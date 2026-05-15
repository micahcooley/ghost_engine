const std = @import("std");
const context_provider = @import("../context_provider.zig");

pub const AttentionStats = struct {
    context_count: usize,
    total_resonance: f32,
};

pub fn resonanceWeightedSum(
    context: []const context_provider.ContextEntry,
    output: []f32,
) !AttentionStats {
    if (context.len == 0) return error.NoContext;
    @memset(output, 0.0);

    var total: f32 = 0.0;
    for (context) |entry| {
        if (entry.embedding.len != output.len) return error.EmbeddingLengthMismatch;
        total += @max(entry.resonance, 0.0);
    }
    if (total <= 0.0) return error.ZeroResonance;

    for (context) |entry| {
        const weight = @max(entry.resonance, 0.0) / total;
        for (output, entry.embedding) |*out, value| out.* += weight * value;
    }
    return .{ .context_count = context.len, .total_resonance = total };
}

test "resonance attention normalizes scores and preserves shape" {
    const a = [_]f32{ 1.0, 0.0, -1.0, 2.0 };
    const b = [_]f32{ 0.0, 2.0, 1.0, -2.0 };
    const context = [_]context_provider.ContextEntry{
        .{ .slot = 0, .resonance = 0.75, .embedding = &a, .rune_id = 1, .rotor = .{ 1, 2 } },
        .{ .slot = 1, .resonance = 0.25, .embedding = &b, .rune_id = 3, .rotor = .{ 3, 4 } },
    };
    var output = [_]f32{0.0} ** 4;
    const stats = try resonanceWeightedSum(&context, &output);
    try std.testing.expectEqual(@as(usize, 2), stats.context_count);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), stats.total_resonance, 0.00001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), output[0], 0.00001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), output[1], 0.00001);
    try std.testing.expectApproxEqAbs(@as(f32, -0.5), output[2], 0.00001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), output[3], 0.00001);
}
