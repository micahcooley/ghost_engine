const std = @import("std");
const vsa = @import("vsa_core.zig");
const config = @import("config.zig");
const ghost_state = @import("ghost_state.zig");
const triad = @import("triad.zig");
const vsa_vulkan = @import("vsa_vulkan.zig");
const sys = @import("sys.zig");

// ══════════════════════════════════════════════════════════════════════════
//  RUNE LATTICE: The King's Memory
// ══════════════════════════════════════════════════════════════════════════
//
// The Rune Lattice is the permanent, ranked memory of all observed patterns.
// It stores Runes (1024-bit HyperVectors) with Rank metadata (1-5).
//
// Key properties:
//   - Weightless: No floating-point weights. Only bit-vectors and integer ranks.
//   - Deterministic: Same query always returns same result.
//   - Pruneable: Stale Rank-5 noise is automatically garbage-collected.
//   - Lattice-Locked: Output can only come from Rank-1 Verified Runes.
//
// Storage layout (GPU-friendly):
//   - Rune vectors: contiguous []HyperVector (128 bytes each)
//   - Rank metadata: packed []RuneRank (1 byte each)
//   - Occurrence counts: []u32 (4 bytes each)
//   - Context hashes: []u64 (8 bytes, for distinct context tracking)
//   - Tags: []u64 (8 bytes, content hash for deduplication)
// ══════════════════════════════════════════════════════════════════════════

/// Maximum number of Runes the lattice can hold.
/// At 128 bytes per vector + 13 bytes metadata = 141 bytes per Rune.
/// 67M Runes × 141 bytes ≈ 9.4 GB (the 8GB budget needs ~56M Runes).
pub const DEFAULT_LATTICE_CAPACITY: u32 = if (config.TEST_MODE) 4096 else 4_194_304; // 4M Runes for now

/// Minimum accepted bit-similarity for a VSA match, expressed per-mille.
pub const SEARCH_MIN_SIMILARITY_PER_MILLE: u16 = 750;
/// Maximum accepted Hamming distance for a 1024-bit hypervector at 75% similarity.
pub const SEARCH_MAX_HAMMING_DISTANCE: u16 = 256;
/// Legacy name kept for callers and CLI rendering.
pub const SEARCH_NEAR_RESONANCE: u16 = SEARCH_MAX_HAMMING_DISTANCE;

pub const PruneSummary = struct {
    scanned: u32 = 0,
    pruned: u32 = 0,
    retained: u32 = 0,
    rank_distribution: [5]u32 = .{ 0, 0, 0, 0, 0 },
};

pub const PromotionSummary = struct {
    scanned: u32 = 0,
    promoted: u32 = 0,
    to_emerging: u32 = 0,
    to_pattern: u32 = 0,
    to_validated: u32 = 0,
};

pub const SearchResult = struct {
    slot: u32,
    distance: u16,
    rank: triad.RuneRank,
    occurrences: u32,
};

pub const AsyncSearchResult = union(enum) {
    pending: vsa_vulkan.VulkanEngine.GpuJob,
    found: SearchResult,
    not_found: void,
};

pub const RuneLattice = struct {
    /// HyperVector storage — the actual Rune bit-patterns.
    vectors: []vsa.HyperVector,
    /// Rank per slot.
    ranks: []triad.RuneRank,
    /// Observation count per slot.
    occurrences: []u32,
    /// Distinct context count per slot.
    distinct_contexts: []u32,
    /// Content hash per slot (for deduplication).
    tags: []u64,
    /// Timestamp of first observation (ms since epoch).
    first_seen: []u64,
    /// Timestamp of last confirmation (ms since epoch).
    last_confirmed: []u64,
    /// Rolling hash of context identifiers (for distinct context tracking).
    context_hashes: []u64,

    /// Number of active (non-empty) slots.
    active_count: u32,
    /// Total capacity.
    capacity: u32,

    vk_engine: ?*vsa_vulkan.VulkanEngine = null,

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, capacity: u32, vk_engine: ?*vsa_vulkan.VulkanEngine) !RuneLattice {
        const cap = if (vk_engine) |vk| @as(usize, vk.matrix_slots) else @as(usize, capacity);

        const vectors = if (vk_engine) |vk|
            @as([*]vsa.HyperVector, @ptrCast(@alignCast(vk.mapped_matrix.?)))[0..cap]
        else
            try allocator.alloc(vsa.HyperVector, cap);

        if (vk_engine == null) {
            @memset(std.mem.sliceAsBytes(vectors), 0);
        }

        const ranks = if (vk_engine) |vk|
            @as([*]triad.RuneRank, @ptrCast(@alignCast(vk.mapped_rune_ranks.?)))[0..cap]
        else
            try allocator.alloc(triad.RuneRank, cap);

        if (vk_engine == null) {
            @memset(@as([]u8, @ptrCast(ranks)), @intFromEnum(triad.RuneRank.noise));
        }
        const occurrences = try allocator.alloc(u32, cap);
        @memset(occurrences, 0);
        const distinct_contexts = try allocator.alloc(u32, cap);
        @memset(distinct_contexts, 0);
        const tags = if (vk_engine) |vk|
            @as([*]u64, @ptrCast(@alignCast(vk.mapped_tags.?)))[0..cap]
        else
            try allocator.alloc(u64, cap);

        if (vk_engine == null) {
            @memset(tags, 0);
        }
        const first_seen = try allocator.alloc(u64, cap);
        @memset(first_seen, 0);
        const last_confirmed = try allocator.alloc(u64, cap);
        @memset(last_confirmed, 0);
        const context_hashes = try allocator.alloc(u64, cap);
        @memset(context_hashes, 0);

        return .{
            .vectors = vectors,
            .ranks = ranks,
            .occurrences = occurrences,
            .distinct_contexts = distinct_contexts,
            .tags = tags,
            .first_seen = first_seen,
            .last_confirmed = last_confirmed,
            .context_hashes = context_hashes,
            .active_count = 0,
            .capacity = @intCast(cap),
            .vk_engine = vk_engine,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RuneLattice) void {
        if (self.vk_engine == null) {
            self.allocator.free(self.vectors);
            self.allocator.free(self.ranks);
            self.allocator.free(self.tags);
        }
        self.allocator.free(self.occurrences);
        self.allocator.free(self.distinct_contexts);
        self.allocator.free(self.first_seen);
        self.allocator.free(self.last_confirmed);
        self.allocator.free(self.context_hashes);
    }

    /// Find a slot for a given content hash. Returns existing slot or allocates new.
    fn findOrAllocateSlot(self: *RuneLattice, content_hash: u64) ?u32 {
        // Linear probe with wrapping (simple, deterministic)
        const start = @as(u32, @intCast(content_hash % self.capacity));
        var probe: u32 = 0;
        while (probe < @min(self.capacity, 64)) : (probe += 1) {
            const slot = (start +% probe) % self.capacity;
            if (self.tags[slot] == content_hash) return slot; // Existing
            if (self.tags[slot] == 0) {
                // Empty slot — allocate
                self.tags[slot] = content_hash;
                self.active_count += 1;
                return slot;
            }
        }
        return null; // Lattice full in this neighborhood
    }

    /// Observe a Rune: record its occurrence and potentially promote its rank.
    /// This is the core Forge operation — "etching" a pattern into the Lattice.
    pub fn observe(self: *RuneLattice, vector: vsa.HyperVector, context_hash: u64, now_ms: u64) ?u32 {
        const content_hash = vsa.collapse(vector);
        const slot = self.findOrAllocateSlot(content_hash) orelse return null;

        // First observation — initialize
        if (self.occurrences[slot] == 0) {
            self.vectors[slot] = vector;
            self.ranks[slot] = .noise;
            self.first_seen[slot] = now_ms;
            self.context_hashes[slot] = context_hash;
            self.distinct_contexts[slot] = 1;
        }

        self.occurrences[slot] +|= 1;
        self.last_confirmed[slot] = now_ms;

        // Track distinct contexts via rolling XOR (not perfect but O(1))
        if (self.context_hashes[slot] != context_hash) {
            self.context_hashes[slot] ^= context_hash;
            self.distinct_contexts[slot] +|= 1;
        }

        // Auto-promote if thresholds are met
        _ = self.tryPromote(slot);

        return slot;
    }

    /// Try to promote a Rune to the next rank level.
    fn tryPromote(self: *RuneLattice, slot: u32) bool {
        const rank = self.ranks[slot];
        const occ = self.occurrences[slot];
        const ctx = self.distinct_contexts[slot];

        const new_rank: triad.RuneRank = switch (rank) {
            .noise => if (occ >= triad.RANK_EMERGING_MIN_OBSERVATIONS) .emerging else return false,
            .emerging => if (occ >= triad.RANK_PATTERN_MIN_OBSERVATIONS and
                ctx >= triad.RANK_PATTERN_MIN_CONTEXTS) .pattern else return false,
            .pattern, .validated, .verified => return false,
        };

        self.ranks[slot] = new_rank;
        return true;
    }

    /// Force a slot to Verified rank (human or test confirmation).
    pub fn verify(self: *RuneLattice, slot: u32, now_ms: u64) void {
        if (slot >= self.capacity) return;
        if (self.tags[slot] == 0) return;
        self.ranks[slot] = .verified;
        self.last_confirmed[slot] = now_ms;
    }

    /// Force a slot to Validated rank (automated test success).
    pub fn validate(self: *RuneLattice, slot: u32, now_ms: u64) void {
        if (slot >= self.capacity) return;
        if (self.tags[slot] == 0) return;
        if (@intFromEnum(self.ranks[slot]) > @intFromEnum(triad.RuneRank.validated)) {
            self.ranks[slot] = .validated;
        }
        self.last_confirmed[slot] = now_ms;
    }

    /// Search for the nearest Rune at or above `min_rank`.
    /// Uses linear scan — for GPU-accelerated search, use the Vulkan rune_search shader.
    pub fn search(self: *const RuneLattice, query: vsa.HyperVector, min_rank: triad.RuneRank) AsyncSearchResult {
        if (self.vk_engine) |vk| {
            if (vk.dispatchRuneSearch(query, @intFromEnum(min_rank), SEARCH_NEAR_RESONANCE)) |job| {
                return .{ .pending = job };
            } else |err| {
                sys.print("[!WARNING] Vulkan search dispatch failed: {any}. Falling back to CPU.\n", .{err});
            }
        }

        var best_slot: u32 = 0;
        var best_dist: u16 = 1025;
        var found = false;

        var i: u32 = 0;
        while (i < self.capacity) : (i += 1) {
            if (self.tags[i] == 0) continue;
            if (@intFromEnum(self.ranks[i]) > @intFromEnum(min_rank)) continue;

            const d = vsa.hammingDistance(query, self.vectors[i]);
            if (d < best_dist) {
                best_dist = d;
                best_slot = i;
                found = true;
            }
        }

        if (!found) return .not_found;
        if (best_dist > SEARCH_MAX_HAMMING_DISTANCE) return .not_found;

        return .{
            .found = .{
                .slot = best_slot,
                .distance = best_dist,
                .rank = self.ranks[best_slot],
                .occurrences = self.occurrences[best_slot],
            },
        };
    }

    pub fn pollSearch(self: *const RuneLattice, job: vsa_vulkan.VulkanEngine.GpuJob) !?SearchResult {
        const vk = self.vk_engine orelse return error.VulkanOffline;
        const res = try vk.pollRuneSearch(job) orelse return null;

        if (res.slot < self.capacity and res.distance <= SEARCH_NEAR_RESONANCE) {
            return SearchResult{
                .slot = res.slot,
                .distance = @intCast(res.distance),
                .rank = self.ranks[res.slot],
                .occurrences = self.occurrences[res.slot],
            };
        }
        return null;
    }

    /// Prune all stale Rank-5 (Noise) Runes older than the TTL.
    pub fn prune(self: *RuneLattice, now_ms: u64) PruneSummary {
        var summary = PruneSummary{};

        var i: u32 = 0;
        while (i < self.capacity) : (i += 1) {
            if (self.tags[i] == 0) continue;
            summary.scanned += 1;

            const rank_idx = @intFromEnum(self.ranks[i]) - 1;
            summary.rank_distribution[rank_idx] += 1;

            if (self.ranks[i] == .noise and
                (now_ms -| self.last_confirmed[i]) > triad.RANK_NOISE_TTL_MS)
            {
                // Prune: zero out the slot
                self.vectors[i] = @splat(0);
                self.ranks[i] = .noise;
                self.occurrences[i] = 0;
                self.distinct_contexts[i] = 0;
                self.tags[i] = 0;
                self.first_seen[i] = 0;
                self.last_confirmed[i] = 0;
                self.context_hashes[i] = 0;
                self.active_count -|= 1;
                summary.pruned += 1;
            } else {
                summary.retained += 1;
            }
        }

        return summary;
    }

    /// Sweep all ranks and apply automatic promotions.
    pub fn sweepPromotions(self: *RuneLattice) PromotionSummary {
        var summary = PromotionSummary{};

        var i: u32 = 0;
        while (i < self.capacity) : (i += 1) {
            if (self.tags[i] == 0) continue;
            summary.scanned += 1;

            const old_rank = self.ranks[i];
            if (self.tryPromote(i)) {
                summary.promoted += 1;
                switch (self.ranks[i]) {
                    .emerging => summary.to_emerging += 1,
                    .pattern => summary.to_pattern += 1,
                    .validated => summary.to_validated += 1,
                    else => {},
                }
                _ = old_rank; // Suppress unused warning
            }
        }

        return summary;
    }

    /// Get the rank distribution of all active Runes.
    pub fn getRankDistribution(self: *const RuneLattice) [5]u32 {
        var dist = [5]u32{ 0, 0, 0, 0, 0 };
        var i: u32 = 0;
        while (i < self.capacity) : (i += 1) {
            if (self.tags[i] == 0) continue;
            dist[@intFromEnum(self.ranks[i]) - 1] += 1;
        }
        return dist;
    }

    /// Get the fill ratio as basis points (0-10000).
    pub fn getFillBp(self: *const RuneLattice) u32 {
        if (self.capacity == 0) return 0;
        return @intCast((@as(u64, self.active_count) * 10000) / self.capacity);
    }
};

// ══════════════════════════════════════════════════════════════════════════
//  TESTS
// ══════════════════════════════════════════════════════════════════════════

test "RuneLattice init and deinit" {
    var lattice = try RuneLattice.init(std.testing.allocator, 256, null);
    defer lattice.deinit();

    try std.testing.expectEqual(@as(u32, 0), lattice.active_count);
    try std.testing.expectEqual(@as(u32, 256), lattice.capacity);
    try std.testing.expectEqual(@as(u32, 0), lattice.getFillBp());
}

test "RuneLattice observe and search" {
    var lattice = try RuneLattice.init(std.testing.allocator, 256, null);
    defer lattice.deinit();

    const vec = vsa.generate(42);
    const slot = lattice.observe(vec, 0xABCD, 1000);
    try std.testing.expect(slot != null);
    try std.testing.expectEqual(@as(u32, 1), lattice.active_count);

    // Search should find it
    const result = lattice.search(vec, .noise);
    try std.testing.expect(result == .found);
    try std.testing.expectEqual(@as(u16, 0), result.found.distance);
    try std.testing.expectEqual(triad.RuneRank.noise, result.found.rank);
}

test "RuneLattice rank promotion" {
    var lattice = try RuneLattice.init(std.testing.allocator, 256, null);
    defer lattice.deinit();

    const vec = vsa.generate(42);

    // Observe 5 times to promote from noise to emerging
    for (0..triad.RANK_EMERGING_MIN_OBSERVATIONS) |i| {
        _ = lattice.observe(vec, @as(u64, i), @as(u64, i * 100));
    }

    const result = lattice.search(vec, .emerging);
    try std.testing.expect(result == .found);
    try std.testing.expectEqual(triad.RuneRank.emerging, result.found.rank);
}

test "RuneLattice prune stale noise" {
    var lattice = try RuneLattice.init(std.testing.allocator, 256, null);
    defer lattice.deinit();

    // Observe a rune at time 0
    _ = lattice.observe(vsa.generate(42), 0xABCD, 0);
    try std.testing.expectEqual(@as(u32, 1), lattice.active_count);

    // Prune at a time well past the TTL
    const summary = lattice.prune(triad.RANK_NOISE_TTL_MS + 1);
    try std.testing.expectEqual(@as(u32, 1), summary.pruned);
    try std.testing.expectEqual(@as(u32, 0), lattice.active_count);
}

test "RuneLattice prune does not remove verified runes" {
    var lattice = try RuneLattice.init(std.testing.allocator, 256, null);
    defer lattice.deinit();

    const slot = lattice.observe(vsa.generate(42), 0xABCD, 0);
    try std.testing.expect(slot != null);

    // Verify the rune
    lattice.verify(slot.?, 0);

    // Prune should NOT remove it
    const summary = lattice.prune(triad.RANK_NOISE_TTL_MS * 100);
    try std.testing.expectEqual(@as(u32, 0), summary.pruned);
    try std.testing.expectEqual(@as(u32, 1), lattice.active_count);
}

test "RuneLattice rank distribution" {
    var lattice = try RuneLattice.init(std.testing.allocator, 256, null);
    defer lattice.deinit();

    _ = lattice.observe(vsa.generate(1), 0x1, 0);
    _ = lattice.observe(vsa.generate(2), 0x2, 0);
    const slot3 = lattice.observe(vsa.generate(3), 0x3, 0);
    if (slot3) |s| lattice.verify(s, 0);

    const dist = lattice.getRankDistribution();
    try std.testing.expectEqual(@as(u32, 1), dist[0]); // Verified (rank 1)
    try std.testing.expectEqual(@as(u32, 2), dist[4]); // Noise (rank 5)
}

test "RuneLattice search respects rank filter" {
    var lattice = try RuneLattice.init(std.testing.allocator, 256, null);
    defer lattice.deinit();

    const vec = vsa.generate(42);
    _ = lattice.observe(vec, 0xABCD, 0);

    // Search with min_rank = pattern should NOT find a noise rune
    const result = lattice.search(vec, .pattern);
    try std.testing.expect(result == .not_found);

    // Search with min_rank = noise SHOULD find it
    const result2 = lattice.search(vec, .noise);
    try std.testing.expect(result2 == .found);
}

test "RuneLattice deduplication" {
    var lattice = try RuneLattice.init(std.testing.allocator, 256, null);
    defer lattice.deinit();

    const vec = vsa.generate(42);
    const slot1 = lattice.observe(vec, 0x1, 0);
    const slot2 = lattice.observe(vec, 0x2, 100);

    // Same vector should map to same slot (dedup via content hash)
    try std.testing.expectEqual(slot1.?, slot2.?);
    try std.testing.expectEqual(@as(u32, 1), lattice.active_count);
    try std.testing.expectEqual(@as(u32, 2), lattice.occurrences[slot1.?]);
}
