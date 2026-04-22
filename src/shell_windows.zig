const std = @import("std");
const core = @import("ghost_core");
const sys = core.sys;
const vsa = core.vsa;
const ghost_state = core.ghost_state;
const vsa_vulkan = core.vsa_vulkan;
const engine = core.engine;
const config = core.config;
const shards = core.shards;
const scratchpad = core.scratchpad;
const sigil_runtime = core.sigil_runtime;
const sigil_vm = core.sigil_vm;
const trainer = @import("trainer.zig");
const shared = @import("shell_shared.zig");

pub usingnamespace shared;

const builtin = @import("builtin");
const WINAPI = if (builtin.os.tag == .windows) std.builtin.CallingConvention.winapi else .C;
extern "kernel32" fn SetConsoleCtrlHandler(handler: ?*const fn (u32) callconv(WINAPI) i32, add: i32) callconv(WINAPI) i32;
extern "ws2_32" fn WSAStartup(wVersionRequired: u16, lpWSAData: *anyopaque) callconv(WINAPI) i32;
extern "ws2_32" fn WSACleanup() callconv(WINAPI) i32;
extern "ws2_32" fn WSAGetLastError() callconv(WINAPI) i32;
extern "ws2_32" fn socket(af: i32, type_: i32, protocol: i32) callconv(WINAPI) usize;
extern "ws2_32" fn bind(s: usize, name: *const anyopaque, namelen: i32) callconv(WINAPI) i32;
extern "ws2_32" fn listen(s: usize, backlog: i32) callconv(WINAPI) i32;
extern "ws2_32" fn accept(s: usize, addr: ?*anyopaque, addrlen: ?*i32) callconv(WINAPI) usize;
extern "ws2_32" fn ioctlsocket(s: usize, cmd: u32, argp: *u32) callconv(WINAPI) i32;
extern "ws2_32" fn recv(s: usize, buf: [*]u8, len: i32, flags: i32) callconv(WINAPI) i32;
extern "ws2_32" fn send(s: usize, buf: [*]const u8, len: i32, flags: i32) callconv(WINAPI) i32;
extern "ws2_32" fn closesocket(s: usize) callconv(WINAPI) i32;

const AF_INET = 2;
const SOCK_STREAM = 1;
const IPPROTO_TCP = 6;
const INVALID_SOCKET = ~@as(usize, 0);
const FIONBIO: u32 = 0x8004667E;
const WSAEWOULDBLOCK = 10035;
const DASHBOARD_HTML = @embedFile("dashboard.html");
const DEFAULT_CHECKPOINT_INTERVAL_MS = shared.DEFAULT_CHECKPOINT_INTERVAL_MS;
const DEFAULT_IDLE_SLEEP_MS = shared.DEFAULT_IDLE_SLEEP_MS;
const DEFAULT_SAMPLE_BINS = shared.DEFAULT_SAMPLE_BINS;
const DEFAULT_HISTOGRAM_BINS = shared.DEFAULT_HISTOGRAM_BINS;
const DEFAULT_HOT_CELLS = shared.DEFAULT_HOT_CELLS;
const CHAT_QUEUE_CAPACITY = shared.CHAT_QUEUE_CAPACITY;
const CHAT_PROMPT_CAPACITY = shared.CHAT_PROMPT_CAPACITY;
const CHAT_CHUNK_CAPACITY = shared.CHAT_CHUNK_CAPACITY;
const CHAT_STREAM_QUEUE_CAPACITY = shared.CHAT_STREAM_QUEUE_CAPACITY;
const SHUTDOWN_DRAIN_TIMEOUT_MS = shared.SHUTDOWN_DRAIN_TIMEOUT_MS;
const SHUTDOWN_POLL_MS = shared.SHUTDOWN_POLL_MS;
const CHAT_STREAM_POLL_MS = shared.CHAT_STREAM_POLL_MS;
const WS_WRITE_BUFFER_CAPACITY = shared.WS_WRITE_BUFFER_CAPACITY;
const FALLBACK_CORPORA = shared.FALLBACK_CORPORA;

comptime {
    if (!std.math.isPowerOfTwo(CHAT_QUEUE_CAPACITY)) @compileError("CHAT_QUEUE_CAPACITY must be a power of two");
    if ((CHAT_PROMPT_CAPACITY & (CHAT_PROMPT_CAPACITY - 1)) != 0) @compileError("CHAT_PROMPT_CAPACITY must be a power of two");
    if (!std.math.isPowerOfTwo(CHAT_STREAM_QUEUE_CAPACITY)) @compileError("CHAT_STREAM_QUEUE_CAPACITY must be a power of two");
}

const sockaddr_in = extern struct {
    sin_family: u16,
    sin_port: u16,
    sin_addr: u32,
    sin_zero: [8]u8 = [_]u8{0} ** 8,
};

const CorpusFile = shared.CorpusFile;
const HotCell = shared.HotCell;
const TrainRequest = shared.TrainRequest;
const ChatStreamFrameKind = shared.ChatStreamFrameKind;
const ChatStreamFrame = shared.ChatStreamFrame;
const ChatStreamQueue = shared.ChatStreamQueue;
const ChatExchange = shared.ChatExchange;
const ChatRequest = shared.ChatRequest;
const Lock = shared.Lock;
const TrackedSocket = shared.TrackedSocket;
const HttpJsonResult = shared.HttpJsonResult;
const RequestHead = shared.RequestHead;

const RawChatRequestQueue = core.sync.LockFreeQueue(ChatRequest, CHAT_QUEUE_CAPACITY);

const ChatRequestQueue = struct {
    inner: RawChatRequestQueue = .{},
    pending: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    fn push(self: *ChatRequestQueue, exchange: *ChatExchange, prompt: []const u8) !void {
        if (prompt.len > CHAT_PROMPT_CAPACITY) return error.PromptTooLong;

        var request: ChatRequest = undefined;
        request.exchange = exchange;
        request.prompt_len = @intCast(prompt.len);
        @memset(request.prompt[0..], 0);
        @memcpy(request.prompt[0..prompt.len], prompt);

        self.inner.push(request) catch |err| switch (err) {
            error.QueueFull => return error.ChatQueueFull,
            error.QueueStopped => return error.ChatQueueStopped,
        };
        _ = self.pending.fetchAdd(1, .acq_rel);
    }

    fn pop(self: *ChatRequestQueue) ?ChatRequest {
        const request = self.inner.pop() orelse return null;
        _ = self.pending.fetchSub(1, .acq_rel);
        return request;
    }

    fn shutdown(self: *ChatRequestQueue) void {
        self.inner.shutdown();
    }

    fn isShutdown(self: *const ChatRequestQueue) bool {
        return self.inner.isShutdown();
    }

    fn pendingCount(self: *const ChatRequestQueue) usize {
        return self.pending.load(.acquire);
    }
};

const TrainingSession = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    batcher: trainer.GreedyBatcher,
    trainer: trainer.OhlTrainer,

    fn init(allocator: std.mem.Allocator, req: TrainRequest) !*TrainingSession {
        const fleet = vsa_vulkan.getFleet();
        var session = try allocator.create(TrainingSession);
        errdefer allocator.destroy(session);

        session.* = .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .batcher = undefined,
            .trainer = undefined,
        };
        errdefer session.arena.deinit();

        const arena = session.arena.allocator();
        const streams = try loadStreams(arena, req.corpora, req.weights);
        if (streams.len == 0) return error.NoCorpusSelected;

        session.batcher = try trainer.GreedyBatcher.init(arena, streams);
        session.trainer = try trainer.OhlTrainer.init(arena, fleet, &session.batcher, .{
            .tier = req.tier,
            .batch_size_override = req.batch_size_override,
            .max_active_streams = req.max_active_streams,
            .checkpoint_interval_ms = req.checkpoint_interval_ms,
            .stop_after_minutes = req.stop_after_minutes,
            .stop_after_runes = req.stop_after_runes,
            .stop_after_slot_usage_bp = req.stop_after_slot_usage_bp,
            .idle_sleep_ms = req.idle_sleep_ms,
            .selected_gpu_ids = req.gpu_ids,
        });
        session.trainer.mapped_lattice = global_lattice;
        session.trainer.mapped_meaning = global_meaning;
        session.trainer.mapped_tags = global_tags;
        if (global_lattice_file) |*m| session.trainer.lattice_file = m;
        if (global_meaning_file) |*m| session.trainer.meaning_file = m;
        if (global_tags_file) |*m| session.trainer.tags_file = m;
        return session;
    }

    fn deinit(self: *TrainingSession) void {
        self.trainer.deinit();
        self.batcher.deinit();
        self.arena.deinit();
        self.allocator.destroy(self);
    }
};

var global_allocator: std.mem.Allocator = undefined;
var stop_flag = std.atomic.Value(bool).init(false);
var train_lock: Lock = .{};
var global_training: ?*TrainingSession = null;
var global_soul: ?*ghost_state.GhostSoul = null;
var global_engine: ?*engine.SingularityEngine = null;
var global_lattice_file: ?sys.MappedFile = null;
var global_meaning_file: ?sys.MappedFile = null;
var global_tags_file: ?sys.MappedFile = null;
var global_scratchpad: ?*scratchpad.ScratchpadLayer = null;
var global_state_paths: ?*const shards.Paths = null;
var global_lattice: ?[]u16 = null;
var global_meaning: ?[]u32 = null;
var global_tags: ?[]u64 = null;
var global_last_stop_reason = std.atomic.Value(u32).init(@intFromEnum(trainer.StopReason.none));
var global_last_checkpoint_ms = std.atomic.Value(u64).init(0);
var global_chat_queue: ChatRequestQueue = .{};
var global_active_chat_exchanges = std.atomic.Value(usize).init(0);
var global_socket_registry_lock: Lock = .{};
var global_active_sockets: std.ArrayListUnmanaged(TrackedSocket) = .empty;
var global_background_workers = std.atomic.Value(usize).init(0);
var global_ema_average = std.atomic.Value(u32).init(850 << 8);
var global_ema_deviation = std.atomic.Value(u32).init(25 << 8);
var global_runtime_lock: Lock = .{};

pub const EmbeddedInit = struct {
    allocator: std.mem.Allocator,
    soul: *ghost_state.GhostSoul,
    live_engine: *engine.SingularityEngine,
    state_paths: *const shards.Paths,
    lattice_file: ?sys.MappedFile = null,
    meaning_file: sys.MappedFile,
    tags_file: sys.MappedFile,
    scratchpad: *scratchpad.ScratchpadLayer,
    lattice_words: ?[]u16 = null,
    meaning_words: []u32,
    tags_words: []u64,
    port: u16 = 8080,
};

pub fn lockInference() void {
    global_runtime_lock.lock();
}

pub fn unlockInference() void {
    global_runtime_lock.unlock();
}

fn ctrlHandler(ctrl_type: u32) callconv(WINAPI) i32 {
    if (ctrl_type == 0) {
        _ = requestStop();
    }
    return 1;
}

fn closeSocketNow(sock: usize) void {
    if (sock == INVALID_SOCKET) return;
    _ = closesocket(sock);
}

fn registerActiveSocket(sock: usize) bool {
    global_socket_registry_lock.lock();
    defer global_socket_registry_lock.unlock();
    global_active_sockets.append(global_allocator, .{ .sock = sock }) catch return false;
    return true;
}

fn closeTrackedSocket(sock: usize) void {
    global_socket_registry_lock.lock();
    defer global_socket_registry_lock.unlock();

    for (global_active_sockets.items) |*entry| {
        if (entry.sock != sock) continue;
        if (entry.closed) return;
        entry.closed = true;
        closeSocketNow(sock);
        return;
    }

    closeSocketNow(sock);
}

fn unregisterActiveSocket(sock: usize) void {
    global_socket_registry_lock.lock();
    defer global_socket_registry_lock.unlock();

    for (global_active_sockets.items, 0..) |entry, i| {
        if (entry.sock != sock) continue;
        _ = global_active_sockets.swapRemove(i);
        return;
    }
}

fn forceCloseActiveSockets() void {
    global_socket_registry_lock.lock();
    defer global_socket_registry_lock.unlock();

    for (global_active_sockets.items) |*entry| {
        if (entry.closed) continue;
        entry.closed = true;
        closeSocketNow(entry.sock);
    }
}

fn failPendingChatRequests(message: []const u8) void {
    while (global_chat_queue.pop()) |request| {
        request.exchange.fail(message);
    }
}

fn isChatDrainComplete() bool {
    return global_chat_queue.pendingCount() == 0 and global_active_chat_exchanges.load(.acquire) == 0;
}

fn waitForChatDrain(timeout_ms: u32) void {
    const started = sys.getMilliTick();
    while (!isChatDrainComplete()) {
        if (sys.getMilliTick() - started >= timeout_ms) break;
        sys.sleep(SHUTDOWN_POLL_MS);
    }
}

pub fn requestStop() bool {
    const first = stop_flag.cmpxchgStrong(false, true, .acq_rel, .acquire) == null;
    if (first) {
        global_chat_queue.shutdown();
        waitForChatDrain(SHUTDOWN_DRAIN_TIMEOUT_MS);
        if (!isChatDrainComplete()) {
            failPendingChatRequests("Shutdown requested.");
            forceCloseActiveSockets();
        }
    }
    _ = requestStopTraining();
    return first;
}

pub fn waitForBackgroundWorkers(timeout_ms: u32) bool {
    const started = sys.getMilliTick();
    while (global_background_workers.load(.acquire) != 0) {
        if (sys.getMilliTick() - started >= timeout_ms) return false;
        sys.sleep(SHUTDOWN_POLL_MS);
    }
    return true;
}

fn sendBytes(sock: usize, bytes: []const u8) void {
    if (bytes.len > 0) _ = send(sock, bytes.ptr, @intCast(bytes.len), 0);
}

fn sendNonBlocking(sock: usize, bytes: []const u8, sent: *usize) !bool {
    if (sent.* >= bytes.len) return true;

    const n = send(sock, bytes[sent.*..].ptr, @intCast(bytes.len - sent.*), 0);
    if (n > 0) {
        sent.* += @intCast(n);
        return sent.* >= bytes.len;
    }

    if (n == 0) return error.SocketClosed;
    const err = WSAGetLastError();
    if (err == WSAEWOULDBLOCK) return false;
    return error.SocketWriteFailed;
}

fn statusPhrase(status: std.http.Status) []const u8 {
    return status.phrase() orelse "Unknown";
}

fn sendResponse(sock: usize, status: std.http.Status, content_type: []const u8, body: []const u8) void {
    var buf: [1024]u8 = undefined;
    const header = std.fmt.bufPrint(
        &buf,
        "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type, Sec-WebSocket-Key, Sec-WebSocket-Version\r\nConnection: close\r\n\r\n",
        .{ @intFromEnum(status), statusPhrase(status), content_type, body.len },
    ) catch return;
    sendBytes(sock, header);
    sendBytes(sock, body);
}

fn sendJsonResponse(sock: usize, status: std.http.Status, body: []const u8) void {
    sendResponse(sock, status, "application/json", body);
}

fn sendJsonError(sock: usize, status: std.http.Status, message: []const u8) void {
    var buf: [192]u8 = undefined;
    const body = std.fmt.bufPrint(&buf, "{{\"error\":\"{s}\"}}", .{message}) catch "{\"error\":\"Response formatting failed\"}";
    sendJsonResponse(sock, status, body);
}

fn parseRequestHead(req: []const u8) ?RequestHead {
    const line_end = std.mem.indexOf(u8, req, "\r\n") orelse return null;
    const line = req[0..line_end];
    const first_space = std.mem.indexOfScalar(u8, line, ' ') orelse return null;
    const remainder = line[first_space + 1 ..];
    const second_space_rel = std.mem.indexOfScalar(u8, remainder, ' ') orelse return null;
    const method = std.meta.stringToEnum(std.http.Method, line[0..first_space]) orelse return null;
    return .{
        .method = method,
        .target = remainder[0..second_space_rel],
    };
}

fn trimName(buf: []const u8) []const u8 {
    var end: usize = 0;
    while (end < buf.len and buf[end] != 0) : (end += 1) {}
    return buf[0..end];
}

fn contains(items: [][]const u8, needle: []const u8) bool {
    for (items) |item| if (std.mem.eql(u8, item, needle)) return true;
    return false;
}

fn decodeJsonString(raw: []const u8, out: []u8) ?[]const u8 {
    var r: usize = 0;
    var w: usize = 0;
    while (r < raw.len) : (r += 1) {
        if (raw[r] == '"') return out[0..w];
        if (w >= out.len) return null;
        if (raw[r] != '\\') {
            out[w] = raw[r];
            w += 1;
            continue;
        }
        r += 1;
        if (r >= raw.len) return null;
        out[w] = switch (raw[r]) {
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            '"', '\\', '/' => raw[r],
            'u' => blk: {
                if (r + 4 >= raw.len) return null;
                r += 4;
                break :blk '?';
            },
            else => return null,
        };
        w += 1;
    }
    return null;
}

fn jsonString(body: []const u8, key: []const u8, out: []u8) ?[]const u8 {
    var pat_buf: [96]u8 = undefined;
    const pat = std.fmt.bufPrint(&pat_buf, "\"{s}\":\"", .{key}) catch return null;
    const idx = std.mem.indexOf(u8, body, pat) orelse return null;
    return decodeJsonString(body[idx + pat.len ..], out);
}

fn jsonStringArray(allocator: std.mem.Allocator, body: []const u8, key: []const u8) ![][]const u8 {
    var pat_buf: [96]u8 = undefined;
    const pat = try std.fmt.bufPrint(&pat_buf, "\"{s}\":[", .{key});
    const idx = std.mem.indexOf(u8, body, pat) orelse return allocator.alloc([]const u8, 0);
    var items = std.ArrayList([]const u8).init(allocator);
    errdefer {
        for (items.items) |item| allocator.free(item);
        items.deinit();
    }
    var pos = idx + pat.len;
    while (pos < body.len) {
        while (pos < body.len and (body[pos] == ' ' or body[pos] == ',')) : (pos += 1) {}
        if (pos >= body.len or body[pos] == ']') break;
        if (body[pos] != '"') return error.InvalidJson;
        pos += 1;
        var tmp: [512]u8 = undefined;
        const value = decodeJsonString(body[pos..], &tmp) orelse return error.InvalidJson;
        try items.append(try allocator.dupe(u8, value));
        while (pos < body.len and body[pos] != '"') : (pos += 1) {}
        if (pos < body.len) pos += 1;
    }
    return items.toOwnedSlice();
}

fn jsonNumberSlice(body: []const u8, key: []const u8) ?[]const u8 {
    var pat_buf: [96]u8 = undefined;
    const pat = std.fmt.bufPrint(&pat_buf, "\"{s}\":", .{key}) catch return null;
    const idx = std.mem.indexOf(u8, body, pat) orelse return null;
    var pos = idx + pat.len;
    while (pos < body.len and body[pos] == ' ') : (pos += 1) {}
    const start = pos;
    while (pos < body.len and ((body[pos] >= '0' and body[pos] <= '9') or body[pos] == '.' or body[pos] == '-' or body[pos] == '+' or body[pos] == 'e' or body[pos] == 'E')) : (pos += 1) {}
    if (pos == start) return null;
    return body[start..pos];
}

fn jsonU32(body: []const u8, key: []const u8, fallback: u32) u32 {
    const raw = jsonNumberSlice(body, key) orelse return fallback;
    return std.fmt.parseInt(u32, raw, 10) catch fallback;
}

fn jsonU64(body: []const u8, key: []const u8, fallback: u64) u64 {
    const raw = jsonNumberSlice(body, key) orelse return fallback;
    return std.fmt.parseInt(u64, raw, 10) catch fallback;
}

fn jsonF64(body: []const u8, key: []const u8, fallback: f64) f64 {
    const raw = jsonNumberSlice(body, key) orelse return fallback;
    return std.fmt.parseFloat(f64, raw) catch fallback;
}

fn parseTierFlag(flag: []const u8) u32 {
    return if (std.mem.eql(u8, flag, "--background"))
        @intFromEnum(vsa_vulkan.OperationalTier.background)
    else if (std.mem.eql(u8, flag, "--high"))
        @intFromEnum(vsa_vulkan.OperationalTier.high)
    else if (std.mem.eql(u8, flag, "--max"))
        @intFromEnum(vsa_vulkan.OperationalTier.max)
    else
        @intFromEnum(vsa_vulkan.OperationalTier.standard);
}

fn jsonU32Array(allocator: std.mem.Allocator, body: []const u8, key: []const u8) ![]u32 {
    var pat_buf: [96]u8 = undefined;
    const pat = try std.fmt.bufPrint(&pat_buf, "\"{s}\":[", .{key});
    const idx = std.mem.indexOf(u8, body, pat) orelse return allocator.alloc(u32, 0);
    var items = std.ArrayList(u32).init(allocator);
    errdefer items.deinit();
    var pos = idx + pat.len;
    while (pos < body.len) {
        while (pos < body.len and (body[pos] == ' ' or body[pos] == ',')) : (pos += 1) {}
        if (pos >= body.len or body[pos] == ']') break;
        const start = pos;
        while (pos < body.len and body[pos] >= '0' and body[pos] <= '9') : (pos += 1) {}
        if (pos == start) return error.InvalidJson;
        try items.append(try std.fmt.parseInt(u32, body[start..pos], 10));
    }
    return items.toOwnedSlice();
}

fn jsonWeightMap(allocator: std.mem.Allocator, body: []const u8, key: []const u8) ![]trainer.CorpusWeight {
    var pat_buf: [96]u8 = undefined;
    const pat = try std.fmt.bufPrint(&pat_buf, "\"{s}\":{{", .{key});
    const idx = std.mem.indexOf(u8, body, pat) orelse return allocator.alloc(trainer.CorpusWeight, 0);
    var items = std.ArrayList(trainer.CorpusWeight).init(allocator);
    errdefer {
        for (items.items) |item| allocator.free(item.name);
        items.deinit();
    }
    var pos = idx + pat.len;
    while (pos < body.len) {
        while (pos < body.len and (body[pos] == ' ' or body[pos] == ',')) : (pos += 1) {}
        if (pos >= body.len or body[pos] == '}') break;
        if (body[pos] != '"') return error.InvalidJson;
        pos += 1;
        var tmp: [512]u8 = undefined;
        const name = decodeJsonString(body[pos..], &tmp) orelse return error.InvalidJson;
        while (pos < body.len and body[pos] != '"') : (pos += 1) {}
        if (pos >= body.len) return error.InvalidJson;
        pos += 1;
        while (pos < body.len and (body[pos] == ' ' or body[pos] == ':')) : (pos += 1) {}
        const start = pos;
        while (pos < body.len and body[pos] >= '0' and body[pos] <= '9') : (pos += 1) {}
        if (pos == start) return error.InvalidJson;
        try items.append(.{
            .name = try allocator.dupe(u8, name),
            .weight = try std.fmt.parseInt(u32, body[start..pos], 10),
        });
    }
    return items.toOwnedSlice();
}

fn tierValueFromText(flag: []const u8) u32 {
    return if (std.mem.eql(u8, flag, "--background") or std.mem.eql(u8, flag, "background"))
        @intFromEnum(vsa_vulkan.OperationalTier.background)
    else if (std.mem.eql(u8, flag, "--high") or std.mem.eql(u8, flag, "high"))
        @intFromEnum(vsa_vulkan.OperationalTier.high)
    else if (std.mem.eql(u8, flag, "--max") or std.mem.eql(u8, flag, "max"))
        @intFromEnum(vsa_vulkan.OperationalTier.max)
    else if (std.mem.eql(u8, flag, "extreme"))
        @intFromEnum(vsa_vulkan.OperationalTier.extreme)
    else if (std.mem.eql(u8, flag, "ultra"))
        @intFromEnum(vsa_vulkan.OperationalTier.ultra)
    else if (std.mem.eql(u8, flag, "hyper"))
        @intFromEnum(vsa_vulkan.OperationalTier.hyper)
    else if (std.mem.eql(u8, flag, "god"))
        @intFromEnum(vsa_vulkan.OperationalTier.god)
    else
        @intFromEnum(vsa_vulkan.OperationalTier.standard);
}

fn tierNameFromValue(value: u32) []const u8 {
    return @tagName(@as(vsa_vulkan.OperationalTier, @enumFromInt(value)));
}

fn stopReasonName(reason: trainer.StopReason) []const u8 {
    return @tagName(reason);
}

fn parseTrainRequest(allocator: std.mem.Allocator, body: []const u8) !TrainRequest {
    var tier_buf: [64]u8 = undefined;
    const tier_text = jsonString(body, "tier", &tier_buf) orelse "standard";
    const corpora = try jsonStringArray(allocator, body, "corpora");
    errdefer {
        for (corpora) |item| allocator.free(item);
        allocator.free(corpora);
    }
    const gpu_ids = try jsonU32Array(allocator, body, "gpuIds");
    errdefer allocator.free(gpu_ids);
    const weights = try jsonWeightMap(allocator, body, "weights");
    errdefer {
        for (weights) |item| allocator.free(item.name);
        allocator.free(weights);
    }
    return .{
        .tier = tierValueFromText(tier_text),
        .corpora = corpora,
        .gpu_ids = gpu_ids,
        .weights = weights,
        .batch_size_override = jsonU32(body, "batchSize", 0),
        .max_active_streams = jsonU32(body, "maxActiveStreams", 0),
        .checkpoint_interval_ms = jsonU32(body, "checkpointIntervalMs", DEFAULT_CHECKPOINT_INTERVAL_MS),
        .stop_after_minutes = jsonU32(body, "stopAfterMinutes", 0),
        .stop_after_runes = jsonU64(body, "stopAfterRunes", 0),
        .stop_after_slot_usage_bp = @intFromFloat(@max(jsonF64(body, "stopAfterSlotUsagePct", 0) * 100.0, 0.0)),
        .idle_sleep_ms = jsonU32(body, "idleSleepMs", DEFAULT_IDLE_SLEEP_MS),
    };
}

fn freeTrainRequest(allocator: std.mem.Allocator, req: TrainRequest) void {
    for (req.corpora) |item| allocator.free(item);
    allocator.free(req.corpora);
    allocator.free(req.gpu_ids);
    for (req.weights) |item| allocator.free(item.name);
    allocator.free(req.weights);
}

fn weightForCorpus(weights: []const trainer.CorpusWeight, corpus_name: []const u8) u32 {
    for (weights) |weight| {
        if (std.mem.eql(u8, weight.name, corpus_name)) return @max(weight.weight, 1);
    }
    return 1;
}

fn loadStreams(
    allocator: std.mem.Allocator,
    wanted: [][]const u8,
    weights: []const trainer.CorpusWeight,
) ![]trainer.StreamState {
    const corpus_files = try sys.findCorpusFiles(allocator);
    defer {
        for (corpus_files) |path| allocator.free(path);
        allocator.free(corpus_files);
    }
    var list = std.ArrayList(trainer.StreamState).init(allocator);
    errdefer list.deinit();
    for (corpus_files) |full_path| {
        const base = std.fs.path.basename(full_path);
        if (wanted.len > 0 and !contains(wanted, base)) continue;
        const name = try allocator.dupe(u8, base);
        var stream = trainer.StreamState.initFile(
            allocator,
            full_path,
            name,
            weightForCorpus(weights, base),
        ) catch continue;
        if (stream.totalSizeBytes() == 0) {
            stream.deinit();
            continue;
        }
        try list.append(stream);
    }

    if (list.items.len == 0 and wanted.len > 0) {
        for (wanted) |name| {
            const full_path = projectCorpusPath(allocator, name) catch continue;
            defer allocator.free(full_path);
            const display_name = try allocator.dupe(u8, std.fs.path.basename(name));
            var stream = trainer.StreamState.initFile(
                allocator,
                full_path,
                display_name,
                weightForCorpus(weights, std.fs.path.basename(name)),
            ) catch continue;
            if (stream.totalSizeBytes() == 0) {
                stream.deinit();
                continue;
            }
            try list.append(stream);
        }
    }

    return list.toOwnedSlice();
}

fn activeTrainingSessionLocked() ?*TrainingSession {
    const session = global_training orelse return null;
    if (!session.trainer.is_running.load(.acquire)) return null;
    return session;
}

fn requestStopTraining() HttpJsonResult {
    train_lock.lock();
    defer train_lock.unlock();
    const session = activeTrainingSessionLocked() orelse return .{
        .status = .conflict,
        .body = "{\"error\":\"Training is not active\"}",
    };
    session.trainer.requestStop(.manual);
    return .{
        .status = .ok,
        .body = "{\"status\":\"stopping\"}",
    };
}

fn trainingThread(session: *TrainingSession) void {
    _ = global_background_workers.fetchAdd(1, .acq_rel);
    defer _ = global_background_workers.fetchSub(1, .acq_rel);
    session.trainer.start() catch |err| sys.print("[TRAIN] {any}\n", .{err});
    if (!stop_flag.load(.acquire) and session.trainer.getStopReason() != .manual) {
        session.trainer.checkpoint() catch |err| sys.print("[CHECKPOINT] {any}\n", .{err});
    }
    global_last_stop_reason.store(@intFromEnum(session.trainer.getStopReason()), .release);
    global_last_checkpoint_ms.store(session.trainer.getLastCheckpointMs(), .release);
    train_lock.lock();
    global_training = null;
    train_lock.unlock();
    session.deinit();
}

fn startTraining(req: TrainRequest) HttpJsonResult {
    train_lock.lock();
    defer train_lock.unlock();
    if (global_training != null) return .{
        .status = .conflict,
        .body = "{\"error\":\"Training is already active\"}",
    };

    const session = TrainingSession.init(global_allocator, req) catch |err| return switch (err) {
        error.NoCorpusSelected => .{
            .status = .bad_request,
            .body = "{\"error\":\"No corpus selected\"}",
        },
        error.NoGpuSelected => .{
            .status = .bad_request,
            .body = "{\"error\":\"No valid GPU selected\"}",
        },
        error.OutOfMemory => .{
            .status = .internal_server_error,
            .body = "{\"error\":\"Failed to allocate training session\"}",
        },
        else => .{
            .status = .internal_server_error,
            .body = "{\"error\":\"Failed to start training\"}",
        },
    };

    global_training = session;
    const thread = std.Thread.spawn(.{ .allocator = global_allocator }, trainingThread, .{session}) catch {
        global_training = null;
        session.deinit();
        return .{
            .status = .internal_server_error,
            .body = "{\"error\":\"Failed to launch training thread\"}",
        };
    };
    thread.detach();
    return .{
        .status = .ok,
        .body = "{\"status\":\"started\"}",
    };
}

fn pauseTraining() HttpJsonResult {
    train_lock.lock();
    defer train_lock.unlock();
    const session = activeTrainingSessionLocked() orelse return .{
        .status = .conflict,
        .body = "{\"error\":\"Training is not active\"}",
    };
    if (session.trainer.is_paused.load(.acquire)) {
        return .{
            .status = .conflict,
            .body = "{\"error\":\"Training is already paused\"}",
        };
    }
    trainer.OhlTrainer.pause(&session.trainer);
    return .{
        .status = .ok,
        .body = "{\"status\":\"paused\"}",
    };
}

fn resumeTraining() HttpJsonResult {
    train_lock.lock();
    defer train_lock.unlock();
    const session = activeTrainingSessionLocked() orelse return .{
        .status = .conflict,
        .body = "{\"error\":\"Training is not active\"}",
    };
    if (!session.trainer.is_paused.load(.acquire)) {
        return .{
            .status = .conflict,
            .body = "{\"error\":\"Training is not paused\"}",
        };
    }
    session.trainer.resumeTraining();
    return .{
        .status = .ok,
        .body = "{\"status\":\"resumed\"}",
    };
}

fn requestCheckpointNow() HttpJsonResult {
    train_lock.lock();
    defer train_lock.unlock();
    const session = activeTrainingSessionLocked() orelse return .{
        .status = .conflict,
        .body = "{\"error\":\"Training is not active\"}",
    };
    if (session.trainer.checkpoint_in_progress.load(.acquire)) {
        return .{
            .status = .conflict,
            .body = "{\"error\":\"Checkpoint already in progress\"}",
        };
    }
    trainer.OhlTrainer.requestCheckpoint(&session.trainer);
    return .{
        .status = .ok,
        .body = "{\"status\":\"queued\"}",
    };
}

fn applyControlUpdate(body: []const u8) HttpJsonResult {
    train_lock.lock();
    defer train_lock.unlock();
    const session = activeTrainingSessionLocked() orelse return .{
        .status = .conflict,
        .body = "{\"error\":\"Training is not active\"}",
    };
    var tier_buf: [64]u8 = undefined;
    const tier_value = if (jsonString(body, "tier", &tier_buf)) |tier_text| tierValueFromText(tier_text) else session.trainer.getCurrentTier();
    session.trainer.applyOptions(.{
        .tier = tier_value,
        .batch_size_override = jsonU32(body, "batchSize", session.trainer.getBatchSizeOverride()),
        .max_active_streams = jsonU32(body, "maxActiveStreams", session.trainer.getMaxActiveStreams()),
        .checkpoint_interval_ms = jsonU32(body, "checkpointIntervalMs", session.trainer.getCheckpointIntervalMs()),
        .stop_after_minutes = jsonU32(body, "stopAfterMinutes", session.trainer.getStopAfterMinutes()),
        .stop_after_runes = jsonU64(body, "stopAfterRunes", session.trainer.getStopAfterRunes()),
        .stop_after_slot_usage_bp = @intFromFloat(@max(jsonF64(body, "stopAfterSlotUsagePct", @as(f64, @floatFromInt(session.trainer.getStopAfterSlotUsageBp())) / 100.0) * 100.0, 0.0)),
        .idle_sleep_ms = jsonU32(body, "idleSleepMs", DEFAULT_IDLE_SLEEP_MS),
        .selected_gpu_ids = &.{},
    });
    return .{
        .status = .ok,
        .body = "{\"status\":\"updated\"}",
    };
}

fn parseSigilScriptBody(body: []const u8, scratch: []u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, body, " \r\n\t");
    if (trimmed.len == 0) return error.EmptyBody;
    if (trimmed[0] != '{') return trimmed;

    const script = jsonLooseString(trimmed, "script", scratch) orelse jsonLooseString(trimmed, "sigil", scratch) orelse return error.InvalidJson;
    const cleaned = std.mem.trim(u8, script, " \r\n\t");
    if (cleaned.len == 0) return error.EmptyBody;
    return cleaned;
}

fn jsonLooseString(body: []const u8, key: []const u8, out: []u8) ?[]const u8 {
    var pat_buf: [96]u8 = undefined;
    const key_pat = std.fmt.bufPrint(&pat_buf, "\"{s}\"", .{key}) catch return null;
    const idx = std.mem.indexOf(u8, body, key_pat) orelse return null;
    var pos = idx + key_pat.len;
    while (pos < body.len and (body[pos] == ' ' or body[pos] == '\r' or body[pos] == '\n' or body[pos] == '\t')) : (pos += 1) {}
    if (pos >= body.len or body[pos] != ':') return null;
    pos += 1;
    while (pos < body.len and (body[pos] == ' ' or body[pos] == '\r' or body[pos] == '\n' or body[pos] == '\t')) : (pos += 1) {}
    if (pos >= body.len or body[pos] != '"') return null;
    return decodeJsonString(body[pos + 1 ..], out);
}

fn controlMoodName(snapshot: sigil_runtime.ControlSnapshot) []const u8 {
    if (snapshot.saturation_bonus == 96 and snapshot.boredom_penalty_high == 8 and snapshot.boredom_penalty_low == 4) return "aggressive";
    if (snapshot.saturation_bonus == 80 and snapshot.boredom_penalty_high == 16 and snapshot.boredom_penalty_low == 8) return "focused";
    if (snapshot.saturation_bonus == 40 and snapshot.boredom_penalty_high == 40 and snapshot.boredom_penalty_low == 20) return "calm";
    if (snapshot.saturation_bonus == config.SATURATION_BONUS and
        snapshot.boredom_penalty_high == config.BOREDOM_PENALTY_HIGH and
        snapshot.boredom_penalty_low == config.BOREDOM_PENALTY_LOW) return "default";
    return "custom";
}

fn buildSigilStateJson(allocator: std.mem.Allocator, snapshot: sigil_runtime.ControlSnapshot) ![]u8 {
    var list = std.ArrayList(u8).init(allocator);
    defer list.deinit();

    try appendPrint(&list, allocator, "{{\"status\":\"ok\",\"control\":{{\"reasoningMode\":\"{s}\",\"mood\":\"{s}\",\"saturationBonus\":{d},\"boredomPenaltyHigh\":{d},\"boredomPenaltyLow\":{d},\"enableVulkan\":{s},\"forceCpuOnly\":{s},\"lastScan\":{{\"hash\":{d},\"energy\":{d}}},\"lockedSlots\":{d},\"lockedHashes\":{d},\"bindings\":{d}}}}}", .{
        sigil_runtime.reasoningModeName(snapshot.reasoning_mode),
        controlMoodName(snapshot),
        snapshot.saturation_bonus,
        snapshot.boredom_penalty_high,
        snapshot.boredom_penalty_low,
        if (snapshot.enable_vulkan) "true" else "false",
        if (snapshot.force_cpu_only) "true" else "false",
        snapshot.last_scan.hash,
        snapshot.last_scan.energy,
        snapshot.locked_slot_count,
        snapshot.locked_hash_count,
        snapshot.binding_count,
    });
    return list.toOwnedSlice();
}

fn handleSigilRequest(sock: usize, allocator: std.mem.Allocator, body: []const u8) void {
    const control = sigil_runtime.getActiveControl() orelse {
        sendJsonError(sock, .service_unavailable, "Sigil control plane unavailable");
        return;
    };
    const live = global_engine orelse {
        sendJsonError(sock, .service_unavailable, "Engine unavailable");
        return;
    };

    const script_buf = allocator.alloc(u8, body.len) catch {
        sendJsonError(sock, .internal_server_error, "Failed to allocate Sigil buffer");
        return;
    };
    defer allocator.free(script_buf);

    const script = parseSigilScriptBody(body, script_buf) catch |err| {
        switch (err) {
            error.EmptyBody => sendJsonError(sock, .bad_request, "Sigil body is empty"),
            error.InvalidJson => sendJsonError(sock, .bad_request, "Expected raw Sigil text or JSON with a script field"),
        }
        return;
    };

    const snapshot = blk: {
        lockInference();
        defer unlockInference();

        const live_scratchpad = global_scratchpad orelse {
            sendJsonError(sock, .service_unavailable, "Scratchpad unavailable");
            return;
        };
        var meaning_surface = sigil_vm.MeaningSurface{ .scratchpad = live_scratchpad.meaning() };
        var vm_ctx = sigil_vm.Context{
            .allocator = allocator,
            .control = control,
            .meaning = &meaning_surface,
            .soul = live.soul,
            .lattice = live.lattice,
        };
        sigil_vm.executeSource(&vm_ctx, script) catch |err| {
            switch (err) {
                error.ParseFailed => sendJsonError(sock, .bad_request, "Invalid Sigil script"),
                else => sendJsonError(sock, .internal_server_error, "Sigil execution failed"),
            }
            return;
        };
        break :blk control.snapshot();
    };

    const json = buildSigilStateJson(allocator, snapshot) catch {
        sendJsonError(sock, .internal_server_error, "Failed to serialize control plane");
        return;
    };
    defer allocator.free(json);
    sendJsonResponse(sock, .ok, json);
}

fn isTrainingActive() bool {
    train_lock.lock();
    defer train_lock.unlock();
    return global_training != null;
}

fn appendEscaped(list: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    _ = allocator;
    for (text) |c| switch (c) {
        '\\' => try list.appendSlice("\\\\"),
        '"' => try list.appendSlice("\\\""),
        '\n' => try list.appendSlice("\\n"),
        '\r' => try list.appendSlice("\\r"),
        '\t' => try list.appendSlice("\\t"),
        else => try list.append(c),
    };
}

fn appendPrint(list: *std.ArrayList(u8), allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    _ = allocator;
    var buf: [4096]u8 = undefined;
    const rendered = try std.fmt.bufPrint(&buf, fmt, args);
    try list.appendSlice(rendered);
}

fn countUsed(tags: []const u64) usize {
    var n: usize = 0;
    for (tags) |tag| {
        if (tag != 0) n += 1;
    }
    return n;
}

fn appendCorpusFilesJson(list: *std.ArrayList(u8), allocator: std.mem.Allocator, corpora: []const CorpusFile) !void {
    try list.append('[');
    for (corpora, 0..) |item, i| {
        if (i > 0) try list.append(',');
        try list.appendSlice("{\"name\":\"");
        try appendEscaped(list, allocator, item.name);
        try appendPrint(list, allocator, "\",\"sizeBytes\":{d}}}", .{item.size_bytes});
    }
    try list.append(']');
}

fn projectCorpusPath(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    const corpus_root = try config.getPath(allocator, "corpus");
    defer allocator.free(corpus_root);
    return std.fs.path.join(allocator, &[_][]const u8{ corpus_root, name });
}

fn appendFallbackCorpusFiles(items: *std.ArrayList(CorpusFile), allocator: std.mem.Allocator) !void {
    for (FALLBACK_CORPORA) |name| {
        const full_path = try projectCorpusPath(allocator, name);
        defer allocator.free(full_path);
        const file = sys.openForRead(allocator, full_path) catch continue;
        defer sys.closeFile(file);
        const size = sys.getFileSize(file) catch 0;
        if (size == 0) continue;
        try items.append(.{
            .name = try allocator.dupe(u8, name),
            .size_bytes = size,
        });
    }
}

fn loadCorpusFiles(allocator: std.mem.Allocator) ![]CorpusFile {
    const files = try sys.findCorpusFiles(allocator);
    errdefer {
        for (files) |path| allocator.free(path);
        allocator.free(files);
    }

    var items = std.ArrayList(CorpusFile).init(allocator);
    errdefer {
        for (items.items) |item| allocator.free(item.name);
        items.deinit();
    }
    for (files) |path| {
        const file = sys.openForRead(allocator, path) catch continue;
        const size = sys.getFileSize(file) catch 0;
        sys.closeFile(file);
        try items.append(.{
            .name = try allocator.dupe(u8, std.fs.path.basename(path)),
            .size_bytes = size,
        });
    }
    for (files) |path| allocator.free(path);
    allocator.free(files);
    if (items.items.len == 0) {
        try appendFallbackCorpusFiles(&items, allocator);
    }
    return items.toOwnedSlice();
}

fn freeCorpusFiles(allocator: std.mem.Allocator, corpora: []CorpusFile) void {
    for (corpora) |item| allocator.free(item.name);
    allocator.free(corpora);
}

fn buildCorporaJson(allocator: std.mem.Allocator) ![]u8 {
    const corpora = try loadCorpusFiles(allocator);
    defer freeCorpusFiles(allocator, corpora);
    var list = std.ArrayList(u8).init(allocator);
    defer list.deinit();
    try appendCorpusFilesJson(&list, allocator, corpora);
    return list.toOwnedSlice();
}

fn updateHotCells(hot_cells: *[DEFAULT_HOT_CELLS]HotCell, idx: usize, value: u16) void {
    if (value == 0) return;
    var insert_at: ?usize = null;
    for (hot_cells, 0..) |cell, i| {
        if (value > cell.value) {
            insert_at = i;
            break;
        }
    }
    if (insert_at) |slot| {
        var j = hot_cells.len - 1;
        while (j > slot) : (j -= 1) {
            hot_cells[j] = hot_cells[j - 1];
        }
        hot_cells[slot] = .{ .index = idx, .value = value };
    }
}

fn buildStatsJson(allocator: std.mem.Allocator) ![]u8 {
    const vk = vsa_vulkan.getEngine();
    const tags = if (vk) |live| live.getTagsData() else (global_tags orelse &[_]u64{});
    const slot_capacity: u32 = if (vk) |live| live.matrix_slots else @intCast(tags.len);
    const used = countUsed(tags);
    const slot_pct = if (slot_capacity == 0) 0.0 else (@as(f64, @floatFromInt(used)) / @as(f64, @floatFromInt(slot_capacity))) * 100.0;
    const ema_avg = @as(f64, @floatFromInt(global_ema_average.load(.acquire))) / 256.0;
    const ema_dev = @as(f64, @floatFromInt(global_ema_deviation.load(.acquire))) / 256.0;
    const last_stop = @as(trainer.StopReason, @enumFromInt(global_last_stop_reason.load(.acquire)));
    const last_checkpoint = global_last_checkpoint_ms.load(.acquire);
    const control_snapshot = if (sigil_runtime.getActiveControl()) |control| control.snapshot() else null;

    var list = std.ArrayList(u8).init(allocator);
    defer list.deinit();
    try list.appendSlice("{\"stats\":{");
    try appendPrint(&list, allocator, "\"slotUsagePct\":{d:.2},\"slotUsage\":{d},\"slotCapacity\":{d},\"emaAverage\":{d:.2},\"emaDeviation\":{d:.2},", .{
        slot_pct,
        used,
        slot_capacity,
        ema_avg,
        ema_dev,
    });
    if (control_snapshot) |snapshot| {
        try appendPrint(&list, allocator, "\"sigilEtches\":{d},\"sigilTotalDrift\":{d},\"sigilLastHash\":{d},\"sigilLastEnergy\":{d},\"sigilEmaAverage\":{d:.2},\"sigilEmaDeviation\":{d:.2},\"sigilSlotUsage\":{d},", .{
            snapshot.etch.total_etches,
            snapshot.etch.total_drift,
            snapshot.etch.last_hash,
            snapshot.etch.last_energy,
            @as(f64, @floatFromInt(snapshot.etch.ema_average)) / 256.0,
            @as(f64, @floatFromInt(snapshot.etch.ema_deviation)) / 256.0,
            snapshot.etch.slot_usage,
        });
    } else {
        try list.appendSlice("\"sigilEtches\":0,\"sigilTotalDrift\":0,\"sigilLastHash\":0,\"sigilLastEnergy\":0,\"sigilEmaAverage\":0,\"sigilEmaDeviation\":0,\"sigilSlotUsage\":0,");
    }

    train_lock.lock();
    defer train_lock.unlock();
    if (global_training) |session| {
        const t = &session.trainer;
        try appendPrint(&list, allocator, "\"throughputMiBs\":{d:.2},\"activeStreams\":{d},\"totalStreams\":{d},\"overallPct\":{d:.2},\"processedRunes\":{d},\"elapsedMs\":{d},\"etaMs\":{d},\"droppedRunes\":{d},\"collisionStalls\":{d},\"isTraining\":true,\"isPaused\":{s},\"checkpointing\":{s},\"batchFillPct\":{d:.2},\"batchSize\":{d},\"maxActiveStreams\":{d},\"checkpointIntervalMs\":{d},\"lastCheckpointMs\":{d},\"checkpointAgeMs\":{d},\"stopAfterMinutes\":{d},\"stopAfterRunes\":{d},\"stopAfterSlotUsagePct\":{d:.2},\"selectedGpuCount\":{d},\"tier\":\"{s}\",\"bottleneck\":\"{s}\",\"stopReason\":\"{s}\",\"timestamp\":{d}}},\"streams\":[", .{
            t.getThroughput(),
            t.getActiveStreamCount(),
            t.getTotalStreamCount(),
            t.getOverallProgress() * 100.0,
            t.getProcessedRunes(),
            t.getElapsedMs(),
            t.getEtaMs(),
            t.getDroppedRunes(),
            t.getCollisionStalls(),
            if (t.is_paused.load(.acquire)) "true" else "false",
            if (t.checkpoint_in_progress.load(.acquire)) "true" else "false",
            t.getBatchFillPct(),
            t.getBatchSizeOverride(),
            t.getMaxActiveStreams(),
            t.getCheckpointIntervalMs(),
            t.getLastCheckpointMs(),
            t.getCheckpointAgeMs(),
            t.getStopAfterMinutes(),
            t.getStopAfterRunes(),
            @as(f64, @floatFromInt(t.getStopAfterSlotUsageBp())) / 100.0,
            t.getSelectedGpuCount(),
            tierNameFromValue(t.getCurrentTier()),
            t.getBottleneckReason(),
            stopReasonName(t.getStopReason()),
            sys.getMilliTick(),
        });

        for (session.batcher.streams, 0..) |stream, i| {
            if (i > 0) try list.append(',');
            const cursor = stream.cursor.load(.monotonic);
            const size = stream.totalSizeBytes();
            const pct = if (size == 0) 100.0 else (@as(f64, @floatFromInt(cursor)) / @as(f64, @floatFromInt(size))) * 100.0;
            try list.appendSlice("{\"name\":\"");
            try appendEscaped(&list, allocator, stream.name);
            try appendPrint(&list, allocator, "\",\"progressPct\":{d:.2},\"cursor\":{d},\"sizeBytes\":{d},\"weight\":{d},\"done\":{s}}}", .{
                pct,
                cursor,
                size,
                stream.weight,
                if (stream.done.load(.monotonic)) "true" else "false",
            });
        }

        try list.appendSlice("],\"gpus\":[");
        for (t.engines, 0..) |gpu, i| {
            if (i > 0) try list.append(',');
            const stat = t.gpu_stats[i];
            const elapsed_ms = @max(t.getElapsedMs(), 1);
            const busy_pct = (@as(f64, @floatFromInt(stat.busy_time_ms.load(.monotonic))) / @as(f64, @floatFromInt(elapsed_ms))) * 100.0;
            try list.appendSlice("{\"index\":");
            try appendPrint(&list, allocator, "{d},\"name\":\"", .{gpu.device_index});
            try appendEscaped(&list, allocator, trimName(gpu.device_name[0..]));
            try appendPrint(&list, allocator, "\",\"vramMiB\":{d},\"queues\":{d},\"matrixSlots\":{d},\"tier\":\"{s}\",\"targetBatchSize\":{d},\"lastBatchSize\":{d},\"processedRunes\":{d},\"dispatchedBatches\":{d},\"busyPct\":{d:.2},\"lastDispatchMs\":{d},\"selected\":true}}", .{
                gpu.vram_size / 1048576,
                gpu.num_queues,
                gpu.matrix_slots,
                tierNameFromValue(@intFromEnum(gpu.tier)),
                stat.target_batch_size.load(.monotonic),
                stat.last_batch_size.load(.monotonic),
                stat.processed_runes.load(.monotonic),
                stat.dispatched_batches.load(.monotonic),
                @min(busy_pct, 100.0),
                stat.last_dispatch_ms.load(.monotonic),
            });
        }
        try list.append(']');
    } else {
        try appendPrint(&list, allocator, "\"throughputMiBs\":0,\"activeStreams\":0,\"totalStreams\":0,\"overallPct\":0,\"processedRunes\":0,\"elapsedMs\":0,\"etaMs\":0,\"droppedRunes\":0,\"collisionStalls\":0,\"isTraining\":false,\"isPaused\":false,\"checkpointing\":false,\"batchFillPct\":0,\"batchSize\":0,\"maxActiveStreams\":0,\"checkpointIntervalMs\":{d},\"lastCheckpointMs\":{d},\"checkpointAgeMs\":{d},\"stopAfterMinutes\":0,\"stopAfterRunes\":0,\"stopAfterSlotUsagePct\":0,\"selectedGpuCount\":0,\"tier\":\"{s}\",\"bottleneck\":\"idle\",\"stopReason\":\"{s}\",\"timestamp\":{d}}},\"streams\":[],\"gpus\":[]", .{
            DEFAULT_CHECKPOINT_INTERVAL_MS,
            last_checkpoint,
            if (last_checkpoint == 0) @as(u64, 0) else sys.getMilliTick() - last_checkpoint,
            tierNameFromValue(@intFromEnum(vsa_vulkan.OperationalTier.standard)),
            stopReasonName(last_stop),
            sys.getMilliTick(),
        });
    }
    try list.append('}');
    return list.toOwnedSlice();
}

fn buildStateJson(allocator: std.mem.Allocator) ![]u8 {
    const vk = vsa_vulkan.getEngine();
    const compute = if (vk != null) "Vulkan" else "CPU-only";
    const device = if (vk) |live| trimName(live.device_name[0..]) else "No GPU";
    const corpora = try loadCorpusFiles(allocator);
    defer freeCorpusFiles(allocator, corpora);

    var list = std.ArrayList(u8).init(allocator);
    defer list.deinit();
    try appendPrint(&list, allocator, "{{\"files\":{{\"unified_lattice.bin\":{d},\"semantic_monolith.bin\":{d},\"semantic_tags.bin\":{d}}},\"architecture\":{{\"version\":\"{s}\",\"hypervectorBits\":{d},\"semanticSlots\":{d},\"gpuMatrixSlots\":{d},\"unifiedSizeBytes\":{d},\"semanticSizeBytes\":{d},\"tagSizeBytes\":{d},\"computeMode\":\"{s}\",\"device\":\"{s}\"}},\"defaults\":{{\"checkpointIntervalMs\":{d},\"idleSleepMs\":{d}}},\"devices\":[", .{
        if (global_lattice_file) |m| m.data.len else config.UNIFIED_SIZE_BYTES,
        if (global_meaning_file) |m| m.data.len else config.SEMANTIC_SIZE_BYTES,
        if (global_tags_file) |m| m.data.len else config.TAG_SIZE_BYTES,
        core.VERSION,
        config.HYPERVECTOR_BITS,
        config.SEMANTIC_SLOTS,
        if (vk) |live| live.matrix_slots else @as(u32, @intCast(config.SEMANTIC_SLOTS)),
        config.UNIFIED_SIZE_BYTES,
        config.SEMANTIC_SIZE_BYTES,
        config.TAG_SIZE_BYTES,
        compute,
        device,
        DEFAULT_CHECKPOINT_INTERVAL_MS,
        DEFAULT_IDLE_SLEEP_MS,
    });
    if (vsa_vulkan.getFleet()) |fleet| {
        for (fleet.engines, 0..) |gpu, i| {
            if (i > 0) try list.append(',');
            try list.appendSlice("{\"index\":");
            try appendPrint(&list, allocator, "{d},\"name\":\"", .{gpu.device_index});
            try appendEscaped(&list, allocator, trimName(gpu.device_name[0..]));
            try appendPrint(&list, allocator, "\",\"vramMiB\":{d},\"queues\":{d},\"matrixSlots\":{d},\"tier\":\"{s}\"}}", .{
                gpu.vram_size / 1048576,
                gpu.num_queues,
                gpu.matrix_slots,
                tierNameFromValue(@intFromEnum(gpu.tier)),
            });
        }
    }
    try list.appendSlice("],\"corpora\":");
    try appendCorpusFilesJson(&list, allocator, corpora);
    try list.append('}');
    return list.toOwnedSlice();
}

fn buildProbeJson(allocator: std.mem.Allocator) ![]u8 {
    const vk = vsa_vulkan.getEngine();
    const lattice = if (vk) |live| live.getLatticeData() else (global_lattice orelse &[_]u16{});
    const tags = if (vk) |live| live.getTagsData() else (global_tags orelse &[_]u64{});
    var list = std.ArrayList(u8).init(allocator);
    errdefer list.deinit();
    var histogram: [DEFAULT_HISTOGRAM_BINS]u32 = [_]u32{0} ** DEFAULT_HISTOGRAM_BINS;
    var hot_cells: [DEFAULT_HOT_CELLS]HotCell = [_]HotCell{.{}} ** DEFAULT_HOT_CELLS;
    var max_val: u16 = 0;
    var lattice_nonzero: usize = 0;
    const lattice_step = @max(if (lattice.len == 0) 1 else lattice.len / DEFAULT_SAMPLE_BINS, 1);
    const hist_step = @max(if (lattice.len == 0) 1 else lattice.len / 2048, 1);
    try list.appendSlice("{\"lattice\":[");
    for (0..DEFAULT_SAMPLE_BINS) |i| {
        if (i > 0) try list.append(',');
        const idx = if (lattice.len == 0) 0 else @min(i * lattice_step, lattice.len - 1);
        const value: u16 = if (lattice.len == 0) 0 else lattice[idx];
        if (value != 0) lattice_nonzero += 1;
        if (value > max_val) max_val = value;
        updateHotCells(&hot_cells, idx, value);
        try appendPrint(&list, allocator, "{d}", .{value});
    }
    if (lattice.len > 0) {
        var pos: usize = 0;
        while (pos < lattice.len) : (pos += hist_step) {
            const value = lattice[pos];
            const bucket = @min(@as(usize, value) * DEFAULT_HISTOGRAM_BINS / 65536, DEFAULT_HISTOGRAM_BINS - 1);
            histogram[bucket] += 1;
            if (value > max_val) max_val = value;
            updateHotCells(&hot_cells, pos, value);
        }
    }

    try list.appendSlice("],\"slotBands\":[");
    const tag_step = @max(if (tags.len == 0) 1 else tags.len / DEFAULT_SAMPLE_BINS, 1);
    const used = countUsed(tags);
    for (0..DEFAULT_SAMPLE_BINS) |i| {
        if (i > 0) try list.append(',');
        const start = if (tags.len == 0) 0 else @min(i * tag_step, tags.len);
        const end = if (tags.len == 0) 0 else @min(start + tag_step, tags.len);
        var occupied: usize = 0;
        for (tags[start..end]) |tag| {
            if (tag != 0) occupied += 1;
        }
        const pct = if (end <= start) 0.0 else (@as(f64, @floatFromInt(occupied)) / @as(f64, @floatFromInt(end - start))) * 100.0;
        try appendPrint(&list, allocator, "{d:.2}", .{pct});
    }

    try list.appendSlice("],\"histogram\":[");
    for (histogram, 0..) |bucket, i| {
        if (i > 0) try list.append(',');
        try appendPrint(&list, allocator, "{d}", .{bucket});
    }

    try list.appendSlice("],\"hotCells\":[");
    for (hot_cells, 0..) |cell, i| {
        if (cell.value == 0) break;
        if (i > 0) try list.append(',');
        try appendPrint(&list, allocator, "{{\"index\":{d},\"value\":{d}}}", .{ cell.index, cell.value });
    }
    try appendPrint(&list, allocator, "],\"occupiedLattice\":{d:.4},\"occupiedMonolith\":{d:.4},\"maxLattice\":{d},\"timestamp\":{d}}}", .{
        @as(f64, @floatFromInt(lattice_nonzero)) / @as(f64, @floatFromInt(DEFAULT_SAMPLE_BINS)),
        if (tags.len == 0) 0.0 else @as(f64, @floatFromInt(used)) / @as(f64, @floatFromInt(tags.len)),
        max_val,
        sys.getMilliTick(),
    });
    return list.toOwnedSlice();
}

fn wsHandshake(sock: usize, req: []const u8) bool {
    const key_hdr = "Sec-WebSocket-Key: ";
    const idx = std.mem.indexOf(u8, req, key_hdr) orelse return false;
    const start = idx + key_hdr.len;
    const end = std.mem.indexOf(u8, req[start..], "\r\n") orelse return false;
    const key = req[start .. start + end];
    var concat: [256]u8 = undefined;
    const joined = std.fmt.bufPrint(&concat, "{s}258EAFA5-E914-47DA-95CA-C5AB0DC85B11", .{key}) catch return false;
    var hash: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    std.crypto.hash.Sha1.hash(joined, &hash, .{});
    var b64: [64]u8 = undefined;
    const accept_key = std.base64.standard.Encoder.encode(&b64, &hash);
    var resp: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&resp, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\n\r\n", .{accept_key}) catch return false;
    sendBytes(sock, text);
    return true;
}

fn recvExact(sock: usize, buf: []u8) bool {
    var got: usize = 0;
    while (got < buf.len) {
        const n = recv(sock, buf[got..].ptr, @intCast(buf.len - got), 0);
        if (n <= 0) return false;
        got += @intCast(n);
    }
    return true;
}

fn recvWsText(sock: usize, out: []u8) ?[]u8 {
    var hdr: [2]u8 = undefined;
    if (!recvExact(sock, &hdr)) return null;
    if ((hdr[0] & 0x0F) == 0x8 or (hdr[0] & 0x0F) != 0x1) return null;
    var len: usize = hdr[1] & 0x7F;
    if (len == 126) {
        var ext: [2]u8 = undefined;
        if (!recvExact(sock, &ext)) return null;
        len = (@as(usize, ext[0]) << 8) | @as(usize, ext[1]);
    } else if (len == 127 or len > out.len or (hdr[1] & 0x80) == 0) return null;
    var mask: [4]u8 = undefined;
    if (!recvExact(sock, &mask) or !recvExact(sock, out[0..len])) return null;
    for (out[0..len], 0..) |*b, i| b.* ^= mask[i % 4];
    return out[0..len];
}

const WsWriteBuffer = struct {
    data: [WS_WRITE_BUFFER_CAPACITY]u8 = [_]u8{0} ** WS_WRITE_BUFFER_CAPACITY,
    len: usize = 0,
    sent: usize = 0,

    fn reset(self: *WsWriteBuffer) void {
        self.len = 0;
        self.sent = 0;
    }

    fn queueJson(self: *WsWriteBuffer, typ: []const u8, content: ?[]const u8) !void {
        self.reset();

        var payload = std.ArrayList(u8).init(global_allocator);
        defer payload.deinit();

        try payload.appendSlice("{\"type\":\"");
        try appendEscaped(&payload, global_allocator, typ);
        try payload.append('"');
        if (content) |value| {
            try payload.appendSlice(",\"content\":\"");
            try appendEscaped(&payload, global_allocator, value);
            try payload.append('"');
        }
        try payload.append('}');

        const payload_len = payload.items.len;

        if (payload_len < 126) {
            self.data[0] = 0x81;
            self.data[1] = @intCast(payload_len);
            @memcpy(self.data[2 .. 2 + payload_len], payload.items[0..payload_len]);
            self.len = 2 + payload_len;
            return;
        }
        if (payload_len > WS_WRITE_BUFFER_CAPACITY - 4) return error.FrameTooLarge;

        self.data[0] = 0x81;
        self.data[1] = 126;
        self.data[2] = @intCast((payload_len >> 8) & 0xFF);
        self.data[3] = @intCast(payload_len & 0xFF);
        @memcpy(self.data[4 .. 4 + payload_len], payload.items[0..payload_len]);
        self.len = 4 + payload_len;
    }

    fn flush(self: *WsWriteBuffer, sock: usize) !bool {
        if (self.sent >= self.len) return true;
        const done = try sendNonBlocking(sock, self.data[0..self.len], &self.sent);
        if (done) self.reset();
        return done;
    }
};

fn sendWsJson(sock: usize, typ: []const u8, content: ?[]const u8) void {
    var writer = WsWriteBuffer{};
    writer.queueJson(typ, content) catch return;
    while (true) {
        const done = writer.flush(sock) catch return;
        if (done) return;
        sys.sleep(CHAT_STREAM_POLL_MS);
    }
}

fn absorbPrompt(soul: *ghost_state.GhostSoul, text: []const u8) !void {
    var iter = (std.unicode.Utf8View.init(text) catch return error.InvalidUtf8).iterator();
    while (iter.nextCodepoint()) |rune| _ = try soul.absorb(vsa.generate(rune), rune, null);
}

fn resetChatEngine(live: *engine.SingularityEngine) void {
    @memset(std.mem.sliceAsBytes(live.canvas.cells), 0);
    @memset(live.canvas.noise, 0);
    live.canvas.cursor = 0;
    @memset(live.inventory[0..], 0);
    live.inv_cursor = 0;
    live.rune_counter = 0;
    live.ema = .{};
    live.is_live = isTrainingActive();
}

fn streamChatChunk(exchange: *ChatExchange, kind: ChatStreamFrameKind, chunk: []const u8) void {
    _ = exchange.stream.tryPush(kind, chunk);
}

fn renderChatResponse(live: *engine.SingularityEngine, prompt: []const u8, exchange: *ChatExchange) !void {
    if (stop_flag.load(.acquire)) {
        exchange.fail("Shutdown requested.");
        return;
    }
    if (config.force_cpu_inference) {
        var chunk_buf: [CHAT_CHUNK_CAPACITY]u8 = undefined;
        const clipped = prompt[0..@min(prompt.len, 48)];
        const text = std.fmt.bufPrint(&chunk_buf, "CPU bypass ok: {s}", .{clipped}) catch "CPU bypass ok";
        streamChatChunk(exchange, .partial, text);
        exchange.finish();
        return;
    }

    lockInference();
    errdefer unlockInference();
    resetChatEngine(live);
    try absorbPrompt(live.soul, prompt);
    unlockInference();

    var chunk: [CHAT_CHUNK_CAPACITY]u8 = undefined;
    var chunk_len: usize = 0;

    for (0..200) |_| {
        if (stop_flag.load(.acquire)) {
            exchange.fail("Shutdown requested.");
            return;
        }
        lockInference();
        const decision = live.resolveText1D();
        unlockInference();
        if (decision.stop_reason != .none) break;
        const cp = decision.output;
        if (cp == 0 or cp == core.inference.UNRESOLVED_OUTPUT) break;

        var utf8: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(@intCast(cp), &utf8) catch 0;
        if (n == 0) continue;

        if (chunk_len + n > chunk.len) {
            streamChatChunk(exchange, .partial, chunk[0..chunk_len]);
            chunk_len = 0;
        }

        @memcpy(chunk[chunk_len .. chunk_len + n], utf8[0..n]);
        chunk_len += n;

        if (chunk_len >= 48 or cp == ' ' or cp == '\n') {
            streamChatChunk(exchange, .partial, chunk[0..chunk_len]);
            chunk_len = 0;
        }

        std.Thread.yield() catch {};
    }

    if (chunk_len > 0) streamChatChunk(exchange, .partial, chunk[0..chunk_len]);
    exchange.finish();
}

fn inferenceActorThread() void {
    _ = global_background_workers.fetchAdd(1, .acq_rel);
    defer _ = global_background_workers.fetchSub(1, .acq_rel);
    while (true) {
        const request = global_chat_queue.pop() orelse {
            if (global_chat_queue.isShutdown()) break;
            std.Thread.yield() catch {};
            continue;
        };
        const exchange = request.exchange;

        if (stop_flag.load(.acquire)) {
            exchange.fail("Shutdown requested.");
            continue;
        }

        const live = global_engine;
        if (live) |engine_ref| {
            renderChatResponse(engine_ref, request.prompt[0..request.prompt_len], exchange) catch |err| {
                var message_buf: [CHAT_CHUNK_CAPACITY]u8 = undefined;
                const message = std.fmt.bufPrint(&message_buf, "Inference failed: {any}", .{err}) catch "Inference failed.";
                exchange.fail(message);
            };
            global_ema_average.store(engine_ref.ema.average, .release);
            global_ema_deviation.store(engine_ref.ema.deviation, .release);
        } else {
            exchange.fail("Engine unavailable.");
        }
    }
}

fn drainChatExchange(sock: usize, exchange: *ChatExchange) bool {
    var writer = WsWriteBuffer{};
    var reported_drop = false;
    var sent_failure = false;
    var sent_done = false;

    while (true) {
        if (writer.len != 0) {
            const flushed = writer.flush(sock) catch return false;
            if (!flushed) {
                sys.sleep(CHAT_STREAM_POLL_MS);
                continue;
            }
        }

        if (exchange.stream.pop()) |frame| {
            const frame_type = switch (frame.kind) {
                .partial => "partial",
                .err => "error",
            };
            writer.queueJson(frame_type, frame.textSlice()) catch return false;
            continue;
        }

        if (!reported_drop and exchange.stream.hasDroppedFrames()) {
            reported_drop = true;
            writer.queueJson("error", "Partial frames dropped because the client could not keep up.") catch return false;
            continue;
        }

        if (exchange.isComplete()) {
            if (exchange.failed() and !sent_failure) {
                sent_failure = true;
                writer.queueJson("error", exchange.errorText()) catch return false;
                continue;
            }
            if (sent_done) return true;
            sent_done = true;
            writer.queueJson("done", null) catch return false;
            while (true) {
                const done = writer.flush(sock) catch return false;
                if (done) return true;
                sys.sleep(CHAT_STREAM_POLL_MS);
            }
        }

        sys.sleep(CHAT_STREAM_POLL_MS);
    }
}

fn chatThread(sock: usize) void {
    defer unregisterActiveSocket(sock);
    defer closeTrackedSocket(sock);
    sendWsJson(sock, "connected", "Ghost link established.");
    var frame: [4096]u8 = undefined;
    while (!stop_flag.load(.acquire)) {
        const msg = recvWsText(sock, &frame) orelse break;
        var kind_buf: [64]u8 = undefined;
        const kind = jsonString(msg, "type", &kind_buf) orelse continue;
        if (!std.mem.eql(u8, kind, "input")) continue;
        var text_buf: [2048]u8 = undefined;
        const prompt = jsonString(msg, "text", &text_buf) orelse continue;
        var exchange = ChatExchange{};
        _ = global_active_chat_exchanges.fetchAdd(1, .acq_rel);
        global_chat_queue.push(&exchange, prompt) catch |err| {
            _ = global_active_chat_exchanges.fetchSub(1, .acq_rel);
            var err_buf: [CHAT_CHUNK_CAPACITY]u8 = undefined;
            const message = std.fmt.bufPrint(&err_buf, "Prompt rejected: {any}", .{err}) catch "Prompt rejected.";
            sendWsJson(sock, "error", message);
            continue;
        };

        setSocketNonBlocking(sock) catch {
            _ = global_active_chat_exchanges.fetchSub(1, .acq_rel);
            sendWsJson(sock, "error", "Failed to enable streaming mode.");
            break;
        };
        const stream_ok = drainChatExchange(sock, &exchange);
        setSocketBlocking(sock) catch {};
        _ = global_active_chat_exchanges.fetchSub(1, .acq_rel);
        if (!stream_ok) break;
    }
}

fn initServerSocket(port: u16) !usize {
    var wsadata: [512]u8 = undefined;
    _ = WSAStartup(0x0202, &wsadata);
    const server = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (server == INVALID_SOCKET) {
        _ = WSACleanup();
        return error.SocketCreateFailed;
    }
    var nonblocking: u32 = 1;
    if (ioctlsocket(server, FIONBIO, &nonblocking) != 0) {
        closeSocketNow(server);
        _ = WSACleanup();
        return error.SocketConfigureFailed;
    }
    const addr = sockaddr_in{ .sin_family = AF_INET, .sin_port = std.mem.nativeToBig(u16, port), .sin_addr = std.mem.nativeToBig(u32, 0x7F000001) };
    if (bind(server, @ptrCast(&addr), @sizeOf(sockaddr_in)) != 0) {
        closeSocketNow(server);
        _ = WSACleanup();
        return error.BindFailed;
    }
    if (listen(server, 1024) != 0) {
        closeSocketNow(server);
        _ = WSACleanup();
        return error.ListenFailed;
    }
    return server;
}

fn setSocketBlocking(sock: usize) !void {
    var blocking: u32 = 0;
    if (ioctlsocket(sock, FIONBIO, &blocking) != 0) return error.SocketConfigureFailed;
}

fn setSocketNonBlocking(sock: usize) !void {
    var nonblocking: u32 = 1;
    if (ioctlsocket(sock, FIONBIO, &nonblocking) != 0) return error.SocketConfigureFailed;
}

fn serveLoop(allocator: std.mem.Allocator, server: usize) !void {
    sys.printOut("[HTTP] Honest Operator Console at http://127.0.0.1:8080\n");

    while (!stop_flag.load(.acquire)) {
        const client = accept(server, null, null);
        if (client == INVALID_SOCKET) {
            const err = WSAGetLastError();
            if (err == WSAEWOULDBLOCK) {
                sys.sleep(SHUTDOWN_POLL_MS);
                continue;
            }
            sys.print("[HTTP] Accept error: {d}\n", .{err});
            break;
        }
        if (stop_flag.load(.acquire)) {
            closeSocketNow(client);
            continue;
        }
        setSocketBlocking(client) catch |err| {
            sys.print("[HTTP] Failed to reset client socket to blocking mode: {any}\n", .{err});
            closeSocketNow(client);
            continue;
        };
        var req_buf: [16384]u8 = undefined;
        const n = recv(client, &req_buf, req_buf.len, 0);
        if (n <= 0) {
            closeSocketNow(client);
            continue;
        }
        const req = req_buf[0..@intCast(n)];
        const body = if (std.mem.indexOf(u8, req, "\r\n\r\n")) |idx| req[idx + 4 ..] else req[0..0];
        const head = parseRequestHead(req) orelse {
            sendJsonError(client, .bad_request, "Malformed HTTP request");
            closeSocketNow(client);
            continue;
        };

        if (head.method == .OPTIONS) {
            sendResponse(client, .no_content, "text/plain", "");
        } else if (head.method == .GET and std.mem.eql(u8, head.target, "/?channel=chat")) {
            if (std.mem.indexOf(u8, req, "Upgrade: websocket") == null) {
                sendJsonError(client, .bad_request, "WebSocket upgrade required");
            } else if (!wsHandshake(client, req)) {
                sendJsonError(client, .bad_request, "WebSocket handshake failed");
            } else {
                if (!registerActiveSocket(client)) {
                    closeSocketNow(client);
                    continue;
                }
                const t = std.Thread.spawn(.{ .allocator = allocator }, chatThread, .{client}) catch |err| {
                    unregisterActiveSocket(client);
                    closeSocketNow(client);
                    return err;
                };
                t.detach();
                continue;
            }
        } else if (head.method == .GET and std.mem.eql(u8, head.target, "/")) {
            sendResponse(client, .ok, "text/html; charset=utf-8", DASHBOARD_HTML);
        } else if (head.method == .GET and std.mem.eql(u8, head.target, "/api/stats")) {
            const json = try buildStatsJson(allocator);
            defer allocator.free(json);
            sendJsonResponse(client, .ok, json);
        } else if (head.method == .GET and std.mem.eql(u8, head.target, "/api/corpora")) {
            const json = try buildCorporaJson(allocator);
            defer allocator.free(json);
            sendJsonResponse(client, .ok, json);
        } else if (head.method == .GET and std.mem.eql(u8, head.target, "/api/state")) {
            const json = try buildStateJson(allocator);
            defer allocator.free(json);
            sendJsonResponse(client, .ok, json);
        } else if (head.method == .GET and std.mem.eql(u8, head.target, "/api/probe")) {
            const json = try buildProbeJson(allocator);
            defer allocator.free(json);
            sendJsonResponse(client, .ok, json);
        } else if (head.method == .POST and std.mem.eql(u8, head.target, "/api/train")) {
            const req_train = parseTrainRequest(allocator, body) catch |err| {
                switch (err) {
                    error.OutOfMemory => sendJsonError(client, .internal_server_error, "Failed to parse training request"),
                    else => sendJsonError(client, .bad_request, "Invalid training request body"),
                }
                closeSocketNow(client);
                continue;
            };
            defer freeTrainRequest(allocator, req_train);
            const resp = startTraining(req_train);
            sendJsonResponse(client, resp.status, resp.body);
        } else if (head.method == .POST and std.mem.eql(u8, head.target, "/api/stoptrain")) {
            const resp = requestStopTraining();
            sendJsonResponse(client, resp.status, resp.body);
        } else if (head.method == .POST and std.mem.eql(u8, head.target, "/api/pause")) {
            const resp = pauseTraining();
            sendJsonResponse(client, resp.status, resp.body);
        } else if (head.method == .POST and std.mem.eql(u8, head.target, "/api/resume")) {
            const resp = resumeTraining();
            sendJsonResponse(client, resp.status, resp.body);
        } else if (head.method == .POST and std.mem.eql(u8, head.target, "/api/checkpoint")) {
            const resp = requestCheckpointNow();
            sendJsonResponse(client, resp.status, resp.body);
        } else if (head.method == .POST and std.mem.eql(u8, head.target, "/api/control")) {
            const resp = applyControlUpdate(body);
            sendJsonResponse(client, resp.status, resp.body);
        } else if (head.method == .POST and std.mem.eql(u8, head.target, "/api/sigil")) {
            handleSigilRequest(client, allocator, body);
        } else {
            sendJsonError(client, .not_found, "Route not found");
        }
        closeSocketNow(client);
    }
}

fn serveThread(allocator: std.mem.Allocator, server: usize, port: u16) void {
    defer closeSocketNow(server);
    defer _ = WSACleanup();

    serveLoop(allocator, server) catch |err| {
        sys.print("[FATAL] Embedded shell failed while serving port {d}: {any}\n", .{ port, err });
        _ = requestStop();
    };
}

pub fn startEmbedded(init: EmbeddedInit) !void {
    global_allocator = init.allocator;
    stop_flag.store(false, .release);
    global_chat_queue = .{};
    global_active_chat_exchanges.store(0, .release);
    global_active_sockets = .empty;
    global_background_workers.store(0, .release);
    global_soul = init.soul;
    global_engine = init.live_engine;
    global_lattice_file = init.lattice_file;
    global_meaning_file = init.meaning_file;
    global_tags_file = init.tags_file;
    global_scratchpad = init.scratchpad;
    global_state_paths = init.state_paths;
    global_lattice = init.lattice_words;
    global_meaning = init.meaning_words;
    global_tags = init.tags_words;
    global_ema_average.store(init.live_engine.ema.average, .release);
    global_ema_deviation.store(init.live_engine.ema.deviation, .release);

    const server_socket = try initServerSocket(init.port);

    const inference_actor = try std.Thread.spawn(.{ .allocator = global_allocator }, inferenceActorThread, .{});
    inference_actor.detach();

    const server = try std.Thread.spawn(.{ .allocator = global_allocator }, serveThread, .{ global_allocator, server_socket, init.port });
    server.detach();
    sys.printOut("◈ Ghost Shell Online ◈\n");
}
