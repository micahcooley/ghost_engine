const std = @import("std");
const vsa = @import("vsa_core.zig");
const rune_lattice = @import("rune_lattice.zig");
const concept_index = @import("concept_index.zig");
const semantic_encoder = @import("semantic_encoder.zig");
const triad = @import("triad.zig");

// ══════════════════════════════════════════════════════════════════════════
//  INTENT RESOLVER: Conversational Intelligence for the Rune Lattice
// ══════════════════════════════════════════════════════════════════════════
//
// When the engine receives a query, three outcomes are possible:
//
//   1. CONFIDENT MATCH (distance < CONFIDENT_TAU):
//      → Return the answer directly. No ambiguity.
//
//   2. AMBIGUOUS (distance < AMBIGUOUS_TAU but top-N are equidistant):
//      → The engine knows several related things but can't pick one.
//      → Generate clarifying questions from the nearest concepts.
//
//   3. UNKNOWN (distance > AMBIGUOUS_TAU):
//      → The engine has no relevant knowledge.
//      → Admit ignorance. Suggest what it DOES know about.
//
// The entropy of the top-N distances drives the ambiguity detection:
//   - Low entropy (one match much closer than others) → confident
//   - High entropy (many matches at similar distances) → ambiguous
//
// This module does NOT generate English prose from scratch. It constructs
// structured responses from concept labels, snippets, and templates.
// ══════════════════════════════════════════════════════════════════════════

/// Distance threshold for a confident match. Below this, the engine
/// trusts the result without asking for clarification.
/// ~700 resonance = ~324 hamming distance from the internal constant.
pub const CONFIDENT_TAU: u16 = 490;

/// Distance threshold for ambiguity. Above this, the engine admits
/// ignorance. Between CONFIDENT_TAU and AMBIGUOUS_TAU, it probes.
pub const AMBIGUOUS_TAU: u16 = 530;

/// Entropy threshold for ambiguity detection. If the normalized entropy
/// of the top-N distances exceeds this, the query is ambiguous.
pub const ENTROPY_THRESHOLD: f32 = 0.85;

/// Number of nearest neighbors to examine for ambiguity detection.
pub const TOP_N: usize = 8;

/// Minimum number of tokens in a query to consider it non-trivial.
pub const MIN_QUERY_TOKENS: usize = 2;

pub const IntentClass = enum {
    /// High confidence — return the answer.
    confident,
    /// Multiple plausible matches — ask for clarification.
    ambiguous,
    /// No relevant knowledge — admit ignorance.
    unknown,
    /// Query is too vague/short — ask the user to elaborate.
    underspecified,
};

pub const NearConcept = struct {
    slot: u32,
    distance: u16,
    label: []const u8,
    snippet: []const u8,
    domain_tag: []const u8,
};

pub const IntentResolution = struct {
    /// Classification of the query intent.
    class: IntentClass,
    /// Normalized confidence score (0.0 = unknown, 1.0 = perfect match).
    confidence: f32,
    /// Normalized entropy of top-N distances (0.0 = single clear winner, 1.0 = uniform).
    entropy: f32,
    /// Nearest concepts found during search.
    nearest: []NearConcept,
    /// Best matching slot (if confident or ambiguous).
    best_slot: ?u32,
    /// Structured response text (answer, question, or admission of ignorance).
    response_text: []u8,
    /// Clarifying questions (populated when class == .ambiguous or .underspecified).
    clarifying_questions: [][]u8,

    pub fn deinit(self: *IntentResolution, allocator: std.mem.Allocator) void {
        allocator.free(self.nearest);
        allocator.free(self.response_text);
        for (self.clarifying_questions) |q| allocator.free(q);
        allocator.free(self.clarifying_questions);
        self.* = undefined;
    }
};

/// Resolve the intent of a natural language query against the Rune Lattice.
///
/// This is the main entry point for conversational intelligence. It:
///   1. Encodes the query string to a HyperVector.
///   2. Searches the lattice for the top-N nearest concepts.
///   3. Computes confidence and entropy metrics.
///   4. Classifies the intent (confident / ambiguous / unknown / underspecified).
///   5. Generates a structured response with clarifying questions if needed.
pub fn resolveIntent(
    allocator: std.mem.Allocator,
    query: []const u8,
    lattice: *const rune_lattice.RuneLattice,
    index: *const concept_index.ConceptIndex,
) !IntentResolution {
    // Step 0: Check for underspecified queries
    const token_count = countTokens(query);
    if (token_count < MIN_QUERY_TOKENS) {
        return buildUnderspecified(allocator, query, lattice, index);
    }

    // Step 1: Encode query
    const query_vec = semantic_encoder.encodeConceptString(query);

    // Step 2: Find top-N nearest concepts
    var nearest = std.ArrayList(NearConcept).init(allocator);
    errdefer nearest.deinit();

    var i: u32 = 0;
    while (i < lattice.capacity) : (i += 1) {
        if (lattice.tags[i] == 0) continue;
        const distance = vsa.hammingDistance(query_vec, lattice.vectors[i]);
        const entry = index.lookupBySlot(i) orelse continue;

        if (nearest.items.len < TOP_N) {
            try nearest.append(.{
                .slot = i,
                .distance = distance,
                .label = entry.label,
                .snippet = entry.snippet,
                .domain_tag = entry.domain_tag,
            });
            std.mem.sort(NearConcept, nearest.items, {}, nearLessThan);
        } else if (distance < nearest.items[nearest.items.len - 1].distance) {
            nearest.items[nearest.items.len - 1] = .{
                .slot = i,
                .distance = distance,
                .label = entry.label,
                .snippet = entry.snippet,
                .domain_tag = entry.domain_tag,
            };
            std.mem.sort(NearConcept, nearest.items, {}, nearLessThan);
        }
    }

    if (nearest.items.len == 0) {
        return buildUnknown(allocator, query, &nearest);
    }

    // Step 3: Compute metrics
    const best_distance = nearest.items[0].distance;
    const confidence = distanceToConfidence(best_distance);
    const entropy = computeEntropy(nearest.items);

    // Step 4: Classify
    const class: IntentClass = if (best_distance <= CONFIDENT_TAU and entropy < ENTROPY_THRESHOLD)
        .confident
    else if (best_distance <= AMBIGUOUS_TAU)
        .ambiguous
    else
        .unknown;

    // Step 5: Build response
    return switch (class) {
        .confident => buildConfident(allocator, query, &nearest, confidence, entropy),
        .ambiguous => buildAmbiguous(allocator, query, &nearest, confidence, entropy),
        .unknown => buildUnknown(allocator, query, &nearest),
        .underspecified => buildUnderspecified(allocator, query, lattice, index),
    };
}

// ── Metric Computation ──

fn distanceToConfidence(distance: u16) f32 {
    // Map Hamming distance to confidence: 0 = 1.0, 512 = 0.0
    if (distance >= 512) return 0.0;
    return 1.0 - @as(f32, @floatFromInt(distance)) / 512.0;
}

fn computeEntropy(nearest: []const NearConcept) f32 {
    if (nearest.len <= 1) return 0.0;

    // Convert distances to a probability distribution
    var sum: f32 = 0.0;
    for (nearest) |n| {
        // Invert distances: closer = higher weight
        const weight = 1.0 / (@as(f32, @floatFromInt(n.distance)) + 1.0);
        sum += weight;
    }
    if (sum == 0.0) return 1.0;

    // Shannon entropy
    var h: f32 = 0.0;
    for (nearest) |n| {
        const p = (1.0 / (@as(f32, @floatFromInt(n.distance)) + 1.0)) / sum;
        if (p > 0.0) {
            h -= p * @log(p);
        }
    }

    // Normalize to [0, 1] by dividing by max entropy (log N)
    const max_h = @log(@as(f32, @floatFromInt(nearest.len)));
    if (max_h == 0.0) return 0.0;
    return @min(h / max_h, 1.0);
}

// ── Response Builders ──

fn buildConfident(
    allocator: std.mem.Allocator,
    query: []const u8,
    nearest: *std.ArrayList(NearConcept),
    confidence: f32,
    entropy: f32,
) !IntentResolution {
    const best = nearest.items[0];
    var text = std.ArrayList(u8).init(allocator);
    errdefer text.deinit();
    const w = text.writer();

    try w.print("[CONFIDENT] (confidence: {d:.0}%, entropy: {d:.2})\n\n", .{ confidence * 100, entropy });
    try w.print("Query: \"{s}\"\n\n", .{query});
    try w.print("Best match: [{s}] \"{s}\" (distance: {d} bits)\n", .{ best.domain_tag, best.label, best.distance });
    if (best.snippet.len > 0) {
        const snippet_len = @min(best.snippet.len, 300);
        try w.print("\n  \"{s}\"\n", .{best.snippet[0..snippet_len]});
    }

    // Show related concepts
    if (nearest.items.len > 1) {
        try w.writeAll("\nRelated concepts:\n");
        for (nearest.items[1..@min(nearest.items.len, 4)]) |n| {
            try w.print("  • [{s}] \"{s}\" (distance: {d})\n", .{ n.domain_tag, n.label, n.distance });
        }
    }

    const best_slot = nearest.items[0].slot;
    const owned_nearest = try nearest.toOwnedSlice();

    return .{
        .class = .confident,
        .confidence = confidence,
        .entropy = entropy,
        .nearest = owned_nearest,
        .best_slot = best_slot,
        .response_text = try text.toOwnedSlice(),
        .clarifying_questions = try allocator.alloc([]u8, 0),
    };
}

fn buildAmbiguous(
    allocator: std.mem.Allocator,
    query: []const u8,
    nearest: *std.ArrayList(NearConcept),
    confidence: f32,
    entropy: f32,
) !IntentResolution {
    var text = std.ArrayList(u8).init(allocator);
    errdefer text.deinit();
    const w = text.writer();

    try w.print("[AMBIGUOUS] (confidence: {d:.0}%, entropy: {d:.2})\n\n", .{ confidence * 100, entropy });
    try w.print("Query: \"{s}\"\n\n", .{query});
    try w.writeAll("I found several relevant concepts but need clarification.\n");
    try w.writeAll("Did you mean one of these?\n\n");

    for (nearest.items[0..@min(nearest.items.len, 5)], 0..) |n, idx| {
        try w.print("  [{d}] [{s}] \"{s}\" (distance: {d})\n", .{ idx + 1, n.domain_tag, n.label, n.distance });
        if (n.snippet.len > 0) {
            const snippet_len = @min(n.snippet.len, 100);
            try w.print("      → \"{s}\"\n", .{n.snippet[0..snippet_len]});
        }
    }

    // Generate clarifying questions from the nearest concepts
    var questions = std.ArrayList([]u8).init(allocator);
    errdefer {
        for (questions.items) |q| allocator.free(q);
        questions.deinit();
    }

    // Extract unique domain tags to ask about domain
    var seen_domains = std.StringHashMap(void).init(allocator);
    defer seen_domains.deinit();
    var domain_count: usize = 0;
    for (nearest.items) |n| {
        if (!seen_domains.contains(n.domain_tag) and n.domain_tag.len > 0) {
            try seen_domains.put(n.domain_tag, {});
            domain_count += 1;
        }
    }

    if (domain_count > 1) {
        try questions.append(try std.fmt.allocPrint(allocator,
            "Which domain are you asking about? I have knowledge across {d} domains.",
            .{domain_count},
        ));
    }

    // Ask about specificity based on top matches
    if (nearest.items.len >= 2) {
        try questions.append(try std.fmt.allocPrint(allocator,
            "Are you asking about \"{s}\" or \"{s}\"?",
            .{ nearest.items[0].label, nearest.items[1].label },
        ));
    }

    // Generic fallback
    try questions.append(try allocator.dupe(u8,
        "Can you be more specific about what aspect you're interested in?",
    ));

    const best_slot = nearest.items[0].slot;
    const owned_nearest = try nearest.toOwnedSlice();

    return .{
        .class = .ambiguous,
        .confidence = confidence,
        .entropy = entropy,
        .nearest = owned_nearest,
        .best_slot = best_slot,
        .response_text = try text.toOwnedSlice(),
        .clarifying_questions = try questions.toOwnedSlice(),
    };
}

fn buildUnknown(
    allocator: std.mem.Allocator,
    query: []const u8,
    nearest: *std.ArrayList(NearConcept),
) !IntentResolution {
    var text = std.ArrayList(u8).init(allocator);
    errdefer text.deinit();
    const w = text.writer();

    try w.print("[UNKNOWN] (no concepts within threshold)\n\n", .{});
    try w.print("Query: \"{s}\"\n\n", .{query});
    try w.writeAll("I don't have knowledge relevant to this query.\n");

    if (nearest.items.len > 0) {
        try w.writeAll("\nThe closest things I know about:\n");
        for (nearest.items[0..@min(nearest.items.len, 3)]) |n| {
            try w.print("  • [{s}] \"{s}\" (distance: {d} — far)\n", .{ n.domain_tag, n.label, n.distance });
        }
        try w.writeAll("\nTry asking about one of these topics, or ingest new data.\n");
    }

    var questions = std.ArrayList([]u8).init(allocator);
    errdefer {
        for (questions.items) |q| allocator.free(q);
        questions.deinit();
    }
    try questions.append(try allocator.dupe(u8,
        "This topic isn't in my lattice. Would you like to ingest documents about it?",
    ));

    return .{
        .class = .unknown,
        .confidence = 0.0,
        .entropy = 1.0,
        .nearest = try nearest.toOwnedSlice(),
        .best_slot = null,
        .response_text = try text.toOwnedSlice(),
        .clarifying_questions = try questions.toOwnedSlice(),
    };
}

fn buildUnderspecified(
    allocator: std.mem.Allocator,
    query: []const u8,
    lattice: *const rune_lattice.RuneLattice,
    index: *const concept_index.ConceptIndex,
) !IntentResolution {
    _ = lattice;
    var text = std.ArrayList(u8).init(allocator);
    errdefer text.deinit();
    const w = text.writer();

    try w.print("[UNDERSPECIFIED]\n\n", .{});
    try w.print("Query: \"{s}\"\n\n", .{query});
    try w.writeAll("Your query is too vague for me to search the lattice effectively.\n");

    // Suggest domains
    const domains = try index.allDomains(allocator);
    defer {
        for (domains) |d| allocator.free(d);
        allocator.free(domains);
    }

    if (domains.len > 0) {
        try w.writeAll("\nI have knowledge in these domains:\n");
        for (domains) |d| {
            try w.print("  • {s}\n", .{d});
        }
    }

    var questions = std.ArrayList([]u8).init(allocator);
    errdefer {
        for (questions.items) |q| allocator.free(q);
        questions.deinit();
    }
    try questions.append(try allocator.dupe(u8,
        "What topic or concept are you looking for? Try a more specific phrase.",
    ));
    if (domains.len > 0) {
        try questions.append(try std.fmt.allocPrint(allocator,
            "Which domain interests you? ({d} available)",
            .{domains.len},
        ));
    }

    return .{
        .class = .underspecified,
        .confidence = 0.0,
        .entropy = 1.0,
        .nearest = try allocator.alloc(NearConcept, 0),
        .best_slot = null,
        .response_text = try text.toOwnedSlice(),
        .clarifying_questions = try questions.toOwnedSlice(),
    };
}

// ── Helpers ──

fn countTokens(text: []const u8) usize {
    var count: usize = 0;
    var in_word = false;
    for (text) |c| {
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            if (in_word) {
                count += 1;
                in_word = false;
            }
        } else {
            in_word = true;
        }
    }
    if (in_word) count += 1;
    return count;
}

fn nearLessThan(_: void, a: NearConcept, b: NearConcept) bool {
    return a.distance < b.distance;
}

// ══════════════════════════════════════════════════════════════════════════
//  TESTS
// ══════════════════════════════════════════════════════════════════════════

test "countTokens" {
    try std.testing.expectEqual(@as(usize, 0), countTokens(""));
    try std.testing.expectEqual(@as(usize, 1), countTokens("hello"));
    try std.testing.expectEqual(@as(usize, 3), countTokens("how are you"));
    try std.testing.expectEqual(@as(usize, 1), countTokens("  hello  "));
}

test "distanceToConfidence" {
    try std.testing.expectEqual(@as(f32, 1.0), distanceToConfidence(0));
    try std.testing.expectEqual(@as(f32, 0.0), distanceToConfidence(512));
    try std.testing.expect(distanceToConfidence(256) > 0.4);
    try std.testing.expect(distanceToConfidence(256) < 0.6);
}

test "computeEntropy uniform distances" {
    // All same distance → high entropy
    const uniform = [_]NearConcept{
        .{ .slot = 0, .distance = 400, .label = "a", .snippet = "", .domain_tag = "" },
        .{ .slot = 1, .distance = 400, .label = "b", .snippet = "", .domain_tag = "" },
        .{ .slot = 2, .distance = 400, .label = "c", .snippet = "", .domain_tag = "" },
    };
    const e = computeEntropy(&uniform);
    try std.testing.expect(e > 0.95); // Should be near 1.0
}

test "computeEntropy one clear winner" {
    // One very close, rest far → low entropy
    const skewed = [_]NearConcept{
        .{ .slot = 0, .distance = 100, .label = "winner", .snippet = "", .domain_tag = "" },
        .{ .slot = 1, .distance = 500, .label = "far1", .snippet = "", .domain_tag = "" },
        .{ .slot = 2, .distance = 500, .label = "far2", .snippet = "", .domain_tag = "" },
    };
    const e = computeEntropy(&skewed);
    try std.testing.expect(e < 0.7); // Should be well below threshold
}

test "resolveIntent underspecified for single-word query" {
    var lattice = try rune_lattice.RuneLattice.init(std.testing.allocator, 256, null);
    defer lattice.deinit();
    var idx = concept_index.ConceptIndex.init(std.testing.allocator);
    defer idx.deinit();

    var result = try resolveIntent(std.testing.allocator, "hi", &lattice, &idx);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(IntentClass.underspecified, result.class);
    try std.testing.expect(result.clarifying_questions.len > 0);
}
