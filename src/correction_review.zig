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

pub const ReviewedCorrectionRecord = struct {
    id: []u8,
    decision: Decision,
    operation_kind: []u8,
    record_json: []u8,
    line_number: usize,

    pub fn deinit(self: *ReviewedCorrectionRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.operation_kind);
        allocator.free(self.record_json);
        self.* = undefined;
    }
};

pub const CountEntry = struct {
    name: []u8,
    count: usize,

    pub fn deinit(self: *CountEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.* = undefined;
    }
};

pub const InfluenceStatusRecord = struct {
    id: []u8,
    decision: Decision,
    operation_kind: []u8,
    correction_type: []u8,
    record_json: []u8,
    line_number: usize,

    pub fn deinit(self: *InfluenceStatusRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.operation_kind);
        allocator.free(self.correction_type);
        allocator.free(self.record_json);
        self.* = undefined;
    }
};

pub const InfluenceStatusSummary = struct {
    total_records: usize = 0,
    accepted_records: usize = 0,
    rejected_records: usize = 0,
    malformed_lines: usize = 0,
    operation_kind_counts: []CountEntry = &.{},
    correction_type_counts: []CountEntry = &.{},
    influence_kind_counts: []CountEntry = &.{},
    suppression_candidate_count: usize = 0,
    stronger_evidence_candidate_count: usize = 0,
    verifier_candidate_count: usize = 0,
    negative_knowledge_candidate_count: usize = 0,
    corpus_update_candidate_count: usize = 0,
    pack_guidance_candidate_count: usize = 0,
    rule_update_candidate_count: usize = 0,
    future_behavior_candidate_count: usize = 0,

    pub fn deinit(self: *InfluenceStatusSummary, allocator: std.mem.Allocator) void {
        for (self.operation_kind_counts) |*entry| entry.deinit(allocator);
        allocator.free(self.operation_kind_counts);
        for (self.correction_type_counts) |*entry| entry.deinit(allocator);
        allocator.free(self.correction_type_counts);
        for (self.influence_kind_counts) |*entry| entry.deinit(allocator);
        allocator.free(self.influence_kind_counts);
        self.* = undefined;
    }
};

pub const InfluenceStatusResult = struct {
    allocator: std.mem.Allocator,
    summary: InfluenceStatusSummary,
    warnings: []ReadWarning,
    records: []InfluenceStatusRecord,
    records_read: usize,
    returned_count: usize,
    truncated: bool,
    max_records_hit: bool,
    limit_hit: bool,
    limit: usize,
    include_records: bool,
    missing_file: bool,

    pub fn deinit(self: *InfluenceStatusResult) void {
        self.summary.deinit(self.allocator);
        for (self.warnings) |*warning| warning.deinit(self.allocator);
        self.allocator.free(self.warnings);
        for (self.records) |*record| record.deinit(self.allocator);
        self.allocator.free(self.records);
        self.* = undefined;
    }
};

pub const InspectionResult = struct {
    allocator: std.mem.Allocator,
    records: []ReviewedCorrectionRecord,
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
    record: ?ReviewedCorrectionRecord,
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

pub fn listReviewedCorrections(
    allocator: std.mem.Allocator,
    project_shard: []const u8,
    decision_filter: DecisionFilter,
    operation_kind_filter: ?[]const u8,
    limit: usize,
    offset: usize,
    max_records: usize,
) !InspectionResult {
    const path = try reviewedCorrectionsPath(allocator, project_shard);
    defer allocator.free(path);
    return listReviewedCorrectionsAtPath(allocator, path, project_shard, decision_filter, operation_kind_filter, limit, offset, max_records);
}

pub fn getReviewedCorrection(allocator: std.mem.Allocator, project_shard: []const u8, id: []const u8, max_records: usize) !GetResult {
    const path = try reviewedCorrectionsPath(allocator, project_shard);
    defer allocator.free(path);
    return getReviewedCorrectionAtPath(allocator, path, project_shard, id, max_records);
}

pub fn correctionInfluenceStatus(
    allocator: std.mem.Allocator,
    project_shard: []const u8,
    operation_kind_filter: ?[]const u8,
    include_records: bool,
    limit: usize,
    max_records: usize,
) !InfluenceStatusResult {
    const path = try reviewedCorrectionsPath(allocator, project_shard);
    defer allocator.free(path);
    return correctionInfluenceStatusAtPath(allocator, path, project_shard, operation_kind_filter, include_records, limit, max_records);
}

pub fn listReviewedCorrectionsAtPath(
    allocator: std.mem.Allocator,
    abs_path: []const u8,
    project_shard: []const u8,
    decision_filter: DecisionFilter,
    operation_kind_filter: ?[]const u8,
    limit: usize,
    offset: usize,
    max_records: usize,
) !InspectionResult {
    var records = std.ArrayList(ReviewedCorrectionRecord).init(allocator);
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
            try appendReadWarning(allocator, &warnings, line_number, "reviewed correction record read limit reached");
            break;
        }
        total_read += 1;

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
        const record_shard = getStr(obj, "projectShard") orelse {
            malformed_lines += 1;
            try appendReadWarning(allocator, &warnings, line_number, "reviewed correction missing projectShard");
            continue;
        };
        if (!std.mem.eql(u8, record_shard, project_shard)) continue;
        const decision_text = getStr(obj, "reviewDecision") orelse {
            malformed_lines += 1;
            try appendReadWarning(allocator, &warnings, line_number, "reviewed correction missing reviewDecision");
            continue;
        };
        const decision = Decision.parse(decision_text) orelse {
            malformed_lines += 1;
            try appendReadWarning(allocator, &warnings, line_number, "reviewed correction had invalid reviewDecision");
            continue;
        };
        if (!decision_filter.matches(decision)) continue;
        const operation_kind = recordOperationKind(obj) orelse "";
        if (operation_kind_filter) |filter| {
            if (!std.mem.eql(u8, operation_kind, filter)) continue;
        }

        if (matched_seen < offset) {
            matched_seen += 1;
            continue;
        }
        matched_seen += 1;
        if (emitted >= limit) {
            limit_hit = true;
            continue;
        }
        try records.append(try duplicateReviewedRecord(allocator, obj, line, decision, operation_kind, line_number));
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

pub fn correctionInfluenceStatusAtPath(
    allocator: std.mem.Allocator,
    abs_path: []const u8,
    project_shard: []const u8,
    operation_kind_filter: ?[]const u8,
    include_records: bool,
    limit: usize,
    max_records: usize,
) !InfluenceStatusResult {
    var operation_counts = std.StringArrayHashMap(usize).init(allocator);
    defer deinitCountMap(allocator, &operation_counts);
    var correction_counts = std.StringArrayHashMap(usize).init(allocator);
    defer deinitCountMap(allocator, &correction_counts);
    var influence_counts = std.StringArrayHashMap(usize).init(allocator);
    defer deinitCountMap(allocator, &influence_counts);
    var records = std.ArrayList(InfluenceStatusRecord).init(allocator);
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
            .summary = .{
                .operation_kind_counts = try emptyCountEntries(allocator),
                .correction_type_counts = try emptyCountEntries(allocator),
                .influence_kind_counts = try emptyCountEntries(allocator),
            },
            .warnings = try warnings.toOwnedSlice(),
            .records = try records.toOwnedSlice(),
            .records_read = 0,
            .returned_count = 0,
            .truncated = false,
            .max_records_hit = false,
            .limit_hit = false,
            .limit = limit,
            .include_records = include_records,
            .missing_file = true,
        },
        else => return err,
    };
    defer allocator.free(data.bytes);

    var summary = InfluenceStatusSummary{};
    var records_read: usize = 0;
    var returned_count: usize = 0;
    var max_records_hit = false;
    var limit_hit = false;
    var line_number: usize = 1;
    var lines = std.mem.splitScalar(u8, data.bytes, '\n');
    while (lines.next()) |raw_line| : (line_number += 1) {
        const line = std.mem.trim(u8, raw_line, " \r\t");
        if (line.len == 0) continue;
        if (records_read >= max_records) {
            max_records_hit = true;
            try appendReadWarning(allocator, &warnings, line_number, "reviewed correction record read limit reached");
            break;
        }
        records_read += 1;

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch {
            summary.malformed_lines += 1;
            try appendReadWarning(allocator, &warnings, line_number, "malformed reviewed correction JSONL line ignored");
            continue;
        };
        defer parsed.deinit();

        const obj = valueObject(parsed.value) orelse {
            summary.malformed_lines += 1;
            try appendReadWarning(allocator, &warnings, line_number, "reviewed correction line was not an object");
            continue;
        };
        const record_shard = getStr(obj, "projectShard") orelse {
            summary.malformed_lines += 1;
            try appendReadWarning(allocator, &warnings, line_number, "reviewed correction missing projectShard");
            continue;
        };
        if (!std.mem.eql(u8, record_shard, project_shard)) continue;
        const decision_text = getStr(obj, "reviewDecision") orelse {
            summary.malformed_lines += 1;
            try appendReadWarning(allocator, &warnings, line_number, "reviewed correction missing reviewDecision");
            continue;
        };
        const decision = Decision.parse(decision_text) orelse {
            summary.malformed_lines += 1;
            try appendReadWarning(allocator, &warnings, line_number, "reviewed correction had invalid reviewDecision");
            continue;
        };
        const operation_kind = recordOperationKind(obj) orelse "unknown";
        if (operation_kind_filter) |filter| {
            if (!std.mem.eql(u8, operation_kind, filter)) continue;
        }
        const correction_type = recordCorrectionType(obj) orelse "unknown";

        summary.total_records += 1;
        switch (decision) {
            .accepted => summary.accepted_records += 1,
            .rejected => summary.rejected_records += 1,
        }
        try incrementCount(allocator, &operation_counts, operation_kind);
        try incrementCount(allocator, &correction_counts, correction_type);

        if (decision == .accepted) {
            try summarizeAcceptedInfluence(allocator, obj, operation_kind, correction_type, &summary, &influence_counts);
        }

        if (include_records) {
            if (returned_count < limit) {
                try records.append(try duplicateInfluenceStatusRecord(allocator, obj, line, decision, operation_kind, correction_type, line_number));
                returned_count += 1;
            } else {
                limit_hit = true;
            }
        }
    }

    summary.operation_kind_counts = try countEntriesFromMap(allocator, &operation_counts);
    summary.correction_type_counts = try countEntriesFromMap(allocator, &correction_counts);
    summary.influence_kind_counts = try countEntriesFromMap(allocator, &influence_counts);

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
        .limit = limit,
        .include_records = include_records,
        .missing_file = false,
    };
}

pub fn getReviewedCorrectionAtPath(allocator: std.mem.Allocator, abs_path: []const u8, project_shard: []const u8, id: []const u8, max_records: usize) !GetResult {
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
            try appendReadWarning(allocator, &warnings, line_number, "reviewed correction record read limit reached");
            break;
        }
        total_read += 1;

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
        const record_shard = getStr(obj, "projectShard") orelse {
            malformed_lines += 1;
            try appendReadWarning(allocator, &warnings, line_number, "reviewed correction missing projectShard");
            continue;
        };
        if (!std.mem.eql(u8, record_shard, project_shard)) continue;
        const record_id = getStr(obj, "id") orelse {
            malformed_lines += 1;
            try appendReadWarning(allocator, &warnings, line_number, "reviewed correction missing id");
            continue;
        };
        const decision_text = getStr(obj, "reviewDecision") orelse {
            malformed_lines += 1;
            try appendReadWarning(allocator, &warnings, line_number, "reviewed correction missing reviewDecision");
            continue;
        };
        const decision = Decision.parse(decision_text) orelse {
            malformed_lines += 1;
            try appendReadWarning(allocator, &warnings, line_number, "reviewed correction had invalid reviewDecision");
            continue;
        };
        if (std.mem.eql(u8, record_id, id)) {
            return .{
                .allocator = allocator,
                .record = try duplicateReviewedRecord(allocator, obj, line, decision, recordOperationKind(obj) orelse "", line_number),
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
    const read_len: usize = @intCast(@min(file_size, MAX_REVIEWED_CORRECTIONS_BYTES));
    var data = try allocator.alloc(u8, read_len);
    errdefer allocator.free(data);
    const actual = try file.readAll(data);
    if (actual != read_len) data = try allocator.realloc(data, actual);
    const truncated = file_size > MAX_REVIEWED_CORRECTIONS_BYTES;
    if (truncated) try appendReadWarning(allocator, warnings, 0, "reviewed correction file exceeded bounded read size; later records were not read");
    return .{ .bytes = data, .truncated = truncated };
}

fn duplicateReviewedRecord(allocator: std.mem.Allocator, obj: std.json.ObjectMap, line: []const u8, decision: Decision, operation_kind: []const u8, line_number: usize) !ReviewedCorrectionRecord {
    const id = getStr(obj, "id") orelse return error.InvalidReviewedCorrectionRecord;
    return .{
        .id = try allocator.dupe(u8, id),
        .decision = decision,
        .operation_kind = try allocator.dupe(u8, operation_kind),
        .record_json = try allocator.dupe(u8, line),
        .line_number = line_number,
    };
}

fn duplicateInfluenceStatusRecord(allocator: std.mem.Allocator, obj: std.json.ObjectMap, line: []const u8, decision: Decision, operation_kind: []const u8, correction_type: []const u8, line_number: usize) !InfluenceStatusRecord {
    const id = getStr(obj, "id") orelse return error.InvalidReviewedCorrectionRecord;
    return .{
        .id = try allocator.dupe(u8, id),
        .decision = decision,
        .operation_kind = try allocator.dupe(u8, operation_kind),
        .correction_type = try allocator.dupe(u8, correction_type),
        .record_json = try allocator.dupe(u8, line),
        .line_number = line_number,
    };
}

fn recordOperationKind(obj: std.json.ObjectMap) ?[]const u8 {
    const candidate_value = obj.get("correctionCandidate") orelse return null;
    const candidate = valueObject(candidate_value) orelse return null;
    return getStr(candidate, "originalOperationKind") orelse getStr(candidate, "operationKind");
}

fn recordCorrectionType(obj: std.json.ObjectMap) ?[]const u8 {
    const candidate_value = obj.get("correctionCandidate") orelse return null;
    const candidate = valueObject(candidate_value) orelse return null;
    return getStr(candidate, "correctionType");
}

fn summarizeAcceptedInfluence(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    operation_kind: []const u8,
    correction_type: []const u8,
    summary: *InfluenceStatusSummary,
    influence_counts: *std.StringArrayHashMap(usize),
) !void {
    if (futureBehaviorCandidatePresent(obj)) summary.future_behavior_candidate_count += 1;

    const accepted_outputs = obj.get("acceptedLearningOutputs");
    var saw_learning_output = false;
    if (accepted_outputs) |value| {
        if (value == .array) {
            for (value.array.items) |item| {
                const output = valueObject(item) orelse continue;
                const kind = getStr(output, "kind") orelse continue;
                saw_learning_output = true;
                try incrementCount(allocator, influence_counts, kind);
                countLearningOutputKind(summary, kind);
            }
        }
    }

    const candidate_value = obj.get("correctionCandidate");
    const candidate = if (candidate_value) |value| valueObject(value) else null;
    const disputed = if (candidate) |c| c.get("disputedOutput") else null;
    const disputed_obj = if (disputed) |value| valueObject(value) else null;
    const disputed_kind = if (disputed_obj) |d| getStr(d, "kind") else null;

    if (influenceKindForCorrection(operation_kind, correction_type, disputed_kind)) |kind| {
        try incrementCount(allocator, influence_counts, @tagName(kind));
        countInfluenceKind(summary, kind, operation_kind, correction_type);
    } else if (!saw_learning_output) {
        try incrementCount(allocator, influence_counts, "unknownInfluenceCandidate");
    }
}

fn futureBehaviorCandidatePresent(obj: std.json.ObjectMap) bool {
    const value = obj.get("futureBehaviorCandidate") orelse return false;
    return value != .null;
}

fn countLearningOutputKind(summary: *InfluenceStatusSummary, kind: []const u8) void {
    if (std.mem.eql(u8, kind, "negative_knowledge_candidate")) summary.negative_knowledge_candidate_count += 1;
    if (std.mem.eql(u8, kind, "corpus_update_candidate")) summary.corpus_update_candidate_count += 1;
    if (std.mem.eql(u8, kind, "pack_guidance_candidate")) summary.pack_guidance_candidate_count += 1;
    if (std.mem.eql(u8, kind, "verifier_check_candidate")) summary.verifier_candidate_count += 1;
    if (std.mem.eql(u8, kind, "follow_up_evidence_request")) summary.stronger_evidence_candidate_count += 1;
    if (std.mem.eql(u8, kind, "rule_update_candidate")) summary.rule_update_candidate_count += 1;
}

fn countInfluenceKind(summary: *InfluenceStatusSummary, kind: InfluenceKind, operation_kind: []const u8, correction_type: []const u8) void {
    switch (kind) {
        .suppress_exact_repeat => summary.suppression_candidate_count += 1,
        .require_stronger_evidence => summary.stronger_evidence_candidate_count += 1,
        .require_verifier_candidate => summary.verifier_candidate_count += 1,
        .propose_negative_knowledge => summary.negative_knowledge_candidate_count += 1,
        .propose_corpus_update => summary.corpus_update_candidate_count += 1,
        .propose_pack_guidance => summary.pack_guidance_candidate_count += 1,
        .warning, .penalty => {},
    }
    if (std.mem.eql(u8, operation_kind, "rule.evaluate") and std.mem.eql(u8, correction_type, "misleading_rule")) {
        summary.rule_update_candidate_count += 1;
    }
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

fn countEntriesFromMap(allocator: std.mem.Allocator, map: *std.StringArrayHashMap(usize)) ![]CountEntry {
    var entries = try allocator.alloc(CountEntry, map.count());
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

fn emptyCountEntries(allocator: std.mem.Allocator) ![]CountEntry {
    return allocator.alloc(CountEntry, 0);
}

fn deinitCountMap(allocator: std.mem.Allocator, map: *std.StringArrayHashMap(usize)) void {
    for (map.keys()) |key| allocator.free(key);
    map.deinit();
}

fn influenceFromRecord(allocator: std.mem.Allocator, obj: std.json.ObjectMap, line_number: usize) !?AcceptedCorrectionInfluence {
    const record_id = getStr(obj, "id") orelse return null;
    const candidate_value = obj.get("correctionCandidate") orelse return null;
    const candidate = valueObject(candidate_value) orelse return null;
    const operation_kind = getStr(candidate, "originalOperationKind") orelse getStr(candidate, "operationKind") orelse return null;
    if (!std.mem.eql(u8, operation_kind, "corpus.ask") and !std.mem.eql(u8, operation_kind, "rule.evaluate")) return null;
    const correction_type = getStr(candidate, "correctionType") orelse return null;

    const disputed = candidate.get("disputedOutput");
    const disputed_obj = if (disputed) |value| valueObject(value) else null;
    const disputed_kind = if (disputed_obj) |d| getStr(d, "kind") else null;
    const kind = influenceKindForCorrection(operation_kind, correction_type, disputed_kind) orelse return null;
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
        .reason = try allocator.dupe(u8, influenceReason(kind, operation_kind, correction_type)),
        .applies_to = try allocator.dupe(u8, operation_kind),
        .operation_kind = try allocator.dupe(u8, operation_kind),
        .correction_type = try allocator.dupe(u8, correction_type),
        .matched_pattern = try allocator.dupe(u8, pattern),
        .disputed_output_fingerprint = fingerprint,
    };
}

fn influenceKindForCorrection(operation_kind: []const u8, correction_type: []const u8, disputed_kind: ?[]const u8) ?InfluenceKind {
    if (std.mem.eql(u8, operation_kind, "rule.evaluate")) {
        if (std.mem.eql(u8, correction_type, "misleading_rule")) return .warning;
        if (std.mem.eql(u8, correction_type, "unsafe_candidate")) return .require_verifier_candidate;
        if (std.mem.eql(u8, correction_type, "repeated_failed_pattern")) return .suppress_exact_repeat;
        if (std.mem.eql(u8, correction_type, "missing_evidence")) return .require_stronger_evidence;
        if (std.mem.eql(u8, correction_type, "wrong_answer")) {
            if (disputed_kind) |kind| {
                if (std.mem.eql(u8, kind, "rule_candidate")) return .suppress_exact_repeat;
            }
        }
        return null;
    }

    if (std.mem.eql(u8, correction_type, "wrong_answer")) return .suppress_exact_repeat;
    if (std.mem.eql(u8, correction_type, "bad_evidence")) return .require_stronger_evidence;
    if (std.mem.eql(u8, correction_type, "missing_evidence")) return .require_verifier_candidate;
    if (std.mem.eql(u8, correction_type, "repeated_failed_pattern")) return .propose_negative_knowledge;
    if (std.mem.eql(u8, correction_type, "outdated_corpus")) return .propose_corpus_update;
    if (std.mem.eql(u8, correction_type, "misleading_rule")) return .propose_pack_guidance;
    if (std.mem.eql(u8, correction_type, "unsafe_candidate")) return .warning;
    return null;
}

fn influenceReason(kind: InfluenceKind, operation_kind: []const u8, correction_type: []const u8) []const u8 {
    if (std.mem.eql(u8, operation_kind, "rule.evaluate")) {
        if (std.mem.eql(u8, correction_type, "misleading_rule")) return "accepted reviewed correction warns on a repeated misleading rule output pattern";
        if (std.mem.eql(u8, correction_type, "unsafe_candidate")) return "accepted reviewed correction requires stronger review and verifier/check candidate for unsafe rule output";
        if (std.mem.eql(u8, correction_type, "missing_evidence")) return "accepted reviewed correction requires explicit evidence expectation before relying on this rule output";
        if (std.mem.eql(u8, correction_type, "repeated_failed_pattern")) return "accepted reviewed correction suppresses an exact repeated bad rule output pattern";
    }
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

test "read accepted reviewed correction influences supports rule evaluate same shard only" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, "reviewed-rules.jsonl" });
    defer allocator.free(path);

    const accepted = try renderRecordJson(allocator, .{
        .project_shard = "phase9b",
        .decision = .accepted,
        .reviewer_note = "accepted unsafe rule output",
        .rejected_reason = null,
        .source_candidate_id = "correction:candidate:rule-accepted",
        .correction_candidate_json =
        \\{"id":"correction:candidate:rule-accepted","originalOperationKind":"rule.evaluate","originalRequestSummary":"rule:deploy","disputedOutput":{"kind":"rule_candidate","ref":"check.deploy","summary":"deploy candidate skips review"},"userCorrection":"unsafe rule candidate needs verifier review","correctionType":"unsafe_candidate"}
        ,
        .accepted_learning_outputs_json = "[{\"kind\":\"verifier_check_candidate\"}]",
    }, 0);
    defer allocator.free(accepted);
    const rejected = try renderRecordJson(allocator, .{
        .project_shard = "phase9b",
        .decision = .rejected,
        .reviewer_note = "not applicable",
        .rejected_reason = "not repeated",
        .source_candidate_id = "correction:candidate:rule-rejected",
        .correction_candidate_json =
        \\{"id":"correction:candidate:rule-rejected","originalOperationKind":"rule.evaluate","disputedOutput":{"kind":"rule_candidate","ref":"check.deploy"},"userCorrection":"ignore","correctionType":"unsafe_candidate"}
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

    var read = try readAcceptedInfluencesAtPath(allocator, path, "phase9b", MAX_REVIEWED_CORRECTIONS_READ);
    defer read.deinit();
    try std.testing.expectEqual(@as(usize, 1), read.influences.len);
    try std.testing.expectEqual(@as(usize, 3), read.records_read);
    try std.testing.expectEqual(@as(usize, 1), read.accepted_records);
    try std.testing.expectEqual(@as(usize, 1), read.rejected_records);
    try std.testing.expectEqual(@as(usize, 1), read.malformed_lines);
    try std.testing.expectEqual(InfluenceKind.require_verifier_candidate, read.influences[0].influence_kind);
    try std.testing.expectEqualStrings("rule.evaluate", read.influences[0].applies_to);
    try std.testing.expect(read.influences[0].non_authorizing);
    try std.testing.expect(!read.influences[0].treated_as_proof);
    try std.testing.expect(!read.influences[0].global_promotion);
    try std.testing.expect(!read.influences[0].mutation_flags.commands_executed);

    var other_shard = try readAcceptedInfluencesAtPath(allocator, path, "other-phase9b", MAX_REVIEWED_CORRECTIONS_READ);
    defer other_shard.deinit();
    try std.testing.expectEqual(@as(usize, 0), other_shard.influences.len);
}

test "correction influence status no file returns zero read-only summary" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, "missing.jsonl" });
    defer allocator.free(path);

    var status = try correctionInfluenceStatusAtPath(allocator, path, "phase10a", null, false, 0, MAX_REVIEWED_CORRECTIONS_READ);
    defer status.deinit();
    try std.testing.expect(status.missing_file);
    try std.testing.expectEqual(@as(usize, 0), status.summary.total_records);
    try std.testing.expectEqual(@as(usize, 0), status.summary.accepted_records);
    try std.testing.expectEqual(@as(usize, 0), status.summary.rejected_records);
    try std.testing.expectEqual(@as(usize, 0), status.summary.malformed_lines);
    try std.testing.expectEqual(@as(usize, 0), status.records.len);
    try std.testing.expect(!status.include_records);
}

test "correction influence status counts accepted rejected malformed and operation filter" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, "reviewed-status.jsonl" });
    defer allocator.free(path);

    const accepted_corpus = try renderRecordJson(allocator, .{
        .project_shard = "phase10a",
        .decision = .accepted,
        .reviewer_note = "accepted wrong answer",
        .rejected_reason = null,
        .source_candidate_id = "correction:candidate:corpus",
        .correction_candidate_json =
        \\{"id":"correction:candidate:corpus","originalOperationKind":"corpus.ask","originalRequestSummary":"retention enabled","disputedOutput":{"kind":"answerDraft","summary":"Retention policy is enabled"},"userCorrection":"suppress this repeated answer","correctionType":"wrong_answer"}
        ,
        .accepted_learning_outputs_json = "[{\"kind\":\"verifier_check_candidate\"},{\"kind\":\"negative_knowledge_candidate\"}]",
    }, 0);
    defer allocator.free(accepted_corpus);
    const rejected_rule = try renderRecordJson(allocator, .{
        .project_shard = "phase10a",
        .decision = .rejected,
        .reviewer_note = "rejected rule issue",
        .rejected_reason = "not repeated",
        .source_candidate_id = "correction:candidate:rule-rejected",
        .correction_candidate_json =
        \\{"id":"correction:candidate:rule-rejected","originalOperationKind":"rule.evaluate","disputedOutput":{"kind":"rule_candidate","summary":"deploy candidate"},"userCorrection":"ignore","correctionType":"misleading_rule"}
        ,
        .accepted_learning_outputs_json = "[]",
    }, accepted_corpus.len + 1);
    defer allocator.free(rejected_rule);
    const accepted_rule = try renderRecordJson(allocator, .{
        .project_shard = "phase10a",
        .decision = .accepted,
        .reviewer_note = "accepted misleading rule",
        .rejected_reason = null,
        .source_candidate_id = "correction:candidate:rule",
        .correction_candidate_json =
        \\{"id":"correction:candidate:rule","originalOperationKind":"rule.evaluate","originalRequestSummary":"deploy rule","disputedOutput":{"kind":"rule_candidate","summary":"deploy candidate"},"userCorrection":"this rule candidate is misleading","correctionType":"misleading_rule"}
        ,
        .accepted_learning_outputs_json = "[{\"kind\":\"pack_guidance_candidate\"}]",
    }, accepted_corpus.len + rejected_rule.len + 2);
    defer allocator.free(accepted_rule);

    var file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll("{malformed json}\n");
    try file.writeAll(accepted_corpus);
    try file.writeAll("\n");
    try file.writeAll(rejected_rule);
    try file.writeAll("\n");
    try file.writeAll(accepted_rule);
    try file.writeAll("\n");

    var status = try correctionInfluenceStatusAtPath(allocator, path, "phase10a", null, true, 2, MAX_REVIEWED_CORRECTIONS_READ);
    defer status.deinit();
    try std.testing.expectEqual(@as(usize, 3), status.summary.total_records);
    try std.testing.expectEqual(@as(usize, 2), status.summary.accepted_records);
    try std.testing.expectEqual(@as(usize, 1), status.summary.rejected_records);
    try std.testing.expectEqual(@as(usize, 1), status.summary.malformed_lines);
    try std.testing.expectEqual(@as(usize, 2), status.records.len);
    try std.testing.expect(status.limit_hit);
    try std.testing.expectEqual(@as(usize, 1), countFor(status.summary.operation_kind_counts, "corpus.ask"));
    try std.testing.expectEqual(@as(usize, 2), countFor(status.summary.operation_kind_counts, "rule.evaluate"));
    try std.testing.expectEqual(@as(usize, 1), countFor(status.summary.correction_type_counts, "wrong_answer"));
    try std.testing.expectEqual(@as(usize, 2), countFor(status.summary.correction_type_counts, "misleading_rule"));
    try std.testing.expectEqual(@as(usize, 1), status.summary.suppression_candidate_count);
    try std.testing.expectEqual(@as(usize, 1), status.summary.negative_knowledge_candidate_count);
    try std.testing.expectEqual(@as(usize, 1), status.summary.verifier_candidate_count);
    try std.testing.expectEqual(@as(usize, 1), status.summary.pack_guidance_candidate_count);
    try std.testing.expectEqual(@as(usize, 1), status.summary.rule_update_candidate_count);
    try std.testing.expectEqual(@as(usize, 2), status.summary.future_behavior_candidate_count);

    var filtered = try correctionInfluenceStatusAtPath(allocator, path, "phase10a", "rule.evaluate", false, 0, MAX_REVIEWED_CORRECTIONS_READ);
    defer filtered.deinit();
    try std.testing.expectEqual(@as(usize, 2), filtered.summary.total_records);
    try std.testing.expectEqual(@as(usize, 1), filtered.summary.accepted_records);
    try std.testing.expectEqual(@as(usize, 1), filtered.summary.rejected_records);
    try std.testing.expectEqual(@as(usize, 0), filtered.records.len);
    try std.testing.expectEqual(@as(usize, 0), countFor(filtered.summary.operation_kind_counts, "corpus.ask"));
}

test "correction influence status reports max record cap" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, "reviewed-cap.jsonl" });
    defer allocator.free(path);

    const first = try renderRecordJson(allocator, .{
        .project_shard = "phase10a-cap",
        .decision = .accepted,
        .reviewer_note = "accepted",
        .rejected_reason = null,
        .source_candidate_id = "correction:candidate:first",
        .correction_candidate_json =
        \\{"id":"correction:candidate:first","originalOperationKind":"corpus.ask","disputedOutput":{"kind":"answerDraft","summary":"first"},"userCorrection":"first","correctionType":"wrong_answer"}
        ,
        .accepted_learning_outputs_json = "[]",
    }, 0);
    defer allocator.free(first);
    const second = try renderRecordJson(allocator, .{
        .project_shard = "phase10a-cap",
        .decision = .accepted,
        .reviewer_note = "accepted",
        .rejected_reason = null,
        .source_candidate_id = "correction:candidate:second",
        .correction_candidate_json =
        \\{"id":"correction:candidate:second","originalOperationKind":"corpus.ask","disputedOutput":{"kind":"answerDraft","summary":"second"},"userCorrection":"second","correctionType":"wrong_answer"}
        ,
        .accepted_learning_outputs_json = "[]",
    }, first.len + 1);
    defer allocator.free(second);

    var file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(first);
    try file.writeAll("\n");
    try file.writeAll(second);
    try file.writeAll("\n");

    var status = try correctionInfluenceStatusAtPath(allocator, path, "phase10a-cap", null, true, 8, 1);
    defer status.deinit();
    try std.testing.expect(status.max_records_hit);
    try std.testing.expectEqual(@as(usize, 1), status.records_read);
    try std.testing.expectEqual(@as(usize, 1), status.summary.total_records);
    try std.testing.expectEqual(@as(usize, 1), status.records.len);
    try std.testing.expect(status.warnings.len > 0);
}

fn countFor(entries: []const CountEntry, name: []const u8) usize {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.count;
    }
    return 0;
}
