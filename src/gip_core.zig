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
    @"corpus.ask",
    @"rule.evaluate",
    @"sigil.inspect",
    @"learning.status",
    @"learning.loop.plan",
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
    @"verifier.candidate.execution.list",
    @"verifier.candidate.execution.get",
    @"verifier.candidate.propose_from_learning_plan",
    @"verifier.candidate.list",
    @"verifier.candidate.review",
    @"verifier.run",
    @"verifier.candidate.execute",
    @"hypothesis.verifier.schedule",

    // Correction / negative knowledge inspection
    @"correction.propose",
    @"correction.review",
    @"correction.reviewed.list",
    @"correction.reviewed.get",
    @"correction.influence.status",
    @"correction.list",
    @"correction.get",
    @"correction.apply",
    @"procedure_pack.candidate.propose",
    @"procedure_pack.candidate.review",
    @"procedure_pack.candidate.reviewed.list",
    @"procedure_pack.candidate.reviewed.get",
    @"negative_knowledge.candidate.list",
    @"negative_knowledge.candidate.get",
    @"negative_knowledge.record.list",
    @"negative_knowledge.record.get",
    @"negative_knowledge.influence.list",
    @"negative_knowledge.review",
    @"negative_knowledge.reviewed.list",
    @"negative_knowledge.reviewed.get",
    @"negative_knowledge.candidate.review",
    @"negative_knowledge.record.expire",
    @"negative_knowledge.record.supersede",
    @"negative_knowledge.promote",
    @"trust_decay.candidate.list",
    @"trust_decay.apply",

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
    @"pack.update_from_negative_knowledge",

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

    // Project inspection
    @"project.autopsy",
    @"context.autopsy",

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
    @"verifier.candidate.execution.list",
    @"verifier.candidate.execution.get",
    @"verifier.candidate.propose_from_learning_plan",
    @"verifier.candidate.list",
    @"verifier.candidate.review",
    @"verifier.candidate.execute",
    @"hypothesis.list",
    @"hypothesis.triage",
    @"verifier.list",
    @"correction.propose",
    @"correction.review",
    @"correction.reviewed.list",
    @"correction.reviewed.get",
    @"correction.influence.status",
    @"learning.status",
    @"learning.loop.plan",
    @"correction.list",
    @"correction.get",
    @"correction.apply",
    @"procedure_pack.candidate.propose",
    @"procedure_pack.candidate.review",
    @"procedure_pack.candidate.reviewed.list",
    @"procedure_pack.candidate.reviewed.get",
    @"negative_knowledge.candidate.list",
    @"negative_knowledge.candidate.get",
    @"negative_knowledge.record.list",
    @"negative_knowledge.record.get",
    @"negative_knowledge.influence.list",
    @"negative_knowledge.review",
    @"negative_knowledge.reviewed.list",
    @"negative_knowledge.reviewed.get",
    @"negative_knowledge.candidate.review",
    @"negative_knowledge.record.expire",
    @"negative_knowledge.record.supersede",
    @"negative_knowledge.promote",
    @"trust_decay.candidate.list",
    @"trust_decay.apply",
    @"pack.list",
    @"pack.inspect",
    @"pack.mount",
    @"pack.unmount",
    @"pack.import",
    @"pack.export",
    @"pack.update_from_negative_knowledge",
    @"feedback.summary",
    @"session.get",
    @"feedback.record",
    @"session.write",
    @"network.access",
    @"corpus.ask",
    @"rule.evaluate",
    @"sigil.inspect",
    @"project.autopsy",
    @"context.autopsy",

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

pub fn defaultCapabilities() [64]CapabilityEntry {
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
        .{ .capability = .@"verifier.candidate.execution.list", .policy = .allowed },
        .{ .capability = .@"verifier.candidate.execution.get", .policy = .allowed },
        .{ .capability = .@"verifier.candidate.propose_from_learning_plan", .policy = .allowed },
        .{ .capability = .@"verifier.candidate.list", .policy = .allowed },
        .{ .capability = .@"verifier.candidate.review", .policy = .allowed },
        .{ .capability = .@"verifier.candidate.execute", .policy = .denied },
        .{ .capability = .@"hypothesis.list", .policy = .allowed },
        .{ .capability = .@"hypothesis.triage", .policy = .allowed },
        .{ .capability = .@"verifier.list", .policy = .allowed },
        .{ .capability = .@"correction.propose", .policy = .allowed },
        .{ .capability = .@"correction.review", .policy = .allowed },
        .{ .capability = .@"correction.reviewed.list", .policy = .allowed },
        .{ .capability = .@"correction.reviewed.get", .policy = .allowed },
        .{ .capability = .@"correction.influence.status", .policy = .allowed },
        .{ .capability = .@"learning.status", .policy = .allowed },
        .{ .capability = .@"learning.loop.plan", .policy = .allowed },
        .{ .capability = .@"correction.list", .policy = .allowed },
        .{ .capability = .@"correction.get", .policy = .allowed },
        .{ .capability = .@"correction.apply", .policy = .denied },
        .{ .capability = .@"procedure_pack.candidate.propose", .policy = .allowed },
        .{ .capability = .@"procedure_pack.candidate.review", .policy = .allowed },
        .{ .capability = .@"procedure_pack.candidate.reviewed.list", .policy = .allowed },
        .{ .capability = .@"procedure_pack.candidate.reviewed.get", .policy = .allowed },
        .{ .capability = .@"negative_knowledge.candidate.list", .policy = .allowed },
        .{ .capability = .@"negative_knowledge.candidate.get", .policy = .allowed },
        .{ .capability = .@"negative_knowledge.record.list", .policy = .allowed },
        .{ .capability = .@"negative_knowledge.record.get", .policy = .allowed },
        .{ .capability = .@"negative_knowledge.influence.list", .policy = .allowed },
        .{ .capability = .@"negative_knowledge.review", .policy = .allowed },
        .{ .capability = .@"negative_knowledge.reviewed.list", .policy = .allowed },
        .{ .capability = .@"negative_knowledge.reviewed.get", .policy = .allowed },
        .{ .capability = .@"negative_knowledge.candidate.review", .policy = .requires_approval },
        .{ .capability = .@"negative_knowledge.record.expire", .policy = .requires_approval },
        .{ .capability = .@"negative_knowledge.record.supersede", .policy = .requires_approval },
        .{ .capability = .@"negative_knowledge.promote", .policy = .denied },
        .{ .capability = .@"trust_decay.candidate.list", .policy = .allowed },
        .{ .capability = .@"trust_decay.apply", .policy = .denied },
        .{ .capability = .@"pack.list", .policy = .allowed },
        .{ .capability = .@"pack.inspect", .policy = .allowed },
        .{ .capability = .@"pack.mount", .policy = .requires_approval },
        .{ .capability = .@"pack.unmount", .policy = .requires_approval },
        .{ .capability = .@"pack.import", .policy = .requires_approval },
        .{ .capability = .@"pack.export", .policy = .requires_approval },
        .{ .capability = .@"pack.update_from_negative_knowledge", .policy = .denied },
        .{ .capability = .@"feedback.summary", .policy = .allowed },
        .{ .capability = .@"session.get", .policy = .allowed },
        .{ .capability = .@"feedback.record", .policy = .allowed },
        .{ .capability = .@"session.write", .policy = .allowed },
        .{ .capability = .@"network.access", .policy = .denied },
        .{ .capability = .@"corpus.ask", .policy = .allowed },
        .{ .capability = .@"rule.evaluate", .policy = .allowed },
        .{ .capability = .@"sigil.inspect", .policy = .allowed },
        .{ .capability = .@"project.autopsy", .policy = .allowed },
        .{ .capability = .@"context.autopsy", .policy = .allowed },
    };
}

pub fn requestCapabilityName(kind: RequestKind) ?CapabilityName {
    return switch (kind) {
        .@"artifact.read" => .@"artifact.read",
        .@"artifact.list" => .@"artifact.list",
        .@"artifact.search" => .@"artifact.search",
        .@"corpus.ask" => .@"corpus.ask",
        .@"rule.evaluate" => .@"rule.evaluate",
        .@"sigil.inspect" => .@"sigil.inspect",
        .@"learning.status" => .@"learning.status",
        .@"learning.loop.plan" => .@"learning.loop.plan",
        .@"artifact.patch.propose" => .@"artifact.patch.propose",
        .@"artifact.patch.apply" => .@"artifact.patch.apply",
        .@"artifact.write.propose" => .@"artifact.write.propose",
        .@"artifact.write.apply" => .@"artifact.write.apply",
        .@"command.run" => .@"command.run",
        .@"verifier.run" => .@"verifier.run",
        .@"verifier.list" => .@"verifier.list",
        .@"verifier.candidate.execution.list" => .@"verifier.candidate.execution.list",
        .@"verifier.candidate.execution.get" => .@"verifier.candidate.execution.get",
        .@"verifier.candidate.propose_from_learning_plan" => .@"verifier.candidate.propose_from_learning_plan",
        .@"verifier.candidate.list" => .@"verifier.candidate.list",
        .@"verifier.candidate.review" => .@"verifier.candidate.review",
        .@"verifier.candidate.execute" => .@"verifier.candidate.execute",
        .@"hypothesis.list" => .@"hypothesis.list",
        .@"hypothesis.triage" => .@"hypothesis.triage",
        .@"correction.propose" => .@"correction.propose",
        .@"correction.review" => .@"correction.review",
        .@"correction.reviewed.list" => .@"correction.reviewed.list",
        .@"correction.reviewed.get" => .@"correction.reviewed.get",
        .@"correction.influence.status" => .@"correction.influence.status",
        .@"procedure_pack.candidate.propose" => .@"procedure_pack.candidate.propose",
        .@"procedure_pack.candidate.review" => .@"procedure_pack.candidate.review",
        .@"procedure_pack.candidate.reviewed.list" => .@"procedure_pack.candidate.reviewed.list",
        .@"procedure_pack.candidate.reviewed.get" => .@"procedure_pack.candidate.reviewed.get",
        .@"correction.list" => .@"correction.list",
        .@"correction.get" => .@"correction.get",
        .@"correction.apply" => .@"correction.apply",
        .@"negative_knowledge.candidate.list" => .@"negative_knowledge.candidate.list",
        .@"negative_knowledge.candidate.get" => .@"negative_knowledge.candidate.get",
        .@"negative_knowledge.record.list" => .@"negative_knowledge.record.list",
        .@"negative_knowledge.record.get" => .@"negative_knowledge.record.get",
        .@"negative_knowledge.influence.list" => .@"negative_knowledge.influence.list",
        .@"negative_knowledge.review" => .@"negative_knowledge.review",
        .@"negative_knowledge.reviewed.list" => .@"negative_knowledge.reviewed.list",
        .@"negative_knowledge.reviewed.get" => .@"negative_knowledge.reviewed.get",
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
        .@"project.autopsy" => .@"project.autopsy",
        .@"context.autopsy" => .@"context.autopsy",
        else => null,
    };
}

pub fn capabilityPolicyForRequestKind(kind: RequestKind) CapabilityPolicy {
    const cap_name = requestCapabilityName(kind) orelse return .allowed;
    const caps = defaultCapabilities();
    for (caps) |cap| {
        if (cap.capability == cap_name) return cap.policy;
    }
    return .allowed;
}

pub const AuthorityEffect = enum {
    none,
    candidate,
    evidence,
    support,

    pub fn name(self: AuthorityEffect) []const u8 {
        return @tagName(self);
    }
};

pub const OperationMaturity = struct {
    kind: RequestKind,
    declared: bool,
    implemented: bool,
    wired: bool,
    mutates_state: bool,
    requires_approval: bool,
    capability_policy: CapabilityPolicy,
    authority_effect: AuthorityEffect,
    product_ready: bool,
    maturity: []const u8,
};

pub fn operationMaturity(kind: RequestKind) OperationMaturity {
    const policy = capabilityPolicyForRequestKind(kind);
    return .{
        .kind = kind,
        .declared = true,
        .implemented = isImplemented(kind),
        .wired = isImplemented(kind),
        .mutates_state = operationMutatesState(kind),
        .requires_approval = policy == .requires_approval,
        .capability_policy = policy,
        .authority_effect = operationAuthorityEffect(kind),
        .product_ready = false,
        .maturity = operationMaturityLabel(kind),
    };
}

pub fn operationMutatesState(kind: RequestKind) bool {
    return switch (kind) {
        .@"artifact.patch.apply",
        .@"artifact.write.apply",
        .@"verifier.run",
        .@"verifier.candidate.execute",
        .@"verifier.candidate.propose_from_learning_plan",
        .@"verifier.candidate.review",
        .@"correction.review",
        .@"correction.apply",
        .@"procedure_pack.candidate.review",
        .@"negative_knowledge.review",
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
        .@"feedback.record",
        .@"feedback.replay",
        .@"session.create",
        .@"session.update",
        .@"session.close",
        .@"command.run",
        => true,
        else => false,
    };
}

pub fn operationAuthorityEffect(kind: RequestKind) AuthorityEffect {
    return switch (kind) {
        .@"artifact.read",
        .@"corpus.ask",
        .@"verifier.candidate.execution.list",
        .@"verifier.candidate.execution.get",
        => .evidence,
        .@"conversation.turn",
        .@"rule.evaluate",
        .@"sigil.inspect",
        .@"artifact.patch.propose",
        .@"artifact.write.propose",
        .@"hypothesis.generate",
        .@"hypothesis.triage",
        .@"hypothesis.list",
        .@"hypothesis.verifier.schedule",
        .@"verifier.candidate.propose_from_learning_plan",
        .@"verifier.candidate.list",
        .@"verifier.candidate.review",
        .@"correction.propose",
        .@"correction.review",
        .@"correction.influence.status",
        .@"procedure_pack.candidate.propose",
        .@"procedure_pack.candidate.review",
        .@"negative_knowledge.candidate.list",
        .@"negative_knowledge.candidate.get",
        .@"negative_knowledge.influence.list",
        .@"negative_knowledge.review",
        .@"negative_knowledge.candidate.review",
        .@"trust_decay.candidate.list",
        .@"project.autopsy",
        .@"context.autopsy",
        .@"learning.loop.plan",
        => .candidate,
        else => .none,
    };
}

pub fn operationMaturityLabel(kind: RequestKind) []const u8 {
    if (!isImplemented(kind)) return "declared_not_implemented";
    return switch (kind) {
        .@"protocol.describe" => "metadata_declared",
        .@"capabilities.describe" => "metadata_declared",
        .@"engine.status" => "status_probe",
        .@"conversation.turn" => "wired_draft_or_verified_response_state",
        .@"corpus.ask" => "read_only_live_corpus_grounded_draft",
        .@"rule.evaluate" => "bounded_deterministic_non_authorizing_candidates",
        .@"sigil.inspect" => "read_only_sigil_bytecode_inspection_non_authorizing",
        .@"learning.status" => "read_only_reviewed_learning_loop_scoreboard_non_authorizing",
        .@"learning.loop.plan" => "candidate_only_project_autopsy_learning_loop_plan_no_execution_no_mutation",
        .@"verifier.candidate.propose_from_learning_plan" => "append_only_verifier_candidate_metadata_from_learning_loop_no_execution",
        .@"verifier.candidate.list" => "read_only_verifier_candidate_metadata_inspection_non_authorizing",
        .@"verifier.candidate.review" => "append_only_verifier_candidate_review_metadata_no_execution",
        .@"correction.propose" => "candidate_only_review_required_no_mutation",
        .@"correction.review" => "append_only_reviewed_record_no_hidden_mutation",
        .@"correction.reviewed.list", .@"correction.reviewed.get" => "read_only_reviewed_correction_inspection_non_authorizing",
        .@"correction.influence.status" => "read_only_reviewed_correction_influence_summary_non_authorizing",
        .@"procedure_pack.candidate.propose" => "candidate_only_no_pack_mutation_no_execution",
        .@"procedure_pack.candidate.review" => "append_only_reviewed_procedure_pack_candidate_no_pack_mutation",
        .@"procedure_pack.candidate.reviewed.list", .@"procedure_pack.candidate.reviewed.get" => "read_only_reviewed_procedure_pack_candidate_inspection_non_authorizing",
        .@"artifact.read", .@"artifact.list", .@"pack.list", .@"pack.inspect", .@"verifier.list" => "read_only_inspection",
        .@"artifact.patch.propose" => "candidate_only_patch_proposal_no_apply",
        .@"hypothesis.list", .@"hypothesis.triage" => "stateless_non_authorizing",
        .@"verifier.candidate.execution.list", .@"verifier.candidate.execution.get" => "read_only_state_inspection",
        .@"correction.list",
        .@"correction.get",
        .@"negative_knowledge.candidate.list",
        .@"negative_knowledge.candidate.get",
        .@"negative_knowledge.record.list",
        .@"negative_knowledge.record.get",
        .@"negative_knowledge.influence.list",
        .@"trust_decay.candidate.list",
        .@"feedback.summary",
        .@"session.get",
        => "read_only_state_inspection",
        .@"negative_knowledge.review" => "append_only_reviewed_negative_knowledge_no_hidden_mutation",
        .@"negative_knowledge.reviewed.list", .@"negative_knowledge.reviewed.get" => "read_only_reviewed_negative_knowledge_inspection_non_authorizing",
        .@"negative_knowledge.candidate.review" => "wired_structured_unsupported_legacy_review_surface",
        .@"negative_knowledge.record.expire", .@"negative_knowledge.record.supersede" => "wired_structured_unsupported_without_persistence",
        .@"project.autopsy" => "read_only_workspace_inspection",
        .@"context.autopsy" => "read_only_artifact_and_input_refs_runtime_and_persistent_pack_guidance",
        else => "implemented_not_product_ready",
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
    request_too_large,
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
pub const MAX_STDIN_REQUEST_BYTES: usize = 1024 * 1024;
pub const MAX_LIST_ENTRIES: usize = 512;
pub const MAX_SEARCH_RESULTS: usize = 64;
pub const MAX_HYPOTHESIS_ITEMS: usize = 128;
pub const MAX_TRIAGE_ITEMS: usize = 128;
pub const MAX_VERIFIER_ADAPTERS: usize = 64;
pub const MAX_PACK_LIST_ITEMS: usize = 128;
pub const MAX_VERIFIER_EXECUTION_ITEMS: usize = 128;
pub const MAX_CORRECTION_ITEMS: usize = 128;
pub const MAX_NEGATIVE_KNOWLEDGE_CANDIDATE_ITEMS: usize = 128;
pub const MAX_NEGATIVE_KNOWLEDGE_RECORD_ITEMS: usize = 128;
pub const MAX_NEGATIVE_KNOWLEDGE_INFLUENCE_ITEMS: usize = 128;
pub const MAX_TRUST_DECAY_CANDIDATE_ITEMS: usize = 128;

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
    .@"corpus.ask",
    .@"rule.evaluate",
    .@"sigil.inspect",
    .@"artifact.read",
    .@"artifact.list",
    .@"artifact.patch.propose",
    .@"hypothesis.list",
    .@"hypothesis.triage",
    .@"verifier.list",
    .@"verifier.candidate.execution.list",
    .@"verifier.candidate.execution.get",
    .@"verifier.candidate.propose_from_learning_plan",
    .@"verifier.candidate.list",
    .@"verifier.candidate.review",
    .@"correction.propose",
    .@"correction.review",
    .@"correction.reviewed.list",
    .@"correction.reviewed.get",
    .@"correction.influence.status",
    .@"learning.status",
    .@"learning.loop.plan",
    .@"procedure_pack.candidate.propose",
    .@"procedure_pack.candidate.review",
    .@"procedure_pack.candidate.reviewed.list",
    .@"procedure_pack.candidate.reviewed.get",
    .@"correction.list",
    .@"correction.get",
    .@"negative_knowledge.candidate.list",
    .@"negative_knowledge.candidate.get",
    .@"negative_knowledge.record.list",
    .@"negative_knowledge.record.get",
    .@"negative_knowledge.influence.list",
    .@"negative_knowledge.review",
    .@"negative_knowledge.reviewed.list",
    .@"negative_knowledge.reviewed.get",
    .@"trust_decay.candidate.list",
    .@"negative_knowledge.candidate.review",
    .@"negative_knowledge.record.expire",
    .@"negative_knowledge.record.supersede",
    .@"pack.list",
    .@"pack.inspect",
    .@"feedback.summary",
    .@"session.get",
    .@"project.autopsy",
    .@"context.autopsy",
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
    try std.testing.expectEqual(CapabilityPolicy.denied, capabilityPolicy(&caps, .@"network.access").?);
    // corpus.ask should be allowed (read-only/non-authorizing)
    try std.testing.expectEqual(CapabilityPolicy.allowed, capabilityPolicy(&caps, .@"corpus.ask").?);
    // rule.evaluate should be allowed (read-only/non-authorizing)
    try std.testing.expectEqual(CapabilityPolicy.allowed, capabilityPolicy(&caps, .@"rule.evaluate").?);
    // sigil.inspect should be allowed (read-only/non-authorizing)
    try std.testing.expectEqual(CapabilityPolicy.allowed, capabilityPolicy(&caps, .@"sigil.inspect").?);
    // correction.propose should be allowed (candidate-only/non-authorizing)
    try std.testing.expectEqual(CapabilityPolicy.allowed, capabilityPolicy(&caps, .@"correction.propose").?);
    // correction.review should be allowed as append-only reviewed record persistence.
    try std.testing.expectEqual(CapabilityPolicy.allowed, capabilityPolicy(&caps, .@"correction.review").?);
    // reviewed correction inspection should be read-only/allowed.
    try std.testing.expectEqual(CapabilityPolicy.allowed, capabilityPolicy(&caps, .@"correction.reviewed.list").?);
    try std.testing.expectEqual(CapabilityPolicy.allowed, capabilityPolicy(&caps, .@"correction.reviewed.get").?);
    try std.testing.expectEqual(CapabilityPolicy.allowed, capabilityPolicy(&caps, .@"correction.influence.status").?);
    // reviewed negative knowledge lifecycle should be explicit and allowed.
    try std.testing.expectEqual(CapabilityPolicy.allowed, capabilityPolicy(&caps, .@"negative_knowledge.review").?);
    try std.testing.expectEqual(CapabilityPolicy.allowed, capabilityPolicy(&caps, .@"negative_knowledge.reviewed.list").?);
    try std.testing.expectEqual(CapabilityPolicy.allowed, capabilityPolicy(&caps, .@"negative_knowledge.reviewed.get").?);
    // project.autopsy should be allowed (read-only)
    try std.testing.expectEqual(CapabilityPolicy.allowed, capabilityPolicy(&caps, .@"project.autopsy").?);
    // context.autopsy should be allowed (read-only/non-authorizing)
    try std.testing.expectEqual(CapabilityPolicy.allowed, capabilityPolicy(&caps, .@"context.autopsy").?);
}

fn capabilityPolicy(caps: []const CapabilityEntry, capability: CapabilityName) ?CapabilityPolicy {
    for (caps) |cap| {
        if (cap.capability == capability) return cap.policy;
    }
    return null;
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

test "every request kind has operation maturity metadata" {
    inline for (std.meta.fields(RequestKind)) |field| {
        const kind: RequestKind = @enumFromInt(field.value);
        const maturity = operationMaturity(kind);
        try std.testing.expectEqual(kind, maturity.kind);
        try std.testing.expect(maturity.declared);
        try std.testing.expect(maturity.maturity.len > 0);
        if (!isImplemented(kind)) {
            try std.testing.expect(!maturity.implemented);
            try std.testing.expect(!maturity.product_ready);
            try std.testing.expectEqualStrings("declared_not_implemented", maturity.maturity);
        }
    }
}

test "every implemented kind has operation maturity metadata" {
    for (IMPLEMENTED_KINDS) |kind| {
        const maturity = operationMaturity(kind);
        try std.testing.expect(maturity.declared);
        try std.testing.expect(maturity.implemented);
        try std.testing.expect(maturity.wired);
        try std.testing.expect(maturity.maturity.len > 0);
    }
}

test "maturity preserves denied and approval-required mutation policies" {
    const denied_mutations = [_]RequestKind{
        .@"verifier.candidate.execute",
        .@"correction.apply",
        .@"negative_knowledge.promote",
        .@"pack.update_from_negative_knowledge",
        .@"trust_decay.apply",
    };
    for (denied_mutations) |kind| {
        const maturity = operationMaturity(kind);
        try std.testing.expect(maturity.mutates_state);
        try std.testing.expectEqual(CapabilityPolicy.denied, maturity.capability_policy);
        try std.testing.expect(!maturity.product_ready);
    }

    const approval_mutations = [_]RequestKind{
        .@"artifact.patch.apply",
        .@"artifact.write.apply",
        .@"negative_knowledge.candidate.review",
        .@"negative_knowledge.record.expire",
        .@"negative_knowledge.record.supersede",
        .@"pack.mount",
        .@"pack.unmount",
        .@"pack.import",
        .@"pack.export",
    };
    for (approval_mutations) |kind| {
        const maturity = operationMaturity(kind);
        try std.testing.expect(maturity.mutates_state);
        try std.testing.expect(maturity.requires_approval);
        try std.testing.expectEqual(CapabilityPolicy.requires_approval, maturity.capability_policy);
        try std.testing.expect(!maturity.product_ready);
    }
}

test "no operation metadata grants support authority" {
    inline for (std.meta.fields(RequestKind)) |field| {
        const kind: RequestKind = @enumFromInt(field.value);
        const maturity = operationMaturity(kind);
        try std.testing.expect(maturity.authority_effect != .support);
    }
}
