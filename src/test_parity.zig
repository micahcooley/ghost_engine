const std = @import("std");
const core = @import("ghost_core");
const vsa = core.vsa;
const ghost_state = core.ghost_state;
const vsa_vulkan = core.vsa_vulkan;
const testing = std.testing;

fn cpuEtchSlotFull(meaning: *vsa.MeaningMatrix, rotor: u64, target_char: u32) void {
    var slot_idx: ?u32 = null;
    const num_slots: u32 = @intCast(meaning.tags.?.len);
    const base_idx = @as(u32, @truncate(rotor % num_slots));
    const stride = @as(u32, @intCast((rotor >> 32) | 1));
    var p: u32 = 0;
    while (p < 8) : (p += 1) {
        const slot = (base_idx + p *% stride) % num_slots;
        if (meaning.tags.?[slot] == rotor) { slot_idx = slot; break; }
        if (meaning.tags.?[slot] == 0) { meaning.tags.?[slot] = rotor; slot_idx = slot; break; }
    }
    const sid = slot_idx orelse return;

    var word_acc = meaning.data[sid * 1024 .. sid * 1024 + 1024];
    const reality_bytes: [128]u8 = @bitCast(vsa.generate(@as(u64, target_char)));
    
    for (0..1024) |i| {
        const bit = (reality_bytes[i / 8] >> @as(u3, @intCast(i % 8))) & 1;
        if (bit == 1) {
            if (word_acc[i] < 65535) word_acc[i] += 1;
        } else {
            if (word_acc[i] > 0) word_acc[i] -= 1;
        }
    }
}

test "MeaningMatrix Parity (CPU vs GPU)" {
    const allocator = std.testing.allocator;

    // ── 1. Init GPU Compute ──
    const compute = try vsa_vulkan.GHOST_COMPUTE_PLUGIN.init(allocator);
    defer vsa_vulkan.GHOST_COMPUTE_PLUGIN.deinit();

    // ── 2. Init Meaning Matrices ──
    const gpu_matrix_data = compute.getMatrixData();
    const cpu_matrix_data = try allocator.alloc(u16, gpu_matrix_data.len);
    defer allocator.free(cpu_matrix_data);
    @memset(cpu_matrix_data, 0);
    @memset(gpu_matrix_data, 0);

    const gpu_tags_data = compute.getTagsData();
    const cpu_tags_data = try allocator.alloc(u64, gpu_tags_data.len);
    defer allocator.free(cpu_tags_data);
    @memset(cpu_tags_data, 0);
    @memset(gpu_tags_data, 0);

    var cpu_meaning = vsa.MeaningMatrix{
        .data = cpu_matrix_data,
        .tags = cpu_tags_data,
    };

    // ── 3. Initialize Shared State ──
    var cpu_soul = try allocator.create(ghost_state.GhostSoul);
    defer allocator.destroy(cpu_soul);
    cpu_soul.* = ghost_state.GhostSoul.init(allocator);
    defer cpu_soul.deinit();
    cpu_soul.meaning_matrix = null;

    const test_corpus = "The quick brown fox jumps over the lazy dog. Unity in the lattice is essential.";
    
    // Arrays for GPU dispatch
    var rotors: std.ArrayListUnmanaged(u64) = .empty;
    defer rotors.deinit(allocator);
    var chars: std.ArrayListUnmanaged(u32) = .empty;
    defer chars.deinit(allocator);
    var indices: std.ArrayListUnmanaged(u32) = .empty;
    defer indices.deinit(allocator);

    // ── 4. Perform CPU-side Inference & Etch ──
    for (test_corpus) |rune| {
        // Collect GPU args matching the StreamState logic
        try rotors.append(allocator, cpu_soul.lexical_rotor);
        try rotors.append(allocator, cpu_soul.semantic_rotor);
        try chars.append(allocator, @intCast(rune));
        try indices.append(allocator, 0);

        cpuEtchSlotFull(&cpu_meaning, cpu_soul.lexical_rotor, @intCast(rune));
        cpuEtchSlotFull(&cpu_meaning, cpu_soul.semantic_rotor, @intCast(rune));

        _ = try cpu_soul.absorb(vsa.generate(rune), rune, null);

        // Run GPU dispatch for this single rune to prevent atomic concurrency divergence
        compute.setTier(1024); // Ensure tier is initialized
        try compute.etch(
            1,
            1,
            rotors.items[rotors.items.len - 2 ..],
            chars.items[chars.items.len - 1 ..],
            indices.items[indices.items.len - 1 ..],
        );
    }

    // Read back CPU data
    const final_gpu_matrix = compute.getMatrixData();
    const final_gpu_tags = compute.getTagsData();

    // ── 6. Assert Parity ──
    try testing.expectEqual(final_gpu_tags.len, cpu_tags_data.len);
    try testing.expectEqual(final_gpu_matrix.len, cpu_matrix_data.len);

    var tag_mismatches: usize = 0;
    var data_mismatches: usize = 0;

    for (0..cpu_tags_data.len) |i| {
        if (cpu_tags_data[i] != final_gpu_tags[i]) tag_mismatches += 1;
    }
    
    // We only test tags and cells that the CPU actually etched
    for (0..cpu_tags_data.len) |slot| {
        if (cpu_tags_data[slot] != 0) {
            const base = slot * 1024;
            for (0..1024) |bit| {
                const cpu_val = cpu_matrix_data[base + bit];
                const gpu_val = final_gpu_matrix[base + bit];
                if (cpu_val != gpu_val) data_mismatches += 1;
            }
        }
    }

    if (tag_mismatches > 0 or data_mismatches > 0) {
        for (0..cpu_tags_data.len) |i| {
            if (cpu_tags_data[i] != final_gpu_tags[i]) {
                try testing.expectEqual(cpu_tags_data[i], final_gpu_tags[i]);
            }
        }
        return error.ParityMismatch;
    }

    std.debug.print("\n[PARITY SUCCESS] CPU and GPU Meaning Matrices perfectly match.\n", .{});
}
