const std = @import("std");
const builtin = @import("builtin");
const core = @import("ghost_core");
const sys = core.sys;
const ghost_state = core.ghost_state;
const vsa = core.vsa;
const vsa_vulkan = core.vsa_vulkan;
const config = core.config;

const STREAM_BUFFER_CAPACITY = 64 * 1024;

pub const CorpusWeight = struct {
    name: []const u8,
    weight: u32,
};

pub const TrainerOptions = struct {
    tier: u32 = @intFromEnum(vsa_vulkan.OperationalTier.standard),
    batch_size_override: u32 = 0,
    max_active_streams: u32 = 0,
    checkpoint_interval_ms: u32 = 60_000,
    stop_after_minutes: u32 = 0,
    stop_after_runes: u64 = 0,
    stop_after_slot_usage_bp: u32 = 0,
    idle_sleep_ms: u32 = 10,
    selected_gpu_ids: []const u32 = &.{},
};

pub const StopReason = enum(u32) {
    none = 0,
    completed = 1,
    manual = 2,
    max_time = 3,
    max_runes = 4,
    slot_usage = 5,
    failed = 6,
};

pub const StreamState = struct {
    const Source = enum {
        memory,
        file,
    };

    lexical_rotor: u64,
    semantic_rotor: u64,
    source: Source,
    file_data: []const u8,
    cursor: std.atomic.Value(usize),
    name: []const u8,
    weight: u32,
    done: std.atomic.Value(bool),
    total_bytes: usize,
    file: sys.FileHandle,
    buffer: [STREAM_BUFFER_CAPACITY + 4]u8,
    buffer_start: usize,
    buffer_end: usize,
    eof: bool,
    mutex: core.sync.Mutex = .{},

    // V32: HyperRotor — 1024-bit HRR context accumulator.
    // Evolves per-rune via Permute→Bind→Bundle to track the "context smell".
    // Used exclusively on the CPU side for future SUDH addressing.
    // Memory cost: 128 bytes per active stream (16 × u64).
    context_rotor: vsa.HyperRotor,

    pub fn init(data: []const u8, name: []const u8, weight: u32) StreamState {
        return .{
            .lexical_rotor = ghost_state.FNV_OFFSET_BASIS,
            .semantic_rotor = ghost_state.FNV_OFFSET_BASIS,
            .source = .memory,
            .file_data = data,
            .cursor = std.atomic.Value(usize).init(0),
            .name = name,
            .weight = @max(weight, 1),
            .done = std.atomic.Value(bool).init(false),
            .total_bytes = data.len,
            .file = sys.INVALID_HANDLE,
            .buffer = undefined,
            .buffer_start = 0,
            .buffer_end = 0,
            .eof = true,
            .context_rotor = vsa.HyperRotor.init(ghost_state.wyhash(
                ghost_state.GENESIS_SEED,
                ghost_state.FNV_OFFSET_BASIS,
            )),
        };
    }

    pub fn initFile(allocator: std.mem.Allocator, path: []const u8, name: []const u8, weight: u32) !StreamState {
        const file = try sys.openForRead(allocator, path);
        errdefer sys.closeFile(file);
        return .{
            .lexical_rotor = ghost_state.FNV_OFFSET_BASIS,
            .semantic_rotor = ghost_state.FNV_OFFSET_BASIS,
            .source = .file,
            .file_data = &.{},
            .cursor = std.atomic.Value(usize).init(0),
            .name = name,
            .weight = @max(weight, 1),
            .done = std.atomic.Value(bool).init(false),
            .total_bytes = sys.getFileSize(file) catch 0,
            .file = file,
            .buffer = undefined,
            .buffer_start = 0,
            .buffer_end = 0,
            .eof = false,
            .context_rotor = vsa.HyperRotor.init(ghost_state.wyhash(
                ghost_state.GENESIS_SEED,
                ghost_state.FNV_OFFSET_BASIS,
            )),
        };
    }

    pub fn deinit(self: *StreamState) void {
        if (self.source == .file and self.file != sys.INVALID_HANDLE) {
            sys.closeFile(self.file);
            self.file = sys.INVALID_HANDLE;
        }
    }

    pub fn totalSizeBytes(self: *const StreamState) usize {
        return switch (self.source) {
            .memory => self.file_data.len,
            .file => self.total_bytes,
        };
    }

    fn refillBuffer(self: *StreamState) !bool {
        const carry = self.buffer_end - self.buffer_start;
        if (carry > 0) {
            std.mem.copyForwards(u8, self.buffer[0..carry], self.buffer[self.buffer_start..self.buffer_end]);
        }
        const bytes_read = try sys.readAll(self.file, self.buffer[carry..STREAM_BUFFER_CAPACITY]);
        self.buffer_start = 0;
        self.buffer_end = carry + bytes_read;
        if (bytes_read == 0) self.eof = true;
        return self.buffer_end > 0;
    }

    fn nextRuneFromMemory(self: *StreamState) ?u32 {
        const cursor = self.cursor.load(.monotonic);
        if (cursor >= self.file_data.len) {
            self.done.store(true, .monotonic);
            return null;
        }

        const first_byte = self.file_data[cursor];
        const cp_len = std.unicode.utf8ByteSequenceLength(first_byte) catch {
            self.cursor.store(cursor + 1, .monotonic);
            if (cursor + 1 >= self.file_data.len) self.done.store(true, .monotonic);
            return 0xFFFD;
        };

        if (cursor + cp_len > self.file_data.len) {
            self.cursor.store(self.file_data.len, .monotonic);
            self.done.store(true, .monotonic);
            return null;
        }

        const rune_slice = self.file_data[cursor .. cursor + cp_len];
        var view = std.unicode.Utf8View.init(rune_slice) catch {
            self.cursor.store(cursor + 1, .monotonic);
            if (cursor + 1 >= self.file_data.len) self.done.store(true, .monotonic);
            return 0xFFFD;
        };
        var iter = view.iterator();
        const rune = iter.nextCodepoint() orelse 0xFFFD;

        const next_cursor = cursor + cp_len;
        self.cursor.store(next_cursor, .monotonic);
        if (next_cursor >= self.file_data.len) self.done.store(true, .monotonic);
        return rune;
    }

    fn nextRuneFromFile(self: *StreamState) !?u32 {
        while (true) {
            if (self.buffer_start >= self.buffer_end) {
                if (!(try self.refillBuffer())) {
                    self.done.store(true, .monotonic);
                    return null;
                }
            }

            const available = self.buffer_end - self.buffer_start;
            const first_byte = self.buffer[self.buffer_start];
            const cp_len = std.unicode.utf8ByteSequenceLength(first_byte) catch {
                self.buffer_start += 1;
                _ = self.cursor.fetchAdd(1, .monotonic);
                if (self.eof and self.buffer_start >= self.buffer_end) self.done.store(true, .monotonic);
                return 0xFFFD;
            };

            if (cp_len > available) {
                if (self.eof) {
                    _ = self.cursor.fetchAdd(available, .monotonic);
                    self.buffer_start = self.buffer_end;
                    self.done.store(true, .monotonic);
                    return null;
                }
                _ = try self.refillBuffer();
                continue;
            }

            const rune_slice = self.buffer[self.buffer_start .. self.buffer_start + cp_len];
            var view = std.unicode.Utf8View.init(rune_slice) catch {
                self.buffer_start += 1;
                _ = self.cursor.fetchAdd(1, .monotonic);
                if (self.eof and self.buffer_start >= self.buffer_end) self.done.store(true, .monotonic);
                return 0xFFFD;
            };
            var iter = view.iterator();
            const rune = iter.nextCodepoint() orelse 0xFFFD;

            self.buffer_start += cp_len;
            _ = self.cursor.fetchAdd(cp_len, .monotonic);
            if (self.eof and self.buffer_start >= self.buffer_end) self.done.store(true, .monotonic);
            return rune;
        }
    }

    fn nextRune(self: *StreamState) !?u32 {
        return switch (self.source) {
            .memory => self.nextRuneFromMemory(),
            .file => try self.nextRuneFromFile(),
        };
    }
};

pub const GreedyBatcher = struct {
    streams: []StreamState,
    allocator: std.mem.Allocator,
    current_stream_idx: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    total_processed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    max_active_streams: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    last_requested_batch: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    last_packed_batch: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    last_active_streams: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    pub fn init(allocator: std.mem.Allocator, streams: []StreamState) !GreedyBatcher {
        return .{
            .streams = streams,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *GreedyBatcher) void {
        for (self.streams) |*stream| stream.deinit();
    }

    fn packRune(stream: *StreamState, stream_idx: usize, total_packed: *u32, out_chars: []u32, out_rotors: []u64, out_indices: []u32) bool {
        stream.mutex.lock();
        defer stream.mutex.unlock();

        const rune = stream.nextRune() catch {
            stream.done.store(true, .monotonic);
            return false;
        } orelse return false;
        out_chars[total_packed.*] = rune;
        out_indices[total_packed.*] = @intCast(stream_idx);

        const boundary = vsa.detectSyntacticBoundary(rune);
        stream.lexical_rotor ^= rune;
        stream.lexical_rotor = std.math.rotl(u64, stream.lexical_rotor, 13) *% ghost_state.FNV_PRIME;

        if (boundary != .none) {
            stream.semantic_rotor ^= stream.lexical_rotor;
            stream.semantic_rotor = std.math.rotl(u64, stream.semantic_rotor, 13) *% ghost_state.FNV_PRIME;
        }

        stream.context_rotor.evolve(rune);

        const base = total_packed.* * 18;
        inline for (0..16) |j| {
            out_rotors[base + j] = stream.context_rotor.state[j];
        }
        out_rotors[base + 16] = stream.lexical_rotor;
        out_rotors[base + 17] = stream.semantic_rotor;

        total_packed.* += 1;
        return true;
    }

    /// Pulls up to 'max_runes' from available streams.
    /// Returns the number of runes actually packed.
    pub fn pack(self: *GreedyBatcher, max_runes: u32, out_chars: []u32, out_rotors: []u64, out_indices: []u32, num_streams_out: *u32) u32 {
        var total_packed: u32 = 0;
        self.last_requested_batch.store(max_runes, .monotonic);

        const stream_count: u32 = @intCast(self.streams.len);
        if (stream_count == 0 or max_runes == 0) {
            self.last_packed_batch.store(0, .monotonic);
            self.last_active_streams.store(0, .monotonic);
            num_streams_out.* = 0;
            return 0;
        }

        const configured_limit = self.max_active_streams.load(.acquire);
        const active_limit: u32 = if (configured_limit == 0) stream_count else @min(configured_limit, stream_count);
        const start_idx = self.current_stream_idx.fetchAdd(1, .monotonic);
        var considered_active: u32 = 0;

        while (total_packed < max_runes) {
            var any_packed_this_pass = false;
            considered_active = 0;

            for (0..self.streams.len) |i| {
                if (total_packed >= max_runes or considered_active >= active_limit) break;

                const idx = (start_idx + i) % self.streams.len;
                const stream = &self.streams[idx];
                if (stream.done.load(.monotonic)) continue;
                considered_active += 1;

                const repeats = @max(stream.weight, 1);
                for (0..repeats) |_| {
                    if (total_packed >= max_runes) break;
                    if (packRune(stream, idx, &total_packed, out_chars, out_rotors, out_indices)) {
                        any_packed_this_pass = true;
                    } else {
                        break;
                    }
                }
            }

            if (!any_packed_this_pass) break;
        }

        num_streams_out.* = considered_active;
        self.last_packed_batch.store(total_packed, .monotonic);
        self.last_active_streams.store(considered_active, .monotonic);
        _ = self.total_processed.fetchAdd(total_packed, .monotonic);
        return total_packed;
    }
};

pub const GpuRuntimeStats = struct {
    device_index: u32 = 0,
    target_batch_size: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    last_batch_size: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    processed_runes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    dispatched_batches: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    idle_loops: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    busy_time_ms: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    last_dispatch_ms: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
};

pub const OhlTrainer = struct {
    allocator: std.mem.Allocator,
    fleet: *vsa_vulkan.MultiGPU,
    batcher: *GreedyBatcher,
    engines: []*vsa_vulkan.VulkanEngine,
    gpu_stats: []GpuRuntimeStats,
    is_running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    is_paused: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    checkpoint_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    checkpoint_in_progress: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    threads: []std.Thread,
    start_time: i64 = 0,
    last_checkpoint_ms: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    current_tier: std.atomic.Value(u32) = std.atomic.Value(u32).init(@intFromEnum(vsa_vulkan.OperationalTier.standard)),
    batch_size_override: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    checkpoint_interval_ms: std.atomic.Value(u32) = std.atomic.Value(u32).init(60_000),
    stop_after_minutes: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    stop_after_runes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    stop_after_slot_usage_bp: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    idle_sleep_ms: std.atomic.Value(u32) = std.atomic.Value(u32).init(10),
    stop_reason: std.atomic.Value(u32) = std.atomic.Value(u32).init(@intFromEnum(StopReason.none)),

    // Global mapped files for checkpointing (synced from main.zig or newly mapped)
    mapped_lattice: ?[]u16 = null,
    mapped_meaning: ?[]u32 = null,
    mapped_tags: ?[]u64 = null,
    lattice_file: ?*const sys.MappedFile = null,
    meaning_file: ?*const sys.MappedFile = null,
    tags_file: ?*const sys.MappedFile = null,

    pub fn init(allocator: std.mem.Allocator, fleet: *vsa_vulkan.MultiGPU, batcher: *GreedyBatcher, options: TrainerOptions) !OhlTrainer {
        var selected_count: usize = 0;
        if (options.selected_gpu_ids.len == 0) {
            selected_count = fleet.engines.len;
        } else {
            for (fleet.engines) |engine| {
                for (options.selected_gpu_ids) |wanted| {
                    if (wanted == engine.device_index) {
                        selected_count += 1;
                        break;
                    }
                }
            }
        }
        if (selected_count == 0) return error.NoGpuSelected;

        const selected = try allocator.alloc(*vsa_vulkan.VulkanEngine, selected_count);
        errdefer allocator.free(selected);
        const gpu_stats = try allocator.alloc(GpuRuntimeStats, selected_count);
        errdefer allocator.free(gpu_stats);

        var out_idx: usize = 0;
        for (fleet.engines) |*engine| {
            if (options.selected_gpu_ids.len != 0) {
                var keep = false;
                for (options.selected_gpu_ids) |wanted| {
                    if (wanted == engine.device_index) {
                        keep = true;
                        break;
                    }
                }
                if (!keep) continue;
            }
            selected[out_idx] = engine;
            gpu_stats[out_idx] = .{ .device_index = engine.device_index };
            out_idx += 1;
        }

        var self = OhlTrainer{
            .allocator = allocator,
            .fleet = fleet,
            .batcher = batcher,
            .engines = selected,
            .gpu_stats = gpu_stats,
            .threads = try allocator.alloc(std.Thread, selected_count),
        };
        self.applyOptions(options);
        return self;
    }

    pub fn deinit(self: *OhlTrainer) void {
        self.allocator.free(self.threads);
        self.allocator.free(self.gpu_stats);
        self.allocator.free(self.engines);
    }

    pub fn applyOptions(self: *OhlTrainer, options: TrainerOptions) void {
        self.current_tier.store(options.tier, .release);
        self.batch_size_override.store(options.batch_size_override, .release);
        self.checkpoint_interval_ms.store(options.checkpoint_interval_ms, .release);
        self.stop_after_minutes.store(options.stop_after_minutes, .release);
        self.stop_after_runes.store(options.stop_after_runes, .release);
        self.stop_after_slot_usage_bp.store(options.stop_after_slot_usage_bp, .release);
        self.idle_sleep_ms.store(@max(options.idle_sleep_ms, 1), .release);
        self.batcher.max_active_streams.store(options.max_active_streams, .release);

        for (self.engines) |engine| {
            engine.setTier(options.tier);
        }
    }

    pub fn start(self: *OhlTrainer) !void {
        self.is_running.store(true, .release);
        self.is_paused.store(false, .release);
        self.stop_reason.store(@intFromEnum(StopReason.none), .release);
        self.start_time = @intCast(sys.getMilliTick());
        self.last_checkpoint_ms.store(@intCast(self.start_time), .release);

        for (self.engines, 0..) |engine, i| {
            self.gpu_stats[i].device_index = engine.device_index;
            self.threads[i] = try std.Thread.spawn(.{ .allocator = self.allocator }, gpuWorker, .{ self, engine, &self.gpu_stats[i] });
        }

        while (self.is_running.load(.acquire)) {
            if (!self.is_paused.load(.acquire) and self.areAllStreamsDone()) {
                self.stop_reason.store(@intFromEnum(StopReason.completed), .release);
                break;
            }

            const now = sys.getMilliTick();
            if (!self.is_paused.load(.acquire)) {
                if (self.checkStopConditions(now)) break;
                try self.maybeCheckpoint(now);
            }

            const throughput = self.getThroughput();
            const processed = self.batcher.total_processed.load(.monotonic);
            sys.print("[FLEET] Throughput: {d:.2} MiB/s | Progress: {d} runes | Bottleneck: {s}\n", .{
                throughput,
                processed,
                self.getBottleneckReason(),
            });

            if (processed > 0) {
                const elapsed = @as(f64, @floatFromInt(now - @as(u64, @intCast(self.start_time)))) / 1000.0;
                if (elapsed > 0.1) {
                    sys.print("[BENCH] Fleet RPS: {d:.2} Runes/sec\n", .{@as(f64, @floatFromInt(processed)) / elapsed});
                }
            }

            sys.sleep(500);
        }

        self.is_running.store(false, .release);
        for (self.threads) |t| t.join();
    }

    pub fn requestStop(self: *OhlTrainer, reason: StopReason) void {
        self.stop_reason.store(@intFromEnum(reason), .release);
        self.is_running.store(false, .release);
    }

    pub fn pause(self: *OhlTrainer) void {
        self.is_paused.store(true, .release);
    }

    pub fn resumeTraining(self: *OhlTrainer) void {
        self.is_paused.store(false, .release);
    }

    pub fn requestCheckpoint(self: *OhlTrainer) void {
        self.checkpoint_requested.store(true, .release);
    }

    pub fn getOverallProgress(self: *const OhlTrainer) f64 {
        var total_size: usize = 0;
        var total_cursor: usize = 0;
        for (self.batcher.streams) |s| {
            total_size += s.totalSizeBytes();
            total_cursor += s.cursor.load(.monotonic);
        }
        if (total_size == 0) return 1.0;
        return @as(f64, @floatFromInt(total_cursor)) / @as(f64, @floatFromInt(total_size));
    }

    pub fn getThroughput(self: *const OhlTrainer) f64 {
        const elapsed = @as(f64, @floatFromInt(sys.getMilliTick() - @as(u64, @intCast(self.start_time)))) / 1000.0;
        if (elapsed < 0.1) return 0;
        return (@as(f64, @floatFromInt(self.batcher.total_processed.load(.monotonic))) / 1024.0 / 1024.0) / elapsed;
    }

    pub fn getProcessedRunes(self: *const OhlTrainer) u64 {
        return self.batcher.total_processed.load(.monotonic);
    }

    pub fn getElapsedMs(self: *const OhlTrainer) u64 {
        if (self.start_time <= 0) return 0;
        return sys.getMilliTick() - @as(u64, @intCast(self.start_time));
    }

    pub fn getEtaMs(self: *const OhlTrainer) u64 {
        const progress = self.getOverallProgress();
        if (progress <= 0.0001 or progress >= 0.9999) return 0;
        const elapsed = @as(f64, @floatFromInt(self.getElapsedMs()));
        const total = elapsed / progress;
        return @intFromFloat(@max(total - elapsed, 0.0));
    }

    pub fn getActiveStreamCount(self: *const OhlTrainer) u32 {
        var active: u32 = 0;
        for (self.batcher.streams) |s| {
            if (!s.done.load(.monotonic)) active += 1;
        }
        return active;
    }

    pub fn getTotalStreamCount(self: *const OhlTrainer) u32 {
        return @intCast(self.batcher.streams.len);
    }

    pub fn getDroppedRunes(self: *const OhlTrainer) u32 {
        var dropped: u32 = 0;
        for (self.engines) |engine| {
            if (engine.mapped_diag) |d| dropped += d.dropped_runes;
        }
        return dropped;
    }

    pub fn getCollisionStalls(self: *const OhlTrainer) u32 {
        var stalls: u32 = 0;
        for (self.engines) |engine| {
            if (engine.mapped_diag) |d| stalls += d.collision_stalls;
        }
        return stalls;
    }

    pub fn getBatchFillPct(self: *const OhlTrainer) f64 {
        const requested = self.batcher.last_requested_batch.load(.monotonic);
        if (requested == 0) return 0;
        return (@as(f64, @floatFromInt(self.batcher.last_packed_batch.load(.monotonic))) / @as(f64, @floatFromInt(requested))) * 100.0;
    }

    pub fn getLastCheckpointMs(self: *const OhlTrainer) u64 {
        return self.last_checkpoint_ms.load(.acquire);
    }

    pub fn getCheckpointAgeMs(self: *const OhlTrainer) u64 {
        const last = self.getLastCheckpointMs();
        return if (last == 0) 0 else sys.getMilliTick() - last;
    }

    pub fn getCurrentTier(self: *const OhlTrainer) u32 {
        return self.current_tier.load(.acquire);
    }

    pub fn getBatchSizeOverride(self: *const OhlTrainer) u32 {
        return self.batch_size_override.load(.acquire);
    }

    pub fn getCheckpointIntervalMs(self: *const OhlTrainer) u32 {
        return self.checkpoint_interval_ms.load(.acquire);
    }

    pub fn getMaxActiveStreams(self: *const OhlTrainer) u32 {
        return self.batcher.max_active_streams.load(.acquire);
    }

    pub fn getStopAfterMinutes(self: *const OhlTrainer) u32 {
        return self.stop_after_minutes.load(.acquire);
    }

    pub fn getStopAfterRunes(self: *const OhlTrainer) u64 {
        return self.stop_after_runes.load(.acquire);
    }

    pub fn getStopAfterSlotUsageBp(self: *const OhlTrainer) u32 {
        return self.stop_after_slot_usage_bp.load(.acquire);
    }

    pub fn getSelectedGpuCount(self: *const OhlTrainer) u32 {
        return @intCast(self.engines.len);
    }

    pub fn getStopReason(self: *const OhlTrainer) StopReason {
        return @enumFromInt(self.stop_reason.load(.acquire));
    }

    pub fn getBottleneckReason(self: *const OhlTrainer) []const u8 {
        const collision_alarm_bp: u32 = 9000;
        if (!self.is_running.load(.acquire)) return "idle";
        if (self.is_paused.load(.acquire)) return "paused";
        if (self.getActiveStreamCount() == 0) return "complete";
        if (self.getDroppedRunes() > 0) return "drop-pressure";
        if (self.getCollisionStalls() > 0 and self.getSlotUsageBp() >= collision_alarm_bp) return "collision-pressure";
        const requested = self.batcher.last_requested_batch.load(.monotonic);
        const packed_batch = self.batcher.last_packed_batch.load(.monotonic);
        if (requested > 0 and packed_batch < requested / 2) return "corpus-starvation";
        if (self.getMaxActiveStreams() != 0 and self.getActiveStreamCount() > self.getMaxActiveStreams()) return "stream-cap";
        return "balanced";
    }

    fn areAllStreamsDone(self: *const OhlTrainer) bool {
        for (self.batcher.streams) |s| {
            if (!s.done.load(.monotonic)) return false;
        }
        return true;
    }

    fn countUsedSlots(self: *const OhlTrainer) u32 {
        const tags: []const u64 = if (self.engines.len > 0)
            self.engines[0].getTagsData()
        else if (self.mapped_tags) |mapped|
            mapped
        else
            &.{};
        var used: u32 = 0;
        for (tags) |tag| {
            if (tag != 0) used += 1;
        }
        return used;
    }

    fn getSlotUsageBp(self: *const OhlTrainer) u32 {
        const mapped_tags: []const u64 = if (self.mapped_tags) |mapped| mapped else &.{};
        const capacity = if (self.engines.len > 0)
            self.engines[0].matrix_slots
        else
            @as(u32, @intCast(mapped_tags.len));
        if (capacity == 0) return 0;
        return @intFromFloat((@as(f64, @floatFromInt(self.countUsedSlots())) / @as(f64, @floatFromInt(capacity))) * 10_000.0);
    }

    fn checkStopConditions(self: *OhlTrainer, now: u64) bool {
        const stop_minutes = self.stop_after_minutes.load(.acquire);
        if (stop_minutes > 0) {
            const elapsed_minutes = @as(f64, @floatFromInt(now - @as(u64, @intCast(self.start_time)))) / 60_000.0;
            if (elapsed_minutes >= @as(f64, @floatFromInt(stop_minutes))) {
                self.requestStop(.max_time);
                return true;
            }
        }

        const stop_runes = self.stop_after_runes.load(.acquire);
        if (stop_runes > 0 and self.getProcessedRunes() >= stop_runes) {
            self.requestStop(.max_runes);
            return true;
        }

        const stop_slot_bp = self.stop_after_slot_usage_bp.load(.acquire);
        if (stop_slot_bp > 0 and self.getSlotUsageBp() >= stop_slot_bp) {
            self.requestStop(.slot_usage);
            return true;
        }

        return false;
    }

    fn maybeCheckpoint(self: *OhlTrainer, now: u64) !void {
        const interval = self.checkpoint_interval_ms.load(.acquire);
        const requested = self.checkpoint_requested.swap(false, .acq_rel);
        const due = interval > 0 and now - self.last_checkpoint_ms.load(.acquire) >= interval;
        if (!requested and !due) return;
        self.checkpoint_in_progress.store(true, .release);
        defer self.checkpoint_in_progress.store(false, .release);
        try self.checkpoint();
        self.last_checkpoint_ms.store(now, .release);
    }

    pub fn checkpoint(self: *OhlTrainer) !void {
        if (self.mapped_lattice == null or self.mapped_meaning == null or self.mapped_tags == null) return;

        for (self.engines) |engine| {
            try engine.syncDeviceToHost(self.mapped_meaning.?, self.mapped_tags.?, self.mapped_lattice.?);

            if (engine.mapped_edges) |edges_ptr| {
                var graph = vsa.FlatGraph.fromMapped(@as([*]vsa.GraphNode, @ptrCast(@alignCast(edges_ptr))), engine.matrix_slots);

                const matrix_view = vsa.MeaningMatrix{
                    .data = self.mapped_meaning.?[0..core.config.SEMANTIC_ENTRIES],
                    .tags = self.mapped_tags.?[0..core.config.TAG_ENTRIES],
                };

                var prng = std.Random.DefaultPrng.init(@intCast(sys.getMilliTick()));
                const random = prng.random();

                for (0..1024) |_| {
                    const slot_a = random.uintLessThan(u32, engine.matrix_slots);
                    if (matrix_view.tags.?[slot_a] == 0) continue;

                    const slot_b = random.uintLessThan(u32, engine.matrix_slots);
                    if (slot_a == slot_b or matrix_view.tags.?[slot_b] == 0) continue;

                    const vec_a = matrix_view.collapseToBinaryAtSlot(slot_a);
                    const vec_b = matrix_view.collapseToBinaryAtSlot(slot_b);

                    graph.maintainEdges(slot_a, vec_a, slot_b, vec_b, &matrix_view);
                }
            }
        }

        if (self.lattice_file) |f| sys.flushMappedMemory(f);
        if (self.meaning_file) |f| sys.flushMappedMemory(f);
        if (self.tags_file) |f| sys.flushMappedMemory(f);

        sys.print("[FLEET] Crystallization Checkpoint OK (V33 Graph Refined)\n", .{});
    }

    fn gpuWorker(self: *OhlTrainer, engine: *vsa_vulkan.VulkanEngine, stats: *GpuRuntimeStats) void {
        sys.print("[GPU-{d}] Worker Online: {s}\n", .{ engine.device_index, engine.device_name });

        while (self.is_running.load(.acquire)) {
            if (self.is_paused.load(.acquire)) {
                _ = stats.idle_loops.fetchAdd(1, .monotonic);
                sys.sleep(self.idle_sleep_ms.load(.acquire));
                continue;
            }

            const tier = @as(vsa_vulkan.OperationalTier, @enumFromInt(self.current_tier.load(.acquire)));
            const tier_batch = tier.getBatchSize(engine.max_workgroup_invocations);
            const override_batch = self.batch_size_override.load(.acquire);
            const batch_size = @min(
                if (override_batch > 0) override_batch else tier_batch,
                config.MAX_STREAMS,
            );
            stats.target_batch_size.store(batch_size, .monotonic);

            const f = engine.frame_idx;
            var num_streams: u32 = 0;
            const num_packed = self.batcher.pack(batch_size, engine.mapped_chars[f].?[0..batch_size], engine.mapped_rotors[f].?[0..(batch_size * 18)], engine.mapped_index[f].?[0..batch_size], &num_streams);
            stats.last_batch_size.store(num_packed, .monotonic);

            if (num_packed == 0) {
                _ = stats.idle_loops.fetchAdd(1, .monotonic);
                sys.sleep(self.idle_sleep_ms.load(.acquire));
                continue;
            }

            const dispatch_start = sys.getMilliTick();
            engine.dispatchMergedEtch(num_packed, num_streams) catch |err| {
                sys.print("[GPU-{d}] Dispatch Error: {any}\n", .{ engine.device_index, err });
                self.requestStop(.failed);
                break;
            };
            const dispatch_elapsed = sys.getMilliTick() - dispatch_start;
            _ = stats.processed_runes.fetchAdd(num_packed, .monotonic);
            _ = stats.dispatched_batches.fetchAdd(1, .monotonic);
            _ = stats.busy_time_ms.fetchAdd(dispatch_elapsed, .monotonic);
            stats.last_dispatch_ms.store(dispatch_elapsed, .monotonic);
        }

        sys.print("[GPU-{d}] Worker Offline.\n", .{engine.device_index});
    }
};

fn main_wrapped(init: std.process.Init) !void {
    const allocator = init.gpa;
    _ = init.io;

    sys.print("\nGhost Trainer {s}: Sovereign Fleet\n", .{@import("ghost_core").VERSION});

    if (!sys.acquireTrainerLock()) {
        sys.print("[FATAL] Trainer is already running or lock could not be acquired.\n", .{});
        sys.exit(1);
    }

    var fleet = try vsa_vulkan.MultiGPU.init(allocator, init.io);
    defer fleet.deinit();

    const lattice_abs_path = try config.getPath(allocator, config.LATTICE_REL_PATH);
    const semantic_abs_path = try config.getPath(allocator, config.SEMANTIC_REL_PATH);
    const tag_abs_path = try config.getPath(allocator, config.TAG_REL_PATH);

    const m_lattice = try sys.createMappedFile(allocator, lattice_abs_path, config.UNIFIED_SIZE_BYTES);
    const m_meaning = try sys.createMappedFile(allocator, semantic_abs_path, config.SEMANTIC_SIZE_BYTES);
    const m_tags = try sys.createMappedFile(allocator, tag_abs_path, config.TAG_SIZE_BYTES);

    const host_lattice = @as([*]u16, @ptrCast(@alignCast(m_lattice.data.ptr)))[0 .. m_lattice.data.len / @sizeOf(u16)];
    const host_meaning = @as([*]u32, @ptrCast(@alignCast(m_meaning.data.ptr)))[0..config.SEMANTIC_ENTRIES];
    const host_tags = @as([*]u64, @ptrCast(@alignCast(m_tags.data.ptr)))[0..config.TAG_ENTRIES];

    for (fleet.engines) |*engine| {
        engine.bindHostState(host_meaning, host_tags, host_lattice);
    }

    const corpus_files = sys.findCorpusFiles(allocator) catch try allocator.alloc([]const u8, 0);
    defer {
        for (corpus_files) |path| allocator.free(path);
        allocator.free(corpus_files);
    }

    var streams = try allocator.alloc(StreamState, @max(corpus_files.len, 1));
    var active_streams: usize = 0;
    if (corpus_files.len > 0) {
        for (corpus_files) |path| {
            streams[active_streams] = StreamState.initFile(allocator, path, path, 1) catch continue;
            if (streams[active_streams].totalSizeBytes() == 0) {
                streams[active_streams].deinit();
                continue;
            }
            active_streams += 1;
        }
        sys.print("[TRAINER] Loaded {d} corpus streams\n", .{active_streams});
    }

    if (active_streams == 0) {
        sys.print("[TRAINER] No corpus files found. Using synthetic benchmark.\n", .{});
        const bench_pattern = "THE QUICK BROWN FOX JUMPS OVER THE LAZY DOG. GHOST ENGINE SOVEREIGNTY. ";
        const data = try allocator.alloc(u8, bench_pattern.len * 1000000);
        for (0..1000000) |i| {
            @memcpy(data[i * bench_pattern.len .. (i + 1) * bench_pattern.len], bench_pattern);
        }
        streams[0] = StreamState.init(data, "bench_stream", 1);
        active_streams = 1;
    }

    var batcher = try GreedyBatcher.init(allocator, streams[0..active_streams]);
    defer batcher.deinit();
    var trainer = try OhlTrainer.init(allocator, &fleet, &batcher, .{});
    defer trainer.deinit();

    trainer.mapped_lattice = host_lattice;
    trainer.mapped_meaning = host_meaning;
    trainer.mapped_tags = host_tags;
    trainer.lattice_file = &m_lattice;
    trainer.meaning_file = &m_meaning;
    trainer.tags_file = &m_tags;
    trainer.start_time = @intCast(sys.getMilliTick());

    try trainer.start();
}

pub fn main(init: std.process.Init) void {
    main_wrapped(init) catch |err| {
        sys.print("\n[FATAL ERROR] {any}\n", .{err});
        std.process.exit(1);
    };
}
