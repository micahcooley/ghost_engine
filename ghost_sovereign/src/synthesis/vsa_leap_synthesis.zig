const std = @import("std");
const flame = @import("flame");
const void_eng = @import("void");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const stdout = std.io.getStdOut().writer();

    try stdout.writeAll("### THE VSA HYPERVECTOR LEAP: EXPERT AUDIT ###\n");
    try stdout.writeAll("Flux vs. Void: Eliminating the Modulo Word-Salad\n\n");

    const core_question = 
        "FIX: Replace modulo indexing with VSA resonance. " ++
        "PROPOSE: 1024-bit orthogonal hypervectors and unbinding search. " ++
        "GO FULL ALIEN.";

    const r = try runProbe(aa, core_question);
    try stdout.print("Expert Verdict reached at mark 0x{X}.\n", .{r.mark});
    try stdout.print("Resulting Scar: 0x{X}\n\n", .{r.scar});
}

const RoundResult = struct {
    mark: u64,
    scar: u64,
};

fn runProbe(allocator: std.mem.Allocator, prompt: []const u8) !RoundResult {
    _ = allocator;
    const request_hash = flame.textHash(prompt);
    var best_impr: u128 = 0;
    var best_mark: u64 = 0;
    var best_scar: u64 = 0;

    for (0..8) |trial_idx| {
        const seed = void_eng.splitMix64(request_hash ^ @as(u64, @intCast(trial_idx)));
        var eng = void_eng.VoidEngine.init(seed);
        if (eng.maybeInventText(prompt, 1)) |cand| {
            const impr = flame.improvementOf(cand.closure_before, cand.closure_after);
            if (impr > best_impr) {
                best_impr = impr;
                best_mark = cand.child_mark;
                best_scar = cand.scar;
            }
        }
    }
    return RoundResult{ .mark = best_mark, .scar = best_scar };
}