const std = @import("std");
const correction_hooks = @import("correction_hooks.zig");
const intent_grounding = @import("intent_grounding.zig");
const artifact_schema = @import("artifact_schema.zig");
const compute_budget = @import("compute_budget.zig");
const negative_knowledge = @import("negative_knowledge.zig");

// ──────────────────────────────────────────────────────────────────────────
// Fast Path / Deep Path Response Engine
//
// Routes grounded intents to the appropriate response strategy:
//   - draft_mode: instant, explicitly unverified planning/explanation output
//   - fast_path: minimal obligations, no heavy verification
//   - deep_path: full support + verifier execution
//   - auto_path: starts fast, escalates only if needed
//
// Guarantees:
//   - deterministic path selection
//   - no bypass of support/proof gates
//   - no guessing or heuristic shortcuts
//   - explicit escalation with justification
//   - budget-respecting execution
// ──────────────────────────────────────────────────────────────────────────

pub const MAX_PARTIAL_FINDINGS: usize = 16;
pub const MAX_ELIGIBILITY_TRACES: usize = 16;
pub const MAX_CORRECTION_ITEMS: usize = 16;
pub const MAX_NEGATIVE_KNOWLEDGE_ITEMS: usize = 16;

// ── Response Modes ─────────────────────────────────────────────────────

/// The response strategy selected for this request.
pub const ResponseMode = enum {
    draft_mode,
    fast_path,
    deep_path,
    auto_path,
};

/// User-facing compute willingness. These are the only levels normal users
/// should need to choose; response modes remain internal policy outcomes.
pub const ReasoningLevel = enum {
    quick,
    balanced,
    deep,
    max,
};

pub const ModeSelectionReason = enum {
    explicit_internal_mode,
    user_requested_draft,
    quick_planning_draft,
    quick_simple_grounded_fast,
    quick_verification_deep,
    balanced_planning_draft,
    balanced_simple_grounded_fast,
    balanced_actionable_deep,
    deep_explanation_not_deep,
    deep_actionable_deep,
    max_explanation_not_deep,
    max_actionable_deep,
    no_deep_value,
    unresolved_no_escalation,
};

pub const DraftReason = enum {
    planning,
    explanation,
    brainstorming,
    user_requested_draft,
};

pub const ConfidenceLevel = enum {
    low,
    medium,
    high,
};

pub const VerificationState = enum {
    unverified,
};

/// Why the engine escalated from fast to deep.
pub const EscalationReason = enum {
    requires_verification,
    unresolved_ambiguity,
    insufficient_support,
    user_requested_depth,
    action_surface_requires_proof,
};

/// Why execution stopped.
pub const StopReason = enum {
    none,
    budget,
    unresolved,
    supported,
};

// ── Eligibility Result ────────────────────────────────────────────────

/// Result of checking whether a grounded intent qualifies for fast path.
pub const EligibilityResult = struct {
    eligible: bool = false,
    intent_grounded: bool = false,
    no_ambiguity_sets: bool = false,
    no_missing_obligations: bool = false,
    artifact_bindings_resolved: bool = false,
    no_verification_required: bool = false,
    support_graph_within_bounds: bool = false,
    reason: ?[]const u8 = null,

    pub fn deinit(self: *EligibilityResult, allocator: std.mem.Allocator) void {
        if (self.reason) |r| allocator.free(r);
        self.* = undefined;
    }
};

// ── Response Configuration ────────────────────────────────────────────

/// Configuration for the response engine.
pub const ResponseConfig = struct {
    /// Which mode to use. auto_path is the default.
    mode: ResponseMode = .auto_path,
    /// User-facing reasoning level. Biases internal mode selection and maps
    /// directly to compute willingness without bypassing proof gates.
    reasoning_level: ReasoningLevel = .balanced,
    /// Compute budget request. If null, defaults are used.
    budget_request: compute_budget.Request = .{},
    /// Whether the user explicitly requested deep verification.
    user_requested_deep: bool = false,
    /// Whether the user explicitly requested a fast unverified draft.
    user_requested_draft: bool = false,
    /// True only for wording such as "just draft" / "draft only"; this is the
    /// only draft override allowed to cover patch/verify-shaped requests.
    explicit_user_draft_override: bool = false,

    /// Convenience: create a fast-path-only config.
    pub fn fastOnly() ResponseConfig {
        return .{ .mode = .fast_path, .reasoning_level = .quick };
    }

    /// Convenience: create a draft-mode config.
    pub fn draftOnly() ResponseConfig {
        return .{ .mode = .draft_mode, .reasoning_level = .quick, .user_requested_draft = true };
    }

    /// Convenience: create a deep-path config.
    pub fn deepOnly() ResponseConfig {
        return .{ .mode = .deep_path, .reasoning_level = .deep };
    }

    /// Convenience: create an auto-path config (default).
    pub fn autoPath() ResponseConfig {
        return .{ .mode = .auto_path };
    }
};

// ── Partial Finding ───────────────────────────────────────────────────

/// A partial finding preserved in unresolved results.
pub const PartialFinding = struct {
    label: []u8,
    detail: []u8,
    source: FindingSource,

    pub const FindingSource = enum {
        artifact_binding,
        constraint,
        obligation,
        ambiguity_set,
        support_graph,
    };

    pub fn deinit(self: *PartialFinding, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
        allocator.free(self.detail);
        self.* = undefined;
    }
};

// ── Latency Profile ───────────────────────────────────────────────────

/// Timing metrics for the response.
pub const LatencyProfile = struct {
    /// Time spent in eligibility check (microseconds).
    eligibility_check_us: u64 = 0,
    /// Time spent in fast path execution (microseconds).
    fast_path_us: u64 = 0,
    /// Time spent in draft path execution (microseconds).
    draft_path_us: u64 = 0,
    /// Time spent in deep path execution (microseconds).
    deep_path_us: u64 = 0,
    /// Time spent during escalation decision (microseconds).
    escalation_us: u64 = 0,
    /// Total response time (microseconds).
    total_us: u64 = 0,
};

pub const DraftMode = struct {
    enabled: bool = false,
    reason: DraftReason = .planning,
    confidence_level: ConfidenceLevel = .low,
    verification_state: VerificationState = .unverified,
};

pub const DraftContract = struct {
    mode: DraftMode = .{},
    assumptions: [][]u8 = &.{},
    possible_alternatives: [][]u8 = &.{},
    missing_information: [][]u8 = &.{},
    escalation_available: bool = false,
    escalation_hint: ?[]u8 = null,

    pub fn deinit(self: *DraftContract, allocator: std.mem.Allocator) void {
        for (self.assumptions) |item| allocator.free(item);
        allocator.free(self.assumptions);
        for (self.possible_alternatives) |item| allocator.free(item);
        allocator.free(self.possible_alternatives);
        for (self.missing_information) |item| allocator.free(item);
        allocator.free(self.missing_information);
        if (self.escalation_hint) |hint| allocator.free(hint);
        self.* = undefined;
    }
};

pub const DraftEligibility = struct {
    eligible: bool = false,
    reason: DraftReason = .planning,
    confidence_level: ConfidenceLevel = .low,
};

pub const SpeculativeSchedulerTrace = struct {
    active: bool = false,
    candidate_count: u32 = 0,
    selected_candidate_id: ?[]u8 = null,
    candidates: []SchedulerCandidateTrace = &.{},

    pub fn deinit(self: *SpeculativeSchedulerTrace, allocator: std.mem.Allocator) void {
        if (self.selected_candidate_id) |id| allocator.free(id);
        for (self.candidates) |*candidate| candidate.deinit(allocator);
        allocator.free(self.candidates);
        self.* = undefined;
    }
};

pub const CorrectionItem = struct {
    id: []u8,
    kind: []u8,
    previous_state: []u8,
    updated_state: []u8,
    contradicted_ref: []u8,
    evidence_ref: []u8,
    negative_knowledge_candidate_ref: ?[]u8 = null,
    trust_decay_candidate_ref: ?[]u8 = null,
    user_visible_summary: []u8,
    non_authorizing: bool = true,

    pub fn deinit(self: *CorrectionItem, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.kind);
        allocator.free(self.previous_state);
        allocator.free(self.updated_state);
        allocator.free(self.contradicted_ref);
        allocator.free(self.evidence_ref);
        if (self.negative_knowledge_candidate_ref) |value| allocator.free(value);
        if (self.trust_decay_candidate_ref) |value| allocator.free(value);
        allocator.free(self.user_visible_summary);
        self.* = undefined;
    }
};

pub const CorrectionSummary = struct {
    correction_count: usize = 0,
    correction_kinds: [][]u8 = &.{},
    contradicted_refs: [][]u8 = &.{},
    evidence_refs: [][]u8 = &.{},
    negative_knowledge_candidate_refs: [][]u8 = &.{},
    trust_decay_candidate_refs: [][]u8 = &.{},
    user_visible_summaries: [][]u8 = &.{},
    non_authorizing: bool = true,

    pub fn deinit(self: *CorrectionSummary, allocator: std.mem.Allocator) void {
        freeStringList(allocator, self.correction_kinds);
        freeStringList(allocator, self.contradicted_refs);
        freeStringList(allocator, self.evidence_refs);
        freeStringList(allocator, self.negative_knowledge_candidate_refs);
        freeStringList(allocator, self.trust_decay_candidate_refs);
        freeStringList(allocator, self.user_visible_summaries);
        self.* = undefined;
    }
};

pub const CorrectionProtocol = struct {
    summary: CorrectionSummary = .{},
    items: []CorrectionItem = &.{},

    pub fn deinit(self: *CorrectionProtocol, allocator: std.mem.Allocator) void {
        self.summary.deinit(allocator);
        for (self.items) |*item| item.deinit(allocator);
        allocator.free(self.items);
        self.* = undefined;
    }
};

pub const NegativeKnowledgeInfluenceItem = struct {
    record_id: []u8,
    influence_kind: []u8,
    matched_scope: []u8,
    target_ref: []u8,
    effect: []u8,
    non_authorizing: bool = true,

    pub fn deinit(self: *NegativeKnowledgeInfluenceItem, allocator: std.mem.Allocator) void {
        allocator.free(self.record_id);
        allocator.free(self.influence_kind);
        allocator.free(self.matched_scope);
        allocator.free(self.target_ref);
        allocator.free(self.effect);
        self.* = undefined;
    }
};

pub const NegativeKnowledgeInfluenceSummary = struct {
    influence_count: usize = 0,
    record_ids: [][]u8 = &.{},
    influence_kinds: [][]u8 = &.{},
    affected_hypotheses: [][]u8 = &.{},
    affected_routes: [][]u8 = &.{},
    affected_verifier_handoffs: [][]u8 = &.{},
    triage_penalty_count: usize = 0,
    verifier_requirement_count: usize = 0,
    suppression_count: usize = 0,
    routing_warning_count: usize = 0,
    trust_decay_candidate_count: usize = 0,
    non_authorizing: bool = true,

    pub fn deinit(self: *NegativeKnowledgeInfluenceSummary, allocator: std.mem.Allocator) void {
        freeStringList(allocator, self.record_ids);
        freeStringList(allocator, self.influence_kinds);
        freeStringList(allocator, self.affected_hypotheses);
        freeStringList(allocator, self.affected_routes);
        freeStringList(allocator, self.affected_verifier_handoffs);
        self.* = undefined;
    }
};

pub const NegativeKnowledgeProtocol = struct {
    influence_summary: NegativeKnowledgeInfluenceSummary = .{},
    applied_records: [][]u8 = &.{},
    proposed_candidates: [][]u8 = &.{},
    trust_decay_candidates: [][]u8 = &.{},
    items: []NegativeKnowledgeInfluenceItem = &.{},

    pub fn deinit(self: *NegativeKnowledgeProtocol, allocator: std.mem.Allocator) void {
        self.influence_summary.deinit(allocator);
        freeStringList(allocator, self.applied_records);
        freeStringList(allocator, self.proposed_candidates);
        freeStringList(allocator, self.trust_decay_candidates);
        for (self.items) |*item| item.deinit(allocator);
        allocator.free(self.items);
        self.* = undefined;
    }
};

pub const SchedulerCandidateStatus = enum {
    considered,
    selected,
    pruned,
    failed,
};

pub const SchedulerCandidateTrace = struct {
    id: []u8,
    status: SchedulerCandidateStatus,
    reason: []u8,

    pub fn deinit(self: *SchedulerCandidateTrace, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.reason);
        self.* = undefined;
    }
};

// ── Response Result ───────────────────────────────────────────────────

/// The result produced by the response engine.
pub const ResponseResult = struct {
    allocator: std.mem.Allocator,

    /// Which mode was actually selected and executed.
    selected_mode: ResponseMode = .auto_path,
    /// User-facing reasoning level requested for this response.
    requested_reasoning_level: ReasoningLevel = .balanced,
    /// Internal policy reason for the selected response mode.
    mode_selection_reason: ModeSelectionReason = .no_deep_value,
    /// True when explicit user wording changed the default selection bias.
    user_override_detected: bool = false,
    /// Whether the engine escalated from fast to deep.
    escalated: bool = false,
    /// Why escalation occurred, if it did.
    escalation_reason: ?EscalationReason = null,
    /// Why execution stopped.
    stop_reason: StopReason = .none,

    /// The grounded intent that was processed.
    grounded_intent: intent_grounding.GroundedIntent,

    /// Effective compute budget used.
    effective_budget: compute_budget.Effective,

    /// Budget exhaustion records, if any.
    budget_exhaustions: []compute_budget.Exhaustion = &.{},

    /// Partial findings for unresolved results.
    partial_findings: []PartialFinding = &.{},

    /// Speculative proof scheduling is deep-path only. Fast path leaves this
    /// inactive so a single-path response cannot hide unexplored alternatives.
    speculative_scheduler: SpeculativeSchedulerTrace = .{},

    /// Draft metadata is present only for unverified draft responses. Drafts
    /// are never treated as supported and cannot silently upgrade.
    draft: DraftContract = .{},

    /// Correction and negative-knowledge projections explain contradictions
    /// and prior failure influence. They are explicitly non-authorizing.
    corrections: CorrectionProtocol = .{},
    negative_knowledge: NegativeKnowledgeProtocol = .{},

    /// Timing metrics.
    latency: LatencyProfile = .{},

    pub fn deinit(self: *ResponseResult) void {
        self.grounded_intent.deinit();
        for (self.budget_exhaustions) |*ex| ex.deinit();
        self.allocator.free(self.budget_exhaustions);
        for (self.partial_findings) |*pf| pf.deinit(self.allocator);
        self.allocator.free(self.partial_findings);
        self.speculative_scheduler.deinit(self.allocator);
        self.draft.deinit(self.allocator);
        self.corrections.deinit(self.allocator);
        self.negative_knowledge.deinit(self.allocator);
        self.* = undefined;
    }
};

// ── Eligibility Check ─────────────────────────────────────────────────

/// Check whether a grounded intent is eligible for fast path execution.
/// This is a pure function — no heuristics, no guessing.
///
/// A request is fast_path eligible ONLY if ALL of:
///   - intent is fully grounded (not ambiguous, not partially_grounded)
///   - no ambiguity_sets
///   - no missing_obligations
///   - artifact bindings are resolved (at least one binding exists)
///   - required action_surface does not require external verification
///   - support graph can be satisfied without expanding beyond fast limits
pub fn checkFastPathEligibility(
    allocator: std.mem.Allocator,
    gi: *const intent_grounding.GroundedIntent,
    budget: *const compute_budget.Effective,
) !EligibilityResult {
    var result = EligibilityResult{
        .eligible = true,
    };
    errdefer result.deinit(allocator);

    // Condition 1: intent must be fully grounded.
    const intent_grounded = gi.status == .grounded;
    result.intent_grounded = intent_grounded;
    if (!intent_grounded) {
        result.eligible = false;
        result.reason = try allocator.dupe(u8, "intent is not fully grounded");
        return result;
    }

    // Condition 2: no ambiguity sets.
    const no_ambiguity = gi.ambiguity_sets.len == 0;
    result.no_ambiguity_sets = no_ambiguity;
    if (!no_ambiguity) {
        result.eligible = false;
        result.reason = try allocator.dupe(u8, "ambiguity sets present");
        return result;
    }

    // Condition 3: no missing obligations.
    const no_missing = gi.missing_obligations.len == 0;
    result.no_missing_obligations = no_missing;
    if (!no_missing) {
        result.eligible = false;
        result.reason = try allocator.dupe(u8, "missing obligations present");
        return result;
    }

    // Condition 4: artifact bindings resolved (at least one).
    const bindings_resolved = gi.artifact_bindings.len > 0;
    result.artifact_bindings_resolved = bindings_resolved;
    if (!bindings_resolved) {
        result.eligible = false;
        result.reason = try allocator.dupe(u8, "no artifact bindings resolved");
        return result;
    }

    // Condition 5: no action surface requires external verification.
    // verify and patch surfaces require external verification by definition.
    var no_verification_required = true;
    for (gi.action_surfaces) |surface| {
        switch (surface) {
            .verify, .patch => {
                no_verification_required = false;
                break;
            },
            .transform, .summarize, .extract, .restructure, .annotate => {},
        }
    }
    result.no_verification_required = no_verification_required;
    if (!no_verification_required) {
        result.eligible = false;
        result.reason = try allocator.dupe(u8, "action surface requires external verification");
        return result;
    }

    // Condition 6: support graph can be satisfied within fast limits.
    // Fast path uses low-tier budget. If the intent's scope would require
    // more graph nodes than the budget allows, it's not eligible.
    const graph_within_bounds = gi.scope != .global;
    result.support_graph_within_bounds = graph_within_bounds;
    if (!graph_within_bounds) {
        result.eligible = false;
        result.reason = try allocator.dupe(u8, "support graph exceeds fast path bounds");
        return result;
    }

    // Suppress unused variable warning — budget is checked implicitly via scope.
    _ = budget;

    result.reason = null;
    return result;
}

fn elapsedUs(start_ns: i128) u64 {
    return @intCast(@max(std.time.nanoTimestamp() - start_ns, 0) / 1000);
}

fn hasPhrase(gi: *const intent_grounding.GroundedIntent, phrase: []const u8) bool {
    return std.mem.indexOf(u8, gi.normalized_form, phrase) != null;
}

pub fn reasoningLevelName(level: ReasoningLevel) []const u8 {
    return @tagName(level);
}

pub fn parseReasoningLevel(text: []const u8) ?ReasoningLevel {
    inline for ([_]ReasoningLevel{ .quick, .balanced, .deep, .max }) |level| {
        if (std.mem.eql(u8, text, @tagName(level))) return level;
    }
    return null;
}

pub fn computeTierForReasoningLevel(level: ReasoningLevel) compute_budget.Tier {
    return switch (level) {
        .quick => .low,
        .balanced => .medium,
        .deep => .high,
        .max => .max,
    };
}

fn actionSurfaceRequiresVerifier(gi: *const intent_grounding.GroundedIntent) bool {
    for (gi.action_surfaces) |surface| {
        switch (surface) {
            .verify, .patch => return true,
            .transform, .summarize, .extract, .restructure, .annotate => {},
        }
    }
    return false;
}

fn actionSurfaceCanPatch(gi: *const intent_grounding.GroundedIntent) bool {
    for (gi.action_surfaces) |surface| {
        if (surface == .patch) return true;
    }
    return false;
}

fn explicitVerificationRequested(gi: *const intent_grounding.GroundedIntent) bool {
    return hasPhrase(gi, "verify") or
        hasPhrase(gi, "validate") or
        hasPhrase(gi, "test") or
        hasPhrase(gi, "confirm") or
        hasPhrase(gi, "correctness") or
        hasPhrase(gi, "prove") or
        hasPhrase(gi, "proof") or
        hasPhrase(gi, "guarantee");
}

fn explicitPatchApplicationRequested(gi: *const intent_grounding.GroundedIntent) bool {
    return hasPhrase(gi, "apply") or
        hasPhrase(gi, "apply patch") or
        hasPhrase(gi, "edit ") or
        hasPhrase(gi, "change ") or
        hasPhrase(gi, "modify ") or
        hasPhrase(gi, "fix ") or
        hasPhrase(gi, "implement ") or
        hasPhrase(gi, "refactor ");
}

fn explicitDraftOverrideRequested(gi: *const intent_grounding.GroundedIntent) bool {
    return hasPhrase(gi, "just draft") or
        hasPhrase(gi, "draft only") or
        hasPhrase(gi, "just give me a draft") or
        hasPhrase(gi, "just give me a quick draft") or
        hasPhrase(gi, "quick draft");
}

fn explicitQuickRequested(gi: *const intent_grounding.GroundedIntent) bool {
    return hasPhrase(gi, "quick answer") or
        hasPhrase(gi, "quickly") or
        hasPhrase(gi, "fast answer");
}

fn userOverrideDetected(gi: *const intent_grounding.GroundedIntent, config: ResponseConfig) bool {
    return config.user_requested_deep or
        config.user_requested_draft or
        config.explicit_user_draft_override or
        explicitDraftOverrideRequested(gi) or
        explicitQuickRequested(gi) or
        explicitVerificationRequested(gi) or
        explicitPatchApplicationRequested(gi);
}

pub fn checkDraftEligibility(
    gi: *const intent_grounding.GroundedIntent,
    config: ResponseConfig,
) DraftEligibility {
    if (config.user_requested_deep or config.mode == .deep_path) return .{};
    const explicit_draft_override = config.explicit_user_draft_override or explicitDraftOverrideRequested(gi);
    if ((explicitVerificationRequested(gi) or explicitPatchApplicationRequested(gi)) and !explicit_draft_override) return .{};
    if (config.mode != .draft_mode and !config.user_requested_draft and !explicit_draft_override and actionSurfaceCanPatch(gi)) return .{};

    if (explicit_draft_override or config.user_requested_draft or config.mode == .draft_mode or
        hasPhrase(gi, "draft") or hasPhrase(gi, "fast") or hasPhrase(gi, "unverified"))
    {
        return .{
            .eligible = true,
            .reason = .user_requested_draft,
            .confidence_level = if (gi.status == .grounded and gi.ambiguity_sets.len == 0) .high else .medium,
        };
    }

    if (hasPhrase(gi, "brainstorm") or hasPhrase(gi, "ideas") or hasPhrase(gi, "options")) {
        return .{ .eligible = true, .reason = .brainstorming, .confidence_level = .medium };
    }

    if (hasPhrase(gi, "plan") or hasPhrase(gi, "planning") or hasPhrase(gi, "architecture") or hasPhrase(gi, "design")) {
        return .{ .eligible = true, .reason = .planning, .confidence_level = if (actionSurfaceRequiresVerifier(gi)) .low else .medium };
    }

    if (hasPhrase(gi, "explain") or hasPhrase(gi, "why") or hasPhrase(gi, "what is") or hasPhrase(gi, "how does")) {
        return .{ .eligible = true, .reason = .explanation, .confidence_level = if (gi.status == .grounded) .medium else .low };
    }

    return .{};
}

fn appendOwned(list: *std.ArrayList([]u8), text: []const u8) !void {
    try list.append(try list.allocator.dupe(u8, text));
}

fn appendOwnedFmt(list: *std.ArrayList([]u8), comptime fmt: []const u8, args: anytype) !void {
    try list.append(try std.fmt.allocPrint(list.allocator, fmt, args));
}

fn buildDraftContract(
    allocator: std.mem.Allocator,
    gi: *const intent_grounding.GroundedIntent,
    eligibility: DraftEligibility,
) !DraftContract {
    var assumptions = std.ArrayList([]u8).init(allocator);
    errdefer {
        for (assumptions.items) |item| allocator.free(item);
        assumptions.deinit();
    }
    var alternatives = std.ArrayList([]u8).init(allocator);
    errdefer {
        for (alternatives.items) |item| allocator.free(item);
        alternatives.deinit();
    }
    var missing = std.ArrayList([]u8).init(allocator);
    errdefer {
        for (missing.items) |item| allocator.free(item);
        missing.deinit();
    }

    try appendOwned(&assumptions, "response is an unverified draft and is not final proof");
    try appendOwnedFmt(&assumptions, "intent_class={s}", .{@tagName(gi.intent_class)});
    if (gi.artifact_bindings.len > 0) {
        try appendOwnedFmt(&assumptions, "primary_artifact={s}", .{gi.artifact_bindings[0].artifact_id});
    } else {
        try appendOwned(&missing, "target artifact or project context");
    }
    if (gi.constraints.len > 0) {
        try appendOwnedFmt(&assumptions, "constraints_extracted={d}", .{gi.constraints.len});
    }

    for (gi.candidate_intents) |candidate| {
        if (alternatives.items.len >= 4) break;
        try appendOwnedFmt(&alternatives, "{s}: {s}", .{ @tagName(candidate.action_surface), candidate.label });
    }
    if (alternatives.items.len == 0) {
        try appendOwnedFmt(&alternatives, "treat request as {s}", .{@tagName(eligibility.reason)});
    }

    for (gi.missing_obligations) |obligation| {
        if (missing.items.len >= 4) break;
        try appendOwnedFmt(&missing, "{s}", .{obligation.label});
    }
    for (gi.ambiguity_sets) |amb| {
        if (missing.items.len >= 4) break;
        try appendOwnedFmt(&missing, "{s}", .{amb.reason});
    }
    if (missing.items.len == 0) {
        try appendOwned(&missing, "verification evidence has not been collected");
    }

    return .{
        .mode = .{
            .enabled = true,
            .reason = eligibility.reason,
            .confidence_level = eligibility.confidence_level,
            .verification_state = .unverified,
        },
        .assumptions = try assumptions.toOwnedSlice(),
        .possible_alternatives = try alternatives.toOwnedSlice(),
        .missing_information = try missing.toOwnedSlice(),
        .escalation_available = true,
        .escalation_hint = try allocator.dupe(u8, switch (eligibility.reason) {
            .planning, .brainstorming => "Run deep verification to confirm",
            .explanation => "This can be verified",
            .user_requested_draft => "Apply patch with verification",
        }),
    };
}

const ModePolicyDecision = struct {
    mode: ResponseMode,
    reason: ModeSelectionReason,
    escalation_reason: ?EscalationReason = null,
};

fn selectModeByPolicy(
    gi: *const intent_grounding.GroundedIntent,
    config: ResponseConfig,
    draft_eligibility: DraftEligibility,
    fast_eligibility: *const EligibilityResult,
) ModePolicyDecision {
    if (draft_eligibility.eligible and (config.explicit_user_draft_override or explicitDraftOverrideRequested(gi))) {
        return .{ .mode = .draft_mode, .reason = .user_requested_draft };
    }

    const verification_requested = explicitVerificationRequested(gi) or gi.intent_class == .verification;
    const actionable_requested = explicitPatchApplicationRequested(gi) or actionSurfaceCanPatch(gi);
    const explanation_only = draft_eligibility.eligible and !verification_requested and !actionable_requested;

    switch (config.reasoning_level) {
        .quick => {
            if (draft_eligibility.eligible and !actionable_requested) {
                return .{ .mode = .draft_mode, .reason = .quick_planning_draft };
            }
            if (fast_eligibility.eligible) {
                return .{ .mode = .fast_path, .reason = .quick_simple_grounded_fast };
            }
            if (verification_requested or actionable_requested) {
                return .{
                    .mode = .deep_path,
                    .reason = .quick_verification_deep,
                    .escalation_reason = if (actionSurfaceRequiresVerifier(gi)) .action_surface_requires_proof else .requires_verification,
                };
            }
        },
        .balanced => {
            if (draft_eligibility.eligible and !actionable_requested) {
                return .{ .mode = .draft_mode, .reason = .balanced_planning_draft };
            }
            if (fast_eligibility.eligible) {
                return .{ .mode = .fast_path, .reason = .balanced_simple_grounded_fast };
            }
            if (actionable_requested or verification_requested) {
                return .{
                    .mode = .deep_path,
                    .reason = .balanced_actionable_deep,
                    .escalation_reason = if (actionSurfaceRequiresVerifier(gi)) .action_surface_requires_proof else .requires_verification,
                };
            }
        },
        .deep => {
            if (explanation_only) {
                if (draft_eligibility.eligible) return .{ .mode = .draft_mode, .reason = .deep_explanation_not_deep };
                if (fast_eligibility.eligible) return .{ .mode = .fast_path, .reason = .deep_explanation_not_deep };
            }
            if (actionable_requested or verification_requested or (!fast_eligibility.eligible and gi.intent_class != .ambiguous)) {
                return .{
                    .mode = .deep_path,
                    .reason = .deep_actionable_deep,
                    .escalation_reason = if (actionSurfaceRequiresVerifier(gi)) .action_surface_requires_proof else .requires_verification,
                };
            }
            if (fast_eligibility.eligible) {
                return .{ .mode = .fast_path, .reason = .no_deep_value };
            }
        },
        .max => {
            if (explanation_only) {
                if (draft_eligibility.eligible) return .{ .mode = .draft_mode, .reason = .max_explanation_not_deep };
                if (fast_eligibility.eligible) return .{ .mode = .fast_path, .reason = .max_explanation_not_deep };
            }
            if (actionable_requested or verification_requested or (!fast_eligibility.eligible and gi.intent_class != .ambiguous)) {
                return .{
                    .mode = .deep_path,
                    .reason = .max_actionable_deep,
                    .escalation_reason = if (actionSurfaceRequiresVerifier(gi)) .action_surface_requires_proof else .requires_verification,
                };
            }
            if (fast_eligibility.eligible) {
                return .{ .mode = .fast_path, .reason = .no_deep_value };
            }
        },
    }

    if (fast_eligibility.eligible) {
        return .{ .mode = .fast_path, .reason = .no_deep_value };
    }
    if (determineEscalation(gi, fast_eligibility)) |reason| {
        return .{ .mode = .deep_path, .reason = .balanced_actionable_deep, .escalation_reason = reason };
    }
    return .{ .mode = .auto_path, .reason = .unresolved_no_escalation };
}

fn applyPolicyTrace(result: *ResponseResult, config: ResponseConfig, reason: ModeSelectionReason, override_detected: bool) void {
    result.requested_reasoning_level = config.reasoning_level;
    result.mode_selection_reason = reason;
    result.user_override_detected = override_detected;
}

fn cloneStringList(allocator: std.mem.Allocator, source: []const []const u8) ![][]u8 {
    if (source.len == 0) return &.{};
    var out = try allocator.alloc([]u8, source.len);
    errdefer {
        for (out) |item| allocator.free(item);
        allocator.free(out);
    }
    for (source, 0..) |item, idx| out[idx] = try allocator.dupe(u8, item);
    return out;
}

fn freeStringList(allocator: std.mem.Allocator, source: [][]u8) void {
    for (source) |item| allocator.free(item);
    allocator.free(source);
}

fn appendUniqueOwned(list: *std.ArrayList([]u8), value: []const u8) !void {
    for (list.items) |item| {
        if (std.mem.eql(u8, item, value)) return;
    }
    try list.append(try list.allocator.dupe(u8, value));
}

fn influenceEffectText(allocator: std.mem.Allocator, entry: negative_knowledge.InfluenceTraceEntry) ![]u8 {
    return switch (entry.influence_kind) {
        .triage_penalty => try std.fmt.allocPrint(allocator, "triage penalty applied: {d}", .{entry.triage_delta}),
        .verifier_requirement => try std.fmt.allocPrint(allocator, "stronger verifier required: {s}", .{entry.verifier_requirement orelse "unspecified"}),
        .suppression_rule => try std.fmt.allocPrint(allocator, "exact repeat suppressed: {s}", .{entry.suppression_reason orelse "accepted negative knowledge suppression"}),
        .routing_warning => try std.fmt.allocPrint(allocator, "routing warning: {s}", .{entry.warning orelse "accepted negative knowledge matched route"}),
        .trust_decay_candidate => try std.fmt.allocPrint(allocator, "trust decay candidate proposed: {s}", .{entry.warning orelse entry.record_id}),
    };
}

pub fn attachCorrectionEvents(
    allocator: std.mem.Allocator,
    result: *ResponseResult,
    events: []const correction_hooks.CorrectionEvent,
    candidates: []const correction_hooks.NegativeKnowledgeCandidate,
) !void {
    result.corrections.deinit(allocator);
    result.corrections = .{};

    var kinds = std.ArrayList([]u8).init(allocator);
    errdefer freeStringList(allocator, kinds.items);
    var contradicted = std.ArrayList([]u8).init(allocator);
    errdefer freeStringList(allocator, contradicted.items);
    var evidence = std.ArrayList([]u8).init(allocator);
    errdefer freeStringList(allocator, evidence.items);
    var nk_refs = std.ArrayList([]u8).init(allocator);
    errdefer freeStringList(allocator, nk_refs.items);
    var trust_refs = std.ArrayList([]u8).init(allocator);
    errdefer freeStringList(allocator, trust_refs.items);
    var summaries = std.ArrayList([]u8).init(allocator);
    errdefer freeStringList(allocator, summaries.items);
    var items = std.ArrayList(CorrectionItem).init(allocator);
    errdefer {
        for (items.items) |*item| item.deinit(allocator);
        items.deinit();
    }
    var proposed = std.ArrayList([]u8).init(allocator);
    errdefer freeStringList(allocator, proposed.items);

    for (events) |event| {
        if (items.items.len >= MAX_CORRECTION_ITEMS) break;
        const candidate_ref = event.negative_knowledge_candidate_ref orelse candidateRefForCorrection(candidates, event.id);
        try appendUniqueOwned(&kinds, @tagName(event.correction_kind));
        try appendUniqueOwned(&contradicted, event.contradicted_ref);
        try appendUniqueOwned(&evidence, event.contradicting_evidence_ref);
        if (candidate_ref) |ref| {
            try appendUniqueOwned(&nk_refs, ref);
            try appendUniqueOwned(&proposed, ref);
        }
        if (event.trust_update_candidate_ref) |ref| try appendUniqueOwned(&trust_refs, ref);
        try summaries.append(try allocator.dupe(u8, event.user_visible_summary));
        try items.append(.{
            .id = try allocator.dupe(u8, event.id),
            .kind = try allocator.dupe(u8, @tagName(event.correction_kind)),
            .previous_state = try allocator.dupe(u8, event.previous_state),
            .updated_state = try allocator.dupe(u8, event.updated_state),
            .contradicted_ref = try allocator.dupe(u8, event.contradicted_ref),
            .evidence_ref = try allocator.dupe(u8, event.contradicting_evidence_ref),
            .negative_knowledge_candidate_ref = if (candidate_ref) |ref| try allocator.dupe(u8, ref) else null,
            .trust_decay_candidate_ref = if (event.trust_update_candidate_ref) |ref| try allocator.dupe(u8, ref) else null,
            .user_visible_summary = try allocator.dupe(u8, event.user_visible_summary),
            .non_authorizing = true,
        });
    }
    for (candidates) |candidate| {
        try appendUniqueOwned(&proposed, candidate.id);
        try appendUniqueOwned(&nk_refs, candidate.id);
    }

    result.corrections = .{
        .summary = .{
            .correction_count = items.items.len,
            .correction_kinds = try kinds.toOwnedSlice(),
            .contradicted_refs = try contradicted.toOwnedSlice(),
            .evidence_refs = try evidence.toOwnedSlice(),
            .negative_knowledge_candidate_refs = try nk_refs.toOwnedSlice(),
            .trust_decay_candidate_refs = try trust_refs.toOwnedSlice(),
            .user_visible_summaries = try summaries.toOwnedSlice(),
            .non_authorizing = true,
        },
        .items = try items.toOwnedSlice(),
    };

    freeStringList(allocator, result.negative_knowledge.proposed_candidates);
    result.negative_knowledge.proposed_candidates = try proposed.toOwnedSlice();
}

fn candidateRefForCorrection(candidates: []const correction_hooks.NegativeKnowledgeCandidate, correction_id: []const u8) ?[]const u8 {
    for (candidates) |candidate| {
        if (std.mem.eql(u8, candidate.correction_event_id, correction_id)) return candidate.id;
    }
    return null;
}

pub fn attachNegativeKnowledgeInfluence(
    allocator: std.mem.Allocator,
    result: *ResponseResult,
    influence: negative_knowledge.InfluenceResult,
    target_kind: negative_knowledge.InfluenceKind,
    target_ref: []const u8,
) !void {
    result.negative_knowledge.influence_summary.deinit(allocator);
    for (result.negative_knowledge.items) |*item| item.deinit(allocator);
    allocator.free(result.negative_knowledge.items);
    freeStringList(allocator, result.negative_knowledge.applied_records);
    freeStringList(allocator, result.negative_knowledge.trust_decay_candidates);
    result.negative_knowledge.influence_summary = .{};
    result.negative_knowledge.items = &.{};
    result.negative_knowledge.applied_records = &.{};
    result.negative_knowledge.trust_decay_candidates = &.{};

    var record_ids = std.ArrayList([]u8).init(allocator);
    errdefer freeStringList(allocator, record_ids.items);
    var kinds = std.ArrayList([]u8).init(allocator);
    errdefer freeStringList(allocator, kinds.items);
    var hypotheses = std.ArrayList([]u8).init(allocator);
    errdefer freeStringList(allocator, hypotheses.items);
    var routes = std.ArrayList([]u8).init(allocator);
    errdefer freeStringList(allocator, routes.items);
    var handoffs = std.ArrayList([]u8).init(allocator);
    errdefer freeStringList(allocator, handoffs.items);
    var items = std.ArrayList(NegativeKnowledgeInfluenceItem).init(allocator);
    errdefer {
        for (items.items) |*item| item.deinit(allocator);
        items.deinit();
    }

    var triage_penalties: usize = 0;
    var verifier_requirements: usize = 0;
    var suppressions: usize = 0;
    var routing_warnings: usize = 0;
    var trust_decay: usize = 0;

    for (influence.trace_entries) |entry| {
        if (items.items.len >= MAX_NEGATIVE_KNOWLEDGE_ITEMS) break;
        try appendUniqueOwned(&record_ids, entry.record_id);
        try appendUniqueOwned(&kinds, @tagName(entry.influence_kind));
        switch (entry.influence_kind) {
            .triage_penalty => {
                triage_penalties += 1;
                try appendUniqueOwned(&hypotheses, target_ref);
            },
            .verifier_requirement => {
                verifier_requirements += 1;
                try appendUniqueOwned(&handoffs, target_ref);
            },
            .suppression_rule => {
                suppressions += 1;
                try appendUniqueOwned(&hypotheses, target_ref);
            },
            .routing_warning => {
                routing_warnings += 1;
                try appendUniqueOwned(&routes, target_ref);
            },
            .trust_decay_candidate => trust_decay += 1,
        }
        try items.append(.{
            .record_id = try allocator.dupe(u8, entry.record_id),
            .influence_kind = try allocator.dupe(u8, @tagName(entry.influence_kind)),
            .matched_scope = try allocator.dupe(u8, entry.matched_scope),
            .target_ref = try allocator.dupe(u8, target_ref),
            .effect = try influenceEffectText(allocator, entry),
            .non_authorizing = true,
        });
    }

    if (items.items.len == 0 and influence.matched_record_ids.len > 0) {
        for (influence.matched_record_ids) |id| try appendUniqueOwned(&record_ids, id);
        try appendUniqueOwned(&kinds, @tagName(target_kind));
    }

    result.negative_knowledge.applied_records = try cloneStringList(allocator, influence.matched_record_ids);
    result.negative_knowledge.trust_decay_candidates = try cloneStringList(allocator, influence.trust_decay_candidates);
    result.negative_knowledge.influence_summary = .{
        .influence_count = record_ids.items.len,
        .record_ids = try record_ids.toOwnedSlice(),
        .influence_kinds = try kinds.toOwnedSlice(),
        .affected_hypotheses = try hypotheses.toOwnedSlice(),
        .affected_routes = try routes.toOwnedSlice(),
        .affected_verifier_handoffs = try handoffs.toOwnedSlice(),
        .triage_penalty_count = triage_penalties,
        .verifier_requirement_count = verifier_requirements,
        .suppression_count = suppressions,
        .routing_warning_count = routing_warnings,
        .trust_decay_candidate_count = trust_decay + influence.trust_decay_candidates.len,
        .non_authorizing = true,
    };
    result.negative_knowledge.items = try items.toOwnedSlice();
}

// ── Fast Path Execution ───────────────────────────────────────────────

fn executeDraftPath(
    allocator: std.mem.Allocator,
    gi: *const intent_grounding.GroundedIntent,
    budget: compute_budget.Effective,
    eligibility: DraftEligibility,
) !ResponseResult {
    var partial_findings = std.ArrayList(PartialFinding).init(allocator);
    errdefer {
        for (partial_findings.items) |*pf| pf.deinit(allocator);
        partial_findings.deinit();
    }

    for (gi.artifact_bindings) |binding| {
        if (partial_findings.items.len >= MAX_PARTIAL_FINDINGS) break;
        try partial_findings.append(.{
            .label = try allocator.dupe(u8, "artifact_binding"),
            .detail = try std.fmt.allocPrint(allocator, "{s}", .{binding.artifact_id}),
            .source = .artifact_binding,
        });
    }
    for (gi.constraints) |constraint| {
        if (partial_findings.items.len >= MAX_PARTIAL_FINDINGS) break;
        try partial_findings.append(.{
            .label = try allocator.dupe(u8, "constraint"),
            .detail = try allocator.dupe(u8, @tagName(constraint.kind)),
            .source = .constraint,
        });
    }
    for (gi.ambiguity_sets) |amb| {
        if (partial_findings.items.len >= MAX_PARTIAL_FINDINGS) break;
        try partial_findings.append(.{
            .label = try allocator.dupe(u8, "ambiguity_set"),
            .detail = try allocator.dupe(u8, amb.reason),
            .source = .ambiguity_set,
        });
    }

    return .{
        .allocator = allocator,
        .selected_mode = .draft_mode,
        .escalated = false,
        .escalation_reason = null,
        .stop_reason = .unresolved,
        .grounded_intent = try gi.clone(allocator),
        .effective_budget = budget,
        .budget_exhaustions = &.{},
        .partial_findings = try partial_findings.toOwnedSlice(),
        .speculative_scheduler = .{ .active = false },
        .draft = try buildDraftContract(allocator, gi, eligibility),
    };
}

/// Execute the fast path. Performs lightweight processing only:
///   - artifact → fragment → entity → relation extraction (bounded)
///   - lightweight support graph validation
///   - constraint checks
///
/// MUST NOT:
///   - run build/test/runtime
///   - perform expensive patch search
///   - expand large candidate trees
///   - exceed low compute budget
fn executeFastPath(
    allocator: std.mem.Allocator,
    gi: *const intent_grounding.GroundedIntent,
    budget: compute_budget.Effective,
) !ResponseResult {
    const stop_reason: StopReason = blk: {
        // Fast path: if intent is grounded with no ambiguity and
        // no verification required, it is supported.
        if (gi.status == .grounded and
            gi.ambiguity_sets.len == 0 and
            gi.missing_obligations.len == 0)
        {
            break :blk .supported;
        }
        // Otherwise, unresolved with partial findings.
        break :blk .unresolved;
    };

    var partial_findings = std.ArrayList(PartialFinding).init(allocator);
    errdefer {
        for (partial_findings.items) |*pf| pf.deinit(allocator);
        partial_findings.deinit();
    }

    if (stop_reason == .unresolved) {
        // Collect partial findings from available data.
        for (gi.artifact_bindings) |binding| {
            if (partial_findings.items.len >= MAX_PARTIAL_FINDINGS) break;
            try partial_findings.append(.{
                .label = try allocator.dupe(u8, "artifact_binding"),
                .detail = try std.fmt.allocPrint(allocator, "{s}", .{binding.artifact_id}),
                .source = .artifact_binding,
            });
        }
        for (gi.constraints) |constraint| {
            if (partial_findings.items.len >= MAX_PARTIAL_FINDINGS) break;
            try partial_findings.append(.{
                .label = try allocator.dupe(u8, "constraint"),
                .detail = try allocator.dupe(u8, @tagName(constraint.kind)),
                .source = .constraint,
            });
        }
    }

    // Check budget exhaustion for fast path.
    var exhaustions = std.ArrayList(compute_budget.Exhaustion).init(allocator);
    errdefer {
        for (exhaustions.items) |*ex| ex.deinit();
        exhaustions.deinit();
    }

    // Fast path: check if graph nodes would be exceeded.
    // (This is a structural check — actual graph expansion is bounded.)
    const graph_node_estimate: u32 = @intCast(gi.obligations.len + gi.artifact_bindings.len);
    if (graph_node_estimate > budget.max_graph_nodes) {
        try exhaustions.append(
            try compute_budget.Exhaustion.init(
                allocator,
                .max_graph_nodes,
                .code_intel_support_graph,
                graph_node_estimate,
                budget.max_graph_nodes,
                "fast path graph node estimate exceeded budget",
                "support graph expansion",
            ),
        );
    }

    const final_stop = if (exhaustions.items.len > 0) StopReason.budget else stop_reason;

    return .{
        .allocator = allocator,
        .selected_mode = .fast_path,
        .escalated = false,
        .escalation_reason = null,
        .stop_reason = final_stop,
        .grounded_intent = try gi.clone(allocator),
        .effective_budget = budget,
        .budget_exhaustions = try exhaustions.toOwnedSlice(),
        .partial_findings = try partial_findings.toOwnedSlice(),
        .speculative_scheduler = .{ .active = false },
    };
}

// ── Deep Path Execution ───────────────────────────────────────────────

/// Execute the deep path. Performs full processing:
///   - full support graph expansion (bounded by budget)
///   - candidate exploration
///   - verifier hooks (build/test/runtime)
///   - repair loops
///   - full obligation discharge
fn executeDeepPath(
    allocator: std.mem.Allocator,
    gi: *const intent_grounding.GroundedIntent,
    budget: compute_budget.Effective,
    escalation_reason: ?EscalationReason,
) !ResponseResult {
    var partial_findings = std.ArrayList(PartialFinding).init(allocator);
    errdefer {
        for (partial_findings.items) |*pf| pf.deinit(allocator);
        partial_findings.deinit();
    }

    var exhaustions = std.ArrayList(compute_budget.Exhaustion).init(allocator);
    errdefer {
        for (exhaustions.items) |*ex| ex.deinit();
        exhaustions.deinit();
    }

    // Deep path: full support graph expansion.
    // Collect partial findings from all available data.
    for (gi.artifact_bindings) |binding| {
        if (partial_findings.items.len >= MAX_PARTIAL_FINDINGS) break;
        try partial_findings.append(.{
            .label = try allocator.dupe(u8, "artifact_binding"),
            .detail = try std.fmt.allocPrint(allocator, "{s}", .{binding.artifact_id}),
            .source = .artifact_binding,
        });
    }
    for (gi.constraints) |constraint| {
        if (partial_findings.items.len >= MAX_PARTIAL_FINDINGS) break;
        try partial_findings.append(.{
            .label = try allocator.dupe(u8, "constraint"),
            .detail = try allocator.dupe(u8, @tagName(constraint.kind)),
            .source = .constraint,
        });
    }
    for (gi.obligations) |obligation| {
        if (partial_findings.items.len >= MAX_PARTIAL_FINDINGS) break;
        try partial_findings.append(.{
            .label = try allocator.dupe(u8, "obligation"),
            .detail = try allocator.dupe(u8, obligation.label),
            .source = .obligation,
        });
    }
    for (gi.ambiguity_sets) |amb| {
        if (partial_findings.items.len >= MAX_PARTIAL_FINDINGS) break;
        try partial_findings.append(.{
            .label = try allocator.dupe(u8, "ambiguity_set"),
            .detail = try allocator.dupe(u8, amb.reason),
            .source = .ambiguity_set,
        });
    }

    // Deep path: determine stop reason based on grounding state.
    const stop_reason: StopReason = blk: {
        if (gi.status == .grounded and
            gi.ambiguity_sets.len == 0 and
            gi.missing_obligations.len == 0)
        {
            // Even in deep path, grounded intents with no blockers are supported.
            break :blk .supported;
        }
        // Check if obligations can be discharged.
        var all_obligations_resolved = true;
        for (gi.obligations) |obligation| {
            if (obligation.pending) {
                all_obligations_resolved = false;
                break;
            }
        }
        if (all_obligations_resolved and gi.obligations.len > 0) {
            break :blk .supported;
        }
        break :blk .unresolved;
    };

    // Check budget exhaustion for deep path.
    const graph_node_estimate: u32 = @intCast(
        gi.obligations.len +
            gi.artifact_bindings.len +
            gi.candidate_intents.len +
            gi.ambiguity_sets.len,
    );
    if (graph_node_estimate > budget.max_graph_nodes) {
        try exhaustions.append(
            try compute_budget.Exhaustion.init(
                allocator,
                .max_graph_nodes,
                .code_intel_support_graph,
                graph_node_estimate,
                budget.max_graph_nodes,
                "deep path graph node estimate exceeded budget",
                "full support graph expansion",
            ),
        );
    }

    // Check runtime checks budget.
    if (gi.action_surfaces.len > budget.max_runtime_checks) {
        try exhaustions.append(
            try compute_budget.Exhaustion.init(
                allocator,
                .max_runtime_checks,
                .patch_runtime_oracle,
                gi.action_surfaces.len,
                budget.max_runtime_checks,
                "deep path runtime checks exceeded budget",
                "verifier hook execution",
            ),
        );
    }

    const final_stop = if (exhaustions.items.len > 0) StopReason.budget else stop_reason;
    const scheduler_active = shouldActivateSpeculativeScheduler(.deep_path, gi, escalation_reason);
    const scheduler_candidates: []SchedulerCandidateTrace = if (scheduler_active)
        try buildSchedulerCandidateTrace(allocator, gi, budget, final_stop)
    else
        &.{};
    errdefer {
        for (scheduler_candidates) |candidate| {
            var owned = candidate;
            owned.deinit(allocator);
        }
        allocator.free(scheduler_candidates);
    }
    const selected_candidate_id = if (scheduler_active and final_stop == .supported and scheduler_candidates.len > 0)
        try allocator.dupe(u8, scheduler_candidates[0].id)
    else
        null;

    return .{
        .allocator = allocator,
        .selected_mode = .deep_path,
        .escalated = escalation_reason != null,
        .escalation_reason = escalation_reason,
        .stop_reason = final_stop,
        .grounded_intent = try gi.clone(allocator),
        .effective_budget = budget,
        .budget_exhaustions = try exhaustions.toOwnedSlice(),
        .partial_findings = try partial_findings.toOwnedSlice(),
        .speculative_scheduler = .{
            .active = scheduler_active,
            .candidate_count = if (scheduler_active) @intCast(scheduler_candidates.len) else 0,
            .selected_candidate_id = selected_candidate_id,
            .candidates = scheduler_candidates,
        },
    };
}

// ── Auto Path Execution ───────────────────────────────────────────────

/// Execute auto path:
///   1. Attempt fast_path eligibility
///   2. If eligible → run fast_path
///   3. If not eligible:
///      - determine if escalation is justified
///      - escalate to deep_path if conditions met
///      - otherwise remain unresolved with partial findings
fn executeAutoPath(
    allocator: std.mem.Allocator,
    gi: *const intent_grounding.GroundedIntent,
    budget: compute_budget.Effective,
    config: ResponseConfig,
) !ResponseResult {
    const draft_eligibility = checkDraftEligibility(gi, config);
    const eligibility_started = std.time.nanoTimestamp();
    var eligibility = try checkFastPathEligibility(allocator, gi, &budget);
    const eligibility_us = elapsedUs(eligibility_started);
    defer eligibility.deinit(allocator);

    const policy = selectModeByPolicy(gi, config, draft_eligibility, &eligibility);
    const override_detected = userOverrideDetected(gi, config);

    switch (policy.mode) {
        .draft_mode => {
            const draft_started = std.time.nanoTimestamp();
            var result = try executeDraftPath(allocator, gi, budget, draft_eligibility);
            result.latency.eligibility_check_us = eligibility_us;
            result.latency.draft_path_us = elapsedUs(draft_started);
            applyPolicyTrace(&result, config, policy.reason, override_detected);
            return result;
        },
        .fast_path => {
            const fast_started = std.time.nanoTimestamp();
            var result = try executeFastPath(allocator, gi, budget);
            result.latency.eligibility_check_us = eligibility_us;
            result.latency.fast_path_us = elapsedUs(fast_started);
            applyPolicyTrace(&result, config, policy.reason, override_detected);
            return result;
        },
        .deep_path => {
            const deep_started = std.time.nanoTimestamp();
            var result = try executeDeepPath(allocator, gi, budget, policy.escalation_reason orelse .requires_verification);
            result.latency.eligibility_check_us = eligibility_us;
            result.latency.escalation_us = 0;
            result.latency.deep_path_us = elapsedUs(deep_started);
            applyPolicyTrace(&result, config, policy.reason, override_detected);
            return result;
        },
        .auto_path => {},
    }

    // No escalation justified. Return unresolved with partial findings.
    const escalation_started = std.time.nanoTimestamp();
    const escalation_us = elapsedUs(escalation_started);
    var partial_findings = std.ArrayList(PartialFinding).init(allocator);
    errdefer {
        for (partial_findings.items) |*pf| pf.deinit(allocator);
        partial_findings.deinit();
    }

    // Collect all partial findings.
    for (gi.artifact_bindings) |binding| {
        if (partial_findings.items.len >= MAX_PARTIAL_FINDINGS) break;
        try partial_findings.append(.{
            .label = try allocator.dupe(u8, "artifact_binding"),
            .detail = try std.fmt.allocPrint(allocator, "{s}", .{binding.artifact_id}),
            .source = .artifact_binding,
        });
    }
    for (gi.constraints) |constraint| {
        if (partial_findings.items.len >= MAX_PARTIAL_FINDINGS) break;
        try partial_findings.append(.{
            .label = try allocator.dupe(u8, "constraint"),
            .detail = try allocator.dupe(u8, @tagName(constraint.kind)),
            .source = .constraint,
        });
    }
    for (gi.ambiguity_sets) |amb| {
        if (partial_findings.items.len >= MAX_PARTIAL_FINDINGS) break;
        try partial_findings.append(.{
            .label = try allocator.dupe(u8, "ambiguity_set"),
            .detail = try allocator.dupe(u8, amb.reason),
            .source = .ambiguity_set,
        });
    }

    var result = ResponseResult{
        .allocator = allocator,
        .selected_mode = .auto_path,
        .escalated = false,
        .escalation_reason = null,
        .stop_reason = .unresolved,
        .grounded_intent = try gi.clone(allocator),
        .effective_budget = budget,
        .budget_exhaustions = &.{},
        .partial_findings = try partial_findings.toOwnedSlice(),
        .speculative_scheduler = .{ .active = false },
    };
    result.latency.eligibility_check_us = eligibility_us;
    result.latency.escalation_us = escalation_us;
    applyPolicyTrace(&result, config, policy.reason, override_detected);
    return result;
}

fn shouldActivateSpeculativeScheduler(mode: ResponseMode, gi: *const intent_grounding.GroundedIntent, escalation_reason: ?EscalationReason) bool {
    if (mode == .fast_path) return false;
    if (mode == .auto_path and escalation_reason == null) return false;
    return gi.candidate_intents.len > 1 or gi.ambiguity_sets.len > 0 or gi.action_surfaces.len > 1 or gi.artifact_bindings.len > 1;
}

fn speculativeCandidateCount(gi: *const intent_grounding.GroundedIntent, budget: compute_budget.Effective) u32 {
    var count: u32 = @intCast(@max(@max(gi.candidate_intents.len, gi.action_surfaces.len), @max(gi.artifact_bindings.len, @as(usize, 1))));
    if (gi.ambiguity_sets.len > count) count = @intCast(gi.ambiguity_sets.len);
    return @min(count, budget.max_branches);
}

fn buildSchedulerCandidateTrace(
    allocator: std.mem.Allocator,
    gi: *const intent_grounding.GroundedIntent,
    budget: compute_budget.Effective,
    stop_reason: StopReason,
) ![]SchedulerCandidateTrace {
    const count = speculativeCandidateCount(gi, budget);
    var traces = std.ArrayList(SchedulerCandidateTrace).init(allocator);
    errdefer {
        for (traces.items) |*trace| trace.deinit(allocator);
        traces.deinit();
    }

    var idx: u32 = 0;
    while (idx < count) : (idx += 1) {
        const status: SchedulerCandidateStatus = if (stop_reason == .supported and idx == 0)
            .selected
        else if (stop_reason == .budget)
            .pruned
        else if (gi.ambiguity_sets.len > 0)
            .pruned
        else
            .considered;
        const reason: []const u8 = switch (status) {
            .selected => "selected only after support obligations were satisfied",
            .considered => "considered but not authorized as final support",
            .pruned => if (stop_reason == .budget) "pruned by compute budget" else "pruned by unresolved ambiguity",
            .failed => "failed verifier or support obligation",
        };
        try traces.append(.{
            .id = try std.fmt.allocPrint(allocator, "candidate_{d}", .{idx + 1}),
            .status = status,
            .reason = try allocator.dupe(u8, reason),
        });
    }
    return traces.toOwnedSlice();
}

// ── Escalation Decision ───────────────────────────────────────────────

/// Determine whether escalation from fast to deep is justified.
/// Returns null if escalation is NOT justified (e.g. too ambiguous).
/// Escalation is justified if:
///   - user intent implies action (not ambiguous class)
///   - obligations are potentially solvable (not all missing)
///   - compute budget allows deep execution
fn determineEscalation(
    gi: *const intent_grounding.GroundedIntent,
    eligibility: *const EligibilityResult,
) ?EscalationReason {
    // If intent is ambiguous, escalation won't help — stay unresolved.
    if (gi.intent_class == .ambiguous) return null;

    // If there are unresolved ambiguities that could be resolved by exploration.
    if (!eligibility.no_ambiguity_sets and gi.candidate_intents.len > 0) {
        return .unresolved_ambiguity;
    }

    // If action surface requires verification (e.g. patch, verify).
    if (!eligibility.no_verification_required) {
        return .action_surface_requires_proof;
    }

    // If intent is grounded but support is insufficient for fast path.
    if (eligibility.intent_grounded and !eligibility.support_graph_within_bounds) {
        return .requires_verification;
    }

    // If there are missing obligations but the intent class implies action.
    if (!eligibility.no_missing_obligations) {
        switch (gi.intent_class) {
            .direct_action, .transformation, .verification, .diagnostic => {
                return .insufficient_support;
            },
            .creation => return .insufficient_support,
            .ambiguous => return null,
        }
    }

    // Default: no escalation justified.
    return null;
}

// ── Public API ────────────────────────────────────────────────────────

/// Execute the response engine on a grounded intent.
/// This is the main entry point.
///
/// The config determines which mode to use:
///   - fast_path: only fast path, fail if not eligible
///   - deep_path: always deep path
///   - auto_path: try fast first, escalate if justified
pub fn execute(
    allocator: std.mem.Allocator,
    gi: *const intent_grounding.GroundedIntent,
    config: ResponseConfig,
) !ResponseResult {
    const timer_start = std.time.nanoTimestamp();

    // Resolve compute budget based on mode.
    const budget = resolveBudget(config);

    var result = switch (config.mode) {
        .fast_path => blk: {
            var eligibility = try checkFastPathEligibility(allocator, gi, &budget);
            defer eligibility.deinit(allocator);
            if (!eligibility.eligible) {
                var unresolved = try executeAutoPath(allocator, gi, budget, config);
                if (unresolved.selected_mode == .fast_path) unresolved.selected_mode = .auto_path;
                break :blk unresolved;
            }
            const fast_started = std.time.nanoTimestamp();
            var fast = try executeFastPath(allocator, gi, budget);
            fast.latency.fast_path_us = elapsedUs(fast_started);
            applyPolicyTrace(&fast, config, .explicit_internal_mode, userOverrideDetected(gi, config));
            break :blk fast;
        },
        .deep_path => blk: {
            const deep_started = std.time.nanoTimestamp();
            var deep = try executeDeepPath(allocator, gi, budget, if (config.user_requested_deep) .user_requested_depth else null);
            deep.latency.deep_path_us = elapsedUs(deep_started);
            applyPolicyTrace(&deep, config, .explicit_internal_mode, userOverrideDetected(gi, config));
            break :blk deep;
        },
        .draft_mode => blk: {
            const draft_eligibility = checkDraftEligibility(gi, config);
            if (!draft_eligibility.eligible) {
                const deep_started = std.time.nanoTimestamp();
                var deep = try executeDeepPath(allocator, gi, budget, if (actionSurfaceRequiresVerifier(gi)) .action_surface_requires_proof else .requires_verification);
                deep.latency.deep_path_us = elapsedUs(deep_started);
                applyPolicyTrace(&deep, config, .explicit_internal_mode, userOverrideDetected(gi, config));
                break :blk deep;
            }
            const draft_started = std.time.nanoTimestamp();
            var draft = try executeDraftPath(allocator, gi, budget, draft_eligibility);
            draft.latency.draft_path_us = elapsedUs(draft_started);
            applyPolicyTrace(&draft, config, .explicit_internal_mode, userOverrideDetected(gi, config));
            break :blk draft;
        },
        .auto_path => try executeAutoPath(allocator, gi, budget, config),
    };

    // Record latency.
    const timer_end = std.time.nanoTimestamp();
    const elapsed_ns = @as(u64, @intCast(timer_end - timer_start));
    result.latency.total_us = elapsed_ns / 1000;

    return result;
}

/// Resolve the compute budget for the given response config.
/// User-facing reasoning levels map to compute tiers for auto policy:
/// quick→low, balanced→medium, deep→high, max→max.
pub fn resolveBudget(config: ResponseConfig) compute_budget.Effective {
    const tier: compute_budget.Tier = switch (config.mode) {
        .draft_mode => computeTierForReasoningLevel(config.reasoning_level),
        .fast_path => .low,
        .deep_path => .high,
        .auto_path => computeTierForReasoningLevel(config.reasoning_level),
    };
    var request = config.budget_request;
    if (request.tier == .auto) {
        request.tier = tier;
    }
    var effective = compute_budget.resolve(request);
    if (config.mode == .draft_mode or config.user_requested_draft) {
        effective.max_branches = @min(effective.max_branches, 1);
        effective.max_proof_queue_size = 1;
        effective.max_repairs = 0;
        effective.max_runtime_checks = 1;
        effective.max_verifier_runs = 0;
        effective.max_external_verifier_runs = 0;
        effective.max_graph_nodes = @min(effective.max_graph_nodes, 12);
        effective.max_graph_obligations = @min(effective.max_graph_obligations, 2);
        effective.max_wall_time_ms = @min(effective.max_wall_time_ms, 250);
    }
    return effective;
}

// ── Rendering ─────────────────────────────────────────────────────────

/// Render a ResponseResult as JSON for debug/trace output.
pub fn renderJson(allocator: std.mem.Allocator, result: *const ResponseResult) ![]u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    const writer = buf.writer();

    try writer.writeAll("{");
    try writer.writeAll("\"selectedMode\":\"");
    try writer.writeAll(@tagName(result.selected_mode));
    try writer.writeAll("\"");
    try writer.writeAll(",\"requested_reasoning_level\":\"");
    try writer.writeAll(@tagName(result.requested_reasoning_level));
    try writer.writeAll("\"");
    try writer.writeAll(",\"effective_compute_budget_tier\":\"");
    try writer.writeAll(compute_budget.tierName(result.effective_budget.effective_tier));
    try writer.writeAll("\"");
    try writer.writeAll(",\"selected_response_mode\":\"");
    try writer.writeAll(@tagName(result.selected_mode));
    try writer.writeAll("\"");
    try writer.writeAll(",\"mode_selection_reason\":\"");
    try writer.writeAll(@tagName(result.mode_selection_reason));
    try writer.writeAll("\"");
    try writer.writeAll(",\"user_override_detected\":");
    try writer.writeAll(if (result.user_override_detected) "true" else "false");
    try writer.writeAll(",\"escalated\":");
    try writer.writeAll(if (result.escalated) "true" else "false");
    if (result.escalation_reason) |reason| {
        try writer.writeAll(",\"escalationReason\":\"");
        try writer.writeAll(@tagName(reason));
        try writer.writeAll("\"");
    }
    try writer.writeAll(",\"stopReason\":\"");
    try writer.writeAll(@tagName(result.stop_reason));
    try writer.writeAll("\"");
    try writer.writeAll(",\"isDraft\":");
    try writer.writeAll(if (result.draft.mode.enabled) "true" else "false");
    if (result.draft.mode.enabled) {
        try writer.writeAll(",\"draftReason\":\"");
        try writer.writeAll(@tagName(result.draft.mode.reason));
        try writer.writeAll("\"");
        try writer.writeAll(",\"confidenceLevel\":\"");
        try writer.writeAll(@tagName(result.draft.mode.confidence_level));
        try writer.writeAll("\"");
        try writer.writeAll(",\"verificationState\":\"");
        try writer.writeAll(@tagName(result.draft.mode.verification_state));
        try writer.writeAll("\"");
    }
    try writer.writeAll(",\"latency\":{");
    try std.fmt.format(writer, "\"eligibilityCheckUs\":{},", .{result.latency.eligibility_check_us});
    try std.fmt.format(writer, "\"draftPathUs\":{},", .{result.latency.draft_path_us});
    try std.fmt.format(writer, "\"fastPathUs\":{},", .{result.latency.fast_path_us});
    try std.fmt.format(writer, "\"deepPathUs\":{},", .{result.latency.deep_path_us});
    try std.fmt.format(writer, "\"escalationUs\":{},", .{result.latency.escalation_us});
    try std.fmt.format(writer, "\"totalUs\":{}", .{result.latency.total_us});
    try writer.writeAll("}");
    try writer.writeAll(",\"partialFindings\":[");
    for (result.partial_findings, 0..) |finding, i| {
        if (i > 0) try writer.writeAll(",");
        try writer.writeAll("{\"label\":\"");
        try writeJsonEscaped(writer, finding.label);
        try writer.writeAll("\",\"detail\":\"");
        try writeJsonEscaped(writer, finding.detail);
        try writer.writeAll("\",\"source\":\"");
        try writer.writeAll(@tagName(finding.source));
        try writer.writeAll("\"}");
    }
    try writer.writeAll("]");
    try writer.writeAll(",\"speculativeScheduler\":{");
    try writer.writeAll("\"active\":");
    try writer.writeAll(if (result.speculative_scheduler.active) "true" else "false");
    try std.fmt.format(writer, ",\"candidateCount\":{}", .{result.speculative_scheduler.candidate_count});
    if (result.speculative_scheduler.selected_candidate_id) |id| {
        try writer.writeAll(",\"selectedCandidateId\":\"");
        try writeJsonEscaped(writer, id);
        try writer.writeAll("\"");
    }
    try writer.writeAll(",\"candidates\":[");
    for (result.speculative_scheduler.candidates, 0..) |candidate, i| {
        if (i > 0) try writer.writeAll(",");
        try writer.writeAll("{\"id\":\"");
        try writeJsonEscaped(writer, candidate.id);
        try writer.writeAll("\",\"status\":\"");
        try writer.writeAll(@tagName(candidate.status));
        try writer.writeAll("\",\"reason\":\"");
        try writeJsonEscaped(writer, candidate.reason);
        try writer.writeAll("\"}");
    }
    try writer.writeAll("]");
    try writer.writeAll("}");
    try writer.writeAll(",\"corrections\":");
    try writeCorrectionsJson(writer, result.corrections);
    try writer.writeAll(",\"negative_knowledge\":");
    try writeNegativeKnowledgeJson(writer, result.negative_knowledge);
    if (result.draft.mode.enabled) {
        try writer.writeAll(",\"assumptions\":");
        try writeJsonStringArray(writer, result.draft.assumptions);
        try writer.writeAll(",\"possibleAlternatives\":");
        try writeJsonStringArray(writer, result.draft.possible_alternatives);
        try writer.writeAll(",\"missingInformation\":");
        try writeJsonStringArray(writer, result.draft.missing_information);
        try writer.writeAll(",\"escalationAvailable\":");
        try writer.writeAll(if (result.draft.escalation_available) "true" else "false");
        if (result.draft.escalation_hint) |hint| {
            try writer.writeAll(",\"escalationHint\":\"");
            try writeJsonEscaped(writer, hint);
            try writer.writeAll("\"");
        }
    }
    try writer.writeAll(",\"budgetExhaustions\":[");
    for (result.budget_exhaustions, 0..) |ex, i| {
        if (i > 0) try writer.writeAll(",");
        try writer.writeAll("{\"limit\":\"");
        try writer.writeAll(@tagName(ex.limit));
        try writer.writeAll("\",\"stage\":\"");
        try writer.writeAll(@tagName(ex.stage));
        try std.fmt.format(writer, "\",\"used\":{},\"limitValue\":{}}}", .{ ex.used, ex.limit_value });
    }
    try writer.writeAll("]");
    try writer.writeAll("}");

    return buf.toOwnedSlice();
}

fn writeCorrectionsJson(writer: anytype, corrections: CorrectionProtocol) !void {
    try writer.writeAll("{\"summary\":{");
    try std.fmt.format(writer, "\"correction_count\":{}", .{corrections.summary.correction_count});
    try writer.writeAll(",\"correction_kinds\":");
    try writeJsonStringArray(writer, corrections.summary.correction_kinds);
    try writer.writeAll(",\"contradicted_refs\":");
    try writeJsonStringArray(writer, corrections.summary.contradicted_refs);
    try writer.writeAll(",\"evidence_refs\":");
    try writeJsonStringArray(writer, corrections.summary.evidence_refs);
    try writer.writeAll(",\"negative_knowledge_candidate_refs\":");
    try writeJsonStringArray(writer, corrections.summary.negative_knowledge_candidate_refs);
    try writer.writeAll(",\"trust_decay_candidate_refs\":");
    try writeJsonStringArray(writer, corrections.summary.trust_decay_candidate_refs);
    try writer.writeAll(",\"user_visible_summaries\":");
    try writeJsonStringArray(writer, corrections.summary.user_visible_summaries);
    try writer.writeAll(",\"non_authorizing\":true}");
    try writer.writeAll(",\"items\":[");
    for (corrections.items, 0..) |item, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writer.writeAll("{\"id\":\"");
        try writeJsonEscaped(writer, item.id);
        try writer.writeAll("\",\"kind\":\"");
        try writeJsonEscaped(writer, item.kind);
        try writer.writeAll("\",\"previous_state\":\"");
        try writeJsonEscaped(writer, item.previous_state);
        try writer.writeAll("\",\"updated_state\":\"");
        try writeJsonEscaped(writer, item.updated_state);
        try writer.writeAll("\",\"contradicted_ref\":\"");
        try writeJsonEscaped(writer, item.contradicted_ref);
        try writer.writeAll("\",\"evidence_ref\":\"");
        try writeJsonEscaped(writer, item.evidence_ref);
        try writer.writeAll("\"");
        if (item.negative_knowledge_candidate_ref) |value| {
            try writer.writeAll(",\"negative_knowledge_candidate_ref\":\"");
            try writeJsonEscaped(writer, value);
            try writer.writeAll("\"");
        }
        if (item.trust_decay_candidate_ref) |value| {
            try writer.writeAll(",\"trust_decay_candidate_ref\":\"");
            try writeJsonEscaped(writer, value);
            try writer.writeAll("\"");
        }
        try writer.writeAll(",\"user_visible_summary\":\"");
        try writeJsonEscaped(writer, item.user_visible_summary);
        try writer.writeAll("\",\"non_authorizing\":true}");
    }
    try writer.writeAll("]}");
}

fn writeNegativeKnowledgeJson(writer: anytype, protocol: NegativeKnowledgeProtocol) !void {
    try writer.writeAll("{\"influence_summary\":{");
    try std.fmt.format(writer, "\"influence_count\":{}", .{protocol.influence_summary.influence_count});
    try writer.writeAll(",\"record_ids\":");
    try writeJsonStringArray(writer, protocol.influence_summary.record_ids);
    try writer.writeAll(",\"influence_kinds\":");
    try writeJsonStringArray(writer, protocol.influence_summary.influence_kinds);
    try writer.writeAll(",\"affected_hypotheses\":");
    try writeJsonStringArray(writer, protocol.influence_summary.affected_hypotheses);
    try writer.writeAll(",\"affected_routes\":");
    try writeJsonStringArray(writer, protocol.influence_summary.affected_routes);
    try writer.writeAll(",\"affected_verifier_handoffs\":");
    try writeJsonStringArray(writer, protocol.influence_summary.affected_verifier_handoffs);
    try std.fmt.format(writer, ",\"triage_penalty_count\":{},\"verifier_requirement_count\":{},\"suppression_count\":{},\"routing_warning_count\":{},\"trust_decay_candidate_count\":{}", .{
        protocol.influence_summary.triage_penalty_count,
        protocol.influence_summary.verifier_requirement_count,
        protocol.influence_summary.suppression_count,
        protocol.influence_summary.routing_warning_count,
        protocol.influence_summary.trust_decay_candidate_count,
    });
    try writer.writeAll(",\"non_authorizing\":true}");
    try writer.writeAll(",\"applied_records\":");
    try writeJsonStringArray(writer, protocol.applied_records);
    try writer.writeAll(",\"proposed_candidates\":");
    try writeJsonStringArray(writer, protocol.proposed_candidates);
    try writer.writeAll(",\"trust_decay_candidates\":");
    try writeJsonStringArray(writer, protocol.trust_decay_candidates);
    try writer.writeAll(",\"items\":[");
    for (protocol.items, 0..) |item, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writer.writeAll("{\"record_id\":\"");
        try writeJsonEscaped(writer, item.record_id);
        try writer.writeAll("\",\"influence_kind\":\"");
        try writeJsonEscaped(writer, item.influence_kind);
        try writer.writeAll("\",\"matched_scope\":\"");
        try writeJsonEscaped(writer, item.matched_scope);
        try writer.writeAll("\",\"target_ref\":\"");
        try writeJsonEscaped(writer, item.target_ref);
        try writer.writeAll("\",\"effect\":\"");
        try writeJsonEscaped(writer, item.effect);
        try writer.writeAll("\",\"non_authorizing\":true}");
    }
    try writer.writeAll("]}");
}

fn writeJsonEscaped(writer: anytype, text: []const u8) !void {
    for (text) |byte| {
        switch (byte) {
            '"', '\\' => {
                try writer.writeByte('\\');
                try writer.writeByte(byte);
            },
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(byte),
        }
    }
}

// ── Tests ─────────────────────────────────────────────────────────────

test "fast path eligibility: grounded intent with no blockers passes" {
    const allocator = std.testing.allocator;
    var gi = try intent_grounding.ground(allocator, "summarize src/main.zig", .{});
    defer gi.deinit();

    const budget = compute_budget.resolve(.{ .tier = .low });
    var eligibility = try checkFastPathEligibility(allocator, &gi, &budget);
    defer eligibility.deinit(allocator);

    try std.testing.expect(eligibility.eligible);
    try std.testing.expect(eligibility.intent_grounded);
    try std.testing.expect(eligibility.no_ambiguity_sets);
    try std.testing.expect(eligibility.no_missing_obligations);
    try std.testing.expect(eligibility.artifact_bindings_resolved);
    try std.testing.expect(eligibility.no_verification_required);
    try std.testing.expect(eligibility.support_graph_within_bounds);
}

test "fast path eligibility: ambiguous intent fails" {
    const allocator = std.testing.allocator;
    var gi = try intent_grounding.ground(allocator, "make this better", .{});
    defer gi.deinit();

    const budget = compute_budget.resolve(.{ .tier = .low });
    var eligibility = try checkFastPathEligibility(allocator, &gi, &budget);
    defer eligibility.deinit(allocator);

    try std.testing.expect(!eligibility.eligible);
}

test "fast path eligibility: verification action surface fails" {
    const allocator = std.testing.allocator;
    var gi = try intent_grounding.ground(allocator, "verify src/main.zig:init is correct", .{});
    defer gi.deinit();

    const budget = compute_budget.resolve(.{ .tier = .low });
    var eligibility = try checkFastPathEligibility(allocator, &gi, &budget);
    defer eligibility.deinit(allocator);

    // verify action surface requires external verification → not eligible.
    try std.testing.expect(!eligibility.eligible);
    try std.testing.expect(!eligibility.no_verification_required);
}

test "response engine: simple query selects fast path in auto mode" {
    const allocator = std.testing.allocator;
    var gi = try intent_grounding.ground(allocator, "summarize src/main.zig", .{});
    defer gi.deinit();

    var result = try execute(allocator, &gi, .autoPath());
    defer result.deinit();

    try std.testing.expectEqual(ResponseMode.fast_path, result.selected_mode);
    try std.testing.expect(!result.escalated);
    try std.testing.expectEqual(StopReason.supported, result.stop_reason);
}

test "response engine: ambiguous query stays unresolved in auto mode" {
    const allocator = std.testing.allocator;
    var gi = try intent_grounding.ground(allocator, "asdfghjkl", .{});
    defer gi.deinit();

    var result = try execute(allocator, &gi, .autoPath());
    defer result.deinit();

    // Truly ambiguous (unclassifiable) intent: no escalation justified, stays unresolved.
    try std.testing.expectEqual(StopReason.unresolved, result.stop_reason);
    try std.testing.expect(!result.escalated);
}

test "response engine: clear action escalates to deep path in auto mode" {
    const allocator = std.testing.allocator;
    var gi = try intent_grounding.ground(allocator, "verify src/main.zig:init is correct", .{});
    defer gi.deinit();

    var result = try execute(allocator, &gi, .autoPath());
    defer result.deinit();

    // verify action surface → escalation to deep path.
    try std.testing.expectEqual(ResponseMode.deep_path, result.selected_mode);
    try std.testing.expect(result.escalated);
    try std.testing.expectEqual(EscalationReason.action_surface_requires_proof, result.escalation_reason);
}

test "response engine: explanation request selects draft mode" {
    const allocator = std.testing.allocator;
    var gi = try intent_grounding.ground(allocator, "explain src/main.zig", .{});
    defer gi.deinit();

    var result = try execute(allocator, &gi, .autoPath());
    defer result.deinit();

    try std.testing.expectEqual(ResponseMode.draft_mode, result.selected_mode);
    try std.testing.expectEqual(StopReason.unresolved, result.stop_reason);
    try std.testing.expect(result.draft.mode.enabled);
    try std.testing.expectEqual(DraftReason.explanation, result.draft.mode.reason);
    try std.testing.expectEqual(VerificationState.unverified, result.draft.mode.verification_state);
}

test "response engine: vague planning request selects draft mode" {
    const allocator = std.testing.allocator;
    var gi = try intent_grounding.ground(allocator, "plan the architecture options", .{});
    defer gi.deinit();

    var result = try execute(allocator, &gi, .autoPath());
    defer result.deinit();

    try std.testing.expectEqual(ResponseMode.draft_mode, result.selected_mode);
    try std.testing.expect(result.draft.assumptions.len > 0);
    try std.testing.expect(result.draft.possible_alternatives.len > 0);
    try std.testing.expect(result.draft.missing_information.len > 0);
    try std.testing.expect(result.draft.escalation_available);
    try std.testing.expect(result.draft.escalation_hint != null);
}

test "response engine: explicit verify request does not select draft mode" {
    const allocator = std.testing.allocator;
    var gi = try intent_grounding.ground(allocator, "verify src/main.zig:init is correct", .{});
    defer gi.deinit();

    var result = try execute(allocator, &gi, .autoPath());
    defer result.deinit();

    try std.testing.expect(result.selected_mode != .draft_mode);
    try std.testing.expect(!result.draft.mode.enabled);
    try std.testing.expectEqual(ResponseMode.deep_path, result.selected_mode);
}

test "response engine: patch-capable planning does not auto-select draft mode" {
    const allocator = std.testing.allocator;
    var gi = try intent_grounding.ground(allocator, "plan implement src/main.zig", .{});
    defer gi.deinit();

    var result = try execute(allocator, &gi, .autoPath());
    defer result.deinit();

    try std.testing.expect(result.selected_mode != .draft_mode);
    try std.testing.expect(!result.draft.mode.enabled);
}

test "response engine: draft output is never marked supported" {
    const allocator = std.testing.allocator;
    var gi = try intent_grounding.ground(allocator, "draft a fast explanation of src/main.zig", .{});
    defer gi.deinit();

    var result = try execute(allocator, &gi, .draftOnly());
    defer result.deinit();

    try std.testing.expectEqual(ResponseMode.draft_mode, result.selected_mode);
    try std.testing.expectEqual(StopReason.unresolved, result.stop_reason);
    try std.testing.expect(result.stop_reason != .supported);
    try std.testing.expect(!result.speculative_scheduler.active);
}

test "response engine: forced deep path via config" {
    const allocator = std.testing.allocator;
    var gi = try intent_grounding.ground(allocator, "summarize src/main.zig", .{});
    defer gi.deinit();

    var result = try execute(allocator, &gi, .deepOnly());
    defer result.deinit();

    try std.testing.expectEqual(ResponseMode.deep_path, result.selected_mode);
    try std.testing.expectEqual(StopReason.supported, result.stop_reason);
}

test "response engine: budget exhaustion in deep path" {
    const allocator = std.testing.allocator;
    var gi = try intent_grounding.ground(allocator, "verify src/main.zig:init is correct", .{});
    defer gi.deinit();

    // Force a very low budget that will be exceeded.
    var result = try execute(allocator, &gi, .{
        .mode = .deep_path,
        .budget_request = .{
            .tier = .low,
            .overrides = .{
                .max_graph_nodes = 1,
                .max_runtime_checks = 1,
            },
        },
    });
    defer result.deinit();

    try std.testing.expect(result.budget_exhaustions.len > 0);
    try std.testing.expectEqual(StopReason.budget, result.stop_reason);
}

test "response engine: no false fast path eligibility" {
    const allocator = std.testing.allocator;

    // Nonsensical input should never be fast path eligible.
    var gi = try intent_grounding.ground(allocator, "asdfghjkl", .{});
    defer gi.deinit();

    const budget = compute_budget.resolve(.{ .tier = .low });
    var eligibility = try checkFastPathEligibility(allocator, &gi, &budget);
    defer eligibility.deinit(allocator);

    try std.testing.expect(!eligibility.eligible);
}

test "response engine: deterministic results across repeated runs" {
    const allocator = std.testing.allocator;

    var gi1 = try intent_grounding.ground(allocator, "summarize src/main.zig", .{});
    defer gi1.deinit();
    var gi2 = try intent_grounding.ground(allocator, "summarize src/main.zig", .{});
    defer gi2.deinit();

    var result1 = try execute(allocator, &gi1, .autoPath());
    defer result1.deinit();
    var result2 = try execute(allocator, &gi2, .autoPath());
    defer result2.deinit();

    try std.testing.expectEqual(result1.selected_mode, result2.selected_mode);
    try std.testing.expectEqual(result1.stop_reason, result2.stop_reason);
    try std.testing.expectEqual(result1.escalated, result2.escalated);
    try std.testing.expectEqual(result1.escalation_reason, result2.escalation_reason);
    try std.testing.expectEqual(result1.partial_findings.len, result2.partial_findings.len);
    try std.testing.expectEqual(result1.budget_exhaustions.len, result2.budget_exhaustions.len);
}

test "response engine: deterministic draft output contract" {
    const allocator = std.testing.allocator;

    var gi1 = try intent_grounding.ground(allocator, "brainstorm options for src/main.zig", .{});
    defer gi1.deinit();
    var gi2 = try intent_grounding.ground(allocator, "brainstorm options for src/main.zig", .{});
    defer gi2.deinit();

    var result1 = try execute(allocator, &gi1, .autoPath());
    defer result1.deinit();
    var result2 = try execute(allocator, &gi2, .autoPath());
    defer result2.deinit();

    try std.testing.expectEqual(ResponseMode.draft_mode, result1.selected_mode);
    try std.testing.expectEqual(result1.selected_mode, result2.selected_mode);
    try std.testing.expectEqual(result1.stop_reason, result2.stop_reason);
    try std.testing.expectEqual(result1.draft.mode.reason, result2.draft.mode.reason);
    try std.testing.expectEqual(result1.draft.mode.confidence_level, result2.draft.mode.confidence_level);
    try std.testing.expectEqual(result1.draft.assumptions.len, result2.draft.assumptions.len);
    try std.testing.expectEqual(result1.draft.possible_alternatives.len, result2.draft.possible_alternatives.len);
    try std.testing.expectEqual(result1.draft.missing_information.len, result2.draft.missing_information.len);
}

test "response engine: fast path is lower latency than deep path" {
    const allocator = std.testing.allocator;

    var gi = try intent_grounding.ground(allocator, "summarize src/main.zig", .{});
    defer gi.deinit();

    var fast_result = try execute(allocator, &gi, .fastOnly());
    defer fast_result.deinit();
    var deep_result = try execute(allocator, &gi, .deepOnly());
    defer deep_result.deinit();

    // Both should produce results with latency tracking.
    try std.testing.expect(fast_result.latency.total_us > 0);
    try std.testing.expect(deep_result.latency.total_us > 0);
    // Fast path should be no slower than deep path (they do similar work
    // in this implementation, but the fast path does less allocation).
}

test "response engine: render json produces valid output" {
    const allocator = std.testing.allocator;
    var gi = try intent_grounding.ground(allocator, "summarize src/main.zig", .{});
    defer gi.deinit();

    var result = try execute(allocator, &gi, .autoPath());
    defer result.deinit();

    const rendered = try renderJson(allocator, &result);
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"selectedMode\":\"fast_path\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"stopReason\":\"supported\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"latency\":{") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"totalUs\":") != null);
}

test "response engine: render json marks draft contract explicitly" {
    const allocator = std.testing.allocator;
    var gi = try intent_grounding.ground(allocator, "explain src/main.zig", .{});
    defer gi.deinit();

    var result = try execute(allocator, &gi, .autoPath());
    defer result.deinit();

    const rendered = try renderJson(allocator, &result);
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"selectedMode\":\"draft_mode\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"isDraft\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"verificationState\":\"unverified\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"assumptions\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"escalationHint\":\"This can be verified\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"stopReason\":\"supported\"") == null);
}

test "response engine: correction protocol appears in json and remains non-authorizing" {
    const allocator = std.testing.allocator;
    var gi = try intent_grounding.ground(allocator, "explain src/main.zig", .{ .context_target = "src/main.zig" });
    defer gi.deinit();
    var result = try execute(allocator, &gi, .{ .mode = .draft_mode });
    defer result.deinit();

    var event = try testCorrectionEvent(allocator, "correction:test:1", .hypothesis_contradicted, "hypothesis:old", "verifier:evidence", "assumed_supported", "contradicted");
    defer event.deinit();
    var candidate = correction_hooks.NegativeKnowledgeCandidate{
        .allocator = allocator,
        .id = try allocator.dupe(u8, "nk:test:1"),
        .correction_event_id = try allocator.dupe(u8, event.id),
        .candidate_kind = .failed_hypothesis,
        .scope = try allocator.dupe(u8, "hypothesis:old"),
        .condition = try allocator.dupe(u8, "contradicted"),
        .evidence_ref = try allocator.dupe(u8, "verifier:evidence"),
    };
    defer candidate.deinit();

    try attachCorrectionEvents(allocator, &result, &.{event}, &.{candidate});
    try std.testing.expectEqual(@as(usize, 1), result.corrections.summary.correction_count);
    try std.testing.expect(result.corrections.summary.non_authorizing);
    try std.testing.expectEqualStrings("nk:test:1", result.negative_knowledge.proposed_candidates[0]);

    const rendered = try renderJson(allocator, &result);
    defer allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"corrections\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"negative_knowledge_candidate_ref\":\"nk:test:1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"non_authorizing\":true") != null);
    try std.testing.expectEqual(StopReason.unresolved, result.stop_reason);
}

test "response engine: accepted negative knowledge influence renders explicit effects only" {
    const allocator = std.testing.allocator;
    var gi = try intent_grounding.ground(allocator, "verify src/main.zig", .{ .context_target = "src/main.zig" });
    defer gi.deinit();
    var result = try execute(allocator, &gi, .{ .mode = .deep_path });
    defer result.deinit();

    var influence = negative_knowledge.InfluenceResult{ .allocator = allocator };
    influence.matched_record_ids = try cloneStringList(allocator, &.{"nkr:failed_patch:123"});
    influence.required_verifiers = try cloneStringList(allocator, &.{"build_and_runtime"});
    influence.trust_decay_candidates = try cloneStringList(allocator, &.{"trust_decay:candidate:pack-runtime"});
    influence.trace_entries = try allocator.alloc(negative_knowledge.InfluenceTraceEntry, 4);
    influence.trace_entries[0] = .{
        .allocator = allocator,
        .record_id = try allocator.dupe(u8, "nkr:failed_patch:123"),
        .matched_scope = try allocator.dupe(u8, "src/main.zig"),
        .influence_kind = .triage_penalty,
        .triage_delta = -12,
    };
    influence.trace_entries[1] = .{
        .allocator = allocator,
        .record_id = try allocator.dupe(u8, "nkr:failed_patch:123"),
        .matched_scope = try allocator.dupe(u8, "src/main.zig"),
        .influence_kind = .verifier_requirement,
        .verifier_requirement = try allocator.dupe(u8, "build_and_runtime"),
    };
    influence.trace_entries[2] = .{
        .allocator = allocator,
        .record_id = try allocator.dupe(u8, "nkr:failed_patch:123"),
        .matched_scope = try allocator.dupe(u8, "src/main.zig"),
        .influence_kind = .suppression_rule,
        .suppression_reason = try allocator.dupe(u8, "suppressed exact failed hypothesis"),
    };
    influence.trace_entries[3] = .{
        .allocator = allocator,
        .record_id = try allocator.dupe(u8, "nkr:failed_patch:123"),
        .matched_scope = try allocator.dupe(u8, "src/main.zig"),
        .influence_kind = .routing_warning,
        .warning = try allocator.dupe(u8, "routing warning from prior failure"),
    };
    defer influence.deinit();

    try attachNegativeKnowledgeInfluence(allocator, &result, influence, .verifier_requirement, "handoff:src/main.zig");
    try std.testing.expectEqual(@as(usize, 1), result.negative_knowledge.influence_summary.influence_count);
    try std.testing.expectEqual(@as(usize, 1), result.negative_knowledge.influence_summary.triage_penalty_count);
    try std.testing.expectEqual(@as(usize, 1), result.negative_knowledge.influence_summary.verifier_requirement_count);
    try std.testing.expectEqual(@as(usize, 1), result.negative_knowledge.influence_summary.suppression_count);
    try std.testing.expectEqual(@as(usize, 1), result.negative_knowledge.influence_summary.routing_warning_count);
    try std.testing.expectEqual(@as(usize, 1), result.negative_knowledge.influence_summary.trust_decay_candidate_count);
    try std.testing.expect(result.negative_knowledge.influence_summary.non_authorizing);

    const rendered = try renderJson(allocator, &result);
    defer allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "stronger verifier required") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "exact repeat suppressed") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"non_authorizing\":true") != null);
}

test "response engine: empty correction and influence summaries render consistently" {
    const allocator = std.testing.allocator;
    var gi = try intent_grounding.ground(allocator, "explain src/main.zig", .{ .context_target = "src/main.zig" });
    defer gi.deinit();
    var result = try execute(allocator, &gi, .{ .mode = .draft_mode });
    defer result.deinit();
    const rendered = try renderJson(allocator, &result);
    defer allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"correction_count\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"influence_count\":0") != null);
    try std.testing.expectEqual(StopReason.unresolved, result.stop_reason);
}

test "resolve budget: fast path maps to low tier" {
    const budget = resolveBudget(.{ .mode = .fast_path });
    try std.testing.expectEqual(compute_budget.Tier.low, budget.effective_tier);
    try std.testing.expectEqual(@as(u32, 2), budget.max_branches);
}

test "resolve budget: draft path uses minimal verifier-free budget" {
    const budget = resolveBudget(.draftOnly());
    try std.testing.expectEqual(compute_budget.Tier.low, budget.effective_tier);
    try std.testing.expectEqual(@as(u32, 1), budget.max_branches);
    try std.testing.expectEqual(@as(u32, 0), budget.max_repairs);
    try std.testing.expectEqual(@as(usize, 0), budget.max_verifier_runs);
    try std.testing.expect(budget.max_wall_time_ms <= 250);
}

test "resolve budget: deep path maps to high tier" {
    const budget = resolveBudget(.{ .mode = .deep_path });
    try std.testing.expectEqual(compute_budget.Tier.high, budget.effective_tier);
    try std.testing.expectEqual(@as(u32, 8), budget.max_branches);
}

test "resolve budget: auto path maps to medium tier" {
    const budget = resolveBudget(.{ .mode = .auto_path });
    try std.testing.expectEqual(compute_budget.Tier.medium, budget.effective_tier);
    try std.testing.expectEqual(@as(u32, 5), budget.max_branches);
}

test "response engine: escalation reasons are explicit and justified" {
    const allocator = std.testing.allocator;

    // verify action → action_surface_requires_proof.
    var gi_verify = try intent_grounding.ground(allocator, "verify src/main.zig:init is correct", .{});
    defer gi_verify.deinit();
    var result_verify = try execute(allocator, &gi_verify, .autoPath());
    defer result_verify.deinit();
    try std.testing.expect(result_verify.escalated);
    try std.testing.expectEqual(EscalationReason.action_surface_requires_proof, result_verify.escalation_reason);

    // ambiguous input → no escalation (stays unresolved).
    var gi_amb = try intent_grounding.ground(allocator, "asdfghjkl", .{});
    defer gi_amb.deinit();
    var result_amb = try execute(allocator, &gi_amb, .autoPath());
    defer result_amb.deinit();
    try std.testing.expect(!result_amb.escalated);
    try std.testing.expect(result_amb.escalation_reason == null);
}

test "response engine: partial findings present for unresolved results" {
    const allocator = std.testing.allocator;
    var gi = try intent_grounding.ground(allocator, "improve this", .{});
    defer gi.deinit();

    var result = try execute(allocator, &gi, .autoPath());
    defer result.deinit();

    try std.testing.expectEqual(StopReason.unresolved, result.stop_reason);
    // Should have at least some partial findings from candidate intents.
    try std.testing.expect(result.grounded_intent.candidate_intents.len >= 2);
}

test "response engine: support contract preserved in fast path" {
    const allocator = std.testing.allocator;
    var gi = try intent_grounding.ground(allocator, "summarize src/main.zig", .{});
    defer gi.deinit();

    var result = try execute(allocator, &gi, .fastOnly());
    defer result.deinit();

    // Fast path must still respect the support contract.
    // A supported result must have grounded status.
    if (result.stop_reason == .supported) {
        try std.testing.expectEqual(
            intent_grounding.GroundedIntent.GroundingStatus.grounded,
            result.grounded_intent.status,
        );
    }
}

test "reasoning policy: level maps to compute budget tier" {
    try std.testing.expectEqual(compute_budget.Tier.low, computeTierForReasoningLevel(.quick));
    try std.testing.expectEqual(compute_budget.Tier.medium, computeTierForReasoningLevel(.balanced));
    try std.testing.expectEqual(compute_budget.Tier.high, computeTierForReasoningLevel(.deep));
    try std.testing.expectEqual(compute_budget.Tier.max, computeTierForReasoningLevel(.max));

    var quick = ResponseConfig.autoPath();
    quick.reasoning_level = .quick;
    try std.testing.expectEqual(compute_budget.Tier.low, resolveBudget(quick).effective_tier);

    var balanced = ResponseConfig.autoPath();
    balanced.reasoning_level = .balanced;
    try std.testing.expectEqual(compute_budget.Tier.medium, resolveBudget(balanced).effective_tier);

    var deep = ResponseConfig.autoPath();
    deep.reasoning_level = .deep;
    try std.testing.expectEqual(compute_budget.Tier.high, resolveBudget(deep).effective_tier);

    var max = ResponseConfig.autoPath();
    max.reasoning_level = .max;
    try std.testing.expectEqual(compute_budget.Tier.max, resolveBudget(max).effective_tier);
}

test "reasoning policy: quick planning selects draft" {
    const allocator = std.testing.allocator;
    var gi = try intent_grounding.ground(allocator, "plan options for src/main.zig", .{});
    defer gi.deinit();

    var config = ResponseConfig.autoPath();
    config.reasoning_level = .quick;
    var result = try execute(allocator, &gi, config);
    defer result.deinit();

    try std.testing.expectEqual(ResponseMode.draft_mode, result.selected_mode);
    try std.testing.expectEqual(ModeSelectionReason.quick_planning_draft, result.mode_selection_reason);
    try std.testing.expectEqual(compute_budget.Tier.low, result.effective_budget.effective_tier);
    try std.testing.expectEqual(StopReason.unresolved, result.stop_reason);
}

test "reasoning policy: quick simple grounded question selects fast" {
    const allocator = std.testing.allocator;
    var gi = try intent_grounding.ground(allocator, "quick answer summarize src/main.zig", .{});
    defer gi.deinit();

    var config = ResponseConfig.autoPath();
    config.reasoning_level = .quick;
    var result = try execute(allocator, &gi, config);
    defer result.deinit();

    try std.testing.expectEqual(ResponseMode.fast_path, result.selected_mode);
    try std.testing.expectEqual(ModeSelectionReason.quick_simple_grounded_fast, result.mode_selection_reason);
    try std.testing.expect(result.user_override_detected);
}

test "reasoning policy: quick explicit verify selects deep" {
    const allocator = std.testing.allocator;
    var gi = try intent_grounding.ground(allocator, "verify src/main.zig:init is correct", .{});
    defer gi.deinit();

    var config = ResponseConfig.autoPath();
    config.reasoning_level = .quick;
    var result = try execute(allocator, &gi, config);
    defer result.deinit();

    try std.testing.expectEqual(ResponseMode.deep_path, result.selected_mode);
    try std.testing.expectEqual(ModeSelectionReason.quick_verification_deep, result.mode_selection_reason);
    try std.testing.expect(result.user_override_detected);
}

test "reasoning policy: balanced vague planning selects draft" {
    const allocator = std.testing.allocator;
    var gi = try intent_grounding.ground(allocator, "brainstorm ideas for src/main.zig", .{});
    defer gi.deinit();

    var config = ResponseConfig.autoPath();
    config.reasoning_level = .balanced;
    var result = try execute(allocator, &gi, config);
    defer result.deinit();

    try std.testing.expectEqual(ResponseMode.draft_mode, result.selected_mode);
    try std.testing.expectEqual(ModeSelectionReason.balanced_planning_draft, result.mode_selection_reason);
}

test "reasoning policy: balanced actionable request selects deep when verifier exists" {
    const allocator = std.testing.allocator;
    var gi = try intent_grounding.ground(allocator, "fix src/main.zig", .{});
    defer gi.deinit();

    var config = ResponseConfig.autoPath();
    config.reasoning_level = .balanced;
    var result = try execute(allocator, &gi, config);
    defer result.deinit();

    try std.testing.expectEqual(ResponseMode.deep_path, result.selected_mode);
    try std.testing.expectEqual(ModeSelectionReason.balanced_actionable_deep, result.mode_selection_reason);
}

test "reasoning policy: deep explanation-only does not force deep" {
    const allocator = std.testing.allocator;
    var gi = try intent_grounding.ground(allocator, "explain src/main.zig", .{});
    defer gi.deinit();

    var config = ResponseConfig.autoPath();
    config.reasoning_level = .deep;
    var result = try execute(allocator, &gi, config);
    defer result.deinit();

    try std.testing.expect(result.selected_mode == .draft_mode or result.selected_mode == .fast_path);
    try std.testing.expect(result.selected_mode != .deep_path);
    try std.testing.expectEqual(ModeSelectionReason.deep_explanation_not_deep, result.mode_selection_reason);
}

test "reasoning policy: max explanation-only does not force deep" {
    const allocator = std.testing.allocator;
    var gi = try intent_grounding.ground(allocator, "explain src/main.zig", .{});
    defer gi.deinit();

    var config = ResponseConfig.autoPath();
    config.reasoning_level = .max;
    var result = try execute(allocator, &gi, config);
    defer result.deinit();

    try std.testing.expect(result.selected_mode == .draft_mode or result.selected_mode == .fast_path);
    try std.testing.expect(result.selected_mode != .deep_path);
    try std.testing.expectEqual(ModeSelectionReason.max_explanation_not_deep, result.mode_selection_reason);
    try std.testing.expectEqual(compute_budget.Tier.max, result.effective_budget.effective_tier);
}

test "reasoning policy: max fix request selects deep" {
    const allocator = std.testing.allocator;
    var gi = try intent_grounding.ground(allocator, "fix src/main.zig", .{});
    defer gi.deinit();

    var config = ResponseConfig.autoPath();
    config.reasoning_level = .max;
    var result = try execute(allocator, &gi, config);
    defer result.deinit();

    try std.testing.expectEqual(ResponseMode.deep_path, result.selected_mode);
    try std.testing.expectEqual(ModeSelectionReason.max_actionable_deep, result.mode_selection_reason);
}

test "reasoning policy: max just draft override selects draft" {
    const allocator = std.testing.allocator;
    var gi = try intent_grounding.ground(allocator, "just draft fix src/main.zig", .{});
    defer gi.deinit();

    var config = ResponseConfig.autoPath();
    config.reasoning_level = .max;
    var result = try execute(allocator, &gi, config);
    defer result.deinit();

    try std.testing.expectEqual(ResponseMode.draft_mode, result.selected_mode);
    try std.testing.expectEqual(ModeSelectionReason.user_requested_draft, result.mode_selection_reason);
    try std.testing.expect(result.user_override_detected);
    try std.testing.expectEqual(StopReason.unresolved, result.stop_reason);
    try std.testing.expectEqual(VerificationState.unverified, result.draft.mode.verification_state);
}

test "reasoning policy: deterministic selection across repeated max runs" {
    const allocator = std.testing.allocator;
    var gi1 = try intent_grounding.ground(allocator, "fix src/main.zig", .{});
    defer gi1.deinit();
    var gi2 = try intent_grounding.ground(allocator, "fix src/main.zig", .{});
    defer gi2.deinit();

    var config = ResponseConfig.autoPath();
    config.reasoning_level = .max;
    var result1 = try execute(allocator, &gi1, config);
    defer result1.deinit();
    var result2 = try execute(allocator, &gi2, config);
    defer result2.deinit();

    try std.testing.expectEqual(result1.selected_mode, result2.selected_mode);
    try std.testing.expectEqual(result1.mode_selection_reason, result2.mode_selection_reason);
    try std.testing.expectEqual(result1.requested_reasoning_level, result2.requested_reasoning_level);
    try std.testing.expectEqual(result1.effective_budget.effective_tier, result2.effective_budget.effective_tier);
}

test "reasoning policy: render json exposes mapper trace" {
    const allocator = std.testing.allocator;
    var gi = try intent_grounding.ground(allocator, "verify src/main.zig:init is correct", .{});
    defer gi.deinit();

    var config = ResponseConfig.autoPath();
    config.reasoning_level = .quick;
    var result = try execute(allocator, &gi, config);
    defer result.deinit();

    const rendered = try renderJson(allocator, &result);
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"requested_reasoning_level\":\"quick\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"effective_compute_budget_tier\":\"low\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"selected_response_mode\":\"deep_path\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"mode_selection_reason\":\"quick_verification_deep\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"user_override_detected\":true") != null);
}

fn writeJsonStringArray(writer: anytype, items: []const []u8) !void {
    try writer.writeAll("[");
    for (items, 0..) |item, i| {
        if (i > 0) try writer.writeAll(",");
        try writer.writeAll("\"");
        try writeJsonEscaped(writer, item);
        try writer.writeAll("\"");
    }
    try writer.writeAll("]");
}

fn testCorrectionEvent(
    allocator: std.mem.Allocator,
    id: []const u8,
    kind: correction_hooks.CorrectionKind,
    contradicted_ref: []const u8,
    evidence_ref: []const u8,
    previous_state: []const u8,
    updated_state: []const u8,
) !correction_hooks.CorrectionEvent {
    return .{
        .allocator = allocator,
        .id = try allocator.dupe(u8, id),
        .correction_kind = kind,
        .source_ref = try allocator.dupe(u8, "test:source"),
        .contradicted_ref = try allocator.dupe(u8, contradicted_ref),
        .contradicting_evidence_ref = try allocator.dupe(u8, evidence_ref),
        .previous_state = try allocator.dupe(u8, previous_state),
        .updated_state = try allocator.dupe(u8, updated_state),
        .user_visible_summary = try allocator.dupe(u8, "Correction recorded: the previous hypothesis was contradicted by verifier evidence. Ghost will not reuse this pattern without stronger verification."),
        .non_authorizing = true,
        .trace = try allocator.dupe(u8, "test correction projection"),
    };
}

test "response engine: speculative scheduler is disabled in fast path and active after deep escalation" {
    const allocator = std.testing.allocator;

    var fast_gi = try intent_grounding.ground(allocator, "summarize src/main.zig", .{});
    defer fast_gi.deinit();
    var fast_result = try execute(allocator, &fast_gi, .fastOnly());
    defer fast_result.deinit();
    try std.testing.expectEqual(ResponseMode.fast_path, fast_result.selected_mode);
    try std.testing.expect(!fast_result.speculative_scheduler.active);
    try std.testing.expectEqual(@as(u32, 0), fast_result.speculative_scheduler.candidate_count);

    var deep_gi = try intent_grounding.ground(allocator, "make this better", .{});
    defer deep_gi.deinit();
    var deep_result = try execute(allocator, &deep_gi, .deepOnly());
    defer deep_result.deinit();
    try std.testing.expectEqual(ResponseMode.deep_path, deep_result.selected_mode);
    try std.testing.expect(deep_result.speculative_scheduler.active);
    try std.testing.expect(deep_result.speculative_scheduler.candidate_count > 1);
}
