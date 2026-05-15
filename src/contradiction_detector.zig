const std = @import("std");
const vsa = @import("vsa_core.zig");
const rune_lattice = @import("rune_lattice.zig");
const concept_index = @import("concept_index.zig");
const triad = @import("triad.zig");
const sys = @import("sys.zig");

// ══════════════════════════════════════════════════════════════════════════
//  CONTRADICTION DETECTOR: Logical Collision Resolution
// ══════════════════════════════════════════════════════════════════════════
//
// When two ingested concepts occupy suspiciously close regions of the
// Rune Lattice but carry contradictory content, the Contradiction Detector
// identifies and resolves the conflict.
//
// Detection Algorithm:
//   1. After ingesting a new concept at slot N, compute Hamming distance
//      to all other occupied slots.
//   2. If any existing slot M has distance < CONTRADICTION_RADIUS,
//      the two concepts are "logically proximate" — they describe the
//      same thing.
//   3. If the concept index reveals that their source texts contain
//      conflicting value assertions, flag as a Contradiction.
//
// Resolution Strategies:
//   - newer_wins: Document with later mtime wins. Simple, deterministic.
//   - higher_trust_wins: Uses TrustClass hierarchy (core > project > exploratory).
//   - prompt_user: Prints both values, asks for human verification.
//   - environmental_proof: [Stub] Runs a command to verify the true value.
//
// After resolution:
//   - Winner → Rank 1 (Verified). Locked in the lattice.
//   - Loser → Rank 5 (Noise). Will be purged on next Reaper prune cycle.
// ══════════════════════════════════════════════════════════════════════════

/// Maximum Hamming distance for two concepts to be considered "logically proximate."
/// With 1024-bit vectors, random pairs cluster ~512. A distance < 200 means
/// the vectors share >80% of bits — they describe the same thing.
pub const CONTRADICTION_RADIUS: u16 = 200;

/// Minimum Hamming distance to avoid self-matches and exact duplicates.
pub const CONTRADICTION_MIN_DISTANCE: u16 = 10;

/// Maximum number of contradictions to report per detection pass.
pub const MAX_CONTRADICTIONS_PER_PASS: usize = 32;

pub const ResolutionStrategy = enum {
    /// Document with later modification time wins.
    newer_wins,
    /// Document with higher trust class wins (core > project > exploratory).
    higher_trust_wins,
    /// Print both values and ask the user to verify.
    prompt_user,
    /// [Stub] Run an environmental command to determine the true value.
    environmental_proof,
};

pub const Contradiction = struct {
    /// Slot of the newly ingested concept.
    new_slot: u32,
    /// Slot of the existing concept that conflicts.
    existing_slot: u32,
    /// Hamming distance between the two vectors.
    distance: u16,
    /// Label of the new concept (from concept index).
    new_label: []const u8,
    /// Label of the existing concept (from concept index).
    existing_label: []const u8,
    /// Snippet of the new concept's source text.
    new_snippet: []const u8,
    /// Snippet of the existing concept's source text.
    existing_snippet: []const u8,
};

pub const ResolutionOutcome = struct {
    /// The slot that was promoted to Rank 1 (winner).
    winner_slot: u32,
    /// The slot that was demoted to Rank 5 (loser).
    loser_slot: u32,
    /// The strategy that was used to resolve.
    strategy: ResolutionStrategy,
    /// Human-readable reason for the resolution.
    reason: []const u8,
    /// Whether the user was prompted (only for .prompt_user).
    user_prompted: bool,
};

/// Detect contradictions for a newly ingested concept.
///
/// Scans the lattice for all concepts within CONTRADICTION_RADIUS of
/// the concept at `new_slot`. Returns a list of contradictions found.
///
/// Note: This does NOT perform deep semantic analysis of the text.
/// It relies on Hamming proximity in the VSA space as a proxy for
/// semantic similarity. If two concepts are proximate but their
/// source texts differ, it's flagged as a potential contradiction.
pub fn detectContradictions(
    allocator: std.mem.Allocator,
    lattice: *const rune_lattice.RuneLattice,
    new_slot: u32,
    index: *const concept_index.ConceptIndex,
) ![]Contradiction {
    if (new_slot >= lattice.capacity) return &.{};
    if (lattice.tags[new_slot] == 0) return &.{};

    const new_vec = lattice.vectors[new_slot];
    const new_entry = index.lookupBySlot(new_slot) orelse return &.{};

    var results = std.ArrayList(Contradiction).init(allocator);
    errdefer results.deinit();

    var i: u32 = 0;
    while (i < lattice.capacity) : (i += 1) {
        if (i == new_slot) continue;
        if (lattice.tags[i] == 0) continue;
        if (results.items.len >= MAX_CONTRADICTIONS_PER_PASS) break;

        const distance = vsa.hammingDistance(new_vec, lattice.vectors[i]);
        if (distance >= CONTRADICTION_RADIUS) continue;
        if (distance < CONTRADICTION_MIN_DISTANCE) continue; // Exact dupes, not contradictions

        const existing_entry = index.lookupBySlot(i) orelse continue;

        // Two concepts are proximate in the lattice — they describe the same thing.
        // If their source texts differ, it's a contradiction.
        if (!std.mem.eql(u8, new_entry.snippet, existing_entry.snippet)) {
            try results.append(.{
                .new_slot = new_slot,
                .existing_slot = i,
                .distance = distance,
                .new_label = new_entry.label,
                .existing_label = existing_entry.label,
                .new_snippet = new_entry.snippet,
                .existing_snippet = existing_entry.snippet,
            });
        }
    }

    return results.toOwnedSlice();
}

/// Resolve a contradiction using the specified strategy.
///
/// Winner → Rank 1 (Verified). Loser → Rank 5 (Noise).
/// The Reaper (Forge.tick → prune) will purge the Noise rune eventually.
pub fn resolveContradiction(
    lattice: *rune_lattice.RuneLattice,
    index: *concept_index.ConceptIndex,
    contradiction: Contradiction,
    strategy: ResolutionStrategy,
    now_ms: u64,
) ResolutionOutcome {
    var winner_slot: u32 = undefined;
    var loser_slot: u32 = undefined;
    var reason: []const u8 = undefined;

    switch (strategy) {
        .newer_wins => {
            // Compare last_confirmed timestamps
            const new_time = lattice.last_confirmed[contradiction.new_slot];
            const existing_time = lattice.last_confirmed[contradiction.existing_slot];
            if (new_time >= existing_time) {
                winner_slot = contradiction.new_slot;
                loser_slot = contradiction.existing_slot;
                reason = "newer document supersedes older";
            } else {
                winner_slot = contradiction.existing_slot;
                loser_slot = contradiction.new_slot;
                reason = "older document retained (newer document was backdated)";
            }
        },
        .higher_trust_wins => {
            // Compare rank (lower numeric rank = higher trust)
            const new_rank = lattice.ranks[contradiction.new_slot];
            const existing_rank = lattice.ranks[contradiction.existing_slot];
            if (@intFromEnum(new_rank) <= @intFromEnum(existing_rank)) {
                winner_slot = contradiction.new_slot;
                loser_slot = contradiction.existing_slot;
                reason = "higher-trust concept wins";
            } else {
                winner_slot = contradiction.existing_slot;
                loser_slot = contradiction.new_slot;
                reason = "existing higher-trust concept retained";
            }
        },
        .prompt_user => {
            // Print both values to stderr for the operator
            sys.print(
                \\
                \\[CONTRADICTION DETECTED]
                \\  Slot A ({d}): {s}
                \\    Snippet: "{s}"
                \\  Slot B ({d}): {s}
                \\    Snippet: "{s}"
                \\  Hamming Distance: {d} bits
                \\
                \\  [AUTO-RESOLVE] Defaulting to newer document.
                \\
            , .{
                contradiction.new_slot,
                contradiction.new_label,
                truncateSnippet(contradiction.new_snippet),
                contradiction.existing_slot,
                contradiction.existing_label,
                truncateSnippet(contradiction.existing_snippet),
                contradiction.distance,
            });
            // Default to newer for automation — a real interactive mode
            // would block here and read stdin.
            winner_slot = contradiction.new_slot;
            loser_slot = contradiction.existing_slot;
            reason = "user-prompted (auto-resolved to newer)";
        },
        .environmental_proof => {
            // Stub: environmental proof is not yet implemented.
            // Fall back to newer_wins.
            winner_slot = contradiction.new_slot;
            loser_slot = contradiction.existing_slot;
            reason = "environmental_proof stub (fell back to newer_wins)";
        },
    }

    // Promote winner to Rank 1 (Verified)
    lattice.verify(winner_slot, now_ms);
    index.updateRank(winner_slot, @intFromEnum(triad.RuneRank.verified));

    // Demote loser to Rank 5 (Noise) — the Reaper will purge it
    demoteToNoise(lattice, loser_slot);
    index.updateRank(loser_slot, @intFromEnum(triad.RuneRank.noise));

    return .{
        .winner_slot = winner_slot,
        .loser_slot = loser_slot,
        .strategy = strategy,
        .reason = reason,
        .user_prompted = strategy == .prompt_user,
    };
}

/// Force-demote a slot to Rank 5 (Noise) and reset its observation counters
/// so the Reaper can prune it on the next tick.
fn demoteToNoise(lattice: *rune_lattice.RuneLattice, slot: u32) void {
    if (slot >= lattice.capacity) return;
    if (lattice.tags[slot] == 0) return;
    lattice.ranks[slot] = .noise;
    lattice.occurrences[slot] = 1; // Keep at 1 so it's still "active" until pruned
    lattice.distinct_contexts[slot] = 1;
    // Set last_confirmed to 0 so it's immediately stale for the Reaper
    lattice.last_confirmed[slot] = 0;
}

fn truncateSnippet(text: []const u8) []const u8 {
    const max = 80;
    if (text.len <= max) return text;
    return text[0..max];
}

// ══════════════════════════════════════════════════════════════════════════
//  TESTS
// ══════════════════════════════════════════════════════════════════════════

test "detectContradictions finds proximate conflicting concepts" {
    var lattice = try rune_lattice.RuneLattice.init(std.testing.allocator, 256, null);
    defer lattice.deinit();
    var index = concept_index.ConceptIndex.init(std.testing.allocator);
    defer index.deinit();

    // Ingest two nearly identical concepts (same concept string, slightly different)
    const vec_a = vsa.generate(42);
    const slot_a = lattice.observe(vec_a, 0x1, 1000) orelse return error.LatticeObserveFailed;
    try index.addEntry("Timeout Config A", slot_a, "doc_a.txt", 0, 50, "config", 2, "The server timeout is 30 seconds");
    lattice.validate(slot_a, 1000);

    // Create a vector that is close to vec_a (within CONTRADICTION_RADIUS)
    // by flipping a small number of bits
    var vec_b = vec_a;
    vec_b[0] ^= 0x0000_0000_0000_00FF; // Flip 8 bits in first word
    const slot_b = lattice.observe(vec_b, 0x2, 2000) orelse return error.LatticeObserveFailed;
    try index.addEntry("Timeout Config B", slot_b, "doc_b.txt", 0, 50, "config", 2, "The server timeout is 5 seconds");
    lattice.validate(slot_b, 2000);

    const contradictions = try detectContradictions(std.testing.allocator, &lattice, slot_b, &index);
    defer std.testing.allocator.free(contradictions);

    // The two vectors are very close — should detect a contradiction
    try std.testing.expect(contradictions.len > 0);
    try std.testing.expectEqual(slot_b, contradictions[0].new_slot);
    try std.testing.expectEqual(slot_a, contradictions[0].existing_slot);
}

test "resolveContradiction newer_wins promotes winner and demotes loser" {
    var lattice = try rune_lattice.RuneLattice.init(std.testing.allocator, 256, null);
    defer lattice.deinit();
    var index = concept_index.ConceptIndex.init(std.testing.allocator);
    defer index.deinit();

    const vec_a = vsa.generate(42);
    const slot_a = lattice.observe(vec_a, 0x1, 1000) orelse return error.LatticeObserveFailed;
    try index.addEntry("Old Config", slot_a, "old.txt", 0, 10, "config", 2, "timeout=30");
    lattice.validate(slot_a, 1000);

    var vec_b = vec_a;
    vec_b[0] ^= 0xFF;
    const slot_b = lattice.observe(vec_b, 0x2, 2000) orelse return error.LatticeObserveFailed;
    try index.addEntry("New Config", slot_b, "new.txt", 0, 10, "config", 2, "timeout=5");
    lattice.validate(slot_b, 2000);

    const contradiction = Contradiction{
        .new_slot = slot_b,
        .existing_slot = slot_a,
        .distance = vsa.hammingDistance(vec_a, vec_b),
        .new_label = "New Config",
        .existing_label = "Old Config",
        .new_snippet = "timeout=5",
        .existing_snippet = "timeout=30",
    };

    const outcome = resolveContradiction(&lattice, &index, contradiction, .newer_wins, 3000);

    // Newer (slot_b) should win
    try std.testing.expectEqual(slot_b, outcome.winner_slot);
    try std.testing.expectEqual(slot_a, outcome.loser_slot);

    // Winner should be Rank 1 (Verified)
    try std.testing.expectEqual(triad.RuneRank.verified, lattice.ranks[slot_b]);

    // Loser should be Rank 5 (Noise) with last_confirmed=0 (stale for Reaper)
    try std.testing.expectEqual(triad.RuneRank.noise, lattice.ranks[slot_a]);
    try std.testing.expectEqual(@as(u64, 0), lattice.last_confirmed[slot_a]);
}

test "resolveContradiction loser is purgeable by Reaper" {
    var lattice = try rune_lattice.RuneLattice.init(std.testing.allocator, 256, null);
    defer lattice.deinit();
    var index = concept_index.ConceptIndex.init(std.testing.allocator);
    defer index.deinit();

    const vec_a = vsa.generate(42);
    const slot_a = lattice.observe(vec_a, 0x1, 1000) orelse return error.LatticeObserveFailed;
    try index.addEntry("Loser", slot_a, "loser.txt", 0, 10, "test", 2, "loser text");
    lattice.validate(slot_a, 1000);

    var vec_b = vec_a;
    vec_b[0] ^= 0xFF;
    const slot_b = lattice.observe(vec_b, 0x2, 2000) orelse return error.LatticeObserveFailed;
    try index.addEntry("Winner", slot_b, "winner.txt", 0, 10, "test", 2, "winner text");
    lattice.validate(slot_b, 2000);

    const contradiction = Contradiction{
        .new_slot = slot_b,
        .existing_slot = slot_a,
        .distance = 8,
        .new_label = "Winner",
        .existing_label = "Loser",
        .new_snippet = "winner text",
        .existing_snippet = "loser text",
    };

    _ = resolveContradiction(&lattice, &index, contradiction, .newer_wins, 3000);

    // The loser's last_confirmed is 0, so it's immediately stale.
    // Prune at any time > RANK_NOISE_TTL_MS should purge it.
    const summary = lattice.prune(triad.RANK_NOISE_TTL_MS + 1);
    try std.testing.expectEqual(@as(u32, 1), summary.pruned);

    // Winner should still be alive
    try std.testing.expect(lattice.tags[slot_b] != 0);
}
