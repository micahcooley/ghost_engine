const std = @import("std");
const core = @import("ghost_core");
const vsa_vulkan = core.vsa_vulkan;
const vsa = core.vsa;
const triad = core.triad;
const sys = core.sys;
const ghost_state = core.ghost_state;
const config = core.config;

fn featureVector(prefix: []const u8, text: []const u8) vsa.HyperVector {
    var h: u64 = 14695981039346656037;
    for (prefix) |c| {
        h ^= c;
        h *%= 1099511628211;
    }
    for (text) |c| {
        h ^= c;
        h *%= 1099511628211;
    }
    return vsa.generate(h);
}

fn latticeBlockWordRange(block_idx: usize) struct { start: usize, end: usize } {
    const start_byte = block_idx * config.CHECKSUM_BLOCK_SIZE;
    const end_byte = if (block_idx + 1 == ghost_state.UnifiedLattice.BLOCK_COUNT)
        ghost_state.UnifiedLattice.HASH_OFFSET
    else
        start_byte + config.CHECKSUM_BLOCK_SIZE;

    return .{
        .start = start_byte / @sizeOf(u16),
        .end = end_byte / @sizeOf(u16),
    };
}

fn syncSliceToPagedLattice(src: []const u16, provider: *ghost_state.PagedLatticeProvider) !void {
    for (0..ghost_state.UnifiedLattice.BLOCK_COUNT) |block_idx| {
        const range = latticeBlockWordRange(block_idx);
        var lease = try provider.acquireWords(range.start, range.end - range.start, true);
        defer lease.release();
        @memcpy(lease.words(), src[range.start..range.end]);
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: ghost_medic_ingest <pytest-log-path>\n", .{});
        std.process.exit(2);
    }

    const log_path = args[1];

    // Read the log file
    const content = std.fs.cwd().readFileAlloc(allocator, log_path, 1024 * 1024 * 100) catch |err| {
        std.debug.print("ghost_medic_ingest: could not read file '{s}': {any}\n", .{ log_path, err });
        std.process.exit(1);
    };
    defer allocator.free(content);

    // Initialize Vulkan
    const vk = vsa_vulkan.initRuntime(allocator) catch |err| {
        std.debug.print("ghost_medic_ingest: failed to init Vulkan runtime: {any}\n", .{err});
        return error.VulkanInitFailed;
    };
    defer vsa_vulkan.deinitRuntime();

    // Mount Core Shard for persistence
    var state_shard = core.shards.MountedStateShard.mountCore(allocator, core.config.IDEAL_LATTICE_SIZE) catch |err| {
        std.debug.print("ghost_medic_ingest: failed to mount state shard: {any}\n", .{err});
        return err;
    };
    defer state_shard.deinit();

    // Prepare temporary host lattice for Vulkan binding
    const lattice_word_count = config.UNIFIED_SIZE_BYTES / @sizeOf(u16);
    const host_lattice_words = try allocator.alloc(u16, lattice_word_count);
    defer allocator.free(host_lattice_words);
    @memset(host_lattice_words, 0);

    // Bind host state to Vulkan
    vk.bindHostState(state_shard.meaning_matrix.data, state_shard.meaning_matrix.tags.?, state_shard.rank_bytes, host_lattice_words);

    // Initialize Lattice
    var lattice = try core.rune_lattice.RuneLattice.init(allocator, 0, vk);
    defer lattice.deinit();

    var last_file: []const u8 = "unknown";
    var lines = std.mem.splitScalar(u8, content, '\n');
    var error_count: usize = 0;

    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, ": in ")) |idx| {
            last_file = std.mem.trim(u8, line[0..idx], " \t\r");
        } else if (std.mem.startsWith(u8, line, "E   ")) {
            const err_msg = std.mem.trim(u8, line[4..], " \t\r");
            const env_hash: u64 = 0xDEADBEEF; // Default hash for env

            const err_vec = featureVector("error:", err_msg);
            const file_vec = featureVector("file:", last_file);
            const env_vec = featureVector("env:", "pytest");

            const bound1 = vsa.bind(err_vec, file_vec);
            const diag_rune = vsa.bind(bound1, env_vec);

            const now_ms = @as(u64, @intCast(std.time.milliTimestamp()));
            if (lattice.observe(diag_rune, env_hash, now_ms)) |slot| {
                // Rank 4 is 'emerging'
                lattice.ranks[slot] = triad.RuneRank.emerging;
                error_count += 1;
                std.debug.print("Ingested Diagnostic Rune (Rank 4) -> slot {d}\n  Error: {s}\n  File: {s}\n", .{ slot, err_msg, last_file });
            }
        }
    }

    // Sync back to host and flush to disk
    try vk.syncDeviceToHost(state_shard.meaning_matrix.data, state_shard.meaning_matrix.tags.?, state_shard.rank_bytes, host_lattice_words);
    try syncSliceToPagedLattice(host_lattice_words, &state_shard.paged_lattice);
    try state_shard.flush();

    std.debug.print("Ingestion complete. {d} errors bound as Causal Links.\n", .{error_count});
}
