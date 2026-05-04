const std = @import("std");
const abstractions = @import("abstractions.zig");
const code_intel = @import("code_intel.zig");
const compute_budget = @import("compute_budget.zig");
const config = @import("config.zig");
const execution = @import("execution.zig");
const feedback = @import("feedback.zig");
const knowledge_pack_store = @import("knowledge_pack_store.zig");
const mc = @import("inference.zig");
const panic_dump = @import("panic_dump.zig");
const shards = @import("shards.zig");
const sys = @import("sys.zig");
const task_intent = @import("task_intent.zig");
const verifier_adapter = @import("verifier_adapter.zig");

pub const COMMAND_NAME = "/stage_patch_candidates";
pub const DEFAULT_CODE_INTEL_RESULT_NAME = "last_result.json";
pub const MINIMALITY_MODEL_NAME = "bounded_refactor_minimality_v1";

pub const HARD_MAX_CANDIDATES: usize = 4;
pub const HARD_MAX_FILES: usize = 4;
pub const HARD_MAX_HUNKS_PER_CANDIDATE: usize = 3;
pub const HARD_MAX_LINES_PER_HUNK: u32 = 12;
pub const HARD_MAX_SUPPORT_ITEMS: usize = 8;
pub const HARD_MAX_ABSTRACTIONS: usize = 6;
pub const MAX_REQUEST_LABEL_BYTES: usize = 160;
pub const MAX_SOURCE_FILE_BYTES: usize = 512 * 1024;
pub const MAX_VERIFICATION_RETRIES: u32 = 1;
pub const MAX_VERIFICATION_OUTPUT_BYTES: usize = 64 * 1024;
pub const MAX_VERIFICATION_TIMEOUT_MS: u32 = 15_000;
pub const MAX_RUNTIME_ORACLE_BYTES: usize = 8 * 1024;
pub const MAX_RUNTIME_ORACLE_CHECKS: usize = 16;
pub const RUNTIME_ORACLE_FILE_NAME = "ghost_runtime_oracle.cfg";
const EXPLORATION_REASONING_MODE = mc.ReasoningMode.exploratory;
const PROOF_REASONING_MODE = mc.ReasoningMode.proof;

pub const Caps = struct {
    max_candidates: usize = 3,
    max_files: usize = 3,
    max_hunks_per_candidate: usize = 2,
    max_lines_per_hunk: u32 = 8,
    max_support_items: usize = 6,
    max_abstractions: usize = 4,

    pub fn normalized(self: Caps) Caps {
        return .{
            .max_candidates = clampBounded(self.max_candidates, 1, HARD_MAX_CANDIDATES),
            .max_files = clampBounded(self.max_files, 1, HARD_MAX_FILES),
            .max_hunks_per_candidate = clampBounded(self.max_hunks_per_candidate, 1, HARD_MAX_HUNKS_PER_CANDIDATE),
            .max_lines_per_hunk = @intCast(clampBounded(self.max_lines_per_hunk, 2, HARD_MAX_LINES_PER_HUNK)),
            .max_support_items = clampBounded(self.max_support_items, 1, HARD_MAX_SUPPORT_ITEMS),
            .max_abstractions = clampBounded(self.max_abstractions, 0, HARD_MAX_ABSTRACTIONS),
        };
    }
};

pub const Options = struct {
    repo_root: []const u8,
    project_shard: ?[]const u8 = null,
    query_kind: code_intel.QueryKind,
    target: []const u8,
    other_target: ?[]const u8 = null,
    request_label: ?[]const u8 = null,
    intent: ?*const task_intent.Task = null,
    caps: Caps = .{},
    compute_budget_request: compute_budget.Request = .{},
    effective_budget: compute_budget.Effective = compute_budget.resolve(.{}),
    persist_code_intel: bool = true,
    cache_persist: bool = true,
    stage_result: bool = false,
    max_verification_retries: u32 = MAX_VERIFICATION_RETRIES,
    verification_path_override: ?[]const u8 = null,
};

pub const Strategy = enum {
    local_guard,
    seam_adapter,
    contradiction_split,
    abstraction_alignment,
};

pub const RewriteOperator = enum {
    import_insert,
    import_remove,
    import_update,
    call_site_adaptation,
    dispatch_indirection,
    signature_adapter_generation,
    parameter_threading,
    guard_insertion,
    structural_rename_update,
};

pub const SupportKind = enum {
    strategy,
    rewrite_operator,
    code_intel_target,
    code_intel_hypothesis,
    code_intel_primary,
    code_intel_secondary,
    code_intel_evidence,
    code_intel_refactor_path,
    code_intel_overlap,
    code_intel_contradiction,
    code_intel_partial_anchor,
    grounding_schema_anchor,
    abstraction_live,
    abstraction_staged,
    execution_evidence,
    execution_contradiction,
    refinement_hypothesis,
};

pub const ScoreTrace = struct {
    label: []u8,
    score: u32,
    evidence_count: u32,

    fn deinit(self: *ScoreTrace, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
        self.* = undefined;
    }
};

pub const SupportTrace = struct {
    kind: SupportKind,
    label: []u8,
    rel_path: ?[]u8 = null,
    line: u32 = 0,
    score: u32 = 0,
    reason: ?[]u8 = null,

    fn deinit(self: *SupportTrace, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
        if (self.rel_path) |rel_path| allocator.free(rel_path);
        if (self.reason) |reason| allocator.free(reason);
        self.* = undefined;
    }
};

pub const PatchHunk = struct {
    rel_path: []u8,
    anchor_line: u32,
    start_line: u32,
    end_line: u32,
    diff: []u8,

    fn deinit(self: *PatchHunk, allocator: std.mem.Allocator) void {
        allocator.free(self.rel_path);
        allocator.free(self.diff);
        self.* = undefined;
    }
};

pub const ValidationState = enum {
    draft_unvalidated,
    build_failed,
    test_failed,
    build_test_verified,
    runtime_verified,
    runtime_failed,
    runtime_unresolved,
    proof_rejected,
};

pub const CandidateStatus = enum {
    rejected,
    unresolved,
    supported,
    novel_but_unverified,
};

pub const SpeculativeCandidateStatus = enum {
    pending,
    pruned,
    verified,
    failed,
};

pub const SupportRiskLevel = enum {
    low,
    medium,
    high,
};

pub const SupportEstimate = struct {
    viable: bool = true,
    risk_level: SupportRiskLevel = .medium,
    estimated_cost: u32 = 0,
    blocking_flags: [][]u8 = &.{},

    fn deinit(self: *SupportEstimate, allocator: std.mem.Allocator) void {
        for (self.blocking_flags) |flag| allocator.free(flag);
        allocator.free(self.blocking_flags);
        self.* = undefined;
    }

    fn clone(self: SupportEstimate, allocator: std.mem.Allocator) !SupportEstimate {
        var flags = try allocator.alloc([]u8, self.blocking_flags.len);
        var built: usize = 0;
        errdefer {
            for (flags[0..built]) |flag| allocator.free(flag);
            allocator.free(flags);
        }
        for (self.blocking_flags, 0..) |flag, idx| {
            flags[idx] = try allocator.dupe(u8, flag);
            built += 1;
        }
        return .{
            .viable = self.viable,
            .risk_level = self.risk_level,
            .estimated_cost = self.estimated_cost,
            .blocking_flags = flags,
        };
    }
};

pub const RefactorPlanStatus = enum {
    unresolved,
    verified_supported,
};

pub const MinimalityEvidence = struct {
    file_count: u32 = 0,
    change_count: u32 = 0,
    hunk_count: u32 = 0,
    dependency_spread: u32 = 0,
    scope_penalty: u32 = 0,
    total_cost: u32 = 0,
};

pub const VerificationStepState = enum {
    unavailable,
    passed,
    failed,
};

pub const RuntimeOracleCheck = union(enum) {
    exit_code: i32,
    stdout_contains: []u8,
    stderr_contains: []u8,
    stdout_not_contains: []u8,
    stderr_not_contains: []u8,
    state_value: KeyValueCheck,
    event_sequence: StringListCheck,
    state_transition: TransitionCheck,
    invariant_holds: []u8,

    fn deinit(self: *RuntimeOracleCheck, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .exit_code => {},
            .stdout_contains => |value| allocator.free(value),
            .stderr_contains => |value| allocator.free(value),
            .stdout_not_contains => |value| allocator.free(value),
            .stderr_not_contains => |value| allocator.free(value),
            .state_value => |*value| value.deinit(allocator),
            .event_sequence => |*value| value.deinit(allocator),
            .state_transition => |*value| value.deinit(allocator),
            .invariant_holds => |value| allocator.free(value),
        }
        self.* = undefined;
    }
};

pub const KeyValueCheck = struct {
    key: []u8,
    value: []u8,

    fn deinit(self: *KeyValueCheck, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        allocator.free(self.value);
        self.* = undefined;
    }
};

pub const StringListCheck = struct {
    items: [][]u8,

    fn deinit(self: *StringListCheck, allocator: std.mem.Allocator) void {
        for (self.items) |item| allocator.free(item);
        allocator.free(self.items);
        self.* = undefined;
    }
};

pub const TransitionCheck = struct {
    key: []u8,
    values: [][]u8,

    fn deinit(self: *TransitionCheck, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        for (self.values) |item| allocator.free(item);
        allocator.free(self.values);
        self.* = undefined;
    }
};

pub const RuntimeOracle = struct {
    required: bool = true,
    label: []u8,
    kind: execution.Kind,
    phase: execution.Phase,
    argv: [][]u8,
    timeout_ms: u32 = MAX_VERIFICATION_TIMEOUT_MS,
    checks: []RuntimeOracleCheck,

    fn deinit(self: *RuntimeOracle, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
        for (self.argv) |arg| allocator.free(arg);
        allocator.free(self.argv);
        for (self.checks) |*check| check.deinit(allocator);
        allocator.free(self.checks);
        self.* = undefined;
    }
};

pub const VerificationStep = struct {
    state: VerificationStepState = .unavailable,
    adapter_id: ?[]u8 = null,
    evidence_kind: ?verifier_adapter.EvidenceKind = null,
    command: ?[]u8 = null,
    exit_code: ?i32 = null,
    duration_ms: u64 = 0,
    failure_signal: ?execution.FailureSignal = null,
    summary: ?[]u8 = null,
    evidence: ?[]u8 = null,

    fn deinit(self: *VerificationStep, allocator: std.mem.Allocator) void {
        if (self.adapter_id) |adapter_id| allocator.free(adapter_id);
        if (self.command) |command| allocator.free(command);
        if (self.summary) |summary| allocator.free(summary);
        if (self.evidence) |evidence| allocator.free(evidence);
        self.* = undefined;
    }
};

pub const RepairStrategy = enum {
    narrow_to_primary_surface,
    import_repair,
    dispatch_normalization_repair,
    signature_alignment_repair,
    call_surface_adapter_repair,
    invariant_preserving_simplification,
};

pub const RepairPlanOutcome = enum {
    pending,
    improved,
    failed,
    insufficient_evidence,
};

pub const RepairPlan = struct {
    attempt: u32,
    trigger_phase: execution.Phase,
    trigger_failure_signal: ?execution.FailureSignal = null,
    strategy: RepairStrategy,
    retry_budget: u32,
    expected_verification_target: execution.Phase,
    lineage_parent_id: []u8,
    descendant_id: []u8,
    trigger_summary: []u8,
    evidence_summary: []u8,
    retained_hunk_count: u32 = 0,
    outcome: RepairPlanOutcome = .pending,
    outcome_summary: ?[]u8 = null,

    fn deinit(self: *RepairPlan, allocator: std.mem.Allocator) void {
        allocator.free(self.lineage_parent_id);
        allocator.free(self.descendant_id);
        allocator.free(self.trigger_summary);
        allocator.free(self.evidence_summary);
        if (self.outcome_summary) |summary| allocator.free(summary);
        self.* = undefined;
    }
};

pub const RefinementTrace = struct {
    attempt: u32,
    label: []u8,
    reason: []u8,
    retained_hunk_count: u32,

    fn deinit(self: *RefinementTrace, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
        allocator.free(self.reason);
        self.* = undefined;
    }
};

pub const VerificationTrace = struct {
    build: VerificationStep = .{},
    test_step: VerificationStep = .{},
    runtime_step: VerificationStep = .{},
    retry_count: u32 = 0,
    max_retry_count: u32 = 0,
    proof_score: u32 = 0,
    proof_confidence: u32 = 0,
    proof_reason: ?[]u8 = null,
    repair_plans: []RepairPlan = &.{},
    refinements: []RefinementTrace = &.{},

    fn deinit(self: *VerificationTrace, allocator: std.mem.Allocator) void {
        self.build.deinit(allocator);
        self.test_step.deinit(allocator);
        self.runtime_step.deinit(allocator);
        if (self.proof_reason) |reason| allocator.free(reason);
        for (self.repair_plans) |*plan| plan.deinit(allocator);
        allocator.free(self.repair_plans);
        for (self.refinements) |*trace| trace.deinit(allocator);
        allocator.free(self.refinements);
        self.* = undefined;
    }
};

pub const CandidateCluster = struct {
    id: []u8,
    label: []u8,
    member_ids: [][]u8 = &.{},
    proof_queue_count: u32 = 0,
    preserved_novel_count: u32 = 0,

    fn deinit(self: *CandidateCluster, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.label);
        for (self.member_ids) |member_id| allocator.free(member_id);
        allocator.free(self.member_ids);
        self.* = undefined;
    }
};

pub const ExplorationTrace = struct {
    mode: mc.ReasoningMode = EXPLORATION_REASONING_MODE,
    candidate_pool_limit: u32 = 0,
    generated_candidate_count: u32 = 0,
    clustered_candidate_count: u32 = 0,
    cluster_count: u32 = 0,
    proof_queue_limit: u32 = 0,
    proof_queue_count: u32 = 0,
    preserved_novel_count: u32 = 0,
};

pub const ProofTrace = struct {
    mode: mc.ReasoningMode = PROOF_REASONING_MODE,
    queued_candidate_count: u32 = 0,
    admission_blocked_count: u32 = 0,
    verified_survivor_count: u32 = 0,
    rejected_count: u32 = 0,
    unresolved_count: u32 = 0,
    supported_count: u32 = 0,
    novel_but_unverified_count: u32 = 0,
    final_candidate_id: ?[]u8 = null,

    fn deinit(self: *ProofTrace, allocator: std.mem.Allocator) void {
        if (self.final_candidate_id) |candidate_id| allocator.free(candidate_id);
        self.* = undefined;
    }
};

pub const ExploreToVerifyHandoff = struct {
    exploration: ExplorationTrace = .{},
    proof: ProofTrace = .{},
    clusters: []CandidateCluster = &.{},

    fn deinit(self: *ExploreToVerifyHandoff, allocator: std.mem.Allocator) void {
        self.proof.deinit(allocator);
        for (self.clusters) |*cluster| cluster.deinit(allocator);
        allocator.free(self.clusters);
        self.* = undefined;
    }
};

pub const Candidate = struct {
    id: []u8,
    source_intent: []u8,
    action_surface: []u8,
    bound_artifacts: [][]u8 = &.{},
    required_obligations: [][]u8 = &.{},
    initial_support_estimate: SupportEstimate = .{},
    scheduler_status: SpeculativeCandidateStatus = .pending,
    summary: []u8,
    strategy: []u8,
    scope: []u8,
    correctness_claimed: bool = false,
    status: CandidateStatus = .unresolved,
    status_reason: ?[]u8 = null,
    validation_state: ValidationState = .draft_unvalidated,
    cluster_id: ?[]u8 = null,
    cluster_label: ?[]u8 = null,
    entered_proof_mode: bool = false,
    exploration_rank: u32 = 0,
    proof_rank: ?u32 = null,
    score: u32,
    minimality: MinimalityEvidence = .{},
    files: [][]u8 = &.{},
    rewrite_operators: []RewriteOperator = &.{},
    hunks: []PatchHunk = &.{},
    trace: []SupportTrace = &.{},
    verification: VerificationTrace = .{},
    rejection_reason: ?[]u8 = null,

    fn deinit(self: *Candidate, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.source_intent);
        allocator.free(self.action_surface);
        for (self.bound_artifacts) |item| allocator.free(item);
        allocator.free(self.bound_artifacts);
        for (self.required_obligations) |item| allocator.free(item);
        allocator.free(self.required_obligations);
        self.initial_support_estimate.deinit(allocator);
        allocator.free(self.summary);
        allocator.free(self.strategy);
        allocator.free(self.scope);
        if (self.status_reason) |reason| allocator.free(reason);
        if (self.cluster_id) |cluster_id| allocator.free(cluster_id);
        if (self.cluster_label) |cluster_label| allocator.free(cluster_label);
        for (self.files) |item| allocator.free(item);
        allocator.free(self.files);
        allocator.free(self.rewrite_operators);
        for (self.hunks) |*hunk| hunk.deinit(allocator);
        allocator.free(self.hunks);
        for (self.trace) |*trace| trace.deinit(allocator);
        allocator.free(self.trace);
        self.verification.deinit(allocator);
        if (self.rejection_reason) |reason| allocator.free(reason);
        self.* = undefined;
    }

    fn clone(self: Candidate, allocator: std.mem.Allocator) !Candidate {
        var files = try allocator.alloc([]u8, self.files.len);
        var built_files: usize = 0;
        errdefer {
            for (files[0..built_files]) |item| allocator.free(item);
            allocator.free(files);
        }
        for (self.files, 0..) |item, idx| {
            files[idx] = try allocator.dupe(u8, item);
            built_files += 1;
        }

        const rewrite_operators = try allocator.dupe(RewriteOperator, self.rewrite_operators);
        errdefer allocator.free(rewrite_operators);

        var hunks = try allocator.alloc(PatchHunk, self.hunks.len);
        var built_hunks: usize = 0;
        errdefer {
            for (hunks[0..built_hunks]) |*hunk| hunk.deinit(allocator);
            allocator.free(hunks);
        }
        for (self.hunks, 0..) |hunk, idx| {
            hunks[idx] = .{
                .rel_path = try allocator.dupe(u8, hunk.rel_path),
                .anchor_line = hunk.anchor_line,
                .start_line = hunk.start_line,
                .end_line = hunk.end_line,
                .diff = try allocator.dupe(u8, hunk.diff),
            };
            built_hunks += 1;
        }

        var trace = try allocator.alloc(SupportTrace, self.trace.len);
        var built_trace: usize = 0;
        errdefer {
            for (trace[0..built_trace]) |*item| item.deinit(allocator);
            allocator.free(trace);
        }
        for (self.trace, 0..) |item, idx| {
            trace[idx] = try cloneSupportTrace(allocator, item);
            built_trace += 1;
        }

        return .{
            .id = try allocator.dupe(u8, self.id),
            .source_intent = try allocator.dupe(u8, self.source_intent),
            .action_surface = try allocator.dupe(u8, self.action_surface),
            .bound_artifacts = try cloneStringSlice(allocator, self.bound_artifacts),
            .required_obligations = try cloneStringSlice(allocator, self.required_obligations),
            .initial_support_estimate = try self.initial_support_estimate.clone(allocator),
            .scheduler_status = self.scheduler_status,
            .summary = try allocator.dupe(u8, self.summary),
            .strategy = try allocator.dupe(u8, self.strategy),
            .scope = try allocator.dupe(u8, self.scope),
            .correctness_claimed = self.correctness_claimed,
            .status = self.status,
            .status_reason = if (self.status_reason) |reason| try allocator.dupe(u8, reason) else null,
            .validation_state = self.validation_state,
            .cluster_id = if (self.cluster_id) |cluster_id| try allocator.dupe(u8, cluster_id) else null,
            .cluster_label = if (self.cluster_label) |cluster_label| try allocator.dupe(u8, cluster_label) else null,
            .entered_proof_mode = self.entered_proof_mode,
            .exploration_rank = self.exploration_rank,
            .proof_rank = self.proof_rank,
            .score = self.score,
            .minimality = self.minimality,
            .files = files,
            .rewrite_operators = rewrite_operators,
            .hunks = hunks,
            .trace = trace,
            .verification = .{},
            .rejection_reason = if (self.rejection_reason) |reason| try allocator.dupe(u8, reason) else null,
        };
    }
};

pub const Result = struct {
    allocator: std.mem.Allocator,
    status: code_intel.Status,
    query_kind: code_intel.QueryKind,
    target: []u8,
    other_target: ?[]u8 = null,
    request_label: []u8,
    repo_root: []u8,
    shard_id: []u8,
    shard_root: []u8,
    shard_kind: shards.Kind,
    scratch_only: bool = true,
    correctness_claimed: bool = false,
    stop_reason: mc.StopReason = .none,
    confidence: u32 = 0,
    minimality_model: ?[]u8 = null,
    refactor_plan_status: RefactorPlanStatus = .unresolved,
    selected_scope: ?[]u8 = null,
    selected_refactor_scope: ?[]u8 = null,
    contradiction_kind: ?[]u8 = null,
    selected_strategy: ?[]u8 = null,
    selected_candidate_id: ?[]u8 = null,
    unresolved_detail: ?[]u8 = null,
    partial_support: code_intel.PartialSupport = .{},
    intent: ?task_intent.Task = null,
    staged_path: ?[]u8 = null,
    code_intel_result_path: []u8,
    caps: Caps,
    effective_budget: compute_budget.Effective = compute_budget.resolve(.{}),
    budget_exhaustion: ?compute_budget.Exhaustion = null,
    strategy_hypotheses: []ScoreTrace = &.{},
    invariant_evidence: []SupportTrace = &.{},
    contradiction_evidence: []SupportTrace = &.{},
    abstraction_refs: []SupportTrace = &.{},
    source_pack_evidence: []code_intel.Evidence = &.{},
    source_abstraction_traces: []code_intel.AbstractionTrace = &.{},
    pack_routing_traces: []abstractions.PackRoutingTrace = &.{},
    pack_routing_caps: abstractions.PackRoutingCaps = .{},
    pack_conflict_policy: abstractions.PackConflictPolicy = .{},
    grounding_traces: []code_intel.GroundingTrace = &.{},
    reverse_grounding_traces: []code_intel.GroundingTrace = &.{},
    planning_basis: code_intel.UnresolvedSupport = .{ .allocator = undefined },
    handoff: ExploreToVerifyHandoff = .{},
    candidates: []Candidate = &.{},
    unresolved: code_intel.UnresolvedSupport = .{ .allocator = undefined },
    support_graph: code_intel.SupportGraph = .{ .allocator = undefined },
    profile: Profile = .{},

    pub fn deinit(self: *Result) void {
        self.allocator.free(self.target);
        if (self.other_target) |other| self.allocator.free(other);
        self.allocator.free(self.request_label);
        self.allocator.free(self.repo_root);
        self.allocator.free(self.shard_id);
        self.allocator.free(self.shard_root);
        self.allocator.free(self.code_intel_result_path);
        if (self.minimality_model) |model| self.allocator.free(model);
        if (self.selected_scope) |scope| self.allocator.free(scope);
        if (self.selected_refactor_scope) |scope| self.allocator.free(scope);
        if (self.contradiction_kind) |kind| self.allocator.free(kind);
        if (self.selected_strategy) |strategy| self.allocator.free(strategy);
        if (self.selected_candidate_id) |candidate_id| self.allocator.free(candidate_id);
        if (self.unresolved_detail) |detail| self.allocator.free(detail);
        if (self.intent) |*intent| intent.deinit();
        if (self.staged_path) |path| self.allocator.free(path);
        if (self.budget_exhaustion) |*exhaustion| exhaustion.deinit();
        for (self.strategy_hypotheses) |*trace| trace.deinit(self.allocator);
        self.allocator.free(self.strategy_hypotheses);
        for (self.invariant_evidence) |*trace| trace.deinit(self.allocator);
        self.allocator.free(self.invariant_evidence);
        for (self.contradiction_evidence) |*trace| trace.deinit(self.allocator);
        self.allocator.free(self.contradiction_evidence);
        for (self.abstraction_refs) |*trace| trace.deinit(self.allocator);
        self.allocator.free(self.abstraction_refs);
        deinitCodeIntelEvidenceSlice(self.allocator, self.source_pack_evidence);
        self.allocator.free(self.source_pack_evidence);
        deinitCodeIntelAbstractionSlice(self.allocator, self.source_abstraction_traces);
        self.allocator.free(self.source_abstraction_traces);
        for (self.pack_routing_traces) |*trace| trace.deinit();
        self.allocator.free(self.pack_routing_traces);
        deinitCodeIntelGroundingSlice(self.allocator, self.grounding_traces);
        self.allocator.free(self.grounding_traces);
        deinitCodeIntelGroundingSlice(self.allocator, self.reverse_grounding_traces);
        self.allocator.free(self.reverse_grounding_traces);
        self.planning_basis.deinit();
        self.handoff.deinit(self.allocator);
        for (self.candidates) |*candidate| candidate.deinit(self.allocator);
        self.allocator.free(self.candidates);
        self.unresolved.deinit();
        self.support_graph.deinit();
        self.* = undefined;
    }
};

pub const Profile = struct {
    code_intel_ms: u64 = 0,
    pack_mount_resolve_ms: u64 = 0,
    pack_manifest_preview_load_ms: u64 = 0,
    pack_routing_ms: u64 = 0,
    pack_catalog_load_ms: u64 = 0,
    workspace_prepare_ms: u64 = 0,
    build_exec_ms: u64 = 0,
    test_exec_ms: u64 = 0,
    runtime_exec_ms: u64 = 0,
    verifier_adapter_dispatch_ms: u64 = 0,
    support_graph_ms: u64 = 0,
    stage_result_ms: u64 = 0,
    json_render_ms: u64 = 0,
    panic_dump_ms: u64 = 0,
};

const SurfaceSeed = struct {
    kind: SupportKind,
    rel_path: []const u8,
    line: u32,
    label: []const u8,
    score: u32,
};

const StrategyOption = struct {
    strategy: Strategy,
    score: u32,
};

const ScopeMode = enum {
    focused,
    expanded,
};

const PlanSeed = struct {
    strategy: Strategy,
    strategy_score: u32,
    scope_mode: ScopeMode,
    surface_indexes: [HARD_MAX_FILES]u8 = [_]u8{0} ** HARD_MAX_FILES,
    surface_count: u8 = 0,
    minimality: MinimalityEvidence = .{},
};

const SynthesisOutput = struct {
    summary: []u8,
    files: [][]u8,
    rewrite_operators: []RewriteOperator,
    hunks: []PatchHunk,
    trace: []SupportTrace,

    fn deinit(self: *SynthesisOutput, allocator: std.mem.Allocator) void {
        allocator.free(self.summary);
        for (self.files) |item| allocator.free(item);
        allocator.free(self.files);
        allocator.free(self.rewrite_operators);
        for (self.hunks) |*hunk| hunk.deinit(allocator);
        allocator.free(self.hunks);
        for (self.trace) |*item| item.deinit(allocator);
        allocator.free(self.trace);
        self.* = undefined;
    }
};

const ParsedCommand = struct {
    query_kind: code_intel.QueryKind,
    target: []u8,
    other_target: ?[]u8 = null,
    request_label: []u8,
    caps: Caps,

    fn deinit(self: *ParsedCommand, allocator: std.mem.Allocator) void {
        allocator.free(self.target);
        if (self.other_target) |other| allocator.free(other);
        allocator.free(self.request_label);
        self.* = undefined;
    }
};

const VerificationWorkflow = struct {
    build_available: bool = false,
    test_available: bool = false,
    runtime_available: bool = false,
    runtime_target: ?[]const u8 = null,
    runtime_oracle: ?RuntimeOracle = null,
    runtime_oracle_load_error: ?[]u8 = null,

    fn deinit(self: *VerificationWorkflow, allocator: std.mem.Allocator) void {
        if (self.runtime_oracle) |*oracle| oracle.deinit(allocator);
        if (self.runtime_oracle_load_error) |detail| allocator.free(detail);
        self.* = undefined;
    }
};

pub fn isCommand(script: []const u8) bool {
    const trimmed = std.mem.trim(u8, script, " \r\n\t");
    return std.mem.startsWith(u8, trimmed, COMMAND_NAME);
}

pub fn clearStaged(allocator: std.mem.Allocator, paths: *const shards.Paths) !void {
    _ = allocator;
    deleteFileIfExists(paths.patch_candidates_staged_abs_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

pub fn run(allocator: std.mem.Allocator, options: Options) !Result {
    var shard_metadata = if (options.project_shard) |project_shard|
        try shards.resolveProjectMetadata(allocator, project_shard)
    else
        try shards.resolveCoreMetadata(allocator);
    defer shard_metadata.deinit();

    var shard_paths = try shards.resolvePaths(allocator, shard_metadata.metadata);
    defer shard_paths.deinit();

    return runWithPaths(allocator, &shard_paths, options);
}

pub fn runTankBenchmark(allocator: std.mem.Allocator, options: Options) !Result {
    var shard_metadata = if (options.project_shard) |project_shard|
        try shards.resolveProjectMetadata(allocator, project_shard)
    else
        try shards.resolveCoreMetadata(allocator);
    defer shard_metadata.deinit();

    var shard_paths = try shards.resolvePaths(allocator, shard_metadata.metadata);
    defer shard_paths.deinit();

    return runTankBenchmarkWithPaths(allocator, &shard_paths, options);
}

pub fn runTankBenchmarkFromIntel(allocator: std.mem.Allocator, options: Options, intel: *const code_intel.Result) !Result {
    var shard_metadata = if (options.project_shard) |project_shard|
        try shards.resolveProjectMetadata(allocator, project_shard)
    else
        try shards.resolveCoreMetadata(allocator);
    defer shard_metadata.deinit();

    var shard_paths = try shards.resolvePaths(allocator, shard_metadata.metadata);
    defer shard_paths.deinit();

    return runTankBenchmarkFromIntelWithPaths(allocator, &shard_paths, options, intel);
}

pub fn stageFromCommand(allocator: std.mem.Allocator, paths: *const shards.Paths, script: []const u8) !Result {
    var request = try parseCommand(allocator, script);
    defer request.deinit(allocator);

    const repo_root = try config.getPath(allocator, ".");
    defer allocator.free(repo_root);

    return runWithPaths(allocator, paths, .{
        .repo_root = repo_root,
        .project_shard = if (paths.metadata.kind == .project) paths.metadata.id else null,
        .query_kind = request.query_kind,
        .target = request.target,
        .other_target = request.other_target,
        .request_label = request.request_label,
        .caps = request.caps,
        .persist_code_intel = true,
        .cache_persist = true,
        .stage_result = true,
    });
}

pub fn renderJson(allocator: std.mem.Allocator, result: *const Result) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const writer = out.writer();

    try writer.writeAll("{");
    try writeJsonFieldString(writer, "status", @tagName(result.status), true);
    try writeJsonFieldString(writer, "queryKind", queryKindName(result.query_kind), false);
    try writeJsonFieldString(writer, "target", result.target, false);
    if (result.other_target) |other| try writeOptionalStringField(writer, "otherTarget", other);
    try writeJsonFieldString(writer, "requestLabel", result.request_label, false);
    try writer.writeAll(",\"scratchOnly\":");
    try writer.writeAll(if (result.scratch_only) "true" else "false");
    try writer.writeAll(",\"correctnessClaimed\":");
    try writer.writeAll(if (result.correctness_claimed) "true" else "false");
    try writer.writeAll(",\"honesty\":{");
    try writeJsonFieldString(writer, "stopReason", @tagName(result.stop_reason), true);
    try writer.print(",\"confidence\":{d}", .{result.confidence});
    try writer.writeAll("}");
    try writer.writeAll(",\"computeBudget\":");
    try writeComputeBudgetJson(writer, result.effective_budget, result.budget_exhaustion);
    if (result.intent) |intent| {
        const rendered_intent = try task_intent.renderJson(allocator, &intent);
        defer allocator.free(rendered_intent);
        try writer.writeAll(",\"intent\":");
        try writer.writeAll(rendered_intent);
    }

    try writer.writeAll(",\"shard\":{");
    try writeJsonFieldString(writer, "kind", @tagName(result.shard_kind), true);
    try writeJsonFieldString(writer, "id", result.shard_id, false);
    try writeJsonFieldString(writer, "root", result.shard_root, false);
    try writer.writeAll("}");

    if (result.minimality_model) |model| try writeOptionalStringField(writer, "minimalityModel", model);
    try writeOptionalStringField(writer, "refactorPlanStatus", refactorPlanStatusName(result.refactor_plan_status));
    if (result.selected_scope) |scope| try writeOptionalStringField(writer, "selectedScope", scope);
    if (result.selected_refactor_scope) |scope| try writeOptionalStringField(writer, "selectedRefactorScope", scope);
    if (selectedValidationState(result)) |state| try writeOptionalStringField(writer, "selectedVerificationState", validationStateName(state));
    if (result.contradiction_kind) |kind| try writeOptionalStringField(writer, "contradictionKind", kind);
    if (result.selected_strategy) |strategy| try writeOptionalStringField(writer, "selectedStrategy", strategy);
    if (result.selected_candidate_id) |candidate_id| try writeOptionalStringField(writer, "selectedCandidateId", candidate_id);
    if (result.unresolved_detail) |detail| try writeOptionalStringField(writer, "unresolvedDetail", detail);
    try writer.writeAll(",\"partialSupport\":");
    try code_intel.writePartialSupportJson(writer, result.partial_support);
    if (result.staged_path) |path| try writeOptionalStringField(writer, "stagedPath", path);
    try writeOptionalStringField(writer, "codeIntelResultPath", result.code_intel_result_path);

    try writer.writeAll(",\"caps\":{");
    try writer.print("\"maxCandidates\":{d},\"maxFiles\":{d},\"maxHunksPerCandidate\":{d},\"maxLinesPerHunk\":{d},\"maxSupportItems\":{d},\"maxAbstractions\":{d}", .{
        result.caps.max_candidates,
        result.caps.max_files,
        result.caps.max_hunks_per_candidate,
        result.caps.max_lines_per_hunk,
        result.caps.max_support_items,
        result.caps.max_abstractions,
    });
    try writer.writeAll("}");

    try writer.writeAll(",\"strategyHypotheses\":");
    try writeScoreTraceArray(writer, result.strategy_hypotheses);
    try writer.writeAll(",\"invariantEvidence\":");
    try writeSupportTraceArray(writer, result.invariant_evidence);
    try writer.writeAll(",\"contradictionEvidence\":");
    try writeSupportTraceArray(writer, result.contradiction_evidence);
    try writer.writeAll(",\"abstractionRefs\":");
    try writeSupportTraceArray(writer, result.abstraction_refs);
    try writer.writeAll(",\"sourcePackEvidence\":");
    try code_intel.writeEvidenceArray(writer, result.source_pack_evidence);
    try writer.writeAll(",\"sourceAbstractions\":");
    try code_intel.writeAbstractionTraceArray(writer, result.source_abstraction_traces);
    try writer.writeAll(",\"sourcePackRouting\":");
    try code_intel.writePackRoutingJson(writer, result.pack_routing_traces, result.pack_routing_caps, result.pack_conflict_policy);
    try writer.writeAll(",\"sourceGroundings\":");
    try code_intel.writeGroundingTraceArray(writer, result.grounding_traces);
    try writer.writeAll(",\"sourceReverseGroundings\":");
    try code_intel.writeGroundingTraceArray(writer, result.reverse_grounding_traces);
    try writer.writeAll(",\"packInfluence\":");
    try code_intel.writePackInfluenceJson(writer, result.source_pack_evidence, result.source_abstraction_traces, result.pack_routing_traces, result.grounding_traces, result.reverse_grounding_traces);
    try writer.writeAll(",\"handoff\":");
    try writeHandoffJson(writer, result.handoff);
    try writer.print(",\"candidateCount\":{d}", .{result.candidates.len});
    try writer.writeAll(",\"candidates\":");
    try writeCandidateArray(writer, result.candidates);
    try writer.writeAll(",\"unresolved\":");
    try code_intel.writeUnresolvedSupportJson(writer, result.unresolved);
    try writer.writeAll(",\"supportGraph\":");
    try code_intel.writeSupportGraphJson(writer, result.support_graph);
    try writer.writeAll("}");
    return out.toOwnedSlice();
}

fn runWithPaths(allocator: std.mem.Allocator, paths: *const shards.Paths, options: Options) !Result {
    var effective_options = options;
    effective_options.effective_budget = compute_budget.resolve(options.compute_budget_request);

    var caps = options.caps.normalized();
    caps.max_candidates = @min(caps.max_candidates, effective_options.effective_budget.max_proof_queue_size);
    caps.max_support_items = @min(caps.max_support_items, effective_options.effective_budget.max_pack_candidate_surfaces);
    caps.max_abstractions = @min(caps.max_abstractions, effective_options.effective_budget.max_pack_candidate_surfaces);

    const intel_started = sys.getMilliTick();
    var intel = try code_intel.run(allocator, .{
        .repo_root = options.repo_root,
        .project_shard = if (paths.metadata.kind == .project) paths.metadata.id else null,
        .reasoning_mode = EXPLORATION_REASONING_MODE,
        .compute_budget_request = effective_options.compute_budget_request,
        .effective_budget = effective_options.effective_budget,
        .query_kind = options.query_kind,
        .target = options.target,
        .other_target = options.other_target,
        .intent = options.intent,
        .max_items = caps.max_support_items,
        .persist = options.persist_code_intel,
        .cache_persist = options.cache_persist,
    });
    defer intel.deinit();

    var result = try initResult(allocator, paths, effective_options, caps);
    errdefer result.deinit();
    result.profile.code_intel_ms = sys.getMilliTick() - intel_started;
    result.profile.pack_mount_resolve_ms = intel.profile.pack_mount_resolve_ms;
    result.profile.pack_manifest_preview_load_ms = intel.profile.pack_manifest_preview_load_ms;
    result.profile.pack_routing_ms = intel.profile.pack_routing_ms;
    result.profile.pack_catalog_load_ms = intel.profile.pack_catalog_load_ms;
    defer {
        const panic_started = sys.getMilliTick();
        panic_dump.capturePatchCandidatesResult(allocator, &result) catch {};
        result.profile.panic_dump_ms = sys.getMilliTick() - panic_started;
    }
    result.status = intel.status;
    result.stop_reason = intel.stop_reason;
    result.confidence = intel.confidence;
    result.planning_basis = try cloneUnresolvedSupport(allocator, intel.unresolved);
    if (options.intent) |intent| result.intent = try intent.clone(allocator);
    if (intel.selected_scope) |scope| result.selected_scope = try allocator.dupe(u8, scope);
    if (intel.contradiction_kind) |kind| result.contradiction_kind = try allocator.dupe(u8, kind);
    result.invariant_evidence = try buildInvariantEvidence(allocator, &intel, caps.max_support_items);
    result.contradiction_evidence = try buildContradictionEvidence(allocator, &intel, caps.max_support_items);
    result.source_pack_evidence = try cloneCodeIntelEvidenceSlice(allocator, intel.evidence);

    var support_paths = std.ArrayList([]const u8).init(allocator);
    defer support_paths.deinit();
    try collectSupportPaths(&support_paths, &intel, caps.max_files);

    const abstraction_refs = try abstractions.collectSupportingConcepts(allocator, paths, support_paths.items, caps.max_abstractions);
    defer abstractions.deinitSupportReferences(allocator, abstraction_refs);
    result.abstraction_refs = try buildAbstractionTraces(allocator, abstraction_refs);
    result.source_abstraction_traces = try cloneCodeIntelAbstractionSlice(allocator, intel.abstraction_traces);
    result.pack_routing_traces = try intelPackRoutingClone(allocator, intel.pack_routing_traces);
    result.pack_routing_caps = intel.pack_routing_caps;
    result.pack_conflict_policy = intel.pack_conflict_policy;
    result.grounding_traces = try cloneCodeIntelGroundingSlice(allocator, intel.grounding_traces);
    result.reverse_grounding_traces = try cloneCodeIntelGroundingSlice(allocator, intel.reverse_grounding_traces);
    const usable_abstraction_refs = abstractions.countUsableReferences(abstraction_refs);

    if (intel.status != .supported or intel.stop_reason != .none) {
        const support_started = sys.getMilliTick();
        try finalizePatchSupportGraph(allocator, &result);
        result.profile.support_graph_ms += sys.getMilliTick() - support_started;
        if (options.stage_result) {
            const stage_started = sys.getMilliTick();
            try stageResult(allocator, paths, &result);
            result.profile.stage_result_ms += sys.getMilliTick() - stage_started;
        }
        return result;
    }

    var strategy_hypotheses = std.ArrayList(ScoreTrace).init(allocator);
    defer {
        for (strategy_hypotheses.items) |*trace| trace.deinit(allocator);
        strategy_hypotheses.deinit();
    }
    var strategy_options = std.ArrayList(StrategyOption).init(allocator);
    defer strategy_options.deinit();

    const partial_anchor_count = countPatchPlanningAnchors(&intel);
    const grounded_anchor_count = countUsableGroundingAnchors(&intel);
    try appendStrategyOption(
        allocator,
        &strategy_hypotheses,
        &strategy_options,
        .local_guard,
        intel.evidence.len + intel.refactor_path.len + partial_anchor_count + grounded_anchor_count,
        intel.primary != null and (intel.evidence.len + intel.refactor_path.len > 0 or partial_anchor_count > 0 or grounded_anchor_count > 0),
    );
    try appendStrategyOption(
        allocator,
        &strategy_hypotheses,
        &strategy_options,
        .seam_adapter,
        intel.refactor_path.len + intel.overlap.len + grounded_anchor_count,
        intel.refactor_path.len + intel.overlap.len > 1 or grounded_anchor_count > 0 or partial_anchor_count > 1,
    );
    try appendStrategyOption(
        allocator,
        &strategy_hypotheses,
        &strategy_options,
        .contradiction_split,
        intel.contradiction_traces.len + intel.overlap.len + partial_anchor_count,
        intel.contradiction_traces.len > 0 or intel.query_kind == .contradicts or intel.partial_support.blocking.contradicted,
    );
    try appendStrategyOption(
        allocator,
        &strategy_hypotheses,
        &strategy_options,
        .abstraction_alignment,
        usable_abstraction_refs + grounded_anchor_count,
        usable_abstraction_refs > 0 or grounded_anchor_count > 0,
    );

    result.strategy_hypotheses = try cloneScoreTraces(allocator, strategy_hypotheses.items);
    if (strategy_options.items.len == 0) {
        result.status = .unresolved;
        result.stop_reason = .low_confidence;
        result.confidence = 0;
        result.unresolved_detail = try allocator.dupe(u8, "no bounded refactor strategy survived deterministic planning");
        const support_started = sys.getMilliTick();
        try finalizePatchSupportGraph(allocator, &result);
        result.profile.support_graph_ms += sys.getMilliTick() - support_started;
        if (options.stage_result) {
            const stage_started = sys.getMilliTick();
            try stageResult(allocator, paths, &result);
            result.profile.stage_result_ms += sys.getMilliTick() - stage_started;
        }
        return result;
    }

    const candidates = try buildCandidates(allocator, options.repo_root, &intel, abstraction_refs, caps, strategy_options.items);
    if (candidates.len == 0) {
        result.status = .unresolved;
        result.stop_reason = .low_confidence;
        result.confidence = 0;
        result.unresolved_detail = try allocator.dupe(u8, "no bounded synthesized patch survived candidate construction; semantic synthesis support was insufficient");
        const support_started = sys.getMilliTick();
        try finalizePatchSupportGraph(allocator, &result);
        result.profile.support_graph_ms += sys.getMilliTick() - support_started;
        if (options.stage_result) {
            const stage_started = sys.getMilliTick();
            try stageResult(allocator, paths, &result);
            result.profile.stage_result_ms += sys.getMilliTick() - stage_started;
        }
        return result;
    }

    result.candidates = candidates;
    const proof_queue = try prepareExploreToVerifyHandoff(allocator, caps, &intel, &result);
    defer allocator.free(proof_queue);
    if (proof_queue.len == 0) {
        if (result.handoff.exploration.preserved_novel_count > 0) {
            try setBudgetExhaustion(
                allocator,
                &result,
                .max_proof_queue_size,
                .patch_proof_handoff,
                result.candidates.len,
                result.effective_budget.max_proof_queue_size,
                "no candidate could enter proof mode within the selected proof queue budget",
                "additional admissible exploratory candidates were skipped",
            );
        } else {
            result.status = .unresolved;
            result.refactor_plan_status = .unresolved;
            result.stop_reason = .low_confidence;
            result.confidence = 0;
            if (result.unresolved_detail) |detail| allocator.free(detail);
            result.unresolved_detail = try proofAdmissionFailureDetail(allocator, &intel);
        }
        const support_started = sys.getMilliTick();
        try finalizePatchSupportGraph(allocator, &result);
        result.profile.support_graph_ms += sys.getMilliTick() - support_started;
        if (options.stage_result) {
            const stage_started = sys.getMilliTick();
            try stageResult(allocator, paths, &result);
            result.profile.stage_result_ms += sys.getMilliTick() - stage_started;
        }
        return result;
    }
    try verifyCandidates(allocator, paths, options, &result, proof_queue);
    _ = try recordVerificationFeedback(allocator, paths, &result);

    if (result.status == .unresolved and result.budget_exhaustion == null and proofQueueBudgetExhaustedWithoutConcreteVerificationOutcome(&result)) {
        try setBudgetExhaustion(
            allocator,
            &result,
            .max_proof_queue_size,
            .patch_proof_handoff,
            result.candidates.len,
            result.effective_budget.max_proof_queue_size,
            "proof queue capacity was exhausted before more exploratory candidates could be verified",
            "remaining admissible candidates stayed outside proof mode",
        );
    }

    const support_started = sys.getMilliTick();
    try finalizePatchSupportGraph(allocator, &result);
    result.profile.support_graph_ms += sys.getMilliTick() - support_started;
    if (options.stage_result) {
        const stage_started = sys.getMilliTick();
        try stageResult(allocator, paths, &result);
        result.profile.stage_result_ms += sys.getMilliTick() - stage_started;
    }
    return result;
}

fn recordVerificationFeedback(allocator: std.mem.Allocator, paths: *const shards.Paths, result: *const Result) !usize {
    if (result.status == .supported and result.stop_reason == .none) {
        const selected_id = result.selected_candidate_id orelse return 0;
        const event_id = try std.fmt.allocPrint(allocator, "verifier:success:{s}:{s}", .{ result.request_label, selected_id });
        defer allocator.free(event_id);
        return feedback.recordAndApply(allocator, paths, .{
            .id = event_id,
            .source = .verifier,
            .type = .success,
            .related_artifact = result.code_intel_result_path,
            .related_intent = result.request_label,
            .related_candidate = selected_id,
            .outcome = "supported",
            .timestamp = event_id,
            .provenance = "patch_candidates.deep_path",
        });
    }

    const failed = firstFailedVerifiedCandidate(result) orelse return 0;
    const event_id = try std.fmt.allocPrint(allocator, "verifier:failure:{s}:{s}:{s}", .{
        result.request_label,
        failed.id,
        validationStateName(failed.validation_state),
    });
    defer allocator.free(event_id);
    return feedback.recordAndApply(allocator, paths, .{
        .id = event_id,
        .source = .verifier,
        .type = .failure,
        .related_artifact = result.code_intel_result_path,
        .related_intent = result.request_label,
        .related_candidate = failed.id,
        .outcome = validationStateName(failed.validation_state),
        .timestamp = event_id,
        .provenance = "patch_candidates.deep_path",
    });
}

fn firstFailedVerifiedCandidate(result: *const Result) ?*const Candidate {
    for (result.candidates) |*candidate| {
        switch (candidate.validation_state) {
            .build_failed, .test_failed, .runtime_failed, .runtime_unresolved, .proof_rejected => return candidate,
            else => {},
        }
    }
    return null;
}

fn runTankBenchmarkWithPaths(allocator: std.mem.Allocator, paths: *const shards.Paths, options: Options) !Result {
    const caps = options.caps.normalized();

    const intel_started = sys.getMilliTick();
    var intel = try code_intel.run(allocator, .{
        .repo_root = options.repo_root,
        .project_shard = if (paths.metadata.kind == .project) paths.metadata.id else null,
        .reasoning_mode = EXPLORATION_REASONING_MODE,
        .query_kind = options.query_kind,
        .target = options.target,
        .other_target = options.other_target,
        .intent = options.intent,
        .max_items = caps.max_support_items,
        .persist = options.persist_code_intel,
        .cache_persist = options.cache_persist,
    });
    defer intel.deinit();

    var result = try initResult(allocator, paths, options, caps);
    errdefer result.deinit();
    result.profile.code_intel_ms = sys.getMilliTick() - intel_started;
    result.profile.pack_mount_resolve_ms = intel.profile.pack_mount_resolve_ms;
    result.profile.pack_manifest_preview_load_ms = intel.profile.pack_manifest_preview_load_ms;
    result.profile.pack_routing_ms = intel.profile.pack_routing_ms;
    result.profile.pack_catalog_load_ms = intel.profile.pack_catalog_load_ms;
    defer {
        const panic_started = sys.getMilliTick();
        panic_dump.capturePatchCandidatesResult(allocator, &result) catch {};
        result.profile.panic_dump_ms = sys.getMilliTick() - panic_started;
    }
    result.status = intel.status;
    result.stop_reason = intel.stop_reason;
    result.confidence = intel.confidence;
    result.planning_basis = try cloneUnresolvedSupport(allocator, intel.unresolved);
    if (options.intent) |intent| result.intent = try intent.clone(allocator);
    if (intel.selected_scope) |scope| result.selected_scope = try allocator.dupe(u8, scope);
    if (intel.contradiction_kind) |kind| result.contradiction_kind = try allocator.dupe(u8, kind);
    result.invariant_evidence = try buildInvariantEvidence(allocator, &intel, caps.max_support_items);
    result.contradiction_evidence = try buildContradictionEvidence(allocator, &intel, caps.max_support_items);
    result.source_pack_evidence = try cloneCodeIntelEvidenceSlice(allocator, intel.evidence);

    var support_paths = std.ArrayList([]const u8).init(allocator);
    defer support_paths.deinit();
    try collectSupportPaths(&support_paths, &intel, caps.max_files);

    const abstraction_refs = try abstractions.collectSupportingConcepts(allocator, paths, support_paths.items, caps.max_abstractions);
    defer abstractions.deinitSupportReferences(allocator, abstraction_refs);
    result.abstraction_refs = try buildAbstractionTraces(allocator, abstraction_refs);
    result.source_abstraction_traces = try cloneCodeIntelAbstractionSlice(allocator, intel.abstraction_traces);
    result.pack_routing_traces = try intelPackRoutingClone(allocator, intel.pack_routing_traces);
    result.pack_routing_caps = intel.pack_routing_caps;
    result.pack_conflict_policy = intel.pack_conflict_policy;
    result.grounding_traces = try cloneCodeIntelGroundingSlice(allocator, intel.grounding_traces);
    result.reverse_grounding_traces = try cloneCodeIntelGroundingSlice(allocator, intel.reverse_grounding_traces);
    const usable_abstraction_refs = abstractions.countUsableReferences(abstraction_refs);

    var strategy_hypotheses = std.ArrayList(ScoreTrace).init(allocator);
    defer {
        for (strategy_hypotheses.items) |*trace| trace.deinit(allocator);
        strategy_hypotheses.deinit();
    }
    var strategy_options = std.ArrayList(StrategyOption).init(allocator);
    defer strategy_options.deinit();

    const partial_anchor_count = countPatchPlanningAnchors(&intel);
    const grounded_anchor_count = countUsableGroundingAnchors(&intel);
    try appendStrategyOption(
        allocator,
        &strategy_hypotheses,
        &strategy_options,
        .local_guard,
        intel.evidence.len + intel.refactor_path.len + partial_anchor_count + grounded_anchor_count,
        intel.primary != null and (intel.evidence.len + intel.refactor_path.len > 0 or partial_anchor_count > 0 or grounded_anchor_count > 0),
    );
    try appendStrategyOption(
        allocator,
        &strategy_hypotheses,
        &strategy_options,
        .seam_adapter,
        intel.refactor_path.len + intel.overlap.len + grounded_anchor_count,
        intel.refactor_path.len + intel.overlap.len > 1 or grounded_anchor_count > 0 or partial_anchor_count > 1,
    );
    try appendStrategyOption(
        allocator,
        &strategy_hypotheses,
        &strategy_options,
        .contradiction_split,
        intel.contradiction_traces.len + intel.overlap.len + partial_anchor_count,
        intel.contradiction_traces.len > 0 or intel.query_kind == .contradicts or intel.partial_support.blocking.contradicted,
    );
    try appendStrategyOption(
        allocator,
        &strategy_hypotheses,
        &strategy_options,
        .abstraction_alignment,
        usable_abstraction_refs + grounded_anchor_count,
        usable_abstraction_refs > 0 or grounded_anchor_count > 0,
    );

    result.strategy_hypotheses = try cloneScoreTraces(allocator, strategy_hypotheses.items);
    if (strategy_options.items.len == 0) {
        result.status = .unresolved;
        result.refactor_plan_status = .unresolved;
        result.stop_reason = .low_confidence;
        result.confidence = 0;
        result.unresolved_detail = try allocator.dupe(u8, "no bounded refactor strategy survived deterministic planning");
        const support_started = sys.getMilliTick();
        try finalizePatchSupportGraph(allocator, &result);
        result.profile.support_graph_ms += sys.getMilliTick() - support_started;
        return result;
    }

    const candidates = try buildCandidates(allocator, options.repo_root, &intel, abstraction_refs, caps, strategy_options.items);
    if (candidates.len == 0) {
        result.status = .unresolved;
        result.refactor_plan_status = .unresolved;
        result.stop_reason = .low_confidence;
        result.confidence = 0;
        result.unresolved_detail = try allocator.dupe(u8, "no bounded synthesized patch survived candidate construction; semantic synthesis support was insufficient");
        const support_started = sys.getMilliTick();
        try finalizePatchSupportGraph(allocator, &result);
        result.profile.support_graph_ms += sys.getMilliTick() - support_started;
        return result;
    }

    result.candidates = candidates;
    const proof_queue = try prepareExploreToVerifyHandoff(allocator, caps, &intel, &result);
    defer allocator.free(proof_queue);
    summarizeProofTrace(&result);

    result.status = .unresolved;
    result.refactor_plan_status = .unresolved;
    result.stop_reason = .low_confidence;
    result.confidence = 0;
    if (proof_queue.len == 0) {
        if (result.unresolved_detail) |detail| allocator.free(detail);
        result.unresolved_detail = try proofAdmissionFailureDetail(allocator, &intel);
    } else {
        if (result.unresolved_detail) |detail| allocator.free(detail);
        result.unresolved_detail = try allocator.dupe(u8, "benchmark tank path staged bounded exploratory candidates without admitting unsupported rationale into proof");
    }
    const support_started = sys.getMilliTick();
    try finalizePatchSupportGraph(allocator, &result);
    result.profile.support_graph_ms += sys.getMilliTick() - support_started;
    return result;
}

fn runTankBenchmarkFromIntelWithPaths(
    allocator: std.mem.Allocator,
    paths: *const shards.Paths,
    options: Options,
    intel: *const code_intel.Result,
) !Result {
    const caps = options.caps.normalized();

    var result = try initResult(allocator, paths, options, caps);
    errdefer result.deinit();
    defer panic_dump.capturePatchCandidatesResult(allocator, &result) catch {};
    result.status = intel.status;
    result.stop_reason = intel.stop_reason;
    result.confidence = intel.confidence;
    result.planning_basis = try cloneUnresolvedSupport(allocator, intel.unresolved);
    if (options.intent) |intent| result.intent = try intent.clone(allocator);
    if (intel.selected_scope) |scope| result.selected_scope = try allocator.dupe(u8, scope);
    if (intel.contradiction_kind) |kind| result.contradiction_kind = try allocator.dupe(u8, kind);
    result.invariant_evidence = try buildInvariantEvidence(allocator, intel, caps.max_support_items);
    result.contradiction_evidence = try buildContradictionEvidence(allocator, intel, caps.max_support_items);
    result.source_pack_evidence = try cloneCodeIntelEvidenceSlice(allocator, intel.evidence);

    var support_paths = std.ArrayList([]const u8).init(allocator);
    defer support_paths.deinit();
    try collectSupportPaths(&support_paths, intel, caps.max_files);

    const abstraction_refs = try abstractions.collectSupportingConcepts(allocator, paths, support_paths.items, caps.max_abstractions);
    defer abstractions.deinitSupportReferences(allocator, abstraction_refs);
    result.abstraction_refs = try buildAbstractionTraces(allocator, abstraction_refs);
    result.source_abstraction_traces = try cloneCodeIntelAbstractionSlice(allocator, intel.abstraction_traces);
    result.pack_routing_traces = try intelPackRoutingClone(allocator, intel.pack_routing_traces);
    result.pack_routing_caps = intel.pack_routing_caps;
    result.pack_conflict_policy = intel.pack_conflict_policy;
    result.grounding_traces = try cloneCodeIntelGroundingSlice(allocator, intel.grounding_traces);
    result.reverse_grounding_traces = try cloneCodeIntelGroundingSlice(allocator, intel.reverse_grounding_traces);
    const usable_abstraction_refs = abstractions.countUsableReferences(abstraction_refs);

    var strategy_hypotheses = std.ArrayList(ScoreTrace).init(allocator);
    defer {
        for (strategy_hypotheses.items) |*trace| trace.deinit(allocator);
        strategy_hypotheses.deinit();
    }
    var strategy_options = std.ArrayList(StrategyOption).init(allocator);
    defer strategy_options.deinit();

    const partial_anchor_count = countPatchPlanningAnchors(intel);
    const grounded_anchor_count = countUsableGroundingAnchors(intel);
    try appendStrategyOption(allocator, &strategy_hypotheses, &strategy_options, .local_guard, intel.evidence.len + intel.refactor_path.len + partial_anchor_count + grounded_anchor_count, intel.primary != null and (intel.evidence.len + intel.refactor_path.len > 0 or partial_anchor_count > 0 or grounded_anchor_count > 0));
    try appendStrategyOption(allocator, &strategy_hypotheses, &strategy_options, .seam_adapter, intel.refactor_path.len + intel.overlap.len + grounded_anchor_count, intel.refactor_path.len + intel.overlap.len > 1 or grounded_anchor_count > 0 or partial_anchor_count > 1);
    try appendStrategyOption(allocator, &strategy_hypotheses, &strategy_options, .contradiction_split, intel.contradiction_traces.len + intel.overlap.len + partial_anchor_count, intel.contradiction_traces.len > 0 or intel.query_kind == .contradicts or intel.partial_support.blocking.contradicted);
    try appendStrategyOption(allocator, &strategy_hypotheses, &strategy_options, .abstraction_alignment, usable_abstraction_refs + grounded_anchor_count, usable_abstraction_refs > 0 or grounded_anchor_count > 0);

    result.strategy_hypotheses = try cloneScoreTraces(allocator, strategy_hypotheses.items);
    if (strategy_options.items.len == 0) {
        result.status = .unresolved;
        result.refactor_plan_status = .unresolved;
        result.stop_reason = .low_confidence;
        result.confidence = 0;
        result.unresolved_detail = try allocator.dupe(u8, "no bounded refactor strategy survived deterministic planning");
        try finalizePatchSupportGraph(allocator, &result);
        return result;
    }

    const candidates = try buildCandidates(allocator, options.repo_root, intel, abstraction_refs, caps, strategy_options.items);
    if (candidates.len == 0) {
        result.status = .unresolved;
        result.refactor_plan_status = .unresolved;
        result.stop_reason = .low_confidence;
        result.confidence = 0;
        result.unresolved_detail = try allocator.dupe(u8, "no bounded synthesized patch survived candidate construction; semantic synthesis support was insufficient");
        try finalizePatchSupportGraph(allocator, &result);
        return result;
    }

    result.candidates = candidates;
    const proof_queue = try prepareExploreToVerifyHandoff(allocator, caps, intel, &result);
    defer allocator.free(proof_queue);
    summarizeProofTrace(&result);

    result.status = .unresolved;
    result.refactor_plan_status = .unresolved;
    result.stop_reason = .low_confidence;
    result.confidence = 0;
    if (proof_queue.len == 0) {
        if (result.unresolved_detail) |detail| allocator.free(detail);
        result.unresolved_detail = try proofAdmissionFailureDetail(allocator, intel);
    } else {
        if (result.unresolved_detail) |detail| allocator.free(detail);
        result.unresolved_detail = try allocator.dupe(u8, "benchmark tank path staged bounded exploratory candidates without admitting unsupported rationale into proof");
    }
    try finalizePatchSupportGraph(allocator, &result);
    return result;
}

fn verifyCandidates(allocator: std.mem.Allocator, paths: *const shards.Paths, options: Options, result: *Result, proof_queue: []const usize) !void {
    var workflow = try detectVerificationWorkflow(allocator, options.repo_root);
    defer workflow.deinit(allocator);
    const max_retries = @min(@min(options.max_verification_retries, MAX_VERIFICATION_RETRIES), options.effective_budget.max_repairs);
    result.handoff.proof.queued_candidate_count = @intCast(proof_queue.len);
    defer summarizeProofTrace(result);

    for (proof_queue, 0..) |candidate_idx, proof_idx| {
        const candidate = &result.candidates[candidate_idx];
        candidate.verification.max_retry_count = max_retries;
        candidate.entered_proof_mode = true;
        candidate.proof_rank = @intCast(proof_idx + 1);
        try setCandidateStatus(allocator, candidate, .unresolved, "candidate entered bounded proof-mode verification");
    }

    if (!workflow.build_available) {
        for (proof_queue) |candidate_idx| {
            const candidate = &result.candidates[candidate_idx];
            try setUnavailableVerificationStep(allocator, &candidate.verification.build, "no Linux-native build workflow was detected");
            try setUnavailableVerificationStep(allocator, &candidate.verification.test_step, "no Linux-native test workflow was detected");
            try setUnavailableVerificationStep(allocator, &candidate.verification.runtime_step, "no Linux-native runtime workflow was detected");
            try setCandidateStatus(allocator, candidate, .unresolved, "proof mode could not verify this candidate because no Linux-native build workflow was detected");
        }
        result.status = .unresolved;
        result.refactor_plan_status = .unresolved;
        result.stop_reason = .low_confidence;
        result.confidence = 0;
        result.unresolved_detail = try allocator.dupe(u8, "no Linux-native build workflow was detected; patch candidates remain draft_unvalidated");
        return;
    }

    const verification_session_root = try createVerificationSessionRoot(allocator, paths);
    defer {
        deleteTreeIfExists(verification_session_root) catch {};
        allocator.free(verification_session_root);
    }

    var proof_branch_ids = std.ArrayList(u32).init(allocator);
    defer proof_branch_ids.deinit();
    var proof_scores = std.ArrayList(u32).init(allocator);
    defer proof_scores.deinit();
    var proof_indexes = std.ArrayList(usize).init(allocator);
    defer proof_indexes.deinit();
    var best_survivor_score: ?u32 = null;

    for (proof_queue, 0..) |idx, proof_idx| {
        const candidate = &result.candidates[idx];
        if (candidate.status == .novel_but_unverified and candidate.verification.build.state == .unavailable) {
            continue;
        }
        if (best_survivor_score) |best_score| {
            const upper_bound = maxPotentialProofScore(candidate, workflow);
            if (upper_bound < best_score) {
                try skipDominatedProofCandidate(allocator, candidate, best_score, upper_bound);
                continue;
            }
        }
        const survived = try verifyCandidate(
            allocator,
            verification_session_root,
            options.repo_root,
            options.verification_path_override,
            workflow,
            result,
            options.effective_budget,
            max_retries,
            best_survivor_score,
            candidate,
        );
        if (!survived) {
            try pruneFocusedCandidatesAfterExpandedScopeFailure(
                allocator,
                result.candidates,
                proof_queue[proof_idx + 1 ..],
                candidate,
            );
            continue;
        }

        candidate.verification.proof_score = proofScore(candidate, workflow);
        candidate.verification.proof_confidence = candidate.verification.proof_score;
        if (candidate.verification.proof_reason) |reason| allocator.free(reason);
        candidate.verification.proof_reason = try allocator.dupe(u8, verificationSurvivorReason(candidate, workflow));
        try proof_branch_ids.append(@intCast(idx + 1));
        try proof_scores.append(candidate.verification.proof_score);
        try proof_indexes.append(idx);
        if (best_survivor_score == null or candidate.verification.proof_score > best_survivor_score.?) {
            best_survivor_score = candidate.verification.proof_score;
        }
    }

    if (proof_branch_ids.items.len == 0) {
        result.status = .unresolved;
        result.refactor_plan_status = .unresolved;
        result.stop_reason = .low_confidence;
        result.confidence = 0;
        result.unresolved_detail = try allocator.dupe(u8, "no patch candidate survived build/test verification");
        return;
    }

    const decision = mc.decideFromScores(proof_branch_ids.items, proof_scores.items, 1, @intCast(proof_branch_ids.items.len), .{
        .confidence_floor = .{ .min_score = 150 },
        .max_steps = 1,
        .max_branches = 4,
        .policy = mc.ReasoningPolicy.proof(),
    });
    result.stop_reason = decision.stop_reason;
    result.confidence = decision.confidence;

    if (decision.stop_reason != .none) {
        for (proof_indexes.items) |candidate_idx| {
            result.candidates[candidate_idx].validation_state = .proof_rejected;
            if (result.candidates[candidate_idx].verification.proof_reason) |reason| allocator.free(reason);
            result.candidates[candidate_idx].verification.proof_reason = try allocator.dupe(
                u8,
                "Layer 2 proof mode could not select a supported survivor without violating the honesty gate",
            );
            try setCandidateStatus(allocator, &result.candidates[candidate_idx], .unresolved, "proof mode could not support this verified survivor without violating the honesty gate");
        }
        result.status = .unresolved;
        result.refactor_plan_status = .unresolved;
        result.unresolved_detail = try allocator.dupe(u8, "verification survivors were rejected by proof-mode selection");
        return;
    }

    const selected_branch = decision.output;
    var selected_candidate_idx: ?usize = null;
    for (proof_indexes.items, 0..) |candidate_idx, proof_idx| {
        const branch_id = proof_branch_ids.items[proof_idx];
        if (branch_id == selected_branch) {
            selected_candidate_idx = candidate_idx;
            break;
        }
    }

    if (selected_candidate_idx == null) {
        for (proof_indexes.items) |candidate_idx| {
            try setCandidateStatus(allocator, &result.candidates[candidate_idx], .unresolved, "proof-mode selection returned an unknown candidate id");
        }
        result.status = .unresolved;
        result.refactor_plan_status = .unresolved;
        result.stop_reason = .internal_error;
        result.confidence = 0;
        result.unresolved_detail = try allocator.dupe(u8, "proof-mode selection returned an unknown patch candidate survivor");
        return;
    }

    const selected_candidate = &result.candidates[selected_candidate_idx.?];
    for (proof_indexes.items) |candidate_idx| {
        const candidate = &result.candidates[candidate_idx];
        if (candidate_idx == selected_candidate_idx.?) {
            if (candidate.validation_state != .runtime_verified) {
                candidate.validation_state = .build_test_verified;
            }
            candidate.verification.proof_confidence = decision.confidence;
            if (candidate.verification.proof_reason) |reason| allocator.free(reason);
            candidate.verification.proof_reason = try allocator.dupe(
                u8,
                if (candidate.validation_state == .runtime_verified)
                    "Layer 2 proof mode selected this runtime-verified survivor as the bounded winner"
                else
                    "Layer 2 proof mode selected this build/test-verified survivor as the bounded winner",
            );
            try setCandidateStatus(allocator, candidate, .supported, "proof mode verified and selected this survivor for final supported output");
        } else {
            candidate.validation_state = .proof_rejected;
            if (candidate.verification.proof_reason) |reason| allocator.free(reason);
            candidate.verification.proof_reason = try allocator.dupe(
                u8,
                "candidate passed verification but proof mode rejected it in favor of a stronger survivor",
            );
            if (candidate.minimality.total_cost > selected_candidate.minimality.total_cost) {
                const reason = try std.fmt.allocPrint(
                    allocator,
                    "rejected in favor of smaller verified scope {s} with lower minimality cost {d} < {d}",
                    .{ selected_candidate.scope, selected_candidate.minimality.total_cost, candidate.minimality.total_cost },
                );
                try setCandidateStatusOwned(allocator, candidate, .rejected, reason);
            } else {
                try setCandidateStatus(allocator, candidate, .rejected, "candidate passed verification but proof mode rejected it in favor of a stronger survivor");
            }
        }
    }

    if (result.selected_candidate_id) |candidate_id| allocator.free(candidate_id);
    result.selected_candidate_id = try allocator.dupe(u8, result.candidates[selected_candidate_idx.?].id);
    if (result.selected_strategy) |strategy| allocator.free(strategy);
    result.selected_strategy = try allocator.dupe(u8, selected_candidate.strategy);
    if (result.selected_refactor_scope) |scope| allocator.free(scope);
    result.selected_refactor_scope = try allocator.dupe(u8, selected_candidate.scope);
    result.status = .supported;
    result.refactor_plan_status = .verified_supported;
    if (result.handoff.proof.final_candidate_id) |candidate_id| allocator.free(candidate_id);
    result.handoff.proof.final_candidate_id = try allocator.dupe(u8, selected_candidate.id);
}

fn patchSupportEvidenceCount(result: *const Result) usize {
    return result.invariant_evidence.len + result.contradiction_evidence.len + result.abstraction_refs.len;
}

fn allowExploratoryPatchPlanning(intel: *const code_intel.Result) bool {
    if (intel.primary == null) return false;
    if (intel.status == .supported and intel.stop_reason == .none) return true;
    return countPatchPlanningAnchors(intel) > 0 or countUsableGroundingAnchors(intel) > 0;
}

fn countPatchPlanningAnchors(intel: *const code_intel.Result) usize {
    var count: usize = 0;
    for (intel.unresolved.partial_findings) |item| {
        if (item.rel_path == null) continue;
        if (item.kind == .fragment and item.line == 0) continue;
        count += 1;
    }
    return count;
}

fn countUsableGroundingAnchors(intel: *const code_intel.Result) usize {
    var count: usize = 0;
    for (intel.grounding_traces) |trace| {
        if (!trace.usable or trace.ambiguous or trace.target_rel_path == null) continue;
        count += 1;
    }
    return count;
}

fn proofAdmissionFailureDetail(allocator: std.mem.Allocator, intel: *const code_intel.Result) ![]u8 {
    if (intel.partial_support.blocking.ambiguous) {
        return allocator.dupe(u8, "exploratory patch candidates remained unresolved because ambiguous rationale cannot enter supported proof selection");
    }
    if (intel.partial_support.blocking.contradicted) {
        return allocator.dupe(u8, "exploratory patch candidates remained unresolved because contradicted rationale cannot enter supported proof selection");
    }
    if (intel.status != .supported or intel.stop_reason != .none) {
        return allocator.dupe(u8, "weak partial rationale improved bounded patch exploration but did not satisfy proof-admission guardrails");
    }
    return allocator.dupe(u8, "patch candidates lacked sufficiently grounded usable rationale for proof admission");
}

fn selectedCandidateHasExecutionEvidence(result: *const Result) bool {
    const selected_id = result.selected_candidate_id orelse return false;
    for (result.candidates) |candidate| {
        if (!std.mem.eql(u8, candidate.id, selected_id)) continue;
        if (candidate.verification.build.state != .passed) return false;
        if (candidate.verification.test_step.state == .passed) return true;
        if (candidate.verification.test_step.state == .unavailable and candidate.verification.runtime_step.state != .failed) return true;
        return candidate.verification.runtime_step.state == .passed;
    }
    return false;
}

fn patchSupportMinimumMet(result: *const Result) bool {
    if (result.status != .supported) return false;
    if (result.selected_candidate_id == null) return false;
    if (patchSupportEvidenceCount(result) == 0) return false;
    if (!selectedCandidateHasExecutionEvidence(result)) return false;
    return result.handoff.proof.supported_count > 0;
}

fn blockingFlagsFromPatch(result: *const Result) code_intel.BlockingFlags {
    return .{
        .ambiguous = stringContains(result.unresolved_detail, "ambiguous"),
        .contradicted = result.contradiction_evidence.len > 0 or result.contradiction_kind != null,
        .insufficient = !patchSupportMinimumMet(result),
        .stale = stringContains(result.unresolved_detail, "stale"),
        .out_of_scope = stringContains(result.unresolved_detail, "out of scope"),
    };
}

fn stringContains(text: ?[]const u8, needle: []const u8) bool {
    const value = text orelse return false;
    return std.mem.indexOf(u8, value, needle) != null;
}

fn derivePatchPartialSupport(allocator: std.mem.Allocator, result: *Result) !void {
    const blocking = blockingFlagsFromPatch(result);
    result.partial_support = .{
        .lattice = blk: {
            if (result.status != .supported) {
                for (result.candidates) |candidate| {
                    if (candidate.verification.build.state == .passed or candidate.verification.test_step.state == .passed or candidate.verification.runtime_step.state == .passed) {
                        break :blk .locally_verified;
                    }
                }
            }
            if (result.invariant_evidence.len > 0 or result.candidates.len > 0) break :blk .scoped;
            if (result.strategy_hypotheses.len > 0 or result.request_label.len > 0) break :blk .fragmentary;
            break :blk .void;
        },
        .blocking = blocking,
    };

    if (result.status == .supported) return;

    var partial_findings = std.ArrayList(code_intel.PartialFinding).init(allocator);
    errdefer {
        for (partial_findings.items) |*item| item.deinit(allocator);
        partial_findings.deinit();
    }
    var ambiguity_sets = std.ArrayList(code_intel.AmbiguitySet).init(allocator);
    errdefer {
        for (ambiguity_sets.items) |*item| item.deinit(allocator);
        ambiguity_sets.deinit();
    }
    var missing_obligations = std.ArrayList(code_intel.MissingObligation).init(allocator);
    errdefer {
        for (missing_obligations.items) |*item| item.deinit(allocator);
        missing_obligations.deinit();
    }
    var suppressed_noise = std.ArrayList(code_intel.SuppressedNoise).init(allocator);
    errdefer {
        for (suppressed_noise.items) |*item| item.deinit(allocator);
        suppressed_noise.deinit();
    }
    var freshness_checks = std.ArrayList(code_intel.FreshnessCheck).init(allocator);
    errdefer {
        for (freshness_checks.items) |*item| item.deinit(allocator);
        freshness_checks.deinit();
    }

    try appendPlanningBasisUnresolved(
        allocator,
        result,
        &partial_findings,
        &ambiguity_sets,
        &missing_obligations,
        &suppressed_noise,
        &freshness_checks,
    );

    for (result.strategy_hypotheses, 0..) |item, idx| {
        if (idx < 2) {
            const detail = try std.fmt.allocPrint(allocator, "strategy score={d}; evidence_count={d}", .{ item.score, item.evidence_count });
            defer allocator.free(detail);
            try partial_findings.append(.{
                .kind = .fragment,
                .label = try allocator.dupe(u8, item.label),
                .scope = try allocator.dupe(u8, result.request_label),
                .provenance = try allocator.dupe(u8, "strategy_hypothesis"),
                .detail = try allocator.dupe(u8, detail),
            });
        }
    }
    for (result.invariant_evidence, 0..) |item, idx| {
        if (idx >= 2) break;
        try partial_findings.append(.{
            .kind = .scoped_claim,
            .label = try allocator.dupe(u8, item.label),
            .scope = try allocator.dupe(u8, result.request_label),
            .provenance = try allocator.dupe(u8, "invariant_evidence"),
            .rel_path = if (item.rel_path) |path| try allocator.dupe(u8, path) else null,
            .line = item.line,
            .detail = if (item.reason) |reason| try allocator.dupe(u8, reason) else null,
        });
    }
    for (result.candidates, 0..) |candidate, idx| {
        if (idx < 2) {
            const provenance = if (candidate.validation_state == .build_test_verified or candidate.validation_state == .runtime_verified or candidate.verification.build.state == .passed or candidate.verification.test_step.state == .passed or candidate.verification.runtime_step.state == .passed)
                "candidate_local_verification"
            else
                "candidate_scope";
            try partial_findings.append(.{
                .kind = if (std.mem.eql(u8, provenance, "candidate_local_verification")) .locally_verified else .scoped_claim,
                .label = try allocator.dupe(u8, candidate.summary),
                .scope = try allocator.dupe(u8, candidate.scope),
                .provenance = try allocator.dupe(u8, provenance),
                .detail = try allocator.dupe(u8, candidate.status_reason orelse "candidate remained bounded and non-authorizing"),
            });
        } else {
            try suppressed_noise.append(.{
                .label = try allocator.dupe(u8, candidate.summary),
                .reason = try allocator.dupe(u8, "extra patch candidate suppressed from unresolved summary"),
            });
        }
    }
    if (partial_findings.items.len == 0) {
        try partial_findings.append(.{
            .kind = .fragment,
            .label = try allocator.dupe(u8, result.request_label),
            .scope = try allocator.dupe(u8, result.request_label),
            .provenance = try allocator.dupe(u8, "request_label"),
            .detail = try allocator.dupe(u8, "request preserved as a bounded unresolved patch fragment"),
        });
    }

    if (blocking.ambiguous and result.strategy_hypotheses.len > 1) {
        var options = std.ArrayList(code_intel.AmbiguityOption).init(allocator);
        errdefer {
            for (options.items) |*item| item.deinit(allocator);
            options.deinit();
        }
        for (result.strategy_hypotheses) |item| {
            if (options.items.len >= 4) break;
            try options.append(.{ .label = try allocator.dupe(u8, item.label) });
        }
        try ambiguity_sets.append(.{
            .label = try allocator.dupe(u8, "strategy_ambiguity"),
            .scope = try allocator.dupe(u8, result.request_label),
            .reason = if (result.unresolved_detail) |detail| try allocator.dupe(u8, detail) else null,
            .options = try options.toOwnedSlice(),
        });
    }

    if (result.selected_candidate_id == null) {
        try missing_obligations.append(.{
            .label = try allocator.dupe(u8, "select_patch_candidate"),
            .scope = try allocator.dupe(u8, result.request_label),
            .detail = try allocator.dupe(u8, "no candidate survived bounded proof selection"),
        });
    }
    if (!selectedCandidateHasExecutionEvidence(result)) {
        try missing_obligations.append(.{
            .label = try allocator.dupe(u8, "obtain_linux_verification"),
            .scope = try allocator.dupe(u8, result.request_label),
            .detail = try allocator.dupe(u8, "partial patch findings remain non-authorizing without bounded verification"),
        });
    }

    try freshness_checks.append(.{
        .label = try allocator.dupe(u8, "workspace_freshness"),
        .scope = try allocator.dupe(u8, result.request_label),
        .state = if (blocking.stale) .stale else .not_needed,
        .detail = try allocator.dupe(u8, if (blocking.stale) "patch partials reference stale support" else "patch partials reference the current bounded workspace snapshot only"),
    });

    result.unresolved = .{
        .allocator = allocator,
        .partial_findings = try partial_findings.toOwnedSlice(),
        .ambiguity_sets = try ambiguity_sets.toOwnedSlice(),
        .missing_obligations = try missing_obligations.toOwnedSlice(),
        .suppressed_noise = try suppressed_noise.toOwnedSlice(),
        .freshness_checks = try freshness_checks.toOwnedSlice(),
    };
}

fn appendPlanningBasisUnresolved(
    allocator: std.mem.Allocator,
    result: *const Result,
    partial_findings: *std.ArrayList(code_intel.PartialFinding),
    ambiguity_sets: *std.ArrayList(code_intel.AmbiguitySet),
    missing_obligations: *std.ArrayList(code_intel.MissingObligation),
    suppressed_noise: *std.ArrayList(code_intel.SuppressedNoise),
    freshness_checks: *std.ArrayList(code_intel.FreshnessCheck),
) !void {
    for (result.planning_basis.partial_findings, 0..) |item, idx| {
        if (idx >= 2) {
            try suppressed_noise.append(.{
                .label = try allocator.dupe(u8, item.label),
                .reason = try allocator.dupe(u8, "extra upstream partial finding suppressed from patch unresolved summary"),
                .rel_path = if (item.rel_path) |path| try allocator.dupe(u8, path) else null,
                .line = item.line,
            });
            continue;
        }
        try partial_findings.append(try clonePartialFinding(allocator, item));
    }
    for (result.planning_basis.ambiguity_sets, 0..) |item, idx| {
        if (idx >= 1) break;
        try ambiguity_sets.append(try cloneAmbiguitySet(allocator, item));
    }
    for (result.planning_basis.missing_obligations, 0..) |item, idx| {
        if (idx >= 2) break;
        try missing_obligations.append(try cloneMissingObligation(allocator, item));
    }
    for (result.planning_basis.freshness_checks, 0..) |item, idx| {
        if (idx >= 1) break;
        try freshness_checks.append(try cloneFreshnessCheck(allocator, item));
    }
}

fn finalizePatchSupportGraph(allocator: std.mem.Allocator, result: *Result) !void {
    if (result.status == .supported and !patchSupportMinimumMet(result)) {
        result.status = .unresolved;
        result.stop_reason = .low_confidence;
        result.confidence = 0;
        if (result.unresolved_detail) |detail| allocator.free(detail);
        result.unresolved_detail = try allocator.dupe(u8, "patch result lacked the minimum bounded support required for final permission");
    }
    try derivePatchPartialSupport(allocator, result);
    result.support_graph = try buildPatchSupportGraph(allocator, result);
}

fn buildPatchSupportGraph(allocator: std.mem.Allocator, result: *const Result) !code_intel.SupportGraph {
    var nodes = std.ArrayList(code_intel.SupportGraphNode).init(allocator);
    errdefer {
        for (nodes.items) |node| {
            allocator.free(node.id);
            allocator.free(node.label);
            if (node.rel_path) |rel_path| allocator.free(rel_path);
            if (node.detail) |detail| allocator.free(detail);
        }
        nodes.deinit();
    }
    var edges = std.ArrayList(code_intel.SupportGraphEdge).init(allocator);
    errdefer {
        for (edges.items) |edge| {
            allocator.free(edge.from_id);
            allocator.free(edge.to_id);
        }
        edges.deinit();
    }

    try appendPatchSupportNode(allocator, &nodes, "output", .output, @tagName(result.status), null, 0, result.confidence, result.status == .supported, result.unresolved_detail);
    try appendPatchSupportNode(allocator, &nodes, "shard", .shard, result.shard_id, null, 0, 0, true, @tagName(result.shard_kind));
    try appendPatchSupportNode(allocator, &nodes, "exploration", .handoff, mc.reasoningModeName(result.handoff.exploration.mode), null, 0, result.handoff.exploration.generated_candidate_count, true, "exploration");
    try appendPatchSupportNode(allocator, &nodes, "proof", .handoff, mc.reasoningModeName(result.handoff.proof.mode), null, 0, result.handoff.proof.supported_count, true, "proof");
    try appendPatchSupportEdge(allocator, &edges, "output", "shard", .sourced_from);
    if (result.intent) |intent| {
        try appendPatchSupportNode(
            allocator,
            &nodes,
            "intent",
            .intent,
            task_intent.actionName(intent.action),
            null,
            0,
            0,
            intent.status == .grounded,
            intent.unresolved_detail,
        );
        try appendPatchSupportEdge(allocator, &edges, "output", "intent", .requested_by);
    }
    try appendPatchSupportEdge(allocator, &edges, "output", "proof", .derived_in);
    try appendPatchSupportEdge(allocator, &edges, "proof", "exploration", .handoff_from);

    if (result.code_intel_result_path.len > 0) {
        try appendPatchSupportNode(allocator, &nodes, "code_intel", .reasoning, result.code_intel_result_path, null, 0, 0, true, "code_intel_result");
        try appendPatchSupportEdge(allocator, &edges, "output", "code_intel", .derived_in);
    }
    if (result.selected_strategy) |strategy| {
        try appendPatchSupportNode(allocator, &nodes, "strategy", .query_hypothesis, strategy, null, 0, if (result.strategy_hypotheses.len > 0) result.strategy_hypotheses[0].score else 0, true, "selected_strategy");
        try appendPatchSupportEdge(allocator, &edges, "output", "strategy", .selected_by);
    }
    if (result.selected_candidate_id) |candidate_id| {
        try appendPatchSupportNode(allocator, &nodes, "candidate", .output, candidate_id, null, 0, result.confidence, true, "selected_candidate");
        try appendPatchSupportEdge(allocator, &edges, "output", "candidate", .selected_from);
        if (selectedCandidateById(result, candidate_id)) |candidate| {
            try appendCandidateRewriteNodes(allocator, &nodes, &edges, "candidate", candidate);
        }
    }

    var execution_node_count: usize = 0;
    var repair_node_count: usize = 0;
    for (result.candidates) |candidate| {
        if (!candidate.entered_proof_mode) continue;
        try appendCandidateExecutionNodes(allocator, &nodes, &edges, "output", candidate, &execution_node_count);
        try appendCandidateRepairNodes(allocator, &nodes, &edges, "output", candidate, &repair_node_count);
        if (execution_node_count >= 6) break;
    }

    for (result.invariant_evidence, 0..) |item, idx| {
        if (idx >= 4) break;
        const node_id = try std.fmt.allocPrint(allocator, "evidence_{d}", .{idx + 1});
        defer allocator.free(node_id);
        try appendPatchSupportNode(allocator, &nodes, node_id, .evidence, item.label, item.rel_path, item.line, item.score, true, item.reason);
        try appendPatchSupportEdge(allocator, &edges, "output", node_id, .supported_by);
    }
    for (result.contradiction_evidence, 0..) |item, idx| {
        if (idx >= 4) break;
        const node_id = try std.fmt.allocPrint(allocator, "contradiction_{d}", .{idx + 1});
        defer allocator.free(node_id);
        try appendPatchSupportNode(allocator, &nodes, node_id, .contradiction, item.label, item.rel_path, item.line, item.score, true, item.reason);
        try appendPatchSupportEdge(allocator, &edges, "output", node_id, .checked_by);
    }
    for (result.abstraction_refs, 0..) |item, idx| {
        if (idx >= 4) break;
        const node_id = try std.fmt.allocPrint(allocator, "abstraction_{d}", .{idx + 1});
        defer allocator.free(node_id);
        try appendPatchSupportNode(allocator, &nodes, node_id, .abstraction, item.label, item.rel_path, item.line, item.score, true, item.reason);
        try appendPatchSupportEdge(allocator, &edges, "output", node_id, .supported_by);
    }
    for (result.source_abstraction_traces, 0..) |item, idx| {
        if (idx >= 4) break;
        if (!std.mem.startsWith(u8, item.owner_id, "pack/")) continue;
        const node_id = try std.fmt.allocPrint(allocator, "pack_abstraction_{d}", .{idx + 1});
        defer allocator.free(node_id);
        const detail = try std.fmt.allocPrint(allocator, "{s}; trust={s}; pack_outcome={s}; pack_conflict={s}", .{
            item.source_spec,
            abstractions.trustClassName(item.trust_class),
            abstractions.packRoutingStatusName(item.pack_outcome),
            abstractions.packConflictCategoryName(item.pack_conflict_category),
        });
        defer allocator.free(detail);
        try appendPatchSupportNode(allocator, &nodes, node_id, .abstraction, item.label, null, 0, item.lookup_score, item.usable, detail);
        try appendPatchSupportEdge(allocator, &edges, "output", node_id, .supported_by);
    }
    for (result.pack_routing_traces, 0..) |item, idx| {
        if (idx >= 6) break;
        const node_id = try std.fmt.allocPrint(allocator, "pack_{d}", .{idx + 1});
        defer allocator.free(node_id);
        const detail = try std.fmt.allocPrint(allocator, "{s}; policy={s}; trust={s}; freshness={s}; category={s}; score={d}; considered={d}; activated={d}; candidates={d}/{d}", .{
            item.reason,
            abstractions.packCompetitionPolicyName(item.policy.competition),
            abstractions.trustClassName(item.trust_class),
            knowledge_pack_store.packFreshnessName(item.freshness_state),
            abstractions.packConflictCategoryName(item.conflict_category),
            item.score,
            item.considered_rank,
            item.activation_rank,
            item.candidate_surfaces,
            item.suppressed_candidates,
        });
        defer allocator.free(detail);
        try appendPatchSupportNode(allocator, &nodes, node_id, .pack, item.owner_id, null, 0, item.score, item.status == .activated, detail);
        try appendPatchSupportEdge(allocator, &edges, "proof", node_id, if (item.status == .activated) .selected_by else .suppressed_by);
    }
    for (result.grounding_traces, 0..) |item, idx| {
        if (idx >= 3) break;
        if (!std.mem.startsWith(u8, item.owner_id, "pack/") and !std.mem.startsWith(u8, item.source_spec, "@pack/")) continue;
        const node_id = try std.fmt.allocPrint(allocator, "grounding_{d}", .{idx + 1});
        defer allocator.free(node_id);
        try appendPatchSupportNode(allocator, &nodes, node_id, .grounding, item.concept, item.target_rel_path, item.target_line, item.mapping_score, item.usable and !item.ambiguous, item.detail);
        try appendPatchSupportEdge(allocator, &edges, "output", node_id, .grounded_by);
    }
    for (result.reverse_grounding_traces, 0..) |item, idx| {
        if (idx >= 3) break;
        if (!std.mem.startsWith(u8, item.owner_id, "pack/") and !std.mem.startsWith(u8, item.source_spec, "@pack/")) continue;
        const node_id = try std.fmt.allocPrint(allocator, "reverse_grounding_{d}", .{idx + 1});
        defer allocator.free(node_id);
        try appendPatchSupportNode(allocator, &nodes, node_id, .reverse_grounding, item.target_label orelse item.source_spec, item.target_rel_path orelse item.source_spec, item.target_line, item.mapping_score, item.usable and !item.ambiguous, item.detail);
        try appendPatchSupportEdge(allocator, &edges, "output", node_id, .grounded_by);
    }

    if (result.status != .supported and result.unresolved_detail != null) {
        try appendPatchSupportNode(allocator, &nodes, "gap", .gap, "support_gap", null, 0, 0, false, result.unresolved_detail);
        try appendPatchSupportEdge(allocator, &edges, "output", "gap", .blocked_by);
    }
    try code_intel.appendUnresolvedSupportGraph(allocator, &nodes, &edges, "output", result.partial_support, &result.unresolved);

    return .{
        .allocator = allocator,
        .permission = result.status,
        .minimum_met = patchSupportMinimumMet(result),
        .partial_support = result.partial_support,
        .flow_mode = try allocator.dupe(u8, "explore_then_proof"),
        .unresolved_reason = if (result.unresolved_detail) |detail| try allocator.dupe(u8, detail) else null,
        .nodes = try nodes.toOwnedSlice(),
        .edges = try edges.toOwnedSlice(),
    };
}

fn appendCandidateExecutionNodes(
    allocator: std.mem.Allocator,
    nodes: *std.ArrayList(code_intel.SupportGraphNode),
    edges: *std.ArrayList(code_intel.SupportGraphEdge),
    parent_id: []const u8,
    candidate: Candidate,
    execution_node_count: *usize,
) !void {
    try appendVerificationSupportNode(allocator, nodes, edges, parent_id, candidate, candidate.verification.build, "build", execution_node_count);
    try appendVerificationSupportNode(allocator, nodes, edges, parent_id, candidate, candidate.verification.test_step, "test", execution_node_count);
    try appendVerificationSupportNode(allocator, nodes, edges, parent_id, candidate, candidate.verification.runtime_step, "runtime", execution_node_count);
}

fn appendCandidateRepairNodes(
    allocator: std.mem.Allocator,
    nodes: *std.ArrayList(code_intel.SupportGraphNode),
    edges: *std.ArrayList(code_intel.SupportGraphEdge),
    parent_id: []const u8,
    candidate: Candidate,
    repair_node_count: *usize,
) !void {
    for (candidate.verification.repair_plans) |plan| {
        if (repair_node_count.* >= 4) return;
        const node_id = try std.fmt.allocPrint(allocator, "repair_{d}", .{repair_node_count.* + 1});
        defer allocator.free(node_id);
        const label = try std.fmt.allocPrint(allocator, "{s} repair {s} {s}", .{
            candidate.id,
            repairStrategyName(plan.strategy),
            repairPlanOutcomeName(plan.outcome),
        });
        defer allocator.free(label);
        const detail = try std.fmt.allocPrint(
            allocator,
            "trigger={s}; expected_target={s}; parent={s}; descendant={s}; retained_hunks={d}; why={s}; outcome={s}",
            .{
                plan.trigger_summary,
                execution.phaseName(plan.expected_verification_target),
                plan.lineage_parent_id,
                plan.descendant_id,
                plan.retained_hunk_count,
                plan.evidence_summary,
                plan.outcome_summary orelse "pending",
            },
        );
        defer allocator.free(detail);
        try appendPatchSupportNode(
            allocator,
            nodes,
            node_id,
            .query_hypothesis,
            label,
            candidatePrimaryRelPath(candidate.trace),
            candidatePrimaryLine(candidate.trace),
            candidate.score,
            plan.outcome == .improved,
            detail,
        );
        try appendPatchSupportEdge(allocator, edges, parent_id, node_id, .checked_by);
        repair_node_count.* += 1;
    }
}

fn appendCandidateRewriteNodes(
    allocator: std.mem.Allocator,
    nodes: *std.ArrayList(code_intel.SupportGraphNode),
    edges: *std.ArrayList(code_intel.SupportGraphEdge),
    parent_id: []const u8,
    candidate: Candidate,
) !void {
    for (candidate.rewrite_operators, 0..) |operator_kind, idx| {
        if (idx >= 6) break;
        const node_id = try std.fmt.allocPrint(allocator, "rewrite_{d}", .{idx + 1});
        defer allocator.free(node_id);
        const detail = candidateRewriteReason(candidate.trace, operator_kind);
        try appendPatchSupportNode(
            allocator,
            nodes,
            node_id,
            .rewrite_operator,
            rewriteOperatorName(operator_kind),
            candidatePrimaryRelPath(candidate.trace),
            candidatePrimaryLine(candidate.trace),
            candidate.score,
            true,
            detail,
        );
        try appendPatchSupportEdge(allocator, edges, parent_id, node_id, .supported_by);
    }
}

fn candidatePrimaryRelPath(trace: []const SupportTrace) ?[]const u8 {
    for (trace) |item| {
        if (item.rel_path != null and item.kind == .code_intel_primary) return item.rel_path.?;
    }
    for (trace) |item| {
        if (item.rel_path != null) return item.rel_path.?;
    }
    return null;
}

fn candidatePrimaryLine(trace: []const SupportTrace) u32 {
    for (trace) |item| {
        if (item.kind == .code_intel_primary and item.line != 0) return item.line;
    }
    for (trace) |item| {
        if (item.line != 0) return item.line;
    }
    return 0;
}

fn candidateRewriteReason(trace: []const SupportTrace, operator_kind: RewriteOperator) ?[]const u8 {
    const label = rewriteOperatorName(operator_kind);
    for (trace) |item| {
        if (item.kind != .rewrite_operator) continue;
        if (!std.mem.eql(u8, item.label, label)) continue;
        return item.reason;
    }
    return null;
}

fn selectedCandidateById(result: *const Result, candidate_id: []const u8) ?Candidate {
    for (result.candidates) |candidate| {
        if (std.mem.eql(u8, candidate.id, candidate_id)) return candidate;
    }
    return null;
}

fn appendVerificationSupportNode(
    allocator: std.mem.Allocator,
    nodes: *std.ArrayList(code_intel.SupportGraphNode),
    edges: *std.ArrayList(code_intel.SupportGraphEdge),
    parent_id: []const u8,
    candidate: Candidate,
    step: VerificationStep,
    phase_name: []const u8,
    execution_node_count: *usize,
) !void {
    if (step.state == .unavailable) return;
    if (execution_node_count.* >= 6) return;

    const adapter_node_id = try std.fmt.allocPrint(allocator, "verifier_adapter_{d}", .{execution_node_count.* + 1});
    defer allocator.free(adapter_node_id);
    const run_node_id = try std.fmt.allocPrint(allocator, "verifier_run_{d}", .{execution_node_count.* + 1});
    defer allocator.free(run_node_id);
    const evidence_node_id = try std.fmt.allocPrint(allocator, "verifier_evidence_{d}", .{execution_node_count.* + 1});
    defer allocator.free(evidence_node_id);
    const label = try std.fmt.allocPrint(allocator, "{s} {s} {s}", .{
        candidate.id,
        phase_name,
        if (step.state == .passed) "passed" else "failed",
    });
    defer allocator.free(label);
    const detail = try verificationStepDetail(allocator, candidate, step);
    defer allocator.free(detail);
    try appendPatchSupportNode(
        allocator,
        nodes,
        adapter_node_id,
        .verifier_adapter,
        step.adapter_id orelse adapterIdForPhaseName(phase_name),
        null,
        0,
        0,
        false,
        "verifier capability only; support still depends on proof graph gates",
    );
    try appendPatchSupportEdge(allocator, edges, parent_id, adapter_node_id, .required_by);
    try appendPatchSupportNode(
        allocator,
        nodes,
        run_node_id,
        .verifier_run,
        label,
        null,
        0,
        candidate.score,
        step.state == .passed,
        detail,
    );
    try appendPatchSupportEdge(allocator, edges, adapter_node_id, run_node_id, .verifies);
    try appendPatchSupportEdge(allocator, edges, parent_id, run_node_id, .checked_by);
    try appendPatchSupportNode(
        allocator,
        nodes,
        evidence_node_id,
        if (step.state == .failed) .verifier_failure else .verifier_evidence,
        if (step.evidence_kind) |kind| verifier_adapter.evidenceKindName(kind) else phase_name,
        null,
        0,
        candidate.score,
        step.state == .passed,
        step.evidence orelse step.summary,
    );
    try appendPatchSupportEdge(allocator, edges, run_node_id, evidence_node_id, .produced_evidence);
    if (step.state == .passed) {
        try appendPatchSupportEdge(allocator, edges, evidence_node_id, parent_id, .discharges);
    } else {
        try appendPatchSupportEdge(allocator, edges, parent_id, evidence_node_id, .failed_by);
    }
    execution_node_count.* += 1;

    if (step.state == .failed) {
        const contradiction_id = try std.fmt.allocPrint(allocator, "execution_contradiction_{d}", .{execution_node_count.*});
        defer allocator.free(contradiction_id);
        const contradiction_label = try std.fmt.allocPrint(allocator, "{s} {s} contradicted bounded verification expectations", .{ candidate.id, phase_name });
        defer allocator.free(contradiction_label);
        try appendPatchSupportNode(
            allocator,
            nodes,
            contradiction_id,
            .contradiction,
            contradiction_label,
            null,
            0,
            0,
            false,
            detail,
        );
        try appendPatchSupportEdge(allocator, edges, parent_id, contradiction_id, .blocked_by);
    }
}

fn verificationStepDetail(allocator: std.mem.Allocator, candidate: Candidate, step: VerificationStep) ![]u8 {
    const exit_text = if (step.exit_code) |code|
        try std.fmt.allocPrint(allocator, "{d}", .{code})
    else
        try allocator.dupe(u8, "none");
    defer allocator.free(exit_text);

    return std.fmt.allocPrint(
        allocator,
        "candidate={s}; adapter={s}; status={s}; exit_code={s}; duration_ms={d}; failure_signal={s}; summary={s}",
        .{
            candidate.id,
            step.adapter_id orelse "none",
            verificationStepStateName(step.state),
            exit_text,
            step.duration_ms,
            if (step.failure_signal) |signal| execution.failureSignalName(signal) else "none",
            if (step.summary) |summary| summary else "none",
        },
    );
}

fn adapterIdForPhaseName(phase_name: []const u8) []const u8 {
    if (std.mem.eql(u8, phase_name, "build")) return "code.build.zig_build";
    if (std.mem.eql(u8, phase_name, "test")) return "code.test.zig_build_test";
    if (std.mem.eql(u8, phase_name, "runtime")) return "code.runtime.oracle";
    return "custom.external.verifier";
}

fn evidenceKindForPhaseName(phase_name: []const u8) verifier_adapter.EvidenceKind {
    if (std.mem.eql(u8, phase_name, "build")) return .build_log;
    if (std.mem.eql(u8, phase_name, "test")) return .test_log;
    if (std.mem.eql(u8, phase_name, "runtime")) return .runtime_oracle;
    return .external_report;
}

fn appendPatchSupportNode(
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

fn appendPatchSupportEdge(
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

fn failureStateRank(state: ValidationState) u8 {
    return switch (state) {
        .build_failed => 1,
        .test_failed => 2,
        .runtime_failed, .runtime_unresolved => 3,
        else => 0,
    };
}

fn noteObservedFailureState(candidate: *Candidate, state: ValidationState) void {
    if (failureStateRank(state) >= failureStateRank(candidate.validation_state)) {
        candidate.validation_state = state;
    }
}

fn failureStatusReason(state: ValidationState) []const u8 {
    return switch (state) {
        .build_failed => "candidate failed Linux build verification",
        .test_failed => "candidate failed Linux test verification",
        .runtime_failed => "candidate failed bounded runtime oracle verification",
        .runtime_unresolved => "runtime verification remained unresolved because runtime oracle support was insufficient",
        else => "candidate verification failed",
    };
}

fn finalizeCandidateFailure(allocator: std.mem.Allocator, candidate: *Candidate, state: ValidationState) !void {
    noteObservedFailureState(candidate, state);
    try setCandidateStatus(
        allocator,
        candidate,
        if (candidate.validation_state == .runtime_unresolved) .unresolved else .rejected,
        failureStatusReason(candidate.validation_state),
    );
}

fn verifyCandidate(
    allocator: std.mem.Allocator,
    verification_session_root: []const u8,
    repo_root: []const u8,
    path_override: ?[]const u8,
    workflow: VerificationWorkflow,
    result: *Result,
    effective_budget: compute_budget.Effective,
    max_retries: u32,
    best_survivor_score: ?u32,
    candidate: *Candidate,
) !bool {
    var attempt: u32 = 0;
    var active_repair_index: ?usize = null;
    while (attempt <= max_retries) : (attempt += 1) {
        var application = RepairApplication{};
        var workspace_candidate_id: []const u8 = candidate.id;
        if (active_repair_index) |repair_index| {
            const repair_plan = candidate.verification.repair_plans[repair_index];
            application = repairApplicationForPlan(candidate, repair_plan);
            workspace_candidate_id = repair_plan.descendant_id;
            try appendRefinementTrace(
                allocator,
                &candidate.verification,
                attempt,
                repairStrategyName(repair_plan.strategy),
                repair_plan.evidence_summary,
                repair_plan.retained_hunk_count,
            );
        }

        const workspace_started = sys.getMilliTick();
        const workspace_root = try createVerificationWorkspace(allocator, verification_session_root, repo_root, workspace_candidate_id, attempt);
        result.profile.workspace_prepare_ms += sys.getMilliTick() - workspace_started;
        defer {
            deleteTreeIfExists(workspace_root) catch {};
            allocator.free(workspace_root);
        }

        try applyCandidateToWorkspace(allocator, workspace_root, candidate, application);
        if (active_repair_index) |repair_index| {
            const repair_plan = candidate.verification.repair_plans[repair_index];
            try applyRepairStrategyToWorkspace(allocator, workspace_root, candidate, repair_plan);
        }

        const build_started = sys.getMilliTick();
        var build_capture = try execution.run(allocator, .{
            .workspace_root = workspace_root,
            .cwd = workspace_root,
            .path_override = path_override,
            .max_output_bytes = @min(MAX_VERIFICATION_OUTPUT_BYTES, effective_budget.max_temp_work_bytes),
        }, .{
            .label = "zig_build",
            .kind = .zig_build,
            .phase = execution.Phase.build,
            .argv = &.{ "zig", "build" },
            .expectations = &.{.{ .success = {} }},
            .timeout_ms = boundedVerifierTimeout(effective_budget, MAX_VERIFICATION_TIMEOUT_MS),
        });
        result.profile.build_exec_ms += sys.getMilliTick() - build_started;
        defer build_capture.deinit(allocator);
        const preserve_prior_build = shouldPreserveDeeperVerificationStep(candidate.verification, active_repair_index != null, execution.Phase.build, !build_capture.succeeded());
        if (!preserve_prior_build) {
            const dispatch_started = sys.getMilliTick();
            try updateVerificationStep(
                allocator,
                &candidate.verification.build,
                &build_capture,
                attempt,
                max_retries,
                "build",
            );
            result.profile.verifier_adapter_dispatch_ms += sys.getMilliTick() - dispatch_started;
        }
        if (!build_capture.succeeded()) {
            noteObservedFailureState(candidate, .build_failed);
            if (try maybeQueueRepairPlan(
                allocator,
                candidate,
                &active_repair_index,
                execution.Phase.build,
                &build_capture,
                attempt,
                max_retries,
            )) {
                candidate.verification.retry_count = attempt + 1;
                continue;
            }
            if (active_repair_index) |repair_index| try setRepairPlanOutcome(
                allocator,
                &candidate.verification,
                repair_index,
                .failed,
                "repaired descendant still failed Linux build verification",
            );
            try finalizeCandidateFailure(allocator, candidate, .build_failed);
            return false;
        }

        if (workflow.test_available) {
            const test_started = sys.getMilliTick();
            var test_capture = try execution.run(allocator, .{
                .workspace_root = workspace_root,
                .cwd = workspace_root,
                .path_override = path_override,
                .max_output_bytes = @min(MAX_VERIFICATION_OUTPUT_BYTES, effective_budget.max_temp_work_bytes),
            }, .{
                .label = "zig_build_test",
                .kind = .zig_build,
                .phase = execution.Phase.@"test",
                .argv = &.{ "zig", "build", "test" },
                .expectations = &.{.{ .success = {} }},
                .timeout_ms = boundedVerifierTimeout(effective_budget, MAX_VERIFICATION_TIMEOUT_MS),
            });
            result.profile.test_exec_ms += sys.getMilliTick() - test_started;
            defer test_capture.deinit(allocator);
            const preserve_prior_test = shouldPreserveDeeperVerificationStep(candidate.verification, active_repair_index != null, execution.Phase.@"test", !test_capture.succeeded());
            if (!preserve_prior_test) {
                const dispatch_started = sys.getMilliTick();
                try updateVerificationStep(
                    allocator,
                    &candidate.verification.test_step,
                    &test_capture,
                    attempt,
                    max_retries,
                    "test",
                );
                result.profile.verifier_adapter_dispatch_ms += sys.getMilliTick() - dispatch_started;
            }
            if (!test_capture.succeeded()) {
                noteObservedFailureState(candidate, .test_failed);
                if (try maybeQueueRepairPlan(
                    allocator,
                    candidate,
                    &active_repair_index,
                    execution.Phase.@"test",
                    &test_capture,
                    attempt,
                    max_retries,
                )) {
                    candidate.verification.retry_count = attempt + 1;
                    continue;
                }
                if (active_repair_index) |repair_index| try setRepairPlanOutcome(
                    allocator,
                    &candidate.verification,
                    repair_index,
                    .failed,
                    "repaired descendant still failed Linux test verification",
                );
                try finalizeCandidateFailure(allocator, candidate, .test_failed);
                return false;
            }
        } else {
            try setUnavailableVerificationStep(allocator, &candidate.verification.test_step, "no Linux-native test workflow was detected");
        }

        if (workflow.runtime_oracle_load_error) |detail| {
            try setUnavailableVerificationStep(allocator, &candidate.verification.runtime_step, detail);
            if (active_repair_index) |repair_index| try setRepairPlanOutcome(
                allocator,
                &candidate.verification,
                repair_index,
                .insufficient_evidence,
                "repair descendant remained unresolved because runtime oracle support was insufficient",
            );
            try finalizeCandidateFailure(allocator, candidate, .runtime_unresolved);
            return false;
        }

        if (best_survivor_score) |best_score| {
            const upper_bound = maxPotentialProofScore(candidate, workflow);
            if (upper_bound < best_score) {
                const summary = try std.fmt.allocPrint(
                    allocator,
                    "runtime verification was skipped because a verified survivor already reached proof score {d}, above this candidate's maximum reachable score {d}",
                    .{ best_score, upper_bound },
                );
                defer allocator.free(summary);
                try setUnavailableVerificationStep(allocator, &candidate.verification.runtime_step, summary);
                candidate.validation_state = .build_test_verified;
                if (active_repair_index) |repair_index| try setRepairPlanOutcome(
                    allocator,
                    &candidate.verification,
                    repair_index,
                    .improved,
                    "candidate survived build/test verification after runtime was pruned by an unbeatable verified survivor",
                );
                candidate.verification.retry_count = attempt;
                return true;
            }
        }

        if (workflow.runtime_oracle) |oracle| {
            if (oracle.checks.len > effective_budget.max_runtime_checks) {
                try setBudgetExhaustion(
                    allocator,
                    result,
                    .max_runtime_checks,
                    .patch_runtime_oracle,
                    oracle.checks.len,
                    effective_budget.max_runtime_checks,
                    "runtime oracle check count exceeded the selected compute budget",
                    "runtime verification was skipped for the remaining oracle checks",
                );
                try finalizeCandidateFailure(allocator, candidate, .runtime_unresolved);
                return false;
            }
            const expectations = try buildRuntimeOracleExpectations(allocator, &oracle);
            defer allocator.free(expectations);

            const runtime_started = sys.getMilliTick();
            var runtime_capture = try execution.run(allocator, .{
                .workspace_root = workspace_root,
                .cwd = workspace_root,
                .path_override = path_override,
                .max_output_bytes = @min(MAX_VERIFICATION_OUTPUT_BYTES, effective_budget.max_temp_work_bytes),
            }, .{
                .label = oracle.label,
                .kind = oracle.kind,
                .phase = oracle.phase,
                .argv = oracle.argv,
                .expectations = expectations,
                .timeout_ms = boundedVerifierTimeout(effective_budget, oracle.timeout_ms),
            });
            result.profile.runtime_exec_ms += sys.getMilliTick() - runtime_started;
            defer runtime_capture.deinit(allocator);

            if (runtime_capture.failure_signal == .none) {
                if (try runtimeOracleFailureSummary(allocator, &oracle, &runtime_capture)) |summary| {
                    runtime_capture.failure_signal = .invariant_failed;
                    runtime_capture.invariant_summary = summary;
                }
            }

            const dispatch_started = sys.getMilliTick();
            try updateVerificationStep(
                allocator,
                &candidate.verification.runtime_step,
                &runtime_capture,
                attempt,
                max_retries,
                "runtime",
            );
            try annotateRuntimeOracleEvidence(allocator, &candidate.verification.runtime_step, &oracle, &runtime_capture);
            result.profile.verifier_adapter_dispatch_ms += sys.getMilliTick() - dispatch_started;

            if (!runtime_capture.succeeded()) {
                noteObservedFailureState(candidate, .runtime_failed);
                if (try maybeQueueRepairPlan(
                    allocator,
                    candidate,
                    &active_repair_index,
                    oracle.phase,
                    &runtime_capture,
                    attempt,
                    max_retries,
                )) {
                    candidate.verification.retry_count = attempt + 1;
                    continue;
                }
                if (active_repair_index) |repair_index| try setRepairPlanOutcome(
                    allocator,
                    &candidate.verification,
                    repair_index,
                    .failed,
                    "repaired descendant still failed bounded runtime oracle verification",
                );
                try finalizeCandidateFailure(allocator, candidate, .runtime_failed);
                return false;
            }

            candidate.validation_state = .runtime_verified;
        } else if (!workflow.test_available and workflow.runtime_available) {
            const argv = [_][]const u8{ "zig", "run", workflow.runtime_target.? };
            const runtime_started = sys.getMilliTick();
            var runtime_capture = try execution.run(allocator, .{
                .workspace_root = workspace_root,
                .cwd = workspace_root,
                .path_override = path_override,
                .max_output_bytes = @min(MAX_VERIFICATION_OUTPUT_BYTES, effective_budget.max_temp_work_bytes),
            }, .{
                .label = "zig_run",
                .kind = .zig_run,
                .phase = execution.Phase.run,
                .argv = &argv,
                .expectations = &.{
                    .{ .success = {} },
                    .{ .stderr_not_contains = "panic" },
                },
                .timeout_ms = boundedVerifierTimeout(effective_budget, MAX_VERIFICATION_TIMEOUT_MS),
            });
            result.profile.runtime_exec_ms += sys.getMilliTick() - runtime_started;
            defer runtime_capture.deinit(allocator);
            const dispatch_started = sys.getMilliTick();
            try updateVerificationStep(
                allocator,
                &candidate.verification.runtime_step,
                &runtime_capture,
                attempt,
                max_retries,
                "runtime",
            );
            result.profile.verifier_adapter_dispatch_ms += sys.getMilliTick() - dispatch_started;
            if (!runtime_capture.succeeded()) {
                noteObservedFailureState(candidate, .runtime_failed);
                if (try maybeQueueRepairPlan(
                    allocator,
                    candidate,
                    &active_repair_index,
                    execution.Phase.run,
                    &runtime_capture,
                    attempt,
                    max_retries,
                )) {
                    candidate.verification.retry_count = attempt + 1;
                    continue;
                }
                if (active_repair_index) |repair_index| try setRepairPlanOutcome(
                    allocator,
                    &candidate.verification,
                    repair_index,
                    .failed,
                    "repaired descendant still failed Linux runtime verification",
                );
                try finalizeCandidateFailure(allocator, candidate, .runtime_failed);
                return false;
            }
            candidate.validation_state = .runtime_verified;
        } else {
            try setUnavailableVerificationStep(allocator, &candidate.verification.runtime_step, "runtime verification was not required for this candidate");
            candidate.validation_state = .build_test_verified;
        }

        if (active_repair_index) |repair_index| try setRepairPlanOutcome(
            allocator,
            &candidate.verification,
            repair_index,
            .improved,
            verificationSurvivorReason(candidate, workflow),
        );
        candidate.verification.retry_count = attempt;
        return true;
    }

    candidate.validation_state = .build_failed;
    return false;
}

fn boundedVerifierTimeout(effective_budget: compute_budget.Effective, requested_timeout_ms: u32) u32 {
    return @max(@as(u32, 1), @min(@min(requested_timeout_ms, MAX_VERIFICATION_TIMEOUT_MS), effective_budget.max_verifier_time_ms));
}

fn maybeQueueRepairPlan(
    allocator: std.mem.Allocator,
    candidate: *Candidate,
    active_repair_index: *?usize,
    trigger_phase: execution.Phase,
    trigger_result: *const execution.Result,
    attempt: u32,
    max_retries: u32,
) !bool {
    const parent_lineage_id = if (active_repair_index.*) |repair_index|
        candidate.verification.repair_plans[repair_index].descendant_id
    else
        candidate.id;
    const selected = try selectRepairPlanForFailure(
        allocator,
        candidate,
        trigger_phase,
        trigger_result,
        attempt,
        max_retries,
        parent_lineage_id,
    ) orelse return false;
    if (active_repair_index.*) |repair_index| try setRepairPlanOutcome(
        allocator,
        &candidate.verification,
        repair_index,
        .failed,
        "repair descendant still failed and required one smaller bounded repair",
    );
    active_repair_index.* = try appendRepairPlan(allocator, &candidate.verification, selected);
    return true;
}

fn selectRepairPlanForFailure(
    allocator: std.mem.Allocator,
    candidate: *const Candidate,
    trigger_phase: execution.Phase,
    trigger_result: *const execution.Result,
    attempt: u32,
    max_retries: u32,
    parent_lineage_id: []const u8,
) !?RepairPlan {
    if (attempt >= max_retries) return null;

    const failure_text = trigger_result.invariant_summary orelse if (trigger_result.stderr.len > 0) trigger_result.stderr else if (trigger_result.stdout.len > 0) trigger_result.stdout else "";
    const has_call_surface = candidateHasRewriteOperator(candidate, .call_site_adaptation);
    const has_dispatch_indirection = candidateHasRewriteOperator(candidate, .dispatch_indirection);
    const has_signature_alignment = candidateHasRewriteOperator(candidate, .signature_adapter_generation);
    const has_import_rewrite = candidateHasImportRewrite(candidate);
    const has_abstraction_support = candidateHasAbstractionSupport(candidate);
    const invariant_hint = failureMentionsInvariant(failure_text) or candidateHasContradictionEvidence(candidate);

    const strategy = blk: {
        if (has_import_rewrite and failureMentionsImport(failure_text)) break :blk RepairStrategy.import_repair;
        if (has_dispatch_indirection and failureMentionsDispatchBoundary(failure_text)) break :blk RepairStrategy.dispatch_normalization_repair;
        if (has_call_surface and failureMentionsCallSurface(failure_text)) break :blk RepairStrategy.call_surface_adapter_repair;
        if (has_signature_alignment and failureMentionsSignature(failure_text)) break :blk RepairStrategy.signature_alignment_repair;
        if (candidate.hunks.len > 1 and (trigger_phase == .run or trigger_phase == .invariant or invariant_hint)) {
            break :blk RepairStrategy.invariant_preserving_simplification;
        }
        if (candidate.hunks.len > 1) break :blk RepairStrategy.narrow_to_primary_surface;
        return null;
    };

    const retained_hunk_count: u32 = switch (strategy) {
        .narrow_to_primary_surface,
        .invariant_preserving_simplification,
        => 1,
        .import_repair,
        .dispatch_normalization_repair,
        .signature_alignment_repair,
        .call_surface_adapter_repair,
        => @intCast(candidate.hunks.len),
    };
    const descendant_id = try std.fmt.allocPrint(allocator, "{s}__repair_{d}", .{ parent_lineage_id, attempt + 1 });
    errdefer allocator.free(descendant_id);
    const trigger_summary = try std.fmt.allocPrint(
        allocator,
        "phase={s}; failure_signal={s}; attempt={d}/{d}; summary={s}",
        .{
            execution.phaseName(trigger_phase),
            execution.failureSignalName(trigger_result.failure_signal),
            attempt + 1,
            max_retries + 1,
            if (trigger_result.invariant_summary) |summary| summary else if (failure_text.len > 0) failure_text else "bounded verification failure",
        },
    );
    errdefer allocator.free(trigger_summary);
    const evidence_summary = try buildRepairEvidenceSummary(
        allocator,
        candidate,
        strategy,
        trigger_phase,
        trigger_result,
        has_abstraction_support,
    );
    errdefer allocator.free(evidence_summary);

    return .{
        .attempt = attempt + 1,
        .trigger_phase = trigger_phase,
        .trigger_failure_signal = trigger_result.failure_signal,
        .strategy = strategy,
        .retry_budget = max_retries,
        .expected_verification_target = trigger_phase,
        .lineage_parent_id = try allocator.dupe(u8, parent_lineage_id),
        .descendant_id = descendant_id,
        .trigger_summary = trigger_summary,
        .evidence_summary = evidence_summary,
        .retained_hunk_count = retained_hunk_count,
    };
}

fn buildRepairEvidenceSummary(
    allocator: std.mem.Allocator,
    candidate: *const Candidate,
    strategy: RepairStrategy,
    trigger_phase: execution.Phase,
    trigger_result: *const execution.Result,
    has_abstraction_support: bool,
) ![]u8 {
    const primary_rel_path = candidatePrimaryRelPath(candidate.trace) orelse if (candidate.files.len > 0) candidate.files[0] else "unknown";
    const primary_line = candidatePrimaryLine(candidate.trace);
    const abstraction_text = if (has_abstraction_support) "abstraction-backed" else "no_abstraction_support";
    const contradiction_text = if (candidateHasContradictionEvidence(candidate)) "contradiction-backed" else "no_direct_contradiction_trace";
    return std.fmt.allocPrint(
        allocator,
        "repair={s}; trigger_phase={s}; primary_surface={s}:{d}; verification_signal={s}; support={s}; contradiction={s}",
        .{
            repairStrategyName(strategy),
            execution.phaseName(trigger_phase),
            primary_rel_path,
            primary_line,
            execution.failureSignalName(trigger_result.failure_signal),
            abstraction_text,
            contradiction_text,
        },
    );
}

fn repairApplicationForPlan(candidate: *const Candidate, plan: RepairPlan) RepairApplication {
    return switch (plan.strategy) {
        .narrow_to_primary_surface,
        .invariant_preserving_simplification,
        => .{
            .retained_hunk_count = @intCast(plan.retained_hunk_count),
            .primary_rel_path = candidatePrimaryRelPath(candidate.trace) orelse if (candidate.hunks.len > 0) candidate.hunks[0].rel_path else null,
        },
        .import_repair,
        .dispatch_normalization_repair,
        .signature_alignment_repair,
        .call_surface_adapter_repair,
        => .{},
    };
}

fn appendRepairPlan(allocator: std.mem.Allocator, trace: *VerificationTrace, plan: RepairPlan) !usize {
    const next = try allocator.alloc(RepairPlan, trace.repair_plans.len + 1);
    errdefer allocator.free(next);
    for (trace.repair_plans, 0..) |item, idx| next[idx] = item;
    next[trace.repair_plans.len] = plan;
    allocator.free(trace.repair_plans);
    trace.repair_plans = next;
    return trace.repair_plans.len - 1;
}

fn setRepairPlanOutcome(
    allocator: std.mem.Allocator,
    trace: *VerificationTrace,
    index: usize,
    outcome: RepairPlanOutcome,
    summary: []const u8,
) !void {
    const plan = &trace.repair_plans[index];
    plan.outcome = outcome;
    if (plan.outcome_summary) |existing| allocator.free(existing);
    plan.outcome_summary = try allocator.dupe(u8, summary);
}

fn candidateHasRewriteOperator(candidate: *const Candidate, operator_kind: RewriteOperator) bool {
    for (candidate.rewrite_operators) |existing| {
        if (existing == operator_kind) return true;
    }
    return false;
}

fn candidateHasImportRewrite(candidate: *const Candidate) bool {
    return candidateHasRewriteOperator(candidate, .import_insert) or
        candidateHasRewriteOperator(candidate, .import_remove) or
        candidateHasRewriteOperator(candidate, .import_update);
}

fn candidateHasContradictionEvidence(candidate: *const Candidate) bool {
    for (candidate.trace) |item| {
        if (item.kind == .code_intel_contradiction or item.kind == .execution_contradiction) return true;
    }
    return false;
}

fn candidateHasAbstractionSupport(candidate: *const Candidate) bool {
    for (candidate.trace) |item| {
        if (item.kind == .abstraction_live or item.kind == .abstraction_staged) return true;
    }
    return false;
}

fn failureMentionsImport(text: []const u8) bool {
    return containsIgnoreCase(text, "import") or containsIgnoreCase(text, "module") or containsIgnoreCase(text, "unused");
}

fn failureMentionsSignature(text: []const u8) bool {
    return containsIgnoreCase(text, "expected") or
        containsIgnoreCase(text, "argument") or
        containsIgnoreCase(text, "parameter") or
        containsIgnoreCase(text, "signature");
}

fn failureMentionsCallSurface(text: []const u8) bool {
    return containsIgnoreCase(text, "call") or containsIgnoreCase(text, "undeclared identifier") or failureMentionsSignature(text);
}

fn failureMentionsDispatchBoundary(text: []const u8) bool {
    return containsIgnoreCase(text, "dispatch") or
        containsIgnoreCase(text, "forwarded") or
        containsIgnoreCase(text, "wrapper") or
        containsIgnoreCase(text, "adapter");
}

fn failureMentionsInvariant(text: []const u8) bool {
    return containsIgnoreCase(text, "invariant") or
        containsIgnoreCase(text, "contradict") or
        containsIgnoreCase(text, "ownership") or
        containsIgnoreCase(text, "state");
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var idx: usize = 0;
    while (idx + needle.len <= haystack.len) : (idx += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[idx .. idx + needle.len], needle)) return true;
    }
    return false;
}

fn appendRefinementTrace(
    allocator: std.mem.Allocator,
    trace: *VerificationTrace,
    attempt: u32,
    label: []const u8,
    reason: []const u8,
    retained_hunk_count: u32,
) !void {
    const next = try allocator.alloc(RefinementTrace, trace.refinements.len + 1);
    errdefer allocator.free(next);
    for (trace.refinements, 0..) |item, idx| next[idx] = item;
    next[trace.refinements.len] = .{
        .attempt = attempt + 1,
        .label = try allocator.dupe(u8, label),
        .reason = try allocator.dupe(u8, reason),
        .retained_hunk_count = retained_hunk_count,
    };
    allocator.free(trace.refinements);
    trace.refinements = next;
}

fn detectVerificationWorkflow(allocator: std.mem.Allocator, repo_root: []const u8) !VerificationWorkflow {
    const build_path = try std.fs.path.join(allocator, &.{ repo_root, "build.zig" });
    defer allocator.free(build_path);
    const has_build = fileExists(build_path);

    const main_path = try std.fs.path.join(allocator, &.{ repo_root, "src", "main.zig" });
    defer allocator.free(main_path);
    const has_main = fileExists(main_path);

    var workflow = VerificationWorkflow{
        .build_available = has_build,
        .test_available = has_build,
        .runtime_available = has_main,
        .runtime_target = if (has_main) "src/main.zig" else null,
    };

    const oracle_path = try std.fs.path.join(allocator, &.{ repo_root, RUNTIME_ORACLE_FILE_NAME });
    defer allocator.free(oracle_path);
    if (!fileExists(oracle_path)) return workflow;

    workflow.runtime_oracle = loadRuntimeOracle(allocator, oracle_path) catch |err| {
        workflow.runtime_oracle_load_error = try std.fmt.allocPrint(
            allocator,
            "runtime oracle support was insufficient: {s}",
            .{@errorName(err)},
        );
        return workflow;
    };
    workflow.runtime_available = true;
    return workflow;
}

fn proofScore(candidate: *const Candidate, workflow: VerificationWorkflow) u32 {
    const bounded_cost = @min(candidate.minimality.total_cost, @as(u32, 2000));
    var score: u32 = @as(u32, 2600) - bounded_cost;
    score +%= candidate.score;
    if (workflow.test_available) score +%= 40;
    if (candidate.validation_state == .runtime_verified) {
        score +%= 40;
    } else if (candidate.validation_state == .build_test_verified or (!workflow.runtime_available and workflow.test_available)) {
        score +%= 20;
    }
    return score;
}

fn maxPotentialProofScore(candidate: *const Candidate, workflow: VerificationWorkflow) u32 {
    const bounded_cost = @min(candidate.minimality.total_cost, @as(u32, 2000));
    var score: u32 = @as(u32, 2600) - bounded_cost;
    score +%= candidate.score;
    if (workflow.test_available) score +%= 40;
    if (workflow.runtime_oracle != null or (!workflow.test_available and workflow.runtime_available)) {
        score +%= 40;
    } else if (workflow.test_available) {
        score +%= 20;
    }
    return score;
}

fn skipDominatedProofCandidate(
    allocator: std.mem.Allocator,
    candidate: *Candidate,
    best_score: u32,
    upper_bound: u32,
) !void {
    const status_reason = try std.fmt.allocPrint(
        allocator,
        "bounded proof-mode skipped this candidate because an earlier verified survivor already reached proof score {d}, above this candidate's maximum reachable score {d}",
        .{ best_score, upper_bound },
    );
    errdefer allocator.free(status_reason);
    const proof_reason = try std.fmt.allocPrint(
        allocator,
        "verification was skipped because a prior bounded survivor already proved a stronger result with proof score {d}, above this candidate's maximum reachable score {d}",
        .{ best_score, upper_bound },
    );
    errdefer allocator.free(proof_reason);

    try setUnavailableVerificationStep(allocator, &candidate.verification.build, status_reason);
    try setUnavailableVerificationStep(allocator, &candidate.verification.test_step, status_reason);
    try setUnavailableVerificationStep(allocator, &candidate.verification.runtime_step, status_reason);
    if (candidate.verification.proof_reason) |reason| allocator.free(reason);
    candidate.verification.proof_reason = proof_reason;
    clearCandidateProofMode(candidate);
    candidate.scheduler_status = .pruned;
    try setCandidateStatusOwned(allocator, candidate, .novel_but_unverified, status_reason);
}

fn pruneFocusedCandidatesAfterExpandedScopeFailure(
    allocator: std.mem.Allocator,
    candidates: []Candidate,
    remaining_queue: []const usize,
    failed_candidate: *const Candidate,
) !void {
    if (!candidateFailureSuggestsExpandedScope(failed_candidate)) return;
    if (!remainingQueueHasExpandedCandidate(candidates, remaining_queue)) return;

    for (remaining_queue) |candidate_idx| {
        const candidate = &candidates[candidate_idx];
        if (candidateScopeExpanded(candidate.*)) continue;
        if (candidateHasRewriteOperator(candidate, .call_site_adaptation)) continue;
        const status_reason = try std.fmt.allocPrint(
            allocator,
            "bounded proof-mode skipped this focused candidate after an earlier verification failure established that broader dependent-surface adaptation was required",
            .{},
        );
        errdefer allocator.free(status_reason);
        const proof_reason = try std.fmt.allocPrint(
            allocator,
            "verification was skipped because an earlier bounded failure already showed that candidates without dependent-surface adaptation could not satisfy the proof obligation",
            .{},
        );
        errdefer allocator.free(proof_reason);

        try setUnavailableVerificationStep(allocator, &candidate.verification.build, status_reason);
        try setUnavailableVerificationStep(allocator, &candidate.verification.test_step, status_reason);
        try setUnavailableVerificationStep(allocator, &candidate.verification.runtime_step, status_reason);
        if (candidate.verification.proof_reason) |reason| allocator.free(reason);
        candidate.verification.proof_reason = proof_reason;
        clearCandidateProofMode(candidate);
        candidate.scheduler_status = .pruned;
        try setCandidateStatusOwned(allocator, candidate, .novel_but_unverified, status_reason);
    }
}

fn clearCandidateProofMode(candidate: *Candidate) void {
    candidate.entered_proof_mode = false;
    candidate.proof_rank = null;
}

fn candidateFailureSuggestsExpandedScope(candidate: *const Candidate) bool {
    if (candidate.validation_state != .test_failed) return false;
    const detail = candidate.verification.test_step.evidence orelse candidate.verification.test_step.summary orelse return false;
    return containsIgnoreCase(detail, "dependent surface expansion missing") or
        containsIgnoreCase(detail, "broader call surface contradicted invariant");
}

fn remainingQueueHasExpandedCandidate(candidates: []const Candidate, remaining_queue: []const usize) bool {
    for (remaining_queue) |candidate_idx| {
        if (candidateScopeExpanded(candidates[candidate_idx])) return true;
    }
    return false;
}

fn verificationSurvivorReason(candidate: *const Candidate, workflow: VerificationWorkflow) []const u8 {
    _ = workflow;
    return switch (candidate.validation_state) {
        .runtime_verified => "candidate survived build, test, and bounded runtime oracle verification",
        .build_test_verified => "candidate survived build and test verification; no runtime oracle was required",
        else => "candidate survived bounded verification",
    };
}

fn loadRuntimeOracle(allocator: std.mem.Allocator, oracle_path: []const u8) !RuntimeOracle {
    const body = try readOwnedFile(allocator, oracle_path, MAX_RUNTIME_ORACLE_BYTES);
    defer allocator.free(body);

    var label: ?[]u8 = null;
    errdefer if (label) |value| allocator.free(value);
    var kind: execution.Kind = .zig_run;
    var phase: execution.Phase = .run;
    var timeout_ms: u32 = MAX_VERIFICATION_TIMEOUT_MS;
    var args = std.ArrayList([]u8).init(allocator);
    defer {
        for (args.items) |arg| allocator.free(arg);
        args.deinit();
    }
    var checks = std.ArrayList(RuntimeOracleCheck).init(allocator);
    defer {
        for (checks.items) |*check| check.deinit(allocator);
        checks.deinit();
    }

    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, std.mem.trimRight(u8, raw_line, "\r"), " \t");
        if (line.len == 0 or line[0] == '#') continue;
        const eq_idx = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidRuntimeOracle;
        const key = std.mem.trim(u8, line[0..eq_idx], " \t");
        const value = std.mem.trim(u8, line[eq_idx + 1 ..], " \t");
        if (std.mem.eql(u8, key, "required")) {
            if (!std.mem.eql(u8, value, "true")) return error.InvalidRuntimeOracle;
        } else if (std.mem.eql(u8, key, "label")) {
            if (label) |existing| allocator.free(existing);
            label = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "kind")) {
            kind = parseRuntimeOracleKind(value) orelse return error.InvalidRuntimeOracle;
        } else if (std.mem.eql(u8, key, "phase")) {
            phase = parseRuntimeOraclePhase(value) orelse return error.InvalidRuntimeOracle;
        } else if (std.mem.eql(u8, key, "timeout_ms")) {
            timeout_ms = std.fmt.parseUnsigned(u32, value, 10) catch return error.InvalidRuntimeOracle;
        } else if (std.mem.eql(u8, key, "arg")) {
            if (args.items.len >= execution.MAX_ARG_COUNT) return error.InvalidRuntimeOracle;
            try args.append(try allocator.dupe(u8, value));
        } else if (std.mem.eql(u8, key, "check")) {
            if (checks.items.len >= MAX_RUNTIME_ORACLE_CHECKS) return error.InvalidRuntimeOracle;
            try checks.append(try parseRuntimeOracleCheck(allocator, value));
        } else {
            return error.InvalidRuntimeOracle;
        }
    }

    if (label == null or args.items.len == 0 or checks.items.len == 0) return error.InvalidRuntimeOracle;

    return .{
        .required = true,
        .label = label.?,
        .kind = kind,
        .phase = phase,
        .argv = try args.toOwnedSlice(),
        .timeout_ms = @max(@as(u32, 1), @min(timeout_ms, execution.MAX_TIMEOUT_MS)),
        .checks = try checks.toOwnedSlice(),
    };
}

fn parseRuntimeOracleKind(value: []const u8) ?execution.Kind {
    if (std.mem.eql(u8, value, "zig_run")) return .zig_run;
    if (std.mem.eql(u8, value, "zig_build")) return .zig_build;
    if (std.mem.eql(u8, value, "shell")) return .shell;
    return null;
}

fn parseRuntimeOraclePhase(value: []const u8) ?execution.Phase {
    if (std.mem.eql(u8, value, "build")) return .build;
    if (std.mem.eql(u8, value, "test")) return .@"test";
    if (std.mem.eql(u8, value, "run")) return .run;
    if (std.mem.eql(u8, value, "invariant")) return .invariant;
    return null;
}

fn parseRuntimeOracleCheck(allocator: std.mem.Allocator, value: []const u8) !RuntimeOracleCheck {
    const colon_idx = std.mem.indexOfScalar(u8, value, ':') orelse return error.InvalidRuntimeOracle;
    const kind = std.mem.trim(u8, value[0..colon_idx], " \t");
    const detail = std.mem.trim(u8, value[colon_idx + 1 ..], " \t");

    if (std.mem.eql(u8, kind, "exit_code")) {
        return .{ .exit_code = std.fmt.parseInt(i32, detail, 10) catch return error.InvalidRuntimeOracle };
    }
    if (std.mem.eql(u8, kind, "stdout_contains")) return .{ .stdout_contains = try allocator.dupe(u8, detail) };
    if (std.mem.eql(u8, kind, "stderr_contains")) return .{ .stderr_contains = try allocator.dupe(u8, detail) };
    if (std.mem.eql(u8, kind, "stdout_not_contains")) return .{ .stdout_not_contains = try allocator.dupe(u8, detail) };
    if (std.mem.eql(u8, kind, "stderr_not_contains")) return .{ .stderr_not_contains = try allocator.dupe(u8, detail) };
    if (std.mem.eql(u8, kind, "invariant_holds")) return .{ .invariant_holds = try allocator.dupe(u8, detail) };
    if (std.mem.eql(u8, kind, "event_sequence")) {
        return .{ .event_sequence = .{ .items = try parseRuntimeOracleList(allocator, detail, ">") } };
    }
    if (std.mem.eql(u8, kind, "state_value")) {
        const eq_idx = std.mem.indexOfScalar(u8, detail, '=') orelse return error.InvalidRuntimeOracle;
        return .{ .state_value = .{
            .key = try allocator.dupe(u8, std.mem.trim(u8, detail[0..eq_idx], " \t")),
            .value = try allocator.dupe(u8, std.mem.trim(u8, detail[eq_idx + 1 ..], " \t")),
        } };
    }
    if (std.mem.eql(u8, kind, "state_transition")) {
        const eq_idx = std.mem.indexOfScalar(u8, detail, '=') orelse return error.InvalidRuntimeOracle;
        return .{ .state_transition = .{
            .key = try allocator.dupe(u8, std.mem.trim(u8, detail[0..eq_idx], " \t")),
            .values = try parseRuntimeOracleList(allocator, std.mem.trim(u8, detail[eq_idx + 1 ..], " \t"), "->"),
        } };
    }
    return error.InvalidRuntimeOracle;
}

fn parseRuntimeOracleList(allocator: std.mem.Allocator, detail: []const u8, delimiter: []const u8) ![][]u8 {
    var items = std.ArrayList([]u8).init(allocator);
    defer {
        for (items.items) |item| allocator.free(item);
        items.deinit();
    }

    var start: usize = 0;
    while (start <= detail.len) {
        const maybe_offset = std.mem.indexOfPos(u8, detail, start, delimiter);
        const end = maybe_offset orelse detail.len;
        const raw_item = detail[start..end];
        const item = std.mem.trim(u8, raw_item, " \t");
        if (item.len == 0) return error.InvalidRuntimeOracle;
        try items.append(try allocator.dupe(u8, item));
        if (maybe_offset == null) break;
        start = end + delimiter.len;
    }
    if (items.items.len == 0) return error.InvalidRuntimeOracle;
    return items.toOwnedSlice();
}

fn buildRuntimeOracleExpectations(allocator: std.mem.Allocator, oracle: *const RuntimeOracle) ![]execution.Expectation {
    var expectations = std.ArrayList(execution.Expectation).init(allocator);
    defer expectations.deinit();
    for (oracle.checks) |check| {
        switch (check) {
            .exit_code => |code| try expectations.append(.{ .exit_code = code }),
            .stdout_contains => |text| try expectations.append(.{ .stdout_contains = text }),
            .stderr_contains => |text| try expectations.append(.{ .stderr_contains = text }),
            .stdout_not_contains => |text| try expectations.append(.{ .stdout_not_contains = text }),
            .stderr_not_contains => |text| try expectations.append(.{ .stderr_not_contains = text }),
            .state_value, .event_sequence, .state_transition, .invariant_holds => {},
        }
    }
    return expectations.toOwnedSlice();
}

fn shouldPreserveDeeperVerificationStep(
    trace: VerificationTrace,
    is_repair_attempt: bool,
    phase: execution.Phase,
    failed: bool,
) bool {
    if (!is_repair_attempt or !failed) return false;
    return verificationDepth(trace) > verificationPhaseDepth(phase);
}

fn verificationDepth(trace: VerificationTrace) u8 {
    if (trace.runtime_step.state != .unavailable) return verificationPhaseDepth(.run);
    if (trace.test_step.state != .unavailable) return verificationPhaseDepth(.@"test");
    if (trace.build.state != .unavailable) return verificationPhaseDepth(.build);
    return 0;
}

fn verificationPhaseDepth(phase: execution.Phase) u8 {
    return switch (phase) {
        .build => 1,
        .@"test" => 2,
        .run, .invariant => 3,
    };
}

fn runtimeOracleFailureSummary(
    allocator: std.mem.Allocator,
    oracle: *const RuntimeOracle,
    result: *const execution.Result,
) !?[]u8 {
    for (oracle.checks) |check| {
        switch (check) {
            .state_value => |item| {
                if (!oracleOutputHasKeyValue(result.stdout, result.stderr, "state", item.key, item.value)) {
                    return try std.fmt.allocPrint(
                        allocator,
                        "runtime oracle {s} expected state {s}={s}",
                        .{ oracle.label, item.key, item.value },
                    );
                }
            },
            .event_sequence => |sequence| {
                if (!oracleOutputHasEventSequence(result.stdout, result.stderr, sequence.items)) {
                    return try std.fmt.allocPrint(
                        allocator,
                        "runtime oracle {s} expected ordered event sequence with {d} steps",
                        .{ oracle.label, sequence.items.len },
                    );
                }
            },
            .state_transition => |transition| {
                if (!oracleOutputHasStateTransition(result.stdout, result.stderr, transition.key, transition.values)) {
                    return try std.fmt.allocPrint(
                        allocator,
                        "runtime oracle {s} expected state transition {s} with {d} steps",
                        .{ oracle.label, transition.key, transition.values.len },
                    );
                }
            },
            .invariant_holds => |name| {
                if (!oracleOutputHasKeyValue(result.stdout, result.stderr, "invariant", name, "true")) {
                    return try std.fmt.allocPrint(
                        allocator,
                        "runtime oracle {s} expected invariant {s}=true",
                        .{ oracle.label, name },
                    );
                }
            },
            else => {},
        }
    }
    return null;
}

fn oracleOutputHasKeyValue(stdout: []const u8, stderr: []const u8, prefix: []const u8, key: []const u8, value: []const u8) bool {
    return oracleStreamHasKeyValue(stdout, prefix, key, value) or oracleStreamHasKeyValue(stderr, prefix, key, value);
}

fn oracleOutputHasEventSequence(stdout: []const u8, stderr: []const u8, expected: []const []const u8) bool {
    var next_idx = advanceOracleEventSequence(stdout, expected, 0);
    next_idx = advanceOracleEventSequence(stderr, expected, next_idx);
    return next_idx == expected.len;
}

fn advanceOracleEventSequence(stream: []const u8, expected: []const []const u8, start_idx: usize) usize {
    var next_idx = start_idx;
    if (next_idx >= expected.len) return next_idx;

    var it = std.mem.splitScalar(u8, stream, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, std.mem.trimRight(u8, raw_line, "\r"), " \t");
        if (!std.mem.startsWith(u8, line, "event:")) continue;
        const name = std.mem.trim(u8, line["event:".len..], " \t");
        if (std.mem.eql(u8, name, expected[next_idx])) {
            next_idx += 1;
            if (next_idx >= expected.len) break;
        }
    }
    return next_idx;
}

fn oracleOutputHasStateTransition(stdout: []const u8, stderr: []const u8, key: []const u8, expected: []const []const u8) bool {
    var next_idx = advanceOracleStateTransition(stdout, key, expected, 0);
    next_idx = advanceOracleStateTransition(stderr, key, expected, next_idx);
    return next_idx == expected.len;
}

fn advanceOracleStateTransition(stream: []const u8, key: []const u8, expected: []const []const u8, start_idx: usize) usize {
    var next_idx = start_idx;
    if (next_idx >= expected.len) return next_idx;

    var it = std.mem.splitScalar(u8, stream, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, std.mem.trimRight(u8, raw_line, "\r"), " \t");
        if (!std.mem.startsWith(u8, line, "state:")) continue;
        const rest = line["state:".len..];
        const eq_idx = std.mem.indexOfScalar(u8, rest, '=') orelse continue;
        const found_key = std.mem.trim(u8, rest[0..eq_idx], " \t");
        const found_value = std.mem.trim(u8, rest[eq_idx + 1 ..], " \t");
        if (std.mem.eql(u8, found_key, key) and std.mem.eql(u8, found_value, expected[next_idx])) {
            next_idx += 1;
            if (next_idx >= expected.len) break;
        }
    }
    return next_idx;
}

fn oracleStreamHasKeyValue(stream: []const u8, prefix: []const u8, key: []const u8, value: []const u8) bool {
    var it = std.mem.splitScalar(u8, stream, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, std.mem.trimRight(u8, raw_line, "\r"), " \t");
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        if (line.len <= prefix.len or line[prefix.len] != ':') continue;
        const rest = line[prefix.len + 1 ..];
        const eq_idx = std.mem.indexOfScalar(u8, rest, '=') orelse continue;
        const found_key = std.mem.trim(u8, rest[0..eq_idx], " \t");
        const found_value = std.mem.trim(u8, rest[eq_idx + 1 ..], " \t");
        if (std.mem.eql(u8, found_key, key) and std.mem.eql(u8, found_value, value)) return true;
    }
    return false;
}

fn annotateRuntimeOracleEvidence(
    allocator: std.mem.Allocator,
    step: *VerificationStep,
    oracle: *const RuntimeOracle,
    result: *const execution.Result,
) !void {
    const summary = if (result.succeeded())
        try std.fmt.allocPrint(
            allocator,
            "{s}; runtime oracle {s} passed {d} bounded checks",
            .{ step.summary orelse "runtime passed", oracle.label, oracle.checks.len },
        )
    else
        try std.fmt.allocPrint(
            allocator,
            "{s}; runtime oracle {s} failed",
            .{ step.summary orelse "runtime failed", oracle.label },
        );
    if (step.summary) |existing| allocator.free(existing);
    step.summary = summary;

    const augmented = try std.fmt.allocPrint(
        allocator,
        "{s}runtime_oracle={s}\nruntime_check_count={d}\n",
        .{ step.evidence orelse "", oracle.label, oracle.checks.len },
    );
    if (step.evidence) |existing| allocator.free(existing);
    step.evidence = augmented;
}

fn createVerificationSessionRoot(allocator: std.mem.Allocator, paths: *const shards.Paths) ![]u8 {
    const verification_root = try std.fs.path.join(allocator, &.{ paths.patch_candidates_root_abs_path, "verification" });
    defer allocator.free(verification_root);
    try sys.makePath(allocator, verification_root);
    return std.fmt.allocPrint(allocator, "{s}/session_{d}", .{ verification_root, std.time.nanoTimestamp() });
}

fn createVerificationWorkspace(
    allocator: std.mem.Allocator,
    verification_session_root: []const u8,
    repo_root: []const u8,
    candidate_id: []const u8,
    attempt: u32,
) ![]u8 {
    try ensureVerificationBaseline(allocator, verification_session_root, repo_root);
    const attempt_dir = try attemptDirName(allocator, attempt);
    defer allocator.free(attempt_dir);
    const workspace_root = try std.fs.path.join(allocator, &.{ verification_session_root, candidate_id, attempt_dir });
    errdefer allocator.free(workspace_root);

    try deleteTreeIfExists(workspace_root);
    try sys.makePath(allocator, workspace_root);
    const baseline_root = try std.fs.path.join(allocator, &.{ verification_session_root, "_baseline" });
    defer allocator.free(baseline_root);
    try cloneTreeAbsolute(allocator, baseline_root, workspace_root, .hardlink);
    return workspace_root;
}

fn ensureVerificationBaseline(
    allocator: std.mem.Allocator,
    verification_session_root: []const u8,
    repo_root: []const u8,
) !void {
    const baseline_root = try std.fs.path.join(allocator, &.{ verification_session_root, "_baseline" });
    defer allocator.free(baseline_root);
    if (fileExists(baseline_root)) return;

    try sys.makePath(allocator, verification_session_root);
    try deleteTreeIfExists(baseline_root);
    try sys.makePath(allocator, baseline_root);
    cloneTreeAbsolute(allocator, repo_root, baseline_root, .hardlink) catch |err| switch (err) {
        error.NotSameFileSystem, error.AccessDenied => try cloneTreeAbsolute(allocator, repo_root, baseline_root, .copy),
        else => return err,
    };
}

fn attemptDirName(allocator: std.mem.Allocator, attempt: u32) ![]u8 {
    return std.fmt.allocPrint(allocator, "attempt_{d}", .{attempt + 1});
}

const RepairApplication = struct {
    retained_hunk_count: ?usize = null,
    primary_rel_path: ?[]const u8 = null,

    fn retainsHunk(self: RepairApplication, candidate: *const Candidate, hunk: PatchHunk, hunk_idx: usize) bool {
        if (self.retained_hunk_count) |limit| if (hunk_idx >= limit) return false;
        if (self.primary_rel_path) |rel_path| {
            if (std.mem.eql(u8, hunk.rel_path, rel_path)) return true;
            if (hunk_idx == 0 and std.mem.eql(u8, hunk.rel_path, candidate.hunks[0].rel_path)) return true;
            return false;
        }
        return true;
    }
};

fn applyCandidateToWorkspace(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    candidate: *const Candidate,
    application: RepairApplication,
) !void {
    for (candidate.files) |rel_path| {
        const hunk_count = countCandidateHunksForPath(candidate, rel_path, application);
        if (hunk_count == 0) continue;

        var path_hunks = try allocator.alloc(PatchHunk, hunk_count);
        defer allocator.free(path_hunks);

        var idx: usize = 0;
        for (candidate.hunks, 0..) |hunk, hunk_idx| {
            if (!application.retainsHunk(candidate, hunk, hunk_idx)) continue;
            if (!std.mem.eql(u8, hunk.rel_path, rel_path)) continue;
            path_hunks[idx] = hunk;
            idx += 1;
        }

        std.sort.heap(PatchHunk, path_hunks, {}, lessThanPatchHunkDesc);

        const abs_path = try std.fs.path.join(allocator, &.{ workspace_root, rel_path });
        defer allocator.free(abs_path);
        const original = try readOwnedFile(allocator, abs_path, MAX_SOURCE_FILE_BYTES);
        defer allocator.free(original);

        var updated = try allocator.dupe(u8, original);
        defer allocator.free(updated);

        for (path_hunks) |hunk| {
            const next = try applyHunkToBody(allocator, updated, hunk);
            allocator.free(updated);
            updated = next;
        }

        try writeOwnedFile(allocator, abs_path, updated);
    }
}

const CandidateSymbolPair = struct {
    original: []const u8,
    implementation: []const u8,
};

fn applyRepairStrategyToWorkspace(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    candidate: *const Candidate,
    plan: RepairPlan,
) !void {
    switch (plan.strategy) {
        .narrow_to_primary_surface, .invariant_preserving_simplification => {},
        .dispatch_normalization_repair => try normalizeWrapperDispatchInWorkspace(allocator, workspace_root, candidate),
        .call_surface_adapter_repair, .signature_alignment_repair => {
            const symbols = candidateSymbolPair(candidate) orelse return;
            try restoreStableCallSurface(allocator, workspace_root, candidate, symbols, plan.strategy == .signature_alignment_repair);
        },
        .import_repair => try repairUnusedImports(allocator, workspace_root, candidate),
    }
}

fn candidateSymbolPair(candidate: *const Candidate) ?CandidateSymbolPair {
    const original = candidatePrimarySymbolName(candidate.trace) orelse return null;
    const implementation = candidateGeneratedImplSymbol(candidate) orelse return null;
    return .{
        .original = original,
        .implementation = implementation,
    };
}

fn candidatePrimarySymbolName(trace: []const SupportTrace) ?[]const u8 {
    for (trace) |item| {
        if (item.kind == .code_intel_primary) return item.label;
    }
    return null;
}

fn candidateGeneratedImplSymbol(candidate: *const Candidate) ?[]const u8 {
    for (candidate.hunks) |hunk| {
        if (findGeneratedImplSymbol(hunk.diff)) |symbol| return symbol;
    }
    return null;
}

fn findGeneratedImplSymbol(diff: []const u8) ?[]const u8 {
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, diff, search_from, "__ghost_c")) |offset| {
        const symbol = diff[offset..];
        const len = startsGeneratedImplSymbol(symbol) orelse {
            search_from = offset + 1;
            continue;
        };
        return symbol[0..len];
    }
    return null;
}

fn restoreStableCallSurface(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    candidate: *const Candidate,
    symbols: CandidateSymbolPair,
    include_primary: bool,
) !void {
    const qualified_from = try std.fmt.allocPrint(allocator, ".{s}(", .{symbols.implementation});
    defer allocator.free(qualified_from);
    const qualified_to = try std.fmt.allocPrint(allocator, ".{s}(", .{symbols.original});
    defer allocator.free(qualified_to);
    const plain_from = try std.fmt.allocPrint(allocator, "{s}(", .{symbols.implementation});
    defer allocator.free(plain_from);
    const plain_to = try std.fmt.allocPrint(allocator, "{s}(", .{symbols.original});
    defer allocator.free(plain_to);

    const primary_rel_path = candidatePrimaryRelPath(candidate.trace);
    for (candidate.files) |rel_path| {
        if (!include_primary and primary_rel_path != null and std.mem.eql(u8, rel_path, primary_rel_path.?)) continue;
        if (!std.mem.endsWith(u8, rel_path, ".zig")) continue;
        const abs_path = try std.fs.path.join(allocator, &.{ workspace_root, rel_path });
        defer allocator.free(abs_path);
        const original = try readOwnedFile(allocator, abs_path, MAX_SOURCE_FILE_BYTES);
        defer allocator.free(original);

        const reverted_qualified = try std.mem.replaceOwned(u8, allocator, original, qualified_from, qualified_to);
        defer allocator.free(reverted_qualified);
        if (std.mem.eql(u8, original, reverted_qualified) and !include_primary) continue;

        const updated = try std.mem.replaceOwned(u8, allocator, reverted_qualified, plain_from, plain_to);
        defer allocator.free(updated);
        if (std.mem.eql(u8, original, updated)) continue;

        try writeOwnedFile(allocator, abs_path, updated);
    }
}

fn repairUnusedImports(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    candidate: *const Candidate,
) !void {
    for (candidate.files) |rel_path| {
        if (!std.mem.endsWith(u8, rel_path, ".zig")) continue;
        const abs_path = try std.fs.path.join(allocator, &.{ workspace_root, rel_path });
        defer allocator.free(abs_path);
        const original = try readOwnedFile(allocator, abs_path, MAX_SOURCE_FILE_BYTES);
        defer allocator.free(original);
        const updated = try removeUnusedZigImports(allocator, original);
        defer allocator.free(updated);
        if (std.mem.eql(u8, original, updated)) continue;
        try writeOwnedFile(allocator, abs_path, updated);
    }
}

fn normalizeWrapperDispatchInWorkspace(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    candidate: *const Candidate,
) !void {
    const symbols = candidateSymbolPair(candidate) orelse return;
    const rel_path = candidatePrimaryRelPath(candidate.trace) orelse if (candidate.files.len > 0) candidate.files[0] else return;
    if (!std.mem.endsWith(u8, rel_path, ".zig")) return;

    const abs_path = try std.fs.path.join(allocator, &.{ workspace_root, rel_path });
    defer allocator.free(abs_path);
    const original = try readOwnedFile(allocator, abs_path, MAX_SOURCE_FILE_BYTES);
    defer allocator.free(original);

    const decl = (try findZigFunctionDecl(allocator, original, symbols.original, candidatePrimaryLine(candidate.trace))) orelse return;
    const call_args = try buildZigForwardedArguments(allocator, original, decl);
    defer allocator.free(call_args);

    const updated = try buildZigDirectWrapperRepairEdit(allocator, original, decl, symbols.implementation, call_args);
    defer allocator.free(updated);
    if (std.mem.eql(u8, original, updated)) return;
    try writeOwnedFile(allocator, abs_path, updated);
}

fn buildZigDirectWrapperRepairEdit(
    allocator: std.mem.Allocator,
    body: []const u8,
    decl: ZigFunctionDecl,
    impl_name: []const u8,
    call_args: []const u8,
) ![]u8 {
    var dispatch = std.ArrayList(u8).init(allocator);
    defer dispatch.deinit();
    const return_type = std.mem.trim(u8, body[decl.params_end + 1 .. decl.body_start], " \r\n\t");
    try writeZigWrapperDispatch(dispatch.writer(), .direct, impl_name, call_args, std.mem.eql(u8, return_type, "void"));
    return replaceZigFunctionBody(allocator, body, decl, dispatch.items);
}

fn replaceZigFunctionBody(
    allocator: std.mem.Allocator,
    body: []const u8,
    decl: ZigFunctionDecl,
    replacement_body: []const u8,
) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const writer = out.writer();
    try writer.writeAll(body[0 .. decl.body_start + 1]);
    try writer.writeAll("\n");
    try writer.writeAll(replacement_body);
    try writer.writeAll("\n");
    try writer.writeAll(body[decl.body_end - 1 ..]);
    return out.toOwnedSlice();
}

fn removeUnusedZigImports(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    var lines = std.ArrayList([]const u8).init(allocator);
    defer lines.deinit();
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |line| try lines.append(std.mem.trimRight(u8, line, "\r"));

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    for (lines.items) |line| {
        if (parseZigImportAlias(line)) |alias| {
            if (!bodyUsesImportAlias(body, alias, line)) continue;
        }
        try out.appendSlice(line);
        try out.append('\n');
    }
    return out.toOwnedSlice();
}

fn parseZigImportAlias(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (!std.mem.startsWith(u8, trimmed, "const ")) return null;
    const eq_idx = std.mem.indexOf(u8, trimmed, " = @import(") orelse return null;
    const alias = std.mem.trim(u8, trimmed["const ".len..eq_idx], " \t");
    if (alias.len == 0) return null;
    return alias;
}

fn bodyUsesImportAlias(body: []const u8, alias: []const u8, import_line: []const u8) bool {
    const dotted = std.mem.indexOf(u8, body, alias) != null;
    if (!dotted) return false;
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        if (std.mem.eql(u8, line, import_line)) continue;
        if (std.mem.indexOf(u8, line, alias)) |offset| {
            if (offset + alias.len < line.len and line[offset + alias.len] == '.') return true;
        }
    }
    return false;
}

fn countCandidateHunksForPath(candidate: *const Candidate, rel_path: []const u8, application: RepairApplication) usize {
    var count: usize = 0;
    for (candidate.hunks, 0..) |hunk, idx| {
        if (!application.retainsHunk(candidate, hunk, idx)) continue;
        if (std.mem.eql(u8, hunk.rel_path, rel_path)) count += 1;
    }
    return count;
}

fn lessThanPatchHunkDesc(_: void, lhs: PatchHunk, rhs: PatchHunk) bool {
    if (lhs.start_line != rhs.start_line) return lhs.start_line > rhs.start_line;
    return lhs.anchor_line > rhs.anchor_line;
}

fn applyHunkToBody(allocator: std.mem.Allocator, body: []const u8, hunk: PatchHunk) ![]u8 {
    var source_lines = std.ArrayList([]const u8).init(allocator);
    defer source_lines.deinit();
    var source_iter = std.mem.splitScalar(u8, body, '\n');
    while (source_iter.next()) |line| try source_lines.append(std.mem.trimRight(u8, line, "\r"));

    var diff_lines = std.ArrayList([]const u8).init(allocator);
    defer diff_lines.deinit();
    var diff_iter = std.mem.splitScalar(u8, hunk.diff, '\n');
    var header_lines: usize = 0;
    while (diff_iter.next()) |line| {
        const trimmed = std.mem.trimRight(u8, line, "\r");
        if (trimmed.len == 0) continue;
        if (header_lines < 3) {
            header_lines += 1;
            continue;
        }
        try diff_lines.append(trimmed);
    }

    const prefix_count: usize = if (hunk.start_line > 1) @intCast(hunk.start_line - 1) else 0;
    if (prefix_count > source_lines.items.len) return error.InvalidPatchCandidateHunk;

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const writer = out.writer();

    for (source_lines.items[0..prefix_count]) |line| {
        try writer.writeAll(line);
        try writer.writeByte('\n');
    }

    var source_idx = prefix_count;
    for (diff_lines.items) |line| {
        if (line.len == 0) continue;
        const kind = line[0];
        const text = line[1..];
        switch (kind) {
            ' ' => {
                if (source_idx >= source_lines.items.len or !std.mem.eql(u8, source_lines.items[source_idx], text)) {
                    return error.InvalidPatchCandidateHunk;
                }
                try writer.writeAll(text);
                try writer.writeByte('\n');
                source_idx += 1;
            },
            '+' => {
                try writer.writeAll(text);
                try writer.writeByte('\n');
            },
            '-' => {
                if (source_idx >= source_lines.items.len or !std.mem.eql(u8, source_lines.items[source_idx], text)) {
                    return error.InvalidPatchCandidateHunk;
                }
                source_idx += 1;
            },
            else => return error.InvalidPatchCandidateHunk,
        }
    }

    for (source_lines.items[source_idx..]) |line| {
        try writer.writeAll(line);
        try writer.writeByte('\n');
    }
    return out.toOwnedSlice();
}

const TreeCloneMode = enum {
    copy,
    hardlink,
};

fn cloneTreeAbsolute(
    allocator: std.mem.Allocator,
    source_root: []const u8,
    dest_root: []const u8,
    mode: TreeCloneMode,
) !void {
    const skip_rel = std.fs.path.relative(allocator, source_root, dest_root) catch null;
    defer if (skip_rel) |rel| allocator.free(rel);

    var source_dir = try std.fs.openDirAbsolute(source_root, .{ .iterate = true });
    defer source_dir.close();
    var walker = try source_dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (skip_rel) |rel| {
            if (!std.mem.startsWith(u8, rel, "..")) {
                if (std.mem.eql(u8, entry.path, rel)) continue;
                if (std.mem.startsWith(u8, entry.path, rel) and entry.path.len > rel.len and entry.path[rel.len] == std.fs.path.sep) continue;
            }
        }
        const target_path = try std.fs.path.join(allocator, &.{ dest_root, entry.path });
        defer allocator.free(target_path);

        switch (entry.kind) {
            .directory => try std.fs.cwd().makePath(target_path),
            .file => {
                if (std.fs.path.dirname(entry.path)) |parent| {
                    const target_parent = try std.fs.path.join(allocator, &.{ dest_root, parent });
                    defer allocator.free(target_parent);
                    try std.fs.cwd().makePath(target_parent);
                }
                const source_path = try std.fs.path.join(allocator, &.{ source_root, entry.path });
                defer allocator.free(source_path);
                switch (mode) {
                    .copy => try std.fs.copyFileAbsolute(source_path, target_path, .{}),
                    .hardlink => try std.posix.link(source_path, target_path),
                }
            },
            else => {},
        }
    }
}

fn updateVerificationStep(
    allocator: std.mem.Allocator,
    step: *VerificationStep,
    result: *const execution.Result,
    attempt: u32,
    max_retries: u32,
    phase_name: []const u8,
) !void {
    clearVerificationStep(allocator, step);
    step.state = if (result.succeeded()) .passed else .failed;
    step.adapter_id = try allocator.dupe(u8, adapterIdForPhaseName(phase_name));
    step.evidence_kind = evidenceKindForPhaseName(phase_name);
    step.command = try allocator.dupe(u8, result.command);
    step.exit_code = result.exit_code;
    step.duration_ms = result.duration_ms;
    step.failure_signal = result.failure_signal;
    step.summary = try std.fmt.allocPrint(
        allocator,
        "{s} {s} on attempt {d}/{d}; duration_ms={d}; failure_signal={s}",
        .{
            phase_name,
            if (result.succeeded()) "passed" else "failed",
            attempt + 1,
            max_retries + 1,
            result.duration_ms,
            execution.failureSignalName(result.failure_signal),
        },
    );
    step.evidence = try execution.buildEvidence(allocator, result);
}

fn setUnavailableVerificationStep(allocator: std.mem.Allocator, step: *VerificationStep, summary: []const u8) !void {
    clearVerificationStep(allocator, step);
    step.state = .unavailable;
    step.summary = try allocator.dupe(u8, summary);
}

fn clearVerificationStep(allocator: std.mem.Allocator, step: *VerificationStep) void {
    if (step.adapter_id) |adapter_id| allocator.free(adapter_id);
    if (step.command) |command| allocator.free(command);
    if (step.summary) |summary| allocator.free(summary);
    if (step.evidence) |evidence| allocator.free(evidence);
    step.* = .{};
}

fn setBudgetExhaustion(
    allocator: std.mem.Allocator,
    result: *Result,
    limit: compute_budget.Limit,
    stage: compute_budget.Stage,
    used: u64,
    limit_value: u64,
    detail: []const u8,
    skipped: []const u8,
) !void {
    if (result.budget_exhaustion != null) return;
    result.status = .unresolved;
    result.stop_reason = .budget;
    result.confidence = 0;
    if (result.unresolved_detail) |existing| allocator.free(existing);
    result.unresolved_detail = try std.fmt.allocPrint(
        allocator,
        "compute budget exhausted: {s} hit during {s}; {s}",
        .{ compute_budget.limitName(limit), compute_budget.stageName(stage), detail },
    );
    result.budget_exhaustion = try compute_budget.Exhaustion.init(
        allocator,
        limit,
        stage,
        used,
        limit_value,
        detail,
        skipped,
    );
}

fn proofQueueBudgetExhaustedWithoutConcreteVerificationOutcome(result: *const Result) bool {
    if (result.handoff.exploration.preserved_novel_count == 0) return false;
    if (result.handoff.proof.rejected_count > 0) return false;
    if (result.handoff.proof.unresolved_count > 0) return false;
    if (result.handoff.proof.supported_count > 0) return false;
    if (result.handoff.proof.verified_survivor_count > 0) return false;
    return true;
}

fn initResult(allocator: std.mem.Allocator, paths: *const shards.Paths, options: Options, caps: Caps) !Result {
    const code_intel_result_path = try std.fs.path.join(allocator, &.{ paths.code_intel_root_abs_path, DEFAULT_CODE_INTEL_RESULT_NAME });
    errdefer allocator.free(code_intel_result_path);

    return .{
        .allocator = allocator,
        .status = .unresolved,
        .query_kind = options.query_kind,
        .target = try allocator.dupe(u8, options.target),
        .other_target = if (options.other_target) |other| try allocator.dupe(u8, other) else null,
        .request_label = try boundedLabel(allocator, options.request_label orelse options.target),
        .repo_root = try allocator.dupe(u8, options.repo_root),
        .shard_id = try allocator.dupe(u8, paths.metadata.id),
        .shard_root = try allocator.dupe(u8, paths.root_abs_path),
        .shard_kind = paths.metadata.kind,
        .minimality_model = try allocator.dupe(u8, MINIMALITY_MODEL_NAME),
        .code_intel_result_path = code_intel_result_path,
        .caps = caps,
        .effective_budget = options.effective_budget,
        .planning_basis = .{ .allocator = allocator },
        .unresolved = .{ .allocator = allocator },
        .support_graph = .{ .allocator = allocator },
    };
}

fn cloneUnresolvedSupport(allocator: std.mem.Allocator, src: code_intel.UnresolvedSupport) !code_intel.UnresolvedSupport {
    var partial_findings = try allocator.alloc(code_intel.PartialFinding, src.partial_findings.len);
    var built_partials: usize = 0;
    errdefer {
        for (partial_findings[0..built_partials]) |*item| item.deinit(allocator);
        allocator.free(partial_findings);
    }
    for (src.partial_findings, 0..) |item, idx| {
        partial_findings[idx] = try clonePartialFinding(allocator, item);
        built_partials += 1;
    }

    var ambiguity_sets = try allocator.alloc(code_intel.AmbiguitySet, src.ambiguity_sets.len);
    var built_ambiguities: usize = 0;
    errdefer {
        for (ambiguity_sets[0..built_ambiguities]) |*item| item.deinit(allocator);
        allocator.free(ambiguity_sets);
    }
    for (src.ambiguity_sets, 0..) |item, idx| {
        ambiguity_sets[idx] = try cloneAmbiguitySet(allocator, item);
        built_ambiguities += 1;
    }

    var missing_obligations = try allocator.alloc(code_intel.MissingObligation, src.missing_obligations.len);
    var built_missing: usize = 0;
    errdefer {
        for (missing_obligations[0..built_missing]) |*item| item.deinit(allocator);
        allocator.free(missing_obligations);
    }
    for (src.missing_obligations, 0..) |item, idx| {
        missing_obligations[idx] = try cloneMissingObligation(allocator, item);
        built_missing += 1;
    }

    var suppressed_noise = try allocator.alloc(code_intel.SuppressedNoise, src.suppressed_noise.len);
    var built_noise: usize = 0;
    errdefer {
        for (suppressed_noise[0..built_noise]) |*item| item.deinit(allocator);
        allocator.free(suppressed_noise);
    }
    for (src.suppressed_noise, 0..) |item, idx| {
        suppressed_noise[idx] = try cloneSuppressedNoise(allocator, item);
        built_noise += 1;
    }

    var freshness_checks = try allocator.alloc(code_intel.FreshnessCheck, src.freshness_checks.len);
    var built_freshness: usize = 0;
    errdefer {
        for (freshness_checks[0..built_freshness]) |*item| item.deinit(allocator);
        allocator.free(freshness_checks);
    }
    for (src.freshness_checks, 0..) |item, idx| {
        freshness_checks[idx] = try cloneFreshnessCheck(allocator, item);
        built_freshness += 1;
    }

    return .{
        .allocator = allocator,
        .partial_findings = partial_findings,
        .ambiguity_sets = ambiguity_sets,
        .missing_obligations = missing_obligations,
        .suppressed_noise = suppressed_noise,
        .freshness_checks = freshness_checks,
    };
}

fn clonePartialFinding(allocator: std.mem.Allocator, item: code_intel.PartialFinding) !code_intel.PartialFinding {
    return .{
        .kind = item.kind,
        .label = try allocator.dupe(u8, item.label),
        .scope = try allocator.dupe(u8, item.scope),
        .provenance = try allocator.dupe(u8, item.provenance),
        .rel_path = if (item.rel_path) |path| try allocator.dupe(u8, path) else null,
        .line = item.line,
        .detail = if (item.detail) |detail| try allocator.dupe(u8, detail) else null,
        .non_authorizing = item.non_authorizing,
    };
}

fn cloneAmbiguitySet(allocator: std.mem.Allocator, item: code_intel.AmbiguitySet) !code_intel.AmbiguitySet {
    var options = try allocator.alloc(code_intel.AmbiguityOption, item.options.len);
    var built: usize = 0;
    errdefer {
        for (options[0..built]) |*option| option.deinit(allocator);
        allocator.free(options);
    }
    for (item.options, 0..) |option, idx| {
        options[idx] = .{
            .label = try allocator.dupe(u8, option.label),
            .rel_path = if (option.rel_path) |path| try allocator.dupe(u8, path) else null,
            .line = option.line,
            .detail = if (option.detail) |detail| try allocator.dupe(u8, detail) else null,
        };
        built += 1;
    }
    return .{
        .label = try allocator.dupe(u8, item.label),
        .scope = try allocator.dupe(u8, item.scope),
        .reason = if (item.reason) |reason| try allocator.dupe(u8, reason) else null,
        .options = options,
    };
}

fn cloneMissingObligation(allocator: std.mem.Allocator, item: code_intel.MissingObligation) !code_intel.MissingObligation {
    return .{
        .label = try allocator.dupe(u8, item.label),
        .scope = try allocator.dupe(u8, item.scope),
        .detail = if (item.detail) |detail| try allocator.dupe(u8, detail) else null,
    };
}

fn cloneSuppressedNoise(allocator: std.mem.Allocator, item: code_intel.SuppressedNoise) !code_intel.SuppressedNoise {
    return .{
        .label = try allocator.dupe(u8, item.label),
        .reason = try allocator.dupe(u8, item.reason),
        .rel_path = if (item.rel_path) |path| try allocator.dupe(u8, path) else null,
        .line = item.line,
    };
}

fn cloneFreshnessCheck(allocator: std.mem.Allocator, item: code_intel.FreshnessCheck) !code_intel.FreshnessCheck {
    return .{
        .label = try allocator.dupe(u8, item.label),
        .scope = try allocator.dupe(u8, item.scope),
        .state = item.state,
        .detail = if (item.detail) |detail| try allocator.dupe(u8, detail) else null,
    };
}

fn buildCandidates(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    intel: *const code_intel.Result,
    abstraction_refs: []const abstractions.SupportReference,
    caps: Caps,
    strategy_options: []const StrategyOption,
) ![]Candidate {
    var surfaces = std.ArrayList(SurfaceSeed).init(allocator);
    defer surfaces.deinit();
    try collectSurfaceSeeds(&surfaces, intel, caps.max_files);
    if (surfaces.items.len == 0) return allocator.alloc(Candidate, 0);

    std.sort.heap(SurfaceSeed, surfaces.items, {}, lessThanSurfaceSeed);
    if (surfaces.items.len > caps.max_files) surfaces.items.len = caps.max_files;

    var plan_seeds = std.ArrayList(PlanSeed).init(allocator);
    defer plan_seeds.deinit();
    for (strategy_options) |option| {
        for (surfaces.items, 0..) |_, focus_idx| {
            try appendPlanSeed(&plan_seeds, intel, surfaces.items, option, .focused, @intCast(focus_idx), null);
            if (caps.max_hunks_per_candidate > 1 and strategySupportsExpandedScope(option.strategy)) {
                var extra_indexes: [HARD_MAX_FILES]u8 = [_]u8{0} ** HARD_MAX_FILES;
                const max_extra = @min(caps.max_hunks_per_candidate - 1, caps.max_files - 1);
                const extra_count = collectExpandedSurfaceIndexes(surfaces.items, focus_idx, max_extra, &extra_indexes);
                if (extra_count == 0) continue;
                try appendPlanSeed(&plan_seeds, intel, surfaces.items, option, .expanded, @intCast(focus_idx), extra_indexes[0..extra_count]);
            }
        }
    }
    if (plan_seeds.items.len == 0) return allocator.alloc(Candidate, 0);

    std.sort.heap(PlanSeed, plan_seeds.items, surfaces.items, lessThanPlanSeed);
    const selected_seeds = try selectPlanSeeds(allocator, plan_seeds.items, exploratoryCandidatePoolCap(caps));
    defer allocator.free(selected_seeds);

    var built_candidates = std.ArrayList(Candidate).init(allocator);
    errdefer {
        for (built_candidates.items) |*candidate| candidate.deinit(allocator);
        built_candidates.deinit();
    }

    for (selected_seeds, 0..) |seed, idx| {
        const candidate = try buildCandidate(
            allocator,
            repo_root,
            intel,
            abstraction_refs,
            surfaces.items,
            caps,
            seed,
            @intCast(idx),
        ) orelse continue;
        try built_candidates.append(candidate);
    }

    const deduped = try dedupeCandidatePool(allocator, built_candidates.items);
    for (built_candidates.items) |*candidate| candidate.deinit(allocator);
    built_candidates.deinit();
    return deduped;
}

fn dedupeCandidatePool(allocator: std.mem.Allocator, candidates: []Candidate) ![]Candidate {
    if (candidates.len <= 1) return cloneCandidateSlice(allocator, candidates);

    var unique = std.ArrayList(Candidate).init(allocator);
    errdefer {
        for (unique.items) |*candidate| candidate.deinit(allocator);
        unique.deinit();
    }

    outer: for (candidates) |candidate| {
        for (unique.items) |*existing| {
            if (!candidatesSemanticallyEquivalent(allocator, existing, candidate)) continue;
            try mergeEquivalentCandidate(allocator, existing, candidate);
            continue :outer;
        }
        try unique.append(try candidate.clone(allocator));
    }

    return unique.toOwnedSlice();
}

fn cloneCandidateSlice(allocator: std.mem.Allocator, candidates: []const Candidate) ![]Candidate {
    const out = try allocator.alloc(Candidate, candidates.len);
    var built: usize = 0;
    errdefer {
        for (out[0..built]) |*candidate| candidate.deinit(allocator);
        allocator.free(out);
    }
    for (candidates, 0..) |candidate, idx| {
        out[idx] = try candidate.clone(allocator);
        built += 1;
    }
    return out;
}

fn cloneStringSlice(allocator: std.mem.Allocator, items: []const []const u8) ![][]u8 {
    var out = try allocator.alloc([]u8, items.len);
    var built: usize = 0;
    errdefer {
        for (out[0..built]) |item| allocator.free(item);
        allocator.free(out);
    }
    for (items, 0..) |item, idx| {
        out[idx] = try allocator.dupe(u8, item);
        built += 1;
    }
    return out;
}

fn mergeEquivalentCandidate(allocator: std.mem.Allocator, winner: *Candidate, duplicate: Candidate) !void {
    if (duplicate.score > winner.score) {
        winner.score = duplicate.score;
        allocator.free(winner.summary);
        winner.summary = try allocator.dupe(u8, duplicate.summary);
        allocator.free(winner.strategy);
        winner.strategy = try allocator.dupe(u8, duplicate.strategy);
        winner.minimality = duplicate.minimality;
    }
    winner.exploration_rank = @min(winner.exploration_rank, duplicate.exploration_rank);
    try mergeSupportTraceList(allocator, winner, duplicate.trace);
}

fn mergeSupportTraceList(allocator: std.mem.Allocator, winner: *Candidate, extra: []const SupportTrace) !void {
    var merged = std.ArrayList(SupportTrace).init(allocator);
    errdefer {
        for (merged.items) |*item| item.deinit(allocator);
        merged.deinit();
    }

    for (winner.trace) |item| {
        try merged.append(try cloneSupportTrace(allocator, item));
    }
    for (extra) |item| {
        if (supportTracePresent(merged.items, item)) continue;
        try merged.append(try cloneSupportTrace(allocator, item));
    }

    for (winner.trace) |*item| item.deinit(allocator);
    allocator.free(winner.trace);
    winner.trace = try merged.toOwnedSlice();
}

fn supportTracePresent(existing: []const SupportTrace, next: SupportTrace) bool {
    for (existing) |item| {
        if (item.kind != next.kind) continue;
        if (!std.mem.eql(u8, item.label, next.label)) continue;
        if (!optionalSliceEqual(item.rel_path, next.rel_path)) continue;
        if (item.line != next.line) continue;
        if (!optionalSliceEqual(item.reason, next.reason)) continue;
        return true;
    }
    return false;
}

fn cloneSupportTrace(allocator: std.mem.Allocator, item: SupportTrace) !SupportTrace {
    return .{
        .kind = item.kind,
        .label = try allocator.dupe(u8, item.label),
        .rel_path = if (item.rel_path) |rel_path| try allocator.dupe(u8, rel_path) else null,
        .line = item.line,
        .score = item.score,
        .reason = if (item.reason) |reason| try allocator.dupe(u8, reason) else null,
    };
}

fn cloneCodeIntelCorpusTrace(allocator: std.mem.Allocator, trace: code_intel.CorpusTrace) !code_intel.CorpusTrace {
    return .{
        .class_name = try allocator.dupe(u8, trace.class_name),
        .source_rel_path = try allocator.dupe(u8, trace.source_rel_path),
        .source_label = try allocator.dupe(u8, trace.source_label),
        .provenance = try allocator.dupe(u8, trace.provenance),
        .trust_class = trace.trust_class,
        .lineage_id = try allocator.dupe(u8, trace.lineage_id),
        .lineage_version = trace.lineage_version,
    };
}

fn deinitCodeIntelCorpusTrace(allocator: std.mem.Allocator, trace: code_intel.CorpusTrace) void {
    allocator.free(trace.class_name);
    allocator.free(trace.source_rel_path);
    allocator.free(trace.source_label);
    allocator.free(trace.provenance);
    allocator.free(trace.lineage_id);
}

fn cloneCodeIntelEvidence(allocator: std.mem.Allocator, item: code_intel.Evidence) !code_intel.Evidence {
    return .{
        .rel_path = try allocator.dupe(u8, item.rel_path),
        .line = item.line,
        .reason = try allocator.dupe(u8, item.reason),
        .subsystem = try allocator.dupe(u8, item.subsystem),
        .routing = if (item.routing) |routing| try allocator.dupe(u8, routing) else null,
        .corpus = if (item.corpus) |corpus| try cloneCodeIntelCorpusTrace(allocator, corpus) else null,
    };
}

fn deinitCodeIntelEvidenceSlice(allocator: std.mem.Allocator, items: []const code_intel.Evidence) void {
    for (items) |item| {
        allocator.free(item.rel_path);
        allocator.free(item.reason);
        allocator.free(item.subsystem);
        if (item.routing) |routing| allocator.free(routing);
        if (item.corpus) |corpus| deinitCodeIntelCorpusTrace(allocator, corpus);
    }
}

fn cloneCodeIntelEvidenceSlice(allocator: std.mem.Allocator, items: []const code_intel.Evidence) ![]code_intel.Evidence {
    var out = try allocator.alloc(code_intel.Evidence, items.len);
    var built: usize = 0;
    errdefer {
        deinitCodeIntelEvidenceSlice(allocator, out[0..built]);
        allocator.free(out);
    }
    for (items, 0..) |item, idx| {
        out[idx] = try cloneCodeIntelEvidence(allocator, item);
        built += 1;
    }
    return out;
}

fn cloneCodeIntelAbstractionTrace(allocator: std.mem.Allocator, item: code_intel.AbstractionTrace) !code_intel.AbstractionTrace {
    return .{
        .label = try allocator.dupe(u8, item.label),
        .family = item.family,
        .source_spec = try allocator.dupe(u8, item.source_spec),
        .tier = item.tier,
        .category = item.category,
        .selection_mode = item.selection_mode,
        .staged = item.staged,
        .owner_kind = item.owner_kind,
        .owner_id = try allocator.dupe(u8, item.owner_id),
        .quality_score = item.quality_score,
        .confidence_score = item.confidence_score,
        .lookup_score = item.lookup_score,
        .direct_support_count = item.direct_support_count,
        .lineage_support_count = item.lineage_support_count,
        .trust_class = item.trust_class,
        .lineage_id = try allocator.dupe(u8, item.lineage_id),
        .lineage_version = item.lineage_version,
        .consensus_hash = item.consensus_hash,
        .usable = item.usable,
        .reuse_decision = item.reuse_decision,
        .resolution = item.resolution,
        .conflict_kind = item.conflict_kind,
        .conflict_concept = if (item.conflict_concept) |value| try allocator.dupe(u8, value) else null,
        .conflict_owner_id = if (item.conflict_owner_id) |value| try allocator.dupe(u8, value) else null,
        .conflict_owner_kind = item.conflict_owner_kind,
        .pack_outcome = item.pack_outcome,
        .pack_conflict_category = item.pack_conflict_category,
        .supporting_concept = if (item.supporting_concept) |value| try allocator.dupe(u8, value) else null,
        .parent_concept = if (item.parent_concept) |value| try allocator.dupe(u8, value) else null,
    };
}

fn deinitCodeIntelAbstractionSlice(allocator: std.mem.Allocator, items: []const code_intel.AbstractionTrace) void {
    for (items) |item| {
        allocator.free(item.label);
        allocator.free(item.source_spec);
        allocator.free(item.owner_id);
        allocator.free(item.lineage_id);
        if (item.conflict_concept) |value| allocator.free(value);
        if (item.conflict_owner_id) |value| allocator.free(value);
        if (item.supporting_concept) |value| allocator.free(value);
        if (item.parent_concept) |value| allocator.free(value);
    }
}

fn cloneCodeIntelAbstractionSlice(allocator: std.mem.Allocator, items: []const code_intel.AbstractionTrace) ![]code_intel.AbstractionTrace {
    var out = try allocator.alloc(code_intel.AbstractionTrace, items.len);
    var built: usize = 0;
    errdefer {
        deinitCodeIntelAbstractionSlice(allocator, out[0..built]);
        allocator.free(out);
    }
    for (items, 0..) |item, idx| {
        out[idx] = try cloneCodeIntelAbstractionTrace(allocator, item);
        built += 1;
    }
    return out;
}

fn cloneCodeIntelGroundingTrace(allocator: std.mem.Allocator, item: code_intel.GroundingTrace) !code_intel.GroundingTrace {
    return .{
        .direction = item.direction,
        .surface = try allocator.dupe(u8, item.surface),
        .concept = try allocator.dupe(u8, item.concept),
        .source_spec = try allocator.dupe(u8, item.source_spec),
        .matched_source_spec = if (item.matched_source_spec) |value| try allocator.dupe(u8, value) else null,
        .selection_mode = item.selection_mode,
        .owner_kind = item.owner_kind,
        .owner_id = try allocator.dupe(u8, item.owner_id),
        .relation = try allocator.dupe(u8, item.relation),
        .lookup_score = item.lookup_score,
        .confidence_score = item.confidence_score,
        .trust_class = item.trust_class,
        .lineage_id = try allocator.dupe(u8, item.lineage_id),
        .lineage_version = item.lineage_version,
        .token_support_count = item.token_support_count,
        .pattern_support_count = item.pattern_support_count,
        .source_support_count = item.source_support_count,
        .mapping_score = item.mapping_score,
        .usable = item.usable,
        .ambiguous = item.ambiguous,
        .resolution = item.resolution,
        .conflict_kind = item.conflict_kind,
        .target_label = if (item.target_label) |value| try allocator.dupe(u8, value) else null,
        .target_rel_path = if (item.target_rel_path) |value| try allocator.dupe(u8, value) else null,
        .target_line = item.target_line,
        .target_kind = if (item.target_kind) |value| try allocator.dupe(u8, value) else null,
        .detail = if (item.detail) |value| try allocator.dupe(u8, value) else null,
    };
}

fn deinitCodeIntelGroundingSlice(allocator: std.mem.Allocator, items: []const code_intel.GroundingTrace) void {
    for (items) |item| {
        allocator.free(item.surface);
        allocator.free(item.concept);
        allocator.free(item.source_spec);
        if (item.matched_source_spec) |value| allocator.free(value);
        allocator.free(item.owner_id);
        allocator.free(item.relation);
        allocator.free(item.lineage_id);
        if (item.target_label) |value| allocator.free(value);
        if (item.target_rel_path) |value| allocator.free(value);
        if (item.target_kind) |value| allocator.free(value);
        if (item.detail) |value| allocator.free(value);
    }
}

fn cloneCodeIntelGroundingSlice(allocator: std.mem.Allocator, items: []const code_intel.GroundingTrace) ![]code_intel.GroundingTrace {
    var out = try allocator.alloc(code_intel.GroundingTrace, items.len);
    var built: usize = 0;
    errdefer {
        deinitCodeIntelGroundingSlice(allocator, out[0..built]);
        allocator.free(out);
    }
    for (items, 0..) |item, idx| {
        out[idx] = try cloneCodeIntelGroundingTrace(allocator, item);
        built += 1;
    }
    return out;
}

fn intelPackRoutingClone(allocator: std.mem.Allocator, items: []const abstractions.PackRoutingTrace) ![]abstractions.PackRoutingTrace {
    var out = try allocator.alloc(abstractions.PackRoutingTrace, items.len);
    var built: usize = 0;
    errdefer {
        for (out[0..built]) |*trace| trace.deinit();
        allocator.free(out);
    }
    for (items, 0..) |item, idx| {
        out[idx] = try abstractions.clonePackRoutingTrace(allocator, item);
        built += 1;
    }
    return out;
}

fn candidatesSemanticallyEquivalent(allocator: std.mem.Allocator, lhs: *const Candidate, rhs: Candidate) bool {
    if (lhs.files.len != rhs.files.len) return false;
    if (lhs.rewrite_operators.len != rhs.rewrite_operators.len) return false;
    if (lhs.hunks.len != rhs.hunks.len) return false;

    for (lhs.files, rhs.files) |lhs_file, rhs_file| {
        if (!std.mem.eql(u8, lhs_file, rhs_file)) return false;
    }
    for (lhs.rewrite_operators, rhs.rewrite_operators) |lhs_op, rhs_op| {
        if (lhs_op != rhs_op) return false;
    }
    for (lhs.hunks, rhs.hunks) |lhs_hunk, rhs_hunk| {
        if (!patchHunksEquivalent(allocator, lhs_hunk, rhs_hunk)) return false;
    }
    return true;
}

fn patchHunksEquivalent(allocator: std.mem.Allocator, lhs: PatchHunk, rhs: PatchHunk) bool {
    if (!std.mem.eql(u8, lhs.rel_path, rhs.rel_path)) return false;
    if (lhs.anchor_line != rhs.anchor_line or lhs.start_line != rhs.start_line or lhs.end_line != rhs.end_line) return false;

    const lhs_normalized = normalizeGeneratedImplNames(allocator, lhs.diff) catch return false;
    defer allocator.free(lhs_normalized);
    const rhs_normalized = normalizeGeneratedImplNames(allocator, rhs.diff) catch return false;
    defer allocator.free(rhs_normalized);
    return std.mem.eql(u8, lhs_normalized, rhs_normalized);
}

fn normalizeGeneratedImplNames(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();

    var idx: usize = 0;
    while (idx < text.len) {
        if (startsGeneratedImplSymbol(text[idx..])) |symbol_len| {
            try out.appendSlice("__ghost_candidate_impl");
            idx += symbol_len;
            continue;
        }
        try out.append(text[idx]);
        idx += 1;
    }
    return out.toOwnedSlice();
}

fn startsGeneratedImplSymbol(text: []const u8) ?usize {
    const prefix = "__ghost_c";
    if (!std.mem.startsWith(u8, text, prefix)) return null;
    var idx = prefix.len;
    if (idx >= text.len or !std.ascii.isDigit(text[idx])) return null;
    while (idx < text.len and std.ascii.isDigit(text[idx])) : (idx += 1) {}
    const suffix = "_impl";
    if (idx + suffix.len > text.len) return null;
    if (!std.mem.eql(u8, text[idx .. idx + suffix.len], suffix)) return null;
    return idx + suffix.len;
}

fn optionalSliceEqual(lhs: ?[]const u8, rhs: ?[]const u8) bool {
    if (lhs == null and rhs == null) return true;
    if (lhs == null or rhs == null) return false;
    return std.mem.eql(u8, lhs.?, rhs.?);
}

fn buildCandidate(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    intel: *const code_intel.Result,
    abstraction_refs: []const abstractions.SupportReference,
    surfaces: []const SurfaceSeed,
    caps: Caps,
    plan: PlanSeed,
    ordinal: u32,
) !?Candidate {
    const focus_surface = surfaces[plan.surface_indexes[0]];
    var synthesis = (try synthesizeCandidate(
        allocator,
        repo_root,
        intel,
        abstraction_refs,
        surfaces,
        caps,
        plan,
        ordinal,
    )) orelse return null;
    errdefer synthesis.deinit(allocator);

    const candidate_score = plan.strategy_score +% focus_surface.score -% @min(ordinal * 12, plan.strategy_score / 2);
    var bound_artifacts = std.ArrayList([]u8).init(allocator);
    errdefer {
        for (bound_artifacts.items) |item| allocator.free(item);
        bound_artifacts.deinit();
    }
    try appendUniqueOwnedPath(&bound_artifacts, allocator, focus_surface.rel_path);
    for (plan.surface_indexes[1..plan.surface_count]) |surface_idx| {
        try appendUniqueOwnedPath(&bound_artifacts, allocator, surfaces[surface_idx].rel_path);
    }

    var obligations = std.ArrayList([]u8).init(allocator);
    errdefer {
        for (obligations.items) |item| allocator.free(item);
        obligations.deinit();
    }
    try appendCandidateObligations(allocator, &obligations, intel, plan);

    const candidate = Candidate{
        .id = try std.fmt.allocPrint(allocator, "candidate_{d}", .{ordinal + 1}),
        .source_intent = try allocator.dupe(u8, intel.query_target),
        .action_surface = try allocator.dupe(u8, strategyName(plan.strategy)),
        .bound_artifacts = try bound_artifacts.toOwnedSlice(),
        .required_obligations = try obligations.toOwnedSlice(),
        .summary = synthesis.summary,
        .strategy = try allocator.dupe(u8, strategyName(plan.strategy)),
        .scope = try allocator.dupe(u8, scopeModeName(plan.scope_mode)),
        .exploration_rank = ordinal + 1,
        .score = candidate_score,
        .minimality = plan.minimality,
        .files = synthesis.files,
        .rewrite_operators = synthesis.rewrite_operators,
        .hunks = synthesis.hunks,
        .trace = synthesis.trace,
    };
    return candidate;
}

fn appendCandidateObligations(
    allocator: std.mem.Allocator,
    out: *std.ArrayList([]u8),
    intel: *const code_intel.Result,
    plan: PlanSeed,
) !void {
    try out.append(try allocator.dupe(u8, "expand_support_graph"));
    try out.append(try allocator.dupe(u8, "discharge_patch_obligations"));
    if (plan.scope_mode == .expanded) try out.append(try allocator.dupe(u8, "verify_neighbor_surface_binding"));
    if (intel.contradiction_traces.len > 0 or intel.partial_support.blocking.contradicted) try out.append(try allocator.dupe(u8, "resolve_contradiction_trace"));
    if (countUsableGroundingAnchors(intel) > 0) try out.append(try allocator.dupe(u8, "preserve_grounding_anchor"));
}

fn synthesizeCandidate(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    intel: *const code_intel.Result,
    abstraction_refs: []const abstractions.SupportReference,
    surfaces: []const SurfaceSeed,
    caps: Caps,
    plan: PlanSeed,
    ordinal: u32,
) !?SynthesisOutput {
    var files = std.ArrayList([]u8).init(allocator);
    defer {
        for (files.items) |item| allocator.free(item);
        files.deinit();
    }
    var rewrite_ops = std.ArrayList(RewriteOperator).init(allocator);
    defer rewrite_ops.deinit();
    var hunks = std.ArrayList(PatchHunk).init(allocator);
    defer {
        for (hunks.items) |*hunk| hunk.deinit(allocator);
        hunks.deinit();
    }
    var trace = std.ArrayList(SupportTrace).init(allocator);
    defer {
        for (trace.items) |*item| item.deinit(allocator);
        trace.deinit();
    }

    try trace.append(try makeSupportTrace(allocator, .strategy, strategyName(plan.strategy), null, 0, plan.strategy_score, "Deterministic refactor planner retained this bounded patch strategy"));
    if (intel.primary) |subject| {
        try trace.append(try makeSupportTrace(allocator, .code_intel_primary, subject.name, subject.rel_path, subject.line, 255, subject.kind_name));
    } else {
        return null;
    }
    for (plan.surface_indexes[0..plan.surface_count]) |surface_idx| {
        try trace.append(try makeSurfaceTrace(allocator, surfaces[surface_idx]));
    }
    if (intel.target_candidates.len > 0) {
        const selected = intel.target_candidates[0];
        try trace.append(try makeSupportTrace(allocator, .code_intel_target, selected.label, null, 0, selected.score, "Layer 2a target candidate"));
    }
    if (intel.query_hypotheses.len > 0) {
        const selected = intel.query_hypotheses[0];
        try trace.append(try makeSupportTrace(allocator, .code_intel_hypothesis, selected.label, null, 0, selected.score, "Layer 2b query hypothesis"));
    }
    for (abstraction_refs, 0..) |reference, idx| {
        if (idx >= caps.max_abstractions) break;
        try trace.append(try makeSupportTrace(
            allocator,
            if (reference.staged) .abstraction_staged else .abstraction_live,
            reference.concept_id,
            null,
            0,
            reference.lookup_score,
            reference.source_spec,
        ));
    }

    const primary = intel.primary.?;
    if (!std.mem.eql(u8, primary.kind_name, "function")) return null;

    if (std.mem.endsWith(u8, primary.rel_path, ".zig")) {
        return synthesizeZigFunctionCandidate(
            allocator,
            repo_root,
            intel,
            surfaces,
            caps,
            plan,
            ordinal,
            &files,
            &rewrite_ops,
            &hunks,
            &trace,
        );
    }

    return null;
}

fn synthesizeZigFunctionCandidate(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    intel: *const code_intel.Result,
    surfaces: []const SurfaceSeed,
    caps: Caps,
    plan: PlanSeed,
    ordinal: u32,
    files: *std.ArrayList([]u8),
    rewrite_ops: *std.ArrayList(RewriteOperator),
    hunks: *std.ArrayList(PatchHunk),
    trace: *std.ArrayList(SupportTrace),
) !?SynthesisOutput {
    const primary = intel.primary.?;
    const impl_name = try std.fmt.allocPrint(allocator, "{s}__ghost_c{d}_impl", .{ primary.name, ordinal + 1 });
    defer allocator.free(impl_name);
    const call_style = wrapperCallStyle(plan.strategy);

    const target_abs_path = try std.fs.path.join(allocator, &.{ repo_root, primary.rel_path });
    defer allocator.free(target_abs_path);
    const target_body = try readOwnedFile(allocator, target_abs_path, MAX_SOURCE_FILE_BYTES);
    defer allocator.free(target_body);

    const decl = (try findZigFunctionDecl(allocator, target_body, primary.name, primary.line)) orelse return null;
    defer decl.deinit(allocator);
    const call_args = try buildZigForwardedArguments(allocator, target_body, decl);
    defer allocator.free(call_args);

    const target_updated = try buildZigSignatureAdapterEdit(allocator, target_body, decl, primary.name, impl_name, call_args, call_style);
    defer allocator.free(target_updated);
    const target_hunk = (try buildPatchHunkFromBodies(allocator, primary.rel_path, target_body, target_updated, primary.line, caps.max_lines_per_hunk)) orelse return null;
    try hunks.append(target_hunk);
    try appendUniqueOwnedPath(files, allocator, primary.rel_path);
    try appendRewriteOperator(rewrite_ops, .signature_adapter_generation);
    try appendRewriteTrace(allocator, trace, .signature_adapter_generation, primary.rel_path, primary.line, "generated a bounded wrapper that preserves the original Zig function surface");
    try appendRewriteOperator(rewrite_ops, .structural_rename_update);
    try appendRewriteTrace(allocator, trace, .structural_rename_update, primary.rel_path, primary.line, "renamed the implementation surface to a deterministic synthesized symbol");
    if (call_args.len > 0) {
        try appendRewriteOperator(rewrite_ops, .parameter_threading);
        try appendRewriteTrace(allocator, trace, .parameter_threading, primary.rel_path, primary.line, "threaded the original parameter names through the synthesized wrapper without inventing new values");
    }
    if (call_style != .direct) {
        try appendRewriteOperator(rewrite_ops, .dispatch_indirection);
        try appendRewriteTrace(allocator, trace, .dispatch_indirection, primary.rel_path, primary.line, wrapperCallStyleReason(plan.strategy));
    }

    var expanded_surface_count: usize = 0;
    if (plan.scope_mode == .expanded) {
        for (plan.surface_indexes[1..plan.surface_count]) |surface_idx| {
            const extra_surface = surfaces[surface_idx];
            if (std.mem.eql(u8, extra_surface.rel_path, primary.rel_path)) continue;
            if (!std.mem.endsWith(u8, extra_surface.rel_path, ".zig")) return null;
            const extra_abs_path = try std.fs.path.join(allocator, &.{ repo_root, extra_surface.rel_path });
            defer allocator.free(extra_abs_path);
            const extra_body = try readOwnedFile(allocator, extra_abs_path, MAX_SOURCE_FILE_BYTES);
            defer allocator.free(extra_body);

            const extra_updated = (try adaptQualifiedZigCallSites(allocator, extra_body, primary.name, impl_name)) orelse return null;
            defer allocator.free(extra_updated);
            const extra_hunk = (try buildPatchHunkFromBodies(allocator, extra_surface.rel_path, extra_body, extra_updated, extra_surface.line, caps.max_lines_per_hunk)) orelse return null;
            try hunks.append(extra_hunk);
            try appendUniqueOwnedPath(files, allocator, extra_surface.rel_path);
            try appendRewriteOperator(rewrite_ops, .call_site_adaptation);
            try appendRewriteTrace(allocator, trace, .call_site_adaptation, extra_surface.rel_path, extra_surface.line, "adapted a bounded dependent Zig call-site to the synthesized implementation symbol");
            expanded_surface_count += 1;
        }
        if (expanded_surface_count == 0) return null;
    }

    const summary = if (plan.scope_mode == .expanded)
        try std.fmt.allocPrint(allocator, "Synthesized Zig signature adapter and {d} dependent caller rewrites for {s}:{d}", .{ expanded_surface_count, primary.rel_path, primary.line })
    else
        try std.fmt.allocPrint(allocator, "Synthesized Zig signature adapter for {s}:{d}", .{ primary.rel_path, primary.line });

    return .{
        .summary = summary,
        .files = try files.toOwnedSlice(),
        .rewrite_operators = try rewrite_ops.toOwnedSlice(),
        .hunks = try hunks.toOwnedSlice(),
        .trace = try trace.toOwnedSlice(),
    };
}

const ZigFunctionDecl = struct {
    allocator: std.mem.Allocator,
    decl_start: usize,
    fn_index: usize,
    name_start: usize,
    name_end: usize,
    params_start: usize,
    params_end: usize,
    body_start: usize,
    body_end: usize,
    line: u32,

    fn deinit(self: ZigFunctionDecl, allocator: std.mem.Allocator) void {
        _ = allocator;
        _ = self;
    }
};

const WrapperCallStyle = enum {
    direct,
    explicit_call,
    indirect_alias,
    block_forward,
};

fn findZigFunctionDecl(allocator: std.mem.Allocator, body: []const u8, symbol: []const u8, approx_line: u32) !?ZigFunctionDecl {
    const pattern = try std.fmt.allocPrint(allocator, "fn {s}(", .{symbol});
    defer allocator.free(pattern);

    var best: ?ZigFunctionDecl = null;
    var best_distance: u32 = std.math.maxInt(u32);
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, body, search_from, pattern)) |fn_index| {
        search_from = fn_index + pattern.len;
        const name_start = fn_index + 3;
        const params_start = name_start + symbol.len;
        const params_end = (try findMatchingDelimiter(body, params_start, '(', ')')) orelse continue;
        const body_start = std.mem.indexOfScalarPos(u8, body, params_end + 1, '{') orelse continue;
        const body_end_close = (try findMatchingDelimiter(body, body_start, '{', '}')) orelse continue;
        const line = lineNumberAtOffset(body, fn_index);
        const distance = if (line > approx_line) line - approx_line else approx_line - line;
        if (distance > best_distance) continue;
        const decl_start = lineStartOffset(body, fn_index);
        best = .{
            .allocator = allocator,
            .decl_start = decl_start,
            .fn_index = fn_index,
            .name_start = name_start,
            .name_end = name_start + symbol.len,
            .params_start = params_start,
            .params_end = params_end,
            .body_start = body_start,
            .body_end = body_end_close + 1,
            .line = line,
        };
        best_distance = distance;
    }
    return best;
}

fn buildZigForwardedArguments(allocator: std.mem.Allocator, body: []const u8, decl: ZigFunctionDecl) ![]u8 {
    const params = body[decl.params_start + 1 .. decl.params_end];
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();

    var part_start: usize = 0;
    var depth_paren: u32 = 0;
    var depth_brace: u32 = 0;
    var depth_bracket: u32 = 0;
    var idx: usize = 0;
    var emitted: usize = 0;
    while (idx <= params.len) : (idx += 1) {
        const at_end = idx == params.len;
        if (!at_end) switch (params[idx]) {
            '(' => depth_paren += 1,
            ')' => {
                if (depth_paren > 0) depth_paren -= 1;
            },
            '{' => depth_brace += 1,
            '}' => {
                if (depth_brace > 0) depth_brace -= 1;
            },
            '[' => depth_bracket += 1,
            ']' => {
                if (depth_bracket > 0) depth_bracket -= 1;
            },
            else => {},
        };
        const at_split = at_end or (params[idx] == ',' and depth_paren == 0 and depth_brace == 0 and depth_bracket == 0);
        if (!at_split) continue;

        const raw_part = std.mem.trim(u8, params[part_start..idx], " \r\n\t");
        part_start = idx + 1;
        if (raw_part.len == 0) continue;
        if (std.mem.eql(u8, raw_part, "...")) return error.UnsupportedZigSignature;
        const colon_idx = std.mem.indexOfScalar(u8, raw_part, ':') orelse return error.UnsupportedZigSignature;
        var name = std.mem.trim(u8, raw_part[0..colon_idx], " \r\n\t");
        name = stripZigParamPrefix(name, "comptime ");
        name = stripZigParamPrefix(name, "noalias ");
        name = stripZigParamPrefix(name, "comptime ");
        name = std.mem.trim(u8, name, " \r\n\t");
        if (std.mem.lastIndexOfScalar(u8, name, ' ')) |space_idx| name = std.mem.trim(u8, name[space_idx + 1 ..], " \r\n\t");
        if (name.len == 0 or std.mem.eql(u8, name, "_")) return error.UnsupportedZigSignature;
        if (emitted != 0) try out.appendSlice(", ");
        try out.appendSlice(name);
        emitted += 1;
    }

    return out.toOwnedSlice();
}

fn stripZigParamPrefix(text: []const u8, prefix: []const u8) []const u8 {
    if (std.mem.startsWith(u8, text, prefix)) return text[prefix.len..];
    return text;
}

fn buildZigSignatureAdapterEdit(
    allocator: std.mem.Allocator,
    body: []const u8,
    decl: ZigFunctionDecl,
    original_name: []const u8,
    impl_name: []const u8,
    call_args: []const u8,
    call_style: WrapperCallStyle,
) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const writer = out.writer();

    try writer.writeAll(body[0..decl.name_start]);
    try writer.writeAll(impl_name);
    try writer.writeAll(body[decl.name_end..decl.body_end]);
    try writer.writeAll("\n\n");
    try writer.writeAll(body[decl.decl_start..decl.name_start]);
    try writer.writeAll(original_name);
    try writer.writeAll(body[decl.name_end..decl.body_start]);
    try writer.writeAll("{\n");
    const return_type = std.mem.trim(u8, body[decl.params_end + 1 .. decl.body_start], " \r\n\t");
    try writeZigWrapperDispatch(writer, call_style, impl_name, call_args, std.mem.eql(u8, return_type, "void"));
    try writer.writeAll("\n}");
    try writer.writeAll(body[decl.body_end..]);

    return out.toOwnedSlice();
}

fn wrapperCallStyle(strategy: Strategy) WrapperCallStyle {
    return switch (strategy) {
        .local_guard => .direct,
        .seam_adapter => .explicit_call,
        .contradiction_split => .indirect_alias,
        .abstraction_alignment => .block_forward,
    };
}

fn wrapperCallStyleReason(strategy: Strategy) []const u8 {
    return switch (strategy) {
        .local_guard => "retained a direct wrapper call because the local guard strategy did not need extra dispatch indirection",
        .seam_adapter => "routed the wrapper through an explicit call adapter so seam-oriented verification can inspect the dispatch boundary directly",
        .contradiction_split => "introduced a named implementation binding so contradiction-oriented verification can inspect wrapper dispatch independently",
        .abstraction_alignment => "materialized the forwarded return boundary so abstraction-backed verification can inspect the wrapper result explicitly",
    };
}

fn writeZigWrapperDispatch(
    writer: anytype,
    call_style: WrapperCallStyle,
    impl_name: []const u8,
    call_args: []const u8,
    returns_void: bool,
) !void {
    switch (call_style) {
        .direct => {
            try writer.writeAll("    ");
            if (!returns_void) try writer.writeAll("return ");
            try writer.print("{s}(", .{impl_name});
            try writer.writeAll(call_args);
            try writer.writeAll(");");
        },
        .explicit_call => {
            try writer.writeAll("    ");
            if (!returns_void) try writer.writeAll("return ");
            try writer.print("@call(.auto, {s}, .{{", .{impl_name});
            if (call_args.len > 0) try writer.writeAll(call_args);
            try writer.writeAll("});");
        },
        .indirect_alias => {
            try writer.print("    const forwarded_impl = {s};\n    ", .{impl_name});
            if (!returns_void) try writer.writeAll("return ");
            try writer.writeAll("forwarded_impl(");
            try writer.writeAll(call_args);
            try writer.writeAll(");");
        },
        .block_forward => {
            if (returns_void) {
                try writer.print("    {s}(", .{impl_name});
                try writer.writeAll(call_args);
                try writer.writeAll(");\n    return;");
            } else {
                try writer.print("    const forwarded_result = {s}(", .{impl_name});
                try writer.writeAll(call_args);
                try writer.writeAll(");\n    return forwarded_result;");
            }
        },
    }
}

fn adaptQualifiedZigCallSites(
    allocator: std.mem.Allocator,
    body: []const u8,
    original_name: []const u8,
    replacement_name: []const u8,
) !?[]u8 {
    const needle = try std.fmt.allocPrint(allocator, ".{s}(", .{original_name});
    defer allocator.free(needle);
    const replacement = try std.fmt.allocPrint(allocator, ".{s}(", .{replacement_name});
    defer allocator.free(replacement);

    var count: usize = 0;
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, body, search_from, needle)) |match| {
        count += 1;
        search_from = match + needle.len;
    }
    if (count == 0 or count > 2) return null;

    return try std.mem.replaceOwned(u8, allocator, body, needle, replacement);
}

fn findExpandedTargetSurface(surfaces: []const SurfaceSeed, plan: PlanSeed, target_rel_path: []const u8) ?SurfaceSeed {
    for (plan.surface_indexes[0..plan.surface_count]) |surface_idx| {
        const surface = surfaces[surface_idx];
        if (std.mem.eql(u8, surface.rel_path, target_rel_path)) continue;
        return surface;
    }
    for (surfaces) |surface| {
        if (!std.mem.eql(u8, surface.rel_path, target_rel_path)) return surface;
    }
    return null;
}

fn appendUniqueOwnedPath(out: *std.ArrayList([]u8), allocator: std.mem.Allocator, rel_path: []const u8) !void {
    for (out.items) |existing| {
        if (std.mem.eql(u8, existing, rel_path)) return;
    }
    try out.append(try allocator.dupe(u8, rel_path));
}

fn appendRewriteOperator(out: *std.ArrayList(RewriteOperator), operator_kind: RewriteOperator) !void {
    for (out.items) |existing| {
        if (existing == operator_kind) return;
    }
    try out.append(operator_kind);
}

fn appendRewriteTrace(
    allocator: std.mem.Allocator,
    trace: *std.ArrayList(SupportTrace),
    operator_kind: RewriteOperator,
    rel_path: []const u8,
    line: u32,
    reason: []const u8,
) !void {
    try trace.append(try makeSupportTrace(
        allocator,
        .rewrite_operator,
        rewriteOperatorName(operator_kind),
        rel_path,
        line,
        0,
        reason,
    ));
}

fn buildPatchHunkFromBodies(
    allocator: std.mem.Allocator,
    rel_path: []const u8,
    original: []const u8,
    updated: []const u8,
    anchor_line: u32,
    max_lines: u32,
) !?PatchHunk {
    if (std.mem.eql(u8, original, updated)) return null;

    const original_lines = try splitLineSlices(allocator, original);
    defer allocator.free(original_lines);
    const updated_lines = try splitLineSlices(allocator, updated);
    defer allocator.free(updated_lines);

    var prefix: usize = 0;
    while (prefix < original_lines.len and prefix < updated_lines.len and std.mem.eql(u8, original_lines[prefix], updated_lines[prefix])) : (prefix += 1) {}

    var suffix: usize = 0;
    while (suffix < original_lines.len - prefix and suffix < updated_lines.len - prefix and
        std.mem.eql(u8, original_lines[original_lines.len - 1 - suffix], updated_lines[updated_lines.len - 1 - suffix])) : (suffix += 1)
    {}

    const old_count = original_lines.len - prefix - suffix;
    const new_count = updated_lines.len - prefix - suffix;
    if (@max(old_count, new_count) > @as(usize, max_lines)) return null;

    const start_line: u32 = @intCast(prefix + 1);
    const end_line: u32 = @intCast(prefix + old_count);

    var diff = std.ArrayList(u8).init(allocator);
    errdefer diff.deinit();
    try diff.writer().print("--- a/{s}\n+++ b/{s}\n@@ -{d},{d} +{d},{d} @@\n", .{
        rel_path,
        rel_path,
        start_line,
        old_count,
        start_line,
        new_count,
    });
    for (original_lines[prefix .. prefix + old_count]) |line| {
        try diff.append('-');
        try diff.appendSlice(line);
        try diff.append('\n');
    }
    for (updated_lines[prefix .. prefix + new_count]) |line| {
        try diff.append('+');
        try diff.appendSlice(line);
        try diff.append('\n');
    }

    return .{
        .rel_path = try allocator.dupe(u8, rel_path),
        .anchor_line = anchor_line,
        .start_line = start_line,
        .end_line = end_line,
        .diff = try diff.toOwnedSlice(),
    };
}

fn splitLineSlices(allocator: std.mem.Allocator, body: []const u8) ![][]const u8 {
    var out = std.ArrayList([]const u8).init(allocator);
    errdefer out.deinit();
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |line| try out.append(std.mem.trimRight(u8, line, "\r"));
    return out.toOwnedSlice();
}

fn lineStartOffset(body: []const u8, offset: usize) usize {
    var idx = offset;
    while (idx > 0 and body[idx - 1] != '\n') : (idx -= 1) {}
    return idx;
}

fn lineNumberAtOffset(body: []const u8, offset: usize) u32 {
    var line: u32 = 1;
    for (body[0..@min(offset, body.len)]) |byte| {
        if (byte == '\n') line += 1;
    }
    return line;
}

fn findMatchingDelimiter(body: []const u8, open_index: usize, open_char: u8, close_char: u8) !?usize {
    if (open_index >= body.len or body[open_index] != open_char) return null;
    var depth: u32 = 0;
    var idx = open_index;
    while (idx < body.len) : (idx += 1) {
        const byte = body[idx];
        if (byte == '"' or byte == '\'') {
            idx = skipQuotedLiteral(body, idx) orelse return null;
            continue;
        }
        if (byte == '/' and idx + 1 < body.len and body[idx + 1] == '/') {
            idx = skipLineComment(body, idx + 2);
            continue;
        }
        if (byte == open_char) {
            depth += 1;
            continue;
        }
        if (byte == close_char) {
            depth -= 1;
            if (depth == 0) return idx;
        }
    }
    return null;
}

fn skipQuotedLiteral(body: []const u8, start: usize) ?usize {
    const quote = body[start];
    var idx = start + 1;
    while (idx < body.len) : (idx += 1) {
        if (body[idx] == '\\') {
            idx += 1;
            continue;
        }
        if (body[idx] == quote) return idx;
    }
    return null;
}

fn skipLineComment(body: []const u8, start: usize) usize {
    var idx = start;
    while (idx < body.len and body[idx] != '\n') : (idx += 1) {}
    return idx;
}

fn appendPlanSeed(
    out: *std.ArrayList(PlanSeed),
    intel: *const code_intel.Result,
    surfaces: []const SurfaceSeed,
    option: StrategyOption,
    scope_mode: ScopeMode,
    focus_idx: u8,
    extra_indexes: ?[]const u8,
) !void {
    var seed = PlanSeed{
        .strategy = option.strategy,
        .strategy_score = option.score,
        .scope_mode = scope_mode,
    };
    seed.surface_indexes[0] = focus_idx;
    seed.surface_count = 1;
    if (extra_indexes) |indexes| {
        for (indexes) |idx| {
            if (idx == focus_idx) continue;
            if (seed.surface_count >= seed.surface_indexes.len) break;
            seed.surface_indexes[seed.surface_count] = idx;
            seed.surface_count += 1;
        }
    }
    seed.minimality = computeMinimalityEvidence(intel, surfaces, seed);
    try out.append(seed);
}

pub const CodeInterventionPolicy = struct {
    file_cost: u32 = 400,
    hunk_cost: u32 = 120,
    change_cost: u32 = 40,
    dependency_cost: u32 = 220,
    focused_scope_penalty: u32 = 40,
    expanded_scope_penalty: u32 = 180,
    max_bounded_cost: u32 = 2000,
};

/// Neutral default policy for non-code artifacts (e.g. docs, recipes, logs)
/// Minimality is a domain policy, not an absolute architectural truth.
/// Non-code tasks often prefer broader structural consistency over localized patches.
pub const ArtifactInterventionPolicy = struct {
    file_cost: u32 = 0,
    hunk_cost: u32 = 10,
    change_cost: u32 = 10,
    dependency_cost: u32 = 0,
    focused_scope_penalty: u32 = 0,
    expanded_scope_penalty: u32 = 0,
    max_bounded_cost: u32 = 2000,
};

pub const DEFAULT_CODE_INTERVENTION_POLICY = CodeInterventionPolicy{};

fn computeMinimalityEvidence(intel: *const code_intel.Result, surfaces: []const SurfaceSeed, seed: PlanSeed) MinimalityEvidence {
    return computeMinimalityEvidenceWithPolicy(intel, surfaces, seed, DEFAULT_CODE_INTERVENTION_POLICY);
}

fn computeMinimalityEvidenceWithPolicy(intel: *const code_intel.Result, surfaces: []const SurfaceSeed, seed: PlanSeed, policy: CodeInterventionPolicy) MinimalityEvidence {
    _ = intel;
    _ = surfaces;
    const file_count: u32 = seed.surface_count;
    const hunk_count: u32 = seed.surface_count;
    const change_count: u32 = seed.surface_count * 2;
    const dependency_spread: u32 = if (seed.surface_count > 0) seed.surface_count - 1 else 0;
    const scope_penalty: u32 = switch (seed.scope_mode) {
        .focused => policy.focused_scope_penalty,
        .expanded => policy.expanded_scope_penalty,
    };
    return .{
        .file_count = file_count,
        .change_count = change_count,
        .hunk_count = hunk_count,
        .dependency_spread = dependency_spread,
        .scope_penalty = scope_penalty,
        .total_cost = file_count * policy.file_cost + hunk_count * policy.hunk_cost + change_count * policy.change_cost + dependency_spread * policy.dependency_cost + scope_penalty,
    };
}

fn lessThanPlanSeed(ctx: []const SurfaceSeed, lhs: PlanSeed, rhs: PlanSeed) bool {
    if (lhs.minimality.total_cost != rhs.minimality.total_cost) return lhs.minimality.total_cost < rhs.minimality.total_cost;
    if (lhs.strategy_score != rhs.strategy_score) return lhs.strategy_score > rhs.strategy_score;
    if (lhs.scope_mode != rhs.scope_mode) return lhs.scope_mode == .focused;
    const lhs_surface = ctx[lhs.surface_indexes[0]];
    const rhs_surface = ctx[rhs.surface_indexes[0]];
    if (lhs_surface.score != rhs_surface.score) return lhs_surface.score > rhs_surface.score;
    if (lhs_surface.line != rhs_surface.line) return lhs_surface.line < rhs_surface.line;
    if (!std.mem.eql(u8, lhs_surface.rel_path, rhs_surface.rel_path)) return std.mem.lessThan(u8, lhs_surface.rel_path, rhs_surface.rel_path);
    return @intFromEnum(lhs.strategy) < @intFromEnum(rhs.strategy);
}

fn exploratoryCandidatePoolCap(caps: Caps) usize {
    return @min(HARD_MAX_CANDIDATES, caps.max_candidates + 1);
}

fn selectPlanSeeds(allocator: std.mem.Allocator, sorted: []const PlanSeed, count_cap: usize) ![]PlanSeed {
    const count = @min(count_cap, sorted.len);
    var selected = std.ArrayList(PlanSeed).init(allocator);
    errdefer selected.deinit();

    for (sorted) |item| {
        if (selected.items.len >= count) break;
        if (item.scope_mode != .focused) continue;
        if (strategyAlreadySelected(selected.items, item.strategy)) continue;
        try selected.append(item);
    }

    for (sorted) |item| {
        if (selected.items.len >= count) break;
        if (planSeedAlreadySelected(selected.items, item)) continue;
        try selected.append(item);
    }

    if (count >= 3 and !containsExpandedSeed(selected.items)) {
        if (findFirstExpandedSeed(sorted)) |expanded| {
            if (selected.items.len < count) {
                try selected.append(expanded);
            } else if (!planSeedAlreadySelected(selected.items, expanded)) {
                selected.items[count - 1] = expanded;
            }
        }
    }

    if (count >= 2 and !strategyAlreadySelected(selected.items, .local_guard)) {
        if (firstFocusedSeedForStrategy(sorted, .local_guard)) |local_guard| {
            if (selected.items.len < count) {
                try selected.append(local_guard);
            } else if (!planSeedAlreadySelected(selected.items, local_guard)) {
                if (lastReplaceableSeedIndexForLocalGuard(selected.items)) |replace_idx| {
                    selected.items[replace_idx] = local_guard;
                }
            }
        }
    }
    return selected.toOwnedSlice();
}

fn strategyAlreadySelected(items: []const PlanSeed, strategy: Strategy) bool {
    for (items) |item| {
        if (item.strategy == strategy) return true;
    }
    return false;
}

fn planSeedAlreadySelected(items: []const PlanSeed, candidate: PlanSeed) bool {
    for (items) |item| {
        if (item.strategy != candidate.strategy) continue;
        if (item.scope_mode != candidate.scope_mode) continue;
        if (item.surface_count != candidate.surface_count) continue;
        if (!std.mem.eql(u8, item.surface_indexes[0..item.surface_count], candidate.surface_indexes[0..candidate.surface_count])) continue;
        return true;
    }
    return false;
}

fn firstFocusedSeedForStrategy(items: []const PlanSeed, strategy: Strategy) ?PlanSeed {
    for (items) |item| {
        if (item.strategy == strategy and item.scope_mode == .focused) return item;
    }
    return null;
}

fn lastReplaceableSeedIndexForLocalGuard(items: []const PlanSeed) ?usize {
    var idx = items.len;
    while (idx > 0) {
        idx -= 1;
        if (items[idx].strategy == .local_guard) continue;
        if (items[idx].scope_mode == .expanded) continue;
        return idx;
    }
    return null;
}

fn prepareExploreToVerifyHandoff(allocator: std.mem.Allocator, caps: Caps, intel: *const code_intel.Result, result: *Result) ![]usize {
    // Candidate generation is allowed to explore more broadly than final output
    // permission. Only the bounded proof queue below is allowed to enter real
    // verification and compete for a supported result.
    result.handoff.exploration = .{
        .mode = EXPLORATION_REASONING_MODE,
        .candidate_pool_limit = @intCast(exploratoryCandidatePoolCap(caps)),
        .generated_candidate_count = @intCast(result.candidates.len),
        .clustered_candidate_count = @intCast(result.candidates.len),
        .proof_queue_limit = @intCast(caps.max_candidates),
    };
    result.handoff.proof = .{ .mode = PROOF_REASONING_MODE };

    if (result.candidates.len == 0) return allocator.alloc(usize, 0);

    var cluster_indexes = try allocator.alloc(usize, result.candidates.len);
    defer allocator.free(cluster_indexes);
    @memset(cluster_indexes, 0);

    var clusters = std.ArrayList(CandidateCluster).init(allocator);
    errdefer {
        for (clusters.items) |*cluster| cluster.deinit(allocator);
        clusters.deinit();
    }

    var candidate_idx: usize = 0;
    while (candidate_idx < result.candidates.len) : (candidate_idx += 1) {
        const candidate = &result.candidates[candidate_idx];
        if (findMatchingCluster(result.candidates, cluster_indexes[0..candidate_idx], clusters.items, candidate_idx)) |cluster_idx| {
            cluster_indexes[candidate_idx] = cluster_idx;
            continue;
        }

        const cluster_id = try std.fmt.allocPrint(allocator, "cluster_{d}", .{clusters.items.len + 1});
        errdefer allocator.free(cluster_id);
        const cluster_label = try buildClusterLabel(allocator, candidate);
        errdefer allocator.free(cluster_label);

        try clusters.append(.{
            .id = cluster_id,
            .label = cluster_label,
        });
        cluster_indexes[candidate_idx] = clusters.items.len - 1;
    }

    for (result.candidates, 0..) |*candidate, idx| {
        const cluster = &clusters.items[cluster_indexes[idx]];
        candidate.cluster_id = try allocator.dupe(u8, cluster.id);
        candidate.cluster_label = try allocator.dupe(u8, cluster.label);
        try appendClusterMemberId(allocator, cluster, candidate.id);
    }

    var selected = try allocator.alloc(bool, result.candidates.len);
    defer allocator.free(selected);
    @memset(selected, false);

    var admissible = try allocator.alloc(bool, result.candidates.len);
    defer allocator.free(admissible);
    @memset(admissible, false);
    for (result.candidates, 0..) |*candidate, idx| {
        candidate.initial_support_estimate = try estimateInitialSupport(allocator, intel, candidate, caps);
        if (!candidate.initial_support_estimate.viable) {
            result.handoff.proof.admission_blocked_count += 1;
            candidate.scheduler_status = .pruned;
            try setCandidateStatus(allocator, candidate, .novel_but_unverified, "cheap support estimate pruned this candidate before full verification");
            continue;
        }
        if (try blockCandidateProofAdmission(allocator, intel, candidate)) {
            result.handoff.proof.admission_blocked_count += 1;
            candidate.scheduler_status = .pruned;
            continue;
        }
        admissible[idx] = true;
    }
    try pruneDominatedCandidates(allocator, result.candidates, admissible);

    const proof_limit = @min(caps.max_candidates, result.candidates.len);
    var queue = std.ArrayList(usize).init(allocator);
    errdefer queue.deinit();

    var cluster_taken = try allocator.alloc(bool, clusters.items.len);
    defer allocator.free(cluster_taken);
    @memset(cluster_taken, false);

    const schedule_order = try buildSchedulingOrder(allocator, result.candidates, admissible);
    defer allocator.free(schedule_order);

    for (schedule_order) |idx| {
        if (queue.items.len >= proof_limit) break;
        if (!admissible[idx]) continue;
        const cluster_idx = cluster_indexes[idx];
        if (cluster_taken[cluster_idx]) continue;
        cluster_taken[cluster_idx] = true;
        selected[idx] = true;
        try queue.append(idx);
    }
    for (schedule_order) |idx| {
        if (queue.items.len >= proof_limit) break;
        if (!admissible[idx]) continue;
        if (selected[idx]) continue;
        selected[idx] = true;
        try queue.append(idx);
    }

    if (queue.items.len > 0 and proof_limit >= 3 and !queueContainsExpandedCandidate(result.candidates, queue.items)) {
        if (firstExpandedCandidateIndex(result.candidates)) |expanded_idx| {
            if (!selected[expanded_idx] and admissible[expanded_idx]) {
                const replace_idx = lastNonExpandedQueueIndex(result.candidates, queue.items) orelse queue.items.len - 1;
                selected[queue.items[replace_idx]] = false;
                queue.items[replace_idx] = expanded_idx;
                selected[expanded_idx] = true;
            }
        }
    }

    if (queue.items.len > 0 and proof_limit >= 2 and !queueContainsLocalGuardFocusedCandidate(result.candidates, queue.items)) {
        if (firstLocalGuardFocusedCandidateIndex(result.candidates)) |local_guard_idx| {
            if (!selected[local_guard_idx] and admissible[local_guard_idx]) {
                const replace_idx = lastReplaceableQueueIndexForLocalGuard(result.candidates, queue.items) orelse queue.items.len - 1;
                selected[queue.items[replace_idx]] = false;
                queue.items[replace_idx] = local_guard_idx;
                selected[local_guard_idx] = true;
            }
        }
    }

    for (result.candidates, 0..) |*candidate, idx| {
        const cluster = &clusters.items[cluster_indexes[idx]];
        if (selected[idx]) {
            cluster.proof_queue_count += 1;
        } else if (admissible[idx]) {
            cluster.preserved_novel_count += 1;
            try setCandidateStatus(allocator, candidate, .novel_but_unverified, "preserved as an exploratory alternative outside the bounded proof queue");
        } else {
            cluster.preserved_novel_count += 1;
        }
    }

    result.handoff.exploration.cluster_count = @intCast(clusters.items.len);
    result.handoff.exploration.proof_queue_count = @intCast(queue.items.len);
    var preserved_novel_count: u32 = 0;
    for (result.candidates) |candidate| {
        if (candidate.status == .novel_but_unverified) preserved_novel_count += 1;
    }
    result.handoff.exploration.preserved_novel_count = preserved_novel_count;
    result.handoff.clusters = try clusters.toOwnedSlice();
    return queue.toOwnedSlice();
}

fn estimateInitialSupport(allocator: std.mem.Allocator, intel: *const code_intel.Result, candidate: *const Candidate, caps: Caps) !SupportEstimate {
    var flags = std.ArrayList([]u8).init(allocator);
    errdefer {
        for (flags.items) |flag| allocator.free(flag);
        flags.deinit();
    }

    if (candidate.hunks.len == 0) try flags.append(try allocator.dupe(u8, "no_patch_hunks"));
    if (candidate.files.len == 0) try flags.append(try allocator.dupe(u8, "no_bound_artifacts"));
    if (candidate.hunks.len > caps.max_hunks_per_candidate) try flags.append(try allocator.dupe(u8, "hunk_budget_exceeded"));
    if (candidate.files.len > caps.max_files) try flags.append(try allocator.dupe(u8, "artifact_budget_exceeded"));
    const cost = candidate.minimality.total_cost + @as(u32, @intCast(candidate.required_obligations.len)) * 90;
    const risk: SupportRiskLevel = if (flags.items.len > 0)
        .high
    else if (intel.partial_support.blocking.contradicted and !candidateHasContradictionEvidence(candidate))
        .high
    else if (candidate.required_obligations.len > 3 or candidate.scope.len > "focused_single_surface".len)
        .medium
    else
        .low;

    return .{
        .viable = flags.items.len == 0,
        .risk_level = risk,
        .estimated_cost = cost,
        .blocking_flags = try flags.toOwnedSlice(),
    };
}

fn pruneDominatedCandidates(allocator: std.mem.Allocator, candidates: []Candidate, admissible: []bool) !void {
    for (candidates, 0..) |candidate, idx| {
        if (!admissible[idx]) continue;
        for (candidates, 0..) |other, other_idx| {
            if (idx == other_idx or !admissible[other_idx]) continue;
            if (!sameCandidateGoal(candidate, other)) continue;
            if (!strictlyDominatesCandidate(other, candidate)) continue;
            admissible[idx] = false;
            candidates[idx].scheduler_status = .pruned;
            const reason = try std.fmt.allocPrint(
                allocator,
                "candidate pruned because {s} has the same goal with lower estimated cost {d} < {d} and no extra obligations",
                .{ other.id, other.initial_support_estimate.estimated_cost, candidate.initial_support_estimate.estimated_cost },
            );
            try setCandidateStatusOwned(allocator, &candidates[idx], .novel_but_unverified, reason);
            break;
        }
    }
}

fn sameCandidateGoal(lhs: Candidate, rhs: Candidate) bool {
    if (!std.mem.eql(u8, lhs.source_intent, rhs.source_intent)) return false;
    if (!std.mem.eql(u8, lhs.action_surface, rhs.action_surface)) return false;
    if (!std.mem.eql(u8, lhs.scope, rhs.scope)) return false;
    if (lhs.bound_artifacts.len != rhs.bound_artifacts.len) return false;
    for (lhs.bound_artifacts, rhs.bound_artifacts) |lhs_artifact, rhs_artifact| {
        if (!std.mem.eql(u8, lhs_artifact, rhs_artifact)) return false;
    }
    return true;
}

fn strictlyDominatesCandidate(lhs: Candidate, rhs: Candidate) bool {
    if (!lhs.initial_support_estimate.viable or !rhs.initial_support_estimate.viable) return false;
    if (lhs.required_obligations.len > rhs.required_obligations.len) return false;
    if (lhs.initial_support_estimate.estimated_cost >= rhs.initial_support_estimate.estimated_cost) return false;
    return lhs.exploration_rank < rhs.exploration_rank or lhs.required_obligations.len < rhs.required_obligations.len;
}

fn buildSchedulingOrder(allocator: std.mem.Allocator, candidates: []const Candidate, admissible: []const bool) ![]usize {
    var order = std.ArrayList(usize).init(allocator);
    errdefer order.deinit();
    for (candidates, 0..) |_, idx| {
        if (admissible[idx]) try order.append(idx);
    }
    std.sort.heap(usize, order.items, candidates, lessThanScheduledCandidate);
    return order.toOwnedSlice();
}

fn lessThanScheduledCandidate(candidates: []const Candidate, lhs_idx: usize, rhs_idx: usize) bool {
    const lhs = candidates[lhs_idx];
    const rhs = candidates[rhs_idx];
    if (lhs.initial_support_estimate.estimated_cost != rhs.initial_support_estimate.estimated_cost) {
        return lhs.initial_support_estimate.estimated_cost < rhs.initial_support_estimate.estimated_cost;
    }
    const lhs_risk = supportRiskRank(lhs.initial_support_estimate.risk_level);
    const rhs_risk = supportRiskRank(rhs.initial_support_estimate.risk_level);
    if (lhs_risk != rhs_risk) return lhs_risk < rhs_risk;
    if (lhs.required_obligations.len != rhs.required_obligations.len) return lhs.required_obligations.len < rhs.required_obligations.len;
    if (lhs.score != rhs.score) return lhs.score > rhs.score;
    return lhs.exploration_rank < rhs.exploration_rank;
}

fn queueContainsExpandedCandidate(candidates: []const Candidate, queue: []const usize) bool {
    for (queue) |candidate_idx| {
        if (candidateScopeExpanded(candidates[candidate_idx])) return true;
    }
    return false;
}

fn blockCandidateProofAdmission(allocator: std.mem.Allocator, intel: *const code_intel.Result, candidate: *Candidate) !bool {
    const reason = proofAdmissionBlockedReason(intel) orelse return false;
    const status_reason = try allocator.dupe(u8, reason);
    errdefer allocator.free(status_reason);
    if (candidate.verification.proof_reason) |existing| allocator.free(existing);
    candidate.verification.proof_reason = try allocator.dupe(u8, reason);
    try setCandidateStatusOwned(allocator, candidate, .novel_but_unverified, status_reason);
    return true;
}

fn proofAdmissionBlockedReason(intel: *const code_intel.Result) ?[]const u8 {
    if (intel.status == .supported and intel.stop_reason == .none) return null;
    if (intel.partial_support.blocking.ambiguous) {
        return "proof admission blocked: ambiguous rationale may guide exploration but cannot enter supported patch selection";
    }
    if (intel.partial_support.blocking.contradicted) {
        return "proof admission blocked: contradicted rationale may guide exploration but cannot enter supported patch selection";
    }
    if (intel.partial_support.blocking.insufficient or intel.status != .supported or intel.stop_reason != .none) {
        return "proof admission blocked: partial rationale may narrow exploration but cannot authorize supported patch selection";
    }
    return "proof admission blocked: rationale did not satisfy bounded proof admission";
}

fn queueContainsLocalGuardFocusedCandidate(candidates: []const Candidate, queue: []const usize) bool {
    for (queue) |candidate_idx| {
        if (candidateLocalGuardFocused(candidates[candidate_idx])) return true;
    }
    return false;
}

fn firstExpandedCandidateIndex(candidates: []const Candidate) ?usize {
    for (candidates, 0..) |candidate, idx| {
        if (candidateScopeExpanded(candidate)) return idx;
    }
    return null;
}

fn firstLocalGuardFocusedCandidateIndex(candidates: []const Candidate) ?usize {
    for (candidates, 0..) |candidate, idx| {
        if (candidateLocalGuardFocused(candidate)) return idx;
    }
    return null;
}

fn lastNonExpandedQueueIndex(candidates: []const Candidate, queue: []const usize) ?usize {
    var idx = queue.len;
    while (idx > 0) {
        idx -= 1;
        if (!candidateScopeExpanded(candidates[queue[idx]])) return idx;
    }
    return null;
}

fn lastReplaceableQueueIndexForLocalGuard(candidates: []const Candidate, queue: []const usize) ?usize {
    var idx = queue.len;
    while (idx > 0) {
        idx -= 1;
        const candidate = candidates[queue[idx]];
        if (candidateScopeExpanded(candidate)) continue;
        if (candidateLocalGuardFocused(candidate)) continue;
        return idx;
    }
    return null;
}

fn candidateScopeExpanded(candidate: Candidate) bool {
    return std.mem.eql(u8, candidate.scope, "expanded_neighbor_surface");
}

fn candidateLocalGuardFocused(candidate: Candidate) bool {
    return std.mem.eql(u8, candidate.strategy, "local_guard") and !candidateScopeExpanded(candidate);
}

fn findMatchingCluster(
    candidates: []const Candidate,
    cluster_indexes: []const usize,
    clusters: []const CandidateCluster,
    candidate_idx: usize,
) ?usize {
    _ = clusters;
    for (candidates[0..candidate_idx], 0..) |existing, idx| {
        if (sameCluster(existing, candidates[candidate_idx])) return cluster_indexes[idx];
    }
    return null;
}

fn sameCluster(lhs: Candidate, rhs: Candidate) bool {
    if (!std.mem.eql(u8, lhs.strategy, rhs.strategy)) return false;
    if (lhs.files.len != rhs.files.len) return false;
    for (lhs.files) |lhs_file| {
        var found = false;
        for (rhs.files) |rhs_file| {
            if (std.mem.eql(u8, lhs_file, rhs_file)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

fn buildClusterLabel(allocator: std.mem.Allocator, candidate: *const Candidate) ![]u8 {
    if (candidate.files.len == 0) {
        return std.fmt.allocPrint(allocator, "{s} exploratory cluster", .{candidate.strategy});
    }
    if (candidate.files.len == 1) {
        return std.fmt.allocPrint(allocator, "{s} on {s}", .{ candidate.strategy, candidate.files[0] });
    }
    return std.fmt.allocPrint(allocator, "{s} across {d} files rooted at {s}", .{ candidate.strategy, candidate.files.len, candidate.files[0] });
}

fn appendClusterMemberId(allocator: std.mem.Allocator, cluster: *CandidateCluster, candidate_id: []const u8) !void {
    const next = try allocator.alloc([]u8, cluster.member_ids.len + 1);
    errdefer allocator.free(next);
    for (cluster.member_ids, 0..) |member_id, idx| next[idx] = member_id;
    next[cluster.member_ids.len] = try allocator.dupe(u8, candidate_id);
    allocator.free(cluster.member_ids);
    cluster.member_ids = next;
}

fn containsExpandedSeed(items: []const PlanSeed) bool {
    for (items) |item| {
        if (item.scope_mode == .expanded) return true;
    }
    return false;
}

fn findFirstExpandedSeed(items: []const PlanSeed) ?PlanSeed {
    for (items) |item| {
        if (item.scope_mode == .expanded) return item;
    }
    return null;
}

fn strategySupportsExpandedScope(strategy: Strategy) bool {
    return switch (strategy) {
        .local_guard => false,
        .seam_adapter, .contradiction_split, .abstraction_alignment => true,
    };
}

fn collectExpandedSurfaceIndexes(
    surfaces: []const SurfaceSeed,
    focus_idx: usize,
    max_extra: usize,
    out: *[HARD_MAX_FILES]u8,
) usize {
    if (max_extra == 0) return 0;
    var count: usize = 0;
    for (surfaces, 0..) |surface, idx| {
        if (idx == focus_idx) continue;
        if (std.mem.eql(u8, surface.rel_path, surfaces[focus_idx].rel_path)) continue;
        var duplicate = false;
        for (out[0..count]) |existing| {
            if (std.mem.eql(u8, surfaces[existing].rel_path, surface.rel_path)) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) continue;
        out[count] = @intCast(idx);
        count += 1;
        if (count >= max_extra) break;
    }
    return count;
}

const Window = struct {
    lines: [][]u8,
    start_line: u32,
    end_line: u32,

    fn deinit(self: *const Window, allocator: std.mem.Allocator) void {
        for (self.lines) |line| allocator.free(line);
        allocator.free(self.lines);
    }
};

fn extractWindow(allocator: std.mem.Allocator, body: []const u8, anchor_line: u32, max_lines: u32) !Window {
    var lines = std.ArrayList([]const u8).init(allocator);
    defer lines.deinit();
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |line| try lines.append(std.mem.trimRight(u8, line, "\r"));

    if (lines.items.len == 0) {
        return .{
            .lines = try allocator.alloc([]u8, 0),
            .start_line = 1,
            .end_line = 1,
        };
    }

    const anchor = if (anchor_line == 0) 1 else @min(anchor_line, @as(u32, @intCast(lines.items.len)));
    const half = max_lines / 2;
    const start_line = if (anchor > half) anchor - half else 1;
    const unclamped_end = start_line + max_lines - 1;
    const end_line = @min(unclamped_end, @as(u32, @intCast(lines.items.len)));

    var owned = std.ArrayList([]u8).init(allocator);
    errdefer {
        for (owned.items) |line| allocator.free(line);
        owned.deinit();
    }
    var line_no = start_line;
    while (line_no <= end_line) : (line_no += 1) {
        try owned.append(try allocator.dupe(u8, lines.items[line_no - 1]));
    }

    return .{
        .lines = try owned.toOwnedSlice(),
        .start_line = start_line,
        .end_line = end_line,
    };
}

fn draftRationale(allocator: std.mem.Allocator, surface: SurfaceSeed, abstraction_refs: []const abstractions.SupportReference) ![]u8 {
    if (firstUsableAbstractionRef(abstraction_refs)) |reference| {
        return std.fmt.allocPrint(
            allocator,
            "Not validated; derived from {s} at {s}:{d} and abstraction {s} ({s}/{s}, {s}, {s}/{s}, lookup {d}).",
            .{
                supportKindName(surface.kind),
                surface.rel_path,
                surface.line,
                reference.concept_id,
                abstractions.tierName(reference.tier),
                abstractions.categoryName(reference.category),
                abstractions.selectionModeName(reference.selection_mode),
                abstractions.reuseResolutionName(reference.resolution),
                reference.owner_id,
                reference.lookup_score,
            },
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "Not validated; derived from {s} at {s}:{d}.",
        .{ supportKindName(surface.kind), surface.rel_path, surface.line },
    );
}

fn firstUsableAbstractionRef(refs: []const abstractions.SupportReference) ?abstractions.SupportReference {
    for (refs) |reference| {
        if (reference.usable) return reference;
    }
    return null;
}

fn draftCommentLine(allocator: std.mem.Allocator, rel_path: []const u8, text: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, text, " \r\n\t");
    const style = commentStyleForPath(rel_path);
    return switch (style) {
        .slash => std.fmt.allocPrint(allocator, "// {s}", .{trimmed}),
        .hash => std.fmt.allocPrint(allocator, "# {s}", .{trimmed}),
        .html => std.fmt.allocPrint(allocator, "<!-- {s} -->", .{trimmed}),
    };
}

const CommentStyle = enum { slash, hash, html };

fn commentStyleForPath(rel_path: []const u8) CommentStyle {
    if (std.mem.endsWith(u8, rel_path, ".html")) return .html;
    if (std.mem.endsWith(u8, rel_path, ".py") or
        std.mem.endsWith(u8, rel_path, ".sh") or
        std.mem.endsWith(u8, rel_path, ".yml") or
        std.mem.endsWith(u8, rel_path, ".yaml") or
        std.mem.endsWith(u8, rel_path, ".toml"))
    {
        return .hash;
    }
    return .slash;
}

fn collectSupportPaths(out: *std.ArrayList([]const u8), intel: *const code_intel.Result, max_items: usize) !void {
    if (intel.primary) |subject| try appendUniquePath(out, subject.rel_path, max_items);
    if (intel.secondary) |subject| try appendUniquePath(out, subject.rel_path, max_items);
    for (intel.evidence) |item| try appendUniquePath(out, item.rel_path, max_items);
    for (intel.refactor_path) |item| try appendUniquePath(out, item.rel_path, max_items);
    for (intel.overlap) |item| try appendUniquePath(out, item.rel_path, max_items);
}

fn appendUniquePath(out: *std.ArrayList([]const u8), rel_path: []const u8, max_items: usize) !void {
    if (out.items.len >= max_items) return;
    for (out.items) |existing| {
        if (std.mem.eql(u8, existing, rel_path)) return;
    }
    try out.append(rel_path);
}

fn buildAbstractionTraces(allocator: std.mem.Allocator, refs: []const abstractions.SupportReference) ![]SupportTrace {
    var out = try allocator.alloc(SupportTrace, refs.len);
    var built: usize = 0;
    errdefer {
        for (out[0..built]) |*trace| trace.deinit(allocator);
        allocator.free(out);
    }
    for (refs, 0..) |reference, idx| {
        const reason = try std.fmt.allocPrint(
            allocator,
            "{s}/{s} {s}; {s}; owner {s}/{s}; usable {s}; direct {d}, lineage {d}; source {s}",
            .{
                abstractions.tierName(reference.tier),
                abstractions.categoryName(reference.category),
                abstractions.selectionModeName(reference.selection_mode),
                abstractions.reuseResolutionName(reference.resolution),
                @tagName(reference.owner_kind),
                reference.owner_id,
                if (reference.usable) "true" else "false",
                reference.direct_support_count,
                reference.lineage_support_count,
                reference.source_spec,
            },
        );
        defer allocator.free(reason);
        out[idx] = try makeSupportTrace(
            allocator,
            if (reference.staged) .abstraction_staged else .abstraction_live,
            reference.concept_id,
            null,
            0,
            reference.lookup_score,
            reason,
        );
        built += 1;
    }
    return out;
}

fn appendStrategyHypothesis(
    allocator: std.mem.Allocator,
    traces: *std.ArrayList(ScoreTrace),
    branch_ids: *std.ArrayList(u32),
    scores: *std.ArrayList(u32),
    strategy: Strategy,
    branch_id: u32,
    evidence_count: usize,
    enabled: bool,
) !void {
    if (!enabled) return;
    const score = strategyHypothesisScore(strategy, evidence_count);
    try traces.append(.{
        .label = try allocator.dupe(u8, strategyName(strategy)),
        .score = score,
        .evidence_count = @intCast(evidence_count),
    });
    try branch_ids.append(branch_id);
    try scores.append(score);
}

fn appendStrategyOption(
    allocator: std.mem.Allocator,
    traces: *std.ArrayList(ScoreTrace),
    options: *std.ArrayList(StrategyOption),
    strategy: Strategy,
    evidence_count: usize,
    enabled: bool,
) !void {
    if (!enabled) return;
    const score = strategyHypothesisScore(strategy, evidence_count);
    try traces.append(.{
        .label = try allocator.dupe(u8, strategyName(strategy)),
        .score = score,
        .evidence_count = @intCast(evidence_count),
    });
    try options.append(.{
        .strategy = strategy,
        .score = score,
    });
}

fn strategyHypothesisScore(strategy: Strategy, evidence_count: usize) u32 {
    return switch (strategy) {
        .local_guard => 165 + @as(u32, @intCast(@min(evidence_count, 4))) * 12,
        .seam_adapter => 185 + @as(u32, @intCast(@min(evidence_count, 4))) * 15,
        .contradiction_split => 190 + @as(u32, @intCast(@min(evidence_count, 4))) * 14,
        .abstraction_alignment => 175 + @as(u32, @intCast(@min(evidence_count, 4))) * 18,
    };
}

fn cloneScoreTraces(allocator: std.mem.Allocator, src: []const ScoreTrace) ![]ScoreTrace {
    var out = try allocator.alloc(ScoreTrace, src.len);
    var built: usize = 0;
    errdefer {
        for (out[0..built]) |*trace| trace.deinit(allocator);
        allocator.free(out);
    }
    for (src, 0..) |trace, idx| {
        out[idx] = .{
            .label = try allocator.dupe(u8, trace.label),
            .score = trace.score,
            .evidence_count = trace.evidence_count,
        };
        built += 1;
    }
    return out;
}

fn buildInvariantEvidence(allocator: std.mem.Allocator, intel: *const code_intel.Result, max_items: usize) ![]SupportTrace {
    var out = std.ArrayList(SupportTrace).init(allocator);
    errdefer {
        for (out.items) |*item| item.deinit(allocator);
        out.deinit();
    }

    for (intel.refactor_path, 0..) |item, idx| {
        if (idx >= max_items) break;
        try out.append(try makeSupportTrace(
            allocator,
            .code_intel_refactor_path,
            item.reason,
            item.rel_path,
            item.line,
            255 - @as(u32, @intCast(idx)) * 5,
            item.subsystem,
        ));
    }
    if (out.items.len < max_items) {
        const remaining = max_items - out.items.len;
        for (intel.evidence, 0..) |item, idx| {
            if (idx >= remaining) break;
            try out.append(try makeSupportTrace(
                allocator,
                .code_intel_evidence,
                item.reason,
                item.rel_path,
                item.line,
                230 - @as(u32, @intCast(idx)) * 4,
                item.subsystem,
            ));
        }
    }
    return out.toOwnedSlice();
}

fn buildContradictionEvidence(allocator: std.mem.Allocator, intel: *const code_intel.Result, max_items: usize) ![]SupportTrace {
    var out = std.ArrayList(SupportTrace).init(allocator);
    errdefer {
        for (out.items) |*item| item.deinit(allocator);
        out.deinit();
    }

    for (intel.contradiction_traces, 0..) |item, idx| {
        if (idx >= max_items) break;
        try out.append(try makeSupportTrace(
            allocator,
            .code_intel_contradiction,
            item.reason,
            item.rel_path,
            item.line,
            235 - @as(u32, @intCast(idx)) * 4,
            item.category,
        ));
    }
    return out.toOwnedSlice();
}

fn collectSurfaceSeeds(out: *std.ArrayList(SurfaceSeed), intel: *const code_intel.Result, max_items: usize) !void {
    const use_partial_planning_surfaces = intel.status != .supported or intel.stop_reason != .none;
    if (intel.primary) |subject| {
        try upsertSurface(out, .{
            .kind = .code_intel_primary,
            .rel_path = subject.rel_path,
            .line = subject.line,
            .label = subject.name,
            .score = 205,
        }, max_items);
    }
    if (intel.secondary) |subject| {
        try upsertSurface(out, .{
            .kind = .code_intel_secondary,
            .rel_path = subject.rel_path,
            .line = subject.line,
            .label = subject.name,
            .score = 195,
        }, max_items);
    }
    for (intel.refactor_path) |item| {
        if (surfaceSuppressedByRouting(intel, item.rel_path, item.line)) continue;
        try upsertSurface(out, .{
            .kind = .code_intel_refactor_path,
            .rel_path = item.rel_path,
            .line = item.line,
            .label = item.reason,
            .score = 255,
        }, max_items);
    }
    for (intel.overlap) |item| {
        if (surfaceSuppressedByRouting(intel, item.rel_path, item.line)) continue;
        try upsertSurface(out, .{
            .kind = .code_intel_overlap,
            .rel_path = item.rel_path,
            .line = item.line,
            .label = item.reason,
            .score = 245,
        }, max_items);
    }
    for (intel.grounding_traces) |trace| {
        if (!trace.usable or trace.ambiguous or trace.target_rel_path == null) continue;
        if (surfaceSuppressedByRouting(intel, trace.target_rel_path.?, trace.target_line)) continue;
        try upsertSurface(out, .{
            .kind = .grounding_schema_anchor,
            .rel_path = trace.target_rel_path.?,
            .line = if (trace.target_line > 0) trace.target_line else 1,
            .label = trace.target_label orelse trace.concept,
            .score = 260,
        }, max_items);
    }
    for (intel.evidence) |item| {
        if (surfaceSuppressedByRouting(intel, item.rel_path, item.line)) continue;
        try upsertSurface(out, .{
            .kind = .code_intel_evidence,
            .rel_path = item.rel_path,
            .line = item.line,
            .label = item.reason,
            .score = 230,
        }, max_items);
    }
    for (intel.contradiction_traces) |item| {
        try upsertSurface(out, .{
            .kind = .code_intel_contradiction,
            .rel_path = item.rel_path,
            .line = item.line,
            .label = item.reason,
            .score = 235,
        }, max_items);
    }
    if (!use_partial_planning_surfaces) return;
    for (intel.unresolved.partial_findings) |item| {
        const rel_path = item.rel_path orelse continue;
        if (surfaceSuppressedByRouting(intel, rel_path, item.line)) continue;
        try upsertSurface(out, .{
            .kind = .code_intel_partial_anchor,
            .rel_path = rel_path,
            .line = if (item.line > 0) item.line else 1,
            .label = item.label,
            .score = partialAnchorScore(item),
        }, max_items);
    }
}

fn partialAnchorScore(item: code_intel.PartialFinding) u32 {
    var score: u32 = switch (item.kind) {
        .fragment => 200,
        .scoped_claim => 218,
        .locally_verified => 238,
    };
    if (std.mem.indexOf(u8, item.provenance, "symbolic_ingest") != null) score +%= 8;
    if (std.mem.indexOf(u8, item.provenance, "grounding:") != null) score +%= 14;
    return score;
}

fn surfaceSuppressedByRouting(intel: *const code_intel.Result, rel_path: []const u8, line: u32) bool {
    for (intel.routing_suppressed) |item| {
        const suppressed_path = item.rel_path orelse continue;
        if (!std.mem.eql(u8, suppressed_path, rel_path)) continue;
        if (item.line != 0 and line != 0 and item.line != line) continue;
        return true;
    }
    return false;
}

fn upsertSurface(out: *std.ArrayList(SurfaceSeed), surface: SurfaceSeed, max_items: usize) !void {
    for (out.items) |*existing| {
        if (!std.mem.eql(u8, existing.rel_path, surface.rel_path)) continue;
        if (surface.score > existing.score) existing.* = surface;
        return;
    }
    if (out.items.len >= max_items) return;
    try out.append(surface);
}

fn makeSurfaceTrace(allocator: std.mem.Allocator, surface: SurfaceSeed) !SupportTrace {
    return makeSupportTrace(
        allocator,
        surface.kind,
        surface.label,
        surface.rel_path,
        surface.line,
        surface.score,
        supportKindName(surface.kind),
    );
}

fn makeSupportTrace(
    allocator: std.mem.Allocator,
    kind: SupportKind,
    label: []const u8,
    rel_path: ?[]const u8,
    line: u32,
    score: u32,
    reason: ?[]const u8,
) !SupportTrace {
    return .{
        .kind = kind,
        .label = try allocator.dupe(u8, label),
        .rel_path = if (rel_path) |path| try allocator.dupe(u8, path) else null,
        .line = line,
        .score = score,
        .reason = if (reason) |text| try allocator.dupe(u8, text) else null,
    };
}

fn stageResult(allocator: std.mem.Allocator, paths: *const shards.Paths, result: *Result) !void {
    const render_started = sys.getMilliTick();
    const json = try renderJson(allocator, result);
    result.profile.json_render_ms += sys.getMilliTick() - render_started;
    defer allocator.free(json);
    try sys.makePath(allocator, paths.patch_candidates_root_abs_path);
    try writeOwnedFile(allocator, paths.patch_candidates_staged_abs_path, json);
    if (result.staged_path) |path| allocator.free(path);
    result.staged_path = try allocator.dupe(u8, paths.patch_candidates_staged_abs_path);
}

fn parseCommand(allocator: std.mem.Allocator, script: []const u8) !ParsedCommand {
    const trimmed = std.mem.trim(u8, script, " \r\n\t");
    if (!std.mem.startsWith(u8, trimmed, COMMAND_NAME)) return error.InvalidPatchCandidateCommand;

    var caps = Caps{};
    var positionals = std.ArrayList([]const u8).init(allocator);
    defer positionals.deinit();

    var it = std.mem.tokenizeAny(u8, trimmed[COMMAND_NAME.len..], " \r\n\t");
    while (it.next()) |token| {
        if (std.mem.startsWith(u8, token, "--max-candidates=")) {
            caps.max_candidates = try std.fmt.parseUnsigned(usize, token["--max-candidates=".len..], 10);
            continue;
        }
        if (std.mem.startsWith(u8, token, "--max-files=")) {
            caps.max_files = try std.fmt.parseUnsigned(usize, token["--max-files=".len..], 10);
            continue;
        }
        if (std.mem.startsWith(u8, token, "--max-hunks=")) {
            caps.max_hunks_per_candidate = try std.fmt.parseUnsigned(usize, token["--max-hunks=".len..], 10);
            continue;
        }
        if (std.mem.startsWith(u8, token, "--max-lines=")) {
            caps.max_lines_per_hunk = try std.fmt.parseUnsigned(u32, token["--max-lines=".len..], 10);
            continue;
        }
        try positionals.append(token);
    }

    if (positionals.items.len < 2) return error.InvalidPatchCandidateCommand;
    const query_kind = parseQueryKind(positionals.items[0]) orelse return error.InvalidPatchCandidateCommand;
    const target = try allocator.dupe(u8, positionals.items[1]);
    errdefer allocator.free(target);

    var other_target: ?[]u8 = null;
    var request_start: usize = 2;
    if (query_kind == .contradicts) {
        if (positionals.items.len < 3) return error.InvalidPatchCandidateCommand;
        other_target = try allocator.dupe(u8, positionals.items[2]);
        request_start = 3;
    }
    errdefer if (other_target) |other| allocator.free(other);

    const request_label = if (positionals.items.len > request_start)
        try boundedLabel(allocator, try joinTokens(allocator, positionals.items[request_start..]))
    else
        try boundedLabel(allocator, positionals.items[1]);
    errdefer allocator.free(request_label);

    return .{
        .query_kind = query_kind,
        .target = target,
        .other_target = other_target,
        .request_label = request_label,
        .caps = caps.normalized(),
    };
}

fn joinTokens(allocator: std.mem.Allocator, tokens: []const []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    for (tokens, 0..) |token, idx| {
        if (idx != 0) try out.append(' ');
        try out.appendSlice(token);
    }
    return out.toOwnedSlice();
}

fn boundedLabel(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, text, " \r\n\t");
    const clipped = if (trimmed.len <= MAX_REQUEST_LABEL_BYTES) trimmed else trimmed[0..MAX_REQUEST_LABEL_BYTES];
    return allocator.dupe(u8, if (clipped.len == 0) "patch-candidate-request" else clipped);
}

fn queryKindName(kind: code_intel.QueryKind) []const u8 {
    return switch (kind) {
        .impact => "impact",
        .breaks_if => "breaks-if",
        .contradicts => "contradicts",
    };
}

fn parseQueryKind(text: []const u8) ?code_intel.QueryKind {
    if (std.mem.eql(u8, text, "impact")) return .impact;
    if (std.mem.eql(u8, text, "breaks-if")) return .breaks_if;
    if (std.mem.eql(u8, text, "contradicts")) return .contradicts;
    return null;
}

fn strategyFromBranchId(branch_id: u32) Strategy {
    return switch (branch_id) {
        1 => .local_guard,
        2 => .seam_adapter,
        3 => .contradiction_split,
        4 => .abstraction_alignment,
        else => .local_guard,
    };
}

fn strategyName(strategy: Strategy) []const u8 {
    return switch (strategy) {
        .local_guard => "local_guard",
        .seam_adapter => "seam_adapter",
        .contradiction_split => "contradiction_split",
        .abstraction_alignment => "abstraction_alignment",
    };
}

fn scopeModeName(scope_mode: ScopeMode) []const u8 {
    return switch (scope_mode) {
        .focused => "focused_single_surface",
        .expanded => "expanded_neighbor_surface",
    };
}

fn supportKindName(kind: SupportKind) []const u8 {
    return switch (kind) {
        .strategy => "strategy",
        .rewrite_operator => "rewrite_operator",
        .code_intel_target => "code_intel_target",
        .code_intel_hypothesis => "code_intel_hypothesis",
        .code_intel_primary => "code_intel_primary",
        .code_intel_secondary => "code_intel_secondary",
        .code_intel_evidence => "code_intel_evidence",
        .code_intel_refactor_path => "code_intel_refactor_path",
        .code_intel_overlap => "code_intel_overlap",
        .code_intel_contradiction => "code_intel_contradiction",
        .code_intel_partial_anchor => "code_intel_partial_anchor",
        .grounding_schema_anchor => "grounding_schema_anchor",
        .abstraction_live => "abstraction_live",
        .abstraction_staged => "abstraction_staged",
        .execution_evidence => "execution_evidence",
        .execution_contradiction => "execution_contradiction",
        .refinement_hypothesis => "refinement_hypothesis",
    };
}

pub fn repairStrategyName(strategy: RepairStrategy) []const u8 {
    return switch (strategy) {
        .narrow_to_primary_surface => "narrow_to_primary_surface",
        .import_repair => "import_repair",
        .dispatch_normalization_repair => "dispatch_normalization_repair",
        .signature_alignment_repair => "signature_alignment_repair",
        .call_surface_adapter_repair => "call_surface_adapter_repair",
        .invariant_preserving_simplification => "invariant_preserving_simplification",
    };
}

pub fn repairPlanOutcomeName(outcome: RepairPlanOutcome) []const u8 {
    return switch (outcome) {
        .pending => "pending",
        .improved => "improved",
        .failed => "failed",
        .insufficient_evidence => "insufficient_evidence",
    };
}

pub fn rewriteOperatorName(operator_kind: RewriteOperator) []const u8 {
    return switch (operator_kind) {
        .import_insert => "import_insert",
        .import_remove => "import_remove",
        .import_update => "import_update",
        .call_site_adaptation => "call_site_adaptation",
        .dispatch_indirection => "dispatch_indirection",
        .signature_adapter_generation => "signature_adapter_generation",
        .parameter_threading => "parameter_threading",
        .guard_insertion => "guard_insertion",
        .structural_rename_update => "structural_rename_update",
    };
}

pub fn selectedValidationState(result: *const Result) ?ValidationState {
    const selected_id = result.selected_candidate_id orelse return null;
    for (result.candidates) |candidate| {
        if (std.mem.eql(u8, candidate.id, selected_id)) return candidate.validation_state;
    }
    return null;
}

fn validationStateName(state: ValidationState) []const u8 {
    return switch (state) {
        .draft_unvalidated => "draft_unvalidated",
        .build_failed => "build_failed",
        .test_failed => "test_failed",
        .build_test_verified => "build_test_verified",
        .runtime_verified => "runtime_verified",
        .runtime_failed => "runtime_failed",
        .runtime_unresolved => "runtime_unresolved",
        .proof_rejected => "proof_rejected",
    };
}

fn candidateStatusName(status: CandidateStatus) []const u8 {
    return switch (status) {
        .rejected => "rejected",
        .unresolved => "unresolved",
        .supported => "supported",
        .novel_but_unverified => "novel_but_unverified",
    };
}

fn speculativeCandidateStatusName(status: SpeculativeCandidateStatus) []const u8 {
    return switch (status) {
        .pending => "pending",
        .pruned => "pruned",
        .verified => "verified",
        .failed => "failed",
    };
}

fn supportRiskLevelName(level: SupportRiskLevel) []const u8 {
    return switch (level) {
        .low => "low",
        .medium => "medium",
        .high => "high",
    };
}

fn supportRiskRank(level: SupportRiskLevel) u8 {
    return switch (level) {
        .low => 0,
        .medium => 1,
        .high => 2,
    };
}

fn refactorPlanStatusName(status: RefactorPlanStatus) []const u8 {
    return switch (status) {
        .unresolved => "unresolved",
        .verified_supported => "verified_supported",
    };
}

fn verificationStepStateName(state: VerificationStepState) []const u8 {
    return switch (state) {
        .unavailable => "unavailable",
        .passed => "passed",
        .failed => "failed",
    };
}

fn lessThanSurfaceSeed(_: void, lhs: SurfaceSeed, rhs: SurfaceSeed) bool {
    if (lhs.score != rhs.score) return lhs.score > rhs.score;
    if (lhs.line != rhs.line) return lhs.line < rhs.line;
    return std.mem.lessThan(u8, lhs.rel_path, rhs.rel_path);
}

fn containsString(items: []const []const u8, needle: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

fn clearCandidateRejectionReason(allocator: std.mem.Allocator, candidate: *Candidate) !void {
    if (candidate.rejection_reason) |reason| allocator.free(reason);
    candidate.rejection_reason = null;
}

fn clearCandidateStatusReason(allocator: std.mem.Allocator, candidate: *Candidate) void {
    if (candidate.status_reason) |reason| allocator.free(reason);
    candidate.status_reason = null;
}

fn setCandidateStatus(allocator: std.mem.Allocator, candidate: *Candidate, status: CandidateStatus, reason: []const u8) !void {
    try clearCandidateRejectionReason(allocator, candidate);
    clearCandidateStatusReason(allocator, candidate);
    candidate.status = status;
    candidate.scheduler_status = schedulerStatusForCandidateStatus(status, candidate.scheduler_status);
    candidate.status_reason = try allocator.dupe(u8, reason);
    if (status == .rejected) {
        candidate.rejection_reason = try allocator.dupe(u8, reason);
    }
}

fn setCandidateStatusOwned(allocator: std.mem.Allocator, candidate: *Candidate, status: CandidateStatus, reason: []u8) !void {
    try clearCandidateRejectionReason(allocator, candidate);
    clearCandidateStatusReason(allocator, candidate);
    candidate.status = status;
    candidate.scheduler_status = schedulerStatusForCandidateStatus(status, candidate.scheduler_status);
    candidate.status_reason = reason;
    if (status == .rejected) {
        candidate.rejection_reason = try allocator.dupe(u8, reason);
    }
}

fn schedulerStatusForCandidateStatus(status: CandidateStatus, previous: SpeculativeCandidateStatus) SpeculativeCandidateStatus {
    return switch (status) {
        .supported => .verified,
        .rejected => .failed,
        .unresolved => if (previous == .pruned) .pruned else .failed,
        .novel_but_unverified => if (previous == .pruned) .pruned else .pending,
    };
}

fn setCandidateRejectionReason(allocator: std.mem.Allocator, candidate: *Candidate, reason: []const u8) !void {
    try clearCandidateRejectionReason(allocator, candidate);
    candidate.rejection_reason = try allocator.dupe(u8, reason);
}

fn setCandidateRejectionReasonOwned(allocator: std.mem.Allocator, candidate: *Candidate, reason: []u8) !void {
    try clearCandidateRejectionReason(allocator, candidate);
    candidate.rejection_reason = reason;
}

fn summarizeProofTrace(result: *Result) void {
    result.handoff.proof.verified_survivor_count = 0;
    result.handoff.proof.rejected_count = 0;
    result.handoff.proof.unresolved_count = 0;
    result.handoff.proof.supported_count = 0;
    result.handoff.proof.novel_but_unverified_count = 0;
    for (result.candidates) |candidate| {
        switch (candidate.status) {
            .rejected => result.handoff.proof.rejected_count += 1,
            .unresolved => result.handoff.proof.unresolved_count += 1,
            .supported => result.handoff.proof.supported_count += 1,
            .novel_but_unverified => result.handoff.proof.novel_but_unverified_count += 1,
        }
        if (candidate.validation_state == .build_test_verified or candidate.validation_state == .runtime_verified or candidate.validation_state == .proof_rejected) {
            result.handoff.proof.verified_survivor_count += 1;
        }
    }
    result.handoff.exploration.preserved_novel_count = result.handoff.proof.novel_but_unverified_count;
}

fn clampBounded(value: anytype, min_value: @TypeOf(value), max_value: @TypeOf(value)) @TypeOf(value) {
    return @max(min_value, @min(value, max_value));
}

fn readOwnedFile(allocator: std.mem.Allocator, abs_path: []const u8, max_bytes: usize) ![]u8 {
    const handle = try sys.openForRead(allocator, abs_path);
    defer sys.closeFile(handle);
    const size = try sys.getFileSize(handle);
    if (size > max_bytes) return error.SourceFileTooLarge;
    const bytes = try allocator.alloc(u8, size);
    errdefer allocator.free(bytes);
    const read = try sys.readAll(handle, bytes);
    return bytes[0..read];
}

fn writeOwnedFile(allocator: std.mem.Allocator, abs_path: []const u8, bytes: []const u8) !void {
    const temp_path = try std.fmt.allocPrint(allocator, "{s}.ghost_tmp", .{abs_path});
    defer allocator.free(temp_path);
    errdefer std.fs.deleteFileAbsolute(temp_path) catch {};

    const handle = try sys.openForWrite(allocator, temp_path);
    defer sys.closeFile(handle);
    try sys.writeAll(handle, bytes);
    try std.fs.renameAbsolute(temp_path, abs_path);
}

fn fileExists(abs_path: []const u8) bool {
    std.fs.accessAbsolute(abs_path, .{}) catch return false;
    return true;
}

fn deleteTreeIfExists(abs_path: []const u8) !void {
    std.fs.deleteTreeAbsolute(abs_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn deleteFileIfExists(abs_path: []const u8) !void {
    try std.fs.deleteFileAbsolute(abs_path);
}

fn writeScoreTraceArray(writer: anytype, items: []const ScoreTrace) !void {
    try writer.writeAll("[");
    for (items, 0..) |item, idx| {
        if (idx != 0) try writer.writeAll(",");
        try writer.writeAll("{");
        try writeJsonFieldString(writer, "label", item.label, true);
        try writer.print(",\"score\":{d},\"evidenceCount\":{d}", .{ item.score, item.evidence_count });
        try writer.writeAll("}");
    }
    try writer.writeAll("]");
}

fn writeSupportTraceArray(writer: anytype, items: []const SupportTrace) !void {
    try writer.writeAll("[");
    for (items, 0..) |item, idx| {
        if (idx != 0) try writer.writeAll(",");
        try writer.writeAll("{");
        try writeJsonFieldString(writer, "kind", supportKindName(item.kind), true);
        try writeJsonFieldString(writer, "label", item.label, false);
        if (item.rel_path) |rel_path| try writeOptionalStringField(writer, "relPath", rel_path);
        if (item.line != 0) try writer.print(",\"line\":{d}", .{item.line});
        if (item.score != 0) try writer.print(",\"score\":{d}", .{item.score});
        if (item.reason) |reason| try writeOptionalStringField(writer, "reason", reason);
        try writer.writeAll("}");
    }
    try writer.writeAll("]");
}

fn writeCandidateArray(writer: anytype, items: []const Candidate) !void {
    try writer.writeAll("[");
    for (items, 0..) |item, idx| {
        if (idx != 0) try writer.writeAll(",");
        try writer.writeAll("{");
        try writeJsonFieldString(writer, "id", item.id, true);
        try writeJsonFieldString(writer, "sourceIntent", item.source_intent, false);
        try writeJsonFieldString(writer, "actionSurface", item.action_surface, false);
        try writer.writeAll(",\"boundArtifacts\":");
        try writeStringArray(writer, item.bound_artifacts);
        try writer.writeAll(",\"requiredObligations\":");
        try writeStringArray(writer, item.required_obligations);
        try writer.writeAll(",\"initialSupportEstimate\":");
        try writeSupportEstimate(writer, item.initial_support_estimate);
        try writeJsonFieldString(writer, "schedulerStatus", speculativeCandidateStatusName(item.scheduler_status), false);
        try writeJsonFieldString(writer, "outcome", candidateOutcomeName(item), false);
        try writeJsonFieldString(writer, "summary", item.summary, false);
        try writeJsonFieldString(writer, "strategy", item.strategy, false);
        try writeJsonFieldString(writer, "scope", item.scope, false);
        try writeJsonFieldString(writer, "status", candidateStatusName(item.status), false);
        try writeJsonFieldString(writer, "validationState", validationStateName(item.validation_state), false);
        try writer.print(",\"enteredProofMode\":{s},\"explorationRank\":{d}", .{
            if (item.entered_proof_mode) "true" else "false",
            item.exploration_rank,
        });
        if (item.proof_rank) |proof_rank| try writer.print(",\"proofRank\":{d}", .{proof_rank});
        if (item.cluster_id) |cluster_id| try writeOptionalStringField(writer, "clusterId", cluster_id);
        if (item.cluster_label) |cluster_label| try writeOptionalStringField(writer, "clusterLabel", cluster_label);
        try writer.print(",\"correctnessClaimed\":{s},\"score\":{d}", .{
            if (item.correctness_claimed) "true" else "false",
            item.score,
        });
        try writer.writeAll(",\"minimality\":");
        try writeMinimalityEvidence(writer, item.minimality);
        try writer.writeAll(",\"files\":");
        try writeStringArray(writer, item.files);
        try writer.writeAll(",\"rewriteOperators\":");
        try writeRewriteOperatorArray(writer, item.rewrite_operators);
        try writer.writeAll(",\"hunks\":");
        try writeHunkArray(writer, item.hunks);
        try writer.writeAll(",\"trace\":");
        try writeSupportTraceArray(writer, item.trace);
        try writer.writeAll(",\"verification\":");
        try writeVerificationTrace(writer, item.verification);
        if (item.status_reason) |reason| try writeOptionalStringField(writer, "statusReason", reason);
        if (item.rejection_reason) |reason| try writeOptionalStringField(writer, "rejectionReason", reason);
        try writer.writeAll("}");
    }
    try writer.writeAll("]");
}

fn writeSupportEstimate(writer: anytype, estimate: SupportEstimate) !void {
    try writer.writeAll("{\"viable\":");
    try writer.writeAll(if (estimate.viable) "true" else "false");
    try writeJsonFieldString(writer, "riskLevel", supportRiskLevelName(estimate.risk_level), false);
    try writer.print(",\"estimatedCost\":{d},\"blockingFlags\":", .{estimate.estimated_cost});
    try writeStringArray(writer, estimate.blocking_flags);
    try writer.writeAll("}");
}

fn candidateOutcomeName(candidate: Candidate) []const u8 {
    return switch (candidate.scheduler_status) {
        .verified => "verified",
        .pruned => "pruned",
        .failed => switch (candidate.validation_state) {
            .runtime_unresolved => "unresolved",
            else => "failed",
        },
        .pending => "unresolved",
    };
}

fn writeHandoffJson(writer: anytype, handoff: ExploreToVerifyHandoff) !void {
    try writer.writeAll("{");
    try writer.writeAll("\"exploration\":");
    try writeExplorationTrace(writer, handoff.exploration);
    try writer.writeAll(",\"proof\":");
    try writeProofTrace(writer, handoff.proof);
    try writer.writeAll(",\"clusters\":");
    try writeCandidateClusterArray(writer, handoff.clusters);
    try writer.writeAll("}");
}

fn writeExplorationTrace(writer: anytype, trace: ExplorationTrace) !void {
    try writer.writeAll("{");
    try writeJsonFieldString(writer, "mode", mc.reasoningModeName(trace.mode), true);
    try writer.print(
        ",\"candidatePoolLimit\":{d},\"generatedCandidateCount\":{d},\"clusteredCandidateCount\":{d},\"clusterCount\":{d},\"proofQueueLimit\":{d},\"proofQueueCount\":{d},\"preservedNovelCount\":{d}",
        .{
            trace.candidate_pool_limit,
            trace.generated_candidate_count,
            trace.clustered_candidate_count,
            trace.cluster_count,
            trace.proof_queue_limit,
            trace.proof_queue_count,
            trace.preserved_novel_count,
        },
    );
    try writer.writeAll("}");
}

fn writeProofTrace(writer: anytype, trace: ProofTrace) !void {
    try writer.writeAll("{");
    try writeJsonFieldString(writer, "mode", mc.reasoningModeName(trace.mode), true);
    try writer.print(
        ",\"queuedCandidateCount\":{d},\"admissionBlockedCount\":{d},\"verifiedSurvivorCount\":{d},\"rejectedCount\":{d},\"unresolvedCount\":{d},\"supportedCount\":{d},\"novelButUnverifiedCount\":{d}",
        .{
            trace.queued_candidate_count,
            trace.admission_blocked_count,
            trace.verified_survivor_count,
            trace.rejected_count,
            trace.unresolved_count,
            trace.supported_count,
            trace.novel_but_unverified_count,
        },
    );
    if (trace.final_candidate_id) |candidate_id| try writeOptionalStringField(writer, "finalCandidateId", candidate_id);
    try writer.writeAll("}");
}

fn writeCandidateClusterArray(writer: anytype, items: []const CandidateCluster) !void {
    try writer.writeAll("[");
    for (items, 0..) |item, idx| {
        if (idx != 0) try writer.writeAll(",");
        try writer.writeAll("{");
        try writeJsonFieldString(writer, "id", item.id, true);
        try writeJsonFieldString(writer, "label", item.label, false);
        try writer.print(",\"proofQueueCount\":{d},\"preservedNovelCount\":{d},\"memberIds\":", .{
            item.proof_queue_count,
            item.preserved_novel_count,
        });
        try writeStringArray(writer, item.member_ids);
        try writer.writeAll("}");
    }
    try writer.writeAll("]");
}

fn writeMinimalityEvidence(writer: anytype, evidence: MinimalityEvidence) !void {
    try writer.writeAll("{");
    try writer.print(
        "\"fileCount\":{d},\"changeCount\":{d},\"hunkCount\":{d},\"dependencySpread\":{d},\"scopePenalty\":{d},\"totalCost\":{d}",
        .{
            evidence.file_count,
            evidence.change_count,
            evidence.hunk_count,
            evidence.dependency_spread,
            evidence.scope_penalty,
            evidence.total_cost,
        },
    );
    try writer.writeAll("}");
}

fn writeVerificationTrace(writer: anytype, trace: VerificationTrace) !void {
    try writer.writeAll("{");
    try writer.print("\"retryCount\":{d},\"maxRetryCount\":{d},\"proofScore\":{d},\"proofConfidence\":{d}", .{
        trace.retry_count,
        trace.max_retry_count,
        trace.proof_score,
        trace.proof_confidence,
    });
    try writer.writeAll(",\"build\":");
    try writeVerificationStep(writer, trace.build);
    try writer.writeAll(",\"test\":");
    try writeVerificationStep(writer, trace.test_step);
    try writer.writeAll(",\"runtime\":");
    try writeVerificationStep(writer, trace.runtime_step);
    try writer.writeAll(",\"repairPlans\":");
    try writeRepairPlanArray(writer, trace.repair_plans);
    try writer.writeAll(",\"refinements\":");
    try writeRefinementTraceArray(writer, trace.refinements);
    if (trace.proof_reason) |reason| try writeOptionalStringField(writer, "proofReason", reason);
    try writer.writeAll("}");
}

fn writeVerificationStep(writer: anytype, step: VerificationStep) !void {
    try writer.writeAll("{");
    try writeJsonFieldString(writer, "status", verificationStepStateName(step.state), true);
    if (step.adapter_id) |adapter_id| try writeOptionalStringField(writer, "adapterId", adapter_id);
    if (step.evidence_kind) |kind| try writeOptionalStringField(writer, "evidenceKind", verifier_adapter.evidenceKindName(kind));
    if (step.command) |command| try writeOptionalStringField(writer, "command", command);
    if (step.exit_code) |exit_code| try writer.print(",\"exitCode\":{d}", .{exit_code});
    if (step.duration_ms != 0) try writer.print(",\"durationMs\":{d}", .{step.duration_ms});
    if (step.failure_signal) |signal| try writeOptionalStringField(writer, "failureSignal", execution.failureSignalName(signal));
    if (step.summary) |summary| try writeOptionalStringField(writer, "summary", summary);
    if (step.evidence) |evidence| try writeOptionalStringField(writer, "evidence", evidence);
    try writer.writeAll("}");
}

fn writeRefinementTraceArray(writer: anytype, items: []const RefinementTrace) !void {
    try writer.writeAll("[");
    for (items, 0..) |item, idx| {
        if (idx != 0) try writer.writeAll(",");
        try writer.writeAll("{");
        try writer.print("\"attempt\":{d}", .{item.attempt});
        try writeJsonFieldString(writer, "label", item.label, false);
        try writeJsonFieldString(writer, "reason", item.reason, false);
        try writer.print(",\"retainedHunkCount\":{d}", .{item.retained_hunk_count});
        try writer.writeAll("}");
    }
    try writer.writeAll("]");
}

fn writeRepairPlanArray(writer: anytype, items: []const RepairPlan) !void {
    try writer.writeAll("[");
    for (items, 0..) |item, idx| {
        if (idx != 0) try writer.writeAll(",");
        try writer.writeAll("{");
        try writer.print("\"attempt\":{d}", .{item.attempt});
        try writeJsonFieldString(writer, "strategy", repairStrategyName(item.strategy), false);
        try writeJsonFieldString(writer, "triggerPhase", execution.phaseName(item.trigger_phase), false);
        if (item.trigger_failure_signal) |signal| try writeOptionalStringField(writer, "triggerFailureSignal", execution.failureSignalName(signal));
        try writer.print(",\"retryBudget\":{d}", .{item.retry_budget});
        try writeJsonFieldString(writer, "expectedVerificationTarget", execution.phaseName(item.expected_verification_target), false);
        try writeJsonFieldString(writer, "lineageParentId", item.lineage_parent_id, false);
        try writeJsonFieldString(writer, "descendantId", item.descendant_id, false);
        try writeJsonFieldString(writer, "triggerSummary", item.trigger_summary, false);
        try writeJsonFieldString(writer, "evidenceSummary", item.evidence_summary, false);
        try writer.print(",\"retainedHunkCount\":{d}", .{item.retained_hunk_count});
        try writeJsonFieldString(writer, "outcome", repairPlanOutcomeName(item.outcome), false);
        if (item.outcome_summary) |summary| try writeOptionalStringField(writer, "outcomeSummary", summary);
        try writer.writeAll("}");
    }
    try writer.writeAll("]");
}

fn writeHunkArray(writer: anytype, items: []const PatchHunk) !void {
    try writer.writeAll("[");
    for (items, 0..) |item, idx| {
        if (idx != 0) try writer.writeAll(",");
        try writer.writeAll("{");
        try writeJsonFieldString(writer, "relPath", item.rel_path, true);
        try writer.print(",\"anchorLine\":{d},\"startLine\":{d},\"endLine\":{d},\"diff\":", .{
            item.anchor_line,
            item.start_line,
            item.end_line,
        });
        try writeJsonString(writer, item.diff);
        try writer.writeAll("}");
    }
    try writer.writeAll("]");
}

fn writeRewriteOperatorArray(writer: anytype, items: []const RewriteOperator) !void {
    try writer.writeAll("[");
    for (items, 0..) |item, idx| {
        if (idx != 0) try writer.writeAll(",");
        try writeJsonString(writer, rewriteOperatorName(item));
    }
    try writer.writeAll("]");
}

fn writeStringArray(writer: anytype, items: []const []const u8) !void {
    try writer.writeAll("[");
    for (items, 0..) |item, idx| {
        if (idx != 0) try writer.writeAll(",");
        try writeJsonString(writer, item);
    }
    try writer.writeAll("]");
}

fn writeComputeBudgetJson(writer: anytype, budget: compute_budget.Effective, exhaustion: ?compute_budget.Exhaustion) !void {
    try writer.writeAll("{\"requestedTier\":");
    try writeJsonString(writer, compute_budget.tierName(budget.requested_tier));
    try writer.writeAll(",\"effectiveTier\":");
    try writeJsonString(writer, compute_budget.tierName(budget.effective_tier));
    try writer.print(
        ",\"limits\":{{\"maxBranches\":{d},\"maxProofQueueSize\":{d},\"maxRepairs\":{d},\"maxMountedPacksConsidered\":{d},\"maxPacksActivated\":{d},\"maxPackCandidateSurfaces\":{d},\"maxGraphNodes\":{d},\"maxGraphObligations\":{d},\"maxAmbiguitySets\":{d},\"maxRuntimeChecks\":{d},\"maxVerifierRuns\":{d},\"maxVerifierTimeMs\":{d},\"maxExternalVerifierRuns\":{d},\"maxVerifierEvidenceBytes\":{d}",
        .{
            budget.max_branches,
            budget.max_proof_queue_size,
            budget.max_repairs,
            budget.max_mounted_packs_considered,
            budget.max_packs_activated,
            budget.max_pack_candidate_surfaces,
            budget.max_graph_nodes,
            budget.max_graph_obligations,
            budget.max_ambiguity_sets,
            budget.max_runtime_checks,
            budget.max_verifier_runs,
            budget.max_verifier_time_ms,
            budget.max_external_verifier_runs,
            budget.max_verifier_evidence_bytes,
        },
    );
    try writer.print(
        ",\"maxHypothesesGenerated\":{d},\"maxHypothesesSelected\":{d},\"maxHypothesisEvidenceFragments\":{d},\"maxHypothesisObligations\":{d},\"maxHypothesisVerifierNeeds\":{d},\"maxHypothesisVerifierJobs\":{d},\"maxHypothesisVerifierJobsPerArtifact\":{d},\"maxHypothesisVerifierTimeMs\":{d},\"maxHypothesisVerifierEvidenceBytes\":{d},\"maxVerifierCandidatesGenerated\":{d},\"maxVerifierCandidateArtifacts\":{d},\"maxVerifierCandidateCommands\":{d},\"maxVerifierCandidateBytes\":{d},\"maxVerifierCandidateObligations\":{d},\"maxWallTimeMs\":{d},\"maxTempWorkBytes\":{d}}}",
        .{
            budget.max_hypotheses_generated,
            budget.max_hypotheses_selected,
            budget.max_hypothesis_evidence_fragments,
            budget.max_hypothesis_obligations,
            budget.max_hypothesis_verifier_needs,
            budget.max_hypothesis_verifier_jobs,
            budget.max_hypothesis_verifier_jobs_per_artifact,
            budget.max_hypothesis_verifier_time_ms,
            budget.max_hypothesis_verifier_evidence_bytes,
            budget.max_verifier_candidates_generated,
            budget.max_verifier_candidate_artifacts,
            budget.max_verifier_candidate_commands,
            budget.max_verifier_candidate_bytes,
            budget.max_verifier_candidate_obligations,
            budget.max_wall_time_ms,
            budget.max_temp_work_bytes,
        },
    );
    if (exhaustion) |value| {
        try writer.writeAll(",\"exhaustion\":{");
        try writeJsonFieldString(writer, "limit", compute_budget.limitName(value.limit), true);
        try writeJsonFieldString(writer, "stage", compute_budget.stageName(value.stage), false);
        try writer.print(",\"used\":{d},\"limitValue\":{d}", .{ value.used, value.limit_value });
        try writeOptionalStringField(writer, "detail", value.detail);
        try writeOptionalStringField(writer, "skipped", value.skipped);
        try writer.writeAll("}");
    }
    try writer.writeAll("}");
}

fn writeOptionalStringField(writer: anytype, field: []const u8, value: []const u8) !void {
    try writer.writeAll(",");
    try writeJsonString(writer, field);
    try writer.writeAll(":");
    try writeJsonString(writer, value);
}

fn writeJsonFieldString(writer: anytype, field: []const u8, value: []const u8, first: bool) !void {
    if (!first) try writer.writeAll(",");
    try writeJsonString(writer, field);
    try writer.writeAll(":");
    try writeJsonString(writer, value);
}

fn writeJsonString(writer: anytype, text: []const u8) !void {
    try writer.writeByte('"');
    for (text) |byte| switch (byte) {
        '\\' => try writer.writeAll("\\\\"),
        '"' => try writer.writeAll("\\\""),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        else => if (byte < 0x20) {
            try writer.print("\\u{X:0>4}", .{@as(u16, byte)});
        } else {
            try writer.writeByte(byte);
        },
    };
    try writer.writeByte('"');
}

fn deleteTreeIfExistsAbsolute(path: []const u8) !void {
    std.fs.deleteTreeAbsolute(path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn writeOwnedTestFileAbsolute(abs_path: []const u8, body: []const u8) !void {
    if (std.fs.path.dirname(abs_path)) |dir| try std.fs.cwd().makePath(dir);
    var file = try std.fs.createFileAbsolute(abs_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(body);
}

fn createPatchPlanningTestRepo(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const root = try std.fs.path.join(allocator, &.{ "/tmp", name });
    errdefer allocator.free(root);
    try deleteTreeIfExistsAbsolute(root);
    try std.fs.cwd().makePath(root);

    const build_path = try std.fs.path.join(allocator, &.{ root, "build.zig" });
    defer allocator.free(build_path);
    try writeOwnedTestFileAbsolute(build_path,
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    _ = b;
        \\}
        \\
    );

    const main_path = try std.fs.path.join(allocator, &.{ root, "src", "main.zig" });
    defer allocator.free(main_path);
    try writeOwnedTestFileAbsolute(main_path,
        \\pub fn main() void {}
        \\
    );

    const worker_path = try std.fs.path.join(allocator, &.{ root, "src", "runtime", "worker.zig" });
    defer allocator.free(worker_path);
    try writeOwnedTestFileAbsolute(worker_path,
        \\pub fn sync(value: i32) i32 {
        \\    return value + 1;
        \\}
        \\
    );

    const noise_path = try std.fs.path.join(allocator, &.{ root, "src", "runtime", "noise.zig" });
    defer allocator.free(noise_path);
    try writeOwnedTestFileAbsolute(noise_path,
        \\pub fn helper(value: i32) i32 {
        \\    return value;
        \\}
        \\
    );

    return root;
}

fn initTestCodeIntelResult(allocator: std.mem.Allocator, repo_root: []const u8, status: code_intel.Status) !code_intel.Result {
    return .{
        .allocator = allocator,
        .status = status,
        .query_kind = .impact,
        .query_target = try allocator.dupe(u8, "src/runtime/worker.zig:sync"),
        .repo_root = try allocator.dupe(u8, repo_root),
        .shard_root = try allocator.dupe(u8, repo_root),
        .shard_id = try allocator.dupe(u8, "patch-planning-test"),
        .shard_kind = .project,
        .partial_support = .{},
        .unresolved = .{ .allocator = allocator },
        .support_graph = .{ .allocator = allocator },
    };
}

fn initTestPatchResult(allocator: std.mem.Allocator, repo_root: []const u8) !Result {
    return .{
        .allocator = allocator,
        .status = .unresolved,
        .query_kind = .impact,
        .target = try allocator.dupe(u8, "src/runtime/worker.zig:sync"),
        .request_label = try allocator.dupe(u8, "sync patch planning"),
        .repo_root = try allocator.dupe(u8, repo_root),
        .shard_id = try allocator.dupe(u8, "patch-planning-test"),
        .shard_root = try allocator.dupe(u8, repo_root),
        .shard_kind = .project,
        .minimality_model = try allocator.dupe(u8, MINIMALITY_MODEL_NAME),
        .code_intel_result_path = try allocator.dupe(u8, ""),
        .caps = (Caps{}).normalized(),
        .planning_basis = .{ .allocator = allocator },
        .unresolved = .{ .allocator = allocator },
        .support_graph = .{ .allocator = allocator },
    };
}

fn candidateTraceHasKind(candidate: Candidate, kind: SupportKind) bool {
    for (candidate.trace) |item| {
        if (item.kind == kind) return true;
    }
    return false;
}

fn candidateTraceHasPath(candidate: Candidate, rel_path: []const u8) bool {
    for (candidate.trace) |item| {
        if (item.rel_path) |path| {
            if (std.mem.eql(u8, path, rel_path)) return true;
        }
    }
    return false;
}

fn missingObligationPresent(items: []const code_intel.MissingObligation, label: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item.label, label)) return true;
    }
    return false;
}

test "weak partial grounding improves exploratory planning but cannot enter proof queue" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const repo_root = try createPatchPlanningTestRepo(allocator, "ghost-patch-partial-planning-test");
    defer deleteTreeIfExistsAbsolute(repo_root) catch {};

    var intel = try initTestCodeIntelResult(allocator, repo_root, .unresolved);
    intel.stop_reason = .low_confidence;
    intel.primary = .{
        .name = try allocator.dupe(u8, "sync"),
        .rel_path = try allocator.dupe(u8, "src/runtime/worker.zig"),
        .line = 1,
        .kind_name = "function",
        .subsystem = "runtime",
    };
    intel.partial_support = .{
        .lattice = .scoped,
        .blocking = .{ .insufficient = true },
    };
    intel.unresolved.partial_findings = try allocator.alloc(code_intel.PartialFinding, 1);
    intel.unresolved.partial_findings[0] = .{
        .kind = .scoped_claim,
        .label = try allocator.dupe(u8, "heading:runtime_contracts@1"),
        .scope = try allocator.dupe(u8, "sync"),
        .provenance = try allocator.dupe(u8, "symbolic_ingest"),
        .rel_path = try allocator.dupe(u8, "src/runtime/worker.zig"),
        .line = 1,
        .detail = try allocator.dupe(u8, "weak symbolic fragment narrowed the patch surface"),
    };
    intel.grounding_traces = try allocator.alloc(code_intel.GroundingTrace, 1);
    intel.grounding_traces[0] = .{
        .direction = .symbolic_to_code,
        .surface = "sync",
        .concept = "heading:runtime_contracts@1",
        .source_spec = "region:@corpus/docs/runbook.md:1-3",
        .selection_mode = .promoted,
        .owner_kind = .project,
        .owner_id = "patch-planning-test",
        .relation = "symbolic_unit_to_internal_concept",
        .lookup_score = 320,
        .confidence_score = 320,
        .trust_class = .project,
        .lineage_id = "lineage:test",
        .lineage_version = 1,
        .token_support_count = 2,
        .pattern_support_count = 2,
        .source_support_count = 1,
        .mapping_score = 360,
        .usable = true,
        .ambiguous = false,
        .resolution = .local,
        .conflict_kind = .none,
        .target_label = try allocator.dupe(u8, "sync"),
        .target_rel_path = try allocator.dupe(u8, "src/runtime/worker.zig"),
        .target_line = 1,
        .target_kind = try allocator.dupe(u8, "function"),
        .detail = try allocator.dupe(u8, "usable grounding anchor"),
    };

    const strategy_options = [_]StrategyOption{
        .{ .strategy = .local_guard, .score = 220 },
    };
    const candidates = try buildCandidates(allocator, repo_root, &intel, &.{}, (Caps{}).normalized(), &strategy_options);
    try std.testing.expect(candidates.len > 0);
    try std.testing.expect(candidateTraceHasKind(candidates[0], .code_intel_partial_anchor) or candidateTraceHasKind(candidates[0], .grounding_schema_anchor));

    var result = try initTestPatchResult(allocator, repo_root);
    result.candidates = candidates;
    const proof_queue = try prepareExploreToVerifyHandoff(allocator, (Caps{}).normalized(), &intel, &result);

    try std.testing.expectEqual(@as(usize, 0), proof_queue.len);
    try std.testing.expectEqual(@as(u32, @intCast(candidates.len)), result.handoff.proof.admission_blocked_count);
    try std.testing.expectEqual(CandidateStatus.novel_but_unverified, result.candidates[0].status);
    try std.testing.expect(result.candidates[0].verification.proof_reason != null);
}

test "weak evidence still cannot authorize a supported patch" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const repo_root = try createPatchPlanningTestRepo(allocator, "ghost-patch-proof-gate-test");
    defer deleteTreeIfExistsAbsolute(repo_root) catch {};

    var intel = try initTestCodeIntelResult(allocator, repo_root, .unresolved);
    intel.stop_reason = .low_confidence;
    intel.primary = .{
        .name = try allocator.dupe(u8, "sync"),
        .rel_path = try allocator.dupe(u8, "src/runtime/worker.zig"),
        .line = 1,
        .kind_name = "function",
        .subsystem = "runtime",
    };
    intel.partial_support = .{
        .lattice = .scoped,
        .blocking = .{ .ambiguous = true, .insufficient = true },
    };
    intel.unresolved.partial_findings = try allocator.alloc(code_intel.PartialFinding, 1);
    intel.unresolved.partial_findings[0] = .{
        .kind = .scoped_claim,
        .label = try allocator.dupe(u8, "competing_symbolic_anchor"),
        .scope = try allocator.dupe(u8, "sync"),
        .provenance = try allocator.dupe(u8, "grounding:test"),
        .rel_path = try allocator.dupe(u8, "src/runtime/worker.zig"),
        .line = 1,
        .detail = try allocator.dupe(u8, "equally plausible symbolic anchors remain"),
    };

    const detail = try proofAdmissionFailureDetail(allocator, &intel);
    try std.testing.expect(std.mem.indexOf(u8, detail, "ambiguous rationale") != null);
    try std.testing.expect(proofAdmissionBlockedReason(&intel) != null);
}

test "ambiguous patch unresolved output preserves partial rationale and missing obligations" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var result = try initTestPatchResult(allocator, "/tmp/ghost-patch-unresolved-test");
    result.unresolved_detail = try allocator.dupe(u8, "ambiguous symbolic mappings remained");
    result.planning_basis.partial_findings = try allocator.alloc(code_intel.PartialFinding, 1);
    result.planning_basis.partial_findings[0] = .{
        .kind = .scoped_claim,
        .label = try allocator.dupe(u8, "runtime_contract fragment"),
        .scope = try allocator.dupe(u8, "sync"),
        .provenance = try allocator.dupe(u8, "symbolic_ingest"),
        .rel_path = try allocator.dupe(u8, "src/runtime/worker.zig"),
        .line = 1,
        .detail = try allocator.dupe(u8, "parser sketch preserved this fragment"),
    };
    result.planning_basis.ambiguity_sets = try allocator.alloc(code_intel.AmbiguitySet, 1);
    result.planning_basis.ambiguity_sets[0] = .{
        .label = try allocator.dupe(u8, "grounding_ambiguity"),
        .scope = try allocator.dupe(u8, "sync"),
        .reason = try allocator.dupe(u8, "equally supported mappings"),
        .options = try allocator.alloc(code_intel.AmbiguityOption, 1),
    };
    result.planning_basis.ambiguity_sets[0].options[0] = .{
        .label = try allocator.dupe(u8, "src/runtime/worker.zig:sync"),
    };
    result.planning_basis.missing_obligations = try allocator.alloc(code_intel.MissingObligation, 1);
    result.planning_basis.missing_obligations[0] = .{
        .label = try allocator.dupe(u8, "ground_symbolic_fragment"),
        .scope = try allocator.dupe(u8, "sync"),
        .detail = try allocator.dupe(u8, "weak fragments remain non-authorizing"),
    };

    try derivePatchPartialSupport(allocator, &result);
    try std.testing.expect(result.unresolved.partial_findings.len > 0);
    try std.testing.expect(result.unresolved.ambiguity_sets.len > 0);
    try std.testing.expect(missingObligationPresent(result.unresolved.missing_obligations, "ground_symbolic_fragment"));
}

test "routing suppression and grounding anchors improve proof queue composition without bypassing proof gates" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const repo_root = try createPatchPlanningTestRepo(allocator, "ghost-patch-routing-grounding-test");
    defer deleteTreeIfExistsAbsolute(repo_root) catch {};

    var intel = try initTestCodeIntelResult(allocator, repo_root, .supported);
    intel.primary = .{
        .name = try allocator.dupe(u8, "sync"),
        .rel_path = try allocator.dupe(u8, "src/runtime/worker.zig"),
        .line = 1,
        .kind_name = "function",
        .subsystem = "runtime",
    };
    intel.partial_support = .{ .lattice = .scoped };
    intel.evidence = try allocator.alloc(code_intel.Evidence, 1);
    intel.evidence[0] = .{
        .rel_path = try allocator.dupe(u8, "src/runtime/noise.zig"),
        .line = 1,
        .reason = "noisy routed evidence",
        .subsystem = "runtime",
    };
    intel.routing_suppressed = try allocator.alloc(code_intel.SuppressedNoise, 1);
    intel.routing_suppressed[0] = .{
        .label = try allocator.dupe(u8, "noisy routed evidence"),
        .reason = try allocator.dupe(u8, "reinforced route suppressor"),
        .rel_path = try allocator.dupe(u8, "src/runtime/noise.zig"),
        .line = 1,
    };
    intel.grounding_traces = try allocator.alloc(code_intel.GroundingTrace, 1);
    intel.grounding_traces[0] = .{
        .direction = .symbolic_to_code,
        .surface = "sync",
        .concept = "heading:runtime_contracts@1",
        .source_spec = "region:@corpus/docs/runbook.md:1-3",
        .selection_mode = .promoted,
        .owner_kind = .project,
        .owner_id = "patch-planning-test",
        .relation = "symbolic_unit_to_internal_concept",
        .lookup_score = 320,
        .confidence_score = 320,
        .trust_class = .project,
        .lineage_id = "lineage:test",
        .lineage_version = 1,
        .token_support_count = 2,
        .pattern_support_count = 2,
        .source_support_count = 1,
        .mapping_score = 360,
        .usable = true,
        .ambiguous = false,
        .resolution = .local,
        .conflict_kind = .none,
        .target_label = try allocator.dupe(u8, "sync"),
        .target_rel_path = try allocator.dupe(u8, "src/runtime/worker.zig"),
        .target_line = 1,
        .target_kind = try allocator.dupe(u8, "function"),
        .detail = try allocator.dupe(u8, "usable grounding anchor"),
    };

    var surfaces = std.ArrayList(SurfaceSeed).init(allocator);
    try collectSurfaceSeeds(&surfaces, &intel, 4);
    try std.testing.expect(surfaces.items.len > 0);
    for (surfaces.items) |surface| {
        try std.testing.expect(!std.mem.eql(u8, surface.rel_path, "src/runtime/noise.zig"));
    }

    const strategy_options = [_]StrategyOption{
        .{ .strategy = .local_guard, .score = 220 },
    };
    const candidates = try buildCandidates(allocator, repo_root, &intel, &.{}, (Caps{}).normalized(), &strategy_options);
    try std.testing.expect(candidates.len > 0);
    try std.testing.expect(candidateTraceHasKind(candidates[0], .grounding_schema_anchor));
    try std.testing.expect(!candidateTraceHasPath(candidates[0], "src/runtime/noise.zig"));

    var result = try initTestPatchResult(allocator, repo_root);
    result.status = .supported;
    result.candidates = candidates;
    const proof_queue = try prepareExploreToVerifyHandoff(allocator, (Caps{}).normalized(), &intel, &result);
    try std.testing.expect(proof_queue.len > 0);
    try std.testing.expectEqual(@as(u32, 0), result.handoff.proof.admission_blocked_count);
}

test "low tier proof queue constrains verification more than high tier" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const repo_root = try createPatchPlanningTestRepo(allocator, "ghost-patch-budget-tier-test");
    defer deleteTreeIfExistsAbsolute(repo_root) catch {};

    var intel = try initTestCodeIntelResult(allocator, repo_root, .supported);
    intel.primary = .{
        .name = try allocator.dupe(u8, "sync"),
        .rel_path = try allocator.dupe(u8, "src/runtime/worker.zig"),
        .line = 1,
        .kind_name = "function",
        .subsystem = "runtime",
    };
    intel.evidence = try allocator.alloc(code_intel.Evidence, 2);
    intel.evidence[0] = .{ .rel_path = try allocator.dupe(u8, "src/runtime/worker.zig"), .line = 1, .reason = "primary", .subsystem = "runtime" };
    intel.evidence[1] = .{ .rel_path = try allocator.dupe(u8, "src/runtime/noise.zig"), .line = 1, .reason = "secondary", .subsystem = "runtime" };
    intel.refactor_path = try allocator.alloc(code_intel.Evidence, 1);
    intel.refactor_path[0] = .{ .rel_path = try allocator.dupe(u8, "src/runtime/worker.zig"), .line = 1, .reason = "path", .subsystem = "runtime" };

    const strategy_options = [_]StrategyOption{
        .{ .strategy = .local_guard, .score = 260 },
        .{ .strategy = .seam_adapter, .score = 240 },
        .{ .strategy = .contradiction_split, .score = 220 },
    };

    const low_budget = compute_budget.resolve(.{ .tier = .low });
    var low_caps = (Caps{}).normalized();
    low_caps.max_candidates = @min(low_caps.max_candidates, low_budget.max_proof_queue_size);
    var low_result = try initTestPatchResult(allocator, repo_root);
    low_result.effective_budget = low_budget;
    low_result.candidates = try buildCandidates(allocator, repo_root, &intel, &.{}, low_caps, &strategy_options);
    const low_queue = try prepareExploreToVerifyHandoff(allocator, low_caps, &intel, &low_result);

    const high_budget = compute_budget.resolve(.{ .tier = .high });
    var high_caps = (Caps{}).normalized();
    high_caps.max_candidates = @min(high_caps.max_candidates, high_budget.max_proof_queue_size);
    var high_result = try initTestPatchResult(allocator, repo_root);
    high_result.effective_budget = high_budget;
    high_result.candidates = try buildCandidates(allocator, repo_root, &intel, &.{}, high_caps, &strategy_options);
    const high_queue = try prepareExploreToVerifyHandoff(allocator, high_caps, &intel, &high_result);

    try std.testing.expectEqual(@as(usize, 1), low_queue.len);
    try std.testing.expect(high_queue.len > low_queue.len);
}

test "speculative scheduler records candidate model and deterministic order" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const repo_root = try createPatchPlanningTestRepo(allocator, "ghost-speculative-scheduler-test");
    defer deleteTreeIfExistsAbsolute(repo_root) catch {};

    var intel = try initTestCodeIntelResult(allocator, repo_root, .supported);
    intel.primary = .{
        .name = try allocator.dupe(u8, "sync"),
        .rel_path = try allocator.dupe(u8, "src/runtime/worker.zig"),
        .line = 1,
        .kind_name = "function",
        .subsystem = "runtime",
    };
    intel.evidence = try allocator.alloc(code_intel.Evidence, 2);
    intel.evidence[0] = .{ .rel_path = try allocator.dupe(u8, "src/runtime/worker.zig"), .line = 1, .reason = "primary", .subsystem = "runtime" };
    intel.evidence[1] = .{ .rel_path = try allocator.dupe(u8, "src/runtime/noise.zig"), .line = 1, .reason = "secondary", .subsystem = "runtime" };
    intel.refactor_path = try allocator.alloc(code_intel.Evidence, 1);
    intel.refactor_path[0] = .{ .rel_path = try allocator.dupe(u8, "src/runtime/worker.zig"), .line = 1, .reason = "path", .subsystem = "runtime" };

    const strategy_options = [_]StrategyOption{
        .{ .strategy = .local_guard, .score = 260 },
        .{ .strategy = .seam_adapter, .score = 240 },
        .{ .strategy = .contradiction_split, .score = 220 },
    };
    var caps = (Caps{}).normalized();
    caps.max_candidates = 3;

    var first = try initTestPatchResult(allocator, repo_root);
    first.status = .supported;
    first.candidates = try buildCandidates(allocator, repo_root, &intel, &.{}, caps, &strategy_options);
    const first_queue = try prepareExploreToVerifyHandoff(allocator, caps, &intel, &first);

    var second = try initTestPatchResult(allocator, repo_root);
    second.status = .supported;
    second.candidates = try buildCandidates(allocator, repo_root, &intel, &.{}, caps, &strategy_options);
    const second_queue = try prepareExploreToVerifyHandoff(allocator, caps, &intel, &second);

    try std.testing.expect(first.candidates.len > 1);
    try std.testing.expectEqual(first_queue.len, second_queue.len);
    for (first_queue, 0..) |candidate_idx, idx| {
        const candidate = first.candidates[candidate_idx];
        try std.testing.expectEqualStrings(candidate.id, second.candidates[second_queue[idx]].id);
        try std.testing.expect(candidate.source_intent.len > 0);
        try std.testing.expect(candidate.action_surface.len > 0);
        try std.testing.expect(candidate.bound_artifacts.len > 0);
        try std.testing.expect(candidate.required_obligations.len > 0);
        try std.testing.expect(candidate.initial_support_estimate.estimated_cost > 0);
        try std.testing.expect(candidate.scheduler_status == .pending);
    }
}

test "speculative scheduler prunes impossible candidate without deleting trace" {
    var candidate = Candidate{
        .id = try std.testing.allocator.dupe(u8, "candidate_bad"),
        .source_intent = try std.testing.allocator.dupe(u8, "src/runtime/worker.zig:sync"),
        .action_surface = try std.testing.allocator.dupe(u8, "local_guard"),
        .summary = try std.testing.allocator.dupe(u8, "invalid empty patch"),
        .strategy = try std.testing.allocator.dupe(u8, "local_guard"),
        .scope = try std.testing.allocator.dupe(u8, "focused_single_surface"),
        .score = 1,
    };
    defer candidate.deinit(std.testing.allocator);

    var intel = code_intel.Result{
        .allocator = std.testing.allocator,
        .status = .supported,
        .query_kind = .impact,
        .query_target = try std.testing.allocator.dupe(u8, "src/runtime/worker.zig:sync"),
        .repo_root = try std.testing.allocator.dupe(u8, "/tmp/ghost-scheduler-prune"),
        .shard_root = try std.testing.allocator.dupe(u8, "/tmp/ghost-scheduler-prune"),
        .shard_id = try std.testing.allocator.dupe(u8, "ghost-scheduler-prune"),
        .shard_kind = .project,
        .unresolved = .{ .allocator = std.testing.allocator },
        .support_graph = .{ .allocator = std.testing.allocator },
    };
    defer intel.deinit();

    candidate.initial_support_estimate = try estimateInitialSupport(std.testing.allocator, &intel, &candidate, (Caps{}).normalized());
    try std.testing.expect(!candidate.initial_support_estimate.viable);
    try std.testing.expect(candidate.initial_support_estimate.blocking_flags.len > 0);
}

test "patch budget exhaustion is surfaced honestly" {
    var result = Result{
        .allocator = std.testing.allocator,
        .status = .supported,
        .query_kind = .impact,
        .target = try std.testing.allocator.dupe(u8, "src/runtime/worker.zig:sync"),
        .request_label = try std.testing.allocator.dupe(u8, "budget patch test"),
        .repo_root = try std.testing.allocator.dupe(u8, "/tmp/ghost-budget-patch"),
        .shard_id = try std.testing.allocator.dupe(u8, "ghost-budget-patch"),
        .shard_root = try std.testing.allocator.dupe(u8, "/tmp/ghost-budget-patch"),
        .shard_kind = .project,
        .code_intel_result_path = try std.testing.allocator.dupe(u8, ""),
        .caps = (Caps{}).normalized(),
        .effective_budget = compute_budget.resolve(.{ .tier = .low }),
        .planning_basis = .{ .allocator = std.testing.allocator },
        .unresolved = .{ .allocator = std.testing.allocator },
        .support_graph = .{ .allocator = std.testing.allocator },
    };
    defer result.deinit();

    try setBudgetExhaustion(
        std.testing.allocator,
        &result,
        .max_proof_queue_size,
        .patch_proof_handoff,
        3,
        result.effective_budget.max_proof_queue_size,
        "proof queue capacity was exhausted",
        "additional admissible candidates were skipped",
    );

    try std.testing.expectEqual(mc.StopReason.budget, result.stop_reason);
    try std.testing.expectEqual(code_intel.Status.unresolved, result.status);
    try std.testing.expect(result.budget_exhaustion != null);
    try std.testing.expect(std.mem.indexOf(u8, result.unresolved_detail.?, "compute budget exhausted") != null);
}

test "policy: code intervention penalty applies costs but neutral artifact policy does not" {
    const surfaces = [_]SurfaceSeed{};

    const seed = PlanSeed{
        .strategy = .local_guard,
        .surface_indexes = [_]u8{0} ** 4,
        .surface_count = 3, // simulate 3 files/hunks
        .scope_mode = .expanded,
        .strategy_score = 0,
        .minimality = .{},
    };

    const code_cost = computeMinimalityEvidenceWithPolicy(undefined, &surfaces, seed, DEFAULT_CODE_INTERVENTION_POLICY);
    const neutral_policy = ArtifactInterventionPolicy{};
    const neutral_cost = computeMinimalityEvidenceWithPolicy(undefined, &surfaces, seed, .{
        .file_cost = neutral_policy.file_cost,
        .hunk_cost = neutral_policy.hunk_cost,
        .change_cost = neutral_policy.change_cost,
        .dependency_cost = neutral_policy.dependency_cost,
        .focused_scope_penalty = neutral_policy.focused_scope_penalty,
        .expanded_scope_penalty = neutral_policy.expanded_scope_penalty,
        .max_bounded_cost = neutral_policy.max_bounded_cost,
    });

    // Code policy penalizes heavily
    try std.testing.expectEqual(DEFAULT_CODE_INTERVENTION_POLICY.file_cost, 400);
    try std.testing.expectEqual(DEFAULT_CODE_INTERVENTION_POLICY.dependency_cost, 220);
    try std.testing.expect(code_cost.file_count == 3);
    try std.testing.expect(code_cost.total_cost > 1000);
    try std.testing.expect(code_cost.scope_penalty == 180);

    // Neutral policy doesn't inherit code phobias
    try std.testing.expectEqual(neutral_policy.file_cost, 0);
    try std.testing.expectEqual(neutral_policy.dependency_cost, 0);
    try std.testing.expect(neutral_cost.file_count == 3);
    try std.testing.expect(neutral_cost.total_cost < 200); // just hunk/change costs
    try std.testing.expect(neutral_cost.scope_penalty == 0);
}

test "policy scoring does not grant proof or support status" {
    var candidate = Candidate{
        .id = try std.testing.allocator.dupe(u8, "candidate_scoring"),
        .source_intent = try std.testing.allocator.dupe(u8, "test"),
        .action_surface = try std.testing.allocator.dupe(u8, "test"),
        .summary = try std.testing.allocator.dupe(u8, "test"),
        .strategy = try std.testing.allocator.dupe(u8, "test"),
        .scope = try std.testing.allocator.dupe(u8, "test"),
        .score = 100,
        .minimality = .{
            .file_count = 1,
            .change_count = 1,
            .hunk_count = 1,
            .dependency_spread = 0,
            .scope_penalty = 0,
            .total_cost = 0, // perfect minimality (0 penalty)
        },
        .validation_state = .draft_unvalidated,
    };
    defer candidate.deinit(std.testing.allocator);

    const workflow = VerificationWorkflow{
        .test_available = false,
        .runtime_available = false,
        .runtime_oracle = null,
    };

    const initial_state = candidate.validation_state;
    const score = proofScore(&candidate, workflow);

    // Scoring is applied.
    try std.testing.expect(score == 2700);

    // The core requirement: policy scoring MUST NOT mutate or grant proof/support validation state.
    try std.testing.expectEqual(initial_state, candidate.validation_state);
}
