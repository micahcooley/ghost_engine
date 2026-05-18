const std = @import("std");
const absolute = @import("absolute_final");

pub const LabeledPrompt = struct {
    label: []const u8,
    text: []const u8,
};

// 8 voxels per chamber gives 512 chambers per 4096-voxel window — enough
// candidates inside a single short-prompt window for 8 distinct edges to
// resolve reliably across the canonical prompts.
const ChamberSize: usize = 8;
const ChamberCount: usize = absolute.AbsoluteCore.ManifoldSize / ChamberSize;

fn chamberSums(field: []u64, out: *[ChamberCount]u64) void {
    for (0..ChamberCount) |i| {
        const start = i * ChamberSize;
        var sum: u64 = 0;
        for (field[start .. start + ChamberSize]) |v| sum ^= v;
        out[i] = sum;
    }
}

fn fingerprint(sums: *const [ChamberCount]u64) u64 {
    var h: u64 = 0xCBF29CE484222325;
    for (sums) |s| {
        h ^= s;
        h = h *% 0x100000001B3;
    }
    return h;
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const stdout = std.io.getStdOut().writer();

    const prompts = [_]LabeledPrompt{
        .{ .label = "technical-low-level", .text = "Explain the memory layout of a Zig struct with aligned fields." },
        .{ .label = "creative-poetic", .text = "Write a haiku about the silence of a motherboard at night." },
        .{ .label = "math-hard", .text = "Solve for x where 7x^2 + 13x - 5000 = 0 using Diophantine approximation." },
        .{ .label = "typo-adversarial", .text = "hw do i fix teh broken lgc in my asic core??" },
        .{ .label = "instruction-complex", .text = "Refactor the existing Sovereign meta-architecture to use a sharded ring buffer for voxel persistence." },
        .{ .label = "casual-greeting", .text = "Hello, how is the weather in the cloud today?" },
        .{ .label = "system-status", .text = "Report on current manifold resonance and L1 cache utilization." },
        .{ .label = "code-zig", .text = "const std = @import(\"std\"); pub fn main() !void { std.debug.print(\"hello\", .{}); }" },
    };

    try stdout.writeAll("### GHOST ABSOLUTE CALIBRATION (AbsoluteCore backend) ###\n");
    try stdout.print("Chamber partition: {d} chambers x {d} voxels (64-bit)\n\n", .{ ChamberCount, ChamberSize });
    try stdout.writeAll("Label                | Delta      | Edge  | Fingerprint         | Status\n");
    try stdout.writeAll("---------------------|------------|-------|---------------------|-------\n");

    const before = try aa.create([ChamberCount]u64);
    const after = try aa.create([ChamberCount]u64);

    for (prompts) |lp| {
        var core = try absolute.AbsoluteCore.init(16 * 1024 * 1024);
        defer core.deinit();

        chamberSums(core.field, before);
        core.ingest(lp.text);
        chamberSums(core.field, after);

        // delta_total is u128 because XOR-folded chamber values are full-range
        // u64s; summing 32K of their differences overflows a u64 quickly.
        var delta_total: u128 = 0;
        var max_change: u64 = 0;
        var trigger_edge: usize = 0;
        for (0..ChamberCount) |i| {
            const a = after[i];
            const b = before[i];
            const change = if (a > b) a - b else b - a;
            delta_total += @as(u128, change);
            if (change > max_change) {
                max_change = change;
                trigger_edge = i;
            }
        }

        const fp = fingerprint(after);
        try stdout.print("{s: <20} | {d: >10} | {d: >5} | {X: >19} | OK\n", .{
            lp.label, delta_total, trigger_edge, fp,
        });
    }
}