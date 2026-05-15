const std = @import("std");
const vsa = @import("vsa_core.zig");
const semantic_encoder = @import("semantic_encoder.zig");
const sys = @import("sys.zig");

// ══════════════════════════════════════════════════════════════════════════
//  CONCEPT INDEX: Persistent Label → Lattice Slot Mapping
// ══════════════════════════════════════════════════════════════════════════
//
// The Rune Lattice stores 1024-bit HyperVectors with rank metadata.
// But it doesn't know what those vectors *mean* in human terms.
//
// The ConceptIndex is the reverse phone book:
//   Lattice Slot 42 → "QUIC Packet Loss Recovery" from rfc9000.txt:15230
//
// Without this, XOR-search returns a slot number and a distance — but
// you can't tell the user what concept they matched.
//
// Storage: JSON on disk alongside unified_lattice.bin.
// ══════════════════════════════════════════════════════════════════════════

pub const INDEX_VERSION = "ghost_concept_index_v2";
pub const DEFAULT_MAX_ENTRIES: usize = 65536;
pub const DEFAULT_SNIPPET_MAX_BYTES: usize = 512;

const BINARY_MAGIC = [4]u8{ 'G', 'C', 'I', 'B' };
const BINARY_VERSION: u32 = 1;

const DiskEntryFixed = extern struct {
    slot: u32,
    rank: u8,
    pad: [3]u8,
    source_offset: u64,
    source_length: u64,
    content_hash: u64,
    
    label_offset: u32,
    label_len: u32,
    source_file_offset: u32,
    source_file_len: u32,
    domain_tag_offset: u32,
    domain_tag_len: u32,
    snippet_offset: u32,
    snippet_len: u32,
};

pub const ConceptEntry = struct {
    /// Human-readable concept label (e.g., "QUIC Packet Loss Recovery").
    label: []u8,
    /// Lattice slot where this concept's vector is stored.
    slot: u32,
    /// Source file that produced this concept.
    source_file: []u8,
    /// Byte offset in the source file.
    source_offset: usize,
    /// Length in bytes of the source text.
    source_length: usize,
    /// Domain tag for cross-domain operations (e.g., "networking", "biology").
    domain_tag: []u8,
    /// Current rank (1=verified, 5=noise). Mirrors the lattice but cached here for fast queries.
    rank: u8,
    /// A snippet of the source text for display.
    snippet: []u8,
    /// The content hash at ingestion time (for staleness detection).
    content_hash: u64,

    pub fn deinit(self: *ConceptEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
        allocator.free(self.source_file);
        allocator.free(self.domain_tag);
        allocator.free(self.snippet);
        self.* = undefined;
    }
};

pub const ConceptIndex = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(ConceptEntry),
    /// Slot → entry index mapping for O(1) reverse lookup.
    slot_map: std.AutoHashMap(u32, usize),

    pub fn init(allocator: std.mem.Allocator) ConceptIndex {
        return .{
            .allocator = allocator,
            .entries = std.ArrayList(ConceptEntry).init(allocator),
            .slot_map = std.AutoHashMap(u32, usize).init(allocator),
        };
    }

    pub fn deinit(self: *ConceptIndex) void {
        for (self.entries.items) |*entry| entry.deinit(self.allocator);
        self.entries.deinit();
        self.slot_map.deinit();
    }

    /// Register a concept in the index.
    pub fn addEntry(
        self: *ConceptIndex,
        label: []const u8,
        slot: u32,
        source_file: []const u8,
        source_offset: usize,
        source_length: usize,
        domain_tag: []const u8,
        rank: u8,
        snippet_source: []const u8,
    ) !void {
        if (self.entries.items.len >= DEFAULT_MAX_ENTRIES) return error.ConceptIndexFull;

        const snippet = if (snippet_source.len > DEFAULT_SNIPPET_MAX_BYTES)
            try self.allocator.dupe(u8, snippet_source[0..DEFAULT_SNIPPET_MAX_BYTES])
        else
            try self.allocator.dupe(u8, snippet_source);
        errdefer self.allocator.free(snippet);

        const idx = self.entries.items.len;
        try self.entries.append(.{
            .label = try self.allocator.dupe(u8, label),
            .slot = slot,
            .source_file = try self.allocator.dupe(u8, source_file),
            .source_offset = source_offset,
            .source_length = source_length,
            .domain_tag = try self.allocator.dupe(u8, domain_tag),
            .rank = rank,
            .snippet = snippet,
            .content_hash = vsa.collapse(semantic_encoder.encodeConceptString(snippet_source)),
        });
        try self.slot_map.put(slot, idx);
    }

    /// Reverse lookup: given a lattice slot, find the concept entry.
    pub fn lookupBySlot(self: *const ConceptIndex, slot: u32) ?*const ConceptEntry {
        const idx = self.slot_map.get(slot) orelse return null;
        if (idx >= self.entries.items.len) return null;
        return &self.entries.items[idx];
    }

    /// Forward lookup: find an entry by label (linear scan).
    pub fn lookupByLabel(self: *const ConceptIndex, label: []const u8) ?*const ConceptEntry {
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.label, label)) return entry;
        }
        return null;
    }

    /// Get all entries for a specific domain.
    pub fn domainEntries(self: *const ConceptIndex, allocator: std.mem.Allocator, domain_tag: []const u8) ![]u32 {
        var result = std.ArrayList(u32).init(allocator);
        errdefer result.deinit();
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.domain_tag, domain_tag)) {
                try result.append(entry.slot);
            }
        }
        return result.toOwnedSlice();
    }

    /// Get all unique domain tags in the index.
    pub fn allDomains(self: *const ConceptIndex, allocator: std.mem.Allocator) ![][]u8 {
        var seen = std.StringHashMap(void).init(allocator);
        defer seen.deinit();
        var result = std.ArrayList([]u8).init(allocator);
        errdefer {
            for (result.items) |item| allocator.free(item);
            result.deinit();
        }
        for (self.entries.items) |entry| {
            if (entry.domain_tag.len == 0) continue;
            if (seen.contains(entry.domain_tag)) continue;
            try seen.put(entry.domain_tag, {});
            try result.append(try allocator.dupe(u8, entry.domain_tag));
        }
        return result.toOwnedSlice();
    }

    /// Update the cached rank for a slot (call after Forge promotions/demotions).
    pub fn updateRank(self: *ConceptIndex, slot: u32, new_rank: u8) void {
        if (self.slot_map.get(slot)) |idx| {
            if (idx < self.entries.items.len) {
                self.entries.items[idx].rank = new_rank;
            }
        }
    }

    /// Remove an entry by slot (called when the Reaper prunes a Noise rune).
    pub fn removeBySlot(self: *ConceptIndex, slot: u32) void {
        const idx = self.slot_map.get(slot) orelse return;
        if (idx >= self.entries.items.len) return;

        // Remove from slot_map
        _ = self.slot_map.remove(slot);

        // Deinit and swap-remove from entries
        self.entries.items[idx].deinit(self.allocator);
        _ = self.entries.swapRemove(idx);

        // Fix up the slot_map for the swapped entry
        if (idx < self.entries.items.len) {
            self.slot_map.put(self.entries.items[idx].slot, idx) catch {};
        }
    }

    /// Total number of entries.
    pub fn count(self: *const ConceptIndex) usize {
        return self.entries.items.len;
    }

    // ── Persistence (Binary) ──

    pub fn save(self: *const ConceptIndex, abs_path: []const u8) !void {
        var file = try std.fs.createFileAbsolute(abs_path, .{});
        defer file.close();
        const writer = file.writer();

        // 1. Header: Magic (4), Version (4), Count (4)
        try writer.writeAll(&BINARY_MAGIC);
        try writer.writeInt(u32, BINARY_VERSION, .little);
        try writer.writeInt(u32, @intCast(self.entries.items.len), .little);

        // 2. String blob compilation
        var string_blob = std.ArrayList(u8).init(self.allocator);
        defer string_blob.deinit();

        var fixed_entries = try self.allocator.alloc(DiskEntryFixed, self.entries.items.len);
        defer self.allocator.free(fixed_entries);

        for (self.entries.items, 0..) |entry, i| {
            var fixed = std.mem.zeroes(DiskEntryFixed);
            fixed.slot = entry.slot;
            fixed.rank = entry.rank;
            fixed.source_offset = @intCast(entry.source_offset);
            fixed.source_length = @intCast(entry.source_length);
            fixed.content_hash = entry.content_hash;

            fixed.label_offset = @intCast(string_blob.items.len);
            fixed.label_len = @intCast(entry.label.len);
            try string_blob.appendSlice(entry.label);

            fixed.source_file_offset = @intCast(string_blob.items.len);
            fixed.source_file_len = @intCast(entry.source_file.len);
            try string_blob.appendSlice(entry.source_file);

            fixed.domain_tag_offset = @intCast(string_blob.items.len);
            fixed.domain_tag_len = @intCast(entry.domain_tag.len);
            try string_blob.appendSlice(entry.domain_tag);

            fixed.snippet_offset = @intCast(string_blob.items.len);
            fixed.snippet_len = @intCast(entry.snippet.len);
            try string_blob.appendSlice(entry.snippet);

            fixed_entries[i] = fixed;
        }

        // 3. Write fixed entries
        try writer.writeAll(std.mem.sliceAsBytes(fixed_entries));

        // 4. Write string blob length & string blob
        try writer.writeInt(u32, @intCast(string_blob.items.len), .little);
        try writer.writeAll(string_blob.items);
    }

    pub fn load(allocator: std.mem.Allocator, abs_path: []const u8) !ConceptIndex {
        const file = try std.fs.openFileAbsolute(abs_path, .{});
        defer file.close();
        
        const stat = try file.stat();
        if (stat.size > 256 * 1024 * 1024) return error.ConceptIndexTooLarge;
        
        // Use mmap if possible, else read full file (for simplicity we read it)
        const bytes = try file.readToEndAlloc(allocator, @intCast(stat.size));
        defer allocator.free(bytes);

        var fbs = std.io.fixedBufferStream(bytes);
        const reader = fbs.reader();

        var magic: [4]u8 = undefined;
        _ = try reader.readAll(&magic);
        if (!std.mem.eql(u8, &magic, &BINARY_MAGIC)) return error.InvalidConceptIndexMagic;

        const version = try reader.readInt(u32, .little);
        if (version != BINARY_VERSION) return error.InvalidConceptIndexVersion;

        const entry_count = try reader.readInt(u32, .little);

        const fixed_bytes_len = entry_count * @sizeOf(DiskEntryFixed);
        const fixed_bytes = try allocator.alloc(u8, fixed_bytes_len);
        defer allocator.free(fixed_bytes);
        _ = try reader.readAll(fixed_bytes);
        const fixed_bytes_aligned = @as([]align(@alignOf(DiskEntryFixed)) u8, @alignCast(fixed_bytes));
        const fixed_entries = std.mem.bytesAsSlice(DiskEntryFixed, fixed_bytes_aligned);

        const blob_len = try reader.readInt(u32, .little);
        const blob_bytes = try allocator.alloc(u8, blob_len);
        defer allocator.free(blob_bytes);
        _ = try reader.readAll(blob_bytes);

        var index = ConceptIndex.init(allocator);
        errdefer index.deinit();

        for (fixed_entries) |fixed| {
            if (fixed.label_offset + fixed.label_len > blob_len) return error.CorruptStringBlob;
            const label = blob_bytes[fixed.label_offset .. fixed.label_offset + fixed.label_len];

            if (fixed.source_file_offset + fixed.source_file_len > blob_len) return error.CorruptStringBlob;
            const source_file = blob_bytes[fixed.source_file_offset .. fixed.source_file_offset + fixed.source_file_len];

            if (fixed.domain_tag_offset + fixed.domain_tag_len > blob_len) return error.CorruptStringBlob;
            const domain_tag = blob_bytes[fixed.domain_tag_offset .. fixed.domain_tag_offset + fixed.domain_tag_len];

            if (fixed.snippet_offset + fixed.snippet_len > blob_len) return error.CorruptStringBlob;
            const snippet = blob_bytes[fixed.snippet_offset .. fixed.snippet_offset + fixed.snippet_len];

            try index.addEntry(
                label,
                fixed.slot,
                source_file,
                @intCast(fixed.source_offset),
                @intCast(fixed.source_length),
                domain_tag,
                fixed.rank,
                snippet,
            );
            
            // Restore exact content hash
            const idx = index.entries.items.len - 1;
            index.entries.items[idx].content_hash = fixed.content_hash;
        }

        return index;
    }
};

// ══════════════════════════════════════════════════════════════════════════
//  TESTS
// ══════════════════════════════════════════════════════════════════════════

test "ConceptIndex add and lookup" {
    var index = ConceptIndex.init(std.testing.allocator);
    defer index.deinit();

    try index.addEntry(
        "Packet Loss Recovery",
        42,
        "rfc9000.txt",
        15230,
        512,
        "networking",
        1,
        "When a packet is deemed lost, the sender...",
    );

    try std.testing.expectEqual(@as(usize, 1), index.count());

    // Lookup by slot
    const by_slot = index.lookupBySlot(42);
    try std.testing.expect(by_slot != null);
    try std.testing.expectEqualStrings("Packet Loss Recovery", by_slot.?.label);
    try std.testing.expectEqual(@as(u8, 1), by_slot.?.rank);

    // Lookup by label
    const by_label = index.lookupByLabel("Packet Loss Recovery");
    try std.testing.expect(by_label != null);
    try std.testing.expectEqual(@as(u32, 42), by_label.?.slot);

    // Miss
    try std.testing.expectEqual(@as(?*const ConceptEntry, null), index.lookupBySlot(999));
    try std.testing.expectEqual(@as(?*const ConceptEntry, null), index.lookupByLabel("nonexistent"));
}

test "ConceptIndex domain filtering" {
    var index = ConceptIndex.init(std.testing.allocator);
    defer index.deinit();

    try index.addEntry("Concept A", 1, "a.txt", 0, 10, "biology", 2, "text a");
    try index.addEntry("Concept B", 2, "b.txt", 0, 10, "traffic", 2, "text b");
    try index.addEntry("Concept C", 3, "c.txt", 0, 10, "biology", 2, "text c");

    const bio_slots = try index.domainEntries(std.testing.allocator, "biology");
    defer std.testing.allocator.free(bio_slots);
    try std.testing.expectEqual(@as(usize, 2), bio_slots.len);

    const traffic_slots = try index.domainEntries(std.testing.allocator, "traffic");
    defer std.testing.allocator.free(traffic_slots);
    try std.testing.expectEqual(@as(usize, 1), traffic_slots.len);
}

test "ConceptIndex rank update and removal" {
    var index = ConceptIndex.init(std.testing.allocator);
    defer index.deinit();

    try index.addEntry("Concept A", 1, "a.txt", 0, 10, "test", 5, "text a");
    try index.addEntry("Concept B", 2, "b.txt", 0, 10, "test", 5, "text b");

    // Update rank
    index.updateRank(1, 1);
    try std.testing.expectEqual(@as(u8, 1), index.lookupBySlot(1).?.rank);

    // Remove
    index.removeBySlot(1);
    try std.testing.expectEqual(@as(usize, 1), index.count());
    try std.testing.expectEqual(@as(?*const ConceptEntry, null), index.lookupBySlot(1));
}

test "ConceptIndex save and load roundtrip" {
    const path = "/tmp/ghost_concept_index_test.bin";

    // Save
    {
        var index = ConceptIndex.init(std.testing.allocator);
        defer index.deinit();
        try index.addEntry("Concept A", 1, "a.txt", 0, 100, "biology", 1, "text about biology");
        try index.addEntry("Concept B", 2, "b.txt", 200, 300, "traffic", 2, "text about traffic");
        try index.save(path);
    }

    // Load
    {
        var loaded = try ConceptIndex.load(std.testing.allocator, path);
        defer loaded.deinit();
        try std.testing.expectEqual(@as(usize, 2), loaded.count());

        const a = loaded.lookupBySlot(1);
        try std.testing.expect(a != null);
        try std.testing.expectEqualStrings("Concept A", a.?.label);
        try std.testing.expectEqualStrings("biology", a.?.domain_tag);

        const b = loaded.lookupBySlot(2);
        try std.testing.expect(b != null);
        try std.testing.expectEqualStrings("b.txt", b.?.source_file);
    }

    // Cleanup
    std.fs.deleteFileAbsolute(path) catch {};
}
