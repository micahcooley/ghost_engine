const std = @import("std");

pub const Sketch = struct {
    hash: u64,
    feature_count: usize,

    pub fn valid(self: Sketch) bool {
        return self.feature_count != 0;
    }
};

const MAX_TOKENS: usize = 128;
const MAX_NORMALIZED_BYTES: usize = 4096;

pub fn simHash64(allocator: std.mem.Allocator, text: []const u8) !Sketch {
    var tokens = std.ArrayList([]u8).init(allocator);
    defer {
        for (tokens.items) |token| allocator.free(token);
        tokens.deinit();
    }

    var normalized = std.ArrayList(u8).init(allocator);
    defer normalized.deinit();

    var start: ?usize = null;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (isTokenByte(c)) {
            if (start == null) start = i;
        } else if (start) |s| {
            try appendNormalizedToken(allocator, &tokens, &normalized, text[s..i]);
            start = null;
        }
        if (tokens.items.len >= MAX_TOKENS and normalized.items.len >= MAX_NORMALIZED_BYTES) break;
    }
    if (start) |s| {
        if (tokens.items.len < MAX_TOKENS or normalized.items.len < MAX_NORMALIZED_BYTES) {
            try appendNormalizedToken(allocator, &tokens, &normalized, text[s..]);
        }
    }

    var weights = [_]i32{0} ** 64;
    var feature_count: usize = 0;

    for (tokens.items) |token| {
        addFeature(&weights, "tok", token, null);
        feature_count += 1;
    }

    if (tokens.items.len >= 2) {
        var idx: usize = 0;
        while (idx + 1 < tokens.items.len) : (idx += 1) {
            addFeature(&weights, "bi", tokens.items[idx], tokens.items[idx + 1]);
            feature_count += 1;
        }
    }

    const normalized_text = normalized.items;
    if (normalized_text.len >= 3) {
        var idx: usize = 0;
        while (idx + 3 <= normalized_text.len) : (idx += 1) {
            const tri = normalized_text[idx .. idx + 3];
            if (tri[0] == ' ' or tri[2] == ' ') continue;
            addFeature(&weights, "tri", tri, null);
            feature_count += 1;
        }
    }

    if (feature_count == 0) return .{ .hash = 0, .feature_count = 0 };

    var hash: u64 = 0;
    for (weights, 0..) |weight, bit| {
        if (weight >= 0) hash |= (@as(u64, 1) << @intCast(bit));
    }
    return .{ .hash = hash, .feature_count = feature_count };
}

pub fn hammingDistance(lhs: u64, rhs: u64) u7 {
    return @intCast(@popCount(lhs ^ rhs));
}

pub fn similarityScore(distance: u7) u16 {
    const remaining: u16 = 64 - @as(u16, distance);
    return @intCast((@as(u32, remaining) * 1000) / 64);
}

fn isTokenByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-';
}

fn appendNormalizedToken(
    allocator: std.mem.Allocator,
    tokens: *std.ArrayList([]u8),
    normalized: *std.ArrayList(u8),
    raw: []const u8,
) !void {
    const trimmed = std.mem.trim(u8, raw, "_-");
    if (trimmed.len < 2) return;

    var lower_buf: [128]u8 = undefined;
    var lower_owned: ?[]u8 = null;
    const lower = if (trimmed.len <= lower_buf.len) blk: {
        for (trimmed, 0..) |c, idx| lower_buf[idx] = std.ascii.toLower(c);
        break :blk lower_buf[0..trimmed.len];
    } else blk: {
        const owned = try allocator.alloc(u8, trimmed.len);
        for (trimmed, 0..) |c, idx| owned[idx] = std.ascii.toLower(c);
        lower_owned = owned;
        break :blk owned;
    };
    defer if (lower_owned) |owned| allocator.free(owned);

    if (tokens.items.len < MAX_TOKENS) {
        try tokens.append(try allocator.dupe(u8, lower));
    }
    if (normalized.items.len < MAX_NORMALIZED_BYTES) {
        if (normalized.items.len != 0) try normalized.append(' ');
        const remaining = MAX_NORMALIZED_BYTES - normalized.items.len;
        try normalized.appendSlice(lower[0..@min(lower.len, remaining)]);
    }
}

fn addFeature(weights: *[64]i32, prefix: []const u8, first: []const u8, second: ?[]const u8) void {
    var hasher = std.hash.Fnv1a_64.init();
    hasher.update(prefix);
    hasher.update(":");
    hasher.update(first);
    if (second) |value| {
        hasher.update("|");
        hasher.update(value);
    }
    const hash = hasher.final();
    for (0..64) |bit| {
        const mask = @as(u64, 1) << @intCast(bit);
        if ((hash & mask) != 0) {
            weights[bit] += 1;
        } else {
            weights[bit] -= 1;
        }
    }
}

test "simhash is stable for identical text and near for small local variation" {
    const allocator = std.testing.allocator;
    const base = try simHash64(allocator, "retention policy is enabled for event audit logs");
    const same = try simHash64(allocator, "Retention policy is enabled for event audit logs");
    const near = try simHash64(allocator, "retention policy is enabled for event audit logs today");
    const unrelated = try simHash64(allocator, "shader compilation failed in a vulkan driver path");

    try std.testing.expect(base.valid());
    try std.testing.expectEqual(base.hash, same.hash);
    const near_distance = hammingDistance(base.hash, near.hash);
    const unrelated_distance = hammingDistance(base.hash, unrelated.hash);
    try std.testing.expect(near_distance < unrelated_distance);
}
