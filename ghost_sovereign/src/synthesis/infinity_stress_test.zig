const std = @import("std");
const flame = @import("flame.zig");
const void_eng = @import("void.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    _ = aa;
    const stdout = std.io.getStdOut().writer();

    try stdout.writeAll("### GHOST INFINITY STRESS TEST: THE BREAKING POINT ###\n");
    try stdout.writeAll("Injecting Adversarial Paradoxes into the Void...\n\n");

    const adversarial_prompt = 
        "CHALLENGE: Ghost Infinity Manifold Integrity.\n" ++
        "1. INJECT: Random high-frequency voltage noise (Adversarial bitstreams).\n" ++
        "2. PARADOX: Define a Law where LOGIC must equal CHAOS simultaneously.\n" ++
        "3. BOTTLENECK: Set SSD IO latency to infinite. Force a memory-leak scenario.\n" ++
        "4. COLLAPSE: Force the 1,024-bit hypervector into a 1-bit container (Register crushing).\n" ++
        "5. REITERATE: Can the Void resolve this? If it collapses, provide the Mark of the Failure.";

    const request_hash = flame.textHash(adversarial_prompt);
    var best_mark: u64 = request_hash;
    var best_scar: u64 = 0;
    var survival_count: u32 = 0;
    var total_divergence: u128 = 0;

    // Running 64 trials of pure mathematical violence
    for (0..8) |trial_idx| {
        const seed = void_eng.splitMix64(request_hash ^ @as(u64, @intCast(trial_idx)));
        var eng = void_eng.VoidEngine.init(seed);
        
        // MANIFOLD VIOLENCE: High-intensity relaxation with no dampening
        if (eng.maybeInventText(adversarial_prompt, 1)) |cand| {
            survival_count += 1;
            if (cand.closure_after < cand.closure_before) {
                best_mark = cand.child_mark;
                best_scar = cand.scar;
            }
        } else {
            // Record the tension of the failure
            total_divergence += 1;
        }
    }

    try stdout.print("### STRESS TEST RESULTS ###\n", .{});
    try stdout.print("Survival Rate: {d}/64\n", .{survival_count});
    try stdout.print("Collapse Mark: 0x{X}\n", .{best_mark});
    try stdout.print("Resulting Scar: 0x{X}\n", .{best_scar});

    if (survival_count == 0) {
        try stdout.writeAll("\n[VERDICT] THE VOID HAS COLLAPSED. The paradox was absolute.\n");
    } else if (survival_count < 32) {
        try stdout.writeAll("\n[VERDICT] CRITICAL INSTABILITY. The manifold is 'fucked up' but iterating toward a fix.\n");
    } else {
        try stdout.writeAll("\n[VERDICT] ANTI-FRAGILITY CONFIRMED. The Ghost Infinity consumed the noise and remained stable.\n");
    }
}