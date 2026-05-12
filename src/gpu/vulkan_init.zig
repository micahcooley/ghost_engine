const std = @import("std");
const vl = @import("../vulkan_loader.zig");
const vk = vl.vk;

pub const STAGE_GATE_RUNE_THRESHOLD: usize = 512;
pub const VECTOR_BITS: usize = 1024;
pub const VECTOR_WORDS: usize = VECTOR_BITS / 32;

pub const SearchLocation = enum {
    cpu_ram,
    vulkan_vram,
};

pub const StageGateDecision = struct {
    location: SearchLocation,
    rune_count: usize,
    threshold: usize = STAGE_GATE_RUNE_THRESHOLD,

    pub fn usesGpu(self: StageGateDecision) bool {
        return self.location == .vulkan_vram;
    }
};

pub fn stageGate(rune_count: usize) StageGateDecision {
    return .{
        .location = if (rune_count >= STAGE_GATE_RUNE_THRESHOLD) .vulkan_vram else .cpu_ram,
        .rune_count = rune_count,
    };
}

pub const PipelineHandles = struct {
    descriptor_set_layout: vk.VkDescriptorSetLayout = null,
    pipeline_layout: vk.VkPipelineLayout = null,
    pipeline: vk.VkPipeline = null,
};

pub const ComputeRuntime = struct {
    loader: vl.VulkanCtx,
    handles: PipelineHandles = .{},

    pub fn initBasic() !ComputeRuntime {
        return .{ .loader = try vl.VulkanCtx.load() };
    }

    pub fn deinit(self: *ComputeRuntime) void {
        self.loader.unload();
        self.* = undefined;
    }
};

pub const GreRune = extern struct {
    id: u32 = 0,
    flags: u32 = 0,
    reserved0: u32 = 0,
    reserved1: u32 = 0,
    words: [VECTOR_WORDS]u32 = [_]u32{0} ** VECTOR_WORDS,
};

pub fn hammingDistanceWords(query: [VECTOR_WORDS]u32, rune: GreRune) u16 {
    var distance: u32 = 0;
    inline for (0..VECTOR_WORDS) |i| {
        distance += @popCount(query[i] ^ rune.words[i]);
    }
    return @intCast(distance);
}

pub fn wordsFromU64Lanes(lanes: []const u64) [VECTOR_WORDS]u32 {
    var out = [_]u32{0} ** VECTOR_WORDS;
    const lane_count = @min(lanes.len, VECTOR_WORDS / 2);
    for (lanes[0..lane_count], 0..) |lane, idx| {
        out[idx * 2] = @truncate(lane);
        out[idx * 2 + 1] = @intCast(lane >> 32);
    }
    return out;
}

pub fn runeFromU64Lanes(id: u32, flags: u32, lanes: []const u64) GreRune {
    return .{
        .id = id,
        .flags = flags,
        .words = wordsFromU64Lanes(lanes),
    };
}

pub fn hammingSearchCpu(query: [VECTOR_WORDS]u32, runes: []const GreRune, out: []u32) !void {
    if (out.len < runes.len) return error.OutputTooSmall;
    for (runes, 0..) |rune, idx| out[idx] = hammingDistanceWords(query, rune);
}

test "stage gate keeps small sets in RAM and large sets in VRAM" {
    try std.testing.expect(!stageGate(STAGE_GATE_RUNE_THRESHOLD - 1).usesGpu());
    try std.testing.expect(stageGate(STAGE_GATE_RUNE_THRESHOLD).usesGpu());
}

test "cpu parity helper matches shader hamming contract" {
    const q = [_]u32{0xffff_ffff} ** VECTOR_WORDS;
    const r = GreRune{};
    try std.testing.expectEqual(@as(u16, 1024), hammingDistanceWords(q, r));
}

test "u64 lanes expand to shader word layout" {
    const lanes = [_]u64{0x0123_4567_89ab_cdef} ** (VECTOR_WORDS / 2);
    const words = wordsFromU64Lanes(&lanes);
    try std.testing.expectEqual(@as(u32, 0x89ab_cdef), words[0]);
    try std.testing.expectEqual(@as(u32, 0x0123_4567), words[1]);
}

test "cpu hamming search fills caller output" {
    const q = [_]u32{0xffff_ffff} ** VECTOR_WORDS;
    const runes = [_]GreRune{ .{}, runeFromU64Lanes(1, 0, &[_]u64{0xffff_ffff_ffff_ffff} ** (VECTOR_WORDS / 2)) };
    var out: [2]u32 = undefined;
    try hammingSearchCpu(q, &runes, &out);
    try std.testing.expectEqual(@as(u32, 1024), out[0]);
    try std.testing.expectEqual(@as(u32, 0), out[1]);
}
