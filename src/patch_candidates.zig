const std = @import("std");
const abstractions = @import("abstractions.zig");
const code_intel = @import("code_intel.zig");
const config = @import("config.zig");
const execution = @import("execution.zig");
const mc = @import("inference.zig");
const shards = @import("shards.zig");
const sys = @import("sys.zig");
const task_intent = @import("task_intent.zig");

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
pub const MAX_VERIFICATION_TIMEOUT_MS: u32 = 12_000;
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

pub const SupportKind = enum {
    strategy,
    code_intel_target,
    code_intel_hypothesis,
    code_intel_primary,
    code_intel_secondary,
    code_intel_evidence,
    code_intel_refactor_path,
    code_intel_overlap,
    code_intel_contradiction,
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
    proof_rejected,
    verified_supported,
};

pub const CandidateStatus = enum {
    rejected,
    unresolved,
    supported,
    novel_but_unverified,
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

pub const VerificationStep = struct {
    state: VerificationStepState = .unavailable,
    command: ?[]u8 = null,
    exit_code: ?i32 = null,
    duration_ms: u64 = 0,
    failure_signal: ?execution.FailureSignal = null,
    summary: ?[]u8 = null,
    evidence: ?[]u8 = null,

    fn deinit(self: *VerificationStep, allocator: std.mem.Allocator) void {
        if (self.command) |command| allocator.free(command);
        if (self.summary) |summary| allocator.free(summary);
        if (self.evidence) |evidence| allocator.free(evidence);
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
    refinements: []RefinementTrace = &.{},

    fn deinit(self: *VerificationTrace, allocator: std.mem.Allocator) void {
        self.build.deinit(allocator);
        self.test_step.deinit(allocator);
        self.runtime_step.deinit(allocator);
        if (self.proof_reason) |reason| allocator.free(reason);
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
    hunks: []PatchHunk = &.{},
    trace: []SupportTrace = &.{},
    verification: VerificationTrace = .{},
    rejection_reason: ?[]u8 = null,

    fn deinit(self: *Candidate, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.summary);
        allocator.free(self.strategy);
        allocator.free(self.scope);
        if (self.status_reason) |reason| allocator.free(reason);
        if (self.cluster_id) |cluster_id| allocator.free(cluster_id);
        if (self.cluster_label) |cluster_label| allocator.free(cluster_label);
        for (self.files) |item| allocator.free(item);
        allocator.free(self.files);
        for (self.hunks) |*hunk| hunk.deinit(allocator);
        allocator.free(self.hunks);
        for (self.trace) |*trace| trace.deinit(allocator);
        allocator.free(self.trace);
        self.verification.deinit(allocator);
        if (self.rejection_reason) |reason| allocator.free(reason);
        self.* = undefined;
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
    intent: ?task_intent.Task = null,
    staged_path: ?[]u8 = null,
    code_intel_result_path: []u8,
    caps: Caps,
    strategy_hypotheses: []ScoreTrace = &.{},
    invariant_evidence: []SupportTrace = &.{},
    contradiction_evidence: []SupportTrace = &.{},
    abstraction_refs: []SupportTrace = &.{},
    handoff: ExploreToVerifyHandoff = .{},
    candidates: []Candidate = &.{},
    support_graph: code_intel.SupportGraph = .{ .allocator = undefined },

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
        for (self.strategy_hypotheses) |*trace| trace.deinit(self.allocator);
        self.allocator.free(self.strategy_hypotheses);
        for (self.invariant_evidence) |*trace| trace.deinit(self.allocator);
        self.allocator.free(self.invariant_evidence);
        for (self.contradiction_evidence) |*trace| trace.deinit(self.allocator);
        self.allocator.free(self.contradiction_evidence);
        for (self.abstraction_refs) |*trace| trace.deinit(self.allocator);
        self.allocator.free(self.abstraction_refs);
        self.handoff.deinit(self.allocator);
        for (self.candidates) |*candidate| candidate.deinit(self.allocator);
        self.allocator.free(self.candidates);
        self.support_graph.deinit();
        self.* = undefined;
    }
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
    if (result.contradiction_kind) |kind| try writeOptionalStringField(writer, "contradictionKind", kind);
    if (result.selected_strategy) |strategy| try writeOptionalStringField(writer, "selectedStrategy", strategy);
    if (result.selected_candidate_id) |candidate_id| try writeOptionalStringField(writer, "selectedCandidateId", candidate_id);
    if (result.unresolved_detail) |detail| try writeOptionalStringField(writer, "unresolvedDetail", detail);
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
    try writer.writeAll(",\"handoff\":");
    try writeHandoffJson(writer, result.handoff);
    try writer.writeAll(",\"candidates\":");
    try writeCandidateArray(writer, result.candidates);
    try writer.writeAll(",\"supportGraph\":");
    try code_intel.writeSupportGraphJson(writer, result.support_graph);
    try writer.writeAll("}");
    return out.toOwnedSlice();
}

fn runWithPaths(allocator: std.mem.Allocator, paths: *const shards.Paths, options: Options) !Result {
    const caps = options.caps.normalized();

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
    result.status = intel.status;
    result.stop_reason = intel.stop_reason;
    result.confidence = intel.confidence;
    if (options.intent) |intent| result.intent = try intent.clone(allocator);
    if (intel.selected_scope) |scope| result.selected_scope = try allocator.dupe(u8, scope);
    if (intel.contradiction_kind) |kind| result.contradiction_kind = try allocator.dupe(u8, kind);
    result.invariant_evidence = try buildInvariantEvidence(allocator, &intel, caps.max_support_items);
    result.contradiction_evidence = try buildContradictionEvidence(allocator, &intel, caps.max_support_items);

    var support_paths = std.ArrayList([]const u8).init(allocator);
    defer support_paths.deinit();
    try collectSupportPaths(&support_paths, &intel, caps.max_files);

    const abstraction_refs = try abstractions.collectSupportingConcepts(allocator, paths, support_paths.items, caps.max_abstractions);
    defer abstractions.deinitSupportReferences(allocator, abstraction_refs);
    result.abstraction_refs = try buildAbstractionTraces(allocator, abstraction_refs);
    const usable_abstraction_refs = abstractions.countUsableReferences(abstraction_refs);

    if (intel.status != .supported or intel.stop_reason != .none) {
        try finalizePatchSupportGraph(allocator, &result);
        if (options.stage_result) try stageResult(allocator, paths, &result);
        return result;
    }

    var strategy_hypotheses = std.ArrayList(ScoreTrace).init(allocator);
    defer {
        for (strategy_hypotheses.items) |*trace| trace.deinit(allocator);
        strategy_hypotheses.deinit();
    }
    var strategy_options = std.ArrayList(StrategyOption).init(allocator);
    defer strategy_options.deinit();

    try appendStrategyOption(allocator, &strategy_hypotheses, &strategy_options, .local_guard, intel.evidence.len + intel.refactor_path.len, intel.primary != null);
    try appendStrategyOption(allocator, &strategy_hypotheses, &strategy_options, .seam_adapter, intel.refactor_path.len + intel.overlap.len, intel.refactor_path.len + intel.overlap.len > 1);
    try appendStrategyOption(allocator, &strategy_hypotheses, &strategy_options, .contradiction_split, intel.contradiction_traces.len + intel.overlap.len, intel.contradiction_traces.len > 0 or intel.query_kind == .contradicts);
    try appendStrategyOption(allocator, &strategy_hypotheses, &strategy_options, .abstraction_alignment, usable_abstraction_refs, usable_abstraction_refs > 0);

    result.strategy_hypotheses = try cloneScoreTraces(allocator, strategy_hypotheses.items);
    if (strategy_options.items.len == 0) {
        result.status = .unresolved;
        result.stop_reason = .low_confidence;
        result.confidence = 0;
        result.unresolved_detail = try allocator.dupe(u8, "no bounded refactor strategy survived deterministic planning");
        try finalizePatchSupportGraph(allocator, &result);
        if (options.stage_result) try stageResult(allocator, paths, &result);
        return result;
    }

    const candidates = try buildCandidates(allocator, options.repo_root, &intel, abstraction_refs, caps, strategy_options.items);
    if (candidates.len == 0) {
        result.status = .unresolved;
        result.stop_reason = .low_confidence;
        result.confidence = 0;
        result.unresolved_detail = try allocator.dupe(u8, "no bounded patch scaffold survived candidate construction");
        try finalizePatchSupportGraph(allocator, &result);
        if (options.stage_result) try stageResult(allocator, paths, &result);
        return result;
    }

    result.candidates = candidates;
    const proof_queue = try prepareExploreToVerifyHandoff(allocator, caps, &result);
    defer allocator.free(proof_queue);
    try verifyCandidates(allocator, paths, options, &result, proof_queue);

    try finalizePatchSupportGraph(allocator, &result);
    if (options.stage_result) try stageResult(allocator, paths, &result);
    return result;
}

fn verifyCandidates(allocator: std.mem.Allocator, paths: *const shards.Paths, options: Options, result: *Result, proof_queue: []const usize) !void {
    const workflow = detectVerificationWorkflow(options.repo_root);
    const max_retries = @min(options.max_verification_retries, MAX_VERIFICATION_RETRIES);
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

    var proof_branch_ids = std.ArrayList(u32).init(allocator);
    defer proof_branch_ids.deinit();
    var proof_scores = std.ArrayList(u32).init(allocator);
    defer proof_scores.deinit();
    var proof_indexes = std.ArrayList(usize).init(allocator);
    defer proof_indexes.deinit();

    for (proof_queue) |idx| {
        const candidate = &result.candidates[idx];
        const survived = try verifyCandidate(allocator, paths, options.repo_root, options.verification_path_override, workflow, max_retries, candidate);
        if (!survived) continue;

        candidate.verification.proof_score = proofScore(candidate, workflow);
        candidate.verification.proof_confidence = candidate.verification.proof_score;
        if (candidate.verification.proof_reason) |reason| allocator.free(reason);
        candidate.verification.proof_reason = try allocator.dupe(
            u8,
            if (workflow.test_available)
                "candidate survived build and test verification"
            else if (workflow.runtime_available)
                "candidate survived build and runtime verification"
            else
                "candidate survived build verification; no runtime workflow was available",
        );
        try proof_branch_ids.append(@intCast(idx + 1));
        try proof_scores.append(candidate.verification.proof_score);
        try proof_indexes.append(idx);
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
            candidate.validation_state = .verified_supported;
            candidate.verification.proof_confidence = decision.confidence;
            if (candidate.verification.proof_reason) |reason| allocator.free(reason);
            candidate.verification.proof_reason = try allocator.dupe(
                u8,
                "Layer 2 proof mode selected this verified survivor as the bounded winner",
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

fn finalizePatchSupportGraph(allocator: std.mem.Allocator, result: *Result) !void {
    if (result.status == .supported and !patchSupportMinimumMet(result)) {
        result.status = .unresolved;
        result.stop_reason = .low_confidence;
        result.confidence = 0;
        if (result.unresolved_detail) |detail| allocator.free(detail);
        result.unresolved_detail = try allocator.dupe(u8, "patch result lacked the minimum bounded support required for final permission");
    }
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
    }

    var execution_node_count: usize = 0;
    for (result.candidates) |candidate| {
        if (!candidate.entered_proof_mode) continue;
        try appendCandidateExecutionNodes(allocator, &nodes, &edges, "output", candidate, &execution_node_count);
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

    if (result.status != .supported and result.unresolved_detail != null) {
        try appendPatchSupportNode(allocator, &nodes, "gap", .gap, "support_gap", null, 0, 0, false, result.unresolved_detail);
        try appendPatchSupportEdge(allocator, &edges, "output", "gap", .blocked_by);
    }

    return .{
        .allocator = allocator,
        .permission = result.status,
        .minimum_met = patchSupportMinimumMet(result),
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

    const node_id = try std.fmt.allocPrint(allocator, "execution_{d}", .{execution_node_count.* + 1});
    defer allocator.free(node_id);
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
        node_id,
        .execution,
        label,
        null,
        0,
        candidate.score,
        step.state == .passed,
        detail,
    );
    try appendPatchSupportEdge(allocator, edges, parent_id, node_id, .checked_by);
    execution_node_count.* += 1;

    if (step.state == .failed) {
        const contradiction_id = try std.fmt.allocPrint(allocator, "execution_contradiction_{d}", .{execution_node_count.*});
        defer allocator.free(contradiction_id);
        const contradiction_label = try std.fmt.allocPrint(allocator, "{s} {s} contradicted expected runtime invariants", .{ candidate.id, phase_name });
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
        "candidate={s}; status={s}; exit_code={s}; duration_ms={d}; failure_signal={s}; summary={s}",
        .{
            candidate.id,
            verificationStepStateName(step.state),
            exit_text,
            step.duration_ms,
            if (step.failure_signal) |signal| execution.failureSignalName(signal) else "none",
            if (step.summary) |summary| summary else "none",
        },
    );
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

fn verifyCandidate(
    allocator: std.mem.Allocator,
    paths: *const shards.Paths,
    repo_root: []const u8,
    path_override: ?[]const u8,
    workflow: VerificationWorkflow,
    max_retries: u32,
    candidate: *Candidate,
) !bool {
    var attempt: u32 = 0;
    while (attempt <= max_retries) : (attempt += 1) {
        const hypothesis = verificationHypothesis(candidate, attempt, max_retries);
        const workspace_root = try createVerificationWorkspace(allocator, paths, repo_root, candidate.id, attempt);
        defer {
            deleteTreeIfExists(workspace_root) catch {};
            allocator.free(workspace_root);
        }

        if (attempt > 0) {
            try appendRefinementTrace(
                allocator,
                &candidate.verification,
                attempt,
                hypothesis.label,
                hypothesis.reason,
                @intCast(hypothesis.retained_hunk_count orelse candidate.hunks.len),
            );
        }

        try applyCandidateToWorkspace(allocator, workspace_root, candidate, hypothesis);

        var build_capture = try execution.run(allocator, .{
            .workspace_root = workspace_root,
            .cwd = workspace_root,
            .path_override = path_override,
            .max_output_bytes = MAX_VERIFICATION_OUTPUT_BYTES,
        }, .{
            .label = "zig_build",
            .kind = .zig_build,
            .phase = execution.Phase.build,
            .argv = &.{ "zig", "build" },
            .expectations = &.{.{ .success = {} }},
            .timeout_ms = MAX_VERIFICATION_TIMEOUT_MS,
        });
        defer build_capture.deinit(allocator);
        try updateVerificationStep(
            allocator,
            &candidate.verification.build,
            &build_capture,
            attempt,
            max_retries,
            "build",
        );
        if (!build_capture.succeeded()) {
            if (shouldRefineCandidate(candidate, attempt, max_retries)) {
                candidate.verification.retry_count = attempt + 1;
                continue;
            }
            if (attempt < max_retries) {
                candidate.verification.retry_count = attempt + 1;
                continue;
            }
            candidate.validation_state = .build_failed;
            try setCandidateStatus(allocator, candidate, .rejected, "candidate failed Linux build verification");
            return false;
        }

        if (workflow.test_available) {
            var test_capture = try execution.run(allocator, .{
                .workspace_root = workspace_root,
                .cwd = workspace_root,
                .path_override = path_override,
                .max_output_bytes = MAX_VERIFICATION_OUTPUT_BYTES,
            }, .{
                .label = "zig_build_test",
                .kind = .zig_build,
                .phase = execution.Phase.@"test",
                .argv = &.{ "zig", "build", "test" },
                .expectations = &.{.{ .success = {} }},
                .timeout_ms = MAX_VERIFICATION_TIMEOUT_MS,
            });
            defer test_capture.deinit(allocator);
            try updateVerificationStep(
                allocator,
                &candidate.verification.test_step,
                &test_capture,
                attempt,
                max_retries,
                "test",
            );
            if (!test_capture.succeeded()) {
                if (shouldRefineCandidate(candidate, attempt, max_retries)) {
                    candidate.verification.retry_count = attempt + 1;
                    continue;
                }
                if (attempt < max_retries) {
                    candidate.verification.retry_count = attempt + 1;
                    continue;
                }
                candidate.validation_state = .test_failed;
                try setCandidateStatus(allocator, candidate, .rejected, "candidate failed Linux test verification");
                return false;
            }
            try setUnavailableVerificationStep(allocator, &candidate.verification.runtime_step, "test workflow covered runtime verification for this candidate");
        } else {
            try setUnavailableVerificationStep(allocator, &candidate.verification.test_step, "no Linux-native test workflow was detected");
        }

        if (!workflow.test_available and workflow.runtime_available) {
            const argv = [_][]const u8{ "zig", "run", workflow.runtime_target.? };
            var runtime_capture = try execution.run(allocator, .{
                .workspace_root = workspace_root,
                .cwd = workspace_root,
                .path_override = path_override,
                .max_output_bytes = MAX_VERIFICATION_OUTPUT_BYTES,
            }, .{
                .label = "zig_run",
                .kind = .zig_run,
                .phase = execution.Phase.run,
                .argv = &argv,
                .expectations = &.{
                    .{ .success = {} },
                    .{ .stderr_not_contains = "panic" },
                },
                .timeout_ms = MAX_VERIFICATION_TIMEOUT_MS,
            });
            defer runtime_capture.deinit(allocator);
            try updateVerificationStep(
                allocator,
                &candidate.verification.runtime_step,
                &runtime_capture,
                attempt,
                max_retries,
                "runtime",
            );
            if (!runtime_capture.succeeded()) {
                if (shouldRefineCandidate(candidate, attempt, max_retries)) {
                    candidate.verification.retry_count = attempt + 1;
                    continue;
                }
                if (attempt < max_retries) {
                    candidate.verification.retry_count = attempt + 1;
                    continue;
                }
                candidate.validation_state = .test_failed;
                try setCandidateStatus(allocator, candidate, .rejected, "candidate failed Linux runtime verification");
                return false;
            }
        } else {
            try setUnavailableVerificationStep(allocator, &candidate.verification.runtime_step, "runtime verification was not required for this candidate");
        }

        candidate.verification.retry_count = attempt;
        return true;
    }

    candidate.validation_state = .build_failed;
    return false;
}

fn verificationHypothesis(candidate: *const Candidate, attempt: u32, max_retries: u32) VerificationHypothesis {
    if (attempt == 0) {
        return .{
            .label = "base_candidate",
            .reason = "execute the full bounded candidate before any refinement",
        };
    }
    if (candidate.hunks.len > 1 and attempt <= max_retries) {
        return .{
            .label = "narrow_to_primary_surface",
            .retained_hunk_count = 1,
            .reason = "runtime failure contradicted the broader hypothesis; retry a smaller primary-surface slice",
        };
    }
    return .{
        .label = "transient_retry",
        .reason = "no smaller deterministic refinement was available; retry once within the bounded budget",
    };
}

fn shouldRefineCandidate(candidate: *const Candidate, attempt: u32, max_retries: u32) bool {
    return candidate.hunks.len > 1 and attempt < max_retries;
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

fn detectVerificationWorkflow(repo_root: []const u8) VerificationWorkflow {
    const build_path = std.fs.path.join(std.heap.page_allocator, &.{ repo_root, "build.zig" }) catch return .{};
    defer std.heap.page_allocator.free(build_path);
    const has_build = fileExists(build_path);
    const main_path = std.fs.path.join(std.heap.page_allocator, &.{ repo_root, "src", "main.zig" }) catch return .{
        .build_available = has_build,
        .test_available = has_build,
    };
    defer std.heap.page_allocator.free(main_path);
    const has_main = fileExists(main_path);
    return .{
        .build_available = has_build,
        .test_available = has_build,
        .runtime_available = has_main,
        .runtime_target = if (has_main) "src/main.zig" else null,
    };
}

fn proofScore(candidate: *const Candidate, workflow: VerificationWorkflow) u32 {
    const bounded_cost = @min(candidate.minimality.total_cost, @as(u32, 2000));
    var score: u32 = @as(u32, 2600) - bounded_cost;
    score +%= candidate.score;
    if (workflow.test_available) score +%= 40;
    if (candidate.verification.runtime_step.state == .passed or (!workflow.runtime_available and workflow.test_available)) score +%= 20;
    return score;
}

fn createVerificationWorkspace(
    allocator: std.mem.Allocator,
    paths: *const shards.Paths,
    repo_root: []const u8,
    candidate_id: []const u8,
    attempt: u32,
) ![]u8 {
    const verification_root = try std.fs.path.join(allocator, &.{ paths.patch_candidates_root_abs_path, "verification" });
    defer allocator.free(verification_root);
    try sys.makePath(allocator, verification_root);

    const attempt_dir = try attemptDirName(allocator, attempt);
    defer allocator.free(attempt_dir);
    const workspace_root = try std.fs.path.join(allocator, &.{ verification_root, candidate_id, attempt_dir });
    errdefer allocator.free(workspace_root);

    try deleteTreeIfExists(workspace_root);
    try sys.makePath(allocator, workspace_root);
    try copyTreeAbsolute(allocator, repo_root, workspace_root);
    return workspace_root;
}

fn attemptDirName(allocator: std.mem.Allocator, attempt: u32) ![]u8 {
    return std.fmt.allocPrint(allocator, "attempt_{d}", .{attempt + 1});
}

const VerificationHypothesis = struct {
    label: []const u8,
    retained_hunk_count: ?usize = null,
    reason: []const u8,
};

fn applyCandidateToWorkspace(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    candidate: *const Candidate,
    hypothesis: VerificationHypothesis,
) !void {
    for (candidate.files) |rel_path| {
        const hunk_count = countCandidateHunksForPath(candidate.hunks, rel_path, hypothesis.retained_hunk_count);
        if (hunk_count == 0) continue;

        var path_hunks = try allocator.alloc(PatchHunk, hunk_count);
        defer allocator.free(path_hunks);

        var idx: usize = 0;
        for (candidate.hunks, 0..) |hunk, hunk_idx| {
            if (hypothesis.retained_hunk_count) |limit| {
                if (hunk_idx >= limit) break;
            }
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

fn countCandidateHunksForPath(hunks: []const PatchHunk, rel_path: []const u8, retained_hunk_count: ?usize) usize {
    var count: usize = 0;
    for (hunks, 0..) |hunk, idx| {
        if (retained_hunk_count) |limit| if (idx >= limit) break;
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

fn copyTreeAbsolute(
    allocator: std.mem.Allocator,
    source_root: []const u8,
    dest_root: []const u8,
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
                try std.fs.copyFileAbsolute(source_path, target_path, .{});
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
    if (step.command) |command| allocator.free(command);
    if (step.summary) |summary| allocator.free(summary);
    if (step.evidence) |evidence| allocator.free(evidence);
    step.* = .{};
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
        .support_graph = .{ .allocator = allocator },
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
                const extra_idx = findExpandedSurfaceIndex(surfaces.items, focus_idx) orelse continue;
                try appendPlanSeed(&plan_seeds, intel, surfaces.items, option, .expanded, @intCast(focus_idx), @intCast(extra_idx));
            }
        }
    }
    if (plan_seeds.items.len == 0) return allocator.alloc(Candidate, 0);

    std.sort.heap(PlanSeed, plan_seeds.items, surfaces.items, lessThanPlanSeed);
    const selected_seeds = try selectPlanSeeds(allocator, plan_seeds.items, exploratoryCandidatePoolCap(caps));
    defer allocator.free(selected_seeds);

    const candidate_count = selected_seeds.len;
    var out = try allocator.alloc(Candidate, candidate_count);

    var built: usize = 0;
    errdefer {
        for (out[0..built]) |*candidate| candidate.deinit(allocator);
        allocator.free(out);
    }

    for (selected_seeds, 0..) |seed, idx| {
        out[idx] = try buildCandidate(
            allocator,
            repo_root,
            intel,
            abstraction_refs,
            surfaces.items,
            caps,
            seed,
            @intCast(idx),
        );
        built += 1;
    }

    return out;
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
) !Candidate {
    var hunks = std.ArrayList(PatchHunk).init(allocator);
    defer hunks.deinit();

    const focus_surface = surfaces[plan.surface_indexes[0]];
    var plan_idx: usize = 0;
    while (plan_idx < plan.surface_count) : (plan_idx += 1) {
        const surface = surfaces[plan.surface_indexes[plan_idx]];
        try hunks.append(try buildDraftHunk(allocator, repo_root, surface, plan.strategy, caps, ordinal, abstraction_refs));
    }

    var files = std.ArrayList([]u8).init(allocator);
    defer {
        for (files.items) |item| allocator.free(item);
        files.deinit();
    }
    for (hunks.items) |hunk| {
        if (!containsString(files.items, hunk.rel_path)) {
            try files.append(try allocator.dupe(u8, hunk.rel_path));
        }
    }

    var trace = std.ArrayList(SupportTrace).init(allocator);
    defer {
        for (trace.items) |*item| item.deinit(allocator);
        trace.deinit();
    }
    try trace.append(try makeSupportTrace(allocator, .strategy, strategyName(plan.strategy), null, 0, plan.strategy_score, "Deterministic refactor planner retained this bounded patch strategy"));
    try trace.append(try makeSurfaceTrace(allocator, focus_surface));
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
            0,
            reference.source_spec,
        ));
    }

    const summary = try std.fmt.allocPrint(
        allocator,
        "Draft {s} {s} scaffold around {s}:{d}",
        .{ strategyName(plan.strategy), scopeModeName(plan.scope_mode), focus_surface.rel_path, focus_surface.line },
    );
    errdefer allocator.free(summary);

    const candidate_score = plan.strategy_score +% focus_surface.score -% @min(ordinal * 12, plan.strategy_score / 2);
    return .{
        .id = try std.fmt.allocPrint(allocator, "candidate_{d}", .{ordinal + 1}),
        .summary = summary,
        .strategy = try allocator.dupe(u8, strategyName(plan.strategy)),
        .scope = try allocator.dupe(u8, scopeModeName(plan.scope_mode)),
        .exploration_rank = ordinal + 1,
        .score = candidate_score,
        .minimality = plan.minimality,
        .files = try files.toOwnedSlice(),
        .hunks = try hunks.toOwnedSlice(),
        .trace = try trace.toOwnedSlice(),
    };
}

fn buildDraftHunk(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    surface: SurfaceSeed,
    strategy: Strategy,
    caps: Caps,
    ordinal: u32,
    abstraction_refs: []const abstractions.SupportReference,
) !PatchHunk {
    const abs_path = try std.fs.path.join(allocator, &.{ repo_root, surface.rel_path });
    defer allocator.free(abs_path);
    const body = try readOwnedFile(allocator, abs_path, MAX_SOURCE_FILE_BYTES);
    defer allocator.free(body);

    const window = try extractWindow(allocator, body, surface.line, caps.max_lines_per_hunk);
    defer window.deinit(allocator);

    const anchor_index = @min(window.lines.len, if (surface.line > window.start_line) @as(usize, surface.line - window.start_line) else 0);
    const header = try std.fmt.allocPrint(allocator, "GHOST-PATCH-CANDIDATE: draft {s} scaffold #{d}.", .{
        strategyName(strategy),
        ordinal + 1,
    });
    defer allocator.free(header);
    const comment1 = try draftCommentLine(allocator, surface.rel_path, header);
    defer allocator.free(comment1);
    const rationale = try draftRationale(allocator, surface, abstraction_refs);
    defer allocator.free(rationale);
    const comment2 = try draftCommentLine(allocator, surface.rel_path, rationale);
    defer allocator.free(comment2);

    var diff = std.ArrayList(u8).init(allocator);
    errdefer diff.deinit();
    try diff.writer().print("--- a/{s}\n+++ b/{s}\n@@ -{d},{d} +{d},{d} @@\n", .{
        surface.rel_path,
        surface.rel_path,
        window.start_line,
        window.lines.len,
        window.start_line,
        window.lines.len + 2,
    });

    for (window.lines, 0..) |line, idx| {
        if (idx == anchor_index) {
            try diff.append('+');
            try diff.appendSlice(comment1);
            try diff.append('\n');
            try diff.append('+');
            try diff.appendSlice(comment2);
            try diff.append('\n');
        }
        try diff.append(' ');
        try diff.appendSlice(line);
        try diff.append('\n');
    }
    if (anchor_index == window.lines.len) {
        try diff.append('+');
        try diff.appendSlice(comment1);
        try diff.append('\n');
        try diff.append('+');
        try diff.appendSlice(comment2);
        try diff.append('\n');
    }

    return .{
        .rel_path = try allocator.dupe(u8, surface.rel_path),
        .anchor_line = surface.line,
        .start_line = window.start_line,
        .end_line = window.end_line,
        .diff = try diff.toOwnedSlice(),
    };
}

fn appendPlanSeed(
    out: *std.ArrayList(PlanSeed),
    intel: *const code_intel.Result,
    surfaces: []const SurfaceSeed,
    option: StrategyOption,
    scope_mode: ScopeMode,
    focus_idx: u8,
    extra_idx: ?u8,
) !void {
    var seed = PlanSeed{
        .strategy = option.strategy,
        .strategy_score = option.score,
        .scope_mode = scope_mode,
    };
    seed.surface_indexes[0] = focus_idx;
    seed.surface_count = 1;
    if (extra_idx) |idx| {
        if (idx != focus_idx) {
            seed.surface_indexes[1] = idx;
            seed.surface_count = 2;
        }
    }
    seed.minimality = computeMinimalityEvidence(intel, surfaces, seed);
    try out.append(seed);
}

fn computeMinimalityEvidence(intel: *const code_intel.Result, surfaces: []const SurfaceSeed, seed: PlanSeed) MinimalityEvidence {
    _ = intel;
    _ = surfaces;
    const file_count: u32 = seed.surface_count;
    const hunk_count: u32 = seed.surface_count;
    const change_count: u32 = seed.surface_count * 2;
    const dependency_spread: u32 = if (seed.surface_count > 0) seed.surface_count - 1 else 0;
    const scope_penalty: u32 = switch (seed.scope_mode) {
        .focused => 40,
        .expanded => 180,
    };
    return .{
        .file_count = file_count,
        .change_count = change_count,
        .hunk_count = hunk_count,
        .dependency_spread = dependency_spread,
        .scope_penalty = scope_penalty,
        .total_cost = file_count * 400 + hunk_count * 120 + change_count * 40 + dependency_spread * 220 + scope_penalty,
    };
}

fn lessThanPlanSeed(ctx: []const SurfaceSeed, lhs: PlanSeed, rhs: PlanSeed) bool {
    if (lhs.minimality.total_cost != rhs.minimality.total_cost) return lhs.minimality.total_cost < rhs.minimality.total_cost;
    if (lhs.strategy_score != rhs.strategy_score) return lhs.strategy_score > rhs.strategy_score;
    if (lhs.scope_mode != rhs.scope_mode) return lhs.scope_mode == .focused;
    const lhs_surface = ctx[lhs.surface_indexes[0]];
    const rhs_surface = ctx[rhs.surface_indexes[0]];
    if (lhs_surface.line != rhs_surface.line) return lhs_surface.line < rhs_surface.line;
    if (!std.mem.eql(u8, lhs_surface.rel_path, rhs_surface.rel_path)) return std.mem.lessThan(u8, lhs_surface.rel_path, rhs_surface.rel_path);
    return @intFromEnum(lhs.strategy) < @intFromEnum(rhs.strategy);
}

fn exploratoryCandidatePoolCap(caps: Caps) usize {
    return @min(HARD_MAX_CANDIDATES, caps.max_candidates + 1);
}

fn selectPlanSeeds(allocator: std.mem.Allocator, sorted: []const PlanSeed, count_cap: usize) ![]PlanSeed {
    const count = @min(count_cap, sorted.len);
    var out = try allocator.alloc(PlanSeed, count);
    for (out, 0..) |*item, idx| item.* = sorted[idx];

    if (count >= 3 and !containsExpandedSeed(out)) {
        if (findFirstExpandedSeed(sorted)) |expanded| {
            out[count - 1] = expanded;
        }
    }
    return out;
}

fn prepareExploreToVerifyHandoff(allocator: std.mem.Allocator, caps: Caps, result: *Result) ![]usize {
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

    const proof_limit = @min(caps.max_candidates, result.candidates.len);
    var queue = std.ArrayList(usize).init(allocator);
    errdefer queue.deinit();

    var cluster_taken = try allocator.alloc(bool, clusters.items.len);
    defer allocator.free(cluster_taken);
    @memset(cluster_taken, false);

    for (result.candidates, 0..) |_, idx| {
        if (queue.items.len >= proof_limit) break;
        const cluster_idx = cluster_indexes[idx];
        if (cluster_taken[cluster_idx]) continue;
        cluster_taken[cluster_idx] = true;
        selected[idx] = true;
        try queue.append(idx);
    }
    for (result.candidates, 0..) |_, idx| {
        if (queue.items.len >= proof_limit) break;
        if (selected[idx]) continue;
        selected[idx] = true;
        try queue.append(idx);
    }

    for (result.candidates, 0..) |*candidate, idx| {
        const cluster = &clusters.items[cluster_indexes[idx]];
        if (selected[idx]) {
            cluster.proof_queue_count += 1;
        } else {
            cluster.preserved_novel_count += 1;
            try setCandidateStatus(allocator, candidate, .novel_but_unverified, "preserved as an exploratory alternative outside the bounded proof queue");
        }
    }

    result.handoff.exploration.cluster_count = @intCast(clusters.items.len);
    result.handoff.exploration.proof_queue_count = @intCast(queue.items.len);
    result.handoff.exploration.preserved_novel_count = @intCast(result.candidates.len - queue.items.len);
    result.handoff.clusters = try clusters.toOwnedSlice();
    return queue.toOwnedSlice();
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

fn findExpandedSurfaceIndex(surfaces: []const SurfaceSeed, focus_idx: usize) ?usize {
    for (surfaces, 0..) |surface, idx| {
        if (idx == focus_idx) continue;
        if (!std.mem.eql(u8, surface.rel_path, surfaces[focus_idx].rel_path)) return idx;
    }
    return null;
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
        try upsertSurface(out, .{
            .kind = .code_intel_refactor_path,
            .rel_path = item.rel_path,
            .line = item.line,
            .label = item.reason,
            .score = 255,
        }, max_items);
    }
    for (intel.overlap) |item| {
        try upsertSurface(out, .{
            .kind = .code_intel_overlap,
            .rel_path = item.rel_path,
            .line = item.line,
            .label = item.reason,
            .score = 245,
        }, max_items);
    }
    for (intel.evidence) |item| {
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
    const json = try renderJson(allocator, result);
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
        .code_intel_target => "code_intel_target",
        .code_intel_hypothesis => "code_intel_hypothesis",
        .code_intel_primary => "code_intel_primary",
        .code_intel_secondary => "code_intel_secondary",
        .code_intel_evidence => "code_intel_evidence",
        .code_intel_refactor_path => "code_intel_refactor_path",
        .code_intel_overlap => "code_intel_overlap",
        .code_intel_contradiction => "code_intel_contradiction",
        .abstraction_live => "abstraction_live",
        .abstraction_staged => "abstraction_staged",
        .execution_evidence => "execution_evidence",
        .execution_contradiction => "execution_contradiction",
        .refinement_hypothesis => "refinement_hypothesis",
    };
}

fn validationStateName(state: ValidationState) []const u8 {
    return switch (state) {
        .draft_unvalidated => "draft_unvalidated",
        .build_failed => "build_failed",
        .test_failed => "test_failed",
        .proof_rejected => "proof_rejected",
        .verified_supported => "verified_supported",
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
    candidate.status_reason = try allocator.dupe(u8, reason);
    if (status == .rejected) {
        candidate.rejection_reason = try allocator.dupe(u8, reason);
    }
}

fn setCandidateStatusOwned(allocator: std.mem.Allocator, candidate: *Candidate, status: CandidateStatus, reason: []u8) !void {
    try clearCandidateRejectionReason(allocator, candidate);
    clearCandidateStatusReason(allocator, candidate);
    candidate.status = status;
    candidate.status_reason = reason;
    if (status == .rejected) {
        candidate.rejection_reason = try allocator.dupe(u8, reason);
    }
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
        if (candidate.validation_state == .verified_supported or candidate.validation_state == .proof_rejected) {
            result.handoff.proof.verified_survivor_count += 1;
        }
    }
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
    const handle = try sys.openForWrite(allocator, abs_path);
    defer sys.closeFile(handle);
    try sys.writeAll(handle, bytes);
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
        ",\"queuedCandidateCount\":{d},\"verifiedSurvivorCount\":{d},\"rejectedCount\":{d},\"unresolvedCount\":{d},\"supportedCount\":{d},\"novelButUnverifiedCount\":{d}",
        .{
            trace.queued_candidate_count,
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
    try writer.writeAll(",\"refinements\":");
    try writeRefinementTraceArray(writer, trace.refinements);
    if (trace.proof_reason) |reason| try writeOptionalStringField(writer, "proofReason", reason);
    try writer.writeAll("}");
}

fn writeVerificationStep(writer: anytype, step: VerificationStep) !void {
    try writer.writeAll("{");
    try writeJsonFieldString(writer, "status", verificationStepStateName(step.state), true);
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

fn writeStringArray(writer: anytype, items: []const []const u8) !void {
    try writer.writeAll("[");
    for (items, 0..) |item, idx| {
        if (idx != 0) try writer.writeAll(",");
        try writeJsonString(writer, item);
    }
    try writer.writeAll("]");
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
