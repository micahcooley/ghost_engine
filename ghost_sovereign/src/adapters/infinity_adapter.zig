const std = @import("std");
const infinity = @import("infinity_core");

// THE GHOST INFINITY ADAPTER
// The anti-fragile, hardware-native mind.

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const stdout = std.io.getStdOut().writer();

    try stdout.writeAll("### GHOST INFINITY: HARDWARE ORGANISM PROBE ###\n");
    
    var core = try infinity.InfinityCore.init(aa);
    defer core.deinit();

    const intent = "Isolate the logic paradox and stabilize the hardware manifold.";
    try stdout.print("Input Pulse: {s}\n", .{intent});

    const dict = [_][]const u8{
        "Hardware", "Organism", "Infinity", "Stability", "Aether", "Resonance",
        "Quarantine", "Self-Healing", "Paradox", "Logic", "Chaos", "Pulse",
    };

    try core.resolve(intent, &dict, stdout);
    
    try stdout.writeAll("\n[System] Infinity Manifold Stable. Recursive Recirculation Active.\n");
}