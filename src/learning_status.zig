const std = @import("std");
const correction_review = @import("correction_review.zig");
const negative_knowledge_review = @import("negative_knowledge_review.zig");
const shards = @import("shards.zig");

pub const MAX_LEARNING_STATUS_RECORDS: usize = @min(correction_review.MAX_REVIEWED_CORRECTIONS_READ, negative_knowledge_review.MAX_REVIEWED_NEGATIVE_KNOWLEDGE_READ);

pub const Request = struct {
    project_shard: []const u8,
    include_records: bool = false,
    include_warnings: bool = true,
    limit: usize = 0,
};

pub const RecordSample = struct {
    kind: []u8,
    id: []u8,
    decision: []u8,
    record_json: []u8,
    line_number: usize,

    pub fn deinit(self: *RecordSample, allocator: std.mem.Allocator) void {
        allocator.free(self.kind);
        allocator.free(self.id);
        allocator.free(self.decision);
        allocator.free(self.record_json);
        self.* = undefined;
    }
};

pub const NegativeKnowledgeSummary = struct {
    reviewed_records: usize = 0,
    accepted_records: usize = 0,
    rejected_records: usize = 0,
    malformed_lines: usize = 0,
    operation_kind_counts: []correction_review.CountEntry = &.{},
    influence_kind_counts: []correction_review.CountEntry = &.{},
    suppression_candidate_count: usize = 0,
    stronger_evidence_candidate_count: usize = 0,
    verifier_candidate_count: usize = 0,
    pack_guidance_candidate_count: usize = 0,
    corpus_update_candidate_count: usize = 0,
    rule_update_candidate_count: usize = 0,
    future_behavior_candidate_count: usize = 0,

    pub fn deinit(self: *NegativeKnowledgeSummary, allocator: std.mem.Allocator) void {
        for (self.operation_kind_counts) |*entry| entry.deinit(allocator);
        allocator.free(self.operation_kind_counts);
        for (self.influence_kind_counts) |*entry| entry.deinit(allocator);
        allocator.free(self.influence_kind_counts);
        self.* = undefined;
    }
};

pub const WarningSummary = struct {
    malformed_reviewed_correction_lines: usize = 0,
    malformed_reviewed_negative_knowledge_lines: usize = 0,
    capacity_warnings: usize = 0,
    unknown_or_unclassified_records: usize = 0,
    read_caps_hit: bool = false,
    byte_caps_hit: bool = false,
};

pub const CapacityTelemetry = struct {
    correction_records_read: usize = 0,
    correction_max_records: usize = correction_review.MAX_REVIEWED_CORRECTIONS_READ,
    correction_read_cap_hit: bool = false,
    correction_max_bytes: usize = correction_review.MAX_REVIEWED_CORRECTIONS_BYTES,
    correction_byte_cap_hit: bool = false,
    negative_knowledge_records_read: usize = 0,
    negative_knowledge_max_records: usize = negative_knowledge_review.MAX_REVIEWED_NEGATIVE_KNOWLEDGE_READ,
    negative_knowledge_read_cap_hit: bool = false,
    negative_knowledge_max_bytes: usize = negative_knowledge_review.MAX_REVIEWED_NEGATIVE_KNOWLEDGE_BYTES,
    negative_knowledge_byte_cap_hit: bool = false,
    include_records: bool = false,
    limit: usize = 0,
    returned_records: usize = 0,
    limit_hit: bool = false,
};

pub const StorageSummary = struct {
    correction_missing_file: bool = false,
    negative_knowledge_missing_file: bool = false,
};

pub const StatusResult = struct {
    allocator: std.mem.Allocator,
    project_shard: []u8,
    correction_status: correction_review.InfluenceStatusResult,
    negative_knowledge_summary: NegativeKnowledgeSummary,
    negative_knowledge_warnings: []negative_knowledge_review.ReadWarning,
    records: []RecordSample,
    warning_summary: WarningSummary,
    capacity_telemetry: CapacityTelemetry,
    storage: StorageSummary,

    pub fn deinit(self: *StatusResult) void {
        self.allocator.free(self.project_shard);
        self.correction_status.deinit();
        self.negative_knowledge_summary.deinit(self.allocator);
        for (self.negative_knowledge_warnings) |*warning| warning.deinit(self.allocator);
        self.allocator.free(self.negative_knowledge_warnings);
        for (self.records) |*record| record.deinit(self.allocator);
        self.allocator.free(self.records);
        self.* = undefined;
    }
};

const ReviewedFileBytes = struct {
    bytes: []u8,
    truncated: bool,
};

pub fn readStatus(allocator: std.mem.Allocator, request: Request) !StatusResult {
    const limit = if (request.include_records) @min(request.limit, MAX_LEARNING_STATUS_RECORDS) else 0;
    var correction_status = try correction_review.correctionInfluenceStatus(
        allocator,
        request.project_shard,
        null,
        request.include_records,
        limit,
        correction_review.MAX_REVIEWED_CORRECTIONS_READ,
    );
    errdefer correction_status.deinit();

    var nk_status = try readNegativeKnowledgeStatus(allocator, request.project_shard, request.include_records, limit);
    errdefer nk_status.deinit(allocator);

    var records = std.ArrayList(RecordSample).init(allocator);
    errdefer {
        for (records.items) |*record| record.deinit(allocator);
        records.deinit();
    }
    if (request.include_records) {
        for (correction_status.records) |record| {
            if (records.items.len >= limit) break;
            try records.append(.{
                .kind = try allocator.dupe(u8, "reviewed_correction"),
                .id = try allocator.dupe(u8, record.id),
                .decision = try allocator.dupe(u8, @tagName(record.decision)),
                .record_json = try allocator.dupe(u8, record.record_json),
                .line_number = record.line_number,
            });
        }
        for (nk_status.records.items) |record| {
            if (records.items.len >= limit) break;
            try records.append(.{
                .kind = try allocator.dupe(u8, "reviewed_negative_knowledge"),
                .id = try allocator.dupe(u8, record.id),
                .decision = try allocator.dupe(u8, record.decision),
                .record_json = try allocator.dupe(u8, record.record_json),
                .line_number = record.line_number,
            });
        }
    }

    const correction_read_cap_hit = correction_status.max_records_hit;
    const nk_read_cap_hit = nk_status.max_records_hit;
    const correction_byte_cap_hit = correction_status.truncated;
    const nk_byte_cap_hit = nk_status.truncated;
    const limit_hit = request.include_records and (correction_status.limit_hit or nk_status.limit_hit or records.items.len >= limit) and
        (correction_status.summary.total_records + nk_status.summary.reviewed_records > records.items.len);

    const warning_summary = WarningSummary{
        .malformed_reviewed_correction_lines = correction_status.summary.malformed_lines,
        .malformed_reviewed_negative_knowledge_lines = nk_status.summary.malformed_lines,
        .capacity_warnings = @as(usize, if (correction_read_cap_hit) 1 else 0) + @as(usize, if (nk_read_cap_hit) 1 else 0) +
            @as(usize, if (correction_byte_cap_hit) 1 else 0) + @as(usize, if (nk_byte_cap_hit) 1 else 0),
        .unknown_or_unclassified_records = countEntryValue(correction_status.summary.influence_kind_counts, "unknownInfluenceCandidate") +
            countEntryValue(nk_status.summary.influence_kind_counts, "unknownInfluenceCandidate"),
        .read_caps_hit = correction_read_cap_hit or nk_read_cap_hit,
        .byte_caps_hit = correction_byte_cap_hit or nk_byte_cap_hit,
    };

    const returned_records = records.items.len;
    for (nk_status.records.items) |*record| record.deinit(allocator);
    nk_status.records.deinit();

    return .{
        .allocator = allocator,
        .project_shard = try allocator.dupe(u8, request.project_shard),
        .correction_status = correction_status,
        .negative_knowledge_summary = nk_status.summary,
        .negative_knowledge_warnings = try nk_status.warnings.toOwnedSlice(),
        .records = try records.toOwnedSlice(),
        .warning_summary = warning_summary,
        .capacity_telemetry = .{
            .correction_records_read = correction_status.records_read,
            .correction_read_cap_hit = correction_read_cap_hit,
            .correction_byte_cap_hit = correction_byte_cap_hit,
            .negative_knowledge_records_read = nk_status.records_read,
            .negative_knowledge_read_cap_hit = nk_read_cap_hit,
            .negative_knowledge_byte_cap_hit = nk_byte_cap_hit,
            .include_records = request.include_records,
            .limit = limit,
            .returned_records = returned_records,
            .limit_hit = limit_hit,
        },
        .storage = .{
            .correction_missing_file = correction_status.missing_file,
            .negative_knowledge_missing_file = nk_status.missing_file,
        },
    };
}

const NkStatusScratch = struct {
    allocator: std.mem.Allocator,
    summary: NegativeKnowledgeSummary,
    warnings: std.ArrayList(negative_knowledge_review.ReadWarning),
    records: std.ArrayList(NkRecordScratch),
    records_read: usize = 0,
    max_records_hit: bool = false,
    limit_hit: bool = false,
    truncated: bool = false,
    missing_file: bool = false,

    fn deinit(self: *NkStatusScratch, allocator: std.mem.Allocator) void {
        self.summary.deinit(allocator);
        for (self.warnings.items) |*warning| warning.deinit(allocator);
        self.warnings.deinit();
        for (self.records.items) |*record| record.deinit(allocator);
        self.records.deinit();
        self.* = undefined;
    }
};

const NkRecordScratch = struct {
    id: []u8,
    decision: []u8,
    record_json: []u8,
    line_number: usize,

    fn deinit(self: *NkRecordScratch, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.decision);
        allocator.free(self.record_json);
        self.* = undefined;
    }
};

fn readNegativeKnowledgeStatus(allocator: std.mem.Allocator, project_shard: []const u8, include_records: bool, limit: usize) !NkStatusScratch {
    var operation_counts = std.StringArrayHashMap(usize).init(allocator);
    defer deinitCountMap(allocator, &operation_counts);
    var influence_counts = std.StringArrayHashMap(usize).init(allocator);
    defer deinitCountMap(allocator, &influence_counts);
    var scratch = NkStatusScratch{
        .allocator = allocator,
        .summary = .{},
        .warnings = std.ArrayList(negative_knowledge_review.ReadWarning).init(allocator),
        .records = std.ArrayList(NkRecordScratch).init(allocator),
    };
    errdefer scratch.deinit(allocator);

    const path = try negative_knowledge_review.reviewedNegativeKnowledgePath(allocator, project_shard);
    defer allocator.free(path);
    const data = readNkFileBounded(allocator, path, &scratch.warnings) catch |err| switch (err) {
        error.FileNotFound => {
            scratch.summary.operation_kind_counts = try emptyCountEntries(allocator);
            scratch.summary.influence_kind_counts = try emptyCountEntries(allocator);
            scratch.missing_file = true;
            return scratch;
        },
        else => return err,
    };
    defer allocator.free(data.bytes);
    scratch.truncated = data.truncated;

    var emitted: usize = 0;
    var line_number: usize = 1;
    var lines = std.mem.splitScalar(u8, data.bytes, '\n');
    while (lines.next()) |raw_line| : (line_number += 1) {
        const line = std.mem.trim(u8, raw_line, " \r\t");
        if (line.len == 0) continue;
        if (scratch.records_read >= negative_knowledge_review.MAX_REVIEWED_NEGATIVE_KNOWLEDGE_READ) {
            scratch.max_records_hit = true;
            try appendNkWarning(allocator, &scratch.warnings, line_number, "reviewed negative knowledge record read limit reached");
            break;
        }
        scratch.records_read += 1;

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch {
            scratch.summary.malformed_lines += 1;
            try appendNkWarning(allocator, &scratch.warnings, line_number, "malformed reviewed negative knowledge JSONL line ignored");
            continue;
        };
        defer parsed.deinit();

        const obj = valueObject(parsed.value) orelse {
            scratch.summary.malformed_lines += 1;
            try appendNkWarning(allocator, &scratch.warnings, line_number, "reviewed negative knowledge line was not an object");
            continue;
        };
        const record_shard = getStr(obj, "projectShard") orelse getStr(obj, "project_shard") orelse {
            scratch.summary.malformed_lines += 1;
            try appendNkWarning(allocator, &scratch.warnings, line_number, "reviewed negative knowledge missing projectShard");
            continue;
        };
        if (!std.mem.eql(u8, record_shard, project_shard)) continue;
        const id = getStr(obj, "id") orelse {
            scratch.summary.malformed_lines += 1;
            try appendNkWarning(allocator, &scratch.warnings, line_number, "reviewed negative knowledge missing id");
            continue;
        };
        const decision_text = getStr(obj, "reviewDecision") orelse {
            scratch.summary.malformed_lines += 1;
            try appendNkWarning(allocator, &scratch.warnings, line_number, "reviewed negative knowledge missing reviewDecision");
            continue;
        };
        const decision = negative_knowledge_review.Decision.parse(decision_text) orelse {
            scratch.summary.malformed_lines += 1;
            try appendNkWarning(allocator, &scratch.warnings, line_number, "reviewed negative knowledge had invalid reviewDecision");
            continue;
        };

        scratch.summary.reviewed_records += 1;
        switch (decision) {
            .accepted => {
                scratch.summary.accepted_records += 1;
                try summarizeNkAccepted(allocator, obj, &scratch.summary, &operation_counts, &influence_counts);
            },
            .rejected => scratch.summary.rejected_records += 1,
        }

        if (include_records) {
            if (emitted >= limit) {
                scratch.limit_hit = true;
                continue;
            }
            emitted += 1;
            try scratch.records.append(.{
                .id = try allocator.dupe(u8, id),
                .decision = try allocator.dupe(u8, decision_text),
                .record_json = try allocator.dupe(u8, line),
                .line_number = line_number,
            });
        }
    }
    scratch.max_records_hit = scratch.max_records_hit or data.truncated;
    scratch.summary.operation_kind_counts = try countEntriesFromMap(allocator, &operation_counts);
    scratch.summary.influence_kind_counts = try countEntriesFromMap(allocator, &influence_counts);
    return scratch;
}

fn summarizeNkAccepted(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    summary: *NegativeKnowledgeSummary,
    operation_counts: *std.StringArrayHashMap(usize),
    influence_counts: *std.StringArrayHashMap(usize),
) !void {
    if (futureInfluencePresent(obj)) summary.future_behavior_candidate_count += 1;
    const candidate_value = obj.get("negativeKnowledgeCandidate") orelse obj.get("negative_knowledge_candidate");
    const candidate = if (candidate_value) |value| valueObject(value) else null;
    if (candidate) |c| {
        if (firstNonEmpty(&.{ getStr(c, "operationKind"), getStr(c, "operation_kind"), getStr(c, "appliesTo"), getStr(c, "applies_to") })) |op| {
            try incrementCount(allocator, operation_counts, op);
        }
        const kind = nkInfluenceKind(c);
        try incrementCount(allocator, influence_counts, kind);
        if (std.mem.eql(u8, kind, "suppress_exact_repeat")) summary.suppression_candidate_count += 1;
        if (std.mem.eql(u8, kind, "require_stronger_evidence")) summary.stronger_evidence_candidate_count += 1;
        if (std.mem.eql(u8, kind, "require_verifier_candidate")) summary.verifier_candidate_count += 1;
        if (std.mem.eql(u8, kind, "propose_pack_guidance")) summary.pack_guidance_candidate_count += 1;
        if (std.mem.eql(u8, kind, "propose_corpus_update")) summary.corpus_update_candidate_count += 1;
        if (std.mem.eql(u8, kind, "propose_rule_update")) summary.rule_update_candidate_count += 1;
    } else {
        try incrementCount(allocator, influence_counts, "unknownInfluenceCandidate");
    }
}

fn nkInfluenceKind(candidate: std.json.ObjectMap) []const u8 {
    if (firstNonEmpty(&.{ getStr(candidate, "influenceKind"), getStr(candidate, "influence_kind") })) |kind| return kind;
    if (hasNonEmpty(candidate, &.{ "suppressionRule", "suppression_rule", "suppressExactRepeat", "suppress_exact_repeat" })) return "suppress_exact_repeat";
    if (hasNonEmpty(candidate, &.{ "verifierRequirement", "verifier_requirement", "requiredVerifier", "required_verifier" })) return "require_verifier_candidate";
    if (hasNonEmpty(candidate, &.{ "strongerEvidenceRequirement", "stronger_evidence_requirement", "evidenceRef", "evidence_ref" })) return "require_stronger_evidence";
    if (hasNonEmpty(candidate, &.{ "packGuidanceCandidate", "pack_guidance_candidate", "trustDecaySuggestion", "trust_decay_suggestion" })) return "propose_pack_guidance";
    if (hasNonEmpty(candidate, &.{ "corpusUpdateCandidate", "corpus_update_candidate" })) return "propose_corpus_update";
    if (hasNonEmpty(candidate, &.{ "ruleUpdateCandidate", "rule_update_candidate" })) return "propose_rule_update";
    const kind_text = getStr(candidate, "kind") orelse "";
    if (std.mem.eql(u8, kind_text, "unsafe_verifier_candidate") or std.mem.eql(u8, kind_text, "insufficient_test")) return "require_verifier_candidate";
    if (std.mem.eql(u8, kind_text, "overbroad_rule")) return "propose_rule_update";
    if (std.mem.eql(u8, kind_text, "stale_source_claim")) return "require_stronger_evidence";
    if (std.mem.eql(u8, kind_text, "forbidden_project_pattern") or std.mem.eql(u8, kind_text, "failed_hypothesis")) return "suppress_exact_repeat";
    return "warning";
}

fn futureInfluencePresent(obj: std.json.ObjectMap) bool {
    const value = obj.get("futureInfluenceCandidate") orelse return false;
    return value != .null;
}

fn readNkFileBounded(allocator: std.mem.Allocator, abs_path: []const u8, warnings: *std.ArrayList(negative_knowledge_review.ReadWarning)) !ReviewedFileBytes {
    const file = std.fs.openFileAbsolute(abs_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => return err,
    };
    defer file.close();

    const file_size = try file.getEndPos();
    const read_len: usize = @intCast(@min(file_size, negative_knowledge_review.MAX_REVIEWED_NEGATIVE_KNOWLEDGE_BYTES));
    var data = try allocator.alloc(u8, read_len);
    errdefer allocator.free(data);
    const actual = try file.readAll(data);
    if (actual != read_len) data = try allocator.realloc(data, actual);
    const truncated = file_size > negative_knowledge_review.MAX_REVIEWED_NEGATIVE_KNOWLEDGE_BYTES;
    if (truncated) try appendNkWarning(allocator, warnings, 0, "reviewed negative knowledge file exceeded bounded read size; later records were not read");
    return .{ .bytes = data, .truncated = truncated };
}

fn appendNkWarning(allocator: std.mem.Allocator, warnings: *std.ArrayList(negative_knowledge_review.ReadWarning), line_number: usize, reason: []const u8) !void {
    if (warnings.items.len >= negative_knowledge_review.MAX_REVIEWED_NEGATIVE_KNOWLEDGE_WARNINGS) return;
    try warnings.append(.{
        .line_number = line_number,
        .reason = try allocator.dupe(u8, reason),
    });
}

fn incrementCount(allocator: std.mem.Allocator, map: *std.StringArrayHashMap(usize), name: []const u8) !void {
    if (map.getEntry(name)) |entry| {
        entry.value_ptr.* += 1;
        return;
    }
    const owned = try allocator.dupe(u8, name);
    errdefer allocator.free(owned);
    try map.put(owned, 1);
}

fn countEntriesFromMap(allocator: std.mem.Allocator, map: *std.StringArrayHashMap(usize)) ![]correction_review.CountEntry {
    var entries = try allocator.alloc(correction_review.CountEntry, map.count());
    errdefer allocator.free(entries);
    var idx: usize = 0;
    var it = map.iterator();
    while (it.next()) |entry| : (idx += 1) {
        entries[idx] = .{
            .name = try allocator.dupe(u8, entry.key_ptr.*),
            .count = entry.value_ptr.*,
        };
    }
    return entries;
}

fn emptyCountEntries(allocator: std.mem.Allocator) ![]correction_review.CountEntry {
    return allocator.alloc(correction_review.CountEntry, 0);
}

fn deinitCountMap(allocator: std.mem.Allocator, map: *std.StringArrayHashMap(usize)) void {
    for (map.keys()) |key| allocator.free(key);
    map.deinit();
}

fn countEntryValue(entries: []const correction_review.CountEntry, name: []const u8) usize {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.count;
    }
    return 0;
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

test "learning status no file returns zero summary without mutation" {
    const allocator = std.testing.allocator;
    const shard_id = "learning-status-no-file-test";
    var metadata = try shards.resolveProjectMetadata(allocator, shard_id);
    defer metadata.deinit();
    var paths = try shards.resolvePaths(allocator, metadata.metadata);
    defer paths.deinit();
    std.fs.deleteTreeAbsolute(paths.root_abs_path) catch {};

    var status = try readStatus(allocator, .{ .project_shard = shard_id });
    defer status.deinit();
    try std.testing.expect(status.storage.correction_missing_file);
    try std.testing.expect(status.storage.negative_knowledge_missing_file);
    try std.testing.expectEqual(@as(usize, 0), status.correction_status.summary.total_records);
    try std.testing.expectEqual(@as(usize, 0), status.negative_knowledge_summary.reviewed_records);
    try std.testing.expectEqual(@as(usize, 0), status.records.len);
    try std.testing.expect(!status.warning_summary.read_caps_hit);
    try std.testing.expect(!status.warning_summary.byte_caps_hit);
}

test "learning status counts reviewed corrections and negative knowledge with samples and caps" {
    const allocator = std.testing.allocator;
    const shard_id = "learning-status-populated-test";
    var metadata = try shards.resolveProjectMetadata(allocator, shard_id);
    defer metadata.deinit();
    var paths = try shards.resolvePaths(allocator, metadata.metadata);
    defer paths.deinit();
    std.fs.deleteTreeAbsolute(paths.root_abs_path) catch {};
    defer std.fs.deleteTreeAbsolute(paths.root_abs_path) catch {};

    var correction_accepted = try correction_review.reviewAndAppend(allocator, .{
        .project_shard = shard_id,
        .decision = .accepted,
        .reviewer_note = "accepted correction",
        .rejected_reason = null,
        .source_candidate_id = "correction:candidate:learning-status-accepted",
        .correction_candidate_json =
        \\{"id":"correction:candidate:learning-status-accepted","originalOperationKind":"corpus.ask","disputedOutput":{"kind":"answerDraft","summary":"bad answer"},"userCorrection":"suppress exact bad answer","correctionType":"wrong_answer"}
        ,
        .accepted_learning_outputs_json = "[{\"kind\":\"verifier_check_candidate\",\"status\":\"candidate\"}]",
    });
    defer correction_accepted.deinit();
    var correction_rejected = try correction_review.reviewAndAppend(allocator, .{
        .project_shard = shard_id,
        .decision = .rejected,
        .reviewer_note = "rejected correction",
        .rejected_reason = "not valid",
        .source_candidate_id = "correction:candidate:learning-status-rejected",
        .correction_candidate_json =
        \\{"id":"correction:candidate:learning-status-rejected","originalOperationKind":"rule.evaluate","disputedOutput":{"kind":"rule_candidate","summary":"bad rule"},"userCorrection":"ignore","correctionType":"misleading_rule"}
        ,
        .accepted_learning_outputs_json = "[]",
    });
    defer correction_rejected.deinit();
    var nk_accepted = try negative_knowledge_review.reviewAndAppend(allocator, .{
        .project_shard = shard_id,
        .decision = .accepted,
        .reviewer_note = "accepted nk",
        .rejected_reason = null,
        .source_candidate_id = "nk:candidate:learning-status-accepted",
        .negative_knowledge_candidate_json =
        \\{"id":"nk:candidate:learning-status-accepted","operationKind":"rule.evaluate","kind":"overbroad_rule","condition":"bad rule","ruleUpdateCandidate":"tighten","nonAuthorizing":true}
        ,
    });
    defer nk_accepted.deinit();
    var nk_rejected = try negative_knowledge_review.reviewAndAppend(allocator, .{
        .project_shard = shard_id,
        .decision = .rejected,
        .reviewer_note = "rejected nk",
        .rejected_reason = "not valid",
        .source_candidate_id = "nk:candidate:learning-status-rejected",
        .negative_knowledge_candidate_json = "{\"id\":\"nk:candidate:learning-status-rejected\"}",
    });
    defer nk_rejected.deinit();
    const correction_path = try correction_review.reviewedCorrectionsPath(allocator, shard_id);
    defer allocator.free(correction_path);
    var correction_file = try std.fs.openFileAbsolute(correction_path, .{ .mode = .write_only });
    defer correction_file.close();
    try correction_file.seekFromEnd(0);
    try correction_file.writeAll("{malformed correction}\n");
    const nk_path = try negative_knowledge_review.reviewedNegativeKnowledgePath(allocator, shard_id);
    defer allocator.free(nk_path);
    var nk_file = try std.fs.openFileAbsolute(nk_path, .{ .mode = .write_only });
    defer nk_file.close();
    try nk_file.seekFromEnd(0);
    try nk_file.writeAll("{malformed nk}\n");

    var no_records = try readStatus(allocator, .{ .project_shard = shard_id });
    defer no_records.deinit();
    try std.testing.expectEqual(@as(usize, 0), no_records.records.len);
    try std.testing.expectEqual(@as(usize, 2), no_records.correction_status.summary.total_records);
    try std.testing.expectEqual(@as(usize, 1), no_records.correction_status.summary.accepted_records);
    try std.testing.expectEqual(@as(usize, 1), no_records.correction_status.summary.rejected_records);
    try std.testing.expectEqual(@as(usize, 1), no_records.correction_status.summary.malformed_lines);
    try std.testing.expectEqual(@as(usize, 2), no_records.negative_knowledge_summary.reviewed_records);
    try std.testing.expectEqual(@as(usize, 1), no_records.negative_knowledge_summary.accepted_records);
    try std.testing.expectEqual(@as(usize, 1), no_records.negative_knowledge_summary.rejected_records);
    try std.testing.expectEqual(@as(usize, 1), no_records.negative_knowledge_summary.malformed_lines);
    try std.testing.expectEqual(@as(usize, 1), no_records.negative_knowledge_summary.rule_update_candidate_count);
    try std.testing.expectEqual(@as(usize, 1), no_records.warning_summary.malformed_reviewed_correction_lines);
    try std.testing.expectEqual(@as(usize, 1), no_records.warning_summary.malformed_reviewed_negative_knowledge_lines);

    var sampled = try readStatus(allocator, .{ .project_shard = shard_id, .include_records = true, .limit = 1 });
    defer sampled.deinit();
    try std.testing.expectEqual(@as(usize, 1), sampled.records.len);
    try std.testing.expect(sampled.capacity_telemetry.limit_hit);
    try std.testing.expect(!sampled.warning_summary.read_caps_hit);

    var capped = try readStatus(allocator, .{ .project_shard = shard_id, .include_records = true, .limit = 4 });
    defer capped.deinit();
    try std.testing.expectEqual(@as(usize, 4), capped.records.len);
}

test "learning status reports reviewed record read caps" {
    const allocator = std.testing.allocator;
    const shard_id = "learning-status-read-cap-test";
    var metadata = try shards.resolveProjectMetadata(allocator, shard_id);
    defer metadata.deinit();
    var paths = try shards.resolvePaths(allocator, metadata.metadata);
    defer paths.deinit();
    std.fs.deleteTreeAbsolute(paths.root_abs_path) catch {};
    defer std.fs.deleteTreeAbsolute(paths.root_abs_path) catch {};

    var i: usize = 0;
    while (i < correction_review.MAX_REVIEWED_CORRECTIONS_READ + 1) : (i += 1) {
        const candidate = try std.fmt.allocPrint(allocator, "{{\"id\":\"correction:candidate:cap-{d}\",\"originalOperationKind\":\"corpus.ask\",\"disputedOutput\":{{\"kind\":\"answerDraft\",\"summary\":\"bad {d}\"}},\"correctionType\":\"wrong_answer\"}}", .{ i, i });
        defer allocator.free(candidate);
        var reviewed = try correction_review.reviewAndAppend(allocator, .{
            .project_shard = shard_id,
            .decision = .accepted,
            .reviewer_note = "cap test",
            .rejected_reason = null,
            .source_candidate_id = "correction:candidate:cap",
            .correction_candidate_json = candidate,
            .accepted_learning_outputs_json = "[]",
        });
        reviewed.deinit();
    }
    i = 0;
    while (i < negative_knowledge_review.MAX_REVIEWED_NEGATIVE_KNOWLEDGE_READ + 1) : (i += 1) {
        const candidate = try std.fmt.allocPrint(allocator, "{{\"id\":\"nk:candidate:cap-{d}\",\"operationKind\":\"rule.evaluate\",\"kind\":\"overbroad_rule\",\"condition\":\"bad {d}\",\"ruleUpdateCandidate\":\"tighten\",\"nonAuthorizing\":true}}", .{ i, i });
        defer allocator.free(candidate);
        var reviewed = try negative_knowledge_review.reviewAndAppend(allocator, .{
            .project_shard = shard_id,
            .decision = .accepted,
            .reviewer_note = "cap test",
            .rejected_reason = null,
            .source_candidate_id = "nk:candidate:cap",
            .negative_knowledge_candidate_json = candidate,
        });
        reviewed.deinit();
    }

    var status = try readStatus(allocator, .{ .project_shard = shard_id });
    defer status.deinit();
    try std.testing.expect(status.warning_summary.read_caps_hit);
    try std.testing.expect(status.capacity_telemetry.correction_read_cap_hit);
    try std.testing.expect(status.capacity_telemetry.negative_knowledge_read_cap_hit);
    try std.testing.expectEqual(@as(usize, correction_review.MAX_REVIEWED_CORRECTIONS_READ), status.capacity_telemetry.correction_records_read);
    try std.testing.expectEqual(@as(usize, negative_knowledge_review.MAX_REVIEWED_NEGATIVE_KNOWLEDGE_READ), status.capacity_telemetry.negative_knowledge_records_read);
}
