// ──────────────────────────────────────────────────────────────────────────
// GIP Dispatch — Request routing and operation execution
// ──────────────────────────────────────────────────────────────────────────

const std = @import("std");
const core = @import("gip_core.zig");
const schema = @import("gip_schema.zig");
const validation = @import("gip_validation.zig");
const conversation_session = @import("conversation_session.zig");
const response_engine = @import("response_engine.zig");

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
    try w.writeAll("\",\"capabilities\":[\"artifact.read\",\"artifact.list\",\"artifact.patch.propose\",\"conversation.turn\"]");
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

    try w.writeAll("{\"capabilities\":[\"artifact.read\",\"artifact.list\",\"artifact.patch.propose\",\"conversation.turn\"]}");

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
    const sessionId = if (obj.get("sessionId")) |s| s.string else null;
    const reasoningLevelStr = if (obj.get("reasoningLevel")) |r| r.string else "balanced";
    const r_level: response_engine.ReasoningLevel = if (std.mem.eql(u8, reasoningLevelStr, "quick"))
        .quick
    else if (std.mem.eql(u8, reasoningLevelStr, "balanced"))
        .balanced
    else if (std.mem.eql(u8, reasoningLevelStr, "deep"))
        .deep
    else if (std.mem.eql(u8, reasoningLevelStr, "max"))
        .max
    else
        .balanced;

    var turn_result = try conversation_session.turn(allocator, .{
        .repo_root = root,
        .session_id = sessionId,
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
    try w.writeAll("{\"sessionId\":\"");
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

        const startLine = if (span.get("startLine")) |v| if (v == .integer) @as(usize, @intCast(v.integer)) else return .{ .status = .rejected, .err = .{ .code = .json_contract_error, .message = "startLine must be int" } } else return .{ .status = .rejected, .err = .{ .code = .missing_required_field, .message = "startLine missing" } };
        const startCol = if (span.get("startCol")) |v| if (v == .integer) @as(usize, @intCast(v.integer)) else return .{ .status = .rejected, .err = .{ .code = .json_contract_error, .message = "startCol must be int" } } else return .{ .status = .rejected, .err = .{ .code = .missing_required_field, .message = "startCol missing" } };
        const endLine = if (span.get("endLine")) |v| if (v == .integer) @as(usize, @intCast(v.integer)) else return .{ .status = .rejected, .err = .{ .code = .json_contract_error, .message = "endLine must be int" } } else return .{ .status = .rejected, .err = .{ .code = .missing_required_field, .message = "endLine missing" } };
        const endCol = if (span.get("endCol")) |v| if (v == .integer) @as(usize, @intCast(v.integer)) else return .{ .status = .rejected, .err = .{ .code = .json_contract_error, .message = "endCol must be int" } } else return .{ .status = .rejected, .err = .{ .code = .missing_required_field, .message = "endCol missing" } };

        if (startLine < last_end_line or (startLine == last_end_line and startCol < last_end_col)) {
            return .{ .status = .rejected, .err = .{ .code = .invalid_patch_span, .message = "edits overlap or are not sorted" } };
        }
        last_end_line = endLine;
        last_end_col = endCol;

        const replacement_val = edit.get("replacement") orelse return .{ .status = .rejected, .err = .{ .code = .missing_required_field, .message = "replacement missing" } };
        if (replacement_val != .string) return .{ .status = .rejected, .err = .{ .code = .json_contract_error, .message = "replacement must be string" } };
        const replacement = replacement_val.string;
        total_bytes += replacement.len;

        if (total_bytes > 512 * 1024) return .{ .status = .rejected, .err = .{ .code = .budget_exhausted, .message = "patch replacement bytes exceed limit" } };

        const span_text = getSpanText(content, startLine, startCol, endLine, endCol) orelse {
            return .{ .status = .rejected, .err = .{ .code = .invalid_patch_span, .message = "span out of bounds or invalid" } };
        };

        if (edit.get("precondition")) |prec_val| {
            if (prec_val == .object) {
                const prec = prec_val.object;
                if (prec.get("expectedText")) |exp_val| {
                    if (exp_val == .string and !std.mem.eql(u8, span_text, exp_val.string)) {
                        return .{ .status = .rejected, .err = .{ .code = .patch_precondition_failed, .message = "expectedText mismatch" } };
                    }
                }
                if (prec.get("expectedHash")) |exp_val| {
                    if (exp_val == .integer) {
                        const file_hash = std.hash.Wyhash.hash(0, content);
                        if (@as(u64, @intCast(exp_val.integer)) != file_hash) {
                            return .{ .status = .rejected, .err = .{ .code = .patch_precondition_failed, .message = "expectedHash mismatch" } };
                        }
                    }
                }
            }
        }
    }

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    try w.writeAll("{\"patchProposal\":{");
    try w.writeAll("\"patchId\":\"prop-");
    try w.print("{d}", .{std.hash.Wyhash.hash(0, body)});
    try w.writeAll("\",\"artifactRef\":\"");
    try writeEscaped(w, path);
    try w.writeAll("\",\"edits\":");
    try std.json.stringify(edits_val, .{}, w);
    try w.writeAll(",\"appliesCleanly\":true,\"previewDiff\":\"");
    try writeEscaped(w, "--- before\n+++ after\n(preview not generated for dry-run stub)");
    try w.writeAll("\",\"conflicts\":[],\"requiresApproval\":true,\"requiresVerification\":true,\"missingObligations\":[],\"nonAuthorizing\":true");
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
        \\      "span": { "startLine": 100000, "startCol": 1, "endLine": 100001, "endCol": 1 },
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

test "artifact.patch.propose successful dry run with nonAuthorizing" {
    const allocator = std.testing.allocator;
    var ws = try PatchTestWorkspace.init(allocator);
    defer ws.deinit();

    const body =
        \\{
        \\  "path": "sample.txt",
        \\  "edits": [
        \\    {
        \\      "span": { "startLine": 1, "startCol": 1, "endLine": 1, "endCol": 5 },
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
    try std.testing.expect(std.mem.indexOf(u8, result.result_json.?, "\"nonAuthorizing\":true") != null);
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
        \\      "span": { "startLine": 1, "startCol": 1, "endLine": 1, "endCol": 5 },
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
        \\      "span": { "startLine": 1, "startCol": 1, "endLine": 1, "endCol": 5 },
        \\      "replacement": "a"
        \\    },
        \\    {
        \\      "span": { "startLine": 1, "startCol": 3, "endLine": 1, "endCol": 8 },
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

test "artifact.patch.propose expectedText mismatch rejected" {
    const allocator = std.testing.allocator;
    var ws = try PatchTestWorkspace.init(allocator);
    defer ws.deinit();

    const body =
        \\{
        \\  "path": "sample.txt",
        \\  "edits": [
        \\    {
        \\      "span": { "startLine": 1, "startCol": 1, "endLine": 1, "endCol": 5 },
        \\      "replacement": "LINE",
        \\      "precondition": { "expectedText": "WRONG" }
        \\    }
        \\  ]
        \\}
    ;

    var result = try dispatchArtifactPatchPropose(allocator, ws.workspace_root, body);
    defer result.deinit(allocator);

    try std.testing.expectEqual(core.ProtocolStatus.rejected, result.status);
    try std.testing.expectEqual(core.ErrorCode.patch_precondition_failed, result.err.?.code);
}

test "artifact.patch.propose expectedHash mismatch rejected" {
    const allocator = std.testing.allocator;
    var ws = try PatchTestWorkspace.init(allocator);
    defer ws.deinit();

    const body =
        \\{
        \\  "path": "sample.txt",
        \\  "edits": [
        \\    {
        \\      "span": { "startLine": 1, "startCol": 1, "endLine": 1, "endCol": 5 },
        \\      "replacement": "LINE",
        \\      "precondition": { "expectedHash": 999999999 }
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

    try bw.writeAll("{\"path\":\"sample.txt\",\"edits\":[{\"span\":{\"startLine\":1,\"startCol\":1,\"endLine\":1,\"endCol\":5},\"replacement\":\"");
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

test "artifact.patch.propose deterministic patchId for same input" {
    const allocator = std.testing.allocator;
    var ws = try PatchTestWorkspace.init(allocator);
    defer ws.deinit();

    const body =
        \\{
        \\  "path": "sample.txt",
        \\  "edits": [
        \\    {
        \\      "span": { "startLine": 1, "startCol": 1, "endLine": 1, "endCol": 5 },
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

    // Extract and compare patchIds
    const json1 = result1.result_json.?;
    const json2 = result2.result_json.?;
    const id1_start = std.mem.indexOf(u8, json1, "\"patchId\":\"prop-") orelse return error.TestUnexpectedResult;
    const id2_start = std.mem.indexOf(u8, json2, "\"patchId\":\"prop-") orelse return error.TestUnexpectedResult;
    const rest1 = json1[id1_start + 14 ..];
    const rest2 = json2[id2_start + 14 ..];
    const end1 = std.mem.indexOfScalar(u8, rest1, '"') orelse return error.TestUnexpectedResult;
    const end2 = std.mem.indexOfScalar(u8, rest2, '"') orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(rest1[0..end1], rest2[0..end2]);
}
