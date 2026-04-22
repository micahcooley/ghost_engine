const builtin = @import("builtin");

pub usingnamespace if (builtin.os.tag == .linux)
    @import("shell_linux.zig")
else
    @import("shell_windows.zig");
