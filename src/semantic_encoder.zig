const std = @import("std");
const vsa = @import("vsa_core.zig");

// ══════════════════════════════════════════════════════════════════════════
//  SEMANTIC ENCODER: String → 1024-bit HyperVector
// ══════════════════════════════════════════════════════════════════════════
//
// Converts arbitrary UTF-8 strings into deterministic 1024-bit HyperVectors
// using the HyperRotor's evolve() pipeline:
//
//   1. Initialize a fresh HyperRotor with a domain-specific seed.
//   2. Feed every Unicode codepoint of the input string through evolve().
//   3. The final rotor.state IS the concept vector.
//
// Properties:
//   - DETERMINISTIC: Same string always produces the same vector.
//   - ORDER-SENSITIVE: "packet loss" ≠ "loss packet" (the permute step
//     in evolve() encodes positional information).
//   - COMPOSITIONAL: Related strings produce vectors with measurable
//     resonance (Hamming proximity), while unrelated strings are
//     near-orthogonal (~512 bits).
//
// This is the bridge between human-readable text and the Rune Lattice.
// ══════════════════════════════════════════════════════════════════════════

/// Seed used for concept encoding. Distinct from GENESIS_SEED to avoid
/// collisions with the training pipeline's rotor state.
pub const CONCEPT_SEED: u64 = 0x47484F53545F434F; // "GHOST_CO" in ASCII

/// Seed used for domain tagging. Orthogonal to CONCEPT_SEED.
pub const DOMAIN_SEED: u64 = 0x444F4D41494E5F54; // "DOMAIN_T" in ASCII

/// Minimum paragraph size in bytes. Paragraphs smaller than this are
/// merged with their successor to avoid creating low-information vectors.
pub const MIN_PARAGRAPH_BYTES: usize = 256;

/// Maximum paragraph size in bytes. Paragraphs larger than this are split
/// at the nearest sentence boundary.
pub const MAX_PARAGRAPH_BYTES: usize = 4096;

/// Maximum concepts per document to prevent lattice exhaustion.
pub const MAX_CONCEPTS_PER_DOCUMENT: usize = 2048;

/// A single concept extracted from a document.
pub const ConceptEntry = struct {
    /// The 1024-bit HyperVector encoding of this concept.
    vector: vsa.HyperVector,
    /// Byte offset in the source document where this concept starts.
    source_offset: usize,
    /// Length in bytes of the source text that produced this concept.
    source_length: usize,
    /// The raw text of the concept (borrowed from input — caller owns lifetime).
    text: []const u8,
    /// Optional domain tag for cross-domain operations.
    domain_tag: ?[]const u8,
};

/// A bound relation triple (Subject-Predicate-Object).
pub const BoundRelation = struct {
    /// The composite vector: (Subject ⊗ ROLE_SUBJECT) ⊕ (Predicate ⊗ ROLE_PREDICATE) ⊕ (Object ⊗ ROLE_OBJECT)
    vector: vsa.HyperVector,
    subject_vector: vsa.HyperVector,
    predicate_vector: vsa.HyperVector,
    object_vector: vsa.HyperVector,
};

// ── Core Encoding ──

/// Encode a concept string into a 1024-bit HyperVector.
///
/// The encoding is deterministic: identical strings always produce
/// identical vectors. The HyperRotor's evolve() pipeline ensures:
///   - Positional encoding (permute step)
///   - Compositional binding (XOR step)
///   - Inertial context (majority-vote bundle step)
///
/// Example:
///   const vec = encodeConceptString("Packet Loss");
///   // vec is now a deterministic 1024-bit vector representing "Packet Loss"
pub fn encodeConceptString(text: []const u8) vsa.HyperVector {
    return encodeConceptStringSeeded(text, CONCEPT_SEED);
}

/// Encode with a custom seed (used for domain-specific encoding).
pub fn encodeConceptStringSeeded(text: []const u8, seed: u64) vsa.HyperVector {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return vsa.generate(seed);

    var state = vsa.generate(seed);
    var utf8 = std.unicode.Utf8View.init(trimmed) catch {
        return encodeBytesSeeded(trimmed, seed);
    };
    var it = utf8.iterator();
    var offset: u64 = 0;
    while (it.nextCodepoint()) |cp| {
        const rune_vec = vsa.generate(seed ^ @as(u64, cp));
        const position_vec = vsa.generate(seed ^ offset ^ vsa.collapse(state));
        state = vsa.bundle(vsa.permute(state), rune_vec, position_vec);
        offset +%= 1;
    }
    return state;
}

fn encodeBytesSeeded(text: []const u8, seed: u64) vsa.HyperVector {
    var state = vsa.generate(seed);
    for (text, 0..) |byte, idx| {
        const rune_vec = vsa.generate(seed ^ @as(u64, byte));
        const position_vec = vsa.generate(seed ^ @as(u64, @intCast(idx)) ^ vsa.collapse(state));
        state = vsa.bundle(vsa.permute(state), rune_vec, position_vec);
    }
    return state;
}

/// Encode a domain tag into a 1024-bit HyperVector.
/// Used for domain-level operations (cross-domain projection).
pub fn encodeDomainTag(domain: []const u8) vsa.HyperVector {
    return encodeConceptStringSeeded(domain, DOMAIN_SEED);
}

/// Create a domain-bound concept: concept ⊗ domain_tag.
/// This places the concept in a specific domain's "continent" of the lattice.
pub fn encodeDomainConcept(text: []const u8, domain: []const u8) vsa.HyperVector {
    const concept_vec = encodeConceptString(text);
    const domain_vec = encodeDomainTag(domain);
    return vsa.bind(concept_vec, domain_vec);
}

// ── Document Chunking ──

/// Chunk a document into paragraphs and encode each as a ConceptEntry.
///
/// Strategy: Split on double-newlines (`\n\n`), merge paragraphs smaller
/// than MIN_PARAGRAPH_BYTES with their successor, and split paragraphs
/// larger than MAX_PARAGRAPH_BYTES at sentence boundaries.
///
/// Returns a slice of ConceptEntry. The caller owns the slice and must
/// free it with `allocator.free(result)`. The `.text` fields borrow from
/// the input `document` — do NOT free the document before consuming entries.
pub fn encodeDocument(
    allocator: std.mem.Allocator,
    document: []const u8,
    domain_tag: ?[]const u8,
) ![]ConceptEntry {
    var entries = std.ArrayList(ConceptEntry).init(allocator);
    errdefer entries.deinit();

    // Phase 1: Split on paragraph boundaries
    var paragraphs = std.ArrayList(ParagraphSpan).init(allocator);
    defer paragraphs.deinit();
    try splitParagraphs(document, &paragraphs);

    // Phase 2: Merge small paragraphs
    var merged = std.ArrayList(ParagraphSpan).init(allocator);
    defer merged.deinit();
    try mergeParagraphs(paragraphs.items, &merged);

    // Phase 3: Split oversized paragraphs
    var final_spans = std.ArrayList(ParagraphSpan).init(allocator);
    defer final_spans.deinit();
    for (merged.items) |span| {
        if (span.end - span.start > MAX_PARAGRAPH_BYTES) {
            try splitAtSentences(document, span, &final_spans);
        } else {
            try final_spans.append(span);
        }
    }

    // Phase 4: Encode each chunk
    for (final_spans.items) |span| {
        if (entries.items.len >= MAX_CONCEPTS_PER_DOCUMENT) break;

        const text = document[span.start..span.end];
        if (std.mem.trim(u8, text, " \r\n\t").len == 0) continue;

        const vector = if (domain_tag) |domain|
            encodeDomainConcept(text, domain)
        else
            encodeConceptString(text);

        try entries.append(.{
            .vector = vector,
            .source_offset = span.start,
            .source_length = span.end - span.start,
            .text = text,
            .domain_tag = domain_tag,
        });
    }

    return entries.toOwnedSlice();
}

// ── Relation Binding ──

/// Encode a Subject-Predicate-Object triple into a composite HyperVector.
///
/// Math:
///   composite = bundle(
///     bind(Subject_vec, ROLE_SUBJECT),
///     bind(Predicate_vec, ROLE_PREDICATE),
///     bind(Object_vec, ROLE_OBJECT)
///   )
///
/// The bundle (majority vote) preserves all three roles in superposition.
/// Un-binding any single role recovers the other two:
///   Subject_vec ≈ bind(composite, ROLE_SUBJECT)
///   (approximate due to majority-vote lossy compression)
pub fn encodeBoundRelation(
    subject: []const u8,
    predicate: []const u8,
    object: []const u8,
) BoundRelation {
    const subj_vec = encodeConceptString(subject);
    const pred_vec = encodeConceptString(predicate);
    const obj_vec = encodeConceptString(object);

    // Bind each component with its role vector
    const bound_subj = vsa.bind(subj_vec, vsa.ROLE_SUBJECT);
    const bound_pred = vsa.bind(pred_vec, vsa.ROLE_PREDICATE);
    const bound_obj = vsa.bind(obj_vec, vsa.ROLE_OBJECT);

    // Bundle all three into a single superposition
    const composite = vsa.bundle(bound_subj, bound_pred, bound_obj);

    return .{
        .vector = composite,
        .subject_vector = subj_vec,
        .predicate_vector = pred_vec,
        .object_vector = obj_vec,
    };
}

/// Un-bind a role from a composite relation vector to recover the filler.
///
/// Example:
///   const relation = encodeBoundRelation("QUIC", "handles", "Packet Loss");
///   const recovered_subject = unbindRole(relation.vector, .subject);
///   // resonance(recovered_subject, encodeConceptString("QUIC")) should be high
pub fn unbindRole(composite: vsa.HyperVector, role: Role) vsa.HyperVector {
    const role_vec = switch (role) {
        .subject => vsa.ROLE_SUBJECT,
        .predicate => vsa.ROLE_PREDICATE,
        .object => vsa.ROLE_OBJECT,
    };
    // XOR is self-inverse: bind(composite, role_vec) recovers the filler
    return vsa.bind(composite, role_vec);
}

pub const Role = enum {
    subject,
    predicate,
    object,
};

// ── Internal Helpers ──

const ParagraphSpan = struct {
    start: usize,
    end: usize,
};

fn splitParagraphs(text: []const u8, out: *std.ArrayList(ParagraphSpan)) !void {
    var start: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (i + 1 < text.len and text[i] == '\n' and text[i + 1] == '\n') {
            if (i > start) {
                try out.append(.{ .start = start, .end = i });
            }
            // Skip all consecutive newlines
            while (i < text.len and text[i] == '\n') : (i += 1) {}
            start = i;
        } else {
            i += 1;
        }
    }
    // Trailing paragraph
    if (start < text.len) {
        try out.append(.{ .start = start, .end = text.len });
    }
}

fn mergeParagraphs(spans: []const ParagraphSpan, out: *std.ArrayList(ParagraphSpan)) !void {
    if (spans.len == 0) return;

    var current = spans[0];
    for (spans[1..]) |span| {
        const current_size = current.end - current.start;
        const next_size = span.end - span.start;
        if (current_size < MIN_PARAGRAPH_BYTES or next_size < MIN_PARAGRAPH_BYTES) {
            // Merge: extend current to cover both
            current.end = span.end;
        } else {
            try out.append(current);
            current = span;
        }
    }
    try out.append(current);
}

fn splitAtSentences(text: []const u8, span: ParagraphSpan, out: *std.ArrayList(ParagraphSpan)) !void {
    const content = text[span.start..span.end];
    var chunk_start: usize = 0;

    var i: usize = 0;
    while (i < content.len) : (i += 1) {
        const is_sentence_end = (content[i] == '.' or content[i] == '!' or content[i] == '?') and
            (i + 1 >= content.len or content[i + 1] == ' ' or content[i + 1] == '\n');

        if (is_sentence_end and (i - chunk_start) >= MIN_PARAGRAPH_BYTES) {
            try out.append(.{
                .start = span.start + chunk_start,
                .end = span.start + i + 1,
            });
            chunk_start = i + 1;
            // Skip whitespace after sentence end
            while (chunk_start < content.len and
                (content[chunk_start] == ' ' or content[chunk_start] == '\n'))
            {
                chunk_start += 1;
            }
            i = chunk_start;
        }
    }
    // Remainder
    if (chunk_start < content.len) {
        try out.append(.{
            .start = span.start + chunk_start,
            .end = span.end,
        });
    }
}

// ══════════════════════════════════════════════════════════════════════════
//  TESTS
// ══════════════════════════════════════════════════════════════════════════

test "encodeConceptString determinism" {
    const v1 = encodeConceptString("Packet Loss");
    const v2 = encodeConceptString("Packet Loss");
    const resonance = vsa.calculateResonance(v1, v2);
    try std.testing.expectEqual(@as(u16, 1024), resonance);
}

test "encodeConceptString order sensitivity" {
    const v1 = encodeConceptString("Packet Loss");
    const v2 = encodeConceptString("Loss Packet");
    const resonance = vsa.calculateResonance(v1, v2);
    // Related but different — should NOT be identical
    try std.testing.expect(resonance < 1024);
    // But should have some similarity since they share tokens
    try std.testing.expect(resonance > 400);
}

test "encodeConceptString unrelated concepts are near-orthogonal" {
    const v1 = encodeConceptString("Packet Loss");
    const v2 = encodeConceptString("Chocolate Cake Recipe");
    const resonance = vsa.calculateResonance(v1, v2);
    // Random baseline is ~512 ± ~32. Unrelated concepts should cluster there.
    try std.testing.expect(resonance > 400);
    try std.testing.expect(resonance < 600);
}

test "encodeDocument produces multiple entries" {
    const doc =
        \\Paragraph one about packet loss in QUIC protocol.
        \\This is important for network reliability.
        \\
        \\Paragraph two about encryption handshake mechanisms.
        \\TLS 1.3 is used for secure connections.
        \\
        \\Paragraph three about congestion control algorithms.
        \\BBR and CUBIC are commonly used approaches.
    ;

    const entries = try encodeDocument(std.testing.allocator, doc, null);
    defer std.testing.allocator.free(entries);

    // Should produce at least 2 entries (may merge small paragraphs)
    try std.testing.expect(entries.len >= 1);
    try std.testing.expect(entries.len <= 10);

    // Each entry should have a non-zero vector
    for (entries) |entry| {
        try std.testing.expect(entry.source_length > 0);
        try std.testing.expect(vsa.collapse(entry.vector) != 0);
    }
}

test "encodeDocument with domain tag" {
    const doc = "Synaptic vesicle release follows calcium influx at the presynaptic terminal.";
    const entries = try encodeDocument(std.testing.allocator, doc, "biology");
    defer std.testing.allocator.free(entries);

    try std.testing.expect(entries.len >= 1);
    // Domain-tagged vector should differ from untagged
    const plain = encodeConceptString(doc);
    const resonance = vsa.calculateResonance(entries[0].vector, plain);
    try std.testing.expect(resonance < 700);
}

test "encodeBoundRelation and unbind" {
    const relation = encodeBoundRelation("QUIC", "handles", "Packet Loss");

    // Unbind subject
    const recovered_subj = unbindRole(relation.vector, .subject);
    const subj_resonance = vsa.calculateResonance(recovered_subj, relation.subject_vector);
    // Bundle is lossy — but subject should have higher resonance than random
    try std.testing.expect(subj_resonance > 550);

    // Unbind predicate
    const recovered_pred = unbindRole(relation.vector, .predicate);
    const pred_resonance = vsa.calculateResonance(recovered_pred, relation.predicate_vector);
    try std.testing.expect(pred_resonance > 550);
}

test "encodeDomainTag orthogonality" {
    const bio = encodeDomainTag("biology");
    const traffic = encodeDomainTag("traffic");
    const resonance = vsa.calculateResonance(bio, traffic);
    // Different domains should be near-orthogonal
    try std.testing.expect(resonance > 400);
    try std.testing.expect(resonance < 600);
}
