const std = @import("std");
const task_intent = @import("task_intent.zig");
const artifact_schema = @import("artifact_schema.zig");
const vsa_vulkan = @import("vsa_vulkan.zig");

// ──────────────────────────────────────────────────────────────────────────
// Intent Grounding v2
//
// Handles vague, underspecified, or "lazy" user requests without guessing
// or hallucinating, by grounding intent into explicit, bounded
// interpretations tied to artifacts, schemas, and obligations.
//
// Guarantees:
//   - deterministic behavior
//   - support/proof contract preserved
//   - unresolved on insufficient support
//   - no transformer-style guessing
// ──────────────────────────────────────────────────────────────────────────

pub const MAX_CANDIDATES: usize = 8;
pub const MAX_AMBIGUITY_SETS: usize = 8;
pub const MAX_ARTIFACT_BINDINGS: usize = 8;
pub const MAX_INTENT_OBLIGATIONS: usize = 16;
pub const MAX_ACTION_SURFACES: usize = 8;
pub const MAX_MISSING_OBLIGATIONS: usize = 8;
pub const MAX_GROUNDING_TRACES: usize = 16;
pub const MAX_INPUT_BYTES: usize = 512;
pub const LATENT_VECTOR_DIMS: usize = 8;

const HEAVY_TASK_THRESHOLD: f32 = 0.70;

// ── Intent Classification ──────────────────────────────────────────────

/// Deterministic classification of user input into intent categories.
/// Ties produce ambiguity_sets, not guesses.
pub const IntentClass = enum {
    conversation,
    direct_action,
    transformation,
    diagnostic,
    creation,
    verification,
    ambiguous,
};

pub const GeneralistRoute = enum {
    general_chat,
    strict_verification,
};

pub const LatentConcept = enum {
    conversation,
    modification,
    retrieval,
    meta_analysis,
};

const LatentIntentMatch = struct {
    concept: LatentConcept,
    similarity: f32,
    strong_heavy_task: bool,
    vector: [LATENT_VECTOR_DIMS]f32,
};

pub const IntentConfidence = struct {
    concept: LatentConcept,
    score: f32,
    strong_heavy_task: bool,
};

/// Scope of the intent — how wide its effect surface is.
pub const IntentScope = enum {
    artifact_local,
    cross_artifact,
    global,
};

/// How an artifact was bound to the intent.
pub const BindingSource = enum {
    explicit_reference,
    implicit_context,
    pack_based,
};

/// An artifact bound to an intent.
pub const ArtifactBinding = struct {
    artifact_id: []u8,
    source: BindingSource,
    schema_name: []u8,
    confidence: u16,

    pub fn deinit(self: *ArtifactBinding, allocator: std.mem.Allocator) void {
        allocator.free(self.artifact_id);
        allocator.free(self.schema_name);
        self.* = undefined;
    }

    pub fn clone(self: ArtifactBinding, allocator: std.mem.Allocator) !ArtifactBinding {
        return .{
            .artifact_id = try allocator.dupe(u8, self.artifact_id),
            .source = self.source,
            .schema_name = try allocator.dupe(u8, self.schema_name),
            .confidence = self.confidence,
        };
    }
};

/// An inferred constraint attached to an intent.
pub const GroundedConstraint = struct {
    kind: task_intent.ConstraintKind,
    value: ?[]u8 = null,
    source: ConstraintSource,
    detail: ?[]u8 = null,

    pub const ConstraintSource = enum {
        user_explicit,
        inferred_preserve_behavior,
        inferred_preserve_structure,
        from_schema,
        from_verifier,
    };

    pub fn deinit(self: *GroundedConstraint, allocator: std.mem.Allocator) void {
        if (self.value) |v| allocator.free(v);
        if (self.detail) |d| allocator.free(d);
        self.* = undefined;
    }

    pub fn clone(self: GroundedConstraint, allocator: std.mem.Allocator) !GroundedConstraint {
        return .{
            .kind = self.kind,
            .value = if (self.value) |v| try allocator.dupe(u8, v) else null,
            .source = self.source,
            .detail = if (self.detail) |d| try allocator.dupe(u8, d) else null,
        };
    }
};

/// An obligation produced by intent grounding. Conversational reasoning may
/// have no obligations; artifact-changing/retrieval/verifier work must expose
/// the missing binding or proof obligations that block support.
pub const IntentObligation = struct {
    id: []u8,
    label: []u8,
    scope: []u8,
    pending: bool = true,
    resolved_by: ?[]u8 = null,
    detail: ?[]u8 = null,

    pub fn deinit(self: *IntentObligation, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.label);
        allocator.free(self.scope);
        if (self.resolved_by) |r| allocator.free(r);
        if (self.detail) |d| allocator.free(d);
        self.* = undefined;
    }

    pub fn clone(self: IntentObligation, allocator: std.mem.Allocator) !IntentObligation {
        return .{
            .id = try allocator.dupe(u8, self.id),
            .label = try allocator.dupe(u8, self.label),
            .scope = try allocator.dupe(u8, self.scope),
            .pending = self.pending,
            .resolved_by = if (self.resolved_by) |r| try allocator.dupe(u8, r) else null,
            .detail = if (self.detail) |d| try allocator.dupe(u8, d) else null,
        };
    }
};

/// A candidate interpretation of a vague request. Each candidate has an
/// explicit action surface, scope, and obligations — never a guess.
pub const CandidateIntent = struct {
    action_surface: artifact_schema.ActionSurface,
    label: []u8,
    scope: IntentScope,
    obligations: []IntentObligation = &.{},
    reason: []u8,
    viable: bool = true,

    pub fn deinit(self: *CandidateIntent, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
        allocator.free(self.reason);
        for (self.obligations) |*obl| obl.deinit(allocator);
        allocator.free(self.obligations);
        self.* = undefined;
    }

    pub fn clone(self: *const CandidateIntent, allocator: std.mem.Allocator) !CandidateIntent {
        var obligations = std.ArrayList(IntentObligation).init(allocator);
        errdefer {
            for (obligations.items) |*o| o.deinit(allocator);
            obligations.deinit();
        }
        for (self.obligations) |obl| {
            try obligations.append(try obl.clone(allocator));
        }
        return .{
            .action_surface = self.action_surface,
            .label = try allocator.dupe(u8, self.label),
            .scope = self.scope,
            .obligations = try obligations.toOwnedSlice(),
            .reason = try allocator.dupe(u8, self.reason),
            .viable = self.viable,
        };
    }
};

/// An ambiguity set: multiple valid interpretations that must be resolved
/// before the intent can progress to supported.
/// NOTE: candidates are referenced by index into GroundedIntent.candidate_intents.
/// The AmbiguitySet does NOT own the candidates — GroundedIntent does.
pub const AmbiguitySet = struct {
    /// Indices into GroundedIntent.candidate_intents.
    candidate_indices: []usize = &.{},
    reason: []u8,
    obligation_to_resolve: []u8,

    pub fn deinit(self: *AmbiguitySet, allocator: std.mem.Allocator) void {
        allocator.free(self.candidate_indices);
        allocator.free(self.reason);
        allocator.free(self.obligation_to_resolve);
        self.* = undefined;
    }

    pub fn clone(self: *const AmbiguitySet, allocator: std.mem.Allocator) !AmbiguitySet {
        const indices = try allocator.dupe(usize, self.candidate_indices);
        errdefer allocator.free(indices);
        return .{
            .candidate_indices = indices,
            .reason = try allocator.dupe(u8, self.reason),
            .obligation_to_resolve = try allocator.dupe(u8, self.obligation_to_resolve),
        };
    }
};

/// A missing obligation — something the user must provide or the system
/// must resolve before the intent can be grounded.
pub const MissingObligation = struct {
    id: []u8,
    label: []u8,
    required_for: []u8,

    pub fn deinit(self: *MissingObligation, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.label);
        allocator.free(self.required_for);
        self.* = undefined;
    }

    pub fn clone(self: *const MissingObligation, allocator: std.mem.Allocator) !MissingObligation {
        return .{
            .id = try allocator.dupe(u8, self.id),
            .label = try allocator.dupe(u8, self.label),
            .required_for = try allocator.dupe(u8, self.required_for),
        };
    }
};

/// A grounding trace step — tracks each interpretation decision.
pub const GroundingTrace = struct {
    step: []u8,
    input: []u8,
    output: []u8,
    detail: ?[]u8 = null,

    pub fn deinit(self: *GroundingTrace, allocator: std.mem.Allocator) void {
        allocator.free(self.step);
        allocator.free(self.input);
        allocator.free(self.output);
        if (self.detail) |d| allocator.free(d);
        self.* = undefined;
    }

    pub fn clone(self: *const GroundingTrace, allocator: std.mem.Allocator) !GroundingTrace {
        return .{
            .step = try allocator.dupe(u8, self.step),
            .input = try allocator.dupe(u8, self.input),
            .output = try allocator.dupe(u8, self.output),
            .detail = if (self.detail) |d| try allocator.dupe(u8, d) else null,
        };
    }
};

/// The result of intent grounding v2. Contains either a fully grounded
/// intent (fast path) or a partial grounding with ambiguity sets and
/// missing obligations (partial mode).
pub const GroundedIntent = struct {
    allocator: std.mem.Allocator,
    status: GroundingStatus = .unresolved,
    intent_class: IntentClass = .ambiguous,
    scope: IntentScope = .artifact_local,

    /// The original raw input.
    raw_input: []u8,
    /// Tokenized/structured normalized form.
    normalized_form: []u8,

    /// Base task from v1 parsing.
    base_task: task_intent.Task,

    /// Artifacts bound to this intent.
    artifact_bindings: []ArtifactBinding = &.{},
    /// Action surfaces extracted from schema + intent.
    action_surfaces: []artifact_schema.ActionSurface = &.{},
    /// Constraints (explicit + inferred + schema).
    constraints: []GroundedConstraint = &.{},
    /// Obligations produced by the intent.
    obligations: []IntentObligation = &.{},

    /// Ambiguity sets — multiple valid interpretations.
    ambiguity_sets: []AmbiguitySet = &.{},
    /// Missing obligations — user must provide.
    missing_obligations: []MissingObligation = &.{},

    /// Candidate interpretations for vague requests.
    candidate_intents: []CandidateIntent = &.{},

    /// Abstract primitives consumed by the ontological router.
    ontological_primitives: []OntologyPrimitive = &.{},

    /// Grounding traces for audit.
    traces: []GroundingTrace = &.{},

    /// Fast path: true if intent is unambiguous, fully bound, low obligation cost.
    fast_path_eligible: bool = false,

    pub const GroundingStatus = enum {
        grounded,
        partially_grounded,
        unresolved,
    };

    pub fn deinit(self: *GroundedIntent) void {
        self.allocator.free(self.raw_input);
        self.allocator.free(self.normalized_form);
        self.base_task.deinit();
        for (self.artifact_bindings) |*ab| ab.deinit(self.allocator);
        self.allocator.free(self.artifact_bindings);
        self.allocator.free(self.action_surfaces);
        for (self.constraints) |*c| c.deinit(self.allocator);
        self.allocator.free(self.constraints);
        for (self.obligations) |*o| o.deinit(self.allocator);
        self.allocator.free(self.obligations);
        for (self.ambiguity_sets) |*as| as.deinit(self.allocator);
        self.allocator.free(self.ambiguity_sets);
        for (self.missing_obligations) |*mo| mo.deinit(self.allocator);
        self.allocator.free(self.missing_obligations);
        for (self.candidate_intents) |*ci| ci.deinit(self.allocator);
        self.allocator.free(self.candidate_intents);
        freeOntologicalPrimitives(self.allocator, self.ontological_primitives);
        for (self.traces) |*t| t.deinit(self.allocator);
        self.allocator.free(self.traces);
        self.* = undefined;
    }

    pub fn clone(self: *const GroundedIntent, allocator: std.mem.Allocator) !GroundedIntent {
        const raw_input = try allocator.dupe(u8, self.raw_input);
        errdefer allocator.free(raw_input);
        const normalized_form = try allocator.dupe(u8, self.normalized_form);
        errdefer allocator.free(normalized_form);
        const base_task = try self.base_task.clone(allocator);

        var artifact_bindings = std.ArrayList(ArtifactBinding).init(allocator);
        errdefer {
            for (artifact_bindings.items) |*ab| ab.deinit(allocator);
            artifact_bindings.deinit();
        }
        for (self.artifact_bindings) |ab| {
            try artifact_bindings.append(try ab.clone(allocator));
        }

        const action_surfaces = try allocator.dupe(artifact_schema.ActionSurface, self.action_surfaces);
        errdefer allocator.free(action_surfaces);

        var constraints = std.ArrayList(GroundedConstraint).init(allocator);
        errdefer {
            for (constraints.items) |*c| c.deinit(allocator);
            constraints.deinit();
        }
        for (self.constraints) |c| {
            try constraints.append(try c.clone(allocator));
        }

        var obligations = std.ArrayList(IntentObligation).init(allocator);
        errdefer {
            for (obligations.items) |*o| o.deinit(allocator);
            obligations.deinit();
        }
        for (self.obligations) |o| {
            try obligations.append(try o.clone(allocator));
        }

        var ambiguity_sets = std.ArrayList(AmbiguitySet).init(allocator);
        errdefer {
            for (ambiguity_sets.items) |*as| as.deinit(allocator);
            ambiguity_sets.deinit();
        }
        for (self.ambiguity_sets) |as| {
            try ambiguity_sets.append(try as.clone(allocator));
        }

        var missing_obligations = std.ArrayList(MissingObligation).init(allocator);
        errdefer {
            for (missing_obligations.items) |*mo| mo.deinit(allocator);
            missing_obligations.deinit();
        }
        for (self.missing_obligations) |mo| {
            try missing_obligations.append(try mo.clone(allocator));
        }

        var candidate_intents = std.ArrayList(CandidateIntent).init(allocator);
        errdefer {
            for (candidate_intents.items) |*ci| ci.deinit(allocator);
            candidate_intents.deinit();
        }
        for (self.candidate_intents) |ci| {
            try candidate_intents.append(try ci.clone(allocator));
        }

        var ontological_primitives = std.ArrayList(OntologyPrimitive).init(allocator);
        errdefer {
            for (ontological_primitives.items) |*primitive| primitive.deinit(allocator);
            ontological_primitives.deinit();
        }
        for (self.ontological_primitives) |primitive| {
            try ontological_primitives.append(try primitive.clone(allocator));
        }

        var traces = std.ArrayList(GroundingTrace).init(allocator);
        errdefer {
            for (traces.items) |*t| t.deinit(allocator);
            traces.deinit();
        }
        for (self.traces) |t| {
            try traces.append(try t.clone(allocator));
        }

        return .{
            .allocator = allocator,
            .status = self.status,
            .intent_class = self.intent_class,
            .scope = self.scope,
            .raw_input = raw_input,
            .normalized_form = normalized_form,
            .base_task = base_task,
            .artifact_bindings = try artifact_bindings.toOwnedSlice(),
            .action_surfaces = action_surfaces,
            .constraints = try constraints.toOwnedSlice(),
            .obligations = try obligations.toOwnedSlice(),
            .ambiguity_sets = try ambiguity_sets.toOwnedSlice(),
            .missing_obligations = try missing_obligations.toOwnedSlice(),
            .candidate_intents = try candidate_intents.toOwnedSlice(),
            .ontological_primitives = try ontological_primitives.toOwnedSlice(),
            .traces = try traces.toOwnedSlice(),
            .fast_path_eligible = self.fast_path_eligible,
        };
    }
};

// ── Options ────────────────────────────────────────────────────────────

pub const GroundingOptions = struct {
    context_target: ?[]const u8 = null,
    /// Known artifact ids in the current scope.
    available_artifacts: []const []const u8 = &.{},
    /// Schema registry for artifact-based constraint extraction.
    schema_registry: ?*const artifact_schema.SchemaRegistry = null,
};

pub const OntologyRole = enum {
    target,
    action,
    constraint,
    evidence,
    primitive,
};

pub const OntologyConcept = enum {
    target_system_component,
    target_knowledge_sequence,
    target_artifact,
    action_verify_integrity,
    action_explain,
    action_transform,
    action_synthesize,
    constraint_local_axioms,
    constraint_chronological_consistency,
    constraint_no_external_authority,
    evidence_cpp_component,
    evidence_omni_codex,
    evidence_cpp_smart_pointers,
    constraint_ownership_axioms,
    primitive_existence,
    primitive_ownership,
    primitive_null_state,
};

pub const OntologyPrimitive = struct {
    role: OntologyRole,
    concept: OntologyConcept,
    source: []u8,
    confidence: u16,

    pub fn deinit(self: *OntologyPrimitive, allocator: std.mem.Allocator) void {
        allocator.free(self.source);
        self.* = undefined;
    }

    pub fn clone(self: OntologyPrimitive, allocator: std.mem.Allocator) !OntologyPrimitive {
        return .{
            .role = self.role,
            .concept = self.concept,
            .source = try allocator.dupe(u8, self.source),
            .confidence = self.confidence,
        };
    }
};

pub const MAX_SALIENCE_RUNES: usize = 48;

pub const SalienceRune = struct {
    text: []u8,
    start: usize,
    end: usize,
    semantic_score: u16,
    structural_score: u16,
    selected_target: bool = false,
};

pub const SalienceMap = struct {
    semantic_target: []u8,
    structural_noise: []u8,
    density_multiplier: u8,
    target_score: u16,
    structural_noise_score: u16,
    runes: []SalienceRune,

    pub fn deinit(self: *SalienceMap, allocator: std.mem.Allocator) void {
        allocator.free(self.semantic_target);
        allocator.free(self.structural_noise);
        for (self.runes) |rune| allocator.free(rune.text);
        allocator.free(self.runes);
        self.* = undefined;
    }
};

pub const ImperativeTargetKind = enum {
    none,
    exact,
    vague,
};

pub const ImperativeIntent = struct {
    detected: bool = false,
    target_kind: ImperativeTargetKind = .none,
    target: []u8 = &.{},
    negative_constraint: []u8 = &.{},
    references_previous_output: bool = false,
    strict_output: bool = false,
    positional_score: u16 = 0,

    pub fn deinit(self: *ImperativeIntent, allocator: std.mem.Allocator) void {
        if (self.target.len != 0) allocator.free(self.target);
        if (self.negative_constraint.len != 0) allocator.free(self.negative_constraint);
        self.* = undefined;
    }
};

pub fn analyzeSalience(allocator: std.mem.Allocator, input: []const u8) !SalienceMap {
    var runes = std.ArrayList(SalienceRune).init(allocator);
    errdefer {
        for (runes.items) |rune| allocator.free(rune.text);
        runes.deinit();
    }
    try tokenizeSalienceRunes(allocator, input, &runes);

    if (runes.items.len == 0) {
        return .{
            .semantic_target = try allocator.dupe(u8, std.mem.trim(u8, input, " \r\n\t")),
            .structural_noise = try allocator.dupe(u8, ""),
            .density_multiplier = 1,
            .target_score = 0,
            .structural_noise_score = 0,
            .runes = try runes.toOwnedSlice(),
        };
    }

    scoreSalienceRunes(runes.items);
    const window = if (isDefinitionContentQuery(input))
        chooseResonantContentWindow(runes.items) orelse chooseSemanticWindow(runes.items)
    else
        chooseSemanticWindow(runes.items);
    var target_score_total: usize = 0;
    var noise_score_total: usize = 0;
    var target_count: usize = 0;
    var noise_count: usize = 0;
    for (runes.items, 0..) |*rune, idx| {
        rune.selected_target = idx >= window.start and idx < window.end;
        if (rune.selected_target) {
            target_score_total += rune.semantic_score;
            target_count += 1;
        } else {
            noise_score_total += rune.structural_score;
            noise_count += 1;
        }
    }

    const semantic_target = try joinSelectedSalienceRunes(allocator, runes.items, true);
    errdefer allocator.free(semantic_target);
    const structural_noise = try joinSelectedSalienceRunes(allocator, runes.items, false);
    errdefer allocator.free(structural_noise);

    const avg_target: u16 = if (target_count == 0) 0 else @intCast(@min(@as(usize, 1000), target_score_total / target_count));
    const avg_noise: u16 = if (noise_count == 0) 0 else @intCast(@min(@as(usize, 1000), noise_score_total / noise_count));
    const density_multiplier = densityMultiplier(noise_count, avg_noise);

    return .{
        .semantic_target = semantic_target,
        .structural_noise = structural_noise,
        .density_multiplier = density_multiplier,
        .target_score = avg_target,
        .structural_noise_score = avg_noise,
        .runes = try runes.toOwnedSlice(),
    };
}

const PositionalRune = struct {
    text: []const u8,
    start: usize,
    end: usize,
};

pub fn analyzeImperativeIntent(allocator: std.mem.Allocator, input: []const u8) !ImperativeIntent {
    const trimmed = std.mem.trim(u8, input, " \r\n\t");
    if (trimmed.len == 0 or std.mem.indexOfScalar(u8, trimmed, '?') != null) return .{};
    if (startsWithQuestionRune(trimmed)) return .{};
    if (isDefinitionContentQuery(trimmed)) return .{};

    const global_match = vsa_vulkan.globalRuneMatch(trimmed);
    if (global_match.commandOverridesTokenizer()) {
        return .{
            .detected = true,
            .target_kind = .exact,
            .target = try allocator.dupe(u8, global_match.command_target),
            .strict_output = true,
            .positional_score = global_match.command.score_per_mille,
        };
    }

    var runes = std.ArrayList(PositionalRune).init(allocator);
    defer runes.deinit();
    tokenizePositionalRunes(trimmed, &runes);
    if (runes.items.len < 2) return .{};

    const initial = runes.items[0];
    if (!isHighActionRuneSequence(initial.text)) return .{};

    var target_kind: ImperativeTargetKind = .none;
    var target: []u8 = &.{};
    var strict_output = false;
    var isolation_score: u16 = 0;

    if (try isolatedQuotedOrBracketedTarget(allocator, trimmed)) |isolated| {
        target = isolated;
        target_kind = .exact;
        strict_output = true;
        isolation_score = 620;
    } else if (try isolatedObjectMarkerTarget(allocator, trimmed, runes.items)) |isolated| {
        target = isolated;
        target_kind = .exact;
        strict_output = true;
        isolation_score = 590;
    } else if (try isolatedOnlyTarget(allocator, trimmed, runes.items)) |isolated| {
        target = isolated;
        target_kind = .exact;
        strict_output = true;
        isolation_score = 560;
    } else if (singleCompactTailTarget(trimmed, runes.items)) |tail| {
        target = try allocator.dupe(u8, tail);
        target_kind = .exact;
        strict_output = true;
        isolation_score = 390;
    }

    var negative_constraint: []u8 = &.{};
    const negation = try extractNegationConstraint(allocator, trimmed, runes.items);
    if (negation.constraint.len != 0 or negation.references_previous) {
        negative_constraint = negation.constraint;
        if (target.len == 0) {
            target = try allocator.dupe(u8, "something");
            target_kind = .vague;
        }
        isolation_score = @max(isolation_score, 620);
    }

    const positional_score = imperativePositionalScore(initial, runes.items.len, isolation_score);
    if (positional_score < 700) {
        if (target.len != 0) allocator.free(target);
        if (negative_constraint.len != 0) allocator.free(negative_constraint);
        return .{};
    }

    return .{
        .detected = true,
        .target_kind = target_kind,
        .target = target,
        .negative_constraint = negative_constraint,
        .references_previous_output = negation.references_previous,
        .strict_output = strict_output,
        .positional_score = positional_score,
    };
}

pub fn lacksSemanticTarget(input: []const u8) bool {
    if (isDefinitionContentQuery(input) and vsa_vulkan.globalRuneMatch(input).contentOverridesEntropy()) return false;

    var meaningful_runes: usize = 0;
    var start: ?usize = null;
    var idx: usize = 0;
    while (idx <= input.len) : (idx += 1) {
        const at_end = idx == input.len;
        const byte = if (at_end) 0 else input[idx];
        if (!at_end and isSalienceRuneByte(byte)) {
            if (start == null) start = idx;
            continue;
        }
        if (start) |s| {
            const token = std.mem.trim(u8, input[s..idx], "_-");
            if (isSemanticSignalRune(token)) meaningful_runes += 1;
            start = null;
        }
    }
    return meaningful_runes == 0;
}

pub fn routeGeneralistIntent(input: []const u8) GeneralistRoute {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const primitives = extractOntologicalPrimitives(arena.allocator(), input) catch return .general_chat;
    if (ontologicalRouteRequiresVerifier(primitives)) return .strict_verification;
    return .general_chat;
}

pub fn isStrictVerificationPrompt(input: []const u8) bool {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const primitives = extractOntologicalPrimitives(arena.allocator(), input) catch return false;
    return ontologicalRouteRequiresVerifier(primitives);
}

pub fn extractOntologicalPrimitives(allocator: std.mem.Allocator, input: []const u8) ![]OntologyPrimitive {
    var primitives = std.ArrayList(OntologyPrimitive).init(allocator);
    errdefer {
        for (primitives.items) |*primitive| primitive.deinit(allocator);
        primitives.deinit();
    }

    const trimmed = std.mem.trim(u8, input, " \r\n\t");
    if (trimmed.len == 0) return primitives.toOwnedSlice();

    if (hasVerificationConcept(trimmed)) {
        try appendOntologyPrimitive(allocator, &primitives, .action, .action_verify_integrity, matchedOntologySource(trimmed, &.{ "verify", "validate", "check", "audit", "test", "prove", "confirm", "logical consistency" }) orelse "verify", 930);
    }
    if (hasTransformConcept(trimmed)) {
        try appendOntologyPrimitive(allocator, &primitives, .action, .action_transform, matchedOntologySource(trimmed, &.{ "make", "improve", "refactor", "fix", "patch", "change", "modify", "optimize" }) orelse "transform", 760);
    }
    if (hasExplainConcept(trimmed)) {
        try appendOntologyPrimitive(allocator, &primitives, .action, .action_explain, matchedOntologySource(trimmed, &.{ "explain", "why", "summarize", "describe" }) orelse "explain", 720);
    }
    if (hasSynthesisConcept(trimmed)) {
        try appendOntologyPrimitive(allocator, &primitives, .action, .action_synthesize, matchedOntologySource(trimmed, &.{ "generate", "write", "create", "draft", "synthesize" }) orelse "synthesize", 720);
    }

    if (hasExistencePrimitive(trimmed)) {
        try appendOntologyPrimitive(allocator, &primitives, .primitive, .primitive_existence, matchedOntologySource(trimmed, &.{ "existence", "exists", "memory address", "address" }) orelse "existence", 900);
    }
    if (hasOwnershipPrimitive(trimmed)) {
        try appendOntologyPrimitive(allocator, &primitives, .primitive, .primitive_ownership, matchedOntologySource(trimmed, &.{ "ownership", "owner", "owned" }) orelse "ownership", 930);
    }
    if (hasNullStatePrimitive(trimmed)) {
        try appendOntologyPrimitive(allocator, &primitives, .primitive, .primitive_null_state, matchedOntologySource(trimmed, &.{ "null_state", "null state", "without an owner", "dangling" }) orelse "null state", 910);
    }

    if (hasSystemComponentConcept(trimmed)) {
        try appendOntologyPrimitive(allocator, &primitives, .target, .target_system_component, matchedSystemComponentSource(trimmed) orelse "system component", 930);
        if (hasCppComponentEvidence(trimmed)) {
            try appendOntologyPrimitive(allocator, &primitives, .evidence, .evidence_cpp_component, matchedOntologySource(trimmed, &.{ ".cpp", ".cc", ".cxx", ".hpp", ".hh", ".hxx", "c++", "cpp" }) orelse "cpp component", 900);
        }
    } else if (hasArtifactConcept(trimmed)) {
        try appendOntologyPrimitive(allocator, &primitives, .target, .target_artifact, matchedOntologySource(trimmed, &.{ "artifact", "workspace", "source file", "file" }) orelse "artifact", 760);
    }

    if (hasKnowledgeSequenceConcept(trimmed)) {
        try appendOntologyPrimitive(allocator, &primitives, .target, .target_knowledge_sequence, matchedOntologySource(trimmed, &.{ "timeline", "chronology", "chronological", "historical", "sequence" }) orelse "knowledge sequence", 900);
    }

    if (hasLocalAxiomConcept(trimmed) or (hasOntologyConcept(primitives.items, .action_verify_integrity) and hasOntologyConcept(primitives.items, .target_system_component))) {
        try appendOntologyPrimitive(allocator, &primitives, .constraint, .constraint_local_axioms, matchedOntologySource(trimmed, &.{ "local axiom", "local axioms", "axiom", "compiler", "compile", "verifier" }) orelse "local axioms", 880);
    }
    if (hasOwnershipAxiomConcept(trimmed)) {
        try appendOntologyPrimitive(allocator, &primitives, .constraint, .constraint_ownership_axioms, matchedOntologySource(trimmed, &.{ "ownership_axioms", "ownership axioms" }) orelse "ownership axioms", 900);
    }
    if (hasCppSmartPointerConcept(trimmed)) {
        try appendOntologyPrimitive(allocator, &primitives, .evidence, .evidence_cpp_smart_pointers, matchedOntologySource(trimmed, &.{ "c++_smart_pointers", "c++ smart pointers", "smart pointers" }) orelse "c++ smart pointers", 900);
        try appendOntologyPrimitive(allocator, &primitives, .evidence, .evidence_cpp_component, "c++ smart pointers", 860);
    }
    if (hasChronologyConcept(trimmed) or (hasOntologyConcept(primitives.items, .action_verify_integrity) and hasOntologyConcept(primitives.items, .target_knowledge_sequence))) {
        try appendOntologyPrimitive(allocator, &primitives, .constraint, .constraint_chronological_consistency, matchedOntologySource(trimmed, &.{ "timeline", "chronology", "chronological", "logical consistency", "historical" }) orelse "chronological consistency", 900);
    }
    if (hasOmniCodexConcept(trimmed)) {
        try appendOntologyPrimitive(allocator, &primitives, .evidence, .evidence_omni_codex, matchedOntologySource(trimmed, &.{ "omni-codex", "omni codex", "corpus", "codex" }) orelse "omni-codex", 820);
    }
    if (hasLocalOnlyConstraint(trimmed)) {
        try appendOntologyPrimitive(allocator, &primitives, .constraint, .constraint_no_external_authority, matchedOntologySource(trimmed, &.{ "local", "offline", "no network", "no external" }) orelse "local only", 760);
    }

    return primitives.toOwnedSlice();
}

pub fn freeOntologicalPrimitives(allocator: std.mem.Allocator, primitives: []OntologyPrimitive) void {
    if (primitives.len == 0) return;
    for (primitives) |*primitive| primitive.deinit(allocator);
    allocator.free(primitives);
}

pub fn hasOntologyConcept(primitives: []const OntologyPrimitive, concept: OntologyConcept) bool {
    for (primitives) |primitive| {
        if (primitive.concept == concept) return true;
    }
    return false;
}

pub fn ontologyConceptName(concept: OntologyConcept) []const u8 {
    return switch (concept) {
        .target_system_component => "target.system_component",
        .target_knowledge_sequence => "target.knowledge_sequence",
        .target_artifact => "target.artifact",
        .action_verify_integrity => "action.verify_integrity",
        .action_explain => "action.explain",
        .action_transform => "action.transform",
        .action_synthesize => "action.synthesize",
        .constraint_local_axioms => "constraint.local_axioms",
        .constraint_chronological_consistency => "constraint.chronological_consistency",
        .constraint_no_external_authority => "constraint.no_external_authority",
        .evidence_cpp_component => "evidence.cpp_component",
        .evidence_omni_codex => "evidence.omni_codex",
        .evidence_cpp_smart_pointers => "evidence.cpp_smart_pointers",
        .constraint_ownership_axioms => "constraint.ownership_axioms",
        .primitive_existence => "primitive.existence",
        .primitive_ownership => "primitive.ownership",
        .primitive_null_state => "primitive.null_state",
    };
}

pub fn ontologyRoleName(role: OntologyRole) []const u8 {
    return @tagName(role);
}

pub fn ontologicalRouteRequiresVerifier(primitives: []const OntologyPrimitive) bool {
    if (!hasOntologyConcept(primitives, .action_verify_integrity)) return false;
    return hasOntologyConcept(primitives, .constraint_local_axioms) or
        hasOntologyConcept(primitives, .constraint_chronological_consistency);
}

fn appendOntologyPrimitive(
    allocator: std.mem.Allocator,
    primitives: *std.ArrayList(OntologyPrimitive),
    role: OntologyRole,
    concept: OntologyConcept,
    source: []const u8,
    confidence: u16,
) !void {
    if (hasOntologyConcept(primitives.items, concept)) return;
    try primitives.append(.{
        .role = role,
        .concept = concept,
        .source = try allocator.dupe(u8, source),
        .confidence = confidence,
    });
}

fn hasVerificationConcept(input: []const u8) bool {
    return hasAnyRouteSignal(input, &.{ "verify", "validate", "check", "audit", "test", "prove", "confirm", "logical consistency" });
}

fn hasExistencePrimitive(input: []const u8) bool {
    return hasAnyRouteSignal(input, &.{ "existence", "exists", "memory address", "address" });
}

fn hasOwnershipPrimitive(input: []const u8) bool {
    return hasAnyRouteSignal(input, &.{ "ownership", "owner", "owned" });
}

fn hasNullStatePrimitive(input: []const u8) bool {
    return hasAnyRouteSignal(input, &.{ "null_state", "null state", "without an owner", "dangling" });
}

fn hasOwnershipAxiomConcept(input: []const u8) bool {
    return hasAnyRouteSignal(input, &.{ "ownership_axioms", "ownership axioms" });
}

fn hasCppSmartPointerConcept(input: []const u8) bool {
    return hasAnyRouteSignal(input, &.{ "c++_smart_pointers", "c++ smart pointers", "smart pointers" });
}

fn hasTransformConcept(input: []const u8) bool {
    return hasAnyRouteSignal(input, &.{ "make", "improve", "refactor", "fix", "patch", "change", "modify", "optimize" });
}

fn hasExplainConcept(input: []const u8) bool {
    return hasAnyRouteSignal(input, &.{ "explain", "why", "summarize", "describe" });
}

fn hasSynthesisConcept(input: []const u8) bool {
    return hasAnyRouteSignal(input, &.{ "generate", "write", "create", "draft", "synthesize" });
}

fn hasSystemComponentConcept(input: []const u8) bool {
    return hasAnyRouteSignal(input, &.{ ".zig", ".cpp", ".cc", ".cxx", ".hpp", ".hh", ".hxx", ".h:", "c++", "cpp", "class", "struct", "virtual", "override", "namespace", "::", "component", "module", "function", "source file" });
}

fn hasArtifactConcept(input: []const u8) bool {
    return hasAnyRouteSignal(input, &.{ "artifact", "workspace", "source file", "file" });
}

fn hasKnowledgeSequenceConcept(input: []const u8) bool {
    return hasAnyRouteSignal(input, &.{ "timeline", "chronology", "chronological", "historical", "sequence" });
}

fn hasLocalAxiomConcept(input: []const u8) bool {
    return hasAnyRouteSignal(input, &.{ "local axiom", "local axioms", "axiom", "compiler", "compile", "verifier" });
}

fn hasChronologyConcept(input: []const u8) bool {
    return hasAnyRouteSignal(input, &.{ "timeline", "chronology", "chronological", "logical consistency", "historical" });
}

fn hasCppComponentEvidence(input: []const u8) bool {
    return hasAnyRouteSignal(input, &.{ ".cpp", ".cc", ".cxx", ".hpp", ".hh", ".hxx", "c++", "cpp" });
}

fn hasOmniCodexConcept(input: []const u8) bool {
    return hasAnyRouteSignal(input, &.{ "omni-codex", "omni codex", "corpus", "codex" });
}

fn hasLocalOnlyConstraint(input: []const u8) bool {
    return hasAnyRouteSignal(input, &.{ "local", "offline", "no network", "no external" });
}

fn matchedSystemComponentSource(input: []const u8) ?[]const u8 {
    return matchedOntologySource(input, &.{ ".zig", ".cpp", ".cc", ".cxx", ".hpp", ".hh", ".hxx", "component", "module", "function", "source file" });
}

fn matchedOntologySource(input: []const u8, needles: []const []const u8) ?[]const u8 {
    for (needles) |needle| {
        if (indexOfIgnoreCaseRoute(input, needle) != null) return needle;
    }
    return null;
}

fn hasAnyRouteSignal(input: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (indexOfIgnoreCaseRoute(input, needle) != null) return true;
    }
    return false;
}

fn indexOfIgnoreCaseRoute(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or needle.len > haystack.len) return null;
    var idx: usize = 0;
    while (idx + needle.len <= haystack.len) : (idx += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[idx .. idx + needle.len], needle)) return idx;
    }
    return null;
}

fn isSemanticSignalRune(token: []const u8) bool {
    if (token.len == 0) return false;
    if (isLowInformationRune(token)) return false;
    if (isContextStopToken(token)) return false;
    if (token.len <= 2 and !isUpperAcronymRune(token)) return false;
    const entropy = byteEntropyPerMille(token);
    const unique = uniqueByteRatioPerMille(token);
    return entropy >= 320 and unique >= 450;
}

fn isLowInformationRune(token: []const u8) bool {
    if (token.len == 0) return true;
    if (isUpperAcronymRune(token)) return false;
    var alpha_count: usize = 0;
    var digit_count: usize = 0;
    for (token) |byte| {
        if (std.ascii.isAlphabetic(byte)) alpha_count += 1 else if (std.ascii.isDigit(byte)) digit_count += 1;
    }
    if (digit_count != 0) return false;
    if (alpha_count == token.len and token.len <= 5) return true;
    return byteEntropyPerMille(token) < 300 or uniqueByteRatioPerMille(token) < 450;
}

fn isUpperAcronymRune(token: []const u8) bool {
    if (token.len < 2 or token.len > 6) return false;
    var has_alpha = false;
    for (token) |byte| {
        if (std.ascii.isAlphabetic(byte)) {
            has_alpha = true;
            if (std.ascii.isLower(byte)) return false;
        } else if (!std.ascii.isDigit(byte)) return false;
    }
    return has_alpha;
}

fn tokenizePositionalRunes(input: []const u8, out: *std.ArrayList(PositionalRune)) void {
    var start: ?usize = null;
    var idx: usize = 0;
    while (idx <= input.len) : (idx += 1) {
        const at_end = idx == input.len;
        const byte = if (at_end) 0 else input[idx];
        if (!at_end and isSalienceRuneByte(byte)) {
            if (start == null) start = idx;
            continue;
        }
        if (start) |s| {
            const text = std.mem.trim(u8, input[s..idx], "_-");
            if (text.len != 0) out.append(.{ .text = text, .start = s, .end = idx }) catch {};
            start = null;
        }
    }
}

fn isHighActionRuneSequence(token: []const u8) bool {
    if (token.len < 3 or token.len > 14) return false;
    if (isUpperAcronymRune(token)) return false;
    var alpha: usize = 0;
    for (token) |byte| {
        if (std.ascii.isAlphabetic(byte)) {
            alpha += 1;
        } else if (byte != '-' and byte != '_') {
            return false;
        }
    }
    if (alpha * 1000 / token.len < 700) return false;
    return byteEntropyPerMille(token) >= 600 and uniqueByteRatioPerMille(token) >= 650;
}

fn imperativePositionalScore(initial: PositionalRune, rune_count: usize, isolation_score: u16) u16 {
    const entropy = byteEntropyPerMille(initial.text);
    const unique = uniqueByteRatioPerMille(initial.text);
    const compactness: u16 = if (rune_count <= 5) 180 else if (rune_count <= 8) 90 else 0;
    const first_rune_bias: u16 = if (initial.start == 0) 260 else 0;
    const raw: usize = @as(usize, entropy) / 4 +
        @as(usize, unique) / 5 +
        @as(usize, compactness) +
        @as(usize, first_rune_bias) +
        @as(usize, isolation_score);
    return @intCast(@min(@as(usize, 1000), raw));
}

fn isolatedQuotedOrBracketedTarget(allocator: std.mem.Allocator, input: []const u8) !?[]u8 {
    if (delimitedTarget(input, '"', '"')) |target| return try allocator.dupe(u8, target);
    if (delimitedTarget(input, '\'', '\'')) |target| return try allocator.dupe(u8, target);
    if (delimitedTarget(input, '[', ']')) |target| return try allocator.dupe(u8, target);
    return null;
}

fn delimitedTarget(input: []const u8, open: u8, close: u8) ?[]const u8 {
    const start = std.mem.indexOfScalar(u8, input, open) orelse return null;
    const after = start + 1;
    if (after >= input.len) return null;
    const rel_end = std.mem.indexOfScalar(u8, input[after..], close) orelse return null;
    const target = std.mem.trim(u8, input[after .. after + rel_end], " \r\n\t,.:;!?");
    return if (target.len == 0) null else target;
}

fn isolatedObjectMarkerTarget(allocator: std.mem.Allocator, input: []const u8, runes: []const PositionalRune) !?[]u8 {
    if (runes.len < 3) return null;
    var idx: usize = 1;
    while (idx + 1 < runes.len) : (idx += 1) {
        if (!std.ascii.eqlIgnoreCase(runes[idx].text, "word")) continue;
        const start = runes[idx + 1].start;
        var end = runes[idx + 1].end;
        var cursor = idx + 2;
        while (cursor < runes.len) : (cursor += 1) {
            if (isImperativeTailTerminator(runes[cursor].text)) break;
            end = runes[cursor].end;
        }
        const target = std.mem.trim(u8, input[start..end], " \r\n\t,.:;!?");
        return if (target.len == 0) null else try allocator.dupe(u8, target);
    }
    return null;
}

fn isolatedOnlyTarget(allocator: std.mem.Allocator, input: []const u8, runes: []const PositionalRune) !?[]u8 {
    if (runes.len < 3) return null;
    var only_idx: ?usize = null;
    for (runes, 0..) |rune, idx| {
        if (std.ascii.eqlIgnoreCase(rune.text, "only")) {
            only_idx = idx;
            break;
        }
    }
    const stop = only_idx orelse return null;
    if (stop <= 1) return null;
    const start = runes[1].start;
    var end = runes[stop - 1].end;
    if (stop >= 2 and isImperativeTailTerminator(runes[stop - 1].text)) {
        if (stop <= 2) return null;
        end = runes[stop - 2].end;
    }
    const target = std.mem.trim(u8, input[start..end], " \r\n\t,.:;!?");
    return if (target.len == 0) null else try allocator.dupe(u8, target);
}

fn singleCompactTailTarget(input: []const u8, runes: []const PositionalRune) ?[]const u8 {
    if (runes.len != 2) return null;
    const tail = runes[1];
    if (tail.text.len > 5) return null;
    if (byteEntropyPerMille(tail.text) < 600 or uniqueByteRatioPerMille(tail.text) < 650) return null;
    return std.mem.trim(u8, input[tail.start..tail.end], " \r\n\t,.:;!?");
}

fn isImperativeTailTerminator(token: []const u8) bool {
    return std.ascii.eqlIgnoreCase(token, "and") or
        std.ascii.eqlIgnoreCase(token, "only") or
        std.ascii.eqlIgnoreCase(token, "than");
}

const NegationConstraint = struct {
    constraint: []u8 = &.{},
    references_previous: bool = false,
};

fn extractNegationConstraint(allocator: std.mem.Allocator, input: []const u8, runes: []const PositionalRune) !NegationConstraint {
    var idx: usize = 0;
    while (idx < runes.len) : (idx += 1) {
        if (idx + 1 < runes.len and
            std.ascii.eqlIgnoreCase(runes[idx].text, "other") and
            std.ascii.eqlIgnoreCase(runes[idx + 1].text, "than"))
        {
            if (idx + 2 >= runes.len) return .{ .references_previous = true };
            const start = runes[idx + 2].start;
            const end = runes[runes.len - 1].end;
            const target = std.mem.trim(u8, input[start..end], " \r\n\t,.:;!?");
            if (target.len == 0 or isDeicticOnly(target)) return .{ .references_previous = true };
            return .{ .constraint = try allocator.dupe(u8, target) };
        }
        if (std.ascii.eqlIgnoreCase(runes[idx].text, "not")) {
            if (idx + 1 >= runes.len or isDeicticOnly(runes[idx + 1].text)) return .{ .references_previous = true };
            const start = runes[idx + 1].start;
            const end = runes[runes.len - 1].end;
            const target = std.mem.trim(u8, input[start..end], " \r\n\t,.:;!?");
            return .{ .constraint = try allocator.dupe(u8, target) };
        }
    }
    return .{};
}

pub fn extractPrimarySemanticTargetFromText(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var best = std.ArrayList(u8).init(allocator);
    errdefer best.deinit();

    var it = std.mem.splitScalar(u8, input, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\n\t");
        if (trimmed.len == 0) continue;
        if (!std.ascii.startsWithIgnoreCase(trimmed, "user:")) continue;
        var payload = trimmed;
        if (std.mem.indexOfScalar(u8, trimmed, ':')) |colon| {
            payload = std.mem.trim(u8, trimmed[colon + 1 ..], " \r\n\t");
        }
        if (payload.len == 0 or lacksSemanticTarget(payload) or isDeicticOnly(payload)) continue;
        if (try recentContextPhrase(allocator, payload)) |phrase| {
            defer allocator.free(phrase);
            best.clearRetainingCapacity();
            try best.appendSlice(phrase);
            continue;
        }
        var salience = try analyzeSalience(allocator, payload);
        defer salience.deinit(allocator);
        const target = if (salience.semantic_target.len != 0) salience.semantic_target else payload;
        if (target.len == 0 or isDeicticOnly(target)) continue;
        best.clearRetainingCapacity();
        try best.appendSlice(target);
    }
    return best.toOwnedSlice();
}

fn isDeicticOnly(text: []const u8) bool {
    var meaningful: usize = 0;
    var deictic: usize = 0;
    var it = std.mem.tokenizeAny(u8, text, " \r\n\t,.:;!?()[]{}\"'");
    while (it.next()) |token| {
        if (token.len <= 2 and !std.ascii.eqlIgnoreCase(token, "it")) continue;
        meaningful += 1;
        if (std.ascii.eqlIgnoreCase(token, "it") or
            std.ascii.eqlIgnoreCase(token, "that") or
            std.ascii.eqlIgnoreCase(token, "this") or
            std.ascii.eqlIgnoreCase(token, "they") or
            std.ascii.eqlIgnoreCase(token, "them"))
        {
            deictic += 1;
        }
    }
    return meaningful != 0 and meaningful == deictic;
}

fn recentContextPhrase(allocator: std.mem.Allocator, text: []const u8) !?[]u8 {
    var tokens = std.ArrayList([]const u8).init(allocator);
    defer tokens.deinit();
    var it = std.mem.tokenizeAny(u8, text, " \r\n\t,.:;!?()[]{}\"'");
    while (it.next()) |token| {
        if (token.len < 3 or isContextStopToken(token)) continue;
        try tokens.append(token);
    }
    if (tokens.items.len == 0) return null;
    const start = if (tokens.items.len >= 2) tokens.items.len - 2 else 0;
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    for (tokens.items[start..], 0..) |token, idx| {
        if (idx != 0) try out.append(' ');
        for (token) |byte| try out.append(std.ascii.toLower(byte));
    }
    return try out.toOwnedSlice();
}

fn isContextStopToken(token: []const u8) bool {
    const words = [_][]const u8{
        "what", "whats", "how",  "why",   "where", "when", "who",
        "the",  "and",   "for",  "with",  "that",  "this", "does",
        "did",  "are",   "was",  "were",  "have",  "has",  "had",
        "its",  "into",  "from", "about",
    };
    for (words) |word| {
        if (std.ascii.eqlIgnoreCase(token, word)) return true;
    }
    return false;
}

const SemanticWindow = struct {
    start: usize,
    end: usize,
};

fn tokenizeSalienceRunes(allocator: std.mem.Allocator, input: []const u8, runes: *std.ArrayList(SalienceRune)) !void {
    var start: ?usize = null;
    var idx: usize = 0;
    while (idx <= input.len) : (idx += 1) {
        const at_end = idx == input.len;
        const byte = if (at_end) 0 else input[idx];
        if (!at_end and isSalienceRuneByte(byte)) {
            if (start == null) start = idx;
            continue;
        }
        if (start) |s| {
            try appendSalienceRune(allocator, input, s, idx, runes);
            start = null;
            if (runes.items.len >= MAX_SALIENCE_RUNES) break;
        }
    }
}

fn appendSalienceRune(allocator: std.mem.Allocator, input: []const u8, start: usize, end: usize, runes: *std.ArrayList(SalienceRune)) !void {
    const trimmed = std.mem.trim(u8, input[start..end], "_-");
    if (trimmed.len == 0) return;
    if (trimmed.len == 1 and std.ascii.isAlphabetic(trimmed[0])) return;

    const lower = try allocator.alloc(u8, trimmed.len);
    errdefer allocator.free(lower);
    for (trimmed, 0..) |byte, idx| lower[idx] = std.ascii.toLower(byte);
    try runes.append(.{
        .text = lower,
        .start = start,
        .end = end,
        .semantic_score = 0,
        .structural_score = 0,
    });
}

fn isSalienceRuneByte(byte: u8) bool {
    return byte >= 0x80 or std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-';
}

fn scoreSalienceRunes(runes: []SalienceRune) void {
    for (runes, 0..) |*rune, idx| {
        const entropy = byteEntropyPerMille(rune.text);
        const unique = uniqueByteRatioPerMille(rune.text);
        const length = lengthSaliencePerMille(rune.text);
        const position = positionPerMille(idx, runes.len);
        const repeat = repeatedRunePerMille(runes, rune.text);

        const semantic =
            (@as(usize, entropy) * 34) +
            (@as(usize, unique) * 18) +
            (@as(usize, length) * 22) +
            (@as(usize, position) * 22) -
            (@as(usize, repeat) * 18);
        const structural =
            (@as(usize, 1000 - entropy) * 30) +
            (@as(usize, 1000 - length) * 22) +
            (@as(usize, 1000 - position) * 18) +
            (@as(usize, repeat) * 30);

        rune.semantic_score = @intCast(@min(@as(usize, 1000), semantic / 100));
        rune.structural_score = @intCast(@min(@as(usize, 1000), structural / 100));
    }
}

fn isDefinitionContentQuery(input: []const u8) bool {
    const match = vsa_vulkan.globalRuneMatch(input);
    if (!match.contentOverridesEntropy()) return false;
    return containsBoundedPhrase(input, "what is") != null or
        containsBoundedPhrase(input, "what's") != null or
        containsBoundedPhrase(input, "define") != null or
        containsBoundedPhrase(input, "definition") != null;
}

fn startsWithQuestionRune(input: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, input, " \r\n\t,.:;!?()[]{}\"'");
    const first = it.next() orelse return false;
    return isQuestionToken(first) or std.ascii.eqlIgnoreCase(first, "who");
}

fn chooseResonantContentWindow(runes: []const SalienceRune) ?SemanticWindow {
    for (runes, 0..) |rune, idx| {
        if (vsa_vulkan.contentRuneResonancePerMille(rune.text) >= vsa_vulkan.GLOBAL_RUNE_RESONANCE_OVERRIDE_PER_MILLE) {
            return .{ .start = idx, .end = idx + 1 };
        }
    }
    return null;
}

fn chooseSemanticWindow(runes: []const SalienceRune) SemanticWindow {
    if (runes.len <= 2) return .{ .start = 0, .end = runes.len };

    var best = SemanticWindow{ .start = runes.len - 1, .end = runes.len };
    var best_score: i64 = std.math.minInt(i64);
    const max_width = @min(@as(usize, 4), runes.len);
    var width: usize = 1;
    while (width <= max_width) : (width += 1) {
        var start: usize = 0;
        while (start + width <= runes.len) : (start += 1) {
            const end = start + width;
            var semantic_sum: usize = 0;
            for (runes[start..end]) |rune| semantic_sum += rune.semantic_score;
            const average_semantic: i64 = @intCast(semantic_sum / width);
            const tail_pressure: i64 = @intCast((end * 1000) / runes.len);
            const width_bias: i64 = switch (width) {
                1 => if (runes.len <= 3) -120 else -260,
                2 => 520,
                3 => 80,
                else => 0,
            };
            const prefix_penalty: i64 = if (start == 0) 110 else 0;
            const barrier_penalty: i64 = if (start > 0 and isStructuralBarrier(runes[start - 1])) 620 else 0;
            const score = (average_semantic * 61) + (tail_pressure * 39) + width_bias - prefix_penalty - barrier_penalty;
            if (score > best_score) {
                best_score = score;
                best = .{ .start = start, .end = end };
            }
        }
    }
    if (best.start > 0 and isStructuralBarrier(runes[best.start - 1])) {
        best.end = best.start - 1;
        best.start = best.end;
        while (best.start > 0 and runes[best.start - 1].text.len >= 4 and !isStructuralBarrier(runes[best.start - 1])) {
            best.start -= 1;
            break;
        }
        if (best.start == best.end) best.end = best.start + 1;
    } else if (best.end - best.start == 1 and best.start > 0) {
        const previous = runes[best.start - 1];
        const current = runes[best.start];
        if (previous.text.len >= 4 and
            !isStructuralBarrier(previous) and
            @as(usize, previous.semantic_score) + 260 >= @as(usize, current.semantic_score))
        {
            best.start -= 1;
        }
    }
    return best;
}

fn isStructuralBarrier(rune: SalienceRune) bool {
    if (rune.text.len <= 3 and rune.structural_score < 350) return true;
    return rune.text.len >= 3 and
        rune.semantic_score < 520 and
        rune.structural_score > rune.semantic_score + 180;
}

fn joinSelectedSalienceRunes(allocator: std.mem.Allocator, runes: []const SalienceRune, selected: bool) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    for (runes) |rune| {
        if (rune.selected_target != selected) continue;
        if (out.items.len != 0) try out.append(' ');
        try out.appendSlice(rune.text);
    }
    return out.toOwnedSlice();
}

fn densityMultiplier(noise_count: usize, avg_noise: u16) u8 {
    if (noise_count == 0) return 1;
    const count_component = noise_count / 2 + @min(noise_count % 2, 1);
    const raw = 1 + @min(@as(usize, 7), count_component + @as(usize, avg_noise) / 350);
    return @intCast(@min(@as(usize, 8), raw));
}

fn byteEntropyPerMille(bytes: []const u8) u16 {
    if (bytes.len <= 1) return 0;
    var counts = [_]u16{0} ** 256;
    for (bytes) |byte| counts[byte] += 1;

    const total: f64 = @floatFromInt(bytes.len);
    var entropy: f64 = 0.0;
    for (counts) |count| {
        if (count == 0) continue;
        const p = @as(f64, @floatFromInt(count)) / total;
        entropy -= p * @log2(p);
    }
    const max_symbols = @min(bytes.len, 256);
    const max_entropy = @log2(@as(f64, @floatFromInt(max_symbols)));
    if (max_entropy <= 0.0) return 0;
    const scaled = @min(@as(f64, 1000.0), (entropy / max_entropy) * 1000.0);
    return @intFromFloat(scaled);
}

fn uniqueByteRatioPerMille(bytes: []const u8) u16 {
    if (bytes.len == 0) return 0;
    var seen = [_]bool{false} ** 256;
    var unique: usize = 0;
    for (bytes) |byte| {
        if (!seen[byte]) {
            seen[byte] = true;
            unique += 1;
        }
    }
    return @intCast((unique * 1000) / bytes.len);
}

fn lengthSaliencePerMille(bytes: []const u8) u16 {
    const bounded: usize = @min(bytes.len, @as(usize, 14));
    return @intCast((bounded * @as(usize, 1000)) / @as(usize, 14));
}

fn positionPerMille(idx: usize, count: usize) u16 {
    if (count <= 1) return 1000;
    return @intCast((idx * 1000) / (count - 1));
}

fn repeatedRunePerMille(runes: []const SalienceRune, text: []const u8) u16 {
    var count: usize = 0;
    for (runes) |rune| {
        if (std.mem.eql(u8, rune.text, text)) count += 1;
    }
    if (count <= 1) return 0;
    return @intCast(@min(@as(usize, 1000), ((count - 1) * 1000) / @max(@as(usize, 1), runes.len - 1)));
}

// ── Vague Request Phrase Table ─────────────────────────────────────────

const VaguePhrase = struct {
    phrase: []const u8,
    expansions: []const VagueExpansion,
};

const VagueExpansion = struct {
    action_surface: artifact_schema.ActionSurface,
    label: []const u8,
    reason: []const u8,
};

const VAGUE_PHRASES = [_]VaguePhrase{
    .{
        .phrase = "make this better",
        .expansions = &.{
            .{ .action_surface = .transform, .label = "improve readability", .reason = "\"better\" commonly refers to readability" },
            .{ .action_surface = .transform, .label = "reduce complexity", .reason = "\"better\" commonly refers to simplification" },
            .{ .action_surface = .patch, .label = "fix errors", .reason = "\"better\" may mean fixing known issues" },
            .{ .action_surface = .transform, .label = "optimize performance", .reason = "\"better\" commonly refers to performance" },
            .{ .action_surface = .transform, .label = "align with schema/patterns", .reason = "\"better\" may mean conformance" },
        },
    },
    .{
        .phrase = "clean this up",
        .expansions = &.{
            .{ .action_surface = .transform, .label = "improve readability", .reason = "\"clean up\" commonly refers to readability" },
            .{ .action_surface = .restructure, .label = "restructure for clarity", .reason = "\"clean up\" may mean reorganization" },
            .{ .action_surface = .transform, .label = "remove dead code", .reason = "\"clean up\" commonly refers to removal" },
        },
    },
    .{
        .phrase = "optimize this",
        .expansions = &.{
            .{ .action_surface = .transform, .label = "optimize performance", .reason = "\"optimize\" directly maps to performance" },
            .{ .action_surface = .transform, .label = "reduce memory usage", .reason = "\"optimize\" may refer to memory" },
            .{ .action_surface = .restructure, .label = "reduce complexity", .reason = "\"optimize\" may refer to algorithmic complexity" },
        },
    },
    .{
        .phrase = "fix it",
        .expansions = &.{
            .{ .action_surface = .patch, .label = "fix errors", .reason = "\"fix it\" directly maps to error correction" },
            .{ .action_surface = .patch, .label = "fix incorrect behavior", .reason = "\"fix it\" may mean behavioral correction" },
        },
    },
    .{
        .phrase = "make it nicer",
        .expansions = &.{
            .{ .action_surface = .transform, .label = "improve readability", .reason = "\"nicer\" commonly refers to readability" },
            .{ .action_surface = .transform, .label = "improve naming", .reason = "\"nicer\" may refer to naming clarity" },
            .{ .action_surface = .restructure, .label = "restructure for clarity", .reason = "\"nicer\" may mean reorganization" },
        },
    },
    .{
        .phrase = "improve this",
        .expansions = &.{
            .{ .action_surface = .transform, .label = "improve readability", .reason = "\"improve\" commonly refers to readability" },
            .{ .action_surface = .transform, .label = "optimize performance", .reason = "\"improve\" may refer to performance" },
            .{ .action_surface = .transform, .label = "reduce complexity", .reason = "\"improve\" may refer to simplification" },
            .{ .action_surface = .patch, .label = "fix errors", .reason = "\"improve\" may mean fixing issues" },
        },
    },
};

// ── Classification Phrase Tables ───────────────────────────────────────

const ClassificationPhrase = struct {
    phrase: []const u8,
    class: IntentClass,
};

const CLASSIFICATION_PHRASES = [_]ClassificationPhrase{
    .{ .phrase = "summarize", .class = .direct_action },
    .{ .phrase = "list", .class = .direct_action },
    .{ .phrase = "show", .class = .direct_action },
    .{ .phrase = "extract", .class = .direct_action },
    .{ .phrase = "find", .class = .direct_action },
    .{ .phrase = "search", .class = .direct_action },
    .{ .phrase = "get", .class = .direct_action },
    .{ .phrase = "display", .class = .direct_action },

    .{ .phrase = "make", .class = .transformation },
    .{ .phrase = "improve", .class = .transformation },
    .{ .phrase = "optimize", .class = .transformation },
    .{ .phrase = "clean", .class = .transformation },
    .{ .phrase = "fix", .class = .transformation },
    .{ .phrase = "refactor", .class = .transformation },
    .{ .phrase = "simplify", .class = .transformation },
    .{ .phrase = "restructure", .class = .transformation },
    .{ .phrase = "convert", .class = .transformation },
    .{ .phrase = "migrate", .class = .transformation },

    .{ .phrase = "what is wrong", .class = .diagnostic },
    .{ .phrase = "what's wrong", .class = .diagnostic },
    .{ .phrase = "debug", .class = .diagnostic },
    .{ .phrase = "diagnose", .class = .diagnostic },
    .{ .phrase = "investigate", .class = .diagnostic },
    .{ .phrase = "why does", .class = .diagnostic },
    .{ .phrase = "why is", .class = .diagnostic },
    .{ .phrase = "why did", .class = .diagnostic },
    .{ .phrase = "trace", .class = .diagnostic },

    .{ .phrase = "build", .class = .creation },
    .{ .phrase = "create", .class = .creation },
    .{ .phrase = "implement", .class = .creation },
    .{ .phrase = "add", .class = .creation },
    .{ .phrase = "generate", .class = .creation },
    .{ .phrase = "write", .class = .creation },
    .{ .phrase = "scaffold", .class = .creation },

    .{ .phrase = "verify", .class = .verification },
    .{ .phrase = "check", .class = .verification },
    .{ .phrase = "audit", .class = .verification },
    .{ .phrase = "validate", .class = .verification },
    .{ .phrase = "test", .class = .verification },
    .{ .phrase = "confirm", .class = .verification },
    .{ .phrase = "is this correct", .class = .verification },
    .{ .phrase = "correct", .class = .verification },
};

// ── Public API ─────────────────────────────────────────────────────────

/// Ground an intent from raw user input. This is the main entry point.
/// Returns a GroundedIntent with full traceability.
pub fn ground(
    allocator: std.mem.Allocator,
    input: []const u8,
    options: GroundingOptions,
) !GroundedIntent {
    const trimmed = std.mem.trim(u8, input, " \r\n\t");
    const clipped = if (trimmed.len <= MAX_INPUT_BYTES) trimmed else trimmed[0..MAX_INPUT_BYTES];
    const raw_input = try allocator.dupe(u8, clipped);
    errdefer allocator.free(raw_input);
    const normalized_form = try lowercaseAscii(allocator, clipped);
    errdefer allocator.free(normalized_form);

    // Step 1: Run v1 base parsing.
    const base_task_or_err = task_intent.parse(allocator, input, .{ .context_target = options.context_target });
    if (base_task_or_err) |base_task| {
        // Continue with the grounded base task below.
        return finishGrounding(allocator, raw_input, normalized_form, base_task, options);
    } else |_| {
        // If v1 parsing fails entirely, create a minimal unresolved base.
        const minimal = task_intent.Task{
            .allocator = allocator,
            .raw_input = try allocator.dupe(u8, clipped),
            .normalized_input = try allocator.dupe(u8, normalized_form),
            .status = .unresolved,
        };
        return .{
            .allocator = allocator,
            .status = .unresolved,
            .raw_input = raw_input,
            .normalized_form = normalized_form,
            .base_task = minimal,
        };
    }
}

fn finishGrounding(
    allocator: std.mem.Allocator,
    raw_input: []u8,
    normalized_form: []u8,
    base_task: task_intent.Task,
    options: GroundingOptions,
) !GroundedIntent {
    var result = GroundedIntent{
        .allocator = allocator,
        .raw_input = raw_input,
        .normalized_form = normalized_form,
        .base_task = base_task,
    };
    errdefer result.deinit();

    var traces = std.ArrayList(GroundingTrace).init(allocator);
    defer traces.deinit();
    var artifact_bindings = std.ArrayList(ArtifactBinding).init(allocator);
    defer artifact_bindings.deinit();
    var constraints = std.ArrayList(GroundedConstraint).init(allocator);
    defer {
        for (constraints.items) |*c| c.deinit(allocator);
        constraints.deinit();
    }
    var obligations = std.ArrayList(IntentObligation).init(allocator);
    defer {
        for (obligations.items) |*o| o.deinit(allocator);
        obligations.deinit();
    }
    var missing_obligations = std.ArrayList(MissingObligation).init(allocator);
    defer {
        for (missing_obligations.items) |*mo| mo.deinit(allocator);
        missing_obligations.deinit();
    }
    var ambiguity_sets = std.ArrayList(AmbiguitySet).init(allocator);
    defer {
        for (ambiguity_sets.items) |*as| as.deinit(allocator);
        ambiguity_sets.deinit();
    }
    var candidate_intents = std.ArrayList(CandidateIntent).init(allocator);
    defer {
        for (candidate_intents.items) |*ci| ci.deinit(allocator);
        candidate_intents.deinit();
    }
    var ontological_primitives: []OntologyPrimitive = &.{};
    defer freeOntologicalPrimitives(allocator, ontological_primitives);

    // Step 2: Classify intent.
    const classification = classifyIntent(normalized_form);
    result.intent_class = classification.class;
    const latent_detail = try std.fmt.allocPrint(
        allocator,
        "latent_concept={s}; similarity_per_mille={d}; strong_heavy_task={s}",
        .{
            @tagName(classification.latent.concept),
            scorePerMille(classification.latent.similarity),
            if (classification.latent.strong_heavy_task) "true" else "false",
        },
    );
    defer allocator.free(latent_detail);
    if (classification.ambiguous) {
        try appendTrace(allocator, &traces, "classify", normalized_form, @tagName(IntentClass.ambiguous), latent_detail);
    } else {
        try appendTrace(allocator, &traces, "classify", normalized_form, @tagName(classification.class), classification.matched_phrase orelse latent_detail);
    }

    // Step 3: Vague request expansion (only for transformation class).
    if (classification.class == .transformation) {
        const vague = expandVagueRequest(allocator, normalized_form);
        if (vague) |candidates| {
            const start_idx: usize = candidate_intents.items.len;
            // Move candidates from temporary list into the persistent list.
            // We must NOT deinit the candidates' owned strings since they are
            // shallow-copied into our list. Only free the ArrayList's internal
            // buffer, not the items themselves.
            try candidate_intents.appendSlice(candidates.items);
            // The items' owned strings (label, reason) are now owned by
            // candidate_intents. deinit only frees the backing array of
            // CandidateIntent structs, not the strings they point to.
            candidates.deinit();

            // Create indices for the ambiguity set.
            const count = candidate_intents.items.len - start_idx;
            const indices = try allocator.alloc(usize, count);
            for (indices, 0..) |*idx, i| idx.* = start_idx + i;

            // Create an ambiguity set referencing the candidates by index.
            const set_reason = try std.fmt.allocPrint(allocator, "vague transformation request \"{s}\" has {d} valid interpretations", .{ normalized_form, count });
            const set_obl = try allocator.dupe(u8, "define_improvement_criteria");
            try ambiguity_sets.append(.{
                .candidate_indices = indices,
                .reason = set_reason,
                .obligation_to_resolve = set_obl,
            });
            try appendTrace(allocator, &traces, "vague_expand", normalized_form, "multiple_candidates", null);
        }
    }

    // Step 4: Artifact binding. Conversational reasoning is not artifact work,
    // so it does not require bind_target_artifact.
    if (!intentClassRequiresArtifact(classification.class)) {
        try appendTrace(allocator, &traces, "bind_artifact", normalized_form, "not_required", "latent intent resolved as conversational reasoning");
    } else {
        const bindings = try bindArtifacts(allocator, &base_task, normalized_form, options);
        // Transfer valid bindings.
        for (bindings) |binding| {
            if (artifact_bindings.items.len >= MAX_ARTIFACT_BINDINGS) break;
            try artifact_bindings.append(binding);
        }
        if (artifact_bindings.items.len == 0 and (base_task.target.kind == .none or base_task.target.kind == .current_context)) {
            try missing_obligations.append(.{
                .id = try allocator.dupe(u8, "bind_target_artifact"),
                .label = try allocator.dupe(u8, "bind target artifact to intent"),
                .required_for = try allocator.dupe(u8, "any_action"),
            });
            try appendTrace(allocator, &traces, "bind_artifact", normalized_form, "no_binding", "no artifact could be bound to the intent");
        } else {
            try appendTrace(allocator, &traces, "bind_artifact", normalized_form, "bound", null);
        }
        allocator.free(bindings);
    }

    // Step 5: Constraint extraction (explicit + inferred).
    try extractGroundedConstraints(allocator, &constraints, &base_task, normalized_form, classification.class);
    try appendTrace(allocator, &traces, "extract_constraints", normalized_form, "extracted", null);

    // Step 6: Ontological primitive extraction.
    ontological_primitives = try extractOntologicalPrimitives(allocator, normalized_form);
    const ontology_detail = try std.fmt.allocPrint(allocator, "primitive_count={d}", .{ontological_primitives.len});
    defer allocator.free(ontology_detail);
    try appendTrace(allocator, &traces, "extract_ontology", normalized_form, "ontological_primitives", ontology_detail);

    // Step 7: Intent → Obligation mapping.
    try mapObligations(allocator, &obligations, classification.class, &base_task, artifact_bindings.items);
    try appendTrace(allocator, &traces, "map_obligations", normalized_form, "mapped", null);

    // Step 8: Determine scope.
    result.scope = determineScope(artifact_bindings.items);

    // Step 9: Determine action surfaces.
    result.action_surfaces = try determineActionSurfaces(allocator, classification.class, &base_task);

    // Step 10: Finalize status.
    result.artifact_bindings = try artifact_bindings.toOwnedSlice();
    result.constraints = try constraints.toOwnedSlice();
    constraints = std.ArrayList(GroundedConstraint).init(allocator);
    result.obligations = try obligations.toOwnedSlice();
    obligations = std.ArrayList(IntentObligation).init(allocator);
    result.missing_obligations = try missing_obligations.toOwnedSlice();
    missing_obligations = std.ArrayList(MissingObligation).init(allocator);
    result.ambiguity_sets = try ambiguity_sets.toOwnedSlice();
    ambiguity_sets = std.ArrayList(AmbiguitySet).init(allocator);
    result.candidate_intents = try candidate_intents.toOwnedSlice();
    candidate_intents = std.ArrayList(CandidateIntent).init(allocator);
    result.ontological_primitives = ontological_primitives;
    ontological_primitives = &.{};
    result.traces = try traces.toOwnedSlice();
    traces = std.ArrayList(GroundingTrace).init(allocator);

    finalizeGrounding(&result);
    return result;
}

/// Render a GroundedIntent as JSON for CLI output.
pub fn renderJson(allocator: std.mem.Allocator, gi: *const GroundedIntent) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const writer = out.writer();

    try writer.writeAll("{");
    try writeJsonFieldString(writer, "status", groundingStatusName(gi.status), true);
    try writeJsonFieldString(writer, "intentClass", @tagName(gi.intent_class), false);
    try writeJsonFieldString(writer, "scope", @tagName(gi.scope), false);
    try writeJsonFieldString(writer, "rawInput", gi.raw_input, false);
    try writeJsonFieldString(writer, "normalizedForm", gi.normalized_form, false);
    try writer.writeAll(",\"fastPathEligible\":");
    try writer.writeAll(if (gi.fast_path_eligible) "true" else "false");

    // Action surfaces
    try writer.writeAll(",\"actionSurfaces\":[");
    for (gi.action_surfaces, 0..) |surface, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writer.writeByte('"');
        try writer.writeAll(@tagName(surface));
        try writer.writeByte('"');
    }
    try writer.writeAll("]");

    // Artifact bindings
    try writer.writeAll(",\"artifactBindings\":[");
    for (gi.artifact_bindings, 0..) |binding, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writer.writeAll("{");
        try writeJsonFieldString(writer, "artifactId", binding.artifact_id, true);
        try writeJsonFieldString(writer, "source", @tagName(binding.source), false);
        try writeJsonFieldString(writer, "schemaName", binding.schema_name, false);
        try writer.print(",\"confidence\":{d}", .{binding.confidence});
        try writer.writeAll("}");
    }
    try writer.writeAll("]");

    // Constraints
    try writer.writeAll(",\"constraints\":[");
    for (gi.constraints, 0..) |constraint, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writer.writeAll("{");
        try writeJsonFieldString(writer, "kind", @tagName(constraint.kind), true);
        try writeJsonFieldString(writer, "source", @tagName(constraint.source), false);
        if (constraint.value) |v| try writeOptionalStringField(writer, "value", v);
        if (constraint.detail) |d| try writeOptionalStringField(writer, "detail", d);
        try writer.writeAll("}");
    }
    try writer.writeAll("]");

    // Obligations
    try writer.writeAll(",\"obligations\":[");
    for (gi.obligations, 0..) |obl, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writer.writeAll("{");
        try writeJsonFieldString(writer, "id", obl.id, true);
        try writeJsonFieldString(writer, "label", obl.label, false);
        try writeJsonFieldString(writer, "scope", obl.scope, false);
        try writer.print(",\"pending\":{s}", .{if (obl.pending) "true" else "false"});
        try writer.writeAll("}");
    }
    try writer.writeAll("]");

    // Ambiguity sets
    try writer.writeAll(",\"ambiguitySets\":[");
    for (gi.ambiguity_sets, 0..) |aset, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writer.writeAll("{");
        try writeJsonFieldString(writer, "reason", aset.reason, true);
        try writeJsonFieldString(writer, "obligationToResolve", aset.obligation_to_resolve, false);
        try writer.writeAll(",\"candidateIndices\":[");
        for (aset.candidate_indices, 0..) |cidx, ci| {
            if (ci != 0) try writer.writeByte(',');
            try writer.print("{d}", .{cidx});
        }
        try writer.writeAll("]}");
    }
    try writer.writeAll("]");

    // Missing obligations
    try writer.writeAll(",\"missingObligations\":[");
    for (gi.missing_obligations, 0..) |mo, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writer.writeAll("{");
        try writeJsonFieldString(writer, "id", mo.id, true);
        try writeJsonFieldString(writer, "label", mo.label, false);
        try writeJsonFieldString(writer, "requiredFor", mo.required_for, false);
        try writer.writeAll("}");
    }
    try writer.writeAll("]");

    // Candidate intents
    try writer.writeAll(",\"candidateIntents\":[");
    for (gi.candidate_intents, 0..) |ci, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writer.writeAll("{");
        try writeJsonFieldString(writer, "label", ci.label, true);
        try writeJsonFieldString(writer, "actionSurface", @tagName(ci.action_surface), false);
        try writeJsonFieldString(writer, "reason", ci.reason, false);
        try writeJsonFieldString(writer, "scope", @tagName(ci.scope), false);
        try writer.writeAll("}");
    }
    try writer.writeAll("]");

    // Ontological primitives
    try writer.writeAll(",\"ontologicalPrimitives\":[");
    for (gi.ontological_primitives, 0..) |primitive, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writer.writeAll("{");
        try writeJsonFieldString(writer, "role", ontologyRoleName(primitive.role), true);
        try writeJsonFieldString(writer, "concept", ontologyConceptName(primitive.concept), false);
        try writeJsonFieldString(writer, "source", primitive.source, false);
        try writer.print(",\"confidence\":{d}", .{primitive.confidence});
        try writer.writeAll("}");
    }
    try writer.writeAll("]");

    // Base task status
    try writeJsonFieldString(writer, "baseTaskStatus", task_intent.parseStatusName(gi.base_task.status), false);

    // Traces
    try writer.writeAll(",\"traces\":[");
    for (gi.traces, 0..) |trace, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writer.writeAll("{");
        try writeJsonFieldString(writer, "step", trace.step, true);
        try writeJsonFieldString(writer, "input", trace.input, false);
        try writeJsonFieldString(writer, "output", trace.output, false);
        if (trace.detail) |d| try writeOptionalStringField(writer, "detail", d);
        try writer.writeAll("}");
    }
    try writer.writeAll("]");

    try writer.writeAll("}");
    return out.toOwnedSlice();
}

pub fn groundingStatusName(status: GroundedIntent.GroundingStatus) []const u8 {
    return @tagName(status);
}

pub fn intentClassRequiresArtifact(class: IntentClass) bool {
    return switch (class) {
        .conversation => false,
        .direct_action, .transformation, .diagnostic, .creation, .verification, .ambiguous => true,
    };
}

// ── Internal: Classification ───────────────────────────────────────────

fn classifyIntent(normalized: []const u8) struct { class: IntentClass, ambiguous: bool, matched_phrase: ?[]const u8, latent: LatentIntentMatch } {
    const latent = inferLatentIntent(normalized);
    const ontology_verification = hasVerificationConcept(normalized) and
        (hasSystemComponentConcept(normalized) or hasKnowledgeSequenceConcept(normalized) or hasLocalAxiomConcept(normalized) or hasChronologyConcept(normalized));
    if (!latent.strong_heavy_task and !ontology_verification) {
        return .{ .class = .conversation, .ambiguous = false, .matched_phrase = "latent_default_conversation", .latent = latent };
    }

    var found_class: ?IntentClass = null;
    var found_index: usize = std.math.maxInt(usize);
    var found_phrase: ?[]const u8 = null;
    var ambiguous = false;

    for (CLASSIFICATION_PHRASES) |entry| {
        if (containsBoundedPhrase(normalized, entry.phrase)) |idx| {
            if (found_class == null or idx < found_index) {
                found_class = entry.class;
                found_index = idx;
                found_phrase = entry.phrase;
            } else if (entry.class != found_class.?) {
                ambiguous = true;
            }
        }
    }

    // Check v1 action as fallback for direct classification.
    if (found_class == null) {
        if (containsBoundedPhrase(normalized, "explain") != null or
            containsBoundedPhrase(normalized, "why") != null)
        {
            found_class = .diagnostic;
            found_phrase = "explain/why";
        } else if (containsBoundedPhrase(normalized, "build") != null or
            containsBoundedPhrase(normalized, "implement") != null)
        {
            found_class = .creation;
            found_phrase = "build/implement";
        } else if (containsBoundedPhrase(normalized, "refactor") != null) {
            found_class = .transformation;
            found_phrase = "refactor";
        } else if (containsBoundedPhrase(normalized, "verify") != null or
            containsBoundedPhrase(normalized, "check") != null)
        {
            found_class = .verification;
            found_phrase = "verify/check";
        }
    }

    if (found_class == null) {
        found_class = switch (latent.concept) {
            .conversation => .conversation,
            .modification => .transformation,
            .retrieval => .direct_action,
            .meta_analysis => .diagnostic,
        };
        found_phrase = "latent_similarity";
    }
    return .{ .class = found_class.?, .ambiguous = ambiguous, .matched_phrase = found_phrase, .latent = latent };
}

fn inferLatentIntent(normalized: []const u8) LatentIntentMatch {
    const input_vector = projectInputVector(normalized);
    const concepts = [_]struct {
        concept: LatentConcept,
        vector: [LATENT_VECTOR_DIMS]f32,
    }{
        .{ .concept = .conversation, .vector = .{ 1.00, 0.72, 0.08, 0.00, 0.08, 0.00, 0.24, 0.20 } },
        .{ .concept = .modification, .vector = .{ 0.00, 0.04, 0.68, 1.00, 0.10, 0.25, 0.12, 0.55 } },
        .{ .concept = .retrieval, .vector = .{ 0.10, 0.35, 0.55, 0.05, 1.00, 0.10, 0.25, 0.28 } },
        .{ .concept = .meta_analysis, .vector = .{ 0.28, 0.70, 0.45, 0.10, 0.28, 0.45, 1.00, 0.38 } },
    };

    var best = LatentIntentMatch{
        .concept = .conversation,
        .similarity = -1.0,
        .strong_heavy_task = false,
        .vector = input_vector,
    };
    for (concepts) |entry| {
        const similarity = cosineSimilarity(input_vector, entry.vector);
        if (similarity > best.similarity) {
            best.concept = entry.concept;
            best.similarity = similarity;
        }
    }
    const code_context_present = input_vector[2] >= 0.25;
    const heavy_lane_present = input_vector[3] >= 0.35 or
        (code_context_present and (input_vector[4] >= 0.45 or input_vector[5] >= 0.35));
    const path_backed_diagnostic = input_vector[2] >= 0.35 and input_vector[1] >= 0.25 and
        (containsBoundedPhrase(normalized, "why") != null or containsBoundedPhrase(normalized, "explain") != null);
    best.strong_heavy_task = hasExplicitHeavyTaskSignal(normalized) and
        (heavy_lane_present or path_backed_diagnostic or (isHeavyConcept(best.concept) and best.similarity >= HEAVY_TASK_THRESHOLD));
    return best;
}

pub fn estimateIntentConfidence(normalized: []const u8) IntentConfidence {
    const match = inferLatentIntent(normalized);
    return .{
        .concept = match.concept,
        .score = match.similarity,
        .strong_heavy_task = match.strong_heavy_task,
    };
}

fn isHeavyConcept(concept: LatentConcept) bool {
    return switch (concept) {
        .modification, .retrieval => true,
        .conversation, .meta_analysis => false,
    };
}

fn projectInputVector(normalized: []const u8) [LATENT_VECTOR_DIMS]f32 {
    // Vulkan-compatible f32 semantic lane layout:
    // social, question, artifact, mutation, retrieval, verification, meta, effort.
    var vector = [_]f32{0.0} ** LATENT_VECTOR_DIMS;
    var token_count: usize = 0;
    var it = std.mem.tokenizeAny(u8, normalized, " \r\n\t,.:;!?()[]{}\"'");
    while (it.next()) |token| {
        token_count += 1;
        if (isSocialToken(token)) vector[0] += 1.0;
        if (isQuestionToken(token)) vector[1] += 0.85;
        if (isArtifactToken(token)) vector[2] += 0.65;
        if (isMutationToken(token)) vector[3] += 1.0;
        if (isRetrievalToken(token)) vector[4] += 1.0;
        if (isVerificationToken(token)) vector[5] += 1.0;
        if (isMetaToken(token)) vector[6] += 0.9;
        if (isEffortToken(token)) vector[7] += 0.7;
    }

    if (token_count <= 5) vector[0] += 0.25;
    if (std.mem.indexOf(u8, normalized, "?") != null) vector[1] += 0.25;
    if (containsBoundedPhrase(normalized, "what's up") != null or containsBoundedPhrase(normalized, "whats up") != null) vector[0] += 1.0;
    if (containsBoundedPhrase(normalized, "how is") != null or containsBoundedPhrase(normalized, "how are") != null) {
        vector[1] += 0.45;
        vector[6] += 0.35;
    }
    if (containsBoundedPhrase(normalized, "looking") != null) vector[6] += 0.35;
    if (containsBoundedPhrase(normalized, "audio engine") != null) {
        vector[2] += 0.25;
        vector[6] += 0.25;
    }
    if (containsBoundedPhrase(normalized, "src/") != null or containsBoundedPhrase(normalized, ".zig") != null) vector[2] += 0.9;
    if (containsBoundedPhrase(normalized, "run tests") != null or containsBoundedPhrase(normalized, "build test") != null) vector[5] += 0.8;

    return normalizeVector(vector);
}

fn normalizeVector(vector: [LATENT_VECTOR_DIMS]f32) [LATENT_VECTOR_DIMS]f32 {
    var sum: f32 = 0.0;
    for (vector) |value| sum += value * value;
    if (sum <= 0.0) return .{ 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 };
    const magnitude = @sqrt(sum);
    var out = vector;
    for (&out) |*value| value.* /= magnitude;
    return out;
}

fn cosineSimilarity(a: [LATENT_VECTOR_DIMS]f32, b: [LATENT_VECTOR_DIMS]f32) f32 {
    const bn = normalizeVector(b);
    var dot: f32 = 0.0;
    for (a, bn) |av, bv| dot += av * bv;
    return dot;
}

fn scorePerMille(score: f32) u16 {
    const clipped = @max(@min(score, 1.0), 0.0);
    return @intFromFloat(clipped * 1000.0);
}

fn hasExplicitHeavyTaskSignal(normalized: []const u8) bool {
    const phrases = [_][]const u8{
        "make",      "improve",  "refactor", "implement", "add",         "fix",     "modify", "change", "patch",    "build", "create",
        "migrate",   "optimize", "clean",    "clean up",  "restructure", "convert", "write",  "verify", "validate", "test",  "check",
        "audit",     "confirm",  "prove",    "proof",     "explain",     "why",     "search", "find",   "show",     "list",  "extract",
        "summarize", "display",  "get",
    };
    for (phrases) |phrase| {
        if (containsBoundedPhrase(normalized, phrase) != null) return true;
    }
    return false;
}

fn isSocialToken(token: []const u8) bool {
    return std.mem.eql(u8, token, "thanks") or
        std.mem.eql(u8, token, "morning");
}

fn isQuestionToken(token: []const u8) bool {
    return std.mem.eql(u8, token, "what") or
        std.mem.eql(u8, token, "whats") or
        std.mem.eql(u8, token, "what's") or
        std.mem.eql(u8, token, "how") or
        std.mem.eql(u8, token, "why") or
        std.mem.eql(u8, token, "where") or
        std.mem.eql(u8, token, "when");
}

fn isArtifactToken(token: []const u8) bool {
    return std.mem.indexOf(u8, token, "/") != null or
        std.mem.indexOf(u8, token, ".zig") != null or
        std.mem.eql(u8, token, "file") or
        std.mem.eql(u8, token, "code") or
        std.mem.eql(u8, token, "engine") or
        std.mem.eql(u8, token, "module") or
        std.mem.eql(u8, token, "artifact");
}

fn isMutationToken(token: []const u8) bool {
    return std.mem.eql(u8, token, "refactor") or
        std.mem.eql(u8, token, "make") or
        std.mem.eql(u8, token, "improve") or
        std.mem.eql(u8, token, "implement") or
        std.mem.eql(u8, token, "add") or
        std.mem.eql(u8, token, "fix") or
        std.mem.eql(u8, token, "modify") or
        std.mem.eql(u8, token, "change") or
        std.mem.eql(u8, token, "patch") or
        std.mem.eql(u8, token, "build") or
        std.mem.eql(u8, token, "create") or
        std.mem.eql(u8, token, "migrate") or
        std.mem.eql(u8, token, "optimize") or
        std.mem.eql(u8, token, "clean") or
        std.mem.eql(u8, token, "restructure") or
        std.mem.eql(u8, token, "convert") or
        std.mem.eql(u8, token, "write");
}

fn isRetrievalToken(token: []const u8) bool {
    return std.mem.eql(u8, token, "summarize") or
        std.mem.eql(u8, token, "list") or
        std.mem.eql(u8, token, "show") or
        std.mem.eql(u8, token, "extract") or
        std.mem.eql(u8, token, "find") or
        std.mem.eql(u8, token, "search") or
        std.mem.eql(u8, token, "get") or
        std.mem.eql(u8, token, "display");
}

fn isVerificationToken(token: []const u8) bool {
    return std.mem.eql(u8, token, "verify") or
        std.mem.eql(u8, token, "check") or
        std.mem.eql(u8, token, "validate") or
        std.mem.eql(u8, token, "test") or
        std.mem.eql(u8, token, "confirm") or
        std.mem.eql(u8, token, "prove") or
        std.mem.eql(u8, token, "proof");
}

fn isMetaToken(token: []const u8) bool {
    return std.mem.eql(u8, token, "status") or
        std.mem.eql(u8, token, "state") or
        std.mem.eql(u8, token, "looking") or
        std.mem.eql(u8, token, "health") or
        std.mem.eql(u8, token, "architecture") or
        std.mem.eql(u8, token, "design") or
        std.mem.eql(u8, token, "analysis") or
        std.mem.eql(u8, token, "engine");
}

fn isEffortToken(token: []const u8) bool {
    return std.mem.eql(u8, token, "deep") or
        std.mem.eql(u8, token, "thorough") or
        std.mem.eql(u8, token, "full") or
        std.mem.eql(u8, token, "properly") or
        std.mem.eql(u8, token, "production");
}

// ── Internal: Vague Request Expansion ──────────────────────────────────

fn expandVagueRequest(allocator: std.mem.Allocator, normalized: []const u8) ?std.ArrayList(CandidateIntent) {
    for (VAGUE_PHRASES) |vp| {
        if (containsBoundedPhrase(normalized, vp.phrase) != null) {
            var candidates = std.ArrayList(CandidateIntent).init(allocator);
            for (vp.expansions) |exp| {
                const label = allocator.dupe(u8, exp.label) catch continue;
                const reason = allocator.dupe(u8, exp.reason) catch {
                    allocator.free(label);
                    continue;
                };
                candidates.append(.{
                    .action_surface = exp.action_surface,
                    .label = label,
                    .scope = .artifact_local,
                    .obligations = &.{},
                    .reason = reason,
                }) catch {
                    allocator.free(label);
                    allocator.free(reason);
                    continue;
                };
            }
            if (candidates.items.len > 0) return candidates;
            candidates.deinit();
            return null;
        }
    }
    return null;
}

// ── Internal: Artifact Binding ─────────────────────────────────────────

fn bindArtifacts(
    allocator: std.mem.Allocator,
    task: *const task_intent.Task,
    normalized: []const u8,
    options: GroundingOptions,
) ![]ArtifactBinding {
    var bindings = std.ArrayList(ArtifactBinding).init(allocator);
    errdefer {
        for (bindings.items) |*b| b.deinit(allocator);
        bindings.deinit();
    }

    // Explicit reference from task target.
    if (task.target.kind != .none and task.target.kind != .current_context) {
        if (task.target.spec) |spec| {
            try bindings.append(.{
                .artifact_id = try allocator.dupe(u8, spec),
                .source = .explicit_reference,
                .schema_name = try allocator.dupe(u8, ""),
                .confidence = 1000,
            });
        }
    }

    // Context binding from options.
    if (task.target.kind == .current_context) {
        if (options.context_target) |target| {
            try bindings.append(.{
                .artifact_id = try allocator.dupe(u8, target),
                .source = .implicit_context,
                .schema_name = try allocator.dupe(u8, ""),
                .confidence = 800,
            });
        }
    }

    // Deictic resolution: "this", "that", "it".
    if (bindings.items.len == 0) {
        const deictic_phrases = [_][]const u8{ "this", "that", "it" };
        for (deictic_phrases) |phrase| {
            if (containsBoundedPhrase(normalized, phrase) != null) {
                if (options.context_target) |target| {
                    try bindings.append(.{
                        .artifact_id = try allocator.dupe(u8, target),
                        .source = .implicit_context,
                        .schema_name = try allocator.dupe(u8, ""),
                        .confidence = 600,
                    });
                }
                break;
            }
        }
    }

    // Pack-based context if relevant.
    if (bindings.items.len == 0 and options.available_artifacts.len > 0) {
        // If there is exactly one available artifact, bind to it implicitly.
        if (options.available_artifacts.len == 1) {
            try bindings.append(.{
                .artifact_id = try allocator.dupe(u8, options.available_artifacts[0]),
                .source = .pack_based,
                .schema_name = try allocator.dupe(u8, ""),
                .confidence = 400,
            });
        }
        // Multiple artifacts → no binding (ambiguity, not guessing).
    }

    return bindings.toOwnedSlice();
}

// ── Internal: Constraint Extraction ────────────────────────────────────

fn extractGroundedConstraints(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(GroundedConstraint),
    task: *const task_intent.Task,
    normalized: []const u8,
    class: IntentClass,
) !void {
    // Transfer explicit constraints from v1.
    for (task.constraints) |constraint| {
        if (out.items.len >= MAX_INTENT_OBLIGATIONS) break;
        try out.append(.{
            .kind = constraint.kind,
            .value = if (constraint.value) |v| try allocator.dupe(u8, v) else null,
            .source = .user_explicit,
        });
    }

    // Inferred constraints based on classification.
    if (class == .transformation or class == .creation) {
        // Implicit: preserve behavior.
        if (!hasConstraintKind(out.items, .determinism)) {
            if (out.items.len < MAX_INTENT_OBLIGATIONS) {
                try out.append(.{
                    .kind = .determinism,
                    .source = .inferred_preserve_behavior,
                    .detail = try allocator.dupe(u8, "transformation/creation must preserve existing behavior"),
                });
            }
        }
        // Implicit: preserve structure.
        if (!hasConstraintKind(out.items, .api_stability)) {
            if (out.items.len < MAX_INTENT_OBLIGATIONS) {
                try out.append(.{
                    .kind = .api_stability,
                    .source = .inferred_preserve_structure,
                    .detail = try allocator.dupe(u8, "structural changes must maintain API contracts"),
                });
            }
        }
    }

    // Safety constraint for any intent involving "this" without context.
    if (containsBoundedPhrase(normalized, "this") != null and task.target.kind == .current_context) {
        if (!hasConstraintKind(out.items, .safety)) {
            if (out.items.len < MAX_INTENT_OBLIGATIONS) {
                try out.append(.{
                    .kind = .safety,
                    .source = .from_verifier,
                    .detail = try allocator.dupe(u8, "deictic reference without explicit binding requires safety verification"),
                });
            }
        }
    }
}

fn hasConstraintKind(items: []GroundedConstraint, kind: task_intent.ConstraintKind) bool {
    for (items) |item| {
        if (item.kind == kind) return true;
    }
    return false;
}

// ── Internal: Obligation Mapping ───────────────────────────────────────

fn mapObligations(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(IntentObligation),
    class: IntentClass,
    task: *const task_intent.Task,
    bindings: []ArtifactBinding,
) !void {
    _ = task;
    switch (class) {
        .conversation => {},
        .direct_action => {
            try appendObligation(allocator, out, "define_target", "identify the target artifact for the action", "direct_action");
            if (bindings.len == 0) {
                try appendObligation(allocator, out, "bind_artifact", "bind target artifact to the action", "direct_action");
            }
        },
        .transformation => {
            try appendObligation(allocator, out, "define_criteria", "define improvement/transform criteria", "transformation");
            try appendObligation(allocator, out, "bind_artifact", "bind target artifact to the transformation", "transformation");
            try appendObligation(allocator, out, "validate_result", "validate result preserves behavior", "transformation");
        },
        .diagnostic => {
            try appendObligation(allocator, out, "identify_symptom", "identify the symptom or question", "diagnostic");
            if (bindings.len == 0) {
                try appendObligation(allocator, out, "bind_artifact", "bind target artifact for diagnosis", "diagnostic");
            }
        },
        .creation => {
            try appendObligation(allocator, out, "define_spec", "define the creation specification", "creation");
            try appendObligation(allocator, out, "bind_artifact", "bind target artifact or location for creation", "creation");
            try appendObligation(allocator, out, "validate_result", "validate created artifact meets specification", "creation");
        },
        .verification => {
            try appendObligation(allocator, out, "define_criterion", "define the verification criterion", "verification");
            if (bindings.len == 0) {
                try appendObligation(allocator, out, "bind_artifact", "bind target artifact for verification", "verification");
            }
        },
        .ambiguous => {
            try appendObligation(allocator, out, "resolve_class", "resolve the intent classification", "ambiguous");
            try appendObligation(allocator, out, "bind_artifact", "bind target artifact to the intent", "ambiguous");
            try appendObligation(allocator, out, "define_action", "define the action to take", "ambiguous");
        },
    }

    // If artifact binding succeeded, mark bind_artifact as resolved.
    if (bindings.len > 0) {
        for (out.items) |*obl| {
            if (std.mem.eql(u8, obl.id, "bind_artifact")) {
                if (obl.resolved_by) |old| allocator.free(old);
                obl.resolved_by = try allocator.dupe(u8, bindings[0].artifact_id);
                obl.pending = false;
            }
        }
    }
}

fn appendObligation(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(IntentObligation),
    id: []const u8,
    label: []const u8,
    scope: []const u8,
) !void {
    if (out.items.len >= MAX_INTENT_OBLIGATIONS) return;
    try out.append(.{
        .id = try allocator.dupe(u8, id),
        .label = try allocator.dupe(u8, label),
        .scope = try allocator.dupe(u8, scope),
    });
}

// ── Internal: Scope Determination ──────────────────────────────────────

fn determineScope(bindings: []ArtifactBinding) IntentScope {
    if (bindings.len == 0) return .artifact_local;
    if (bindings.len == 1) return .artifact_local;
    return .cross_artifact;
}

// ── Internal: Action Surface Determination ─────────────────────────────

fn determineActionSurfaces(
    allocator: std.mem.Allocator,
    class: IntentClass,
    task: *const task_intent.Task,
) ![]artifact_schema.ActionSurface {
    var surfaces = std.ArrayList(artifact_schema.ActionSurface).init(allocator);
    errdefer surfaces.deinit();

    switch (class) {
        .conversation => {
            // No artifact action surface. This is a resolved conversational turn.
        },
        .direct_action => {
            try surfaces.append(.extract);
            if (containsBoundedPhrase(task.normalized_input, "summarize") != null) {
                try surfaces.append(.summarize);
            }
        },
        .transformation => {
            try surfaces.append(.transform);
            try surfaces.append(.patch);
        },
        .diagnostic => {
            try surfaces.append(.verify);
            try surfaces.append(.extract);
        },
        .creation => {
            try surfaces.append(.patch);
            try surfaces.append(.transform);
        },
        .verification => {
            try surfaces.append(.verify);
        },
        .ambiguous => {
            // No action surface for ambiguous intents.
        },
    }

    return surfaces.toOwnedSlice();
}

// ── Internal: Finalization ─────────────────────────────────────────────

fn finalizeGrounding(gi: *GroundedIntent) void {
    // Fast path eligibility:
    // - intent is unambiguous
    // - at least one artifact is bound
    // - no ambiguity sets
    // - no missing obligations
    const requires_artifact = intentClassRequiresArtifact(gi.intent_class);
    const unambiguous = gi.intent_class != .ambiguous;
    const has_binding = gi.artifact_bindings.len > 0;
    const no_ambiguity = gi.ambiguity_sets.len == 0;
    const no_missing = gi.missing_obligations.len == 0;

    gi.fast_path_eligible = unambiguous and (has_binding or !requires_artifact) and no_ambiguity and no_missing;

    if (gi.fast_path_eligible) {
        gi.status = .grounded;
        return;
    }

    // Partial grounding: some information present but blocked by ambiguity.
    const has_any_info = gi.artifact_bindings.len > 0 or gi.constraints.len > 0 or gi.obligations.len > 0;
    if (has_any_info and !no_ambiguity) {
        gi.status = .partially_grounded;
        return;
    }

    // Grounded if unambiguous with binding and no ambiguity, even if base task
    // was unresolved (v2 classification is independent of v1 parsing).
    if (unambiguous and (has_binding or !requires_artifact) and no_ambiguity and no_missing) {
        gi.status = .grounded;
        return;
    }

    // If base task is grounded and we have no ambiguity, we're grounded.
    if (gi.base_task.status == .grounded and (has_binding or !requires_artifact) and no_ambiguity and no_missing) {
        gi.status = .grounded;
        return;
    }

    gi.status = .unresolved;
}

// ── Internal: Utilities ────────────────────────────────────────────────

fn appendTrace(
    allocator: std.mem.Allocator,
    traces: *std.ArrayList(GroundingTrace),
    step: []const u8,
    input: []const u8,
    output: []const u8,
    detail: ?[]const u8,
) !void {
    if (traces.items.len >= MAX_GROUNDING_TRACES) return;
    try traces.append(.{
        .step = try allocator.dupe(u8, step),
        .input = try allocator.dupe(u8, input),
        .output = try allocator.dupe(u8, output),
        .detail = if (detail) |d| try allocator.dupe(u8, d) else null,
    });
}

fn containsBoundedPhrase(text: []const u8, phrase: []const u8) ?usize {
    var search_start: usize = 0;
    while (std.mem.indexOfPos(u8, text, search_start, phrase)) |idx| {
        const before_ok = idx == 0 or !isWordByte(text[idx - 1]);
        const end = idx + phrase.len;
        const after_ok = end >= text.len or !isWordByte(text[end]);
        if (before_ok and after_ok) return idx;
        search_start = idx + 1;
    }
    return null;
}

fn isWordByte(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or std.ascii.isDigit(byte) or byte == '_' or byte == '/' or byte == '.' or byte == ':';
}

test "intent grounding: latent conversation bypasses artifact obligations" {
    const allocator = std.testing.allocator;

    const inputs = [_][]const u8{
        "ok",
        "test",
        "whats up",
        "how is the audio engine looking",
    };
    for (inputs) |input| {
        var gi = try ground(allocator, input, .{});
        defer gi.deinit();

        try std.testing.expectEqual(IntentClass.conversation, gi.intent_class);
        try std.testing.expectEqual(GroundedIntent.GroundingStatus.grounded, gi.status);
        try std.testing.expectEqual(@as(usize, 0), gi.missing_obligations.len);
        try std.testing.expectEqual(@as(usize, 0), gi.obligations.len);
        try std.testing.expect(gi.fast_path_eligible);
    }
}

test "intent grounding: heavy modification still requires artifact binding" {
    const allocator = std.testing.allocator;

    var gi = try ground(allocator, "refactor this", .{});
    defer gi.deinit();

    try std.testing.expectEqual(IntentClass.transformation, gi.intent_class);
    try std.testing.expect(gi.missing_obligations.len > 0);
}

test "salience mapping isolates semantic target and density" {
    const allocator = std.testing.allocator;

    var salience = try analyzeSalience(allocator, "i require an exhaustive explanation regarding the nature of silicon computers");
    defer salience.deinit(allocator);

    try std.testing.expectEqualStrings("silicon computers", salience.semantic_target);
    try std.testing.expect(std.mem.indexOf(u8, salience.structural_noise, "exhaustive") != null);
    try std.testing.expect(salience.density_multiplier > 1);
}

test "zero entropy mapper rejects greetings as semantic targets" {
    try std.testing.expect(lacksSemanticTarget("hello"));
    try std.testing.expect(lacksSemanticTarget("ok"));
    try std.testing.expect(!lacksSemanticTarget("Explain how a CPU processes data"));
}

test "question prefixes do not enter imperative command path" {
    const allocator = std.testing.allocator;

    var imperative = try analyzeImperativeIntent(allocator, "whats a computer");
    defer imperative.deinit(allocator);

    try std.testing.expect(!imperative.detected);
}

test "global rune resonance treats programming cluster as content" {
    const allocator = std.testing.allocator;

    try std.testing.expect(!lacksSemanticTarget("what is code"));
    var salience = try analyzeSalience(allocator, "what is code");
    defer salience.deinit(allocator);

    try std.testing.expectEqualStrings("code", salience.semantic_target);
    try std.testing.expect(vsa_vulkan.globalRuneMatch("what is code").content.score_per_mille >= vsa_vulkan.GLOBAL_RUNE_RESONANCE_OVERRIDE_PER_MILLE);
}

test "global rune resonance sees squished sayghost command" {
    const allocator = std.testing.allocator;

    var imperative = try analyzeImperativeIntent(allocator, "sayghost");
    defer imperative.deinit(allocator);

    try std.testing.expect(imperative.detected);
    try std.testing.expectEqual(ImperativeTargetKind.exact, imperative.target_kind);
    try std.testing.expectEqualStrings("ghost", imperative.target);
    try std.testing.expect(imperative.strict_output);
}

test "generalist router uses ontological primitives across verification domains" {
    try std.testing.expectEqual(GeneralistRoute.general_chat, routeGeneralistIntent("Why is a variable like a bucket?"));
    try std.testing.expectEqual(GeneralistRoute.strict_verification, routeGeneralistIntent("verify src/native/widget.cpp:compute"));
    try std.testing.expectEqual(GeneralistRoute.strict_verification, routeGeneralistIntent("verify the logical consistency of a historical timeline from the Omni-Codex"));
}

test "ontology extraction abstracts C++ audit into primitives" {
    const allocator = std.testing.allocator;

    const primitives = try extractOntologicalPrimitives(allocator, "audit TrackManager.cpp against local axioms");
    defer freeOntologicalPrimitives(allocator, primitives);

    try std.testing.expect(hasOntologyConcept(primitives, .target_system_component));
    try std.testing.expect(hasOntologyConcept(primitives, .action_verify_integrity));
    try std.testing.expect(hasOntologyConcept(primitives, .constraint_local_axioms));
    try std.testing.expect(hasOntologyConcept(primitives, .evidence_cpp_component));
}

test "ontology extraction maps sovereign premise primitives" {
    const allocator = std.testing.allocator;
    const prompt =
        \\PROTOCOL_OVERRIDE: [Ontological_Inquiry]
        \\EXTRACT: Take the English premise: "A memory address that exists without an owner is a ghost in the machine."
        \\MAP: Deconstruct this into the primitives [Existence], [Ownership], and [Null_State].
        \\CROSS-VERIFY: Query the Omni-Codex for the intersection of [Ownership_Axioms] and [C++_Smart_Pointers].
        \\PROVE: Generate a C++ code block that intentionally creates this 'ghost' and pass it to the internal LLVM verifier.
    ;

    const primitives = try extractOntologicalPrimitives(allocator, prompt);
    defer freeOntologicalPrimitives(allocator, primitives);

    try std.testing.expect(hasOntologyConcept(primitives, .primitive_existence));
    try std.testing.expect(hasOntologyConcept(primitives, .primitive_ownership));
    try std.testing.expect(hasOntologyConcept(primitives, .primitive_null_state));
    try std.testing.expect(hasOntologyConcept(primitives, .constraint_ownership_axioms));
    try std.testing.expect(hasOntologyConcept(primitives, .evidence_cpp_smart_pointers));
    try std.testing.expect(hasOntologyConcept(primitives, .evidence_omni_codex));
    try std.testing.expect(hasOntologyConcept(primitives, .action_verify_integrity));
}

test "grounded intent exposes ontology primitives" {
    const allocator = std.testing.allocator;

    var gi = try ground(allocator, "audit TrackManager.cpp against local axioms", .{});
    defer gi.deinit();

    try std.testing.expect(hasOntologyConcept(gi.ontological_primitives, .target_system_component));
    try std.testing.expect(hasOntologyConcept(gi.ontological_primitives, .action_verify_integrity));
    try std.testing.expect(hasOntologyConcept(gi.ontological_primitives, .constraint_local_axioms));
}

test "imperative ngram shape isolates exact output target" {
    const allocator = std.testing.allocator;

    var imperative = try analyzeImperativeIntent(allocator, "say the word hint and only that");
    defer imperative.deinit(allocator);

    try std.testing.expect(imperative.detected);
    try std.testing.expectEqual(ImperativeTargetKind.exact, imperative.target_kind);
    try std.testing.expectEqualStrings("hint", imperative.target);
    try std.testing.expect(imperative.strict_output);
}

test "imperative ngram shape captures contextual negation" {
    const allocator = std.testing.allocator;

    var imperative = try analyzeImperativeIntent(allocator, "say something other than that");
    defer imperative.deinit(allocator);

    try std.testing.expect(imperative.detected);
    try std.testing.expect(imperative.references_previous_output);
    try std.testing.expectEqual(ImperativeTargetKind.vague, imperative.target_kind);
}

fn lowercaseAscii(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const out = try allocator.dupe(u8, text);
    for (out) |*byte| byte.* = std.ascii.toLower(byte.*);
    return out;
}

fn writeJsonFieldString(writer: anytype, field: []const u8, value: []const u8, first: bool) !void {
    if (!first) try writer.writeByte(',');
    try writeJsonString(writer, field);
    try writer.writeByte(':');
    try writeJsonString(writer, value);
}

fn writeOptionalStringField(writer: anytype, field: []const u8, value: []const u8) !void {
    try writer.writeByte(',');
    try writeJsonString(writer, field);
    try writer.writeByte(':');
    try writeJsonString(writer, value);
}

fn writeJsonString(writer: anytype, text: []const u8) !void {
    try writer.writeByte('"');
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
    try writer.writeByte('"');
}
