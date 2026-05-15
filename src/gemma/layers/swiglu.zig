const std = @import("std");

pub fn forward(gate: []const f32, up: []const f32, output: []f32) !void {
    if (gate.len != up.len or gate.len != output.len) return error.LengthMismatch;
    for (gate, up, output) |g, u, *out| {
        out.* = silu(g) * u;
    }
}

pub fn silu(value: f32) f32 {
    return value * sigmoid(value);
}

pub fn sigmoid(value: f32) f32 {
    return 1.0 / (1.0 + @exp(-value));
}

test "SwiGLU combines gate SiLU and up projection" {
    const gate = [_]f32{ 0.0, 1.0, -1.0, 2.0 };
    const up = [_]f32{ 4.0, 3.0, 2.0, -1.0 };
    var output = [_]f32{0.0} ** gate.len;
    try forward(&gate, &up, &output);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), output[0], 0.00001);
    try std.testing.expectApproxEqAbs(@as(f32, 2.1931758), output[1], 0.00001);
    try std.testing.expectApproxEqAbs(@as(f32, -0.53788286), output[2], 0.00001);
    try std.testing.expectApproxEqAbs(@as(f32, -1.761594), output[3], 0.00001);
}

