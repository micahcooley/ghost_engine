const std = @import("std");
const vsa = @import("vsa_core.zig");
const ghost_state = @import("ghost_state.zig");

/// [ASPIRATIONAL] This interface is not yet used by any production code.
/// See AGENTS_SPEC.md for the intended architecture.
pub const AgentApi = struct {
    name: []const u8,
    
    /// The Sigil pattern that triggers this agent.
    trigger_sigil: u64,

    /// Called when the agent is spawned by a resonance trigger.
    ignition: *const fn (soul: *ghost_state.GhostSoul) anyerror!void,
    
    /// The primary cognitive loop for the agent.
    /// This is where 'The Oracle' would perform lookahead or 'The Scribe' would track syntax.
    resonate: *const fn (matrix: *vsa.MeaningMatrix, soul: *ghost_state.GhostSoul) anyerror!void,
    
    /// Called as the agent loses resonance (lattice decay).
    decay: *const fn () void,
};

pub const AgentPlugin = struct {
    name: []const u8,
    author: []const u8,
    
    /// Factory to create the agent instance
    spawn: *const fn (allocator: std.mem.Allocator) anyerror!*const AgentApi,
};
