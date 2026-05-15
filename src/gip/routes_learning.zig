const std = @import("std");
const core = @import("../ghost.zig");
const sys = @import("../sys.zig");
const gip = @import("../gip.zig");
const ghost_state = @import("../ghost_state.zig");
const config = @import("../config.zig");
const knowledge_pack_store = @import("../knowledge_pack_store.zig");
const artifact_autopsy = @import("../artifact_autopsy.zig");
const project_autopsy = @import("../project_autopsy.zig");
const shards = @import("../shards.zig");
const learning_store = @import("../learning_store.zig");
const gip_utils = @import("utils.zig");
const getBool = gip_utils.getBool;
const getInt = gip_utils.getInt;
const writeEscaped = gip_utils.writeEscaped;
const boundedCount = gip_utils.boundedCount;
const writeCountEntriesJson = gip_utils.writeCountEntriesJson;
const writeReadWarningsJson = gip_utils.writeReadWarningsJson;
const countNamed = gip_utils.countNamed;
const writeNegativeKnowledgeReadWarningsJson = gip_utils.writeNegativeKnowledgeReadWarningsJson;
const getStr = gip_utils.getStr;

const learning_loop = @import("../learning_loop.zig");
const schema = @import("../gip_schema.zig");
const learning_status = @import("../learning_status.zig");
const writeLearningRecordsJson = @import("../gip_dispatch.zig").writeLearningRecordsJson;

const DispatchResult = @import("../gip_dispatch.zig").DispatchResult;
// Add any missing imports based on compiler errors

pub fn dispatchLearningReview(allocator: std.mem.Allocator, request_body: ?[]const u8) !DispatchResult {
    const body = request_body orelse return .{
        .status = .rejected,
        .err = .{ .code = .missing_required_field, .message = "request body is required for learning.review" },
    };

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return .{ .status = .rejected, .err = .{ .code = .json_contract_error, .message = "invalid JSON in request body" } };
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return .{ .status = .rejected, .err = .{ .code = .invalid_request, .message = "learning.review request must be a JSON object" } };
    }
    const obj = parsed.value.object;
    const decision_text = getStr(obj, "decision", "decision") orelse return .{
        .status = .rejected,
        .err = .{ .code = .missing_required_field, .message = "decision is required" },
    };
    const decision = learning_store.Decision.parse(decision_text) orelse return .{
        .status = .rejected,
        .err = .{ .code = .invalid_request, .message = "decision must be accepted or rejected", .details = decision_text },
    };
    const reviewer_note = getStr(obj, "reviewer_note", "reviewerNote") orelse return .{
        .status = .rejected,
        .err = .{ .code = .missing_required_field, .message = "reviewerNote is required" },
    };
    const project_shard = getStr(obj, "project_shard", "projectShard") orelse shards.DEFAULT_PROJECT_ID;
    const candidate_id = getStr(obj, "learning_candidate_id", "learningCandidateId") orelse return .{
        .status = .rejected,
        .err = .{ .code = .missing_required_field, .message = "learningCandidateId is required" },
    };
    const learning_candidate_json = if (obj.get("learningCandidate")) |candidate_value| try std.json.stringifyAlloc(allocator, candidate_value, .{}) else null;
    defer if (learning_candidate_json) |json| allocator.free(json);

    var outcome = try learning_store.reviewAndAppend(allocator, .{
        .project_shard = project_shard,
        .learning_candidate_id = candidate_id,
        .decision = decision,
        .reviewer_note = reviewer_note,
        .learning_candidate_json = learning_candidate_json,
    });
    defer outcome.deinit();

    if (outcome == .conflict) {
        const conflict = outcome.conflict;
        var out = std.ArrayList(u8).init(allocator);
        errdefer out.deinit();
        const w = out.writer();
        try w.writeAll("{\"learningReview\":{\"status\":\"ConflictDetected\",\"appendRefused\":true,\"projectShard\":\"");
        try writeEscaped(w, project_shard);
        try w.writeAll("\",\"learningCandidateId\":\"");
        try writeEscaped(w, candidate_id);
        try w.writeAll("\",\"conflictsWithRecordIds\":[");
        for (conflict.established_record_ids, 0..) |id, idx| {
            if (idx != 0) try w.writeByte(',');
            try w.writeByte('"');
            try writeEscaped(w, id);
            try w.writeByte('"');
        }
        try w.writeAll("],\"reason\":\"");
        try writeEscaped(w, conflict.reason);
        try w.writeAll("\",\"appendOnly\":{\"storage\":\"jsonl\",\"file\":\"learned_records.jsonl\",\"recordAppended\":false,\"inPlaceRewrite\":false,\"deletion\":false,\"compaction\":false},\"authority\":{\"nonAuthorizing\":true,\"treatedAsProof\":false,\"usedAsEvidence\":false,\"supportGranted\":false,\"proofDischarged\":false,\"globalPromotion\":false}}}");
        return .{
            .status = .rejected,
            .result_state = schema.unresolvedResultState("learning conflict detected"),
            .result_json = try out.toOwnedSlice(),
            .err = .{
                .code = .conflict_detected,
                .message = "ConflictDetected: accepted learning review contradicts established same-shard learning",
                .details = "see result.learningReview.conflictsWithRecordIds",
                .fix_hint = "review the established record before accepting contradictory learning into this shard",
                .severity = .warning,
            },
            .allocated_result = true,
        };
    }

    const result = outcome.appended;

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();
    try w.writeAll("{\"learningReview\":{\"status\":\"reviewed\",\"reviewedLearningRecord\":");
    try w.writeAll(result.record_json);
    try w.writeAll(",\"storage\":{\"path\":\"");
    try writeEscaped(w, result.storage_path);
    try w.writeAll("\",\"appendOnly\":true,\"file\":\"learned_records.jsonl\",\"inPlaceRewrite\":false,\"deletion\":false,\"compaction\":false,\"stableOrdering\":\"file_append_order\"}");
    try w.writeAll(",\"mutationFlags\":{\"corpusMutation\":false,\"packMutation\":false,\"negativeKnowledgeMutation\":false,\"correctionMutation\":false,\"commandsExecuted\":false,\"verifiersExecuted\":false}");
    try w.writeAll(",\"authority\":{\"nonAuthorizing\":true,\"treatedAsProof\":false,\"usedAsEvidence\":false,\"supportGranted\":false,\"proofDischarged\":false,\"globalPromotion\":false}}}");

    var gip_state = schema.draftResultState();
    gip_state.permission = .none;
    gip_state.verification_state = .unverified;
    gip_state.support_minimum_met = false;
    gip_state.non_authorization_notice = "learning.review persists append-only reviewed learning records only; accepted records may influence draft generation but are non-authorizing and not proof or evidence";
    return .{
        .status = .ok,
        .result_state = gip_state,
        .result_json = try out.toOwnedSlice(),
        .allocated_result = true,
    };
}

pub fn dispatchLearningStatus(allocator: std.mem.Allocator, request_body: ?[]const u8) !DispatchResult {
    var parsed: ?std.json.Parsed(std.json.Value) = null;
    defer if (parsed) |*p| p.deinit();

    var obj: ?std.json.ObjectMap = null;
    if (request_body) |body| {
        parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
            return .{ .status = .rejected, .err = .{ .code = .json_contract_error, .message = "invalid JSON in request body" } };
        };
        if (parsed.?.value != .object) {
            return .{ .status = .rejected, .err = .{ .code = .invalid_request, .message = "learning.status request must be a JSON object" } };
        }
        obj = parsed.?.value.object;
    }

    const project_shard = if (obj) |body_obj| getStr(body_obj, "project_shard", "projectShard") orelse shards.DEFAULT_PROJECT_ID else shards.DEFAULT_PROJECT_ID;
    const include_records = if (obj) |body_obj| getBool(body_obj, "include_records", "includeRecords") orelse false else false;
    const include_warnings = if (obj) |body_obj| getBool(body_obj, "include_warnings", "includeWarnings") orelse true else true;
    const limit = if (include_records and obj != null)
        boundedCount(obj.?, "limit", "limit", learning_status.MAX_LEARNING_STATUS_RECORDS, learning_status.MAX_LEARNING_STATUS_RECORDS)
    else if (include_records)
        learning_status.MAX_LEARNING_STATUS_RECORDS
    else
        0;

    var status = try learning_status.readStatus(allocator, .{
        .project_shard = project_shard,
        .include_records = include_records,
        .include_warnings = include_warnings,
        .limit = limit,
    });
    defer status.deinit();

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();
    try w.writeAll("{\"learningStatus\":{\"status\":\"ok\",\"projectShard\":\"");
    try writeEscaped(w, project_shard);
    try w.writeAll("\",\"readOnly\":true");
    try w.writeAll(",\"correctionSummary\":{");
    try w.print("\"reviewedCorrectionRecords\":{d},\"acceptedReviewedCorrections\":{d},\"rejectedReviewedCorrections\":{d},\"malformedCorrectionLines\":{d}", .{
        status.correction_status.summary.total_records,
        status.correction_status.summary.accepted_records,
        status.correction_status.summary.rejected_records,
        status.correction_status.summary.malformed_lines,
    });
    try w.writeAll(",\"correctionOperationKindCounts\":");
    try writeCountEntriesJson(w, status.correction_status.summary.operation_kind_counts);
    try w.writeAll(",\"correctionTypeCounts\":");
    try writeCountEntriesJson(w, status.correction_status.summary.correction_type_counts);
    try w.writeAll(",\"correctionInfluenceKindCounts\":");
    try writeCountEntriesJson(w, status.correction_status.summary.influence_kind_counts);
    try w.print(",\"correctionSuppressionCandidateCount\":{d},\"correctionFutureBehaviorCandidateCount\":{d}", .{
        status.correction_status.summary.suppression_candidate_count,
        status.correction_status.summary.future_behavior_candidate_count,
    });
    try w.writeAll("},\"negativeKnowledgeSummary\":{");
    try w.print("\"reviewedNegativeKnowledgeRecords\":{d},\"acceptedReviewedNegativeKnowledge\":{d},\"rejectedReviewedNegativeKnowledge\":{d},\"malformedNegativeKnowledgeLines\":{d}", .{
        status.negative_knowledge_summary.reviewed_records,
        status.negative_knowledge_summary.accepted_records,
        status.negative_knowledge_summary.rejected_records,
        status.negative_knowledge_summary.malformed_lines,
    });
    try w.writeAll(",\"negativeKnowledgeOperationKindCounts\":");
    try writeCountEntriesJson(w, status.negative_knowledge_summary.operation_kind_counts);
    try w.writeAll(",\"negativeKnowledgeInfluenceKindCounts\":");
    try writeCountEntriesJson(w, status.negative_knowledge_summary.influence_kind_counts);
    try w.print(",\"negativeKnowledgeSuppressionCandidateCount\":{d},\"negativeKnowledgeFutureBehaviorCandidateCount\":{d}", .{
        status.negative_knowledge_summary.suppression_candidate_count,
        status.negative_knowledge_summary.future_behavior_candidate_count,
    });
    try w.writeAll("},\"reviewedLearningSummary\":{");
    try w.print("\"reviewedLearningRecords\":{d},\"acceptedReviewedLearning\":{d},\"rejectedReviewedLearning\":{d},\"malformedLearningLines\":{d}", .{
        status.learning_status.summary.reviewed_records,
        status.learning_status.summary.accepted_records,
        status.learning_status.summary.rejected_records,
        status.learning_status.summary.malformed_lines,
    });
    try w.writeAll("},\"selfVerificationScoreboard\":{");
    try w.print("\"passed\":{d},\"failed\":{d},\"ambiguous\":{d}", .{
        status.learning_status.summary.self_verification_passed,
        status.learning_status.summary.self_verification_failed,
        status.learning_status.summary.self_verification_ambiguous,
    });
    try w.writeAll(",\"learningCandidateKindCounts\":");
    try writeCountEntriesJson(w, status.learning_status.summary.candidate_kind_counts);
    try w.writeAll("},\"influenceSummary\":{");
    const corpus_correction = countNamed(status.correction_status.summary.operation_kind_counts, "corpus.ask") > 0;
    const rule_correction = countNamed(status.correction_status.summary.operation_kind_counts, "rule.evaluate") > 0;
    const corpus_nk = countNamed(status.negative_knowledge_summary.operation_kind_counts, "corpus.ask") > 0;
    const rule_nk = countNamed(status.negative_knowledge_summary.operation_kind_counts, "rule.evaluate") > 0;
    const reviewed_learning_available = status.learning_status.summary.accepted_records > 0;
    const suppression = status.correction_status.summary.suppression_candidate_count + status.negative_knowledge_summary.suppression_candidate_count;
    const stronger = status.correction_status.summary.stronger_evidence_candidate_count + status.negative_knowledge_summary.stronger_evidence_candidate_count;
    const verifier = status.correction_status.summary.verifier_candidate_count + status.negative_knowledge_summary.verifier_candidate_count;
    const pack = status.correction_status.summary.pack_guidance_candidate_count + status.negative_knowledge_summary.pack_guidance_candidate_count;
    const corpus = status.correction_status.summary.corpus_update_candidate_count + status.negative_knowledge_summary.corpus_update_candidate_count;
    const rule = status.correction_status.summary.rule_update_candidate_count + status.negative_knowledge_summary.rule_update_candidate_count;
    const future = status.correction_status.summary.future_behavior_candidate_count + status.negative_knowledge_summary.future_behavior_candidate_count;
    try w.print("\"corpusAskCorrectionInfluenceAvailable\":{},\"ruleEvaluateCorrectionInfluenceAvailable\":{},\"corpusAskNegativeKnowledgeInfluenceAvailable\":{},\"ruleEvaluateNegativeKnowledgeInfluenceAvailable\":{},\"reviewedLearningInfluenceAvailable\":{}", .{
        corpus_correction,
        rule_correction,
        corpus_nk,
        rule_nk,
        reviewed_learning_available,
    });
    try w.print(",\"suppressionCapableRecords\":{d},\"strongerEvidenceCandidateCount\":{d},\"verifierCandidateCount\":{d},\"packGuidanceCandidateCount\":{d},\"corpusUpdateCandidateCount\":{d},\"ruleUpdateCandidateCount\":{d},\"futureBehaviorCandidateCount\":{d},\"unappliedCandidateCount\":{d}", .{
        suppression,
        stronger,
        verifier,
        pack,
        corpus,
        rule,
        future,
        future,
    });
    try w.writeAll("},\"warningSummary\":{");
    try w.print("\"malformedReviewedCorrectionLines\":{d},\"malformedReviewedNegativeKnowledgeLines\":{d},\"malformedReviewedLearningLines\":{d},\"capacityWarnings\":{d},\"unknownOrUnclassifiedRecords\":{d},\"readCapsHit\":{},\"byteCapsHit\":{}", .{
        status.warning_summary.malformed_reviewed_correction_lines,
        status.warning_summary.malformed_reviewed_negative_knowledge_lines,
        status.warning_summary.malformed_reviewed_learning_lines,
        status.warning_summary.capacity_warnings,
        status.warning_summary.unknown_or_unclassified_records,
        status.warning_summary.read_caps_hit,
        status.warning_summary.byte_caps_hit,
    });
    try w.writeAll("},\"capacityTelemetry\":{");
    try w.print("\"correctionRecordsRead\":{d},\"correctionMaxRecords\":{d},\"correctionReadCapHit\":{},\"correctionMaxBytes\":{d},\"correctionByteCapHit\":{},\"negativeKnowledgeRecordsRead\":{d},\"negativeKnowledgeMaxRecords\":{d},\"negativeKnowledgeReadCapHit\":{},\"negativeKnowledgeMaxBytes\":{d},\"negativeKnowledgeByteCapHit\":{},\"learningRecordsRead\":{d},\"learningMaxRecords\":{d},\"learningReadCapHit\":{},\"learningMaxBytes\":{d},\"learningByteCapHit\":{},\"includeRecords\":{},\"limit\":{d},\"returnedRecords\":{d},\"limitHit\":{}", .{
        status.capacity_telemetry.correction_records_read,
        status.capacity_telemetry.correction_max_records,
        status.capacity_telemetry.correction_read_cap_hit,
        status.capacity_telemetry.correction_max_bytes,
        status.capacity_telemetry.correction_byte_cap_hit,
        status.capacity_telemetry.negative_knowledge_records_read,
        status.capacity_telemetry.negative_knowledge_max_records,
        status.capacity_telemetry.negative_knowledge_read_cap_hit,
        status.capacity_telemetry.negative_knowledge_max_bytes,
        status.capacity_telemetry.negative_knowledge_byte_cap_hit,
        status.capacity_telemetry.learning_records_read,
        status.capacity_telemetry.learning_max_records,
        status.capacity_telemetry.learning_read_cap_hit,
        status.capacity_telemetry.learning_max_bytes,
        status.capacity_telemetry.learning_byte_cap_hit,
        status.capacity_telemetry.include_records,
        status.capacity_telemetry.limit,
        status.capacity_telemetry.returned_records,
        status.capacity_telemetry.limit_hit,
    });
    try w.writeAll("},\"storage\":{\"appendOnly\":true,\"correctionMissingFile\":");
    try w.print("{}", .{status.storage.correction_missing_file});
    try w.writeAll(",\"negativeKnowledgeMissingFile\":");
    try w.print("{}", .{status.storage.negative_knowledge_missing_file});
    try w.writeAll(",\"learningMissingFile\":");
    try w.print("{}", .{status.storage.learning_missing_file});
    try w.writeAll(",\"sameShardOnly\":true,\"readOnly\":true,\"inPlaceRewrite\":false,\"deletion\":false,\"compaction\":false,\"stableOrdering\":\"file_append_order\"}");
    if (include_warnings) {
        try w.writeAll(",\"warnings\":{\"corrections\":");
        try writeReadWarningsJson(w, status.correction_status.warnings);
        try w.writeAll(",\"negativeKnowledge\":");
        try writeNegativeKnowledgeReadWarningsJson(w, status.negative_knowledge_warnings);
        try w.writeAll("}");
    }
    if (include_records) {
        try w.writeAll(",\"records\":");
        try writeLearningRecordsJson(w, status.records);
    }
    try w.writeAll(",\"mutationFlags\":{\"corpusMutation\":false,\"packMutation\":false,\"negativeKnowledgeMutation\":false,\"correctionMutation\":false,\"commandsExecuted\":false,\"verifiersExecuted\":false}");
    try w.writeAll(",\"authority\":{\"nonAuthorizing\":true,\"treatedAsProof\":false,\"globalPromotion\":false,\"usedAsEvidence\":false,\"supportGranted\":false,\"proofDischarged\":false,\"allLearningNonAuthorizing\":true}}}");

    var gip_state = schema.draftResultState();
    gip_state.permission = .none;
    gip_state.verification_state = .unverified;
    gip_state.support_minimum_met = false;
    gip_state.non_authorization_notice = "learning.status is a read-only reviewed learning-loop scoreboard; counts are diagnostics only and not proof, evidence, support, mutation, or global promotion";

    return .{
        .status = .ok,
        .result_state = gip_state,
        .result_json = try out.toOwnedSlice(),
        .allocated_result = true,
    };
}

pub fn dispatchLearningLoopPlan(allocator: std.mem.Allocator, workspace_root: ?[]const u8, request_body: ?[]const u8) !DispatchResult {
    const root = workspace_root orelse return .{
        .status = .rejected,
        .err = .{ .code = .missing_required_field, .message = "workspace root is required for learning.loop.plan" },
    };

    var max_entries: usize = project_autopsy.DEFAULT_MAX_ENTRIES;
    var max_depth: usize = project_autopsy.DEFAULT_MAX_DEPTH;
    var plan_id: ?[]u8 = null;
    defer if (plan_id) |owned| allocator.free(owned);

    if (request_body) |body| {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
            return .{ .status = .rejected, .err = .{ .code = .json_contract_error, .message = "invalid JSON in request body" } };
        };
        defer parsed.deinit();
        if (parsed.value != .object) {
            return .{ .status = .rejected, .err = .{ .code = .invalid_request, .message = "learning.loop.plan request must be a JSON object" } };
        }
        const obj = parsed.value.object;
        if (getInt(obj, "max_entries", "maxEntries")) |v| {
            if (v > 0) max_entries = @min(@as(usize, @intCast(v)), project_autopsy.DEFAULT_MAX_ENTRIES);
        }
        if (getInt(obj, "max_depth", "maxDepth")) |v| {
            if (v > 0) max_depth = @min(@as(usize, @intCast(v)), project_autopsy.DEFAULT_MAX_DEPTH);
        }
        if (getStr(obj, "plan_id", "planId")) |value| {
            plan_id = try allocator.dupe(u8, value);
        }
    }

    var analysis_arena = std.heap.ArenaAllocator.init(allocator);
    defer analysis_arena.deinit();
    const analysis_alloc = analysis_arena.allocator();

    const autopsy_result = project_autopsy.analyze(analysis_alloc, root, .{
        .max_entries = max_entries,
        .max_depth = max_depth,
    }) catch |err| {
        if (err == error.FileNotFound) {
            return .{
                .status = .rejected,
                .err = .{ .code = .path_not_found, .message = "workspace root does not exist" },
            };
        }
        return .{
            .status = .failed,
            .err = .{
                .code = .internal_error,
                .message = "learning loop project autopsy analysis failed",
                .details = @errorName(err),
            },
        };
    };

    const plan = try learning_loop.planFromAutopsy(analysis_alloc, autopsy_result, .{ .plan_id = plan_id });

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    try w.writeAll("{\"learningLoopPlan\":");
    try plan.writeJson(w);
    try w.writeAll(",\"readOnly\":true,\"candidateOnly\":true,\"commandsExecuted\":false,\"verifiersExecuted\":false,\"patchesApplied\":false,\"packsMutated\":false,\"correctionsApplied\":false,\"negativeKnowledgePromoted\":false,\"mutatesState\":false,\"authorityEffect\":\"candidate\",\"non_authorizing\":true}");

    var gip_state = schema.draftResultState();
    gip_state.stop_reason = .none;
    gip_state.unresolved_reason = null;
    gip_state.non_authorization_notice = "learning.loop.plan is read-only and candidate-only; it does not execute commands, run verifiers, apply patches, mutate packs, apply corrections, promote negative knowledge, or grant support";

    return .{
        .status = .ok,
        .result_state = gip_state,
        .result_json = try out.toOwnedSlice(),
        .allocated_result = true,
    };
}
