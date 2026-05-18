const std = @import("std");
const absolute = @import("absolute_final");

const BenchBytes: usize = 32 * 1024 * 1024;
const PromptCount: usize = 1000;

fn splitMix64(state: *u64) u64 {
    state.* +%= 0x9E3779B97F4A7C15;
    var z = state.*;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

fn fillDeterministic(data: []u8) void {
    var state: u64 = 0x47524F554E444544;
    var i: usize = 0;
    while (i < data.len) {
        const word = splitMix64(&state);
        var j: usize = 0;
        while (j < @sizeOf(u64) and i < data.len) : ({
            j += 1;
            i += 1;
        }) {
            data[i] = @truncate(word >> @as(u6, @intCast(j * 8)));
        }
    }
}

fn baselineXorSum(data: []const u8) u64 {
    var acc: u64 = 0xD1B54A32D192ED03;
    for (data, 0..) |b, i| {
        const spread = @as(u64, b) ^ (@as(u64, b) << 8) ^ (@as(u64, b) << 16) ^ (@as(u64, b) << 24);
        acc ^= std.math.rotl(u64, spread, @as(u6, @intCast(i & 63)));
    }
    return acc;
}

fn mbPerSec(bytes: usize, elapsed_ns: u64) f64 {
    const mib = @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0);
    const seconds = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
    return mib / seconds;
}

fn seenContains(seen: []const u64, value: u64) bool {
    for (seen) |item| {
        if (item == value) return true;
    }
    return false;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const stdout = std.io.getStdOut().writer();

    const data = try allocator.alloc(u8, BenchBytes);
    defer allocator.free(data);
    fillDeterministic(data);

    var baseline_timer = try std.time.Timer.start();
    const baseline_mark = baselineXorSum(data);
    const baseline_ns = baseline_timer.read();

    var core = try absolute.AbsoluteCore.init(16 * 1024 * 1024);
    defer core.deinit();

    var core_timer = try std.time.Timer.start();
    const core_report = core.ingestMeasured(data);
    const core_ns = core_timer.read();

    var unique_edges: [PromptCount]u64 = undefined;
    var unique_count: usize = 0;
    var prng: u64 = 0x5354415449535449;
    var prompt_buf: [192]u8 = undefined;

    for (0..PromptCount) |idx| {
        core.reset();
        const a = splitMix64(&prng);
        const b = splitMix64(&prng);
        const c = splitMix64(&prng);
        const prompt = try std.fmt.bufPrint(
            &prompt_buf,
            "prompt={d} intent=0x{x} route=0x{x} pressure=0x{x} grounded absolute calibration",
            .{ idx, a, b, c },
        );
        const report = core.ingestMeasured(prompt);
        const edge_key = report.edge_fingerprint ^ @as(u64, @intCast(report.dominant_edge));
        if (!seenContains(unique_edges[0..unique_count], edge_key)) {
            unique_edges[unique_count] = edge_key;
            unique_count += 1;
        }
    }

    const unique_rate = @as(f64, @floatFromInt(unique_count)) / @as(f64, @floatFromInt(PromptCount));
    const baseline_mbps = mbPerSec(data.len, baseline_ns);
    const core_mbps = mbPerSec(data.len, core_ns);

    try stdout.writeAll("### GHOST ABSOLUTE THROUGHPUT BENCH ###\n");
    try stdout.print("buffer_bytes={d}\n", .{data.len});
    try stdout.print("baseline_xor_mbps={d:.2}\n", .{baseline_mbps});
    try stdout.print("baseline_mark=0x{X}\n", .{baseline_mark});
    try stdout.print("sharded_core_mbps={d:.2}\n", .{core_mbps});
    try stdout.print("sharded_core_writes={d}\n", .{core_report.writes});
    try stdout.print("sharded_core_edge=0x{X}\n", .{core_report.edge_fingerprint});
    try stdout.print("core_vs_baseline_ratio={d:.4}\n", .{core_mbps / baseline_mbps});
    try stdout.writeAll("\n### STATISTICAL CALIBRATION ###\n");
    try stdout.print("prompts={d}\n", .{PromptCount});
    try stdout.print("unique_edge_fingerprints={d}\n", .{unique_count});
    try stdout.print("unique_edge_rate={d:.4}\n", .{unique_rate});
    try stdout.print("collisions={d}\n", .{PromptCount - unique_count});
}
