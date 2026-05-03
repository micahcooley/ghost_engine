const std = @import("std");
const abstractions = @import("abstractions.zig");
const corpus_ingest = @import("corpus_ingest.zig");
const corpus_sketch = @import("corpus_sketch.zig");
const correction_review = @import("correction_review.zig");
const negative_knowledge_review = @import("negative_knowledge_review.zig");
const shards = @import("shards.zig");

pub const DEFAULT_MAX_RESULTS: usize = 3;
pub const MAX_RESULTS: usize = 8;
pub const DEFAULT_MAX_SNIPPET_BYTES: usize = 320;
pub const MAX_SNIPPET_BYTES: usize = 1024;
const MAX_FILE_READ_BYTES: usize = 64 * 1024;
const MAX_QUERY_TOKENS: usize = 16;
const MIN_TOKEN_LEN: usize = 3;
const MAX_SKETCH_CANDIDATES: usize = 8;
const MAX_SIMHASH_DISTANCE: u7 = 24;

pub const AskStatus = enum {
    answered,
    unknown,
};

pub const UnknownKind = enum {
    no_corpus_available,
    insufficient_evidence,
    conflicting_evidence,
    capacity_limited,
    malformed_request,
};

pub const SafetyFlags = struct {
    corpus_mutation: bool = false,
    pack_mutation: bool = false,
    negative_knowledge_mutation: bool = false,
    commands_executed: bool = false,
    verifiers_executed: bool = false,
};

pub const CorrectionMutationFlags = struct {
    corpus_mutation: bool = false,
    pack_mutation: bool = false,
    negative_knowledge_mutation: bool = false,
    commands_executed: bool = false,
    verifiers_executed: bool = false,
};

pub const Options = struct {
    question: []const u8,
    project_shard: ?[]const u8 = null,
    max_results: usize = DEFAULT_MAX_RESULTS,
    max_snippet_bytes: usize = DEFAULT_MAX_SNIPPET_BYTES,
    require_citations: bool = true,
};

pub const EvidenceUsed = struct {
    item_id: []u8,
    path: []u8,
    source_path: []u8,
    source_label: []u8,
    class_name: []u8,
    trust_class: []u8,
    content_hash: []u8,
    byte_start: usize,
    byte_end: usize,
    line_start: usize,
    line_end: usize,
    snippet: []u8,
    snippet_truncated: bool,
    matched_terms: [][]u8,
    matched_phrase: ?[]u8 = null,
    reason: []u8,
    match_reason: []u8,
    provenance: []u8,
    score: u32,
    rank: usize,

    fn deinit(self: *EvidenceUsed, allocator: std.mem.Allocator) void {
        allocator.free(self.item_id);
        allocator.free(self.path);
        allocator.free(self.source_path);
        allocator.free(self.source_label);
        allocator.free(self.class_name);
        allocator.free(self.trust_class);
        allocator.free(self.content_hash);
        allocator.free(self.snippet);
        for (self.matched_terms) |term| allocator.free(term);
        allocator.free(self.matched_terms);
        if (self.matched_phrase) |phrase| allocator.free(phrase);
        allocator.free(self.reason);
        allocator.free(self.match_reason);
        allocator.free(self.provenance);
        self.* = undefined;
    }
};

pub const Unknown = struct {
    kind: UnknownKind,
    reason: []u8,

    fn deinit(self: *Unknown, allocator: std.mem.Allocator) void {
        allocator.free(self.reason);
        self.* = undefined;
    }
};

pub const CandidateFollowup = struct {
    kind: []u8,
    detail: []u8,

    fn deinit(self: *CandidateFollowup, allocator: std.mem.Allocator) void {
        allocator.free(self.kind);
        allocator.free(self.detail);
        self.* = undefined;
    }
};

pub const LearningCandidate = struct {
    candidate_kind: []u8,
    proposed_action: []u8,
    reason: []u8,
    candidate_only: bool = true,
    non_authorizing: bool = true,
    treated_as_proof: bool = false,
    persisted: bool = false,

    fn deinit(self: *LearningCandidate, allocator: std.mem.Allocator) void {
        allocator.free(self.candidate_kind);
        allocator.free(self.proposed_action);
        allocator.free(self.reason);
        self.* = undefined;
    }
};

pub const SimilarCandidate = struct {
    item_id: []u8,
    path: []u8,
    source_path: []u8,
    source_label: []u8,
    trust_class: []u8,
    sketch_hash: []u8,
    hamming_distance: u7,
    similarity_score: u16,
    reason: []u8,
    non_authorizing: bool = true,
    rank: usize,

    fn deinit(self: *SimilarCandidate, allocator: std.mem.Allocator) void {
        allocator.free(self.item_id);
        allocator.free(self.path);
        allocator.free(self.source_path);
        allocator.free(self.source_label);
        allocator.free(self.trust_class);
        allocator.free(self.sketch_hash);
        allocator.free(self.reason);
        self.* = undefined;
    }
};

pub const AcceptedCorrectionWarning = struct {
    line_number: usize,
    reason: []u8,

    fn deinit(self: *AcceptedCorrectionWarning, allocator: std.mem.Allocator) void {
        allocator.free(self.reason);
        self.* = undefined;
    }
};

pub const AcceptedNegativeKnowledgeWarning = struct {
    line_number: usize,
    reason: []u8,

    fn deinit(self: *AcceptedNegativeKnowledgeWarning, allocator: std.mem.Allocator) void {
        allocator.free(self.reason);
        self.* = undefined;
    }
};

pub const CorrectionInfluence = struct {
    id: []u8,
    source_reviewed_correction_id: []u8,
    influence_kind: []u8,
    reason: []u8,
    applies_to: []u8,
    matched_pattern: []u8,
    disputed_output_fingerprint: []u8,
    non_authorizing: bool = true,
    treated_as_proof: bool = false,
    global_promotion: bool = false,
    mutation_flags: CorrectionMutationFlags = .{},

    fn deinit(self: *CorrectionInfluence, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.source_reviewed_correction_id);
        allocator.free(self.influence_kind);
        allocator.free(self.reason);
        allocator.free(self.applies_to);
        allocator.free(self.matched_pattern);
        allocator.free(self.disputed_output_fingerprint);
        self.* = undefined;
    }
};

pub const FutureBehaviorCandidate = struct {
    kind: []u8,
    status: []u8,
    reason: []u8,
    source_reviewed_correction_id: ?[]u8 = null,
    source_reviewed_negative_knowledge_id: ?[]u8 = null,
    candidate_only: bool = true,
    non_authorizing: bool = true,
    treated_as_proof: bool = false,
    used_as_evidence: bool = false,
    global_promotion: bool = false,
    mutation_flags: CorrectionMutationFlags = .{},

    fn deinit(self: *FutureBehaviorCandidate, allocator: std.mem.Allocator) void {
        allocator.free(self.kind);
        allocator.free(self.status);
        allocator.free(self.reason);
        if (self.source_reviewed_correction_id) |value| allocator.free(value);
        if (self.source_reviewed_negative_knowledge_id) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub const NegativeKnowledgeInfluence = struct {
    id: []u8,
    source_reviewed_negative_knowledge_id: []u8,
    influence_kind: []u8,
    applies_to: []u8,
    matched_pattern: []u8,
    matched_output_id: ?[]u8 = null,
    matched_rule_id: ?[]u8 = null,
    reason: []u8,
    non_authorizing: bool = true,
    treated_as_proof: bool = false,
    used_as_evidence: bool = false,
    global_promotion: bool = false,
    mutation_flags: CorrectionMutationFlags = .{},

    fn deinit(self: *NegativeKnowledgeInfluence, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.source_reviewed_negative_knowledge_id);
        allocator.free(self.influence_kind);
        allocator.free(self.applies_to);
        allocator.free(self.matched_pattern);
        if (self.matched_output_id) |value| allocator.free(value);
        if (self.matched_rule_id) |value| allocator.free(value);
        allocator.free(self.reason);
        self.* = undefined;
    }
};

pub const InfluenceTelemetry = struct {
    reviewed_records_read: usize = 0,
    accepted_records_read: usize = 0,
    rejected_records_read: usize = 0,
    malformed_lines: usize = 0,
    warnings: usize = 0,
    matched_influences: usize = 0,
    answer_suppressed: bool = false,
    bounded_read_truncated: bool = false,
};

pub const NegativeKnowledgeTelemetry = struct {
    records_read: usize = 0,
    accepted_records: usize = 0,
    rejected_records: usize = 0,
    malformed_lines: usize = 0,
    warnings: usize = 0,
    influences_loaded: usize = 0,
    influences_applied: usize = 0,
    answer_suppressed: bool = false,
    truncated: bool = false,
    same_shard_only: bool = true,
    mutation_performed: bool = false,
    commands_executed: bool = false,
    verifiers_executed: bool = false,
};

pub const CapacityTelemetry = struct {
    dropped_runes: usize = 0,
    collision_stalls: usize = 0,
    saturated_slots: usize = 0,
    truncated_inputs: usize = 0,
    truncated_snippets: usize = 0,
    skipped_inputs: usize = 0,
    skipped_files: usize = 0,
    budget_hits: usize = 0,
    max_results_hit: bool = false,
    max_outputs_hit: bool = false,
    max_rules_hit: bool = false,
    exact_candidate_cap_hit: bool = false,
    sketch_candidate_cap_hit: bool = false,
    unknowns_created: usize = 0,
    expansion_recommended: bool = false,
    spillover_recommended: bool = false,

    pub fn hasPressure(self: CapacityTelemetry) bool {
        return self.dropped_runes != 0 or
            self.collision_stalls != 0 or
            self.saturated_slots != 0 or
            self.truncated_inputs != 0 or
            self.truncated_snippets != 0 or
            self.skipped_inputs != 0 or
            self.skipped_files != 0 or
            self.budget_hits != 0 or
            self.max_results_hit or
            self.max_outputs_hit or
            self.max_rules_hit or
            self.exact_candidate_cap_hit or
            self.sketch_candidate_cap_hit;
    }
};

pub const Result = struct {
    allocator: std.mem.Allocator,
    status: AskStatus,
    state: []u8,
    permission: []u8,
    question: []u8,
    shard_kind: []u8,
    shard_id: []u8,
    answer_draft: ?[]u8 = null,
    evidence_used: []EvidenceUsed = &.{},
    unknowns: []Unknown = &.{},
    candidate_followups: []CandidateFollowup = &.{},
    learning_candidates: []LearningCandidate = &.{},
    similar_candidates: []SimilarCandidate = &.{},
    accepted_correction_warnings: []AcceptedCorrectionWarning = &.{},
    correction_influences: []CorrectionInfluence = &.{},
    accepted_negative_knowledge_warnings: []AcceptedNegativeKnowledgeWarning = &.{},
    negative_knowledge_influences: []NegativeKnowledgeInfluence = &.{},
    future_behavior_candidates: []FutureBehaviorCandidate = &.{},
    safety_flags: SafetyFlags = .{},
    corpus_entries_considered: usize = 0,
    corpus_coverage_complete: bool = true,
    corpus_coverage_next_cursor: ?[]u8 = null,
    max_results: usize = DEFAULT_MAX_RESULTS,
    max_snippet_bytes: usize = DEFAULT_MAX_SNIPPET_BYTES,
    require_citations: bool = true,
    capacity_telemetry: CapacityTelemetry = .{},
    influence_telemetry: InfluenceTelemetry = .{},
    negative_knowledge_telemetry: NegativeKnowledgeTelemetry = .{},

    pub fn deinit(self: *Result) void {
        self.allocator.free(self.state);
        self.allocator.free(self.permission);
        self.allocator.free(self.question);
        self.allocator.free(self.shard_kind);
        self.allocator.free(self.shard_id);
        if (self.corpus_coverage_next_cursor) |value| self.allocator.free(value);
        if (self.answer_draft) |value| self.allocator.free(value);
        for (self.evidence_used) |*item| item.deinit(self.allocator);
        self.allocator.free(self.evidence_used);
        for (self.unknowns) |*item| item.deinit(self.allocator);
        self.allocator.free(self.unknowns);
        for (self.candidate_followups) |*item| item.deinit(self.allocator);
        self.allocator.free(self.candidate_followups);
        for (self.learning_candidates) |*item| item.deinit(self.allocator);
        self.allocator.free(self.learning_candidates);
        for (self.similar_candidates) |*item| item.deinit(self.allocator);
        self.allocator.free(self.similar_candidates);
        for (self.accepted_correction_warnings) |*item| item.deinit(self.allocator);
        self.allocator.free(self.accepted_correction_warnings);
        for (self.correction_influences) |*item| item.deinit(self.allocator);
        self.allocator.free(self.correction_influences);
        for (self.accepted_negative_knowledge_warnings) |*item| item.deinit(self.allocator);
        self.allocator.free(self.accepted_negative_knowledge_warnings);
        for (self.negative_knowledge_influences) |*item| item.deinit(self.allocator);
        self.allocator.free(self.negative_knowledge_influences);
        for (self.future_behavior_candidates) |*item| item.deinit(self.allocator);
        self.allocator.free(self.future_behavior_candidates);
        self.* = undefined;
    }
};

const QueryTokens = struct {
    tokens: [][]u8,

    fn deinit(self: *QueryTokens, allocator: std.mem.Allocator) void {
        for (self.tokens) |token| allocator.free(token);
        allocator.free(self.tokens);
        self.* = undefined;
    }
};

const Candidate = struct {
    entry_index: usize,
    score: u32,
    first_match: usize,
    byte_start: usize,
    byte_end: usize,
    line_start: usize,
    line_end: usize,
    matched_terms: [][]u8,
    matched_phrase: ?[]u8,
    content_hash: u64,
    polarity: Polarity,
    value_match: bool = false,
    text: []u8,

    fn deinit(self: *Candidate, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        for (self.matched_terms) |term| allocator.free(term);
        allocator.free(self.matched_terms);
        if (self.matched_phrase) |phrase| allocator.free(phrase);
        self.* = undefined;
    }
};

const SketchCandidate = struct {
    entry_index: usize,
    sketch_hash: u64,
    hamming_distance: u7,
    similarity_score: u16,
};

const TextToken = struct {
    lower: []u8,
    start: usize,
    end: usize,
    line_start: usize,
    line_end: usize,

    fn deinit(self: *TextToken, allocator: std.mem.Allocator) void {
        allocator.free(self.lower);
        self.* = undefined;
    }
};

const MatchSummary = struct {
    score: u32,
    first_match: usize,
    byte_start: usize,
    byte_end: usize,
    line_start: usize,
    line_end: usize,
    matched_terms: [][]u8,
    matched_phrase: ?[]u8,

    fn deinit(self: *MatchSummary, allocator: std.mem.Allocator) void {
        for (self.matched_terms) |term| allocator.free(term);
        allocator.free(self.matched_terms);
        if (self.matched_phrase) |phrase| allocator.free(phrase);
        self.* = undefined;
    }
};

const PhraseHit = struct {
    text: []u8,
    token_count: usize,
    byte_start: usize,
    byte_end: usize,
    line_start: usize,
    line_end: usize,
};

const Snippet = struct {
    text: []u8,
    truncated: bool,
};

const ReadEntryResult = struct {
    text: []u8,
    truncated: bool,
};

const Polarity = enum {
    none,
    affirmative,
    negative,
};

const QueryIntent = enum {
    general,
    date_value,
    numeric_value,
    path_value,
    config_value,
    boolean_value,
    identity_value,
};

pub fn ask(allocator: std.mem.Allocator, options: Options) !Result {
    if (std.mem.trim(u8, options.question, " \r\n\t").len == 0) {
        return malformedResult(allocator, options.question, "question must be non-empty");
    }

    const capped_results = @min(options.max_results, MAX_RESULTS);
    const max_results = if (capped_results == 0) DEFAULT_MAX_RESULTS else capped_results;
    const capped_snippet = @min(options.max_snippet_bytes, MAX_SNIPPET_BYTES);
    const max_snippet = if (capped_snippet == 0) DEFAULT_MAX_SNIPPET_BYTES else capped_snippet;

    var shard_metadata = if (options.project_shard) |project_shard|
        try shards.resolveProjectMetadata(allocator, project_shard)
    else
        try shards.resolveCoreMetadata(allocator);
    defer shard_metadata.deinit();

    var paths = try shards.resolvePaths(allocator, shard_metadata.metadata);
    defer paths.deinit();
    var reviewed = try correction_review.readAcceptedInfluences(allocator, paths.metadata.id);
    defer reviewed.deinit();
    var reviewed_nk = try negative_knowledge_review.readAcceptedInfluences(allocator, paths.metadata.id);
    defer reviewed_nk.deinit();

    const entries = try corpus_ingest.collectLiveScanEntries(allocator, &paths);
    defer corpus_ingest.deinitIndexedEntries(allocator, entries);
    var live_coverage = try corpus_ingest.liveCoverage(allocator, &paths);
    defer live_coverage.deinit(allocator);

    var tokens = try tokenizeQuery(allocator, options.question);
    defer tokens.deinit(allocator);
    const query_intent = classifyQueryIntent(options.question, tokens.tokens);

    if (entries.len == 0) {
        var result = try unknownResult(allocator, options, &paths, .no_corpus_available, "no live shard corpus is available for this ask request", entries.len, max_results, max_snippet);
        errdefer result.deinit();
        try attachLiveCoverage(allocator, &result, live_coverage);
        try applyAcceptedCorrectionInfluence(allocator, &result, &reviewed);
        try applyAcceptedNegativeKnowledgeInfluence(allocator, &result, &reviewed_nk);
        return result;
    }
    if (tokens.tokens.len == 0) {
        var result = try unknownResult(allocator, options, &paths, .insufficient_evidence, "question did not contain enough searchable terms", entries.len, max_results, max_snippet);
        errdefer result.deinit();
        try attachLiveCoverage(allocator, &result, live_coverage);
        try applyAcceptedCorrectionInfluence(allocator, &result, &reviewed);
        try applyAcceptedNegativeKnowledgeInfluence(allocator, &result, &reviewed_nk);
        return result;
    }

    var candidates = std.ArrayList(Candidate).init(allocator);
    defer {
        for (candidates.items) |*candidate| candidate.deinit(allocator);
        candidates.deinit();
    }
    var sketch_candidates = std.ArrayList(SketchCandidate).init(allocator);
    defer sketch_candidates.deinit();
    const query_sketch = try corpus_sketch.simHash64(allocator, options.question);
    var telemetry = CapacityTelemetry{};
    if (!live_coverage.complete) {
        telemetry.skipped_inputs += 1;
        telemetry.budget_hits += 1;
    }

    for (entries, 0..) |entry, idx| {
        const read_result = readEntryText(allocator, entry.abs_path) catch {
            telemetry.skipped_files += 1;
            telemetry.skipped_inputs += 1;
            telemetry.budget_hits += 1;
            continue;
        };
        const file_text = read_result.text;
        errdefer allocator.free(file_text);
        if (read_result.truncated) {
            telemetry.truncated_inputs += 1;
            telemetry.budget_hits += 1;
        }
        if (query_sketch.valid()) {
            const entry_sketch = try corpus_sketch.simHash64(allocator, file_text);
            if (entry_sketch.valid()) {
                const distance = corpus_sketch.hammingDistance(query_sketch.hash, entry_sketch.hash);
                if (distance <= MAX_SIMHASH_DISTANCE) {
                    try sketch_candidates.append(.{
                        .entry_index = idx,
                        .sketch_hash = entry_sketch.hash,
                        .hamming_distance = distance,
                        .similarity_score = corpus_sketch.similarityScore(distance),
                    });
                }
            }
        }
        const text_tokens = try tokenizeText(allocator, file_text);
        defer freeTextTokens(allocator, text_tokens);
        var scored = try scoreText(allocator, text_tokens, tokens.tokens);
        if (scored.score == 0) {
            scored.deinit(allocator);
            allocator.free(file_text);
            continue;
        }
        const value_match = evidenceMatchesIntent(file_text, query_intent);
        const value_bonus: u32 = if (query_intent != .general and value_match) 10 else 0;
        candidates.append(.{
            .entry_index = idx,
            .score = scored.score + value_bonus,
            .first_match = scored.first_match,
            .byte_start = scored.byte_start,
            .byte_end = scored.byte_end,
            .line_start = scored.line_start,
            .line_end = scored.line_end,
            .matched_terms = scored.matched_terms,
            .matched_phrase = scored.matched_phrase,
            .content_hash = std.hash.Fnv1a_64.hash(file_text),
            .polarity = detectPolarity(file_text),
            .value_match = value_match,
            .text = file_text,
        }) catch |err| {
            scored.deinit(allocator);
            return err;
        };
    }

    if (candidates.items.len == 0) {
        var result = try unknownResult(allocator, options, &paths, .insufficient_evidence, "no live corpus item matched the question terms", entries.len, max_results, max_snippet);
        errdefer result.deinit();
        result.similar_candidates = try buildSimilarCandidates(allocator, sketch_candidates.items, entries, max_results);
        telemetry.sketch_candidate_cap_hit = sketchCandidatesCapHit(sketch_candidates.items.len, max_results);
        telemetry.max_results_hit = telemetry.sketch_candidate_cap_hit;
        if (telemetry.sketch_candidate_cap_hit) telemetry.budget_hits += 1;
        telemetry.expansion_recommended = telemetry.hasPressure();
        result.capacity_telemetry = telemetry;
        try attachLiveCoverage(allocator, &result, live_coverage);
        try applyCapacityDisclosure(allocator, &result);
        try applyAcceptedCorrectionInfluence(allocator, &result, &reviewed);
        try applyAcceptedNegativeKnowledgeInfluence(allocator, &result, &reviewed_nk);
        return result;
    }

    std.mem.sort(Candidate, candidates.items, {}, candidateLessThan);
    const top_count = @min(max_results, candidates.items.len);
    telemetry.exact_candidate_cap_hit = candidates.items.len > top_count;
    telemetry.max_results_hit = telemetry.exact_candidate_cap_hit;
    if (telemetry.exact_candidate_cap_hit) telemetry.budget_hits += 1;
    const conflict = hasConflict(candidates.items[0..top_count]);
    if (conflict) {
        var result = try buildBaseResult(allocator, options, &paths, .unknown, "unresolved", "unresolved", entries.len, max_results, max_snippet);
        errdefer result.deinit();
        result.evidence_used = try buildEvidence(allocator, candidates.items[0..top_count], entries, max_snippet, "selected because it matched question terms but conflicts with another selected corpus item");
        result.similar_candidates = try buildSimilarCandidates(allocator, sketch_candidates.items, entries, max_results);
        telemetry.truncated_snippets += countTruncatedSnippets(result.evidence_used);
        if (telemetry.truncated_snippets != 0) telemetry.budget_hits += 1;
        telemetry.sketch_candidate_cap_hit = sketchCandidatesCapHit(sketch_candidates.items.len, max_results);
        if (telemetry.sketch_candidate_cap_hit) {
            telemetry.max_results_hit = true;
            telemetry.budget_hits += 1;
        }
        telemetry.expansion_recommended = telemetry.hasPressure();
        result.capacity_telemetry = telemetry;
        try attachLiveCoverage(allocator, &result, live_coverage);
        result.unknowns = try singleUnknown(allocator, .conflicting_evidence, "selected corpus evidence contains conflicting affirmative and negative signals");
        result.candidate_followups = try singleFollowup(allocator, "evidence_to_collect", "provide or ingest an authoritative corpus item that resolves the conflict");
        result.learning_candidates = try singleLearningCandidate(allocator, "correction_candidate", "review the conflicting corpus items and propose a correction or corpus update through an explicit lifecycle", "conflicting evidence cannot authorize an answer");
        try applyCapacityDisclosure(allocator, &result);
        try applyAcceptedCorrectionInfluence(allocator, &result, &reviewed);
        try applyAcceptedNegativeKnowledgeInfluence(allocator, &result, &reviewed_nk);
        return result;
    }

    const top = candidates.items[0];
    if (top.score < requiredScore(tokens.tokens.len) and top.matched_phrase == null) {
        var result = try unknownResult(allocator, options, &paths, .insufficient_evidence, "matched corpus evidence was too weak to support an answer draft", entries.len, max_results, max_snippet);
        errdefer result.deinit();
        result.similar_candidates = try buildSimilarCandidates(allocator, sketch_candidates.items, entries, max_results);
        telemetry.sketch_candidate_cap_hit = sketchCandidatesCapHit(sketch_candidates.items.len, max_results);
        if (telemetry.sketch_candidate_cap_hit) {
            telemetry.max_results_hit = true;
            telemetry.budget_hits += 1;
        }
        telemetry.expansion_recommended = telemetry.hasPressure();
        result.capacity_telemetry = telemetry;
        try attachLiveCoverage(allocator, &result, live_coverage);
        try applyCapacityDisclosure(allocator, &result);
        try applyAcceptedCorrectionInfluence(allocator, &result, &reviewed);
        try applyAcceptedNegativeKnowledgeInfluence(allocator, &result, &reviewed_nk);
        return result;
    }

    if (query_intent != .general and !top.value_match) {
        var result = try buildBaseResult(allocator, options, &paths, .unknown, "unresolved", "unresolved", entries.len, max_results, max_snippet);
        errdefer result.deinit();
        result.evidence_used = try buildEvidence(allocator, candidates.items[0..top_count], entries, max_snippet, "candidate evidence matched topic terms but did not contain the requested value shape");
        result.similar_candidates = try buildSimilarCandidates(allocator, sketch_candidates.items, entries, max_results);
        telemetry.truncated_snippets += countTruncatedSnippets(result.evidence_used);
        if (telemetry.truncated_snippets != 0) telemetry.budget_hits += 1;
        telemetry.sketch_candidate_cap_hit = sketchCandidatesCapHit(sketch_candidates.items.len, max_results);
        if (telemetry.sketch_candidate_cap_hit) {
            telemetry.max_results_hit = true;
            telemetry.budget_hits += 1;
        }
        telemetry.expansion_recommended = true;
        result.capacity_telemetry = telemetry;
        try attachLiveCoverage(allocator, &result, live_coverage);
        result.unknowns = try singleUnknown(allocator, .insufficient_evidence, "matched corpus evidence did not contain the requested exact value");
        result.candidate_followups = try singleFollowup(allocator, "evidence_to_collect", "ingest exact evidence that contains the requested value, not only related topic words");
        result.learning_candidates = try singleLearningCandidate(allocator, "corpus_update_candidate", "review whether a value-bearing corpus item should be added through an explicit lifecycle", "topic overlap without the requested value cannot authorize an answer draft");
        try applyCapacityDisclosure(allocator, &result);
        try applyAcceptedCorrectionInfluence(allocator, &result, &reviewed);
        try applyAcceptedNegativeKnowledgeInfluence(allocator, &result, &reviewed_nk);
        return result;
    }

    var result = try buildBaseResult(allocator, options, &paths, .answered, "draft", "none", entries.len, max_results, max_snippet);
    errdefer result.deinit();
    result.evidence_used = try buildEvidence(allocator, candidates.items[0..top_count], entries, max_snippet, "selected because it matched bounded question terms");
    result.similar_candidates = try buildSimilarCandidates(allocator, sketch_candidates.items, entries, max_results);
    telemetry.truncated_snippets += countTruncatedSnippets(result.evidence_used);
    if (telemetry.truncated_snippets != 0) telemetry.budget_hits += 1;
    telemetry.sketch_candidate_cap_hit = sketchCandidatesCapHit(sketch_candidates.items.len, max_results);
    if (telemetry.sketch_candidate_cap_hit) {
        telemetry.max_results_hit = true;
        telemetry.budget_hits += 1;
    }
    telemetry.expansion_recommended = telemetry.hasPressure();
    result.capacity_telemetry = telemetry;
    try attachLiveCoverage(allocator, &result, live_coverage);
    result.answer_draft = try std.fmt.allocPrint(
        allocator,
        "Draft answer from corpus evidence: {s}",
        .{result.evidence_used[0].snippet},
    );
    result.candidate_followups = try singleFollowup(allocator, "verifier_check_candidate", "review the cited corpus evidence before treating this answer as supported");
    try applyCapacityDisclosure(allocator, &result);
    try applyAcceptedCorrectionInfluence(allocator, &result, &reviewed);
    try applyAcceptedNegativeKnowledgeInfluence(allocator, &result, &reviewed_nk);
    return result;
}

fn applyAcceptedCorrectionInfluence(allocator: std.mem.Allocator, result: *Result, reviewed: *const correction_review.ReadResult) !void {
    result.influence_telemetry.reviewed_records_read = reviewed.records_read;
    result.influence_telemetry.accepted_records_read = reviewed.accepted_records;
    result.influence_telemetry.rejected_records_read = reviewed.rejected_records;
    result.influence_telemetry.malformed_lines = reviewed.malformed_lines;
    result.influence_telemetry.warnings = reviewed.warnings.len;
    result.influence_telemetry.bounded_read_truncated = reviewed.truncated;
    result.accepted_correction_warnings = try cloneWarnings(allocator, reviewed.warnings);

    for (reviewed.influences) |influence| {
        if (!std.mem.eql(u8, influence.applies_to, "corpus.ask")) continue;
        if (!influenceMatchesResult(result, influence)) continue;
        try appendCorrectionInfluence(allocator, result, influence);
        result.influence_telemetry.matched_influences += 1;
        switch (influence.influence_kind) {
            .suppress_exact_repeat => try suppressAnswerDraft(allocator, result, influence),
            .require_stronger_evidence => try appendFutureBehaviorCandidate(allocator, result, "corpus_update_candidate", "accepted bad-evidence correction requires stronger exact evidence before relying on this pattern", influence.source_reviewed_correction_id),
            .require_verifier_candidate => {
                try appendFutureBehaviorCandidate(allocator, result, "follow_up_evidence_request", "accepted missing-evidence correction asks for follow-up evidence before support changes", influence.source_reviewed_correction_id);
                try appendCandidateFollowup(allocator, result, "evidence_to_collect", "accepted reviewed correction says this pattern needs additional evidence before it can support an answer");
            },
            .propose_negative_knowledge => try appendFutureBehaviorCandidate(allocator, result, "negative_knowledge_candidate", "accepted repeated-failed-pattern correction proposes negative knowledge candidate only", influence.source_reviewed_correction_id),
            .propose_corpus_update => try appendFutureBehaviorCandidate(allocator, result, "corpus_update_candidate", "accepted reviewed correction proposes a corpus update candidate only", influence.source_reviewed_correction_id),
            .propose_pack_guidance => try appendFutureBehaviorCandidate(allocator, result, "pack_guidance_candidate", "accepted reviewed correction proposes pack guidance candidate only", influence.source_reviewed_correction_id),
            .warning, .penalty => {},
        }
    }
}

fn applyAcceptedNegativeKnowledgeInfluence(allocator: std.mem.Allocator, result: *Result, reviewed: *const negative_knowledge_review.ReadResult) !void {
    result.negative_knowledge_telemetry.records_read = reviewed.records_read;
    result.negative_knowledge_telemetry.accepted_records = reviewed.accepted_records;
    result.negative_knowledge_telemetry.rejected_records = reviewed.rejected_records;
    result.negative_knowledge_telemetry.malformed_lines = reviewed.malformed_lines;
    result.negative_knowledge_telemetry.warnings = reviewed.warnings.len;
    result.negative_knowledge_telemetry.influences_loaded = reviewed.influences.len;
    result.negative_knowledge_telemetry.truncated = reviewed.truncated;
    result.accepted_negative_knowledge_warnings = try cloneNegativeKnowledgeWarnings(allocator, reviewed.warnings);

    for (reviewed.influences) |influence| {
        if (!std.mem.eql(u8, influence.applies_to, "corpus.ask")) continue;
        if (!negativeKnowledgeMatchesResult(result, influence)) continue;
        try appendNegativeKnowledgeInfluence(allocator, result, influence);
        result.negative_knowledge_telemetry.influences_applied += 1;
        switch (influence.influence_kind) {
            .suppress_exact_repeat => try suppressAnswerDraftForNegativeKnowledge(allocator, result, influence),
            .require_stronger_evidence => {
                try appendNegativeKnowledgeFutureBehaviorCandidate(allocator, result, "corpus_update_candidate", "accepted reviewed negative knowledge requires stronger exact evidence before this corpus pattern can be relied on", influence.source_reviewed_negative_knowledge_id);
                try appendCandidateFollowup(allocator, result, "evidence_to_collect", "accepted reviewed negative knowledge says this pattern needs stronger exact evidence before support changes");
            },
            .require_verifier_candidate => {
                try appendNegativeKnowledgeFutureBehaviorCandidate(allocator, result, "verifier_check_candidate", "accepted reviewed negative knowledge requires an explicit verifier/check candidate; no verifier was executed", influence.source_reviewed_negative_knowledge_id);
                try appendCandidateFollowup(allocator, result, "verifier_check_candidate", "accepted reviewed negative knowledge requires explicit checking before this pattern can support an answer");
            },
            .propose_pack_guidance => try appendNegativeKnowledgeFutureBehaviorCandidate(allocator, result, "pack_guidance_candidate", "accepted reviewed negative knowledge proposes pack guidance candidate only", influence.source_reviewed_negative_knowledge_id),
            .propose_corpus_update => try appendNegativeKnowledgeFutureBehaviorCandidate(allocator, result, "corpus_update_candidate", "accepted reviewed negative knowledge proposes corpus update candidate only", influence.source_reviewed_negative_knowledge_id),
            .propose_rule_update => try appendNegativeKnowledgeFutureBehaviorCandidate(allocator, result, "rule_update_candidate", "accepted reviewed negative knowledge proposes rule update candidate only", influence.source_reviewed_negative_knowledge_id),
            .warning, .penalty => {},
        }
    }
}

fn influenceMatchesResult(result: *const Result, influence: correction_review.AcceptedCorrectionInfluence) bool {
    if (!std.mem.eql(u8, influence.operation_kind, "corpus.ask")) return false;
    if (containsIgnoreCase(result.question, influence.matched_pattern)) return true;
    if (result.answer_draft) |answer| {
        if (containsIgnoreCase(answer, influence.matched_pattern)) return true;
    }
    for (result.evidence_used) |evidence| {
        if (containsIgnoreCase(evidence.snippet, influence.matched_pattern)) return true;
        if (containsIgnoreCase(evidence.item_id, influence.matched_pattern)) return true;
        if (containsIgnoreCase(evidence.path, influence.matched_pattern)) return true;
    }
    return false;
}

fn negativeKnowledgeMatchesResult(result: *const Result, influence: negative_knowledge_review.AcceptedNegativeKnowledgeInfluence) bool {
    if (textMatchesNegativeKnowledge(result.question, influence)) return true;
    if (result.answer_draft) |answer| {
        if (textMatchesNegativeKnowledge(answer, influence)) return true;
    }
    for (result.evidence_used) |evidence| {
        if (textMatchesNegativeKnowledge(evidence.snippet, influence)) return true;
        if (textMatchesNegativeKnowledge(evidence.item_id, influence)) return true;
        if (textMatchesNegativeKnowledge(evidence.path, influence)) return true;
        if (textMatchesNegativeKnowledge(evidence.source_path, influence)) return true;
        if (textMatchesNegativeKnowledge(evidence.source_label, influence)) return true;
        if (textMatchesNegativeKnowledge(evidence.content_hash, influence)) return true;
    }
    return false;
}

fn textMatchesNegativeKnowledge(text: []const u8, influence: negative_knowledge_review.AcceptedNegativeKnowledgeInfluence) bool {
    if (text.len == 0 or influence.matched_pattern.len == 0) return false;
    if (std.mem.eql(u8, text, influence.matched_pattern)) return true;
    if (containsIgnoreCase(text, influence.matched_pattern)) return true;
    if (containsIgnoreCase(influence.matched_pattern, text)) return true;
    return fingerprintMatches(text, influence.pattern_fingerprint);
}

fn fingerprintMatches(text: []const u8, fingerprint: []const u8) bool {
    var buf: [32]u8 = undefined;
    const own = std.fmt.bufPrint(&buf, "fnv1a64:{x:0>16}", .{std.hash.Fnv1a_64.hash(text)}) catch return false;
    return std.mem.eql(u8, own, fingerprint);
}

fn suppressAnswerDraft(allocator: std.mem.Allocator, result: *Result, influence: correction_review.AcceptedCorrectionInfluence) !void {
    if (result.answer_draft) |answer| {
        allocator.free(answer);
        result.answer_draft = null;
    }
    result.status = .unknown;
    allocator.free(result.state);
    result.state = try allocator.dupe(u8, "unresolved");
    allocator.free(result.permission);
    result.permission = try allocator.dupe(u8, "unresolved");
    result.influence_telemetry.answer_suppressed = true;
    try appendUnknownToResult(allocator, result, .insufficient_evidence, "accepted reviewed correction suppressed an exact repeated bad answer pattern; stronger evidence or explicit verification is required");
    try appendCandidateFollowup(allocator, result, "verifier_check_candidate", "accepted reviewed correction requires an explicit check candidate before this repeated pattern can support an answer");
    try appendFutureBehaviorCandidate(allocator, result, "verifier_check_candidate", "suppressed exact repeated bad answer pattern requires explicit verifier/check candidate", influence.source_reviewed_correction_id);
}

fn suppressAnswerDraftForNegativeKnowledge(allocator: std.mem.Allocator, result: *Result, influence: negative_knowledge_review.AcceptedNegativeKnowledgeInfluence) !void {
    if (result.answer_draft) |answer| {
        allocator.free(answer);
        result.answer_draft = null;
    }
    result.status = .unknown;
    allocator.free(result.state);
    result.state = try allocator.dupe(u8, "unresolved");
    allocator.free(result.permission);
    result.permission = try allocator.dupe(u8, "unresolved");
    result.negative_knowledge_telemetry.answer_suppressed = true;
    try appendUnknownToResult(allocator, result, .insufficient_evidence, "accepted reviewed negative knowledge suppressed an exact repeated known-bad answer pattern; stronger evidence or explicit verification is required");
    try appendCandidateFollowup(allocator, result, "verifier_check_candidate", "accepted reviewed negative knowledge requires an explicit check candidate before this repeated pattern can support an answer");
    try appendNegativeKnowledgeFutureBehaviorCandidate(allocator, result, "verifier_check_candidate", "suppressed exact repeated known-bad answer pattern requires explicit verifier/check candidate", influence.source_reviewed_negative_knowledge_id);
}

fn cloneWarnings(allocator: std.mem.Allocator, warnings: []const correction_review.ReadWarning) ![]AcceptedCorrectionWarning {
    var out = try allocator.alloc(AcceptedCorrectionWarning, warnings.len);
    var built: usize = 0;
    errdefer {
        for (out[0..built]) |*item| item.deinit(allocator);
        allocator.free(out);
    }
    for (warnings, 0..) |warning, idx| {
        out[idx] = .{
            .line_number = warning.line_number,
            .reason = try allocator.dupe(u8, warning.reason),
        };
        built += 1;
    }
    return out;
}

fn cloneNegativeKnowledgeWarnings(allocator: std.mem.Allocator, warnings: []const negative_knowledge_review.ReadWarning) ![]AcceptedNegativeKnowledgeWarning {
    var out = try allocator.alloc(AcceptedNegativeKnowledgeWarning, warnings.len);
    var built: usize = 0;
    errdefer {
        for (out[0..built]) |*item| item.deinit(allocator);
        allocator.free(out);
    }
    for (warnings, 0..) |warning, idx| {
        out[idx] = .{
            .line_number = warning.line_number,
            .reason = try allocator.dupe(u8, warning.reason),
        };
        built += 1;
    }
    return out;
}

fn appendCorrectionInfluence(allocator: std.mem.Allocator, result: *Result, influence: correction_review.AcceptedCorrectionInfluence) !void {
    const old = result.correction_influences;
    var out = try allocator.alloc(CorrectionInfluence, old.len + 1);
    @memcpy(out[0..old.len], old);
    out[old.len] = .{
        .id = try allocator.dupe(u8, influence.id),
        .source_reviewed_correction_id = try allocator.dupe(u8, influence.source_reviewed_correction_id),
        .influence_kind = try allocator.dupe(u8, @tagName(influence.influence_kind)),
        .reason = try allocator.dupe(u8, influence.reason),
        .applies_to = try allocator.dupe(u8, influence.applies_to),
        .matched_pattern = try allocator.dupe(u8, influence.matched_pattern),
        .disputed_output_fingerprint = try allocator.dupe(u8, influence.disputed_output_fingerprint),
    };
    allocator.free(old);
    result.correction_influences = out;
}

fn appendNegativeKnowledgeInfluence(allocator: std.mem.Allocator, result: *Result, influence: negative_knowledge_review.AcceptedNegativeKnowledgeInfluence) !void {
    const old = result.negative_knowledge_influences;
    var out = try allocator.alloc(NegativeKnowledgeInfluence, old.len + 1);
    @memcpy(out[0..old.len], old);
    out[old.len] = .{
        .id = try allocator.dupe(u8, influence.id),
        .source_reviewed_negative_knowledge_id = try allocator.dupe(u8, influence.source_reviewed_negative_knowledge_id),
        .influence_kind = try allocator.dupe(u8, @tagName(influence.influence_kind)),
        .applies_to = try allocator.dupe(u8, influence.applies_to),
        .matched_pattern = try allocator.dupe(u8, influence.matched_pattern),
        .matched_output_id = if (influence.matched_output_id) |value| try allocator.dupe(u8, value) else null,
        .matched_rule_id = if (influence.matched_rule_id) |value| try allocator.dupe(u8, value) else null,
        .reason = try allocator.dupe(u8, influence.reason),
    };
    allocator.free(old);
    result.negative_knowledge_influences = out;
}

fn appendFutureBehaviorCandidate(allocator: std.mem.Allocator, result: *Result, kind: []const u8, reason: []const u8, source_id: []const u8) !void {
    const old = result.future_behavior_candidates;
    var out = try allocator.alloc(FutureBehaviorCandidate, old.len + 1);
    @memcpy(out[0..old.len], old);
    out[old.len] = .{
        .kind = try allocator.dupe(u8, kind),
        .status = try allocator.dupe(u8, "candidate"),
        .reason = try allocator.dupe(u8, reason),
        .source_reviewed_correction_id = try allocator.dupe(u8, source_id),
    };
    allocator.free(old);
    result.future_behavior_candidates = out;
}

fn appendNegativeKnowledgeFutureBehaviorCandidate(allocator: std.mem.Allocator, result: *Result, kind: []const u8, reason: []const u8, source_id: []const u8) !void {
    const old = result.future_behavior_candidates;
    var out = try allocator.alloc(FutureBehaviorCandidate, old.len + 1);
    @memcpy(out[0..old.len], old);
    out[old.len] = .{
        .kind = try allocator.dupe(u8, kind),
        .status = try allocator.dupe(u8, "candidate"),
        .reason = try allocator.dupe(u8, reason),
        .source_reviewed_negative_knowledge_id = try allocator.dupe(u8, source_id),
    };
    allocator.free(old);
    result.future_behavior_candidates = out;
}

fn appendCandidateFollowup(allocator: std.mem.Allocator, result: *Result, kind: []const u8, detail: []const u8) !void {
    const old = result.candidate_followups;
    var out = try allocator.alloc(CandidateFollowup, old.len + 1);
    @memcpy(out[0..old.len], old);
    out[old.len] = .{
        .kind = try allocator.dupe(u8, kind),
        .detail = try allocator.dupe(u8, detail),
    };
    allocator.free(old);
    result.candidate_followups = out;
}

fn appendUnknownToResult(allocator: std.mem.Allocator, result: *Result, kind: UnknownKind, reason: []const u8) !void {
    result.unknowns = try appendUnknown(allocator, result.unknowns, kind, reason);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return false;
    var idx: usize = 0;
    while (idx + needle.len <= haystack.len) : (idx += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[idx .. idx + needle.len], needle)) return true;
    }
    return false;
}

fn malformedResult(allocator: std.mem.Allocator, question: []const u8, reason: []const u8) !Result {
    return .{
        .allocator = allocator,
        .status = .unknown,
        .state = try allocator.dupe(u8, "unresolved"),
        .permission = try allocator.dupe(u8, "unresolved"),
        .question = try allocator.dupe(u8, question),
        .shard_kind = try allocator.dupe(u8, "unknown"),
        .shard_id = try allocator.dupe(u8, "unknown"),
        .unknowns = try singleUnknown(allocator, .malformed_request, reason),
        .candidate_followups = try singleFollowup(allocator, "question_to_ask_user", "provide a non-empty question"),
    };
}

fn unknownResult(
    allocator: std.mem.Allocator,
    options: Options,
    paths: *const shards.Paths,
    kind: UnknownKind,
    reason: []const u8,
    entries_considered: usize,
    max_results: usize,
    max_snippet_bytes: usize,
) !Result {
    var result = try buildBaseResult(allocator, options, paths, .unknown, "unresolved", "unresolved", entries_considered, max_results, max_snippet_bytes);
    errdefer result.deinit();
    result.unknowns = try singleUnknown(allocator, kind, reason);
    result.candidate_followups = switch (kind) {
        .no_corpus_available => try singleFollowup(allocator, "evidence_to_collect", "ingest and explicitly commit a corpus for the target shard before asking again"),
        .insufficient_evidence => try singleFollowup(allocator, "evidence_to_collect", "provide a more specific question or ingest corpus evidence that addresses it"),
        .conflicting_evidence => try singleFollowup(allocator, "evidence_to_collect", "provide authoritative evidence to resolve the conflict"),
        .capacity_limited => try singleFollowup(allocator, "capacity_review_candidate", "raise explicit retrieval bounds or inspect skipped/truncated corpus coverage before relying on missing evidence"),
        .malformed_request => try singleFollowup(allocator, "question_to_ask_user", "provide a valid ask request"),
    };
    result.learning_candidates = try singleLearningCandidate(
        allocator,
        "corpus_update_candidate",
        "review whether new corpus evidence or a correction candidate should be added through an explicit lifecycle",
        reason,
    );
    return result;
}

fn buildBaseResult(
    allocator: std.mem.Allocator,
    options: Options,
    paths: *const shards.Paths,
    status: AskStatus,
    state: []const u8,
    permission: []const u8,
    entries_considered: usize,
    max_results: usize,
    max_snippet_bytes: usize,
) !Result {
    return .{
        .allocator = allocator,
        .status = status,
        .state = try allocator.dupe(u8, state),
        .permission = try allocator.dupe(u8, permission),
        .question = try allocator.dupe(u8, options.question),
        .shard_kind = try allocator.dupe(u8, @tagName(paths.metadata.kind)),
        .shard_id = try allocator.dupe(u8, paths.metadata.id),
        .corpus_entries_considered = entries_considered,
        .max_results = max_results,
        .max_snippet_bytes = max_snippet_bytes,
        .require_citations = options.require_citations,
    };
}

fn singleUnknown(allocator: std.mem.Allocator, kind: UnknownKind, reason: []const u8) ![]Unknown {
    const items = try allocator.alloc(Unknown, 1);
    items[0] = .{
        .kind = kind,
        .reason = try allocator.dupe(u8, reason),
    };
    return items;
}

fn appendUnknown(allocator: std.mem.Allocator, existing: []Unknown, kind: UnknownKind, reason: []const u8) ![]Unknown {
    const out = try allocator.alloc(Unknown, existing.len + 1);
    @memcpy(out[0..existing.len], existing);
    out[existing.len] = .{
        .kind = kind,
        .reason = try allocator.dupe(u8, reason),
    };
    allocator.free(existing);
    return out;
}

fn applyCapacityDisclosure(allocator: std.mem.Allocator, result: *Result) !void {
    if (result.capacity_telemetry.hasPressure()) {
        result.unknowns = try appendUnknown(
            allocator,
            result.unknowns,
            .capacity_limited,
            "bounded corpus retrieval had skipped, truncated, or capped coverage; missing evidence remains unknown and cannot be treated as negative evidence",
        );
        if (result.candidate_followups.len == 0) {
            result.candidate_followups = try singleFollowup(allocator, "capacity_review_candidate", "raise explicit retrieval bounds or inspect skipped/truncated corpus coverage before relying on missing evidence");
        }
    }
    result.capacity_telemetry.unknowns_created = result.unknowns.len;
}

fn attachLiveCoverage(allocator: std.mem.Allocator, result: *Result, coverage: corpus_ingest.LiveCoverage) !void {
    result.corpus_coverage_complete = coverage.complete;
    if (result.corpus_coverage_next_cursor) |value| {
        allocator.free(value);
        result.corpus_coverage_next_cursor = null;
    }
    if (coverage.next_cursor) |value| {
        result.corpus_coverage_next_cursor = try allocator.dupe(u8, value);
    }
    if (!coverage.complete) {
        result.capacity_telemetry.expansion_recommended = true;
    }
}

fn singleFollowup(allocator: std.mem.Allocator, kind: []const u8, detail: []const u8) ![]CandidateFollowup {
    const items = try allocator.alloc(CandidateFollowup, 1);
    items[0] = .{
        .kind = try allocator.dupe(u8, kind),
        .detail = try allocator.dupe(u8, detail),
    };
    return items;
}

fn singleLearningCandidate(
    allocator: std.mem.Allocator,
    candidate_kind: []const u8,
    proposed_action: []const u8,
    reason: []const u8,
) ![]LearningCandidate {
    const items = try allocator.alloc(LearningCandidate, 1);
    items[0] = .{
        .candidate_kind = try allocator.dupe(u8, candidate_kind),
        .proposed_action = try allocator.dupe(u8, proposed_action),
        .reason = try allocator.dupe(u8, reason),
    };
    return items;
}

fn buildEvidence(
    allocator: std.mem.Allocator,
    candidates: []const Candidate,
    entries: []const corpus_ingest.IndexedEntry,
    max_snippet_bytes: usize,
    reason: []const u8,
) ![]EvidenceUsed {
    var out = try allocator.alloc(EvidenceUsed, candidates.len);
    errdefer {
        for (out[0..]) |*item| item.deinit(allocator);
        allocator.free(out);
    }

    for (candidates, 0..) |candidate, idx| {
        const entry = entries[candidate.entry_index];
        const snippet = try makeSnippet(allocator, candidate.text, candidate.first_match, max_snippet_bytes);
        out[idx] = .{
            .item_id = try allocator.dupe(u8, entry.corpus_meta.lineage_id),
            .path = try allocator.dupe(u8, entry.rel_path),
            .source_path = try allocator.dupe(u8, entry.corpus_meta.source_rel_path),
            .source_label = try allocator.dupe(u8, entry.corpus_meta.source_label),
            .class_name = try allocator.dupe(u8, corpus_ingest.className(entry.corpus_meta.class)),
            .trust_class = try allocator.dupe(u8, abstractions.trustClassName(entry.corpus_meta.trust_class)),
            .content_hash = try std.fmt.allocPrint(allocator, "fnv1a64:{x:0>16}", .{candidate.content_hash}),
            .byte_start = candidate.byte_start,
            .byte_end = candidate.byte_end,
            .line_start = candidate.line_start,
            .line_end = candidate.line_end,
            .snippet = snippet.text,
            .snippet_truncated = snippet.truncated,
            .matched_terms = try cloneStringSlice(allocator, candidate.matched_terms),
            .matched_phrase = if (candidate.matched_phrase) |phrase| try allocator.dupe(u8, phrase) else null,
            .reason = try allocator.dupe(u8, reason),
            .match_reason = try allocator.dupe(u8, if (candidate.matched_phrase != null) "exact_phrase_and_token_overlap" else "case_insensitive_exact_token_overlap"),
            .provenance = try allocator.dupe(u8, entry.corpus_meta.provenance),
            .score = candidate.score,
            .rank = idx + 1,
        };
    }
    return out;
}

fn buildSimilarCandidates(
    allocator: std.mem.Allocator,
    candidates: []SketchCandidate,
    entries: []const corpus_ingest.IndexedEntry,
    max_results: usize,
) ![]SimilarCandidate {
    std.mem.sort(SketchCandidate, candidates, {}, sketchCandidateLessThan);
    const count = @min(@min(max_results, MAX_SKETCH_CANDIDATES), candidates.len);
    var out = try allocator.alloc(SimilarCandidate, count);
    var built: usize = 0;
    errdefer {
        for (out[0..built]) |*item| item.deinit(allocator);
        allocator.free(out);
    }

    for (candidates[0..count], 0..) |candidate, idx| {
        const entry = entries[candidate.entry_index];
        out[idx] = .{
            .item_id = try allocator.dupe(u8, entry.corpus_meta.lineage_id),
            .path = try allocator.dupe(u8, entry.rel_path),
            .source_path = try allocator.dupe(u8, entry.corpus_meta.source_rel_path),
            .source_label = try allocator.dupe(u8, entry.corpus_meta.source_label),
            .trust_class = try allocator.dupe(u8, abstractions.trustClassName(entry.corpus_meta.trust_class)),
            .sketch_hash = try std.fmt.allocPrint(allocator, "simhash64:{x:0>16}", .{candidate.sketch_hash}),
            .hamming_distance = candidate.hamming_distance,
            .similarity_score = candidate.similarity_score,
            .reason = try allocator.dupe(u8, "simhash_near_duplicate"),
            .rank = idx + 1,
        };
        built += 1;
    }
    return out;
}

fn sketchCandidatesCapHit(candidate_count: usize, max_results: usize) bool {
    const cap = @min(max_results, MAX_SKETCH_CANDIDATES);
    return candidate_count > cap;
}

fn countTruncatedSnippets(evidence: []const EvidenceUsed) usize {
    var count: usize = 0;
    for (evidence) |item| {
        if (item.snippet_truncated) count += 1;
    }
    return count;
}

fn sketchCandidateLessThan(_: void, lhs: SketchCandidate, rhs: SketchCandidate) bool {
    if (lhs.hamming_distance != rhs.hamming_distance) return lhs.hamming_distance < rhs.hamming_distance;
    if (lhs.similarity_score != rhs.similarity_score) return lhs.similarity_score > rhs.similarity_score;
    return lhs.entry_index < rhs.entry_index;
}

fn readEntryText(allocator: std.mem.Allocator, abs_path: []const u8) !ReadEntryResult {
    const file = try std.fs.openFileAbsolute(abs_path, .{});
    defer file.close();
    const file_size = try file.getEndPos();
    const read_len: usize = @intCast(@min(file_size, MAX_FILE_READ_BYTES));
    var buffer = try allocator.alloc(u8, read_len);
    errdefer allocator.free(buffer);
    const actual = try file.readAll(buffer);
    if (actual != read_len) {
        buffer = try allocator.realloc(buffer, actual);
    }
    return .{
        .text = buffer,
        .truncated = file_size > MAX_FILE_READ_BYTES,
    };
}

fn tokenizeQuery(allocator: std.mem.Allocator, question: []const u8) !QueryTokens {
    var tokens = std.ArrayList([]u8).init(allocator);
    errdefer {
        for (tokens.items) |token| allocator.free(token);
        tokens.deinit();
    }

    var start: ?usize = null;
    for (question, 0..) |c, idx| {
        if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-') {
            if (start == null) start = idx;
        } else if (start) |s| {
            try appendToken(allocator, &tokens, question[s..idx]);
            start = null;
            if (tokens.items.len >= MAX_QUERY_TOKENS) break;
        }
    }
    if (start) |s| {
        if (tokens.items.len < MAX_QUERY_TOKENS) try appendToken(allocator, &tokens, question[s..]);
    }

    return .{ .tokens = try tokens.toOwnedSlice() };
}

fn appendToken(allocator: std.mem.Allocator, tokens: *std.ArrayList([]u8), raw: []const u8) !void {
    const trimmed = std.mem.trim(u8, raw, " \r\n\t.,:;!?()[]{}\"'");
    if (trimmed.len < MIN_TOKEN_LEN) return;
    if (isStopWord(trimmed)) return;

    const lower = try allocator.alloc(u8, trimmed.len);
    errdefer allocator.free(lower);
    for (trimmed, 0..) |c, idx| lower[idx] = std.ascii.toLower(c);
    for (tokens.items) |existing| {
        if (std.mem.eql(u8, existing, lower)) {
            allocator.free(lower);
            return;
        }
    }
    try tokens.append(lower);
}

fn isStopWord(token: []const u8) bool {
    const words = [_][]const u8{
        "the",  "and",  "for",   "with",  "from",   "what",  "when",  "where", "which", "this", "that",
        "does", "into", "about", "using", "should", "would", "could", "tell",  "give",  "show",
    };
    for (words) |word| {
        if (std.ascii.eqlIgnoreCase(token, word)) return true;
    }
    return false;
}

fn scoreText(allocator: std.mem.Allocator, text_tokens: []const TextToken, tokens: []const []const u8) !MatchSummary {
    var score: u32 = 0;
    var first_match: usize = 0;
    var byte_start: usize = 0;
    var byte_end: usize = 0;
    var line_start: usize = 0;
    var line_end: usize = 0;
    var found_any = false;
    var matched_terms = std.ArrayList([]u8).init(allocator);
    errdefer {
        for (matched_terms.items) |term| allocator.free(term);
        matched_terms.deinit();
    }

    for (tokens) |token| {
        var token_count: u32 = 0;
        var first_token: ?TextToken = null;
        for (text_tokens) |text_token| {
            if (!std.mem.eql(u8, text_token.lower, token)) continue;
            token_count += 1;
            if (first_token == null) first_token = text_token;
        }
        if (first_token) |first| {
            score += 1;
            score += @min(token_count, 3) - 1;
            try matched_terms.append(try allocator.dupe(u8, token));
            if (!found_any or first.start < first_match) {
                first_match = first.start;
                byte_start = first.start;
                byte_end = first.end;
                line_start = first.line_start;
                line_end = first.line_end;
            }
            found_any = true;
        }
    }

    const phrase = try findBestPhrase(allocator, text_tokens, tokens);
    if (phrase) |hit| {
        score += 20 + @as(u32, @intCast(hit.token_count * 5));
        if (!found_any or hit.byte_start < first_match) first_match = hit.byte_start;
        byte_start = hit.byte_start;
        byte_end = hit.byte_end;
        line_start = hit.line_start;
        line_end = hit.line_end;
        found_any = true;
    }

    return .{
        .score = if (found_any) score else 0,
        .first_match = if (found_any) first_match else 0,
        .byte_start = if (found_any) byte_start else 0,
        .byte_end = if (found_any) byte_end else 0,
        .line_start = if (found_any) line_start else 0,
        .line_end = if (found_any) line_end else 0,
        .matched_terms = try matched_terms.toOwnedSlice(),
        .matched_phrase = if (phrase) |hit| hit.text else null,
    };
}

fn candidateLessThan(_: void, lhs: Candidate, rhs: Candidate) bool {
    if (lhs.score != rhs.score) return lhs.score > rhs.score;
    if ((lhs.matched_phrase != null) != (rhs.matched_phrase != null)) return lhs.matched_phrase != null;
    if (lhs.first_match != rhs.first_match) return lhs.first_match < rhs.first_match;
    return lhs.entry_index < rhs.entry_index;
}

fn requiredScore(token_count: usize) u32 {
    if (token_count <= 1) return 1;
    return 2;
}

fn detectPolarity(text: []const u8) Polarity {
    var affirmative = false;
    var negative = false;
    const yes_terms = [_][]const u8{ " enabled", " enable ", " yes", " true", " must ", " required", " supported" };
    const no_terms = [_][]const u8{ " disabled", " disable ", " no", " false", " must not", " unsupported", " forbidden" };

    for (yes_terms) |term| {
        if (indexOfIgnoreCase(text, term) != null) {
            affirmative = true;
            break;
        }
    }
    for (no_terms) |term| {
        if (indexOfIgnoreCase(text, term) != null) {
            negative = true;
            break;
        }
    }

    if (affirmative and !negative) return .affirmative;
    if (negative and !affirmative) return .negative;
    return .none;
}

fn classifyQueryIntent(question: []const u8, tokens: []const []const u8) QueryIntent {
    if (indexOfIgnoreCase(question, "release date") != null or
        indexOfIgnoreCase(question, "what date") != null or
        indexOfIgnoreCase(question, "when ") != null)
    {
        return .date_value;
    }
    if (indexOfIgnoreCase(question, " path") != null or
        indexOfIgnoreCase(question, " file") != null or
        indexOfIgnoreCase(question, "where ") != null)
    {
        return .path_value;
    }
    if (indexOfIgnoreCase(question, " enabled") != null or
        indexOfIgnoreCase(question, " disabled") != null or
        indexOfIgnoreCase(question, " true") != null or
        indexOfIgnoreCase(question, " false") != null or
        indexOfIgnoreCase(question, " yes") != null or
        indexOfIgnoreCase(question, " no") != null or
        startsWithIgnoreCase(question, "is ") or
        startsWithIgnoreCase(question, "are ") or
        startsWithIgnoreCase(question, "does ") or
        startsWithIgnoreCase(question, "do "))
    {
        return .boolean_value;
    }
    if (indexOfIgnoreCase(question, "version") != null or indexOfIgnoreCase(question, "number") != null or indexOfIgnoreCase(question, "how many") != null) {
        return .numeric_value;
    }
    for (tokens) |token| {
        if (std.mem.indexOfScalar(u8, token, '_') != null or std.mem.indexOfScalar(u8, token, '-') != null) return .config_value;
    }
    if (startsWithIgnoreCase(question, "who ") or
        indexOfIgnoreCase(question, "owner") != null or
        indexOfIgnoreCase(question, "author") != null or
        indexOfIgnoreCase(question, " maintainer") != null or
        indexOfIgnoreCase(question, " identity") != null)
    {
        return .identity_value;
    }
    return .general;
}

fn evidenceMatchesIntent(text: []const u8, intent: QueryIntent) bool {
    return switch (intent) {
        .general => true,
        .date_value => containsDateLike(text),
        .numeric_value, .config_value => containsNumber(text),
        .path_value => containsPathLike(text),
        .boolean_value => detectPolarity(text) != .none,
        .identity_value => containsIdentityLike(text),
    };
}

fn containsNumber(text: []const u8) bool {
    var idx: usize = 0;
    while (idx < text.len) : (idx += 1) {
        if (std.ascii.isDigit(text[idx])) return true;
    }
    return false;
}

fn containsDateLike(text: []const u8) bool {
    var idx: usize = 0;
    while (idx + 10 <= text.len) : (idx += 1) {
        if (std.ascii.isDigit(text[idx]) and
            std.ascii.isDigit(text[idx + 1]) and
            std.ascii.isDigit(text[idx + 2]) and
            std.ascii.isDigit(text[idx + 3]) and
            (text[idx + 4] == '-' or text[idx + 4] == '/') and
            std.ascii.isDigit(text[idx + 5]) and
            std.ascii.isDigit(text[idx + 6]) and
            (text[idx + 7] == '-' or text[idx + 7] == '/') and
            std.ascii.isDigit(text[idx + 8]) and
            std.ascii.isDigit(text[idx + 9]))
        {
            return true;
        }
    }
    const months = [_][]const u8{ "january", "february", "march", "april", "may ", "june", "july", "august", "september", "october", "november", "december" };
    for (months) |month| {
        if (indexOfIgnoreCase(text, month) != null and containsNumber(text)) return true;
    }
    return false;
}

fn containsPathLike(text: []const u8) bool {
    return std.mem.indexOfScalar(u8, text, '/') != null or
        indexOfIgnoreCase(text, ".zig") != null or
        indexOfIgnoreCase(text, ".md") != null or
        indexOfIgnoreCase(text, ".json") != null or
        indexOfIgnoreCase(text, ".toml") != null;
}

fn containsIdentityLike(text: []const u8) bool {
    return indexOfIgnoreCase(text, "owner") != null or
        indexOfIgnoreCase(text, "author") != null or
        indexOfIgnoreCase(text, "maintainer") != null or
        indexOfIgnoreCase(text, "by ") != null;
}

fn startsWithIgnoreCase(text: []const u8, prefix: []const u8) bool {
    return text.len >= prefix.len and std.ascii.eqlIgnoreCase(text[0..prefix.len], prefix);
}

fn hasConflict(candidates: []const Candidate) bool {
    var affirmative = false;
    var negative = false;
    for (candidates) |candidate| {
        switch (candidate.polarity) {
            .affirmative => affirmative = true,
            .negative => negative = true,
            .none => {},
        }
    }
    return affirmative and negative;
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or needle.len > haystack.len) return null;
    var idx: usize = 0;
    while (idx + needle.len <= haystack.len) : (idx += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[idx .. idx + needle.len], needle)) return idx;
    }
    return null;
}

fn tokenizeText(allocator: std.mem.Allocator, text: []const u8) ![]TextToken {
    var out = std.ArrayList(TextToken).init(allocator);
    errdefer {
        for (out.items) |*token| token.deinit(allocator);
        out.deinit();
    }

    var start: ?usize = null;
    var line: usize = 1;
    var token_line: usize = 1;
    for (text, 0..) |c, idx| {
        if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-') {
            if (start == null) {
                start = idx;
                token_line = line;
            }
        } else {
            if (start) |s| {
                try appendTextToken(allocator, &out, text[s..idx], s, idx, token_line, line);
                start = null;
            }
            if (c == '\n') line += 1;
        }
    }
    if (start) |s| try appendTextToken(allocator, &out, text[s..], s, text.len, token_line, line);
    return out.toOwnedSlice();
}

fn appendTextToken(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(TextToken),
    raw: []const u8,
    start: usize,
    end: usize,
    line_start: usize,
    line_end: usize,
) !void {
    const lower = try allocator.alloc(u8, raw.len);
    errdefer allocator.free(lower);
    for (raw, 0..) |c, idx| lower[idx] = std.ascii.toLower(c);
    try out.append(.{
        .lower = lower,
        .start = start,
        .end = end,
        .line_start = line_start,
        .line_end = line_end,
    });
}

fn freeTextTokens(allocator: std.mem.Allocator, tokens: []TextToken) void {
    for (tokens) |*token| token.deinit(allocator);
    allocator.free(tokens);
}

fn findBestPhrase(allocator: std.mem.Allocator, text_tokens: []const TextToken, query_tokens: []const []const u8) !?PhraseHit {
    if (query_tokens.len < 2 or text_tokens.len < 2) return null;
    var phrase_len = @min(query_tokens.len, @as(usize, 5));
    while (phrase_len >= 2) : (phrase_len -= 1) {
        var query_start: usize = 0;
        while (query_start + phrase_len <= query_tokens.len) : (query_start += 1) {
            const phrase_tokens = query_tokens[query_start .. query_start + phrase_len];
            var text_start: usize = 0;
            while (text_start + phrase_len <= text_tokens.len) : (text_start += 1) {
                var matches = true;
                for (phrase_tokens, 0..) |phrase_token, offset| {
                    if (!std.mem.eql(u8, phrase_token, text_tokens[text_start + offset].lower)) {
                        matches = false;
                        break;
                    }
                }
                if (!matches) continue;
                return .{
                    .text = try joinPhrase(allocator, phrase_tokens),
                    .token_count = phrase_len,
                    .byte_start = text_tokens[text_start].start,
                    .byte_end = text_tokens[text_start + phrase_len - 1].end,
                    .line_start = text_tokens[text_start].line_start,
                    .line_end = text_tokens[text_start + phrase_len - 1].line_end,
                };
            }
        }
        if (phrase_len == 2) break;
    }
    return null;
}

fn joinPhrase(allocator: std.mem.Allocator, tokens: []const []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    for (tokens, 0..) |token, idx| {
        if (idx != 0) try out.append(' ');
        try out.appendSlice(token);
    }
    return out.toOwnedSlice();
}

fn cloneStringSlice(allocator: std.mem.Allocator, values: []const []const u8) ![][]u8 {
    const out = try allocator.alloc([]u8, values.len);
    var built: usize = 0;
    errdefer {
        for (out[0..built]) |value| allocator.free(value);
        allocator.free(out);
    }
    for (values, 0..) |value, idx| {
        out[idx] = try allocator.dupe(u8, value);
        built += 1;
    }
    return out;
}

fn makeSnippet(allocator: std.mem.Allocator, text: []const u8, first_match: usize, max_bytes: usize) !Snippet {
    if (text.len <= max_bytes) return .{ .text = try cleanSnippet(allocator, text), .truncated = false };
    const half = max_bytes / 2;
    const start = if (first_match > half) first_match - half else 0;
    const end = @min(text.len, start + max_bytes);
    return .{ .text = try cleanSnippet(allocator, text[start..end]), .truncated = true };
}

fn cleanSnippet(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    var last_space = false;
    for (text) |c| {
        const normalized: u8 = switch (c) {
            '\n', '\r', '\t' => ' ',
            else => c,
        };
        if (normalized == ' ') {
            if (last_space) continue;
            last_space = true;
        } else {
            last_space = false;
        }
        try out.append(normalized);
    }
    return out.toOwnedSlice();
}

pub fn renderJson(allocator: std.mem.Allocator, result: *const Result) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    try w.writeAll("{\"corpusAsk\":{");
    try writeField(w, "status", @tagName(result.status), true);
    try writeField(w, "state", result.state, false);
    try writeField(w, "permission", result.permission, false);
    try w.writeAll(",\"nonAuthorizing\":true");
    try writeField(w, "question", result.question, false);
    try w.writeAll(",\"shard\":{");
    try writeField(w, "kind", result.shard_kind, true);
    try writeField(w, "id", result.shard_id, false);
    try w.writeAll("}");
    if (result.answer_draft) |answer| try writeField(w, "answerDraft", answer, false);
    try w.writeAll(",\"evidenceUsed\":[");
    for (result.evidence_used, 0..) |evidence, idx| {
        if (idx != 0) try w.writeByte(',');
        try w.writeAll("{");
        try writeField(w, "itemId", evidence.item_id, true);
        try writeField(w, "path", evidence.path, false);
        try writeField(w, "sourcePath", evidence.source_path, false);
        try writeField(w, "sourceLabel", evidence.source_label, false);
        try writeField(w, "class", evidence.class_name, false);
        try writeField(w, "trustClass", evidence.trust_class, false);
        try writeField(w, "contentHash", evidence.content_hash, false);
        try w.print(",\"byteSpan\":{{\"start\":{d},\"end\":{d}}}", .{ evidence.byte_start, evidence.byte_end });
        try w.print(",\"lineSpan\":{{\"start\":{d},\"end\":{d}}}", .{ evidence.line_start, evidence.line_end });
        try writeField(w, "snippet", evidence.snippet, false);
        try w.print(",\"snippetTruncated\":{s}", .{if (evidence.snippet_truncated) "true" else "false"});
        try w.writeAll(",\"matchedTerms\":[");
        for (evidence.matched_terms, 0..) |term, term_idx| {
            if (term_idx != 0) try w.writeByte(',');
            try w.writeByte('"');
            try writeEscaped(w, term);
            try w.writeByte('"');
        }
        try w.writeAll("]");
        if (evidence.matched_phrase) |phrase| try writeField(w, "matchedPhrase", phrase, false);
        try writeField(w, "reason", evidence.reason, false);
        try writeField(w, "matchReason", evidence.match_reason, false);
        try writeField(w, "provenance", evidence.provenance, false);
        try w.print(",\"score\":{d}", .{evidence.score});
        try w.print(",\"rank\":{d}", .{evidence.rank});
        try w.writeAll("}");
    }
    try w.writeAll("],\"similarCandidates\":[");
    for (result.similar_candidates, 0..) |candidate, idx| {
        if (idx != 0) try w.writeByte(',');
        try w.writeAll("{");
        try writeField(w, "itemId", candidate.item_id, true);
        try writeField(w, "path", candidate.path, false);
        try writeField(w, "sourcePath", candidate.source_path, false);
        try writeField(w, "sourceLabel", candidate.source_label, false);
        try writeField(w, "trustClass", candidate.trust_class, false);
        try writeField(w, "sketchHash", candidate.sketch_hash, false);
        try w.print(",\"hammingDistance\":{d}", .{candidate.hamming_distance});
        try w.print(",\"similarityScore\":{d}", .{candidate.similarity_score});
        try writeField(w, "reason", candidate.reason, false);
        try w.print(",\"nonAuthorizing\":{s}", .{if (candidate.non_authorizing) "true" else "false"});
        try w.print(",\"rank\":{d}", .{candidate.rank});
        try w.writeAll("}");
    }
    try w.writeAll("],\"acceptedCorrectionWarnings\":[");
    for (result.accepted_correction_warnings, 0..) |warning, idx| {
        if (idx != 0) try w.writeByte(',');
        try w.writeAll("{");
        try w.print("\"lineNumber\":{d}", .{warning.line_number});
        try writeField(w, "reason", warning.reason, false);
        try w.writeAll("}");
    }
    try w.writeAll("],\"correctionInfluences\":[");
    for (result.correction_influences, 0..) |influence, idx| {
        if (idx != 0) try w.writeByte(',');
        try w.writeAll("{");
        try writeField(w, "id", influence.id, true);
        try writeField(w, "sourceReviewedCorrectionId", influence.source_reviewed_correction_id, false);
        try writeField(w, "influenceKind", influence.influence_kind, false);
        try writeField(w, "reason", influence.reason, false);
        try writeField(w, "appliesTo", influence.applies_to, false);
        try writeField(w, "matchedPattern", influence.matched_pattern, false);
        try writeField(w, "disputedOutputFingerprint", influence.disputed_output_fingerprint, false);
        try w.print(",\"nonAuthorizing\":{s}", .{if (influence.non_authorizing) "true" else "false"});
        try w.print(",\"treatedAsProof\":{s}", .{if (influence.treated_as_proof) "true" else "false"});
        try w.print(",\"globalPromotion\":{s}", .{if (influence.global_promotion) "true" else "false"});
        try w.writeAll(",\"mutationFlags\":");
        try writeCorrectionMutationFlags(w, influence.mutation_flags);
        try w.writeAll("}");
    }
    try w.writeAll("],\"acceptedNegativeKnowledgeWarnings\":[");
    for (result.accepted_negative_knowledge_warnings, 0..) |warning, idx| {
        if (idx != 0) try w.writeByte(',');
        try w.writeAll("{");
        try w.print("\"lineNumber\":{d}", .{warning.line_number});
        try writeField(w, "reason", warning.reason, false);
        try w.writeAll("}");
    }
    try w.writeAll("],\"negativeKnowledgeInfluences\":[");
    for (result.negative_knowledge_influences, 0..) |influence, idx| {
        if (idx != 0) try w.writeByte(',');
        try w.writeAll("{");
        try writeField(w, "id", influence.id, true);
        try writeField(w, "sourceReviewedNegativeKnowledgeId", influence.source_reviewed_negative_knowledge_id, false);
        try writeField(w, "influenceKind", influence.influence_kind, false);
        try writeField(w, "appliesTo", influence.applies_to, false);
        try writeField(w, "matchedPattern", influence.matched_pattern, false);
        if (influence.matched_output_id) |value| try writeField(w, "matchedOutputId", value, false);
        if (influence.matched_rule_id) |value| try writeField(w, "matchedRuleId", value, false);
        try writeField(w, "reason", influence.reason, false);
        try w.print(",\"nonAuthorizing\":{s}", .{if (influence.non_authorizing) "true" else "false"});
        try w.print(",\"treatedAsProof\":{s}", .{if (influence.treated_as_proof) "true" else "false"});
        try w.print(",\"usedAsEvidence\":{s}", .{if (influence.used_as_evidence) "true" else "false"});
        try w.print(",\"globalPromotion\":{s}", .{if (influence.global_promotion) "true" else "false"});
        try w.writeAll(",\"mutationFlags\":");
        try writeCorrectionMutationFlags(w, influence.mutation_flags);
        try w.writeAll("}");
    }
    try w.writeAll("],\"futureBehaviorCandidates\":[");
    for (result.future_behavior_candidates, 0..) |candidate, idx| {
        if (idx != 0) try w.writeByte(',');
        try w.writeAll("{");
        try writeField(w, "kind", candidate.kind, true);
        try writeField(w, "status", candidate.status, false);
        try writeField(w, "reason", candidate.reason, false);
        if (candidate.source_reviewed_correction_id) |value| try writeField(w, "sourceReviewedCorrectionId", value, false);
        if (candidate.source_reviewed_negative_knowledge_id) |value| try writeField(w, "sourceReviewedNegativeKnowledgeId", value, false);
        try w.print(",\"candidateOnly\":{s}", .{if (candidate.candidate_only) "true" else "false"});
        try w.print(",\"nonAuthorizing\":{s}", .{if (candidate.non_authorizing) "true" else "false"});
        try w.print(",\"treatedAsProof\":{s}", .{if (candidate.treated_as_proof) "true" else "false"});
        try w.print(",\"usedAsEvidence\":{s}", .{if (candidate.used_as_evidence) "true" else "false"});
        try w.print(",\"globalPromotion\":{s}", .{if (candidate.global_promotion) "true" else "false"});
        try w.writeAll(",\"mutationFlags\":");
        try writeCorrectionMutationFlags(w, candidate.mutation_flags);
        try w.writeAll("}");
    }
    try w.writeAll("],\"influenceTelemetry\":");
    try writeInfluenceTelemetry(w, result.influence_telemetry);
    try w.writeAll(",\"negativeKnowledgeTelemetry\":");
    try writeNegativeKnowledgeTelemetry(w, result.negative_knowledge_telemetry);
    try w.writeAll(",\"unknowns\":[");
    for (result.unknowns, 0..) |unknown, idx| {
        if (idx != 0) try w.writeByte(',');
        try w.writeAll("{");
        try writeField(w, "kind", @tagName(unknown.kind), true);
        try writeField(w, "reason", unknown.reason, false);
        try w.writeAll("}");
    }
    try w.writeAll("],\"candidateFollowups\":[");
    for (result.candidate_followups, 0..) |followup, idx| {
        if (idx != 0) try w.writeByte(',');
        try w.writeAll("{");
        try writeField(w, "kind", followup.kind, true);
        try writeField(w, "detail", followup.detail, false);
        try w.writeAll(",\"executes\":false}");
    }
    try w.writeAll("],\"learningCandidates\":[");
    for (result.learning_candidates, 0..) |candidate, idx| {
        if (idx != 0) try w.writeByte(',');
        try w.writeAll("{");
        try writeField(w, "candidateKind", candidate.candidate_kind, true);
        try writeField(w, "proposedAction", candidate.proposed_action, false);
        try writeField(w, "reason", candidate.reason, false);
        try w.print(",\"candidateOnly\":{s}", .{if (candidate.candidate_only) "true" else "false"});
        try w.print(",\"nonAuthorizing\":{s}", .{if (candidate.non_authorizing) "true" else "false"});
        try w.print(",\"treatedAsProof\":{s}", .{if (candidate.treated_as_proof) "true" else "false"});
        try w.print(",\"persisted\":{s}", .{if (candidate.persisted) "true" else "false"});
        try w.writeAll("}");
    }
    try w.writeAll("],\"capacityTelemetry\":");
    try writeCapacityTelemetry(w, result.capacity_telemetry);
    try w.writeAll(",\"coverage\":{");
    try w.print("\"complete\":{s}", .{if (result.corpus_coverage_complete) "true" else "false"});
    if (result.corpus_coverage_next_cursor) |value| try writeField(w, "nextCursor", value, false);
    try w.writeAll("}");
    try w.writeAll(",\"trace\":{");
    try w.print("\"corpusEntriesConsidered\":{d}", .{result.corpus_entries_considered});
    try w.print(",\"maxResults\":{d}", .{result.max_results});
    try w.print(",\"maxSnippetBytes\":{d}", .{result.max_snippet_bytes});
    try w.print(",\"requireCitations\":{s}", .{if (result.require_citations) "true" else "false"});
    try w.print(",\"corpusMutation\":{s}", .{if (result.safety_flags.corpus_mutation) "true" else "false"});
    try w.print(",\"packMutation\":{s}", .{if (result.safety_flags.pack_mutation) "true" else "false"});
    try w.print(",\"negativeKnowledgeMutation\":{s}", .{if (result.safety_flags.negative_knowledge_mutation) "true" else "false"});
    try w.print(",\"commandsExecuted\":{s}", .{if (result.safety_flags.commands_executed) "true" else "false"});
    try w.print(",\"verifiersExecuted\":{s}", .{if (result.safety_flags.verifiers_executed) "true" else "false"});
    try w.writeAll("}}}");
    return out.toOwnedSlice();
}

fn writeCapacityTelemetry(w: anytype, telemetry: CapacityTelemetry) !void {
    try w.writeAll("{");
    try w.print("\"droppedRunes\":{d},\"collisionStalls\":{d},\"saturatedSlots\":{d}", .{ telemetry.dropped_runes, telemetry.collision_stalls, telemetry.saturated_slots });
    try w.print(",\"truncatedInputs\":{d},\"truncatedSnippets\":{d},\"skippedInputs\":{d},\"skippedFiles\":{d}", .{ telemetry.truncated_inputs, telemetry.truncated_snippets, telemetry.skipped_inputs, telemetry.skipped_files });
    try w.print(",\"budgetHits\":{d},\"maxResultsHit\":{s},\"maxOutputsHit\":{s},\"maxRulesHit\":{s}", .{
        telemetry.budget_hits,
        if (telemetry.max_results_hit) "true" else "false",
        if (telemetry.max_outputs_hit) "true" else "false",
        if (telemetry.max_rules_hit) "true" else "false",
    });
    try w.print(",\"exactCandidateCapHit\":{s},\"sketchCandidateCapHit\":{s},\"unknownsCreated\":{d}", .{
        if (telemetry.exact_candidate_cap_hit) "true" else "false",
        if (telemetry.sketch_candidate_cap_hit) "true" else "false",
        telemetry.unknowns_created,
    });
    try w.writeAll(",\"capacityWarnings\":[");
    var wrote = false;
    try writeWarningIf(w, &wrote, telemetry.max_results_hit, "max_results_hit");
    try writeWarningIf(w, &wrote, telemetry.exact_candidate_cap_hit, "exact_candidate_cap_hit");
    try writeWarningIf(w, &wrote, telemetry.sketch_candidate_cap_hit, "sketch_candidate_cap_hit");
    try writeWarningIf(w, &wrote, telemetry.truncated_inputs != 0, "truncated_inputs");
    try writeWarningIf(w, &wrote, telemetry.truncated_snippets != 0, "truncated_snippets");
    try writeWarningIf(w, &wrote, telemetry.skipped_files != 0, "skipped_files");
    try w.print("],\"expansionRecommended\":{s},\"spilloverRecommended\":{s}", .{
        if (telemetry.expansion_recommended) "true" else "false",
        if (telemetry.spillover_recommended) "true" else "false",
    });
    try w.writeAll("}");
}

fn writeInfluenceTelemetry(w: anytype, telemetry: InfluenceTelemetry) !void {
    try w.writeAll("{");
    try w.print("\"reviewedRecordsRead\":{d},\"acceptedRecordsRead\":{d},\"rejectedRecordsRead\":{d}", .{
        telemetry.reviewed_records_read,
        telemetry.accepted_records_read,
        telemetry.rejected_records_read,
    });
    try w.print(",\"malformedLines\":{d},\"warnings\":{d},\"matchedInfluences\":{d}", .{
        telemetry.malformed_lines,
        telemetry.warnings,
        telemetry.matched_influences,
    });
    try w.print(",\"answerSuppressed\":{s},\"boundedReadTruncated\":{s}", .{
        if (telemetry.answer_suppressed) "true" else "false",
        if (telemetry.bounded_read_truncated) "true" else "false",
    });
    try w.writeAll("}");
}

fn writeNegativeKnowledgeTelemetry(w: anytype, telemetry: NegativeKnowledgeTelemetry) !void {
    try w.writeAll("{");
    try w.print("\"recordsRead\":{d},\"acceptedRecords\":{d},\"rejectedRecords\":{d}", .{
        telemetry.records_read,
        telemetry.accepted_records,
        telemetry.rejected_records,
    });
    try w.print(",\"malformedLines\":{d},\"warnings\":{d},\"influencesLoaded\":{d},\"influencesApplied\":{d}", .{
        telemetry.malformed_lines,
        telemetry.warnings,
        telemetry.influences_loaded,
        telemetry.influences_applied,
    });
    try w.print(",\"answerSuppressed\":{s},\"truncated\":{s},\"sameShardOnly\":{s}", .{
        if (telemetry.answer_suppressed) "true" else "false",
        if (telemetry.truncated) "true" else "false",
        if (telemetry.same_shard_only) "true" else "false",
    });
    try w.print(",\"mutationPerformed\":{s},\"commandsExecuted\":{s},\"verifiersExecuted\":{s}", .{
        if (telemetry.mutation_performed) "true" else "false",
        if (telemetry.commands_executed) "true" else "false",
        if (telemetry.verifiers_executed) "true" else "false",
    });
    try w.writeAll("}");
}

fn writeCorrectionMutationFlags(w: anytype, flags: CorrectionMutationFlags) !void {
    try w.writeAll("{");
    try w.print("\"corpusMutation\":{s},\"packMutation\":{s},\"negativeKnowledgeMutation\":{s}", .{
        if (flags.corpus_mutation) "true" else "false",
        if (flags.pack_mutation) "true" else "false",
        if (flags.negative_knowledge_mutation) "true" else "false",
    });
    try w.print(",\"commandsExecuted\":{s},\"verifiersExecuted\":{s}", .{
        if (flags.commands_executed) "true" else "false",
        if (flags.verifiers_executed) "true" else "false",
    });
    try w.writeAll("}");
}

fn writeWarningIf(w: anytype, wrote: *bool, condition: bool, warning: []const u8) !void {
    if (!condition) return;
    if (wrote.*) try w.writeByte(',');
    try w.writeByte('"');
    try writeEscaped(w, warning);
    try w.writeByte('"');
    wrote.* = true;
}

fn writeField(w: anytype, key: []const u8, value: []const u8, first: bool) !void {
    if (!first) try w.writeByte(',');
    try w.writeByte('"');
    try w.writeAll(key);
    try w.writeAll("\":\"");
    try writeEscaped(w, value);
    try w.writeByte('"');
}

fn writeEscaped(w: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try w.print("\\u{x:0>4}", .{@as(u16, c)});
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
}
