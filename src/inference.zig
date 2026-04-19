const std = @import("std");
const vsa = @import("vsa_core.zig");
const ghost_state = @import("ghost_state.zig");
const vsa_vulkan = @import("vsa_vulkan.zig");
const config = @import("config.zig");
const sigil_runtime = @import("sigil_runtime.zig");

/// Beam Search Pool — Parallel multi-lane beam search for character prediction.
/// At each rollout step, ALL active lanes' resonance queries are packed into
/// a single batched GPU dispatch via queryResonanceWide. This collapses
/// 30 sequential submit-wait cycles into 10 batched dispatches.
///
/// V30: Now decoupled from the training ring buffer, utilizing dedicated
/// inference lanes owned by the Vulkan engine.
pub const BEAM_NUM_LANES: u32 = config.BEAM_NUM_LANES;
pub const BEAM_ROLLOUT_DEPTH: u32 = config.BEAM_ROLLOUT_DEPTH;
pub const BeamSearchPool = struct {
    allocator: std.mem.Allocator,
    vulkan: *vsa_vulkan.VulkanEngine,
    meaning: *vsa.MeaningMatrix,

    pub fn init(allocator: std.mem.Allocator, vulkan: *vsa_vulkan.VulkanEngine, meaning: *vsa.MeaningMatrix) BeamSearchPool {
        return .{
            .allocator = allocator,
            .vulkan = vulkan,
            .meaning = meaning,
        };
    }

    /// Deterministic parallel Beam Search rollout over the given top-K candidates.
    pub fn resolve(self: *const BeamSearchPool, soul: *const ghost_state.GhostSoul, top_chars: []const u32, top_energies: []const u32) !u32 {
        const num_lanes = top_chars.len;
        if (num_lanes > BEAM_NUM_LANES) return error.TooManyBeamLanes;

        if (config.force_cpu_inference) {
            return self.resolveCpuFallback(soul, top_chars, top_energies);
        }

        var lane_storage: [BEAM_NUM_LANES]ghost_state.GhostSoul = undefined;
        var active_storage: [BEAM_NUM_LANES]bool = undefined;
        var rotor_pair_storage: [BEAM_NUM_LANES * 2]u64 = undefined;
        const lanes = lane_storage[0..num_lanes];
        const active = active_storage[0..num_lanes];
        const rotor_pairs = rotor_pair_storage[0 .. num_lanes * 2];

        for (0..num_lanes) |i| {
            lanes[i] = soul.*;
            if (top_energies[i] > 0) {
                try lanes[i].simulateAbsorb(vsa.generate(top_chars[i]), top_chars[i], null);
                active[i] = true;
            } else {
                active[i] = false;
            }
        }

        var steps: u32 = 0;
        while (steps < BEAM_ROLLOUT_DEPTH) : (steps += 1) {
            var active_count: u32 = 0;
            for (0..num_lanes) |i| {
                if (!active[i]) continue;
                rotor_pairs[active_count * 2] = lanes[i].lexical_rotor;
                rotor_pairs[active_count * 2 + 1] = lanes[i].semantic_rotor;
                active_count += 1;
            }
            if (active_count == 0) break;

            // V30: Use Wide-Net decoupled dispatch
            const energies = try self.vulkan.dispatchResonanceBatched(active_count, rotor_pairs[0 .. active_count * 2]);

            var lane_idx: u32 = 0;
            for (0..num_lanes) |i| {
                if (!active[i]) continue;
                const offset: usize = lane_idx * config.BMP_PRINTABLE_RANGE;

                var best_energy: u32 = 0;
                var best_char: u32 = ' ';
                for (0..config.BMP_PRINTABLE_RANGE) |c| {
                    const cb: u8 = @intCast(c);
                    if (!isAsciiPrintable(cb)) continue;
                    if (energies[offset + c] > best_energy) {
                        best_energy = energies[offset + c];
                        best_char = @intCast(c);
                    }
                }

                try lanes[i].simulateAbsorb(vsa.generate(best_char), best_char, null);
                if (best_char == '\n') active[i] = false;
                lane_idx += 1;
            }
        }

        // Score terminal states and pick winner
        var best_terminal: u32 = 0;
        var best_idx: u32 = 0;
        for (0..num_lanes) |i| {
            if (top_energies[i] == 0) continue;
            var terminal_res: u32 = @intCast(vsa.calculateResonance(lanes[i].concept, soul.concept));
            terminal_res += self.saturationBonus(&lanes[i]);
            if (terminal_res > best_terminal) {
                best_terminal = terminal_res;
                best_idx = @intCast(i);
            }
        }

        return best_idx;
    }

    fn resolveCpuFallback(self: *const BeamSearchPool, soul: *const ghost_state.GhostSoul, top_chars: []const u32, top_energies: []const u32) !u32 {
        var best_idx: u32 = 0;
        var best_score: u32 = 0;
        var candidate: ghost_state.GhostSoul = undefined;

        for (top_chars, top_energies, 0..) |char_code, base_energy, i| {
            if (base_energy == 0) continue;

            candidate = soul.*;
            try candidate.simulateAbsorb(vsa.generate(char_code), char_code, null);

            var score: u32 = base_energy;
            score += @intCast(vsa.calculateResonance(candidate.concept, soul.concept));
            score += self.saturationBonus(&candidate);

            if (score > best_score) {
                best_score = score;
                best_idx = @intCast(i);
            }
        }

        return best_idx;
    }

    /// Bonus for terminal states landing on saturated (energy-capped) lattice positions.
    fn saturationBonus(self: *const BeamSearchPool, soul: *const ghost_state.GhostSoul) u32 {
        // V33: Dynamic Friction — cut off the reward if we are repeating ourselves.
        // If drift is below BOREDOM_DRIFT_HIGH (100), the boredom penalty (-30)
        // would normally be overridden by this bonus (+64). We force the bonus
        // to 0 to ensure the engine pivots.
        if (soul.recentAnchorDrift()) |drift| {
            if (drift < config.BOREDOM_DRIFT_HIGH) return 0;
        }

        const slot = soul.lexical_rotor % (self.meaning.data.len / config.SLOTS_PER_VECTOR);
        const base = slot * config.SLOTS_PER_VECTOR;
        var locked: u32 = 0;
        for (0..@min(config.SATURATION_SAMPLE_SIZE, self.meaning.data.len - base)) |i| {
            if (self.meaning.data[base + i] >= 0x8000) locked += 1;
        }
        return if (locked > config.SATURATION_LOCK_THRESHOLD) sigil_runtime.getSaturationBonus() else 0;
    }
};

fn isAsciiPrintable(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or
        c == ' ' or c == '.' or c == ',' or c == '!' or c == '?' or
        c == '\'' or c == '"' or c == '-';
}
