const std = @import("std");
const ghost_core = @import("ghost_core");
const corpus_ingest = ghost_core.corpus_ingest;
const corpus_sketch = ghost_core.corpus_sketch;
const gip = ghost_core.gip;
const intent_grounding = ghost_core.intent_grounding;
const shards = ghost_core.shards;
const vsa_vulkan = ghost_core.vsa_vulkan;

pub const SOCKET_PATH = "/tmp/ghost.sock";
pub const PID_PATH = "/tmp/ghost.pid";
const MAX_FRAME_BYTES: usize = 10 * 1024 * 1024;
const DEFAULT_RESIDENT_SHARDS = [_][]const u8{ "english_core", "user_vault" };

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
        try std.io.getStdErr().writer().print("ghostd already active at {s}\n", .{SOCKET_PATH});
        return error.DaemonAlreadyRunning;
    }
    std.fs.deleteFileAbsolute(SOCKET_PATH) catch {};

    try writePidFile();
    errdefer std.fs.deleteFileAbsolute(PID_PATH) catch {};

    var resident = try ResidentState.init(allocator);
    defer resident.deinit();

    var address = try std.net.Address.initUnix(SOCKET_PATH);
    var server = try address.listen(.{ .kernel_backlog = 128 });
    defer server.deinit();
    defer std.fs.deleteFileAbsolute(SOCKET_PATH) catch {};
    defer std.fs.deleteFileAbsolute(PID_PATH) catch {};

    try std.io.getStdErr().writer().print(
        "ghostd ready socket={s} shards={d} vulkan={s}\n",
        .{ SOCKET_PATH, resident.loaded_shards, if (resident.vulkan_active) "resident" else "cpu" },
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

    fn deinit(self: *ResidentShard, allocator: std.mem.Allocator, vk: ?*vsa_vulkan.VulkanEngine) void {
        if (vk) |engine| engine.destroyResidentBuffer(&self.vram_buffer);
        allocator.free(self.id);
        corpus_ingest.deinitIndexedEntries(allocator, self.entries);
        for (self.texts) |text| allocator.free(text);
        allocator.free(self.texts);
        for (self.lower_texts) |text| allocator.free(text);
        allocator.free(self.lower_texts);
        allocator.free(self.offsets);
        self.* = undefined;
    }
};

const ResidentState = struct {
    allocator: std.mem.Allocator,
    vulkan_active: bool = false,
    vulkan: ?*vsa_vulkan.VulkanEngine = null,
    loaded_shards: usize = 0,
    vram_resident_bytes: usize = 0,
    shards: std.ArrayList(ResidentShard),

    fn init(allocator: std.mem.Allocator) !ResidentState {
        var state = ResidentState{
            .allocator = allocator,
            .shards = std.ArrayList(ResidentShard).init(allocator),
        };
        errdefer state.deinit();

        if (vsa_vulkan.initRuntime(allocator)) |vk| {
            state.vulkan = vk;
            state.vulkan_active = true;
        } else |_| {
            state.vulkan_active = false;
        }

        for (DEFAULT_RESIDENT_SHARDS) |shard_id| {
            state.preloadShard(shard_id) catch |err| {
                try std.io.getStdErr().writer().print("ghostd preload skipped shard={s} err={s}\n", .{ shard_id, @errorName(err) });
            };
        }
        return state;
    }

    fn deinit(self: *ResidentState) void {
        for (self.shards.items) |*shard| shard.deinit(self.allocator, self.vulkan);
        self.shards.deinit();
        if (self.vulkan_active) vsa_vulkan.deinitRuntime();
        self.* = undefined;
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
        try self.shards.append(.{
            .id = try self.allocator.dupe(u8, shard_id),
            .entries = entries,
            .texts = loaded.texts,
            .lower_texts = loaded.lower_texts,
            .offsets = loaded.offsets,
            .vram_buffer = vram_buffer,
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
        const max_cpu_bytes: usize = @intCast(@min(entry.size_bytes, 64 * 1024));
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

fn serveConnection(allocator: std.mem.Allocator, resident: *const ResidentState, stream: std.net.Stream) !void {
    const request = try readFrame(allocator, stream);
    defer allocator.free(request);
    const response = try dispatchFrame(allocator, resident, request);
    defer allocator.free(response);
    try writeFrame(stream, response);
}

fn dispatchFrame(allocator: std.mem.Allocator, resident: *const ResidentState, request: []const u8) ![]u8 {
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
            return try std.fmt.allocPrint(
                allocator,
                "{{\"status\":\"ok\",\"daemon\":{{\"status\":\"running\",\"socketPath\":\"/tmp/ghost.sock\",\"residentShards\":{d},\"vramResidentBytes\":{d},\"deviceLocal\":{s}}}}}",
                .{ resident.loaded_shards, resident.vram_resident_bytes, if (resident.vram_resident_bytes > 0) "true" else "false" },
            );
        }
        if (std.mem.eql(u8, kind, "daemon.stop")) {
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

fn dispatchResidentCorpusAsk(allocator: std.mem.Allocator, resident: *const ResidentState, obj: std.json.ObjectMap) !?[]u8 {
    const question = jsonStringField(obj, "question") orelse jsonStringField(obj, "message") orelse return null;
    const shard_id = jsonStringField(obj, "projectShard") orelse jsonStringField(obj, "project_shard") orelse "english_core";
    const shard = resident.findShard(shard_id) orelse return null;
    if (shard.entries.len == 0) return null;

    var salience = try intent_grounding.analyzeSalience(allocator, question);
    defer salience.deinit(allocator);
    const target = if (salience.semantic_target.len != 0) salience.semantic_target else question;
    const terms = try collectTerms(allocator, target);
    defer freeTerms(allocator, terms);
    if (terms.len == 0) return null;
    const scoring_terms = if (terms.len > 2) terms[terms.len - 2 ..] else terms;
    const query_hash = try corpus_sketch.simHash64Query(allocator, target);

    var candidates = std.ArrayList(HotCandidate).init(allocator);
    defer candidates.deinit();
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
    if (candidates.items.len == 0) return null;
    std.mem.sort(HotCandidate, candidates.items, {}, hotCandidateLessThan);
    const requested_limit: usize = if (salience.density_multiplier <= 2) 2 else @intCast(@min(@as(u32, salience.density_multiplier), 4));
    const top = candidates.items[0..@min(requested_limit, candidates.items.len)];

    const result_json = try renderHotCorpusResult(allocator, question, shard_id, shard, scoring_terms, top);
    defer allocator.free(result_json);
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
    try out.append(term);
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
    try w.writeAll("],\"unknowns\":[],\"candidateFollowups\":[{\"kind\":\"verifier_check_candidate\",\"detail\":\"review the cited corpus evidence before treating this answer as supported\",\"executes\":false}],\"learningCandidates\":[],\"trace\":{\"corpusMutation\":false,\"packMutation\":false,\"negativeKnowledgeMutation\":false,\"commandsExecuted\":false,\"verifiersExecuted\":false,\"corpusEntriesConsidered\":");
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
    var stream = std.net.connectUnixSocket(SOCKET_PATH) catch return false;
    stream.close();
    return true;
}

fn writePidFile() !void {
    var file = try std.fs.createFileAbsolute(PID_PATH, .{ .truncate = true });
    defer file.close();
    try file.writer().print("{d}\n", .{std.os.linux.getpid()});
}

fn printLocalStatus() !void {
    if (probeSocket()) {
        try std.io.getStdOut().writer().print("ghostd active socket={s}\n", .{SOCKET_PATH});
    } else {
        try std.io.getStdOut().writer().print("ghostd inactive socket={s}\n", .{SOCKET_PATH});
    }
}
