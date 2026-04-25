// ──────────────────────────────────────────────────────────────────────────
// GIP — Ghost Interface Protocol v0.1
//
// Root module. Re-exports all GIP sub-modules.
//
// GIP is Ghost's native, explicit, deterministic interface protocol.
// It is designed so that ghost_cli, ghost_tui, GUI editors, and
// future MCP bridges can all consume GIP directly.
//
// GIP is NOT MCP. GIP is NOT a chat completion API.
// ──────────────────────────────────────────────────────────────────────────

pub const core = @import("gip_core.zig");
pub const schema = @import("gip_schema.zig");
pub const validation = @import("gip_validation.zig");
pub const dispatch = @import("gip_dispatch.zig");

// Re-export key types for convenience
pub const PROTOCOL_VERSION = core.PROTOCOL_VERSION;
pub const RequestKind = core.RequestKind;
pub const ProtocolStatus = core.ProtocolStatus;
pub const SemanticState = core.SemanticState;
pub const ReasoningLevel = core.ReasoningLevel;
pub const CapabilityPolicy = core.CapabilityPolicy;
pub const ErrorCode = core.ErrorCode;

pub const GipError = schema.GipError;
pub const ResultState = schema.ResultState;
pub const Stats = schema.Stats;

pub const renderResponse = schema.renderResponse;
pub const draftResultState = schema.draftResultState;
pub const unresolvedResultState = schema.unresolvedResultState;

// Force test inclusion
comptime {
    _ = core;
    _ = schema;
    _ = validation;
    _ = dispatch;
}
