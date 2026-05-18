const std = @import("std");
pub fn main() !void {
    inline for (std.meta.fields(std.posix.MAP)) |f| {
        std.debug.print("Field: {s}\n", .{f.name});
    }
}