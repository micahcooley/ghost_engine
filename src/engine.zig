const std = @import("std");
const sys = @import("sys.zig");
const vsa = @import("vsa_core.zig");
const ghost_state = @import("ghost_state.zig");
const vsa_vulkan = @import("vsa_vulkan.zig");
const compute_api = @import("compute_api.zig");
const mc = @import("inference.zig");

pub const VERSION = "V27";

pub const REASON_DEPTH: u32 = 8;
pub const REASON_TOP_K: u32 = 3;
pub const KORYPHAIOS_MANAGER_THRESHOLD: u64 = 256;
pub const KORYPHAIOS_CRITIC_THRESHOLD: u64 = 5;

pub fn isAllowed(cp: u32) bool {
    if (cp > 0x10FFFF) return false;
    // ASCII Range
    if (cp < 128) {
        if (cp >= 'a' and cp <= 'z') return true;
        if (cp >= 'A' and cp <= 'Z') return true;
        if (cp >= '0' and cp <= '9') return true;
        if (cp == ' ' or cp == '.' or cp == ',' or cp == '!' or cp == '?' or cp == '\'' or cp == '"' or cp == '-') return true;
        if (cp == '\n' or cp == '\r' or cp == '\t') return true;
        return false;
    }
    // Basic Multilingual Plane (BMP) support
    // We allow any valid printable character in the BMP (0x0080 to 0xFFFF)
    // Excluding surrogates (0xD800-0xDFFF) as they aren't valid codepoints
    if (cp >= 0x0080 and cp <= 0xD7FF) return true;
    if (cp >= 0xE000 and cp <= 0xFFFF) return true;
    
    return false;
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
    last_boundary: ghost_state.Boundary,
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
    inventory: [128]u8,
    inv_cursor: usize,
    compute: ?*const compute_api.ComputeApi,
    vulkan: ?*vsa_vulkan.VulkanEngine,
    allocator: std.mem.Allocator,

    pub fn measureNoise(self: *SingularityEngine, candidate_vec: vsa.HyperVector, position: u32) u16 {
        const pos_hash = ghost_state.wyhash(self.soul.active_context_hash, @as(u64, position));
        const target_vec = self.meaning.collapseToBinary(pos_hash);
        return vsa.resonanceScore(candidate_vec, target_vec);
    }

    pub fn resolveTopology(self: *SingularityEngine) ?u8 {
        switch (self.canvas.topology) {
            .text_1d => return self.resolveText1D(),
            .image_2d => { self.resolveImage2D(); return null; },
            .audio_1d_time => { self.resolveAudio1DTime(); return null; },
        }
    }

    pub fn resolveText1D(self: *SingularityEngine) ?u8 {
        const position = self.canvas.cursor;
        var top_chars: [REASON_TOP_K]u32 = [_]u32{' '} ** REASON_TOP_K;
        var top_energies: [REASON_TOP_K]u32 = [_]u32{0} ** REASON_TOP_K;
        const prev1 = self.inventory[(self.inv_cursor + 127) % 128];
        const prev2 = self.inventory[(self.inv_cursor + 126) % 128];
        const prev3 = self.inventory[(self.inv_cursor + 125) % 128];

        var gpu_success: bool = false;
        if (self.compute) |compute| {
            if (compute.queryResonance(self.soul.lexical_rotor, self.soul.semantic_rotor, self.allocator)) |energies| {
                defer self.allocator.free(energies);
                gpu_success = true;
                const boredom = self.soul.getBoredomPenalty(self.soul.lexical_rotor);
                // V27: Heuristic Fast-Path (Top 256 common runes)
                for (energies, 0..) |raw_e, i| {
                    const cb: u32 = @intCast(i);
                    if (!isAllowed(cb)) continue;
                    var energy = raw_e;
                    if (cb == prev1 and cb == prev2 and cb == prev3) energy = energy -| 50;
                    energy = energy -| boredom;
                    insertTopK(&top_chars, &top_energies, cb, energy);
                }
            } else |_| {}
        }

        if (!gpu_success) {
            // Minimal Heuristic Fallback (replaces the exhaustive 65k BMP search)
            const boredom = self.soul.getBoredomPenalty(self.soul.lexical_rotor);
            var cp: u32 = 32;
            while (cp < 127) : (cp += 1) { // ASCII fast path only
                const e_lex = vsa.calculateResonance(self.meaning.collapseToBinary(self.soul.lexical_rotor), vsa.generate(cp));
                const e_sem = vsa.calculateResonance(self.meaning.collapseToBinary(self.soul.semantic_rotor), vsa.generate(cp));
                var energy: u32 = if (e_lex > 0) (e_lex * 2 + e_sem) / 3 else e_sem;
                if (energy == 0) energy = 512;
                if (cp == prev1 and cp == prev2 and cp == prev3) energy = energy -| 50;
                energy = energy -| boredom;
                insertTopK(&top_chars, &top_energies, cp, energy);
            }
        }

        const primary_concept = self.soul.concept;
        var reason_best_char: u32 = top_chars[0];

        // System 2: Monte Carlo rollout (when Vulkan is available)
        if (self.vulkan) |vk_engine| {
            const mc_engine = mc.MonteCarloEngine.init(self.allocator, vk_engine, self.meaning);
            const winner_idx = mc_engine.resolve(self.soul, &top_chars, &top_energies);
            reason_best_char = top_chars[winner_idx];
        } else {
            // Fallback: shallow koryphaios reasoning (no GPU)
            var reason_best_score: u32 = 0;
            var frustration: u64 = 0;

            while (true) {
                for (top_chars, 0..) |candidate, ki| {
                    if (top_energies[ki] == 0) continue;
                    const snapshot = saveSoul(self.soul);

                    var utf8_buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(@intCast(candidate), &utf8_buf) catch {
                        restoreSoul(self.soul, snapshot);
                        continue;
                    };

                    for (utf8_buf[0..len]) |b| {
                        self.soul.simulateAbsorb(vsa.generate(b), b, null);
                    }

                    const sigmoid_leniency = (200 * (frustration * frustration)) / ((frustration * frustration) + 25);
                    const verdict = vsa.koryphaiosBrickwall(self.soul.concept, primary_concept, KORYPHAIOS_MANAGER_THRESHOLD, KORYPHAIOS_CRITIC_THRESHOLD + sigmoid_leniency);
                    if (!verdict.passed) { restoreSoul(self.soul, snapshot); continue; }

                    const future_energy: u32 = top_energies[ki] + @as(u32, @intCast(@min(verdict.manager_drift / 4, 64)));
                    restoreSoul(self.soul, snapshot);
                    if (future_energy > reason_best_score) { reason_best_score = future_energy; reason_best_char = candidate; }
                }
                if (reason_best_score > 0 or frustration >= 15) break;
                frustration += 1;
            }
        }

        const chosen: u32 = reason_best_char;
        const chosen_vec = vsa.generate(chosen);
        self.canvas.setCell(position, 0, chosen_vec);
        self.canvas.noise[position] = self.measureNoise(chosen_vec, position);
        self.canvas.advance();

        // Encode and push to inventory
        var utf8_fin: [4]u8 = undefined;
        const len_fin = std.unicode.utf8Encode(@intCast(chosen), &utf8_fin) catch 1;
        for (utf8_fin[0..len_fin]) |b| {
            self.inventory[self.inv_cursor % 128] = b;
            self.inv_cursor += 1;
        }

        return if (chosen < 256) @intCast(@as(u8, @truncate(chosen))) else '?';
    }

    pub fn resolveImage2D(self: *SingularityEngine) void {
        const w = self.canvas.width; const h = self.canvas.height;
        var total_noise: u64 = 0; var prev_noise: u64 = 0xFFFFFFFFFFFFFFFF; var iterations: u32 = 0;
        while (iterations < 20) : (iterations += 1) {
            total_noise = 0;
            var y: u32 = 0; while (y < h) : (y += 1) {
                var x: u32 = 0; while (x < w) : (x += 1) {
                    const idx = self.canvas.cellIndex(x, y); const current = self.canvas.cells[idx];
                    var neighbor_bundle = current;
                    if (x > 0) neighbor_bundle = vsa.bundle(neighbor_bundle, self.canvas.getCell(x - 1, y), vsa.generate(0x2D00));
                    if (x < w - 1) neighbor_bundle = vsa.bundle(neighbor_bundle, self.canvas.getCell(x + 1, y), vsa.generate(0x2D01));
                    if (y > 0) neighbor_bundle = vsa.bundle(neighbor_bundle, self.canvas.getCell(x, y - 1), vsa.generate(0x2D10));
                    if (y < h - 1) neighbor_bundle = vsa.bundle(neighbor_bundle, self.canvas.getCell(x, y + 1), vsa.generate(0x2D11));
                    const pos_hash = self.canvas.coordHash(x, y); const target = self.meaning.collapseToBinary(pos_hash);
                    self.canvas.cells[idx] = vsa.bundle(neighbor_bundle, target, vsa.generate(0x2DFF));
                    const score = vsa.resonanceScore(self.canvas.cells[idx], target); self.canvas.noise[idx] = score; total_noise += score;
                }
            }
            if (total_noise >= prev_noise) break; prev_noise = total_noise;
        }
    }

    pub fn resolveAudio1DTime(self: *SingularityEngine) void {
        const bins = self.canvas.width; const steps = self.canvas.height;
        var t: u32 = 0; while (t < steps) : (t += 1) {
            var b: u32 = 0; while (b < bins) : (b += 1) {
                const idx = self.canvas.cellIndex(b, t); const current = self.canvas.cells[idx];
                var ctx = current;
                if (b > 0) ctx = vsa.bundle(ctx, self.canvas.getCell(b - 1, t), vsa.generate(0xA000));
                if (b < bins - 1) ctx = vsa.bundle(ctx, self.canvas.getCell(b + 1, t), vsa.generate(0xA001));
                if (t > 0) ctx = vsa.bundle(ctx, self.canvas.getCell(b, t - 1), vsa.generate(0xA100));
                const pos_hash = self.canvas.coordHash(b, t); const target = self.meaning.collapseToBinary(pos_hash);
                self.canvas.cells[idx] = vsa.bundle(ctx, target, vsa.generate(0xAFFF));
                self.canvas.noise[idx] = vsa.resonanceScore(self.canvas.cells[idx], target);
            }
        }
    }
};

pub fn insertTopK(chars: *[REASON_TOP_K]u32, energies: *[REASON_TOP_K]u32, candidate: u32, energy: u32) void {
    var i: usize = 0; while (i < REASON_TOP_K) : (i += 1) {
        if (energy > energies[i]) {
            var j: usize = REASON_TOP_K - 1; while (j > i) : (j -= 1) { chars[j] = chars[j - 1]; energies[j] = energies[j - 1]; }
            chars[i] = candidate; energies[i] = energy; return;
        }
    }
}
