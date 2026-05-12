const std = @import("std");
const hypervector = @import("../vsa/hypervector.zig");

pub const MIN_SPEEDUP_PER_MILLE: u32 = 50;
pub const HOT_SWAP_LATENCY_TARGET_MS: u16 = 15;
pub const DEFAULT_BENCH_ITERATIONS: usize = 4096;

pub const BenchResult = struct {
    iterations: usize,
    elapsed_ns: u64,
    ns_per_operation: u64,
    checksum: u64,
};

pub const SwapDecision = struct {
    candidate_verified: bool,
    speedup_per_mille: i64,
    hot_swap_latency_ms: u16,

    pub fn shouldSwap(self: SwapDecision) bool {
        return self.candidate_verified and
            self.speedup_per_mille >= MIN_SPEEDUP_PER_MILLE and
            self.hot_swap_latency_ms <= HOT_SWAP_LATENCY_TARGET_MS;
    }
};

pub fn benchmarkBind(iterations: usize) !BenchResult {
    const n = @max(iterations, @as(usize, 1));
    var a = hypervector.deterministic(0x1234);
    var b = hypervector.deterministic(0x5678);
    var checksum: u64 = 0;
    var timer = try std.time.Timer.start();
    for (0..n) |idx| {
        const bound = hypervector.bind(a, b);
        checksum ^= bound.lanes[idx % hypervector.LANE_COUNT];
        a = hypervector.bind(bound, hypervector.deterministic(@intCast(idx + 1)));
        b = hypervector.bind(b, hypervector.splat(@intCast(idx + 3)));
    }
    const elapsed = timer.read();
    std.mem.doNotOptimizeAway(checksum);
    return .{
        .iterations = n,
        .elapsed_ns = elapsed,
        .ns_per_operation = @max(@as(u64, 1), elapsed / n),
        .checksum = checksum,
    };
}

pub fn speedupPerMille(baseline_ns: u64, candidate_ns: u64) i64 {
    if (baseline_ns == 0 or candidate_ns == 0) return 0;
    const baseline_i: i128 = baseline_ns;
    const candidate_i: i128 = candidate_ns;
    return @intCast(@divTrunc((baseline_i - candidate_i) * 1000, baseline_i));
}

pub fn renderStatusJson(allocator: std.mem.Allocator, iterations: usize) ![]u8 {
    const bench = try benchmarkBind(iterations);
    const hypothetical_candidate_ns = bench.ns_per_operation;
    const decision = SwapDecision{
        .candidate_verified = false,
        .speedup_per_mille = speedupPerMille(bench.ns_per_operation, hypothetical_candidate_ns),
        .hot_swap_latency_ms = HOT_SWAP_LATENCY_TARGET_MS,
    };

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();
    try w.writeAll("{\"recursiveBoot\":{\"status\":\"measurement_only\",\"observesSelf\":true,\"hotSwapEnabledByDefault\":false");
    try w.print(",\"minSpeedupPerMille\":{d},\"hotSwapLatencyTargetMs\":{d}", .{
        MIN_SPEEDUP_PER_MILLE,
        HOT_SWAP_LATENCY_TARGET_MS,
    });
    try w.print(",\"benchmark\":{{\"target\":\"vsa.hypervector.bind\",\"iterations\":{d},\"elapsedNs\":{d},\"nsPerOperation\":{d},\"checksum\":{d}}}", .{
        bench.iterations,
        bench.elapsed_ns,
        bench.ns_per_operation,
        bench.checksum,
    });
    try w.print(",\"swapDecision\":{{\"candidateVerified\":{s},\"speedupPerMille\":{d},\"hotSwapLatencyMs\":{d},\"shouldSwap\":{s}}}", .{
        if (decision.candidate_verified) "true" else "false",
        decision.speedup_per_mille,
        decision.hot_swap_latency_ms,
        if (decision.shouldSwap()) "true" else "false",
    });
    try w.writeAll(",\"mutationFlags\":{\"sourceMutation\":false,\"binaryReplacement\":false,\"sharedMemoryStateTransfer\":false,\"commandsExecuted\":false,\"verifiersExecuted\":false},\"authorityFlags\":{\"nonAuthorizing\":true,\"treatedAsProof\":false,\"usedAsEvidence\":false},\"notes\":[\"candidate generation and execve handoff are not enabled by this read-only status operation\"]}}");
    return out.toOwnedSlice();
}

test "swap requires verification and at least five percent speedup" {
    try std.testing.expect(!(SwapDecision{ .candidate_verified = false, .speedup_per_mille = 100, .hot_swap_latency_ms = 1 }).shouldSwap());
    try std.testing.expect(!(SwapDecision{ .candidate_verified = true, .speedup_per_mille = 49, .hot_swap_latency_ms = 1 }).shouldSwap());
    try std.testing.expect((SwapDecision{ .candidate_verified = true, .speedup_per_mille = 50, .hot_swap_latency_ms = 15 }).shouldSwap());
}

test "speedup math is per mille" {
    try std.testing.expectEqual(@as(i64, 100), speedupPerMille(100, 90));
    try std.testing.expectEqual(@as(i64, -100), speedupPerMille(100, 110));
}
