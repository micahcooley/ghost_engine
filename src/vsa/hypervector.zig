const std = @import("std");

pub const BIT_COUNT: usize = 1024;
pub const LANE_BITS: usize = 64;
pub const LANE_COUNT: usize = BIT_COUNT / LANE_BITS;
pub const Vector = @Vector(LANE_COUNT, u64);

pub const HyperVector = extern struct {
    lanes: [LANE_COUNT]u64 = [_]u64{0} ** LANE_COUNT,

    pub fn fromVector(v: Vector) HyperVector {
        return .{ .lanes = @as([LANE_COUNT]u64, v) };
    }

    pub fn vector(self: HyperVector) Vector {
        return @as(Vector, self.lanes);
    }
};

pub fn zero() HyperVector {
    return .{};
}

pub fn splat(word: u64) HyperVector {
    return HyperVector.fromVector(@splat(word));
}

/// Binding is bitwise XOR over the full 1024-bit vector. Zig lowers this
/// vector expression through LLVM for the full Ghost build; AVX-512 capable
/// targets can widen the lane scheduling without changing the contract.
pub inline fn bind(a: HyperVector, b: HyperVector) HyperVector {
    return HyperVector.fromVector(a.vector() ^ b.vector());
}

pub inline fn hammingDistance(a: HyperVector, b: HyperVector) u16 {
    const diff = bind(a, b);
    var distance: u32 = 0;
    inline for (0..LANE_COUNT) |lane| {
        distance += @popCount(diff.lanes[lane]);
    }
    return @intCast(distance);
}

pub inline fn similarity(a: HyperVector, b: HyperVector) f32 {
    const distance: f32 = @floatFromInt(hammingDistance(a, b));
    return 1.0 - (distance / @as(f32, @floatFromInt(BIT_COUNT)));
}

/// Bundles any non-empty vector set by per-bit majority. Ties resolve to zero,
/// keeping the operation deterministic and non-authorizing.
pub fn bundleMajority(vectors: []const HyperVector) !HyperVector {
    if (vectors.len == 0) return error.EmptyBundle;

    var out = zero();
    const threshold = (vectors.len / 2) + 1;
    for (0..LANE_COUNT) |lane| {
        var word: u64 = 0;
        for (0..LANE_BITS) |bit| {
            const mask = @as(u64, 1) << @as(u6, @intCast(bit));
            var ones: usize = 0;
            for (vectors) |candidate| {
                if ((candidate.lanes[lane] & mask) != 0) ones += 1;
            }
            if (ones >= threshold) word |= mask;
        }
        out.lanes[lane] = word;
    }
    return out;
}

/// Fast three-input majority used by hot VSA paths:
/// (a & b) | (b & c) | (a & c).
pub inline fn bundle3(a: HyperVector, b: HyperVector, c: HyperVector) HyperVector {
    const av = a.vector();
    const bv = b.vector();
    const cv = c.vector();
    return HyperVector.fromVector((av & bv) | (bv & cv) | (av & cv));
}

pub fn deterministic(seed: u64) HyperVector {
    var state = seed ^ 0x9e37_79b9_7f4a_7c15;
    var out: HyperVector = undefined;
    inline for (0..LANE_COUNT) |lane| {
        state ^= state >> 30;
        state *%= 0xbf58_476d_1ce4_e5b9;
        state ^= state >> 27;
        state *%= 0x94d0_49bb_1331_11eb;
        state ^= state >> 31;
        out.lanes[lane] = state;
    }
    return out;
}

test "binding is xor and self inverse" {
    const a = deterministic(1);
    const b = deterministic(2);
    try std.testing.expectEqual(a, bind(bind(a, b), b));
}

test "majority bundling and similarity stay bounded" {
    const a = splat(0xffff_ffff_ffff_ffff);
    const b = splat(0xffff_ffff_ffff_ffff);
    const c = zero();
    const bundled = bundle3(a, b, c);
    try std.testing.expectEqual(a, bundled);
    try std.testing.expectEqual(@as(f32, 1.0), similarity(a, bundled));
    try std.testing.expectEqual(@as(f32, 0.0), similarity(a, zero()));
}

test "slice majority rejects empty bundles" {
    try std.testing.expectError(error.EmptyBundle, bundleMajority(&.{}));
}
