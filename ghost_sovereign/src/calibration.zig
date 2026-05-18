const std = @import("std");
const flame = @import("flame.zig");
const void_eng = @import("void.zig");
const lore_eng = @import("lore.zig");

pub const LabeledPrompt = struct {
    label: []const u8,
    text: []const u8,
};

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

    try stdout.writeAll("### GHOST RESERVOIR CALIBRATION ###\n");
    try stdout.writeAll("Label                | Delta    | Edge | Lattice Fingerprint | Status\n");
    try stdout.writeAll("---------------------|----------|------|---------------------|-------\n");

    for (prompts) |lp| {
        var engine = void_eng.VoidEngine.init(0xACE);
        const closure_before = flame.closureError(&engine.state);

        // Record per-law pressure before ingestion
        var pressure_before: [flame.LawCount]u128 = undefined;
        for (flame.Laws, 0..) |law, i| {
            const got = law.ca * engine.state.chamber[law.a] + law.cb * engine.state.chamber[law.b];
            pressure_before[i] = @abs(got - law.t);
        }

        engine.ingestTextSequence(0x12345, lp.text, flame.SequenceLen);
        const closure_after = flame.closureError(&engine.state);
        const delta = @as(i128, @intCast(closure_before)) - @as(i128, @intCast(closure_after));

        // Trigger edge = which law changed pressure the most (content-driven, not structural)
        var max_change: u128 = 0;
        var trigger_edge: usize = 0;
        for (flame.Laws, 0..) |law, i| {
            const got = law.ca * engine.state.chamber[law.a] + law.cb * engine.state.chamber[law.b];
            const p_after: u128 = @abs(got - law.t);
            const change = if (p_after > pressure_before[i]) p_after - pressure_before[i] else pressure_before[i] - p_after;
            if (change > max_change) {
                max_change = change;
                trigger_edge = i;
            }
        }

        var lore = lore_eng.LoreEngine.init(aa, 0xACE);
        lore.learn(lp.text);
        var lattice_sum: u64 = 0;
        for (lore.grammar_lattice) |val| lattice_sum ^= val;

        try stdout.print("{s: <20} | {d: >8} | {d: >4} | {X: >19} | OK\n", .{
            lp.label, delta, trigger_edge, lattice_sum,
        });
    }
}