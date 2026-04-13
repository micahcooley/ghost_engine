const std = @import("std");
pub fn main() void {
    if (@hasDecl(std.Thread, "Mutex")) {
        std.debug.print("std.Thread.Mutex exists\n", .{});
    } else {
        std.debug.print("std.Thread.Mutex DOES NOT exist\n", .{});
    }
}
