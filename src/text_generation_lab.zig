const std = @import("std");

// Experimental Ghost text-generation lab.
//
// This module is deliberately separate from GIP, support routing, verifier
// execution, packs, corpus mutation, corrections, negative knowledge, trust,
// snapshots, and project state. It turns inspected signals into operator-facing
// drafts only. A draft produced here is never proof and never support.

pub const TextSignal = struct {
    source_path: []const u8,
    text: []const u8,
    kind: []const u8,
};

pub const CandidateInconsistencySignal = struct {
    id: []const u8,
    description: []const u8,
    source_paths: []const []const u8 = &.{},
};

pub const TextGenerationInput = struct {
    source_artifact_ids: []const []const u8 = &.{},
    source_paths: []const []const u8 = &.{},
    detected_claims: []const TextSignal = &.{},
    detected_obligations: []const TextSignal = &.{},
    candidate_inconsistencies: []const CandidateInconsistencySignal = &.{},
    unknowns: []const []const u8 = &.{},
};

pub const TextGenerationDraft = struct {
    draft_text: []const u8,
    source_artifact_ids: []const []const u8 = &.{},
    source_paths: []const []const u8 = &.{},
    candidate_only: bool = true,
    non_authorizing: bool = true,
    support_granted: bool = false,
    proof_granted: bool = false,
    mutates_state: bool = false,
    training_applied: bool = false,
    product_ready: bool = false,
    commands_executed: bool = false,
    verifiers_executed: bool = false,
    limitations: []const []const u8 = defaultLimitations(),
    unknowns: []const []const u8 = &.{},

    pub fn deinit(self: TextGenerationDraft, allocator: std.mem.Allocator) void {
        allocator.free(self.draft_text);
    }
};

pub const TrainingExample = struct {
    source_id: []const u8,
    input_text: []const u8,
    desired_draft: []const u8,
};

pub const TokenCount = struct {
    token: []const u8,
    count: usize,
};

pub const TrainingLabResult = struct {
    examples_seen: usize,
    token_count: usize,
    frequency_table: []const TokenCount,
    candidate_only: bool = true,
    non_authorizing: bool = true,
    support_granted: bool = false,
    proof_granted: bool = false,
    mutates_state: bool = false,
    training_applied: bool = false,
    product_ready: bool = false,
    commands_executed: bool = false,
    verifiers_executed: bool = false,
    limitations: []const []const u8 = defaultLimitations(),
    unknowns: []const []const u8 = &.{},

    pub fn deinit(self: TrainingLabResult, allocator: std.mem.Allocator) void {
        allocator.free(self.frequency_table);
    }
};

pub fn defaultLimitations() []const []const u8 {
    return &.{
        "experimental lab surface only",
        "template/rule-based draft generation only",
        "no model training is applied",
        "no generated text grants proof or support",
        "no trusted state is mutated",
        "unknowns remain unknown rather than negative evidence",
        "not product-ready",
    };
}

pub fn generateOperatorSummaryDraft(
    allocator: std.mem.Allocator,
    input: TextGenerationInput,
) !TextGenerationDraft {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const writer = out.writer();

    try writer.writeAll("TEXT GENERATION LAB DRAFT / CANDIDATE ONLY / NON-AUTHORIZING\n");
    try writer.writeAll("Authority: proof_granted=false, support_granted=false, mutates_state=false, training_applied=false, product_ready=false.\n\n");

    if (hasNoSignals(input)) {
        try writer.writeAll("Summary: insufficient inspected signal to draft a substantive operator summary without guessing.\n");
        try writer.writeAll("Unknowns:\n");
        try writer.writeAll("- no claims, obligations, inconsistencies, or explicit unknowns were supplied\n");
        try writer.writeAll("Boundary: no evidence is not negative evidence, and unknown is not false.\n");
    } else {
        try writer.writeAll("Summary: inspected artifact/corpus-like signals produced a draft for operator review.\n");
        try writeSourceSection(writer, input);
        try writeTextSignals(writer, "Detected claims", input.detected_claims);
        try writeTextSignals(writer, "Detected obligations", input.detected_obligations);
        try writeInconsistencies(writer, input.candidate_inconsistencies);
        try writeUnknowns(writer, input.unknowns);
        try writer.writeAll("Boundary: this draft may guide review, but it is not evidence, proof, support, or verifier output.\n");
    }

    return .{
        .draft_text = try out.toOwnedSlice(),
        .source_artifact_ids = input.source_artifact_ids,
        .source_paths = input.source_paths,
        .unknowns = input.unknowns,
    };
}

pub fn summarizeTrainingExamples(
    allocator: std.mem.Allocator,
    examples: []const TrainingExample,
) !TrainingLabResult {
    var counts = std.ArrayList(TokenCount).init(allocator);
    errdefer counts.deinit();
    var token_total: usize = 0;

    for (examples) |example| {
        token_total += try addTokens(&counts, example.input_text);
        token_total += try addTokens(&counts, example.desired_draft);
    }

    return .{
        .examples_seen = examples.len,
        .token_count = token_total,
        .frequency_table = try counts.toOwnedSlice(),
    };
}

fn hasNoSignals(input: TextGenerationInput) bool {
    return input.detected_claims.len == 0 and
        input.detected_obligations.len == 0 and
        input.candidate_inconsistencies.len == 0 and
        input.unknowns.len == 0;
}

fn writeSourceSection(writer: anytype, input: TextGenerationInput) !void {
    if (input.source_artifact_ids.len > 0) {
        try writer.writeAll("\nSource artifact ids:\n");
        for (input.source_artifact_ids) |id| {
            try writer.print("- {s}\n", .{id});
        }
    }
    if (input.source_paths.len > 0) {
        try writer.writeAll("\nSource paths:\n");
        for (input.source_paths) |path| {
            try writer.print("- {s}\n", .{path});
        }
    }
}

fn writeTextSignals(writer: anytype, title: []const u8, signals: []const TextSignal) !void {
    if (signals.len == 0) return;
    try writer.print("\n{s}:\n", .{title});
    for (signals) |signal| {
        try writer.print("- [{s}] {s}: {s}\n", .{ signal.kind, signal.source_path, signal.text });
    }
}

fn writeInconsistencies(writer: anytype, inconsistencies: []const CandidateInconsistencySignal) !void {
    if (inconsistencies.len == 0) return;
    try writer.writeAll("\nCandidate inconsistencies:\n");
    for (inconsistencies) |inconsistency| {
        try writer.print("- {s}: {s}\n", .{ inconsistency.id, inconsistency.description });
        if (inconsistency.source_paths.len > 0) {
            try writer.writeAll("  paths:");
            for (inconsistency.source_paths) |path| {
                try writer.print(" {s}", .{path});
            }
            try writer.writeByte('\n');
        }
    }
}

fn writeUnknowns(writer: anytype, unknowns: []const []const u8) !void {
    if (unknowns.len == 0) return;
    try writer.writeAll("\nUnknowns:\n");
    for (unknowns) |unknown| {
        try writer.print("- unknown: {s}\n", .{unknown});
    }
    try writer.writeAll("Unknown handling: unknown is not false; missing evidence is not negative evidence.\n");
}

fn addTokens(counts: *std.ArrayList(TokenCount), text: []const u8) !usize {
    var seen: usize = 0;
    var tokens = std.mem.tokenizeAny(u8, text, " \t\r\n.,;:!?()[]{}<>\"'");
    while (tokens.next()) |token| {
        if (token.len == 0) continue;
        seen += 1;
        if (findToken(counts.items, token)) |index| {
            counts.items[index].count += 1;
        } else {
            try counts.append(.{ .token = token, .count = 1 });
        }
    }
    return seen;
}

fn findToken(counts: []const TokenCount, token: []const u8) ?usize {
    for (counts, 0..) |entry, index| {
        if (std.ascii.eqlIgnoreCase(entry.token, token)) return index;
    }
    return null;
}

test "generated draft is candidate-only and non-authorizing" {
    const allocator = std.testing.allocator;
    const input = TextGenerationInput{
        .source_artifact_ids = &.{"artifact.autopsy.fixture.documentation"},
        .source_paths = &.{ "README.md", "Makefile" },
        .detected_claims = &.{
            .{ .source_path = "README.md", .kind = "build_instruction", .text = "README says to run make build" },
        },
    };

    const draft = try generateOperatorSummaryDraft(allocator, input);
    defer draft.deinit(allocator);

    try std.testing.expect(draft.candidate_only);
    try std.testing.expect(draft.non_authorizing);
    try std.testing.expect(!draft.product_ready);
    try std.testing.expect(std.mem.indexOf(u8, draft.draft_text, "CANDIDATE ONLY") != null);
    try std.testing.expect(std.mem.indexOf(u8, draft.draft_text, "NON-AUTHORIZING") != null);
}

test "generated draft does not grant proof support or mutation" {
    const allocator = std.testing.allocator;
    const input = TextGenerationInput{
        .detected_obligations = &.{
            .{ .source_path = "docs/runbook.md", .kind = "operator_step", .text = "operator should inspect retry budget" },
        },
    };

    const draft = try generateOperatorSummaryDraft(allocator, input);
    defer draft.deinit(allocator);

    try std.testing.expect(!draft.proof_granted);
    try std.testing.expect(!draft.support_granted);
    try std.testing.expect(!draft.mutates_state);
    try std.testing.expect(!draft.training_applied);
    try std.testing.expect(!draft.commands_executed);
    try std.testing.expect(!draft.verifiers_executed);
}

test "unknowns are rendered as unknowns not false claims" {
    const allocator = std.testing.allocator;
    const input = TextGenerationInput{
        .unknowns = &.{
            "whether the Makefile target succeeds on this host",
            "whether omitted evidence exists in another shard",
        },
    };

    const draft = try generateOperatorSummaryDraft(allocator, input);
    defer draft.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(u8, draft.draft_text, "unknown: whether the Makefile target succeeds on this host") != null);
    try std.testing.expect(std.mem.indexOf(u8, draft.draft_text, "unknown is not false") != null);
    try std.testing.expect(std.mem.indexOf(u8, draft.draft_text, "negative evidence") != null);
}

test "training examples are counted without mutating trusted state" {
    const allocator = std.testing.allocator;
    const result = try summarizeTrainingExamples(allocator, &.{
        .{
            .source_id = "example.one",
            .input_text = "claim unknown claim",
            .desired_draft = "unknown remains unknown",
        },
        .{
            .source_id = "example.two",
            .input_text = "draft only",
            .desired_draft = "candidate draft only",
        },
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), result.examples_seen);
    try std.testing.expectEqual(@as(usize, 11), result.token_count);
    try std.testing.expect(!result.training_applied);
    try std.testing.expect(!result.mutates_state);
    try std.testing.expect(!result.proof_granted);
    try std.testing.expect(!result.support_granted);
    try std.testing.expect(!result.commands_executed);
    try std.testing.expect(!result.verifiers_executed);
    try std.testing.expect(findToken(result.frequency_table, "unknown") != null);
}

test "empty input produces insufficient signal draft without certainty" {
    const allocator = std.testing.allocator;
    const draft = try generateOperatorSummaryDraft(allocator, .{});
    defer draft.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(u8, draft.draft_text, "insufficient inspected signal") != null);
    try std.testing.expect(std.mem.indexOf(u8, draft.draft_text, "without guessing") != null);
    try std.testing.expect(std.mem.indexOf(u8, draft.draft_text, "no evidence is not negative evidence") != null);
    try std.testing.expect(!draft.proof_granted);
    try std.testing.expect(!draft.support_granted);
}

test "text lab is not product ready" {
    const allocator = std.testing.allocator;
    const draft = try generateOperatorSummaryDraft(allocator, .{});
    defer draft.deinit(allocator);
    const training = try summarizeTrainingExamples(allocator, &.{});
    defer training.deinit(allocator);

    try std.testing.expect(!draft.product_ready);
    try std.testing.expect(!training.product_ready);
}

test "lab surface has no command or verifier execution path" {
    const allocator = std.testing.allocator;
    const draft = try generateOperatorSummaryDraft(allocator, .{
        .candidate_inconsistencies = &.{
            .{
                .id = "candidate.mismatch",
                .description = "README and recipe disagree about a setup step",
                .source_paths = &.{ "README.md", "recipe.md" },
            },
        },
    });
    defer draft.deinit(allocator);
    const training = try summarizeTrainingExamples(allocator, &.{
        .{ .source_id = "example", .input_text = "no command execution", .desired_draft = "candidate wording" },
    });
    defer training.deinit(allocator);

    try std.testing.expect(!draft.commands_executed);
    try std.testing.expect(!draft.verifiers_executed);
    try std.testing.expect(!training.commands_executed);
    try std.testing.expect(!training.verifiers_executed);
}
