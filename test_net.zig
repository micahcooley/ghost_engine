const std = @import("std");
pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena.allocator();
    const stats = .{ .a = 1, .b = 2 };
    const json_str = try std.fmt.allocPrint(allocator, "{}", .{ std.json.fmt(stats, .{}) });
    std.debug.print("{s}\n", .{json_str});
}
