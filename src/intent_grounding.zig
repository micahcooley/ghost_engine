const std = @import("std");
const task_intent = @import("task_intent.zig");
const artifact_schema = @import("artifact_schema.zig");

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

// ── Intent Classification ──────────────────────────────────────────────

/// Deterministic classification of user input into intent categories.
/// Ties produce ambiguity_sets, not guesses.
pub const IntentClass = enum {
    direct_action,
    transformation,
    diagnostic,
    creation,
    verification,
    ambiguous,
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

/// An obligation produced by intent grounding. Every intent must produce
/// obligations; no obligation → no progression to supported.
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

    // Step 2: Classify intent.
    const classification = classifyIntent(normalized_form);
    result.intent_class = classification.class;
    if (classification.ambiguous) {
        try appendTrace(allocator, &traces, "classify", normalized_form, @tagName(IntentClass.ambiguous), "multiple classification phrases matched; ties produce ambiguity, not guesses");
    } else {
        try appendTrace(allocator, &traces, "classify", normalized_form, @tagName(classification.class), classification.matched_phrase orelse "inferred");
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

    // Step 4: Artifact binding.
    const bindings = try bindArtifacts(allocator, &base_task, normalized_form, options);
    // Transfer valid bindings.
    for (bindings) |binding| {
        if (artifact_bindings.items.len >= MAX_ARTIFACT_BINDINGS) break;
        try artifact_bindings.append(binding);
    }
    if (artifact_bindings.items.len == 0 and base_task.target.kind == .none) {
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

    // Step 5: Constraint extraction (explicit + inferred).
    try extractGroundedConstraints(allocator, &constraints, &base_task, normalized_form, classification.class);
    try appendTrace(allocator, &traces, "extract_constraints", normalized_form, "extracted", null);

    // Step 6: Intent → Obligation mapping.
    try mapObligations(allocator, &obligations, classification.class, &base_task, artifact_bindings.items);
    try appendTrace(allocator, &traces, "map_obligations", normalized_form, "mapped", null);

    // Step 7: Determine scope.
    result.scope = determineScope(artifact_bindings.items);

    // Step 8: Determine action surfaces.
    result.action_surfaces = try determineActionSurfaces(allocator, classification.class, &base_task);

    // Step 9: Finalize status.
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

// ── Internal: Classification ───────────────────────────────────────────

fn classifyIntent(normalized: []const u8) struct { class: IntentClass, ambiguous: bool, matched_phrase: ?[]const u8 } {
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
        return .{ .class = .ambiguous, .ambiguous = false, .matched_phrase = null };
    }
    return .{ .class = found_class.?, .ambiguous = ambiguous, .matched_phrase = found_phrase };
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
    // Every classification produces specific obligations.
    switch (class) {
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

    // If base task already has a target, mark bind_artifact as resolved.
    if (task.target.kind != .none and task.target.kind != .current_context) {
        for (out.items) |*obl| {
            if (std.mem.eql(u8, obl.id, "bind_artifact")) {
                if (obl.resolved_by) |old| allocator.free(old);
                obl.resolved_by = try allocator.dupe(u8, task.target.spec orelse "base_task_target");
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
    const unambiguous = gi.intent_class != .ambiguous;
    const has_binding = gi.artifact_bindings.len > 0;
    const no_ambiguity = gi.ambiguity_sets.len == 0;
    const no_missing = gi.missing_obligations.len == 0;

    gi.fast_path_eligible = unambiguous and has_binding and no_ambiguity and no_missing;

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
    if (unambiguous and has_binding and no_ambiguity and no_missing) {
        gi.status = .grounded;
        return;
    }

    // If base task is grounded and we have no ambiguity, we're grounded.
    if (gi.base_task.status == .grounded and no_ambiguity and no_missing) {
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
