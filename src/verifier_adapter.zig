const std = @import("std");
const abstractions = @import("abstractions.zig");
const artifact_schema = @import("artifact_schema.zig");
const code_intel = @import("code_intel.zig");
const compute_budget = @import("compute_budget.zig");
const execution = @import("execution.zig");
const hypothesis_core = @import("hypothesis_core.zig");
const negative_knowledge = @import("negative_knowledge.zig");

pub const HookKind = enum {
    build,
    @"test",
    runtime,
    schema_validation,
    consistency_check,
    freshness_check,
    citation_check,
    unit_consistency,
    constraint_check,
    custom_external,
};

pub const EvidenceKind = enum {
    build_log,
    test_log,
    runtime_oracle,
    schema_report,
    consistency_report,
    freshness_report,
    citation_report,
    unit_report,
    constraint_report,
    external_report,
};

pub const Status = enum {
    passed,
    failed,
    blocked,
    skipped,
    budget_exhausted,
};

pub const HandoffMode = enum {
    draft,
    fast,
    deep,
    auto,
};

pub const HandoffJobStatus = enum {
    pending,
    scheduled,
    blocked,
    skipped,
    budget_exhausted,
    completed,
    failed,
};

pub const HandoffBlockedReason = enum {
    missing_verifier_hook,
    no_matching_adapter,
    unbound_artifact_scope,
    insufficient_evidence,
    contradiction_blocker,
    budget_exhausted,
    unsupported_domain,
    unsafe_or_disallowed_verification,
    blocked_by_negative_knowledge,
    no_adapter_satisfies_negative_knowledge,
};

pub const CandidateKind = enum {
    regression_test,
    consistency_check,
    schema_validation,
    invariant_check,
    diff_check,
    runtime_probe,
    static_check,
    document_consistency_check,
    config_validation_check,
    generic_check_plan,
};

pub const CandidateStatus = enum {
    proposed,
    blocked,
    accepted,
    rejected,
    materialized,
    scheduled,
    executed,
    failed,
    superseded,
};

pub const CandidateBlockedReason = enum {
    unbound_scope,
    insufficient_evidence,
    unsafe_check,
    unsupported_action,
    expected_observation_unknown,
    budget_exhausted,
    contradiction_blocker,
    approval_required,
    missing_candidate,
    not_approved,
    unsafe_materialization,
    negative_knowledge_blocked,
};

pub const ApprovalKind = enum {
    user,
    test_fixture,
    policy,
};

pub const VerifierCandidateApproval = struct {
    candidate_id: []u8,
    approved_by: []u8,
    approval_kind: ApprovalKind,
    approval_reason: []u8,
    timestamp_ms: u64,
    trace: []u8,
    scope: []u8,
    allow_materialize_check_plan: bool = false,
    allow_propose_file: bool = false,
    allow_propose_patch: bool = false,
    allow_schedule_verifier_later: bool = false,

    pub fn deinit(self: *VerifierCandidateApproval, allocator: std.mem.Allocator) void {
        allocator.free(self.candidate_id);
        allocator.free(self.approved_by);
        allocator.free(self.approval_reason);
        allocator.free(self.trace);
        allocator.free(self.scope);
        self.* = undefined;
    }
};

pub const MaterializationKind = enum {
    check_plan,
    file_proposal,
    patch_proposal,
    command_plan,
};

pub const VerifierCandidateMaterialization = struct {
    id: []u8,
    candidate_id: []u8,
    kind: MaterializationKind,
    generated_artifact_refs: [][]u8 = &.{},
    patch_proposal_refs: [][]u8 = &.{},
    write_proposal_refs: [][]u8 = &.{},
    command_plan_refs: [][]u8 = &.{},
    requires_approval: bool = true,
    requires_verification: bool = true,
    non_authorizing: bool = true,
    trace: []u8,

    pub fn deinit(self: *VerifierCandidateMaterialization, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.candidate_id);
        freeStringList(allocator, self.generated_artifact_refs);
        freeStringList(allocator, self.patch_proposal_refs);
        freeStringList(allocator, self.write_proposal_refs);
        freeStringList(allocator, self.command_plan_refs);
        allocator.free(self.trace);
        self.* = undefined;
    }
};

pub const CommandPlan = struct {
    argv: [][]u8 = &.{},
    requires_approval: bool = true,

    pub fn deinit(self: *CommandPlan, allocator: std.mem.Allocator) void {
        freeStringList(allocator, self.argv);
        self.* = undefined;
    }
};

pub const VerifierCandidate = struct {
    allocator: std.mem.Allocator,
    id: []u8,
    hypothesis_id: []u8,
    candidate_kind: CandidateKind,
    artifact_scope: []u8,
    target_claim_surface: []u8,
    proposed_check: []u8,
    required_inputs: [][]u8 = &.{},
    generated_artifacts: [][]u8 = &.{},
    command_plan: ?CommandPlan = null,
    patch_or_file_proposal: ?[]u8 = null,
    expected_observations: [][]u8 = &.{},
    safety_constraints: [][]u8 = &.{},
    missing_obligations: [][]u8 = &.{},
    scope_limitations: [][]u8 = &.{},
    status: CandidateStatus = .proposed,
    blocked_reason: ?CandidateBlockedReason = null,
    approval: ?VerifierCandidateApproval = null,
    materialization: ?VerifierCandidateMaterialization = null,
    rejection_reason: ?[]u8 = null,
    negative_knowledge_record_ids: [][]u8 = &.{},
    verifier_requirement: ?[]u8 = null,
    blocked_by_negative_knowledge: bool = false,
    required_strength: ?[]u8 = null,
    selected_adapter_after_nk: ?[]u8 = null,
    fallback_reason: ?[]u8 = null,
    requires_approval: bool = true,
    non_authorizing: bool = true,
    provenance: []u8,
    trace: []u8,

    pub fn deinit(self: *VerifierCandidate) void {
        self.allocator.free(self.id);
        self.allocator.free(self.hypothesis_id);
        self.allocator.free(self.artifact_scope);
        self.allocator.free(self.target_claim_surface);
        self.allocator.free(self.proposed_check);
        freeStringList(self.allocator, self.required_inputs);
        freeStringList(self.allocator, self.generated_artifacts);
        if (self.command_plan) |*plan| plan.deinit(self.allocator);
        if (self.patch_or_file_proposal) |value| self.allocator.free(value);
        freeStringList(self.allocator, self.expected_observations);
        freeStringList(self.allocator, self.safety_constraints);
        freeStringList(self.allocator, self.missing_obligations);
        freeStringList(self.allocator, self.scope_limitations);
        if (self.approval) |*approval| approval.deinit(self.allocator);
        if (self.materialization) |*materialization| materialization.deinit(self.allocator);
        if (self.rejection_reason) |reason| self.allocator.free(reason);
        freeStringList(self.allocator, self.negative_knowledge_record_ids);
        if (self.verifier_requirement) |value| self.allocator.free(value);
        if (self.required_strength) |value| self.allocator.free(value);
        if (self.selected_adapter_after_nk) |value| self.allocator.free(value);
        if (self.fallback_reason) |value| self.allocator.free(value);
        self.allocator.free(self.provenance);
        self.allocator.free(self.trace);
        self.* = undefined;
    }
};

pub const HandoffJob = struct {
    allocator: std.mem.Allocator,
    id: []u8,
    hypothesis_id: []u8,
    verifier_hook_kind: []u8,
    adapter_id: []u8,
    artifact_scope: []u8,
    required_entities: [][]u8 = &.{},
    required_relations: [][]u8 = &.{},
    required_obligations: [][]u8 = &.{},
    input_evidence_refs: [][]u8 = &.{},
    budget_cost: u32 = 0,
    status: HandoffJobStatus = .pending,
    blocked_reason: ?HandoffBlockedReason = null,
    result_ref: ?[]u8 = null,
    result_status: ?Status = null,
    evidence_ref: ?[]u8 = null,
    negative_knowledge_record_ids: [][]u8 = &.{},
    verifier_requirement: ?[]u8 = null,
    blocked_by_negative_knowledge: bool = false,
    required_strength: ?[]u8 = null,
    selected_adapter_after_nk: ?[]u8 = null,
    fallback_reason: ?[]u8 = null,
    non_authorizing_input: bool = true,
    trace: []u8,

    pub fn deinit(self: *HandoffJob) void {
        self.allocator.free(self.id);
        self.allocator.free(self.hypothesis_id);
        self.allocator.free(self.verifier_hook_kind);
        self.allocator.free(self.adapter_id);
        self.allocator.free(self.artifact_scope);
        freeStringList(self.allocator, self.required_entities);
        freeStringList(self.allocator, self.required_relations);
        freeStringList(self.allocator, self.required_obligations);
        freeStringList(self.allocator, self.input_evidence_refs);
        if (self.result_ref) |value| self.allocator.free(value);
        if (self.evidence_ref) |value| self.allocator.free(value);
        freeStringList(self.allocator, self.negative_knowledge_record_ids);
        if (self.verifier_requirement) |value| self.allocator.free(value);
        if (self.required_strength) |value| self.allocator.free(value);
        if (self.selected_adapter_after_nk) |value| self.allocator.free(value);
        if (self.fallback_reason) |value| self.allocator.free(value);
        self.allocator.free(self.trace);
        self.* = undefined;
    }
};

pub const HandoffResult = struct {
    allocator: std.mem.Allocator,
    eligible_count: usize = 0,
    scheduled_count: usize = 0,
    completed_count: usize = 0,
    blocked_count: usize = 0,
    skipped_count: usize = 0,
    budget_exhausted_count: usize = 0,
    code_job_count: usize = 0,
    non_code_job_count: usize = 0,
    jobs: []HandoffJob = &.{},
    verifier_candidates: []VerifierCandidate = &.{},
    verifier_candidate_proposed_count: usize = 0,
    verifier_candidate_blocked_count: usize = 0,
    verifier_candidate_accepted_count: usize = 0,
    verifier_candidate_materialized_count: usize = 0,
    verifier_candidate_rejected_count: usize = 0,
    verifier_candidate_materialization_blocked_count: usize = 0,
    verifier_candidate_scheduled_count: usize = 0,
    verifier_candidate_executed_count: usize = 0,
    verifier_candidate_budget_exhausted_count: usize = 0,
    code_verifier_candidate_count: usize = 0,
    non_code_verifier_candidate_count: usize = 0,
    negative_knowledge_verifier_requirement_count: usize = 0,
    negative_knowledge_verifier_blocked_count: usize = 0,
    negative_knowledge_verifier_strengthened_count: usize = 0,

    pub fn deinit(self: *HandoffResult) void {
        for (self.jobs) |*job| job.deinit();
        if (self.jobs.len != 0) self.allocator.free(self.jobs);
        for (self.verifier_candidates) |*candidate| candidate.deinit();
        if (self.verifier_candidates.len != 0) self.allocator.free(self.verifier_candidates);
        self.* = undefined;
    }
};

pub const HandoffInputs = struct {
    artifact: ?*const artifact_schema.Artifact = null,
    entities: []const artifact_schema.Entity = &.{},
    relations: []const artifact_schema.RelationEdge = &.{},
    obligations: []const artifact_schema.Obligation = &.{},
    fragments: []const artifact_schema.Fragment = &.{},
    negative_knowledge_records: []const negative_knowledge.Record = &.{},
};

const ArtifactCounter = struct {
    scope: []const u8,
    count: usize,
};

pub const Timing = struct {
    started_ms: u64 = 0,
    duration_ms: u64 = 0,
};

pub const Adapter = struct {
    id: []const u8,
    schema_name: []const u8,
    hook_kind: HookKind,
    input_artifact_types: []const artifact_schema.ArtifactType = &.{},
    required_entity_kinds: []const []const u8 = &.{},
    required_relation_kinds: []const artifact_schema.Relation = &.{},
    required_obligations: []const []const u8 = &.{},
    budget_cost: u32 = 1,
    trust_requirements: []const abstractions.TrustClass = &.{},
    output_evidence_kind: EvidenceKind,
};

pub const RunRequest = struct {
    adapter: Adapter,
    artifact: ?*const artifact_schema.Artifact = null,
    entities: []const artifact_schema.Entity = &.{},
    relations: []const artifact_schema.RelationEdge = &.{},
    obligations: []const artifact_schema.Obligation = &.{},
    fragments: []const artifact_schema.Fragment = &.{},
    provenance: []const u8 = "verifier_adapter",
};

pub const Result = struct {
    allocator: std.mem.Allocator,
    adapter_id: []u8,
    status: Status,
    evidence_kind: EvidenceKind,
    evidence: []u8,
    obligations_discharged: [][]u8 = &.{},
    obligations_remaining: [][]u8 = &.{},
    failure_signal: ?[]u8 = null,
    provenance: []u8,
    timing: Timing = .{},
    budget_exhaustion: ?compute_budget.Exhaustion = null,

    pub fn deinit(self: *Result) void {
        self.allocator.free(self.adapter_id);
        self.allocator.free(self.evidence);
        for (self.obligations_discharged) |item| self.allocator.free(item);
        self.allocator.free(self.obligations_discharged);
        for (self.obligations_remaining) |item| self.allocator.free(item);
        self.allocator.free(self.obligations_remaining);
        if (self.failure_signal) |signal| self.allocator.free(signal);
        self.allocator.free(self.provenance);
        if (self.budget_exhaustion) |*ex| ex.deinit();
        self.* = undefined;
    }
};

pub const BudgetTracker = struct {
    allocator: std.mem.Allocator,
    budget: compute_budget.Effective,
    runs_used: usize = 0,
    external_runs_used: usize = 0,
    evidence_bytes_used: usize = 0,

    pub fn init(allocator: std.mem.Allocator, budget: compute_budget.Effective) BudgetTracker {
        return .{ .allocator = allocator, .budget = budget };
    }

    pub fn reserve(self: *BudgetTracker, adapter: Adapter) !?compute_budget.Exhaustion {
        if (self.runs_used + 1 > self.budget.max_verifier_runs) {
            return try compute_budget.Exhaustion.init(
                self.allocator,
                .max_verifier_runs,
                .verifier_adapter_run,
                self.runs_used + 1,
                self.budget.max_verifier_runs,
                "verifier adapter run count exceeded selected compute budget",
                adapter.id,
            );
        }
        if (isExternal(adapter.hook_kind) and self.external_runs_used + 1 > self.budget.max_external_verifier_runs) {
            return try compute_budget.Exhaustion.init(
                self.allocator,
                .max_external_verifier_runs,
                .verifier_adapter_run,
                self.external_runs_used + 1,
                self.budget.max_external_verifier_runs,
                "external verifier adapter run count exceeded selected compute budget",
                adapter.id,
            );
        }
        self.runs_used += 1;
        if (isExternal(adapter.hook_kind)) self.external_runs_used += 1;
        return null;
    }

    pub fn accountEvidence(self: *BudgetTracker, result: *Result) !void {
        self.evidence_bytes_used += result.evidence.len;
        if (self.evidence_bytes_used > self.budget.max_verifier_evidence_bytes) {
            result.status = .budget_exhausted;
            if (result.failure_signal) |signal| self.allocator.free(signal);
            result.failure_signal = try self.allocator.dupe(u8, "verifier_evidence_budget_exhausted");
            result.budget_exhaustion = try compute_budget.Exhaustion.init(
                self.allocator,
                .max_verifier_evidence_bytes,
                .verifier_adapter_evidence,
                self.evidence_bytes_used,
                self.budget.max_verifier_evidence_bytes,
                "verifier evidence bytes exceeded selected compute budget",
                result.adapter_id,
            );
        }
    }
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    entries: std.StringHashMap(Adapter),
    lookup_cache: std.StringHashMap(Adapter),

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{
            .allocator = allocator,
            .entries = std.StringHashMap(Adapter).init(allocator),
            .lookup_cache = std.StringHashMap(Adapter).init(allocator),
        };
    }

    pub fn deinit(self: *Registry) void {
        var iter = self.entries.iterator();
        while (iter.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.entries.deinit();
        self.clearLookupCache();
        self.lookup_cache.deinit();
        self.* = undefined;
    }

    pub fn register(self: *Registry, adapter: Adapter) !void {
        const key = try self.allocator.dupe(u8, adapter.id);
        errdefer self.allocator.free(key);
        if (self.entries.fetchRemove(adapter.id)) |removed| self.allocator.free(removed.key);
        try self.entries.put(key, adapter);
        self.clearLookupCache();
    }

    pub fn lookup(self: *Registry, schema_name: []const u8, hook_kind: HookKind, obligation: ?[]const u8) ?Adapter {
        const cache_key = self.lookupCacheKey(schema_name, hook_kind, obligation) catch null;
        defer if (cache_key) |key| self.allocator.free(key);
        if (cache_key) |key| {
            if (self.lookup_cache.get(key)) |adapter| return adapter;
        }
        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            const adapter = entry.value_ptr.*;
            if (!std.mem.eql(u8, adapter.schema_name, schema_name)) continue;
            if (adapter.hook_kind != hook_kind) continue;
            if (obligation) |required| {
                if (!adapterDischarges(adapter, required)) continue;
            }
            if (cache_key) |key| {
                const owned_key = self.allocator.dupe(u8, key) catch return adapter;
                self.lookup_cache.put(owned_key, adapter) catch {
                    self.allocator.free(owned_key);
                    return adapter;
                };
            }
            return adapter;
        }
        return null;
    }

    pub fn listApplicable(self: *const Registry, allocator: std.mem.Allocator, schema_name: []const u8, hook_kind: ?HookKind) ![]Adapter {
        var items = std.ArrayList(Adapter).init(allocator);
        errdefer items.deinit();
        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            const adapter = entry.value_ptr.*;
            if (!std.mem.eql(u8, adapter.schema_name, schema_name)) continue;
            if (hook_kind) |kind| {
                if (adapter.hook_kind != kind) continue;
            }
            try items.append(adapter);
        }
        std.mem.sort(Adapter, items.items, {}, lessAdapter);
        return items.toOwnedSlice();
    }

    pub fn missingVerifierObligation(self: *Registry, schema_name: []const u8, hook_kind: HookKind, obligation: []const u8) bool {
        return self.lookup(schema_name, hook_kind, obligation) == null;
    }

    fn lookupCacheKey(self: *Registry, schema_name: []const u8, hook_kind: HookKind, obligation: ?[]const u8) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "{s}|{s}|{s}", .{
            schema_name,
            @tagName(hook_kind),
            obligation orelse "",
        });
    }

    fn clearLookupCache(self: *Registry) void {
        var iter = self.lookup_cache.iterator();
        while (iter.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.lookup_cache.clearRetainingCapacity();
    }
};

fn lessAdapter(_: void, a: Adapter, b: Adapter) bool {
    return std.mem.lessThan(u8, a.id, b.id);
}

fn adapterDischarges(adapter: Adapter, obligation: []const u8) bool {
    for (adapter.required_obligations) |item| {
        if (std.mem.eql(u8, item, obligation)) return true;
    }
    return false;
}

fn isExternal(kind: HookKind) bool {
    return switch (kind) {
        .build, .@"test", .runtime, .custom_external => true,
        else => false,
    };
}

fn verifierCandidateViewForAdapter(hypothesis: hypothesis_core.Hypothesis, adapter: Adapter) negative_knowledge.VerifierCandidateView {
    return .{
        .id = adapter.id,
        .artifact_scope = hypothesis.artifact_scope,
        .target_claim_surface = if (hypothesis.affected_entities.len > 0) hypothesis.affected_entities[0] else hypothesis.artifact_scope,
        .proposed_check = if (hypothesis.missing_obligations.len > 0) hypothesis.missing_obligations[0] else @tagName(adapter.hook_kind),
        .provenance = "hypothesis_verifier_handoff",
    };
}

fn verifierCandidateView(candidate: VerifierCandidate) negative_knowledge.VerifierCandidateView {
    return .{
        .id = candidate.id,
        .artifact_scope = candidate.artifact_scope,
        .target_claim_surface = candidate.target_claim_surface,
        .proposed_check = candidate.proposed_check,
        .provenance = candidate.provenance,
    };
}

fn applyNegativeKnowledgeToHandoffJob(
    allocator: std.mem.Allocator,
    job: *HandoffJob,
    influence: negative_knowledge.InfluenceResult,
    selected_adapter_after_nk: ?[]const u8,
    fallback_reason: ?[]const u8,
) !void {
    if (influence.matched_record_ids.len == 0) return;
    freeStringList(allocator, job.negative_knowledge_record_ids);
    job.negative_knowledge_record_ids = try cloneStringList(allocator, influence.matched_record_ids);
    if (influence.required_verifiers.len > 0) {
        if (job.verifier_requirement) |value| allocator.free(value);
        job.verifier_requirement = try allocator.dupe(u8, influence.required_verifiers[0]);
        if (job.required_strength) |value| allocator.free(value);
        job.required_strength = try allocator.dupe(u8, influence.required_verifiers[0]);
    }
    if (selected_adapter_after_nk) |value| {
        if (job.selected_adapter_after_nk) |old| allocator.free(old);
        job.selected_adapter_after_nk = try allocator.dupe(u8, value);
    }
    const effective_fallback: ?[]const u8 = if (fallback_reason) |value|
        value
    else if (influence.suppression_reason) |value|
        value
    else
        null;
    if (effective_fallback) |value| {
        if (job.fallback_reason) |old| allocator.free(old);
        job.fallback_reason = try allocator.dupe(u8, value);
        job.blocked_by_negative_knowledge = true;
    }
    const old_trace = job.trace;
    job.trace = try std.fmt.allocPrint(allocator, "{s}; negative_knowledge_record_ids={d}; verifier_requirement={s}; selected_adapter_after_nk={s}; fallback_reason={s}", .{
        old_trace,
        influence.matched_record_ids.len,
        if (influence.required_verifiers.len > 0) influence.required_verifiers[0] else "none",
        selected_adapter_after_nk orelse "none",
        effective_fallback orelse "none",
    });
    allocator.free(old_trace);
}

fn applyNegativeKnowledgeToVerifierCandidate(
    allocator: std.mem.Allocator,
    result: *HandoffResult,
    candidate: *VerifierCandidate,
    negative_records: []const negative_knowledge.Record,
    budget: compute_budget.Effective,
) !void {
    if (negative_records.len == 0) return;
    var influence = try negative_knowledge.influenceVerifierCandidate(allocator, negative_records, verifierCandidateView(candidate.*), budget);
    defer influence.deinit();
    if (influence.matched_record_ids.len == 0) return;
    candidate.negative_knowledge_record_ids = try cloneStringList(allocator, influence.matched_record_ids);
    if (influence.required_verifiers.len > 0) {
        candidate.verifier_requirement = try allocator.dupe(u8, influence.required_verifiers[0]);
        candidate.required_strength = try allocator.dupe(u8, influence.required_verifiers[0]);
        result.negative_knowledge_verifier_requirement_count += influence.required_verifiers.len;
    }
    if (influence.suppression_reason) |reason| {
        candidate.status = .blocked;
        candidate.blocked_reason = .negative_knowledge_blocked;
        candidate.blocked_by_negative_knowledge = true;
        candidate.fallback_reason = try allocator.dupe(u8, reason);
        result.negative_knowledge_verifier_blocked_count += 1;
    }
    const old_trace = candidate.trace;
    candidate.trace = try std.fmt.allocPrint(allocator, "{s}; negative_knowledge_record_ids={d}; verifier_requirement={s}; blocked_by_negative_knowledge={s}; fallback_reason={s}", .{
        old_trace,
        influence.matched_record_ids.len,
        if (influence.required_verifiers.len > 0) influence.required_verifiers[0] else "none",
        if (candidate.blocked_by_negative_knowledge) "true" else "false",
        candidate.fallback_reason orelse "none",
    });
    allocator.free(old_trace);
}

fn findAdapterForNegativeKnowledgeRequirement(
    allocator: std.mem.Allocator,
    registry: *Registry,
    schema_name: []const u8,
    base_adapter: Adapter,
    requirement: []const u8,
    mode: HandoffMode,
) !?Adapter {
    const maybe_hook = requirementHookKind(requirement);
    const applicable = try registry.listApplicable(allocator, schema_name, maybe_hook);
    defer allocator.free(applicable);
    var selected: ?Adapter = null;
    for (applicable) |adapter| {
        if (!adapterSatisfiesNegativeKnowledgeRequirement(adapter, requirement)) continue;
        if (!adapterIsStrongerThan(adapter, base_adapter, requirement)) continue;
        if (!modeAllowsAdapter(mode, adapter)) continue;
        if (selected == null or adapter.budget_cost > selected.?.budget_cost or (adapter.budget_cost == selected.?.budget_cost and std.mem.lessThan(u8, adapter.id, selected.?.id))) {
            selected = adapter;
        }
    }
    return selected;
}

fn adapterSatisfiesNegativeKnowledgeRequirement(adapter: Adapter, requirement: []const u8) bool {
    if (std.mem.eql(u8, adapter.id, requirement)) return true;
    if (std.mem.eql(u8, @tagName(adapter.hook_kind), requirement)) return true;
    if (std.mem.indexOf(u8, adapter.id, requirement) != null) return true;
    for (adapter.required_obligations) |obligation| {
        if (std.mem.eql(u8, obligation, requirement) or std.mem.indexOf(u8, obligation, requirement) != null) return true;
    }
    const hook = requirementHookKind(requirement) orelse return false;
    return adapter.hook_kind == hook and adapter.budget_cost > 1;
}

fn adapterIsStrongerThan(adapter: Adapter, base_adapter: Adapter, requirement: []const u8) bool {
    if (std.mem.eql(u8, adapter.id, base_adapter.id)) return !strongerRequirement(requirement) and adapterSatisfiesNegativeKnowledgeRequirement(adapter, requirement);
    if (adapter.budget_cost > base_adapter.budget_cost) return true;
    return adapterSatisfiesNegativeKnowledgeRequirement(adapter, requirement) and adapter.budget_cost >= base_adapter.budget_cost;
}

fn strongerRequirement(requirement: []const u8) bool {
    return std.mem.indexOf(u8, requirement, "strong") != null or
        std.mem.indexOf(u8, requirement, "enhanced") != null or
        std.mem.indexOf(u8, requirement, "deep") != null;
}

fn requirementHookKind(requirement: []const u8) ?HookKind {
    if (std.mem.indexOf(u8, requirement, "runtime") != null) return .runtime;
    if (std.mem.indexOf(u8, requirement, "test") != null) return .@"test";
    if (std.mem.indexOf(u8, requirement, "build") != null) return .build;
    if (std.mem.indexOf(u8, requirement, "schema") != null) return .schema_validation;
    if (std.mem.indexOf(u8, requirement, "consistency") != null) return .consistency_check;
    if (std.mem.indexOf(u8, requirement, "freshness") != null) return .freshness_check;
    if (std.mem.indexOf(u8, requirement, "citation") != null) return .citation_check;
    if (std.mem.indexOf(u8, requirement, "unit") != null) return .unit_consistency;
    if (std.mem.indexOf(u8, requirement, "constraint") != null) return .constraint_check;
    if (std.mem.indexOf(u8, requirement, "external") != null) return .custom_external;
    return null;
}

pub fn registerBuiltinAdapters(registry: *Registry) !void {
    try registry.register(codeBuildAdapter());
    try registry.register(codeTestAdapter());
    try registry.register(codeRuntimeOracleAdapter());
    try registry.register(configSchemaValidationAdapter());
    try registry.register(documentCitationCheckAdapter());
    try registry.register(documentFreshnessCheckAdapter());
    try registry.register(genericConsistencyCheckAdapter());
}

pub fn codeBuildAdapter() Adapter {
    return .{
        .id = "code.build.zig_build",
        .schema_name = "code_artifact_schema",
        .hook_kind = .build,
        .input_artifact_types = &.{ .file, .directory, .mixed },
        .required_entity_kinds = &.{ "module", "function" },
        .required_relation_kinds = &.{ .contains, .defines },
        .required_obligations = &.{"build"},
        .budget_cost = 4,
        .trust_requirements = &.{ .core, .project, .exploratory },
        .output_evidence_kind = .build_log,
    };
}

pub fn codeTestAdapter() Adapter {
    return .{
        .id = "code.test.zig_build_test",
        .schema_name = "code_artifact_schema",
        .hook_kind = .@"test",
        .input_artifact_types = &.{ .file, .directory, .mixed },
        .required_entity_kinds = &.{"function"},
        .required_relation_kinds = &.{ .references, .depends_on },
        .required_obligations = &.{"test"},
        .budget_cost = 4,
        .trust_requirements = &.{ .core, .project, .exploratory },
        .output_evidence_kind = .test_log,
    };
}

pub fn codeRuntimeOracleAdapter() Adapter {
    return .{
        .id = "code.runtime.oracle",
        .schema_name = "code_artifact_schema",
        .hook_kind = .runtime,
        .input_artifact_types = &.{ .file, .directory, .mixed },
        .required_entity_kinds = &.{"function"},
        .required_relation_kinds = &.{.references},
        .required_obligations = &.{"runtime"},
        .budget_cost = 5,
        .trust_requirements = &.{ .core, .project, .exploratory },
        .output_evidence_kind = .runtime_oracle,
    };
}

pub fn configSchemaValidationAdapter() Adapter {
    return .{
        .id = "config.schema.validation",
        .schema_name = "config_schema",
        .hook_kind = .schema_validation,
        .input_artifact_types = &.{ .file, .document },
        .required_entity_kinds = &.{ "key", "value" },
        .required_relation_kinds = &.{.contains},
        .required_obligations = &.{"schema_validation"},
        .budget_cost = 1,
        .trust_requirements = &.{ .core, .project, .exploratory },
        .output_evidence_kind = .schema_report,
    };
}

pub fn documentCitationCheckAdapter() Adapter {
    return .{
        .id = "document.citation.check",
        .schema_name = "document_schema",
        .hook_kind = .citation_check,
        .input_artifact_types = &.{ .document, .file },
        .required_entity_kinds = &.{"link"},
        .required_relation_kinds = &.{.references},
        .required_obligations = &.{"citation_check"},
        .budget_cost = 1,
        .trust_requirements = &.{ .core, .project, .exploratory },
        .output_evidence_kind = .citation_report,
    };
}

pub fn documentFreshnessCheckAdapter() Adapter {
    return .{
        .id = "document.freshness.check",
        .schema_name = "document_schema",
        .hook_kind = .freshness_check,
        .input_artifact_types = &.{ .document, .file },
        .required_entity_kinds = &.{"section"},
        .required_relation_kinds = &.{.contains},
        .required_obligations = &.{"freshness_check"},
        .budget_cost = 1,
        .trust_requirements = &.{ .core, .project, .exploratory },
        .output_evidence_kind = .freshness_report,
    };
}

pub fn genericConsistencyCheckAdapter() Adapter {
    return .{
        .id = "generic.consistency.check",
        .schema_name = "generic_schema",
        .hook_kind = .consistency_check,
        .input_artifact_types = &.{ .file, .document, .mixed, .corpus },
        .required_entity_kinds = &.{},
        .required_relation_kinds = &.{.contradicts},
        .required_obligations = &.{"consistency_check"},
        .budget_cost = 1,
        .trust_requirements = &.{ .core, .project, .exploratory },
        .output_evidence_kind = .consistency_report,
    };
}

pub fn run(allocator: std.mem.Allocator, tracker: *BudgetTracker, request: RunRequest) !Result {
    const started = std.time.milliTimestamp();
    if (try tracker.reserve(request.adapter)) |exhaustion| {
        return budgetResult(allocator, request.adapter, request.provenance, exhaustion);
    }

    var result = switch (request.adapter.hook_kind) {
        .schema_validation => try runSchemaValidation(allocator, request),
        .consistency_check => try runConsistencyCheck(allocator, request),
        .freshness_check => try runFreshnessCheck(allocator, request),
        .citation_check => try runCitationCheck(allocator, request),
        .unit_consistency, .constraint_check => try runRequiredStructureCheck(allocator, request),
        .build, .@"test", .runtime, .custom_external => try skippedResult(
            allocator,
            request.adapter,
            "external adapter execution must be bridged through the bounded execution harness",
            request.provenance,
        ),
    };
    result.timing.started_ms = @intCast(started);
    result.timing.duration_ms = @intCast(std.time.milliTimestamp() - started);
    try tracker.accountEvidence(&result);
    return result;
}

pub fn fromExecutionCapture(
    allocator: std.mem.Allocator,
    adapter: Adapter,
    capture: *const execution.Result,
    obligations: []const []const u8,
    provenance: []const u8,
) !Result {
    const status: Status = if (capture.succeeded()) .passed else .failed;
    const signal: ?[]const u8 = if (capture.failure_signal != .none)
        execution.failureSignalName(capture.failure_signal)
    else if (status == .failed)
        "command_failed"
    else
        null;
    const exit_text = if (capture.exit_code) |code|
        try std.fmt.allocPrint(allocator, "{d}", .{code})
    else
        try allocator.dupe(u8, "none");
    defer allocator.free(exit_text);
    const evidence = try std.fmt.allocPrint(
        allocator,
        "command={s}; exit_code={s}; stdout_bytes={d}; stderr_bytes={d}; summary={s}",
        .{
            capture.command,
            exit_text,
            capture.stdout.len,
            capture.stderr.len,
            capture.invariant_summary orelse "none",
        },
    );
    return makeResult(
        allocator,
        adapter,
        status,
        evidence,
        obligations,
        if (status == .passed) &.{} else obligations,
        signal,
        provenance,
        .{ .duration_ms = capture.duration_ms },
    );
}

fn runSchemaValidation(allocator: std.mem.Allocator, request: RunRequest) !Result {
    if (request.artifact == null) return blockedResult(allocator, request.adapter, "schema validation requires an artifact", request.provenance);
    const missing = try missingEntityKinds(allocator, request.adapter.required_entity_kinds, request.entities);
    defer allocator.free(missing);
    if (missing.len > 0) {
        const evidence = try std.fmt.allocPrint(allocator, "schema={s}; missing_entity_kind={s}", .{ request.adapter.schema_name, missing[0] });
        return makeResult(allocator, request.adapter, .failed, evidence, &.{}, request.adapter.required_obligations, "missing_required_entity_kind", request.provenance, .{});
    }
    return makeResult(allocator, request.adapter, .passed, try allocator.dupe(u8, "required schema entity kinds were present"), request.adapter.required_obligations, &.{}, null, request.provenance, .{});
}

fn runConsistencyCheck(allocator: std.mem.Allocator, request: RunRequest) !Result {
    for (request.relations) |relation| {
        if (relation.relation == .contradicts) {
            const evidence = try std.fmt.allocPrint(allocator, "contradiction relation from {s} to {s}", .{ relation.from_entity_id, relation.to_entity_id });
            return makeResult(allocator, request.adapter, .failed, evidence, &.{}, request.adapter.required_obligations, "contradiction_relation_present", request.provenance, .{});
        }
    }
    return makeResult(allocator, request.adapter, .passed, try allocator.dupe(u8, "no contradiction relations were present"), request.adapter.required_obligations, &.{}, null, request.provenance, .{});
}

fn runFreshnessCheck(allocator: std.mem.Allocator, request: RunRequest) !Result {
    for (request.fragments) |fragment| {
        if (std.mem.indexOf(u8, fragment.raw_text, "stale") != null or std.mem.indexOf(u8, fragment.raw_text, "outdated") != null) {
            return makeResult(allocator, request.adapter, .failed, try allocator.dupe(u8, "freshness marker indicates stale or outdated content"), &.{}, request.adapter.required_obligations, "stale_content_marker", request.provenance, .{});
        }
    }
    return makeResult(allocator, request.adapter, .passed, try allocator.dupe(u8, "no stale freshness markers were present"), request.adapter.required_obligations, &.{}, null, request.provenance, .{});
}

fn runCitationCheck(allocator: std.mem.Allocator, request: RunRequest) !Result {
    for (request.entities) |entity| {
        if (std.mem.eql(u8, entity.entity_type, "link")) {
            return makeResult(allocator, request.adapter, .passed, try allocator.dupe(u8, "document contains at least one citation/link entity"), request.adapter.required_obligations, &.{}, null, request.provenance, .{});
        }
    }
    return makeResult(allocator, request.adapter, .blocked, try allocator.dupe(u8, "citation check requires at least one link entity"), &.{}, request.adapter.required_obligations, "missing_citation_entity", request.provenance, .{});
}

fn runRequiredStructureCheck(allocator: std.mem.Allocator, request: RunRequest) !Result {
    const missing = try missingEntityKinds(allocator, request.adapter.required_entity_kinds, request.entities);
    defer allocator.free(missing);
    if (missing.len > 0) {
        const evidence = try std.fmt.allocPrint(allocator, "missing required entity kind {s}", .{missing[0]});
        return makeResult(allocator, request.adapter, .blocked, evidence, &.{}, request.adapter.required_obligations, "missing_required_structure", request.provenance, .{});
    }
    return makeResult(allocator, request.adapter, .passed, try allocator.dupe(u8, "required structure was present"), request.adapter.required_obligations, &.{}, null, request.provenance, .{});
}

fn missingEntityKinds(allocator: std.mem.Allocator, required: []const []const u8, entities: []const artifact_schema.Entity) ![][]const u8 {
    var missing = std.ArrayList([]const u8).init(allocator);
    errdefer missing.deinit();
    for (required) |kind| {
        var found = false;
        for (entities) |entity| {
            if (std.mem.eql(u8, entity.entity_type, kind)) {
                found = true;
                break;
            }
        }
        if (!found) try missing.append(kind);
    }
    return missing.toOwnedSlice();
}

fn blockedResult(allocator: std.mem.Allocator, adapter: Adapter, evidence: []const u8, provenance: []const u8) !Result {
    return makeResult(allocator, adapter, .blocked, try allocator.dupe(u8, evidence), &.{}, adapter.required_obligations, "blocked", provenance, .{});
}

fn skippedResult(allocator: std.mem.Allocator, adapter: Adapter, evidence: []const u8, provenance: []const u8) !Result {
    return makeResult(allocator, adapter, .skipped, try allocator.dupe(u8, evidence), &.{}, adapter.required_obligations, "skipped", provenance, .{});
}

fn budgetResult(allocator: std.mem.Allocator, adapter: Adapter, provenance: []const u8, exhaustion: compute_budget.Exhaustion) !Result {
    var result = try makeResult(allocator, adapter, .budget_exhausted, try allocator.dupe(u8, "verifier adapter budget exhausted before execution"), &.{}, adapter.required_obligations, "budget_exhausted", provenance, .{});
    result.budget_exhaustion = exhaustion;
    return result;
}

fn makeResult(
    allocator: std.mem.Allocator,
    adapter: Adapter,
    status: Status,
    evidence: []u8,
    discharged: []const []const u8,
    remaining: []const []const u8,
    failure_signal: ?[]const u8,
    provenance: []const u8,
    timing: Timing,
) !Result {
    errdefer allocator.free(evidence);
    return .{
        .allocator = allocator,
        .adapter_id = try allocator.dupe(u8, adapter.id),
        .status = status,
        .evidence_kind = adapter.output_evidence_kind,
        .evidence = evidence,
        .obligations_discharged = try cloneStringList(allocator, discharged),
        .obligations_remaining = try cloneStringList(allocator, remaining),
        .failure_signal = if (failure_signal) |signal| try allocator.dupe(u8, signal) else null,
        .provenance = try allocator.dupe(u8, provenance),
        .timing = timing,
    };
}

fn cloneStringList(allocator: std.mem.Allocator, items: []const []const u8) ![][]u8 {
    const out = try allocator.alloc([]u8, items.len);
    errdefer allocator.free(out);
    for (items, 0..) |item, idx| out[idx] = try allocator.dupe(u8, item);
    return out;
}

pub fn appendResultToSupportGraph(
    allocator: std.mem.Allocator,
    nodes: *std.ArrayList(code_intel.SupportGraphNode),
    edges: *std.ArrayList(code_intel.SupportGraphEdge),
    parent_id: []const u8,
    result: Result,
    ordinal: usize,
) !void {
    const adapter_node = try std.fmt.allocPrint(allocator, "verifier_adapter_{d}", .{ordinal});
    defer allocator.free(adapter_node);
    const run_node = try std.fmt.allocPrint(allocator, "verifier_run_{d}", .{ordinal});
    defer allocator.free(run_node);
    const evidence_node = try std.fmt.allocPrint(allocator, "verifier_evidence_{d}", .{ordinal});
    defer allocator.free(evidence_node);
    try appendNode(allocator, nodes, adapter_node, .verifier_adapter, result.adapter_id, null, 0, 0, false, "capability only; does not authorize support directly");
    try appendNode(allocator, nodes, run_node, .verifier_run, statusName(result.status), null, 0, 0, result.status == .passed, result.provenance);
    try appendNode(allocator, nodes, evidence_node, if (result.status == .failed or result.status == .blocked or result.status == .budget_exhausted) .verifier_failure else .verifier_evidence, evidenceKindName(result.evidence_kind), null, 0, 0, result.status == .passed, result.evidence);
    try appendEdge(allocator, edges, parent_id, adapter_node, .required_by);
    try appendEdge(allocator, edges, adapter_node, run_node, .verifies);
    try appendEdge(allocator, edges, run_node, evidence_node, .produced_evidence);
    if (result.status == .failed) try appendEdge(allocator, edges, parent_id, evidence_node, .failed_by);
    if (result.status == .blocked or result.status == .budget_exhausted) try appendEdge(allocator, edges, parent_id, evidence_node, .blocked_by);
    for (result.obligations_discharged, 0..) |_, idx| {
        if (idx >= 4) break;
        try appendEdge(allocator, edges, evidence_node, parent_id, .discharges);
    }
}

pub fn handoffSelectedHypotheses(
    allocator: std.mem.Allocator,
    registry: *Registry,
    tracker: *BudgetTracker,
    hypotheses: []const hypothesis_core.Hypothesis,
    triage: hypothesis_core.TriageResult,
    inputs: HandoffInputs,
    mode: HandoffMode,
) !HandoffResult {
    var jobs = std.ArrayList(HandoffJob).init(allocator);
    errdefer {
        for (jobs.items) |*job| job.deinit();
        jobs.deinit();
    }
    var candidates = std.ArrayList(VerifierCandidate).init(allocator);
    errdefer {
        for (candidates.items) |*candidate| candidate.deinit();
        candidates.deinit();
    }
    var result = HandoffResult{ .allocator = allocator };
    var artifact_counts = std.ArrayList(ArtifactCounter).init(allocator);
    defer artifact_counts.deinit();

    for (triage.items, 0..) |item, idx| {
        if (idx >= hypotheses.len) break;
        if (!item.selected_for_next_stage or item.triage_status != .selected) continue;
        const hypothesis = hypotheses[idx];
        if (hypothesis.verifier_hooks_needed.len == 0) {
            const job = try makeBlockedHandoffJob(allocator, hypothesis, "missing_verifier_hook", null, .missing_verifier_hook, "selected hypothesis had no verifier_hooks_needed entry");
            try maybeAppendVerifierCandidate(allocator, &result, &candidates, hypothesis, job, .missing_verifier_hook, tracker.budget, inputs.negative_knowledge_records);
            try jobs.append(job);
            result.blocked_count += 1;
            continue;
        }
        result.eligible_count += 1;

        if (!boundArtifactScope(hypothesis.artifact_scope)) {
            const job = try makeBlockedHandoffJob(allocator, hypothesis, hypothesis.verifier_hooks_needed[0], null, .unbound_artifact_scope, "verification blocked because artifact scope is not bound");
            try maybeAppendVerifierCandidate(allocator, &result, &candidates, hypothesis, job, .unbound_artifact_scope, tracker.budget, inputs.negative_knowledge_records);
            try jobs.append(job);
            result.blocked_count += 1;
            continue;
        }
        if (!provenanceBackedEvidence(hypothesis)) {
            const job = try makeBlockedHandoffJob(allocator, hypothesis, hypothesis.verifier_hooks_needed[0], null, .insufficient_evidence, "verification blocked because hypothesis input evidence was not provenance-backed");
            try maybeAppendVerifierCandidate(allocator, &result, &candidates, hypothesis, job, .insufficient_evidence, tracker.budget, inputs.negative_knowledge_records);
            try jobs.append(job);
            result.blocked_count += 1;
            continue;
        }
        if (hasUnsafeSignal(hypothesis)) {
            const job = try makeBlockedHandoffJob(allocator, hypothesis, hypothesis.verifier_hooks_needed[0], null, .unsafe_or_disallowed_verification, "verification blocked by unsafe or disallowed verifier request");
            try maybeAppendVerifierCandidate(allocator, &result, &candidates, hypothesis, job, .unsafe_or_disallowed_verification, tracker.budget, inputs.negative_knowledge_records);
            try jobs.append(job);
            result.blocked_count += 1;
            continue;
        }
        if (hasContradictionBlocker(hypothesis)) {
            const job = try makeBlockedHandoffJob(allocator, hypothesis, hypothesis.verifier_hooks_needed[0], null, .contradiction_blocker, "verification blocked by active contradiction blocker");
            try maybeAppendVerifierCandidate(allocator, &result, &candidates, hypothesis, job, .contradiction_blocker, tracker.budget, inputs.negative_knowledge_records);
            try jobs.append(job);
            result.blocked_count += 1;
            continue;
        }
        if (jobs.items.len >= tracker.budget.max_hypothesis_verifier_jobs) {
            const job = try makeBlockedHandoffJob(allocator, hypothesis, hypothesis.verifier_hooks_needed[0], null, .budget_exhausted, "hypothesis verifier job budget exhausted before scheduling");
            try maybeAppendVerifierCandidate(allocator, &result, &candidates, hypothesis, job, .budget_exhausted, tracker.budget, inputs.negative_knowledge_records);
            try jobs.append(job);
            result.budget_exhausted_count += 1;
            continue;
        }
        if (countArtifactJobs(artifact_counts.items, hypothesis.artifact_scope) >= tracker.budget.max_hypothesis_verifier_jobs_per_artifact) {
            const job = try makeBlockedHandoffJob(allocator, hypothesis, hypothesis.verifier_hooks_needed[0], null, .budget_exhausted, "per-artifact hypothesis verifier job budget exhausted before scheduling");
            try maybeAppendVerifierCandidate(allocator, &result, &candidates, hypothesis, job, .budget_exhausted, tracker.budget, inputs.negative_knowledge_records);
            try jobs.append(job);
            result.budget_exhausted_count += 1;
            continue;
        }

        const hook_kind = parseHookKind(hypothesis.verifier_hooks_needed[0]) orelse {
            const job = try makeBlockedHandoffJob(allocator, hypothesis, hypothesis.verifier_hooks_needed[0], null, .unsupported_domain, "verification blocked because hook kind is not supported by the adapter interface");
            try maybeAppendVerifierCandidate(allocator, &result, &candidates, hypothesis, job, .unsupported_domain, tracker.budget, inputs.negative_knowledge_records);
            try jobs.append(job);
            result.blocked_count += 1;
            continue;
        };
        var adapter = registry.lookup(hypothesis.schema_name, hook_kind, firstObligation(hypothesis)) orelse registry.lookup(hypothesis.schema_name, hook_kind, null) orelse {
            const job = try makeBlockedHandoffJob(allocator, hypothesis, hypothesis.verifier_hooks_needed[0], null, .no_matching_adapter, "verification blocked because no matching verifier adapter exists");
            try maybeAppendVerifierCandidate(allocator, &result, &candidates, hypothesis, job, .no_matching_adapter, tracker.budget, inputs.negative_knowledge_records);
            try jobs.append(job);
            result.blocked_count += 1;
            continue;
        };
        if (inputs.negative_knowledge_records.len > 0) {
            var influence = try negative_knowledge.influenceVerifierCandidate(
                allocator,
                inputs.negative_knowledge_records,
                verifierCandidateViewForAdapter(hypothesis, adapter),
                tracker.budget,
            );
            defer influence.deinit();
            if (influence.matched_record_ids.len > 0) result.negative_knowledge_verifier_requirement_count += influence.required_verifiers.len;
            if (influence.suppression_reason) |reason| {
                var job = try makeBlockedHandoffJob(allocator, hypothesis, hypothesis.verifier_hooks_needed[0], adapter.id, .blocked_by_negative_knowledge, reason);
                try applyNegativeKnowledgeToHandoffJob(allocator, &job, influence, null, reason);
                try jobs.append(job);
                result.blocked_count += 1;
                result.negative_knowledge_verifier_blocked_count += 1;
                continue;
            }
            if (influence.required_verifiers.len > 0) {
                const requirement = influence.required_verifiers[0];
                const selected = try findAdapterForNegativeKnowledgeRequirement(allocator, registry, hypothesis.schema_name, adapter, requirement, mode);
                if (selected) |strengthened| {
                    adapter = strengthened;
                    result.negative_knowledge_verifier_strengthened_count += 1;
                } else {
                    var job = try makeBlockedHandoffJob(allocator, hypothesis, hypothesis.verifier_hooks_needed[0], adapter.id, .no_adapter_satisfies_negative_knowledge, "no verifier adapter satisfied accepted negative knowledge verifier requirement");
                    try applyNegativeKnowledgeToHandoffJob(allocator, &job, influence, null, "no_adapter_satisfies_negative_knowledge");
                    try jobs.append(job);
                    result.blocked_count += 1;
                    result.negative_knowledge_verifier_blocked_count += 1;
                    continue;
                }
            }
        }
        if (!modeAllowsAdapter(mode, adapter)) {
            var job = try makeScheduledHandoffJob(allocator, hypothesis, adapter, .skipped, "verification skipped by response mode policy");
            try setJobResult(allocator, &job, .skipped, null, "response_mode_policy_skipped");
            try jobs.append(job);
            result.skipped_count += 1;
            continue;
        }

        var job = try makeScheduledHandoffJob(allocator, hypothesis, adapter, .scheduled, "verification scheduled from selected non-authorizing hypothesis");
        if (inputs.negative_knowledge_records.len > 0) {
            var influence = try negative_knowledge.influenceVerifierCandidate(
                allocator,
                inputs.negative_knowledge_records,
                verifierCandidateViewForAdapter(hypothesis, adapter),
                tracker.budget,
            );
            defer influence.deinit();
            try applyNegativeKnowledgeToHandoffJob(allocator, &job, influence, adapter.id, null);
        }
        result.scheduled_count += 1;
        try incrementArtifactJobs(allocator, &artifact_counts, hypothesis.artifact_scope);

        var adapter_result = try run(allocator, tracker, .{
            .adapter = adapter,
            .artifact = inputs.artifact,
            .entities = inputs.entities,
            .relations = inputs.relations,
            .obligations = inputs.obligations,
            .fragments = inputs.fragments,
            .provenance = "hypothesis_verifier_handoff",
        });
        defer adapter_result.deinit();
        try setJobResult(allocator, &job, adapter_result.status, adapter_result.evidence, adapter_result.adapter_id);
        switch (adapter_result.status) {
            .passed => {
                job.status = .completed;
                result.completed_count += 1;
            },
            .failed => {
                job.status = .failed;
                result.completed_count += 1;
            },
            .blocked => {
                job.status = .blocked;
                job.blocked_reason = .insufficient_evidence;
                result.blocked_count += 1;
            },
            .skipped => {
                job.status = .skipped;
                result.skipped_count += 1;
            },
            .budget_exhausted => {
                job.status = .budget_exhausted;
                job.blocked_reason = .budget_exhausted;
                result.budget_exhausted_count += 1;
            },
        }
        try jobs.append(job);
    }
    result.code_job_count = 0;
    result.non_code_job_count = 0;
    for (jobs.items) |job| {
        if (std.mem.startsWith(u8, job.adapter_id, "code.") or
            std.mem.indexOf(u8, job.artifact_scope, ".zig") != null or
            std.mem.indexOf(u8, job.artifact_scope, "src/") != null)
        {
            result.code_job_count += 1;
        } else {
            result.non_code_job_count += 1;
        }
    }
    result.jobs = try jobs.toOwnedSlice();
    result.verifier_candidates = try candidates.toOwnedSlice();
    return result;
}

pub fn appendHandoffToSupportGraph(
    allocator: std.mem.Allocator,
    nodes: *std.ArrayList(code_intel.SupportGraphNode),
    edges: *std.ArrayList(code_intel.SupportGraphEdge),
    parent_id: []const u8,
    handoff: HandoffResult,
) !void {
    if (handoff.jobs.len == 0) return;
    try appendNode(allocator, nodes, "hypothesis_verifier_handoff", .hypothesis_verifier_job, "verification scheduled", null, 0, @intCast(handoff.scheduled_count), false, "hypothesis verifier jobs are non-authorizing requests for adapter evidence");
    try appendEdge(allocator, edges, "hypothesis_verifier_handoff", parent_id, .schedules_verifier);
    for (handoff.jobs, 0..) |job, idx| {
        const job_id = try std.fmt.allocPrint(allocator, "hypothesis_verifier_job_{d}", .{idx + 1});
        defer allocator.free(job_id);
        const job_detail = try std.fmt.allocPrint(
            allocator,
            "{s}; negative_knowledge_record_ids={d}; verifier_requirement={s}; blocked_by_negative_knowledge={s}; required_strength={s}; selected_adapter_after_nk={s}; fallback_reason={s}",
            .{
                job.trace,
                job.negative_knowledge_record_ids.len,
                job.verifier_requirement orelse "none",
                if (job.blocked_by_negative_knowledge) "true" else "false",
                job.required_strength orelse "none",
                job.selected_adapter_after_nk orelse "none",
                job.fallback_reason orelse "none",
            },
        );
        defer allocator.free(job_detail);
        try appendNode(allocator, nodes, job_id, .hypothesis_verifier_job, job.id, null, 0, job.budget_cost, false, job_detail);
        try appendEdge(allocator, edges, "hypothesis_verifier_handoff", job_id, .schedules_verifier);
        try appendEdge(allocator, edges, job_id, parent_id, .verifier_job_for);
        if (job.negative_knowledge_record_ids.len > 0) {
            const nk_id = try std.fmt.allocPrint(allocator, "negative_knowledge_verifier_influence_{d}", .{idx + 1});
            defer allocator.free(nk_id);
            try appendNode(allocator, nodes, nk_id, .negative_knowledge_influence, "negative knowledge verifier influence", null, 0, @intCast(@min(job.negative_knowledge_record_ids.len, std.math.maxInt(u32))), false, "non-authorizing verifier selection influence only");
            try appendEdge(allocator, edges, nk_id, job_id, .negative_knowledge_requires_verifier);
            if (job.blocked_by_negative_knowledge) try appendEdge(allocator, edges, job_id, nk_id, .blocked_verification_by);
        }
        if (job.evidence_ref) |evidence| {
            const result_id = try std.fmt.allocPrint(allocator, "hypothesis_verifier_result_{d}", .{idx + 1});
            defer allocator.free(result_id);
            const node_kind: code_intel.SupportNodeKind = if (job.result_status == .failed) .verifier_failure else .hypothesis_verifier_result;
            try appendNode(allocator, nodes, result_id, node_kind, evidence, null, 0, 0, job.result_status == .passed, "verifier evidence produced; normal support obligations still apply");
            try appendEdge(allocator, edges, result_id, job_id, .verifier_result_for);
            try appendEdge(allocator, edges, job_id, result_id, .produces_verifier_evidence);
        }
        if (job.blocked_reason) |_| try appendEdge(allocator, edges, job_id, parent_id, .blocked_verification_by);
    }
    try appendVerifierCandidatesToSupportGraph(allocator, nodes, edges, parent_id, handoff.verifier_candidates);
}

fn appendVerifierCandidatesToSupportGraph(
    allocator: std.mem.Allocator,
    nodes: *std.ArrayList(code_intel.SupportGraphNode),
    edges: *std.ArrayList(code_intel.SupportGraphEdge),
    parent_id: []const u8,
    candidates: []const VerifierCandidate,
) !void {
    if (candidates.len == 0) return;
    try appendNode(allocator, nodes, "verifier_candidates", .verifier_candidate, "proposed verifier candidate", null, 0, @intCast(candidates.len), false, "non-authorizing verifier candidates; not evidence until accepted and executed");
    try appendEdge(allocator, edges, "verifier_candidates", parent_id, .proposes_verifier_for);
    for (candidates, 0..) |candidate, idx| {
        const candidate_id = try std.fmt.allocPrint(allocator, "verifier_candidate_{d}", .{idx + 1});
        defer allocator.free(candidate_id);
        const detail = try std.fmt.allocPrint(
            allocator,
            "kind={s}; status={s}; requires_approval={s}; non_authorizing={s}; check={s}; does_not_check={s}; negative_knowledge_record_ids={d}; verifier_requirement={s}; blocked_by_negative_knowledge={s}; required_strength={s}; selected_adapter_after_nk={s}; fallback_reason={s}; trace={s}",
            .{
                candidateKindName(candidate.candidate_kind),
                candidateStatusName(candidate.status),
                if (candidate.requires_approval) "true" else "false",
                if (candidate.non_authorizing) "true" else "false",
                candidate.proposed_check,
                if (candidate.scope_limitations.len > 0) candidate.scope_limitations[0] else "final support or truth",
                candidate.negative_knowledge_record_ids.len,
                candidate.verifier_requirement orelse "none",
                if (candidate.blocked_by_negative_knowledge) "true" else "false",
                candidate.required_strength orelse "none",
                candidate.selected_adapter_after_nk orelse "none",
                candidate.fallback_reason orelse "none",
                candidate.trace,
            },
        );
        defer allocator.free(detail);
        try appendNode(allocator, nodes, candidate_id, .verifier_candidate, candidate.id, null, 0, 0, false, detail);
        try appendEdge(allocator, edges, "verifier_candidates", candidate_id, .proposes_verifier_for);
        try appendEdge(allocator, edges, candidate_id, parent_id, .proposes_verifier_for);

        const plan_id = try std.fmt.allocPrint(allocator, "verifier_candidate_check_plan_{d}", .{idx + 1});
        defer allocator.free(plan_id);
        try appendNode(allocator, nodes, plan_id, .verifier_candidate_check_plan, candidate.proposed_check, null, 0, 0, false, "check plan only; does not discharge obligations");
        try appendEdge(allocator, edges, candidate_id, plan_id, .candidate_checks);

        if (candidate.approval) |approval| {
            const approval_id = try std.fmt.allocPrint(allocator, "verifier_candidate_approval_{d}", .{idx + 1});
            defer allocator.free(approval_id);
            try appendNode(allocator, nodes, approval_id, .verifier_candidate_approval, approval.approved_by, null, 0, 0, false, approval.approval_reason);
            try appendEdge(allocator, edges, approval_id, candidate_id, .approves_candidate);
        }

        if (candidate.materialization) |mat| {
            const mat_id = try std.fmt.allocPrint(allocator, "verifier_candidate_materialization_{d}", .{idx + 1});
            defer allocator.free(mat_id);
            try appendNode(allocator, nodes, mat_id, .verifier_candidate_materialization, @tagName(mat.kind), null, 0, 0, false, mat.trace);
            try appendEdge(allocator, edges, mat_id, candidate_id, .materializes_candidate);
            for (mat.generated_artifact_refs, 0..) |ref, ref_idx| {
                if (ref_idx >= 2) break;
                const ref_node_id = try std.fmt.allocPrint(allocator, "verifier_candidate_materialized_artifact_{d}_{d}", .{ idx + 1, ref_idx + 1 });
                defer allocator.free(ref_node_id);
                try appendNode(allocator, nodes, ref_node_id, .verifier_candidate_artifact, ref, null, 0, 0, false, "materialized artifact proposal");
                try appendEdge(allocator, edges, mat_id, ref_node_id, .materialization_proposes_artifact);
            }
        }

        if (candidate.status == .rejected) {
            const rejection_id = try std.fmt.allocPrint(allocator, "verifier_candidate_rejection_{d}", .{idx + 1});
            defer allocator.free(rejection_id);
            try appendNode(allocator, nodes, rejection_id, .verifier_candidate_rejection, candidate.rejection_reason orelse "rejected", null, 0, 0, false, "candidate rejected by lifecycle");
            try appendEdge(allocator, edges, rejection_id, candidate_id, .rejects_candidate);
        }

        for (candidate.required_inputs, 0..) |input, input_idx| {
            if (input_idx >= 2) break;
            const input_id = try std.fmt.allocPrint(allocator, "verifier_candidate_input_{d}_{d}", .{ idx + 1, input_idx + 1 });
            defer allocator.free(input_id);
            try appendNode(allocator, nodes, input_id, .verifier_candidate_safety_obligation, input, null, 0, 0, false, "candidate requires bounded input before materialization or execution");
            try appendEdge(allocator, edges, candidate_id, input_id, .candidate_requires_input);
        }
        for (candidate.generated_artifacts, 0..) |artifact_ref, artifact_idx| {
            if (artifact_idx >= 2) break;
            const artifact_id = try std.fmt.allocPrint(allocator, "verifier_candidate_artifact_{d}_{d}", .{ idx + 1, artifact_idx + 1 });
            defer allocator.free(artifact_id);
            try appendNode(allocator, nodes, artifact_id, .verifier_candidate_artifact, artifact_ref, null, 0, 0, false, "generated artifact proposal only; requires approval before write");
            try appendEdge(allocator, edges, candidate_id, artifact_id, .candidate_materializes_as);
        }
        if (candidate.requires_approval) {
            const approval_id = try std.fmt.allocPrint(allocator, "verifier_candidate_approval_{d}", .{idx + 1});
            defer allocator.free(approval_id);
            try appendNode(allocator, nodes, approval_id, .verifier_candidate_safety_obligation, "requires approval before apply/run", null, 0, 0, false, "no hidden writes or execution");
            try appendEdge(allocator, edges, candidate_id, approval_id, .candidate_requires_approval);
        }
        if (candidate.status == .blocked) {
            const blocked_id = try std.fmt.allocPrint(allocator, "verifier_candidate_blocked_{d}", .{idx + 1});
            defer allocator.free(blocked_id);
            try appendNode(allocator, nodes, blocked_id, .verifier_candidate_safety_obligation, if (candidate.blocked_reason) |reason| candidateBlockedReasonName(reason) else "blocked", null, 0, 0, false, "candidate generation blocked before authorization");
            try appendEdge(allocator, edges, candidate_id, blocked_id, .candidate_blocked_by);
        }
        if (candidate.negative_knowledge_record_ids.len > 0) {
            const nk_id = try std.fmt.allocPrint(allocator, "negative_knowledge_verifier_candidate_influence_{d}", .{idx + 1});
            defer allocator.free(nk_id);
            try appendNode(allocator, nodes, nk_id, .negative_knowledge_influence, "negative knowledge verifier candidate influence", null, 0, @intCast(@min(candidate.negative_knowledge_record_ids.len, std.math.maxInt(u32))), false, "non-authorizing verifier candidate influence only");
            try appendEdge(allocator, edges, nk_id, candidate_id, .negative_knowledge_requires_verifier);
        }
    }
}

fn appendNode(
    allocator: std.mem.Allocator,
    nodes: *std.ArrayList(code_intel.SupportGraphNode),
    id: []const u8,
    kind: code_intel.SupportNodeKind,
    label: []const u8,
    rel_path: ?[]const u8,
    line: u32,
    score: u32,
    usable: bool,
    detail: ?[]const u8,
) !void {
    try nodes.append(.{
        .id = try allocator.dupe(u8, id),
        .kind = kind,
        .label = try allocator.dupe(u8, label),
        .rel_path = if (rel_path) |path| try allocator.dupe(u8, path) else null,
        .line = line,
        .score = score,
        .usable = usable,
        .detail = if (detail) |item| try allocator.dupe(u8, item) else null,
    });
}

fn appendEdge(
    allocator: std.mem.Allocator,
    edges: *std.ArrayList(code_intel.SupportGraphEdge),
    from_id: []const u8,
    to_id: []const u8,
    kind: code_intel.SupportEdgeKind,
) !void {
    try edges.append(.{
        .from_id = try allocator.dupe(u8, from_id),
        .to_id = try allocator.dupe(u8, to_id),
        .kind = kind,
    });
}

pub const MaterializationPolicy = struct {
    max_generated_bytes: usize = 1024 * 1024,
    allow_check_plan: bool = true,
    allow_file_proposal: bool = false,
    allow_patch_proposal: bool = false,
    allow_command_plan: bool = false,
    require_acceptance: bool = true,
};

pub fn acceptVerifierCandidate(candidate: *VerifierCandidate, approval: VerifierCandidateApproval) !void {
    if (candidate.status != .proposed) return error.InvalidStatus;
    if (candidate.approval) |*old| old.deinit(candidate.allocator);
    candidate.approval = approval;
    candidate.status = .accepted;
    const old_trace = candidate.trace;
    candidate.trace = try std.fmt.allocPrint(candidate.allocator, "accepted verifier candidate; approved_by={s}; kind={s}; {s}", .{ approval.approved_by, @tagName(approval.approval_kind), old_trace });
    candidate.allocator.free(old_trace);
}

pub fn rejectVerifierCandidate(candidate: *VerifierCandidate, reason: []const u8) !void {
    if (candidate.status != .proposed and candidate.status != .accepted) return error.InvalidStatus;
    if (candidate.rejection_reason) |old| candidate.allocator.free(old);
    candidate.rejection_reason = try candidate.allocator.dupe(u8, reason);
    candidate.status = .rejected;
    const old_trace = candidate.trace;
    candidate.trace = try std.fmt.allocPrint(candidate.allocator, "rejected verifier candidate; reason={s}; {s}", .{ reason, old_trace });
    candidate.allocator.free(old_trace);
}

pub fn materializeVerifierCandidate(
    allocator: std.mem.Allocator,
    candidate: *VerifierCandidate,
    policy: MaterializationPolicy,
) !void {
    if (policy.require_acceptance and candidate.status != .accepted) {
        candidate.status = .blocked;
        candidate.blocked_reason = .not_approved;
        const old_trace = candidate.trace;
        candidate.trace = try std.fmt.allocPrint(allocator, "materialization blocked because candidate is not accepted; {s}", .{old_trace});
        allocator.free(old_trace);
        return;
    }
    if (candidate.status != .proposed and candidate.status != .accepted) return error.InvalidStatus;

    if (!candidate.non_authorizing) {
        candidate.status = .blocked;
        candidate.blocked_reason = .unsafe_materialization;
        const old_trace = candidate.trace;
        candidate.trace = try std.fmt.allocPrint(allocator, "materialization blocked because candidate is authorizing; {s}", .{old_trace});
        allocator.free(old_trace);
        return;
    }

    var mat = VerifierCandidateMaterialization{
        .id = try std.fmt.allocPrint(allocator, "mat:{s}", .{candidate.id}),
        .candidate_id = try allocator.dupe(u8, candidate.id),
        .kind = .check_plan,
        .trace = try allocator.dupe(u8, "materialized from candidate proposal"),
    };
    errdefer mat.deinit(allocator);

    if (candidate.generated_artifacts.len > 0) {
        mat.generated_artifact_refs = try cloneStringList(allocator, candidate.generated_artifacts);
        if (mat.generated_artifact_refs.len > policy.max_generated_bytes / 1024) { // simplified cap
            return error.BudgetExhausted;
        }
    }

    if (candidate.patch_or_file_proposal) |p| {
        if (std.mem.startsWith(u8, p, "generated verifier candidate file proposal")) {
            if (policy.allow_file_proposal) {
                mat.kind = .file_proposal;
                mat.write_proposal_refs = try cloneStringList(allocator, &.{p});
            }
        } else {
            if (policy.allow_patch_proposal) {
                mat.kind = .patch_proposal;
                mat.patch_proposal_refs = try cloneStringList(allocator, &.{p});
            }
        }
    }

    if (candidate.command_plan) |plan| {
        if (policy.allow_command_plan) {
            mat.kind = .command_plan;
            mat.command_plan_refs = try cloneStringList(allocator, plan.argv);
        }
    }

    if (candidate.materialization) |*old| old.deinit(allocator);
    candidate.materialization = mat;
    candidate.status = .materialized;
    const old_trace = candidate.trace;
    candidate.trace = try std.fmt.allocPrint(allocator, "materialized verifier candidate; kind={s}; {s}", .{ @tagName(mat.kind), old_trace });
    allocator.free(old_trace);
}

pub fn renderHandoffJson(allocator: std.mem.Allocator, handoff: HandoffResult) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const writer = out.writer();
    try writer.writeAll("{\"hypothesis_verifier_handoff\":{");
    try writer.print("\"eligible_count\":{d},\"scheduled_count\":{d},\"completed_count\":{d},\"blocked_count\":{d},\"skipped_count\":{d},\"budget_exhausted_count\":{d}", .{
        handoff.eligible_count,
        handoff.scheduled_count,
        handoff.completed_count,
        handoff.blocked_count,
        handoff.skipped_count,
        handoff.budget_exhausted_count,
    });
    try writer.print(",\"negativeKnowledgeVerifierRequirementCount\":{d},\"negativeKnowledgeVerifierBlockedCount\":{d},\"negativeKnowledgeVerifierStrengthenedCount\":{d},\"items\":[", .{
        handoff.negative_knowledge_verifier_requirement_count,
        handoff.negative_knowledge_verifier_blocked_count,
        handoff.negative_knowledge_verifier_strengthened_count,
    });
    for (handoff.jobs, 0..) |job, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writer.writeAll("{");
        try writeJsonFieldString(writer, "id", job.id, true);
        try writeJsonFieldString(writer, "hypothesis_id", job.hypothesis_id, false);
        try writeJsonFieldString(writer, "adapter_id", job.adapter_id, false);
        try writeJsonFieldString(writer, "status", @tagName(job.status), false);
        try writer.writeAll(",\"negative_knowledge_record_ids\":");
        try writeJsonStringList(writer, job.negative_knowledge_record_ids);
        if (job.verifier_requirement) |value| try writeJsonFieldString(writer, "verifier_requirement", value, false);
        try writer.print(",\"blocked_by_negative_knowledge\":{s}", .{if (job.blocked_by_negative_knowledge) "true" else "false"});
        if (job.required_strength) |value| try writeJsonFieldString(writer, "required_strength", value, false);
        if (job.selected_adapter_after_nk) |value| try writeJsonFieldString(writer, "selected_adapter_after_nk", value, false);
        if (job.fallback_reason) |value| try writeJsonFieldString(writer, "fallback_reason", value, false);
        try writeJsonFieldString(writer, "trace", job.trace, false);
        try writer.writeAll("}");
    }
    try writer.writeAll("]");
    try writer.writeAll("},\"verifier_candidates\":{");
    try writer.print("\"proposed_count\":{d},\"blocked_count\":{d},\"accepted_count\":{d},\"materialized_count\":{d},\"scheduled_count\":{d},\"executed_count\":{d},\"budget_exhausted_count\":{d},\"items\":[", .{
        handoff.verifier_candidate_proposed_count,
        handoff.verifier_candidate_blocked_count,
        handoff.verifier_candidate_accepted_count,
        handoff.verifier_candidate_materialized_count,
        handoff.verifier_candidate_scheduled_count,
        handoff.verifier_candidate_executed_count,
        handoff.verifier_candidate_budget_exhausted_count,
    });
    for (handoff.verifier_candidates, 0..) |candidate, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writer.writeAll("{");
        try writeJsonFieldString(writer, "id", candidate.id, true);
        try writeJsonFieldString(writer, "hypothesis_id", candidate.hypothesis_id, false);
        try writeJsonFieldString(writer, "candidate_kind", candidateKindName(candidate.candidate_kind), false);
        try writeJsonFieldString(writer, "status", candidateStatusName(candidate.status), false);
        try writeJsonFieldString(writer, "artifact_scope", candidate.artifact_scope, false);
        try writeJsonFieldString(writer, "target_claim_surface", candidate.target_claim_surface, false);
        try writeJsonFieldString(writer, "proposed_check", candidate.proposed_check, false);
        try writer.writeAll(",\"expected_observations\":");
        try writeJsonStringList(writer, candidate.expected_observations);
        try writer.writeAll(",\"missing_obligations\":");
        try writeJsonStringList(writer, candidate.missing_obligations);
        try writer.writeAll(",\"safety_constraints\":");
        try writeJsonStringList(writer, candidate.safety_constraints);
        try writer.writeAll(",\"scope_limitations\":");
        try writeJsonStringList(writer, candidate.scope_limitations);
        try writer.writeAll(",\"generated_artifacts\":");
        try writeJsonStringList(writer, candidate.generated_artifacts);
        if (candidate.command_plan) |plan| {
            try writer.writeAll(",\"command_plan\":{\"argv\":");
            try writeJsonStringList(writer, plan.argv);
            try writer.print(",\"requires_approval\":{s}}}", .{if (plan.requires_approval) "true" else "false"});
        }
        if (candidate.patch_or_file_proposal) |proposal| try writeJsonFieldString(writer, "patch_or_file_proposal", proposal, false);
        if (candidate.blocked_reason) |reason| try writeJsonFieldString(writer, "blocked_reason", candidateBlockedReasonName(reason), false);
        if (candidate.rejection_reason) |reason| try writeJsonFieldString(writer, "rejection_reason", reason, false);
        try writer.writeAll(",\"negative_knowledge_record_ids\":");
        try writeJsonStringList(writer, candidate.negative_knowledge_record_ids);
        if (candidate.verifier_requirement) |value| try writeJsonFieldString(writer, "verifier_requirement", value, false);
        try writer.print(",\"blocked_by_negative_knowledge\":{s}", .{if (candidate.blocked_by_negative_knowledge) "true" else "false"});
        if (candidate.required_strength) |value| try writeJsonFieldString(writer, "required_strength", value, false);
        if (candidate.selected_adapter_after_nk) |value| try writeJsonFieldString(writer, "selected_adapter_after_nk", value, false);
        if (candidate.fallback_reason) |value| try writeJsonFieldString(writer, "fallback_reason", value, false);
        if (candidate.approval) |approval| {
            try writer.writeAll(",\"approval\":{");
            try writeJsonFieldString(writer, "approved_by", approval.approved_by, true);
            try writeJsonFieldString(writer, "approval_kind", @tagName(approval.approval_kind), false);
            try writeJsonFieldString(writer, "approval_reason", approval.approval_reason, false);
            try writer.print(",\"timestamp_ms\":{d}", .{approval.timestamp_ms});
            try writer.writeAll("}");
        }
        if (candidate.materialization) |mat| {
            try writer.writeAll(",\"materialization\":{");
            try writeJsonFieldString(writer, "id", mat.id, true);
            try writeJsonFieldString(writer, "kind", @tagName(mat.kind), false);
            try writer.writeAll(",\"generated_artifact_refs\":");
            try writeJsonStringList(writer, mat.generated_artifact_refs);
            try writer.writeAll("}");
        }
        try writer.print(",\"requires_approval\":{s},\"non_authorizing\":{s}", .{
            if (candidate.requires_approval) "true" else "false",
            if (candidate.non_authorizing) "true" else "false",
        });
        try writeJsonFieldString(writer, "provenance", candidate.provenance, false);
        try writeJsonFieldString(writer, "trace", candidate.trace, false);
        try writer.writeAll("}");
    }
    try writer.writeAll("]}}");
    return out.toOwnedSlice();
}

fn writeJsonFieldString(writer: anytype, field: []const u8, value: []const u8, first: bool) !void {
    if (!first) try writer.writeByte(',');
    try writeJsonString(writer, field);
    try writer.writeByte(':');
    try writeJsonString(writer, value);
}

fn writeJsonStringList(writer: anytype, items: [][]u8) !void {
    try writer.writeByte('[');
    for (items, 0..) |item, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writeJsonString(writer, item);
    }
    try writer.writeByte(']');
}

fn writeJsonString(writer: anytype, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |ch| {
        switch (ch) {
            '\\' => try writer.writeAll("\\\\"),
            '"' => try writer.writeAll("\\\""),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(ch),
        }
    }
    try writer.writeByte('"');
}

fn maybeAppendVerifierCandidate(
    allocator: std.mem.Allocator,
    result: *HandoffResult,
    candidates: *std.ArrayList(VerifierCandidate),
    hypothesis: hypothesis_core.Hypothesis,
    job: HandoffJob,
    handoff_reason: HandoffBlockedReason,
    budget: compute_budget.Effective,
    negative_records: []const negative_knowledge.Record,
) !void {
    if (!candidateEligibleHandoffReason(handoff_reason)) return;
    if (candidates.items.len >= budget.max_verifier_candidates_generated) {
        var blocked = try makeBlockedVerifierCandidate(allocator, hypothesis, job, .budget_exhausted, "verifier candidate generation budget exhausted before proposal");
        errdefer blocked.deinit();
        try candidates.append(blocked);
        result.verifier_candidate_blocked_count += 1;
        result.verifier_candidate_budget_exhausted_count += 1;
        return;
    }

    if (!boundArtifactScope(hypothesis.artifact_scope)) {
        var blocked = try makeBlockedVerifierCandidate(allocator, hypothesis, job, .unbound_scope, "verifier candidate blocked because artifact scope is unbound");
        errdefer blocked.deinit();
        try candidates.append(blocked);
        result.verifier_candidate_blocked_count += 1;
        return;
    }
    if (!provenanceBackedEvidence(hypothesis)) {
        var blocked = try makeBlockedVerifierCandidate(allocator, hypothesis, job, .insufficient_evidence, "verifier candidate blocked because evidence/provenance is insufficient");
        errdefer blocked.deinit();
        try candidates.append(blocked);
        result.verifier_candidate_blocked_count += 1;
        return;
    }
    if (hasContradictionBlocker(hypothesis)) {
        var blocked = try makeBlockedVerifierCandidate(allocator, hypothesis, job, .contradiction_blocker, "verifier candidate blocked by active contradiction blocker");
        errdefer blocked.deinit();
        try candidates.append(blocked);
        result.verifier_candidate_blocked_count += 1;
        return;
    }
    if (hasUnsafeSignal(hypothesis)) {
        var blocked = try makeBlockedVerifierCandidate(allocator, hypothesis, job, .unsafe_check, "verifier candidate blocked by unsafe or disallowed action surface");
        errdefer blocked.deinit();
        try candidates.append(blocked);
        result.verifier_candidate_blocked_count += 1;
        return;
    }
    if (!expectedObservationKnown(hypothesis)) {
        var blocked = try makeBlockedVerifierCandidate(allocator, hypothesis, job, .expected_observation_unknown, "verifier candidate blocked because expected observation cannot be stated");
        errdefer blocked.deinit();
        try candidates.append(blocked);
        result.verifier_candidate_blocked_count += 1;
        return;
    }
    if (candidateByteEstimate(hypothesis) > budget.max_verifier_candidate_bytes or hypothesis.missing_obligations.len > budget.max_verifier_candidate_obligations) {
        var blocked = try makeBlockedVerifierCandidate(allocator, hypothesis, job, .budget_exhausted, "verifier candidate obligation or byte budget exhausted");
        errdefer blocked.deinit();
        try candidates.append(blocked);
        result.verifier_candidate_blocked_count += 1;
        result.verifier_candidate_budget_exhausted_count += 1;
        return;
    }

    var candidate = try makeVerifierCandidate(allocator, hypothesis, job, handoff_reason, budget);
    errdefer candidate.deinit();
    try applyNegativeKnowledgeToVerifierCandidate(allocator, result, &candidate, negative_records, budget);
    try candidates.append(candidate);
    if (candidate.status == .blocked) {
        result.verifier_candidate_blocked_count += 1;
    } else {
        result.verifier_candidate_proposed_count += 1;
        if (candidate.generated_artifacts.len > 0) result.verifier_candidate_materialized_count += 1;
    }
    if (isCodeCandidate(candidate)) {
        result.code_verifier_candidate_count += 1;
    } else {
        result.non_code_verifier_candidate_count += 1;
    }
}

fn makeVerifierCandidate(
    allocator: std.mem.Allocator,
    hypothesis: hypothesis_core.Hypothesis,
    job: HandoffJob,
    handoff_reason: HandoffBlockedReason,
    budget: compute_budget.Effective,
) !VerifierCandidate {
    const kind = candidateKindForHypothesis(hypothesis);
    const materializable = canMaterializeCandidate(kind, hypothesis) and budget.max_verifier_candidate_artifacts > 0;
    const generated_artifacts = if (materializable) blk: {
        const items = try allocator.alloc([]u8, 1);
        items[0] = try proposedArtifactRef(allocator, hypothesis, kind);
        break :blk items;
    } else try cloneStringList(allocator, &.{});
    errdefer freeStringList(allocator, generated_artifacts);
    const patch_proposal = if (materializable)
        try proposedFilePatch(allocator, hypothesis, kind)
    else
        null;
    errdefer if (patch_proposal) |value| allocator.free(value);
    var command_plan: ?CommandPlan = if (materializable and budget.max_verifier_candidate_commands > 0 and safeCommandCandidate(kind))
        .{ .argv = try cloneStringList(allocator, &.{ "zig", "build", "test" }), .requires_approval = true }
    else
        null;
    errdefer if (command_plan) |*plan| plan.deinit(allocator);
    const expected = try expectedObservations(allocator, hypothesis, kind);
    errdefer freeStringList(allocator, expected);
    const limitations = try scopeLimitations(allocator, kind);
    errdefer freeStringList(allocator, limitations);
    const safety = try cloneStringList(allocator, &.{
        "requires approval before apply/run",
        "no hidden writes",
        "no hidden execution",
        "argv arrays only",
        "network denied by default",
        "sudo/system modification denied",
        "workspace writes only after approval",
        "not evidence until executed through verifier path",
    });
    errdefer freeStringList(allocator, safety);

    return .{
        .allocator = allocator,
        .id = try std.fmt.allocPrint(allocator, "verifier_candidate:{s}:{s}", .{ hypothesis.id, candidateKindName(kind) }),
        .hypothesis_id = try allocator.dupe(u8, hypothesis.id),
        .candidate_kind = kind,
        .artifact_scope = try allocator.dupe(u8, hypothesis.artifact_scope),
        .target_claim_surface = try targetClaimSurface(allocator, hypothesis),
        .proposed_check = try proposedCheck(allocator, hypothesis, kind),
        .required_inputs = try requiredInputs(allocator, hypothesis),
        .generated_artifacts = generated_artifacts,
        .command_plan = command_plan,
        .patch_or_file_proposal = patch_proposal,
        .expected_observations = expected,
        .safety_constraints = safety,
        .missing_obligations = try cloneStringList(allocator, hypothesis.missing_obligations),
        .scope_limitations = limitations,
        .status = .proposed,
        .requires_approval = true,
        .non_authorizing = true,
        .provenance = try std.fmt.allocPrint(allocator, "hypothesis_verifier_candidate_generation:{s}", .{@tagName(handoff_reason)}),
        .trace = try std.fmt.allocPrint(allocator, "proposed verifier candidate; check plan requires approval before apply/run; not evidence until executed; source_job={s}", .{job.id}),
    };
}

fn makeBlockedVerifierCandidate(
    allocator: std.mem.Allocator,
    hypothesis: hypothesis_core.Hypothesis,
    job: HandoffJob,
    reason: CandidateBlockedReason,
    trace: []const u8,
) !VerifierCandidate {
    const kind = candidateKindForHypothesis(hypothesis);
    return .{
        .allocator = allocator,
        .id = try std.fmt.allocPrint(allocator, "verifier_candidate_blocked:{s}:{s}", .{ hypothesis.id, candidateBlockedReasonName(reason) }),
        .hypothesis_id = try allocator.dupe(u8, hypothesis.id),
        .candidate_kind = kind,
        .artifact_scope = try allocator.dupe(u8, hypothesis.artifact_scope),
        .target_claim_surface = try targetClaimSurface(allocator, hypothesis),
        .proposed_check = try proposedCheck(allocator, hypothesis, kind),
        .required_inputs = try requiredInputs(allocator, hypothesis),
        .expected_observations = try cloneStringList(allocator, &.{}),
        .safety_constraints = try cloneStringList(allocator, &.{ "blocked before apply/run", "non-authorizing candidate only" }),
        .missing_obligations = try cloneStringList(allocator, hypothesis.missing_obligations),
        .scope_limitations = try scopeLimitations(allocator, kind),
        .status = .blocked,
        .blocked_reason = reason,
        .requires_approval = true,
        .non_authorizing = true,
        .provenance = try allocator.dupe(u8, "hypothesis_verifier_candidate_generation:blocked"),
        .trace = try std.fmt.allocPrint(allocator, "{s}; source_job={s}", .{ trace, job.id }),
    };
}

fn candidateEligibleHandoffReason(reason: HandoffBlockedReason) bool {
    _ = reason;
    return true;
}

fn candidateKindForHypothesis(hypothesis: hypothesis_core.Hypothesis) CandidateKind {
    if (std.mem.eql(u8, hypothesis.schema_name, "document_schema")) return .document_consistency_check;
    if (std.mem.eql(u8, hypothesis.schema_name, "config_schema")) return .config_validation_check;
    if (std.mem.eql(u8, hypothesis.schema_name, "code_artifact_schema")) {
        if (containsHypothesisSignal(hypothesis, "runtime")) return .runtime_probe;
        if (containsHypothesisSignal(hypothesis, "diff")) return .diff_check;
        if (containsHypothesisSignal(hypothesis, "invariant")) return .invariant_check;
        if (containsHypothesisSignal(hypothesis, "test")) return .regression_test;
        return .static_check;
    }
    if (containsHypothesisSignal(hypothesis, "schema")) return .schema_validation;
    if (containsHypothesisSignal(hypothesis, "diff")) return .diff_check;
    if (containsHypothesisSignal(hypothesis, "invariant")) return .invariant_check;
    if (containsHypothesisSignal(hypothesis, "consistency") or containsHypothesisSignal(hypothesis, "contradict")) return .consistency_check;
    return .generic_check_plan;
}

fn canMaterializeCandidate(kind: CandidateKind, hypothesis: hypothesis_core.Hypothesis) bool {
    if (std.mem.eql(u8, hypothesis.schema_name, "document_schema")) return false;
    return switch (kind) {
        .regression_test, .schema_validation, .config_validation_check, .static_check, .invariant_check, .diff_check, .runtime_probe => true,
        .consistency_check, .document_consistency_check, .generic_check_plan => false,
    };
}

fn safeCommandCandidate(kind: CandidateKind) bool {
    return switch (kind) {
        .regression_test, .static_check, .invariant_check => true,
        else => false,
    };
}

fn expectedObservationKnown(hypothesis: hypothesis_core.Hypothesis) bool {
    if (containsHypothesisSignal(hypothesis, "expected_observation_unknown")) return false;
    return hypothesis.evidence_fragments.len > 0 or hypothesis.missing_obligations.len > 0 or hypothesis.affected_entities.len > 0;
}

fn candidateByteEstimate(hypothesis: hypothesis_core.Hypothesis) usize {
    var total: usize = hypothesis.id.len + hypothesis.artifact_scope.len + hypothesis.schema_name.len + hypothesis.suggested_action_surface.len + hypothesis.provenance.len + hypothesis.trace.len;
    for (hypothesis.evidence_fragments) |item| total += item.len;
    for (hypothesis.missing_obligations) |item| total += item.len;
    for (hypothesis.affected_entities) |item| total += item.len;
    for (hypothesis.involved_relations) |item| total += item.len;
    return total + 512;
}

fn targetClaimSurface(allocator: std.mem.Allocator, hypothesis: hypothesis_core.Hypothesis) ![]u8 {
    if (hypothesis.affected_entities.len > 0) {
        return std.fmt.allocPrint(allocator, "{s}::{s}", .{ hypothesis.artifact_scope, hypothesis.affected_entities[0] });
    }
    return allocator.dupe(u8, hypothesis.artifact_scope);
}

fn proposedCheck(allocator: std.mem.Allocator, hypothesis: hypothesis_core.Hypothesis, kind: CandidateKind) ![]u8 {
    const obligation = firstObligation(hypothesis) orelse hypothesis.suggested_action_surface;
    return std.fmt.allocPrint(
        allocator,
        "Check {s} for {s} on {s}; proposed verifier candidate, not evidence until executed",
        .{ obligation, candidateKindName(kind), hypothesis.artifact_scope },
    );
}

fn expectedObservations(allocator: std.mem.Allocator, hypothesis: hypothesis_core.Hypothesis, kind: CandidateKind) ![][]u8 {
    const first = try std.fmt.allocPrint(allocator, "bounded {s} reports pass/fail/block for {s}", .{ candidateKindName(kind), hypothesis.artifact_scope });
    defer allocator.free(first);
    return cloneStringList(allocator, &.{
        first,
        "result enters evidence only through existing verifier adapter/result path",
    });
}

fn requiredInputs(allocator: std.mem.Allocator, hypothesis: hypothesis_core.Hypothesis) ![][]u8 {
    var items = std.ArrayList([]const u8).init(allocator);
    defer items.deinit();
    try items.append(hypothesis.artifact_scope);
    if (hypothesis.evidence_fragments.len > 0) try items.append(hypothesis.evidence_fragments[0]);
    if (hypothesis.missing_obligations.len > 0) try items.append(hypothesis.missing_obligations[0]);
    return cloneStringList(allocator, items.items);
}

fn scopeLimitations(allocator: std.mem.Allocator, kind: CandidateKind) ![][]u8 {
    const first = try std.fmt.allocPrint(allocator, "does not check final support/proof gate for {s}", .{candidateKindName(kind)});
    defer allocator.free(first);
    return cloneStringList(allocator, &.{
        first,
        "does not authorize support",
        "does not execute or write without approval",
    });
}

fn proposedArtifactRef(allocator: std.mem.Allocator, hypothesis: hypothesis_core.Hypothesis, kind: CandidateKind) ![]u8 {
    const id = try sanitizeId(allocator, hypothesis.id);
    defer allocator.free(id);
    return std.fmt.allocPrint(allocator, "generated/verifier_candidates/{s}.{s}.check", .{ id, candidateKindName(kind) });
}

fn proposedFilePatch(allocator: std.mem.Allocator, hypothesis: hypothesis_core.Hypothesis, kind: CandidateKind) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "generated verifier candidate file proposal only\nkind={s}\nhypothesis_id={s}\nartifact_scope={s}\nassumptions=artifact scope remains bound; verifier result must enter adapter evidence path\nnon_authorizing=true\n",
        .{ candidateKindName(kind), hypothesis.id, hypothesis.artifact_scope },
    );
}

fn sanitizeId(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    const out = try allocator.dupe(u8, value);
    for (out) |*ch| {
        if (!std.ascii.isAlphanumeric(ch.*)) ch.* = '_';
    }
    return out;
}

fn isCodeCandidate(candidate: VerifierCandidate) bool {
    return std.mem.indexOf(u8, candidate.artifact_scope, ".zig") != null or
        std.mem.indexOf(u8, candidate.artifact_scope, "src/") != null or
        candidate.candidate_kind == .regression_test or
        candidate.candidate_kind == .static_check or
        candidate.candidate_kind == .runtime_probe;
}

fn makeBlockedHandoffJob(
    allocator: std.mem.Allocator,
    hypothesis: hypothesis_core.Hypothesis,
    hook: []const u8,
    adapter_id: ?[]const u8,
    reason: HandoffBlockedReason,
    trace: []const u8,
) !HandoffJob {
    var job = try makeBaseHandoffJob(allocator, hypothesis, hook, adapter_id orelse "none", 0, trace);
    job.status = if (reason == .budget_exhausted) .budget_exhausted else .blocked;
    job.blocked_reason = reason;
    return job;
}

fn makeScheduledHandoffJob(
    allocator: std.mem.Allocator,
    hypothesis: hypothesis_core.Hypothesis,
    adapter: Adapter,
    status: HandoffJobStatus,
    trace: []const u8,
) !HandoffJob {
    var job = try makeBaseHandoffJob(allocator, hypothesis, @tagName(adapter.hook_kind), adapter.id, adapter.budget_cost, trace);
    job.status = status;
    return job;
}

fn makeBaseHandoffJob(
    allocator: std.mem.Allocator,
    hypothesis: hypothesis_core.Hypothesis,
    hook: []const u8,
    adapter_id: []const u8,
    budget_cost: u32,
    trace: []const u8,
) !HandoffJob {
    return .{
        .allocator = allocator,
        .id = try std.fmt.allocPrint(allocator, "hypothesis_verifier_job:{s}:{s}", .{ hypothesis.id, hook }),
        .hypothesis_id = try allocator.dupe(u8, hypothesis.id),
        .verifier_hook_kind = try allocator.dupe(u8, hook),
        .adapter_id = try allocator.dupe(u8, adapter_id),
        .artifact_scope = try allocator.dupe(u8, hypothesis.artifact_scope),
        .required_entities = try cloneStringList(allocator, hypothesis.affected_entities),
        .required_relations = try cloneStringList(allocator, hypothesis.involved_relations),
        .required_obligations = try cloneStringList(allocator, hypothesis.missing_obligations),
        .input_evidence_refs = try cloneStringList(allocator, hypothesis.evidence_fragments),
        .budget_cost = budget_cost,
        .trace = try allocator.dupe(u8, trace),
    };
}

fn setJobResult(allocator: std.mem.Allocator, job: *HandoffJob, status: Status, evidence: ?[]const u8, result_ref: []const u8) !void {
    job.result_status = status;
    if (job.result_ref) |value| allocator.free(value);
    job.result_ref = try allocator.dupe(u8, result_ref);
    if (evidence) |value| {
        if (job.evidence_ref) |old| allocator.free(old);
        job.evidence_ref = try allocator.dupe(u8, value);
    }
}

fn parseHookKind(value: []const u8) ?HookKind {
    if (std.mem.eql(u8, value, "build")) return .build;
    if (std.mem.eql(u8, value, "test")) return .@"test";
    if (std.mem.eql(u8, value, "runtime")) return .runtime;
    if (std.mem.eql(u8, value, "schema_validation")) return .schema_validation;
    if (std.mem.eql(u8, value, "consistency_check")) return .consistency_check;
    if (std.mem.eql(u8, value, "freshness_check")) return .freshness_check;
    if (std.mem.eql(u8, value, "citation_check")) return .citation_check;
    if (std.mem.eql(u8, value, "unit_consistency")) return .unit_consistency;
    if (std.mem.eql(u8, value, "constraint_check")) return .constraint_check;
    if (std.mem.eql(u8, value, "custom_external")) return .custom_external;
    return null;
}

fn modeAllowsAdapter(mode: HandoffMode, adapter: Adapter) bool {
    return switch (mode) {
        .draft => false,
        .fast => adapter.budget_cost <= 1 and !isExternal(adapter.hook_kind),
        .deep => true,
        .auto => adapter.budget_cost <= 1 and !isExternal(adapter.hook_kind),
    };
}

fn boundArtifactScope(scope: []const u8) bool {
    return scope.len > 0 and
        !std.mem.eql(u8, scope, "unknown") and
        !std.mem.eql(u8, scope, "unbound") and
        std.mem.indexOf(u8, scope, "unbound") == null;
}

fn provenanceBackedEvidence(hypothesis: hypothesis_core.Hypothesis) bool {
    return hypothesis.evidence_fragments.len > 0 and
        hypothesis.provenance.len > 0 and
        std.mem.indexOf(u8, hypothesis.provenance, "fallback") == null;
}

fn hasContradictionBlocker(hypothesis: hypothesis_core.Hypothesis) bool {
    return containsHypothesisSignal(hypothesis, "contradiction_blocker");
}

fn hasUnsafeSignal(hypothesis: hypothesis_core.Hypothesis) bool {
    return containsHypothesisSignal(hypothesis, "unsafe") or
        containsHypothesisSignal(hypothesis, "disallowed") or
        containsHypothesisSignal(hypothesis, "exploit") or
        containsHypothesisSignal(hypothesis, "offensive");
}

fn containsHypothesisSignal(hypothesis: hypothesis_core.Hypothesis, needle: []const u8) bool {
    if (std.mem.indexOf(u8, hypothesis.source_rule, needle) != null) return true;
    if (std.mem.indexOf(u8, hypothesis.provenance, needle) != null) return true;
    if (std.mem.indexOf(u8, hypothesis.trace, needle) != null) return true;
    for (hypothesis.source_signals) |signal| {
        if (std.mem.indexOf(u8, signal, needle) != null) return true;
    }
    for (hypothesis.evidence_fragments) |fragment| {
        if (std.mem.indexOf(u8, fragment, needle) != null) return true;
    }
    return false;
}

fn firstObligation(hypothesis: hypothesis_core.Hypothesis) ?[]const u8 {
    if (hypothesis.missing_obligations.len == 0) return null;
    return hypothesis.missing_obligations[0];
}

fn countArtifactJobs(items: []const ArtifactCounter, scope: []const u8) usize {
    for (items) |item| {
        if (std.mem.eql(u8, item.scope, scope)) return item.count;
    }
    return 0;
}

fn incrementArtifactJobs(allocator: std.mem.Allocator, items: *std.ArrayList(ArtifactCounter), scope: []const u8) !void {
    for (items.items) |*item| {
        if (std.mem.eql(u8, item.scope, scope)) {
            item.count += 1;
            return;
        }
    }
    _ = allocator;
    try items.append(.{ .scope = scope, .count = 1 });
}

fn freeStringList(allocator: std.mem.Allocator, items: [][]u8) void {
    for (items) |item| allocator.free(item);
    if (items.len != 0) allocator.free(items);
}

pub fn hookKindName(kind: HookKind) []const u8 {
    return @tagName(kind);
}

pub fn statusName(status: Status) []const u8 {
    return @tagName(status);
}

pub fn evidenceKindName(kind: EvidenceKind) []const u8 {
    return @tagName(kind);
}

pub fn candidateKindName(kind: CandidateKind) []const u8 {
    return @tagName(kind);
}

pub fn candidateStatusName(status: CandidateStatus) []const u8 {
    return @tagName(status);
}

pub fn candidateBlockedReasonName(reason: CandidateBlockedReason) []const u8 {
    return @tagName(reason);
}

test "registry selects adapters and detects missing verifier obligations" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();
    try registerBuiltinAdapters(&registry);
    try std.testing.expect(registry.lookup("code_artifact_schema", .build, "build") != null);
    try std.testing.expect(registry.missingVerifierObligation("config_schema", .schema_validation, "runtime"));
    const adapters = try registry.listApplicable(allocator, "document_schema", null);
    defer allocator.free(adapters);
    try std.testing.expect(adapters.len >= 2);
}

test "passed verifier evidence enters graph without direct support authorization" {
    const allocator = std.testing.allocator;
    var tracker = BudgetTracker.init(allocator, compute_budget.resolve(.{ .tier = .medium }));
    const artifact = artifact_schema.Artifact{
        .id = "cfg",
        .source = .user,
        .artifact_type = .file,
        .format_hint = "toml",
        .provenance = "test",
        .trust_class = .project,
        .content_path = null,
        .schema_name = "config_schema",
    };
    const entities = [_]artifact_schema.Entity{
        .{ .id = "key", .entity_type = "key", .fragment_index = 0, .label = "port", .provenance = "test", .artifact_id = "cfg" },
        .{ .id = "value", .entity_type = "value", .fragment_index = 0, .label = "3000", .provenance = "test", .artifact_id = "cfg" },
    };
    var result = try run(allocator, &tracker, .{
        .adapter = configSchemaValidationAdapter(),
        .artifact = &artifact,
        .entities = &entities,
    });
    defer result.deinit();
    try std.testing.expectEqual(Status.passed, result.status);
    try std.testing.expectEqual(@as(usize, 1), result.obligations_discharged.len);

    var nodes = std.ArrayList(code_intel.SupportGraphNode).init(allocator);
    defer {
        for (nodes.items) |node| {
            allocator.free(node.id);
            allocator.free(node.label);
            if (node.rel_path) |path| allocator.free(path);
            if (node.detail) |detail| allocator.free(detail);
        }
        nodes.deinit();
    }
    var edges = std.ArrayList(code_intel.SupportGraphEdge).init(allocator);
    defer {
        for (edges.items) |edge| {
            allocator.free(edge.from_id);
            allocator.free(edge.to_id);
        }
        edges.deinit();
    }
    try appendResultToSupportGraph(allocator, &nodes, &edges, "output", result, 1);
    try std.testing.expect(nodes.items.len >= 3);
    try std.testing.expectEqual(code_intel.SupportNodeKind.verifier_adapter, nodes.items[0].kind);
    try std.testing.expect(!nodes.items[0].usable);
    try std.testing.expectEqual(code_intel.SupportNodeKind.verifier_evidence, nodes.items[2].kind);
    try std.testing.expect(edges.items.len >= 4);
}

test "failed verifier creates blocking failure evidence" {
    const allocator = std.testing.allocator;
    var tracker = BudgetTracker.init(allocator, compute_budget.resolve(.{ .tier = .medium }));
    const relation = artifact_schema.RelationEdge{
        .relation = .contradicts,
        .from_entity_id = "a",
        .to_entity_id = "b",
        .provenance = "test",
    };
    var result = try run(allocator, &tracker, .{
        .adapter = genericConsistencyCheckAdapter(),
        .relations = &.{relation},
    });
    defer result.deinit();
    try std.testing.expectEqual(Status.failed, result.status);
    try std.testing.expect(result.failure_signal != null);
    try std.testing.expectEqual(@as(usize, 1), result.obligations_remaining.len);
}

test "verifier budget exhaustion is explicit" {
    const allocator = std.testing.allocator;
    var tracker = BudgetTracker.init(allocator, compute_budget.resolve(.{
        .tier = .medium,
        .overrides = .{ .max_verifier_runs = 0 },
    }));
    var result = try run(allocator, &tracker, .{
        .adapter = configSchemaValidationAdapter(),
        .provenance = "budget-test",
    });
    defer result.deinit();
    try std.testing.expectEqual(Status.budget_exhausted, result.status);
    try std.testing.expect(result.budget_exhaustion != null);
    try std.testing.expectEqual(compute_budget.Limit.max_verifier_runs, result.budget_exhaustion.?.limit);
}

test "code execution verifier result is adapter traceable" {
    const allocator = std.testing.allocator;
    var capture = execution.Result{
        .label = try allocator.dupe(u8, "zig_build"),
        .kind = .zig_build,
        .phase = .build,
        .command = try allocator.dupe(u8, "zig build"),
        .exit_code = 0,
        .duration_ms = 7,
        .stdout = try allocator.dupe(u8, ""),
        .stderr = try allocator.dupe(u8, ""),
    };
    defer capture.deinit(allocator);
    var result = try fromExecutionCapture(allocator, codeBuildAdapter(), &capture, &.{"build"}, "execution_harness");
    defer result.deinit();
    try std.testing.expectEqual(Status.passed, result.status);
    try std.testing.expect(std.mem.eql(u8, result.adapter_id, "code.build.zig_build"));
    try std.testing.expectEqual(EvidenceKind.build_log, result.evidence_kind);
}

test "document citation and freshness checks use the same adapter interface" {
    const allocator = std.testing.allocator;
    var tracker = BudgetTracker.init(allocator, compute_budget.resolve(.{ .tier = .medium }));
    const link = artifact_schema.Entity{ .id = "link", .entity_type = "link", .fragment_index = 0, .label = "https://example.test", .provenance = "test", .artifact_id = "doc" };
    var citation = try run(allocator, &tracker, .{
        .adapter = documentCitationCheckAdapter(),
        .entities = &.{link},
    });
    defer citation.deinit();
    try std.testing.expectEqual(Status.passed, citation.status);

    const stale_fragment = artifact_schema.Fragment{
        .artifact_id = "doc",
        .offset = 0,
        .line = 1,
        .region = "line 1",
        .parser_stage = .strict,
        .raw_text = "this section is stale",
        .provenance = "test",
    };
    var freshness = try run(allocator, &tracker, .{
        .adapter = documentFreshnessCheckAdapter(),
        .fragments = &.{stale_fragment},
    });
    defer freshness.deinit();
    try std.testing.expectEqual(Status.failed, freshness.status);
}

fn testHypothesis(allocator: std.mem.Allocator, schema: []const u8, scope: []const u8, hook: []const u8, signal: []const u8) !hypothesis_core.Hypothesis {
    var hooks = try allocator.alloc([]const u8, if (hook.len == 0) 0 else 1);
    errdefer allocator.free(hooks);
    if (hook.len > 0) hooks[0] = hook;
    var signals = try allocator.alloc([]const u8, 1);
    signals[0] = signal;
    return .{
        .id = "hyp-test",
        .artifact_scope = scope,
        .schema_name = schema,
        .hypothesis_kind = .possible_missing_obligation,
        .affected_entities = &.{"target"},
        .involved_relations = &.{"contains"},
        .evidence_fragments = &.{"evidence:provenance-backed"},
        .missing_obligations = &.{"bounded_check"},
        .suggested_action_surface = "check",
        .verifier_hooks_needed = hooks,
        .source_rule = "verifier_gap",
        .source_signals = signals,
        .support_potential = .medium,
        .risk_or_value_level = .medium,
        .status = .selected_for_verification,
        .non_authorizing = true,
        .provenance = "test_provenance",
        .trace = "selected hypothesis for verifier candidate tests",
    };
}

fn deinitTestHypothesis(allocator: std.mem.Allocator, hypothesis: *const hypothesis_core.Hypothesis) void {
    allocator.free(hypothesis.verifier_hooks_needed);
    allocator.free(hypothesis.source_signals);
}

fn selectedTriage() !hypothesis_core.TriageResult {
    const items = try std.heap.page_allocator.alloc(hypothesis_core.TriageItem, 1);
    items[0] = .{
        .hypothesis_id = "hyp-test",
        .rank = 1,
        .triage_status = .selected,
        .score = 10,
        .selected_for_next_stage = true,
        .trace = "selected",
    };
    return .{
        .allocator = std.heap.page_allocator,
        .total = 1,
        .selected = 1,
        .hypotheses_scored = 1,
        .hypotheses_selected = 1,
        .items = items,
    };
}

fn nonSelectedTriage() !hypothesis_core.TriageResult {
    const items = try std.heap.page_allocator.alloc(hypothesis_core.TriageItem, 1);
    items[0] = .{
        .hypothesis_id = "hyp-test",
        .rank = 1,
        .triage_status = .deferred,
        .score = 10,
        .selected_for_next_stage = false,
        .trace = "deferred",
    };
    return .{
        .allocator = std.heap.page_allocator,
        .total = 1,
        .deferred = 1,
        .hypotheses_scored = 1,
        .items = items,
    };
}

fn acceptedNkRecord(
    allocator: std.mem.Allocator,
    id: []const u8,
    kind: negative_knowledge.Kind,
    condition: []const u8,
    verifier_requirement: ?[]const u8,
) !negative_knowledge.Record {
    const influences = [_]negative_knowledge.AllowedInfluence{ .verifier_requirement, .suppression_rule, .triage_penalty };
    return negative_knowledge.acceptNegativeKnowledgeCandidate(allocator, .{
        .id = id,
        .correction_event_id = "corr:nk-verifier",
        .kind = kind,
        .scope = .artifact,
        .condition = condition,
        .evidence_ref = "ev:nk-verifier",
        .verifier_requirement = verifier_requirement,
    }, .{
        .approved_by = "test",
        .approval_kind = .test_fixture,
        .reason = "verified negative verifier influence fixture",
        .scope = .artifact,
        .allowed_influence = &influences,
    });
}

fn strongCodeBuildAdapter() Adapter {
    var adapter = codeBuildAdapter();
    adapter.id = "code.build.strong";
    adapter.required_obligations = &.{"strong_build"};
    adapter.budget_cost = 6;
    return adapter;
}

fn strongConfigSchemaAdapter() Adapter {
    var adapter = configSchemaValidationAdapter();
    adapter.id = "config.schema.strong_validation";
    adapter.required_obligations = &.{"strong_schema_check"};
    adapter.budget_cost = 2;
    return adapter;
}

test "selected hypothesis blocked by no matching adapter creates verifier candidate" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();
    try registerBuiltinAdapters(&registry);
    var tracker = BudgetTracker.init(allocator, compute_budget.resolve(.{ .tier = .medium }));
    var hypothesis = try testHypothesis(allocator, "document_schema", "docs/runbook.md", "unit_consistency", "document_consistency");
    defer deinitTestHypothesis(allocator, &hypothesis);
    var handoff = try handoffSelectedHypotheses(allocator, &registry, &tracker, &.{hypothesis}, try selectedTriage(), .{}, .deep);
    defer handoff.deinit();
    try std.testing.expectEqual(@as(usize, 1), handoff.blocked_count);
    try std.testing.expectEqual(@as(usize, 1), handoff.verifier_candidate_proposed_count);
    try std.testing.expectEqual(CandidateKind.document_consistency_check, handoff.verifier_candidates[0].candidate_kind);
    try std.testing.expect(handoff.verifier_candidates[0].non_authorizing);
}

test "accepted failed patch requires stronger verifier during handoff" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();
    try registry.register(codeBuildAdapter());
    try registry.register(strongCodeBuildAdapter());
    var tracker = BudgetTracker.init(allocator, compute_budget.resolve(.{ .tier = .max }));
    var hypothesis = try testHypothesis(allocator, "code_artifact_schema", "src/api.zig", "build", "build");
    defer deinitTestHypothesis(allocator, &hypothesis);
    var record = try acceptedNkRecord(allocator, "cand:nk-strong-build", .failed_patch, "src/api.zig", "strong_build");
    defer record.deinit();

    var handoff = try handoffSelectedHypotheses(allocator, &registry, &tracker, &.{hypothesis}, try selectedTriage(), .{ .negative_knowledge_records = &.{record} }, .deep);
    defer handoff.deinit();

    try std.testing.expectEqual(@as(usize, 1), handoff.negative_knowledge_verifier_requirement_count);
    try std.testing.expectEqual(@as(usize, 1), handoff.negative_knowledge_verifier_strengthened_count);
    try std.testing.expectEqualStrings("code.build.strong", handoff.jobs[0].adapter_id);
    try std.testing.expectEqualStrings("strong_build", handoff.jobs[0].required_strength.?);
    try std.testing.expect(handoff.jobs[0].negative_knowledge_record_ids.len == 1);
}

test "rejected and expired records do not affect verifier handoff" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();
    try registry.register(codeBuildAdapter());
    try registry.register(strongCodeBuildAdapter());
    var tracker = BudgetTracker.init(allocator, compute_budget.resolve(.{ .tier = .max }));
    var hypothesis = try testHypothesis(allocator, "code_artifact_schema", "src/api.zig", "build", "build");
    defer deinitTestHypothesis(allocator, &hypothesis);
    var rejected = try acceptedNkRecord(allocator, "cand:nk-rejected", .failed_patch, "src/api.zig", "strong_build");
    defer rejected.deinit();
    rejected.status = .rejected;
    var expired = try acceptedNkRecord(allocator, "cand:nk-expired", .failed_patch, "src/api.zig", "strong_build");
    defer expired.deinit();
    expired.status = .expired;

    var handoff = try handoffSelectedHypotheses(allocator, &registry, &tracker, &.{hypothesis}, try selectedTriage(), .{ .negative_knowledge_records = &.{ rejected, expired } }, .deep);
    defer handoff.deinit();

    try std.testing.expectEqual(@as(usize, 0), handoff.negative_knowledge_verifier_requirement_count);
    try std.testing.expectEqualStrings("code.build.zig_build", handoff.jobs[0].adapter_id);
    try std.testing.expect(handoff.jobs[0].negative_knowledge_record_ids.len == 0);
}

test "exact unsafe verifier reuse is blocked during handoff" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();
    try registry.register(codeBuildAdapter());
    var tracker = BudgetTracker.init(allocator, compute_budget.resolve(.{ .tier = .max }));
    var hypothesis = try testHypothesis(allocator, "code_artifact_schema", "src/api.zig", "build", "build");
    defer deinitTestHypothesis(allocator, &hypothesis);
    var record = try acceptedNkRecord(allocator, "cand:nk-unsafe-adapter", .unsafe_verifier_candidate, "code.build.zig_build", "strong_build");
    defer record.deinit();

    var handoff = try handoffSelectedHypotheses(allocator, &registry, &tracker, &.{hypothesis}, try selectedTriage(), .{ .negative_knowledge_records = &.{record} }, .deep);
    defer handoff.deinit();

    try std.testing.expectEqual(HandoffJobStatus.blocked, handoff.jobs[0].status);
    try std.testing.expectEqual(HandoffBlockedReason.blocked_by_negative_knowledge, handoff.jobs[0].blocked_reason.?);
    try std.testing.expect(handoff.jobs[0].blocked_by_negative_knowledge);
    try std.testing.expectEqual(@as(usize, 1), handoff.negative_knowledge_verifier_blocked_count);
}

test "missing stronger verifier produces explicit blocked handoff reason" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();
    try registry.register(codeBuildAdapter());
    var tracker = BudgetTracker.init(allocator, compute_budget.resolve(.{ .tier = .max }));
    var hypothesis = try testHypothesis(allocator, "code_artifact_schema", "src/api.zig", "build", "build");
    defer deinitTestHypothesis(allocator, &hypothesis);
    var record = try acceptedNkRecord(allocator, "cand:nk-missing-strong", .failed_patch, "src/api.zig", "strong_build");
    defer record.deinit();

    var handoff = try handoffSelectedHypotheses(allocator, &registry, &tracker, &.{hypothesis}, try selectedTriage(), .{ .negative_knowledge_records = &.{record} }, .deep);
    defer handoff.deinit();

    try std.testing.expectEqual(HandoffJobStatus.blocked, handoff.jobs[0].status);
    try std.testing.expectEqual(HandoffBlockedReason.no_adapter_satisfies_negative_knowledge, handoff.jobs[0].blocked_reason.?);
    try std.testing.expectEqualStrings("strong_build", handoff.jobs[0].verifier_requirement.?);
    try std.testing.expect(std.mem.indexOf(u8, handoff.jobs[0].fallback_reason.?, "no_adapter_satisfies_negative_knowledge") != null);
}

test "non-code verifier handoff uses same negative knowledge influence model" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();
    try registry.register(configSchemaValidationAdapter());
    try registry.register(strongConfigSchemaAdapter());
    var tracker = BudgetTracker.init(allocator, compute_budget.resolve(.{ .tier = .max }));
    var hypothesis = try testHypothesis(allocator, "config_schema", "config/app.toml", "schema_validation", "schema");
    defer deinitTestHypothesis(allocator, &hypothesis);
    var record = try acceptedNkRecord(allocator, "cand:nk-config-strong", .failed_patch, "config/app.toml", "strong_schema_check");
    defer record.deinit();

    var handoff = try handoffSelectedHypotheses(allocator, &registry, &tracker, &.{hypothesis}, try selectedTriage(), .{ .negative_knowledge_records = &.{record} }, .deep);
    defer handoff.deinit();

    try std.testing.expectEqualStrings("config.schema.strong_validation", handoff.jobs[0].adapter_id);
    try std.testing.expectEqual(@as(usize, 1), handoff.non_code_job_count);
    try std.testing.expectEqual(@as(usize, 1), handoff.negative_knowledge_verifier_strengthened_count);
}

test "negative knowledge verifier trace is emitted without support edges" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();
    try registry.register(codeBuildAdapter());
    try registry.register(strongCodeBuildAdapter());
    var tracker = BudgetTracker.init(allocator, compute_budget.resolve(.{ .tier = .max }));
    var hypothesis = try testHypothesis(allocator, "code_artifact_schema", "src/api.zig", "build", "build");
    defer deinitTestHypothesis(allocator, &hypothesis);
    var record = try acceptedNkRecord(allocator, "cand:nk-trace", .failed_patch, "src/api.zig", "strong_build");
    defer record.deinit();
    var handoff = try handoffSelectedHypotheses(allocator, &registry, &tracker, &.{hypothesis}, try selectedTriage(), .{ .negative_knowledge_records = &.{record} }, .deep);
    defer handoff.deinit();

    var nodes = std.ArrayList(code_intel.SupportGraphNode).init(allocator);
    defer {
        for (nodes.items) |node| {
            allocator.free(node.id);
            allocator.free(node.label);
            if (node.rel_path) |path| allocator.free(path);
            if (node.detail) |detail| allocator.free(detail);
        }
        nodes.deinit();
    }
    var edges = std.ArrayList(code_intel.SupportGraphEdge).init(allocator);
    defer {
        for (edges.items) |edge| {
            allocator.free(edge.from_id);
            allocator.free(edge.to_id);
        }
        edges.deinit();
    }
    try appendHandoffToSupportGraph(allocator, &nodes, &edges, "output", handoff);
    var saw_nk = false;
    for (nodes.items) |node| {
        if (node.kind == .negative_knowledge_influence) saw_nk = true;
        try std.testing.expect(!node.usable or node.kind != .negative_knowledge_influence);
    }
    for (edges.items) |edge| try std.testing.expect(edge.kind != .supported_by);
    try std.testing.expect(saw_nk);
}

test "negative knowledge verifier handoff behavior is deterministic" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();
    try registry.register(codeBuildAdapter());
    try registry.register(strongCodeBuildAdapter());
    var hypothesis = try testHypothesis(allocator, "code_artifact_schema", "src/api.zig", "build", "build");
    defer deinitTestHypothesis(allocator, &hypothesis);
    var record = try acceptedNkRecord(allocator, "cand:nk-deterministic", .failed_patch, "src/api.zig", "strong_build");
    defer record.deinit();
    var tracker_a = BudgetTracker.init(allocator, compute_budget.resolve(.{ .tier = .max }));
    var tracker_b = BudgetTracker.init(allocator, compute_budget.resolve(.{ .tier = .max }));

    var first = try handoffSelectedHypotheses(allocator, &registry, &tracker_a, &.{hypothesis}, try selectedTriage(), .{ .negative_knowledge_records = &.{record} }, .deep);
    defer first.deinit();
    var second = try handoffSelectedHypotheses(allocator, &registry, &tracker_b, &.{hypothesis}, try selectedTriage(), .{ .negative_knowledge_records = &.{record} }, .deep);
    defer second.deinit();

    try std.testing.expectEqualStrings(first.jobs[0].adapter_id, second.jobs[0].adapter_id);
    try std.testing.expectEqual(first.negative_knowledge_verifier_strengthened_count, second.negative_knowledge_verifier_strengthened_count);
    try std.testing.expectEqual(first.jobs[0].negative_knowledge_record_ids.len, second.jobs[0].negative_knowledge_record_ids.len);
}

test "non-selected hypothesis does not create verifier candidate" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();
    var tracker = BudgetTracker.init(allocator, compute_budget.resolve(.{ .tier = .medium }));
    var hypothesis = try testHypothesis(allocator, "document_schema", "docs/runbook.md", "unit_consistency", "document_consistency");
    defer deinitTestHypothesis(allocator, &hypothesis);
    var handoff = try handoffSelectedHypotheses(allocator, &registry, &tracker, &.{hypothesis}, try nonSelectedTriage(), .{}, .deep);
    defer handoff.deinit();
    try std.testing.expectEqual(@as(usize, 0), handoff.verifier_candidates.len);
}

test "unbound artifact scope blocks verifier candidate generation" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();
    var tracker = BudgetTracker.init(allocator, compute_budget.resolve(.{ .tier = .medium }));
    var hypothesis = try testHypothesis(allocator, "document_schema", "unbound", "unit_consistency", "document_consistency");
    defer deinitTestHypothesis(allocator, &hypothesis);
    var handoff = try handoffSelectedHypotheses(allocator, &registry, &tracker, &.{hypothesis}, try selectedTriage(), .{}, .deep);
    defer handoff.deinit();
    try std.testing.expectEqual(@as(usize, 1), handoff.verifier_candidate_blocked_count);
    try std.testing.expectEqual(CandidateStatus.blocked, handoff.verifier_candidates[0].status);
    try std.testing.expectEqual(CandidateBlockedReason.unbound_scope, handoff.verifier_candidates[0].blocked_reason.?);
}

test "check-plan candidate is allowed without writing files" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();
    var tracker = BudgetTracker.init(allocator, compute_budget.resolve(.{ .tier = .medium }));
    var hypothesis = try testHypothesis(allocator, "document_schema", "docs/runbook.md", "unit_consistency", "document_consistency");
    defer deinitTestHypothesis(allocator, &hypothesis);
    var handoff = try handoffSelectedHypotheses(allocator, &registry, &tracker, &.{hypothesis}, try selectedTriage(), .{}, .deep);
    defer handoff.deinit();
    try std.testing.expectEqual(@as(usize, 0), handoff.verifier_candidates[0].generated_artifacts.len);
    try std.testing.expect(handoff.verifier_candidates[0].patch_or_file_proposal == null);
    try std.testing.expect(handoff.verifier_candidates[0].requires_approval);
}

test "materializable file candidate is proposed not applied" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();
    try registerBuiltinAdapters(&registry);
    var tracker = BudgetTracker.init(allocator, compute_budget.resolve(.{ .tier = .medium }));
    var hypothesis = try testHypothesis(allocator, "code_artifact_schema", "src/runtime/worker.zig", "constraint_check", "static_check");
    defer deinitTestHypothesis(allocator, &hypothesis);
    var handoff = try handoffSelectedHypotheses(allocator, &registry, &tracker, &.{hypothesis}, try selectedTriage(), .{}, .deep);
    defer handoff.deinit();
    try std.testing.expectEqual(@as(usize, 1), handoff.verifier_candidates[0].generated_artifacts.len);
    try std.testing.expect(handoff.verifier_candidates[0].patch_or_file_proposal != null);
    try std.testing.expect(handoff.verifier_candidates[0].command_plan != null);
    try std.testing.expect(handoff.verifier_candidates[0].command_plan.?.requires_approval);
}

test "unsafe verifier candidate is blocked before proposal" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();
    var tracker = BudgetTracker.init(allocator, compute_budget.resolve(.{ .tier = .medium }));
    var hypothesis = try testHypothesis(allocator, "code_artifact_schema", "src/runtime/worker.zig", "constraint_check", "unsafe exploit command");
    defer deinitTestHypothesis(allocator, &hypothesis);
    hypothesis.source_rule = "unsafe";
    var handoff = try handoffSelectedHypotheses(allocator, &registry, &tracker, &.{hypothesis}, try selectedTriage(), .{}, .deep);
    defer handoff.deinit();
    try std.testing.expectEqual(CandidateStatus.blocked, handoff.verifier_candidates[0].status);
    try std.testing.expectEqual(CandidateBlockedReason.unsafe_check, handoff.verifier_candidates[0].blocked_reason.?);
}

test "verifier candidate generation obeys budget caps deterministically" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();
    var tracker = BudgetTracker.init(allocator, compute_budget.resolve(.{
        .tier = .medium,
        .overrides = .{ .max_verifier_candidates_generated = 0 },
    }));
    var hypothesis = try testHypothesis(allocator, "document_schema", "docs/runbook.md", "unit_consistency", "document_consistency");
    defer deinitTestHypothesis(allocator, &hypothesis);
    var handoff = try handoffSelectedHypotheses(allocator, &registry, &tracker, &.{hypothesis}, try selectedTriage(), .{}, .deep);
    defer handoff.deinit();
    try std.testing.expectEqual(@as(usize, 1), handoff.verifier_candidate_budget_exhausted_count);
    try std.testing.expectEqual(CandidateBlockedReason.budget_exhausted, handoff.verifier_candidates[0].blocked_reason.?);
}

test "verifier candidate appears in support graph but cannot support final output" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();
    var tracker = BudgetTracker.init(allocator, compute_budget.resolve(.{ .tier = .medium }));
    var hypothesis = try testHypothesis(allocator, "document_schema", "docs/runbook.md", "unit_consistency", "document_consistency");
    defer deinitTestHypothesis(allocator, &hypothesis);
    var handoff = try handoffSelectedHypotheses(allocator, &registry, &tracker, &.{hypothesis}, try selectedTriage(), .{}, .deep);
    defer handoff.deinit();
    var nodes = std.ArrayList(code_intel.SupportGraphNode).init(allocator);
    defer {
        for (nodes.items) |node| {
            allocator.free(node.id);
            allocator.free(node.label);
            if (node.rel_path) |path| allocator.free(path);
            if (node.detail) |detail| allocator.free(detail);
        }
        nodes.deinit();
    }
    var edges = std.ArrayList(code_intel.SupportGraphEdge).init(allocator);
    defer {
        for (edges.items) |edge| {
            allocator.free(edge.from_id);
            allocator.free(edge.to_id);
        }
        edges.deinit();
    }
    try appendHandoffToSupportGraph(allocator, &nodes, &edges, "output", handoff);
    var saw_candidate = false;
    for (nodes.items) |node| {
        if (node.kind == .verifier_candidate) {
            saw_candidate = true;
            try std.testing.expect(!node.usable);
        }
    }
    try std.testing.expect(saw_candidate);
    for (edges.items) |edge| {
        try std.testing.expect(edge.kind != .supported_by);
    }
}

test "same verifier candidate input produces same order and scope limitation" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();
    var tracker_a = BudgetTracker.init(allocator, compute_budget.resolve(.{ .tier = .medium }));
    var tracker_b = BudgetTracker.init(allocator, compute_budget.resolve(.{ .tier = .medium }));
    var hypothesis = try testHypothesis(allocator, "document_schema", "docs/runbook.md", "unit_consistency", "document_consistency");
    defer deinitTestHypothesis(allocator, &hypothesis);
    var first = try handoffSelectedHypotheses(allocator, &registry, &tracker_a, &.{hypothesis}, try selectedTriage(), .{}, .deep);
    defer first.deinit();
    var second = try handoffSelectedHypotheses(allocator, &registry, &tracker_b, &.{hypothesis}, try selectedTriage(), .{}, .deep);
    defer second.deinit();
    try std.testing.expect(std.mem.eql(u8, first.verifier_candidates[0].id, second.verifier_candidates[0].id));
    try std.testing.expect(first.verifier_candidates[0].scope_limitations.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, first.verifier_candidates[0].scope_limitations[0], "does not check") != null);
}

test "expected observation unknown blocks verifier candidate" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();
    var tracker = BudgetTracker.init(allocator, compute_budget.resolve(.{ .tier = .medium }));
    var hypothesis = try testHypothesis(allocator, "document_schema", "docs/runbook.md", "unit_consistency", "expected_observation_unknown");
    defer deinitTestHypothesis(allocator, &hypothesis);
    var handoff = try handoffSelectedHypotheses(allocator, &registry, &tracker, &.{hypothesis}, try selectedTriage(), .{}, .deep);
    defer handoff.deinit();
    try std.testing.expectEqual(CandidateStatus.blocked, handoff.verifier_candidates[0].status);
    try std.testing.expectEqual(CandidateBlockedReason.expected_observation_unknown, handoff.verifier_candidates[0].blocked_reason.?);
}
