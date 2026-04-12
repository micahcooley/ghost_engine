const std = @import("std");
const vsa = @import("vsa_core.zig");
const ghost_state = @import("ghost_state.zig");
const vsa_vulkan = @import("vsa_vulkan.zig");

/// Monte Carlo Inference Engine (System 2 Reasoning)
/// Takes top-K candidates from fast-path resonance, then simulates each one
/// forward N steps to measure terminal coherence. The lane with the highest
/// terminal resonance wins. This replaces greedy next-rune prediction with
/// consequential reasoning.

pub const MC_NUM_LANES: u32 = 5;
pub const MC_ROLLOUT_DEPTH: u32 = 10;
pub const MSB_BONUS: u32 = 64; // Weight bonus for terminal states with MSB-locked runes

pub const MonteCarloEngine = struct {
    allocator: std.mem.Allocator,
    vulkan: *vsa_vulkan.VulkanEngine,
    meaning: *vsa.MeaningMatrix,

    pub fn init(allocator: std.mem.Allocator, vulkan: *vsa_vulkan.VulkanEngine, meaning: *vsa.MeaningMatrix) MonteCarloEngine {
        return .{
            .allocator = allocator,
            .vulkan = vulkan,
            .meaning = meaning,
        };
    }

    /// Run Monte Carlo rollout over the given top-K candidates.
    /// Returns the index into top_chars that wins.
    pub fn resolve(self: *const MonteCarloEngine, soul: *const ghost_state.GhostSoul, top_chars: []const u32, top_energies: []const u32) !u32 {
        var best_terminal: u32 = 0;
        var best_idx: u32 = 0;

        for (top_chars, 0..) |prime_char, idx| {
            if (top_energies[idx] == 0) continue;

            // Clone soul state for this lane on the heap
            var sim_soul = try self.allocator.create(ghost_state.GhostSoul);
            defer self.allocator.destroy(sim_soul);
            sim_soul.* = soul.*;
            sim_soul.simulateAbsorb(vsa.generate(prime_char), prime_char, null);

            // Roll forward
            var steps: u32 = 0;
            while (steps < MC_ROLLOUT_DEPTH) : (steps += 1) {
                const next = self.greedyStep(sim_soul) orelse break;
                sim_soul.simulateAbsorb(vsa.generate(next), next, null);
                if (next == '\n') break;
            }

            // Score: terminal resonance + MSB bonus
            var terminal_res: u32 = @intCast(vsa.calculateResonance(sim_soul.concept, soul.concept));
            terminal_res += self.msbBonus(sim_soul);

            if (terminal_res > best_terminal) {
                best_terminal = terminal_res;
                best_idx = @intCast(idx);
            }
        }

        return best_idx;
    }

    /// Single greedy step: query resonance and pick the best character
    fn greedyStep(self: *const MonteCarloEngine, soul: *ghost_state.GhostSoul) ?u8 {
        const energies = self.vulkan.dispatchResonance(soul.lexical_rotor, soul.semantic_rotor, self.allocator) catch return null;
        defer self.allocator.free(energies);

        var best_energy: u32 = 0;
        var best_char: u8 = ' ';

        for (energies, 0..) |raw_e, i| {
            const cb: u8 = @intCast(i);
            if (!isAsciiPrintable(cb)) continue;
            if (raw_e > best_energy) {
                best_energy = raw_e;
                best_char = cb;
            }
        }
        return best_char;
    }

    /// Bonus for terminal states that land on MSB-locked (myelinated) lattice positions.
    /// Checks if the meaning matrix slot for the current rotor has locked counters.
    fn msbBonus(self: *const MonteCarloEngine, soul: *const ghost_state.GhostSoul) u32 {
        const slot = soul.lexical_rotor % (self.meaning.data.len / 1024);
        const base = slot * 1024;
        var locked: u32 = 0;
        for (0..@min(64, self.meaning.data.len - base)) |i| {
            if (self.meaning.data[base + i] >= 0x8000) locked += 1;
        }
        // If more than half the sampled counters are locked, give the bonus
        return if (locked > 32) MSB_BONUS else 0;
    }
};

fn isAsciiPrintable(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or
        c == ' ' or c == '.' or c == ',' or c == '!' or c == '?' or
        c == '\'' or c == '"' or c == '-';
}
