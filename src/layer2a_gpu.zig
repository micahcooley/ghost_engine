const std = @import("std");
const config = @import("config.zig");
const vsa_vulkan = @import("vsa_vulkan.zig");

pub const MAX_CANDIDATES: usize = config.BEAM_NUM_LANES;
pub const NO_WINNER: u32 = 0xFFFFFFFF;

const SUDH_NEIGHBORHOOD_SIZE: u32 = 256;
const GRAPH_EDGES: usize = 16;
pub const GRAPH_EMPTY: u32 = 0xFFFFFFFF;
const GRAPH_MAX_HOPS: u32 = 6;
const SIGIL_SLOT_LIMIT: u32 = 128 * 1024 * 1024 / 4096;
const SIGIL_REQUIRED_WORDS: usize = @as(usize, SIGIL_SLOT_LIMIT) * 1024;

pub const CandidateScore = struct {
    char_code: u32,
    score: u32,
};

pub const NeighborhoodScore = struct {
    char_code: u32,
    score: u32,
    lexical_slot: u32,
    semantic_slot: u32,
    neighbor_hits: u32,
};

pub const ContradictionFilterResult = struct {
    winner_index: ?u32,
    winner_char: u32,
    best_score: u32,
    runner_up_score: u32,
    contradiction: bool,
    contradiction_checks: u32,
    candidate_count: u32,
    survivor_count: u32,
};

pub const StateView = struct {
    matrix_words: []const u16,
    tags: []const u64,
    sigil_words: []const u16,
    panopticon_edges: []const u32,
    slot_mask: u32,

    pub fn initFromVulkan(vulkan: *vsa_vulkan.VulkanEngine) !StateView {
        return initFromSlices(
            vulkan.getMatrixData(),
            vulkan.getTagsData(),
            vulkan.getSigilData(),
            vulkan.getPanopticonEdges(),
            vulkan.matrix_slots,
        );
    }

    pub fn initFromSlices(
        matrix_words_32: []const u32,
        tags: []const u64,
        sigil_words: []const u16,
        panopticon_edges: []const u32,
        slot_count: u32,
    ) !StateView {
        // Reference Layer 2a helpers must be able to score any mounted shard's
        // local slices, not just the process-wide Vulkan backing.
        if (slot_count == 0) return error.InvalidStateShape;
        if (matrix_words_32.len < @as(usize, slot_count) * 1024) return error.InvalidStateShape;
        if (tags.len < slot_count) return error.InvalidStateShape;
        if (panopticon_edges.len < @as(usize, slot_count) * GRAPH_EDGES) return error.InvalidStateShape;
        if ((slot_count & (slot_count - 1)) != 0) return error.InvalidStateShape;
        return .{
            .matrix_words = std.mem.bytesAsSlice(u16, std.mem.sliceAsBytes(matrix_words_32[0 .. @as(usize, slot_count) * 1024])),
            .tags = tags[0..@as(usize, slot_count)],
            .sigil_words = sigil_words,
            .panopticon_edges = panopticon_edges[0 .. @as(usize, slot_count) * GRAPH_EDGES],
            .slot_mask = slot_count - 1,
        };
    }
};

const NeighborEval = struct {
    score: u32,
    slot: u32,
    hits: u32,
};

/// Layer 2a accelerates bounded, regular scoring/filter sub-operations only.
/// These helpers never own rollout, contradiction adjudication, stop semantics,
/// or final answer selection. CPU Layer 2b remains authoritative.
pub const Layer2aGpu = struct {
    vulkan: *vsa_vulkan.VulkanEngine,

    pub fn init(vulkan: *vsa_vulkan.VulkanEngine) Layer2aGpu {
        return .{ .vulkan = vulkan };
    }

    pub fn scoreCandidates(
        self: *const Layer2aGpu,
        lexical_rotor: u64,
        semantic_rotor: u64,
        candidates: []const u32,
        out: []CandidateScore,
    ) ![]const CandidateScore {
        if (candidates.len == 0) return out[0..0];
        if (candidates.len > MAX_CANDIDATES) return error.TooManyCandidates;
        if (out.len < candidates.len) return error.OutputTooSmall;

        try validateGpuCandidateState(self.vulkan);
        const scores = try self.vulkan.dispatchLayer2aCandidateScores(lexical_rotor, semantic_rotor, candidates);
        if (scores.len != candidates.len) return error.InvalidResultShape;
        for (candidates, scores, 0..) |char_code, score, idx| {
            out[idx] = .{
                .char_code = char_code,
                .score = score,
            };
        }
        return out[0..candidates.len];
    }

    pub fn scoreNeighborhoods(
        self: *const Layer2aGpu,
        lexical_rotor: u64,
        semantic_rotor: u64,
        candidates: []const u32,
        out: []NeighborhoodScore,
    ) ![]const NeighborhoodScore {
        if (candidates.len == 0) return out[0..0];
        if (candidates.len > MAX_CANDIDATES) return error.TooManyCandidates;
        if (out.len < candidates.len) return error.OutputTooSmall;

        try validateGpuCandidateState(self.vulkan);
        const result_words = try self.vulkan.dispatchLayer2aNeighborhoodScores(lexical_rotor, semantic_rotor, candidates);
        if (result_words.len != candidates.len * 4) return error.InvalidResultShape;
        for (candidates, 0..) |char_code, idx| {
            const base = idx * 4;
            out[idx] = .{
                .char_code = char_code,
                .score = result_words[base],
                .lexical_slot = result_words[base + 1],
                .semantic_slot = result_words[base + 2],
                .neighbor_hits = result_words[base + 3],
            };
        }
        return out[0..candidates.len];
    }

    pub fn filterContradictions(self: *const Layer2aGpu, candidates: []const CandidateScore) !ContradictionFilterResult {
        if (candidates.len > MAX_CANDIDATES) return error.TooManyCandidates;

        var chars: [MAX_CANDIDATES]u32 = [_]u32{0} ** MAX_CANDIDATES;
        var scores: [MAX_CANDIDATES]u32 = [_]u32{0} ** MAX_CANDIDATES;
        for (candidates, 0..) |candidate, idx| {
            chars[idx] = candidate.char_code;
            scores[idx] = candidate.score;
        }

        const summary = try self.vulkan.dispatchLayer2aContradictionFilter(chars[0..candidates.len], scores[0..candidates.len]);
        try validateContradictionSummary(summary, chars[0..candidates.len], scores[0..candidates.len]);
        return .{
            .winner_index = if (summary.winner_index == NO_WINNER) null else summary.winner_index,
            .winner_char = summary.winner_char,
            .best_score = summary.best_score,
            .runner_up_score = summary.runner_up_score,
            .contradiction = summary.contradiction,
            .contradiction_checks = summary.contradiction_checks,
            .candidate_count = summary.candidate_count,
            .survivor_count = summary.survivor_count,
        };
    }
};

pub fn scoreCandidatesReference(
    state: StateView,
    lexical_rotor: u64,
    semantic_rotor: u64,
    candidates: []const u32,
    out: []CandidateScore,
) ![]const CandidateScore {
    if (candidates.len == 0) return out[0..0];
    if (candidates.len > MAX_CANDIDATES) return error.TooManyCandidates;
    if (out.len < candidates.len) return error.OutputTooSmall;

    for (candidates, 0..) |char_code, idx| {
        const e_lex = computeEnergy(state, lexical_rotor, char_code);
        const e_sem = computeEnergy(state, semantic_rotor, char_code);
        out[idx] = .{
            .char_code = char_code,
            .score = if (e_lex > 0) (e_lex * 2 + e_sem) / 3 else e_sem,
        };
    }
    return out[0..candidates.len];
}

pub fn scoreNeighborhoodsReference(
    state: StateView,
    lexical_rotor: u64,
    semantic_rotor: u64,
    candidates: []const u32,
    out: []NeighborhoodScore,
) ![]const NeighborhoodScore {
    if (candidates.len == 0) return out[0..0];
    if (candidates.len > MAX_CANDIDATES) return error.TooManyCandidates;
    if (out.len < candidates.len) return error.OutputTooSmall;

    for (candidates, 0..) |char_code, idx| {
        const lex_root = graphWalk(state, findSlot(state, lexical_rotor, false), char_code);
        const sem_root = graphWalk(state, findSlot(state, semantic_rotor, false), char_code);
        const lex_sigil = findSlot(state, lexical_rotor, true);
        const sem_sigil = findSlot(state, semantic_rotor, true);
        const lex_eval = bestNeighborhoodScore(state, lex_root, lex_sigil, char_code);
        const sem_eval = bestNeighborhoodScore(state, sem_root, sem_sigil, char_code);
        out[idx] = .{
            .char_code = char_code,
            .score = (lex_eval.score * 2 + sem_eval.score) / 3,
            .lexical_slot = lex_eval.slot,
            .semantic_slot = sem_eval.slot,
            .neighbor_hits = lex_eval.hits + sem_eval.hits,
        };
    }
    return out[0..candidates.len];
}

pub fn filterContradictionsReference(candidates: []const CandidateScore) ContradictionFilterResult {
    var best_idx: ?u32 = null;
    var best_char: u32 = 0;
    var best_score: u32 = 0;
    var runner_up_score: u32 = 0;
    var contradiction_checks: u32 = 0;
    var contradiction = false;

    for (candidates, 0..) |candidate, idx| {
        if (candidate.score == 0) continue;

        if (best_idx == null or candidate.score > best_score) {
            runner_up_score = best_score;
            best_idx = @intCast(idx);
            best_char = candidate.char_code;
            best_score = candidate.score;
            contradiction = false;
            continue;
        }

        contradiction_checks += 1;
        if (candidate.score == best_score and candidate.char_code != best_char) {
            contradiction = true;
        } else if (candidate.score > runner_up_score) {
            runner_up_score = candidate.score;
        }
    }

    return .{
        .winner_index = if (contradiction) null else best_idx,
        .winner_char = best_char,
        .best_score = best_score,
        .runner_up_score = runner_up_score,
        .contradiction = contradiction,
        .contradiction_checks = contradiction_checks,
        .candidate_count = @intCast(candidates.len),
        .survivor_count = if (best_idx != null and !contradiction) 1 else 0,
    };
}

fn validateGpuCandidateState(vulkan: *vsa_vulkan.VulkanEngine) !void {
    if (vulkan.matrix_slots == 0) return error.InvalidStateShape;
    if (vulkan.getTagsData().len < vulkan.matrix_slots) return error.InvalidStateShape;
    if (vulkan.getPanopticonEdges().len < @as(usize, vulkan.matrix_slots) * GRAPH_EDGES) return error.InvalidStateShape;
    if (vulkan.getSigilData().len < SIGIL_REQUIRED_WORDS) return error.InvalidStateShape;
}

fn validateContradictionSummary(
    summary: vsa_vulkan.Layer2aContradictionSummary,
    candidate_chars: []const u32,
    candidate_scores: []const u32,
) !void {
    if (summary.candidate_count != candidate_chars.len) return error.InvalidResultShape;
    if (candidate_chars.len != candidate_scores.len) return error.InvalidResultShape;

    if (summary.contradiction) {
        if (summary.winner_index != NO_WINNER) return error.InvalidResultShape;
        if (summary.survivor_count != 0) return error.InvalidResultShape;
        return;
    }

    if (summary.winner_index == NO_WINNER) {
        if (summary.best_score != 0) return error.InvalidResultShape;
        if (summary.survivor_count != 0) return error.InvalidResultShape;
        return;
    }

    if (summary.winner_index >= candidate_chars.len) return error.InvalidResultShape;
    if (summary.winner_char != candidate_chars[summary.winner_index]) return error.InvalidResultShape;
    if (summary.best_score != candidate_scores[summary.winner_index]) return error.InvalidResultShape;
    if (summary.survivor_count != 1) return error.InvalidResultShape;
}

fn findSlot(state: StateView, rotor: u64, use_sigil: bool) u32 {
    if (use_sigil) {
        const base_slot: u32 = @intCast(rotor % SIGIL_SLOT_LIMIT);
        const stride: u32 = @intCast((rotor >> 32) | 1);
        var p: u32 = 0;
        while (p < 8) : (p += 1) {
            const slot = @as(u32, @intCast((@as(u64, base_slot) + @as(u64, p) * @as(u64, stride)) % SIGIL_SLOT_LIMIT));
            const tag = tagAt(state, slot);
            if (tag == rotor or tag == 0) return slot;
        }
        return base_slot;
    }

    const slot_count_local = state.slot_mask + 1;
    const lo: u32 = @truncate(rotor);
    const wide = @as(u64, lo) * @as(u64, slot_count_local);
    const raw_base: u32 = @intCast(wide >> 32);
    const base_slot = raw_base & ~(SUDH_NEIGHBORHOOD_SIZE - 1);
    const raw_stride: u32 = @truncate(rotor >> 32);
    const stride = @max(raw_stride | 1, SUDH_NEIGHBORHOOD_SIZE + 1) | 1;

    var p: u32 = 0;
    while (p < 8) : (p += 1) {
        const slot = (base_slot +% (p *% stride)) & state.slot_mask;
        const tag = tagAt(state, slot);
        if (tag == rotor or tag == 0) return slot;
    }
    return base_slot & state.slot_mask;
}

fn slotHamming(state: StateView, slot: u32, target_char: u32) u32 {
    const m_base = @as(usize, slot) * 1024;
    var s: u64 = @as(u64, target_char) ^ 0x60bee2bee120fc15;
    const c1: u64 = 0xa3b195354a39b70d;
    const c2: u64 = 0x123456789abcdef0;
    var total: u32 = 0;

    var word: u32 = 0;
    while (word < 16) : (word += 1) {
        var collapsed: u64 = 0;
        var b: u32 = 0;
        while (b < 64) : (b += 1) {
            const val = matrixWord(state, m_base + @as(usize, word) * 64 + b);
            if (val > 32767) collapsed |= (@as(u64, 1) << @intCast(b));
        }

        s = (s ^ (s >> 33)) *% c1;
        s = (s ^ (s >> 33)) *% c2;
        s ^= s >> 33;

        const diff = collapsed ^ s;
        total +%= @popCount(@as(u32, @truncate(diff))) + @popCount(@as(u32, @truncate(diff >> 32)));
    }

    return total;
}

fn graphWalk(state: StateView, entry_slot: u32, target_char: u32) u32 {
    var current = entry_slot;
    var current_dist = slotHamming(state, current, target_char);
    if (tagAt(state, current) == 0) return current;

    var hop: u32 = 0;
    while (hop < GRAPH_MAX_HOPS) : (hop += 1) {
        const edge_base = @as(usize, current) * GRAPH_EDGES;
        var best_nb = current;
        var best_dist = current_dist;

        var e: usize = 0;
        while (e < GRAPH_EDGES) : (e += 1) {
            const nb = edgeAt(state, edge_base + e);
            if (nb == GRAPH_EMPTY or nb > state.slot_mask) continue;
            if (tagAt(state, nb) == 0) continue;

            const d = slotHamming(state, nb, target_char);
            if (d < best_dist) {
                best_dist = d;
                best_nb = nb;
            }
        }

        if (best_nb == current) break;
        current = best_nb;
        current_dist = best_dist;
    }

    return current;
}

fn rotl64(v: u64, n: u6) u64 {
    return std.math.rotl(u64, v, n);
}

fn getRealityBit(char_id: u32, bit_idx: u32) u32 {
    const word_idx = bit_idx / 64;
    var s: u64 = @as(u64, char_id) ^ 0x60bee2bee120fc15;
    const c1: u64 = 0xa3b195354a39b70d;
    const c2: u64 = 0x123456789abcdef0;

    if (word_idx < 15) {
        var i: u32 = 0;
        while (i <= word_idx) : (i += 1) {
            s = (s ^ (s >> 33)) *% c1;
            s = (s ^ (s >> 33)) *% c2;
            s ^= s >> 33;
        }
        return @intCast((s >> @intCast(bit_idx % 64)) & 1);
    }

    var parity: u64 = 0;
    var i: u32 = 0;
    while (i < 15) : (i += 1) {
        s = (s ^ (s >> 33)) *% c1;
        s = (s ^ (s >> 33)) *% c2;
        s ^= s >> 33;
        parity ^= rotl64(s, @intCast(i * 3));
        parity *%= 0xbf58476d1ce4e5b9;
    }
    return @intCast((parity >> @intCast(bit_idx % 64)) & 1);
}

fn collapseChunk(state: StateView, monolith_base: usize, sigil_base: usize, chunk_idx: u32, override_mask: u32) u32 {
    var r_monolith: u32 = 0;
    var r_sigil: u32 = 0;
    var b: u32 = 0;
    while (b < 32) : (b += 1) {
        const counter_idx = chunk_idx * 32 + b;
        const m_val = matrixWord(state, monolith_base + counter_idx);
        if (m_val > 32767) r_monolith |= (@as(u32, 1) << @intCast(b));
        const s_val = sigilWord(state, sigil_base + counter_idx);
        if (s_val > 32767) r_sigil |= (@as(u32, 1) << @intCast(b));
    }
    return r_monolith ^ ((r_monolith ^ r_sigil) & override_mask);
}

fn computeSlotEnergy(state: StateView, monolith_slot: u32, sigil_slot: u32, target_char: u32) u32 {
    const m_base = @as(usize, monolith_slot) * 1024;
    const s_base = @as(usize, sigil_slot) * 1024;

    var override_mask: u32 = 0;
    var i: u32 = 0;
    while (i < 16) : (i += 1) {
        if (sigilWord(state, s_base + @as(usize, i) * 64) > 0) {
            override_mask = 0xFFFFFFFF;
            break;
        }
    }

    var total_hamming: u32 = 0;
    var chunk: u32 = 0;
    while (chunk < 32) : (chunk += 1) {
        const expectation = collapseChunk(state, m_base, s_base, chunk, override_mask);
        var reality: u32 = 0;
        var b: u32 = 0;
        while (b < 32) : (b += 1) {
            if (getRealityBit(target_char, chunk * 32 + b) == 1) {
                reality |= (@as(u32, 1) << @intCast(b));
            }
        }
        total_hamming +%= @popCount(expectation ^ reality);
    }

    return 1024 - total_hamming;
}

fn computeEnergy(state: StateView, rotor: u64, target_char: u32) u32 {
    const entry_slot = findSlot(state, rotor, false);
    const sigil_slot = findSlot(state, rotor, true);
    const monolith_slot = graphWalk(state, entry_slot, target_char);
    return computeSlotEnergy(state, monolith_slot, sigil_slot, target_char);
}

fn bestNeighborhoodScore(state: StateView, root_slot: u32, sigil_slot: u32, target_char: u32) NeighborEval {
    var best = NeighborEval{
        .score = computeSlotEnergy(state, root_slot, sigil_slot, target_char),
        .slot = root_slot,
        .hits = if (tagAt(state, root_slot) == 0) 0 else 1,
    };

    const edge_base = @as(usize, root_slot) * GRAPH_EDGES;
    var e: usize = 0;
    while (e < GRAPH_EDGES) : (e += 1) {
        const nb = edgeAt(state, edge_base + e);
        if (nb == GRAPH_EMPTY or nb > state.slot_mask) continue;
        if (tagAt(state, nb) == 0) continue;

        best.hits += 1;
        const score = computeSlotEnergy(state, nb, sigil_slot, target_char);
        if (score > best.score) {
            best.score = score;
            best.slot = nb;
        }
    }

    return best;
}

fn matrixWord(state: StateView, idx: usize) u16 {
    return if (idx < state.matrix_words.len) state.matrix_words[idx] else 0;
}

fn sigilWord(state: StateView, idx: usize) u16 {
    return if (idx < state.sigil_words.len) state.sigil_words[idx] else 0;
}

fn tagAt(state: StateView, slot: u32) u64 {
    return if (slot < state.tags.len) state.tags[slot] else 0;
}

fn edgeAt(state: StateView, idx: usize) u32 {
    return if (idx < state.panopticon_edges.len) state.panopticon_edges[idx] else GRAPH_EMPTY;
}

test "layer2a limits stay bounded" {
    try std.testing.expectEqual(@as(usize, config.BEAM_NUM_LANES), MAX_CANDIDATES);
}

test "layer2a contradiction reference tie breaking is deterministic" {
    const candidates = [_]CandidateScore{
        .{ .char_code = 'a', .score = 99 },
        .{ .char_code = 'a', .score = 99 },
        .{ .char_code = 'b', .score = 42 },
    };
    const first = filterContradictionsReference(&candidates);
    const second = filterContradictionsReference(&candidates);

    try std.testing.expectEqualDeep(first, second);
    try std.testing.expectEqual(@as(?u32, 0), first.winner_index);
    try std.testing.expectEqual(@as(u32, 'a'), first.winner_char);
    try std.testing.expect(!first.contradiction);
}
