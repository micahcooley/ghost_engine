const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const inference = @import("inference.zig");
const scratchpad = @import("scratchpad.zig");
const build_options = @import("build_options");

pub const FORMAT_VERSION: u16 = 1;
pub const MAGIC = "GDDP1LE\n";
pub const VERSION_CAP: usize = 16;
pub const PANIC_MESSAGE_CAP: usize = 160;
pub const MAX_CANDIDATES: usize = config.LAYER3_MAX_BRANCHES;
pub const MAX_HYPOTHESES: usize = config.LAYER3_MAX_BRANCHES;
pub const MAX_SCRATCH_REFS: usize = 64;

pub const CandidateRecord = struct {
    char_code: u32 = 0,
    branch_index: u32 = 0,
    base_score: u32 = 0,
    score: u32 = 0,
    confidence: u32 = 0,
};

pub const HypothesisRecord = struct {
    root_char: u32 = 0,
    branch_index: u32 = 0,
    last_char: u32 = 0,
    depth: u32 = 0,
    score: u32 = 0,
    confidence: u32 = 0,
};

pub const ScratchReference = struct {
    slot_index: u32 = 0,
    hash: u64 = 0,
};

pub const Header = struct {
    flags: u32 = 0,
    total_bytes: u32 = 0,
    stop_reason: u8 = 0,
    engine_version_len: u8 = 0,
    panic_message_len: u16 = 0,
    step_count: u32 = 0,
    confidence: u32 = 0,
    candidate_count: u16 = 0,
    candidate_total_count: u16 = 0,
    hypothesis_count: u16 = 0,
    hypothesis_total_count: u16 = 0,
    scratch_ref_count: u16 = 0,
    scratch_ref_total_count: u16 = 0,
};

const FLAG_CANDIDATES_TRUNCATED: u32 = 1 << 0;
const FLAG_HYPOTHESES_TRUNCATED: u32 = 1 << 1;
const FLAG_SCRATCH_REFS_TRUNCATED: u32 = 1 << 2;
const FLAG_HAS_PANIC_MESSAGE: u32 = 1 << 3;

const DUMP_PATH = switch (builtin.os.tag) {
    .linux, .macos => "/tmp/ghost-dd-panic.bin",
    else => "ghost-dd-panic.bin",
};

var registered_scratchpad: ?*const scratchpad.ScratchpadLayer = null;

pub const Recorder = struct {
    last_event: inference.TraceEvent = .{
        .step = 0,
        .active_branches = 0,
    },
    engine_version_len: u8 = 0,
    engine_version: [VERSION_CAP]u8 = [_]u8{0} ** VERSION_CAP,
    panic_message_len: u16 = 0,
    panic_message: [PANIC_MESSAGE_CAP]u8 = [_]u8{0} ** PANIC_MESSAGE_CAP,
    candidate_count: u16 = 0,
    candidate_total_count: u16 = 0,
    hypothesis_count: u16 = 0,
    hypothesis_total_count: u16 = 0,
    scratch_ref_count: u16 = 0,
    scratch_ref_total_count: u16 = 0,
    candidates: [MAX_CANDIDATES]CandidateRecord = [_]CandidateRecord{.{}} ** MAX_CANDIDATES,
    hypotheses: [MAX_HYPOTHESES]HypothesisRecord = [_]HypothesisRecord{.{}} ** MAX_HYPOTHESES,
    scratch_refs: [MAX_SCRATCH_REFS]ScratchReference = [_]ScratchReference{.{}} ** MAX_SCRATCH_REFS,

    pub fn init() Recorder {
        var recorder = Recorder{};
        recorder.copyEngineVersion(build_options.ghost_version);
        return recorder;
    }

    pub fn reset(self: *Recorder) void {
        const version_len = self.engine_version_len;
        const version = self.engine_version;
        self.* = Recorder{};
        self.engine_version_len = version_len;
        self.engine_version = version;
    }

    fn copyEngineVersion(self: *Recorder, version: []const u8) void {
        const len = @min(version.len, self.engine_version.len);
        @memset(self.engine_version[0..], 0);
        @memcpy(self.engine_version[0..len], version[0..len]);
        self.engine_version_len = @intCast(len);
    }

    pub fn notePanicMessage(self: *Recorder, msg: []const u8) void {
        const len = @min(msg.len, self.panic_message.len);
        @memset(self.panic_message[0..], 0);
        @memcpy(self.panic_message[0..len], msg[0..len]);
        self.panic_message_len = @intCast(len);
    }

    pub fn captureHook(
        ctx: ?*anyopaque,
        event: inference.TraceEvent,
        candidates: []const inference.Candidate,
        hypotheses: []const inference.HypothesisSnapshot,
    ) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx.?));
        self.capture(event, candidates, hypotheses);
    }

    pub fn capture(
        self: *Recorder,
        event: inference.TraceEvent,
        candidates: []const inference.Candidate,
        hypotheses: []const inference.HypothesisSnapshot,
    ) void {
        self.last_event = event;

        self.candidate_total_count = saturatingCount(candidates.len);
        self.candidate_count = @intCast(@min(candidates.len, self.candidates.len));
        const stored_candidates: usize = @intCast(self.candidate_count);
        for (candidates[0..stored_candidates], 0..) |candidate, idx| {
            self.candidates[idx] = .{
                .char_code = candidate.char_code,
                .branch_index = candidate.branch_index,
                .base_score = candidate.base_score,
                .score = candidate.score,
                .confidence = candidate.confidence,
            };
        }
        var candidate_idx: usize = stored_candidates;
        while (candidate_idx < self.candidates.len) : (candidate_idx += 1) self.candidates[candidate_idx] = .{};

        self.hypothesis_total_count = saturatingCount(hypotheses.len);
        self.hypothesis_count = @intCast(@min(hypotheses.len, self.hypotheses.len));
        const stored_hypotheses: usize = @intCast(self.hypothesis_count);
        for (hypotheses[0..stored_hypotheses], 0..) |hypothesis, idx| {
            self.hypotheses[idx] = .{
                .root_char = hypothesis.root_char,
                .branch_index = hypothesis.branch_index,
                .last_char = hypothesis.last_char,
                .depth = hypothesis.depth,
                .score = hypothesis.score,
                .confidence = hypothesis.confidence,
            };
        }
        var hypothesis_idx: usize = stored_hypotheses;
        while (hypothesis_idx < self.hypotheses.len) : (hypothesis_idx += 1) self.hypotheses[hypothesis_idx] = .{};
    }

    pub fn refreshScratchReferences(self: *Recorder) void {
        self.scratch_ref_count = 0;
        self.scratch_ref_total_count = 0;
        for (&self.scratch_refs) |*reference| reference.* = .{};

        const layer = registered_scratchpad orelse return;
        const tags = layer.overlay.scratch.tags orelse return;
        for (tags, 0..) |hash, idx| {
            if (hash == 0) continue;
            self.scratch_ref_total_count +|= 1;
            if (self.scratch_ref_count >= self.scratch_refs.len) continue;
            const stored_idx: usize = @intCast(self.scratch_ref_count);
            self.scratch_refs[stored_idx] = .{
                .slot_index = @intCast(idx),
                .hash = hash,
            };
            self.scratch_ref_count += 1;
        }
    }

    pub fn header(self: *Recorder) Header {
        var flags: u32 = 0;
        if (self.candidate_total_count > self.candidate_count) flags |= FLAG_CANDIDATES_TRUNCATED;
        if (self.hypothesis_total_count > self.hypothesis_count) flags |= FLAG_HYPOTHESES_TRUNCATED;
        if (self.scratch_ref_total_count > self.scratch_ref_count) flags |= FLAG_SCRATCH_REFS_TRUNCATED;
        if (self.panic_message_len > 0) flags |= FLAG_HAS_PANIC_MESSAGE;

        const total_bytes: u32 = @intCast(
            MAGIC.len +
            @sizeOf(u16) +
            @sizeOf(u16) +
            @sizeOf(u32) +
            @sizeOf(u32) +
            @sizeOf(u8) +
            @sizeOf(u8) +
            @sizeOf(u16) +
            @sizeOf(u32) +
            @sizeOf(u32) +
            (@sizeOf(u16) * 6) +
            self.engine_version_len +
            self.panic_message_len +
            (@as(u32, self.candidate_count) * @sizeOf(CandidateRecord)) +
            (@as(u32, self.hypothesis_count) * @sizeOf(HypothesisRecord)) +
            (@as(u32, self.scratch_ref_count) * @sizeOf(ScratchReference)));

        return .{
            .flags = flags,
            .total_bytes = total_bytes,
            .stop_reason = @intFromEnum(self.last_event.stop_reason),
            .engine_version_len = self.engine_version_len,
            .panic_message_len = self.panic_message_len,
            .step_count = self.last_event.step_count,
            .confidence = self.last_event.confidence,
            .candidate_count = self.candidate_count,
            .candidate_total_count = self.candidate_total_count,
            .hypothesis_count = self.hypothesis_count,
            .hypothesis_total_count = self.hypothesis_total_count,
            .scratch_ref_count = self.scratch_ref_count,
            .scratch_ref_total_count = self.scratch_ref_total_count,
        };
    }

    pub fn serialize(self: *Recorder, writer: anytype) !void {
        const hdr = self.header();
        try writer.writeAll(MAGIC);
        try writeInt(writer, u16, FORMAT_VERSION);
        try writeInt(writer, u16, 0);
        try writeInt(writer, u32, hdr.flags);
        try writeInt(writer, u32, hdr.total_bytes);
        try writeInt(writer, u8, hdr.stop_reason);
        try writeInt(writer, u8, hdr.engine_version_len);
        try writeInt(writer, u16, hdr.panic_message_len);
        try writeInt(writer, u32, hdr.step_count);
        try writeInt(writer, u32, hdr.confidence);
        try writeInt(writer, u16, hdr.candidate_count);
        try writeInt(writer, u16, hdr.candidate_total_count);
        try writeInt(writer, u16, hdr.hypothesis_count);
        try writeInt(writer, u16, hdr.hypothesis_total_count);
        try writeInt(writer, u16, hdr.scratch_ref_count);
        try writeInt(writer, u16, hdr.scratch_ref_total_count);
        try writer.writeAll(self.engine_version[0..hdr.engine_version_len]);
        try writer.writeAll(self.panic_message[0..hdr.panic_message_len]);

        const candidate_count: usize = @intCast(hdr.candidate_count);
        for (self.candidates[0..candidate_count]) |candidate| {
            try writeInt(writer, u32, candidate.char_code);
            try writeInt(writer, u32, candidate.branch_index);
            try writeInt(writer, u32, candidate.base_score);
            try writeInt(writer, u32, candidate.score);
            try writeInt(writer, u32, candidate.confidence);
        }

        const hypothesis_count: usize = @intCast(hdr.hypothesis_count);
        for (self.hypotheses[0..hypothesis_count]) |hypothesis| {
            try writeInt(writer, u32, hypothesis.root_char);
            try writeInt(writer, u32, hypothesis.branch_index);
            try writeInt(writer, u32, hypothesis.last_char);
            try writeInt(writer, u32, hypothesis.depth);
            try writeInt(writer, u32, hypothesis.score);
            try writeInt(writer, u32, hypothesis.confidence);
        }

        const scratch_ref_count: usize = @intCast(hdr.scratch_ref_count);
        for (self.scratch_refs[0..scratch_ref_count]) |reference| {
            try writeInt(writer, u32, reference.slot_index);
            try writeInt(writer, u64, reference.hash);
        }
    }
};

pub var global_recorder: Recorder = Recorder.init();

pub fn dumpHook() inference.DumpHook {
    return .{
        .context = &global_recorder,
        .emit = Recorder.captureHook,
    };
}

pub fn registerScratchpad(layer: *const scratchpad.ScratchpadLayer) void {
    registered_scratchpad = layer;
}

pub fn unregisterScratchpad() void {
    registered_scratchpad = null;
}

pub fn emitPanicDump(msg: []const u8) void {
    global_recorder.notePanicMessage(msg);
    global_recorder.refreshScratchReferences();

    const fd = openDumpFile() catch return;
    defer std.posix.close(fd);

    var writer = FdWriter{ .fd = fd };
    global_recorder.serialize(&writer) catch return;
    std.posix.fsync(fd) catch {};
}

pub fn panicCall(msg: []const u8, ra: ?usize) noreturn {
    emitPanicDump(msg);
    std.debug.defaultPanic(msg, ra);
}

pub fn write(writer: anytype, panic_reason: anytype) !void {
    try writer.print("[MONOLITH] Panic: {any}\n", .{panic_reason});
}

pub fn format(allocator: std.mem.Allocator, panic_reason: anytype) ![]u8 {
    return std.fmt.allocPrint(allocator, "[MONOLITH] Panic: {any}\n", .{panic_reason});
}

fn openDumpFile() !std.posix.fd_t {
    return try std.posix.openZ(DUMP_PATH, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .TRUNC = true,
    }, 0o644);
}

fn writeInt(writer: anytype, comptime T: type, value: T) !void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    try writer.writeAll(&bytes);
}

fn saturatingCount(len: usize) u16 {
    return @intCast(@min(len, std.math.maxInt(u16)));
}

const FdWriter = struct {
    fd: std.posix.fd_t,

    fn writeAll(self: *FdWriter, bytes: []const u8) !void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            const written = try std.posix.write(self.fd, bytes[offset..]);
            if (written == 0) return error.WriteFailed;
            offset += written;
        }
    }
};
