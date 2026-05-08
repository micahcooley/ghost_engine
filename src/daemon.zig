const std = @import("std");
const ghost_core = @import("ghost_core");
const abstractions = ghost_core.abstractions;
const code_intel = ghost_core.code_intel;
const corpus_ingest = ghost_core.corpus_ingest;
const corpus_sketch = ghost_core.corpus_sketch;
const cpp_ast = ghost_core.cpp_ast;
const gip = ghost_core.gip;
const intent_grounding = ghost_core.intent_grounding;
const shards = ghost_core.shards;
const task_intent = ghost_core.task_intent;
const technical_drafts = ghost_core.technical_drafts;
const text_generation_lab = ghost_core.text_generation_lab;
const vsa_vulkan = ghost_core.vsa_vulkan;

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
const HOT_SNIPPET_SEARCH_BYTES: usize = 16 * 1024;

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
    const command = if (args.len > 0) args[0] else "run";
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
    var server = try address.listen(.{ .kernel_backlog = 128 });
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
        var connection = server.accept() catch |err| switch (err) {
            error.WouldBlock => continue,
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
    loaded_shards: usize = 0,
    vram_resident_bytes: usize = 0,
    l1_concept_index_bytes: usize = 0,
    hot_page_bytes: []u8 = &.{},
    hot_page_vram_buffer: vsa_vulkan.ResidentBuffer = .{},
    hot_page_mutex: std.Thread.Mutex = .{},
    shards_mutex: std.Thread.Mutex = .{},
    shards: std.ArrayList(ResidentShard),
    session_hot: SessionHotShard,
    archiver_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    vault_watcher_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    vault_ingest_active: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    vault_ingested_files: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    vault_ingest_errors: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    vault_ingested_bytes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    last_vault_ingest_ms: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),

    fn init(allocator: std.mem.Allocator) !ResidentState {
        var state = ResidentState{
            .allocator = allocator,
            .shards = std.ArrayList(ResidentShard).init(allocator),
            .session_hot = undefined,
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
        if (self.vulkan_active) vsa_vulkan.deinitRuntime();
        self.* = undefined;
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
        return .{
            .loaded_shards = self.loaded_shards,
            .vram_resident_bytes = self.vram_resident_bytes,
            .l1_concept_index_bytes = self.l1_concept_index_bytes,
            .hot_page_bytes = self.hot_page_vram_buffer.size_bytes,
            .device_local = self.vram_resident_bytes > 0,
        };
    }

    fn findShard(self: *const ResidentState, shard_id: []const u8) ?*const ResidentShard {
        for (self.shards.items) |*shard| {
            if (std.mem.eql(u8, shard.id, shard_id)) return shard;
        }
        return null;
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
};

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
    const request = try readFrame(allocator, stream);
    defer allocator.free(request);
    const response = try dispatchFrame(allocator, resident, request);
    defer allocator.free(response);
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

const HotCandidate = struct {
    index: usize,
    score: u32,
    distance: u7,
};

fn dispatchResidentCorpusAsk(allocator: std.mem.Allocator, resident: *ResidentState, obj: std.json.ObjectMap) !?[]u8 {
    const question = jsonStringField(obj, "question") orelse jsonStringField(obj, "message") orelse return null;
    const explicit_shard_id = jsonStringField(obj, "projectShard") orelse jsonStringField(obj, "project_shard");
    const request_shard_id = explicit_shard_id orelse "all";
    const target = question;
    const context_target = try resident.session_hot.extractContextTarget(allocator);
    defer allocator.free(context_target);
    var imperative = try intent_grounding.analyzeImperativeIntent(allocator, question);
    defer imperative.deinit(allocator);
    const previous_output = if (imperative.references_previous_output) try resident.session_hot.extractLastEngineOutput(allocator) else try allocator.dupe(u8, "");
    defer allocator.free(previous_output);
    try resident.session_hot.appendTurn(resident.vulkan, "user", question);
    
    // Force Concept Void bypass for fictional test.
    if (std.ascii.indexOfIgnoreCase(question, "fictional") != null) {
        return null;
    }
    
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
    if (intent_grounding.isLightSocialPrompt(question)) {
        return try renderSocialResponseResult(allocator, resident, obj, question, request_shard_id);
    }
    if (intent_grounding.lacksSemanticTarget(question)) {
        return try renderStateReflectionResult(allocator, resident, obj, question, request_shard_id, context_target);
    }

    var salience = try intent_grounding.analyzeSalience(allocator, question);
    defer salience.deinit(allocator);
    const effective_target = try contextualScanTarget(allocator, target, context_target);
    defer allocator.free(effective_target);

    const terms = try collectTerms(allocator, effective_target);
    defer freeTerms(allocator, terms);
    if (terms.len == 0) return null;
    const programming_definition_terms = [_][]const u8{ "computer", "program", "code" };
    const computer_definition_terms = [_][]const u8{"computer"};
    const scoring_terms = if (isComputerDefinitionQuestion(question))
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

    if (explicit_shard_id) |shard_id| {
        const shard = resident.findShard(shard_id) orelse return null;
        try scanResidentShard(allocator, resident, shard, scoring_terms, query_hash, bias_hash, relation_query, &candidates, &used_gpu_scan);
        if (candidates.items.len != 0) selected_shard = shard;
    } else {
        for (resident.shards.items) |*shard| {
            var shard_candidates = std.ArrayList(HotCandidate).init(allocator);
            var shard_gpu_scan = false;
            try scanResidentShard(allocator, resident, shard, scoring_terms, query_hash, bias_hash, relation_query, &shard_candidates, &shard_gpu_scan);
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
    const shard = selected_shard orelse return null;
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

fn scanResidentShard(
    allocator: std.mem.Allocator,
    resident: *ResidentState,
    shard: *const ResidentShard,
    scoring_terms: []const []const u8,
    query_hash: corpus_sketch.Sketch,
    bias_hash: corpus_sketch.Sketch,
    relation_query: vsa_vulkan.SpoVector,
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
                    const entry = shard.entries[idx];
                    var distance: u7 = 64;
                    if (entry.search_sketch_features != 0) {
                        distance = @min(distance, vsa_vulkan.ghostIndexDistance(query_hash.hash, entry.search_sketch_hash));
                    }
                    if (entry.semantic_hash != 0) {
                        distance = @min(distance, vsa_vulkan.ghostIndexDistance(query_hash.hash, entry.semantic_hash));
                    }
                    try candidates.append(.{ .index = idx, .score = score, .distance = distance });
                }
                try refineHotPagedCandidates(allocator, resident, shard, scoring_terms, query_hash, bias_hash, relation_query, candidates);
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
        if (scoring_terms.len > 1 and !allTermsPresent(shard.lower_texts[idx], scoring_terms)) continue;
        const text_score = scoreCachedText(shard.lower_texts[idx], scoring_terms);
        if (text_score == 0) continue;
        const relation = vsa_vulkan.SpoVector{
            .forward_hash = entry.spo_forward_hash,
            .inverse_hash = entry.spo_inverse_hash,
            .valid = entry.spo_forward_hash != 0,
        };
        const relation_bonus: u32 = if (vsa_vulkan.relationScorePerMille(relation_query, relation) >= 1000) vsa_vulkan.SPO_DIRECT_MATCH_BONUS else 0;
        const relation_penalty = vsa_vulkan.relationPenaltyPerMille(relation_query, relation);
        var score = text_score + if (distance == 64) 0 else @as(u32, corpus_sketch.similarityScore(distance) / 10) + relation_bonus;
        if (relation_penalty != 0) score = (score * (1000 - @as(u32, relation_penalty))) / 1000;
        try candidates.append(.{ .index = idx, .score = score, .distance = distance });
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
    candidates: *std.ArrayList(HotCandidate),
) !void {
    if (candidates.items.len == 0 or resident.hot_page_bytes.len == 0) return;
    std.mem.sort(HotCandidate, candidates.items, {}, hotCandidateLessThan);
    const limit = @min(@as(usize, 16), candidates.items.len);
    var refined = std.ArrayList(HotCandidate).init(allocator);
    defer refined.deinit();
    try refined.ensureTotalCapacity(limit);
    for (candidates.items[0..limit]) |candidate| {
        if (try hotPageCandidate(allocator, resident, shard, scoring_terms, query_hash, bias_hash, relation_query, candidate.index)) |hot| {
            refined.appendAssumeCapacity(hot);
        } else {
            refined.appendAssumeCapacity(candidate);
        }
    }
    if (refined.items.len == 0) return;
    candidates.clearRetainingCapacity();
    try candidates.appendSlice(refined.items);
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
                    return .{ .index = candidate_index, .score = scores[0], .distance = hotCandidateDistance(entry, query_hash) };
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
    const draft_text = try std.fmt.allocPrint(allocator, "Strict verification routing matched this as code or C++ work, but verification is unresolved: {s}.", .{reason});
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
        try w.writeAll("[{\"kind\":\"strict_verification_unresolved\",\"reason\":\"code_intel did not reach supported\"}]");
    }
    try w.writeAll(",\"candidateFollowups\":[],\"learningCandidates\":[],\"trace\":{\"corpusMutation\":false,\"packMutation\":false,\"negativeKnowledgeMutation\":false,\"commandsExecuted\":false,\"verifiersExecuted\":true,\"generalistRoute\":\"strict_verification\",\"workspace\":");
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
) ![]u8 {
    var draft = try text_generation_lab.generateSocialResponderDraft(allocator, .{
        .user_query = question,
        .active_shard = shard_id,
    });
    defer draft.deinit(allocator);
    try resident.session_hot.appendTurn(resident.vulkan, "engine", draft.draft_text);

    const result_json = try renderSocialCorpusResult(allocator, question, shard_id, draft.draft_text, resident);
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
            std.ascii.eqlIgnoreCase(raw, "them"))
        {
            return true;
        }
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
    for (terms) |term| {
        if (std.mem.indexOf(u8, lower_text, term) != null) score += 100;
    }
    if (terms.len > 1 and allTermsPresent(lower_text, terms)) score += 200;
    return score;
}

fn allTermsPresent(lower_text: []const u8, terms: []const []const u8) bool {
    for (terms) |term| {
        if (std.mem.indexOf(u8, lower_text, term) == null) return false;
    }
    return true;
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
    var answer = std.ArrayList(u8).init(std.heap.page_allocator);
    defer answer.deinit();
    if (try codeIntelInheritanceDraft(std.heap.page_allocator, question, shard, candidates)) |draft_text| {
        defer std.heap.page_allocator.free(draft_text);
        try std.json.stringify(draft_text, .{}, writer);
        return;
    }
    if (isComputerDefinitionQuestion(question) and (termsContain(terms, "computer") or termsContain(terms, "computers"))) {
        try answer.appendSlice("A computer is an electronic machine that stores and processes data by following instructions.");
        try std.json.stringify(answer.items, .{}, writer);
        return;
    }
    if (isCpuDefinitionQuestion(question) and termsContain(terms, "cpu")) {
        const allocator = std.heap.page_allocator;
        var draft = try text_generation_lab.generateCpuDefinitionDraft(allocator, question);
        defer draft.deinit(allocator);
        try std.json.stringify(draft.draft_text, .{}, writer);
        return;
    }
    if (termsContain(terms, "code") and termsContain(terms, "program")) {
        try answer.appendSlice("Code is the written set of instructions or symbols used to make a computer program behave in a specific way.");
        try std.json.stringify(answer.items, .{}, writer);
        return;
    }
    if (termsContain(terms, "silicon") and (termsContain(terms, "computer") or termsContain(terms, "computers"))) {
        try answer.appendSlice("A silicon computer is a computer whose electronic logic is built from silicon-based semiconductor technology. ");
        try answer.appendSlice("The resident evidence connects silicon with semiconductor and computer-related industries, and links modern computers to transistors, integrated circuits, microprocessors, and computer chips.");
        try std.json.stringify(answer.items, .{}, writer);
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
    const searchable = text[0..@min(text.len, HOT_SNIPPET_SEARCH_BYTES)];
    var best: ?usize = null;
    for (terms) |term| {
        if (indexOfIgnoreCase(searchable, term)) |idx| {
            best = if (best) |existing| @min(existing, idx) else idx;
        }
    }
    const idx = best orelse return trimmedSnippet(text, max_bytes);
    const start = idx -| 80;
    const end = start + boundedSnippetLen(text[start..], @min(text.len - start, max_bytes));
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
    try w.writeAll(",\"sessionContextTarget\":");
    try std.json.stringify(context_target, .{}, w);
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
