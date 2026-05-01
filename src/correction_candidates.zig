const std = @import("std");

pub const DisputedOutputKind = enum {
    answerDraft,
    evidenceUsed,
    unknown,
    rule_candidate,
    similarity_hint,
    capacity_warning,

    pub fn parse(text: []const u8) ?DisputedOutputKind {
        inline for (std.meta.fields(DisputedOutputKind)) |field| {
            if (std.mem.eql(u8, text, field.name)) return @enumFromInt(field.value);
        }
        return null;
    }
};

pub const CorrectionType = enum {
    wrong_answer,
    missing_evidence,
    bad_evidence,
    outdated_corpus,
    misleading_rule,
    repeated_failed_pattern,
    unsafe_candidate,

    pub fn parse(text: []const u8) ?CorrectionType {
        inline for (std.meta.fields(CorrectionType)) |field| {
            if (std.mem.eql(u8, text, field.name)) return @enumFromInt(field.value);
        }
        return null;
    }
};

pub const CandidateState = enum {
    proposed,
    reviewed,
    accepted,
    rejected,
};

pub const LearningOutputKind = enum {
    negative_knowledge_candidate,
    corpus_update_candidate,
    pack_guidance_candidate,
    verifier_check_candidate,
    follow_up_evidence_request,
};

pub const Request = struct {
    operation_kind: ?[]const u8 = null,
    original_request_id: ?[]const u8 = null,
    original_request_summary: ?[]const u8 = null,
    disputed_output_kind: ?DisputedOutputKind = null,
    disputed_output_ref: ?[]const u8 = null,
    disputed_output_summary: ?[]const u8 = null,
    user_correction: ?[]const u8 = null,
    correction_type: ?CorrectionType = null,
    evidence_refs: []const []const u8 = &.{},
    project_shard: ?[]const u8 = null,
};

pub const MutationFlags = struct {
    corpus_mutation: bool = false,
    pack_mutation: bool = false,
    negative_knowledge_mutation: bool = false,
    commands_executed: bool = false,
    verifiers_executed: bool = false,
};

pub const LearningOutput = struct {
    kind: LearningOutputKind,
    status: []const u8 = "proposed",
    candidate_only: bool = true,
    non_authorizing: bool = true,
    treated_as_proof: bool = false,
    persisted: bool = false,
    reason: []const u8,
};

pub const Proposal = struct {
    request: Request,
    status: []const u8,
    candidate_id_hash: ?u64,
    unknown_reason: ?[]const u8 = null,
    learning_outputs: []const LearningOutput,
    required_review: bool = true,
    state: CandidateState = .proposed,
    non_authorizing: bool = true,
    treated_as_proof: bool = false,
    mutation_flags: MutationFlags = .{},
};

pub fn propose(request: Request, body_hash: u64) Proposal {
    if (isBlank(request.operation_kind) or request.disputed_output_kind == null or
        isBlank(request.user_correction) or request.correction_type == null)
    {
        return .{
            .request = request,
            .status = "request_more_detail",
            .candidate_id_hash = null,
            .unknown_reason = "operationKind, disputedOutput.kind, userCorrection, and correctionType are required to propose a correction candidate",
            .learning_outputs = &.{.{
                .kind = .follow_up_evidence_request,
                .reason = "correction request is underspecified; ask for the missing disputed output and correction details",
            }},
        };
    }

    return .{
        .request = request,
        .status = "proposed",
        .candidate_id_hash = body_hash,
        .learning_outputs = learningOutputsFor(request.correction_type.?, request.disputed_output_kind.?),
    };
}

fn isBlank(value: ?[]const u8) bool {
    const text = value orelse return true;
    return std.mem.trim(u8, text, " \r\n\t").len == 0;
}

fn learningOutputsFor(correction_type: CorrectionType, disputed_kind: DisputedOutputKind) []const LearningOutput {
    _ = disputed_kind;
    return switch (correction_type) {
        .wrong_answer => &.{
            .{ .kind = .negative_knowledge_candidate, .reason = "wrong answer may identify a repeated failure pattern after review" },
            .{ .kind = .corpus_update_candidate, .reason = "answer correction may require reviewed corpus evidence or replacement evidence" },
            .{ .kind = .verifier_check_candidate, .reason = "corrected claim needs an explicit check before support can change" },
        },
        .missing_evidence => &.{
            .{ .kind = .follow_up_evidence_request, .reason = "missing evidence should be collected or cited before any support changes" },
        },
        .bad_evidence => &.{
            .{ .kind = .corpus_update_candidate, .reason = "disputed evidence may need removal, replacement, or provenance review through an explicit lifecycle" },
            .{ .kind = .verifier_check_candidate, .reason = "bad evidence requires an explicit check before future behavior changes" },
        },
        .outdated_corpus => &.{
            .{ .kind = .corpus_update_candidate, .reason = "outdated corpus claims require reviewed replacement evidence" },
            .{ .kind = .follow_up_evidence_request, .reason = "request current evidence before accepting the correction" },
        },
        .misleading_rule => &.{
            .{ .kind = .pack_guidance_candidate, .reason = "misleading rule output may require reviewed pack guidance adjustment" },
            .{ .kind = .verifier_check_candidate, .reason = "rule behavior should be checked before changing future guidance" },
        },
        .repeated_failed_pattern => &.{
            .{ .kind = .negative_knowledge_candidate, .reason = "repeated failure pattern can become negative knowledge only after explicit review" },
        },
        .unsafe_candidate => &.{
            .{ .kind = .negative_knowledge_candidate, .reason = "unsafe candidate can propose scoped negative knowledge after review" },
            .{ .kind = .verifier_check_candidate, .reason = "unsafe candidate needs explicit checking before any future influence" },
        },
    };
}

pub fn renderJson(writer: anytype, proposal: Proposal) !void {
    try writer.writeAll("{\"correctionProposal\":{");
    try writeField(writer, "status", proposal.status, true);
    try writer.writeAll(",\"requiredReview\":true");
    try writer.writeAll(",\"correctionCandidate\":");
    if (proposal.candidate_id_hash) |id_hash| {
        try writer.writeAll("{");
        try writer.print("\"id\":\"correction:candidate:{x:0>16}\"", .{id_hash});
        try writeField(writer, "originalOperationKind", proposal.request.operation_kind.?, false);
        if (proposal.request.original_request_id) |value| try writeField(writer, "originalRequestId", value, false);
        if (proposal.request.original_request_summary) |value| try writeField(writer, "originalRequestSummary", value, false);
        try writer.writeAll(",\"disputedOutput\":{");
        try writeField(writer, "kind", @tagName(proposal.request.disputed_output_kind.?), true);
        if (proposal.request.disputed_output_ref) |value| try writeField(writer, "ref", value, false);
        if (proposal.request.disputed_output_summary) |value| try writeField(writer, "summary", value, false);
        try writer.writeAll("}");
        try writeField(writer, "userCorrection", proposal.request.user_correction.?, false);
        try writeField(writer, "correctionType", @tagName(proposal.request.correction_type.?), false);
        try writer.writeAll(",\"evidenceRefs\":");
        try writeStringArray(writer, proposal.request.evidence_refs);
        if (proposal.request.project_shard) |value| try writeField(writer, "projectShard", value, false);
        try writer.writeAll(",\"proposedLearningOutputs\":");
        try writeLearningOutputs(writer, proposal.learning_outputs);
        try writer.writeAll(",\"state\":\"proposed\",\"nonAuthorizing\":true,\"treatedAsProof\":false");
        try writer.writeAll("}");
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"learningCandidates\":");
    try writeLearningOutputs(writer, proposal.learning_outputs);
    if (proposal.unknown_reason) |reason| {
        try writer.writeAll(",\"unknowns\":[{");
        try writeField(writer, "kind", "request_more_detail", true);
        try writeField(writer, "reason", reason, false);
        try writer.writeAll("}]");
    } else {
        try writer.writeAll(",\"unknowns\":[]");
    }
    try writer.writeAll(",\"mutationFlags\":{");
    try writer.writeAll("\"corpusMutation\":false,\"packMutation\":false,\"negativeKnowledgeMutation\":false,\"commandsExecuted\":false,\"verifiersExecuted\":false");
    try writer.writeAll("},\"authority\":{\"nonAuthorizing\":true,\"treatedAsProof\":false,\"requiredReview\":true,\"autoAccepted\":false,\"persisted\":false}");
    try writer.writeAll("}}");
}

fn writeLearningOutputs(writer: anytype, outputs: []const LearningOutput) !void {
    try writer.writeByte('[');
    for (outputs, 0..) |output, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writer.writeAll("{");
        try writeField(writer, "kind", @tagName(output.kind), true);
        try writeField(writer, "status", output.status, false);
        try writeField(writer, "reason", output.reason, false);
        try writer.writeAll(",\"candidateOnly\":true,\"nonAuthorizing\":true,\"treatedAsProof\":false,\"persisted\":false");
        try writer.writeAll("}");
    }
    try writer.writeByte(']');
}

fn writeField(writer: anytype, name: []const u8, value: []const u8, first: bool) !void {
    if (!first) try writer.writeByte(',');
    try writer.writeByte('"');
    try writer.writeAll(name);
    try writer.writeAll("\":\"");
    try writeEscaped(writer, value);
    try writer.writeByte('"');
}

fn writeStringArray(writer: anytype, items: []const []const u8) !void {
    try writer.writeByte('[');
    for (items, 0..) |item, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writer.writeByte('"');
        try writeEscaped(writer, item);
        try writer.writeByte('"');
    }
    try writer.writeByte(']');
}

fn writeEscaped(writer: anytype, text: []const u8) !void {
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
}

test "wrong answer correction proposes candidate-only learning outputs" {
    const proposal = propose(.{
        .operation_kind = "corpus.ask",
        .disputed_output_kind = .answerDraft,
        .user_correction = "the draft answer is wrong",
        .correction_type = .wrong_answer,
    }, 1);
    try std.testing.expectEqualStrings("proposed", proposal.status);
    try std.testing.expect(proposal.non_authorizing);
    try std.testing.expect(!proposal.treated_as_proof);
    try std.testing.expectEqual(@as(usize, 3), proposal.learning_outputs.len);
}

test "underspecified correction requests more detail" {
    const proposal = propose(.{
        .operation_kind = "corpus.ask",
        .correction_type = .missing_evidence,
    }, 1);
    try std.testing.expectEqualStrings("request_more_detail", proposal.status);
    try std.testing.expect(proposal.candidate_id_hash == null);
    try std.testing.expectEqual(LearningOutputKind.follow_up_evidence_request, proposal.learning_outputs[0].kind);
}
