const std = @import("std");
const ghost = @import("ghost_core");

pub fn main() !void {
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
