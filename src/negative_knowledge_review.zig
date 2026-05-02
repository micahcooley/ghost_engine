const std = @import("std");
const shards = @import("shards.zig");

pub const SCHEMA_VERSION = "reviewed_negative_knowledge_record.v1";
pub const REVIEWED_NEGATIVE_KNOWLEDGE_REL_DIR = "negative_knowledge";
pub const REVIEWED_NEGATIVE_KNOWLEDGE_FILE_NAME = "reviewed_negative_knowledge.jsonl";
pub const MAX_REVIEWED_NEGATIVE_KNOWLEDGE_READ: usize = 128;
pub const MAX_REVIEWED_NEGATIVE_KNOWLEDGE_BYTES: usize = 256 * 1024;

pub const Decision = enum {
    accepted,
    rejected,

    pub fn parse(text: []const u8) ?Decision {
        if (std.mem.eql(u8, text, "accepted")) return .accepted;
        if (std.mem.eql(u8, text, "rejected")) return .rejected;
        return null;
    }
};

pub const DecisionFilter = enum {
    accepted,
    rejected,
    all,

    pub fn parse(text: []const u8) ?DecisionFilter {
        if (std.mem.eql(u8, text, "accepted")) return .accepted;
        if (std.mem.eql(u8, text, "rejected")) return .rejected;
        if (std.mem.eql(u8, text, "all")) return .all;
        return null;
    }

    pub fn matches(self: DecisionFilter, decision: Decision) bool {
        return switch (self) {
            .accepted => decision == .accepted,
            .rejected => decision == .rejected,
            .all => true,
        };
    }
};

pub const Request = struct {
    project_shard: []const u8,
    decision: Decision,
    reviewer_note: []const u8,
    rejected_reason: ?[]const u8,
    source_candidate_id: []const u8,
    source_correction_review_id: ?[]const u8 = null,
    negative_knowledge_candidate_json: []const u8,
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

pub const ReadWarning = struct {
    line_number: usize,
    reason: []u8,

    pub fn deinit(self: *ReadWarning, allocator: std.mem.Allocator) void {
        allocator.free(self.reason);
        self.* = undefined;
    }
};

pub const ReviewedNegativeKnowledgeRecord = struct {
    id: []u8,
    decision: Decision,
    record_json: []u8,
    line_number: usize,

    pub fn deinit(self: *ReviewedNegativeKnowledgeRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.record_json);
        self.* = undefined;
    }
};

pub const InspectionResult = struct {
    allocator: std.mem.Allocator,
    records: []ReviewedNegativeKnowledgeRecord,
    warnings: []ReadWarning,
    total_read: usize,
    returned_count: usize,
    malformed_lines: usize,
    truncated: bool,
    max_records_hit: bool,
    limit_hit: bool,
    offset: usize,
    limit: usize,
    missing_file: bool,

    pub fn deinit(self: *InspectionResult) void {
        for (self.records) |*record| record.deinit(self.allocator);
        self.allocator.free(self.records);
        for (self.warnings) |*warning| warning.deinit(self.allocator);
        self.allocator.free(self.warnings);
        self.* = undefined;
    }
};

pub const GetResult = struct {
    allocator: std.mem.Allocator,
    record: ?ReviewedNegativeKnowledgeRecord,
    warnings: []ReadWarning,
    total_read: usize,
    malformed_lines: usize,
    truncated: bool,
    max_records_hit: bool,
    missing_file: bool,

    pub fn deinit(self: *GetResult) void {
        if (self.record) |*record| record.deinit(self.allocator);
        for (self.warnings) |*warning| warning.deinit(self.allocator);
        self.allocator.free(self.warnings);
        self.* = undefined;
    }
};

pub fn reviewedNegativeKnowledgePath(allocator: std.mem.Allocator, project_shard: []const u8) ![]u8 {
    var metadata = try shards.resolveProjectMetadata(allocator, project_shard);
    defer metadata.deinit();
    var paths = try shards.resolvePaths(allocator, metadata.metadata);
    defer paths.deinit();
    return std.fs.path.join(allocator, &.{ paths.root_abs_path, REVIEWED_NEGATIVE_KNOWLEDGE_REL_DIR, REVIEWED_NEGATIVE_KNOWLEDGE_FILE_NAME });
}

pub fn reviewAndAppend(allocator: std.mem.Allocator, request: Request) !ReviewResult {
    const path = try reviewedNegativeKnowledgePath(allocator, request.project_shard);
    defer allocator.free(path);
    return reviewAndAppendAtPath(allocator, request, path);
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
    const body_hash = std.hash.Fnv1a_64.hash(request.negative_knowledge_candidate_json) ^ std.hash.Fnv1a_64.hash(request.reviewer_note);
    const id = try std.fmt.allocPrint(allocator, "reviewed-negative-knowledge:{s}:{x:0>16}:{d}", .{ request.project_shard, body_hash, append_offset });
    defer allocator.free(id);

    try w.writeAll("{");
    try writeStringField(w, "id", id, true);
    try writeStringField(w, "schemaVersion", SCHEMA_VERSION, false);
    try writeStringField(w, "createdAt", "deterministic:append_order", false);
    try writeStringField(w, "reviewedAt", "deterministic:append_order", false);
    try writeStringField(w, "projectShard", request.project_shard, false);
    try writeStringField(w, "project_shard", request.project_shard, false);
    try writeStringField(w, "sourceCandidateId", request.source_candidate_id, false);
    try writeStringField(w, "source_candidate_id", request.source_candidate_id, false);
    try w.writeAll(",\"sourceCorrectionReviewId\":");
    if (request.source_correction_review_id) |value| {
        try writeJsonString(w, value);
    } else {
        try w.writeAll("null");
    }
    try w.writeAll(",\"negativeKnowledgeCandidate\":");
    try w.writeAll(request.negative_knowledge_candidate_json);
    try writeStringField(w, "reviewDecision", @tagName(request.decision), false);
    try writeStringField(w, "reviewerNote", request.reviewer_note, false);
    try w.writeAll(",\"rejectedReason\":");
    if (request.decision == .rejected) {
        try writeJsonString(w, request.rejected_reason orelse "");
    } else {
        try w.writeAll("null");
    }
    try w.writeAll(",\"influenceScope\":{\"kind\":\"project_shard\",\"projectShard\":");
    try writeJsonString(w, request.project_shard);
    try w.writeAll(",\"globalScopeSupported\":false}");
    try w.writeAll(",\"futureInfluenceCandidate\":");
    if (request.decision == .accepted) {
        try w.writeAll("{\"status\":\"candidate\",\"kind\":\"reviewed_negative_knowledge_influence_candidate\",\"candidateOnly\":true,\"nonAuthorizing\":true,\"treatedAsProof\":false,\"usedAsEvidence\":false,\"globalPromotion\":false}");
    } else {
        try w.writeAll("null");
    }
    try w.writeAll(",\"nonAuthorizing\":true,\"treatedAsProof\":false,\"usedAsEvidence\":false,\"globalPromotion\":false");
    try w.writeAll(",\"mutationFlags\":{\"corpusMutation\":false,\"packMutation\":false,\"negativeKnowledgeMutation\":true,\"commandsExecuted\":false,\"verifiersExecuted\":false}");
    try w.writeAll(",\"appendOnly\":{\"storage\":\"jsonl\",\"appendOffsetBytes\":");
    try w.print("{d}", .{append_offset});
    try w.writeAll(",\"inPlaceRewrite\":false,\"deletion\":false,\"compaction\":false,\"stableOrdering\":\"file_append_order\"}");
    try w.writeAll("}");
    return out.toOwnedSlice();
}

pub fn listReviewedNegativeKnowledge(
    allocator: std.mem.Allocator,
    project_shard: []const u8,
    decision_filter: DecisionFilter,
    limit: usize,
    offset: usize,
    max_records: usize,
) !InspectionResult {
    const path = try reviewedNegativeKnowledgePath(allocator, project_shard);
    defer allocator.free(path);
    return listReviewedNegativeKnowledgeAtPath(allocator, path, project_shard, decision_filter, limit, offset, max_records);
}

pub fn getReviewedNegativeKnowledge(allocator: std.mem.Allocator, project_shard: []const u8, id: []const u8, max_records: usize) !GetResult {
    const path = try reviewedNegativeKnowledgePath(allocator, project_shard);
    defer allocator.free(path);
    return getReviewedNegativeKnowledgeAtPath(allocator, path, project_shard, id, max_records);
}

pub fn listReviewedNegativeKnowledgeAtPath(
    allocator: std.mem.Allocator,
    abs_path: []const u8,
    project_shard: []const u8,
    decision_filter: DecisionFilter,
    limit: usize,
    offset: usize,
    max_records: usize,
) !InspectionResult {
    var records = std.ArrayList(ReviewedNegativeKnowledgeRecord).init(allocator);
    errdefer {
        for (records.items) |*record| record.deinit(allocator);
        records.deinit();
    }
    var warnings = std.ArrayList(ReadWarning).init(allocator);
    errdefer {
        for (warnings.items) |*warning| warning.deinit(allocator);
        warnings.deinit();
    }

    const data = readReviewedFileBounded(allocator, abs_path, &warnings) catch |err| switch (err) {
        error.FileNotFound => return .{
            .allocator = allocator,
            .records = try records.toOwnedSlice(),
            .warnings = try warnings.toOwnedSlice(),
            .total_read = 0,
            .returned_count = 0,
            .malformed_lines = 0,
            .truncated = false,
            .max_records_hit = false,
            .limit_hit = false,
            .offset = offset,
            .limit = limit,
            .missing_file = true,
        },
        else => return err,
    };
    defer allocator.free(data.bytes);

    var total_read: usize = 0;
    var malformed_lines: usize = 0;
    var matched_seen: usize = 0;
    var emitted: usize = 0;
    var limit_hit = false;
    var max_records_hit = false;
    var line_number: usize = 1;
    var lines = std.mem.splitScalar(u8, data.bytes, '\n');
    while (lines.next()) |raw_line| : (line_number += 1) {
        const line = std.mem.trim(u8, raw_line, " \r\t");
        if (line.len == 0) continue;
        if (total_read >= max_records) {
            max_records_hit = true;
            try appendReadWarning(allocator, &warnings, line_number, "reviewed negative knowledge record read limit reached");
            break;
        }
        total_read += 1;

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch {
            malformed_lines += 1;
            try appendReadWarning(allocator, &warnings, line_number, "malformed reviewed negative knowledge JSONL line ignored");
            continue;
        };
        defer parsed.deinit();

        const obj = valueObject(parsed.value) orelse {
            malformed_lines += 1;
            try appendReadWarning(allocator, &warnings, line_number, "reviewed negative knowledge line was not an object");
            continue;
        };
        const record_shard = getStr(obj, "projectShard") orelse getStr(obj, "project_shard") orelse {
            malformed_lines += 1;
            try appendReadWarning(allocator, &warnings, line_number, "reviewed negative knowledge missing projectShard");
            continue;
        };
        if (!std.mem.eql(u8, record_shard, project_shard)) continue;
        const decision_text = getStr(obj, "reviewDecision") orelse {
            malformed_lines += 1;
            try appendReadWarning(allocator, &warnings, line_number, "reviewed negative knowledge missing reviewDecision");
            continue;
        };
        const decision = Decision.parse(decision_text) orelse {
            malformed_lines += 1;
            try appendReadWarning(allocator, &warnings, line_number, "reviewed negative knowledge had invalid reviewDecision");
            continue;
        };
        if (!decision_filter.matches(decision)) continue;
        if (matched_seen < offset) {
            matched_seen += 1;
            continue;
        }
        matched_seen += 1;
        if (emitted >= limit) {
            limit_hit = true;
            continue;
        }
        try records.append(try duplicateReviewedRecord(allocator, obj, line, decision, line_number));
        emitted += 1;
    }

    return .{
        .allocator = allocator,
        .records = try records.toOwnedSlice(),
        .warnings = try warnings.toOwnedSlice(),
        .total_read = total_read,
        .returned_count = emitted,
        .malformed_lines = malformed_lines,
        .truncated = data.truncated,
        .max_records_hit = max_records_hit or data.truncated,
        .limit_hit = limit_hit,
        .offset = offset,
        .limit = limit,
        .missing_file = false,
    };
}

pub fn getReviewedNegativeKnowledgeAtPath(allocator: std.mem.Allocator, abs_path: []const u8, project_shard: []const u8, id: []const u8, max_records: usize) !GetResult {
    var warnings = std.ArrayList(ReadWarning).init(allocator);
    errdefer {
        for (warnings.items) |*warning| warning.deinit(allocator);
        warnings.deinit();
    }

    const data = readReviewedFileBounded(allocator, abs_path, &warnings) catch |err| switch (err) {
        error.FileNotFound => return .{
            .allocator = allocator,
            .record = null,
            .warnings = try warnings.toOwnedSlice(),
            .total_read = 0,
            .malformed_lines = 0,
            .truncated = false,
            .max_records_hit = false,
            .missing_file = true,
        },
        else => return err,
    };
    defer allocator.free(data.bytes);

    var total_read: usize = 0;
    var malformed_lines: usize = 0;
    var max_records_hit = false;
    var line_number: usize = 1;
    var lines = std.mem.splitScalar(u8, data.bytes, '\n');
    while (lines.next()) |raw_line| : (line_number += 1) {
        const line = std.mem.trim(u8, raw_line, " \r\t");
        if (line.len == 0) continue;
        if (total_read >= max_records) {
            max_records_hit = true;
            try appendReadWarning(allocator, &warnings, line_number, "reviewed negative knowledge record read limit reached");
            break;
        }
        total_read += 1;

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch {
            malformed_lines += 1;
            try appendReadWarning(allocator, &warnings, line_number, "malformed reviewed negative knowledge JSONL line ignored");
            continue;
        };
        defer parsed.deinit();

        const obj = valueObject(parsed.value) orelse {
            malformed_lines += 1;
            try appendReadWarning(allocator, &warnings, line_number, "reviewed negative knowledge line was not an object");
            continue;
        };
        const record_shard = getStr(obj, "projectShard") orelse getStr(obj, "project_shard") orelse {
            malformed_lines += 1;
            try appendReadWarning(allocator, &warnings, line_number, "reviewed negative knowledge missing projectShard");
            continue;
        };
        if (!std.mem.eql(u8, record_shard, project_shard)) continue;
        const record_id = getStr(obj, "id") orelse {
            malformed_lines += 1;
            try appendReadWarning(allocator, &warnings, line_number, "reviewed negative knowledge missing id");
            continue;
        };
        const decision_text = getStr(obj, "reviewDecision") orelse {
            malformed_lines += 1;
            try appendReadWarning(allocator, &warnings, line_number, "reviewed negative knowledge missing reviewDecision");
            continue;
        };
        const decision = Decision.parse(decision_text) orelse {
            malformed_lines += 1;
            try appendReadWarning(allocator, &warnings, line_number, "reviewed negative knowledge had invalid reviewDecision");
            continue;
        };
        if (std.mem.eql(u8, record_id, id)) {
            return .{
                .allocator = allocator,
                .record = try duplicateReviewedRecord(allocator, obj, line, decision, line_number),
                .warnings = try warnings.toOwnedSlice(),
                .total_read = total_read,
                .malformed_lines = malformed_lines,
                .truncated = data.truncated,
                .max_records_hit = max_records_hit or data.truncated,
                .missing_file = false,
            };
        }
    }

    return .{
        .allocator = allocator,
        .record = null,
        .warnings = try warnings.toOwnedSlice(),
        .total_read = total_read,
        .malformed_lines = malformed_lines,
        .truncated = data.truncated,
        .max_records_hit = max_records_hit or data.truncated,
        .missing_file = false,
    };
}

const ReviewedFileBytes = struct {
    bytes: []u8,
    truncated: bool,
};

fn readReviewedFileBounded(allocator: std.mem.Allocator, abs_path: []const u8, warnings: *std.ArrayList(ReadWarning)) !ReviewedFileBytes {
    const file = std.fs.openFileAbsolute(abs_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => return err,
    };
    defer file.close();

    const file_size = try file.getEndPos();
    const read_len: usize = @intCast(@min(file_size, MAX_REVIEWED_NEGATIVE_KNOWLEDGE_BYTES));
    var data = try allocator.alloc(u8, read_len);
    errdefer allocator.free(data);
    const actual = try file.readAll(data);
    if (actual != read_len) data = try allocator.realloc(data, actual);
    const truncated = file_size > MAX_REVIEWED_NEGATIVE_KNOWLEDGE_BYTES;
    if (truncated) try appendReadWarning(allocator, warnings, 0, "reviewed negative knowledge file exceeded bounded read size; later records were not read");
    return .{ .bytes = data, .truncated = truncated };
}

fn duplicateReviewedRecord(allocator: std.mem.Allocator, obj: std.json.ObjectMap, line: []const u8, decision: Decision, line_number: usize) !ReviewedNegativeKnowledgeRecord {
    const id = getStr(obj, "id") orelse return error.InvalidReviewedNegativeKnowledgeRecord;
    return .{
        .id = try allocator.dupe(u8, id),
        .decision = decision,
        .record_json = try allocator.dupe(u8, line),
        .line_number = line_number,
    };
}

fn appendReadWarning(allocator: std.mem.Allocator, warnings: *std.ArrayList(ReadWarning), line_number: usize, reason: []const u8) !void {
    if (warnings.items.len >= 8) return;
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
            else => {
                if (c < 0x20) {
                    try writer.print("\\u{x:0>4}", .{@as(u16, c)});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
    try writer.writeByte('"');
}

test "reviewed negative knowledge append preserves previous records" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, "reviewed_negative_knowledge.jsonl" });
    defer allocator.free(path);

    const req = Request{
        .project_shard = "phase11a",
        .decision = .accepted,
        .reviewer_note = "reviewed",
        .rejected_reason = null,
        .source_candidate_id = "nk:candidate:1",
        .negative_knowledge_candidate_json = "{\"id\":\"nk:candidate:1\",\"kind\":\"failed_hypothesis\"}",
    };
    var first = try reviewAndAppendAtPath(allocator, req, path);
    defer first.deinit();
    var second = try reviewAndAppendAtPath(allocator, req, path);
    defer second.deinit();

    try std.testing.expect(std.mem.indexOf(u8, first.record_json, "\"appendOffsetBytes\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, second.record_json, "\"appendOffsetBytes\":0") == null);
    const data = try tmp.dir.readFileAlloc(allocator, "reviewed_negative_knowledge.jsonl", 16 * 1024);
    defer allocator.free(data);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, data, "\n"));
    try std.testing.expect(std.mem.indexOf(u8, data, "\"nonAuthorizing\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "\"treatedAsProof\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "\"usedAsEvidence\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "\"globalPromotion\":false") != null);
}

test "reviewed negative knowledge list and get tolerate missing and malformed storage" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const missing_path = try std.fs.path.join(allocator, &.{ root, "missing.jsonl" });
    defer allocator.free(missing_path);

    var missing = try listReviewedNegativeKnowledgeAtPath(allocator, missing_path, "phase11a", .all, 10, 0, MAX_REVIEWED_NEGATIVE_KNOWLEDGE_READ);
    defer missing.deinit();
    try std.testing.expect(missing.missing_file);
    try std.testing.expectEqual(@as(usize, 0), missing.returned_count);

    const path = try std.fs.path.join(allocator, &.{ root, "reviewed_negative_knowledge.jsonl" });
    defer allocator.free(path);
    var accepted = try reviewAndAppendAtPath(allocator, .{
        .project_shard = "phase11a",
        .decision = .accepted,
        .reviewer_note = "accepted",
        .rejected_reason = null,
        .source_candidate_id = "nk:candidate:accepted",
        .negative_knowledge_candidate_json = "{\"id\":\"nk:candidate:accepted\"}",
    }, path);
    defer accepted.deinit();
    var rejected = try reviewAndAppendAtPath(allocator, .{
        .project_shard = "phase11a",
        .decision = .rejected,
        .reviewer_note = "rejected",
        .rejected_reason = "not enough evidence",
        .source_candidate_id = "nk:candidate:rejected",
        .negative_knowledge_candidate_json = "{\"id\":\"nk:candidate:rejected\"}",
    }, path);
    defer rejected.deinit();

    var file = try std.fs.openFileAbsolute(path, .{ .mode = .write_only });
    defer file.close();
    try file.seekFromEnd(0);
    try file.writeAll("{malformed reviewed negative knowledge line}\n");

    var all = try listReviewedNegativeKnowledgeAtPath(allocator, path, "phase11a", .all, 10, 0, MAX_REVIEWED_NEGATIVE_KNOWLEDGE_READ);
    defer all.deinit();
    try std.testing.expectEqual(@as(usize, 2), all.returned_count);
    try std.testing.expectEqual(@as(usize, 1), all.malformed_lines);

    var accepted_only = try listReviewedNegativeKnowledgeAtPath(allocator, path, "phase11a", .accepted, 10, 0, MAX_REVIEWED_NEGATIVE_KNOWLEDGE_READ);
    defer accepted_only.deinit();
    try std.testing.expectEqual(@as(usize, 1), accepted_only.returned_count);

    var existing = try getReviewedNegativeKnowledgeAtPath(allocator, path, "phase11a", all.records[0].id, MAX_REVIEWED_NEGATIVE_KNOWLEDGE_READ);
    defer existing.deinit();
    try std.testing.expect(existing.record != null);

    var missing_get = try getReviewedNegativeKnowledgeAtPath(allocator, path, "phase11a", "reviewed-negative-knowledge:missing", MAX_REVIEWED_NEGATIVE_KNOWLEDGE_READ);
    defer missing_get.deinit();
    try std.testing.expect(missing_get.record == null);
    try std.testing.expectEqual(@as(usize, 1), missing_get.malformed_lines);
}
