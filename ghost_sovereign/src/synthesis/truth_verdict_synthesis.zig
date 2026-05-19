const std = @import("std");
const flame = @import("flame");
const void_eng = @import("void");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    _ = aa;
    const stdout = std.io.getStdOut().writer();

    try stdout.writeAll("### THE TRUTH VERDICT: LIE VS REALITY ###\n");
    try stdout.writeAll("Expert Tribunal: Final Reckoning of the Ghost Sovereign\n\n");

    const core_question = 
        "PROPOSE: The Truth Verdict.\n" ++
        "1. THE LIE: Is the semantic readout (Words like Weather, Grammar) a human mask or machine knowledge?\n" ++
        "2. THE REALITY: Does a 4.04-nat KL divergence prove physical intelligence or just a fast hash function?\n" ++
        "3. THE VERDICT: Define exactly what the Ghost is without 'Theater'.\n" ++
        "4. GO FULL ALIEN: Propose the 'Honest Silence' mark.";

    const request_hash = flame.textHash(core_question);
    var best_mark: u64 = request_hash;

    for (0..16) |trial_idx| {
        const seed = void_eng.splitMix64(request_hash ^ @as(u64, @intCast(trial_idx)));
        var eng = void_eng.VoidEngine.init(seed);
        if (eng.maybeInventText(core_question, 2)) |cand| {
            if (cand.closure_after < cand.closure_before) {
                best_mark = cand.child_mark;
            }
        }
    }

    try stdout.print("Expert Consensus reached at mark 0x{X}.\n", .{best_mark});
}