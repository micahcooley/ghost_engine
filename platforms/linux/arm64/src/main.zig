const std = @import("std");
const sys = @import("../../../../src/sys.zig");
const vsa = @import("../../../../src/vsa_core.zig");
const ghost_state = @import("../../../../src/ghost_state.zig");
const vsa_vulkan = @import("../../../../src/vsa_vulkan.zig");

const PRINTABLE_START: u16 = 0;
const PRINTABLE_END: u16 = 256;

const REASON_DEPTH: u32 = 8;
const REASON_TOP_K: u32 = 3;
const KORYPHAIOS_MANAGER_THRESHOLD: u64 = 256;
const KORYPHAIOS_CRITIC_THRESHOLD: u64 = 5;

fn isAllowed(c: u8) bool {
    if (c >= 'a' and c <= 'z') return true;
    if (c >= 'A' and c <= 'Z') return true;
    if (c >= '0' and c <= '9') return true;
    if (c == ' ' or c == '.' or c == ',' or c == '!' or c == '?' or c == '\'' or c == '"' or c == '-') return true;
    return false;
}

const SparseDelta = extern struct {
    index: u32,
    delta: i16,
};

const SoulSnapshot = struct {
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

fn saveSoul(soul: *const ghost_state.GhostSoul) SoulSnapshot {
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

fn restoreSoul(soul: *ghost_state.GhostSoul, snap: SoulSnapshot) void {
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

const SingularityEngine = struct {
    lattice: *ghost_state.UnifiedLattice,
    meaning: *vsa.MeaningMatrix,
    soul: *ghost_state.GhostSoul,
    canvas: ghost_state.MesoLattice,
    is_live: bool,
    inventory: [128]u8,
    inv_cursor: usize,
    vk_engine: ?*vsa_vulkan.VulkanEngine,

    fn measureNoise(self: *SingularityEngine, candidate_vec: vsa.HyperVector, position: u32) u16 {
        const pos_hash = ghost_state.wyhash(self.soul.active_context_hash, @as(u64, position));
        const target_vec = self.meaning.collapseToBinary(pos_hash);
        return vsa.resonanceScore(candidate_vec, target_vec);
    }

    fn resolveTopology(self: *SingularityEngine) ?u8 {
        switch (self.canvas.topology) {
            .text_1d => return self.resolveText1D(),
            .image_2d => { self.resolveImage2D(); return null; },
            .audio_1d_time => { self.resolveAudio1DTime(); return null; },
        }
    }

    fn resolveText1D(self: *SingularityEngine) ?u8 {
        const position = self.canvas.cursor;
        var top_chars: [REASON_TOP_K]u8 = [_]u8{' '} ** REASON_TOP_K;
        var top_energies: [REASON_TOP_K]u32 = [_]u32{0} ** REASON_TOP_K;
        const prev1 = self.inventory[(self.inv_cursor + 127) % 128];
        const prev2 = self.inventory[(self.inv_cursor + 126) % 128];
        const prev3 = self.inventory[(self.inv_cursor + 125) % 128];

        var gpu_success = false;
        if (self.vk_engine) |vk| {
            if (vk.dispatchResonance(self.soul.lexical_rotor, self.soul.semantic_rotor)) |energies| {
                defer vk.allocator.free(energies);
                gpu_success = true;
                const boredom = self.soul.getBoredomPenalty(self.soul.lexical_rotor);
                for (energies, 0..) |raw_e, i| {
                    const cb: u8 = @intCast(i);
                    if (!isAllowed(cb)) continue;
                    var energy = raw_e;
                    if (cb == prev1 and cb == prev2 and cb == prev3) energy = energy -| 50;
                    energy = energy -| boredom;
                    insertTopK(&top_chars, &top_energies, cb, energy);
                }
            } else |_| {}
        }

        if (!gpu_success) {
            const boredom = self.soul.getBoredomPenalty(self.soul.lexical_rotor);
            var i: u16 = 0;
            while (i < 256) : (i += 1) {
                const cb: u8 = @intCast(i);
                if (!isAllowed(cb)) continue;
                const e_lex = vsa.calculateResonance(self.meaning.collapseToBinary(self.soul.lexical_rotor), vsa.generate(cb));
                const e_sem = vsa.calculateResonance(self.meaning.collapseToBinary(self.soul.semantic_rotor), vsa.generate(cb));
                var energy: u32 = if (e_lex > 0) (e_lex * 2 + e_sem) / 3 else e_sem;
                if (energy == 0) energy = 512;
                if (cb == prev1 and cb == prev2 and cb == prev3) energy = energy -| 50;
                energy = energy -| boredom;
                insertTopK(&top_chars, &top_energies, cb, energy);
            }
        }

        const primary_concept = self.soul.concept;
        var reason_best_char: u8 = top_chars[0];
        var reason_best_score: u32 = 0;
        var frustration: u64 = 0;

        while (true) {
            for (top_chars, 0..) |candidate, ki| {
                if (top_energies[ki] == 0) continue;
                const snapshot = saveSoul(self.soul);
                const cand_vec = vsa.generate(candidate);
                self.soul.simulateAbsorb(cand_vec, candidate, null);
                const sigmoid_leniency = (200 * (frustration * frustration)) / ((frustration * frustration) + 25);
                const verdict = vsa.koryphaiosBrickwall(self.soul.concept, primary_concept, KORYPHAIOS_MANAGER_THRESHOLD, KORYPHAIOS_CRITIC_THRESHOLD + sigmoid_leniency);
                if (!verdict.passed) { restoreSoul(self.soul, snapshot); continue; }
                var future_energy: u32 = top_energies[ki] + @as(u32, @intCast(@min(verdict.manager_drift / 4, 64)));
                if (self.vk_engine) |vk| {
                    if (vk.dispatchRecursiveLookahead(REASON_TOP_K, REASON_DEPTH)) |fut_energies| {
                        defer vk.allocator.free(fut_energies);
                        future_energy += fut_energies[ki];
                    }
                }
                restoreSoul(self.soul, snapshot);
                if (future_energy > reason_best_score) { reason_best_score = future_energy; reason_best_char = candidate; }
            }
            if (reason_best_score > 0 or frustration >= 15) break;
            frustration += 1;
        }

        const chosen: u8 = if (reason_best_score > 0) reason_best_char else top_chars[0];
        const chosen_vec = vsa.generate(chosen);
        self.canvas.setCell(position, 0, chosen_vec);
        self.canvas.noise[position] = self.measureNoise(chosen_vec, position);
        self.canvas.advance();
        return chosen;
    }

    fn resolveImage2D(self: *SingularityEngine) void {
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

    fn resolveAudio1DTime(self: *SingularityEngine) void {
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

pub fn main() !void {
    sys.printOut("\nGhost V22: Symmetric Bitwise Intelligence Engine\n");
    const allocator = std.heap.page_allocator;
    sys.printOut("[MONOLITH] Mapping Cortex...\n");
    const mapped_lattice = try sys.createMappedFile("data/unified_lattice.bin", ghost_state.UNIFIED_SIZE_BYTES);
    const lattice: *ghost_state.UnifiedLattice = @as(*ghost_state.UnifiedLattice, @ptrCast(@alignCast(mapped_lattice.data.ptr)));
    sys.printOut("[MEANING] Mapping Hippocampus...\n");
    const mapped_meaning = try sys.createMappedFile("data/semantic_monolith.bin", 1024*1024*1024);
    const mapped_tags = try sys.createMappedFile("data/semantic_tags.bin", 1048576 * 8);
    var meaning_matrix = vsa.MeaningMatrix{ .data = mapped_meaning.data, .tags = @as([*]u64, @ptrCast(@alignCast(mapped_tags.data.ptr)))[0..1048576] };
    sys.printOut("[VULKAN] Initializing...\n");
    var vk_engine_opt: ?vsa_vulkan.VulkanEngine = null;
    if (vsa_vulkan.VulkanEngine.init(allocator)) |init_engine| {
        vk_engine_opt = init_engine;
        if (vk_engine_opt.?.mapped_matrix) |mm| std.mem.copyForwards(u8, mm[0..1024*1024*1024], meaning_matrix.data);
    } else |_| sys.printOut("[VULKAN] Failed.\n");
    var soul = ghost_state.GhostSoul.init(allocator); soul.meaning_matrix = &meaning_matrix;
    while (true) {
        sys.printOut("User > "); var input_buf: [1024]u8 = undefined;
        const raw_line = sys.readStdin(&input_buf) catch break; if (raw_line.len == 0) break;
        const prompt = std.mem.trim(u8, raw_line, " \r\n"); if (prompt.len == 0) continue;
        for (prompt) |byte| _ = try soul.absorb(vsa.generate(byte), byte, null);
        sys.printOut("Ghost > "); const generation_start_concept = soul.concept;
        var engine = SingularityEngine{ .lattice = lattice, .meaning = &meaning_matrix, .soul = &soul, .canvas = ghost_state.MesoLattice.initText(), .is_live = sys.isTrainerActive(), .inventory = [_]u8{0} ** 128, .inv_cursor = 0, .vk_engine = if (vk_engine_opt) |*ve| ve else null };
        while (true) {
            const chosen = engine.resolveTopology() orelse break; sys.printOut(&[_]u8{chosen});
            engine.inventory[engine.inv_cursor] = chosen; engine.inv_cursor = (engine.inv_cursor + 1) % 128;
            _ = try soul.absorb(vsa.generate(chosen), chosen, null);
            if (soul.last_boundary == .paragraph or vsa.hammingDistance(soul.concept, generation_start_concept) > 450) break;
        }
        sys.printOut("\n\n");
    }
}

fn insertTopK(chars: *[REASON_TOP_K]u8, energies: *[REASON_TOP_K]u32, candidate: u8, energy: u32) void {
    var i: usize = 0; while (i < REASON_TOP_K) : (i += 1) {
        if (energy > energies[i]) {
            var j: usize = REASON_TOP_K - 1; while (j > i) : (j -= 1) { chars[j] = chars[j - 1]; energies[j] = energies[j - 1]; }
            chars[i] = candidate; energies[i] = energy; return;
        }
    }
}
