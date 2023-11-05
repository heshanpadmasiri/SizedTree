const std = @import("std");
const stdErr = std.io.getStdErr();
const stdOut = std.io.getStdOut();
const ArrayList = std.ArrayList;
const FileKind = std.fs.File.Kind;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const n_args = args.len;

    // TODO: handle the case where use don't provide any path
    // For that we need to figure out the path from which user executed the binary
    // check `std.fs.cwd()`
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
    allocator.free(prefix);
}

fn spacer(allocator: std.mem.Allocator, prefix_len: usize, basename_len: usize, size_len: usize) ![]const u8 {
    const total_len = prefix_len + "-- ".len + basename_len + size_len;
    const remainder = 80 - total_len;
    if (remainder <= 0) {
        return "";
    }
    var buffer = try allocator.alloc(u8, remainder);
    for (0..remainder) |i| {
        buffer[i] = '.';
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

fn walk_directory(allocator: std.mem.Allocator, path: []const u8) !ArrayList(Entry) {
    var dir = try std.fs.cwd().openIterableDir(path, .{ .access_sub_paths = false, .no_follow = true });
    var it = dir.iterate();
    defer dir.close();
    var list = ArrayList(Entry).init(allocator);
    while (try it.next()) |entry| {
        var basename = try allocator.alloc(u8, entry.name.len);
        @memcpy(basename, entry.name.ptr);
        var file_path = try std.fs.path.join(allocator, &[_][]const u8{ path, basename });
        defer allocator.free(file_path);
        switch (entry.kind) {
            FileKind.file => {
                const size = try file_size(file_path);
                const file_entry = Entry{ .file = FileEntry{ .basename = basename, .size = size } };
                try list.append(file_entry);
            },
            FileKind.directory => {
                const children = try walk_directory(allocator, file_path);
                var size: usize = 0;
                for (children.items) |child| {
                    size += child.size();
                }
                const directory_entry = Entry{ .directory = DirectoryEntry{
                    .basename = basename,
                    .size = size,
                    .children = children,
                } };
                try list.append(directory_entry);
            },
            else => {
                // currently we ignore other cases
            },
        }
    }
    std.mem.sort(Entry, list.items, {}, entryLessThan);
    return list;
}

fn file_size(path: []const u8) !usize {
    var file = try std.fs.cwd().openFile(path, .{});
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
