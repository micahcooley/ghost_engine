const std = @import("std");
const core = @import("../gip_core.zig");
const sys = @import("../sys.zig");
const gip = @import("../gip.zig");
const ghost_state = @import("../ghost_state.zig");
const config = @import("../config.zig");
const knowledge_pack_store = @import("../knowledge_pack_store.zig");
const artifact_autopsy = @import("../artifact_autopsy.zig");
const verifier_adapter = @import("../verifier_adapter.zig");
const verifier_candidates = @import("../verifier_candidates.zig");
const gip_utils = @import("utils.zig");
const writeEscaped = gip_utils.writeEscaped;
const boundedCount = gip_utils.boundedCount;
const getStr = gip_utils.getStr;
const boundedMaxItems = gip_utils.boundedMaxItems;
const verifierCandidateRequestError = @import("../gip_dispatch.zig").verifierCandidateRequestError;
const verifierCandidateExecutionRequestError = @import("../gip_dispatch.zig").verifierCandidateExecutionRequestError;
const renderVerifierCandidateExecutionGetError = @import("../gip_dispatch.zig").renderVerifierCandidateExecutionGetError;
const isExternalHook = @import("../gip_dispatch.zig").isExternalHook;
const schema = @import("../gip_schema.zig");
const verifier_candidate_execution = @import("../verifier_candidate_execution.zig");
const shards = @import("../shards.zig");

const DispatchResult = @import("../gip_dispatch.zig").DispatchResult;
// Add any missing imports based on compiler errors

pub fn dispatchVerifierList(allocator: std.mem.Allocator) !DispatchResult {
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

pub fn dispatchVerifierCandidateExecutionList(allocator: std.mem.Allocator, workspace_root: ?[]const u8, request_body: ?[]const u8) !DispatchResult {
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

pub fn dispatchVerifierCandidateExecutionGet(allocator: std.mem.Allocator, workspace_root: ?[]const u8, request_body: ?[]const u8) !DispatchResult {
    _ = workspace_root;
    const body = request_body orelse return .{
        .status = .rejected,
        .err = .{ .code = .missing_required_field, .message = "missing request body" },
        .result_json = try renderVerifierCandidateExecutionGetError(allocator, "rejected", null, null, "missing_request_body", "request body is required"),
        .allocated_result = true,
    };

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return .{
            .status = .rejected,
            .err = .{ .code = .json_contract_error, .message = "invalid JSON" },
            .result_json = try renderVerifierCandidateExecutionGetError(allocator, "rejected", null, null, "invalid_json", "request body must be valid JSON"),
            .allocated_result = true,
        };
    };
    defer parsed.deinit();

    if (parsed.value != .object) return .{
        .status = .rejected,
        .err = .{ .code = .invalid_request, .message = "verifier.candidate.execution.get request must be a JSON object" },
        .result_json = try renderVerifierCandidateExecutionGetError(allocator, "rejected", null, null, "invalid_request_shape", "request must be a JSON object"),
        .allocated_result = true,
    };
    const obj = parsed.value.object;
    const project_shard_raw = getStr(obj, "project_shard", "projectShard") orelse return .{
        .status = .rejected,
        .err = .{ .code = .missing_required_field, .message = "projectShard is required" },
        .result_json = try renderVerifierCandidateExecutionGetError(allocator, "rejected", null, null, "missing_project_shard", "projectShard is required"),
        .allocated_result = true,
    };
    const execution_id_raw = getStr(obj, "execution_id", "executionId") orelse return .{
        .status = .rejected,
        .err = .{ .code = .missing_required_field, .message = "execution_id is required" },
        .result_json = try renderVerifierCandidateExecutionGetError(allocator, "rejected", project_shard_raw, null, "missing_execution_id", "executionId is required"),
        .allocated_result = true,
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
        .status = .unresolved,
        .err = .{
            .code = .path_not_found,
            .message = "verifier candidate execution not found",
            .fix_hint = "list verifier.candidate.execution.list with projectShard to inspect persisted verifier execution records",
        },
        .result_state = schema.unresolvedResultState("verifier candidate execution not found"),
        .result_json = try renderVerifierCandidateExecutionGetError(allocator, "not_found", project_shard, execution_id, "verifier_execution_not_found", "no same-shard verifier execution record matched executionId"),
        .allocated_result = true,
    };
}

pub fn dispatchVerifierCandidateProposeFromLearningPlan(allocator: std.mem.Allocator, request_body: ?[]const u8) !DispatchResult {
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

pub fn dispatchVerifierCandidateList(allocator: std.mem.Allocator, request_body: ?[]const u8) !DispatchResult {
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

pub fn dispatchVerifierCandidateReview(allocator: std.mem.Allocator, request_body: ?[]const u8) !DispatchResult {
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

pub fn dispatchVerifierCandidateExecute(allocator: std.mem.Allocator, workspace_root: ?[]const u8, request_body: ?[]const u8) !DispatchResult {
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

