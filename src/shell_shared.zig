const std = @import("std");
const core = @import("ghost_core");
const trainer = @import("trainer.zig");
const vsa_vulkan = core.vsa_vulkan;
const sigil_runtime = core.sigil_runtime;
const config = core.config;

// ── Shared constants ──

pub const DEFAULT_CHECKPOINT_INTERVAL_MS: u32 = 60_000;
pub const DEFAULT_IDLE_SLEEP_MS: u32 = 10;
pub const DEFAULT_SAMPLE_BINS: usize = 96;
pub const DEFAULT_HISTOGRAM_BINS: usize = 16;
pub const DEFAULT_HOT_CELLS: usize = 8;
pub const CHAT_QUEUE_CAPACITY = 32;
pub const CHAT_PROMPT_CAPACITY = 2048;
pub const CHAT_CHUNK_CAPACITY = 128;
pub const CHAT_STREAM_QUEUE_CAPACITY = 64;
pub const SHUTDOWN_DRAIN_TIMEOUT_MS: u32 = 3_000;
pub const SHUTDOWN_POLL_MS: u32 = 10;
pub const CHAT_STREAM_POLL_MS: u32 = 1;
pub const WS_WRITE_BUFFER_CAPACITY = 1024;
pub const FALLBACK_CORPORA = [_][]const u8{
    "tiny_shakespeare.txt",
    "mixed_sovereign.txt",
};

// ── Shared types ──

pub const CorpusFile = struct {
    name: []const u8,
    size_bytes: usize,
};

pub const HotCell = struct {
    index: usize = 0,
    value: u16 = 0,
};

pub const TrainRequest = struct {
    tier: u32,
    corpora: [][]const u8,
    gpu_ids: []u32,
    weights: []trainer.CorpusWeight,
    batch_size_override: u32,
    max_active_streams: u32,
    checkpoint_interval_ms: u32,
    stop_after_minutes: u32,
    stop_after_runes: u64,
    stop_after_slot_usage_bp: u32,
    idle_sleep_ms: u32,
};

pub const ChatStreamFrameKind = enum(u8) {
    partial,
    err,
};

pub const ChatStreamFrame = struct {
    kind: ChatStreamFrameKind = .partial,
    text_len: u16 = 0,
    text: [CHAT_CHUNK_CAPACITY]u8 = [_]u8{0} ** CHAT_CHUNK_CAPACITY,

    pub fn set(self: *ChatStreamFrame, kind: ChatStreamFrameKind, chunk: []const u8) void {
        self.kind = kind;
        const len = @min(chunk.len, self.text.len);
        @memcpy(self.text[0..len], chunk[0..len]);
        self.text_len = @intCast(len);
        if (len < self.text.len) @memset(self.text[len..], 0);
    }

    pub fn textSlice(self: *const ChatStreamFrame) []const u8 {
        return self.text[0..self.text_len];
    }
};

pub const ChatStreamQueue = struct {
    write_index: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    read_index: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    dropped_frames: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    frames: [CHAT_STREAM_QUEUE_CAPACITY]ChatStreamFrame = [_]ChatStreamFrame{.{}} ** CHAT_STREAM_QUEUE_CAPACITY,

    pub fn tryPush(self: *ChatStreamQueue, kind: ChatStreamFrameKind, chunk: []const u8) bool {
        const write = self.write_index.load(.acquire);
        const read = self.read_index.load(.acquire);
        if (write - read >= self.frames.len) {
            self.dropped_frames.store(true, .release);
            return false;
        }

        const idx = write & (self.frames.len - 1);
        self.frames[idx].set(kind, chunk);
        self.write_index.store(write + 1, .release);
        return true;
    }

    pub fn pop(self: *ChatStreamQueue) ?ChatStreamFrame {
        const read = self.read_index.load(.acquire);
        const write = self.write_index.load(.acquire);
        if (read == write) return null;

        const idx = read & (self.frames.len - 1);
        const frame = self.frames[idx];
        self.read_index.store(read + 1, .release);
        return frame;
    }

    pub fn hasDroppedFrames(self: *const ChatStreamQueue) bool {
        return self.dropped_frames.load(.acquire);
    }
};

pub const ChatExchange = struct {
    status: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    stream: ChatStreamQueue = .{},
    error_len: u16 = 0,
    error_buf: [CHAT_CHUNK_CAPACITY]u8 = [_]u8{0} ** CHAT_CHUNK_CAPACITY,

    pub fn fail(self: *ChatExchange, message: []const u8) void {
        const len = @min(message.len, self.error_buf.len);
        @memcpy(self.error_buf[0..len], message[0..len]);
        self.error_len = @intCast(len);
        self.status.store(2, .release);
    }

    pub fn finish(self: *ChatExchange) void {
        self.status.store(1, .release);
    }

    pub fn isComplete(self: *const ChatExchange) bool {
        return self.status.load(.acquire) != 0;
    }

    pub fn failed(self: *const ChatExchange) bool {
        return self.status.load(.acquire) == 2;
    }

    pub fn errorText(self: *const ChatExchange) []const u8 {
        return self.error_buf[0..self.error_len];
    }
};

pub const ChatRequest = struct {
    exchange: *ChatExchange,
    prompt_len: u16,
    prompt: [CHAT_PROMPT_CAPACITY]u8,
};

pub const Lock = struct {
    state: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    pub fn lock(self: *Lock) void {
        while (self.state.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    pub fn unlock(self: *Lock) void {
        self.state.store(0, .release);
    }
};

pub const TrackedSocket = struct {
    sock: usize,
    closed: bool = false,
};

pub const HttpJsonResult = struct {
    status: std.http.Status,
    body: []const u8,
};

pub const RequestHead = struct {
    method: std.http.Method,
    target: []const u8,
};

// ── JSON parsing utilities (stateless) ──

pub fn trimName(buf: []const u8) []const u8 {
    var end: usize = 0;
    while (end < buf.len and buf[end] != 0) : (end += 1) {}
    return buf[0..end];
}

pub fn contains(items: [][]const u8, needle: []const u8) bool {
    for (items) |item| if (std.mem.eql(u8, item, needle)) return true;
    return false;
}

pub fn decodeJsonString(raw: []const u8, out: []u8) ?[]const u8 {
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

pub fn jsonString(body: []const u8, key: []const u8, out: []u8) ?[]const u8 {
    var pat_buf: [96]u8 = undefined;
    const pat = std.fmt.bufPrint(&pat_buf, "\"{s}\":\"", .{key}) catch return null;
    const idx = std.mem.indexOf(u8, body, pat) orelse return null;
    return decodeJsonString(body[idx + pat.len ..], out);
}

pub fn jsonStringArray(allocator: std.mem.Allocator, body: []const u8, key: []const u8) ![][]const u8 {
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

pub fn jsonNumberSlice(body: []const u8, key: []const u8) ?[]const u8 {
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

pub fn jsonU32(body: []const u8, key: []const u8, fallback: u32) u32 {
    const raw = jsonNumberSlice(body, key) orelse return fallback;
    return std.fmt.parseInt(u32, raw, 10) catch fallback;
}

pub fn jsonU64(body: []const u8, key: []const u8, fallback: u64) u64 {
    const raw = jsonNumberSlice(body, key) orelse return fallback;
    return std.fmt.parseInt(u64, raw, 10) catch fallback;
}

pub fn jsonF64(body: []const u8, key: []const u8, fallback: f64) f64 {
    const raw = jsonNumberSlice(body, key) orelse return fallback;
    return std.fmt.parseFloat(f64, raw) catch fallback;
}

pub fn parseTierFlag(flag: []const u8) u32 {
    return if (std.mem.eql(u8, flag, "--background"))
        @intFromEnum(vsa_vulkan.OperationalTier.background)
    else if (std.mem.eql(u8, flag, "--high"))
        @intFromEnum(vsa_vulkan.OperationalTier.high)
    else if (std.mem.eql(u8, flag, "--max"))
        @intFromEnum(vsa_vulkan.OperationalTier.max)
    else
        @intFromEnum(vsa_vulkan.OperationalTier.standard);
}

pub fn jsonU32Array(allocator: std.mem.Allocator, body: []const u8, key: []const u8) ![]u32 {
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

pub fn jsonWeightMap(allocator: std.mem.Allocator, body: []const u8, key: []const u8) ![]trainer.CorpusWeight {
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

// ── Tier/stop helpers (stateless) ──

pub fn tierValueFromText(flag: []const u8) u32 {
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

pub fn tierNameFromValue(value: u32) []const u8 {
    return @tagName(@as(vsa_vulkan.OperationalTier, @enumFromInt(value)));
}

pub fn stopReasonName(reason: trainer.StopReason) []const u8 {
    return @tagName(reason);
}

// ── Request parsing (stateless) ──

pub fn parseTrainRequest(allocator: std.mem.Allocator, body: []const u8) !TrainRequest {
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

pub fn freeTrainRequest(allocator: std.mem.Allocator, req: TrainRequest) void {
    for (req.corpora) |item| allocator.free(item);
    allocator.free(req.corpora);
    allocator.free(req.gpu_ids);
    for (req.weights) |item| allocator.free(item.name);
    allocator.free(req.weights);
}

pub fn weightForCorpus(weights: []const trainer.CorpusWeight, corpus_name: []const u8) u32 {
    for (weights) |weight| {
        if (std.mem.eql(u8, weight.name, corpus_name)) return @max(weight.weight, 1);
    }
    return 1;
}

// ── JSON serialization helpers (stateless) ──

pub fn appendEscaped(list: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    for (text) |c| {
        switch (c) {
            '"' => try list.appendSlice(allocator, "\\\""),
            '\\' => try list.appendSlice(allocator, "\\\\"),
            '\n' => try list.appendSlice(allocator, "\\n"),
            '\r' => try list.appendSlice(allocator, "\\r"),
            '\t' => try list.appendSlice(allocator, "\\t"),
            else => try list.append(allocator, c),
        }
    }
}

pub fn appendPrint(list: *std.ArrayList(u8), allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const result = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(result);
    try list.appendSlice(allocator, result);
}

pub fn countUsed(tags: []const u64) usize {
    var count: usize = 0;
    for (tags) |tag| {
        if (tag != 0) count += 1;
    }
    return count;
}

pub fn updateHotCells(hot_cells: *[DEFAULT_HOT_CELLS]HotCell, idx: usize, value: u16) void {
    var insert_pos: usize = DEFAULT_HOT_CELLS;
    for (hot_cells, 0..) |cell, i| {
        if (value > cell.value) {
            insert_pos = i;
            break;
        }
    }
    if (insert_pos < DEFAULT_HOT_CELLS) {
        var i: usize = DEFAULT_HOT_CELLS - 1;
        while (i > insert_pos) : (i -= 1) {
            hot_cells[i] = hot_cells[i - 1];
        }
        hot_cells[insert_pos] = .{ .index = idx, .value = value };
    }
}

// ── Sigil helpers (stateless) ──

pub fn parseSigilScriptBody(body: []const u8, scratch: []u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, body, " \r\n\t");
    if (trimmed.len == 0) return error.EmptyBody;
    if (trimmed[0] != '{') return trimmed;

    const script = jsonLooseString(trimmed, "script", scratch) orelse jsonLooseString(trimmed, "sigil", scratch) orelse return error.InvalidJson;
    const cleaned = std.mem.trim(u8, script, " \r\n\t");
    if (cleaned.len == 0) return error.EmptyBody;
    return cleaned;
}

pub fn jsonLooseString(body: []const u8, key: []const u8, out: []u8) ?[]const u8 {
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

pub fn controlMoodName(snapshot: sigil_runtime.ControlSnapshot) []const u8 {
    if (snapshot.saturation_bonus == 96 and snapshot.boredom_penalty_high == 8 and snapshot.boredom_penalty_low == 4) return "aggressive";
    if (snapshot.saturation_bonus == 80 and snapshot.boredom_penalty_high == 16 and snapshot.boredom_penalty_low == 8) return "focused";
    if (snapshot.saturation_bonus == 40 and snapshot.boredom_penalty_high == 40 and snapshot.boredom_penalty_low == 20) return "calm";
    if (snapshot.saturation_bonus == config.SATURATION_BONUS and
        snapshot.boredom_penalty_high == config.BOREDOM_PENALTY_HIGH and
        snapshot.boredom_penalty_low == config.BOREDOM_PENALTY_LOW) return "default";
    return "custom";
}

pub fn buildSigilStateJson(allocator: std.mem.Allocator, snapshot: sigil_runtime.ControlSnapshot) ![]u8 {
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
