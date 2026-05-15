const std = @import("std");
const gemma_config = @import("config.zig");
const model = @import("model.zig");

pub const Stage = enum {
    rune_embed,
    attn_norm,
    attn_q,
    attn_k,
    attn_v,
    ghost_attention,
    attn_output,
    post_attention_norm,
    ffn_norm,
    ffn_gate,
    ffn_up,
    swiglu,
    ffn_down,
    post_ffw_norm,
    post_norm,
    rune_project,

    pub fn shaderName(self: Stage) []const u8 {
        return switch (self) {
            .rune_embed => "rune_embed",
            .attn_norm, .post_attention_norm, .ffn_norm, .post_ffw_norm, .post_norm => "rms_norm",
            .attn_q, .attn_k, .attn_v, .attn_output, .ffn_gate, .ffn_up, .ffn_down => "matmul_q8_0",
            .ghost_attention => "ghost_attention",
            .swiglu => "swiglu",
            .rune_project => "rune_project",
        };
    }
};

pub const Step = struct {
    stage: Stage,
    layer: ?u16 = null,
    embedding_len: usize,
    ffn_dim: usize = 0,
    q_width: usize = 0,
    kv_width: usize = 0,
};

pub const Schedule = struct {
    steps: []Step,
    block_count: usize,
    embedding_len: usize,

    pub fn deinit(self: *Schedule, allocator: std.mem.Allocator) void {
        allocator.free(self.steps);
        self.* = undefined;
    }
};

pub fn build(allocator: std.mem.Allocator, shape: model.ModelShape) !Schedule {
    try shape.validateE2B();

    var steps = std.ArrayList(Step).init(allocator);
    errdefer steps.deinit();

    try steps.append(.{ .stage = .rune_embed, .embedding_len = shape.embedding_length });
    for (0..shape.block_count) |layer| {
        const ffn_dim = try shape.feedForwardLengthForLayer(layer);
        const full_attention = usesFullAttention(layer);
        const head_width = if (full_attention) shape.attention_key_length else shape.attention_key_length_swa;
        const value_width = if (full_attention) shape.attention_value_length else shape.attention_value_length_swa;
        const q_width = shape.attention_head_count * head_width;
        const kv_width = shape.attention_head_count_kv * value_width;
        const layer_u16: u16 = @intCast(layer);

        try steps.append(.{ .stage = .attn_norm, .layer = layer_u16, .embedding_len = shape.embedding_length });
        try steps.append(.{ .stage = .attn_q, .layer = layer_u16, .embedding_len = shape.embedding_length, .q_width = q_width, .kv_width = kv_width });
        try steps.append(.{ .stage = .attn_k, .layer = layer_u16, .embedding_len = shape.embedding_length, .q_width = q_width, .kv_width = kv_width });
        try steps.append(.{ .stage = .attn_v, .layer = layer_u16, .embedding_len = shape.embedding_length, .q_width = q_width, .kv_width = kv_width });
        try steps.append(.{ .stage = .ghost_attention, .layer = layer_u16, .embedding_len = shape.embedding_length, .q_width = q_width, .kv_width = kv_width });
        try steps.append(.{ .stage = .attn_output, .layer = layer_u16, .embedding_len = shape.embedding_length, .q_width = q_width, .kv_width = kv_width });
        try steps.append(.{ .stage = .post_attention_norm, .layer = layer_u16, .embedding_len = shape.embedding_length });
        try steps.append(.{ .stage = .ffn_norm, .layer = layer_u16, .embedding_len = shape.embedding_length, .ffn_dim = ffn_dim });
        try steps.append(.{ .stage = .ffn_gate, .layer = layer_u16, .embedding_len = shape.embedding_length, .ffn_dim = ffn_dim });
        try steps.append(.{ .stage = .ffn_up, .layer = layer_u16, .embedding_len = shape.embedding_length, .ffn_dim = ffn_dim });
        try steps.append(.{ .stage = .swiglu, .layer = layer_u16, .embedding_len = shape.embedding_length, .ffn_dim = ffn_dim });
        try steps.append(.{ .stage = .ffn_down, .layer = layer_u16, .embedding_len = shape.embedding_length, .ffn_dim = ffn_dim });
        try steps.append(.{ .stage = .post_ffw_norm, .layer = layer_u16, .embedding_len = shape.embedding_length });
        try steps.append(.{ .stage = .post_norm, .layer = layer_u16, .embedding_len = shape.embedding_length });
    }
    try steps.append(.{ .stage = .rune_project, .embedding_len = shape.embedding_length });

    return .{
        .steps = try steps.toOwnedSlice(),
        .block_count = shape.block_count,
        .embedding_len = shape.embedding_length,
    };
}

pub fn usesFullAttention(layer_idx: usize) bool {
    return layer_idx % 5 == 4;
}

test "schedule wires all 35 Gemma blocks" {
    const shape = model.ModelShape{
        .architecture = gemma_config.supported_architecture,
        .block_count = gemma_config.default_block_count,
        .embedding_length = gemma_config.default_embedding_length,
        .feed_forward_length = null,
        .feed_forward_length_count = gemma_config.default_block_count,
        .attention_head_count = gemma_config.default_attention_head_count,
        .attention_head_count_kv = gemma_config.default_attention_head_count_kv,
        .attention_key_length = gemma_config.default_attention_key_length,
        .attention_key_length_swa = gemma_config.default_attention_key_length_swa,
        .attention_value_length = gemma_config.default_attention_value_length,
        .attention_value_length_swa = gemma_config.default_attention_value_length_swa,
        .embedding_length_per_layer_input = gemma_config.default_embedding_length_per_layer_input,
        .context_length = 131072,
    };
    var schedule = try build(std.testing.allocator, shape);
    defer schedule.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 492), schedule.steps.len);
    try std.testing.expectEqual(Stage.rune_embed, schedule.steps[0].stage);
    try std.testing.expectEqual(Stage.rune_project, schedule.steps[schedule.steps.len - 1].stage);
    try std.testing.expectEqual(@as(usize, 6144), schedule.steps[8].ffn_dim);
    try std.testing.expectEqual(@as(usize, 2048), schedule.steps[2].q_width);
    const layer34_attn_q = 1 + 34 * 14 + 1;
    try std.testing.expectEqual(@as(usize, 4096), schedule.steps[layer34_attn_q].q_width);
    const layer34_ffn_gate = 1 + 34 * 14 + 8;
    try std.testing.expectEqual(@as(usize, 12288), schedule.steps[layer34_ffn_gate].ffn_dim);
}
