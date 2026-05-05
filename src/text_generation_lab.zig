const std = @import("std");
const builtin = @import("builtin");

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

pub const CorpusIngestLimits = struct {
    max_file_count: usize = 8,
    max_bytes_per_file: usize = 16 * 1024,
    max_total_bytes: usize = 32 * 1024,
};

pub const CorpusIngestInput = struct {
    workspace_root: []const u8,
    corpus_paths: []const []const u8,
    limits: CorpusIngestLimits = .{},
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

pub const CorpusIngestSummary = struct {
    files_seen: usize,
    bytes_seen: usize,
    claim_count: usize,
    obligation_count: usize,
    unknown_count: usize,
    duplicate_line_count: usize,
};

pub const CorpusIngestDraftResult = struct {
    draft: TextGenerationDraft,
    training_summary: TrainingLabResult,
    ingest_summary: CorpusIngestSummary,
    extraction: CorpusSignalExtraction,

    pub fn deinit(self: CorpusIngestDraftResult, allocator: std.mem.Allocator) void {
        self.draft.deinit(allocator);
        self.training_summary.deinit(allocator);
        self.extraction.deinit(allocator);
    }
};

pub const TrainingExample = struct {
    source_id: []const u8,
    input_text: []const u8,
    desired_draft: []const u8,
};

const CorpusSignalExtraction = struct {
    input: TextGenerationInput,
    summary: CorpusIngestSummary,

    pub fn deinit(self: CorpusSignalExtraction, allocator: std.mem.Allocator) void {
        for (self.input.detected_claims) |signal| allocator.free(signal.text);
        allocator.free(self.input.detected_claims);

        for (self.input.detected_obligations) |signal| allocator.free(signal.text);
        allocator.free(self.input.detected_obligations);

        for (self.input.unknowns) |unknown| allocator.free(unknown);
        allocator.free(self.input.unknowns);

        for (self.input.source_paths) |path| allocator.free(path);
        allocator.free(self.input.source_paths);
    }
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

pub fn ingestCorpusAndGenerateDraft(
    allocator: std.mem.Allocator,
    input: CorpusIngestInput,
) !CorpusIngestDraftResult {
    if (input.workspace_root.len == 0) return error.EmptyWorkspaceRoot;
    var root_dir = try std.fs.cwd().openDir(input.workspace_root, .{});
    defer root_dir.close();
    return ingestCorpusAndGenerateDraftFromDir(allocator, root_dir, input.corpus_paths, input.limits);
}

fn ingestCorpusAndGenerateDraftFromDir(
    allocator: std.mem.Allocator,
    root_dir: std.fs.Dir,
    corpus_paths: []const []const u8,
    limits: CorpusIngestLimits,
) !CorpusIngestDraftResult {
    var extraction = try readCorpusSignalsFromDir(allocator, root_dir, corpus_paths, limits);
    errdefer extraction.deinit(allocator);

    const draft = try generateOperatorSummaryDraft(allocator, extraction.input);
    errdefer draft.deinit(allocator);

    const training_examples = [_]TrainingExample{
        .{
            .source_id = "lab-local-corpus-ingest",
            .input_text = "bounded file-backed corpus signals",
            .desired_draft = "candidate-only non-authorizing operator draft",
        },
    };
    const training_summary = try summarizeTrainingExamples(allocator, if (extraction.summary.claim_count +
        extraction.summary.obligation_count +
        extraction.summary.unknown_count == 0) &.{} else &training_examples);
    errdefer training_summary.deinit(allocator);

    return .{
        .draft = draft,
        .training_summary = training_summary,
        .ingest_summary = extraction.summary,
        .extraction = extraction,
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

fn readCorpusSignalsFromDir(
    allocator: std.mem.Allocator,
    root_dir: std.fs.Dir,
    corpus_paths: []const []const u8,
    limits: CorpusIngestLimits,
) !CorpusSignalExtraction {
    if (corpus_paths.len > limits.max_file_count) return error.TooManyCorpusFiles;

    var source_paths = std.ArrayList([]const u8).init(allocator);
    errdefer source_paths.deinit();
    errdefer freeStringList(allocator, source_paths.items);

    var claims = std.ArrayList(TextSignal).init(allocator);
    errdefer claims.deinit();
    errdefer freeSignals(allocator, claims.items);

    var obligations = std.ArrayList(TextSignal).init(allocator);
    errdefer obligations.deinit();
    errdefer freeSignals(allocator, obligations.items);

    var unknowns = std.ArrayList([]const u8).init(allocator);
    errdefer unknowns.deinit();
    errdefer freeStringList(allocator, unknowns.items);

    var unique_lines = std.ArrayList([]const u8).init(allocator);
    defer {
        freeStringList(allocator, unique_lines.items);
        unique_lines.deinit();
    }

    var summary = CorpusIngestSummary{
        .files_seen = 0,
        .bytes_seen = 0,
        .claim_count = 0,
        .obligation_count = 0,
        .unknown_count = 0,
        .duplicate_line_count = 0,
    };

    for (corpus_paths) |path| {
        try validateCorpusPath(path);
        const stat = try statNoFollow(root_dir, path);
        switch (stat.kind) {
            .file => {},
            .directory => return error.CorpusPathIsDirectory,
            .sym_link => return error.CorpusPathIsSymlink,
            else => return error.CorpusPathIsNotFile,
        }
        if (stat.size > limits.max_bytes_per_file) return error.CorpusFileTooLarge;
        if (summary.bytes_seen + stat.size > limits.max_total_bytes) return error.CorpusTotalBytesExceeded;

        var file = try root_dir.openFile(path, .{ .mode = .read_only });
        defer file.close();
        const content = try file.readToEndAlloc(allocator, limits.max_bytes_per_file);
        defer allocator.free(content);
        summary.bytes_seen += content.len;
        summary.files_seen += 1;

        const owned_path = try allocator.dupe(u8, path);
        source_paths.append(owned_path) catch |err| {
            allocator.free(owned_path);
            return err;
        };

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r\n");
            if (line.len == 0) continue;
            if (containsLine(unique_lines.items, line)) {
                summary.duplicate_line_count += 1;
                continue;
            }
            const stored_line = try allocator.dupe(u8, line);
            unique_lines.append(stored_line) catch |err| {
                allocator.free(stored_line);
                return err;
            };

            if (std.ascii.indexOfIgnoreCase(line, "claim:") != null) {
                try appendSignal(allocator, &claims, owned_path, "corpus_claim", line);
                summary.claim_count += 1;
            }
            if (std.ascii.indexOfIgnoreCase(line, "obligation:") != null or
                std.ascii.indexOfIgnoreCase(line, "must") != null)
            {
                try appendSignal(allocator, &obligations, owned_path, "corpus_obligation", line);
                summary.obligation_count += 1;
            }
            if (std.ascii.indexOfIgnoreCase(line, "unknown:") != null or
                std.ascii.indexOfIgnoreCase(line, "todo:") != null)
            {
                try appendStringCopy(allocator, &unknowns, line);
                summary.unknown_count += 1;
            }
        }
    }

    return .{
        .input = .{
            .source_paths = try source_paths.toOwnedSlice(),
            .detected_claims = try claims.toOwnedSlice(),
            .detected_obligations = try obligations.toOwnedSlice(),
            .unknowns = try unknowns.toOwnedSlice(),
        },
        .summary = summary,
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

fn validateCorpusPath(path: []const u8) !void {
    if (path.len == 0) return error.EmptyCorpusPath;
    if (std.fs.path.isAbsolute(path)) return error.AbsoluteCorpusPathRejected;
    var components = std.mem.tokenizeAny(u8, path, "/\\");
    while (components.next()) |component| {
        if (std.mem.eql(u8, component, "..")) return error.PathTraversalRejected;
    }
}

fn statNoFollow(root_dir: std.fs.Dir, path: []const u8) !std.fs.File.Stat {
    if (builtin.os.tag == .windows) {
        return root_dir.statFile(path);
    }

    const stat = try std.posix.fstatat(root_dir.fd, path, std.posix.AT.SYMLINK_NOFOLLOW);
    return std.fs.File.Stat.fromPosix(stat);
}

fn containsLine(lines: []const []const u8, line: []const u8) bool {
    for (lines) |candidate| {
        if (std.mem.eql(u8, candidate, line)) return true;
    }
    return false;
}

fn appendSignal(
    allocator: std.mem.Allocator,
    signals: *std.ArrayList(TextSignal),
    source_path: []const u8,
    kind: []const u8,
    text: []const u8,
) !void {
    const owned_text = try allocator.dupe(u8, text);
    signals.append(.{
        .source_path = source_path,
        .kind = kind,
        .text = owned_text,
    }) catch |err| {
        allocator.free(owned_text);
        return err;
    };
}

fn appendStringCopy(
    allocator: std.mem.Allocator,
    values: *std.ArrayList([]const u8),
    text: []const u8,
) !void {
    const owned_text = try allocator.dupe(u8, text);
    values.append(owned_text) catch |err| {
        allocator.free(owned_text);
        return err;
    };
}

fn freeSignals(allocator: std.mem.Allocator, signals: []const TextSignal) void {
    for (signals) |signal| allocator.free(signal.text);
}

fn freeStringList(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |value| allocator.free(value);
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

test "fixture corpus ingestion produces candidate draft from claims obligations and unknowns" {
    const allocator = std.testing.allocator;
    const result = try ingestCorpusAndGenerateDraft(allocator, .{
        .workspace_root = ".",
        .corpus_paths = &.{
            "fixtures/text_generation_lab/corpus/doc_claims.md",
            "fixtures/text_generation_lab/corpus/runbook.md",
            "fixtures/text_generation_lab/corpus/noisy_notes.md",
        },
    });
    defer result.deinit(allocator);

    try std.testing.expect(result.draft.candidate_only);
    try std.testing.expect(result.draft.non_authorizing);
    try std.testing.expect(!result.draft.proof_granted);
    try std.testing.expect(!result.draft.support_granted);
    try std.testing.expect(!result.draft.mutates_state);
    try std.testing.expect(!result.draft.training_applied);
    try std.testing.expect(!result.training_summary.training_applied);
    try std.testing.expectEqual(@as(usize, 3), result.ingest_summary.files_seen);
    try std.testing.expect(result.ingest_summary.claim_count >= 3);
    try std.testing.expect(result.ingest_summary.obligation_count >= 2);
    try std.testing.expect(result.ingest_summary.unknown_count >= 2);
    try std.testing.expect(std.mem.indexOf(u8, result.draft.draft_text, "Detected claims") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.draft.draft_text, "Detected obligations") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.draft.draft_text, "Unknowns") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.draft.draft_text, "proof_granted=false") != null);
}

test "noisy duplicate corpus lines are suppressed and do not become authority" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{
        .sub_path = "noisy.md",
        .data =
        \\claim: repeated candidate
        \\claim: repeated candidate
        \\claim: repeated candidate
        \\unmarked noise
        ,
    });

    const allocator = std.testing.allocator;
    const result = try ingestCorpusAndGenerateDraftFromDir(allocator, tmp.dir, &.{"noisy.md"}, .{});
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), result.ingest_summary.claim_count);
    try std.testing.expectEqual(@as(usize, 2), result.ingest_summary.duplicate_line_count);
    try std.testing.expect(!result.draft.proof_granted);
    try std.testing.expect(!result.draft.support_granted);
}

test "no usable corpus signals produces insufficient signal draft" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "plain.md", .data = "plain text\nmore plain text\n" });

    const allocator = std.testing.allocator;
    const result = try ingestCorpusAndGenerateDraftFromDir(allocator, tmp.dir, &.{"plain.md"}, .{});
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), result.ingest_summary.claim_count);
    try std.testing.expectEqual(@as(usize, 0), result.ingest_summary.obligation_count);
    try std.testing.expectEqual(@as(usize, 0), result.ingest_summary.unknown_count);
    try std.testing.expectEqual(@as(usize, 0), result.training_summary.examples_seen);
    try std.testing.expect(std.mem.indexOf(u8, result.draft.draft_text, "insufficient inspected signal") != null);
    try std.testing.expect(!result.draft.proof_granted);
}

test "corpus path traversal is rejected" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try std.testing.expectError(
        error.PathTraversalRejected,
        ingestCorpusAndGenerateDraftFromDir(std.testing.allocator, tmp.dir, &.{"../outside.md"}, .{}),
    );
}

test "absolute corpus path is rejected" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try std.testing.expectError(
        error.AbsoluteCorpusPathRejected,
        ingestCorpusAndGenerateDraftFromDir(std.testing.allocator, tmp.dir, &.{"/tmp/ghost-lab.md"}, .{}),
    );
}

test "directory corpus path is rejected" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("corpus_dir");

    try std.testing.expectError(
        error.CorpusPathIsDirectory,
        ingestCorpusAndGenerateDraftFromDir(std.testing.allocator, tmp.dir, &.{"corpus_dir"}, .{}),
    );
}

test "too many corpus files are rejected before reading" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try std.testing.expectError(
        error.TooManyCorpusFiles,
        ingestCorpusAndGenerateDraftFromDir(std.testing.allocator, tmp.dir, &.{ "a.md", "b.md" }, .{ .max_file_count = 1 }),
    );
}

test "too large corpus file is rejected" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile("large.md", .{});
    defer file.close();
    try file.writer().writeByteNTimes('x', 33);

    try std.testing.expectError(
        error.CorpusFileTooLarge,
        ingestCorpusAndGenerateDraftFromDir(std.testing.allocator, tmp.dir, &.{"large.md"}, .{ .max_bytes_per_file = 32 }),
    );
}

test "total corpus byte cap is rejected" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "one.md", .data = "claim: one\n" });
    try tmp.dir.writeFile(.{ .sub_path = "two.md", .data = "claim: two\n" });

    try std.testing.expectError(
        error.CorpusTotalBytesExceeded,
        ingestCorpusAndGenerateDraftFromDir(std.testing.allocator, tmp.dir, &.{ "one.md", "two.md" }, .{ .max_total_bytes = 12 }),
    );
}

test "symlink corpus path is rejected" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "target.md", .data = "claim: symlink target\n" });
    try tmp.dir.symLink("target.md", "link.md", .{});

    try std.testing.expectError(
        error.CorpusPathIsSymlink,
        ingestCorpusAndGenerateDraftFromDir(std.testing.allocator, tmp.dir, &.{"link.md"}, .{}),
    );
}

test "corpus ingestion output remains candidate-only and training is not applied" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "bounded.md", .data = "claim: bounded input\nobligation: must remain candidate-only\nunknown: missing context\n" });

    const allocator = std.testing.allocator;
    const result = try ingestCorpusAndGenerateDraftFromDir(allocator, tmp.dir, &.{"bounded.md"}, .{});
    defer result.deinit(allocator);

    try std.testing.expect(result.draft.candidate_only);
    try std.testing.expect(result.draft.non_authorizing);
    try std.testing.expect(!result.draft.proof_granted);
    try std.testing.expect(!result.draft.support_granted);
    try std.testing.expect(!result.draft.mutates_state);
    try std.testing.expect(!result.draft.product_ready);
    try std.testing.expect(!result.draft.commands_executed);
    try std.testing.expect(!result.draft.verifiers_executed);
    try std.testing.expect(!result.training_summary.training_applied);
    try std.testing.expect(!result.training_summary.mutates_state);
    try std.testing.expect(!result.training_summary.proof_granted);
    try std.testing.expect(!result.training_summary.support_granted);
}
