const std = @import("std");
const builtin = @import("builtin");
const vsa = @import("vsa_core.zig");
const ghost_state = @import("ghost_state.zig");
const vsa_vulkan = @import("vsa_vulkan.zig");
const layer2a_gpu = @import("layer2a_gpu.zig");
const vl = @import("vulkan_loader.zig");
const vk = vl.vk;

const GoldenPayload = extern struct {
    lexical: u64 = 0xDEADBEEFCAFEBABE,
    semantic: u64 = 0x8BADF00D0D15EA5E,
    rune: u32 = 'X',
};

const WindowsParityGolden = extern struct {
    payload: GoldenPayload,
    rotor_state: [16]u64,
    lexical_slot: u32,
    semantic_slot: u32,
    lexical_vector: [16]u64,
    semantic_vector: [16]u64,
    lexical_tag: u64,
    semantic_tag: u64,
    resonance: u16,
    manager_drift: u16,
    critic_drift: u16,
    drift_passed: u8,
    _padding: [5]u8 = [_]u8{0} ** 5,
};

fn makeGoldenSoul(allocator: std.mem.Allocator, payload: GoldenPayload) !ghost_state.GhostSoul {
    var soul = try ghost_state.GhostSoul.init(allocator);
    soul.lexical_rotor = payload.lexical;
    soul.semantic_rotor = payload.semantic;
    soul.spatial_rotor = vsa.HyperRotor.init(payload.lexical ^ payload.semantic);
    soul.spatial_rotor.evolve(payload.rune);
    return soul;
}

fn cpuProjectSpatialSignature(rotor: vsa.HyperRotor) u32 {
    var result: u32 = 0;
    const state: [16]u64 = rotor.state;
    for (0..16) |i| {
        const word = state[i];
        const lo = @as(u32, @truncate(word));
        if (@popCount(lo) > 16) result |= (@as(u32, 1) << @as(u5, @intCast(i * 2)));

        const hi = @as(u32, @truncate(word >> 32));
        if (@popCount(hi) > 16) result |= (@as(u32, 1) << @as(u5, @intCast(i * 2 + 1)));
    }
    return result;
}

fn cpuFindSlot(rotor: vsa.HyperRotor, uniform_hash: u64, num_slots: u32) ?u32 {
    const spatial_sig = cpuProjectSpatialSignature(rotor);
    const wide = @as(u64, spatial_sig) *% @as(u64, num_slots);
    const base_slot = @as(u32, @truncate(wide >> 32)) & ~@as(u32, vsa.SUDH_NEIGHBORHOOD_SIZE - 1);
    const raw_stride = @as(u32, @truncate(uniform_hash >> 32));
    const stride = @max(raw_stride | 1, vsa.SUDH_NEIGHBORHOOD_SIZE + 1) | 1;
    const slot_mask = num_slots - 1;

    var p: u32 = 0;
    while (p < 8) : (p += 1) {
        const slot = (base_slot +% p *% stride) & slot_mask;
        if (slot < num_slots) return slot;
    }
    return null;
}

fn cpuEtchSlotFull(meaning: *vsa.MeaningMatrix, rotor: vsa.HyperRotor, uniform_hash: u64, target_char: u32) !u32 {
    const num_slots: u32 = @intCast(meaning.tags.?.len);
    const slot_idx = cpuFindSlot(rotor, uniform_hash, num_slots) orelse return error.NoSlot;

    var claimed = false;
    var p: u32 = 0;
    const spatial_sig = cpuProjectSpatialSignature(rotor);
    const wide = @as(u64, spatial_sig) *% @as(u64, num_slots);
    const base_slot = @as(u32, @truncate(wide >> 32)) & ~@as(u32, vsa.SUDH_NEIGHBORHOOD_SIZE - 1);
    const raw_stride = @as(u32, @truncate(uniform_hash >> 32));
    const stride = @max(raw_stride | 1, vsa.SUDH_NEIGHBORHOOD_SIZE + 1) | 1;
    const slot_mask = num_slots - 1;
    while (p < 8) : (p += 1) {
        const slot = (base_slot +% p *% stride) & slot_mask;
        if (meaning.tags.?[slot] == uniform_hash) {
            claimed = true;
            break;
        }
        if (meaning.tags.?[slot] == 0) {
            meaning.tags.?[slot] = uniform_hash;
            claimed = true;
            break;
        }
    }
    if (!claimed) return error.NoSlot;

    const base_idx = slot_idx * 1024;
    var s = @as(u64, target_char) ^ 0x60bee2bee120fc15;
    const c1 = 0xa3b195354a39b70d;
    const c2 = 0x123456789abcdef0;
    var parity: u64 = 0;

    for (0..15) |word_idx| {
        s = (s ^ (s >> 33)) *% c1;
        s = (s ^ (s >> 33)) *% c2;
        s = s ^ (s >> 33);
        const reality_word = s;

        parity ^= std.math.rotl(u64, s, @as(u6, @intCast(word_idx * 3)));
        parity = parity *% 0xbf58476d1ce4e5b9;

        for (0..64) |bit_idx| {
            const target_idx = base_idx + word_idx * 64 + bit_idx;
            if (((reality_word >> @as(u6, @intCast(bit_idx))) & 1) != 0) {
                meaning.data[target_idx] +%= 1;
            } else {
                meaning.data[target_idx] +%= 0xFFFF_FFFF;
            }
        }
    }

    for (0..64) |bit_idx| {
        const target_idx = base_idx + 15 * 64 + bit_idx;
        if (((parity >> @as(u6, @intCast(bit_idx))) & 1) != 0) {
            meaning.data[target_idx] +%= 1;
        } else {
            meaning.data[target_idx] +%= 0xFFFF_FFFF;
        }
    }

    return slot_idx;
}

fn hvWords(vector: vsa.HyperVector) [16]u64 {
    return @bitCast(vector);
}

fn vkCheck(result: vk.VkResult) !void {
    if (result != vk.VK_SUCCESS) return error.VulkanError;
}

const PhaseTrace = struct {
    test_name: []const u8,
    total_timer: std.time.Timer,
    phase_timer: std.time.Timer,
    phase_index: usize = 0,

    fn init(test_name: []const u8) !PhaseTrace {
        std.debug.print("[PARITY] {s} begin\n", .{test_name});
        return .{
            .test_name = test_name,
            .total_timer = try std.time.Timer.start(),
            .phase_timer = try std.time.Timer.start(),
        };
    }

    fn begin(self: *PhaseTrace, phase_name: []const u8) void {
        self.phase_index += 1;
        self.phase_timer.reset();
        std.debug.print("[PARITY] {s} phase {d}: {s}\n", .{
            self.test_name,
            self.phase_index,
            phase_name,
        });
    }

    fn end(self: *PhaseTrace, phase_name: []const u8) void {
        std.debug.print("[PARITY] {s} phase {d} done: {s} ({})\n", .{
            self.test_name,
            self.phase_index,
            phase_name,
            std.fmt.fmtDuration(self.phase_timer.read()),
        });
    }

    fn finish(self: *PhaseTrace) void {
        std.debug.print("[PARITY] {s} complete ({})\n", .{
            self.test_name,
            std.fmt.fmtDuration(self.total_timer.read()),
        });
    }
};

fn dispatchSingleEtch(engine: *vsa_vulkan.VulkanEngine, rotors: []const u64, chars: []const u32, indices: []const u32) !void {
    const frame = engine.frame_idx;
    var total_timer = try std.time.Timer.start();
    var record_timer = try std.time.Timer.start();

    @memcpy(engine.mapped_rotors[frame].?[0..rotors.len], rotors);
    @memcpy(engine.mapped_chars[frame].?[0..chars.len], chars);
    @memcpy(engine.mapped_index[frame].?[0..indices.len], indices);

    _ = engine.vk_ctx.vkResetFences.?(engine.dev, 1, &engine.fences[frame]);

    var begin_info = std.mem.zeroes(vk.VkCommandBufferBeginInfo);
    begin_info.sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    try vkCheck(engine.vk_ctx.vkBeginCommandBuffer.?(engine.command_buffers[frame], &begin_info));

    const wg_size = @min(1024, engine.max_workgroup_invocations);
    const num_workgroups = 1;
    const push_constants = [_]u32{ 1, 1, engine.matrix_slots - 1, engine.lattice_quarter };

    engine.mapped_config[frame].?.* = .{
        .rotor_stride = vsa_vulkan.ROTOR_STRIDE,
        .rotor_offset = 16,
        .batch_size = 1,
    };

    engine.vk_ctx.vkCmdBindPipeline.?(engine.command_buffers[frame], vk.VK_PIPELINE_BIND_POINT_COMPUTE, engine.lattice_pipeline);
    engine.vk_ctx.vkCmdBindDescriptorSets.?(engine.command_buffers[frame], vk.VK_PIPELINE_BIND_POINT_COMPUTE, engine.pipeline_layout, 0, 1, &engine.descriptor_sets[frame], 0, null);
    engine.vk_ctx.vkCmdPushConstants.?(engine.command_buffers[frame], engine.pipeline_layout, vk.VK_SHADER_STAGE_COMPUTE_BIT, 0, 16, &push_constants);
    engine.vk_ctx.vkCmdDispatch.?(engine.command_buffers[frame], num_workgroups, 1, 1);

    var barrier = std.mem.zeroes(vk.VkMemoryBarrier);
    barrier.sType = vk.VK_STRUCTURE_TYPE_MEMORY_BARRIER;
    barrier.srcAccessMask = vk.VK_ACCESS_SHADER_WRITE_BIT;
    barrier.dstAccessMask = vk.VK_ACCESS_SHADER_READ_BIT | vk.VK_ACCESS_SHADER_WRITE_BIT;
    engine.vk_ctx.vkCmdPipelineBarrier.?(engine.command_buffers[frame], vk.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, vk.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0, 1, &barrier, 0, null, 0, null);

    engine.vk_ctx.vkCmdBindPipeline.?(engine.command_buffers[frame], vk.VK_PIPELINE_BIND_POINT_COMPUTE, engine.etch_pipeline);
    engine.vk_ctx.vkCmdPushConstants.?(engine.command_buffers[frame], engine.pipeline_layout, vk.VK_SHADER_STAGE_COMPUTE_BIT, 0, 16, &push_constants);
    engine.vk_ctx.vkCmdDispatch.?(engine.command_buffers[frame], num_workgroups, 1, 1);

    try vkCheck(engine.vk_ctx.vkEndCommandBuffer.?(engine.command_buffers[frame]));
    const record_ns = record_timer.read();

    var submit_info = std.mem.zeroes(vk.VkSubmitInfo);
    submit_info.sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO;
    submit_info.commandBufferCount = 1;
    submit_info.pCommandBuffers = &engine.command_buffers[frame];
    var submit_timer = try std.time.Timer.start();
    try vkCheck(engine.vk_ctx.vkQueueSubmit.?(engine.queue, 1, &submit_info, engine.fences[frame]));
    const submit_ns = submit_timer.read();

    var wait_timer = try std.time.Timer.start();
    try engine.waitForHardwareInterrupt(frame);
    const wait_ns = wait_timer.read();
    engine.frame_idx = (engine.frame_idx + 1) % vsa_vulkan.FRAME_COUNT;

    std.debug.print(
        "[PARITY] single-rune gpu frame {d}: record={} submit={} wait={} total={}\n",
        .{
            frame,
            std.fmt.fmtDuration(record_ns),
            std.fmt.fmtDuration(submit_ns),
            std.fmt.fmtDuration(wait_ns),
            std.fmt.fmtDuration(total_timer.read()),
        },
    );

    _ = wg_size;
}

fn readGoldenFixture(allocator: std.mem.Allocator) !?WindowsParityGolden {
    const env_name = "GHOST_WINDOWS_PARITY_GOLDEN";
    const path = std.process.getEnvVarOwned(allocator, env_name) catch return null;
    defer allocator.free(path);

    const file = std.fs.openFileAbsolute(path, .{}) catch |abs_err| blk: {
        if (abs_err != error.FileNotFound) return abs_err;
        break :blk try std.fs.cwd().openFile(path, .{});
    };
    defer file.close();

    const bytes = try file.readToEndAlloc(allocator, @sizeOf(WindowsParityGolden) + 1);
    defer allocator.free(bytes);
    if (bytes.len != @sizeOf(WindowsParityGolden)) return error.InvalidGoldenFixture;
    return std.mem.bytesToValue(WindowsParityGolden, bytes[0..@sizeOf(WindowsParityGolden)]);
}

fn makeSnapshot(
    payload: GoldenPayload,
    soul: ghost_state.GhostSoul,
    lexical_slot: u32,
    semantic_slot: u32,
    lexical_vector: [16]u64,
    semantic_vector: [16]u64,
    lexical_tag: u64,
    semantic_tag: u64,
) WindowsParityGolden {
    const lexical_hv: vsa.HyperVector = @bitCast(lexical_vector);
    const semantic_hv: vsa.HyperVector = @bitCast(semantic_vector);
    const rotor_state: [16]u64 = @bitCast(soul.spatial_rotor.state);
    const resonance = vsa.calculateResonance(lexical_hv, semantic_hv);
    const drift = vsa.dualDriftCheck(lexical_hv, semantic_hv, 512, 512);
    return .{
        .payload = payload,
        .rotor_state = rotor_state,
        .lexical_slot = lexical_slot,
        .semantic_slot = semantic_slot,
        .lexical_vector = lexical_vector,
        .semantic_vector = semantic_vector,
        .lexical_tag = lexical_tag,
        .semantic_tag = semantic_tag,
        .resonance = resonance,
        .manager_drift = drift.manager_drift,
        .critic_drift = drift.critic_drift,
        .drift_passed = @intFromBool(drift.passed),
    };
}

fn expectGoldenParity(expected: WindowsParityGolden, actual: WindowsParityGolden) !void {
    try std.testing.expectEqual(expected.payload.lexical, actual.payload.lexical);
    try std.testing.expectEqual(expected.payload.semantic, actual.payload.semantic);
    try std.testing.expectEqual(expected.payload.rune, actual.payload.rune);
    try std.testing.expectEqualSlices(u64, expected.rotor_state[0..], actual.rotor_state[0..]);
    try std.testing.expectEqual(expected.lexical_slot, actual.lexical_slot);
    try std.testing.expectEqual(expected.semantic_slot, actual.semantic_slot);
    try std.testing.expectEqualSlices(u64, expected.lexical_vector[0..], actual.lexical_vector[0..]);
    try std.testing.expectEqualSlices(u64, expected.semantic_vector[0..], actual.semantic_vector[0..]);
    try std.testing.expectEqual(expected.lexical_tag, actual.lexical_tag);
    try std.testing.expectEqual(expected.semantic_tag, actual.semantic_tag);
    try std.testing.expectEqual(expected.resonance, actual.resonance);
    try std.testing.expectEqual(expected.manager_drift, actual.manager_drift);
    try std.testing.expectEqual(expected.critic_drift, actual.critic_drift);
    try std.testing.expectEqual(expected.drift_passed, actual.drift_passed);
}

fn resetLayer2aBuffers(engine: *vsa_vulkan.VulkanEngine) !void {
    try engine.ensureSigilCapacity(64 * 1024 * 1024);
    @memset(engine.getMatrixData(), 0);
    @memset(engine.getTagsData(), 0);
    @memset(engine.getLatticeData(), 0);
    @memset(std.mem.sliceAsBytes(engine.getSigilDataMutable()), 0);
    @memset(engine.getPanopticonEdgesMutable(), layer2a_gpu.GRAPH_EMPTY);
}

fn expectCandidateScoresEqual(expected: []const layer2a_gpu.CandidateScore, actual: []const layer2a_gpu.CandidateScore) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |lhs, rhs| {
        try std.testing.expectEqualDeep(lhs, rhs);
    }
}

fn expectNeighborhoodScoresEqual(expected: []const layer2a_gpu.NeighborhoodScore, actual: []const layer2a_gpu.NeighborhoodScore) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |lhs, rhs| {
        try std.testing.expectEqualDeep(lhs, rhs);
    }
}

test "single-rune CPU and GPU etch agree bit-for-bit" {
    const allocator = std.testing.allocator;
    const payload = GoldenPayload{};
    var trace = try PhaseTrace.init("single-rune CPU and GPU etch agree bit-for-bit");
    defer trace.finish();

    trace.begin("init runtime");
    const engine = try vsa_vulkan.initRuntime(allocator);
    defer vsa_vulkan.deinitRuntime();
    trace.end("init runtime");

    trace.begin("clear gpu buffers");
    const gpu_matrix = engine.getMatrixData();
    const gpu_tags = engine.getTagsData();
    const gpu_lattice = engine.getLatticeData();
    @memset(gpu_matrix, 0);
    @memset(gpu_tags, 0);
    @memset(gpu_lattice, 0);
    trace.end("clear gpu buffers");

    trace.begin("allocate cpu mirrors");
    const cpu_matrix = try allocator.alloc(u32, gpu_matrix.len);
    defer allocator.free(cpu_matrix);
    const cpu_tags = try allocator.alloc(u64, gpu_tags.len);
    defer allocator.free(cpu_tags);
    @memset(cpu_matrix, 0);
    @memset(cpu_tags, 0);
    trace.end("allocate cpu mirrors");

    var cpu_meaning = vsa.MeaningMatrix{
        .data = cpu_matrix,
        .tags = cpu_tags,
    };

    trace.begin("build golden soul");
    var soul = try makeGoldenSoul(allocator, payload);
    defer soul.deinit();
    trace.end("build golden soul");

    trace.begin("cpu etch reference");
    const lexical_slot = try cpuEtchSlotFull(&cpu_meaning, soul.spatial_rotor, payload.lexical, payload.rune);
    const semantic_slot = try cpuEtchSlotFull(&cpu_meaning, soul.spatial_rotor, payload.semantic, payload.rune);
    trace.end("cpu etch reference");

    trace.begin("prepare gpu dispatch");
    var rotors: [18]u64 = undefined;
    const spatial_state: [16]u64 = soul.spatial_rotor.state;
    @memcpy(rotors[0..16], spatial_state[0..16]);
    rotors[16] = payload.lexical;
    rotors[17] = payload.semantic;

    const chars = [_]u32{payload.rune};
    const indices = [_]u32{0};

    engine.setTier(4);
    trace.end("prepare gpu dispatch");

    trace.begin("gpu etch dispatch");
    try dispatchSingleEtch(engine, rotors[0..], chars[0..], indices[0..]);
    trace.end("gpu etch dispatch");

    // The matrix and tags buffers are host-visible and mapped.
    trace.begin("compare cpu and gpu results");
    var gpu_meaning = vsa.MeaningMatrix{
        .data = gpu_matrix,
        .tags = gpu_tags,
    };

    const cpu_lex_vector = hvWords(cpu_meaning.collapseToBinaryAtSlot(lexical_slot));
    const gpu_lex_vector = hvWords(gpu_meaning.collapseToBinaryAtSlot(lexical_slot));
    try std.testing.expectEqualSlices(u64, cpu_lex_vector[0..], gpu_lex_vector[0..]);

    const cpu_sem_vector = hvWords(cpu_meaning.collapseToBinaryAtSlot(semantic_slot));
    const gpu_sem_vector = hvWords(gpu_meaning.collapseToBinaryAtSlot(semantic_slot));
    try std.testing.expectEqualSlices(u64, cpu_sem_vector[0..], gpu_sem_vector[0..]);

    try std.testing.expectEqual(cpu_tags[lexical_slot], gpu_tags[lexical_slot]);
    try std.testing.expectEqual(cpu_tags[semantic_slot], gpu_tags[semantic_slot]);

    const local_snapshot = makeSnapshot(
        payload,
        soul,
        lexical_slot,
        semantic_slot,
        cpu_lex_vector,
        cpu_sem_vector,
        cpu_tags[lexical_slot],
        cpu_tags[semantic_slot],
    );
    try std.testing.expectEqual(
        vsa.calculateResonance(cpu_lex_vector, cpu_sem_vector),
        local_snapshot.resonance,
    );
    const drift = vsa.dualDriftCheck(cpu_lex_vector, cpu_sem_vector, 512, 512);
    try std.testing.expectEqual(drift.manager_drift, local_snapshot.manager_drift);
    try std.testing.expectEqual(drift.critic_drift, local_snapshot.critic_drift);
    try std.testing.expectEqual(@intFromBool(drift.passed), local_snapshot.drift_passed);

    if (builtin.os.tag == .linux) {
        if (try readGoldenFixture(allocator)) |golden| {
            std.debug.print("[PARITY] compare windows fixture\n", .{});
            try expectGoldenParity(golden, local_snapshot);
        }
    }
    trace.end("compare cpu and gpu results");
}

test "layer2a candidate scoring matches exact cpu reference" {
    const allocator = std.testing.allocator;
    var trace = try PhaseTrace.init("layer2a candidate scoring matches exact cpu reference");
    defer trace.finish();

    trace.begin("init runtime");
    const engine = try vsa_vulkan.initRuntime(allocator);
    defer vsa_vulkan.deinitRuntime();
    trace.end("init runtime");

    trace.begin("reset layer2a buffers");
    try resetLayer2aBuffers(engine);
    trace.end("reset layer2a buffers");

    trace.begin("prepare candidate inputs");
    const helper = layer2a_gpu.Layer2aGpu.init(engine);
    const state = try layer2a_gpu.StateView.initFromVulkan(engine);
    const chars = [_]u32{ 'a', 'b', '(', ')' };
    var expected_storage: [layer2a_gpu.MAX_CANDIDATES]layer2a_gpu.CandidateScore = undefined;
    var actual_storage: [layer2a_gpu.MAX_CANDIDATES]layer2a_gpu.CandidateScore = undefined;
    trace.end("prepare candidate inputs");

    trace.begin("candidate cpu reference");
    const expected = try layer2a_gpu.scoreCandidatesReference(state, 0xDEADBEEFCAFEBABE, 0x8BADF00D0D15EA5E, &chars, expected_storage[0..chars.len]);
    trace.end("candidate cpu reference");

    trace.begin("candidate gpu dispatch");
    const actual = try helper.scoreCandidates(0xDEADBEEFCAFEBABE, 0x8BADF00D0D15EA5E, &chars, actual_storage[0..chars.len]);
    trace.end("candidate gpu dispatch");

    trace.begin("candidate result compare");
    try expectCandidateScoresEqual(expected, actual);
    trace.end("candidate result compare");

    var run_index: usize = 0;
    while (run_index < 4) : (run_index += 1) {
        trace.begin("candidate stability rerun");
        const repeated = try helper.scoreCandidates(0xDEADBEEFCAFEBABE, 0x8BADF00D0D15EA5E, &chars, actual_storage[0..chars.len]);
        try expectCandidateScoresEqual(actual, repeated);
        trace.end("candidate stability rerun");
    }
}

test "layer2a neighborhood scoring matches exact cpu reference" {
    const allocator = std.testing.allocator;
    var trace = try PhaseTrace.init("layer2a neighborhood scoring matches exact cpu reference");
    defer trace.finish();

    trace.begin("init runtime");
    const engine = try vsa_vulkan.initRuntime(allocator);
    defer vsa_vulkan.deinitRuntime();
    trace.end("init runtime");

    trace.begin("reset layer2a buffers");
    try resetLayer2aBuffers(engine);
    trace.end("reset layer2a buffers");

    trace.begin("prepare neighborhood inputs");
    const helper = layer2a_gpu.Layer2aGpu.init(engine);
    const state = try layer2a_gpu.StateView.initFromVulkan(engine);
    const chars = [_]u32{ 'x', 'y', '[', ']' };
    var expected_storage: [layer2a_gpu.MAX_CANDIDATES]layer2a_gpu.NeighborhoodScore = undefined;
    var actual_storage: [layer2a_gpu.MAX_CANDIDATES]layer2a_gpu.NeighborhoodScore = undefined;
    trace.end("prepare neighborhood inputs");

    trace.begin("neighborhood cpu reference");
    const expected = try layer2a_gpu.scoreNeighborhoodsReference(state, 0x1111222233334444, 0x5555666677778888, &chars, expected_storage[0..chars.len]);
    trace.end("neighborhood cpu reference");

    trace.begin("neighborhood gpu dispatch");
    const actual = try helper.scoreNeighborhoods(0x1111222233334444, 0x5555666677778888, &chars, actual_storage[0..chars.len]);
    trace.end("neighborhood gpu dispatch");

    trace.begin("neighborhood result compare");
    try expectNeighborhoodScoresEqual(expected, actual);
    trace.end("neighborhood result compare");

    var run_index: usize = 0;
    while (run_index < 4) : (run_index += 1) {
        trace.begin("neighborhood stability rerun");
        const repeated = try helper.scoreNeighborhoods(0x1111222233334444, 0x5555666677778888, &chars, actual_storage[0..chars.len]);
        try expectNeighborhoodScoresEqual(actual, repeated);
        trace.end("neighborhood stability rerun");
    }
}

test "layer2a contradiction filtering matches exact cpu reference" {
    const allocator = std.testing.allocator;
    var trace = try PhaseTrace.init("layer2a contradiction filtering matches exact cpu reference");
    defer trace.finish();

    trace.begin("init runtime");
    const engine = try vsa_vulkan.initRuntime(allocator);
    defer vsa_vulkan.deinitRuntime();
    trace.end("init runtime");

    trace.begin("reset layer2a buffers");
    try resetLayer2aBuffers(engine);
    trace.end("reset layer2a buffers");

    trace.begin("prepare contradiction inputs");
    const helper = layer2a_gpu.Layer2aGpu.init(engine);
    const candidates = [_]layer2a_gpu.CandidateScore{
        .{ .char_code = 'x', .score = 700 },
        .{ .char_code = 'y', .score = 700 },
        .{ .char_code = 'z', .score = 12 },
    };
    trace.end("prepare contradiction inputs");

    trace.begin("contradiction cpu reference");
    const expected = layer2a_gpu.filterContradictionsReference(&candidates);
    trace.end("contradiction cpu reference");

    trace.begin("contradiction gpu dispatch");
    const actual = try helper.filterContradictions(&candidates);
    trace.end("contradiction gpu dispatch");

    trace.begin("contradiction result compare");
    try std.testing.expectEqualDeep(expected, actual);
    trace.end("contradiction result compare");

    var run_index: usize = 0;
    while (run_index < 4) : (run_index += 1) {
        trace.begin("contradiction stability rerun");
        const repeated = try helper.filterContradictions(&candidates);
        try std.testing.expectEqualDeep(actual, repeated);
        trace.end("contradiction stability rerun");
    }
}
