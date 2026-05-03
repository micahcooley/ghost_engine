const std = @import("std");
const shards = @import("shards.zig");
const correction_review = @import("correction_review.zig");
const negative_knowledge_review = @import("negative_knowledge_review.zig");
const learning_status = @import("learning_status.zig");

pub const REVIEWED_PROCEDURE_PACK_CANDIDATES_REL_DIR = "procedure_packs";
pub const REVIEWED_PROCEDURE_PACK_CANDIDATES_FILE_NAME = "reviewed_pack_candidates.jsonl";
pub const SCHEMA_VERSION = "procedure_pack_candidate.v1";
pub const REVIEWED_SCHEMA_VERSION = "reviewed_procedure_pack_candidate.v1";
pub const MAX_REVIEWED_PROCEDURE_PACK_CANDIDATES_READ: usize = 128;
pub const MAX_REVIEWED_PROCEDURE_PACK_CANDIDATES_BYTES: usize = 256 * 1024;

pub const SourceKind = enum {
    reviewed_correction,
    reviewed_negative_knowledge,
    learning_status,

    pub fn parse(text: []const u8) ?SourceKind {
        if (std.mem.eql(u8, text, "reviewed_correction")) return .reviewed_correction;
        if (std.mem.eql(u8, text, "correction")) return .reviewed_correction;
        if (std.mem.eql(u8, text, "reviewed_negative_knowledge")) return .reviewed_negative_knowledge;
        if (std.mem.eql(u8, text, "negative_knowledge")) return .reviewed_negative_knowledge;
        if (std.mem.eql(u8, text, "learning_status")) return .learning_status;
        if (std.mem.eql(u8, text, "learning.status")) return .learning_status;
        return null;
    }
};

pub const CandidateKind = enum {
    verifier_procedure,
    debugging_procedure,
    corpus_review_procedure,
    rule_guidance_procedure,
    negative_knowledge_procedure,

    pub fn parse(text: []const u8) ?CandidateKind {
        inline for (std.meta.fields(CandidateKind)) |field| {
            if (std.mem.eql(u8, text, field.name)) return @enumFromInt(field.value);
        }
        return null;
    }
};

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

pub const ProposeRequest = struct {
    project_shard: []const u8,
    source_kind: SourceKind,
    source_id: ?[]const u8 = null,
    candidate_kind_override: ?CandidateKind = null,
};

pub const ProposalResult = struct {
    allocator: std.mem.Allocator,
    candidate_json: []u8,
    source_record_json: ?[]u8 = null,
    source_warnings: []correction_review.ReadWarning = &.{},
    storage_path: ?[]u8 = null,
    missing_source: bool = false,

    pub fn deinit(self: *ProposalResult) void {
        self.allocator.free(self.candidate_json);
        if (self.source_record_json) |value| self.allocator.free(value);
        for (self.source_warnings) |*warning| warning.deinit(self.allocator);
        self.allocator.free(self.source_warnings);
        if (self.storage_path) |value| self.allocator.free(value);
        self.* = undefined;
    }
};

pub const ReviewRequest = struct {
    project_shard: []const u8,
    decision: Decision,
    reviewer_note: []const u8,
    rejected_reason: ?[]const u8 = null,
    procedure_pack_candidate_json: []const u8,
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

pub const ReviewedCandidateRecord = struct {
    id: []u8,
    decision: Decision,
    candidate_id: []u8,
    candidate_kind: []u8,
    record_json: []u8,
    line_number: usize,

    pub fn deinit(self: *ReviewedCandidateRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.candidate_id);
        allocator.free(self.candidate_kind);
        allocator.free(self.record_json);
        self.* = undefined;
    }
};

pub const InspectionResult = struct {
    allocator: std.mem.Allocator,
    records: []ReviewedCandidateRecord,
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
    record: ?ReviewedCandidateRecord,
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

pub fn reviewedProcedurePackCandidatesPath(allocator: std.mem.Allocator, project_shard: []const u8) ![]u8 {
    var metadata = try shards.resolveProjectMetadata(allocator, project_shard);
    defer metadata.deinit();
    var paths = try shards.resolvePaths(allocator, metadata.metadata);
    defer paths.deinit();
    return std.fs.path.join(allocator, &.{ paths.root_abs_path, REVIEWED_PROCEDURE_PACK_CANDIDATES_REL_DIR, REVIEWED_PROCEDURE_PACK_CANDIDATES_FILE_NAME });
}

pub fn propose(allocator: std.mem.Allocator, request: ProposeRequest) !ProposalResult {
    return switch (request.source_kind) {
        .reviewed_correction => proposeFromReviewedCorrection(allocator, request),
        .reviewed_negative_knowledge => proposeFromReviewedNegativeKnowledge(allocator, request),
        .learning_status => proposeFromLearningStatus(allocator, request),
    };
}

pub fn reviewAndAppend(allocator: std.mem.Allocator, request: ReviewRequest) !ReviewResult {
    const path = try reviewedProcedurePackCandidatesPath(allocator, request.project_shard);
    defer allocator.free(path);
    const parent = std.fs.path.dirname(path) orelse return error.InvalidPath;
    try std.fs.cwd().makePath(parent);

    var file = try std.fs.createFileAbsolute(path, .{ .read = true, .truncate = false });
    defer file.close();
    const append_offset = try file.getEndPos();
    try file.seekTo(append_offset);

    const record_json = try renderReviewedRecordJson(allocator, request, append_offset);
    errdefer allocator.free(record_json);
    try file.writeAll(record_json);
    try file.writeAll("\n");

    return .{
        .allocator = allocator,
        .record_json = record_json,
        .storage_path = try allocator.dupe(u8, path),
    };
}

pub fn listReviewedCandidates(
    allocator: std.mem.Allocator,
    project_shard: []const u8,
    decision_filter: DecisionFilter,
    limit: usize,
    offset: usize,
    max_records: usize,
) !InspectionResult {
    const path = try reviewedProcedurePackCandidatesPath(allocator, project_shard);
    defer allocator.free(path);
    return listReviewedCandidatesAtPath(allocator, path, project_shard, decision_filter, limit, offset, max_records);
}

pub fn getReviewedCandidate(allocator: std.mem.Allocator, project_shard: []const u8, id: []const u8, max_records: usize) !GetResult {
    const path = try reviewedProcedurePackCandidatesPath(allocator, project_shard);
    defer allocator.free(path);
    return getReviewedCandidateAtPath(allocator, path, project_shard, id, max_records);
}

fn proposeFromReviewedCorrection(allocator: std.mem.Allocator, request: ProposeRequest) !ProposalResult {
    const source_id = request.source_id orelse return error.MissingSourceId;
    var inspected = try correction_review.getReviewedCorrection(allocator, request.project_shard, source_id, correction_review.MAX_REVIEWED_CORRECTIONS_READ);
    defer inspected.deinit();
    if (inspected.record == null) {
        return .{
            .allocator = allocator,
            .candidate_json = try renderMissingSourceCandidate(allocator, request.project_shard, .reviewed_correction, source_id),
            .source_warnings = try convertCorrectionWarnings(allocator, inspected.warnings),
            .missing_source = true,
        };
    }
    const record = inspected.record.?;
    const candidate = try renderCandidateFromReviewedCorrection(
        allocator,
        request.project_shard,
        record.record_json,
        request.candidate_kind_override,
    );
    return .{
        .allocator = allocator,
        .candidate_json = candidate,
        .source_record_json = try allocator.dupe(u8, record.record_json),
        .source_warnings = try convertCorrectionWarnings(allocator, inspected.warnings),
    };
}

fn proposeFromReviewedNegativeKnowledge(allocator: std.mem.Allocator, request: ProposeRequest) !ProposalResult {
    const source_id = request.source_id orelse return error.MissingSourceId;
    var inspected = try negative_knowledge_review.getReviewedNegativeKnowledge(allocator, request.project_shard, source_id, negative_knowledge_review.MAX_REVIEWED_NEGATIVE_KNOWLEDGE_READ);
    defer inspected.deinit();
    if (inspected.record == null) {
        return .{
            .allocator = allocator,
            .candidate_json = try renderMissingSourceCandidate(allocator, request.project_shard, .reviewed_negative_knowledge, source_id),
            .source_warnings = try convertNkWarnings(allocator, inspected.warnings),
            .missing_source = true,
        };
    }
    const record = inspected.record.?;
    const candidate = try renderCandidateFromReviewedNegativeKnowledge(
        allocator,
        request.project_shard,
        record.record_json,
        request.candidate_kind_override,
    );
    return .{
        .allocator = allocator,
        .candidate_json = candidate,
        .source_record_json = try allocator.dupe(u8, record.record_json),
        .source_warnings = try convertNkWarnings(allocator, inspected.warnings),
    };
}

fn proposeFromLearningStatus(allocator: std.mem.Allocator, request: ProposeRequest) !ProposalResult {
    var status = try learning_status.readStatus(allocator, .{ .project_shard = request.project_shard });
    defer status.deinit();
    return .{
        .allocator = allocator,
        .candidate_json = try renderCandidateFromLearningStatus(allocator, request.project_shard, status, request.candidate_kind_override),
        .storage_path = try reviewedProcedurePackCandidatesPath(allocator, request.project_shard),
    };
}

fn renderCandidateFromReviewedCorrection(
    allocator: std.mem.Allocator,
    project_shard: []const u8,
    record_json: []const u8,
    override: ?CandidateKind,
) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, record_json, .{});
    defer parsed.deinit();
    const obj = valueObject(parsed.value) orelse return error.InvalidReviewedCorrectionRecord;
    const record_id = getStr(obj, "id") orelse return error.InvalidReviewedCorrectionRecord;
    const operation_kind = nestedStr(obj, "correctionCandidate", &.{ "originalOperationKind", "original_operation_kind" }) orelse "unknown";
    const correction_type = nestedStr(obj, "correctionCandidate", &.{ "correctionType", "correction_type" }) orelse "unknown";
    const candidate_kind = override orelse candidateKindForCorrection(operation_kind, correction_type);
    const summary = try std.fmt.allocPrint(allocator, "Procedure candidate from reviewed correction {s}: {s}", .{ record_id, correction_type });
    defer allocator.free(summary);
    const id = try candidateId(allocator, project_shard, "reviewed-correction", record_id, @tagName(candidate_kind));
    defer allocator.free(id);
    return renderCandidateJson(allocator, .{
        .id = id,
        .project_shard = project_shard,
        .source_kind = .reviewed_correction,
        .source_id = record_id,
        .candidate_kind = candidate_kind,
        .summary = summary,
        .trigger = operation_kind,
        .required_evidence = "same-shard reviewed correction record plus fresh task evidence",
        .step_one = "Inspect the reviewed correction record and identify the disputed output pattern.",
        .step_two = "Collect independent current evidence before changing any answer, rule, corpus, verifier, or pack behavior.",
    });
}

fn renderCandidateFromReviewedNegativeKnowledge(
    allocator: std.mem.Allocator,
    project_shard: []const u8,
    record_json: []const u8,
    override: ?CandidateKind,
) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, record_json, .{});
    defer parsed.deinit();
    const obj = valueObject(parsed.value) orelse return error.InvalidReviewedNegativeKnowledgeRecord;
    const record_id = getStr(obj, "id") orelse return error.InvalidReviewedNegativeKnowledgeRecord;
    const candidate_kind = override orelse CandidateKind.negative_knowledge_procedure;
    const nk_kind = nestedStr(obj, "negativeKnowledgeCandidate", &.{ "kind", "candidateKind", "candidate_kind" }) orelse "negative_knowledge";
    const summary = try std.fmt.allocPrint(allocator, "Procedure candidate from reviewed negative knowledge {s}: {s}", .{ record_id, nk_kind });
    defer allocator.free(summary);
    const id = try candidateId(allocator, project_shard, "reviewed-negative-knowledge", record_id, @tagName(candidate_kind));
    defer allocator.free(id);
    return renderCandidateJson(allocator, .{
        .id = id,
        .project_shard = project_shard,
        .source_kind = .reviewed_negative_knowledge,
        .source_id = record_id,
        .candidate_kind = candidate_kind,
        .summary = summary,
        .trigger = nk_kind,
        .required_evidence = "same-shard reviewed negative-knowledge record plus independent positive evidence",
        .step_one = "Inspect the reviewed negative-knowledge pattern and identify the failure condition it warns about.",
        .step_two = "Require fresh supporting evidence before allowing a future workflow to rely on a similar output.",
    });
}

fn renderCandidateFromLearningStatus(
    allocator: std.mem.Allocator,
    project_shard: []const u8,
    status: learning_status.StatusResult,
    override: ?CandidateKind,
) ![]u8 {
    const candidate_kind = override orelse if (status.negative_knowledge_summary.reviewed_records > status.correction_status.summary.total_records)
        CandidateKind.negative_knowledge_procedure
    else
        CandidateKind.corpus_review_procedure;
    const summary = try std.fmt.allocPrint(
        allocator,
        "Procedure candidate from learning.status: corrections={d}, negativeKnowledge={d}, warnings={d}",
        .{
            status.correction_status.summary.total_records,
            status.negative_knowledge_summary.reviewed_records,
            status.warning_summary.capacity_warnings + status.warning_summary.unknown_or_unclassified_records,
        },
    );
    defer allocator.free(summary);
    const id = try candidateId(allocator, project_shard, "learning-status", project_shard, @tagName(candidate_kind));
    defer allocator.free(id);
    return renderCandidateJson(allocator, .{
        .id = id,
        .project_shard = project_shard,
        .source_kind = .learning_status,
        .source_id = "learning.status",
        .candidate_kind = candidate_kind,
        .summary = summary,
        .trigger = "learning.status reviewed-loop summary",
        .required_evidence = "learning.status summary plus specific reviewed records before any separate adoption",
        .step_one = "Review the same-shard learning.status counts and warnings for repeated candidate patterns.",
        .step_two = "Select concrete reviewed records before drafting a pack procedure for separate human review.",
    });
}

const CandidateRender = struct {
    id: []const u8,
    project_shard: []const u8,
    source_kind: SourceKind,
    source_id: []const u8,
    candidate_kind: CandidateKind,
    summary: []const u8,
    trigger: []const u8,
    required_evidence: []const u8,
    step_one: []const u8,
    step_two: []const u8,
};

fn renderCandidateJson(allocator: std.mem.Allocator, candidate: CandidateRender) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();
    try w.writeAll("{");
    try writeStringField(w, "id", candidate.id, true);
    try writeStringField(w, "schemaVersion", SCHEMA_VERSION, false);
    try writeStringField(w, "projectShard", candidate.project_shard, false);
    try writeStringField(w, "project_shard", candidate.project_shard, false);
    try writeStringField(w, "sourceKind", @tagName(candidate.source_kind), false);
    try writeStringField(w, "sourceReviewId", candidate.source_id, false);
    try writeStringField(w, "source_review_id", candidate.source_id, false);
    try writeStringField(w, "candidateKind", @tagName(candidate.candidate_kind), false);
    try writeStringField(w, "summary", candidate.summary, false);
    try w.writeAll(",\"triggers\":[");
    try writeJsonString(w, candidate.trigger);
    try w.writeAll("]");
    try w.writeAll(",\"steps\":[{\"order\":1,\"description\":");
    try writeJsonString(w, candidate.step_one);
    try w.writeAll(",\"executable\":false},{\"order\":2,\"description\":");
    try writeJsonString(w, candidate.step_two);
    try w.writeAll(",\"executable\":false}]");
    try w.writeAll(",\"requiredEvidence\":[");
    try writeJsonString(w, candidate.required_evidence);
    try w.writeAll("]");
    try w.writeAll(",\"safetyBoundaries\":[\"candidate-only\",\"not proof\",\"not evidence\",\"no pack mutation\",\"no global promotion\",\"no command execution\",\"no verifier execution\"]");
    try w.writeAll(",\"nonAuthorizing\":true,\"treatedAsProof\":false,\"usedAsEvidence\":false,\"executesByDefault\":false,\"packMutation\":false,\"globalPromotion\":false");
    try w.writeAll(",\"mutationFlags\":{\"corpusMutation\":false,\"packMutation\":false,\"negativeKnowledgeMutation\":false,\"commandsExecuted\":false,\"verifiersExecuted\":false}");
    try w.writeAll(",\"review\":{\"required\":true,\"persisted\":false,\"autoPromote\":false}");
    try w.writeAll("}");
    return out.toOwnedSlice();
}

fn renderMissingSourceCandidate(allocator: std.mem.Allocator, project_shard: []const u8, source_kind: SourceKind, source_id: []const u8) ![]u8 {
    const id = try candidateId(allocator, project_shard, "missing-source", source_id, "unresolved");
    defer allocator.free(id);
    return renderCandidateJson(allocator, .{
        .id = id,
        .project_shard = project_shard,
        .source_kind = source_kind,
        .source_id = source_id,
        .candidate_kind = .debugging_procedure,
        .summary = "Procedure pack candidate source was not found",
        .trigger = "missing reviewed source",
        .required_evidence = "existing same-shard reviewed source record",
        .step_one = "Inspect reviewed-source storage for the requested id.",
        .step_two = "Do not create, mutate, promote, or execute a pack procedure from a missing source.",
    });
}

fn renderReviewedRecordJson(allocator: std.mem.Allocator, request: ReviewRequest, append_offset: u64) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, request.procedure_pack_candidate_json, .{});
    defer parsed.deinit();
    const candidate_obj = valueObject(parsed.value) orelse return error.InvalidProcedurePackCandidate;
    const candidate_id = getStr(candidate_obj, "id") orelse return error.InvalidProcedurePackCandidate;
    const candidate_kind = getStr(candidate_obj, "candidateKind") orelse "unknown";
    const body_hash = std.hash.Fnv1a_64.hash(request.procedure_pack_candidate_json) ^ std.hash.Fnv1a_64.hash(request.reviewer_note);
    const id = try std.fmt.allocPrint(allocator, "reviewed-procedure-pack-candidate:{s}:{x:0>16}:{d}", .{ request.project_shard, body_hash, append_offset });
    defer allocator.free(id);

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();
    try w.writeAll("{");
    try writeStringField(w, "id", id, true);
    try writeStringField(w, "schemaVersion", REVIEWED_SCHEMA_VERSION, false);
    try writeStringField(w, "createdAt", "deterministic:append_order", false);
    try writeStringField(w, "reviewedAt", "deterministic:append_order", false);
    try writeStringField(w, "projectShard", request.project_shard, false);
    try writeStringField(w, "project_shard", request.project_shard, false);
    try writeStringField(w, "sourceCandidateId", candidate_id, false);
    try writeStringField(w, "candidateKind", candidate_kind, false);
    try w.writeAll(",\"procedurePackCandidate\":");
    try w.writeAll(request.procedure_pack_candidate_json);
    try writeStringField(w, "reviewDecision", @tagName(request.decision), false);
    try writeStringField(w, "reviewerNote", request.reviewer_note, false);
    try w.writeAll(",\"rejectedReason\":");
    if (request.decision == .rejected) try writeJsonString(w, request.rejected_reason orelse "") else try w.writeAll("null");
    try w.writeAll(",\"nonAuthorizing\":true,\"treatedAsProof\":false,\"usedAsEvidence\":false,\"executesByDefault\":false,\"packMutation\":false,\"globalPromotion\":false");
    try w.writeAll(",\"mutationFlags\":{\"corpusMutation\":false,\"packMutation\":false,\"negativeKnowledgeMutation\":false,\"commandsExecuted\":false,\"verifiersExecuted\":false}");
    try w.writeAll(",\"appendOnly\":{\"storage\":\"jsonl\",\"appendOffsetBytes\":");
    try w.print("{d}", .{append_offset});
    try w.writeAll(",\"inPlaceRewrite\":false,\"deletion\":false,\"compaction\":false,\"stableOrdering\":\"file_append_order\"}");
    try w.writeAll("}");
    return out.toOwnedSlice();
}

pub fn listReviewedCandidatesAtPath(
    allocator: std.mem.Allocator,
    abs_path: []const u8,
    project_shard: []const u8,
    decision_filter: DecisionFilter,
    limit: usize,
    offset: usize,
    max_records: usize,
) !InspectionResult {
    var records = std.ArrayList(ReviewedCandidateRecord).init(allocator);
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
            try appendReadWarning(allocator, &warnings, line_number, "reviewed procedure pack candidate read limit reached");
            break;
        }
        total_read += 1;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch {
            malformed_lines += 1;
            try appendReadWarning(allocator, &warnings, line_number, "malformed reviewed procedure pack candidate JSONL line ignored");
            continue;
        };
        defer parsed.deinit();
        const obj = valueObject(parsed.value) orelse {
            malformed_lines += 1;
            try appendReadWarning(allocator, &warnings, line_number, "reviewed procedure pack candidate line was not an object");
            continue;
        };
        const record_shard = getStr(obj, "projectShard") orelse getStr(obj, "project_shard") orelse {
            malformed_lines += 1;
            try appendReadWarning(allocator, &warnings, line_number, "reviewed procedure pack candidate missing projectShard");
            continue;
        };
        if (!std.mem.eql(u8, record_shard, project_shard)) continue;
        const decision_text = getStr(obj, "reviewDecision") orelse {
            malformed_lines += 1;
            try appendReadWarning(allocator, &warnings, line_number, "reviewed procedure pack candidate missing reviewDecision");
            continue;
        };
        const decision = Decision.parse(decision_text) orelse {
            malformed_lines += 1;
            try appendReadWarning(allocator, &warnings, line_number, "reviewed procedure pack candidate had invalid reviewDecision");
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

pub fn getReviewedCandidateAtPath(allocator: std.mem.Allocator, abs_path: []const u8, project_shard: []const u8, id: []const u8, max_records: usize) !GetResult {
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
            try appendReadWarning(allocator, &warnings, line_number, "reviewed procedure pack candidate read limit reached");
            break;
        }
        total_read += 1;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch {
            malformed_lines += 1;
            try appendReadWarning(allocator, &warnings, line_number, "malformed reviewed procedure pack candidate JSONL line ignored");
            continue;
        };
        defer parsed.deinit();
        const obj = valueObject(parsed.value) orelse {
            malformed_lines += 1;
            try appendReadWarning(allocator, &warnings, line_number, "reviewed procedure pack candidate line was not an object");
            continue;
        };
        const record_shard = getStr(obj, "projectShard") orelse getStr(obj, "project_shard") orelse {
            malformed_lines += 1;
            try appendReadWarning(allocator, &warnings, line_number, "reviewed procedure pack candidate missing projectShard");
            continue;
        };
        if (!std.mem.eql(u8, record_shard, project_shard)) continue;
        const record_id = getStr(obj, "id") orelse {
            malformed_lines += 1;
            try appendReadWarning(allocator, &warnings, line_number, "reviewed procedure pack candidate missing id");
            continue;
        };
        const decision_text = getStr(obj, "reviewDecision") orelse {
            malformed_lines += 1;
            try appendReadWarning(allocator, &warnings, line_number, "reviewed procedure pack candidate missing reviewDecision");
            continue;
        };
        const decision = Decision.parse(decision_text) orelse {
            malformed_lines += 1;
            try appendReadWarning(allocator, &warnings, line_number, "reviewed procedure pack candidate had invalid reviewDecision");
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
    const read_len: usize = @intCast(@min(file_size, MAX_REVIEWED_PROCEDURE_PACK_CANDIDATES_BYTES));
    var data = try allocator.alloc(u8, read_len);
    errdefer allocator.free(data);
    const actual = try file.readAll(data);
    if (actual != read_len) data = try allocator.realloc(data, actual);
    const truncated = file_size > MAX_REVIEWED_PROCEDURE_PACK_CANDIDATES_BYTES;
    if (truncated) try appendReadWarning(allocator, warnings, 0, "reviewed procedure pack candidate file exceeded bounded read size; later records were not read");
    return .{ .bytes = data, .truncated = truncated };
}

fn duplicateReviewedRecord(allocator: std.mem.Allocator, obj: std.json.ObjectMap, line: []const u8, decision: Decision, line_number: usize) !ReviewedCandidateRecord {
    const id = getStr(obj, "id") orelse return error.InvalidReviewedProcedurePackCandidate;
    const candidate_id = getStr(obj, "sourceCandidateId") orelse nestedStr(obj, "procedurePackCandidate", &.{"id"}) orelse "";
    const candidate_kind = getStr(obj, "candidateKind") orelse nestedStr(obj, "procedurePackCandidate", &.{"candidateKind"}) orelse "";
    return .{
        .id = try allocator.dupe(u8, id),
        .decision = decision,
        .candidate_id = try allocator.dupe(u8, candidate_id),
        .candidate_kind = try allocator.dupe(u8, candidate_kind),
        .record_json = try allocator.dupe(u8, line),
        .line_number = line_number,
    };
}

fn candidateKindForCorrection(operation_kind: []const u8, correction_type: []const u8) CandidateKind {
    if (std.mem.indexOf(u8, correction_type, "verifier") != null) return .verifier_procedure;
    if (std.mem.eql(u8, operation_kind, "rule.evaluate")) return .rule_guidance_procedure;
    if (std.mem.indexOf(u8, correction_type, "wrong_answer") != null) return .corpus_review_procedure;
    if (std.mem.indexOf(u8, correction_type, "missing_evidence") != null) return .debugging_procedure;
    return .debugging_procedure;
}

fn candidateId(allocator: std.mem.Allocator, project_shard: []const u8, source_label: []const u8, source_id: []const u8, kind: []const u8) ![]u8 {
    const hash = std.hash.Fnv1a_64.hash(source_id) ^ std.hash.Fnv1a_64.hash(kind);
    return std.fmt.allocPrint(allocator, "procedure-pack-candidate:{s}:{s}:{x:0>16}", .{ project_shard, source_label, hash });
}

fn convertCorrectionWarnings(allocator: std.mem.Allocator, warnings: []const correction_review.ReadWarning) ![]correction_review.ReadWarning {
    var out = try allocator.alloc(correction_review.ReadWarning, warnings.len);
    errdefer allocator.free(out);
    for (warnings, 0..) |warning, i| {
        out[i] = .{ .line_number = warning.line_number, .reason = try allocator.dupe(u8, warning.reason) };
    }
    return out;
}

fn convertNkWarnings(allocator: std.mem.Allocator, warnings: []const negative_knowledge_review.ReadWarning) ![]correction_review.ReadWarning {
    var out = try allocator.alloc(correction_review.ReadWarning, warnings.len);
    errdefer allocator.free(out);
    for (warnings, 0..) |warning, i| {
        out[i] = .{ .line_number = warning.line_number, .reason = try allocator.dupe(u8, warning.reason) };
    }
    return out;
}

fn appendReadWarning(allocator: std.mem.Allocator, warnings: *std.ArrayList(ReadWarning), line_number: usize, reason: []const u8) !void {
    if (warnings.items.len >= 8) return;
    try warnings.append(.{
        .line_number = line_number,
        .reason = try allocator.dupe(u8, reason),
    });
}

fn valueObject(value: std.json.Value) ?std.json.ObjectMap {
    return if (value == .object) value.object else null;
}

fn getStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn nestedStr(obj: std.json.ObjectMap, object_key: []const u8, field_names: []const []const u8) ?[]const u8 {
    const value = obj.get(object_key) orelse return null;
    const nested = valueObject(value) orelse return null;
    for (field_names) |field_name| {
        if (getStr(nested, field_name)) |text| return text;
    }
    return null;
}

fn writeStringField(w: anytype, name: []const u8, value: []const u8, first: bool) !void {
    if (!first) try w.writeByte(',');
    try w.writeByte('"');
    try w.writeAll(name);
    try w.writeAll("\":");
    try writeJsonString(w, value);
}

fn writeJsonString(w: anytype, value: []const u8) !void {
    try w.writeByte('"');
    for (value) |c| switch (c) {
        '\\' => try w.writeAll("\\\\"),
        '"' => try w.writeAll("\\\""),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}
