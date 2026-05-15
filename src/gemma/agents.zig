const std = @import("std");

pub const Intent = enum {
    query,
    etch,
    prove,
    converse,

    pub fn parse(raw: []const u8) ?Intent {
        if (std.mem.eql(u8, raw, "query")) return .query;
        if (std.mem.eql(u8, raw, "etch")) return .etch;
        if (std.mem.eql(u8, raw, "prove")) return .prove;
        if (std.mem.eql(u8, raw, "converse")) return .converse;
        return null;
    }
};

pub const Confidence = enum {
    low,
    medium,
    high,

    pub fn parse(raw: []const u8) ?Confidence {
        if (std.mem.eql(u8, raw, "low")) return .low;
        if (std.mem.eql(u8, raw, "medium")) return .medium;
        if (std.mem.eql(u8, raw, "high")) return .high;
        return null;
    }

    pub fn queryThreshold(self: Confidence) f32 {
        return switch (self) {
            .high => 0.75,
            .medium => 0.50,
            .low => 0.30,
        };
    }
};

pub const AgentStatus = enum {
    supported,
    unresolved,
    etched,
    converse,
};

pub const AgentInput = struct {
    intent: Intent,
    subject: []const u8,
    context_hints: []const []const u8 = &.{},
    confidence_required: Confidence = .high,
    needs_ghost: bool,
    original_message: []const u8 = "",
    source: []const u8 = "",
    explicit_store: bool = false,
    resonance: f32 = 0.0,
    decision_trace: bool = false,
    evidence_trace: bool = false,
};

pub const ResultPayload = struct {
    status: AgentStatus,
    subject: []const u8,
    confidence_required: Confidence,
    needs_ghost: bool,
    resonance: f32,
    proof_chain_present: bool,
    unresolved_reason: []const u8 = "",
    read_only: bool = true,
    matrix_mutation_allowed: bool = false,
};

pub fn route(input: AgentInput) ResultPayload {
    return switch (input.intent) {
        .query, .prove => runQueryAgent(input),
        .converse => runConversationAgent(input),
        .etch => runEtchAgent(input),
    };
}

pub fn runQueryAgent(input: AgentInput) ResultPayload {
    if (!input.needs_ghost) return unresolved(input, "query_requires_ghost");
    if (input.subject.len < 5) return unresolved(input, "subject_too_short");
    if (input.context_hints.len == 0 or input.context_hints.len > 5) return unresolved(input, "invalid_context_hint_count");
    if (input.resonance < input.confidence_required.queryThreshold()) return unresolved(input, "resonance_below_threshold");
    if (!input.decision_trace or !input.evidence_trace) return unresolved(input, "missing_required_traces");
    return .{
        .status = .supported,
        .subject = input.subject,
        .confidence_required = input.confidence_required,
        .needs_ghost = true,
        .resonance = input.resonance,
        .proof_chain_present = true,
        .read_only = true,
        .matrix_mutation_allowed = false,
    };
}

pub fn runConversationAgent(input: AgentInput) ResultPayload {
    if (input.needs_ghost) return unresolved(input, "conversation_must_not_require_ghost");
    if (input.intent != .converse) return unresolved(input, "invalid_conversation_intent");
    return .{
        .status = .converse,
        .subject = if (input.subject.len > 0) input.subject else input.original_message,
        .confidence_required = .low,
        .needs_ghost = false,
        .resonance = input.resonance,
        .proof_chain_present = false,
        .read_only = true,
        .matrix_mutation_allowed = false,
    };
}

pub fn runEtchAgent(input: AgentInput) ResultPayload {
    if (!input.needs_ghost) return unresolved(input, "etch_requires_ghost");
    if (!input.explicit_store or !std.mem.eql(u8, input.source, "user_explicit")) return unresolved(input, "etch_requires_explicit_user_source");
    if (input.subject.len < 10) return unresolved(input, "subject_too_short_for_etch");
    if (input.context_hints.len < 2) return unresolved(input, "etch_requires_two_context_hints");
    return .{
        .status = .etched,
        .subject = input.subject,
        .confidence_required = input.confidence_required,
        .needs_ghost = true,
        .resonance = input.resonance,
        .proof_chain_present = false,
        .read_only = false,
        .matrix_mutation_allowed = true,
    };
}

fn unresolved(input: AgentInput, reason: []const u8) ResultPayload {
    return .{
        .status = .unresolved,
        .subject = input.subject,
        .confidence_required = input.confidence_required,
        .needs_ghost = input.needs_ghost,
        .resonance = input.resonance,
        .proof_chain_present = input.decision_trace and input.evidence_trace,
        .unresolved_reason = reason,
        .read_only = true,
        .matrix_mutation_allowed = false,
    };
}

pub fn statusName(status: AgentStatus) []const u8 {
    return switch (status) {
        .supported => "supported",
        .unresolved => "unresolved",
        .etched => "etched",
        .converse => "converse",
    };
}

pub fn intentName(intent: Intent) []const u8 {
    return switch (intent) {
        .query => "query",
        .etch => "etch",
        .prove => "prove",
        .converse => "converse",
    };
}

pub fn confidenceName(confidence: Confidence) []const u8 {
    return switch (confidence) {
        .low => "low",
        .medium => "medium",
        .high => "high",
    };
}

test "query agent refuses support without both traces" {
    const hints = [_][]const u8{"memory"};
    const result = route(.{
        .intent = .query,
        .subject = "memory allocation",
        .context_hints = &hints,
        .confidence_required = .high,
        .needs_ghost = true,
        .resonance = 0.95,
        .decision_trace = true,
        .evidence_trace = false,
    });
    try std.testing.expectEqual(AgentStatus.unresolved, result.status);
    try std.testing.expectEqualStrings("missing_required_traces", result.unresolved_reason);
}

test "query agent supports only after resonance and proof gates pass" {
    const hints = [_][]const u8{"memory"};
    const result = route(.{
        .intent = .query,
        .subject = "memory allocation",
        .context_hints = &hints,
        .confidence_required = .high,
        .needs_ghost = true,
        .resonance = 0.95,
        .decision_trace = true,
        .evidence_trace = true,
    });
    try std.testing.expectEqual(AgentStatus.supported, result.status);
    try std.testing.expect(result.read_only);
    try std.testing.expect(!result.matrix_mutation_allowed);
}

test "etch agent requires explicit user source" {
    const hints = [_][]const u8{ "ghost", "memory" };
    const result = route(.{
        .intent = .etch,
        .subject = "store memory allocation policy",
        .context_hints = &hints,
        .needs_ghost = true,
        .source = "gemma_output",
        .explicit_store = true,
    });
    try std.testing.expectEqual(AgentStatus.unresolved, result.status);
}

test "conversation agent refuses ghost requirement" {
    const result = route(.{
        .intent = .converse,
        .subject = "hello",
        .needs_ghost = true,
    });
    try std.testing.expectEqual(AgentStatus.unresolved, result.status);
}
