const std = @import("std");
const abstractions = @import("abstractions.zig");
const corpus_ingest = @import("corpus_ingest.zig");
const shards = @import("shards.zig");

pub const DEFAULT_MAX_RESULTS: usize = 3;
pub const MAX_RESULTS: usize = 8;
pub const DEFAULT_MAX_SNIPPET_BYTES: usize = 320;
pub const MAX_SNIPPET_BYTES: usize = 1024;
const MAX_FILE_READ_BYTES: usize = 64 * 1024;
const MAX_QUERY_TOKENS: usize = 16;
const MIN_TOKEN_LEN: usize = 3;

pub const AskStatus = enum {
    answered,
    unknown,
};

pub const UnknownKind = enum {
    no_corpus_available,
    insufficient_evidence,
    conflicting_evidence,
    malformed_request,
};

pub const SafetyFlags = struct {
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
    persisted: bool = false,

    fn deinit(self: *LearningCandidate, allocator: std.mem.Allocator) void {
        allocator.free(self.candidate_kind);
        allocator.free(self.proposed_action);
        allocator.free(self.reason);
        self.* = undefined;
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
    safety_flags: SafetyFlags = .{},
    corpus_entries_considered: usize = 0,
    max_results: usize = DEFAULT_MAX_RESULTS,
    max_snippet_bytes: usize = DEFAULT_MAX_SNIPPET_BYTES,
    require_citations: bool = true,

    pub fn deinit(self: *Result) void {
        self.allocator.free(self.state);
        self.allocator.free(self.permission);
        self.allocator.free(self.question);
        self.allocator.free(self.shard_kind);
        self.allocator.free(self.shard_id);
        if (self.answer_draft) |value| self.allocator.free(value);
        for (self.evidence_used) |*item| item.deinit(self.allocator);
        self.allocator.free(self.evidence_used);
        for (self.unknowns) |*item| item.deinit(self.allocator);
        self.allocator.free(self.unknowns);
        for (self.candidate_followups) |*item| item.deinit(self.allocator);
        self.allocator.free(self.candidate_followups);
        for (self.learning_candidates) |*item| item.deinit(self.allocator);
        self.allocator.free(self.learning_candidates);
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
    text: []u8,

    fn deinit(self: *Candidate, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        for (self.matched_terms) |term| allocator.free(term);
        allocator.free(self.matched_terms);
        if (self.matched_phrase) |phrase| allocator.free(phrase);
        self.* = undefined;
    }
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

const Polarity = enum {
    none,
    affirmative,
    negative,
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

    const entries = try corpus_ingest.collectLiveScanEntries(allocator, &paths);
    defer corpus_ingest.deinitIndexedEntries(allocator, entries);

    var tokens = try tokenizeQuery(allocator, options.question);
    defer tokens.deinit(allocator);

    if (entries.len == 0) {
        return unknownResult(allocator, options, &paths, .no_corpus_available, "no live shard corpus is available for this ask request", entries.len, max_results, max_snippet);
    }
    if (tokens.tokens.len == 0) {
        return unknownResult(allocator, options, &paths, .insufficient_evidence, "question did not contain enough searchable terms", entries.len, max_results, max_snippet);
    }

    var candidates = std.ArrayList(Candidate).init(allocator);
    defer {
        for (candidates.items) |*candidate| candidate.deinit(allocator);
        candidates.deinit();
    }

    for (entries, 0..) |entry, idx| {
        const file_text = readEntryText(allocator, entry.abs_path) catch continue;
        errdefer allocator.free(file_text);
        const text_tokens = try tokenizeText(allocator, file_text);
        defer freeTextTokens(allocator, text_tokens);
        var scored = try scoreText(allocator, text_tokens, tokens.tokens);
        if (scored.score == 0) {
            scored.deinit(allocator);
            allocator.free(file_text);
            continue;
        }
        candidates.append(.{
            .entry_index = idx,
            .score = scored.score,
            .first_match = scored.first_match,
            .byte_start = scored.byte_start,
            .byte_end = scored.byte_end,
            .line_start = scored.line_start,
            .line_end = scored.line_end,
            .matched_terms = scored.matched_terms,
            .matched_phrase = scored.matched_phrase,
            .content_hash = std.hash.Fnv1a_64.hash(file_text),
            .polarity = detectPolarity(file_text),
            .text = file_text,
        }) catch |err| {
            scored.deinit(allocator);
            return err;
        };
    }

    if (candidates.items.len == 0) {
        return unknownResult(allocator, options, &paths, .insufficient_evidence, "no live corpus item matched the question terms", entries.len, max_results, max_snippet);
    }

    std.mem.sort(Candidate, candidates.items, {}, candidateLessThan);
    const top_count = @min(max_results, candidates.items.len);
    const conflict = hasConflict(candidates.items[0..top_count]);
    if (conflict) {
        var result = try buildBaseResult(allocator, options, &paths, .unknown, "unresolved", "unresolved", entries.len, max_results, max_snippet);
        errdefer result.deinit();
        result.evidence_used = try buildEvidence(allocator, candidates.items[0..top_count], entries, max_snippet, "selected because it matched question terms but conflicts with another selected corpus item");
        result.unknowns = try singleUnknown(allocator, .conflicting_evidence, "selected corpus evidence contains conflicting affirmative and negative signals");
        result.candidate_followups = try singleFollowup(allocator, "evidence_to_collect", "provide or ingest an authoritative corpus item that resolves the conflict");
        result.learning_candidates = try singleLearningCandidate(allocator, "correction_candidate", "review the conflicting corpus items and propose a correction or corpus update through an explicit lifecycle", "conflicting evidence cannot authorize an answer");
        return result;
    }

    const top = candidates.items[0];
    if (top.score < requiredScore(tokens.tokens.len) and top.matched_phrase == null) {
        return unknownResult(allocator, options, &paths, .insufficient_evidence, "matched corpus evidence was too weak to support an answer draft", entries.len, max_results, max_snippet);
    }

    var result = try buildBaseResult(allocator, options, &paths, .answered, "draft", "none", entries.len, max_results, max_snippet);
    errdefer result.deinit();
    result.evidence_used = try buildEvidence(allocator, candidates.items[0..top_count], entries, max_snippet, "selected because it matched bounded question terms");
    result.answer_draft = try std.fmt.allocPrint(
        allocator,
        "Draft answer from corpus evidence: {s}",
        .{result.evidence_used[0].snippet},
    );
    result.candidate_followups = try singleFollowup(allocator, "verifier_check_candidate", "review the cited corpus evidence before treating this answer as supported");
    return result;
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

fn readEntryText(allocator: std.mem.Allocator, abs_path: []const u8) ![]u8 {
    const file = try std.fs.openFileAbsolute(abs_path, .{});
    defer file.close();
    return file.readToEndAlloc(allocator, MAX_FILE_READ_BYTES);
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
    try w.writeAll("],\"unknowns\":[");
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
        try w.print(",\"persisted\":{s}", .{if (candidate.persisted) "true" else "false"});
        try w.writeAll("}");
    }
    try w.writeAll("],\"trace\":{");
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
