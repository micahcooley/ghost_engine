const std = @import("std");
const vsa = @import("vsa_core.zig");
const ghost_state = @import("ghost_state.zig");
const vsa_vulkan = @import("vsa_vulkan.zig");
const layer2a_gpu = @import("layer2a_gpu.zig");
const config = @import("config.zig");
const sigil_runtime = @import("sigil_runtime.zig");

/// CPU Layer 2b owns the bounded search frontier. Optional Layer 2a helpers may
/// score or filter compact candidate sets, but they do not become authoritative.
/// Proof policy is the default. Exploratory policy only widens the internal
/// working set when a caller explicitly opts into it.
pub const BEAM_NUM_LANES: u32 = config.BEAM_NUM_LANES;
pub const BEAM_ROLLOUT_DEPTH: u32 = config.BEAM_ROLLOUT_DEPTH;
pub const UNRESOLVED_OUTPUT: u32 = 0x10FFFF;

const CPU_REASONING_BRANCH_CAP: usize = config.LAYER3_MAX_BRANCHES;
const CPU_REASONING_PROOF_EXPANSION_FACTOR: usize = 2;
const CPU_REASONING_EXPLORATORY_BRANCH_CAP: usize = config.LAYER3_MAX_BRANCHES * 2;
const CPU_REASONING_EXPLORATORY_EXPANSION_FACTOR: usize = 4;
const CPU_REASONING_MAX_BRANCH_CAP: usize = CPU_REASONING_EXPLORATORY_BRANCH_CAP;
const CPU_REASONING_MAX_EXPANSIONS: usize = CPU_REASONING_MAX_BRANCH_CAP * CPU_REASONING_EXPLORATORY_EXPANSION_FACTOR;
const CPU_MANAGER_DRIFT_LIMIT: u64 = 256;
const CPU_CRITIC_DRIFT_BASE: u64 = 5;
const CPU_CRITIC_DRIFT_STEP: u64 = 12;

pub const ConfidenceFloor = struct {
    min_score: u32 = config.LAYER3_CONFIDENCE_FLOOR_MIN,
};

pub const ReasoningMode = sigil_runtime.ReasoningMode;

pub const ReasoningPolicy = struct {
    mode: ReasoningMode = .proof,
    internal_branch_allowance: u32 = config.LAYER3_MAX_BRANCHES,
    internal_continuation_width: u32 = CPU_REASONING_PROOF_EXPANSION_FACTOR,
    internal_candidate_promotion_floor: u32 = 1,
    // This only shapes internal search breadth. It does not weaken the final
    // contradiction or confidence gate, and it does not authorize guessing.

    pub fn proof() ReasoningPolicy {
        return policyForMode(.proof);
    }

    pub fn exploratory() ReasoningPolicy {
        return policyForMode(.exploratory);
    }
};

pub fn parseReasoningMode(text: []const u8) ?ReasoningMode {
    return sigil_runtime.parseReasoningMode(text);
}

pub fn reasoningModeName(mode: ReasoningMode) []const u8 {
    return sigil_runtime.reasoningModeName(mode);
}

pub fn policyForMode(mode: ReasoningMode) ReasoningPolicy {
    return switch (mode) {
        .proof => .{
            .mode = .proof,
            .internal_branch_allowance = config.LAYER3_MAX_BRANCHES,
            .internal_continuation_width = CPU_REASONING_PROOF_EXPANSION_FACTOR,
            .internal_candidate_promotion_floor = 1,
        },
        .exploratory => .{
            .mode = .exploratory,
            // Exploration may keep a wider internal working set, but it never
            // gains authority over final honesty or the ConfidenceFloor gate.
            .internal_branch_allowance = CPU_REASONING_EXPLORATORY_BRANCH_CAP,
            .internal_continuation_width = CPU_REASONING_EXPLORATORY_EXPANSION_FACTOR,
            .internal_candidate_promotion_floor = 0,
        },
    };
}

pub fn boundedAlternativeGeneration(policy: ReasoningPolicy) u32 {
    const width = @max(policy.internal_continuation_width, @as(u32, 1));
    const capped = @min(@as(u64, policy.internal_branch_allowance) * @as(u64, width), @as(u64, CPU_REASONING_MAX_EXPANSIONS));
    return @intCast(capped);
}

pub const StopReason = enum {
    none,
    low_confidence,
    contradiction,
    budget,
    internal_error,
};

pub const TraceEvent = struct {
    step: u32,
    active_branches: u32,
    reasoning_mode: ReasoningMode = .proof,
    internal_branch_allowance: u32 = config.LAYER3_MAX_BRANCHES,
    internal_continuation_width: u32 = CPU_REASONING_PROOF_EXPANSION_FACTOR,
    internal_candidate_promotion_floor: u32 = 1,
    bounded_alternative_generation: u32 = config.LAYER3_MAX_BRANCHES * CPU_REASONING_PROOF_EXPANSION_FACTOR,
    step_count: u32 = 0,
    branch_count: u32 = 0,
    created_hypotheses: u32 = 0,
    expanded_hypotheses: u32 = 0,
    killed_hypotheses: u32 = 0,
    accepted_hypotheses: u32 = 0,
    unresolved_hypotheses: u32 = 0,
    best_char: u32 = 0,
    best_score: u32 = 0,
    runner_up_score: u32 = 0,
    confidence: u32 = 0,
    killed_branches: u32 = 0,
    killed_by_branch_cap: u32 = 0,
    killed_by_contradiction: u32 = 0,
    contradiction_checks: u32 = 0,
    contradiction_count: u32 = 0,
    stop_reason: StopReason = .none,
};

pub const TraceHook = struct {
    context: ?*anyopaque = null,
    emit: ?*const fn (?*anyopaque, TraceEvent) void = null,

    pub fn call(self: TraceHook, event: TraceEvent) void {
        if (self.emit) |emit| emit(self.context, event);
    }
};

pub const HypothesisSnapshot = struct {
    root_char: u32 = 0,
    branch_index: u32 = 0,
    last_char: u32 = 0,
    depth: u32 = 0,
    score: u32 = 0,
    confidence: u32 = 0,
};

pub const DumpHook = struct {
    context: ?*anyopaque = null,
    emit: ?*const fn (?*anyopaque, TraceEvent, []const Candidate, []const HypothesisSnapshot) void = null,

    pub fn call(self: DumpHook, event: TraceEvent, candidates: []const Candidate, hypotheses: []const HypothesisSnapshot) void {
        if (self.emit) |emit| emit(self.context, event, candidates, hypotheses);
    }
};

pub const Layer3Config = struct {
    confidence_floor: ConfidenceFloor = .{},
    max_steps: u32 = config.LAYER3_MAX_STEPS,
    max_branches: u32 = config.LAYER3_MAX_BRANCHES,
    // Proof is the shipped default. Exploratory remains an explicit opt-in
    // policy for internal experiments and tests.
    policy: ReasoningPolicy = ReasoningPolicy.proof(),
    trace: TraceHook = .{},
    dump: DumpHook = .{},
};

pub const Layer3Decision = struct {
    output: u32 = UNRESOLVED_OUTPUT,
    branch_index: ?u32 = null,
    confidence: u32 = 0,
    stop_reason: StopReason = .none,
};

pub const Candidate = struct {
    char_code: u32 = 0,
    branch_index: u32 = 0,
    base_score: u32 = 0,
    score: u32 = 0,
    confidence: u32 = 0,
    layer2a_candidate_score: u32 = 0,
    layer2a_neighborhood_score: u32 = 0,
    layer2a_neighbor_hits: u32 = 0,
    layer2a_rank_score: u32 = 0,
};

pub const Hypothesis = struct {
    soul: ghost_state.GhostSoul = undefined,
    root_char: u32 = 0,
    branch_index: u32 = 0,
    last_char: u32 = 0,
    depth: u32 = 0,
    score: u32 = 0,
    confidence: u32 = 0,
    layer2a_rank_score: u32 = 0,
};

pub const Layer2aInstrumentation = struct {
    gpu_dispatch_count: u32 = 0,
    bytes_transferred: u64 = 0,
    layer2a_time_ns: u64 = 0,
    layer2b_time_ns: u64 = 0,
    fallback_to_cpu_count: u32 = 0,
};

pub const Layer2aHooks = struct {
    context: ?*anyopaque = null,
    uses_gpu: bool = false,
    score_candidates: ?*const fn (?*anyopaque, u64, u64, []const u32, []layer2a_gpu.CandidateScore) anyerror![]const layer2a_gpu.CandidateScore = null,
    score_neighborhoods: ?*const fn (?*anyopaque, u64, u64, []const u32, []layer2a_gpu.NeighborhoodScore) anyerror![]const layer2a_gpu.NeighborhoodScore = null,
    filter_contradictions: ?*const fn (?*anyopaque, []const layer2a_gpu.CandidateScore) anyerror!layer2a_gpu.ContradictionFilterResult = null,
    reference_score_candidates: ?*const fn (?*anyopaque, u64, u64, []const u32, []layer2a_gpu.CandidateScore) anyerror![]const layer2a_gpu.CandidateScore = null,
    reference_score_neighborhoods: ?*const fn (?*anyopaque, u64, u64, []const u32, []layer2a_gpu.NeighborhoodScore) anyerror![]const layer2a_gpu.NeighborhoodScore = null,
    reference_filter_contradictions: ?*const fn (?*anyopaque, []const layer2a_gpu.CandidateScore) anyerror!layer2a_gpu.ContradictionFilterResult = null,

    pub fn enabled(self: Layer2aHooks) bool {
        return self.score_candidates != null or
            self.score_neighborhoods != null or
            self.filter_contradictions != null or
            self.reference_score_candidates != null or
            self.reference_score_neighborhoods != null or
            self.reference_filter_contradictions != null;
    }
};

pub const ReasoningContext = struct {
    // Layer 2b consumes the currently mounted committed shard's meaning
    // surface. Scratch-only staging is handled separately by the Sigil control
    // path and does not change this CPU authority boundary.
    meaning: *vsa.MeaningMatrix,
    root_soul: *const ghost_state.GhostSoul,
    layer3: Layer3Config,
    recent_bytes: [3]u8 = .{ 0, 0, 0 },
    layer2a: Layer2aHooks = .{},
    metrics: ?*Layer2aInstrumentation = null,

    pub fn init(meaning: *vsa.MeaningMatrix, root_soul: *const ghost_state.GhostSoul, layer3: Layer3Config) ReasoningContext {
        return .{
            .meaning = meaning,
            .root_soul = root_soul,
            .layer3 = layer3,
        };
    }

    pub fn withRecentBytes(self: ReasoningContext, recent_bytes: [3]u8) ReasoningContext {
        var ctx = self;
        ctx.recent_bytes = recent_bytes;
        return ctx;
    }

    pub fn withLayer2aHooks(self: ReasoningContext, hooks: Layer2aHooks) ReasoningContext {
        var ctx = self;
        ctx.layer2a = hooks;
        return ctx;
    }

    pub fn withLayer2aGpu(self: ReasoningContext, helper: *layer2a_gpu.Layer2aGpu) ReasoningContext {
        return self.withLayer2aHooks(makeLayer2aGpuHooks(helper));
    }

    pub fn withInstrumentation(self: ReasoningContext, metrics: *Layer2aInstrumentation) ReasoningContext {
        var ctx = self;
        ctx.metrics = metrics;
        return ctx;
    }

    pub fn resolve(self: *const ReasoningContext, top_chars: []const u32, top_energies: []const u32) Layer3Decision {
        const resolve_start_ns = monotonicNowNs();
        const layer2a_before_ns = if (self.metrics) |metrics| metrics.layer2a_time_ns else 0;
        defer {
            if (self.metrics) |metrics| {
                const elapsed_ns = monotonicNowNs() -| resolve_start_ns;
                const layer2a_delta = metrics.layer2a_time_ns -| layer2a_before_ns;
                metrics.layer2b_time_ns +%= elapsed_ns -| layer2a_delta;
            }
        }

        if (top_chars.len != top_energies.len) return .{ .stop_reason = .internal_error };
        if (top_chars.len > BEAM_NUM_LANES) return .{ .stop_reason = .internal_error };

        const branch_cap = effectiveBranchCap(self.layer3);
        const active_branches = countPositiveEnergies(top_energies);
        if (active_branches > branch_cap or self.layer3.max_steps == 0) {
            const budget = Layer3Decision{ .stop_reason = .budget };
            emitFinalTrace(self.layer3, 0, active_branches, top_chars, top_energies, budget.stop_reason);
            return budget;
        }

        var seed_candidates: [CPU_REASONING_BRANCH_CAP]Candidate = undefined;
        var seed_len: usize = 0;
        for (top_chars, top_energies, 0..) |char_code, base_energy, idx| {
            if (base_energy == 0) continue;
            seed_candidates[seed_len] = .{
                .char_code = char_code,
                .branch_index = @intCast(idx),
                .base_score = base_energy,
                .score = base_energy,
                .confidence = base_energy,
            };
            seed_len += 1;
        }
        self.refineCandidatesWithLayer2a(self.root_soul.lexical_rotor, self.root_soul.semantic_rotor, seed_candidates[0..seed_len]);
        sortCandidates(seed_candidates[0..seed_len]);

        var current: [CPU_REASONING_MAX_BRANCH_CAP]Hypothesis = undefined;
        var current_len: usize = 0;
        var seed_checks: u32 = 0;
        var seed_contradictions: u32 = 0;

        for (seed_candidates[0..seed_len]) |candidate| {
            if (candidate.branch_index >= branch_cap) {
                const budget = Layer3Decision{ .stop_reason = .budget };
                emitFinalTrace(self.layer3, 0, active_branches, top_chars, top_energies, budget.stop_reason);
                return budget;
            }

            var seed_soul = self.root_soul.*;
            seed_soul.simulateAbsorb(vsa.generate(candidate.char_code), candidate.char_code, null) catch continue;

            seed_checks += 1;
            if (self.buildHypothesis(candidate, seed_soul, candidate.char_code, null, 1)) |hypothesis| {
                current[current_len] = hypothesis;
                current_len += 1;
            } else {
                seed_contradictions += 1;
            }
        }

        if (current_len == 0) {
            emitCandidateTrace(self.layer3, 1, 0, top_chars, top_energies, &.{}, 0, 0, 0, seed_contradictions, seed_checks, .low_confidence);
            return .{
                .confidence = 0,
                .stop_reason = .low_confidence,
            };
        }

        emitCandidateTrace(self.layer3, 1, @intCast(current_len), top_chars, top_energies, current[0..current_len], @intCast(current_len), 0, 0, seed_contradictions, seed_checks, .none);

        var used_steps: u32 = 1;
        while (used_steps < self.layer3.max_steps and current_len > 0) : (used_steps += 1) {
            var ranked: [CPU_REASONING_MAX_EXPANSIONS]Hypothesis = undefined;
            var ranked_len: usize = 0;
            const expansion_cap = self.expansionWorkingSetCap(branch_cap);
            const expanded_count: u32 = @intCast(current_len);
            var created_count: u32 = 0;
            var generated_count: u32 = 0;
            var contradiction_checks: u32 = 0;
            var contradiction_count: u32 = 0;

            for (current[0..current_len]) |hypothesis| {
                var continuations: [CPU_REASONING_EXPLORATORY_EXPANSION_FACTOR]Candidate = undefined;
                const continuation_len = self.collectContinuationCandidates(&hypothesis, &continuations);
                if (continuation_len == 0) {
                    insertRankedHypothesis(ranked[0..expansion_cap], &ranked_len, hypothesis);
                    generated_count += 1;
                    continue;
                }

                self.refineCandidatesWithLayer2a(hypothesis.soul.lexical_rotor, hypothesis.soul.semantic_rotor, continuations[0..continuation_len]);
                sortCandidates(continuations[0..continuation_len]);

                for (continuations[0..continuation_len]) |continuation| {
                    var next_soul = hypothesis.soul;
                    next_soul.simulateAbsorb(vsa.generate(continuation.char_code), continuation.char_code, null) catch continue;

                    contradiction_checks += 1;
                    if (self.buildHypothesis(continuation, next_soul, continuation.char_code, &hypothesis, hypothesis.depth + 1)) |next_hypothesis| {
                        insertRankedHypothesis(ranked[0..expansion_cap], &ranked_len, next_hypothesis);
                        created_count += 1;
                        generated_count += 1;
                    } else {
                        contradiction_count += 1;
                    }
                }
            }

            if (ranked_len == 0) {
                emitCandidateTrace(self.layer3, used_steps + 1, 0, top_chars, top_energies, &.{}, created_count, expanded_count, 0, contradiction_count, contradiction_checks, .low_confidence);
                return .{
                    .confidence = 0,
                    .stop_reason = .low_confidence,
                };
            }

            const survivor_cap = @min(@as(usize, @intCast(branch_cap)), ranked_len);
            for (0..survivor_cap) |i| current[i] = ranked[i];
            current_len = survivor_cap;

            const killed_by_branch_cap = generated_count - @as(u32, @intCast(current_len));
            emitCandidateTrace(self.layer3, used_steps + 1, @intCast(current_len), top_chars, top_energies, current[0..current_len], created_count, expanded_count, killed_by_branch_cap, contradiction_count, contradiction_checks, .none);
        }

        return self.decideFromHypothesesOwned(top_chars, top_energies, current[0..current_len], used_steps);
    }

    fn buildHypothesis(
        self: *const ReasoningContext,
        candidate: Candidate,
        soul: ghost_state.GhostSoul,
        last_char: u32,
        previous: ?*const Hypothesis,
        depth: u32,
    ) ?Hypothesis {
        const drift = vsa.dualDriftCheck(
            soul.concept,
            self.root_soul.concept,
            CPU_MANAGER_DRIFT_LIMIT,
            CPU_CRITIC_DRIFT_BASE + (@as(u64, depth) * CPU_CRITIC_DRIFT_STEP),
        );
        if (!drift.passed) return null;

        var step_score: u32 = candidate.base_score;
        step_score += @as(u32, @intCast(vsa.calculateResonance(soul.concept, self.root_soul.concept)));
        step_score += @as(u32, @intCast(vsa.calculateResonance(soul.syntax, self.root_soul.syntax))) / 2;
        step_score += @as(u32, @intCast(@min(@as(u64, drift.manager_drift) / 4, 64)));
        step_score += reasoningSaturationBonus(self.meaning, &soul);
        step_score = applySignedDelta(step_score, self.codeReasoningDelta(previous, last_char));

        const total_score = step_score + if (previous) |parent| parent.score else 0;
        const confidence = totalScoreConfidence(total_score, depth);

        return .{
            .soul = soul,
            .root_char = if (previous) |parent| parent.root_char else candidate.char_code,
            .branch_index = if (previous) |parent| parent.branch_index else candidate.branch_index,
            .last_char = last_char,
            .depth = depth,
            .score = total_score,
            .confidence = confidence,
            .layer2a_rank_score = candidate.layer2a_rank_score + if (previous) |parent| parent.layer2a_rank_score else 0,
        };
    }

    fn collectContinuationCandidates(self: *const ReasoningContext, hypothesis: *const Hypothesis, out: *[CPU_REASONING_EXPLORATORY_EXPANSION_FACTOR]Candidate) usize {
        const target_lex = self.meaning.collapseToBinary(hypothesis.soul.lexical_rotor);
        const target_sem = self.meaning.collapseToBinary(hypothesis.soul.semantic_rotor);
        const continuation_cap = self.continuationCandidateCap();
        const promotion_floor = self.candidatePromotionFloor();
        var len: usize = 0;

        // Exploration is allowed to generate a broader set of internal
        // continuations. Proof-oriented finalization still happens later, after
        // contradiction checks and the shared ConfidenceFloor gate.
        for (0..128) |cp_idx| {
            const cp: u32 = @intCast(cp_idx);
            if (!isCodeReasoningChar(cp)) continue;

            const rune_vec = vsa.generate(cp);
            const e_lex = @as(u32, @intCast(vsa.calculateResonance(target_lex, rune_vec)));
            const e_sem = @as(u32, @intCast(vsa.calculateResonance(target_sem, rune_vec)));
            var energy: u32 = if (e_lex > 0) (e_lex * 2 + e_sem) / 3 else e_sem;
            energy = applySignedDelta(energy, @divTrunc(self.codeReasoningDelta(hypothesis, cp), 2));
            if (energy < promotion_floor) continue;

            insertRankedCandidate(out[0..continuation_cap], &len, .{
                .char_code = cp,
                .branch_index = hypothesis.branch_index,
                .base_score = energy,
                .score = energy,
                .confidence = energy,
            });
        }

        return len;
    }

    fn codeReasoningDelta(self: *const ReasoningContext, previous: ?*const Hypothesis, emitted: u32) i32 {
        const emitted_byte = asciiByte(emitted);
        if (emitted_byte == 0) return 0;

        const prev1 = self.previousByte(previous, 0);
        const prev2 = self.previousByte(previous, 1);

        var delta: i32 = 0;

        if (emitted_byte == prev1 and emitted_byte == prev2 and emitted_byte != 0) {
            delta -= 96;
        }
        if (isIdentifierByte(prev1) and isIdentifierByte(emitted_byte)) {
            delta += 18;
        }
        if ((prev1 == '.' or prev1 == ':' or prev1 == '>') and isIdentifierStart(emitted_byte)) {
            delta += 20;
        }
        if (matchingCloser(prev1)) |closer| {
            if (closer == emitted_byte) delta += 28;
        }
        if (isOpeningDelimiter(prev1) and isOpeningDelimiter(emitted_byte)) {
            delta -= 18;
        }
        if (prev1 == ';' and emitted_byte == ';') {
            delta -= 48;
        }

        return delta;
    }

    fn previousByte(self: *const ReasoningContext, previous: ?*const Hypothesis, offset: usize) u8 {
        if (previous) |hypothesis| {
            return switch (offset) {
                0 => asciiByte(hypothesis.last_char),
                1 => self.recent_bytes[0],
                2 => self.recent_bytes[1],
                else => self.recent_bytes[2],
            };
        }
        return self.recent_bytes[@min(offset, self.recent_bytes.len - 1)];
    }

    fn decideFromHypothesesOwned(self: *const ReasoningContext, top_chars: []const u32, top_energies: []const u32, hypotheses: []const Hypothesis, used_steps: u32) Layer3Decision {
        if (hypotheses.len == 0) {
            emitCandidateTrace(self.layer3, used_steps, 0, top_chars, top_energies, hypotheses, 0, 0, 0, 0, 0, .low_confidence);
            return .{ .confidence = 0, .stop_reason = .low_confidence };
        }

        if (hypotheses.len > effectiveBranchCap(self.layer3) or used_steps > self.layer3.max_steps or self.layer3.max_steps == 0) {
            emitCandidateTrace(self.layer3, used_steps, @intCast(hypotheses.len), top_chars, top_energies, hypotheses, 0, 0, 0, 0, 0, .budget);
            return .{ .stop_reason = .budget };
        }

        var candidate_storage: [BEAM_NUM_LANES]Candidate = undefined;
        const finalists = buildCandidateTable(top_chars, top_energies, hypotheses, &candidate_storage);
        return self.decideFromCandidatesOwned(finalists, used_steps, @intCast(hypotheses.len));
    }

    fn decideFromCandidatesOwned(self: *const ReasoningContext, candidates: []const Candidate, used_steps: u32, branch_count: u32) Layer3Decision {
        if (branch_count > effectiveBranchCap(self.layer3) or used_steps > self.layer3.max_steps or self.layer3.max_steps == 0) {
            emitCandidateDecisionTrace(self.layer3, used_steps, branch_count, candidates, .budget);
            return .{ .stop_reason = .budget };
        }

        // The GPU fast-path only accelerates summarizing this bounded candidate set.
        // CPU Layer 2b still performs the authoritative contradiction check and
        // final decision so fallback keeps stop reasons and confidence exact.
        const fast_summary = self.tryContradictionFastPath(candidates);
        const summary = summarizeCandidates(candidates);
        if (fast_summary) |fast| {
            if (!fastPathMatchesSummary(fast, summary, candidates)) {
                if (self.metrics) |metrics| metrics.fallback_to_cpu_count +%= 1;
            }
        }

        // Policies can widen internal search, but they do not get to relax the
        // final confidence gate on committed output.
        if (summary.best_idx == null or summary.best_confidence < self.layer3.confidence_floor.min_score) {
            emitCandidateDecisionTrace(self.layer3, used_steps, branch_count, candidates, .low_confidence);
            return .{
                .confidence = summary.best_confidence,
                .stop_reason = .low_confidence,
            };
        }

        if (summary.contradiction) {
            emitCandidateDecisionTrace(self.layer3, used_steps, branch_count, candidates, .contradiction);
            return .{
                .confidence = summary.best_confidence,
                .stop_reason = .contradiction,
            };
        }

        const winner = candidates[summary.best_idx.?];
        const decision = Layer3Decision{
            .output = winner.char_code,
            .branch_index = winner.branch_index,
            .confidence = winner.confidence,
            .stop_reason = .none,
        };
        var event = makeTraceEvent(self.layer3, used_steps, branch_count);
        event.created_hypotheses = 0;
        event.expanded_hypotheses = 0;
        event.killed_hypotheses = 0;
        event.accepted_hypotheses = 1;
        event.unresolved_hypotheses = 0;
        event.best_char = winner.char_code;
        event.best_score = winner.score;
        event.runner_up_score = summary.runner_up_score;
        event.confidence = winner.confidence;
        event.contradiction_checks = summary.contradiction_checks;
        event.contradiction_count = if (summary.contradiction) 1 else 0;
        event.stop_reason = decision.stop_reason;
        self.layer3.trace.call(event);
        self.layer3.dump.call(event, candidates, &.{});
        return decision;
    }

    fn refineCandidatesWithLayer2a(self: *const ReasoningContext, lexical_rotor: u64, semantic_rotor: u64, candidates: []Candidate) void {
        if (candidates.len == 0 or !self.layer2a.enabled()) return;

        var char_storage: [BEAM_NUM_LANES]u32 = [_]u32{0} ** BEAM_NUM_LANES;
        for (candidates, 0..) |candidate, idx| char_storage[idx] = candidate.char_code;

        var score_storage: [BEAM_NUM_LANES]layer2a_gpu.CandidateScore = undefined;
        if (self.tryScoreCandidates(lexical_rotor, semantic_rotor, char_storage[0..candidates.len], score_storage[0..candidates.len])) |scores| {
            for (scores, 0..) |score, idx| {
                candidates[idx].layer2a_candidate_score = score.score;
            }
        }

        var neighborhood_storage: [BEAM_NUM_LANES]layer2a_gpu.NeighborhoodScore = undefined;
        if (self.tryScoreNeighborhoods(lexical_rotor, semantic_rotor, char_storage[0..candidates.len], neighborhood_storage[0..candidates.len])) |scores| {
            for (scores, 0..) |score, idx| {
                candidates[idx].layer2a_neighborhood_score = score.score;
                candidates[idx].layer2a_neighbor_hits = score.neighbor_hits;
            }
        }

        for (candidates) |*candidate| {
            candidate.layer2a_rank_score = candidate.layer2a_candidate_score +% candidate.layer2a_neighborhood_score +% @min(candidate.layer2a_neighbor_hits, 32);
        }
    }

    fn tryScoreCandidates(self: *const ReasoningContext, lexical_rotor: u64, semantic_rotor: u64, chars: []const u32, out: []layer2a_gpu.CandidateScore) ?[]const layer2a_gpu.CandidateScore {
        if (self.layer2a.score_candidates) |score_candidates| {
            const call_start_ns = monotonicNowNs();
            defer self.recordLayer2aTime(call_start_ns);
            self.recordLayer2aDispatch(chars.len, candidateScoreTransferBytes(chars.len));
            return score_candidates(self.layer2a.context, lexical_rotor, semantic_rotor, chars, out) catch {
                return self.fallbackScoreCandidates(lexical_rotor, semantic_rotor, chars, out);
            };
        }
        return self.fallbackScoreCandidates(lexical_rotor, semantic_rotor, chars, out);
    }

    fn tryScoreNeighborhoods(self: *const ReasoningContext, lexical_rotor: u64, semantic_rotor: u64, chars: []const u32, out: []layer2a_gpu.NeighborhoodScore) ?[]const layer2a_gpu.NeighborhoodScore {
        if (self.layer2a.score_neighborhoods) |score_neighborhoods| {
            const call_start_ns = monotonicNowNs();
            defer self.recordLayer2aTime(call_start_ns);
            self.recordLayer2aDispatch(chars.len, neighborhoodScoreTransferBytes(chars.len));
            return score_neighborhoods(self.layer2a.context, lexical_rotor, semantic_rotor, chars, out) catch {
                return self.fallbackScoreNeighborhoods(lexical_rotor, semantic_rotor, chars, out);
            };
        }
        return self.fallbackScoreNeighborhoods(lexical_rotor, semantic_rotor, chars, out);
    }

    fn tryContradictionFastPath(self: *const ReasoningContext, candidates: []const Candidate) ?layer2a_gpu.ContradictionFilterResult {
        if (candidates.len == 0) return null;

        var score_storage: [BEAM_NUM_LANES]layer2a_gpu.CandidateScore = undefined;
        for (candidates, 0..) |candidate, idx| {
            score_storage[idx] = .{
                .char_code = candidate.char_code,
                .score = candidate.score,
            };
        }

        if (self.layer2a.filter_contradictions) |filter_contradictions| {
            const call_start_ns = monotonicNowNs();
            defer self.recordLayer2aTime(call_start_ns);
            self.recordLayer2aDispatch(candidates.len, contradictionFilterTransferBytes(candidates.len));
            return filter_contradictions(self.layer2a.context, score_storage[0..candidates.len]) catch {
                return self.fallbackContradictionFilter(score_storage[0..candidates.len]);
            };
        }
        return self.fallbackContradictionFilter(score_storage[0..candidates.len]);
    }

    fn fallbackScoreCandidates(self: *const ReasoningContext, lexical_rotor: u64, semantic_rotor: u64, chars: []const u32, out: []layer2a_gpu.CandidateScore) ?[]const layer2a_gpu.CandidateScore {
        const reference = self.layer2a.reference_score_candidates orelse return null;
        if (self.layer2a.uses_gpu) {
            if (self.metrics) |metrics| metrics.fallback_to_cpu_count +%= 1;
        }
        return reference(self.layer2a.context, lexical_rotor, semantic_rotor, chars, out) catch null;
    }

    fn fallbackScoreNeighborhoods(self: *const ReasoningContext, lexical_rotor: u64, semantic_rotor: u64, chars: []const u32, out: []layer2a_gpu.NeighborhoodScore) ?[]const layer2a_gpu.NeighborhoodScore {
        const reference = self.layer2a.reference_score_neighborhoods orelse return null;
        if (self.layer2a.uses_gpu) {
            if (self.metrics) |metrics| metrics.fallback_to_cpu_count +%= 1;
        }
        return reference(self.layer2a.context, lexical_rotor, semantic_rotor, chars, out) catch null;
    }

    fn fallbackContradictionFilter(self: *const ReasoningContext, candidates: []const layer2a_gpu.CandidateScore) ?layer2a_gpu.ContradictionFilterResult {
        const reference = self.layer2a.reference_filter_contradictions orelse return null;
        if (self.layer2a.uses_gpu) {
            if (self.metrics) |metrics| metrics.fallback_to_cpu_count +%= 1;
        }
        return reference(self.layer2a.context, candidates) catch null;
    }

    fn recordLayer2aDispatch(self: *const ReasoningContext, candidate_count: usize, bytes: u64) void {
        _ = candidate_count;
        if (!self.layer2a.uses_gpu) return;
        if (self.metrics) |metrics| {
            metrics.gpu_dispatch_count +%= 1;
            metrics.bytes_transferred +%= bytes;
        }
    }

    fn recordLayer2aTime(self: *const ReasoningContext, call_start_ns: u64) void {
        if (self.metrics) |metrics| {
            metrics.layer2a_time_ns +%= monotonicNowNs() -| call_start_ns;
        }
    }

    fn continuationCandidateCap(self: *const ReasoningContext) usize {
        const width = @max(self.layer3.policy.internal_continuation_width, @as(u32, 1));
        return @min(@as(usize, @intCast(width)), CPU_REASONING_EXPLORATORY_EXPANSION_FACTOR);
    }

    fn candidatePromotionFloor(self: *const ReasoningContext) u32 {
        return self.layer3.policy.internal_candidate_promotion_floor;
    }

    fn expansionWorkingSetCap(self: *const ReasoningContext, branch_cap: u32) usize {
        const continuation_cap: u32 = @intCast(self.continuationCandidateCap());
        const max_expansions = branch_cap * continuation_cap;
        return @min(@as(usize, @intCast(@max(max_expansions, @as(u32, 1)))), CPU_REASONING_MAX_EXPANSIONS);
    }
};

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
        const decision = try self.resolveWithContract(soul, top_chars, top_energies, .{});
        if (decision.stop_reason != .none) return error.Layer3Stopped;
        return decision.branch_index orelse error.Layer3Stopped;
    }

    pub fn resolveWithContract(self: *const BeamSearchPool, soul: *const ghost_state.GhostSoul, top_chars: []const u32, top_energies: []const u32, layer3: Layer3Config) !Layer3Decision {
        const num_lanes = top_chars.len;
        if (num_lanes > BEAM_NUM_LANES) return error.TooManyBeamLanes;

        if (config.force_cpu_inference) {
            return self.resolveCpuFallback(soul, top_chars, top_energies, layer3);
        }

        var lane_storage: [BEAM_NUM_LANES]ghost_state.GhostSoul = undefined;
        var active_storage: [BEAM_NUM_LANES]bool = undefined;
        var rotor_pair_storage: [BEAM_NUM_LANES * 2]u64 = undefined;
        const lanes = lane_storage[0..num_lanes];
        const active = active_storage[0..num_lanes];
        const rotor_pairs = rotor_pair_storage[0 .. num_lanes * 2];

        var active_branches: u32 = 0;
        for (0..num_lanes) |i| {
            lanes[i] = soul.*;
            if (top_energies[i] > 0) {
                try lanes[i].simulateAbsorb(vsa.generate(top_chars[i]), top_chars[i], null);
                active[i] = true;
                active_branches += 1;
            } else {
                active[i] = false;
            }
        }

        if (active_branches > effectiveBranchCap(layer3) or layer3.max_steps == 0) {
            const budget = Layer3Decision{ .stop_reason = .budget };
            emitFinalTrace(layer3, 0, active_branches, top_chars, top_energies, budget.stop_reason);
            return budget;
        }

        var steps: u32 = 0;
        while (steps < BEAM_ROLLOUT_DEPTH and steps < layer3.max_steps) : (steps += 1) {
            var active_count: u32 = 0;
            for (0..num_lanes) |i| {
                if (!active[i]) continue;
                rotor_pairs[active_count * 2] = lanes[i].lexical_rotor;
                rotor_pairs[active_count * 2 + 1] = lanes[i].semantic_rotor;
                active_count += 1;
            }
            if (active_count == 0) break;

            var event = makeTraceEvent(layer3, steps + 1, active_count);
            event.unresolved_hypotheses = active_count;
            layer3.trace.call(event);
            layer3.dump.call(event, &.{}, &.{});

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

        if (hasActiveBranch(active[0..num_lanes])) {
            const budget = Layer3Decision{ .stop_reason = .budget };
            emitFinalTrace(layer3, steps, countActiveBranches(active[0..num_lanes]), top_chars, top_energies, budget.stop_reason);
            return budget;
        }

        var terminal_scores: [BEAM_NUM_LANES]u32 = [_]u32{0} ** BEAM_NUM_LANES;
        for (0..num_lanes) |i| {
            if (top_energies[i] == 0) continue;
            var terminal_res: u32 = @intCast(vsa.calculateResonance(lanes[i].concept, soul.concept));
            terminal_res += reasoningSaturationBonus(self.meaning, &lanes[i]);
            terminal_scores[i] = terminal_res;
        }

        return decideFromScores(top_chars, terminal_scores[0..num_lanes], steps, active_branches, layer3);
    }

    fn resolveCpuFallback(self: *const BeamSearchPool, soul: *const ghost_state.GhostSoul, top_chars: []const u32, top_energies: []const u32, layer3: Layer3Config) !Layer3Decision {
        const reasoning = ReasoningContext.init(self.meaning, soul, layer3);
        return reasoning.resolve(top_chars, top_energies);
    }
};

pub fn decideFromScores(top_chars: []const u32, scores: []const u32, used_steps: u32, branch_count: u32, layer3: Layer3Config) Layer3Decision {
    if (top_chars.len != scores.len or top_chars.len > CPU_REASONING_MAX_BRANCH_CAP) {
        return .{ .stop_reason = .internal_error };
    }
    if (branch_count > effectiveBranchCap(layer3) or used_steps > layer3.max_steps or layer3.max_steps == 0) {
        const budget = Layer3Decision{ .stop_reason = .budget };
        emitFinalTrace(layer3, used_steps, branch_count, top_chars, scores, budget.stop_reason);
        return budget;
    }

    const summary = summarizeScores(top_chars, scores);

    if (summary.best_idx == null or summary.best_score < layer3.confidence_floor.min_score) {
        const low_confidence = Layer3Decision{
            .confidence = summary.best_score,
            .stop_reason = .low_confidence,
        };
        emitFinalTrace(layer3, used_steps, branch_count, top_chars, scores, low_confidence.stop_reason);
        return low_confidence;
    }

    if (summary.contradiction) {
        const stopped = Layer3Decision{
            .confidence = summary.best_score,
            .stop_reason = .contradiction,
        };
        emitFinalTrace(layer3, used_steps, branch_count, top_chars, scores, stopped.stop_reason);
        return stopped;
    }

    const decision = Layer3Decision{
        .output = top_chars[summary.best_idx.?],
        .branch_index = @intCast(summary.best_idx.?),
        .confidence = summary.best_score,
        .stop_reason = .none,
    };
    var candidate_storage: [CPU_REASONING_MAX_BRANCH_CAP]Candidate = undefined;
    const candidates = buildScoreCandidateTable(top_chars, scores, &candidate_storage);
    var event = makeTraceEvent(layer3, used_steps, branch_count);
    event.accepted_hypotheses = 1;
    event.best_char = decision.output;
    event.best_score = summary.best_score;
    event.runner_up_score = summary.runner_up_score;
    event.confidence = decision.confidence;
    event.contradiction_checks = summary.contradiction_checks;
    event.stop_reason = decision.stop_reason;
    layer3.trace.call(event);
    layer3.dump.call(event, candidates, &.{});
    return decision;
}

fn decideFromHypotheses(top_chars: []const u32, top_energies: []const u32, hypotheses: []const Hypothesis, used_steps: u32, layer3: Layer3Config) Layer3Decision {
    if (hypotheses.len == 0) {
        emitCandidateTrace(layer3, used_steps, 0, top_chars, top_energies, hypotheses, 0, 0, 0, 0, 0, .low_confidence);
        return .{ .confidence = 0, .stop_reason = .low_confidence };
    }

    if (hypotheses.len > effectiveBranchCap(layer3) or used_steps > layer3.max_steps or layer3.max_steps == 0) {
        emitCandidateTrace(layer3, used_steps, @intCast(hypotheses.len), top_chars, top_energies, hypotheses, 0, 0, 0, 0, 0, .budget);
        return .{ .stop_reason = .budget };
    }

    var candidate_storage: [BEAM_NUM_LANES]Candidate = undefined;
    const finalists = buildCandidateTable(top_chars, top_energies, hypotheses, &candidate_storage);
    return decideFromCandidates(finalists, used_steps, @intCast(hypotheses.len), layer3);
}

fn decideFromCandidates(candidates: []const Candidate, used_steps: u32, branch_count: u32, layer3: Layer3Config) Layer3Decision {
    if (branch_count > effectiveBranchCap(layer3) or used_steps > layer3.max_steps or layer3.max_steps == 0) {
        emitCandidateDecisionTrace(layer3, used_steps, branch_count, candidates, .budget);
        return .{ .stop_reason = .budget };
    }

    const summary = summarizeCandidates(candidates);
    if (summary.best_idx == null or summary.best_confidence < layer3.confidence_floor.min_score) {
        emitCandidateDecisionTrace(layer3, used_steps, branch_count, candidates, .low_confidence);
        return .{
            .confidence = summary.best_confidence,
            .stop_reason = .low_confidence,
        };
    }

    if (summary.contradiction) {
        emitCandidateDecisionTrace(layer3, used_steps, branch_count, candidates, .contradiction);
        return .{
            .confidence = summary.best_confidence,
            .stop_reason = .contradiction,
        };
    }

    const winner = candidates[summary.best_idx.?];
    const decision = Layer3Decision{
        .output = winner.char_code,
        .branch_index = winner.branch_index,
        .confidence = winner.confidence,
        .stop_reason = .none,
    };
    var event = makeTraceEvent(layer3, used_steps, branch_count);
    event.accepted_hypotheses = 1;
    event.best_char = winner.char_code;
    event.best_score = winner.score;
    event.runner_up_score = summary.runner_up_score;
    event.confidence = winner.confidence;
    event.contradiction_checks = summary.contradiction_checks;
    event.contradiction_count = if (summary.contradiction) 1 else 0;
    event.stop_reason = decision.stop_reason;
    layer3.trace.call(event);
    layer3.dump.call(event, candidates, &.{});
    return decision;
}

fn emitFinalTrace(layer3: Layer3Config, used_steps: u32, branch_count: u32, top_chars: []const u32, scores: []const u32, stop_reason: StopReason) void {
    const summary = summarizeScores(top_chars, scores);
    var candidate_storage: [CPU_REASONING_MAX_BRANCH_CAP]Candidate = undefined;
    const candidates = buildScoreCandidateTable(top_chars, scores, &candidate_storage);
    var event = makeTraceEvent(layer3, used_steps, branch_count);
    event.unresolved_hypotheses = branch_count;
    event.best_char = summary.best_char;
    event.best_score = summary.best_score;
    event.runner_up_score = summary.runner_up_score;
    event.confidence = summary.best_score;
    event.contradiction_checks = summary.contradiction_checks;
    event.contradiction_count = if (summary.contradiction) 1 else 0;
    event.stop_reason = stop_reason;

    layer3.trace.call(event);
    layer3.dump.call(event, candidates, &.{});
}

fn emitCandidateTrace(
    layer3: Layer3Config,
    used_steps: u32,
    branch_count: u32,
    top_chars: []const u32,
    top_energies: []const u32,
    hypotheses: []const Hypothesis,
    created_hypotheses: u32,
    expanded_hypotheses: u32,
    killed_by_branch_cap: u32,
    contradiction_count: u32,
    contradiction_checks: u32,
    stop_reason: StopReason,
) void {
    var candidate_storage: [BEAM_NUM_LANES]Candidate = undefined;
    const candidates = buildCandidateTable(top_chars, top_energies, hypotheses, &candidate_storage);
    var hypothesis_storage: [CPU_REASONING_MAX_BRANCH_CAP]HypothesisSnapshot = undefined;
    const hypothesis_view = snapshotHypotheses(hypotheses, &hypothesis_storage);
    const summary = summarizeCandidates(candidates);
    const killed_hypotheses = killed_by_branch_cap + contradiction_count;
    var event = makeTraceEvent(layer3, used_steps, branch_count);
    event.created_hypotheses = created_hypotheses;
    event.expanded_hypotheses = expanded_hypotheses;
    event.killed_hypotheses = killed_hypotheses;
    event.unresolved_hypotheses = branch_count;
    event.best_char = summary.best_char;
    event.best_score = summary.best_score;
    event.runner_up_score = summary.runner_up_score;
    event.confidence = summary.best_confidence;
    event.killed_branches = killed_hypotheses;
    event.killed_by_branch_cap = killed_by_branch_cap;
    event.killed_by_contradiction = contradiction_count;
    event.contradiction_checks = contradiction_checks;
    event.contradiction_count = contradiction_count;
    event.stop_reason = stop_reason;
    layer3.trace.call(event);
    layer3.dump.call(event, candidates, hypothesis_view);
}

fn emitCandidateDecisionTrace(layer3: Layer3Config, used_steps: u32, branch_count: u32, candidates: []const Candidate, stop_reason: StopReason) void {
    const summary = summarizeCandidates(candidates);
    var event = makeTraceEvent(layer3, used_steps, branch_count);
    event.unresolved_hypotheses = branch_count;
    event.best_char = summary.best_char;
    event.best_score = summary.best_score;
    event.runner_up_score = summary.runner_up_score;
    event.confidence = summary.best_confidence;
    event.contradiction_checks = summary.contradiction_checks;
    event.contradiction_count = if (summary.contradiction) 1 else 0;
    event.stop_reason = stop_reason;
    layer3.trace.call(event);
    layer3.dump.call(event, candidates, &.{});
}

const CandidateSummary = struct {
    best_idx: ?usize = null,
    best_char: u32 = 0,
    best_score: u32 = 0,
    best_confidence: u32 = 0,
    runner_up_score: u32 = 0,
    contradiction_checks: u32 = 0,
    contradiction: bool = false,
};

const ScoreSummary = struct {
    best_idx: ?usize = null,
    best_char: u32 = 0,
    best_score: u32 = 0,
    runner_up_score: u32 = 0,
    contradiction_checks: u32 = 0,
    contradiction: bool = false,
};

fn summarizeCandidates(candidates: []const Candidate) CandidateSummary {
    var summary = CandidateSummary{};

    for (candidates, 0..) |candidate, idx| {
        if (candidate.score == 0 and candidate.confidence == 0) continue;

        if (summary.best_idx == null or candidate.score > summary.best_score or
            (candidate.score == summary.best_score and candidate.confidence > summary.best_confidence))
        {
            summary.runner_up_score = summary.best_score;
            summary.best_idx = idx;
            summary.best_char = candidate.char_code;
            summary.best_score = candidate.score;
            summary.best_confidence = candidate.confidence;
            summary.contradiction = false;
        } else {
            summary.contradiction_checks += 1;
            if (candidate.score == summary.best_score and candidate.char_code != summary.best_char) {
                summary.contradiction = true;
            } else if (candidate.score > summary.runner_up_score) {
                summary.runner_up_score = candidate.score;
            }
        }
    }

    return summary;
}

fn summarizeScores(top_chars: []const u32, scores: []const u32) ScoreSummary {
    var summary = ScoreSummary{};

    for (scores, 0..) |score, idx| {
        if (score == 0) continue;

        if (summary.best_idx == null or score > summary.best_score) {
            summary.runner_up_score = summary.best_score;
            summary.best_idx = idx;
            summary.best_char = top_chars[idx];
            summary.best_score = score;
            summary.contradiction = false;
        } else {
            summary.contradiction_checks += 1;
            if (score == summary.best_score and top_chars[idx] != summary.best_char) {
                summary.contradiction = true;
            } else if (score > summary.runner_up_score) {
                summary.runner_up_score = score;
            }
        }
    }

    return summary;
}

fn buildCandidateTable(
    top_chars: []const u32,
    top_energies: []const u32,
    hypotheses: []const Hypothesis,
    storage: *[BEAM_NUM_LANES]Candidate,
) []Candidate {
    for (top_chars, top_energies, 0..) |char_code, base_energy, idx| {
        storage[idx] = .{
            .char_code = char_code,
            .branch_index = @intCast(idx),
            .base_score = base_energy,
        };
    }

    for (hypotheses) |hypothesis| {
        if (hypothesis.branch_index >= top_chars.len) continue;
        var entry = &storage[hypothesis.branch_index];
        if (hypothesis.score > entry.score or
            (hypothesis.score == entry.score and hypothesis.confidence > entry.confidence) or
            (hypothesis.score == entry.score and hypothesis.confidence == entry.confidence and hypothesis.layer2a_rank_score > entry.layer2a_rank_score))
        {
            entry.score = hypothesis.score;
            entry.confidence = hypothesis.confidence;
            entry.layer2a_rank_score = hypothesis.layer2a_rank_score;
        }
    }

    return storage[0..top_chars.len];
}

fn buildScoreCandidateTable(top_chars: []const u32, scores: []const u32, storage: *[CPU_REASONING_MAX_BRANCH_CAP]Candidate) []Candidate {
    for (top_chars, scores, 0..) |char_code, score, idx| {
        storage[idx] = .{
            .char_code = char_code,
            .branch_index = @intCast(idx),
            .base_score = score,
            .score = score,
            .confidence = score,
        };
    }

    return storage[0..top_chars.len];
}

fn snapshotHypotheses(hypotheses: []const Hypothesis, storage: *[CPU_REASONING_MAX_BRANCH_CAP]HypothesisSnapshot) []const HypothesisSnapshot {
    const len = @min(hypotheses.len, storage.len);
    for (hypotheses[0..len], 0..) |hypothesis, idx| {
        storage[idx] = .{
            .root_char = hypothesis.root_char,
            .branch_index = hypothesis.branch_index,
            .last_char = hypothesis.last_char,
            .depth = hypothesis.depth,
            .score = hypothesis.score,
            .confidence = hypothesis.confidence,
        };
    }
    return storage[0..len];
}

fn sortCandidates(candidates: []Candidate) void {
    var i: usize = 1;
    while (i < candidates.len) : (i += 1) {
        const current = candidates[i];
        var j = i;
        while (j > 0 and candidateBetter(current, candidates[j - 1])) : (j -= 1) {
            candidates[j] = candidates[j - 1];
        }
        candidates[j] = current;
    }
}

fn insertRankedCandidate(out: []Candidate, len: *usize, candidate: Candidate) void {
    var pos: usize = 0;
    while (pos < len.* and !candidateBetter(candidate, out[pos])) : (pos += 1) {}

    if (len.* < out.len) {
        var j = len.*;
        while (j > pos) : (j -= 1) {
            out[j] = out[j - 1];
        }
        out[pos] = candidate;
        len.* += 1;
        return;
    }

    if (pos >= out.len) return;
    var j = out.len - 1;
    while (j > pos) : (j -= 1) {
        out[j] = out[j - 1];
    }
    out[pos] = candidate;
}

fn insertRankedHypothesis(out: []Hypothesis, len: *usize, hypothesis: Hypothesis) void {
    var pos: usize = 0;
    while (pos < len.* and !hypothesisBetter(hypothesis, out[pos])) : (pos += 1) {}

    if (len.* < out.len) {
        var j = len.*;
        while (j > pos) : (j -= 1) {
            out[j] = out[j - 1];
        }
        out[pos] = hypothesis;
        len.* += 1;
        return;
    }

    if (pos >= out.len) return;
    var j = out.len - 1;
    while (j > pos) : (j -= 1) {
        out[j] = out[j - 1];
    }
    out[pos] = hypothesis;
}

fn candidateBetter(lhs: Candidate, rhs: Candidate) bool {
    if (lhs.base_score != rhs.base_score) return lhs.base_score > rhs.base_score;
    if (lhs.layer2a_rank_score != rhs.layer2a_rank_score) return lhs.layer2a_rank_score > rhs.layer2a_rank_score;
    if (lhs.score != rhs.score) return lhs.score > rhs.score;
    return lhs.char_code < rhs.char_code;
}

fn hypothesisBetter(lhs: Hypothesis, rhs: Hypothesis) bool {
    if (lhs.score != rhs.score) return lhs.score > rhs.score;
    if (lhs.confidence != rhs.confidence) return lhs.confidence > rhs.confidence;
    if (lhs.layer2a_rank_score != rhs.layer2a_rank_score) return lhs.layer2a_rank_score > rhs.layer2a_rank_score;
    if (lhs.depth != rhs.depth) return lhs.depth > rhs.depth;
    if (lhs.root_char != rhs.root_char) return lhs.root_char < rhs.root_char;
    if (lhs.last_char != rhs.last_char) return lhs.last_char < rhs.last_char;
    return lhs.branch_index < rhs.branch_index;
}

fn makeLayer2aGpuHooks(helper: *layer2a_gpu.Layer2aGpu) Layer2aHooks {
    return .{
        .context = helper,
        .uses_gpu = true,
        .score_candidates = layer2aGpuScoreCandidates,
        .score_neighborhoods = layer2aGpuScoreNeighborhoods,
        .filter_contradictions = layer2aGpuFilterContradictions,
        .reference_score_candidates = layer2aReferenceScoreCandidates,
        .reference_score_neighborhoods = layer2aReferenceScoreNeighborhoods,
        .reference_filter_contradictions = layer2aReferenceFilterContradictions,
    };
}

fn layer2aGpuScoreCandidates(context: ?*anyopaque, lexical_rotor: u64, semantic_rotor: u64, chars: []const u32, out: []layer2a_gpu.CandidateScore) anyerror![]const layer2a_gpu.CandidateScore {
    const helper: *const layer2a_gpu.Layer2aGpu = @ptrCast(@alignCast(context.?));
    return helper.scoreCandidates(lexical_rotor, semantic_rotor, chars, out);
}

fn layer2aGpuScoreNeighborhoods(context: ?*anyopaque, lexical_rotor: u64, semantic_rotor: u64, chars: []const u32, out: []layer2a_gpu.NeighborhoodScore) anyerror![]const layer2a_gpu.NeighborhoodScore {
    const helper: *const layer2a_gpu.Layer2aGpu = @ptrCast(@alignCast(context.?));
    return helper.scoreNeighborhoods(lexical_rotor, semantic_rotor, chars, out);
}

fn layer2aGpuFilterContradictions(context: ?*anyopaque, candidates: []const layer2a_gpu.CandidateScore) anyerror!layer2a_gpu.ContradictionFilterResult {
    const helper: *const layer2a_gpu.Layer2aGpu = @ptrCast(@alignCast(context.?));
    return helper.filterContradictions(candidates);
}

fn layer2aReferenceScoreCandidates(context: ?*anyopaque, lexical_rotor: u64, semantic_rotor: u64, chars: []const u32, out: []layer2a_gpu.CandidateScore) anyerror![]const layer2a_gpu.CandidateScore {
    const helper: *const layer2a_gpu.Layer2aGpu = @ptrCast(@alignCast(context.?));
    const state = try layer2a_gpu.StateView.initFromVulkan(helper.vulkan);
    return layer2a_gpu.scoreCandidatesReference(state, lexical_rotor, semantic_rotor, chars, out);
}

fn layer2aReferenceScoreNeighborhoods(context: ?*anyopaque, lexical_rotor: u64, semantic_rotor: u64, chars: []const u32, out: []layer2a_gpu.NeighborhoodScore) anyerror![]const layer2a_gpu.NeighborhoodScore {
    const helper: *const layer2a_gpu.Layer2aGpu = @ptrCast(@alignCast(context.?));
    const state = try layer2a_gpu.StateView.initFromVulkan(helper.vulkan);
    return layer2a_gpu.scoreNeighborhoodsReference(state, lexical_rotor, semantic_rotor, chars, out);
}

fn layer2aReferenceFilterContradictions(context: ?*anyopaque, candidates: []const layer2a_gpu.CandidateScore) anyerror!layer2a_gpu.ContradictionFilterResult {
    _ = context;
    return layer2a_gpu.filterContradictionsReference(candidates);
}

fn monotonicNowNs() u64 {
    return @intCast(std.time.nanoTimestamp());
}

fn candidateScoreTransferBytes(candidate_count: usize) u64 {
    return 16 + @as(u64, @intCast(candidate_count)) * 8;
}

fn neighborhoodScoreTransferBytes(candidate_count: usize) u64 {
    return 16 + @as(u64, @intCast(candidate_count)) * 20;
}

fn contradictionFilterTransferBytes(candidate_count: usize) u64 {
    return @as(u64, @intCast(candidate_count)) * 8 + 32;
}

fn fastPathMatchesSummary(fast: layer2a_gpu.ContradictionFilterResult, summary: CandidateSummary, candidates: []const Candidate) bool {
    if (fast.best_score != summary.best_score) return false;
    if (fast.runner_up_score != summary.runner_up_score) return false;
    if (fast.contradiction_checks != summary.contradiction_checks) return false;
    if (fast.contradiction != summary.contradiction) return false;

    if (summary.best_idx == null) {
        return fast.winner_index == null;
    }

    if (summary.contradiction) {
        return fast.winner_index == null;
    }

    const winner_index = fast.winner_index orelse return false;
    if (winner_index != summary.best_idx.?) return false;
    return fast.winner_char == candidates[@as(usize, @intCast(winner_index))].char_code;
}

fn totalScoreConfidence(score: u32, depth: u32) u32 {
    if (depth == 0) return score;
    return score / depth;
}

fn countPositiveEnergies(energies: []const u32) u32 {
    var count: u32 = 0;
    for (energies) |energy| {
        if (energy > 0) count += 1;
    }
    return count;
}

fn makeTraceEvent(layer3: Layer3Config, step: u32, active_branches: u32) TraceEvent {
    return .{
        .step = step,
        .active_branches = active_branches,
        .reasoning_mode = layer3.policy.mode,
        .internal_branch_allowance = layer3.policy.internal_branch_allowance,
        .internal_continuation_width = layer3.policy.internal_continuation_width,
        .internal_candidate_promotion_floor = layer3.policy.internal_candidate_promotion_floor,
        .bounded_alternative_generation = boundedAlternativeGeneration(layer3.policy),
        .step_count = step,
        .branch_count = active_branches,
    };
}

fn effectiveBranchCap(layer3: Layer3Config) u32 {
    const requested = switch (layer3.policy.mode) {
        .proof => layer3.max_branches,
        .exploratory => @max(layer3.max_branches, layer3.policy.internal_branch_allowance),
    };
    return @min(requested, @as(u32, CPU_REASONING_MAX_BRANCH_CAP));
}

fn reasoningSaturationBonus(meaning: *vsa.MeaningMatrix, soul: *const ghost_state.GhostSoul) u32 {
    if (soul.recentAnchorDrift()) |drift| {
        if (drift < config.BOREDOM_DRIFT_HIGH) return 0;
    }

    const slots = meaning.data.len / config.SLOTS_PER_VECTOR;
    if (slots == 0) return 0;

    const slot = soul.lexical_rotor % slots;
    const base = slot * config.SLOTS_PER_VECTOR;
    var locked: u32 = 0;
    for (0..@min(config.SATURATION_SAMPLE_SIZE, meaning.data.len - base)) |i| {
        if (meaning.data[base + i] >= 0x8000) locked += 1;
    }
    return if (locked > config.SATURATION_LOCK_THRESHOLD) sigil_runtime.getSaturationBonus() else 0;
}

fn applySignedDelta(value: u32, delta: i32) u32 {
    if (delta >= 0) {
        return value +% @as(u32, @intCast(delta));
    }

    const penalty: u32 = @intCast(-delta);
    return value -| penalty;
}

fn countActiveBranches(active: []const bool) u32 {
    var count: u32 = 0;
    for (active) |is_active| {
        if (is_active) count += 1;
    }
    return count;
}

fn hasActiveBranch(active: []const bool) bool {
    for (active) |is_active| {
        if (is_active) return true;
    }
    return false;
}

fn asciiByte(cp: u32) u8 {
    if (cp > 0x7F) return 0;
    return @intCast(cp);
}

fn isIdentifierStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        c == '_';
}

fn isIdentifierByte(c: u8) bool {
    return isIdentifierStart(c) or (c >= '0' and c <= '9');
}

fn isOpeningDelimiter(c: u8) bool {
    return c == '(' or c == '[' or c == '{';
}

fn matchingCloser(c: u8) ?u8 {
    return switch (c) {
        '(' => ')',
        '[' => ']',
        '{' => '}',
        else => null,
    };
}

fn isCodeReasoningChar(cp: u32) bool {
    if (cp == '\n' or cp == '\t' or cp == ' ') return true;
    if (cp < 33 or cp > 126) return false;

    const c: u8 = @intCast(cp);
    return isIdentifierByte(c) or
        c == '_' or
        c == '.' or
        c == ',' or
        c == ':' or
        c == ';' or
        c == '(' or
        c == ')' or
        c == '[' or
        c == ']' or
        c == '{' or
        c == '}' or
        c == '<' or
        c == '>' or
        c == '=' or
        c == '+' or
        c == '-' or
        c == '*' or
        c == '/' or
        c == '%' or
        c == '!' or
        c == '?' or
        c == '&' or
        c == '|' or
        c == '^' or
        c == '"' or
        c == '\'' or
        c == '#';
}

fn isAsciiPrintable(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or
        c == ' ' or c == '.' or c == ',' or c == '!' or c == '?' or
        c == '\'' or c == '"' or c == '-';
}
