const std = @import("std");
const sys = @import("sys.zig");
const vsa = @import("vsa_core.zig");
const ghost_state = @import("ghost_state.zig");
const vsa_vulkan = @import("vsa_vulkan.zig");
const mc = @import("inference.zig");
const config = @import("config.zig");

pub const REASON_DEPTH: u32 = 8;
pub const REASON_TOP_K: u32 = 3;
pub const DUAL_DRIFT_MANAGER_THRESHOLD: u64 = 256;
pub const DUAL_DRIFT_CRITIC_THRESHOLD: u64 = 5;

/// V32: Resonance Self-Calibration (Fixed-Point Integer)
/// Replaces non-deterministic floating-point EMA with bit-perfect integer math.
/// Uses 24.8 fixed-point representation for average and Mean Absolute Deviation (MAD).
pub const ResonanceEMA = struct {
    average: u32 = 850 << 8, // Initial seed: 850.0
    deviation: u32 = 25 << 8, // Initial MAD: 25.0
    alpha_shift: u5 = 4, // Alpha = 1/16 (0.0625)

    pub fn update(self: *ResonanceEMA, sample: u16) void {
        const s = @as(u32, sample) << 8;
        const diff = if (s > self.average) s - self.average else self.average - s;

        // EMA update: (val * (1-alpha) + sample * alpha)
        const a = @as(u32, 1) << self.alpha_shift;
        self.average = (self.average * (a - 1) + s) >> self.alpha_shift;
        self.deviation = (self.deviation * (a - 1) + diff) >> self.alpha_shift;
    }

    pub fn getSurpriseThreshold(self: ResonanceEMA) u16 {
        // Threshold = average + 2.5 * deviation (approx 2.5 * MAD is roughly 2.0 * SD)
        const thresh = (self.average + (self.deviation * 5 / 2)) >> 8;
        return @as(u16, @intCast(@min(1024, thresh)));
    }

    pub fn getSearchThreshold(self: ResonanceEMA) u16 {
        // Threshold = average - 1.5 * deviation
        const avg = self.average >> 8;
        const dev_scaled = (self.deviation * 3 / 2) >> 8;
        return @as(u16, @intCast(if (avg > dev_scaled) avg - dev_scaled else 0));
    }
};

pub fn isAllowed(cp: u32) bool {
    if (cp > 0x10FFFF) return false;
    // Unicode standard: exclude surrogates [0xD800, 0xDFFF]
    if (cp >= 0xD800 and cp <= 0xDFFF) return false;
    // Allow all other valid codepoints
    return true;
}

pub const SoulSnapshot = struct {
    syntax: vsa.HyperVector,
    phrase: vsa.HyperVector,
    concept: vsa.HyperVector,
    global: vsa.HyperVector,
    active_context_hash: u64,
    lexical_rotor: u64,
    fractal_state: vsa.HyperVector,
    spell_vector: vsa.HyperVector,
    sentence_pool: vsa.HyperVector,
    last_energy: u16,
    last_boundary: vsa.Boundary,
};

pub fn saveSoul(soul: *const ghost_state.GhostSoul) SoulSnapshot {
    return .{
        .syntax = soul.syntax,
        .phrase = soul.phrase,
        .concept = soul.concept,
        .global = soul.global,
        .active_context_hash = soul.active_context_hash,
        .lexical_rotor = soul.lexical_rotor,
        .fractal_state = soul.fractal_state,
        .spell_vector = soul.spell_vector,
        .sentence_pool = soul.sentence_pool,
        .last_energy = soul.last_energy,
        .last_boundary = soul.last_boundary,
    };
}

pub fn restoreSoul(soul: *ghost_state.GhostSoul, snap: SoulSnapshot) void {
    soul.syntax = snap.syntax;
    soul.phrase = snap.phrase;
    soul.concept = snap.concept;
    soul.global = snap.global;
    soul.active_context_hash = snap.active_context_hash;
    soul.lexical_rotor = snap.lexical_rotor;
    soul.fractal_state = snap.fractal_state;
    soul.spell_vector = snap.spell_vector;
    soul.sentence_pool = snap.sentence_pool;
    soul.last_energy = snap.last_energy;
    soul.last_boundary = snap.last_boundary;
}

pub const SingularityEngine = struct {
    lattice: *ghost_state.UnifiedLattice,
    meaning: *vsa.MeaningMatrix,
    soul: *ghost_state.GhostSoul,
    canvas: ghost_state.MesoLattice,
    is_live: bool,
    inventory: [128]u8 = [_]u8{0} ** 128,
    inv_cursor: usize = 0,
    vulkan: ?*vsa_vulkan.VulkanEngine,
    allocator: std.mem.Allocator,
    rune_counter: u64 = 0,
    ema: ResonanceEMA = .{},

    pub fn measureNoise(self: *SingularityEngine, candidate_vec: vsa.HyperVector, position: u32) u16 {
        const pos_hash = ghost_state.wyhash(self.soul.active_context_hash, @as(u64, position));
        const target_vec = self.meaning.collapseToBinary(pos_hash);
        return vsa.resonanceScore(candidate_vec, target_vec);
    }

    pub fn resolveTopology(self: *SingularityEngine) ?u32 {
        switch (self.canvas.topology) {
            .text_1d => return self.resolveText1D(),
            .image_2d => {
                self.resolveImage2D();
                return null;
            },
            .audio_1d_time => {
                self.resolveAudio1DTime();
                return null;
            },
        }
    }

    pub fn resolveText1D(self: *SingularityEngine) ?u32 {
        const position = self.canvas.cursor;
        var top_chars: [REASON_TOP_K]u32 = [_]u32{' '} ** REASON_TOP_K;
        var top_energies: [REASON_TOP_K]u32 = [_]u32{0} ** REASON_TOP_K;
        const prev1 = self.inventory[(self.inv_cursor + 127) % 128];
        const prev2 = self.inventory[(self.inv_cursor + 126) % 128];
        const prev3 = self.inventory[(self.inv_cursor + 125) % 128];

        var gpu_success: bool = false;
        if (!config.force_cpu_inference and self.vulkan != null) {
            const vulkan = self.vulkan.?;
            if (vulkan.dispatchResonance(self.soul.lexical_rotor, self.soul.semantic_rotor)) |energies| {
                gpu_success = true;
                const boredom = self.soul.getBoredomPenalty();
                for (energies, 0..) |raw_e, i| {
                    const cb: u32 = @intCast(i);
                    if (!isAllowed(cb)) continue;
                    var energy = raw_e;
                    if (cb == prev1 and cb == prev2 and cb == prev3) energy = energy -| 50;
                    energy = energy -| boredom;
                    insertTopK(&top_chars, &top_energies, cb, energy);
                }
            } else |err| {
                sys.print("\n[VULKAN WARNING] Resonance Query Failed: {any}. Falling back to Silicon Heuristics...\n", .{err});
            }
        }

        if (!gpu_success) {
            const boredom = self.soul.getBoredomPenalty();
            const target_lex = self.meaning.collapseToBinary(self.soul.lexical_rotor);
            const target_sem = self.meaning.collapseToBinary(self.soul.semantic_rotor);
            for (0..0x1_0000) |cp_usize| {
                const cp: u32 = @intCast(cp_usize);
                if (!isAllowed(cp)) continue;

                const v = vsa.generate(cp);
                const e_lex = vsa.calculateResonance(target_lex, v);
                const e_sem = vsa.calculateResonance(target_sem, v);

                var energy: u32 = if (e_lex > 0) (e_lex * 2 + e_sem) / 3 else e_sem;
                if (energy == 0) energy = 512;
                if (cp == prev1 and cp == prev2 and cp == prev3) energy = energy -| 50;
                energy = energy -| boredom;
                insertTopK(&top_chars, &top_energies, cp, energy);
            }
        }

        const primary_concept = self.soul.concept;
        var reason_best_char: u32 = top_chars[0];

        // Beam search rollout (when Vulkan is available)
        if (!config.force_cpu_inference and self.vulkan != null) {
            const vulkan = self.vulkan.?;
            const beam = mc.BeamSearchPool.init(self.allocator, vulkan, self.meaning);
            const winner_idx = beam.resolve(self.soul, &top_chars, &top_energies) catch 0;
            reason_best_char = top_chars[winner_idx];
        } else {
            // Fallback: shallow dual-drift reasoning (no GPU)
            var reason_best_score: u32 = 0;
            var frustration: u64 = 0;

            var candidate_encoded = [_][4]u8{[_]u8{0} ** 4} ** REASON_TOP_K;
            var candidate_lens = [_]u8{0} ** REASON_TOP_K;
            var candidate_vecs = [_]vsa.HyperVector{@as(vsa.HyperVector, @splat(0))} ** REASON_TOP_K;
            for (top_chars, 0..) |candidate, ki| {
                candidate_lens[ki] = @as(u8, @intCast(std.unicode.utf8Encode(@intCast(candidate), &candidate_encoded[ki]) catch 0));
                candidate_vecs[ki] = vsa.generate(candidate);
            }

            while (true) {
                for (top_chars, 0..) |candidate, ki| {
                    if (top_energies[ki] == 0 or candidate_lens[ki] == 0) continue;
                    const snapshot = saveSoul(self.soul);

                    const len = candidate_lens[ki];
                    for (candidate_encoded[ki][0..len]) |b| {
                        self.soul.simulateAbsorb(candidate_vecs[ki], b, null) catch break;
                    }

                    // Integer-only sigmoid approximation for frustration-based leniency
                    // leniency = (200 * (f * f)) / ((f * f) + 25)
                    const f2 = frustration * frustration;
                    const sigmoid_leniency = (200 * f2) / (f2 + 25);
                    const verdict = vsa.dualDriftCheck(self.soul.concept, primary_concept, DUAL_DRIFT_MANAGER_THRESHOLD, DUAL_DRIFT_CRITIC_THRESHOLD + sigmoid_leniency);
                    if (!verdict.passed) {
                        restoreSoul(self.soul, snapshot);
                        continue;
                    }

                    const future_energy: u32 = top_energies[ki] + @as(u32, @intCast(@min(verdict.manager_drift / 4, 64)));
                    restoreSoul(self.soul, snapshot);
                    if (future_energy > reason_best_score) {
                        reason_best_score = future_energy;
                        reason_best_char = candidate;
                    }
                }
                if (reason_best_score > 0 or frustration >= 15) break;
                frustration += 1;
            }
        }

        const chosen: u32 = reason_best_char;
        const chosen_vec = vsa.generate(chosen);

        // Paranoid Oracle: verify GPU resonance matches independent CPU computation.
        // Audit 1 in 10,000 runes to catch shader/CPU divergence in Hamming distance logic.
        self.rune_counter += 1;
        if (self.rune_counter % 10000 == 0 and gpu_success) {
            if (self.vulkan) |vulkan| {
                const gpu_energies = vulkan.dispatchResonance(self.soul.lexical_rotor, self.soul.semantic_rotor) catch return chosen;
                const gpu_energy = gpu_energies[@as(usize, @intCast(chosen))];

                // Independent CPU computation
                const cpu_target_lex = self.meaning.collapseToBinary(self.soul.lexical_rotor);
                const cpu_target_sem = self.meaning.collapseToBinary(self.soul.semantic_rotor);
                const cpu_e_lex = vsa.calculateResonance(cpu_target_lex, chosen_vec);
                const cpu_e_sem = vsa.calculateResonance(cpu_target_sem, chosen_vec);
                const cpu_energy: u32 = if (cpu_e_lex > 0) (@as(u32, cpu_e_lex) * 2 + cpu_e_sem) / 3 else cpu_e_sem;

                const delta = if (gpu_energy > cpu_energy) gpu_energy - cpu_energy else cpu_energy - gpu_energy;
                if (delta > 50) {
                    sys.print("[ORACLE] CPU/GPU divergence at rune {d}: CPU={d} GPU={d} delta={d}\n", .{ self.rune_counter, cpu_energy, gpu_energy, delta });
                }
            }
        }

        // Etch chosen vector into the canvas and measure per-position noise
        if (position < self.canvas.cells.len) {
            self.canvas.cells[position] = chosen_vec;
        }
        if (position < self.canvas.noise.len) {
            self.canvas.noise[position] = self.measureNoise(chosen_vec, position);
        }
        self.canvas.advance();

        // Encode and push to inventory
        var utf8_fin: [4]u8 = undefined;
        const len_fin = std.unicode.utf8Encode(@intCast(chosen), &utf8_fin) catch 1;
        for (utf8_fin[0..len_fin]) |b| {
            self.inventory[self.inv_cursor % 128] = b;
            self.inv_cursor += 1;
        }

        // V32: Update the noise floor EMA with the chosen rune's resonance
        self.ema.update(@intCast(top_energies[0]));

        // Aggressive Uncertainty Detection: V32 "Digital Oracle"
        // Triggered via dynamic threshold derived from Hamming drift statistics
        const search_threshold = self.ema.getSearchThreshold();
        if (top_energies[0] < search_threshold and self.rune_counter > 20) {
            sys.print("\n[MONOLITH] Resonance dropped to {d} (Threshold: {d}). State depletion detected.\n", .{ top_energies[0], search_threshold });
            return 0x10FFFF; // Ghost Sigil for "Search Required"
        }

        return chosen;
    }

    /// VSA-based 2D relaxation: each cell converges toward its MeaningMatrix target
    /// while being influenced by its 4-connected neighbors via VSA bundling.
    /// Iterates until noise stabilizes or max 20 passes.
    pub fn resolveImage2D(self: *SingularityEngine) void {
        const w = self.canvas.width;
        const h = self.canvas.height;
        const left_tag = vsa.generate(0x2D00);
        const right_tag = vsa.generate(0x2D01);
        const up_tag = vsa.generate(0x2D10);
        const down_tag = vsa.generate(0x2D11);
        const target_tag = vsa.generate(0x2DFF);
        var total_noise: u64 = 0;
        var prev_noise: u64 = 0xFFFFFFFFFFFFFFFF;
        var iterations: u32 = 0;
        while (iterations < 20) : (iterations += 1) {
            total_noise = 0;
            var y: u32 = 0;
            while (y < h) : (y += 1) {
                var x: u32 = 0;
                while (x < w) : (x += 1) {
                    const idx = self.canvas.cellIndex(x, y);
                    if (idx >= self.canvas.cells.len) continue;
                    const current = self.canvas.cells[idx];
                    // Bundle with 4-connected neighbors using position-tagged identity vectors
                    var neighbor_bundle = current;
                    if (x > 0) neighbor_bundle = vsa.bundle(neighbor_bundle, self.canvas.getCell(x - 1, y), left_tag);
                    if (x < w - 1) neighbor_bundle = vsa.bundle(neighbor_bundle, self.canvas.getCell(x + 1, y), right_tag);
                    if (y > 0) neighbor_bundle = vsa.bundle(neighbor_bundle, self.canvas.getCell(x, y - 1), up_tag);
                    if (y < h - 1) neighbor_bundle = vsa.bundle(neighbor_bundle, self.canvas.getCell(x, y + 1), down_tag);
                    const pos_hash = self.canvas.coordHash(x, y);
                    const target = self.meaning.collapseToBinary(pos_hash);
                    // Converge: bundle neighbor state with the target attractor
                    self.canvas.cells[idx] = vsa.bundle(neighbor_bundle, target, target_tag);
                    const score = vsa.resonanceScore(self.canvas.cells[idx], target);
                    self.canvas.noise[idx] = score;
                    total_noise += score;
                }
            }
            if (total_noise >= prev_noise) break;
            prev_noise = total_noise;
        }
    }

    /// VSA-based 1D temporal diffusion: each cell absorbs left and right spectral
    /// context via bundling, anchored to its MeaningMatrix target at each timestep.
    pub fn resolveAudio1DTime(self: *SingularityEngine) void {
        const bins = self.canvas.width;
        const steps = self.canvas.height;
        const left_tag = vsa.generate(0xA000);
        const right_tag = vsa.generate(0xA001);
        const time_tag = vsa.generate(0xA100);
        const target_tag = vsa.generate(0xAFFF);
        var t: u32 = 0;
        while (t < steps) : (t += 1) {
            var b: u32 = 0;
            while (b < bins) : (b += 1) {
                const idx = self.canvas.cellIndex(b, t);
                if (idx >= self.canvas.cells.len) continue;
                const current = self.canvas.cells[idx];
                var ctx = current;
                if (b > 0) ctx = vsa.bundle(ctx, self.canvas.getCell(b - 1, t), left_tag);
                if (b < bins - 1) ctx = vsa.bundle(ctx, self.canvas.getCell(b + 1, t), right_tag);
                if (t > 0) ctx = vsa.bundle(ctx, self.canvas.getCell(b, t - 1), time_tag);
                const pos_hash = self.canvas.coordHash(b, t);
                const target = self.meaning.collapseToBinary(pos_hash);
                self.canvas.cells[idx] = vsa.bundle(ctx, target, target_tag);
                self.canvas.noise[idx] = vsa.resonanceScore(self.canvas.cells[idx], target);
            }
        }
    }
};

pub fn insertTopK(chars: *[REASON_TOP_K]u32, energies: *[REASON_TOP_K]u32, candidate: u32, energy: u32) void {
    var i: usize = 0;
    while (i < REASON_TOP_K) : (i += 1) {
        if (energy > energies[i]) {
            var j: usize = REASON_TOP_K - 1;
            while (j > i) : (j -= 1) {
                chars[j] = chars[j - 1];
                energies[j] = energies[j - 1];
            }
            chars[i] = candidate;
            energies[i] = energy;
            return;
        }
    }
}
