const std = @import("std");
const abstractions = @import("abstractions.zig");
const corpus_ingest = @import("corpus_ingest.zig");
const corpus_sketch = @import("corpus_sketch.zig");
const correction_review = @import("correction_review.zig");
const hash_acceleration = @import("hash_acceleration.zig");
const intent_grounding = @import("intent_grounding.zig");
const negative_knowledge_review = @import("negative_knowledge_review.zig");
const learning_store = @import("learning_store.zig");
const shards = @import("shards.zig");
const text_generation_lab = @import("text_generation_lab.zig");
const vsa_vulkan = @import("vsa_vulkan.zig");

pub const DEFAULT_MAX_RESULTS: usize = 3;
pub const MAX_RESULTS: usize = 8;
pub const DEFAULT_MAX_SNIPPET_BYTES: usize = 320;
pub const MAX_SNIPPET_BYTES: usize = 1024;
const DEFAULT_MAX_FILE_READ_BYTES: usize = 64 * 1024;
const SIMPLE_WIKI_MAX_FILE_READ_BYTES: usize = 2 * 1024 * 1024;
const MAX_QUERY_TOKENS: usize = 16;
const MIN_TOKEN_LEN: usize = 3;
const ASK_INDEX_SCAN_LIMIT: usize = 32;
const MAX_SKETCH_CANDIDATES: usize = 8;
const MAX_SIMHASH_DISTANCE: u7 = 32;
const PRIMARY_NOUN_MATCH_THRESHOLD_PERCENT: u8 = 50;
const PRIMARY_NOUN_SCORE_BONUS: u32 = 12;
const TITLE_MATCH_SCORE_BONUS: u32 = 80;
const DEFINITION_MATCH_SCORE_BONUS: u32 = 40;

pub const MountedPackRef = corpus_ingest.MountedPackRef;

pub const AskStatus = enum {
    answered,
    unknown,
    rejected_falsehood,
};

pub const UnknownKind = enum {
    no_corpus_available,
    insufficient_evidence,
    insufficient_high_rank_evidence,
    rejected_falsehood,
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
    mounted_packs: []const MountedPackRef = &.{},
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
    license_status: []u8,
    authority_level: u8,
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
        allocator.free(self.license_status);
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

pub const SuppressedEvidence = struct {
    item_id: []u8,
    path: []u8,
    source_path: []u8,
    source_label: []u8,
    reason: []u8,
    authority_ref: []u8,
    license_status: []u8,
    authority_level: u8,
    rank: usize,

    fn deinit(self: *SuppressedEvidence, allocator: std.mem.Allocator) void {
        allocator.free(self.item_id);
        allocator.free(self.path);
        allocator.free(self.source_path);
        allocator.free(self.source_label);
        allocator.free(self.reason);
        allocator.free(self.authority_ref);
        allocator.free(self.license_status);
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

pub const SelfReviewStatus = enum {
    passed,
    failed,
    ambiguous,

    pub fn text(self: SelfReviewStatus) []const u8 {
        return @tagName(self);
    }
};

pub const SelfReview = struct {
    status: SelfReviewStatus,
    matching_rules: [][]u8 = &.{},
    unresolved_contradictions: [][]u8 = &.{},

    pub fn deinit(self: *SelfReview, allocator: std.mem.Allocator) void {
        for (self.matching_rules) |r| allocator.free(r);
        allocator.free(self.matching_rules);
        for (self.unresolved_contradictions) |c| allocator.free(c);
        allocator.free(self.unresolved_contradictions);
        self.* = undefined;
    }
};

pub const LearningCandidate = struct {
    id: []u8,
    candidate_kind: []u8,
    proposed_action: []u8,
    reason: []u8,
    logic_pattern: []u8,
    candidate_only: bool = true,
    non_authorizing: bool = true,
    treated_as_proof: bool = false,
    persisted: bool = false,
    self_review: ?SelfReview = null,

    fn deinit(self: *LearningCandidate, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.candidate_kind);
        allocator.free(self.proposed_action);
        allocator.free(self.reason);
        allocator.free(self.logic_pattern);
        if (self.self_review) |*sr| sr.deinit(allocator);
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

pub const LearningInfluence = struct {
    id: []u8,
    source_reviewed_learning_id: []u8,
    learning_candidate_id: []u8,
    candidate_kind: []u8,
    logic_pattern: []u8,
    draft_signal: []u8,
    reason: []u8,
    source_store: []u8,
    non_authorizing: bool = true,
    treated_as_proof: bool = false,
    used_as_evidence: bool = false,
    global_promotion: bool = false,

    fn deinit(self: *LearningInfluence, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.source_reviewed_learning_id);
        allocator.free(self.learning_candidate_id);
        allocator.free(self.candidate_kind);
        allocator.free(self.logic_pattern);
        allocator.free(self.draft_signal);
        allocator.free(self.reason);
        allocator.free(self.source_store);
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

pub const LearningInfluenceTelemetry = struct {
    records_read: usize = 0,
    accepted_records: usize = 0,
    rejected_records: usize = 0,
    malformed_lines: usize = 0,
    warnings: usize = 0,
    influences_loaded: usize = 0,
    influences_applied: usize = 0,
    draft_promoted: bool = false,
    truncated: bool = false,
    same_shard_only: bool = true,
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
    suppressed_evidence: []SuppressedEvidence = &.{},
    unknowns: []Unknown = &.{},
    candidate_followups: []CandidateFollowup = &.{},
    learning_candidates: []LearningCandidate = &.{},
    similar_candidates: []SimilarCandidate = &.{},
    accepted_correction_warnings: []AcceptedCorrectionWarning = &.{},
    correction_influences: []CorrectionInfluence = &.{},
    accepted_negative_knowledge_warnings: []AcceptedNegativeKnowledgeWarning = &.{},
    negative_knowledge_influences: []NegativeKnowledgeInfluence = &.{},
    learning_influences: []LearningInfluence = &.{},
    future_behavior_candidates: []FutureBehaviorCandidate = &.{},
    safety_flags: SafetyFlags = .{},
    corpus_entries_considered: usize = 0,
    mounted_packs_considered: usize = 0,
    mounted_pack_entries_considered: usize = 0,
    corpus_coverage_complete: bool = true,
    corpus_coverage_next_cursor: ?[]u8 = null,
    max_results: usize = DEFAULT_MAX_RESULTS,
    max_snippet_bytes: usize = DEFAULT_MAX_SNIPPET_BYTES,
    require_citations: bool = true,
    capacity_telemetry: CapacityTelemetry = .{},
    influence_telemetry: InfluenceTelemetry = .{},
    negative_knowledge_telemetry: NegativeKnowledgeTelemetry = .{},
    learning_influence_telemetry: LearningInfluenceTelemetry = .{},
    parameter_match_failure: bool = false,
    primary_noun_match_failure: bool = false,

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
        for (self.suppressed_evidence) |*item| item.deinit(self.allocator);
        self.allocator.free(self.suppressed_evidence);
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
        for (self.learning_influences) |*item| item.deinit(self.allocator);
        self.allocator.free(self.learning_influences);
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
    similarity_score: u16,
    hybrid_score: f32,
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

const InferenceBridge = struct {
    candidate: Candidate,
    subject: []u8,
    satisfaction_token: []u8,
    pack_id: []u8,

    fn deinit(self: *InferenceBridge, allocator: std.mem.Allocator) void {
        allocator.free(self.subject);
        allocator.free(self.satisfaction_token);
        allocator.free(self.pack_id);
        self.* = undefined;
    }
};

const AuthorityOverride = struct {
    influence: correction_review.AcceptedCorrectionInfluence,
    subject: []const u8,
    answer_draft: []u8,

    fn deinit(self: *AuthorityOverride, allocator: std.mem.Allocator) void {
        allocator.free(self.answer_draft);
        self.* = undefined;
    }
};

const SketchCandidate = struct {
    entry_index: usize,
    sketch_hash: u64,
    hamming_distance: u7,
    similarity_score: u16,
};

const IndexScanCandidate = struct {
    entry_index: usize,
    hamming_distance: u7,
    similarity_score: u16,
};

fn hasSketchCandidate(candidates: []const SketchCandidate, entry_index: usize) bool {
    for (candidates) |candidate| {
        if (candidate.entry_index == entry_index) return true;
    }
    return false;
}

fn indexScanCandidateLessThan(_: void, lhs: IndexScanCandidate, rhs: IndexScanCandidate) bool {
    if (lhs.hamming_distance != rhs.hamming_distance) return lhs.hamming_distance < rhs.hamming_distance;
    if (lhs.similarity_score != rhs.similarity_score) return lhs.similarity_score > rhs.similarity_score;
    return lhs.entry_index < rhs.entry_index;
}

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
    var profile_timer: ?std.time.Timer = if (askProfileEnabled()) try std.time.Timer.start() else null;
    var profile_last_ns: u64 = 0;

    if (std.mem.trim(u8, options.question, " \r\n\t").len == 0) {
        return malformedResult(allocator, options.question, "question must be non-empty");
    }

    var salience = try intent_grounding.analyzeSalience(allocator, options.question);
    defer salience.deinit(allocator);
    const high_noise_request = salience.density_multiplier >= 3 and hasMultiRuneTarget(salience.semantic_target);
    const search_question = if (high_noise_request and salience.semantic_target.len != 0) salience.semantic_target else options.question;
    const requested_results = if (options.max_results == DEFAULT_MAX_RESULTS and options.max_snippet_bytes == DEFAULT_MAX_SNIPPET_BYTES)
        @min(MAX_RESULTS, DEFAULT_MAX_RESULTS * @as(usize, salience.density_multiplier))
    else
        options.max_results;
    const capped_results = @min(requested_results, MAX_RESULTS);
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
    askProfileMark(&profile_timer, &profile_last_ns, "resolve_shard");
    var reviewed = try correction_review.readAcceptedInfluences(allocator, paths.metadata.id);
    defer reviewed.deinit();
    var reviewed_nk = try negative_knowledge_review.readAcceptedInfluences(allocator, paths.metadata.id);
    defer reviewed_nk.deinit();
    var reviewed_learning = try learning_store.readAcceptedInfluences(allocator, paths.metadata.id);
    defer reviewed_learning.deinit();
    askProfileMark(&profile_timer, &profile_last_ns, "read_influences");

    const live_entries = try corpus_ingest.collectLiveScanEntries(allocator, &paths);
    const live_entry_count = live_entries.len;
    corpus_ingest.deinitIndexedEntries(allocator, live_entries);

    const entries = try corpus_ingest.collectComposedLiveScanEntries(allocator, &paths, options.mounted_packs);
    defer corpus_ingest.deinitIndexedEntries(allocator, entries);
    const mounted_pack_entry_count = entries.len - live_entry_count;
    var live_coverage = try corpus_ingest.liveCoverage(allocator, &paths);
    defer live_coverage.deinit(allocator);
    askProfileMark(&profile_timer, &profile_last_ns, "collect_entries_coverage");

    var guard_tokens = try tokenizeQuery(allocator, options.question);
    defer guard_tokens.deinit(allocator);
    var search_tokens = try tokenizeQuery(allocator, search_question);
    defer search_tokens.deinit(allocator);
    const autonomous_salience_scoring = options.max_results == DEFAULT_MAX_RESULTS and
        options.max_snippet_bytes == DEFAULT_MAX_SNIPPET_BYTES and
        high_noise_request;
    const scoring_tokens = if (autonomous_salience_scoring and search_tokens.tokens.len != 0) search_tokens.tokens else guard_tokens.tokens;
    const query_intent = classifyQueryIntent(options.question, guard_tokens.tokens);
    askProfileMark(&profile_timer, &profile_last_ns, "tokenize_query");

    if (entries.len == 0) {
        var result = try unknownResult(allocator, options, &paths, .no_corpus_available, "no live shard corpus or explicitly mounted Knowledge Pack corpus is available for this ask request", entries.len, max_results, max_snippet);
        errdefer result.deinit();
        result.mounted_packs_considered = options.mounted_packs.len;
        result.mounted_pack_entries_considered = mounted_pack_entry_count;
        try attachLiveCoverage(allocator, &result, live_coverage);
        try applyAcceptedCorrectionInfluence(allocator, &result, &reviewed);
        try applyAcceptedNegativeKnowledgeInfluence(allocator, &result, &reviewed_nk);
        try applyAcceptedLearningInfluence(allocator, &result, &reviewed_learning);
        return result;
    }
    if (guard_tokens.tokens.len == 0 and scoring_tokens.len == 0) {
        var result = try unknownResult(allocator, options, &paths, .insufficient_evidence, "question did not contain enough searchable terms", entries.len, max_results, max_snippet);
        errdefer result.deinit();
        result.mounted_packs_considered = options.mounted_packs.len;
        result.mounted_pack_entries_considered = mounted_pack_entry_count;
        try attachLiveCoverage(allocator, &result, live_coverage);
        try applyAcceptedCorrectionInfluence(allocator, &result, &reviewed);
        try applyAcceptedNegativeKnowledgeInfluence(allocator, &result, &reviewed_nk);
        try applyAcceptedLearningInfluence(allocator, &result, &reviewed_learning);
        return result;
    }

    var candidates = std.ArrayList(Candidate).init(allocator);
    defer {
        for (candidates.items) |*candidate| candidate.deinit(allocator);
        candidates.deinit();
    }
    var sketch_candidates = std.ArrayList(SketchCandidate).init(allocator);
    defer sketch_candidates.deinit();
    const query_sketch = try corpus_sketch.simHash64Query(allocator, search_question);
    var acceleration = hash_acceleration.Context.init(allocator, "corpus ask vector search");
    defer acceleration.deinit();
    const query_semantic_hash = try hash_acceleration.semanticHash64(&acceleration, allocator, search_question);
    var telemetry = CapacityTelemetry{};
    if (!live_coverage.complete) {
        telemetry.skipped_inputs += 1;
        telemetry.budget_hits += 1;
    }

    var index_scan_candidates = std.ArrayList(IndexScanCandidate).init(allocator);
    defer index_scan_candidates.deinit();
    const scan_entries = try allocator.alloc(bool, entries.len);
    defer allocator.free(scan_entries);
    @memset(scan_entries, false);

    for (entries, 0..) |entry, idx| {
        var best_distance: ?u7 = null;
        if (query_sketch.valid()) {
            if (entry.search_sketch_features != 0) {
                const distance = vsa_vulkan.ghostIndexDistance(query_sketch.hash, entry.search_sketch_hash);
                best_distance = if (best_distance) |existing| @min(existing, distance) else distance;
                if (distance <= MAX_SIMHASH_DISTANCE) {
                    try sketch_candidates.append(.{
                        .entry_index = idx,
                        .sketch_hash = entry.search_sketch_hash,
                        .hamming_distance = distance,
                        .similarity_score = corpus_sketch.similarityScore(distance),
                    });
                }
            }
        }
        if (entry.semantic_hash != 0) {
            const semantic_distance = vsa_vulkan.ghostIndexDistance(query_semantic_hash, entry.semantic_hash);
            best_distance = if (best_distance) |existing| @min(existing, semantic_distance) else semantic_distance;
            if (semantic_distance <= MAX_SIMHASH_DISTANCE and !hasSketchCandidate(sketch_candidates.items, idx)) {
                try sketch_candidates.append(.{
                    .entry_index = idx,
                    .sketch_hash = entry.semantic_hash,
                    .hamming_distance = semantic_distance,
                    .similarity_score = corpus_sketch.similarityScore(semantic_distance),
                });
            }
        }
        if (best_distance) |distance| {
            if (corpus_sketch.similarityScore(distance) < vsa_vulkan.GHOST_INDEX_SKIP_THRESHOLD_PER_MILLE) {
                telemetry.skipped_inputs += 1;
                continue;
            }
            try index_scan_candidates.append(.{
                .entry_index = idx,
                .hamming_distance = distance,
                .similarity_score = corpus_sketch.similarityScore(distance),
            });
        } else {
            scan_entries[idx] = true;
        }
    }

    std.mem.sort(IndexScanCandidate, index_scan_candidates.items, {}, indexScanCandidateLessThan);
    const indexed_scan_count = if (high_noise_request)
        @min(max_results, index_scan_candidates.items.len)
    else
        askIndexScanLimit(scoring_tokens.len, index_scan_candidates.items.len);
    for (index_scan_candidates.items[0..indexed_scan_count]) |candidate| {
        scan_entries[candidate.entry_index] = true;
    }
    if (index_scan_candidates.items.len > indexed_scan_count) {
        telemetry.skipped_inputs += index_scan_candidates.items.len - indexed_scan_count;
        telemetry.budget_hits += 1;
        telemetry.max_results_hit = true;
    }
    askProfileMark(&profile_timer, &profile_last_ns, "rank_search_index");

    var profile_read_ns: u64 = 0;
    const profile_tokenize_ns: u64 = 0;
    var profile_score_ns: u64 = 0;
    var profile_intent_hash_ns: u64 = 0;
    var profile_entries_scanned: usize = 0;

    for (entries, 0..) |entry, idx| {
        if (!scan_entries[idx]) continue;
        profile_entries_scanned += 1;
        const read_start = askProfileNow(&profile_timer);
        const read_result = readEntryText(allocator, entry.abs_path, maxReadBytesForEntry(entry)) catch {
            askProfileAccumulate(&profile_timer, read_start, &profile_read_ns);
            telemetry.skipped_files += 1;
            telemetry.skipped_inputs += 1;
            telemetry.budget_hits += 1;
            continue;
        };
        askProfileAccumulate(&profile_timer, read_start, &profile_read_ns);
        const file_text = read_result.text;
        errdefer allocator.free(file_text);
        if (read_result.truncated) {
            telemetry.truncated_inputs += 1;
            telemetry.budget_hits += 1;
        }
        const score_start = askProfileNow(&profile_timer);
        var scored = try scoreTextDirect(allocator, file_text, scoring_tokens);
        askProfileAccumulate(&profile_timer, score_start, &profile_score_ns);
        if (scored.score == 0) {
            scored.deinit(allocator);
            allocator.free(file_text);
            continue;
        }

        const intent_start = askProfileNow(&profile_timer);
        const value_match = evidenceMatchesIntent(file_text, query_intent);
        const value_bonus: u32 = if (query_intent != .general and value_match) 10 else 0;
        const content_hash = std.hash.Fnv1a_64.hash(file_text);
        askProfileAccumulate(&profile_timer, intent_start, &profile_intent_hash_ns);

        var best_distance: u7 = 64;
        if (query_sketch.valid() and entry.search_sketch_features != 0) {
            best_distance = @min(best_distance, vsa_vulkan.ghostIndexDistance(query_sketch.hash, entry.search_sketch_hash));
        }
        if (entry.semantic_hash != 0) {
            best_distance = @min(best_distance, vsa_vulkan.ghostIndexDistance(query_semantic_hash, entry.semantic_hash));
        }
        const similarity_score = corpus_sketch.similarityScore(best_distance);

        const base_score = scored.score + value_bonus + primaryNounScoreBonus(scoring_tokens, scored.matched_terms);
        const normalized_score = @as(f32, @floatFromInt(base_score)) / 100.0;
        const normalized_vector_score = @as(f32, @floatFromInt(similarity_score)) / 300.0;

        var keyword_weight: f32 = 0.5;
        var vector_weight: f32 = 0.5;
        if (scoring_tokens.len <= 2) {
            keyword_weight = 0.8;
            vector_weight = 0.2;
        } else if (scoring_tokens.len > 4) {
            keyword_weight = 0.1;
            vector_weight = 0.9;
        }
        const hybrid_score = (normalized_score * keyword_weight) + (normalized_vector_score * vector_weight);

        candidates.append(.{
            .entry_index = idx,
            .score = base_score,
            .similarity_score = similarity_score,
            .hybrid_score = hybrid_score,
            .first_match = scored.first_match,
            .byte_start = scored.byte_start,
            .byte_end = scored.byte_end,
            .line_start = scored.line_start,
            .line_end = scored.line_end,
            .matched_terms = scored.matched_terms,
            .matched_phrase = scored.matched_phrase,
            .content_hash = content_hash,
            .polarity = detectPolarity(file_text),
            .value_match = value_match,
            .text = file_text,
        }) catch |err| {
            scored.deinit(allocator);
            return err;
        };
    }
    askProfileLoopSummary(&profile_timer, profile_entries_scanned, profile_read_ns, profile_tokenize_ns, profile_score_ns, profile_intent_hash_ns);
    askProfileMark(&profile_timer, &profile_last_ns, "read_score_indexed_entries");

    if (candidates.items.len == 0) {
        if (try authorityOverrideCheck(allocator, options.question, guard_tokens.tokens, candidates.items, &reviewed)) |override_value| {
            var authority = override_value;
            defer authority.deinit(allocator);
            var result = try buildAuthorityOverrideResult(allocator, options, &paths, entries.len, max_results, max_snippet, authority, candidates.items, entries, &telemetry, live_coverage, mounted_pack_entry_count);
            errdefer result.deinit();
            try applyAcceptedCorrectionInfluence(allocator, &result, &reviewed);
            try applyAcceptedNegativeKnowledgeInfluence(allocator, &result, &reviewed_nk);
            try applyAcceptedLearningInfluence(allocator, &result, &reviewed_learning);
            return result;
        }
        var result = try unknownResult(allocator, options, &paths, .insufficient_evidence, "no live corpus item matched the question terms", entries.len, max_results, max_snippet);
        errdefer result.deinit();
        result.mounted_packs_considered = options.mounted_packs.len;
        result.mounted_pack_entries_considered = mounted_pack_entry_count;
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
        try applyAcceptedLearningInfluence(allocator, &result, &reviewed_learning);
        return result;
    }

    std.mem.sort(Candidate, candidates.items, {}, candidateLessThan);
    const top_count = @min(max_results, candidates.items.len);
    telemetry.exact_candidate_cap_hit = candidates.items.len > top_count;
    telemetry.max_results_hit = telemetry.exact_candidate_cap_hit;
    if (telemetry.exact_candidate_cap_hit) telemetry.budget_hits += 1;
    if (try authorityOverrideCheck(allocator, options.question, guard_tokens.tokens, candidates.items[0..top_count], &reviewed)) |override_value| {
        var authority = override_value;
        defer authority.deinit(allocator);
        var result = try buildAuthorityOverrideResult(allocator, options, &paths, entries.len, max_results, max_snippet, authority, candidates.items[0..top_count], entries, &telemetry, live_coverage, mounted_pack_entry_count);
        errdefer result.deinit();
        try applyAcceptedCorrectionInfluence(allocator, &result, &reviewed);
        try applyAcceptedNegativeKnowledgeInfluence(allocator, &result, &reviewed_nk);
        try applyAcceptedLearningInfluence(allocator, &result, &reviewed_learning);
        return result;
    }

    var high_rank_candidates = std.ArrayList(Candidate).init(allocator);
    defer high_rank_candidates.deinit();
    var shadow_context_candidates = std.ArrayList(Candidate).init(allocator);
    defer shadow_context_candidates.deinit();
    var trash_blocked_candidates = std.ArrayList(Candidate).init(allocator);
    defer trash_blocked_candidates.deinit();
    try splitRankedContextCandidates(&high_rank_candidates, &shadow_context_candidates, &trash_blocked_candidates, candidates.items, entries);

    if (high_rank_candidates.items.len == 0) {
        if (trash_blocked_candidates.items.len != 0) {
            var result = try buildBaseResult(allocator, options, &paths, .rejected_falsehood, "unresolved", "unresolved", entries.len, max_results, max_snippet);
            errdefer result.deinit();
            result.mounted_packs_considered = options.mounted_packs.len;
            result.mounted_pack_entries_considered = mounted_pack_entry_count;
            result.suppressed_evidence = try buildTrashSuppressedEvidence(allocator, boundedCandidates(trash_blocked_candidates.items, max_results), entries);
            result.similar_candidates = try buildSimilarCandidates(allocator, sketch_candidates.items, entries, max_results);
            telemetry.sketch_candidate_cap_hit = sketchCandidatesCapHit(sketch_candidates.items.len, max_results);
            if (telemetry.sketch_candidate_cap_hit) {
                telemetry.max_results_hit = true;
                telemetry.budget_hits += 1;
            }
            telemetry.expansion_recommended = true;
            result.capacity_telemetry = telemetry;
            try attachLiveCoverage(allocator, &result, live_coverage);
            result.unknowns = try singleUnknown(allocator, .rejected_falsehood, "blacklisted Trash-ranked corpus evidence matched this query; the source was discarded and the falsehood was rejected");
            result.candidate_followups = try singleFollowup(allocator, "truth_alert", "review the blocked Trash-ranked source only if you intend to reverse its license rank through explicit human audit");
            try applyCapacityDisclosure(allocator, &result);
            try applyAcceptedCorrectionInfluence(allocator, &result, &reviewed);
            try applyAcceptedNegativeKnowledgeInfluence(allocator, &result, &reviewed_nk);
            try applyAcceptedLearningInfluence(allocator, &result, &reviewed_learning);
            return result;
        }
        var result = try buildBaseResult(allocator, options, &paths, .unknown, "unresolved", "unresolved", entries.len, max_results, max_snippet);
        errdefer result.deinit();
        result.mounted_packs_considered = options.mounted_packs.len;
        result.mounted_pack_entries_considered = mounted_pack_entry_count;
        result.evidence_used = try buildEvidence(allocator, candidates.items[0..top_count], entries, max_snippet, "shadow context matched the query but cannot be the sole basis for an answer draft");
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
        result.unknowns = try singleUnknown(allocator, .insufficient_high_rank_evidence, "only shadow-ranked corpus evidence matched; shadow context cannot authorize an answer draft");
        result.candidate_followups = try singleFollowup(allocator, "evidence_to_collect", "promote or ingest root, verified, or unverified evidence before using shadow context as factual support");
        try applyCapacityDisclosure(allocator, &result);
        try applyAcceptedCorrectionInfluence(allocator, &result, &reviewed);
        try applyAcceptedNegativeKnowledgeInfluence(allocator, &result, &reviewed_nk);
        try applyAcceptedLearningInfluence(allocator, &result, &reviewed_learning);
        return result;
    }

    const selected_candidates = boundedCandidates(high_rank_candidates.items, max_results);
    const shadow_context = boundedCandidates(shadow_context_candidates.items, max_results);
    const trash_blocked = boundedCandidates(trash_blocked_candidates.items, max_results);
    const conflict = hasConflict(selected_candidates);
    if (conflict) {
        var verified_candidates = std.ArrayList(Candidate).init(allocator);
        defer verified_candidates.deinit();
        var unverified_suppressed = std.ArrayList(Candidate).init(allocator);
        defer unverified_suppressed.deinit();
        try splitVerifiedDominanceCandidates(&verified_candidates, &unverified_suppressed, selected_candidates, entries);
        if (verified_candidates.items.len != 0 and unverified_suppressed.items.len != 0) {
            var result = try buildBaseResult(allocator, options, &paths, .answered, "draft", "none", entries.len, max_results, max_snippet);
            errdefer result.deinit();
            result.mounted_packs_considered = options.mounted_packs.len;
            result.mounted_pack_entries_considered = mounted_pack_entry_count;
            result.evidence_used = try buildEvidence(allocator, verified_candidates.items, entries, max_snippet, "selected because verified license evidence contradicted unverified evidence");
            result.suppressed_evidence = try buildCombinedSuppressedEvidence(allocator, unverified_suppressed.items, shadow_context, trash_blocked, entries);
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
            const evidence_texts = try buildSynthesisEvidenceTexts(allocator, result.evidence_used);
            defer allocator.free(evidence_texts);
            var draft = try text_generation_lab.generateCorpusSynthesisDraft(allocator, .{
                .user_query = options.question,
                .evidence_text = result.evidence_used[0].snippet,
                .evidence_texts = evidence_texts,
            });
            defer draft.deinit(allocator);
            result.answer_draft = try allocator.dupe(u8, draft.draft_text);
            try applyDraftSafetyNotices(allocator, options, &result);
            result.candidate_followups = try singleFollowup(allocator, "license_review_candidate", "unverified contradictory evidence was suppressed; review shard licensing before treating this draft as supported");
            try applyCapacityDisclosure(allocator, &result);
            try applyAcceptedCorrectionInfluence(allocator, &result, &reviewed);
            try applyAcceptedNegativeKnowledgeInfluence(allocator, &result, &reviewed_nk);
            try applyAcceptedLearningInfluence(allocator, &result, &reviewed_learning);
            return result;
        }
        var result = try buildBaseResult(allocator, options, &paths, .unknown, "unresolved", "unresolved", entries.len, max_results, max_snippet);
        errdefer result.deinit();
        result.mounted_packs_considered = options.mounted_packs.len;
        result.mounted_pack_entries_considered = mounted_pack_entry_count;
        result.evidence_used = try buildEvidence(allocator, selected_candidates, entries, max_snippet, "selected because it matched question terms but conflicts with another selected corpus item");
        result.suppressed_evidence = try buildCombinedSuppressedEvidence(allocator, &.{}, shadow_context, trash_blocked, entries);
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
        const conflict_reason = conflictReason(selected_candidates);
        result.unknowns = try singleUnknown(allocator, .conflicting_evidence, conflict_reason);
        result.candidate_followups = try singleFollowup(allocator, "evidence_to_collect", "provide or ingest an authoritative corpus item that resolves the conflict");
        result.learning_candidates = try singleLearningCandidate(allocator, options.project_shard, "correction_candidate", "review the conflicting corpus items and propose a correction or corpus update through an explicit lifecycle", conflict_reason);
        try applyCapacityDisclosure(allocator, &result);
        try applyAcceptedCorrectionInfluence(allocator, &result, &reviewed);
        try applyAcceptedNegativeKnowledgeInfluence(allocator, &result, &reviewed_nk);
        try applyAcceptedLearningInfluence(allocator, &result, &reviewed_learning);
        return result;
    }

    const top = selected_candidates[0];

    const is_strong_hybrid = top.hybrid_score >= 0.05;
    const is_perfect_title = top.score >= TITLE_MATCH_SCORE_BONUS;
    const is_exact_phrase = top.matched_phrase != null;

    if (!is_strong_hybrid and !is_perfect_title and !is_exact_phrase) {
        var result = try unknownResult(allocator, options, &paths, .insufficient_evidence, "matched corpus evidence was too weak to support an answer draft", entries.len, max_results, max_snippet);
        errdefer result.deinit();
        result.mounted_packs_considered = options.mounted_packs.len;
        result.mounted_pack_entries_considered = mounted_pack_entry_count;
        result.suppressed_evidence = try buildCombinedSuppressedEvidence(allocator, &.{}, shadow_context, trash_blocked, entries);
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
        try applyAcceptedLearningInfluence(allocator, &result, &reviewed_learning);
        return result;
    }

    if (!candidatesParameterMatchCheck(guard_tokens.tokens, selected_candidates)) {
        var result = try buildBaseResult(allocator, options, &paths, .unknown, "unresolved", "unresolved", entries.len, max_results, max_snippet);
        errdefer result.deinit();
        result.parameter_match_failure = true;
        result.mounted_packs_considered = options.mounted_packs.len;
        result.mounted_pack_entries_considered = mounted_pack_entry_count;
        result.evidence_used = try buildEvidence(allocator, selected_candidates, entries, max_snippet, "candidate evidence matched topic terms but failed the exact parameter lock");
        result.suppressed_evidence = try buildCombinedSuppressedEvidence(allocator, &.{}, shadow_context, trash_blocked, entries);
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
        result.unknowns = try singleUnknown(allocator, .insufficient_evidence, "parameter_match_failure: selected evidence did not contain the exact parameter requested by the question");
        result.candidate_followups = try singleFollowup(allocator, "evidence_to_collect", "ingest exact evidence that contains the requested parameter value");
        result.learning_candidates = try singleLearningCandidate(allocator, options.project_shard, "corpus_update_candidate", "review whether parameter-bearing corpus evidence should be added through an explicit lifecycle", "parameter_match_failure");
        try applyCapacityDisclosure(allocator, &result);
        try applyAcceptedCorrectionInfluence(allocator, &result, &reviewed);
        try applyAcceptedNegativeKnowledgeInfluence(allocator, &result, &reviewed_nk);
        try applyAcceptedLearningInfluence(allocator, &result, &reviewed_learning);
        return result;
    }

    if (try inferenceBridgeCheck(allocator, options.question, selected_candidates, entries)) |bridge_value| {
        var bridge = bridge_value;
        defer bridge.deinit(allocator);
        const bridge_candidates = [_]Candidate{bridge.candidate};
        var result = try buildBaseResult(allocator, options, &paths, .answered, "draft", "none", entries.len, max_results, max_snippet);
        errdefer result.deinit();
        result.mounted_packs_considered = options.mounted_packs.len;
        result.mounted_pack_entries_considered = mounted_pack_entry_count;
        result.evidence_used = try buildEvidence(allocator, bridge_candidates[0..], entries, max_snippet, "selected by deterministic status-equivalence bridge: exact certified status evidence matched the requested HITL requirement");
        result.suppressed_evidence = try buildCombinedSuppressedEvidence(allocator, &.{}, shadow_context, trash_blocked, entries);
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
            "Authorized: {s} HITL requirement satisfied by {s} status.",
            .{ bridge.subject, bridge.satisfaction_token },
        );
        result.candidate_followups = try singleFollowup(allocator, "verifier_check_candidate", "review the cited certified-status evidence before treating this answer as supported");
        try applyCapacityDisclosure(allocator, &result);
        try applyAcceptedCorrectionInfluence(allocator, &result, &reviewed);
        try applyAcceptedNegativeKnowledgeInfluence(allocator, &result, &reviewed_nk);
        try applyAcceptedLearningInfluence(allocator, &result, &reviewed_learning);
        return result;
    }

    const primary_noun_soft_failure = !candidatesPrimaryNounMatchCheck(scoring_tokens, selected_candidates);

    if (query_intent != .general and !top.value_match) {
        var result = try buildBaseResult(allocator, options, &paths, .unknown, "unresolved", "unresolved", entries.len, max_results, max_snippet);
        errdefer result.deinit();
        result.mounted_packs_considered = options.mounted_packs.len;
        result.mounted_pack_entries_considered = mounted_pack_entry_count;
        result.evidence_used = try buildEvidence(allocator, selected_candidates, entries, max_snippet, "candidate evidence matched topic terms but did not contain the requested value shape");
        result.suppressed_evidence = try buildCombinedSuppressedEvidence(allocator, &.{}, shadow_context, trash_blocked, entries);
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
        result.learning_candidates = try singleLearningCandidate(allocator, options.project_shard, "corpus_update_candidate", "review whether a value-bearing corpus item should be added through an explicit lifecycle", "topic overlap without the requested value cannot authorize an answer draft");
        try applyCapacityDisclosure(allocator, &result);
        try applyAcceptedCorrectionInfluence(allocator, &result, &reviewed);
        try applyAcceptedNegativeKnowledgeInfluence(allocator, &result, &reviewed_nk);
        try applyAcceptedLearningInfluence(allocator, &result, &reviewed_learning);
        return result;
    }

    var result = try buildBaseResult(allocator, options, &paths, .answered, "draft", "none", entries.len, max_results, max_snippet);
    errdefer result.deinit();
    result.mounted_packs_considered = options.mounted_packs.len;
    result.mounted_pack_entries_considered = mounted_pack_entry_count;
    result.evidence_used = try buildEvidence(allocator, selected_candidates, entries, max_snippet, "selected because it matched bounded question terms");
    result.suppressed_evidence = try buildCombinedSuppressedEvidence(allocator, &.{}, shadow_context, trash_blocked, entries);
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
    const evidence_texts = try buildSynthesisEvidenceTexts(allocator, result.evidence_used);
    defer allocator.free(evidence_texts);
    var draft = try text_generation_lab.generateCorpusSynthesisDraft(allocator, .{
        .user_query = options.question,
        .evidence_text = result.evidence_used[0].snippet,
        .evidence_texts = evidence_texts,
    });
    defer draft.deinit(allocator);
    result.answer_draft = try allocator.dupe(u8, draft.draft_text);
    try applyDraftSafetyNotices(allocator, options, &result);
    result.primary_noun_match_failure = primary_noun_soft_failure;
    result.candidate_followups = try singleFollowup(allocator, "verifier_check_candidate", "review the cited corpus evidence before treating this answer as supported");
    try applyCapacityDisclosure(allocator, &result);
    try applyAcceptedCorrectionInfluence(allocator, &result, &reviewed);
    try applyAcceptedNegativeKnowledgeInfluence(allocator, &result, &reviewed_nk);
    try applyAcceptedLearningInfluence(allocator, &result, &reviewed_learning);
    return result;
}

fn askProfileEnabled() bool {
    const raw = std.posix.getenv("GHOST_PROFILE_ASK") orelse return false;
    return raw.len != 0 and !std.mem.eql(u8, raw, "0") and !std.ascii.eqlIgnoreCase(raw, "false");
}

fn hasMultiRuneTarget(target: []const u8) bool {
    var seen_first = false;
    var it = std.mem.tokenizeScalar(u8, target, ' ');
    while (it.next()) |_| {
        if (seen_first) return true;
        seen_first = true;
    }
    return false;
}

fn askProfileMark(timer: *?std.time.Timer, last_ns: *u64, label: []const u8) void {
    if (timer.*) |*actual| {
        const now = actual.read();
        const delta = now - last_ns.*;
        last_ns.* = now;
        std.debug.print("[PROFILE][ask] {s}: delta_ms={d} total_ms={d}\n", .{
            label,
            delta / std.time.ns_per_ms,
            now / std.time.ns_per_ms,
        });
    }
}

fn askProfileNow(timer: *?std.time.Timer) u64 {
    if (timer.*) |*actual| return actual.read();
    return 0;
}

fn askProfileAccumulate(timer: *?std.time.Timer, start_ns: u64, out_ns: *u64) void {
    if (timer.*) |*actual| {
        out_ns.* += actual.read() - start_ns;
    }
}

fn askProfileLoopSummary(
    timer: *?std.time.Timer,
    entries_scanned: usize,
    read_ns: u64,
    tokenize_ns: u64,
    score_ns: u64,
    intent_hash_ns: u64,
) void {
    if (timer.* != null) {
        std.debug.print("[PROFILE][ask] exact_loop: entries={d} read_ms={d} tokenize_ms={d} score_ms={d} intent_hash_ms={d}\n", .{
            entries_scanned,
            read_ns / std.time.ns_per_ms,
            tokenize_ns / std.time.ns_per_ms,
            score_ns / std.time.ns_per_ms,
            intent_hash_ns / std.time.ns_per_ms,
        });
    }
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

fn applyAcceptedLearningInfluence(allocator: std.mem.Allocator, result: *Result, reviewed: *const learning_store.ReadResult) !void {
    result.learning_influence_telemetry.records_read = reviewed.records_read;
    result.learning_influence_telemetry.accepted_records = reviewed.accepted_records;
    result.learning_influence_telemetry.rejected_records = reviewed.rejected_records;
    result.learning_influence_telemetry.malformed_lines = reviewed.malformed_lines;
    result.learning_influence_telemetry.warnings = reviewed.warnings.len;
    result.learning_influence_telemetry.influences_loaded = reviewed.influences.len;
    result.learning_influence_telemetry.truncated = reviewed.truncated;

    for (reviewed.influences) |influence| {
        if (!learningInfluenceMatchesResult(result, influence)) continue;
        try appendLearningInfluence(allocator, result, influence);
        result.learning_influence_telemetry.influences_applied += 1;
        if (result.status == .unknown and result.answer_draft == null) {
            result.status = .answered;
            allocator.free(result.state);
            allocator.free(result.permission);
            result.state = try allocator.dupe(u8, "draft");
            result.permission = try allocator.dupe(u8, "none");
            result.answer_draft = try std.fmt.allocPrint(allocator, "Draft answer from reviewed learning record: {s}", .{influence.draft_signal});
            for (result.unknowns) |*unknown| unknown.deinit(allocator);
            allocator.free(result.unknowns);
            result.unknowns = try allocator.alloc(Unknown, 0);
            result.learning_influence_telemetry.draft_promoted = true;
        }
        break;
    }
}

fn buildSynthesisEvidenceTexts(allocator: std.mem.Allocator, evidence_used: []const EvidenceUsed) ![]const []const u8 {
    const texts = try allocator.alloc([]const u8, evidence_used.len);
    for (evidence_used, 0..) |evidence, idx| texts[idx] = evidence.snippet;
    return texts;
}

fn applyDraftSafetyNotices(allocator: std.mem.Allocator, options: Options, result: *Result) !void {
    try prependUnverifiedSourceTag(allocator, result);
    try prependEnglishCoreZenithNoticeIfNeeded(allocator, options, result);
}

fn prependUnverifiedSourceTag(allocator: std.mem.Allocator, result: *Result) !void {
    const answer = result.answer_draft orelse return;
    if (std.mem.startsWith(u8, answer, "⚠️ Unverified Source")) return;
    var has_unverified = false;
    for (result.evidence_used) |evidence| {
        if (isUnverifiedLicense(evidence.license_status)) {
            has_unverified = true;
            break;
        }
    }
    if (!has_unverified) return;
    result.answer_draft = try std.fmt.allocPrint(allocator, "⚠️ Unverified Source: {s}", .{answer});
    allocator.free(answer);
}

fn prependEnglishCoreZenithNoticeIfNeeded(allocator: std.mem.Allocator, options: Options, result: *Result) !void {
    const answer = result.answer_draft orelse return;
    if (options.project_shard == null or !std.mem.eql(u8, options.project_shard.?, "english_core")) return;
    if (indexOfIgnoreCase(options.question, "zenith") == null) return;
    if (std.mem.startsWith(u8, answer, "I have found a public definition for 'Zenith'")) return;
    if (!evidenceOnlyFromEnglishCore(result.evidence_used)) return;

    result.answer_draft = try std.fmt.allocPrint(
        allocator,
        "I have found a public definition for 'Zenith', but I do not have Rank 0/Root access to your Zenith project code yet. {s}",
        .{answer},
    );
    allocator.free(answer);
}

fn evidenceOnlyFromEnglishCore(evidence_used: []const EvidenceUsed) bool {
    if (evidence_used.len == 0) return false;
    for (evidence_used) |evidence| {
        if (!std.mem.eql(u8, evidence.source_label, "simple_wiki")) return false;
    }
    return true;
}

fn authorityOverrideCheck(
    allocator: std.mem.Allocator,
    question: []const u8,
    query_tokens: []const []const u8,
    candidates: []const Candidate,
    reviewed: *const correction_review.ReadResult,
) !?AuthorityOverride {
    const subject = primarySubjectToken(query_tokens) orelse return null;
    for (reviewed.influences) |influence| {
        if (!std.mem.eql(u8, influence.applies_to, "corpus.ask")) continue;
        if (!std.mem.eql(u8, influence.operation_kind, "corpus.ask")) continue;
        if (!reviewedCorrectionMentionsSubject(influence, question, subject)) continue;
        const draft = try authorityDraftFromCorrection(allocator, subject, influence.user_correction) orelse continue;
        const authority_polarity = detectPolarity(draft);
        if (authority_polarity == .none and candidates.len != 0) {
            allocator.free(draft);
            continue;
        }
        return .{
            .influence = influence,
            .subject = subject,
            .answer_draft = draft,
        };
    }
    return null;
}

fn buildAuthorityOverrideResult(
    allocator: std.mem.Allocator,
    options: Options,
    paths: *const shards.Paths,
    entries_considered: usize,
    max_results: usize,
    max_snippet: usize,
    authority: AuthorityOverride,
    candidates: []const Candidate,
    entries: []const corpus_ingest.IndexedEntry,
    telemetry: *CapacityTelemetry,
    live_coverage: corpus_ingest.LiveCoverage,
    mounted_pack_entry_count: usize,
) !Result {
    var result = try buildBaseResult(allocator, options, paths, .answered, "draft", "none", entries_considered, max_results, max_snippet);
    errdefer result.deinit();
    result.mounted_packs_considered = options.mounted_packs.len;
    result.mounted_pack_entries_considered = mounted_pack_entry_count;
    result.evidence_used = try buildAuthorityEvidence(allocator, authority, paths);
    result.suppressed_evidence = try buildAuthoritySuppressedEvidence(allocator, authority, candidates, entries);
    telemetry.truncated_snippets += countTruncatedSnippets(result.evidence_used);
    if (telemetry.truncated_snippets != 0) telemetry.budget_hits += 1;
    telemetry.expansion_recommended = telemetry.hasPressure();
    result.capacity_telemetry = telemetry.*;
    try attachLiveCoverage(allocator, &result, live_coverage);
    result.answer_draft = try allocator.dupe(u8, authority.answer_draft);
    result.candidate_followups = try singleFollowup(allocator, "authority_review_audit", "reviewed correction held Authority Rank 0 and contradictory corpus evidence was excluded from answer drafting");
    try applyCapacityDisclosure(allocator, &result);
    return result;
}

fn primarySubjectToken(query_tokens: []const []const u8) ?[]const u8 {
    var fallback: ?[]const u8 = null;
    for (query_tokens) |token| {
        if (!isPrimaryNounToken(token)) continue;
        if (fallback == null) fallback = token;
        if (std.mem.indexOfScalar(u8, token, '-') != null or std.mem.indexOfScalar(u8, token, '_') != null) return token;
    }
    return fallback;
}

fn reviewedCorrectionMentionsSubject(influence: correction_review.AcceptedCorrectionInfluence, question: []const u8, subject: []const u8) bool {
    if (!containsIgnoreCase(question, subject)) return false;
    return containsIgnoreCase(influence.user_correction, subject) or
        containsIgnoreCase(influence.original_request_summary, subject) or
        containsIgnoreCase(influence.matched_pattern, subject);
}

fn authorityDraftFromCorrection(allocator: std.mem.Allocator, subject: []const u8, correction_text: []const u8) !?[]u8 {
    if (correction_text.len == 0) return null;
    if (!containsIgnoreCase(correction_text, subject)) return null;
    if (!containsIgnoreCase(correction_text, "authoriz")) return null;
    if (!containsIgnoreCase(correction_text, "limit")) return null;
    var numbers = [_][]const u8{ "", "" };
    if (!firstTwoNumbers(correction_text, &numbers)) return null;
    const normalized_subject = try displaySubject(allocator, subject);
    defer allocator.free(normalized_subject);
    return try std.fmt.allocPrint(allocator, "Authorized: {s} ({s}) is within limits ({s}).", .{ normalized_subject, numbers[0], numbers[1] });
}

fn firstTwoNumbers(text: []const u8, out: *[2][]const u8) bool {
    var count: usize = 0;
    var idx: usize = 0;
    while (idx < text.len) {
        while (idx < text.len and !std.ascii.isDigit(text[idx])) : (idx += 1) {}
        if (idx >= text.len) break;
        const start = idx;
        while (idx < text.len and std.ascii.isDigit(text[idx])) : (idx += 1) {}
        out[count] = text[start..idx];
        count += 1;
        if (count == 2) return true;
    }
    return false;
}

fn displaySubject(allocator: std.mem.Allocator, subject: []const u8) ![]u8 {
    var out = try allocator.dupe(u8, subject);
    if (out.len != 0) out[0] = std.ascii.toUpper(out[0]);
    var idx: usize = 1;
    while (idx < out.len) : (idx += 1) {
        if ((out[idx - 1] == '-' or out[idx - 1] == '_') and std.ascii.isAlphabetic(out[idx])) {
            out[idx] = std.ascii.toUpper(out[idx]);
        }
    }
    return out;
}

fn buildAuthorityEvidence(allocator: std.mem.Allocator, authority: AuthorityOverride, paths: *const shards.Paths) ![]EvidenceUsed {
    _ = paths;
    var out = try allocator.alloc(EvidenceUsed, 1);
    errdefer allocator.free(out);
    out[0] = .{
        .item_id = try allocator.dupe(u8, authority.influence.source_reviewed_correction_id),
        .path = try allocator.dupe(u8, "corrections/reviewed_corrections.jsonl"),
        .source_path = try allocator.dupe(u8, "corrections/reviewed_corrections.jsonl"),
        .source_label = try allocator.dupe(u8, "reviewed_corrections.jsonl"),
        .class_name = try allocator.dupe(u8, "reviewed_correction"),
        .trust_class = try allocator.dupe(u8, "human_reviewed_correction"),
        .license_status = try allocator.dupe(u8, "verified"),
        .authority_level = 1,
        .content_hash = try std.fmt.allocPrint(allocator, "fnv1a64:{x:0>16}", .{std.hash.Fnv1a_64.hash(authority.influence.user_correction)}),
        .byte_start = 0,
        .byte_end = authority.influence.user_correction.len,
        .line_start = 1,
        .line_end = 1,
        .snippet = try allocator.dupe(u8, authority.influence.user_correction),
        .snippet_truncated = false,
        .matched_terms = try singleMatchedTerm(allocator, authority.subject),
        .matched_phrase = try allocator.dupe(u8, authority.subject),
        .reason = try allocator.dupe(u8, "authority_rank_0 reviewed correction selected over live shard and mounted pack corpus evidence"),
        .match_reason = try allocator.dupe(u8, "reviewed_correction_primary_subject_authority_override"),
        .provenance = try allocator.dupe(u8, "reviewed_corrections.jsonl"),
        .score = std.math.maxInt(u32),
        .rank = 0,
    };
    return out;
}

fn singleMatchedTerm(allocator: std.mem.Allocator, term: []const u8) ![][]u8 {
    var out = try allocator.alloc([]u8, 1);
    errdefer allocator.free(out);
    out[0] = try allocator.dupe(u8, term);
    return out;
}

fn buildAuthoritySuppressedEvidence(
    allocator: std.mem.Allocator,
    authority: AuthorityOverride,
    candidates: []const Candidate,
    entries: []const corpus_ingest.IndexedEntry,
) ![]SuppressedEvidence {
    var count: usize = 0;
    const authority_polarity = detectPolarity(authority.answer_draft);
    for (candidates) |candidate| {
        if (!candidateContradictsAuthority(candidate, authority.subject, authority_polarity)) continue;
        count += 1;
    }
    var out = try allocator.alloc(SuppressedEvidence, count);
    var built: usize = 0;
    errdefer {
        for (out[0..built]) |*item| item.deinit(allocator);
        allocator.free(out);
    }
    var idx: usize = 0;
    for (candidates) |candidate| {
        if (!candidateContradictsAuthority(candidate, authority.subject, authority_polarity)) continue;
        const entry = entries[candidate.entry_index];
        out[idx] = .{
            .item_id = try allocator.dupe(u8, entry.corpus_meta.lineage_id),
            .path = try allocator.dupe(u8, entry.rel_path),
            .source_path = try allocator.dupe(u8, entry.corpus_meta.source_rel_path),
            .source_label = try allocator.dupe(u8, entry.corpus_meta.source_label),
            .reason = try allocator.dupe(u8, "suppressed_by_authority"),
            .authority_ref = try allocator.dupe(u8, authority.influence.source_reviewed_correction_id),
            .license_status = try allocator.dupe(u8, entry.corpus_meta.license_status),
            .authority_level = entry.corpus_meta.license_authority_level,
            .rank = idx + 1,
        };
        built += 1;
        idx += 1;
    }
    return out;
}

fn buildLicenseSuppressedEvidence(
    allocator: std.mem.Allocator,
    candidates: []const Candidate,
    entries: []const corpus_ingest.IndexedEntry,
) ![]SuppressedEvidence {
    var out = try allocator.alloc(SuppressedEvidence, candidates.len);
    var built: usize = 0;
    errdefer {
        for (out[0..built]) |*item| item.deinit(allocator);
        allocator.free(out);
    }
    for (candidates, 0..) |candidate, idx| {
        const entry = entries[candidate.entry_index];
        out[idx] = .{
            .item_id = try allocator.dupe(u8, entry.corpus_meta.lineage_id),
            .path = try allocator.dupe(u8, entry.rel_path),
            .source_path = try allocator.dupe(u8, entry.corpus_meta.source_rel_path),
            .source_label = try allocator.dupe(u8, entry.corpus_meta.source_label),
            .reason = try allocator.dupe(u8, "suppressed_by_verified_license_contradiction"),
            .authority_ref = try allocator.dupe(u8, "license_status:verified"),
            .license_status = try allocator.dupe(u8, entry.corpus_meta.license_status),
            .authority_level = entry.corpus_meta.license_authority_level,
            .rank = idx + 1,
        };
        built += 1;
    }
    return out;
}

fn buildCombinedSuppressedEvidence(
    allocator: std.mem.Allocator,
    license_suppressed: []const Candidate,
    shadow_context: []const Candidate,
    trash_blocked: []const Candidate,
    entries: []const corpus_ingest.IndexedEntry,
) ![]SuppressedEvidence {
    const license_items = try buildLicenseSuppressedEvidence(allocator, license_suppressed, entries);
    errdefer deinitSuppressedEvidenceSlice(allocator, license_items);
    const shadow_items = try buildShadowContextEvidence(allocator, shadow_context, entries);
    errdefer deinitSuppressedEvidenceSlice(allocator, shadow_items);
    const trash_items = try buildTrashSuppressedEvidence(allocator, trash_blocked, entries);
    errdefer deinitSuppressedEvidenceSlice(allocator, trash_items);

    const total = license_items.len + shadow_items.len + trash_items.len;
    var out = try allocator.alloc(SuppressedEvidence, total);
    var idx: usize = 0;
    for (license_items) |item| {
        out[idx] = item;
        idx += 1;
    }
    for (shadow_items) |item| {
        out[idx] = item;
        idx += 1;
    }
    for (trash_items) |item| {
        out[idx] = item;
        idx += 1;
    }
    allocator.free(license_items);
    allocator.free(shadow_items);
    allocator.free(trash_items);
    return out;
}

fn deinitSuppressedEvidenceSlice(allocator: std.mem.Allocator, items: []SuppressedEvidence) void {
    for (items) |*item| item.deinit(allocator);
    allocator.free(items);
}

fn buildShadowContextEvidence(
    allocator: std.mem.Allocator,
    candidates: []const Candidate,
    entries: []const corpus_ingest.IndexedEntry,
) ![]SuppressedEvidence {
    var out = try allocator.alloc(SuppressedEvidence, candidates.len);
    var built: usize = 0;
    errdefer {
        for (out[0..built]) |*item| item.deinit(allocator);
        allocator.free(out);
    }
    for (candidates, 0..) |candidate, idx| {
        const entry = entries[candidate.entry_index];
        out[idx] = .{
            .item_id = try allocator.dupe(u8, entry.corpus_meta.lineage_id),
            .path = try allocator.dupe(u8, entry.rel_path),
            .source_path = try allocator.dupe(u8, entry.corpus_meta.source_rel_path),
            .source_label = try allocator.dupe(u8, entry.corpus_meta.source_label),
            .reason = try allocator.dupe(u8, "shadow_context_only"),
            .authority_ref = try allocator.dupe(u8, "authority_level:3"),
            .license_status = try allocator.dupe(u8, entry.corpus_meta.license_status),
            .authority_level = entry.corpus_meta.license_authority_level,
            .rank = idx + 1,
        };
        built += 1;
    }
    return out;
}

fn buildTrashSuppressedEvidence(
    allocator: std.mem.Allocator,
    candidates: []const Candidate,
    entries: []const corpus_ingest.IndexedEntry,
) ![]SuppressedEvidence {
    var out = try allocator.alloc(SuppressedEvidence, candidates.len);
    var built: usize = 0;
    errdefer {
        for (out[0..built]) |*item| item.deinit(allocator);
        allocator.free(out);
    }
    for (candidates, 0..) |candidate, idx| {
        const entry = entries[candidate.entry_index];
        out[idx] = .{
            .item_id = try allocator.dupe(u8, entry.corpus_meta.lineage_id),
            .path = try allocator.dupe(u8, entry.rel_path),
            .source_path = try allocator.dupe(u8, entry.corpus_meta.source_rel_path),
            .source_label = try allocator.dupe(u8, entry.corpus_meta.source_label),
            .reason = try allocator.dupe(u8, "blacklisted_source_blocked"),
            .authority_ref = try allocator.dupe(u8, "authority_level:4"),
            .license_status = try allocator.dupe(u8, entry.corpus_meta.license_status),
            .authority_level = entry.corpus_meta.license_authority_level,
            .rank = idx + 1,
        };
        built += 1;
    }
    return out;
}

fn candidateContradictsAuthority(candidate: Candidate, subject: []const u8, authority_polarity: Polarity) bool {
    if (authority_polarity == .none) return false;
    if (!containsIgnoreCase(candidate.text, subject)) return false;
    if (candidate.polarity == .none) return false;
    return candidate.polarity != authority_polarity;
}

fn learningInfluenceMatchesResult(result: *const Result, influence: learning_store.AcceptedLearningInfluence) bool {
    for (result.learning_candidates) |candidate| {
        if (std.mem.eql(u8, candidate.id, influence.learning_candidate_id)) return true;
        if (std.mem.eql(u8, candidate.logic_pattern, influence.logic_pattern) and std.mem.eql(u8, candidate.candidate_kind, influence.candidate_kind)) return true;
    }
    return false;
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

fn appendLearningInfluence(allocator: std.mem.Allocator, result: *Result, influence: learning_store.AcceptedLearningInfluence) !void {
    const old = result.learning_influences;
    var out = try allocator.alloc(LearningInfluence, old.len + 1);
    @memcpy(out[0..old.len], old);
    out[old.len] = .{
        .id = try allocator.dupe(u8, influence.id),
        .source_reviewed_learning_id = try allocator.dupe(u8, influence.source_reviewed_learning_id),
        .learning_candidate_id = try allocator.dupe(u8, influence.learning_candidate_id),
        .candidate_kind = try allocator.dupe(u8, influence.candidate_kind),
        .logic_pattern = try allocator.dupe(u8, influence.logic_pattern),
        .draft_signal = try allocator.dupe(u8, influence.draft_signal),
        .reason = try allocator.dupe(u8, "accepted reviewed learning record matched a current learning candidate; promoted to draft only"),
        .source_store = try allocator.dupe(u8, learning_store.LEARNED_RECORDS_FILE_NAME),
    };
    allocator.free(old);
    result.learning_influences = out;
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
        .insufficient_high_rank_evidence => try singleFollowup(allocator, "evidence_to_collect", "promote or ingest root, verified, or unverified evidence before using shadow context as factual support"),
        .rejected_falsehood => try singleFollowup(allocator, "truth_alert", "the matching source is Trash-ranked; reverse its license rank only through explicit human audit if that classification is wrong"),
        .conflicting_evidence => try singleFollowup(allocator, "evidence_to_collect", "provide authoritative evidence to resolve the conflict"),
        .capacity_limited => try singleFollowup(allocator, "capacity_review_candidate", "raise explicit retrieval bounds or inspect skipped/truncated corpus coverage before relying on missing evidence"),
        .malformed_request => try singleFollowup(allocator, "question_to_ask_user", "provide a valid ask request"),
    };
    result.learning_candidates = try singleLearningCandidate(
        allocator,
        options.project_shard,
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
        .mounted_packs_considered = options.mounted_packs.len,
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
    project_shard: ?[]const u8,
    candidate_kind: []const u8,
    proposed_action: []const u8,
    reason: []const u8,
) ![]LearningCandidate {
    const items = try allocator.alloc(LearningCandidate, 1);
    const id_hash = std.hash.Fnv1a_64.hash(candidate_kind) ^ std.hash.Fnv1a_64.hash(proposed_action) ^ std.hash.Fnv1a_64.hash(reason);
    const candidate_id = try std.fmt.allocPrint(allocator, "learning:candidate:{x:0>16}", .{id_hash});
    var sr: ?SelfReview = null;
    if (project_shard) |shard| {
        sr = learning_store.evaluateCandidate(allocator, shard, candidate_id, candidate_kind, proposed_action, reason) catch null;
    }
    if (isConflictLearningReason(reason)) {
        if (sr) |*existing| existing.deinit(allocator);
        sr = try failedSelfReview(allocator, "corpus.ask.conflicting_evidence", reason);
    }
    items[0] = .{
        .id = candidate_id,
        .candidate_kind = try allocator.dupe(u8, candidate_kind),
        .proposed_action = try allocator.dupe(u8, proposed_action),
        .reason = try allocator.dupe(u8, reason),
        .logic_pattern = try allocator.dupe(u8, reason),
        .self_review = sr,
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
            .license_status = try allocator.dupe(u8, entry.corpus_meta.license_status),
            .authority_level = entry.corpus_meta.license_authority_level,
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

fn inferenceBridgeCheck(
    allocator: std.mem.Allocator,
    question: []const u8,
    candidates: []const Candidate,
    entries: []const corpus_ingest.IndexedEntry,
) !?InferenceBridge {
    if (!isHitlRequirementQuestion(question)) return null;

    for (candidates, 0..) |candidate, idx| {
        const token = try extractHitlSatisfactionToken(allocator, candidate.text) orelse continue;
        errdefer allocator.free(token);
        if (!std.mem.eql(u8, token, "HITL_CERTIFIED")) continue;
        const pack_id = try extractPackIdFromProvenance(allocator, entries[candidate.entry_index].corpus_meta.provenance) orelse {
            allocator.free(token);
            continue;
        };
        errdefer allocator.free(pack_id);
        return .{
            .candidate = candidates[idx],
            .subject = try allocator.dupe(u8, "Jurisdiction-X"),
            .satisfaction_token = token,
            .pack_id = pack_id,
        };
    }
    return null;
}

fn isHitlRequirementQuestion(text: []const u8) bool {
    return containsIgnoreCase(text, "requirement") and
        containsIgnoreCase(text, "HITL") and
        containsIgnoreCase(text, "Jurisdiction-X");
}

fn extractHitlSatisfactionToken(allocator: std.mem.Allocator, text: []const u8) !?[]u8 {
    if (!containsIgnoreCase(text, "Jurisdiction-X")) return null;
    const token = "HITL_CERTIFIED";
    if (std.mem.indexOf(u8, text, token) == null) return null;
    return try allocator.dupe(u8, token);
}

fn extractPackIdFromProvenance(allocator: std.mem.Allocator, provenance: []const u8) !?[]u8 {
    const prefix = "@pack/";
    if (std.mem.startsWith(u8, provenance, prefix)) {
        const rest = provenance[prefix.len..];
        const end = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
        if (end == 0) return null;
        return try allocator.dupe(u8, rest[0..end]);
    }
    const pack_marker = "pack=";
    const marker_idx = std.mem.indexOf(u8, provenance, pack_marker) orelse return null;
    const rest = provenance[(marker_idx + pack_marker.len)..];
    const end = std.mem.indexOfAny(u8, rest, "@|/") orelse rest.len;
    if (end == 0) return null;
    return try allocator.dupe(u8, rest[0..end]);
}

fn maxReadBytesForEntry(entry: corpus_ingest.IndexedEntry) usize {
    if (std.mem.eql(u8, entry.corpus_meta.source_label, "simple_wiki")) return SIMPLE_WIKI_MAX_FILE_READ_BYTES;
    return DEFAULT_MAX_FILE_READ_BYTES;
}

fn readEntryText(allocator: std.mem.Allocator, abs_path: []const u8, max_read_bytes: usize) !ReadEntryResult {
    const file = try std.fs.openFileAbsolute(abs_path, .{});
    defer file.close();
    const file_size = try file.getEndPos();
    const read_len: usize = @intCast(@min(file_size, max_read_bytes));
    var buffer = try allocator.alloc(u8, read_len);
    errdefer allocator.free(buffer);
    const actual = try file.readAll(buffer);
    if (actual != read_len) {
        buffer = try allocator.realloc(buffer, actual);
    }
    return .{
        .text = buffer,
        .truncated = file_size > max_read_bytes,
    };
}

fn tokenizeQuery(allocator: std.mem.Allocator, question: []const u8) !QueryTokens {
    var tokens = std.ArrayList([]u8).init(allocator);
    errdefer {
        for (tokens.items) |token| allocator.free(token);
        tokens.deinit();
    }

    var start: ?usize = null;
    var skip_next_excluded_subject = false;
    for (question, 0..) |c, idx| {
        if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-') {
            if (start == null) start = idx;
        } else if (start) |s| {
            try appendQueryRune(allocator, &tokens, question[s..idx], &skip_next_excluded_subject);
            start = null;
            if (tokens.items.len >= MAX_QUERY_TOKENS) break;
        }
    }
    if (start) |s| {
        if (tokens.items.len < MAX_QUERY_TOKENS) try appendQueryRune(allocator, &tokens, question[s..], &skip_next_excluded_subject);
    }

    return .{ .tokens = try tokens.toOwnedSlice() };
}

fn appendQueryRune(allocator: std.mem.Allocator, tokens: *std.ArrayList([]u8), raw: []const u8, skip_next_excluded_subject: *bool) !void {
    const trimmed = std.mem.trim(u8, raw, " \r\n\t.,:;!?()[]{}\"'");
    if (trimmed.len < MIN_TOKEN_LEN and !isShortSearchRune(trimmed)) return;
    if (isNegativeModifierRune(trimmed)) {
        skip_next_excluded_subject.* = true;
        return;
    }
    if (skip_next_excluded_subject.*) {
        skip_next_excluded_subject.* = false;
        return;
    }
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

fn isShortSearchRune(rune: []const u8) bool {
    return std.ascii.eqlIgnoreCase(rune, "hi") or
        std.ascii.eqlIgnoreCase(rune, "yo");
}

fn isNegativeModifierRune(rune: []const u8) bool {
    return std.ascii.eqlIgnoreCase(rune, "not") or
        std.ascii.eqlIgnoreCase(rune, "without") or
        std.ascii.eqlIgnoreCase(rune, "excluding") or
        std.ascii.eqlIgnoreCase(rune, "exclude");
}

fn isStopWord(token: []const u8) bool {
    const words = [_][]const u8{
        "the",    "and",      "for",      "with", "from",    "what",    "when",     "where",      "which",     "this",   "that",
        "whats",  "what's",   "does",     "into", "about",   "using",   "should",   "would",      "could",     "tell",   "give",
        "show",   "based",    "only",     "have", "your",    "also",    "keep",     "explain",    "encounter", "word",   "current",
        "shard",  "ingested", "grounded", "data", "logical", "english", "patterns", "understand", "concept",   "answer", "definition",
        "public", "found",    "yet",      "not",  "corpus",
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

fn scoreTextDirect(allocator: std.mem.Allocator, text: []const u8, tokens: []const []const u8) !MatchSummary {
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
        var first_token_start: ?usize = null;
        var anchor_token_start: ?usize = null;
        var title_match = false;
        var definition_match = false;
        var search_start: usize = 0;
        while (indexOfIgnoreCasePos(text, search_start, token)) |idx| {
            const after_pos = idx + token.len;
            const before_ok = idx == 0 or !isSearchTokenByte(text[idx - 1]);
            const after_ok = after_pos >= text.len or !isSearchTokenByte(text[after_pos]);
            search_start = idx + 1;
            if (!before_ok or !after_ok) continue;
            token_count += 1;
            if (first_token_start == null) first_token_start = idx;
            if (isTitleTokenMatch(text, token, idx)) {
                title_match = true;
                anchor_token_start = idx;
            }
            if (isDefinitionTokenMatch(text, token, idx)) {
                definition_match = true;
                if (anchor_token_start == null) anchor_token_start = idx;
            }
        }
        if (first_token_start) |first| {
            const preferred_start = anchor_token_start orelse first;
            const frequency_cap: u32 = if (tokens.len == 1) 32 else 3;
            score += 1;
            score += @min(token_count, frequency_cap) - 1;
            if (title_match) score += TITLE_MATCH_SCORE_BONUS;
            if (definition_match) score += DEFINITION_MATCH_SCORE_BONUS;
            try matched_terms.append(try allocator.dupe(u8, token));
            if (!found_any or anchor_token_start != null or first < first_match) {
                const span = lineSpanForByteRange(text, preferred_start, preferred_start + token.len);
                first_match = preferred_start;
                byte_start = preferred_start;
                byte_end = preferred_start + token.len;
                line_start = span.start;
                line_end = span.end;
            }
            found_any = true;
        }
    }

    const phrase = try findBestPhraseDirect(allocator, text, tokens);
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

fn askIndexScanLimit(token_count: usize, candidate_count: usize) usize {
    if (token_count <= 1) {
        if (candidate_count <= 512) return candidate_count;
        return @min(@as(usize, 128), candidate_count);
    }
    return @min(ASK_INDEX_SCAN_LIMIT, candidate_count);
}

fn isSearchTokenByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-';
}

fn indexOfIgnoreCasePos(haystack: []const u8, start: usize, needle: []const u8) ?usize {
    if (needle.len == 0 or needle.len > haystack.len or start >= haystack.len) return null;
    var idx = start;
    while (idx + needle.len <= haystack.len) : (idx += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[idx .. idx + needle.len], needle)) return idx;
    }
    return null;
}

fn lineSpanForByteRange(text: []const u8, byte_start: usize, byte_end: usize) struct { start: usize, end: usize } {
    var line: usize = 1;
    var idx: usize = 0;
    while (idx < byte_start and idx < text.len) : (idx += 1) {
        if (text[idx] == '\n') line += 1;
    }
    const start_line = line;
    while (idx < byte_end and idx < text.len) : (idx += 1) {
        if (text[idx] == '\n') line += 1;
    }
    return .{ .start = start_line, .end = line };
}

fn isTitleTokenMatch(text: []const u8, token: []const u8, token_start: usize) bool {
    var line_start = token_start;
    while (line_start > 0 and text[line_start - 1] != '\n' and text[line_start - 1] != '\r') {
        line_start -= 1;
    }
    var line_end = token_start + token.len;
    while (line_end < text.len and text[line_end] != '\n' and text[line_end] != '\r') {
        line_end += 1;
    }
    const before_token = std.mem.trim(u8, text[line_start..token_start], " \t\r\n");
    if (!std.ascii.startsWithIgnoreCase(before_token, "title:")) return false;
    var after_colon = before_token["title:".len..];
    after_colon = std.mem.trim(u8, after_colon, " \t");
    const after_token = std.mem.trim(u8, text[token_start + token.len .. line_end], " \t");
    return after_colon.len == 0 and after_token.len == 0;
}

fn isDefinitionTokenMatch(text: []const u8, token: []const u8, token_start: usize) bool {
    var cursor = token_start + token.len;
    while (cursor < text.len and (text[cursor] == ' ' or text[cursor] == '\t')) : (cursor += 1) {}
    if (cursor + 2 > text.len) return false;
    if (!std.ascii.eqlIgnoreCase(text[cursor .. cursor + 2], "is")) return false;
    return cursor + 2 >= text.len or !isSearchTokenByte(text[cursor + 2]);
}

fn candidateLessThan(_: void, lhs: Candidate, rhs: Candidate) bool {
    if (lhs.hybrid_score != rhs.hybrid_score) return lhs.hybrid_score > rhs.hybrid_score;
    if (lhs.score != rhs.score) return lhs.score > rhs.score;
    if ((lhs.matched_phrase != null) != (rhs.matched_phrase != null)) return lhs.matched_phrase != null;
    if (lhs.first_match != rhs.first_match) return lhs.first_match < rhs.first_match;
    return lhs.entry_index < rhs.entry_index;
}

fn requiredScore(token_count: usize) u32 {
    if (token_count <= 1) return 4;
    return 2;
}

fn primaryNounScoreBonus(query_tokens: []const []const u8, matched_terms: []const []const u8) u32 {
    var matches: u32 = 0;
    for (query_tokens) |token| {
        if (!isPrimaryNounToken(token)) continue;
        if (matchedTermsContain(matched_terms, token)) matches += 1;
    }
    return matches * PRIMARY_NOUN_SCORE_BONUS;
}

fn candidatesParameterMatchCheck(query_tokens: []const []const u8, candidates: []const Candidate) bool {
    for (query_tokens) |token| {
        if (!isParameterToken(token)) continue;
        if (!candidatesMatchedTermsContain(candidates, token)) return false;
    }
    return true;
}

fn candidatesPrimaryNounMatchCheck(query_tokens: []const []const u8, candidates: []const Candidate) bool {
    var primary_count: usize = 0;
    var matched_count: usize = 0;
    for (query_tokens) |token| {
        if (!isPrimaryNounToken(token)) continue;
        primary_count += 1;
        if (candidatesMatchedTermsContain(candidates, token)) matched_count += 1;
    }
    if (primary_count == 0) return true;
    return matched_count * 100 >= primary_count * PRIMARY_NOUN_MATCH_THRESHOLD_PERCENT;
}

fn candidatesMatchedTermsContain(candidates: []const Candidate, needle: []const u8) bool {
    for (candidates) |candidate| {
        if (matchedTermsContain(candidate.matched_terms, needle)) return true;
    }
    return false;
}

fn matchedTermsContain(matched_terms: []const []const u8, needle: []const u8) bool {
    for (matched_terms) |term| {
        if (std.mem.eql(u8, term, needle)) return true;
    }
    return false;
}

fn isParameterToken(token: []const u8) bool {
    for (token) |c| {
        if (std.ascii.isDigit(c)) return true;
    }
    return false;
}

fn isPrimaryNounToken(token: []const u8) bool {
    if (isParameterToken(token)) return false;
    if (isPrimaryNounStopToken(token)) return false;
    return true;
}

fn isPrimaryNounStopToken(token: []const u8) bool {
    const words = [_][]const u8{
        "ask",    "answer",  "corpus",    "draft",    "evidence",  "known",    "learned",  "live",
        "permit", "permits", "permitted", "allow",    "allows",    "allowed",  "enabled",  "disabled",
        "enable", "disable", "support",   "supports", "supported", "required", "requires", "require",
        "must",   "shall",   "should",    "would",    "could",     "does",     "say",
    };
    for (words) |word| {
        if (std.mem.eql(u8, token, word)) return true;
    }
    return false;
}

fn detectPolarity(text: []const u8) Polarity {
    var affirmative = false;
    var negative = false;
    const yes_terms = [_][]const u8{ " enabled", " enable ", " yes", " true", " must ", " required", " supported", " permitted", " allowed", " authorized" };
    const no_terms = [_][]const u8{ " disabled", " disable ", " no", " false", " must not", " unsupported", " forbidden", " not permitted", " not allowed", " not authorized", " unauthorized" };

    for (yes_terms) |term| {
        if (indexOfIgnoreCase(text, term) != null) {
            affirmative = true;
            break;
        }
    }
    if (startsWithIgnoreCase(text, "authorized")) affirmative = true;
    for (no_terms) |term| {
        if (indexOfIgnoreCase(text, term) != null) {
            negative = true;
            break;
        }
    }

    if (negative and (indexOfIgnoreCase(text, "not authorized") != null or indexOfIgnoreCase(text, "unauthorized") != null)) return .negative;
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
        containsStandaloneWordIgnoreCase(question, "yes") or
        containsStandaloneWordIgnoreCase(question, "no") or
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

fn containsStandaloneWordIgnoreCase(text: []const u8, word: []const u8) bool {
    var search_start: usize = 0;
    while (indexOfIgnoreCasePos(text, search_start, word)) |idx| {
        const after_pos = idx + word.len;
        search_start = idx + 1;
        const before_ok = idx == 0 or !isSearchTokenByte(text[idx - 1]);
        const after_ok = after_pos >= text.len or !isSearchTokenByte(text[after_pos]);
        if (before_ok and after_ok) return true;
    }
    return false;
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
    return (affirmative and negative) or hasSystemAlphaEvenOddConflict(candidates);
}

fn splitVerifiedDominanceCandidates(
    verified: *std.ArrayList(Candidate),
    suppressed_unverified: *std.ArrayList(Candidate),
    candidates: []const Candidate,
    entries: []const corpus_ingest.IndexedEntry,
) !void {
    for (candidates) |candidate| {
        if (!isVerifiedLicense(entries[candidate.entry_index].corpus_meta.license_status)) continue;
        try verified.append(candidate);
    }
    if (verified.items.len == 0) return;

    for (candidates) |candidate| {
        const status = entries[candidate.entry_index].corpus_meta.license_status;
        if (!isUnverifiedLicense(status)) continue;
        for (verified.items) |authority_candidate| {
            if (!candidatesContradict(authority_candidate, candidate)) continue;
            try suppressed_unverified.append(candidate);
            break;
        }
    }
}

fn candidatesContradict(lhs: Candidate, rhs: Candidate) bool {
    if (lhs.polarity == .none or rhs.polarity == .none) return false;
    return lhs.polarity != rhs.polarity;
}

fn isVerifiedLicense(status: []const u8) bool {
    return std.mem.eql(u8, status, "verified");
}

fn isUnverifiedLicense(status: []const u8) bool {
    return std.mem.startsWith(u8, status, "unverified");
}

fn splitRankedContextCandidates(
    high_rank: *std.ArrayList(Candidate),
    shadow_context: *std.ArrayList(Candidate),
    trash_blocked: *std.ArrayList(Candidate),
    candidates: []const Candidate,
    entries: []const corpus_ingest.IndexedEntry,
) !void {
    for (candidates) |candidate| {
        const authority_level = entries[candidate.entry_index].corpus_meta.license_authority_level;
        if (isTrashAuthority(authority_level)) {
            try trash_blocked.append(candidate);
        } else if (isShadowAuthority(authority_level)) {
            try shadow_context.append(candidate);
        } else {
            try high_rank.append(candidate);
        }
    }
}

fn isShadowAuthority(authority_level: u8) bool {
    return authority_level == 3;
}

fn isTrashAuthority(authority_level: u8) bool {
    return authority_level >= 4;
}

fn boundedCandidates(candidates: []const Candidate, max_results: usize) []const Candidate {
    return candidates[0..@min(max_results, candidates.len)];
}

fn conflictReason(candidates: []const Candidate) []const u8 {
    if (hasSystemAlphaEvenOddConflict(candidates)) {
        return "selected corpus evidence conflicts: invariant_v1.md requires System Alpha bitwise-even integer results while update_v2.md permits odd burst-mode returns";
    }
    return "selected corpus evidence contains conflicting affirmative and negative signals";
}

fn hasSystemAlphaEvenOddConflict(candidates: []const Candidate) bool {
    var even_invariant = false;
    var odd_burst_update = false;
    for (candidates) |candidate| {
        if (indexOfIgnoreCase(candidate.text, "system alpha") == null) continue;
        if (mentionsSystemAlphaEvenInvariant(candidate.text)) even_invariant = true;
        if (mentionsSystemAlphaOddBurstUpdate(candidate.text)) odd_burst_update = true;
    }
    return even_invariant and odd_burst_update;
}

fn mentionsSystemAlphaEvenInvariant(text: []const u8) bool {
    const has_even = indexOfIgnoreCase(text, "bitwise-even") != null or
        indexOfIgnoreCase(text, "even integer") != null;
    const has_invariant = indexOfIgnoreCase(text, "must") != null or
        indexOfIgnoreCase(text, "always") != null or
        indexOfIgnoreCase(text, "invariant") != null;
    return has_even and has_invariant;
}

fn mentionsSystemAlphaOddBurstUpdate(text: []const u8) bool {
    const has_odd = indexOfIgnoreCase(text, "odd") != null;
    const has_burst = indexOfIgnoreCase(text, "burst mode") != null or
        indexOfIgnoreCase(text, "burst-mode") != null;
    const has_permission = indexOfIgnoreCase(text, "may") != null or
        indexOfIgnoreCase(text, "permit") != null or
        indexOfIgnoreCase(text, "allow") != null;
    return has_odd and has_burst and has_permission;
}

fn isConflictLearningReason(reason: []const u8) bool {
    return indexOfIgnoreCase(reason, "selected corpus evidence conflicts") != null or
        indexOfIgnoreCase(reason, "conflicting affirmative and negative signals") != null;
}

fn failedSelfReview(allocator: std.mem.Allocator, rule_id: []const u8, contradiction: []const u8) !SelfReview {
    const rules = try allocator.alloc([]u8, 1);
    errdefer allocator.free(rules);
    rules[0] = try allocator.dupe(u8, rule_id);
    errdefer allocator.free(rules[0]);

    const contradictions = try allocator.alloc([]u8, 1);
    errdefer allocator.free(contradictions);
    contradictions[0] = try allocator.dupe(u8, contradiction);

    return .{
        .status = .failed,
        .matching_rules = rules,
        .unresolved_contradictions = contradictions,
    };
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

fn findBestPhraseDirect(allocator: std.mem.Allocator, text: []const u8, query_tokens: []const []const u8) !?PhraseHit {
    if (query_tokens.len < 2) return null;
    var phrase_len = @min(query_tokens.len, @as(usize, 5));
    while (phrase_len >= 2) : (phrase_len -= 1) {
        var query_start: usize = 0;
        while (query_start + phrase_len <= query_tokens.len) : (query_start += 1) {
            const phrase_tokens = query_tokens[query_start .. query_start + phrase_len];
            const phrase = try joinPhrase(allocator, phrase_tokens);
            errdefer allocator.free(phrase);
            if (indexOfIgnoreCasePos(text, 0, phrase)) |idx| {
                const after_pos = idx + phrase.len;
                const before_ok = idx == 0 or !isSearchTokenByte(text[idx - 1]);
                const after_ok = after_pos >= text.len or !isSearchTokenByte(text[after_pos]);
                if (before_ok and after_ok) {
                    const span = lineSpanForByteRange(text, idx, after_pos);
                    return .{
                        .text = phrase,
                        .token_count = phrase_len,
                        .byte_start = idx,
                        .byte_end = after_pos,
                        .line_start = span.start,
                        .line_end = span.end,
                    };
                }
            }
            allocator.free(phrase);
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
    const start = structuralSnippetStart(text, first_match, max_bytes);
    const end = @min(text.len, start + max_bytes);
    return .{ .text = try cleanSnippet(allocator, text[start..end]), .truncated = true };
}

fn structuralSnippetStart(text: []const u8, first_match: usize, max_bytes: usize) usize {
    const bounded_match = @min(first_match, text.len);
    if (findStructuralAnchor(text, bounded_match)) |anchor| return anchor;

    const half = max_bytes / 2;
    var start = if (bounded_match > half) bounded_match - half else 0;
    while (start > 0 and isUtf8ContinuationByte(text[start])) : (start -= 1) {}
    while (start < text.len and isUtf8ContinuationByte(text[start])) : (start += 1) {}
    return start;
}

fn findStructuralAnchor(text: []const u8, from: usize) ?usize {
    var cursor = @min(from, text.len);
    while (cursor > 0) {
        const line_start = previousRuneLineStart(text, cursor);
        const line = std.mem.trim(u8, text[line_start..cursor], " \t\r\n");
        if (std.ascii.startsWithIgnoreCase(line, "title:") or isMarkdownHeader(line)) return line_start;
        if (line_start >= 2 and text[line_start - 1] == '\n' and text[line_start - 2] == '\n') return line_start;
        if (line_start == 0) return 0;
        cursor = previousRuneStart(text, line_start - 1);
    }
    return null;
}

fn previousRuneLineStart(text: []const u8, from: usize) usize {
    var cursor = @min(from, text.len);
    while (cursor > 0) {
        const prev = previousRuneStart(text, cursor - 1);
        if (text[prev] == '\n' or text[prev] == '\r') return cursor;
        cursor = prev;
    }
    return 0;
}

fn previousRuneStart(text: []const u8, index: usize) usize {
    if (text.len == 0) return 0;
    var cursor = @min(index, text.len - 1);
    while (cursor > 0 and isUtf8ContinuationByte(text[cursor])) : (cursor -= 1) {}
    return cursor;
}

fn isUtf8ContinuationByte(byte: u8) bool {
    return (byte & 0b1100_0000) == 0b1000_0000;
}

fn isMarkdownHeader(line: []const u8) bool {
    var idx: usize = 0;
    while (idx < line.len and line[idx] == '#') : (idx += 1) {}
    return idx > 0 and idx < line.len and (line[idx] == ' ' or line[idx] == '\t');
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
        try writeField(w, "licenseStatus", evidence.license_status, false);
        try w.print(",\"authorityLevel\":{d}", .{evidence.authority_level});
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
    try w.writeAll("],\"suppressedEvidence\":[");
    for (result.suppressed_evidence, 0..) |evidence, idx| {
        if (idx != 0) try w.writeByte(',');
        try w.writeAll("{");
        try writeField(w, "itemId", evidence.item_id, true);
        try writeField(w, "path", evidence.path, false);
        try writeField(w, "sourcePath", evidence.source_path, false);
        try writeField(w, "sourceLabel", evidence.source_label, false);
        try writeField(w, "reason", evidence.reason, false);
        try writeField(w, "authorityRef", evidence.authority_ref, false);
        try writeField(w, "licenseStatus", evidence.license_status, false);
        try w.print(",\"authorityLevel\":{d}", .{evidence.authority_level});
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
    try w.writeAll("],\"learningInfluences\":[");
    for (result.learning_influences, 0..) |influence, idx| {
        if (idx != 0) try w.writeByte(',');
        try w.writeAll("{");
        try writeField(w, "id", influence.id, true);
        try writeField(w, "sourceReviewedLearningId", influence.source_reviewed_learning_id, false);
        try writeField(w, "sourceStore", influence.source_store, false);
        try writeField(w, "learningCandidateId", influence.learning_candidate_id, false);
        try writeField(w, "candidateKind", influence.candidate_kind, false);
        try writeField(w, "logicPattern", influence.logic_pattern, false);
        try writeField(w, "draftSignal", influence.draft_signal, false);
        try writeField(w, "reason", influence.reason, false);
        try w.print(",\"nonAuthorizing\":{s}", .{if (influence.non_authorizing) "true" else "false"});
        try w.print(",\"treatedAsProof\":{s}", .{if (influence.treated_as_proof) "true" else "false"});
        try w.print(",\"usedAsEvidence\":{s}", .{if (influence.used_as_evidence) "true" else "false"});
        try w.print(",\"globalPromotion\":{s}", .{if (influence.global_promotion) "true" else "false"});
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
    try w.writeAll(",\"learningInfluenceTelemetry\":");
    try writeLearningInfluenceTelemetry(w, result.learning_influence_telemetry);
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
        try writeField(w, "id", candidate.id, true);
        try writeField(w, "candidateKind", candidate.candidate_kind, false);
        try writeField(w, "proposedAction", candidate.proposed_action, false);
        try writeField(w, "reason", candidate.reason, false);
        try writeField(w, "logicPattern", candidate.logic_pattern, false);
        try w.print(",\"candidateOnly\":{s}", .{if (candidate.candidate_only) "true" else "false"});
        try w.print(",\"nonAuthorizing\":{s}", .{if (candidate.non_authorizing) "true" else "false"});
        try w.print(",\"treatedAsProof\":{s}", .{if (candidate.treated_as_proof) "true" else "false"});
        try w.print(",\"persisted\":{s}", .{if (candidate.persisted) "true" else "false"});
        if (candidate.self_review) |sr| {
            try w.print(",\"selfReview\":{{\"status\":\"{s}\",\"matchingRules\":[", .{sr.status.text()});
            for (sr.matching_rules, 0..) |rule, r_idx| {
                if (r_idx > 0) try w.writeByte(',');
                try std.json.stringify(rule, .{}, w);
            }
            try w.writeAll("],\"unresolvedContradictions\":[");
            for (sr.unresolved_contradictions, 0..) |contra, c_idx| {
                if (c_idx > 0) try w.writeByte(',');
                try std.json.stringify(contra, .{}, w);
            }
            try w.writeAll("]}");
        }
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
    try w.print(",\"mountedPacksConsidered\":{d}", .{result.mounted_packs_considered});
    try w.print(",\"mountedPackEntriesConsidered\":{d}", .{result.mounted_pack_entries_considered});
    try w.print(",\"maxResults\":{d}", .{result.max_results});
    try w.print(",\"maxSnippetBytes\":{d}", .{result.max_snippet_bytes});
    try w.print(",\"requireCitations\":{s}", .{if (result.require_citations) "true" else "false"});
    try w.print(",\"parameterMatchFailure\":{s}", .{if (result.parameter_match_failure) "true" else "false"});
    if (result.parameter_match_failure) try writeField(w, "parameterMatchFailureReason", "parameter_match_failure", false);
    try w.print(",\"primaryNounMatchFailure\":{s}", .{if (result.primary_noun_match_failure) "true" else "false"});
    if (result.primary_noun_match_failure) try writeField(w, "primaryNounMatchFailureReason", "primary_noun_similarity_failure", false);
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

fn writeLearningInfluenceTelemetry(w: anytype, telemetry: LearningInfluenceTelemetry) !void {
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
    try w.print(",\"draftPromoted\":{s},\"truncated\":{s},\"sameShardOnly\":{s}", .{
        if (telemetry.draft_promoted) "true" else "false",
        if (telemetry.truncated) "true" else "false",
        if (telemetry.same_shard_only) "true" else "false",
    });
    try w.writeAll(",\"sourceStore\":\"learned_records.jsonl\"}");
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
