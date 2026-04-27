const std = @import("std");
const compute_budget = @import("compute_budget.zig");
const correction_hooks = @import("correction_hooks.zig");
const feedback = @import("feedback.zig");
const intent_grounding = @import("intent_grounding.zig");
const response_engine = @import("response_engine.zig");
const shards = @import("shards.zig");
const sys = @import("sys.zig");

pub const FORMAT_VERSION = "ghost_conversation_session_v1";
pub const MAX_MESSAGES: usize = 64;
pub const MAX_ACTIVE_ARTIFACTS: usize = 16;
pub const MAX_AMBIGUITIES: usize = 8;
pub const MAX_OBLIGATIONS: usize = 16;
pub const MAX_SESSION_BYTES: usize = 512 * 1024;

pub const Role = enum {
    user,
    system,
};

pub const ConversationMode = enum {
    draft,
    fast,
    deep,
    unresolved,
};

pub const ResultKind = enum {
    draft,
    verified,
    unresolved,
    feedback,
};

pub const Message = struct {
    index: u32,
    role: Role,
    text: []u8,
    mode: ConversationMode = .draft,
    result_kind: ResultKind = .draft,

    pub fn deinit(self: *Message, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.* = undefined;
    }
};

pub const ArtifactRef = struct {
    id: []u8,
    kind: []u8,
    source: []u8,

    pub fn deinit(self: *ArtifactRef, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.kind);
        allocator.free(self.source);
        self.* = undefined;
    }
};

pub const IntentState = struct {
    raw_text: []u8,
    normalized_text: []u8,
    status: intent_grounding.GroundedIntent.GroundingStatus,
    selected_mode: ConversationMode,
    trace: []u8,

    pub fn deinit(self: *IntentState, allocator: std.mem.Allocator) void {
        allocator.free(self.raw_text);
        allocator.free(self.normalized_text);
        allocator.free(self.trace);
        self.* = undefined;
    }
};

pub const LastResult = struct {
    kind: ResultKind,
    selected_mode: ConversationMode,
    stop_reason: response_engine.StopReason,
    summary: []u8,
    artifact_path: ?[]u8 = null,

    pub fn deinit(self: *LastResult, allocator: std.mem.Allocator) void {
        allocator.free(self.summary);
        if (self.artifact_path) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub const CorrectionProjection = struct {
    correction_count: usize = 0,
    correction_refs: [][]u8 = &.{},
    correction_kinds: [][]u8 = &.{},
    contradicted_refs: [][]u8 = &.{},
    evidence_refs: [][]u8 = &.{},
    negative_knowledge_candidate_refs: [][]u8 = &.{},
    trust_decay_candidate_refs: [][]u8 = &.{},
    user_visible_summaries: [][]u8 = &.{},
    non_authorizing: bool = true,
    projection_complete: bool = true,

    pub fn deinit(self: *CorrectionProjection, allocator: std.mem.Allocator) void {
        freeStringList(allocator, self.correction_refs);
        freeStringList(allocator, self.correction_kinds);
        freeStringList(allocator, self.contradicted_refs);
        freeStringList(allocator, self.evidence_refs);
        freeStringList(allocator, self.negative_knowledge_candidate_refs);
        freeStringList(allocator, self.trust_decay_candidate_refs);
        freeStringList(allocator, self.user_visible_summaries);
        self.* = undefined;
    }
};

pub const NegativeKnowledgeInfluenceProjection = struct {
    influence_count: usize = 0,
    record_ids: [][]u8 = &.{},
    influence_kinds: [][]u8 = &.{},
    affected_hypotheses: [][]u8 = &.{},
    affected_routes: [][]u8 = &.{},
    affected_verifier_handoffs: [][]u8 = &.{},
    applied_records: [][]u8 = &.{},
    proposed_candidates: [][]u8 = &.{},
    trust_decay_candidates: [][]u8 = &.{},
    triage_penalty_count: usize = 0,
    verifier_requirement_count: usize = 0,
    suppression_count: usize = 0,
    routing_warning_count: usize = 0,
    trust_decay_candidate_count: usize = 0,
    non_authorizing: bool = true,
    projection_complete: bool = true,

    pub fn deinit(self: *NegativeKnowledgeInfluenceProjection, allocator: std.mem.Allocator) void {
        freeStringList(allocator, self.record_ids);
        freeStringList(allocator, self.influence_kinds);
        freeStringList(allocator, self.affected_hypotheses);
        freeStringList(allocator, self.affected_routes);
        freeStringList(allocator, self.affected_verifier_handoffs);
        freeStringList(allocator, self.applied_records);
        freeStringList(allocator, self.proposed_candidates);
        freeStringList(allocator, self.trust_decay_candidates);
        self.* = undefined;
    }
};

pub const PendingAmbiguity = struct {
    label: []u8,
    question: []u8,
    options: [][]u8 = &.{},

    pub fn deinit(self: *PendingAmbiguity, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
        allocator.free(self.question);
        for (self.options) |option| allocator.free(option);
        allocator.free(self.options);
        self.* = undefined;
    }
};

pub const PendingObligation = struct {
    id: []u8,
    label: []u8,
    required_for: []u8,

    pub fn deinit(self: *PendingObligation, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.label);
        allocator.free(self.required_for);
        self.* = undefined;
    }
};

pub const ModeTransition = struct {
    from: ConversationMode,
    to: ConversationMode,
    reason: []u8,
};

pub const TurnResult = struct {
    session: Session,
    reply: []u8,
    mode_transition: ?ModeTransition = null,

    pub fn deinit(self: *TurnResult) void {
        if (self.mode_transition) |transition| self.session.allocator.free(transition.reason);
        self.session.allocator.free(self.reply);
        self.session.deinit();
        self.* = undefined;
    }
};

pub const Session = struct {
    allocator: std.mem.Allocator,
    session_id: []u8,
    session_path: []u8,
    repo_root: []u8,
    shard_kind: shards.Kind,
    shard_id: []u8,
    shard_root: []u8,
    history: []Message = &.{},
    active_artifacts: []ArtifactRef = &.{},
    current_intent: ?IntentState = null,
    last_result: ?LastResult = null,
    last_corrections: ?CorrectionProjection = null,
    last_negative_knowledge_influence: ?NegativeKnowledgeInfluenceProjection = null,
    correction_refs: [][]u8 = &.{},
    negative_knowledge_candidate_refs: [][]u8 = &.{},
    pending_ambiguities: []PendingAmbiguity = &.{},
    pending_obligations: []PendingObligation = &.{},

    pub fn deinit(self: *Session) void {
        self.allocator.free(self.session_id);
        self.allocator.free(self.session_path);
        self.allocator.free(self.repo_root);
        self.allocator.free(self.shard_id);
        self.allocator.free(self.shard_root);
        for (self.history) |*item| item.deinit(self.allocator);
        self.allocator.free(self.history);
        for (self.active_artifacts) |*item| item.deinit(self.allocator);
        self.allocator.free(self.active_artifacts);
        if (self.current_intent) |*value| value.deinit(self.allocator);
        if (self.last_result) |*value| value.deinit(self.allocator);
        if (self.last_corrections) |*value| value.deinit(self.allocator);
        if (self.last_negative_knowledge_influence) |*value| value.deinit(self.allocator);
        freeStringList(self.allocator, self.correction_refs);
        freeStringList(self.allocator, self.negative_knowledge_candidate_refs);
        for (self.pending_ambiguities) |*item| item.deinit(self.allocator);
        self.allocator.free(self.pending_ambiguities);
        for (self.pending_obligations) |*item| item.deinit(self.allocator);
        self.allocator.free(self.pending_obligations);
        self.* = undefined;
    }
};

pub const TurnOptions = struct {
    repo_root: []const u8,
    project_shard: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    message: []const u8,
    context_artifacts: []const []const u8 = &.{},
    auto_proceed_low_risk: bool = true,
    compute_budget_request: compute_budget.Request = .{},
    reasoning_level: response_engine.ReasoningLevel = .balanced,
};

pub fn turn(allocator: std.mem.Allocator, options: TurnOptions) !TurnResult {
    var shard_metadata = try resolveConversationShardMetadata(allocator, options.project_shard);
    defer shard_metadata.deinit();
    var paths = try shards.resolvePaths(allocator, shard_metadata.metadata);
    defer paths.deinit();

    const session_id = if (options.session_id) |raw| try sanitizeSessionId(allocator, raw) else try autoSessionId(allocator, options.repo_root, shard_metadata.metadata.kind, shard_metadata.metadata.id);
    defer allocator.free(session_id);
    const path = try sessionPath(allocator, &paths, session_id);
    defer allocator.free(path);

    var session = if (fileExists(path))
        try load(allocator, options.project_shard, session_id)
    else
        try create(allocator, .{
            .repo_root = options.repo_root,
            .project_shard = options.project_shard,
            .session_id = session_id,
            .context_artifacts = options.context_artifacts,
        });
    errdefer session.deinit();

    try appendContextArtifacts(&session, options.context_artifacts, "turn_context");
    try appendMessage(&session, .user, options.message, .draft, .draft);

    if (isFeedback(options.message)) {
        const applied = try recordFeedback(&session, &paths, options.message);
        clearLastResult(&session);
        clearCorrectionProjections(&session);
        session.last_result = .{
            .kind = .feedback,
            .selected_mode = .draft,
            .stop_reason = .none,
            .summary = try std.fmt.allocPrint(allocator, "feedback_event recorded; reinforcement_events_applied={d}", .{applied}),
        };
        const reply = try renderConversationReply(allocator, &session, null);
        try appendMessage(&session, .system, reply, .draft, .feedback);
        try save(&session);
        return .{ .session = session, .reply = reply };
    }

    const context_target = resolveContextTarget(&session, options.message);
    const normalized_message = try lowercaseAscii(allocator, options.message);
    defer allocator.free(normalized_message);
    const resolved_text = try resolveTurnText(allocator, &session, options.message, normalized_message, context_target);
    defer allocator.free(resolved_text);

    var gi = try intent_grounding.ground(allocator, resolved_text, .{
        .context_target = context_target,
        .available_artifacts = artifactIds(session.active_artifacts),
    });
    defer gi.deinit();

    var config = chooseResponseConfig(&session, &gi, normalized_message, options.compute_budget_request, options.reasoning_level);
    const deep_blocked_by_ambiguity = wantsDeep(normalized_message) and (session.pending_ambiguities.len > 0 or gi.ambiguity_sets.len > 0);
    if (deep_blocked_by_ambiguity) {
        config = response_engine.ResponseConfig.draftOnly();
        config.budget_request = options.compute_budget_request;
        config.reasoning_level = options.reasoning_level;
        config.explicit_user_draft_override = true;
    }

    var response = try response_engine.execute(allocator, &gi, config);
    defer response.deinit();

    const selected_mode = conversationModeFromResponse(response.selected_mode, response.stop_reason);
    const previous_mode = if (session.last_result) |last| last.selected_mode else ConversationMode.draft;
    const transition = try buildTransition(allocator, previous_mode, selected_mode, &response, deep_blocked_by_ambiguity);
    errdefer if (transition) |t| allocator.free(t.reason);

    try replaceCurrentIntent(&session, &response.grounded_intent, selected_mode, transition);
    if (!deep_blocked_by_ambiguity) try replacePending(&session, &response.grounded_intent);
    try updateArtifactsFromIntent(&session, &response.grounded_intent);
    try replaceLastResult(&session, &response, selected_mode, deep_blocked_by_ambiguity);
    try replaceCorrectionProjections(&session, &response);

    const reply = try renderConversationReply(allocator, &session, transition);
    errdefer allocator.free(reply);
    try appendMessage(&session, .system, reply, selected_mode, session.last_result.?.kind);
    try save(&session);

    return .{ .session = session, .reply = reply, .mode_transition = transition };
}

const CreateOptions = struct {
    repo_root: []const u8,
    project_shard: ?[]const u8 = null,
    session_id: []const u8,
    context_artifacts: []const []const u8 = &.{},
};

pub fn create(allocator: std.mem.Allocator, options: CreateOptions) !Session {
    var shard_metadata = try resolveConversationShardMetadata(allocator, options.project_shard);
    defer shard_metadata.deinit();
    var paths = try shards.resolvePaths(allocator, shard_metadata.metadata);
    defer paths.deinit();
    const id = try sanitizeSessionId(allocator, options.session_id);
    errdefer allocator.free(id);
    const path = try sessionPath(allocator, &paths, id);
    errdefer allocator.free(path);
    var session = Session{
        .allocator = allocator,
        .session_id = id,
        .session_path = path,
        .repo_root = try allocator.dupe(u8, options.repo_root),
        .shard_kind = shard_metadata.metadata.kind,
        .shard_id = try allocator.dupe(u8, shard_metadata.metadata.id),
        .shard_root = try allocator.dupe(u8, paths.root_abs_path),
    };
    errdefer session.deinit();
    try appendContextArtifacts(&session, options.context_artifacts, "create_context");
    try save(&session);
    return session;
}

pub fn load(allocator: std.mem.Allocator, project_shard: ?[]const u8, session_id_text: []const u8) !Session {
    var shard_metadata = try resolveConversationShardMetadata(allocator, project_shard);
    defer shard_metadata.deinit();
    var paths = try shards.resolvePaths(allocator, shard_metadata.metadata);
    defer paths.deinit();
    const id = try sanitizeSessionId(allocator, session_id_text);
    defer allocator.free(id);
    const path = try sessionPath(allocator, &paths, id);
    defer allocator.free(path);
    const bytes = try readOwnedFile(allocator, path, MAX_SESSION_BYTES);
    defer allocator.free(bytes);

    const DiskSession = struct {
        formatVersion: []const u8,
        sessionId: []const u8,
        sessionPath: []const u8,
        repoRoot: []const u8,
        shardKind: shards.Kind,
        shardId: []const u8,
        shardRoot: []const u8,
        history: []const Message,
        activeArtifacts: []const ArtifactRef,
        currentIntent: ?IntentState = null,
        lastResult: ?LastResult = null,
        last_corrections: ?CorrectionProjection = null,
        last_negative_knowledge_influence: ?NegativeKnowledgeInfluenceProjection = null,
        correction_refs: []const []const u8 = &.{},
        negative_knowledge_candidate_refs: []const []const u8 = &.{},
        pendingAmbiguities: []const PendingAmbiguity,
        pendingObligations: []const PendingObligation,
    };

    const parsed = try std.json.parseFromSlice(DiskSession, allocator, bytes, .{});
    defer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.formatVersion, FORMAT_VERSION)) return error.InvalidConversationSession;

    return .{
        .allocator = allocator,
        .session_id = try allocator.dupe(u8, parsed.value.sessionId),
        .session_path = try allocator.dupe(u8, parsed.value.sessionPath),
        .repo_root = try allocator.dupe(u8, parsed.value.repoRoot),
        .shard_kind = parsed.value.shardKind,
        .shard_id = try allocator.dupe(u8, parsed.value.shardId),
        .shard_root = try allocator.dupe(u8, parsed.value.shardRoot),
        .history = try cloneMessages(allocator, parsed.value.history),
        .active_artifacts = try cloneArtifacts(allocator, parsed.value.activeArtifacts),
        .current_intent = if (parsed.value.currentIntent) |value| try cloneIntentState(allocator, value) else null,
        .last_result = if (parsed.value.lastResult) |value| try cloneLastResult(allocator, value) else null,
        .last_corrections = if (parsed.value.last_corrections) |value| try cloneCorrectionProjection(allocator, value) else null,
        .last_negative_knowledge_influence = if (parsed.value.last_negative_knowledge_influence) |value| try cloneNegativeKnowledgeInfluenceProjection(allocator, value) else null,
        .correction_refs = try cloneConstStringList(allocator, parsed.value.correction_refs),
        .negative_knowledge_candidate_refs = try cloneConstStringList(allocator, parsed.value.negative_knowledge_candidate_refs),
        .pending_ambiguities = try cloneAmbiguities(allocator, parsed.value.pendingAmbiguities),
        .pending_obligations = try cloneObligations(allocator, parsed.value.pendingObligations),
    };
}

pub fn save(session: *const Session) !void {
    const rendered = try renderJson(session.allocator, session);
    defer session.allocator.free(rendered);
    try sys.makePath(session.allocator, std.fs.path.dirname(session.session_path).?);
    try writeOwnedFile(session.allocator, session.session_path, rendered);
}

pub fn renderJson(allocator: std.mem.Allocator, session: *const Session) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    try std.json.stringify(.{
        .formatVersion = FORMAT_VERSION,
        .sessionId = session.session_id,
        .sessionPath = session.session_path,
        .repoRoot = session.repo_root,
        .shardKind = session.shard_kind,
        .shardId = session.shard_id,
        .shardRoot = session.shard_root,
        .history = session.history,
        .activeArtifacts = session.active_artifacts,
        .currentIntent = session.current_intent,
        .lastResult = session.last_result,
        .last_corrections = session.last_corrections,
        .last_negative_knowledge_influence = session.last_negative_knowledge_influence,
        .correction_refs = session.correction_refs,
        .negative_knowledge_candidate_refs = session.negative_knowledge_candidate_refs,
        .pendingAmbiguities = session.pending_ambiguities,
        .pendingObligations = session.pending_obligations,
    }, .{}, out.writer());
    return out.toOwnedSlice();
}

pub fn renderSummary(allocator: std.mem.Allocator, session: *const Session) ![]u8 {
    return renderConversationReply(allocator, session, null);
}

fn renderConversationReply(allocator: std.mem.Allocator, session: *const Session, transition: ?ModeTransition) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const writer = out.writer();

    if (transition) |item| {
        try writer.print("[mode_switch]\nfrom={s}\nto={s}\nreason={s}\n", .{ @tagName(item.from), @tagName(item.to), item.reason });
        if (item.to == .deep) {
            try writer.writeAll("notice=I will verify this with build/test/runtime where the artifact verifier requires it; this may take longer.\n");
        }
        try writer.writeAll("\n");
    }

    if (session.last_result) |last| {
        switch (last.kind) {
            .draft => try writer.writeAll("[Draft]\n"),
            .verified => try writer.writeAll("[Verified]\n"),
            .unresolved => try writer.writeAll("[Unresolved]\n"),
            .feedback => try writer.writeAll("[Feedback]\n"),
        }
        try writer.print("summary={s}\n", .{last.summary});
        try writer.print("session={s}\n", .{session.session_id});
        if (last.artifact_path) |path| try writer.print("artifact={s}\n", .{path});
    }

    if (session.last_corrections) |corrections| {
        if (corrections.correction_count > 0) {
            try writer.writeAll("\n[correction_recorded]\n");
            const count = @min(corrections.user_visible_summaries.len, 4);
            for (corrections.user_visible_summaries[0..count], 0..) |summary, idx| {
                const previous = if (idx < corrections.contradicted_refs.len) corrections.contradicted_refs[idx] else "unknown";
                const evidence = if (idx < corrections.evidence_refs.len) corrections.evidence_refs[idx] else "unknown";
                try writer.print("previous_assumption={s}\ncontradicting_evidence={s}\nupdated_state={s}\n", .{ previous, evidence, summary });
            }
            if (corrections.negative_knowledge_candidate_refs.len > 0) {
                try writer.print("negative_knowledge_candidate_proposed={s}\nreview_required=true\n", .{corrections.negative_knowledge_candidate_refs[0]});
            } else {
                try writer.writeAll("negative_knowledge_candidate_proposed=false\nreview_required=false\n");
            }
            try writer.writeAll("non_authorizing=true\n");
        }
    }

    if (session.last_negative_knowledge_influence) |influence| {
        if (influence.influence_count > 0 or influence.trust_decay_candidate_count > 0) {
            try writer.writeAll("\n[negative_knowledge_applied]\n");
            const count = @min(influence.record_ids.len, 4);
            for (influence.record_ids[0..count], 0..) |record_id, idx| {
                const kind = if (idx < influence.influence_kinds.len) influence.influence_kinds[idx] else "accepted_negative_knowledge";
                try writer.print("record={s}\ninfluence={s}\n", .{ record_id, kind });
            }
            if (influence.triage_penalty_count > 0) try writer.print("triage_penalty_count={d}\n", .{influence.triage_penalty_count});
            if (influence.verifier_requirement_count > 0) try writer.print("stronger_verifier_required={d}\n", .{influence.verifier_requirement_count});
            if (influence.suppression_count > 0) try writer.print("exact_repeat_suppressed={d}\n", .{influence.suppression_count});
            if (influence.routing_warning_count > 0) try writer.print("routing_warning={d}\n", .{influence.routing_warning_count});
            if (influence.trust_decay_candidate_count > 0) try writer.print("trust_decay_candidate_proposed={d}\n", .{influence.trust_decay_candidate_count});
            try writer.writeAll("did_not_prove_claim=true\ndid_not_authorize_support=true\ndid_not_mutate_packs=true\nnon_authorizing=true\n");
        } else if (influence.proposed_candidates.len > 0) {
            try writer.writeAll("\n[negative_knowledge_candidate_proposed]\n");
            const count = @min(influence.proposed_candidates.len, 4);
            for (influence.proposed_candidates[0..count]) |candidate| {
                try writer.print("candidate={s}\n", .{candidate});
            }
            try writer.writeAll("review_required=true\nnon_authorizing=true\n");
        }
    }

    if (session.pending_ambiguities.len > 0) {
        try writer.writeAll("\n[clarification]\n");
        const amb = session.pending_ambiguities[0];
        try writer.print("{s}\n", .{amb.question});
        for (amb.options, 0..) |option, idx| {
            try writer.print("{c}) {s}\n", .{ @as(u8, 'A') + @as(u8, @intCast(idx)), option });
        }
    }

    if (session.pending_obligations.len > 0) {
        try writer.writeAll("\n[pending_obligations]\n");
        const count = @min(session.pending_obligations.len, 4);
        for (session.pending_obligations[0..count]) |obligation| {
            try writer.print("- {s}: {s}\n", .{ obligation.id, obligation.label });
        }
    }

    if (session.active_artifacts.len > 0) {
        try writer.writeAll("\n[artifacts]\n");
        const count = @min(session.active_artifacts.len, 4);
        for (session.active_artifacts[0..count]) |artifact| {
            try writer.print("- {s} ({s})\n", .{ artifact.id, artifact.source });
        }
    }

    return out.toOwnedSlice();
}

fn replaceLastResult(session: *Session, result: *const response_engine.ResponseResult, mode: ConversationMode, deep_blocked_by_ambiguity: bool) !void {
    clearLastResult(session);
    const kind: ResultKind = if (result.draft.mode.enabled)
        .draft
    else if (result.stop_reason == .supported and mode == .deep)
        .verified
    else if (result.stop_reason == .supported)
        .verified
    else
        .unresolved;
    const summary = try summarizeResponse(session.allocator, result, mode, deep_blocked_by_ambiguity);
    session.last_result = .{
        .kind = kind,
        .selected_mode = mode,
        .stop_reason = result.stop_reason,
        .summary = summary,
    };
}

fn replaceCorrectionProjections(session: *Session, result: *const response_engine.ResponseResult) !void {
    clearCorrectionProjections(session);
    if (result.corrections.summary.correction_count > 0) {
        var refs = try session.allocator.alloc([]u8, result.corrections.items.len);
        errdefer {
            for (refs) |item| session.allocator.free(item);
            session.allocator.free(refs);
        }
        for (result.corrections.items, 0..) |item, idx| refs[idx] = try session.allocator.dupe(u8, item.id);
        session.last_corrections = .{
            .correction_count = result.corrections.summary.correction_count,
            .correction_refs = try cloneStringList(session.allocator, refs),
            .correction_kinds = try cloneStringList(session.allocator, result.corrections.summary.correction_kinds),
            .contradicted_refs = try cloneStringList(session.allocator, result.corrections.summary.contradicted_refs),
            .evidence_refs = try cloneStringList(session.allocator, result.corrections.summary.evidence_refs),
            .negative_knowledge_candidate_refs = try cloneStringList(session.allocator, result.corrections.summary.negative_knowledge_candidate_refs),
            .trust_decay_candidate_refs = try cloneStringList(session.allocator, result.corrections.summary.trust_decay_candidate_refs),
            .user_visible_summaries = try cloneStringList(session.allocator, result.corrections.summary.user_visible_summaries),
            .non_authorizing = true,
            .projection_complete = result.corrections.items.len <= response_engine.MAX_CORRECTION_ITEMS,
        };
        session.correction_refs = refs;
    } else {
        session.last_corrections = .{ .projection_complete = true };
    }

    if (result.negative_knowledge.influence_summary.influence_count > 0 or
        result.negative_knowledge.proposed_candidates.len > 0 or
        result.negative_knowledge.trust_decay_candidates.len > 0)
    {
        session.last_negative_knowledge_influence = .{
            .influence_count = result.negative_knowledge.influence_summary.influence_count,
            .record_ids = try cloneStringList(session.allocator, result.negative_knowledge.influence_summary.record_ids),
            .influence_kinds = try cloneStringList(session.allocator, result.negative_knowledge.influence_summary.influence_kinds),
            .affected_hypotheses = try cloneStringList(session.allocator, result.negative_knowledge.influence_summary.affected_hypotheses),
            .affected_routes = try cloneStringList(session.allocator, result.negative_knowledge.influence_summary.affected_routes),
            .affected_verifier_handoffs = try cloneStringList(session.allocator, result.negative_knowledge.influence_summary.affected_verifier_handoffs),
            .applied_records = try cloneStringList(session.allocator, result.negative_knowledge.applied_records),
            .proposed_candidates = try cloneStringList(session.allocator, result.negative_knowledge.proposed_candidates),
            .trust_decay_candidates = try cloneStringList(session.allocator, result.negative_knowledge.trust_decay_candidates),
            .triage_penalty_count = result.negative_knowledge.influence_summary.triage_penalty_count,
            .verifier_requirement_count = result.negative_knowledge.influence_summary.verifier_requirement_count,
            .suppression_count = result.negative_knowledge.influence_summary.suppression_count,
            .routing_warning_count = result.negative_knowledge.influence_summary.routing_warning_count,
            .trust_decay_candidate_count = result.negative_knowledge.influence_summary.trust_decay_candidate_count,
            .non_authorizing = true,
            .projection_complete = result.negative_knowledge.items.len <= response_engine.MAX_NEGATIVE_KNOWLEDGE_ITEMS,
        };
        session.negative_knowledge_candidate_refs = try cloneStringList(session.allocator, result.negative_knowledge.proposed_candidates);
    } else {
        session.last_negative_knowledge_influence = .{ .projection_complete = true };
    }
}

fn clearCorrectionProjections(session: *Session) void {
    if (session.last_corrections) |*value| value.deinit(session.allocator);
    session.last_corrections = null;
    if (session.last_negative_knowledge_influence) |*value| value.deinit(session.allocator);
    session.last_negative_knowledge_influence = null;
    freeStringList(session.allocator, session.correction_refs);
    session.correction_refs = &.{};
    freeStringList(session.allocator, session.negative_knowledge_candidate_refs);
    session.negative_knowledge_candidate_refs = &.{};
}

fn summarizeResponse(allocator: std.mem.Allocator, result: *const response_engine.ResponseResult, mode: ConversationMode, deep_blocked_by_ambiguity: bool) ![]u8 {
    if (deep_blocked_by_ambiguity) {
        return allocator.dupe(u8, "deep execution is blocked until the ambiguity is resolved");
    }
    if (result.draft.mode.enabled) {
        return std.fmt.allocPrint(allocator, "unverified {s}; assumptions={d}; alternatives={d}; missing_info={d}", .{
            @tagName(result.draft.mode.reason),
            result.draft.assumptions.len,
            result.draft.possible_alternatives.len,
            result.draft.missing_information.len,
        });
    }
    switch (result.stop_reason) {
        .supported => return std.fmt.allocPrint(allocator, "{s} result supported by grounded intent and satisfied obligations", .{@tagName(mode)}),
        .budget => return allocator.dupe(u8, "blocked by compute budget; inspect budgetExhaustions for the hit limit and stage"),
        .unresolved => return allocator.dupe(u8, "blocked because ambiguity or missing obligations remain unresolved"),
        .none => return allocator.dupe(u8, "no terminal result was produced"),
    }
}

fn chooseResponseConfig(session: *const Session, gi: *const intent_grounding.GroundedIntent, normalized: []const u8, budget_request: compute_budget.Request, reasoning_level: response_engine.ReasoningLevel) response_engine.ResponseConfig {
    var config = response_engine.ResponseConfig.autoPath();
    config.budget_request = budget_request;
    config.reasoning_level = reasoning_level;
    if (contains(normalized, "just give me a draft") or contains(normalized, "draft only")) {
        config = response_engine.ResponseConfig.draftOnly();
        config.budget_request = budget_request;
        config.reasoning_level = reasoning_level;
        config.explicit_user_draft_override = true;
        return config;
    }
    if (session.pending_ambiguities.len > 0 and !selectsAmbiguity(normalized, session)) {
        config = response_engine.ResponseConfig.draftOnly();
        config.budget_request = budget_request;
        config.reasoning_level = reasoning_level;
        return config;
    }
    if (gi.ambiguity_sets.len > 0 and !selectsAmbiguity(normalized, session)) {
        config = response_engine.ResponseConfig.draftOnly();
        config.budget_request = budget_request;
        config.reasoning_level = reasoning_level;
        return config;
    }
    if (wantsDeep(normalized)) {
        config = response_engine.ResponseConfig.deepOnly();
        config.user_requested_deep = true;
        config.budget_request = budget_request;
        config.reasoning_level = reasoning_level;
        return config;
    }
    if (isQuestionOrPlanning(normalized)) {
        return config;
    }
    return config;
}

fn resolveTurnText(allocator: std.mem.Allocator, session: *const Session, raw: []const u8, normalized: []const u8, context_target: ?[]const u8) ![]u8 {
    if ((contains(normalized, "yes") or contains(normalized, "do that") or contains(normalized, "go ahead")) and session.current_intent != null) {
        return allocator.dupe(u8, session.current_intent.?.raw_text);
    }
    if (selectsAmbiguity(normalized, session)) {
        const selected = selectedAmbiguityText(normalized, session) orelse raw;
        if (context_target) |target| {
            return std.fmt.allocPrint(allocator, "refactor {s} {s}", .{ target, selected });
        }
        return allocator.dupe(u8, selected);
    }
    if (context_target) |target| {
        if (contains(normalized, "more readable") or contains(normalized, "readability")) {
            return std.fmt.allocPrint(allocator, "refactor {s} improve readability", .{target});
        }
        if (contains(normalized, "messy") or contains(normalized, "clean this") or contains(normalized, "clean it")) {
            return std.fmt.allocPrint(allocator, "make this better {s}", .{target});
        }
    }
    return allocator.dupe(u8, raw);
}

fn replaceCurrentIntent(session: *Session, gi: *const intent_grounding.GroundedIntent, mode: ConversationMode, transition: ?ModeTransition) !void {
    if (session.current_intent) |*old| old.deinit(session.allocator);
    const trace = if (transition) |item|
        try std.fmt.allocPrint(session.allocator, "mode_transition:{s}->{s}:{s}", .{ @tagName(item.from), @tagName(item.to), item.reason })
    else
        try session.allocator.dupe(u8, "mode_transition:none");
    session.current_intent = .{
        .raw_text = try session.allocator.dupe(u8, gi.raw_input),
        .normalized_text = try session.allocator.dupe(u8, gi.normalized_form),
        .status = gi.status,
        .selected_mode = mode,
        .trace = trace,
    };
}

fn replacePending(session: *Session, gi: *const intent_grounding.GroundedIntent) !void {
    clearPending(session);
    var ambiguities = std.ArrayList(PendingAmbiguity).init(session.allocator);
    errdefer {
        for (ambiguities.items) |*item| item.deinit(session.allocator);
        ambiguities.deinit();
    }
    for (gi.ambiguity_sets) |amb| {
        if (ambiguities.items.len >= MAX_AMBIGUITIES) break;
        var options = std.ArrayList([]u8).init(session.allocator);
        errdefer {
            for (options.items) |item| session.allocator.free(item);
            options.deinit();
        }
        for (amb.candidate_indices) |idx| {
            if (idx >= gi.candidate_intents.len or options.items.len >= 4) continue;
            try options.append(try session.allocator.dupe(u8, gi.candidate_intents[idx].label));
        }
        try ambiguities.append(.{
            .label = try session.allocator.dupe(u8, "ambiguity_set"),
            .question = try session.allocator.dupe(u8, "I need one choice before verified execution. Which direction do you want?"),
            .options = try options.toOwnedSlice(),
        });
    }
    session.pending_ambiguities = try ambiguities.toOwnedSlice();

    var obligations = std.ArrayList(PendingObligation).init(session.allocator);
    errdefer {
        for (obligations.items) |*item| item.deinit(session.allocator);
        obligations.deinit();
    }
    for (gi.missing_obligations) |obl| {
        if (obligations.items.len >= MAX_OBLIGATIONS) break;
        try obligations.append(.{
            .id = try session.allocator.dupe(u8, obl.id),
            .label = try session.allocator.dupe(u8, obl.label),
            .required_for = try session.allocator.dupe(u8, obl.required_for),
        });
    }
    for (gi.obligations) |obl| {
        if (!obl.pending or obligations.items.len >= MAX_OBLIGATIONS) continue;
        try obligations.append(.{
            .id = try session.allocator.dupe(u8, obl.id),
            .label = try session.allocator.dupe(u8, obl.label),
            .required_for = try session.allocator.dupe(u8, obl.scope),
        });
    }
    session.pending_obligations = try obligations.toOwnedSlice();
}

fn updateArtifactsFromIntent(session: *Session, gi: *const intent_grounding.GroundedIntent) !void {
    for (gi.artifact_bindings) |binding| {
        try appendArtifact(session, binding.artifact_id, "artifact", @tagName(binding.source));
    }
}

fn appendContextArtifacts(session: *Session, artifacts: []const []const u8, source: []const u8) !void {
    for (artifacts) |artifact| try appendArtifact(session, artifact, "artifact", source);
}

fn appendArtifact(session: *Session, id: []const u8, kind: []const u8, source: []const u8) !void {
    if (id.len == 0) return;
    for (session.active_artifacts) |item| {
        if (std.mem.eql(u8, item.id, id)) return;
    }
    var list = std.ArrayList(ArtifactRef).fromOwnedSlice(session.allocator, session.active_artifacts);
    errdefer list.deinit();
    if (list.items.len >= MAX_ACTIVE_ARTIFACTS) {
        var old = list.orderedRemove(0);
        old.deinit(session.allocator);
    }
    try list.append(.{
        .id = try session.allocator.dupe(u8, id),
        .kind = try session.allocator.dupe(u8, kind),
        .source = try session.allocator.dupe(u8, source),
    });
    session.active_artifacts = try list.toOwnedSlice();
}

fn appendMessage(session: *Session, role: Role, text: []const u8, mode: ConversationMode, kind: ResultKind) !void {
    var list = std.ArrayList(Message).fromOwnedSlice(session.allocator, session.history);
    errdefer list.deinit();
    if (list.items.len >= MAX_MESSAGES) {
        var old = list.orderedRemove(0);
        old.deinit(session.allocator);
    }
    try list.append(.{
        .index = @intCast(list.items.len),
        .role = role,
        .text = try session.allocator.dupe(u8, text),
        .mode = mode,
        .result_kind = kind,
    });
    session.history = try list.toOwnedSlice();
}

fn buildTransition(allocator: std.mem.Allocator, from: ConversationMode, to: ConversationMode, result: *const response_engine.ResponseResult, deep_blocked_by_ambiguity: bool) !?ModeTransition {
    if (from == to and !result.escalated and !deep_blocked_by_ambiguity) return null;
    const reason = if (deep_blocked_by_ambiguity)
        try allocator.dupe(u8, "deep execution blocked by unresolved ambiguity")
    else if (result.escalation_reason) |reason|
        try std.fmt.allocPrint(allocator, "{s}", .{@tagName(reason)})
    else
        try allocator.dupe(u8, "natural mode selection");
    return .{ .from = from, .to = to, .reason = reason };
}

fn recordFeedback(session: *const Session, paths: *const shards.Paths, text: []const u8) !usize {
    return feedback.recordUserFeedback(session.allocator, paths, .{
        .text = text,
        .related_artifact = if (session.active_artifacts.len > 0) session.active_artifacts[0].id else "",
        .related_intent = if (session.current_intent) |intent| intent.normalized_text else "",
        .related_candidate = if (session.last_result) |last| @tagName(last.selected_mode) else "",
        .timestamp = "deterministic:conversation",
        .provenance = "conversation_feedback_event",
    });
}

fn resolveContextTarget(session: *const Session, message: []const u8) ?[]const u8 {
    const needs_context = containsIgnoreCase(message, "this") or containsIgnoreCase(message, "that") or containsIgnoreCase(message, " it") or containsIgnoreCase(message, "previous result");
    if (!needs_context) return null;
    if (containsIgnoreCase(message, "previous result")) {
        if (session.last_result) |last| {
            if (last.artifact_path) |path| return path;
        }
    }
    if (session.active_artifacts.len == 1) return session.active_artifacts[0].id;
    if (session.active_artifacts.len > 0) return session.active_artifacts[session.active_artifacts.len - 1].id;
    return null;
}

fn conversationModeFromResponse(mode: response_engine.ResponseMode, stop: response_engine.StopReason) ConversationMode {
    if (stop == .unresolved or stop == .budget) return .unresolved;
    return switch (mode) {
        .draft_mode => .draft,
        .fast_path, .auto_path => .fast,
        .deep_path => .deep,
    };
}

fn wantsDeep(normalized: []const u8) bool {
    return contains(normalized, "verify this") or contains(normalized, "verify ") or contains(normalized, "apply the fix") or contains(normalized, "apply patch") or contains(normalized, "yes do that") or contains(normalized, "go ahead") or contains(normalized, "do that");
}

fn isQuestionOrPlanning(normalized: []const u8) bool {
    return contains(normalized, "?") or contains(normalized, "explain") or contains(normalized, "why") or contains(normalized, "what ") or contains(normalized, "how ") or contains(normalized, "plan") or contains(normalized, "options");
}

fn isFeedback(text: []const u8) bool {
    return containsIgnoreCase(text, "that worked") or containsIgnoreCase(text, "this worked") or containsIgnoreCase(text, "that's wrong") or containsIgnoreCase(text, "that is wrong") or containsIgnoreCase(text, "i meant");
}

fn selectsAmbiguity(normalized: []const u8, session: *const Session) bool {
    return selectedAmbiguityText(normalized, session) != null;
}

fn selectedAmbiguityText(normalized: []const u8, session: *const Session) ?[]const u8 {
    if (session.pending_ambiguities.len == 0) return null;
    const options = session.pending_ambiguities[0].options;
    if ((std.mem.eql(u8, normalized, "a") or contains(normalized, "readability") or contains(normalized, "readable")) and options.len > 0) return options[0];
    if ((std.mem.eql(u8, normalized, "b") or contains(normalized, "performance")) and options.len > 1) return options[1];
    if ((std.mem.eql(u8, normalized, "c") or contains(normalized, "bug")) and options.len > 2) return options[2];
    return null;
}

fn clearLastResult(session: *Session) void {
    if (session.last_result) |*value| value.deinit(session.allocator);
    session.last_result = null;
}

fn clearPending(session: *Session) void {
    for (session.pending_ambiguities) |*item| item.deinit(session.allocator);
    session.allocator.free(session.pending_ambiguities);
    session.pending_ambiguities = &.{};
    for (session.pending_obligations) |*item| item.deinit(session.allocator);
    session.allocator.free(session.pending_obligations);
    session.pending_obligations = &.{};
}

fn artifactIds(artifacts: []ArtifactRef) []const []const u8 {
    _ = artifacts;
    return &.{};
}

fn resolveConversationShardMetadata(allocator: std.mem.Allocator, project_shard: ?[]const u8) !shards.OwnedMetadata {
    return if (project_shard) |value| try shards.resolveProjectMetadata(allocator, value) else try shards.resolveDefaultProjectMetadata(allocator);
}

fn autoSessionId(allocator: std.mem.Allocator, repo_root: []const u8, shard_kind: shards.Kind, shard_id: []const u8) ![]u8 {
    var hasher = std.hash.Fnv1a_64.init();
    hasher.update(FORMAT_VERSION);
    hasher.update(repo_root);
    hasher.update(@tagName(shard_kind));
    hasher.update(shard_id);
    return std.fmt.allocPrint(allocator, "conv-{x:0>16}", .{hasher.final()});
}

fn sanitizeSessionId(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, raw, " \r\n\t/");
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    for (if (trimmed.len == 0) "conversation" else trimmed) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_') {
            try out.append(std.ascii.toLower(byte));
        } else {
            try out.append('_');
        }
    }
    if (out.items.len == 0) try out.appendSlice("conversation");
    return out.toOwnedSlice();
}

fn sessionPath(allocator: std.mem.Allocator, paths: *const shards.Paths, session_id: []const u8) ![]u8 {
    const root = try std.fs.path.join(allocator, &.{ paths.task_sessions_root_abs_path, "conversations" });
    defer allocator.free(root);
    const file_name = try std.fmt.allocPrint(allocator, "{s}.json", .{session_id});
    defer allocator.free(file_name);
    return std.fs.path.join(allocator, &.{ root, file_name });
}

fn cloneMessages(allocator: std.mem.Allocator, source: []const Message) ![]Message {
    const out = try allocator.alloc(Message, source.len);
    errdefer allocator.free(out);
    for (source, 0..) |item, idx| {
        out[idx] = .{ .index = item.index, .role = item.role, .text = try allocator.dupe(u8, item.text), .mode = item.mode, .result_kind = item.result_kind };
    }
    return out;
}

fn cloneArtifacts(allocator: std.mem.Allocator, source: []const ArtifactRef) ![]ArtifactRef {
    const out = try allocator.alloc(ArtifactRef, source.len);
    errdefer allocator.free(out);
    for (source, 0..) |item, idx| {
        out[idx] = .{ .id = try allocator.dupe(u8, item.id), .kind = try allocator.dupe(u8, item.kind), .source = try allocator.dupe(u8, item.source) };
    }
    return out;
}

fn cloneIntentState(allocator: std.mem.Allocator, item: IntentState) !IntentState {
    return .{
        .raw_text = try allocator.dupe(u8, item.raw_text),
        .normalized_text = try allocator.dupe(u8, item.normalized_text),
        .status = item.status,
        .selected_mode = item.selected_mode,
        .trace = try allocator.dupe(u8, item.trace),
    };
}

fn cloneLastResult(allocator: std.mem.Allocator, item: LastResult) !LastResult {
    return .{
        .kind = item.kind,
        .selected_mode = item.selected_mode,
        .stop_reason = item.stop_reason,
        .summary = try allocator.dupe(u8, item.summary),
        .artifact_path = if (item.artifact_path) |value| try allocator.dupe(u8, value) else null,
    };
}

fn cloneCorrectionProjection(allocator: std.mem.Allocator, item: CorrectionProjection) !CorrectionProjection {
    return .{
        .correction_count = item.correction_count,
        .correction_refs = try cloneStringList(allocator, item.correction_refs),
        .correction_kinds = try cloneStringList(allocator, item.correction_kinds),
        .contradicted_refs = try cloneStringList(allocator, item.contradicted_refs),
        .evidence_refs = try cloneStringList(allocator, item.evidence_refs),
        .negative_knowledge_candidate_refs = try cloneStringList(allocator, item.negative_knowledge_candidate_refs),
        .trust_decay_candidate_refs = try cloneStringList(allocator, item.trust_decay_candidate_refs),
        .user_visible_summaries = try cloneStringList(allocator, item.user_visible_summaries),
        .non_authorizing = item.non_authorizing,
        .projection_complete = item.projection_complete,
    };
}

fn cloneNegativeKnowledgeInfluenceProjection(allocator: std.mem.Allocator, item: NegativeKnowledgeInfluenceProjection) !NegativeKnowledgeInfluenceProjection {
    return .{
        .influence_count = item.influence_count,
        .record_ids = try cloneStringList(allocator, item.record_ids),
        .influence_kinds = try cloneStringList(allocator, item.influence_kinds),
        .affected_hypotheses = try cloneStringList(allocator, item.affected_hypotheses),
        .affected_routes = try cloneStringList(allocator, item.affected_routes),
        .affected_verifier_handoffs = try cloneStringList(allocator, item.affected_verifier_handoffs),
        .applied_records = try cloneStringList(allocator, item.applied_records),
        .proposed_candidates = try cloneStringList(allocator, item.proposed_candidates),
        .trust_decay_candidates = try cloneStringList(allocator, item.trust_decay_candidates),
        .triage_penalty_count = item.triage_penalty_count,
        .verifier_requirement_count = item.verifier_requirement_count,
        .suppression_count = item.suppression_count,
        .routing_warning_count = item.routing_warning_count,
        .trust_decay_candidate_count = item.trust_decay_candidate_count,
        .non_authorizing = item.non_authorizing,
        .projection_complete = item.projection_complete,
    };
}

fn cloneStringList(allocator: std.mem.Allocator, source: []const []u8) ![][]u8 {
    if (source.len == 0) return &.{};
    var out = try allocator.alloc([]u8, source.len);
    errdefer {
        for (out) |item| allocator.free(item);
        allocator.free(out);
    }
    for (source, 0..) |item, idx| out[idx] = try allocator.dupe(u8, item);
    return out;
}

fn cloneConstStringList(allocator: std.mem.Allocator, source: []const []const u8) ![][]u8 {
    if (source.len == 0) return &.{};
    var out = try allocator.alloc([]u8, source.len);
    errdefer {
        for (out) |item| allocator.free(item);
        allocator.free(out);
    }
    for (source, 0..) |item, idx| out[idx] = try allocator.dupe(u8, item);
    return out;
}

fn freeStringList(allocator: std.mem.Allocator, source: [][]u8) void {
    for (source) |item| allocator.free(item);
    allocator.free(source);
}

fn cloneAmbiguities(allocator: std.mem.Allocator, source: []const PendingAmbiguity) ![]PendingAmbiguity {
    const out = try allocator.alloc(PendingAmbiguity, source.len);
    errdefer allocator.free(out);
    for (source, 0..) |item, idx| {
        var options = try allocator.alloc([]u8, item.options.len);
        errdefer allocator.free(options);
        for (item.options, 0..) |option, opt_idx| options[opt_idx] = try allocator.dupe(u8, option);
        out[idx] = .{
            .label = try allocator.dupe(u8, item.label),
            .question = try allocator.dupe(u8, item.question),
            .options = options,
        };
    }
    return out;
}

fn cloneObligations(allocator: std.mem.Allocator, source: []const PendingObligation) ![]PendingObligation {
    const out = try allocator.alloc(PendingObligation, source.len);
    errdefer allocator.free(out);
    for (source, 0..) |item, idx| {
        out[idx] = .{ .id = try allocator.dupe(u8, item.id), .label = try allocator.dupe(u8, item.label), .required_for = try allocator.dupe(u8, item.required_for) };
    }
    return out;
}

fn readOwnedFile(allocator: std.mem.Allocator, abs_path: []const u8, max_bytes: usize) ![]u8 {
    const handle = try sys.openForRead(allocator, abs_path);
    defer sys.closeFile(handle);
    const size = try sys.getFileSize(handle);
    if (size > max_bytes) return error.ConversationSessionTooLarge;
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

fn fileExists(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

fn lowercaseAscii(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, text.len);
    for (text, 0..) |byte, idx| out[idx] = std.ascii.toLower(byte);
    return out;
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var idx: usize = 0;
    while (idx + needle.len <= haystack.len) : (idx += 1) {
        var matched = true;
        for (needle, 0..) |byte, offset| {
            if (std.ascii.toLower(haystack[idx + offset]) != std.ascii.toLower(byte)) {
                matched = false;
                break;
            }
        }
        if (matched) return true;
    }
    return false;
}

test "conversation session refines vague intent and blocks deep execution until ambiguity resolves" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const project = "conversation-ambiguity-test";
    try resetConversationTestShard(allocator, project);

    var first = try turn(allocator, .{
        .repo_root = root,
        .project_shard = project,
        .session_id = "ux",
        .message = "this code is messy",
        .context_artifacts = &.{"src/main.zig"},
    });
    defer first.deinit();
    try std.testing.expect(first.session.pending_ambiguities.len > 0);
    try std.testing.expect(first.session.last_result.?.kind == .draft or first.session.last_result.?.kind == .unresolved);

    var second = try turn(allocator, .{
        .repo_root = root,
        .project_shard = project,
        .session_id = "ux",
        .message = "verify this",
    });
    defer second.deinit();
    try std.testing.expectEqual(ResultKind.draft, second.session.last_result.?.kind);
    try std.testing.expect(second.session.pending_ambiguities.len > 0);
}

test "conversation session carries artifact context, feedback, and deterministic replay" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const project = "conversation-replay-feedback-test";
    try resetConversationTestShard(allocator, project);

    var first = try turn(allocator, .{
        .repo_root = root,
        .project_shard = project,
        .session_id = "ux",
        .message = "explain this",
        .context_artifacts = &.{"src/main.zig"},
    });
    defer first.deinit();
    try std.testing.expect(first.session.active_artifacts.len == 1);
    try std.testing.expect(std.mem.eql(u8, first.session.active_artifacts[0].id, "src/main.zig"));

    var second = try turn(allocator, .{
        .repo_root = root,
        .project_shard = project,
        .session_id = "ux",
        .message = "that worked",
    });
    defer second.deinit();
    try std.testing.expectEqual(ResultKind.feedback, second.session.last_result.?.kind);

    var loaded = try load(allocator, project, "ux");
    defer loaded.deinit();
    try std.testing.expectEqual(second.session.history.len, loaded.history.len);
    try std.testing.expectEqual(second.session.active_artifacts.len, loaded.active_artifacts.len);
    const json1 = try renderJson(allocator, &second.session);
    defer allocator.free(json1);
    const json2 = try renderJson(allocator, &loaded);
    defer allocator.free(json2);
    try std.testing.expect(std.mem.eql(u8, json1, json2));
}

test "conversation session preserves bounded correction and negative knowledge projection refs" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const project = "conversation-correction-projection-test";
    try resetConversationTestShard(allocator, project);

    var session = try create(allocator, .{
        .repo_root = root,
        .project_shard = project,
        .session_id = "ux",
        .context_artifacts = &.{"src/main.zig"},
    });
    defer session.deinit();

    var gi = try intent_grounding.ground(allocator, "verify src/main.zig", .{ .context_target = "src/main.zig" });
    defer gi.deinit();
    var response = try response_engine.execute(allocator, &gi, .{ .mode = .deep_path });
    defer response.deinit();

    var event = correction_hooks.CorrectionEvent{
        .allocator = allocator,
        .id = try allocator.dupe(u8, "correction:session:1"),
        .correction_kind = .hypothesis_contradicted,
        .source_ref = try allocator.dupe(u8, "test:source"),
        .contradicted_ref = try allocator.dupe(u8, "hypothesis:session"),
        .contradicting_evidence_ref = try allocator.dupe(u8, "verifier:evidence"),
        .previous_state = try allocator.dupe(u8, "assumed_supported"),
        .updated_state = try allocator.dupe(u8, "contradicted"),
        .user_visible_summary = try allocator.dupe(u8, "Correction recorded: verifier evidence contradicted the previous hypothesis."),
        .non_authorizing = true,
        .trace = try allocator.dupe(u8, "session projection test"),
    };
    defer event.deinit();
    var candidate = correction_hooks.NegativeKnowledgeCandidate{
        .allocator = allocator,
        .id = try allocator.dupe(u8, "nk:session:1"),
        .correction_event_id = try allocator.dupe(u8, event.id),
        .candidate_kind = .failed_hypothesis,
        .scope = try allocator.dupe(u8, "hypothesis:session"),
        .condition = try allocator.dupe(u8, "contradicted"),
        .evidence_ref = try allocator.dupe(u8, "verifier:evidence"),
    };
    defer candidate.deinit();
    try response_engine.attachCorrectionEvents(allocator, &response, &.{event}, &.{candidate});
    try replaceCorrectionProjections(&session, &response);

    try std.testing.expectEqual(@as(usize, 1), session.last_corrections.?.correction_count);
    try std.testing.expectEqual(@as(usize, 1), session.correction_refs.len);
    try std.testing.expectEqual(@as(usize, 1), session.negative_knowledge_candidate_refs.len);
    try std.testing.expect(session.last_corrections.?.non_authorizing);

    const reply = try renderConversationReply(allocator, &session, null);
    defer allocator.free(reply);
    try std.testing.expect(std.mem.indexOf(u8, reply, "[correction_recorded]") != null);
    try std.testing.expect(std.mem.indexOf(u8, reply, "review_required=true") != null);

    try save(&session);
    var loaded = try load(allocator, project, "ux");
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 1), loaded.correction_refs.len);
    try std.testing.expectEqual(@as(usize, 1), loaded.negative_knowledge_candidate_refs.len);
    try std.testing.expect(loaded.last_corrections.?.projection_complete);
}

fn resetConversationTestShard(allocator: std.mem.Allocator, shard_id: []const u8) !void {
    var shard_metadata = try shards.resolveProjectMetadata(allocator, shard_id);
    defer shard_metadata.deinit();
    var paths = try shards.resolvePaths(allocator, shard_metadata.metadata);
    defer paths.deinit();
    const conversations = try std.fs.path.join(allocator, &.{ paths.task_sessions_root_abs_path, "conversations" });
    defer allocator.free(conversations);
    deleteTreeIfExistsAbsolute(conversations) catch {};
    const feedback_root = try std.fs.path.join(allocator, &.{ paths.root_abs_path, "feedback" });
    defer allocator.free(feedback_root);
    deleteTreeIfExistsAbsolute(feedback_root) catch {};
}

fn deleteTreeIfExistsAbsolute(path: []const u8) !void {
    std.fs.deleteTreeAbsolute(path) catch |err| switch (err) {
        error.FileNotFound => {},
        error.NotDir => std.fs.deleteFileAbsolute(path) catch |delete_err| switch (delete_err) {
            error.FileNotFound => {},
            else => return delete_err,
        },
        else => return err,
    };
}
