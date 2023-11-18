const std = @import("std");
const stdErr = std.io.getStdErr();
const stdOut = std.io.getStdOut();
const ArrayList = std.ArrayList;
const FileKind = std.fs.File.Kind;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    // TODO: what to do with return value?
    defer _ = gpa.deinit();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const n_args = args.len;

    // TODO: handle the case where use don't provide any path
    // For that we need to figure out the path from which user executed the binary
    // check `std.fs.cwd()`
    // TODO: also allow controlling how deep we need the output to go
    // (ideally we shouldn't check for files deeper than that either)
    // FIXME: name too long (not sure what is causing it, other than handling deeply recursive directories)
    if (n_args != 2) {
        try print_message_and_exit("Please provide a path to a file", 1);
    }
    const path = args[1];
    // TODO: pass in a areana allocator
    const entries = try walk_directory(allocator, path);
    try print_and_deallocate_entries(allocator, entries, 0);
}

// Size is in bytes
const DirectoryEntry = struct {
    basename: []const u8,
    size: usize,
    children: ArrayList(Entry),
};

const FileEntry = struct {
    basename: []const u8,
    size: usize,
};

const EntryTag = enum { file, directory };
const Entry = union(EntryTag) {
    file: FileEntry,
    directory: DirectoryEntry,
    fn size(self: Entry) usize {
        switch (self) {
            .file => |file_entry| {
                return file_entry.size;
            },
            .directory => |directory_entry| {
                return directory_entry.size;
            },
        }
    }

    fn basename(self: Entry) []const u8 {
        switch (self) {
            .file => |file_entry| {
                return file_entry.basename;
            },
            .directory => |directory_entry| {
                return directory_entry.basename;
            },
        }
    }
};

fn entryLessThan(context: void, lhs: Entry, rhs: Entry) bool {
    _ = context;
    return lhs.size() < rhs.size();
}

fn print_and_deallocate_entries(allocator: std.mem.Allocator, entries: ArrayList(Entry), depth: usize) !void {
    for (entries.items) |entry| {
        try print_entry(allocator, entry, depth);
    }
    entries.deinit();
}

fn print_entry(allocator: std.mem.Allocator, entry: Entry, depth: usize) (std.os.WriteError || std.mem.Allocator.Error)!void {
    const prefix = try create_prefix(allocator, depth);
    defer allocator.free(prefix);
    const size = try human_readable_size(allocator, entry.size());
    defer allocator.free(size);
    const basename = entry.basename();
    defer allocator.free(basename);
    const spacer_text = try spacer(allocator, prefix.len, basename.len, size.len);
    defer allocator.free(spacer_text);
    try stdOut.writer().print("{s}-- {s}{s}{s}\n", .{ prefix, basename, spacer_text, size });
    switch (entry) {
        .directory => |directory_entry| {
            try print_and_deallocate_entries(allocator, directory_entry.children, depth + 1);
        },
        else => {},
    }
}


fn spacer(allocator: std.mem.Allocator, prefix_len: usize, basename_len: usize, size_len: usize) ![]const u8 {
    const total_len = prefix_len + "-- ".len + basename_len + size_len;
    const remainder = 80 - total_len;
    if (remainder <= 0) {
        return "";
    }
    var buffer = try allocator.alloc(u8, remainder);
    for (0..remainder) |i| {
        buffer[i] = if (i == 0) ' ' else '.';
    }
    return buffer;
}

fn human_readable_size(allocator: std.mem.Allocator, size: usize) ![]const u8 {
    var fs: f64 = @floatFromInt(size);
    switch (size) {
        0...1023 => {
            return try std.fmt.allocPrint(allocator, "{d:.2} B", .{fs});
        },
        1024...(1024 * 1024 - 1) => {
            return try std.fmt.allocPrint(allocator, "{d:.2} KB", .{fs / 1024.0});
        },
        1024 * 1024...1024 * 1024 * 1024 => {
            return try std.fmt.allocPrint(allocator, "{d:.2} MB", .{fs / (1024.0 * 1024.0)});
        },
        else => {
            return try std.fmt.allocPrint(allocator, "{d:.2} GB", .{fs / (1024.0 * 1024.0 * 1024.0)});
        },
    }
}

fn create_prefix(allocator: std.mem.Allocator, depth: usize) ![]const u8 {
    var prefix = try allocator.alloc(u8, depth * 2); // | + space
    for (0..depth) |i| {
        const index = i * 2;
        prefix[index] = '|';
        prefix[index + 1] = ' ';
    }
    return prefix;
}

// TODO: walk directory should accept the array list as an argument and index in it
// Then walk directory will update the index in it (this allows us to run the threads without locking)
// But the first one don't know the index so we will split this walk_directory function to a top level one and inner one
fn walk_directory(allocator: std.mem.Allocator, path: []const u8) !ArrayList(Entry) {
    var dir = try std.fs.cwd().openIterableDir(path, .{ .access_sub_paths = false, .no_follow = true });
    defer dir.close();
    var buffer = ArrayList(?Entry).init(allocator);
    defer buffer.deinit();
    try buffer.append(null);
    try walk_directory_inner(allocator, dir, try owned_heap_string(allocator, path), 0, buffer);
    var entries = ArrayList(Entry).init(allocator);
    // TODO: use a iterator
    for (buffer.items) |entry| {
        try entries.append(entry.?);
    }
    std.mem.sort(Entry, entries.items, {}, entryLessThan);
    return entries;
}

const DirectoryTrampoline = struct {
    index: usize,
    directory_name: []const u8,
};

fn walk_directory_inner(allocator: std.mem.Allocator, parent_dir: std.fs.IterableDir, directory_name: []const u8, index: usize, siblingBuffer: ArrayList(?Entry)) !void {
    var dir = try parent_dir.dir.openIterableDir(directory_name, .{ .access_sub_paths = false, .no_follow = true });
    defer dir.close();
    var it = dir.iterate();
    var buffer = ArrayList(?Entry).init(allocator);
    defer buffer.deinit();
    var child_directories = ArrayList(DirectoryTrampoline).init(allocator);
    defer child_directories.deinit();
    // TODO: Create a list to hold all directory entries
    while (try it.next()) |entry| {
        var basename = try owned_heap_string(allocator, entry.name);
        switch (entry.kind) {
            FileKind.file => {
                const size = try file_size(dir.dir, basename);
                const file_entry = Entry{ .file = FileEntry{ .basename = basename, .size = size } };
                try buffer.append(file_entry);
            },
            FileKind.directory => {
                try child_directories.append(DirectoryTrampoline{ .index = buffer.items.len, .directory_name = basename });
                try buffer.append(null);
            },
            else => {
                // currently we ignore other cases
            },
        }
    }
    // TODO: this needs to be parallelized
    // Idea is to be able to to this without locking the buffer (since each has unique index in the preallocated array)
    for (child_directories.items) |child| {
        try walk_directory_inner(allocator, dir, child.directory_name, child.index, buffer);
    }
    var entries = ArrayList(Entry).init(allocator);
    // TODO: use a iterator
    for (buffer.items) |entry| {
        try entries.append(entry.?);
    }
    var size: usize = 0;
    for (entries.items) |child| {
        size += child.size();
    }
    const directory_entry = Entry{ .directory = DirectoryEntry{
        .basename = directory_name,
        .size = size,
        .children = entries,
    } };
    siblingBuffer.items[index] = directory_entry;
    std.mem.sort(Entry, entries.items, {}, entryLessThan);
}

fn owned_heap_string(allocator: std.mem.Allocator, string: []const u8) ![]const u8 {
    var buffer = try allocator.alloc(u8, string.len);
    @memcpy(buffer, string.ptr);
    return buffer;
}

fn file_size(dir: std.fs.Dir, file_name: []const u8) !usize {
    var file = try dir.openFile(file_name, .{});
    defer file.close();
    return (try file.stat()).size;
}

fn print_message_and_exit(message: []const u8, status: u8) !void {
    if (status != 0) {
        try stdErr.writer().print("ERROR: {s}\n", .{message});
        std.os.exit(status);
    } else {
        try stdOut.writer().print("{s}\n", .{message});
        std.os.exit(0);
    }
}
