const std = @import("std");
const abstractions = @import("abstractions.zig");
const code_intel = @import("code_intel.zig");
const compute_budget = @import("compute_budget.zig");
const shards = @import("shards.zig");

// ──────────────────────────────────────────────────────────────────────────
// Universal Artifact Schema Core
//
// All inputs are artifacts. An artifact is any bounded input surface. Ghost
// processes all artifacts through the same pipeline:
//
//   artifact → fragments → entities → relations → obligations
//
// No domain is architecturally privileged. The schema registry defines
// structure (entity types, relation types, action surfaces, verifier hooks)
// but never behavior overrides or bypass of support/proof gates.
// ──────────────────────────────────────────────────────────────────────────

pub const MAX_FRAGMENT_BYTES: usize = 16 * 1024;
pub const MAX_ENTITY_LABEL_BYTES: usize = 256;
pub const MAX_RELATION_LABEL_BYTES: usize = 128;
pub const MAX_SCHEMA_ENTITY_TYPES: usize = 16;
pub const MAX_SCHEMA_RELATION_TYPES: usize = 16;
pub const MAX_SCHEMA_ACTION_SURFACES: usize = 8;
pub const MAX_SCHEMA_VERIFIER_HOOKS: usize = 8;
pub const MAX_SCHEMA_NAME_BYTES: usize = 64;
pub const MAX_ARTIFACTS_PER_BATCH: usize = 32;
pub const MAX_ENTITIES_PER_FRAGMENT: usize = 16;
pub const MAX_RELATIONS_PER_BATCH: usize = 64;
pub const MAX_OBLIGATIONS_PER_BATCH: usize = 32;

// ── Core Types ──────────────────────────────────────────────────────────

/// Where an artifact originated.
pub const ArtifactSource = enum {
    repo,
    pack,
    web,
    user,
    scratch,
};

/// The physical form of an artifact.
pub const ArtifactType = enum {
    file,
    directory,
    corpus,
    document,
    mixed,
};

/// A bounded input surface — the universal input unit.
pub const Artifact = struct {
    id: []const u8,
    source: ArtifactSource,
    artifact_type: ArtifactType,
    /// Optional format hint (e.g. "zig", "json", "markdown"). Not trusted —
    /// the parser cascade determines actual structure.
    format_hint: ?[]const u8 = null,
    provenance: []const u8,
    trust_class: abstractions.TrustClass,
    /// Absolute or relative path to the artifact content.
    content_path: ?[]const u8 = null,
    /// Content hash for dedup and provenance.
    content_hash: u64 = 0,
    /// Schema name assigned during routing; empty until resolved.
    schema_name: []const u8 = "",

    /// Create an artifact with all strings owned by `allocator`.
    pub fn init(
        allocator: std.mem.Allocator,
        id: []const u8,
        source: ArtifactSource,
        artifact_type: ArtifactType,
        provenance: []const u8,
        trust_class: abstractions.TrustClass,
        format_hint: ?[]const u8,
        content_path: ?[]const u8,
        schema_name: ?[]const u8,
    ) !Artifact {
        return .{
            .id = try allocator.dupe(u8, id),
            .source = source,
            .artifact_type = artifact_type,
            .format_hint = if (format_hint) |h| try allocator.dupe(u8, h) else null,
            .provenance = try allocator.dupe(u8, provenance),
            .trust_class = trust_class,
            .content_path = if (content_path) |p| try allocator.dupe(u8, p) else null,
            .schema_name = if (schema_name) |s| try allocator.dupe(u8, s) else try allocator.dupe(u8, ""),
        };
    }

    pub fn deinit(self: *Artifact, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.provenance);
        allocator.free(self.schema_name);
        if (self.format_hint) |hint| allocator.free(hint);
        if (self.content_path) |path| allocator.free(path);
        self.* = undefined;
    }
};

/// Parser cascade stages reused from code_intel symbolic parser.
pub const ParserStage = enum {
    strict,
    robust,
    delimiter,
    fallback,
};

/// A bounded span of an artifact.
pub const Fragment = struct {
    /// Owning artifact id.
    artifact_id: []const u8,
    /// Byte offset within the artifact content.
    offset: usize,
    /// Line number (1-based) of the fragment start.
    line: u32,
    /// Region label (e.g. "lines 10-25").
    region: []const u8,
    /// Which parser stage produced this fragment.
    parser_stage: ParserStage,
    /// Raw text content of the fragment.
    raw_text: []const u8,
    provenance: []const u8,
    /// Index into the fragments array for cross-referencing.
    index: u32 = 0,

    pub fn deinit(self: *Fragment, allocator: std.mem.Allocator) void {
        allocator.free(self.artifact_id);
        allocator.free(self.region);
        allocator.free(self.raw_text);
        allocator.free(self.provenance);
        self.* = undefined;
    }
};

/// Typed unit extracted from fragments. Schema-extensible — no hardcoding
/// for "code only".
pub const Entity = struct {
    id: []const u8,
    /// Schema-defined type name (symbol, key, path, heading, section, value,
    /// instruction, function, type_decl, config_key, log_entry, etc.).
    entity_type: []const u8,
    /// The fragment index that produced this entity.
    fragment_index: u32,
    label: []const u8,
    provenance: []const u8,
    /// If true, this entity lacks full grounding.
    partially_grounded: bool = false,
    /// Optional detail string (e.g. a signature, a value).
    detail: ?[]const u8 = null,
    /// Artifact id this entity belongs to.
    artifact_id: []const u8,

    pub fn deinit(self: *Entity, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.entity_type);
        allocator.free(self.label);
        allocator.free(self.provenance);
        allocator.free(self.artifact_id);
        if (self.detail) |d| allocator.free(d);
        self.* = undefined;
    }
};

/// Typed connection between entities. Generic — no domain-specific shortcuts.
pub const Relation = enum {
    references,
    contains,
    depends_on,
    modifies,
    defines,
    implements,
    extends,
    contradicts,
    supports,
    ordered_before,
};

/// A required step for a claim/action to be valid. Integrates with the
/// existing support graph obligation nodes.
pub const Obligation = struct {
    id: []const u8,
    /// Human-readable label for the obligation.
    label: []const u8,
    scope: []const u8,
    /// The entity id this obligation is attached to.
    entity_id: []const u8,
    /// If true, this obligation has not been satisfied.
    pending: bool = true,
    detail: ?[]const u8 = null,

    pub fn deinit(self: *Obligation, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.label);
        allocator.free(self.scope);
        allocator.free(self.entity_id);
        if (self.detail) |d| allocator.free(d);
        self.* = undefined;
    }
};

/// A possible operation Ghost can perform. Domain-neutral.
pub const ActionSurface = enum {
    patch,
    transform,
    summarize,
    extract,
    verify,
    restructure,
    annotate,
};

/// An external or internal check. Abstract and domain-neutral.
pub const VerifierHook = struct {
    id: []const u8,
    label: []const u8,
    /// The verifier kind (build, test, runtime, schema_validation,
    /// consistency_check, freshness_check, etc.).
    hook_type: []const u8,
    /// If true, this hook must pass before promotion to supported.
    blocking: bool = true,
    /// The entity id this hook verifies.
    entity_id: ?[]const u8 = null,
    result: VerifierResult = .pending,

    pub fn deinit(self: *VerifierHook, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.label);
        allocator.free(self.hook_type);
        if (self.entity_id) |eid| allocator.free(eid);
        self.* = undefined;
    }
};

pub const VerifierResult = enum {
    pending,
    passed,
    failed,
    skipped,
};

// ── Schema Registry ─────────────────────────────────────────────────────

/// Defines structure for a class of artifacts. Schemas define entity types,
/// relation types, allowed action surfaces, and optional verifier hooks.
/// Schemas do NOT define behavior overrides or bypass support/proof gates.
pub const ArtifactSchema = struct {
    name: []const u8,
    entity_types: []const []const u8,
    relation_types: []const Relation,
    action_surfaces: []const ActionSurface,
    verifier_hooks: []const VerifierHookDef,

    pub fn deinit(self: *ArtifactSchema, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.entity_types.len > 0) {
            for (self.entity_types) |et| allocator.free(et);
            allocator.free(self.entity_types);
        }
        if (self.relation_types.len > 0) allocator.free(self.relation_types);
        if (self.action_surfaces.len > 0) allocator.free(self.action_surfaces);
        if (self.verifier_hooks.len > 0) {
            for (self.verifier_hooks) |vh| allocator.free(vh.hook_type);
            allocator.free(self.verifier_hooks);
        }
        self.* = undefined;
    }
};

/// Definition of a verifier hook within a schema (no runtime state).
pub const VerifierHookDef = struct {
    hook_type: []const u8,
    blocking: bool = true,
};

/// Schema registry: maps schema names to schema definitions.
/// No schema may bypass support/proof gates. No schema may introduce
/// special-case pipelines. Code schema is NOT privileged over others.
pub const SchemaRegistry = struct {
    allocator: std.mem.Allocator,
    entries: std.StringHashMap(ArtifactSchema),

    pub fn init(allocator: std.mem.Allocator) SchemaRegistry {
        return .{
            .allocator = allocator,
            .entries = std.StringHashMap(ArtifactSchema).init(allocator),
        };
    }

    pub fn deinit(self: *SchemaRegistry) void {
        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            var schema = entry.value_ptr.*;
            schema.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.entries.deinit();
        self.* = undefined;
    }

    pub fn register(self: *SchemaRegistry, schema: ArtifactSchema) !void {
        const owned_name = try self.allocator.dupe(u8, schema.name);
        errdefer self.allocator.free(owned_name);
        if (self.entries.fetchRemove(owned_name)) |removed| {
            self.allocator.free(removed.key);
            var old = removed.value;
            old.deinit(self.allocator);
        }
        try self.entries.put(owned_name, schema);
    }

    pub fn lookup(self: *const SchemaRegistry, name: []const u8) ?ArtifactSchema {
        return self.entries.get(name);
    }

    pub fn count(self: *const SchemaRegistry) usize {
        return self.entries.count();
    }
};

// ── Ingestion Pipeline ──────────────────────────────────────────────────

/// Complete pipeline output for a batch of artifacts.
pub const PipelineResult = struct {
    allocator: std.mem.Allocator,
    artifacts: []Artifact,
    fragments: []Fragment,
    entities: []Entity,
    relations: []RelationEdge,
    obligations: []Obligation,
    verifier_hooks: []VerifierHook,
    /// The schema name resolved for each artifact (parallel to artifacts).
    resolved_schemas: []const []const u8 = &.{},
    /// Malformed artifacts that still produced fragments (never collapsed).
    malformed_count: u32 = 0,
    /// Artifacts that could not be routed to any schema.
    unrouted_count: u32 = 0,
    /// Compute budget exhaustion if hit.
    budget_exhaustion: ?compute_budget.Exhaustion = null,
    /// Profile timing.
    profile: PipelineProfile = .{},

    pub fn deinit(self: *PipelineResult) void {
        for (self.artifacts) |*a| a.deinit(self.allocator);
        if (self.artifacts.len > 0) self.allocator.free(self.artifacts);
        for (self.fragments) |*f| f.deinit(self.allocator);
        if (self.fragments.len > 0) self.allocator.free(self.fragments);
        for (self.entities) |*e| e.deinit(self.allocator);
        if (self.entities.len > 0) self.allocator.free(self.entities);
        for (self.relations) |*r| r.deinit(self.allocator);
        if (self.relations.len > 0) self.allocator.free(self.relations);
        for (self.obligations) |*o| o.deinit(self.allocator);
        if (self.obligations.len > 0) self.allocator.free(self.obligations);
        for (self.verifier_hooks) |*v| v.deinit(self.allocator);
        if (self.verifier_hooks.len > 0) self.allocator.free(self.verifier_hooks);
        if (self.resolved_schemas.len > 0) self.allocator.free(self.resolved_schemas);
        if (self.budget_exhaustion) |*ex| ex.deinit();
        self.* = undefined;
    }
};

/// A typed edge connecting two entities.
pub const RelationEdge = struct {
    relation: Relation,
    from_entity_id: []const u8,
    to_entity_id: []const u8,
    provenance: []const u8,
    /// Fragment index that supports this relation.
    fragment_index: ?u32 = null,

    pub fn deinit(self: *RelationEdge, allocator: std.mem.Allocator) void {
        allocator.free(self.from_entity_id);
        allocator.free(self.to_entity_id);
        allocator.free(self.provenance);
        self.* = undefined;
    }
};

pub const PipelineProfile = struct {
    fragment_extract_ms: u64 = 0,
    entity_extract_ms: u64 = 0,
    relation_extract_ms: u64 = 0,
    schema_routing_ms: u64 = 0,
    obligation_attach_ms: u64 = 0,
};

/// Options for the artifact ingestion pipeline.
pub const PipelineOptions = struct {
    registry: *const SchemaRegistry,
    compute_budget_request: compute_budget.Request = .{},
    /// If true, entities may exist without full grounding.
    allow_partial: bool = true,
    /// If true, produce fragments even from malformed input.
    always_fragment: bool = true,
    /// Default trust class for artifacts without explicit class.
    default_trust_class: abstractions.TrustClass = .exploratory,
};

// ── Routing Signals ─────────────────────────────────────────────────────

/// Signals used for deterministic schema routing.
pub const RoutingSignals = struct {
    artifact_type: ArtifactType,
    format_hint: ?[]const u8,
    entity_type_counts: std.StringHashMap(u32),
    trust_class: abstractions.TrustClass,
    /// Schema hint from the artifact itself (not trusted).
    explicit_schema_hint: ?[]const u8 = null,
    /// Pack influence — schema names from mounted packs.
    pack_schema_hints: []const []const u8 = &.{},

    pub fn init(allocator: std.mem.Allocator) RoutingSignals {
        return .{
            .artifact_type = .document,
            .format_hint = null,
            .entity_type_counts = std.StringHashMap(u32).init(allocator),
            .trust_class = .exploratory,
        };
    }

    pub fn deinit(self: *RoutingSignals) void {
        self.entity_type_counts.deinit();
        self.* = undefined;
    }
};

// ── Built-in Example Schemas (for testing, not hardcoded logic) ─────────

/// Creates the code artifact schema. NOT privileged — goes through the same
/// pipeline as all other schemas.
pub fn builtinCodeSchema(allocator: std.mem.Allocator) !ArtifactSchema {
    const entity_types = try allocator.alloc([]const u8, 8);
    entity_types[0] = try allocator.dupe(u8, "symbol");
    entity_types[1] = try allocator.dupe(u8, "type_decl");
    entity_types[2] = try allocator.dupe(u8, "function");
    entity_types[3] = try allocator.dupe(u8, "variable");
    entity_types[4] = try allocator.dupe(u8, "constant");
    entity_types[5] = try allocator.dupe(u8, "import");
    entity_types[6] = try allocator.dupe(u8, "module");
    entity_types[7] = try allocator.dupe(u8, "annotation");

    const relation_types = try allocator.alloc(Relation, 5);
    relation_types[0] = .references;
    relation_types[1] = .contains;
    relation_types[2] = .depends_on;
    relation_types[3] = .defines;
    relation_types[4] = .implements;

    const action_surfaces = try allocator.alloc(ActionSurface, 3);
    action_surfaces[0] = .patch;
    action_surfaces[1] = .transform;
    action_surfaces[2] = .verify;

    const verifier_hooks = try allocator.alloc(VerifierHookDef, 3);
    verifier_hooks[0] = .{ .hook_type = try allocator.dupe(u8, "build"), .blocking = true };
    verifier_hooks[1] = .{ .hook_type = try allocator.dupe(u8, "test"), .blocking = true };
    verifier_hooks[2] = .{ .hook_type = try allocator.dupe(u8, "runtime"), .blocking = false };

    return .{
        .name = try allocator.dupe(u8, "code_artifact_schema"),
        .entity_types = entity_types,
        .relation_types = relation_types,
        .action_surfaces = action_surfaces,
        .verifier_hooks = verifier_hooks,
    };
}

/// Creates the document schema. Equal treatment to code schema.
pub fn builtinDocumentSchema(allocator: std.mem.Allocator) !ArtifactSchema {
    const entity_types = try allocator.alloc([]const u8, 6);
    entity_types[0] = try allocator.dupe(u8, "heading");
    entity_types[1] = try allocator.dupe(u8, "section");
    entity_types[2] = try allocator.dupe(u8, "paragraph");
    entity_types[3] = try allocator.dupe(u8, "link");
    entity_types[4] = try allocator.dupe(u8, "list_item");
    entity_types[5] = try allocator.dupe(u8, "code_block");

    const relation_types = try allocator.alloc(Relation, 4);
    relation_types[0] = .contains;
    relation_types[1] = .references;
    relation_types[2] = .ordered_before;
    relation_types[3] = .supports;

    const action_surfaces = try allocator.alloc(ActionSurface, 3);
    action_surfaces[0] = .summarize;
    action_surfaces[1] = .extract;
    action_surfaces[2] = .annotate;

    const verifier_hooks = try allocator.alloc(VerifierHookDef, 1);
    verifier_hooks[0] = .{ .hook_type = try allocator.dupe(u8, "consistency_check"), .blocking = false };

    return .{
        .name = try allocator.dupe(u8, "document_schema"),
        .entity_types = entity_types,
        .relation_types = relation_types,
        .action_surfaces = action_surfaces,
        .verifier_hooks = verifier_hooks,
    };
}

/// Creates the config schema. Equal treatment to code schema.
pub fn builtinConfigSchema(allocator: std.mem.Allocator) !ArtifactSchema {
    const entity_types = try allocator.alloc([]const u8, 5);
    entity_types[0] = try allocator.dupe(u8, "key");
    entity_types[1] = try allocator.dupe(u8, "value");
    entity_types[2] = try allocator.dupe(u8, "section");
    entity_types[3] = try allocator.dupe(u8, "comment");
    entity_types[4] = try allocator.dupe(u8, "include");

    const relation_types = try allocator.alloc(Relation, 3);
    relation_types[0] = .contains;
    relation_types[1] = .references;
    relation_types[2] = .depends_on;

    const action_surfaces = try allocator.alloc(ActionSurface, 3);
    action_surfaces[0] = .verify;
    action_surfaces[1] = .transform;
    action_surfaces[2] = .extract;

    const verifier_hooks = try allocator.alloc(VerifierHookDef, 1);
    verifier_hooks[0] = .{ .hook_type = try allocator.dupe(u8, "schema_validation"), .blocking = true };

    return .{
        .name = try allocator.dupe(u8, "config_schema"),
        .entity_types = entity_types,
        .relation_types = relation_types,
        .action_surfaces = action_surfaces,
        .verifier_hooks = verifier_hooks,
    };
}

/// Creates the log schema. Equal treatment to code schema.
pub fn builtinLogSchema(allocator: std.mem.Allocator) !ArtifactSchema {
    const entity_types = try allocator.alloc([]const u8, 5);
    entity_types[0] = try allocator.dupe(u8, "log_entry");
    entity_types[1] = try allocator.dupe(u8, "timestamp");
    entity_types[2] = try allocator.dupe(u8, "level");
    entity_types[3] = try allocator.dupe(u8, "message");
    entity_types[4] = try allocator.dupe(u8, "path");

    const relation_types = try allocator.alloc(Relation, 3);
    relation_types[0] = .ordered_before;
    relation_types[1] = .references;
    relation_types[2] = .supports;

    const action_surfaces = try allocator.alloc(ActionSurface, 2);
    action_surfaces[0] = .extract;
    action_surfaces[1] = .summarize;

    const verifier_hooks = try allocator.alloc(VerifierHookDef, 1);
    verifier_hooks[0] = .{ .hook_type = try allocator.dupe(u8, "freshness_check"), .blocking = false };

    return .{
        .name = try allocator.dupe(u8, "log_schema"),
        .entity_types = entity_types,
        .relation_types = relation_types,
        .action_surfaces = action_surfaces,
        .verifier_hooks = verifier_hooks,
    };
}

/// Register all built-in example schemas. For testing only — not hardcoded
/// logic paths. All schemas go through the same core pipeline.
pub fn registerBuiltinSchemas(registry: *SchemaRegistry) !void {
    try registry.register(try builtinCodeSchema(registry.allocator));
    try registry.register(try builtinDocumentSchema(registry.allocator));
    try registry.register(try builtinConfigSchema(registry.allocator));
    try registry.register(try builtinLogSchema(registry.allocator));
}

// ── Pipeline Implementation ─────────────────────────────────────────────

/// Routes an artifact to a schema using deterministic signals.
/// No fuzzy embedding shortcuts. No domain-specific routing hacks.
pub fn routeSchema(
    allocator: std.mem.Allocator,
    artifact: *const Artifact,
    signals: *const RoutingSignals,
    registry: *const SchemaRegistry,
) ?[]const u8 {
    // 1. Explicit schema hint from artifact (not trusted, but used if valid).
    if (artifact.schema_name.len > 0) {
        if (registry.lookup(artifact.schema_name)) |_| {
            return artifact.schema_name;
        }
    }

    // 2. Explicit hint from routing signals.
    if (signals.explicit_schema_hint) |hint| {
        if (registry.lookup(hint)) |_| {
            return hint;
        }
    }

    // 3. Deterministic routing based on format_hint + artifact_type.
    const format = artifact.format_hint orelse "";
    const type_name = @tagName(artifact.artifact_type);

    // Check format hints against registered schema entity types.
    // This is a simple prefix/suffix match, not fuzzy.
    if (std.mem.eql(u8, format, "zig") or
        std.mem.eql(u8, format, "rs") or
        std.mem.eql(u8, format, "py") or
        std.mem.eql(u8, format, "c") or
        std.mem.eql(u8, format, "h") or
        std.mem.eql(u8, format, "cpp") or
        std.mem.eql(u8, format, "java") or
        std.mem.eql(u8, format, "js") or
        std.mem.eql(u8, format, "ts"))
    {
        if (registry.lookup("code_artifact_schema")) |_| {
            return "code_artifact_schema";
        }
    }

    if (std.mem.eql(u8, format, "md") or
        std.mem.eql(u8, format, "txt") or
        std.mem.eql(u8, format, "rst") or
        std.mem.eql(u8, format, "html") or
        std.mem.eql(u8, format, "adoc"))
    {
        if (registry.lookup("document_schema")) |_| {
            return "document_schema";
        }
    }

    if (std.mem.eql(u8, format, "json") or
        std.mem.eql(u8, format, "yaml") or
        std.mem.eql(u8, format, "yml") or
        std.mem.eql(u8, format, "toml") or
        std.mem.eql(u8, format, "ini") or
        std.mem.eql(u8, format, "conf"))
    {
        if (registry.lookup("config_schema")) |_| {
            return "config_schema";
        }
    }

    if (std.mem.eql(u8, format, "log") or
        std.mem.eql(u8, type_name, "log"))
    {
        if (registry.lookup("log_schema")) |_| {
            return "log_schema";
        }
    }

    // 4. Entity type signal matching (if entities already extracted).
    var best_schema: ?[]const u8 = null;
    var best_score: u32 = 0;
    var schema_iter = registry.entries.iterator();
    while (schema_iter.next()) |entry| {
        const schema = entry.value_ptr.*;
        var score: u32 = 0;
        for (schema.entity_types) |et| {
            if (signals.entity_type_counts.get(et)) |count| {
                score += count;
            }
        }
        if (score > best_score) {
            best_score = score;
            best_schema = entry.key_ptr.*;
        }
    }

    if (best_schema) |name| {
        return name;
    }

    // 5. Pack influence hints.
    for (signals.pack_schema_hints) |hint| {
        if (registry.lookup(hint)) |_| {
            return hint;
        }
    }

    _ = allocator;
    return null;
}

/// Extracts fragments from artifact content using the parser cascade.
/// Malformed input still produces fragments — never collapses.
pub fn extractFragments(
    allocator: std.mem.Allocator,
    artifact: *const Artifact,
    content: []const u8,
    always_fragment: bool,
) ![]Fragment {
    var fragments = std.ArrayList(Fragment).init(allocator);
    errdefer {
        for (fragments.items) |*f| f.deinit(allocator);
        fragments.deinit();
    }

    if (content.len == 0) {
        // Even empty artifacts produce a single fragment.
        if (always_fragment) {
            const artifact_id = try allocator.dupe(u8, artifact.id);
            const region = try allocator.dupe(u8, "empty");
            const raw_text = try allocator.dupe(u8, "");
            const provenance = try allocator.dupe(u8, artifact.provenance);
            try fragments.append(.{
                .artifact_id = artifact_id,
                .offset = 0,
                .line = 1,
                .region = region,
                .parser_stage = .fallback,
                .raw_text = raw_text,
                .provenance = provenance,
                .index = 0,
            });
        }
        return fragments.toOwnedSlice();
    }

    // Parser cascade: try stages in order.
    // Stage 1: strict — line-based splitting on structured content.
    var lines = std.mem.splitSequence(u8, content, "\n");
    var line_num: u32 = 0;
    var current_offset: usize = 0;
    var used_strict = true;

    // Heuristic: if content has consistent structure, use strict parsing.
    // Otherwise fall through to robust/delimiter/fallback.
    const looks_structured = isStructured(content);

    while (lines.next()) |line| {
        line_num += 1;
        const line_end = current_offset + line.len;
        defer current_offset = if (line_end < content.len) line_end + 1 else line_end;

        if (line.len == 0) continue;
        if (line.len > MAX_FRAGMENT_BYTES) continue;

        const stage: ParserStage = if (looks_structured) .strict else blk: {
            if (isRobustLine(line)) break :blk .robust;
            if (isDelimiterLine(line)) break :blk .delimiter;
            used_strict = false;
            break :blk .fallback;
        };

        const artifact_id = try allocator.dupe(u8, artifact.id);
        const region = try std.fmt.allocPrint(allocator, "line {d}", .{line_num});
        const raw_text = try allocator.dupe(u8, line);
        const provenance = try allocator.dupe(u8, artifact.provenance);

        try fragments.append(.{
            .artifact_id = artifact_id,
            .offset = current_offset,
            .line = line_num,
            .region = region,
            .parser_stage = stage,
            .raw_text = raw_text,
            .provenance = provenance,
            .index = @intCast(fragments.items.len),
        });
    }

    // If no fragments were produced but always_fragment is set, produce one
    // fallback fragment from the entire content.
    if (fragments.items.len == 0 and always_fragment) {
        const trimmed = std.mem.trimRight(u8, content, " \t\r\n");
        const text = if (trimmed.len > MAX_FRAGMENT_BYTES) trimmed[0..MAX_FRAGMENT_BYTES] else trimmed;
        const artifact_id = try allocator.dupe(u8, artifact.id);
        const region = try allocator.dupe(u8, "entire");
        const raw_text = try allocator.dupe(u8, text);
        const provenance = try allocator.dupe(u8, artifact.provenance);
        try fragments.append(.{
            .artifact_id = artifact_id,
            .offset = 0,
            .line = 1,
            .region = region,
            .parser_stage = .fallback,
            .raw_text = raw_text,
            .provenance = provenance,
            .index = 0,
        });
    }

    return fragments.toOwnedSlice();
}

/// Extracts entities from fragments based on schema entity types.
/// Entities can exist without full grounding (partial understanding).
pub fn extractEntities(
    allocator: std.mem.Allocator,
    artifact: *const Artifact,
    fragments: []const Fragment,
    schema: *const ArtifactSchema,
) ![]Entity {
    var entities = std.ArrayList(Entity).init(allocator);
    errdefer {
        for (entities.items) |*e| e.deinit(allocator);
        entities.deinit();
    }

    for (fragments) |fragment| {
        const text = std.mem.trim(u8, fragment.raw_text, " \t\r");
        if (text.len == 0) continue;

        // Try each entity type defined by the schema.
        for (schema.entity_types) |entity_type| {
            if (entities.items.len >= MAX_ENTITIES_PER_FRAGMENT * fragments.len) break;

            if (matchesEntityType(text, entity_type)) {
                const id = try std.fmt.allocPrint(allocator, "{s}:{s}:{d}", .{ artifact.id, entity_type, fragment.line });
                const label = try extractLabel(allocator, text, entity_type);
                const provenance = try allocator.dupe(u8, fragment.provenance);
                const artifact_id = try allocator.dupe(u8, artifact.id);
                const et = try allocator.dupe(u8, entity_type);

                try entities.append(.{
                    .id = id,
                    .entity_type = et,
                    .fragment_index = fragment.index,
                    .label = label,
                    .provenance = provenance,
                    .partially_grounded = false,
                    .detail = null,
                    .artifact_id = artifact_id,
                });
            }
        }
    }

    return entities.toOwnedSlice();
}

/// Extracts relations between entities within the same artifact.
/// Relations must be explicit, not inferred silently.
pub fn extractRelations(
    allocator: std.mem.Allocator,
    entities: []const Entity,
    schema: *const ArtifactSchema,
    provenance: []const u8,
) ![]RelationEdge {
    var relations = std.ArrayList(RelationEdge).init(allocator);
    errdefer {
        for (relations.items) |*r| r.deinit(allocator);
        relations.deinit();
    }

    // For entities within the same artifact, apply containment relations.
    // Only emit relations for allowed relation types in the schema.
    const allows_contains = containsRelation(schema.relation_types, .contains);
    const allows_references = containsRelation(schema.relation_types, .references);
    const allows_depends = containsRelation(schema.relation_types, .depends_on);

    // Section/heading entities contain subsequent entities until next section.
    var last_container: ?usize = null;
    for (entities, 0..) |entity, i| {
        if (std.mem.eql(u8, entity.entity_type, "section") or
            std.mem.eql(u8, entity.entity_type, "heading") or
            std.mem.eql(u8, entity.entity_type, "module") or
            std.mem.eql(u8, entity.entity_type, "type_decl"))
        {
            last_container = i;
        } else if (last_container) |container_idx| {
            if (allows_contains and entities[container_idx].artifact_id.len > 0 and
                std.mem.eql(u8, entities[container_idx].artifact_id, entity.artifact_id))
            {
                const from_id = try allocator.dupe(u8, entities[container_idx].id);
                const to_id = try allocator.dupe(u8, entity.id);
                const prov = try allocator.dupe(u8, provenance);
                try relations.append(.{
                    .relation = .contains,
                    .from_entity_id = from_id,
                    .to_entity_id = to_id,
                    .provenance = prov,
                    .fragment_index = entity.fragment_index,
                });
            }
        }

        // Reference detection: look for cross-references in labels.
        if (allows_references and i > 0) {
            for (entities[0..i]) |other| {
                if (std.mem.eql(u8, other.artifact_id, entity.artifact_id)) continue;
                if (referencesEntity(entity.label, other.label)) {
                    const from_id = try allocator.dupe(u8, entity.id);
                    const to_id = try allocator.dupe(u8, other.id);
                    const prov = try allocator.dupe(u8, provenance);
                    try relations.append(.{
                        .relation = .references,
                        .from_entity_id = from_id,
                        .to_entity_id = to_id,
                        .provenance = prov,
                        .fragment_index = entity.fragment_index,
                    });
                }
            }
        }

        // Dependency detection for import/include entities.
        if (allows_depends and
            (std.mem.eql(u8, entity.entity_type, "import") or
                std.mem.eql(u8, entity.entity_type, "include") or
                std.mem.eql(u8, entity.entity_type, "depends_on")))
        {
            // Look for matching symbols in other entities.
            for (entities[0..i]) |other| {
                if (std.mem.eql(u8, other.artifact_id, entity.artifact_id)) continue;
                if (labelContains(entity.label, other.label)) {
                    const from_id = try allocator.dupe(u8, entity.id);
                    const to_id = try allocator.dupe(u8, other.id);
                    const prov = try allocator.dupe(u8, provenance);
                    try relations.append(.{
                        .relation = .depends_on,
                        .from_entity_id = from_id,
                        .to_entity_id = to_id,
                        .provenance = prov,
                        .fragment_index = entity.fragment_index,
                    });
                }
            }
        }

        if (relations.items.len >= MAX_RELATIONS_PER_BATCH) break;
    }

    return relations.toOwnedSlice();
}

/// Attaches obligations to entities based on schema verifier hooks.
/// Obligations must block promotion to supported.
pub fn attachObligations(
    allocator: std.mem.Allocator,
    entities: []const Entity,
    schema: *const ArtifactSchema,
) ![]Obligation {
    var obligations = std.ArrayList(Obligation).init(allocator);
    errdefer {
        for (obligations.items) |*o| o.deinit(allocator);
        obligations.deinit();
    }

    for (schema.verifier_hooks) |hook_def| {
        if (!hook_def.blocking) continue;

        for (entities) |entity| {
            if (obligations.items.len >= MAX_OBLIGATIONS_PER_BATCH) break;

            const id = try std.fmt.allocPrint(allocator, "obl:{s}:{s}", .{ hook_def.hook_type, entity.id });
            const label = try std.fmt.allocPrint(allocator, "verify {s} for {s}", .{ hook_def.hook_type, entity.label });
            const scope = try allocator.dupe(u8, schema.name);
            const entity_id = try allocator.dupe(u8, entity.id);

            try obligations.append(.{
                .id = id,
                .label = label,
                .scope = scope,
                .entity_id = entity_id,
                .pending = true,
                .detail = null,
            });
        }
    }

    return obligations.toOwnedSlice();
}

/// Creates verifier hook instances from schema definitions.
pub fn createVerifierHooks(
    allocator: std.mem.Allocator,
    entities: []const Entity,
    schema: *const ArtifactSchema,
) ![]VerifierHook {
    _ = entities;
    var hooks = std.ArrayList(VerifierHook).init(allocator);
    errdefer {
        for (hooks.items) |*h| h.deinit(allocator);
        hooks.deinit();
    }

    for (schema.verifier_hooks) |hook_def| {
        const id = try std.fmt.allocPrint(allocator, "vh:{s}", .{hook_def.hook_type});
        const label = try std.fmt.allocPrint(allocator, "{s} verification", .{hook_def.hook_type});
        const hook_type = try allocator.dupe(u8, hook_def.hook_type);

        try hooks.append(.{
            .id = id,
            .label = label,
            .hook_type = hook_type,
            .blocking = hook_def.blocking,
            .entity_id = null,
            .result = .pending,
        });
    }

    return hooks.toOwnedSlice();
}

/// Runs the full pipeline for a single artifact:
///   artifact → fragments → entities → relations → obligations
pub fn ingestArtifact(
    allocator: std.mem.Allocator,
    artifact: *const Artifact,
    content: []const u8,
    options: *const PipelineOptions,
) !PipelineResult {
    // 1. Route to schema.
    var signals = RoutingSignals.init(allocator);
    defer signals.deinit();
    signals.artifact_type = artifact.artifact_type;
    signals.format_hint = artifact.format_hint;
    signals.trust_class = artifact.trust_class;
    signals.explicit_schema_hint = if (artifact.schema_name.len > 0) artifact.schema_name else null;

    const schema_name = routeSchema(allocator, artifact, &signals, options.registry) orelse "unknown";
    const schema = options.registry.lookup(schema_name);

    const owned_schema_name = try allocator.dupe(u8, schema_name);
    errdefer allocator.free(owned_schema_name);

    // 2. Extract fragments (malformed input still produces fragments).
    const fragments = try extractFragments(allocator, artifact, content, options.always_fragment);

    // 3. Extract entities from fragments using schema entity types.
    var entities: []Entity = &.{};
    if (schema) |s| {
        entities = try extractEntities(allocator, artifact, fragments, &s);
    }

    // 4. Extract relations between entities.
    var relations: []RelationEdge = &.{};
    if (schema) |s| {
        relations = try extractRelations(allocator, entities, &s, artifact.provenance);
    }

    // 5. Attach obligations based on schema verifier hooks.
    var obligations: []Obligation = &.{};
    if (schema) |s| {
        obligations = try attachObligations(allocator, entities, &s);
    }

    // 6. Create verifier hooks from schema.
    var verifier_hooks: []VerifierHook = &.{};
    if (schema) |s| {
        verifier_hooks = try createVerifierHooks(allocator, entities, &s);
    }

    const artifacts_slice = try allocator.alloc(Artifact, 1);
    artifacts_slice[0] = .{
        .id = try allocator.dupe(u8, artifact.id),
        .source = artifact.source,
        .artifact_type = artifact.artifact_type,
        .format_hint = if (artifact.format_hint) |h| try allocator.dupe(u8, h) else null,
        .provenance = try allocator.dupe(u8, artifact.provenance),
        .trust_class = artifact.trust_class,
        .content_path = if (artifact.content_path) |p| try allocator.dupe(u8, p) else null,
        .content_hash = artifact.content_hash,
        .schema_name = owned_schema_name,
    };

    return .{
        .allocator = allocator,
        .artifacts = artifacts_slice,
        .fragments = fragments,
        .entities = entities,
        .relations = relations,
        .obligations = obligations,
        .verifier_hooks = verifier_hooks,
        .malformed_count = 0,
        .unrouted_count = if (schema == null) 1 else 0,
        .budget_exhaustion = null,
        .profile = .{},
    };
}

// ── Support Graph Extension Helpers ─────────────────────────────────────

/// Creates support graph nodes for artifact pipeline elements.
/// All claims must originate from fragment-backed entities.
pub fn appendArtifactSupportNodes(
    allocator: std.mem.Allocator,
    graph: *code_intel.SupportGraph,
    result: *const PipelineResult,
) !void {
    var nodes = std.ArrayList(code_intel.SupportGraphNode).init(allocator);
    errdefer {
        for (nodes.items) |n| {
            allocator.free(n.id);
            allocator.free(n.label);
        }
        nodes.deinit();
    }

    // Artifact nodes
    for (result.artifacts) |artifact| {
        try nodes.append(.{
            .id = try std.fmt.allocPrint(allocator, "artifact:{s}", .{artifact.id}),
            .kind = .artifact,
            .label = try allocator.dupe(u8, artifact.id),
            .rel_path = if (artifact.content_path) |p| try allocator.dupe(u8, p) else null,
            .line = 0,
            .score = 0,
            .usable = true,
            .detail = null,
        });
    }

    // Fragment nodes
    for (result.fragments) |fragment| {
        try nodes.append(.{
            .id = try std.fmt.allocPrint(allocator, "fragment:{s}:{d}", .{ fragment.artifact_id, fragment.index }),
            .kind = .fragment,
            .label = try std.fmt.allocPrint(allocator, "{s} @ {s}", .{ fragment.artifact_id, fragment.region }),
            .rel_path = null,
            .line = fragment.line,
            .score = 0,
            .usable = true,
            .detail = try std.fmt.allocPrint(allocator, "parser_stage={s}", .{@tagName(fragment.parser_stage)}),
        });
    }

    // Entity nodes
    for (result.entities) |entity| {
        try nodes.append(.{
            .id = try std.fmt.allocPrint(allocator, "entity:{s}", .{entity.id}),
            .kind = .entity,
            .label = try allocator.dupe(u8, entity.label),
            .rel_path = null,
            .line = 0,
            .score = if (entity.partially_grounded) 0 else 1,
            .usable = !entity.partially_grounded,
            .detail = try std.fmt.allocPrint(allocator, "type={s}", .{entity.entity_type}),
        });
    }

    // Obligation nodes — these block promotion to supported.
    for (result.obligations) |obligation| {
        try nodes.append(.{
            .id = try std.fmt.allocPrint(allocator, "obligation:{s}", .{obligation.id}),
            .kind = .obligation,
            .label = try allocator.dupe(u8, obligation.label),
            .rel_path = null,
            .line = 0,
            .score = 0,
            .usable = !obligation.pending,
            .detail = obligation.detail,
        });
    }

    // Append to existing graph
    const old_nodes = graph.nodes;
    defer {
        if (old_nodes.len > 0) allocator.free(old_nodes);
    }
    var all_nodes = std.ArrayList(code_intel.SupportGraphNode).init(allocator);
    if (old_nodes.len > 0) try all_nodes.appendSlice(old_nodes);
    try all_nodes.appendSlice(nodes.items);
    graph.nodes = try all_nodes.toOwnedSlice();
    nodes.items.len = 0; // prevent double-free in errdefer
    nodes.deinit();
}

// ── Internal Helpers ─────────────────────────────────────────────────────

fn isStructured(content: []const u8) bool {
    if (content.len < 10) return false;
    var line_count: u32 = 0;
    var indent_count: u32 = 0;
    var brace_count: u32 = 0;
    for (content) |ch| {
        if (ch == '\n') line_count += 1;
        if (ch == ' ' or ch == '\t') indent_count += 1;
        if (ch == '{' or ch == '}' or ch == '(' or ch == ')' or ch == '[' or ch == ']') brace_count += 1;
    }
    if (line_count == 0) return false;
    return brace_count > line_count / 4 or indent_count > line_count * 2;
}

fn isRobustLine(line: []const u8) bool {
    // Lines with common delimiters or structural markers.
    for (line) |ch| {
        if (ch == ':' or ch == '=' or ch == '-' or ch == '#' or ch == '/') return true;
    }
    return false;
}

fn isDelimiterLine(line: []const u8) bool {
    // Lines that are primarily delimiters (---, ===, ***).
    if (line.len < 3) return false;
    const first = line[0];
    if (first != '-' and first != '=' and first != '*' and first != '#') return false;
    for (line) |ch| {
        if (ch != first and ch != ' ' and ch != '\t' and ch != '\r') return false;
    }
    return true;
}

fn matchesEntityType(text: []const u8, entity_type: []const u8) bool {
    // Code entities
    if (std.mem.eql(u8, entity_type, "symbol")) {
        // Identifiers: starts with alpha/underscore, contains alphanumeric/underscore.
        if (text.len < 2) return false;
        if (!std.ascii.isAlphanumeric(text[0]) and text[0] != '_') return false;
        for (text) |ch| {
            if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '.') return false;
        }
        return true;
    }
    if (std.mem.eql(u8, entity_type, "function")) {
        // Heuristic: contains 'fn ', 'func ', 'def ', 'function ', or has parens with name.
        if (std.mem.indexOf(u8, text, "fn ") != null) return true;
        if (std.mem.indexOf(u8, text, "func ") != null) return true;
        if (std.mem.indexOf(u8, text, "def ") != null) return true;
        if (std.mem.indexOf(u8, text, "function ") != null) return true;
        if (std.mem.indexOf(u8, text, "pub fn ") != null) return true;
        if (std.mem.indexOf(u8, text, "pub ") != null and std.mem.indexOf(u8, text, "(") != null) return true;
        return false;
    }
    if (std.mem.eql(u8, entity_type, "type_decl")) {
        if (std.mem.indexOf(u8, text, "const ") != null and std.mem.indexOf(u8, text, "= struct") != null) return true;
        if (std.mem.indexOf(u8, text, "struct ") != null) return true;
        if (std.mem.indexOf(u8, text, "enum ") != null) return true;
        if (std.mem.indexOf(u8, text, "type ") != null) return true;
        if (std.mem.indexOf(u8, text, "class ") != null) return true;
        if (std.mem.indexOf(u8, text, "interface ") != null) return true;
        return false;
    }
    if (std.mem.eql(u8, entity_type, "variable")) {
        if (std.mem.indexOf(u8, text, "var ") != null or
            std.mem.indexOf(u8, text, "let ") != null or
            std.mem.indexOf(u8, text, "const ") != null or
            std.mem.indexOf(u8, text, "local ") != null) return true;
        // Simple assignment: identifier = value
        if (std.mem.indexOf(u8, text, " = ") != null and
            std.mem.indexOf(u8, text, "fn ") == null and
            std.mem.indexOf(u8, text, "struct ") == null) return true;
        return false;
    }
    if (std.mem.eql(u8, entity_type, "constant")) {
        if (std.mem.indexOf(u8, text, "const ") != null) return true;
        // All uppercase with underscores heuristic.
        var all_upper = true;
        for (text) |ch| {
            if (std.ascii.isAlphanumeric(ch) and !std.ascii.isUpper(ch) and ch != '_') {
                all_upper = false;
                break;
            }
        }
        if (all_upper and text.len > 2) return true;
        return false;
    }
    if (std.mem.eql(u8, entity_type, "import")) {
        if (std.mem.indexOf(u8, text, "import ") != null or
            std.mem.indexOf(u8, text, "@import") != null or
            std.mem.indexOf(u8, text, "require(") != null or
            std.mem.indexOf(u8, text, "from ") != null or
            std.mem.indexOf(u8, text, "#include") != null or
            std.mem.indexOf(u8, text, "use ") != null) return true;
        return false;
    }
    if (std.mem.eql(u8, entity_type, "module")) {
        if (std.mem.indexOf(u8, text, "module ") != null or
            std.mem.indexOf(u8, text, "pub const ") != null or
            std.mem.indexOf(u8, text, "package ") != null) return true;
        return false;
    }
    if (std.mem.eql(u8, entity_type, "annotation")) {
        if (text.len > 1 and text[0] == '@') return true;
        if (std.mem.indexOf(u8, text, "// ") != null) return true;
        if (std.mem.indexOf(u8, text, "///") != null) return true;
        return false;
    }

    // Document entities
    if (std.mem.eql(u8, entity_type, "heading")) {
        if (text.len > 0 and text[0] == '#') return true;
        if (text.len > 0 and (text[0] == '=' or text[0] == '-')) {
            // Could be a setext heading underline — check previous line.
            return false;
        }
        return false;
    }
    if (std.mem.eql(u8, entity_type, "section")) {
        // A section is a heading with content — detected by heading presence.
        if (text.len > 0 and text[0] == '#') return true;
        return false;
    }
    if (std.mem.eql(u8, entity_type, "paragraph")) {
        if (text.len > 20 and
            text[0] != '#' and
            text[0] != '-' and
            text[0] != '*' and
            text[0] != '>' and
            std.mem.indexOf(u8, text, " ") != null) return true;
        return false;
    }
    if (std.mem.eql(u8, entity_type, "link")) {
        if (std.mem.indexOf(u8, text, "](http") != null) return true;
        if (std.mem.indexOf(u8, text, "](/") != null) return true;
        if (std.mem.indexOf(u8, text, "href=") != null) return true;
        return false;
    }
    if (std.mem.eql(u8, entity_type, "list_item")) {
        if (text.len > 2) {
            if (text[0] == '-' and text[1] == ' ') return true;
            if (text[0] == '*' and text[1] == ' ') return true;
            if (text[0] == '+' and text[1] == ' ') return true;
            if (std.ascii.isDigit(text[0]) and text.len > 1 and (text[1] == '.' or text[1] == ')')) return true;
        }
        return false;
    }
    if (std.mem.eql(u8, entity_type, "code_block")) {
        if (std.mem.startsWith(u8, text, "```")) return true;
        if (std.mem.startsWith(u8, text, "    ") and text.len > 8) return true;
        if (std.mem.startsWith(u8, text, "\t") and text.len > 4) return true;
        return false;
    }

    // Config entities
    if (std.mem.eql(u8, entity_type, "key")) {
        // key = value or key: value
        if (std.mem.indexOf(u8, text, " = ") != null or
            std.mem.indexOf(u8, text, ": ") != null) {
            // Not a heading.
            if (text[0] != '#') return true;
        }
        return false;
    }
    if (std.mem.eql(u8, entity_type, "value")) {
        if (std.mem.indexOf(u8, text, " = ") != null or
            std.mem.indexOf(u8, text, ": ") != null) return true;
        return false;
    }
    if (std.mem.eql(u8, entity_type, "config_section")) {
        if (text.len > 2 and text[0] == '[' and text[text.len - 1] == ']') return true;
        if (std.mem.startsWith(u8, text, "[") and std.mem.indexOf(u8, text, "]") != null) return true;
        return false;
    }
    if (std.mem.eql(u8, entity_type, "comment")) {
        if (std.mem.startsWith(u8, text, "//") or
            std.mem.startsWith(u8, text, "#") or
            std.mem.startsWith(u8, text, ";") or
            std.mem.startsWith(u8, text, "--")) return true;
        return false;
    }
    if (std.mem.eql(u8, entity_type, "include")) {
        if (std.mem.indexOf(u8, text, "include") != null or
            std.mem.indexOf(u8, text, "import") != null) return true;
        return false;
    }

    // Log entities
    if (std.mem.eql(u8, entity_type, "log_entry")) {
        // Timestamp patterns at line start.
        if (text.len > 10) {
            // ISO timestamp: YYYY-MM-DD or YYYY/MM/DD
            if (std.ascii.isDigit(text[0]) and std.ascii.isDigit(text[1]) and
                std.ascii.isDigit(text[2]) and std.ascii.isDigit(text[3]) and
                (text[4] == '-' or text[4] == '/')) return true;
            // [timestamp] pattern
            if (text[0] == '[') return true;
        }
        return false;
    }
    if (std.mem.eql(u8, entity_type, "timestamp")) {
        if (std.mem.indexOf(u8, text, "T") != null and
            (std.mem.indexOf(u8, text, ":") != null)) return true;
        if (std.mem.indexOf(u8, text, "AM") != null or std.mem.indexOf(u8, text, "PM") != null) return true;
        return false;
    }
    if (std.mem.eql(u8, entity_type, "level")) {
        const upper = std.ascii.isUpper(text[0]);
        if (upper) {
            if (std.mem.startsWith(u8, text, "ERROR") or
                std.mem.startsWith(u8, text, "WARN") or
                std.mem.startsWith(u8, text, "INFO") or
                std.mem.startsWith(u8, text, "DEBUG") or
                std.mem.startsWith(u8, text, "TRACE") or
                std.mem.startsWith(u8, text, "FATAL") or
                std.mem.startsWith(u8, text, "SEVERE")) return true;
        }
        // [LEVEL] pattern
        if (std.mem.startsWith(u8, text, "[ERROR]") or
            std.mem.startsWith(u8, text, "[WARN") or
            std.mem.startsWith(u8, text, "[INFO") or
            std.mem.startsWith(u8, text, "[DEBUG")) return true;
        return false;
    }
    if (std.mem.eql(u8, entity_type, "message")) {
        return text.len > 10;
    }
    if (std.mem.eql(u8, entity_type, "path")) {
        if (std.mem.indexOf(u8, text, "/") != null and
            (std.mem.indexOf(u8, text, ".") != null or std.mem.indexOf(u8, text, "/src/") != null)) return true;
        return false;
    }

    // Default: no match for unknown entity types.
    return false;
}

fn extractLabel(allocator: std.mem.Allocator, text: []const u8, entity_type: []const u8) ![]u8 {
    // For most entity types, use the first token or the whole line (truncated).
    const max_len = 64;

    if (std.mem.eql(u8, entity_type, "heading")) {
        // Strip leading # and spaces.
        var start: usize = 0;
        while (start < text.len and (text[start] == '#' or text[start] == ' ')) start += 1;
        const end = @min(text.len, start + max_len);
        return allocator.dupe(u8, text[start..end]);
    }

    if (std.mem.eql(u8, entity_type, "key")) {
        // Take everything before = or :.
        if (std.mem.indexOf(u8, text, " = ")) |idx| {
            return allocator.dupe(u8, std.mem.trim(u8, text[0..idx], " \t"));
        }
        if (std.mem.indexOf(u8, text, ": ")) |idx| {
            return allocator.dupe(u8, std.mem.trim(u8, text[0..idx], " \t"));
        }
    }

    if (std.mem.eql(u8, entity_type, "value")) {
        // Take everything after = or :.
        if (std.mem.indexOf(u8, text, " = ")) |idx| {
            const start = idx + 3;
            const end = @min(text.len, start + max_len);
            return allocator.dupe(u8, std.mem.trim(u8, text[start..end], " \t"));
        }
        if (std.mem.indexOf(u8, text, ": ")) |idx| {
            const start = idx + 2;
            const end = @min(text.len, start + max_len);
            return allocator.dupe(u8, std.mem.trim(u8, text[start..end], " \t"));
        }
    }

    // Default: first token up to max_len.
    var end: usize = 0;
    while (end < text.len and end < max_len and text[end] != ' ' and text[end] != '\t') end += 1;
    if (end == 0) end = @min(text.len, max_len);
    return allocator.dupe(u8, text[0..end]);
}

fn containsRelation(relations: []const Relation, target: Relation) bool {
    for (relations) |r| {
        if (r == target) return true;
    }
    return false;
}

fn referencesEntity(source_label: []const u8, target_label: []const u8) bool {
    return std.mem.indexOf(u8, source_label, target_label) != null and target_label.len > 2;
}

fn labelContains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null and needle.len > 2;
}
