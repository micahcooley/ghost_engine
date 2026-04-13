const std = @import("std");
const vsa = @import("vsa_core.zig");
const config = @import("config.zig");
const sigil_runtime = @import("sigil_runtime.zig");

pub const GENESIS_SEED: u64 = 0x1415926535897932;
pub const FNV_OFFSET_BASIS: u64 = 0xcbf29ce484222325;
pub const FNV_PRIME: u64 = 0x100000001b3;
pub const UNIFIED_SIZE_BYTES: usize = config.UNIFIED_SIZE_BYTES;

pub const UnifiedLattice = struct {
    // V31: Block Checksum Manifest — per-block hashes persisted at the tail of the 1GB buffer.
    // Hash space: 1GB / 64MB = 16 blocks * 8 bytes = 128 bytes.
    pub const HASH_OFFSET = UNIFIED_SIZE_BYTES - config.CHECKSUM_RESERVED_BYTES;

    pub fn getData(self: *const UnifiedLattice) []const u16 {
        const ptr = @as([*]const u16, @ptrCast(@alignCast(self)));
        return ptr[0 .. (UNIFIED_SIZE_BYTES / 2)];
    }


    pub fn getHashes(self: *const UnifiedLattice) [*]u64 {
        const byte_ptr = @as([*]const u8, @ptrCast(@alignCast(self)));
        return @as([*]u64, @ptrCast(@constCast(@alignCast(byte_ptr + HASH_OFFSET))));
    }

    pub fn verifyBlock(self: *const UnifiedLattice, block_idx: usize) bool {
        const sys = @import("sys.zig");
        const block_size_u16 = config.CHECKSUM_BLOCK_SIZE / 2;
        const start = block_idx * block_size_u16;
        const data = self.getData();
        const block_data = data[start .. start + block_size_u16];
        const byte_data = std.mem.sliceAsBytes(block_data);
        
        const current_hash = wyhash(GENESIS_SEED, std.hash.Fnv1a_64.hash(byte_data));
        const stored_hashes = self.getHashes();
        
        if (stored_hashes[block_idx] == 0) {
            sys.print("[CHECKSUM] Block {d} initial hash: 0x{x}\n", .{block_idx, current_hash});
            stored_hashes[block_idx] = current_hash;
            return true;
        }
        if (stored_hashes[block_idx] != current_hash) {
            sys.print("[CHECKSUM] Block {d} mismatch! 0x{x} vs 0x{x}\n", .{block_idx, stored_hashes[block_idx], current_hash});
            return false;
        }
        return true;
    }

    pub fn resetBlock(self: *UnifiedLattice, block_idx: usize) void {
        const block_size_u16 = config.CHECKSUM_BLOCK_SIZE / 2;
        const start = block_idx * block_size_u16;
        // WARNING: This zeroes the block. Data is destroyed, not recovered.
        // A true repair would require redundant encoding (e.g., erasure coding).
        const ptr = @as([*]u16, @ptrCast(@alignCast(self)));
        const data = ptr[0 .. (UNIFIED_SIZE_BYTES / 2)];
        @memset(data[start .. start + block_size_u16], 0);
        const stored_hashes = self.getHashes();
        stored_hashes[block_idx] = 0; // Reset for re-etch
    }
};

pub const MesoLattice = struct {
    pub const TEXT_BUFFER_SIZE: usize = 4096;

    cells: []vsa.HyperVector,
    noise: []u16,
    topology: enum { text_1d, image_2d, audio_1d_time } = .text_1d,
    cursor: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    allocator: std.mem.Allocator,

    pub fn initText(allocator: std.mem.Allocator) !MesoLattice {
        const cells = try allocator.alloc(vsa.HyperVector, TEXT_BUFFER_SIZE);
        @memset(std.mem.sliceAsBytes(cells), 0);
        const noise = try allocator.alloc(u16, TEXT_BUFFER_SIZE);
        @memset(noise, 0);
        return .{
            .cells = cells,
            .noise = noise,
            .topology = .text_1d,
            .cursor = 0,
            .width = 0,
            .height = 0,
            .allocator = allocator,
        };
    }

    pub fn initGrid(allocator: std.mem.Allocator, w: u32, h: u32) !MesoLattice {
        const total = @as(usize, w) * h;
        const cells = try allocator.alloc(vsa.HyperVector, total);
        @memset(std.mem.sliceAsBytes(cells), 0);
        const noise = try allocator.alloc(u16, total);
        @memset(noise, 0);
        return .{
            .cells = cells,
            .noise = noise,
            .topology = .image_2d,
            .cursor = 0,
            .width = w,
            .height = h,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MesoLattice) void {
        self.allocator.free(self.cells);
        self.allocator.free(self.noise);
    }

    pub fn cellIndex(self: *const MesoLattice, x: usize, y: usize) usize {
        return y * self.width + x;
    }

    pub fn getCell(self: *const MesoLattice, x: usize, y: usize) vsa.HyperVector {
        const idx = self.cellIndex(x, y);
        if (idx >= self.cells.len) return @splat(@as(u64, 0));
        return self.cells[idx];
    }

    pub fn setCell(self: *MesoLattice, x: usize, y: usize, vec: vsa.HyperVector) void {
        const idx = self.cellIndex(x, y);
        if (idx >= self.cells.len) return;
        self.cells[idx] = vec;
    }

    pub fn advance(self: *MesoLattice) void {
        self.cursor += 1;
    }

    pub fn coordHash(self: *const MesoLattice, x: usize, y: usize) u64 {
        _ = self;
        const combined = (@as(u64, x) << 32) | @as(u64, y);
        return wyhash(GENESIS_SEED, combined);
    }
};

pub const GhostSoul = struct {
    syntax: vsa.HyperVector,
    phrase: vsa.HyperVector,
    concept: vsa.HyperVector,
    global: vsa.HyperVector,
    fractal_state: vsa.HyperVector = @splat(0),
    spell_vector: vsa.HyperVector = @splat(0),
    sentence_pool: vsa.HyperVector = @splat(0),
    panopticon: vsa.PagedPanopticon,
    meaning_matrix: ?*vsa.MeaningMatrix = null,
    active_context_hash: u64,
    entropy_flatline: bool,

    last_energy: u16,
    last_boundary: vsa.Boundary,
    spatial_rotor: vsa.HyperRotor,
    lexical_rotor: u64,
    phrase_rotor: u64,
    concept_rotor: u64,
    semantic_rotor: u64,
    rune_count: u64,
    
    rolling_idx: u32,
    
    // Anchor Buffer: 16 most recent conceptual snapshots
    anchor_buffer: [16]vsa.HyperVector,
    anchor_idx: u4,

    energy_word_threshold: u16 = config.ENERGY_WORD_THRESHOLD,
    energy_phrase_threshold: u16 = config.ENERGY_PHRASE_THRESHOLD,

    pub fn init(allocator: std.mem.Allocator) !GhostSoul {
        return .{
            .syntax = @splat(0),
            .phrase = @splat(0),
            .concept = @splat(0),
            .global = @splat(0),
            .panopticon = try vsa.PagedPanopticon.init(allocator),
            .active_context_hash = GENESIS_SEED,
            .entropy_flatline = false,
            .last_energy = 1024,
            .last_boundary = .none,
            .spatial_rotor = vsa.HyperRotor.init(GENESIS_SEED),
            .lexical_rotor = FNV_OFFSET_BASIS,
            .phrase_rotor = FNV_OFFSET_BASIS,
            .concept_rotor = FNV_OFFSET_BASIS,
            .semantic_rotor = FNV_OFFSET_BASIS,
            .rune_count = 0,
            .rolling_idx = 0,
            .anchor_buffer = [_]vsa.HyperVector{@splat(0)} ** 16,
            .anchor_idx = 0,
        };
    }

    pub fn deinit(self: *GhostSoul) void {
        self.panopticon.deinit();
    }

    pub fn absorb(self: *GhostSoul, rune_vec: vsa.HyperVector, rune: u32, energy: ?u16) !u64 {
        self.spatial_rotor.evolve(rune);
        return self.absorbInternal(rune_vec, rune, energy, true);
    }

    pub fn simulateAbsorb(self: *GhostSoul, rune_vec: vsa.HyperVector, rune: u32, energy: ?u16) !void {
        _ = try self.absorbInternal(rune_vec, rune, energy, false);
    }

    fn absorbInternal(self: *GhostSoul, rune_vec: vsa.HyperVector, rune: u32, energy: ?u16, permanent: bool) !u64 {
        var boundary = if (energy) |e| self.detectBoundary(e) else .none;
        
        // V30: Syntactic Boundary Detection
        const syntactic = vsa.detectSyntacticBoundary(rune);
        if (@intFromEnum(syntactic) > @intFromEnum(boundary)) {
            boundary = syntactic;
        }

        self.last_boundary = boundary;

        // Update context rotors via non-linear projection
        self.lexical_rotor ^= rune;
        self.lexical_rotor = std.math.rotl(u64, self.lexical_rotor, 13) *% FNV_PRIME;

        // Fractal evolution: Bundle the new rune into the current lobes
        self.syntax = vsa.bundle(self.syntax, rune_vec, vsa.generate(self.lexical_rotor));
        self.phrase = vsa.bundle(vsa.rotate(self.phrase, 1), rune_vec, vsa.generate(self.phrase_rotor));

        // ── Cascade Etching: Multi-Scale Context Hierarchy ──
        // When a boundary is detected, lower-level state cascades into higher levels.
        // This mechanically forces the VSA lattice to build a true multi-dimensional
        // memory hierarchy (word -> phrase -> paragraph -> soul).
        switch (boundary) {
            .word => {
                // Word boundary (space-like): fold lexical state into phrase level
                self.phrase_rotor ^= self.lexical_rotor;
                self.phrase_rotor = std.math.rotl(u64, self.phrase_rotor, 13) *% FNV_PRIME;
                self.phrase = vsa.bundle(self.phrase, self.syntax, vsa.generate(self.phrase_rotor));
            },
            .phrase => {
                // Phrase boundary (punctuation): fold phrase into concept level
                self.phrase_rotor ^= self.lexical_rotor;
                self.phrase_rotor = std.math.rotl(u64, self.phrase_rotor, 13) *% FNV_PRIME;
                self.concept_rotor ^= self.phrase_rotor;
                self.concept_rotor = std.math.rotl(u64, self.concept_rotor, 13) *% FNV_PRIME;
                self.concept = vsa.bundle(self.concept, self.phrase, vsa.generate(self.concept_rotor));
            },
            .paragraph => {
                // Paragraph boundary: fold concept into semantic/global level
                self.concept_rotor ^= self.phrase_rotor;
                self.concept_rotor = std.math.rotl(u64, self.concept_rotor, 13) *% FNV_PRIME;
                self.semantic_rotor ^= self.concept_rotor;
                self.semantic_rotor = std.math.rotl(u64, self.semantic_rotor, 13) *% FNV_PRIME;
                self.global = vsa.bundle(self.global, self.concept, vsa.generate(self.semantic_rotor));
            },
            .soul => {
                // Soul boundary (deep context shift): integrate all levels
                self.semantic_rotor ^= self.concept_rotor;
                self.semantic_rotor = std.math.rotl(u64, self.semantic_rotor, 13) *% FNV_PRIME;
                self.global = vsa.bundle(self.global, self.concept, vsa.generate(self.semantic_rotor));
                self.sentence_pool = self.concept;
            },
            .none => {},
        }

        if (permanent) try self.panopticon.pushRune(rune);

        if (permanent) {
            self.rune_count += 1;
            if (self.rune_count % 64 == 0) {
                self.panopticon.markSentence(self.concept);
                self.anchor_buffer[self.anchor_idx] = self.concept;
                self.anchor_idx +%= 1;
            }
        }

        return self.lexical_rotor;
    }

    fn detectBoundary(self: *const GhostSoul, energy: u16) vsa.Boundary {
        if (energy < config.BOUNDARY_SOUL_THRESHOLD) return .soul;
        if (energy < config.BOUNDARY_PARAGRAPH_THRESHOLD) return .paragraph;
        if (energy < self.energy_phrase_threshold) return .phrase;
        if (energy < self.energy_word_threshold) return .word;
        return .none;
    }

    /// Penalize repetitive output: low conceptual drift between recent anchors means we're stuck.
    pub fn getBoredomPenalty(self: *const GhostSoul) u32 {
        if (self.anchor_idx < 2) return 0;
        const a = self.anchor_idx -% 1;
        const b = self.anchor_idx -% 2;
        const drift = vsa.hammingDistance(self.anchor_buffer[a], self.anchor_buffer[b]);
        if (drift < config.BOREDOM_DRIFT_HIGH) return sigil_runtime.getBoredomPenaltyHigh();
        if (drift < config.BOREDOM_DRIFT_LOW) return sigil_runtime.getBoredomPenaltyLow();
        return 0;
    }
};

pub fn wyhash(seed: u64, input: u64) u64 {
    var h = seed ^ (input *% 0xbf58476d1ce4e5b9);
    h = std.math.rotl(u64, h, 31) *% 0x94d049bb133111eb;
    return h ^ (h >> 31);
}
