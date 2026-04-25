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
    try w.writeAll("\",\"implemented\":[\"protocol.describe\",\"capabilities.describe\",\"engine.status\",\"conversation.turn\",\"artifact.read\",\"artifact.list\",\"artifact.patch.propose\",\"hypothesis.list\",\"hypothesis.triage\",\"verifier.list\",\"pack.list\",\"pack.inspect\",\"feedback.summary\",\"session.get\"]");
    try w.writeAll(",\"maturity\":{\"hypothesis.list\":\"stateless\",\"hypothesis.triage\":\"stateless\",\"feedback.summary\":\"requires_workspace_metadata\",\"session.get\":\"requires_existing_session\"}");
    try w.writeAll(",\"unsupported\":[\"artifact.patch.apply\",\"artifact.write.propose\",\"artifact.write.apply\",\"artifact.search\",\"conversation.replay\",\"intent.ground\",\"response.evaluate\",\"verifier.run\",\"hypothesis.generate\",\"hypothesis.verifier.schedule\",\"pack.mount\",\"pack.unmount\",\"pack.import\",\"pack.export\",\"pack.distill.list\",\"pack.distill.show\",\"pack.distill.export\",\"feedback.record\",\"feedback.replay\",\"session.create\",\"session.update\",\"session.close\",\"command.run\"]");
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
    try w.writeAll("{\"capability\":\"pack.list\",\"policy\":\"allowed\",\"read_only\":true},");
    try w.writeAll("{\"capability\":\"pack.inspect\",\"policy\":\"allowed\",\"read_only\":true},");
    try w.writeAll("{\"capability\":\"feedback.summary\",\"policy\":\"allowed\",\"read_only\":true},");
    try w.writeAll("{\"capability\":\"session.get\",\"policy\":\"allowed\",\"read_only\":true},");
    try w.writeAll("{\"capability\":\"artifact.patch.apply\",\"policy\":\"requires_approval\",\"mutation\":true},");
    try w.writeAll("{\"capability\":\"verifier.run\",\"policy\":\"allowed\",\"note\":\"not yet implemented\"},");
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
}
