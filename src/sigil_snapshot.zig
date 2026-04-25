const std = @import("std");
const config = @import("config.zig");
const engine = @import("engine.zig");
const ghost_state = @import("ghost_state.zig");
const abstractions = @import("abstractions.zig");
const corpus_ingest = @import("corpus_ingest.zig");
const patch_candidates = @import("patch_candidates.zig");
const shards = @import("shards.zig");
const scratchpad = @import("scratchpad.zig");
const sigil_runtime = @import("sigil_runtime.zig");
const sys = @import("sys.zig");

const CONTROL_MAGIC = "SGCTL01\n";
const CONTROL_VERSION: u32 = 1;

/// Snapshot/control ownership lives in this module. It owns the persisted
/// baseline scratch snapshot, the committed snapshot, the revert target, and
/// the command contract that decides when scratch data may be applied.
pub const Command = enum {
    none,
    begin_scratch,
    discard,
    commit,
    snapshot,
    revert,
    rollback,
};

pub const SnapshotStatus = struct {
    scratch_active: bool,
    committed_exists: bool,
    snapshot_exists: bool,
};

pub const LiveState = struct {
    allocator: std.mem.Allocator,
    paths: *const shards.Paths,
    engine: *engine.SingularityEngine,
    control: *sigil_runtime.ControlPlane,
    scratchpad: *scratchpad.ScratchpadLayer,
    meaning_file: *const sys.MappedFile,
    tags_file: *const sys.MappedFile,
    meaning_words: []u32,
    tags_words: []u64,
    lattice_words: ?[]u16 = null,
};

const Slot = enum {
    scratch,
    committed,
    snapshot,
};

const Reader = struct {
    data: []const u8,
    pos: usize = 0,

    fn readBytes(self: *Reader, len: usize) ![]const u8 {
        if (self.pos + len > self.data.len) return error.InvalidControlFile;
        const slice = self.data[self.pos .. self.pos + len];
        self.pos += len;
        return slice;
    }

    fn readInt(self: *Reader, comptime T: type) !T {
        const bytes = try self.readBytes(@sizeOf(T));
        return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
    }

    fn readBool(self: *Reader) !bool {
        return (try self.readInt(u8)) != 0;
    }
};

fn slotDir(paths: *const shards.Paths, slot: Slot) []const u8 {
    return switch (slot) {
        .scratch => paths.sigil_scratch_abs_path,
        .committed => paths.sigil_committed_abs_path,
        .snapshot => paths.sigil_snapshot_abs_path,
    };
}

fn slotFilePath(allocator: std.mem.Allocator, paths: *const shards.Paths, slot: Slot, file_name: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &[_][]const u8{ slotDir(paths, slot), file_name });
}

fn appendInt(list: *std.ArrayList(u8), comptime T: type, value: T) !void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    try list.appendSlice(&bytes);
}

fn serializeControlState(allocator: std.mem.Allocator, captured: *const sigil_runtime.CapturedControlState) ![]u8 {
    var bytes = std.ArrayList(u8).init(allocator);
    errdefer bytes.deinit();

    try bytes.appendSlice(CONTROL_MAGIC);
    try appendInt(&bytes, u32, CONTROL_VERSION);
    try appendInt(&bytes, u32, captured.snapshot.saturation_bonus);
    try appendInt(&bytes, u32, captured.snapshot.boredom_penalty_high);
    try appendInt(&bytes, u32, captured.snapshot.boredom_penalty_low);
    try appendInt(&bytes, u8, @intFromBool(captured.snapshot.enable_vulkan));
    try appendInt(&bytes, u8, @intFromBool(captured.snapshot.force_cpu_only));
    try appendInt(&bytes, u8, captured.snapshot.loom_tier);
    try appendInt(&bytes, u8, @intFromEnum(captured.snapshot.reasoning_mode));
    try appendInt(&bytes, u64, captured.snapshot.lattice_cache_cap_bytes);
    try appendInt(&bytes, u64, captured.snapshot.last_scan.hash);
    try appendInt(&bytes, u32, captured.snapshot.last_scan.energy);
    try appendInt(&bytes, u64, captured.snapshot.etch.total_etches);
    try appendInt(&bytes, u64, captured.snapshot.etch.total_drift);
    try appendInt(&bytes, u64, captured.snapshot.etch.last_hash);
    try appendInt(&bytes, u16, captured.snapshot.etch.last_energy);
    try appendInt(&bytes, u16, 0);
    try appendInt(&bytes, u32, captured.snapshot.etch.ema_average);
    try appendInt(&bytes, u32, captured.snapshot.etch.ema_deviation);
    try appendInt(&bytes, u64, @intCast(captured.snapshot.etch.slot_usage));
    try appendInt(&bytes, u8, @intFromBool(captured.snapshot.etch.slot_usage_initialized));
    try appendInt(&bytes, u8, 0);
    try appendInt(&bytes, u16, 0);
    try appendInt(&bytes, u32, @intCast(captured.locked_slots.len));
    try appendInt(&bytes, u32, @intCast(captured.locked_hashes.len));
    try appendInt(&bytes, u32, @intCast(captured.bindings.len));

    for (captured.locked_slots) |slot| {
        try appendInt(&bytes, u32, slot);
    }
    for (captured.locked_hashes) |hash| {
        try appendInt(&bytes, u64, hash);
    }
    for (captured.bindings) |binding| {
        try appendInt(&bytes, u32, @intCast(binding.label.len));
        try bytes.appendSlice(binding.label);
        try appendInt(&bytes, u32, binding.rune);
    }

    return bytes.toOwnedSlice();
}

fn parseControlState(allocator: std.mem.Allocator, data: []const u8) !sigil_runtime.CapturedControlState {
    var reader = Reader{ .data = data };
    const magic = try reader.readBytes(CONTROL_MAGIC.len);
    if (!std.mem.eql(u8, magic, CONTROL_MAGIC)) return error.InvalidControlFile;
    if (try reader.readInt(u32) != CONTROL_VERSION) return error.UnsupportedControlVersion;

    var captured = sigil_runtime.CapturedControlState{
        .allocator = allocator,
        .snapshot = .{
            .reasoning_mode = .proof,
            .saturation_bonus = try reader.readInt(u32),
            .boredom_penalty_high = try reader.readInt(u32),
            .boredom_penalty_low = try reader.readInt(u32),
            .enable_vulkan = try reader.readBool(),
            .force_cpu_only = try reader.readBool(),
            .loom_tier = try reader.readInt(u8),
            .lattice_cache_cap_bytes = 0,
            .last_scan = .{},
            .locked_slot_count = 0,
            .locked_hash_count = 0,
            .binding_count = 0,
            .etch = .{},
        },
        .locked_slots = &.{},
        .locked_hashes = &.{},
        .bindings = &.{},
    };
    errdefer captured.deinit();

    captured.snapshot.reasoning_mode = std.meta.intToEnum(sigil_runtime.ReasoningMode, try reader.readInt(u8)) catch .proof;
    captured.snapshot.lattice_cache_cap_bytes = try reader.readInt(u64);
    captured.snapshot.last_scan = .{
        .hash = try reader.readInt(u64),
        .energy = try reader.readInt(u32),
    };
    captured.snapshot.etch = .{
        .total_etches = try reader.readInt(u64),
        .total_drift = try reader.readInt(u64),
        .last_hash = try reader.readInt(u64),
        .last_energy = try reader.readInt(u16),
        .ema_average = 0,
        .ema_deviation = 0,
        .slot_usage = 0,
        .slot_usage_initialized = false,
    };
    _ = try reader.readInt(u16);
    captured.snapshot.etch.ema_average = try reader.readInt(u32);
    captured.snapshot.etch.ema_deviation = try reader.readInt(u32);
    captured.snapshot.etch.slot_usage = @intCast(try reader.readInt(u64));
    captured.snapshot.etch.slot_usage_initialized = try reader.readBool();
    _ = try reader.readInt(u8);
    _ = try reader.readInt(u16);

    const slot_count: usize = try reader.readInt(u32);
    const hash_count: usize = try reader.readInt(u32);
    const binding_count: usize = try reader.readInt(u32);

    captured.locked_slots = try allocator.alloc(u32, slot_count);
    captured.locked_hashes = try allocator.alloc(u64, hash_count);
    captured.bindings = try allocator.alloc(sigil_runtime.BindingSnapshot, binding_count);
    for (captured.bindings) |*binding| {
        binding.* = .{ .label = &.{}, .rune = 0 };
    }

    for (captured.locked_slots) |*slot| slot.* = try reader.readInt(u32);
    for (captured.locked_hashes) |*hash| hash.* = try reader.readInt(u64);
    for (captured.bindings) |*binding| {
        const label_len: usize = try reader.readInt(u32);
        const label = try reader.readBytes(label_len);
        binding.* = .{
            .label = try allocator.dupe(u8, label),
            .rune = try reader.readInt(u32),
        };
    }

    if (reader.pos != reader.data.len) return error.InvalidControlFile;

    captured.snapshot.locked_slot_count = captured.locked_slots.len;
    captured.snapshot.locked_hash_count = captured.locked_hashes.len;
    captured.snapshot.binding_count = captured.bindings.len;
    return captured;
}

fn fileExists(allocator: std.mem.Allocator, rel_path: []const u8) bool {
    const handle = sys.openForRead(allocator, rel_path) catch return false;
    sys.closeFile(handle);
    return true;
}

fn ensureSlotDirForState(state: LiveState, slot: Slot) !void {
    try sys.makePath(state.allocator, slotDir(state.paths, slot));
}

fn readExactFile(allocator: std.mem.Allocator, rel_path: []const u8, dest: []u8) !void {
    const handle = try sys.openForRead(allocator, rel_path);
    defer sys.closeFile(handle);

    const size = try sys.getFileSize(handle);
    if (size != dest.len) return error.UnexpectedFileSize;
    const read = try sys.readAll(handle, dest);
    if (read != dest.len) return error.ShortRead;
}

fn copyBytesToFile(allocator: std.mem.Allocator, rel_path: []const u8, src: []const u8) !void {
    const handle = try sys.openForWrite(allocator, rel_path);
    defer sys.closeFile(handle);
    try sys.writeAll(handle, src);
}

fn latticeBlockWordRange(block_idx: usize) struct { start: usize, end: usize } {
    const start_byte = block_idx * config.CHECKSUM_BLOCK_SIZE;
    const end_byte = if (block_idx + 1 == ghost_state.UnifiedLattice.BLOCK_COUNT)
        ghost_state.UnifiedLattice.HASH_OFFSET
    else
        start_byte + config.CHECKSUM_BLOCK_SIZE;
    return .{
        .start = start_byte / @sizeOf(u16),
        .end = end_byte / @sizeOf(u16),
    };
}

fn syncLiveLatticeWords(dest: []u16, start: usize, src: []const u16) void {
    const window = dest[start .. start + src.len];
    if (@intFromPtr(window.ptr) == @intFromPtr(src.ptr)) return;
    @memcpy(window, src);
}

fn syncGpuToHostIfNeeded(state: LiveState) !void {
    if (state.engine.vulkan) |vk| {
        const host_lattice = state.lattice_words orelse return error.HostLatticeUnavailable;
        try vk.syncDeviceToHost(state.meaning_words, state.tags_words, host_lattice);
    }
}

fn writeLiveLatticeSnapshot(state: LiveState, allocator: std.mem.Allocator, rel_path: []const u8) !void {
    const handle = try sys.openForWrite(allocator, rel_path);
    defer sys.closeFile(handle);

    var hashes: [ghost_state.UnifiedLattice.BLOCK_COUNT]u64 = undefined;
    if (state.lattice_words) |words| {
        for (0..ghost_state.UnifiedLattice.BLOCK_COUNT) |block_idx| {
            const range = latticeBlockWordRange(block_idx);
            const bytes = std.mem.sliceAsBytes(words[range.start..range.end]);
            hashes[block_idx] = ghost_state.wyhash(ghost_state.GENESIS_SEED, std.hash.Fnv1a_64.hash(bytes));
            try sys.writeAll(handle, bytes);
        }
    } else {
        const provider = state.engine.lattice_provider orelse return error.LatticeUnavailable;
        for (0..ghost_state.UnifiedLattice.BLOCK_COUNT) |block_idx| {
            const range = latticeBlockWordRange(block_idx);
            var lease = try provider.acquireWords(range.start, range.end - range.start, false);
            defer lease.release();
            const bytes = std.mem.sliceAsBytes(lease.words());
            hashes[block_idx] = ghost_state.wyhash(ghost_state.GENESIS_SEED, std.hash.Fnv1a_64.hash(bytes));
            try sys.writeAll(handle, bytes);
        }
    }

    var reserved = [_]u8{0} ** config.CHECKSUM_RESERVED_BYTES;
    for (hashes, 0..) |hash, index| {
        const start = index * @sizeOf(u64);
        var hash_bytes: [@sizeOf(u64)]u8 = undefined;
        std.mem.writeInt(u64, &hash_bytes, hash, .little);
        @memcpy(reserved[start .. start + @sizeOf(u64)], &hash_bytes);
    }
    try sys.writeAll(handle, &reserved);
}

fn writeSlot(state: LiveState, slot: Slot) !void {
    try ensureSlotDirForState(state, slot);
    try syncGpuToHostIfNeeded(state);

    const lattice_path = try slotFilePath(state.allocator, state.paths, slot, config.LATTICE_FILE_NAME);
    defer state.allocator.free(lattice_path);
    try writeLiveLatticeSnapshot(state, state.allocator, lattice_path);

    const meaning_path = try slotFilePath(state.allocator, state.paths, slot, config.SEMANTIC_FILE_NAME);
    defer state.allocator.free(meaning_path);
    try copyBytesToFile(state.allocator, meaning_path, std.mem.sliceAsBytes(state.meaning_words));

    const tags_path = try slotFilePath(state.allocator, state.paths, slot, config.TAG_FILE_NAME);
    defer state.allocator.free(tags_path);
    try copyBytesToFile(state.allocator, tags_path, std.mem.sliceAsBytes(state.tags_words));

    var captured = try state.control.captureState(state.allocator);
    defer captured.deinit();
    const control_bytes = try serializeControlState(state.allocator, &captured);
    defer state.allocator.free(control_bytes);

    const control_path = try slotFilePath(state.allocator, state.paths, slot, config.SIGIL_CONTROL_FILE_NAME);
    defer state.allocator.free(control_path);
    try copyBytesToFile(state.allocator, control_path, control_bytes);

    try abstractions.writeLiveToSlot(state.allocator, state.paths, slotDir(state.paths, slot));
    try corpus_ingest.writeLiveToSlot(state.allocator, state.paths, slotDir(state.paths, slot));
}

fn readControlSlot(allocator: std.mem.Allocator, paths: *const shards.Paths, slot: Slot) !sigil_runtime.CapturedControlState {
    const path = try slotFilePath(allocator, paths, slot, config.SIGIL_CONTROL_FILE_NAME);
    defer allocator.free(path);

    const handle = try sys.openForRead(allocator, path);
    defer sys.closeFile(handle);
    const size = try sys.getFileSize(handle);
    const bytes = try allocator.alloc(u8, size);
    defer allocator.free(bytes);
    const read = try sys.readAll(handle, bytes);
    if (read != bytes.len) return error.ShortRead;
    return parseControlState(allocator, bytes);
}

fn restoreSlot(state: LiveState, slot: Slot) !void {
    if (!slotExists(state.allocator, state.paths, slot)) return switch (slot) {
        .scratch => error.ScratchMissing,
        .snapshot => error.SnapshotMissing,
        .committed => error.CommitMissing,
    };

    const lattice_path = try slotFilePath(state.allocator, state.paths, slot, config.LATTICE_FILE_NAME);
    defer state.allocator.free(lattice_path);
    const provider = state.engine.lattice_provider orelse return error.LatticeUnavailable;

    const lattice_handle = try sys.openForRead(state.allocator, lattice_path);
    defer sys.closeFile(lattice_handle);
    const lattice_size = try sys.getFileSize(lattice_handle);
    if (lattice_size != config.UNIFIED_SIZE_BYTES) return error.UnexpectedFileSize;

    for (0..ghost_state.UnifiedLattice.BLOCK_COUNT) |block_idx| {
        const range = latticeBlockWordRange(block_idx);
        var lease = try provider.acquireWords(range.start, range.end - range.start, true);
        defer lease.release();
        const bytes = std.mem.sliceAsBytes(lease.words());
        const read = try sys.readAll(lattice_handle, bytes);
        if (read != bytes.len) return error.ShortRead;
        if (state.lattice_words) |live_words| {
            syncLiveLatticeWords(live_words, range.start, lease.words());
        }
    }

    const tail_start = ghost_state.UnifiedLattice.HASH_OFFSET / @sizeOf(u16);
    const tail_count = config.CHECKSUM_RESERVED_BYTES / @sizeOf(u16);
    var tail_lease = try provider.acquireWords(tail_start, tail_count, true);
    defer tail_lease.release();
    const tail_bytes = std.mem.sliceAsBytes(tail_lease.words());
    const tail_read = try sys.readAll(lattice_handle, tail_bytes);
    if (tail_read != tail_bytes.len) return error.ShortRead;
    if (state.lattice_words) |live_words| {
        syncLiveLatticeWords(live_words, tail_start, tail_lease.words());
    }
    try provider.flush();

    const meaning_path = try slotFilePath(state.allocator, state.paths, slot, config.SEMANTIC_FILE_NAME);
    defer state.allocator.free(meaning_path);
    try readExactFile(state.allocator, meaning_path, std.mem.sliceAsBytes(state.meaning_words));
    try sys.flushMappedMemory(state.meaning_file);

    const tags_path = try slotFilePath(state.allocator, state.paths, slot, config.TAG_FILE_NAME);
    defer state.allocator.free(tags_path);
    try readExactFile(state.allocator, tags_path, std.mem.sliceAsBytes(state.tags_words));
    try sys.flushMappedMemory(state.tags_file);

    var captured = try readControlSlot(state.allocator, state.paths, slot);
    defer captured.deinit();
    try state.control.restoreState(&captured);

    try abstractions.restoreLiveFromSlot(state.allocator, state.paths, slotDir(state.paths, slot));
    try corpus_ingest.restoreLiveFromSlot(state.allocator, state.paths, slotDir(state.paths, slot));

    if (state.engine.vulkan) |vk| {
        const host_lattice = state.lattice_words orelse return error.HostLatticeUnavailable;
        vk.bindHostState(state.meaning_words, state.tags_words, host_lattice);
    }
}

fn slotExists(allocator: std.mem.Allocator, paths: *const shards.Paths, slot: Slot) bool {
    const path = slotFilePath(allocator, paths, slot, config.SIGIL_CONTROL_FILE_NAME) catch return false;
    defer allocator.free(path);
    return fileExists(allocator, path);
}

pub fn status(layer: *const scratchpad.ScratchpadLayer, allocator: std.mem.Allocator, paths: *const shards.Paths) SnapshotStatus {
    return .{
        .scratch_active = layer.isSessionActive(),
        .committed_exists = slotExists(allocator, paths, .committed),
        .snapshot_exists = slotExists(allocator, paths, .snapshot),
    };
}

pub fn parseCommand(script: []const u8) Command {
    const trimmed = std.mem.trim(u8, script, " \r\n\t");
    if (std.ascii.eqlIgnoreCase(trimmed, "begin scratch")) return .begin_scratch;
    if (std.ascii.eqlIgnoreCase(trimmed, "discard")) return .discard;
    if (std.ascii.eqlIgnoreCase(trimmed, "commit")) return .commit;
    if (std.ascii.eqlIgnoreCase(trimmed, "snapshot")) return .snapshot;
    if (std.ascii.eqlIgnoreCase(trimmed, "revert")) return .revert;
    if (std.ascii.eqlIgnoreCase(trimmed, "rollback")) return .rollback;
    return .none;
}

pub fn commandName(command: Command) []const u8 {
    return switch (command) {
        .none => "sigil",
        .begin_scratch => "begin scratch",
        .discard => "discard",
        .commit => "commit",
        .snapshot => "snapshot",
        .revert => "revert",
        .rollback => "rollback",
    };
}

/// `begin scratch` captures a baseline snapshot so discard can restore control
/// and permanent state. `commit` means "apply current scratch overlay into the
/// permanent mappings, then persist that live state as the committed snapshot".
/// `discard` means "drop scratch data and restore the baseline snapshot". The
/// scratch session flag only controls baseline/discard legality and whether
/// snapshot/revert are blocked; it does not own the overlay's staged bytes.
pub fn executeCommand(state: LiveState, command: Command) !SnapshotStatus {
    switch (command) {
        .none => return status(state.scratchpad, state.allocator, state.paths),
        .begin_scratch => {
            if (state.scratchpad.isSessionActive()) return error.ScratchAlreadyActive;
            state.scratchpad.beginSession();
            errdefer {
                state.scratchpad.endSession();
                state.scratchpad.clear();
            }
            try abstractions.clearStaged(state.allocator, state.paths);
            try corpus_ingest.clearStaged(state.allocator, state.paths);
            try patch_candidates.clearStaged(state.allocator, state.paths);
            try writeSlot(state, .scratch);
        },
        .discard => {
            if (!state.scratchpad.isSessionActive()) return error.ScratchNotActive;
            state.scratchpad.clear();
            try restoreSlot(state, .scratch);
            try abstractions.clearStaged(state.allocator, state.paths);
            try corpus_ingest.clearStaged(state.allocator, state.paths);
            try patch_candidates.clearStaged(state.allocator, state.paths);
            state.scratchpad.endSession();
            state.scratchpad.clear();
        },
        .commit => {
            errdefer state.scratchpad.endSession();
            if (state.scratchpad.hasChanges()) {
                try state.scratchpad.applyToPermanent();
                try sys.flushMappedMemory(state.meaning_file);
                try sys.flushMappedMemory(state.tags_file);
            }
            try abstractions.applyStaged(state.allocator, state.paths);
            try corpus_ingest.applyStaged(state.allocator, state.paths);
            try patch_candidates.clearStaged(state.allocator, state.paths);
            try writeSlot(state, .committed);
            state.scratchpad.endSession();
        },
        .snapshot => {
            if (state.scratchpad.isSessionActive()) return error.ScratchSessionActive;
            try writeSlot(state, .snapshot);
        },
        .revert, .rollback => {
            if (state.scratchpad.isSessionActive()) return error.ScratchSessionActive;
            try restoreSlot(state, .snapshot);
            try abstractions.clearStaged(state.allocator, state.paths);
            try corpus_ingest.clearStaged(state.allocator, state.paths);
            try patch_candidates.clearStaged(state.allocator, state.paths);
            state.scratchpad.clear();
        },
    }
    return status(state.scratchpad, state.allocator, state.paths);
}
