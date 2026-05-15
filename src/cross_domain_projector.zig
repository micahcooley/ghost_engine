const std = @import("std");
const vsa = @import("vsa_core.zig");
const rune_lattice = @import("rune_lattice.zig");
const concept_index = @import("concept_index.zig");
const semantic_encoder = @import("semantic_encoder.zig");
const triad = @import("triad.zig");

// ══════════════════════════════════════════════════════════════════════════
//  CROSS-DOMAIN PROJECTOR: The Dark Space Invention Engine
// ══════════════════════════════════════════════════════════════════════════
//
// The ultimate test of the VSA Lattice: can it invent a solution by
// mathematically combining two completely unrelated fields?
//
// Architecture:
//   1. Select representative vectors from each domain.
//   2. Create a Candidate Rune: candidate = bind(domain_A_vec, domain_B_vec)
//      This vector occupies "Dark Space" — a region of the 1024-bit lattice
//      that no explicitly ingested concept inhabits.
//   3. Search the lattice for the nearest verified concepts to the candidate.
//   4. Unbind: novel_context = bind(candidate, nearest_verified)
//      This produces a vector that is the "gap" between the candidate and
//      the nearest known concept.
//   5. Decode: Find the closest known concepts to the novel context,
//      constructing a structured explanation from the concept index.
//
// The output is NOT flowing prose — it's a structured mapping of concepts
// from both domains with a novelty score. Template-based explanation
// generation assembles these into a readable format.
// ══════════════════════════════════════════════════════════════════════════

/// Minimum novelty score (0.0 - 1.0) for a cross-domain projection to
/// be considered "genuinely novel" rather than a trivial retrieval.
pub const MIN_NOVELTY_SCORE: f32 = 0.3;

/// Maximum number of nearest concepts to retrieve during decoding.
pub const MAX_DECODE_NEIGHBORS: usize = 8;

/// A candidate rune produced by binding two domain vectors.
pub const CandidateRune = struct {
    /// The composite vector: domain_A ⊗ domain_B
    vector: vsa.HyperVector,
    /// Source vector from domain A.
    source_a: vsa.HyperVector,
    /// Source vector from domain B.
    source_b: vsa.HyperVector,
    /// Label of the domain A concept.
    label_a: []const u8,
    /// Label of the domain B concept.
    label_b: []const u8,
    /// Domain tag of domain A.
    domain_a: []const u8,
    /// Domain tag of domain B.
    domain_b: []const u8,
};

/// A decoded cross-domain explanation.
pub const CrossDomainExplanation = struct {
    /// The candidate rune that was decoded.
    candidate: CandidateRune,
    /// Nearest verified concepts from the lattice.
    nearest_concepts: []NearestConcept,
    /// Novelty score: 0.0 = trivial retrieval, 1.0 = maximally novel.
    novelty_score: f32,
    /// Template-generated explanation text.
    explanation_text: []u8,

    pub fn deinit(self: *CrossDomainExplanation, allocator: std.mem.Allocator) void {
        allocator.free(self.nearest_concepts);
        allocator.free(self.explanation_text);
        self.* = undefined;
    }
};

pub const NearestConcept = struct {
    slot: u32,
    distance: u16,
    label: []const u8,
    snippet: []const u8,
    domain_tag: []const u8,
    rank: u8,
};

/// Project a cross-domain candidate rune from two domain vectors.
///
/// This creates a vector in "Dark Space" — the unexplored region of the
/// 1024-bit lattice between two known domains.
pub fn projectCrossDomain(
    source_a: vsa.HyperVector,
    source_b: vsa.HyperVector,
    label_a: []const u8,
    label_b: []const u8,
    domain_a: []const u8,
    domain_b: []const u8,
) CandidateRune {
    // XOR-bind the two domain vectors to create a composite
    const candidate = vsa.bind(source_a, source_b);

    return .{
        .vector = candidate,
        .source_a = source_a,
        .source_b = source_b,
        .label_a = label_a,
        .label_b = label_b,
        .domain_a = domain_a,
        .domain_b = domain_b,
    };
}

/// Project multiple candidate runes by combining representative vectors
/// from two domains. Takes up to `max_candidates` pairs.
pub fn projectCrossDomainBatch(
    allocator: std.mem.Allocator,
    lattice: *const rune_lattice.RuneLattice,
    index: *const concept_index.ConceptIndex,
    domain_a: []const u8,
    domain_b: []const u8,
    max_candidates: usize,
) ![]CandidateRune {
    // Get representative slots from each domain
    const slots_a = try index.domainEntries(allocator, domain_a);
    defer allocator.free(slots_a);
    const slots_b = try index.domainEntries(allocator, domain_b);
    defer allocator.free(slots_b);

    if (slots_a.len == 0 or slots_b.len == 0) return &.{};

    var results = std.ArrayList(CandidateRune).init(allocator);
    errdefer results.deinit();

    // Create candidates from the top N vectors of each domain
    const limit_a = @min(slots_a.len, max_candidates);
    const limit_b = @min(slots_b.len, max_candidates);

    for (slots_a[0..limit_a]) |slot_a| {
        if (slot_a >= lattice.capacity) continue;
        if (lattice.tags[slot_a] == 0) continue;
        const entry_a = index.lookupBySlot(slot_a) orelse continue;

        for (slots_b[0..limit_b]) |slot_b| {
            if (slot_b >= lattice.capacity) continue;
            if (lattice.tags[slot_b] == 0) continue;
            const entry_b = index.lookupBySlot(slot_b) orelse continue;

            if (results.items.len >= max_candidates) break;

            try results.append(projectCrossDomain(
                lattice.vectors[slot_a],
                lattice.vectors[slot_b],
                entry_a.label,
                entry_b.label,
                domain_a,
                domain_b,
            ));
        }
        if (results.items.len >= max_candidates) break;
    }

    return results.toOwnedSlice();
}

/// Decode a candidate rune by finding its nearest verified concepts in
/// the lattice and generating a structured explanation.
pub fn decodeCandidateRune(
    allocator: std.mem.Allocator,
    candidate: CandidateRune,
    lattice: *const rune_lattice.RuneLattice,
    index: *const concept_index.ConceptIndex,
) !CrossDomainExplanation {
    // Find nearest verified concepts to the candidate vector
    var neighbors = std.ArrayList(NearestConcept).init(allocator);
    errdefer neighbors.deinit();

    var i: u32 = 0;
    while (i < lattice.capacity) : (i += 1) {
        if (lattice.tags[i] == 0) continue;

        const distance = vsa.hammingDistance(candidate.vector, lattice.vectors[i]);
        const entry = index.lookupBySlot(i) orelse continue;

        // Keep the closest N concepts
        if (neighbors.items.len < MAX_DECODE_NEIGHBORS) {
            try neighbors.append(.{
                .slot = i,
                .distance = distance,
                .label = entry.label,
                .snippet = entry.snippet,
                .domain_tag = entry.domain_tag,
                .rank = entry.rank,
            });
            // Sort by distance
            std.mem.sort(NearestConcept, neighbors.items, {}, neighborLessThan);
        } else if (distance < neighbors.items[neighbors.items.len - 1].distance) {
            neighbors.items[neighbors.items.len - 1] = .{
                .slot = i,
                .distance = distance,
                .label = entry.label,
                .snippet = entry.snippet,
                .domain_tag = entry.domain_tag,
                .rank = entry.rank,
            };
            std.mem.sort(NearestConcept, neighbors.items, {}, neighborLessThan);
        }
    }

    // Compute novelty score
    const novelty = computeNoveltyScore(candidate, neighbors.items);

    // Generate template-based explanation
    const explanation = try generateExplanation(allocator, candidate, neighbors.items, novelty);

    return .{
        .candidate = candidate,
        .nearest_concepts = try neighbors.toOwnedSlice(),
        .novelty_score = novelty,
        .explanation_text = explanation,
    };
}

/// Compute novelty score for a candidate rune.
///
/// Novelty is based on:
///   1. Mean distance to nearest concepts (further = more novel)
///   2. Domain diversity of nearest concepts (more domains = more novel)
///   3. Distance from both source domains (should be far from both)
///
/// Returns 0.0 (trivial retrieval) to 1.0 (maximally novel).
fn computeNoveltyScore(candidate: CandidateRune, neighbors: []const NearestConcept) f32 {
    if (neighbors.len == 0) return 1.0; // Nothing to compare — maximally novel

    // Factor 1: Mean distance to nearest neighbors (normalized to 0-1)
    var sum_dist: u32 = 0;
    for (neighbors) |n| {
        sum_dist += n.distance;
    }
    const mean_dist = @as(f32, @floatFromInt(sum_dist)) / @as(f32, @floatFromInt(neighbors.len));
    const distance_novelty = @min(mean_dist / 512.0, 1.0); // 512 = random baseline

    // Factor 2: Domain diversity (count unique domains)
    var domain_count: u32 = 0;
    var seen_a = false;
    var seen_b = false;
    var seen_other = false;
    for (neighbors) |n| {
        if (std.mem.eql(u8, n.domain_tag, candidate.domain_a)) {
            if (!seen_a) {
                seen_a = true;
                domain_count += 1;
            }
        } else if (std.mem.eql(u8, n.domain_tag, candidate.domain_b)) {
            if (!seen_b) {
                seen_b = true;
                domain_count += 1;
            }
        } else {
            if (!seen_other) {
                seen_other = true;
                domain_count += 1;
            }
        }
    }
    const diversity_novelty = if (domain_count >= 2) @as(f32, 0.8) else @as(f32, 0.3);

    // Factor 3: Distance from source vectors (should be far from both)
    const dist_a = @as(f32, @floatFromInt(vsa.hammingDistance(candidate.vector, candidate.source_a)));
    const dist_b = @as(f32, @floatFromInt(vsa.hammingDistance(candidate.vector, candidate.source_b)));
    const source_novelty = @min((dist_a + dist_b) / 1024.0, 1.0);

    // Weighted combination
    return distance_novelty * 0.4 + diversity_novelty * 0.3 + source_novelty * 0.3;
}

/// Generate a template-based explanation from the decoded candidate rune.
fn generateExplanation(
    allocator: std.mem.Allocator,
    candidate: CandidateRune,
    neighbors: []const NearestConcept,
    novelty: f32,
) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    try w.writeAll("=== CROSS-DOMAIN PROJECTION ===\n\n");
    try w.print("Domain A: [{s}] \"{s}\"\n", .{ candidate.domain_a, candidate.label_a });
    try w.print("Domain B: [{s}] \"{s}\"\n", .{ candidate.domain_b, candidate.label_b });
    try w.print("Novelty Score: {d:.2}\n\n", .{novelty});

    if (novelty >= MIN_NOVELTY_SCORE) {
        try w.writeAll("PROJECTION RESULT:\n");
        try w.print("  The concept of [{s}: {s}] applied to [{s}: {s}] suggests:\n\n", .{
            candidate.domain_a, candidate.label_a,
            candidate.domain_b, candidate.label_b,
        });

        for (neighbors, 0..) |n, idx| {
            try w.print("  [{d}] [{s}] \"{s}\" (distance: {d} bits, rank: {d})\n", .{
                idx + 1,
                n.domain_tag,
                n.label,
                n.distance,
                n.rank,
            });
            if (n.snippet.len > 0) {
                const max_snippet = @min(n.snippet.len, 120);
                try w.print("      → \"{s}\"\n", .{n.snippet[0..max_snippet]});
            }
        }

        try w.writeAll("\n  SYNTHESIS:\n");
        if (neighbors.len >= 2) {
            // Group neighbors by domain to find the cross-domain bridge
            var closest_a: ?NearestConcept = null;
            var closest_b: ?NearestConcept = null;
            for (neighbors) |n| {
                if (std.mem.eql(u8, n.domain_tag, candidate.domain_a)) {
                    if (closest_a == null) closest_a = n;
                } else if (std.mem.eql(u8, n.domain_tag, candidate.domain_b)) {
                    if (closest_b == null) closest_b = n;
                }
            }

            try w.print("    By binding [{s}] with [{s}], the Dark Space vector\\n", .{
                candidate.label_a, candidate.label_b,
            });
            try w.writeAll("    lands nearest to these cross-domain concepts:\n\n");

            if (closest_a) |ca| {
                const snip_len = @min(ca.snippet.len, 80);
                try w.print("    FROM [{s}]: \"{s}\" ({d} bits)\n", .{
                    ca.domain_tag, ca.label, ca.distance,
                });
                if (snip_len > 0) try w.print("      \"{s}\"\n", .{ca.snippet[0..snip_len]});
            }
            if (closest_b) |cb| {
                const snip_len = @min(cb.snippet.len, 80);
                try w.print("    FROM [{s}]: \"{s}\" ({d} bits)\n", .{
                    cb.domain_tag, cb.label, cb.distance,
                });
                if (snip_len > 0) try w.print("      \"{s}\"\n", .{cb.snippet[0..snip_len]});
            }

            try w.writeAll("\n    INVENTION HYPOTHESIS:\n");
            if (closest_a != null and closest_b != null) {
                try w.print("      The [{s}] concept of [{s}] and the [{s}] concept of\n", .{
                    closest_a.?.domain_tag, closest_a.?.label,
                    closest_b.?.domain_tag,
                });
                try w.print("      [{s}] share structural similarity in the lattice.\n", .{
                    closest_b.?.label,
                });
                try w.print("      A [{s}]-inspired approach to [{s}] would apply the\n", .{
                    candidate.domain_a, candidate.domain_b,
                });
                try w.print("      mechanisms of [{s}] to the constraints of [{s}],\n", .{
                    closest_a.?.label, closest_b.?.label,
                });
                try w.writeAll("      creating a hybrid system that neither domain achieves alone.\n");
            } else {
                try w.writeAll("      The binding reveals proximity between concepts that\n");
                try w.writeAll("      have never been combined. Further corpus ingestion\n");
                try w.writeAll("      may reveal deeper structural analogies.\n");
            }
        } else if (neighbors.len == 1) {
            try w.print("    The nearest known concept [{s}] provides a partial bridge\\n", .{
                neighbors[0].label,
            });
            try w.writeAll("    between the two domains, but deeper exploration is needed.\n");
        }
    } else {
        try w.writeAll("PROJECTION RESULT: LOW NOVELTY\n");
        try w.writeAll("  The cross-domain binding produced a vector too close to existing\n");
        try w.writeAll("  concepts. The projection is a trivial retrieval, not an invention.\n");
        try w.writeAll("  Consider using more specific or orthogonal domain concepts.\n");
    }

    try w.writeAll("\n=== END PROJECTION ===\n");

    return out.toOwnedSlice();
}

fn neighborLessThan(_: void, a: NearestConcept, b: NearestConcept) bool {
    return a.distance < b.distance;
}

// ══════════════════════════════════════════════════════════════════════════
//  TESTS
// ══════════════════════════════════════════════════════════════════════════

test "projectCrossDomain creates a Dark Space vector" {
    const bio_vec = semantic_encoder.encodeConceptString("Synaptic vesicle release");
    const traffic_vec = semantic_encoder.encodeConceptString("Traffic intersection routing");

    const candidate = projectCrossDomain(
        bio_vec,
        traffic_vec,
        "Synaptic vesicle release",
        "Traffic intersection routing",
        "biology",
        "traffic",
    );

    // The candidate should be far from both sources (XOR property)
    const dist_a = vsa.hammingDistance(candidate.vector, bio_vec);
    const dist_b = vsa.hammingDistance(candidate.vector, traffic_vec);

    // XOR of two independent vectors should produce a vector ~512 bits from each
    try std.testing.expect(dist_a > 300);
    try std.testing.expect(dist_b > 300);
}

test "decodeCandidateRune produces explanation with novelty score" {
    var lattice = try rune_lattice.RuneLattice.init(std.testing.allocator, 256, null);
    defer lattice.deinit();
    var index = concept_index.ConceptIndex.init(std.testing.allocator);
    defer index.deinit();

    // Populate with some concepts from both domains
    const bio_vec = semantic_encoder.encodeConceptString("Synaptic firing patterns");
    const slot_bio = lattice.observe(bio_vec, 0x1, 1000) orelse return error.LatticeFull;
    try index.addEntry("Synaptic firing", slot_bio, "bio.txt", 0, 50, "biology", 1, "Neurons fire in bursts based on calcium levels");
    lattice.verify(slot_bio, 1000);

    const traffic_vec = semantic_encoder.encodeConceptString("Traffic signal timing");
    const slot_traffic = lattice.observe(traffic_vec, 0x2, 1000) orelse return error.LatticeFull;
    try index.addEntry("Signal timing", slot_traffic, "traffic.txt", 0, 50, "traffic", 1, "Traffic lights cycle through phases based on demand");
    lattice.verify(slot_traffic, 1000);

    // Create cross-domain candidate
    const candidate = projectCrossDomain(
        bio_vec,
        traffic_vec,
        "Synaptic firing",
        "Signal timing",
        "biology",
        "traffic",
    );

    // Decode
    var explanation = try decodeCandidateRune(std.testing.allocator, candidate, &lattice, &index);
    defer explanation.deinit(std.testing.allocator);

    // Should have found some nearest concepts
    try std.testing.expect(explanation.nearest_concepts.len > 0);

    // Novelty score should be positive
    try std.testing.expect(explanation.novelty_score > 0.0);

    // Explanation text should be non-empty
    try std.testing.expect(explanation.explanation_text.len > 0);
}

test "computeNoveltyScore returns high for genuinely novel projections" {
    const bio_vec = semantic_encoder.encodeConceptString("DNA replication");
    const traffic_vec = semantic_encoder.encodeConceptString("Highway merge lanes");

    const candidate = projectCrossDomain(
        bio_vec,
        traffic_vec,
        "DNA replication",
        "Highway merge",
        "biology",
        "traffic",
    );

    // With no neighbors, novelty should be maximal
    const novelty_empty = computeNoveltyScore(candidate, &.{});
    try std.testing.expectEqual(@as(f32, 1.0), novelty_empty);

    // With a distant neighbor, novelty should still be high
    const far_neighbors = [_]NearestConcept{.{
        .slot = 0,
        .distance = 480,
        .label = "some concept",
        .snippet = "some text",
        .domain_tag = "other",
        .rank = 3,
    }};
    const novelty_far = computeNoveltyScore(candidate, &far_neighbors);
    try std.testing.expect(novelty_far > 0.5);
}
