const std = @import("std");
const execution = @import("execution.zig");
const shards = @import("shards.zig");
const verifier_candidates = @import("verifier_candidates.zig");

pub const EXECUTIONS_REL_DIR = "verifier_executions";
pub const EXECUTIONS_FILE_NAME = "verifier_execution_records.jsonl";
pub const SCHEMA_VERSION = "verifier_execution_record.v1";
pub const MAX_EXECUTION_RECORDS_READ: usize = 128;
pub const MAX_EXECUTION_RECORDS_BYTES: usize = 256 * 1024;
const MAX_SNIPPET_BYTES: usize = 1024;

pub const RecordSummary = struct {
    allocator: std.mem.Allocator,
    raw_json: []u8,
    id: []u8,
    candidate_id: []u8,
    status: []u8,

    pub fn deinit(self: *RecordSummary) void {
        self.allocator.free(self.raw_json);
        self.allocator.free(self.id);
        self.allocator.free(self.candidate_id);
        self.allocator.free(self.status);
        self.* = undefined;
    }
};

pub const ListRecordsResult = struct {
    allocator: std.mem.Allocator,
    records: []RecordSummary,
    storage_path: []u8,
    total: usize,
    emitted: usize,
    passed: usize,
    failed: usize,
    timed_out: usize,
    disallowed: usize,
    rejected: usize,
    unknown: usize,
    limit: usize,
    malformed_lines: usize,
    bytes_read: usize,
    truncated: bool,

    pub fn deinit(self: *ListRecordsResult) void {
        for (self.records) |*record| record.deinit();
        self.allocator.free(self.records);
        self.allocator.free(self.storage_path);
        self.* = undefined;
    }
};

pub const GetRecordResult = struct {
    allocator: std.mem.Allocator,
    record: ?RecordSummary,
    storage_path: []u8,
    malformed_lines: usize,
    bytes_read: usize,
    truncated: bool,

    pub fn deinit(self: *GetRecordResult) void {
        if (self.record) |*record| record.deinit();
        self.allocator.free(self.storage_path);
        self.* = undefined;
    }
};

pub const ExecuteResult = struct {
    allocator: std.mem.Allocator,
    record_json: []u8,
    storage_path: ?[]u8 = null,
    status: []const u8,
    executed: bool,
    commands_executed: bool,
    verifiers_executed: bool,
    produced_evidence: bool,
    mutates_state: bool,

    pub fn deinit(self: *ExecuteResult) void {
        self.allocator.free(self.record_json);
        if (self.storage_path) |path| self.allocator.free(path);
        self.* = undefined;
    }
};

pub fn executionsPath(allocator: std.mem.Allocator, project_shard: []const u8) ![]u8 {
    var metadata = try shards.resolveProjectMetadata(allocator, project_shard);
    defer metadata.deinit();
    var paths = try shards.resolvePaths(allocator, metadata.metadata);
    defer paths.deinit();
    return std.fs.path.join(allocator, &.{ paths.root_abs_path, EXECUTIONS_REL_DIR, EXECUTIONS_FILE_NAME });
}

pub fn listExecutionRecords(
    allocator: std.mem.Allocator,
    project_shard: []const u8,
    candidate_filter: ?[]const u8,
    status_filter: ?[]const u8,
    limit: usize,
) !ListRecordsResult {
    const path = try executionsPath(allocator, project_shard);
    errdefer allocator.free(path);

    var records = std.ArrayList(RecordSummary).init(allocator);
    errdefer {
        for (records.items) |*record| record.deinit();
        records.deinit();
    }

    var malformed_lines: usize = 0;
    var bytes_read: usize = 0;
    var truncated = false;
    var total: usize = 0;
    var passed: usize = 0;
    var failed: usize = 0;
    var timed_out: usize = 0;
    var disallowed: usize = 0;
    var rejected: usize = 0;
    var unknown: usize = 0;

    var file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return .{
            .allocator = allocator,
            .records = try records.toOwnedSlice(),
            .storage_path = path,
            .total = 0,
            .emitted = 0,
            .passed = 0,
            .failed = 0,
            .timed_out = 0,
            .disallowed = 0,
            .rejected = 0,
            .unknown = 0,
            .limit = limit,
            .malformed_lines = 0,
            .bytes_read = 0,
            .truncated = false,
        },
        else => return err,
    };
    defer file.close();

    const stat = try file.stat();
    const read_len: usize = @intCast(@min(stat.size, MAX_EXECUTION_RECORDS_BYTES));
    if (stat.size > MAX_EXECUTION_RECORDS_BYTES) truncated = true;
    const bytes = try file.readToEndAlloc(allocator, read_len);
    defer allocator.free(bytes);
    bytes_read = bytes.len;

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0) continue;
        var summary = parseRecordSummary(allocator, line) catch {
            malformed_lines += 1;
            continue;
        };
        errdefer summary.deinit();
        if (candidate_filter) |filter| {
            if (!std.mem.eql(u8, summary.candidate_id, filter)) {
                summary.deinit();
                continue;
            }
        }
        if (status_filter) |filter| {
            if (!std.mem.eql(u8, summary.status, filter)) {
                summary.deinit();
                continue;
            }
        }
        total += 1;
        countStatus(summary.status, &passed, &failed, &timed_out, &disallowed, &rejected, &unknown);
        if (records.items.len < limit) {
            try records.append(summary);
        } else {
            summary.deinit();
        }
    }

    const emitted = records.items.len;
    if (total > emitted) truncated = true;
    return .{
        .allocator = allocator,
        .records = try records.toOwnedSlice(),
        .storage_path = path,
        .total = total,
        .emitted = emitted,
        .passed = passed,
        .failed = failed,
        .timed_out = timed_out,
        .disallowed = disallowed,
        .rejected = rejected,
        .unknown = unknown,
        .limit = limit,
        .malformed_lines = malformed_lines,
        .bytes_read = bytes_read,
        .truncated = truncated,
    };
}

pub fn getExecutionRecord(allocator: std.mem.Allocator, project_shard: []const u8, execution_id: []const u8) !GetRecordResult {
    const path = try executionsPath(allocator, project_shard);
    errdefer allocator.free(path);

    var malformed_lines: usize = 0;
    var bytes_read: usize = 0;
    var truncated = false;

    var file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return .{
            .allocator = allocator,
            .record = null,
            .storage_path = path,
            .malformed_lines = 0,
            .bytes_read = 0,
            .truncated = false,
        },
        else => return err,
    };
    defer file.close();

    const stat = try file.stat();
    const read_len: usize = @intCast(@min(stat.size, MAX_EXECUTION_RECORDS_BYTES));
    if (stat.size > MAX_EXECUTION_RECORDS_BYTES) truncated = true;
    const bytes = try file.readToEndAlloc(allocator, read_len);
    defer allocator.free(bytes);
    bytes_read = bytes.len;

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0) continue;
        var summary = parseRecordSummary(allocator, line) catch {
            malformed_lines += 1;
            continue;
        };
        errdefer summary.deinit();
        if (std.mem.eql(u8, summary.id, execution_id)) {
            return .{
                .allocator = allocator,
                .record = summary,
                .storage_path = path,
                .malformed_lines = malformed_lines,
                .bytes_read = bytes_read,
                .truncated = truncated,
            };
        }
        summary.deinit();
    }

    return .{
        .allocator = allocator,
        .record = null,
        .storage_path = path,
        .malformed_lines = malformed_lines,
        .bytes_read = bytes_read,
        .truncated = truncated,
    };
}

pub fn executeBody(allocator: std.mem.Allocator, body: []const u8, dispatch_workspace_root: ?[]const u8) !ExecuteResult {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.InvalidJson;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidRequest;
    const obj = parsed.value.object;

    const project_shard = getStrAny(obj, &.{ "project_shard", "projectShard" }) orelse return error.MissingProjectShard;
    const candidate_id = getStrAny(obj, &.{ "candidate_id", "candidateId", "id" }) orelse return error.MissingCandidateId;
    const confirm_execute = getBoolAny(obj, &.{ "confirm_execute", "confirmExecute", "approved" }) orelse false;
    const workspace_root_input = getStrAny(obj, &.{ "workspace_root", "workspaceRoot" }) orelse dispatch_workspace_root orelse return error.MissingWorkspaceRoot;

    var listed = try verifier_candidates.listCandidates(allocator, project_shard, verifier_candidates.MAX_CANDIDATES_READ);
    defer listed.deinit();
    const candidate = findCandidate(listed.candidates, candidate_id) orelse {
        return rejectedResult(allocator, project_shard, candidate_id, "rejected", "candidate_not_found", "candidateId was not found in same-shard verifier candidate metadata");
    };

    if (!confirm_execute) {
        return rejectedResult(allocator, project_shard, candidate_id, "rejected", "confirmation_required", "confirmExecute must be true before any verifier candidate execution");
    }
    if (!std.mem.eql(u8, candidate.status, "approved")) {
        return rejectedResult(allocator, project_shard, candidate_id, "rejected", "candidate_not_approved", "only approved verifier candidates may execute");
    }
    if (candidate.argv.len == 0) {
        return rejectedResult(allocator, project_shard, candidate_id, "rejected", "missing_argv", "approved candidate has no argv tokens");
    }

    const workspace_root = try normalizePath(allocator, workspace_root_input);
    defer allocator.free(workspace_root);
    const cwd = try resolveCwd(allocator, workspace_root, getStrAny(obj, &.{ "cwd", "cwdHint" }) orelse "");
    defer allocator.free(cwd);

    const timeout_ms = boundedTimeout(getIntAny(obj, &.{ "timeout_ms", "timeoutMs" }));
    const max_output_bytes = boundedOutput(getIntAny(obj, &.{ "max_output_bytes", "maxOutputBytes" }));
    const step = execution.Step{
        .label = candidate.id,
        .kind = executionKindForArgv(candidate.argv),
        .phase = .@"test",
        .argv = constArgv(candidate.argv),
        .timeout_ms = timeout_ms,
    };
    const options = execution.Options{
        .workspace_root = workspace_root,
        .cwd = cwd,
        .max_output_bytes = max_output_bytes,
    };

    var harness_result = try execution.run(allocator, options, step);
    defer harness_result.deinit(allocator);

    const blocked_before_spawn = harness_result.failure_signal == .disallowed_command or
        harness_result.failure_signal == .workspace_violation or
        harness_result.failure_signal == .spawn_failed and harness_result.exit_code == null;

    const status: []const u8 = if (harness_result.succeeded())
        "passed"
    else if (harness_result.failure_signal == .timed_out)
        "timed_out"
    else if (harness_result.failure_signal == .disallowed_command)
        "disallowed"
    else
        "failed";

    const executed = !blocked_before_spawn;
    const produced_evidence = executed;
    const record_json = try renderExecutionRecord(
        allocator,
        project_shard,
        candidate_id,
        status,
        candidate.argv,
        workspace_root,
        cwd,
        &harness_result,
        executed,
        produced_evidence,
        0,
    );
    errdefer allocator.free(record_json);

    if (!produced_evidence) {
        return .{
            .allocator = allocator,
            .record_json = record_json,
            .status = status,
            .executed = false,
            .commands_executed = false,
            .verifiers_executed = false,
            .produced_evidence = false,
            .mutates_state = false,
        };
    }

    const path = try executionsPath(allocator, project_shard);
    errdefer allocator.free(path);
    const parent = std.fs.path.dirname(path) orelse return error.InvalidPath;
    try std.fs.cwd().makePath(parent);
    var file = try std.fs.createFileAbsolute(path, .{ .read = true, .truncate = false });
    defer file.close();
    const append_offset = try file.getEndPos();
    try file.seekTo(append_offset);

    allocator.free(record_json);
    const persisted_record_json = try renderExecutionRecord(
        allocator,
        project_shard,
        candidate_id,
        status,
        candidate.argv,
        workspace_root,
        cwd,
        &harness_result,
        true,
        true,
        append_offset,
    );
    errdefer allocator.free(persisted_record_json);
    try file.writeAll(persisted_record_json);
    try file.writeAll("\n");

    return .{
        .allocator = allocator,
        .record_json = persisted_record_json,
        .storage_path = path,
        .status = status,
        .executed = true,
        .commands_executed = true,
        .verifiers_executed = true,
        .produced_evidence = true,
        .mutates_state = true,
    };
}

pub fn writeExecuteResultJson(writer: anytype, result: ExecuteResult) !void {
    try writer.writeAll("{\"verifierCandidateExecution\":{\"schemaVersion\":\"");
    try writer.writeAll(SCHEMA_VERSION);
    try writer.writeAll("\",\"status\":\"");
    try writer.writeAll(result.status);
    try writer.writeAll("\",\"executionRecord\":");
    try writer.writeAll(result.record_json);
    try writer.writeAll(",\"executed\":");
    try writer.writeAll(if (result.executed) "true" else "false");
    try writer.writeAll(",\"commandsExecuted\":");
    try writer.writeAll(if (result.commands_executed) "true" else "false");
    try writer.writeAll(",\"verifiersExecuted\":");
    try writer.writeAll(if (result.verifiers_executed) "true" else "false");
    try writer.writeAll(",\"producedEvidence\":");
    try writer.writeAll(if (result.produced_evidence) "true" else "false");
    try writer.writeAll(",\"evidenceCandidate\":");
    try writer.writeAll(if (result.produced_evidence) "true" else "false");
    try writer.writeAll(",\"nonAuthorizing\":true,\"supportGranted\":false,\"proofGranted\":false,\"correctionApplied\":false,\"negativeKnowledgePromoted\":false,\"patchApplied\":false,\"corpusMutation\":false,\"packMutation\":false,\"mutatesState\":");
    try writer.writeAll(if (result.mutates_state) "true" else "false");
    try writer.writeAll(",\"authorityEffect\":\"evidence_candidate\"}}");
}

fn parseRecordSummary(allocator: std.mem.Allocator, line: []const u8) !RecordSummary {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidRecord;
    const obj = parsed.value.object;
    const id = getStrAny(obj, &.{"id"}) orelse return error.InvalidRecord;
    const candidate_id = getStrAny(obj, &.{ "candidateId", "candidate_id" }) orelse return error.InvalidRecord;
    const status = getStrAny(obj, &.{"status"}) orelse "unknown";
    const raw_json = try allocator.dupe(u8, line);
    errdefer allocator.free(raw_json);
    const id_copy = try allocator.dupe(u8, id);
    errdefer allocator.free(id_copy);
    const candidate_id_copy = try allocator.dupe(u8, candidate_id);
    errdefer allocator.free(candidate_id_copy);
    const status_copy = try allocator.dupe(u8, status);
    errdefer allocator.free(status_copy);
    return .{
        .allocator = allocator,
        .raw_json = raw_json,
        .id = id_copy,
        .candidate_id = candidate_id_copy,
        .status = status_copy,
    };
}

fn countStatus(
    status: []const u8,
    passed: *usize,
    failed: *usize,
    timed_out: *usize,
    disallowed: *usize,
    rejected: *usize,
    unknown: *usize,
) void {
    if (std.mem.eql(u8, status, "passed")) {
        passed.* += 1;
    } else if (std.mem.eql(u8, status, "failed")) {
        failed.* += 1;
    } else if (std.mem.eql(u8, status, "timed_out")) {
        timed_out.* += 1;
    } else if (std.mem.eql(u8, status, "disallowed")) {
        disallowed.* += 1;
    } else if (std.mem.eql(u8, status, "rejected")) {
        rejected.* += 1;
    } else {
        unknown.* += 1;
    }
}

fn rejectedResult(allocator: std.mem.Allocator, project_shard: []const u8, candidate_id: []const u8, status: []const u8, reason_code: []const u8, reason: []const u8) !ExecuteResult {
    const record = try renderRejectedRecord(allocator, project_shard, candidate_id, status, reason_code, reason);
    return .{
        .allocator = allocator,
        .record_json = record,
        .status = status,
        .executed = false,
        .commands_executed = false,
        .verifiers_executed = false,
        .produced_evidence = false,
        .mutates_state = false,
    };
}

fn renderRejectedRecord(allocator: std.mem.Allocator, project_shard: []const u8, candidate_id: []const u8, status: []const u8, reason_code: []const u8, reason: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();
    try w.writeByte('{');
    try writeStringField(w, "id", "stateless-verifier-execution-rejection", true);
    try writeStringField(w, "recordType", "verifier_candidate_execution_result", false);
    try writeStringField(w, "schemaVersion", SCHEMA_VERSION, false);
    try writeStringField(w, "projectShard", project_shard, false);
    try writeStringField(w, "candidateId", candidate_id, false);
    try writeStringField(w, "status", status, false);
    try writeStringField(w, "failureSignal", reason_code, false);
    try writeStringField(w, "reason", reason, false);
    try w.writeAll(",\"argv\":[],\"workspaceRoot\":null,\"exitCode\":null,\"durationMs\":0,\"stdoutSnippet\":\"\",\"stderrSnippet\":\"\"");
    try writeAuthorityTail(w, false, false, 0);
    try w.writeByte('}');
    return out.toOwnedSlice();
}

fn renderExecutionRecord(
    allocator: std.mem.Allocator,
    project_shard: []const u8,
    candidate_id: []const u8,
    status: []const u8,
    argv: [][]u8,
    workspace_root: []const u8,
    cwd: []const u8,
    result: *const execution.Result,
    executed: bool,
    produced_evidence: bool,
    append_offset: u64,
) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();
    const record_hash = std.hash.Fnv1a_64.hash(candidate_id) ^ std.hash.Fnv1a_64.hash(status) ^ append_offset;
    const record_id = try std.fmt.allocPrint(allocator, "verifier-execution:{s}:{x:0>16}:{d}", .{ project_shard, record_hash, append_offset });
    defer allocator.free(record_id);

    try w.writeByte('{');
    try writeStringField(w, "id", record_id, true);
    try writeStringField(w, "recordType", "verifier_candidate_execution_result", false);
    try writeStringField(w, "schemaVersion", SCHEMA_VERSION, false);
    try writeStringField(w, "createdAt", "deterministic:append_order", false);
    try writeStringField(w, "projectShard", project_shard, false);
    try writeStringField(w, "candidateId", candidate_id, false);
    try writeStringField(w, "status", status, false);
    try w.writeAll(",\"argv\":");
    try writeStringArray(w, argv);
    try writeStringField(w, "workspaceRoot", workspace_root, false);
    try writeStringField(w, "cwd", cwd, false);
    try w.writeAll(",\"exitCode\":");
    if (result.exit_code) |code| try w.print("{d}", .{code}) else try w.writeAll("null");
    try w.writeAll(",\"durationMs\":");
    try w.print("{d}", .{result.duration_ms});
    try writeStringField(w, "failureSignal", execution.failureSignalName(result.failure_signal), false);
    try writeStringField(w, "stdoutSnippet", clip(result.stdout, MAX_SNIPPET_BYTES), false);
    try writeStringField(w, "stderrSnippet", clip(result.stderr, MAX_SNIPPET_BYTES), false);
    try writeAuthorityTail(w, executed, produced_evidence, append_offset);
    try w.writeByte('}');
    return out.toOwnedSlice();
}

fn writeAuthorityTail(w: anytype, executed: bool, produced_evidence: bool, append_offset: u64) !void {
    try w.writeAll(",\"executed\":");
    try w.writeAll(if (executed) "true" else "false");
    try w.writeAll(",\"commandsExecuted\":");
    try w.writeAll(if (executed) "true" else "false");
    try w.writeAll(",\"verifiersExecuted\":");
    try w.writeAll(if (executed) "true" else "false");
    try w.writeAll(",\"producedEvidence\":");
    try w.writeAll(if (produced_evidence) "true" else "false");
    try w.writeAll(",\"evidenceCandidate\":");
    try w.writeAll(if (produced_evidence) "true" else "false");
    try w.writeAll(",\"nonAuthorizing\":true,\"supportGranted\":false,\"proofGranted\":false,\"proofDischarged\":false,\"treatedAsProof\":false,\"correctionApplied\":false,\"negativeKnowledgePromoted\":false,\"patchApplied\":false,\"corpusMutation\":false,\"packMutation\":false,\"authorityEffect\":\"evidence_candidate\",\"appendOnly\":{\"storage\":\"jsonl\",\"appendOffsetBytes\":");
    try w.print("{d}", .{append_offset});
    try w.writeAll(",\"inPlaceRewrite\":false,\"deletion\":false,\"compaction\":false,\"stableOrdering\":\"file_append_order\"}");
}

fn findCandidate(candidates: []verifier_candidates.CandidateSummary, id: []const u8) ?verifier_candidates.CandidateSummary {
    for (candidates) |candidate| {
        if (std.mem.eql(u8, candidate.id, id)) return candidate;
    }
    return null;
}

fn executionKindForArgv(argv: [][]u8) execution.Kind {
    if (argv.len >= 2 and std.mem.eql(u8, argv[0], "zig") and std.mem.eql(u8, argv[1], "build")) return .zig_build;
    if (argv.len >= 2 and std.mem.eql(u8, argv[0], "zig") and std.mem.eql(u8, argv[1], "run")) return .zig_run;
    return .shell;
}

fn resolveCwd(allocator: std.mem.Allocator, workspace_root: []const u8, requested: []const u8) ![]u8 {
    if (requested.len == 0) return allocator.dupe(u8, workspace_root);
    const candidate = if (std.fs.path.isAbsolute(requested))
        try normalizePath(allocator, requested)
    else
        try std.fs.path.resolve(allocator, &.{ workspace_root, requested });
    errdefer allocator.free(candidate);
    if (!pathWithinRoot(workspace_root, candidate)) return error.WorkspaceEscape;
    return candidate;
}

fn normalizePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fs.path.resolve(allocator, &.{path});
}

fn pathWithinRoot(root: []const u8, path: []const u8) bool {
    return std.mem.eql(u8, root, path) or
        (std.mem.startsWith(u8, path, root) and path.len > root.len and path[root.len] == std.fs.path.sep);
}

fn boundedTimeout(value: ?i64) u32 {
    if (value == null or value.? <= 0) return execution.DEFAULT_TIMEOUT_MS;
    return @min(@as(u32, @intCast(value.?)), execution.MAX_TIMEOUT_MS);
}

fn boundedOutput(value: ?i64) usize {
    if (value == null or value.? <= 0) return execution.DEFAULT_MAX_OUTPUT_BYTES;
    return @min(@as(usize, @intCast(value.?)), execution.DEFAULT_MAX_OUTPUT_BYTES);
}

fn getStrAny(obj: std.json.ObjectMap, names: []const []const u8) ?[]const u8 {
    for (names) |name| {
        const value = obj.get(name) orelse continue;
        if (value == .string) return value.string;
    }
    return null;
}

fn getBoolAny(obj: std.json.ObjectMap, names: []const []const u8) ?bool {
    for (names) |name| {
        const value = obj.get(name) orelse continue;
        if (value == .bool) return value.bool;
    }
    return null;
}

fn getIntAny(obj: std.json.ObjectMap, names: []const []const u8) ?i64 {
    for (names) |name| {
        const value = obj.get(name) orelse continue;
        if (value == .integer) return value.integer;
    }
    return null;
}

fn constArgv(argv: [][]u8) []const []const u8 {
    const ptr: [*]const []const u8 = @ptrCast(argv.ptr);
    return ptr[0..argv.len];
}

fn clip(value: []const u8, max: usize) []const u8 {
    return value[0..@min(value.len, max)];
}

fn writeStringField(w: anytype, name: []const u8, value: []const u8, first: bool) !void {
    if (!first) try w.writeByte(',');
    try w.writeByte('"');
    try w.writeAll(name);
    try w.writeAll("\":");
    try writeJsonString(w, value);
}

fn writeStringArray(w: anytype, values: [][]u8) !void {
    try w.writeByte('[');
    for (values, 0..) |value, i| {
        if (i != 0) try w.writeByte(',');
        try writeJsonString(w, value);
    }
    try w.writeByte(']');
}

fn writeJsonString(w: anytype, value: []const u8) !void {
    try w.writeByte('"');
    for (value) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}

fn setupTestShard(allocator: std.mem.Allocator, project_shard: []const u8) !void {
    var meta = try shards.resolveProjectMetadata(allocator, project_shard);
    defer meta.deinit();
    var paths = try shards.resolvePaths(allocator, meta.metadata);
    defer paths.deinit();
    std.fs.deleteTreeAbsolute(paths.root_abs_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    const candidates_dir = try std.fs.path.join(allocator, &.{ paths.root_abs_path, verifier_candidates.CANDIDATES_REL_DIR });
    defer allocator.free(candidates_dir);
    try std.fs.cwd().makePath(candidates_dir);
}

fn cleanupTestShard(allocator: std.mem.Allocator, project_shard: []const u8) void {
    var meta = shards.resolveProjectMetadata(allocator, project_shard) catch return;
    defer meta.deinit();
    var paths = shards.resolvePaths(allocator, meta.metadata) catch return;
    defer paths.deinit();
    std.fs.deleteTreeAbsolute(paths.root_abs_path) catch {};
}

test "executeBody: unconfirmed execution does not spawn" {
    const allocator = std.testing.allocator;
    const test_project = "test_verifier_exec_unconfirmed_v10";

    try setupTestShard(allocator, test_project);
    defer cleanupTestShard(allocator, test_project);

    const propose_body = try std.fmt.allocPrint(allocator,
        \\{{"projectShard":"{s}","learningLoopPlan":{{"schema_version":"learning_loop_plan.v1","plan_id":"plan.unit","verifier_candidate_refs":[{{"id":"cand_123","source_command_candidate_id":"cmd_1","argv":["echo","hello"],"cwd_hint":"/tmp","reason":"testing","requires_approval":true,"executes_by_default":false}}]}}}}
    , .{test_project});
    defer allocator.free(propose_body);

    var proposed = try verifier_candidates.proposeFromLearningPlanBody(allocator, propose_body);
    defer proposed.deinit();

    // Extract the generated candidate ID
    var parsed_prop = try std.json.parseFromSlice(std.json.Value, allocator, proposed.record_jsons[0], .{});
    defer parsed_prop.deinit();
    const candidate_id = getStrAny(parsed_prop.value.object, &.{"id"}) orelse return error.NoId;

    const req_body = try std.fmt.allocPrint(allocator,
        \\{{"projectShard":"{s}","candidateId":"{s}","confirmExecute":false,"workspaceRoot":"/tmp"}}
    , .{ test_project, candidate_id });
    defer allocator.free(req_body);

    var result = try executeBody(allocator, req_body, null);
    defer result.deinit();

    try std.testing.expectEqual(false, result.executed);
    try std.testing.expectEqual(false, result.commands_executed);
    try std.testing.expectEqualStrings("rejected", result.status);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.record_json, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("confirmation_required", obj.get("failureSignal").?.string);
    try std.testing.expectEqual(false, obj.get("executed").?.bool);
    try std.testing.expectEqual(false, obj.get("producedEvidence").?.bool);
    try std.testing.expectEqual(false, obj.get("proofGranted").?.bool);
    try std.testing.expectEqual(false, obj.get("supportGranted").?.bool);
}

test "executeBody: rejected candidate does not spawn" {
    const allocator = std.testing.allocator;
    const test_project = "test_verifier_exec_rejected_v10";

    try setupTestShard(allocator, test_project);
    defer cleanupTestShard(allocator, test_project);

    const propose_body = try std.fmt.allocPrint(allocator,
        \\{{"projectShard":"{s}","learningLoopPlan":{{"schema_version":"learning_loop_plan.v1","plan_id":"plan.unit","verifier_candidate_refs":[{{"id":"cand_rejected","source_command_candidate_id":"cmd_1","argv":["echo","hello"],"cwd_hint":"/tmp","reason":"testing","requires_approval":true,"executes_by_default":false}}]}}}}
    , .{test_project});
    defer allocator.free(propose_body);

    var proposed = try verifier_candidates.proposeFromLearningPlanBody(allocator, propose_body);
    defer proposed.deinit();

    var parsed_prop = try std.json.parseFromSlice(std.json.Value, allocator, proposed.record_jsons[0], .{});
    defer parsed_prop.deinit();
    const candidate_id = getStrAny(parsed_prop.value.object, &.{"id"}) orelse return error.NoId;

    const review_body = try std.fmt.allocPrint(allocator,
        \\{{"projectShard":"{s}","candidateId":"{s}","reviewDecision":"rejected","reason":"test rejection"}}
    , .{ test_project, candidate_id });
    defer allocator.free(review_body);

    var review_result = try verifier_candidates.reviewBody(allocator, review_body);
    review_result.deinit();

    const req_body = try std.fmt.allocPrint(allocator,
        \\{{"projectShard":"{s}","candidateId":"{s}","confirmExecute":true,"workspaceRoot":"/tmp"}}
    , .{ test_project, candidate_id });
    defer allocator.free(req_body);

    var result = try executeBody(allocator, req_body, null);
    defer result.deinit();

    try std.testing.expectEqual(false, result.executed);
    try std.testing.expectEqual(false, result.commands_executed);
    try std.testing.expectEqualStrings("rejected", result.status);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.record_json, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("candidate_not_approved", obj.get("failureSignal").?.string);
    try std.testing.expectEqual(false, obj.get("executed").?.bool);
}

test "executeBody: execution record is evidence candidate only and proof flags remain false" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;

    const test_project = "test_verifier_exec_evidence_v10";

    try setupTestShard(allocator, test_project);
    defer cleanupTestShard(allocator, test_project);

    const propose_body = try std.fmt.allocPrint(allocator,
        \\{{"projectShard":"{s}","learningLoopPlan":{{"schema_version":"learning_loop_plan.v1","plan_id":"plan.unit","verifier_candidate_refs":[{{"id":"cand_valid","source_command_candidate_id":"cmd_1","argv":["echo","hello"],"cwd_hint":"/tmp","reason":"testing","requires_approval":true,"executes_by_default":false}}]}}}}
    , .{test_project});
    defer allocator.free(propose_body);

    var proposed = try verifier_candidates.proposeFromLearningPlanBody(allocator, propose_body);
    defer proposed.deinit();

    var parsed_prop = try std.json.parseFromSlice(std.json.Value, allocator, proposed.record_jsons[0], .{});
    defer parsed_prop.deinit();
    const candidate_id = getStrAny(parsed_prop.value.object, &.{"id"}) orelse return error.NoId;

    const review_body = try std.fmt.allocPrint(allocator,
        \\{{"projectShard":"{s}","candidateId":"{s}","reviewDecision":"approved","reason":"test approval"}}
    , .{ test_project, candidate_id });
    defer allocator.free(review_body);

    var review_result = try verifier_candidates.reviewBody(allocator, review_body);
    review_result.deinit();

    const workspace_root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(workspace_root);

    const req_body = try std.fmt.allocPrint(allocator,
        \\{{"projectShard":"{s}","candidateId":"{s}","confirmExecute":true,"workspaceRoot":"{s}"}}
    , .{ test_project, candidate_id, workspace_root });
    defer allocator.free(req_body);

    var result = try executeBody(allocator, req_body, null);
    defer result.deinit();

    try std.testing.expectEqual(true, result.executed);
    try std.testing.expectEqual(true, result.commands_executed);
    try std.testing.expectEqual(true, result.produced_evidence);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.record_json, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqual(true, obj.get("executed").?.bool);
    try std.testing.expectEqual(true, obj.get("producedEvidence").?.bool);
    try std.testing.expectEqual(true, obj.get("evidenceCandidate").?.bool);
    try std.testing.expectEqualStrings("evidence_candidate", obj.get("authorityEffect").?.string);
    try std.testing.expectEqual(false, obj.get("proofGranted").?.bool);
    try std.testing.expectEqual(false, obj.get("supportGranted").?.bool);
    try std.testing.expectEqual(true, obj.get("nonAuthorizing").?.bool);

    var out = std.ArrayList(u8).init(allocator);
    defer out.deinit();
    try writeExecuteResultJson(out.writer(), result);

    const parsed_wrapper = try std.json.parseFromSlice(std.json.Value, allocator, out.items, .{});
    defer parsed_wrapper.deinit();
    const wrapper_obj = parsed_wrapper.value.object.get("verifierCandidateExecution").?.object;
    try std.testing.expectEqual(true, wrapper_obj.get("producedEvidence").?.bool);
    try std.testing.expectEqual(true, wrapper_obj.get("evidenceCandidate").?.bool);
    try std.testing.expectEqualStrings("evidence_candidate", wrapper_obj.get("authorityEffect").?.string);
    try std.testing.expectEqual(false, wrapper_obj.get("proofGranted").?.bool);
    try std.testing.expectEqual(false, wrapper_obj.get("supportGranted").?.bool);
    try std.testing.expectEqual(true, wrapper_obj.get("nonAuthorizing").?.bool);
}
