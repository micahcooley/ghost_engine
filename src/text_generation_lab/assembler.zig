const std = @import("std");
const parser = @import("parser.zig");

pub const AssemblyInput = struct {
    query: []const u8,
    concept: parser.ParsedConcept,
    source_hint: ?[]const u8 = null,
};

pub const VoidInput = struct {
    query: []const u8,
    shard_hint: ?[]const u8 = null,
};

const ClauseOrder = enum {
    subject_first,
    predicate_first,
    source_first,
};

pub fn assemblePredicateDraft(allocator: std.mem.Allocator, input: AssemblyInput) ![]u8 {
    const predicate = input.concept.predicate orelse return assembleVoidDraft(allocator, .{ .query = input.query, .shard_hint = input.source_hint });
    
    // For social/conversational intents, we bypass the symbolic "predicate reads" wrapper
    // to provide a natural, human-like response from the neural layer.
    if (input.concept.intent == .social) {
        var out = std.ArrayList(u8).init(allocator);
        errdefer out.deinit();
        const trimmed = std.mem.trim(u8, input.concept.source_sentence, " \r\n\t");
        try out.appendSlice(trimmed);
        if (out.items.len > 0 and out.items[out.items.len - 1] != '.' and out.items[out.items.len - 1] != '!' and out.items[out.items.len - 1] != '?') {
            try out.append('.');
        }
        return out.toOwnedSlice();
    }

    const order = chooseOrder(input.query, input.concept.source_sentence);
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();

    switch (order) {
        .subject_first => {
            try writeCapitalized(&out, predicate.subject);
            try out.append(' ');
            try out.appendSlice(normalizePredicate(predicate.predicate, predicate.kind));
            try out.append(' ');
            try appendBoundPhrase(&out, predicate.object);
        },
        .predicate_first => {
            try out.appendSlice(intentLead(input.concept.intent));
            try out.appendSlice(", ");
            try writeCapitalized(&out, predicate.subject);
            try out.append(' ');
            try out.appendSlice(normalizePredicate(predicate.predicate, predicate.kind));
            try out.append(' ');
            try appendBoundPhrase(&out, predicate.object);
        },
        .source_first => {
            if (input.source_hint) |source| {
                try out.appendSlice("From ");
                try appendBoundPhrase(&out, source);
                try out.appendSlice(": ");
            }
            try writeCapitalized(&out, predicate.subject);
            try out.append(' ');
            try out.appendSlice(normalizePredicate(predicate.predicate, predicate.kind));
            try out.append(' ');
            try appendBoundPhrase(&out, predicate.object);
        },
    }
    try finishSentence(&out);
    return out.toOwnedSlice();
}

pub fn assembleVoidDraft(allocator: std.mem.Allocator, input: VoidInput) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const keyword = singleConceptKeyword(input.query);
    if (keyword.len == 0) {
        try out.appendSlice("The query resolved to a semantic void");
    } else {
        try out.appendSlice("The query resolved to a semantic void after single-concept VSA search for ");
        try appendBoundPhrase(&out, keyword);
    }
    try finishSentence(&out);
    return out.toOwnedSlice();
}

fn chooseOrder(query: []const u8, sentence: []const u8) ClauseOrder {
    return switch (hashChoice(query, sentence, 3)) {
        0 => .subject_first,
        1 => .predicate_first,
        else => .source_first,
    };
}

fn hashChoice(a: []const u8, b: []const u8, modulo: u64) u64 {
    var hasher = std.hash.Fnv1a_64.init();
    hasher.update(a);
    hasher.update(b);
    var time_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &time_bytes, @intCast(std.time.nanoTimestamp()), .little);
    hasher.update(&time_bytes);
    return hasher.final() % modulo;
}

fn intentLead(intent: parser.IntentKind) []const u8 {
    return switch (intent) {
        .factual_identity => "the identity predicate reads",
        .factual_definition => "the definition predicate reads",
        .procedural => "the procedure predicate reads",
        .social => "the acknowledgment predicate reads",
        .unknown => "the extracted predicate reads",
    };
}

fn normalizePredicate(predicate: []const u8, kind: parser.PredicateKind) []const u8 {
    _ = kind;
    if (std.ascii.eqlIgnoreCase(predicate, "means")) return "means";
    if (std.ascii.eqlIgnoreCase(predicate, "refers to")) return "refers to";
    if (std.ascii.eqlIgnoreCase(predicate, "describes")) return "describes";
    if (std.ascii.eqlIgnoreCase(predicate, "are")) return "are";
    if (std.ascii.eqlIgnoreCase(predicate, "were")) return "were";
    if (std.ascii.eqlIgnoreCase(predicate, "was")) return "was";
    return predicate;
}

fn writeCapitalized(out: *std.ArrayList(u8), text: []const u8) !void {
    const trimmed = std.mem.trim(u8, text, " \r\n\t");
    if (trimmed.len == 0) return;
    try out.append(std.ascii.toUpper(trimmed[0]));
    if (trimmed.len > 1) try out.appendSlice(trimmed[1..]);
}

fn appendBoundPhrase(out: *std.ArrayList(u8), text: []const u8) !void {
    const trimmed = std.mem.trim(u8, text, " \r\n\t,;:\"'");
    const max = @min(trimmed.len, @as(usize, 220));
    try out.appendSlice(trimmed[0..max]);
}

fn finishSentence(out: *std.ArrayList(u8)) !void {
    while (out.items.len != 0 and std.ascii.isWhitespace(out.items[out.items.len - 1])) _ = out.pop();
    if (out.items.len == 0) return;
    const last = out.items[out.items.len - 1];
    if (last != '.' and last != '!' and last != '?') try out.append('.');
}

fn semanticSubject(query: []const u8) []const u8 {
    return singleConceptKeyword(query);
}

pub fn singleConceptKeyword(query: []const u8) []const u8 {
    var start: ?usize = null;
    var best: []const u8 = "";
    var idx: usize = 0;
    while (idx <= query.len) : (idx += 1) {
        const at_end = idx == query.len;
        const byte = if (at_end) 0 else query[idx];
        if (!at_end and (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_')) {
            if (start == null) start = idx;
            continue;
        }
        if (start) |s| {
            const term = query[s..idx];
            if (term.len >= 3 and term.len >= best.len and !isQuestionWord(term)) best = term;
            start = null;
        }
    }
    return best;
}

fn isQuestionWord(term: []const u8) bool {
    const words = [_][]const u8{ "who", "what", "when", "where", "why", "how", "define", "the" };
    for (words) |word| if (std.ascii.eqlIgnoreCase(term, word)) return true;
    return false;
}

test "assembler renders predicate without canned subject response" {
    const allocator = std.testing.allocator;
    var parsed = (try parser.parseConcept(allocator, "who is albert einstein", "Albert Einstein was a theoretical physicist.")) orelse return error.ExpectedPredicate;
    defer parsed.deinit(allocator);
    const text = try assemblePredicateDraft(allocator, .{ .query = "who is albert einstein", .concept = parsed });
    defer allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "physicist") != null);
}

test "assembler falls back to single concept instead of predicate failure" {
    const allocator = std.testing.allocator;
    const text = try assembleVoidDraft(allocator, .{ .query = "what is a ghost", .shard_hint = null });
    defer allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "ghost") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "No extractable predicate") == null);
}
