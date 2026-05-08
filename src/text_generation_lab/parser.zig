const std = @import("std");
const intent_grounding = @import("../intent_grounding.zig");

pub const IntentKind = enum {
    factual_identity,
    factual_definition,
    procedural,
    social,
    unknown,
};

pub const PredicateKind = enum {
    identity,
    definition,
    action,
    property,
    unknown,
};

pub const PredicateNode = struct {
    subject: []u8,
    predicate: []u8,
    object: []u8,
    kind: PredicateKind,

    pub fn deinit(self: *PredicateNode, allocator: std.mem.Allocator) void {
        allocator.free(self.subject);
        allocator.free(self.predicate);
        allocator.free(self.object);
        self.* = undefined;
    }
};

pub const ParsedConcept = struct {
    intent: IntentKind,
    predicate: ?PredicateNode = null,
    ontological_primitives: []intent_grounding.OntologyPrimitive = &.{},
    source_sentence: []u8,
    confidence_per_mille: u16,

    pub fn deinit(self: *ParsedConcept, allocator: std.mem.Allocator) void {
        if (self.predicate) |*predicate| predicate.deinit(allocator);
        intent_grounding.freeOntologicalPrimitives(allocator, self.ontological_primitives);
        allocator.free(self.source_sentence);
        self.* = undefined;
    }
};

pub fn parseConcept(allocator: std.mem.Allocator, query: []const u8, raw_text: []const u8) !?ParsedConcept {
    const cleaned = try cleanRawText(allocator, raw_text);
    defer allocator.free(cleaned);

    const intent = inferIntent(query);
    var best_sentence: []const u8 = "";
    var best_score: i32 = -1;
    var start: usize = 0;
    var idx: usize = 0;
    while (idx <= cleaned.len) : (idx += 1) {
        const at_end = idx == cleaned.len;
        if (!at_end and cleaned[idx] != '.' and cleaned[idx] != '!' and cleaned[idx] != '?' and cleaned[idx] != '\n') continue;
        const sentence = std.mem.trim(u8, cleaned[start..idx], " \r\n\t");
        const score = scoreSentence(query, sentence);
        if (sentence.len != 0 and score > best_score) {
            if (try extractPredicate(allocator, sentence, intent)) |probe_node| {
                var probe = probe_node;
                probe.deinit(allocator);
                best_sentence = sentence;
                best_score = score;
            }
        }
        start = idx + 1;
    }

    if (best_sentence.len == 0) {
        const trimmed = std.mem.trim(u8, cleaned, " \r\n\t");
        if (trimmed.len == 0) return null;
        best_sentence = trimmed;
    }

    var predicate = (try extractPredicate(allocator, best_sentence, intent)) orelse return null;
    errdefer predicate.deinit(allocator);
    const ontological_primitives = try parseOntologyPrimitives(allocator, query, best_sentence);
    errdefer intent_grounding.freeOntologicalPrimitives(allocator, ontological_primitives);

    return .{
        .intent = intent,
        .predicate = predicate,
        .ontological_primitives = ontological_primitives,
        .source_sentence = try allocator.dupe(u8, best_sentence),
        .confidence_per_mille = confidenceFor(best_score, predicate),
    };
}

pub fn parseOntologyPrimitives(allocator: std.mem.Allocator, query: []const u8, raw_text: []const u8) ![]intent_grounding.OntologyPrimitive {
    const combined = if (raw_text.len == 0)
        try allocator.dupe(u8, query)
    else
        try std.fmt.allocPrint(allocator, "{s}\n{s}", .{ query, raw_text });
    defer allocator.free(combined);
    return intent_grounding.extractOntologicalPrimitives(allocator, combined);
}

fn cleanRawText(allocator: std.mem.Allocator, raw_text: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();

    var line_it = std.mem.splitScalar(u8, raw_text, '\n');
    while (line_it.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \r\t");
        if (line.len == 0) {
            if (out.items.len != 0 and out.items[out.items.len - 1] != '\n') try out.append('\n');
            continue;
        }
        if (isMetadataLine(line)) continue;
        var idx: usize = 0;
        while (idx < line.len) : (idx += 1) {
            const byte = line[idx];
            if (byte == '[' or byte == ']' or byte == '{' or byte == '}' or byte == '|' or byte == '*') {
                try out.append(' ');
            } else if (std.ascii.isControl(byte)) {
                try out.append(' ');
            } else {
                try out.append(byte);
            }
        }
        try out.append(' ');
    }
    return out.toOwnedSlice();
}

fn isMetadataLine(line: []const u8) bool {
    const prefixes = [_][]const u8{
        "path=",  "source=", "search=", "semantic=", "spo=",      "inv_spo=", "concepts=",
        "title:", "url:",    "source:", "redirect:", "category:",
    };
    for (prefixes) |prefix| {
        if (std.ascii.startsWithIgnoreCase(line, prefix)) return true;
    }
    return false;
}

fn inferIntent(query: []const u8) IntentKind {
    if (containsWord(query, "who")) return .factual_identity;
    if (containsWord(query, "what") or containsWord(query, "define") or containsWord(query, "definition")) return .factual_definition;
    if (containsWord(query, "how")) return .procedural;
    if (containsWord(query, "hi") or containsWord(query, "hello") or containsWord(query, "hey")) return .social;
    return .unknown;
}

fn extractPredicate(allocator: std.mem.Allocator, sentence: []const u8, intent: IntentKind) !?PredicateNode {
    const verbs = [_][]const u8{
        " is ",       " are ",      " was ",  " were ",     " means ",     " refers to ", " describes ",
        " contains ", " includes ", " uses ", " executes ", " processes ", " stores ",    " controls ",
    };
    for (verbs) |verb| {
        const idx = indexOfIgnoreCase(sentence, verb) orelse continue;
        const lhs = trimPhrase(sentence[0..idx]);
        const rhs = trimPhrase(sentence[idx + verb.len ..]);
        if (lhs.len == 0 or rhs.len == 0) continue;
        const predicate = std.mem.trim(u8, verb, " ");
        return .{
            .subject = try allocator.dupe(u8, lhs),
            .predicate = try allocator.dupe(u8, predicate),
            .object = try allocator.dupe(u8, boundObject(rhs)),
            .kind = switch (intent) {
                .factual_identity => .identity,
                .factual_definition => .definition,
                else => if (isCopula(predicate)) .property else .action,
            },
        };
    }
    return null;
}

fn trimPhrase(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, " \r\n\t,;:\"'()[]{}");
}

fn boundObject(text: []const u8) []const u8 {
    var end: usize = @min(text.len, @as(usize, 220));
    var idx: usize = 0;
    while (idx < end) : (idx += 1) {
        if (text[idx] == '\n') {
            end = idx;
            break;
        }
    }
    while (end > 0 and end < text.len and !std.ascii.isWhitespace(text[end - 1]) and text[end - 1] != '.' and text[end - 1] != ',') : (end -= 1) {}
    return std.mem.trim(u8, text[0..end], " \r\n\t,;:\"'()[]{}");
}

fn isCopula(predicate: []const u8) bool {
    return std.ascii.eqlIgnoreCase(predicate, "is") or
        std.ascii.eqlIgnoreCase(predicate, "are") or
        std.ascii.eqlIgnoreCase(predicate, "was") or
        std.ascii.eqlIgnoreCase(predicate, "were");
}

fn scoreSentence(query: []const u8, sentence: []const u8) i32 {
    var score: i32 = 0;
    var it = std.mem.tokenizeAny(u8, query, " \r\n\t,.:;!?()[]{}\"'");
    while (it.next()) |term| {
        if (term.len < 3 or isStopWord(term)) continue;
        if (indexOfIgnoreCase(sentence, term) != null) score += 20;
    }
    if (indexOfIgnoreCase(sentence, " is ") != null or indexOfIgnoreCase(sentence, " was ") != null) score += 8;
    if (sentence.len > 260) score -= 4;
    return score;
}

fn confidenceFor(score: i32, predicate: PredicateNode) u16 {
    var confidence: i32 = 480 + @max(score, 0) * 20;
    if (predicate.subject.len != 0) confidence += 80;
    if (predicate.object.len > 24) confidence += 80;
    return @intCast(@min(@max(confidence, 0), 1000));
}

fn containsWord(text: []const u8, needle: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, text, " \r\n\t,.:;!?()[]{}\"'");
    while (it.next()) |term| {
        if (std.ascii.eqlIgnoreCase(term, needle)) return true;
    }
    return false;
}

fn isStopWord(term: []const u8) bool {
    const stops = [_][]const u8{ "what", "who", "when", "where", "why", "how", "the", "and", "for", "with", "that", "this" };
    for (stops) |stop| if (std.ascii.eqlIgnoreCase(term, stop)) return true;
    return false;
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or needle.len > haystack.len) return null;
    var idx: usize = 0;
    while (idx + needle.len <= haystack.len) : (idx += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[idx .. idx + needle.len], needle)) return idx;
    }
    return null;
}

test "parser extracts identity predicate from noisy text" {
    const allocator = std.testing.allocator;
    var parsed = (try parseConcept(allocator, "who is albert einstein", "title: Albert Einstein\nAlbert Einstein was a theoretical physicist who developed the theory of relativity.")) orelse return error.ExpectedPredicate;
    defer parsed.deinit(allocator);
    try std.testing.expect(parsed.predicate != null);
    try std.testing.expect(std.mem.indexOf(u8, parsed.predicate.?.object, "physicist") != null);
}

test "parser extracts ontological primitives from audit request" {
    const allocator = std.testing.allocator;
    const primitives = try parseOntologyPrimitives(allocator, "audit TrackManager.cpp", "");
    defer intent_grounding.freeOntologicalPrimitives(allocator, primitives);

    try std.testing.expect(intent_grounding.hasOntologyConcept(primitives, .target_system_component));
    try std.testing.expect(intent_grounding.hasOntologyConcept(primitives, .action_verify_integrity));
    try std.testing.expect(intent_grounding.hasOntologyConcept(primitives, .constraint_local_axioms));
}
