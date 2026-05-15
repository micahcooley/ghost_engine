const std = @import("std");
const vsa = @import("vsa_core.zig");
const config = @import("config.zig");
const ghost_state = @import("ghost_state.zig");
const triad = @import("triad.zig");
const rune_lattice = @import("rune_lattice.zig");
const vsa_vulkan = @import("vsa_vulkan.zig");
const sys = @import("sys.zig");

// ══════════════════════════════════════════════════════════════════════════
//  THE FORGE: Rank-Based Training Without Weights
// ══════════════════════════════════════════════════════════════════════════
//
// You don't "train" Ghost v2 with gradient descent or backpropagation.
// You "Forge" it through Consolidation:
//
//   1. ACCUMULATION: Feed the system millions of lines of verified code.
//   2. RANKING: Patterns move through Rank 5→1 based on observation frequency
//      and verification status.
//   3. LATTICE PRUNING: Delete anything that stays at Rank 5 for too long.
//      Memory stays lean and 100% logical.
//
// The Forge integrates with the existing OhlTrainer to overlay rank tracking
// onto the existing etching pipeline.
// ══════════════════════════════════════════════════════════════════════════

/// Forge configuration.
pub const ForgeConfig = struct {
    /// How often to run automatic pruning (ms).
    prune_interval_ms: u64 = 300_000, // 5 minutes
    /// How often to sweep for rank promotions (ms).
    promotion_sweep_interval_ms: u64 = 60_000, // 1 minute
    /// Whether to log promotion events.
    log_promotions: bool = true,
    /// Whether to log prune events.
    log_prunes: bool = true,
    /// Minimum rank for query responses.
    query_min_rank: triad.RuneRank = .pattern,
    /// Maximum distance threshold for lattice queries.
    query_distance_threshold: u16 = triad.KING_DISTANCE_THRESHOLD,
};

pub const ForgeStats = struct {
    total_observations: u64 = 0,
    total_promotions: u64 = 0,
    total_pruned: u64 = 0,
    total_verifications: u64 = 0,
    total_validations: u64 = 0,
    total_queries: u64 = 0,
    total_query_hits: u64 = 0,
    total_query_misses: u64 = 0,
    total_medic_triggers: u64 = 0,
    last_prune_ms: u64 = 0,
    last_promotion_sweep_ms: u64 = 0,
    lattice_fill_bp: u32 = 0,
    rank_distribution: [5]u32 = .{ 0, 0, 0, 0, 0 },
};

pub const ForgeEngine = struct {
    lattice: rune_lattice.RuneLattice,
    pipeline: triad.TriadPipeline,
    forge_config: ForgeConfig,
    stats: ForgeStats,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, cfg: ForgeConfig, lattice_capacity: u32, vk_engine: ?*vsa_vulkan.VulkanEngine) !ForgeEngine {
        return ForgeEngine{
            .lattice = try rune_lattice.RuneLattice.init(allocator, lattice_capacity, vk_engine),
            .pipeline = triad.TriadPipeline.init(ghost_state.GENESIS_SEED),
            .forge_config = cfg,
            .stats = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ForgeEngine) void {
        self.lattice.deinit();
    }

    // ── Forge Operations ──

    /// Observe a rune during training. This is the core Forge etching operation.
    /// Called by the trainer after each rune is processed through the existing pipeline.
    pub fn observe(self: *ForgeEngine, vector: vsa.HyperVector, context_hash: u64, now_ms: u64) ?u32 {
        self.stats.total_observations += 1;
        return self.lattice.observe(vector, context_hash, now_ms);
    }

    /// Process a rune through the full Triad pipeline.
    /// This is the v2 inference path — Scout→Sniper→King.
    pub fn processRune(self: *ForgeEngine, rune: u32, byte_offset: u64) triad.TriadDecision {
        self.stats.total_queries += 1;

        const decision = self.pipeline.process(
            rune,
            byte_offset,
            self.lattice.vectors[0..self.lattice.capacity],
            self.lattice.ranks[0..self.lattice.capacity],
        );

        if (decision.lattice_resolved) {
            self.stats.total_query_hits += 1;
        } else if (decision.medic_triggered) {
            self.stats.total_medic_triggers += 1;
            self.stats.total_query_misses += 1;
        }

        return decision;
    }

    /// Verify a slot — promote to Rank 1 (Verified). Called by human confirmation.
    pub fn verify(self: *ForgeEngine, slot: u32, now_ms: u64) void {
        self.lattice.verify(slot, now_ms);
        self.stats.total_verifications += 1;
        if (self.forge_config.log_promotions) {
            sys.print("[FORGE] Slot {d} verified to Rank 1\n", .{slot});
        }
    }

    /// Validate a slot — promote to Rank 2 (Validated). Called by automated tests.
    pub fn validateSlot(self: *ForgeEngine, slot: u32, now_ms: u64) void {
        self.lattice.validate(slot, now_ms);
        self.stats.total_validations += 1;
        if (self.forge_config.log_promotions) {
            sys.print("[FORGE] Slot {d} validated to Rank 2\n", .{slot});
        }
    }

    /// Run periodic maintenance (pruning + promotions).
    /// Call this from the trainer's checkpoint loop.
    pub fn tick(self: *ForgeEngine, now_ms: u64) void {
        // Prune stale noise
        if (now_ms -| self.stats.last_prune_ms >= self.forge_config.prune_interval_ms) {
            const prune_summary = self.lattice.prune(now_ms);
            self.stats.total_pruned += prune_summary.pruned;
            self.stats.last_prune_ms = now_ms;

            if (self.forge_config.log_prunes and prune_summary.pruned > 0) {
                sys.print("[FORGE] Pruned {d} stale Noise runes ({d} retained)\n", .{
                    prune_summary.pruned,
                    prune_summary.retained,
                });
            }
        }

        // Sweep for automatic promotions
        if (now_ms -| self.stats.last_promotion_sweep_ms >= self.forge_config.promotion_sweep_interval_ms) {
            const promo_summary = self.lattice.sweepPromotions();
            self.stats.total_promotions += promo_summary.promoted;
            self.stats.last_promotion_sweep_ms = now_ms;

            if (self.forge_config.log_promotions and promo_summary.promoted > 0) {
                sys.print("[FORGE] Promoted {d} runes (→Emerging:{d} →Pattern:{d} →Validated:{d})\n", .{
                    promo_summary.promoted,
                    promo_summary.to_emerging,
                    promo_summary.to_pattern,
                    promo_summary.to_validated,
                });
            }
        }

        // Update stats
        self.stats.lattice_fill_bp = self.lattice.getFillBp();
        self.stats.rank_distribution = self.lattice.getRankDistribution();
    }

    /// Get current forge statistics.
    pub fn getStats(self: *const ForgeEngine) ForgeStats {
        var stats = self.stats;
        stats.lattice_fill_bp = self.lattice.getFillBp();
        stats.rank_distribution = self.lattice.getRankDistribution();
        return stats;
    }

    /// Search the lattice for a query vector.
    pub fn search(self: *const ForgeEngine, query: vsa.HyperVector) rune_lattice.AsyncSearchResult {
        return self.lattice.search(query, self.forge_config.query_min_rank);
    }

    pub fn pollSearch(self: *const ForgeEngine, job: vsa_vulkan.VulkanEngine.GpuJob) !?rune_lattice.SearchResult {
        return try self.lattice.pollSearch(job);
    }

    /// Get the Triad pipeline's Scout state.
    pub fn getScoutState(self: *const ForgeEngine) *const triad.ScoutState {
        return self.pipeline.getScoutState();
    }
};

// ══════════════════════════════════════════════════════════════════════════
//  MEDIC LOOP (0x8B): Logical Proof Fallback
// ══════════════════════════════════════════════════════════════════════════
//
// When the King cannot resolve a query to a Rank-1 Rune (no match within
// distance τ), the Medic Loop is triggered. It performs a "logical proof
// of the environment" before emitting text.
//
// In v2, the Medic:
//   1. Examines the Scout's recent state trajectory.
//   2. Searches for partial matches (relaxed distance threshold).
//   3. If a partial match is found, returns it with a confidence flag.
//   4. If no match at all, returns SILENT (the system says nothing rather
//      than hallucinate).
// ══════════════════════════════════════════════════════════════════════════

pub const MedicDecision = struct {
    /// Whether the Medic found a resolution.
    resolved: bool,
    /// If resolved, the best-effort Rune match.
    rune_vector: ?vsa.HyperVector,
    /// Slot selected from the lattice, if any.
    slot: ?u32 = null,
    /// Rank of the selected Rune.
    rank: triad.RuneRank = .noise,
    /// Hamming distance from the query to the selected Rune.
    distance: u16 = 1024,
    /// Whether the selected Rune came from Rank-5 Noise/Dark Space.
    dark_space: bool = false,
    /// Confidence level (0 = pure guess, 1000 = near-certain).
    confidence_per_mille: u16,
    /// Short stream marker for human renderers.
    confidence_indicator: []const u8 = "verified",
    /// Number of probes attempted.
    probes: u32,
    /// Whether the system should remain silent.
    silent: bool,
};

/// Medic Loop: attempt to resolve an unmatched query through extended search.
/// This is the "logical proof of the environment" before emitting any text.
pub fn medicLoop(
    lattice: *const rune_lattice.RuneLattice,
    query: vsa.HyperVector,
    scout_state: *const triad.ScoutState,
) MedicDecision {
    _ = scout_state; // Future: use state trajectory for guided search

    // Phase 1: strict Rank-1 search inside the configured tau.
    const tau: u16 = config.V2_MEDIC_DISTANCE_TAU;
    var best_verified_slot: u32 = 0;
    var best_verified_dist: u16 = 1025;
    var found_verified = false;
    var best_noise_slot: u32 = 0;
    var best_noise_dist: u16 = 1025;
    var found_noise = false;
    var probes: u32 = 0;

    var i: u32 = 0;
    while (i < lattice.capacity) : (i += 1) {
        if (lattice.tags[i] == 0) continue;
        probes += 1;

        const d = vsa.hammingDistance(query, lattice.vectors[i]);
        switch (lattice.ranks[i]) {
            .verified => {
                if (d < best_verified_dist) {
                    best_verified_dist = d;
                    best_verified_slot = i;
                    found_verified = true;
                }
            },
            .noise => {
                if (d < best_noise_dist) {
                    best_noise_dist = d;
                    best_noise_slot = i;
                    found_noise = true;
                }
            },
            else => {},
        }
    }

    if (found_verified and best_verified_dist <= tau) {
        // Compute confidence: inversely proportional to distance.
        const max_dist = @as(u32, tau);
        const confidence = if (best_verified_dist < max_dist)
            @as(u16, @intCast(((max_dist - @as(u32, best_verified_dist)) * 1000) / max_dist))
        else
            0;

        return .{
            .resolved = true,
            .rune_vector = lattice.vectors[best_verified_slot],
            .slot = best_verified_slot,
            .rank = .verified,
            .distance = best_verified_dist,
            .dark_space = false,
            .confidence_per_mille = confidence,
            .confidence_indicator = "rank1",
            .probes = probes,
            .silent = false,
        };
    }

    if (!found_noise) {
        return .{
            .resolved = false,
            .rune_vector = null,
            .confidence_per_mille = 0,
            .confidence_indicator = "unresolved",
            .probes = probes,
            .silent = true,
        };
    }

    // Phase 2: exploratory unbind from Rank-5 Noise/Dark Space. XOR binding is
    // self-inverse, so binding query with the nearest noise vector recovers the
    // exploratory delta without promoting it to verified authority.
    const unbound = vsa.bind(query, lattice.vectors[best_noise_slot]);
    const dark_confidence = @as(u16, @intCast(((@as(u32, config.HYPERVECTOR_BITS) - @as(u32, best_noise_dist)) * 250) / @as(u32, config.HYPERVECTOR_BITS)));

    return .{
        .resolved = true,
        .rune_vector = unbound,
        .slot = best_noise_slot,
        .rank = .noise,
        .distance = best_noise_dist,
        .dark_space = true,
        .confidence_per_mille = dark_confidence,
        .confidence_indicator = "~dark-space~",
        .probes = probes,
        .silent = false,
    };
}

// ══════════════════════════════════════════════════════════════════════════
//  TESTS
// ══════════════════════════════════════════════════════════════════════════

test "ForgeEngine init and deinit" {
    var forge = try ForgeEngine.init(std.testing.allocator, .{}, 256, null);
    defer forge.deinit();

    const stats = forge.getStats();
    try std.testing.expectEqual(@as(u64, 0), stats.total_observations);
}

test "ForgeEngine observe and search" {
    var forge = try ForgeEngine.init(std.testing.allocator, .{
        .query_min_rank = .noise,
    }, 256, null);
    defer forge.deinit();

    const vec = vsa.generate(42);
    const slot = forge.observe(vec, 0x1234, 1000);
    try std.testing.expect(slot != null);

    const result = forge.search(vec);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(u16, 0), result.?.distance);
}

test "ForgeEngine verify and validate" {
    var forge = try ForgeEngine.init(std.testing.allocator, .{}, 256, null);
    defer forge.deinit();

    const vec = vsa.generate(42);
    const slot = forge.observe(vec, 0x1234, 1000);
    try std.testing.expect(slot != null);

    forge.verify(slot.?, 2000);
    try std.testing.expectEqual(@as(u64, 1), forge.stats.total_verifications);

    const result = forge.search(vec);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(triad.RuneRank.verified, result.?.rank);
}

test "ForgeEngine tick prune" {
    var forge = try ForgeEngine.init(std.testing.allocator, .{
        .prune_interval_ms = 0,
        .promotion_sweep_interval_ms = 0,
        .log_prunes = false,
        .log_promotions = false,
    }, 256, null);
    defer forge.deinit();

    _ = forge.observe(vsa.generate(42), 0x1, 0);
    try std.testing.expectEqual(@as(u32, 1), forge.lattice.active_count);

    // Tick at a time well past TTL
    forge.tick(triad.RANK_NOISE_TTL_MS + 1);
    try std.testing.expectEqual(@as(u32, 0), forge.lattice.active_count);
    try std.testing.expect(forge.stats.total_pruned > 0);
}

test "MedicLoop returns silent for empty lattice" {
    var lattice = try rune_lattice.RuneLattice.init(std.testing.allocator, 64, null);
    defer lattice.deinit();

    var scout = triad.ScoutState.init(ghost_state.GENESIS_SEED);
    const query = vsa.generate(42);

    const decision = medicLoop(&lattice, query, &scout);
    try std.testing.expect(decision.silent);
    try std.testing.expect(!decision.resolved);
    try std.testing.expectEqual(@as(u16, 0), decision.confidence_per_mille);
}

test "MedicLoop finds relaxed match" {
    var lattice = try rune_lattice.RuneLattice.init(std.testing.allocator, 64, null);
    defer lattice.deinit();

    const vec = vsa.generate(42);
    const slot = lattice.observe(vec, 0x1, 0).?;
    lattice.verify(slot, 0);

    var scout = triad.ScoutState.init(ghost_state.GENESIS_SEED);

    // Query with the exact same vector should find a Rank-1 match inside tau.
    const decision = medicLoop(&lattice, vec, &scout);
    try std.testing.expect(decision.resolved);
    try std.testing.expect(!decision.silent);
    try std.testing.expect(!decision.dark_space);
    try std.testing.expectEqual(triad.RuneRank.verified, decision.rank);
    try std.testing.expect(decision.confidence_per_mille > 900);
}

test "MedicLoop explores nearest Rank-5 dark space when Rank-1 misses tau" {
    var lattice = try rune_lattice.RuneLattice.init(std.testing.allocator, 64, null);
    defer lattice.deinit();

    const query = vsa.generate(42);
    const far_verified = vsa.bind(query, @as(vsa.HyperVector, @splat(std.math.maxInt(u64))));
    const verified_slot = lattice.observe(far_verified, 0x1, 0).?;
    lattice.verify(verified_slot, 0);

    const noise = vsa.bind(query, vsa.generate(99));
    const noise_slot = lattice.observe(noise, 0x2, 0).?;

    var scout = triad.ScoutState.init(ghost_state.GENESIS_SEED);
    const decision = medicLoop(&lattice, query, &scout);

    try std.testing.expect(decision.resolved);
    try std.testing.expect(!decision.silent);
    try std.testing.expect(decision.dark_space);
    try std.testing.expectEqual(triad.RuneRank.noise, decision.rank);
    try std.testing.expectEqual(@as(?u32, noise_slot), decision.slot);
    try std.testing.expectEqualStrings("~dark-space~", decision.confidence_indicator);
}
