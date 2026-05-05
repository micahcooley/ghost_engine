const std = @import("std");
const shards = @import("shards.zig");

pub const SCHEMA_VERSION = "reviewed_negative_knowledge_record.v1";
pub const REVIEWED_NEGATIVE_KNOWLEDGE_REL_DIR = "negative_knowledge";
pub const REVIEWED_NEGATIVE_KNOWLEDGE_FILE_NAME = "reviewed_negative_knowledge.jsonl";
pub const MAX_REVIEWED_NEGATIVE_KNOWLEDGE_READ: usize = 128;
pub const MAX_REVIEWED_NEGATIVE_KNOWLEDGE_BYTES: usize = 256 * 1024;
pub const MAX_REVIEWED_NEGATIVE_KNOWLEDGE_WARNINGS: usize = 8;

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

pub const InfluenceKind = enum {
    warning,
    penalty,
    require_stronger_evidence,
    require_verifier_candidate,
    suppress_exact_repeat,
    propose_pack_guidance,
    propose_corpus_update,
    propose_rule_update,

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

pub const AcceptedNegativeKnowledgeInfluence = struct {
    id: []u8,
    source_reviewed_negative_knowledge_id: []u8,
    influence_kind: InfluenceKind,
    applies_to: []u8,
    matched_pattern: []u8,
    matched_output_id: ?[]u8 = null,
    matched_rule_id: ?[]u8 = null,
    reason: []u8,
    pattern_fingerprint: []u8,
    non_authorizing: bool = true,
    treated_as_proof: bool = false,
    used_as_evidence: bool = false,
    global_promotion: bool = false,
    mutation_flags: MutationFlags = .{},

    pub fn deinit(self: *AcceptedNegativeKnowledgeInfluence, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.source_reviewed_negative_knowledge_id);
        allocator.free(self.applies_to);
        allocator.free(self.matched_pattern);
        if (self.matched_output_id) |value| allocator.free(value);
        if (self.matched_rule_id) |value| allocator.free(value);
        allocator.free(self.reason);
        allocator.free(self.pattern_fingerprint);
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
    influences: []AcceptedNegativeKnowledgeInfluence,
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

pub fn readAcceptedInfluences(allocator: std.mem.Allocator, project_shard: []const u8) !ReadResult {
    const path = try reviewedNegativeKnowledgePath(allocator, project_shard);
    defer allocator.free(path);
    return readAcceptedInfluencesAtPath(allocator, path, project_shard, MAX_REVIEWED_NEGATIVE_KNOWLEDGE_READ);
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

pub fn readAcceptedInfluencesAtPath(allocator: std.mem.Allocator, abs_path: []const u8, project_shard: []const u8, max_records: usize) !ReadResult {
    var influences = std.ArrayList(AcceptedNegativeKnowledgeInfluence).init(allocator);
    errdefer {
        for (influences.items) |*item| item.deinit(allocator);
        influences.deinit();
    }
    var warnings = std.ArrayList(ReadWarning).init(allocator);
    errdefer {
        for (warnings.items) |*warning| warning.deinit(allocator);
        warnings.deinit();
    }

    const data = readReviewedFileBounded(allocator, abs_path, &warnings) catch |err| switch (err) {
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
            try appendReadWarning(allocator, &warnings, line_number, "reviewed negative knowledge record read limit reached");
            break;
        }
        records_read += 1;

        var parsed_line = (try parseReviewLineAndValidateShard(
            allocator,
            line,
            line_number,
            project_shard,
            &warnings,
            &malformed_lines,
        )) orelse continue;
        defer parsed_line.deinit();

        switch (parsed_line.decision) {
            .rejected => {
                rejected_records += 1;
                continue;
            },
            .accepted => accepted_records += 1,
        }

        const before = influences.items.len;
        try appendInfluencesFromRecord(allocator, parsed_line.obj, line_number, &influences);
        if (influences.items.len == before) {
            try appendReadWarning(allocator, &warnings, line_number, "accepted reviewed negative knowledge did not contain a usable future influence");
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
    };
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

        var parsed_line = (try parseReviewLineAndValidateShard(
            allocator,
            line,
            line_number,
            project_shard,
            &warnings,
            &malformed_lines,
        )) orelse continue;
        defer parsed_line.deinit();

        if (!decision_filter.matches(parsed_line.decision)) continue;
        if (matched_seen < offset) {
            matched_seen += 1;
            continue;
        }
        matched_seen += 1;
        if (emitted >= limit) {
            limit_hit = true;
            continue;
        }
        try records.append(try duplicateReviewedRecord(allocator, parsed_line.obj, line, parsed_line.decision, line_number));
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

        var parsed_line = (try parseReviewLineAndValidateShard(
            allocator,
            line,
            line_number,
            project_shard,
            &warnings,
            &malformed_lines,
        )) orelse continue;
        defer parsed_line.deinit();

        const record_id = getStr(parsed_line.obj, "id") orelse {
            malformed_lines += 1;
            try appendReadWarning(allocator, &warnings, line_number, "reviewed negative knowledge missing id");
            continue;
        };

        if (std.mem.eql(u8, record_id, id)) {
            return .{
                .allocator = allocator,
                .record = try duplicateReviewedRecord(allocator, parsed_line.obj, line, parsed_line.decision, line_number),
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

fn appendInfluencesFromRecord(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    line_number: usize,
    influences: *std.ArrayList(AcceptedNegativeKnowledgeInfluence),
) !void {
    const record_id = getStr(obj, "id") orelse return;
    const candidate_value = obj.get("negativeKnowledgeCandidate") orelse obj.get("negative_knowledge_candidate") orelse return;
    const candidate = valueObject(candidate_value) orelse return;
    const pattern = influencePattern(obj, candidate) orelse return;
    const kind = influenceKindFromCandidate(candidate);
    const output_id = firstNonEmpty(&.{
        getStr(candidate, "matchedOutputId"),
        getStr(candidate, "matched_output_id"),
        getStr(candidate, "outputId"),
        getStr(candidate, "output_id"),
        nestedStr(candidate, "disputedOutput", &.{ "ref", "id" }),
    });
    const rule_id = firstNonEmpty(&.{
        getStr(candidate, "matchedRuleId"),
        getStr(candidate, "matched_rule_id"),
        getStr(candidate, "ruleId"),
        getStr(candidate, "rule_id"),
    });
    const explicit = firstNonEmpty(&.{
        getStr(candidate, "appliesTo"),
        getStr(candidate, "applies_to"),
        getStr(candidate, "operationKind"),
        getStr(candidate, "operation_kind"),
        getStr(candidate, "originalOperationKind"),
        getStr(candidate, "original_operation_kind"),
    });
    if (explicit) |applies_to| {
        if (isInfluenceOperation(applies_to)) {
            try appendInfluence(allocator, influences, record_id, kind, applies_to, pattern, output_id, rule_id, line_number);
        }
        return;
    }
    try appendInfluence(allocator, influences, record_id, kind, "corpus.ask", pattern, output_id, rule_id, line_number);
    try appendInfluence(allocator, influences, record_id, kind, "rule.evaluate", pattern, output_id, rule_id, line_number);
}

fn appendInfluence(
    allocator: std.mem.Allocator,
    influences: *std.ArrayList(AcceptedNegativeKnowledgeInfluence),
    record_id: []const u8,
    kind: InfluenceKind,
    applies_to: []const u8,
    pattern: []const u8,
    output_id: ?[]const u8,
    rule_id: ?[]const u8,
    line_number: usize,
) !void {
    const fingerprint = try std.fmt.allocPrint(allocator, "fnv1a64:{x:0>16}", .{std.hash.Fnv1a_64.hash(pattern)});
    errdefer allocator.free(fingerprint);
    const id = try std.fmt.allocPrint(allocator, "negative-knowledge-influence:{x:0>16}:{d}:{s}", .{
        std.hash.Fnv1a_64.hash(record_id) ^ std.hash.Fnv1a_64.hash(pattern) ^ std.hash.Fnv1a_64.hash(applies_to),
        line_number,
        applies_to,
    });
    errdefer allocator.free(id);
    try influences.append(.{
        .id = id,
        .source_reviewed_negative_knowledge_id = try allocator.dupe(u8, record_id),
        .influence_kind = kind,
        .applies_to = try allocator.dupe(u8, applies_to),
        .matched_pattern = try allocator.dupe(u8, pattern),
        .matched_output_id = if (output_id) |value| try allocator.dupe(u8, value) else null,
        .matched_rule_id = if (rule_id) |value| try allocator.dupe(u8, value) else null,
        .reason = try allocator.dupe(u8, influenceReason(kind, applies_to)),
        .pattern_fingerprint = fingerprint,
    });
}

fn influencePattern(record: std.json.ObjectMap, candidate: std.json.ObjectMap) ?[]const u8 {
    return firstNonEmpty(&.{
        getStr(candidate, "matchedPattern"),
        getStr(candidate, "matched_pattern"),
        getStr(candidate, "failurePattern"),
        getStr(candidate, "failure_pattern"),
        getStr(candidate, "disputedOutput"),
        nestedStr(candidate, "disputedOutput", &.{ "summary", "detail", "ref", "id" }),
        getStr(candidate, "candidateSummary"),
        getStr(candidate, "candidate_summary"),
        getStr(candidate, "summary"),
        getStr(candidate, "detail"),
        getStr(candidate, "condition"),
        getStr(candidate, "suppressionRule"),
        getStr(candidate, "suppression_rule"),
        getStr(candidate, "verifierRequirement"),
        getStr(candidate, "verifier_requirement"),
        getStr(candidate, "ruleId"),
        getStr(candidate, "rule_id"),
        getStr(candidate, "outputId"),
        getStr(candidate, "output_id"),
        getStr(candidate, "answerDraft"),
        getStr(candidate, "answer_draft"),
        getStr(candidate, "evidenceRef"),
        getStr(candidate, "evidence_ref"),
        getStr(candidate, "sourcePath"),
        getStr(candidate, "source_path"),
        getStr(candidate, "originalRequestSummary"),
        getStr(candidate, "original_request_summary"),
        getStr(candidate, "trace"),
        getStr(record, "reviewerNote"),
        getStr(record, "sourceCandidateId"),
    });
}

fn influenceKindFromCandidate(candidate: std.json.ObjectMap) InfluenceKind {
    if (firstNonEmpty(&.{ getStr(candidate, "influenceKind"), getStr(candidate, "influence_kind") })) |text| {
        if (InfluenceKind.parse(text)) |kind| return kind;
    }
    if (hasNonEmpty(candidate, &.{ "suppressionRule", "suppression_rule", "suppressExactRepeat", "suppress_exact_repeat" })) return .suppress_exact_repeat;
    if (hasNonEmpty(candidate, &.{ "verifierRequirement", "verifier_requirement", "requiredVerifier", "required_verifier" })) return .require_verifier_candidate;
    if (hasNonEmpty(candidate, &.{ "strongerEvidenceRequirement", "stronger_evidence_requirement", "evidenceRef", "evidence_ref" })) return .require_stronger_evidence;
    if (hasNonEmpty(candidate, &.{ "triagePenalty", "triage_penalty", "penalty" })) return .penalty;
    if (hasNonEmpty(candidate, &.{ "packGuidanceCandidate", "pack_guidance_candidate", "trustDecaySuggestion", "trust_decay_suggestion" })) return .propose_pack_guidance;
    if (hasNonEmpty(candidate, &.{ "corpusUpdateCandidate", "corpus_update_candidate" })) return .propose_corpus_update;
    if (hasNonEmpty(candidate, &.{ "ruleUpdateCandidate", "rule_update_candidate" })) return .propose_rule_update;
    const kind_text = getStr(candidate, "kind") orelse "";
    if (std.mem.eql(u8, kind_text, "unsafe_verifier_candidate")) return .require_verifier_candidate;
    if (std.mem.eql(u8, kind_text, "insufficient_test")) return .require_verifier_candidate;
    if (std.mem.eql(u8, kind_text, "overbroad_rule")) return .propose_rule_update;
    if (std.mem.eql(u8, kind_text, "stale_source_claim")) return .require_stronger_evidence;
    if (std.mem.eql(u8, kind_text, "forbidden_project_pattern")) return .suppress_exact_repeat;
    if (std.mem.eql(u8, kind_text, "failed_hypothesis")) return .suppress_exact_repeat;
    return .warning;
}

fn influenceReason(kind: InfluenceKind, applies_to: []const u8) []const u8 {
    _ = applies_to;
    return switch (kind) {
        .warning => "accepted reviewed negative knowledge warns on a repeated known-bad pattern",
        .penalty => "accepted reviewed negative knowledge ranks a repeated known-bad pattern lower",
        .require_stronger_evidence => "accepted reviewed negative knowledge requires stronger exact evidence before this pattern can be relied on",
        .require_verifier_candidate => "accepted reviewed negative knowledge requires an explicit verifier/check candidate; no verifier was executed",
        .suppress_exact_repeat => "accepted reviewed negative knowledge suppresses an exact repeated known-bad pattern",
        .propose_pack_guidance => "accepted reviewed negative knowledge proposes pack guidance candidate only",
        .propose_corpus_update => "accepted reviewed negative knowledge proposes corpus update candidate only",
        .propose_rule_update => "accepted reviewed negative knowledge proposes rule update candidate only",
    };
}

fn isInfluenceOperation(text: []const u8) bool {
    return std.mem.eql(u8, text, "corpus.ask") or std.mem.eql(u8, text, "rule.evaluate");
}

fn nestedStr(obj: std.json.ObjectMap, field: []const u8, names: []const []const u8) ?[]const u8 {
    const value = obj.get(field) orelse return null;
    const nested = valueObject(value) orelse return null;
    for (names) |name| {
        if (getStr(nested, name)) |text| return text;
    }
    return null;
}

fn hasNonEmpty(obj: std.json.ObjectMap, names: []const []const u8) bool {
    for (names) |name| {
        const value = obj.get(name) orelse continue;
        switch (value) {
            .string => if (std.mem.trim(u8, value.string, " \r\n\t").len != 0) return true,
            .integer, .float, .bool => return true,
            else => {},
        }
    }
    return false;
}

fn firstNonEmpty(values: []const ?[]const u8) ?[]const u8 {
    for (values) |maybe| {
        const value = maybe orelse continue;
        if (std.mem.trim(u8, value, " \r\n\t").len != 0) return value;
    }
    return null;
}

fn appendReadWarning(allocator: std.mem.Allocator, warnings: *std.ArrayList(ReadWarning), line_number: usize, reason: []const u8) !void {
    if (warnings.items.len >= MAX_REVIEWED_NEGATIVE_KNOWLEDGE_WARNINGS) return;
    try warnings.append(.{
        .line_number = line_number,
        .reason = try allocator.dupe(u8, reason),
    });
}

const ParsedReviewLine = struct {
    parsed: std.json.Parsed(std.json.Value),
    obj: std.json.ObjectMap,
    decision: Decision,

    pub fn deinit(self: *ParsedReviewLine) void {
        self.parsed.deinit();
    }
};

fn parseReviewLineAndValidateShard(
    allocator: std.mem.Allocator,
    line: []const u8,
    line_number: usize,
    project_shard: []const u8,
    warnings: *std.ArrayList(ReadWarning),
    malformed_lines: *usize,
) !?ParsedReviewLine {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch {
        malformed_lines.* += 1;
        try appendReadWarning(allocator, warnings, line_number, "malformed reviewed negative knowledge JSONL line ignored");
        return null;
    };
    var success = false;
    defer if (!success) parsed.deinit();

    const obj = valueObject(parsed.value) orelse {
        malformed_lines.* += 1;
        try appendReadWarning(allocator, warnings, line_number, "reviewed negative knowledge line was not an object");
        return null;
    };
    const record_shard = getStr(obj, "projectShard") orelse getStr(obj, "project_shard") orelse {
        malformed_lines.* += 1;
        try appendReadWarning(allocator, warnings, line_number, "reviewed negative knowledge missing projectShard");
        return null;
    };
    if (!std.mem.eql(u8, record_shard, project_shard)) return null;

    const decision_text = getStr(obj, "reviewDecision") orelse {
        malformed_lines.* += 1;
        try appendReadWarning(allocator, warnings, line_number, "reviewed negative knowledge missing reviewDecision");
        return null;
    };
    const decision = Decision.parse(decision_text) orelse {
        malformed_lines.* += 1;
        try appendReadWarning(allocator, warnings, line_number, "reviewed negative knowledge had invalid reviewDecision");
        return null;
    };

    success = true;
    return .{
        .parsed = parsed,
        .obj = obj,
        .decision = decision,
    };
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

test "accepted reviewed negative knowledge influence reader is bounded same shard and warning only on malformed" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const missing_path = try std.fs.path.join(allocator, &.{ root, "missing.jsonl" });
    defer allocator.free(missing_path);

    var missing = try readAcceptedInfluencesAtPath(allocator, missing_path, "phase11b", MAX_REVIEWED_NEGATIVE_KNOWLEDGE_READ);
    defer missing.deinit();
    try std.testing.expectEqual(@as(usize, 0), missing.influences.len);
    try std.testing.expectEqual(@as(usize, 0), missing.records_read);

    const path = try std.fs.path.join(allocator, &.{ root, "reviewed_negative_knowledge.jsonl" });
    defer allocator.free(path);
    var accepted = try reviewAndAppendAtPath(allocator, .{
        .project_shard = "phase11b",
        .decision = .accepted,
        .reviewer_note = "accepted",
        .rejected_reason = null,
        .source_candidate_id = "nk:candidate:accepted",
        .negative_knowledge_candidate_json =
        \\{"id":"nk:candidate:accepted","operationKind":"rule.evaluate","kind":"overbroad_rule","condition":"unsafe rule output","matchedOutputId":"check.bad","ruleUpdateCandidate":"tighten rule","nonAuthorizing":true}
        ,
    }, path);
    defer accepted.deinit();
    var rejected = try reviewAndAppendAtPath(allocator, .{
        .project_shard = "phase11b",
        .decision = .rejected,
        .reviewer_note = "rejected",
        .rejected_reason = "too broad",
        .source_candidate_id = "nk:candidate:rejected",
        .negative_knowledge_candidate_json = "{\"id\":\"nk:candidate:rejected\",\"operationKind\":\"rule.evaluate\",\"condition\":\"must not influence\"}",
    }, path);
    defer rejected.deinit();
    var other = try reviewAndAppendAtPath(allocator, .{
        .project_shard = "other-phase11b",
        .decision = .accepted,
        .reviewer_note = "other shard",
        .rejected_reason = null,
        .source_candidate_id = "nk:candidate:other",
        .negative_knowledge_candidate_json = "{\"id\":\"nk:candidate:other\",\"operationKind\":\"rule.evaluate\",\"condition\":\"other shard\"}",
    }, path);
    defer other.deinit();

    var file = try std.fs.openFileAbsolute(path, .{ .mode = .write_only });
    defer file.close();
    try file.seekFromEnd(0);
    try file.writeAll("{malformed reviewed negative knowledge line}\n");

    var read = try readAcceptedInfluencesAtPath(allocator, path, "phase11b", MAX_REVIEWED_NEGATIVE_KNOWLEDGE_READ);
    defer read.deinit();
    try std.testing.expectEqual(@as(usize, 4), read.records_read);
    try std.testing.expectEqual(@as(usize, 1), read.accepted_records);
    try std.testing.expectEqual(@as(usize, 1), read.rejected_records);
    try std.testing.expectEqual(@as(usize, 1), read.malformed_lines);
    try std.testing.expectEqual(@as(usize, 1), read.influences.len);
    try std.testing.expectEqual(InfluenceKind.propose_rule_update, read.influences[0].influence_kind);
    try std.testing.expectEqualStrings("rule.evaluate", read.influences[0].applies_to);
    try std.testing.expectEqualStrings("unsafe rule output", read.influences[0].matched_pattern);
    try std.testing.expectEqualStrings("check.bad", read.influences[0].matched_output_id.?);
    try std.testing.expect(read.influences[0].non_authorizing);
    try std.testing.expect(!read.influences[0].treated_as_proof);
    try std.testing.expect(!read.influences[0].used_as_evidence);
    try std.testing.expect(!read.influences[0].global_promotion);
    try std.testing.expect(!read.influences[0].mutation_flags.corpus_mutation);
    try std.testing.expect(!read.influences[0].mutation_flags.pack_mutation);
    try std.testing.expect(!read.influences[0].mutation_flags.negative_knowledge_mutation);
    try std.testing.expect(!read.influences[0].mutation_flags.commands_executed);
    try std.testing.expect(!read.influences[0].mutation_flags.verifiers_executed);
}
