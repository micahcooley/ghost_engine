const std = @import("std");

pub const RelationshipType = enum {
    Identity,
    Distinction,
    Composition,
    Constraint,
    Implication,
    Unresolved,
};

pub const ConfidenceBand = enum {
    none,
    low,
    medium,
    high,
};

pub const Signal = enum(u3) {
    main_verb_semantics = 0,
    grammatical_mood = 1,
    word_order = 2,
    explicit_marker = 3,
    topology_context = 4,
};

pub const ClassificationResult = struct {
    relationship: RelationshipType,
    confidence: u8,
    signals_found: u8,
    confidence_band: ConfidenceBand,
    uncertain: bool,
    negation_detected: bool,

    pub fn hasSignal(self: ClassificationResult, signal: Signal) bool {
        return (self.signals_found & signalMask(signal)) != 0;
    }
};

const TypeSignals = struct {
    relationship: RelationshipType,
    verbs: []const []const u8,
    markers: []const []const u8,
};

const identity_verbs = [_][]const u8{
    "is",      "are",         "was",       "were", "equals", "means", "represents",
    "defines", "constitutes", "refers to",
};

const distinction_verbs = [_][]const u8{
    "differs",      "unlike",   "contrast",      "distinct", "separate",
    "not the same", "diverges", "distinguishes",
};

const composition_verbs = [_][]const u8{
    "combines", "combined", "composed", "creates", "produces", "yields",
    "together", "merged",   "joined",   "forms",
};

const constraint_verbs = [_][]const u8{
    "prevents", "blocks",    "forbids", "cannot", "must not",
    "denies",   "restricts", "limits",  "stops",  "not all",
};

const implication_verbs = [_][]const u8{
    "implies",  "therefore", "means that", "causes", "results in",
    "leads to", "if",        "then",       "when",   "ensures",
};

const copula_verbs = [_][]const u8{ "is", "are", "was", "were" };
const state_permission_verbs = [_][]const u8{
    "shared",    "allocated", "owned",    "held",     "locked",
    "protected", "guarded",   "accessed", "reserved",
};

const identity_markers = [_][]const u8{ " is ", " are ", " equals ", " means " };
const distinction_markers = [_][]const u8{ " differs ", " unlike ", " contrast ", " distinct ", " not the same " };
const composition_markers = [_][]const u8{ " combined with ", " composed of ", " with ", " together ", " creates " };
const constraint_markers = [_][]const u8{ " prevents ", " cannot ", " must not ", " not all ", " no " };
const implication_markers = [_][]const u8{ " implies ", " therefore ", " if ", " then ", " when ", " results in " };

const type_signals = [_]TypeSignals{
    .{ .relationship = .Identity, .verbs = &identity_verbs, .markers = &identity_markers },
    .{ .relationship = .Distinction, .verbs = &distinction_verbs, .markers = &distinction_markers },
    .{ .relationship = .Composition, .verbs = &composition_verbs, .markers = &composition_markers },
    .{ .relationship = .Constraint, .verbs = &constraint_verbs, .markers = &constraint_markers },
    .{ .relationship = .Implication, .verbs = &implication_verbs, .markers = &implication_markers },
};

const Score = struct {
    relationship: RelationshipType,
    confidence: u8 = 0,
    signals_found: u8 = 0,
    earliest_match: usize = std.math.maxInt(usize),
};

pub fn classify(allocator: std.mem.Allocator, sentence: []const u8) !ClassificationResult {
    const normalized = try normalize(allocator, sentence);
    defer allocator.free(normalized);

    const trimmed = std.mem.trim(u8, normalized, " ");
    if (trimmed.len == 0) return unresolved(false);

    var tokens = std.ArrayList([]const u8).init(allocator);
    defer tokens.deinit();
    try tokenize(trimmed, &tokens);
    if (tokens.items.len < 2) return unresolved(hasNegation(trimmed));

    var best = Score{ .relationship = .Unresolved };
    var tie = false;
    for (type_signals) |spec| {
        const score = scoreType(trimmed, tokens.items, spec);
        if (score.confidence > best.confidence or
            (score.confidence == best.confidence and score.confidence > 0 and score.earliest_match < best.earliest_match))
        {
            best = score;
            tie = false;
        } else if (score.confidence == best.confidence and score.confidence > 0 and score.earliest_match == best.earliest_match) {
            tie = true;
        }
    }

    if (best.confidence == 0) return unresolved(hasNegation(trimmed));
    if (tie and best.confidence < 4) return unresolved(hasNegation(trimmed));

    const confidence = @min(best.confidence, 5);
    return .{
        .relationship = best.relationship,
        .confidence = confidence,
        .signals_found = best.signals_found,
        .confidence_band = confidenceBand(confidence),
        .uncertain = confidence < 4,
        .negation_detected = hasNegation(trimmed),
    };
}

fn scoreType(sentence: []const u8, tokens: []const []const u8, spec: TypeSignals) Score {
    var score = Score{ .relationship = spec.relationship };
    const state_permission_match = statePermissionOverrideMatch(sentence);
    const identity_downgraded = spec.relationship == .Identity and state_permission_match != null;
    const constraint_upgraded = spec.relationship == .Constraint and state_permission_match != null;
    const verb_match = if (identity_downgraded) null else firstPhraseMatch(sentence, spec.verbs);
    const marker_match = if (identity_downgraded) null else firstPhraseMatch(sentence, spec.markers);
    const standard_match = verb_match orelse marker_match;

    if (verb_match) |idx| {
        addSignal(&score, .main_verb_semantics);
        score.earliest_match = @min(score.earliest_match, idx);
    }
    if (!constraint_upgraded or standard_match != null) {
        if (hasMoodSignal(sentence, spec.relationship)) addSignal(&score, .grammatical_mood);
    }
    if (hasWordOrderSignal(sentence, tokens, spec.relationship, standard_match)) addSignal(&score, .word_order);
    if (marker_match) |idx| {
        addSignal(&score, .explicit_marker);
        score.earliest_match = @min(score.earliest_match, idx);
    }
    if (hasContextSignal(tokens, spec.relationship)) addSignal(&score, .topology_context);
    if (constraint_upgraded and standard_match == null) {
        const idx = state_permission_match.?;
        addSignal(&score, .main_verb_semantics);
        if (hasWordOrderSignal(sentence, tokens, spec.relationship, idx)) addSignal(&score, .word_order);
        score.earliest_match = @min(score.earliest_match, idx);
    }

    return score;
}

fn hasMoodSignal(sentence: []const u8, relationship: RelationshipType) bool {
    if (std.mem.indexOfScalar(u8, sentence, '?') != null) return false;
    return switch (relationship) {
        .Implication => containsWord(sentence, "if") or containsWord(sentence, "then") or containsWord(sentence, "when") or isDeclarative(sentence),
        .Constraint => hasNegation(sentence) or isDeclarative(sentence),
        .Identity, .Distinction, .Composition => isDeclarative(sentence),
        .Unresolved => false,
    };
}

fn isDeclarative(sentence: []const u8) bool {
    return sentence.len > 0 and std.mem.indexOfScalar(u8, sentence, '?') == null;
}

fn hasWordOrderSignal(sentence: []const u8, tokens: []const []const u8, relationship: RelationshipType, match_index: ?usize) bool {
    if (tokens.len < 3) return false;
    if (relationship == .Implication and (containsWord(sentence, "if") or containsWord(sentence, "when"))) return true;
    const idx = match_index orelse return false;
    const before = std.mem.trim(u8, sentence[0..idx], " ");
    const after = std.mem.trim(u8, sentence[@min(sentence.len, idx + 1)..], " ");
    return contentTokenCount(before) >= 1 and contentTokenCount(after) >= 1;
}

fn hasContextSignal(tokens: []const []const u8, relationship: RelationshipType) bool {
    const content_count = countContentTokens(tokens);
    if (content_count < 2) return false;
    return switch (relationship) {
        .Identity, .Distinction, .Composition, .Constraint, .Implication => true,
        .Unresolved => false,
    };
}

fn addSignal(score: *Score, signal: Signal) void {
    const mask = signalMask(signal);
    if ((score.signals_found & mask) == 0) {
        score.signals_found |= mask;
        score.confidence += 1;
    }
}

fn signalMask(signal: Signal) u8 {
    return @as(u8, 1) << @intFromEnum(signal);
}

fn confidenceBand(confidence: u8) ConfidenceBand {
    if (confidence >= 4) return .high;
    if (confidence >= 2) return .medium;
    if (confidence == 1) return .low;
    return .none;
}

fn unresolved(negation_detected: bool) ClassificationResult {
    return .{
        .relationship = .Unresolved,
        .confidence = 0,
        .signals_found = 0,
        .confidence_band = .none,
        .uncertain = true,
        .negation_detected = negation_detected,
    };
}

fn normalize(allocator: std.mem.Allocator, sentence: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();

    var previous_space = true;
    for (sentence) |byte| {
        const lower = std.ascii.toLower(byte);
        if (std.ascii.isAlphanumeric(lower) or lower == '\'') {
            try out.append(lower);
            previous_space = false;
        } else if (std.ascii.isWhitespace(lower) or byte == '-' or byte == '/' or byte == ',' or byte == '.' or byte == ':' or byte == ';') {
            if (!previous_space) {
                try out.append(' ');
                previous_space = true;
            }
        } else if (byte == '?') {
            if (!previous_space) try out.append(' ');
            try out.append('?');
            previous_space = false;
        }
    }

    while (out.items.len > 0 and out.items[out.items.len - 1] == ' ') _ = out.pop();
    return out.toOwnedSlice();
}

fn tokenize(sentence: []const u8, out: *std.ArrayList([]const u8)) !void {
    var it = std.mem.tokenizeScalar(u8, sentence, ' ');
    while (it.next()) |token| {
        if (std.mem.eql(u8, token, "?")) continue;
        try out.append(token);
    }
}

fn firstPhraseMatch(sentence: []const u8, phrases: []const []const u8) ?usize {
    var best: ?usize = null;
    for (phrases) |phrase| {
        if (findPhrase(sentence, phrase)) |idx| {
            if (best == null or idx < best.?) best = idx;
        }
    }
    return best;
}

fn findPhrase(sentence: []const u8, raw_phrase: []const u8) ?usize {
    var buf: [96]u8 = undefined;
    if (raw_phrase.len + 2 > buf.len) return null;
    const phrase = normalizePhrase(&buf, raw_phrase);
    return std.mem.indexOf(u8, sentence, phrase);
}

fn normalizePhrase(buf: []u8, raw_phrase: []const u8) []const u8 {
    var len: usize = 0;
    var previous_space = false;
    for (raw_phrase) |byte| {
        const lower = std.ascii.toLower(byte);
        if (std.ascii.isAlphanumeric(lower) or lower == '\'') {
            buf[len] = lower;
            len += 1;
            previous_space = false;
        } else if (!previous_space) {
            buf[len] = ' ';
            len += 1;
            previous_space = true;
        }
    }
    while (len > 0 and buf[len - 1] == ' ') len -= 1;
    return buf[0..len];
}

fn containsWord(sentence: []const u8, word: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, sentence, ' ');
    while (it.next()) |token| {
        if (std.mem.eql(u8, token, word)) return true;
    }
    return false;
}

fn hasNegation(sentence: []const u8) bool {
    return containsWord(sentence, "not") or
        containsWord(sentence, "no") or
        containsWord(sentence, "cannot") or
        std.mem.indexOf(u8, sentence, "must not") != null;
}

fn statePermissionOverrideMatch(sentence: []const u8) ?usize {
    if (firstPhraseMatch(sentence, &copula_verbs) == null) return null;
    return firstPhraseMatch(sentence, &state_permission_verbs);
}

fn countContentTokens(tokens: []const []const u8) usize {
    var count: usize = 0;
    for (tokens) |token| {
        if (!isStopword(token)) count += 1;
    }
    return count;
}

fn contentTokenCount(text: []const u8) usize {
    var count: usize = 0;
    var it = std.mem.tokenizeScalar(u8, text, ' ');
    while (it.next()) |token| {
        if (!isStopword(token)) count += 1;
    }
    return count;
}

fn isStopword(token: []const u8) bool {
    const words = [_][]const u8{
        "a",  "an",  "the", "that",    "this", "with", "from", "to", "in",
        "of", "and", "or",  "between", "all",  "not",
    };
    for (words) |word| {
        if (std.mem.eql(u8, token, word)) return true;
    }
    return false;
}

test "grpe classifier clear cases score high confidence" {
    const allocator = std.testing.allocator;
    const Case = struct {
        sentence: []const u8,
        expected: RelationshipType,
    };
    const cases = [_]Case{
        .{ .sentence = "A mutex is a synchronization primitive", .expected = .Identity },
        .{ .sentence = "A mutex differs from a semaphore in ownership", .expected = .Distinction },
        .{ .sentence = "A mutex combined with a thread creates ownership", .expected = .Composition },
        .{ .sentence = "A mutex prevents concurrent thread access", .expected = .Constraint },
        .{ .sentence = "Acquiring a mutex implies entering a critical section", .expected = .Implication },
    };

    for (cases) |case| {
        const result = try classify(allocator, case.sentence);
        try std.testing.expectEqual(case.expected, result.relationship);
        try std.testing.expect(result.confidence >= 4);
        try std.testing.expectEqual(ConfidenceBand.high, result.confidence_band);
        try std.testing.expect(!result.uncertain);
    }
}

test "grpe classifier harder language stays low confidence or unresolved" {
    const allocator = std.testing.allocator;

    const failed_lock = try classify(allocator, "The lock failed");
    try std.testing.expect(failed_lock.relationship == .Unresolved or failed_lock.relationship == .Identity);
    try std.testing.expect(failed_lock.confidence <= 1);

    const calls = try classify(allocator, "Functions call functions");
    try std.testing.expect(calls.relationship == .Unresolved or calls.relationship == .Composition);
    try std.testing.expect(calls.confidence <= 3);

    const shared = try classify(allocator, "Memory is shared between threads");
    try std.testing.expectEqual(RelationshipType.Constraint, shared.relationship);
    try std.testing.expectEqual(ConfidenceBand.medium, shared.confidence_band);
    try std.testing.expect(shared.uncertain);

    const negation = try classify(allocator, "Not all functions that acquire locks release them");
    try std.testing.expect(negation.relationship == .Constraint or negation.relationship == .Unresolved);
    try std.testing.expect(negation.negation_detected);
}

test "grpe classifier adversarial input remains unresolved" {
    const allocator = std.testing.allocator;

    const nonsense = try classify(allocator, "Purple Tuesday recursive elephant");
    try std.testing.expectEqual(RelationshipType.Unresolved, nonsense.relationship);
    try std.testing.expectEqual(@as(u8, 0), nonsense.confidence);

    const single = try classify(allocator, "The");
    try std.testing.expectEqual(RelationshipType.Unresolved, single.relationship);
    try std.testing.expectEqual(@as(u8, 0), single.confidence);

    const empty = try classify(allocator, "");
    try std.testing.expectEqual(RelationshipType.Unresolved, empty.relationship);
    try std.testing.expectEqual(@as(u8, 0), empty.confidence);
}
