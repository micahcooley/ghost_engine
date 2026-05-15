const std = @import("std");
const context_provider = @import("context_provider.zig");
const gemma_config = @import("config.zig");
const attention = @import("layers/attention.zig");
const rms_norm = @import("layers/rms_norm.zig");
const rune_encoder = @import("rune_encoder.zig");
const rune_head = @import("layers/rune_head.zig");
const swiglu = @import("layers/swiglu.zig");
const vsa = @import("../vsa_math.zig");

pub const HarnessState = "read_only_non_authorizing_phase_harness_not_full_model";

pub const ForwardSummary = struct {
    state: []const u8 = HarnessState,
    rune_count: usize,
    embedding_len: usize,
    top_k: usize,
    attention_total_resonance: f32,
    output_rune: vsa.HyperVector,

    pub fn checksum(self: ForwardSummary) u64 {
        var acc: u64 = 0;
        inline for (0..16) |idx| acc ^= self.output_rune[idx];
        return acc;
    }
};

pub const ReferenceInferenceHarness = struct {
    allocator: std.mem.Allocator,
    embedding_len: usize = gemma_config.default_embedding_length,
    top_k: usize = gemma_config.default_attention_top_k,

    pub fn init(allocator: std.mem.Allocator, embedding_len: usize, top_k: usize) ReferenceInferenceHarness {
        return .{ .allocator = allocator, .embedding_len = embedding_len, .top_k = top_k };
    }

    pub fn forward(self: ReferenceInferenceHarness, input_text: []const u8, session_id: u64) !ForwardSummary {
        const encoder = rune_encoder.RuneEncoder.init(self.allocator, self.embedding_len);
        const runes = try encoder.encode(input_text, session_id);
        defer rune_encoder.freeRunes(self.allocator, runes);
        if (runes.len == 0) return error.EmptyInput;

        const provider = context_provider.GhostContextProvider.init(self.allocator);
        const context = try provider.queryContext(runes[runes.len - 1].vector, runes, self.top_k);
        defer context_provider.freeContext(self.allocator, context);

        const hidden = try self.allocator.alloc(f32, self.embedding_len);
        defer self.allocator.free(hidden);
        const attention_stats = try attention.resonanceWeightedSum(context, hidden);
        try rms_norm.forwardInPlace(hidden, self.embedding_len);

        const ffn = try self.allocator.alloc(f32, self.embedding_len);
        defer self.allocator.free(ffn);
        try swiglu.forward(hidden, hidden, ffn);
        for (hidden, ffn) |*value, residual| value.* += residual;
        try rms_norm.forwardInPlace(hidden, self.embedding_len);

        const head = rune_head.RuneHead{};
        return .{
            .rune_count = runes.len,
            .embedding_len = self.embedding_len,
            .top_k = @min(self.top_k, runes.len),
            .attention_total_resonance = attention_stats.total_resonance,
            .output_rune = head.project(hidden),
        };
    }
};

test "reference inference harness returns deterministic healthy rune" {
    const allocator = std.testing.allocator;
    const harness = ReferenceInferenceHarness.init(allocator, 32, 4);
    const first = try harness.forward("memory allocation heap pointer", 11);
    const second = try harness.forward("memory allocation heap pointer", 11);
    try std.testing.expectEqual(first.output_rune, second.output_rune);
    try std.testing.expect(vsa.isHealthy(first.output_rune));
    try std.testing.expectEqual(@as(usize, 4), first.rune_count);
    try std.testing.expect(first.attention_total_resonance > 0.0);
}
