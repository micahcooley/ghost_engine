const std = @import("std");
const ghost = @import("ghost_core");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();
    const root = args.next() orelse ".";

    const stdout = std.io.getStdOut().writer();
    try ghost.project_autopsy.writeJson(allocator, root, stdout);
    try stdout.writeByte('\n');
}
