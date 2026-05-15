const std = @import("std");
const vsa = @import("../../vsa_math.zig");

pub const RuneHead = struct {
    seed: u64 = 0x6765_6d6d_615f_6864,

    pub fn project(self: RuneHead, model_output: []const f32) vsa.HyperVector {
        var result: vsa.HyperVector = @splat(0);
        for (0..15) |word_idx| {
            var word: u64 = 0;
            for (0..64) |bit_idx| {
                var votes: i64 = 0;
                const bit_number = word_idx * 64 + bit_idx;
                for (model_output, 0..) |value, dim| {
                    const sign: i64 = if (value >= 0.0) 1 else -1;
                    const projection = projectionSign(self.seed, dim, bit_number);
                    votes += sign * projection;
                }
                if (votes > 0) word |= @as(u64, 1) << @as(u6, @intCast(bit_idx));
            }
            result[word_idx] = word;
        }
        result[15] = vsa.generateParity(result);
        return result;
    }
};

fn projectionSign(seed: u64, dim: usize, bit: usize) i64 {
    var state = seed ^ (@as(u64, @intCast(dim)) *% 0x9e37_79b9_7f4a_7c15) ^ (@as(u64, @intCast(bit)) *% 0xbf58_476d_1ce4_e5b9);
    state = splitMix64(state);
    return if ((state & 1) == 1) 1 else -1;
}

fn splitMix64(input: u64) u64 {
    var z = input +% 0x9e37_79b9_7f4a_7c15;
    z = (z ^ (z >> 30)) *% 0xbf58_476d_1ce4_e5b9;
    z = (z ^ (z >> 27)) *% 0x94d0_49bb_1331_11eb;
    return z ^ (z >> 31);
}

test "rune head projects deterministically to a healthy hypervector" {
    const head = RuneHead{};
    const values = [_]f32{ 0.25, -0.5, 1.0, -2.0, 0.125, 0.75 };
    const first = head.project(&values);
    const second = head.project(&values);
    try std.testing.expectEqual(first, second);
    try std.testing.expect(vsa.isHealthy(first));
}
