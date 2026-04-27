const std = @import("std");
const code_intel = @import("code_intel.zig");
const compute_budget = @import("compute_budget.zig");
const verifier_execution = @import("verifier_execution.zig");

pub const CorrectionKind = enum {
    hypothesis_contradicted,
    verifier_candidate_failed,
    patch_candidate_invalidated,
    pack_signal_contradicted,
    assumption_invalidated,
    insufficient_test_detected,
};

pub const NegativeKnowledgeKind = enum {
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

pub const Permanence = enum {
    temporary,
    project_local,
    pack_local,
    global_candidate,
};

pub const CorrectionEvent = struct {
    allocator: std.mem.Allocator,
    id: []u8,
    correction_kind: CorrectionKind,
    source_ref: []u8,
    contradicted_ref: []u8,
    contradicting_evidence_ref: []u8,
    previous_state: []u8,
    updated_state: []u8,
    affected_artifacts: [][]u8 = &.{},
    affected_entities: [][]u8 = &.{},
    affected_relations: [][]u8 = &.{},
    failure_cause: ?[]u8 = null,
    negative_knowledge_candidate_ref: ?[]u8 = null,
    trust_update_candidate_ref: ?[]u8 = null,
    user_visible_summary: []u8,
    non_authorizing: bool = true,
    trace: []u8,

    pub fn deinit(self: *CorrectionEvent) void {
        self.allocator.free(self.id);
        self.allocator.free(self.source_ref);
        self.allocator.free(self.contradicted_ref);
        self.allocator.free(self.contradicting_evidence_ref);
        self.allocator.free(self.previous_state);
        self.allocator.free(self.updated_state);
        freeStringList(self.allocator, self.affected_artifacts);
        freeStringList(self.allocator, self.affected_entities);
        freeStringList(self.allocator, self.affected_relations);
        if (self.failure_cause) |v| self.allocator.free(v);
        if (self.negative_knowledge_candidate_ref) |v| self.allocator.free(v);
        if (self.trust_update_candidate_ref) |v| self.allocator.free(v);
        self.allocator.free(self.user_visible_summary);
        self.allocator.free(self.trace);
        self.* = undefined;
    }
};

pub const NegativeKnowledgeCandidate = struct {
    allocator: std.mem.Allocator,
    id: []u8,
    correction_event_id: []u8,
    candidate_kind: NegativeKnowledgeKind,
    scope: []u8,
    condition: []u8,
    evidence_ref: []u8,
    suggested_suppression_rule: ?[]u8 = null,
    freshness: u64 = 0,
    permanence: Permanence = .temporary,
    status: enum { proposed } = .proposed,
    non_authorizing: bool = true,

    pub fn deinit(self: *NegativeKnowledgeCandidate) void {
        self.allocator.free(self.id);
        self.allocator.free(self.correction_event_id);
        self.allocator.free(self.scope);
        self.allocator.free(self.condition);
        self.allocator.free(self.evidence_ref);
        if (self.suggested_suppression_rule) |v| self.allocator.free(v);
        self.* = undefined;
    }
};

pub const CorrectionSummary = struct {
    allocator: std.mem.Allocator,
    correction_count: usize = 0,
    by_kind_hypothesis_contradicted: usize = 0,
    by_kind_verifier_candidate_failed: usize = 0,
    by_kind_patch_candidate_invalidated: usize = 0,
    by_kind_pack_signal_contradicted: usize = 0,
    by_kind_assumption_invalidated: usize = 0,
    by_kind_insufficient_test_detected: usize = 0,
    events: []CorrectionEvent = &.{},
    negative_knowledge_proposed_count: usize = 0,
    negative_knowledge_candidates: []NegativeKnowledgeCandidate = &.{},

    pub fn deinit(self: *CorrectionSummary) void {
        for (self.events) |*event| event.deinit();
        if (self.events.len != 0) self.allocator.free(self.events);
        for (self.negative_knowledge_candidates) |*candidate| candidate.deinit();
        if (self.negative_knowledge_candidates.len != 0) self.allocator.free(self.negative_knowledge_candidates);
        self.* = undefined;
    }
};

pub fn createCorrectionFromExecutionResult(
    allocator: std.mem.Allocator,
    result: *const verifier_execution.ExecutionResult,
    candidate_id: []const u8,
    previous_state: []const u8,
    correction_id_counter: *u64,
    budget: compute_budget.Effective,
    correction_count: *usize,
    negative_knowledge_count: *usize,
) !?CorrectionEvent {
    if (result.status != .failed and result.status != .timeout and result.contradiction_signals.len == 0) {
        return null;
    }
    _ = negative_knowledge_count;

    if (correction_count.* >= budget.max_correction_events) {
        return null;
    }

    const correction_kind: CorrectionKind = if (result.contradiction_signals.len > 0)
        .hypothesis_contradicted
    else if (result.status == .failed)
        .verifier_candidate_failed
    else
        .insufficient_test_detected;

    const id = try std.fmt.allocPrint(allocator, "correction:{d}:{s}", .{ correction_id_counter.*, candidate_id });
    correction_id_counter.* += 1;

    var failure_cause: ?[]u8 = null;
    if (result.contradiction_signals.len > 0) {
        failure_cause = try allocator.dupe(u8, result.contradiction_signals[0]);
    } else if (result.status == .timeout) {
        failure_cause = try std.fmt.allocPrint(allocator, "execution timed out after {d}ms", .{result.elapsed_ms});
    }

    const updated = if (result.status == .failed) "contradicted" else if (result.status == .timeout) "timeout_evidence" else "partially_contradicted";

    var summary_buf = std.ArrayList(u8).init(allocator);
    defer summary_buf.deinit();
    const writer = summary_buf.writer();
    try writer.print("verifier execution produced evidence: {s} contradicted", .{candidate_id});
    if (failure_cause) |cause| {
        try writer.print("; cause: {s}", .{cause});
    }

    correction_count.* += 1;

    return .{
        .allocator = allocator,
        .id = id,
        .correction_kind = correction_kind,
        .source_ref = try allocator.dupe(u8, result.job_id),
        .contradicted_ref = try allocator.dupe(u8, candidate_id),
        .contradicting_evidence_ref = try allocator.dupe(u8, result.evidence_kind),
        .previous_state = try allocator.dupe(u8, previous_state),
        .updated_state = try allocator.dupe(u8, updated),
        .failure_cause = failure_cause,
        .user_visible_summary = try summary_buf.toOwnedSlice(),
        .non_authorizing = true,
        .trace = try std.fmt.allocPrint(allocator, "correction from execution result {s}", .{result.job_id}),
    };
}

pub fn maybeCreateNegativeKnowledgeCandidate(
    allocator: std.mem.Allocator,
    correction: *const CorrectionEvent,
    nk_id_counter: *u64,
    budget: compute_budget.Effective,
    negative_knowledge_count: *usize,
) ?NegativeKnowledgeCandidate {
    if (correction.correction_kind != .hypothesis_contradicted and
        correction.correction_kind != .verifier_candidate_failed and
        correction.correction_kind != .insufficient_test_detected)
    {
        return null;
    }

    if (negative_knowledge_count.* >= budget.max_negative_knowledge_candidates) {
        return null;
    }

    const nk_kind: NegativeKnowledgeKind = switch (correction.correction_kind) {
        .hypothesis_contradicted => .failed_hypothesis,
        .verifier_candidate_failed => .unsafe_verifier_candidate,
        .insufficient_test_detected => .insufficient_test,
        else => .failed_repair_strategy,
    };

    const id = std.fmt.allocPrint(allocator, "nk:{d}:{s}", .{ nk_id_counter.*, correction.id }) catch return null;
    nk_id_counter.* += 1;
    negative_knowledge_count.* += 1;

    return .{
        .allocator = allocator,
        .id = id,
        .correction_event_id = allocator.dupe(u8, correction.id) catch unreachable,
        .candidate_kind = nk_kind,
        .scope = allocator.dupe(u8, correction.contradicted_ref) catch unreachable,
        .condition = allocator.dupe(u8, correction.updated_state) catch unreachable,
        .evidence_ref = allocator.dupe(u8, correction.contradicting_evidence_ref) catch unreachable,
        .permanence = .temporary,
        .non_authorizing = true,
    };
}

pub fn appendCorrectionToSupportGraph(
    allocator: std.mem.Allocator,
    nodes: *std.ArrayList(code_intel.SupportGraphNode),
    edges: *std.ArrayList(code_intel.SupportGraphEdge),
    output_id: []const u8,
    correction: *const CorrectionEvent,
    negative_knowledge: ?*const NegativeKnowledgeCandidate,
) !void {
    // Correction event node (non-authorizing)
    try nodes.append(.{
        .id = try std.fmt.allocPrint(allocator, "{s}:correction:{s}", .{ output_id, correction.id }),
        .kind = .correction_event,
        .label = try std.fmt.allocPrint(allocator, "correction {s}", .{correction.id}),
        .score = 0,
        .usable = false,
        .detail = try std.fmt.allocPrint(allocator, "kind={s} previous={s} updated={s} non_authorizing=true", .{
            @tagName(correction.correction_kind),
            correction.previous_state,
            correction.updated_state,
        }),
    });
    const correction_node_idx = nodes.items.len - 1;

    // Edge: correction_for
    try edges.append(.{
        .from_id = try allocator.dupe(u8, nodes.items[correction_node_idx].id),
        .to_id = try allocator.dupe(u8, correction.contradicted_ref),
        .kind = .correction_for,
    });

    // Edge: correction_from_evidence
    try edges.append(.{
        .from_id = try allocator.dupe(u8, nodes.items[correction_node_idx].id),
        .to_id = try allocator.dupe(u8, correction.contradicting_evidence_ref),
        .kind = .correction_from_evidence,
    });

    // Edge: correction_updates_state
    try edges.append(.{
        .from_id = try allocator.dupe(u8, nodes.items[correction_node_idx].id),
        .to_id = try allocator.dupe(u8, correction.contradicted_ref),
        .kind = .correction_updates_state,
    });

    if (negative_knowledge) |nk| {
        // Negative knowledge candidate node (non-authorizing)
        try nodes.append(.{
            .id = try std.fmt.allocPrint(allocator, "{s}:nk:{s}", .{ output_id, nk.id }),
            .kind = .negative_knowledge_candidate,
            .label = try std.fmt.allocPrint(allocator, "negative knowledge candidate {s}", .{nk.id}),
            .score = 0,
            .usable = false,
            .detail = try std.fmt.allocPrint(allocator, "kind={s} permanence={s} status=proposed non_authorizing=true", .{
                @tagName(nk.candidate_kind),
                @tagName(nk.permanence),
            }),
        });
        const nk_node_idx = nodes.items.len - 1;

        // Edge: proposes_negative_knowledge
        try edges.append(.{
            .from_id = try allocator.dupe(u8, nodes.items[correction_node_idx].id),
            .to_id = try allocator.dupe(u8, nodes.items[nk_node_idx].id),
            .kind = .proposes_negative_knowledge,
        });

        // Edge: negative_knowledge_from_correction
        try edges.append(.{
            .from_id = try allocator.dupe(u8, nodes.items[nk_node_idx].id),
            .to_id = try allocator.dupe(u8, nodes.items[correction_node_idx].id),
            .kind = .negative_knowledge_from_correction,
        });
    }
}

pub fn appendNegativeKnowledgeInfluenceToSupportGraph(
    allocator: std.mem.Allocator,
    nodes: *std.ArrayList(code_intel.SupportGraphNode),
    edges: *std.ArrayList(code_intel.SupportGraphEdge),
    output_id: []const u8,
    trace_entries: []const @import("negative_knowledge.zig").InfluenceTraceEntry,
    target_id: []const u8,
) !void {
    for (trace_entries, 0..) |entry, idx| {
        const influence_node_id = try std.fmt.allocPrint(allocator, "{s}:nk_influence:{s}:{d}", .{ output_id, entry.record_id, idx });
        const influence_kind_name = @tagName(entry.influence_kind);

        try nodes.append(.{
            .id = influence_node_id,
            .kind = .negative_knowledge_influence,
            .label = try std.fmt.allocPrint(allocator, "NK influence {s} on {s}", .{ entry.record_id, target_id }),
            .score = 0,
            .usable = false,
            .detail = try std.fmt.allocPrint(allocator, "kind={s} scope={s} triage_delta={d} non_authorizing=true", .{
                influence_kind_name,
                entry.matched_scope,
                entry.triage_delta,
            }),
        });
        const influence_node_idx = nodes.items.len - 1;

        const edge_kind: code_intel.SupportEdgeKind = switch (entry.influence_kind) {
            .triage_penalty => .negative_knowledge_influences_hypothesis,
            .verifier_requirement => .negative_knowledge_requires_verifier,
            .suppression_rule => .negative_knowledge_influences_hypothesis,
            .routing_warning => .negative_knowledge_warns_routing,
            .trust_decay_candidate => .proposes_trust_decay,
        };

        try edges.append(.{
            .from_id = try allocator.dupe(u8, nodes.items[influence_node_idx].id),
            .to_id = try allocator.dupe(u8, target_id),
            .kind = edge_kind,
        });

        try edges.append(.{
            .from_id = try allocator.dupe(u8, nodes.items[influence_node_idx].id),
            .to_id = try allocator.dupe(u8, entry.record_id),
            .kind = .negative_knowledge_from_candidate,
        });
    }

    // Add trust decay candidate nodes for any trust_decay_candidate entries
    for (trace_entries, 0..) |entry, idx| {
        if (entry.influence_kind != .trust_decay_candidate) continue;
        const td_node_id = try std.fmt.allocPrint(allocator, "{s}:trust_decay:{s}:{d}", .{ output_id, entry.record_id, idx });
        try nodes.append(.{
            .id = td_node_id,
            .kind = .trust_decay_candidate,
            .label = try std.fmt.allocPrint(allocator, "trust decay candidate from {s}", .{entry.record_id}),
            .score = 0,
            .usable = false,
            .detail = try std.fmt.allocPrint(allocator, "non_authorizing=true source_record={s}", .{entry.record_id}),
        });
        const td_node_idx = nodes.items.len - 1;

        try edges.append(.{
            .from_id = try allocator.dupe(u8, nodes.items[td_node_idx].id),
            .to_id = try allocator.dupe(u8, entry.record_id),
            .kind = .proposes_trust_decay,
        });
    }
}

pub fn correctionKindName(kind: CorrectionKind) []const u8 {
    return @tagName(kind);
}

pub fn negativeKnowledgeKindName(kind: NegativeKnowledgeKind) []const u8 {
    return @tagName(kind);
}

pub fn permanenceName(p: Permanence) []const u8 {
    return @tagName(p);
}

fn freeStringList(allocator: std.mem.Allocator, items: [][]u8) void {
    for (items) |item| allocator.free(item);
    if (items.len != 0) allocator.free(items);
}
