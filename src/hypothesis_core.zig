const std = @import("std");
const compute_budget = @import("compute_budget.zig");
const negative_knowledge = @import("negative_knowledge.zig");

pub const HypothesisKind = enum {
    possible_inconsistency,
    possible_missing_obligation,
    possible_constraint_violation,
    possible_stale_information,
    possible_ambiguity,
    possible_unsupported_claim,
    possible_optimization,
    possible_safety_issue,
    possible_compatibility_issue,
    possible_behavior_mismatch,
};

pub const HypothesisStatus = enum {
    proposed,
    triaged,
    selected_for_verification,
    verified,
    rejected,
    blocked,
    unresolved,
};

pub const TriageStatus = enum {
    selected,
    suppressed,
    duplicate,
    blocked,
    deferred,
};

pub const scoring_policy_version = "hypothesis_triage_v1";

pub const SupportPotential = enum {
    none,
    low,
    medium,
    high,
};

pub const RiskOrValueLevel = enum {
    low,
    medium,
    high,
};

pub const Hypothesis = struct {
    id: []const u8,
    artifact_scope: []const u8,
    schema_name: []const u8,
    hypothesis_kind: HypothesisKind,
    affected_entities: []const []const u8 = &.{},
    involved_relations: []const []const u8 = &.{},
    evidence_fragments: []const []const u8 = &.{},
    missing_obligations: []const []const u8 = &.{},
    suggested_action_surface: []const u8,
    verifier_hooks_needed: []const []const u8 = &.{},
    source_rule: []const u8,
    source_signals: []const []const u8 = &.{},
    support_potential: SupportPotential = .low,
    risk_or_value_level: RiskOrValueLevel = .low,
    status: HypothesisStatus = .proposed,
    non_authorizing: bool = true,
    provenance: []const u8,
    trace: []const u8,

    pub fn deinit(self: *Hypothesis, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.artifact_scope);
        allocator.free(self.schema_name);
        freeStringSlice(allocator, self.affected_entities);
        freeStringSlice(allocator, self.involved_relations);
        freeStringSlice(allocator, self.evidence_fragments);
        freeStringSlice(allocator, self.missing_obligations);
        allocator.free(self.suggested_action_surface);
        freeStringSlice(allocator, self.verifier_hooks_needed);
        allocator.free(self.source_rule);
        freeStringSlice(allocator, self.source_signals);
        allocator.free(self.provenance);
        allocator.free(self.trace);
        self.* = undefined;
    }
};

pub const HypothesisCollection = struct {
    allocator: std.mem.Allocator,
    items: []Hypothesis = &.{},
    budget_exhaustion: ?compute_budget.Exhaustion = null,

    pub fn deinit(self: *HypothesisCollection) void {
        for (self.items) |*item| item.deinit(self.allocator);
        if (self.items.len != 0) self.allocator.free(self.items);
        if (self.budget_exhaustion) |*exhaustion| exhaustion.deinit();
        self.* = undefined;
    }
};

pub const TriagePolicy = struct {
    max_hypotheses_selected: usize,
    max_hypotheses_per_artifact: usize = 2,
    max_hypotheses_per_kind: usize = 2,
    max_duplicate_groups_traced: usize = 8,
};

pub const ScoreBreakdown = struct {
    support_potential_score: u32 = 0,
    verifier_availability_score: u32 = 0,
    provenance_score: u32 = 0,
    trust_score: u32 = 0,
    freshness_score: u32 = 0,
    obligation_cost: u32 = 0,
    relation_strength_score: u32 = 0,
    novelty_score: u32 = 0,
    artifact_schema_compatibility_score: u32 = 0,
    evidence_fragment_score: u32 = 0,
    negative_score: u32 = 0,

    pub fn total(self: ScoreBreakdown) u32 {
        const positive =
            self.support_potential_score +
            self.verifier_availability_score +
            self.provenance_score +
            self.trust_score +
            self.freshness_score +
            self.relation_strength_score +
            self.novelty_score +
            self.artifact_schema_compatibility_score +
            self.evidence_fragment_score;
        if (positive <= self.obligation_cost + self.negative_score) return 0;
        return positive - self.obligation_cost - self.negative_score;
    }
};

pub const TriageItem = struct {
    hypothesis_id: []const u8,
    rank: usize = 0,
    triage_status: TriageStatus = .deferred,
    score: u32 = 0,
    score_breakdown: ScoreBreakdown = .{},
    duplicate_group_id: ?[]const u8 = null,
    suppression_reason: ?[]const u8 = null,
    required_verifiers: []const []const u8 = &.{},
    negative_knowledge_match_count: usize = 0,
    selected_for_next_stage: bool = false,
    trace: []const u8,

    pub fn deinit(self: *TriageItem, allocator: std.mem.Allocator) void {
        allocator.free(self.hypothesis_id);
        if (self.duplicate_group_id) |value| allocator.free(value);
        if (self.suppression_reason) |value| allocator.free(value);
        freeStringSlice(allocator, self.required_verifiers);
        allocator.free(self.trace);
        self.* = undefined;
    }
};

pub const TriageResult = struct {
    allocator: std.mem.Allocator,
    total: usize = 0,
    selected: usize = 0,
    suppressed: usize = 0,
    duplicates: usize = 0,
    blocked: usize = 0,
    deferred: usize = 0,
    budget_hits: usize = 0,
    hypotheses_scored: usize = 0,
    hypotheses_selected: usize = 0,
    duplicate_groups_traced: usize = 0,
    per_artifact_caps_hit: usize = 0,
    per_kind_caps_hit: usize = 0,
    scoring_policy_version: []const u8 = scoring_policy_version,
    selected_code_count: usize = 0,
    selected_non_code_count: usize = 0,
    negative_knowledge_influence_match_count: usize = 0,
    negative_knowledge_triage_penalty_count: usize = 0,
    negative_knowledge_verifier_requirement_count: usize = 0,
    negative_knowledge_suppression_count: usize = 0,
    negative_knowledge_routing_warning_count: usize = 0,
    negative_knowledge_budget_hit_count: usize = 0,
    top_selected_kinds: []const []const u8 = &.{},
    items: []TriageItem = &.{},

    pub fn deinit(self: *TriageResult) void {
        for (self.items) |*item| item.deinit(self.allocator);
        if (self.items.len != 0) self.allocator.free(self.items);
        freeStringSlice(self.allocator, self.top_selected_kinds);
        self.* = undefined;
    }
};

const RankedIndex = struct {
    index: usize,
    score: u32,
    id: []const u8,
};

const SelectionCounter = struct {
    key: []const u8,
    count: usize,
};

pub const Counts = struct {
    total_count: usize = 0,
    proposed_count: usize = 0,
    selected_count: usize = 0,
    verified_count: usize = 0,
    rejected_count: usize = 0,
    blocked_count: usize = 0,
    unresolved_count: usize = 0,
};

pub fn counts(items: []const Hypothesis) Counts {
    var out = Counts{ .total_count = items.len };
    for (items) |item| {
        switch (item.status) {
            .proposed, .triaged => out.proposed_count += 1,
            .selected_for_verification => out.selected_count += 1,
            .verified => out.verified_count += 1,
            .rejected => out.rejected_count += 1,
            .blocked => out.blocked_count += 1,
            .unresolved => out.unresolved_count += 1,
        }
    }
    return out;
}

pub fn triage(
    allocator: std.mem.Allocator,
    hypotheses: []const Hypothesis,
    policy: TriagePolicy,
) !TriageResult {
    return triageWithNegativeKnowledge(allocator, hypotheses, policy, &.{}, compute_budget.resolve(.{ .tier = .medium }));
}

pub fn triageWithNegativeKnowledge(
    allocator: std.mem.Allocator,
    hypotheses: []const Hypothesis,
    policy: TriagePolicy,
    negative_records: []const negative_knowledge.Record,
    budget: compute_budget.Effective,
) !TriageResult {
    var result = TriageResult{
        .allocator = allocator,
        .total = hypotheses.len,
        .hypotheses_scored = hypotheses.len,
    };

    if (hypotheses.len == 0) return result;

    var items = try allocator.alloc(TriageItem, hypotheses.len);
    var initialized_items: usize = 0;
    errdefer {
        for (items[0..initialized_items]) |*item| item.deinit(allocator);
        allocator.free(items);
    }
    var ranked = try allocator.alloc(RankedIndex, hypotheses.len);
    defer allocator.free(ranked);

    for (hypotheses, 0..) |hypothesis, idx| {
        var breakdown = scoreHypothesis(hypothesis);
        var influence = try negative_knowledge.influenceHypothesis(allocator, negative_records, hypothesis, budget);
        defer influence.deinit();
        if (influence.triage_delta < 0) {
            breakdown.negative_score += @intCast(-influence.triage_delta);
            result.negative_knowledge_triage_penalty_count += 1;
        }
        const score = breakdown.total();
        var trace = std.ArrayList(u8).init(allocator);
        defer trace.deinit();
        try trace.writer().print(
            "policy={s}; deterministic score from explicit hypothesis signals only; selected_for_investigation_does_not_authorize=true",
            .{scoring_policy_version},
        );
        if (influence.matched_record_ids.len > 0) {
            result.negative_knowledge_influence_match_count += influence.matched_record_ids.len;
            try trace.writer().print("; negative knowledge accepted for scoped influence matches={d}", .{influence.matched_record_ids.len});
        }
        if (influence.required_verifiers.len > 0) {
            result.negative_knowledge_verifier_requirement_count += influence.required_verifiers.len;
            try trace.writer().writeAll("; verifier requirement added");
        }
        if (influence.budget_exhausted != null) result.negative_knowledge_budget_hit_count += 1;
        result.negative_knowledge_routing_warning_count += influence.warnings.len;
        items[idx] = .{
            .hypothesis_id = try allocator.dupe(u8, hypothesis.id),
            .score = score,
            .score_breakdown = breakdown,
            .required_verifiers = try cloneStringSliceLimited(allocator, influence.required_verifiers, influence.required_verifiers.len),
            .negative_knowledge_match_count = influence.matched_record_ids.len,
            .trace = try trace.toOwnedSlice(),
        };
        initialized_items += 1;
        ranked[idx] = .{ .index = idx, .score = score, .id = hypothesis.id };
        if (isBlocked(hypothesis)) {
            items[idx].triage_status = .blocked;
            try setSuppressionReason(allocator, &items[idx], "blocked by explicit contradiction, ambiguity, or out-of-scope signal");
            result.blocked += 1;
        }
        if (influence.suppression_reason) |reason| {
            items[idx].triage_status = .suppressed;
            try setSuppressionReason(allocator, &items[idx], reason);
            result.suppressed += 1;
            result.negative_knowledge_suppression_count += 1;
        }
    }

    std.mem.sort(RankedIndex, ranked, {}, rankedLessThan);
    for (ranked, 0..) |entry, rank_idx| {
        items[entry.index].rank = rank_idx + 1;
    }

    try applyDuplicateAndDominance(allocator, hypotheses, items, &result, policy.max_duplicate_groups_traced);
    try selectRanked(allocator, hypotheses, ranked, items, &result, policy);
    result.items = items;
    items = &.{};
    result.top_selected_kinds = try selectedKindNames(allocator, hypotheses, result.items);
    return result;
}

fn rankedLessThan(_: void, lhs: RankedIndex, rhs: RankedIndex) bool {
    if (lhs.score != rhs.score) return lhs.score > rhs.score;
    return std.mem.lessThan(u8, lhs.id, rhs.id);
}

fn scoreHypothesis(hypothesis: Hypothesis) ScoreBreakdown {
    var out = ScoreBreakdown{};
    out.support_potential_score = switch (hypothesis.support_potential) {
        .none => 0,
        .low => 8,
        .medium => 16,
        .high => 24,
    };
    if (hypothesis.affected_entities.len > 0 or hasAnySignal(hypothesis, "anchor") or hasAnySignal(hypothesis, "entity")) {
        out.support_potential_score += 18;
    }
    if (hypothesis.involved_relations.len > 0 or hasAnySignal(hypothesis, "relation")) {
        out.relation_strength_score += 14 + @as(u32, @intCast(@min(hypothesis.involved_relations.len, 3))) * 4;
    }
    if (hypothesis.missing_obligations.len > 0 or hasAnySignal(hypothesis, "obligation")) {
        out.support_potential_score += 10;
    }
    out.verifier_availability_score = if (hypothesis.verifier_hooks_needed.len > 0) 16 else 0;
    out.provenance_score = if (hasAnySignal(hypothesis, "independent") or hypothesis.evidence_fragments.len > 1) 12 else 6;
    out.trust_score = trustScore(hypothesis);
    out.freshness_score = freshnessScore(hypothesis);
    out.evidence_fragment_score = @as(u32, @intCast(@min(hypothesis.evidence_fragments.len, 4))) * 5;
    out.artifact_schema_compatibility_score = if (isOutOfScope(hypothesis)) 0 else if (std.mem.indexOf(u8, hypothesis.schema_name, "fallback") != null) 3 else 10;
    out.novelty_score = 10;
    out.obligation_cost = @as(u32, @intCast(hypothesis.missing_obligations.len)) * 4;
    if (requiresVerifier(hypothesis) and hypothesis.verifier_hooks_needed.len == 0) out.negative_score += 18;
    if (hasAnySignal(hypothesis, "ambiguous") or hasAnySignal(hypothesis, "ambiguity_unresolved")) out.negative_score += 10;
    if (hasAnySignal(hypothesis, "contradiction_blocker")) out.negative_score += 25;
    if (isOutOfScope(hypothesis)) out.negative_score += 25;
    if (hypothesis.missing_obligations.len > 3) out.negative_score += @as(u32, @intCast(hypothesis.missing_obligations.len - 3)) * 6;
    return out;
}

fn trustScore(hypothesis: Hypothesis) u32 {
    if (hasAnySignal(hypothesis, "low_trust") or hasAnySignal(hypothesis, "untrusted")) return 0;
    if (hasAnySignal(hypothesis, "high_trust") or hasAnySignal(hypothesis, "verified") or hasAnySignal(hypothesis, "project")) return 16;
    return 8;
}

fn freshnessScore(hypothesis: Hypothesis) u32 {
    if (hasAnySignal(hypothesis, "stale")) return 0;
    if (hasAnySignal(hypothesis, "fresh") or hasAnySignal(hypothesis, "current")) return 12;
    return 6;
}

fn requiresVerifier(hypothesis: Hypothesis) bool {
    return std.mem.eql(u8, hypothesis.suggested_action_surface, "verify") or hypothesis.missing_obligations.len > 0;
}

fn isOutOfScope(hypothesis: Hypothesis) bool {
    return hasAnySignal(hypothesis, "out_of_scope") or std.mem.indexOf(u8, hypothesis.schema_name, "out_of_scope") != null;
}

fn isBlocked(hypothesis: Hypothesis) bool {
    return isOutOfScope(hypothesis) or hasAnySignal(hypothesis, "contradiction_blocker");
}

fn hasAnySignal(hypothesis: Hypothesis, needle: []const u8) bool {
    if (std.mem.indexOf(u8, hypothesis.source_rule, needle) != null) return true;
    if (std.mem.indexOf(u8, hypothesis.provenance, needle) != null) return true;
    if (std.mem.indexOf(u8, hypothesis.trace, needle) != null) return true;
    if (std.mem.indexOf(u8, hypothesis.artifact_scope, needle) != null) return true;
    for (hypothesis.source_signals) |signal| {
        if (std.mem.indexOf(u8, signal, needle) != null) return true;
    }
    for (hypothesis.evidence_fragments) |fragment| {
        if (std.mem.indexOf(u8, fragment, needle) != null) return true;
    }
    return false;
}

fn applyDuplicateAndDominance(
    allocator: std.mem.Allocator,
    hypotheses: []const Hypothesis,
    items: []TriageItem,
    result: *TriageResult,
    max_duplicate_groups_traced: usize,
) !void {
    for (hypotheses, 0..) |hypothesis, idx| {
        if (items[idx].triage_status == .blocked) continue;
        var strongest_idx = idx;
        for (hypotheses[0..idx], 0..) |prior, prior_idx| {
            if (!sameDuplicateSurface(hypothesis, prior)) continue;
            if (result.duplicate_groups_traced < max_duplicate_groups_traced) {
                items[idx].duplicate_group_id = try std.fmt.allocPrint(allocator, "hypothesis_duplicate_group:{s}", .{hypotheses[prior_idx].id});
                result.duplicate_groups_traced += 1;
            }
            strongest_idx = strongerHypothesisIndex(hypotheses, items, prior_idx, idx);
            const suppressed_idx = if (strongest_idx == idx) prior_idx else idx;
            if (items[suppressed_idx].triage_status == .duplicate) break;
            items[suppressed_idx].triage_status = .duplicate;
            try setSuppressionReason(allocator, &items[suppressed_idx], if (strongest_idx == idx)
                "duplicate of stronger later hypothesis with higher deterministic score"
            else
                "duplicate of stronger earlier hypothesis with equal target surface");
            result.duplicates += 1;
            break;
        }
    }

    for (hypotheses, 0..) |hypothesis, idx| {
        if (items[idx].triage_status == .blocked or items[idx].triage_status == .duplicate) continue;
        for (hypotheses, 0..) |other, other_idx| {
            if (idx == other_idx) continue;
            if (items[other_idx].triage_status == .blocked) continue;
            if (!sameTargetSurface(hypothesis, other)) continue;
            if (!dominates(hypothesis, items[idx], other, items[other_idx])) continue;
            items[other_idx].triage_status = .suppressed;
            try setSuppressionReason(allocator, &items[other_idx], "dominated by stronger provenance/trust, lower obligation cost, or available verifier hook on same target surface");
            result.suppressed += 1;
        }
    }
}

fn setSuppressionReason(allocator: std.mem.Allocator, item: *TriageItem, reason: []const u8) !void {
    if (item.suppression_reason) |existing| allocator.free(existing);
    item.suppression_reason = try allocator.dupe(u8, reason);
}

fn strongerHypothesisIndex(hypotheses: []const Hypothesis, items: []const TriageItem, lhs_idx: usize, rhs_idx: usize) usize {
    if (items[lhs_idx].score != items[rhs_idx].score) return if (items[lhs_idx].score > items[rhs_idx].score) lhs_idx else rhs_idx;
    return if (std.mem.lessThan(u8, hypotheses[lhs_idx].id, hypotheses[rhs_idx].id)) lhs_idx else rhs_idx;
}

fn sameDuplicateSurface(lhs: Hypothesis, rhs: Hypothesis) bool {
    return lhs.hypothesis_kind == rhs.hypothesis_kind and
        std.mem.eql(u8, lhs.artifact_scope, rhs.artifact_scope) and
        stringSetsEqual(lhs.affected_entities, rhs.affected_entities) and
        stringSetsEqual(lhs.involved_relations, rhs.involved_relations) and
        stringSetsEqual(lhs.verifier_hooks_needed, rhs.verifier_hooks_needed);
}

fn sameTargetSurface(lhs: Hypothesis, rhs: Hypothesis) bool {
    return lhs.hypothesis_kind == rhs.hypothesis_kind and std.mem.eql(u8, lhs.artifact_scope, rhs.artifact_scope);
}

fn dominates(lhs: Hypothesis, lhs_item: TriageItem, rhs: Hypothesis, rhs_item: TriageItem) bool {
    if (lhs_item.score <= rhs_item.score) return false;
    if (lhs.missing_obligations.len > rhs.missing_obligations.len) return false;
    if (lhs.verifier_hooks_needed.len == 0 and rhs.verifier_hooks_needed.len > 0) return false;
    return lhs_item.score >= rhs_item.score + 8;
}

fn stringSetsEqual(lhs: []const []const u8, rhs: []const []const u8) bool {
    if (lhs.len != rhs.len) return false;
    for (lhs) |left| {
        var found = false;
        for (rhs) |right| {
            if (std.mem.eql(u8, left, right)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

fn selectRanked(
    allocator: std.mem.Allocator,
    hypotheses: []const Hypothesis,
    ranked: []const RankedIndex,
    items: []TriageItem,
    result: *TriageResult,
    policy: TriagePolicy,
) !void {
    var artifact_counts = std.ArrayList(SelectionCounter).init(allocator);
    defer artifact_counts.deinit();
    var kind_counts = std.ArrayList(SelectionCounter).init(allocator);
    defer kind_counts.deinit();

    const non_code_candidate = bestNonCodeCandidate(hypotheses, ranked, items);
    for (ranked) |entry| {
        if (result.selected >= policy.max_hypotheses_selected) {
            if (items[entry.index].triage_status == .deferred) {
                try setSuppressionReason(allocator, &items[entry.index], "selection budget exhausted before this hypothesis rank");
                result.budget_hits += 1;
            }
            continue;
        }
        if (items[entry.index].triage_status != .deferred) continue;
        const hypothesis = hypotheses[entry.index];
        if (non_code_candidate) |candidate_idx| {
            if (entry.index != candidate_idx and result.selected + 1 == policy.max_hypotheses_selected and result.selected_non_code_count == 0) {
                items[entry.index].triage_status = .deferred;
                try setSuppressionReason(allocator, &items[entry.index], "deferred to preserve reasonably scored non-code hypothesis diversity");
                result.deferred += 1;
                continue;
            }
        }
        if (countFor(artifact_counts.items, hypothesis.artifact_scope) >= policy.max_hypotheses_per_artifact) {
            items[entry.index].triage_status = .deferred;
            try setSuppressionReason(allocator, &items[entry.index], "per-artifact hypothesis cap reached");
            result.deferred += 1;
            result.per_artifact_caps_hit += 1;
            continue;
        }
        const kind_key = kindName(hypothesis.hypothesis_kind);
        if (countFor(kind_counts.items, kind_key) >= policy.max_hypotheses_per_kind) {
            items[entry.index].triage_status = .deferred;
            try setSuppressionReason(allocator, &items[entry.index], "per-kind hypothesis cap reached");
            result.deferred += 1;
            result.per_kind_caps_hit += 1;
            continue;
        }
        try incrementCounter(allocator, &artifact_counts, hypothesis.artifact_scope);
        try incrementCounter(allocator, &kind_counts, kind_key);
        items[entry.index].triage_status = .selected;
        items[entry.index].selected_for_next_stage = true;
        result.selected += 1;
        result.hypotheses_selected += 1;
        if (isCodeHypothesis(hypothesis)) {
            result.selected_code_count += 1;
        } else {
            result.selected_non_code_count += 1;
        }
    }
}

fn bestNonCodeCandidate(hypotheses: []const Hypothesis, ranked: []const RankedIndex, items: []const TriageItem) ?usize {
    if (ranked.len == 0) return null;
    const top_score = ranked[0].score;
    for (ranked) |entry| {
        if (items[entry.index].triage_status != .deferred) continue;
        if (isCodeHypothesis(hypotheses[entry.index])) continue;
        if (entry.score + 12 >= top_score) return entry.index;
    }
    return null;
}

fn isCodeHypothesis(hypothesis: Hypothesis) bool {
    return std.mem.indexOf(u8, hypothesis.schema_name, "code") != null or
        std.mem.indexOf(u8, hypothesis.artifact_scope, ".zig") != null or
        std.mem.indexOf(u8, hypothesis.artifact_scope, "src/") != null;
}

fn countFor(items: []const SelectionCounter, key: []const u8) usize {
    for (items) |item| {
        if (std.mem.eql(u8, item.key, key)) return item.count;
    }
    return 0;
}

fn incrementCounter(allocator: std.mem.Allocator, items: *std.ArrayList(SelectionCounter), key: []const u8) !void {
    for (items.items) |*item| {
        if (std.mem.eql(u8, item.key, key)) {
            item.count += 1;
            return;
        }
    }
    try items.append(.{ .key = key, .count = 1 });
    _ = allocator;
}

fn selectedKindNames(allocator: std.mem.Allocator, hypotheses: []const Hypothesis, items: []const TriageItem) ![]const []const u8 {
    var out = std.ArrayList([]const u8).init(allocator);
    errdefer {
        for (out.items) |item| allocator.free(item);
        out.deinit();
    }
    for (items, 0..) |item, idx| {
        if (!item.selected_for_next_stage) continue;
        const name = kindName(hypotheses[idx].hypothesis_kind);
        if (containsString(out.items, name)) continue;
        try out.append(try allocator.dupe(u8, name));
        if (out.items.len >= 5) break;
    }
    return out.toOwnedSlice();
}

fn containsString(items: []const []const u8, needle: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

pub fn make(
    allocator: std.mem.Allocator,
    id: []const u8,
    artifact_scope: []const u8,
    schema_name: []const u8,
    hypothesis_kind: HypothesisKind,
    evidence_fragments: []const []const u8,
    missing_obligations: []const []const u8,
    verifier_hooks_needed: []const []const u8,
    suggested_action_surface: []const u8,
    provenance: []const u8,
    trace: []const u8,
) !Hypothesis {
    const source_signals = [_][]const u8{provenance};
    return makeWithSignals(
        allocator,
        id,
        artifact_scope,
        schema_name,
        hypothesis_kind,
        &.{},
        &.{},
        evidence_fragments,
        missing_obligations,
        verifier_hooks_needed,
        suggested_action_surface,
        trace,
        &source_signals,
        provenance,
        trace,
    );
}

pub fn makeWithSignals(
    allocator: std.mem.Allocator,
    id: []const u8,
    artifact_scope: []const u8,
    schema_name: []const u8,
    hypothesis_kind: HypothesisKind,
    affected_entities: []const []const u8,
    involved_relations: []const []const u8,
    evidence_fragments: []const []const u8,
    missing_obligations: []const []const u8,
    verifier_hooks_needed: []const []const u8,
    suggested_action_surface: []const u8,
    source_rule: []const u8,
    source_signals: []const []const u8,
    provenance: []const u8,
    trace: []const u8,
) !Hypothesis {
    return .{
        .id = try allocator.dupe(u8, id),
        .artifact_scope = try allocator.dupe(u8, artifact_scope),
        .schema_name = try allocator.dupe(u8, schema_name),
        .hypothesis_kind = hypothesis_kind,
        .affected_entities = try cloneStringSliceLimited(allocator, affected_entities, affected_entities.len),
        .involved_relations = try cloneStringSliceLimited(allocator, involved_relations, involved_relations.len),
        .evidence_fragments = try cloneStringSliceLimited(allocator, evidence_fragments, evidence_fragments.len),
        .missing_obligations = try cloneStringSliceLimited(allocator, missing_obligations, missing_obligations.len),
        .suggested_action_surface = try allocator.dupe(u8, suggested_action_surface),
        .verifier_hooks_needed = try cloneStringSliceLimited(allocator, verifier_hooks_needed, verifier_hooks_needed.len),
        .source_rule = try allocator.dupe(u8, source_rule),
        .source_signals = try cloneStringSliceLimited(allocator, source_signals, source_signals.len),
        .support_potential = .low,
        .risk_or_value_level = .low,
        .status = .proposed,
        .non_authorizing = true,
        .provenance = try allocator.dupe(u8, provenance),
        .trace = try allocator.dupe(u8, trace),
    };
}

pub fn cloneStringSliceLimited(
    allocator: std.mem.Allocator,
    items: []const []const u8,
    limit: usize,
) ![]const []const u8 {
    const count = @min(items.len, limit);
    if (count == 0) return &.{};
    var out = try allocator.alloc([]const u8, count);
    errdefer {
        for (out[0..count]) |item| allocator.free(item);
        allocator.free(out);
    }
    for (items[0..count], 0..) |item, idx| {
        out[idx] = try allocator.dupe(u8, item);
    }
    return out;
}

pub fn freeStringSlice(allocator: std.mem.Allocator, items: []const []const u8) void {
    for (items) |item| allocator.free(item);
    if (items.len != 0) allocator.free(items);
}

pub fn kindName(kind: HypothesisKind) []const u8 {
    return @tagName(kind);
}

pub fn statusName(status: HypothesisStatus) []const u8 {
    return @tagName(status);
}

pub fn triageStatusName(status: TriageStatus) []const u8 {
    return @tagName(status);
}

pub fn supportPotentialName(value: SupportPotential) []const u8 {
    return @tagName(value);
}

pub fn riskOrValueLevelName(value: RiskOrValueLevel) []const u8 {
    return @tagName(value);
}

test "hypothesis object creation is always non-authorizing" {
    const allocator = std.testing.allocator;
    const evidence = [_][]const u8{"fragment:doc:1"};
    const obligations = [_][]const u8{"validate_consistency"};
    const hooks = [_][]const u8{"consistency_check"};
    var item = try make(
        allocator,
        "hypothesis:doc:1",
        "doc",
        "document_schema",
        .possible_missing_obligation,
        &evidence,
        &obligations,
        &hooks,
        "verify",
        "artifact:doc",
        "unresolved_obligation",
    );
    defer item.deinit(allocator);

    try std.testing.expect(item.non_authorizing);
    try std.testing.expectEqual(HypothesisStatus.proposed, item.status);
    try std.testing.expectEqualStrings("document_schema", item.schema_name);
}

fn testHypothesis(
    allocator: std.mem.Allocator,
    id: []const u8,
    artifact_scope: []const u8,
    schema_name: []const u8,
    kind: HypothesisKind,
    entities: []const []const u8,
    relations: []const []const u8,
    evidence: []const []const u8,
    obligations: []const []const u8,
    hooks: []const []const u8,
    source_rule: []const u8,
    signals: []const []const u8,
    provenance: []const u8,
    trace: []const u8,
) !Hypothesis {
    return makeWithSignals(
        allocator,
        id,
        artifact_scope,
        schema_name,
        kind,
        entities,
        relations,
        evidence,
        obligations,
        hooks,
        "verify",
        source_rule,
        signals,
        provenance,
        trace,
    );
}

fn deinitHypothesisArray(allocator: std.mem.Allocator, items: []Hypothesis) void {
    for (items) |*item| item.deinit(allocator);
}

test "hypothesis triage: exact anchor/entity outranks fallback token hypothesis" {
    const allocator = std.testing.allocator;
    const entities = [_][]const u8{"Worker"};
    const relations = [_][]const u8{"calls"};
    const evidence = [_][]const u8{"fresh high_trust independent anchor evidence"};
    const obligations = [_][]const u8{"verify_anchor"};
    const hooks = [_][]const u8{"consistency_check"};
    const fallback_evidence = [_][]const u8{"fallback token evidence"};
    var hypotheses = [_]Hypothesis{
        try testHypothesis(allocator, "hyp:fallback", "docs/runbook.md", "universal_artifact_schema", .possible_unsupported_claim, &.{}, &.{}, &fallback_evidence, &obligations, &hooks, "fallback_token", &.{"fallback"}, "low_trust", "fallback"),
        try testHypothesis(allocator, "hyp:anchor", "docs/runbook.md", "universal_artifact_schema", .possible_unsupported_claim, &entities, &relations, &evidence, &obligations, &hooks, "exact_anchor_entity", &.{ "anchor", "entity", "relation" }, "fresh high_trust project", "exact anchor"),
    };
    defer deinitHypothesisArray(allocator, &hypotheses);
    var triaged = try triage(allocator, &hypotheses, .{ .max_hypotheses_selected = 1 });
    defer triaged.deinit();
    try std.testing.expectEqualStrings("hyp:anchor", triaged.items[1].hypothesis_id);
    try std.testing.expectEqual(@as(usize, 1), triaged.items[1].rank);
}

test "hypothesis triage: verifier hook outranks missing hook when verification is needed" {
    const allocator = std.testing.allocator;
    const evidence = [_][]const u8{"fresh high_trust anchor evidence"};
    const obligations = [_][]const u8{"verify_runtime"};
    const hooks = [_][]const u8{"runtime_check"};
    var hypotheses = [_]Hypothesis{
        try testHypothesis(allocator, "hyp:no-hook", "src/runtime.zig", "code_artifact_schema", .possible_behavior_mismatch, &.{"Worker"}, &.{"updates"}, &evidence, &obligations, &.{}, "anchor", &.{"anchor"}, "fresh high_trust", "verify required"),
        try testHypothesis(allocator, "hyp:hook", "src/runtime.zig", "code_artifact_schema", .possible_behavior_mismatch, &.{"Worker"}, &.{"updates"}, &evidence, &obligations, &hooks, "anchor", &.{"anchor"}, "fresh high_trust", "verify required"),
    };
    defer deinitHypothesisArray(allocator, &hypotheses);
    var triaged = try triage(allocator, &hypotheses, .{ .max_hypotheses_selected = 1 });
    defer triaged.deinit();
    try std.testing.expect(triaged.items[1].rank < triaged.items[0].rank);
}

test "hypothesis triage: fresh high-trust outranks stale low-trust" {
    const allocator = std.testing.allocator;
    const evidence = [_][]const u8{"anchor evidence"};
    const obligations = [_][]const u8{"verify_contract"};
    const hooks = [_][]const u8{"consistency_check"};
    var hypotheses = [_]Hypothesis{
        try testHypothesis(allocator, "hyp:stale", "docs/contract.md", "universal_artifact_schema", .possible_stale_information, &.{"Contract"}, &.{"mentions"}, &evidence, &obligations, &hooks, "anchor", &.{ "stale", "low_trust" }, "stale low_trust", "stale"),
        try testHypothesis(allocator, "hyp:fresh", "docs/contract.md", "universal_artifact_schema", .possible_stale_information, &.{"Contract"}, &.{"mentions"}, &evidence, &obligations, &hooks, "anchor", &.{ "fresh", "high_trust" }, "fresh high_trust", "fresh"),
    };
    defer deinitHypothesisArray(allocator, &hypotheses);
    var triaged = try triage(allocator, &hypotheses, .{ .max_hypotheses_selected = 1 });
    defer triaged.deinit();
    try std.testing.expect(triaged.items[1].score > triaged.items[0].score);
}

test "hypothesis triage: duplicate hypotheses are suppressed but traceable" {
    const allocator = std.testing.allocator;
    const evidence = [_][]const u8{"fresh high_trust anchor evidence"};
    const obligations = [_][]const u8{"verify_contract"};
    const hooks = [_][]const u8{"consistency_check"};
    var hypotheses = [_]Hypothesis{
        try testHypothesis(allocator, "hyp:dup-a", "docs/contract.md", "universal_artifact_schema", .possible_missing_obligation, &.{"Contract"}, &.{"requires"}, &evidence, &obligations, &hooks, "anchor", &.{ "fresh", "high_trust" }, "fresh high_trust", "first"),
        try testHypothesis(allocator, "hyp:dup-b", "docs/contract.md", "universal_artifact_schema", .possible_missing_obligation, &.{"Contract"}, &.{"requires"}, &evidence, &obligations, &hooks, "anchor", &.{ "fresh", "high_trust" }, "fresh high_trust", "second"),
    };
    defer deinitHypothesisArray(allocator, &hypotheses);
    var triaged = try triage(allocator, &hypotheses, .{ .max_hypotheses_selected = 2 });
    defer triaged.deinit();
    try std.testing.expectEqual(@as(usize, 1), triaged.duplicates);
    try std.testing.expect(triaged.items[1].duplicate_group_id != null);
    try std.testing.expect(triaged.items[1].suppression_reason != null);
}

test "hypothesis triage: dominated hypothesis is suppressed with reason" {
    const allocator = std.testing.allocator;
    const evidence = [_][]const u8{"fresh high_trust independent anchor evidence"};
    const weak_evidence = [_][]const u8{"low_trust evidence"};
    const obligation = [_][]const u8{"verify_contract"};
    const many_obligations = [_][]const u8{ "verify_contract", "collect_source", "disambiguate" };
    const hooks = [_][]const u8{"consistency_check"};
    var hypotheses = [_]Hypothesis{
        try testHypothesis(allocator, "hyp:strong", "docs/contract.md", "universal_artifact_schema", .possible_missing_obligation, &.{"Contract"}, &.{"requires"}, &evidence, &obligation, &hooks, "anchor", &.{ "fresh", "high_trust", "independent" }, "fresh high_trust", "strong"),
        try testHypothesis(allocator, "hyp:weak", "docs/contract.md", "universal_artifact_schema", .possible_missing_obligation, &.{"Contract"}, &.{"mentions"}, &weak_evidence, &many_obligations, &.{}, "anchor", &.{"low_trust"}, "low_trust", "weak"),
    };
    defer deinitHypothesisArray(allocator, &hypotheses);
    var triaged = try triage(allocator, &hypotheses, .{ .max_hypotheses_selected = 2 });
    defer triaged.deinit();
    try std.testing.expectEqual(TriageStatus.suppressed, triaged.items[1].triage_status);
    try std.testing.expect(triaged.items[1].suppression_reason != null);
}

test "negative knowledge triage: accepted failed_hypothesis penalizes matching hypothesis" {
    const allocator = std.testing.allocator;
    const influence = [_]negative_knowledge.AllowedInfluence{.triage_penalty};
    var record = try negative_knowledge.acceptNegativeKnowledgeCandidate(allocator, .{
        .id = "cand:triage:penalty",
        .correction_event_id = "corr:triage",
        .kind = .failed_hypothesis,
        .scope = .artifact,
        .condition = "hyp:penalized",
        .evidence_ref = "evidence:failed",
        .triage_penalty = 20,
    }, .{ .approved_by = "test", .approval_kind = .test_fixture, .reason = "fixture failure", .scope = .artifact, .allowed_influence = &influence });
    defer record.deinit();
    var hypotheses = [_]Hypothesis{
        try testHypothesis(allocator, "hyp:penalized", "src/a.zig", "code_artifact_schema", .possible_behavior_mismatch, &.{"Worker"}, &.{"updates"}, &.{"fresh high_trust anchor evidence"}, &.{"verify"}, &.{"runtime_check"}, "anchor", &.{"anchor"}, "fresh high_trust", "hyp:penalized"),
        try testHypothesis(allocator, "hyp:clean", "src/b.zig", "code_artifact_schema", .possible_behavior_mismatch, &.{"Worker"}, &.{"updates"}, &.{"fresh high_trust anchor evidence"}, &.{"verify"}, &.{"runtime_check"}, "anchor", &.{"anchor"}, "fresh high_trust", "clean"),
    };
    defer deinitHypothesisArray(allocator, &hypotheses);
    var triaged = try triageWithNegativeKnowledge(allocator, &hypotheses, .{ .max_hypotheses_selected = 2 }, &.{record}, compute_budget.resolve(.{ .tier = .medium }));
    defer triaged.deinit();
    try std.testing.expect(triaged.items[0].score < triaged.items[1].score);
    try std.testing.expectEqual(@as(usize, 1), triaged.negative_knowledge_triage_penalty_count);
}

test "negative knowledge triage: rejected and expired records have no effect" {
    const allocator = std.testing.allocator;
    const influence = [_]negative_knowledge.AllowedInfluence{.triage_penalty};
    var record = try negative_knowledge.acceptNegativeKnowledgeCandidate(allocator, .{
        .id = "cand:triage:no-effect",
        .correction_event_id = "corr",
        .kind = .failed_hypothesis,
        .scope = .artifact,
        .condition = "hyp:no-effect",
        .evidence_ref = "evidence",
        .triage_penalty = 20,
    }, .{ .approved_by = "test", .approval_kind = .test_fixture, .reason = "fixture", .scope = .artifact, .allowed_influence = &influence });
    defer record.deinit();
    var hypothesis = [_]Hypothesis{
        try testHypothesis(allocator, "hyp:no-effect", "src/a.zig", "code_artifact_schema", .possible_behavior_mismatch, &.{"Worker"}, &.{}, &.{"fresh high_trust anchor evidence"}, &.{"verify"}, &.{"runtime_check"}, "anchor", &.{"anchor"}, "fresh high_trust", "hyp:no-effect"),
    };
    defer deinitHypothesisArray(allocator, &hypothesis);
    record.status = .rejected;
    var rejected = try triageWithNegativeKnowledge(allocator, &hypothesis, .{ .max_hypotheses_selected = 1 }, &.{record}, compute_budget.resolve(.{ .tier = .medium }));
    defer rejected.deinit();
    try std.testing.expectEqual(@as(usize, 0), rejected.negative_knowledge_influence_match_count);
    record.status = .expired;
    var expired = try triageWithNegativeKnowledge(allocator, &hypothesis, .{ .max_hypotheses_selected = 1 }, &.{record}, compute_budget.resolve(.{ .tier = .medium }));
    defer expired.deinit();
    try std.testing.expectEqual(@as(usize, 0), expired.negative_knowledge_influence_match_count);
}

test "negative knowledge triage: suppression and verifier requirement are explicit and not executed" {
    const allocator = std.testing.allocator;
    const influence = [_]negative_knowledge.AllowedInfluence{ .suppression_rule, .verifier_requirement };
    var record = try negative_knowledge.acceptNegativeKnowledgeCandidate(allocator, .{
        .id = "cand:triage:suppress",
        .correction_event_id = "corr",
        .kind = .failed_patch,
        .scope = .artifact,
        .condition = "hyp:repeat",
        .evidence_ref = "evidence",
        .suppression_rule = "exact_failed_hypothesis",
        .verifier_requirement = "strong_runtime_check",
    }, .{ .approved_by = "test", .approval_kind = .test_fixture, .reason = "fixture", .scope = .artifact, .allowed_influence = &influence });
    defer record.deinit();
    var hypothesis = [_]Hypothesis{
        try testHypothesis(allocator, "hyp:repeat", "src/a.zig", "code_artifact_schema", .possible_behavior_mismatch, &.{"Worker"}, &.{}, &.{"fresh high_trust anchor evidence"}, &.{"verify"}, &.{"runtime_check"}, "anchor", &.{"anchor"}, "fresh high_trust", "hyp:repeat"),
    };
    defer deinitHypothesisArray(allocator, &hypothesis);
    var triaged = try triageWithNegativeKnowledge(allocator, &hypothesis, .{ .max_hypotheses_selected = 1 }, &.{record}, compute_budget.resolve(.{ .tier = .medium }));
    defer triaged.deinit();
    try std.testing.expectEqual(TriageStatus.suppressed, triaged.items[0].triage_status);
    try std.testing.expect(triaged.items[0].suppression_reason != null);
    try std.testing.expectEqual(@as(usize, 1), triaged.items[0].required_verifiers.len);
}

test "hypothesis triage: per-kind cap preserves diversity" {
    const allocator = std.testing.allocator;
    const evidence = [_][]const u8{"fresh high_trust anchor evidence"};
    const obligation = [_][]const u8{"verify_contract"};
    const hooks = [_][]const u8{"consistency_check"};
    var hypotheses = [_]Hypothesis{
        try testHypothesis(allocator, "hyp:missing-a", "docs/a.md", "universal_artifact_schema", .possible_missing_obligation, &.{"A"}, &.{"requires"}, &evidence, &obligation, &hooks, "anchor", &.{ "fresh", "high_trust" }, "fresh high_trust", "a"),
        try testHypothesis(allocator, "hyp:missing-b", "docs/b.md", "universal_artifact_schema", .possible_missing_obligation, &.{"B"}, &.{"requires"}, &evidence, &obligation, &hooks, "anchor", &.{ "fresh", "high_trust" }, "fresh high_trust", "b"),
        try testHypothesis(allocator, "hyp:ambiguity", "docs/c.md", "universal_artifact_schema", .possible_ambiguity, &.{"C"}, &.{"maps"}, &evidence, &obligation, &hooks, "anchor", &.{ "fresh", "high_trust" }, "fresh high_trust", "c"),
    };
    defer deinitHypothesisArray(allocator, &hypotheses);
    var triaged = try triage(allocator, &hypotheses, .{ .max_hypotheses_selected = 2, .max_hypotheses_per_kind = 1, .max_hypotheses_per_artifact = 2 });
    defer triaged.deinit();
    try std.testing.expectEqual(@as(usize, 2), triaged.selected);
    try std.testing.expectEqual(TriageStatus.selected, triaged.items[2].triage_status);
}

test "hypothesis triage: per-artifact cap prevents one artifact from consuming all selections" {
    const allocator = std.testing.allocator;
    const evidence = [_][]const u8{"fresh high_trust anchor evidence"};
    const obligation = [_][]const u8{"verify_contract"};
    const hooks = [_][]const u8{"consistency_check"};
    var hypotheses = [_]Hypothesis{
        try testHypothesis(allocator, "hyp:a1", "docs/a.md", "universal_artifact_schema", .possible_missing_obligation, &.{"A1"}, &.{"requires"}, &evidence, &obligation, &hooks, "anchor", &.{ "fresh", "high_trust" }, "fresh high_trust", "a1"),
        try testHypothesis(allocator, "hyp:a2", "docs/a.md", "universal_artifact_schema", .possible_ambiguity, &.{"A2"}, &.{"maps"}, &evidence, &obligation, &hooks, "anchor", &.{ "fresh", "high_trust" }, "fresh high_trust", "a2"),
        try testHypothesis(allocator, "hyp:b1", "docs/b.md", "universal_artifact_schema", .possible_unsupported_claim, &.{"B1"}, &.{"mentions"}, &evidence, &obligation, &hooks, "anchor", &.{ "fresh", "high_trust" }, "fresh high_trust", "b1"),
    };
    defer deinitHypothesisArray(allocator, &hypotheses);
    var triaged = try triage(allocator, &hypotheses, .{ .max_hypotheses_selected = 2, .max_hypotheses_per_artifact = 1, .max_hypotheses_per_kind = 2 });
    defer triaged.deinit();
    try std.testing.expectEqual(@as(usize, 2), triaged.selected);
    try std.testing.expect(triaged.per_artifact_caps_hit > 0);
    try std.testing.expectEqual(TriageStatus.selected, triaged.items[2].triage_status);
}

test "hypothesis triage: non-code hypothesis is not starved when reasonably scored" {
    const allocator = std.testing.allocator;
    const evidence = [_][]const u8{"fresh high_trust anchor evidence"};
    const obligation = [_][]const u8{"verify_contract"};
    const hooks = [_][]const u8{"consistency_check"};
    var hypotheses = [_]Hypothesis{
        try testHypothesis(allocator, "hyp:code", "src/runtime.zig", "code_artifact_schema", .possible_behavior_mismatch, &.{"Runtime"}, &.{"updates"}, &evidence, &obligation, &hooks, "anchor", &.{ "fresh", "high_trust" }, "fresh high_trust", "code"),
        try testHypothesis(allocator, "hyp:doc", "docs/runbook.md", "document_schema", .possible_missing_obligation, &.{"Runbook"}, &.{"requires"}, &evidence, &obligation, &hooks, "anchor", &.{ "fresh", "high_trust" }, "fresh high_trust", "doc"),
    };
    defer deinitHypothesisArray(allocator, &hypotheses);
    var triaged = try triage(allocator, &hypotheses, .{ .max_hypotheses_selected = 1 });
    defer triaged.deinit();
    try std.testing.expectEqual(@as(usize, 1), triaged.selected_non_code_count);
    try std.testing.expectEqual(TriageStatus.selected, triaged.items[1].triage_status);
}

test "hypothesis triage: same input produces identical ranking order" {
    const allocator = std.testing.allocator;
    const evidence = [_][]const u8{"fresh high_trust anchor evidence"};
    const obligation = [_][]const u8{"verify_contract"};
    const hooks = [_][]const u8{"consistency_check"};
    var hypotheses = [_]Hypothesis{
        try testHypothesis(allocator, "hyp:b", "docs/b.md", "universal_artifact_schema", .possible_missing_obligation, &.{"B"}, &.{"requires"}, &evidence, &obligation, &hooks, "anchor", &.{ "fresh", "high_trust" }, "fresh high_trust", "b"),
        try testHypothesis(allocator, "hyp:a", "docs/a.md", "universal_artifact_schema", .possible_missing_obligation, &.{"A"}, &.{"requires"}, &evidence, &obligation, &hooks, "anchor", &.{ "fresh", "high_trust" }, "fresh high_trust", "a"),
    };
    defer deinitHypothesisArray(allocator, &hypotheses);
    var first = try triage(allocator, &hypotheses, .{ .max_hypotheses_selected = 2 });
    defer first.deinit();
    var second = try triage(allocator, &hypotheses, .{ .max_hypotheses_selected = 2 });
    defer second.deinit();
    try std.testing.expectEqual(first.items[0].rank, second.items[0].rank);
    try std.testing.expectEqual(first.items[1].rank, second.items[1].rank);
    try std.testing.expect(first.items[1].rank < first.items[0].rank);
}

test "hypothesis triage: selected hypothesis remains non-authorizing" {
    const allocator = std.testing.allocator;
    const evidence = [_][]const u8{"fresh high_trust anchor evidence"};
    const obligation = [_][]const u8{"verify_contract"};
    const hooks = [_][]const u8{"consistency_check"};
    var hypothesis = try testHypothesis(allocator, "hyp:selected", "docs/runbook.md", "document_schema", .possible_missing_obligation, &.{"Runbook"}, &.{"requires"}, &evidence, &obligation, &hooks, "anchor", &.{ "fresh", "high_trust" }, "fresh high_trust", "selected");
    defer hypothesis.deinit(allocator);
    var triaged = try triage(allocator, @as([]const Hypothesis, &.{hypothesis}), .{ .max_hypotheses_selected = 1 });
    defer triaged.deinit();
    try std.testing.expectEqual(TriageStatus.selected, triaged.items[0].triage_status);
    try std.testing.expect(hypothesis.non_authorizing);
    try std.testing.expectEqual(HypothesisStatus.proposed, hypothesis.status);
}
