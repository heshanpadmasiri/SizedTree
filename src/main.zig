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
};

fn print_and_deallocate_entries(allocator: std.mem.Allocator, entries: ArrayList(Entry), depth: usize) !void {
    for (entries.items) |entry| {
        try print_entry(allocator, entry, depth);
    }
    entries.deinit();
}

fn print_entry(allocator: std.mem.Allocator, entry: Entry, depth: usize) std.os.WriteError!void {
    switch (entry) {
        .file => |file_entry| {
            const basename = file_entry.basename;
            try stdOut.writer().print("file: {s}\n", .{basename});
            allocator.free(basename);
        },
        .directory => |directory_entry| {
            const basename = directory_entry.basename;
            try stdOut.writer().print("dir:{s}\n", .{basename});
            allocator.free(basename);
            try print_and_deallocate_entries(allocator, directory_entry.children, depth + 1);
        },
    }
}

// TODO: This should return entries in a sorted order
fn walk_directory(allocator: std.mem.Allocator, path: []const u8) !ArrayList(Entry) {
    var dir = try std.fs.cwd().openIterableDir(path, .{ .access_sub_paths = false, .no_follow = true });
    var it = dir.iterate();
    defer dir.close();
    var list = ArrayList(Entry).init(allocator);

    while (try it.next()) |entry| {
        var basename = try allocator.alloc(u8, entry.name.len);
        @memcpy(basename, entry.name.ptr);
        const size = 0;
        switch (entry.kind) {
            FileKind.file => {
                const file_entry = Entry{ .file = FileEntry{ .basename = basename, .size = size } };
                try list.append(file_entry);
            },
            FileKind.directory => {
                var childPath = try std.fs.path.join(allocator, &[_][]const u8{ path, basename });
                defer allocator.free(childPath);
                const children = try walk_directory(allocator, childPath);
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
    return list;
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
