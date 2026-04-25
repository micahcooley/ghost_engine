const std = @import("std");
const builtin = @import("builtin");
const code_intel = @import("code_intel.zig");
const config = @import("config.zig");
const inference = @import("inference.zig");
const patch_candidates = @import("patch_candidates.zig");
const scratchpad = @import("scratchpad.zig");
const shards = @import("shards.zig");
const technical_drafts = @import("technical_drafts.zig");
const build_options = @import("build_options");

pub const FORMAT_VERSION: u16 = 2;
pub const MAGIC = "GDDP1LE\n";
pub const VERSION_CAP: usize = 16;
pub const PANIC_MESSAGE_CAP: usize = 160;
pub const MAX_CANDIDATES: usize = config.LAYER3_MAX_BRANCHES;
pub const MAX_HYPOTHESES: usize = config.LAYER3_MAX_BRANCHES;
pub const MAX_SCRATCH_REFS: usize = 64;
pub const MAX_REPO_ROOT: usize = 512;
pub const MAX_SHARD_ID: usize = 96;
pub const MAX_SHARD_ROOT: usize = 512;
pub const MAX_REQUEST_LABEL: usize = 192;
pub const MAX_TARGET: usize = 256;
pub const MAX_OTHER_TARGET: usize = 256;
pub const MAX_ARTIFACT_PATH: usize = 512;
pub const MAX_ARTIFACT_BYTES: usize = 192 * 1024;
pub const MAX_REPORT_BYTES: usize = 48 * 1024;

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

pub const ArtifactKind = enum(u8) {
    none = 0,
    code_intel_result = 1,
    patch_candidates_result = 2,
};

pub const ReplayClass = enum {
    fully_replayable,
    observational_only,
    insufficient_replay_state,
};

pub const ReplaySource = enum {
    none,
    embedded,
    external_exact,
};

pub const DumpContext = struct {
    reasoning_mode: inference.ReasoningMode = .proof,
    shard_kind: ?shards.Kind = null,
    scratch_active: bool = false,
    scratch_only: bool = false,
    repo_root: ?[]const u8 = null,
    shard_id: ?[]const u8 = null,
    shard_root: ?[]const u8 = null,
    request_label: ?[]const u8 = null,
    target: ?[]const u8 = null,
    other_target: ?[]const u8 = null,
};

pub const ParsedDump = struct {
    allocator: std.mem.Allocator,
    format_version: u16,
    flags: u32 = 0,
    total_bytes: u32 = 0,
    engine_version: []u8,
    panic_message: ?[]u8 = null,
    trace: inference.TraceEvent = .{
        .step = 0,
        .active_branches = 0,
    },
    candidate_total_count: u32 = 0,
    hypothesis_total_count: u32 = 0,
    scratch_ref_total_count: u32 = 0,
    candidates: []CandidateRecord = &.{},
    hypotheses: []HypothesisRecord = &.{},
    scratch_refs: []ScratchReference = &.{},
    context: DumpContext = .{},
    artifact_kind: ArtifactKind = .none,
    artifact_path: ?[]u8 = null,
    artifact_hash: u64 = 0,
    artifact_total_bytes: u32 = 0,
    artifact_json: []u8 = &.{},
    report_total_bytes: u32 = 0,
    report: []u8 = &.{},
    report_draft_type: ?technical_drafts.DraftType = null,

    pub fn deinit(self: *ParsedDump) void {
        self.allocator.free(self.engine_version);
        if (self.panic_message) |msg| self.allocator.free(msg);
        self.allocator.free(self.candidates);
        self.allocator.free(self.hypotheses);
        self.allocator.free(self.scratch_refs);
        if (self.context.repo_root) |value| self.allocator.free(value);
        if (self.context.shard_id) |value| self.allocator.free(value);
        if (self.context.shard_root) |value| self.allocator.free(value);
        if (self.context.request_label) |value| self.allocator.free(value);
        if (self.context.target) |value| self.allocator.free(value);
        if (self.context.other_target) |value| self.allocator.free(value);
        if (self.artifact_path) |value| self.allocator.free(value);
        self.allocator.free(self.artifact_json);
        self.allocator.free(self.report);
        self.* = undefined;
    }

    pub fn candidateTotalCount(self: *const ParsedDump) usize {
        return @intCast(if (self.candidate_total_count == 0) self.candidates.len else self.candidate_total_count);
    }

    pub fn hypothesisTotalCount(self: *const ParsedDump) usize {
        return @intCast(if (self.hypothesis_total_count == 0) self.hypotheses.len else self.hypothesis_total_count);
    }

    pub fn scratchRefTotalCount(self: *const ParsedDump) usize {
        return @intCast(if (self.scratch_ref_total_count == 0) self.scratch_refs.len else self.scratch_ref_total_count);
    }
};

pub const ReplayInspection = struct {
    class: ReplayClass = .insufficient_replay_state,
    source: ReplaySource = .none,
    artifact_bytes: []const u8 = &.{},
    artifact_kind: ArtifactKind = .none,
    report: []const u8 = &.{},
    artifact_path_status: ArtifactPathStatus = .none,
    owned_artifact: ?[]u8 = null,

    pub const ArtifactPathStatus = enum {
        none,
        matched,
        missing,
        hash_mismatch,
        unreadable,
    };

    pub fn deinit(self: *ReplayInspection, allocator: std.mem.Allocator) void {
        if (self.owned_artifact) |bytes| allocator.free(bytes);
        self.* = undefined;
    }
};

pub const HeaderV1 = struct {
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

pub const HeaderV2 = struct {
    flags: u32 = 0,
    total_bytes: u32 = 0,
    stop_reason: u8 = 0,
    engine_version_len: u8 = 0,
    panic_message_len: u16 = 0,
    step_count: u32 = 0,
    confidence: u32 = 0,
    active_branches: u32 = 0,
    branch_count: u32 = 0,
    created_hypotheses: u32 = 0,
    expanded_hypotheses: u32 = 0,
    killed_hypotheses: u32 = 0,
    accepted_hypotheses: u32 = 0,
    unresolved_hypotheses: u32 = 0,
    best_char: u32 = 0,
    best_score: u32 = 0,
    runner_up_score: u32 = 0,
    killed_branches: u32 = 0,
    killed_by_branch_cap: u32 = 0,
    killed_by_contradiction: u32 = 0,
    contradiction_checks: u32 = 0,
    contradiction_count: u32 = 0,
    candidate_count: u16 = 0,
    candidate_total_count: u16 = 0,
    hypothesis_count: u16 = 0,
    hypothesis_total_count: u16 = 0,
    scratch_ref_count: u16 = 0,
    scratch_ref_total_count: u16 = 0,
    repo_root_len: u16 = 0,
    shard_id_len: u16 = 0,
    shard_root_len: u16 = 0,
    request_label_len: u16 = 0,
    target_len: u16 = 0,
    other_target_len: u16 = 0,
    artifact_path_len: u16 = 0,
    artifact_len: u32 = 0,
    artifact_total_bytes: u32 = 0,
    report_len: u32 = 0,
    report_total_bytes: u32 = 0,
    artifact_hash: u64 = 0,
    artifact_kind: u8 = 0,
    reasoning_mode: u8 = 0,
    shard_kind: u8 = 0,
    report_draft_type: u8 = 0,
};

const FLAG_CANDIDATES_TRUNCATED: u32 = 1 << 0;
const FLAG_HYPOTHESES_TRUNCATED: u32 = 1 << 1;
const FLAG_SCRATCH_REFS_TRUNCATED: u32 = 1 << 2;
const FLAG_HAS_PANIC_MESSAGE: u32 = 1 << 3;
const FLAG_HAS_REPO_ROOT: u32 = 1 << 4;
const FLAG_HAS_SHARD_ID: u32 = 1 << 5;
const FLAG_HAS_SHARD_ROOT: u32 = 1 << 6;
const FLAG_HAS_REQUEST_LABEL: u32 = 1 << 7;
const FLAG_HAS_TARGET: u32 = 1 << 8;
const FLAG_HAS_OTHER_TARGET: u32 = 1 << 9;
const FLAG_HAS_ARTIFACT_PATH: u32 = 1 << 10;
const FLAG_HAS_ARTIFACT: u32 = 1 << 11;
const FLAG_ARTIFACT_TRUNCATED: u32 = 1 << 12;
const FLAG_HAS_REPORT: u32 = 1 << 13;
const FLAG_REPORT_TRUNCATED: u32 = 1 << 14;
const FLAG_SCRATCH_ACTIVE: u32 = 1 << 15;
const FLAG_SCRATCH_ONLY: u32 = 1 << 16;
const FLAG_HAS_RUNTIME_CONTEXT: u32 = 1 << 17;

const DUMP_PATH = switch (builtin.os.tag) {
    .linux, .macos => "/tmp/ghost-dd-panic.bin",
    else => "ghost-dd-panic.bin",
};

pub fn dumpPath() []const u8 {
    return DUMP_PATH;
}

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
    context_flags: u32 = 0,
    artifact_kind: ArtifactKind = .none,
    report_draft_type: ?technical_drafts.DraftType = null,
    artifact_hash: u64 = 0,
    artifact_len: u32 = 0,
    artifact_total_bytes: u32 = 0,
    report_len: u32 = 0,
    report_total_bytes: u32 = 0,
    reasoning_mode: inference.ReasoningMode = .proof,
    shard_kind: ?shards.Kind = null,
    repo_root_len: u16 = 0,
    shard_id_len: u16 = 0,
    shard_root_len: u16 = 0,
    request_label_len: u16 = 0,
    target_len: u16 = 0,
    other_target_len: u16 = 0,
    artifact_path_len: u16 = 0,
    repo_root: [MAX_REPO_ROOT]u8 = [_]u8{0} ** MAX_REPO_ROOT,
    shard_id: [MAX_SHARD_ID]u8 = [_]u8{0} ** MAX_SHARD_ID,
    shard_root: [MAX_SHARD_ROOT]u8 = [_]u8{0} ** MAX_SHARD_ROOT,
    request_label: [MAX_REQUEST_LABEL]u8 = [_]u8{0} ** MAX_REQUEST_LABEL,
    target: [MAX_TARGET]u8 = [_]u8{0} ** MAX_TARGET,
    other_target: [MAX_OTHER_TARGET]u8 = [_]u8{0} ** MAX_OTHER_TARGET,
    artifact_path: [MAX_ARTIFACT_PATH]u8 = [_]u8{0} ** MAX_ARTIFACT_PATH,
    artifact_json: [MAX_ARTIFACT_BYTES]u8 = [_]u8{0} ** MAX_ARTIFACT_BYTES,
    report: [MAX_REPORT_BYTES]u8 = [_]u8{0} ** MAX_REPORT_BYTES,

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
        self.reasoning_mode = event.reasoning_mode;

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

    pub fn noteRuntimeContext(
        self: *Recorder,
        shard_kind: shards.Kind,
        shard_id: []const u8,
        shard_root: []const u8,
        reasoning_mode: inference.ReasoningMode,
    ) void {
        self.reasoning_mode = reasoning_mode;
        self.shard_kind = shard_kind;
        self.context_flags |= FLAG_HAS_RUNTIME_CONTEXT;
        self.storeString(&self.shard_id_len, self.shard_id[0..], shard_id, FLAG_HAS_SHARD_ID);
        self.storeString(&self.shard_root_len, self.shard_root[0..], shard_root, FLAG_HAS_SHARD_ROOT);
    }

    pub fn clearRuntimeContext(self: *Recorder) void {
        self.context_flags &= ~@as(u32, FLAG_HAS_RUNTIME_CONTEXT);
        self.shard_kind = null;
        self.clearStoredString(&self.shard_id_len, self.shard_id[0..], FLAG_HAS_SHARD_ID);
        self.clearStoredString(&self.shard_root_len, self.shard_root[0..], FLAG_HAS_SHARD_ROOT);
    }

    pub fn noteScratchState(self: *Recorder, scratch_active: bool, scratch_only: bool) void {
        if (scratch_active) {
            self.context_flags |= FLAG_SCRATCH_ACTIVE;
        } else {
            self.context_flags &= ~@as(u32, FLAG_SCRATCH_ACTIVE);
        }
        if (scratch_only) {
            self.context_flags |= FLAG_SCRATCH_ONLY;
        } else {
            self.context_flags &= ~@as(u32, FLAG_SCRATCH_ONLY);
        }
    }

    pub fn captureCodeIntelResult(self: *Recorder, allocator: std.mem.Allocator, result: *const code_intel.Result, artifact_path: ?[]const u8) !void {
        self.reasoning_mode = result.reasoning_mode;
        self.shard_kind = result.shard_kind;
        self.context_flags |= FLAG_HAS_RUNTIME_CONTEXT;
        self.storeString(&self.repo_root_len, self.repo_root[0..], result.repo_root, FLAG_HAS_REPO_ROOT);
        self.storeString(&self.shard_id_len, self.shard_id[0..], result.shard_id, FLAG_HAS_SHARD_ID);
        self.storeString(&self.shard_root_len, self.shard_root[0..], result.shard_root, FLAG_HAS_SHARD_ROOT);
        self.storeString(&self.request_label_len, self.request_label[0..], if (result.intent) |intent| intent.raw_input else result.query_target, FLAG_HAS_REQUEST_LABEL);
        self.storeString(&self.target_len, self.target[0..], result.query_target, FLAG_HAS_TARGET);
        if (result.query_other_target) |other| {
            self.storeString(&self.other_target_len, self.other_target[0..], other, FLAG_HAS_OTHER_TARGET);
        } else {
            self.clearStoredString(&self.other_target_len, self.other_target[0..], FLAG_HAS_OTHER_TARGET);
        }
        self.noteScratchState(false, false);

        const artifact_json = try code_intel.renderJson(allocator, result);
        defer allocator.free(artifact_json);
        const report = try technical_drafts.render(allocator, .{ .code_intel = result }, .{
            .draft_type = .proof_backed_explanation,
            .max_items = 6,
        });
        defer allocator.free(report);

        self.storeArtifact(.code_intel_result, artifact_path, artifact_json, .proof_backed_explanation, report);
    }

    pub fn capturePatchCandidatesResult(self: *Recorder, allocator: std.mem.Allocator, result: *const patch_candidates.Result) !void {
        self.reasoning_mode = result.handoff.proof.mode;
        self.shard_kind = result.shard_kind;
        self.context_flags |= FLAG_HAS_RUNTIME_CONTEXT;
        self.storeString(&self.repo_root_len, self.repo_root[0..], result.repo_root, FLAG_HAS_REPO_ROOT);
        self.storeString(&self.shard_id_len, self.shard_id[0..], result.shard_id, FLAG_HAS_SHARD_ID);
        self.storeString(&self.shard_root_len, self.shard_root[0..], result.shard_root, FLAG_HAS_SHARD_ROOT);
        self.storeString(&self.request_label_len, self.request_label[0..], result.request_label, FLAG_HAS_REQUEST_LABEL);
        self.storeString(&self.target_len, self.target[0..], result.target, FLAG_HAS_TARGET);
        if (result.other_target) |other| {
            self.storeString(&self.other_target_len, self.other_target[0..], other, FLAG_HAS_OTHER_TARGET);
        } else {
            self.clearStoredString(&self.other_target_len, self.other_target[0..], FLAG_HAS_OTHER_TARGET);
        }
        self.noteScratchState(true, result.scratch_only);

        const artifact_json = try patch_candidates.renderJson(allocator, result);
        defer allocator.free(artifact_json);
        const report = try technical_drafts.render(allocator, .{ .patch_candidates = result }, .{
            .draft_type = .proof_backed_explanation,
            .max_items = result.caps.max_support_items,
        });
        defer allocator.free(report);

        self.storeArtifact(.patch_candidates_result, result.staged_path, artifact_json, .proof_backed_explanation, report);
    }

    pub fn header(self: *Recorder) HeaderV2 {
        var flags: u32 = self.context_flags;
        if (self.candidate_total_count > self.candidate_count) flags |= FLAG_CANDIDATES_TRUNCATED;
        if (self.hypothesis_total_count > self.hypothesis_count) flags |= FLAG_HYPOTHESES_TRUNCATED;
        if (self.scratch_ref_total_count > self.scratch_ref_count) flags |= FLAG_SCRATCH_REFS_TRUNCATED;
        if (self.panic_message_len > 0) flags |= FLAG_HAS_PANIC_MESSAGE;
        if (self.artifact_kind != .none) flags |= FLAG_HAS_ARTIFACT;
        if (self.artifact_total_bytes > self.artifact_len) flags |= FLAG_ARTIFACT_TRUNCATED;
        if (self.report_total_bytes > 0) flags |= FLAG_HAS_REPORT;
        if (self.report_total_bytes > self.report_len) flags |= FLAG_REPORT_TRUNCATED;

        const total_bytes: u32 = @intCast(MAGIC.len +
            @sizeOf(u16) +
            @sizeOf(u16) +
            (@sizeOf(u32) * 2) +
            (@sizeOf(u8) * 4) +
            (@sizeOf(u16) * 10) +
            (@sizeOf(u32) * 18) +
            @sizeOf(u64) +
            self.engine_version_len +
            self.panic_message_len +
            self.repo_root_len +
            self.shard_id_len +
            self.shard_root_len +
            self.request_label_len +
            self.target_len +
            self.other_target_len +
            self.artifact_path_len +
            self.artifact_len +
            self.report_len +
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
            .active_branches = self.last_event.active_branches,
            .branch_count = self.last_event.branch_count,
            .created_hypotheses = self.last_event.created_hypotheses,
            .expanded_hypotheses = self.last_event.expanded_hypotheses,
            .killed_hypotheses = self.last_event.killed_hypotheses,
            .accepted_hypotheses = self.last_event.accepted_hypotheses,
            .unresolved_hypotheses = self.last_event.unresolved_hypotheses,
            .best_char = self.last_event.best_char,
            .best_score = self.last_event.best_score,
            .runner_up_score = self.last_event.runner_up_score,
            .killed_branches = self.last_event.killed_branches,
            .killed_by_branch_cap = self.last_event.killed_by_branch_cap,
            .killed_by_contradiction = self.last_event.killed_by_contradiction,
            .contradiction_checks = self.last_event.contradiction_checks,
            .contradiction_count = self.last_event.contradiction_count,
            .candidate_count = self.candidate_count,
            .candidate_total_count = self.candidate_total_count,
            .hypothesis_count = self.hypothesis_count,
            .hypothesis_total_count = self.hypothesis_total_count,
            .scratch_ref_count = self.scratch_ref_count,
            .scratch_ref_total_count = self.scratch_ref_total_count,
            .repo_root_len = self.repo_root_len,
            .shard_id_len = self.shard_id_len,
            .shard_root_len = self.shard_root_len,
            .request_label_len = self.request_label_len,
            .target_len = self.target_len,
            .other_target_len = self.other_target_len,
            .artifact_path_len = self.artifact_path_len,
            .artifact_len = self.artifact_len,
            .artifact_total_bytes = self.artifact_total_bytes,
            .report_len = self.report_len,
            .report_total_bytes = self.report_total_bytes,
            .artifact_hash = self.artifact_hash,
            .artifact_kind = @intFromEnum(self.artifact_kind),
            .reasoning_mode = reasoningModeByte(self.reasoning_mode),
            .shard_kind = shardKindByte(self.shard_kind),
            .report_draft_type = draftTypeByte(self.report_draft_type),
        };
    }

    pub fn serialize(self: *Recorder, writer: anytype) !void {
        const hdr = self.header();
        try writer.writeAll(MAGIC);
        try writeInt(writer, u16, FORMAT_VERSION);
        try writeInt(writer, u16, 0);
        try writeHeaderV2(writer, hdr);
        try writer.writeAll(self.engine_version[0..hdr.engine_version_len]);
        try writer.writeAll(self.panic_message[0..hdr.panic_message_len]);
        try writer.writeAll(self.repo_root[0..hdr.repo_root_len]);
        try writer.writeAll(self.shard_id[0..hdr.shard_id_len]);
        try writer.writeAll(self.shard_root[0..hdr.shard_root_len]);
        try writer.writeAll(self.request_label[0..hdr.request_label_len]);
        try writer.writeAll(self.target[0..hdr.target_len]);
        try writer.writeAll(self.other_target[0..hdr.other_target_len]);
        try writer.writeAll(self.artifact_path[0..hdr.artifact_path_len]);
        try writer.writeAll(self.artifact_json[0..hdr.artifact_len]);
        try writer.writeAll(self.report[0..hdr.report_len]);

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

    fn storeArtifact(
        self: *Recorder,
        artifact_kind: ArtifactKind,
        artifact_path: ?[]const u8,
        artifact_json: []const u8,
        report_draft_type: technical_drafts.DraftType,
        report: []const u8,
    ) void {
        self.artifact_kind = artifact_kind;
        self.artifact_hash = hashBytes(artifact_json);
        self.artifact_total_bytes = @intCast(@min(artifact_json.len, std.math.maxInt(u32)));
        self.artifact_len = @intCast(@min(artifact_json.len, self.artifact_json.len));
        if (self.artifact_len > 0) @memcpy(self.artifact_json[0..self.artifact_len], artifact_json[0..self.artifact_len]);
        if (self.artifact_len < self.artifact_json.len) @memset(self.artifact_json[self.artifact_len..], 0);

        if (artifact_path) |path| {
            self.storeString(&self.artifact_path_len, self.artifact_path[0..], path, FLAG_HAS_ARTIFACT_PATH);
        } else {
            self.clearStoredString(&self.artifact_path_len, self.artifact_path[0..], FLAG_HAS_ARTIFACT_PATH);
        }

        self.report_draft_type = report_draft_type;
        self.report_total_bytes = @intCast(@min(report.len, std.math.maxInt(u32)));
        self.report_len = @intCast(@min(report.len, self.report.len));
        if (self.report_len > 0) @memcpy(self.report[0..self.report_len], report[0..self.report_len]);
        if (self.report_len < self.report.len) @memset(self.report[self.report_len..], 0);
    }

    fn storeString(self: *Recorder, len_ptr: *u16, dest: []u8, value: []const u8, flag: u32) void {
        const len = @min(value.len, dest.len);
        @memset(dest, 0);
        @memcpy(dest[0..len], value[0..len]);
        len_ptr.* = @intCast(len);
        self.context_flags |= flag;
    }

    fn clearStoredString(self: *Recorder, len_ptr: *u16, dest: []u8, flag: u32) void {
        @memset(dest, 0);
        len_ptr.* = 0;
        self.context_flags &= ~flag;
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

pub fn noteRuntimeContext(
    shard_kind: shards.Kind,
    shard_id: []const u8,
    shard_root: []const u8,
    reasoning_mode: inference.ReasoningMode,
) void {
    global_recorder.noteRuntimeContext(shard_kind, shard_id, shard_root, reasoning_mode);
}

pub fn clearRuntimeContext() void {
    global_recorder.clearRuntimeContext();
}

pub fn captureCodeIntelResult(allocator: std.mem.Allocator, result: *const code_intel.Result, artifact_path: ?[]const u8) !void {
    try global_recorder.captureCodeIntelResult(allocator, result, artifact_path);
}

pub fn capturePatchCandidatesResult(allocator: std.mem.Allocator, result: *const patch_candidates.Result) !void {
    try global_recorder.capturePatchCandidatesResult(allocator, result);
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

pub fn readFile(allocator: std.mem.Allocator, path: []const u8) !ParsedDump {
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    const stat = try file.stat();
    const max_read: usize = @intCast(@min(stat.size, 16 * 1024 * 1024));
    const bytes = try file.readToEndAlloc(allocator, max_read);
    defer allocator.free(bytes);
    return parse(allocator, bytes);
}

pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !ParsedDump {
    if (bytes.len < MAGIC.len + 4) return error.InvalidPanicDump;
    if (!std.mem.eql(u8, bytes[0..MAGIC.len], MAGIC)) return error.InvalidPanicDump;

    var cursor: usize = MAGIC.len;
    const version = try readIntAt(bytes, &cursor, u16);
    _ = try readIntAt(bytes, &cursor, u16);

    return switch (version) {
        1 => try parseV1(allocator, bytes, version, &cursor),
        2 => try parseV2(allocator, bytes, version, &cursor),
        else => error.UnsupportedPanicDumpVersion,
    };
}

pub fn inspectReplay(allocator: std.mem.Allocator, dump: *const ParsedDump, allow_external: bool) !ReplayInspection {
    var inspection = ReplayInspection{
        .artifact_kind = dump.artifact_kind,
        .report = dump.report,
    };

    if (dump.artifact_kind != .none and dump.artifact_json.len > 0 and dump.artifact_json.len == @as(usize, dump.artifact_total_bytes)) {
        inspection.class = .fully_replayable;
        inspection.source = .embedded;
        inspection.artifact_bytes = dump.artifact_json;
        inspection.artifact_path_status = if (dump.artifact_path != null) .matched else .none;
        return inspection;
    }

    if (allow_external and dump.artifact_kind != .none and dump.artifact_path != null and dump.artifact_hash != 0) {
        const path = dump.artifact_path.?;
        const maybe_bytes = readAbsoluteAlloc(allocator, path, 2 * 1024 * 1024) catch |err| {
            inspection.class = classifyObservational(dump);
            inspection.artifact_path_status = switch (err) {
                error.FileNotFound => .missing,
                else => .unreadable,
            };
            return inspection;
        };
        if (hashBytes(maybe_bytes) == dump.artifact_hash) {
            inspection.class = .fully_replayable;
            inspection.source = .external_exact;
            inspection.artifact_bytes = maybe_bytes;
            inspection.owned_artifact = maybe_bytes;
            inspection.artifact_path_status = .matched;
            return inspection;
        }
        allocator.free(maybe_bytes);
        inspection.class = classifyObservational(dump);
        inspection.artifact_path_status = .hash_mismatch;
        return inspection;
    }

    inspection.class = classifyObservational(dump);
    if (dump.artifact_path != null) inspection.artifact_path_status = .missing;
    return inspection;
}

pub fn renderSummary(allocator: std.mem.Allocator, dump: *const ParsedDump, replay: ?*const ReplayInspection) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const writer = out.writer();

    try writer.print("panic_dump version={d} bytes={d}\n", .{ dump.format_version, dump.total_bytes });
    try writer.print("engine={s} stop_reason={s} confidence={d}\n", .{
        dump.engine_version,
        @tagName(dump.trace.stop_reason),
        dump.trace.confidence,
    });
    if (dump.panic_message) |msg| try writer.print("panic_message={s}\n", .{msg});
    try writer.print(
        "trace step_count={d} active_branches={d} branch_count={d} created={d} expanded={d} accepted={d} unresolved={d}\n",
        .{
            dump.trace.step_count,
            dump.trace.active_branches,
            dump.trace.branch_count,
            dump.trace.created_hypotheses,
            dump.trace.expanded_hypotheses,
            dump.trace.accepted_hypotheses,
            dump.trace.unresolved_hypotheses,
        },
    );
    try writer.print(
        "branch_outcomes killed={d} killed_by_cap={d} killed_by_contradiction={d} contradiction_checks={d} contradiction_count={d}\n",
        .{
            dump.trace.killed_branches,
            dump.trace.killed_by_branch_cap,
            dump.trace.killed_by_contradiction,
            dump.trace.contradiction_checks,
            dump.trace.contradiction_count,
        },
    );
    try writer.print(
        "frontier candidates={d}/{d} hypotheses={d}/{d} scratch_refs={d}/{d}\n",
        .{
            dump.candidates.len,
            dump.candidateTotalCount(),
            dump.hypotheses.len,
            dump.hypothesisTotalCount(),
            dump.scratch_refs.len,
            dump.scratchRefTotalCount(),
        },
    );

    if (dump.context.shard_kind != null or dump.context.shard_id != null or dump.context.repo_root != null or dump.context.target != null) {
        try writer.print(
            "context reasoning_mode={s} shard={s}/{s} scratch_active={s} scratch_only={s}\n",
            .{
                inference.reasoningModeName(dump.context.reasoning_mode),
                if (dump.context.shard_kind) |kind| @tagName(kind) else "unknown",
                if (dump.context.shard_id) |value| value else "unknown",
                boolText(dump.context.scratch_active),
                boolText(dump.context.scratch_only),
            },
        );
        if (dump.context.repo_root) |value| try writer.print("repo_root={s}\n", .{value});
        if (dump.context.shard_root) |value| try writer.print("shard_root={s}\n", .{value});
        if (dump.context.request_label) |value| try writer.print("request={s}\n", .{value});
        if (dump.context.target) |value| try writer.print("target={s}\n", .{value});
        if (dump.context.other_target) |value| try writer.print("other_target={s}\n", .{value});
    }

    if (replay) |inspection| {
        try writer.print(
            "replay class={s} source={s} artifact={s} artifact_path_status={s}\n",
            .{
                replayClassName(inspection.class),
                replaySourceName(inspection.source),
                artifactKindName(dump.artifact_kind),
                artifactPathStatusName(inspection.artifact_path_status),
            },
        );
        if (dump.artifact_path) |path| try writer.print("artifact_path={s}\n", .{path});
        if (dump.artifact_kind != .none) {
            try writer.print(
                "artifact bytes={d}/{d} hash=0x{x}\n",
                .{ dump.artifact_json.len, dump.artifact_total_bytes, dump.artifact_hash },
            );
        }
        if (dump.report.len > 0) {
            try writer.print("report bytes={d}/{d} draft_type={s}\n", .{
                dump.report.len,
                dump.report_total_bytes,
                draftTypeName(dump.report_draft_type),
            });
        }
        try renderArtifactNarrative(writer, allocator, dump, inspection);
    }

    return out.toOwnedSlice();
}

pub fn renderReplayReport(allocator: std.mem.Allocator, dump: *const ParsedDump, inspection: *const ReplayInspection) ![]u8 {
    if (inspection.report.len > 0 and dump.report.len == @as(usize, dump.report_total_bytes)) {
        if (std.mem.indexOf(u8, inspection.report, "Replay Report") != null) {
            return allocator.dupe(u8, inspection.report);
        }
        return std.fmt.allocPrint(allocator, "Replay Report\n\n{s}", .{inspection.report});
    }

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const writer = out.writer();
    try writer.writeAll("Replay Report\n\n");
    try writer.print(
        "rendering_model: ghost_panic_replay_v1\nsource: panic_dump\ndraft_type: proof-backed-explanation\nclaim_status: {s}\nreasoning_mode: {s}\nverification_label: {s}\n",
        .{
            if (inspection.class == .fully_replayable) "supported" else "unresolved",
            inference.reasoningModeName(dump.context.reasoning_mode),
            if (inspection.class == .fully_replayable) "replay_backed" else "observational_only",
        },
    );
    try writer.writeAll("\n[summary]\n");
    try writer.print("- replayability: {s}\n", .{replayClassName(inspection.class)});
    try writer.print("- stop_reason: {s}\n", .{@tagName(dump.trace.stop_reason)});
    try writer.print("- confidence: {d}\n", .{dump.trace.confidence});
    if (dump.context.request_label) |value| try writer.print("- request: {s}\n", .{value});
    if (dump.context.target) |value| try writer.print("- target: {s}\n", .{value});
    if (dump.artifact_path) |path| try writer.print("- artifact_path: {s}\n", .{path});
    return out.toOwnedSlice();
}

pub fn renderJson(allocator: std.mem.Allocator, dump: *const ParsedDump, replay: ?*const ReplayInspection) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const writer = out.writer();

    try writer.writeAll("{");
    try writeJsonFieldString(writer, "magic", MAGIC, true);
    try writer.print(",\"formatVersion\":{d}", .{dump.format_version});
    try writer.print(",\"totalBytes\":{d}", .{dump.total_bytes});
    try writeJsonFieldString(writer, "engineVersion", dump.engine_version, false);
    if (dump.panic_message) |msg| try writeOptionalStringField(writer, "panicMessage", msg);

    try writer.writeAll(",\"trace\":{");
    try writeJsonFieldString(writer, "stopReason", @tagName(dump.trace.stop_reason), true);
    try writeJsonFieldString(writer, "reasoningMode", inference.reasoningModeName(dump.context.reasoning_mode), false);
    try writer.print(
        ",\"stepCount\":{d},\"activeBranches\":{d},\"branchCount\":{d},\"confidence\":{d},\"createdHypotheses\":{d},\"expandedHypotheses\":{d},\"acceptedHypotheses\":{d},\"unresolvedHypotheses\":{d},\"killedBranches\":{d},\"killedByBranchCap\":{d},\"killedByContradiction\":{d},\"contradictionChecks\":{d},\"contradictionCount\":{d}",
        .{
            dump.trace.step_count,
            dump.trace.active_branches,
            dump.trace.branch_count,
            dump.trace.confidence,
            dump.trace.created_hypotheses,
            dump.trace.expanded_hypotheses,
            dump.trace.accepted_hypotheses,
            dump.trace.unresolved_hypotheses,
            dump.trace.killed_branches,
            dump.trace.killed_by_branch_cap,
            dump.trace.killed_by_contradiction,
            dump.trace.contradiction_checks,
            dump.trace.contradiction_count,
        },
    );
    try writer.writeAll("}");

    try writer.writeAll(",\"counts\":{");
    try writer.print(
        "\"candidateStored\":{d},\"candidateTotal\":{d},\"hypothesisStored\":{d},\"hypothesisTotal\":{d},\"scratchStored\":{d},\"scratchTotal\":{d}",
        .{
            dump.candidates.len,
            dump.candidateTotalCount(),
            dump.hypotheses.len,
            dump.hypothesisTotalCount(),
            dump.scratch_refs.len,
            dump.scratchRefTotalCount(),
        },
    );
    try writer.writeAll("}");

    try writer.writeAll(",\"context\":{");
    try writeJsonFieldString(writer, "reasoningMode", inference.reasoningModeName(dump.context.reasoning_mode), true);
    try writeJsonFieldString(writer, "shardKind", if (dump.context.shard_kind) |kind| @tagName(kind) else "unknown", false);
    try writer.writeAll(",\"scratchActive\":");
    try writer.writeAll(boolText(dump.context.scratch_active));
    try writer.writeAll(",\"scratchOnly\":");
    try writer.writeAll(boolText(dump.context.scratch_only));
    if (dump.context.repo_root) |value| try writeOptionalStringField(writer, "repoRoot", value);
    if (dump.context.shard_id) |value| try writeOptionalStringField(writer, "shardId", value);
    if (dump.context.shard_root) |value| try writeOptionalStringField(writer, "shardRoot", value);
    if (dump.context.request_label) |value| try writeOptionalStringField(writer, "requestLabel", value);
    if (dump.context.target) |value| try writeOptionalStringField(writer, "target", value);
    if (dump.context.other_target) |value| try writeOptionalStringField(writer, "otherTarget", value);
    try writer.writeAll("}");

    try writer.writeAll(",\"artifact\":{");
    try writeJsonFieldString(writer, "kind", artifactKindName(dump.artifact_kind), true);
    if (dump.artifact_path) |path| try writeOptionalStringField(writer, "path", path);
    try writer.print(",\"hash\":{d},\"embeddedBytes\":{d},\"totalBytes\":{d}", .{
        dump.artifact_hash,
        dump.artifact_json.len,
        dump.artifact_total_bytes,
    });
    if (replay) |inspection| {
        try writeJsonFieldString(writer, "replayClass", replayClassName(inspection.class), false);
        try writeJsonFieldString(writer, "replaySource", replaySourceName(inspection.source), false);
        try writeJsonFieldString(writer, "pathStatus", artifactPathStatusName(inspection.artifact_path_status), false);
        try writer.writeAll(",\"exact\":");
        try writer.writeAll(if (inspection.class == .fully_replayable) "true" else "false");
        if (inspection.class == .fully_replayable and inspection.artifact_bytes.len > 0) {
            try writer.writeAll(",\"json\":");
            try writer.writeAll(inspection.artifact_bytes);
        }
    }
    try writer.writeAll("}");

    try writer.writeAll(",\"report\":{");
    try writeJsonFieldString(writer, "draftType", draftTypeName(dump.report_draft_type), true);
    try writer.print(",\"embeddedBytes\":{d},\"totalBytes\":{d}", .{ dump.report.len, dump.report_total_bytes });
    try writer.writeAll(",\"available\":");
    try writer.writeAll(if (dump.report.len > 0 and dump.report.len == @as(usize, dump.report_total_bytes)) "true" else "false");
    if (dump.report.len > 0 and dump.report.len == @as(usize, dump.report_total_bytes)) try writeOptionalStringField(writer, "text", dump.report);
    try writer.writeAll("}");

    try writer.writeAll("}");
    return out.toOwnedSlice();
}

fn parseV1(allocator: std.mem.Allocator, bytes: []const u8, version: u16, cursor: *usize) !ParsedDump {
    const header = HeaderV1{
        .flags = try readIntAt(bytes, cursor, u32),
        .total_bytes = try readIntAt(bytes, cursor, u32),
        .stop_reason = try readIntAt(bytes, cursor, u8),
        .engine_version_len = try readIntAt(bytes, cursor, u8),
        .panic_message_len = try readIntAt(bytes, cursor, u16),
        .step_count = try readIntAt(bytes, cursor, u32),
        .confidence = try readIntAt(bytes, cursor, u32),
        .candidate_count = try readIntAt(bytes, cursor, u16),
        .candidate_total_count = try readIntAt(bytes, cursor, u16),
        .hypothesis_count = try readIntAt(bytes, cursor, u16),
        .hypothesis_total_count = try readIntAt(bytes, cursor, u16),
        .scratch_ref_count = try readIntAt(bytes, cursor, u16),
        .scratch_ref_total_count = try readIntAt(bytes, cursor, u16),
    };

    var parsed = ParsedDump{
        .allocator = allocator,
        .format_version = version,
        .flags = header.flags,
        .total_bytes = header.total_bytes,
        .candidate_total_count = header.candidate_total_count,
        .hypothesis_total_count = header.hypothesis_total_count,
        .scratch_ref_total_count = header.scratch_ref_total_count,
        .engine_version = try readOwnedSlice(allocator, bytes, cursor, header.engine_version_len),
        .panic_message = if ((header.flags & FLAG_HAS_PANIC_MESSAGE) != 0 and header.panic_message_len > 0)
            try readOwnedSlice(allocator, bytes, cursor, header.panic_message_len)
        else blk: {
            cursor.* += header.panic_message_len;
            break :blk null;
        },
    };
    errdefer parsed.deinit();

    parsed.trace.stop_reason = @enumFromInt(header.stop_reason);
    parsed.trace.step_count = header.step_count;
    parsed.trace.confidence = header.confidence;
    parsed.context.reasoning_mode = .proof;

    parsed.candidates = try allocator.alloc(CandidateRecord, header.candidate_count);
    for (parsed.candidates) |*candidate| {
        candidate.* = .{
            .char_code = try readIntAt(bytes, cursor, u32),
            .branch_index = try readIntAt(bytes, cursor, u32),
            .base_score = try readIntAt(bytes, cursor, u32),
            .score = try readIntAt(bytes, cursor, u32),
            .confidence = try readIntAt(bytes, cursor, u32),
        };
    }

    parsed.hypotheses = try allocator.alloc(HypothesisRecord, header.hypothesis_count);
    for (parsed.hypotheses) |*hypothesis| {
        hypothesis.* = .{
            .root_char = try readIntAt(bytes, cursor, u32),
            .branch_index = try readIntAt(bytes, cursor, u32),
            .last_char = try readIntAt(bytes, cursor, u32),
            .depth = try readIntAt(bytes, cursor, u32),
            .score = try readIntAt(bytes, cursor, u32),
            .confidence = try readIntAt(bytes, cursor, u32),
        };
    }

    parsed.scratch_refs = try allocator.alloc(ScratchReference, header.scratch_ref_count);
    for (parsed.scratch_refs) |*reference| {
        reference.* = .{
            .slot_index = try readIntAt(bytes, cursor, u32),
            .hash = try readIntAt(bytes, cursor, u64),
        };
    }

    return parsed;
}

fn parseV2(allocator: std.mem.Allocator, bytes: []const u8, version: u16, cursor: *usize) !ParsedDump {
    const header = HeaderV2{
        .flags = try readIntAt(bytes, cursor, u32),
        .total_bytes = try readIntAt(bytes, cursor, u32),
        .stop_reason = try readIntAt(bytes, cursor, u8),
        .engine_version_len = try readIntAt(bytes, cursor, u8),
        .panic_message_len = try readIntAt(bytes, cursor, u16),
        .step_count = try readIntAt(bytes, cursor, u32),
        .confidence = try readIntAt(bytes, cursor, u32),
        .active_branches = try readIntAt(bytes, cursor, u32),
        .branch_count = try readIntAt(bytes, cursor, u32),
        .created_hypotheses = try readIntAt(bytes, cursor, u32),
        .expanded_hypotheses = try readIntAt(bytes, cursor, u32),
        .killed_hypotheses = try readIntAt(bytes, cursor, u32),
        .accepted_hypotheses = try readIntAt(bytes, cursor, u32),
        .unresolved_hypotheses = try readIntAt(bytes, cursor, u32),
        .best_char = try readIntAt(bytes, cursor, u32),
        .best_score = try readIntAt(bytes, cursor, u32),
        .runner_up_score = try readIntAt(bytes, cursor, u32),
        .killed_branches = try readIntAt(bytes, cursor, u32),
        .killed_by_branch_cap = try readIntAt(bytes, cursor, u32),
        .killed_by_contradiction = try readIntAt(bytes, cursor, u32),
        .contradiction_checks = try readIntAt(bytes, cursor, u32),
        .contradiction_count = try readIntAt(bytes, cursor, u32),
        .candidate_count = try readIntAt(bytes, cursor, u16),
        .candidate_total_count = try readIntAt(bytes, cursor, u16),
        .hypothesis_count = try readIntAt(bytes, cursor, u16),
        .hypothesis_total_count = try readIntAt(bytes, cursor, u16),
        .scratch_ref_count = try readIntAt(bytes, cursor, u16),
        .scratch_ref_total_count = try readIntAt(bytes, cursor, u16),
        .repo_root_len = try readIntAt(bytes, cursor, u16),
        .shard_id_len = try readIntAt(bytes, cursor, u16),
        .shard_root_len = try readIntAt(bytes, cursor, u16),
        .request_label_len = try readIntAt(bytes, cursor, u16),
        .target_len = try readIntAt(bytes, cursor, u16),
        .other_target_len = try readIntAt(bytes, cursor, u16),
        .artifact_path_len = try readIntAt(bytes, cursor, u16),
        .artifact_len = try readIntAt(bytes, cursor, u32),
        .artifact_total_bytes = try readIntAt(bytes, cursor, u32),
        .report_len = try readIntAt(bytes, cursor, u32),
        .report_total_bytes = try readIntAt(bytes, cursor, u32),
        .artifact_hash = try readIntAt(bytes, cursor, u64),
        .artifact_kind = try readIntAt(bytes, cursor, u8),
        .reasoning_mode = try readIntAt(bytes, cursor, u8),
        .shard_kind = try readIntAt(bytes, cursor, u8),
        .report_draft_type = try readIntAt(bytes, cursor, u8),
    };

    var parsed = ParsedDump{
        .allocator = allocator,
        .format_version = version,
        .flags = header.flags,
        .total_bytes = header.total_bytes,
        .candidate_total_count = header.candidate_total_count,
        .hypothesis_total_count = header.hypothesis_total_count,
        .scratch_ref_total_count = header.scratch_ref_total_count,
        .engine_version = try readOwnedSlice(allocator, bytes, cursor, header.engine_version_len),
        .panic_message = if ((header.flags & FLAG_HAS_PANIC_MESSAGE) != 0 and header.panic_message_len > 0)
            try readOwnedSlice(allocator, bytes, cursor, header.panic_message_len)
        else blk: {
            cursor.* += header.panic_message_len;
            break :blk null;
        },
        .artifact_kind = artifactKindFromByte(header.artifact_kind),
        .artifact_hash = header.artifact_hash,
        .artifact_total_bytes = header.artifact_total_bytes,
        .report_total_bytes = header.report_total_bytes,
        .report_draft_type = draftTypeFromByte(header.report_draft_type),
    };
    errdefer parsed.deinit();

    parsed.trace = .{
        .step = header.step_count,
        .active_branches = header.active_branches,
        .reasoning_mode = reasoningModeFromByte(header.reasoning_mode),
        .step_count = header.step_count,
        .branch_count = header.branch_count,
        .created_hypotheses = header.created_hypotheses,
        .expanded_hypotheses = header.expanded_hypotheses,
        .killed_hypotheses = header.killed_hypotheses,
        .accepted_hypotheses = header.accepted_hypotheses,
        .unresolved_hypotheses = header.unresolved_hypotheses,
        .best_char = header.best_char,
        .best_score = header.best_score,
        .runner_up_score = header.runner_up_score,
        .confidence = header.confidence,
        .killed_branches = header.killed_branches,
        .killed_by_branch_cap = header.killed_by_branch_cap,
        .killed_by_contradiction = header.killed_by_contradiction,
        .contradiction_checks = header.contradiction_checks,
        .contradiction_count = header.contradiction_count,
        .stop_reason = @enumFromInt(header.stop_reason),
    };
    parsed.context.reasoning_mode = reasoningModeFromByte(header.reasoning_mode);
    parsed.context.shard_kind = shardKindFromByte(header.shard_kind);
    parsed.context.scratch_active = (header.flags & FLAG_SCRATCH_ACTIVE) != 0;
    parsed.context.scratch_only = (header.flags & FLAG_SCRATCH_ONLY) != 0;

    if ((header.flags & FLAG_HAS_REPO_ROOT) != 0 and header.repo_root_len > 0) {
        parsed.context.repo_root = try readOwnedSlice(allocator, bytes, cursor, header.repo_root_len);
    } else {
        cursor.* += header.repo_root_len;
    }
    if ((header.flags & FLAG_HAS_SHARD_ID) != 0 and header.shard_id_len > 0) {
        parsed.context.shard_id = try readOwnedSlice(allocator, bytes, cursor, header.shard_id_len);
    } else {
        cursor.* += header.shard_id_len;
    }
    if ((header.flags & FLAG_HAS_SHARD_ROOT) != 0 and header.shard_root_len > 0) {
        parsed.context.shard_root = try readOwnedSlice(allocator, bytes, cursor, header.shard_root_len);
    } else {
        cursor.* += header.shard_root_len;
    }
    if ((header.flags & FLAG_HAS_REQUEST_LABEL) != 0 and header.request_label_len > 0) {
        parsed.context.request_label = try readOwnedSlice(allocator, bytes, cursor, header.request_label_len);
    } else {
        cursor.* += header.request_label_len;
    }
    if ((header.flags & FLAG_HAS_TARGET) != 0 and header.target_len > 0) {
        parsed.context.target = try readOwnedSlice(allocator, bytes, cursor, header.target_len);
    } else {
        cursor.* += header.target_len;
    }
    if ((header.flags & FLAG_HAS_OTHER_TARGET) != 0 and header.other_target_len > 0) {
        parsed.context.other_target = try readOwnedSlice(allocator, bytes, cursor, header.other_target_len);
    } else {
        cursor.* += header.other_target_len;
    }
    if ((header.flags & FLAG_HAS_ARTIFACT_PATH) != 0 and header.artifact_path_len > 0) {
        parsed.artifact_path = try readOwnedSlice(allocator, bytes, cursor, header.artifact_path_len);
    } else {
        cursor.* += header.artifact_path_len;
    }
    parsed.artifact_json = try readOwnedSlice(allocator, bytes, cursor, header.artifact_len);
    parsed.report = try readOwnedSlice(allocator, bytes, cursor, header.report_len);

    parsed.candidates = try allocator.alloc(CandidateRecord, header.candidate_count);
    for (parsed.candidates) |*candidate| {
        candidate.* = .{
            .char_code = try readIntAt(bytes, cursor, u32),
            .branch_index = try readIntAt(bytes, cursor, u32),
            .base_score = try readIntAt(bytes, cursor, u32),
            .score = try readIntAt(bytes, cursor, u32),
            .confidence = try readIntAt(bytes, cursor, u32),
        };
    }

    parsed.hypotheses = try allocator.alloc(HypothesisRecord, header.hypothesis_count);
    for (parsed.hypotheses) |*hypothesis| {
        hypothesis.* = .{
            .root_char = try readIntAt(bytes, cursor, u32),
            .branch_index = try readIntAt(bytes, cursor, u32),
            .last_char = try readIntAt(bytes, cursor, u32),
            .depth = try readIntAt(bytes, cursor, u32),
            .score = try readIntAt(bytes, cursor, u32),
            .confidence = try readIntAt(bytes, cursor, u32),
        };
    }

    parsed.scratch_refs = try allocator.alloc(ScratchReference, header.scratch_ref_count);
    for (parsed.scratch_refs) |*reference| {
        reference.* = .{
            .slot_index = try readIntAt(bytes, cursor, u32),
            .hash = try readIntAt(bytes, cursor, u64),
        };
    }

    return parsed;
}

fn writeHeaderV2(writer: anytype, hdr: HeaderV2) !void {
    try writeInt(writer, u32, hdr.flags);
    try writeInt(writer, u32, hdr.total_bytes);
    try writeInt(writer, u8, hdr.stop_reason);
    try writeInt(writer, u8, hdr.engine_version_len);
    try writeInt(writer, u16, hdr.panic_message_len);
    try writeInt(writer, u32, hdr.step_count);
    try writeInt(writer, u32, hdr.confidence);
    try writeInt(writer, u32, hdr.active_branches);
    try writeInt(writer, u32, hdr.branch_count);
    try writeInt(writer, u32, hdr.created_hypotheses);
    try writeInt(writer, u32, hdr.expanded_hypotheses);
    try writeInt(writer, u32, hdr.killed_hypotheses);
    try writeInt(writer, u32, hdr.accepted_hypotheses);
    try writeInt(writer, u32, hdr.unresolved_hypotheses);
    try writeInt(writer, u32, hdr.best_char);
    try writeInt(writer, u32, hdr.best_score);
    try writeInt(writer, u32, hdr.runner_up_score);
    try writeInt(writer, u32, hdr.killed_branches);
    try writeInt(writer, u32, hdr.killed_by_branch_cap);
    try writeInt(writer, u32, hdr.killed_by_contradiction);
    try writeInt(writer, u32, hdr.contradiction_checks);
    try writeInt(writer, u32, hdr.contradiction_count);
    try writeInt(writer, u16, hdr.candidate_count);
    try writeInt(writer, u16, hdr.candidate_total_count);
    try writeInt(writer, u16, hdr.hypothesis_count);
    try writeInt(writer, u16, hdr.hypothesis_total_count);
    try writeInt(writer, u16, hdr.scratch_ref_count);
    try writeInt(writer, u16, hdr.scratch_ref_total_count);
    try writeInt(writer, u16, hdr.repo_root_len);
    try writeInt(writer, u16, hdr.shard_id_len);
    try writeInt(writer, u16, hdr.shard_root_len);
    try writeInt(writer, u16, hdr.request_label_len);
    try writeInt(writer, u16, hdr.target_len);
    try writeInt(writer, u16, hdr.other_target_len);
    try writeInt(writer, u16, hdr.artifact_path_len);
    try writeInt(writer, u32, hdr.artifact_len);
    try writeInt(writer, u32, hdr.artifact_total_bytes);
    try writeInt(writer, u32, hdr.report_len);
    try writeInt(writer, u32, hdr.report_total_bytes);
    try writeInt(writer, u64, hdr.artifact_hash);
    try writeInt(writer, u8, hdr.artifact_kind);
    try writeInt(writer, u8, hdr.reasoning_mode);
    try writeInt(writer, u8, hdr.shard_kind);
    try writeInt(writer, u8, hdr.report_draft_type);
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

fn readIntAt(bytes: []const u8, cursor: *usize, comptime T: type) !T {
    if (cursor.* + @sizeOf(T) > bytes.len) return error.InvalidPanicDump;
    const view: *const [@sizeOf(T)]u8 = @ptrCast(bytes[cursor.* .. cursor.* + @sizeOf(T)].ptr);
    const value = std.mem.readInt(T, view, .little);
    cursor.* += @sizeOf(T);
    return value;
}

fn readOwnedSlice(allocator: std.mem.Allocator, bytes: []const u8, cursor: *usize, len: anytype) ![]u8 {
    const usize_len: usize = @intCast(len);
    if (cursor.* + usize_len > bytes.len) return error.InvalidPanicDump;
    const out = try allocator.alloc(u8, usize_len);
    @memcpy(out, bytes[cursor.* .. cursor.* + usize_len]);
    cursor.* += usize_len;
    return out;
}

fn readAbsoluteAlloc(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    return file.readToEndAlloc(allocator, max_bytes);
}

fn saturatingCount(len: usize) u16 {
    return @intCast(@min(len, std.math.maxInt(u16)));
}

fn reasoningModeByte(mode: inference.ReasoningMode) u8 {
    return switch (mode) {
        .proof => 1,
        .exploratory => 2,
    };
}

fn reasoningModeFromByte(value: u8) inference.ReasoningMode {
    return switch (value) {
        2 => .exploratory,
        else => .proof,
    };
}

fn shardKindByte(kind: ?shards.Kind) u8 {
    return if (kind) |value| switch (value) {
        .core => 1,
        .project => 2,
        .scratch => 3,
    } else 0;
}

fn shardKindFromByte(value: u8) ?shards.Kind {
    return switch (value) {
        1 => .core,
        2 => .project,
        3 => .scratch,
        else => null,
    };
}

fn draftTypeByte(value: ?technical_drafts.DraftType) u8 {
    return if (value) |draft_type| switch (draft_type) {
        .proof_backed_explanation => 1,
        .refactor_plan => 2,
        .contradiction_report => 3,
        .code_change_summary => 4,
        .technical_design_alternatives => 5,
    } else 0;
}

fn draftTypeFromByte(value: u8) ?technical_drafts.DraftType {
    return switch (value) {
        1 => .proof_backed_explanation,
        2 => .refactor_plan,
        3 => .contradiction_report,
        4 => .code_change_summary,
        5 => .technical_design_alternatives,
        else => null,
    };
}

fn artifactKindFromByte(value: u8) ArtifactKind {
    return @enumFromInt(@min(value, @intFromEnum(ArtifactKind.patch_candidates_result)));
}

fn hashBytes(bytes: []const u8) u64 {
    var hash: u64 = 14695981039346656037;
    for (bytes) |byte| {
        hash ^= byte;
        hash *%= 1099511628211;
    }
    return hash;
}

fn classifyObservational(dump: *const ParsedDump) ReplayClass {
    if (dump.artifact_kind != .none or dump.report.len > 0) return .observational_only;
    if (dump.candidates.len > 0 or dump.hypotheses.len > 0 or dump.scratch_refs.len > 0) return .observational_only;
    if (dump.trace.step_count > 0 or dump.trace.confidence > 0 or dump.trace.stop_reason != .none) return .observational_only;
    return .insufficient_replay_state;
}

fn renderArtifactNarrative(writer: anytype, allocator: std.mem.Allocator, dump: *const ParsedDump, inspection: *const ReplayInspection) !void {
    if (inspection.artifact_bytes.len == 0 or inspection.class != .fully_replayable) return;

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, inspection.artifact_bytes, .{}) catch return;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return;

    switch (dump.artifact_kind) {
        .code_intel_result => try renderCodeIntelNarrative(writer, root),
        .patch_candidates_result => try renderPatchNarrative(writer, root),
        .none => {},
    }
}

fn renderCodeIntelNarrative(writer: anytype, root: std.json.Value) !void {
    const obj = root.object;
    const status = jsonString(obj.get("status"));
    const query_kind = jsonString(obj.get("queryKind"));
    const target = jsonString(obj.get("target"));
    const honesty = jsonObject(obj.get("honesty"));
    const support_graph = jsonObject(obj.get("supportGraph"));
    const pack_influence = jsonObject(obj.get("packInfluence"));
    const trace = jsonObject(obj.get("trace"));
    try writer.writeAll("replay_summary kind=code_intel_result\n");
    if (query_kind) |value| try writer.print("attempted query_kind={s}\n", .{value});
    if (target) |value| try writer.print("attempted target={s}\n", .{value});
    if (status) |value| try writer.print("result status={s}\n", .{value});
    if (honesty) |value| {
        if (jsonString(value.get("stopReason"))) |stop_reason| try writer.print("result stop_reason={s}\n", .{stop_reason});
        if (jsonInt(value.get("confidence"))) |confidence| try writer.print("result confidence={d}\n", .{confidence});
    }
    if (jsonString(obj.get("detail"))) |detail| try writer.print("unresolved_detail={s}\n", .{detail});
    if (support_graph) |graph| {
        try writer.print(
            "support nodes={d} edges={d}\n",
            .{
                jsonArrayLen(graph.get("nodes")),
                jsonArrayLen(graph.get("edges")),
            },
        );
    }
    if (pack_influence) |value| {
        if (jsonObject(value.get("summary"))) |summary| {
            try writer.print(
                "pack considered={d} activated={d} skipped={d} suppressed={d} conflict_refused={d} trust_blocked={d} stale_blocked={d} candidate_surfaces={d}\n",
                .{
                    jsonInt(summary.get("consideredCount")) orelse 0,
                    jsonInt(summary.get("activatedCount")) orelse 0,
                    jsonInt(summary.get("skippedCount")) orelse 0,
                    jsonInt(summary.get("suppressedCount")) orelse 0,
                    jsonInt(summary.get("conflictRefusedCount")) orelse 0,
                    jsonInt(summary.get("trustBlockedCount")) orelse 0,
                    jsonInt(summary.get("staleBlockedCount")) orelse 0,
                    jsonInt(summary.get("candidateSurfaceCount")) orelse 0,
                },
            );
        }
    }
    if (trace) |value| {
        try writer.print(
            "reasoning target_candidates={d} query_hypotheses={d}\n",
            .{
                jsonNestedArrayLen(value, "layer2a", "targetCandidates"),
                jsonNestedArrayLen(value, "layer2b", "queryHypotheses"),
            },
        );
    }
}

fn renderPatchNarrative(writer: anytype, root: std.json.Value) !void {
    const obj = root.object;
    const status = jsonString(obj.get("status"));
    const target = jsonString(obj.get("target"));
    const request_label = jsonString(obj.get("requestLabel"));
    const honesty = jsonObject(obj.get("honesty"));
    const support_graph = jsonObject(obj.get("supportGraph"));
    const handoff = jsonObject(obj.get("handoff"));
    const pack_influence = jsonObject(obj.get("packInfluence"));
    const candidates = jsonArray(obj.get("candidates"));

    try writer.writeAll("replay_summary kind=patch_candidates_result\n");
    if (request_label) |value| try writer.print("attempted request={s}\n", .{value});
    if (target) |value| try writer.print("attempted target={s}\n", .{value});
    if (status) |value| try writer.print("result status={s}\n", .{value});
    if (honesty) |value| {
        if (jsonString(value.get("stopReason"))) |stop_reason| try writer.print("result stop_reason={s}\n", .{stop_reason});
        if (jsonInt(value.get("confidence"))) |confidence| try writer.print("result confidence={d}\n", .{confidence});
    }
    if (jsonString(obj.get("selectedCandidateId"))) |value| try writer.print("selected_candidate={s}\n", .{value});
    if (jsonString(obj.get("selectedStrategy"))) |value| try writer.print("selected_strategy={s}\n", .{value});
    if (jsonString(obj.get("selectedRefactorScope"))) |value| try writer.print("selected_scope={s}\n", .{value});
    if (jsonString(obj.get("unresolvedDetail"))) |detail| try writer.print("unresolved_detail={s}\n", .{detail});

    if (handoff) |value| {
        if (jsonObject(value.get("exploration"))) |exploration| {
            try writer.print(
                "exploration generated={d} proof_queue={d} preserved_novel={d}\n",
                .{
                    jsonInt(exploration.get("generatedCandidateCount")) orelse 0,
                    jsonInt(exploration.get("proofQueueCount")) orelse 0,
                    jsonInt(exploration.get("preservedNovelCount")) orelse 0,
                },
            );
        }
        if (jsonObject(value.get("proof"))) |proof| {
            try writer.print(
                "proof queued={d} verified_survivors={d} supported={d} rejected={d} unresolved={d}\n",
                .{
                    jsonInt(proof.get("queuedCandidateCount")) orelse 0,
                    jsonInt(proof.get("verifiedSurvivorCount")) orelse 0,
                    jsonInt(proof.get("supportedCount")) orelse 0,
                    jsonInt(proof.get("rejectedCount")) orelse 0,
                    jsonInt(proof.get("unresolvedCount")) orelse 0,
                },
            );
        }
    }
    if (pack_influence) |value| {
        if (jsonObject(value.get("summary"))) |summary| {
            try writer.print(
                "pack considered={d} activated={d} skipped={d} suppressed={d} conflict_refused={d} trust_blocked={d} stale_blocked={d} candidate_surfaces={d}\n",
                .{
                    jsonInt(summary.get("consideredCount")) orelse 0,
                    jsonInt(summary.get("activatedCount")) orelse 0,
                    jsonInt(summary.get("skippedCount")) orelse 0,
                    jsonInt(summary.get("suppressedCount")) orelse 0,
                    jsonInt(summary.get("conflictRefusedCount")) orelse 0,
                    jsonInt(summary.get("trustBlockedCount")) orelse 0,
                    jsonInt(summary.get("staleBlockedCount")) orelse 0,
                    jsonInt(summary.get("candidateSurfaceCount")) orelse 0,
                },
            );
        }
    }

    if (candidates) |items| {
        var build_failed: usize = 0;
        var test_failed: usize = 0;
        var runtime_failed: usize = 0;
        var repair_total: usize = 0;
        var repair_improved: usize = 0;
        var repair_failed: usize = 0;

        for (items.items) |item| {
            if (item != .object) continue;
            const candidate_obj = item.object;
            const verification = jsonObject(candidate_obj.get("verification")) orelse continue;
            if (jsonObject(verification.get("build"))) |step| {
                if (std.mem.eql(u8, jsonString(step.get("status")) orelse "", "failed")) build_failed += 1;
            }
            if (jsonObject(verification.get("test"))) |step| {
                if (std.mem.eql(u8, jsonString(step.get("status")) orelse "", "failed")) test_failed += 1;
            }
            if (jsonObject(verification.get("runtime"))) |step| {
                if (std.mem.eql(u8, jsonString(step.get("status")) orelse "", "failed")) runtime_failed += 1;
            }
            if (jsonArray(verification.get("repairPlans"))) |plans| {
                repair_total += plans.items.len;
                for (plans.items) |plan| {
                    if (plan != .object) continue;
                    const outcome = jsonString(plan.object.get("outcome")) orelse "";
                    if (std.mem.eql(u8, outcome, "improved")) repair_improved += 1;
                    if (std.mem.eql(u8, outcome, "failed")) repair_failed += 1;
                    if (repair_total <= 4) {
                        const descendant = jsonString(plan.object.get("descendantId")) orelse "";
                        const parent = jsonString(plan.object.get("lineageParentId")) orelse "";
                        const strategy = jsonString(plan.object.get("strategy")) orelse "";
                        try writer.print("repair lineage={s}->{s} strategy={s} outcome={s}\n", .{ parent, descendant, strategy, outcome });
                    }
                }
            }
        }
        try writer.print(
            "verification build_failed={d} test_failed={d} runtime_failed={d} repair_total={d} repair_improved={d} repair_failed={d}\n",
            .{ build_failed, test_failed, runtime_failed, repair_total, repair_improved, repair_failed },
        );
    }

    if (support_graph) |graph| {
        try writer.print(
            "support nodes={d} edges={d} invariant={d} contradiction={d} abstractions={d}\n",
            .{
                jsonArrayLen(graph.get("nodes")),
                jsonArrayLen(graph.get("edges")),
                jsonArrayLen(obj.get("invariantEvidence")),
                jsonArrayLen(obj.get("contradictionEvidence")),
                jsonArrayLen(obj.get("abstractionRefs")),
            },
        );
    }
}

fn jsonString(value: ?std.json.Value) ?[]const u8 {
    if (value == null) return null;
    return switch (value.?) {
        .string => |text| text,
        else => null,
    };
}

fn jsonInt(value: ?std.json.Value) ?u64 {
    if (value == null) return null;
    return switch (value.?) {
        .integer => |number| @intCast(number),
        else => null,
    };
}

fn jsonObject(value: ?std.json.Value) ?std.json.ObjectMap {
    if (value == null) return null;
    return switch (value.?) {
        .object => |object| object,
        else => null,
    };
}

fn jsonArray(value: ?std.json.Value) ?std.json.Array {
    if (value == null) return null;
    return switch (value.?) {
        .array => |array| array,
        else => null,
    };
}

fn jsonArrayLen(value: ?std.json.Value) usize {
    return if (jsonArray(value)) |items| items.items.len else 0;
}

fn jsonNestedArrayLen(root: std.json.ObjectMap, comptime first: []const u8, comptime second: []const u8) usize {
    const outer = jsonObject(root.get(first)) orelse return 0;
    return if (jsonArray(outer.get(second))) |items| items.items.len else 0;
}

fn replayClassName(class: ReplayClass) []const u8 {
    return switch (class) {
        .fully_replayable => "fully_replayable",
        .observational_only => "observational_only",
        .insufficient_replay_state => "insufficient_replay_state",
    };
}

fn replaySourceName(source: ReplaySource) []const u8 {
    return switch (source) {
        .none => "none",
        .embedded => "embedded",
        .external_exact => "external_exact",
    };
}

fn artifactPathStatusName(status: ReplayInspection.ArtifactPathStatus) []const u8 {
    return switch (status) {
        .none => "none",
        .matched => "matched",
        .missing => "missing",
        .hash_mismatch => "hash_mismatch",
        .unreadable => "unreadable",
    };
}

fn artifactKindName(kind: ArtifactKind) []const u8 {
    return switch (kind) {
        .none => "none",
        .code_intel_result => "code_intel_result",
        .patch_candidates_result => "patch_candidates_result",
    };
}

fn draftTypeName(value: ?technical_drafts.DraftType) []const u8 {
    return if (value) |draft_type| technical_drafts.draftTypeName(draft_type) else "none";
}

fn boolText(value: bool) []const u8 {
    return if (value) "true" else "false";
}

fn writeJsonString(writer: anytype, value: []const u8) !void {
    try std.json.stringify(value, .{}, writer);
}

fn writeJsonFieldString(writer: anytype, name: []const u8, value: []const u8, first: bool) !void {
    if (!first) try writer.writeByte(',');
    try writeJsonString(writer, name);
    try writer.writeByte(':');
    try writeJsonString(writer, value);
}

fn writeOptionalStringField(writer: anytype, name: []const u8, value: []const u8) !void {
    try writer.writeByte(',');
    try writeJsonString(writer, name);
    try writer.writeByte(':');
    try writeJsonString(writer, value);
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
