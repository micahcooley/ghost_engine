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
        std.debug.print("Usage: ghost_medic_solve <test-command...>\n", .{});
        std.process.exit(2);
    }

    const test_command = args[1..];

    // Initialize Vulkan
    const vk = vsa_vulkan.initRuntime(allocator) catch |err| {
        std.debug.print("ghost_medic_solve: failed to init Vulkan runtime: {any}\n", .{err});
        return error.VulkanInitFailed;
    };
    defer vsa_vulkan.deinitRuntime();

    // Mount Core Shard for persistence
    var state_shard = core.shards.MountedStateShard.mountCore(allocator, core.config.IDEAL_LATTICE_SIZE) catch |err| {
        std.debug.print("ghost_medic_solve: failed to mount state shard: {any}\n", .{err});
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

    // Initialize Effector
    var eff = try core.effector.Effector.init(allocator);
    defer eff.deinit();

    std.debug.print("[MEDIC] Scanning Lattice for Rank 4 (Emerging) Causal Links...\n", .{});

    var found_rank4: u32 = 0;
    var candidate_slot: ?u32 = null;
    var captured_diag_rune: ?vsa.HyperVector = null;

    const now_ms = @as(u64, @intCast(std.time.milliTimestamp()));

    for (0..lattice.capacity) |i| {
        const slot: u32 = @intCast(i);
        if (lattice.ranks[slot] == triad.RuneRank.emerging) {
            found_rank4 += 1;
            std.debug.print("[MEDIC] Found Rank 4 Diagnostic Rune at slot {d}.\n", .{slot});
            
            // Project a fix using an Effector command:
            // R_candidate = bind(R_diagnostic, R_pip_install)
            const diag_rune = lattice.vectors[slot];
            captured_diag_rune = diag_rune;
            
            const r_pip_install = featureVector("effector_cmd", "pip install --break-system-packages jinja2");
            const r_candidate = vsa.bind(diag_rune, r_pip_install);
            
            // Inject candidate into lattice
            if (lattice.observe(r_candidate, 0x11223344, now_ms)) |c_slot| {
                candidate_slot = c_slot;
                std.debug.print("[MEDIC] Projected Candidate Rune into Dark Space (slot {d}).\n", .{c_slot});
            }
            break; // Just solve one for now
        }
    }

    if (found_rank4 == 0) {
        std.debug.print("[MEDIC] No Rank 4 Causal Links found. System is healthy.\n", .{});
    } else if (candidate_slot) |c_slot| {
        // Attempt to execute the Effector command first
        _ = try eff.resolveAndExecute(lattice.vectors[c_slot], captured_diag_rune.?);

        var joined_cmd = std.ArrayList(u8).init(allocator);
        defer joined_cmd.deinit();
        for (test_command, 0..) |arg, i| {
            if (i > 0) try joined_cmd.append(' ');
            try joined_cmd.appendSlice(arg);
        }
        
        std.debug.print("[MEDIC] Verifying fix: Executing '{s}'\n", .{joined_cmd.items});
        
        var child_args = [_][]const u8{ "/bin/sh", "-c", joined_cmd.items };
        var child = std.process.Child.init(&child_args, allocator);
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        
        const term = child.spawnAndWait() catch |err| {
            std.debug.print("[MEDIC] Failed to spawn test process: {any}\n", .{err});
            std.process.exit(1);
        };
        
        if (term.Exited == 0) {
            std.debug.print("[MEDIC] SUCCESS! Candidate Rune verified by test environment.\n", .{});
            std.debug.print("[MEDIC] Promoting Candidate Rune (slot {d}) to Rank 1 (Verified).\n", .{c_slot});
            lattice.ranks[c_slot] = triad.RuneRank.verified;
        } else {
            std.debug.print("[MEDIC] FAILURE. Candidate Rune did not resolve the test failure (exit code {d}).\n", .{term.Exited});
            // Demote to noise
            lattice.ranks[c_slot] = triad.RuneRank.noise;
        }
    }

    // Sync back to host and flush to disk
    try vk.syncDeviceToHost(state_shard.meaning_matrix.data, state_shard.meaning_matrix.tags.?, state_shard.rank_bytes, host_lattice_words);
    try syncSliceToPagedLattice(host_lattice_words, &state_shard.paged_lattice);
    try state_shard.flush();
}
