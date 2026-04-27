// ──────────────────────────────────────────────────────────────────────────
// GIP Validation — Request validation for safety and correctness
//
// Validates:
//   - protocol version
//   - required fields
//   - path containment (workspace boundary)
//   - command allowlist
//   - reasoning level
//   - budget limits
//   - capability gates
// ──────────────────────────────────────────────────────────────────────────

const std = @import("std");
const core = @import("gip_core.zig");
const schema = @import("gip_schema.zig");

pub const ValidationResult = struct {
    valid: bool,
    errors: []const schema.GipError,

    pub fn ok() ValidationResult {
        return .{ .valid = true, .errors = &.{} };
    }

    pub fn single(err: schema.GipError) ValidationResult {
        return .{ .valid = false, .errors = &.{err} };
    }
};

pub fn validateVersion(version: ?[]const u8) ?schema.GipError {
    const v = version orelse return .{
        .code = .missing_required_field,
        .message = "missing 'gipVersion' field",
        .fix_hint = "set gipVersion to \"gip.v0.1\"",
    };
    if (!std.mem.eql(u8, v, core.PROTOCOL_VERSION)) return .{
        .code = .unsupported_gip_version,
        .message = "unsupported GIP version",
        .details = v,
        .fix_hint = "use \"gip.v0.1\"",
    };
    return null;
}

pub fn validateRequestKind(kind_text: ?[]const u8) ?schema.GipError {
    const text = kind_text orelse return .{
        .code = .missing_required_field,
        .message = "missing 'kind' field",
        .fix_hint = "use protocol.describe to list supported kinds",
    };
    if (core.parseRequestKind(text) == null) return .{
        .code = .unsupported_operation,
        .message = "unknown request kind",
        .details = text,
        .fix_hint = "use protocol.describe to list supported kinds",
    };
    return null;
}

pub fn validateImplemented(kind: core.RequestKind) ?schema.GipError {
    if (!core.isImplemented(kind)) return .{
        .code = .unsupported_operation,
        .message = "request kind not implemented in this version",
        .details = kind.name(),
        .fix_hint = "use protocol.describe to see implemented kinds",
    };
    return null;
}

pub fn validateReasoningLevel(level: ?[]const u8) ?schema.GipError {
    if (level) |l| {
        if (core.parseReasoningLevel(l) == null) return .{
            .code = .invalid_reasoning_level,
            .message = "unknown reasoning level",
            .details = l,
            .fix_hint = "use one of: quick, balanced, deep, max",
        };
    }
    return null;
}

pub fn validatePathContainment(workspace_root: []const u8, path: []const u8) ?schema.GipError {
    if (path.len == 0) return .{
        .code = .missing_required_field,
        .message = "empty path",
        .fix_hint = "provide a non-empty path",
    };

    // Reject obvious traversal attempts
    if (std.mem.indexOf(u8, path, "..") != null) return .{
        .code = .path_outside_workspace,
        .message = "path contains '..' traversal",
        .details = path,
        .fix_hint = "use a path within the workspace root",
    };

    // If absolute, check prefix
    if (std.fs.path.isAbsolute(path)) {
        if (!std.mem.startsWith(u8, path, workspace_root)) return .{
            .code = .path_outside_workspace,
            .message = "absolute path is outside workspace root",
            .details = path,
            .fix_hint = "use a path relative to the workspace root or an absolute path within it",
        };
    }

    return null;
}

pub fn validateCommandAllowed(argv0: ?[]const u8) ?schema.GipError {
    const cmd = argv0 orelse return .{
        .code = .missing_required_field,
        .message = "missing command (argv[0])",
        .fix_hint = "provide at least one argument",
    };
    if (!core.isCommandAllowed(cmd)) return .{
        .code = .command_not_allowed,
        .message = "command is not on the allowlist",
        .details = cmd,
        .fix_hint = "allowed commands: zig, git, ls, find, cat, head, tail, wc, grep, diff, echo, test, stat",
    };
    return null;
}

pub fn validateCommandTimeout(timeout_ms: ?u32) ?schema.GipError {
    if (timeout_ms) |t| {
        if (t > core.MAX_COMMAND_TIMEOUT_MS) return .{
            .code = .invalid_request,
            .message = "command timeout exceeds maximum",
            .fix_hint = "maximum timeout is 30000ms",
        };
    }
    return null;
}

// ── Capability Gate ───────────────────────────────────────────────────

pub fn checkCapability(kind: core.RequestKind) struct { cap: ?core.CapabilityName, policy: core.CapabilityPolicy } {
    const caps = core.defaultCapabilities();
    const cap_name: ?core.CapabilityName = switch (kind) {
        .@"artifact.read" => .@"artifact.read",
        .@"artifact.list" => .@"artifact.list",
        .@"artifact.search" => .@"artifact.search",
        .@"artifact.patch.propose" => .@"artifact.patch.propose",
        .@"artifact.patch.apply" => .@"artifact.patch.apply",
        .@"artifact.write.propose" => .@"artifact.write.propose",
        .@"artifact.write.apply" => .@"artifact.write.apply",
        .@"command.run" => .@"command.run",
        .@"verifier.run" => .@"verifier.run",
        .@"verifier.list" => .@"verifier.list",
        .@"verifier.candidate.execution.list" => .@"verifier.candidate.execution.list",
        .@"verifier.candidate.execution.get" => .@"verifier.candidate.execution.get",
        .@"verifier.candidate.execute" => .@"verifier.candidate.execute",
        .@"hypothesis.list" => .@"hypothesis.list",
        .@"hypothesis.triage" => .@"hypothesis.triage",
        .@"correction.list" => .@"correction.list",
        .@"correction.get" => .@"correction.get",
        .@"correction.apply" => .@"correction.apply",
        .@"negative_knowledge.candidate.list" => .@"negative_knowledge.candidate.list",
        .@"negative_knowledge.candidate.get" => .@"negative_knowledge.candidate.get",
        .@"negative_knowledge.record.list" => .@"negative_knowledge.record.list",
        .@"negative_knowledge.record.get" => .@"negative_knowledge.record.get",
        .@"negative_knowledge.influence.list" => .@"negative_knowledge.influence.list",
        .@"negative_knowledge.candidate.review" => .@"negative_knowledge.candidate.review",
        .@"negative_knowledge.record.expire" => .@"negative_knowledge.record.expire",
        .@"negative_knowledge.record.supersede" => .@"negative_knowledge.record.supersede",
        .@"negative_knowledge.promote" => .@"negative_knowledge.promote",
        .@"trust_decay.candidate.list" => .@"trust_decay.candidate.list",
        .@"trust_decay.apply" => .@"trust_decay.apply",
        .@"pack.inspect" => .@"pack.inspect",
        .@"pack.list" => .@"pack.list",
        .@"pack.mount" => .@"pack.mount",
        .@"pack.unmount" => .@"pack.unmount",
        .@"pack.import" => .@"pack.import",
        .@"pack.export" => .@"pack.export",
        .@"pack.update_from_negative_knowledge" => .@"pack.update_from_negative_knowledge",
        .@"feedback.summary" => .@"feedback.summary",
        .@"feedback.record" => .@"feedback.record",
        .@"session.get" => .@"session.get",
        .@"session.create", .@"session.update", .@"session.close" => .@"session.write",
        else => null,
    };

    if (cap_name) |cn| {
        for (caps) |cap| {
            if (cap.capability == cn) return .{ .cap = cn, .policy = cap.policy };
        }
    }
    return .{ .cap = cap_name, .policy = .allowed };
}

pub fn validateCapability(kind: core.RequestKind) ?schema.GipError {
    const check = checkCapability(kind);
    return switch (check.policy) {
        .denied => .{
            .code = .capability_denied,
            .message = "this operation is denied by capability policy",
            .details = if (check.cap) |c| c.asText() else kind.name(),
        },
        .requires_approval => .{
            .code = .approval_required,
            .message = "this operation requires user approval",
            .details = if (check.cap) |c| c.asText() else kind.name(),
            .fix_hint = "set approved=true in the request to confirm",
            .severity = .warning,
        },
        else => null,
    };
}

// ── Tests ─────────────────────────────────────────────────────────────

test "validateVersion rejects wrong version" {
    try std.testing.expect(validateVersion(null) != null);
    try std.testing.expect(validateVersion("mcp.v1") != null);
    try std.testing.expect(validateVersion(core.PROTOCOL_VERSION) == null);
}

test "validatePathContainment rejects traversal" {
    try std.testing.expect(validatePathContainment("/workspace", "../etc/passwd") != null);
    try std.testing.expect(validatePathContainment("/workspace", "/etc/passwd") != null);
    try std.testing.expect(validatePathContainment("/workspace", "") != null);
    try std.testing.expect(validatePathContainment("/workspace", "src/main.zig") == null);
    try std.testing.expect(validatePathContainment("/workspace", "/workspace/src/main.zig") == null);
}

test "validateCommandAllowed rejects dangerous commands" {
    try std.testing.expect(validateCommandAllowed(null) != null);
    try std.testing.expect(validateCommandAllowed("rm") != null);
    try std.testing.expect(validateCommandAllowed("sudo") != null);
    try std.testing.expect(validateCommandAllowed("bash") != null);
    try std.testing.expect(validateCommandAllowed("curl") != null);
    try std.testing.expect(validateCommandAllowed("zig") == null);
    try std.testing.expect(validateCommandAllowed("git") == null);
}

test "checkCapability returns correct policies" {
    const read = checkCapability(.@"artifact.read");
    try std.testing.expectEqual(core.CapabilityPolicy.allowed, read.policy);

    const apply = checkCapability(.@"artifact.patch.apply");
    try std.testing.expectEqual(core.CapabilityPolicy.requires_approval, apply.policy);

    const cmd = checkCapability(.@"command.run");
    try std.testing.expectEqual(core.CapabilityPolicy.allowlist, cmd.policy);
}

test "validateCapability blocks denied operations" {
    // network.access is always denied but that's not a request kind.
    // artifact.patch.apply requires approval (warning, not blocking).
    const apply_err = validateCapability(.@"artifact.patch.apply");
    try std.testing.expect(apply_err != null);
    try std.testing.expectEqual(core.ErrorCode.approval_required, apply_err.?.code);

    // artifact.read should pass
    try std.testing.expect(validateCapability(.@"artifact.read") == null);
}
