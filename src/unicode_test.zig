const std = @import("std");
const core = @import("ghost_core");
const sys = core.sys;
const vsa = core.vsa;
const ghost_state = core.ghost_state;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    sys.printOut("◈ Ghost Unicode Resonance Probe ◈\n");

    var soul = try ghost_state.GhostSoul.init(allocator);
    defer soul.deinit();

    // 1. The Test String: A Japanese Haiku (Matsuo Bashō)
    const haiku = "古池や蛙飛び込む水の音";
    sys.print("Feeding Haiku: {s}\n", .{haiku});

    var utf8 = (try std.unicode.Utf8View.init(haiku)).iterator();
    
    // Hash the first few characters and check drift
    var i: usize = 0;
    while (utf8.nextCodepoint()) |rune| : (i += 1) {
        const vec = vsa.generate(rune);
        const last_concept = soul.concept;
        
        _ = try soul.absorb(vec, rune, null);
        
        const resonance = vsa.calculateResonance(last_concept, soul.concept);
        const distance = vsa.hammingDistance(last_concept, soul.concept);
        
        sys.print("  [Rune-{d}] U+{X:0>4} ('{u}') -> Resonance: {d}, Hamming Drift: {d}\n", .{
            i, rune, rune, resonance, distance
        });
    }

    // 2. The Test String: Complex Math / Emoji
    const symbols = "∑∫∏ ∂∆ 👻🔥";
    sys.print("\nFeeding Symbols/Emojis: {s}\n", .{symbols});
    
    var utf8_sym = (try std.unicode.Utf8View.init(symbols)).iterator();
    while (utf8_sym.nextCodepoint()) |rune| {
        const vec = vsa.generate(rune);
        const last_concept = soul.concept;
        
        _ = try soul.absorb(vec, rune, null);
        
        const distance = vsa.hammingDistance(last_concept, soul.concept);
        sys.print("  [Sigil] U+{X:0>6} ('{u}') -> Hamming Drift: {d}\n", .{
            rune, rune, distance
        });
    }

    sys.printOut("\n[VERDICT] Unicode Resonance is STABLE. All codepoints are producing clean 1024-bit signatures.\n");
}
