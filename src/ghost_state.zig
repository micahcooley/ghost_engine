const std = @import("std");
const vsa = @import("vsa_core.zig");
const config = @import("config.zig");
const sigil_runtime = @import("sigil_runtime.zig");
const sync = @import("sync.zig");
const sys = @import("sys.zig");

pub const GENESIS_SEED: u64 = 0x1415926535897932;
pub const FNV_OFFSET_BASIS: u64 = 0xcbf29ce484222325;
pub const FNV_PRIME: u64 = 0x100000001b3;
pub const UNIFIED_SIZE_BYTES: usize = config.UNIFIED_SIZE_BYTES;
pub const LATTICE_PAGE_BYTES: usize = config.CHECKSUM_BLOCK_SIZE;

const ByteRange = struct {
    start: usize,
    end: usize,
};

pub const BlockCache = struct {
    const Slot = struct {
        block_index: ?usize = null,
        buffer: []align(@alignOf(u64)) u8,
        valid_len: usize = 0,
        dirty: bool = false,
        pin_count: usize = 0,
        prev: ?usize = null,
        next: ?usize = null,
    };

    allocator: std.mem.Allocator,
    file: sys.FileHandle,
    file_size: usize,
    page_size: usize,
    cache_cap_bytes: usize,
    max_slots: usize,
    slots: std.ArrayListUnmanaged(Slot) = .empty,
    lru_head: ?usize = null,
    lru_tail: ?usize = null,
    mutex: sync.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator, path: []const u8, cache_cap_bytes: usize) !BlockCache {
        const file = if (std.fs.path.isAbsolute(path))
            try sys.openForReadWrite(allocator, path)
        else
            try sys.openForReadWrite(allocator, path);

        var cache = BlockCache{
            .allocator = allocator,
            .file = file,
            .file_size = UNIFIED_SIZE_BYTES,
            .page_size = LATTICE_PAGE_BYTES,
            .cache_cap_bytes = 0,
            .max_slots = 0,
        };
        errdefer cache.deinit();

        try cache.setCacheCap(cache_cap_bytes);
        return cache;
    }

    pub fn deinit(self: *BlockCache) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.flushAllLocked() catch {};
        for (self.slots.items) |slot| {
            self.allocator.free(slot.buffer);
        }
        self.slots.deinit(self.allocator);
        sys.closeFile(self.file);
        self.* = undefined;
    }

    pub fn flush(self: *BlockCache) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.flushAllLocked();
    }

    pub fn setCacheCap(self: *BlockCache, bytes: usize) !void {
        const rounded = @max(self.page_size, std.mem.alignBackward(usize, bytes, self.page_size));
        const target_slots = @max(@as(usize, 1), rounded / self.page_size);

        self.mutex.lock();
        defer self.mutex.unlock();

        if (target_slots < self.slots.items.len) {
            try self.evictUntilLocked(target_slots);
        }

        self.cache_cap_bytes = target_slots * self.page_size;
        self.max_slots = target_slots;
    }

    pub fn acquire(self: *BlockCache, byte_offset: usize, byte_len: usize, writable: bool) !Lease {
        if (byte_len == 0) return error.EmptyRange;
        if (byte_offset >= self.file_size) return error.OutOfBounds;
        if (byte_offset + byte_len > self.file_size) return error.OutOfBounds;

        const block_index = byte_offset / self.page_size;
        const block_offset = byte_offset % self.page_size;
        const block_len = self.blockDataLen(block_index);
        if (block_offset + byte_len > block_len) return error.CrossBlockAccess;

        self.mutex.lock();
        defer self.mutex.unlock();

        const slot_index = try self.ensureResidentLocked(block_index);
        var slot = &self.slots.items[slot_index];
        slot.pin_count += 1;
        if (writable) slot.dirty = true;
        self.moveToHeadLocked(slot_index);

        return .{
            .cache = self,
            .slot_index = slot_index,
            .bytes = slot.buffer[block_offset .. block_offset + byte_len],
            .released = false,
        };
    }

    fn blockDataLen(self: *const BlockCache, block_index: usize) usize {
        const start = block_index * self.page_size;
        if (start >= self.file_size) return 0;
        return @min(self.page_size, self.file_size - start);
    }

    fn ensureResidentLocked(self: *BlockCache, block_index: usize) !usize {
        if (self.findSlotLocked(block_index)) |slot_index| {
            return slot_index;
        }

        const slot_index = if (self.slots.items.len < self.max_slots)
            try self.allocateSlotLocked()
        else
            try self.selectVictimLocked();

        var slot = &self.slots.items[slot_index];
        if (slot.block_index != null) {
            try self.flushSlotLocked(slot_index);
        }

        const block_len = self.blockDataLen(block_index);
        @memset(slot.buffer, 0);
        if (block_len > 0) {
            try self.preadAll(slot.buffer[0..block_len], block_index * self.page_size);
        }

        slot.block_index = block_index;
        slot.valid_len = block_len;
        slot.dirty = false;
        self.moveToHeadLocked(slot_index);
        return slot_index;
    }

    fn allocateSlotLocked(self: *BlockCache) !usize {
        const buffer = try self.allocator.alignedAlloc(u8, @alignOf(u64), self.page_size);
        const slot_index = self.slots.items.len;
        try self.slots.append(self.allocator, .{
            .buffer = buffer,
        });
        self.insertAtHeadLocked(slot_index);
        return slot_index;
    }

    fn selectVictimLocked(self: *BlockCache) !usize {
        var current = self.lru_tail;
        while (current) |slot_index| : (current = self.slots.items[slot_index].prev) {
            if (self.slots.items[slot_index].pin_count == 0) return slot_index;
        }
        return error.AllPagesPinned;
    }

    fn evictUntilLocked(self: *BlockCache, target_slots: usize) !void {
        while (self.slots.items.len > target_slots) {
            const victim = try self.selectVictimLocked();
            try self.flushSlotLocked(victim);
            const buffer = self.slots.items[victim].buffer;
            self.unlinkLocked(victim);
            const last_index = self.slots.items.len - 1;
            if (victim != last_index) {
                self.slots.items[victim] = self.slots.items[last_index];
                self.repairLinksLocked(last_index, victim);
            }
            _ = self.slots.pop();
            self.allocator.free(buffer);
        }
    }

    fn flushAllLocked(self: *BlockCache) !void {
        for (self.slots.items, 0..) |_, slot_index| {
            try self.flushSlotLocked(slot_index);
        }
    }

    fn flushSlotLocked(self: *BlockCache, slot_index: usize) !void {
        var slot = &self.slots.items[slot_index];
        if (!slot.dirty or slot.block_index == null) return;
        try self.pwriteAll(slot.buffer[0..slot.valid_len], slot.block_index.? * self.page_size);
        slot.dirty = false;
    }

    fn findSlotLocked(self: *const BlockCache, block_index: usize) ?usize {
        for (self.slots.items, 0..) |slot, slot_index| {
            if (slot.block_index == block_index) return slot_index;
        }
        return null;
    }

    fn insertAtHeadLocked(self: *BlockCache, slot_index: usize) void {
        var slot = &self.slots.items[slot_index];
        slot.prev = null;
        slot.next = self.lru_head;
        if (self.lru_head) |head| self.slots.items[head].prev = slot_index;
        self.lru_head = slot_index;
        if (self.lru_tail == null) self.lru_tail = slot_index;
    }

    fn moveToHeadLocked(self: *BlockCache, slot_index: usize) void {
        if (self.lru_head == slot_index) return;
        self.unlinkLocked(slot_index);
        self.insertAtHeadLocked(slot_index);
    }

    fn unlinkLocked(self: *BlockCache, slot_index: usize) void {
        const prev = self.slots.items[slot_index].prev;
        const next = self.slots.items[slot_index].next;

        if (prev) |p| self.slots.items[p].next = next else self.lru_head = next;
        if (next) |n| self.slots.items[n].prev = prev else self.lru_tail = prev;

        self.slots.items[slot_index].prev = null;
        self.slots.items[slot_index].next = null;
    }

    fn repairLinksLocked(self: *BlockCache, old_index: usize, new_index: usize) void {
        if (self.lru_head == old_index) self.lru_head = new_index;
        if (self.lru_tail == old_index) self.lru_tail = new_index;

        if (self.slots.items[new_index].prev) |prev| {
            self.slots.items[prev].next = new_index;
        }
        if (self.slots.items[new_index].next) |next| {
            self.slots.items[next].prev = new_index;
        }
    }

    fn release(self: *BlockCache, slot_index: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (slot_index >= self.slots.items.len) return;
        if (self.slots.items[slot_index].pin_count > 0) {
            self.slots.items[slot_index].pin_count -= 1;
        }
    }

    fn preadAll(self: *BlockCache, buffer: []u8, offset: usize) !void {
        var total: usize = 0;
        while (total < buffer.len) {
            try sys.directRead(self.file, offset + total, buffer[total..]);
            total = buffer.len;
        }
    }

    fn pwriteAll(self: *BlockCache, buffer: []const u8, offset: usize) !void {
        var total: usize = 0;
        while (total < buffer.len) {
            try sys.directWrite(self.file, offset + total, buffer[total..]);
            total = buffer.len;
        }
    }

    pub const Lease = struct {
        cache: *BlockCache,
        slot_index: usize,
        bytes: []u8,
        released: bool,

        pub fn words(self: *const Lease) []u16 {
            std.debug.assert(self.bytes.len % @sizeOf(u16) == 0);
            return @as([*]u16, @ptrCast(@alignCast(self.bytes.ptr)))[0 .. self.bytes.len / @sizeOf(u16)];
        }

        pub fn release(self: *Lease) void {
            if (self.released) return;
            self.cache.release(self.slot_index);
            self.released = true;
        }
    };
};

pub const PagedLatticeProvider = struct {
    allocator: std.mem.Allocator,
    cache: BlockCache,

    pub fn init(allocator: std.mem.Allocator, path: []const u8, cache_cap_bytes: usize) !PagedLatticeProvider {
        return .{
            .allocator = allocator,
            .cache = try BlockCache.init(allocator, path, cache_cap_bytes),
        };
    }

    pub fn deinit(self: *PagedLatticeProvider) void {
        self.cache.deinit();
    }

    pub fn flush(self: *PagedLatticeProvider) !void {
        try self.cache.flush();
    }

    pub fn setCacheCap(self: *PagedLatticeProvider, bytes: u64) !void {
        try self.cache.setCacheCap(@intCast(bytes));
    }

    pub fn acquireBytes(self: *PagedLatticeProvider, byte_offset: usize, byte_len: usize, writable: bool) !BlockCache.Lease {
        return self.cache.acquire(byte_offset, byte_len, writable);
    }

    pub fn acquireWords(self: *PagedLatticeProvider, word_index: usize, word_count: usize, writable: bool) !BlockCache.Lease {
        return self.acquireBytes(word_index * @sizeOf(u16), word_count * @sizeOf(u16), writable);
    }

    fn blockByteRange(block_idx: usize) ByteRange {
        return UnifiedLattice.blockByteRange(block_idx);
    }

    fn readHash(self: *PagedLatticeProvider, block_idx: usize) !u64 {
        var lease = try self.acquireBytes(UnifiedLattice.HASH_OFFSET + block_idx * @sizeOf(u64), @sizeOf(u64), false);
        defer lease.release();
        return std.mem.bytesToValue(u64, lease.bytes[0..@sizeOf(u64)]);
    }

    fn writeHash(self: *PagedLatticeProvider, block_idx: usize, hash: u64) !void {
        var lease = try self.acquireBytes(UnifiedLattice.HASH_OFFSET + block_idx * @sizeOf(u64), @sizeOf(u64), true);
        defer lease.release();
        std.mem.writeInt(u64, lease.bytes[0..@sizeOf(u64)], hash, .little);
    }

    fn computeBlockHash(self: *PagedLatticeProvider, block_idx: usize) !u64 {
        const range = blockByteRange(block_idx);
        var lease = try self.acquireBytes(range.start, range.end - range.start, false);
        defer lease.release();
        return wyhash(GENESIS_SEED, std.hash.Fnv1a_64.hash(lease.bytes));
    }

    pub fn verifyBlock(self: *PagedLatticeProvider, block_idx: usize) !bool {
        const current_hash = try self.computeBlockHash(block_idx);
        const stored_hash = try self.readHash(block_idx);

        if (stored_hash == 0) {
            sys.print("[CHECKSUM] Block {d} initial hash: 0x{x}\n", .{ block_idx, current_hash });
            try self.writeHash(block_idx, current_hash);
            return true;
        }
        if (stored_hash != current_hash) {
            sys.print("[CHECKSUM] Block {d} mismatch! 0x{x} vs 0x{x}\n", .{ block_idx, stored_hash, current_hash });
            return false;
        }
        return true;
    }

    pub fn finalizeChecksums(self: *PagedLatticeProvider) !void {
        for (0..UnifiedLattice.BLOCK_COUNT) |block_idx| {
            try self.writeHash(block_idx, try self.computeBlockHash(block_idx));
        }
    }

    pub fn resetBlock(self: *PagedLatticeProvider, block_idx: usize) !void {
        const range = blockByteRange(block_idx);
        var lease = try self.acquireBytes(range.start, range.end - range.start, true);
        defer lease.release();
        @memset(lease.bytes, 0);
        try self.writeHash(block_idx, 0);
    }
};

pub const LatticeLease = union(enum) {
    mapped: []u16,
    paged: BlockCache.Lease,

    pub fn words(self: *LatticeLease) []u16 {
        return switch (self.*) {
            .mapped => |slice| slice,
            .paged => |*lease| lease.words(),
        };
    }

    pub fn release(self: *LatticeLease) void {
        switch (self.*) {
            .mapped => {},
            .paged => |*lease| lease.release(),
        }
    }
};

pub const LatticeProvider = union(enum) {
    mapped: *UnifiedLattice,
    paged: *PagedLatticeProvider,

    pub fn initMapped(lattice: *UnifiedLattice) LatticeProvider {
        return .{ .mapped = lattice };
    }

    pub fn initPaged(provider: *PagedLatticeProvider) LatticeProvider {
        return .{ .paged = provider };
    }

    pub fn setCacheCap(self: *LatticeProvider, bytes: u64) !void {
        switch (self.*) {
            .mapped => {},
            .paged => |provider| try provider.setCacheCap(bytes),
        }
    }

    pub fn acquireWords(self: *LatticeProvider, word_index: usize, word_count: usize, writable: bool) !LatticeLease {
        return switch (self.*) {
            .mapped => |lattice| blk: {
                const data = @constCast(lattice.getData());
                if (word_index + word_count > data.len) return error.OutOfBounds;
                break :blk .{ .mapped = data[word_index .. word_index + word_count] };
            },
            .paged => |provider| .{ .paged = try provider.acquireWords(word_index, word_count, writable) },
        };
    }

    pub fn verifyBlock(self: *LatticeProvider, block_idx: usize) !bool {
        return switch (self.*) {
            .mapped => |lattice| lattice.verifyBlock(block_idx),
            .paged => |provider| try provider.verifyBlock(block_idx),
        };
    }

    pub fn finalizeChecksums(self: *LatticeProvider) !void {
        switch (self.*) {
            .mapped => |lattice| lattice.finalizeChecksums(),
            .paged => |provider| try provider.finalizeChecksums(),
        }
    }

    pub fn resetBlock(self: *LatticeProvider, block_idx: usize) !void {
        switch (self.*) {
            .mapped => |lattice| lattice.resetBlock(block_idx),
            .paged => |provider| try provider.resetBlock(block_idx),
        }
    }

    pub fn flush(self: *LatticeProvider) !void {
        switch (self.*) {
            .mapped => {},
            .paged => |provider| try provider.flush(),
        }
    }
};

pub const UnifiedLattice = struct {
    // V31: Block Checksum Manifest — per-block hashes persisted at the tail of the 1GB buffer.
    // Hash space: 1GB / 64MB = 16 blocks * 8 bytes = 128 bytes.
    pub const HASH_OFFSET = UNIFIED_SIZE_BYTES - config.CHECKSUM_RESERVED_BYTES;
    pub const BLOCK_COUNT = config.CHECKSUM_BLOCK_COUNT;

    pub fn getData(self: *const UnifiedLattice) []const u16 {
        const ptr = @as([*]const u16, @ptrCast(@alignCast(self)));
        return ptr[0..(UNIFIED_SIZE_BYTES / 2)];
    }

    pub fn getHashes(self: *const UnifiedLattice) [*]u64 {
        const byte_ptr = @as([*]const u8, @ptrCast(@alignCast(self)));
        return @as([*]u64, @ptrCast(@alignCast(@constCast(byte_ptr + HASH_OFFSET))));
    }

    fn blockByteRange(block_idx: usize) ByteRange {
        const start = block_idx * config.CHECKSUM_BLOCK_SIZE;
        const end = if (block_idx + 1 == BLOCK_COUNT) HASH_OFFSET else start + config.CHECKSUM_BLOCK_SIZE;
        return .{ .start = start, .end = end };
    }

    fn computeBlockHash(self: *const UnifiedLattice, block_idx: usize) u64 {
        const data = self.getData();
        const range = blockByteRange(block_idx);
        const start = range.start / @sizeOf(u16);
        const end = range.end / @sizeOf(u16);
        const block_data = data[start..end];
        const byte_data = std.mem.sliceAsBytes(block_data);
        return wyhash(GENESIS_SEED, std.hash.Fnv1a_64.hash(byte_data));
    }

    pub fn verifyBlock(self: *const UnifiedLattice, block_idx: usize) bool {
        const current_hash = self.computeBlockHash(block_idx);
        const stored_hashes = self.getHashes();

        if (stored_hashes[block_idx] == 0) {
            sys.print("[CHECKSUM] Block {d} initial hash: 0x{x}\n", .{ block_idx, current_hash });
            stored_hashes[block_idx] = current_hash;
            return true;
        }
        if (stored_hashes[block_idx] != current_hash) {
            sys.print("[CHECKSUM] Block {d} mismatch! 0x{x} vs 0x{x}\n", .{ block_idx, stored_hashes[block_idx], current_hash });
            return false;
        }
        return true;
    }

    pub fn finalizeChecksums(self: *UnifiedLattice) void {
        const stored_hashes = self.getHashes();
        for (0..BLOCK_COUNT) |block_idx| {
            stored_hashes[block_idx] = self.computeBlockHash(block_idx);
        }
    }

    pub fn resetBlock(self: *UnifiedLattice, block_idx: usize) void {
        // WARNING: This zeroes the block. Data is destroyed, not recovered.
        // A true repair would require redundant encoding (e.g., erasure coding).
        const ptr = @as([*]u16, @ptrCast(@alignCast(self)));
        const data = ptr[0..(UNIFIED_SIZE_BYTES / 2)];
        const range = blockByteRange(block_idx);
        const start = range.start / @sizeOf(u16);
        const end = range.end / @sizeOf(u16);
        @memset(data[start..end], 0);
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
    structural: vsa.HyperVector,
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
    anchor_count: u64,

    energy_word_threshold: u16 = config.ENERGY_WORD_THRESHOLD,
    energy_phrase_threshold: u16 = config.ENERGY_PHRASE_THRESHOLD,

    pub fn init(allocator: std.mem.Allocator) !GhostSoul {
        return .{
            .structural = @splat(0),
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
            .anchor_count = 0,
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
        self.structural = vsa.bundle(self.structural, rune_vec, vsa.generate(self.lexical_rotor));
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
                self.phrase = vsa.bundle(self.phrase, self.structural, vsa.generate(self.phrase_rotor));
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
                self.anchor_count += 1;
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

    pub fn recentAnchorDrift(self: *const GhostSoul) ?u64 {
        if (self.anchor_count < 2) return null;

        const len = self.anchor_buffer.len;
        const latest = (@as(usize, self.anchor_idx) + len - 1) % len;
        const previous = (@as(usize, self.anchor_idx) + len - 2) % len;
        return vsa.hammingDistance(self.anchor_buffer[latest], self.anchor_buffer[previous]);
    }

    /// Penalize repetitive output: low conceptual drift between recent anchors means we're stuck.
    pub fn getBoredomPenalty(self: *const GhostSoul) u32 {
        const drift = self.recentAnchorDrift() orelse return 0;
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
