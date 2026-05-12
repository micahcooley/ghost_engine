const std = @import("std");
const gutf = @import("../codec/gutf.zig");
const gip_mapping = @import("../gip/mapping.zig");

pub const MAX_RUNE_LATTICE: usize = 100_000;
pub const GPU_STAGE_GATE_RUNE_COUNT: usize = 1000;

pub const LatticeLocation = enum {
    cpu_ram,
    vulkan_vram,
};

pub const LatticeEntry = struct {
    uid: gip_mapping.GeometricUid,
    tier: gip_mapping.EpistemicTier,
    label: []const u8,
    rune: gutf.RuneView,
};

pub const SearchOptions = struct {
    include_shadow: bool = false,
    include_unverified: bool = false,
};

pub const SearchResult = struct {
    index: usize,
    uid: gip_mapping.GeometricUid,
    label: []const u8,
    tier: gip_mapping.EpistemicTier,
    hamming_distance: u16,
    authorizing: bool,
};

pub const LatticeView = struct {
    entries: []const LatticeEntry,
    location: LatticeLocation,

    pub fn init(entries: []const LatticeEntry) !LatticeView {
        if (entries.len > MAX_RUNE_LATTICE) return error.LatticeCapacityExceeded;
        return .{
            .entries = entries,
            .location = if (entries.len > GPU_STAGE_GATE_RUNE_COUNT) .vulkan_vram else .cpu_ram,
        };
    }

    pub fn searchNearest(
        self: LatticeView,
        query: gutf.RuneView,
        options: SearchOptions,
    ) ?SearchResult {
        var best: ?SearchResult = null;
        for (self.entries, 0..) |entry, idx| {
            if (!tierAllowed(entry.tier, options)) continue;
            const distance = hammingDistance(query.bytes, entry.rune.bytes);
            if (best == null or distance < best.?.hamming_distance) {
                best = .{
                    .index = idx,
                    .uid = entry.uid,
                    .label = entry.label,
                    .tier = entry.tier,
                    .hamming_distance = distance,
                    .authorizing = entry.tier.authorizes(),
                };
            }
        }
        return best;
    }
};

fn tierAllowed(tier: gip_mapping.EpistemicTier, options: SearchOptions) bool {
    return switch (tier) {
        .root, .verified => true,
        .shadow => options.include_shadow,
        .unverified => options.include_unverified,
    };
}

pub fn hammingDistance(a: *align(gutf.RUNE_ALIGNMENT) const gutf.RuneBytes, b: *align(gutf.RUNE_ALIGNMENT) const gutf.RuneBytes) u16 {
    var distance: u32 = 0;
    for (0..gutf.RUNE_BYTES) |idx| {
        distance += @popCount(a[idx] ^ b[idx]);
    }
    return @intCast(distance);
}

test "lattice stage gate selects Vulkan residency only for large point clouds" {
    var one: gutf.RuneBytes align(gutf.RUNE_ALIGNMENT) = gutf.deterministicRuneBytes(1, 0x03);
    const entries = [_]LatticeEntry{
        .{ .uid = gip_mapping.UID_RUNE_SEARCH_ROOT, .tier = .root, .label = "root", .rune = gutf.viewRuneBlock(&one) },
    };
    const view = try LatticeView.init(&entries);
    try std.testing.expectEqual(LatticeLocation.cpu_ram, view.location);
}

test "nearest search ignores shadow tier unless explicitly requested" {
    var query_bytes: gutf.RuneBytes align(gutf.RUNE_ALIGNMENT) = gutf.deterministicRuneBytes(10, 0x04);
    var verified_bytes: gutf.RuneBytes align(gutf.RUNE_ALIGNMENT) = gutf.deterministicRuneBytes(11, 0x04);
    var shadow_bytes: gutf.RuneBytes align(gutf.RUNE_ALIGNMENT) = query_bytes;

    const entries = [_]LatticeEntry{
        .{ .uid = gip_mapping.UID_ZERO_ALLOC_DSP, .tier = .verified, .label = "verified", .rune = gutf.viewRuneBlock(&verified_bytes) },
        .{ .uid = gip_mapping.UID_SHADOW_TRUTH_SYNC, .tier = .shadow, .label = "shadow", .rune = gutf.viewRuneBlock(&shadow_bytes) },
    };
    const view = try LatticeView.init(&entries);
    const query = gutf.viewRuneBlock(&query_bytes);

    const verified_only = view.searchNearest(query, .{}).?;
    try std.testing.expectEqualStrings("verified", verified_only.label);
    try std.testing.expect(verified_only.authorizing);

    const with_shadow = view.searchNearest(query, .{ .include_shadow = true }).?;
    try std.testing.expectEqualStrings("shadow", with_shadow.label);
    try std.testing.expect(!with_shadow.authorizing);
    try std.testing.expectEqual(@as(u16, 0), with_shadow.hamming_distance);
}
