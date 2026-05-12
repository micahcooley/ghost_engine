const std = @import("std");

pub const RUNE_BITS: usize = 1024;
pub const RUNE_BYTES: usize = RUNE_BITS / 8;
pub const CHUNK_BITS: usize = 512;
pub const CHUNK_BYTES: usize = CHUNK_BITS / 8;

pub const RuneVector = @Vector(RUNE_BITS, u1);
pub const ChunkVector = @Vector(CHUNK_BITS, u1);
pub const RuneBytes = [RUNE_BYTES]u8;

pub const RUNE_ALIGNMENT: usize = @max(@alignOf(RuneVector), @alignOf(ChunkVector));

comptime {
    std.debug.assert(@sizeOf(RuneVector) == RUNE_BYTES);
    std.debug.assert(@sizeOf(ChunkVector) == CHUNK_BYTES);
    std.debug.assert(RUNE_BYTES == CHUNK_BYTES * 2);
}

pub const ByteClass = enum {
    legacy_ascii,
    intent_class,
    epistemic_tag,
    hyper_bitstream,
};

pub const IntentClass = enum(u8) {
    audio_dsp = 0x81,
    logic_verification = 0x82,
    hardware_abstraction = 0x83,
    software_engineering = 0x84,
    world_model = 0x85,

    pub fn fromByte(byte: u8) ?IntentClass {
        return switch (byte) {
            0x81 => .audio_dsp,
            0x82 => .logic_verification,
            0x83 => .hardware_abstraction,
            0x84 => .software_engineering,
            0x85 => .world_model,
            else => null,
        };
    }
};

pub const EpistemicTag = enum(u8) {
    verified = 0xA1,
    shadow = 0xA2,
    hive_derived = 0xA3,
    unverified = 0xA4,

    pub fn fromByte(byte: u8) ?EpistemicTag {
        return switch (byte) {
            0xA1 => .verified,
            0xA2 => .shadow,
            0xA3 => .hive_derived,
            0xA4 => .unverified,
            else => null,
        };
    }
};

pub const RuneView = struct {
    offset: usize,
    bytes: *align(RUNE_ALIGNMENT) const RuneBytes,

    pub inline fn vectorPtr(self: RuneView) *align(RUNE_ALIGNMENT) const RuneVector {
        return @ptrCast(self.bytes);
    }

    pub inline fn vector(self: RuneView) RuneVector {
        return self.vectorPtr().*;
    }

    pub inline fn chunkPtr(self: RuneView, index: u1) *align(@alignOf(ChunkVector)) const ChunkVector {
        const byte_offset = @as(usize, index) * CHUNK_BYTES;
        const ptr = self.bytes[byte_offset .. byte_offset + CHUNK_BYTES].ptr;
        return @ptrCast(@alignCast(ptr));
    }

    pub inline fn chunk(self: RuneView, index: u1) ChunkVector {
        return self.chunkPtr(index).*;
    }
};

pub const Token = union(enum) {
    legacy_ascii: u8,
    intent_class: u8,
    epistemic_tag: u8,
    rune: RuneView,
};

pub const Parser = struct {
    input: []const u8,
    cursor: usize = 0,

    pub fn init(input: []const u8) Parser {
        return .{ .input = input };
    }

    pub fn next(self: *Parser) !?Token {
        if (self.cursor >= self.input.len) return null;

        const byte = self.input[self.cursor];
        switch (classifyByte(byte)) {
            .legacy_ascii => {
                self.cursor += 1;
                return .{ .legacy_ascii = byte };
            },
            .intent_class => {
                self.cursor += 1;
                return .{ .intent_class = byte };
            },
            .epistemic_tag => {
                self.cursor += 1;
                return .{ .epistemic_tag = byte };
            },
            .hyper_bitstream => {
                const start = self.cursor;
                if (self.input.len - start < RUNE_BYTES) return error.TruncatedRune;
                const block = try alignedRuneBlock(self.input[start .. start + RUNE_BYTES]);
                self.cursor += RUNE_BYTES;
                return .{ .rune = .{ .offset = start, .bytes = block } };
            },
        }
    }
};

pub fn classifyByte(byte: u8) ByteClass {
    if (byte <= 0x7F) return .legacy_ascii;
    if (byte <= 0x9F) return .intent_class;
    if (byte <= 0xBF) return .epistemic_tag;
    return .hyper_bitstream;
}

pub fn alignedRuneBlock(bytes: []const u8) !*align(RUNE_ALIGNMENT) const RuneBytes {
    if (bytes.len != RUNE_BYTES) return error.InvalidRuneLength;
    if (!std.mem.isAligned(@intFromPtr(bytes.ptr), RUNE_ALIGNMENT)) return error.UnalignedRune;
    return @ptrCast(@alignCast(bytes.ptr));
}

pub fn viewRuneBlock(block: *align(RUNE_ALIGNMENT) const RuneBytes) RuneView {
    return .{ .offset = 0, .bytes = block };
}

pub fn writeRuneVector(out: *align(RUNE_ALIGNMENT) RuneBytes, vector: RuneVector) void {
    const src: *const RuneBytes = @ptrCast(&vector);
    @memcpy(out, src);
}

pub fn deterministicRuneBytes(seed: u64, class_byte: u8) RuneBytes {
    var out: RuneBytes = undefined;
    var state = seed ^ 0x9e37_79b9_7f4a_7c15;
    for (&out, 0..) |*byte, idx| {
        state ^= state >> 12;
        state ^= state << 25;
        state ^= state >> 27;
        byte.* = @truncate((state *% 0x2545_f491_4f6c_dd1d) >> @intCast((idx % 8) * 8));
    }
    out[0] = 0xC0 | (class_byte & 0x3F);
    return out;
}

test "byte ranges classify according to GUTF spec" {
    try std.testing.expectEqual(ByteClass.legacy_ascii, classifyByte(0x7F));
    try std.testing.expectEqual(ByteClass.intent_class, classifyByte(0x81));
    try std.testing.expectEqual(ByteClass.epistemic_tag, classifyByte(0xA1));
    try std.testing.expectEqual(ByteClass.hyper_bitstream, classifyByte(0xC0));
}

test "parser maps aligned 1024-bit rune with no heap allocation" {
    var storage: RuneBytes align(RUNE_ALIGNMENT) = deterministicRuneBytes(0x1234, 0x04);
    var parser = Parser.init(&storage);
    const token = (try parser.next()).?;
    const rune = token.rune;
    try std.testing.expectEqual(@intFromPtr(&storage), @intFromPtr(rune.bytes));
    try std.testing.expectEqual(@as(usize, RUNE_BYTES), parser.cursor);

    const full = rune.vector();
    const lower = rune.chunk(0);
    const upper = rune.chunk(1);
    std.mem.doNotOptimizeAway(full);
    std.mem.doNotOptimizeAway(lower);
    std.mem.doNotOptimizeAway(upper);
}

test "parser rejects unaligned hyper-bitstream rune" {
    var frame: [RUNE_BYTES + 1]u8 align(RUNE_ALIGNMENT) = undefined;
    @memset(&frame, 0xC1);
    var parser = Parser.init(frame[1 .. 1 + RUNE_BYTES]);
    try std.testing.expectError(error.UnalignedRune, parser.next());
}

test "parser keeps legacy and metadata bytes as direct one-byte tokens" {
    const frame = [_]u8{ 'G', 0x81, 0xA1 };
    var parser = Parser.init(&frame);
    try std.testing.expectEqual(@as(u8, 'G'), (try parser.next()).?.legacy_ascii);
    try std.testing.expectEqual(@as(u8, 0x81), (try parser.next()).?.intent_class);
    try std.testing.expectEqual(@as(u8, 0xA1), (try parser.next()).?.epistemic_tag);
    try std.testing.expect((try parser.next()) == null);
}
