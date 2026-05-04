const std = @import("std");
const shards = @import("shards.zig");

pub const CANDIDATES_REL_DIR = "verifier_candidates";
pub const CANDIDATES_FILE_NAME = "verifier_candidates.jsonl";
pub const SCHEMA_VERSION = "verifier_candidate.v1";
pub const REVIEW_SCHEMA_VERSION = "reviewed_verifier_candidate.v1";
pub const MAX_CANDIDATES_READ: usize = 128;
pub const MAX_CANDIDATES_BYTES: usize = 256 * 1024;

pub const Decision = enum {
    approved,
    rejected,

    pub fn parse(text: []const u8) ?Decision {
        if (std.mem.eql(u8, text, "approved")) return .approved;
        if (std.mem.eql(u8, text, "accepted")) return .approved;
        if (std.mem.eql(u8, text, "rejected")) return .rejected;
        return null;
    }
};

pub const CandidateSummary = struct {
    id: []u8,
    source_kind: []u8,
    source_ref: []u8,
    source_command_candidate_id: []u8,
    argv: [][]u8,
    cwd_hint: []u8,
    purpose: []u8,
    reason: []u8,
    risk_level: []u8,
    mutation_risk_disclosure: []u8,
    evidence_paths: [][]u8,
    status: []u8,
    reviewed_by: ?[]u8 = null,
    review_reason: ?[]u8 = null,

    pub fn deinit(self: *CandidateSummary, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.source_kind);
        allocator.free(self.source_ref);
        allocator.free(self.source_command_candidate_id);
        for (self.argv) |item| allocator.free(item);
        allocator.free(self.argv);
        allocator.free(self.cwd_hint);
        allocator.free(self.purpose);
        allocator.free(self.reason);
        allocator.free(self.risk_level);
        allocator.free(self.mutation_risk_disclosure);
        for (self.evidence_paths) |item| allocator.free(item);
        allocator.free(self.evidence_paths);
        allocator.free(self.status);
        if (self.reviewed_by) |value| allocator.free(value);
        if (self.review_reason) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub const ProposeResult = struct {
    allocator: std.mem.Allocator,
    storage_path: []u8,
    record_jsons: [][]u8,

    pub fn deinit(self: *ProposeResult) void {
        allocatorFreeStrings(self.allocator, self.record_jsons);
        self.allocator.free(self.storage_path);
        self.* = undefined;
    }
};

pub const ReviewResult = struct {
    allocator: std.mem.Allocator,
    storage_path: []u8,
    record_json: []u8,

    pub fn deinit(self: *ReviewResult) void {
        self.allocator.free(self.storage_path);
        self.allocator.free(self.record_json);
        self.* = undefined;
    }
};

pub const ListResult = struct {
    allocator: std.mem.Allocator,
    storage_path: []u8,
    candidates: []CandidateSummary,
    total_read: usize,
    malformed_lines: usize,
    truncated: bool,
    max_records_hit: bool,
    missing_file: bool,

    pub fn deinit(self: *ListResult) void {
        for (self.candidates) |*candidate| candidate.deinit(self.allocator);
        self.allocator.free(self.candidates);
        self.allocator.free(self.storage_path);
        self.* = undefined;
    }
};

pub fn candidatesPath(allocator: std.mem.Allocator, project_shard: []const u8) ![]u8 {
    var metadata = try shards.resolveProjectMetadata(allocator, project_shard);
    defer metadata.deinit();
    var paths = try shards.resolvePaths(allocator, metadata.metadata);
    defer paths.deinit();
    return std.fs.path.join(allocator, &.{ paths.root_abs_path, CANDIDATES_REL_DIR, CANDIDATES_FILE_NAME });
}

pub fn proposeFromLearningPlanBody(allocator: std.mem.Allocator, body: []const u8) !ProposeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.InvalidJson;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidRequest;

    const root = parsed.value.object;
    const project_shard = getStrAny(root, &.{ "project_shard", "projectShard" }) orelse return error.MissingProjectShard;
    const plan_value = root.get("learningLoopPlan") orelse root.get("learning_loop_plan") orelse root.get("plan") orelse return error.MissingLearningPlan;
    if (plan_value != .object) return error.InvalidLearningPlan;
    const plan = plan_value.object;
    const refs_value = plan.get("verifier_candidate_refs") orelse plan.get("verifierCandidateRefs") orelse return error.InvalidLearningPlan;
    if (refs_value != .array or refs_value.array.items.len == 0) return error.InvalidLearningPlan;

    const plan_id = getStrAny(plan, &.{ "plan_id", "planId" }) orelse "learning_loop_plan.unknown";
    for (refs_value.array.items) |ref_value| {
        if (ref_value != .object) return error.InvalidVerifierRef;
        const ref = ref_value.object;
        _ = getStrAny(ref, &.{ "id", "refId" }) orelse return error.InvalidVerifierRef;
        _ = getStrAny(ref, &.{ "source_command_candidate_id", "sourceCommandCandidateId" }) orelse return error.InvalidVerifierRef;
        const argv_value = ref.get("argv") orelse return error.InvalidVerifierRef;
        if (argv_value != .array or argv_value.array.items.len == 0) return error.InvalidVerifierRef;
        for (argv_value.array.items) |arg| {
            if (arg != .string or std.mem.trim(u8, arg.string, " \r\n\t").len == 0) return error.InvalidVerifierRef;
        }
        const requires_approval = getBoolAny(ref, &.{ "requires_approval", "requiresApproval" }) orelse true;
        if (!requires_approval) return error.InvalidVerifierRef;
        const executes_by_default = getBoolAny(ref, &.{ "executes_by_default", "executesByDefault" }) orelse false;
        if (executes_by_default) return error.InvalidVerifierRef;
    }

    const path = try candidatesPath(allocator, project_shard);
    errdefer allocator.free(path);
    const parent = std.fs.path.dirname(path) orelse return error.InvalidPath;
    try std.fs.cwd().makePath(parent);

    var file = try std.fs.createFileAbsolute(path, .{ .read = true, .truncate = false });
    defer file.close();
    var append_offset = try file.getEndPos();
    try file.seekTo(append_offset);

    var records = std.ArrayList([]u8).init(allocator);
    errdefer {
        for (records.items) |record| allocator.free(record);
        records.deinit();
    }

    for (refs_value.array.items) |ref_value| {
        const ref = ref_value.object;
        const record_json = try renderProposalRecord(allocator, project_shard, plan_id, ref, append_offset);
        errdefer allocator.free(record_json);
        try file.writeAll(record_json);
        try file.writeAll("\n");
        append_offset += record_json.len + 1;
        try records.append(record_json);
    }

    return .{
        .allocator = allocator,
        .storage_path = path,
        .record_jsons = try records.toOwnedSlice(),
    };
}

pub fn reviewBody(allocator: std.mem.Allocator, body: []const u8) !ReviewResult {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.InvalidJson;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidRequest;
    const obj = parsed.value.object;
    const project_shard = getStrAny(obj, &.{ "project_shard", "projectShard" }) orelse return error.MissingProjectShard;
    const candidate_id = getStrAny(obj, &.{ "candidate_id", "candidateId", "id" }) orelse return error.MissingCandidateId;
    const decision_text = getStrAny(obj, &.{ "decision", "reviewDecision" }) orelse return error.MissingDecision;
    const decision = Decision.parse(decision_text) orelse return error.InvalidDecision;
    const reviewed_by = getStrAny(obj, &.{ "reviewed_by", "reviewedBy", "reviewer" }) orelse "operator";
    const review_reason = getStrAny(obj, &.{ "review_reason", "reviewReason", "reason" }) orelse "";

    var listed = try listCandidates(allocator, project_shard, MAX_CANDIDATES_READ);
    defer listed.deinit();
    var found = false;
    for (listed.candidates) |candidate| {
        if (std.mem.eql(u8, candidate.id, candidate_id)) {
            found = true;
            break;
        }
    }
    if (!found) return error.CandidateNotFound;

    const path = try candidatesPath(allocator, project_shard);
    errdefer allocator.free(path);
    const parent = std.fs.path.dirname(path) orelse return error.InvalidPath;
    try std.fs.cwd().makePath(parent);
    var file = try std.fs.createFileAbsolute(path, .{ .read = true, .truncate = false });
    defer file.close();
    const append_offset = try file.getEndPos();
    try file.seekTo(append_offset);

    const record_json = try renderReviewRecord(allocator, project_shard, candidate_id, decision, reviewed_by, review_reason, append_offset);
    errdefer allocator.free(record_json);
    try file.writeAll(record_json);
    try file.writeAll("\n");
    return .{ .allocator = allocator, .storage_path = path, .record_json = record_json };
}

pub fn listCandidates(allocator: std.mem.Allocator, project_shard: []const u8, max_records: usize) !ListResult {
    const path = try candidatesPath(allocator, project_shard);
    errdefer allocator.free(path);
    const data = std.fs.cwd().readFileAlloc(allocator, path, MAX_CANDIDATES_BYTES) catch |err| switch (err) {
        error.FileNotFound => return .{
            .allocator = allocator,
            .storage_path = path,
            .candidates = &.{},
            .total_read = 0,
            .malformed_lines = 0,
            .truncated = false,
            .max_records_hit = false,
            .missing_file = true,
        },
        else => return err,
    };
    defer allocator.free(data);

    var candidates = std.ArrayList(CandidateSummary).init(allocator);
    errdefer {
        for (candidates.items) |*candidate| candidate.deinit(allocator);
        candidates.deinit();
    }

    var total_read: usize = 0;
    var malformed_lines: usize = 0;
    var iter = std.mem.splitScalar(u8, data, '\n');
    while (iter.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \r\n\t");
        if (line.len == 0) continue;
        if (total_read >= max_records) break;
        total_read += 1;

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch {
            malformed_lines += 1;
            continue;
        };
        defer parsed.deinit();
        if (parsed.value != .object) {
            malformed_lines += 1;
            continue;
        }
        const obj = parsed.value.object;
        const record_shard = getStrAny(obj, &.{ "projectShard", "project_shard" }) orelse {
            malformed_lines += 1;
            continue;
        };
        if (!std.mem.eql(u8, record_shard, project_shard)) continue;
        const record_type = getStrAny(obj, &.{"recordType"}) orelse {
            malformed_lines += 1;
            continue;
        };
        if (std.mem.eql(u8, record_type, "verifier_candidate_proposal")) {
            var candidate = duplicateCandidateFromProposal(allocator, obj) catch {
                malformed_lines += 1;
                continue;
            };
            errdefer candidate.deinit(allocator);
            const existing = findCandidate(candidates.items, candidate.id);
            if (existing) |idx| {
                candidates.items[idx].deinit(allocator);
                candidates.items[idx] = candidate;
            } else {
                try candidates.append(candidate);
            }
        } else if (std.mem.eql(u8, record_type, "verifier_candidate_review")) {
            const candidate_id = getStrAny(obj, &.{"candidateId"}) orelse {
                malformed_lines += 1;
                continue;
            };
            const idx = findCandidate(candidates.items, candidate_id) orelse continue;
            const status = getStrAny(obj, &.{"status"}) orelse "proposed";
            allocator.free(candidates.items[idx].status);
            candidates.items[idx].status = try allocator.dupe(u8, status);
            if (candidates.items[idx].reviewed_by) |old| allocator.free(old);
            candidates.items[idx].reviewed_by = if (getStrAny(obj, &.{"reviewedBy"})) |v| try allocator.dupe(u8, v) else null;
            if (candidates.items[idx].review_reason) |old| allocator.free(old);
            candidates.items[idx].review_reason = if (getStrAny(obj, &.{"reviewReason"})) |v| try allocator.dupe(u8, v) else null;
        }
    }

    return .{
        .allocator = allocator,
        .storage_path = path,
        .candidates = try candidates.toOwnedSlice(),
        .total_read = total_read,
        .malformed_lines = malformed_lines,
        .truncated = data.len == MAX_CANDIDATES_BYTES,
        .max_records_hit = total_read >= max_records,
        .missing_file = false,
    };
}

pub fn writeProposeResultJson(writer: anytype, result: ProposeResult) !void {
    try writer.writeAll("{\"verifierCandidateProposal\":{\"schemaVersion\":\"");
    try writer.writeAll(SCHEMA_VERSION);
    try writer.writeAll("\",\"candidateCount\":");
    try writer.print("{d}", .{result.record_jsons.len});
    try writer.writeAll(",\"records\":[");
    for (result.record_jsons, 0..) |record, i| {
        if (i != 0) try writer.writeByte(',');
        try writer.writeAll(record);
    }
    try writer.writeAll("],\"reviewRequired\":true,\"candidateOnly\":true,\"nonAuthorizing\":true,\"commandsExecuted\":false,\"verifiersExecuted\":false,\"executed\":false,\"producedEvidence\":false,\"mutatesState\":true,\"authorityEffect\":\"candidate\"}}");
}

pub fn writeReviewResultJson(writer: anytype, result: ReviewResult) !void {
    try writer.writeAll("{\"verifierCandidateReview\":");
    try writer.writeAll(result.record_json);
    try writer.writeAll(",\"reviewRequired\":false,\"candidateOnly\":true,\"nonAuthorizing\":true,\"commandsExecuted\":false,\"verifiersExecuted\":false,\"executed\":false,\"producedEvidence\":false,\"mutatesState\":true,\"authorityEffect\":\"candidate\"}");
}

pub fn writeListResultJson(writer: anytype, result: ListResult) !void {
    try writer.writeAll("{\"verifierCandidateList\":{\"schemaVersion\":\"");
    try writer.writeAll(SCHEMA_VERSION);
    try writer.writeAll("\",\"candidates\":[");
    for (result.candidates, 0..) |candidate, i| {
        if (i != 0) try writer.writeByte(',');
        try writeCandidateJson(writer, candidate);
    }
    try writer.writeAll("],\"totalRead\":");
    try writer.print("{d}", .{result.total_read});
    try writer.writeAll(",\"malformedLines\":");
    try writer.print("{d}", .{result.malformed_lines});
    try writer.writeAll(",\"missingFile\":");
    try writer.writeAll(if (result.missing_file) "true" else "false");
    try writer.writeAll(",\"truncated\":");
    try writer.writeAll(if (result.truncated) "true" else "false");
    try writer.writeAll(",\"maxRecordsHit\":");
    try writer.writeAll(if (result.max_records_hit) "true" else "false");
    try writer.writeAll(",\"readOnly\":true,\"candidateOnly\":true,\"nonAuthorizing\":true,\"commandsExecuted\":false,\"verifiersExecuted\":false,\"executed\":false,\"producedEvidence\":false,\"mutatesState\":false,\"authorityEffect\":\"candidate\"}}");
}

fn renderProposalRecord(allocator: std.mem.Allocator, project_shard: []const u8, plan_id: []const u8, ref: std.json.ObjectMap, append_offset: u64) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();
    const ref_id = getStrAny(ref, &.{ "id", "refId" }).?;
    const body_hash = std.hash.Fnv1a_64.hash(plan_id) ^ std.hash.Fnv1a_64.hash(ref_id) ^ std.hash.Fnv1a_64.hash(project_shard);
    const candidate_id = try std.fmt.allocPrint(allocator, "verifier-candidate:{s}:{x:0>16}", .{ project_shard, body_hash });
    defer allocator.free(candidate_id);

    try w.writeByte('{');
    try writeStringField(w, "id", candidate_id, true);
    try writeStringField(w, "recordType", "verifier_candidate_proposal", false);
    try writeStringField(w, "schemaVersion", SCHEMA_VERSION, false);
    try writeStringField(w, "createdAt", "deterministic:append_order", false);
    try writeStringField(w, "projectShard", project_shard, false);
    try writeStringField(w, "sourceKind", "learning_loop_plan", false);
    try writeStringField(w, "sourceRef", ref_id, false);
    try writeStringField(w, "sourcePlanId", plan_id, false);
    try writeStringField(w, "sourceCommandCandidateId", getStrAny(ref, &.{ "source_command_candidate_id", "sourceCommandCandidateId" }).?, false);
    try w.writeAll(",\"argv\":");
    try writeJsonStringArrayFromValue(w, ref.get("argv").?);
    try writeStringField(w, "cwdHint", getStrAny(ref, &.{ "cwd_hint", "cwdHint" }) orelse "", false);
    try writeStringField(w, "purpose", "approval-required verifier candidate from learning.loop.plan", false);
    try writeStringField(w, "reason", getStrAny(ref, &.{"reason"}) orelse "learning.loop.plan verifier ref requires explicit review", false);
    try writeStringField(w, "riskLevel", "review_required", false);
    try writeStringField(w, "mutationRiskDisclosure", "candidate metadata only; no command or verifier execution", false);
    try w.writeAll(",\"evidencePaths\":");
    if (ref.get("evidence_paths") orelse ref.get("evidencePaths")) |evidence| try writeJsonStringArrayFromValue(w, evidence) else try w.writeAll("[]");
    try w.writeAll(",\"status\":\"proposed\",\"reviewRequired\":true,\"candidateOnly\":true,\"nonAuthorizing\":true,\"executesByDefault\":false,\"executed\":false,\"producedEvidence\":false,\"commandsExecuted\":false,\"verifiersExecuted\":false,\"supportGranted\":false,\"proofDischarged\":false");
    try w.writeAll(",\"appendOnly\":{\"storage\":\"jsonl\",\"appendOffsetBytes\":");
    try w.print("{d}", .{append_offset});
    try w.writeAll(",\"inPlaceRewrite\":false,\"deletion\":false,\"compaction\":false,\"stableOrdering\":\"file_append_order\"}}");
    return out.toOwnedSlice();
}

fn renderReviewRecord(allocator: std.mem.Allocator, project_shard: []const u8, candidate_id: []const u8, decision: Decision, reviewed_by: []const u8, review_reason: []const u8, append_offset: u64) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();
    const record_hash = std.hash.Fnv1a_64.hash(candidate_id) ^ std.hash.Fnv1a_64.hash(reviewed_by) ^ @as(u64, append_offset);
    const record_id = try std.fmt.allocPrint(allocator, "reviewed-verifier-candidate:{s}:{x:0>16}:{d}", .{ project_shard, record_hash, append_offset });
    defer allocator.free(record_id);
    const status = if (decision == .approved) "approved" else "rejected";

    try w.writeByte('{');
    try writeStringField(w, "id", record_id, true);
    try writeStringField(w, "recordType", "verifier_candidate_review", false);
    try writeStringField(w, "schemaVersion", REVIEW_SCHEMA_VERSION, false);
    try writeStringField(w, "createdAt", "deterministic:append_order", false);
    try writeStringField(w, "reviewedAt", "deterministic:append_order", false);
    try writeStringField(w, "projectShard", project_shard, false);
    try writeStringField(w, "candidateId", candidate_id, false);
    try writeStringField(w, "reviewDecision", @tagName(decision), false);
    try writeStringField(w, "status", status, false);
    try writeStringField(w, "reviewedBy", reviewed_by, false);
    try writeStringField(w, "reviewReason", review_reason, false);
    try w.writeAll(",\"approvalMeaning\":\"approved for possible future execution only; this record does not execute the verifier or produce evidence\"");
    try w.writeAll(",\"candidateOnly\":true,\"nonAuthorizing\":true,\"treatedAsProof\":false,\"approvalCreatesEvidence\":false,\"executesByDefault\":false,\"executed\":false,\"producedEvidence\":false,\"commandsExecuted\":false,\"verifiersExecuted\":false,\"supportGranted\":false,\"proofDischarged\":false");
    try w.writeAll(",\"appendOnly\":{\"storage\":\"jsonl\",\"appendOffsetBytes\":");
    try w.print("{d}", .{append_offset});
    try w.writeAll(",\"inPlaceRewrite\":false,\"deletion\":false,\"compaction\":false,\"stableOrdering\":\"file_append_order\"}}");
    return out.toOwnedSlice();
}

fn duplicateCandidateFromProposal(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !CandidateSummary {
    return .{
        .id = try allocator.dupe(u8, getStrAny(obj, &.{"id"}) orelse return error.InvalidRecord),
        .source_kind = try allocator.dupe(u8, getStrAny(obj, &.{"sourceKind"}) orelse "learning_loop_plan"),
        .source_ref = try allocator.dupe(u8, getStrAny(obj, &.{"sourceRef"}) orelse ""),
        .source_command_candidate_id = try allocator.dupe(u8, getStrAny(obj, &.{"sourceCommandCandidateId"}) orelse ""),
        .argv = try dupeStringArrayFromValue(allocator, obj.get("argv") orelse return error.InvalidRecord),
        .cwd_hint = try allocator.dupe(u8, getStrAny(obj, &.{"cwdHint"}) orelse ""),
        .purpose = try allocator.dupe(u8, getStrAny(obj, &.{"purpose"}) orelse ""),
        .reason = try allocator.dupe(u8, getStrAny(obj, &.{"reason"}) orelse ""),
        .risk_level = try allocator.dupe(u8, getStrAny(obj, &.{"riskLevel"}) orelse "review_required"),
        .mutation_risk_disclosure = try allocator.dupe(u8, getStrAny(obj, &.{"mutationRiskDisclosure"}) orelse "candidate metadata only"),
        .evidence_paths = try dupeStringArrayFromValue(allocator, obj.get("evidencePaths") orelse return error.InvalidRecord),
        .status = try allocator.dupe(u8, getStrAny(obj, &.{"status"}) orelse "proposed"),
    };
}

fn writeCandidateJson(w: anytype, candidate: CandidateSummary) !void {
    try w.writeByte('{');
    try writeStringField(w, "id", candidate.id, true);
    try writeStringField(w, "sourceKind", candidate.source_kind, false);
    try writeStringField(w, "sourceRef", candidate.source_ref, false);
    try writeStringField(w, "sourceCommandCandidateId", candidate.source_command_candidate_id, false);
    try w.writeAll(",\"argv\":");
    try writeStringArray(w, candidate.argv);
    try writeStringField(w, "cwdHint", candidate.cwd_hint, false);
    try writeStringField(w, "purpose", candidate.purpose, false);
    try writeStringField(w, "reason", candidate.reason, false);
    try writeStringField(w, "riskLevel", candidate.risk_level, false);
    try writeStringField(w, "mutationRiskDisclosure", candidate.mutation_risk_disclosure, false);
    try w.writeAll(",\"evidencePaths\":");
    try writeStringArray(w, candidate.evidence_paths);
    try writeStringField(w, "status", candidate.status, false);
    try w.writeAll(",\"reviewedBy\":");
    if (candidate.reviewed_by) |value| try writeJsonString(w, value) else try w.writeAll("null");
    try w.writeAll(",\"reviewReason\":");
    if (candidate.review_reason) |value| try writeJsonString(w, value) else try w.writeAll("null");
    try w.writeAll(",\"reviewRequired\":true,\"candidateOnly\":true,\"nonAuthorizing\":true,\"executesByDefault\":false,\"executed\":false,\"producedEvidence\":false,\"commandsExecuted\":false,\"verifiersExecuted\":false,\"supportGranted\":false,\"proofDischarged\":false}");
}

fn findCandidate(candidates: []CandidateSummary, id: []const u8) ?usize {
    for (candidates, 0..) |candidate, i| {
        if (std.mem.eql(u8, candidate.id, id)) return i;
    }
    return null;
}

fn getStrAny(obj: std.json.ObjectMap, names: []const []const u8) ?[]const u8 {
    for (names) |name| {
        const value = obj.get(name) orelse continue;
        if (value == .string) return value.string;
    }
    return null;
}

fn getBoolAny(obj: std.json.ObjectMap, names: []const []const u8) ?bool {
    for (names) |name| {
        const value = obj.get(name) orelse continue;
        if (value == .bool) return value.bool;
    }
    return null;
}

fn dupeStringArrayFromValue(allocator: std.mem.Allocator, value: std.json.Value) ![][]u8 {
    if (value != .array) return error.InvalidRecord;
    var out = try allocator.alloc([]u8, value.array.items.len);
    errdefer allocator.free(out);
    for (value.array.items, 0..) |item, i| {
        if (item != .string) return error.InvalidRecord;
        out[i] = try allocator.dupe(u8, item.string);
    }
    return out;
}

fn allocatorFreeStrings(allocator: std.mem.Allocator, strings: [][]u8) void {
    for (strings) |value| allocator.free(value);
    allocator.free(strings);
}

fn writeStringField(w: anytype, name: []const u8, value: []const u8, first: bool) !void {
    if (!first) try w.writeByte(',');
    try w.writeByte('"');
    try w.writeAll(name);
    try w.writeAll("\":");
    try writeJsonString(w, value);
}

fn writeJsonStringArrayFromValue(w: anytype, value: std.json.Value) !void {
    if (value != .array) return error.InvalidRecord;
    try w.writeByte('[');
    for (value.array.items, 0..) |item, i| {
        if (item != .string) return error.InvalidRecord;
        if (i != 0) try w.writeByte(',');
        try writeJsonString(w, item.string);
    }
    try w.writeByte(']');
}

fn writeStringArray(w: anytype, values: [][]u8) !void {
    try w.writeByte('[');
    for (values, 0..) |value, i| {
        if (i != 0) try w.writeByte(',');
        try writeJsonString(w, value);
    }
    try w.writeByte(']');
}

fn writeJsonString(w: anytype, value: []const u8) !void {
    try w.writeByte('"');
    for (value) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}

test "learning loop verifier refs become proposed verifier candidates without execution" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, "verifier_candidates.jsonl" });
    defer allocator.free(path);

    const body =
        \\{"projectShard":"verifier-candidate-unit","learningLoopPlan":{"schema_version":"learning_loop_plan.v1","plan_id":"plan.unit","verifier_candidate_refs":[{"id":"learning.verifier_ref.zig_build","source_command_candidate_id":"zig_build","argv":["zig","build"],"cwd_hint":"/workspace","reason":"detected build","evidence_paths":["build.zig"],"requires_approval":true,"executes_by_default":false}]}}
    ;
    var proposed = try proposeFromLearningPlanBodyAtPath(allocator, body, path);
    defer proposed.deinit();
    try std.testing.expectEqual(@as(usize, 1), proposed.record_jsons.len);
    try std.testing.expect(std.mem.indexOf(u8, proposed.record_jsons[0], "\"status\":\"proposed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, proposed.record_jsons[0], "\"executed\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, proposed.record_jsons[0], "\"producedEvidence\":false") != null);
}

fn proposeFromLearningPlanBodyAtPath(allocator: std.mem.Allocator, body: []const u8, path: []const u8) !ProposeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.InvalidJson;
    defer parsed.deinit();
    const root = parsed.value.object;
    const project_shard = getStrAny(root, &.{ "project_shard", "projectShard" }) orelse return error.MissingProjectShard;
    const plan = (root.get("learningLoopPlan") orelse return error.MissingLearningPlan).object;
    const refs = (plan.get("verifier_candidate_refs") orelse return error.InvalidLearningPlan).array;
    const plan_id = getStrAny(plan, &.{ "plan_id", "planId" }) orelse "learning_loop_plan.unknown";

    var file = try std.fs.createFileAbsolute(path, .{ .read = true, .truncate = false });
    defer file.close();
    var records = std.ArrayList([]u8).init(allocator);
    for (refs.items) |ref_value| {
        const record = try renderProposalRecord(allocator, project_shard, plan_id, ref_value.object, 0);
        try file.writeAll(record);
        try file.writeAll("\n");
        try records.append(record);
    }
    return .{ .allocator = allocator, .storage_path = try allocator.dupe(u8, path), .record_jsons = try records.toOwnedSlice() };
}
