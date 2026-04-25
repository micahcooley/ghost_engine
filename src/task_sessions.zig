const std = @import("std");
const code_intel = @import("code_intel.zig");
const compute_budget = @import("compute_budget.zig");
const mc = @import("inference.zig");
const external_evidence = @import("external_evidence.zig");
const panic_dump = @import("panic_dump.zig");
const patch_candidates = @import("patch_candidates.zig");
const shards = @import("shards.zig");
const sys = @import("sys.zig");
const task_intent = @import("task_intent.zig");
const technical_drafts = @import("technical_drafts.zig");

pub const FORMAT_VERSION = "ghost_task_session_v1";
pub const MAX_HISTORY = 16;
pub const MAX_CONTEXT_REFS = 16;
pub const MAX_CONTEXT_ABSTRACTIONS = 4;
pub const MAX_CONTEXT_CORPUS = 4;
pub const MAX_TASK_FILE_BYTES = 256 * 1024;
pub const MAX_ARTIFACT_FILE_BYTES = 512 * 1024;

pub const Status = enum {
    planned,
    running,
    blocked,
    unresolved,
    verified_complete,
    failed,
};

pub const Workflow = enum {
    code_intel,
    patch_candidates,
};

pub const SubgoalState = enum {
    pending,
    running,
    complete,
    blocked,
    unresolved,
    failed,
};

pub const ContextKind = enum {
    shard,
    code_intel_result,
    patch_candidates_result,
    external_evidence_result,
    technical_draft,
    panic_dump,
    abstraction,
    corpus,
};

pub const ActionKind = enum {
    task_created,
    task_resumed,
    task_reopened,
    intent_grounded,
    evidence_requested,
    evidence_fetched,
    evidence_ingested,
    evidence_conflicting,
    evidence_insufficient,
    support_collected,
    patch_verified,
    task_blocked,
    task_unresolved,
    task_verified_complete,
    task_failed,
    checkpoint_saved,
};

pub const IntentSnapshot = struct {
    status: task_intent.ParseStatus,
    action: task_intent.Action,
    output_mode: task_intent.OutputMode,
    target_kind: task_intent.TargetKind,
    target_spec: ?[]u8 = null,
    other_target_kind: task_intent.TargetKind = .none,
    other_target_spec: ?[]u8 = null,
    dispatch_flow: task_intent.FlowKind = .none,
    query_kind: ?code_intel.QueryKind = null,
    reasoning_mode: mc.ReasoningMode = .proof,
    executable: bool = false,
    detail: ?[]u8 = null,

    fn deinit(self: *IntentSnapshot, allocator: std.mem.Allocator) void {
        if (self.target_spec) |value| allocator.free(value);
        if (self.other_target_spec) |value| allocator.free(value);
        if (self.detail) |value| allocator.free(value);
        self.* = undefined;
    }

    fn clone(self: IntentSnapshot, allocator: std.mem.Allocator) !IntentSnapshot {
        return .{
            .status = self.status,
            .action = self.action,
            .output_mode = self.output_mode,
            .target_kind = self.target_kind,
            .target_spec = if (self.target_spec) |value| try allocator.dupe(u8, value) else null,
            .other_target_kind = self.other_target_kind,
            .other_target_spec = if (self.other_target_spec) |value| try allocator.dupe(u8, value) else null,
            .dispatch_flow = self.dispatch_flow,
            .query_kind = self.query_kind,
            .reasoning_mode = self.reasoning_mode,
            .executable = self.executable,
            .detail = if (self.detail) |value| try allocator.dupe(u8, value) else null,
        };
    }
};

pub const Subgoal = struct {
    id: []u8,
    title: []u8,
    state: SubgoalState = .pending,
    detail: ?[]u8 = null,

    fn deinit(self: *Subgoal, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.title);
        if (self.detail) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub const ContextRef = struct {
    kind: ContextKind,
    label: []u8,
    value: []u8,
    detail: ?[]u8 = null,

    fn deinit(self: *ContextRef, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
        allocator.free(self.value);
        if (self.detail) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub const SupportSummary = struct {
    permission: code_intel.Status = .unresolved,
    minimum_met: bool = false,
    node_count: u32 = 0,
    edge_count: u32 = 0,
    evidence_count: u32 = 0,
    abstraction_ref_count: u32 = 0,
    pack_considered_count: u32 = 0,
    pack_activated_count: u32 = 0,
    pack_skipped_count: u32 = 0,
    pack_suppressed_count: u32 = 0,
    pack_conflict_refused_count: u32 = 0,
    pack_trust_blocked_count: u32 = 0,
    pack_stale_blocked_count: u32 = 0,
    pack_candidate_surface_count: u32 = 0,
    verified_candidate_count: u32 = 0,
    build_passed: u32 = 0,
    build_attempted: u32 = 0,
    test_passed: u32 = 0,
    test_attempted: u32 = 0,
    runtime_passed: u32 = 0,
    runtime_attempted: u32 = 0,
    repair_recovered_count: u32 = 0,
    repair_failed_count: u32 = 0,
};

pub const HistoryEntry = struct {
    index: u32,
    step_index: u32,
    action: ActionKind,
    state: Status,
    summary: []u8,
    result_path: ?[]u8 = null,
    draft_path: ?[]u8 = null,
    panic_dump_path: ?[]u8 = null,
    stop_reason: ?mc.StopReason = null,
    support_permission: ?code_intel.Status = null,
    support_minimum_met: bool = false,

    fn deinit(self: *HistoryEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.summary);
        if (self.result_path) |value| allocator.free(value);
        if (self.draft_path) |value| allocator.free(value);
        if (self.panic_dump_path) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub const Session = struct {
    allocator: std.mem.Allocator,
    task_id: []u8,
    session_path: []u8,
    repo_root: []u8,
    shard_kind: shards.Kind,
    shard_id: []u8,
    shard_root: []u8,
    status: Status = .planned,
    workflow: Workflow = .code_intel,
    originating_intent: []u8,
    intent: IntentSnapshot,
    current_objective: []u8,
    chosen_reasoning_mode: mc.ReasoningMode = .proof,
    compute_budget_request: compute_budget.Request = .{},
    effective_budget: compute_budget.Effective = compute_budget.resolve(.{}),
    query_kind: ?code_intel.QueryKind = null,
    target: ?[]u8 = null,
    other_target: ?[]u8 = null,
    evidence_request: ?external_evidence.Request = null,
    evidence_state: external_evidence.AcquisitionState = .not_needed,
    next_subgoal_index: u32 = 0,
    resume_count: u32 = 0,
    status_detail: ?[]u8 = null,
    evidence_detail: ?[]u8 = null,
    latest_support: ?SupportSummary = null,
    last_code_intel_result_path: ?[]u8 = null,
    last_patch_candidates_result_path: ?[]u8 = null,
    last_external_evidence_result_path: ?[]u8 = null,
    last_draft_path: ?[]u8 = null,
    last_panic_dump_path: ?[]u8 = null,
    subgoals: []Subgoal = &.{},
    relevant_context: []ContextRef = &.{},
    history: []HistoryEntry = &.{},
    profile: Profile = .{},

    pub fn deinit(self: *Session) void {
        self.allocator.free(self.task_id);
        self.allocator.free(self.session_path);
        self.allocator.free(self.repo_root);
        self.allocator.free(self.shard_id);
        self.allocator.free(self.shard_root);
        self.allocator.free(self.originating_intent);
        self.intent.deinit(self.allocator);
        self.allocator.free(self.current_objective);
        if (self.target) |value| self.allocator.free(value);
        if (self.other_target) |value| self.allocator.free(value);
        if (self.evidence_request) |*value| value.deinit(self.allocator);
        if (self.status_detail) |value| self.allocator.free(value);
        if (self.evidence_detail) |value| self.allocator.free(value);
        if (self.last_code_intel_result_path) |value| self.allocator.free(value);
        if (self.last_patch_candidates_result_path) |value| self.allocator.free(value);
        if (self.last_external_evidence_result_path) |value| self.allocator.free(value);
        if (self.last_draft_path) |value| self.allocator.free(value);
        if (self.last_panic_dump_path) |value| self.allocator.free(value);
        for (self.subgoals) |*item| item.deinit(self.allocator);
        self.allocator.free(self.subgoals);
        for (self.relevant_context) |*item| item.deinit(self.allocator);
        self.allocator.free(self.relevant_context);
        for (self.history) |*item| item.deinit(self.allocator);
        self.allocator.free(self.history);
        self.* = undefined;
    }
};

pub const Profile = struct {
    artifact_write_ms: u64 = 0,
    artifact_write_count: u32 = 0,
    session_save_ms: u64 = 0,
    session_save_count: u32 = 0,
    code_intel_run_ms: u64 = 0,
    patch_run_ms: u64 = 0,
};

pub const CreateOptions = struct {
    repo_root: []const u8,
    project_shard: ?[]const u8 = null,
    intent_text: []const u8,
    task_id: ?[]const u8 = null,
    evidence_request: ?external_evidence.RequestInput = null,
    compute_budget_request: compute_budget.Request = .{},
};

pub const RunOptions = struct {
    repo_root: []const u8,
    project_shard: ?[]const u8 = null,
    intent_text: []const u8,
    task_id: ?[]const u8 = null,
    evidence_request: ?external_evidence.RequestInput = null,
    compute_budget_request: compute_budget.Request = .{},
    max_steps: u32 = 3,
    reopen: bool = false,
    emit_panic_dump: bool = true,
};

pub const ResumeOptions = struct {
    project_shard: ?[]const u8 = null,
    task_id: []const u8,
    evidence_request: ?external_evidence.RequestInput = null,
    compute_budget_request: ?compute_budget.Request = null,
    max_steps: u32 = 3,
    reopen: bool = false,
    emit_panic_dump: bool = true,
};

pub fn create(allocator: std.mem.Allocator, options: CreateOptions) !Session {
    var shard_metadata = try resolveOperatorShardMetadata(allocator, options.project_shard);
    defer shard_metadata.deinit();

    var paths = try shards.resolvePaths(allocator, shard_metadata.metadata);
    defer paths.deinit();

    const task_id = if (options.task_id) |raw_id|
        try sanitizeTaskId(allocator, raw_id)
    else
        try autoTaskId(allocator, options.repo_root, shard_metadata.metadata.kind, shard_metadata.metadata.id, options.intent_text);
    errdefer allocator.free(task_id);

    const session_path = try sessionPath(allocator, &paths, task_id);
    errdefer allocator.free(session_path);

    var snapshot = try snapshotIntent(allocator, options.intent_text);
    errdefer snapshot.deinit(allocator);

    const workflow = workflowFromIntent(snapshot);
    const subgoals = try initSubgoals(allocator, workflow, snapshot.status == .grounded);
    errdefer {
        for (subgoals) |*item| item.deinit(allocator);
        allocator.free(subgoals);
    }

    const current_objective = try allocator.dupe(u8, subgoals[0].title);
    errdefer allocator.free(current_objective);

    const target = if (snapshot.target_spec) |value| try allocator.dupe(u8, value) else null;
    errdefer if (target) |value| allocator.free(value);
    const other_target = if (snapshot.other_target_spec) |value| try allocator.dupe(u8, value) else null;
    errdefer if (other_target) |value| allocator.free(value);
    var evidence_request = if (options.evidence_request) |value|
        try external_evidence.Request.initOwned(allocator, value)
    else
        null;
    errdefer if (evidence_request) |*value| value.deinit(allocator);

    var session = Session{
        .allocator = allocator,
        .task_id = task_id,
        .session_path = session_path,
        .repo_root = try allocator.dupe(u8, options.repo_root),
        .shard_kind = shard_metadata.metadata.kind,
        .shard_id = try allocator.dupe(u8, shard_metadata.metadata.id),
        .shard_root = try allocator.dupe(u8, paths.root_abs_path),
        .workflow = workflow,
        .originating_intent = try allocator.dupe(u8, options.intent_text),
        .intent = snapshot,
        .current_objective = current_objective,
        .chosen_reasoning_mode = snapshot.reasoning_mode,
        .compute_budget_request = options.compute_budget_request,
        .effective_budget = compute_budget.resolve(options.compute_budget_request),
        .query_kind = snapshot.query_kind,
        .target = target,
        .other_target = other_target,
        .evidence_request = evidence_request,
        .evidence_state = if (evidence_request != null) .requested else .not_needed,
        .subgoals = subgoals,
        .relevant_context = &.{},
        .history = &.{},
    };
    errdefer session.deinit();

    try upsertContextRef(&session, .{
        .kind = .shard,
        .label = try allocator.dupe(u8, "shard"),
        .value = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ @tagName(session.shard_kind), session.shard_id }),
        .detail = try allocator.dupe(u8, session.shard_root),
    });
    try appendHistory(&session, .{
        .index = 0,
        .step_index = 0,
        .action = .task_created,
        .state = .planned,
        .summary = try std.fmt.allocPrint(allocator, "created task for intent: {s}", .{session.originating_intent}),
    });
    try save(&session, &paths);
    return session;
}

pub fn load(allocator: std.mem.Allocator, project_shard: ?[]const u8, task_id_text: []const u8) !Session {
    var shard_metadata = try resolveOperatorShardMetadata(allocator, project_shard);
    defer shard_metadata.deinit();

    var paths = try shards.resolvePaths(allocator, shard_metadata.metadata);
    defer paths.deinit();

    const task_id = try sanitizeTaskId(allocator, task_id_text);
    defer allocator.free(task_id);

    const file_path = try sessionPath(allocator, &paths, task_id);
    defer allocator.free(file_path);

    const bytes = try readOwnedFile(allocator, file_path, MAX_TASK_FILE_BYTES);
    defer allocator.free(bytes);

    const DiskSession = struct {
        formatVersion: []const u8,
        taskId: []const u8,
        sessionPath: []const u8,
        repoRoot: []const u8,
        shardKind: shards.Kind,
        shardId: []const u8,
        shardRoot: []const u8,
        status: Status,
        workflow: Workflow,
        originatingIntent: []const u8,
        intent: IntentSnapshot,
        currentObjective: []const u8,
        chosenReasoningMode: mc.ReasoningMode,
        computeBudgetRequest: compute_budget.Request = .{},
        effectiveBudget: compute_budget.Effective = compute_budget.resolve(.{}),
        queryKind: ?code_intel.QueryKind = null,
        target: ?[]const u8 = null,
        otherTarget: ?[]const u8 = null,
        evidenceRequest: ?external_evidence.Request = null,
        evidenceState: external_evidence.AcquisitionState = .not_needed,
        nextSubgoalIndex: u32,
        resumeCount: u32,
        statusDetail: ?[]const u8 = null,
        evidenceDetail: ?[]const u8 = null,
        latestSupport: ?SupportSummary = null,
        lastCodeIntelResultPath: ?[]const u8 = null,
        lastPatchCandidatesResultPath: ?[]const u8 = null,
        lastExternalEvidenceResultPath: ?[]const u8 = null,
        lastDraftPath: ?[]const u8 = null,
        lastPanicDumpPath: ?[]const u8 = null,
        subgoals: []const Subgoal,
        relevantContext: []const ContextRef,
        history: []const HistoryEntry,
    };

    const parsed = try std.json.parseFromSlice(DiskSession, allocator, bytes, .{});
    defer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.formatVersion, FORMAT_VERSION)) return error.InvalidTaskSession;

    var session = Session{
        .allocator = allocator,
        .task_id = try allocator.dupe(u8, parsed.value.taskId),
        .session_path = try allocator.dupe(u8, parsed.value.sessionPath),
        .repo_root = try allocator.dupe(u8, parsed.value.repoRoot),
        .shard_kind = parsed.value.shardKind,
        .shard_id = try allocator.dupe(u8, parsed.value.shardId),
        .shard_root = try allocator.dupe(u8, parsed.value.shardRoot),
        .status = parsed.value.status,
        .workflow = parsed.value.workflow,
        .originating_intent = try allocator.dupe(u8, parsed.value.originatingIntent),
        .intent = try parsed.value.intent.clone(allocator),
        .current_objective = try allocator.dupe(u8, parsed.value.currentObjective),
        .chosen_reasoning_mode = parsed.value.chosenReasoningMode,
        .compute_budget_request = parsed.value.computeBudgetRequest,
        .effective_budget = parsed.value.effectiveBudget,
        .query_kind = parsed.value.queryKind,
        .target = if (parsed.value.target) |value| try allocator.dupe(u8, value) else null,
        .other_target = if (parsed.value.otherTarget) |value| try allocator.dupe(u8, value) else null,
        .evidence_request = if (parsed.value.evidenceRequest) |value| try value.clone(allocator) else null,
        .evidence_state = parsed.value.evidenceState,
        .next_subgoal_index = parsed.value.nextSubgoalIndex,
        .resume_count = parsed.value.resumeCount,
        .status_detail = if (parsed.value.statusDetail) |value| try allocator.dupe(u8, value) else null,
        .evidence_detail = if (parsed.value.evidenceDetail) |value| try allocator.dupe(u8, value) else null,
        .latest_support = parsed.value.latestSupport,
        .last_code_intel_result_path = if (parsed.value.lastCodeIntelResultPath) |value| try allocator.dupe(u8, value) else null,
        .last_patch_candidates_result_path = if (parsed.value.lastPatchCandidatesResultPath) |value| try allocator.dupe(u8, value) else null,
        .last_external_evidence_result_path = if (parsed.value.lastExternalEvidenceResultPath) |value| try allocator.dupe(u8, value) else null,
        .last_draft_path = if (parsed.value.lastDraftPath) |value| try allocator.dupe(u8, value) else null,
        .last_panic_dump_path = if (parsed.value.lastPanicDumpPath) |value| try allocator.dupe(u8, value) else null,
        .subgoals = try cloneSubgoals(allocator, parsed.value.subgoals),
        .relevant_context = try cloneContextRefs(allocator, parsed.value.relevantContext),
        .history = try cloneHistory(allocator, parsed.value.history),
    };
    errdefer session.deinit();
    return session;
}

pub fn run(allocator: std.mem.Allocator, options: RunOptions) !Session {
    var shard_metadata = try resolveOperatorShardMetadata(allocator, options.project_shard);
    defer shard_metadata.deinit();

    var paths = try shards.resolvePaths(allocator, shard_metadata.metadata);
    defer paths.deinit();

    const resolved_task_id = if (options.task_id) |raw_id|
        try sanitizeTaskId(allocator, raw_id)
    else
        try autoTaskId(allocator, options.repo_root, shard_metadata.metadata.kind, shard_metadata.metadata.id, options.intent_text);
    defer allocator.free(resolved_task_id);

    const file_path = try sessionPath(allocator, &paths, resolved_task_id);
    defer allocator.free(file_path);

    var session = if (fileExists(file_path))
        try load(allocator, options.project_shard, resolved_task_id)
    else
        try create(allocator, .{
            .repo_root = options.repo_root,
            .project_shard = options.project_shard,
            .intent_text = options.intent_text,
            .task_id = resolved_task_id,
            .evidence_request = options.evidence_request,
            .compute_budget_request = options.compute_budget_request,
        });
    errdefer session.deinit();

    if (options.reopen and isReopenable(session.status)) {
        try reopenSession(&session);
    }
    try advanceLoop(&session, &paths, options.max_steps, options.emit_panic_dump);
    return session;
}

pub fn resumeTask(allocator: std.mem.Allocator, options: ResumeOptions) !Session {
    var shard_metadata = try resolveOperatorShardMetadata(allocator, options.project_shard);
    defer shard_metadata.deinit();

    var paths = try shards.resolvePaths(allocator, shard_metadata.metadata);
    defer paths.deinit();

    var session = try load(allocator, options.project_shard, options.task_id);
    errdefer session.deinit();

    if (options.compute_budget_request) |request| {
        session.compute_budget_request = request;
        session.effective_budget = compute_budget.resolve(request);
    }
    if (options.evidence_request) |request| {
        try replaceEvidenceRequest(&session, request);
    }
    if (options.reopen and isReopenable(session.status)) {
        try reopenSession(&session);
    }
    try appendHistory(&session, .{
        .index = nextHistoryIndex(&session),
        .step_index = session.next_subgoal_index,
        .action = .task_resumed,
        .state = session.status,
        .summary = try std.fmt.allocPrint(allocator, "resuming task at subgoal {d}", .{session.next_subgoal_index}),
    });
    try advanceLoop(&session, &paths, options.max_steps, options.emit_panic_dump);
    return session;
}

pub fn save(session: *const Session, paths: *const shards.Paths) !void {
    _ = paths;
    const started = sys.getMilliTick();
    const rendered = try renderJson(session.allocator, session);
    defer session.allocator.free(rendered);
    try sys.makePath(session.allocator, std.fs.path.dirname(session.session_path).?);
    try writeOwnedFile(session.allocator, session.session_path, rendered);
    const mutable = @constCast(session);
    mutable.profile.session_save_ms += sys.getMilliTick() - started;
    mutable.profile.session_save_count += 1;
}

pub fn renderJson(allocator: std.mem.Allocator, session: *const Session) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    try std.json.stringify(.{
        .formatVersion = FORMAT_VERSION,
        .taskId = session.task_id,
        .sessionPath = session.session_path,
        .repoRoot = session.repo_root,
        .shardKind = session.shard_kind,
        .shardId = session.shard_id,
        .shardRoot = session.shard_root,
        .status = session.status,
        .workflow = session.workflow,
        .originatingIntent = session.originating_intent,
        .intent = session.intent,
        .currentObjective = session.current_objective,
        .chosenReasoningMode = session.chosen_reasoning_mode,
        .computeBudgetRequest = session.compute_budget_request,
        .effectiveBudget = session.effective_budget,
        .queryKind = session.query_kind,
        .target = session.target,
        .otherTarget = session.other_target,
        .evidenceRequest = session.evidence_request,
        .evidenceState = session.evidence_state,
        .nextSubgoalIndex = session.next_subgoal_index,
        .resumeCount = session.resume_count,
        .statusDetail = session.status_detail,
        .evidenceDetail = session.evidence_detail,
        .latestSupport = session.latest_support,
        .lastCodeIntelResultPath = session.last_code_intel_result_path,
        .lastPatchCandidatesResultPath = session.last_patch_candidates_result_path,
        .lastExternalEvidenceResultPath = session.last_external_evidence_result_path,
        .lastDraftPath = session.last_draft_path,
        .lastPanicDumpPath = session.last_panic_dump_path,
        .subgoals = session.subgoals,
        .relevantContext = session.relevant_context,
        .history = session.history,
    }, .{}, out.writer());
    return out.toOwnedSlice();
}

pub fn renderSummary(allocator: std.mem.Allocator, session: *const Session) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const writer = out.writer();
    const show_cmd = try taskOperatorCommand(allocator, session, "show");
    defer allocator.free(show_cmd);
    const support_cmd = try taskOperatorCommand(allocator, session, "support");
    defer allocator.free(support_cmd);
    const replay_cmd = if (session.last_panic_dump_path != null)
        try taskOperatorCommand(allocator, session, "replay")
    else
        null;
    defer if (replay_cmd) |value| allocator.free(value);
    const resume_cmd = if (session.status == .blocked or session.status == .unresolved)
        try taskOperatorResumeCommand(allocator, session)
    else
        null;
    defer if (resume_cmd) |value| allocator.free(value);

    try writer.print(
        "task={s}\nstatus={s}\nworkflow={s}\nobjective={s}\nrepo={s}\nshard={s}/{s}\nstate_file={s}\n",
        .{
            session.task_id,
            @tagName(session.status),
            @tagName(session.workflow),
            session.current_objective,
            session.repo_root,
            @tagName(session.shard_kind),
            session.shard_id,
            session.session_path,
        },
    );
    if (session.status_detail) |detail| try writer.print("detail={s}\n", .{detail});
    try writer.print(
        "compute_tier requested={s} effective={s} branches={d} proof_queue={d} repairs={d} packs={d}/{d}\n",
        .{
            compute_budget.tierName(session.compute_budget_request.tier),
            compute_budget.tierName(session.effective_budget.effective_tier),
            session.effective_budget.max_branches,
            session.effective_budget.max_proof_queue_size,
            session.effective_budget.max_repairs,
            session.effective_budget.max_packs_activated,
            session.effective_budget.max_mounted_packs_considered,
        },
    );
    try writer.print("evidence_state={s}\n", .{external_evidence.acquisitionStateName(session.evidence_state)});
    if (session.evidence_detail) |detail| try writer.print("evidence_detail={s}\n", .{detail});
    if (session.latest_support) |support| {
        try writer.print(
            "support permission={s} minimum_met={s} nodes={d} edges={d} evidence={d} abstractions={d}\n",
            .{
                @tagName(support.permission),
                if (support.minimum_met) "true" else "false",
                support.node_count,
                support.edge_count,
                support.evidence_count,
                support.abstraction_ref_count,
            },
        );
        try writer.print(
            "verification build={d}/{d} test={d}/{d} runtime={d}/{d} repairs={d}/{d}\n",
            .{
                support.build_passed,
                support.build_attempted,
                support.test_passed,
                support.test_attempted,
                support.runtime_passed,
                support.runtime_attempted,
                support.repair_recovered_count,
                support.repair_failed_count,
            },
        );
        try writer.print(
            "packs considered={d} activated={d} skipped={d} suppressed={d} conflict_refused={d} trust_blocked={d} stale_blocked={d} candidate_surfaces={d}\n",
            .{
                support.pack_considered_count,
                support.pack_activated_count,
                support.pack_skipped_count,
                support.pack_suppressed_count,
                support.pack_conflict_refused_count,
                support.pack_trust_blocked_count,
                support.pack_stale_blocked_count,
                support.pack_candidate_surface_count,
            },
        );
    }
    if (session.last_code_intel_result_path) |path| try writer.print("code_intel_result={s}\n", .{path});
    if (session.last_patch_candidates_result_path) |path| try writer.print("patch_result={s}\n", .{path});
    if (session.last_external_evidence_result_path) |path| try writer.print("external_evidence_result={s}\n", .{path});
    if (session.last_draft_path) |path| try writer.print("draft={s}\n", .{path});
    if (session.last_panic_dump_path) |path| try writer.print("panic_dump={s}\n", .{path});
    try writer.print("show_cmd={s}\n", .{show_cmd});
    try writer.print("support_cmd={s}\n", .{support_cmd});
    if (resume_cmd) |value| try writer.print("resume_cmd={s}\n", .{value});
    if (replay_cmd) |value| try writer.print("replay_cmd={s}\n", .{value});
    try writer.writeAll("\n[subgoals]\n");
    for (session.subgoals, 0..) |item, idx| {
        try writer.print("{d}. {s} [{s}]\n", .{ idx + 1, item.title, @tagName(item.state) });
        if (item.detail) |detail| try writer.print("   detail={s}\n", .{detail});
    }
    try writer.writeAll("\n[history]\n");
    for (session.history) |item| {
        try writer.print("- #{d} step={d} action={s} state={s} summary={s}\n", .{
            item.index,
            item.step_index,
            @tagName(item.action),
            @tagName(item.state),
            item.summary,
        });
    }
    return out.toOwnedSlice();
}

fn taskOperatorCommand(allocator: std.mem.Allocator, session: *const Session, command: []const u8) ![]u8 {
    const shard_arg = if (session.shard_kind == .project)
        try std.fmt.allocPrint(allocator, " --project-shard={s}", .{session.shard_id})
    else
        try allocator.dupe(u8, "");
    defer allocator.free(shard_arg);
    return std.fmt.allocPrint(allocator, "ghost_task_operator {s}{s} --task-id={s}", .{ command, shard_arg, session.task_id });
}

fn taskOperatorResumeCommand(allocator: std.mem.Allocator, session: *const Session) ![]u8 {
    const shard_arg = if (session.shard_kind == .project)
        try std.fmt.allocPrint(allocator, " --project-shard={s}", .{session.shard_id})
    else
        try allocator.dupe(u8, "");
    defer allocator.free(shard_arg);
    return std.fmt.allocPrint(allocator, "ghost_task_operator resume{s} --task-id={s} --reopen", .{ shard_arg, session.task_id });
}

fn resolveOperatorShardMetadata(allocator: std.mem.Allocator, project_shard: ?[]const u8) !shards.OwnedMetadata {
    if (project_shard) |value| return shards.resolveProjectMetadata(allocator, value);
    return shards.resolveDefaultProjectMetadata(allocator);
}

fn workflowFromIntent(intent: IntentSnapshot) Workflow {
    return switch (intent.dispatch_flow) {
        .patch_candidates => .patch_candidates,
        else => .code_intel,
    };
}

fn snapshotIntent(allocator: std.mem.Allocator, intent_text: []const u8) !IntentSnapshot {
    var parsed = try task_intent.parse(allocator, intent_text, .{});
    defer parsed.deinit();

    return .{
        .status = parsed.status,
        .action = parsed.action,
        .output_mode = parsed.output_mode,
        .target_kind = parsed.target.kind,
        .target_spec = if (parsed.target.spec) |value| try allocator.dupe(u8, value) else null,
        .other_target_kind = parsed.other_target.kind,
        .other_target_spec = if (parsed.other_target.spec) |value| try allocator.dupe(u8, value) else null,
        .dispatch_flow = parsed.dispatch.flow,
        .query_kind = if (parsed.dispatch.query_kind) |kind| translateIntentQueryKind(kind) else null,
        .reasoning_mode = parsed.dispatch.reasoning_mode,
        .executable = parsed.dispatch.executable,
        .detail = if (parsed.unresolved_detail) |value| try allocator.dupe(u8, value) else null,
    };
}

fn translateIntentQueryKind(kind: task_intent.QueryKind) code_intel.QueryKind {
    return switch (kind) {
        .impact => .impact,
        .breaks_if => .breaks_if,
        .contradicts => .contradicts,
    };
}

fn initSubgoals(allocator: std.mem.Allocator, workflow: Workflow, grounded: bool) ![]Subgoal {
    _ = grounded;
    return switch (workflow) {
        .code_intel => blk: {
            const out = try allocator.alloc(Subgoal, 2);
            errdefer allocator.free(out);
            out[0] = .{
                .id = try allocator.dupe(u8, "ground_request"),
                .title = try allocator.dupe(u8, "Ground Request"),
            };
            out[1] = .{
                .id = try allocator.dupe(u8, "collect_support"),
                .title = try allocator.dupe(u8, "Collect Support"),
            };
            break :blk out;
        },
        .patch_candidates => blk: {
            const out = try allocator.alloc(Subgoal, 3);
            errdefer allocator.free(out);
            out[0] = .{
                .id = try allocator.dupe(u8, "ground_request"),
                .title = try allocator.dupe(u8, "Ground Request"),
            };
            out[1] = .{
                .id = try allocator.dupe(u8, "collect_support"),
                .title = try allocator.dupe(u8, "Collect Support"),
            };
            out[2] = .{
                .id = try allocator.dupe(u8, "synthesize_and_verify_patch"),
                .title = try allocator.dupe(u8, "Synthesize And Verify Patch"),
            };
            break :blk out;
        },
    };
}

fn advanceLoop(session: *Session, paths: *const shards.Paths, max_steps: u32, emit_panic_dump: bool) !void {
    if (session.status == .planned) session.status = .running;
    var steps: u32 = 0;
    while (steps < max_steps and !isTerminal(session.status)) : (steps += 1) {
        try executeCurrentStep(session, paths, emit_panic_dump);
        try appendHistory(session, .{
            .index = nextHistoryIndex(session),
            .step_index = session.next_subgoal_index,
            .action = .checkpoint_saved,
            .state = session.status,
            .summary = try std.fmt.allocPrint(session.allocator, "checkpointed task after {d} step(s)", .{steps + 1}),
            .result_path = if (session.last_patch_candidates_result_path) |path| try session.allocator.dupe(u8, path) else if (session.last_code_intel_result_path) |path| try session.allocator.dupe(u8, path) else null,
            .draft_path = if (session.last_draft_path) |path| try session.allocator.dupe(u8, path) else null,
            .panic_dump_path = if (session.last_panic_dump_path) |path| try session.allocator.dupe(u8, path) else null,
            .support_permission = if (session.latest_support) |support| support.permission else null,
            .support_minimum_met = if (session.latest_support) |support| support.minimum_met else false,
        });
        try save(session, paths);
    }
}

fn executeCurrentStep(session: *Session, paths: *const shards.Paths, emit_panic_dump: bool) !void {
    if (session.next_subgoal_index >= session.subgoals.len) {
        if (session.status == .running) {
            session.status = .verified_complete;
            try replaceOwnedText(session.allocator, &session.current_objective, "task reached terminal state");
        }
        return;
    }

    switch (session.next_subgoal_index) {
        0 => try stepGroundIntent(session),
        1 => try stepCollectSupport(session, paths, emit_panic_dump),
        2 => try stepPatchVerification(session, paths, emit_panic_dump),
        else => {
            session.status = .failed;
            try setStatusDetail(session, "unknown task step index");
            try setSubgoalState(session, session.next_subgoal_index, .failed, "task step index was outside the bounded operator loop");
            try appendHistory(session, .{
                .index = nextHistoryIndex(session),
                .step_index = session.next_subgoal_index,
                .action = .task_failed,
                .state = session.status,
                .summary = try session.allocator.dupe(u8, "task operator encountered an unknown step"),
            });
        },
    }
}

fn stepGroundIntent(session: *Session) !void {
    try setSubgoalState(session, session.next_subgoal_index, .running, null);
    if (session.intent.status != .grounded or session.intent.query_kind == null or session.intent.target_spec == null or session.intent.dispatch_flow == .none) {
        session.status = .unresolved;
        const detail = session.intent.detail orelse "recorded intent did not ground to a supported deterministic workflow";
        try setStatusDetail(session, detail);
        try setSubgoalState(session, session.next_subgoal_index, .unresolved, detail);
        try replaceOwnedText(session.allocator, &session.current_objective, detail);
        try appendHistory(session, .{
            .index = nextHistoryIndex(session),
            .step_index = session.next_subgoal_index,
            .action = .task_unresolved,
            .state = session.status,
            .summary = try std.fmt.allocPrint(session.allocator, "intent grounding stopped: {s}", .{detail}),
        });
        return;
    }

    session.status = .running;
    session.chosen_reasoning_mode = session.intent.reasoning_mode;
    session.query_kind = session.intent.query_kind;
    try replaceOptionalOwnedText(session.allocator, &session.target, session.intent.target_spec);
    try replaceOptionalOwnedText(session.allocator, &session.other_target, session.intent.other_target_spec);
    try clearStatusDetail(session);
    try setSubgoalState(session, session.next_subgoal_index, .complete, null);
    session.next_subgoal_index += 1;
    try replaceOwnedText(session.allocator, &session.current_objective, session.subgoals[session.next_subgoal_index].title);
    try appendHistory(session, .{
        .index = nextHistoryIndex(session),
        .step_index = 0,
        .action = .intent_grounded,
        .state = session.status,
        .summary = try std.fmt.allocPrint(
            session.allocator,
            "grounded intent as {s}/{s} targeting {s}",
            .{
                @tagName(session.workflow),
                @tagName(session.query_kind.?),
                session.target.?,
            },
        ),
    });
}

fn stepCollectSupport(session: *Session, paths: *const shards.Paths, emit_panic_dump: bool) !void {
    try setSubgoalState(session, session.next_subgoal_index, .running, null);
    var intent = try reparseRecordedIntent(session);
    defer intent.deinit();

    var result = runCodeIntelForSession(session, paths, &intent) catch |err| switch (err) {
        error.TaskOperatorHandledFailure => return,
        else => return err,
    };
    defer result.deinit();

    const draft_type: technical_drafts.DraftType = if (session.workflow == .patch_candidates) .refactor_plan else .proof_backed_explanation;
    var persisted = try persistCodeIntelArtifacts(session, paths, &result, draft_type);
    defer persisted.deinit(session.allocator);

    if (!proofBackedCodeIntelComplete(&result)) {
        const initial_detail = result.unresolved_detail orelse result.support_graph.unresolved_reason orelse "support was insufficient for proof-backed progress";
        if (session.evidence_request != null and session.evidence_state == .requested and paths.metadata.kind == .project) {
            try setEvidenceDetail(session, initial_detail);
            try appendHistory(session, .{
                .index = nextHistoryIndex(session),
                .step_index = session.next_subgoal_index,
                .action = .evidence_requested,
                .state = .running,
                .summary = try std.fmt.allocPrint(session.allocator, "external evidence requested because: {s}", .{initial_detail}),
                .result_path = try session.allocator.dupe(u8, persisted.result_path),
                .draft_path = try session.allocator.dupe(u8, persisted.draft_path),
                .support_permission = result.support_graph.permission,
                .support_minimum_met = result.support_graph.minimum_met,
            });

            session.evidence_state = .fetched;
            var evidence_result = try external_evidence.acquire(session.allocator, .{
                .project_shard = paths.metadata.id,
                .request = &session.evidence_request.?,
                .request_id_hint = session.task_id,
                .considered_reason = initial_detail,
            });
            defer evidence_result.deinit();
            const evidence_path = try writeTaskArtifact(session, paths, "external-evidence-result", ".json", try external_evidence.renderJson(session.allocator, &evidence_result));
            replaceOptionalOwnedTextOwned(session.allocator, &session.last_external_evidence_result_path, evidence_path);
            try updateContextFromExternalEvidence(session, &evidence_result, evidence_path);
            try appendHistory(session, .{
                .index = nextHistoryIndex(session),
                .step_index = session.next_subgoal_index,
                .action = .evidence_fetched,
                .state = .running,
                .summary = try std.fmt.allocPrint(session.allocator, "fetched {d} external evidence source(s)", .{evidence_result.source_records.len}),
                .result_path = try session.allocator.dupe(u8, evidence_path),
            });

            if (evidence_result.state == .ingested) {
                session.evidence_state = .ingested;
                try clearEvidenceDetail(session);
                try appendHistory(session, .{
                    .index = nextHistoryIndex(session),
                    .step_index = session.next_subgoal_index,
                    .action = .evidence_ingested,
                    .state = .running,
                    .summary = try std.fmt.allocPrint(session.allocator, "ingested {d} external evidence item(s)", .{evidence_result.stage_result.staged_items}),
                    .result_path = try session.allocator.dupe(u8, evidence_path),
                });

                var rerun = runCodeIntelForSession(session, paths, &intent) catch |err| switch (err) {
                    error.TaskOperatorHandledFailure => return,
                    else => return err,
                };
                defer rerun.deinit();
                try code_intel.appendExternalEvidenceOutcome(session.allocator, &rerun.support_graph, .{
                    .state = session.evidence_state,
                    .considered_reason = initial_detail,
                    .improved_support = proofBackedCodeIntelComplete(&rerun),
                    .unresolved_detail = if (proofBackedCodeIntelComplete(&rerun)) null else rerun.unresolved_detail,
                });
                persisted.deinit(session.allocator);
                persisted = try persistCodeIntelArtifacts(session, paths, &rerun, draft_type);

                if (!proofBackedCodeIntelComplete(&rerun)) {
                    const detail = rerun.unresolved_detail orelse rerun.support_graph.unresolved_reason orelse "external evidence did not produce proof-backed support";
                    session.evidence_state = classifyEvidenceOutcome(detail);
                    try setEvidenceDetail(session, detail);
                    try appendHistory(session, .{
                        .index = nextHistoryIndex(session),
                        .step_index = session.next_subgoal_index,
                        .action = if (session.evidence_state == .conflicting) .evidence_conflicting else .evidence_insufficient,
                        .state = .running,
                        .summary = try std.fmt.allocPrint(session.allocator, "external evidence remained {s}: {s}", .{ external_evidence.acquisitionStateName(session.evidence_state), detail }),
                        .result_path = try session.allocator.dupe(u8, evidence_path),
                    });
                    try finishUnresolvedSupport(session, paths, emit_panic_dump, &rerun, persisted.result_path, persisted.draft_path, detail);
                    return;
                }

                try clearEvidenceDetail(session);
                try clearStatusDetail(session);
                try setSubgoalState(session, session.next_subgoal_index, .complete, null);
                try appendHistory(session, .{
                    .index = nextHistoryIndex(session),
                    .step_index = session.next_subgoal_index,
                    .action = .support_collected,
                    .state = .running,
                    .summary = try std.fmt.allocPrint(session.allocator, "external evidence improved support nodes={d} evidence={d}", .{ rerun.support_graph.nodes.len, rerun.evidence.len }),
                    .result_path = try session.allocator.dupe(u8, persisted.result_path),
                    .draft_path = try session.allocator.dupe(u8, persisted.draft_path),
                    .stop_reason = rerun.stop_reason,
                    .support_permission = rerun.support_graph.permission,
                    .support_minimum_met = rerun.support_graph.minimum_met,
                });
                if (session.workflow == .code_intel) {
                    session.status = .verified_complete;
                    session.next_subgoal_index = @intCast(session.subgoals.len);
                    try replaceOwnedText(session.allocator, &session.current_objective, "proof-backed completion recorded");
                    try appendHistory(session, .{
                        .index = nextHistoryIndex(session),
                        .step_index = 1,
                        .action = .task_verified_complete,
                        .state = session.status,
                        .summary = try session.allocator.dupe(u8, "verified completion reached after external evidence ingestion"),
                        .result_path = try session.allocator.dupe(u8, persisted.result_path),
                        .draft_path = try session.allocator.dupe(u8, persisted.draft_path),
                        .stop_reason = rerun.stop_reason,
                        .support_permission = rerun.support_graph.permission,
                        .support_minimum_met = rerun.support_graph.minimum_met,
                    });
                    return;
                }
                session.next_subgoal_index += 1;
                try replaceOwnedText(session.allocator, &session.current_objective, session.subgoals[session.next_subgoal_index].title);
                return;
            }

            session.evidence_state = evidence_result.state;
            const detail = evidence_result.detail orelse initial_detail;
            try setEvidenceDetail(session, detail);
            try appendHistory(session, .{
                .index = nextHistoryIndex(session),
                .step_index = session.next_subgoal_index,
                .action = if (session.evidence_state == .conflicting) .evidence_conflicting else .evidence_insufficient,
                .state = .running,
                .summary = try std.fmt.allocPrint(session.allocator, "external evidence acquisition stopped: {s}", .{detail}),
                .result_path = try session.allocator.dupe(u8, evidence_path),
            });
        }

        try finishUnresolvedSupport(session, paths, emit_panic_dump, &result, persisted.result_path, persisted.draft_path, initial_detail);
        return;
    }

    try clearStatusDetail(session);
    try clearEvidenceDetail(session);
    if (session.evidence_request != null and session.evidence_state == .requested) {
        session.evidence_state = .not_needed;
    }
    try setSubgoalState(session, session.next_subgoal_index, .complete, null);
    try appendHistory(session, .{
        .index = nextHistoryIndex(session),
        .step_index = session.next_subgoal_index,
        .action = .support_collected,
        .state = .running,
        .summary = try std.fmt.allocPrint(
            session.allocator,
            "collected proof-backed support nodes={d} evidence={d}",
            .{ result.support_graph.nodes.len, result.evidence.len },
        ),
        .result_path = try session.allocator.dupe(u8, persisted.result_path),
        .draft_path = try session.allocator.dupe(u8, persisted.draft_path),
        .stop_reason = result.stop_reason,
        .support_permission = result.support_graph.permission,
        .support_minimum_met = result.support_graph.minimum_met,
    });

    if (session.workflow == .code_intel) {
        session.status = .verified_complete;
        session.next_subgoal_index = @intCast(session.subgoals.len);
        try replaceOwnedText(session.allocator, &session.current_objective, "proof-backed completion recorded");
        try appendHistory(session, .{
            .index = nextHistoryIndex(session),
            .step_index = 1,
            .action = .task_verified_complete,
            .state = session.status,
            .summary = try session.allocator.dupe(u8, "verified completion reached from proof-backed code intel support"),
            .result_path = try session.allocator.dupe(u8, persisted.result_path),
            .draft_path = try session.allocator.dupe(u8, persisted.draft_path),
            .stop_reason = result.stop_reason,
            .support_permission = result.support_graph.permission,
            .support_minimum_met = result.support_graph.minimum_met,
        });
        return;
    }

    session.next_subgoal_index += 1;
    try replaceOwnedText(session.allocator, &session.current_objective, session.subgoals[session.next_subgoal_index].title);
}

const PersistedCodeIntelArtifacts = struct {
    result_path: []u8,
    draft_path: []u8,

    fn deinit(self: *PersistedCodeIntelArtifacts, allocator: std.mem.Allocator) void {
        allocator.free(self.result_path);
        allocator.free(self.draft_path);
        self.* = undefined;
    }
};

fn runCodeIntelForSession(session: *Session, paths: *const shards.Paths, intent: *task_intent.Task) !code_intel.Result {
    const started = sys.getMilliTick();
    const result = code_intel.run(session.allocator, .{
        .repo_root = session.repo_root,
        .project_shard = if (paths.metadata.kind == .project) paths.metadata.id else null,
        .reasoning_mode = session.chosen_reasoning_mode,
        .compute_budget_request = session.compute_budget_request,
        .effective_budget = session.effective_budget,
        .query_kind = session.query_kind.?,
        .target = session.target.?,
        .other_target = session.other_target,
        .intent = intent,
        .max_items = 8,
        .persist = true,
        .cache_persist = true,
    }) catch |err| {
        try failSessionFromError(session, session.next_subgoal_index, err);
        return error.TaskOperatorHandledFailure;
    };
    session.profile.code_intel_run_ms += sys.getMilliTick() - started;
    return result;
}

fn persistCodeIntelArtifacts(
    session: *Session,
    paths: *const shards.Paths,
    result: *const code_intel.Result,
    draft_type: technical_drafts.DraftType,
) !PersistedCodeIntelArtifacts {
    const result_path = try writeTaskArtifact(session, paths, "code-intel-result", ".json", try code_intel.renderJson(session.allocator, result));
    const draft_path = try writeTaskArtifact(session, paths, "support-draft", ".txt", try technical_drafts.render(session.allocator, .{ .code_intel = result }, .{
        .draft_type = draft_type,
        .max_items = 6,
    }));

    replaceOptionalOwnedTextOwned(session.allocator, &session.last_code_intel_result_path, result_path);
    replaceOptionalOwnedTextOwned(session.allocator, &session.last_draft_path, draft_path);
    session.latest_support = supportSummaryFromCodeIntel(result);
    try updateContextFromCodeIntel(session, result, result_path, draft_path);

    return .{
        .result_path = try session.allocator.dupe(u8, result_path),
        .draft_path = try session.allocator.dupe(u8, draft_path),
    };
}

fn finishUnresolvedSupport(
    session: *Session,
    paths: *const shards.Paths,
    emit_panic_dump: bool,
    result: *const code_intel.Result,
    result_path: []const u8,
    draft_path: []const u8,
    detail: []const u8,
) !void {
    session.status = .unresolved;
    try setStatusDetail(session, detail);
    try setSubgoalState(session, session.next_subgoal_index, .unresolved, detail);
    if (emit_panic_dump) {
        try maybeCaptureCodeIntelPanicDump(session, paths, result);
    }
    try replaceOwnedText(session.allocator, &session.current_objective, detail);
    try appendHistory(session, .{
        .index = nextHistoryIndex(session),
        .step_index = session.next_subgoal_index,
        .action = .task_unresolved,
        .state = session.status,
        .summary = try std.fmt.allocPrint(session.allocator, "support step stopped: {s}", .{detail}),
        .result_path = try session.allocator.dupe(u8, result_path),
        .draft_path = try session.allocator.dupe(u8, draft_path),
        .panic_dump_path = if (session.last_panic_dump_path) |path| try session.allocator.dupe(u8, path) else null,
        .stop_reason = result.stop_reason,
        .support_permission = result.support_graph.permission,
        .support_minimum_met = result.support_graph.minimum_met,
    });
}

fn classifyEvidenceOutcome(detail: []const u8) external_evidence.AcquisitionState {
    if (std.mem.indexOf(u8, detail, "ambiguous") != null or std.mem.indexOf(u8, detail, "contradiction") != null or std.mem.indexOf(u8, detail, "conflict") != null) {
        return .conflicting;
    }
    return .insufficient;
}

fn stepPatchVerification(session: *Session, paths: *const shards.Paths, emit_panic_dump: bool) !void {
    try setSubgoalState(session, session.next_subgoal_index, .running, null);
    var intent = try reparseRecordedIntent(session);
    defer intent.deinit();

    const patch_started = sys.getMilliTick();
    var result = patch_candidates.run(session.allocator, .{
        .repo_root = session.repo_root,
        .project_shard = if (paths.metadata.kind == .project) paths.metadata.id else null,
        .query_kind = session.query_kind.?,
        .target = session.target.?,
        .other_target = session.other_target,
        .request_label = session.originating_intent,
        .intent = &intent,
        .compute_budget_request = session.compute_budget_request,
        .effective_budget = session.effective_budget,
        .persist_code_intel = true,
        .cache_persist = true,
        .stage_result = true,
    }) catch |err| {
        try failSessionFromError(session, session.next_subgoal_index, err);
        return;
    };
    session.profile.patch_run_ms += sys.getMilliTick() - patch_started;
    defer result.deinit();

    const result_path = try writeTaskArtifact(session, paths, "patch-result", ".json", try patch_candidates.renderJson(session.allocator, &result));
    const final_draft_type: technical_drafts.DraftType = if (proofBackedPatchComplete(&result))
        .code_change_summary
    else
        .proof_backed_explanation;
    const draft_path = try writeTaskArtifact(session, paths, "patch-draft", ".txt", try technical_drafts.render(session.allocator, .{ .patch_candidates = &result }, .{
        .draft_type = final_draft_type,
        .max_items = result.caps.max_support_items,
    }));

    replaceOptionalOwnedTextOwned(session.allocator, &session.last_patch_candidates_result_path, result_path);
    replaceOptionalOwnedTextOwned(session.allocator, &session.last_draft_path, draft_path);
    session.latest_support = supportSummaryFromPatchResult(&result);

    try updateContextFromPatchCandidates(session, &result, result_path, draft_path);

    if (proofBackedPatchComplete(&result)) {
        session.status = .verified_complete;
        try clearStatusDetail(session);
        try setSubgoalState(session, session.next_subgoal_index, .complete, null);
        session.next_subgoal_index = @intCast(session.subgoals.len);
        try replaceOwnedText(session.allocator, &session.current_objective, "verified completion recorded");
        try appendHistory(session, .{
            .index = nextHistoryIndex(session),
            .step_index = 2,
            .action = .task_verified_complete,
            .state = session.status,
            .summary = try std.fmt.allocPrint(
                session.allocator,
                "verified patch completion with {s}",
                .{@tagName(patch_candidates.selectedValidationState(&result).?)},
            ),
            .result_path = try session.allocator.dupe(u8, result_path),
            .draft_path = try session.allocator.dupe(u8, draft_path),
            .stop_reason = result.stop_reason,
            .support_permission = result.support_graph.permission,
            .support_minimum_met = result.support_graph.minimum_met,
        });
        return;
    }

    const detail = result.unresolved_detail orelse inferPatchStopDetail(&result);
    if (patchResultBlocked(&result)) {
        session.status = .blocked;
        try setStatusDetail(session, detail);
        try setSubgoalState(session, session.next_subgoal_index, .blocked, detail);
        if (emit_panic_dump) {
            try maybeCapturePatchPanicDump(session, paths, &result);
        }
        try replaceOwnedText(session.allocator, &session.current_objective, detail);
        try appendHistory(session, .{
            .index = nextHistoryIndex(session),
            .step_index = 2,
            .action = .task_blocked,
            .state = session.status,
            .summary = try std.fmt.allocPrint(session.allocator, "patch verification blocked: {s}", .{detail}),
            .result_path = try session.allocator.dupe(u8, result_path),
            .draft_path = try session.allocator.dupe(u8, draft_path),
            .panic_dump_path = if (session.last_panic_dump_path) |path| try session.allocator.dupe(u8, path) else null,
            .stop_reason = result.stop_reason,
            .support_permission = result.support_graph.permission,
            .support_minimum_met = result.support_graph.minimum_met,
        });
        return;
    }

    session.status = .unresolved;
    try setStatusDetail(session, detail);
    try setSubgoalState(session, session.next_subgoal_index, .unresolved, detail);
    if (emit_panic_dump) {
        try maybeCapturePatchPanicDump(session, paths, &result);
    }
    try replaceOwnedText(session.allocator, &session.current_objective, detail);
    try appendHistory(session, .{
        .index = nextHistoryIndex(session),
        .step_index = 2,
        .action = .task_unresolved,
        .state = session.status,
        .summary = try std.fmt.allocPrint(session.allocator, "patch verification unresolved: {s}", .{detail}),
        .result_path = try session.allocator.dupe(u8, result_path),
        .draft_path = try session.allocator.dupe(u8, draft_path),
        .panic_dump_path = if (session.last_panic_dump_path) |path| try session.allocator.dupe(u8, path) else null,
        .stop_reason = result.stop_reason,
        .support_permission = result.support_graph.permission,
        .support_minimum_met = result.support_graph.minimum_met,
    });
}

fn reparseRecordedIntent(session: *const Session) !task_intent.Task {
    var parsed = try task_intent.parse(session.allocator, session.originating_intent, .{});
    errdefer parsed.deinit();
    if (!intentMatchesSnapshot(session.intent, &parsed)) {
        return error.IntentSnapshotMismatch;
    }
    return parsed;
}

fn intentMatchesSnapshot(snapshot: IntentSnapshot, parsed: *const task_intent.Task) bool {
    if (snapshot.status != parsed.status) return false;
    if (snapshot.action != parsed.action) return false;
    if (snapshot.output_mode != parsed.output_mode) return false;
    if (snapshot.target_kind != parsed.target.kind) return false;
    if (!optionalTextEqual(snapshot.target_spec, parsed.target.spec)) return false;
    if (snapshot.other_target_kind != parsed.other_target.kind) return false;
    if (!optionalTextEqual(snapshot.other_target_spec, parsed.other_target.spec)) return false;
    if (snapshot.dispatch_flow != parsed.dispatch.flow) return false;
    if (snapshot.query_kind != (if (parsed.dispatch.query_kind) |kind| translateIntentQueryKind(kind) else null)) return false;
    if (snapshot.reasoning_mode != parsed.dispatch.reasoning_mode) return false;
    if (snapshot.executable != parsed.dispatch.executable) return false;
    if (!optionalTextEqual(snapshot.detail, parsed.unresolved_detail)) return false;
    return true;
}

fn proofBackedCodeIntelComplete(result: *const code_intel.Result) bool {
    return result.status == .supported and
        result.stop_reason == .none and
        result.reasoning_mode == .proof and
        result.support_graph.permission == .supported and
        result.support_graph.minimum_met;
}

fn proofBackedPatchComplete(result: *const patch_candidates.Result) bool {
    const selected_state = patch_candidates.selectedValidationState(result) orelse return false;
    return result.status == .supported and
        result.stop_reason == .none and
        result.refactor_plan_status == .verified_supported and
        result.support_graph.permission == .supported and
        result.support_graph.minimum_met and
        (selected_state == .build_test_verified or selected_state == .runtime_verified);
}

fn patchResultBlocked(result: *const patch_candidates.Result) bool {
    if (result.unresolved_detail) |detail| {
        if (std.mem.indexOf(u8, detail, "no Linux-native build workflow was detected") != null) return true;
    }
    for (result.candidates) |candidate| {
        if (candidate.verification.build.summary) |summary| {
            if (std.mem.indexOf(u8, summary, "no Linux-native build workflow was detected") != null) return true;
        }
        if (candidate.verification.test_step.summary) |summary| {
            if (std.mem.indexOf(u8, summary, "no Linux-native build workflow was detected") != null) return true;
        }
    }
    return false;
}

fn inferPatchStopDetail(result: *const patch_candidates.Result) []const u8 {
    return result.unresolved_detail orelse switch (result.stop_reason) {
        .low_confidence => "no patch candidate survived proof-backed verification",
        .contradiction => "patch workflow reached a contradiction under bounded verification",
        .budget => "patch workflow exhausted its bounded verification budget",
        .internal_error => "patch workflow encountered an internal operator error",
        else => "patch workflow did not reach proof-backed completion",
    };
}

fn maybeCaptureCodeIntelPanicDump(session: *Session, paths: *const shards.Paths, result: *const code_intel.Result) !void {
    panic_dump.global_recorder.reset();
    panic_dump.global_recorder.capture(.{
        .step = 1,
        .active_branches = @intCast(result.query_hypotheses.len),
        .reasoning_mode = result.reasoning_mode,
        .step_count = 1,
        .branch_count = @intCast(result.query_hypotheses.len),
        .created_hypotheses = @intCast(result.query_hypotheses.len),
        .expanded_hypotheses = @intCast(result.query_hypotheses.len),
        .accepted_hypotheses = if (result.status == .supported) 1 else 0,
        .unresolved_hypotheses = if (result.status == .unresolved) 1 else 0,
        .confidence = result.confidence,
        .stop_reason = result.stop_reason,
    }, &.{}, &.{});
    try panic_dump.captureCodeIntelResult(session.allocator, result, session.last_code_intel_result_path);
    panic_dump.emitPanicDump(session.task_id);
    const snapshot = try snapshotPanicDump(session, paths, "code-intel-panic.bin");
    replaceOptionalOwnedTextOwned(session.allocator, &session.last_panic_dump_path, snapshot);
}

fn maybeCapturePatchPanicDump(session: *Session, paths: *const shards.Paths, result: *const patch_candidates.Result) !void {
    panic_dump.global_recorder.reset();
    panic_dump.global_recorder.capture(.{
        .step = 1,
        .active_branches = @intCast(result.candidates.len),
        .reasoning_mode = .proof,
        .step_count = 1,
        .branch_count = @intCast(result.candidates.len),
        .created_hypotheses = @intCast(result.candidates.len),
        .expanded_hypotheses = @intCast(result.candidates.len),
        .accepted_hypotheses = if (result.status == .supported) 1 else 0,
        .unresolved_hypotheses = if (result.status == .unresolved) 1 else 0,
        .confidence = result.confidence,
        .stop_reason = result.stop_reason,
    }, &.{}, &.{});
    try panic_dump.capturePatchCandidatesResult(session.allocator, result);
    panic_dump.emitPanicDump(session.task_id);
    const snapshot = try snapshotPanicDump(session, paths, "patch-panic.bin");
    replaceOptionalOwnedTextOwned(session.allocator, &session.last_panic_dump_path, snapshot);
}

fn snapshotPanicDump(session: *Session, paths: *const shards.Paths, suffix: []const u8) ![]u8 {
    const bytes = try readOwnedFile(session.allocator, panic_dump.dumpPath(), MAX_ARTIFACT_FILE_BYTES);
    return writeTaskArtifact(session, paths, suffix, "", bytes);
}

fn writeTaskArtifact(session: *Session, paths: *const shards.Paths, stem: []const u8, suffix: []const u8, bytes: []const u8) ![]u8 {
    defer session.allocator.free(bytes);
    const started = sys.getMilliTick();
    try sys.makePath(session.allocator, paths.task_sessions_root_abs_path);
    const file_name = if (suffix.len == 0)
        try std.fmt.allocPrint(session.allocator, "{s}-{d}-{s}", .{ session.task_id, session.next_subgoal_index + 1, stem })
    else
        try std.fmt.allocPrint(session.allocator, "{s}-{d}-{s}{s}", .{ session.task_id, session.next_subgoal_index + 1, stem, suffix });
    defer session.allocator.free(file_name);
    const abs_path = try std.fs.path.join(session.allocator, &.{ paths.task_sessions_root_abs_path, file_name });
    try writeOwnedFile(session.allocator, abs_path, bytes);
    session.profile.artifact_write_ms += sys.getMilliTick() - started;
    session.profile.artifact_write_count += 1;
    return abs_path;
}

fn updateContextFromCodeIntel(session: *Session, result: *const code_intel.Result, result_path: []const u8, draft_path: []const u8) !void {
    try upsertContextRef(session, .{
        .kind = .code_intel_result,
        .label = try session.allocator.dupe(u8, "code_intel_result"),
        .value = try session.allocator.dupe(u8, result_path),
        .detail = try std.fmt.allocPrint(session.allocator, "query={s} target={s}", .{ @tagName(result.query_kind), result.query_target }),
    });
    try upsertContextRef(session, .{
        .kind = .technical_draft,
        .label = try session.allocator.dupe(u8, "support_draft"),
        .value = try session.allocator.dupe(u8, draft_path),
        .detail = try session.allocator.dupe(u8, technical_drafts.draftTypeName(if (session.workflow == .patch_candidates) .refactor_plan else .proof_backed_explanation)),
    });

    var abstraction_count: usize = 0;
    for (result.abstraction_traces) |trace| {
        if (abstraction_count >= MAX_CONTEXT_ABSTRACTIONS) break;
        if (!trace.usable) continue;
        abstraction_count += 1;
        try upsertContextRef(session, .{
            .kind = .abstraction,
            .label = try session.allocator.dupe(u8, trace.label),
            .value = try session.allocator.dupe(u8, trace.source_spec),
            .detail = if (trace.supporting_concept) |value| try session.allocator.dupe(u8, value) else null,
        });
    }

    var corpus_count: usize = 0;
    if (result.primary) |subject| {
        if (subject.corpus) |corpus| {
            corpus_count += try upsertCorpusContext(session, corpus, corpus_count);
        }
    }
    for (result.evidence) |item| {
        if (corpus_count >= MAX_CONTEXT_CORPUS) break;
        if (item.corpus) |corpus| {
            corpus_count += try upsertCorpusContext(session, corpus, corpus_count);
        }
    }
}

fn updateContextFromPatchCandidates(session: *Session, result: *const patch_candidates.Result, result_path: []const u8, draft_path: []const u8) !void {
    try upsertContextRef(session, .{
        .kind = .patch_candidates_result,
        .label = try session.allocator.dupe(u8, "patch_candidates_result"),
        .value = try session.allocator.dupe(u8, result_path),
        .detail = try std.fmt.allocPrint(session.allocator, "request={s}", .{result.request_label}),
    });
    try upsertContextRef(session, .{
        .kind = .technical_draft,
        .label = try session.allocator.dupe(u8, "patch_draft"),
        .value = try session.allocator.dupe(u8, draft_path),
        .detail = try session.allocator.dupe(u8, technical_drafts.draftTypeName(if (proofBackedPatchComplete(result)) .code_change_summary else .proof_backed_explanation)),
    });
    if (result.code_intel_result_path.len > 0) {
        try upsertContextRef(session, .{
            .kind = .code_intel_result,
            .label = try session.allocator.dupe(u8, "code_intel_source"),
            .value = try session.allocator.dupe(u8, result.code_intel_result_path),
            .detail = try session.allocator.dupe(u8, "canonical code-intel provenance"),
        });
    }
    var abstraction_count: usize = 0;
    for (result.abstraction_refs) |item| {
        if (abstraction_count >= MAX_CONTEXT_ABSTRACTIONS) break;
        abstraction_count += 1;
        try upsertContextRef(session, .{
            .kind = .abstraction,
            .label = try session.allocator.dupe(u8, item.label),
            .value = if (item.rel_path) |rel_path| try session.allocator.dupe(u8, rel_path) else try session.allocator.dupe(u8, item.label),
            .detail = if (item.reason) |reason| try session.allocator.dupe(u8, reason) else null,
        });
    }
}

fn updateContextFromExternalEvidence(session: *Session, result: *const external_evidence.Result, result_path: []const u8) !void {
    try upsertContextRef(session, .{
        .kind = .external_evidence_result,
        .label = try session.allocator.dupe(u8, "external_evidence_result"),
        .value = try session.allocator.dupe(u8, result_path),
        .detail = try std.fmt.allocPrint(session.allocator, "state={s} sources={d}", .{ external_evidence.acquisitionStateName(result.state), result.source_records.len }),
    });
    var corpus_count: usize = 0;
    for (result.source_records) |item| {
        if (corpus_count >= MAX_CONTEXT_CORPUS) break;
        corpus_count += 1;
        try upsertContextRef(session, .{
            .kind = .corpus,
            .label = try session.allocator.dupe(u8, item.source_url),
            .value = try session.allocator.dupe(u8, item.local_rel_path),
            .detail = try session.allocator.dupe(u8, item.considered_reason),
        });
    }
}

fn upsertCorpusContext(session: *Session, corpus: code_intel.CorpusTrace, current_count: usize) !usize {
    if (current_count >= MAX_CONTEXT_CORPUS) return 0;
    try upsertContextRef(session, .{
        .kind = .corpus,
        .label = try session.allocator.dupe(u8, corpus.source_label),
        .value = try session.allocator.dupe(u8, corpus.source_rel_path),
        .detail = try session.allocator.dupe(u8, corpus.provenance),
    });
    return 1;
}

fn supportSummaryFromCodeIntel(result: *const code_intel.Result) SupportSummary {
    const pack = code_intel.collectPackInfluenceStats(result.evidence, result.abstraction_traces, result.pack_routing_traces, result.grounding_traces, result.reverse_grounding_traces);
    return .{
        .permission = result.support_graph.permission,
        .minimum_met = result.support_graph.minimum_met,
        .node_count = @intCast(result.support_graph.nodes.len),
        .edge_count = @intCast(result.support_graph.edges.len),
        .evidence_count = @intCast(result.evidence.len),
        .abstraction_ref_count = @intCast(result.abstraction_traces.len),
        .pack_considered_count = pack.considered_count,
        .pack_activated_count = pack.activated_count,
        .pack_skipped_count = pack.skipped_count,
        .pack_suppressed_count = pack.suppressed_count,
        .pack_conflict_refused_count = pack.conflict_refused_count,
        .pack_trust_blocked_count = pack.trust_blocked_count,
        .pack_stale_blocked_count = pack.stale_blocked_count,
        .pack_candidate_surface_count = pack.candidate_surface_count,
    };
}

fn supportSummaryFromPatchResult(result: *const patch_candidates.Result) SupportSummary {
    const pack = code_intel.collectPackInfluenceStats(result.source_pack_evidence, result.source_abstraction_traces, result.pack_routing_traces, result.grounding_traces, result.reverse_grounding_traces);
    var summary = SupportSummary{
        .permission = result.support_graph.permission,
        .minimum_met = result.support_graph.minimum_met,
        .node_count = @intCast(result.support_graph.nodes.len),
        .edge_count = @intCast(result.support_graph.edges.len),
        .evidence_count = @intCast(result.invariant_evidence.len + result.contradiction_evidence.len),
        .abstraction_ref_count = @intCast(result.abstraction_refs.len),
        .pack_considered_count = pack.considered_count,
        .pack_activated_count = pack.activated_count,
        .pack_skipped_count = pack.skipped_count,
        .pack_suppressed_count = pack.suppressed_count,
        .pack_conflict_refused_count = pack.conflict_refused_count,
        .pack_trust_blocked_count = pack.trust_blocked_count,
        .pack_stale_blocked_count = pack.stale_blocked_count,
        .pack_candidate_surface_count = pack.candidate_surface_count,
    };
    for (result.candidates) |candidate| {
        switch (candidate.verification.build.state) {
            .passed => {
                summary.build_passed += 1;
                summary.build_attempted += 1;
            },
            .failed => summary.build_attempted += 1,
            .unavailable => {},
        }
        switch (candidate.verification.test_step.state) {
            .passed => {
                summary.test_passed += 1;
                summary.test_attempted += 1;
            },
            .failed => summary.test_attempted += 1,
            .unavailable => {},
        }
        switch (candidate.verification.runtime_step.state) {
            .passed => {
                summary.runtime_passed += 1;
                summary.runtime_attempted += 1;
            },
            .failed => summary.runtime_attempted += 1,
            .unavailable => {},
        }
        if (candidate.status == .supported and (candidate.validation_state == .build_test_verified or candidate.validation_state == .runtime_verified)) {
            summary.verified_candidate_count += 1;
        }
        for (candidate.verification.repair_plans) |plan| {
            switch (plan.outcome) {
                .improved => summary.repair_recovered_count += 1,
                .failed => summary.repair_failed_count += 1,
                else => {},
            }
        }
    }
    return summary;
}

fn isTerminal(status: Status) bool {
    return switch (status) {
        .blocked, .unresolved, .verified_complete, .failed => true,
        else => false,
    };
}

fn isReopenable(status: Status) bool {
    return switch (status) {
        .blocked, .unresolved, .failed => true,
        else => false,
    };
}

fn reopenSession(session: *Session) !void {
    session.status = .running;
    session.resume_count += 1;
    try clearStatusDetail(session);
    try clearEvidenceDetail(session);
    if (session.next_subgoal_index < session.subgoals.len) {
        try setSubgoalState(session, session.next_subgoal_index, .pending, null);
        try replaceOwnedText(session.allocator, &session.current_objective, session.subgoals[session.next_subgoal_index].title);
    }
    try appendHistory(session, .{
        .index = nextHistoryIndex(session),
        .step_index = session.next_subgoal_index,
        .action = .task_reopened,
        .state = session.status,
        .summary = try std.fmt.allocPrint(session.allocator, "reopened task at subgoal {d}", .{session.next_subgoal_index}),
    });
}

fn replaceEvidenceRequest(session: *Session, request: external_evidence.RequestInput) !void {
    if (session.evidence_request) |*existing| existing.deinit(session.allocator);
    session.evidence_request = try external_evidence.Request.initOwned(session.allocator, request);
    session.evidence_state = .requested;
    try clearEvidenceDetail(session);
}

fn setSubgoalState(session: *Session, idx: u32, state: SubgoalState, detail: ?[]const u8) !void {
    if (idx >= session.subgoals.len) return;
    session.subgoals[idx].state = state;
    if (session.subgoals[idx].detail) |existing| {
        session.allocator.free(existing);
        session.subgoals[idx].detail = null;
    }
    if (detail) |value| session.subgoals[idx].detail = try session.allocator.dupe(u8, value);
}

fn clearStatusDetail(session: *Session) !void {
    if (session.status_detail) |existing| {
        session.allocator.free(existing);
        session.status_detail = null;
    }
}

fn clearEvidenceDetail(session: *Session) !void {
    if (session.evidence_detail) |existing| {
        session.allocator.free(existing);
        session.evidence_detail = null;
    }
}

fn setStatusDetail(session: *Session, detail: []const u8) !void {
    try clearStatusDetail(session);
    session.status_detail = try session.allocator.dupe(u8, detail);
}

fn setEvidenceDetail(session: *Session, detail: []const u8) !void {
    try clearEvidenceDetail(session);
    session.evidence_detail = try session.allocator.dupe(u8, detail);
}

fn replaceOwnedText(allocator: std.mem.Allocator, target: *[]u8, next: []const u8) !void {
    allocator.free(target.*);
    target.* = try allocator.dupe(u8, next);
}

fn replaceOptionalOwnedText(allocator: std.mem.Allocator, target: *?[]u8, next: ?[]const u8) !void {
    if (target.*) |existing| allocator.free(existing);
    target.* = if (next) |value| try allocator.dupe(u8, value) else null;
}

fn replaceOptionalOwnedTextOwned(allocator: std.mem.Allocator, target: *?[]u8, next: []u8) void {
    if (target.*) |existing| allocator.free(existing);
    target.* = next;
}

fn appendHistory(session: *Session, entry: HistoryEntry) !void {
    var next_len = session.history.len;
    if (next_len < MAX_HISTORY) {
        next_len += 1;
        const next = try session.allocator.alloc(HistoryEntry, next_len);
        for (session.history, 0..) |item, idx| next[idx] = item;
        if (session.history.len > 0) session.allocator.free(session.history);
        next[next_len - 1] = entry;
        session.history = next;
        return;
    }

    session.history[0].deinit(session.allocator);
    const next = try session.allocator.alloc(HistoryEntry, MAX_HISTORY);
    var idx: usize = 1;
    while (idx < session.history.len) : (idx += 1) {
        next[idx - 1] = session.history[idx];
    }
    session.allocator.free(session.history);
    next[MAX_HISTORY - 1] = entry;
    session.history = next;
}

fn nextHistoryIndex(session: *const Session) u32 {
    return if (session.history.len == 0) 0 else session.history[session.history.len - 1].index + 1;
}

fn upsertContextRef(session: *Session, entry: ContextRef) !void {
    for (session.relevant_context) |*existing| {
        if (existing.kind != entry.kind) continue;
        if (!std.mem.eql(u8, existing.value, entry.value)) continue;
        existing.deinit(session.allocator);
        existing.* = entry;
        return;
    }

    if (session.relevant_context.len < MAX_CONTEXT_REFS) {
        const next = try session.allocator.alloc(ContextRef, session.relevant_context.len + 1);
        for (session.relevant_context, 0..) |item, idx| next[idx] = item;
        if (session.relevant_context.len > 0) session.allocator.free(session.relevant_context);
        next[next.len - 1] = entry;
        session.relevant_context = next;
        return;
    }

    const replace_idx: usize = if (session.relevant_context[0].kind == .shard) 1 else 0;
    session.relevant_context[replace_idx].deinit(session.allocator);
    session.relevant_context[replace_idx] = entry;
}

fn failSessionFromError(session: *Session, step_idx: u32, err: anyerror) !void {
    session.status = .failed;
    const detail = @errorName(err);
    try setStatusDetail(session, detail);
    try setSubgoalState(session, step_idx, .failed, detail);
    try replaceOwnedText(session.allocator, &session.current_objective, detail);
    try appendHistory(session, .{
        .index = nextHistoryIndex(session),
        .step_index = step_idx,
        .action = .task_failed,
        .state = session.status,
        .summary = try std.fmt.allocPrint(session.allocator, "operator step failed with {s}", .{detail}),
    });
}

fn autoTaskId(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    shard_kind: shards.Kind,
    shard_id: []const u8,
    intent_text: []const u8,
) ![]u8 {
    var hasher = std.hash.Fnv1a_64.init();
    hasher.update(FORMAT_VERSION);
    hasher.update(repo_root);
    hasher.update(@tagName(shard_kind));
    hasher.update(shard_id);
    hasher.update(intent_text);
    return std.fmt.allocPrint(allocator, "task-{x:0>16}", .{hasher.final()});
}

fn sanitizeTaskId(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, raw, " \r\n\t/");
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    for (if (trimmed.len == 0) "task" else trimmed) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_') {
            try out.append(std.ascii.toLower(byte));
        } else {
            try out.append('_');
        }
    }
    if (out.items.len == 0) try out.appendSlice("task");
    return out.toOwnedSlice();
}

fn sessionPath(allocator: std.mem.Allocator, paths: *const shards.Paths, task_id: []const u8) ![]u8 {
    const file_name = try std.fmt.allocPrint(allocator, "{s}.json", .{task_id});
    defer allocator.free(file_name);
    return std.fs.path.join(allocator, &.{ paths.task_sessions_root_abs_path, file_name });
}

fn cloneSubgoals(allocator: std.mem.Allocator, source: []const Subgoal) ![]Subgoal {
    const out = try allocator.alloc(Subgoal, source.len);
    errdefer allocator.free(out);
    for (source, 0..) |item, idx| {
        out[idx] = .{
            .id = try allocator.dupe(u8, item.id),
            .title = try allocator.dupe(u8, item.title),
            .state = item.state,
            .detail = if (item.detail) |value| try allocator.dupe(u8, value) else null,
        };
    }
    return out;
}

fn cloneContextRefs(allocator: std.mem.Allocator, source: []const ContextRef) ![]ContextRef {
    const out = try allocator.alloc(ContextRef, source.len);
    errdefer allocator.free(out);
    for (source, 0..) |item, idx| {
        out[idx] = .{
            .kind = item.kind,
            .label = try allocator.dupe(u8, item.label),
            .value = try allocator.dupe(u8, item.value),
            .detail = if (item.detail) |value| try allocator.dupe(u8, value) else null,
        };
    }
    return out;
}

fn cloneHistory(allocator: std.mem.Allocator, source: []const HistoryEntry) ![]HistoryEntry {
    const out = try allocator.alloc(HistoryEntry, source.len);
    errdefer allocator.free(out);
    for (source, 0..) |item, idx| {
        out[idx] = .{
            .index = item.index,
            .step_index = item.step_index,
            .action = item.action,
            .state = item.state,
            .summary = try allocator.dupe(u8, item.summary),
            .result_path = if (item.result_path) |value| try allocator.dupe(u8, value) else null,
            .draft_path = if (item.draft_path) |value| try allocator.dupe(u8, value) else null,
            .panic_dump_path = if (item.panic_dump_path) |value| try allocator.dupe(u8, value) else null,
            .stop_reason = item.stop_reason,
            .support_permission = item.support_permission,
            .support_minimum_met = item.support_minimum_met,
        };
    }
    return out;
}

fn optionalTextEqual(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null and right == null) return true;
    if (left == null or right == null) return false;
    return std.mem.eql(u8, left.?, right.?);
}

fn fileExists(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

fn readOwnedFile(allocator: std.mem.Allocator, abs_path: []const u8, max_bytes: usize) ![]u8 {
    const handle = try sys.openForRead(allocator, abs_path);
    defer sys.closeFile(handle);
    const size = try sys.getFileSize(handle);
    if (size > max_bytes) return error.TaskArtifactTooLarge;
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
