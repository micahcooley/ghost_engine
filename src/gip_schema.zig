// ──────────────────────────────────────────────────────────────────────────
// GIP Schema — Request/Response envelopes and operation-specific types
//
// JSON field naming: camelCase (consistent with existing Ghost JSON output)
// Null fields: omitted
// Arrays: deterministically ordered
// ──────────────────────────────────────────────────────────────────────────

const std = @import("std");
const core = @import("gip_core.zig");

// ── GIP Error ─────────────────────────────────────────────────────────

pub const GipError = struct {
    code: core.ErrorCode,
    message: []const u8,
    details: ?[]const u8 = null,
    fix_hint: ?[]const u8 = null,
    retryable: bool = false,
    severity: core.ErrorSeverity = .@"error",
};

// ── Result State ──────────────────────────────────────────────────────

pub const ResultState = struct {
    state: core.SemanticState = .draft,
    permission: core.Permission = .none,
    is_draft: bool = true,
    verification_state: core.VerificationState = .unverified,
    support_minimum_met: bool = false,
    stop_reason: core.StopReason = .none,
    unresolved_reason: ?[]const u8 = null,
    failure_reason: ?[]const u8 = null,
    non_authorization_notice: ?[]const u8 = null,
};

pub fn draftResultState() ResultState {
    return .{
        .state = .draft,
        .permission = .none,
        .is_draft = true,
        .verification_state = .unverified,
        .support_minimum_met = false,
        .stop_reason = .unresolved,
        .non_authorization_notice = "this is a draft response and does not constitute supported output",
    };
}

pub fn unresolvedResultState(reason: ?[]const u8) ResultState {
    return .{
        .state = .unresolved,
        .permission = .unresolved,
        .is_draft = false,
        .verification_state = .unverified,
        .support_minimum_met = false,
        .stop_reason = .unresolved,
        .unresolved_reason = reason,
    };
}

pub fn unsupportedResultState() ResultState {
    return .{
        .state = .unresolved,
        .permission = .none,
        .is_draft = false,
        .verification_state = .not_applicable,
        .support_minimum_met = false,
        .stop_reason = .none,
    };
}

// ── Stats ─────────────────────────────────────────────────────────────

pub const Stats = struct {
    input_runes: ?usize = null,
    output_runes: ?usize = null,
    elapsed_ms: ?u64 = null,
    engine_elapsed_ms: ?u64 = null,
    requested_reasoning_level: ?[]const u8 = null,
    effective_compute_budget_tier: ?[]const u8 = null,
    budget_exhausted: bool = false,
    exhausted_limit: ?[]const u8 = null,
    exhausted_stage: ?[]const u8 = null,
    artifacts_considered: ?usize = null,
    hypotheses_generated: ?usize = null,
    hypotheses_selected: ?usize = null,
    verifier_jobs_scheduled: ?usize = null,
    packs_considered: ?usize = null,
    packs_activated: ?usize = null,
};

// ── Capability Report ─────────────────────────────────────────────────

pub const CapabilityReport = struct {
    requested: []const CapabilityReportEntry = &.{},
    effective: []const core.CapabilityEntry = &.{},
};

pub const CapabilityReportEntry = struct {
    capability: core.CapabilityName,
    requested: core.CapabilityPolicy,
    granted: core.CapabilityPolicy,
    reason: ?[]const u8 = null,
};

// ── Workspace ─────────────────────────────────────────────────────────

pub const Workspace = struct {
    root_path: []const u8,
    state_path: ?[]const u8 = null,
    project_shard: ?[]const u8 = null,
    allow_outside_root: bool = false,
};

// ── Artifact Ref ──────────────────────────────────────────────────────

pub const ArtifactRef = struct {
    artifact_id: ?[]const u8 = null,
    path: ?[]const u8 = null,
    uri: ?[]const u8 = null,
    content_hash: ?u64 = null,
    source_kind: core.SourceKind = .workspace_file,
    provenance: ?[]const u8 = null,
};

// ── Artifact Read Result ──────────────────────────────────────────────

pub const ArtifactReadResult = struct {
    artifact_ref: ArtifactRef,
    content: ?[]const u8 = null,
    byte_len: usize = 0,
    rune_count: usize = 0,
    hash: ?u64 = null,
    mtime: ?i128 = null,
    truncated: bool = false,
    truncation_reason: ?[]const u8 = null,
    provenance: ?[]const u8 = null,
};

// ── Artifact List Entry ───────────────────────────────────────────────

pub const ArtifactListEntry = struct {
    path: []const u8,
    kind: core.ArtifactEntryKind = .unknown,
    size: ?u64 = null,
    mtime: ?i128 = null,
    hash: ?u64 = null,
    artifact_type_hint: ?[]const u8 = null,
};

// ── Patch Edit ────────────────────────────────────────────────────────

pub const PatchSpan = struct {
    start_line: u32,
    start_col: ?u32 = null,
    end_line: u32,
    end_col: ?u32 = null,
};

pub const PatchPrecondition = struct {
    expected_hash: ?u64 = null,
    expected_text: ?[]const u8 = null,
    expected_span_hash: ?u64 = null,
};

pub const PatchEdit = struct {
    edit_id: ?[]const u8 = null,
    span: PatchSpan,
    replacement: []const u8,
    precondition: ?PatchPrecondition = null,
    provenance: ?[]const u8 = null,
    non_authorizing: bool = true,
};

pub const PatchProposal = struct {
    patch_id: []const u8,
    artifact_ref: ArtifactRef,
    edits: []const PatchEdit = &.{},
    applies_cleanly: bool = false,
    preview_diff: ?[]const u8 = null,
    requires_approval: bool = true,
    requires_verification: bool = true,
    non_authorizing: bool = true,
};

// ── Write Proposal ────────────────────────────────────────────────────

pub const WriteProposal = struct {
    write_id: []const u8,
    path: []const u8,
    byte_len: usize = 0,
    rune_count: usize = 0,
    content_hash: ?u64 = null,
    would_overwrite: bool = false,
    requires_approval: bool = true,
    non_authorizing: bool = true,
};

// ── Command Result ────────────────────────────────────────────────────

pub const CommandResult = struct {
    command_id: ?[]const u8 = null,
    argv: []const []const u8 = &.{},
    cwd: ?[]const u8 = null,
    exit_code: ?i32 = null,
    stdout: ?[]const u8 = null,
    stderr: ?[]const u8 = null,
    elapsed_ms: ?u64 = null,
    timed_out: bool = false,
    killed: bool = false,
    evidence_kind: ?[]const u8 = null,
    provenance: ?[]const u8 = null,
    dry_run: bool = false,
    max_rss_bytes: ?usize = null,
};

// ── Verifier Adapter Entry ────────────────────────────────────────────

pub const VerifierAdapterEntry = struct {
    adapter_id: []const u8,
    schema_name: []const u8,
    hook_kind: []const u8,
    budget_cost: u32 = 0,
    output_evidence_kind: []const u8,
};

// ── Hypothesis Entry ──────────────────────────────────────────────────

pub const HypothesisEntry = struct {
    id: []const u8,
    artifact_scope: []const u8,
    kind: []const u8,
    status: []const u8,
    non_authorizing: bool = true,
    support_potential: []const u8 = "low",
    score: ?u32 = null,
};

// ── Pack Entry ────────────────────────────────────────────────────────

pub const PackEntry = struct {
    pack_id: []const u8,
    version: []const u8,
    mounted: bool = false,
    enabled: bool = false,
    domain_family: []const u8 = "general",
    trust_class: []const u8 = "project",
    summary: ?[]const u8 = null,
};

// ── Conversation Turn Result ──────────────────────────────────────────

pub const ConversationTurnResult = struct {
    session_id: ?[]const u8 = null,
    turn_id: ?u32 = null,
    result_state: ResultState = draftResultState(),
    response_summary: ?[]const u8 = null,
    response_detail: ?[]const u8 = null,
    intent_classification: ?[]const u8 = null,
    requested_reasoning_level: ?[]const u8 = null,
    effective_compute_budget_tier: ?[]const u8 = null,
    selected_response_mode: ?[]const u8 = null,
    mode_selection_reason: ?[]const u8 = null,
    user_override_detected: bool = false,
};

// ── Protocol Description ──────────────────────────────────────────────

pub const ProtocolDescription = struct {
    gip_version: []const u8 = core.PROTOCOL_VERSION,
    engine_version: []const u8 = core.ENGINE_VERSION,
    supported_request_kinds: []const []const u8 = &.{},
    implemented_request_kinds: []const []const u8 = &.{},
    reasoning_levels: []const []const u8 = &.{ "quick", "balanced", "deep", "max" },
    semantic_states: []const []const u8 = &.{ "draft", "verified", "unresolved", "failed", "blocked", "ambiguous", "budget_exhausted" },
    protocol_statuses: []const []const u8 = &.{ "ok", "accepted", "partial", "unresolved", "failed", "rejected", "unsupported", "budget_exhausted" },
};

// ── Engine Status ─────────────────────────────────────────────────────

pub const EngineStatus = struct {
    engine_version: []const u8 = core.ENGINE_VERSION,
    gip_version: []const u8 = core.PROTOCOL_VERSION,
    platform: []const u8 = "linux",
    status: []const u8 = "operational",
};

// ── JSON Rendering ────────────────────────────────────────────────────

pub fn renderResponse(
    allocator: std.mem.Allocator,
    gip_version: []const u8,
    request_id: ?[]const u8,
    kind: ?core.RequestKind,
    status: core.ProtocolStatus,
    result_state: ?ResultState,
    result_json: ?[]const u8,
    err: ?GipError,
    stats: ?Stats,
) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    try w.writeAll("{");
    try writeStr(w, "gipVersion", gip_version, true);
    if (request_id) |rid| try writeStr(w, "requestId", rid, false);
    if (kind) |k| try writeStr(w, "kind", k.name(), false);
    try writeStr(w, "status", status.name(), false);

    if (result_state) |rs| {
        try w.writeAll(",\"resultState\":{");
        try writeStr(w, "state", rs.state.name(), true);
        try writeStr(w, "permission", rs.permission.name(), false);
        try w.print(",\"isDraft\":{s}", .{if (rs.is_draft) "true" else "false"});
        try writeStr(w, "verificationState", rs.verification_state.name(), false);
        try w.print(",\"supportMinimumMet\":{s}", .{if (rs.support_minimum_met) "true" else "false"});
        try writeStr(w, "stopReason", rs.stop_reason.name(), false);
        if (rs.unresolved_reason) |r| try writeStr(w, "unresolvedReason", r, false);
        if (rs.failure_reason) |r| try writeStr(w, "failureReason", r, false);
        if (rs.non_authorization_notice) |n| try writeStr(w, "nonAuthorizationNotice", n, false);
        try w.writeAll("}");
    }

    if (result_json) |rj| {
        try w.writeAll(",\"result\":");
        try w.writeAll(rj);
    }

    if (err) |e| {
        try w.writeAll(",\"error\":{");
        try writeStr(w, "code", e.code.name(), true);
        try writeStr(w, "message", e.message, false);
        if (e.details) |d| try writeStr(w, "details", d, false);
        if (e.fix_hint) |h| try writeStr(w, "fixHint", h, false);
        try w.print(",\"retryable\":{s}", .{if (e.retryable) "true" else "false"});
        try writeStr(w, "severity", e.severity.name(), false);
        try w.writeAll("}");
    }

    if (stats) |s| {
        try w.writeAll(",\"stats\":{");
        var first = true;
        if (s.input_runes) |v| {
            try writeUsize(w, "inputRunes", v, first);
            first = false;
        }
        if (s.output_runes) |v| {
            try writeUsize(w, "outputRunes", v, first);
            first = false;
        }
        if (s.elapsed_ms) |v| {
            try writeU64(w, "elapsedMs", v, first);
            first = false;
        }
        if (s.engine_elapsed_ms) |v| {
            try writeU64(w, "engineElapsedMs", v, first);
            first = false;
        }
        if (s.requested_reasoning_level) |v| {
            try writeStr(w, "requestedReasoningLevel", v, first);
            first = false;
        }
        if (s.effective_compute_budget_tier) |v| {
            try writeStr(w, "effectiveComputeBudgetTier", v, first);
            first = false;
        }
        if (s.budget_exhausted) {
            try writeBool(w, "budgetExhausted", true, first);
            first = false;
        }
        if (s.exhausted_limit) |v| {
            try writeStr(w, "exhaustedLimit", v, first);
            first = false;
        }
        if (s.exhausted_stage) |v| {
            try writeStr(w, "exhaustedStage", v, first);
            first = false;
        }
        if (s.artifacts_considered) |v| {
            try writeUsize(w, "artifactsConsidered", v, first);
            first = false;
        }
        if (s.hypotheses_generated) |v| {
            try writeUsize(w, "hypothesesGenerated", v, first);
            first = false;
        }
        if (s.hypotheses_selected) |v| {
            try writeUsize(w, "hypothesesSelected", v, first);
            first = false;
        }
        if (s.verifier_jobs_scheduled) |v| {
            try writeUsize(w, "verifierJobsScheduled", v, first);
            first = false;
        }
        if (s.packs_considered) |v| {
            try writeUsize(w, "packsConsidered", v, first);
            first = false;
        }
        if (s.packs_activated) |v| {
            try writeUsize(w, "packsActivated", v, first);
            first = false;
        }
        try w.writeAll("}");
    }

    try w.writeAll("}");
    return out.toOwnedSlice();
}

// ── JSON Helpers ──────────────────────────────────────────────────────

fn writeStr(w: anytype, key: []const u8, value: []const u8, first: bool) !void {
    if (!first) try w.writeByte(',');
    try w.writeByte('"');
    try w.writeAll(key);
    try w.writeAll("\":\"");
    try writeEscapedJson(w, value);
    try w.writeByte('"');
}

fn writeUsize(w: anytype, key: []const u8, value: usize, first: bool) !void {
    if (!first) try w.writeByte(',');
    try w.writeByte('"');
    try w.writeAll(key);
    try w.writeAll("\":");
    try w.print("{d}", .{value});
}

fn writeU64(w: anytype, key: []const u8, value: u64, first: bool) !void {
    if (!first) try w.writeByte(',');
    try w.writeByte('"');
    try w.writeAll(key);
    try w.writeAll("\":");
    try w.print("{d}", .{value});
}

fn writeBool(w: anytype, key: []const u8, value: bool, first: bool) !void {
    if (!first) try w.writeByte(',');
    try w.writeByte('"');
    try w.writeAll(key);
    try w.writeAll("\":");
    try w.writeAll(if (value) "true" else "false");
}

fn writeEscapedJson(w: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try w.print("\\u{x:0>4}", .{@as(u16, c)});
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
}

pub fn renderJsonStringArray(allocator: std.mem.Allocator, items: []const []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();
    try w.writeByte('[');
    for (items, 0..) |item, idx| {
        if (idx != 0) try w.writeByte(',');
        try w.writeByte('"');
        try writeEscapedJson(w, item);
        try w.writeByte('"');
    }
    try w.writeByte(']');
    return out.toOwnedSlice();
}

pub fn renderProtocolDescription(allocator: std.mem.Allocator) ![]u8 {
    var all_kinds_list = std.ArrayList([]const u8).init(allocator);
    defer all_kinds_list.deinit();
    inline for (std.meta.fields(core.RequestKind)) |field| {
        try all_kinds_list.append(field.name);
    }

    var impl_kinds_list = std.ArrayList([]const u8).init(allocator);
    defer impl_kinds_list.deinit();
    for (core.IMPLEMENTED_KINDS) |k| {
        try impl_kinds_list.append(k.name());
    }

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    try w.writeAll("{");
    try writeStr(w, "gipVersion", core.PROTOCOL_VERSION, true);
    try writeStr(w, "engineVersion", core.ENGINE_VERSION, false);

    const all_kinds = try renderJsonStringArray(allocator, all_kinds_list.items);
    defer allocator.free(all_kinds);
    try w.writeAll(",\"supportedRequestKinds\":");
    try w.writeAll(all_kinds);

    const impl_kinds = try renderJsonStringArray(allocator, impl_kinds_list.items);
    defer allocator.free(impl_kinds);
    try w.writeAll(",\"implementedRequestKinds\":");
    try w.writeAll(impl_kinds);

    const levels = try renderJsonStringArray(allocator, &.{ "quick", "balanced", "deep", "max" });
    defer allocator.free(levels);
    try w.writeAll(",\"reasoningLevels\":");
    try w.writeAll(levels);

    const states = try renderJsonStringArray(allocator, &.{ "draft", "verified", "unresolved", "failed", "blocked", "ambiguous", "budget_exhausted" });
    defer allocator.free(states);
    try w.writeAll(",\"semanticStates\":");
    try w.writeAll(states);

    const statuses = try renderJsonStringArray(allocator, &.{ "ok", "accepted", "partial", "unresolved", "failed", "rejected", "unsupported", "budget_exhausted" });
    defer allocator.free(statuses);
    try w.writeAll(",\"protocolStatuses\":");
    try w.writeAll(statuses);

    var unsupported_kinds_list = std.ArrayList([]const u8).init(allocator);
    defer unsupported_kinds_list.deinit();
    inline for (std.meta.fields(core.RequestKind)) |field| {
        const kind: core.RequestKind = @enumFromInt(field.value);
        if (!core.isImplemented(kind)) try unsupported_kinds_list.append(field.name);
    }
    const unsupported_kinds = try renderJsonStringArray(allocator, unsupported_kinds_list.items);
    defer allocator.free(unsupported_kinds);
    try w.writeAll(",\"unsupportedRequestKinds\":");
    try w.writeAll(unsupported_kinds);

    try w.writeAll(",\"operationMaturity\":[");
    inline for (std.meta.fields(core.RequestKind), 0..) |field, idx| {
        if (idx != 0) try w.writeByte(',');
        const kind: core.RequestKind = @enumFromInt(field.value);
        try writeOperationMaturity(w, core.operationMaturity(kind));
    }
    try w.writeAll("]");

    try w.writeAll("}");
    return out.toOwnedSlice();
}

pub fn renderCapabilitiesDescription(allocator: std.mem.Allocator) ![]u8 {
    const caps = core.defaultCapabilities();
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    try w.writeAll("{\"capabilities\":[");
    try w.writeAll("{\"capability\":\"protocol.describe\",\"policy\":\"allowed\"},");
    try w.writeAll("{\"capability\":\"capabilities.describe\",\"policy\":\"allowed\"},");
    try w.writeAll("{\"capability\":\"engine.status\",\"policy\":\"allowed\"}");
    for (caps) |cap| {
        try w.writeByte(',');
        try w.writeAll("{");
        try writeStr(w, "capability", cap.capability.asText(), true);
        try writeStr(w, "policy", cap.policy.name(), false);
        try writeCapabilityDetails(w, cap.capability, cap.policy);
        try w.writeAll("}");
    }
    try w.writeAll("],\"operationMaturity\":[");
    inline for (std.meta.fields(core.RequestKind), 0..) |field, idx| {
        if (idx != 0) try w.writeByte(',');
        const kind: core.RequestKind = @enumFromInt(field.value);
        try writeOperationMaturity(w, core.operationMaturity(kind));
    }
    try w.writeAll("]}");
    return out.toOwnedSlice();
}

fn writeOperationMaturity(w: anytype, maturity: core.OperationMaturity) !void {
    try w.writeAll("{");
    try writeStr(w, "kind", maturity.kind.name(), true);
    try writeBool(w, "declared", maturity.declared, false);
    try writeBool(w, "implemented", maturity.implemented, false);
    try writeBool(w, "wired", maturity.wired, false);
    try writeBool(w, "mutatesState", maturity.mutates_state, false);
    try writeBool(w, "requiresApproval", maturity.requires_approval, false);
    try writeStr(w, "capabilityPolicy", maturity.capability_policy.name(), false);
    try writeStr(w, "authorityEffect", maturity.authority_effect.name(), false);
    try writeBool(w, "productReady", maturity.product_ready, false);
    try writeStr(w, "maturity", maturity.maturity, false);
    try w.writeAll("}");
}

fn writeCapabilityDetails(w: anytype, capability: core.CapabilityName, policy: core.CapabilityPolicy) !void {
    switch (capability) {
        .@"verifier.run",
        .@"command.run",
        => try writeStr(w, "note", "not yet implemented", false),
        .@"correction.review",
        .@"procedure_pack.candidate.review",
        .@"negative_knowledge.review",
        => try writeBool(w, "append_only", true, false),
        .@"artifact.read",
        .@"artifact.list",
        .@"artifact.search",
        .@"artifact.patch.propose",
        .@"artifact.write.propose",
        .@"verifier.list",
        .@"verifier.candidate.execution.list",
        .@"verifier.candidate.execution.get",
        .@"hypothesis.list",
        .@"hypothesis.triage",
        .@"corpus.ask",
        .@"rule.evaluate",
        .@"sigil.inspect",
        .@"learning.status",
        .@"learning.loop.plan",
        .@"correction.propose",
        .@"correction.reviewed.list",
        .@"correction.reviewed.get",
        .@"correction.influence.status",
        .@"procedure_pack.candidate.propose",
        .@"procedure_pack.candidate.reviewed.list",
        .@"procedure_pack.candidate.reviewed.get",
        .@"correction.list",
        .@"correction.get",
        .@"negative_knowledge.candidate.list",
        .@"negative_knowledge.candidate.get",
        .@"negative_knowledge.record.list",
        .@"negative_knowledge.record.get",
        .@"negative_knowledge.influence.list",
        .@"negative_knowledge.reviewed.list",
        .@"negative_knowledge.reviewed.get",
        .@"trust_decay.candidate.list",
        .@"pack.list",
        .@"pack.inspect",
        .@"feedback.summary",
        .@"session.get",
        .@"project.autopsy",
        .@"context.autopsy",
        .@"artifact.policy.describe",
        => try writeBool(w, "read_only", true, false),
        else => {},
    }

    if (policy == .denied or policy == .requires_approval) {
        switch (capability) {
            .@"artifact.patch.apply",
            .@"artifact.write.apply",
            .@"verifier.candidate.execute",
            .@"correction.apply",
            .@"negative_knowledge.candidate.review",
            .@"negative_knowledge.record.expire",
            .@"negative_knowledge.record.supersede",
            .@"negative_knowledge.promote",
            .@"trust_decay.apply",
            .@"pack.mount",
            .@"pack.unmount",
            .@"pack.import",
            .@"pack.export",
            .@"pack.update_from_negative_knowledge",
            => try writeBool(w, "mutation", true, false),
            else => {},
        }
    }
}

pub fn renderEngineStatus(allocator: std.mem.Allocator) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    try w.writeAll("{");
    try writeStr(w, "engineVersion", core.ENGINE_VERSION, true);
    try writeStr(w, "gipVersion", core.PROTOCOL_VERSION, false);
    try writeStr(w, "platform", "linux", false);
    try writeStr(w, "status", "operational", false);
    try w.writeAll("}");
    return out.toOwnedSlice();
}

// ── Test ──────────────────────────────────────────────────────────────

test "renderResponse produces valid JSON envelope" {
    const allocator = std.testing.allocator;
    const response = try renderResponse(
        allocator,
        core.PROTOCOL_VERSION,
        "test-req-1",
        .@"protocol.describe",
        .ok,
        null,
        null,
        null,
        null,
    );
    defer allocator.free(response);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"gipVersion\":\"gip.v0.1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"status\":\"ok\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"requestId\":\"test-req-1\"") != null);
}

test "renderResponse with error includes error object" {
    const allocator = std.testing.allocator;
    const response = try renderResponse(
        allocator,
        core.PROTOCOL_VERSION,
        "test-req-2",
        .@"artifact.read",
        .rejected,
        null,
        null,
        .{
            .code = .path_outside_workspace,
            .message = "path traversal detected",
            .fix_hint = "use a path within the workspace root",
        },
        null,
    );
    defer allocator.free(response);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"code\":\"path_outside_workspace\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"fixHint\"") != null);
}

test "renderResponse with draft result state" {
    const allocator = std.testing.allocator;
    const rs = draftResultState();
    const response = try renderResponse(
        allocator,
        core.PROTOCOL_VERSION,
        "test-req-3",
        .@"conversation.turn",
        .ok,
        rs,
        null,
        null,
        null,
    );
    defer allocator.free(response);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"isDraft\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"permission\":\"none\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"nonAuthorizationNotice\"") != null);
}
