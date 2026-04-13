const std = @import("std");
const core = @import("ghost_core");
const sys = core.sys;
const config = core.config;

pub fn main_wrapped(init: std.process.Init) !void {
    const allocator = init.gpa;
    const path = "mixed_sovereign.txt";
    
    // Use project root for consistency
    const abs_path = try config.getPath(allocator, path);
    defer allocator.free(abs_path);

    const f = try sys.openForWrite(allocator, abs_path);
    defer sys.closeFile(f);

    const line = "Ghost Engine Sovereign Resilience Test. ";
    for (0..250000) |_| {
        try sys.writeAll(f, line);
    }
    
    std.debug.print("Successfully generated {s}\n", .{abs_path});
}

pub fn main(init: std.process.Init) void {
    main_wrapped(init) catch |err| {
        std.debug.print("\n[FATAL ERROR] {any}\n", .{err});
        std.process.exit(1);
    };
}
