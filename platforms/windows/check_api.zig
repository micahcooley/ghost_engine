const std = @import("std");
pub fn main() !void {
    const process = std.process;
    inline for (std.meta.declarations(process)) |decl| {
        if (std.mem.containsAtLeast(u8, decl.name, 1, "Env")) {
            std.debug.print("{s}\n", .{decl.name});
        }
    }
}
