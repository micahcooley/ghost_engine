const std = @import("std");
const gemma_config = @import("config.zig");
const weights = @import("weights.zig");

pub const ModelShape = struct {
    architecture: []const u8,
    block_count: usize,
    embedding_length: usize,
    feed_forward_length: ?usize,
    feed_forward_length_count: usize,
    attention_head_count: usize,
    attention_head_count_kv: usize,
    attention_key_length: usize,
    attention_key_length_swa: usize,
    attention_value_length: usize,
    attention_value_length_swa: usize,
    embedding_length_per_layer_input: usize,
    context_length: usize,

    pub fn fromLoader(loader: *const weights.GGUFLoader) !ModelShape {
        const architecture = try metadataString(loader, "general.architecture");
        if (!std.mem.eql(u8, architecture, gemma_config.supported_architecture)) return error.UnsupportedArchitecture;
        return .{
            .architecture = architecture,
            .block_count = try metadataUsize(loader, "gemma4.block_count"),
            .embedding_length = try metadataUsize(loader, "gemma4.embedding_length"),
            .feed_forward_length = metadataOptionalUsize(loader, "gemma4.feed_forward_length") catch null,
            .feed_forward_length_count = try metadataArrayOrScalarCount(loader, "gemma4.feed_forward_length"),
            .attention_head_count = try metadataUsize(loader, "gemma4.attention.head_count"),
            .attention_head_count_kv = try metadataUsize(loader, "gemma4.attention.head_count_kv"),
            .attention_key_length = try metadataUsize(loader, "gemma4.attention.key_length"),
            .attention_key_length_swa = try metadataUsize(loader, "gemma4.attention.key_length_swa"),
            .attention_value_length = try metadataUsize(loader, "gemma4.attention.value_length"),
            .attention_value_length_swa = try metadataUsize(loader, "gemma4.attention.value_length_swa"),
            .embedding_length_per_layer_input = try metadataUsize(loader, "gemma4.embedding_length_per_layer_input"),
            .context_length = try metadataUsize(loader, "gemma4.context_length"),
        };
    }

    pub fn validateE2B(self: ModelShape) !void {
        if (self.block_count != gemma_config.default_block_count) return error.UnexpectedBlockCount;
        if (self.embedding_length != gemma_config.default_embedding_length) return error.UnexpectedEmbeddingLength;
        if (self.attention_head_count != gemma_config.default_attention_head_count) return error.UnexpectedAttentionHeadCount;
        if (self.attention_head_count_kv != gemma_config.default_attention_head_count_kv) return error.UnexpectedAttentionHeadCountKv;
        if (self.feed_forward_length_count != gemma_config.default_block_count) return error.UnexpectedFeedForwardLengthCount;
    }

    pub fn feedForwardLengthForLayer(self: ModelShape, layer_idx: usize) !usize {
        if (layer_idx >= self.block_count) return error.LayerOutOfRange;
        if (layer_idx < gemma_config.default_ffn_dim_by_layer.len) return gemma_config.default_ffn_dim_by_layer[layer_idx];
        return self.feed_forward_length orelse error.MissingFeedForwardLength;
    }
};

pub const GhostGemmaModel = struct {
    shape: ModelShape,
    attention_top_k: usize = gemma_config.default_attention_top_k,

    pub fn initFromLoader(loader: *const weights.GGUFLoader) !GhostGemmaModel {
        return .{ .shape = try ModelShape.fromLoader(loader) };
    }
};

fn metadataUsize(loader: *const weights.GGUFLoader, key: []const u8) !usize {
    const value = loader.metadataValue(key) orelse return error.MissingMetadata;
    return switch (value) {
        .uint => |v| checkedU64ToUsize(v),
        .int => |v| if (v >= 0) checkedU64ToUsize(@intCast(v)) else error.InvalidMetadataValue,
        else => error.InvalidMetadataValue,
    };
}

fn metadataOptionalUsize(loader: *const weights.GGUFLoader, key: []const u8) !usize {
    return metadataUsize(loader, key);
}

fn metadataArrayOrScalarCount(loader: *const weights.GGUFLoader, key: []const u8) !usize {
    const value = loader.metadataValue(key) orelse return error.MissingMetadata;
    return switch (value) {
        .uint, .int => 1,
        .array => |v| checkedU64ToUsize(v.len),
        else => error.InvalidMetadataValue,
    };
}

fn metadataString(loader: *const weights.GGUFLoader, key: []const u8) ![]const u8 {
    const value = loader.metadataValue(key) orelse return error.MissingMetadata;
    return switch (value) {
        .string => |v| v,
        else => error.InvalidMetadataValue,
    };
}

fn checkedU64ToUsize(value: u64) !usize {
    if (value > std.math.maxInt(usize)) return error.IntegerOverflow;
    return @intCast(value);
}
