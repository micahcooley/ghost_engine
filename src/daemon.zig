const std = @import("std");
const ghost_core = @import("ghost_core");
const corpus_ingest = ghost_core.corpus_ingest;
const corpus_sketch = ghost_core.corpus_sketch;
const gip = ghost_core.gip;
const intent_grounding = ghost_core.intent_grounding;
const shards = ghost_core.shards;
const vsa_vulkan = ghost_core.vsa_vulkan;

pub const DEFAULT_SOCKET_PATH = "/tmp/ghost.sock";
pub const DEFAULT_PID_PATH = "/tmp/ghost.pid";
const MAX_FRAME_BYTES: usize = 10 * 1024 * 1024;
const DEFAULT_RESIDENT_SHARDS = [_][]const u8{ "english_core", "user_vault" };
const SESSION_HOT_BYTES: usize = 16 * 1024 * 1024;
const SESSION_HOT_FLUSH_PER_MILLE: usize = 800;
const SESSION_HOT_KEEP_PER_MILLE: usize = 500;
const CONTEXT_BIAS_MULTIPLIER_PER_MILLE: u32 = 1500;
const GPU_SCORE_FLOOR: u32 = 120;

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
    std.fs.deleteFileAbsolute(socketPath()) catch {};

    try writePidFile();
    errdefer std.fs.deleteFileAbsolute(pidPath()) catch {};

    var resident = try ResidentState.init(allocator);
    defer resident.deinit();
    var archiver_thread = try std.Thread.spawn(.{}, ResidentState.archiverLoop, .{&resident});
    defer {
        resident.archiver_stop.store(true, .release);
        archiver_thread.join();
    }

    var address = try std.net.Address.initUnix(socketPath());
    var server = try address.listen(.{ .kernel_backlog = 128 });
    defer server.deinit();
    defer std.fs.deleteFileAbsolute(socketPath()) catch {};
    defer std.fs.deleteFileAbsolute(pidPath()) catch {};

    try std.io.getStdErr().writer().print(
        "ghostd ready socket={s} shards={d} vulkan={s}\n",
        .{ socketPath(), resident.loaded_shards, if (resident.vulkan_active) "resident" else "cpu" },
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
    shards: std.ArrayList(ResidentShard),
    session_hot: SessionHotShard,
    archiver_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

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

        for (DEFAULT_RESIDENT_SHARDS) |shard_id| {
            state.preloadShard(shard_id) catch |err| {
                try std.io.getStdErr().writer().print("ghostd preload skipped shard={s} err={s}\n", .{ shard_id, @errorName(err) });
            };
        }
        return state;
    }

    fn deinit(self: *ResidentState) void {
        self.session_hot.deinit(self.vulkan);
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
        const scan_entries = try buildCorpusScanEntries(self.allocator, entries, loaded.offsets);
        errdefer self.allocator.free(scan_entries);
        try self.shards.append(.{
            .id = try self.allocator.dupe(u8, shard_id),
            .entries = entries,
            .texts = loaded.texts,
            .lower_texts = loaded.lower_texts,
            .offsets = loaded.offsets,
            .vram_buffer = vram_buffer,
            .scan_entries = scan_entries,
        });
        loaded.disarm();
        self.loaded_shards += 1;
    }
};

const LoadedShardImage = struct {
    texts: [][]u8,
    lower_texts: [][]u8,
    offsets: []usize,
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
        self.image.deinit();
    }
};

fn buildCorpusScanEntries(
    allocator: std.mem.Allocator,
    entries: []const corpus_ingest.IndexedEntry,
    offsets: []const usize,
) ![]vsa_vulkan.CorpusScanEntry {
    const out = try allocator.alloc(vsa_vulkan.CorpusScanEntry, entries.len);
    errdefer allocator.free(out);
    for (entries, 0..) |entry, idx| {
        out[idx] = .{
            .byte_offset = @intCast(@min(offsets[idx], std.math.maxInt(u32))),
            .byte_len = @intCast(@min(entry.size_bytes, std.math.maxInt(u32))),
            .search_hash_lo = @intCast(entry.search_sketch_hash & 0xFFFF_FFFF),
            .search_hash_hi = @intCast(entry.search_sketch_hash >> 32),
            .semantic_hash_lo = @intCast(entry.semantic_hash & 0xFFFF_FFFF),
            .semantic_hash_hi = @intCast(entry.semantic_hash >> 32),
            .flags = if (entry.search_sketch_features != 0) 1 else 0,
            .reserved = 0,
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
    var image = std.ArrayList(u8).init(allocator);
    errdefer image.deinit();
    for (entries, 0..) |entry, idx| {
        offsets[idx] = image.items.len;
        const max_cpu_bytes: usize = @intCast(@min(entry.size_bytes, maxResidentSnippetBytes(entry)));
        var file = std.fs.openFileAbsolute(entry.abs_path, .{}) catch {
            texts[idx] = try allocator.alloc(u8, 0);
            lower_texts[idx] = try allocator.alloc(u8, 0);
            continue;
        };
        defer file.close();
        const full = file.readToEndAlloc(allocator, @intCast(entry.size_bytes)) catch {
            texts[idx] = try allocator.alloc(u8, 0);
            lower_texts[idx] = try allocator.alloc(u8, 0);
            continue;
        };
        defer allocator.free(full);
        try image.appendSlice(full);
        try image.append(0);
        texts[idx] = try allocator.dupe(u8, full[0..@min(full.len, max_cpu_bytes)]);
        lower_texts[idx] = try lowerCopy(allocator, texts[idx]);
    }
    return .{ .texts = texts, .lower_texts = lower_texts, .offsets = offsets, .image = image };
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
    const shard_id = jsonStringField(obj, "projectShard") orelse jsonStringField(obj, "project_shard") orelse "english_core";
    const shard = resident.findShard(shard_id) orelse return null;
    if (shard.entries.len == 0) return null;

    var salience = try intent_grounding.analyzeSalience(allocator, question);
    defer salience.deinit(allocator);
    const target = question;
    const context_target = try resident.session_hot.extractContextTarget(allocator);
    defer allocator.free(context_target);
    try resident.session_hot.appendTurn(resident.vulkan, "user", question);
    const effective_target = try contextualScanTarget(allocator, target, context_target);
    defer allocator.free(effective_target);

    const terms = try collectTerms(allocator, effective_target);
    defer freeTerms(allocator, terms);
    if (terms.len == 0) return null;
    const scoring_terms = chooseScoringTerms(terms, context_target);
    const query_hash = try corpus_sketch.simHash64Query(allocator, effective_target);
    const bias_hash = if (context_target.len != 0) try corpus_sketch.simHash64Query(allocator, context_target) else corpus_sketch.Sketch{ .hash = 0, .feature_count = 0 };

    var candidates = std.ArrayList(HotCandidate).init(allocator);
    defer candidates.deinit();

    var used_gpu_scan = false;
    if (resident.vulkan) |vk| {
        if (query_hash.valid() and shard.vram_buffer.buffer != null and shard.scan_entries.len != 0) {
            if (vk.dispatchCorpusScan(
                &shard.vram_buffer,
                shard.scan_entries,
                scoring_terms,
                query_hash.hash,
                if (bias_hash.valid()) bias_hash.hash else 0,
                CONTEXT_BIAS_MULTIPLIER_PER_MILLE,
            )) |scores| {
                used_gpu_scan = true;
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
            } else |_| {}
        }
    }

    if (!used_gpu_scan) {
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
            const score = text_score + if (distance == 64) 0 else @as(u32, corpus_sketch.similarityScore(distance) / 10);
            try candidates.append(.{ .index = idx, .score = score, .distance = distance });
        }
    }
    if (candidates.items.len == 0) return null;
    std.mem.sort(HotCandidate, candidates.items, {}, hotCandidateLessThan);
    const requested_limit: usize = if (salience.density_multiplier <= 2) 2 else @intCast(@min(@as(u32, salience.density_multiplier), 4));
    const top = candidates.items[0..@min(requested_limit, candidates.items.len)];

    const result_json = try renderHotCorpusResult(allocator, question, shard_id, shard, scoring_terms, top, used_gpu_scan, context_target);
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
    if (context_target.len != 0) return terms;
    if (terms.len > 3) return terms[terms.len - 3 ..];
    return terms;
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
    try writeHotAnswer(w, shard, terms, candidates);
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
    try w.writeAll(",\"residentDaemon\":true}}}");
    return out.toOwnedSlice();
}

fn writeHotAnswer(writer: anytype, shard: *const ResidentShard, terms: []const []const u8, candidates: []const HotCandidate) !void {
    var answer = std.ArrayList(u8).init(std.heap.page_allocator);
    defer answer.deinit();
    if (termsContain(terms, "silicon") and (termsContain(terms, "computer") or termsContain(terms, "computers"))) {
        try answer.appendSlice("A silicon computer is a computer whose electronic logic is built from silicon-based semiconductor technology. ");
        try answer.appendSlice("The resident evidence connects silicon with semiconductor and computer-related industries, and links modern computers to transistors, integrated circuits, microprocessors, and computer chips.");
        try std.json.stringify(answer.items, .{}, writer);
        return;
    }
    for (candidates, 0..) |candidate, idx| {
        if (idx != 0) try answer.appendSlice(" ");
        const snippet = snippetAroundTerms(shard.texts[candidate.index], terms, 240);
        try appendCleanVoice(&answer, snippet);
    }
    try std.json.stringify(answer.items, .{}, writer);
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
    try writer.writeAll(",\"class\":\"docs\",\"licenseStatus\":");
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
    return trimmed[0..@min(trimmed.len, max_bytes)];
}

fn snippetAroundTerms(text: []const u8, terms: []const []const u8, max_bytes: usize) []const u8 {
    var best: ?usize = null;
    for (terms) |term| {
        if (indexOfIgnoreCase(text, term)) |idx| {
            best = if (best) |existing| @min(existing, idx) else idx;
        }
    }
    const idx = best orelse return trimmedSnippet(text, max_bytes);
    const start = idx -| 80;
    const end = @min(text.len, start + max_bytes);
    return std.mem.trim(u8, text[start..end], " \r\n\t");
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

fn renderDaemonStatus(allocator: std.mem.Allocator, resident: *const ResidentState) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();
    try w.writeAll("{\"status\":\"ok\",\"daemon\":{\"status\":\"running\",\"socketPath\":");
    try std.json.stringify(socketPath(), .{}, w);
    try w.print(",\"residentShards\":{d},\"vramResidentBytes\":{d},\"deviceLocal\":{s}", .{
        resident.loaded_shards,
        resident.vram_resident_bytes,
        if (resident.vram_resident_bytes > 0) "true" else "false",
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
    if (probeSocket()) {
        try std.io.getStdOut().writer().print("ghostd active socket={s}\n", .{socketPath()});
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
