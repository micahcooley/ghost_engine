const std = @import("std");
pub fn main() void {
    inline for (std.meta.declarations(std.Thread)) |decl| {
        @compileLog(decl.name);
    }
}
