const std = @import("std");
const vsa = @import("vsa_core.zig");

pub const GENESIS_SEED: u64 = 0x5A5A5A5A5A5A5A5A;

/// ── Sovereign Architecture: Dual-State Engine ──
/// The Rotor provides the statistical spine (trigram CMS keys with ~33
/// observations per key during training). The Fractal State provides
/// holographic infinite context via rotate+XOR binding. Both coexist:
/// the rotor determines WHERE to look, the fractal state determines
/// HOW to interpret what we find.

// ── Avalanche Rotor: FNV-1a rolling hash ──
// Replaces the 24-bit bit-shift with an infinite-context word fingerprint.
// Compresses the entire word (since last TRP boundary) into a 64-bit key.
pub const FNV_OFFSET_BASIS: u64 = 14695981039346656037;
pub const FNV_PRIME: u64 = 1099511628211;

/// Solstice Decay: when lattice saturation exceeds this percentage,
/// trigger a global >> 1 to free counter headroom.
pub const SOLSTICE_THRESHOLD: u64 = 8000; // x10000 fixed-point: 80.00%

pub const GhostSoul = struct {
    syntax: vsa.HyperVector,
    phrase: vsa.HyperVector,
    concept: vsa.HyperVector,
    global: vsa.HyperVector,
    panopticon: vsa.Panopticon,
    active_context_hash: u64,
    entropy_flatline: bool, // Task 4 fallback state

    // ── Orthogonal Snap: Resonance Physics (Prediction Error) ──
    last_energy: u16,
    last_boundary: Boundary,

    // ── Dual-State: Rotor (spine) + Fractal (holographic memory) + Spell (word VSA) ──
    lexical_rotor: u64,
    semantic_rotor: u64,
    fractal_state: vsa.HyperVector,
    spell_vector: vsa.HyperVector,

    // Vectorial Gravity: Semantic Pool
    sentence_pool: vsa.HyperVector,
    meaning_matrix: ?*vsa.MeaningMatrix,
    allocator: std.mem.Allocator,

    // ── Rotor Satiation: Boredom/Decay ──
    rotor_history: [16]u64,
    history_ptr: usize,

    // ── Entropy Heartbeat ──
    rolling_buffer: [65536]u8,
    rolling_idx: u32,
    energy_word_threshold: u16,
    energy_sentence_threshold: u16,

    pub fn init(allocator: std.mem.Allocator) GhostSoul {
        return .{
            .syntax = @splat(0),
            .phrase = @splat(0),
            .concept = @splat(0),
            .global = @splat(0),
            .panopticon = vsa.Panopticon.init(allocator),
            .active_context_hash = GENESIS_SEED,
            .entropy_flatline = false,
            .last_energy = 1024,
            .last_boundary = .none,
            .lexical_rotor = FNV_OFFSET_BASIS,
            .semantic_rotor = FNV_OFFSET_BASIS,
            .fractal_state = vsa.generate(GENESIS_SEED),
            .spell_vector = @splat(0),
            .sentence_pool = @splat(0),
            .meaning_matrix = null,
            .allocator = allocator,
            .rotor_history = [_]u64{0} ** 16,
            .history_ptr = 0,
            .rolling_buffer = [_]u8{0} ** 65536,
            .rolling_idx = 0,
            .energy_word_threshold = 700,
            .energy_sentence_threshold = 500,
        };
    }

    pub fn deinit(self: *GhostSoul) void {
        self.panopticon.deinit();
    }

    /// Avalanche Rotor: FNV-1a rolling hash. Each byte is XOR-multiply
    /// compressed into a 64-bit fingerprint of the current sequence.
    /// Infinite context depth: the rotor carries the state of every previous
    /// character in the session. O(1) cost. 
    pub fn pushRotor(self: *GhostSoul, raw_char: u8) void {
        self.lexical_rotor = (self.lexical_rotor ^ @as(u64, raw_char)) *% FNV_PRIME;
        
        self.semantic_rotor = (self.semantic_rotor ^ @as(u64, raw_char)) *% FNV_PRIME;
        const is_boundary = (raw_char == ' ' or raw_char == '.' or raw_char == ';' or raw_char == '=');
        if (is_boundary) self.semantic_rotor = FNV_OFFSET_BASIS;

        // Update history for satiation
        self.rotor_history[self.history_ptr] = self.lexical_rotor;
        self.history_ptr = (self.history_ptr + 1) % 16;
    }

    pub fn pushRotorFast(self: *GhostSoul, raw_char: u8) void {
        self.lexical_rotor = (self.lexical_rotor ^ @as(u64, raw_char)) *% FNV_PRIME;
        self.semantic_rotor = (self.semantic_rotor ^ @as(u64, raw_char)) *% FNV_PRIME;
        const is_boundary = (raw_char == ' ' or raw_char == '.' or raw_char == ';' or raw_char == '=');
        if (is_boundary) self.semantic_rotor = FNV_OFFSET_BASIS;
    }

    pub fn getBoredomPenalty(self: *const GhostSoul, rotor: u64) u32 {
        var count: u32 = 0;
        for (self.rotor_history) |h| {
            if (h == rotor) count += 1;
        }
        return count * 40; // Calibrated: 40 energy penalty per repetition
    }

    /// Rotor as u64 for CMS addressing — direct FNV-1a fingerprint.
    pub fn rotorKey(self: *const GhostSoul) u64 {
        return self.lexical_rotor;
    }

    /// Fractal State Update: MAP operation (Multiply-Add-Permute).
    /// Rotates the 1024-bit vector and XORs with the character's permanent
    /// random signature. O(1) cost, infinite context depth.
    pub fn fractalPush(self: *GhostSoul, raw_char: u8) void {
        self.fractal_state = vsa.rotate(self.fractal_state, 1) ^ vsa.generate(raw_char);
    }

    /// Fractal Resonance: hamming distance between two fractal states.
    /// Lower = more coherent. Used by REASON to measure which candidate
    /// keeps the holographic memory on a stable attractor.
    pub fn fractalResonance(self: *const GhostSoul, candidate_state: vsa.HyperVector) u64 {
        return vsa.hammingDistance(self.fractal_state, candidate_state);
    }

    /// Spell Vector Push: rotate + XOR binding for word-level VSA encoding.
    /// Accumulates characters into a 1024-bit "micro spell" that represents
    /// the current word. Handles words of any length (infinite capacity).
    pub fn spellPush(self: *GhostSoul, raw_char: u8) void {
        self.spell_vector = vsa.rotate(self.spell_vector, 1) ^ vsa.generate(raw_char);
    }

    /// Detect boundary type from Resonance Energy.
    pub fn detectSnap(self: *const GhostSoul, energy: u16) Boundary {
        if (energy <= self.energy_sentence_threshold) return .sentence;
        if (energy < self.energy_word_threshold) return .word;
        return .none;
    }

    /// The core evolution: absorb a new token into the state.
    /// Boundaries are detected dynamically via Prediction Error (Resonance Drop).
    /// Returns the semantic drift occurred (if any).
    pub fn absorb(self: *GhostSoul, token_vec: vsa.HyperVector, raw_char: u8, energy: ?u16) !u64 {
        self.rolling_buffer[self.rolling_idx % 65536] = raw_char;
        self.rolling_idx +%= 1;
        // Phase-Change Detector (Entropy Heartbeat) - Recalibrate every 64KB window
        if (self.rolling_idx % 65536 == 0) {
            var hamming_variance: u32 = 0;
            // Sample a stride to measure thermodynamic texture quickly
            for (1..8192) |i| {
                hamming_variance += @popCount(self.rolling_buffer[i*8] ^ self.rolling_buffer[(i-1)*8]);
            }
            
            if (hamming_variance == 0) {
                // --- Task 4: Baseline Structural Fallback (The Blindness Fix) ---
                // Data is perfectly flat. Fall back to ASCII delimiters.
                self.entropy_flatline = true;
            } else if (hamming_variance > 20000) {
                // High entropy (Code, Base64, Tables)
                self.entropy_flatline = false;
                self.energy_word_threshold = 600;
                self.energy_sentence_threshold = 400;
            } else if (hamming_variance < 10000) {
                // Low entropy (Predictable formatting / Whitespace heavy)
                self.entropy_flatline = false;
                self.energy_word_threshold = 800;
                self.energy_sentence_threshold = 600;
            } else {
                // Normal English text
                self.entropy_flatline = false;
                self.energy_word_threshold = 700;
                self.energy_sentence_threshold = 500;
            }
        }

        // 1. Calculate Resonance (Prediction Error) BEFORE updating state
        if (energy) |e| {
            self.last_energy = e;
        } else if (self.meaning_matrix) |mm| {
            const expectation = mm.collapseToBinary(self.lexical_rotor);
            self.last_energy = vsa.calculateResonance(expectation, token_vec);
        } else {
            self.last_energy = 1024;
        }

        const boundary = if (self.entropy_flatline) blk: {
            // Task 4: Hardcoded ASCII Fallback
            if (raw_char == '\n' or raw_char == '\r' or raw_char == 0) break :blk Boundary.sentence;
            if (raw_char == ' ' or raw_char == '\t' or raw_char == ',' or raw_char == ';') break :blk Boundary.word;
            break :blk Boundary.none;
        } else self.detectSnap(self.last_energy);

        self.last_boundary = boundary;

        // 2. Update state based on boundary detection
        self.pushRotor(raw_char);
        self.fractalPush(raw_char);

        // Continuous Concept Update (every byte)
        self.concept = vsa.bundle(vsa.permute(self.concept), token_vec, vsa.generate(0xD00));

        // Accumulate spell_vector only for non-boundary characters
        if (boundary == .none) {
            self.spellPush(raw_char);
        }

        try self.panopticon.pushByte(raw_char);
        self.sentence_pool = vsa.bundle(self.sentence_pool, token_vec, vsa.generate(0x1337));
        self.syntax = vsa.bundle(vsa.permute(self.syntax), token_vec, vsa.generate(0xB00));
        self.phrase = vsa.bundle(vsa.permute(self.phrase), token_vec, vsa.generate(0xC00));
        var drift: u64 = 0;

        // Word-level semantic gravity at any snap boundary (using spell_vector)
        if (boundary != .none) {
            if (self.meaning_matrix) |mm| {
                const word_hash = vsa.collapse(self.spell_vector);
                drift = mm.applyGravity(word_hash, self.concept);
            }
            self.spell_vector = @splat(0);
        }

        switch (boundary) {
            .sentence, .paragraph => {
                self.concept = vsa.bundle(self.concept, self.phrase, vsa.generate(0xD10));
                try self.panopticon.markSentence(self.concept);
                self.sentence_pool = @splat(0);
                self.active_context_hash = wyhash(self.active_context_hash, vsa.collapse(self.concept));
            },
            else => {},
        }
        return drift;
    }

    /// Simulation absorb for lookahead -- mirrors absorb() physics.
    pub fn simulateAbsorb(self: *GhostSoul, token_vec: vsa.HyperVector, raw_char: u8, energy: ?u16) void {
        // 1. Calculate Resonance
        if (energy) |e| {
            self.last_energy = e;
        } else if (self.meaning_matrix) |mm| {
            const expectation = mm.collapseToBinary(self.lexical_rotor);
            self.last_energy = vsa.calculateResonance(expectation, token_vec);
        } else {
            self.last_energy = 1024;
        }

        const boundary = self.detectSnap(self.last_energy);
        self.last_boundary = boundary;

        // 2. Update state
        self.pushRotor(raw_char);
        self.fractalPush(raw_char);

        self.concept = vsa.bundle(vsa.permute(self.concept), token_vec, vsa.generate(0xD00));

        if (boundary == .none) {
            self.spellPush(raw_char);
        }

        self.sentence_pool = vsa.bundle(self.sentence_pool, token_vec, vsa.generate(0x1337));
        self.syntax = vsa.bundle(vsa.permute(self.syntax), token_vec, vsa.generate(0xB00));
        self.phrase = vsa.bundle(vsa.permute(self.phrase), token_vec, vsa.generate(0xC00));

        if (boundary != .none) {
            self.spell_vector = @splat(0);
        }

        switch (boundary) {
            .sentence, .paragraph => {
                self.concept = vsa.bundle(self.concept, self.phrase, vsa.generate(0xD10));
                self.active_context_hash = wyhash(self.active_context_hash, vsa.collapse(self.concept));
            },
            else => {},
        }
    }

    pub fn contextVector(self: *const GhostSoul) vsa.HyperVector {
        const s1 = self.syntax;
        const s2 = rotateTrack(self.phrase, 3);
        const s3 = rotateTrack(self.concept, 7);
        const s4 = rotateTrack(self.global, 11);
        return s1 ^ s2 ^ s3 ^ s4;
    }

    pub inline fn rotateTrack(v: vsa.HyperVector, comptime n: comptime_int) vsa.HyperVector {
        var result: vsa.HyperVector = undefined;
        inline for (0..16) |i| {
            result[i] = v[(i + n) % 16];
        }
        return result;
    }
};

pub const Boundary = enum(u8) {
    none = 0,
    word = 1,
    sentence = 2,
    paragraph = 3,
};




// ────────────────────────────────────────────────────────────────
// The Unified 1GB Holographic Monolith
// ────────────────────────────────────────────────────────────────
pub const UNIFIED_ENTRIES: usize = 536_870_912;
pub const UNIFIED_SIZE_BYTES: usize = UNIFIED_ENTRIES * 2;

pub const DOMAIN_SYNTAX: u64    = 0x9E3779B97F4A7C15;
pub const DOMAIN_INTUITION: u64 = 0x6C62272E07BB0142;
pub const DOMAIN_CONCEPT: u64   = 0xC7115792D0E47B43;
pub const DOMAIN_ROLES: u64     = 0x517CC1B727220A95;
pub const DOMAIN_TRINITY: u64   = 0x3C2B1A0987654321;
pub const DOMAIN_MOMENTUM: u64  = 0xA5A5A5A5A5A5A5A5;

/// ── Koryphaios Protocol: Hemispheric Domain Isolation ──
/// DOMAIN_STYLE is XOR-mixed into Manager hemisphere lattice writes (Lanes 0–7).
/// DOMAIN_FACT is XOR-mixed into Critic hemisphere lattice writes (Lanes 8–15).
/// These seeds are orthogonal to all existing domains and to each other.
pub const DOMAIN_STYLE: u64     = 0xD15C0_DEAD_BEEF_01;
pub const DOMAIN_FACT: u64      = 0xFAC75_C0DE_CAFE_02;

/// ── Phantom Lobe: 128MB Dense Cartridge Format ──
/// The Console & Cartridge architecture. Each lobe is a focused 128MB
/// CMS array that the OS pages directly into L3 cache on first touch.
/// Zero allocation, zero copy — MapViewOfFile is the only instruction.
///
/// File Layout:
///   [0..127]     : VSA Identity Header (128 bytes = 1 HyperVector)
///   [128..end]   : Dense CMS array (67,108,864 × u16 = 128 MiB)
///   Total size   : 134,217,856 bytes
pub const LOBE_CMS_ENTRIES: u32 = 67_108_864;               // 128 MiB / sizeof(u16)
pub const LOBE_CMS_BYTES: usize = @as(usize, LOBE_CMS_ENTRIES) * 2;  // 134,217,728 bytes
pub const LOBE_HEADER_SIZE: usize = 128;                     // 1 HyperVector
pub const LOBE_TOTAL_SIZE: usize = LOBE_HEADER_SIZE + LOBE_CMS_BYTES; // 134,217,856 bytes

pub const LOBE_TILE_SIZE: usize = 2 * 1024 * 1024; // 2 MiB matching x86_64 Huge Page
pub const LOBE_TILE_COUNT: usize = 64;             // 128 MiB / 2 MiB

pub const TileManager = struct {
    lobe: *const PhantomLobe,

    /// Predicted prefetch for a set of candidate bytes.
    /// Calculates the CMS probe locations and triggers Windows PrefetchVirtualMemory
    /// on the specific 2MB tiles those probes land in.
    pub fn prefetchTilesForCandidates(self: *const TileManager, context: u64, domain: u64, candidates: []const u8) void {
        const base_ptr = self.lobe.data orelse return;
        var tile_mask: u64 = 0; // 64 bits = 64 tiles

        for (candidates) |cb| {
            const h = wyhash(context ^ domain, @as(u64, cb));
            const s: u32 = LOBE_CMS_ENTRIES / 4;
            const probes = [4]u32{
                @as(u32, @truncate(h & 0xFFFFFFFF)) % s,
                (@as(u32, @truncate(h >> 32)) % s) + s,
                (@as(u32, @truncate(wyhash(h, 0x12345678))) % s) + (s * 2),
                (@as(u32, @truncate(wyhash(h, 0x87654321))) % s) + (s * 3),
            };

            inline for (probes) |idx| {
                const byte_offset = idx * 2;
                const tile_idx = @as(u6, @truncate(byte_offset / LOBE_TILE_SIZE));
                tile_mask |= (@as(u64, 1) << tile_idx);
            }
        }

        // Trigger Windows Prefetch for all "hot" tiles
        var i: u6 = 0;
        while (i < LOBE_TILE_COUNT) : (i += 1) {
            if ((tile_mask >> i) & 1 == 1) {
                const tile_addr = @as(?*anyopaque, @ptrFromInt(@intFromPtr(base_ptr) + (@as(usize, i) * LOBE_TILE_SIZE)));
                @import("sys.zig").prefetchMemory(tile_addr, LOBE_TILE_SIZE);
            }
        }
    }
};

pub const PhantomLobe = struct {
    /// The identity vector of this lobe (from the 128-byte header).
    /// Used for resonance matching against the soul's fractal_state.
    identity: vsa.HyperVector,

    /// Direct pointer to the dense CMS array (memory-mapped, zero-copy).
    /// Points to the first u16 AFTER the 128-byte header in the mapped file.
    data: ?[*]const u16,

    /// The underlying sys.MappedFile handle (for unmapping on swap).
    mapped: ?@import("sys.zig").MappedFile,

    /// Filesystem path of the loaded lobe (for swap detection).
    path: ?[]const u8,

    pub fn empty() PhantomLobe {
        return .{
            .identity = @splat(0),
            .data = null,
            .mapped = null,
            .path = null,
        };
    }

    /// Read a CMS value from the lobe's dense array.
    /// Uses the same 4-probe orthogonal CMS addressing as the Unified Lattice,
    /// but with the lobe's smaller address space (67M entries vs 536M).
    /// Single-cycle L3 cache hit on x86_64 once the page is warm.
    pub inline fn read(self: *const PhantomLobe, context: u64, char_byte: u8, domain: u64) u16 {
        const cms = self.data orelse return 0;
        const h = wyhash(context ^ domain, @as(u64, char_byte));
        const s: u32 = LOBE_CMS_ENTRIES / 4;
        const probes = [4]u32{
            @as(u32, @truncate(h & 0xFFFFFFFF)) % s,
            (@as(u32, @truncate(h >> 32)) % s) + s,
            (@as(u32, @truncate(wyhash(h, 0x12345678))) % s) + (s * 2),
            (@as(u32, @truncate(wyhash(h, 0x87654321))) % s) + (s * 3),
        };
        var min: u16 = 0xFFFF;
        inline for (probes) |idx| {
            const val = cms[idx];
            if (val < min) min = val;
        }
        return if (min == 0xFFFF) 0 else min;
    }

    /// Check if this lobe is currently loaded.
    pub inline fn isLoaded(self: *const PhantomLobe) bool {
        return self.data != null;
    }

    /// Unmap the current lobe (flush from virtual address space).
    /// The OS will evict the pages from L3 cache as they become cold.
    pub fn unload(self: *PhantomLobe) void {
        if (self.mapped) |*m| {
            m.unmap();
        }
        self.data = null;
        self.mapped = null;
        self.path = null;
        self.identity = @splat(0);
    }

    pub fn tileManager(self: *const PhantomLobe) TileManager {
        return .{ .lobe = self };
    }
};
// These domain hashes feed into the CMS for coordinate-aware etching.
// For text (1D), only SPATIAL_X matters (sequence position).
// For images (2D), SPATIAL_X and SPATIAL_Y encode the grid.
// For audio (1D+T), SPATIAL_X is the frequency bin, TEMPORAL is time.
pub const DOMAIN_SPATIAL_X: u64 = 0x7A7A7A7A7A7A7A7A;
pub const DOMAIN_SPATIAL_Y: u64 = 0x3B3B3B3B3B3B3B3B;
pub const DOMAIN_TEMPORAL: u64  = 0x4C4C4C4C4C4C4C4C;

// ── Topology: The Shape of the Canvas ──
pub const Topology = enum(u8) {
    text_1d = 0,
    image_2d = 1,
    audio_1d_time = 2,
};

// ── The MesoLattice: Universal Canvas ──
// A pre-allocated grid of 1024-bit vectors. Zero allocation once booted.
// Topology determines how indices map to spatial/temporal coordinates.
// 1D text: sequential chain. 2D image: grid. 1D+T audio: bins over time.
pub const MESO_MAX_CELLS: u32 = 4096;

pub const MesoLattice = struct {
    topology: Topology,
    width: u32,
    height: u32,
    active_count: u32,
    cells: [MESO_MAX_CELLS]vsa.HyperVector,
    noise: [MESO_MAX_CELLS]u16,
    cursor: u32,

    pub fn initText() MesoLattice {
        return .{
            .topology = .text_1d,
            .width = MESO_MAX_CELLS,
            .height = 1,
            .active_count = 0,
            .cells = [_]vsa.HyperVector{@as(vsa.HyperVector, @splat(0))} ** MESO_MAX_CELLS,
            .noise = [_]u16{0} ** MESO_MAX_CELLS,
            .cursor = 0,
        };
    }

    pub fn initImage(w: u32, h: u32) MesoLattice {
        const count = @min(w * h, MESO_MAX_CELLS);
        return .{
            .topology = .image_2d,
            .width = w,
            .height = h,
            .active_count = count,
            .cells = [_]vsa.HyperVector{@as(vsa.HyperVector, @splat(0))} ** MESO_MAX_CELLS,
            .noise = [_]u16{0} ** MESO_MAX_CELLS,
            .cursor = 0,
        };
    }

    pub fn initAudio(bins: u32, time_steps: u32) MesoLattice {
        const count = @min(bins * time_steps, MESO_MAX_CELLS);
        return .{
            .topology = .audio_1d_time,
            .width = bins,
            .height = time_steps,
            .active_count = count,
            .cells = [_]vsa.HyperVector{@as(vsa.HyperVector, @splat(0))} ** MESO_MAX_CELLS,
            .noise = [_]u16{0} ** MESO_MAX_CELLS,
            .cursor = 0,
        };
    }

    /// Cell index from 2D coordinates. Wraps for safety.
    pub inline fn cellIndex(self: *const MesoLattice, x: u32, y: u32) u32 {
        return (y % self.height) * self.width + (x % self.width);
    }

    /// Coordinate-aware CMS hash: mixes spatial position into the domain hash.
    /// This is what makes the same concept produce different vectors at different
    /// positions in the canvas — the topology mask.
    pub fn coordHash(self: *const MesoLattice, x: u32, y: u32) u64 {
        var h: u64 = DOMAIN_SPATIAL_X ^ @as(u64, x);
        switch (self.topology) {
            .text_1d => {
                h = wyhash(h, @as(u64, x));
            },
            .image_2d => {
                h = wyhash(h ^ DOMAIN_SPATIAL_Y, @as(u64, y));
            },
            .audio_1d_time => {
                h = wyhash(h ^ DOMAIN_TEMPORAL, @as(u64, y));
            },
        }
        return h;
    }

    /// Write a vector to the canvas at a position.
    pub inline fn setCell(self: *MesoLattice, x: u32, y: u32, vec: vsa.HyperVector) void {
        const idx = self.cellIndex(x, y);
        self.cells[idx] = vec;
    }

    /// Read a vector from the canvas.
    pub inline fn getCell(self: *const MesoLattice, x: u32, y: u32) vsa.HyperVector {
        return self.cells[self.cellIndex(x, y)];
    }

    /// Advance the cursor for sequential (1D) resolution.
    pub inline fn advance(self: *MesoLattice) void {
        self.cursor +|= 1;
        if (self.cursor >= MESO_MAX_CELLS) self.cursor = 0;
    }

    /// Reset canvas for a new generation pass.
    pub fn reset(self: *MesoLattice) void {
        self.cursor = 0;
        self.noise = [_]u16{0} ** MESO_MAX_CELLS;
    }
};

pub const UnifiedLattice = struct {
    data: [UNIFIED_ENTRIES]u16,

    pub fn etch(self: *UnifiedLattice, context: u64, char_byte: u8, domain: u64) void {
        const LEAKY_MASK: u64 = 0xEFEFEFEFEFEFEFEF;
        const leaky_domain = domain & LEAKY_MASK;
        const h = wyhash(context ^ leaky_domain, @as(u64, char_byte));
        const probes = getProbesUnified(h);
        inline for (probes) |idx| {
            const current = self.data[idx];
            if (current == 0) {
                self.data[idx] = 1;
            } else {
                // Probabilistic Leaky Etching: rand() % current == 0
                // Math flattening: frequency bulb scales down naturally
                if ((wyhash(h, idx) % @as(u64, current)) == 0) {
                    if (current < 65535) self.data[idx] += 1;
                }
            }
        }
    }

    /// Prefetch the cache lines that etch() will touch, without writing.
    /// Call this N bytes ahead of the actual etch to warm L1/L2 cache.
    /// On x86-64, compiles to a single PREFETCHW instruction per probe.
    pub fn prefetchEtch(self: *const UnifiedLattice, context: u64, char_byte: u8, domain: u64) void {
        const LEAKY_MASK: u64 = 0xEFEFEFEFEFEFEFEF;
        const leaky_domain = domain & LEAKY_MASK;
        const h = wyhash(context ^ leaky_domain, @as(u64, char_byte));
        const probes = getProbesUnified(h);
        inline for (probes) |idx| {
            @prefetch(&self.data[idx], .{ .rw = .write, .locality = 3, .cache = .data });
        }
    }

    pub fn read(self: *const UnifiedLattice, context: u64, char_byte: u8, domain: u64) u16 {
        const LEAKY_MASK: u64 = 0xEFEFEFEFEFEFEFEF;
        const leaky_domain = domain & LEAKY_MASK;
        const h = wyhash(context ^ leaky_domain, @as(u64, char_byte));
        const probes = getProbesUnified(h);
        var min: u16 = 0xFFFF;
        inline for (probes) |idx| {
            if (self.data[idx] < min) min = self.data[idx];
        }
        return min;
    }

    fn getProbesUnified(h: u64) [4]u32 {
        const s: u32 = UNIFIED_ENTRIES / 4;
        return .{
            @as(u32, @truncate(h & 0xFFFFFFFF)) % s,
            (@as(u32, @truncate(h >> 32)) % s) + s,
            (@as(u32, @truncate(wyhash(h, 0x12345678))) % s) + (s * 2),
            (@as(u32, @truncate(wyhash(h, 0x87654321))) % s) + (s * 3),
        };
    }

    /// Solstice Decay: global >> 1 across the entire 1GB Monolith.
    /// Halves all counters to free headroom, preserving relative rankings.
    /// Called when sampled occupancy exceeds SOLSTICE_THRESHOLD.
    /// Global shift and check for Scaling Realignment (V23).
    /// Returns true if expansion is required (saturation exceeds 85.00%).
    pub fn solsticeDecay(self: *UnifiedLattice) bool {
        const occ = self.sampleOccupancy(0x1337);
        for (&self.data) |*entry| {
            entry.* >>= 1;
        }
        return occ > 8500;
    }

    /// Chunked Solstice Decay: process 1MB at a time to avoid stalls.
    /// Returns true when a full pass is complete.
    pub const SOLSTICE_CHUNK: usize = 524_288; // 1MB / sizeof(u16)
    pub fn chunkedSolsticeDecay(self: *UnifiedLattice, position: *usize) bool {
        const end = @min(position.* + SOLSTICE_CHUNK, UNIFIED_ENTRIES);
        for (position.*..end) |i| {
            self.data[i] >>= 1;
        }
        position.* = end;
        if (position.* >= UNIFIED_ENTRIES) {
            position.* = 0;
            return true;
        }
        return false;
    }

    /// Sample occupancy: integer percentage. Zero floats.
    pub fn sampleOccupancy(self: *const UnifiedLattice, seed: u64) u64 {
        var non_zero: usize = 0;
        const samples: u64 = 10000;
        var s = seed;
        for (0..samples) |_| {
            s = wyhash(s, 0x1337);
            const idx = s % UNIFIED_ENTRIES;
            if (self.data[idx] > 0) non_zero += 1;
        }
        return (non_zero * 10000) / samples;
    }
};

pub inline fn wyhash(state: u64, input: u64) u64 {
    const x = state ^ 0x60bee2bee120fc15;
    const y = input ^ 0xa3b195354a39b70d;
    const m = @as(u128, x) * @as(u128, y);
    return @as(u64, @truncate(m ^ (m >> 64)));
}
