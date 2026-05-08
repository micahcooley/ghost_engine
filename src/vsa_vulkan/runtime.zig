const std = @import("std");
const builtin = @import("builtin");

pub const OperationalTier = enum(u32) {
    background = 1,
    standard = 2,
    high = 3,
    max = 4,
    extreme = 5,
    tier_heuristic = 6,
    tier_verified = 7,
    tier_system_authoritative = 8,

    pub fn getBatchSize(self: OperationalTier, max_wg: u32) u32 {
        const base = @max(max_wg, 1024);
        return switch (self) {
            .background => base / 8,
            .standard => base / 4,
            .high => base / 2,
            .max => base,
            .extreme => base * 2,
            .tier_heuristic => base * 4,
            .tier_verified => base * 8,
            .tier_system_authoritative => if (builtin.os.tag == .linux) base * 24 else base * 16,
        };
    }
};

pub fn parseOperationalTierAlias(flag: []const u8) ?OperationalTier {
    if (std.mem.eql(u8, flag, "background")) return .background;
    if (std.mem.eql(u8, flag, "standard")) return .standard;
    if (std.mem.eql(u8, flag, "high")) return .high;
    if (std.mem.eql(u8, flag, "max")) return .max;
    if (std.mem.eql(u8, flag, "extreme")) return .extreme;
    if (std.mem.eql(u8, flag, "tier_heuristic") or std.mem.eql(u8, flag, "heuristic") or std.mem.eql(u8, flag, "ultra")) return .tier_heuristic;
    if (std.mem.eql(u8, flag, "tier_verified") or std.mem.eql(u8, flag, "verified") or std.mem.eql(u8, flag, "hyper")) return .tier_verified;
    if (std.mem.eql(u8, flag, "tier_system_authoritative") or std.mem.eql(u8, flag, "system_authoritative") or std.mem.eql(u8, flag, "god")) return .tier_system_authoritative;
    return null;
}

pub fn tierNameFromValue(value: u32) []const u8 {
    return @tagName(@as(OperationalTier, @enumFromInt(value)));
}

test "professional operational tier names preserve legacy aliases" {
    try std.testing.expectEqual(OperationalTier.tier_heuristic, parseOperationalTierAlias("ultra").?);
    try std.testing.expectEqual(OperationalTier.tier_verified, parseOperationalTierAlias("hyper").?);
    try std.testing.expectEqual(OperationalTier.tier_system_authoritative, parseOperationalTierAlias("god").?);
    try std.testing.expectEqualStrings("tier_system_authoritative", tierNameFromValue(8));
}
