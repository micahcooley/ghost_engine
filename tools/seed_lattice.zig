const std = @import("std");
const core = @import("ghost_core");
const sys = core.sys;
const config = core.config;

pub fn main_wrapped(init: std.process.Init) !void {
    const allocator = init.gpa;

    const lattice_size: usize = config.UNIFIED_SIZE_BYTES;
    const monolith_size: usize = config.SEMANTIC_SIZE_BYTES;
    const tags_size: usize = config.TAG_SIZE_BYTES;

    const lattice_abs_path = try config.getPath(allocator, config.LATTICE_REL_PATH);
    const semantic_abs_path = try config.getPath(allocator, config.SEMANTIC_REL_PATH);
    const tag_abs_path = try config.getPath(allocator, config.TAG_REL_PATH);
    defer allocator.free(lattice_abs_path);
    defer allocator.free(semantic_abs_path);
    defer allocator.free(tag_abs_path);

    std.debug.print("Ghost Engine: State Seeding (~2.1 GB)\n", .{});

    // Ensure state directory exists using sys.makePath
    if (std.fs.path.dirname(lattice_abs_path)) |dir_path| {
        sys.makePath(allocator, dir_path) catch |err| {
            if (err != error.DirectoryCreationFailed) return err;
        };
    }

    try initializeFile(allocator, lattice_abs_path, lattice_size);
    try initializeFile(allocator, semantic_abs_path, monolith_size);
    try initializeFile(allocator, tag_abs_path, tags_size);

    std.debug.print("\nState Seeding Complete.\n", .{});
    std.debug.print("The Ghost is ready to begin ingestion.\n", .{});
}

fn initializeFile(allocator: std.mem.Allocator, path: []const u8, size: usize) !void {
    // Check if file exists using sys
    const f_check = sys.openForRead(allocator, path) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("  Creating {s}... ", .{path});
            const mapped = try sys.createMappedFile(allocator, path, size);
            sys.flushMappedMemory(&mapped);
            std.debug.print("done.\n", .{});
            return;
        }
        return err;
    };
    sys.closeFile(f_check);
    std.debug.print("  {s} already exists.\n", .{path});
}

pub fn main(init: std.process.Init) void {
    main_wrapped(init) catch |err| {
        std.debug.print("\n[FATAL ERROR] {any}\n", .{err});
        std.process.exit(1);
    };
}
