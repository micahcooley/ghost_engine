const std = @import("std");
const compute_budget = @import("compute_budget.zig");
const hypothesis_core = @import("hypothesis_core.zig");
const support_routing = @import("support_routing.zig");

pub const Kind = enum {
    failed_hypothesis,
    failed_patch,
    failed_repair_strategy,
    misleading_pack_signal,
    insufficient_test,
    unsafe_verifier_candidate,
    overbroad_rule,
    stale_source_claim,
    forbidden_project_pattern,
};

pub const Status = enum {
    proposed,
    accepted,
    rejected,
    expired,
    superseded,
};

pub const Scope = enum {
    artifact,
    entity,
    relation,
    project,
    pack,
    domain,
    global_candidate,
};

pub const Permanence = enum {
    temporary,
    project_local,
    pack_local,
    global_candidate,
};

pub const ReviewDecisionKind = enum {
    accept,
    reject,
    deferred,
};

pub const ApprovalKind = enum {
    user,
    test_fixture,
    policy,
};

pub const AllowedInfluence = enum {
    triage_penalty,
    routing_warning,
    verifier_requirement,
    pack_trust_decay_candidate,
    suppression_rule,
};

pub const ReviewDecision = struct {
    decision: ReviewDecisionKind,
    reason: []const u8,
    approval_context: ?ApprovalContext = null,
};

pub const ApprovalContext = struct {
    approved_by: []const u8,
    approval_kind: ApprovalKind,
    reason: []const u8,
    scope: Scope,
    allowed_influence: []const AllowedInfluence,
};

pub const Candidate = struct {
    id: []const u8,
    correction_event_id: []const u8,
    kind: Kind,
    scope: Scope,
    permanence: Permanence = .temporary,
    condition: []const u8,
    evidence_ref: []const u8,
    affected_artifacts: []const []const u8 = &.{},
    affected_entities: []const []const u8 = &.{},
    affected_relations: []const []const u8 = &.{},
    affected_pack_refs: []const []const u8 = &.{},
    suppression_rule: ?[]const u8 = null,
    triage_penalty: ?i32 = null,
    verifier_requirement: ?[]const u8 = null,
    trust_decay_suggestion: ?[]const u8 = null,
    freshness: u64 = 0,
    expires_at_or_condition: ?[]const u8 = null,
    resurrection_condition: ?[]const u8 = null,
    trace: []const u8 = "negative knowledge candidate is proposed only",
    non_authorizing: bool = true,
};

pub const Record = struct {
    allocator: std.mem.Allocator,
    id: []u8,
    source_candidate_id: []u8,
    correction_event_id: []u8,
    kind: Kind,
    status: Status,
    scope: Scope,
    permanence: Permanence,
    condition: []u8,
    evidence_ref: []u8,
    affected_artifacts: [][]u8 = &.{},
    affected_entities: [][]u8 = &.{},
    affected_relations: [][]u8 = &.{},
    affected_pack_refs: [][]u8 = &.{},
    suppression_rule: ?[]u8 = null,
    triage_penalty: ?i32 = null,
    verifier_requirement: ?[]u8 = null,
    trust_decay_suggestion: ?[]u8 = null,
    freshness: u64 = 0,
    expires_at_or_condition: ?[]u8 = null,
    resurrection_condition: ?[]u8 = null,
    reviewed_by: ?[]u8 = null,
    review_reason: ?[]u8 = null,
    non_authorizing: bool = true,
    trace: []u8,

    pub fn deinit(self: *Record) void {
        self.allocator.free(self.id);
        self.allocator.free(self.source_candidate_id);
        self.allocator.free(self.correction_event_id);
        self.allocator.free(self.condition);
        self.allocator.free(self.evidence_ref);
        freeStringList(self.allocator, self.affected_artifacts);
        freeStringList(self.allocator, self.affected_entities);
        freeStringList(self.allocator, self.affected_relations);
        freeStringList(self.allocator, self.affected_pack_refs);
        if (self.suppression_rule) |value| self.allocator.free(value);
        if (self.verifier_requirement) |value| self.allocator.free(value);
        if (self.trust_decay_suggestion) |value| self.allocator.free(value);
        if (self.expires_at_or_condition) |value| self.allocator.free(value);
        if (self.resurrection_condition) |value| self.allocator.free(value);
        if (self.reviewed_by) |value| self.allocator.free(value);
        if (self.review_reason) |value| self.allocator.free(value);
        self.allocator.free(self.trace);
        self.* = undefined;
    }
};

pub const ReviewEvent = struct {
    allocator: std.mem.Allocator,
    id: []u8,
    candidate_id: []u8,
    record_id: ?[]u8 = null,
    decision: ReviewDecisionKind,
    reviewed_by: ?[]u8 = null,
    reason: []u8,
    non_authorizing: bool = true,
    trace: []u8,

    pub fn deinit(self: *ReviewEvent) void {
        self.allocator.free(self.id);
        self.allocator.free(self.candidate_id);
        if (self.record_id) |value| self.allocator.free(value);
        if (self.reviewed_by) |value| self.allocator.free(value);
        self.allocator.free(self.reason);
        self.allocator.free(self.trace);
        self.* = undefined;
    }
};

pub const InfluenceResult = struct {
    allocator: std.mem.Allocator,
    matched_record_ids: [][]u8 = &.{},
    warnings: [][]u8 = &.{},
    triage_delta: i32 = 0,
    required_verifiers: [][]u8 = &.{},
    suppression_reason: ?[]u8 = null,
    trust_decay_candidates: [][]u8 = &.{},
    budget_exhausted: ?compute_budget.Exhaustion = null,
    non_authorizing: bool = true,

    pub fn deinit(self: *InfluenceResult) void {
        freeStringList(self.allocator, self.matched_record_ids);
        freeStringList(self.allocator, self.warnings);
        freeStringList(self.allocator, self.required_verifiers);
        if (self.suppression_reason) |value| self.allocator.free(value);
        freeStringList(self.allocator, self.trust_decay_candidates);
        if (self.budget_exhausted) |*value| value.deinit();
        self.* = undefined;
    }
};

pub const Summary = struct {
    candidate_count: usize = 0,
    accepted_count: usize = 0,
    rejected_count: usize = 0,
    expired_count: usize = 0,
    influence_match_count: usize = 0,
    triage_penalty_count: usize = 0,
    verifier_requirement_count: usize = 0,
    suppression_count: usize = 0,
    trust_decay_candidate_count: usize = 0,
};

pub fn reviewNegativeKnowledgeCandidate(
    allocator: std.mem.Allocator,
    candidate: Candidate,
    review_decision: ReviewDecision,
) !struct { event: ReviewEvent, record: ?Record } {
    return switch (review_decision.decision) {
        .accept => blk: {
            const ctx = review_decision.approval_context orelse return error.ApprovalContextRequired;
            var record = try acceptNegativeKnowledgeCandidate(allocator, candidate, ctx);
            errdefer record.deinit();
            var event = try reviewEvent(allocator, candidate.id, record.id, .accept, ctx.approved_by, ctx.reason, "negative knowledge accepted for scoped influence");
            errdefer event.deinit();
            break :blk .{ .event = event, .record = record };
        },
        .reject => blk: {
            var event = try rejectNegativeKnowledgeCandidate(allocator, candidate.id, review_decision.reason);
            errdefer event.deinit();
            break :blk .{ .event = event, .record = null };
        },
        .deferred => blk: {
            var event = try reviewEvent(allocator, candidate.id, null, .deferred, null, review_decision.reason, "negative knowledge review deferred; no influence allowed");
            errdefer event.deinit();
            break :blk .{ .event = event, .record = null };
        },
    };
}

pub fn acceptNegativeKnowledgeCandidate(allocator: std.mem.Allocator, candidate: Candidate, approval_context: ApprovalContext) !Record {
    if (approval_context.allowed_influence.len == 0) return error.AllowedInfluenceRequired;
    return .{
        .allocator = allocator,
        .id = try std.fmt.allocPrint(allocator, "nkr:{s}", .{candidate.id}),
        .source_candidate_id = try allocator.dupe(u8, candidate.id),
        .correction_event_id = try allocator.dupe(u8, candidate.correction_event_id),
        .kind = candidate.kind,
        .status = .accepted,
        .scope = approval_context.scope,
        .permanence = candidate.permanence,
        .condition = try allocator.dupe(u8, candidate.condition),
        .evidence_ref = try allocator.dupe(u8, candidate.evidence_ref),
        .affected_artifacts = try cloneStringList(allocator, candidate.affected_artifacts),
        .affected_entities = try cloneStringList(allocator, candidate.affected_entities),
        .affected_relations = try cloneStringList(allocator, candidate.affected_relations),
        .affected_pack_refs = try cloneStringList(allocator, candidate.affected_pack_refs),
        .suppression_rule = try cloneOptional(allocator, candidate.suppression_rule),
        .triage_penalty = candidate.triage_penalty orelse if (hasInfluence(approval_context.allowed_influence, .triage_penalty)) 12 else null,
        .verifier_requirement = try cloneOptional(allocator, candidate.verifier_requirement),
        .trust_decay_suggestion = try cloneOptional(allocator, candidate.trust_decay_suggestion),
        .freshness = candidate.freshness,
        .expires_at_or_condition = try cloneOptional(allocator, candidate.expires_at_or_condition),
        .resurrection_condition = try cloneOptional(allocator, candidate.resurrection_condition),
        .reviewed_by = try allocator.dupe(u8, approval_context.approved_by),
        .review_reason = try allocator.dupe(u8, approval_context.reason),
        .non_authorizing = true,
        .trace = try std.fmt.allocPrint(allocator, "accepted by {s} approval_kind={s}; scoped influence only; cannot prove claims true", .{ approval_context.approved_by, @tagName(approval_context.approval_kind) }),
    };
}

pub fn rejectNegativeKnowledgeCandidate(allocator: std.mem.Allocator, candidate_id: []const u8, reason: []const u8) !ReviewEvent {
    return reviewEvent(allocator, candidate_id, null, .reject, null, reason, "negative knowledge rejected; no future influence allowed");
}

pub fn expireNegativeKnowledgeRecord(allocator: std.mem.Allocator, record: *Record, reason: []const u8) !ReviewEvent {
    record.status = .expired;
    if (record.review_reason) |value| record.allocator.free(value);
    record.review_reason = try record.allocator.dupe(u8, reason);
    return reviewEvent(allocator, record.source_candidate_id, record.id, .deferred, record.reviewed_by, reason, "negative knowledge expired; no future influence allowed");
}

pub fn supersedeNegativeKnowledgeRecord(allocator: std.mem.Allocator, old_record: *Record, new_record: *const Record, reason: []const u8) !ReviewEvent {
    old_record.status = .superseded;
    if (old_record.review_reason) |value| old_record.allocator.free(value);
    old_record.review_reason = try old_record.allocator.dupe(u8, reason);
    return reviewEvent(allocator, old_record.source_candidate_id, new_record.id, .accept, old_record.reviewed_by, reason, "negative knowledge superseded by newer scoped record");
}

pub fn influenceHypothesis(
    allocator: std.mem.Allocator,
    records: []const Record,
    hypothesis: hypothesis_core.Hypothesis,
    budget: compute_budget.Effective,
) !InfluenceResult {
    var result = InfluenceResult{ .allocator = allocator };
    errdefer result.deinit();
    var matched = std.ArrayList([]u8).init(allocator);
    errdefer freeStringList(allocator, matched.items);
    var warnings = std.ArrayList([]u8).init(allocator);
    errdefer freeStringList(allocator, warnings.items);
    var verifiers = std.ArrayList([]u8).init(allocator);
    errdefer freeStringList(allocator, verifiers.items);
    var matches: usize = 0;

    for (records) |record| {
        if (record.status != .accepted) continue;
        if (!recordMatchesHypothesis(record, hypothesis)) continue;
        if (matches >= budget.max_negative_knowledge_influence_matches) {
            result.budget_exhausted = try compute_budget.Exhaustion.init(allocator, .max_negative_knowledge_influence_matches, .negative_knowledge, matches + 1, budget.max_negative_knowledge_influence_matches, "negative knowledge influence match cap hit", "remaining accepted records skipped");
            break;
        }
        matches += 1;
        try matched.append(try allocator.dupe(u8, record.id));
        if (record.triage_penalty) |penalty| {
            result.triage_delta -= @max(0, penalty);
        }
        if (record.verifier_requirement) |req| {
            if (!containsString(verifiers.items, req)) try verifiers.append(try allocator.dupe(u8, req));
        }
        if (record.suppression_rule) |rule| {
            if (suppressionMatches(record, hypothesis, rule) and result.suppression_reason == null) {
                result.suppression_reason = try std.fmt.allocPrint(allocator, "suppressed by accepted negative knowledge {s}: {s}", .{ record.id, rule });
            }
        }
        try warnings.append(try std.fmt.allocPrint(allocator, "negative knowledge accepted for scoped influence: {s}", .{record.id}));
    }

    result.matched_record_ids = try matched.toOwnedSlice();
    result.warnings = try warnings.toOwnedSlice();
    result.required_verifiers = try verifiers.toOwnedSlice();
    return result;
}

pub fn influenceRoutingEntry(
    allocator: std.mem.Allocator,
    records: []const Record,
    entry: support_routing.Entry,
    budget: compute_budget.Effective,
) !InfluenceResult {
    var result = InfluenceResult{ .allocator = allocator };
    errdefer result.deinit();
    var matched = std.ArrayList([]u8).init(allocator);
    errdefer freeStringList(allocator, matched.items);
    var warnings = std.ArrayList([]u8).init(allocator);
    errdefer freeStringList(allocator, warnings.items);
    var trust = std.ArrayList([]u8).init(allocator);
    errdefer freeStringList(allocator, trust.items);

    var matches: usize = 0;
    for (records) |record| {
        if (record.status != .accepted) continue;
        if (!recordMatchesText(record, entry.id) and !recordMatchesText(record, entry.provenance)) continue;
        if (matches >= budget.max_negative_knowledge_influence_matches) {
            result.budget_exhausted = try compute_budget.Exhaustion.init(allocator, .max_negative_knowledge_influence_matches, .negative_knowledge, matches + 1, budget.max_negative_knowledge_influence_matches, "negative knowledge routing influence cap hit", "remaining accepted records skipped");
            break;
        }
        matches += 1;
        try matched.append(try allocator.dupe(u8, record.id));
        try warnings.append(try std.fmt.allocPrint(allocator, "routing warning from accepted negative knowledge {s}", .{record.id}));
        result.triage_delta -= @max(0, record.triage_penalty orelse 8);
        if (record.trust_decay_suggestion) |suggestion| {
            if (trust.items.len < budget.max_trust_decay_candidates) {
                try trust.append(try std.fmt.allocPrint(allocator, "trust decay candidate proposed: {s}", .{suggestion}));
            }
        }
    }

    result.matched_record_ids = try matched.toOwnedSlice();
    result.warnings = try warnings.toOwnedSlice();
    result.trust_decay_candidates = try trust.toOwnedSlice();
    return result;
}

pub fn summarize(records: []const Record, influence: ?InfluenceResult) Summary {
    var out = Summary{};
    out.candidate_count = records.len;
    for (records) |record| {
        switch (record.status) {
            .accepted => out.accepted_count += 1,
            .rejected => out.rejected_count += 1,
            .expired => out.expired_count += 1,
            else => {},
        }
    }
    if (influence) |value| {
        out.influence_match_count = value.matched_record_ids.len;
        if (value.triage_delta != 0) out.triage_penalty_count = 1;
        out.verifier_requirement_count = value.required_verifiers.len;
        out.suppression_count = if (value.suppression_reason != null) 1 else 0;
        out.trust_decay_candidate_count = value.trust_decay_candidates.len;
    }
    return out;
}

fn reviewEvent(allocator: std.mem.Allocator, candidate_id: []const u8, record_id: ?[]const u8, decision: ReviewDecisionKind, reviewed_by: ?[]const u8, reason: []const u8, trace: []const u8) !ReviewEvent {
    return .{
        .allocator = allocator,
        .id = try std.fmt.allocPrint(allocator, "nkrv:{s}:{s}", .{ @tagName(decision), candidate_id }),
        .candidate_id = try allocator.dupe(u8, candidate_id),
        .record_id = if (record_id) |value| try allocator.dupe(u8, value) else null,
        .decision = decision,
        .reviewed_by = if (reviewed_by) |value| try allocator.dupe(u8, value) else null,
        .reason = try allocator.dupe(u8, reason),
        .non_authorizing = true,
        .trace = try allocator.dupe(u8, trace),
    };
}

fn recordMatchesHypothesis(record: Record, hypothesis: hypothesis_core.Hypothesis) bool {
    if (record.resurrection_condition) |condition| {
        if (std.mem.indexOf(u8, hypothesis.trace, condition) != null) return false;
    }
    if (recordMatchesText(record, hypothesis.id) or
        recordMatchesText(record, hypothesis.artifact_scope) or
        recordMatchesText(record, hypothesis.source_rule) or
        recordMatchesText(record, hypothesis.provenance) or
        recordMatchesText(record, hypothesis.trace)) return true;
    for (hypothesis.affected_entities) |entity| if (recordMatchesText(record, entity)) return true;
    for (hypothesis.involved_relations) |relation| if (recordMatchesText(record, relation)) return true;
    for (hypothesis.source_signals) |signal| if (recordMatchesText(record, signal)) return true;
    return false;
}

fn recordMatchesText(record: Record, text: []const u8) bool {
    if (record.condition.len != 0 and std.mem.indexOf(u8, text, record.condition) != null) return true;
    for (record.affected_artifacts) |value| if (std.mem.eql(u8, value, text) or std.mem.indexOf(u8, text, value) != null) return true;
    for (record.affected_entities) |value| if (std.mem.eql(u8, value, text) or std.mem.indexOf(u8, text, value) != null) return true;
    for (record.affected_relations) |value| if (std.mem.eql(u8, value, text) or std.mem.indexOf(u8, text, value) != null) return true;
    for (record.affected_pack_refs) |value| if (std.mem.eql(u8, value, text) or std.mem.indexOf(u8, text, value) != null) return true;
    return false;
}

fn suppressionMatches(record: Record, hypothesis: hypothesis_core.Hypothesis, rule: []const u8) bool {
    if (std.mem.eql(u8, rule, "exact_failed_hypothesis")) return recordMatchesText(record, hypothesis.id) or std.mem.eql(u8, record.condition, hypothesis.id);
    return std.mem.indexOf(u8, hypothesis.trace, rule) != null or std.mem.indexOf(u8, hypothesis.source_rule, rule) != null;
}

fn hasInfluence(items: []const AllowedInfluence, needle: AllowedInfluence) bool {
    for (items) |item| if (item == needle) return true;
    return false;
}

fn containsString(items: []const []const u8, needle: []const u8) bool {
    for (items) |item| if (std.mem.eql(u8, item, needle)) return true;
    return false;
}

fn cloneOptional(allocator: std.mem.Allocator, value: ?[]const u8) !?[]u8 {
    return if (value) |v| try allocator.dupe(u8, v) else null;
}

fn cloneStringList(allocator: std.mem.Allocator, items: []const []const u8) ![][]u8 {
    if (items.len == 0) return &.{};
    var out = try allocator.alloc([]u8, items.len);
    errdefer {
        for (out) |item| allocator.free(item);
        allocator.free(out);
    }
    for (items, 0..) |item, idx| out[idx] = try allocator.dupe(u8, item);
    return out;
}

fn freeStringList(allocator: std.mem.Allocator, items: [][]u8) void {
    for (items) |item| allocator.free(item);
    if (items.len != 0) allocator.free(items);
}

pub fn kindName(kind: Kind) []const u8 {
    return @tagName(kind);
}

pub fn statusName(status: Status) []const u8 {
    return @tagName(status);
}

pub fn scopeName(scope: Scope) []const u8 {
    return @tagName(scope);
}

test "candidate can be accepted only with explicit approval context" {
    const allocator = std.testing.allocator;
    const candidate = Candidate{ .id = "cand:1", .correction_event_id = "corr:1", .kind = .failed_hypothesis, .scope = .artifact, .condition = "hyp:bad", .evidence_ref = "evidence:1" };
    try std.testing.expectError(error.ApprovalContextRequired, reviewNegativeKnowledgeCandidate(allocator, candidate, .{ .decision = .accept, .reason = "missing" }));
    const influences = [_]AllowedInfluence{.triage_penalty};
    var reviewed = try reviewNegativeKnowledgeCandidate(allocator, candidate, .{ .decision = .accept, .reason = "fixture", .approval_context = .{ .approved_by = "test", .approval_kind = .test_fixture, .reason = "verified failure", .scope = .artifact, .allowed_influence = &influences } });
    defer reviewed.event.deinit();
    defer reviewed.record.?.deinit();
    try std.testing.expect(reviewed.record.?.non_authorizing);
    try std.testing.expectEqual(Status.accepted, reviewed.record.?.status);
}

test "candidate can be rejected with reason and creates no record" {
    const allocator = std.testing.allocator;
    const candidate = Candidate{ .id = "cand:2", .correction_event_id = "corr:2", .kind = .failed_patch, .scope = .artifact, .condition = "patch", .evidence_ref = "evidence:2" };
    var reviewed = try reviewNegativeKnowledgeCandidate(allocator, candidate, .{ .decision = .reject, .reason = "overfit" });
    defer reviewed.event.deinit();
    try std.testing.expect(reviewed.record == null);
    try std.testing.expect(std.mem.indexOf(u8, reviewed.event.trace, "no future influence") != null);
}

test "rejected and expired records produce no influence" {
    const allocator = std.testing.allocator;
    var hyp = try hypothesis_core.make(allocator, "hyp:bad", "src/a.zig", "code_artifact_schema", .possible_behavior_mismatch, &.{"hyp:bad"}, &.{}, &.{}, "verify", "hyp:bad", "hyp:bad");
    defer hyp.deinit(allocator);
    const influences = [_]AllowedInfluence{.triage_penalty};
    var record = try acceptNegativeKnowledgeCandidate(allocator, .{ .id = "cand:3", .correction_event_id = "corr:3", .kind = .failed_hypothesis, .scope = .artifact, .condition = "hyp:bad", .evidence_ref = "ev" }, .{ .approved_by = "test", .approval_kind = .test_fixture, .reason = "fixture", .scope = .artifact, .allowed_influence = &influences });
    defer record.deinit();
    record.status = .rejected;
    var influence = try influenceHypothesis(allocator, &.{record}, hyp, compute_budget.resolve(.{ .tier = .medium }));
    defer influence.deinit();
    try std.testing.expectEqual(@as(usize, 0), influence.matched_record_ids.len);
    record.status = .expired;
    var expired = try influenceHypothesis(allocator, &.{record}, hyp, compute_budget.resolve(.{ .tier = .medium }));
    defer expired.deinit();
    try std.testing.expectEqual(@as(usize, 0), expired.matched_record_ids.len);
}

test "matching failed patch requires stronger verifier and non-code works through same model" {
    const allocator = std.testing.allocator;
    const influences = [_]AllowedInfluence{ .verifier_requirement, .triage_penalty };
    var record = try acceptNegativeKnowledgeCandidate(allocator, .{ .id = "cand:4", .correction_event_id = "corr:4", .kind = .failed_patch, .scope = .artifact, .condition = "docs/contract.md", .evidence_ref = "ev", .verifier_requirement = "strong_consistency_check" }, .{ .approved_by = "test", .approval_kind = .test_fixture, .reason = "fixture", .scope = .artifact, .allowed_influence = &influences });
    defer record.deinit();
    var hyp = try hypothesis_core.make(allocator, "hyp:doc", "docs/contract.md", "document_schema", .possible_unsupported_claim, &.{"doc evidence"}, &.{}, &.{}, "verify", "doc", "doc");
    defer hyp.deinit(allocator);
    var influence = try influenceHypothesis(allocator, &.{record}, hyp, compute_budget.resolve(.{ .tier = .medium }));
    defer influence.deinit();
    try std.testing.expectEqual(@as(usize, 1), influence.required_verifiers.len);
    try std.testing.expect(influence.triage_delta < 0);
}

test "routing warning and trust decay candidate do not mutate packs" {
    const allocator = std.testing.allocator;
    const influences = [_]AllowedInfluence{ .routing_warning, .pack_trust_decay_candidate };
    var record = try acceptNegativeKnowledgeCandidate(allocator, .{ .id = "cand:5", .correction_event_id = "corr:5", .kind = .misleading_pack_signal, .scope = .pack, .condition = "pack:runtime", .evidence_ref = "ev", .trust_decay_suggestion = "pack:runtime stale signal" }, .{ .approved_by = "test", .approval_kind = .test_fixture, .reason = "fixture", .scope = .pack, .allowed_influence = &influences });
    defer record.deinit();
    var influence = try influenceRoutingEntry(allocator, &.{record}, .{ .id = "pack:runtime", .source_kind = .knowledge_pack_preview, .provenance = "pack:runtime", .source_family = .pack }, compute_budget.resolve(.{ .tier = .medium }));
    defer influence.deinit();
    try std.testing.expectEqual(@as(usize, 1), influence.warnings.len);
    try std.testing.expectEqual(@as(usize, 1), influence.trust_decay_candidates.len);
}

test "overbroad rule creates routing warning without removing candidates" {
    const allocator = std.testing.allocator;
    const influences = [_]AllowedInfluence{.routing_warning};
    var record = try acceptNegativeKnowledgeCandidate(allocator, .{ .id = "cand:overbroad", .correction_event_id = "corr:overbroad", .kind = .overbroad_rule, .scope = .project, .condition = "runtime", .evidence_ref = "ev", .triage_penalty = 6 }, .{ .approved_by = "test", .approval_kind = .test_fixture, .reason = "fixture", .scope = .project, .allowed_influence = &influences });
    defer record.deinit();
    var influence = try influenceRoutingEntry(allocator, &.{record}, .{ .id = "runtime-candidate", .source_kind = .artifact, .provenance = "runtime candidate", .source_family = .code }, compute_budget.resolve(.{ .tier = .medium }));
    defer influence.deinit();
    try std.testing.expectEqual(@as(usize, 1), influence.warnings.len);
    try std.testing.expect(influence.suppression_reason == null);
}

test "resurrection condition prevents stale suppression when condition no longer matches" {
    const allocator = std.testing.allocator;
    const influences = [_]AllowedInfluence{.suppression_rule};
    var record = try acceptNegativeKnowledgeCandidate(allocator, .{
        .id = "cand:resurrect",
        .correction_event_id = "corr:resurrect",
        .kind = .failed_hypothesis,
        .scope = .artifact,
        .condition = "hyp:resurrect",
        .evidence_ref = "ev",
        .suppression_rule = "exact_failed_hypothesis",
        .resurrection_condition = "fixed_by_new_evidence",
    }, .{ .approved_by = "test", .approval_kind = .test_fixture, .reason = "fixture", .scope = .artifact, .allowed_influence = &influences });
    defer record.deinit();
    var hyp = try hypothesis_core.make(allocator, "hyp:resurrect", "src/a.zig", "code_artifact_schema", .possible_behavior_mismatch, &.{"new evidence"}, &.{}, &.{}, "verify", "hyp:resurrect", "fixed_by_new_evidence");
    defer hyp.deinit(allocator);
    var influence = try influenceHypothesis(allocator, &.{record}, hyp, compute_budget.resolve(.{ .tier = .medium }));
    defer influence.deinit();
    try std.testing.expectEqual(@as(usize, 0), influence.matched_record_ids.len);
    try std.testing.expect(influence.suppression_reason == null);
}

test "unknown evidence is distinct from negative evidence and influence is deterministic" {
    const allocator = std.testing.allocator;
    var hyp = try hypothesis_core.make(allocator, "hyp:unknown", "src/unknown.zig", "code_artifact_schema", .possible_behavior_mismatch, &.{}, &.{}, &.{}, "verify", "unknown", "unknown");
    defer hyp.deinit(allocator);
    var first = try influenceHypothesis(allocator, &.{}, hyp, compute_budget.resolve(.{ .tier = .medium }));
    defer first.deinit();
    var second = try influenceHypothesis(allocator, &.{}, hyp, compute_budget.resolve(.{ .tier = .medium }));
    defer second.deinit();
    try std.testing.expectEqual(@as(usize, 0), first.matched_record_ids.len);
    try std.testing.expectEqual(first.triage_delta, second.triage_delta);
}

test "influence respects max budget caps" {
    const allocator = std.testing.allocator;
    const influences = [_]AllowedInfluence{.triage_penalty};
    var a = try acceptNegativeKnowledgeCandidate(allocator, .{ .id = "cand:cap:a", .correction_event_id = "corr", .kind = .failed_hypothesis, .scope = .artifact, .condition = "src/a.zig", .evidence_ref = "ev" }, .{ .approved_by = "test", .approval_kind = .test_fixture, .reason = "fixture", .scope = .artifact, .allowed_influence = &influences });
    defer a.deinit();
    var b = try acceptNegativeKnowledgeCandidate(allocator, .{ .id = "cand:cap:b", .correction_event_id = "corr", .kind = .failed_hypothesis, .scope = .artifact, .condition = "src/a.zig", .evidence_ref = "ev" }, .{ .approved_by = "test", .approval_kind = .test_fixture, .reason = "fixture", .scope = .artifact, .allowed_influence = &influences });
    defer b.deinit();
    var hyp = try hypothesis_core.make(allocator, "hyp:cap", "src/a.zig", "code_artifact_schema", .possible_behavior_mismatch, &.{}, &.{}, &.{}, "verify", "cap", "cap");
    defer hyp.deinit(allocator);
    var influence = try influenceHypothesis(allocator, &.{ a, b }, hyp, compute_budget.resolve(.{ .tier = .medium, .overrides = .{ .max_negative_knowledge_influence_matches = 1 } }));
    defer influence.deinit();
    try std.testing.expectEqual(@as(usize, 1), influence.matched_record_ids.len);
    try std.testing.expect(influence.budget_exhausted != null);
}
