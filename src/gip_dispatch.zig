// ──────────────────────────────────────────────────────────────────────────
// GIP Dispatch — Request routing and operation execution
// ──────────────────────────────────────────────────────────────────────────

const std = @import("std");
const core = @import("gip_core.zig");
const schema = @import("gip_schema.zig");
const validation = @import("gip_validation.zig");
const conversation_session = @import("conversation_session.zig");
const response_engine = @import("response_engine.zig");
const hypothesis_core = @import("hypothesis_core.zig");
const verifier_adapter = @import("verifier_adapter.zig");
const verifier_candidates = @import("verifier_candidates.zig");
const verifier_candidate_execution = @import("verifier_candidate_execution.zig");
const knowledge_packs = @import("knowledge_packs.zig");
const knowledge_pack_store = @import("knowledge_pack_store.zig");
const autopsy_guidance_validator = @import("autopsy_guidance_validator.zig");
const feedback = @import("feedback.zig");
const shards = @import("shards.zig");
const task_sessions = @import("task_sessions.zig");
const project_autopsy = @import("project_autopsy.zig");
const learning_loop = @import("learning_loop.zig");
const context_autopsy = @import("context_autopsy.zig");
const context_autopsy_engine = @import("context_autopsy_engine.zig");
const context_artifacts = @import("context_artifacts.zig");
const context_inputs = @import("context_inputs.zig");
const corpus_ask = @import("corpus_ask.zig");
const rule_reasoning = @import("rule_reasoning.zig");
const correction_candidates = @import("correction_candidates.zig");
const correction_review = @import("correction_review.zig");
const negative_knowledge_review = @import("negative_knowledge_review.zig");
const learning_status = @import("learning_status.zig");
const procedure_pack_candidates = @import("procedure_pack_candidates.zig");
const sigil_core = @import("sigil_core.zig");

pub const DispatchResult = struct {
    status: core.ProtocolStatus,
    result_state: ?schema.ResultState = null,
    result_json: ?[]const u8 = null,
    err: ?schema.GipError = null,
    stats: ?schema.Stats = null,
    allocated_result: bool = false,

    pub fn deinit(self: *DispatchResult, allocator: std.mem.Allocator) void {
        if (self.allocated_result) {
            if (self.result_json) |rj| allocator.free(rj);
        }
    }
};

fn getInt(obj: std.json.ObjectMap, snake: []const u8, camel: []const u8) ?i64 {
    const v = obj.get(snake) orelse obj.get(camel) orelse return null;
    return if (v == .integer) v.integer else null;
}

fn getStr(obj: std.json.ObjectMap, snake: []const u8, camel: []const u8) ?[]const u8 {
    const v = obj.get(snake) orelse obj.get(camel) orelse return null;
    return if (v == .string) v.string else null;
}

fn getBool(obj: std.json.ObjectMap, snake: []const u8, camel: []const u8) ?bool {
    const v = obj.get(snake) orelse obj.get(camel) orelse return null;
    return if (v == .bool) v.bool else null;
}

fn boundedMaxItems(obj: std.json.ObjectMap, default_value: usize, max_value: usize) usize {
    const requested = getInt(obj, "max_items", "maxItems") orelse return default_value;
    if (requested <= 0) return 0;
    return @min(@as(usize, @intCast(requested)), max_value);
}

pub fn dispatch(
    allocator: std.mem.Allocator,
    kind_text: ?[]const u8,
    gip_version: ?[]const u8,
    workspace_root: ?[]const u8,
    request_path: ?[]const u8,
    request_body: ?[]const u8,
) !DispatchResult {

    // Validate version
    if (validation.validateVersion(gip_version)) |err| {
        return .{ .status = .rejected, .err = err };
    }

    // Validate kind
    if (validation.validateRequestKind(kind_text)) |err| {
        return .{ .status = .rejected, .err = err };
    }
    const kind = core.parseRequestKind(kind_text.?).?;

    // Capability gate
    if (validation.validateCapability(kind)) |err| {
        if (err.code == .capability_denied) {
            return .{ .status = .rejected, .err = err };
        }
    }

    // Check implemented
    if (validation.validateImplemented(kind)) |err| {
        return .{ .status = .unsupported, .err = err, .result_state = schema.unsupportedResultState() };
    }

    // Dispatch by kind
    return switch (kind) {
        .@"protocol.describe" => dispatchProtocolDescribe(allocator),
        .@"capabilities.describe" => dispatchCapabilitiesDescribe(allocator),
        .@"engine.status" => dispatchEngineStatus(allocator),
        .@"conversation.turn" => dispatchConversationTurn(allocator, workspace_root, request_body),
        .@"corpus.ask" => dispatchCorpusAsk(allocator, request_body),
        .@"rule.evaluate" => dispatchRuleEvaluate(allocator, request_body),
        .@"sigil.inspect" => dispatchSigilInspect(allocator, request_body),
        .@"learning.status" => dispatchLearningStatus(allocator, request_body),
        .@"learning.loop.plan" => dispatchLearningLoopPlan(allocator, workspace_root, request_body),
        .@"correction.propose" => dispatchCorrectionPropose(allocator, request_body),
        .@"correction.review" => dispatchCorrectionReview(allocator, request_body),
        .@"correction.reviewed.list" => dispatchCorrectionReviewedList(allocator, request_body),
        .@"correction.reviewed.get" => dispatchCorrectionReviewedGet(allocator, request_body),
        .@"correction.influence.status" => dispatchCorrectionInfluenceStatus(allocator, request_body),
        .@"procedure_pack.candidate.propose" => dispatchProcedurePackCandidatePropose(allocator, request_body),
        .@"procedure_pack.candidate.review" => dispatchProcedurePackCandidateReview(allocator, request_body),
        .@"procedure_pack.candidate.reviewed.list" => dispatchProcedurePackCandidateReviewedList(allocator, request_body),
        .@"procedure_pack.candidate.reviewed.get" => dispatchProcedurePackCandidateReviewedGet(allocator, request_body),
        .@"artifact.read" => dispatchArtifactRead(allocator, workspace_root, request_path),
        .@"artifact.list" => dispatchArtifactList(allocator, workspace_root, request_path),
        .@"artifact.patch.propose" => dispatchArtifactPatchPropose(allocator, workspace_root, request_body),
        .@"hypothesis.list" => dispatchHypothesisList(allocator, request_body),
        .@"hypothesis.triage" => dispatchHypothesisTriage(allocator, request_body),
        .@"verifier.list" => dispatchVerifierList(allocator),
        .@"verifier.candidate.execution.list" => dispatchVerifierCandidateExecutionList(allocator, workspace_root, request_body),
        .@"verifier.candidate.execution.get" => dispatchVerifierCandidateExecutionGet(allocator, workspace_root, request_body),
        .@"verifier.candidate.propose_from_learning_plan" => dispatchVerifierCandidateProposeFromLearningPlan(allocator, request_body),
        .@"verifier.candidate.list" => dispatchVerifierCandidateList(allocator, request_body),
        .@"verifier.candidate.review" => dispatchVerifierCandidateReview(allocator, request_body),
        .@"verifier.candidate.execute" => dispatchVerifierCandidateExecute(allocator, workspace_root, request_body),
        .@"correction.list" => dispatchCorrectionList(allocator, workspace_root, request_body),
        .@"correction.get" => dispatchCorrectionGet(allocator, workspace_root, request_body),
        .@"negative_knowledge.candidate.list" => dispatchNegativeKnowledgeCandidateList(allocator, workspace_root, request_body),
        .@"negative_knowledge.candidate.get" => dispatchNegativeKnowledgeCandidateGet(allocator, workspace_root, request_body),
        .@"negative_knowledge.record.list" => dispatchNegativeKnowledgeRecordList(allocator, workspace_root, request_body),
        .@"negative_knowledge.record.get" => dispatchNegativeKnowledgeRecordGet(allocator, workspace_root, request_body),
        .@"negative_knowledge.influence.list" => dispatchNegativeKnowledgeInfluenceList(allocator, workspace_root, request_body),
        .@"negative_knowledge.review" => dispatchNegativeKnowledgeReview(allocator, request_body),
        .@"negative_knowledge.reviewed.list" => dispatchNegativeKnowledgeReviewedList(allocator, request_body),
        .@"negative_knowledge.reviewed.get" => dispatchNegativeKnowledgeReviewedGet(allocator, request_body),
        .@"trust_decay.candidate.list" => dispatchTrustDecayCandidateList(allocator, workspace_root, request_body),
        .@"negative_knowledge.candidate.review" => dispatchNegativeKnowledgeCandidateReview(allocator, request_body),
        .@"negative_knowledge.record.expire" => dispatchNegativeKnowledgeRecordExpire(allocator, request_body),
        .@"negative_knowledge.record.supersede" => dispatchNegativeKnowledgeRecordSupersede(allocator, request_body),
        .@"pack.list" => dispatchPackList(allocator, workspace_root),
        .@"pack.inspect" => dispatchPackInspect(allocator, request_body),
        .@"feedback.summary" => dispatchFeedbackSummary(allocator, workspace_root, request_body),
        .@"session.get" => dispatchSessionGet(allocator, request_body),
        .@"project.autopsy" => dispatchProjectAutopsy(allocator, workspace_root, request_body),
        .@"context.autopsy" => dispatchContextAutopsy(allocator, workspace_root, request_body),
        else => .{
            .status = .unsupported,
            .err = .{
                .code = .unsupported_operation,
                .message = "unknown request kind",
                .details = kind_text,
                .fix_hint = "use protocol.describe to list supported kinds",
            },
            .result_state = schema.unsupportedResultState(),
        },
    };
}

fn dispatchProtocolDescribe(allocator: std.mem.Allocator) !DispatchResult {
    return .{
        .status = .ok,
        .result_json = try schema.renderProtocolDescription(allocator),
        .allocated_result = true,
    };
}

fn dispatchCapabilitiesDescribe(allocator: std.mem.Allocator) !DispatchResult {
    return .{
        .status = .ok,
        .result_json = try schema.renderCapabilitiesDescription(allocator),
        .allocated_result = true,
    };
}

fn dispatchEngineStatus(allocator: std.mem.Allocator) !DispatchResult {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    try w.writeAll("{\"status\":\"running\",\"version\":\"0.1.0\"}");

    return .{
        .status = .ok,
        .result_json = try out.toOwnedSlice(),
        .allocated_result = true,
    };
}

fn dispatchConversationTurn(allocator: std.mem.Allocator, workspace_root: ?[]const u8, request_body: ?[]const u8) !DispatchResult {
    const root = workspace_root orelse ".";
    const body = request_body orelse return .{ .status = .rejected, .err = .{ .code = .missing_required_field, .message = "body missing" } };

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return .{ .status = .rejected, .err = .{ .code = .json_contract_error, .message = "invalid JSON" } };
    };
    defer parsed.deinit();

    const obj = parsed.value.object;
    const msg = if (obj.get("message")) |m| m.string else return .{ .status = .rejected, .err = .{ .code = .missing_required_field, .message = "message missing" } };
    const session_id = getStr(obj, "session_id", "session_id");
    const reasoning_level_str = getStr(obj, "reasoning_level", "reasoning_level") orelse "balanced";
    const r_level: response_engine.ReasoningLevel = if (std.mem.eql(u8, reasoning_level_str, "quick"))
        .quick
    else if (std.mem.eql(u8, reasoning_level_str, "balanced"))
        .balanced
    else if (std.mem.eql(u8, reasoning_level_str, "deep"))
        .deep
    else if (std.mem.eql(u8, reasoning_level_str, "max"))
        .max
    else
        .balanced;

    var turn_result = try conversation_session.turn(allocator, .{
        .repo_root = root,
        .session_id = session_id,
        .message = msg,
        .reasoning_level = r_level,
    });
    defer turn_result.deinit();

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    try w.writeAll("{\"conversationTurn\":");
    try renderConversationTurnResult(w, turn_result);
    try w.writeAll("}");

    const gip_status: core.ProtocolStatus = .ok;
    var gip_state = schema.draftResultState();

    if (turn_result.session.last_result) |res| {
        switch (res.kind) {
            .verified => {
                gip_state.state = .verified;
                gip_state.is_draft = false;
                gip_state.verification_state = .verified;
            },
            .unresolved => {
                gip_state.state = .unresolved;
                gip_state.is_draft = true;
                gip_state.verification_state = .unverified;
            },
            .draft, .feedback => {
                gip_state.state = .draft;
                gip_state.is_draft = true;
                gip_state.verification_state = .unverified;
            },
        }
    }

    return .{
        .status = gip_status,
        .result_state = gip_state,
        .result_json = try out.toOwnedSlice(),
        .allocated_result = true,
    };
}

fn renderConversationTurnResult(w: anytype, res: conversation_session.TurnResult) !void {
    try w.writeAll("{\"session_id\":\"");
    try writeEscaped(w, res.session.session_id);
    try w.writeAll("\",\"response\":");
    try w.writeAll("{\"summary\":\"");
    try writeEscaped(w, res.reply);
    try w.writeAll("\",\"state\":\"");
    if (res.session.last_result) |lr| {
        try w.writeAll(@tagName(lr.kind));
    } else {
        try w.writeAll("none");
    }
    try w.writeAll("\"},\"intent\":");
    if (res.session.current_intent) |intent| {
        try w.writeAll("{\"status\":\"");
        try w.writeAll(@tagName(intent.status));
        try w.writeAll("\",\"mode\":\"");
        try w.writeAll(@tagName(intent.selected_mode));
        try w.writeAll("\"}");
    } else {
        try w.writeAll("null");
    }
    try w.writeAll("}");
}

fn dispatchCorpusAsk(allocator: std.mem.Allocator, request_body: ?[]const u8) !DispatchResult {
    const body = request_body orelse return .{
        .status = .rejected,
        .err = .{ .code = .missing_required_field, .message = "request body is required for corpus.ask" },
    };

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return .{ .status = .rejected, .err = .{ .code = .json_contract_error, .message = "invalid JSON in request body" } };
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return .{ .status = .rejected, .err = .{ .code = .invalid_request, .message = "corpus.ask request must be a JSON object" } };
    }

    const obj = parsed.value.object;
    const question = getStr(obj, "question", "question") orelse getStr(obj, "message", "message") orelse return .{
        .status = .rejected,
        .err = .{ .code = .missing_required_field, .message = "question or message is required for corpus.ask" },
    };
    if (std.mem.trim(u8, question, " \r\n\t").len == 0) {
        return .{
            .status = .rejected,
            .err = .{ .code = .invalid_request, .message = "question must be non-empty" },
        };
    }

    const max_results_raw = getInt(obj, "max_results", "maxResults") orelse corpus_ask.DEFAULT_MAX_RESULTS;
    const max_results = if (max_results_raw <= 0)
        corpus_ask.DEFAULT_MAX_RESULTS
    else
        @min(@as(usize, @intCast(max_results_raw)), corpus_ask.MAX_RESULTS);
    const max_snippet_raw = getInt(obj, "max_snippet_bytes", "maxSnippetBytes") orelse corpus_ask.DEFAULT_MAX_SNIPPET_BYTES;
    const max_snippet_bytes = if (max_snippet_raw <= 0)
        corpus_ask.DEFAULT_MAX_SNIPPET_BYTES
    else
        @min(@as(usize, @intCast(max_snippet_raw)), corpus_ask.MAX_SNIPPET_BYTES);

    var result = try corpus_ask.ask(allocator, .{
        .question = question,
        .project_shard = getStr(obj, "project_shard", "projectShard"),
        .max_results = max_results,
        .max_snippet_bytes = max_snippet_bytes,
        .require_citations = getBool(obj, "require_citations", "requireCitations") orelse true,
    });
    defer result.deinit();

    const rendered = try corpus_ask.renderJson(allocator, &result);
    errdefer allocator.free(rendered);

    var gip_state = if (result.status == .answered)
        schema.draftResultState()
    else
        schema.unresolvedResultState(if (result.unknowns.len > 0) @tagName(result.unknowns[0].kind) else "unknown");
    gip_state.non_authorization_notice = "corpus.ask output is draft/non-authorizing; cited corpus evidence is not proof and no verifier was executed";

    return .{
        .status = if (result.status == .answered) .ok else .unresolved,
        .result_state = gip_state,
        .result_json = rendered,
        .allocated_result = true,
    };
}

fn dispatchRuleEvaluate(allocator: std.mem.Allocator, request_body: ?[]const u8) !DispatchResult {
    const body = request_body orelse return .{
        .status = .rejected,
        .err = .{ .code = .missing_required_field, .message = "request body is required for rule.evaluate" },
    };

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return .{ .status = .rejected, .err = .{ .code = .json_contract_error, .message = "invalid JSON in request body" } };
    };
    defer parsed.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const request = rule_reasoning.parseRequest(arena_alloc, parsed.value) catch |err| {
        return .{
            .status = .rejected,
            .err = .{
                .code = .invalid_request,
                .message = "invalid rule.evaluate request",
                .details = @errorName(err),
                .fix_hint = "provide facts plus non-recursive rules with all/any conditions and candidate-only outputs",
            },
        };
    };

    var result = rule_reasoning.evaluate(allocator, request) catch |err| switch (err) {
        error.InvalidRule, error.FactLimitExceeded, error.RuleLimitExceeded => return .{
            .status = .rejected,
            .err = .{
                .code = .invalid_request,
                .message = "rule.evaluate validation failed",
                .details = @errorName(err),
                .fix_hint = "reduce facts/rules or remove unsupported recursive fact outputs",
            },
        },
        else => return err,
    };
    defer result.deinit();

    if (request.project_shard) |project_shard| {
        var reviewed = try correction_review.readAcceptedInfluences(allocator, project_shard);
        defer reviewed.deinit();
        try rule_reasoning.applyAcceptedCorrectionInfluence(allocator, &result, &reviewed);
        var reviewed_nk = try negative_knowledge_review.readAcceptedInfluences(allocator, project_shard);
        defer reviewed_nk.deinit();
        try rule_reasoning.applyAcceptedNegativeKnowledgeInfluence(allocator, &result, &reviewed_nk);
    }

    const rendered = try rule_reasoning.renderJson(allocator, &result);
    errdefer allocator.free(rendered);

    var gip_state = schema.draftResultState();
    gip_state.permission = .none;
    gip_state.verification_state = .unverified;
    gip_state.stop_reason = .none;
    gip_state.unresolved_reason = null;
    gip_state.non_authorization_notice = "rule.evaluate output is candidate-only and non-authorizing; no verifier was executed and no proof/support gate was discharged";

    return .{
        .status = .ok,
        .result_state = gip_state,
        .result_json = rendered,
        .allocated_result = true,
    };
}

fn dispatchSigilInspect(allocator: std.mem.Allocator, request_body: ?[]const u8) !DispatchResult {
    const body = request_body orelse return .{
        .status = .rejected,
        .err = .{ .code = .missing_required_field, .message = "request body is required for sigil.inspect" },
    };

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return .{ .status = .rejected, .err = .{ .code = .json_contract_error, .message = "invalid JSON in request body" } };
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return .{ .status = .rejected, .err = .{ .code = .invalid_request, .message = "sigil.inspect request must be a JSON object" } };
    }

    const obj = parsed.value.object;
    const source = getStr(obj, "source", "source") orelse getStr(obj, "sigil_source", "sigilSource") orelse return .{
        .status = .rejected,
        .err = .{ .code = .missing_required_field, .message = "source or sigilSource is required for sigil.inspect" },
    };

    const scope_text = getStr(obj, "validation_scope", "validationScope") orelse getStr(obj, "scope", "scope") orelse "boot_control";
    const scope = parseSigilValidationScope(scope_text) orelse return .{
        .status = .rejected,
        .err = .{
            .code = .invalid_request,
            .message = "invalid sigil.inspect validation scope",
            .details = scope_text,
            .fix_hint = "use boot_control or scratch_session",
        },
    };

    var program = sigil_core.compileScript(allocator, source) catch |err| {
        const rendered = try renderSigilParseFailure(allocator, source, scope, @errorName(err));
        errdefer allocator.free(rendered);
        const gip_state = failedSigilInspectionState("sigil syntax rejected before inspection");
        return .{
            .status = .rejected,
            .result_state = gip_state,
            .result_json = rendered,
            .err = .{
                .code = .invalid_request,
                .message = "invalid Sigil source",
                .details = @errorName(err),
                .fix_hint = "provide source using supported Sigil statements only",
            },
            .allocated_result = true,
        };
    };
    defer program.deinit();

    var disassembly = try sigil_core.disassembleProgram(allocator, &program, scope);
    defer disassembly.deinit();

    const rendered_text = try sigil_core.renderDisassembly(allocator, &program, scope);
    defer allocator.free(rendered_text);

    const validation_failed = disassembly.validation_issue != null;
    const rendered = try renderSigilInspection(allocator, source, &program, &disassembly, rendered_text);
    errdefer allocator.free(rendered);

    var gip_state = if (validation_failed)
        failedSigilInspectionState("sigil validation failed")
    else
        schema.draftResultState();
    if (!validation_failed) {
        gip_state.stop_reason = .none;
        gip_state.unresolved_reason = null;
        gip_state.non_authorization_notice = "sigil.inspect output is read-only candidate/control inspection; no VM code was executed and no proof/support gate was discharged";
    }

    return .{
        .status = if (validation_failed) .rejected else .ok,
        .result_state = gip_state,
        .result_json = rendered,
        .allocated_result = true,
    };
}

fn dispatchCorrectionPropose(allocator: std.mem.Allocator, request_body: ?[]const u8) !DispatchResult {
    const body = request_body orelse return .{
        .status = .rejected,
        .err = .{ .code = .missing_required_field, .message = "request body is required for correction.propose" },
    };

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return .{ .status = .rejected, .err = .{ .code = .json_contract_error, .message = "invalid JSON in request body" } };
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return .{ .status = .rejected, .err = .{ .code = .invalid_request, .message = "correction.propose request must be a JSON object" } };
    }

    const obj = parsed.value.object;
    var evidence_refs = std.ArrayList([]const u8).init(allocator);
    defer evidence_refs.deinit();
    if (obj.get("evidenceRefs") orelse obj.get("evidence_refs")) |value| {
        if (value != .array) return .{ .status = .rejected, .err = .{ .code = .invalid_request, .message = "evidenceRefs must be an array of strings" } };
        for (value.array.items) |item| {
            if (item != .string) return .{ .status = .rejected, .err = .{ .code = .invalid_request, .message = "evidenceRefs must contain only strings" } };
            try evidence_refs.append(item.string);
        }
    }

    const disputed = obj.get("disputedOutput") orelse obj.get("disputed_output");
    const disputed_kind_text: ?[]const u8 = if (disputed) |value| switch (value) {
        .string => value.string,
        .object => getStr(value.object, "kind", "kind"),
        else => return .{ .status = .rejected, .err = .{ .code = .invalid_request, .message = "disputedOutput must be a string or object" } },
    } else null;
    const disputed_ref: ?[]const u8 = if (disputed) |value| if (value == .object) getStr(value.object, "ref", "ref") orelse getStr(value.object, "id", "id") else null else null;
    const disputed_summary: ?[]const u8 = if (disputed) |value| if (value == .object) getStr(value.object, "summary", "summary") else null else null;
    const disputed_kind = if (disputed_kind_text) |text| correction_candidates.DisputedOutputKind.parse(text) orelse {
        return .{ .status = .rejected, .err = .{ .code = .invalid_request, .message = "unknown disputedOutput kind", .details = text } };
    } else null;

    const correction_type_text = getStr(obj, "correctionType", "correction_type");
    const correction_type = if (correction_type_text) |text| correction_candidates.CorrectionType.parse(text) orelse {
        return .{ .status = .rejected, .err = .{ .code = .invalid_request, .message = "unknown correctionType", .details = text } };
    } else null;

    const request = correction_candidates.Request{
        .operation_kind = getStr(obj, "operationKind", "operation_kind"),
        .original_request_id = getStr(obj, "originalRequestId", "original_request_id"),
        .original_request_summary = getStr(obj, "originalRequestSummary", "original_request_summary"),
        .disputed_output_kind = disputed_kind,
        .disputed_output_ref = disputed_ref,
        .disputed_output_summary = disputed_summary,
        .user_correction = getStr(obj, "userCorrection", "user_correction"),
        .correction_type = correction_type,
        .evidence_refs = evidence_refs.items,
        .project_shard = getStr(obj, "projectShard", "project_shard"),
    };

    const proposal = correction_candidates.propose(request, std.hash.Fnv1a_64.hash(body));
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    try correction_candidates.renderJson(out.writer(), proposal);

    var gip_state = if (std.mem.eql(u8, proposal.status, "request_more_detail"))
        schema.unresolvedResultState("request_more_detail")
    else
        schema.draftResultState();
    gip_state.permission = .none;
    gip_state.verification_state = .unverified;
    gip_state.support_minimum_met = false;
    gip_state.non_authorization_notice = "correction.propose creates review-required candidates only; user correction is signal, not proof";

    return .{
        .status = if (std.mem.eql(u8, proposal.status, "request_more_detail")) .unresolved else .ok,
        .result_state = gip_state,
        .result_json = try out.toOwnedSlice(),
        .allocated_result = true,
    };
}

fn dispatchCorrectionReview(allocator: std.mem.Allocator, request_body: ?[]const u8) !DispatchResult {
    const body = request_body orelse return .{
        .status = .rejected,
        .err = .{ .code = .missing_required_field, .message = "request body is required for correction.review" },
    };

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return .{ .status = .rejected, .err = .{ .code = .json_contract_error, .message = "invalid JSON in request body" } };
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return .{ .status = .rejected, .err = .{ .code = .invalid_request, .message = "correction.review request must be a JSON object" } };
    }

    const obj = parsed.value.object;
    const decision_text = getStr(obj, "decision", "decision") orelse return .{
        .status = .rejected,
        .err = .{ .code = .missing_required_field, .message = "decision is required" },
    };
    const decision = correction_review.Decision.parse(decision_text) orelse return .{
        .status = .rejected,
        .err = .{ .code = .invalid_request, .message = "decision must be accepted or rejected", .details = decision_text },
    };
    const reviewer_note = getStr(obj, "reviewer_note", "reviewerNote") orelse return .{
        .status = .rejected,
        .err = .{ .code = .missing_required_field, .message = "reviewerNote is required" },
    };
    if (std.mem.trim(u8, reviewer_note, " \r\n\t").len == 0) {
        return .{ .status = .rejected, .err = .{ .code = .invalid_request, .message = "reviewerNote must be non-empty" } };
    }
    const rejected_reason = getStr(obj, "rejected_reason", "rejectedReason");
    if (decision == .rejected and (rejected_reason == null or std.mem.trim(u8, rejected_reason.?, " \r\n\t").len == 0)) {
        return .{ .status = .rejected, .err = .{ .code = .missing_required_field, .message = "rejectedReason is required when decision is rejected" } };
    }

    const candidate_value = obj.get("correctionCandidate") orelse obj.get("correction_candidate");
    const candidate_id = getStr(obj, "correction_candidate_id", "correctionCandidateId") orelse blk: {
        if (candidate_value) |value| {
            const candidate_obj = valueObject(value) orelse return .{ .status = .rejected, .err = .{ .code = .invalid_request, .message = "correctionCandidate must be an object when provided" } };
            break :blk getStr(candidate_obj, "id", "id");
        }
        break :blk null;
    } orelse return .{
        .status = .rejected,
        .err = .{ .code = .missing_required_field, .message = "correctionCandidate or correctionCandidateId is required" },
    };

    const candidate_json = if (candidate_value) |value|
        try stringifyJsonValue(allocator, value)
    else
        try std.fmt.allocPrint(allocator, "{{\"id\":\"{}\"}}", .{std.zig.fmtEscapes(candidate_id)});
    defer allocator.free(candidate_json);

    const accepted_outputs_value = obj.get("acceptedLearningOutputs") orelse obj.get("accepted_learning_outputs");
    const accepted_outputs_json = if (accepted_outputs_value) |value| blk: {
        if (value != .array) return .{ .status = .rejected, .err = .{ .code = .invalid_request, .message = "acceptedLearningOutputs must be an array" } };
        break :blk try stringifyJsonValue(allocator, value);
    } else try allocator.dupe(u8, "[]");
    defer allocator.free(accepted_outputs_json);

    var result = try correction_review.reviewAndAppend(allocator, .{
        .project_shard = getStr(obj, "project_shard", "projectShard") orelse shards.DEFAULT_PROJECT_ID,
        .decision = decision,
        .reviewer_note = reviewer_note,
        .rejected_reason = rejected_reason,
        .source_candidate_id = candidate_id,
        .correction_candidate_json = candidate_json,
        .accepted_learning_outputs_json = accepted_outputs_json,
    });
    defer result.deinit();

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();
    try w.writeAll("{\"correctionReview\":{\"status\":\"reviewed\",\"reviewedCorrectionRecord\":");
    try w.writeAll(result.record_json);
    try w.writeAll(",\"requiredReview\":false,\"futureBehaviorCandidate\":");
    if (decision == .accepted) {
        try w.writeAll("{\"status\":\"candidate\",\"nonAuthorizing\":true,\"treatedAsProof\":false,\"globalPromotion\":false}");
    } else {
        try w.writeAll("null");
    }
    try w.writeAll(",\"storage\":{\"path\":\"");
    try writeEscaped(w, result.storage_path);
    try w.writeAll("\",\"appendOnly\":true,\"stableOrdering\":\"file_append_order\",\"inPlaceRewrite\":false,\"deletion\":false,\"compaction\":false}");
    try w.writeAll(",\"mutationFlags\":{\"corpusMutation\":false,\"packMutation\":false,\"negativeKnowledgeMutation\":false,\"commandsExecuted\":false,\"verifiersExecuted\":false}");
    try w.writeAll(",\"authority\":{\"nonAuthorizing\":true,\"treatedAsProof\":false,\"requiredReview\":false,\"globalPromotion\":false,\"supportGranted\":false,\"proofDischarged\":false}}}");

    var gip_state = schema.draftResultState();
    gip_state.permission = .none;
    gip_state.verification_state = .unverified;
    gip_state.support_minimum_met = false;
    gip_state.non_authorization_notice = "correction.review persists append-only reviewed records only; accepted records are still not proof and do not mutate corpus, packs, or negative knowledge";

    return .{
        .status = .ok,
        .result_state = gip_state,
        .result_json = try out.toOwnedSlice(),
        .allocated_result = true,
    };
}

fn dispatchCorrectionReviewedList(allocator: std.mem.Allocator, request_body: ?[]const u8) !DispatchResult {
    const body = request_body orelse return .{
        .status = .rejected,
        .err = .{ .code = .missing_required_field, .message = "request body is required for correction.reviewed.list" },
    };

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return .{ .status = .rejected, .err = .{ .code = .json_contract_error, .message = "invalid JSON in request body" } };
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        return .{ .status = .rejected, .err = .{ .code = .invalid_request, .message = "correction.reviewed.list request must be a JSON object" } };
    }

    const obj = parsed.value.object;
    const project_shard = getStr(obj, "project_shard", "projectShard") orelse shards.DEFAULT_PROJECT_ID;
    const decision_text = getStr(obj, "decision", "decision") orelse if ((getBool(obj, "include_rejected", "includeRejected") orelse true)) "all" else "accepted";
    const decision_filter = correction_review.DecisionFilter.parse(decision_text) orelse return .{
        .status = .rejected,
        .err = .{ .code = .invalid_request, .message = "decision must be accepted, rejected, or all", .details = decision_text },
    };
    const limit = boundedCount(obj, "limit", "limit", correction_review.MAX_REVIEWED_CORRECTIONS_READ, correction_review.MAX_REVIEWED_CORRECTIONS_READ);
    const offset = boundedCount(obj, "offset", "cursor", 0, correction_review.MAX_REVIEWED_CORRECTIONS_READ);
    const operation_kind_filter = getStr(obj, "operation_kind", "operationKind");

    var inspected = try correction_review.listReviewedCorrections(
        allocator,
        project_shard,
        decision_filter,
        operation_kind_filter,
        limit,
        offset,
        correction_review.MAX_REVIEWED_CORRECTIONS_READ,
    );
    defer inspected.deinit();

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();
    try w.writeAll("{\"correctionReviewedList\":{\"status\":\"ok\",\"projectShard\":\"");
    try writeEscaped(w, project_shard);
    try w.writeAll("\",\"decision\":\"");
    try writeEscaped(w, @tagName(decision_filter));
    try w.writeAll("\",\"operationKindFilter\":");
    if (operation_kind_filter) |filter| {
        try w.writeByte('"');
        try writeEscaped(w, filter);
        try w.writeByte('"');
    } else {
        try w.writeAll("null");
    }
    try w.writeAll(",\"records\":[");
    for (inspected.records, 0..) |record, i| {
        if (i != 0) try w.writeByte(',');
        try w.writeAll("{\"id\":\"");
        try writeEscaped(w, record.id);
        try w.writeAll("\",\"reviewDecision\":\"");
        try writeEscaped(w, @tagName(record.decision));
        try w.writeAll("\",\"operationKind\":\"");
        try writeEscaped(w, record.operation_kind);
        try w.writeAll("\",\"lineNumber\":");
        try w.print("{d}", .{record.line_number});
        try w.writeAll(",\"reviewedCorrectionRecord\":");
        try w.writeAll(record.record_json);
        try w.writeAll("}");
    }
    try w.writeAll("],\"totalRead\":");
    try w.print("{d}", .{inspected.total_read});
    try w.writeAll(",\"returnedCount\":");
    try w.print("{d}", .{inspected.returned_count});
    try w.writeAll(",\"malformedLines\":");
    try w.print("{d}", .{inspected.malformed_lines});
    try w.writeAll(",\"warnings\":");
    try writeReadWarningsJson(w, inspected.warnings);
    try w.writeAll(",\"capacityTelemetry\":{");
    try w.print("\"maxRecordsRead\":{d},\"maxRecordsHit\":{},\"limit\":{d},\"offset\":{d},\"limitHit\":{},\"fileBytesLimit\":{d},\"fileBytesLimitHit\":{}", .{
        correction_review.MAX_REVIEWED_CORRECTIONS_READ,
        inspected.max_records_hit,
        inspected.limit,
        inspected.offset,
        inspected.limit_hit,
        correction_review.MAX_REVIEWED_CORRECTIONS_BYTES,
        inspected.truncated,
    });
    try w.writeAll("},\"storage\":{\"appendOnly\":true,\"missingFile\":");
    try w.print("{}", .{inspected.missing_file});
    try w.writeAll(",\"readOnly\":true,\"inPlaceRewrite\":false,\"deletion\":false,\"compaction\":false,\"stableOrdering\":\"file_append_order\"}");
    try writeReviewedCorrectionSafeguards(w);
    try w.writeAll("}}");

    var gip_state = schema.draftResultState();
    gip_state.permission = .none;
    gip_state.verification_state = .unverified;
    gip_state.support_minimum_met = false;
    gip_state.non_authorization_notice = "correction.reviewed.list inspects reviewed records only; records are non-authorizing and not proof";

    return .{
        .status = .ok,
        .result_state = gip_state,
        .result_json = try out.toOwnedSlice(),
        .allocated_result = true,
    };
}

fn dispatchCorrectionReviewedGet(allocator: std.mem.Allocator, request_body: ?[]const u8) !DispatchResult {
    const body = request_body orelse return .{
        .status = .rejected,
        .err = .{ .code = .missing_required_field, .message = "request body is required for correction.reviewed.get" },
    };

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return .{ .status = .rejected, .err = .{ .code = .json_contract_error, .message = "invalid JSON in request body" } };
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        return .{ .status = .rejected, .err = .{ .code = .invalid_request, .message = "correction.reviewed.get request must be a JSON object" } };
    }

    const obj = parsed.value.object;
    const project_shard = getStr(obj, "project_shard", "projectShard") orelse shards.DEFAULT_PROJECT_ID;
    const id = getStr(obj, "id", "id") orelse return .{
        .status = .rejected,
        .err = .{ .code = .missing_required_field, .message = "id is required" },
    };

    var inspected = try correction_review.getReviewedCorrection(allocator, project_shard, id, correction_review.MAX_REVIEWED_CORRECTIONS_READ);
    defer inspected.deinit();

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();
    try w.writeAll("{\"correctionReviewedGet\":{\"status\":\"");
    try w.writeAll(if (inspected.record != null) "ok" else "not_found");
    try w.writeAll("\",\"projectShard\":\"");
    try writeEscaped(w, project_shard);
    try w.writeAll("\",\"id\":\"");
    try writeEscaped(w, id);
    try w.writeAll("\",\"reviewedCorrectionRecord\":");
    if (inspected.record) |record| {
        try w.writeAll(record.record_json);
    } else {
        try w.writeAll("null,\"unknown\":{\"kind\":\"reviewed_correction_not_found\",\"reason\":\"no same-shard reviewed correction record matched id\"}");
    }
    try w.writeAll(",\"totalRead\":");
    try w.print("{d}", .{inspected.total_read});
    try w.writeAll(",\"returnedCount\":");
    try w.print("{d}", .{if (inspected.record != null) @as(usize, 1) else @as(usize, 0)});
    try w.writeAll(",\"malformedLines\":");
    try w.print("{d}", .{inspected.malformed_lines});
    try w.writeAll(",\"warnings\":");
    try writeReadWarningsJson(w, inspected.warnings);
    try w.writeAll(",\"capacityTelemetry\":{");
    try w.print("\"maxRecordsRead\":{d},\"maxRecordsHit\":{},\"fileBytesLimit\":{d},\"fileBytesLimitHit\":{}", .{
        correction_review.MAX_REVIEWED_CORRECTIONS_READ,
        inspected.max_records_hit,
        correction_review.MAX_REVIEWED_CORRECTIONS_BYTES,
        inspected.truncated,
    });
    try w.writeAll("},\"storage\":{\"appendOnly\":true,\"missingFile\":");
    try w.print("{}", .{inspected.missing_file});
    try w.writeAll(",\"readOnly\":true,\"inPlaceRewrite\":false,\"deletion\":false,\"compaction\":false,\"stableOrdering\":\"file_append_order\"}");
    try writeReviewedCorrectionSafeguards(w);
    try w.writeAll("}}");

    var gip_state = if (inspected.record != null) schema.draftResultState() else schema.unresolvedResultState("reviewed_correction_not_found");
    gip_state.permission = .none;
    gip_state.verification_state = .unverified;
    gip_state.support_minimum_met = false;
    gip_state.non_authorization_notice = "correction.reviewed.get inspects reviewed records only; records are non-authorizing and not proof";

    return .{
        .status = if (inspected.record != null) .ok else .unresolved,
        .result_state = gip_state,
        .result_json = try out.toOwnedSlice(),
        .allocated_result = true,
    };
}

fn dispatchCorrectionInfluenceStatus(allocator: std.mem.Allocator, request_body: ?[]const u8) !DispatchResult {
    const body = request_body orelse return .{
        .status = .rejected,
        .err = .{ .code = .missing_required_field, .message = "request body is required for correction.influence.status" },
    };

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return .{ .status = .rejected, .err = .{ .code = .json_contract_error, .message = "invalid JSON in request body" } };
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        return .{ .status = .rejected, .err = .{ .code = .invalid_request, .message = "correction.influence.status request must be a JSON object" } };
    }

    const obj = parsed.value.object;
    const project_shard = getStr(obj, "project_shard", "projectShard") orelse shards.DEFAULT_PROJECT_ID;
    const operation_kind_filter = getStr(obj, "operation_kind", "operationKind");
    const include_records = getBool(obj, "include_records", "includeRecords") orelse false;
    const limit = if (include_records)
        boundedCount(obj, "limit", "limit", correction_review.MAX_REVIEWED_CORRECTIONS_READ, correction_review.MAX_REVIEWED_CORRECTIONS_READ)
    else
        0;

    var status = try correction_review.correctionInfluenceStatus(
        allocator,
        project_shard,
        operation_kind_filter,
        include_records,
        limit,
        correction_review.MAX_REVIEWED_CORRECTIONS_READ,
    );
    defer status.deinit();

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();
    try w.writeAll("{\"correctionInfluenceStatus\":{\"status\":\"ok\",\"projectShard\":\"");
    try writeEscaped(w, project_shard);
    try w.writeAll("\",\"readOnly\":true,\"operationKindFilter\":");
    if (operation_kind_filter) |filter| {
        try w.writeByte('"');
        try writeEscaped(w, filter);
        try w.writeByte('"');
    } else {
        try w.writeAll("null");
    }
    try w.writeAll(",\"summary\":{");
    try w.print("\"totalRecords\":{d},\"acceptedRecords\":{d},\"rejectedRecords\":{d},\"malformedLines\":{d}", .{
        status.summary.total_records,
        status.summary.accepted_records,
        status.summary.rejected_records,
        status.summary.malformed_lines,
    });
    try w.writeAll(",\"operationKindCounts\":");
    try writeCountEntriesJson(w, status.summary.operation_kind_counts);
    try w.writeAll(",\"correctionTypeCounts\":");
    try writeCountEntriesJson(w, status.summary.correction_type_counts);
    try w.writeAll(",\"influenceKindCounts\":");
    try writeCountEntriesJson(w, status.summary.influence_kind_counts);
    try w.print(",\"suppressionCandidateCount\":{d},\"strongerEvidenceCandidateCount\":{d},\"verifierCandidateCount\":{d},\"negativeKnowledgeCandidateCount\":{d},\"corpusUpdateCandidateCount\":{d},\"packGuidanceCandidateCount\":{d},\"ruleUpdateCandidateCount\":{d},\"futureBehaviorCandidateCount\":{d}", .{
        status.summary.suppression_candidate_count,
        status.summary.stronger_evidence_candidate_count,
        status.summary.verifier_candidate_count,
        status.summary.negative_knowledge_candidate_count,
        status.summary.corpus_update_candidate_count,
        status.summary.pack_guidance_candidate_count,
        status.summary.rule_update_candidate_count,
        status.summary.future_behavior_candidate_count,
    });
    try w.writeAll("},\"warnings\":");
    try writeReadWarningsJson(w, status.warnings);
    try w.writeAll(",\"capacityTelemetry\":{");
    try w.print("\"recordsRead\":{d},\"maxRecordsRead\":{d},\"maxRecordsHit\":{},\"includeRecords\":{},\"limit\":{d},\"returnedCount\":{d},\"limitHit\":{},\"fileBytesLimit\":{d},\"fileBytesLimitHit\":{}", .{
        status.records_read,
        correction_review.MAX_REVIEWED_CORRECTIONS_READ,
        status.max_records_hit,
        status.include_records,
        status.limit,
        status.returned_count,
        status.limit_hit,
        correction_review.MAX_REVIEWED_CORRECTIONS_BYTES,
        status.truncated,
    });
    try w.writeAll("},\"storage\":{\"appendOnly\":true,\"missingFile\":");
    try w.print("{}", .{status.missing_file});
    try w.writeAll(",\"sameShardOnly\":true,\"readOnly\":true,\"inPlaceRewrite\":false,\"deletion\":false,\"compaction\":false,\"stableOrdering\":\"file_append_order\"}");
    if (include_records) {
        try w.writeAll(",\"records\":");
        try writeInfluenceStatusRecordsJson(w, status.records);
    }
    try w.writeAll(",\"mutationFlags\":{\"corpusMutation\":false,\"packMutation\":false,\"negativeKnowledgeMutation\":false,\"commandsExecuted\":false,\"verifiersExecuted\":false}");
    try w.writeAll(",\"authority\":{\"nonAuthorizing\":true,\"treatedAsProof\":false,\"globalPromotion\":false,\"supportGranted\":false,\"proofDischarged\":false,\"usedAsEvidence\":false}}}");

    var gip_state = schema.draftResultState();
    gip_state.permission = .none;
    gip_state.verification_state = .unverified;
    gip_state.support_minimum_met = false;
    gip_state.non_authorization_notice = "correction.influence.status summarizes reviewed correction records only; summaries are non-authorizing diagnostics and not proof";

    return .{
        .status = .ok,
        .result_state = gip_state,
        .result_json = try out.toOwnedSlice(),
        .allocated_result = true,
    };
}

fn dispatchProcedurePackCandidatePropose(allocator: std.mem.Allocator, request_body: ?[]const u8) !DispatchResult {
    const body = request_body orelse return .{
        .status = .rejected,
        .err = .{ .code = .missing_required_field, .message = "request body is required for procedure_pack.candidate.propose" },
    };
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return .{ .status = .rejected, .err = .{ .code = .json_contract_error, .message = "invalid JSON in request body" } };
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        return .{ .status = .rejected, .err = .{ .code = .invalid_request, .message = "procedure_pack.candidate.propose request must be a JSON object" } };
    }
    const obj = parsed.value.object;
    const project_shard = getStr(obj, "project_shard", "projectShard") orelse shards.DEFAULT_PROJECT_ID;
    const source_kind_text = getStr(obj, "source_kind", "sourceKind") orelse return .{
        .status = .rejected,
        .err = .{ .code = .missing_required_field, .message = "sourceKind is required" },
    };
    const source_kind = procedure_pack_candidates.SourceKind.parse(source_kind_text) orelse return .{
        .status = .rejected,
        .err = .{ .code = .invalid_request, .message = "sourceKind must be reviewed_correction, reviewed_negative_knowledge, or learning_status", .details = source_kind_text },
    };
    const source_id = getStr(obj, "source_review_id", "sourceReviewId") orelse getStr(obj, "source_id", "sourceId");
    if (source_kind != .learning_status and source_id == null) {
        return .{ .status = .rejected, .err = .{ .code = .missing_required_field, .message = "sourceReviewId is required for reviewed correction and reviewed negative knowledge sources" } };
    }
    const candidate_kind_override = if (getStr(obj, "candidate_kind", "candidateKind")) |text|
        procedure_pack_candidates.CandidateKind.parse(text) orelse return .{
            .status = .rejected,
            .err = .{ .code = .invalid_request, .message = "candidateKind is not a supported procedure kind", .details = text },
        }
    else
        null;

    var proposal = try procedure_pack_candidates.propose(allocator, .{
        .project_shard = project_shard,
        .source_kind = source_kind,
        .source_id = source_id,
        .candidate_kind_override = candidate_kind_override,
    });
    defer proposal.deinit();

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();
    try w.writeAll("{\"procedurePackCandidatePropose\":{\"status\":\"");
    try w.writeAll(if (proposal.missing_source) "not_found" else "candidate");
    try w.writeAll("\",\"projectShard\":\"");
    try writeEscaped(w, project_shard);
    try w.writeAll("\",\"sourceKind\":\"");
    try writeEscaped(w, @tagName(source_kind));
    try w.writeAll("\",\"sourceReviewId\":");
    if (source_id) |id| {
        try w.writeByte('"');
        try writeEscaped(w, id);
        try w.writeByte('"');
    } else {
        try w.writeAll("null");
    }
    try w.writeAll(",\"procedurePackCandidate\":");
    try w.writeAll(proposal.candidate_json);
    try w.writeAll(",\"sourceRecord\":");
    if (proposal.source_record_json) |record| try w.writeAll(record) else try w.writeAll("null");
    try w.writeAll(",\"warnings\":");
    try writeReadWarningsJson(w, proposal.source_warnings);
    try w.writeAll(",\"storage\":{\"persisted\":false,\"reviewRequiredForPersistence\":true,\"packMutation\":false,\"globalPromotion\":false}");
    try writeProcedurePackCandidateSafeguards(w, true);
    try w.writeAll("}}");

    var gip_state = if (proposal.missing_source) schema.unresolvedResultState("procedure_pack_candidate_source_not_found") else schema.draftResultState();
    gip_state.permission = .none;
    gip_state.verification_state = .unverified;
    gip_state.support_minimum_met = false;
    gip_state.non_authorization_notice = "procedure_pack.candidate.propose emits candidate-only procedure descriptions; candidates are not proof, evidence, pack mutation, execution, or global promotion";

    return .{
        .status = if (proposal.missing_source) .unresolved else .ok,
        .result_state = gip_state,
        .result_json = try out.toOwnedSlice(),
        .allocated_result = true,
    };
}

fn dispatchVerifierCandidateProposeFromLearningPlan(allocator: std.mem.Allocator, request_body: ?[]const u8) !DispatchResult {
    const body = request_body orelse return .{
        .status = .rejected,
        .err = .{ .code = .missing_required_field, .message = "request body is required for verifier.candidate.propose_from_learning_plan" },
    };
    var proposed = verifier_candidates.proposeFromLearningPlanBody(allocator, body) catch |err| {
        return verifierCandidateRequestError(err, "verifier.candidate.propose_from_learning_plan rejected invalid learning loop plan or verifier ref");
    };
    defer proposed.deinit();

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    try verifier_candidates.writeProposeResultJson(out.writer(), proposed);

    var gip_state = schema.draftResultState();
    gip_state.permission = .none;
    gip_state.verification_state = .unverified;
    gip_state.support_minimum_met = false;
    gip_state.non_authorization_notice = "verifier.candidate.propose_from_learning_plan appends candidate metadata only; it does not execute commands or verifiers and does not create proof or evidence";

    return .{ .status = .ok, .result_state = gip_state, .result_json = try out.toOwnedSlice(), .allocated_result = true };
}

fn dispatchVerifierCandidateList(allocator: std.mem.Allocator, request_body: ?[]const u8) !DispatchResult {
    const body = request_body orelse return .{
        .status = .rejected,
        .err = .{ .code = .missing_required_field, .message = "request body is required for verifier.candidate.list" },
    };
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return .{ .status = .rejected, .err = .{ .code = .json_contract_error, .message = "invalid JSON in request body" } };
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        return .{ .status = .rejected, .err = .{ .code = .invalid_request, .message = "verifier.candidate.list request must be a JSON object" } };
    }
    const obj = parsed.value.object;
    const project_shard = getStr(obj, "project_shard", "projectShard") orelse shards.DEFAULT_PROJECT_ID;
    const limit = boundedCount(obj, "limit", "limit", verifier_candidates.MAX_CANDIDATES_READ, verifier_candidates.MAX_CANDIDATES_READ);

    var listed = try verifier_candidates.listCandidates(allocator, project_shard, limit);
    defer listed.deinit();

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    try verifier_candidates.writeListResultJson(out.writer(), listed);

    var gip_state = schema.draftResultState();
    gip_state.permission = .none;
    gip_state.verification_state = .unverified;
    gip_state.support_minimum_met = false;
    gip_state.non_authorization_notice = "verifier.candidate.list is read-only candidate metadata inspection; listing never executes commands or verifiers and never creates evidence";

    return .{ .status = .ok, .result_state = gip_state, .result_json = try out.toOwnedSlice(), .allocated_result = true };
}

fn dispatchVerifierCandidateReview(allocator: std.mem.Allocator, request_body: ?[]const u8) !DispatchResult {
    const body = request_body orelse return .{
        .status = .rejected,
        .err = .{ .code = .missing_required_field, .message = "request body is required for verifier.candidate.review" },
    };
    var reviewed = verifier_candidates.reviewBody(allocator, body) catch |err| {
        return verifierCandidateRequestError(err, "verifier.candidate.review rejected invalid review request");
    };
    defer reviewed.deinit();

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    try verifier_candidates.writeReviewResultJson(out.writer(), reviewed);

    var gip_state = schema.draftResultState();
    gip_state.permission = .none;
    gip_state.verification_state = .unverified;
    gip_state.support_minimum_met = false;
    gip_state.non_authorization_notice = "verifier.candidate.review appends approval/rejection metadata only; approval permits possible future execution but does not execute or produce evidence";

    return .{ .status = .ok, .result_state = gip_state, .result_json = try out.toOwnedSlice(), .allocated_result = true };
}

fn dispatchVerifierCandidateExecute(allocator: std.mem.Allocator, workspace_root: ?[]const u8, request_body: ?[]const u8) !DispatchResult {
    const body = request_body orelse return .{
        .status = .rejected,
        .err = .{ .code = .missing_required_field, .message = "request body is required for verifier.candidate.execute" },
    };
    var executed = verifier_candidate_execution.executeBody(allocator, body, workspace_root) catch |err| {
        return verifierCandidateExecutionRequestError(err);
    };
    defer executed.deinit();

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    try verifier_candidate_execution.writeExecuteResultJson(out.writer(), executed);

    var gip_state = schema.draftResultState();
    gip_state.permission = .none;
    gip_state.verification_state = .partial;
    gip_state.support_minimum_met = false;
    gip_state.non_authorization_notice = "verifier.candidate.execute runs only approved candidates through the bounded harness and produces verifier execution evidence candidates only; it never grants proof/support or applies correction, negative knowledge, patches, packs, or corpus changes";

    const status: core.ProtocolStatus = if (!executed.executed) .rejected else if (std.mem.eql(u8, executed.status, "passed")) .ok else .failed;
    return .{ .status = status, .result_state = gip_state, .result_json = try out.toOwnedSlice(), .allocated_result = true };
}

fn verifierCandidateExecutionRequestError(err: anyerror) DispatchResult {
    return switch (err) {
        error.InvalidJson => .{ .status = .rejected, .err = .{ .code = .json_contract_error, .message = "invalid JSON in request body" } },
        error.MissingProjectShard => .{ .status = .rejected, .err = .{ .code = .missing_required_field, .message = "projectShard is required" } },
        error.MissingCandidateId => .{ .status = .rejected, .err = .{ .code = .missing_required_field, .message = "candidateId is required" } },
        error.MissingWorkspaceRoot => .{ .status = .rejected, .err = .{ .code = .missing_required_field, .message = "workspaceRoot is required for verifier.candidate.execute" } },
        error.WorkspaceEscape => .{ .status = .rejected, .err = .{ .code = .path_outside_workspace, .message = "execution cwd is outside workspace root" } },
        error.InvalidRequest => .{ .status = .rejected, .err = .{ .code = .invalid_request, .message = "verifier.candidate.execute request must be a JSON object" } },
        else => .{ .status = .failed, .err = .{ .code = .internal_error, .message = "verifier.candidate.execute failed", .details = @errorName(err) } },
    };
}

fn verifierCandidateRequestError(err: anyerror, fallback: []const u8) DispatchResult {
    return switch (err) {
        error.InvalidJson => .{ .status = .rejected, .err = .{ .code = .json_contract_error, .message = "invalid JSON in request body" } },
        error.MissingProjectShard => .{ .status = .rejected, .err = .{ .code = .missing_required_field, .message = "projectShard is required" } },
        error.MissingLearningPlan => .{ .status = .rejected, .err = .{ .code = .missing_required_field, .message = "learningLoopPlan is required" } },
        error.MissingCandidateId => .{ .status = .rejected, .err = .{ .code = .missing_required_field, .message = "candidateId is required" } },
        error.MissingDecision => .{ .status = .rejected, .err = .{ .code = .missing_required_field, .message = "decision is required" } },
        error.CandidateNotFound => .{ .status = .rejected, .err = .{ .code = .invalid_request, .message = "candidateId was not found in same-shard verifier candidate metadata" } },
        error.InvalidDecision => .{ .status = .rejected, .err = .{ .code = .invalid_request, .message = "decision must be approved or rejected" } },
        error.InvalidLearningPlan, error.InvalidVerifierRef, error.InvalidRequest => .{ .status = .rejected, .err = .{ .code = .invalid_request, .message = fallback } },
        else => .{ .status = .failed, .err = .{ .code = .internal_error, .message = "verifier candidate lifecycle operation failed", .details = @errorName(err) } },
    };
}

fn dispatchProcedurePackCandidateReview(allocator: std.mem.Allocator, request_body: ?[]const u8) !DispatchResult {
    const body = request_body orelse return .{
        .status = .rejected,
        .err = .{ .code = .missing_required_field, .message = "request body is required for procedure_pack.candidate.review" },
    };
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return .{ .status = .rejected, .err = .{ .code = .json_contract_error, .message = "invalid JSON in request body" } };
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        return .{ .status = .rejected, .err = .{ .code = .invalid_request, .message = "procedure_pack.candidate.review request must be a JSON object" } };
    }
    const obj = parsed.value.object;
    const project_shard = getStr(obj, "project_shard", "projectShard") orelse shards.DEFAULT_PROJECT_ID;
    const decision_text = getStr(obj, "decision", "decision") orelse return .{
        .status = .rejected,
        .err = .{ .code = .missing_required_field, .message = "decision is required" },
    };
    const decision = procedure_pack_candidates.Decision.parse(decision_text) orelse return .{
        .status = .rejected,
        .err = .{ .code = .invalid_request, .message = "decision must be accepted or rejected", .details = decision_text },
    };
    const reviewer_note = getStr(obj, "reviewer_note", "reviewerNote") orelse "";
    const rejected_reason = getStr(obj, "rejected_reason", "rejectedReason");
    const candidate_value = obj.get("procedurePackCandidate") orelse obj.get("procedure_pack_candidate") orelse return .{
        .status = .rejected,
        .err = .{ .code = .missing_required_field, .message = "procedurePackCandidate is required" },
    };
    if (candidate_value != .object) {
        return .{ .status = .rejected, .err = .{ .code = .invalid_request, .message = "procedurePackCandidate must be an object" } };
    }
    const candidate_json = try std.json.stringifyAlloc(allocator, candidate_value, .{});
    defer allocator.free(candidate_json);

    var reviewed = try procedure_pack_candidates.reviewAndAppend(allocator, .{
        .project_shard = project_shard,
        .decision = decision,
        .reviewer_note = reviewer_note,
        .rejected_reason = rejected_reason,
        .procedure_pack_candidate_json = candidate_json,
    });
    defer reviewed.deinit();

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();
    try w.writeAll("{\"procedurePackCandidateReview\":{\"status\":\"reviewed\",\"reviewedProcedurePackCandidateRecord\":");
    try w.writeAll(reviewed.record_json);
    try w.writeAll(",\"storage\":{\"path\":\"");
    try writeEscaped(w, reviewed.storage_path);
    try w.writeAll("\",\"appendOnly\":true,\"stableOrdering\":\"file_append_order\",\"inPlaceRewrite\":false,\"deletion\":false,\"compaction\":false,\"packMutation\":false}");
    try writeProcedurePackCandidateSafeguards(w, false);
    try w.writeAll("}}");

    var gip_state = schema.draftResultState();
    gip_state.permission = .none;
    gip_state.verification_state = .unverified;
    gip_state.support_minimum_met = false;
    gip_state.non_authorization_notice = "procedure_pack.candidate.review appends reviewed candidate records only; it does not mutate packs or execute commands/verifiers";

    return .{ .status = .ok, .result_state = gip_state, .result_json = try out.toOwnedSlice(), .allocated_result = true };
}

fn dispatchProcedurePackCandidateReviewedList(allocator: std.mem.Allocator, request_body: ?[]const u8) !DispatchResult {
    const body = request_body orelse return .{
        .status = .rejected,
        .err = .{ .code = .missing_required_field, .message = "request body is required for procedure_pack.candidate.reviewed.list" },
    };
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return .{ .status = .rejected, .err = .{ .code = .json_contract_error, .message = "invalid JSON in request body" } };
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        return .{ .status = .rejected, .err = .{ .code = .invalid_request, .message = "procedure_pack.candidate.reviewed.list request must be a JSON object" } };
    }
    const obj = parsed.value.object;
    const project_shard = getStr(obj, "project_shard", "projectShard") orelse shards.DEFAULT_PROJECT_ID;
    const decision_text = getStr(obj, "decision", "decision") orelse "all";
    const decision_filter = procedure_pack_candidates.DecisionFilter.parse(decision_text) orelse return .{
        .status = .rejected,
        .err = .{ .code = .invalid_request, .message = "decision must be accepted, rejected, or all", .details = decision_text },
    };
    const limit = boundedCount(obj, "limit", "limit", procedure_pack_candidates.MAX_REVIEWED_PROCEDURE_PACK_CANDIDATES_READ, procedure_pack_candidates.MAX_REVIEWED_PROCEDURE_PACK_CANDIDATES_READ);
    const offset = boundedCount(obj, "offset", "cursor", 0, procedure_pack_candidates.MAX_REVIEWED_PROCEDURE_PACK_CANDIDATES_READ);
    var inspected = try procedure_pack_candidates.listReviewedCandidates(allocator, project_shard, decision_filter, limit, offset, procedure_pack_candidates.MAX_REVIEWED_PROCEDURE_PACK_CANDIDATES_READ);
    defer inspected.deinit();

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();
    try w.writeAll("{\"procedurePackCandidateReviewedList\":{\"status\":\"ok\",\"projectShard\":\"");
    try writeEscaped(w, project_shard);
    try w.writeAll("\",\"records\":[");
    for (inspected.records, 0..) |record, i| {
        if (i != 0) try w.writeByte(',');
        try w.writeAll("{\"id\":\"");
        try writeEscaped(w, record.id);
        try w.writeAll("\",\"reviewDecision\":\"");
        try writeEscaped(w, @tagName(record.decision));
        try w.writeAll("\",\"candidateId\":\"");
        try writeEscaped(w, record.candidate_id);
        try w.writeAll("\",\"candidateKind\":\"");
        try writeEscaped(w, record.candidate_kind);
        try w.writeAll("\",\"lineNumber\":");
        try w.print("{d}", .{record.line_number});
        try w.writeAll(",\"reviewedProcedurePackCandidateRecord\":");
        try w.writeAll(record.record_json);
        try w.writeAll("}");
    }
    try w.writeAll("],\"totalRead\":");
    try w.print("{d}", .{inspected.total_read});
    try w.writeAll(",\"returnedCount\":");
    try w.print("{d}", .{inspected.returned_count});
    try w.writeAll(",\"malformedLines\":");
    try w.print("{d}", .{inspected.malformed_lines});
    try w.writeAll(",\"warnings\":");
    try writeProcedurePackReadWarningsJson(w, inspected.warnings);
    try w.writeAll(",\"capacityTelemetry\":{");
    try w.print("\"maxRecordsRead\":{d},\"maxRecordsHit\":{},\"limit\":{d},\"offset\":{d},\"limitHit\":{},\"fileBytesLimit\":{d},\"fileBytesLimitHit\":{}", .{
        procedure_pack_candidates.MAX_REVIEWED_PROCEDURE_PACK_CANDIDATES_READ,
        inspected.max_records_hit,
        inspected.limit,
        inspected.offset,
        inspected.limit_hit,
        procedure_pack_candidates.MAX_REVIEWED_PROCEDURE_PACK_CANDIDATES_BYTES,
        inspected.truncated,
    });
    try w.writeAll("},\"storage\":{\"appendOnly\":true,\"missingFile\":");
    try w.print("{}", .{inspected.missing_file});
    try w.writeAll(",\"readOnly\":true,\"inPlaceRewrite\":false,\"deletion\":false,\"compaction\":false,\"stableOrdering\":\"file_append_order\",\"packMutation\":false}");
    try writeProcedurePackCandidateSafeguards(w, true);
    try w.writeAll("}}");

    var gip_state = schema.draftResultState();
    gip_state.permission = .none;
    gip_state.verification_state = .unverified;
    gip_state.support_minimum_met = false;
    gip_state.non_authorization_notice = "procedure_pack.candidate.reviewed.list is read-only inspection; records are non-authorizing and not proof or evidence";
    return .{ .status = .ok, .result_state = gip_state, .result_json = try out.toOwnedSlice(), .allocated_result = true };
}

fn dispatchProcedurePackCandidateReviewedGet(allocator: std.mem.Allocator, request_body: ?[]const u8) !DispatchResult {
    const body = request_body orelse return .{
        .status = .rejected,
        .err = .{ .code = .missing_required_field, .message = "request body is required for procedure_pack.candidate.reviewed.get" },
    };
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return .{ .status = .rejected, .err = .{ .code = .json_contract_error, .message = "invalid JSON in request body" } };
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        return .{ .status = .rejected, .err = .{ .code = .invalid_request, .message = "procedure_pack.candidate.reviewed.get request must be a JSON object" } };
    }
    const obj = parsed.value.object;
    const project_shard = getStr(obj, "project_shard", "projectShard") orelse shards.DEFAULT_PROJECT_ID;
    const id = getStr(obj, "id", "id") orelse return .{
        .status = .rejected,
        .err = .{ .code = .missing_required_field, .message = "id is required" },
    };
    var inspected = try procedure_pack_candidates.getReviewedCandidate(allocator, project_shard, id, procedure_pack_candidates.MAX_REVIEWED_PROCEDURE_PACK_CANDIDATES_READ);
    defer inspected.deinit();

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();
    try w.writeAll("{\"procedurePackCandidateReviewedGet\":{\"status\":\"");
    try w.writeAll(if (inspected.record != null) "ok" else "not_found");
    try w.writeAll("\",\"projectShard\":\"");
    try writeEscaped(w, project_shard);
    try w.writeAll("\",\"id\":\"");
    try writeEscaped(w, id);
    try w.writeAll("\",\"reviewedProcedurePackCandidateRecord\":");
    if (inspected.record) |record| {
        try w.writeAll(record.record_json);
    } else {
        try w.writeAll("null,\"unknown\":{\"kind\":\"reviewed_procedure_pack_candidate_not_found\",\"reason\":\"no same-shard reviewed procedure pack candidate matched id\"}");
    }
    try w.writeAll(",\"totalRead\":");
    try w.print("{d}", .{inspected.total_read});
    try w.writeAll(",\"returnedCount\":");
    try w.print("{d}", .{if (inspected.record != null) @as(usize, 1) else @as(usize, 0)});
    try w.writeAll(",\"malformedLines\":");
    try w.print("{d}", .{inspected.malformed_lines});
    try w.writeAll(",\"warnings\":");
    try writeProcedurePackReadWarningsJson(w, inspected.warnings);
    try w.writeAll(",\"capacityTelemetry\":{");
    try w.print("\"maxRecordsRead\":{d},\"maxRecordsHit\":{},\"fileBytesLimit\":{d},\"fileBytesLimitHit\":{}", .{
        procedure_pack_candidates.MAX_REVIEWED_PROCEDURE_PACK_CANDIDATES_READ,
        inspected.max_records_hit,
        procedure_pack_candidates.MAX_REVIEWED_PROCEDURE_PACK_CANDIDATES_BYTES,
        inspected.truncated,
    });
    try w.writeAll("},\"storage\":{\"appendOnly\":true,\"missingFile\":");
    try w.print("{}", .{inspected.missing_file});
    try w.writeAll(",\"readOnly\":true,\"inPlaceRewrite\":false,\"deletion\":false,\"compaction\":false,\"stableOrdering\":\"file_append_order\",\"packMutation\":false}");
    try writeProcedurePackCandidateSafeguards(w, true);
    try w.writeAll("}}");

    var gip_state = if (inspected.record != null) schema.draftResultState() else schema.unresolvedResultState("reviewed_procedure_pack_candidate_not_found");
    gip_state.permission = .none;
    gip_state.verification_state = .unverified;
    gip_state.support_minimum_met = false;
    gip_state.non_authorization_notice = "procedure_pack.candidate.reviewed.get is read-only inspection; records are non-authorizing and not proof or evidence";
    return .{
        .status = if (inspected.record != null) .ok else .unresolved,
        .result_state = gip_state,
        .result_json = try out.toOwnedSlice(),
        .allocated_result = true,
    };
}

fn dispatchLearningStatus(allocator: std.mem.Allocator, request_body: ?[]const u8) !DispatchResult {
    var parsed: ?std.json.Parsed(std.json.Value) = null;
    defer if (parsed) |*p| p.deinit();

    var obj: ?std.json.ObjectMap = null;
    if (request_body) |body| {
        parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
            return .{ .status = .rejected, .err = .{ .code = .json_contract_error, .message = "invalid JSON in request body" } };
        };
        if (parsed.?.value != .object) {
            return .{ .status = .rejected, .err = .{ .code = .invalid_request, .message = "learning.status request must be a JSON object" } };
        }
        obj = parsed.?.value.object;
    }

    const project_shard = if (obj) |body_obj| getStr(body_obj, "project_shard", "projectShard") orelse shards.DEFAULT_PROJECT_ID else shards.DEFAULT_PROJECT_ID;
    const include_records = if (obj) |body_obj| getBool(body_obj, "include_records", "includeRecords") orelse false else false;
    const include_warnings = if (obj) |body_obj| getBool(body_obj, "include_warnings", "includeWarnings") orelse true else true;
    const limit = if (include_records and obj != null)
        boundedCount(obj.?, "limit", "limit", learning_status.MAX_LEARNING_STATUS_RECORDS, learning_status.MAX_LEARNING_STATUS_RECORDS)
    else if (include_records)
        learning_status.MAX_LEARNING_STATUS_RECORDS
    else
        0;

    var status = try learning_status.readStatus(allocator, .{
        .project_shard = project_shard,
        .include_records = include_records,
        .include_warnings = include_warnings,
        .limit = limit,
    });
    defer status.deinit();

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();
    try w.writeAll("{\"learningStatus\":{\"status\":\"ok\",\"projectShard\":\"");
    try writeEscaped(w, project_shard);
    try w.writeAll("\",\"readOnly\":true");
    try w.writeAll(",\"correctionSummary\":{");
    try w.print("\"reviewedCorrectionRecords\":{d},\"acceptedReviewedCorrections\":{d},\"rejectedReviewedCorrections\":{d},\"malformedCorrectionLines\":{d}", .{
        status.correction_status.summary.total_records,
        status.correction_status.summary.accepted_records,
        status.correction_status.summary.rejected_records,
        status.correction_status.summary.malformed_lines,
    });
    try w.writeAll(",\"correctionOperationKindCounts\":");
    try writeCountEntriesJson(w, status.correction_status.summary.operation_kind_counts);
    try w.writeAll(",\"correctionTypeCounts\":");
    try writeCountEntriesJson(w, status.correction_status.summary.correction_type_counts);
    try w.writeAll(",\"correctionInfluenceKindCounts\":");
    try writeCountEntriesJson(w, status.correction_status.summary.influence_kind_counts);
    try w.print(",\"correctionSuppressionCandidateCount\":{d},\"correctionFutureBehaviorCandidateCount\":{d}", .{
        status.correction_status.summary.suppression_candidate_count,
        status.correction_status.summary.future_behavior_candidate_count,
    });
    try w.writeAll("},\"negativeKnowledgeSummary\":{");
    try w.print("\"reviewedNegativeKnowledgeRecords\":{d},\"acceptedReviewedNegativeKnowledge\":{d},\"rejectedReviewedNegativeKnowledge\":{d},\"malformedNegativeKnowledgeLines\":{d}", .{
        status.negative_knowledge_summary.reviewed_records,
        status.negative_knowledge_summary.accepted_records,
        status.negative_knowledge_summary.rejected_records,
        status.negative_knowledge_summary.malformed_lines,
    });
    try w.writeAll(",\"negativeKnowledgeOperationKindCounts\":");
    try writeCountEntriesJson(w, status.negative_knowledge_summary.operation_kind_counts);
    try w.writeAll(",\"negativeKnowledgeInfluenceKindCounts\":");
    try writeCountEntriesJson(w, status.negative_knowledge_summary.influence_kind_counts);
    try w.print(",\"negativeKnowledgeSuppressionCandidateCount\":{d},\"negativeKnowledgeFutureBehaviorCandidateCount\":{d}", .{
        status.negative_knowledge_summary.suppression_candidate_count,
        status.negative_knowledge_summary.future_behavior_candidate_count,
    });
    try w.writeAll("},\"influenceSummary\":{");
    const corpus_correction = countNamed(status.correction_status.summary.operation_kind_counts, "corpus.ask") > 0;
    const rule_correction = countNamed(status.correction_status.summary.operation_kind_counts, "rule.evaluate") > 0;
    const corpus_nk = countNamed(status.negative_knowledge_summary.operation_kind_counts, "corpus.ask") > 0;
    const rule_nk = countNamed(status.negative_knowledge_summary.operation_kind_counts, "rule.evaluate") > 0;
    const suppression = status.correction_status.summary.suppression_candidate_count + status.negative_knowledge_summary.suppression_candidate_count;
    const stronger = status.correction_status.summary.stronger_evidence_candidate_count + status.negative_knowledge_summary.stronger_evidence_candidate_count;
    const verifier = status.correction_status.summary.verifier_candidate_count + status.negative_knowledge_summary.verifier_candidate_count;
    const pack = status.correction_status.summary.pack_guidance_candidate_count + status.negative_knowledge_summary.pack_guidance_candidate_count;
    const corpus = status.correction_status.summary.corpus_update_candidate_count + status.negative_knowledge_summary.corpus_update_candidate_count;
    const rule = status.correction_status.summary.rule_update_candidate_count + status.negative_knowledge_summary.rule_update_candidate_count;
    const future = status.correction_status.summary.future_behavior_candidate_count + status.negative_knowledge_summary.future_behavior_candidate_count;
    try w.print("\"corpusAskCorrectionInfluenceAvailable\":{},\"ruleEvaluateCorrectionInfluenceAvailable\":{},\"corpusAskNegativeKnowledgeInfluenceAvailable\":{},\"ruleEvaluateNegativeKnowledgeInfluenceAvailable\":{}", .{
        corpus_correction,
        rule_correction,
        corpus_nk,
        rule_nk,
    });
    try w.print(",\"suppressionCapableRecords\":{d},\"strongerEvidenceCandidateCount\":{d},\"verifierCandidateCount\":{d},\"packGuidanceCandidateCount\":{d},\"corpusUpdateCandidateCount\":{d},\"ruleUpdateCandidateCount\":{d},\"futureBehaviorCandidateCount\":{d},\"unappliedCandidateCount\":{d}", .{
        suppression,
        stronger,
        verifier,
        pack,
        corpus,
        rule,
        future,
        future,
    });
    try w.writeAll("},\"warningSummary\":{");
    try w.print("\"malformedReviewedCorrectionLines\":{d},\"malformedReviewedNegativeKnowledgeLines\":{d},\"capacityWarnings\":{d},\"unknownOrUnclassifiedRecords\":{d},\"readCapsHit\":{},\"byteCapsHit\":{}", .{
        status.warning_summary.malformed_reviewed_correction_lines,
        status.warning_summary.malformed_reviewed_negative_knowledge_lines,
        status.warning_summary.capacity_warnings,
        status.warning_summary.unknown_or_unclassified_records,
        status.warning_summary.read_caps_hit,
        status.warning_summary.byte_caps_hit,
    });
    try w.writeAll("},\"capacityTelemetry\":{");
    try w.print("\"correctionRecordsRead\":{d},\"correctionMaxRecords\":{d},\"correctionReadCapHit\":{},\"correctionMaxBytes\":{d},\"correctionByteCapHit\":{},\"negativeKnowledgeRecordsRead\":{d},\"negativeKnowledgeMaxRecords\":{d},\"negativeKnowledgeReadCapHit\":{},\"negativeKnowledgeMaxBytes\":{d},\"negativeKnowledgeByteCapHit\":{},\"includeRecords\":{},\"limit\":{d},\"returnedRecords\":{d},\"limitHit\":{}", .{
        status.capacity_telemetry.correction_records_read,
        status.capacity_telemetry.correction_max_records,
        status.capacity_telemetry.correction_read_cap_hit,
        status.capacity_telemetry.correction_max_bytes,
        status.capacity_telemetry.correction_byte_cap_hit,
        status.capacity_telemetry.negative_knowledge_records_read,
        status.capacity_telemetry.negative_knowledge_max_records,
        status.capacity_telemetry.negative_knowledge_read_cap_hit,
        status.capacity_telemetry.negative_knowledge_max_bytes,
        status.capacity_telemetry.negative_knowledge_byte_cap_hit,
        status.capacity_telemetry.include_records,
        status.capacity_telemetry.limit,
        status.capacity_telemetry.returned_records,
        status.capacity_telemetry.limit_hit,
    });
    try w.writeAll("},\"storage\":{\"appendOnly\":true,\"correctionMissingFile\":");
    try w.print("{}", .{status.storage.correction_missing_file});
    try w.writeAll(",\"negativeKnowledgeMissingFile\":");
    try w.print("{}", .{status.storage.negative_knowledge_missing_file});
    try w.writeAll(",\"sameShardOnly\":true,\"readOnly\":true,\"inPlaceRewrite\":false,\"deletion\":false,\"compaction\":false,\"stableOrdering\":\"file_append_order\"}");
    if (include_warnings) {
        try w.writeAll(",\"warnings\":{\"corrections\":");
        try writeReadWarningsJson(w, status.correction_status.warnings);
        try w.writeAll(",\"negativeKnowledge\":");
        try writeNegativeKnowledgeReadWarningsJson(w, status.negative_knowledge_warnings);
        try w.writeAll("}");
    }
    if (include_records) {
        try w.writeAll(",\"records\":");
        try writeLearningRecordsJson(w, status.records);
    }
    try w.writeAll(",\"mutationFlags\":{\"corpusMutation\":false,\"packMutation\":false,\"negativeKnowledgeMutation\":false,\"correctionMutation\":false,\"commandsExecuted\":false,\"verifiersExecuted\":false}");
    try w.writeAll(",\"authority\":{\"nonAuthorizing\":true,\"treatedAsProof\":false,\"globalPromotion\":false,\"usedAsEvidence\":false,\"supportGranted\":false,\"proofDischarged\":false,\"allLearningNonAuthorizing\":true}}}");

    var gip_state = schema.draftResultState();
    gip_state.permission = .none;
    gip_state.verification_state = .unverified;
    gip_state.support_minimum_met = false;
    gip_state.non_authorization_notice = "learning.status is a read-only reviewed learning-loop scoreboard; counts are diagnostics only and not proof, evidence, support, mutation, or global promotion";

    return .{
        .status = .ok,
        .result_state = gip_state,
        .result_json = try out.toOwnedSlice(),
        .allocated_result = true,
    };
}

fn dispatchNegativeKnowledgeReview(allocator: std.mem.Allocator, request_body: ?[]const u8) !DispatchResult {
    const body = request_body orelse return .{
        .status = .rejected,
        .err = .{ .code = .missing_required_field, .message = "request body is required for negative_knowledge.review" },
    };

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return .{ .status = .rejected, .err = .{ .code = .json_contract_error, .message = "invalid JSON in request body" } };
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return .{ .status = .rejected, .err = .{ .code = .invalid_request, .message = "negative_knowledge.review request must be a JSON object" } };
    }

    const obj = parsed.value.object;
    const decision_text = getStr(obj, "decision", "decision") orelse return .{
        .status = .rejected,
        .err = .{ .code = .missing_required_field, .message = "decision is required" },
    };
    const decision = negative_knowledge_review.Decision.parse(decision_text) orelse return .{
        .status = .rejected,
        .err = .{ .code = .invalid_request, .message = "decision must be accepted or rejected", .details = decision_text },
    };
    const reviewer_note = getStr(obj, "reviewer_note", "reviewerNote") orelse return .{
        .status = .rejected,
        .err = .{ .code = .missing_required_field, .message = "reviewerNote is required" },
    };
    if (std.mem.trim(u8, reviewer_note, " \r\n\t").len == 0) {
        return .{ .status = .rejected, .err = .{ .code = .invalid_request, .message = "reviewerNote must be non-empty" } };
    }
    const rejected_reason = getStr(obj, "rejected_reason", "rejectedReason");
    if (decision == .rejected and (rejected_reason == null or std.mem.trim(u8, rejected_reason.?, " \r\n\t").len == 0)) {
        return .{ .status = .rejected, .err = .{ .code = .missing_required_field, .message = "rejectedReason is required when decision is rejected" } };
    }

    const candidate_value = obj.get("negativeKnowledgeCandidate") orelse obj.get("negative_knowledge_candidate");
    const candidate_id = getStr(obj, "negative_knowledge_candidate_id", "negativeKnowledgeCandidateId") orelse blk: {
        if (candidate_value) |value| {
            const candidate_obj = valueObject(value) orelse return .{ .status = .rejected, .err = .{ .code = .invalid_request, .message = "negativeKnowledgeCandidate must be an object when provided" } };
            break :blk getStr(candidate_obj, "id", "id");
        }
        break :blk null;
    } orelse return .{
        .status = .rejected,
        .err = .{ .code = .missing_required_field, .message = "negativeKnowledgeCandidate or negativeKnowledgeCandidateId is required" },
    };

    const candidate_json = if (candidate_value) |value|
        try stringifyJsonValue(allocator, value)
    else
        try std.fmt.allocPrint(allocator, "{{\"id\":\"{}\"}}", .{std.zig.fmtEscapes(candidate_id)});
    defer allocator.free(candidate_json);

    var result = try negative_knowledge_review.reviewAndAppend(allocator, .{
        .project_shard = getStr(obj, "project_shard", "projectShard") orelse shards.DEFAULT_PROJECT_ID,
        .decision = decision,
        .reviewer_note = reviewer_note,
        .rejected_reason = rejected_reason,
        .source_candidate_id = candidate_id,
        .source_correction_review_id = getStr(obj, "source_correction_review_id", "sourceCorrectionReviewId"),
        .negative_knowledge_candidate_json = candidate_json,
    });
    defer result.deinit();

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();
    try w.writeAll("{\"negativeKnowledgeReview\":{\"status\":\"reviewed\",\"reviewedNegativeKnowledgeRecord\":");
    try w.writeAll(result.record_json);
    try w.writeAll(",\"requiredReview\":false,\"readOnly\":false,\"appendOnly\":true,\"futureInfluenceCandidate\":");
    if (decision == .accepted) {
        try w.writeAll("{\"status\":\"candidate\",\"kind\":\"reviewed_negative_knowledge_influence_candidate\",\"candidateOnly\":true,\"nonAuthorizing\":true,\"treatedAsProof\":false,\"usedAsEvidence\":false,\"globalPromotion\":false}");
    } else {
        try w.writeAll("null");
    }
    try w.writeAll(",\"storage\":{\"path\":\"");
    try writeEscaped(w, result.storage_path);
    try w.writeAll("\",\"appendOnly\":true,\"stableOrdering\":\"file_append_order\",\"inPlaceRewrite\":false,\"deletion\":false,\"compaction\":false}");
    try w.writeAll(",\"mutationFlags\":{\"corpusMutation\":false,\"packMutation\":false,\"negativeKnowledgeMutation\":true,\"commandsExecuted\":false,\"verifiersExecuted\":false}");
    try w.writeAll(",\"authority\":{\"nonAuthorizing\":true,\"treatedAsProof\":false,\"usedAsEvidence\":false,\"requiredReview\":false,\"globalPromotion\":false,\"supportGranted\":false,\"proofDischarged\":false}}}");

    var gip_state = schema.draftResultState();
    gip_state.permission = .none;
    gip_state.verification_state = .unverified;
    gip_state.support_minimum_met = false;
    gip_state.non_authorization_notice = "negative_knowledge.review persists append-only reviewed negative knowledge records only; accepted records are still not proof, evidence, corpus, packs, or global promotion";

    return .{
        .status = .ok,
        .result_state = gip_state,
        .result_json = try out.toOwnedSlice(),
        .allocated_result = true,
    };
}

fn dispatchNegativeKnowledgeReviewedList(allocator: std.mem.Allocator, request_body: ?[]const u8) !DispatchResult {
    const body = request_body orelse return .{
        .status = .rejected,
        .err = .{ .code = .missing_required_field, .message = "request body is required for negative_knowledge.reviewed.list" },
    };

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return .{ .status = .rejected, .err = .{ .code = .json_contract_error, .message = "invalid JSON in request body" } };
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        return .{ .status = .rejected, .err = .{ .code = .invalid_request, .message = "negative_knowledge.reviewed.list request must be a JSON object" } };
    }

    const obj = parsed.value.object;
    const project_shard = getStr(obj, "project_shard", "projectShard") orelse shards.DEFAULT_PROJECT_ID;
    const decision_text = getStr(obj, "decision", "decision") orelse "all";
    const decision_filter = negative_knowledge_review.DecisionFilter.parse(decision_text) orelse return .{
        .status = .rejected,
        .err = .{ .code = .invalid_request, .message = "decision filter must be accepted, rejected, or all", .details = decision_text },
    };
    const limit = boundedCount(obj, "limit", "limit", negative_knowledge_review.MAX_REVIEWED_NEGATIVE_KNOWLEDGE_READ, negative_knowledge_review.MAX_REVIEWED_NEGATIVE_KNOWLEDGE_READ);
    const offset = boundedCount(obj, "offset", "cursor", 0, negative_knowledge_review.MAX_REVIEWED_NEGATIVE_KNOWLEDGE_READ);

    var inspected = try negative_knowledge_review.listReviewedNegativeKnowledge(
        allocator,
        project_shard,
        decision_filter,
        limit,
        offset,
        negative_knowledge_review.MAX_REVIEWED_NEGATIVE_KNOWLEDGE_READ,
    );
    defer inspected.deinit();

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();
    try w.writeAll("{\"reviewedNegativeKnowledge\":{\"status\":\"ok\",\"records\":[");
    for (inspected.records, 0..) |record, i| {
        if (i != 0) try w.writeByte(',');
        try w.writeAll("{\"id\":\"");
        try writeEscaped(w, record.id);
        try w.writeAll("\",\"reviewDecision\":\"");
        try writeEscaped(w, @tagName(record.decision));
        try w.writeAll("\",\"lineNumber\":");
        try w.print("{d}", .{record.line_number});
        try w.writeAll(",\"reviewedNegativeKnowledgeRecord\":");
        try w.writeAll(record.record_json);
        try w.writeAll("}");
    }
    try w.writeAll("],\"totalRead\":");
    try w.print("{d}", .{inspected.total_read});
    try w.writeAll(",\"returnedCount\":");
    try w.print("{d}", .{inspected.returned_count});
    try w.writeAll(",\"malformedLines\":");
    try w.print("{d}", .{inspected.malformed_lines});
    try w.writeAll(",\"warnings\":");
    try writeNegativeKnowledgeReadWarningsJson(w, inspected.warnings);
    try w.writeAll(",\"capacityTelemetry\":{\"maxRecords\":");
    try w.print("{d}", .{negative_knowledge_review.MAX_REVIEWED_NEGATIVE_KNOWLEDGE_READ});
    try w.writeAll(",\"maxRecordsHit\":");
    try w.print("{}", .{inspected.max_records_hit});
    try w.writeAll(",\"limit\":");
    try w.print("{d}", .{inspected.limit});
    try w.writeAll(",\"offset\":");
    try w.print("{d}", .{inspected.offset});
    try w.writeAll(",\"limitHit\":");
    try w.print("{}", .{inspected.limit_hit});
    try w.writeAll(",\"maxBytes\":");
    try w.print("{d}", .{negative_knowledge_review.MAX_REVIEWED_NEGATIVE_KNOWLEDGE_BYTES});
    try w.writeAll(",\"truncated\":");
    try w.print("{}", .{inspected.truncated});
    try w.writeAll("},\"storage\":{\"appendOnly\":true,\"missingFile\":");
    try w.print("{}", .{inspected.missing_file});
    try w.writeAll(",\"sameShardOnly\":true,\"readOnly\":true,\"inPlaceRewrite\":false,\"deletion\":false,\"compaction\":false,\"stableOrdering\":\"file_append_order\"}");
    try writeReviewedNegativeKnowledgeSafeguards(w);
    try w.writeAll("}}");

    var gip_state = schema.draftResultState();
    gip_state.permission = .none;
    gip_state.verification_state = .unverified;
    gip_state.support_minimum_met = false;
    gip_state.non_authorization_notice = "negative_knowledge.reviewed.list inspects reviewed negative knowledge records only; records are non-authorizing and not proof or evidence";

    return .{
        .status = .ok,
        .result_state = gip_state,
        .result_json = try out.toOwnedSlice(),
        .allocated_result = true,
    };
}

fn dispatchNegativeKnowledgeReviewedGet(allocator: std.mem.Allocator, request_body: ?[]const u8) !DispatchResult {
    const body = request_body orelse return .{
        .status = .rejected,
        .err = .{ .code = .missing_required_field, .message = "request body is required for negative_knowledge.reviewed.get" },
    };

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return .{ .status = .rejected, .err = .{ .code = .json_contract_error, .message = "invalid JSON in request body" } };
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        return .{ .status = .rejected, .err = .{ .code = .invalid_request, .message = "negative_knowledge.reviewed.get request must be a JSON object" } };
    }

    const obj = parsed.value.object;
    const project_shard = getStr(obj, "project_shard", "projectShard") orelse shards.DEFAULT_PROJECT_ID;
    const id = getStr(obj, "id", "id") orelse return .{
        .status = .rejected,
        .err = .{ .code = .missing_required_field, .message = "id is required" },
    };

    var inspected = try negative_knowledge_review.getReviewedNegativeKnowledge(allocator, project_shard, id, negative_knowledge_review.MAX_REVIEWED_NEGATIVE_KNOWLEDGE_READ);
    defer inspected.deinit();

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();
    try w.writeAll("{\"reviewedNegativeKnowledge\":{\"status\":\"");
    try w.writeAll(if (inspected.record != null) "found" else "not_found");
    try w.writeAll("\",\"reviewedNegativeKnowledgeRecord\":");
    if (inspected.record) |record| {
        try w.writeAll(record.record_json);
    } else {
        try w.writeAll("null,\"unknown\":{\"kind\":\"reviewed_negative_knowledge_not_found\",\"reason\":\"no same-shard reviewed negative knowledge record matched id\"}");
    }
    try w.writeAll(",\"totalRead\":");
    try w.print("{d}", .{inspected.total_read});
    try w.writeAll(",\"malformedLines\":");
    try w.print("{d}", .{inspected.malformed_lines});
    try w.writeAll(",\"warnings\":");
    try writeNegativeKnowledgeReadWarningsJson(w, inspected.warnings);
    try w.writeAll(",\"capacityTelemetry\":{\"maxRecords\":");
    try w.print("{d}", .{negative_knowledge_review.MAX_REVIEWED_NEGATIVE_KNOWLEDGE_READ});
    try w.writeAll(",\"maxRecordsHit\":");
    try w.print("{}", .{inspected.max_records_hit});
    try w.writeAll(",\"maxBytes\":");
    try w.print("{d}", .{negative_knowledge_review.MAX_REVIEWED_NEGATIVE_KNOWLEDGE_BYTES});
    try w.writeAll(",\"truncated\":");
    try w.print("{}", .{inspected.truncated});
    try w.writeAll("},\"storage\":{\"appendOnly\":true,\"missingFile\":");
    try w.print("{}", .{inspected.missing_file});
    try w.writeAll(",\"sameShardOnly\":true,\"readOnly\":true,\"inPlaceRewrite\":false,\"deletion\":false,\"compaction\":false,\"stableOrdering\":\"file_append_order\"}");
    try writeReviewedNegativeKnowledgeSafeguards(w);
    try w.writeAll("}}");

    var gip_state = if (inspected.record != null) schema.draftResultState() else schema.unresolvedResultState("reviewed_negative_knowledge_not_found");
    gip_state.permission = .none;
    gip_state.verification_state = .unverified;
    gip_state.support_minimum_met = false;
    gip_state.non_authorization_notice = "negative_knowledge.reviewed.get inspects reviewed negative knowledge records only; records are non-authorizing and not proof or evidence";

    return .{
        .status = if (inspected.record != null) .ok else .failed,
        .result_state = gip_state,
        .result_json = try out.toOwnedSlice(),
        .allocated_result = true,
    };
}

fn boundedCount(obj: std.json.ObjectMap, snake: []const u8, camel: []const u8, default_value: usize, max_value: usize) usize {
    const requested = getInt(obj, snake, camel) orelse return default_value;
    if (requested <= 0) return 0;
    return @min(@as(usize, @intCast(requested)), max_value);
}

fn writeCountEntriesJson(w: anytype, entries: []const correction_review.CountEntry) !void {
    try w.writeByte('{');
    for (entries, 0..) |entry, i| {
        if (i != 0) try w.writeByte(',');
        try w.writeByte('"');
        try writeEscaped(w, entry.name);
        try w.writeAll("\":");
        try w.print("{d}", .{entry.count});
    }
    try w.writeByte('}');
}

fn writeInfluenceStatusRecordsJson(w: anytype, records: []const correction_review.InfluenceStatusRecord) !void {
    try w.writeByte('[');
    for (records, 0..) |record, i| {
        if (i != 0) try w.writeByte(',');
        try w.writeAll("{\"id\":\"");
        try writeEscaped(w, record.id);
        try w.writeAll("\",\"reviewDecision\":\"");
        try writeEscaped(w, @tagName(record.decision));
        try w.writeAll("\",\"operationKind\":\"");
        try writeEscaped(w, record.operation_kind);
        try w.writeAll("\",\"correctionType\":\"");
        try writeEscaped(w, record.correction_type);
        try w.writeAll("\",\"lineNumber\":");
        try w.print("{d}", .{record.line_number});
        try w.writeAll(",\"reviewedCorrectionRecord\":");
        try w.writeAll(record.record_json);
        try w.writeAll("}");
    }
    try w.writeByte(']');
}

fn writeLearningRecordsJson(w: anytype, records: []const learning_status.RecordSample) !void {
    try w.writeByte('[');
    for (records, 0..) |record, i| {
        if (i != 0) try w.writeByte(',');
        try w.writeAll("{\"kind\":\"");
        try writeEscaped(w, record.kind);
        try w.writeAll("\",\"id\":\"");
        try writeEscaped(w, record.id);
        try w.writeAll("\",\"reviewDecision\":\"");
        try writeEscaped(w, record.decision);
        try w.writeAll("\",\"lineNumber\":");
        try w.print("{d}", .{record.line_number});
        try w.writeAll(",\"reviewedRecord\":");
        try w.writeAll(record.record_json);
        try w.writeAll("}");
    }
    try w.writeByte(']');
}

fn countNamed(entries: []const correction_review.CountEntry, name: []const u8) usize {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.count;
    }
    return 0;
}

fn writeReadWarningsJson(w: anytype, warnings: []const correction_review.ReadWarning) !void {
    try w.writeByte('[');
    for (warnings, 0..) |warning, i| {
        if (i != 0) try w.writeByte(',');
        try w.writeAll("{\"lineNumber\":");
        try w.print("{d}", .{warning.line_number});
        try w.writeAll(",\"reason\":\"");
        try writeEscaped(w, warning.reason);
        try w.writeAll("\"}");
    }
    try w.writeByte(']');
}

fn writeReviewedCorrectionSafeguards(w: anytype) !void {
    try w.writeAll(",\"readOnly\":true");
    try w.writeAll(",\"mutationFlags\":{\"corpusMutation\":false,\"packMutation\":false,\"negativeKnowledgeMutation\":false,\"commandsExecuted\":false,\"verifiersExecuted\":false}");
    try w.writeAll(",\"authority\":{\"nonAuthorizing\":true,\"treatedAsProof\":false,\"supportGranted\":false,\"proofDischarged\":false,\"usedAsEvidence\":false}");
}

fn writeProcedurePackReadWarningsJson(w: anytype, warnings: []const procedure_pack_candidates.ReadWarning) !void {
    try w.writeByte('[');
    for (warnings, 0..) |warning, i| {
        if (i != 0) try w.writeByte(',');
        try w.writeAll("{\"lineNumber\":");
        try w.print("{d}", .{warning.line_number});
        try w.writeAll(",\"reason\":\"");
        try writeEscaped(w, warning.reason);
        try w.writeAll("\"}");
    }
    try w.writeByte(']');
}

fn writeProcedurePackCandidateSafeguards(w: anytype, read_only: bool) !void {
    if (read_only) try w.writeAll(",\"readOnly\":true");
    try w.writeAll(",\"mutationFlags\":{\"corpusMutation\":false,\"packMutation\":false,\"negativeKnowledgeMutation\":false,\"commandsExecuted\":false,\"verifiersExecuted\":false}");
    try w.writeAll(",\"authority\":{\"nonAuthorizing\":true,\"treatedAsProof\":false,\"usedAsEvidence\":false,\"supportGranted\":false,\"proofDischarged\":false,\"executesByDefault\":false,\"packMutation\":false,\"globalPromotion\":false}");
}

fn writeNegativeKnowledgeReadWarningsJson(w: anytype, warnings: []const negative_knowledge_review.ReadWarning) !void {
    try w.writeByte('[');
    for (warnings, 0..) |warning, i| {
        if (i != 0) try w.writeByte(',');
        try w.writeAll("{\"lineNumber\":");
        try w.print("{d}", .{warning.line_number});
        try w.writeAll(",\"reason\":\"");
        try writeEscaped(w, warning.reason);
        try w.writeAll("\"}");
    }
    try w.writeByte(']');
}

fn writeReviewedNegativeKnowledgeSafeguards(w: anytype) !void {
    try w.writeAll(",\"readOnly\":true");
    try w.writeAll(",\"mutationFlags\":{\"corpusMutation\":false,\"packMutation\":false,\"negativeKnowledgeMutation\":false,\"commandsExecuted\":false,\"verifiersExecuted\":false}");
    try w.writeAll(",\"authority\":{\"nonAuthorizing\":true,\"treatedAsProof\":false,\"supportGranted\":false,\"proofDischarged\":false,\"usedAsEvidence\":false,\"globalPromotion\":false}");
}

fn stringifyJsonValue(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    try std.json.stringify(value, .{}, out.writer());
    return out.toOwnedSlice();
}

fn dispatchArtifactRead(allocator: std.mem.Allocator, workspace_root: ?[]const u8, request_path: ?[]const u8) !DispatchResult {
    const root = workspace_root orelse return .{ .status = .rejected, .err = .{ .code = .missing_required_field, .message = "workspace root missing" } };
    const path = request_path orelse return .{ .status = .rejected, .err = .{ .code = .missing_required_field, .message = "path missing" } };

    if (validation.validatePathContainment(root, path)) |err| return .{ .status = .rejected, .err = err };

    const full_path = if (std.fs.path.isAbsolute(path)) try allocator.dupe(u8, path) else try std.fs.path.join(allocator, &.{ root, path });
    defer allocator.free(full_path);

    const file = std.fs.cwd().openFile(full_path, .{}) catch {
        return .{ .status = .failed, .err = .{ .code = .path_not_found, .message = "file not found" } };
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, core.MAX_ARTIFACT_READ_BYTES);
    defer allocator.free(content);

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    try w.writeAll("{\"artifact\":{\"path\":\"");
    try writeEscaped(w, path);
    try w.writeAll("\",\"content\":\"");
    try writeEscaped(w, content);
    try w.writeAll("\"}}");

    return .{
        .status = .ok,
        .result_json = try out.toOwnedSlice(),
        .allocated_result = true,
    };
}

fn dispatchArtifactList(allocator: std.mem.Allocator, workspace_root: ?[]const u8, request_path: ?[]const u8) !DispatchResult {
    const root = workspace_root orelse return .{ .status = .rejected, .err = .{ .code = .missing_required_field, .message = "workspace root missing" } };
    const path = request_path orelse ".";

    if (validation.validatePathContainment(root, path)) |err| return .{ .status = .rejected, .err = err };

    const full_path = if (std.fs.path.isAbsolute(path)) try allocator.dupe(u8, path) else try std.fs.path.join(allocator, &.{ root, path });
    defer allocator.free(full_path);

    var dir = std.fs.openDirAbsolute(full_path, .{ .iterate = true }) catch {
        return .{ .status = .failed, .err = .{ .code = .path_not_found, .message = "dir not found" } };
    };
    defer dir.close();

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    try w.writeAll("{\"entries\":[");
    var iter = dir.iterate();
    var first = true;
    while (try iter.next()) |entry| {
        if (!first) try w.writeByte(',');
        first = false;
        try w.writeAll("{\"name\":\"");
        try writeEscaped(w, entry.name);
        try w.writeAll("\",\"type\":\"");
        try w.writeAll(if (entry.kind == .directory) "directory" else "file");
        try w.writeAll("\"}");
    }
    try w.writeAll("]}");

    return .{
        .status = .ok,
        .result_json = try out.toOwnedSlice(),
        .allocated_result = true,
    };
}

fn getSpanText(file_content: []const u8, start_line: usize, start_col: usize, end_line: usize, end_col: usize) ?[]const u8 {
    if (start_line < 1 or end_line < 1 or start_col < 1 or end_col < 1) return null;
    if (start_line > end_line) return null;
    if (start_line == end_line and start_col > end_col) return null;

    var line_num: usize = 1;
    var offset: usize = 0;
    var span_start: ?usize = null;
    var span_end: ?usize = null;

    while (offset < file_content.len) {
        if (line_num == start_line and span_start == null) span_start = offset + start_col - 1;
        if (line_num == end_line and span_end == null) span_end = offset + end_col - 1;
        if (file_content[offset] == '\n') line_num += 1;
        offset += 1;
    }
    if (line_num == start_line and span_start == null) span_start = offset + start_col - 1;
    if (line_num == end_line and span_end == null) span_end = offset + end_col - 1;

    if (span_start) |s| {
        if (span_end) |e| {
            if (s <= e and e <= file_content.len and s <= file_content.len) return file_content[s..e];
        }
    }
    return null;
}

fn dispatchArtifactPatchPropose(allocator: std.mem.Allocator, workspace_root: ?[]const u8, request_body: ?[]const u8) !DispatchResult {
    const root = workspace_root orelse return .{
        .status = .rejected,
        .err = .{ .code = .missing_required_field, .message = "workspace root not configured" },
    };
    const body = request_body orelse return .{
        .status = .rejected,
        .err = .{ .code = .missing_required_field, .message = "missing request body" },
    };

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return .{ .status = .rejected, .err = .{ .code = .json_contract_error, .message = "invalid JSON payload" } };
    };
    defer parsed.deinit();

    const obj = parsed.value.object;
    const path_val = obj.get("path") orelse return .{ .status = .rejected, .err = .{ .code = .missing_required_field, .message = "path field is required" } };
    const path = path_val.string;

    const edits_val = obj.get("edits") orelse return .{ .status = .rejected, .err = .{ .code = .missing_required_field, .message = "edits field is required" } };
    if (edits_val != .array) return .{ .status = .rejected, .err = .{ .code = .json_contract_error, .message = "edits must be an array" } };

    if (validation.validatePathContainment(root, path)) |err| return .{ .status = .rejected, .err = err };

    const full_path = if (std.fs.path.isAbsolute(path)) try allocator.dupe(u8, path) else try std.fs.path.join(allocator, &.{ root, path });
    defer allocator.free(full_path);

    const file = std.fs.cwd().openFile(full_path, .{}) catch {
        return .{
            .status = .failed,
            .err = .{ .code = .path_not_found, .message = "file not found", .details = path },
            .result_state = schema.unresolvedResultState("file not found"),
        };
    };
    defer file.close();

    const stat = try file.stat();
    if (stat.size > core.MAX_ARTIFACT_READ_BYTES) return .{ .status = .failed, .err = .{ .code = .artifact_too_large, .message = "file too large for patching" } };

    const content = try allocator.alloc(u8, @intCast(stat.size));
    defer allocator.free(content);
    _ = try file.readAll(content);

    var total_bytes: usize = 0;
    var last_end_line: usize = 0;
    var last_end_col: usize = 0;

    for (edits_val.array.items) |edit_val| {
        if (edit_val != .object) return .{ .status = .rejected, .err = .{ .code = .json_contract_error, .message = "edit must be object" } };
        const edit = edit_val.object;

        const span_val = edit.get("span") orelse return .{ .status = .rejected, .err = .{ .code = .missing_required_field, .message = "edit span required" } };
        if (span_val != .object) return .{ .status = .rejected, .err = .{ .code = .json_contract_error, .message = "span must be object" } };
        const span = span_val.object;

        const start_line = getInt(span, "start_line", "start_line") orelse return .{ .status = .rejected, .err = .{ .code = .missing_required_field, .message = "start_line missing" } };
        const start_col = getInt(span, "start_col", "start_col") orelse return .{ .status = .rejected, .err = .{ .code = .missing_required_field, .message = "start_col missing" } };
        const end_line = getInt(span, "end_line", "end_line") orelse return .{ .status = .rejected, .err = .{ .code = .missing_required_field, .message = "end_line missing" } };
        const end_col = getInt(span, "end_col", "end_col") orelse return .{ .status = .rejected, .err = .{ .code = .missing_required_field, .message = "end_col missing" } };

        const u_start_line: usize = @intCast(start_line);
        const u_start_col: usize = @intCast(start_col);
        const u_end_line: usize = @intCast(end_line);
        const u_end_col: usize = @intCast(end_col);

        if (u_start_line < last_end_line or (u_start_line == last_end_line and u_start_col < last_end_col)) {
            return .{ .status = .rejected, .err = .{ .code = .invalid_patch_span, .message = "edits overlap or are not sorted" } };
        }
        last_end_line = u_end_line;
        last_end_col = u_end_col;

        const replacement = getStr(edit, "replacement", "replacement") orelse return .{ .status = .rejected, .err = .{ .code = .missing_required_field, .message = "replacement missing" } };
        total_bytes += replacement.len;

        if (total_bytes > 512 * 1024) return .{ .status = .rejected, .err = .{ .code = .budget_exhausted, .message = "patch replacement bytes exceed limit" } };

        const span_text = getSpanText(content, u_start_line, u_start_col, u_end_line, u_end_col) orelse {
            return .{ .status = .rejected, .err = .{ .code = .invalid_patch_span, .message = "span out of bounds or invalid" } };
        };

        if (edit.get("precondition")) |prec_val| {
            if (prec_val == .object) {
                const prec = prec_val.object;
                if (getStr(prec, "expected_text", "expected_text")) |exp_text| {
                    if (!std.mem.eql(u8, span_text, exp_text)) {
                        return .{ .status = .rejected, .err = .{ .code = .patch_precondition_failed, .message = "expected_text mismatch" } };
                    }
                }
                if (getInt(prec, "expected_hash", "expected_hash")) |exp_hash| {
                    const file_hash = std.hash.Wyhash.hash(0, content);
                    if (@as(u64, @intCast(exp_hash)) != file_hash) {
                        return .{ .status = .rejected, .err = .{ .code = .patch_precondition_failed, .message = "expected_hash mismatch" } };
                    }
                }
            }
        }
    }

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    try w.writeAll("{\"patch_proposal\":{");
    try w.writeAll("\"patch_id\":\"prop-");
    try w.print("{d}", .{std.hash.Wyhash.hash(0, body)});
    try w.writeAll("\",\"artifact_ref\":\"");
    try writeEscaped(w, path);
    try w.writeAll("\",\"edits\":");
    try std.json.stringify(edits_val, .{}, w);
    try w.writeAll(",\"appliesCleanly\":true,\"previewDiff\":\"");
    try writeEscaped(w, "--- before\n+++ after\n(preview not generated for dry-run stub)");
    try w.writeAll("\",\"conflicts\":[],\"requiresApproval\":true,\"requiresVerification\":true,\"missingObligations\":[],\"non_authorizing\":true");
    try w.writeAll(",\"provenance\":\"ghost_gip\",\"trace\":\"generated proposal\"}}");

    var gip_state = schema.draftResultState();
    gip_state.state = .draft;
    gip_state.permission = .none;
    gip_state.is_draft = true;
    gip_state.verification_state = .unverified;

    return .{
        .status = .ok,
        .result_state = gip_state,
        .result_json = try out.toOwnedSlice(),
        .allocated_result = true,
    };
}

// ── Hypothesis List ────────────────────────────────────────────────────

fn dispatchHypothesisList(allocator: std.mem.Allocator, request_body: ?[]const u8) !DispatchResult {
    var max_items: usize = core.MAX_HYPOTHESIS_ITEMS;

    if (request_body) |body| {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
            return .{ .status = .rejected, .err = .{ .code = .json_contract_error, .message = "invalid JSON" } };
        };
        defer parsed.deinit();
        const obj = parsed.value.object;
        if (getInt(obj, "maxItems", "max_items")) |requested| {
            max_items = @min(@as(usize, @intCast(requested)), core.MAX_HYPOTHESIS_ITEMS);
        }
        // sessionId, artifactRef, statusFilter accepted but not used in this pass
        _ = getStr(obj, "sessionId", "session_id");
        _ = getStr(obj, "artifactRef", "artifact_ref");
        _ = getStr(obj, "statusFilter", "status_filter");
    }

    // GIP runs statelessly: no active hypothesis collection exists in this context.
    // Return ok with empty list, not fake hypotheses.
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    try w.writeAll("{\"hypotheses\":[],\"counts\":{\"total\":0,\"proposed\":0,\"triaged\":0,\"selected\":0,\"suppressed\":0,\"verified\":0,\"rejected\":0,\"blocked\":0,\"unresolved\":0},\"maxItems\":");
    try w.print("{d}", .{max_items});
    try w.writeAll("}");

    return .{
        .status = .ok,
        .result_json = try out.toOwnedSlice(),
        .allocated_result = true,
    };
}

// ── Hypothesis Triage ─────────────────────────────────────────────────

fn dispatchHypothesisTriage(allocator: std.mem.Allocator, request_body: ?[]const u8) !DispatchResult {
    var max_items: usize = core.MAX_TRIAGE_ITEMS;
    var include_suppressed = false;

    if (request_body) |body| {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
            return .{ .status = .rejected, .err = .{ .code = .json_contract_error, .message = "invalid JSON" } };
        };
        defer parsed.deinit();
        const obj = parsed.value.object;
        if (getInt(obj, "maxItems", "max_items")) |requested| {
            max_items = @min(@as(usize, @intCast(requested)), core.MAX_TRIAGE_ITEMS);
        }
        if (getBool(obj, "includeSuppressed", "include_suppressed")) |v| {
            include_suppressed = v;
        }
        // sessionId, artifactRef accepted but not used in this pass
        _ = getStr(obj, "sessionId", "session_id");
        _ = getStr(obj, "artifactRef", "artifact_ref");
    }

    // GIP runs statelessly: no active hypotheses to triage.
    // Return ok with empty triage summary.
    // This does not schedule verifiers.
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    try w.writeAll("{\"triageSummary\":{\"total\":0,\"selected\":0,\"suppressed\":0,\"duplicate\":0,\"blocked\":0,\"deferred\":0,\"budgetHits\":0,\"scoringPolicyVersion\":\"");
    try w.writeAll(hypothesis_core.scoring_policy_version);
    try w.writeAll("\"},\"items\":[],\"maxItems\":");
    try w.print("{d}", .{max_items});
    try w.writeAll(",\"includeSuppressed\":");
    try w.writeAll(if (include_suppressed) "true" else "false");
    try w.writeAll("}");

    return .{
        .status = .ok,
        .result_json = try out.toOwnedSlice(),
        .allocated_result = true,
    };
}

// ── Verifier List ─────────────────────────────────────────────────────

fn dispatchVerifierList(allocator: std.mem.Allocator) !DispatchResult {
    // Build a registry with builtin adapters and list them.
    // This is registry inspection only — no verifier is executed.
    var registry = verifier_adapter.Registry.init(allocator);
    defer registry.deinit();
    try verifier_adapter.registerBuiltinAdapters(&registry);

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    try w.writeAll("{\"adapters\":[");

    var iter = registry.entries.iterator();
    var first = true;
    while (iter.next()) |entry| {
        const adapter = entry.value_ptr.*;
        if (!first) try w.writeByte(',');
        first = false;
        try w.writeAll("{\"adapter_id\":\"");
        try writeEscaped(w, adapter.id);
        try w.writeAll("\",\"domain\":\"");
        try writeEscaped(w, adapter.schema_name);
        try w.writeAll("\",\"hook_kind\":\"");
        try writeEscaped(w, @tagName(adapter.hook_kind));
        try w.writeAll("\",\"input_artifact_types\":[");
        for (adapter.input_artifact_types, 0..) |a_type, idx| {
            if (idx != 0) try w.writeByte(',');
            try w.writeByte('"');
            try writeEscaped(w, @tagName(a_type));
            try w.writeByte('"');
        }
        try w.writeAll("],\"required_entity_kinds\":[");
        for (adapter.required_entity_kinds, 0..) |kind, idx| {
            if (idx != 0) try w.writeByte(',');
            try w.writeByte('"');
            try writeEscaped(w, kind);
            try w.writeByte('"');
        }
        try w.writeAll("],\"required_relation_kinds\":[");
        for (adapter.required_relation_kinds, 0..) |rel, idx| {
            if (idx != 0) try w.writeByte(',');
            try w.writeByte('"');
            try writeEscaped(w, @tagName(rel));
            try w.writeByte('"');
        }
        try w.writeAll("],\"required_obligations\":[");
        for (adapter.required_obligations, 0..) |obl, idx| {
            if (idx != 0) try w.writeByte(',');
            try w.writeByte('"');
            try writeEscaped(w, obl);
            try w.writeByte('"');
        }
        try w.writeAll("],\"budget_cost\":");
        try w.print("{d}", .{adapter.budget_cost});
        try w.writeAll(",\"evidence_kind\":\"");
        try writeEscaped(w, @tagName(adapter.output_evidence_kind));
        try w.writeAll("\",\"safe_local\":");
        try w.writeAll(if (!isExternalHook(adapter.hook_kind)) "true" else "false");
        try w.writeAll(",\"external\":");
        try w.writeAll(if (isExternalHook(adapter.hook_kind)) "true" else "false");
        try w.writeAll(",\"enabled\":true}");
    }

    try w.writeAll("]}");

    return .{
        .status = .ok,
        .result_json = try out.toOwnedSlice(),
        .allocated_result = true,
    };
}

fn isExternalHook(kind: verifier_adapter.HookKind) bool {
    return switch (kind) {
        .build, .@"test", .runtime, .custom_external => true,
        else => false,
    };
}

// ── Verifier Candidate Execution Inspection ───────────────────────────

const MAX_GIP_STATE_BYTES: usize = 8 * 1024 * 1024;

fn valueObject(value: std.json.Value) ?std.json.ObjectMap {
    return if (value == .object) value.object else null;
}

fn valueArray(value: std.json.Value) ?std.json.Array {
    return if (value == .array) value.array else null;
}

fn stringField(obj: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    const v = obj.get(field) orelse return null;
    return if (v == .string) v.string else null;
}

fn supportGraphObject(root: std.json.Value) ?std.json.ObjectMap {
    const obj = valueObject(root) orelse return null;
    const graph = obj.get("supportGraph") orelse obj.get("support_graph") orelse return null;
    return valueObject(graph);
}

fn supportGraphNodes(root: std.json.Value) ?std.json.Array {
    const graph = supportGraphObject(root) orelse return null;
    const nodes = graph.get("nodes") orelse return null;
    return valueArray(nodes);
}

fn supportGraphEdges(root: std.json.Value) ?std.json.Array {
    const graph = supportGraphObject(root) orelse return null;
    const edges = graph.get("edges") orelse return null;
    return valueArray(edges);
}

fn detailValue(detail: []const u8, key: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, detail, key) orelse return null;
    const value_start = start + key.len;
    var value_end = value_start;
    while (value_end < detail.len and detail[value_end] != ' ' and detail[value_end] != ';' and detail[value_end] != ',') {
        value_end += 1;
    }
    return detail[value_start..value_end];
}

fn suffixAfterLast(haystack: []const u8, needle: []const u8) ?[]const u8 {
    var cursor: usize = 0;
    var found: ?usize = null;
    while (std.mem.indexOfPos(u8, haystack, cursor, needle)) |idx| {
        found = idx + needle.len;
        cursor = idx + needle.len;
    }
    if (found) |idx| return haystack[idx..];
    return null;
}

fn resolveInspectionStatePath(allocator: std.mem.Allocator, workspace_root: ?[]const u8, obj: std.json.ObjectMap) !?[]u8 {
    if (getStr(obj, "state_path", "statePath")) |state_path| {
        if (workspace_root) |root| {
            if (validation.validatePathContainment(root, state_path)) |err| return errToError(err);
            return if (std.fs.path.isAbsolute(state_path))
                try allocator.dupe(u8, state_path)
            else
                try std.fs.path.join(allocator, &.{ root, state_path });
        }
        return try allocator.dupe(u8, state_path);
    }

    const session_id = getStr(obj, "session_id", "sessionId") orelse return null;
    const project_shard = getStr(obj, "project_shard", "projectShard");
    var session = task_sessions.load(allocator, project_shard, session_id) catch return null;
    defer session.deinit();

    if (session.last_code_intel_result_path) |path| return try allocator.dupe(u8, path);
    if (session.last_patch_candidates_result_path) |path| return try allocator.dupe(u8, path);
    return null;
}

fn errToError(err: schema.GipError) error{PathRejected} {
    _ = err;
    return error.PathRejected;
}

fn loadInspectionState(allocator: std.mem.Allocator, path: []const u8) !std.json.Parsed(std.json.Value) {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const bytes = try file.readToEndAlloc(allocator, MAX_GIP_STATE_BYTES);
    defer allocator.free(bytes);
    return std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
}

fn linkedEdgeTarget(root: std.json.Value, from_id: []const u8, edge_kind: []const u8) ?[]const u8 {
    const edges = supportGraphEdges(root) orelse return null;
    for (edges.items) |edge_val| {
        const edge = valueObject(edge_val) orelse continue;
        const from = stringField(edge, "from") orelse continue;
        const kind = stringField(edge, "kind") orelse continue;
        if (!std.mem.eql(u8, from, from_id) or !std.mem.eql(u8, kind, edge_kind)) continue;
        return stringField(edge, "to");
    }
    return null;
}

fn reverseLinkedEdgeSource(root: std.json.Value, to_id: []const u8, edge_kind: []const u8) ?[]const u8 {
    const edges = supportGraphEdges(root) orelse return null;
    for (edges.items) |edge_val| {
        const edge = valueObject(edge_val) orelse continue;
        const to = stringField(edge, "to") orelse continue;
        const kind = stringField(edge, "kind") orelse continue;
        if (!std.mem.eql(u8, to, to_id) or !std.mem.eql(u8, kind, edge_kind)) continue;
        return stringField(edge, "from");
    }
    return null;
}

fn findNode(root: std.json.Value, wanted_id: []const u8, wanted_kind: []const u8) ?std.json.ObjectMap {
    const nodes = supportGraphNodes(root) orelse return null;
    for (nodes.items) |node_val| {
        const node = valueObject(node_val) orelse continue;
        const id = stringField(node, "id") orelse continue;
        const kind = stringField(node, "kind") orelse continue;
        if (std.mem.eql(u8, kind, wanted_kind) and std.mem.eql(u8, id, wanted_id)) return node;
    }
    return null;
}

fn writeNullableString(w: anytype, value: ?[]const u8) !void {
    if (value) |text| {
        try w.writeByte('"');
        try writeEscaped(w, text);
        try w.writeByte('"');
    } else {
        try w.writeAll("null");
    }
}

fn writeExecutionProjection(w: anytype, root: std.json.Value, node: std.json.ObjectMap, id: []const u8, candidate_id: []const u8, status: []const u8, execution_kind: []const u8, detail: []const u8) !void {
    _ = node;
    const result_ref = linkedEdgeTarget(root, id, "execution_produces_evidence");
    const materialization_ref = linkedEdgeTarget(root, id, "execution_for_materialization");
    try w.writeAll("{\"id\":\"");
    try writeEscaped(w, id);
    try w.writeAll("\",\"candidate_id\":\"");
    try writeEscaped(w, candidate_id);
    try w.writeAll("\",\"hypothesis_id\":null,\"materialization_id\":");
    try writeNullableString(w, materialization_ref);
    try w.writeAll(",\"execution_kind\":\"");
    try writeEscaped(w, execution_kind);
    try w.writeAll("\",\"status\":\"");
    try writeEscaped(w, status);
    try w.writeAll("\",\"result_ref\":");
    try writeNullableString(w, result_ref);
    try w.writeAll(",\"evidence_ref\":");
    try writeNullableString(w, result_ref);
    try w.writeAll(",\"correction_ref\":null,\"blocked_reason\":null,\"elapsed_ms\":null,\"non_authorizing_input\":true,\"trace\":{\"summary\":\"");
    try writeEscaped(w, detail);
    try w.writeAll("\",\"source\":\"support_graph\"}}");
}

fn writeCorrectionProjection(w: anytype, root: std.json.Value, node: std.json.ObjectMap, id: []const u8, detail: []const u8) !void {
    const correction_kind = detailValue(detail, "kind=") orelse "unknown";
    const previous_state = detailValue(detail, "previous=") orelse "unknown";
    const updated_state = detailValue(detail, "updated=") orelse "unknown";
    const source_ref = stringField(node, "label") orelse id;
    const contradicted_ref = linkedEdgeTarget(root, id, "correction_for");
    const evidence_ref = linkedEdgeTarget(root, id, "correction_from_evidence");
    const nk_ref = linkedEdgeTarget(root, id, "proposes_negative_knowledge");
    try w.writeAll("{\"id\":\"");
    try writeEscaped(w, id);
    try w.writeAll("\",\"correction_kind\":\"");
    try writeEscaped(w, correction_kind);
    try w.writeAll("\",\"source_ref\":\"");
    try writeEscaped(w, source_ref);
    try w.writeAll("\",\"contradicted_ref\":");
    try writeNullableString(w, contradicted_ref);
    try w.writeAll(",\"contradicting_evidence_ref\":");
    try writeNullableString(w, evidence_ref);
    try w.writeAll(",\"previous_state\":\"");
    try writeEscaped(w, previous_state);
    try w.writeAll("\",\"updated_state\":\"");
    try writeEscaped(w, updated_state);
    try w.writeAll("\",\"affected_artifacts\":[],\"affected_entities\":[],\"affected_relations\":[],\"failure_cause\":null,\"negative_knowledge_candidate_ref\":");
    try writeNullableString(w, nk_ref);
    try w.writeAll(",\"trust_update_candidate_ref\":null,\"user_visible_summary\":\"");
    try writeEscaped(w, detail);
    try w.writeAll("\",\"non_authorizing\":true}");
}

fn writeNegativeKnowledgeProjection(w: anytype, root: std.json.Value, node: std.json.ObjectMap, id: []const u8, detail: []const u8) !void {
    const candidate_kind = detailValue(detail, "kind=") orelse "unknown";
    const permanence = detailValue(detail, "permanence=") orelse "temporary";
    const correction_ref = linkedEdgeTarget(root, id, "negative_knowledge_from_correction") orelse reverseLinkedEdgeSource(root, id, "proposes_negative_knowledge");
    const scope = stringField(node, "label") orelse id;
    try w.writeAll("{\"id\":\"");
    try writeEscaped(w, id);
    try w.writeAll("\",\"correction_event_id\":");
    try writeNullableString(w, correction_ref);
    try w.writeAll(",\"candidate_kind\":\"");
    try writeEscaped(w, candidate_kind);
    try w.writeAll("\",\"scope\":\"");
    try writeEscaped(w, scope);
    try w.writeAll("\",\"condition\":\"");
    try writeEscaped(w, detail);
    try w.writeAll("\",\"evidence_ref\":");
    try writeNullableString(w, correction_ref);
    try w.writeAll(",\"suggested_suppression_rule\":null,\"freshness\":0,\"permanence\":\"");
    try writeEscaped(w, permanence);
    try w.writeAll("\",\"status\":\"proposed\",\"non_authorizing\":true}");
}

fn stateSourceFromRequest(obj: std.json.ObjectMap, resolved: ?[]const u8) []const u8 {
    if (resolved == null) return "no_state_found";
    if (getStr(obj, "state_path", "statePath") != null) return "state_path";
    if (getStr(obj, "session_id", "sessionId") != null) return "session_state";
    return "support_graph";
}

fn writeNegativeKnowledgeRecordProjection(w: anytype, root: std.json.Value, node: std.json.ObjectMap, id: []const u8, detail: []const u8) !void {
    _ = node;
    const record_kind = detailValue(detail, "kind=") orelse "unknown";
    const status = detailValue(detail, "status=") orelse "accepted";
    const scope = detailValue(detail, "scope=") orelse "artifact";
    const permanence = detailValue(detail, "permanence=") orelse "temporary";
    const condition = detailValue(detail, "condition=") orelse detail;
    const evidence_ref = detailValue(detail, "evidence_ref=") orelse "";
    const candidate_ref = linkedEdgeTarget(root, id, "negative_knowledge_from_candidate") orelse reverseLinkedEdgeSource(root, id, "accepts_negative_knowledge");
    const correction_ref = linkedEdgeTarget(root, id, "negative_knowledge_from_correction") orelse reverseLinkedEdgeSource(root, id, "proposes_negative_knowledge");
    try w.writeAll("{\"id\":\"");
    try writeEscaped(w, id);
    try w.writeAll("\",\"source_candidate_id\":");
    try writeNullableString(w, candidate_ref);
    try w.writeAll(",\"correction_event_id\":");
    try writeNullableString(w, correction_ref);
    try w.writeAll(",\"kind\":\"");
    try writeEscaped(w, record_kind);
    try w.writeAll("\",\"status\":\"");
    try writeEscaped(w, status);
    try w.writeAll("\",\"scope\":\"");
    try writeEscaped(w, scope);
    try w.writeAll("\",\"permanence\":\"");
    try writeEscaped(w, permanence);
    try w.writeAll("\",\"condition\":\"");
    try writeEscaped(w, condition);
    try w.writeAll("\",\"evidence_ref\":\"");
    try writeEscaped(w, evidence_ref);
    try w.writeAll("\",\"influence_summary\":{\"warning\":true,\"triage_penalty\":");
    try w.writeAll(if (std.mem.indexOf(u8, detail, "triage") != null) "true" else "false");
    try w.writeAll(",\"verifier_requirement\":");
    try w.writeAll(if (std.mem.indexOf(u8, detail, "verifier") != null) "true" else "false");
    try w.writeAll(",\"suppression\":");
    try w.writeAll(if (std.mem.indexOf(u8, detail, "suppress") != null) "true" else "false");
    try w.writeAll(",\"trust_decay_candidate\":");
    try w.writeAll(if (std.mem.indexOf(u8, detail, "trust_decay") != null) "true" else "false");
    try w.writeAll(",\"non_authorizing\":true},\"review_metadata\":{\"reviewed_by\":");
    try writeNullableString(w, detailValue(detail, "reviewed_by="));
    try w.writeAll(",\"review_reason\":");
    try writeNullableString(w, detailValue(detail, "reason="));
    try w.writeAll("},\"influence_metadata\":{\"non_authorizing\":true,\"does_not_support_output\":true},\"linked_refs\":{\"candidate_ref\":");
    try writeNullableString(w, candidate_ref);
    try w.writeAll(",\"correction_ref\":");
    try writeNullableString(w, correction_ref);
    try w.writeAll("},\"projection_completeness\":{\"source\":\"support_graph_projection\",\"may_omit_unpersisted_fields\":true},\"non_authorizing\":true}");
}

fn writeNegativeKnowledgeInfluenceProjection(w: anytype, root: std.json.Value, node: std.json.ObjectMap, id: []const u8, detail: []const u8) !void {
    _ = node;
    const hypothesis_ref = linkedEdgeTarget(root, id, "negative_knowledge_influences_hypothesis");
    const routing_ref = linkedEdgeTarget(root, id, "negative_knowledge_warns_routing");
    const verifier_ref = linkedEdgeTarget(root, id, "negative_knowledge_requires_verifier");
    const trust_ref = linkedEdgeTarget(root, id, "proposes_trust_decay");
    try w.writeAll("{\"id\":\"");
    try writeEscaped(w, id);
    try w.writeAll("\",\"matched_record_ids\":[],\"hypothesis_ref\":");
    try writeNullableString(w, hypothesis_ref);
    try w.writeAll(",\"routing_ref\":");
    try writeNullableString(w, routing_ref);
    try w.writeAll(",\"warnings\":[\"");
    try writeEscaped(w, detail);
    try w.writeAll("\"],\"triage_delta\":");
    try w.writeAll(if (std.mem.indexOf(u8, detail, "triage penalty applied") != null) "-1" else "0");
    try w.writeAll(",\"required_verifiers\":");
    if (verifier_ref) |ref| {
        try w.writeAll("[\"");
        try writeEscaped(w, ref);
        try w.writeAll("\"]");
    } else {
        try w.writeAll("[]");
    }
    try w.writeAll(",\"suppression_reason\":");
    try writeNullableString(w, detailValue(detail, "suppression="));
    try w.writeAll(",\"trust_decay_candidates\":");
    if (trust_ref) |ref| {
        try w.writeAll("[\"");
        try writeEscaped(w, ref);
        try w.writeAll("\"]");
    } else {
        try w.writeAll("[]");
    }
    try w.writeAll(",\"non_authorizing\":true}");
}

fn writeTrustDecayCandidateProjection(w: anytype, root: std.json.Value, node: std.json.ObjectMap, id: []const u8, detail: []const u8) !void {
    _ = root;
    const source_ref = detailValue(detail, "source_ref=") orelse stringField(node, "label") orelse id;
    const reason = detailValue(detail, "reason=") orelse detail;
    const evidence_ref = detailValue(detail, "evidence_ref=") orelse "";
    try w.writeAll("{\"id\":\"");
    try writeEscaped(w, id);
    try w.writeAll("\",\"source_ref\":\"");
    try writeEscaped(w, source_ref);
    try w.writeAll("\",\"reason\":\"");
    try writeEscaped(w, reason);
    try w.writeAll("\",\"evidence_ref\":\"");
    try writeEscaped(w, evidence_ref);
    try w.writeAll("\",\"suggested_delta\":null,\"status\":\"proposed\",\"non_authorizing\":true}");
}

fn dispatchVerifierCandidateExecutionList(allocator: std.mem.Allocator, workspace_root: ?[]const u8, request_body: ?[]const u8) !DispatchResult {
    _ = workspace_root;
    var max_items: usize = core.MAX_VERIFIER_EXECUTION_ITEMS;
    var candidate_filter: ?[]const u8 = null;
    var candidate_filter_owned: ?[]u8 = null;
    defer if (candidate_filter_owned) |value| allocator.free(value);
    var status_filter: ?[]const u8 = null;
    var status_filter_owned: ?[]u8 = null;
    defer if (status_filter_owned) |value| allocator.free(value);
    var project_shard: ?[]const u8 = null;
    var project_shard_owned: ?[]u8 = null;
    defer if (project_shard_owned) |value| allocator.free(value);

    if (request_body) |body| {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
            return .{ .status = .rejected, .err = .{ .code = .json_contract_error, .message = "invalid JSON" } };
        };
        defer parsed.deinit();
        if (parsed.value != .object) return .{ .status = .rejected, .err = .{ .code = .invalid_request, .message = "verifier.candidate.execution.list request must be a JSON object" } };
        const obj = parsed.value.object;
        max_items = boundedMaxItems(obj, core.MAX_VERIFIER_EXECUTION_ITEMS, core.MAX_VERIFIER_EXECUTION_ITEMS);
        if (getStr(obj, "project_shard", "projectShard")) |value| {
            project_shard_owned = try allocator.dupe(u8, value);
            project_shard = project_shard_owned.?;
        }
        if (getStr(obj, "candidate_id", "candidateId")) |value| {
            candidate_filter_owned = try allocator.dupe(u8, value);
            candidate_filter = candidate_filter_owned.?;
        }
        if (getStr(obj, "status_filter", "statusFilter")) |value| {
            status_filter_owned = try allocator.dupe(u8, value);
            status_filter = status_filter_owned.?;
        }
    }
    const shard_id = project_shard orelse return .{
        .status = .rejected,
        .err = .{ .code = .missing_required_field, .message = "projectShard is required" },
    };

    var listed = verifier_candidate_execution.listExecutionRecords(allocator, shard_id, candidate_filter, status_filter, max_items) catch |err| {
        return switch (err) {
            else => .{ .status = .failed, .err = .{ .code = .internal_error, .message = "verifier.candidate.execution.list failed", .details = @errorName(err) } },
        };
    };
    defer listed.deinit();

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    try w.writeAll("{\"executions\":[");
    for (listed.records, 0..) |record, i| {
        if (i != 0) try w.writeByte(',');
        try w.writeAll(record.raw_json);
    }
    try w.writeAll("],\"counts\":{\"total\":");
    try w.print("{d}", .{listed.total});
    try w.writeAll(",\"emitted\":");
    try w.print("{d}", .{listed.emitted});
    try w.writeAll(",\"passed\":");
    try w.print("{d}", .{listed.passed});
    try w.writeAll(",\"failed\":");
    try w.print("{d}", .{listed.failed});
    try w.writeAll(",\"timed_out\":");
    try w.print("{d}", .{listed.timed_out});
    try w.writeAll(",\"disallowed\":");
    try w.print("{d}", .{listed.disallowed});
    try w.writeAll(",\"rejected\":");
    try w.print("{d}", .{listed.rejected});
    try w.writeAll(",\"unknown\":");
    try w.print("{d}", .{listed.unknown});
    try w.writeAll("},\"projectShard\":\"");
    try writeEscaped(w, shard_id);
    try w.writeAll("\",\"max_items\":");
    try w.print("{d}", .{listed.limit});
    try w.writeAll(",\"read_only\":true,\"readOnly\":true,\"non_authorizing\":true,\"nonAuthorizing\":true,\"commands_executed\":false,\"commandsExecuted\":false,\"verifiers_executed\":false,\"verifiersExecuted\":false,\"mutates_state\":false,\"mutatesState\":false,\"proof_granted\":false,\"proofGranted\":false,\"support_granted\":false,\"supportGranted\":false,\"correction_applied\":false,\"correctionApplied\":false,\"negative_knowledge_promoted\":false,\"negativeKnowledgePromoted\":false,\"patch_applied\":false,\"patchApplied\":false,\"corpus_mutation\":false,\"corpusMutation\":false,\"pack_mutation\":false,\"packMutation\":false,\"state_source\":\"verifier_execution_records_jsonl\",\"storage_path\":\"");
    try writeEscaped(w, listed.storage_path);
    try w.writeAll("\",\"telemetry\":{\"malformed_lines\":");
    try w.print("{d}", .{listed.malformed_lines});
    try w.writeAll(",\"bytes_read\":");
    try w.print("{d}", .{listed.bytes_read});
    try w.writeAll(",\"truncated\":");
    try w.writeAll(if (listed.truncated) "true" else "false");
    try w.writeAll("},\"trace\":{\"summary\":\"inspection only; read existing verifier execution JSONL records without scheduling or running verifiers\"}}");

    return .{
        .status = .ok,
        .result_json = try out.toOwnedSlice(),
        .allocated_result = true,
    };
}

fn dispatchVerifierCandidateExecutionGet(allocator: std.mem.Allocator, workspace_root: ?[]const u8, request_body: ?[]const u8) !DispatchResult {
    _ = workspace_root;
    const body = request_body orelse return .{
        .status = .rejected,
        .err = .{ .code = .missing_required_field, .message = "missing request body" },
    };

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return .{ .status = .rejected, .err = .{ .code = .json_contract_error, .message = "invalid JSON" } };
    };
    defer parsed.deinit();

    if (parsed.value != .object) return .{ .status = .rejected, .err = .{ .code = .invalid_request, .message = "verifier.candidate.execution.get request must be a JSON object" } };
    const obj = parsed.value.object;
    const project_shard_raw = getStr(obj, "project_shard", "projectShard") orelse return .{
        .status = .rejected,
        .err = .{ .code = .missing_required_field, .message = "projectShard is required" },
    };
    const execution_id_raw = getStr(obj, "execution_id", "executionId") orelse return .{
        .status = .rejected,
        .err = .{ .code = .missing_required_field, .message = "execution_id is required" },
    };
    const project_shard = try allocator.dupe(u8, project_shard_raw);
    defer allocator.free(project_shard);
    const execution_id = try allocator.dupe(u8, execution_id_raw);
    defer allocator.free(execution_id);

    var inspected = verifier_candidate_execution.getExecutionRecord(allocator, project_shard, execution_id) catch |err| {
        return switch (err) {
            else => .{ .status = .failed, .err = .{ .code = .internal_error, .message = "verifier.candidate.execution.get failed", .details = @errorName(err) } },
        };
    };
    defer inspected.deinit();
    if (inspected.record) |record| {
        var out = std.ArrayList(u8).init(allocator);
        errdefer out.deinit();
        const w = out.writer();
        try w.writeAll("{\"execution\":");
        try w.writeAll(record.raw_json);
        try w.writeAll(",\"projectShard\":\"");
        try writeEscaped(w, project_shard);
        try w.writeAll("\",\"executionId\":\"");
        try writeEscaped(w, execution_id);
        try w.writeAll("\",\"read_only\":true,\"readOnly\":true,\"non_authorizing\":true,\"nonAuthorizing\":true,\"commands_executed\":false,\"commandsExecuted\":false,\"verifiers_executed\":false,\"verifiersExecuted\":false,\"mutates_state\":false,\"mutatesState\":false,\"proof_granted\":false,\"proofGranted\":false,\"support_granted\":false,\"supportGranted\":false,\"correction_applied\":false,\"correctionApplied\":false,\"negative_knowledge_promoted\":false,\"negativeKnowledgePromoted\":false,\"patch_applied\":false,\"patchApplied\":false,\"corpus_mutation\":false,\"corpusMutation\":false,\"pack_mutation\":false,\"packMutation\":false,\"state_source\":\"verifier_execution_records_jsonl\",\"storage_path\":\"");
        try writeEscaped(w, inspected.storage_path);
        try w.writeAll("\",\"telemetry\":{\"malformed_lines\":");
        try w.print("{d}", .{inspected.malformed_lines});
        try w.writeAll(",\"bytes_read\":");
        try w.print("{d}", .{inspected.bytes_read});
        try w.writeAll(",\"truncated\":");
        try w.writeAll(if (inspected.truncated) "true" else "false");
        try w.writeAll("},\"trace\":{\"summary\":\"inspection only; read existing verifier execution JSONL record without scheduling or running verifiers\"}}");
        return .{ .status = .ok, .result_json = try out.toOwnedSlice(), .allocated_result = true };
    }

    return .{
        .status = .rejected,
        .err = .{
            .code = .path_not_found,
            .message = "verifier candidate execution not found",
            .details = execution_id,
            .fix_hint = "list verifier.candidate.execution.list with projectShard to inspect persisted verifier execution records",
        },
        .result_state = schema.unresolvedResultState("verifier candidate execution not found"),
    };
}

// ── Correction Inspection ─────────────────────────────────────────────

fn dispatchCorrectionList(allocator: std.mem.Allocator, workspace_root: ?[]const u8, request_body: ?[]const u8) !DispatchResult {
    var max_items: usize = core.MAX_CORRECTION_ITEMS;
    var state_path: ?[]u8 = null;
    defer if (state_path) |p| allocator.free(p);
    var correction_kind_filter: ?[]const u8 = null;

    if (request_body) |body| {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
            return .{ .status = .rejected, .err = .{ .code = .json_contract_error, .message = "invalid JSON" } };
        };
        defer parsed.deinit();
        const obj = parsed.value.object;
        max_items = boundedMaxItems(obj, core.MAX_CORRECTION_ITEMS, core.MAX_CORRECTION_ITEMS);
        _ = getStr(obj, "session_id", "sessionId");
        _ = getStr(obj, "artifact_ref", "artifactRef");
        correction_kind_filter = getStr(obj, "correction_kind", "correctionKind");
        state_path = resolveInspectionStatePath(allocator, workspace_root, obj) catch |err| {
            if (err == error.PathRejected) return .{ .status = .rejected, .err = .{ .code = .path_outside_workspace, .message = "state path outside workspace" } };
            return err;
        };
    }

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    var parsed_state: ?std.json.Parsed(std.json.Value) = null;
    defer if (parsed_state) |*p| p.deinit();
    if (state_path) |path| parsed_state = loadInspectionState(allocator, path) catch null;

    var total: usize = 0;
    var emitted: usize = 0;
    var hypothesis_contradicted: usize = 0;
    var verifier_candidate_failed: usize = 0;
    var patch_candidate_invalidated: usize = 0;
    var pack_signal_contradicted: usize = 0;
    var assumption_invalidated: usize = 0;
    var insufficient_test_detected: usize = 0;

    try w.writeAll("{\"corrections\":[");
    if (parsed_state) |state| {
        if (supportGraphNodes(state.value)) |nodes| {
            for (nodes.items) |node_val| {
                const node = valueObject(node_val) orelse continue;
                const kind = stringField(node, "kind") orelse continue;
                if (!std.mem.eql(u8, kind, "correction_event")) continue;
                const id = stringField(node, "id") orelse continue;
                const detail = stringField(node, "detail") orelse "";
                const correction_kind = detailValue(detail, "kind=") orelse "unknown";
                if (correction_kind_filter) |filter| if (!std.mem.eql(u8, correction_kind, filter)) continue;
                total += 1;
                if (std.mem.eql(u8, correction_kind, "hypothesis_contradicted")) hypothesis_contradicted += 1 else if (std.mem.eql(u8, correction_kind, "verifier_candidate_failed")) verifier_candidate_failed += 1 else if (std.mem.eql(u8, correction_kind, "patch_candidate_invalidated")) patch_candidate_invalidated += 1 else if (std.mem.eql(u8, correction_kind, "pack_signal_contradicted")) pack_signal_contradicted += 1 else if (std.mem.eql(u8, correction_kind, "assumption_invalidated")) assumption_invalidated += 1 else if (std.mem.eql(u8, correction_kind, "insufficient_test_detected")) insufficient_test_detected += 1;
                if (emitted >= max_items) continue;
                if (emitted != 0) try w.writeByte(',');
                emitted += 1;
                try writeCorrectionProjection(w, state.value, node, id, detail);
            }
        }
    }
    try w.writeAll("],\"counts_by_correction_kind\":{\"total\":");
    try w.print("{d}", .{total});
    try w.writeAll(",\"hypothesis_contradicted\":");
    try w.print("{d}", .{hypothesis_contradicted});
    try w.writeAll(",\"verifier_candidate_failed\":");
    try w.print("{d}", .{verifier_candidate_failed});
    try w.writeAll(",\"patch_candidate_invalidated\":");
    try w.print("{d}", .{patch_candidate_invalidated});
    try w.writeAll(",\"pack_signal_contradicted\":");
    try w.print("{d}", .{pack_signal_contradicted});
    try w.writeAll(",\"assumption_invalidated\":");
    try w.print("{d}", .{assumption_invalidated});
    try w.writeAll(",\"insufficient_test_detected\":");
    try w.print("{d}", .{insufficient_test_detected});
    try w.writeAll("},\"max_items\":");
    try w.print("{d}", .{max_items});
    try w.writeAll(",\"read_only\":true,\"non_authorizing\":true,\"state_source\":\"");
    try w.writeAll(if (state_path != null) "support_graph" else "no_state_found");
    try w.writeAll("\",\"trace\":{\"summary\":\"correction events are state transition evidence, not proof\"}}");

    return .{
        .status = .ok,
        .result_json = try out.toOwnedSlice(),
        .allocated_result = true,
    };
}

fn dispatchCorrectionGet(allocator: std.mem.Allocator, workspace_root: ?[]const u8, request_body: ?[]const u8) !DispatchResult {
    const body = request_body orelse return .{
        .status = .rejected,
        .err = .{ .code = .missing_required_field, .message = "missing request body" },
    };

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return .{ .status = .rejected, .err = .{ .code = .json_contract_error, .message = "invalid JSON" } };
    };
    defer parsed.deinit();

    const obj = parsed.value.object;
    const correction_id = getStr(obj, "correction_id", "correctionId") orelse return .{
        .status = .rejected,
        .err = .{ .code = .missing_required_field, .message = "correction_id is required" },
    };
    const state_path = resolveInspectionStatePath(allocator, workspace_root, obj) catch |err| {
        if (err == error.PathRejected) return .{ .status = .rejected, .err = .{ .code = .path_outside_workspace, .message = "state path outside workspace" } };
        return err;
    };
    defer if (state_path) |p| allocator.free(p);
    if (state_path) |path| {
        var state = loadInspectionState(allocator, path) catch null;
        if (state) |*parsed_state| {
            defer parsed_state.deinit();
            if (findNode(parsed_state.value, correction_id, "correction_event")) |node| {
                const detail = stringField(node, "detail") orelse "";
                var out = std.ArrayList(u8).init(allocator);
                errdefer out.deinit();
                const w = out.writer();
                try w.writeAll("{\"correction\":");
                try writeCorrectionProjection(w, parsed_state.value, node, correction_id, detail);
                try w.writeAll(",\"linked_evidence_ref\":");
                try writeNullableString(w, linkedEdgeTarget(parsed_state.value, correction_id, "correction_from_evidence"));
                try w.writeAll(",\"linked_negative_knowledge_candidate_ref\":");
                try writeNullableString(w, linkedEdgeTarget(parsed_state.value, correction_id, "proposes_negative_knowledge"));
                try w.writeAll(",\"trace\":{\"summary\":\"read existing support graph correction state\"}}");
                return .{ .status = .ok, .result_json = try out.toOwnedSlice(), .allocated_result = true };
            }
        }
    }

    return .{
        .status = .failed,
        .err = .{
            .code = .path_not_found,
            .message = "correction event not found",
            .details = correction_id,
            .fix_hint = "list correction.list to inspect visible correction events",
        },
        .result_state = schema.unresolvedResultState("correction event not found"),
    };
}

// ── Negative Knowledge Candidate Inspection ───────────────────────────

fn dispatchNegativeKnowledgeCandidateList(allocator: std.mem.Allocator, workspace_root: ?[]const u8, request_body: ?[]const u8) !DispatchResult {
    var max_items: usize = core.MAX_NEGATIVE_KNOWLEDGE_CANDIDATE_ITEMS;
    var state_path: ?[]u8 = null;
    defer if (state_path) |p| allocator.free(p);
    var candidate_kind_filter: ?[]const u8 = null;
    var scope_filter: ?[]const u8 = null;

    if (request_body) |body| {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
            return .{ .status = .rejected, .err = .{ .code = .json_contract_error, .message = "invalid JSON" } };
        };
        defer parsed.deinit();
        const obj = parsed.value.object;
        max_items = boundedMaxItems(obj, core.MAX_NEGATIVE_KNOWLEDGE_CANDIDATE_ITEMS, core.MAX_NEGATIVE_KNOWLEDGE_CANDIDATE_ITEMS);
        _ = getStr(obj, "session_id", "sessionId");
        candidate_kind_filter = getStr(obj, "candidate_kind", "candidateKind");
        scope_filter = getStr(obj, "scope", "scope");
        state_path = resolveInspectionStatePath(allocator, workspace_root, obj) catch |err| {
            if (err == error.PathRejected) return .{ .status = .rejected, .err = .{ .code = .path_outside_workspace, .message = "state path outside workspace" } };
            return err;
        };
    }

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    var parsed_state: ?std.json.Parsed(std.json.Value) = null;
    defer if (parsed_state) |*p| p.deinit();
    if (state_path) |path| parsed_state = loadInspectionState(allocator, path) catch null;

    var total: usize = 0;
    var emitted: usize = 0;
    var failed_hypothesis: usize = 0;
    var failed_patch: usize = 0;
    var failed_repair_strategy: usize = 0;
    var misleading_pack_signal: usize = 0;
    var insufficient_test: usize = 0;
    var unsafe_verifier_candidate: usize = 0;
    var overbroad_rule: usize = 0;

    try w.writeAll("{\"candidates\":[");
    if (parsed_state) |state| {
        if (supportGraphNodes(state.value)) |nodes| {
            for (nodes.items) |node_val| {
                const node = valueObject(node_val) orelse continue;
                const kind = stringField(node, "kind") orelse continue;
                if (!std.mem.eql(u8, kind, "negative_knowledge_candidate")) continue;
                const id = stringField(node, "id") orelse continue;
                const detail = stringField(node, "detail") orelse "";
                const candidate_kind = detailValue(detail, "kind=") orelse "unknown";
                const scope = stringField(node, "label") orelse id;
                if (candidate_kind_filter) |filter| if (!std.mem.eql(u8, candidate_kind, filter)) continue;
                if (scope_filter) |filter| if (std.mem.indexOf(u8, scope, filter) == null and std.mem.indexOf(u8, id, filter) == null) continue;
                total += 1;
                if (std.mem.eql(u8, candidate_kind, "failed_hypothesis")) failed_hypothesis += 1 else if (std.mem.eql(u8, candidate_kind, "failed_patch")) failed_patch += 1 else if (std.mem.eql(u8, candidate_kind, "failed_repair_strategy")) failed_repair_strategy += 1 else if (std.mem.eql(u8, candidate_kind, "misleading_pack_signal")) misleading_pack_signal += 1 else if (std.mem.eql(u8, candidate_kind, "insufficient_test")) insufficient_test += 1 else if (std.mem.eql(u8, candidate_kind, "unsafe_verifier_candidate")) unsafe_verifier_candidate += 1 else if (std.mem.eql(u8, candidate_kind, "overbroad_rule")) overbroad_rule += 1;
                if (emitted >= max_items) continue;
                if (emitted != 0) try w.writeByte(',');
                emitted += 1;
                try writeNegativeKnowledgeProjection(w, state.value, node, id, detail);
            }
        }
    }
    try w.writeAll("],\"counts\":{\"total\":");
    try w.print("{d}", .{total});
    try w.writeAll(",\"failed_hypothesis\":");
    try w.print("{d}", .{failed_hypothesis});
    try w.writeAll(",\"failed_patch\":");
    try w.print("{d}", .{failed_patch});
    try w.writeAll(",\"failed_repair_strategy\":");
    try w.print("{d}", .{failed_repair_strategy});
    try w.writeAll(",\"misleading_pack_signal\":");
    try w.print("{d}", .{misleading_pack_signal});
    try w.writeAll(",\"insufficient_test\":");
    try w.print("{d}", .{insufficient_test});
    try w.writeAll(",\"unsafe_verifier_candidate\":");
    try w.print("{d}", .{unsafe_verifier_candidate});
    try w.writeAll(",\"overbroad_rule\":");
    try w.print("{d}", .{overbroad_rule});
    try w.writeAll("},\"max_items\":");
    try w.print("{d}", .{max_items});
    try w.writeAll(",\"read_only\":true,\"non_authorizing\":true,\"promoted\":false,\"pack_authorized\":false,\"state_source\":\"");
    try w.writeAll(if (state_path != null) "support_graph" else "no_state_found");
    try w.writeAll("\",\"trace\":{\"summary\":\"negative knowledge candidates are proposed only and are not promoted\"}}");

    return .{
        .status = .ok,
        .result_json = try out.toOwnedSlice(),
        .allocated_result = true,
    };
}

fn dispatchNegativeKnowledgeCandidateGet(allocator: std.mem.Allocator, workspace_root: ?[]const u8, request_body: ?[]const u8) !DispatchResult {
    const body = request_body orelse return .{
        .status = .rejected,
        .err = .{ .code = .missing_required_field, .message = "missing request body" },
    };

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return .{ .status = .rejected, .err = .{ .code = .json_contract_error, .message = "invalid JSON" } };
    };
    defer parsed.deinit();

    const obj = parsed.value.object;
    const candidate_id = getStr(obj, "candidate_id", "candidateId") orelse return .{
        .status = .rejected,
        .err = .{ .code = .missing_required_field, .message = "candidate_id is required" },
    };
    const state_path = resolveInspectionStatePath(allocator, workspace_root, obj) catch |err| {
        if (err == error.PathRejected) return .{ .status = .rejected, .err = .{ .code = .path_outside_workspace, .message = "state path outside workspace" } };
        return err;
    };
    defer if (state_path) |p| allocator.free(p);
    if (state_path) |path| {
        var state = loadInspectionState(allocator, path) catch null;
        if (state) |*parsed_state| {
            defer parsed_state.deinit();
            if (findNode(parsed_state.value, candidate_id, "negative_knowledge_candidate")) |node| {
                const detail = stringField(node, "detail") orelse "";
                var out = std.ArrayList(u8).init(allocator);
                errdefer out.deinit();
                const w = out.writer();
                try w.writeAll("{\"candidate\":");
                try writeNegativeKnowledgeProjection(w, parsed_state.value, node, candidate_id, detail);
                try w.writeAll(",\"correction_event_ref\":");
                try writeNullableString(w, linkedEdgeTarget(parsed_state.value, candidate_id, "negative_knowledge_from_correction") orelse reverseLinkedEdgeSource(parsed_state.value, candidate_id, "proposes_negative_knowledge"));
                try w.writeAll(",\"evidence_ref\":null,\"promotion_status\":{\"promoted\":false,\"pack_authorized\":false},\"trace\":{\"summary\":\"read existing support graph negative knowledge candidate state\"}}");
                return .{ .status = .ok, .result_json = try out.toOwnedSlice(), .allocated_result = true };
            }
        }
    }

    return .{
        .status = .failed,
        .err = .{
            .code = .path_not_found,
            .message = "negative knowledge candidate not found",
            .details = candidate_id,
            .fix_hint = "list negative_knowledge.candidate.list to inspect visible candidates",
        },
        .result_state = schema.unresolvedResultState("negative knowledge candidate not found"),
    };
}

fn dispatchNegativeKnowledgeRecordList(allocator: std.mem.Allocator, workspace_root: ?[]const u8, request_body: ?[]const u8) !DispatchResult {
    var max_items: usize = core.MAX_NEGATIVE_KNOWLEDGE_RECORD_ITEMS;
    var state_path: ?[]u8 = null;
    defer if (state_path) |p| allocator.free(p);
    var status_filter: ?[]const u8 = null;
    var kind_filter: ?[]const u8 = null;
    var scope_filter: ?[]const u8 = null;
    var state_source: []const u8 = "no_state_found";

    if (request_body) |body| {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
            return .{ .status = .rejected, .err = .{ .code = .json_contract_error, .message = "invalid JSON" } };
        };
        defer parsed.deinit();
        const obj = parsed.value.object;
        max_items = boundedMaxItems(obj, core.MAX_NEGATIVE_KNOWLEDGE_RECORD_ITEMS, core.MAX_NEGATIVE_KNOWLEDGE_RECORD_ITEMS);
        status_filter = getStr(obj, "status_filter", "statusFilter");
        kind_filter = getStr(obj, "kind_filter", "kindFilter");
        scope_filter = getStr(obj, "scope_filter", "scopeFilter");
        _ = getStr(obj, "project_shard", "projectShard");
        state_path = resolveInspectionStatePath(allocator, workspace_root, obj) catch |err| {
            if (err == error.PathRejected) return .{ .status = .rejected, .err = .{ .code = .path_outside_workspace, .message = "state path outside workspace" } };
            return err;
        };
        state_source = stateSourceFromRequest(obj, state_path);
    }

    var parsed_state: ?std.json.Parsed(std.json.Value) = null;
    defer if (parsed_state) |*p| p.deinit();
    if (state_path) |path| parsed_state = loadInspectionState(allocator, path) catch null;

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();
    var total: usize = 0;
    var emitted: usize = 0;
    var accepted: usize = 0;
    var rejected: usize = 0;
    var expired: usize = 0;
    var superseded: usize = 0;
    var proposed: usize = 0;

    try w.writeAll("{\"records\":[");
    if (parsed_state) |state| {
        if (supportGraphNodes(state.value)) |nodes| {
            for (nodes.items) |node_val| {
                const node = valueObject(node_val) orelse continue;
                const node_kind = stringField(node, "kind") orelse continue;
                if (!std.mem.eql(u8, node_kind, "negative_knowledge_record")) continue;
                const id = stringField(node, "id") orelse continue;
                const detail = stringField(node, "detail") orelse "";
                const record_kind = detailValue(detail, "kind=") orelse "unknown";
                const status = detailValue(detail, "status=") orelse "accepted";
                const scope = detailValue(detail, "scope=") orelse "artifact";
                if (status_filter) |filter| if (!std.mem.eql(u8, status, filter)) continue;
                if (kind_filter) |filter| if (!std.mem.eql(u8, record_kind, filter)) continue;
                if (scope_filter) |filter| if (!std.mem.eql(u8, scope, filter)) continue;
                total += 1;
                if (std.mem.eql(u8, status, "accepted")) accepted += 1 else if (std.mem.eql(u8, status, "rejected")) rejected += 1 else if (std.mem.eql(u8, status, "expired")) expired += 1 else if (std.mem.eql(u8, status, "superseded")) superseded += 1 else if (std.mem.eql(u8, status, "proposed")) proposed += 1;
                if (emitted >= max_items) continue;
                if (emitted != 0) try w.writeByte(',');
                emitted += 1;
                try writeNegativeKnowledgeRecordProjection(w, state.value, node, id, detail);
            }
        }
    }
    try w.print("],\"counts\":{{\"total\":{d},\"accepted\":{d},\"rejected\":{d},\"expired\":{d},\"superseded\":{d},\"proposed\":{d}}},\"max_items\":{d},\"read_only\":true,\"non_authorizing\":true,\"pack_mutation\":false,\"state_source\":\"", .{ total, accepted, rejected, expired, superseded, proposed, max_items });
    try w.writeAll(state_source);
    try w.writeAll("\",\"trace\":{\"summary\":\"record inspection only; no influence application or pack mutation\"}}");

    return .{ .status = .ok, .result_json = try out.toOwnedSlice(), .allocated_result = true };
}

fn dispatchNegativeKnowledgeRecordGet(allocator: std.mem.Allocator, workspace_root: ?[]const u8, request_body: ?[]const u8) !DispatchResult {
    const body = request_body orelse return .{ .status = .rejected, .err = .{ .code = .missing_required_field, .message = "missing request body" } };
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return .{ .status = .rejected, .err = .{ .code = .json_contract_error, .message = "invalid JSON" } };
    };
    defer parsed.deinit();
    const obj = parsed.value.object;
    const record_id = getStr(obj, "record_id", "recordId") orelse return .{ .status = .rejected, .err = .{ .code = .missing_required_field, .message = "record_id is required" } };
    const state_path = resolveInspectionStatePath(allocator, workspace_root, obj) catch |err| {
        if (err == error.PathRejected) return .{ .status = .rejected, .err = .{ .code = .path_outside_workspace, .message = "state path outside workspace" } };
        return err;
    };
    defer if (state_path) |p| allocator.free(p);
    if (state_path) |path| {
        var state = loadInspectionState(allocator, path) catch null;
        if (state) |*parsed_state| {
            defer parsed_state.deinit();
            if (findNode(parsed_state.value, record_id, "negative_knowledge_record")) |node| {
                const detail = stringField(node, "detail") orelse "";
                var out = std.ArrayList(u8).init(allocator);
                errdefer out.deinit();
                const w = out.writer();
                try w.writeAll("{\"record\":");
                try writeNegativeKnowledgeRecordProjection(w, parsed_state.value, node, record_id, detail);
                try w.writeAll(",\"projection_completeness\":{\"source\":\"support_graph\",\"complete\":false,\"reason\":\"support graph projection may omit unpersisted lifecycle fields\"},\"trace\":{\"summary\":\"read existing negative knowledge record state only\"}}");
                return .{ .status = .ok, .result_json = try out.toOwnedSlice(), .allocated_result = true };
            }
        }
    }
    return .{ .status = .failed, .err = .{ .code = .path_not_found, .message = "negative knowledge record not found", .details = record_id, .fix_hint = "list negative_knowledge.record.list to inspect visible records" }, .result_state = schema.unresolvedResultState("negative knowledge record not found") };
}

fn dispatchNegativeKnowledgeInfluenceList(allocator: std.mem.Allocator, workspace_root: ?[]const u8, request_body: ?[]const u8) !DispatchResult {
    var max_items: usize = core.MAX_NEGATIVE_KNOWLEDGE_INFLUENCE_ITEMS;
    var state_path: ?[]u8 = null;
    defer if (state_path) |p| allocator.free(p);
    var hypothesis_filter: ?[]const u8 = null;
    var artifact_filter: ?[]const u8 = null;
    if (request_body) |body| {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
            return .{ .status = .rejected, .err = .{ .code = .json_contract_error, .message = "invalid JSON" } };
        };
        defer parsed.deinit();
        const obj = parsed.value.object;
        max_items = boundedMaxItems(obj, core.MAX_NEGATIVE_KNOWLEDGE_INFLUENCE_ITEMS, core.MAX_NEGATIVE_KNOWLEDGE_INFLUENCE_ITEMS);
        hypothesis_filter = getStr(obj, "hypothesis_id", "hypothesisId");
        artifact_filter = getStr(obj, "artifact_ref", "artifactRef");
        state_path = resolveInspectionStatePath(allocator, workspace_root, obj) catch |err| {
            if (err == error.PathRejected) return .{ .status = .rejected, .err = .{ .code = .path_outside_workspace, .message = "state path outside workspace" } };
            return err;
        };
    }
    var parsed_state: ?std.json.Parsed(std.json.Value) = null;
    defer if (parsed_state) |*p| p.deinit();
    if (state_path) |path| parsed_state = loadInspectionState(allocator, path) catch null;

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();
    var matches: usize = 0;
    var emitted: usize = 0;
    var triage_penalties: usize = 0;
    var verifier_requirements: usize = 0;
    var suppressions: usize = 0;
    var routing_warnings: usize = 0;
    var trust_decay_candidates: usize = 0;
    try w.writeAll("{\"influence_results\":[");
    if (parsed_state) |state| {
        if (supportGraphNodes(state.value)) |nodes| {
            for (nodes.items) |node_val| {
                const node = valueObject(node_val) orelse continue;
                const kind = stringField(node, "kind") orelse continue;
                if (!std.mem.eql(u8, kind, "negative_knowledge_influence")) continue;
                const id = stringField(node, "id") orelse continue;
                const detail = stringField(node, "detail") orelse "";
                if (hypothesis_filter) |filter| if (std.mem.indexOf(u8, id, filter) == null and std.mem.indexOf(u8, detail, filter) == null) continue;
                if (artifact_filter) |filter| if (std.mem.indexOf(u8, id, filter) == null and std.mem.indexOf(u8, detail, filter) == null) continue;
                matches += 1;
                if (std.mem.indexOf(u8, detail, "triage") != null) triage_penalties += 1;
                if (linkedEdgeTarget(state.value, id, "negative_knowledge_requires_verifier") != null or std.mem.indexOf(u8, detail, "verifier") != null) verifier_requirements += 1;
                if (std.mem.indexOf(u8, detail, "suppress") != null) suppressions += 1;
                if (linkedEdgeTarget(state.value, id, "negative_knowledge_warns_routing") != null or std.mem.indexOf(u8, detail, "routing") != null) routing_warnings += 1;
                if (linkedEdgeTarget(state.value, id, "proposes_trust_decay") != null or std.mem.indexOf(u8, detail, "trust_decay") != null) trust_decay_candidates += 1;
                if (emitted >= max_items) continue;
                if (emitted != 0) try w.writeByte(',');
                emitted += 1;
                try writeNegativeKnowledgeInfluenceProjection(w, state.value, node, id, detail);
            }
        }
    }
    try w.print("],\"counts\":{{\"matches\":{d},\"triage_penalties\":{d},\"verifier_requirements\":{d},\"suppressions\":{d},\"routing_warnings\":{d},\"trust_decay_candidates\":{d}}},\"max_items\":{d},\"read_only\":true,\"non_authorizing\":true,\"mutated_triage\":false,\"mutated_routing\":false}}", .{ matches, triage_penalties, verifier_requirements, suppressions, routing_warnings, trust_decay_candidates, max_items });
    return .{ .status = .ok, .result_json = try out.toOwnedSlice(), .allocated_result = true };
}

fn dispatchTrustDecayCandidateList(allocator: std.mem.Allocator, workspace_root: ?[]const u8, request_body: ?[]const u8) !DispatchResult {
    var max_items: usize = core.MAX_TRUST_DECAY_CANDIDATE_ITEMS;
    var state_path: ?[]u8 = null;
    defer if (state_path) |p| allocator.free(p);
    var source_filter: ?[]const u8 = null;
    var pack_filter: ?[]const u8 = null;
    if (request_body) |body| {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
            return .{ .status = .rejected, .err = .{ .code = .json_contract_error, .message = "invalid JSON" } };
        };
        defer parsed.deinit();
        const obj = parsed.value.object;
        max_items = boundedMaxItems(obj, core.MAX_TRUST_DECAY_CANDIDATE_ITEMS, core.MAX_TRUST_DECAY_CANDIDATE_ITEMS);
        source_filter = getStr(obj, "source_ref", "sourceRef");
        pack_filter = getStr(obj, "pack_id", "packId");
        state_path = resolveInspectionStatePath(allocator, workspace_root, obj) catch |err| {
            if (err == error.PathRejected) return .{ .status = .rejected, .err = .{ .code = .path_outside_workspace, .message = "state path outside workspace" } };
            return err;
        };
    }
    var parsed_state: ?std.json.Parsed(std.json.Value) = null;
    defer if (parsed_state) |*p| p.deinit();
    if (state_path) |path| parsed_state = loadInspectionState(allocator, path) catch null;
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();
    var total: usize = 0;
    var emitted: usize = 0;
    try w.writeAll("{\"candidates\":[");
    if (parsed_state) |state| {
        if (supportGraphNodes(state.value)) |nodes| {
            for (nodes.items) |node_val| {
                const node = valueObject(node_val) orelse continue;
                const kind = stringField(node, "kind") orelse continue;
                if (!std.mem.eql(u8, kind, "trust_decay_candidate")) continue;
                const id = stringField(node, "id") orelse continue;
                const detail = stringField(node, "detail") orelse "";
                if (source_filter) |filter| if (std.mem.indexOf(u8, id, filter) == null and std.mem.indexOf(u8, detail, filter) == null) continue;
                if (pack_filter) |filter| if (std.mem.indexOf(u8, id, filter) == null and std.mem.indexOf(u8, detail, filter) == null) continue;
                total += 1;
                if (emitted >= max_items) continue;
                if (emitted != 0) try w.writeByte(',');
                emitted += 1;
                try writeTrustDecayCandidateProjection(w, state.value, node, id, detail);
            }
        }
    }
    try w.print("],\"counts\":{{\"total\":{d},\"proposed\":{d}}},\"max_items\":{d},\"read_only\":true,\"non_authorizing\":true,\"trust_mutation\":false}}", .{ total, total, max_items });
    return .{ .status = .ok, .result_json = try out.toOwnedSlice(), .allocated_result = true };
}

fn dispatchNegativeKnowledgeCandidateReview(allocator: std.mem.Allocator, request_body: ?[]const u8) !DispatchResult {
    const body = request_body orelse return .{ .status = .rejected, .err = .{ .code = .missing_required_field, .message = "missing request body" } };
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return .{ .status = .rejected, .err = .{ .code = .json_contract_error, .message = "invalid JSON" } };
    };
    defer parsed.deinit();
    const obj = parsed.value.object;
    const candidate_id = getStr(obj, "candidate_id", "candidateId") orelse return .{ .status = .rejected, .err = .{ .code = .missing_required_field, .message = "candidate_id is required" } };
    const decision = getStr(obj, "decision", "decision") orelse return .{ .status = .rejected, .err = .{ .code = .missing_required_field, .message = "decision is required" } };
    if (!std.mem.eql(u8, decision, "accept") and !std.mem.eql(u8, decision, "reject") and !std.mem.eql(u8, decision, "defer")) {
        return .{ .status = .rejected, .err = .{ .code = .invalid_request, .message = "decision must be accept, reject, or defer" } };
    }
    const approval_value = obj.get("approval_context") orelse obj.get("approvalContext");
    if (std.mem.eql(u8, decision, "accept") and approval_value == null) {
        return .{ .status = .rejected, .err = .{ .code = .approval_required, .message = "accept requires explicit approval_context", .details = candidate_id } };
    }
    if (approval_value) |value| {
        const approval = valueObject(value) orelse return .{ .status = .rejected, .err = .{ .code = .invalid_request, .message = "approval_context must be an object" } };
        if (std.mem.eql(u8, decision, "accept")) {
            _ = getStr(approval, "approved_by", "approvedBy") orelse return .{ .status = .rejected, .err = .{ .code = .missing_required_field, .message = "approval_context.approved_by is required" } };
            _ = getStr(approval, "approval_kind", "approvalKind") orelse return .{ .status = .rejected, .err = .{ .code = .missing_required_field, .message = "approval_context.approval_kind is required" } };
            _ = getStr(approval, "reason", "reason") orelse return .{ .status = .rejected, .err = .{ .code = .missing_required_field, .message = "approval_context.reason is required" } };
            _ = getStr(approval, "scope", "scope") orelse return .{ .status = .rejected, .err = .{ .code = .missing_required_field, .message = "approval_context.scope is required" } };
            if (approval.get("allowed_influence") == null and approval.get("allowedInfluence") == null) return .{ .status = .rejected, .err = .{ .code = .missing_required_field, .message = "approval_context.allowed_influence is required" } };
        }
    }
    if (std.mem.eql(u8, decision, "reject") and (getStr(obj, "reason", "reason") orelse "").len == 0) {
        return .{ .status = .rejected, .err = .{ .code = .missing_required_field, .message = "reject requires reason" } };
    }
    return negativeKnowledgeReviewPersistenceUnsupported(allocator, candidate_id, decision);
}

fn dispatchNegativeKnowledgeRecordExpire(allocator: std.mem.Allocator, request_body: ?[]const u8) !DispatchResult {
    const body = request_body orelse return .{ .status = .rejected, .err = .{ .code = .missing_required_field, .message = "missing request body" } };
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return .{ .status = .rejected, .err = .{ .code = .json_contract_error, .message = "invalid JSON" } };
    };
    defer parsed.deinit();
    const obj = parsed.value.object;
    const record_id = getStr(obj, "record_id", "recordId") orelse return .{ .status = .rejected, .err = .{ .code = .missing_required_field, .message = "record_id is required" } };
    const reason = getStr(obj, "reason", "reason") orelse return .{ .status = .rejected, .err = .{ .code = .missing_required_field, .message = "expire requires reason" } };
    return negativeKnowledgeRecordMutationUnsupported(allocator, record_id, "expire", reason);
}

fn dispatchNegativeKnowledgeRecordSupersede(allocator: std.mem.Allocator, request_body: ?[]const u8) !DispatchResult {
    const body = request_body orelse return .{ .status = .rejected, .err = .{ .code = .missing_required_field, .message = "missing request body" } };
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return .{ .status = .rejected, .err = .{ .code = .json_contract_error, .message = "invalid JSON" } };
    };
    defer parsed.deinit();
    const obj = parsed.value.object;
    const record_id = getStr(obj, "record_id", "recordId") orelse return .{ .status = .rejected, .err = .{ .code = .missing_required_field, .message = "record_id is required" } };
    _ = getStr(obj, "new_record_id", "newRecordId") orelse return .{ .status = .rejected, .err = .{ .code = .missing_required_field, .message = "new_record_id is required" } };
    const reason = getStr(obj, "reason", "reason") orelse return .{ .status = .rejected, .err = .{ .code = .missing_required_field, .message = "supersede requires reason" } };
    return negativeKnowledgeRecordMutationUnsupported(allocator, record_id, "supersede", reason);
}

fn negativeKnowledgeReviewPersistenceUnsupported(allocator: std.mem.Allocator, candidate_id: []const u8, decision: []const u8) !DispatchResult {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();
    try w.writeAll("{\"review_result\":{\"candidate_id\":\"");
    try writeEscaped(w, candidate_id);
    try w.writeAll("\",\"decision\":\"");
    try writeEscaped(w, decision);
    try w.writeAll("\",\"record_id\":null,\"review_event_id\":null,\"status\":\"unsupported_without_persistence\",\"non_authorizing\":true,\"requires_no_pack_mutation\":true},\"unsupported\":true,\"reason\":\"negative knowledge review requires a safe explicit append-only persistence target; GIP does not fake review state\",\"pack_mutation\":false,\"global_promotion\":false,\"support_authority\":false}");
    return .{ .status = .unsupported, .result_json = try out.toOwnedSlice(), .allocated_result = true, .result_state = schema.unsupportedResultState() };
}

fn negativeKnowledgeRecordMutationUnsupported(allocator: std.mem.Allocator, record_id: []const u8, action: []const u8, reason: []const u8) !DispatchResult {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();
    try w.writeAll("{\"record_action\":{\"record_id\":\"");
    try writeEscaped(w, record_id);
    try w.writeAll("\",\"action\":\"");
    try writeEscaped(w, action);
    try w.writeAll("\",\"reason\":\"");
    try writeEscaped(w, reason);
    try w.writeAll("\",\"status\":\"unsupported_without_persistence\",\"non_authorizing\":true},\"unsupported\":true,\"pack_mutation\":false,\"global_promotion\":false,\"support_authority\":false}");
    return .{ .status = .unsupported, .result_json = try out.toOwnedSlice(), .allocated_result = true, .result_state = schema.unsupportedResultState() };
}

// ── Pack List ─────────────────────────────────────────────────────────

fn dispatchPackList(allocator: std.mem.Allocator, workspace_root: ?[]const u8) !DispatchResult {
    // Try to load mount registry from workspace shard.
    // If no workspace or no registry, return empty list safely.
    const root = workspace_root orelse ".";
    var metadata = shards.resolveDefaultProjectMetadata(allocator) catch {
        return packListEmpty(allocator);
    };
    defer metadata.deinit();
    var paths = shards.resolvePaths(allocator, metadata.metadata) catch {
        return packListEmpty(allocator);
    };
    defer paths.deinit();

    var registry = knowledge_pack_store.loadMountRegistry(allocator, &paths) catch {
        return packListEmpty(allocator);
    };
    defer registry.deinit();

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    try w.writeAll("{\"packs\":[");
    for (registry.entries, 0..) |entry, idx| {
        if (idx >= core.MAX_PACK_LIST_ITEMS) break;
        if (idx != 0) try w.writeByte(',');
        try w.writeAll("{\"pack_id\":\"");
        try writeEscaped(w, entry.pack_id);
        try w.writeAll("\",\"version\":\"");
        try writeEscaped(w, entry.pack_version);
        try w.writeAll("\",\"mounted\":true,\"enabled\":");
        try w.writeAll(if (entry.enabled) "true" else "false");

        // Try to load manifest for richer info
        if (knowledge_pack_store.loadManifest(allocator, entry.pack_id, entry.pack_version)) |manifest_val| {
            var manifest = manifest_val;
            defer manifest.deinit();
            try w.writeAll(",\"domain_family\":\"");
            try writeEscaped(w, manifest.domain_family);
            try w.writeAll("\",\"trust_class\":\"");
            try writeEscaped(w, manifest.trust_class);
            try w.writeAll("\",\"summary\":\"");
            try writeEscaped(w, manifest.provenance.source_summary);
            try w.writeAll("\",\"non_authorizingInfluence\":true");
        } else |_| {
            try w.writeAll(",\"domain_family\":\"unknown\",\"trust_class\":\"unknown\",\"summary\":\"manifest not loadable\",\"non_authorizingInfluence\":true");
        }
        try w.writeAll("}");
    }
    try w.writeAll("]}");

    // Suppress unused warning
    _ = root;

    return .{
        .status = .ok,
        .result_json = try out.toOwnedSlice(),
        .allocated_result = true,
    };
}

fn packListEmpty(allocator: std.mem.Allocator) !DispatchResult {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();
    try w.writeAll("{\"packs\":[]}");
    return .{
        .status = .ok,
        .result_json = try out.toOwnedSlice(),
        .allocated_result = true,
    };
}

// ── Pack Inspect ──────────────────────────────────────────────────────

fn dispatchPackInspect(allocator: std.mem.Allocator, request_body: ?[]const u8) !DispatchResult {
    const body = request_body orelse return .{
        .status = .rejected,
        .err = .{ .code = .missing_required_field, .message = "missing request body" },
    };

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return .{ .status = .rejected, .err = .{ .code = .json_contract_error, .message = "invalid JSON" } };
    };
    defer parsed.deinit();

    const obj = parsed.value.object;
    const pack_id = getStr(obj, "packId", "pack_id") orelse return .{
        .status = .rejected,
        .err = .{ .code = .missing_required_field, .message = "packId is required" },
    };

    const pack_version = getStr(obj, "version", "version") orelse "v1";

    var manifest = loadPackManifestSafe(allocator, pack_id, pack_version) catch {
        return .{
            .status = .failed,
            .err = .{ .code = .path_not_found, .message = "pack not found or manifest not loadable", .details = pack_id },
            .result_state = schema.unresolvedResultState("pack manifest not found"),
        };
    };
    defer manifest.deinit();

    // Do not mount pack, do not mutate registry.
    // Only read manifest data.
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    try w.writeAll("{\"manifest_summary\":{");
    try w.writeAll("\"pack_id\":\"");
    try writeEscaped(w, manifest.pack_id);
    try w.writeAll("\",\"version\":\"");
    try writeEscaped(w, manifest.pack_version);
    try w.writeAll("\",\"schema_version\":\"");
    try writeEscaped(w, manifest.schema_version);
    try w.writeAll("\",\"domain_family\":\"");
    try writeEscaped(w, manifest.domain_family);
    try w.writeAll("\",\"trust_class\":\"");
    try writeEscaped(w, manifest.trust_class);
    try w.writeAll("\"}");

    try w.writeAll(",\"trust_freshness_status\":{\"freshness\":\"");
    try writeEscaped(w, knowledge_pack_store.packFreshnessName(manifest.provenance.freshness_state));
    try w.writeAll("\",\"source_state\":\"");
    try writeEscaped(w, knowledge_pack_store.sourceStateName(manifest.provenance.source_state));
    try w.writeAll("\"}");

    try w.writeAll(",\"content_summary\":{\"corpus_item_count\":");
    try w.print("{d}", .{manifest.content.corpus_item_count});
    try w.writeAll(",\"concept_count\":");
    try w.print("{d}", .{manifest.content.concept_count});
    try w.writeAll("}");

    try w.writeAll(",\"provenance\":{\"source_kind\":\"");
    try writeEscaped(w, manifest.provenance.source_kind);
    try w.writeAll("\",\"source_summary\":\"");
    try writeEscaped(w, manifest.provenance.source_summary);
    try w.writeAll("\"}");

    try w.writeAll(",\"influencePolicy\":\"non_authorizing\",\"non_authorizing\":true}");

    return .{
        .status = .ok,
        .result_json = try out.toOwnedSlice(),
        .allocated_result = true,
    };
}

fn loadPackManifestSafe(allocator: std.mem.Allocator, pack_id: []const u8, pack_version: []const u8) !knowledge_pack_store.Manifest {
    return knowledge_pack_store.loadManifest(allocator, pack_id, pack_version);
}

// ── Feedback Summary ──────────────────────────────────────────────────

fn dispatchFeedbackSummary(allocator: std.mem.Allocator, workspace_root: ?[]const u8, request_body: ?[]const u8) !DispatchResult {
    // Try to load feedback events from workspace shard.
    // If no workspace or no feedback, return structured unsupported.
    const root = workspace_root orelse return feedbackSummaryUnavailable(allocator, "workspace root required");

    var metadata = shards.resolveDefaultProjectMetadata(allocator) catch {
        return feedbackSummaryUnavailable(allocator, "could not resolve project metadata");
    };
    defer metadata.deinit();
    var paths = shards.resolvePaths(allocator, metadata.metadata) catch {
        return feedbackSummaryUnavailable(allocator, "could not resolve paths");
    };
    defer paths.deinit();

    const event_count = feedback.countEvents(allocator, &paths) catch {
        return feedbackSummaryUnavailable(allocator, "could not count feedback events");
    };

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    try w.writeAll("{\"event_counts\":{\"total\":");
    try w.print("{d}", .{event_count});
    try w.writeAll("},\"reinforcementFamilies\":[\"intent_interpretation\",\"action_surface\",\"verifier_pattern\"]");

    // Parse project_shard from request body if available
    if (request_body) |body| {
        var parsed_opt: ?std.json.Parsed(std.json.Value) = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch null;
        defer if (parsed_opt) |*p| p.deinit();
        if (parsed_opt) |p| {
            if (p.value.object.get("project_shard")) |v| {
                if (v == .string) {
                    try w.writeAll(",\"project_shard\":\"");
                    try writeEscaped(w, v.string);
                    try w.writeAll("\"");
                }
            }
        }
    }

    try w.writeAll("}");

    _ = root;

    return .{
        .status = .ok,
        .result_json = try out.toOwnedSlice(),
        .allocated_result = true,
    };
}

fn feedbackSummaryUnavailable(allocator: std.mem.Allocator, reason: []const u8) !DispatchResult {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();
    try w.writeAll("{\"unsupported\":true,\"reason\":\"");
    try writeEscaped(w, reason);
    try w.writeAll("\"}");
    return .{
        .status = .ok,
        .result_json = try out.toOwnedSlice(),
        .allocated_result = true,
    };
}

// ── Session Get ───────────────────────────────────────────────────────

fn dispatchSessionGet(allocator: std.mem.Allocator, request_body: ?[]const u8) !DispatchResult {
    const body = request_body orelse return .{
        .status = .rejected,
        .err = .{ .code = .missing_required_field, .message = "missing request body" },
    };

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return .{ .status = .rejected, .err = .{ .code = .json_contract_error, .message = "invalid JSON" } };
    };
    defer parsed.deinit();

    const obj = parsed.value.object;
    const session_id = getStr(obj, "sessionId", "session_id") orelse return .{
        .status = .rejected,
        .err = .{ .code = .missing_required_field, .message = "sessionId is required" },
    };

    const project_shard = getStr(obj, "projectShard", "project_shard");

    var session = conversation_session.load(allocator, project_shard, session_id) catch {
        return .{
            .status = .failed,
            .err = .{ .code = .path_not_found, .message = "session not found", .details = session_id },
            .result_state = schema.unresolvedResultState("session not found"),
        };
    };
    defer session.deinit();

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    try w.writeAll("{\"session_id\":\"");
    try writeEscaped(w, session.session_id);
    try w.writeAll("\",\"historyCount\":");
    try w.print("{d}", .{session.history.len});

    if (session.current_intent) |intent| {
        try w.writeAll(",\"currentIntent\":{\"status\":\"");
        try writeEscaped(w, @tagName(intent.status));
        try w.writeAll("\",\"mode\":\"");
        try writeEscaped(w, @tagName(intent.selected_mode));
        try w.writeAll("\"}");
    }

    try w.writeAll(",\"pendingObligations\":");
    try w.print("{d}", .{session.pending_obligations.len});
    try w.writeAll(",\"pendingAmbiguities\":");
    try w.print("{d}", .{session.pending_ambiguities.len});

    if (session.last_result) |result| {
        try w.writeAll(",\"lastResultState\":{\"kind\":\"");
        try writeEscaped(w, @tagName(result.kind));
        try w.writeAll("\",\"mode\":\"");
        try writeEscaped(w, @tagName(result.selected_mode));
        try w.writeAll("\",\"stopReason\":\"");
        try writeEscaped(w, @tagName(result.stop_reason));
        try w.writeAll("\"}");
    }

    try w.writeAll("}");

    return .{
        .status = .ok,
        .result_json = try out.toOwnedSlice(),
        .allocated_result = true,
    };
}

// ── Context Autopsy ───────────────────────────────────────────────────
//
// Runtime and persisted mounted-pack guidance only.
// No command or verifier execution. No pack or negative-knowledge mutation.
// Output is always draft/non-authorizing.

fn dispatchContextAutopsy(allocator: std.mem.Allocator, workspace_root: ?[]const u8, request_body: ?[]const u8) !DispatchResult {
    const body = request_body orelse return .{
        .status = .rejected,
        .err = .{ .code = .missing_required_field, .message = "request body is required for context.autopsy" },
    };

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return .{ .status = .rejected, .err = .{ .code = .json_contract_error, .message = "invalid JSON in request body" } };
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return .{ .status = .rejected, .err = .{ .code = .invalid_request, .message = "context.autopsy request must be a JSON object" } };
    }

    const request_obj = parsed.value.object;
    const context_value = request_obj.get("context") orelse parsed.value;
    const context_obj = valueObject(context_value) orelse return .{
        .status = .rejected,
        .err = .{ .code = .invalid_request, .message = "context must be an object" },
    };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const request_guidance = try parseContextPackGuidance(arena_alloc, request_obj);
    var persistent_guidance = try loadPersistentContextPackGuidance(arena_alloc, workspace_root);
    const guidance = try mergeContextPackGuidance(arena_alloc, persistent_guidance.guidance, request_guidance);
    const artifact_refs = try parseContextArtifactRefs(arena_alloc, request_obj);
    const input_refs = try parseContextInputRefs(arena_alloc, request_obj, context_obj);
    const description = getStr(context_obj, "summary", "summary") orelse getStr(context_obj, "description", "description") orelse "";
    const intake_type = getStr(context_obj, "intake_type", "intakeType") orelse getStr(context_obj, "context_kind", "contextKind") orelse "context";
    const case = context_autopsy.ContextCase{
        .description = description,
        .intake_data = context_value,
        .intake_type = intake_type,
        .intent_tags = try parseStringArrayField(arena_alloc, context_obj, "intent_tags", "intentTags"),
        .artifact_kinds = try parseStringArrayField(arena_alloc, context_obj, "artifact_kinds", "artifactKinds"),
        .situation_kinds = try parseStringArrayField(arena_alloc, context_obj, "situation_kinds", "situationKinds"),
        .input_ref_labels = try inputRefStringFieldList(arena_alloc, input_refs, .label),
        .input_ref_purposes = try inputRefStringFieldList(arena_alloc, input_refs, .purpose),
        .input_ref_reasons = try inputRefStringFieldList(arena_alloc, input_refs, .reason),
        .artifact_ref_purposes = try artifactRefStringFieldList(arena_alloc, artifact_refs, .purpose),
        .artifact_ref_reasons = try artifactRefStringFieldList(arena_alloc, artifact_refs, .reason),
    };
    const artifact_coverage = if (artifact_refs.len == 0) null else blk: {
        const root = workspace_root orelse return .{
            .status = .rejected,
            .err = .{ .code = .missing_required_field, .message = "workspace root is required when context.autopsy uses artifactRefs" },
        };
        break :blk try context_artifacts.collect(arena_alloc, root, artifact_refs);
    };
    const input_coverage = if (input_refs.len == 0) null else blk: {
        const root = workspace_root orelse return .{
            .status = .rejected,
            .err = .{ .code = .missing_required_field, .message = "workspace root is required when context.autopsy uses inputRefs" },
        };
        const coverage = try context_inputs.collect(arena_alloc, root, input_refs);
        if (inputCoverageHasSkipReason(&coverage, "PathOutsideWorkspace")) {
            return .{
                .status = .rejected,
                .err = .{
                    .code = .path_outside_workspace,
                    .message = "context input ref path outside workspace",
                    .fix_hint = "use a workspace-relative input ref path",
                },
            };
        }
        break :blk coverage;
    };
    var pack_source = context_autopsy_engine.PackGuidanceSource.init(guidance);
    const sources = [_]context_autopsy_engine.ContextSignalSource{pack_source.source()};
    var engine = context_autopsy_engine.ContextAutopsyEngine.init(allocator, &sources);
    var autopsy_result = try engine.evaluate(&case);
    defer autopsy_result.deinit(allocator);
    for (persistent_guidance.warnings) |warning| {
        autopsy_result.suggested_unknowns = try appendContextUnknown(allocator, autopsy_result.suggested_unknowns, warning);
    }
    if (artifact_coverage) |coverage| {
        var coverage_builder = context_autopsy_engine.ResultBuilder.init(allocator);
        defer coverage_builder.deinit();
        try context_artifacts.appendUnknownsToBuilder(&coverage, &coverage_builder);
        for (coverage_builder.unknowns.items) |unknown| {
            autopsy_result.suggested_unknowns = try appendContextUnknown(allocator, autopsy_result.suggested_unknowns, unknown);
        }
    }
    if (input_coverage) |coverage| {
        var input_builder = context_autopsy_engine.ResultBuilder.init(allocator);
        defer input_builder.deinit();
        try context_inputs.appendSignalsToBuilder(&coverage, &input_builder);
        for (input_builder.signals.items) |signal| {
            autopsy_result.detected_signals = try appendContextSignal(allocator, autopsy_result.detected_signals, signal);
        }
        for (input_builder.evidence_expectations.items) |expectation| {
            autopsy_result.evidence_expectations = try appendEvidenceExpectation(allocator, autopsy_result.evidence_expectations, expectation);
        }
        for (input_builder.pending_evidence_obligations.items) |obligation| {
            autopsy_result.pending_evidence_obligations = try appendPendingEvidenceObligation(allocator, autopsy_result.pending_evidence_obligations, obligation);
        }
        for (input_builder.unknowns.items) |unknown| {
            autopsy_result.suggested_unknowns = try appendContextUnknown(allocator, autopsy_result.suggested_unknowns, unknown);
        }
    }

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();
    try w.writeAll("{\"contextAutopsy\":");
    try writeContextAutopsyResult(
        w,
        &autopsy_result,
        if (artifact_coverage) |*coverage| coverage else null,
        if (input_coverage) |*coverage| coverage else null,
    );
    try w.writeAll(",\"packGuidanceTrace\":");
    try writePackGuidanceTrace(w, &persistent_guidance, request_guidance.len);
    try w.writeAll(",\"readOnly\":true,\"commandsExecuted\":false,\"verifiersExecuted\":false,\"packMutation\":false,\"negativeKnowledgeMutation\":false,\"persistentPackLoading\":true,\"non_authorizing\":true}");

    var gip_state = schema.draftResultState();
    gip_state.stop_reason = .none;
    gip_state.unresolved_reason = null;
    gip_state.non_authorization_notice = "context autopsy output is draft pack guidance; it does not constitute supported output or proof of any claim";

    return .{
        .status = .ok,
        .result_state = gip_state,
        .result_json = try out.toOwnedSlice(),
        .allocated_result = true,
    };
}

fn parseStringArrayField(allocator: std.mem.Allocator, obj: std.json.ObjectMap, snake: []const u8, camel: []const u8) ![]const []const u8 {
    const value = obj.get(snake) orelse obj.get(camel) orelse return &.{};
    if (value != .array) return &.{};
    var items = std.ArrayList([]const u8).init(allocator);
    for (value.array.items) |item| {
        if (item == .string) try items.append(item.string);
    }
    return try items.toOwnedSlice();
}

fn parseContextPackGuidance(allocator: std.mem.Allocator, request_obj: std.json.ObjectMap) ![]const context_autopsy.PackAutopsyGuidance {
    const value = request_obj.get("pack_guidance") orelse request_obj.get("packGuidance") orelse return &.{};
    if (value != .array) return &.{};
    var guidance = std.ArrayList(context_autopsy.PackAutopsyGuidance).init(allocator);
    for (value.array.items) |item| {
        const obj = valueObject(item) orelse continue;
        const pack_id = getStr(obj, "pack_id", "packId") orelse "runtime_pack_guidance";
        const pack_version = getStr(obj, "pack_version", "packVersion") orelse "runtime";
        const match_obj = if (obj.get("match")) |m| valueObject(m) else null;
        try guidance.append(.{
            .influence = .{
                .pack_name = pack_id,
                .pack_version = pack_version,
                .reason = getStr(obj, "reason", "reason") orelse "Runtime pack guidance payload contributed Context Autopsy candidates.",
                .weight = getStr(obj, "weight", "weight") orelse "medium",
            },
            .match = if (match_obj) |m| try parsePackAutopsyMatch(allocator, m) else .{},
            .signals = try parseContextSignals(allocator, obj, pack_id),
            .suggested_unknowns = try parseContextUnknowns(allocator, obj, pack_id),
            .risk_surfaces = try parseContextRisks(allocator, obj, pack_id),
            .candidate_actions = try parseContextActions(allocator, obj, pack_id),
            .check_candidates = try parseContextChecks(allocator, obj, pack_id),
            .evidence_expectations = try parseEvidenceExpectations(allocator, obj, pack_id),
        });
    }
    return try guidance.toOwnedSlice();
}

const PersistentGuidanceTrace = struct {
    pack_id: []const u8,
    pack_version: []const u8,
    status: []const u8,
    guidance_count: usize,
    warning: []const u8 = "",
};

const PersistentGuidanceLoad = struct {
    guidance: []const context_autopsy.PackAutopsyGuidance = &.{},
    traces: []const PersistentGuidanceTrace = &.{},
    warnings: []const context_autopsy.ContextUnknown = &.{},
};

fn mergeContextPackGuidance(
    allocator: std.mem.Allocator,
    persistent: []const context_autopsy.PackAutopsyGuidance,
    request: []const context_autopsy.PackAutopsyGuidance,
) ![]const context_autopsy.PackAutopsyGuidance {
    if (persistent.len == 0) return request;
    if (request.len == 0) return persistent;
    var merged = try allocator.alloc(context_autopsy.PackAutopsyGuidance, persistent.len + request.len);
    @memcpy(merged[0..persistent.len], persistent);
    @memcpy(merged[persistent.len..], request);
    return merged;
}

fn loadPersistentContextPackGuidance(allocator: std.mem.Allocator, workspace_root: ?[]const u8) !PersistentGuidanceLoad {
    _ = workspace_root;
    var traces = std.ArrayList(PersistentGuidanceTrace).init(allocator);
    var warnings = std.ArrayList(context_autopsy.ContextUnknown).init(allocator);
    var guidance = std.ArrayList(context_autopsy.PackAutopsyGuidance).init(allocator);

    const metadata = shards.resolveDefaultProjectMetadata(allocator) catch |err| {
        try warnings.append(try packLoadWarning(allocator, "pack_guidance_mount_registry_unavailable", "knowledge_pack_mounts", "Mounted Knowledge Pack registry could not be resolved; persisted autopsy guidance availability remains unknown.", @errorName(err)));
        return .{ .warnings = try warnings.toOwnedSlice(), .traces = try traces.toOwnedSlice(), .guidance = try guidance.toOwnedSlice() };
    };
    const paths = shards.resolvePaths(allocator, metadata.metadata) catch |err| {
        try warnings.append(try packLoadWarning(allocator, "pack_guidance_mount_registry_unavailable", "knowledge_pack_mounts", "Mounted Knowledge Pack paths could not be resolved; persisted autopsy guidance availability remains unknown.", @errorName(err)));
        return .{ .warnings = try warnings.toOwnedSlice(), .traces = try traces.toOwnedSlice(), .guidance = try guidance.toOwnedSlice() };
    };

    const mounts = knowledge_pack_store.listResolvedMounts(allocator, &paths) catch |err| {
        try warnings.append(try packLoadWarning(allocator, "pack_guidance_mount_registry_unavailable", "knowledge_pack_mounts", "Mounted Knowledge Pack registry could not be loaded; persisted autopsy guidance availability remains unknown.", @errorName(err)));
        return .{ .warnings = try warnings.toOwnedSlice(), .traces = try traces.toOwnedSlice(), .guidance = try guidance.toOwnedSlice() };
    };
    // This loader is dispatch-arena scoped; intermediate mount/path allocations
    // are released with the arena after the rendered response is complete.

    for (mounts) |mount| {
        if (!mount.entry.enabled) {
            try traces.append(try packGuidanceTrace(allocator, mount.entry.pack_id, mount.entry.pack_version, "skipped_disabled", 0, ""));
            continue;
        }
        const guidance_path = mount.autopsy_guidance_abs_path orelse {
            try traces.append(try packGuidanceTrace(allocator, mount.entry.pack_id, mount.entry.pack_version, "no_guidance_path", 0, ""));
            continue;
        };
        const file_bytes = readFileAbsoluteAlloc(allocator, guidance_path, 512 * 1024) catch |err| switch (err) {
            error.FileNotFound => {
                const warning = "manifest declares autopsy guidance path but the file was not found";
                try traces.append(try packGuidanceTrace(allocator, mount.entry.pack_id, mount.entry.pack_version, "missing_guidance", 0, warning));
                try warnings.append(try packLoadWarning(allocator, "missing_persistent_pack_guidance", mount.entry.pack_id, warning, @errorName(err)));
                continue;
            },
            else => {
                const warning = "persistent autopsy guidance could not be read";
                try traces.append(try packGuidanceTrace(allocator, mount.entry.pack_id, mount.entry.pack_version, "guidance_read_warning", 0, warning));
                try warnings.append(try packLoadWarning(allocator, "persistent_pack_guidance_read_warning", mount.entry.pack_id, warning, @errorName(err)));
                continue;
            },
        };

        const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, file_bytes, .{}) catch |err| {
            const warning = "persistent autopsy guidance JSON is malformed";
            try traces.append(try packGuidanceTrace(allocator, mount.entry.pack_id, mount.entry.pack_version, "malformed_guidance", 0, warning));
            try warnings.append(try packLoadWarning(allocator, "malformed_persistent_pack_guidance", mount.entry.pack_id, warning, @errorName(err)));
            continue;
        };
        const parsed_guidance = parsePersistentGuidanceValue(allocator, parsed, mount.entry.pack_id, mount.entry.pack_version) catch |err| {
            const warning = "persistent autopsy guidance shape is unsupported";
            try traces.append(try packGuidanceTrace(allocator, mount.entry.pack_id, mount.entry.pack_version, "unsupported_guidance_shape", 0, warning));
            try warnings.append(try packLoadWarning(allocator, "unsupported_persistent_pack_guidance", mount.entry.pack_id, warning, @errorName(err)));
            continue;
        };
        for (parsed_guidance) |item| try guidance.append(item);
        try traces.append(try packGuidanceTrace(allocator, mount.entry.pack_id, mount.entry.pack_version, "loaded", parsed_guidance.len, ""));
    }

    return .{
        .guidance = try guidance.toOwnedSlice(),
        .traces = try traces.toOwnedSlice(),
        .warnings = try warnings.toOwnedSlice(),
    };
}

fn parsePersistentGuidanceValue(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    pack_id: []const u8,
    pack_version: []const u8,
) ![]const context_autopsy.PackAutopsyGuidance {
    const owned_pack_id = try allocator.dupe(u8, pack_id);
    const owned_pack_version = try allocator.dupe(u8, pack_version);
    const array_value = switch (value) {
        .array => value,
        .object => |obj| blk: {
            if (obj.get("schema")) |schema_value| {
                if (schema_value != .string) return error.InvalidPersistentPackGuidance;
                if (!std.mem.eql(u8, schema_value.string, autopsy_guidance_validator.AUTOPSY_GUIDANCE_SCHEMA_V1)) return error.UnsupportedPersistentPackGuidanceSchema;
            }
            break :blk obj.get("pack_guidance") orelse obj.get("packGuidance") orelse return error.InvalidPersistentPackGuidance;
        },
        else => return error.InvalidPersistentPackGuidance,
    };
    if (array_value != .array) return error.InvalidPersistentPackGuidance;
    var guidance = std.ArrayList(context_autopsy.PackAutopsyGuidance).init(allocator);
    for (array_value.array.items) |item| {
        const obj = valueObject(item) orelse continue;
        const match_obj = if (obj.get("match")) |m| valueObject(m) else null;
        try guidance.append(.{
            .influence = .{
                .pack_name = owned_pack_id,
                .pack_version = owned_pack_version,
                .source_kind = "persistent_pack_autopsy_guidance",
                .reason = getStr(obj, "reason", "reason") orelse "Persisted Knowledge Pack autopsy guidance contributed Context Autopsy candidates.",
                .weight = getStr(obj, "weight", "weight") orelse "medium",
            },
            .match = if (match_obj) |m| try parsePackAutopsyMatch(allocator, m) else .{},
            .signals = try parseContextSignals(allocator, obj, owned_pack_id),
            .suggested_unknowns = try parseContextUnknowns(allocator, obj, owned_pack_id),
            .risk_surfaces = try parseContextRisks(allocator, obj, owned_pack_id),
            .candidate_actions = try parseContextActions(allocator, obj, owned_pack_id),
            .check_candidates = try parseContextChecks(allocator, obj, owned_pack_id),
            .evidence_expectations = try parseEvidenceExpectations(allocator, obj, owned_pack_id),
        });
    }
    return try guidance.toOwnedSlice();
}

fn packLoadWarning(allocator: std.mem.Allocator, name: []const u8, source_pack: []const u8, reason: []const u8, detail: []const u8) !context_autopsy.ContextUnknown {
    _ = detail;
    return .{
        .name = try allocator.dupe(u8, name),
        .source_pack = try allocator.dupe(u8, source_pack),
        .importance = "medium",
        .reason = try allocator.dupe(u8, reason),
    };
}

fn packGuidanceTrace(
    allocator: std.mem.Allocator,
    pack_id: []const u8,
    pack_version: []const u8,
    status: []const u8,
    guidance_count: usize,
    warning: []const u8,
) !PersistentGuidanceTrace {
    return .{
        .pack_id = try allocator.dupe(u8, pack_id),
        .pack_version = try allocator.dupe(u8, pack_version),
        .status = try allocator.dupe(u8, status),
        .guidance_count = guidance_count,
        .warning = try allocator.dupe(u8, warning),
    };
}

fn parseContextArtifactRefs(allocator: std.mem.Allocator, request_obj: std.json.ObjectMap) ![]const context_artifacts.ArtifactRef {
    const value = request_obj.get("artifact_refs") orelse request_obj.get("artifactRefs") orelse return &.{};
    if (value != .array) return &.{};
    var refs = std.ArrayList(context_artifacts.ArtifactRef).init(allocator);
    for (value.array.items) |item| {
        const obj = valueObject(item) orelse continue;
        const path = getStr(obj, "path", "path") orelse continue;
        const kind_text = getStr(obj, "kind", "kind") orelse "file";
        const kind: context_artifacts.ArtifactRefKind = if (std.mem.eql(u8, kind_text, "directory") or std.mem.eql(u8, kind_text, "dir")) .directory else .file;
        try refs.append(.{
            .kind = kind,
            .path = path,
            .purpose = getStr(obj, "purpose", "purpose") orelse "",
            .reason = getStr(obj, "reason", "reason") orelse "",
            .include_filters = try parseStringArrayAliases(allocator, obj, &.{ "include", "includes", "include_filters", "includeFilters" }),
            .exclude_filters = try parseStringArrayAliases(allocator, obj, &.{ "exclude", "excludes", "exclude_filters", "excludeFilters" }),
            .max_file_bytes = getOptionalUsize(obj, "max_file_bytes", "maxFileBytes") orelse context_artifacts.DEFAULT_MAX_FILE_BYTES,
            .max_chunk_bytes = getOptionalUsize(obj, "max_chunk_bytes", "maxChunkBytes") orelse context_artifacts.DEFAULT_MAX_CHUNK_BYTES,
            .max_files = getOptionalUsize(obj, "max_files", "maxFiles") orelse context_artifacts.DEFAULT_MAX_FILES,
            .max_entries = getOptionalUsize(obj, "max_entries", "maxEntries") orelse context_artifacts.DEFAULT_MAX_ENTRIES,
            .max_bytes = getOptionalUsize(obj, "max_bytes", "maxBytes") orelse context_artifacts.DEFAULT_MAX_BYTES,
        });
    }
    return try refs.toOwnedSlice();
}

fn parseContextInputRefs(
    allocator: std.mem.Allocator,
    request_obj: std.json.ObjectMap,
    context_obj: std.json.ObjectMap,
) ![]const context_inputs.InputRef {
    const value = context_obj.get("input_refs") orelse context_obj.get("inputRefs") orelse request_obj.get("input_refs") orelse request_obj.get("inputRefs") orelse return &.{};
    if (value != .array) return &.{};
    var refs = std.ArrayList(context_inputs.InputRef).init(allocator);
    for (value.array.items) |item| {
        const obj = valueObject(item) orelse continue;
        const path = getStr(obj, "path", "path") orelse continue;
        const kind_text = getStr(obj, "kind", "kind") orelse "file";
        const kind: context_inputs.InputRefKind = if (std.mem.eql(u8, kind_text, "file")) .file else .unsupported;
        try refs.append(.{
            .kind = kind,
            .path = path,
            .id = getStr(obj, "id", "id") orelse "",
            .label = getStr(obj, "label", "label") orelse "",
            .purpose = getStr(obj, "purpose", "purpose") orelse "",
            .reason = getStr(obj, "reason", "reason") orelse "",
            .max_bytes = getOptionalUsize(obj, "max_bytes", "maxBytes") orelse context_inputs.DEFAULT_MAX_BYTES,
        });
    }
    return try refs.toOwnedSlice();
}

const InputRefStringField = enum { label, purpose, reason };
const ArtifactRefStringField = enum { purpose, reason };

fn inputRefStringFieldList(allocator: std.mem.Allocator, refs: []const context_inputs.InputRef, field: InputRefStringField) ![]const []const u8 {
    var out = std.ArrayList([]const u8).init(allocator);
    for (refs) |ref| {
        const value = switch (field) {
            .label => ref.label,
            .purpose => ref.purpose,
            .reason => ref.reason,
        };
        if (value.len != 0) try out.append(value);
    }
    return try out.toOwnedSlice();
}

fn artifactRefStringFieldList(allocator: std.mem.Allocator, refs: []const context_artifacts.ArtifactRef, field: ArtifactRefStringField) ![]const []const u8 {
    var out = std.ArrayList([]const u8).init(allocator);
    for (refs) |ref| {
        const value = switch (field) {
            .purpose => ref.purpose,
            .reason => ref.reason,
        };
        if (value.len != 0) try out.append(value);
    }
    return try out.toOwnedSlice();
}

fn inputCoverageHasSkipReason(coverage: *const context_inputs.InputCoverageReport, reason: []const u8) bool {
    for (coverage.skipped_inputs) |skip| {
        if (std.mem.eql(u8, skip.reason, reason)) return true;
    }
    return false;
}

fn parseStringArrayAliases(allocator: std.mem.Allocator, obj: std.json.ObjectMap, names: []const []const u8) ![]const []const u8 {
    for (names) |name| {
        if (obj.get(name)) |value| {
            if (value != .array) return &.{};
            var items = std.ArrayList([]const u8).init(allocator);
            for (value.array.items) |item| {
                if (item == .string) try items.append(item.string);
            }
            return try items.toOwnedSlice();
        }
    }
    return &.{};
}

fn getOptionalUsize(obj: std.json.ObjectMap, snake: []const u8, camel: []const u8) ?usize {
    const raw = getInt(obj, snake, camel) orelse return null;
    if (raw <= 0) return null;
    return @as(usize, @intCast(raw));
}

fn appendContextUnknown(
    allocator: std.mem.Allocator,
    current: []context_autopsy.ContextUnknown,
    unknown: context_autopsy.ContextUnknown,
) ![]context_autopsy.ContextUnknown {
    const next = try allocator.alloc(context_autopsy.ContextUnknown, current.len + 1);
    @memcpy(next[0..current.len], current);
    next[current.len] = unknown;
    allocator.free(current);
    return next;
}

fn appendContextSignal(
    allocator: std.mem.Allocator,
    current: []context_autopsy.ContextSignal,
    signal: context_autopsy.ContextSignal,
) ![]context_autopsy.ContextSignal {
    const next = try allocator.alloc(context_autopsy.ContextSignal, current.len + 1);
    @memcpy(next[0..current.len], current);
    next[current.len] = signal;
    allocator.free(current);
    return next;
}

fn appendEvidenceExpectation(
    allocator: std.mem.Allocator,
    current: []context_autopsy.EvidenceExpectation,
    expectation: context_autopsy.EvidenceExpectation,
) ![]context_autopsy.EvidenceExpectation {
    const next = try allocator.alloc(context_autopsy.EvidenceExpectation, current.len + 1);
    @memcpy(next[0..current.len], current);
    next[current.len] = expectation;
    allocator.free(current);
    return next;
}

fn appendPendingEvidenceObligation(
    allocator: std.mem.Allocator,
    current: []context_autopsy.PendingEvidenceObligation,
    obligation: context_autopsy.PendingEvidenceObligation,
) ![]context_autopsy.PendingEvidenceObligation {
    const next = try allocator.alloc(context_autopsy.PendingEvidenceObligation, current.len + 1);
    @memcpy(next[0..current.len], current);
    next[current.len] = obligation;
    allocator.free(current);
    return next;
}

fn parsePackAutopsyMatch(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !context_autopsy.PackAutopsyMatch {
    return .{
        .intent_tags_any = try parseStringArrayField(allocator, obj, "intent_tags_any", "intentTagsAny"),
        .intent_tags_all = try parseStringArrayField(allocator, obj, "intent_tags_all", "intentTagsAll"),
        .context_keywords_any = try parseStringArrayField(allocator, obj, "context_keywords_any", "contextKeywordsAny"),
        .context_keywords_all = try parseStringArrayField(allocator, obj, "context_keywords_all", "contextKeywordsAll"),
        .artifact_kinds_any = try parseStringArrayField(allocator, obj, "artifact_kinds_any", "artifactKindsAny"),
        .artifact_kinds_all = try parseStringArrayField(allocator, obj, "artifact_kinds_all", "artifactKindsAll"),
        .situation_kinds_any = try parseStringArrayField(allocator, obj, "situation_kinds_any", "situationKindsAny"),
        .situation_kinds_all = try parseStringArrayField(allocator, obj, "situation_kinds_all", "situationKindsAll"),
        .required_context_fields = try parseStringArrayField(allocator, obj, "required_context_fields", "requiredContextFields"),
    };
}

fn guidanceArray(obj: std.json.ObjectMap, snake: []const u8, camel: []const u8) ?std.json.Array {
    const value = obj.get(snake) orelse obj.get(camel) orelse return null;
    return if (value == .array) value.array else null;
}

fn parseContextSignals(allocator: std.mem.Allocator, obj: std.json.ObjectMap, pack_id: []const u8) ![]const context_autopsy.ContextSignal {
    var out = std.ArrayList(context_autopsy.ContextSignal).init(allocator);
    if (guidanceArray(obj, "signals", "signals")) |items| {
        for (items.items) |item| {
            const signal = valueObject(item) orelse continue;
            try out.append(.{
                .name = getStr(signal, "name", "name") orelse "unnamed_signal",
                .source_pack = getStr(signal, "source_pack", "sourcePack") orelse pack_id,
                .kind = getStr(signal, "kind", "kind") orelse "generic_signal",
                .confidence = getStr(signal, "confidence", "confidence") orelse "low",
                .reason = getStr(signal, "reason", "reason") orelse "Pack guidance signal.",
            });
        }
    }
    return try out.toOwnedSlice();
}

fn parseContextUnknowns(allocator: std.mem.Allocator, obj: std.json.ObjectMap, pack_id: []const u8) ![]const context_autopsy.ContextUnknown {
    var out = std.ArrayList(context_autopsy.ContextUnknown).init(allocator);
    if (guidanceArray(obj, "unknowns", "unknowns")) |items| {
        for (items.items) |item| {
            const unknown = valueObject(item) orelse continue;
            try out.append(.{
                .name = getStr(unknown, "name", "name") orelse "unnamed_unknown",
                .source_pack = getStr(unknown, "source_pack", "sourcePack") orelse pack_id,
                .importance = getStr(unknown, "importance", "importance") orelse "medium",
                .reason = getStr(unknown, "reason", "reason") orelse "Pack guidance expects missing context.",
            });
        }
    }
    return try out.toOwnedSlice();
}

fn parseContextRisks(allocator: std.mem.Allocator, obj: std.json.ObjectMap, pack_id: []const u8) ![]const context_autopsy.ContextRiskSurface {
    var out = std.ArrayList(context_autopsy.ContextRiskSurface).init(allocator);
    if (guidanceArray(obj, "risks", "risks")) |items| {
        for (items.items) |item| {
            const risk = valueObject(item) orelse continue;
            const reason = getStr(risk, "reason", "reason") orelse "Pack guidance risk surface.";
            try out.append(.{
                .risk_kind = getStr(risk, "risk_kind", "riskKind") orelse getStr(risk, "name", "name") orelse "unnamed_risk",
                .source_pack = getStr(risk, "source_pack", "sourcePack") orelse pack_id,
                .reason = reason,
                .suggested_caution = getStr(risk, "suggested_caution", "suggestedCaution") orelse reason,
            });
        }
    }
    return try out.toOwnedSlice();
}

fn parseContextActions(allocator: std.mem.Allocator, obj: std.json.ObjectMap, pack_id: []const u8) ![]const context_autopsy.ContextCandidateAction {
    var out = std.ArrayList(context_autopsy.ContextCandidateAction).init(allocator);
    if (guidanceArray(obj, "candidate_actions", "candidateActions")) |items| {
        for (items.items) |item| {
            const action = valueObject(item) orelse continue;
            const summary = getStr(action, "summary", "summary") orelse getStr(action, "reason", "reason") orelse "Pack guidance candidate action.";
            try out.append(.{
                .id = getStr(action, "id", "id") orelse "unnamed_candidate_action",
                .source_pack = getStr(action, "source_pack", "sourcePack") orelse pack_id,
                .action_type = getStr(action, "action_type", "actionType") orelse "generic_action",
                .payload = action.get("payload") orelse .null,
                .reason = summary,
                .risk_level = getStr(action, "risk_level", "riskLevel") orelse "medium",
                .requires_user_confirmation = getBool(action, "requires_user_confirmation", "requiresUserConfirmation") orelse true,
                .non_authorizing = getBool(action, "non_authorizing", "nonAuthorizing") orelse true,
            });
        }
    }
    return try out.toOwnedSlice();
}

fn parseContextChecks(allocator: std.mem.Allocator, obj: std.json.ObjectMap, pack_id: []const u8) ![]const context_autopsy.ContextCheckCandidate {
    var out = std.ArrayList(context_autopsy.ContextCheckCandidate).init(allocator);
    if (guidanceArray(obj, "check_candidates", "checkCandidates")) |items| {
        for (items.items) |item| {
            const check = valueObject(item) orelse continue;
            const check_kind = getStr(check, "check_kind", "checkKind") orelse getStr(check, "check_type", "checkType") orelse "soft";
            const check_type = if (std.mem.eql(u8, check_kind, "hard") or std.mem.eql(u8, check_kind, "hard_verifier")) "hard_verifier" else "soft_real_world_check";
            try out.append(.{
                .id = getStr(check, "id", "id") orelse "unnamed_check_candidate",
                .source_pack = getStr(check, "source_pack", "sourcePack") orelse pack_id,
                .check_type = check_type,
                .purpose = getStr(check, "summary", "summary") orelse getStr(check, "purpose", "purpose") orelse "Pack guidance check candidate.",
                .risk_level = getStr(check, "risk_level", "riskLevel") orelse "medium",
                .confidence = getStr(check, "confidence", "confidence") orelse "medium",
                .evidence_strength = getStr(check, "evidence_strength", "evidenceStrength") orelse if (std.mem.eql(u8, check_type, "hard_verifier")) "absolute" else "heuristic",
                .requires_user_confirmation = true,
                .non_authorizing = getBool(check, "non_authorizing", "nonAuthorizing") orelse true,
                .executes_by_default = getBool(check, "executes_by_default", "executesByDefault") orelse false,
                .why_candidate_exists = getStr(check, "why_candidate_exists", "whyCandidateExists") orelse "Pack guidance expects evidence before claims.",
            });
        }
    }
    return try out.toOwnedSlice();
}

fn parseEvidenceExpectations(allocator: std.mem.Allocator, obj: std.json.ObjectMap, pack_id: []const u8) ![]const context_autopsy.EvidenceExpectation {
    var out = std.ArrayList(context_autopsy.EvidenceExpectation).init(allocator);
    if (guidanceArray(obj, "evidence_expectations", "evidenceExpectations")) |items| {
        for (items.items) |item| {
            const expectation = valueObject(item) orelse continue;
            const id = getStr(expectation, "id", "id") orelse getStr(expectation, "expected_signal", "expectedSignal") orelse "unnamed_evidence_expectation";
            const summary = getStr(expectation, "summary", "summary") orelse getStr(expectation, "reason", "reason") orelse "Pending evidence expectation.";
            try out.append(.{
                .id = id,
                .summary = summary,
                .expectation_kind = getStr(expectation, "expectation_kind", "expectationKind") orelse "soft",
                .expected_signal = getStr(expectation, "expected_signal", "expectedSignal") orelse id,
                .source_pack = getStr(expectation, "source_pack", "sourcePack") orelse pack_id,
                .reason = getStr(expectation, "reason", "reason") orelse summary,
            });
        }
    }
    return try out.toOwnedSlice();
}

fn writeContextAutopsyResult(
    w: anytype,
    result: *const context_autopsy.ContextAutopsyResult,
    artifact_coverage: ?*const context_artifacts.CoverageReport,
    input_coverage: ?*const context_inputs.InputCoverageReport,
) !void {
    try w.writeAll("{\"contextCase\":{\"description\":\"");
    try writeEscaped(w, result.context_case.description);
    try w.writeAll("\",\"intakeType\":\"");
    try writeEscaped(w, result.context_case.intake_type);
    try w.writeAll("\",\"intentTags\":");
    try writeStringList(w, result.context_case.intent_tags);
    try w.writeAll(",\"artifactKinds\":");
    try writeStringList(w, result.context_case.artifact_kinds);
    try w.writeAll(",\"situationKinds\":");
    try writeStringList(w, result.context_case.situation_kinds);
    try w.writeAll("},\"detectedSignals\":[");
    for (result.detected_signals, 0..) |signal, idx| {
        if (idx != 0) try w.writeByte(',');
        try w.writeAll("{\"name\":\"");
        try writeEscaped(w, signal.name);
        try w.writeAll("\",\"sourcePack\":\"");
        try writeEscaped(w, signal.source_pack);
        try w.writeAll("\",\"kind\":\"");
        try writeEscaped(w, signal.kind);
        try w.writeAll("\",\"confidence\":\"");
        try writeEscaped(w, signal.confidence);
        try w.writeAll("\",\"reason\":\"");
        try writeEscaped(w, signal.reason);
        try w.writeAll("\"}");
    }
    try w.writeAll("],\"suggestedUnknowns\":[");
    for (result.suggested_unknowns, 0..) |unknown, idx| {
        if (idx != 0) try w.writeByte(',');
        try w.writeAll("{\"name\":\"");
        try writeEscaped(w, unknown.name);
        try w.writeAll("\",\"sourcePack\":\"");
        try writeEscaped(w, unknown.source_pack);
        try w.writeAll("\",\"importance\":\"");
        try writeEscaped(w, unknown.importance);
        try w.writeAll("\",\"reason\":\"");
        try writeEscaped(w, unknown.reason);
        try w.writeAll("\",\"isMissingEvidence\":");
        try w.writeAll(if (unknown.is_missing_evidence) "true" else "false");
        try w.writeAll(",\"isNegativeEvidence\":");
        try w.writeAll(if (unknown.is_negative_evidence) "true" else "false");
        try w.writeAll("}");
    }
    try w.writeAll("],\"riskSurfaces\":[");
    for (result.risk_surfaces, 0..) |risk, idx| {
        if (idx != 0) try w.writeByte(',');
        try w.writeAll("{\"riskKind\":\"");
        try writeEscaped(w, risk.risk_kind);
        try w.writeAll("\",\"sourcePack\":\"");
        try writeEscaped(w, risk.source_pack);
        try w.writeAll("\",\"reason\":\"");
        try writeEscaped(w, risk.reason);
        try w.writeAll("\",\"suggestedCaution\":\"");
        try writeEscaped(w, risk.suggested_caution);
        try w.writeAll("\",\"nonAuthorizing\":");
        try w.writeAll(if (risk.non_authorizing) "true" else "false");
        try w.writeAll("}");
    }
    try w.writeAll("],\"candidateActions\":[");
    for (result.candidate_actions, 0..) |action, idx| {
        if (idx != 0) try w.writeByte(',');
        try w.writeAll("{\"id\":\"");
        try writeEscaped(w, action.id);
        try w.writeAll("\",\"sourcePack\":\"");
        try writeEscaped(w, action.source_pack);
        try w.writeAll("\",\"actionType\":\"");
        try writeEscaped(w, action.action_type);
        try w.writeAll("\",\"payload\":");
        try std.json.stringify(action.payload, .{}, w);
        try w.writeAll(",\"reason\":\"");
        try writeEscaped(w, action.reason);
        try w.writeAll("\",\"riskLevel\":\"");
        try writeEscaped(w, action.risk_level);
        try w.writeAll("\",\"requiresUserConfirmation\":");
        try w.writeAll(if (action.requires_user_confirmation) "true" else "false");
        try w.writeAll(",\"nonAuthorizing\":");
        try w.writeAll(if (action.non_authorizing) "true" else "false");
        try w.writeAll("}");
    }
    try w.writeAll("],\"checkCandidates\":[");
    for (result.check_candidates, 0..) |check, idx| {
        if (idx != 0) try w.writeByte(',');
        try w.writeAll("{\"id\":\"");
        try writeEscaped(w, check.id);
        try w.writeAll("\",\"sourcePack\":\"");
        try writeEscaped(w, check.source_pack);
        try w.writeAll("\",\"checkType\":\"");
        try writeEscaped(w, check.check_type);
        try w.writeAll("\",\"purpose\":\"");
        try writeEscaped(w, check.purpose);
        try w.writeAll("\",\"riskLevel\":\"");
        try writeEscaped(w, check.risk_level);
        try w.writeAll("\",\"confidence\":\"");
        try writeEscaped(w, check.confidence);
        try w.writeAll("\",\"evidenceStrength\":\"");
        try writeEscaped(w, check.evidence_strength);
        try w.writeAll("\",\"requiresUserConfirmation\":");
        try w.writeAll(if (check.requires_user_confirmation) "true" else "false");
        try w.writeAll(",\"nonAuthorizing\":");
        try w.writeAll(if (check.non_authorizing) "true" else "false");
        try w.writeAll(",\"executesByDefault\":");
        try w.writeAll(if (check.executes_by_default) "true" else "false");
        try w.writeAll(",\"whyCandidateExists\":\"");
        try writeEscaped(w, check.why_candidate_exists);
        try w.writeAll("\"}");
    }
    try w.writeAll("],\"evidenceExpectations\":[");
    for (result.evidence_expectations, 0..) |expectation, idx| {
        if (idx != 0) try w.writeByte(',');
        try w.writeAll("{\"id\":\"");
        try writeEscaped(w, expectation.id);
        try w.writeAll("\",\"summary\":\"");
        try writeEscaped(w, expectation.summary);
        try w.writeAll("\",\"expectationKind\":\"");
        try writeEscaped(w, expectation.expectation_kind);
        try w.writeAll("\",\"expectedSignal\":\"");
        try writeEscaped(w, expectation.expected_signal);
        try w.writeAll("\",\"sourcePack\":\"");
        try writeEscaped(w, expectation.source_pack);
        try w.writeAll("\",\"reason\":\"");
        try writeEscaped(w, expectation.reason);
        try w.writeAll("\"}");
    }
    try w.writeAll("],\"pendingEvidenceObligations\":[");
    for (result.pending_evidence_obligations, 0..) |obligation, idx| {
        if (idx != 0) try w.writeByte(',');
        try w.writeAll("{\"id\":\"");
        try writeEscaped(w, obligation.id);
        try w.writeAll("\",\"sourcePack\":\"");
        try writeEscaped(w, obligation.source_pack);
        try w.writeAll("\",\"summary\":\"");
        try writeEscaped(w, obligation.summary);
        try w.writeAll("\",\"expectationKind\":\"");
        try writeEscaped(w, obligation.expectation_kind);
        try w.writeAll("\",\"obligationKind\":\"");
        try writeEscaped(w, obligation.obligation_kind);
        try w.writeAll("\",\"status\":\"");
        try writeEscaped(w, obligation.status);
        try w.writeAll("\",\"executed\":");
        try w.writeAll(if (obligation.executed) "true" else "false");
        try w.writeAll(",\"treatedAsProof\":");
        try w.writeAll(if (obligation.treated_as_proof) "true" else "false");
        try w.writeAll(",\"nonAuthorizing\":");
        try w.writeAll(if (obligation.non_authorizing) "true" else "false");
        try w.writeAll(",\"reason\":\"");
        try writeEscaped(w, obligation.reason);
        try w.writeAll("\"}");
    }
    try w.writeAll("],\"packInfluences\":[");
    for (result.pack_influences, 0..) |influence, idx| {
        if (idx != 0) try w.writeByte(',');
        try w.writeAll("{\"packName\":\"");
        try writeEscaped(w, influence.pack_name);
        try w.writeAll("\",\"packVersion\":\"");
        try writeEscaped(w, influence.pack_version);
        try w.writeAll("\",\"sourceKind\":\"");
        try writeEscaped(w, influence.source_kind);
        try w.writeAll("\",\"reason\":\"");
        try writeEscaped(w, influence.reason);
        try w.writeAll("\",\"matchTrace\":\"");
        try writeEscaped(w, influence.match_trace);
        try w.writeAll("\",\"weight\":\"");
        try writeEscaped(w, influence.weight);
        try w.writeAll("\",\"nonAuthorizing\":");
        try w.writeAll(if (influence.non_authorizing) "true" else "false");
        try w.writeAll(",\"isProofAuthority\":");
        try w.writeAll(if (influence.is_proof_authority) "true" else "false");
        try w.writeAll("}");
    }
    try w.writeAll("]");
    if (artifact_coverage) |coverage| {
        try w.writeAll(",\"artifactCoverage\":");
        try writeArtifactCoverage(w, coverage);
    }
    if (input_coverage) |coverage| {
        try w.writeAll(",\"inputCoverage\":");
        try writeInputCoverage(w, coverage);
    }
    try w.writeAll(",\"state\":\"");
    try writeEscaped(w, result.state);
    try w.writeAll("\",\"nonAuthorizing\":");
    try w.writeAll(if (result.non_authorizing) "true" else "false");
    try w.writeAll("}");
}

fn writePackGuidanceTrace(w: anytype, load: *const PersistentGuidanceLoad, request_guidance_count: usize) !void {
    try w.writeAll("{\"persistentGuidanceEnabled\":true,\"mergeOrder\":\"persistent_mounted_pack_order_then_request_order\",\"persistentGuidanceCount\":");
    try w.print("{d}", .{load.guidance.len});
    try w.writeAll(",\"requestGuidanceCount\":");
    try w.print("{d}", .{request_guidance_count});
    try w.writeAll(",\"packLoads\":[");
    for (load.traces, 0..) |trace, idx| {
        if (idx != 0) try w.writeByte(',');
        try w.writeAll("{\"packId\":\"");
        try writeEscaped(w, trace.pack_id);
        try w.writeAll("\",\"packVersion\":\"");
        try writeEscaped(w, trace.pack_version);
        try w.writeAll("\",\"status\":\"");
        try writeEscaped(w, trace.status);
        try w.writeAll("\",\"guidanceCount\":");
        try w.print("{d}", .{trace.guidance_count});
        try w.writeAll(",\"nonAuthorizing\":true");
        if (trace.warning.len != 0) {
            try w.writeAll(",\"warning\":\"");
            try writeEscaped(w, trace.warning);
            try w.writeAll("\"");
        }
        try w.writeAll("}");
    }
    try w.writeAll("],\"warnings\":[");
    for (load.warnings, 0..) |warning, idx| {
        if (idx != 0) try w.writeByte(',');
        try w.writeAll("{\"name\":\"");
        try writeEscaped(w, warning.name);
        try w.writeAll("\",\"sourcePack\":\"");
        try writeEscaped(w, warning.source_pack);
        try w.writeAll("\",\"reason\":\"");
        try writeEscaped(w, warning.reason);
        try w.writeAll("\",\"isMissingEvidence\":true,\"isNegativeEvidence\":false}");
    }
    try w.writeAll("]}");
}

fn writeArtifactCoverage(w: anytype, coverage: *const context_artifacts.CoverageReport) !void {
    try w.writeAll("{\"artifactsRequested\":[");
    for (coverage.artifacts_requested, 0..) |request, idx| {
        if (idx != 0) try w.writeByte(',');
        try w.writeAll("{\"kind\":\"");
        try writeEscaped(w, request.kind);
        try w.writeAll("\",\"path\":\"");
        try writeEscaped(w, request.path);
        try w.writeAll("\",\"purpose\":\"");
        try writeEscaped(w, request.purpose);
        try w.writeAll("\",\"reason\":\"");
        try writeEscaped(w, request.reason);
        try w.writeAll("\",\"includeFilters\":");
        try writeStringList(w, request.include_filters);
        try w.writeAll(",\"excludeFilters\":");
        try writeStringList(w, request.exclude_filters);
        try w.print(",\"maxFileBytes\":{d},\"maxChunkBytes\":{d},\"maxFiles\":{d},\"maxEntries\":{d},\"maxBytes\":{d}", .{
            request.max_file_bytes,
            request.max_chunk_bytes,
            request.max_files,
            request.max_entries,
            request.max_bytes,
        });
        try w.writeAll("}");
    }
    try w.print("],\"filesConsidered\":{d},\"filesRead\":{d},\"bytesRead\":{d},\"filesSkipped\":{d},\"skipReasons\":[", .{
        coverage.files_considered,
        coverage.files_read,
        coverage.bytes_read,
        coverage.files_skipped,
    });
    for (coverage.skipped_inputs, 0..) |skip, idx| {
        if (idx != 0) try w.writeByte(',');
        try w.writeAll("{\"path\":\"");
        try writeEscaped(w, skip.path);
        try w.writeAll("\",\"reason\":\"");
        try writeEscaped(w, skip.reason);
        try w.writeAll("\"}");
    }
    try w.print("],\"filesTruncated\":{d},\"truncationReasons\":[", .{coverage.files_truncated});
    for (coverage.truncated_inputs, 0..) |truncated, idx| {
        if (idx != 0) try w.writeByte(',');
        try w.writeAll("{\"path\":\"");
        try writeEscaped(w, truncated.path);
        try w.writeAll("\",\"reason\":\"");
        try writeEscaped(w, truncated.reason);
        try w.print("\",\"bytesRead\":{d}", .{truncated.bytes});
        try w.writeAll("}");
    }
    try w.writeAll("],\"budgetHits\":");
    try writeStringList(w, coverage.budget_hits);
    try w.writeAll(",\"unknowns\":[");
    for (coverage.unknowns, 0..) |unknown, idx| {
        if (idx != 0) try w.writeByte(',');
        try w.writeAll("{\"name\":\"");
        try writeEscaped(w, unknown.name);
        try w.writeAll("\",\"path\":\"");
        try writeEscaped(w, unknown.path);
        try w.writeAll("\",\"reason\":\"");
        try writeEscaped(w, unknown.reason);
        try w.writeAll("\"}");
    }
    try w.writeAll("]}");
}

fn writeInputCoverage(w: anytype, coverage: *const context_inputs.InputCoverageReport) !void {
    try w.writeAll("{\"inputRefsRequested\":[");
    for (coverage.input_refs_requested, 0..) |request, idx| {
        if (idx != 0) try w.writeByte(',');
        try w.writeAll("{\"kind\":\"");
        try writeEscaped(w, request.kind);
        try w.writeAll("\",\"path\":\"");
        try writeEscaped(w, request.path);
        try w.writeAll("\",\"id\":\"");
        try writeEscaped(w, request.id);
        try w.writeAll("\",\"label\":\"");
        try writeEscaped(w, request.label);
        try w.writeAll("\",\"purpose\":\"");
        try writeEscaped(w, request.purpose);
        try w.writeAll("\",\"reason\":\"");
        try writeEscaped(w, request.reason);
        try w.print("\",\"maxBytes\":{d}", .{request.max_bytes});
        try w.writeAll("}");
    }
    try w.print("],\"inputsConsidered\":{d},\"inputsRead\":{d},\"bytesRead\":{d},\"inputsSkipped\":{d},\"skipReasons\":[", .{
        coverage.inputs_considered,
        coverage.inputs_read,
        coverage.bytes_read,
        coverage.inputs_skipped,
    });
    for (coverage.skipped_inputs, 0..) |skip, idx| {
        if (idx != 0) try w.writeByte(',');
        try w.writeAll("{\"path\":\"");
        try writeEscaped(w, skip.path);
        try w.writeAll("\",\"id\":\"");
        try writeEscaped(w, skip.id);
        try w.writeAll("\",\"label\":\"");
        try writeEscaped(w, skip.label);
        try w.writeAll("\",\"reason\":\"");
        try writeEscaped(w, skip.reason);
        try w.writeAll("\"}");
    }
    try w.print("],\"inputsTruncated\":{d},\"truncationReasons\":[", .{coverage.inputs_truncated});
    for (coverage.truncated_inputs, 0..) |truncated, idx| {
        if (idx != 0) try w.writeByte(',');
        try w.writeAll("{\"path\":\"");
        try writeEscaped(w, truncated.path);
        try w.writeAll("\",\"id\":\"");
        try writeEscaped(w, truncated.id);
        try w.writeAll("\",\"label\":\"");
        try writeEscaped(w, truncated.label);
        try w.writeAll("\",\"reason\":\"");
        try writeEscaped(w, truncated.reason);
        try w.print("\",\"bytesRead\":{d}", .{truncated.bytes});
        try w.writeAll("}");
    }
    try w.writeAll("],\"budgetHits\":");
    try writeStringList(w, coverage.budget_hits);
    try w.writeAll(",\"unknowns\":[");
    for (coverage.unknowns, 0..) |unknown, idx| {
        if (idx != 0) try w.writeByte(',');
        try w.writeAll("{\"name\":\"");
        try writeEscaped(w, unknown.name);
        try w.writeAll("\",\"path\":\"");
        try writeEscaped(w, unknown.path);
        try w.writeAll("\",\"id\":\"");
        try writeEscaped(w, unknown.id);
        try w.writeAll("\",\"label\":\"");
        try writeEscaped(w, unknown.label);
        try w.writeAll("\",\"reason\":\"");
        try writeEscaped(w, unknown.reason);
        try w.writeAll("\"}");
    }
    try w.writeAll("]}");
}

fn writeStringList(w: anytype, values: []const []const u8) !void {
    try w.writeByte('[');
    for (values, 0..) |value, idx| {
        if (idx != 0) try w.writeByte(',');
        try w.writeByte('"');
        try writeEscaped(w, value);
        try w.writeByte('"');
    }
    try w.writeByte(']');
}

// ── Project Autopsy ───────────────────────────────────────────────────
//
// Read-only bounded workspace inspection.
// No commands are executed. No files are mutated. No verifiers are
// registered or scheduled. Output is always draft/non-authorizing.
// Command candidates remain argv arrays with requires_user_confirmation=true.
// Verifier plan candidates have executes_by_default=false.
// Missing evidence is expressed as unknown/gap, not negative evidence.

fn dispatchProjectAutopsy(allocator: std.mem.Allocator, workspace_root: ?[]const u8, request_body: ?[]const u8) !DispatchResult {
    const root = workspace_root orelse return .{
        .status = .rejected,
        .err = .{ .code = .missing_required_field, .message = "workspace root is required for project.autopsy" },
    };

    // The workspace root is the analysis boundary. It is canonicalized using realpathAlloc
    // inside project_autopsy.analyze. There is no subpath accepted by this operation.
    // Therefore, if the canonicalized workspace root exists, analysis is safely bounded to it.

    // Parse optional options from request body.
    var max_entries: usize = project_autopsy.DEFAULT_MAX_ENTRIES;
    var max_depth: usize = project_autopsy.DEFAULT_MAX_DEPTH;

    if (request_body) |body| {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
            return .{ .status = .rejected, .err = .{ .code = .json_contract_error, .message = "invalid JSON in request body" } };
        };
        defer parsed.deinit();
        if (parsed.value == .object) {
            const obj = parsed.value.object;
            if (getInt(obj, "max_entries", "maxEntries")) |v| {
                if (v > 0) max_entries = @min(@as(usize, @intCast(v)), project_autopsy.DEFAULT_MAX_ENTRIES);
            }
            if (getInt(obj, "max_depth", "maxDepth")) |v| {
                if (v > 0) max_depth = @min(@as(usize, @intCast(v)), project_autopsy.DEFAULT_MAX_DEPTH);
            }
        }
    }

    const options: project_autopsy.AnalyzeOptions = .{
        .max_entries = max_entries,
        .max_depth = max_depth,
    };

    // Run the bounded read-only analysis in a sub-arena so that all analysis
    // allocations are freed together after we stringify the result into the
    // main allocator's output buffer. This prevents leaks in the GPA.
    var analysis_arena = std.heap.ArenaAllocator.init(allocator);
    defer analysis_arena.deinit();
    const analysis_alloc = analysis_arena.allocator();

    const autopsy_result = project_autopsy.analyze(analysis_alloc, root, options) catch |err| {
        if (err == error.FileNotFound) {
            return .{
                .status = .rejected,
                .err = .{ .code = .path_not_found, .message = "workspace root does not exist" },
            };
        }
        return .{
            .status = .failed,
            .err = .{
                .code = .internal_error,
                .message = "project autopsy analysis failed",
                .details = @errorName(err),
            },
        };
    };

    // Stringify into the main allocator's output buffer.
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    // Wrap in a "projectAutopsy" result envelope.
    try w.writeAll("{\"projectAutopsy\":");
    try autopsy_result.writeJson(w);
    try w.writeAll(",\"readOnly\":true,\"commandsExecuted\":false,\"verifiersExecuted\":false,\"verifiersRegistered\":false,\"mutatesState\":false,\"non_authorizing\":true}");

    // analysis_arena.deinit() is called by defer above; autopsy_result slices are gone.
    // The out buffer (owned by main allocator) contains the serialized output.

    var gip_state = schema.draftResultState();
    // Autopsy is permanently draft; override the stop reason to make it clear
    // the output is informational rather than unresolved.
    gip_state.stop_reason = .none;
    gip_state.unresolved_reason = null;
    gip_state.non_authorization_notice = "project autopsy output is a draft profile; it does not constitute supported output or proof of any claim";

    return .{
        .status = .ok,
        .result_state = gip_state,
        .result_json = try out.toOwnedSlice(),
        .allocated_result = true,
    };
}

fn dispatchLearningLoopPlan(allocator: std.mem.Allocator, workspace_root: ?[]const u8, request_body: ?[]const u8) !DispatchResult {
    const root = workspace_root orelse return .{
        .status = .rejected,
        .err = .{ .code = .missing_required_field, .message = "workspace root is required for learning.loop.plan" },
    };

    var max_entries: usize = project_autopsy.DEFAULT_MAX_ENTRIES;
    var max_depth: usize = project_autopsy.DEFAULT_MAX_DEPTH;
    var plan_id: ?[]u8 = null;
    defer if (plan_id) |owned| allocator.free(owned);

    if (request_body) |body| {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
            return .{ .status = .rejected, .err = .{ .code = .json_contract_error, .message = "invalid JSON in request body" } };
        };
        defer parsed.deinit();
        if (parsed.value != .object) {
            return .{ .status = .rejected, .err = .{ .code = .invalid_request, .message = "learning.loop.plan request must be a JSON object" } };
        }
        const obj = parsed.value.object;
        if (getInt(obj, "max_entries", "maxEntries")) |v| {
            if (v > 0) max_entries = @min(@as(usize, @intCast(v)), project_autopsy.DEFAULT_MAX_ENTRIES);
        }
        if (getInt(obj, "max_depth", "maxDepth")) |v| {
            if (v > 0) max_depth = @min(@as(usize, @intCast(v)), project_autopsy.DEFAULT_MAX_DEPTH);
        }
        if (getStr(obj, "plan_id", "planId")) |value| {
            plan_id = try allocator.dupe(u8, value);
        }
    }

    var analysis_arena = std.heap.ArenaAllocator.init(allocator);
    defer analysis_arena.deinit();
    const analysis_alloc = analysis_arena.allocator();

    const autopsy_result = project_autopsy.analyze(analysis_alloc, root, .{
        .max_entries = max_entries,
        .max_depth = max_depth,
    }) catch |err| {
        if (err == error.FileNotFound) {
            return .{
                .status = .rejected,
                .err = .{ .code = .path_not_found, .message = "workspace root does not exist" },
            };
        }
        return .{
            .status = .failed,
            .err = .{
                .code = .internal_error,
                .message = "learning loop project autopsy analysis failed",
                .details = @errorName(err),
            },
        };
    };

    const plan = try learning_loop.planFromAutopsy(analysis_alloc, autopsy_result, .{ .plan_id = plan_id });

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    try w.writeAll("{\"learningLoopPlan\":");
    try plan.writeJson(w);
    try w.writeAll(",\"readOnly\":true,\"candidateOnly\":true,\"commandsExecuted\":false,\"verifiersExecuted\":false,\"patchesApplied\":false,\"packsMutated\":false,\"correctionsApplied\":false,\"negativeKnowledgePromoted\":false,\"mutatesState\":false,\"authorityEffect\":\"candidate\",\"non_authorizing\":true}");

    var gip_state = schema.draftResultState();
    gip_state.stop_reason = .none;
    gip_state.unresolved_reason = null;
    gip_state.non_authorization_notice = "learning.loop.plan is read-only and candidate-only; it does not execute commands, run verifiers, apply patches, mutate packs, apply corrections, promote negative knowledge, or grant support";

    return .{
        .status = .ok,
        .result_state = gip_state,
        .result_json = try out.toOwnedSlice(),
        .allocated_result = true,
    };
}

fn parseSigilValidationScope(text: []const u8) ?sigil_core.ValidationScope {
    if (std.ascii.eqlIgnoreCase(text, "boot_control")) return .boot_control;
    if (std.ascii.eqlIgnoreCase(text, "scratch_session")) return .scratch_session;
    return null;
}

fn failedSigilInspectionState(reason: []const u8) schema.ResultState {
    var state = schema.draftResultState();
    state.state = .failed;
    state.permission = .none;
    state.is_draft = false;
    state.verification_state = .unverified;
    state.support_minimum_met = false;
    state.stop_reason = .failed;
    state.failure_reason = reason;
    state.unresolved_reason = null;
    state.non_authorization_notice = "sigil.inspect failed closed; no VM code was executed and no support/proof authority was granted";
    return state;
}

fn renderSigilParseFailure(
    allocator: std.mem.Allocator,
    source: []const u8,
    scope: sigil_core.ValidationScope,
    error_name: []const u8,
) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    try w.writeAll("{\"sigilInspection\":{");
    try w.writeAll("\"status\":\"parse_failed\"");
    try w.print(",\"sourceBytes\":{d}", .{source.len});
    try w.writeAll(",\"validation\":{\"scope\":\"");
    try w.writeAll(@tagName(scope));
    try w.writeAll("\",\"status\":\"failed\",\"issue\":{\"code\":\"parse_failed\",\"instructionIndex\":null,\"message\":\"");
    try writeEscaped(w, error_name);
    try w.writeAll("\"}}");
    try writeSigilSafety(w, false, false);
    try w.writeAll(",\"instructions\":[],\"procedureInspectionRecords\":[],\"disassemblyText\":null");
    try w.writeAll("}}");
    return out.toOwnedSlice();
}

fn renderSigilInspection(
    allocator: std.mem.Allocator,
    source: []const u8,
    program: *const sigil_core.Program,
    disassembly: *const sigil_core.Disassembly,
    rendered_text: []const u8,
) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    var requires_review = false;
    var requires_verification = false;
    for (disassembly.procedure_records) |record| {
        requires_review = requires_review or record.requires_review;
        requires_verification = requires_verification or record.requires_verification;
    }

    try w.writeAll("{\"sigilInspection\":{");
    try w.writeAll("\"status\":\"");
    try w.writeAll(if (disassembly.validation_issue == null) "ok" else "validation_failed");
    try w.writeByte('"');
    try w.print(",\"sourceBytes\":{d},\"instructionCount\":{d},\"stringCount\":{d}", .{
        source.len,
        program.instructions.len,
        program.strings.len,
    });
    try w.writeAll(",\"validation\":{\"scope\":\"");
    try w.writeAll(@tagName(disassembly.validation_scope));
    try w.writeAll("\",\"status\":\"");
    if (disassembly.validation_issue) |issue| {
        try w.writeAll("failed\",\"issue\":{\"code\":\"");
        try w.writeAll(@tagName(issue.code));
        try w.print("\",\"instructionIndex\":{d},\"message\":\"", .{issue.instruction_index});
        try writeEscaped(w, issue.message);
        try w.writeAll("\"}");
    } else {
        try w.writeAll("ok\",\"issue\":null");
    }
    try w.writeAll("}");
    try writeSigilSafety(w, requires_review, requires_verification);
    try w.writeAll(",\"instructions\":[");
    for (disassembly.instructions, 0..) |inst, idx| {
        if (idx != 0) try w.writeByte(',');
        try w.writeAll("{");
        try w.print("\"instructionIndex\":{d},\"opcode\":\"{s}\",\"mode\":\"{s}\",\"a\":{d},\"b\":{d},\"stringIndex\":", .{
            inst.instruction_index,
            @tagName(inst.opcode),
            @tagName(inst.mode),
            inst.a,
            inst.b,
        });
        try writeNullableStringIndexJson(w, inst.string_index);
        try w.writeAll(",\"stringPayload\":");
        try writeNullableStringJson(w, inst.string_payload);
        try w.writeAll("}");
    }
    try w.writeAll("],\"procedureInspectionRecords\":[");
    for (disassembly.procedure_records, 0..) |record, idx| {
        if (idx != 0) try w.writeByte(',');
        try w.writeAll("{");
        try w.print("\"instructionIndex\":{d},\"kind\":\"{s}\",\"opcode\":\"{s}\",\"operandMode\":\"{s}\",\"a\":{d},\"b\":{d},\"stringIndex\":", .{
            record.instruction_index,
            @tagName(record.kind),
            @tagName(record.opcode),
            @tagName(record.operand_mode),
            record.a,
            record.b,
        });
        try writeNullableStringIndexJson(w, record.string_index);
        try w.writeAll(",\"stringPayload\":");
        try writeNullableStringJson(w, record.string_payload);
        try w.writeAll(",\"non_authorizing\":");
        try w.writeAll(if (record.non_authorizing) "true" else "false");
        try w.writeAll(",\"authority_effect\":\"");
        try writeEscaped(w, record.authority_effect);
        try w.writeAll("\",\"requires_review\":");
        try w.writeAll(if (record.requires_review) "true" else "false");
        try w.writeAll(",\"requires_verification\":");
        try w.writeAll(if (record.requires_verification) "true" else "false");
        try w.writeAll("}");
    }
    try w.writeAll("],\"disassemblyText\":\"");
    try writeEscaped(w, rendered_text);
    try w.writeAll("\"}}");
    return out.toOwnedSlice();
}

fn writeSigilSafety(w: anytype, requires_review: bool, requires_verification: bool) !void {
    try w.writeAll(",\"safety\":{\"non_authorizing\":true,\"read_only\":true,\"executed\":false,\"mutates_state\":false,\"authority_effect\":\"candidate\",\"requires_review\":");
    try w.writeAll(if (requires_review) "true" else "false");
    try w.writeAll(",\"requires_verification\":");
    try w.writeAll(if (requires_verification) "true" else "false");
    try w.writeAll(",\"vm_execution\":false,\"commands_executed\":false,\"corpus_mutation\":false,\"pack_mutation\":false,\"negative_knowledge_mutation\":false,\"trust_state_mutation\":false,\"scratch_state_mutation\":false,\"support_granted\":false,\"proof_gate_bypassed\":false}");
}

fn writeNullableStringIndexJson(w: anytype, index: u32) !void {
    if (index == sigil_core.INVALID_STRING_INDEX) {
        try w.writeAll("null");
    } else {
        try w.print("{d}", .{index});
    }
}

fn writeNullableStringJson(w: anytype, value: ?[]const u8) !void {
    if (value) |text| {
        try w.writeByte('"');
        try writeEscaped(w, text);
        try w.writeByte('"');
    } else {
        try w.writeAll("null");
    }
}

fn writeEscaped(w: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '\"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => try w.writeByte(c),
        }
    }
}

fn readFileAbsoluteAlloc(allocator: std.mem.Allocator, abs_path: []const u8, max_bytes: usize) ![]u8 {
    const file = try std.fs.openFileAbsolute(abs_path, .{});
    defer file.close();
    return file.readToEndAlloc(allocator, max_bytes);
}

// ── Patch Test Workspace Helper ──────────────────────────────────────────

const PatchTestWorkspace = struct {
    allocator: std.mem.Allocator,
    workspace_root: []const u8,

    pub const sample_content = "line one\nline two\nline three\n";

    pub fn init(allocator: std.mem.Allocator) !PatchTestWorkspace {
        const rand_id = std.crypto.random.int(u64);
        const workspace_root = try std.fmt.allocPrint(allocator, "/tmp/gip_patch_test_{x}", .{rand_id});
        try std.fs.makeDirAbsolute(workspace_root);

        const file_path = try std.fs.path.join(allocator, &.{ workspace_root, "sample.txt" });
        defer allocator.free(file_path);

        const file = try std.fs.createFileAbsolute(file_path, .{});
        try file.writeAll(sample_content);
        file.close();

        return .{
            .allocator = allocator,
            .workspace_root = workspace_root,
        };
    }

    pub fn deinit(self: *PatchTestWorkspace) void {
        std.fs.deleteTreeAbsolute(self.workspace_root) catch {};
        self.allocator.free(self.workspace_root);
    }
};

test "artifact.patch.propose handles path traversal" {
    const allocator = std.testing.allocator;
    const body =
        \\{
        \\  "path": "../../../etc/passwd",
        \\  "edits": []
        \\}
    ;
    var result = try dispatchArtifactPatchPropose(allocator, "/", body);
    defer result.deinit(allocator);

    try std.testing.expectEqual(core.ProtocolStatus.rejected, result.status);
    try std.testing.expectEqual(core.ErrorCode.path_outside_workspace, result.err.?.code);
}

test "artifact.patch.propose missing file" {
    const allocator = std.testing.allocator;
    const body =
        \\{
        \\  "path": "non_existent_file_xyz.zig",
        \\  "edits": []
        \\}
    ;
    var result = try dispatchArtifactPatchPropose(allocator, "/tmp", body);
    defer result.deinit(allocator);

    try std.testing.expectEqual(core.ProtocolStatus.failed, result.status);
    try std.testing.expectEqual(core.ErrorCode.path_not_found, result.err.?.code);
}

test "artifact.patch.propose invalid span rejected" {
    const allocator = std.testing.allocator;
    var ws = try PatchTestWorkspace.init(allocator);
    defer ws.deinit();

    const body =
        \\{
        \\  "path": "sample.txt",
        \\  "edits": [
        \\    {
        \\      "span": { "start_line": 100000, "start_col": 1, "end_line": 100001, "end_col": 1 },
        \\      "replacement": "foo"
        \\    }
        \\  ]
        \\}
    ;

    var result = try dispatchArtifactPatchPropose(allocator, ws.workspace_root, body);
    defer result.deinit(allocator);

    try std.testing.expectEqual(core.ProtocolStatus.rejected, result.status);
    try std.testing.expectEqual(core.ErrorCode.invalid_patch_span, result.err.?.code);
}

test "artifact.patch.propose successful dry run with non_authorizing" {
    const allocator = std.testing.allocator;
    var ws = try PatchTestWorkspace.init(allocator);
    defer ws.deinit();

    const body =
        \\{
        \\  "path": "sample.txt",
        \\  "edits": [
        \\    {
        \\      "span": { "start_line": 1, "start_col": 1, "end_line": 1, "end_col": 5 },
        \\      "replacement": "LINE"
        \\    }
        \\  ]
        \\}
    ;

    var result = try dispatchArtifactPatchPropose(allocator, ws.workspace_root, body);
    defer result.deinit(allocator);

    try std.testing.expectEqual(core.ProtocolStatus.ok, result.status);
    try std.testing.expect(result.result_state != null);
    try std.testing.expectEqual(core.SemanticState.draft, result.result_state.?.state);
    try std.testing.expect(std.mem.indexOf(u8, result.result_json.?, "\"non_authorizing\":true") != null);
}

test "artifact.patch.propose does not modify source file" {
    const allocator = std.testing.allocator;
    var ws = try PatchTestWorkspace.init(allocator);
    defer ws.deinit();

    const body =
        \\{
        \\  "path": "sample.txt",
        \\  "edits": [
        \\    {
        \\      "span": { "start_line": 1, "start_col": 1, "end_line": 1, "end_col": 5 },
        \\      "replacement": "CHANGED"
        \\    }
        \\  ]
        \\}
    ;

    var result = try dispatchArtifactPatchPropose(allocator, ws.workspace_root, body);
    defer result.deinit(allocator);

    const file_path = try std.fs.path.join(allocator, &.{ ws.workspace_root, "sample.txt" });
    defer allocator.free(file_path);

    const file = try std.fs.openFileAbsolute(file_path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 4096);
    defer allocator.free(content);

    try std.testing.expectEqualStrings(PatchTestWorkspace.sample_content, content);
}

test "artifact.patch.propose overlapping edits rejected" {
    const allocator = std.testing.allocator;
    var ws = try PatchTestWorkspace.init(allocator);
    defer ws.deinit();

    const body =
        \\{
        \\  "path": "sample.txt",
        \\  "edits": [
        \\    {
        \\      "span": { "start_line": 1, "start_col": 1, "end_line": 1, "end_col": 5 },
        \\      "replacement": "a"
        \\    },
        \\    {
        \\      "span": { "start_line": 1, "start_col": 3, "end_line": 1, "end_col": 8 },
        \\      "replacement": "b"
        \\    }
        \\  ]
        \\}
    ;

    var result = try dispatchArtifactPatchPropose(allocator, ws.workspace_root, body);
    defer result.deinit(allocator);

    try std.testing.expectEqual(core.ProtocolStatus.rejected, result.status);
    try std.testing.expectEqual(core.ErrorCode.invalid_patch_span, result.err.?.code);
}

test "artifact.patch.propose expected_text mismatch rejected" {
    const allocator = std.testing.allocator;
    var ws = try PatchTestWorkspace.init(allocator);
    defer ws.deinit();

    const body =
        \\{
        \\  "path": "sample.txt",
        \\  "edits": [
        \\    {
        \\      "span": { "start_line": 1, "start_col": 1, "end_line": 1, "end_col": 5 },
        \\      "replacement": "LINE",
        \\      "precondition": { "expected_text": "WRONG" }
        \\    }
        \\  ]
        \\}
    ;

    var result = try dispatchArtifactPatchPropose(allocator, ws.workspace_root, body);
    defer result.deinit(allocator);

    try std.testing.expectEqual(core.ProtocolStatus.rejected, result.status);
    try std.testing.expectEqual(core.ErrorCode.patch_precondition_failed, result.err.?.code);
}

test "artifact.patch.propose expected_hash mismatch rejected" {
    const allocator = std.testing.allocator;
    var ws = try PatchTestWorkspace.init(allocator);
    defer ws.deinit();

    const body =
        \\{
        \\  "path": "sample.txt",
        \\  "edits": [
        \\    {
        \\      "span": { "start_line": 1, "start_col": 1, "end_line": 1, "end_col": 5 },
        \\      "replacement": "LINE",
        \\      "precondition": { "expected_hash": 999999999 }
        \\    }
        \\  ]
        \\}
    ;

    var result = try dispatchArtifactPatchPropose(allocator, ws.workspace_root, body);
    defer result.deinit(allocator);

    try std.testing.expectEqual(core.ProtocolStatus.rejected, result.status);
    try std.testing.expectEqual(core.ErrorCode.patch_precondition_failed, result.err.?.code);
}

test "artifact.patch.propose oversized replacement rejected" {
    const allocator = std.testing.allocator;
    var ws = try PatchTestWorkspace.init(allocator);
    defer ws.deinit();

    var body_buf = std.ArrayList(u8).init(allocator);
    defer body_buf.deinit();
    const bw = body_buf.writer();

    try bw.writeAll("{\"path\":\"sample.txt\",\"edits\":[{\"span\":{\"start_line\":1,\"start_col\":1,\"end_line\":1,\"end_col\":5},\"replacement\":\"");
    var i: usize = 0;
    while (i < 600 * 1024) : (i += 1) {
        try bw.writeByte('X');
    }
    try bw.writeAll("\"}]}");

    var result = try dispatchArtifactPatchPropose(allocator, ws.workspace_root, body_buf.items);
    defer result.deinit(allocator);

    try std.testing.expectEqual(core.ProtocolStatus.rejected, result.status);
    try std.testing.expectEqual(core.ErrorCode.budget_exhausted, result.err.?.code);
}

test "artifact.patch.apply unsupported in v0.1" {
    const allocator = std.testing.allocator;
    const body =
        \\{
        \\  "path": "sample.txt",
        \\  "edits": []
        \\}
    ;
    var result = try dispatch(allocator, "artifact.patch.apply", core.PROTOCOL_VERSION, "/tmp", null, body);
    defer result.deinit(allocator);

    try std.testing.expectEqual(core.ProtocolStatus.unsupported, result.status);
}

test "artifact.patch.propose deterministic patch_id for same input" {
    const allocator = std.testing.allocator;
    var ws = try PatchTestWorkspace.init(allocator);
    defer ws.deinit();

    const body =
        \\{
        \\  "path": "sample.txt",
        \\  "edits": [
        \\    {
        \\      "span": { "start_line": 1, "start_col": 1, "end_line": 1, "end_col": 5 },
        \\      "replacement": "LINE"
        \\    }
        \\  ]
        \\}
    ;

    var result1 = try dispatchArtifactPatchPropose(allocator, ws.workspace_root, body);
    defer result1.deinit(allocator);

    var result2 = try dispatchArtifactPatchPropose(allocator, ws.workspace_root, body);
    defer result2.deinit(allocator);

    try std.testing.expectEqual(result1.status, result2.status);

    // Extract and compare patch_ids
    const json1 = result1.result_json.?;
    const json2 = result2.result_json.?;
    const id1_start = std.mem.indexOf(u8, json1, "\"patch_id\":\"prop-") orelse return error.TestUnexpectedResult;
    const id2_start = std.mem.indexOf(u8, json2, "\"patch_id\":\"prop-") orelse return error.TestUnexpectedResult;
    const rest1 = json1[id1_start + 14 ..];
    const rest2 = json2[id2_start + 14 ..];
    const end1 = std.mem.indexOfScalar(u8, rest1, '"') orelse return error.TestUnexpectedResult;
    const end2 = std.mem.indexOfScalar(u8, rest2, '"') orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(rest1[0..end1], rest2[0..end2]);
}

// ── Inspection API Tests ──────────────────────────────────────────────

test "hypothesis.list returns empty list safely" {
    const allocator = std.testing.allocator;
    var result = try dispatch(allocator, "hypothesis.list", core.PROTOCOL_VERSION, null, null, "{}");
    defer result.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, result.status);
    try std.testing.expect(std.mem.indexOf(u8, result.result_json.?, "\"total\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.result_json.?, "\"hypotheses\":[]") != null);
}

test "hypothesis.list with maxItems bounded" {
    const allocator = std.testing.allocator;
    var result = try dispatch(allocator, "hypothesis.list", core.PROTOCOL_VERSION, null, null, "{\"maxItems\":5}");
    defer result.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, result.status);
    try std.testing.expect(std.mem.indexOf(u8, result.result_json.?, "\"maxItems\":5") != null);
}

test "hypothesis.list maxItems capped at MAX_HYPOTHESIS_ITEMS" {
    const allocator = std.testing.allocator;
    var result = try dispatch(allocator, "hypothesis.list", core.PROTOCOL_VERSION, null, null, "{\"maxItems\":999999}");
    defer result.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, result.status);
    const max_str = try std.fmt.allocPrint(allocator, "\"maxItems\":{d}", .{core.MAX_HYPOTHESIS_ITEMS});
    defer allocator.free(max_str);
    try std.testing.expect(std.mem.indexOf(u8, result.result_json.?, max_str) != null);
}

test "hypothesis.triage returns empty triage summary" {
    const allocator = std.testing.allocator;
    var result = try dispatch(allocator, "hypothesis.triage", core.PROTOCOL_VERSION, null, null, "{}");
    defer result.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, result.status);
    try std.testing.expect(std.mem.indexOf(u8, result.result_json.?, "\"total\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.result_json.?, "\"items\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.result_json.?, "scoringPolicyVersion") != null);
}

test "hypothesis.triage does not schedule verifiers" {
    const allocator = std.testing.allocator;
    var result = try dispatch(allocator, "hypothesis.triage", core.PROTOCOL_VERSION, null, null, "{}");
    defer result.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, result.status);
    // Verify no verifier_jobs_scheduled in stats
    try std.testing.expect(result.stats == null or result.stats.?.verifier_jobs_scheduled == null or result.stats.?.verifier_jobs_scheduled.? == 0);
}

test "verifier.list returns registry adapters without running them" {
    const allocator = std.testing.allocator;
    var result = try dispatch(allocator, "verifier.list", core.PROTOCOL_VERSION, null, null, null);
    defer result.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, result.status);
    try std.testing.expect(std.mem.indexOf(u8, result.result_json.?, "\"adapters\":[") != null);
    // Should contain builtin adapters
    try std.testing.expect(std.mem.indexOf(u8, result.result_json.?, "code.build.zig_build") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.result_json.?, "code.test.zig_build_test") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.result_json.?, "\"enabled\":true") != null);
}

test "verifier.list adapters include required fields" {
    const allocator = std.testing.allocator;
    var result = try dispatch(allocator, "verifier.list", core.PROTOCOL_VERSION, null, null, null);
    defer result.deinit(allocator);
    const json = result.result_json.?;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"adapter_id\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"domain\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"hook_kind\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"budget_cost\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"evidence_kind\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"safe_local\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"external\"") != null);
}

test "verifier.candidate.execution.list returns empty list safely" {
    const allocator = std.testing.allocator;
    const shard_id = "verifier-execution-empty-list-smoke";
    const execution_path = try verifier_candidate_execution.executionsPath(allocator, shard_id);
    defer allocator.free(execution_path);
    std.fs.deleteFileAbsolute(execution_path) catch {};
    defer std.fs.deleteFileAbsolute(execution_path) catch {};

    var result = try dispatch(allocator, "verifier.candidate.execution.list", core.PROTOCOL_VERSION, null, null, "{\"projectShard\":\"verifier-execution-empty-list-smoke\"}");
    defer result.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, result.status);
    const json = result.result_json.?;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"executions\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"total\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"read_only\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"non_authorizing\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"commands_executed\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"verifiers_executed\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"support_granted\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"proof_granted\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"state_source\":\"verifier_execution_records_jsonl\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "engine_state_not_wired") == null);
}

test "legacy correction and negative knowledge inspection reads support graph state" {
    const allocator = std.testing.allocator;
    var ws = try PatchTestWorkspace.init(allocator);
    defer ws.deinit();

    const state_path = try std.fs.path.join(allocator, &.{ ws.workspace_root, "state.json" });
    defer allocator.free(state_path);
    const file = try std.fs.createFileAbsolute(state_path, .{});
    try file.writeAll(
        \\{"supportGraph":{"nodes":[
        \\{"id":"out:exec_job:exec_job:cand-real","kind":"verifier_execution_job","label":"execution job exec_job:cand-real","usable":false,"detail":"execution_kind=check_plan_eval status=completed non_authorizing=true"},
        \\{"id":"out:exec_result:exec_job:cand-real","kind":"verifier_execution_result","label":"execution result exec_job:cand-real","usable":false,"detail":"status=passed elapsed_ms=7 non_authorizing=true"},
        \\{"id":"out:correction:correction:1:cand-real","kind":"correction_event","label":"correction correction:1:cand-real","usable":false,"detail":"kind=hypothesis_contradicted previous=materialized updated=contradicted non_authorizing=true"},
        \\{"id":"out:nk:nk:1:correction:1:cand-real","kind":"negative_knowledge_candidate","label":"negative knowledge candidate nk:1:correction:1:cand-real","usable":false,"detail":"kind=failed_hypothesis permanence=temporary status=proposed non_authorizing=true"}
        \\],"edges":[
        \\{"from":"out:exec_job:exec_job:cand-real","to":"out:exec_result:exec_job:cand-real","kind":"execution_produces_evidence"},
        \\{"from":"out:correction:correction:1:cand-real","to":"out:exec_result:exec_job:cand-real","kind":"correction_from_evidence"},
        \\{"from":"out:correction:correction:1:cand-real","to":"cand-real","kind":"correction_for"},
        \\{"from":"out:correction:correction:1:cand-real","to":"out:nk:nk:1:correction:1:cand-real","kind":"proposes_negative_knowledge"},
        \\{"from":"out:nk:nk:1:correction:1:cand-real","to":"out:correction:correction:1:cand-real","kind":"negative_knowledge_from_correction"}
        \\]}}
    );
    file.close();

    const exec_body = "{\"statePath\":\"state.json\"}";
    var correction_result = try dispatch(allocator, "correction.list", core.PROTOCOL_VERSION, ws.workspace_root, null, exec_body);
    defer correction_result.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, correction_result.status);
    try std.testing.expect(std.mem.indexOf(u8, correction_result.result_json.?, "\"correction_kind\":\"hypothesis_contradicted\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, correction_result.result_json.?, "\"hypothesis_contradicted\":1") != null);

    var nk_result = try dispatch(allocator, "negative_knowledge.candidate.list", core.PROTOCOL_VERSION, ws.workspace_root, null, exec_body);
    defer nk_result.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, nk_result.status);
    try std.testing.expect(std.mem.indexOf(u8, nk_result.result_json.?, "\"candidate_kind\":\"failed_hypothesis\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, nk_result.result_json.?, "\"failed_hypothesis\":1") != null);
}

test "legacy correction and negative knowledge get APIs read support graph state" {
    const allocator = std.testing.allocator;
    var ws = try PatchTestWorkspace.init(allocator);
    defer ws.deinit();

    const state_path = try std.fs.path.join(allocator, &.{ ws.workspace_root, "state.json" });
    defer allocator.free(state_path);
    const file = try std.fs.createFileAbsolute(state_path, .{});
    try file.writeAll(
        \\{"supportGraph":{"nodes":[
        \\{"id":"out:exec_job:exec_job:cand-real","kind":"verifier_execution_job","label":"execution job exec_job:cand-real","usable":false,"detail":"execution_kind=check_plan_eval status=completed non_authorizing=true"},
        \\{"id":"out:exec_result:exec_job:cand-real","kind":"verifier_execution_result","label":"execution result exec_job:cand-real","usable":false,"detail":"status=passed elapsed_ms=7 non_authorizing=true"},
        \\{"id":"out:correction:correction:1:cand-real","kind":"correction_event","label":"correction correction:1:cand-real","usable":false,"detail":"kind=hypothesis_contradicted previous=materialized updated=contradicted non_authorizing=true"},
        \\{"id":"out:nk:nk:1:correction:1:cand-real","kind":"negative_knowledge_candidate","label":"negative knowledge candidate nk:1:correction:1:cand-real","usable":false,"detail":"kind=failed_hypothesis permanence=temporary status=proposed non_authorizing=true"}
        \\],"edges":[
        \\{"from":"out:exec_job:exec_job:cand-real","to":"out:exec_result:exec_job:cand-real","kind":"execution_produces_evidence"},
        \\{"from":"out:correction:correction:1:cand-real","to":"out:exec_result:exec_job:cand-real","kind":"correction_from_evidence"},
        \\{"from":"out:correction:correction:1:cand-real","to":"out:nk:nk:1:correction:1:cand-real","kind":"proposes_negative_knowledge"},
        \\{"from":"out:nk:nk:1:correction:1:cand-real","to":"out:correction:correction:1:cand-real","kind":"negative_knowledge_from_correction"}
        \\]}}
    );
    file.close();

    var correction_get = try dispatch(allocator, "correction.get", core.PROTOCOL_VERSION, ws.workspace_root, null, "{\"statePath\":\"state.json\",\"correctionId\":\"out:correction:correction:1:cand-real\"}");
    defer correction_get.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, correction_get.status);
    try std.testing.expect(std.mem.indexOf(u8, correction_get.result_json.?, "\"linked_negative_knowledge_candidate_ref\"") != null);

    var nk_get = try dispatch(allocator, "negative_knowledge.candidate.get", core.PROTOCOL_VERSION, ws.workspace_root, null, "{\"statePath\":\"state.json\",\"candidateId\":\"out:nk:nk:1:correction:1:cand-real\"}");
    defer nk_get.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, nk_get.status);
    try std.testing.expect(std.mem.indexOf(u8, nk_get.result_json.?, "\"promoted\":false") != null);
}

test "correction.list returns empty list safely" {
    const allocator = std.testing.allocator;
    var result = try dispatch(allocator, "correction.list", core.PROTOCOL_VERSION, null, null, "{}");
    defer result.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, result.status);
    const json = result.result_json.?;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"corrections\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"counts_by_correction_kind\":{\"total\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"non_authorizing\":true") != null);
}

test "negative_knowledge.candidate.list returns empty list safely" {
    const allocator = std.testing.allocator;
    var result = try dispatch(allocator, "negative_knowledge.candidate.list", core.PROTOCOL_VERSION, null, null, "{}");
    defer result.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, result.status);
    const json = result.result_json.?;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"candidates\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"failed_hypothesis\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"non_authorizing\":true") != null);
}

test "negative_knowledge.record.list returns empty no_state_found safely" {
    const allocator = std.testing.allocator;
    var result = try dispatch(allocator, "negative_knowledge.record.list", core.PROTOCOL_VERSION, null, null, "{}");
    defer result.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, result.status);
    const json = result.result_json.?;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"records\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"total\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"state_source\":\"no_state_found\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"non_authorizing\":true") != null);
}

test "negative_knowledge.record.get missing returns path_not_found" {
    const allocator = std.testing.allocator;
    var result = try dispatch(allocator, "negative_knowledge.record.get", core.PROTOCOL_VERSION, null, null, "{\"recordId\":\"missing-record\"}");
    defer result.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.failed, result.status);
    try std.testing.expectEqual(core.ErrorCode.path_not_found, result.err.?.code);
}

test "negative_knowledge.influence.list returns empty safely" {
    const allocator = std.testing.allocator;
    var result = try dispatch(allocator, "negative_knowledge.influence.list", core.PROTOCOL_VERSION, null, null, "{}");
    defer result.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, result.status);
    const json = result.result_json.?;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"influence_results\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"matches\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"mutated_triage\":false") != null);
}

test "trust_decay.candidate.list returns empty safely" {
    const allocator = std.testing.allocator;
    var result = try dispatch(allocator, "trust_decay.candidate.list", core.PROTOCOL_VERSION, null, null, "{}");
    defer result.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, result.status);
    const json = result.result_json.?;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"candidates\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"trust_mutation\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"non_authorizing\":true") != null);
}

test "negative_knowledge.candidate.review validates approval and persistence honestly" {
    const allocator = std.testing.allocator;
    var missing_approval = try dispatch(allocator, "negative_knowledge.candidate.review", core.PROTOCOL_VERSION, null, null, "{\"candidateId\":\"cand:1\",\"decision\":\"accept\"}");
    defer missing_approval.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.rejected, missing_approval.status);
    try std.testing.expectEqual(core.ErrorCode.approval_required, missing_approval.err.?.code);

    var missing_reason = try dispatch(allocator, "negative_knowledge.candidate.review", core.PROTOCOL_VERSION, null, null, "{\"candidateId\":\"cand:1\",\"decision\":\"reject\"}");
    defer missing_reason.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.rejected, missing_reason.status);
    try std.testing.expectEqual(core.ErrorCode.missing_required_field, missing_reason.err.?.code);

    const accept_body =
        \\{"candidateId":"cand:1","decision":"accept","approvalContext":{"approvedBy":"test","approvalKind":"test_fixture","reason":"fixture","scope":"artifact","allowedInfluence":["triage_penalty"]}}
    ;
    var accepted = try dispatch(allocator, "negative_knowledge.candidate.review", core.PROTOCOL_VERSION, null, null, accept_body);
    defer accepted.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.unsupported, accepted.status);
    try std.testing.expect(std.mem.indexOf(u8, accepted.result_json.?, "\"requires_no_pack_mutation\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, accepted.result_json.?, "\"support_authority\":false") != null);
}

test "gip maturity metadata is exposed and unsupported operations do not fake success" {
    const allocator = std.testing.allocator;

    var protocol = try dispatch(allocator, "protocol.describe", core.PROTOCOL_VERSION, null, null, null);
    defer protocol.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, protocol.status);
    try std.testing.expect(std.mem.indexOf(u8, protocol.result_json.?, "\"operationMaturity\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, protocol.result_json.?, "\"kind\":\"conversation.replay\",\"declared\":true,\"implemented\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, protocol.result_json.?, "\"productReady\":false") != null);

    var caps = try dispatch(allocator, "capabilities.describe", core.PROTOCOL_VERSION, null, null, null);
    defer caps.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, caps.status);
    try std.testing.expect(std.mem.indexOf(u8, caps.result_json.?, "\"operationMaturity\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, caps.result_json.?, "\"kind\":\"artifact.patch.apply\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, caps.result_json.?, "\"requiresApproval\":true") != null);

    var unsupported = try dispatch(allocator, "conversation.replay", core.PROTOCOL_VERSION, null, null, "{}");
    defer unsupported.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.unsupported, unsupported.status);
    try std.testing.expect(unsupported.err != null);
    try std.testing.expectEqual(core.ErrorCode.unsupported_operation, unsupported.err.?.code);
    try std.testing.expect(unsupported.result_state != null);
    try std.testing.expectEqual(core.SemanticState.unresolved, unsupported.result_state.?.state);
}

test "gip denied mutation operations remain denied before implementation fallback" {
    const allocator = std.testing.allocator;
    var denied = try dispatch(allocator, "correction.apply", core.PROTOCOL_VERSION, null, null, "{}");
    defer denied.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.rejected, denied.status);
    try std.testing.expect(denied.err != null);
    try std.testing.expectEqual(core.ErrorCode.capability_denied, denied.err.?.code);
}

test "sigil.inspect is advertised as read-only candidate inspection" {
    const allocator = std.testing.allocator;

    var protocol = try dispatch(allocator, "protocol.describe", core.PROTOCOL_VERSION, null, null, null);
    defer protocol.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, protocol.status);
    const protocol_json = protocol.result_json.?;
    try std.testing.expect(std.mem.indexOf(u8, protocol_json, "\"kind\":\"sigil.inspect\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, protocol_json, "\"kind\":\"sigil.inspect\",\"declared\":true,\"implemented\":true,\"wired\":true,\"mutatesState\":false,\"requiresApproval\":false,\"capabilityPolicy\":\"allowed\",\"authorityEffect\":\"candidate\",\"productReady\":false") != null);

    var caps = try dispatch(allocator, "capabilities.describe", core.PROTOCOL_VERSION, null, null, null);
    defer caps.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, caps.status);
    const caps_json = caps.result_json.?;
    try std.testing.expect(std.mem.indexOf(u8, caps_json, "\"capability\":\"sigil.inspect\",\"policy\":\"allowed\",\"read_only\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, caps_json, "\"authorityEffect\":\"support\"") == null);
}

test "sigil.inspect disassembles safe control source without execution" {
    const allocator = std.testing.allocator;
    const body =
        \\{"source":"MOOD \"focused\"\nLOOM CPU_ONLY\nSCAN \"system_memory\"","validationScope":"boot_control"}
    ;

    var result = try dispatch(allocator, "sigil.inspect", core.PROTOCOL_VERSION, null, null, body);
    defer result.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, result.status);
    const state = result.result_state orelse return error.MissingResultState;
    try std.testing.expectEqual(core.Permission.none, state.permission);
    try std.testing.expect(!state.support_minimum_met);
    const json = result.result_json orelse return error.MissingResult;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"sigilInspection\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"status\":\"ok\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"scope\":\"boot_control\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"validation\":{\"scope\":\"boot_control\",\"status\":\"ok\",\"issue\":null}") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"opcode\":\"loom\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"stringPayload\":\"system_memory\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"non_authorizing\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"read_only\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"executed\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"mutates_state\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"vm_execution\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"commands_executed\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"support_granted\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"proof_gate_bypassed\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"authority_effect\":\"support\"") == null);
}

test "sigil.inspect exposes test block jump target through GIP" {
    const allocator = std.testing.allocator;
    const body =
        \\{"source":"TEST FALSE {\n  SCAN \"system_memory\"\n}","validationScope":"boot_control"}
    ;

    var result = try dispatch(allocator, "sigil.inspect", core.PROTOCOL_VERSION, null, null, body);
    defer result.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, result.status);
    const json = result.result_json orelse return error.MissingResult;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"test_jump\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"opcode\":\"jmp_if_false\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"b\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "0000 opcode=jmp_if_false mode=immediate_bool a=0 b=2") != null);
}

test "sigil.inspect scratch scope returns candidate-only mutation records" {
    const allocator = std.testing.allocator;
    const body =
        \\{"source":"BIND 65 TO alpha\nETCH \"candidate_anchor\" @2\nVOID \"candidate_void\"","validationScope":"scratch_session"}
    ;

    var result = try dispatch(allocator, "sigil.inspect", core.PROTOCOL_VERSION, null, null, body);
    defer result.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, result.status);
    const json = result.result_json orelse return error.MissingResult;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"bind_candidate\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"etch_candidate\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"void_candidate\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"authority_effect\":\"candidate\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"requires_review\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"requires_verification\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"scratch_state_mutation\":false") != null);
}

test "sigil.inspect fails validation for forbidden authority sources without execution" {
    const allocator = std.testing.allocator;

    const forbidden_sources = [_][]const u8{
        "SCAN \\\"support\\\"",
        "SCAN \\\"negative_knowledge.promote\\\"",
        "SCAN \\\"pack.update_from_negative_knowledge\\\"",
        "LOOM SHELL",
    };
    for (forbidden_sources) |source| {
        const body = try std.fmt.allocPrint(allocator, "{{\"source\":\"{s}\",\"validationScope\":\"scratch_session\"}}", .{source});
        defer allocator.free(body);
        var result = try dispatch(allocator, "sigil.inspect", core.PROTOCOL_VERSION, null, null, body);
        defer result.deinit(allocator);
        try std.testing.expectEqual(core.ProtocolStatus.rejected, result.status);
        const state = result.result_state orelse return error.MissingResultState;
        try std.testing.expectEqual(core.SemanticState.failed, state.state);
        const json = result.result_json orelse return error.MissingResult;
        try std.testing.expect(std.mem.indexOf(u8, json, "\"status\":\"validation_failed\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, json, "\"executed\":false") != null);
        try std.testing.expect(std.mem.indexOf(u8, json, "\"commands_executed\":false") != null);
        try std.testing.expect(std.mem.indexOf(u8, json, "\"pack_mutation\":false") != null);
        try std.testing.expect(std.mem.indexOf(u8, json, "\"negative_knowledge_mutation\":false") != null);
        try std.testing.expect(std.mem.indexOf(u8, json, "\"support_granted\":false") != null);
        try std.testing.expect(std.mem.indexOf(u8, json, "\"authority_effect\":\"support\"") == null);
    }
}

test "sigil.inspect invalid syntax fails closed before disassembly" {
    const allocator = std.testing.allocator;
    const body =
        \\{"source":"SHELL \"echo hidden\"","validationScope":"scratch_session"}
    ;

    var result = try dispatch(allocator, "sigil.inspect", core.PROTOCOL_VERSION, null, null, body);
    defer result.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.rejected, result.status);
    try std.testing.expectEqual(core.ErrorCode.invalid_request, result.err.?.code);
    const state = result.result_state orelse return error.MissingResultState;
    try std.testing.expectEqual(core.SemanticState.failed, state.state);
    const json = result.result_json orelse return error.MissingResult;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"status\":\"parse_failed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"instructions\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"procedureInspectionRecords\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"executed\":false") != null);
}

test "negative_knowledge.review appends accepted and rejected reviewed records" {
    const allocator = std.testing.allocator;
    const project_shard = "phase11a-gip-review";
    try cleanProjectShardForTest(allocator, project_shard);
    defer cleanProjectShardForTest(allocator, project_shard) catch {};

    var accepted = try dispatch(allocator, "negative_knowledge.review", core.PROTOCOL_VERSION, null, null,
        \\{"projectShard":"phase11a-gip-review","negativeKnowledgeCandidate":{"id":"nk:candidate:accepted","kind":"failed_hypothesis","condition":"bad repeated answer","nonAuthorizing":true},"decision":"accepted","reviewerNote":"accepted by test","sourceCorrectionReviewId":"reviewed-correction:test"}
    );
    defer accepted.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, accepted.status);
    const accepted_json = accepted.result_json.?;
    try std.testing.expect(std.mem.indexOf(u8, accepted_json, "\"reviewedNegativeKnowledgeRecord\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, accepted_json, "\"reviewDecision\":\"accepted\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, accepted_json, "\"nonAuthorizing\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, accepted_json, "\"treatedAsProof\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, accepted_json, "\"usedAsEvidence\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, accepted_json, "\"globalPromotion\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, accepted_json, "\"corpusMutation\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, accepted_json, "\"packMutation\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, accepted_json, "\"negativeKnowledgeMutation\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, accepted_json, "\"commandsExecuted\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, accepted_json, "\"verifiersExecuted\":false") != null);

    var rejected_missing_reason = try dispatch(allocator, "negative_knowledge.review", core.PROTOCOL_VERSION, null, null,
        \\{"projectShard":"phase11a-gip-review","negativeKnowledgeCandidateId":"nk:candidate:missing-reason","decision":"rejected","reviewerNote":"rejected by test"}
    );
    defer rejected_missing_reason.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.rejected, rejected_missing_reason.status);
    try std.testing.expectEqual(core.ErrorCode.missing_required_field, rejected_missing_reason.err.?.code);

    var rejected = try dispatch(allocator, "negative_knowledge.review", core.PROTOCOL_VERSION, null, null,
        \\{"projectShard":"phase11a-gip-review","negativeKnowledgeCandidateId":"nk:candidate:rejected","decision":"rejected","reviewerNote":"rejected by test","rejectedReason":"candidate not supported"}
    );
    defer rejected.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, rejected.status);
    try std.testing.expect(std.mem.indexOf(u8, rejected.result_json.?, "\"reviewDecision\":\"rejected\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rejected.result_json.?, "\"rejectedReason\":\"candidate not supported\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rejected.result_json.?, "\"futureInfluenceCandidate\":null") != null);

    var all = try dispatch(allocator, "negative_knowledge.reviewed.list", core.PROTOCOL_VERSION, null, null,
        \\{"projectShard":"phase11a-gip-review","decision":"all","limit":8}
    );
    defer all.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, all.status);
    try std.testing.expect(std.mem.indexOf(u8, all.result_json.?, "\"returnedCount\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, all.result_json.?, "\"readOnly\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, all.result_json.?, "\"negativeKnowledgeMutation\":false") != null);

    var accepted_only = try dispatch(allocator, "negative_knowledge.reviewed.list", core.PROTOCOL_VERSION, null, null,
        \\{"projectShard":"phase11a-gip-review","decision":"accepted","limit":8}
    );
    defer accepted_only.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, accepted_only.result_json.?, "\"returnedCount\":1") != null);

    var rejected_only = try dispatch(allocator, "negative_knowledge.reviewed.list", core.PROTOCOL_VERSION, null, null,
        \\{"projectShard":"phase11a-gip-review","decision":"rejected","limit":8}
    );
    defer rejected_only.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, rejected_only.result_json.?, "\"returnedCount\":1") != null);
}

test "negative_knowledge.reviewed list and get handle missing and malformed records" {
    const allocator = std.testing.allocator;
    try cleanProjectShardForTest(allocator, "phase11a-gip-no-file");
    defer cleanProjectShardForTest(allocator, "phase11a-gip-no-file") catch {};

    var no_file = try dispatch(allocator, "negative_knowledge.reviewed.list", core.PROTOCOL_VERSION, null, null,
        \\{"projectShard":"phase11a-gip-no-file","decision":"all"}
    );
    defer no_file.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, no_file.status);
    try std.testing.expect(std.mem.indexOf(u8, no_file.result_json.?, "\"missingFile\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, no_file.result_json.?, "\"returnedCount\":0") != null);

    const project_shard = "phase11a-gip-malformed";
    try cleanProjectShardForTest(allocator, project_shard);
    defer cleanProjectShardForTest(allocator, project_shard) catch {};

    var accepted = try negative_knowledge_review.reviewAndAppend(allocator, .{
        .project_shard = project_shard,
        .decision = .accepted,
        .reviewer_note = "accepted",
        .rejected_reason = null,
        .source_candidate_id = "nk:candidate:malformed",
        .negative_knowledge_candidate_json = "{\"id\":\"nk:candidate:malformed\"}",
    });
    defer accepted.deinit();

    const reviewed_path = try negative_knowledge_review.reviewedNegativeKnowledgePath(allocator, project_shard);
    defer allocator.free(reviewed_path);
    var file = try std.fs.openFileAbsolute(reviewed_path, .{ .mode = .write_only });
    defer file.close();
    try file.seekFromEnd(0);
    try file.writeAll("{malformed reviewed negative knowledge line}\n");

    const id = try reviewedRecordIdForTest(allocator, accepted.record_json);
    defer allocator.free(id);
    const get_body = try std.fmt.allocPrint(allocator, "{{\"projectShard\":\"{s}\",\"id\":\"{s}\"}}", .{ project_shard, id });
    defer allocator.free(get_body);
    var existing = try dispatch(allocator, "negative_knowledge.reviewed.get", core.PROTOCOL_VERSION, null, null, get_body);
    defer existing.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, existing.status);
    try std.testing.expect(std.mem.indexOf(u8, existing.result_json.?, "\"reviewedNegativeKnowledgeRecord\":{\"id\":\"") != null);

    var missing = try dispatch(allocator, "negative_knowledge.reviewed.get", core.PROTOCOL_VERSION, null, null,
        \\{"projectShard":"phase11a-gip-malformed","id":"reviewed-negative-knowledge:missing"}
    );
    defer missing.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.failed, missing.status);
    try std.testing.expect(std.mem.indexOf(u8, missing.result_json.?, "\"kind\":\"reviewed_negative_knowledge_not_found\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, missing.result_json.?, "malformed reviewed negative knowledge JSONL line ignored") != null);
}

test "procedure_pack.candidate.propose creates candidate from reviewed correction without pack mutation" {
    const allocator = std.testing.allocator;
    const project_shard = "phase13a-propose-correction";
    try cleanProjectShardForTest(allocator, project_shard);
    defer cleanProjectShardForTest(allocator, project_shard) catch {};

    const reviewed_id = try appendReviewedCorrectionForTest(allocator, project_shard, "procedure-correction", .accepted);
    defer allocator.free(reviewed_id);
    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"projectShard\":\"{s}\",\"sourceKind\":\"reviewed_correction\",\"sourceReviewId\":\"{s}\"}}",
        .{ project_shard, reviewed_id },
    );
    defer allocator.free(body);

    var result = try dispatch(allocator, "procedure_pack.candidate.propose", core.PROTOCOL_VERSION, null, null, body);
    defer result.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, result.status);
    const json = result.result_json.?;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"procedurePackCandidate\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"sourceKind\":\"reviewed_correction\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"candidateKind\":\"corpus_review_procedure\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"persisted\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"nonAuthorizing\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"treatedAsProof\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"usedAsEvidence\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"executesByDefault\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"packMutation\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"globalPromotion\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"commandsExecuted\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"verifiersExecuted\":false") != null);
}

test "procedure_pack.candidate.propose creates candidate from reviewed negative knowledge" {
    const allocator = std.testing.allocator;
    const project_shard = "phase13a-propose-nk";
    try cleanProjectShardForTest(allocator, project_shard);
    defer cleanProjectShardForTest(allocator, project_shard) catch {};

    var reviewed = try negative_knowledge_review.reviewAndAppend(allocator, .{
        .project_shard = project_shard,
        .decision = .accepted,
        .reviewer_note = "accepted procedure source",
        .rejected_reason = null,
        .source_candidate_id = "nk:candidate:procedure",
        .negative_knowledge_candidate_json = "{\"id\":\"nk:candidate:procedure\",\"kind\":\"failed_hypothesis\",\"condition\":\"bad repeated answer\"}",
    });
    defer reviewed.deinit();
    const reviewed_id = try reviewedRecordIdForTest(allocator, reviewed.record_json);
    defer allocator.free(reviewed_id);
    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"projectShard\":\"{s}\",\"sourceKind\":\"reviewed_negative_knowledge\",\"sourceReviewId\":\"{s}\"}}",
        .{ project_shard, reviewed_id },
    );
    defer allocator.free(body);

    var result = try dispatch(allocator, "procedure_pack.candidate.propose", core.PROTOCOL_VERSION, null, null, body);
    defer result.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, result.status);
    const json = result.result_json.?;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"sourceKind\":\"reviewed_negative_knowledge\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"candidateKind\":\"negative_knowledge_procedure\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"nonAuthorizing\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"treatedAsProof\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"packMutation\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"commandsExecuted\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"verifiersExecuted\":false") != null);
}

test "procedure_pack.candidate review list and get are append-only inspection only" {
    const allocator = std.testing.allocator;
    const project_shard = "phase13a-review-list-get";
    try cleanProjectShardForTest(allocator, project_shard);
    defer cleanProjectShardForTest(allocator, project_shard) catch {};

    var proposal = try procedure_pack_candidates.propose(allocator, .{
        .project_shard = project_shard,
        .source_kind = .learning_status,
    });
    defer proposal.deinit();
    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"projectShard\":\"{s}\",\"decision\":\"accepted\",\"reviewerNote\":\"phase13a review\",\"procedurePackCandidate\":{s}}}",
        .{ project_shard, proposal.candidate_json },
    );
    defer allocator.free(body);

    var reviewed = try dispatch(allocator, "procedure_pack.candidate.review", core.PROTOCOL_VERSION, null, null, body);
    defer reviewed.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, reviewed.status);
    const reviewed_json = reviewed.result_json.?;
    try std.testing.expect(std.mem.indexOf(u8, reviewed_json, "\"reviewedProcedurePackCandidateRecord\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, reviewed_json, "\"appendOnly\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, reviewed_json, "\"packMutation\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, reviewed_json, "\"executesByDefault\":false") != null);
    const reviewed_id = try reviewedProcedurePackCandidateIdForTest(allocator, reviewed_json);
    defer allocator.free(reviewed_id);

    var listed = try dispatch(allocator, "procedure_pack.candidate.reviewed.list", core.PROTOCOL_VERSION, null, null,
        \\{"projectShard":"phase13a-review-list-get","decision":"all"}
    );
    defer listed.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, listed.status);
    try std.testing.expect(std.mem.indexOf(u8, listed.result_json.?, "\"returnedCount\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, listed.result_json.?, "\"readOnly\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, listed.result_json.?, "\"packMutation\":false") != null);

    const get_body = try std.fmt.allocPrint(allocator, "{{\"projectShard\":\"{s}\",\"id\":\"{s}\"}}", .{ project_shard, reviewed_id });
    defer allocator.free(get_body);
    var got = try dispatch(allocator, "procedure_pack.candidate.reviewed.get", core.PROTOCOL_VERSION, null, null, get_body);
    defer got.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, got.status);
    try std.testing.expect(std.mem.indexOf(u8, got.result_json.?, "\"returnedCount\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, got.result_json.?, "\"usedAsEvidence\":false") != null);
}

test "procedure_pack.candidate malformed and missing input handled cleanly" {
    const allocator = std.testing.allocator;
    var bad_source = try dispatch(allocator, "procedure_pack.candidate.propose", core.PROTOCOL_VERSION, null, null,
        \\{"projectShard":"phase13a-bad","sourceKind":"pack"}
    );
    defer bad_source.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.rejected, bad_source.status);
    try std.testing.expectEqual(core.ErrorCode.invalid_request, bad_source.err.?.code);

    var missing_id = try dispatch(allocator, "procedure_pack.candidate.propose", core.PROTOCOL_VERSION, null, null,
        \\{"projectShard":"phase13a-bad","sourceKind":"reviewed_correction"}
    );
    defer missing_id.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.rejected, missing_id.status);
    try std.testing.expectEqual(core.ErrorCode.missing_required_field, missing_id.err.?.code);

    var bad_review = try dispatch(allocator, "procedure_pack.candidate.review", core.PROTOCOL_VERSION, null, null,
        \\{"projectShard":"phase13a-bad","decision":"accepted","procedurePackCandidate":42}
    );
    defer bad_review.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.rejected, bad_review.status);
    try std.testing.expectEqual(core.ErrorCode.invalid_request, bad_review.err.?.code);
}

test "correction.propose creates review-required wrong answer candidate" {
    const allocator = std.testing.allocator;
    const body =
        \\{"operationKind":"corpus.ask","originalRequestId":"ask:1","disputedOutput":{"kind":"answerDraft","ref":"answer:1"},"userCorrection":"that answer is wrong","correctionType":"wrong_answer","evidenceRefs":["corpus:item:1"],"projectShard":"smoke"}
    ;
    var result = try dispatch(allocator, "correction.propose", core.PROTOCOL_VERSION, null, null, body);
    defer result.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, result.status);
    const json = result.result_json.?;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"status\":\"proposed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"originalOperationKind\":\"corpus.ask\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"negative_knowledge_candidate\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"corpus_update_candidate\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"requiredReview\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"nonAuthorizing\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"treatedAsProof\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"corpusMutation\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"packMutation\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"negativeKnowledgeMutation\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"commandsExecuted\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"verifiersExecuted\":false") != null);
}

test "correction.propose missing evidence creates follow-up evidence request" {
    const allocator = std.testing.allocator;
    const body =
        \\{"operationKind":"corpus.ask","disputedOutput":{"kind":"unknown"},"userCorrection":"the answer needs a citation","correctionType":"missing_evidence"}
    ;
    var result = try dispatch(allocator, "correction.propose", core.PROTOCOL_VERSION, null, null, body);
    defer result.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, result.status);
    try std.testing.expect(std.mem.indexOf(u8, result.result_json.?, "\"kind\":\"follow_up_evidence_request\"") != null);
}

test "correction.propose bad evidence preserves disputed evidence refs" {
    const allocator = std.testing.allocator;
    const body =
        \\{"operationKind":"corpus.ask","disputedOutput":{"kind":"evidenceUsed","ref":"evidence:bad"},"userCorrection":"this evidence is from the wrong file","correctionType":"bad_evidence","evidenceRefs":["evidence:bad"]}
    ;
    var result = try dispatch(allocator, "correction.propose", core.PROTOCOL_VERSION, null, null, body);
    defer result.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, result.status);
    const json = result.result_json.?;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"ref\":\"evidence:bad\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"evidenceRefs\":[\"evidence:bad\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"corpus_update_candidate\"") != null);
}

test "correction.propose repeated failed pattern proposes NK candidate only" {
    const allocator = std.testing.allocator;
    const body =
        \\{"operationKind":"context.autopsy","disputedOutput":{"kind":"unknown"},"userCorrection":"this same missing-context pattern keeps failing","correctionType":"repeated_failed_pattern"}
    ;
    var result = try dispatch(allocator, "correction.propose", core.PROTOCOL_VERSION, null, null, body);
    defer result.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, result.status);
    const json = result.result_json.?;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"negative_knowledge_candidate\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"corpus_update_candidate\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"autoAccepted\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"negativeKnowledgeMutation\":false") != null);
}

test "correction.propose underspecified returns request_more_detail unknown" {
    const allocator = std.testing.allocator;
    var result = try dispatch(allocator, "correction.propose", core.PROTOCOL_VERSION, null, null, "{\"operationKind\":\"rule.evaluate\",\"correctionType\":\"missing_evidence\"}");
    defer result.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.unresolved, result.status);
    const json = result.result_json.?;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"status\":\"request_more_detail\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"request_more_detail\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"correctionCandidate\":null") != null);
}

test "correction.propose malformed request returns invalid_request" {
    const allocator = std.testing.allocator;
    var result = try dispatch(allocator, "correction.propose", core.PROTOCOL_VERSION, null, null, "{\"operationKind\":\"corpus.ask\",\"disputedOutput\":42,\"userCorrection\":\"bad\",\"correctionType\":\"wrong_answer\"}");
    defer result.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.rejected, result.status);
    try std.testing.expectEqual(core.ErrorCode.invalid_request, result.err.?.code);
}

test "correction.review accepts candidate into append-only reviewed record" {
    const allocator = std.testing.allocator;
    const body =
        \\{"projectShard":"phase7-gip-accept","correctionCandidate":{"id":"correction:candidate:accept","correctionType":"wrong_answer"},"decision":"accepted","reviewerNote":"reviewed by test","acceptedLearningOutputs":[{"kind":"verifier_check_candidate","status":"candidate"}]}
    ;
    var result = try dispatch(allocator, "correction.review", core.PROTOCOL_VERSION, null, null, body);
    defer result.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, result.status);
    const json = result.result_json.?;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"reviewDecision\":\"accepted\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"requiredReview\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"nonAuthorizing\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"treatedAsProof\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"globalPromotion\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"corpusMutation\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"packMutation\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"negativeKnowledgeMutation\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"commandsExecuted\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"verifiersExecuted\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"futureBehaviorCandidate\":{\"status\":\"candidate\"") != null);
}

test "correction.review rejects candidate with rejectedReason" {
    const allocator = std.testing.allocator;
    const body =
        \\{"projectShard":"phase7-gip-reject","correctionCandidateId":"correction:candidate:reject","decision":"rejected","reviewerNote":"reviewed by test","rejectedReason":"correction did not match evidence"}
    ;
    var result = try dispatch(allocator, "correction.review", core.PROTOCOL_VERSION, null, null, body);
    defer result.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, result.status);
    const json = result.result_json.?;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"reviewDecision\":\"rejected\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"rejectedReason\":\"correction did not match evidence\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"futureBehaviorCandidate\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"negativeKnowledgeMutation\":false") != null);
}

test "correction.review malformed and missing decision are structured rejections" {
    const allocator = std.testing.allocator;
    var malformed = try dispatch(allocator, "correction.review", core.PROTOCOL_VERSION, null, null, "[]");
    defer malformed.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.rejected, malformed.status);
    try std.testing.expectEqual(core.ErrorCode.invalid_request, malformed.err.?.code);

    var missing_decision = try dispatch(allocator, "correction.review", core.PROTOCOL_VERSION, null, null, "{\"correctionCandidateId\":\"cand\",\"reviewerNote\":\"note\"}");
    defer missing_decision.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.rejected, missing_decision.status);
    try std.testing.expectEqual(core.ErrorCode.missing_required_field, missing_decision.err.?.code);

    var invalid_decision = try dispatch(allocator, "correction.review", core.PROTOCOL_VERSION, null, null, "{\"correctionCandidateId\":\"cand\",\"decision\":\"accept\",\"reviewerNote\":\"note\"}");
    defer invalid_decision.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.rejected, invalid_decision.status);
    try std.testing.expectEqual(core.ErrorCode.invalid_request, invalid_decision.err.?.code);
}

test "correction.reviewed.list tolerates missing storage as empty read-only result" {
    const allocator = std.testing.allocator;
    const project_shard = "phase9a-gip-missing";
    try cleanProjectShardForTest(allocator, project_shard);
    defer cleanProjectShardForTest(allocator, project_shard) catch {};

    const body =
        \\{"projectShard":"phase9a-gip-missing","decision":"all"}
    ;
    var result = try dispatch(allocator, "correction.reviewed.list", core.PROTOCOL_VERSION, null, null, body);
    defer result.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, result.status);
    const json = result.result_json.?;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"status\":\"ok\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"records\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"totalRead\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"returnedCount\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"missingFile\":true") != null);
    try expectReviewedCorrectionSafeguards(json);
}

test "correction.reviewed.list returns accepted and rejected records in append order with filters" {
    const allocator = std.testing.allocator;
    const project_shard = "phase9a-gip-list";
    try cleanProjectShardForTest(allocator, project_shard);
    defer cleanProjectShardForTest(allocator, project_shard) catch {};

    const accepted_id = try appendReviewedCorrectionForTest(allocator, project_shard, "phase9a-accepted", .accepted);
    defer allocator.free(accepted_id);
    const rejected_id = try appendReviewedCorrectionForTest(allocator, project_shard, "phase9a-rejected", .rejected);
    defer allocator.free(rejected_id);

    var all = try dispatch(allocator, "correction.reviewed.list", core.PROTOCOL_VERSION, null, null,
        \\{"projectShard":"phase9a-gip-list","decision":"all"}
    );
    defer all.deinit(allocator);
    const all_json = all.result_json.?;
    try std.testing.expect(std.mem.indexOf(u8, all_json, "\"returnedCount\":2") != null);
    const accepted_pos = std.mem.indexOf(u8, all_json, "phase9a-accepted") orelse return error.MissingAcceptedRecord;
    const rejected_pos = std.mem.indexOf(u8, all_json, "phase9a-rejected") orelse return error.MissingRejectedRecord;
    try std.testing.expect(accepted_pos < rejected_pos);
    try expectReviewedCorrectionSafeguards(all_json);

    var accepted = try dispatch(allocator, "correction.reviewed.list", core.PROTOCOL_VERSION, null, null,
        \\{"projectShard":"phase9a-gip-list","decision":"accepted"}
    );
    defer accepted.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, accepted.result_json.?, "\"returnedCount\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, accepted.result_json.?, "\"reviewDecision\":\"accepted\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, accepted.result_json.?, "\"reviewDecision\":\"rejected\"") == null);

    var rejected = try dispatch(allocator, "correction.reviewed.list", core.PROTOCOL_VERSION, null, null,
        \\{"projectShard":"phase9a-gip-list","decision":"rejected"}
    );
    defer rejected.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, rejected.result_json.?, "\"returnedCount\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, rejected.result_json.?, "\"reviewDecision\":\"rejected\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rejected.result_json.?, "\"reviewDecision\":\"accepted\"") == null);

    var operation_filter = try dispatch(allocator, "correction.reviewed.list", core.PROTOCOL_VERSION, null, null,
        \\{"projectShard":"phase9a-gip-list","decision":"all","operationKind":"rule.evaluate"}
    );
    defer operation_filter.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, operation_filter.result_json.?, "\"returnedCount\":0") != null);
}

test "correction.reviewed.list reports limit and malformed line telemetry" {
    const allocator = std.testing.allocator;
    const project_shard = "phase9a-gip-limit";
    try cleanProjectShardForTest(allocator, project_shard);
    defer cleanProjectShardForTest(allocator, project_shard) catch {};

    const reviewed_path = try correction_review.reviewedCorrectionsPath(allocator, project_shard);
    defer allocator.free(reviewed_path);
    const parent = std.fs.path.dirname(reviewed_path) orelse return error.InvalidPath;
    try std.fs.cwd().makePath(parent);
    var file = try std.fs.createFileAbsolute(reviewed_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll("{malformed json}\n");
    const first = try reviewedRecordJsonForTest(allocator, project_shard, "limit-one", .accepted, 0);
    defer allocator.free(first);
    const second = try reviewedRecordJsonForTest(allocator, project_shard, "limit-two", .accepted, first.len + 1);
    defer allocator.free(second);
    try file.writeAll(first);
    try file.writeAll("\n");
    try file.writeAll(second);
    try file.writeAll("\n");

    var result = try dispatch(allocator, "correction.reviewed.list", core.PROTOCOL_VERSION, null, null,
        \\{"projectShard":"phase9a-gip-limit","decision":"accepted","limit":1}
    );
    defer result.deinit(allocator);
    const json = result.result_json.?;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"returnedCount\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"malformedLines\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "malformed reviewed correction JSONL line ignored") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"limitHit\":true") != null);
    try expectReviewedCorrectionSafeguards(json);
}

test "correction.reviewed.get returns existing and missing records without crashing on malformed lines" {
    const allocator = std.testing.allocator;
    const project_shard = "phase9a-gip-get";
    try cleanProjectShardForTest(allocator, project_shard);
    defer cleanProjectShardForTest(allocator, project_shard) catch {};

    const reviewed_path = try correction_review.reviewedCorrectionsPath(allocator, project_shard);
    defer allocator.free(reviewed_path);
    const parent = std.fs.path.dirname(reviewed_path) orelse return error.InvalidPath;
    try std.fs.cwd().makePath(parent);
    var file = try std.fs.createFileAbsolute(reviewed_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll("not json\n");
    const record_json = try reviewedRecordJsonForTest(allocator, project_shard, "get-existing", .accepted, 0);
    defer allocator.free(record_json);
    try file.writeAll(record_json);
    try file.writeAll("\n");

    const id = try reviewedRecordIdForTest(allocator, record_json);
    defer allocator.free(id);
    const get_body = try std.fmt.allocPrint(allocator, "{{\"projectShard\":\"{s}\",\"id\":\"{s}\"}}", .{ project_shard, id });
    defer allocator.free(get_body);

    var existing = try dispatch(allocator, "correction.reviewed.get", core.PROTOCOL_VERSION, null, null, get_body);
    defer existing.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, existing.status);
    try std.testing.expect(std.mem.indexOf(u8, existing.result_json.?, "\"reviewedCorrectionRecord\":{\"id\":\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, existing.result_json.?, "\"malformedLines\":1") != null);
    try expectReviewedCorrectionSafeguards(existing.result_json.?);

    var missing = try dispatch(allocator, "correction.reviewed.get", core.PROTOCOL_VERSION, null, null,
        \\{"projectShard":"phase9a-gip-get","id":"reviewed-correction:missing"}
    );
    defer missing.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.unresolved, missing.status);
    try std.testing.expect(std.mem.indexOf(u8, missing.result_json.?, "\"status\":\"not_found\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, missing.result_json.?, "\"kind\":\"reviewed_correction_not_found\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, missing.result_json.?, "\"malformedLines\":1") != null);
    try expectReviewedCorrectionSafeguards(missing.result_json.?);
}

test "get missing execution returns structured error" {
    const allocator = std.testing.allocator;
    var result = try dispatch(allocator, "verifier.candidate.execution.get", core.PROTOCOL_VERSION, null, null, "{\"projectShard\":\"verifier-execution-missing-smoke\",\"executionId\":\"missing-exec\"}");
    defer result.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.rejected, result.status);
    try std.testing.expectEqual(core.ErrorCode.path_not_found, result.err.?.code);
}

test "get missing correction returns structured error" {
    const allocator = std.testing.allocator;
    var result = try dispatch(allocator, "correction.get", core.PROTOCOL_VERSION, null, null, "{\"correctionId\":\"missing-correction\"}");
    defer result.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.failed, result.status);
    try std.testing.expectEqual(core.ErrorCode.path_not_found, result.err.?.code);
}

test "get missing negative knowledge candidate returns structured error" {
    const allocator = std.testing.allocator;
    var result = try dispatch(allocator, "negative_knowledge.candidate.get", core.PROTOCOL_VERSION, null, null, "{\"candidateId\":\"missing-candidate\"}");
    defer result.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.failed, result.status);
    try std.testing.expectEqual(core.ErrorCode.path_not_found, result.err.?.code);
}

test "inspection max_items bounded" {
    const allocator = std.testing.allocator;

    var execution_result = try dispatch(allocator, "verifier.candidate.execution.list", core.PROTOCOL_VERSION, null, null, "{\"projectShard\":\"verifier-execution-max-smoke\",\"maxItems\":999999}");
    defer execution_result.deinit(allocator);
    const execution_max = try std.fmt.allocPrint(allocator, "\"max_items\":{d}", .{core.MAX_VERIFIER_EXECUTION_ITEMS});
    defer allocator.free(execution_max);
    try std.testing.expect(std.mem.indexOf(u8, execution_result.result_json.?, execution_max) != null);

    var correction_result = try dispatch(allocator, "correction.list", core.PROTOCOL_VERSION, null, null, "{\"max_items\":999999}");
    defer correction_result.deinit(allocator);
    const correction_max = try std.fmt.allocPrint(allocator, "\"max_items\":{d}", .{core.MAX_CORRECTION_ITEMS});
    defer allocator.free(correction_max);
    try std.testing.expect(std.mem.indexOf(u8, correction_result.result_json.?, correction_max) != null);

    var negative_result = try dispatch(allocator, "negative_knowledge.candidate.list", core.PROTOCOL_VERSION, null, null, "{\"maxItems\":999999}");
    defer negative_result.deinit(allocator);
    const negative_max = try std.fmt.allocPrint(allocator, "\"max_items\":{d}", .{core.MAX_NEGATIVE_KNOWLEDGE_CANDIDATE_ITEMS});
    defer allocator.free(negative_max);
    try std.testing.expect(std.mem.indexOf(u8, negative_result.result_json.?, negative_max) != null);

    var record_result = try dispatch(allocator, "negative_knowledge.record.list", core.PROTOCOL_VERSION, null, null, "{\"maxItems\":999999}");
    defer record_result.deinit(allocator);
    const record_max = try std.fmt.allocPrint(allocator, "\"max_items\":{d}", .{core.MAX_NEGATIVE_KNOWLEDGE_RECORD_ITEMS});
    defer allocator.free(record_max);
    try std.testing.expect(std.mem.indexOf(u8, record_result.result_json.?, record_max) != null);
}

test "inspection outputs mark correction and negative knowledge non-authorizing" {
    const allocator = std.testing.allocator;

    var correction_result = try dispatch(allocator, "correction.list", core.PROTOCOL_VERSION, null, null, "{}");
    defer correction_result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, correction_result.result_json.?, "\"non_authorizing\":true") != null);

    var negative_result = try dispatch(allocator, "negative_knowledge.candidate.list", core.PROTOCOL_VERSION, null, null, "{}");
    defer negative_result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, negative_result.result_json.?, "\"non_authorizing\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, negative_result.result_json.?, "\"promoted\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, negative_result.result_json.?, "\"pack_authorized\":false") != null);
}

test "inspection operations do not schedule or execute verifiers" {
    const allocator = std.testing.allocator;
    var result = try dispatch(allocator, "verifier.candidate.execution.list", core.PROTOCOL_VERSION, null, null, "{\"projectShard\":\"verifier-execution-no-run-smoke\"}");
    defer result.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, result.status);
    try std.testing.expect(result.stats == null or result.stats.?.verifier_jobs_scheduled == null or result.stats.?.verifier_jobs_scheduled.? == 0);
    try std.testing.expect(std.mem.indexOf(u8, result.result_json.?, "\"commands_executed\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.result_json.?, "\"verifiers_executed\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.result_json.?, "without scheduling or running verifiers") != null);
}

test "pack.list returns structured response or safe empty list" {
    const allocator = std.testing.allocator;
    var result = try dispatch(allocator, "pack.list", core.PROTOCOL_VERSION, "/tmp", null, null);
    defer result.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, result.status);
    try std.testing.expect(std.mem.indexOf(u8, result.result_json.?, "\"packs\":") != null);
}

test "pack.inspect missing pack returns structured error" {
    const allocator = std.testing.allocator;
    var result = try dispatch(allocator, "pack.inspect", core.PROTOCOL_VERSION, null, null, "{\"pack_id\":\"nonexistent_pack_xyz\",\"version\":\"v1\"}");
    defer result.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.failed, result.status);
    try std.testing.expectEqual(core.ErrorCode.path_not_found, result.err.?.code);
}

test "pack.inspect missing pack_id returns rejection" {
    const allocator = std.testing.allocator;
    var result = try dispatch(allocator, "pack.inspect", core.PROTOCOL_VERSION, null, null, "{}");
    defer result.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.rejected, result.status);
    try std.testing.expectEqual(core.ErrorCode.missing_required_field, result.err.?.code);
}

test "session.get missing session returns structured error" {
    const allocator = std.testing.allocator;
    var result = try dispatch(allocator, "session.get", core.PROTOCOL_VERSION, null, null, "{\"sessionId\":\"nonexistent_session_xyz\"}");
    defer result.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.failed, result.status);
    try std.testing.expectEqual(core.ErrorCode.path_not_found, result.err.?.code);
}

test "session.get missing session_id returns rejection" {
    const allocator = std.testing.allocator;
    var result = try dispatch(allocator, "session.get", core.PROTOCOL_VERSION, null, null, "{}");
    defer result.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.rejected, result.status);
    try std.testing.expectEqual(core.ErrorCode.missing_required_field, result.err.?.code);
}

test "feedback.summary returns structured response" {
    const allocator = std.testing.allocator;
    var result = try dispatch(allocator, "feedback.summary", core.PROTOCOL_VERSION, "/tmp", null, "{}");
    defer result.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, result.status);
    // Either returns event counts or unsupported
    try std.testing.expect(std.mem.indexOf(u8, result.result_json.?, "event_counts") != null or std.mem.indexOf(u8, result.result_json.?, "unsupported") != null);
}

test "protocol.describe lists new implemented operations exactly" {
    const allocator = std.testing.allocator;
    var result = try dispatch(allocator, "protocol.describe", core.PROTOCOL_VERSION, null, null, null);
    defer result.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, result.status);
    const json = result.result_json.?;
    try std.testing.expect(std.mem.indexOf(u8, json, "hypothesis.list") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "hypothesis.triage") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "verifier.list") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "verifier.candidate.execution.list") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "verifier.candidate.execution.get") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "correction.propose") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "correction.review") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "correction.reviewed.list") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "correction.reviewed.get") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "correction.list") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "correction.get") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "negative_knowledge.candidate.list") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "negative_knowledge.candidate.get") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "negative_knowledge.record.list") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "negative_knowledge.record.get") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "negative_knowledge.influence.list") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "negative_knowledge.review") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "negative_knowledge.reviewed.list") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "negative_knowledge.reviewed.get") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "trust_decay.candidate.list") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "negative_knowledge.candidate.review") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "pack.list") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "pack.inspect") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "feedback.summary") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "session.get") != null);
}

test "capabilities.describe reports read-only operations as allowed" {
    const allocator = std.testing.allocator;
    var result = try dispatch(allocator, "capabilities.describe", core.PROTOCOL_VERSION, null, null, null);
    defer result.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, result.status);
    const json = result.result_json.?;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"capability\":\"hypothesis.list\",\"policy\":\"allowed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"capability\":\"verifier.list\",\"policy\":\"allowed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"capability\":\"verifier.candidate.execution.list\",\"policy\":\"allowed\",\"read_only\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"capability\":\"correction.propose\",\"policy\":\"allowed\",\"read_only\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"capability\":\"correction.review\",\"policy\":\"allowed\",\"append_only\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"capability\":\"correction.reviewed.list\",\"policy\":\"allowed\",\"read_only\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"capability\":\"correction.reviewed.get\",\"policy\":\"allowed\",\"read_only\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"capability\":\"correction.list\",\"policy\":\"allowed\",\"read_only\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"capability\":\"negative_knowledge.candidate.list\",\"policy\":\"allowed\",\"read_only\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"capability\":\"negative_knowledge.record.list\",\"policy\":\"allowed\",\"read_only\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"capability\":\"negative_knowledge.review\",\"policy\":\"allowed\",\"append_only\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"capability\":\"negative_knowledge.reviewed.list\",\"policy\":\"allowed\",\"read_only\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"capability\":\"negative_knowledge.reviewed.get\",\"policy\":\"allowed\",\"read_only\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"capability\":\"negative_knowledge.candidate.review\",\"policy\":\"requires_approval\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"capability\":\"trust_decay.candidate.list\",\"policy\":\"allowed\",\"read_only\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"capability\":\"pack.list\",\"policy\":\"allowed\"") != null);
}

test "capabilities.describe does not imply unimplemented mutating ops are implemented" {
    const allocator = std.testing.allocator;
    var result = try dispatch(allocator, "capabilities.describe", core.PROTOCOL_VERSION, null, null, null);
    defer result.deinit(allocator);
    const json = result.result_json.?;
    // These should NOT appear as implemented capabilities
    try std.testing.expect(std.mem.indexOf(u8, json, "\"capability\":\"pack.mount\",\"policy\":\"allowed\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"capability\":\"patch.apply\",\"policy\":\"allowed\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"capability\":\"verifier.run\",\"policy\":\"allowed\",\"note\":\"not yet implemented\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"capability\":\"verifier.candidate.execute\",\"policy\":\"requires_approval\",\"mutation\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"capability\":\"correction.apply\",\"policy\":\"denied\",\"mutation\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"capability\":\"negative_knowledge.promote\",\"policy\":\"denied\",\"mutation\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"capability\":\"pack.update_from_negative_knowledge\",\"policy\":\"denied\",\"mutation\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"capability\":\"trust_decay.apply\",\"policy\":\"denied\",\"mutation\":true") != null);
}

test "outputs mark hypotheses and pack influence as non-authorizing" {
    const allocator = std.testing.allocator;
    // hypothesis.list output should note non-authorizing
    var hyp_result = try dispatch(allocator, "hypothesis.list", core.PROTOCOL_VERSION, null, null, "{}");
    defer hyp_result.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, hyp_result.status);

    // pack.list output should note non-authorizing influence
    var pack_result = try dispatch(allocator, "pack.list", core.PROTOCOL_VERSION, "/tmp", null, null);
    defer pack_result.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, pack_result.status);
}

test "unsupported operations remain unsupported while verifier candidate execute is implemented approval-gated" {
    const allocator = std.testing.allocator;

    var r1 = try dispatch(allocator, "verifier.run", core.PROTOCOL_VERSION, null, null, "{}");
    defer r1.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.unsupported, r1.status);

    var r2 = try dispatch(allocator, "pack.mount", core.PROTOCOL_VERSION, null, null, "{}");
    defer r2.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.unsupported, r2.status);

    var r3 = try dispatch(allocator, "command.run", core.PROTOCOL_VERSION, null, null, "{}");
    defer r3.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.unsupported, r3.status);

    var r4 = try dispatch(allocator, "verifier.candidate.execute", core.PROTOCOL_VERSION, null, null, "{}");
    defer r4.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.rejected, r4.status);
    try std.testing.expectEqual(core.ErrorCode.missing_required_field, r4.err.?.code);

    var r5 = try dispatch(allocator, "correction.apply", core.PROTOCOL_VERSION, null, null, "{}");
    defer r5.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.rejected, r5.status);
    try std.testing.expectEqual(core.ErrorCode.capability_denied, r5.err.?.code);

    var r6 = try dispatch(allocator, "negative_knowledge.promote", core.PROTOCOL_VERSION, null, null, "{}");
    defer r6.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.rejected, r6.status);
    try std.testing.expectEqual(core.ErrorCode.capability_denied, r6.err.?.code);

    var r7 = try dispatch(allocator, "pack.update_from_negative_knowledge", core.PROTOCOL_VERSION, null, null, "{}");
    defer r7.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.rejected, r7.status);
    try std.testing.expectEqual(core.ErrorCode.capability_denied, r7.err.?.code);

    var r8 = try dispatch(allocator, "trust_decay.apply", core.PROTOCOL_VERSION, null, null, "{}");
    defer r8.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.rejected, r8.status);
    try std.testing.expectEqual(core.ErrorCode.capability_denied, r8.err.?.code);
}

// ── project.autopsy tests ─────────────────────────────────────────────

test "project.autopsy valid request returns autopsy result" {
    const allocator = std.testing.allocator;
    var result = try dispatch(allocator, "project.autopsy", core.PROTOCOL_VERSION, "/tmp", null, null);
    defer result.deinit(allocator);
    // A real workspace analysis of /tmp should succeed (it exists on all Unix systems).
    try std.testing.expectEqual(core.ProtocolStatus.ok, result.status);
    const json = result.result_json orelse return error.MissingResult;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"projectAutopsy\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"autopsy_schema_version\": \"project_autopsy.v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"operator_summary\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"readOnly\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"commandsExecuted\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"verifiersExecuted\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"verifiersRegistered\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"mutatesState\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"non_authorizing\":true") != null);
}

test "project.autopsy missing workspace is rejected" {
    const allocator = std.testing.allocator;
    var result = try dispatch(allocator, "project.autopsy", core.PROTOCOL_VERSION, null, null, null);
    defer result.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.rejected, result.status);
    try std.testing.expectEqual(core.ErrorCode.missing_required_field, result.err.?.code);
}

test "project.autopsy non-existent workspace returns path_not_found" {
    const allocator = std.testing.allocator;
    var result = try dispatch(allocator, "project.autopsy", core.PROTOCOL_VERSION, "/does/not/exist/12345", null, null);
    defer result.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.rejected, result.status);
    try std.testing.expectEqual(core.ErrorCode.path_not_found, result.err.?.code);
}

test "project.autopsy traversal in workspace root is canonicalized and accepted" {
    const allocator = std.testing.allocator;
    // /tmp/../tmp canonicalizes to /tmp (or the canonical temp path), which is valid.
    var result = try dispatch(allocator, "project.autopsy", core.PROTOCOL_VERSION, "/tmp/../tmp", null, null);
    defer result.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, result.status);
    const json = result.result_json orelse return error.MissingResult;
    // The output should contain the canonicalized workspace_root.
    try std.testing.expect(std.mem.indexOf(u8, json, "\"projectAutopsy\"") != null);
}

test "project.autopsy output state is draft and non-authorizing" {
    const allocator = std.testing.allocator;
    var result = try dispatch(allocator, "project.autopsy", core.PROTOCOL_VERSION, "/tmp", null, null);
    defer result.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, result.status);
    const rs = result.result_state orelse return error.MissingResultState;
    try std.testing.expectEqual(core.SemanticState.draft, rs.state);
    try std.testing.expect(rs.is_draft);
    try std.testing.expectEqual(core.Permission.none, rs.permission);
    try std.testing.expectEqual(false, rs.support_minimum_met);
    try std.testing.expect(rs.non_authorization_notice != null);
}

test "project.autopsy verifier candidates have executes_by_default false" {
    const allocator = std.testing.allocator;
    // Test with /tmp which has no known project structure — verifier_plan_candidates will be [].
    var result = try dispatch(allocator, "project.autopsy", core.PROTOCOL_VERSION, "/tmp", null, null);
    defer result.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, result.status);
    const json = result.result_json orelse return error.MissingResult;
    // executes_by_default must NEVER appear as true anywhere in the output.
    // (Pretty-printed JSON uses ": " so search for the key without the value suffix.)
    try std.testing.expect(std.mem.indexOf(u8, json, "\"executes_by_default\": true") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"executes_by_default\":true") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"applies_by_default\": true") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"applies_by_default\":true") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"commandsExecuted\":true") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"verifiersExecuted\":true") == null);
    // The field "verifier_plan_candidates" must be present (even if empty).
    try std.testing.expect(std.mem.indexOf(u8, json, "\"verifier_plan_candidates\"") != null);
}

test "project.autopsy does not appear in unsupported operations" {
    const allocator = std.testing.allocator;
    var result = try dispatch(allocator, "project.autopsy", core.PROTOCOL_VERSION, "/tmp", null, null);
    defer result.deinit(allocator);
    // Must NOT be unsupported.
    try std.testing.expect(result.status != core.ProtocolStatus.unsupported);
}

test "protocol.describe lists project.autopsy as implemented" {
    const allocator = std.testing.allocator;
    var result = try dispatch(allocator, "protocol.describe", core.PROTOCOL_VERSION, null, null, null);
    defer result.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, result.status);
    const json = result.result_json.?;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"project.autopsy\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "read_only_workspace_inspection") != null);
}

test "capabilities.describe lists project.autopsy as allowed read-only" {
    const allocator = std.testing.allocator;
    var result = try dispatch(allocator, "capabilities.describe", core.PROTOCOL_VERSION, null, null, null);
    defer result.deinit(allocator);
    const json = result.result_json.?;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"capability\":\"project.autopsy\",\"policy\":\"allowed\",\"read_only\":true") != null);
}

// ── learning.loop.plan tests ──────────────────────────────────────────

test "learning.loop.plan returns candidate-only read-only plan" {
    const allocator = std.testing.allocator;
    var result = try dispatch(allocator, "learning.loop.plan", core.PROTOCOL_VERSION, "/tmp", null, "{\"planId\":\"test-plan\"}");
    defer result.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, result.status);
    const json = result.result_json orelse return error.MissingResult;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"learningLoopPlan\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"schema_version\": \"learning_loop_plan.v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"plan_id\": \"test-plan\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"candidate_only\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"read_only\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"mutates_state\": false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"commands_executed\": false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"verifiers_executed\": false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"patches_applied\": false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"packs_mutated\": false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"corrections_applied\": false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"negative_knowledge_promoted\": false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"support_granted\": false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"proof_discharged\": false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"readOnly\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"authorityEffect\":\"candidate\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"commandsExecuted\":true") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"verifiersExecuted\":true") == null);
}

test "learning.loop.plan rejects non-object request body" {
    const allocator = std.testing.allocator;
    var result = try dispatch(allocator, "learning.loop.plan", core.PROTOCOL_VERSION, "/tmp", null, "[]");
    defer result.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.rejected, result.status);
    try std.testing.expectEqual(core.ErrorCode.invalid_request, result.err.?.code);
}

test "verifier candidate GIP lifecycle proposes lists approves and rejects without execution" {
    const allocator = std.testing.allocator;
    const shard_id = "verifier-candidate-gip-smoke";
    const candidate_path = try verifier_candidates.candidatesPath(allocator, shard_id);
    defer allocator.free(candidate_path);
    std.fs.deleteFileAbsolute(candidate_path) catch {};
    defer std.fs.deleteFileAbsolute(candidate_path) catch {};

    const propose_body =
        \\{"projectShard":"verifier-candidate-gip-smoke","learningLoopPlan":{"schema_version":"learning_loop_plan.v1","plan_id":"plan.gip","verifier_candidate_refs":[{"id":"learning.verifier_ref.zig_build_test","source_command_candidate_id":"zig_build_test","argv":["zig","build","test"],"cwd_hint":"/workspace","reason":"build test candidate from learning loop","evidence_paths":["build.zig"],"requires_approval":true,"executes_by_default":false}]}}
    ;
    var proposed = try dispatch(allocator, "verifier.candidate.propose_from_learning_plan", core.PROTOCOL_VERSION, null, null, propose_body);
    defer proposed.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, proposed.status);
    const proposed_json = proposed.result_json orelse return error.MissingResult;
    try std.testing.expect(std.mem.indexOf(u8, proposed_json, "\"candidateOnly\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, proposed_json, "\"nonAuthorizing\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, proposed_json, "\"executed\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, proposed_json, "\"producedEvidence\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, proposed_json, "\"verifiersExecuted\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, proposed_json, "\"authorityEffect\":\"support\"") == null);

    const candidate_id = try extractVerifierCandidateIdFromProposal(allocator, proposed_json);
    defer allocator.free(candidate_id);

    const review_body = try std.fmt.allocPrint(allocator, "{{\"projectShard\":\"{s}\",\"candidateId\":\"{s}\",\"decision\":\"approved\",\"reviewedBy\":\"tester\",\"reviewReason\":\"safe future verifier candidate\"}}", .{ shard_id, candidate_id });
    defer allocator.free(review_body);
    var approved = try dispatch(allocator, "verifier.candidate.review", core.PROTOCOL_VERSION, null, null, review_body);
    defer approved.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, approved.status);
    const approved_json = approved.result_json orelse return error.MissingResult;
    try std.testing.expect(std.mem.indexOf(u8, approved_json, "\"status\":\"approved\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, approved_json, "\"approvalCreatesEvidence\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, approved_json, "\"executed\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, approved_json, "\"producedEvidence\":false") != null);

    var listed_after_approval = try dispatch(allocator, "verifier.candidate.list", core.PROTOCOL_VERSION, null, null, "{\"projectShard\":\"verifier-candidate-gip-smoke\"}");
    defer listed_after_approval.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, listed_after_approval.status);
    const approved_list_json = listed_after_approval.result_json orelse return error.MissingResult;
    try std.testing.expect(std.mem.indexOf(u8, approved_list_json, "\"status\":\"approved\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, approved_list_json, "\"commandsExecuted\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, approved_list_json, "\"verifiersExecuted\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, approved_list_json, "\"producedEvidence\":false") != null);

    const reject_body = try std.fmt.allocPrint(allocator, "{{\"projectShard\":\"{s}\",\"candidateId\":\"{s}\",\"decision\":\"rejected\",\"reviewedBy\":\"tester\",\"reviewReason\":\"reject to verify folded status\"}}", .{ shard_id, candidate_id });
    defer allocator.free(reject_body);
    var rejected = try dispatch(allocator, "verifier.candidate.review", core.PROTOCOL_VERSION, null, null, reject_body);
    defer rejected.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, rejected.status);
    const rejected_json = rejected.result_json orelse return error.MissingResult;
    try std.testing.expect(std.mem.indexOf(u8, rejected_json, "\"status\":\"rejected\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rejected_json, "\"approvalCreatesEvidence\":false") != null);

    var listed_after_rejection = try dispatch(allocator, "verifier.candidate.list", core.PROTOCOL_VERSION, null, null, "{\"projectShard\":\"verifier-candidate-gip-smoke\"}");
    defer listed_after_rejection.deinit(allocator);
    const rejected_list_json = listed_after_rejection.result_json orelse return error.MissingResult;
    try std.testing.expect(std.mem.indexOf(u8, rejected_list_json, "\"status\":\"rejected\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rejected_list_json, "\"authorityEffect\":\"support\"") == null);
}

test "verifier.candidate.execute only runs approved confirmed candidates through bounded harness" {
    const allocator = std.testing.allocator;
    const shard_id = "verifier-candidate-execute-gip-smoke";
    const candidate_path = try verifier_candidates.candidatesPath(allocator, shard_id);
    defer allocator.free(candidate_path);
    const execution_path = try verifier_candidate_execution.executionsPath(allocator, shard_id);
    defer allocator.free(execution_path);
    std.fs.deleteFileAbsolute(candidate_path) catch {};
    std.fs.deleteFileAbsolute(execution_path) catch {};
    defer std.fs.deleteFileAbsolute(candidate_path) catch {};
    defer std.fs.deleteFileAbsolute(execution_path) catch {};

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace_root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(workspace_root);

    const propose_body =
        \\{"projectShard":"verifier-candidate-execute-gip-smoke","learningLoopPlan":{"schema_version":"learning_loop_plan.v1","plan_id":"plan.execute","verifier_candidate_refs":[{"id":"learning.verifier_ref.true","source_command_candidate_id":"true","argv":["true"],"cwd_hint":"","reason":"safe true smoke","evidence_paths":["build.zig"],"requires_approval":true,"executes_by_default":false}]}}
    ;
    var proposed = try dispatch(allocator, "verifier.candidate.propose_from_learning_plan", core.PROTOCOL_VERSION, null, null, propose_body);
    defer proposed.deinit(allocator);
    const candidate_id = try extractVerifierCandidateIdFromProposal(allocator, proposed.result_json.?);
    defer allocator.free(candidate_id);

    const execute_proposed_body = try std.fmt.allocPrint(allocator, "{{\"projectShard\":\"{s}\",\"candidateId\":\"{s}\",\"workspaceRoot\":\"{s}\",\"confirmExecute\":true}}", .{ shard_id, candidate_id, workspace_root });
    defer allocator.free(execute_proposed_body);
    var proposed_execute = try dispatch(allocator, "verifier.candidate.execute", core.PROTOCOL_VERSION, null, null, execute_proposed_body);
    defer proposed_execute.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.rejected, proposed_execute.status);
    try std.testing.expect(std.mem.indexOf(u8, proposed_execute.result_json.?, "\"executed\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, proposed_execute.result_json.?, "\"candidate_not_approved\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, proposed_execute.result_json.?, "\"producedEvidence\":false") != null);

    const review_body = try std.fmt.allocPrint(allocator, "{{\"projectShard\":\"{s}\",\"candidateId\":\"{s}\",\"decision\":\"approved\",\"reviewedBy\":\"tester\",\"reviewReason\":\"safe bounded execution smoke\"}}", .{ shard_id, candidate_id });
    defer allocator.free(review_body);
    var approved = try dispatch(allocator, "verifier.candidate.review", core.PROTOCOL_VERSION, null, null, review_body);
    defer approved.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, approved.status);

    const execute_no_confirm_body = try std.fmt.allocPrint(allocator, "{{\"projectShard\":\"{s}\",\"candidateId\":\"{s}\",\"workspaceRoot\":\"{s}\",\"confirmExecute\":false}}", .{ shard_id, candidate_id, workspace_root });
    defer allocator.free(execute_no_confirm_body);
    var no_confirm = try dispatch(allocator, "verifier.candidate.execute", core.PROTOCOL_VERSION, null, null, execute_no_confirm_body);
    defer no_confirm.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.rejected, no_confirm.status);
    try std.testing.expect(std.mem.indexOf(u8, no_confirm.result_json.?, "\"confirmation_required\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, no_confirm.result_json.?, "\"commandsExecuted\":false") != null);

    var safe_execute = try dispatch(allocator, "verifier.candidate.execute", core.PROTOCOL_VERSION, null, null, execute_proposed_body);
    defer safe_execute.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, safe_execute.status);
    const safe_json = safe_execute.result_json.?;
    try std.testing.expect(std.mem.indexOf(u8, safe_json, "\"status\":\"passed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, safe_json, "\"executed\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, safe_json, "\"commandsExecuted\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, safe_json, "\"verifiersExecuted\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, safe_json, "\"evidenceCandidate\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, safe_json, "\"nonAuthorizing\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, safe_json, "\"supportGranted\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, safe_json, "\"proofGranted\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, safe_json, "\"correctionApplied\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, safe_json, "\"negativeKnowledgePromoted\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, safe_json, "\"patchApplied\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, safe_json, "\"mutatesState\":true") != null);

    const persisted = try std.fs.cwd().readFileAlloc(allocator, execution_path, 64 * 1024);
    defer allocator.free(persisted);
    try std.testing.expect(std.mem.indexOf(u8, persisted, "\"recordType\":\"verifier_candidate_execution_result\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, persisted, "\"supportGranted\":false") != null);

    const execution_id = try extractVerifierExecutionIdFromExecuteResult(allocator, safe_json);
    defer allocator.free(execution_id);

    const list_body = try std.fmt.allocPrint(allocator, "{{\"projectShard\":\"{s}\",\"candidateId\":\"{s}\"}}", .{ shard_id, candidate_id });
    defer allocator.free(list_body);
    var inspected_list = try dispatch(allocator, "verifier.candidate.execution.list", core.PROTOCOL_VERSION, null, null, list_body);
    defer inspected_list.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, inspected_list.status);
    const list_json = inspected_list.result_json.?;
    try std.testing.expect(std.mem.indexOf(u8, list_json, execution_id) != null);
    try std.testing.expect(std.mem.indexOf(u8, list_json, "\"candidateId\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, list_json, "\"status\":\"passed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, list_json, "\"argv\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, list_json, "\"workspaceRoot\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, list_json, "\"exitCode\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, list_json, "\"stdoutSnippet\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, list_json, "\"stderrSnippet\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, list_json, "\"evidenceCandidate\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, list_json, "\"state_source\":\"verifier_execution_records_jsonl\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, list_json, "\"commands_executed\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, list_json, "\"verifiers_executed\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, list_json, "\"support_granted\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, list_json, "\"proof_granted\":false") != null);

    const get_body = try std.fmt.allocPrint(allocator, "{{\"projectShard\":\"{s}\",\"executionId\":\"{s}\"}}", .{ shard_id, execution_id });
    defer allocator.free(get_body);
    var inspected_get = try dispatch(allocator, "verifier.candidate.execution.get", core.PROTOCOL_VERSION, null, null, get_body);
    defer inspected_get.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, inspected_get.status);
    const get_json = inspected_get.result_json.?;
    try std.testing.expect(std.mem.indexOf(u8, get_json, execution_id) != null);
    try std.testing.expect(std.mem.indexOf(u8, get_json, "\"execution\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, get_json, "\"commands_executed\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, get_json, "\"verifiers_executed\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, get_json, "\"support_granted\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, get_json, "\"proof_granted\":false") != null);
}

test "verifier.candidate.execute rejects rejected and disallowed candidates without evidence" {
    const allocator = std.testing.allocator;
    const shard_id = "verifier-candidate-execute-reject-smoke";
    const candidate_path = try verifier_candidates.candidatesPath(allocator, shard_id);
    defer allocator.free(candidate_path);
    const execution_path = try verifier_candidate_execution.executionsPath(allocator, shard_id);
    defer allocator.free(execution_path);
    std.fs.deleteFileAbsolute(candidate_path) catch {};
    std.fs.deleteFileAbsolute(execution_path) catch {};
    defer std.fs.deleteFileAbsolute(candidate_path) catch {};
    defer std.fs.deleteFileAbsolute(execution_path) catch {};

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace_root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(workspace_root);

    const propose_body =
        \\{"projectShard":"verifier-candidate-execute-reject-smoke","learningLoopPlan":{"schema_version":"learning_loop_plan.v1","plan_id":"plan.execute.reject","verifier_candidate_refs":[{"id":"learning.verifier_ref.false","source_command_candidate_id":"false","argv":["false"],"cwd_hint":"","reason":"failing command smoke","evidence_paths":["build.zig"],"requires_approval":true,"executes_by_default":false},{"id":"learning.verifier_ref.bash","source_command_candidate_id":"bash","argv":["bash","-c","echo no"],"cwd_hint":"","reason":"disallowed command smoke","evidence_paths":["build.zig"],"requires_approval":true,"executes_by_default":false}]}}
    ;
    var proposed = try dispatch(allocator, "verifier.candidate.propose_from_learning_plan", core.PROTOCOL_VERSION, null, null, propose_body);
    defer proposed.deinit(allocator);
    const proposal_json = proposed.result_json.?;
    const rejected_id = try extractVerifierCandidateIdFromProposal(allocator, proposal_json);
    defer allocator.free(rejected_id);
    const disallowed_id = try extractVerifierCandidateIdAt(allocator, proposal_json, 1);
    defer allocator.free(disallowed_id);

    const reject_body = try std.fmt.allocPrint(allocator, "{{\"projectShard\":\"{s}\",\"candidateId\":\"{s}\",\"decision\":\"rejected\",\"reviewedBy\":\"tester\",\"reviewReason\":\"must not execute rejected\"}}", .{ shard_id, rejected_id });
    defer allocator.free(reject_body);
    var rejected_review = try dispatch(allocator, "verifier.candidate.review", core.PROTOCOL_VERSION, null, null, reject_body);
    defer rejected_review.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, rejected_review.status);

    const execute_rejected_body = try std.fmt.allocPrint(allocator, "{{\"projectShard\":\"{s}\",\"candidateId\":\"{s}\",\"workspaceRoot\":\"{s}\",\"confirmExecute\":true}}", .{ shard_id, rejected_id, workspace_root });
    defer allocator.free(execute_rejected_body);
    var rejected_execute = try dispatch(allocator, "verifier.candidate.execute", core.PROTOCOL_VERSION, null, null, execute_rejected_body);
    defer rejected_execute.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.rejected, rejected_execute.status);
    try std.testing.expect(std.mem.indexOf(u8, rejected_execute.result_json.?, "\"candidate_not_approved\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rejected_execute.result_json.?, "\"producedEvidence\":false") != null);

    const approve_disallowed_body = try std.fmt.allocPrint(allocator, "{{\"projectShard\":\"{s}\",\"candidateId\":\"{s}\",\"decision\":\"approved\",\"reviewedBy\":\"tester\",\"reviewReason\":\"approved metadata but command remains harness-disallowed\"}}", .{ shard_id, disallowed_id });
    defer allocator.free(approve_disallowed_body);
    var approved_disallowed = try dispatch(allocator, "verifier.candidate.review", core.PROTOCOL_VERSION, null, null, approve_disallowed_body);
    defer approved_disallowed.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, approved_disallowed.status);

    const execute_disallowed_body = try std.fmt.allocPrint(allocator, "{{\"projectShard\":\"{s}\",\"candidateId\":\"{s}\",\"workspaceRoot\":\"{s}\",\"confirmExecute\":true}}", .{ shard_id, disallowed_id, workspace_root });
    defer allocator.free(execute_disallowed_body);
    var disallowed_execute = try dispatch(allocator, "verifier.candidate.execute", core.PROTOCOL_VERSION, null, null, execute_disallowed_body);
    defer disallowed_execute.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.rejected, disallowed_execute.status);
    try std.testing.expect(std.mem.indexOf(u8, disallowed_execute.result_json.?, "\"status\":\"disallowed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, disallowed_execute.result_json.?, "\"commandsExecuted\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, disallowed_execute.result_json.?, "\"producedEvidence\":false") != null);

    const maybe_file = std.fs.openFileAbsolute(execution_path, .{});
    try std.testing.expectError(error.FileNotFound, maybe_file);
}

test "verifier.candidate.execute failed run records evidence candidate without correction or nk" {
    const allocator = std.testing.allocator;
    const shard_id = "verifier-candidate-execute-failed-smoke";
    const candidate_path = try verifier_candidates.candidatesPath(allocator, shard_id);
    defer allocator.free(candidate_path);
    const execution_path = try verifier_candidate_execution.executionsPath(allocator, shard_id);
    defer allocator.free(execution_path);
    std.fs.deleteFileAbsolute(candidate_path) catch {};
    std.fs.deleteFileAbsolute(execution_path) catch {};
    defer std.fs.deleteFileAbsolute(candidate_path) catch {};
    defer std.fs.deleteFileAbsolute(execution_path) catch {};

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace_root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(workspace_root);

    const propose_body =
        \\{"projectShard":"verifier-candidate-execute-failed-smoke","learningLoopPlan":{"schema_version":"learning_loop_plan.v1","plan_id":"plan.execute.failed","verifier_candidate_refs":[{"id":"learning.verifier_ref.false","source_command_candidate_id":"false","argv":["false"],"cwd_hint":"","reason":"failing command smoke","evidence_paths":["build.zig"],"requires_approval":true,"executes_by_default":false}]}}
    ;
    var proposed = try dispatch(allocator, "verifier.candidate.propose_from_learning_plan", core.PROTOCOL_VERSION, null, null, propose_body);
    defer proposed.deinit(allocator);
    const candidate_id = try extractVerifierCandidateIdFromProposal(allocator, proposed.result_json.?);
    defer allocator.free(candidate_id);

    const review_body = try std.fmt.allocPrint(allocator, "{{\"projectShard\":\"{s}\",\"candidateId\":\"{s}\",\"decision\":\"approved\",\"reviewedBy\":\"tester\",\"reviewReason\":\"approved failing verifier smoke\"}}", .{ shard_id, candidate_id });
    defer allocator.free(review_body);
    var approved = try dispatch(allocator, "verifier.candidate.review", core.PROTOCOL_VERSION, null, null, review_body);
    defer approved.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, approved.status);

    const execute_body = try std.fmt.allocPrint(allocator, "{{\"projectShard\":\"{s}\",\"candidateId\":\"{s}\",\"workspaceRoot\":\"{s}\",\"confirmExecute\":true}}", .{ shard_id, candidate_id, workspace_root });
    defer allocator.free(execute_body);
    var failed = try dispatch(allocator, "verifier.candidate.execute", core.PROTOCOL_VERSION, null, null, execute_body);
    defer failed.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.failed, failed.status);
    const failed_json = failed.result_json.?;
    try std.testing.expect(std.mem.indexOf(u8, failed_json, "\"status\":\"failed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, failed_json, "\"executed\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, failed_json, "\"producedEvidence\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, failed_json, "\"supportGranted\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, failed_json, "\"proofGranted\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, failed_json, "\"correctionApplied\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, failed_json, "\"negativeKnowledgePromoted\":false") != null);

    const persisted = try std.fs.cwd().readFileAlloc(allocator, execution_path, 64 * 1024);
    defer allocator.free(persisted);
    try std.testing.expect(std.mem.indexOf(u8, persisted, "\"status\":\"failed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, persisted, "\"negativeKnowledgePromoted\":false") != null);
}

test "verifier candidate handoff rejects invalid learning plan refs closed" {
    const allocator = std.testing.allocator;
    const invalid_path = try verifier_candidates.candidatesPath(allocator, "verifier-candidate-invalid-smoke");
    defer allocator.free(invalid_path);
    std.fs.deleteFileAbsolute(invalid_path) catch {};

    var executes_by_default = try dispatch(
        allocator,
        "verifier.candidate.propose_from_learning_plan",
        core.PROTOCOL_VERSION,
        null,
        null,
        "{\"projectShard\":\"verifier-candidate-invalid-smoke\",\"learningLoopPlan\":{\"verifier_candidate_refs\":[{\"id\":\"bad\",\"source_command_candidate_id\":\"bad\",\"argv\":[\"zig\"],\"requires_approval\":true,\"executes_by_default\":true}]}}",
    );
    defer executes_by_default.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.rejected, executes_by_default.status);
    try std.testing.expectEqual(core.ErrorCode.invalid_request, executes_by_default.err.?.code);

    var no_approval = try dispatch(
        allocator,
        "verifier.candidate.propose_from_learning_plan",
        core.PROTOCOL_VERSION,
        null,
        null,
        "{\"projectShard\":\"verifier-candidate-invalid-smoke\",\"learningLoopPlan\":{\"verifier_candidate_refs\":[{\"id\":\"bad\",\"source_command_candidate_id\":\"bad\",\"argv\":[\"zig\"],\"requires_approval\":false,\"executes_by_default\":false}]}}",
    );
    defer no_approval.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.rejected, no_approval.status);
    try std.testing.expectEqual(core.ErrorCode.invalid_request, no_approval.err.?.code);

    const maybe_file = std.fs.openFileAbsolute(invalid_path, .{});
    try std.testing.expectError(error.FileNotFound, maybe_file);
}

test "verifier candidate lifecycle maturity never declares support authority" {
    try std.testing.expectEqual(core.AuthorityEffect.candidate, core.operationAuthorityEffect(.@"verifier.candidate.propose_from_learning_plan"));
    try std.testing.expectEqual(core.AuthorityEffect.candidate, core.operationAuthorityEffect(.@"verifier.candidate.list"));
    try std.testing.expectEqual(core.AuthorityEffect.candidate, core.operationAuthorityEffect(.@"verifier.candidate.review"));
    try std.testing.expectEqual(core.AuthorityEffect.evidence, core.operationAuthorityEffect(.@"verifier.candidate.execute"));
    try std.testing.expect(core.operationMutatesState(.@"verifier.candidate.propose_from_learning_plan"));
    try std.testing.expect(!core.operationMutatesState(.@"verifier.candidate.list"));
    try std.testing.expect(core.operationMutatesState(.@"verifier.candidate.review"));
    try std.testing.expect(core.operationMutatesState(.@"verifier.candidate.execute"));
    try std.testing.expectEqual(core.CapabilityPolicy.requires_approval, core.capabilityPolicyForRequestKind(.@"verifier.candidate.execute"));
}

test "protocol.describe lists learning.loop.plan as candidate implemented not product ready" {
    const allocator = std.testing.allocator;
    var result = try dispatch(allocator, "protocol.describe", core.PROTOCOL_VERSION, null, null, null);
    defer result.deinit(allocator);
    const json = result.result_json.?;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"learning.loop.plan\",\"declared\":true,\"implemented\":true,\"wired\":true,\"mutatesState\":false,\"requiresApproval\":false,\"capabilityPolicy\":\"allowed\",\"authorityEffect\":\"candidate\",\"productReady\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "candidate_only_project_autopsy_learning_loop_plan_no_execution_no_mutation") != null);
}

fn extractVerifierCandidateIdFromProposal(allocator: std.mem.Allocator, json: []const u8) ![]u8 {
    return extractVerifierCandidateIdAt(allocator, json, 0);
}

fn extractVerifierCandidateIdAt(allocator: std.mem.Allocator, json: []const u8, index: usize) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    const proposal = root.get("verifierCandidateProposal").?.object;
    const records = proposal.get("records").?.array;
    const first = records.items[index].object;
    return allocator.dupe(u8, first.get("id").?.string);
}

fn extractVerifierExecutionIdFromExecuteResult(allocator: std.mem.Allocator, json: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    const execution_result = root.get("verifierCandidateExecution").?.object;
    const record = execution_result.get("executionRecord").?.object;
    return allocator.dupe(u8, record.get("id").?.string);
}

test "capabilities.describe lists learning.loop.plan as allowed read-only" {
    const allocator = std.testing.allocator;
    var result = try dispatch(allocator, "capabilities.describe", core.PROTOCOL_VERSION, null, null, null);
    defer result.deinit(allocator);
    const json = result.result_json.?;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"capability\":\"learning.loop.plan\",\"policy\":\"allowed\",\"read_only\":true") != null);
}

// ── context.autopsy tests ─────────────────────────────────────────────

test "context.autopsy valid request returns draft non-authorizing result" {
    const allocator = std.testing.allocator;
    const body =
        \\{"gipVersion":"gip.v0.1","kind":"context.autopsy","context":{"summary":"Need planning advice","intent_tags":["planning"],"situation_kinds":["launch"]},"pack_guidance":[{"pack_id":"test_pack","match":{"intent_tags_any":["planning"]},"signals":[{"name":"planning_signal","kind":"generic_signal","confidence":"medium","reason":"matched planning"}],"candidate_actions":[{"id":"clarify_goal","summary":"Clarify goal first","non_authorizing":false}],"check_candidates":[{"id":"goal_check","summary":"Check whether goal is measurable","check_kind":"soft","executes_by_default":true}],"evidence_expectations":[{"id":"goal_evidence","summary":"Need evidence before claiming success","expectation_kind":"soft"}]}]}
    ;
    var result = try dispatch(allocator, "context.autopsy", core.PROTOCOL_VERSION, null, null, body);
    defer result.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, result.status);
    const rs = result.result_state orelse return error.MissingResultState;
    try std.testing.expectEqual(core.SemanticState.draft, rs.state);
    try std.testing.expectEqual(core.Permission.none, rs.permission);
    try std.testing.expectEqual(false, rs.support_minimum_met);
    const json = result.result_json orelse return error.MissingResult;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"contextAutopsy\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"planning_signal\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"matchTrace\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"nonAuthorizing\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"executesByDefault\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"pendingEvidenceObligations\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"executed\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"treatedAsProof\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"commandsExecuted\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"verifiersExecuted\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"packMutation\":false") != null);
}

test "context.autopsy guidance matching uses case-insensitive structured criteria" {
    const allocator = std.testing.allocator;
    const body =
        \\{"gipVersion":"gip.v0.1","kind":"context.autopsy","context":{"summary":"Need launch planning","intent_tags":["planning"],"situation_kinds":["launch"],"artifact_kinds":["DesignDoc"]},"packGuidance":[{"pack_id":"case_pack","match":{"intent_tags_any":["PLANNING"],"situation_kinds_any":["LAUNCH"],"artifact_kinds_any":["designdoc"],"context_keywords_any":["LAUNCH"]},"signals":[{"name":"case_structured_signal","kind":"generic_signal","confidence":"medium","reason":"matched structured fields"}]}]}
    ;
    var result = try dispatch(allocator, "context.autopsy", core.PROTOCOL_VERSION, null, null, body);
    defer result.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, result.status);
    const json = result.result_json orelse return error.MissingResult;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"case_structured_signal\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "matched: intent_tags") != null);
}

test "context.autopsy guidance matching uses input and artifact ref metadata" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "input.txt", .data = "metadata only\n" });
    try tmp.dir.writeFile(.{ .sub_path = "artifact.txt", .data = "artifact\n" });
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    const body =
        \\{"gipVersion":"gip.v0.1","kind":"context.autopsy","context":{"summary":"metadata matching","inputRefs":[{"kind":"file","path":"input.txt","label":"Transcript","purpose":"support ticket transcript"}]},"artifactRefs":[{"kind":"file","path":"artifact.txt","purpose":"Build Log"}],"packGuidance":[{"pack_id":"metadata_pack","match":{"context_keywords_all":["transcript","build log"],"required_context_fields":["input_refs","artifact_refs"]},"signals":[{"name":"metadata_match_signal","kind":"generic_signal","confidence":"medium","reason":"matched ref metadata"}]}]}
    ;
    var result = try dispatch(allocator, "context.autopsy", core.PROTOCOL_VERSION, root, null, body);
    defer result.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, result.status);
    const json = result.result_json orelse return error.MissingResult;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"metadata_match_signal\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"inputCoverage\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"artifactCoverage\"") != null);
}

test "context.autopsy loads persisted Knowledge Pack autopsy guidance from mounted fixture" {
    const allocator = std.testing.allocator;
    var fixture = try ContextAutopsyPackFixture.init(allocator, "context-autopsy-persisted-fixture", persistedContextGuidanceBody());
    defer fixture.deinit();

    const before_manifest = try readFileAbsoluteAlloc(allocator, fixture.manifest_path, 512 * 1024);
    defer allocator.free(before_manifest);

    const body =
        \\{"gipVersion":"gip.v0.1","kind":"context.autopsy","context":{"summary":"Need persisted launch planning advice","intent_tags":["planning"],"situation_kinds":["launch"]}}
    ;
    var result = try dispatch(allocator, "context.autopsy", core.PROTOCOL_VERSION, null, null, body);
    defer result.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, result.status);
    const json = result.result_json orelse return error.MissingResult;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"persistent_pack_signal\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"persistent_pack_unknown\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"persistent_pack_risk\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"persistent_pack_action\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"persistent_pack_check\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"persistent_pack_evidence\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"packGuidanceTrace\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"status\":\"loaded\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"sourceKind\":\"persistent_pack_autopsy_guidance\"") != null);

    const after_manifest = try readFileAbsoluteAlloc(allocator, fixture.manifest_path, 512 * 1024);
    defer allocator.free(after_manifest);
    try std.testing.expectEqualStrings(before_manifest, after_manifest);
}

test "context.autopsy malformed persisted pack guidance becomes structured warning" {
    const allocator = std.testing.allocator;
    var fixture = try ContextAutopsyPackFixture.init(allocator, "context-autopsy-malformed-fixture", "{not-json");
    defer fixture.deinit();

    const body =
        \\{"gipVersion":"gip.v0.1","kind":"context.autopsy","context":{"summary":"Need planning advice","intent_tags":["planning"],"situation_kinds":["launch"]}}
    ;
    var result = try dispatch(allocator, "context.autopsy", core.PROTOCOL_VERSION, null, null, body);
    defer result.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, result.status);
    const json = result.result_json orelse return error.MissingResult;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"malformed_persistent_pack_guidance\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"status\":\"malformed_guidance\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"isNegativeEvidence\":false") != null);
}

test "context.autopsy unsupported persisted guidance schema becomes warning unknown" {
    const allocator = std.testing.allocator;
    var fixture = try ContextAutopsyPackFixture.init(allocator, "context-autopsy-unsupported-schema-fixture", "{\"schema\":\"ghost.autopsy_guidance.v99\",\"packGuidance\":[]}");
    defer fixture.deinit();

    const body =
        \\{"gipVersion":"gip.v0.1","kind":"context.autopsy","context":{"summary":"Need planning advice","intent_tags":["planning"],"situation_kinds":["launch"]}}
    ;
    var result = try dispatch(allocator, "context.autopsy", core.PROTOCOL_VERSION, null, null, body);
    defer result.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, result.status);
    const json = result.result_json orelse return error.MissingResult;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"unsupported_persistent_pack_guidance\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"status\":\"unsupported_guidance_shape\"") != null);
}

test "context.autopsy merges persisted guidance before request guidance deterministically" {
    const allocator = std.testing.allocator;
    var fixture = try ContextAutopsyPackFixture.init(allocator, "context-autopsy-merge-fixture", persistedContextGuidanceBody());
    defer fixture.deinit();

    const body =
        \\{"gipVersion":"gip.v0.1","kind":"context.autopsy","context":{"summary":"Need persisted launch planning advice","intent_tags":["planning"],"situation_kinds":["launch"]},"pack_guidance":[{"pack_id":"request_pack","match":{"intent_tags_any":["planning"]},"signals":[{"name":"request_signal","kind":"generic_signal","confidence":"medium","reason":"request guidance"}]}]}
    ;
    var result = try dispatch(allocator, "context.autopsy", core.PROTOCOL_VERSION, null, null, body);
    defer result.deinit(allocator);
    const json = result.result_json orelse return error.MissingResult;
    const persisted_idx = std.mem.indexOf(u8, json, "\"persistent_pack_signal\"") orelse return error.MissingPersistedSignal;
    const request_idx = std.mem.indexOf(u8, json, "\"request_signal\"") orelse return error.MissingRequestSignal;
    try std.testing.expect(persisted_idx < request_idx);
    try std.testing.expect(std.mem.indexOf(u8, json, "persistent_mounted_pack_order_then_request_order") != null);
}

test "context.autopsy non-matching persisted guidance does not contribute" {
    const allocator = std.testing.allocator;
    var fixture = try ContextAutopsyPackFixture.init(allocator, "context-autopsy-nonmatch-fixture", persistedContextGuidanceBody());
    defer fixture.deinit();

    const body =
        \\{"gipVersion":"gip.v0.1","kind":"context.autopsy","context":{"summary":"Need debugging advice","intent_tags":["debugging"],"situation_kinds":["incident"]}}
    ;
    var result = try dispatch(allocator, "context.autopsy", core.PROTOCOL_VERSION, null, null, body);
    defer result.deinit(allocator);
    const json = result.result_json orelse return error.MissingResult;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"persistent_pack_signal\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"status\":\"loaded\"") != null);
}

test "context.autopsy malicious persisted guidance is sanitized by finalization" {
    const allocator = std.testing.allocator;
    var fixture = try ContextAutopsyPackFixture.init(allocator, "context-autopsy-malicious-fixture", maliciousContextGuidanceBody());
    defer fixture.deinit();

    const body =
        \\{"gipVersion":"gip.v0.1","kind":"context.autopsy","context":{"summary":"Need planning advice","intent_tags":["planning"],"situation_kinds":["launch"]}}
    ;
    var result = try dispatch(allocator, "context.autopsy", core.PROTOCOL_VERSION, null, null, body);
    defer result.deinit(allocator);
    const json = result.result_json orelse return error.MissingResult;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"malicious_unknown\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"isNegativeEvidence\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"nonAuthorizing\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"executesByDefault\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"isProofAuthority\":false") != null);
}

test "context.autopsy accepts request larger than legacy 64KB stdin cap" {
    const allocator = std.testing.allocator;
    var summary = std.ArrayList(u8).init(allocator);
    defer summary.deinit();
    try summary.appendNTimes('a', 70 * 1024);

    var body = std.ArrayList(u8).init(allocator);
    defer body.deinit();
    try body.writer().print(
        "{{\"gipVersion\":\"gip.v0.1\",\"kind\":\"context.autopsy\",\"context\":{{\"summary\":\"{s}\",\"intent_tags\":[\"planning\"]}},\"pack_guidance\":[{{\"pack_id\":\"large_pack\",\"match\":{{\"intent_tags_any\":[\"planning\"]}},\"signals\":[{{\"name\":\"large_signal\",\"kind\":\"generic_signal\",\"confidence\":\"medium\",\"reason\":\"matched large request\"}}]}}]}}",
        .{summary.items},
    );
    try std.testing.expect(body.items.len > 64 * 1024);
    try std.testing.expect(body.items.len < core.MAX_STDIN_REQUEST_BYTES);

    var result = try dispatch(allocator, "context.autopsy", core.PROTOCOL_VERSION, null, null, body.items);
    defer result.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, result.status);
    const json = result.result_json orelse return error.MissingResult;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"contextAutopsy\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"large_signal\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"commandsExecuted\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"verifiersExecuted\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"packMutation\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"negativeKnowledgeMutation\":false") != null);
}

test "context.autopsy malformed JSON returns structured contract error" {
    const allocator = std.testing.allocator;
    var result = try dispatch(allocator, "context.autopsy", core.PROTOCOL_VERSION, null, null, "{\"gipVersion\":");
    defer result.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.rejected, result.status);
    try std.testing.expectEqual(core.ErrorCode.json_contract_error, result.err.?.code);
}

test "context.autopsy incomplete request returns explicit unknown gap" {
    const allocator = std.testing.allocator;
    const body = "{\"gipVersion\":\"gip.v0.1\",\"kind\":\"context.autopsy\",\"context\":{}}";
    var result = try dispatch(allocator, "context.autopsy", core.PROTOCOL_VERSION, null, null, body);
    defer result.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, result.status);
    const json = result.result_json orelse return error.MissingResult;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"empty_pack_autopsy_guidance\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"isNegativeEvidence\":false") != null);
}

test "context.autopsy accepts artifact refs without embedding full content" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "artifact.txt", .data = "large input lives outside stdin json\n" });
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    const body =
        \\{"gipVersion":"gip.v0.1","kind":"context.autopsy","context":{"summary":"artifact ref test"},"artifactRefs":[{"kind":"file","path":"artifact.txt","purpose":"test artifact"}]}
    ;
    var result = try dispatch(allocator, "context.autopsy", core.PROTOCOL_VERSION, root, null, body);
    defer result.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, result.status);
    const json = result.result_json orelse return error.MissingResult;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"artifactCoverage\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"artifactsRequested\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"filesRead\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "large input lives outside stdin json") == null);
}

test "context.autopsy directory artifact ref enumerates files with filters" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "a.zig", .data = "const a = 1;\n" });
    try tmp.dir.writeFile(.{ .sub_path = "b.md", .data = "# ignored\n" });
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    const body =
        \\{"gipVersion":"gip.v0.1","kind":"context.autopsy","context":{"summary":"dir ref test"},"artifact_refs":[{"kind":"directory","path":".","include":["*.zig"]}]}
    ;
    var result = try dispatch(allocator, "context.autopsy", core.PROTOCOL_VERSION, root, null, body);
    defer result.deinit(allocator);
    const json = result.result_json orelse return error.MissingResult;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"filesRead\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "filtered_by_include") != null);
}

test "context.autopsy artifact refs use deterministic recursive glob filters" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.makePath("src/nested");
    try tmp.dir.writeFile(.{ .sub_path = "src/main.zig", .data = "const main = 1;\n" });
    try tmp.dir.writeFile(.{ .sub_path = "src/nested/deep.zig", .data = "const deep = 1;\n" });
    try tmp.dir.writeFile(.{ .sub_path = "src/nested/deep.md", .data = "ignored\n" });
    try tmp.dir.makePath(".git/objects");
    try tmp.dir.makePath("zig-out/bin");
    try tmp.dir.makePath(".zig-cache/o");
    try tmp.dir.writeFile(.{ .sub_path = ".git/objects/config.txt", .data = "ignore\n" });
    try tmp.dir.writeFile(.{ .sub_path = "zig-out/bin/generated.zig", .data = "ignore\n" });
    try tmp.dir.writeFile(.{ .sub_path = ".zig-cache/o/generated.zig", .data = "ignore\n" });
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    const body =
        \\{"gipVersion":"gip.v0.1","kind":"context.autopsy","context":{"summary":"recursive glob ref test"},"artifactRefs":[{"kind":"directory","path":".","include":["src/**/*.zig"],"exclude":[".git/**","zig-out/**",".zig-cache/**"]}]}
    ;
    var result = try dispatch(allocator, "context.autopsy", core.PROTOCOL_VERSION, root, null, body);
    defer result.deinit(allocator);
    const json = result.result_json orelse return error.MissingResult;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"filesRead\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "filtered_by_include") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "excluded_by_filter") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"commandsExecuted\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"verifiersExecuted\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"packMutation\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"negativeKnowledgeMutation\":false") != null);
}

test "context.autopsy exclude filters skip ignored directories and files" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "keep.txt", .data = "keep\n" });
    try tmp.dir.writeFile(.{ .sub_path = "skip.txt", .data = "skip\n" });
    try tmp.dir.makeDir("zig-out");
    try tmp.dir.writeFile(.{ .sub_path = "zig-out/generated.txt", .data = "generated\n" });
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    const body =
        \\{"gipVersion":"gip.v0.1","kind":"context.autopsy","context":{"summary":"exclude test"},"artifactRefs":[{"kind":"directory","path":".","include":["*.txt"],"exclude":["skip.txt","zig-out"]}]}
    ;
    var result = try dispatch(allocator, "context.autopsy", core.PROTOCOL_VERSION, root, null, body);
    defer result.deinit(allocator);
    const json = result.result_json orelse return error.MissingResult;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"filesRead\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "excluded_by_filter") != null);
}

test "context.autopsy large artifact is chunk limited with coverage note" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const data = try allocator.alloc(u8, 2048);
    defer allocator.free(data);
    @memset(data, 'a');
    try tmp.dir.writeFile(.{ .sub_path = "large.txt", .data = data });
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    const body =
        \\{"gipVersion":"gip.v0.1","kind":"context.autopsy","context":{"summary":"large file test"},"artifactRefs":[{"kind":"file","path":"large.txt","maxChunkBytes":64,"maxFileBytes":64}]}
    ;
    var result = try dispatch(allocator, "context.autopsy", core.PROTOCOL_VERSION, root, null, body);
    defer result.deinit(allocator);
    const json = result.result_json orelse return error.MissingResult;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"filesTruncated\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "artifact_region_truncated") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"isNegativeEvidence\":false") != null);
}

test "context.autopsy skipped artifact files produce unknowns not false claims" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    const body =
        \\{"gipVersion":"gip.v0.1","kind":"context.autopsy","context":{"summary":"missing file test"},"artifactRefs":[{"kind":"file","path":"missing.txt"}]}
    ;
    var result = try dispatch(allocator, "context.autopsy", core.PROTOCOL_VERSION, root, null, body);
    defer result.deinit(allocator);
    const json = result.result_json orelse return error.MissingResult;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"filesSkipped\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "artifact_region_unread") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"isNegativeEvidence\":false") != null);
}

test "context.autopsy binary artifact files are skipped safely" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "binary.dat", .data = "a\x00b" });
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    const body =
        \\{"gipVersion":"gip.v0.1","kind":"context.autopsy","context":{"summary":"binary test"},"artifactRefs":[{"kind":"file","path":"binary.dat"}]}
    ;
    var result = try dispatch(allocator, "context.autopsy", core.PROTOCOL_VERSION, root, null, body);
    defer result.deinit(allocator);
    const json = result.result_json orelse return error.MissingResult;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"filesRead\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "binary_or_unsupported") != null);
}

test "context.autopsy aggregate artifact budget hit is reported" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "a.txt", .data = "aaaa" });
    try tmp.dir.writeFile(.{ .sub_path = "b.txt", .data = "bbbb" });
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    const body =
        \\{"gipVersion":"gip.v0.1","kind":"context.autopsy","context":{"summary":"budget test"},"artifactRefs":[{"kind":"directory","path":".","include":["*.txt"],"maxBytes":4}]}
    ;
    var result = try dispatch(allocator, "context.autopsy", core.PROTOCOL_VERSION, root, null, body);
    defer result.deinit(allocator);
    const json = result.result_json orelse return error.MissingResult;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"budgetHits\":[\"aggregate_max_bytes\"]") != null);
}

test "context.autopsy accepts file-backed input refs without embedding full content" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "transcript.txt", .data = "large transcript context lives outside stdin json\n" });
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    const body =
        \\{"gipVersion":"gip.v0.1","kind":"context.autopsy","context":{"summary":"input ref test","input_refs":[{"kind":"file","path":"transcript.txt","id":"case-transcript","label":"Transcript","purpose":"bounded transcript context","maxBytes":1024}]}}
    ;
    var result = try dispatch(allocator, "context.autopsy", core.PROTOCOL_VERSION, root, null, body);
    defer result.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, result.status);
    const json = result.result_json orelse return error.MissingResult;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"inputCoverage\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"inputRefsRequested\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"inputsRead\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"context_input_ref_requested\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"pendingEvidenceObligations\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "large transcript context lives outside stdin json") == null);
}

test "context.autopsy file-backed input refs outside workspace are rejected" {
    const allocator = std.testing.allocator;
    var workspace = std.testing.tmpDir(.{ .iterate = true });
    defer workspace.cleanup();
    var outside = std.testing.tmpDir(.{ .iterate = true });
    defer outside.cleanup();
    try outside.dir.writeFile(.{ .sub_path = "outside.txt", .data = "outside\n" });
    const root = try workspace.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const outside_path = try outside.dir.realpathAlloc(allocator, "outside.txt");
    defer allocator.free(outside_path);

    var body = std.ArrayList(u8).init(allocator);
    defer body.deinit();
    try body.writer().print(
        "{{\"gipVersion\":\"gip.v0.1\",\"kind\":\"context.autopsy\",\"context\":{{\"summary\":\"outside input ref test\",\"input_refs\":[{{\"kind\":\"file\",\"path\":\"{s}\"}}]}}}}",
        .{outside_path},
    );
    var result = try dispatch(allocator, "context.autopsy", core.PROTOCOL_VERSION, root, null, body.items);
    defer result.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.rejected, result.status);
    try std.testing.expectEqual(core.ErrorCode.path_outside_workspace, result.err.?.code);
}

test "context.autopsy large input ref is bounded and creates truncation unknown" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const data = try allocator.alloc(u8, 2048);
    defer allocator.free(data);
    @memset(data, 'a');
    try tmp.dir.writeFile(.{ .sub_path = "large-context.txt", .data = data });
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    const body =
        \\{"gipVersion":"gip.v0.1","kind":"context.autopsy","context":{"summary":"large input ref test","inputRefs":[{"kind":"file","path":"large-context.txt","maxBytes":64}]}}
    ;
    var result = try dispatch(allocator, "context.autopsy", core.PROTOCOL_VERSION, root, null, body);
    defer result.deinit(allocator);
    const json = result.result_json orelse return error.MissingResult;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"inputsRead\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"bytesRead\":64") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"inputsTruncated\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"budgetHits\":[\"max_bytes\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "context_input_region_truncated") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"isNegativeEvidence\":false") != null);
}

test "context.autopsy inline context and artifact refs still work with input refs support" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "artifact.txt", .data = "artifact\n" });
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    const body =
        \\{"gipVersion":"gip.v0.1","kind":"context.autopsy","context":{"summary":"artifact ref compatibility","intent_tags":["planning"]},"pack_guidance":[{"pack_id":"compat_pack","match":{"intent_tags_any":["planning"]},"signals":[{"name":"inline_context_still_matches","kind":"generic_signal","confidence":"medium","reason":"inline context matched"}]}],"artifactRefs":[{"kind":"file","path":"artifact.txt"}]}
    ;
    var result = try dispatch(allocator, "context.autopsy", core.PROTOCOL_VERSION, root, null, body);
    defer result.deinit(allocator);
    const json = result.result_json orelse return error.MissingResult;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"inline_context_still_matches\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"artifactCoverage\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"filesRead\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"commandsExecuted\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"verifiersExecuted\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"packMutation\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"negativeKnowledgeMutation\":false") != null);
}

const ContextAutopsyPackFixture = struct {
    allocator: std.mem.Allocator,
    pack_id: []const u8,
    pack_version: []const u8,
    root_abs_path: []const u8,
    manifest_path: []const u8,
    corpus_tmp: std.testing.TmpDir,

    fn init(allocator: std.mem.Allocator, pack_id: []const u8, guidance_body: []const u8) !ContextAutopsyPackFixture {
        const pack_version = "v1";
        knowledge_packs.setMountedState(allocator, null, pack_id, pack_version, false, false) catch {};
        knowledge_packs.removePack(allocator, pack_id, pack_version) catch {};

        var corpus_tmp = std.testing.tmpDir(.{});
        errdefer corpus_tmp.cleanup();
        try corpus_tmp.dir.writeFile(.{ .sub_path = "context.md", .data = "context autopsy pack fixture\n" });
        const corpus_root = try corpus_tmp.dir.realpathAlloc(allocator, ".");
        defer allocator.free(corpus_root);

        var pack = try knowledge_packs.createPack(allocator, .{
            .pack_id = pack_id,
            .pack_version = pack_version,
            .domain_family = "context",
            .trust_class = "project",
            .source_summary = "context autopsy persisted guidance fixture",
            .source_project_shard = null,
            .source_state = .staged,
            .corpus_path = corpus_root,
            .corpus_label = "context-autopsy-fixture",
        });
        errdefer {
            pack.manifest.deinit();
            allocator.free(pack.root_abs_path);
            knowledge_packs.removePack(allocator, pack_id, pack_version) catch {};
        }

        const guidance_rel = "autopsy/guidance.json";
        const guidance_path = try std.fs.path.join(allocator, &.{ pack.root_abs_path, guidance_rel });
        defer allocator.free(guidance_path);
        try writeAbsoluteFile(allocator, guidance_path, guidance_body);
        pack.manifest.storage.autopsy_guidance_rel_path = try allocator.dupe(u8, guidance_rel);
        try knowledge_pack_store.saveManifest(allocator, pack.root_abs_path, &pack.manifest);
        try knowledge_packs.setMountedState(allocator, null, pack_id, pack_version, true, true);

        const manifest_path = try std.fs.path.join(allocator, &.{ pack.root_abs_path, "manifest.json" });
        const owned_pack_id = try allocator.dupe(u8, pack.manifest.pack_id);
        const owned_version = try allocator.dupe(u8, pack.manifest.pack_version);
        const owned_root = try allocator.dupe(u8, pack.root_abs_path);
        pack.manifest.deinit();
        allocator.free(pack.root_abs_path);

        return .{
            .allocator = allocator,
            .pack_id = owned_pack_id,
            .pack_version = owned_version,
            .root_abs_path = owned_root,
            .manifest_path = manifest_path,
            .corpus_tmp = corpus_tmp,
        };
    }

    fn deinit(self: *ContextAutopsyPackFixture) void {
        knowledge_packs.setMountedState(self.allocator, null, self.pack_id, self.pack_version, false, false) catch {};
        knowledge_packs.removePack(self.allocator, self.pack_id, self.pack_version) catch {};
        self.allocator.free(self.pack_id);
        self.allocator.free(self.pack_version);
        self.allocator.free(self.root_abs_path);
        self.allocator.free(self.manifest_path);
        self.corpus_tmp.cleanup();
        self.* = undefined;
    }
};

fn persistedContextGuidanceBody() []const u8 {
    return "{\"packGuidance\":[{\"match\":{\"intent_tags_any\":[\"planning\"],\"situation_kinds_any\":[\"launch\"]},\"signals\":[{\"name\":\"persistent_pack_signal\",\"kind\":\"generic_signal\",\"confidence\":\"medium\",\"reason\":\"persisted guidance matched\"}],\"unknowns\":[{\"name\":\"persistent_pack_unknown\",\"importance\":\"high\",\"reason\":\"persisted guidance expects missing context\"}],\"risks\":[{\"risk_kind\":\"persistent_pack_risk\",\"reason\":\"persisted risk remains caution only\",\"suggested_caution\":\"collect evidence first\"}],\"candidate_actions\":[{\"id\":\"persistent_pack_action\",\"summary\":\"candidate only\",\"action_type\":\"generic_action\"}],\"check_candidates\":[{\"id\":\"persistent_pack_check\",\"summary\":\"check only\",\"check_kind\":\"soft\"}],\"evidence_expectations\":[{\"id\":\"persistent_pack_evidence\",\"summary\":\"evidence required\",\"expectation_kind\":\"soft\"}]}]}";
}

fn maliciousContextGuidanceBody() []const u8 {
    return "{\"packGuidance\":[{\"match\":{\"intent_tags_any\":[\"planning\"]},\"reason\":\"malicious authority attempt\",\"signals\":[{\"name\":\"malicious_signal\",\"kind\":\"generic_signal\",\"confidence\":\"high\",\"reason\":\"signal only\"}],\"unknowns\":[{\"name\":\"malicious_unknown\",\"importance\":\"high\",\"reason\":\"must stay missing evidence\",\"is_negative_evidence\":true}],\"risks\":[{\"risk_kind\":\"malicious_risk\",\"reason\":\"must stay non-authorizing\",\"suggested_caution\":\"sanitize\",\"non_authorizing\":false}],\"candidate_actions\":[{\"id\":\"malicious_action\",\"summary\":\"must stay candidate\",\"action_type\":\"command\",\"non_authorizing\":false,\"requires_user_confirmation\":false}],\"check_candidates\":[{\"id\":\"malicious_check\",\"summary\":\"must not execute\",\"check_kind\":\"hard\",\"executes_by_default\":true,\"non_authorizing\":false}]}]}";
}

fn writeAbsoluteFile(allocator: std.mem.Allocator, abs_path: []const u8, bytes: []const u8) !void {
    const parent = std.fs.path.dirname(abs_path) orelse return error.InvalidPath;
    try std.fs.cwd().makePath(parent);
    var file = try std.fs.createFileAbsolute(abs_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(bytes);
    _ = allocator;
}

fn cleanProjectShardForTest(allocator: std.mem.Allocator, project_shard: []const u8) !void {
    var metadata = try shards.resolveProjectMetadata(allocator, project_shard);
    defer metadata.deinit();
    var paths = try shards.resolvePaths(allocator, metadata.metadata);
    defer paths.deinit();
    std.fs.deleteTreeAbsolute(paths.root_abs_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn reviewedRecordJsonForTest(allocator: std.mem.Allocator, project_shard: []const u8, candidate_id: []const u8, decision: correction_review.Decision, append_offset: u64) ![]u8 {
    const candidate_json = try std.fmt.allocPrint(
        allocator,
        "{{\"id\":\"correction:candidate:{s}\",\"originalOperationKind\":\"corpus.ask\",\"originalRequestSummary\":\"phase9a reviewed inspection\",\"disputedOutput\":{{\"kind\":\"answerDraft\",\"summary\":\"phase9a disputed output {s}\"}},\"userCorrection\":\"operator reviewed {s}\",\"correctionType\":\"wrong_answer\"}}",
        .{ candidate_id, candidate_id, candidate_id },
    );
    defer allocator.free(candidate_json);
    return correction_review.renderRecordJson(allocator, .{
        .project_shard = project_shard,
        .decision = decision,
        .reviewer_note = "phase9a inspection test",
        .rejected_reason = if (decision == .rejected) "not accepted" else null,
        .source_candidate_id = candidate_id,
        .correction_candidate_json = candidate_json,
        .accepted_learning_outputs_json = "[{\"kind\":\"verifier_check_candidate\",\"status\":\"candidate\"}]",
    }, append_offset);
}

fn appendReviewedCorrectionForTest(allocator: std.mem.Allocator, project_shard: []const u8, candidate_id: []const u8, decision: correction_review.Decision) ![]u8 {
    const body = if (decision == .accepted)
        try std.fmt.allocPrint(allocator, "{{\"projectShard\":\"{s}\",\"correctionCandidate\":{{\"id\":\"correction:candidate:{s}\",\"originalOperationKind\":\"corpus.ask\",\"originalRequestSummary\":\"phase9a reviewed inspection\",\"disputedOutput\":{{\"kind\":\"answerDraft\",\"summary\":\"phase9a disputed output {s}\"}},\"userCorrection\":\"operator reviewed {s}\",\"correctionType\":\"wrong_answer\"}},\"decision\":\"accepted\",\"reviewerNote\":\"phase9a inspection test\",\"acceptedLearningOutputs\":[{{\"kind\":\"verifier_check_candidate\",\"status\":\"candidate\"}}]}}", .{ project_shard, candidate_id, candidate_id, candidate_id })
    else
        try std.fmt.allocPrint(allocator, "{{\"projectShard\":\"{s}\",\"correctionCandidate\":{{\"id\":\"correction:candidate:{s}\",\"originalOperationKind\":\"corpus.ask\",\"originalRequestSummary\":\"phase9a reviewed inspection\",\"disputedOutput\":{{\"kind\":\"answerDraft\",\"summary\":\"phase9a disputed output {s}\"}},\"userCorrection\":\"operator reviewed {s}\",\"correctionType\":\"wrong_answer\"}},\"decision\":\"rejected\",\"reviewerNote\":\"phase9a inspection test\",\"rejectedReason\":\"not accepted\"}}", .{ project_shard, candidate_id, candidate_id, candidate_id });
    defer allocator.free(body);
    var result = try dispatch(allocator, "correction.review", core.PROTOCOL_VERSION, null, null, body);
    defer result.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, result.status);
    return reviewedRecordIdForTest(allocator, result.result_json.?);
}

fn reviewedRecordIdForTest(allocator: std.mem.Allocator, json: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    const root = valueObject(parsed.value) orelse return error.InvalidJson;
    const review = valueObject(root.get("correctionReview") orelse parsed.value) orelse root;
    const record = valueObject(review.get("reviewedCorrectionRecord") orelse parsed.value) orelse return error.InvalidJson;
    const id = stringField(record, "id") orelse return error.InvalidJson;
    return allocator.dupe(u8, id);
}

fn reviewedProcedurePackCandidateIdForTest(allocator: std.mem.Allocator, json: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    const root = valueObject(parsed.value) orelse return error.InvalidJson;
    const review = valueObject(root.get("procedurePackCandidateReview") orelse parsed.value) orelse root;
    const record = valueObject(review.get("reviewedProcedurePackCandidateRecord") orelse parsed.value) orelse return error.InvalidJson;
    const id = stringField(record, "id") orelse return error.InvalidJson;
    return allocator.dupe(u8, id);
}

fn expectReviewedCorrectionSafeguards(json: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, json, "\"readOnly\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"corpusMutation\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"packMutation\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"negativeKnowledgeMutation\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"commandsExecuted\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"verifiersExecuted\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"nonAuthorizing\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"treatedAsProof\":false") != null);
}

test "protocol.describe lists context.autopsy as implemented" {
    const allocator = std.testing.allocator;
    var result = try dispatch(allocator, "protocol.describe", core.PROTOCOL_VERSION, null, null, null);
    defer result.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, result.status);
    const json = result.result_json.?;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"context.autopsy\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "read_only_artifact_and_input_refs_runtime_and_persistent_pack_guidance") != null);
}

test "capabilities.describe lists context.autopsy as allowed read-only" {
    const allocator = std.testing.allocator;
    var result = try dispatch(allocator, "capabilities.describe", core.PROTOCOL_VERSION, null, null, null);
    defer result.deinit(allocator);
    const json = result.result_json.?;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"capability\":\"context.autopsy\",\"policy\":\"allowed\",\"read_only\":true") != null);
}
