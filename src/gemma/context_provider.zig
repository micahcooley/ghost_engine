const std = @import("std");
const vsa = @import("../vsa_math.zig");
const rune_encoder = @import("rune_encoder.zig");

pub const ContextEntry = struct {
    slot: u32,
    resonance: f32,
    embedding: []const f32,
    rune_id: u64,
    rotor: [2]u64,
};

pub const QueryLogEntry = struct {
    timestamp: i64,
    rotor_hash: u64,
    resonance: f32,
    status: Status,
    duration_ns: u64,

    pub const Status = enum {
        supported,
        unresolved,
    };
};

pub const GhostContextProvider = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) GhostContextProvider {
        return .{ .allocator = allocator };
    }

    pub fn queryContext(
        self: GhostContextProvider,
        query: vsa.HyperVector,
        candidates: []const rune_encoder.ConversationRune,
        top_k: usize,
    ) ![]ContextEntry {
        if (top_k == 0) return error.InvalidTopK;
        const count = @min(top_k, candidates.len);
        var entries = try self.allocator.alloc(ContextEntry, candidates.len);
        errdefer self.allocator.free(entries);

        for (candidates, 0..) |candidate, idx| {
            entries[idx] = .{
                .slot = @intCast(idx),
                .resonance = resonanceScore(query, candidate.vector),
                .embedding = candidate.embedding,
                .rune_id = candidate.rotor[0],
                .rotor = candidate.rotor,
            };
        }
        std.mem.sort(ContextEntry, entries, {}, sortByResonanceDesc);

        const result = try self.allocator.alloc(ContextEntry, count);
        @memcpy(result, entries[0..count]);
        self.allocator.free(entries);
        return result;
    }
};

pub fn freeContext(allocator: std.mem.Allocator, context: []ContextEntry) void {
    allocator.free(context);
}

pub fn resonanceScore(query: vsa.HyperVector, candidate: vsa.HyperVector) f32 {
    const distance = vsa.hammingDistance(query, candidate);
    const normalized = @as(f32, @floatFromInt(distance)) / 1024.0;
    return @max(0.0, 1.0 - normalized);
}

fn sortByResonanceDesc(_: void, lhs: ContextEntry, rhs: ContextEntry) bool {
    if (lhs.resonance == rhs.resonance) return lhs.rune_id < rhs.rune_id;
    return lhs.resonance > rhs.resonance;
}

test "context provider returns top resonance entries without mutation" {
    const allocator = std.testing.allocator;
    const encoder = rune_encoder.RuneEncoder.init(allocator, 16);
    const runes = try encoder.encode("memory allocation heap pointer", 9);
    defer rune_encoder.freeRunes(allocator, runes);

    const provider = GhostContextProvider.init(allocator);
    const context = try provider.queryContext(runes[0].vector, runes, 2);
    defer freeContext(allocator, context);

    try std.testing.expectEqual(@as(usize, 2), context.len);
    try std.testing.expect(context[0].resonance >= context[1].resonance);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), context[0].resonance, 0.00001);
    try std.testing.expectEqual(runes[0].rotor[0], context[0].rune_id);
}
