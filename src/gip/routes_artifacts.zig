const std = @import("std");
const core = @import("../gip_core.zig");
const sys = @import("../sys.zig");
const gip = @import("../gip.zig");
const ghost_state = @import("../ghost_state.zig");
const config = @import("../config.zig");
const knowledge_pack_store = @import("../knowledge_pack_store.zig");
const artifact_autopsy = @import("../artifact_autopsy.zig");
const validation = @import("../gip_validation.zig");
const artifact_policy = @import("../artifact_policy.zig");
const schema = @import("../gip_schema.zig");
const gip_utils = @import("utils.zig");
const writeEscaped = gip_utils.writeEscaped;
const getInt = gip_utils.getInt;
const getStr = gip_utils.getStr;
const getSpanText = gip_utils.getSpanText;

const DispatchResult = @import("../gip_dispatch.zig").DispatchResult;

pub fn dispatchArtifactRead(allocator: std.mem.Allocator, workspace_root: ?[]const u8, request_path: ?[]const u8) !DispatchResult {
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

pub fn dispatchArtifactList(allocator: std.mem.Allocator, workspace_root: ?[]const u8, request_path: ?[]const u8) !DispatchResult {
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

pub fn dispatchArtifactPolicyDescribe(allocator: std.mem.Allocator) !DispatchResult {
    const summary = artifact_policy.codeProfileSummary();
    const inner_json = try summary.toJson(allocator);
    defer allocator.free(inner_json);

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    try w.writeAll("{\"artifactPolicy\":");
    try w.writeAll(inner_json);
    try w.writeAll(",\"readOnly\":true,\"mutatesState\":false,\"commandsExecuted\":false,\"verifiersExecuted\":false,\"non_authorizing\":true}");

    var gip_state = schema.draftResultState();
    gip_state.permission = .none;
    gip_state.verification_state = .unverified;
    gip_state.support_minimum_met = false;
    gip_state.stop_reason = .none;
    gip_state.unresolved_reason = null;
    gip_state.non_authorization_notice = "artifact.policy.describe is a read-only metadata inspection operation; it does not grant proof or support";

    return .{
        .status = .ok,
        .result_state = gip_state,
        .result_json = try out.toOwnedSlice(),
        .allocated_result = true,
    };
}

pub fn dispatchArtifactPatchPropose(allocator: std.mem.Allocator, workspace_root: ?[]const u8, request_body: ?[]const u8) !DispatchResult {
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

pub fn dispatchArtifactAutopsyInspect(allocator: std.mem.Allocator, workspace_root: ?[]const u8, request_body: ?[]const u8) !DispatchResult {
    var domain: artifact_autopsy.ArtifactDomain = .documentation_audit;
    var artifact_paths = std.ArrayList([]const u8).init(allocator);
    defer {
        for (artifact_paths.items) |p| allocator.free(p);
        artifact_paths.deinit();
    }

    if (request_body) |body| {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
            return .{ .status = .rejected, .err = .{ .code = .json_contract_error, .message = "invalid JSON in request body" } };
        };
        defer parsed.deinit();

        if (parsed.value == .object) {
            const obj = parsed.value.object;
            if (getStr(obj, "domain", "domain")) |d| {
                if (std.mem.eql(u8, d, "documentation_audit")) {
                    domain = .documentation_audit;
                } else if (std.mem.eql(u8, d, "recipe_consistency")) {
                    domain = .recipe_consistency;
                } else {
                    return .{ .status = .rejected, .err = .{ .code = .invalid_request, .message = "unknown domain", .details = d } };
                }
            }

            if (obj.get("artifactPaths") orelse obj.get("artifact_paths")) |paths_val| {
                if (paths_val == .array) {
                    for (paths_val.array.items) |p_val| {
                        if (p_val == .string) {
                            try artifact_paths.append(try allocator.dupe(u8, p_val.string));
                        } else {
                            return .{ .status = .rejected, .err = .{ .code = .invalid_request, .message = "artifactPaths must be strings" } };
                        }
                    }
                } else {
                    return .{ .status = .rejected, .err = .{ .code = .invalid_request, .message = "artifactPaths must be an array" } };
                }
            }
        } else {
            return .{ .status = .rejected, .err = .{ .code = .invalid_request, .message = "artifact.autopsy.inspect request must be a JSON object" } };
        }
    }

    if (artifact_paths.items.len > artifact_autopsy.MAX_FILES) {
        return .{ .status = .rejected, .err = .{ .code = .invalid_request, .message = "too many files provided in artifactPaths" } };
    }

    if (artifact_paths.items.len > 0 and workspace_root == null) {
        return .{ .status = .rejected, .err = .{ .code = .missing_required_field, .message = "workspace root is required for bounded file autopsy when artifactPaths are provided" } };
    }

    // Run file-backed analysis in a sub-arena so all analysis allocations
    // (file content, duped paths, ArrayLists) are freed together after
    // stringification into the main allocator output buffer.
    var analysis_arena = std.heap.ArenaAllocator.init(allocator);
    defer analysis_arena.deinit();
    const analysis_alloc = analysis_arena.allocator();

    const result = if (domain == .recipe_consistency)
        artifact_autopsy.recipeConsistency(analysis_alloc, workspace_root orelse ".", artifact_paths.items)
    else
        artifact_autopsy.documentationAudit(analysis_alloc, workspace_root orelse ".", artifact_paths.items);

    const autopsy_result = result catch |err| switch (err) {
        error.TooManyFiles => return .{ .status = .rejected, .err = .{ .code = .invalid_request, .message = "too many files provided in artifactPaths" } },
        error.EmptyPathRejected => return .{ .status = .rejected, .err = .{ .code = .invalid_request, .message = "empty paths are rejected for artifact autopsy" } },
        error.AbsolutePathRejected => return .{ .status = .rejected, .err = .{ .code = .invalid_request, .message = "absolute paths are rejected for artifact autopsy" } },
        error.PathTraversalRejected => return .{ .status = .rejected, .err = .{ .code = .invalid_request, .message = "path traversal is rejected for artifact autopsy" } },
        error.DirectoryRejected => return .{ .status = .rejected, .err = .{ .code = .invalid_request, .message = "directory paths are rejected for artifact autopsy" } },
        error.SymlinkRejected => return .{ .status = .rejected, .err = .{ .code = .invalid_request, .message = "symlink paths are rejected for artifact autopsy" } },
        error.FileTooLarge => return .{ .status = .rejected, .err = .{ .code = .invalid_request, .message = "file too large for artifact autopsy" } },
        error.TotalBytesExceeded => return .{ .status = .rejected, .err = .{ .code = .invalid_request, .message = "total bytes exceeded for artifact autopsy" } },
        error.WorkspaceNotFound => return .{ .status = .rejected, .err = .{ .code = .path_not_found, .message = "workspace root not found" } },
        else => return err,
    };

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    try w.writeAll("{\"artifactAutopsyInspect\":");
    try std.json.stringify(autopsy_result, .{}, w);
    try w.writeAll(",\"readOnly\":true,\"mutatesState\":false,\"commandsExecuted\":false,\"verifiersExecuted\":false,\"supportGranted\":false,\"proofGranted\":false,\"non_authorizing\":true");
    // v1 contract fields in envelope for consumer discoverability
    try w.print(",\"autopsy_schema_version\":\"{s}\"", .{autopsy_result.autopsy_schema_version});
    try w.print(",\"artifact_autopsy_contract\":\"{s}\"", .{autopsy_result.artifact_autopsy_contract});
    try w.print(",\"route_kind\":\"{s}\"", .{autopsy_result.route_kind});
    try w.print(",\"fixture_backed\":{}", .{autopsy_result.fixture_backed});
    try w.print(",\"file_backed\":{}", .{autopsy_result.file_backed});
    try w.print(",\"product_ready\":{}", .{autopsy_result.product_ready});
    try w.writeAll("}");

    // analysis_arena.deinit() called by defer above; result slices are gone.
    // out buffer (owned by main allocator) contains the serialized output.

    var gip_state = schema.draftResultState();
    gip_state.permission = .none;
    gip_state.verification_state = .unverified;
    gip_state.support_minimum_met = false;
    gip_state.non_authorization_notice = "artifact.autopsy.inspect output is candidate-only and non-authorizing; no verifier was executed and no proof/support gate was discharged";

    return .{
        .status = .ok,
        .result_state = gip_state,
        .result_json = try out.toOwnedSlice(),
        .allocated_result = true,
    };
}

