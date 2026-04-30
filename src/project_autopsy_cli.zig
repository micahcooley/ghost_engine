const std = @import("std");
const ghost = @import("ghost_core");

pub fn main() !void {
    mainImpl() catch |err| switch (err) {
        error.FileNotFound => {
            try printExpectedError("workspace path was not found");
            std.process.exit(1);
        },
        error.NotDir => {
            try printExpectedError("workspace path is not a directory");
            std.process.exit(1);
        },
        error.AccessDenied => {
            try printExpectedError("workspace path could not be accessed");
            std.process.exit(1);
        },
        else => return err,
    };
}

fn mainImpl() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();

    var root: []const u8 = ".";

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            const stdout = std.io.getStdOut().writer();
            try stdout.writeAll(
                \\Usage: ghost_project_autopsy [path]
                \\
                \\Options:
                \\  -h, --help     Show this help
                \\  --version      Show version
                \\
            );
            return;
        } else if (std.mem.eql(u8, arg, "--version")) {
            const stdout = std.io.getStdOut().writer();
            try stdout.print("{s}\n", .{ghost.VERSION});
            return;
        } else {
            root = arg;
        }
    }

    const stdout = std.io.getStdOut().writer();
    try ghost.project_autopsy.writeJson(allocator, root, stdout);
    try stdout.writeByte('\n');
}

fn printExpectedError(message: []const u8) !void {
    const stderr = std.io.getStdErr().writer();
    try stderr.print("ghost_project_autopsy: {s}\n", .{message});
    try stderr.writeAll("Use --help for usage.\n");
}

test "project autopsy CLI classifies expected path errors" {
    try std.testing.expect(isExpectedPathError(error.FileNotFound));
    try std.testing.expect(isExpectedPathError(error.NotDir));
    try std.testing.expect(isExpectedPathError(error.AccessDenied));
    try std.testing.expect(!isExpectedPathError(error.OutOfMemory));
}

fn isExpectedPathError(err: anyerror) bool {
    return switch (err) {
        error.FileNotFound, error.NotDir, error.AccessDenied => true,
        else => false,
    };
}
