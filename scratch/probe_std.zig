const std = @import("std");
pub fn main() void {
    const std_info = @typeInfo(std);
    if (std_info == .@"struct") {
        const decls = std_info.@"struct".decls;
        inline for (decls) |decl| {
            if (std.mem.indexOf(u8, decl.name, "Mutex") != null or std.mem.indexOf(u8, decl.name, "Condition") != null) {
                std.debug.print("Found std declaration: {s}\n", .{decl.name});
            }
        }
    }
    
    const thread_info = @typeInfo(std.Thread);
    if (thread_info == .@"struct") {
        const decls = thread_info.@"struct".decls;
        inline for (decls) |decl| {
            if (std.mem.indexOf(u8, decl.name, "Mutex") != null or std.mem.indexOf(u8, decl.name, "Condition") != null) {
                std.debug.print("Found std.Thread declaration: {s}\n", .{decl.name});
            }
        }
    }
}
