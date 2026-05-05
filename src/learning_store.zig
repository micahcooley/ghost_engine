const std = @import("std");
const shards = @import("shards.zig");
const correction_review = @import("correction_review.zig");

const corpus_ask = @import("corpus_ask.zig");
const rule_reasoning = @import("rule_reasoning.zig");

pub fn evaluateCandidate(
    allocator: std.mem.Allocator,
    project_shard: []const u8,
    candidate_id: []const u8,
    candidate_kind: []const u8,
    proposed_action: []const u8,
    reason: []const u8,
) !corpus_ask.SelfReview {
    var review = corpus_ask.SelfReview{ .status = .passed };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const temp_alloc = arena.allocator();

    var metadata = try shards.resolveProjectMetadata(temp_alloc, project_shard);
    defer metadata.deinit();
    var paths = try shards.resolvePaths(temp_alloc, metadata.metadata);
    defer paths.deinit();

    const rules_path = try std.fs.path.join(temp_alloc, &.{ paths.root_abs_path, "rules.jsonl" });

    const rules_text = std.fs.cwd().readFileAlloc(temp_alloc, rules_path, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return review,
        else => return err,
    };

    var rules_json = std.ArrayList(u8).init(temp_alloc);
    try rules_json.appendSlice("{\"facts\":[],\"rules\":[");
    var line_iter = std.mem.splitScalar(u8, rules_text, '\n');
    var first = true;
    while (line_iter.next()) |line| {
        const t = std.mem.trim(u8, line, " \r\t");
        if (t.len == 0) continue;
        if (!first) try rules_json.appendSlice(",");
        try rules_json.appendSlice(t);
        first = false;
    }
    try rules_json.appendSlice("]}");

    const parsed = std.json.parseFromSlice(std.json.Value, temp_alloc, rules_json.items, .{}) catch return review;

    var rule_req = rule_reasoning.parseRequest(temp_alloc, parsed.value) catch return review;

    var facts = std.ArrayList(rule_reasoning.Fact).init(temp_alloc);
    try facts.append(.{ .subject = candidate_id, .predicate = "is_a", .object = candidate_kind });
    try facts.append(.{ .subject = candidate_id, .predicate = "proposes", .object = proposed_action });
    try facts.append(.{ .subject = candidate_id, .predicate = "reason", .object = reason });
    rule_req.facts = facts.items;

    const eval_res = rule_reasoning.evaluate(temp_alloc, rule_req) catch return review;

    var matching = std.ArrayList([]u8).init(allocator);
    errdefer {
        for (matching.items) |i| allocator.free(i);
        matching.deinit();
    }
    var contradictions = std.ArrayList([]u8).init(allocator);
    errdefer {
        for (contradictions.items) |i| allocator.free(i);
        contradictions.deinit();
    }
    var failed = false;

    for (eval_res.fired_rules) |fr| {
        try matching.append(try allocator.dupe(u8, fr.id));
    }
    for (eval_res.emitted_candidates) |c| {
        failed = true;
        try contradictions.append(try allocator.dupe(u8, c.summary));
    }

    review.status = if (failed) .failed else .passed;
    review.matching_rules = try matching.toOwnedSlice();
    review.unresolved_contradictions = try contradictions.toOwnedSlice();

    return review;
}

pub const SCHEMA_VERSION = "reviewed_learning_record.v1";
pub const LEARNING_REL_DIR = "learning";
pub const LEARNED_RECORDS_FILE_NAME = "learned_records.jsonl";
pub const MAX_LEARNED_RECORDS_READ: usize = 128;
pub const MAX_LEARNED_RECORDS_BYTES: usize = 256 * 1024;
pub const MAX_LEARNED_RECORD_WARNINGS: usize = 8;

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
    learning_candidate_id: []const u8,
    decision: Decision,
    reviewer_note: []const u8,
    learning_candidate_json: ?[]const u8 = null,
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

pub const ConflictResult = struct {
    allocator: std.mem.Allocator,
    established_record_ids: [][]u8,
    reason: []u8,

    pub fn deinit(self: *ConflictResult) void {
        for (self.established_record_ids) |id| self.allocator.free(id);
        self.allocator.free(self.established_record_ids);
        self.allocator.free(self.reason);
        self.* = undefined;
    }
};

pub const ReviewOutcome = union(enum) {
    appended: ReviewResult,
    conflict: ConflictResult,

    pub fn deinit(self: *ReviewOutcome) void {
        switch (self.*) {
            .appended => |*result| result.deinit(),
            .conflict => |*conflict| conflict.deinit(),
        }
        self.* = undefined;
    }
};

pub const ReadWarning = correction_review.ReadWarning;
pub const CountEntry = correction_review.CountEntry;

pub const AcceptedLearningInfluence = struct {
    id: []u8,
    source_reviewed_learning_id: []u8,
    learning_candidate_id: []u8,
    candidate_kind: []u8,
    logic_pattern: []u8,
    reviewer_note: []u8,
    draft_signal: []u8,
    non_authorizing: bool = true,
    treated_as_proof: bool = false,
    used_as_evidence: bool = false,
    global_promotion: bool = false,

    pub fn deinit(self: *AcceptedLearningInfluence, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.source_reviewed_learning_id);
        allocator.free(self.learning_candidate_id);
        allocator.free(self.candidate_kind);
        allocator.free(self.logic_pattern);
        allocator.free(self.reviewer_note);
        allocator.free(self.draft_signal);
        self.* = undefined;
    }
};

pub const ReadResult = struct {
    allocator: std.mem.Allocator,
    influences: []AcceptedLearningInfluence,
    warnings: []ReadWarning,
    records_read: usize,
    accepted_records: usize,
    rejected_records: usize,
    malformed_lines: usize,
    truncated: bool,
    missing_file: bool,

    pub fn deinit(self: *ReadResult) void {
        for (self.influences) |*item| item.deinit(self.allocator);
        self.allocator.free(self.influences);
        for (self.warnings) |*warning| warning.deinit(self.allocator);
        self.allocator.free(self.warnings);
        self.* = undefined;
    }
};

pub const StatusRecord = struct {
    id: []u8,
    decision: Decision,
    candidate_kind: []u8,
    record_json: []u8,
    line_number: usize,

    pub fn deinit(self: *StatusRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.candidate_kind);
        allocator.free(self.record_json);
        self.* = undefined;
    }
};

pub const StatusSummary = struct {
    reviewed_records: usize = 0,
    accepted_records: usize = 0,
    rejected_records: usize = 0,
    malformed_lines: usize = 0,
    candidate_kind_counts: []CountEntry = &.{},
    self_verification_passed: usize = 0,
    self_verification_failed: usize = 0,
    self_verification_ambiguous: usize = 0,

    pub fn deinit(self: *StatusSummary, allocator: std.mem.Allocator) void {
        for (self.candidate_kind_counts) |*entry| entry.deinit(allocator);
        allocator.free(self.candidate_kind_counts);
        self.* = undefined;
    }
};

pub const StatusResult = struct {
    allocator: std.mem.Allocator,
    summary: StatusSummary,
    warnings: []ReadWarning,
    records: []StatusRecord,
    records_read: usize,
    returned_count: usize,
    truncated: bool,
    max_records_hit: bool,
    limit_hit: bool,
    missing_file: bool,

    pub fn deinit(self: *StatusResult) void {
        self.summary.deinit(self.allocator);
        for (self.warnings) |*warning| warning.deinit(self.allocator);
        self.allocator.free(self.warnings);
        for (self.records) |*record| record.deinit(self.allocator);
        self.allocator.free(self.records);
        self.* = undefined;
    }
};

const FileBytes = struct {
    bytes: []u8,
    truncated: bool,
};

pub fn learnedRecordsPath(allocator: std.mem.Allocator, project_shard: []const u8) ![]u8 {
    var metadata = try shards.resolveProjectMetadata(allocator, project_shard);
    defer metadata.deinit();
    var paths = try shards.resolvePaths(allocator, metadata.metadata);
    defer paths.deinit();
    return std.fs.path.join(allocator, &.{ paths.root_abs_path, LEARNING_REL_DIR, LEARNED_RECORDS_FILE_NAME });
}

pub fn reviewAndAppend(allocator: std.mem.Allocator, request: Request) !ReviewOutcome {
    const path = try learnedRecordsPath(allocator, request.project_shard);
    defer allocator.free(path);
    return reviewAndAppendAtPath(allocator, request, path);
}

pub fn reviewAndAppendAtPath(allocator: std.mem.Allocator, request: Request, abs_path: []const u8) !ReviewOutcome {
    const parent = std.fs.path.dirname(abs_path) orelse return error.InvalidPath;
    try std.fs.cwd().makePath(parent);

    if (try detectConflictAtPath(allocator, request, abs_path)) |conflict| {
        return .{ .conflict = conflict };
    }

    var file = try std.fs.createFileAbsolute(abs_path, .{ .read = true, .truncate = false });
    defer file.close();
    const append_offset = try file.getEndPos();
    try file.seekTo(append_offset);

    const record_json = try renderRecordJson(allocator, request, append_offset);
    errdefer allocator.free(record_json);
    try file.writeAll(record_json);
    try file.writeAll("\n");

    return .{ .appended = .{
        .allocator = allocator,
        .record_json = record_json,
        .storage_path = try allocator.dupe(u8, abs_path),
    } };
}

pub fn renderRecordJson(allocator: std.mem.Allocator, request: Request, append_offset: u64) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();
    const body_hash = std.hash.Fnv1a_64.hash(request.learning_candidate_id) ^ std.hash.Fnv1a_64.hash(request.reviewer_note);
    const id = try std.fmt.allocPrint(allocator, "reviewed-learning:{s}:{x:0>16}:{d}", .{ request.project_shard, body_hash, append_offset });
    defer allocator.free(id);

    try w.writeAll("{");
    try writeStringField(w, "id", id, true);
    try writeStringField(w, "schemaVersion", SCHEMA_VERSION, false);
    try writeStringField(w, "createdAt", "deterministic:append_order", false);
    try writeStringField(w, "reviewedAt", "deterministic:append_order", false);
    try writeStringField(w, "projectShard", request.project_shard, false);
    try writeStringField(w, "sourceLearningCandidateId", request.learning_candidate_id, false);
    try w.writeAll(",\"learningCandidate\":");
    if (request.learning_candidate_json) |json| try w.writeAll(json) else try w.writeAll("null");
    try writeStringField(w, "reviewDecision", @tagName(request.decision), false);
    try writeStringField(w, "reviewerNote", request.reviewer_note, false);
    try w.writeAll(",\"draftSignal\":");
    if (request.decision == .accepted) {
        try w.writeAll("{");
        try writeStringField(w, "status", "draft_signal", true);
        try writeStringField(w, "kind", "reviewed_learning_influence", false);
        try writeStringField(w, "summary", request.reviewer_note, false);
        try w.writeAll(",\"sourceStore\":\"learned_records.jsonl\",\"nonAuthorizing\":true,\"treatedAsProof\":false,\"usedAsEvidence\":false");
        try w.writeAll("}");
    } else {
        try w.writeAll("null");
    }
    try w.writeAll(",\"nonAuthorizing\":true,\"treatedAsProof\":false,\"usedAsEvidence\":false,\"globalPromotion\":false");
    try w.writeAll(",\"commandsExecuted\":false,\"verifiersExecuted\":false,\"corpusMutation\":false,\"packMutation\":false,\"negativeKnowledgeMutation\":false");
    try w.writeAll(",\"appendOnly\":{\"storage\":\"jsonl\",\"file\":\"learned_records.jsonl\",\"appendOffsetBytes\":");
    try w.print("{d}", .{append_offset});
    try w.writeAll(",\"inPlaceRewrite\":false,\"deletion\":false,\"compaction\":false,\"stableOrdering\":\"file_append_order\"}");
    try w.writeAll("}");
    return out.toOwnedSlice();
}

pub fn readAcceptedInfluences(allocator: std.mem.Allocator, project_shard: []const u8) !ReadResult {
    const path = try learnedRecordsPath(allocator, project_shard);
    defer allocator.free(path);
    return readAcceptedInfluencesAtPath(allocator, path, project_shard, MAX_LEARNED_RECORDS_READ);
}

pub fn readAcceptedInfluencesAtPath(allocator: std.mem.Allocator, abs_path: []const u8, project_shard: []const u8, max_records: usize) !ReadResult {
    var influences = std.ArrayList(AcceptedLearningInfluence).init(allocator);
    errdefer {
        for (influences.items) |*item| item.deinit(allocator);
        influences.deinit();
    }
    var warnings = std.ArrayList(ReadWarning).init(allocator);
    errdefer deinitWarnings(allocator, &warnings);

    const data = readFileBounded(allocator, abs_path, &warnings) catch |err| switch (err) {
        error.FileNotFound => return .{
            .allocator = allocator,
            .influences = try influences.toOwnedSlice(),
            .warnings = try warnings.toOwnedSlice(),
            .records_read = 0,
            .accepted_records = 0,
            .rejected_records = 0,
            .malformed_lines = 0,
            .truncated = false,
            .missing_file = true,
        },
        else => return err,
    };
    defer allocator.free(data.bytes);

    var records_read: usize = 0;
    var accepted_records: usize = 0;
    var rejected_records: usize = 0;
    var malformed_lines: usize = 0;
    var line_number: usize = 1;
    var lines = std.mem.splitScalar(u8, data.bytes, '\n');
    while (lines.next()) |raw_line| : (line_number += 1) {
        const line = std.mem.trim(u8, raw_line, " \r\t");
        if (line.len == 0) continue;
        if (records_read >= max_records) {
            try appendReadWarning(allocator, &warnings, line_number, "reviewed learning record read limit reached");
            break;
        }
        records_read += 1;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch {
            malformed_lines += 1;
            try appendReadWarning(allocator, &warnings, line_number, "malformed reviewed learning JSONL line ignored");
            continue;
        };
        defer parsed.deinit();
        const obj = valueObject(parsed.value) orelse {
            malformed_lines += 1;
            try appendReadWarning(allocator, &warnings, line_number, "reviewed learning line was not an object");
            continue;
        };
        const shard = getStr(obj, "projectShard") orelse "";
        if (!std.mem.eql(u8, shard, project_shard)) continue;
        const decision_text = getStr(obj, "reviewDecision") orelse {
            malformed_lines += 1;
            try appendReadWarning(allocator, &warnings, line_number, "reviewed learning missing reviewDecision");
            continue;
        };
        const decision = Decision.parse(decision_text) orelse {
            malformed_lines += 1;
            try appendReadWarning(allocator, &warnings, line_number, "reviewed learning had invalid reviewDecision");
            continue;
        };
        switch (decision) {
            .accepted => accepted_records += 1,
            .rejected => {
                rejected_records += 1;
                continue;
            },
        }
        if (try influenceFromRecord(allocator, obj, line_number)) |influence| {
            try influences.append(influence);
        } else {
            try appendReadWarning(allocator, &warnings, line_number, "accepted reviewed learning record did not contain a usable influence");
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
        .truncated = data.truncated,
        .missing_file = false,
    };
}

pub fn status(allocator: std.mem.Allocator, project_shard: []const u8, include_records: bool, limit: usize, max_records: usize) !StatusResult {
    const path = try learnedRecordsPath(allocator, project_shard);
    defer allocator.free(path);
    return statusAtPath(allocator, path, project_shard, include_records, limit, max_records);
}

pub fn statusAtPath(allocator: std.mem.Allocator, abs_path: []const u8, project_shard: []const u8, include_records: bool, limit: usize, max_records: usize) !StatusResult {
    var candidate_counts = std.StringArrayHashMap(usize).init(allocator);
    defer deinitCountMap(allocator, &candidate_counts);
    var records = std.ArrayList(StatusRecord).init(allocator);
    errdefer {
        for (records.items) |*record| record.deinit(allocator);
        records.deinit();
    }
    var warnings = std.ArrayList(ReadWarning).init(allocator);
    errdefer deinitWarnings(allocator, &warnings);
    var summary = StatusSummary{};
    errdefer summary.deinit(allocator);

    const data = readFileBounded(allocator, abs_path, &warnings) catch |err| switch (err) {
        error.FileNotFound => {
            summary.candidate_kind_counts = try emptyCountEntries(allocator);
            return .{
                .allocator = allocator,
                .summary = summary,
                .warnings = try warnings.toOwnedSlice(),
                .records = try records.toOwnedSlice(),
                .records_read = 0,
                .returned_count = 0,
                .truncated = false,
                .max_records_hit = false,
                .limit_hit = false,
                .missing_file = true,
            };
        },
        else => return err,
    };
    defer allocator.free(data.bytes);

    var records_read: usize = 0;
    var returned_count: usize = 0;
    var limit_hit = false;
    var max_records_hit = false;
    var line_number: usize = 1;
    var lines = std.mem.splitScalar(u8, data.bytes, '\n');
    while (lines.next()) |raw_line| : (line_number += 1) {
        const line = std.mem.trim(u8, raw_line, " \r\t");
        if (line.len == 0) continue;
        if (records_read >= max_records) {
            max_records_hit = true;
            try appendReadWarning(allocator, &warnings, line_number, "reviewed learning record read limit reached");
            break;
        }
        records_read += 1;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch {
            summary.malformed_lines += 1;
            try appendReadWarning(allocator, &warnings, line_number, "malformed reviewed learning JSONL line ignored");
            continue;
        };
        defer parsed.deinit();
        const obj = valueObject(parsed.value) orelse {
            summary.malformed_lines += 1;
            try appendReadWarning(allocator, &warnings, line_number, "reviewed learning line was not an object");
            continue;
        };
        const shard = getStr(obj, "projectShard") orelse "";
        if (!std.mem.eql(u8, shard, project_shard)) continue;
        const decision_text = getStr(obj, "reviewDecision") orelse {
            summary.malformed_lines += 1;
            try appendReadWarning(allocator, &warnings, line_number, "reviewed learning missing reviewDecision");
            continue;
        };
        const decision = Decision.parse(decision_text) orelse {
            summary.malformed_lines += 1;
            try appendReadWarning(allocator, &warnings, line_number, "reviewed learning had invalid reviewDecision");
            continue;
        };
        const candidate_kind = candidateKind(obj) orelse "unknown";
        summary.reviewed_records += 1;
        switch (decision) {
            .accepted => summary.accepted_records += 1,
            .rejected => summary.rejected_records += 1,
        }
        try incrementCount(allocator, &candidate_counts, candidate_kind);

        if (obj.get("learningCandidate")) |cand_val| {
            if (valueObject(cand_val)) |cand| {
                if (cand.get("selfReview")) |sr_val| {
                    if (valueObject(sr_val)) |sr| {
                        if (getStr(sr, "status")) |status_str| {
                            if (std.mem.eql(u8, status_str, "passed")) summary.self_verification_passed += 1;
                            if (std.mem.eql(u8, status_str, "failed")) summary.self_verification_failed += 1;
                            if (std.mem.eql(u8, status_str, "ambiguous")) summary.self_verification_ambiguous += 1;
                        }
                    }
                }
            }
        }

        if (include_records) {
            if (returned_count < limit) {
                try records.append(.{
                    .id = try allocator.dupe(u8, getStr(obj, "id") orelse ""),
                    .decision = decision,
                    .candidate_kind = try allocator.dupe(u8, candidate_kind),
                    .record_json = try allocator.dupe(u8, line),
                    .line_number = line_number,
                });
                returned_count += 1;
            } else {
                limit_hit = true;
            }
        }
    }
    summary.candidate_kind_counts = try countEntriesFromMap(allocator, &candidate_counts);
    return .{
        .allocator = allocator,
        .summary = summary,
        .warnings = try warnings.toOwnedSlice(),
        .records = try records.toOwnedSlice(),
        .records_read = records_read,
        .returned_count = returned_count,
        .truncated = data.truncated,
        .max_records_hit = max_records_hit or data.truncated,
        .limit_hit = limit_hit,
        .missing_file = false,
    };
}

fn influenceFromRecord(allocator: std.mem.Allocator, obj: std.json.ObjectMap, line_number: usize) !?AcceptedLearningInfluence {
    const record_id = getStr(obj, "id") orelse return null;
    const candidate_id = getStr(obj, "sourceLearningCandidateId") orelse return null;
    const candidate_value = obj.get("learningCandidate");
    const candidate = if (candidate_value) |value| valueObject(value) else null;
    const kind = if (candidate) |c| (getStr(c, "candidateKind") orelse getStr(c, "kind") orelse "unknown") else "unknown";
    const pattern = if (candidate) |c| firstNonEmpty(&.{ getStr(c, "logicPattern"), getStr(c, "reason"), getStr(c, "proposedAction") }) else candidate_id;
    const reviewer_note = getStr(obj, "reviewerNote") orelse "";
    const id = try std.fmt.allocPrint(allocator, "learning-influence:{x:0>16}:{d}", .{ std.hash.Fnv1a_64.hash(record_id) ^ std.hash.Fnv1a_64.hash(candidate_id), line_number });
    errdefer allocator.free(id);
    return .{
        .id = id,
        .source_reviewed_learning_id = try allocator.dupe(u8, record_id),
        .learning_candidate_id = try allocator.dupe(u8, candidate_id),
        .candidate_kind = try allocator.dupe(u8, kind),
        .logic_pattern = try allocator.dupe(u8, pattern),
        .reviewer_note = try allocator.dupe(u8, reviewer_note),
        .draft_signal = try allocator.dupe(u8, if (reviewer_note.len > 0) reviewer_note else pattern),
    };
}

fn detectConflictAtPath(allocator: std.mem.Allocator, request: Request, abs_path: []const u8) !?ConflictResult {
    if (request.decision != .accepted) return null;

    var incoming_view = try LearningTextView.fromRequest(allocator, request);
    defer incoming_view.deinit();

    var warnings = std.ArrayList(ReadWarning).init(allocator);
    defer deinitWarnings(allocator, &warnings);
    const data = readFileBounded(allocator, abs_path, &warnings) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(data.bytes);

    var established_ids = std.ArrayList([]u8).init(allocator);
    errdefer {
        for (established_ids.items) |id| allocator.free(id);
        established_ids.deinit();
    }

    var line_number: usize = 1;
    var records_read: usize = 0;
    var lines = std.mem.splitScalar(u8, data.bytes, '\n');
    while (lines.next()) |raw_line| : (line_number += 1) {
        const line = std.mem.trim(u8, raw_line, " \r\t");
        if (line.len == 0) continue;
        if (records_read >= MAX_LEARNED_RECORDS_READ) break;
        records_read += 1;

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        defer parsed.deinit();
        const obj = valueObject(parsed.value) orelse continue;
        if (!std.mem.eql(u8, getStr(obj, "projectShard") orelse "", request.project_shard)) continue;
        if (!std.mem.eql(u8, getStr(obj, "reviewDecision") orelse "", "accepted")) continue;
        if (!recordsContradict(incoming_view, obj)) continue;

        const id = getStr(obj, "id") orelse continue;
        try established_ids.append(try allocator.dupe(u8, id));
    }

    if (established_ids.items.len == 0) return null;
    return .{
        .allocator = allocator,
        .established_record_ids = try established_ids.toOwnedSlice(),
        .reason = try allocator.dupe(u8, "accepted learning review structurally contradicts established reviewed learning in the same shard"),
    };
}

fn recordsContradict(incoming_text: LearningTextView, established: std.json.ObjectMap) bool {
    const established_text = LearningTextView.fromRecord(established);
    return viewsContradict(incoming_text, established_text);
}

const LearningTextView = struct {
    candidate_kind: []const u8 = "",
    logic_pattern: []const u8 = "",
    reason: []const u8 = "",
    proposed_action: []const u8 = "",
    reviewer_note: []const u8 = "",
    parsed_candidate: ?std.json.Parsed(std.json.Value) = null,

    fn fromRequest(allocator: std.mem.Allocator, request: Request) !LearningTextView {
        var view = LearningTextView{ .reviewer_note = request.reviewer_note };
        if (request.learning_candidate_json) |json| {
            view.parsed_candidate = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch return view;
            if (view.parsed_candidate) |parsed| {
                if (valueObject(parsed.value)) |obj| fillFromCandidate(&view, obj);
            }
        }
        return view;
    }

    fn deinit(view: *LearningTextView) void {
        if (view.parsed_candidate) |*parsed| parsed.deinit();
        view.* = undefined;
    }

    fn fromRecord(record: std.json.ObjectMap) LearningTextView {
        var view = LearningTextView{ .reviewer_note = getStr(record, "reviewerNote") orelse "" };
        if (record.get("learningCandidate")) |candidate_value| {
            if (valueObject(candidate_value)) |obj| fillFromCandidate(&view, obj);
        }
        return view;
    }

    fn fillFromCandidate(view: *LearningTextView, obj: std.json.ObjectMap) void {
        view.candidate_kind = getStr(obj, "candidateKind") orelse getStr(obj, "kind") orelse "";
        view.logic_pattern = getStr(obj, "logicPattern") orelse "";
        view.reason = getStr(obj, "reason") orelse "";
        view.proposed_action = getStr(obj, "proposedAction") orelse "";
    }
};

const Polarity = enum {
    unknown,
    permits_non_zero_header,
    forbids_non_zero_header,
};

fn viewsContradict(a: LearningTextView, b: LearningTextView) bool {
    if (!sameStructuralSubject(a, b)) return false;
    const polarity_a = polarityFor(a);
    const polarity_b = polarityFor(b);
    return (polarity_a == .permits_non_zero_header and polarity_b == .forbids_non_zero_header) or
        (polarity_a == .forbids_non_zero_header and polarity_b == .permits_non_zero_header);
}

fn sameStructuralSubject(a: LearningTextView, b: LearningTextView) bool {
    if (mentionsProtocol99(a) and mentionsProtocol99(b)) return true;
    return std.mem.eql(u8, a.candidate_kind, b.candidate_kind) and
        a.candidate_kind.len > 0 and
        normalizedTextEquals(a.logic_pattern, b.logic_pattern);
}

fn polarityFor(view: LearningTextView) Polarity {
    if (!mentionsNonZeroHeader(view)) return .unknown;
    if (containsAnyView(view, &.{ "permits", "permit", "allows", "allow", "valid", "complies", "comply", "may use" })) {
        if (!containsAnyView(view, &.{ "does not comply", "not comply", "noncompliant", "non-compliant", "invalid", "forbid", "forbids", "disallow", "disallows", "reject", "rejects" })) {
            return .permits_non_zero_header;
        }
    }
    if (containsAnyView(view, &.{ "does not comply", "not comply", "noncompliant", "non-compliant", "invalid", "forbid", "forbids", "forbidden", "disallow", "disallows", "reject", "rejects", "must be zero", "requires zero" })) {
        return .forbids_non_zero_header;
    }
    return .unknown;
}

fn mentionsProtocol99(view: LearningTextView) bool {
    return containsAnyView(view, &.{ "protocol 99", "protocol99" });
}

fn mentionsNonZeroHeader(view: LearningTextView) bool {
    return containsAnyView(view, &.{ "non-zero header", "non-zero headers", "nonzero header", "nonzero headers", "non zero header", "non zero headers" });
}

fn containsAnyView(view: LearningTextView, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (containsInsensitive(view.candidate_kind, needle) or
            containsInsensitive(view.logic_pattern, needle) or
            containsInsensitive(view.reason, needle) or
            containsInsensitive(view.proposed_action, needle) or
            containsInsensitive(view.reviewer_note, needle))
        {
            return true;
        }
    }
    return false;
}

fn containsInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn normalizedTextEquals(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, a, " \r\n\t"), std.mem.trim(u8, b, " \r\n\t"));
}

fn candidateKind(obj: std.json.ObjectMap) ?[]const u8 {
    const candidate_value = obj.get("learningCandidate") orelse return null;
    const candidate = valueObject(candidate_value) orelse return null;
    return getStr(candidate, "candidateKind") orelse getStr(candidate, "kind");
}

fn readFileBounded(allocator: std.mem.Allocator, abs_path: []const u8, warnings: *std.ArrayList(ReadWarning)) !FileBytes {
    const file = try std.fs.openFileAbsolute(abs_path, .{});
    defer file.close();
    const file_size = try file.getEndPos();
    const read_len: usize = @intCast(@min(file_size, MAX_LEARNED_RECORDS_BYTES));
    var data = try allocator.alloc(u8, read_len);
    errdefer allocator.free(data);
    const actual = try file.readAll(data);
    if (actual != read_len) data = try allocator.realloc(data, actual);
    const truncated = file_size > MAX_LEARNED_RECORDS_BYTES;
    if (truncated) try appendReadWarning(allocator, warnings, 0, "reviewed learning file exceeded bounded read size; later records were not read");
    return .{ .bytes = data, .truncated = truncated };
}

fn appendReadWarning(allocator: std.mem.Allocator, warnings: *std.ArrayList(ReadWarning), line_number: usize, reason: []const u8) !void {
    if (warnings.items.len >= MAX_LEARNED_RECORD_WARNINGS) return;
    try warnings.append(.{ .line_number = line_number, .reason = try allocator.dupe(u8, reason) });
}

fn deinitWarnings(allocator: std.mem.Allocator, warnings: *std.ArrayList(ReadWarning)) void {
    for (warnings.items) |*warning| warning.deinit(allocator);
    warnings.deinit();
}

fn incrementCount(allocator: std.mem.Allocator, map: *std.StringArrayHashMap(usize), name: []const u8) !void {
    if (map.getPtr(name)) |count| {
        count.* += 1;
        return;
    }
    try map.put(try allocator.dupe(u8, name), 1);
}

fn countEntriesFromMap(allocator: std.mem.Allocator, map: *std.StringArrayHashMap(usize)) ![]CountEntry {
    var entries = try allocator.alloc(CountEntry, map.count());
    var idx: usize = 0;
    var it = map.iterator();
    while (it.next()) |entry| : (idx += 1) {
        entries[idx] = .{ .name = try allocator.dupe(u8, entry.key_ptr.*), .count = entry.value_ptr.* };
    }
    return entries;
}

fn emptyCountEntries(allocator: std.mem.Allocator) ![]CountEntry {
    return allocator.alloc(CountEntry, 0);
}

fn deinitCountMap(allocator: std.mem.Allocator, map: *std.StringArrayHashMap(usize)) void {
    for (map.keys()) |key| allocator.free(key);
    map.deinit();
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

fn firstNonEmpty(values: []const ?[]const u8) []const u8 {
    for (values) |maybe| {
        const text = maybe orelse continue;
        if (std.mem.trim(u8, text, " \r\n\t").len != 0) return text;
    }
    return "";
}

test "reviewed learning append preserves prior records" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, "learned_records.jsonl" });
    defer allocator.free(path);
    const req = Request{
        .project_shard = "learning-store-test",
        .learning_candidate_id = "learning:candidate:1",
        .decision = .accepted,
        .reviewer_note = "reviewed draft signal",
        .learning_candidate_json = "{\"id\":\"learning:candidate:1\",\"candidateKind\":\"corpus_update_candidate\",\"logicPattern\":\"protocol 99\"}",
    };
    var first = try reviewAndAppendAtPath(allocator, req, path);
    defer first.deinit();
    var second = try reviewAndAppendAtPath(allocator, req, path);
    defer second.deinit();
    try std.testing.expect(first == .appended);
    try std.testing.expect(second == .appended);
    try std.testing.expect(std.mem.indexOf(u8, first.appended.record_json, "\"appendOffsetBytes\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, second.appended.record_json, "\"appendOffsetBytes\":0") == null);
    var read = try readAcceptedInfluencesAtPath(allocator, path, "learning-store-test", MAX_LEARNED_RECORDS_READ);
    defer read.deinit();
    try std.testing.expectEqual(@as(usize, 2), read.accepted_records);
    try std.testing.expectEqual(@as(usize, 2), read.influences.len);
}

test "accepted reviewed learning rejects Protocol 99 contradiction" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, "learned_records.jsonl" });
    defer allocator.free(path);

    var established = try reviewAndAppendAtPath(allocator, .{
        .project_shard = "learning-conflict-test",
        .learning_candidate_id = "learning:candidate:protocol99:established",
        .decision = .accepted,
        .reviewer_note = "A non-zero header does not comply with Protocol 99.",
        .learning_candidate_json = "{\"id\":\"learning:candidate:protocol99:established\",\"candidateKind\":\"corpus_update_candidate\",\"logicPattern\":\"Protocol 99 non-zero header compliance\"}",
    }, path);
    defer established.deinit();
    try std.testing.expect(established == .appended);

    var contradictory = try reviewAndAppendAtPath(allocator, .{
        .project_shard = "learning-conflict-test",
        .learning_candidate_id = "learning:candidate:protocol99:contradiction",
        .decision = .accepted,
        .reviewer_note = "Protocol 99 permits non-zero headers.",
        .learning_candidate_json = "{\"id\":\"learning:candidate:protocol99:contradiction\",\"candidateKind\":\"corpus_update_candidate\",\"logicPattern\":\"Protocol 99 permits non-zero headers\"}",
    }, path);
    defer contradictory.deinit();

    try std.testing.expect(contradictory == .conflict);
    try std.testing.expectEqual(@as(usize, 1), contradictory.conflict.established_record_ids.len);
    try std.testing.expectEqualStrings(established.appended.record_json[7..std.mem.indexOfPos(u8, established.appended.record_json, 7, "\"").?], contradictory.conflict.established_record_ids[0]);

    var read = try readAcceptedInfluencesAtPath(allocator, path, "learning-conflict-test", MAX_LEARNED_RECORDS_READ);
    defer read.deinit();
    try std.testing.expectEqual(@as(usize, 1), read.accepted_records);
}
