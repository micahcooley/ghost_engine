const std = @import("std");
const gemma_config = @import("config.zig");
const vsa = @import("../vsa_math.zig");

pub const encoder_seed: u64 = 0x6765_6d6d_615f_7275;
pub const max_segment_bytes: usize = 256;

pub const ConversationRune = struct {
    text: []const u8,
    rotor: [2]u64,
    vector: vsa.HyperVector,
    embedding: []f32,
    session_id: u64 = 0,
    timestamp: i64 = 0,
    resonance_depth: u32 = 0,

    pub fn deinit(self: *ConversationRune, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        allocator.free(self.embedding);
        self.* = undefined;
    }
};

pub const RuneEncoder = struct {
    allocator: std.mem.Allocator,
    embedding_len: usize = gemma_config.default_embedding_length,

    pub fn init(allocator: std.mem.Allocator, embedding_len: usize) RuneEncoder {
        return .{ .allocator = allocator, .embedding_len = embedding_len };
    }

    pub fn encode(self: RuneEncoder, text: []const u8, session_id: u64) ![]ConversationRune {
        var segments = std.ArrayList([]const u8).init(self.allocator);
        defer segments.deinit();
        try segmentWords(self.allocator, text, &segments);

        const runes = try self.allocator.alloc(ConversationRune, segments.items.len);
        var initialized: usize = 0;
        errdefer {
            for (runes[0..initialized]) |*rune| rune.deinit(self.allocator);
            self.allocator.free(runes);
        }

        for (segments.items, 0..) |segment, idx| {
            const owned_text = try self.allocator.dupe(u8, segment);
            errdefer self.allocator.free(owned_text);
            const vector = buildHyperRotor(segment);
            const rotor = rotorPair(vector);
            const embedding = try self.allocator.alloc(f32, self.embedding_len);
            projectDeterministic(vector, embedding);
            runes[idx] = .{
                .text = owned_text,
                .rotor = rotor,
                .vector = vector,
                .embedding = embedding,
                .session_id = session_id,
                .timestamp = std.time.timestamp(),
                .resonance_depth = 0,
            };
            initialized += 1;
        }
        return runes;
    }
};

pub fn freeRunes(allocator: std.mem.Allocator, runes: []ConversationRune) void {
    for (runes) |*rune| rune.deinit(allocator);
    allocator.free(runes);
}

pub fn segmentWords(allocator: std.mem.Allocator, text: []const u8, out: *std.ArrayList([]const u8)) !void {
    _ = allocator;
    // V34: Pure Tokenless Spatial Rotor Ingest.
    // We treat the entire input as a single continuous conceptual stream.
    // Instead of arbitrary slicing, we segment by logical structural hints (BoundaryBytes)
    // while maintaining a sliding spatial context within the hyper-rotor builder.
    var cursor: usize = 0;
    while (cursor < text.len) {
        while (cursor < text.len and isBoundaryByte(text[cursor])) cursor += 1;
        const start = cursor;
        while (cursor < text.len and !isBoundaryByte(text[cursor])) cursor += 1;
        const end = cursor;
        if (end > start) {
            // Each segment is a dense conceptual unit, mapped directly to a Rune.
            try out.append(text[start..end]);
        }
    }
}

pub fn buildHyperRotor(segment: []const u8) vsa.HyperVector {
    // Spatial hyper-rotor: binds each character to its position via permutation
    // then bundles them into a unified conceptual vector.
    var state = vsa.generate(encoder_seed);
    for (segment, 0..) |byte, pos| {
        const char_vec = vsa.generate(byte);
        // Position binding via N-fold permutation
        var pos_vec = char_vec;
        for (0..pos % 15) |_| {
            pos_vec = vsa.permute(pos_vec);
        }
        state = vsa.bundle(state, pos_vec, vsa.generate(encoder_seed ^ @as(u64, byte)));
    }
    return state;
}

pub fn rotorPair(vector: vsa.HyperVector) [2]u64 {
    return .{
        vsa.collapse(vector),
        @as(u64, vsa.projectSpatialSignature(vector)) << 32 | (vector[0] & 0xffff_ffff),
    };
}

pub fn projectDeterministic(vector: vsa.HyperVector, embedding: []f32) void {
    for (embedding, 0..) |*value, idx| {
        const lane = vector[idx % 16];
        const bit_index: u6 = @intCast((idx * 17 + idx / 16) % 64);
        const sign: f32 = if (((lane >> bit_index) & 1) == 1) 1.0 else -1.0;
        const scale = 1.0 / @sqrt(@as(f32, @floatFromInt(embedding.len)));
        value.* = sign * scale;
    }
}

fn isBoundaryByte(byte: u8) bool {
    // Structural hints for the rotor ingest, NOT data-center tokenization.
    return switch (byte) {
        ' ', '\t', '\r', '\n', ',', '.', ';', ':', '!', '?', '(', ')', '[', ']', '{', '}', '"', '\'' => true,
        else => false,
    };
}

test "rune encoder segments and embeds deterministically" {
    const encoder = RuneEncoder.init(std.testing.allocator, 16);
    const first = try encoder.encode("memory allocation memory", 7);
    defer freeRunes(std.testing.allocator, first);
    const second = try encoder.encode("memory allocation memory", 7);
    defer freeRunes(std.testing.allocator, second);
    try std.testing.expectEqual(@as(usize, 3), first.len);
    try std.testing.expectEqualSlices(f32, first[0].embedding, second[0].embedding);
    try std.testing.expectEqual(first[0].rotor[0], second[0].rotor[0]);
}
