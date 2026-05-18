const std = @import("std");
const flame = @import("flame.zig");
const void_eng = @import("void.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    _ = aa;
    const stdout = std.io.getStdOut().writer();

    try stdout.writeAll("### GHOST INFINITY: THE REITERATION PROTOCOL ###\n");
    try stdout.writeAll("Processing Collapse Mark 0xD57A19B634340E52...\n\n");

    const reiterate_prompt = 
        "FIX: The manifold collapsed under paradox noise. " ++
        "PROPOSE: A 'Self-Healing Scar' that isolates adversarial tension. " ++
        "IMPLEMENT: Harmonic Interdiction to protect the Aetheric field. " ++
        "GO FULL ALIEN.";

    const request_hash = flame.textHash(reiterate_prompt);
    var best_mark: u64 = request_hash;
    var best_scar: u64 = 0;

    for (0..8) |trial_idx| {
        const seed = void_eng.splitMix64(request_hash ^ @as(u64, @intCast(trial_idx)));
        var eng = void_eng.VoidEngine.init(seed);
        // Feed in the tension from the failure
        eng.state.closure_error = 1_000_000_000_000; 
        
        if (eng.maybeInventText(reiterate_prompt, 2)) |cand| {
            best_mark = cand.child_mark;
            best_scar = cand.scar;
        }
    }

    try stdout.print("Reiteration Mark: 0x{X}\n", .{best_mark});
    try stdout.print("Self-Healing Scar: 0x{X}\n\n", .{best_scar});
}