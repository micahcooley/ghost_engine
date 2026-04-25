// ──────────────────────────────────────────────────────────────────────────
// GIP Core — Ghost Interface Protocol v0.1
//
// Ghost's native, explicit, deterministic interface protocol.
// GIP is NOT MCP. GIP is NOT an LLM tool-call wrapper.
// GIP is NOT a chat completion API.
//
// GIP represents Ghost's actual architecture:
//   artifacts, sessions, reasoning levels, response states,
//   draft/verified/unresolved semantics, hypotheses, obligations,
//   support graphs, verifier jobs, capabilities, knowledge packs,
//   feedback/reinforcement/distillation, budgets, provenance, stats.
// ──────────────────────────────────────────────────────────────────────────

const std = @import("std");

pub const PROTOCOL_VERSION = "gip.v0.1";
pub const ENGINE_VERSION = @import("build_options").ghost_version;

// ── Request Kind ──────────────────────────────────────────────────────

pub const RequestKind = enum {
    // Conversation / reasoning
    @"conversation.turn",
    @"conversation.replay",
    @"intent.ground",
    @"response.evaluate",

    // Artifacts
    @"artifact.list",
    @"artifact.read",
    @"artifact.search",
    @"artifact.patch.propose",
    @"artifact.patch.apply",
    @"artifact.write.propose",
    @"artifact.write.apply",

    // Verification
    @"verifier.list",
    @"verifier.run",
    @"hypothesis.verifier.schedule",

    // Hypotheses
    @"hypothesis.generate",
    @"hypothesis.triage",
    @"hypothesis.list",

    // Knowledge Packs
    @"pack.list",
    @"pack.inspect",
    @"pack.mount",
    @"pack.unmount",
    @"pack.import",
    @"pack.export",
    @"pack.distill.list",
    @"pack.distill.show",
    @"pack.distill.export",

    // Feedback
    @"feedback.record",
    @"feedback.replay",
    @"feedback.summary",

    // Session
    @"session.create",
    @"session.get",
    @"session.update",
    @"session.close",

    // Command
    @"command.run",

    // Status / meta
    @"engine.status",
    @"protocol.describe",
    @"capabilities.describe",

    pub fn name(self: RequestKind) []const u8 {
        return @tagName(self);
    }
};

pub fn parseRequestKind(text: []const u8) ?RequestKind {
    inline for (std.meta.fields(RequestKind)) |field| {
        if (std.mem.eql(u8, text, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

// ── Protocol Status ───────────────────────────────────────────────────

pub const ProtocolStatus = enum {
    ok,
    accepted,
    partial,
    unresolved,
    failed,
    rejected,
    unsupported,
    budget_exhausted,

    pub fn name(self: ProtocolStatus) []const u8 {
        return @tagName(self);
    }
};

// ── Semantic State ────────────────────────────────────────────────────

pub const SemanticState = enum {
    draft,
    verified,
    unresolved,
    failed,
    blocked,
    ambiguous,
    budget_exhausted,

    pub fn name(self: SemanticState) []const u8 {
        return @tagName(self);
    }
};

// ── Permission ────────────────────────────────────────────────────────

pub const Permission = enum {
    supported,
    unresolved,
    none,

    pub fn name(self: Permission) []const u8 {
        return @tagName(self);
    }
};

// ── Verification State ────────────────────────────────────────────────

pub const VerificationState = enum {
    unverified,
    partial,
    verified,
    not_applicable,

    pub fn name(self: VerificationState) []const u8 {
        return @tagName(self);
    }
};

// ── Stop Reason ───────────────────────────────────────────────────────

pub const StopReason = enum {
    none,
    unresolved,
    budget,
    failed,
    supported,
    blocked,

    pub fn name(self: StopReason) []const u8 {
        return @tagName(self);
    }
};

// ── Reasoning Level ───────────────────────────────────────────────────

pub const ReasoningLevel = enum {
    quick,
    balanced,
    deep,
    max,

    pub fn name(self: ReasoningLevel) []const u8 {
        return @tagName(self);
    }
};

pub fn parseReasoningLevel(text: []const u8) ?ReasoningLevel {
    inline for ([_]ReasoningLevel{ .quick, .balanced, .deep, .max }) |level| {
        if (std.mem.eql(u8, text, @tagName(level))) return level;
    }
    return null;
}

// ── Capability ────────────────────────────────────────────────────────

pub const CapabilityName = enum {
    @"artifact.read",
    @"artifact.list",
    @"artifact.search",
    @"artifact.patch.propose",
    @"artifact.patch.apply",
    @"artifact.write.propose",
    @"artifact.write.apply",
    @"command.run",
    @"command.run.allowlist",
    @"verifier.run",
    @"pack.inspect",
    @"pack.mount",
    @"pack.unmount",
    @"pack.import",
    @"pack.export",
    @"feedback.record",
    @"session.write",
    @"network.access",

    pub fn asText(self: CapabilityName) []const u8 {
        return @tagName(self);
    }
};

pub const CapabilityPolicy = enum {
    allowed,
    denied,
    requires_approval,
    allowlist,
    dry_run_only,

    pub fn name(self: CapabilityPolicy) []const u8 {
        return @tagName(self);
    }
};

pub const CapabilityEntry = struct {
    capability: CapabilityName,
    policy: CapabilityPolicy,
};

pub fn defaultCapabilities() [18]CapabilityEntry {
    return .{
        .{ .capability = .@"artifact.read", .policy = .allowed },
        .{ .capability = .@"artifact.list", .policy = .allowed },
        .{ .capability = .@"artifact.search", .policy = .allowed },
        .{ .capability = .@"artifact.patch.propose", .policy = .allowed },
        .{ .capability = .@"artifact.patch.apply", .policy = .requires_approval },
        .{ .capability = .@"artifact.write.propose", .policy = .allowed },
        .{ .capability = .@"artifact.write.apply", .policy = .requires_approval },
        .{ .capability = .@"command.run", .policy = .allowlist },
        .{ .capability = .@"command.run.allowlist", .policy = .allowlist },
        .{ .capability = .@"verifier.run", .policy = .allowed },
        .{ .capability = .@"pack.inspect", .policy = .allowed },
        .{ .capability = .@"pack.mount", .policy = .requires_approval },
        .{ .capability = .@"pack.unmount", .policy = .requires_approval },
        .{ .capability = .@"pack.import", .policy = .requires_approval },
        .{ .capability = .@"pack.export", .policy = .requires_approval },
        .{ .capability = .@"feedback.record", .policy = .allowed },
        .{ .capability = .@"session.write", .policy = .allowed },
        .{ .capability = .@"network.access", .policy = .denied },
    };
}

// ── Source Kind ────────────────────────────────────────────────────────

pub const SourceKind = enum {
    workspace_file,
    pack_file,
    web_artifact,
    generated,
    external,
    memory,

    pub fn name(self: SourceKind) []const u8 {
        return @tagName(self);
    }
};

// ── Artifact Entry Kind ───────────────────────────────────────────────

pub const ArtifactEntryKind = enum {
    file,
    directory,
    symlink,
    unknown,

    pub fn name(self: ArtifactEntryKind) []const u8 {
        return @tagName(self);
    }
};

// ── Sandbox Policy ────────────────────────────────────────────────────

pub const SandboxPolicy = enum {
    workspace_only,
    temp_only,
    read_only,
    allow_writes_to_workspace,

    pub fn name(self: SandboxPolicy) []const u8 {
        return @tagName(self);
    }
};

// ── Error Code ────────────────────────────────────────────────────────

pub const ErrorCode = enum {
    unsupported_gip_version,
    invalid_request,
    missing_required_field,
    invalid_reasoning_level,
    unsupported_operation,
    capability_denied,
    approval_required,
    path_outside_workspace,
    path_not_found,
    artifact_too_large,
    command_not_allowed,
    command_timeout,
    verifier_not_found,
    verifier_blocked,
    budget_exhausted,
    json_contract_error,
    internal_error,
    invalid_patch_span,
    patch_precondition_failed,

    pub fn name(self: ErrorCode) []const u8 {
        return @tagName(self);
    }
};

// ── Error Severity ────────────────────────────────────────────────────

pub const ErrorSeverity = enum {
    info,
    warning,
    @"error",
    fatal,

    pub fn name(self: ErrorSeverity) []const u8 {
        return @tagName(self);
    }
};

// ── Command Allowlist ─────────────────────────────────────────────────

pub const COMMAND_ALLOWLIST = [_][]const u8{
    "zig",
    "git",
    "ls",
    "find",
    "cat",
    "head",
    "tail",
    "wc",
    "grep",
    "diff",
    "echo",
    "test",
    "stat",
};

pub const MAX_COMMAND_TIMEOUT_MS: u32 = 30_000;
pub const DEFAULT_COMMAND_TIMEOUT_MS: u32 = 10_000;
pub const MAX_COMMAND_OUTPUT_BYTES: usize = 256 * 1024;
pub const MAX_ARTIFACT_READ_BYTES: usize = 1024 * 1024;
pub const MAX_LIST_ENTRIES: usize = 512;
pub const MAX_SEARCH_RESULTS: usize = 64;

pub fn isCommandAllowed(argv0: []const u8) bool {
    // Extract basename from potential path
    const basename = std.fs.path.basename(argv0);
    for (COMMAND_ALLOWLIST) |allowed| {
        if (std.mem.eql(u8, basename, allowed)) return true;
    }
    return false;
}

// ── Supported Request Kinds ───────────────────────────────────────────

/// Request kinds that have working dispatch handlers in v0.1.
/// Kinds NOT in this list return structured "unsupported" responses.
/// Do not add a kind here until its dispatch handler exists.
pub const IMPLEMENTED_KINDS = [_]RequestKind{
    .@"protocol.describe",
    .@"capabilities.describe",
    .@"engine.status",
    .@"conversation.turn",
    .@"artifact.read",
    .@"artifact.list",
    .@"artifact.patch.propose",
};

pub fn isImplemented(kind: RequestKind) bool {
    for (IMPLEMENTED_KINDS) |k| {
        if (k == kind) return true;
    }
    return false;
}

// ── Tests ─────────────────────────────────────────────────────────────

test "protocol version is gip.v0.1" {
    try std.testing.expectEqualStrings("gip.v0.1", PROTOCOL_VERSION);
}

test "parseRequestKind recognizes all valid kinds" {
    try std.testing.expect(parseRequestKind("protocol.describe") != null);
    try std.testing.expect(parseRequestKind("conversation.turn") != null);
    try std.testing.expect(parseRequestKind("artifact.read") != null);
    try std.testing.expect(parseRequestKind("unknown.kind") == null);
}

test "parseReasoningLevel recognizes valid levels" {
    try std.testing.expect(parseReasoningLevel("quick") == .quick);
    try std.testing.expect(parseReasoningLevel("balanced") == .balanced);
    try std.testing.expect(parseReasoningLevel("deep") == .deep);
    try std.testing.expect(parseReasoningLevel("max") == .max);
    try std.testing.expect(parseReasoningLevel("extreme") == null);
}

test "default capabilities have safe defaults" {
    const caps = defaultCapabilities();
    // artifact.read should be allowed
    try std.testing.expectEqual(CapabilityPolicy.allowed, caps[0].policy);
    // artifact.patch.apply should require approval
    try std.testing.expectEqual(CapabilityPolicy.requires_approval, caps[4].policy);
    // command.run should be allowlisted
    try std.testing.expectEqual(CapabilityPolicy.allowlist, caps[7].policy);
    // network.access should be denied
    try std.testing.expectEqual(CapabilityPolicy.denied, caps[17].policy);
}

test "command allowlist rejects arbitrary commands" {
    try std.testing.expect(isCommandAllowed("zig"));
    try std.testing.expect(isCommandAllowed("git"));
    try std.testing.expect(!isCommandAllowed("sudo"));
    try std.testing.expect(!isCommandAllowed("rm"));
    try std.testing.expect(!isCommandAllowed("curl"));
    try std.testing.expect(!isCommandAllowed("bash"));
    try std.testing.expect(!isCommandAllowed("sh"));
}
