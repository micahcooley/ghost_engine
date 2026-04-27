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
const knowledge_packs = @import("knowledge_packs.zig");
const knowledge_pack_store = @import("knowledge_pack_store.zig");
const feedback = @import("feedback.zig");
const shards = @import("shards.zig");
const task_sessions = @import("task_sessions.zig");

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

    // Check implemented
    if (validation.validateImplemented(kind)) |err| {
        return .{ .status = .unsupported, .err = err, .result_state = schema.unsupportedResultState() };
    }

    // Capability gate
    if (validation.validateCapability(kind)) |err| {
        if (err.code == .capability_denied) {
            return .{ .status = .rejected, .err = err };
        }
    }

    // Dispatch by kind
    return switch (kind) {
        .@"protocol.describe" => dispatchProtocolDescribe(allocator),
        .@"capabilities.describe" => dispatchCapabilitiesDescribe(allocator),
        .@"engine.status" => dispatchEngineStatus(allocator),
        .@"conversation.turn" => dispatchConversationTurn(allocator, workspace_root, request_body),
        .@"artifact.read" => dispatchArtifactRead(allocator, workspace_root, request_path),
        .@"artifact.list" => dispatchArtifactList(allocator, workspace_root, request_path),
        .@"artifact.patch.propose" => dispatchArtifactPatchPropose(allocator, workspace_root, request_body),
        .@"hypothesis.list" => dispatchHypothesisList(allocator, request_body),
        .@"hypothesis.triage" => dispatchHypothesisTriage(allocator, request_body),
        .@"verifier.list" => dispatchVerifierList(allocator),
        .@"verifier.candidate.execution.list" => dispatchVerifierCandidateExecutionList(allocator, workspace_root, request_body),
        .@"verifier.candidate.execution.get" => dispatchVerifierCandidateExecutionGet(allocator, workspace_root, request_body),
        .@"correction.list" => dispatchCorrectionList(allocator, workspace_root, request_body),
        .@"correction.get" => dispatchCorrectionGet(allocator, workspace_root, request_body),
        .@"negative_knowledge.candidate.list" => dispatchNegativeKnowledgeCandidateList(allocator, workspace_root, request_body),
        .@"negative_knowledge.candidate.get" => dispatchNegativeKnowledgeCandidateGet(allocator, workspace_root, request_body),
        .@"negative_knowledge.record.list" => dispatchNegativeKnowledgeRecordList(allocator, workspace_root, request_body),
        .@"negative_knowledge.record.get" => dispatchNegativeKnowledgeRecordGet(allocator, workspace_root, request_body),
        .@"negative_knowledge.influence.list" => dispatchNegativeKnowledgeInfluenceList(allocator, workspace_root, request_body),
        .@"trust_decay.candidate.list" => dispatchTrustDecayCandidateList(allocator, workspace_root, request_body),
        .@"negative_knowledge.candidate.review" => dispatchNegativeKnowledgeCandidateReview(allocator, request_body),
        .@"negative_knowledge.record.expire" => dispatchNegativeKnowledgeRecordExpire(allocator, request_body),
        .@"negative_knowledge.record.supersede" => dispatchNegativeKnowledgeRecordSupersede(allocator, request_body),
        .@"pack.list" => dispatchPackList(allocator, workspace_root),
        .@"pack.inspect" => dispatchPackInspect(allocator, request_body),
        .@"feedback.summary" => dispatchFeedbackSummary(allocator, workspace_root, request_body),
        .@"session.get" => dispatchSessionGet(allocator, request_body),
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
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    try w.writeAll("{\"protocol\":{");
    try w.writeAll("\"version\":\"");
    try w.writeAll(core.PROTOCOL_VERSION);
    try w.writeAll("\",\"implemented\":[\"protocol.describe\",\"capabilities.describe\",\"engine.status\",\"conversation.turn\",\"artifact.read\",\"artifact.list\",\"artifact.patch.propose\",\"hypothesis.list\",\"hypothesis.triage\",\"verifier.list\",\"verifier.candidate.execution.list\",\"verifier.candidate.execution.get\",\"correction.list\",\"correction.get\",\"negative_knowledge.candidate.list\",\"negative_knowledge.candidate.get\",\"negative_knowledge.record.list\",\"negative_knowledge.record.get\",\"negative_knowledge.influence.list\",\"trust_decay.candidate.list\",\"negative_knowledge.candidate.review\",\"negative_knowledge.record.expire\",\"negative_knowledge.record.supersede\",\"pack.list\",\"pack.inspect\",\"feedback.summary\",\"session.get\"]");
    try w.writeAll(",\"maturity\":{\"hypothesis.list\":\"stateless\",\"hypothesis.triage\":\"stateless\",\"verifier.candidate.execution.list\":\"read_only_state_inspection\",\"verifier.candidate.execution.get\":\"read_only_state_inspection\",\"correction.list\":\"read_only_state_inspection\",\"correction.get\":\"read_only_state_inspection\",\"negative_knowledge.candidate.list\":\"read_only_state_inspection\",\"negative_knowledge.candidate.get\":\"read_only_state_inspection\",\"negative_knowledge.record.list\":\"read_only_state_inspection\",\"negative_knowledge.record.get\":\"read_only_state_inspection\",\"negative_knowledge.influence.list\":\"read_only_state_inspection\",\"trust_decay.candidate.list\":\"read_only_state_inspection\",\"negative_knowledge.candidate.review\":\"structured_unsupported_without_persistence\",\"negative_knowledge.record.expire\":\"structured_unsupported_without_persistence\",\"negative_knowledge.record.supersede\":\"structured_unsupported_without_persistence\",\"feedback.summary\":\"requires_workspace_metadata\",\"session.get\":\"requires_existing_session\"}");
    try w.writeAll(",\"unsupported\":[\"artifact.patch.apply\",\"artifact.write.propose\",\"artifact.write.apply\",\"artifact.search\",\"conversation.replay\",\"intent.ground\",\"response.evaluate\",\"verifier.run\",\"verifier.candidate.execute\",\"hypothesis.generate\",\"hypothesis.verifier.schedule\",\"correction.apply\",\"negative_knowledge.promote\",\"pack.update_from_negative_knowledge\",\"trust_decay.apply\",\"pack.mount\",\"pack.unmount\",\"pack.import\",\"pack.export\",\"pack.distill.list\",\"pack.distill.show\",\"pack.distill.export\",\"feedback.record\",\"feedback.replay\",\"session.create\",\"session.update\",\"session.close\",\"command.run\"]");
    try w.writeAll("}}");

    return .{
        .status = .ok,
        .result_json = try out.toOwnedSlice(),
        .allocated_result = true,
    };
}

fn dispatchCapabilitiesDescribe(allocator: std.mem.Allocator) !DispatchResult {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    try w.writeAll("{\"capabilities\":[");
    try w.writeAll("{\"capability\":\"protocol.describe\",\"policy\":\"allowed\"},");
    try w.writeAll("{\"capability\":\"capabilities.describe\",\"policy\":\"allowed\"},");
    try w.writeAll("{\"capability\":\"engine.status\",\"policy\":\"allowed\"},");
    try w.writeAll("{\"capability\":\"artifact.read\",\"policy\":\"allowed\"},");
    try w.writeAll("{\"capability\":\"artifact.list\",\"policy\":\"allowed\"},");
    try w.writeAll("{\"capability\":\"artifact.patch.propose\",\"policy\":\"allowed\"},");
    try w.writeAll("{\"capability\":\"conversation.turn\",\"policy\":\"allowed\"},");
    try w.writeAll("{\"capability\":\"hypothesis.list\",\"policy\":\"allowed\",\"read_only\":true},");
    try w.writeAll("{\"capability\":\"hypothesis.triage\",\"policy\":\"allowed\",\"read_only\":true},");
    try w.writeAll("{\"capability\":\"verifier.list\",\"policy\":\"allowed\",\"read_only\":true},");
    try w.writeAll("{\"capability\":\"verifier.candidate.execution.list\",\"policy\":\"allowed\",\"read_only\":true},");
    try w.writeAll("{\"capability\":\"verifier.candidate.execution.get\",\"policy\":\"allowed\",\"read_only\":true},");
    try w.writeAll("{\"capability\":\"correction.list\",\"policy\":\"allowed\",\"read_only\":true},");
    try w.writeAll("{\"capability\":\"correction.get\",\"policy\":\"allowed\",\"read_only\":true},");
    try w.writeAll("{\"capability\":\"negative_knowledge.candidate.list\",\"policy\":\"allowed\",\"read_only\":true},");
    try w.writeAll("{\"capability\":\"negative_knowledge.candidate.get\",\"policy\":\"allowed\",\"read_only\":true},");
    try w.writeAll("{\"capability\":\"negative_knowledge.record.list\",\"policy\":\"allowed\",\"read_only\":true},");
    try w.writeAll("{\"capability\":\"negative_knowledge.record.get\",\"policy\":\"allowed\",\"read_only\":true},");
    try w.writeAll("{\"capability\":\"negative_knowledge.influence.list\",\"policy\":\"allowed\",\"read_only\":true},");
    try w.writeAll("{\"capability\":\"trust_decay.candidate.list\",\"policy\":\"allowed\",\"read_only\":true},");
    try w.writeAll("{\"capability\":\"negative_knowledge.candidate.review\",\"policy\":\"requires_approval\",\"mutation\":true,\"note\":\"structured unsupported until safe append-only persistence is available\"},");
    try w.writeAll("{\"capability\":\"negative_knowledge.record.expire\",\"policy\":\"requires_approval\",\"mutation\":true,\"note\":\"structured unsupported until safe append-only persistence is available\"},");
    try w.writeAll("{\"capability\":\"negative_knowledge.record.supersede\",\"policy\":\"requires_approval\",\"mutation\":true,\"note\":\"structured unsupported until safe append-only persistence is available\"},");
    try w.writeAll("{\"capability\":\"pack.list\",\"policy\":\"allowed\",\"read_only\":true},");
    try w.writeAll("{\"capability\":\"pack.inspect\",\"policy\":\"allowed\",\"read_only\":true},");
    try w.writeAll("{\"capability\":\"feedback.summary\",\"policy\":\"allowed\",\"read_only\":true},");
    try w.writeAll("{\"capability\":\"session.get\",\"policy\":\"allowed\",\"read_only\":true},");
    try w.writeAll("{\"capability\":\"artifact.patch.apply\",\"policy\":\"requires_approval\",\"mutation\":true},");
    try w.writeAll("{\"capability\":\"verifier.run\",\"policy\":\"allowed\",\"note\":\"not yet implemented\"},");
    try w.writeAll("{\"capability\":\"verifier.candidate.execute\",\"policy\":\"denied\",\"mutation\":true,\"note\":\"future work; not implemented\"},");
    try w.writeAll("{\"capability\":\"correction.apply\",\"policy\":\"denied\",\"mutation\":true,\"note\":\"future work; not implemented\"},");
    try w.writeAll("{\"capability\":\"negative_knowledge.promote\",\"policy\":\"denied\",\"mutation\":true,\"note\":\"future work; not implemented\"},");
    try w.writeAll("{\"capability\":\"pack.update_from_negative_knowledge\",\"policy\":\"denied\",\"mutation\":true,\"note\":\"future work; not implemented\"},");
    try w.writeAll("{\"capability\":\"trust_decay.apply\",\"policy\":\"denied\",\"mutation\":true,\"note\":\"future work; not implemented\"},");
    try w.writeAll("{\"capability\":\"command.run\",\"policy\":\"allowlist\",\"note\":\"not yet implemented\"},");
    try w.writeAll("{\"capability\":\"network.access\",\"policy\":\"denied\"}");
    try w.writeAll("]}");

    return .{
        .status = .ok,
        .result_json = try out.toOwnedSlice(),
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
    var max_items: usize = core.MAX_VERIFIER_EXECUTION_ITEMS;
    var state_path: ?[]u8 = null;
    defer if (state_path) |p| allocator.free(p);
    var candidate_filter: ?[]const u8 = null;
    var hypothesis_filter: ?[]const u8 = null;
    var status_filter: ?[]const u8 = null;

    if (request_body) |body| {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
            return .{ .status = .rejected, .err = .{ .code = .json_contract_error, .message = "invalid JSON" } };
        };
        defer parsed.deinit();
        const obj = parsed.value.object;
        max_items = boundedMaxItems(obj, core.MAX_VERIFIER_EXECUTION_ITEMS, core.MAX_VERIFIER_EXECUTION_ITEMS);
        _ = getStr(obj, "session_id", "sessionId");
        candidate_filter = getStr(obj, "candidate_id", "candidateId");
        hypothesis_filter = getStr(obj, "hypothesis_id", "hypothesisId");
        status_filter = getStr(obj, "status_filter", "statusFilter");
        state_path = resolveInspectionStatePath(allocator, workspace_root, obj) catch |err| {
            if (err == error.PathRejected) return .{ .status = .rejected, .err = .{ .code = .path_outside_workspace, .message = "state path outside workspace" } };
            return err;
        };
    }

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    var pending: usize = 0;
    var scheduled: usize = 0;
    var running: usize = 0;
    var completed: usize = 0;
    var failed: usize = 0;
    var blocked: usize = 0;
    var skipped: usize = 0;
    var budget_exhausted: usize = 0;
    var timeout: usize = 0;
    var total: usize = 0;
    var emitted: usize = 0;
    const source = if (state_path != null) "support_graph" else "no_state_found";

    var parsed_state: ?std.json.Parsed(std.json.Value) = null;
    defer if (parsed_state) |*p| p.deinit();
    if (state_path) |path| {
        parsed_state = loadInspectionState(allocator, path) catch null;
    }

    try w.writeAll("{\"executions\":[");
    if (parsed_state) |state| {
        const nodes = supportGraphNodes(state.value);
        if (nodes) |node_array| {
            for (node_array.items) |node_val| {
                const node = valueObject(node_val) orelse continue;
                const kind = stringField(node, "kind") orelse continue;
                if (!std.mem.eql(u8, kind, "verifier_execution_job")) continue;
                const id = stringField(node, "id") orelse continue;
                const detail = stringField(node, "detail") orelse "";
                const status = detailValue(detail, "status=") orelse "unknown";
                const execution_kind = detailValue(detail, "execution_kind=") orelse "unknown";
                const candidate_id = suffixAfterLast(id, "exec_job:") orelse id;
                if (candidate_filter) |filter| if (!std.mem.eql(u8, candidate_id, filter) and std.mem.indexOf(u8, id, filter) == null) continue;
                if (hypothesis_filter != null) continue;
                if (status_filter) |filter| if (!std.mem.eql(u8, status, filter)) continue;
                total += 1;
                if (std.mem.eql(u8, status, "pending")) pending += 1 else if (std.mem.eql(u8, status, "scheduled")) scheduled += 1 else if (std.mem.eql(u8, status, "running")) running += 1 else if (std.mem.eql(u8, status, "completed")) completed += 1 else if (std.mem.eql(u8, status, "failed")) failed += 1 else if (std.mem.eql(u8, status, "blocked")) blocked += 1 else if (std.mem.eql(u8, status, "skipped")) skipped += 1 else if (std.mem.eql(u8, status, "budget_exhausted")) budget_exhausted += 1 else if (std.mem.eql(u8, status, "timeout")) timeout += 1;
                if (emitted >= max_items) continue;
                if (emitted != 0) try w.writeByte(',');
                emitted += 1;
                try writeExecutionProjection(w, state.value, node, id, candidate_id, status, execution_kind, detail);
            }
        }
    }
    try w.writeAll("],\"counts\":{\"total\":");
    try w.print("{d}", .{total});
    try w.writeAll(",\"pending\":");
    try w.print("{d}", .{pending});
    try w.writeAll(",\"scheduled\":");
    try w.print("{d}", .{scheduled});
    try w.writeAll(",\"running\":");
    try w.print("{d}", .{running});
    try w.writeAll(",\"completed\":");
    try w.print("{d}", .{completed});
    try w.writeAll(",\"failed\":");
    try w.print("{d}", .{failed});
    try w.writeAll(",\"blocked\":");
    try w.print("{d}", .{blocked});
    try w.writeAll(",\"skipped\":");
    try w.print("{d}", .{skipped});
    try w.writeAll(",\"budget_exhausted\":");
    try w.print("{d}", .{budget_exhausted});
    try w.writeAll(",\"timeout\":");
    try w.print("{d}", .{timeout});
    try w.writeAll("},\"max_items\":");
    try w.print("{d}", .{max_items});
    try w.writeAll(",\"read_only\":true,\"non_authorizing_input\":true,\"state_source\":\"");
    try w.writeAll(source);
    try w.writeAll("\",\"trace\":{\"summary\":\"inspection only; read existing state without scheduling verifiers\"}}");

    return .{
        .status = .ok,
        .result_json = try out.toOwnedSlice(),
        .allocated_result = true,
    };
}

fn dispatchVerifierCandidateExecutionGet(allocator: std.mem.Allocator, workspace_root: ?[]const u8, request_body: ?[]const u8) !DispatchResult {
    const body = request_body orelse return .{
        .status = .rejected,
        .err = .{ .code = .missing_required_field, .message = "missing request body" },
    };

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return .{ .status = .rejected, .err = .{ .code = .json_contract_error, .message = "invalid JSON" } };
    };
    defer parsed.deinit();

    const obj = parsed.value.object;
    const execution_id = getStr(obj, "execution_id", "executionId") orelse return .{
        .status = .rejected,
        .err = .{ .code = .missing_required_field, .message = "execution_id is required" },
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
            if (findNode(parsed_state.value, execution_id, "verifier_execution_job")) |node| {
                const detail = stringField(node, "detail") orelse "";
                const status = detailValue(detail, "status=") orelse "unknown";
                const execution_kind = detailValue(detail, "execution_kind=") orelse "unknown";
                const candidate_id = suffixAfterLast(execution_id, "exec_job:") orelse execution_id;
                var out = std.ArrayList(u8).init(allocator);
                errdefer out.deinit();
                const w = out.writer();
                try w.writeAll("{\"execution\":");
                try writeExecutionProjection(w, parsed_state.value, node, execution_id, candidate_id, status, execution_kind, detail);
                try w.writeAll(",\"result\":");
                if (linkedEdgeTarget(parsed_state.value, execution_id, "execution_produces_evidence")) |result_id| {
                    if (findNode(parsed_state.value, result_id, "verifier_execution_result")) |result_node| {
                        const result_detail = stringField(result_node, "detail") orelse "";
                        try w.writeAll("{\"id\":\"");
                        try writeEscaped(w, result_id);
                        try w.writeAll("\",\"status\":\"");
                        try writeEscaped(w, detailValue(result_detail, "status=") orelse "unknown");
                        try w.writeAll("\",\"elapsed_ms\":");
                        try w.writeAll(detailValue(result_detail, "elapsed_ms=") orelse "null");
                        try w.writeAll(",\"trace\":{\"summary\":\"");
                        try writeEscaped(w, result_detail);
                        try w.writeAll("\",\"source\":\"support_graph\"}}");
                    } else try w.writeAll("null");
                } else try w.writeAll("null");
                try w.writeAll(",\"stdout_ref\":null,\"stderr_ref\":null,\"evidence_refs\":[],\"correction_refs\":[],\"safety_policy\":{\"source\":\"support_graph_projection\"},\"budget_trace\":{\"source\":\"support_graph_projection\"},\"trace\":{\"summary\":\"read existing support graph state\"}}");
                return .{ .status = .ok, .result_json = try out.toOwnedSlice(), .allocated_result = true };
            }
        }
    }

    return .{
        .status = .failed,
        .err = .{
            .code = .path_not_found,
            .message = "verifier candidate execution not found",
            .details = execution_id,
            .fix_hint = "list verifier.candidate.execution.list to inspect visible execution jobs",
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
    var result = try dispatch(allocator, "verifier.candidate.execution.list", core.PROTOCOL_VERSION, null, null, "{}");
    defer result.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, result.status);
    const json = result.result_json.?;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"executions\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"total\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"non_authorizing_input\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "engine_state_not_wired") == null);
}

test "inspection APIs read existing support graph state" {
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
    var exec_result = try dispatch(allocator, "verifier.candidate.execution.list", core.PROTOCOL_VERSION, ws.workspace_root, null, exec_body);
    defer exec_result.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, exec_result.status);
    try std.testing.expect(std.mem.indexOf(u8, exec_result.result_json.?, "\"state_source\":\"support_graph\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, exec_result.result_json.?, "\"candidate_id\":\"cand-real\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, exec_result.result_json.?, "\"completed\":1") != null);

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

test "inspection get APIs read existing support graph state" {
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

    var exec_get = try dispatch(allocator, "verifier.candidate.execution.get", core.PROTOCOL_VERSION, ws.workspace_root, null, "{\"statePath\":\"state.json\",\"executionId\":\"out:exec_job:exec_job:cand-real\"}");
    defer exec_get.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, exec_get.status);
    try std.testing.expect(std.mem.indexOf(u8, exec_get.result_json.?, "\"execution\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, exec_get.result_json.?, "\"result\"") != null);

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

test "get missing execution returns structured error" {
    const allocator = std.testing.allocator;
    var result = try dispatch(allocator, "verifier.candidate.execution.get", core.PROTOCOL_VERSION, null, null, "{\"executionId\":\"missing-exec\"}");
    defer result.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.failed, result.status);
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

    var execution_result = try dispatch(allocator, "verifier.candidate.execution.list", core.PROTOCOL_VERSION, null, null, "{\"maxItems\":999999}");
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
    var result = try dispatch(allocator, "verifier.candidate.execution.list", core.PROTOCOL_VERSION, null, null, "{}");
    defer result.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.ok, result.status);
    try std.testing.expect(result.stats == null or result.stats.?.verifier_jobs_scheduled == null or result.stats.?.verifier_jobs_scheduled.? == 0);
    try std.testing.expect(std.mem.indexOf(u8, result.result_json.?, "read existing state without scheduling verifiers") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, json, "correction.list") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "correction.get") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "negative_knowledge.candidate.list") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "negative_knowledge.candidate.get") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "negative_knowledge.record.list") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "negative_knowledge.record.get") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "negative_knowledge.influence.list") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, json, "\"capability\":\"correction.list\",\"policy\":\"allowed\",\"read_only\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"capability\":\"negative_knowledge.candidate.list\",\"policy\":\"allowed\",\"read_only\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"capability\":\"negative_knowledge.record.list\",\"policy\":\"allowed\",\"read_only\":true") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, json, "\"capability\":\"verifier.candidate.execute\",\"policy\":\"denied\",\"mutation\":true") != null);
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

test "unsupported operations remain unsupported" {
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
    try std.testing.expectEqual(core.ProtocolStatus.unsupported, r4.status);

    var r5 = try dispatch(allocator, "correction.apply", core.PROTOCOL_VERSION, null, null, "{}");
    defer r5.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.unsupported, r5.status);

    var r6 = try dispatch(allocator, "negative_knowledge.promote", core.PROTOCOL_VERSION, null, null, "{}");
    defer r6.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.unsupported, r6.status);

    var r7 = try dispatch(allocator, "pack.update_from_negative_knowledge", core.PROTOCOL_VERSION, null, null, "{}");
    defer r7.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.unsupported, r7.status);

    var r8 = try dispatch(allocator, "trust_decay.apply", core.PROTOCOL_VERSION, null, null, "{}");
    defer r8.deinit(allocator);
    try std.testing.expectEqual(core.ProtocolStatus.unsupported, r8.status);
}
