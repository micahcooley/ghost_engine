const std = @import("std");
const core = @import("ghost_core");
const sys = core.sys;
const config = core.config;
const shards = core.shards;

fn resolveSelectedShardPaths(allocator: std.mem.Allocator) !shards.Paths {
    const project_id = std.process.getEnvVarOwned(allocator, "GHOST_PROJECT_SHARD") catch null;
    defer if (project_id) |value| allocator.free(value);

    var metadata = if (project_id) |value|
        try shards.resolveProjectMetadata(allocator, value)
    else
        try shards.resolveCoreMetadata(allocator);
    defer metadata.deinit();

    return shards.resolvePaths(allocator, metadata.metadata);
}

pub fn main_wrapped(allocator: std.mem.Allocator) !void {
    const lattice_size: usize = config.UNIFIED_SIZE_BYTES;
    const monolith_size: usize = config.SEMANTIC_SIZE_BYTES;
    const tags_size: usize = config.TAG_SIZE_BYTES;
    const total_size: usize = lattice_size + monolith_size + tags_size;

    var shard_paths = try resolveSelectedShardPaths(allocator);
    defer shard_paths.deinit();

    std.debug.print(
        "Ghost Engine: State Seeding ({})\n  {s}: {}\n  {s}: {}\n  {s}: {}\n",
        .{
            std.fmt.fmtIntSizeBin(total_size),
            shard_paths.lattice_abs_path,
            std.fmt.fmtIntSizeBin(lattice_size),
            shard_paths.semantic_abs_path,
            std.fmt.fmtIntSizeBin(monolith_size),
            shard_paths.tags_abs_path,
            std.fmt.fmtIntSizeBin(tags_size),
        },
    );

    // Seed the selected target's state directory under platforms/<os>/<arch>/state.
    if (std.fs.path.dirname(shard_paths.lattice_abs_path)) |dir_path| {
        sys.makePath(allocator, dir_path) catch |err| {
            if (err != error.DirectoryCreationFailed) return err;
        };
    }

    try initializeFile(allocator, shard_paths.lattice_abs_path, lattice_size);
    try initializeFile(allocator, shard_paths.semantic_abs_path, monolith_size);
    try initializeFile(allocator, shard_paths.tags_abs_path, tags_size);

    std.debug.print("\nState Seeding Complete.\n", .{});
    std.debug.print("The Ghost is ready to begin ingestion.\n", .{});
}

fn initializeFile(allocator: std.mem.Allocator, path: []const u8, size: usize) !void {
    // Check if file exists using sys
    const f_check = sys.openForRead(allocator, path) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("  Creating {s}... ", .{path});
            var mapped = try sys.createMappedFile(allocator, path, size);
            defer mapped.unmap();
            try sys.flushMappedMemory(&mapped);
            std.debug.print("done.\n", .{});
            return;
        }
        return err;
    };
    sys.closeFile(f_check);
    std.debug.print("  {s} already exists.\n", .{path});
}

pub fn main() void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    main_wrapped(gpa.allocator()) catch |err| {
        std.debug.print("\n[FATAL ERROR] {any}\n", .{err});
        std.process.exit(1);
    };
}
