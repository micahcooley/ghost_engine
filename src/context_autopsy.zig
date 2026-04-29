const std = @import("std");

pub const ContextCase = struct {
    description: []const u8,
    intake_data: std.json.Value, // Raw situational data
    intake_type: []const u8, // e.g., "workspace", "chat", "document"
};

pub const ContextSignal = struct {
    name: []const u8,
    source_pack: []const u8,
    kind: []const u8, // e.g., "domain_marker", "ingredient", "tech_stack"
    confidence: []const u8,
    reason: []const u8,
};
pub const PackAutopsySignal = ContextSignal;

pub const ContextUnknown = struct {
    name: []const u8,
    source_pack: []const u8,
    importance: []const u8, // high, medium, low
    reason: []const u8,
    is_missing_evidence: bool = true,
    is_negative_evidence: bool = false, // Invariant: no evidence is not negative evidence
};

pub const ContextConstraint = struct {
    name: []const u8,
    source_pack: []const u8,
    reason: []const u8,
};

pub const ContextRiskSurface = struct {
    risk_kind: []const u8,
    source_pack: []const u8,
    reason: []const u8,
    suggested_caution: []const u8,
    non_authorizing: bool = true,
};

pub const ContextCandidateAction = struct {
    id: []const u8,
    source_pack: []const u8,
    action_type: []const u8, // e.g., "command", "communication", "physical_action"
    payload: std.json.Value, // action-specific details
    reason: []const u8,
    risk_level: []const u8,
    requires_user_confirmation: bool = true,
    non_authorizing: bool = true,
};

pub const ContextCheckCandidate = struct {
    id: []const u8,
    source_pack: []const u8,
    check_type: []const u8, // e.g., "hard_verifier", "soft_real_world_check"
    purpose: []const u8,
    risk_level: []const u8,
    confidence: []const u8,
    evidence_strength: []const u8, // e.g., "absolute", "heuristic", "subjective"
    requires_user_confirmation: bool = true,
    non_authorizing: bool = true,
    executes_by_default: bool = false,
    why_candidate_exists: []const u8,
};

pub const EvidenceExpectation = struct {
    expected_signal: []const u8,
    source_pack: []const u8,
    reason: []const u8,
};

pub const PackInfluence = struct {
    pack_name: []const u8,
    weight: []const u8,
    is_proof_authority: bool = false,
};

pub const ContextAutopsyResult = struct {
    context_case: ContextCase,
    detected_signals: []ContextSignal = &.{},
    suggested_unknowns: []ContextUnknown = &.{},
    risk_surfaces: []ContextRiskSurface = &.{},
    candidate_actions: []ContextCandidateAction = &.{},
    check_candidates: []ContextCheckCandidate = &.{},
    constraints: []ContextConstraint = &.{},
    evidence_expectations: []EvidenceExpectation = &.{},
    pack_influences: []PackInfluence = &.{},
    state: []const u8 = "draft",
    non_authorizing: bool = true,
};

test "candidate actions default non_authorizing=true" {
    const action = ContextCandidateAction{
        .id = "test_action",
        .source_pack = "test_pack",
        .action_type = "test",
        .payload = .null,
        .reason = "testing",
        .risk_level = "low",
    };
    try std.testing.expectEqual(true, action.non_authorizing);
}

test "check candidates default executes_by_default=false" {
    const candidate = ContextCheckCandidate{
        .id = "test_check",
        .source_pack = "test_pack",
        .check_type = "hard_verifier",
        .purpose = "testing",
        .risk_level = "low",
        .confidence = "high",
        .evidence_strength = "absolute",
        .why_candidate_exists = "testing",
    };
    try std.testing.expectEqual(false, candidate.executes_by_default);
}

test "pack influence cannot be marked proof/authority by default" {
    const influence = PackInfluence{
        .pack_name = "test_pack",
        .weight = "high",
    };
    try std.testing.expectEqual(false, influence.is_proof_authority);
}

test "unknown records represent missing/unknown, not false" {
    const unknown = ContextUnknown{
        .name = "test_unknown",
        .source_pack = "test_pack",
        .importance = "high",
        .reason = "testing",
    };
    try std.testing.expectEqual(true, unknown.is_missing_evidence);
    try std.testing.expectEqual(false, unknown.is_negative_evidence);
}

test "soft vs hard check kinds are distinguishable" {
    const hard_check = ContextCheckCandidate{
        .id = "hard_check",
        .source_pack = "test_pack",
        .check_type = "hard_verifier",
        .purpose = "testing",
        .risk_level = "low",
        .confidence = "high",
        .evidence_strength = "absolute",
        .why_candidate_exists = "testing",
    };
    const soft_check = ContextCheckCandidate{
        .id = "soft_check",
        .source_pack = "test_pack",
        .check_type = "soft_real_world_check",
        .purpose = "testing",
        .risk_level = "low",
        .confidence = "low",
        .evidence_strength = "subjective",
        .why_candidate_exists = "testing",
    };
    try std.testing.expect(!std.mem.eql(u8, hard_check.check_type, soft_check.check_type));
}
