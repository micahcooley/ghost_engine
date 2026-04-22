const std = @import("std");
const sys = @import("sys.zig");
const vsa = @import("vsa_core.zig");
const config = @import("config.zig");

pub const SLOT_WORDS: usize = 1024;
pub const SLOT_DATA_BYTES: usize = SLOT_WORDS * @sizeOf(u32);
pub const SLOT_TAG_BYTES: usize = @sizeOf(u64);
pub const SLOT_BYTES: usize = SLOT_DATA_BYTES + SLOT_TAG_BYTES;
pub const MIN_CAPACITY_BYTES: usize = SLOT_BYTES;

pub const Config = struct {
    requested_bytes: usize = config.DEFAULT_SCRATCHPAD_BYTES,
    file_prefix: []const u8 = "ghost-scratchpad",
    owner_id: []const u8 = "core",
};

/// Scratch overlay reads fall back to the permanent matrix, but every write is
/// staged into the scratch backing only until the control layer explicitly
/// applies the overlay into permanent state.
pub const OverlayMeaningMatrix = struct {
    permanent: *const vsa.MeaningMatrix,
    scratch: vsa.MeaningMatrix,

    pub fn collapseToBinary(self: *const OverlayMeaningMatrix, hash: u64) vsa.HyperVector {
        if (self.findScratchSlot(hash) != null) {
            return self.scratch.collapseToBinary(hash);
        }
        return self.permanent.collapseToBinary(hash);
    }

    pub fn applyGravity(
        self: *OverlayMeaningMatrix,
        word_hash: u64,
        sentence_pool: vsa.HyperVector,
        hash_locked: bool,
        slot_lock_mask: u32,
    ) vsa.GravityResult {
        return self.scratch.applyGravity(word_hash, sentence_pool, hash_locked, slot_lock_mask);
    }

    pub fn hardLockUniversalSigil(self: *OverlayMeaningMatrix, hash: u64, rune: u32) void {
        self.scratch.hardLockUniversalSigil(hash, rune);
    }

    pub fn slotUsageHint(self: *const OverlayMeaningMatrix) ?usize {
        const tags = self.scratch.tags orelse return null;
        var used: usize = 0;
        for (tags) |tag| {
            if (tag != 0) used += 1;
        }
        return used;
    }

    fn findScratchSlot(self: *const OverlayMeaningMatrix, hash: u64) ?u32 {
        const tags = self.scratch.tags orelse return null;
        const num_slots = @as(u32, @intCast(tags.len));
        if (num_slots == 0) return null;

        const addr = vsa.computeSudhAddress(@as(u32, @truncate(hash)), hash, num_slots);
        var probe: u32 = 0;
        while (probe < vsa.SUDH_CPU_PROBES) : (probe += 1) {
            const slot = addr.probe(probe, num_slots);
            if (slot >= num_slots) break;
            if (tags[slot] == hash) return slot;
            if (tags[slot] == 0) return null;
        }
        return null;
    }
};

/// The scratchpad owns the temporary Linux-backed mapping and the in-memory
/// session flag. The flag means "a discardable baseline exists", not "writes are
/// enabled": the overlay may still accumulate staged changes outside a session,
/// but only the control layer decides when they are applied or discarded.
pub const ScratchpadLayer = struct {
    backing: sys.MappedFile,
    overlay: OverlayMeaningMatrix,
    owner_id: []const u8,
    slot_count: usize,
    capacity_bytes: usize,
    session_active: bool,

    pub fn init(allocator: std.mem.Allocator, cfg: Config, permanent: *const vsa.MeaningMatrix) !ScratchpadLayer {
        const capacity_bytes = normalizeCapacity(cfg.requested_bytes);
        const slot_count = capacity_bytes / SLOT_BYTES;
        const backing = try sys.createTemporaryMappedFile(allocator, cfg.file_prefix, capacity_bytes);
        errdefer {
            var temp = backing;
            temp.unmap();
        }

        const data_len = slot_count * SLOT_WORDS;
        const tags_offset = data_len * @sizeOf(u32);
        const scratch_data = @as([*]u32, @ptrCast(@alignCast(backing.data.ptr)))[0..data_len];
        const scratch_tags = @as([*]u64, @ptrCast(@alignCast(backing.data.ptr + tags_offset)))[0..slot_count];

        var layer = ScratchpadLayer{
            .backing = backing,
            .overlay = .{
                .permanent = permanent,
                .scratch = .{
                    .data = scratch_data,
                    .tags = scratch_tags,
                },
            },
            .owner_id = cfg.owner_id,
            .slot_count = slot_count,
            .capacity_bytes = capacity_bytes,
            .session_active = false,
        };
        layer.clear();
        return layer;
    }

    pub fn beginSession(self: *ScratchpadLayer) void {
        self.clear();
        self.session_active = true;
    }

    pub fn endSession(self: *ScratchpadLayer) void {
        self.session_active = false;
    }

    pub fn isSessionActive(self: *const ScratchpadLayer) bool {
        return self.session_active;
    }

    pub fn ownerId(self: *const ScratchpadLayer) []const u8 {
        return self.owner_id;
    }

    pub fn clear(self: *ScratchpadLayer) void {
        @memset(self.backing.data, 0);
    }

    pub fn hasChanges(self: *const ScratchpadLayer) bool {
        const tags = self.overlay.scratch.tags orelse return false;
        for (tags) |tag| {
            if (tag != 0) return true;
        }
        return false;
    }

    /// Applies the current scratch overlay into the permanent matrix and then
    /// clears the scratch backing. This is a data-plane primitive, not a
    /// commit-policy decision.
    pub fn applyToPermanent(self: *ScratchpadLayer) !void {
        const scratch_tags = self.overlay.scratch.tags orelse return;
        const permanent_tags = self.overlay.permanent.tags orelse return;
        const permanent_slots = @as(u32, @intCast(permanent_tags.len));

        for (scratch_tags, 0..) |hash, scratch_slot| {
            if (hash == 0) continue;

            const addr = vsa.computeSudhAddress(@as(u32, @truncate(hash)), hash, permanent_slots);
            var destination: ?u32 = null;
            var probe: u32 = 0;
            while (probe < vsa.SUDH_CPU_PROBES) : (probe += 1) {
                const slot = addr.probe(probe, permanent_slots);
                if (slot >= permanent_slots) break;
                if (permanent_tags[slot] == hash or permanent_tags[slot] == 0) {
                    destination = slot;
                    break;
                }
            }

            const slot = destination orelse return error.ScratchCommitCollision;
            permanent_tags[slot] = hash;
            const src_start = scratch_slot * SLOT_WORDS;
            const dst_start = @as(usize, slot) * SLOT_WORDS;
            @memcpy(
                self.overlay.permanent.data[dst_start .. dst_start + SLOT_WORDS],
                self.overlay.scratch.data[src_start .. src_start + SLOT_WORDS],
            );
        }

        self.clear();
    }

    pub fn deinit(self: *ScratchpadLayer) void {
        self.backing.unmap();
        self.* = undefined;
    }

    pub fn meaning(self: *ScratchpadLayer) *OverlayMeaningMatrix {
        return &self.overlay;
    }

    pub fn normalizeCapacity(requested_bytes: usize) usize {
        const effective = @max(requested_bytes, MIN_CAPACITY_BYTES);
        const slot_count = std.math.divCeil(usize, effective, SLOT_BYTES) catch unreachable;
        return slot_count * SLOT_BYTES;
    }
};
