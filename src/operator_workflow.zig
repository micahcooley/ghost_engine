const std = @import("std");
const code_intel = @import("code_intel.zig");
const compute_budget = @import("compute_budget.zig");
const mc = @import("inference.zig");
const panic_dump = @import("panic_dump.zig");
const patch_candidates = @import("patch_candidates.zig");
const shards = @import("shards.zig");
const task_intent = @import("task_intent.zig");
const task_sessions = @import("task_sessions.zig");
const technical_drafts = @import("technical_drafts.zig");
const external_evidence = @import("external_evidence.zig");

pub const RenderMode = enum {
    summary,
    json,
    report,
};

pub fn parseRenderMode(text: []const u8) ?RenderMode {
    if (std.mem.eql(u8, text, "summary") or std.mem.eql(u8, text, "concise")) return .summary;
    if (std.mem.eql(u8, text, "json")) return .json;
    if (std.mem.eql(u8, text, "report")) return .report;
    return null;
}

pub fn parseQueryKind(text: []const u8) ?code_intel.QueryKind {
    if (std.mem.eql(u8, text, "impact")) return .impact;
    if (std.mem.eql(u8, text, "breaks-if")) return .breaks_if;
    if (std.mem.eql(u8, text, "contradicts")) return .contradicts;
    return null;
}

pub const ProjectMount = struct {
    allocator: std.mem.Allocator,
    repo_root: []u8,
    shard_kind: shards.Kind,
    shard_id: []u8,
    shard_root: []u8,
    code_intel_root: []u8,
    patch_root: []u8,
    corpus_root: []u8,
    abstractions_root: []u8,
    task_root: []u8,

    pub fn deinit(self: *ProjectMount) void {
        self.allocator.free(self.repo_root);
        self.allocator.free(self.shard_id);
        self.allocator.free(self.shard_root);
        self.allocator.free(self.code_intel_root);
        self.allocator.free(self.patch_root);
        self.allocator.free(self.corpus_root);
        self.allocator.free(self.abstractions_root);
        self.allocator.free(self.task_root);
        self.* = undefined;
    }
};

pub const TaskRunOptions = struct {
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

pub const TaskResumeOptions = struct {
    project_shard: ?[]const u8 = null,
    task_id: []const u8,
    evidence_request: ?external_evidence.RequestInput = null,
    compute_budget_request: ?compute_budget.Request = null,
    max_steps: u32 = 3,
    reopen: bool = false,
    emit_panic_dump: bool = true,
};

pub const CodeIntelOptions = struct {
    repo_root: []const u8,
    project_shard: ?[]const u8 = null,
    intent_text: ?[]const u8 = null,
    query_kind: ?code_intel.QueryKind = null,
    target: ?[]const u8 = null,
    other_target: ?[]const u8 = null,
    reasoning_mode: mc.ReasoningMode = .proof,
    max_items: usize = 8,
    compute_budget_request: compute_budget.Request = .{},
};

pub const PatchWorkflowMode = enum {
    plan,
    verify,
    oracle,
};

pub const PatchWorkflowOptions = struct {
    repo_root: []const u8,
    project_shard: ?[]const u8 = null,
    intent_text: ?[]const u8 = null,
    request_label: ?[]const u8 = null,
    query_kind: ?code_intel.QueryKind = null,
    target: ?[]const u8 = null,
    other_target: ?[]const u8 = null,
    caps: patch_candidates.Caps = .{},
    compute_budget_request: compute_budget.Request = .{},
};

pub const CodeIntelView = struct {
    allocator: std.mem.Allocator,
    result: code_intel.Result,
    draft_type: technical_drafts.DraftType,

    pub fn deinit(self: *CodeIntelView) void {
        self.result.deinit();
        self.* = undefined;
    }
};

pub const PatchWorkflowView = struct {
    allocator: std.mem.Allocator,
    mode: PatchWorkflowMode,
    result: patch_candidates.Result,
    draft_type: technical_drafts.DraftType,

    pub fn deinit(self: *PatchWorkflowView) void {
        self.result.deinit();
        self.* = undefined;
    }
};

pub const ReplayView = struct {
    allocator: std.mem.Allocator,
    dump_path: []u8,
    task_id: ?[]u8 = null,
    dump: panic_dump.ParsedDump,
    inspection: panic_dump.ReplayInspection,

    pub fn deinit(self: *ReplayView) void {
        self.allocator.free(self.dump_path);
        if (self.task_id) |value| self.allocator.free(value);
        self.inspection.deinit(self.allocator);
        self.dump.deinit();
        self.* = undefined;
    }
};

pub fn useProject(allocator: std.mem.Allocator, repo_root: []const u8, project_shard: ?[]const u8) !ProjectMount {
    var shard_metadata = if (project_shard) |value|
        try shards.resolveProjectMetadata(allocator, value)
    else
        try shards.resolveDefaultProjectMetadata(allocator);
    defer shard_metadata.deinit();

    var paths = try shards.resolvePaths(allocator, shard_metadata.metadata);
    defer paths.deinit();

    return .{
        .allocator = allocator,
        .repo_root = try allocator.dupe(u8, repo_root),
        .shard_kind = paths.metadata.kind,
        .shard_id = try allocator.dupe(u8, paths.metadata.id),
        .shard_root = try allocator.dupe(u8, paths.root_abs_path),
        .code_intel_root = try allocator.dupe(u8, paths.code_intel_root_abs_path),
        .patch_root = try allocator.dupe(u8, paths.patch_candidates_root_abs_path),
        .corpus_root = try allocator.dupe(u8, paths.corpus_ingest_root_abs_path),
        .abstractions_root = try allocator.dupe(u8, paths.abstractions_root_abs_path),
        .task_root = try allocator.dupe(u8, paths.task_sessions_root_abs_path),
    };
}

pub fn runTask(allocator: std.mem.Allocator, options: TaskRunOptions) !task_sessions.Session {
    return task_sessions.run(allocator, .{
        .repo_root = options.repo_root,
        .project_shard = options.project_shard,
        .intent_text = options.intent_text,
        .task_id = options.task_id,
        .evidence_request = options.evidence_request,
        .compute_budget_request = options.compute_budget_request,
        .max_steps = options.max_steps,
        .reopen = options.reopen,
        .emit_panic_dump = options.emit_panic_dump,
    });
}

pub fn resumeTask(allocator: std.mem.Allocator, options: TaskResumeOptions) !task_sessions.Session {
    return task_sessions.resumeTask(allocator, .{
        .project_shard = options.project_shard,
        .task_id = options.task_id,
        .evidence_request = options.evidence_request,
        .compute_budget_request = options.compute_budget_request,
        .max_steps = options.max_steps,
        .reopen = options.reopen,
        .emit_panic_dump = options.emit_panic_dump,
    });
}

pub fn loadTask(allocator: std.mem.Allocator, project_shard: ?[]const u8, task_id: []const u8) !task_sessions.Session {
    return task_sessions.load(allocator, project_shard, task_id);
}

pub fn inspect(allocator: std.mem.Allocator, options: CodeIntelOptions) !CodeIntelView {
    var parsed_intent: ?task_intent.Task = null;
    errdefer if (parsed_intent) |*intent| intent.deinit();

    var resolved = try resolveCodeIntelQuery(allocator, options, &parsed_intent);
    defer resolved.deinit(allocator);

    const draft_type: technical_drafts.DraftType = switch (resolved.query_kind) {
        .contradicts => .contradiction_report,
        else => .proof_backed_explanation,
    };

    return .{
        .allocator = allocator,
        .result = try code_intel.run(allocator, .{
            .repo_root = options.repo_root,
            .project_shard = options.project_shard,
            .reasoning_mode = resolved.reasoning_mode,
            .compute_budget_request = options.compute_budget_request,
            .query_kind = resolved.query_kind,
            .target = resolved.target,
            .other_target = resolved.other_target,
            .intent = if (parsed_intent) |*intent| intent else null,
            .max_items = options.max_items,
            .persist = true,
        }),
        .draft_type = draft_type,
    };
}

pub fn runPatchWorkflow(allocator: std.mem.Allocator, mode: PatchWorkflowMode, options: PatchWorkflowOptions) !PatchWorkflowView {
    var parsed_intent: ?task_intent.Task = null;
    errdefer if (parsed_intent) |*intent| intent.deinit();

    var resolved = try resolvePatchQuery(allocator, options, &parsed_intent);
    defer resolved.deinit(allocator);

    const result = try patch_candidates.run(allocator, .{
        .repo_root = options.repo_root,
        .project_shard = options.project_shard,
        .query_kind = resolved.query_kind,
        .target = resolved.target,
        .other_target = resolved.other_target,
        .request_label = resolved.request_label,
        .intent = if (parsed_intent) |*intent| intent else null,
        .caps = resolved.caps,
        .compute_budget_request = options.compute_budget_request,
        .persist_code_intel = true,
        .cache_persist = true,
        .stage_result = mode != .plan,
    });

    return .{
        .allocator = allocator,
        .mode = mode,
        .draft_type = draftTypeForPatch(mode, &result),
        .result = result,
    };
}

pub fn replayDumpPath(allocator: std.mem.Allocator, dump_path: []const u8, allow_external: bool) !ReplayView {
    var dump = try panic_dump.readFile(allocator, dump_path);
    errdefer dump.deinit();
    var inspection = try panic_dump.inspectReplay(allocator, &dump, allow_external);
    errdefer inspection.deinit(allocator);
    return .{
        .allocator = allocator,
        .dump_path = try allocator.dupe(u8, dump_path),
        .dump = dump,
        .inspection = inspection,
    };
}

pub fn replayTask(allocator: std.mem.Allocator, project_shard: ?[]const u8, task_id: []const u8, allow_external: bool) !ReplayView {
    var session = try task_sessions.load(allocator, project_shard, task_id);
    defer session.deinit();
    const dump_path = session.last_panic_dump_path orelse return error.MissingPanicDump;
    var replay = try replayDumpPath(allocator, dump_path, allow_external);
    replay.task_id = try allocator.dupe(u8, task_id);
    return replay;
}

pub fn renderProject(allocator: std.mem.Allocator, mount: *const ProjectMount, mode: RenderMode) ![]u8 {
    switch (mode) {
        .json => {
            var out = std.ArrayList(u8).init(allocator);
            errdefer out.deinit();
            try std.json.stringify(.{
                .workflowEntry = "ghost_task_operator",
                .repoRoot = mount.repo_root,
                .shardKind = mount.shard_kind,
                .shardId = mount.shard_id,
                .shardRoot = mount.shard_root,
                .codeIntelRoot = mount.code_intel_root,
                .patchRoot = mount.patch_root,
                .corpusRoot = mount.corpus_root,
                .abstractionsRoot = mount.abstractions_root,
                .taskRoot = mount.task_root,
            }, .{}, out.writer());
            return out.toOwnedSlice();
        },
        .report, .summary => {
            var out = std.ArrayList(u8).init(allocator);
            errdefer out.deinit();
            const writer = out.writer();
            try writer.print(
                "workflow_entry=ghost_task_operator\nrepo={s}\nproject_shard={s}/{s}\nshard_root={s}\ncode_intel_root={s}\npatch_root={s}\ncorpus_root={s}\nabstractions_root={s}\ntask_root={s}\n",
                .{
                    mount.repo_root,
                    @tagName(mount.shard_kind),
                    mount.shard_id,
                    mount.shard_root,
                    mount.code_intel_root,
                    mount.patch_root,
                    mount.corpus_root,
                    mount.abstractions_root,
                    mount.task_root,
                },
            );
            if (mode == .report) {
                try writer.writeAll("\ncommands=project,run,resume,show,support,inspect,plan,verify,oracle,replay\n");
            }
            return out.toOwnedSlice();
        },
    }
}

pub fn renderTaskState(allocator: std.mem.Allocator, session: *const task_sessions.Session, mode: RenderMode) ![]u8 {
    return switch (mode) {
        .json => task_sessions.renderJson(allocator, session),
        .summary => task_sessions.renderSummary(allocator, session),
        .report => if (session.last_draft_path) |path|
            readOwnedAbsoluteFile(allocator, path, 512 * 1024)
        else
            task_sessions.renderSummary(allocator, session),
    };
}

pub fn renderTaskSupport(allocator: std.mem.Allocator, session: *const task_sessions.Session, mode: RenderMode) ![]u8 {
    switch (mode) {
        .json => {
            var out = std.ArrayList(u8).init(allocator);
            errdefer out.deinit();
            try std.json.stringify(.{
                .taskId = session.task_id,
                .status = session.status,
                .currentObjective = session.current_objective,
                .evidenceState = session.evidence_state,
                .evidenceDetail = session.evidence_detail,
                .latestSupport = session.latest_support,
                .lastCodeIntelResultPath = session.last_code_intel_result_path,
                .lastPatchCandidatesResultPath = session.last_patch_candidates_result_path,
                .lastExternalEvidenceResultPath = session.last_external_evidence_result_path,
                .lastDraftPath = session.last_draft_path,
                .lastPanicDumpPath = session.last_panic_dump_path,
                .relevantContext = session.relevant_context,
            }, .{}, out.writer());
            return out.toOwnedSlice();
        },
        .report => {
            if (session.last_draft_path) |path| return readOwnedAbsoluteFile(allocator, path, 512 * 1024);
            return renderTaskSupport(allocator, session, .summary);
        },
        .summary => {
            var out = std.ArrayList(u8).init(allocator);
            errdefer out.deinit();
            const writer = out.writer();
            const show_cmd = try taskSupportCommand(allocator, session, "show");
            defer allocator.free(show_cmd);
            const replay_cmd = if (session.last_panic_dump_path != null)
                try taskSupportCommand(allocator, session, "replay")
            else
                null;
            defer if (replay_cmd) |value| allocator.free(value);
            try writer.print(
                "task={s}\nstatus={s}\nobjective={s}\nevidence_state={s}\n",
                .{
                    session.task_id,
                    @tagName(session.status),
                    session.current_objective,
                    external_evidence.acquisitionStateName(session.evidence_state),
                },
            );
            if (session.evidence_detail) |detail| try writer.print("evidence_detail={s}\n", .{detail});
            if (session.latest_support) |support| {
                try writer.print(
                    "support_permission={s}\nsupport_minimum_met={s}\nsupport_nodes={d}\nsupport_edges={d}\nsupport_evidence={d}\nsupport_abstractions={d}\nverified_candidates={d}\nbuild_passed={d}/{d}\ntest_passed={d}/{d}\nruntime_passed={d}/{d}\n",
                    .{
                        @tagName(support.permission),
                        if (support.minimum_met) "true" else "false",
                        support.node_count,
                        support.edge_count,
                        support.evidence_count,
                        support.abstraction_ref_count,
                        support.verified_candidate_count,
                        support.build_passed,
                        support.build_attempted,
                        support.test_passed,
                        support.test_attempted,
                        support.runtime_passed,
                        support.runtime_attempted,
                    },
                );
                try writer.print(
                    "repair_recovered={d}\nrepair_failed={d}\npack_considered={d}\npack_activated={d}\npack_skipped={d}\npack_suppressed={d}\npack_conflict_refused={d}\npack_trust_blocked={d}\npack_stale_blocked={d}\npack_candidate_surfaces={d}\n",
                    .{
                        support.repair_recovered_count,
                        support.repair_failed_count,
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
            if (replay_cmd) |value| try writer.print("replay_cmd={s}\n", .{value});
            const context_count = @min(session.relevant_context.len, 6);
            if (context_count > 0) {
                try writer.writeAll("\n[provenance]\n");
                for (session.relevant_context[0..context_count]) |item| {
                    try writer.print("- {s}:{s} -> {s}\n", .{ @tagName(item.kind), item.label, item.value });
                    if (item.detail) |detail| try writer.print("  detail={s}\n", .{detail});
                }
            }
            return out.toOwnedSlice();
        },
    }
}

pub fn renderCodeIntelView(allocator: std.mem.Allocator, view: *const CodeIntelView, mode: RenderMode) ![]u8 {
    return switch (mode) {
        .json => code_intel.renderJson(allocator, &view.result),
        .report => technical_drafts.render(allocator, .{ .code_intel = &view.result }, .{
            .draft_type = view.draft_type,
            .max_items = 8,
        }),
        .summary => {
            var out = std.ArrayList(u8).init(allocator);
            errdefer out.deinit();
            const writer = out.writer();
            const pack = code_intel.collectPackInfluenceStats(view.result.evidence, view.result.abstraction_traces, view.result.pack_routing_traces, view.result.grounding_traces, view.result.reverse_grounding_traces);
            try writer.print(
                "workflow=inspect\nstatus={s}\nquery={s}\ntarget={s}\nreasoning_mode={s}\ncompute_tier={s}\nconfidence={d}\nstop_reason={s}\nsupport_permission={s}\nsupport_minimum_met={s}\nevidence_count={d}\nabstraction_count={d}\npack_considered={d}\npack_activated={d}\npack_skipped={d}\npack_suppressed={d}\n",
                .{
                    @tagName(view.result.status),
                    @tagName(view.result.query_kind),
                    view.result.query_target,
                    mc.reasoningModeName(view.result.reasoning_mode),
                    compute_budget.tierName(view.result.effective_budget.effective_tier),
                    view.result.confidence,
                    @tagName(view.result.stop_reason),
                    @tagName(view.result.support_graph.permission),
                    if (view.result.support_graph.minimum_met) "true" else "false",
                    view.result.evidence.len,
                    view.result.abstraction_traces.len,
                    pack.considered_count,
                    pack.activated_count,
                    pack.skipped_count,
                    pack.suppressed_count,
                },
            );
            if (view.result.unresolved_detail) |detail| try writer.print("detail={s}\n", .{detail});
            if (view.result.query_other_target) |other| try writer.print("other_target={s}\n", .{other});
            return out.toOwnedSlice();
        },
    };
}

fn taskSupportCommand(allocator: std.mem.Allocator, session: *const task_sessions.Session, command: []const u8) ![]u8 {
    const shard_arg = if (session.shard_kind == .project)
        try std.fmt.allocPrint(allocator, " --project-shard={s}", .{session.shard_id})
    else
        try allocator.dupe(u8, "");
    defer allocator.free(shard_arg);
    return std.fmt.allocPrint(allocator, "ghost_task_operator {s}{s} --task-id={s}", .{ command, shard_arg, session.task_id });
}

pub fn renderPatchWorkflowView(allocator: std.mem.Allocator, view: *const PatchWorkflowView, mode: RenderMode) ![]u8 {
    return switch (mode) {
        .json => patch_candidates.renderJson(allocator, &view.result),
        .report => technical_drafts.render(allocator, .{ .patch_candidates = &view.result }, .{
            .draft_type = view.draft_type,
            .max_items = view.result.caps.max_support_items,
        }),
        .summary => {
            var out = std.ArrayList(u8).init(allocator);
            errdefer out.deinit();
            const writer = out.writer();
            const selected_state = patch_candidates.selectedValidationState(&view.result);
            const selected_candidate = findSelectedCandidate(&view.result);
            const pack = code_intel.collectPackInfluenceStats(view.result.source_pack_evidence, view.result.source_abstraction_traces, view.result.pack_routing_traces, view.result.grounding_traces, view.result.reverse_grounding_traces);
            try writer.print(
                "workflow={s}\nstatus={s}\nquery={s}\ntarget={s}\nrequest={s}\ncompute_tier={s}\nconfidence={d}\nstop_reason={s}\nrefactor_plan_status={s}\nsupport_permission={s}\nsupport_minimum_met={s}\ncandidate_count={d}\npack_considered={d}\npack_activated={d}\npack_skipped={d}\npack_suppressed={d}\n",
                .{
                    @tagName(view.mode),
                    @tagName(view.result.status),
                    @tagName(view.result.query_kind),
                    view.result.target,
                    view.result.request_label,
                    compute_budget.tierName(view.result.effective_budget.effective_tier),
                    view.result.confidence,
                    @tagName(view.result.stop_reason),
                    @tagName(view.result.refactor_plan_status),
                    @tagName(view.result.support_graph.permission),
                    if (view.result.support_graph.minimum_met) "true" else "false",
                    view.result.candidates.len,
                    pack.considered_count,
                    pack.activated_count,
                    pack.skipped_count,
                    pack.suppressed_count,
                },
            );
            if (selected_state) |state| try writer.print("selected_verification_state={s}\n", .{@tagName(state)});
            if (view.result.selected_candidate_id) |candidate_id| try writer.print("selected_candidate={s}\n", .{candidate_id});
            if (view.result.selected_scope) |scope| try writer.print("selected_scope={s}\n", .{scope});
            if (view.result.selected_strategy) |strategy| try writer.print("selected_strategy={s}\n", .{strategy});
            if (view.result.staged_path) |path| try writer.print("staged_patch={s}\n", .{path});
            try writer.print("code_intel_result={s}\n", .{view.result.code_intel_result_path});
            if (selected_candidate) |candidate| {
                try writer.print("selected_candidate_status={s}\n", .{@tagName(candidate.status)});
                try writer.print("runtime_step_state={s}\n", .{@tagName(candidate.verification.runtime_step.state)});
                if (candidate.verification.runtime_step.summary) |summary| try writer.print("runtime_step_summary={s}\n", .{summary});
            } else if (view.mode == .oracle) {
                try writer.writeAll("runtime_step_state=unavailable\n");
            }
            if (view.result.unresolved_detail) |detail| try writer.print("detail={s}\n", .{detail});
            return out.toOwnedSlice();
        },
    };
}

pub fn renderReplayView(allocator: std.mem.Allocator, view: *const ReplayView, mode: RenderMode) ![]u8 {
    const rendered = switch (mode) {
        .summary => try panic_dump.renderSummary(allocator, &view.dump, &view.inspection),
        .json => try panic_dump.renderJson(allocator, &view.dump, &view.inspection),
        .report => try panic_dump.renderReplayReport(allocator, &view.dump, &view.inspection),
    };
    errdefer allocator.free(rendered);
    if (view.task_id == null or mode == .json) return rendered;

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const writer = out.writer();
    try writer.print("task={s}\npanic_dump={s}\n", .{ view.task_id.?, view.dump_path });
    if (mode == .report) {
        try writer.writeAll("\n");
    }
    try writer.writeAll(rendered);
    allocator.free(rendered);
    return out.toOwnedSlice();
}

const ResolvedCodeIntelQuery = struct {
    query_kind: code_intel.QueryKind,
    target: []u8,
    other_target: ?[]u8 = null,
    reasoning_mode: mc.ReasoningMode,

    fn deinit(self: *ResolvedCodeIntelQuery, allocator: std.mem.Allocator) void {
        allocator.free(self.target);
        if (self.other_target) |value| allocator.free(value);
        self.* = undefined;
    }
};

const ResolvedPatchQuery = struct {
    query_kind: code_intel.QueryKind,
    target: []u8,
    other_target: ?[]u8 = null,
    request_label: []u8,
    caps: patch_candidates.Caps,

    fn deinit(self: *ResolvedPatchQuery, allocator: std.mem.Allocator) void {
        allocator.free(self.target);
        if (self.other_target) |value| allocator.free(value);
        allocator.free(self.request_label);
        self.* = undefined;
    }
};

fn resolveCodeIntelQuery(
    allocator: std.mem.Allocator,
    options: CodeIntelOptions,
    parsed_intent: *?task_intent.Task,
) !ResolvedCodeIntelQuery {
    if (options.intent_text) |text| {
        parsed_intent.* = try task_intent.parse(allocator, text, .{});
        const intent = parsed_intent.*.?;
        if (intent.status != .grounded or intent.dispatch.flow != .code_intel or intent.dispatch.query_kind == null or intent.target.spec == null) {
            return error.InvalidArguments;
        }
        return .{
            .query_kind = translateIntentQueryKind(intent.dispatch.query_kind.?),
            .target = try allocator.dupe(u8, intent.target.spec.?),
            .other_target = if (intent.other_target.spec) |value| try allocator.dupe(u8, value) else null,
            .reasoning_mode = intent.dispatch.reasoning_mode,
        };
    }

    return .{
        .query_kind = options.query_kind orelse return error.InvalidArguments,
        .target = try allocator.dupe(u8, options.target orelse return error.InvalidArguments),
        .other_target = if (options.other_target) |value| try allocator.dupe(u8, value) else null,
        .reasoning_mode = options.reasoning_mode,
    };
}

fn resolvePatchQuery(
    allocator: std.mem.Allocator,
    options: PatchWorkflowOptions,
    parsed_intent: *?task_intent.Task,
) !ResolvedPatchQuery {
    var caps = options.caps;
    if (options.intent_text) |text| {
        parsed_intent.* = try task_intent.parse(allocator, text, .{});
        const intent = parsed_intent.*.?;
        if (intent.status != .grounded or intent.dispatch.flow != .patch_candidates or intent.dispatch.query_kind == null or intent.target.spec == null) {
            return error.InvalidArguments;
        }
        if (intent.requested_alternatives > 0 and intent.requested_alternatives > caps.max_candidates) {
            caps.max_candidates = intent.requested_alternatives;
        }
        return .{
            .query_kind = translateIntentQueryKind(intent.dispatch.query_kind.?),
            .target = try allocator.dupe(u8, intent.target.spec.?),
            .other_target = if (intent.other_target.spec) |value| try allocator.dupe(u8, value) else null,
            .request_label = try allocator.dupe(u8, intent.raw_input),
            .caps = caps,
        };
    }

    return .{
        .query_kind = options.query_kind orelse return error.InvalidArguments,
        .target = try allocator.dupe(u8, options.target orelse return error.InvalidArguments),
        .other_target = if (options.other_target) |value| try allocator.dupe(u8, value) else null,
        .request_label = try allocator.dupe(u8, options.request_label orelse options.target orelse return error.InvalidArguments),
        .caps = caps,
    };
}

fn draftTypeForPatch(mode: PatchWorkflowMode, result: *const patch_candidates.Result) technical_drafts.DraftType {
    const selected_state = patch_candidates.selectedValidationState(result);
    return switch (mode) {
        .plan => .refactor_plan,
        .verify, .oracle => if (result.status == .supported and
            result.refactor_plan_status == .verified_supported and
            selected_state != null and
            (selected_state.? == .build_test_verified or selected_state.? == .runtime_verified))
            .code_change_summary
        else
            .proof_backed_explanation,
    };
}

fn findSelectedCandidate(result: *const patch_candidates.Result) ?*const patch_candidates.Candidate {
    if (result.selected_candidate_id) |candidate_id| {
        for (result.candidates) |*candidate| {
            if (std.mem.eql(u8, candidate.id, candidate_id)) return candidate;
        }
    }
    for (result.candidates) |*candidate| {
        if (candidate.status == .supported) return candidate;
    }
    return null;
}

fn translateIntentQueryKind(kind: task_intent.QueryKind) code_intel.QueryKind {
    return switch (kind) {
        .impact => .impact,
        .breaks_if => .breaks_if,
        .contradicts => .contradicts,
    };
}

fn readOwnedAbsoluteFile(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    return file.readToEndAlloc(allocator, max_bytes);
}
