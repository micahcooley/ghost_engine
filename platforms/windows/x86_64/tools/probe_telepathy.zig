const std = @import("std");
const vsa_core = @import("vsa_core.zig");
const ghost_state = @import("ghost_state.zig");
const sys = @import("sys.zig");

pub fn main() !void {
    const mm_path = "semantic_monolith.bin";
    const mm_size = 1024 * 1024 * 1024;
    
    const mapped_mm = try sys.openMappedFileRead(mm_path, mm_size);
    defer @as(*sys.MappedFile, @constCast(&mapped_mm)).unmap();

    const mm = vsa_core.MeaningMatrix{ .data = mapped_mm.data };

    sys.printOut("\n=== Multi-Sequence Telepathy Probe (V27.Resonance) ===\n");
    sys.printOut("Monitoring mass accumulation in the Hippocampus...\n\n");

    const targets = [_][]const u8{ "he", "an", "th" };
    var buf: [512]u8 = undefined;

    while (true) {
        for (targets) |target| {
            var rotor: u64 = ghost_state.FNV_OFFSET_BASIS;
            for (target) |ch| {
                rotor = (rotor ^ @as(u64, ch)) *% ghost_state.FNV_PRIME;
            }

            const expectation = mm.collapseToBinary(rotor);

            var top_chars = [_]u8{0} ** 3;
            var top_energies = [_]u16{0} ** 3;

            var c: u16 = 0;
            while (c < 256) : (c += 1) {
                const ch: u8 = @intCast(c);
                const reality = vsa_core.generate(@as(u64, ch));
                const energy = vsa_core.calculateResonance(expectation, reality);

                if (energy > top_energies[0]) {
                    top_energies[2] = top_energies[1];
                    top_chars[2] = top_chars[1];
                    top_energies[1] = top_energies[0];
                    top_chars[1] = top_chars[0];
                    top_energies[0] = energy;
                    top_chars[0] = ch;
                } else if (energy > top_energies[1]) {
                    top_energies[2] = top_energies[1];
                    top_chars[2] = top_chars[1];
                    top_energies[1] = energy;
                    top_chars[1] = ch;
                } else if (energy > top_energies[2]) {
                    top_energies[2] = energy;
                    top_chars[2] = ch;
                }
            }

            const line = std.fmt.bufPrint(&buf, "Target \"{s}\" -> Predictions: '{c}' ({d})  '{c}' ({d})  '{c}' ({d})\n", .{
                target,
                if (top_chars[0] >= 32 and top_chars[0] <= 126) top_chars[0] else @as(u8, '?'), top_energies[0],
                if (top_chars[1] >= 32 and top_chars[1] <= 126) top_chars[1] else @as(u8, '?'), top_energies[1],
                if (top_chars[2] >= 32 and top_chars[2] <= 126) top_chars[2] else @as(u8, '?'), top_energies[2],
            }) catch "Print Error\n";
            sys.printOut(line);
        }
        sys.printOut("\n");
        sys.sleep(3000);
    }
}
