const std = @import("std");

pub const RUNE_BITS: usize = 1024;
pub const RUNE_BYTES: usize = RUNE_BITS / 8;
pub const RUNE_LANES: usize = RUNE_BYTES / @sizeOf(u64);
pub const TIER_HIVE_REMOTE: u8 = 6;
pub const DEFAULT_PORT: u16 = 42069;

const MAGIC = "GHSV";
const VERSION: u8 = 1;

pub const Rune = struct {
    lanes: [RUNE_LANES]u64 = [_]u64{0} ** RUNE_LANES,

    pub fn deterministic(seed: u64) Rune {
        var state = seed;
        var out = Rune{};
        for (0..RUNE_LANES) |idx| {
            state ^= state >> 12;
            state ^= state << 25;
            state ^= state >> 27;
            out.lanes[idx] = state *% 0x2545_f491_4f6c_dd1d;
        }
        return out;
    }
};

pub const GossipPacket = struct {
    tier: u8 = TIER_HIVE_REMOTE,
    flags: u8 = 0,
    rune: Rune,
    proof_hash: u64 = 0,
};

pub const PromotionDecision = enum {
    rejected,
    remote_cache,
    verified_local,

    pub fn name(self: PromotionDecision) []const u8 {
        return @tagName(self);
    }
};

pub fn encodePacket(packet: GossipPacket, out: *[4 + 1 + 1 + 1 + RUNE_BYTES + 8]u8) void {
    @memcpy(out[0..4], MAGIC);
    out[4] = VERSION;
    out[5] = packet.tier;
    out[6] = packet.flags;
    var offset: usize = 7;
    for (packet.rune.lanes) |lane| {
        std.mem.writeInt(u64, out[offset .. offset + 8][0..8], lane, .little);
        offset += 8;
    }
    std.mem.writeInt(u64, out[offset .. offset + 8][0..8], packet.proof_hash, .little);
}

pub fn decodePacket(bytes: []const u8) !GossipPacket {
    if (bytes.len != 4 + 1 + 1 + 1 + RUNE_BYTES + 8) return error.InvalidPacketLength;
    if (!std.mem.eql(u8, bytes[0..4], MAGIC)) return error.InvalidMagic;
    if (bytes[4] != VERSION) return error.UnsupportedVersion;
    var out = GossipPacket{
        .tier = bytes[5],
        .flags = bytes[6],
        .rune = .{},
        .proof_hash = 0,
    };
    var offset: usize = 7;
    for (0..RUNE_LANES) |idx| {
        out.rune.lanes[idx] = std.mem.readInt(u64, bytes[offset .. offset + 8][0..8], .little);
        offset += 8;
    }
    out.proof_hash = std.mem.readInt(u64, bytes[offset .. offset + 8][0..8], .little);
    return out;
}

pub fn decidePromotion(local_oracle_proved: bool, commit_requested: bool) PromotionDecision {
    if (!local_oracle_proved) return .rejected;
    return if (commit_requested) .verified_local else .remote_cache;
}

pub fn renderStatusJson(allocator: std.mem.Allocator) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    try w.writeAll("{\"hive\":{\"status\":\"offline_ready\",\"networkEnabledByDefault\":false");
    try w.print(",\"protocol\":\"udp_gossip\",\"defaultPort\":{d},\"runeBits\":{d},\"remoteCacheTier\":{d}", .{
        DEFAULT_PORT,
        RUNE_BITS,
        TIER_HIVE_REMOTE,
    });
    try w.writeAll(",\"localOracleGateRequired\":true,\"rawSourceExchange\":false,\"promotionPolicy\":\"reject_until_local_oracle_proves\",\"mutationFlags\":{\"sourceMutation\":false,\"corpusMutation\":false,\"packMutation\":false,\"negativeKnowledgeMutation\":false,\"commandsExecuted\":false,\"verifiersExecuted\":false,\"networkPacketsSent\":false},\"authorityFlags\":{\"nonAuthorizing\":true,\"treatedAsProof\":false,\"usedAsEvidence\":false}}}");
    return out.toOwnedSlice();
}

test "gossip packet round trips a 1024-bit rune" {
    const packet = GossipPacket{
        .rune = Rune.deterministic(99),
        .proof_hash = 0xabc,
    };
    var encoded: [4 + 1 + 1 + 1 + RUNE_BYTES + 8]u8 = undefined;
    encodePacket(packet, &encoded);
    const decoded = try decodePacket(&encoded);
    try std.testing.expectEqual(packet.tier, decoded.tier);
    try std.testing.expectEqual(packet.proof_hash, decoded.proof_hash);
    try std.testing.expectEqual(packet.rune.lanes[3], decoded.rune.lanes[3]);
}

test "remote rune cannot promote without local oracle proof" {
    try std.testing.expectEqual(PromotionDecision.rejected, decidePromotion(false, true));
    try std.testing.expectEqual(PromotionDecision.remote_cache, decidePromotion(true, false));
    try std.testing.expectEqual(PromotionDecision.verified_local, decidePromotion(true, true));
}
