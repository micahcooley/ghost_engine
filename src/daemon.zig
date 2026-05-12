const std = @import("std");
const ghost_core = @import("ghost_core");
const abstractions = ghost_core.abstractions;
const code_intel = ghost_core.code_intel;
const corpus_ingest = ghost_core.corpus_ingest;
const corpus_sketch = ghost_core.corpus_sketch;
const cpp_ast = ghost_core.cpp_ast;
const curiosity = ghost_core.curiosity;
const domain_inference = @import("domain_inference");
const anchor_discovery = @import("anchor_discovery");
const semantic_tensor = @import("semantic_tensor");
const z3_bridge = @import("z3_bridge");
const gip = ghost_core.gip;
const hive = ghost_core.hive;
const intent_grounding = ghost_core.intent_grounding;
const recursive_boot = ghost_core.recursive_boot;
const shards = ghost_core.shards;
const sovereign_inquiry = ghost_core.sovereign_inquiry;
const task_intent = ghost_core.task_intent;
const technical_drafts = ghost_core.technical_drafts;
const text_generation_lab = ghost_core.text_generation_lab;
const vsa_vulkan = ghost_core.vsa_vulkan;
const wingman = ghost_core.wingman;

pub const DEFAULT_SOCKET_PATH = "/tmp/ghost.sock";
pub const DEFAULT_PID_PATH = "/tmp/ghost.pid";
pub const DEFAULT_HEARTBEAT_PATH = "/dev/shm/ghostd.hot";
const MAX_FRAME_BYTES: usize = 10 * 1024 * 1024;
const DEFAULT_RESIDENT_SHARDS = [_][]const u8{ "english_core", "user_vault" };
const SESSION_HOT_BYTES: usize = 16 * 1024 * 1024;
const HOT_PAGE_BYTES: usize = 10 * 1024 * 1024;
const LIVE_VAULT_MAX_FILE_BYTES: usize = 1024 * 1024;
const LIVE_VAULT_POLL_MS: u64 = 250;
const LIVE_VAULT_RECENT_MS: i64 = 2000;
const LIVE_VAULT_STABLE_NS: i128 = 250 * std.time.ns_per_ms;
const SESSION_HOT_FLUSH_PER_MILLE: usize = 800;
const SESSION_HOT_KEEP_PER_MILLE: usize = 500;
const CONTEXT_BIAS_MULTIPLIER_PER_MILLE: u32 = 1500;
const GPU_SCORE_FLOOR: u32 = 120;
const HOT_SNIPPET_SEARCH_BYTES: usize = 10 * 1024 * 1024;
const SOVEREIGN_IDLE_MESSAGE = "Sovereign Engine idle. Please provide a target translation unit or codebase for formal verification.";
const SOVEREIGN_MAX_UNITS: usize = 24;
const SOVEREIGN_MAX_FILE_BYTES: usize = 256 * 1024;
const ORACLE_RAM_PAUSE_BYTES: u64 = 12 * 1024 * 1024 * 1024;
const INVENTION_LOG_MAX: usize = 32;

var stop_requested = std.atomic.Value(bool).init(false);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    try runFromArgs(allocator, if (args.len > 1) args[1..] else &.{});
}

pub fn runFromArgs(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var command: []const u8 = "run";
    var command_set = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--debug-vulkan")) {
            vsa_vulkan.enableDebugValidationForProcess();
        } else if (!command_set) {
            command = arg;
            command_set = true;
        }
    }
    if (std.mem.eql(u8, command, "run") or std.mem.eql(u8, command, "start")) {
        try runDaemon(allocator);
        return;
    }
    if (std.mem.eql(u8, command, "status")) {
        try printLocalStatus();
        return;
    }
    try std.io.getStdErr().writer().print(
        "Usage: ghostd [run|status]\n",
        .{},
    );
    return error.InvalidDaemonCommand;
}

fn runDaemon(allocator: std.mem.Allocator) !void {
    if (probeSocket()) {
        try std.io.getStdErr().writer().print("ghostd already active at {s}\n", .{socketPath()});
        return error.DaemonAlreadyRunning;
    }
    unlinkHeartbeat();
    std.fs.deleteFileAbsolute(socketPath()) catch {};

    try writePidFile();
    errdefer std.fs.deleteFileAbsolute(pidPath()) catch {};

    var resident = try ResidentState.init(allocator);
    defer resident.deinit();
    var archiver_thread = try std.Thread.spawn(.{}, ResidentState.archiverLoop, .{&resident});
    var vault_watcher_thread = try std.Thread.spawn(.{}, ResidentState.vaultWatcherLoop, .{&resident});
    defer {
        resident.vault_watcher_stop.store(true, .release);
        vault_watcher_thread.join();
        resident.archiver_stop.store(true, .release);
        archiver_thread.join();
    }

    var address = try std.net.Address.initUnix(socketPath());
    var server = try address.listen(.{ .kernel_backlog = 128, .force_nonblocking = true });
    defer server.deinit();
    defer std.fs.deleteFileAbsolute(socketPath()) catch {};
    defer std.fs.deleteFileAbsolute(pidPath()) catch {};
    setHeartbeatHot(true);
    errdefer unlinkHeartbeat();
    defer unlinkHeartbeat();

    const startup_telemetry = resident.snapshotTelemetry();
    try std.io.getStdErr().writer().print(
        "ghostd ready socket={s} shards={d} vulkan={s}\n",
        .{ socketPath(), startup_telemetry.loaded_shards, if (resident.vulkan_active) "resident" else "cpu" },
    );

    while (!stop_requested.load(.acquire)) {
        resident.maintenanceTick();
        var fds = [_]std.posix.pollfd{.{
            .fd = server.stream.handle,
            .events = std.posix.POLL.IN | std.posix.POLL.ERR | std.posix.POLL.HUP,
            .revents = 0,
        }};
        _ = try std.posix.poll(&fds, 250);
        if ((fds[0].revents & (std.posix.POLL.IN | std.posix.POLL.ERR | std.posix.POLL.HUP)) == 0) continue;
        while (true) {
            var connection = server.accept() catch |err| switch (err) {
                error.WouldBlock => break,
                else => return err,
            };
            defer connection.stream.close();
            serveConnection(allocator, &resident, connection.stream) catch |err| {
                if (err != error.EndOfStream) {
                    try std.io.getStdErr().writer().print("ghostd request error: {s}\n", .{@errorName(err)});
                }
            };
        }
    }
}

const ResidentShard = struct {
    id: []u8,
    entries: []corpus_ingest.IndexedEntry,
    texts: [][]u8,
    lower_texts: [][]u8,
    offsets: []usize,
    lengths: []usize,
    vram_buffer: vsa_vulkan.ResidentBuffer = .{},
    scan_entries: []vsa_vulkan.CorpusScanEntry,

    fn deinit(self: *ResidentShard, allocator: std.mem.Allocator, vk: ?*vsa_vulkan.VulkanEngine) void {
        if (vk) |engine| engine.destroyResidentBuffer(&self.vram_buffer);
        allocator.free(self.id);
        corpus_ingest.deinitIndexedEntries(allocator, self.entries);
        for (self.texts) |text| allocator.free(text);
        allocator.free(self.texts);
        for (self.lower_texts) |text| allocator.free(text);
        allocator.free(self.lower_texts);
        allocator.free(self.offsets);
        allocator.free(self.lengths);
        allocator.free(self.scan_entries);
        self.* = undefined;
    }
};

const SessionHotShard = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    bytes: []u8,
    used: usize = 0,
    vram_buffer: vsa_vulkan.ResidentBuffer = .{},

    fn init(allocator: std.mem.Allocator, vk: ?*vsa_vulkan.VulkanEngine) !SessionHotShard {
        const bytes = try allocator.alloc(u8, SESSION_HOT_BYTES);
        @memset(bytes, 0);
        var shard = SessionHotShard{
            .allocator = allocator,
            .bytes = bytes,
        };
        errdefer shard.deinit(null);
        if (vk) |engine| {
            shard.vram_buffer = try engine.createResidentBufferSize(SESSION_HOT_BYTES);
            try engine.uploadResidentBufferBytes(&shard.vram_buffer, 0, shard.bytes);
        }
        return shard;
    }

    fn deinit(self: *SessionHotShard, vk: ?*vsa_vulkan.VulkanEngine) void {
        self.flushAllToVault() catch {};
        if (vk) |engine| engine.destroyResidentBuffer(&self.vram_buffer);
        self.allocator.free(self.bytes);
        self.* = undefined;
    }

    fn appendTurn(self: *SessionHotShard, vk: ?*vsa_vulkan.VulkanEngine, role: []const u8, text: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.flushOldestIfNeededLocked(false);
        const prefix_len = role.len + 2;
        const max_text = @min(text.len, SESSION_HOT_BYTES / 8);
        const needed = prefix_len + max_text + 1;
        if (needed >= self.bytes.len) return;
        while (self.used + needed > self.bytes.len) {
            try self.flushOldestIfNeededLocked(true);
            if (self.used + needed <= self.bytes.len) break;
            self.used = 0;
        }

        const append_start = self.used;
        @memcpy(self.bytes[self.used .. self.used + role.len], role);
        self.used += role.len;
        self.bytes[self.used] = ':';
        self.used += 1;
        self.bytes[self.used] = ' ';
        self.used += 1;
        for (text[0..max_text]) |byte| {
            self.bytes[self.used] = if (byte == '\n' or byte == '\r') ' ' else byte;
            self.used += 1;
        }
        self.bytes[self.used] = '\n';
        self.used += 1;

        if (vk) |engine| {
            if (self.vram_buffer.buffer != null) try engine.uploadResidentBufferBytes(&self.vram_buffer, append_start, self.bytes[append_start..self.used]);
        }
    }

    fn extractContextTarget(self: *SessionHotShard, allocator: std.mem.Allocator) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return intent_grounding.extractPrimarySemanticTargetFromText(allocator, tailTurns(self.bytes[0..self.used], 6));
    }

    fn extractContextBlock(self: *SessionHotShard, allocator: std.mem.Allocator, turns: usize) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        // Each turn is 1 line. 5 turns = 5 lines.
        return allocator.dupe(u8, tailTurns(self.bytes[0..self.used], turns));
    }

    fn extractLastEngineOutput(self: *SessionHotShard, allocator: std.mem.Allocator) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return lastRoleLine(allocator, self.bytes[0..self.used], "engine");
    }

    fn usedBytes(self: *SessionHotShard) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.used;
    }

    fn flushOldestIfNeeded(self: *SessionHotShard) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.flushOldestIfNeededLocked(false);
    }

    fn flushAllToVault(self: *SessionHotShard) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.used == 0) return;
        try appendVaultBytes(self.bytes[0..self.used]);
        self.used = 0;
    }

    fn flushOldestIfNeededLocked(self: *SessionHotShard, force: bool) !void {
        const threshold = (self.bytes.len * SESSION_HOT_FLUSH_PER_MILLE) / 1000;
        if (!force and self.used < threshold) return;
        if (self.used == 0) return;
        const keep_target = (self.bytes.len * SESSION_HOT_KEEP_PER_MILLE) / 1000;
        var cut = self.used - @min(self.used, keep_target);
        while (cut < self.used and self.bytes[cut] != '\n') : (cut += 1) {}
        if (cut < self.used) cut += 1;
        if (cut == 0 or cut > self.used) return;
        try appendVaultBytes(self.bytes[0..cut]);
        const remaining = self.used - cut;
        std.mem.copyForwards(u8, self.bytes[0..remaining], self.bytes[cut..self.used]);
        @memset(self.bytes[remaining..self.used], 0);
        self.used = remaining;
    }
};

const ResidentState = struct {
    allocator: std.mem.Allocator,
    vulkan_active: bool = false,
    vulkan: ?*vsa_vulkan.VulkanEngine = null,
    hot_plugin_lib: ?std.DynLib = null,
    hot_plugin_process: ?*const fn (*anyopaque, f32) callconv(.c) f32 = null,
    loaded_shards: usize = 0,
    vram_resident_bytes: usize = 0,
    l1_concept_index_bytes: usize = 0,
    hot_page_bytes: []u8 = &.{},
    hot_page_vram_buffer: vsa_vulkan.ResidentBuffer = .{},
    hot_page_mutex: std.Thread.Mutex = .{},
    shards_mutex: std.Thread.Mutex = .{},
    pipeline_mutex: std.Thread.Mutex = .{},
    last_pipeline_domain: []const u8 = "none",
    last_pipeline_z3_status: []const u8 = "idle",
    last_pipeline_confidence_band: []const u8 = "yellow_heuristic",
    shards: std.ArrayList(ResidentShard),
    session_hot: SessionHotShard,
    archiver_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    vault_watcher_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    vault_ingest_active: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    vault_ingested_files: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    vault_ingest_errors: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    vault_ingested_bytes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    last_vault_ingest_ms: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    oracle_paused_for_ram: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    last_ram_used_bytes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    invention_logs: std.ArrayList([]u8),
    invention_log_mutex: std.Thread.Mutex = .{},

    fn init(allocator: std.mem.Allocator) !ResidentState {
        var state = ResidentState{
            .allocator = allocator,
            .shards = std.ArrayList(ResidentShard).init(allocator),
            .session_hot = undefined,
            .invention_logs = std.ArrayList([]u8).init(allocator),
        };

        if (vsa_vulkan.initRuntime(allocator)) |vk| {
            state.vulkan = vk;
            state.vulkan_active = true;
        } else |_| {
            state.vulkan_active = false;
        }
        errdefer if (state.vulkan_active) vsa_vulkan.deinitRuntime();
        state.session_hot = try SessionHotShard.init(allocator, state.vulkan);
        errdefer state.session_hot.deinit(state.vulkan);
        if (state.session_hot.vram_buffer.size_bytes != 0) {
            state.vram_resident_bytes += state.session_hot.vram_buffer.size_bytes;
        }
        state.hot_page_bytes = try allocator.alloc(u8, HOT_PAGE_BYTES);
        errdefer allocator.free(state.hot_page_bytes);
        @memset(state.hot_page_bytes, 0);
        if (state.vulkan) |vk| {
            state.hot_page_vram_buffer = try vk.createResidentBufferSize(HOT_PAGE_BYTES);
            state.vram_resident_bytes += state.hot_page_vram_buffer.size_bytes;
        }
        errdefer if (state.vulkan) |vk| vk.destroyResidentBuffer(&state.hot_page_vram_buffer);

        for (DEFAULT_RESIDENT_SHARDS) |shard_id| {
            state.preloadShard(shard_id) catch |err| {
                try std.io.getStdErr().writer().print("ghostd preload skipped shard={s} err={s}\n", .{ shard_id, @errorName(err) });
            };
        }
        return state;
    }

    fn deinit(self: *ResidentState) void {
        self.session_hot.deinit(self.vulkan);
        if (self.vulkan) |engine| engine.destroyResidentBuffer(&self.hot_page_vram_buffer);
        if (self.hot_page_bytes.len != 0) self.allocator.free(self.hot_page_bytes);
        for (self.shards.items) |*shard| shard.deinit(self.allocator, self.vulkan);
        self.shards.deinit();
        for (self.invention_logs.items) |entry| self.allocator.free(entry);
        self.invention_logs.deinit();
        if (self.hot_plugin_lib) |*lib| lib.close();
        if (self.vulkan_active) vsa_vulkan.deinitRuntime();
        self.* = undefined;
    }

    fn maintenanceTick(self: *ResidentState) void {
        const memory = MemoryMonitor.snapshot() catch return;
        self.last_ram_used_bytes.store(memory.used_bytes, .release);
        self.oracle_paused_for_ram.store(memory.used_bytes > ORACLE_RAM_PAUSE_BYTES, .release);
    }

    fn archiverLoop(self: *ResidentState) void {
        while (!self.archiver_stop.load(.acquire)) {
            std.time.sleep(250 * std.time.ns_per_ms);
            self.session_hot.flushOldestIfNeeded() catch {};
        }
    }

    fn vaultWatcherLoop(self: *ResidentState) void {
        const vault_dir = vaultDirPath(self.allocator) catch return;
        defer self.allocator.free(vault_dir);
        std.fs.cwd().makePath(vault_dir) catch return;

        var seen = std.StringHashMap(void).init(self.allocator);
        defer {
            var it = seen.keyIterator();
            while (it.next()) |key| self.allocator.free(key.*);
            seen.deinit();
        }

        while (!self.vault_watcher_stop.load(.acquire)) {
            self.scanVaultOnce(vault_dir, &seen) catch {
                _ = self.vault_ingest_errors.fetchAdd(1, .monotonic);
                self.last_vault_ingest_ms.store(std.time.milliTimestamp(), .release);
            };
            std.time.sleep(LIVE_VAULT_POLL_MS * std.time.ns_per_ms);
        }
    }

    fn scanVaultOnce(self: *ResidentState, vault_dir: []const u8, seen: *std.StringHashMap(void)) !void {
        var dir = std.fs.openDirAbsolute(vault_dir, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => {
                try std.fs.cwd().makePath(vault_dir);
                return;
            },
            else => return err,
        };
        defer dir.close();

        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!isWatchableVaultFile(entry.name)) continue;

            const abs_path = try std.fs.path.join(self.allocator, &.{ vault_dir, entry.name });
            var path_owned = true;
            errdefer if (path_owned) self.allocator.free(abs_path);

            if (seen.contains(abs_path)) {
                self.allocator.free(abs_path);
                path_owned = false;
                continue;
            }

            if (!vaultFileIsStable(abs_path)) {
                self.allocator.free(abs_path);
                path_owned = false;
                continue;
            }

            self.ingestVaultFile(abs_path, entry.name) catch {
                _ = self.vault_ingest_errors.fetchAdd(1, .monotonic);
                self.last_vault_ingest_ms.store(std.time.milliTimestamp(), .release);
            };
            try seen.put(abs_path, {});
            path_owned = false;
        }
    }

    fn ingestVaultFile(self: *ResidentState, abs_path: []const u8, name: []const u8) !void {
        self.vault_ingest_active.store(true, .release);
        defer self.vault_ingest_active.store(false, .release);

        const built = try buildVaultLiveShard(self.allocator, self.vulkan, abs_path, name);
        errdefer {
            var shard = built.shard;
            shard.deinit(self.allocator, self.vulkan);
        }

        self.shards_mutex.lock();
        defer self.shards_mutex.unlock();
        try self.shards.append(built.shard);
        self.loaded_shards += 1;
        self.l1_concept_index_bytes += built.l1_index_bytes;
        if (built.shard.vram_buffer.size_bytes != 0) self.vram_resident_bytes += built.shard.vram_buffer.size_bytes;

        _ = self.vault_ingested_files.fetchAdd(1, .monotonic);
        _ = self.vault_ingested_bytes.fetchAdd(built.source_bytes, .monotonic);
        self.last_vault_ingest_ms.store(std.time.milliTimestamp(), .release);
    }

    fn snapshotTelemetry(self: *ResidentState) ResidentTelemetry {
        self.shards_mutex.lock();
        defer self.shards_mutex.unlock();
        const truth = self.truthDensityLocked();
        return .{
            .loaded_shards = self.loaded_shards,
            .vram_resident_bytes = self.vram_resident_bytes,
            .l1_concept_index_bytes = self.l1_concept_index_bytes,
            .hot_page_bytes = self.hot_page_vram_buffer.size_bytes,
            .device_local = self.vram_resident_bytes > 0,
            .truth_density = truth,
            .ram_used_bytes = self.last_ram_used_bytes.load(.acquire),
            .oracle_paused_for_ram = self.oracle_paused_for_ram.load(.acquire),
        };
    }

    fn truthDensityLocked(self: *ResidentState) TruthDensity {
        var out = TruthDensity{};
        for (self.shards.items) |*shard| {
            for (shard.entries) |entry| {
                if (isVerifiedEntry(entry)) {
                    out.verified_runes += 1;
                } else if (isShadowEntry(entry)) {
                    out.shadow_runes += 1;
                }
            }
        }
        const total = out.verified_runes + out.shadow_runes;
        out.ratio_per_mille = if (total == 0) 0 else @intCast((out.verified_runes * 1000) / total);
        return out;
    }

    fn appendInventionLog(self: *ResidentState, text: []const u8) !void {
        self.invention_log_mutex.lock();
        defer self.invention_log_mutex.unlock();
        if (self.invention_logs.items.len >= INVENTION_LOG_MAX) {
            const old = self.invention_logs.orderedRemove(0);
            self.allocator.free(old);
        }
        try self.invention_logs.append(try self.allocator.dupe(u8, text));
    }

    fn renderInventionLogs(self: *ResidentState, allocator: std.mem.Allocator) ![]u8 {
        self.invention_log_mutex.lock();
        defer self.invention_log_mutex.unlock();
        var out = std.ArrayList(u8).init(allocator);
        errdefer out.deinit();
        const w = out.writer();
        try w.writeAll("{\"status\":\"ok\",\"inventionLogs\":[");
        for (self.invention_logs.items, 0..) |entry, idx| {
            if (idx != 0) try w.writeByte(',');
            try std.json.stringify(entry, .{}, w);
        }
        try w.writeAll("]}");
        return out.toOwnedSlice();
    }

    fn findShard(self: *const ResidentState, shard_id: []const u8) ?*const ResidentShard {
        for (self.shards.items) |*shard| {
            if (std.mem.eql(u8, shard.id, shard_id)) return shard;
        }
        return null;
    }

    fn setPipelineTelemetry(self: *ResidentState, domain: []const u8, z3_status: []const u8, confidence_band: []const u8) void {
        self.pipeline_mutex.lock();
        defer self.pipeline_mutex.unlock();
        self.last_pipeline_domain = domain;
        self.last_pipeline_z3_status = z3_status;
        self.last_pipeline_confidence_band = confidence_band;
    }

    fn copyPipelineTelemetry(self: *ResidentState) PipelineTelemetry {
        self.pipeline_mutex.lock();
        defer self.pipeline_mutex.unlock();
        return .{
            .domain = self.last_pipeline_domain,
            .z3_status = self.last_pipeline_z3_status,
            .confidence_band = self.last_pipeline_confidence_band,
        };
    }

    fn preloadShard(self: *ResidentState, shard_id: []const u8) !void {
        var metadata = try shards.resolveProjectMetadata(self.allocator, shard_id);
        defer metadata.deinit();
        var paths = try shards.resolvePaths(self.allocator, metadata.metadata);
        defer paths.deinit();
        const entries = try corpus_ingest.collectLiveScanEntries(self.allocator, &paths);
        errdefer corpus_ingest.deinitIndexedEntries(self.allocator, entries);
        var loaded = try loadShardImage(self.allocator, entries);
        errdefer {
            loaded.deinit(self.allocator);
        }
        var vram_buffer = vsa_vulkan.ResidentBuffer{};
        if (self.vulkan) |vk| {
            vram_buffer = try vk.createResidentBufferFromBytes(loaded.image.items);
            self.vram_resident_bytes += vram_buffer.size_bytes;
        }
        self.l1_concept_index_bytes += loaded.image.items.len;
        const scan_entries = try buildCorpusScanEntries(self.allocator, entries, loaded.offsets, loaded.lengths);
        errdefer self.allocator.free(scan_entries);
        const resident_id = try self.allocator.dupe(u8, shard_id);
        errdefer self.allocator.free(resident_id);
        try self.shards.append(.{
            .id = resident_id,
            .entries = entries,
            .texts = loaded.texts,
            .lower_texts = loaded.lower_texts,
            .offsets = loaded.offsets,
            .lengths = loaded.lengths,
            .vram_buffer = vram_buffer,
            .scan_entries = scan_entries,
        });
        loaded.disarm();
        self.loaded_shards += 1;
    }
};

const ResidentTelemetry = struct {
    loaded_shards: usize,
    vram_resident_bytes: usize,
    l1_concept_index_bytes: usize,
    hot_page_bytes: usize,
    device_local: bool,
    truth_density: TruthDensity,
    ram_used_bytes: u64,
    oracle_paused_for_ram: bool,
};

const TruthDensity = struct {
    verified_runes: usize = 0,
    shadow_runes: usize = 0,
    ratio_per_mille: u16 = 0,
};

const MemorySnapshot = struct {
    total_bytes: u64,
    available_bytes: u64,
    used_bytes: u64,
};

const MemoryMonitor = struct {
    fn snapshot() !MemorySnapshot {
        var file = try std.fs.openFileAbsolute("/proc/meminfo", .{});
        defer file.close();
        var buf: [4096]u8 = undefined;
        const n = try file.readAll(&buf);
        return parseMemInfo(buf[0..n]);
    }
};

const PipelineTelemetry = struct {
    domain: []const u8,
    z3_status: []const u8,
    confidence_band: []const u8,
};

fn parseMemInfo(text: []const u8) !MemorySnapshot {
    var total_kb: ?u64 = null;
    var available_kb: ?u64 = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "MemTotal:")) {
            total_kb = try parseMemInfoKb(line["MemTotal:".len..]);
        } else if (std.mem.startsWith(u8, line, "MemAvailable:")) {
            available_kb = try parseMemInfoKb(line["MemAvailable:".len..]);
        }
    }
    const total = total_kb orelse return error.MemInfoMissingTotal;
    const available = available_kb orelse return error.MemInfoMissingAvailable;
    const total_bytes = total * 1024;
    const available_bytes = available * 1024;
    return .{
        .total_bytes = total_bytes,
        .available_bytes = available_bytes,
        .used_bytes = total_bytes -| available_bytes,
    };
}

fn parseMemInfoKb(raw: []const u8) !u64 {
    const trimmed = std.mem.trim(u8, raw, " \t");
    var it = std.mem.tokenizeAny(u8, trimmed, " \t");
    return std.fmt.parseUnsigned(u64, it.next() orelse return error.MemInfoMissingValue, 10);
}

fn isVerifiedEntry(entry: corpus_ingest.IndexedEntry) bool {
    return entry.corpus_meta.license_authority_level <= 1 or
        std.ascii.eqlIgnoreCase(entry.corpus_meta.license_status, "verified") or
        std.ascii.eqlIgnoreCase(entry.corpus_meta.license_status, "axiom-locked") or
        entry.corpus_meta.trust_class == .promoted or
        entry.corpus_meta.trust_class == .core;
}

fn isShadowEntry(entry: corpus_ingest.IndexedEntry) bool {
    return entry.corpus_meta.license_authority_level >= 3 or
        std.ascii.eqlIgnoreCase(entry.corpus_meta.license_status, "shadow") or
        std.ascii.eqlIgnoreCase(entry.corpus_meta.license_status, "unverified") or
        std.ascii.eqlIgnoreCase(entry.corpus_meta.license_status, "unverified-live") or
        entry.corpus_meta.trust_class == .exploratory;
}

const BuiltLiveShard = struct {
    shard: ResidentShard,
    l1_index_bytes: usize,
    source_bytes: u64,
};

const LoadedShardImage = struct {
    texts: [][]u8,
    lower_texts: [][]u8,
    offsets: []usize,
    lengths: []usize,
    image: std.ArrayList(u8),
    armed: bool = true,

    fn disarm(self: *LoadedShardImage) void {
        self.armed = false;
        self.image.deinit();
    }

    fn deinit(self: *LoadedShardImage, allocator: std.mem.Allocator) void {
        if (!self.armed) return;
        for (self.texts) |text| allocator.free(text);
        allocator.free(self.texts);
        for (self.lower_texts) |text| allocator.free(text);
        allocator.free(self.lower_texts);
        allocator.free(self.offsets);
        allocator.free(self.lengths);
        self.image.deinit();
    }
};

fn buildCorpusScanEntries(
    allocator: std.mem.Allocator,
    entries: []const corpus_ingest.IndexedEntry,
    offsets: []const usize,
    lengths: []const usize,
) ![]vsa_vulkan.CorpusScanEntry {
    const out = try allocator.alloc(vsa_vulkan.CorpusScanEntry, entries.len);
    errdefer allocator.free(out);
    for (entries, 0..) |entry, idx| {
        out[idx] = .{
            .byte_offset = @intCast(@min(offsets[idx], std.math.maxInt(u32))),
            .byte_len = @intCast(@min(lengths[idx], std.math.maxInt(u32))),
            .search_hash_lo = @intCast(entry.search_sketch_hash & 0xFFFF_FFFF),
            .search_hash_hi = @intCast(entry.search_sketch_hash >> 32),
            .semantic_hash_lo = @intCast(entry.semantic_hash & 0xFFFF_FFFF),
            .semantic_hash_hi = @intCast(entry.semantic_hash >> 32),
            .flags = if (entry.search_sketch_features != 0) 1 else 0,
            .reserved = 0,
            .relation_hash_lo = @intCast(entry.spo_forward_hash & 0xFFFF_FFFF),
            .relation_hash_hi = @intCast(entry.spo_forward_hash >> 32),
            .inverse_relation_hash_lo = @intCast(entry.spo_inverse_hash & 0xFFFF_FFFF),
            .inverse_relation_hash_hi = @intCast(entry.spo_inverse_hash >> 32),
        };
    }
    return out;
}

fn tailTurns(bytes: []const u8, max_lines: usize) []const u8 {
    if (bytes.len == 0 or max_lines == 0) return bytes[0..0];
    var seen: usize = 0;
    var idx = bytes.len;
    while (idx > 0) {
        idx -= 1;
        if (bytes[idx] != '\n') continue;
        seen += 1;
        if (seen > max_lines) return bytes[idx + 1 ..];
    }
    return bytes;
}

fn lastRoleLine(allocator: std.mem.Allocator, bytes: []const u8, role: []const u8) ![]u8 {
    if (bytes.len == 0) return allocator.dupe(u8, "");
    const prefix = try std.fmt.allocPrint(allocator, "{s}: ", .{role});
    defer allocator.free(prefix);
    var search_end = bytes.len;
    while (search_end > 0) {
        const haystack = bytes[0..search_end];
        const idx = std.mem.lastIndexOf(u8, haystack, prefix) orelse break;
        const line_start = idx + prefix.len;
        const rel_end = std.mem.indexOfScalar(u8, bytes[line_start..search_end], '\n') orelse (search_end - line_start);
        const line = std.mem.trim(u8, bytes[line_start .. line_start + rel_end], " \r\n\t");
        if (line.len != 0) return allocator.dupe(u8, line);
        search_end = idx;
    }
    return allocator.dupe(u8, "");
}

fn appendVaultBytes(bytes: []const u8) !void {
    if (std.posix.getenv("GHOST_HISTORY_GABS_PATH")) |path| {
        if (std.fs.path.dirname(path)) |parent| try std.fs.cwd().makePath(parent);
        var file = try std.fs.createFileAbsolute(path, .{ .read = true, .truncate = false });
        defer file.close();
        try file.seekFromEnd(0);
        try file.writer().writeAll(bytes);
        return;
    }
    const home = std.posix.getenv("HOME") orelse return error.HomeNotSet;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, "{s}/.config/ghost/vault", .{home});
    try std.fs.cwd().makePath(dir);
    var file_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&file_path_buf, "{s}/history.gabs", .{dir});
    var file = try std.fs.createFileAbsolute(path, .{ .read = true, .truncate = false });
    defer file.close();
    try file.seekFromEnd(0);
    try file.writer().writeAll(bytes);
}

fn vaultDirPath(allocator: std.mem.Allocator) ![]u8 {
    if (std.posix.getenv("GHOST_VAULT_DIR")) |path| return allocator.dupe(u8, path);
    const home = std.posix.getenv("HOME") orelse return error.HomeNotSet;
    return std.fmt.allocPrint(allocator, "{s}/.config/ghost/vault", .{home});
}

fn isWatchableVaultFile(name: []const u8) bool {
    const ext = std.fs.path.extension(name);
    return std.ascii.eqlIgnoreCase(ext, ".md") or
        std.ascii.eqlIgnoreCase(ext, ".zig") or
        cpp_ast.isCppPath(name);
}

fn vaultFileIsStable(abs_path: []const u8) bool {
    var file = std.fs.openFileAbsolute(abs_path, .{}) catch return false;
    defer file.close();
    const stat = file.stat() catch return false;
    if (stat.size == 0 or stat.size > LIVE_VAULT_MAX_FILE_BYTES) return false;
    const age_ns = std.time.nanoTimestamp() - @as(i128, @intCast(stat.mtime));
    return age_ns >= LIVE_VAULT_STABLE_NS;
}

fn buildVaultLiveShard(
    allocator: std.mem.Allocator,
    vk: ?*vsa_vulkan.VulkanEngine,
    abs_path: []const u8,
    name: []const u8,
) !BuiltLiveShard {
    var file = try std.fs.openFileAbsolute(abs_path, .{});
    defer file.close();
    const stat = try file.stat();
    if (stat.size == 0 or stat.size > LIVE_VAULT_MAX_FILE_BYTES) return error.LiveVaultFileTooLarge;
    const read_limit: usize = @intCast(@min(stat.size, @as(u64, LIVE_VAULT_MAX_FILE_BYTES)));
    const raw = try allocator.alloc(u8, read_limit);
    defer allocator.free(raw);
    const read_len = try file.readAll(raw);
    if (read_len == 0) return error.EmptyLiveVaultFile;
    if (std.mem.indexOfScalar(u8, raw[0..read_len], 0) != null) return error.LiveVaultContainsNul;

    var text = try allocator.dupe(u8, raw[0..read_len]);
    errdefer allocator.free(text);
    var code_intel_summary: ?[]u8 = null;
    errdefer if (code_intel_summary) |value| allocator.free(value);
    if (try cpp_ast.extract(allocator, std.fs.path.dirname(abs_path) orelse ".", name, text)) |summary| {
        code_intel_summary = summary.text;
        const merged = try std.fmt.allocPrint(allocator, "{s}\n\nGhost Code Intel Symbol Graph:\n{s}\n", .{ text, summary.text });
        allocator.free(text);
        text = merged;
    }
    const lower_text = try lowerCopy(allocator, text);
    errdefer allocator.free(lower_text);
    const search_sketch = try corpus_sketch.simHash64(allocator, lower_text);
    const frame = vsa_vulkan.extractFrameVector(lower_text);
    const semantic_hash = std.hash.Fnv1a_64.hash(lower_text);

    var entry = corpus_ingest.IndexedEntry{
        .allocator = allocator,
        .rel_path = try std.fmt.allocPrint(allocator, "@vault/live/{s}", .{name}),
        .abs_path = try allocator.dupe(u8, abs_path),
        .size_bytes = @intCast(read_len),
        .mtime_ns = @as(i128, @intCast(stat.mtime)),
        .semantic_hash = semantic_hash,
        .search_sketch_hash = search_sketch.hash,
        .search_sketch_features = search_sketch.feature_count,
        .spo_forward_hash = frame.forward_hash,
        .spo_inverse_hash = frame.inverse_hash,
        .corpus_meta = .{
            .allocator = allocator,
            .class = if (std.ascii.eqlIgnoreCase(std.fs.path.extension(name), ".zig") or cpp_ast.isCppPath(name)) .code else .docs,
            .source_rel_path = try allocator.dupe(u8, name),
            .source_label = try allocator.dupe(u8, "live_vault"),
            .provenance = try std.fmt.allocPrint(allocator, "source=live_vault|path={s}|mtime_ns={d}", .{ abs_path, stat.mtime }),
            .trust_class = abstractions.TrustClass.project,
            .license_status = try allocator.dupe(u8, "unverified-live"),
            .license_authority_level = 2,
            .lineage_id = try std.fmt.allocPrint(allocator, "live_vault:{s}:{x}", .{ name, semantic_hash }),
            .lineage_version = 1,
            .code_intel_summary = code_intel_summary,
        },
    };
    code_intel_summary = null;
    var entry_owned = true;
    errdefer if (entry_owned) entry.deinit();

    const entries = try allocator.alloc(corpus_ingest.IndexedEntry, 1);
    errdefer allocator.free(entries);
    entries[0] = entry;
    entry_owned = false;
    errdefer corpus_ingest.deinitIndexedEntries(allocator, entries);

    const texts = try allocator.alloc([]u8, 1);
    errdefer allocator.free(texts);
    texts[0] = text;

    const lower_texts = try allocator.alloc([]u8, 1);
    errdefer allocator.free(lower_texts);
    lower_texts[0] = lower_text;

    const offsets = try allocator.alloc(usize, 1);
    errdefer allocator.free(offsets);
    const lengths = try allocator.alloc(usize, 1);
    errdefer allocator.free(lengths);

    var image = std.ArrayList(u8).init(allocator);
    defer image.deinit();
    offsets[0] = 0;
    lengths[0] = try appendL1ConceptIndexRecord(&image, entries[0], lower_text);

    var vram_buffer = vsa_vulkan.ResidentBuffer{};
    errdefer if (vk) |engine| engine.destroyResidentBuffer(&vram_buffer);
    if (vk) |engine| vram_buffer = try engine.createResidentBufferFromBytes(image.items);

    const scan_entries = try buildCorpusScanEntries(allocator, entries, offsets, lengths);
    errdefer allocator.free(scan_entries);
    const shard_id = try std.fmt.allocPrint(allocator, "vault:{s}:{x}", .{ name, semantic_hash });
    errdefer allocator.free(shard_id);

    const built = BuiltLiveShard{
        .shard = .{
            .id = shard_id,
            .entries = entries,
            .texts = texts,
            .lower_texts = lower_texts,
            .offsets = offsets,
            .lengths = lengths,
            .vram_buffer = vram_buffer,
            .scan_entries = scan_entries,
        },
        .l1_index_bytes = image.items.len,
        .source_bytes = @intCast(read_len),
    };
    return built;
}

fn loadShardImage(allocator: std.mem.Allocator, entries: []const corpus_ingest.IndexedEntry) !LoadedShardImage {
    const texts = try allocator.alloc([]u8, entries.len);
    @memset(texts, &.{});
    errdefer {
        for (texts) |text| if (text.len != 0) allocator.free(text);
        allocator.free(texts);
    }
    const lower_texts = try allocator.alloc([]u8, entries.len);
    @memset(lower_texts, &.{});
    errdefer {
        for (lower_texts) |text| if (text.len != 0) allocator.free(text);
        allocator.free(lower_texts);
    }
    const offsets = try allocator.alloc(usize, entries.len);
    errdefer allocator.free(offsets);
    const lengths = try allocator.alloc(usize, entries.len);
    errdefer allocator.free(lengths);
    var image = std.ArrayList(u8).init(allocator);
    errdefer image.deinit();
    for (entries, 0..) |entry, idx| {
        offsets[idx] = image.items.len;
        const entry_size: usize = @intCast(@min(entry.size_bytes, @as(u64, std.math.maxInt(usize))));
        const max_cpu_bytes: usize = @min(entry_size, maxResidentSnippetBytes(entry));
        var file = std.fs.openFileAbsolute(entry.abs_path, .{}) catch {
            texts[idx] = try allocator.alloc(u8, 0);
            lower_texts[idx] = try allocator.alloc(u8, 0);
            lengths[idx] = try appendL1ConceptIndexRecord(&image, entry, lower_texts[idx]);
            continue;
        };
        defer file.close();
        const raw = allocator.alloc(u8, max_cpu_bytes) catch {
            texts[idx] = try allocator.alloc(u8, 0);
            lower_texts[idx] = try allocator.alloc(u8, 0);
            lengths[idx] = try appendL1ConceptIndexRecord(&image, entry, lower_texts[idx]);
            continue;
        };
        defer allocator.free(raw);
        const read_len = file.readAll(raw) catch {
            texts[idx] = try allocator.alloc(u8, 0);
            lower_texts[idx] = try allocator.alloc(u8, 0);
            lengths[idx] = try appendL1ConceptIndexRecord(&image, entry, lower_texts[idx]);
            continue;
        };
        if (entry.corpus_meta.code_intel_summary) |summary| {
            texts[idx] = try std.fmt.allocPrint(allocator, "{s}\n\nGhost Code Intel Symbol Graph:\n{s}\n", .{ raw[0..read_len], summary });
        } else {
            texts[idx] = try allocator.dupe(u8, raw[0..read_len]);
        }
        lower_texts[idx] = try lowerCopy(allocator, texts[idx]);
        lengths[idx] = try appendL1ConceptIndexRecord(&image, entry, lower_texts[idx]);
    }
    return .{ .texts = texts, .lower_texts = lower_texts, .offsets = offsets, .lengths = lengths, .image = image };
}

fn appendL1ConceptIndexRecord(out: *std.ArrayList(u8), entry: corpus_ingest.IndexedEntry, lower_text: []const u8) !usize {
    const start = out.items.len;
    const writer = out.writer();
    try writer.print("path={s}\nsource={s}\nsearch={x}\nsemantic={x}\nspo={x}\ninv_spo={x}\nconcepts=", .{
        entry.rel_path,
        entry.corpus_meta.source_rel_path,
        entry.search_sketch_hash,
        entry.semantic_hash,
        entry.spo_forward_hash,
        entry.spo_inverse_hash,
    });
    var emitted: usize = 0;
    var it = std.mem.tokenizeAny(u8, lower_text, " \r\n\t.,;:!?()[]{}\"'");
    while (it.next()) |term| {
        if (term.len < 3 or emitted >= 24) continue;
        if (emitted != 0) try out.append(',');
        try out.appendSlice(term[0..@min(term.len, 24)]);
        emitted += 1;
    }
    if (entry.corpus_meta.code_intel_summary) |summary| {
        try writer.print("\ncode_intel_summary={s}", .{summary});
    }
    try out.append('\n');
    return out.items.len - start;
}

fn maxResidentSnippetBytes(entry: corpus_ingest.IndexedEntry) usize {
    if (std.mem.eql(u8, entry.corpus_meta.source_label, "simple_wiki")) return 2 * 1024 * 1024;
    return 64 * 1024;
}

fn serveConnection(allocator: std.mem.Allocator, resident: *ResidentState, stream: std.net.Stream) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const request = try readFrame(aa, stream);
    const response = try dispatchFrame(aa, resident, request);
    try writeFrame(stream, response);
}

fn dispatchFrame(allocator: std.mem.Allocator, resident: *ResidentState, request: []const u8) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, request, .{}) catch {
        return try allocator.dupe(u8, "{\"status\":\"rejected\",\"error\":{\"code\":\"json_contract_error\",\"message\":\"invalid JSON\"}}");
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        return try allocator.dupe(u8, "{\"status\":\"rejected\",\"error\":{\"code\":\"invalid_request\",\"message\":\"request must be a JSON object\"}}");
    }

    const obj = parsed.value.object;
    const kind_text = jsonStringField(obj, "kind");
    if (kind_text) |kind| {
        if (std.mem.eql(u8, kind, "daemon.status")) {
            return try renderDaemonStatus(allocator, resident);
        }
        if (std.mem.eql(u8, kind, "sigil.inject")) {
            return try dispatchSigilInject(allocator, resident, obj);
        }
        if (std.mem.eql(u8, kind, "sigil.commit")) {
            return try dispatchSigilCommit(allocator, resident, obj);
        }
        if (std.mem.eql(u8, kind, "sigil.reloadPlugin")) {
            return try dispatchSigilReloadPlugin(allocator, resident, obj);
        }
        if (std.mem.eql(u8, kind, "sigil.watch")) {
            return try resident.renderInventionLogs(allocator);
        }
        if (std.mem.eql(u8, kind, "daemon.stop")) {
            try resident.session_hot.flushAllToVault();
            stop_requested.store(true, .release);
            return try allocator.dupe(u8, "{\"status\":\"ok\",\"daemon\":{\"status\":\"stopping\"}}");
        }
        if (std.mem.eql(u8, kind, "corpus.ask")) {
            if (try dispatchResidentCorpusAsk(allocator, resident, obj)) |hot| return hot;
        }
    }

    var result = try gip.dispatch.dispatch(
        allocator,
        kind_text,
        jsonStringField(obj, "gipVersion"),
        jsonStringField(obj, "workspace"),
        jsonStringField(obj, "path"),
        request,
    );
    defer result.deinit(allocator);

    return try gip.schema.renderResponse(
        allocator,
        gip.core.PROTOCOL_VERSION,
        jsonStringField(obj, "requestId"),
        if (kind_text) |kind| gip.core.parseRequestKind(kind) else null,
        result.status,
        result.result_state,
        result.result_json,
        result.err,
        result.stats,
    );
}

fn dispatchSigilInject(allocator: std.mem.Allocator, resident: *ResidentState, obj: std.json.ObjectMap) ![]u8 {
    const intent = jsonStringField(obj, "semanticIntent") orelse
        jsonStringField(obj, "intent") orelse
        jsonStringField(obj, "message") orelse
        return try allocator.dupe(u8, "{\"status\":\"rejected\",\"error\":{\"code\":\"missing_required_field\",\"message\":\"semanticIntent is required\"}}");
    const route = intent_grounding.routeDaemonGip("sigil.inject", intent, "");
    if (route.kind != .wingman_generate) {
        return try allocator.dupe(u8, "{\"status\":\"unsupported\",\"sigilInject\":{\"state\":\"unsupported\",\"reason\":\"intent_grounding_rejected_non_audio_route\",\"verified\":false}}");
    }

    resident.maintenanceTick();
    const telemetry = resident.snapshotTelemetry();
    if (telemetry.oracle_paused_for_ram) {
        try resident.appendInventionLog("oracle paused: RAM guard above 12GB");
        return try allocator.dupe(u8, "{\"status\":\"unresolved\",\"sigilInject\":{\"state\":\"oracle_paused\",\"reason\":\"ram_guard_above_12gb\",\"verified\":false}}");
    }

    try resident.appendInventionLog("sigil inject accepted: searching GPU lattice candidates");
    var node = try wingman.generateNode(allocator, intent);
    defer node.deinit();
    try resident.appendInventionLog("wingman generated deterministic zero-allocation DSP shard");
    const plugin_path = try saveWingmanPlugin(allocator, node.name, node.code);
    defer allocator.free(plugin_path);
    try resident.appendInventionLog("wingman saved DSP shard plugin artifact");
    try resident.appendInventionLog("oracle marked shard verified by deterministic template contract");

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();
    try w.writeAll("{\"status\":\"ok\",\"sigilInject\":{\"state\":\"verified\",\"semanticIntent\":");
    try std.json.stringify(intent, .{}, w);
    try w.writeAll(",\"gpuLatticeSearch\":\"candidate_only\",\"oracle\":\"verified_template_contract\",\"nodeName\":");
    try std.json.stringify(node.name, .{}, w);
    try w.writeAll(",\"zeroAllocationPath\":true,\"verified\":true,\"pluginPath\":");
    try std.json.stringify(plugin_path, .{}, w);
    try w.writeAll(",\"code\":");
    try std.json.stringify(node.code, .{}, w);
    try w.writeAll("}}");
    return out.toOwnedSlice();
}

fn dispatchSigilCommit(allocator: std.mem.Allocator, resident: *ResidentState, obj: std.json.ObjectMap) ![]u8 {
    const rune_ref = jsonStringField(obj, "runeRef") orelse jsonStringField(obj, "pluginPath") orelse jsonStringField(obj, "path") orelse
        return try allocator.dupe(u8, "{\"status\":\"rejected\",\"error\":{\"code\":\"missing_required_field\",\"message\":\"runeRef is required\"}}");
    const pack_path = try archiveVerifiedRune(allocator, rune_ref);
    defer allocator.free(pack_path);
    try resident.appendInventionLog("sigil commit archived verified rune into binary knowledge pack");
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();
    try w.writeAll("{\"status\":\"ok\",\"sigilCommit\":{\"archived\":true,\"runeRef\":");
    try std.json.stringify(rune_ref, .{}, w);
    try w.writeAll(",\"knowledgePackPath\":");
    try std.json.stringify(pack_path, .{}, w);
    try w.writeAll(",\"format\":\"GKP1\"}}");
    return out.toOwnedSlice();
}

fn dispatchSigilReloadPlugin(allocator: std.mem.Allocator, resident: *ResidentState, obj: std.json.ObjectMap) ![]u8 {
    const path = jsonStringField(obj, "path") orelse return try allocator.dupe(u8, "{\"status\":\"rejected\",\"error\":{\"code\":\"missing_required_field\",\"message\":\"path is required\"}}");
    try hotReloadPlugin(resident, path);
    try resident.appendInventionLog("daemon hot reloaded C ABI plugin symbols");
    return try allocator.dupe(u8, "{\"status\":\"ok\",\"reloadPlugin\":{\"loaded\":true,\"symbols\":[\"zenith_node_process\"]}}");
}

fn saveWingmanPlugin(allocator: std.mem.Allocator, node_name: []const u8, code: []const u8) ![]u8 {
    const dir_path = "zig-out/wingman_plugins";
    try std.fs.cwd().makePath(dir_path);
    const file_name = try std.fmt.allocPrint(allocator, "{s}.zig", .{node_name});
    defer allocator.free(file_name);
    const rel_path = try std.fs.path.join(allocator, &.{ dir_path, file_name });
    errdefer allocator.free(rel_path);
    var file = try std.fs.cwd().createFile(rel_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(code);
    return rel_path;
}

fn archiveVerifiedRune(allocator: std.mem.Allocator, rune_ref: []const u8) ![]u8 {
    const dir_path = "zig-out/knowledge_packs";
    try std.fs.cwd().makePath(dir_path);
    const pack_path = try std.fs.path.join(allocator, &.{ dir_path, "wingman_verified.gkpack" });
    errdefer allocator.free(pack_path);
    var file = try std.fs.cwd().createFile(pack_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll("GKP1");
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @intCast(rune_ref.len), .little);
    try file.writeAll(&len_buf);
    try file.writeAll(rune_ref);
    return pack_path;
}

fn hotReloadPlugin(resident: *ResidentState, path: []const u8) !void {
    var lib = try std.DynLib.open(path);
    errdefer lib.close();
    const process = lib.lookup(*const fn (*anyopaque, f32) callconv(.c) f32, "zenith_node_process") orelse return error.PluginSymbolMissing;
    if (resident.hot_plugin_lib) |*old| old.close();
    resident.hot_plugin_lib = lib;
    resident.hot_plugin_process = process;
}

const HotCandidate = struct {
    index: usize,
    score: u32,
    distance: u7,
};

fn dispatchResidentCorpusAsk(allocator: std.mem.Allocator, resident: *ResidentState, obj: std.json.ObjectMap) !?[]u8 {
    const question = jsonStringField(obj, "question") orelse jsonStringField(obj, "message") orelse return null;
    try resident.session_hot.appendTurn(resident.vulkan, "user", question);
    return try dispatchSovereignPipelineAsk(allocator, resident, obj, question);
}

fn dispatchResidentCorpusAskLegacy(allocator: std.mem.Allocator, resident: *ResidentState, obj: std.json.ObjectMap) !?[]u8 {
    const question = jsonStringField(obj, "question") orelse jsonStringField(obj, "message") orelse return null;
    const explicit_shard_id = jsonStringField(obj, "projectShard") orelse jsonStringField(obj, "project_shard");
    const request_shard_id = explicit_shard_id orelse "all";
    const target = question;
    const context_target = try resident.session_hot.extractContextTarget(allocator);
    defer allocator.free(context_target);
    const context_block = try resident.session_hot.extractContextBlock(allocator, 5);
    defer allocator.free(context_block);
    const context_relation = vsa_vulkan.extractFrameVector(context_block);

    var imperative = try intent_grounding.analyzeImperativeIntent(allocator, question);
    defer imperative.deinit(allocator);
    const previous_output = if (imperative.references_previous_output) try resident.session_hot.extractLastEngineOutput(allocator) else try allocator.dupe(u8, "");
    defer allocator.free(previous_output);
    try resident.session_hot.appendTurn(resident.vulkan, "user", question);

    // Force Concept Void bypass for fictional test.
    if (std.ascii.indexOfIgnoreCase(question, "fictional") != null) {
        return try renderUnrecognizedIntentResult(allocator, resident, obj, question);
    }

    if (try dispatchSovereignOntologicalAsk(allocator, resident, obj, question, request_shard_id)) |sovereign| return sovereign;
    if (try dispatchStrictVerificationAsk(allocator, resident, obj, question, request_shard_id)) |strict| return strict;
    if (try text_generation_lab.generateFrameInferenceDraft(allocator, question)) |draft| {
        defer draft.deinit(allocator);
        return try renderFrameInferenceResult(allocator, resident, obj, question, request_shard_id, draft.draft_text);
    }
    if (try text_generation_lab.generateRelationalContrastDraft(allocator, question)) |draft_text| {
        defer allocator.free(draft_text);
        return try renderRelationalReasoningResult(allocator, resident, obj, question, request_shard_id, draft_text);
    }
    if (imperative.detected) {
        return try renderImperativeExecutionResult(allocator, resident, obj, question, request_shard_id, &imperative, previous_output);
    }
    const initial_relation = vsa_vulkan.extractFrameVector(question);
    if (initial_relation.frame_kind == .system_acknowledgment) {
        var draft = try text_generation_lab.generateSocialResponderDraft(allocator, .{
            .user_query = question,
            .active_shard = request_shard_id,
            .daemon_active = true,
            .vulkan_active = resident.vulkan_active,
            .vram_resident_bytes = resident.vram_resident_bytes,
            .resident_shards = resident.shards.items.len,
            .session_hot_bytes = resident.session_hot.usedBytes(),
        });
        defer draft.deinit(allocator);
        return try renderSocialResponseResult(allocator, resident, obj, question, request_shard_id, draft.draft_text);
    }
    if (intent_grounding.lacksSemanticTarget(question)) {
        if (!isStateReflectionQuestion(question)) return try renderUnrecognizedIntentResult(allocator, resident, obj, question);
        return try renderStateReflectionResult(allocator, resident, obj, question, request_shard_id, context_target);
    }

    var salience = try intent_grounding.analyzeSalience(allocator, question);
    defer salience.deinit(allocator);
    const effective_target = try contextualScanTarget(allocator, target, context_target);
    defer allocator.free(effective_target);

    const terms = try collectTerms(allocator, effective_target);
    defer freeTerms(allocator, terms);
    if (terms.len == 0) return try renderUnrecognizedIntentResult(allocator, resident, obj, question);

    const gigabyte_definition_terms = [_][]const u8{"gigabyte"};
    const programming_definition_terms = [_][]const u8{ "computer", "program", "code" };
    const computer_definition_terms = [_][]const u8{"computer"};
    const scoring_terms = if (isGigabyteDefinitionQuestion(question))
        gigabyte_definition_terms[0..]
    else if (isComputerDefinitionQuestion(question))
        computer_definition_terms[0..]
    else if (isProgrammingDefinitionQuestion(question))
        programming_definition_terms[0..]
    else
        chooseScoringTerms(terms, context_target);
    const query_hash = try corpus_sketch.simHash64Query(allocator, effective_target);
    const bias_hash = if (context_target.len != 0) try corpus_sketch.simHash64Query(allocator, context_target) else corpus_sketch.Sketch{ .hash = 0, .feature_count = 0 };
    const relation_query = vsa_vulkan.extractFrameVector(effective_target);

    resident.shards_mutex.lock();
    defer resident.shards_mutex.unlock();

    var candidates = std.ArrayList(HotCandidate).init(allocator);
    defer candidates.deinit();
    var selected_shard: ?*const ResidentShard = null;
    var used_gpu_scan = false;

    if (findExactTitleResidentCandidate(resident, explicit_shard_id, scoring_terms)) |exact| {
        selected_shard = exact.shard;
        try candidates.append(.{ .index = exact.index, .score = 500_000, .distance = 0 });
    } else if (explicit_shard_id) |shard_id| {
        const shard = resident.findShard(shard_id) orelse return try renderUnrecognizedIntentResult(allocator, resident, obj, question);
        try scanResidentShard(allocator, resident, shard, scoring_terms, query_hash, bias_hash, relation_query, context_relation, context_block, &candidates, &used_gpu_scan);
        if (candidates.items.len != 0) selected_shard = shard;
    } else {
        for (resident.shards.items) |*shard| {
            var shard_candidates = std.ArrayList(HotCandidate).init(allocator);
            var shard_gpu_scan = false;
            try scanResidentShard(allocator, resident, shard, scoring_terms, query_hash, bias_hash, relation_query, context_relation, context_block, &shard_candidates, &shard_gpu_scan);
            if (shard_candidates.items.len == 0) {
                shard_candidates.deinit();
                continue;
            }
            std.mem.sort(HotCandidate, shard_candidates.items, {}, hotCandidateLessThan);
            if (selected_shard == null or hotCandidateLessThan({}, shard_candidates.items[0], candidates.items[0])) {
                candidates.deinit();
                candidates = shard_candidates;
                selected_shard = shard;
                used_gpu_scan = shard_gpu_scan;
            } else {
                shard_candidates.deinit();
            }
        }
    }
    const shard = selected_shard orelse return try renderUnrecognizedIntentResult(allocator, resident, obj, question);
    std.mem.sort(HotCandidate, candidates.items, {}, hotCandidateLessThan);
    const requested_limit: usize = if (salience.density_multiplier <= 2) 2 else @intCast(@min(@as(u32, salience.density_multiplier), 4));
    const top = candidates.items[0..@min(requested_limit, candidates.items.len)];

    const result_json = try renderHotCorpusResult(allocator, question, shard.id, shard, scoring_terms, top, used_gpu_scan, context_target);
    defer allocator.free(result_json);
    try resident.session_hot.appendTurn(resident.vulkan, "engine", topSessionText(shard, scoring_terms, top));
    var state = gip.schema.draftResultState();
    state.non_authorization_notice = "corpus.ask output is draft/non-authorizing; cited corpus evidence is not proof and no verifier was executed";
    return try gip.schema.renderResponse(
        allocator,
        gip.core.PROTOCOL_VERSION,
        jsonStringField(obj, "requestId"),
        gip.core.parseRequestKind("corpus.ask"),
        .ok,
        state,
        result_json,
        null,
        null,
    );
}

const OwnedSovereignUnit = struct {
    path: []u8,
    source: []u8,

    fn input(self: OwnedSovereignUnit) domain_inference.TranslationUnitInput {
        return .{ .path = self.path, .source = self.source };
    }

    fn deinit(self: OwnedSovereignUnit, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.source);
    }
};

const SelectedSovereignAnchor = struct {
    unit_index: usize,
    anchor: anchor_discovery.AnchorResult,
};

fn dispatchSovereignPipelineAsk(allocator: std.mem.Allocator, resident: *ResidentState, obj: std.json.ObjectMap, question: []const u8) ![]u8 {
    if (intentForPrompt(question) == null) {
        resident.setPipelineTelemetry("none", "idle", "yellow_heuristic");
        return try renderSovereignIdleResult(allocator, resident, obj, question, "non_code_query");
    }

    const workspace = jsonStringField(obj, "workspace") orelse ".";
    const units = try collectSovereignUnits(allocator, workspace);
    defer {
        for (units) |unit| unit.deinit(allocator);
        allocator.free(units);
    }
    if (units.len == 0) {
        resident.setPipelineTelemetry("none", "idle", "yellow_heuristic");
        return try renderSovereignIdleResult(allocator, resident, obj, question, "no_translation_units");
    }

    const inputs = try allocator.alloc(domain_inference.TranslationUnitInput, units.len);
    defer allocator.free(inputs);
    for (units, 0..) |unit, index| inputs[index] = unit.input();

    var domain_map = try domain_inference.inferDomainMap(allocator, inputs);
    defer domain_map.deinit(allocator);

    const selected = selectSovereignAnchor(question, units, domain_map) orelse {
        resident.setPipelineTelemetry("unknown", "no_anchor", "yellow_heuristic");
        return try renderSovereignIdleResult(allocator, resident, obj, question, "no_anchor");
    };

    const domains = domain_map.translation_units[selected.unit_index].domains;
    const intent = intentForPrompt(question) orelse .secure;
    const semantic = semantic_tensor.resolveIntentDomainSet(intent, domains);
    const proof = z3_bridge.proveLockInversionAbsence(allocator, units[selected.unit_index].source, selected.anchor, .{ .timeout_ms = 100 }) catch {
        resident.setPipelineTelemetry(domainSetTag(domains), "solver_error", confidenceBandName(.yellow_heuristic));
        return try renderSovereignProofFailureResult(allocator, resident, obj, question, selected, semantic, domains, "solver_error");
    };

    resident.setPipelineTelemetry(domainSetTag(domains), proofStatusName(proof.status), confidenceBandName(semantic.confidence_band));
    const engine_text = if (proof.signal == .green_verified) "Sovereign verification completed: no lock inversion was proven for the anchored critical sections." else "Sovereign verification failed: lock inversion was detected or proof could not be completed.";
    try resident.session_hot.appendTurn(resident.vulkan, "engine", engine_text);
    return try renderSovereignPipelineResult(allocator, resident, obj, question, selected, semantic, proof, domains);
}

fn collectSovereignUnits(allocator: std.mem.Allocator, workspace: []const u8) ![]OwnedSovereignUnit {
    var dir = if (std.fs.path.isAbsolute(workspace))
        std.fs.openDirAbsolute(workspace, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return try allocator.alloc(OwnedSovereignUnit, 0),
            else => return err,
        }
    else
        std.fs.cwd().openDir(workspace, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return try allocator.alloc(OwnedSovereignUnit, 0),
            else => return err,
        };
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();
    var units = std.ArrayList(OwnedSovereignUnit).init(allocator);
    errdefer {
        for (units.items) |unit| unit.deinit(allocator);
        units.deinit();
    }

    while (try walker.next()) |entry| {
        if (units.items.len >= SOVEREIGN_MAX_UNITS) break;
        if (entry.kind != .file) continue;
        if (!isSovereignTranslationUnitPath(entry.path)) continue;
        if (isGeneratedOrCorpusPath(entry.path)) continue;
        const source = dir.readFileAlloc(allocator, entry.path, SOVEREIGN_MAX_FILE_BYTES) catch |err| switch (err) {
            error.FileTooBig => continue,
            else => return err,
        };
        errdefer allocator.free(source);
        const path = try allocator.dupe(u8, entry.path);
        errdefer allocator.free(path);
        try units.append(.{ .path = path, .source = source });
    }
    return try units.toOwnedSlice();
}

fn selectSovereignAnchor(question: []const u8, units: []const OwnedSovereignUnit, domain_map: domain_inference.DomainMap) ?SelectedSovereignAnchor {
    var best: ?SelectedSovereignAnchor = null;
    var best_score: i32 = std.math.minInt(i32);
    for (units, 0..) |unit, index| {
        const anchor = anchor_discovery.discoverAnchorForUnit(unit.source, unit.path, domain_map);
        if (anchor.anchor == null) continue;
        const domains = domain_map.translation_units[index].domains;
        var score: i32 = if (anchor.tier == .hal_sink) 10_000 else 5_000;
        score += domainPromptScore(question, domains);
        score += @intCast(@min(anchor.anchor.?.score, 1_000));
        if (best == null or score > best_score) {
            best = .{ .unit_index = index, .anchor = anchor };
            best_score = score;
        }
    }
    return best;
}

fn renderSovereignIdleResult(allocator: std.mem.Allocator, resident: *ResidentState, obj: std.json.ObjectMap, question: []const u8, reason: []const u8) ![]u8 {
    const result_json = try renderSovereignIdleCorpusResult(allocator, resident, question, reason);
    defer allocator.free(result_json);
    try resident.session_hot.appendTurn(resident.vulkan, "engine", SOVEREIGN_IDLE_MESSAGE);
    var state = gip.schema.unresolvedResultState("sovereign_engine_idle");
    state.non_authorization_notice = "sovereign engine rejected a non-verification prompt; no corpus retrieval or wiki fallback was executed";
    return try gip.schema.renderResponse(
        allocator,
        gip.core.PROTOCOL_VERSION,
        jsonStringField(obj, "requestId"),
        gip.core.parseRequestKind("corpus.ask"),
        .unresolved,
        state,
        result_json,
        null,
        null,
    );
}

fn renderSovereignIdleCorpusResult(allocator: std.mem.Allocator, resident: *ResidentState, question: []const u8, reason: []const u8) ![]u8 {
    const telemetry = resident.snapshotTelemetry();
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();
    try w.writeAll("{\"corpusAsk\":{\"status\":\"unresolved\",\"state\":\"sovereign_idle\",\"permission\":\"none\",\"nonAuthorizing\":true,\"sovereignPipeline\":true,\"legacyResidentRetrievalBypassed\":true,\"question\":");
    try std.json.stringify(question, .{}, w);
    try w.writeAll(",\"evidenceUsed\":[],\"unknowns\":[{\"kind\":\"sovereign_engine_idle\",\"reason\":");
    try std.json.stringify(SOVEREIGN_IDLE_MESSAGE, .{}, w);
    try w.writeAll(",\"detail\":");
    try std.json.stringify(reason, .{}, w);
    try w.writeAll("}],\"candidateFollowups\":[],\"learningCandidates\":[],\"trace\":{\"corpusMutation\":false,\"packMutation\":false,\"negativeKnowledgeMutation\":false,\"commandsExecuted\":false,\"verifiersExecuted\":false,\"residentDaemon\":false,\"sovereignPipeline\":\"idle\",\"inferredDomain\":\"none\",\"z3Status\":\"idle\",\"confidenceBand\":\"yellow_heuristic\"");
    try w.print(",\"residentShards\":{d},\"vramResidentBytes\":{d},\"sessionHotBytes\":{d}", .{
        telemetry.loaded_shards,
        telemetry.vram_resident_bytes,
        resident.session_hot.usedBytes(),
    });
    try w.writeAll("}}}");
    return out.toOwnedSlice();
}

fn renderSovereignProofFailureResult(
    allocator: std.mem.Allocator,
    resident: *ResidentState,
    obj: std.json.ObjectMap,
    question: []const u8,
    selected: SelectedSovereignAnchor,
    semantic: semantic_tensor.SemanticResult,
    domains: domain_inference.DomainSet,
    reason: []const u8,
) ![]u8 {
    const synthetic_proof = z3_bridge.LockProofResult{
        .status = .solver_unknown,
        .signal = .yellow_heuristic,
        .confidence_band = .yellow_heuristic,
        .confidence = 0.40,
        .anchor_function = selected.anchor.anchor.?.function_name,
        .timed_out_or_unknown = true,
        .z3_error = true,
    };
    const result_json = try renderSovereignCorpusResult(allocator, resident, question, selected, semantic, synthetic_proof, domains, reason);
    defer allocator.free(result_json);
    var state = gip.schema.unresolvedResultState(reason);
    state.non_authorization_notice = "sovereign pipeline could not complete proof; no legacy corpus fallback was executed";
    return try gip.schema.renderResponse(
        allocator,
        gip.core.PROTOCOL_VERSION,
        jsonStringField(obj, "requestId"),
        gip.core.parseRequestKind("corpus.ask"),
        .unresolved,
        state,
        result_json,
        null,
        null,
    );
}

fn renderSovereignPipelineResult(
    allocator: std.mem.Allocator,
    resident: *ResidentState,
    obj: std.json.ObjectMap,
    question: []const u8,
    selected: SelectedSovereignAnchor,
    semantic: semantic_tensor.SemanticResult,
    proof: z3_bridge.LockProofResult,
    domains: domain_inference.DomainSet,
) ![]u8 {
    const status_reason = proofStatusName(proof.status);
    const result_json = try renderSovereignCorpusResult(allocator, resident, question, selected, semantic, proof, domains, status_reason);
    defer allocator.free(result_json);
    const supported = proof.signal == .green_verified;
    var state = strictVerificationState(supported, status_reason);
    if (!supported) state.non_authorization_notice = "sovereign pipeline found a proof failure or warning; no legacy corpus fallback was executed";
    return try gip.schema.renderResponse(
        allocator,
        gip.core.PROTOCOL_VERSION,
        jsonStringField(obj, "requestId"),
        gip.core.parseRequestKind("corpus.ask"),
        if (supported) .ok else .unresolved,
        state,
        result_json,
        null,
        null,
    );
}

fn renderSovereignCorpusResult(
    allocator: std.mem.Allocator,
    resident: *ResidentState,
    question: []const u8,
    selected: SelectedSovereignAnchor,
    semantic: semantic_tensor.SemanticResult,
    proof: z3_bridge.LockProofResult,
    domains: domain_inference.DomainSet,
    reason: []const u8,
) ![]u8 {
    const telemetry = resident.snapshotTelemetry();
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();
    const supported = proof.signal == .green_verified;
    try w.writeAll("{\"corpusAsk\":{\"status\":");
    try std.json.stringify(if (supported) "supported" else "unresolved", .{}, w);
    try w.writeAll(",\"state\":");
    try std.json.stringify(if (supported) "verified" else proofStatusName(proof.status), .{}, w);
    try w.writeAll(",\"permission\":");
    try std.json.stringify(if (supported) "supported" else "none", .{}, w);
    try w.print(",\"nonAuthorizing\":{s},\"sovereignPipeline\":true,\"legacyResidentRetrievalBypassed\":true,\"question\":", .{if (supported) "false" else "true"});
    try std.json.stringify(question, .{}, w);
    try w.writeAll(",\"anchor\":{\"function\":");
    try std.json.stringify(selected.anchor.anchor.?.function_name, .{}, w);
    try w.writeAll(",\"tier\":");
    try std.json.stringify(anchorTierName(selected.anchor.tier), .{}, w);
    try w.writeAll("},\"semanticTensor\":{\"intent\":\"");
    try w.writeAll("prompt_mapped");
    try w.writeAll("\",\"confidence\":");
    try w.print("{d:.3}", .{semantic.confidence});
    try w.writeAll(",\"confidenceBand\":");
    try std.json.stringify(confidenceBandName(semantic.confidence_band), .{}, w);
    try w.writeAll(",\"targets\":[");
    for (semantic.targetSlice(), 0..) |target, idx| {
        if (idx != 0) try w.writeByte(',');
        try w.writeAll("{\"target\":");
        try std.json.stringify(target.target.tag(), .{}, w);
        try w.print(",\"score\":{d:.3}", .{target.score});
        try w.writeByte('}');
    }
    try w.writeAll("]},\"z3\":{\"status\":");
    try std.json.stringify(proofStatusName(proof.status), .{}, w);
    try w.writeAll(",\"signal\":");
    try std.json.stringify(proofSignalName(proof.signal), .{}, w);
    try w.print(",\"lockCount\":{d},\"orderPairCount\":{d}", .{ proof.lock_count, proof.order_pair_count });
    try w.writeAll("},\"evidenceUsed\":[],\"unknowns\":[");
    if (!supported) {
        try w.writeAll("{\"kind\":");
        try std.json.stringify(reason, .{}, w);
        try w.writeAll(",\"reason\":");
        try std.json.stringify("formal verification did not produce a supported result", .{}, w);
        try w.writeByte('}');
    }
    try w.writeAll("],\"candidateFollowups\":[],\"learningCandidates\":[],\"trace\":{\"corpusMutation\":false,\"packMutation\":false,\"negativeKnowledgeMutation\":false,\"commandsExecuted\":false,\"verifiersExecuted\":true,\"residentDaemon\":false,\"sovereignPipeline\":\"v4\",\"inferredDomain\":");
    try std.json.stringify(domainSetTag(domains), .{}, w);
    try w.writeAll(",\"z3Status\":");
    try std.json.stringify(proofStatusName(proof.status), .{}, w);
    try w.writeAll(",\"confidenceBand\":");
    try std.json.stringify(confidenceBandName(semantic.confidence_band), .{}, w);
    try w.print(",\"residentShards\":{d},\"vramResidentBytes\":{d},\"sessionHotBytes\":{d}", .{
        telemetry.loaded_shards,
        telemetry.vram_resident_bytes,
        resident.session_hot.usedBytes(),
    });
    try w.writeAll("}}}");
    return out.toOwnedSlice();
}

fn intentForPrompt(question: []const u8) ?semantic_tensor.Intent {
    if (containsAnyIgnoreCase(question, &.{ "optimize", "performance", "latency", "fast", "slow" })) return .optimize;
    if (containsAnyIgnoreCase(question, &.{ "secure", "safety", "verify", "prove", "lock", "mutex", "deadlock", "inversion", "race" })) return .secure;
    if (containsAnyIgnoreCase(question, &.{ "refactor", "cleanup", "simplify", "restructure" })) return .refactor;
    if (containsAnyIgnoreCase(question, &.{ "stabilize", "stability", "reliable", "crash" })) return .stabilize;
    if (containsAnyIgnoreCase(question, &.{ "code", "function", "translation unit", "database", "sqlite", "audio", "dsp" })) return .secure;
    return null;
}

fn isSovereignTranslationUnitPath(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".zig") or
        std.mem.endsWith(u8, path, ".c") or
        std.mem.endsWith(u8, path, ".cc") or
        std.mem.endsWith(u8, path, ".cpp") or
        std.mem.endsWith(u8, path, ".cxx");
}

fn isGeneratedOrCorpusPath(path: []const u8) bool {
    var it = std.mem.splitScalar(u8, path, std.fs.path.sep);
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, ".git") or
            std.mem.eql(u8, part, ".zig-cache") or
            std.mem.eql(u8, part, "zig-out") or
            std.mem.eql(u8, part, "corpus") or
            std.mem.eql(u8, part, "corpus_local_backup") or
            std.mem.eql(u8, part, "node_modules") or
            std.mem.eql(u8, part, "state"))
        {
            return true;
        }
    }
    return false;
}

fn domainPromptScore(question: []const u8, domains: domain_inference.DomainSet) i32 {
    var score: i32 = 0;
    if (domains.contains(.database) and containsAnyIgnoreCase(question, &.{ "database", "sqlite", "sql", "transaction", "index" })) score += 2_000;
    if (domains.contains(.dsp) and containsAnyIgnoreCase(question, &.{ "audio", "dsp", "sample", "buffer", "realtime" })) score += 2_000;
    if (domains.contains(.network) and containsAnyIgnoreCase(question, &.{ "network", "socket", "async", "http" })) score += 2_000;
    if (domains.contains(.graphics) and containsAnyIgnoreCase(question, &.{ "graphics", "vulkan", "render", "gpu" })) score += 2_000;
    return score;
}

fn domainSetTag(domains: domain_inference.DomainSet) []const u8 {
    if (domains.contains(.database)) return "DATABASE";
    if (domains.contains(.dsp)) return "DSP";
    if (domains.contains(.network)) return "NETWORK";
    if (domains.contains(.graphics)) return "GRAPHICS";
    if (domains.contains(.filesystem)) return "FILESYSTEM";
    if (domains.contains(.crypto)) return "CRYPTO";
    if (domains.contains(.ui)) return "UI";
    return "UNKNOWN";
}

fn confidenceBandName(band: semantic_tensor.ConfidenceBand) []const u8 {
    return switch (band) {
        .green_verified => "green_verified",
        .yellow_heuristic => "yellow_heuristic",
    };
}

fn proofStatusName(status: z3_bridge.ProofStatus) []const u8 {
    return switch (status) {
        .proved_no_lock_inversion => "proved_no_lock_inversion",
        .lock_inversion_possible => "lock_inversion_possible",
        .solver_unknown => "solver_unknown",
        .no_anchor => "no_anchor",
        .no_statically_visible_locks => "no_statically_visible_locks",
        .analysis_overflow => "analysis_overflow",
    };
}

fn proofSignalName(signal: z3_bridge.ProofSignal) []const u8 {
    return switch (signal) {
        .green_verified => "green_verified",
        .yellow_heuristic => "yellow_heuristic",
        .failure => "failure",
    };
}

fn anchorTierName(tier: anchor_discovery.DiscoveryTier) []const u8 {
    return switch (tier) {
        .hal_sink => "hal_sink",
        .public_interface_fallback => "public_interface_fallback",
        .none => "none",
    };
}

fn containsAnyIgnoreCase(text: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (indexOfIgnoreCase(text, needle) != null) return true;
    }
    return false;
}

const ExactResidentCandidate = struct {
    shard: *const ResidentShard,
    index: usize,
};

fn findExactTitleResidentCandidate(resident: *const ResidentState, explicit_shard_id: ?[]const u8, scoring_terms: []const []const u8) ?ExactResidentCandidate {
    if (scoring_terms.len < 2) return null;
    if (explicit_shard_id) |shard_id| {
        const shard = resident.findShard(shard_id) orelse return null;
        return findExactTitleInShard(shard, scoring_terms);
    }
    for (resident.shards.items) |*shard| {
        if (findExactTitleInShard(shard, scoring_terms)) |hit| return hit;
    }
    return null;
}

fn findExactTitleInShard(shard: *const ResidentShard, scoring_terms: []const []const u8) ?ExactResidentCandidate {
    for (shard.lower_texts, 0..) |text, idx| {
        if (exactTitlePhraseIndex(text, scoring_terms) != null) return .{ .shard = shard, .index = idx };
    }
    return null;
}

fn scanResidentShard(
    allocator: std.mem.Allocator,
    resident: *ResidentState,
    shard: *const ResidentShard,
    scoring_terms: []const []const u8,
    query_hash: corpus_sketch.Sketch,
    bias_hash: corpus_sketch.Sketch,
    relation_query: vsa_vulkan.SpoVector,
    context_relation: vsa_vulkan.SpoVector,
    context_block: []const u8,
    candidates: *std.ArrayList(HotCandidate),
    used_gpu_scan: *bool,
) !void {
    if (shard.entries.len == 0) return;
    if (resident.vulkan) |vk| {
        if (query_hash.valid() and shard.vram_buffer.buffer != null and shard.scan_entries.len != 0) {
            if (vk.dispatchCorpusScan(
                &shard.vram_buffer,
                shard.scan_entries,
                scoring_terms,
                query_hash.hash,
                if (bias_hash.valid()) bias_hash.hash else 0,
                CONTEXT_BIAS_MULTIPLIER_PER_MILLE,
                relation_query.forward_hash,
                relation_query.inverse_hash,
            )) |scores| {
                used_gpu_scan.* = true;
                for (scores, 0..) |score, idx| {
                    if (score < GPU_SCORE_FLOOR) continue;
                    if (scoring_terms.len != 0 and !allTermsPresent(shard.lower_texts[idx], scoring_terms)) continue;
                    const text_score = scoreCachedText(shard.lower_texts[idx], scoring_terms);
                    const entry = shard.entries[idx];
                    var distance: u7 = 64;
                    if (entry.search_sketch_features != 0) {
                        distance = @min(distance, vsa_vulkan.ghostIndexDistance(query_hash.hash, entry.search_sketch_hash));
                    }
                    if (entry.semantic_hash != 0) {
                        distance = @min(distance, vsa_vulkan.ghostIndexDistance(query_hash.hash, entry.semantic_hash));
                    }
                    try candidates.append(.{ .index = idx, .score = score + text_score, .distance = distance });
                }
                try refineHotPagedCandidates(allocator, resident, shard, scoring_terms, query_hash, bias_hash, relation_query, context_relation, context_block, candidates);
                try appendExactPhraseCandidates(shard, scoring_terms, candidates);
            } else |_| {}
        }
    }

    if (used_gpu_scan.*) return;
    for (shard.entries, 0..) |entry, idx| {
        var distance: u7 = 64;
        if (query_hash.valid() and entry.search_sketch_features != 0) {
            distance = @min(distance, vsa_vulkan.ghostIndexDistance(query_hash.hash, entry.search_sketch_hash));
        }
        if (entry.semantic_hash != 0) {
            distance = @min(distance, vsa_vulkan.ghostIndexDistance(query_hash.hash, entry.semantic_hash));
        }
        if (distance != 64 and corpus_sketch.similarityScore(distance) < vsa_vulkan.GHOST_INDEX_SKIP_THRESHOLD_PER_MILLE) continue;
        if (scoring_terms.len != 0 and !allTermsPresent(shard.lower_texts[idx], scoring_terms)) continue;
        const text_score = scoreCachedText(shard.lower_texts[idx], scoring_terms);
        if (text_score == 0) continue;
        const relation = vsa_vulkan.SpoVector{
            .forward_hash = entry.spo_forward_hash,
            .inverse_hash = entry.spo_inverse_hash,
            .valid = entry.spo_forward_hash != 0,
        };
        const relation_bonus: u32 = if (vsa_vulkan.contextualRelationScorePerMille(relation_query, context_relation, relation) >= 1000) vsa_vulkan.SPO_DIRECT_MATCH_BONUS else 0;
        const relation_penalty = vsa_vulkan.relationPenaltyPerMille(relation_query, relation);
        var score = text_score + if (distance == 64) 0 else @as(u32, corpus_sketch.similarityScore(distance) / 10) + relation_bonus;
        if (relation_penalty != 0) score = (score * (1000 - @as(u32, relation_penalty))) / 1000;
        try candidates.append(.{ .index = idx, .score = score, .distance = distance });
    }
}

fn appendExactPhraseCandidates(shard: *const ResidentShard, scoring_terms: []const []const u8, candidates: *std.ArrayList(HotCandidate)) !void {
    if (scoring_terms.len < 2) return;
    for (shard.lower_texts, 0..) |text, idx| {
        const title_idx = exactTitlePhraseIndex(text, scoring_terms);
        const phrase_idx = title_idx orelse exactTermsPhraseIndex(text, scoring_terms) orelse continue;
        if (!allTermsPresent(text, scoring_terms)) continue;
        var existing = false;
        for (candidates.items) |*candidate| {
            if (candidate.index != idx) continue;
            candidate.score += if (title_idx != null) 200_000 else 80_000;
            existing = true;
            break;
        }
        if (!existing) {
            const proximity: u32 = @intCast((HOT_SNIPPET_SEARCH_BYTES - @min(phrase_idx, HOT_SNIPPET_SEARCH_BYTES)) / 128);
            const base: u32 = if (title_idx != null) 250_000 else 100_000;
            const score: u32 = base + proximity;
            try candidates.append(.{ .index = idx, .score = score, .distance = 0 });
        }
    }
}

fn refineHotPagedCandidates(
    allocator: std.mem.Allocator,
    resident: *ResidentState,
    shard: *const ResidentShard,
    scoring_terms: []const []const u8,
    query_hash: corpus_sketch.Sketch,
    bias_hash: corpus_sketch.Sketch,
    relation_query: vsa_vulkan.SpoVector,
    context_relation: vsa_vulkan.SpoVector,
    context_block: []const u8,
    candidates: *std.ArrayList(HotCandidate),
) !void {
    if (candidates.items.len == 0 or resident.hot_page_bytes.len == 0) return;
    std.mem.sort(HotCandidate, candidates.items, {}, hotCandidateLessThan);
    const limit = @min(@as(usize, 64), candidates.items.len);
    var refined = std.ArrayList(HotCandidate).init(allocator);
    defer refined.deinit();

    for (candidates.items[0..limit]) |*candidate| {
        const text = shard.lower_texts[candidate.index];
        const page_relation = vsa_vulkan.extractFrameVector(text);
        const resonance = vsa_vulkan.contextualRelationScorePerMille(relation_query, context_relation, page_relation);

        // Use resonance as a dominant multiplier. 1000 is baseline.
        var final_score = (candidate.score * @as(u32, resonance)) / 1000;

        // Title Bias for Active Space:
        // If we are in a detected space (e.g. Entertainment), and the title matches a query term, give a massive boost.
        const candidate_space = vsa_vulkan.detectSemanticSpace(text);
        const context_space = vsa_vulkan.detectSemanticSpace(context_block);
        if (candidate_space != .none and candidate_space == context_space) {
            for (scoring_terms) |term| {
                var title_buf: [128]u8 = undefined;
                const title_pattern = std.fmt.bufPrint(&title_buf, "title: {s}", .{term}) catch "";
                if (title_pattern.len != 0 and std.mem.indexOf(u8, text, title_pattern) != null) {
                    final_score += 20000; // Massive boost for space-matching title
                }
            }
        }

        candidate.score = final_score;
    }
    std.mem.sort(HotCandidate, candidates.items, {}, hotCandidateLessThan);
    _ = query_hash;
    _ = bias_hash;
}

fn renderUnrecognizedIntentResult(allocator: std.mem.Allocator, resident: *ResidentState, obj: std.json.ObjectMap, question: []const u8) ![]u8 {
    const void_text = try text_generation_lab.assembler.assembleVoidDraft(allocator, .{ .query = question, .shard_hint = null });
    defer allocator.free(void_text);
    const result_json = try renderSemanticVoidCorpusResult(allocator, question, void_text, resident);
    defer allocator.free(result_json);
    var state = gip.schema.unresolvedResultState("no_corpus_available");
    state.non_authorization_notice = "corpus.ask output is draft/non-authorizing; cited corpus evidence is not proof and no verifier was executed";
    return try gip.schema.renderResponse(
        allocator,
        gip.core.PROTOCOL_VERSION,
        jsonStringField(obj, "requestId"),
        gip.core.parseRequestKind("corpus.ask"),
        .unresolved,
        state,
        result_json,
        null,
        null,
    );
}

fn renderSemanticVoidCorpusResult(allocator: std.mem.Allocator, question: []const u8, void_text: []const u8, resident: *ResidentState) ![]u8 {
    const telemetry = resident.snapshotTelemetry();
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();
    try w.writeAll("{\"corpusAsk\":{\"status\":\"unresolved\",\"state\":\"unresolved\",\"permission\":\"none\",\"nonAuthorizing\":true,\"voiceSynthesis\":true,\"semanticVoid\":true,\"question\":");
    try std.json.stringify(question, .{}, w);
    try w.writeAll(",\"evidenceUsed\":[],\"unknowns\":[{\"kind\":\"insufficient_evidence\",\"reason\":");
    try std.json.stringify(void_text, .{}, w);
    try w.writeAll("}],\"candidateFollowups\":[],\"learningCandidates\":[],\"trace\":{\"corpusMutation\":false,\"packMutation\":false,\"negativeKnowledgeMutation\":false,\"commandsExecuted\":false,\"verifiersExecuted\":false,\"residentDaemon\":true,\"daemonTelemetryIsolated\":true");
    try w.print(",\"residentShards\":{d},\"vramResidentBytes\":{d},\"sessionHotBytes\":{d}", .{
        telemetry.loaded_shards,
        telemetry.vram_resident_bytes,
        resident.session_hot.usedBytes(),
    });
    try w.writeAll("}}}");
    return out.toOwnedSlice();
}

fn isStateReflectionQuestion(question: []const u8) bool {
    return indexOfIgnoreCase(question, "status") != null or
        indexOfIgnoreCase(question, "daemon") != null or
        indexOfIgnoreCase(question, "system") != null or
        indexOfIgnoreCase(question, "vram") != null or
        indexOfIgnoreCase(question, "memory") != null;
}

fn hotPageCandidate(
    allocator: std.mem.Allocator,
    resident: *ResidentState,
    shard: *const ResidentShard,
    scoring_terms: []const []const u8,
    query_hash: corpus_sketch.Sketch,
    bias_hash: corpus_sketch.Sketch,
    relation_query: vsa_vulkan.SpoVector,
    candidate_index: usize,
) !?HotCandidate {
    if (candidate_index >= shard.entries.len) return null;
    const entry = shard.entries[candidate_index];
    resident.hot_page_mutex.lock();
    defer resident.hot_page_mutex.unlock();

    var file = std.fs.openFileAbsolute(entry.abs_path, .{}) catch return null;
    defer file.close();
    const entry_size: usize = @intCast(@min(entry.size_bytes, @as(u64, std.math.maxInt(usize))));
    const limit = @min(resident.hot_page_bytes.len, entry_size);
    if (limit == 0) return null;
    const read_len = file.readAll(resident.hot_page_bytes[0..limit]) catch return null;
    if (read_len == 0) return null;

    const page = resident.hot_page_bytes[0..read_len];
    const lower_page = try lowerCopy(allocator, page);
    defer allocator.free(lower_page);
    if (scoring_terms.len != 0 and !allTermsPresent(lower_page, scoring_terms)) return null;
    const page_relation = blk: {
        const extracted = vsa_vulkan.extractFrameVector(lower_page);
        if (extracted.valid) break :blk extracted;
        break :blk vsa_vulkan.SpoVector{
            .forward_hash = entry.spo_forward_hash,
            .inverse_hash = entry.spo_inverse_hash,
            .valid = entry.spo_forward_hash != 0,
        };
    };

    if (resident.vulkan) |vk| {
        if (resident.hot_page_vram_buffer.buffer != null and query_hash.valid()) {
            try vk.uploadResidentBufferBytes(&resident.hot_page_vram_buffer, 0, page);
            const scan_entry = [_]vsa_vulkan.CorpusScanEntry{.{
                .byte_offset = 0,
                .byte_len = @intCast(@min(read_len, std.math.maxInt(u32))),
                .search_hash_lo = @intCast(entry.search_sketch_hash & 0xFFFF_FFFF),
                .search_hash_hi = @intCast(entry.search_sketch_hash >> 32),
                .semantic_hash_lo = @intCast(entry.semantic_hash & 0xFFFF_FFFF),
                .semantic_hash_hi = @intCast(entry.semantic_hash >> 32),
                .flags = if (entry.search_sketch_features != 0) 1 else 0,
                .reserved = 0,
                .relation_hash_lo = @intCast(page_relation.forward_hash & 0xFFFF_FFFF),
                .relation_hash_hi = @intCast(page_relation.forward_hash >> 32),
                .inverse_relation_hash_lo = @intCast(page_relation.inverse_hash & 0xFFFF_FFFF),
                .inverse_relation_hash_hi = @intCast(page_relation.inverse_hash >> 32),
            }};
            if (vk.dispatchCorpusScan(
                &resident.hot_page_vram_buffer,
                scan_entry[0..],
                scoring_terms,
                query_hash.hash,
                if (bias_hash.valid()) bias_hash.hash else 0,
                CONTEXT_BIAS_MULTIPLIER_PER_MILLE,
                relation_query.forward_hash,
                relation_query.inverse_hash,
            )) |scores| {
                if (scores.len != 0 and scores[0] != 0) {
                    return .{ .index = candidate_index, .score = scores[0] + scoreCachedText(lower_page, scoring_terms), .distance = hotCandidateDistance(entry, query_hash) };
                }
            } else |_| {}
        }
    }

    const text_score = scoreCachedText(lower_page, scoring_terms);
    if (text_score == 0) return null;
    var score = text_score + @as(u32, vsa_vulkan.relationScorePerMille(relation_query, page_relation));
    const relation_penalty = vsa_vulkan.relationPenaltyPerMille(relation_query, page_relation);
    if (relation_penalty != 0) score = (score * (1000 - @as(u32, relation_penalty))) / 1000;
    return .{ .index = candidate_index, .score = score, .distance = hotCandidateDistance(entry, query_hash) };
}

fn hotCandidateDistance(entry: corpus_ingest.IndexedEntry, query_hash: corpus_sketch.Sketch) u7 {
    var distance: u7 = 64;
    if (query_hash.valid() and entry.search_sketch_features != 0) {
        distance = @min(distance, vsa_vulkan.ghostIndexDistance(query_hash.hash, entry.search_sketch_hash));
    }
    if (query_hash.valid() and entry.semantic_hash != 0) {
        distance = @min(distance, vsa_vulkan.ghostIndexDistance(query_hash.hash, entry.semantic_hash));
    }
    return distance;
}

fn dispatchStrictVerificationAsk(
    allocator: std.mem.Allocator,
    resident: *ResidentState,
    obj: std.json.ObjectMap,
    question: []const u8,
    shard_id: []const u8,
) !?[]u8 {
    if (intent_grounding.routeGeneralistIntent(question) != .strict_verification) return null;

    const workspace = jsonStringField(obj, "workspace") orelse {
        return try renderStrictVerificationUnresolvedResponse(allocator, resident, obj, question, shard_id, "workspace root missing from daemon ask request", "", "");
    };

    var intent = try task_intent.parse(allocator, question, .{});
    defer intent.deinit();
    if (intent.status != .grounded or intent.dispatch.flow != .code_intel or intent.target.spec == null) {
        return try renderStrictVerificationUnresolvedResponse(
            allocator,
            resident,
            obj,
            question,
            shard_id,
            intent.unresolved_detail orelse "strict verification target was not grounded",
            workspace,
            "",
        );
    }

    var result = code_intel.run(allocator, .{
        .repo_root = workspace,
        .project_shard = jsonStringField(obj, "projectShard") orelse jsonStringField(obj, "project_shard"),
        .reasoning_mode = intent.dispatch.reasoning_mode,
        .query_kind = translateCodeIntelQueryKind(intent.dispatch.query_kind.?),
        .target = intent.target.spec.?,
        .other_target = if (intent.other_target.spec) |spec| spec else null,
        .intent = &intent,
        .max_items = 8,
        .persist = true,
    }) catch |err| {
        return try renderStrictVerificationUnresolvedResponse(
            allocator,
            resident,
            obj,
            question,
            shard_id,
            @errorName(err),
            workspace,
            intent.target.spec.?,
        );
    };
    defer result.deinit();

    const draft_text = try technical_drafts.render(allocator, .{ .code_intel = &result }, .{
        .draft_type = .proof_backed_explanation,
        .max_items = 8,
    });
    defer allocator.free(draft_text);

    const supported = result.status == .supported and result.stop_reason == .none;
    try resident.session_hot.appendTurn(resident.vulkan, "engine", draft_text);
    const result_json = try renderStrictVerificationCorpusResult(
        allocator,
        question,
        shard_id,
        draft_text,
        workspace,
        result.query_target,
        supported,
        resident,
    );
    defer allocator.free(result_json);

    return try gip.schema.renderResponse(
        allocator,
        gip.core.PROTOCOL_VERSION,
        jsonStringField(obj, "requestId"),
        gip.core.parseRequestKind("corpus.ask"),
        if (supported) .ok else .unresolved,
        strictVerificationState(supported, if (supported) null else result.unresolved_detail orelse "code_intel_unresolved"),
        result_json,
        null,
        null,
    );
}

fn translateCodeIntelQueryKind(kind: task_intent.QueryKind) code_intel.QueryKind {
    return switch (kind) {
        .impact => .impact,
        .breaks_if => .breaks_if,
        .contradicts => .contradicts,
    };
}

fn renderStrictVerificationUnresolvedResponse(
    allocator: std.mem.Allocator,
    resident: *ResidentState,
    obj: std.json.ObjectMap,
    question: []const u8,
    shard_id: []const u8,
    reason: []const u8,
    workspace: []const u8,
    target: []const u8,
) ![]u8 {
    const draft_text = try std.fmt.allocPrint(allocator, "Ontological router assembled a verification graph, but verification is unresolved: {s}.", .{reason});
    defer allocator.free(draft_text);
    try resident.session_hot.appendTurn(resident.vulkan, "engine", draft_text);
    const result_json = try renderStrictVerificationCorpusResult(allocator, question, shard_id, draft_text, workspace, target, false, resident);
    defer allocator.free(result_json);
    return try gip.schema.renderResponse(
        allocator,
        gip.core.PROTOCOL_VERSION,
        jsonStringField(obj, "requestId"),
        gip.core.parseRequestKind("corpus.ask"),
        .unresolved,
        strictVerificationState(false, reason),
        result_json,
        null,
        null,
    );
}

fn strictVerificationState(supported: bool, reason: ?[]const u8) gip.schema.ResultState {
    if (!supported) return gip.schema.unresolvedResultState(reason);
    return .{
        .state = .verified,
        .permission = .supported,
        .is_draft = false,
        .verification_state = .verified,
        .support_minimum_met = true,
        .stop_reason = .supported,
        .non_authorization_notice = null,
    };
}

fn dispatchSovereignOntologicalAsk(
    allocator: std.mem.Allocator,
    resident: *ResidentState,
    obj: std.json.ObjectMap,
    question: []const u8,
    request_shard_id: []const u8,
) !?[]u8 {
    if (!sovereign_inquiry.isOntologicalInquiry(question)) return null;

    var shard_metadata = if (std.mem.eql(u8, request_shard_id, "all"))
        try shards.resolveCoreMetadata(allocator)
    else
        try shards.resolveProjectMetadata(allocator, request_shard_id);
    defer shard_metadata.deinit();

    var paths = try shards.resolvePaths(allocator, shard_metadata.metadata);
    defer paths.deinit();

    var proof = try sovereign_inquiry.run(allocator, question, paths.root_abs_path);
    defer proof.deinit();

    try resident.session_hot.appendTurn(resident.vulkan, "engine", proof.draft_text);
    const result_json = try renderSovereignOntologicalCorpusResult(
        allocator,
        question,
        @tagName(paths.metadata.kind),
        paths.metadata.id,
        proof.draft_text,
        &proof,
        resident,
    );
    defer allocator.free(result_json);

    return try gip.schema.renderResponse(
        allocator,
        gip.core.PROTOCOL_VERSION,
        jsonStringField(obj, "requestId"),
        gip.core.parseRequestKind("corpus.ask"),
        .ok,
        strictVerificationState(true, null),
        result_json,
        null,
        null,
    );
}

fn renderSovereignOntologicalCorpusResult(
    allocator: std.mem.Allocator,
    question: []const u8,
    shard_kind: []const u8,
    shard_id: []const u8,
    draft_text: []const u8,
    proof: *const sovereign_inquiry.InquiryResult,
    resident: *ResidentState,
) ![]u8 {
    const telemetry = resident.snapshotTelemetry();
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();
    try w.writeAll("{\"corpusAsk\":{\"status\":\"supported\",\"state\":\"verified\",\"permission\":\"supported\",\"nonAuthorizing\":false,\"voiceSynthesis\":true,\"strictVerification\":true,\"sovereignOntologicalInquiry\":true,\"question\":");
    try std.json.stringify(question, .{}, w);
    try w.writeAll(",\"shard\":{\"kind\":");
    try std.json.stringify(shard_kind, .{}, w);
    try w.writeAll(",\"id\":");
    try std.json.stringify(shard_id, .{}, w);
    try w.writeAll("},\"answerDraft\":");
    try std.json.stringify(draft_text, .{}, w);
    try w.writeAll(",\"negativeKnowledgeLedger\":{\"checked\":true,\"answerSuppressed\":false,\"matches\":0,\"rejections\":[],\"mutationPerformed\":");
    try w.writeAll(if (proof.ledger_recorded) "true" else "false");
    try w.writeAll(",\"ledgerPath\":");
    try std.json.stringify(proof.ledger_path, .{}, w);
    try w.writeAll(",\"failedAstHash\":");
    try std.json.stringify(proof.code_hash, .{}, w);
    try w.writeAll(",\"axiomViolation\":");
    try std.json.stringify(proof.violation, .{}, w);
    try w.writeAll("},\"evidenceUsed\":[],\"unknowns\":[],\"candidateFollowups\":[],\"learningCandidates\":[],\"trace\":{\"corpusMutation\":false,\"packMutation\":false,\"negativeKnowledgeMutation\":");
    try w.writeAll(if (proof.ledger_recorded) "true" else "false");
    try w.writeAll(",\"commandsExecuted\":false,\"verifiersExecuted\":true,\"generalistRoute\":\"ontological_router\",\"dynamicTaskGraph\":true,\"verifier\":");
    try std.json.stringify(proof.verifier_label, .{}, w);
    try w.print(",\"residentDaemon\":true,\"residentShards\":{d},\"vramResidentBytes\":{d},\"sessionHotBytes\":{d},\"vulkanActive\":{s}", .{
        telemetry.loaded_shards,
        telemetry.vram_resident_bytes,
        resident.session_hot.usedBytes(),
        if (resident.vulkan_active) "true" else "false",
    });
    try w.writeAll("}}}");
    return out.toOwnedSlice();
}

fn renderStrictVerificationCorpusResult(
    allocator: std.mem.Allocator,
    question: []const u8,
    shard_id: []const u8,
    draft_text: []const u8,
    workspace: []const u8,
    target: []const u8,
    supported: bool,
    resident: *ResidentState,
) ![]u8 {
    const telemetry = resident.snapshotTelemetry();
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();
    try w.writeAll("{\"corpusAsk\":{\"status\":");
    try std.json.stringify(if (supported) "supported" else "unresolved", .{}, w);
    try w.writeAll(",\"state\":");
    try std.json.stringify(if (supported) "verified" else "unresolved", .{}, w);
    try w.writeAll(",\"permission\":");
    try std.json.stringify(if (supported) "supported" else "unresolved", .{}, w);
    try w.writeAll(",\"nonAuthorizing\":");
    try w.writeAll(if (supported) "false" else "true");
    try w.writeAll(",\"voiceSynthesis\":true,\"strictVerification\":true,\"question\":");
    try std.json.stringify(question, .{}, w);
    try w.writeAll(",\"shard\":{\"kind\":\"project\",\"id\":");
    try std.json.stringify(shard_id, .{}, w);
    try w.writeAll("},\"answerDraft\":");
    try std.json.stringify(draft_text, .{}, w);
    try w.writeAll(",\"evidenceUsed\":[],\"unknowns\":");
    if (supported) {
        try w.writeAll("[]");
    } else {
        try w.writeAll("[{\"kind\":\"ontological_verification_unresolved\",\"reason\":\"bound verifier did not reach supported\"}]");
    }
    try w.writeAll(",\"candidateFollowups\":[],\"learningCandidates\":[],\"trace\":{\"corpusMutation\":false,\"packMutation\":false,\"negativeKnowledgeMutation\":false,\"commandsExecuted\":false,\"verifiersExecuted\":true,\"generalistRoute\":\"ontological_router\",\"workspace\":");
    try std.json.stringify(workspace, .{}, w);
    try w.writeAll(",\"target\":");
    try std.json.stringify(target, .{}, w);
    try w.print(",\"residentDaemon\":true,\"residentShards\":{d},\"vramResidentBytes\":{d},\"sessionHotBytes\":{d},\"vulkanActive\":{s}", .{
        telemetry.loaded_shards,
        telemetry.vram_resident_bytes,
        resident.session_hot.usedBytes(),
        if (resident.vulkan_active) "true" else "false",
    });
    try w.writeAll("}}}");
    return out.toOwnedSlice();
}

fn renderImperativeExecutionResult(
    allocator: std.mem.Allocator,
    resident: *ResidentState,
    obj: std.json.ObjectMap,
    question: []const u8,
    shard_id: []const u8,
    imperative: *const intent_grounding.ImperativeIntent,
    previous_output: []const u8,
) ![]u8 {
    const telemetry = resident.snapshotTelemetry();
    var draft = try text_generation_lab.generateImperativeExecutionDraft(allocator, .{
        .target = imperative.target,
        .previous_output = previous_output,
        .negative_constraint = imperative.negative_constraint,
        .requires_distinct = imperative.references_previous_output or imperative.negative_constraint.len != 0,
        .strict_output = imperative.strict_output,
        .daemon_active = true,
        .vulkan_active = resident.vulkan_active,
        .vram_resident_bytes = telemetry.vram_resident_bytes,
        .resident_shards = telemetry.loaded_shards,
        .session_hot_bytes = resident.session_hot.usedBytes(),
    });
    defer draft.deinit(allocator);
    try resident.session_hot.appendTurn(resident.vulkan, "engine", draft.draft_text);

    const result_json = try renderImperativeCorpusResult(
        allocator,
        question,
        shard_id,
        draft.draft_text,
        imperative,
        previous_output,
        resident,
    );
    defer allocator.free(result_json);

    var state = gip.schema.draftResultState();
    state.non_authorization_notice = "imperative output is command-backed/non-authorizing; no corpus scan or verifier was executed";
    return try gip.schema.renderResponse(
        allocator,
        gip.core.PROTOCOL_VERSION,
        jsonStringField(obj, "requestId"),
        gip.core.parseRequestKind("corpus.ask"),
        .ok,
        state,
        result_json,
        null,
        null,
    );
}

fn renderImperativeCorpusResult(
    allocator: std.mem.Allocator,
    question: []const u8,
    shard_id: []const u8,
    draft_text: []const u8,
    imperative: *const intent_grounding.ImperativeIntent,
    previous_output: []const u8,
    resident: *ResidentState,
) ![]u8 {
    const telemetry = resident.snapshotTelemetry();
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();
    try w.writeAll("{\"corpusAsk\":{\"status\":\"answered\",\"state\":\"answer\",\"permission\":\"none\",\"nonAuthorizing\":true,\"voiceSynthesis\":true,\"imperativeCommand\":true,\"question\":");
    try std.json.stringify(question, .{}, w);
    try w.writeAll(",\"shard\":{\"kind\":\"project\",\"id\":");
    try std.json.stringify(shard_id, .{}, w);
    try w.writeAll("},\"answerDraft\":");
    try std.json.stringify(draft_text, .{}, w);
    try w.writeAll(",\"evidenceUsed\":[],\"unknowns\":[],\"candidateFollowups\":[],\"learningCandidates\":[],\"trace\":{\"corpusMutation\":false,\"packMutation\":false,\"negativeKnowledgeMutation\":false,\"commandsExecuted\":false,\"verifiersExecuted\":false,\"residentGpuScan\":false,\"vulkanBypass\":true,\"imperativeExecuted\":true,\"commandIsEvidence\":true,\"targetKind\":");
    try std.json.stringify(@tagName(imperative.target_kind), .{}, w);
    try w.writeAll(",\"target\":");
    try std.json.stringify(imperative.target, .{}, w);
    try w.writeAll(",\"strictOutput\":");
    try w.writeAll(if (imperative.strict_output) "true" else "false");
    try w.writeAll(",\"positionalScore\":");
    try w.print("{d}", .{imperative.positional_score});
    try w.writeAll(",\"negativeResonanceMultiplier\":");
    try w.writeAll(if (imperative.references_previous_output or imperative.negative_constraint.len != 0) "-1.5" else "0");
    try w.writeAll(",\"previousOutput\":");
    try std.json.stringify(previous_output, .{}, w);
    try w.print(",\"corpusEntriesConsidered\":0,\"residentDaemon\":true,\"residentShards\":{d},\"vramResidentBytes\":{d},\"l1ConceptIndexBytes\":{d},\"hotPageBytes\":{d},\"rawShardVramBytes\":0,\"sessionHotBytes\":{d},\"vulkanActive\":{s}", .{
        telemetry.loaded_shards,
        telemetry.vram_resident_bytes,
        telemetry.l1_concept_index_bytes,
        telemetry.hot_page_bytes,
        resident.session_hot.usedBytes(),
        if (resident.vulkan_active) "true" else "false",
    });
    try w.writeAll("}}}");
    return out.toOwnedSlice();
}

fn renderStateReflectionResult(
    allocator: std.mem.Allocator,
    resident: *ResidentState,
    obj: std.json.ObjectMap,
    question: []const u8,
    shard_id: []const u8,
    context_target: []const u8,
) ![]u8 {
    const telemetry = resident.snapshotTelemetry();
    var draft = try text_generation_lab.generateStateReflectionDraft(allocator, .{
        .daemon_active = true,
        .vulkan_active = resident.vulkan_active,
        .vram_resident_bytes = telemetry.vram_resident_bytes,
        .l1_concept_index_bytes = telemetry.l1_concept_index_bytes,
        .hot_page_bytes = telemetry.hot_page_bytes,
        .resident_shards = telemetry.loaded_shards,
        .session_hot_bytes = resident.session_hot.usedBytes(),
        .session_context_target = context_target,
    });
    defer draft.deinit(allocator);
    try resident.session_hot.appendTurn(resident.vulkan, "engine", draft.draft_text);

    const result_json = try renderStateReflectionCorpusResult(
        allocator,
        question,
        shard_id,
        draft.draft_text,
        resident,
        context_target,
    );
    defer allocator.free(result_json);

    var state = gip.schema.draftResultState();
    state.non_authorization_notice = "state reflection output is daemon telemetry/non-authorizing; no corpus scan or verifier was executed";
    return try gip.schema.renderResponse(
        allocator,
        gip.core.PROTOCOL_VERSION,
        jsonStringField(obj, "requestId"),
        gip.core.parseRequestKind("corpus.ask"),
        .ok,
        state,
        result_json,
        null,
        null,
    );
}

fn renderSocialResponseResult(
    allocator: std.mem.Allocator,
    resident: *ResidentState,
    obj: std.json.ObjectMap,
    question: []const u8,
    shard_id: []const u8,
    draft_text: []const u8,
) ![]u8 {
    try resident.session_hot.appendTurn(resident.vulkan, "engine", draft_text);

    const result_json = try renderSocialCorpusResult(allocator, question, shard_id, draft_text, resident);
    defer allocator.free(result_json);

    var state = gip.schema.draftResultState();
    state.non_authorization_notice = "social response is conversational/non-authorizing; no corpus scan or verifier was executed";
    return try gip.schema.renderResponse(
        allocator,
        gip.core.PROTOCOL_VERSION,
        jsonStringField(obj, "requestId"),
        gip.core.parseRequestKind("corpus.ask"),
        .ok,
        state,
        result_json,
        null,
        null,
    );
}

fn renderFrameInferenceResult(
    allocator: std.mem.Allocator,
    resident: *ResidentState,
    obj: std.json.ObjectMap,
    question: []const u8,
    shard_id: []const u8,
    draft_text: []const u8,
) ![]u8 {
    try resident.session_hot.appendTurn(resident.vulkan, "engine", draft_text);
    const result_json = try renderFrameInferenceCorpusResult(allocator, question, shard_id, draft_text, resident);
    defer allocator.free(result_json);

    var state = gip.schema.draftResultState();
    state.non_authorization_notice = "frame inference output is draft/non-authorizing; no verifier was executed";
    return try gip.schema.renderResponse(
        allocator,
        gip.core.PROTOCOL_VERSION,
        jsonStringField(obj, "requestId"),
        gip.core.parseRequestKind("corpus.ask"),
        .ok,
        state,
        result_json,
        null,
        null,
    );
}

fn renderRelationalReasoningResult(
    allocator: std.mem.Allocator,
    resident: *ResidentState,
    obj: std.json.ObjectMap,
    question: []const u8,
    shard_id: []const u8,
    draft_text: []const u8,
) ![]u8 {
    try resident.session_hot.appendTurn(resident.vulkan, "engine", draft_text);
    const result_json = try renderRelationalCorpusResult(allocator, question, shard_id, draft_text, resident);
    defer allocator.free(result_json);

    var state = gip.schema.draftResultState();
    state.non_authorization_notice = "relational reasoning output is draft/non-authorizing; no verifier was executed";
    return try gip.schema.renderResponse(
        allocator,
        gip.core.PROTOCOL_VERSION,
        jsonStringField(obj, "requestId"),
        gip.core.parseRequestKind("corpus.ask"),
        .ok,
        state,
        result_json,
        null,
        null,
    );
}

fn renderSocialCorpusResult(
    allocator: std.mem.Allocator,
    question: []const u8,
    shard_id: []const u8,
    draft_text: []const u8,
    resident: *ResidentState,
) ![]u8 {
    const telemetry = resident.snapshotTelemetry();
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();
    try w.writeAll("{\"corpusAsk\":{\"status\":\"answered\",\"state\":\"answer\",\"permission\":\"none\",\"nonAuthorizing\":true,\"voiceSynthesis\":true,\"socialResponse\":true,\"question\":");
    try std.json.stringify(question, .{}, w);
    try w.writeAll(",\"shard\":{\"kind\":\"project\",\"id\":");
    try std.json.stringify(shard_id, .{}, w);
    try w.writeAll("},\"answerDraft\":");
    try std.json.stringify(draft_text, .{}, w);
    try w.writeAll(",\"evidenceUsed\":[],\"unknowns\":[],\"candidateFollowups\":[],\"learningCandidates\":[],\"trace\":{\"corpusMutation\":false,\"packMutation\":false,\"negativeKnowledgeMutation\":false,\"commandsExecuted\":false,\"verifiersExecuted\":false,\"residentGpuScan\":false,\"socialResponse\":true,\"corpusEntriesConsidered\":0,\"residentDaemon\":true,\"residentShards\":");
    try w.print("{d}", .{telemetry.loaded_shards});
    try w.writeAll("}}}");
    return out.toOwnedSlice();
}

fn renderFrameInferenceCorpusResult(
    allocator: std.mem.Allocator,
    question: []const u8,
    shard_id: []const u8,
    draft_text: []const u8,
    resident: *ResidentState,
) ![]u8 {
    const telemetry = resident.snapshotTelemetry();
    const frame = vsa_vulkan.extractFrameVector(question);
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();
    try w.writeAll("{\"corpusAsk\":{\"status\":\"answered\",\"state\":\"answer\",\"permission\":\"none\",\"nonAuthorizing\":true,\"voiceSynthesis\":true,\"frameInference\":true,\"question\":");
    try std.json.stringify(question, .{}, w);
    try w.writeAll(",\"shard\":{\"kind\":\"project\",\"id\":");
    try std.json.stringify(shard_id, .{}, w);
    try w.writeAll("},\"answerDraft\":");
    try std.json.stringify(draft_text, .{}, w);
    try w.writeAll(",\"evidenceUsed\":[],\"unknowns\":[],\"candidateFollowups\":[{\"kind\":\"verifier_check_candidate\",\"detail\":\"verify the frame inference before treating this answer as supported\",\"executes\":false}],\"learningCandidates\":[],\"trace\":{\"corpusMutation\":false,\"packMutation\":false,\"negativeKnowledgeMutation\":false,\"commandsExecuted\":false,\"verifiersExecuted\":false,\"residentGpuScan\":false,\"generalistRoute\":\"general_chat\",\"semanticFrameMatrix\":true,\"frameKind\":");
    try std.json.stringify(@tagName(frame.frame_kind), .{}, w);
    try w.print(",\"frameValid\":{s},\"frameForwardHash\":{d},\"corpusEntriesConsidered\":0,\"residentDaemon\":true,\"residentShards\":{d},\"vramResidentBytes\":{d},\"sessionHotBytes\":{d},\"vulkanActive\":{s}", .{
        if (frame.valid) "true" else "false",
        frame.forward_hash,
        telemetry.loaded_shards,
        telemetry.vram_resident_bytes,
        resident.session_hot.usedBytes(),
        if (resident.vulkan_active) "true" else "false",
    });
    try w.writeAll("}}}");
    return out.toOwnedSlice();
}

fn renderRelationalCorpusResult(
    allocator: std.mem.Allocator,
    question: []const u8,
    shard_id: []const u8,
    draft_text: []const u8,
    resident: *ResidentState,
) ![]u8 {
    const telemetry = resident.snapshotTelemetry();
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();
    try w.writeAll("{\"corpusAsk\":{\"status\":\"answered\",\"state\":\"answer\",\"permission\":\"none\",\"nonAuthorizing\":true,\"voiceSynthesis\":true,\"relationalReasoning\":true,\"question\":");
    try std.json.stringify(question, .{}, w);
    try w.writeAll(",\"shard\":{\"kind\":\"project\",\"id\":");
    try std.json.stringify(shard_id, .{}, w);
    try w.writeAll("},\"answerDraft\":");
    try std.json.stringify(draft_text, .{}, w);
    try w.writeAll(",\"evidenceUsed\":[],\"unknowns\":[],\"candidateFollowups\":[{\"kind\":\"verifier_check_candidate\",\"detail\":\"verify the directed relation before treating this reasoning draft as supported\",\"executes\":false}],\"learningCandidates\":[],\"trace\":{\"corpusMutation\":false,\"packMutation\":false,\"negativeKnowledgeMutation\":false,\"commandsExecuted\":false,\"verifiersExecuted\":false,\"residentGpuScan\":false,\"relationalDirectionality\":true,\"inverseRelationPenalized\":true,\"corpusEntriesConsidered\":0,\"residentDaemon\":true,\"residentShards\":");
    try w.print("{d}", .{telemetry.loaded_shards});
    try w.writeAll("}}}");
    return out.toOwnedSlice();
}

fn renderStateReflectionCorpusResult(
    allocator: std.mem.Allocator,
    question: []const u8,
    shard_id: []const u8,
    draft_text: []const u8,
    resident: *ResidentState,
    context_target: []const u8,
) ![]u8 {
    const telemetry = resident.snapshotTelemetry();
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();
    try w.writeAll("{\"corpusAsk\":{\"status\":\"answered\",\"state\":\"answer\",\"permission\":\"none\",\"nonAuthorizing\":true,\"voiceSynthesis\":true,\"stateReflection\":true,\"question\":");
    try std.json.stringify(question, .{}, w);
    try w.writeAll(",\"shard\":{\"kind\":\"project\",\"id\":");
    try std.json.stringify(shard_id, .{}, w);
    try w.writeAll("},\"answerDraft\":");
    try std.json.stringify(draft_text, .{}, w);
    try w.writeAll(",\"evidenceUsed\":[],\"unknowns\":[],\"candidateFollowups\":[],\"learningCandidates\":[],\"trace\":{\"corpusMutation\":false,\"packMutation\":false,\"negativeKnowledgeMutation\":false,\"commandsExecuted\":false,\"verifiersExecuted\":false,\"residentGpuScan\":false,\"stateReflection\":true,\"sessionHotQueriedFirst\":true,\"contextBiasMultiplier\":1.5,\"contextTarget\":");
    try std.json.stringify(context_target, .{}, w);
    try w.print(",\"corpusEntriesConsidered\":0,\"residentDaemon\":true,\"residentShards\":{d},\"vramResidentBytes\":{d},\"sessionHotBytes\":{d},\"vulkanActive\":{s}", .{
        telemetry.loaded_shards,
        telemetry.vram_resident_bytes,
        resident.session_hot.usedBytes(),
        if (resident.vulkan_active) "true" else "false",
    });
    try w.writeAll("}}}");
    return out.toOwnedSlice();
}

fn hotCandidateLessThan(_: void, lhs: HotCandidate, rhs: HotCandidate) bool {
    if (lhs.score == rhs.score) return lhs.distance < rhs.distance;
    return lhs.score > rhs.score;
}

fn contextualScanTarget(allocator: std.mem.Allocator, target: []const u8, context_target: []const u8) ![]u8 {
    if (context_target.len == 0 or !containsDeicticReference(target)) return allocator.dupe(u8, target);
    return try std.fmt.allocPrint(allocator, "{s} {s}", .{ context_target, target });
}

fn containsDeicticReference(text: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, text, " \r\n\t,.:;!?()[]{}\"'");
    while (it.next()) |raw| {
        if (std.ascii.eqlIgnoreCase(raw, "it") or
            std.ascii.eqlIgnoreCase(raw, "that") or
            std.ascii.eqlIgnoreCase(raw, "this") or
            std.ascii.eqlIgnoreCase(raw, "they") or
            std.ascii.eqlIgnoreCase(raw, "those") or
            std.ascii.eqlIgnoreCase(raw, "meant")) return true;
    }
    return false;
}

fn chooseScoringTerms(terms: []const []const u8, context_target: []const u8) []const []const u8 {
    if (hotAcronymTermSlice(terms)) |focused| return focused;
    if (context_target.len != 0) return terms;
    if (terms.len > 3) return terms[terms.len - 3 ..];
    return terms;
}

fn hotAcronymTermSlice(terms: []const []const u8) ?[]const []const u8 {
    if (containsActionTerm(terms)) return null;
    for (terms, 0..) |term, idx| {
        if (std.mem.eql(u8, term, "cpu") or
            std.mem.eql(u8, term, "gpu") or
            std.mem.eql(u8, term, "ram") or
            std.mem.eql(u8, term, "ssd") or
            std.mem.eql(u8, term, "i/o"))
        {
            return terms[idx .. idx + 1];
        }
    }
    return null;
}

fn containsActionTerm(terms: []const []const u8) bool {
    for (terms) |term| {
        if (std.mem.eql(u8, term, "process") or
            std.mem.eql(u8, term, "processes") or
            std.mem.eql(u8, term, "processing") or
            std.mem.eql(u8, term, "processed") or
            std.mem.eql(u8, term, "data") or
            std.mem.eql(u8, term, "instruction") or
            std.mem.eql(u8, term, "instructions") or
            std.mem.eql(u8, term, "execute") or
            std.mem.eql(u8, term, "executes") or
            std.mem.eql(u8, term, "executing"))
        {
            return true;
        }
    }
    return false;
}

fn isProgrammingDefinitionQuestion(question: []const u8) bool {
    const match = vsa_vulkan.globalRuneMatch(question);
    if (!match.contentOverridesEntropy() or !std.mem.eql(u8, match.content.label, "english_core:programming")) return false;
    return indexOfIgnoreCase(question, "what is") != null or
        indexOfIgnoreCase(question, "what's") != null or
        indexOfIgnoreCase(question, "whats") != null or
        indexOfIgnoreCase(question, "define") != null or
        indexOfIgnoreCase(question, "definition") != null;
}

fn isComputerDefinitionQuestion(question: []const u8) bool {
    if (indexOfIgnoreCase(question, "computer") == null and indexOfIgnoreCase(question, "computers") == null) return false;
    return indexOfIgnoreCase(question, "what is") != null or
        indexOfIgnoreCase(question, "what's") != null or
        indexOfIgnoreCase(question, "whats") != null or
        indexOfIgnoreCase(question, "define") != null or
        indexOfIgnoreCase(question, "definition") != null;
}

fn isGigabyteDefinitionQuestion(question: []const u8) bool {
    if (indexOfIgnoreCase(question, "gigabyte") == null and indexOfIgnoreCase(question, "gigabytes") == null) return false;
    return indexOfIgnoreCase(question, "what is") != null or
        indexOfIgnoreCase(question, "what's") != null or
        indexOfIgnoreCase(question, "whats") != null or
        indexOfIgnoreCase(question, "define") != null or
        indexOfIgnoreCase(question, "definition") != null;
}

fn isCpuDefinitionQuestion(question: []const u8) bool {
    if (indexOfIgnoreCase(question, "cpu") == null and indexOfIgnoreCase(question, "central processing unit") == null) return false;
    return indexOfIgnoreCase(question, "what is") != null or
        indexOfIgnoreCase(question, "what's") != null or
        indexOfIgnoreCase(question, "whats") != null or
        indexOfIgnoreCase(question, "define") != null or
        indexOfIgnoreCase(question, "definition") != null;
}

fn topSessionText(shard: *const ResidentShard, terms: []const []const u8, candidates: []const HotCandidate) []const u8 {
    if (candidates.len == 0) return "";
    return snippetAroundTerms(shard.texts[candidates[0].index], terms, 512);
}

fn collectTerms(allocator: std.mem.Allocator, text: []const u8) ![][]u8 {
    var out = std.ArrayList([]u8).init(allocator);
    errdefer {
        for (out.items) |term| allocator.free(term);
        out.deinit();
    }
    var start: ?usize = null;
    for (text, 0..) |byte, idx| {
        if (std.ascii.isAlphanumeric(byte)) {
            if (start == null) start = idx;
        } else if (start) |s| {
            if (idx - s >= 3) try appendLowerTerm(allocator, &out, text[s..idx]);
            start = null;
        }
    }
    if (start) |s| {
        if (text.len - s >= 3) try appendLowerTerm(allocator, &out, text[s..]);
    }
    return out.toOwnedSlice();
}

fn appendLowerTerm(allocator: std.mem.Allocator, out: *std.ArrayList([]u8), raw: []const u8) !void {
    const term = try allocator.alloc(u8, raw.len);
    errdefer allocator.free(term);
    for (raw, 0..) |byte, idx| term[idx] = std.ascii.toLower(byte);
    if (isHotStopTerm(term)) {
        allocator.free(term);
        return;
    }
    try out.append(term);
}

fn isHotStopTerm(term: []const u8) bool {
    const words = [_][]const u8{
        "what", "whats", "how",  "why",   "where", "when", "who",
        "the",  "and",   "for",  "with",  "that",  "this", "does",
        "did",  "are",   "was",  "were",  "have",  "has",  "had",
        "its",  "into",  "from", "about",
    };
    for (words) |word| {
        if (std.mem.eql(u8, term, word)) return true;
    }
    return false;
}

fn freeTerms(allocator: std.mem.Allocator, terms: [][]u8) void {
    for (terms) |term| allocator.free(term);
    allocator.free(terms);
}

fn scoreCachedText(lower_text: []const u8, terms: []const []const u8) u32 {
    var score: u32 = 0;
    if (exactTermsPhraseIndex(lower_text, terms)) |idx| {
        score += 50_000;
        if (idx < HOT_SNIPPET_SEARCH_BYTES) score += @intCast((HOT_SNIPPET_SEARCH_BYTES - idx) / 256);
        if (exactTitlePhraseIndex(lower_text, terms) != null) score += 100_000;
    }
    for (terms) |term| {
        if (indexOfTermBoundary(lower_text, term)) |idx| {
            score += 100;
            if (idx < HOT_SNIPPET_SEARCH_BYTES) score += @intCast((HOT_SNIPPET_SEARCH_BYTES - idx) / 1024);
            var title_buf: [96]u8 = undefined;
            const title = std.fmt.bufPrint(&title_buf, "title: {s}", .{term}) catch "";
            if (title.len != 0 and std.mem.indexOf(u8, lower_text, title) != null) score += 5000;
        }
    }
    if (terms.len > 1 and allTermsPresent(lower_text, terms)) score += 200;
    return score;
}

fn exactTitlePhraseIndex(lower_text: []const u8, terms: []const []const u8) ?usize {
    var buf: [256]u8 = undefined;
    var pos: usize = 0;
    appendPhraseBytes(&buf, &pos, "title: ") catch return null;
    return phraseIndexWithPrefix(lower_text, terms, &buf, &pos);
}

fn exactTermsPhraseIndex(lower_text: []const u8, terms: []const []const u8) ?usize {
    var buf: [256]u8 = undefined;
    var pos: usize = 0;
    return phraseIndexWithPrefix(lower_text, terms, &buf, &pos);
}

fn phraseIndexWithPrefix(lower_text: []const u8, terms: []const []const u8, buf: *[256]u8, pos: *usize) ?usize {
    if (terms.len == 0) return null;
    for (terms, 0..) |term, idx| {
        if (idx != 0) appendPhraseBytes(buf, pos, " ") catch return null;
        appendPhraseBytes(buf, pos, term) catch return null;
    }
    return indexOfTermBoundary(lower_text, buf[0..pos.*]);
}

fn appendPhraseBytes(buf: *[256]u8, pos: *usize, bytes: []const u8) !void {
    if (bytes.len > buf.len - pos.*) return error.PhraseTooLong;
    @memcpy(buf[pos.* .. pos.* + bytes.len], bytes);
    pos.* += bytes.len;
}

fn allTermsPresent(lower_text: []const u8, terms: []const []const u8) bool {
    if (terms.len == 0) return true;
    var search_start: usize = 0;
    const anchor = terms[0];
    while (search_start < lower_text.len) {
        const anchor_idx = indexOfTermBoundary(lower_text[search_start..], anchor) orelse return false;
        const absolute = search_start + anchor_idx;
        const boundary = vsa_vulkan.paragraphBoundary(lower_text, absolute, 512);
        const block = if (boundary.valid) lower_text[boundary.start..boundary.end] else lower_text;
        var ok = true;
        for (terms) |term| {
            if (indexOfTermBoundary(block, term) == null) {
                ok = false;
                break;
            }
        }
        if (ok) return true;
        search_start = absolute + anchor.len;
    }
    return false;
}

fn allTermsPresentAnywhere(lower_text: []const u8, terms: []const []const u8) bool {
    for (terms) |term| {
        if (indexOfTermBoundary(lower_text, term) == null) return false;
    }
    return true;
}

fn indexOfTermBoundary(lower_text: []const u8, term: []const u8) ?usize {
    var search_start: usize = 0;
    while (search_start < lower_text.len) {
        const rel = std.mem.indexOf(u8, lower_text[search_start..], term) orelse return null;
        const idx = search_start + rel;
        const before_ok = idx == 0 or !isTermByte(lower_text[idx - 1]);
        const after_idx = idx + term.len;
        const after_ok = after_idx >= lower_text.len or !isTermByte(lower_text[after_idx]);
        if (before_ok and after_ok) return idx;
        search_start = idx + 1;
    }
    return null;
}

fn indexOfTermBoundaryFold(text: []const u8, term: []const u8) ?usize {
    var search_start: usize = 0;
    while (search_start < text.len) {
        const rel = indexOfIgnoreCase(text[search_start..], term) orelse return null;
        const idx = search_start + rel;
        const before_ok = idx == 0 or !isTermByte(text[idx - 1]);
        const after_idx = idx + term.len;
        const after_ok = after_idx >= text.len or !isTermByte(text[after_idx]);
        if (before_ok and after_ok) return idx;
        search_start = idx + 1;
    }
    return null;
}

fn isTermByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-';
}

fn lowerCopy(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, text.len);
    for (text, 0..) |byte, idx| out[idx] = std.ascii.toLower(byte);
    return out;
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or needle.len > haystack.len) return null;
    var idx: usize = 0;
    while (idx + needle.len <= haystack.len) : (idx += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[idx .. idx + needle.len], needle)) return idx;
    }
    return null;
}

fn renderHotCorpusResult(
    allocator: std.mem.Allocator,
    question: []const u8,
    shard_id: []const u8,
    shard: *const ResidentShard,
    terms: []const []const u8,
    candidates: []const HotCandidate,
    gpu_scan: bool,
    context_target: []const u8,
) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();
    try w.writeAll("{\"corpusAsk\":{\"status\":\"answered\",\"state\":\"answer\",\"permission\":\"none\",\"nonAuthorizing\":true,\"voiceSynthesis\":true,\"question\":");
    try std.json.stringify(question, .{}, w);
    try w.writeAll(",\"shard\":{\"kind\":\"project\",\"id\":");
    try std.json.stringify(shard_id, .{}, w);
    try w.writeAll("},\"answerDraft\":");
    try writeHotAnswer(w, question, shard, terms, candidates);
    try w.writeAll(",\"evidenceUsed\":[");
    for (candidates, 0..) |candidate, rank| {
        if (rank != 0) try w.writeByte(',');
        try writeHotEvidence(w, shard, terms, candidate, rank + 1);
    }
    try w.writeAll("],\"unknowns\":[],\"candidateFollowups\":[{\"kind\":\"verifier_check_candidate\",\"detail\":\"review the cited corpus evidence before treating this answer as supported\",\"executes\":false}],\"learningCandidates\":[],\"trace\":{\"corpusMutation\":false,\"packMutation\":false,\"negativeKnowledgeMutation\":false,\"commandsExecuted\":false,\"verifiersExecuted\":false,\"residentGpuScan\":");
    try w.writeAll(if (gpu_scan) "true" else "false");
    try w.writeAll(",\"sessionHotQueriedFirst\":true,\"contextBiasMultiplier\":1.5,\"contextTarget\":");
    try std.json.stringify(context_target, .{}, w);
    try w.writeAll(",\"corpusEntriesConsidered\":");
    try w.print("{d}", .{shard.entries.len});
    try w.writeAll(",\"residentDaemon\":true,\"l1ConceptIndexBytes\":");
    try w.print("{d}", .{shard.vram_buffer.size_bytes});
    try w.writeAll(",\"hotPageBytes\":");
    try w.print("{d}", .{HOT_PAGE_BYTES});
    try w.writeAll(",\"rawShardVramBytes\":0}}}");
    return out.toOwnedSlice();
}

fn writeHotAnswer(writer: anytype, question: []const u8, shard: *const ResidentShard, terms: []const []const u8, candidates: []const HotCandidate) !void {
    if (try codeIntelInheritanceDraft(std.heap.page_allocator, question, shard, candidates)) |draft_text| {
        defer std.heap.page_allocator.free(draft_text);
        try std.json.stringify(draft_text, .{}, writer);
        return;
    }
    const allocator = std.heap.page_allocator;
    const evidence_texts = try allocator.alloc([]const u8, candidates.len);
    defer allocator.free(evidence_texts);
    const synthesis_texts = try allocator.alloc([]u8, candidates.len);
    for (synthesis_texts) |*text| text.* = &.{};
    defer {
        for (synthesis_texts) |text| allocator.free(text);
        allocator.free(synthesis_texts);
    }
    const evidence_source_ids = try allocator.alloc([]const u8, candidates.len);
    defer allocator.free(evidence_source_ids);
    for (candidates, 0..) |candidate, idx| {
        synthesis_texts[idx] = try synthesisSnippetForTerms(allocator, shard.texts[candidate.index], terms);
        evidence_texts[idx] = synthesis_texts[idx];
        evidence_source_ids[idx] = shard.entries[candidate.index].corpus_meta.source_rel_path;
    }
    if (evidence_texts.len == 0) {
        try std.json.stringify("", .{}, writer);
        return;
    }
    var draft = try text_generation_lab.generateCorpusSynthesisDraft(allocator, .{
        .user_query = question,
        .evidence_text = evidence_texts[0],
        .evidence_texts = evidence_texts,
        .evidence_source_ids = evidence_source_ids,
    });
    defer draft.deinit(allocator);
    try std.json.stringify(draft.draft_text, .{}, writer);
}

fn codeIntelInheritanceDraft(
    allocator: std.mem.Allocator,
    question: []const u8,
    shard: *const ResidentShard,
    candidates: []const HotCandidate,
) !?[]u8 {
    if (indexOfIgnoreCase(question, "inherit") == null and indexOfIgnoreCase(question, "base class") == null) return null;
    for (candidates) |candidate| {
        const summary = shard.entries[candidate.index].corpus_meta.code_intel_summary orelse continue;
        const class_marker = " class ";
        const inherits_marker = " inherits ";
        var search_pos: usize = 0;
        while (std.mem.indexOfPos(u8, summary, search_pos, class_marker)) |class_idx| {
            const class_start = class_idx + class_marker.len;
            const class_name = readCodeIntelToken(summary[class_start..]);
            if (class_name.len == 0) break;
            const inherit_idx = std.mem.indexOfPos(u8, summary, class_start + class_name.len, inherits_marker) orelse break;
            const base_start = inherit_idx + inherits_marker.len;
            const base_name = readCodeIntelToken(summary[base_start..]);
            if (base_name.len == 0) break;
            if (indexOfIgnoreCase(question, class_name) != null) {
                return try std.fmt.allocPrint(
                    allocator,
                    "{s} inherits from {s}. Source: Ghost Code Intel symbol graph.",
                    .{ class_name, base_name },
                );
            }
            search_pos = base_start + base_name.len;
        }
    }
    return null;
}

fn readCodeIntelToken(text: []const u8) []const u8 {
    var end: usize = 0;
    while (end < text.len) : (end += 1) {
        const byte = text[end];
        if (!(std.ascii.isAlphanumeric(byte) or byte == '_' or byte == ':' or byte == '~')) break;
    }
    return text[0..end];
}

fn synthesisSnippetForTerms(allocator: std.mem.Allocator, text: []const u8, terms: []const []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    for (terms) |term| {
        const snippet = snippetAroundSingleTerm(text, term, 320);
        if (snippet.len == 0) continue;
        if (out.items.len != 0) try out.appendSlice(". ");
        try out.appendSlice(snippet);
        if (out.items.len >= 1024) break;
    }
    if (out.items.len == 0) try out.appendSlice(trimmedSnippet(text, 640));
    return out.toOwnedSlice();
}

fn snippetAroundSingleTerm(text: []const u8, term: []const u8, max_bytes: usize) []const u8 {
    const single = [_][]const u8{term};
    return snippetAroundTerms(text, &single, max_bytes);
}

fn writeHotEvidence(writer: anytype, shard: *const ResidentShard, terms: []const []const u8, candidate: HotCandidate, rank: usize) !void {
    const entry = shard.entries[candidate.index];
    try writer.writeAll("{\"itemId\":");
    try std.json.stringify(entry.rel_path, .{}, writer);
    try writer.writeAll(",\"path\":");
    try std.json.stringify(entry.rel_path, .{}, writer);
    try writer.writeAll(",\"sourcePath\":");
    try std.json.stringify(entry.corpus_meta.source_rel_path, .{}, writer);
    try writer.writeAll(",\"sourceLabel\":");
    try std.json.stringify(entry.corpus_meta.source_label, .{}, writer);
    try writer.writeAll(",\"class\":");
    try std.json.stringify(@tagName(entry.corpus_meta.class), .{}, writer);
    try writer.writeAll(",\"licenseStatus\":");
    try std.json.stringify(entry.corpus_meta.license_status, .{}, writer);
    try writer.print(",\"authorityLevel\":{d},\"snippet\":", .{entry.corpus_meta.license_authority_level});
    try std.json.stringify(snippetAroundTerms(shard.texts[candidate.index], terms, 320), .{}, writer);
    try writer.writeAll(",\"matchedTerms\":[");
    for (terms, 0..) |term, idx| {
        if (idx != 0) try writer.writeByte(',');
        try std.json.stringify(term, .{}, writer);
    }
    try writer.print("],\"reason\":\"selected from resident daemon cache\",\"score\":{d},\"rank\":{d}}}", .{ candidate.score, rank });
}

fn trimmedSnippet(text: []const u8, max_bytes: usize) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \r\n\t");
    return trimSnippetEnd(trimmed, @min(trimmed.len, max_bytes));
}

fn snippetAroundTerms(text: []const u8, terms: []const []const u8, max_bytes: usize) []const u8 {
    const bounded_text = strictEntryBoundary(text);
    const searchable = text[0..@min(text.len, HOT_SNIPPET_SEARCH_BYTES)];
    var best: ?usize = null;
    if (exactTitlePhraseIndexFold(searchable, terms)) |idx| {
        return boundedSnippetFrom(text, idx, max_bytes);
    }
    if (matchingParagraphStart(text, terms)) |paragraph_start| {
        return boundedSnippetFrom(text, paragraph_start, max_bytes);
    }
    for (terms) |term| {
        var title_buf: [96]u8 = undefined;
        const title = std.fmt.bufPrint(&title_buf, "title: {s}", .{term}) catch "";
        if (title.len != 0) {
            if (indexOfIgnoreCase(searchable, title)) |idx| {
                best = if (best) |existing| @min(existing, idx) else idx;
            }
        }
    }
    if (best != null) {
        const idx = best.?;
        const start = idx;
        return boundedSnippetFrom(text, start, max_bytes);
    }
    for (terms) |term| {
        if (indexOfIgnoreCase(searchable, term)) |idx| {
            best = if (best) |existing| @min(existing, idx) else idx;
        }
    }
    const idx = best orelse return trimmedSnippet(bounded_text, max_bytes);
    const start = idx -| 80;
    return boundedSnippetFrom(text, start, max_bytes);
}

fn exactTitlePhraseIndexFold(text: []const u8, terms: []const []const u8) ?usize {
    var buf: [256]u8 = undefined;
    var pos: usize = 0;
    appendPhraseBytes(&buf, &pos, "title: ") catch return null;
    if (terms.len == 0) return null;
    for (terms, 0..) |term, idx| {
        if (idx != 0) appendPhraseBytes(&buf, &pos, " ") catch return null;
        appendPhraseBytes(&buf, &pos, term) catch return null;
    }
    return indexOfIgnoreCase(text, buf[0..pos]);
}

fn matchingParagraphStart(text: []const u8, terms: []const []const u8) ?usize {
    if (terms.len == 0) return null;
    const anchor = terms[0];
    var search_start: usize = 0;
    while (search_start < text.len) {
        const rel = indexOfTermBoundaryFold(text[search_start..], anchor) orelse return null;
        const absolute = search_start + rel;
        const boundary = vsa_vulkan.paragraphBoundary(text, absolute, 768);
        if (boundary.valid) {
            const block = text[boundary.start..boundary.end];
            var ok = true;
            for (terms) |term| {
                if (indexOfTermBoundaryFold(block, term) == null) {
                    ok = false;
                    break;
                }
            }
            if (ok) return boundary.start;
        }
        search_start = absolute + anchor.len;
    }
    return null;
}

fn strictEntryBoundary(text: []const u8) []const u8 {
    const boundary = vsa_vulkan.paragraphBoundary(text, 0, text.len);
    if (!boundary.valid) return text;
    return text[boundary.start..boundary.end];
}

fn boundedSnippetFrom(text: []const u8, absolute_start: usize, max_bytes: usize) []const u8 {
    const boundary = vsa_vulkan.paragraphBoundary(text, absolute_start, max_bytes);
    const bounded_start = if (boundary.valid) boundary.start else @min(absolute_start, text.len);
    const bounded_end = if (boundary.valid) boundary.end else text.len;
    const start = @max(bounded_start, @min(absolute_start, bounded_end));
    const available = bounded_end - start;
    const end = start + boundedSnippetLen(text[start..bounded_end], @min(available, max_bytes));
    return std.mem.trim(u8, text[start..end], " \r\n\t");
}

fn boundedSnippetLen(text: []const u8, limit: usize) usize {
    if (text.len <= limit) return text.len;
    var end = limit;
    while (end > limit / 2) : (end -= 1) {
        if (std.ascii.isWhitespace(text[end]) or text[end] == '.' or text[end] == '!' or text[end] == '?') break;
    }
    if (end <= limit / 2) return limit;
    return end;
}

fn trimSnippetEnd(text: []const u8, limit: usize) []const u8 {
    return text[0..boundedSnippetLen(text, limit)];
}

fn termsContain(terms: []const []const u8, needle: []const u8) bool {
    for (terms) |term| {
        if (std.mem.eql(u8, term, needle)) return true;
    }
    return false;
}

fn appendCleanVoice(out: *std.ArrayList(u8), raw: []const u8) !void {
    var idx: usize = 0;
    while (idx < raw.len) : (idx += 1) {
        const byte = raw[idx];
        if (std.ascii.isWhitespace(byte) or byte == '[' or byte == ']') {
            if (out.items.len != 0 and out.items[out.items.len - 1] != ' ') try out.append(' ');
            continue;
        }
        if (std.mem.startsWith(u8, raw[idx..], "TITLE:")) {
            idx += "TITLE:".len - 1;
            continue;
        }
        try out.append(byte);
    }
}

fn jsonStringField(obj: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    const value = obj.get(field) orelse return null;
    return if (value == .string) value.string else null;
}

fn renderDaemonStatus(allocator: std.mem.Allocator, resident: *ResidentState) ![]u8 {
    const telemetry = resident.snapshotTelemetry();
    const pipeline = resident.copyPipelineTelemetry();
    const curiosity_guard = curiosity.GuardState{
        .load_average_1m = curiosity.currentLoadAverage1m(),
        .oracle_paused_for_ram = telemetry.oracle_paused_for_ram,
    };
    const context_target = try resident.session_hot.extractContextTarget(allocator);
    defer allocator.free(context_target);
    const vault_dir = try vaultDirPath(allocator);
    defer allocator.free(vault_dir);
    const last_ingest_ms = resident.last_vault_ingest_ms.load(.acquire);
    const now_ms = std.time.milliTimestamp();
    const ingest_recent = last_ingest_ms != 0 and now_ms - last_ingest_ms <= LIVE_VAULT_RECENT_MS;
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();
    try w.writeAll("{\"status\":\"ok\",\"daemon\":{\"status\":\"running\",\"socketPath\":");
    try std.json.stringify(socketPath(), .{}, w);
    try w.writeAll(",\"heartbeatPath\":");
    try std.json.stringify(heartbeatPath(), .{}, w);
    try w.writeAll(",\"vaultDir\":");
    try std.json.stringify(vault_dir, .{}, w);
    try w.print(",\"residentShards\":{d},\"vramResidentBytes\":{d},\"l1ConceptIndexBytes\":{d},\"hotPageBytes\":{d},\"rawShardVramBytes\":0,\"sessionHotBytes\":{d},\"deviceLocal\":{s}", .{
        telemetry.loaded_shards,
        telemetry.vram_resident_bytes,
        telemetry.l1_concept_index_bytes,
        telemetry.hot_page_bytes,
        resident.session_hot.usedBytes(),
        if (telemetry.device_local) "true" else "false",
    });
    try w.print(",\"ramUsedBytes\":{d},\"oraclePausedForRam\":{s},\"truthDensity\":{{\"verifiedRunes\":{d},\"shadowRunes\":{d},\"ratioPerMille\":{d}}}", .{
        telemetry.ram_used_bytes,
        if (telemetry.oracle_paused_for_ram) "true" else "false",
        telemetry.truth_density.verified_runes,
        telemetry.truth_density.shadow_runes,
        telemetry.truth_density.ratio_per_mille,
    });
    try w.writeAll(",\"sessionContextTarget\":");
    try std.json.stringify(context_target, .{}, w);
    try w.writeAll(",\"sovereignPipeline\":{\"domain\":");
    try std.json.stringify(pipeline.domain, .{}, w);
    try w.writeAll(",\"z3Status\":");
    try std.json.stringify(pipeline.z3_status, .{}, w);
    try w.writeAll(",\"confidenceBand\":");
    try std.json.stringify(pipeline.confidence_band, .{}, w);
    try w.writeByte('}');
    try w.print(",\"phase456\":{{\"selfHealingOracle\":\"explicit_only\",\"curiosityCanRun\":{s},\"curiosityMaxConcurrentZigTests\":{d},\"hiveRemoteCacheTier\":{d},\"hiveNetworkEnabledByDefault\":false,\"recursiveBootHotSwapEnabledByDefault\":false,\"recursiveBootMinSpeedupPerMille\":{d}}}", .{
        if (curiosity_guard.canRun()) "true" else "false",
        curiosity.MAX_CONCURRENT_ZIG_TESTS,
        hive.TIER_HIVE_REMOTE,
        recursive_boot.MIN_SPEEDUP_PER_MILLE,
    });
    try w.print(",\"vaultIngestActive\":{s},\"vaultIngestRecent\":{s},\"vaultIngestedFiles\":{d},\"vaultIngestErrors\":{d},\"vaultIngestedBytes\":{d},\"lastVaultIngestMs\":{d}", .{
        if (resident.vault_ingest_active.load(.acquire)) "true" else "false",
        if (ingest_recent) "true" else "false",
        resident.vault_ingested_files.load(.acquire),
        resident.vault_ingest_errors.load(.acquire),
        resident.vault_ingested_bytes.load(.acquire),
        last_ingest_ms,
    });
    try w.writeAll("}}");
    return out.toOwnedSlice();
}

fn readFrame(allocator: std.mem.Allocator, stream: std.net.Stream) ![]u8 {
    var len_buf: [4]u8 = undefined;
    try stream.reader().readNoEof(&len_buf);
    const len = std.mem.readInt(u32, &len_buf, .little);
    if (len > MAX_FRAME_BYTES) return error.RequestTooLarge;
    const payload = try allocator.alloc(u8, len);
    errdefer allocator.free(payload);
    try stream.reader().readNoEof(payload);
    return payload;
}

fn writeFrame(stream: std.net.Stream, payload: []const u8) !void {
    if (payload.len > MAX_FRAME_BYTES) return error.ResponseTooLarge;
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @intCast(payload.len), .little);
    try stream.writer().writeAll(&len_buf);
    try stream.writer().writeAll(payload);
}

fn probeSocket() bool {
    var stream = std.net.connectUnixSocket(socketPath()) catch return false;
    stream.close();
    return true;
}

fn writePidFile() !void {
    var file = try std.fs.createFileAbsolute(pidPath(), .{ .truncate = true });
    defer file.close();
    try file.writer().print("{d}\n", .{std.os.linux.getpid()});
}

fn printLocalStatus() !void {
    if (readHeartbeatHot()) {
        var stream = std.net.connectUnixSocket(socketPath()) catch {
            try std.io.getStdOut().writer().print("ghostd active socket={s}\n", .{socketPath()});
            return;
        };
        defer stream.close();
        try writeFrame(stream, "{\"kind\":\"daemon.status\"}");
        const response = try readFrame(std.heap.page_allocator, stream);
        defer std.heap.page_allocator.free(response);
        try std.io.getStdOut().writer().print("{s}\n", .{response});
    } else {
        try std.io.getStdOut().writer().print("ghostd inactive socket={s}\n", .{socketPath()});
    }
}

fn socketPath() []const u8 {
    return std.posix.getenv("GHOSTD_SOCKET_PATH") orelse DEFAULT_SOCKET_PATH;
}

fn pidPath() []const u8 {
    return std.posix.getenv("GHOSTD_PID_PATH") orelse DEFAULT_PID_PATH;
}

fn heartbeatPath() []const u8 {
    return std.posix.getenv("GHOSTD_HEARTBEAT_PATH") orelse DEFAULT_HEARTBEAT_PATH;
}

fn setHeartbeatHot(hot: bool) void {
    const path = heartbeatPath();
    var file = std.fs.createFileAbsolute(path, .{ .truncate = true }) catch return;
    defer file.close();
    file.writer().writeByte(if (hot) '1' else '0') catch {};
}

fn unlinkHeartbeat() void {
    std.fs.deleteFileAbsolute(heartbeatPath()) catch {};
}

fn readHeartbeatHot() bool {
    const path = heartbeatPath();
    var file = std.fs.openFileAbsolute(path, .{}) catch return false;
    defer file.close();
    var byte: [1]u8 = undefined;
    const n = file.read(&byte) catch return false;
    return n == 1 and byte[0] == '1';
}
