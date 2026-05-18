const std = @import("std");
const context_provider = @import("context_provider.zig");
const gemma_config = @import("config.zig");
const attention = @import("layers/attention.zig");
const rms_norm = @import("layers/rms_norm.zig");
const rune_encoder = @import("rune_encoder.zig");
const rune_head = @import("layers/rune_head.zig");
const swiglu = @import("layers/swiglu.zig");
const prose_head = @import("layers/prose_head.zig");
const vsa = @import("../vsa_math.zig");
const weights = @import("weights.zig");
const q8_matmul = @import("q8_matmul.zig");
const concept_index = @import("../concept_index.zig");

pub const HarnessState = "read_only_non_authorizing_phase_harness_not_full_model";

pub const ForwardSummary = struct {
    state: []const u8 = HarnessState,
    rune_count: usize,
    embedding_len: usize,
    top_k: usize,
    attention_total_resonance: f32,
    output_rune: vsa.HyperVector,
    prose: []const u8 = "",

    pub fn deinit(self: ForwardSummary, allocator: std.mem.Allocator) void {
        allocator.free(self.prose);
    }

    pub fn checksum(self: ForwardSummary) u64 {
        var acc: u64 = 0;
        inline for (0..16) |idx| acc ^= self.output_rune[idx];
        return acc;
    }
};

pub const ReferenceInferenceHarness = struct {
    allocator: std.mem.Allocator,
    loader: ?*weights.GGUFLoader = null,
    embedding_len: usize = gemma_config.default_embedding_length,
    top_k: usize = gemma_config.default_attention_top_k,
    concept_idx: ?*const concept_index.ConceptIndex = null,

    pub fn init(allocator: std.mem.Allocator, embedding_len: usize, top_k: usize, concept_idx: ?*const concept_index.ConceptIndex) ReferenceInferenceHarness {
        return .{ .allocator = allocator, .loader = null, .embedding_len = embedding_len, .top_k = top_k, .concept_idx = concept_idx };
    }

    pub fn initWithLoader(allocator: std.mem.Allocator, loader: *weights.GGUFLoader, embedding_len: usize, top_k: usize, concept_idx: ?*const concept_index.ConceptIndex) ReferenceInferenceHarness {
        return .{ .allocator = allocator, .loader = loader, .embedding_len = embedding_len, .top_k = top_k, .concept_idx = concept_idx };
    }

    pub fn forward(self: ReferenceInferenceHarness, input_text: []const u8, session_id: u64) !ForwardSummary {
        const encoder = rune_encoder.RuneEncoder.init(self.allocator, self.embedding_len);
        const runes = try encoder.encode(input_text, session_id);
        defer rune_encoder.freeRunes(self.allocator, runes);
        if (runes.len == 0) return error.EmptyInput;

        const provider = context_provider.GhostContextProvider.init(self.allocator, self.concept_idx);
        // We query the meaning matrix for context based on the unified conceptual state of the input
        const context = try provider.queryContext(runes[runes.len - 1].vector, runes, self.top_k);
        defer context_provider.freeContext(self.allocator, context);

        var total_resonance: f32 = 0.0;
        var out_rune: vsa.HyperVector = @splat(@as(u64, 0));
        var state_msg: []const u8 = HarnessState;

        const v_engine = @import("../vsa_vulkan.zig").getEngine();
        if (v_engine != null and v_engine.?.gemmaPipelinesReady() and v_engine.?.gemma_state != null) {
            const ve = v_engine.?;
            const embeddings = try self.allocator.alloc(f32, context.len * self.embedding_len);
            defer self.allocator.free(embeddings);
            const resonance = try self.allocator.alloc(f32, context.len);
            defer self.allocator.free(resonance);
            
            for (context, 0..) |entry, i| {
                @memcpy(embeddings[i * self.embedding_len .. (i + 1) * self.embedding_len], entry.embedding);
                resonance[i] = entry.resonance;
            }
            
            out_rune = try ve.executeGemmaForward(embeddings, resonance);
            state_msg = "vulkan_accelerated_sovereign_inference";
            total_resonance = @as(f32, @floatFromInt(context.len)) * 1.0;
        } else {
            const hidden = try self.allocator.alloc(f32, self.embedding_len);
            defer self.allocator.free(hidden);
            @memset(hidden, 0.0);

            if (context.len > 0) {
                @memcpy(hidden, context[0].embedding);
            }
            try rms_norm.forwardInPlace(hidden, self.embedding_len);

            if (self.loader) |ld| {
                state_msg = "active_gguf_weights_authorizing_phase_harness";
                for (0..35) |layer_idx| {
                    // ── 1. Layer-Specific Q/K/V Memory Lattice Attention ──
                    const q_name = try std.fmt.allocPrint(self.allocator, "blk.{d}.attn_q.weight", .{layer_idx});
                    defer self.allocator.free(q_name);
                    const k_name = try std.fmt.allocPrint(self.allocator, "blk.{d}.attn_k.weight", .{layer_idx});
                    defer self.allocator.free(k_name);
                    const v_name = try std.fmt.allocPrint(self.allocator, "blk.{d}.attn_v.weight", .{layer_idx});
                    defer self.allocator.free(v_name);
                    const out_name = try std.fmt.allocPrint(self.allocator, "blk.{d}.attn_output.weight", .{layer_idx});
                    defer self.allocator.free(out_name);

                    if (ld.getTensor(q_name) catch null) |q_view| {
                        const k_view = ld.getTensor(k_name) catch return error.MissingGGUFTensor;
                        const v_view = ld.getTensor(v_name) catch return error.MissingGGUFTensor;
                        const out_view = ld.getTensor(out_name) catch return error.MissingGGUFTensor;

                        const q_out = try self.allocator.alloc(f32, 2048);
                        defer self.allocator.free(q_out);
                        try q8_matmul.matmulQ8_0Vector(q_view, hidden, q_out);

                        var max_score: f32 = -1e9;
                        const scores = try self.allocator.alloc(f32, context.len);
                        defer self.allocator.free(scores);

                        const weighted_v = try self.allocator.alloc(f32, 2048);
                        defer self.allocator.free(weighted_v);
                        @memset(weighted_v, 0.0);

                        for (context, 0..) |entry, c_idx| {
                            const k_full = try self.allocator.alloc(f32, 2048);
                            defer self.allocator.free(k_full);
                            try q8_matmul.matmulQ8_0Vector(k_view, entry.embedding, k_full);

                            const v_full = try self.allocator.alloc(f32, 2048);
                            defer self.allocator.free(v_full);
                            try q8_matmul.matmulQ8_0Vector(v_view, entry.embedding, v_full);
                            
                            var entry_total_s: f32 = 0.0;
                            for (0..8) |head_idx| {
                                const head_base = head_idx * 256;
                                var dot: f32 = 0.0;
                                for (0..256) |i| dot += q_out[head_base + i] * k_full[head_base + i];
                                const score = (dot / 16.0) * @max(entry.resonance, 0.01);
                                if (score > max_score) max_score = score;
                                
                                const s = @exp(score - max_score);
                                entry_total_s += s;
                                for (0..256) |i| weighted_v[head_base + i] += v_full[head_base + i] * s;
                            }
                            scores[c_idx] = entry_total_s;
                        }

                        var sum_exp: f32 = 0.0;
                        for (scores) |s| sum_exp += s;
                        for (weighted_v) |*val| val.* /= (sum_exp + 1e-9);

                        const projected_attn = try self.allocator.alloc(f32, self.embedding_len);
                        defer self.allocator.free(projected_attn);
                        try q8_matmul.matmulQ8_0Vector(out_view, weighted_v, projected_attn);
                        for (hidden, projected_attn) |*val, res| val.* += res;
                        total_resonance += @as(f32, @floatFromInt(context.len));
                    }
                    try rms_norm.forwardInPlace(hidden, self.embedding_len);

                    // ── 2. SwiGLU FFN Pass ──
                    const up_name = try std.fmt.allocPrint(self.allocator, "blk.{d}.ffn_up.weight", .{layer_idx});
                    defer self.allocator.free(up_name);
                    const gate_name = try std.fmt.allocPrint(self.allocator, "blk.{d}.ffn_gate.weight", .{layer_idx});
                    defer self.allocator.free(gate_name);
                    const down_name = try std.fmt.allocPrint(self.allocator, "blk.{d}.ffn_down.weight", .{layer_idx});
                    defer self.allocator.free(down_name);

                    const up_view = try ld.getTensor(up_name);
                    const gate_view = try ld.getTensor(gate_name);
                    const down_view = try ld.getTensor(down_name);

                    const ffn_dim = up_view.info.dimensions[1];
                    const up_out = try self.allocator.alloc(f32, ffn_dim);
                    defer self.allocator.free(up_out);
                    const gate_out = try self.allocator.alloc(f32, ffn_dim);
                    defer self.allocator.free(gate_out);
                    const swiglu_out = try self.allocator.alloc(f32, ffn_dim);
                    defer self.allocator.free(swiglu_out);
                    const ffn = try self.allocator.alloc(f32, self.embedding_len);
                    defer self.allocator.free(ffn);

                    try q8_matmul.matmulQ8_0Vector(up_view, hidden, up_out);
                    try q8_matmul.matmulQ8_0Vector(gate_view, hidden, gate_out);
                    try swiglu.forward(gate_out, up_out, swiglu_out);
                    try q8_matmul.matmulQ8_0Vector(down_view, swiglu_out, ffn);

                    for (hidden, ffn) |*value, residual| value.* += residual;
                    try rms_norm.forwardInPlace(hidden, self.embedding_len);
                }
            } else {
                const ffn = try self.allocator.alloc(f32, self.embedding_len);
                defer self.allocator.free(ffn);
                
                for (0..35) |_| {
                    const attn_out = try self.allocator.alloc(f32, self.embedding_len);
                    defer self.allocator.free(attn_out);
                    const stats = try attention.resonanceWeightedSum(context, attn_out);
                    total_resonance += stats.total_resonance;

                    for (hidden, attn_out) |*val, res| val.* += res;
                    try rms_norm.forwardInPlace(hidden, self.embedding_len);

                    try swiglu.forward(hidden, hidden, ffn);
                    for (hidden, ffn) |*value, residual| value.* += residual;
                    try rms_norm.forwardInPlace(hidden, self.embedding_len);
                }
            }

            const head = rune_head.RuneHead{};
            out_rune = head.project(hidden);
        }

        const phead = prose_head.ProseHead.init(self.allocator);
        const synthesized_prose = try phead.synthesize(out_rune, context);

        return .{
            .state = state_msg,
            .rune_count = runes.len,
            .embedding_len = self.embedding_len,
            .top_k = @min(self.top_k, runes.len),
            .attention_total_resonance = total_resonance,
            .output_rune = out_rune,
            .prose = synthesized_prose,
        };
    }
};

test "reference inference harness returns deterministic healthy rune" {
    const allocator = std.testing.allocator;
    const harness = ReferenceInferenceHarness.init(allocator, 32, 4, null);
    const first = try harness.forward("memory allocation heap pointer", 11);
    defer first.deinit(allocator);
    const second = try harness.forward("memory allocation heap pointer", 11);
    defer second.deinit(allocator);
    try std.testing.expectEqual(first.output_rune, second.output_rune);
    try std.testing.expect(vsa.isHealthy(first.output_rune));
    try std.testing.expectEqual(@as(usize, 4), first.rune_count);
    try std.testing.expect(first.attention_total_resonance > 0.0);
}
