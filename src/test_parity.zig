const std = @import("std");
const vsa = @import("vsa_core.zig");
const ghost_state = @import("ghost_state.zig");
const vsa_vulkan = @import("vsa_vulkan.zig");
const vl = @import("vulkan_loader.zig");
const vk = vl.vk;

const GoldenPayload = struct {
    lexical: u64 = 0xDEADBEEFCAFEBABE,
    semantic: u64 = 0x8BADF00D0D15EA5E,
    rune: u32 = 'X',
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

fn dispatchSingleEtch(engine: *vsa_vulkan.VulkanEngine, rotors: []const u64, chars: []const u32, indices: []const u32) !void {
    const frame = engine.frame_idx;

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

    var submit_info = std.mem.zeroes(vk.VkSubmitInfo);
    submit_info.sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO;
    submit_info.commandBufferCount = 1;
    submit_info.pCommandBuffers = &engine.command_buffers[frame];
    try vkCheck(engine.vk_ctx.vkQueueSubmit.?(engine.queue, 1, &submit_info, engine.fences[frame]));

    try engine.waitForHardwareInterrupt(frame);
    engine.frame_idx = (engine.frame_idx + 1) % vsa_vulkan.FRAME_COUNT;

    _ = wg_size;
}

test "single-rune CPU and GPU etch agree bit-for-bit" {
    const allocator = std.testing.allocator;
    const payload = GoldenPayload{};

    const engine = try vsa_vulkan.initRuntime(allocator, std.testing.io);
    defer vsa_vulkan.deinitRuntime();

    const gpu_matrix = engine.getMatrixData();
    const gpu_tags = engine.getTagsData();
    const gpu_lattice = engine.getLatticeData();
    @memset(gpu_matrix, 0);
    @memset(gpu_tags, 0);
    @memset(gpu_lattice, 0);

    const cpu_matrix = try allocator.alloc(u32, gpu_matrix.len);
    defer allocator.free(cpu_matrix);
    const cpu_tags = try allocator.alloc(u64, gpu_tags.len);
    defer allocator.free(cpu_tags);
    @memset(cpu_matrix, 0);
    @memset(cpu_tags, 0);

    var cpu_meaning = vsa.MeaningMatrix{
        .data = cpu_matrix,
        .tags = cpu_tags,
    };

    var soul = try makeGoldenSoul(allocator, payload);
    defer soul.deinit();

    const lexical_slot = try cpuEtchSlotFull(&cpu_meaning, soul.spatial_rotor, payload.lexical, payload.rune);
    const semantic_slot = try cpuEtchSlotFull(&cpu_meaning, soul.spatial_rotor, payload.semantic, payload.rune);

    var rotors: [18]u64 = undefined;
    const spatial_state: [16]u64 = soul.spatial_rotor.state;
    @memcpy(rotors[0..16], spatial_state[0..16]);
    rotors[16] = payload.lexical;
    rotors[17] = payload.semantic;

    const chars = [_]u32{payload.rune};
    const indices = [_]u32{0};

    engine.setTier(4);
    try dispatchSingleEtch(engine, rotors[0..], chars[0..], indices[0..]);

    // The matrix and tags buffers are host-visible and mapped.
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
}
