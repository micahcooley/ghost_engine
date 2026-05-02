const std = @import("std");
const shards = @import("shards.zig");

pub const SCHEMA_VERSION = "reviewed_correction_record.v1";
pub const REVIEWED_CORRECTIONS_REL_DIR = "corrections";
pub const REVIEWED_CORRECTIONS_FILE_NAME = "reviewed_corrections.jsonl";
pub const MAX_REVIEWED_CORRECTIONS_READ: usize = 128;
pub const MAX_REVIEWED_CORRECTIONS_BYTES: usize = 256 * 1024;
pub const MAX_REVIEWED_CORRECTION_WARNINGS: usize = 8;

pub const Decision = enum {
    accepted,
    rejected,

    pub fn parse(text: []const u8) ?Decision {
        if (std.mem.eql(u8, text, "accepted")) return .accepted;
        if (std.mem.eql(u8, text, "rejected")) return .rejected;
        return null;
    }
};

pub const Request = struct {
    project_shard: []const u8,
    decision: Decision,
    reviewer_note: []const u8,
    rejected_reason: ?[]const u8,
    source_candidate_id: []const u8,
    correction_candidate_json: []const u8,
    accepted_learning_outputs_json: []const u8,
};

pub const ReviewResult = struct {
    allocator: std.mem.Allocator,
    record_json: []u8,
    storage_path: []u8,

    pub fn deinit(self: *ReviewResult) void {
        self.allocator.free(self.record_json);
        self.allocator.free(self.storage_path);
        self.* = undefined;
    }
};

pub const InfluenceKind = enum {
    warning,
    penalty,
    require_stronger_evidence,
    require_verifier_candidate,
    suppress_exact_repeat,
    propose_negative_knowledge,
    propose_corpus_update,
    propose_pack_guidance,

    pub fn parse(text: []const u8) ?InfluenceKind {
        inline for (std.meta.fields(InfluenceKind)) |field| {
            if (std.mem.eql(u8, text, field.name)) return @enumFromInt(field.value);
        }
        return null;
    }
};

pub const MutationFlags = struct {
    corpus_mutation: bool = false,
    pack_mutation: bool = false,
    negative_knowledge_mutation: bool = false,
    commands_executed: bool = false,
    verifiers_executed: bool = false,
};

pub const AcceptedCorrectionInfluence = struct {
    id: []u8,
    source_reviewed_correction_id: []u8,
    influence_kind: InfluenceKind,
    reason: []u8,
    applies_to: []u8,
    operation_kind: []u8,
    correction_type: []u8,
    matched_pattern: []u8,
    disputed_output_fingerprint: []u8,
    non_authorizing: bool = true,
    treated_as_proof: bool = false,
    global_promotion: bool = false,
    mutation_flags: MutationFlags = .{},

    pub fn deinit(self: *AcceptedCorrectionInfluence, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.source_reviewed_correction_id);
        allocator.free(self.reason);
        allocator.free(self.applies_to);
        allocator.free(self.operation_kind);
        allocator.free(self.correction_type);
        allocator.free(self.matched_pattern);
        allocator.free(self.disputed_output_fingerprint);
        self.* = undefined;
    }
};

pub const ReadWarning = struct {
    line_number: usize,
    reason: []u8,

    pub fn deinit(self: *ReadWarning, allocator: std.mem.Allocator) void {
        allocator.free(self.reason);
        self.* = undefined;
    }
};

pub const ReadResult = struct {
    allocator: std.mem.Allocator,
    influences: []AcceptedCorrectionInfluence,
    warnings: []ReadWarning,
    records_read: usize,
    accepted_records: usize,
    rejected_records: usize,
    malformed_lines: usize,
    truncated: bool,

    pub fn deinit(self: *ReadResult) void {
        for (self.influences) |*item| item.deinit(self.allocator);
        self.allocator.free(self.influences);
        for (self.warnings) |*warning| warning.deinit(self.allocator);
        self.allocator.free(self.warnings);
        self.* = undefined;
    }
};

pub fn reviewedCorrectionsPath(allocator: std.mem.Allocator, project_shard: []const u8) ![]u8 {
    var metadata = try shards.resolveProjectMetadata(allocator, project_shard);
    defer metadata.deinit();
    var paths = try shards.resolvePaths(allocator, metadata.metadata);
    defer paths.deinit();
    return std.fs.path.join(allocator, &.{ paths.root_abs_path, REVIEWED_CORRECTIONS_REL_DIR, REVIEWED_CORRECTIONS_FILE_NAME });
}

pub fn reviewAndAppend(allocator: std.mem.Allocator, request: Request) !ReviewResult {
    const path = try reviewedCorrectionsPath(allocator, request.project_shard);
    defer allocator.free(path);
    return reviewAndAppendAtPath(allocator, request, path);
}

pub fn readAcceptedInfluences(allocator: std.mem.Allocator, project_shard: []const u8) !ReadResult {
    const path = try reviewedCorrectionsPath(allocator, project_shard);
    defer allocator.free(path);
    return readAcceptedInfluencesAtPath(allocator, path, project_shard, MAX_REVIEWED_CORRECTIONS_READ);
}

pub fn readAcceptedInfluencesAtPath(allocator: std.mem.Allocator, abs_path: []const u8, project_shard: []const u8, max_records: usize) !ReadResult {
    var influences = std.ArrayList(AcceptedCorrectionInfluence).init(allocator);
    errdefer {
        for (influences.items) |*item| item.deinit(allocator);
        influences.deinit();
    }
    var warnings = std.ArrayList(ReadWarning).init(allocator);
    errdefer {
        for (warnings.items) |*warning| warning.deinit(allocator);
        warnings.deinit();
    }

    const file = std.fs.openFileAbsolute(abs_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return .{
            .allocator = allocator,
            .influences = try influences.toOwnedSlice(),
            .warnings = try warnings.toOwnedSlice(),
            .records_read = 0,
            .accepted_records = 0,
            .rejected_records = 0,
            .malformed_lines = 0,
            .truncated = false,
        },
        else => return err,
    };
    defer file.close();

    const file_size = try file.getEndPos();
    const read_len: usize = @intCast(@min(file_size, MAX_REVIEWED_CORRECTIONS_BYTES));
    var data = try allocator.alloc(u8, read_len);
    defer allocator.free(data);
    const actual = try file.readAll(data);
    if (actual != read_len) data = try allocator.realloc(data, actual);
    const truncated = file_size > MAX_REVIEWED_CORRECTIONS_BYTES;
    if (truncated) try appendReadWarning(allocator, &warnings, 0, "reviewed correction file exceeded bounded read size; later records were not read");

    var records_read: usize = 0;
    var accepted_records: usize = 0;
    var rejected_records: usize = 0;
    var malformed_lines: usize = 0;
    var line_number: usize = 1;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw_line| : (line_number += 1) {
        const line = std.mem.trim(u8, raw_line, " \r\t");
        if (line.len == 0) continue;
        if (records_read >= max_records) {
            try appendReadWarning(allocator, &warnings, line_number, "reviewed correction record read limit reached");
            break;
        }
        records_read += 1;

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch {
            malformed_lines += 1;
            try appendReadWarning(allocator, &warnings, line_number, "malformed reviewed correction JSONL line ignored");
            continue;
        };
        defer parsed.deinit();

        const obj = valueObject(parsed.value) orelse {
            malformed_lines += 1;
            try appendReadWarning(allocator, &warnings, line_number, "reviewed correction line was not an object");
            continue;
        };
        const record_shard = getStr(obj, "projectShard") orelse "";
        if (!std.mem.eql(u8, record_shard, project_shard)) continue;
        const decision = getStr(obj, "reviewDecision") orelse {
            malformed_lines += 1;
            try appendReadWarning(allocator, &warnings, line_number, "reviewed correction missing reviewDecision");
            continue;
        };
        if (std.mem.eql(u8, decision, "rejected")) {
            rejected_records += 1;
            continue;
        }
        if (!std.mem.eql(u8, decision, "accepted")) continue;
        accepted_records += 1;

        if (try influenceFromRecord(allocator, obj, line_number)) |influence| {
            try influences.append(influence);
        } else {
            try appendReadWarning(allocator, &warnings, line_number, "accepted reviewed correction did not contain a usable future influence");
        }
    }

    return .{
        .allocator = allocator,
        .influences = try influences.toOwnedSlice(),
        .warnings = try warnings.toOwnedSlice(),
        .records_read = records_read,
        .accepted_records = accepted_records,
        .rejected_records = rejected_records,
        .malformed_lines = malformed_lines,
        .truncated = truncated,
    };
}

fn influenceFromRecord(allocator: std.mem.Allocator, obj: std.json.ObjectMap, line_number: usize) !?AcceptedCorrectionInfluence {
    const record_id = getStr(obj, "id") orelse return null;
    const candidate_value = obj.get("correctionCandidate") orelse return null;
    const candidate = valueObject(candidate_value) orelse return null;
    const operation_kind = getStr(candidate, "originalOperationKind") orelse getStr(candidate, "operationKind") orelse return null;
    if (!std.mem.eql(u8, operation_kind, "corpus.ask")) return null;
    const correction_type = getStr(candidate, "correctionType") orelse return null;

    const kind = influenceKindForCorrection(correction_type) orelse return null;
    const disputed = candidate.get("disputedOutput");
    const disputed_obj = if (disputed) |value| valueObject(value) else null;
    const original_summary = getStr(candidate, "originalRequestSummary");
    const disputed_summary = if (disputed_obj) |d| getStr(d, "summary") else null;
    const disputed_ref = if (disputed_obj) |d| getStr(d, "ref") else null;
    const user_correction = getStr(candidate, "userCorrection");
    const pattern = firstNonEmpty(&.{ disputed_summary, original_summary, disputed_ref, user_correction }) orelse return null;
    const fingerprint = try std.fmt.allocPrint(allocator, "fnv1a64:{x:0>16}", .{std.hash.Fnv1a_64.hash(pattern)});
    errdefer allocator.free(fingerprint);
    const id = try std.fmt.allocPrint(allocator, "correction-influence:{x:0>16}:{d}", .{ std.hash.Fnv1a_64.hash(record_id) ^ std.hash.Fnv1a_64.hash(pattern), line_number });
    errdefer allocator.free(id);

    return .{
        .id = id,
        .source_reviewed_correction_id = try allocator.dupe(u8, record_id),
        .influence_kind = kind,
        .reason = try allocator.dupe(u8, influenceReason(kind, correction_type)),
        .applies_to = try allocator.dupe(u8, "corpus.ask"),
        .operation_kind = try allocator.dupe(u8, operation_kind),
        .correction_type = try allocator.dupe(u8, correction_type),
        .matched_pattern = try allocator.dupe(u8, pattern),
        .disputed_output_fingerprint = fingerprint,
    };
}

fn influenceKindForCorrection(correction_type: []const u8) ?InfluenceKind {
    if (std.mem.eql(u8, correction_type, "wrong_answer")) return .suppress_exact_repeat;
    if (std.mem.eql(u8, correction_type, "bad_evidence")) return .require_stronger_evidence;
    if (std.mem.eql(u8, correction_type, "missing_evidence")) return .require_verifier_candidate;
    if (std.mem.eql(u8, correction_type, "repeated_failed_pattern")) return .propose_negative_knowledge;
    if (std.mem.eql(u8, correction_type, "outdated_corpus")) return .propose_corpus_update;
    if (std.mem.eql(u8, correction_type, "misleading_rule")) return .propose_pack_guidance;
    if (std.mem.eql(u8, correction_type, "unsafe_candidate")) return .warning;
    return null;
}

fn influenceReason(kind: InfluenceKind, correction_type: []const u8) []const u8 {
    _ = correction_type;
    return switch (kind) {
        .warning => "accepted reviewed correction warns on a repeated disputed output pattern",
        .penalty => "accepted reviewed correction ranks a repeated disputed pattern lower",
        .require_stronger_evidence => "accepted reviewed correction requires stronger exact evidence before drafting",
        .require_verifier_candidate => "accepted reviewed correction requires an explicit verifier/check candidate before support changes",
        .suppress_exact_repeat => "accepted reviewed correction suppresses an exact repeated bad answer pattern",
        .propose_negative_knowledge => "accepted reviewed correction proposes negative knowledge candidate only",
        .propose_corpus_update => "accepted reviewed correction proposes corpus update candidate only",
        .propose_pack_guidance => "accepted reviewed correction proposes pack guidance candidate only",
    };
}

fn appendReadWarning(allocator: std.mem.Allocator, warnings: *std.ArrayList(ReadWarning), line_number: usize, reason: []const u8) !void {
    if (warnings.items.len >= MAX_REVIEWED_CORRECTION_WARNINGS) return;
    try warnings.append(.{
        .line_number = line_number,
        .reason = try allocator.dupe(u8, reason),
    });
}

fn valueObject(value: std.json.Value) ?std.json.ObjectMap {
    return switch (value) {
        .object => value.object,
        else => null,
    };
}

fn getStr(obj: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = obj.get(name) orelse return null;
    return switch (value) {
        .string => value.string,
        else => null,
    };
}

fn firstNonEmpty(values: []const ?[]const u8) ?[]const u8 {
    for (values) |maybe| {
        const value = maybe orelse continue;
        if (std.mem.trim(u8, value, " \r\n\t").len != 0) return value;
    }
    return null;
}

pub fn reviewAndAppendAtPath(allocator: std.mem.Allocator, request: Request, abs_path: []const u8) !ReviewResult {
    const parent = std.fs.path.dirname(abs_path) orelse return error.InvalidPath;
    try std.fs.cwd().makePath(parent);

    var file = try std.fs.createFileAbsolute(abs_path, .{
        .read = true,
        .truncate = false,
    });
    defer file.close();
    const append_offset = try file.getEndPos();
    try file.seekTo(append_offset);

    const record_json = try renderRecordJson(allocator, request, append_offset);
    errdefer allocator.free(record_json);
    try file.writeAll(record_json);
    try file.writeAll("\n");

    return .{
        .allocator = allocator,
        .record_json = record_json,
        .storage_path = try allocator.dupe(u8, abs_path),
    };
}

pub fn renderRecordJson(allocator: std.mem.Allocator, request: Request, append_offset: u64) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();
    const body_hash = std.hash.Fnv1a_64.hash(request.correction_candidate_json) ^ std.hash.Fnv1a_64.hash(request.reviewer_note);
    const id = try std.fmt.allocPrint(allocator, "reviewed-correction:{s}:{x:0>16}:{d}", .{ request.project_shard, body_hash, append_offset });
    defer allocator.free(id);

    try w.writeAll("{");
    try writeStringField(w, "id", id, true);
    try writeStringField(w, "schemaVersion", SCHEMA_VERSION, false);
    try writeStringField(w, "createdAt", "deterministic:append_order", false);
    try writeStringField(w, "reviewedAt", "deterministic:append_order", false);
    try writeStringField(w, "projectShard", request.project_shard, false);
    try writeStringField(w, "sourceCorrectionCandidateId", request.source_candidate_id, false);
    try w.writeAll(",\"correctionCandidate\":");
    try w.writeAll(request.correction_candidate_json);
    try writeStringField(w, "reviewDecision", @tagName(request.decision), false);
    try writeStringField(w, "reviewerNote", request.reviewer_note, false);
    try w.writeAll(",\"acceptedLearningOutputs\":");
    if (request.decision == .accepted) {
        try w.writeAll(request.accepted_learning_outputs_json);
    } else {
        try w.writeAll("[]");
    }
    try w.writeAll(",\"rejectedReason\":");
    if (request.decision == .rejected) {
        try writeJsonString(w, request.rejected_reason orelse "");
    } else {
        try w.writeAll("null");
    }
    try w.writeAll(",\"futureBehaviorCandidate\":");
    if (request.decision == .accepted) {
        try w.writeAll("{");
        try writeStringField(w, "status", "candidate", true);
        try writeStringField(w, "kind", "reviewed_correction_influence_candidate", false);
        try writeStringField(w, "summary", "accepted reviewed correction may warn on repeated bad answer patterns or require stronger evidence in a later explicit lifecycle", false);
        try w.writeAll(",\"candidateOnly\":true,\"nonAuthorizing\":true,\"treatedAsProof\":false,\"globalPromotion\":false");
        try w.writeAll("}");
    } else {
        try w.writeAll("null");
    }
    try w.writeAll(",\"nonAuthorizing\":true,\"treatedAsProof\":false,\"globalPromotion\":false");
    try w.writeAll(",\"commandsExecuted\":false,\"verifiersExecuted\":false,\"corpusMutation\":false,\"packMutation\":false,\"negativeKnowledgeMutation\":false");
    try w.writeAll(",\"appendOnly\":{\"storage\":\"jsonl\",\"appendOffsetBytes\":");
    try w.print("{d}", .{append_offset});
    try w.writeAll(",\"inPlaceRewrite\":false,\"deletion\":false,\"compaction\":false,\"stableOrdering\":\"file_append_order\"}");
    try w.writeAll("}");
    return out.toOwnedSlice();
}

fn writeStringField(writer: anytype, name: []const u8, value: []const u8, first: bool) !void {
    if (!first) try writer.writeByte(',');
    try writer.writeByte('"');
    try writer.writeAll(name);
    try writer.writeAll("\":");
    try writeJsonString(writer, value);
}

fn writeJsonString(writer: anytype, text: []const u8) !void {
    try writer.writeByte('"');
    for (text) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(c),
        }
    }
    try writer.writeByte('"');
}

test "reviewed correction append preserves prior records" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, "reviewed.jsonl" });
    defer allocator.free(path);

    const req = Request{
        .project_shard = "phase7",
        .decision = .accepted,
        .reviewer_note = "reviewed",
        .rejected_reason = null,
        .source_candidate_id = "correction:candidate:1",
        .correction_candidate_json = "{\"id\":\"correction:candidate:1\"}",
        .accepted_learning_outputs_json = "[{\"kind\":\"verifier_check_candidate\"}]",
    };
    var first = try reviewAndAppendAtPath(allocator, req, path);
    defer first.deinit();
    var second = try reviewAndAppendAtPath(allocator, req, path);
    defer second.deinit();
    try std.testing.expect(std.mem.indexOf(u8, first.record_json, "\"appendOffsetBytes\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, second.record_json, "\"appendOffsetBytes\":0") == null);

    const data = try tmp.dir.readFileAlloc(allocator, "reviewed.jsonl", 16 * 1024);
    defer allocator.free(data);
    try std.testing.expect(std.mem.count(u8, data, "\n") == 2);
    try std.testing.expect(std.mem.indexOf(u8, data, "\"nonAuthorizing\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "\"treatedAsProof\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "\"globalPromotion\":false") != null);
}

test "rejected reviewed correction records rejected reason and no future influence" {
    const allocator = std.testing.allocator;
    const json = try renderRecordJson(allocator, .{
        .project_shard = "phase7",
        .decision = .rejected,
        .reviewer_note = "not valid",
        .rejected_reason = "overfit",
        .source_candidate_id = "correction:candidate:2",
        .correction_candidate_json = "{\"id\":\"correction:candidate:2\"}",
        .accepted_learning_outputs_json = "[]",
    }, 0);
    defer allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"reviewDecision\":\"rejected\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"rejectedReason\":\"overfit\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"futureBehaviorCandidate\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"negativeKnowledgeMutation\":false") != null);
}

test "read accepted reviewed correction influences tolerates missing malformed and rejected records" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const missing_path = try std.fs.path.join(allocator, &.{ root, "missing.jsonl" });
    defer allocator.free(missing_path);

    var missing = try readAcceptedInfluencesAtPath(allocator, missing_path, "phase8", MAX_REVIEWED_CORRECTIONS_READ);
    defer missing.deinit();
    try std.testing.expectEqual(@as(usize, 0), missing.influences.len);
    try std.testing.expectEqual(@as(usize, 0), missing.records_read);

    const path = try std.fs.path.join(allocator, &.{ root, "reviewed.jsonl" });
    defer allocator.free(path);
    const accepted = try renderRecordJson(allocator, .{
        .project_shard = "phase8",
        .decision = .accepted,
        .reviewer_note = "accepted",
        .rejected_reason = null,
        .source_candidate_id = "correction:candidate:accepted",
        .correction_candidate_json =
        \\{"id":"correction:candidate:accepted","originalOperationKind":"corpus.ask","originalRequestSummary":"retention policy enabled","disputedOutput":{"kind":"answerDraft","summary":"Draft answer from corpus evidence: Retention policy is enabled"},"userCorrection":"the retention answer was wrong","correctionType":"wrong_answer"}
        ,
        .accepted_learning_outputs_json = "[{\"kind\":\"verifier_check_candidate\"}]",
    }, 0);
    defer allocator.free(accepted);
    const rejected = try renderRecordJson(allocator, .{
        .project_shard = "phase8",
        .decision = .rejected,
        .reviewer_note = "rejected",
        .rejected_reason = "not a real issue",
        .source_candidate_id = "correction:candidate:rejected",
        .correction_candidate_json =
        \\{"id":"correction:candidate:rejected","originalOperationKind":"corpus.ask","originalRequestSummary":"retention policy enabled","disputedOutput":{"kind":"answerDraft","summary":"Draft answer from corpus evidence: Retention policy is enabled"},"userCorrection":"ignore","correctionType":"wrong_answer"}
        ,
        .accepted_learning_outputs_json = "[]",
    }, accepted.len + 1);
    defer allocator.free(rejected);

    var file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll("{malformed json}\n");
    try file.writeAll(rejected);
    try file.writeAll("\n");
    try file.writeAll(accepted);
    try file.writeAll("\n");

    var read = try readAcceptedInfluencesAtPath(allocator, path, "phase8", MAX_REVIEWED_CORRECTIONS_READ);
    defer read.deinit();
    try std.testing.expectEqual(@as(usize, 1), read.influences.len);
    try std.testing.expectEqual(@as(usize, 3), read.records_read);
    try std.testing.expectEqual(@as(usize, 1), read.accepted_records);
    try std.testing.expectEqual(@as(usize, 1), read.rejected_records);
    try std.testing.expectEqual(@as(usize, 1), read.malformed_lines);
    try std.testing.expectEqual(InfluenceKind.suppress_exact_repeat, read.influences[0].influence_kind);
    try std.testing.expectEqualStrings("corpus.ask", read.influences[0].applies_to);
    try std.testing.expect(read.influences[0].non_authorizing);
    try std.testing.expect(!read.influences[0].treated_as_proof);
    try std.testing.expect(!read.influences[0].global_promotion);
    try std.testing.expect(!read.influences[0].mutation_flags.corpus_mutation);

    var other_shard = try readAcceptedInfluencesAtPath(allocator, path, "other-phase8", MAX_REVIEWED_CORRECTIONS_READ);
    defer other_shard.deinit();
    try std.testing.expectEqual(@as(usize, 0), other_shard.influences.len);
}
