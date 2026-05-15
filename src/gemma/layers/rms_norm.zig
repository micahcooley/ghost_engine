const std = @import("std");

pub const epsilon: f32 = 0.000001;

pub fn forward(input: []const f32, output: []f32, vector_len: usize) !void {
    if (vector_len == 0) return error.InvalidVectorLength;
    if (input.len != output.len) return error.LengthMismatch;
    if (input.len % vector_len != 0) return error.LengthMismatch;

    var offset: usize = 0;
    while (offset < input.len) : (offset += vector_len) {
        const in_vec = input[offset .. offset + vector_len];
        const out_vec = output[offset .. offset + vector_len];
        var sum_sq: f64 = 0.0;
        for (in_vec) |value| {
            const wide: f64 = @floatCast(value);
            sum_sq += wide * wide;
        }
        const mean_sq = sum_sq / @as(f64, @floatFromInt(vector_len));
        const inv_rms: f32 = @floatCast(1.0 / @sqrt(mean_sq + epsilon));
        for (in_vec, out_vec) |value, *out| out.* = value * inv_rms;
    }
}

pub fn forwardInPlace(values: []f32, vector_len: usize) !void {
    try forward(values, values, vector_len);
}

test "RMS norm normalizes each vector independently" {
    const input = [_]f32{ 3.0, 4.0, 0.0, 0.0, 1.0, -1.0, 1.0, -1.0 };
    var output = [_]f32{0.0} ** input.len;
    try forward(&input, &output, 4);
    try std.testing.expectApproxEqAbs(@as(f32, 1.2), output[0], 0.00001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.6), output[1], 0.00001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), output[2], 0.00001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), output[3], 0.00001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.9999995), output[4], 0.00001);
    try std.testing.expectApproxEqAbs(@as(f32, -0.9999995), output[5], 0.00001);
}

