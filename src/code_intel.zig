const std = @import("std");
const mc = @import("inference.zig");
const abstractions = @import("abstractions.zig");
const shards = @import("shards.zig");
const sys = @import("sys.zig");
const task_intent = @import("task_intent.zig");

pub const QueryKind = enum {
    impact,
    breaks_if,
    contradicts,
};

pub const Options = struct {
    repo_root: []const u8,
    project_shard: ?[]const u8 = null,
    reasoning_mode: mc.ReasoningMode = .proof,
    query_kind: QueryKind,
    target: []const u8,
    other_target: ?[]const u8 = null,
    intent: ?*const task_intent.Task = null,
    max_items: usize = 8,
    persist: bool = true,
    cache_persist: bool = true,
};

pub const Status = enum {
    supported,
    unresolved,
};

pub const CacheLifecycle = enum {
    cold_build,
    warm_load,
    warm_refresh,
};

const CACHE_MAGIC = "GCIDX3";
const CACHE_INDEX_FILE_NAME = "index_v1.gcix";
const MAX_INDEXED_FILE_BYTES = 2 * 1024 * 1024;
const INVARIANT_MODEL_NAME = "bounded_semantic_invariants_v1";
const MAX_TARGET_INVARIANTS: usize = 24;
const MAX_PAIR_CONTRADICTION_CHECKS: usize = 96;
const MAX_SYMBOLIC_UNITS_PER_FILE: usize = 96;
const MAX_SYMBOLIC_REFERENCES_PER_FILE: usize = 384;
const MAX_SYMBOLIC_LINE_BYTES: usize = 512;
const MAX_SYMBOLIC_SLUG_BYTES: usize = 64;
const MAX_SYMBOLIC_LOOKUP_TOKENS: usize = 8;
const MAX_GROUNDING_PATTERNS: usize = 8;
const MAX_GROUNDING_DECLS: usize = 8;
const MAX_GROUNDING_TRACES: usize = 6;
const MIN_GROUNDING_SCORE: u32 = 280;

const DeclKind = enum {
    function,
    constant,
    variable,
    module,
    type,
    symbolic_unit,
};

const DeclRole = enum {
    declaration,
    definition,
    declaration_and_definition,
};

const DependencyKind = enum {
    import,
    include,
    companion,
};

const SemanticEdgeKind = enum {
    symbol_ref,
    call,
    signature_type,
    annotation_type,
    declaration_pair,
    structural_hint,
};

const InvariantKind = enum {
    call_site,
    signature_contract,
    dependency_edge,
    ownership_state,
    declaration_pair,
    structural_relation,
};

const ContradictionCategory = enum {
    same_target_surface,
    signature_incompatibility,
    missing_dependency_edge,
    incompatible_call_site_expectation,
    ownership_state_assumption,
    declaration_pair_incompatibility,
    structural_relation_assumption,
};

const SymbolicClass = enum {
    technical_text,
    config_like,
    markup_like,
    dsl_like,
};

const TargetKind = enum {
    declaration,
    file,
};

const Subsystem = enum {
    api,
    app,
    cli,
    config,
    docs,
    engine,
    inference,
    platform,
    reasoning,
    shell,
    shader,
    sigil,
    sys,
    tests,
    tools,
    trainer,
    vsa,
    other,
};

const ImportEdge = struct {
    file_index: u32,
    line: u32,
    kind: DependencyKind,
};

const CachedImport = struct {
    rel_path: []u8,
    line: u32,
    kind: DependencyKind,

    fn clone(self: CachedImport, allocator: std.mem.Allocator) !CachedImport {
        return .{
            .rel_path = try allocator.dupe(u8, self.rel_path),
            .line = self.line,
            .kind = self.kind,
        };
    }

    fn deinit(self: *CachedImport, allocator: std.mem.Allocator) void {
        allocator.free(self.rel_path);
        self.* = undefined;
    }
};

const CachedDeclRecord = struct {
    name: []u8,
    line: u32,
    kind: DeclKind,
    is_pub: bool,
    role: DeclRole,

    fn clone(self: CachedDeclRecord, allocator: std.mem.Allocator) !CachedDeclRecord {
        return .{
            .name = try allocator.dupe(u8, self.name),
            .line = self.line,
            .kind = self.kind,
            .is_pub = self.is_pub,
            .role = self.role,
        };
    }

    fn deinit(self: *CachedDeclRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.* = undefined;
    }
};

const CachedReferenceRecord = struct {
    name: []u8,
    line: u32,

    fn clone(self: CachedReferenceRecord, allocator: std.mem.Allocator) !CachedReferenceRecord {
        return .{
            .name = try allocator.dupe(u8, self.name),
            .line = self.line,
        };
    }

    fn deinit(self: *CachedReferenceRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.* = undefined;
    }
};

const CachedSemanticEdgeRecord = struct {
    target_rel_path: []u8,
    target_symbol: []u8,
    line: u32,
    owner_line: u32,
    kind: SemanticEdgeKind,

    fn clone(self: CachedSemanticEdgeRecord, allocator: std.mem.Allocator) !CachedSemanticEdgeRecord {
        return .{
            .target_rel_path = try allocator.dupe(u8, self.target_rel_path),
            .target_symbol = try allocator.dupe(u8, self.target_symbol),
            .line = self.line,
            .owner_line = self.owner_line,
            .kind = self.kind,
        };
    }

    fn deinit(self: *CachedSemanticEdgeRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.target_rel_path);
        allocator.free(self.target_symbol);
        self.* = undefined;
    }
};

const CachedDeferredEdgeRecord = struct {
    raw_symbol: []u8,
    line: u32,
    owner_line: u32,
    kind: SemanticEdgeKind,

    fn clone(self: CachedDeferredEdgeRecord, allocator: std.mem.Allocator) !CachedDeferredEdgeRecord {
        return .{
            .raw_symbol = try allocator.dupe(u8, self.raw_symbol),
            .line = self.line,
            .owner_line = self.owner_line,
            .kind = self.kind,
        };
    }

    fn deinit(self: *CachedDeferredEdgeRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.raw_symbol);
        self.* = undefined;
    }
};

const CachedFileRecord = struct {
    allocator: std.mem.Allocator,
    rel_path: []u8,
    subsystem: Subsystem,
    size_bytes: u64,
    mtime_ns: i128,
    content_hash: u64,
    imports: std.ArrayList(CachedImport),
    declarations: std.ArrayList(CachedDeclRecord),
    references: std.ArrayList(CachedReferenceRecord),
    semantic_edges: std.ArrayList(CachedSemanticEdgeRecord),
    deferred_edges: std.ArrayList(CachedDeferredEdgeRecord),

    fn init(allocator: std.mem.Allocator, rel_path: []u8, subsystem: Subsystem, size_bytes: u64, mtime_ns: i128) CachedFileRecord {
        return .{
            .allocator = allocator,
            .rel_path = rel_path,
            .subsystem = subsystem,
            .size_bytes = size_bytes,
            .mtime_ns = mtime_ns,
            .content_hash = 0,
            .imports = std.ArrayList(CachedImport).init(allocator),
            .declarations = std.ArrayList(CachedDeclRecord).init(allocator),
            .references = std.ArrayList(CachedReferenceRecord).init(allocator),
            .semantic_edges = std.ArrayList(CachedSemanticEdgeRecord).init(allocator),
            .deferred_edges = std.ArrayList(CachedDeferredEdgeRecord).init(allocator),
        };
    }

    fn clone(self: *const CachedFileRecord, allocator: std.mem.Allocator) !CachedFileRecord {
        var out = CachedFileRecord.init(
            allocator,
            try allocator.dupe(u8, self.rel_path),
            self.subsystem,
            self.size_bytes,
            self.mtime_ns,
        );
        errdefer out.deinit();
        out.content_hash = self.content_hash;
        for (self.imports.items) |item| try out.imports.append(try item.clone(allocator));
        for (self.declarations.items) |item| try out.declarations.append(try item.clone(allocator));
        for (self.references.items) |item| try out.references.append(try item.clone(allocator));
        for (self.semantic_edges.items) |item| try out.semantic_edges.append(try item.clone(allocator));
        for (self.deferred_edges.items) |item| try out.deferred_edges.append(try item.clone(allocator));
        return out;
    }

    fn deinit(self: *CachedFileRecord) void {
        for (self.imports.items) |*item| item.deinit(self.allocator);
        for (self.declarations.items) |*item| item.deinit(self.allocator);
        for (self.references.items) |*item| item.deinit(self.allocator);
        for (self.semantic_edges.items) |*item| item.deinit(self.allocator);
        for (self.deferred_edges.items) |*item| item.deinit(self.allocator);
        self.allocator.free(self.rel_path);
        self.imports.deinit();
        self.declarations.deinit();
        self.references.deinit();
        self.semantic_edges.deinit();
        self.deferred_edges.deinit();
        self.* = undefined;
    }
};

const RepoScanEntry = struct {
    rel_path: []u8,
    abs_path: []u8,
    size_bytes: u64,
    mtime_ns: i128,

    fn deinit(self: *RepoScanEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.rel_path);
        allocator.free(self.abs_path);
        self.* = undefined;
    }
};

const PersistedCache = struct {
    allocator: std.mem.Allocator,
    repo_root: []u8,
    files: std.ArrayList(CachedFileRecord),

    fn init(allocator: std.mem.Allocator, repo_root: []const u8) !PersistedCache {
        return .{
            .allocator = allocator,
            .repo_root = try allocator.dupe(u8, repo_root),
            .files = std.ArrayList(CachedFileRecord).init(allocator),
        };
    }

    fn deinit(self: *PersistedCache) void {
        for (self.files.items) |*file| file.deinit();
        self.files.deinit();
        self.allocator.free(self.repo_root);
        self.* = undefined;
    }
};

const FileRecord = struct {
    rel_path: []u8,
    subsystem: Subsystem,
    imports: std.ArrayList(ImportEdge),
    declaration_indexes: std.ArrayList(u32),

    fn init(allocator: std.mem.Allocator, rel_path: []u8, subsystem: Subsystem) FileRecord {
        return .{
            .rel_path = rel_path,
            .subsystem = subsystem,
            .imports = std.ArrayList(ImportEdge).init(allocator),
            .declaration_indexes = std.ArrayList(u32).init(allocator),
        };
    }

    fn deinit(self: *FileRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.rel_path);
        self.imports.deinit();
        self.declaration_indexes.deinit();
    }
};

const DeclRecord = struct {
    name: []u8,
    file_index: u32,
    line: u32,
    kind: DeclKind,
    is_pub: bool,
    role: DeclRole,
};

const ReferenceRecord = struct {
    name: []u8,
    file_index: u32,
    line: u32,
};

const SemanticEdge = struct {
    kind: SemanticEdgeKind,
    source_file_index: u32,
    owner_decl_index: ?u32,
    target_decl_index: u32,
    line: u32,
};

const RepoIndex = struct {
    allocator: std.mem.Allocator,
    repo_root: []u8,
    files: std.ArrayList(FileRecord),
    declarations: std.ArrayList(DeclRecord),
    references: std.ArrayList(ReferenceRecord),
    semantic_edges: std.ArrayList(SemanticEdge),

    fn fromCache(allocator: std.mem.Allocator, repo_root: []const u8, cached_files: []const CachedFileRecord) !RepoIndex {
        var index = RepoIndex{
            .allocator = allocator,
            .repo_root = try allocator.dupe(u8, repo_root),
            .files = std.ArrayList(FileRecord).init(allocator),
            .declarations = std.ArrayList(DeclRecord).init(allocator),
            .references = std.ArrayList(ReferenceRecord).init(allocator),
            .semantic_edges = std.ArrayList(SemanticEdge).init(allocator),
        };
        errdefer index.deinit();

        var path_map = std.StringHashMap(u32).init(allocator);
        defer path_map.deinit();

        for (cached_files) |cached_file| {
            const owned_rel = try allocator.dupe(u8, cached_file.rel_path);
            const file_index: u32 = @intCast(index.files.items.len);
            try index.files.append(FileRecord.init(allocator, owned_rel, cached_file.subsystem));
            try path_map.put(index.files.items[file_index].rel_path, file_index);
        }

        for (cached_files, 0..) |cached_file, file_index_usize| {
            const file_index: u32 = @intCast(file_index_usize);

            for (cached_file.declarations.items) |decl| {
                const decl_index: u32 = @intCast(index.declarations.items.len);
                try index.declarations.append(.{
                    .name = try allocator.dupe(u8, decl.name),
                    .file_index = file_index,
                    .line = decl.line,
                    .kind = decl.kind,
                    .is_pub = decl.is_pub,
                    .role = decl.role,
                });
                try index.files.items[file_index].declaration_indexes.append(decl_index);
            }

            for (cached_file.references.items) |reference| {
                try index.references.append(.{
                    .name = try allocator.dupe(u8, reference.name),
                    .file_index = file_index,
                    .line = reference.line,
                });
            }

            for (cached_file.imports.items) |import| {
                if (path_map.get(import.rel_path)) |dep_idx| {
                    try index.files.items[file_index].imports.append(.{
                        .file_index = dep_idx,
                        .line = import.line,
                        .kind = import.kind,
                    });
                }
            }
        }

        try attachCompanionEdges(allocator, &index);

        for (cached_files, 0..) |cached_file, file_index_usize| {
            const file_index: u32 = @intCast(file_index_usize);

            for (cached_file.semantic_edges.items) |edge| {
                const target_file_index = path_map.get(edge.target_rel_path) orelse continue;
                const target_decl_index = findUniqueDeclarationByNameInFile(&index, target_file_index, edge.target_symbol) orelse continue;
                const owner_decl_index = if (edge.owner_line == 0)
                    null
                else
                    findDeclarationByLine(&index, file_index, edge.owner_line);
                try index.semantic_edges.append(.{
                    .kind = edge.kind,
                    .source_file_index = file_index,
                    .owner_decl_index = owner_decl_index,
                    .target_decl_index = target_decl_index,
                    .line = edge.line,
                });
            }

            try resolveDeferredEdges(allocator, &index, cached_file, file_index);
        }

        try appendDeclarationPairs(&index);

        return index;
    }

    fn deinit(self: *RepoIndex) void {
        for (self.files.items) |*file| file.deinit(self.allocator);
        for (self.declarations.items) |decl| self.allocator.free(decl.name);
        for (self.references.items) |reference| self.allocator.free(reference.name);
        self.files.deinit();
        self.declarations.deinit();
        self.references.deinit();
        self.semantic_edges.deinit();
        self.allocator.free(self.repo_root);
    }
};

const ParsedDecl = struct {
    name: []const u8,
    kind: DeclKind,
    is_pub: bool,
};

const ResolutionCandidate = struct {
    branch_id: u32,
    score: u32,
    evidence_count: u32,
    target_kind: TargetKind,
    file_index: u32,
    decl_index: ?u32 = null,
};

const ResolvedTarget = struct {
    target_kind: TargetKind,
    file_index: u32,
    decl_index: ?u32 = null,
    confidence: u32,
};

const EvidenceSeed = struct {
    file_index: u32,
    line: u32,
    reason: []const u8,
};

const Invariant = struct {
    kind: InvariantKind,
    owner_decl_index: ?u32,
    owner_file_index: u32,
    line: u32,
    requires_dependency_edge: bool,
    weight: u32,
};

const ContradictionSeed = struct {
    category: ContradictionCategory,
    file_index: u32,
    line: u32,
    reason: []const u8,
    owner_decl_index: ?u32 = null,
    weight: u32,
};

const Hypothesis = struct {
    branch_id: u32,
    label: []const u8,
    score: u32,
    evidence_count: u32,
    abstraction_bias: u32 = 0,
};

pub const CandidateTrace = struct {
    label: []const u8,
    score: u32,
    evidence_count: u32,
    abstraction_bias: u32 = 0,
};

pub const AbstractionTrace = struct {
    label: []const u8,
    source_spec: []const u8,
    tier: abstractions.Tier,
    category: abstractions.Category,
    selection_mode: abstractions.SelectionMode,
    staged: bool,
    owner_kind: shards.Kind,
    owner_id: []const u8,
    quality_score: u16,
    confidence_score: u16,
    lookup_score: u16,
    direct_support_count: u16,
    lineage_support_count: u16,
    consensus_hash: u64,
    usable: bool,
    reuse_decision: abstractions.ReuseDecision,
    resolution: abstractions.ReuseResolution,
    conflict_kind: abstractions.ConflictKind,
    conflict_concept: ?[]const u8 = null,
    conflict_owner_id: ?[]const u8 = null,
    conflict_owner_kind: ?shards.Kind = null,
    supporting_concept: ?[]const u8 = null,
    parent_concept: ?[]const u8 = null,
};

pub const GroundingTrace = struct {
    surface: []const u8,
    concept: []const u8,
    source_spec: []const u8,
    selection_mode: abstractions.SelectionMode,
    owner_kind: shards.Kind,
    owner_id: []const u8,
    relation: []const u8,
    lookup_score: u16,
    confidence_score: u16,
    token_support_count: u16,
    pattern_support_count: u16,
    source_support_count: u16,
    mapping_score: u32,
    usable: bool,
    ambiguous: bool,
    resolution: abstractions.ReuseResolution,
    conflict_kind: abstractions.ConflictKind,
    target_label: ?[]const u8 = null,
    target_rel_path: ?[]const u8 = null,
    target_line: u32 = 0,
    target_kind: ?[]const u8 = null,
    detail: ?[]const u8 = null,
};

pub const SupportNodeKind = enum {
    output,
    shard,
    intent,
    reasoning,
    execution,
    target_candidate,
    query_hypothesis,
    evidence,
    contradiction,
    abstraction,
    grounding,
    handoff,
    gap,
};

pub const SupportEdgeKind = enum {
    sourced_from,
    requested_by,
    derived_in,
    selected_from,
    selected_by,
    supported_by,
    checked_by,
    grounded_by,
    handoff_from,
    blocked_by,
};

pub const SupportGraphNode = struct {
    id: []const u8,
    kind: SupportNodeKind,
    label: []const u8,
    rel_path: ?[]const u8 = null,
    line: u32 = 0,
    score: u32 = 0,
    usable: bool = true,
    detail: ?[]const u8 = null,
};

pub const SupportGraphEdge = struct {
    from_id: []const u8,
    to_id: []const u8,
    kind: SupportEdgeKind,
};

pub const SupportGraph = struct {
    allocator: std.mem.Allocator,
    permission: Status = .unresolved,
    minimum_met: bool = false,
    flow_mode: []const u8 = "",
    unresolved_reason: ?[]const u8 = null,
    nodes: []SupportGraphNode = &.{},
    edges: []SupportGraphEdge = &.{},

    pub fn deinit(self: *SupportGraph) void {
        for (self.nodes) |node| {
            self.allocator.free(node.id);
            self.allocator.free(node.label);
            if (node.rel_path) |rel_path| self.allocator.free(rel_path);
            if (node.detail) |detail| self.allocator.free(detail);
        }
        for (self.edges) |edge| {
            self.allocator.free(edge.from_id);
            self.allocator.free(edge.to_id);
        }
        if (self.flow_mode.len > 0) self.allocator.free(self.flow_mode);
        if (self.unresolved_reason) |reason| self.allocator.free(reason);
        self.allocator.free(self.nodes);
        self.allocator.free(self.edges);
        self.* = undefined;
    }
};

pub const Subject = struct {
    name: []const u8,
    rel_path: []const u8,
    line: u32,
    kind_name: []const u8,
    subsystem: []const u8,
};

pub const Evidence = struct {
    rel_path: []const u8,
    line: u32,
    reason: []const u8,
    subsystem: []const u8,
};

pub const ContradictionTrace = struct {
    category: []const u8,
    rel_path: []const u8,
    line: u32,
    reason: []const u8,
    subsystem: []const u8,
    owner: ?[]const u8 = null,
};

pub const Result = struct {
    allocator: std.mem.Allocator,
    status: Status,
    query_kind: QueryKind,
    query_target: []const u8,
    query_other_target: ?[]const u8 = null,
    repo_root: []const u8,
    shard_root: []const u8,
    shard_id: []const u8,
    shard_kind: shards.Kind,
    cache_lifecycle: CacheLifecycle = .cold_build,
    cache_changed_files: u32 = 0,
    reasoning_mode: mc.ReasoningMode = .proof,
    stop_reason: mc.StopReason = .none,
    confidence: u32 = 0,
    invariant_model: ?[]const u8 = null,
    selected_scope: ?[]const u8 = null,
    contradiction_kind: ?[]const u8 = null,
    unresolved_detail: ?[]const u8 = null,
    intent: ?task_intent.Task = null,
    primary: ?Subject = null,
    secondary: ?Subject = null,
    evidence: []Evidence = &.{},
    contradiction_traces: []ContradictionTrace = &.{},
    refactor_path: []Evidence = &.{},
    overlap: []Evidence = &.{},
    affected_subsystems: []Subsystem = &.{},
    layer1_file_count: u32 = 0,
    layer1_decl_count: u32 = 0,
    target_candidates: []CandidateTrace = &.{},
    query_hypotheses: []CandidateTrace = &.{},
    abstraction_traces: []AbstractionTrace = &.{},
    grounding_traces: []GroundingTrace = &.{},
    support_graph: SupportGraph = .{ .allocator = undefined },

    pub fn deinit(self: *Result) void {
        if (self.primary) |subject| {
            self.allocator.free(subject.name);
            self.allocator.free(subject.rel_path);
        }
        if (self.secondary) |subject| {
            self.allocator.free(subject.name);
            self.allocator.free(subject.rel_path);
        }
        for (self.evidence) |item| self.allocator.free(item.rel_path);
        for (self.contradiction_traces) |item| {
            self.allocator.free(item.rel_path);
            if (item.owner) |owner| self.allocator.free(owner);
        }
        for (self.refactor_path) |item| self.allocator.free(item.rel_path);
        for (self.overlap) |item| self.allocator.free(item.rel_path);
        self.allocator.free(self.evidence);
        self.allocator.free(self.contradiction_traces);
        self.allocator.free(self.refactor_path);
        self.allocator.free(self.overlap);
        self.allocator.free(self.affected_subsystems);
        for (self.target_candidates) |candidate| self.allocator.free(candidate.label);
        for (self.query_hypotheses) |candidate| self.allocator.free(candidate.label);
        for (self.abstraction_traces) |trace| {
            self.allocator.free(trace.label);
            self.allocator.free(trace.source_spec);
            self.allocator.free(trace.owner_id);
            if (trace.conflict_concept) |conflict_concept| self.allocator.free(conflict_concept);
            if (trace.conflict_owner_id) |conflict_owner_id| self.allocator.free(conflict_owner_id);
            if (trace.supporting_concept) |supporting_concept| self.allocator.free(supporting_concept);
            if (trace.parent_concept) |parent_concept| self.allocator.free(parent_concept);
        }
        for (self.grounding_traces) |trace| {
            self.allocator.free(trace.surface);
            self.allocator.free(trace.concept);
            self.allocator.free(trace.source_spec);
            self.allocator.free(trace.owner_id);
            self.allocator.free(trace.relation);
            if (trace.target_label) |target_label| self.allocator.free(target_label);
            if (trace.target_rel_path) |target_rel_path| self.allocator.free(target_rel_path);
            if (trace.target_kind) |target_kind| self.allocator.free(target_kind);
            if (trace.detail) |detail| self.allocator.free(detail);
        }
        self.allocator.free(self.target_candidates);
        self.allocator.free(self.query_hypotheses);
        self.allocator.free(self.abstraction_traces);
        self.allocator.free(self.grounding_traces);
        self.support_graph.deinit();
        self.allocator.free(self.query_target);
        if (self.query_other_target) |other| self.allocator.free(other);
        self.allocator.free(self.repo_root);
        self.allocator.free(self.shard_root);
        self.allocator.free(self.shard_id);
        if (self.unresolved_detail) |detail| self.allocator.free(detail);
        if (self.intent) |*intent| intent.deinit();
        self.* = undefined;
    }
};

const IndexLoadResult = struct {
    index: RepoIndex,
    lifecycle: CacheLifecycle,
    changed_files: u32,
};

pub fn run(allocator: std.mem.Allocator, options: Options) !Result {
    const repo_root = try normalizeRootPath(allocator, options.repo_root);
    errdefer allocator.free(repo_root);

    var shard_paths = try resolveSelectedShardPaths(allocator, options.project_shard);
    defer shard_paths.deinit();

    var loaded = try loadRepoIndex(allocator, repo_root, &shard_paths, options.cache_persist);
    defer loaded.index.deinit();

    var result = try switch (options.query_kind) {
        .impact => queryImpact(allocator, &loaded.index, &shard_paths, options),
        .breaks_if => queryBreaksIf(allocator, &loaded.index, &shard_paths, options),
        .contradicts => queryContradicts(allocator, &loaded.index, &shard_paths, options),
    };
    errdefer result.deinit();

    result.repo_root = repo_root;
    result.shard_root = try allocator.dupe(u8, shard_paths.root_abs_path);
    result.shard_id = try allocator.dupe(u8, shard_paths.metadata.id);
    result.shard_kind = shard_paths.metadata.kind;
    result.cache_lifecycle = loaded.lifecycle;
    result.cache_changed_files = loaded.changed_files;
    result.reasoning_mode = options.reasoning_mode;
    result.layer1_file_count = @intCast(loaded.index.files.items.len);
    result.layer1_decl_count = @intCast(loaded.index.declarations.items.len);
    if (options.intent) |intent| result.intent = try intent.clone(allocator);
    try enforceSupportPermission(allocator, &result);
    result.support_graph = try buildCodeIntelSupportGraph(allocator, &result);

    if (options.persist) {
        const rendered = try renderJson(allocator, &result);
        defer allocator.free(rendered);
        try persistResult(allocator, &shard_paths, options, rendered);
    }

    return result;
}

fn reasoningPolicy(mode: mc.ReasoningMode) mc.ReasoningPolicy {
    return mc.policyForMode(mode);
}

fn reasoningBranchCap(mode: mc.ReasoningMode) usize {
    return switch (mode) {
        .proof => 5,
        .exploratory => 8,
    };
}

fn codeIntelLayer3Config(mode: mc.ReasoningMode, min_score: u32, max_branches: u32) mc.Layer3Config {
    return .{
        .confidence_floor = .{ .min_score = min_score },
        .max_steps = 1,
        .max_branches = max_branches,
        .policy = reasoningPolicy(mode),
    };
}

const BranchBiasMap = struct {
    values: [8]u32 = [_]u32{0} ** 8,

    fn add(self: *BranchBiasMap, branch_id: u32, delta: u32) void {
        if (branch_id == 0 or branch_id >= self.values.len) return;
        self.values[branch_id] = @min(self.values[branch_id] + delta, @as(u32, 255));
    }

    fn get(self: BranchBiasMap, branch_id: u32) u32 {
        if (branch_id == 0 or branch_id >= self.values.len) return 0;
        return self.values[branch_id];
    }

    fn merge(self: *BranchBiasMap, other: BranchBiasMap) void {
        for (other.values, 0..) |value, idx| {
            if (idx == 0 or value == 0) continue;
            self.values[idx] = @min(self.values[idx] + value, @as(u32, 255));
        }
    }
};

fn abstractionCategoryHint(query_kind: QueryKind) abstractions.Category {
    return switch (query_kind) {
        .impact => .data_flow,
        .breaks_if => .control_flow,
        .contradicts => .invariant,
    };
}

fn abstractionBiasMagnitude(reference: abstractions.SupportReference) u32 {
    return @max(@as(u32, reference.lookup_score) / 18, @as(u32, 12));
}

fn buildBranchBiases(query_kind: QueryKind, refs: []const abstractions.SupportReference) BranchBiasMap {
    var biases = BranchBiasMap{};
    for (refs) |reference| {
        if (!reference.usable) continue;
        const magnitude = abstractionBiasMagnitude(reference);
        switch (query_kind) {
            .impact => switch (reference.tier) {
                .pattern => {
                    biases.add(1, magnitude / 2);
                    biases.add(2, magnitude);
                },
                .idiom => {
                    biases.add(2, magnitude);
                    biases.add(5, magnitude / 3);
                },
                .mechanism => {
                    biases.add(3, magnitude);
                    biases.add(5, magnitude / 2);
                },
                .contract => {
                    biases.add(3, magnitude / 2);
                    biases.add(5, magnitude);
                },
            },
            .breaks_if => switch (reference.tier) {
                .pattern => {
                    biases.add(1, magnitude);
                    biases.add(2, magnitude / 2);
                },
                .idiom => {
                    biases.add(1, magnitude / 3);
                    biases.add(2, magnitude);
                },
                .mechanism => {
                    biases.add(2, magnitude / 2);
                    biases.add(3, magnitude);
                },
                .contract => {
                    biases.add(2, magnitude / 3);
                    biases.add(3, magnitude);
                },
            },
            .contradicts => switch (reference.category) {
                .syntax => biases.add(1, magnitude / 2),
                .interface => biases.add(2, magnitude),
                .data_flow => biases.add(3, magnitude),
                .control_flow => biases.add(4, magnitude),
                .state => biases.add(5, magnitude),
                .invariant => biases.add(6, magnitude),
            },
        }

        switch (reference.category) {
            .interface => {
                if (query_kind == .impact) {
                    biases.add(4, magnitude / 2);
                    biases.add(5, magnitude / 2);
                }
            },
            .data_flow => if (query_kind == .impact) biases.add(3, magnitude / 2),
            .control_flow => if (query_kind == .breaks_if) biases.add(2, magnitude / 3),
            .state => if (query_kind == .contradicts) biases.add(5, magnitude / 2),
            .invariant => {
                if (query_kind == .breaks_if) biases.add(3, magnitude / 2);
                if (query_kind == .impact) biases.add(5, magnitude / 2);
            },
            .syntax => {},
        }
    }
    return biases;
}

fn buildAbstractionTraces(allocator: std.mem.Allocator, refs: []const abstractions.SupportReference) ![]AbstractionTrace {
    const out = try allocator.alloc(AbstractionTrace, refs.len);
    var built: usize = 0;
    errdefer {
        for (out[0..built]) |trace| {
            allocator.free(trace.label);
            allocator.free(trace.source_spec);
            allocator.free(trace.owner_id);
            if (trace.conflict_concept) |conflict_concept| allocator.free(conflict_concept);
            if (trace.conflict_owner_id) |conflict_owner_id| allocator.free(conflict_owner_id);
            if (trace.supporting_concept) |supporting_concept| allocator.free(supporting_concept);
            if (trace.parent_concept) |parent_concept| allocator.free(parent_concept);
        }
        allocator.free(out);
    }

    for (refs, 0..) |reference, idx| {
        out[idx] = .{
            .label = try allocator.dupe(u8, reference.concept_id),
            .source_spec = try allocator.dupe(u8, reference.source_spec),
            .tier = reference.tier,
            .category = reference.category,
            .selection_mode = reference.selection_mode,
            .staged = reference.staged,
            .owner_kind = reference.owner_kind,
            .owner_id = try allocator.dupe(u8, reference.owner_id),
            .quality_score = reference.quality_score,
            .confidence_score = reference.confidence_score,
            .lookup_score = reference.lookup_score,
            .direct_support_count = reference.direct_support_count,
            .lineage_support_count = reference.lineage_support_count,
            .consensus_hash = reference.consensus_hash,
            .usable = reference.usable,
            .reuse_decision = reference.reuse_decision,
            .resolution = reference.resolution,
            .conflict_kind = reference.conflict_kind,
            .conflict_concept = if (reference.conflict_concept_id) |conflict_concept_id| try allocator.dupe(u8, conflict_concept_id) else null,
            .conflict_owner_id = if (reference.conflict_owner_id) |conflict_owner_id| try allocator.dupe(u8, conflict_owner_id) else null,
            .conflict_owner_kind = reference.conflict_owner_kind,
            .supporting_concept = if (reference.supporting_concept_id) |supporting_concept_id| try allocator.dupe(u8, supporting_concept_id) else null,
            .parent_concept = if (reference.parent_concept_id) |parent_concept_id| try allocator.dupe(u8, parent_concept_id) else null,
        };
        built += 1;
    }

    return out;
}

const GroundingState = enum {
    none,
    selected,
    ambiguous,
    insufficient,
};

const GroundingRegion = struct {
    rel_path: []const u8,
    start_line: u32,
    end_line: u32,
};

const GroundingTargetAggregate = struct {
    target: ResolvedTarget,
    best_ref_index: usize,
    score: u32,
    support_count: u16 = 0,
};

const GroundingOutcome = struct {
    traces: []GroundingTrace = &.{},
    selected_target: ?ResolvedTarget = null,
    biases: BranchBiasMap = .{},
    state: GroundingState = .none,
    detail: ?[]const u8 = null,

    fn deinit(self: *GroundingOutcome, allocator: std.mem.Allocator) void {
        for (self.traces) |trace| {
            allocator.free(trace.surface);
            allocator.free(trace.concept);
            allocator.free(trace.source_spec);
            allocator.free(trace.owner_id);
            allocator.free(trace.relation);
            if (trace.target_label) |target_label| allocator.free(target_label);
            if (trace.target_rel_path) |target_rel_path| allocator.free(target_rel_path);
            if (trace.target_kind) |target_kind| allocator.free(target_kind);
            if (trace.detail) |detail| allocator.free(detail);
        }
        allocator.free(self.traces);
        if (self.detail) |detail| allocator.free(detail);
        self.* = .{};
    }
};

fn lookupSymbolicGrounding(
    allocator: std.mem.Allocator,
    index: *const RepoIndex,
    paths: *const shards.Paths,
    query_kind: QueryKind,
    target: ResolvedTarget,
) !GroundingOutcome {
    if (!isSymbolicTarget(index, target)) return .{};

    var signal_tokens = std.ArrayList([]const u8).init(allocator);
    defer signal_tokens.deinit();
    var signal_patterns = std.ArrayList([]const u8).init(allocator);
    defer signal_patterns.deinit();
    try collectGroundingSignals(index, target, &signal_tokens, &signal_patterns);
    if (signal_tokens.items.len == 0 and signal_patterns.items.len == 0) {
        return .{
            .state = .insufficient,
            .detail = try allocator.dupe(u8, "symbolic target did not expose enough grounded tokens or patterns"),
        };
    }

    const rel_paths = [_][]const u8{index.files.items[target.file_index].rel_path};
    const grounding_refs = try abstractions.lookupGroundingConcepts(allocator, paths, .{
        .rel_paths = &rel_paths,
        .tokens = signal_tokens.items,
        .patterns = signal_patterns.items,
        .max_items = MAX_GROUNDING_TRACES,
        .include_staged = false,
        .prefer_higher_tiers = true,
        .category_hint = abstractionCategoryHint(query_kind),
    });
    defer abstractions.deinitSupportReferences(allocator, grounding_refs);

    var outcome = GroundingOutcome{
        .biases = buildBranchBiases(query_kind, grounding_refs),
    };
    errdefer outcome.deinit(allocator);

    if (grounding_refs.len == 0) {
        outcome.state = .insufficient;
        outcome.detail = try allocator.dupe(u8, "no abstraction catalog concept matched the symbolic signals strongly enough");
        return outcome;
    }

    var aggregates = std.ArrayList(GroundingTargetAggregate).init(allocator);
    defer aggregates.deinit();
    var traces = std.ArrayList(GroundingTrace).init(allocator);
    errdefer {
        for (traces.items) |trace| {
            allocator.free(trace.surface);
            allocator.free(trace.concept);
            allocator.free(trace.source_spec);
            allocator.free(trace.owner_id);
            allocator.free(trace.relation);
            if (trace.target_label) |target_label| allocator.free(target_label);
            if (trace.target_rel_path) |target_rel_path| allocator.free(target_rel_path);
            if (trace.target_kind) |target_kind| allocator.free(target_kind);
            if (trace.detail) |detail| allocator.free(detail);
        }
        traces.deinit();
    }

    const surface_label = try makeSubjectLabel(allocator, index, target);
    defer allocator.free(surface_label);

    for (grounding_refs, 0..) |reference, ref_index| {
        const target_match = resolveGroundingTarget(index, signal_tokens.items, reference.source_spec);
        const mapping_score = if (target_match.target != null and reference.usable) computeGroundingMappingScore(index, signal_tokens.items, reference, target_match.target.?) else 0;
        try traces.append(.{
            .surface = try allocator.dupe(u8, surface_label),
            .concept = try allocator.dupe(u8, reference.concept_id),
            .source_spec = try allocator.dupe(u8, reference.source_spec),
            .selection_mode = reference.selection_mode,
            .owner_kind = reference.owner_kind,
            .owner_id = try allocator.dupe(u8, reference.owner_id),
            .relation = try allocator.dupe(u8, groundingRelationName(target)),
            .lookup_score = reference.lookup_score,
            .confidence_score = reference.confidence_score,
            .token_support_count = reference.token_support_count,
            .pattern_support_count = reference.pattern_support_count,
            .source_support_count = reference.source_support_count,
            .mapping_score = mapping_score,
            .usable = reference.usable and target_match.target != null and !target_match.ambiguous,
            .ambiguous = target_match.ambiguous,
            .resolution = reference.resolution,
            .conflict_kind = reference.conflict_kind,
            .target_label = if (target_match.target) |resolved| try makeSubjectLabel(allocator, index, resolved) else null,
            .target_rel_path = if (target_match.target) |resolved| try allocator.dupe(u8, index.files.items[resolved.file_index].rel_path) else null,
            .target_line = if (target_match.target) |resolved| subjectLine(index, resolved) else 0,
            .target_kind = if (target_match.target) |resolved| try allocator.dupe(u8, groundedTargetKindName(index, resolved)) else null,
            .detail = if (target_match.ambiguous)
                try allocator.dupe(u8, "region source mapped to multiple code/runtime targets")
            else if (target_match.target == null)
                try allocator.dupe(u8, "concept provenance did not resolve to a bounded code/runtime target")
            else if (mapping_score < MIN_GROUNDING_SCORE)
                try allocator.dupe(u8, "grounding support stayed below the deterministic score floor")
            else
                null,
        });

        if (!reference.usable or target_match.target == null or target_match.ambiguous or mapping_score < MIN_GROUNDING_SCORE) continue;
        try upsertGroundingAggregate(&aggregates, .{
            .target = target_match.target.?,
            .best_ref_index = ref_index,
            .score = mapping_score,
            .support_count = reference.token_support_count +| reference.pattern_support_count +| reference.source_support_count,
        });
    }

    std.sort.heap(GroundingTargetAggregate, aggregates.items, index, lessThanGroundingAggregate);
    if (aggregates.items.len == 0) {
        outcome.state = .insufficient;
        if (findAmbiguousGroundingTrace(traces.items)) {
            outcome.state = .ambiguous;
            outcome.detail = try allocator.dupe(u8, "symbolic grounding was ambiguous across multiple code/runtime surfaces");
        } else {
            outcome.detail = try allocator.dupe(u8, "symbolic grounding did not reach a deterministic code/runtime mapping");
        }
    } else {
        const top = aggregates.items[0];
        if (hasEquivalentGroundingSupport(traces.items)) {
            outcome.state = .ambiguous;
            outcome.detail = try allocator.dupe(u8, "symbolic grounding had equally supported mappings across multiple code/runtime surfaces");
        } else if (aggregates.items.len > 1 and
            top.score -| aggregates.items[1].score <= 24 and
            !resolvedTargetsEqual(top.target, aggregates.items[1].target))
        {
            outcome.state = .ambiguous;
            outcome.detail = try allocator.dupe(u8, "symbolic grounding tied across multiple code/runtime surfaces");
        } else {
            outcome.state = .selected;
            outcome.selected_target = top.target;
        }
    }

    markAmbiguousGroundingTraces(traces.items, outcome.state == .ambiguous, if (aggregates.items.len > 0) aggregates.items[0].score else 0, 24);
    outcome.traces = try traces.toOwnedSlice();
    if (outcome.traces.len > MAX_GROUNDING_TRACES) outcome.traces.len = MAX_GROUNDING_TRACES;
    return outcome;
}

fn collectGroundingSignals(
    index: *const RepoIndex,
    target: ResolvedTarget,
    tokens: *std.ArrayList([]const u8),
    patterns: *std.ArrayList([]const u8),
) !void {
    if (target.target_kind != .declaration) return;
    const target_decl_index = target.decl_index.?;
    const decl = index.declarations.items[target_decl_index];
    if (decl.kind != .symbolic_unit) return;

    try appendUniqueSignal(patterns, symbolicLeafName(decl.name), MAX_GROUNDING_PATTERNS);
    try collectLineSignals(index, target.file_index, decl.line, tokens, MAX_SYMBOLIC_LOOKUP_TOKENS);

    var related_count: usize = 0;
    for (index.semantic_edges.items) |edge| {
        if (edge.kind != .structural_hint) continue;
        if (edge.target_decl_index != target_decl_index) continue;
        const owner_decl_index = edge.owner_decl_index orelse continue;
        const owner_decl = index.declarations.items[owner_decl_index];
        if (owner_decl.kind != .symbolic_unit) continue;
        try appendUniqueSignal(patterns, symbolicLeafName(owner_decl.name), MAX_GROUNDING_PATTERNS);
        try collectLineSignals(index, owner_decl.file_index, owner_decl.line, tokens, MAX_SYMBOLIC_LOOKUP_TOKENS);
        related_count += 1;
        if (related_count >= MAX_GROUNDING_DECLS) break;
    }
}

fn collectLineSignals(index: *const RepoIndex, file_index: u32, line: u32, tokens: *std.ArrayList([]const u8), max_items: usize) !void {
    for (index.references.items) |reference| {
        if (tokens.items.len >= max_items) return;
        if (reference.file_index != file_index or reference.line != line) continue;
        try appendUniqueSignal(tokens, reference.name, max_items);
    }
}

fn appendUniqueSignal(out: *std.ArrayList([]const u8), value: []const u8, max_items: usize) !void {
    if (value.len == 0 or out.items.len >= max_items) return;
    for (out.items) |existing| {
        if (std.mem.eql(u8, existing, value)) return;
    }
    try out.append(value);
}

fn resolveGroundingTarget(index: *const RepoIndex, signal_tokens: []const []const u8, source_spec: []const u8) struct { target: ?ResolvedTarget = null, ambiguous: bool = false } {
    const region = parseGroundingRegion(source_spec) orelse return .{};
    const file_index = findFileIndexByRelPath(index, region.rel_path) orelse return .{};

    var best_decl: ?u32 = null;
    var best_score: u32 = 0;
    var ambiguous = false;
    for (index.files.items[file_index].declaration_indexes.items) |decl_index| {
        const decl = index.declarations.items[decl_index];
        if (decl.kind == .symbolic_unit) continue;
        if (decl.line < region.start_line or decl.line > region.end_line) continue;
        const score = declarationBonus(index, decl_index) + groundingDeclSignalBonus(signal_tokens, decl.name);
        if (best_decl == null or score > best_score) {
            best_decl = decl_index;
            best_score = score;
            ambiguous = false;
        } else if (score == best_score and best_decl.? != decl_index) {
            ambiguous = true;
        }
    }

    if (best_decl == null) return .{};
    return .{
        .target = .{
            .target_kind = .declaration,
            .file_index = file_index,
            .decl_index = best_decl,
            .confidence = best_score,
        },
        .ambiguous = ambiguous,
    };
}

fn groundingDeclSignalBonus(signal_tokens: []const []const u8, decl_name: []const u8) u32 {
    var bonus: u32 = 0;
    const leaf = nativeLeafName(decl_name);
    for (signal_tokens) |token| {
        if (token.len < 2) continue;
        if (std.mem.eql(u8, token, leaf)) {
            bonus += 60;
            continue;
        }
        if (std.mem.indexOf(u8, leaf, token) != null or std.mem.indexOf(u8, decl_name, token) != null) {
            bonus += 18;
        }
    }
    return @min(bonus, @as(u32, 120));
}

fn computeGroundingMappingScore(
    index: *const RepoIndex,
    signal_tokens: []const []const u8,
    reference: abstractions.SupportReference,
    target: ResolvedTarget,
) u32 {
    const decl_index = target.decl_index orelse return reference.lookup_score;
    return @as(u32, reference.lookup_score) +
        declarationBonus(index, decl_index) / 2 +
        groundingDeclSignalBonus(signal_tokens, index.declarations.items[decl_index].name);
}

fn groundingRelationName(target: ResolvedTarget) []const u8 {
    return switch (target.target_kind) {
        .file => "symbolic_file_to_internal_concept",
        .declaration => "symbolic_unit_to_internal_concept",
    };
}

fn makeSubjectLabel(allocator: std.mem.Allocator, index: *const RepoIndex, target: ResolvedTarget) ![]u8 {
    return switch (target.target_kind) {
        .file => allocator.dupe(u8, index.files.items[target.file_index].rel_path),
        .declaration => std.fmt.allocPrint(allocator, "{s}:{s}", .{
            index.files.items[target.file_index].rel_path,
            index.declarations.items[target.decl_index.?].name,
        }),
    };
}

fn groundedTargetKindName(index: *const RepoIndex, target: ResolvedTarget) []const u8 {
    return switch (target.target_kind) {
        .file => "file",
        .declaration => declKindName(index.declarations.items[target.decl_index.?].kind),
    };
}

fn parseGroundingRegion(spec: []const u8) ?GroundingRegion {
    if (!std.mem.startsWith(u8, spec, "region:")) return null;
    const payload = spec["region:".len..];
    const colon = std.mem.lastIndexOfScalar(u8, payload, ':') orelse return null;
    const dash_rel = std.mem.indexOfScalar(u8, payload[colon + 1 ..], '-') orelse return null;
    const dash = colon + 1 + dash_rel;
    const rel_path = payload[0..colon];
    if (rel_path.len == 0) return null;
    const start_line = std.fmt.parseUnsigned(u32, payload[colon + 1 .. dash], 10) catch return null;
    const end_line = std.fmt.parseUnsigned(u32, payload[dash + 1 ..], 10) catch return null;
    if (start_line == 0 or end_line < start_line) return null;
    return .{
        .rel_path = rel_path,
        .start_line = start_line,
        .end_line = end_line,
    };
}

fn findFileIndexByRelPath(index: *const RepoIndex, rel_path: []const u8) ?u32 {
    for (index.files.items, 0..) |file, file_idx| {
        if (std.mem.eql(u8, file.rel_path, rel_path) or std.mem.endsWith(u8, file.rel_path, rel_path)) {
            return @intCast(file_idx);
        }
    }
    return null;
}

fn upsertGroundingAggregate(out: *std.ArrayList(GroundingTargetAggregate), next: GroundingTargetAggregate) !void {
    for (out.items) |*existing| {
        if (!resolvedTargetsEqual(existing.target, next.target)) continue;
        const previous_score = existing.score;
        existing.score +|= next.score;
        existing.support_count +|= next.support_count;
        if (next.score > previous_score) existing.best_ref_index = next.best_ref_index;
        return;
    }
    try out.append(next);
}

fn resolvedTargetsEqual(lhs: ResolvedTarget, rhs: ResolvedTarget) bool {
    return lhs.target_kind == rhs.target_kind and
        lhs.file_index == rhs.file_index and
        lhs.decl_index == rhs.decl_index;
}

fn lessThanGroundingAggregate(index: *const RepoIndex, lhs: GroundingTargetAggregate, rhs: GroundingTargetAggregate) bool {
    if (lhs.score != rhs.score) return lhs.score > rhs.score;
    if (lhs.support_count != rhs.support_count) return lhs.support_count > rhs.support_count;
    return std.mem.order(u8, index.files.items[lhs.target.file_index].rel_path, index.files.items[rhs.target.file_index].rel_path) == .lt;
}

fn findAmbiguousGroundingTrace(items: []const GroundingTrace) bool {
    for (items) |item| {
        if (item.ambiguous) return true;
    }
    return false;
}

fn markAmbiguousGroundingTraces(items: []GroundingTrace, ambiguous: bool, top_score: u32, margin: u32) void {
    if (!ambiguous) return;
    for (items) |*item| {
        if (top_score -| item.mapping_score <= margin) item.ambiguous = true;
    }
}

fn hasEquivalentGroundingSupport(items: []const GroundingTrace) bool {
    for (items, 0..) |lhs, lhs_idx| {
        if (!lhs.usable or lhs.target_label == null) continue;
        var rhs_idx = lhs_idx + 1;
        while (rhs_idx < items.len) : (rhs_idx += 1) {
            const rhs = items[rhs_idx];
            if (!rhs.usable or rhs.target_label == null) continue;
            if (std.mem.eql(u8, lhs.target_label.?, rhs.target_label.?)) continue;
            if (lhs.lookup_score != rhs.lookup_score) continue;
            if (lhs.token_support_count != rhs.token_support_count) continue;
            if (lhs.pattern_support_count != rhs.pattern_support_count) continue;
            if (lhs.source_support_count != rhs.source_support_count) continue;
            return true;
        }
    }
    return false;
}

fn collectCombinedTargetInvariants(
    allocator: std.mem.Allocator,
    index: *const RepoIndex,
    primary: ResolvedTarget,
    grounded: ?ResolvedTarget,
) ![]Invariant {
    var out = std.ArrayList(Invariant).init(allocator);
    errdefer out.deinit();

    const primary_invariants = try collectTargetInvariants(allocator, index, primary);
    defer allocator.free(primary_invariants);
    for (primary_invariants) |item| try appendInvariantUnique(&out, item);

    if (grounded) |mapped| {
        const grounded_invariants = try collectTargetInvariants(allocator, index, mapped);
        defer allocator.free(grounded_invariants);
        for (grounded_invariants) |item| try appendInvariantUnique(&out, item);
    }

    return out.toOwnedSlice();
}

fn collectEvidenceSeedPaths(
    out: *std.ArrayList([]const u8),
    index: *const RepoIndex,
    seeds: []const EvidenceSeed,
    max_items: usize,
) !void {
    for (seeds) |seed| {
        if (out.items.len >= max_items) return;
        try appendUniqueRelPath(out, index.files.items[seed.file_index].rel_path, max_items);
    }
}

fn collectContradictionPaths(
    out: *std.ArrayList([]const u8),
    index: *const RepoIndex,
    seeds: []const ContradictionSeed,
    max_items: usize,
) !void {
    for (seeds) |seed| {
        if (out.items.len >= max_items) return;
        try appendUniqueRelPath(out, index.files.items[seed.file_index].rel_path, max_items);
    }
}

fn appendUniqueRelPath(out: *std.ArrayList([]const u8), rel_path: []const u8, max_items: usize) !void {
    if (out.items.len >= max_items) return;
    for (out.items) |existing| {
        if (std.mem.eql(u8, existing, rel_path)) return;
    }
    try out.append(rel_path);
}

fn lookupQueryAbstractions(
    allocator: std.mem.Allocator,
    paths: *const shards.Paths,
    query_kind: QueryKind,
    rel_paths: []const []const u8,
    max_items: usize,
) ![]abstractions.SupportReference {
    return abstractions.lookupConcepts(allocator, paths, .{
        .rel_paths = rel_paths,
        .max_items = @min(max_items, 4),
        .include_staged = false,
        .prefer_higher_tiers = true,
        .category_hint = abstractionCategoryHint(query_kind),
    });
}

fn countUsableAbstractionTraces(items: []const AbstractionTrace) usize {
    var count: usize = 0;
    for (items) |item| {
        if (item.usable) count += 1;
    }
    return count;
}

fn countUsableGroundingTraces(items: []const GroundingTrace) usize {
    var count: usize = 0;
    for (items) |item| {
        if (item.usable and !item.ambiguous) count += 1;
    }
    return count;
}

fn supportEvidenceCount(result: *const Result) usize {
    return result.evidence.len +
        result.refactor_path.len +
        result.overlap.len +
        result.contradiction_traces.len +
        countUsableAbstractionTraces(result.abstraction_traces) +
        countUsableGroundingTraces(result.grounding_traces);
}

fn supportDecisionCount(result: *const Result) usize {
    return result.target_candidates.len + result.query_hypotheses.len;
}

fn buildMinimumSupportReason(allocator: std.mem.Allocator, result: *const Result) ![]u8 {
    if (supportDecisionCount(result) == 0) {
        return allocator.dupe(u8, "supported output lacked target or hypothesis selection traces");
    }
    if (supportEvidenceCount(result) == 0) {
        return allocator.dupe(u8, "supported output lacked evidence, contradiction checks, abstraction support, or grounding support");
    }
    return allocator.dupe(u8, "supported output lacked the minimum bounded support required for final permission");
}

fn enforceSupportPermission(allocator: std.mem.Allocator, result: *Result) !void {
    if (result.status != .supported) return;
    if (supportDecisionCount(result) > 0 and supportEvidenceCount(result) > 0) return;
    result.status = .unresolved;
    result.stop_reason = .low_confidence;
    if (result.unresolved_detail) |detail| allocator.free(detail);
    result.unresolved_detail = try buildMinimumSupportReason(allocator, result);
}

fn appendSupportGraphNode(
    allocator: std.mem.Allocator,
    nodes: *std.ArrayList(SupportGraphNode),
    id: []const u8,
    kind: SupportNodeKind,
    label: []const u8,
    rel_path: ?[]const u8,
    line: u32,
    score: u32,
    usable: bool,
    detail: ?[]const u8,
) !void {
    try nodes.append(.{
        .id = try allocator.dupe(u8, id),
        .kind = kind,
        .label = try allocator.dupe(u8, label),
        .rel_path = if (rel_path) |path| try allocator.dupe(u8, path) else null,
        .line = line,
        .score = score,
        .usable = usable,
        .detail = if (detail) |item| try allocator.dupe(u8, item) else null,
    });
}

fn appendSupportGraphEdge(
    allocator: std.mem.Allocator,
    edges: *std.ArrayList(SupportGraphEdge),
    from_id: []const u8,
    to_id: []const u8,
    kind: SupportEdgeKind,
) !void {
    try edges.append(.{
        .from_id = try allocator.dupe(u8, from_id),
        .to_id = try allocator.dupe(u8, to_id),
        .kind = kind,
    });
}

fn buildCodeIntelSupportGraph(allocator: std.mem.Allocator, result: *const Result) !SupportGraph {
    var nodes = std.ArrayList(SupportGraphNode).init(allocator);
    errdefer {
        for (nodes.items) |node| {
            allocator.free(node.id);
            allocator.free(node.label);
            if (node.rel_path) |rel_path| allocator.free(rel_path);
            if (node.detail) |detail| allocator.free(detail);
        }
        nodes.deinit();
    }
    var edges = std.ArrayList(SupportGraphEdge).init(allocator);
    errdefer {
        for (edges.items) |edge| {
            allocator.free(edge.from_id);
            allocator.free(edge.to_id);
        }
        edges.deinit();
    }

    try appendSupportGraphNode(allocator, &nodes, "output", .output, @tagName(result.status), null, 0, result.confidence, result.status == .supported, result.unresolved_detail);
    try appendSupportGraphNode(allocator, &nodes, "shard", .shard, result.shard_id, null, 0, 0, true, @tagName(result.shard_kind));
    try appendSupportGraphNode(allocator, &nodes, "reasoning", .reasoning, mc.reasoningModeName(result.reasoning_mode), null, 0, result.confidence, true, if (result.stop_reason == .none) null else @tagName(result.stop_reason));
    try appendSupportGraphEdge(allocator, &edges, "output", "shard", .sourced_from);
    if (result.intent) |intent| {
        try appendSupportGraphNode(
            allocator,
            &nodes,
            "intent",
            .intent,
            task_intent.actionName(intent.action),
            null,
            0,
            0,
            intent.status == .grounded,
            intent.unresolved_detail,
        );
        try appendSupportGraphEdge(allocator, &edges, "output", "intent", .requested_by);
    }
    try appendSupportGraphEdge(allocator, &edges, "output", "reasoning", .derived_in);

    if (result.primary) |subject| {
        try appendSupportGraphNode(allocator, &nodes, "target_primary", .target_candidate, subject.name, subject.rel_path, subject.line, if (result.target_candidates.len > 0) result.target_candidates[0].score else 0, true, subject.kind_name);
        try appendSupportGraphEdge(allocator, &edges, "output", "target_primary", .selected_from);
    }

    for (result.target_candidates, 0..) |item, idx| {
        if (idx >= 3) break;
        const node_id = try std.fmt.allocPrint(allocator, "target_candidate_{d}", .{idx + 1});
        defer allocator.free(node_id);
        try appendSupportGraphNode(allocator, &nodes, node_id, .target_candidate, item.label, null, 0, item.score, true, null);
        try appendSupportGraphEdge(allocator, &edges, "output", node_id, .selected_from);
    }
    for (result.query_hypotheses, 0..) |item, idx| {
        if (idx >= 4) break;
        const node_id = try std.fmt.allocPrint(allocator, "hypothesis_{d}", .{idx + 1});
        defer allocator.free(node_id);
        try appendSupportGraphNode(allocator, &nodes, node_id, .query_hypothesis, item.label, null, 0, item.score, true, null);
        try appendSupportGraphEdge(allocator, &edges, "output", node_id, .selected_by);
    }
    for (result.evidence, 0..) |item, idx| {
        if (idx >= 4) break;
        const node_id = try std.fmt.allocPrint(allocator, "evidence_{d}", .{idx + 1});
        defer allocator.free(node_id);
        try appendSupportGraphNode(allocator, &nodes, node_id, .evidence, item.reason, item.rel_path, item.line, 0, true, item.subsystem);
        try appendSupportGraphEdge(allocator, &edges, "output", node_id, .supported_by);
    }
    for (result.contradiction_traces, 0..) |item, idx| {
        if (idx >= 4) break;
        const node_id = try std.fmt.allocPrint(allocator, "contradiction_{d}", .{idx + 1});
        defer allocator.free(node_id);
        try appendSupportGraphNode(allocator, &nodes, node_id, .contradiction, item.reason, item.rel_path, item.line, 0, true, item.category);
        try appendSupportGraphEdge(allocator, &edges, "output", node_id, .checked_by);
    }
    for (result.abstraction_traces, 0..) |item, idx| {
        if (idx >= 4) break;
        const node_id = try std.fmt.allocPrint(allocator, "abstraction_{d}", .{idx + 1});
        defer allocator.free(node_id);
        const detail = try std.fmt.allocPrint(allocator, "{s}/{s} {s}; provenance {s}/{s}", .{
            abstractions.tierName(item.tier),
            abstractions.categoryName(item.category),
            abstractions.selectionModeName(item.selection_mode),
            @tagName(item.owner_kind),
            item.owner_id,
        });
        defer allocator.free(detail);
        try appendSupportGraphNode(allocator, &nodes, node_id, .abstraction, item.label, null, 0, item.lookup_score, item.usable, detail);
        try appendSupportGraphEdge(allocator, &edges, "output", node_id, .supported_by);
    }
    for (result.grounding_traces, 0..) |item, idx| {
        if (idx >= 4) break;
        const node_id = try std.fmt.allocPrint(allocator, "grounding_{d}", .{idx + 1});
        defer allocator.free(node_id);
        try appendSupportGraphNode(allocator, &nodes, node_id, .grounding, item.concept, item.target_rel_path, item.target_line, item.mapping_score, item.usable and !item.ambiguous, item.detail);
        try appendSupportGraphEdge(allocator, &edges, "output", node_id, .grounded_by);
    }

    const minimum_met = result.status == .supported and supportDecisionCount(result) > 0 and supportEvidenceCount(result) > 0;
    if (!minimum_met and result.unresolved_detail != null) {
        try appendSupportGraphNode(allocator, &nodes, "gap", .gap, "support_gap", null, 0, 0, false, result.unresolved_detail);
        try appendSupportGraphEdge(allocator, &edges, "output", "gap", .blocked_by);
    }

    return .{
        .allocator = allocator,
        .permission = result.status,
        .minimum_met = minimum_met,
        .flow_mode = try allocator.dupe(u8, mc.reasoningModeName(result.reasoning_mode)),
        .unresolved_reason = if (result.unresolved_detail) |detail| try allocator.dupe(u8, detail) else null,
        .nodes = try nodes.toOwnedSlice(),
        .edges = try edges.toOwnedSlice(),
    };
}

pub fn renderJson(allocator: std.mem.Allocator, result: *const Result) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const writer = out.writer();

    try writer.writeAll("{");
    try writeJsonFieldString(writer, "status", @tagName(result.status), true);
    try writeJsonFieldString(writer, "queryKind", @tagName(result.query_kind), false);
    try writeJsonFieldString(writer, "target", result.query_target, false);
    if (result.query_other_target) |other| {
        try writer.writeAll(",\"otherTarget\":");
        try writeJsonString(writer, other);
    }
    try writer.writeAll(",\"repoRoot\":");
    try writeJsonString(writer, result.repo_root);
    try writer.writeAll(",\"reasoning\":");
    try writeReasoningJson(writer, result.reasoning_mode);
    try writer.writeAll(",\"shard\":{");
    try writeJsonFieldString(writer, "kind", @tagName(result.shard_kind), true);
    try writeJsonFieldString(writer, "id", result.shard_id, false);
    try writeJsonFieldString(writer, "root", result.shard_root, false);
    try writer.writeAll("}");
    try writer.writeAll(",\"honesty\":{");
    try writeJsonFieldString(writer, "stopReason", @tagName(result.stop_reason), true);
    try writer.print(",\"confidence\":{d}", .{result.confidence});
    try writer.writeAll("}");
    if (result.intent) |intent| {
        const rendered_intent = try task_intent.renderJson(allocator, &intent);
        defer allocator.free(rendered_intent);
        try writer.writeAll(",\"intent\":");
        try writer.writeAll(rendered_intent);
    }

    if (result.invariant_model) |model| try writeOptionalStringField(writer, "invariantModel", model);
    if (result.selected_scope) |scope| try writeOptionalStringField(writer, "selectedScope", scope);
    if (result.contradiction_kind) |kind| try writeOptionalStringField(writer, "contradictionKind", kind);
    if (result.unresolved_detail) |detail| try writeOptionalStringField(writer, "detail", detail);

    if (result.primary) |subject| {
        try writer.writeAll(",\"primary\":");
        try writeSubject(writer, subject);
    }
    if (result.secondary) |subject| {
        try writer.writeAll(",\"secondary\":");
        try writeSubject(writer, subject);
    }

    // The pilot emits the same layer names used elsewhere in the repo, but the
    // meanings stay narrow here: layer1 is deterministic indexing, layer2a is
    // target resolution, layer2b is bounded query hypothesis scoring, and
    // layer3 is the final honesty status.
    try writer.writeAll(",\"trace\":{");
    try writer.print("\"layer1\":{{\"files\":{d},\"declarations\":{d}}}", .{ result.layer1_file_count, result.layer1_decl_count });
    try writer.writeAll(",\"layer2a\":{\"targetCandidates\":");
    try writeCandidateTraceArray(writer, result.target_candidates);
    try writer.writeAll("}");
    try writer.writeAll(",\"layer2b\":{\"queryHypotheses\":");
    try writeCandidateTraceArray(writer, result.query_hypotheses);
    try writer.writeAll(",\"abstractions\":");
    try writeAbstractionTraceArray(writer, result.abstraction_traces);
    try writer.writeAll(",\"groundings\":");
    try writeGroundingTraceArray(writer, result.grounding_traces);
    try writer.writeAll("}");
    try writer.writeAll(",\"layer3\":{");
    try writeJsonFieldString(writer, "mode", mc.reasoningModeName(result.reasoning_mode), true);
    try writeJsonFieldString(writer, "status", @tagName(result.status), false);
    try writeJsonFieldString(writer, "stopReason", @tagName(result.stop_reason), false);
    try writer.print(",\"confidence\":{d}", .{result.confidence});
    try writer.writeAll(",\"policy\":");
    try writeReasoningPolicyJson(writer, reasoningPolicy(result.reasoning_mode));
    try writer.writeAll("}}");

    try writer.writeAll(",\"evidence\":");
    try writeEvidenceArray(writer, result.evidence);
    try writer.writeAll(",\"contradictionTraces\":");
    try writeContradictionTraceArray(writer, result.contradiction_traces);
    try writer.writeAll(",\"refactorPath\":");
    try writeEvidenceArray(writer, result.refactor_path);
    try writer.writeAll(",\"overlap\":");
    try writeEvidenceArray(writer, result.overlap);
    try writer.writeAll(",\"affectedSubsystems\":");
    try writeSubsystemArray(writer, result.affected_subsystems);
    try writer.writeAll(",\"supportGraph\":");
    try writeSupportGraphJson(writer, result.support_graph);
    try writer.writeAll("}");
    return out.toOwnedSlice();
}

fn writeReasoningJson(writer: anytype, mode: mc.ReasoningMode) !void {
    try writer.writeAll("{\"mode\":");
    try writeJsonString(writer, mc.reasoningModeName(mode));
    try writer.writeAll(",\"policy\":");
    try writeReasoningPolicyJson(writer, reasoningPolicy(mode));
    try writer.writeAll("}");
}

fn writeReasoningPolicyJson(writer: anytype, policy: mc.ReasoningPolicy) !void {
    try writer.print(
        "{{\"internalBranchAllowance\":{d},\"internalContinuationWidth\":{d},\"internalCandidatePromotionFloor\":{d},\"boundedAlternativeGeneration\":{d}}}",
        .{
            policy.internal_branch_allowance,
            policy.internal_continuation_width,
            policy.internal_candidate_promotion_floor,
            mc.boundedAlternativeGeneration(policy),
        },
    );
}

fn queryImpact(allocator: std.mem.Allocator, index: *const RepoIndex, paths: *const shards.Paths, options: Options) !Result {
    var result = try initResult(allocator, options);
    errdefer result.deinit();
    result.invariant_model = INVARIANT_MODEL_NAME;

    var target_candidates = std.ArrayList(CandidateTrace).init(allocator);
    defer freeCandidateTraceList(allocator, &target_candidates);

    const resolved = try resolveTarget(allocator, index, options.target, options.reasoning_mode, &target_candidates);
    result.target_candidates = try target_candidates.toOwnedSlice();

    if (resolved.stop_reason != .none) {
        result.status = .unresolved;
        result.stop_reason = resolved.stop_reason;
        result.confidence = resolved.confidence;
        result.unresolved_detail = try allocator.dupe(u8, resolved.detail);
        return result;
    }

    const target = resolved.target.?;
    result.primary = try makeSubject(allocator, index, target);

    var direct_refs = std.ArrayList(EvidenceSeed).init(allocator);
    defer direct_refs.deinit();
    try collectDirectDependents(index, target, &direct_refs);

    var dependency_surface = std.ArrayList(EvidenceSeed).init(allocator);
    defer dependency_surface.deinit();
    switch (target.target_kind) {
        .file => try collectReverseImportSurface(index, target.file_index, 2, &dependency_surface),
        .declaration => try collectReverseSemanticSurface(index, target.decl_index.?, 2, &dependency_surface),
    }

    var import_surface = std.ArrayList(EvidenceSeed).init(allocator);
    defer import_surface.deinit();
    try collectReverseImportSurface(index, target.file_index, 2, &import_surface);

    var grounding = try lookupSymbolicGrounding(allocator, index, paths, options.query_kind, target);
    defer grounding.deinit(allocator);
    result.grounding_traces = grounding.traces;
    grounding.traces = &.{};
    if (grounding.selected_target) |grounded_target| {
        try collectDirectDependents(index, grounded_target, &direct_refs);
        switch (grounded_target.target_kind) {
            .file => try collectReverseImportSurface(index, grounded_target.file_index, 2, &dependency_surface),
            .declaration => try collectReverseSemanticSurface(index, grounded_target.decl_index.?, 2, &dependency_surface),
        }
        try collectReverseImportSurface(index, grounded_target.file_index, 2, &import_surface);
    }

    const invariants = try collectCombinedTargetInvariants(allocator, index, target, grounding.selected_target);
    defer allocator.free(invariants);
    const contradiction_seeds = try collectSingleTargetContradictions(allocator, invariants);
    defer allocator.free(contradiction_seeds);

    var abstraction_paths = std.ArrayList([]const u8).init(allocator);
    defer abstraction_paths.deinit();
    const primary_path = index.files.items[target.file_index].rel_path;
    try appendUniqueRelPath(&abstraction_paths, primary_path, options.max_items);
    try collectEvidenceSeedPaths(&abstraction_paths, index, direct_refs.items, options.max_items);
    try collectEvidenceSeedPaths(&abstraction_paths, index, dependency_surface.items, options.max_items);
    try collectEvidenceSeedPaths(&abstraction_paths, index, import_surface.items, options.max_items);
    try collectContradictionPaths(&abstraction_paths, index, contradiction_seeds, options.max_items);
    const abstraction_refs = try lookupQueryAbstractions(allocator, paths, options.query_kind, abstraction_paths.items, options.max_items);
    defer abstractions.deinitSupportReferences(allocator, abstraction_refs);
    result.abstraction_traces = try buildAbstractionTraces(allocator, abstraction_refs);
    var branch_biases = buildBranchBiases(options.query_kind, abstraction_refs);
    branch_biases.merge(grounding.biases);

    if (shouldLeaveSymbolicTargetUnresolved(index, target, direct_refs.items, dependency_surface.items, import_surface.items, contradiction_seeds, abstraction_refs) and grounding.state != .selected) {
        result.status = .unresolved;
        result.stop_reason = .low_confidence;
        result.unresolved_detail = if (grounding.detail) |detail| try allocator.dupe(u8, detail) else try allocator.dupe(u8, "symbolic target did not expose enough bounded structural grounding");
        return result;
    }

    if (contradiction_seeds.len > 0) {
        result.contradiction_traces = try buildContradictionTraces(allocator, index, contradiction_seeds, options.max_items);
        const contradiction_biases = buildBranchBiases(.contradicts, abstraction_refs);

        var contradiction_hypotheses = std.ArrayList(CandidateTrace).init(allocator);
        defer freeCandidateTraceList(allocator, &contradiction_hypotheses);
        var contradiction_branch_ids = std.ArrayList(u32).init(allocator);
        defer contradiction_branch_ids.deinit();
        var contradiction_scores = std.ArrayList(u32).init(allocator);
        defer contradiction_scores.deinit();
        try buildContradictionHypotheses(
            allocator,
            contradiction_seeds,
            &contradiction_hypotheses,
            &contradiction_branch_ids,
            &contradiction_scores,
        );
        applyBiasToHypotheses(&contradiction_hypotheses, contradiction_branch_ids.items, &contradiction_scores, contradiction_biases);

        result.query_hypotheses = try contradiction_hypotheses.toOwnedSlice();
        const decision = mc.decideFromScores(
            contradiction_branch_ids.items,
            contradiction_scores.items,
            1,
            @intCast(contradiction_branch_ids.items.len),
            codeIntelLayer3Config(options.reasoning_mode, 170, 6),
        );
        result.confidence = decision.confidence;
        result.stop_reason = decision.stop_reason;
        if (decision.stop_reason != .none) {
            result.status = .unresolved;
            result.unresolved_detail = try allocator.dupe(u8, "impact contradiction set could not be selected without contradiction or low confidence");
            return result;
        }

        const selected_category = contradictionCategoryFromBranchId(decision.output);
        result.status = .supported;
        result.selected_scope = "bounded_invariant_impact";
        result.contradiction_kind = contradictionCategoryName(selected_category);
        result.evidence = try buildEvidenceFromContradictions(allocator, index, contradiction_seeds, selected_category, options.max_items);
        result.affected_subsystems = try collectSubsystemsFromContradictions(allocator, index, contradiction_seeds, selected_category);
        return result;
    }

    var hypotheses = std.ArrayList(CandidateTrace).init(allocator);
    defer freeCandidateTraceList(allocator, &hypotheses);

    var branch_ids = std.ArrayList(u32).init(allocator);
    defer branch_ids.deinit();
    var scores = std.ArrayList(u32).init(allocator);
    defer scores.deinit();

    try appendHypothesis(allocator, &hypotheses, &branch_ids, &scores, .{
        .branch_id = 1,
        .label = "local_only",
        .score = @as(u32, 180) + @min(target.confidence / 2, @as(u32, 80)) + branch_biases.get(1),
        .evidence_count = 0,
        .abstraction_bias = branch_biases.get(1),
    });
    if (direct_refs.items.len > 0) {
        try appendHypothesis(allocator, &hypotheses, &branch_ids, &scores, .{
            .branch_id = 2,
            .label = "direct_semantic_surface",
            .score = @as(u32, 220) + @as(u32, @intCast(@min(direct_refs.items.len, 8))) * 25 + branch_biases.get(2),
            .evidence_count = @intCast(direct_refs.items.len),
            .abstraction_bias = branch_biases.get(2),
        });
    }
    if (dependency_surface.items.len > direct_refs.items.len) {
        try appendHypothesis(allocator, &hypotheses, &branch_ids, &scores, .{
            .branch_id = 3,
            .label = "bounded_dependency_graph",
            .score = @as(u32, 235) + @as(u32, @intCast(@min(dependency_surface.items.len, 8))) * 18 + branch_biases.get(3),
            .evidence_count = @intCast(dependency_surface.items.len),
            .abstraction_bias = branch_biases.get(3),
        });
    }
    if (import_surface.items.len > 0) {
        try appendHypothesis(allocator, &hypotheses, &branch_ids, &scores, .{
            .branch_id = 4,
            .label = "import_surface",
            .score = @as(u32, 210) + @as(u32, @intCast(@min(import_surface.items.len, 8))) * 20 + branch_biases.get(4),
            .evidence_count = @intCast(import_surface.items.len),
            .abstraction_bias = branch_biases.get(4),
        });
    }
    if (dependency_surface.items.len > 0 or import_surface.items.len > 0) {
        try appendHypothesis(allocator, &hypotheses, &branch_ids, &scores, .{
            .branch_id = 5,
            .label = "combined_surface",
            .score = @as(u32, 250) + @as(u32, @intCast(@min(dependency_surface.items.len, 8))) * 16 + @as(u32, @intCast(@min(import_surface.items.len, 8))) * 12 + branch_biases.get(5),
            .evidence_count = @intCast(dependency_surface.items.len + import_surface.items.len),
            .abstraction_bias = branch_biases.get(5),
        });
    }

    result.query_hypotheses = try hypotheses.toOwnedSlice();
    const decision = mc.decideFromScores(branch_ids.items, scores.items, 1, @intCast(branch_ids.items.len), codeIntelLayer3Config(options.reasoning_mode, 150, 5));
    result.confidence = decision.confidence;
    result.stop_reason = decision.stop_reason;
    if (decision.stop_reason != .none) {
        result.status = .unresolved;
        result.unresolved_detail = try allocator.dupe(u8, "impact surface could not be selected without contradiction or low confidence");
        return result;
    }

    result.status = .supported;
    const branch = decision.output;
    result.selected_scope = switch (branch) {
        1 => "local_only",
        2 => "direct_semantic_surface",
        3 => "bounded_dependency_graph",
        4 => "import_surface",
        5 => "combined_surface",
        else => "local_only",
    };

    var chosen = std.ArrayList(EvidenceSeed).init(allocator);
    defer chosen.deinit();
    switch (branch) {
        1 => {},
        2 => try appendEvidenceSlice(&chosen, direct_refs.items),
        3 => try appendEvidenceSlice(&chosen, dependency_surface.items),
        4 => try appendEvidenceSlice(&chosen, import_surface.items),
        5 => {
            try appendEvidenceSlice(&chosen, dependency_surface.items);
            try appendEvidenceSlice(&chosen, import_surface.items);
        },
        else => {},
    }

    result.evidence = try buildEvidence(allocator, index, chosen.items, options.max_items);
    result.affected_subsystems = try collectSubsystems(allocator, index, chosen.items);
    return result;
}

fn queryBreaksIf(allocator: std.mem.Allocator, index: *const RepoIndex, paths: *const shards.Paths, options: Options) !Result {
    var result = try initResult(allocator, options);
    errdefer result.deinit();
    result.invariant_model = INVARIANT_MODEL_NAME;

    var target_candidates = std.ArrayList(CandidateTrace).init(allocator);
    defer freeCandidateTraceList(allocator, &target_candidates);

    const resolved = try resolveTarget(allocator, index, options.target, options.reasoning_mode, &target_candidates);
    result.target_candidates = try target_candidates.toOwnedSlice();

    if (resolved.stop_reason != .none) {
        result.status = .unresolved;
        result.stop_reason = resolved.stop_reason;
        result.confidence = resolved.confidence;
        result.unresolved_detail = try allocator.dupe(u8, resolved.detail);
        return result;
    }

    const target = resolved.target.?;
    result.primary = try makeSubject(allocator, index, target);

    var direct_refs = std.ArrayList(EvidenceSeed).init(allocator);
    defer direct_refs.deinit();
    try collectDirectDependents(index, target, &direct_refs);

    var dependency_surface = std.ArrayList(EvidenceSeed).init(allocator);
    defer dependency_surface.deinit();
    switch (target.target_kind) {
        .file => try collectReverseImportSurface(index, target.file_index, 2, &dependency_surface),
        .declaration => try collectReverseSemanticSurface(index, target.decl_index.?, 2, &dependency_surface),
    }

    var import_surface = std.ArrayList(EvidenceSeed).init(allocator);
    defer import_surface.deinit();
    try collectReverseImportSurface(index, target.file_index, 2, &import_surface);

    var grounding = try lookupSymbolicGrounding(allocator, index, paths, options.query_kind, target);
    defer grounding.deinit(allocator);
    result.grounding_traces = grounding.traces;
    grounding.traces = &.{};
    if (grounding.selected_target) |grounded_target| {
        try collectDirectDependents(index, grounded_target, &direct_refs);
        switch (grounded_target.target_kind) {
            .file => try collectReverseImportSurface(index, grounded_target.file_index, 2, &dependency_surface),
            .declaration => try collectReverseSemanticSurface(index, grounded_target.decl_index.?, 2, &dependency_surface),
        }
        try collectReverseImportSurface(index, grounded_target.file_index, 2, &import_surface);
    }

    const invariants = try collectCombinedTargetInvariants(allocator, index, target, grounding.selected_target);
    defer allocator.free(invariants);
    const contradiction_seeds = try collectSingleTargetContradictions(allocator, invariants);
    defer allocator.free(contradiction_seeds);

    var abstraction_paths = std.ArrayList([]const u8).init(allocator);
    defer abstraction_paths.deinit();
    const primary_path = index.files.items[target.file_index].rel_path;
    try appendUniqueRelPath(&abstraction_paths, primary_path, options.max_items);
    try collectEvidenceSeedPaths(&abstraction_paths, index, direct_refs.items, options.max_items);
    try collectEvidenceSeedPaths(&abstraction_paths, index, dependency_surface.items, options.max_items);
    try collectEvidenceSeedPaths(&abstraction_paths, index, import_surface.items, options.max_items);
    try collectContradictionPaths(&abstraction_paths, index, contradiction_seeds, options.max_items);
    const abstraction_refs = try lookupQueryAbstractions(allocator, paths, options.query_kind, abstraction_paths.items, options.max_items);
    defer abstractions.deinitSupportReferences(allocator, abstraction_refs);
    result.abstraction_traces = try buildAbstractionTraces(allocator, abstraction_refs);
    var branch_biases = buildBranchBiases(options.query_kind, abstraction_refs);
    branch_biases.merge(grounding.biases);

    if (shouldLeaveSymbolicTargetUnresolved(index, target, direct_refs.items, dependency_surface.items, import_surface.items, contradiction_seeds, abstraction_refs) and grounding.state != .selected) {
        result.status = .unresolved;
        result.stop_reason = .low_confidence;
        result.unresolved_detail = if (grounding.detail) |detail| try allocator.dupe(u8, detail) else try allocator.dupe(u8, "symbolic target did not expose enough bounded structural grounding");
        return result;
    }

    if (contradiction_seeds.len > 0) {
        result.contradiction_traces = try buildContradictionTraces(allocator, index, contradiction_seeds, options.max_items);
        const contradiction_biases = buildBranchBiases(.contradicts, abstraction_refs);

        var contradiction_hypotheses = std.ArrayList(CandidateTrace).init(allocator);
        defer freeCandidateTraceList(allocator, &contradiction_hypotheses);
        var contradiction_branch_ids = std.ArrayList(u32).init(allocator);
        defer contradiction_branch_ids.deinit();
        var contradiction_scores = std.ArrayList(u32).init(allocator);
        defer contradiction_scores.deinit();
        try buildContradictionHypotheses(
            allocator,
            contradiction_seeds,
            &contradiction_hypotheses,
            &contradiction_branch_ids,
            &contradiction_scores,
        );
        applyBiasToHypotheses(&contradiction_hypotheses, contradiction_branch_ids.items, &contradiction_scores, contradiction_biases);

        result.query_hypotheses = try contradiction_hypotheses.toOwnedSlice();
        const decision = mc.decideFromScores(
            contradiction_branch_ids.items,
            contradiction_scores.items,
            1,
            @intCast(contradiction_branch_ids.items.len),
            codeIntelLayer3Config(options.reasoning_mode, 180, 6),
        );
        result.confidence = decision.confidence;
        result.stop_reason = decision.stop_reason;
        if (decision.stop_reason != .none) {
            result.status = .unresolved;
            result.unresolved_detail = try allocator.dupe(u8, "bounded breakage contradiction path could not be selected without guessing");
            return result;
        }

        const selected_category = contradictionCategoryFromBranchId(decision.output);
        result.status = .supported;
        result.selected_scope = "bounded_invariant_breakage";
        result.contradiction_kind = contradictionCategoryName(selected_category);
        result.evidence = try buildEvidenceFromContradictions(allocator, index, contradiction_seeds, selected_category, options.max_items);
        result.refactor_path = try buildRefactorPathFromContradictions(allocator, index, target, contradiction_seeds, selected_category, options.max_items);
        result.affected_subsystems = try collectSubsystemsFromContradictions(allocator, index, contradiction_seeds, selected_category);
        return result;
    }

    var hypotheses = std.ArrayList(CandidateTrace).init(allocator);
    defer freeCandidateTraceList(allocator, &hypotheses);

    var branch_ids = std.ArrayList(u32).init(allocator);
    defer branch_ids.deinit();
    var scores = std.ArrayList(u32).init(allocator);
    defer scores.deinit();

    try appendHypothesis(allocator, &hypotheses, &branch_ids, &scores, .{
        .branch_id = 1,
        .label = "local_patch",
        .score = (if (direct_refs.items.len == 0 and import_surface.items.len == 0) @as(u32, 230) else @as(u32, 170)) + branch_biases.get(1),
        .evidence_count = 0,
        .abstraction_bias = branch_biases.get(1),
    });
    if (direct_refs.items.len > 0) {
        try appendHypothesis(allocator, &hypotheses, &branch_ids, &scores, .{
            .branch_id = 2,
            .label = "semantic_caller_patch",
            .score = @as(u32, 240) + @as(u32, @intCast(@min(direct_refs.items.len, 8))) * 25 + branch_biases.get(2),
            .evidence_count = @intCast(direct_refs.items.len),
            .abstraction_bias = branch_biases.get(2),
        });
    }
    if (dependency_surface.items.len > 0 or import_surface.items.len > 0) {
        try appendHypothesis(allocator, &hypotheses, &branch_ids, &scores, .{
            .branch_id = 3,
            .label = "seam_patch",
            .score = @as(u32, 235) + @as(u32, @intCast(@min(dependency_surface.items.len, 8))) * 16 + @as(u32, @intCast(@min(import_surface.items.len, 8))) * 12 + branch_biases.get(3),
            .evidence_count = @intCast(dependency_surface.items.len + import_surface.items.len),
            .abstraction_bias = branch_biases.get(3),
        });
    }

    result.query_hypotheses = try hypotheses.toOwnedSlice();
    const decision = mc.decideFromScores(branch_ids.items, scores.items, 1, @intCast(branch_ids.items.len), codeIntelLayer3Config(options.reasoning_mode, 160, 5));
    result.confidence = decision.confidence;
    result.stop_reason = decision.stop_reason;
    if (decision.stop_reason != .none) {
        result.status = .unresolved;
        result.unresolved_detail = try allocator.dupe(u8, "bounded breakage path could not be selected without guessing");
        return result;
    }

    result.status = .supported;
    const branch = decision.output;
    result.selected_scope = switch (branch) {
        1 => "local_patch",
        2 => "semantic_caller_patch",
        3 => "seam_patch",
        else => "local_patch",
    };

    var chosen = std.ArrayList(EvidenceSeed).init(allocator);
    defer chosen.deinit();
    switch (branch) {
        1 => {},
        2 => try appendEvidenceSlice(&chosen, direct_refs.items),
        3 => {
            try appendEvidenceSlice(&chosen, dependency_surface.items);
            try appendEvidenceSlice(&chosen, import_surface.items);
        },
        else => {},
    }

    result.evidence = try buildEvidence(allocator, index, chosen.items, options.max_items);
    result.refactor_path = try buildRefactorPath(allocator, index, target, chosen.items, options.max_items);
    result.affected_subsystems = try collectSubsystems(allocator, index, chosen.items);
    return result;
}

fn queryContradicts(allocator: std.mem.Allocator, index: *const RepoIndex, paths: *const shards.Paths, options: Options) !Result {
    var result = try initResult(allocator, options);
    errdefer result.deinit();
    result.invariant_model = INVARIANT_MODEL_NAME;

    const other_target = options.other_target orelse {
        result.status = .unresolved;
        result.stop_reason = .low_confidence;
        result.unresolved_detail = try allocator.dupe(u8, "contradicts requires two targets");
        return result;
    };

    var target_candidates = std.ArrayList(CandidateTrace).init(allocator);
    defer freeCandidateTraceList(allocator, &target_candidates);
    const left_resolved = try resolveTarget(allocator, index, options.target, options.reasoning_mode, &target_candidates);
    var secondary_candidates = std.ArrayList(CandidateTrace).init(allocator);
    defer freeCandidateTraceList(allocator, &secondary_candidates);
    const right_resolved = try resolveTarget(allocator, index, other_target, options.reasoning_mode, &secondary_candidates);

    var merged_candidates = std.ArrayList(CandidateTrace).init(allocator);
    defer freeCandidateTraceList(allocator, &merged_candidates);
    try appendCandidateTraceCopies(allocator, &merged_candidates, target_candidates.items);
    try appendCandidateTraceCopies(allocator, &merged_candidates, secondary_candidates.items);
    result.target_candidates = try merged_candidates.toOwnedSlice();

    if (left_resolved.stop_reason != .none) {
        result.status = .unresolved;
        result.stop_reason = left_resolved.stop_reason;
        result.confidence = left_resolved.confidence;
        result.unresolved_detail = try allocator.dupe(u8, left_resolved.detail);
        return result;
    }
    if (right_resolved.stop_reason != .none) {
        result.status = .unresolved;
        result.stop_reason = right_resolved.stop_reason;
        result.confidence = right_resolved.confidence;
        result.unresolved_detail = try allocator.dupe(u8, right_resolved.detail);
        return result;
    }

    const left = left_resolved.target.?;
    const right = right_resolved.target.?;
    result.primary = try makeSubject(allocator, index, left);
    result.secondary = try makeSubject(allocator, index, right);

    var left_grounding = try lookupSymbolicGrounding(allocator, index, paths, options.query_kind, left);
    defer left_grounding.deinit(allocator);
    var right_grounding = try lookupSymbolicGrounding(allocator, index, paths, options.query_kind, right);
    defer right_grounding.deinit(allocator);

    if (left_grounding.traces.len > 0 or right_grounding.traces.len > 0) {
        var merged_groundings = std.ArrayList(GroundingTrace).init(allocator);
        errdefer {
            for (merged_groundings.items) |trace| {
                allocator.free(trace.surface);
                allocator.free(trace.concept);
                allocator.free(trace.source_spec);
                allocator.free(trace.owner_id);
                allocator.free(trace.relation);
                if (trace.target_label) |target_label| allocator.free(target_label);
                if (trace.target_rel_path) |target_rel_path| allocator.free(target_rel_path);
                if (trace.target_kind) |target_kind| allocator.free(target_kind);
                if (trace.detail) |detail| allocator.free(detail);
            }
            merged_groundings.deinit();
        }
        try merged_groundings.appendSlice(left_grounding.traces);
        try merged_groundings.appendSlice(right_grounding.traces);
        left_grounding.traces = &.{};
        right_grounding.traces = &.{};
        result.grounding_traces = try merged_groundings.toOwnedSlice();
    }

    const left_invariants = try collectCombinedTargetInvariants(allocator, index, left, left_grounding.selected_target);
    defer allocator.free(left_invariants);
    const right_invariants = try collectCombinedTargetInvariants(allocator, index, right, right_grounding.selected_target);
    defer allocator.free(right_invariants);
    const contradiction_seeds = try collectPairContradictions(
        allocator,
        index,
        if (left_grounding.selected_target) |mapped| mapped else left,
        if (right_grounding.selected_target) |mapped| mapped else right,
        left_invariants,
        right_invariants,
    );
    defer allocator.free(contradiction_seeds);

    var abstraction_paths = std.ArrayList([]const u8).init(allocator);
    defer abstraction_paths.deinit();
    try appendUniqueRelPath(&abstraction_paths, index.files.items[left.file_index].rel_path, options.max_items);
    try appendUniqueRelPath(&abstraction_paths, index.files.items[right.file_index].rel_path, options.max_items);
    try collectContradictionPaths(&abstraction_paths, index, contradiction_seeds, options.max_items);
    const abstraction_refs = try lookupQueryAbstractions(allocator, paths, options.query_kind, abstraction_paths.items, options.max_items);
    defer abstractions.deinitSupportReferences(allocator, abstraction_refs);
    result.abstraction_traces = try buildAbstractionTraces(allocator, abstraction_refs);
    var branch_biases = buildBranchBiases(options.query_kind, abstraction_refs);
    branch_biases.merge(left_grounding.biases);
    branch_biases.merge(right_grounding.biases);

    var hypotheses = std.ArrayList(CandidateTrace).init(allocator);
    defer freeCandidateTraceList(allocator, &hypotheses);
    var branch_ids = std.ArrayList(u32).init(allocator);
    defer branch_ids.deinit();
    var scores = std.ArrayList(u32).init(allocator);
    defer scores.deinit();
    try buildContradictionHypotheses(allocator, contradiction_seeds, &hypotheses, &branch_ids, &scores);
    applyBiasToHypotheses(&hypotheses, branch_ids.items, &scores, branch_biases);

    result.query_hypotheses = try hypotheses.toOwnedSlice();
    result.contradiction_traces = try buildContradictionTraces(allocator, index, contradiction_seeds, options.max_items);
    if (branch_ids.items.len == 0) {
        result.status = .unresolved;
        result.stop_reason = .low_confidence;
        if (left_grounding.detail != null and left_grounding.state != .selected) {
            result.unresolved_detail = try allocator.dupe(u8, left_grounding.detail.?);
        } else if (right_grounding.detail != null and right_grounding.state != .selected) {
            result.unresolved_detail = try allocator.dupe(u8, right_grounding.detail.?);
        } else {
            result.unresolved_detail = try allocator.dupe(u8, "no supported invariant contradiction was found between the two bounded subjects");
        }
        return result;
    }

    const decision = mc.decideFromScores(branch_ids.items, scores.items, 1, @intCast(branch_ids.items.len), codeIntelLayer3Config(options.reasoning_mode, 170, 5));
    result.confidence = decision.confidence;
    result.stop_reason = decision.stop_reason;
    if (decision.stop_reason != .none) {
        result.status = .unresolved;
        result.unresolved_detail = try allocator.dupe(u8, "change contradiction could not be selected without an unsupported tie or low confidence");
        return result;
    }

    result.status = .supported;
    const selected_category = contradictionCategoryFromBranchId(decision.output);
    result.selected_scope = "bounded_invariant_contradiction";
    result.contradiction_kind = contradictionCategoryName(selected_category);
    result.overlap = try buildEvidenceFromContradictions(allocator, index, contradiction_seeds, selected_category, options.max_items);
    result.evidence = try buildEvidenceFromContradictions(allocator, index, contradiction_seeds, selected_category, options.max_items);
    result.affected_subsystems = try collectSubsystemsFromContradictions(allocator, index, contradiction_seeds, selected_category);
    return result;
}

const ResolutionOutcome = struct {
    stop_reason: mc.StopReason = .none,
    confidence: u32 = 0,
    detail: []const u8 = "",
    target: ?ResolvedTarget = null,
};

fn resolveTarget(
    allocator: std.mem.Allocator,
    index: *const RepoIndex,
    raw_target: []const u8,
    reasoning_mode: mc.ReasoningMode,
    traces: *std.ArrayList(CandidateTrace),
) !ResolutionOutcome {
    var candidates = std.ArrayList(ResolutionCandidate).init(allocator);
    defer candidates.deinit();

    if (std.mem.indexOfScalar(u8, raw_target, ':')) |colon| {
        const maybe_path = raw_target[0..colon];
        const symbol = raw_target[colon + 1 ..];
        if (maybe_path.len > 0 and symbol.len > 0) {
            try collectPathSymbolCandidates(index, maybe_path, symbol, &candidates);
        }
    }

    if (candidates.items.len == 0 and (std.mem.indexOfScalar(u8, raw_target, '/') != null or std.mem.endsWith(u8, raw_target, ".zig"))) {
        try collectFileCandidates(index, raw_target, &candidates);
    }
    if (candidates.items.len == 0) {
        try collectDeclCandidates(index, raw_target, &candidates);
    }

    if (candidates.items.len == 0) {
        return .{
            .stop_reason = .low_confidence,
            .detail = "no indexed declaration or file matched the requested target",
        };
    }

    std.sort.heap(ResolutionCandidate, candidates.items, {}, lessThanResolutionCandidate);
    if (candidates.items.len > reasoningBranchCap(reasoning_mode)) candidates.items.len = reasoningBranchCap(reasoning_mode);

    var branch_ids = std.ArrayList(u32).init(allocator);
    defer branch_ids.deinit();
    var scores = std.ArrayList(u32).init(allocator);
    defer scores.deinit();

    for (candidates.items) |candidate| {
        try branch_ids.append(candidate.branch_id);
        try scores.append(candidate.score);
        try traces.append(.{
            .label = try candidateLabel(allocator, index, candidate),
            .score = candidate.score,
            .evidence_count = candidate.evidence_count,
        });
    }

    if (shouldLeaveBareSymbolUnresolved(index, raw_target, candidates.items)) {
        return .{
            .stop_reason = .low_confidence,
            .detail = "bare symbol matched multiple native declarations; use path:symbol to disambiguate",
        };
    }

    const decision = mc.decideFromScores(branch_ids.items, scores.items, 1, @intCast(branch_ids.items.len), codeIntelLayer3Config(reasoning_mode, 120, 5));
    if (decision.stop_reason != .none) {
        return .{
            .stop_reason = decision.stop_reason,
            .confidence = decision.confidence,
            .detail = "target resolution was ambiguous or unsupported",
        };
    }

    for (candidates.items) |candidate| {
        if (candidate.branch_id == decision.output) {
            return .{
                .confidence = decision.confidence,
                .target = .{
                    .target_kind = candidate.target_kind,
                    .file_index = candidate.file_index,
                    .decl_index = candidate.decl_index,
                    .confidence = decision.confidence,
                },
            };
        }
    }

    return .{
        .stop_reason = .internal_error,
        .detail = "layer3 selected a target branch that was not present",
    };
}

fn collectPathSymbolCandidates(index: *const RepoIndex, raw_path: []const u8, symbol: []const u8, out: *std.ArrayList(ResolutionCandidate)) !void {
    for (index.files.items, 0..) |file, file_idx| {
        const exact = std.mem.eql(u8, file.rel_path, raw_path);
        const suffix = std.mem.endsWith(u8, file.rel_path, raw_path);
        if (!exact and !suffix) continue;
        for (file.declaration_indexes.items) |decl_index| {
            const decl = index.declarations.items[decl_index];
            const exact_name = std.mem.eql(u8, decl.name, symbol);
            const leaf_name = std.mem.eql(u8, nativeLeafName(decl.name), symbol) or std.mem.eql(u8, symbolicLeafName(decl.name), symbol);
            if (!exact_name and !leaf_name) continue;
            try out.append(.{
                .branch_id = @intCast(out.items.len + 1),
                .score = (if (exact_name) if (exact) @as(u32, 360) else @as(u32, 320) else if (exact) @as(u32, 300) else @as(u32, 260)) + declarationBonus(index, decl_index),
                .evidence_count = declarationEvidenceCount(index, decl_index),
                .target_kind = .declaration,
                .file_index = @intCast(file_idx),
                .decl_index = decl_index,
            });
        }
    }
}

fn collectFileCandidates(index: *const RepoIndex, raw_path: []const u8, out: *std.ArrayList(ResolutionCandidate)) !void {
    for (index.files.items, 0..) |file, file_idx| {
        const exact = std.mem.eql(u8, file.rel_path, raw_path);
        const suffix = std.mem.endsWith(u8, file.rel_path, raw_path);
        if (!exact and !suffix) continue;
        const evidence_count = reverseImportCount(index, @intCast(file_idx));
        try out.append(.{
            .branch_id = @intCast(out.items.len + 1),
            .score = if (exact) @as(u32, 280) else @as(u32, 220) + @min(evidence_count * 8, @as(u32, 60)),
            .evidence_count = evidence_count,
            .target_kind = .file,
            .file_index = @intCast(file_idx),
        });
    }
}

fn collectDeclCandidates(index: *const RepoIndex, raw_target: []const u8, out: *std.ArrayList(ResolutionCandidate)) !void {
    for (index.declarations.items, 0..) |decl, decl_idx| {
        const exact_name = std.mem.eql(u8, decl.name, raw_target);
        const leaf_name = std.mem.eql(u8, nativeLeafName(decl.name), raw_target) or std.mem.eql(u8, symbolicLeafName(decl.name), raw_target);
        if (!exact_name and !leaf_name) continue;
        try out.append(.{
            .branch_id = @intCast(out.items.len + 1),
            .score = (if (exact_name) @as(u32, 240) else @as(u32, 180)) + declarationBonus(index, @intCast(decl_idx)),
            .evidence_count = declarationEvidenceCount(index, @intCast(decl_idx)),
            .target_kind = .declaration,
            .file_index = decl.file_index,
            .decl_index = @intCast(decl_idx),
        });
    }
}

fn declarationBonus(index: *const RepoIndex, decl_index: u32) u32 {
    const decl = index.declarations.items[decl_index];
    var bonus: u32 = if (decl.is_pub) 40 else 10;
    bonus += switch (decl.role) {
        .definition => 18,
        .declaration_and_definition => 12,
        .declaration => 4,
    };
    bonus += switch (decl.kind) {
        .function => 18,
        .module => 16,
        .type => 20,
        .constant => 8,
        .variable => 4,
        .symbolic_unit => 10,
    };
    bonus += @min(declarationEvidenceCount(index, decl_index) * 10, @as(u32, 140));
    bonus += @min(declarationOutgoingEdgeCount(index, decl_index) * 4, @as(u32, 36));
    return bonus;
}

fn declarationEvidenceCount(index: *const RepoIndex, decl_index: u32) u32 {
    var count: u32 = 0;
    for (index.semantic_edges.items) |edge| {
        if (edge.target_decl_index != decl_index) continue;
        count += semanticEdgeWeight(edge.kind);
    }
    if (count > 0) return count;

    const decl = index.declarations.items[decl_index];
    for (index.references.items) |reference| {
        if (!std.mem.eql(u8, reference.name, decl.name)) continue;
        if (reference.file_index == decl.file_index and reference.line == decl.line) continue;
        count += 1;
    }
    return count;
}

fn declarationOutgoingEdgeCount(index: *const RepoIndex, decl_index: u32) u32 {
    var count: u32 = 0;
    for (index.semantic_edges.items) |edge| {
        if (edge.owner_decl_index != decl_index) continue;
        count += semanticEdgeWeight(edge.kind);
    }
    return count;
}

fn reverseImportCount(index: *const RepoIndex, file_index: u32) u32 {
    var count: u32 = 0;
    for (index.files.items) |file| {
        for (file.imports.items) |edge| {
            if (edge.file_index == file_index) count += 1;
        }
    }
    return count;
}

fn collectDirectDependents(index: *const RepoIndex, target: ResolvedTarget, out: *std.ArrayList(EvidenceSeed)) !void {
    switch (target.target_kind) {
        .file => try collectReverseImportSurface(index, target.file_index, 1, out),
        .declaration => try collectReverseSemanticSurface(index, target.decl_index.?, 1, out),
    }
}

fn collectReverseSemanticSurface(index: *const RepoIndex, root_decl_index: u32, max_hops: u32, out: *std.ArrayList(EvidenceSeed)) !void {
    var frontier = std.ArrayList(u32).init(out.allocator);
    defer frontier.deinit();
    try frontier.append(root_decl_index);

    var visited = std.AutoHashMap(u32, void).init(out.allocator);
    defer visited.deinit();
    try visited.put(root_decl_index, {});

    var hop: u32 = 0;
    while (hop < max_hops and frontier.items.len > 0) : (hop += 1) {
        var next = std.ArrayList(u32).init(out.allocator);
        defer next.deinit();

        for (frontier.items) |current_decl| {
            for (index.semantic_edges.items) |edge| {
                if (edge.target_decl_index != current_decl) continue;
                const line = edge.line;
                try appendEvidenceUnique(out, .{
                    .file_index = edge.source_file_index,
                    .line = line,
                    .reason = semanticEvidenceReason(edge.kind, hop),
                });
                if (edge.owner_decl_index) |owner_decl_index| {
                    if (!visited.contains(owner_decl_index)) {
                        try visited.put(owner_decl_index, {});
                        try next.append(owner_decl_index);
                    }
                }
            }
        }

        frontier.clearRetainingCapacity();
        try frontier.appendSlice(next.items);
    }
}

fn semanticEdgeWeight(kind: SemanticEdgeKind) u32 {
    return switch (kind) {
        .call => 3,
        .signature_type => 2,
        .annotation_type => 2,
        .symbol_ref => 1,
        .declaration_pair => 1,
        .structural_hint => 1,
    };
}

fn semanticEvidenceReason(kind: SemanticEdgeKind, hop: u32) []const u8 {
    return switch (kind) {
        .call => if (hop == 0) "calls_subject" else "calls_transitive_dependency",
        .signature_type => if (hop == 0) "signature_depends_on_subject" else "signature_depends_on_transitive_dependency",
        .annotation_type => if (hop == 0) "type_annotation_depends_on_subject" else "type_annotation_depends_on_transitive_dependency",
        .symbol_ref => if (hop == 0) "references_subject_symbol" else "references_transitive_dependency",
        .declaration_pair => if (hop == 0) "paired_declaration_or_definition" else "paired_transitive_declaration",
        .structural_hint => if (hop == 0) "structurally_relates_to_subject" else "structurally_relates_to_transitive_dependency",
    };
}

fn collectReverseImportSurface(index: *const RepoIndex, root_file_index: u32, max_hops: u32, out: *std.ArrayList(EvidenceSeed)) !void {
    var frontier = std.ArrayList(u32).init(out.allocator);
    defer frontier.deinit();
    try frontier.append(root_file_index);

    var visited = std.AutoHashMap(u32, void).init(out.allocator);
    defer visited.deinit();
    try visited.put(root_file_index, {});

    var hop: u32 = 0;
    while (hop < max_hops and frontier.items.len > 0) : (hop += 1) {
        var next = std.ArrayList(u32).init(out.allocator);
        defer next.deinit();

        for (frontier.items) |current_file| {
            for (index.files.items, 0..) |file, importer_idx| {
                for (file.imports.items) |edge| {
                    if (edge.file_index != current_file) continue;
                    try appendEvidenceUnique(out, .{
                        .file_index = @intCast(importer_idx),
                        .line = if (edge.line == 0) 1 else edge.line,
                        .reason = dependencyEvidenceReason(edge.kind, hop),
                    });
                    if (!visited.contains(@intCast(importer_idx))) {
                        try visited.put(@intCast(importer_idx), {});
                        try next.append(@intCast(importer_idx));
                    }
                }
            }
        }

        frontier.clearRetainingCapacity();
        try frontier.appendSlice(next.items);
    }
}

fn dependencyEvidenceReason(kind: DependencyKind, hop: u32) []const u8 {
    return switch (kind) {
        .import => if (hop == 0) "imports_subject_file" else "transitive_import",
        .include => if (hop == 0) "includes_subject_file" else "transitive_include",
        .companion => if (hop == 0) "paired_source_or_header" else "transitive_source_or_header",
    };
}

fn collectOverlapSeeds(
    allocator: std.mem.Allocator,
    left_file_index: u32,
    left: []const EvidenceSeed,
    right_file_index: u32,
    right: []const EvidenceSeed,
) ![]EvidenceSeed {
    var out = std.ArrayList(EvidenceSeed).init(allocator);
    errdefer out.deinit();

    if (left_file_index == right_file_index) {
        try out.append(.{
            .file_index = left_file_index,
            .line = 1,
            .reason = "same_subject_file",
        });
    }

    for (left) |lhs| {
        if (lhs.file_index == right_file_index) {
            try appendEvidenceUnique(&out, .{
                .file_index = lhs.file_index,
                .line = lhs.line,
                .reason = "left_depends_on_right_surface",
            });
        }
        for (right) |rhs| {
            if (lhs.file_index != rhs.file_index) continue;
            try appendEvidenceUnique(&out, .{
                .file_index = lhs.file_index,
                .line = @min(lhs.line, rhs.line),
                .reason = "shared_change_front",
            });
        }
    }
    for (right) |rhs| {
        if (rhs.file_index == left_file_index) {
            try appendEvidenceUnique(&out, .{
                .file_index = rhs.file_index,
                .line = rhs.line,
                .reason = "right_depends_on_left_surface",
            });
        }
    }

    return out.toOwnedSlice();
}

fn collectTargetInvariants(
    allocator: std.mem.Allocator,
    index: *const RepoIndex,
    target: ResolvedTarget,
) ![]Invariant {
    var out = std.ArrayList(Invariant).init(allocator);
    errdefer out.deinit();

    if (target.target_kind == .declaration) {
        const subject_decl = index.declarations.items[target.decl_index.?];
        for (index.semantic_edges.items) |edge| {
            if (edge.target_decl_index != target.decl_index.?) continue;
            const invariant_kind = invariantKindForSemanticEdge(subject_decl.kind, edge.kind) orelse continue;
            try appendInvariantUnique(&out, .{
                .kind = invariant_kind,
                .owner_decl_index = edge.owner_decl_index,
                .owner_file_index = edge.source_file_index,
                .line = edge.line,
                .requires_dependency_edge = edge.kind != .declaration_pair and
                    edge.source_file_index != target.file_index and
                    dependencyDistance(index, edge.source_file_index, target.file_index) >= 3,
                .weight = invariantWeight(invariant_kind, edge.kind),
            });
            if (out.items.len >= MAX_TARGET_INVARIANTS) break;
        }
    }

    if (out.items.len < MAX_TARGET_INVARIANTS) {
        outer: for (index.files.items, 0..) |file, importer_idx| {
            for (file.imports.items) |edge| {
                if (edge.file_index != target.file_index) continue;
                try appendInvariantUnique(&out, .{
                    .kind = .dependency_edge,
                    .owner_decl_index = null,
                    .owner_file_index = @intCast(importer_idx),
                    .line = if (edge.line == 0) 1 else edge.line,
                    .requires_dependency_edge = false,
                    .weight = 24,
                });
                if (out.items.len >= MAX_TARGET_INVARIANTS) break :outer;
            }
        }
    }

    return out.toOwnedSlice();
}

fn appendInvariantUnique(out: *std.ArrayList(Invariant), item: Invariant) !void {
    for (out.items) |existing| {
        if (existing.kind == item.kind and
            existing.owner_decl_index == item.owner_decl_index and
            existing.owner_file_index == item.owner_file_index and
            existing.line == item.line and
            existing.requires_dependency_edge == item.requires_dependency_edge)
        {
            return;
        }
    }
    try out.append(item);
}

fn invariantKindForSemanticEdge(subject_decl_kind: DeclKind, edge_kind: SemanticEdgeKind) ?InvariantKind {
    return switch (edge_kind) {
        .call => .call_site,
        .signature_type, .annotation_type => .signature_contract,
        .declaration_pair => .declaration_pair,
        .structural_hint => .structural_relation,
        .symbol_ref => switch (subject_decl_kind) {
            .variable, .constant, .type => .ownership_state,
            .symbolic_unit => .structural_relation,
            else => .call_site,
        },
    };
}

fn invariantWeight(kind: InvariantKind, edge_kind: SemanticEdgeKind) u32 {
    const base: u32 = switch (kind) {
        .call_site => 84,
        .signature_contract => 92,
        .dependency_edge => 24,
        .ownership_state => 74,
        .declaration_pair => 82,
        .structural_relation => 42,
    };
    return base + semanticEdgeWeight(edge_kind) * 12;
}

fn collectSingleTargetContradictions(
    allocator: std.mem.Allocator,
    invariants: []const Invariant,
) ![]ContradictionSeed {
    var out = std.ArrayList(ContradictionSeed).init(allocator);
    errdefer out.deinit();

    for (invariants) |invariant| {
        if (invariant.kind == .dependency_edge) continue;
        try appendContradictionSeedUnique(&out, .{
            .category = contradictionCategoryForInvariant(invariant),
            .file_index = invariant.owner_file_index,
            .line = invariant.line,
            .reason = contradictionReasonForInvariant(invariant),
            .owner_decl_index = invariant.owner_decl_index,
            .weight = contradictionSeedWeight(invariant.weight, contradictionCategoryForInvariant(invariant)),
        });
    }

    return out.toOwnedSlice();
}

fn collectPairContradictions(
    allocator: std.mem.Allocator,
    index: *const RepoIndex,
    left: ResolvedTarget,
    right: ResolvedTarget,
    left_invariants: []const Invariant,
    right_invariants: []const Invariant,
) ![]ContradictionSeed {
    var out = std.ArrayList(ContradictionSeed).init(allocator);
    errdefer out.deinit();

    if (targetsShareSameSurface(left, right)) {
        try appendContradictionSeedUnique(&out, .{
            .category = .same_target_surface,
            .file_index = left.file_index,
            .line = subjectLine(index, left),
            .reason = "targets resolve to the same bounded subject surface",
            .weight = 420,
        });
    }

    if (left.target_kind != .declaration or right.target_kind != .declaration) return out.toOwnedSlice();

    const left_decl_index = left.decl_index.?;
    const right_decl_index = right.decl_index.?;

    for (left_invariants) |invariant| {
        if (invariant.owner_decl_index != null and invariant.owner_decl_index.? == right_decl_index) {
            const category = contradictionCategoryForInvariantPair(index, left, right, invariant, null);
            try appendContradictionSeedUnique(&out, .{
                .category = category,
                .file_index = invariant.owner_file_index,
                .line = invariant.line,
                .reason = pairContradictionReason(category, invariant, null),
                .owner_decl_index = invariant.owner_decl_index,
                .weight = contradictionSeedWeight(invariant.weight + 26, category),
            });
        }
    }
    for (right_invariants) |invariant| {
        if (invariant.owner_decl_index != null and invariant.owner_decl_index.? == left_decl_index) {
            const category = contradictionCategoryForInvariantPair(index, left, right, invariant, null);
            try appendContradictionSeedUnique(&out, .{
                .category = category,
                .file_index = invariant.owner_file_index,
                .line = invariant.line,
                .reason = pairContradictionReason(category, invariant, null),
                .owner_decl_index = invariant.owner_decl_index,
                .weight = contradictionSeedWeight(invariant.weight + 26, category),
            });
        }
    }

    var pair_checks: usize = 0;
    outer: for (left_invariants) |lhs| {
        if (lhs.owner_decl_index == null) continue;
        for (right_invariants) |rhs| {
            pair_checks += 1;
            if (pair_checks > MAX_PAIR_CONTRADICTION_CHECKS) break :outer;
            if (rhs.owner_decl_index == null) continue;
            if (lhs.owner_decl_index.? != rhs.owner_decl_index.?) continue;
            const category = contradictionCategoryForInvariantPair(index, left, right, lhs, rhs);
            try appendContradictionSeedUnique(&out, .{
                .category = category,
                .file_index = lhs.owner_file_index,
                .line = @min(lhs.line, rhs.line),
                .reason = pairContradictionReason(category, lhs, rhs),
                .owner_decl_index = lhs.owner_decl_index,
                .weight = contradictionSeedWeight(lhs.weight + rhs.weight + 32, category),
            });
        }
    }

    return out.toOwnedSlice();
}

fn appendContradictionSeedUnique(out: *std.ArrayList(ContradictionSeed), item: ContradictionSeed) !void {
    for (out.items) |existing| {
        if (existing.category == item.category and
            existing.file_index == item.file_index and
            existing.line == item.line and
            existing.owner_decl_index == item.owner_decl_index and
            std.mem.eql(u8, existing.reason, item.reason))
        {
            return;
        }
    }
    try out.append(item);
}

fn contradictionCategoryForInvariant(invariant: Invariant) ContradictionCategory {
    if (invariant.requires_dependency_edge) return .missing_dependency_edge;
    return switch (invariant.kind) {
        .call_site => .incompatible_call_site_expectation,
        .signature_contract => .signature_incompatibility,
        .dependency_edge => .missing_dependency_edge,
        .ownership_state => .ownership_state_assumption,
        .declaration_pair => .declaration_pair_incompatibility,
        .structural_relation => .structural_relation_assumption,
    };
}

fn contradictionCategoryForInvariantPair(
    index: *const RepoIndex,
    left: ResolvedTarget,
    right: ResolvedTarget,
    lhs: Invariant,
    rhs: ?Invariant,
) ContradictionCategory {
    if (lhs.requires_dependency_edge or (rhs != null and rhs.?.requires_dependency_edge)) return .missing_dependency_edge;
    if (lhs.kind == .declaration_pair or (rhs != null and rhs.?.kind == .declaration_pair)) return .declaration_pair_incompatibility;
    if (lhs.kind == .structural_relation or (rhs != null and rhs.?.kind == .structural_relation)) return .structural_relation_assumption;

    const left_decl_kind = resolvedDeclKind(index, left);
    const right_decl_kind = resolvedDeclKind(index, right);
    if (lhs.kind == .ownership_state or
        (rhs != null and rhs.?.kind == .ownership_state) or
        (left_decl_kind != null and (left_decl_kind.? == .variable or left_decl_kind.? == .constant)) or
        (right_decl_kind != null and (right_decl_kind.? == .variable or right_decl_kind.? == .constant)))
    {
        return .ownership_state_assumption;
    }
    if (lhs.kind == .signature_contract or (rhs != null and rhs.?.kind == .signature_contract)) return .signature_incompatibility;
    return .incompatible_call_site_expectation;
}

fn contradictionReasonForInvariant(invariant: Invariant) []const u8 {
    if (invariant.requires_dependency_edge) {
        return switch (invariant.kind) {
            .call_site => "call-site expectation crosses files without a bounded dependency edge",
            .signature_contract => "signature assumption crosses files without a bounded dependency edge",
            .dependency_edge => "dependent file is missing a bounded dependency edge",
            .ownership_state => "state owner assumption crosses files without a bounded dependency edge",
            .declaration_pair => "paired declaration/definition crosses files without a bounded dependency edge",
            .structural_relation => "symbolic structural relation crosses files without a bounded dependency edge",
        };
    }

    return switch (invariant.kind) {
        .call_site => "call-site expects the subject to remain callable and compatible",
        .signature_contract => "signature or annotation assumes the subject remains compatible",
        .dependency_edge => "dependent file imports or includes the subject file",
        .ownership_state => "owner logic assumes the subject remains the same shared state",
        .declaration_pair => "native declaration and definition are treated as one contract",
        .structural_relation => "bounded symbolic structure depends on the subject through a structural relation hint",
    };
}

fn pairContradictionReason(category: ContradictionCategory, lhs: Invariant, rhs: ?Invariant) []const u8 {
    _ = lhs;
    _ = rhs;
    return switch (category) {
        .same_target_surface => "both targets resolve to the same bounded subject surface",
        .signature_incompatibility => "one bounded owner depends on both targets through a signature or type contract",
        .missing_dependency_edge => "bounded reasoning found a semantic dependency without a matching import/include edge",
        .incompatible_call_site_expectation => "one bounded owner depends on both targets at the call site",
        .ownership_state_assumption => "one bounded owner depends on both targets as shared state or ownership",
        .declaration_pair_incompatibility => "bounded native declaration and definition assumptions connect both targets",
        .structural_relation_assumption => "one bounded symbolic owner depends on both targets through the same structural hint",
    };
}

fn contradictionSeedWeight(weight: u32, category: ContradictionCategory) u32 {
    return weight + switch (category) {
        .same_target_surface => @as(u32, 70),
        .signature_incompatibility => @as(u32, 44),
        .missing_dependency_edge => @as(u32, 60),
        .incompatible_call_site_expectation => @as(u32, 36),
        .ownership_state_assumption => @as(u32, 32),
        .declaration_pair_incompatibility => @as(u32, 40),
        .structural_relation_assumption => @as(u32, 28),
    };
}

fn resolvedDeclKind(index: *const RepoIndex, target: ResolvedTarget) ?DeclKind {
    if (target.target_kind != .declaration) return null;
    return index.declarations.items[target.decl_index.?].kind;
}

fn isSymbolicTarget(index: *const RepoIndex, target: ResolvedTarget) bool {
    if (target.target_kind == .declaration) {
        return index.declarations.items[target.decl_index.?].kind == .symbolic_unit;
    }
    return isSymbolicExtension(index.files.items[target.file_index].rel_path);
}

fn shouldLeaveSymbolicTargetUnresolved(
    index: *const RepoIndex,
    target: ResolvedTarget,
    direct_refs: []const EvidenceSeed,
    dependency_surface: []const EvidenceSeed,
    import_surface: []const EvidenceSeed,
    contradiction_seeds: []const ContradictionSeed,
    abstraction_refs: []const abstractions.SupportReference,
) bool {
    if (!isSymbolicTarget(index, target)) return false;
    return direct_refs.len == 0 and
        dependency_surface.len == 0 and
        import_surface.len == 0 and
        contradiction_seeds.len == 0 and
        abstractions.countUsableReferences(abstraction_refs) == 0;
}

fn subjectLine(index: *const RepoIndex, target: ResolvedTarget) u32 {
    return switch (target.target_kind) {
        .file => 1,
        .declaration => index.declarations.items[target.decl_index.?].line,
    };
}

fn targetsShareSameSurface(left: ResolvedTarget, right: ResolvedTarget) bool {
    if (left.target_kind == .declaration and right.target_kind == .declaration) {
        return left.decl_index.? == right.decl_index.?;
    }
    if (left.file_index != right.file_index) return false;
    return left.target_kind == .file or right.target_kind == .file;
}

fn buildContradictionHypotheses(
    allocator: std.mem.Allocator,
    seeds: []const ContradictionSeed,
    traces: *std.ArrayList(CandidateTrace),
    branch_ids: *std.ArrayList(u32),
    scores: *std.ArrayList(u32),
) !void {
    const categories = [_]ContradictionCategory{
        .same_target_surface,
        .signature_incompatibility,
        .missing_dependency_edge,
        .incompatible_call_site_expectation,
        .ownership_state_assumption,
        .declaration_pair_incompatibility,
        .structural_relation_assumption,
    };
    for (categories, 0..) |category, idx| {
        const evidence_count = contradictionEvidenceCount(seeds, category);
        if (evidence_count == 0) continue;
        const score = contradictionCategoryBaseScore(category) +
            @min(contradictionWeightSum(seeds, category), @as(u32, 180)) +
            @min(evidence_count * 18, @as(u32, 90));
        try appendHypothesis(allocator, traces, branch_ids, scores, .{
            .branch_id = @intCast(idx + 1),
            .label = contradictionCategoryName(category),
            .score = score,
            .evidence_count = evidence_count,
        });
    }
}

fn contradictionEvidenceCount(seeds: []const ContradictionSeed, category: ContradictionCategory) u32 {
    var count: u32 = 0;
    for (seeds) |seed| {
        if (seed.category == category) count += 1;
    }
    return count;
}

fn contradictionWeightSum(seeds: []const ContradictionSeed, category: ContradictionCategory) u32 {
    var total: u32 = 0;
    for (seeds) |seed| {
        if (seed.category == category) total += seed.weight;
    }
    return total;
}

fn contradictionCategoryBaseScore(category: ContradictionCategory) u32 {
    return switch (category) {
        .same_target_surface => 360,
        .signature_incompatibility => 310,
        .missing_dependency_edge => 340,
        .incompatible_call_site_expectation => 300,
        .ownership_state_assumption => 280,
        .declaration_pair_incompatibility => 295,
        .structural_relation_assumption => 250,
    };
}

fn contradictionCategoryName(category: ContradictionCategory) []const u8 {
    return switch (category) {
        .same_target_surface => "same_target_surface",
        .signature_incompatibility => "signature_incompatibility",
        .missing_dependency_edge => "missing_dependency_edge",
        .incompatible_call_site_expectation => "incompatible_call_site_expectation",
        .ownership_state_assumption => "ownership_state_assumption",
        .declaration_pair_incompatibility => "declaration_pair_incompatibility",
        .structural_relation_assumption => "structural_relation_assumption",
    };
}

fn contradictionCategoryFromBranchId(branch_id: u32) ContradictionCategory {
    return switch (branch_id) {
        1 => .same_target_surface,
        2 => .signature_incompatibility,
        3 => .missing_dependency_edge,
        4 => .incompatible_call_site_expectation,
        5 => .ownership_state_assumption,
        6 => .declaration_pair_incompatibility,
        7 => .structural_relation_assumption,
        else => .incompatible_call_site_expectation,
    };
}

fn buildEvidenceFromContradictions(
    allocator: std.mem.Allocator,
    index: *const RepoIndex,
    seeds: []const ContradictionSeed,
    category: ContradictionCategory,
    max_items: usize,
) ![]Evidence {
    var evidence_seeds = std.ArrayList(EvidenceSeed).init(allocator);
    defer evidence_seeds.deinit();
    try appendContradictionEvidenceSeeds(&evidence_seeds, seeds, category);
    return buildEvidence(allocator, index, evidence_seeds.items, max_items);
}

fn buildRefactorPathFromContradictions(
    allocator: std.mem.Allocator,
    index: *const RepoIndex,
    target: ResolvedTarget,
    seeds: []const ContradictionSeed,
    category: ContradictionCategory,
    max_items: usize,
) ![]Evidence {
    var evidence_seeds = std.ArrayList(EvidenceSeed).init(allocator);
    defer evidence_seeds.deinit();
    try appendContradictionEvidenceSeeds(&evidence_seeds, seeds, category);
    return buildRefactorPath(allocator, index, target, evidence_seeds.items, max_items);
}

fn collectSubsystemsFromContradictions(
    allocator: std.mem.Allocator,
    index: *const RepoIndex,
    seeds: []const ContradictionSeed,
    category: ContradictionCategory,
) ![]Subsystem {
    var evidence_seeds = std.ArrayList(EvidenceSeed).init(allocator);
    defer evidence_seeds.deinit();
    try appendContradictionEvidenceSeeds(&evidence_seeds, seeds, category);
    return collectSubsystems(allocator, index, evidence_seeds.items);
}

fn appendContradictionEvidenceSeeds(
    out: *std.ArrayList(EvidenceSeed),
    seeds: []const ContradictionSeed,
    category: ContradictionCategory,
) !void {
    for (seeds) |seed| {
        if (seed.category != category) continue;
        try appendEvidenceUnique(out, .{
            .file_index = seed.file_index,
            .line = seed.line,
            .reason = seed.reason,
        });
    }
}

fn buildContradictionTraces(
    allocator: std.mem.Allocator,
    index: *const RepoIndex,
    seeds: []const ContradictionSeed,
    max_items: usize,
) ![]ContradictionTrace {
    var sorted = std.ArrayList(ContradictionSeed).init(allocator);
    defer sorted.deinit();
    try sorted.appendSlice(seeds);
    std.sort.heap(ContradictionSeed, sorted.items, index, lessThanContradictionSeed);

    const limit = @min(max_items, sorted.items.len);
    const out = try allocator.alloc(ContradictionTrace, limit);
    for (sorted.items[0..limit], 0..) |seed, idx| {
        const file = index.files.items[seed.file_index];
        out[idx] = .{
            .category = contradictionCategoryName(seed.category),
            .rel_path = try allocator.dupe(u8, file.rel_path),
            .line = seed.line,
            .reason = seed.reason,
            .subsystem = subsystemName(file.subsystem),
            .owner = if (seed.owner_decl_index) |owner_decl_index|
                try allocator.dupe(u8, index.declarations.items[owner_decl_index].name)
            else
                null,
        };
    }
    return out;
}

fn buildEvidence(allocator: std.mem.Allocator, index: *const RepoIndex, seeds: []const EvidenceSeed, max_items: usize) ![]Evidence {
    var sorted = std.ArrayList(EvidenceSeed).init(allocator);
    defer sorted.deinit();
    try sorted.appendSlice(seeds);
    std.sort.heap(EvidenceSeed, sorted.items, index, lessThanEvidenceSeed);

    const limit = @min(max_items, sorted.items.len);
    const out = try allocator.alloc(Evidence, limit);
    for (sorted.items[0..limit], 0..) |seed, idx| {
        const file = index.files.items[seed.file_index];
        out[idx] = .{
            .rel_path = try allocator.dupe(u8, file.rel_path),
            .line = seed.line,
            .reason = seed.reason,
            .subsystem = subsystemName(file.subsystem),
        };
    }
    return out;
}

fn buildRefactorPath(
    allocator: std.mem.Allocator,
    index: *const RepoIndex,
    target: ResolvedTarget,
    seeds: []const EvidenceSeed,
    max_items: usize,
) ![]Evidence {
    const extra = @min(max_items, seeds.len);
    const out = try allocator.alloc(Evidence, 1 + extra);
    const file = index.files.items[target.file_index];
    const line = switch (target.target_kind) {
        .file => 1,
        .declaration => index.declarations.items[target.decl_index.?].line,
    };
    out[0] = .{
        .rel_path = try allocator.dupe(u8, file.rel_path),
        .line = line,
        .reason = "subject",
        .subsystem = subsystemName(file.subsystem),
    };
    const evidence = try buildEvidence(allocator, index, seeds, max_items);
    defer {
        for (evidence) |item| allocator.free(item.rel_path);
        allocator.free(evidence);
    }
    for (evidence, 0..) |item, idx| {
        out[idx + 1] = .{
            .rel_path = try allocator.dupe(u8, item.rel_path),
            .line = item.line,
            .reason = item.reason,
            .subsystem = item.subsystem,
        };
    }
    return out;
}

fn collectSubsystems(allocator: std.mem.Allocator, index: *const RepoIndex, seeds: []const EvidenceSeed) ![]Subsystem {
    var flags = std.EnumSet(Subsystem).initEmpty();
    for (seeds) |seed| {
        flags.insert(index.files.items[seed.file_index].subsystem);
    }
    var out = std.ArrayList(Subsystem).init(allocator);
    errdefer out.deinit();
    var it = flags.iterator();
    while (it.next()) |value| try out.append(value);
    return out.toOwnedSlice();
}

fn initResult(allocator: std.mem.Allocator, options: Options) !Result {
    return .{
        .allocator = allocator,
        .status = .unresolved,
        .query_kind = options.query_kind,
        .query_target = try allocator.dupe(u8, options.target),
        .query_other_target = if (options.other_target) |other| try allocator.dupe(u8, other) else null,
        .repo_root = "",
        .shard_root = "",
        .shard_id = "",
        .shard_kind = .core,
        .reasoning_mode = options.reasoning_mode,
        .support_graph = .{ .allocator = allocator },
    };
}

fn makeSubject(allocator: std.mem.Allocator, index: *const RepoIndex, target: ResolvedTarget) !Subject {
    const file = index.files.items[target.file_index];
    return switch (target.target_kind) {
        .file => .{
            .name = try allocator.dupe(u8, std.fs.path.basename(file.rel_path)),
            .rel_path = try allocator.dupe(u8, file.rel_path),
            .line = 1,
            .kind_name = "file",
            .subsystem = subsystemName(file.subsystem),
        },
        .declaration => blk: {
            const decl = index.declarations.items[target.decl_index.?];
            break :blk .{
                .name = try allocator.dupe(u8, decl.name),
                .rel_path = try allocator.dupe(u8, file.rel_path),
                .line = decl.line,
                .kind_name = declKindName(decl.kind),
                .subsystem = subsystemName(file.subsystem),
            };
        },
    };
}

fn resolveSelectedShardPaths(allocator: std.mem.Allocator, project_shard: ?[]const u8) !shards.Paths {
    var metadata = if (project_shard) |value|
        try shards.resolveProjectMetadata(allocator, value)
    else
        try shards.resolveCoreMetadata(allocator);
    defer metadata.deinit();
    return shards.resolvePaths(allocator, metadata.metadata);
}

fn loadRepoIndex(allocator: std.mem.Allocator, repo_root: []const u8, shard_paths: *const shards.Paths, cache_persist: bool) !IndexLoadResult {
    var scan_entries = try scanRepoFiles(allocator, repo_root);
    defer {
        for (scan_entries.items) |*entry| entry.deinit(allocator);
        scan_entries.deinit();
    }

    if (!cache_persist) {
        var cache = try buildCacheFromScan(allocator, repo_root, scan_entries.items);
        defer cache.deinit();
        return .{
            .index = try RepoIndex.fromCache(allocator, repo_root, cache.files.items),
            .lifecycle = .cold_build,
            .changed_files = @intCast(cache.files.items.len),
        };
    }

    const cache_index_path = try std.fs.path.join(allocator, &.{ shard_paths.code_intel_cache_abs_path, CACHE_INDEX_FILE_NAME });
    defer allocator.free(cache_index_path);

    var loaded_cache = loadPersistedCache(allocator, cache_index_path) catch null;
    if (loaded_cache) |*cache| {
        if (!std.mem.eql(u8, cache.repo_root, repo_root)) {
            cache.deinit();
            loaded_cache = null;
        }
    }
    const had_loaded_cache = loaded_cache != null;

    var cache = if (loaded_cache) |cache|
        cache
    else
        try PersistedCache.init(allocator, repo_root);
    defer cache.deinit();

    const refresh = try refreshPersistedCache(allocator, &cache, scan_entries.items);
    const lifecycle: CacheLifecycle = if (!had_loaded_cache)
        .cold_build
    else if (refresh.changed_files == 0)
        .warm_load
    else
        .warm_refresh;

    if (!had_loaded_cache or refresh.changed_files > 0) {
        try sys.makePath(allocator, shard_paths.code_intel_cache_abs_path);
        try persistCache(allocator, cache_index_path, &cache);
    }

    return .{
        .index = try RepoIndex.fromCache(allocator, repo_root, cache.files.items),
        .lifecycle = lifecycle,
        .changed_files = refresh.changed_files,
    };
}

const RefreshSummary = struct {
    changed_files: u32,
};

const ZigTokenTag = enum {
    identifier,
    builtin,
    string_lit,
    l_paren,
    r_paren,
    l_brace,
    r_brace,
    l_bracket,
    r_bracket,
    comma,
    colon,
    semicolon,
    dot,
    eq,
    bang,
    question,
    star,
    other,
};

const ZigToken = struct {
    tag: ZigTokenTag,
    text: []const u8,
    line: u32,
};

const NativeTokenTag = enum {
    identifier,
    string_lit,
    char_lit,
    l_paren,
    r_paren,
    l_brace,
    r_brace,
    l_bracket,
    r_bracket,
    comma,
    colon,
    semicolon,
    dot,
    coloncolon,
    arrow,
    eq,
    hash,
    tilde,
    other,
};

const NativeToken = struct {
    tag: NativeTokenTag,
    text: []const u8,
    line: u32,
};

const NativeBoundaryKind = enum {
    semicolon,
    body,
};

const NativeDeclBoundary = struct {
    kind: NativeBoundaryKind,
    index: usize,
};

const AliasTargetKind = enum {
    module,
    symbol,
};

const AliasTarget = struct {
    kind: AliasTargetKind,
    rel_path: []const u8,
    symbol_name: ?[]const u8 = null,
};

fn buildCacheFromScan(allocator: std.mem.Allocator, repo_root: []const u8, scan_entries: []const RepoScanEntry) !PersistedCache {
    var cache = try PersistedCache.init(allocator, repo_root);
    errdefer cache.deinit();
    for (scan_entries) |entry| {
        try cache.files.append(try parseCachedFileRecord(allocator, repo_root, scan_entries, entry));
    }
    return cache;
}

fn refreshPersistedCache(allocator: std.mem.Allocator, cache: *PersistedCache, scan_entries: []const RepoScanEntry) !RefreshSummary {
    var refreshed = try PersistedCache.init(allocator, cache.repo_root);
    errdefer refreshed.deinit();

    var changed_files: u32 = 0;
    var scan_index: usize = 0;
    var cache_index: usize = 0;

    while (scan_index < scan_entries.len or cache_index < cache.files.items.len) {
        if (scan_index >= scan_entries.len) {
            changed_files += 1;
            cache_index += 1;
            continue;
        }
        if (cache_index >= cache.files.items.len) {
            try refreshed.files.append(try parseCachedFileRecord(allocator, cache.repo_root, scan_entries, scan_entries[scan_index]));
            changed_files += 1;
            scan_index += 1;
            continue;
        }

        const scan_entry = scan_entries[scan_index];
        const cached_file = &cache.files.items[cache_index];
        switch (std.mem.order(u8, scan_entry.rel_path, cached_file.rel_path)) {
            .lt => {
                try refreshed.files.append(try parseCachedFileRecord(allocator, cache.repo_root, scan_entries, scan_entry));
                changed_files += 1;
                scan_index += 1;
            },
            .gt => {
                changed_files += 1;
                cache_index += 1;
            },
            .eq => {
                if (scan_entry.size_bytes == cached_file.size_bytes and scan_entry.mtime_ns == cached_file.mtime_ns) {
                    try refreshed.files.append(try cached_file.clone(allocator));
                } else {
                    try refreshed.files.append(try parseCachedFileRecord(allocator, cache.repo_root, scan_entries, scan_entry));
                    changed_files += 1;
                }
                scan_index += 1;
                cache_index += 1;
            },
        }
    }

    cache.deinit();
    cache.* = refreshed;
    return .{ .changed_files = changed_files };
}

fn parseCachedFileRecord(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    scan_entries: []const RepoScanEntry,
    entry: RepoScanEntry,
) !CachedFileRecord {
    if (isNativeExtension(entry.rel_path)) {
        return parseNativeCachedFileRecord(allocator, repo_root, scan_entries, entry);
    }
    if (isSymbolicExtension(entry.rel_path)) {
        return parseSymbolicCachedFileRecord(allocator, entry);
    }
    return parseZigCachedFileRecord(allocator, entry);
}

fn parseZigCachedFileRecord(allocator: std.mem.Allocator, entry: RepoScanEntry) !CachedFileRecord {
    const file = try std.fs.openFileAbsolute(entry.abs_path, .{});
    defer file.close();

    const source = try file.readToEndAlloc(allocator, MAX_INDEXED_FILE_BYTES);
    defer allocator.free(source);

    var tokens = try tokenizeZigSource(allocator, source);
    defer tokens.deinit();

    var record = CachedFileRecord.init(
        allocator,
        try allocator.dupe(u8, entry.rel_path),
        classifySubsystem(entry.rel_path),
        entry.size_bytes,
        entry.mtime_ns,
    );
    errdefer record.deinit();
    record.content_hash = std.hash.Fnv1a_64.hash(source);

    for (tokens.items) |token| {
        if (token.tag != .identifier) continue;
        if (isIgnoredIdentifier(token.text)) continue;
        try record.references.append(.{
            .name = try allocator.dupe(u8, token.text),
            .line = token.line,
        });
    }

    var top_module_aliases = std.StringHashMap(AliasTarget).init(allocator);
    defer top_module_aliases.deinit();
    var top_symbol_aliases = std.StringHashMap(AliasTarget).init(allocator);
    defer top_symbol_aliases.deinit();

    var i: usize = 0;
    while (i < tokens.items.len) {
        var start = i;
        var is_pub = false;
        if (tokens.items[start].tag == .identifier and std.mem.eql(u8, tokens.items[start].text, "pub")) {
            is_pub = true;
            start += 1;
            if (start >= tokens.items.len) break;
        }

        const token = tokens.items[start];
        if (token.tag == .identifier and (std.mem.eql(u8, token.text, "const") or std.mem.eql(u8, token.text, "var"))) {
            const end = findStatementEnd(tokens.items, start) orelse break;
            try parseTopLevelBinding(
                &record,
                tokens.items[start .. end + 1],
                is_pub,
                &top_module_aliases,
                &top_symbol_aliases,
            );
            i = end + 1;
            continue;
        }

        if (token.tag == .identifier and std.mem.eql(u8, token.text, "fn")) {
            const body_end = try parseTopLevelFunction(
                &record,
                tokens.items[start..],
                is_pub,
                &top_module_aliases,
                &top_symbol_aliases,
            );
            i = start + body_end;
            continue;
        }

        i += 1;
    }

    return record;
}

fn parseSymbolicCachedFileRecord(allocator: std.mem.Allocator, entry: RepoScanEntry) !CachedFileRecord {
    // Symbolic ingestion is intentionally shallow: it extracts bounded units
    // from docs, config, markup, and DSL-like files so support-backed queries
    // can ground across code and non-code surfaces without claiming full
    // semantic understanding of those formats.
    const file = try std.fs.openFileAbsolute(entry.abs_path, .{});
    defer file.close();

    const source = try file.readToEndAlloc(allocator, MAX_INDEXED_FILE_BYTES);
    defer allocator.free(source);

    var record = CachedFileRecord.init(
        allocator,
        try allocator.dupe(u8, entry.rel_path),
        classifySubsystem(entry.rel_path),
        entry.size_bytes,
        entry.mtime_ns,
    );
    errdefer record.deinit();
    record.content_hash = std.hash.Fnv1a_64.hash(source);

    switch (classifySymbolicClass(entry.rel_path, source)) {
        .technical_text => try parseTechnicalTextRecord(&record, source),
        .config_like => try parseConfigLikeRecord(&record, source),
        .markup_like => try parseMarkupLikeRecord(&record, source),
        .dsl_like => try parseDslLikeRecord(&record, source),
    }

    return record;
}

fn classifySymbolicClass(path: []const u8, source: []const u8) SymbolicClass {
    if (std.mem.endsWith(u8, path, ".toml") or
        std.mem.endsWith(u8, path, ".yaml") or
        std.mem.endsWith(u8, path, ".yml") or
        std.mem.endsWith(u8, path, ".json") or
        std.mem.endsWith(u8, path, ".ini") or
        std.mem.endsWith(u8, path, ".cfg") or
        std.mem.endsWith(u8, path, ".conf") or
        std.mem.endsWith(u8, path, ".env"))
    {
        return .config_like;
    }
    if (std.mem.endsWith(u8, path, ".html") or std.mem.endsWith(u8, path, ".xml")) return .markup_like;
    if (std.mem.endsWith(u8, path, ".rules") or std.mem.endsWith(u8, path, ".dsl")) return .dsl_like;
    if (std.mem.endsWith(u8, path, ".md")) return .technical_text;
    if (std.mem.indexOfScalar(u8, source, '<') != null and std.mem.indexOfScalar(u8, source, '>') != null) return .markup_like;
    if (std.mem.indexOf(u8, source, "->") != null or std.mem.indexOf(u8, source, "=>") != null or std.mem.indexOf(u8, source, ":=") != null) return .dsl_like;
    if (std.mem.indexOfScalar(u8, source, '=') != null or std.mem.indexOfScalar(u8, source, ':') != null) return .config_like;
    return .technical_text;
}

fn parseTechnicalTextRecord(record: *CachedFileRecord, source: []const u8) !void {
    var paragraph = std.ArrayList(u8).init(record.allocator);
    defer paragraph.deinit();
    var paragraph_start_line: u32 = 0;
    var current_heading: ?[]const u8 = null;

    var lines = std.mem.splitScalar(u8, source, '\n');
    var line_number: u32 = 1;
    while (lines.next()) |raw_line| : (line_number += 1) {
        const line = std.mem.trim(u8, std.mem.trimRight(u8, raw_line, "\r"), " \t");
        if (line.len > MAX_SYMBOLIC_LINE_BYTES) continue;
        if (line.len == 0) {
            try flushTechnicalParagraph(record, &paragraph, paragraph_start_line, current_heading);
            paragraph_start_line = 0;
            continue;
        }
        if (markdownHeadingText(line)) |heading_text| {
            try flushTechnicalParagraph(record, &paragraph, paragraph_start_line, current_heading);
            paragraph_start_line = 0;
            current_heading = try appendSymbolicUnit(record, "heading", heading_text, line_number, true);
            continue;
        }
        if (markdownListItemText(line)) |item_text| {
            try flushTechnicalParagraph(record, &paragraph, paragraph_start_line, current_heading);
            paragraph_start_line = 0;
            if (try appendSymbolicUnit(record, "item", item_text, line_number, true)) |item_name| {
                if (current_heading) |heading_name| try appendCachedSemanticEdge(record, item_name, line_number, heading_name, line_number, .structural_hint);
            }
            continue;
        }

        if (paragraph_start_line == 0) paragraph_start_line = line_number;
        if (paragraph.items.len > 0) try paragraph.append(' ');
        try paragraph.appendSlice(line);
    }

    try flushTechnicalParagraph(record, &paragraph, paragraph_start_line, current_heading);
}

fn flushTechnicalParagraph(
    record: *CachedFileRecord,
    paragraph: *std.ArrayList(u8),
    start_line: u32,
    current_heading: ?[]const u8,
) !void {
    if (paragraph.items.len == 0 or start_line == 0) {
        paragraph.clearRetainingCapacity();
        return;
    }
    if (try appendSymbolicUnit(record, "paragraph", paragraph.items, start_line, true)) |paragraph_name| {
        if (current_heading) |heading_name| try appendCachedSemanticEdge(record, paragraph_name, start_line, heading_name, start_line, .structural_hint);
    }
    paragraph.clearRetainingCapacity();
}

fn parseConfigLikeRecord(record: *CachedFileRecord, source: []const u8) !void {
    var current_section: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, source, '\n');
    var line_number: u32 = 1;
    while (lines.next()) |raw_line| : (line_number += 1) {
        const stripped = trimConfigLine(raw_line);
        if (stripped.len == 0 or stripped.len > MAX_SYMBOLIC_LINE_BYTES) continue;

        if (configSectionName(stripped)) |section_name| {
            current_section = try appendSymbolicNamedUnit(record, "section", section_name, line_number);
            continue;
        }
        if (configKeyValue(stripped)) |kv| {
            var full_name_buf = std.ArrayList(u8).init(record.allocator);
            defer full_name_buf.deinit();
            try full_name_buf.appendSlice("key:");
            if (current_section) |section_name| {
                try full_name_buf.appendSlice(symbolicLeafName(section_name));
                try full_name_buf.append('.');
            }
            try appendSanitizedSymbolicText(&full_name_buf, kv.key, true);
            const key_name = try appendSymbolicExactUnit(record, full_name_buf.items, kv.key, line_number);
            if (key_name) |decl_name| {
                try appendSymbolicReferences(record, kv.value, line_number);
                if (current_section) |section_name| try appendCachedSemanticEdge(record, decl_name, line_number, section_name, line_number, .structural_hint);
            }
            continue;
        }
        if (yamlContainerName(stripped)) |container_name| {
            current_section = try appendSymbolicNamedUnit(record, "section", container_name, line_number);
            continue;
        }
    }
}

fn parseMarkupLikeRecord(record: *CachedFileRecord, source: []const u8) !void {
    var stack = std.ArrayList([]const u8).init(record.allocator);
    defer stack.deinit();

    var i: usize = 0;
    var line_number: u32 = 1;
    while (i < source.len) {
        if (source[i] == '\n') {
            line_number += 1;
            i += 1;
            continue;
        }
        if (source[i] != '<') {
            i += 1;
            continue;
        }
        if (i + 1 < source.len and (source[i + 1] == '/' or source[i + 1] == '!' or source[i + 1] == '?')) {
            if (i + 1 < source.len and source[i + 1] == '/') {
                if (stack.items.len > 0) _ = stack.pop();
            }
            i += 1;
            continue;
        }

        var cursor = i + 1;
        while (cursor < source.len and isMarkupTagChar(source[cursor])) : (cursor += 1) {}
        if (cursor == i + 1) {
            i += 1;
            continue;
        }
        const tag_name = source[i + 1 .. cursor];
        const start_line = line_number;

        var self_closing = false;
        while (cursor < source.len and source[cursor] != '>') : (cursor += 1) {
            if (source[cursor] == '\n') line_number += 1;
            if (source[cursor] == '/' and cursor + 1 < source.len and source[cursor + 1] == '>') self_closing = true;
        }
        if (cursor < source.len and source[cursor] == '>') cursor += 1;

        if (try appendSymbolicUnit(record, "tag", tag_name, start_line, true)) |tag_decl_name| {
            if (stack.items.len > 0) try appendCachedSemanticEdge(record, tag_decl_name, start_line, stack.items[stack.items.len - 1], start_line, .structural_hint);
            if (!self_closing) try stack.append(tag_decl_name);
        }
        i = cursor;
    }
}

fn parseDslLikeRecord(record: *CachedFileRecord, source: []const u8) !void {
    var current_section: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, source, '\n');
    var line_number: u32 = 1;
    while (lines.next()) |raw_line| : (line_number += 1) {
        const line = trimDslLine(raw_line);
        if (line.len == 0 or line.len > MAX_SYMBOLIC_LINE_BYTES) continue;

        if (configSectionName(line)) |section_name| {
            current_section = try appendSymbolicNamedUnit(record, "section", section_name, line_number);
            continue;
        }
        if (dslRuleSides(line)) |rule| {
            if (try appendSymbolicUnit(record, "rule", rule.left, line_number, true)) |rule_name| {
                try appendSymbolicReferences(record, rule.left, line_number);
                try appendSymbolicReferences(record, rule.right, line_number);
                if (current_section) |section_name| try appendCachedSemanticEdge(record, rule_name, line_number, section_name, line_number, .structural_hint);
            }
            continue;
        }
        if (try appendSymbolicUnit(record, "statement", line, line_number, true)) |statement_name| {
            if (current_section) |section_name| try appendCachedSemanticEdge(record, statement_name, line_number, section_name, line_number, .structural_hint);
        }
    }
}

fn appendSymbolicUnit(
    record: *CachedFileRecord,
    prefix: []const u8,
    text: []const u8,
    line: u32,
    include_line: bool,
) !?[]const u8 {
    if (record.declarations.items.len >= MAX_SYMBOLIC_UNITS_PER_FILE) return null;

    const slug = try symbolicSlug(record.allocator, text);
    defer record.allocator.free(slug);
    const name = if (include_line)
        try std.fmt.allocPrint(record.allocator, "{s}:{s}@{d}", .{ prefix, slug, line })
    else
        try std.fmt.allocPrint(record.allocator, "{s}:{s}", .{ prefix, slug });
    defer record.allocator.free(name);

    try appendCachedDecl(record, name, line, .symbolic_unit, true, .definition);
    try appendSymbolicReferences(record, text, line);
    return record.declarations.items[record.declarations.items.len - 1].name;
}

fn appendSymbolicNamedUnit(record: *CachedFileRecord, prefix: []const u8, text: []const u8, line: u32) !?[]const u8 {
    if (record.declarations.items.len >= MAX_SYMBOLIC_UNITS_PER_FILE) return null;
    var name = std.ArrayList(u8).init(record.allocator);
    defer name.deinit();
    try name.appendSlice(prefix);
    try name.append(':');
    try appendSanitizedSymbolicText(&name, text, true);
    return appendSymbolicExactUnit(record, name.items, text, line);
}

fn appendSymbolicExactUnit(record: *CachedFileRecord, exact_name: []const u8, source_text: []const u8, line: u32) !?[]const u8 {
    if (record.declarations.items.len >= MAX_SYMBOLIC_UNITS_PER_FILE) return null;
    try appendCachedDecl(record, exact_name, line, .symbolic_unit, true, .definition);
    try appendSymbolicReferences(record, source_text, line);
    return record.declarations.items[record.declarations.items.len - 1].name;
}

fn appendSymbolicReferences(record: *CachedFileRecord, text: []const u8, line: u32) !void {
    if (record.references.items.len >= MAX_SYMBOLIC_REFERENCES_PER_FILE) return;
    var i: usize = 0;
    while (i < text.len and record.references.items.len < MAX_SYMBOLIC_REFERENCES_PER_FILE) {
        while (i < text.len and !isSymbolicTokenByte(text[i])) : (i += 1) {}
        const start = i;
        while (i < text.len and isSymbolicTokenByte(text[i])) : (i += 1) {}
        if (start == i) continue;
        const token = std.mem.trim(u8, text[start..i], "._-");
        if (token.len < 2) continue;
        try record.references.append(.{
            .name = try asciiLowerDup(record.allocator, token),
            .line = line,
        });
    }
}

fn appendCachedSemanticEdge(
    record: *CachedFileRecord,
    owner_name: []const u8,
    owner_line: u32,
    target_name: []const u8,
    line: u32,
    kind: SemanticEdgeKind,
) !void {
    _ = owner_name;
    try record.semantic_edges.append(.{
        .target_rel_path = try record.allocator.dupe(u8, record.rel_path),
        .target_symbol = try record.allocator.dupe(u8, target_name),
        .line = line,
        .owner_line = owner_line,
        .kind = kind,
    });
}

fn markdownHeadingText(line: []const u8) ?[]const u8 {
    var count: usize = 0;
    while (count < line.len and line[count] == '#') : (count += 1) {}
    if (count == 0 or count >= line.len or line[count] != ' ') return null;
    return std.mem.trim(u8, line[count + 1 ..], " \t");
}

fn markdownListItemText(line: []const u8) ?[]const u8 {
    if (line.len >= 2 and (line[0] == '-' or line[0] == '*') and line[1] == ' ') return std.mem.trim(u8, line[2..], " \t");
    var i: usize = 0;
    while (i < line.len and std.ascii.isDigit(line[i])) : (i += 1) {}
    if (i > 0 and i + 1 < line.len and line[i] == '.' and line[i + 1] == ' ') return std.mem.trim(u8, line[i + 2 ..], " \t");
    return null;
}

fn trimConfigLine(raw_line: []const u8) []const u8 {
    const line = std.mem.trim(u8, std.mem.trimRight(u8, raw_line, "\r"), " \t");
    if (line.len == 0) return line;
    if (line[0] == '#') return "";
    if (line[0] == ';') return "";
    return line;
}

fn configSectionName(line: []const u8) ?[]const u8 {
    if (line.len >= 3 and line[0] == '[' and line[line.len - 1] == ']') {
        return std.mem.trim(u8, line[1 .. line.len - 1], " \t\"");
    }
    return null;
}

fn yamlContainerName(line: []const u8) ?[]const u8 {
    if (!std.mem.endsWith(u8, line, ":")) return null;
    const body = std.mem.trim(u8, line[0 .. line.len - 1], " \t\"");
    if (body.len == 0 or std.mem.indexOfScalar(u8, body, ' ') != null) return null;
    return body;
}

fn configKeyValue(line: []const u8) ?struct { key: []const u8, value: []const u8, line: u32 = 0 } {
    if (std.mem.startsWith(u8, line, "{") or std.mem.startsWith(u8, line, "}")) return null;
    if (std.mem.endsWith(u8, line, "{") or std.mem.endsWith(u8, line, "}")) return null;
    if (std.mem.indexOfScalar(u8, line, '=')) |eq| {
        const key = std.mem.trim(u8, line[0..eq], " \t\"");
        const value = std.mem.trim(u8, std.mem.trimRight(u8, line[eq + 1 ..], ","), " \t\"");
        if (key.len == 0 or value.len == 0) return null;
        return .{ .key = key, .value = value };
    }
    if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
        const key = std.mem.trim(u8, line[0..colon], " \t\"");
        const value = std.mem.trim(u8, std.mem.trimRight(u8, line[colon + 1 ..], ","), " \t\"");
        if (key.len == 0 or value.len == 0) return null;
        return .{ .key = key, .value = value };
    }
    return null;
}

fn trimDslLine(raw_line: []const u8) []const u8 {
    var line = std.mem.trim(u8, std.mem.trimRight(u8, raw_line, "\r"), " \t");
    if (std.mem.indexOf(u8, line, "//")) |idx| line = std.mem.trimRight(u8, line[0..idx], " \t");
    if (std.mem.indexOfScalar(u8, line, '#')) |idx| line = std.mem.trimRight(u8, line[0..idx], " \t");
    return line;
}

fn dslRuleSides(line: []const u8) ?struct { left: []const u8, right: []const u8 } {
    for (&[_][]const u8{ "->", "=>", ":=" }) |delim| {
        if (std.mem.indexOf(u8, line, delim)) |idx| {
            const left = std.mem.trim(u8, line[0..idx], " \t\"");
            const right = std.mem.trim(u8, line[idx + delim.len ..], " \t\"");
            if (left.len == 0 or right.len == 0) return null;
            return .{ .left = left, .right = right };
        }
    }
    return null;
}

fn symbolicSlug(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    try appendSanitizedSymbolicText(&out, text, false);
    if (out.items.len == 0) try out.appendSlice("unit");
    return out.toOwnedSlice();
}

fn appendSanitizedSymbolicText(out: *std.ArrayList(u8), text: []const u8, allow_dot: bool) !void {
    var written: usize = 0;
    var pending_sep = false;
    var i: usize = 0;
    while (i < text.len and written < MAX_SYMBOLIC_SLUG_BYTES) : (i += 1) {
        const byte = text[i];
        if (std.ascii.isAlphanumeric(byte)) {
            if (pending_sep and out.items.len > 0 and out.items[out.items.len - 1] != '_') {
                try out.append('_');
                written += 1;
                if (written >= MAX_SYMBOLIC_SLUG_BYTES) break;
            }
            try out.append(std.ascii.toLower(byte));
            written += 1;
            pending_sep = false;
            continue;
        }
        if (allow_dot and byte == '.' and out.items.len > 0 and out.items[out.items.len - 1] != '.') {
            try out.append('.');
            written += 1;
            pending_sep = false;
            continue;
        }
        pending_sep = true;
    }
    while (out.items.len > 0 and (out.items[out.items.len - 1] == '_' or out.items[out.items.len - 1] == '.')) {
        _ = out.pop();
    }
}

fn asciiLowerDup(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, text.len);
    for (text, 0..) |byte, idx| out[idx] = std.ascii.toLower(byte);
    return out;
}

fn isSymbolicTokenByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-' or byte == '.';
}

fn isMarkupTagChar(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or std.ascii.isDigit(byte) or byte == '_' or byte == '-';
}

fn tokenizeZigSource(allocator: std.mem.Allocator, source: []const u8) !std.ArrayList(ZigToken) {
    var tokens = std.ArrayList(ZigToken).init(allocator);
    errdefer tokens.deinit();

    var i: usize = 0;
    var line: u32 = 1;
    while (i < source.len) {
        const byte = source[i];
        switch (byte) {
            ' ', '\t', '\r' => {
                i += 1;
            },
            '\n' => {
                line += 1;
                i += 1;
            },
            '/' => {
                if (i + 1 < source.len and source[i + 1] == '/') {
                    i += 2;
                    while (i < source.len and source[i] != '\n') : (i += 1) {}
                } else {
                    i += 1;
                }
            },
            '"' => {
                const start = i + 1;
                i += 1;
                var escaped = false;
                while (i < source.len) : (i += 1) {
                    const ch = source[i];
                    if (ch == '\n') line += 1;
                    if (ch == '"' and !escaped) break;
                    escaped = ch == '\\' and !escaped;
                    if (ch != '\\') escaped = false;
                }
                if (i >= source.len) break;
                try tokens.append(.{
                    .tag = .string_lit,
                    .text = source[start..i],
                    .line = line,
                });
                i += 1;
            },
            '@' => {
                const start = i;
                i += 1;
                while (i < source.len and isIdentifierContinue(source[i])) : (i += 1) {}
                try tokens.append(.{
                    .tag = .builtin,
                    .text = source[start..i],
                    .line = line,
                });
            },
            else => {
                if (isIdentifierStart(byte)) {
                    const start = i;
                    i += 1;
                    while (i < source.len and isIdentifierContinue(source[i])) : (i += 1) {}
                    try tokens.append(.{
                        .tag = .identifier,
                        .text = source[start..i],
                        .line = line,
                    });
                    continue;
                }

                const tag: ZigTokenTag = switch (byte) {
                    '(' => .l_paren,
                    ')' => .r_paren,
                    '{' => .l_brace,
                    '}' => .r_brace,
                    '[' => .l_bracket,
                    ']' => .r_bracket,
                    ',' => .comma,
                    ':' => .colon,
                    ';' => .semicolon,
                    '.' => .dot,
                    '=' => .eq,
                    '!' => .bang,
                    '?' => .question,
                    '*' => .star,
                    else => .other,
                };
                try tokens.append(.{
                    .tag = tag,
                    .text = source[i .. i + 1],
                    .line = line,
                });
                i += 1;
            },
        }
    }

    return tokens;
}

fn parseTopLevelBinding(
    record: *CachedFileRecord,
    stmt: []const ZigToken,
    is_pub: bool,
    top_module_aliases: *std.StringHashMap(AliasTarget),
    top_symbol_aliases: *std.StringHashMap(AliasTarget),
) !void {
    if (stmt.len < 3 or stmt[1].tag != .identifier) return;
    const is_const = std.mem.eql(u8, stmt[0].text, "const");
    const name = stmt[1].text;
    const line = stmt[1].line;

    const eq_index = findTopLevelToken(stmt, .eq);
    const colon_index = findTopLevelTokenBefore(stmt, .colon, eq_index orelse stmt.len);

    var decl_kind: DeclKind = if (is_const) .constant else .variable;
    if (eq_index) |eq| {
        const rhs = trimTokenSlice(stmt[eq + 1 ..]);
        if (rhs.len > 0) {
            if (try matchImportExpr(record, rhs)) |target| {
                decl_kind = .module;
                try putOwnedImportEdge(record, target, line, .import);
                try top_module_aliases.put(name, .{
                    .kind = .module,
                    .rel_path = record.imports.items[record.imports.items.len - 1].rel_path,
                });
            } else if (startsContainerType(rhs)) {
                decl_kind = .type;
            } else if (resolvePathTarget(rhs, top_module_aliases, top_symbol_aliases)) |target| {
                try top_symbol_aliases.put(name, target);
                try appendSemanticEdge(record, target, line, line, .symbol_ref);
            }
        }
    }

    try record.declarations.append(.{
        .name = try record.allocator.dupe(u8, name),
        .line = line,
        .kind = decl_kind,
        .is_pub = is_pub,
        .role = .declaration_and_definition,
    });

    if (decl_kind != .module) {
        try top_symbol_aliases.put(record.declarations.items[record.declarations.items.len - 1].name, .{
            .kind = .symbol,
            .rel_path = record.rel_path,
            .symbol_name = record.declarations.items[record.declarations.items.len - 1].name,
        });
    }

    if (colon_index) |colon| {
        const type_tokens = trimTokenSlice(stmt[colon + 1 .. (eq_index orelse stmt.len)]);
        try collectTypeEdgesPrimary(record, type_tokens, line, .annotation_type, top_module_aliases, top_symbol_aliases);
    }
}

fn parseTopLevelFunction(
    record: *CachedFileRecord,
    tokens: []const ZigToken,
    is_pub: bool,
    top_module_aliases: *std.StringHashMap(AliasTarget),
    top_symbol_aliases: *std.StringHashMap(AliasTarget),
) !usize {
    if (tokens.len < 3 or tokens[1].tag != .identifier) return 1;
    const name = tokens[1].text;
    const line = tokens[1].line;

    try record.declarations.append(.{
        .name = try record.allocator.dupe(u8, name),
        .line = line,
        .kind = .function,
        .is_pub = is_pub,
        .role = .declaration_and_definition,
    });
    try top_symbol_aliases.put(record.declarations.items[record.declarations.items.len - 1].name, .{
        .kind = .symbol,
        .rel_path = record.rel_path,
        .symbol_name = record.declarations.items[record.declarations.items.len - 1].name,
    });

    const l_paren = findToken(tokens, .l_paren) orelse return 2;
    const r_paren = findMatchingToken(tokens, l_paren, .l_paren, .r_paren) orelse return l_paren + 1;

    try collectFunctionParamTypeEdges(
        record,
        tokens[l_paren + 1 .. r_paren],
        line,
        top_module_aliases,
        top_symbol_aliases,
    );

    const body_start = findFunctionBodyStart(tokens, r_paren + 1) orelse return r_paren + 1;
    try collectTypeEdgesPrimary(
        record,
        trimTokenSlice(tokens[r_paren + 1 .. body_start]),
        line,
        .signature_type,
        top_module_aliases,
        top_symbol_aliases,
    );

    if (tokens[body_start].tag != .l_brace) return body_start + 1;
    const body_end = findMatchingToken(tokens, body_start, .l_brace, .r_brace) orelse return body_start + 1;
    try parseFunctionBody(
        record,
        tokens[body_start + 1 .. body_end],
        line,
        top_module_aliases,
        top_symbol_aliases,
    );
    return body_end + 1;
}

fn parseFunctionBody(
    record: *CachedFileRecord,
    body: []const ZigToken,
    owner_line: u32,
    top_module_aliases: *const std.StringHashMap(AliasTarget),
    top_symbol_aliases: *const std.StringHashMap(AliasTarget),
) !void {
    var local_module_aliases = std.StringHashMap(AliasTarget).init(record.allocator);
    defer local_module_aliases.deinit();
    var local_symbol_aliases = std.StringHashMap(AliasTarget).init(record.allocator);
    defer local_symbol_aliases.deinit();

    var i: usize = 0;
    while (i < body.len) {
        if (body[i].tag == .identifier and (std.mem.eql(u8, body[i].text, "const") or std.mem.eql(u8, body[i].text, "var"))) {
            const stmt_end = findStatementEnd(body, i) orelse body.len - 1;
            try parseLocalBinding(
                record,
                body[i .. stmt_end + 1],
                owner_line,
                top_module_aliases,
                top_symbol_aliases,
                &local_module_aliases,
                &local_symbol_aliases,
            );
            i = stmt_end + 1;
            continue;
        }

        const consumed = try scanResolvedUses(
            record,
            body[i..],
            owner_line,
            top_module_aliases,
            top_symbol_aliases,
            &local_module_aliases,
            &local_symbol_aliases,
        );
        i += @max(consumed, 1);
    }
}

fn parseLocalBinding(
    record: *CachedFileRecord,
    stmt: []const ZigToken,
    owner_line: u32,
    top_module_aliases: *const std.StringHashMap(AliasTarget),
    top_symbol_aliases: *const std.StringHashMap(AliasTarget),
    local_module_aliases: *std.StringHashMap(AliasTarget),
    local_symbol_aliases: *std.StringHashMap(AliasTarget),
) !void {
    if (stmt.len < 3 or stmt[1].tag != .identifier) return;
    const name = stmt[1].text;
    const eq_index = findTopLevelToken(stmt, .eq);
    const colon_index = findTopLevelTokenBefore(stmt, .colon, eq_index orelse stmt.len);

    if (colon_index) |colon| {
        const type_tokens = trimTokenSlice(stmt[colon + 1 .. (eq_index orelse stmt.len)]);
        try collectTypeEdgesWithFallback(
            record,
            type_tokens,
            owner_line,
            .annotation_type,
            local_module_aliases,
            local_symbol_aliases,
            top_module_aliases,
            top_symbol_aliases,
        );
    }

    if (eq_index) |eq| {
        const rhs = trimTokenSlice(stmt[eq + 1 ..]);
        _ = try scanUsesInRange(
            record,
            rhs,
            owner_line,
            local_module_aliases,
            local_symbol_aliases,
            top_module_aliases,
            top_symbol_aliases,
        );
        if (rhs.len > 0) {
            if (try matchImportExpr(record, rhs)) |target| {
                try putOwnedImportEdge(record, target, stmt[1].line, .import);
                try local_module_aliases.put(name, .{
                    .kind = .module,
                    .rel_path = record.imports.items[record.imports.items.len - 1].rel_path,
                });
            } else if (resolvePathTargetWithFallback(rhs, local_module_aliases, local_symbol_aliases, top_module_aliases, top_symbol_aliases)) |target| {
                switch (target.kind) {
                    .module => try local_module_aliases.put(name, target),
                    .symbol => try local_symbol_aliases.put(name, target),
                }
            }
        }
    }
}

fn scanResolvedUses(
    record: *CachedFileRecord,
    tokens: []const ZigToken,
    owner_line: u32,
    top_module_aliases: *const std.StringHashMap(AliasTarget),
    top_symbol_aliases: *const std.StringHashMap(AliasTarget),
    local_module_aliases: *const std.StringHashMap(AliasTarget),
    local_symbol_aliases: *const std.StringHashMap(AliasTarget),
) !usize {
    if (tokens.len == 0) return 0;
    if (tokens[0].tag != .identifier) return 1;
    if (isIgnoredIdentifier(tokens[0].text)) return 1;
    if (tokens.len > 1 and tokens[1].tag == .colon) return 1;

    const path_len = pathExpressionLength(tokens);
    if (path_len == 0) return 1;

    const target = resolvePathTargetWithFallback(tokens[0..path_len], local_module_aliases, local_symbol_aliases, top_module_aliases, top_symbol_aliases) orelse return path_len;
    if (target.kind != .symbol) return path_len;

    const edge_kind: SemanticEdgeKind = if (path_len < tokens.len and tokens[path_len].tag == .l_paren) .call else .symbol_ref;
    try appendSemanticEdge(record, target, tokens[0].line, owner_line, edge_kind);
    return path_len;
}

fn scanUsesInRange(
    record: *CachedFileRecord,
    tokens: []const ZigToken,
    owner_line: u32,
    local_module_aliases: *const std.StringHashMap(AliasTarget),
    local_symbol_aliases: *const std.StringHashMap(AliasTarget),
    top_module_aliases: *const std.StringHashMap(AliasTarget),
    top_symbol_aliases: *const std.StringHashMap(AliasTarget),
) !usize {
    var i: usize = 0;
    while (i < tokens.len) {
        const consumed = try scanResolvedUses(
            record,
            tokens[i..],
            owner_line,
            top_module_aliases,
            top_symbol_aliases,
            local_module_aliases,
            local_symbol_aliases,
        );
        i += @max(consumed, 1);
    }
    return i;
}

fn collectFunctionParamTypeEdges(
    record: *CachedFileRecord,
    params: []const ZigToken,
    owner_line: u32,
    top_module_aliases: *const std.StringHashMap(AliasTarget),
    top_symbol_aliases: *const std.StringHashMap(AliasTarget),
) !void {
    var depth_paren: u32 = 0;
    var depth_bracket: u32 = 0;
    var start: ?usize = null;

    for (params, 0..) |token, idx| {
        switch (token.tag) {
            .l_paren => depth_paren += 1,
            .r_paren => {
                if (depth_paren > 0) depth_paren -= 1;
            },
            .l_bracket => depth_bracket += 1,
            .r_bracket => {
                if (depth_bracket > 0) depth_bracket -= 1;
            },
            .colon => {
                if (depth_paren == 0 and depth_bracket == 0) start = idx + 1;
            },
            .comma => if (depth_paren == 0 and depth_bracket == 0 and start != null) {
                try collectTypeEdgesPrimary(record, trimTokenSlice(params[start.?..idx]), owner_line, .signature_type, top_module_aliases, top_symbol_aliases);
                start = null;
            },
            else => {},
        }
    }

    if (start) |idx| {
        try collectTypeEdgesPrimary(record, trimTokenSlice(params[idx..]), owner_line, .signature_type, top_module_aliases, top_symbol_aliases);
    }
}

fn collectTypeEdgesPrimary(
    record: *CachedFileRecord,
    tokens: []const ZigToken,
    owner_line: u32,
    edge_kind: SemanticEdgeKind,
    primary_module_aliases: *const std.StringHashMap(AliasTarget),
    primary_symbol_aliases: *const std.StringHashMap(AliasTarget),
) !void {
    try collectTypeEdgesOptionalFallback(record, tokens, owner_line, edge_kind, primary_module_aliases, primary_symbol_aliases, null, null);
}

fn collectTypeEdgesWithFallback(
    record: *CachedFileRecord,
    tokens: []const ZigToken,
    owner_line: u32,
    edge_kind: SemanticEdgeKind,
    local_module_aliases: *const std.StringHashMap(AliasTarget),
    local_symbol_aliases: *const std.StringHashMap(AliasTarget),
    top_module_aliases: *const std.StringHashMap(AliasTarget),
    top_symbol_aliases: *const std.StringHashMap(AliasTarget),
) !void {
    try collectTypeEdgesOptionalFallback(record, tokens, owner_line, edge_kind, local_module_aliases, local_symbol_aliases, top_module_aliases, top_symbol_aliases);
}

fn collectTypeEdgesOptionalFallback(
    record: *CachedFileRecord,
    tokens: []const ZigToken,
    owner_line: u32,
    edge_kind: SemanticEdgeKind,
    primary_module_aliases: *const std.StringHashMap(AliasTarget),
    primary_symbol_aliases: *const std.StringHashMap(AliasTarget),
    fallback_module_aliases: ?*const std.StringHashMap(AliasTarget),
    fallback_symbol_aliases: ?*const std.StringHashMap(AliasTarget),
) !void {
    var i: usize = 0;
    while (i < tokens.len) {
        if (tokens[i].tag != .identifier or isIgnoredIdentifier(tokens[i].text)) {
            i += 1;
            continue;
        }
        const path_len = pathExpressionLength(tokens[i..]);
        if (path_len == 0) {
            i += 1;
            continue;
        }
        const target = if (fallback_module_aliases != null and fallback_symbol_aliases != null)
            resolvePathTargetWithFallback(tokens[i .. i + path_len], primary_module_aliases, primary_symbol_aliases, fallback_module_aliases.?, fallback_symbol_aliases.?)
        else
            resolvePathTarget(tokens[i .. i + path_len], primary_module_aliases, primary_symbol_aliases);
        if (target) |resolved| {
            if (resolved.kind == .symbol) {
                try appendSemanticEdge(record, resolved, tokens[i].line, owner_line, edge_kind);
            }
        }
        i += path_len;
    }
}

fn appendSemanticEdge(
    record: *CachedFileRecord,
    target: AliasTarget,
    line: u32,
    owner_line: u32,
    kind: SemanticEdgeKind,
) !void {
    if (target.kind != .symbol or target.symbol_name == null) return;
    try record.semantic_edges.append(.{
        .target_rel_path = try record.allocator.dupe(u8, target.rel_path),
        .target_symbol = try record.allocator.dupe(u8, target.symbol_name.?),
        .line = line,
        .owner_line = owner_line,
        .kind = kind,
    });
}

fn putOwnedImportEdge(record: *CachedFileRecord, import_target: []u8, line: u32, kind: DependencyKind) !void {
    for (record.imports.items) |existing| {
        if (existing.line == line and existing.kind == kind and std.mem.eql(u8, existing.rel_path, import_target)) {
            record.allocator.free(import_target);
            return;
        }
    }
    try record.imports.append(.{
        .rel_path = import_target,
        .line = line,
        .kind = kind,
    });
}

fn matchImportExpr(record: *CachedFileRecord, rhs: []const ZigToken) !?[]u8 {
    if (rhs.len < 4) return null;
    if (rhs[0].tag != .builtin or !std.mem.eql(u8, rhs[0].text, "@import")) return null;
    if (rhs[1].tag != .l_paren or rhs[2].tag != .string_lit or rhs[3].tag != .r_paren) return null;
    return resolveImportPathForOwner(record.allocator, record.rel_path, rhs[2].text) catch null;
}

fn startsContainerType(tokens: []const ZigToken) bool {
    if (tokens.len == 0 or tokens[0].tag != .identifier) return false;
    return std.mem.eql(u8, tokens[0].text, "struct") or
        std.mem.eql(u8, tokens[0].text, "enum") or
        std.mem.eql(u8, tokens[0].text, "union") or
        std.mem.eql(u8, tokens[0].text, "opaque");
}

fn resolvePathTarget(
    tokens: []const ZigToken,
    module_aliases: *const std.StringHashMap(AliasTarget),
    symbol_aliases: *const std.StringHashMap(AliasTarget),
) ?AliasTarget {
    if (tokens.len == 0 or tokens[0].tag != .identifier) return null;
    if (tokens.len == 1) {
        if (symbol_aliases.get(tokens[0].text)) |target| return target;
        return module_aliases.get(tokens[0].text);
    }
    if (tokens.len == 3 and tokens[1].tag == .dot and tokens[2].tag == .identifier) {
        if (module_aliases.get(tokens[0].text)) |module_target| {
            return .{
                .kind = .symbol,
                .rel_path = module_target.rel_path,
                .symbol_name = tokens[2].text,
            };
        }
    }
    return null;
}

fn resolvePathTargetWithFallback(
    tokens: []const ZigToken,
    primary_module_aliases: *const std.StringHashMap(AliasTarget),
    primary_symbol_aliases: *const std.StringHashMap(AliasTarget),
    fallback_module_aliases: *const std.StringHashMap(AliasTarget),
    fallback_symbol_aliases: *const std.StringHashMap(AliasTarget),
) ?AliasTarget {
    return resolvePathTarget(tokens, primary_module_aliases, primary_symbol_aliases) orelse
        resolvePathTarget(tokens, fallback_module_aliases, fallback_symbol_aliases);
}

fn pathExpressionLength(tokens: []const ZigToken) usize {
    if (tokens.len == 0 or tokens[0].tag != .identifier) return 0;
    var i: usize = 1;
    while (i + 1 < tokens.len and tokens[i].tag == .dot and tokens[i + 1].tag == .identifier) : (i += 2) {}
    return i;
}

fn trimTokenSlice(tokens: []const ZigToken) []const ZigToken {
    var start: usize = 0;
    var end: usize = tokens.len;
    while (start < end and tokens[start].tag == .comma) start += 1;
    while (end > start and (tokens[end - 1].tag == .semicolon or tokens[end - 1].tag == .comma)) end -= 1;
    return tokens[start..end];
}

fn findToken(tokens: []const ZigToken, tag: ZigTokenTag) ?usize {
    for (tokens, 0..) |token, idx| {
        if (token.tag == tag) return idx;
    }
    return null;
}

fn findMatchingToken(tokens: []const ZigToken, start: usize, open: ZigTokenTag, close: ZigTokenTag) ?usize {
    var depth: u32 = 0;
    var i = start;
    while (i < tokens.len) : (i += 1) {
        if (tokens[i].tag == open) depth += 1;
        if (tokens[i].tag == close) {
            if (depth == 0) return null;
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

fn findFunctionBodyStart(tokens: []const ZigToken, start: usize) ?usize {
    var paren_depth: u32 = 0;
    var bracket_depth: u32 = 0;
    var brace_depth: u32 = 0;
    var i = start;
    while (i < tokens.len) : (i += 1) {
        switch (tokens[i].tag) {
            .l_paren => paren_depth += 1,
            .r_paren => {
                if (paren_depth > 0) paren_depth -= 1;
            },
            .l_bracket => bracket_depth += 1,
            .r_bracket => {
                if (bracket_depth > 0) bracket_depth -= 1;
            },
            .l_brace => {
                if (paren_depth == 0 and bracket_depth == 0 and brace_depth == 0) return i;
                brace_depth += 1;
            },
            .r_brace => {
                if (brace_depth > 0) brace_depth -= 1;
            },
            .semicolon => if (paren_depth == 0 and bracket_depth == 0 and brace_depth == 0) return i,
            else => {},
        }
    }
    return null;
}

fn findStatementEnd(tokens: []const ZigToken, start: usize) ?usize {
    var paren_depth: u32 = 0;
    var bracket_depth: u32 = 0;
    var brace_depth: u32 = 0;
    var i = start;
    while (i < tokens.len) : (i += 1) {
        switch (tokens[i].tag) {
            .l_paren => paren_depth += 1,
            .r_paren => {
                if (paren_depth > 0) paren_depth -= 1;
            },
            .l_bracket => bracket_depth += 1,
            .r_bracket => {
                if (bracket_depth > 0) bracket_depth -= 1;
            },
            .l_brace => brace_depth += 1,
            .r_brace => {
                if (brace_depth > 0) brace_depth -= 1;
            },
            .semicolon => if (paren_depth == 0 and bracket_depth == 0 and brace_depth == 0) return i,
            else => {},
        }
    }
    return null;
}

fn findTopLevelToken(tokens: []const ZigToken, tag: ZigTokenTag) ?usize {
    return findTopLevelTokenBefore(tokens, tag, tokens.len);
}

fn findTopLevelTokenBefore(tokens: []const ZigToken, tag: ZigTokenTag, limit: usize) ?usize {
    var paren_depth: u32 = 0;
    var bracket_depth: u32 = 0;
    var brace_depth: u32 = 0;
    for (tokens[0..limit], 0..) |token, idx| {
        switch (token.tag) {
            .l_paren => paren_depth += 1,
            .r_paren => {
                if (paren_depth > 0) paren_depth -= 1;
            },
            .l_bracket => bracket_depth += 1,
            .r_bracket => {
                if (bracket_depth > 0) bracket_depth -= 1;
            },
            .l_brace => brace_depth += 1,
            .r_brace => {
                if (brace_depth > 0) brace_depth -= 1;
            },
            else => {},
        }
        if (paren_depth == 0 and bracket_depth == 0 and brace_depth == 0 and token.tag == tag) return idx;
    }
    return null;
}

fn findDeclarationByLine(index: *const RepoIndex, file_index: u32, line: u32) ?u32 {
    for (index.files.items[file_index].declaration_indexes.items) |decl_index| {
        if (index.declarations.items[decl_index].line == line) return decl_index;
    }
    return null;
}

fn findUniqueDeclarationByNameInFile(index: *const RepoIndex, file_index: u32, name: []const u8) ?u32 {
    var found: ?u32 = null;
    for (index.files.items[file_index].declaration_indexes.items) |decl_index| {
        if (!std.mem.eql(u8, index.declarations.items[decl_index].name, name)) continue;
        if (found != null) return null;
        found = decl_index;
    }
    return found;
}

fn scanRepoFiles(allocator: std.mem.Allocator, repo_root: []const u8) !std.ArrayList(RepoScanEntry) {
    var entries = std.ArrayList(RepoScanEntry).init(allocator);
    errdefer {
        for (entries.items) |*entry| entry.deinit(allocator);
        entries.deinit();
    }
    try scanRepoDirRecursive(allocator, repo_root, "", &entries);
    std.sort.heap(RepoScanEntry, entries.items, {}, lessThanRepoScanEntry);
    return entries;
}

fn scanRepoDirRecursive(
    allocator: std.mem.Allocator,
    abs_dir: []const u8,
    rel_dir: []const u8,
    entries: *std.ArrayList(RepoScanEntry),
) !void {
    var dir = try std.fs.openDirAbsolute(abs_dir, .{ .iterate = true });
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        const rel_path = if (rel_dir.len == 0)
            try allocator.dupe(u8, entry.name)
        else
            try std.fs.path.join(allocator, &.{ rel_dir, entry.name });
        errdefer allocator.free(rel_path);

        switch (entry.kind) {
            .directory => {
                if (shouldSkipWalkPath(rel_path)) {
                    allocator.free(rel_path);
                    continue;
                }
                const child_abs = try std.fs.path.join(allocator, &.{ abs_dir, entry.name });
                defer allocator.free(child_abs);
                try scanRepoDirRecursive(allocator, child_abs, rel_path, entries);
                allocator.free(rel_path);
            },
            .file => {
                if (!isIndexedExtension(rel_path)) {
                    allocator.free(rel_path);
                    continue;
                }
                const abs_path = try std.fs.path.join(allocator, &.{ abs_dir, entry.name });
                errdefer allocator.free(abs_path);
                const file = try std.fs.openFileAbsolute(abs_path, .{});
                defer file.close();
                const stat = try file.stat();
                try entries.append(.{
                    .rel_path = rel_path,
                    .abs_path = abs_path,
                    .size_bytes = stat.size,
                    .mtime_ns = @as(i128, @intCast(stat.mtime)),
                });
            },
            else => allocator.free(rel_path),
        }
    }
}

fn loadPersistedCache(allocator: std.mem.Allocator, cache_index_path: []const u8) !PersistedCache {
    const file = try std.fs.openFileAbsolute(cache_index_path, .{});
    defer file.close();

    const stat = try file.stat();
    const bytes = try file.readToEndAlloc(allocator, @intCast(stat.size));
    defer allocator.free(bytes);

    var line_it = std.mem.splitScalar(u8, bytes, '\n');
    const magic = line_it.next() orelse return error.InvalidCodeIntelCache;
    if (!std.mem.eql(u8, magic, CACHE_MAGIC)) return error.InvalidCodeIntelCache;

    const root_line = line_it.next() orelse return error.InvalidCodeIntelCache;
    var root_fields = std.mem.splitScalar(u8, root_line, '\t');
    if (!std.mem.eql(u8, root_fields.next() orelse return error.InvalidCodeIntelCache, "repo")) return error.InvalidCodeIntelCache;
    const repo_root = try parseCacheStringField(allocator, root_fields.next() orelse return error.InvalidCodeIntelCache);
    errdefer allocator.free(repo_root);

    var cache = PersistedCache{
        .allocator = allocator,
        .repo_root = repo_root,
        .files = std.ArrayList(CachedFileRecord).init(allocator),
    };
    errdefer cache.deinit();

    var current: ?CachedFileRecord = null;
    errdefer if (current) |*file_record| file_record.deinit();

    while (line_it.next()) |line| {
        if (line.len == 0) continue;
        var fields = std.mem.splitScalar(u8, line, '\t');
        const tag = fields.next() orelse return error.InvalidCodeIntelCache;
        if (std.mem.eql(u8, tag, "file")) {
            if (current != null) return error.InvalidCodeIntelCache;
            const rel_path = try parseCacheStringField(allocator, fields.next() orelse return error.InvalidCodeIntelCache);
            errdefer allocator.free(rel_path);
            current = CachedFileRecord.init(
                allocator,
                rel_path,
                parseSubsystem(fields.next() orelse return error.InvalidCodeIntelCache) orelse return error.InvalidCodeIntelCache,
                try std.fmt.parseUnsigned(u64, fields.next() orelse return error.InvalidCodeIntelCache, 10),
                try std.fmt.parseInt(i128, fields.next() orelse return error.InvalidCodeIntelCache, 10),
            );
            current.?.content_hash = try std.fmt.parseUnsigned(u64, fields.next() orelse return error.InvalidCodeIntelCache, 10);
        } else if (std.mem.eql(u8, tag, "decl")) {
            if (current) |*file_record| {
                try file_record.declarations.append(.{
                    .name = try parseCacheStringField(allocator, fields.next() orelse return error.InvalidCodeIntelCache),
                    .line = try std.fmt.parseUnsigned(u32, fields.next() orelse return error.InvalidCodeIntelCache, 10),
                    .kind = parseDeclKind(fields.next() orelse return error.InvalidCodeIntelCache) orelse return error.InvalidCodeIntelCache,
                    .is_pub = parseCacheBool(fields.next() orelse return error.InvalidCodeIntelCache) orelse return error.InvalidCodeIntelCache,
                    .role = parseDeclRole(fields.next() orelse return error.InvalidCodeIntelCache) orelse return error.InvalidCodeIntelCache,
                });
            } else return error.InvalidCodeIntelCache;
        } else if (std.mem.eql(u8, tag, "ref")) {
            if (current) |*file_record| {
                try file_record.references.append(.{
                    .name = try parseCacheStringField(allocator, fields.next() orelse return error.InvalidCodeIntelCache),
                    .line = try std.fmt.parseUnsigned(u32, fields.next() orelse return error.InvalidCodeIntelCache, 10),
                });
            } else return error.InvalidCodeIntelCache;
        } else if (std.mem.eql(u8, tag, "imp")) {
            if (current) |*file_record| {
                try file_record.imports.append(.{
                    .rel_path = try parseCacheStringField(allocator, fields.next() orelse return error.InvalidCodeIntelCache),
                    .line = try std.fmt.parseUnsigned(u32, fields.next() orelse return error.InvalidCodeIntelCache, 10),
                    .kind = parseDependencyKind(fields.next() orelse return error.InvalidCodeIntelCache) orelse return error.InvalidCodeIntelCache,
                });
            } else return error.InvalidCodeIntelCache;
        } else if (std.mem.eql(u8, tag, "sem")) {
            if (current) |*file_record| {
                try file_record.semantic_edges.append(.{
                    .target_rel_path = try parseCacheStringField(allocator, fields.next() orelse return error.InvalidCodeIntelCache),
                    .target_symbol = try parseCacheStringField(allocator, fields.next() orelse return error.InvalidCodeIntelCache),
                    .line = try std.fmt.parseUnsigned(u32, fields.next() orelse return error.InvalidCodeIntelCache, 10),
                    .owner_line = try std.fmt.parseUnsigned(u32, fields.next() orelse return error.InvalidCodeIntelCache, 10),
                    .kind = parseSemanticEdgeKind(fields.next() orelse return error.InvalidCodeIntelCache) orelse return error.InvalidCodeIntelCache,
                });
            } else return error.InvalidCodeIntelCache;
        } else if (std.mem.eql(u8, tag, "use")) {
            if (current) |*file_record| {
                try file_record.deferred_edges.append(.{
                    .raw_symbol = try parseCacheStringField(allocator, fields.next() orelse return error.InvalidCodeIntelCache),
                    .line = try std.fmt.parseUnsigned(u32, fields.next() orelse return error.InvalidCodeIntelCache, 10),
                    .owner_line = try std.fmt.parseUnsigned(u32, fields.next() orelse return error.InvalidCodeIntelCache, 10),
                    .kind = parseSemanticEdgeKind(fields.next() orelse return error.InvalidCodeIntelCache) orelse return error.InvalidCodeIntelCache,
                });
            } else return error.InvalidCodeIntelCache;
        } else if (std.mem.eql(u8, tag, "end")) {
            if (current == null) return error.InvalidCodeIntelCache;
            try cache.files.append(current.?);
            current = null;
        } else {
            return error.InvalidCodeIntelCache;
        }
    }

    if (current != null) return error.InvalidCodeIntelCache;
    std.sort.heap(CachedFileRecord, cache.files.items, {}, lessThanCachedFileRecord);
    return cache;
}

fn persistCache(allocator: std.mem.Allocator, cache_index_path: []const u8, cache: *const PersistedCache) !void {
    var out = std.ArrayList(u8).init(allocator);
    defer out.deinit();
    const writer = out.writer();

    try writer.writeAll(CACHE_MAGIC);
    try writer.writeByte('\n');
    try writer.writeAll("repo\t");
    try writeJsonString(writer, cache.repo_root);
    try writer.writeByte('\n');

    for (cache.files.items) |file| {
        try writer.writeAll("file\t");
        try writeJsonString(writer, file.rel_path);
        try writer.print("\t{s}\t{d}\t{d}\t{d}\n", .{
            subsystemName(file.subsystem),
            file.size_bytes,
            file.mtime_ns,
            file.content_hash,
        });
        for (file.declarations.items) |decl| {
            try writer.writeAll("decl\t");
            try writeJsonString(writer, decl.name);
            try writer.print("\t{d}\t{s}\t{s}\t{s}\n", .{
                decl.line,
                declKindName(decl.kind),
                if (decl.is_pub) "1" else "0",
                declRoleName(decl.role),
            });
        }
        for (file.references.items) |reference| {
            try writer.writeAll("ref\t");
            try writeJsonString(writer, reference.name);
            try writer.print("\t{d}\n", .{reference.line});
        }
        for (file.imports.items) |import| {
            try writer.writeAll("imp\t");
            try writeJsonString(writer, import.rel_path);
            try writer.print("\t{d}\t{s}\n", .{ import.line, dependencyKindName(import.kind) });
        }
        for (file.semantic_edges.items) |edge| {
            try writer.writeAll("sem\t");
            try writeJsonString(writer, edge.target_rel_path);
            try writer.writeByte('\t');
            try writeJsonString(writer, edge.target_symbol);
            try writer.print("\t{d}\t{d}\t{s}\n", .{
                edge.line,
                edge.owner_line,
                semanticEdgeKindName(edge.kind),
            });
        }
        for (file.deferred_edges.items) |edge| {
            try writer.writeAll("use\t");
            try writeJsonString(writer, edge.raw_symbol);
            try writer.print("\t{d}\t{d}\t{s}\n", .{
                edge.line,
                edge.owner_line,
                semanticEdgeKindName(edge.kind),
            });
        }
        try writer.writeAll("end\n");
    }

    const handle = try sys.openForWrite(allocator, cache_index_path);
    defer sys.closeFile(handle);
    try sys.writeAll(handle, out.items);
}

fn persistResult(allocator: std.mem.Allocator, shard_paths: *const shards.Paths, options: Options, rendered: []const u8) !void {
    try sys.makePath(allocator, shard_paths.code_intel_root_abs_path);

    const query_path = try std.fs.path.join(allocator, &.{ shard_paths.code_intel_root_abs_path, "last_query.txt" });
    defer allocator.free(query_path);
    const query_file = try sys.openForWrite(allocator, query_path);
    defer sys.closeFile(query_file);
    const query_text = if (options.other_target) |other|
        try std.fmt.allocPrint(allocator, "{s} {s} {s} --reasoning-mode={s}\n", .{ @tagName(options.query_kind), options.target, other, mc.reasoningModeName(options.reasoning_mode) })
    else
        try std.fmt.allocPrint(allocator, "{s} {s} --reasoning-mode={s}\n", .{ @tagName(options.query_kind), options.target, mc.reasoningModeName(options.reasoning_mode) });
    defer allocator.free(query_text);
    try sys.writeAll(query_file, query_text);

    const result_path = try std.fs.path.join(allocator, &.{ shard_paths.code_intel_root_abs_path, "last_result.json" });
    defer allocator.free(result_path);
    const result_file = try sys.openForWrite(allocator, result_path);
    defer sys.closeFile(result_file);
    try sys.writeAll(result_file, rendered);
}

fn parseCacheStringField(allocator: std.mem.Allocator, field: []const u8) ![]u8 {
    if (field.len < 2 or field[0] != '"' or field[field.len - 1] != '"') return error.InvalidCodeIntelCache;
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();

    var i: usize = 1;
    while (i + 1 < field.len) : (i += 1) {
        const byte = field[i];
        if (byte == '\\') {
            i += 1;
            if (i >= field.len - 1) return error.InvalidCodeIntelCache;
            switch (field[i]) {
                '"', '\\' => try out.append(field[i]),
                'n' => try out.append('\n'),
                'r' => try out.append('\r'),
                't' => try out.append('\t'),
                else => return error.InvalidCodeIntelCache,
            }
            continue;
        }
        try out.append(byte);
    }

    return out.toOwnedSlice();
}

fn parseCacheBool(field: []const u8) ?bool {
    if (std.mem.eql(u8, field, "1")) return true;
    if (std.mem.eql(u8, field, "0")) return false;
    return null;
}

fn appendHypothesis(
    allocator: std.mem.Allocator,
    traces: *std.ArrayList(CandidateTrace),
    branch_ids: *std.ArrayList(u32),
    scores: *std.ArrayList(u32),
    hypothesis: Hypothesis,
) !void {
    try traces.append(.{
        .label = try allocator.dupe(u8, hypothesis.label),
        .score = hypothesis.score,
        .evidence_count = hypothesis.evidence_count,
        .abstraction_bias = hypothesis.abstraction_bias,
    });
    try branch_ids.append(hypothesis.branch_id);
    try scores.append(hypothesis.score);
}

fn applyBiasToHypotheses(
    hypotheses: *std.ArrayList(CandidateTrace),
    branch_ids: []const u32,
    scores: *std.ArrayList(u32),
    biases: BranchBiasMap,
) void {
    for (hypotheses.items, 0..) |*hypothesis, idx| {
        if (idx >= branch_ids.len) break;
        const branch_id = branch_ids[idx];
        const delta = biases.get(branch_id);
        if (delta == 0) continue;
        hypothesis.abstraction_bias +%= delta;
        hypothesis.score +%= delta;
        if (idx < scores.items.len) scores.items[idx] +%= delta;
    }
}

fn candidateLabel(allocator: std.mem.Allocator, index: *const RepoIndex, candidate: ResolutionCandidate) ![]u8 {
    const file = index.files.items[candidate.file_index];
    return switch (candidate.target_kind) {
        .file => std.fmt.allocPrint(allocator, "file:{s}", .{file.rel_path}),
        .declaration => blk: {
            const decl = index.declarations.items[candidate.decl_index.?];
            break :blk std.fmt.allocPrint(allocator, "{s}:{s}@{s}:{d}", .{
                declKindName(decl.kind),
                decl.name,
                file.rel_path,
                decl.line,
            });
        },
    };
}

fn appendEvidenceSlice(out: *std.ArrayList(EvidenceSeed), items: []const EvidenceSeed) !void {
    for (items) |item| try appendEvidenceUnique(out, item);
}

fn appendEvidenceUnique(out: *std.ArrayList(EvidenceSeed), item: EvidenceSeed) !void {
    for (out.items) |existing| {
        if (existing.file_index == item.file_index and existing.line == item.line and std.mem.eql(u8, existing.reason, item.reason)) return;
    }
    try out.append(item);
}

fn appendCandidateTraceCopies(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(CandidateTrace),
    items: []const CandidateTrace,
) !void {
    for (items) |item| {
        try out.append(.{
            .label = try allocator.dupe(u8, item.label),
            .score = item.score,
            .evidence_count = item.evidence_count,
            .abstraction_bias = item.abstraction_bias,
        });
    }
}

fn freeCandidateTraceList(allocator: std.mem.Allocator, list: *std.ArrayList(CandidateTrace)) void {
    for (list.items) |item| allocator.free(item.label);
    list.deinit();
}

fn writeSubject(writer: anytype, subject: Subject) !void {
    try writer.writeAll("{");
    try writeJsonFieldString(writer, "name", subject.name, true);
    try writeJsonFieldString(writer, "path", subject.rel_path, false);
    try writer.print(",\"line\":{d}", .{subject.line});
    try writeOptionalStringField(writer, "kind", subject.kind_name);
    try writeOptionalStringField(writer, "subsystem", subject.subsystem);
    try writer.writeAll("}");
}

fn writeEvidenceArray(writer: anytype, items: []const Evidence) !void {
    try writer.writeAll("[");
    for (items, 0..) |item, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writer.writeAll("{");
        try writeJsonFieldString(writer, "path", item.rel_path, true);
        try writer.print(",\"line\":{d}", .{item.line});
        try writeOptionalStringField(writer, "reason", item.reason);
        try writeOptionalStringField(writer, "subsystem", item.subsystem);
        try writer.writeAll("}");
    }
    try writer.writeAll("]");
}

fn writeContradictionTraceArray(writer: anytype, items: []const ContradictionTrace) !void {
    try writer.writeAll("[");
    for (items, 0..) |item, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writer.writeAll("{");
        try writeJsonFieldString(writer, "category", item.category, true);
        try writeJsonFieldString(writer, "path", item.rel_path, false);
        try writer.print(",\"line\":{d}", .{item.line});
        try writeOptionalStringField(writer, "reason", item.reason);
        try writeOptionalStringField(writer, "subsystem", item.subsystem);
        if (item.owner) |owner| try writeOptionalStringField(writer, "owner", owner);
        try writer.writeAll("}");
    }
    try writer.writeAll("]");
}

fn writeCandidateTraceArray(writer: anytype, items: []const CandidateTrace) !void {
    try writer.writeAll("[");
    for (items, 0..) |item, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writer.writeAll("{");
        try writeJsonFieldString(writer, "label", item.label, true);
        try writer.print(",\"score\":{d},\"evidence\":{d},\"abstractionBias\":{d}", .{ item.score, item.evidence_count, item.abstraction_bias });
        try writer.writeAll("}");
    }
    try writer.writeAll("]");
}

fn writeAbstractionTraceArray(writer: anytype, items: []const AbstractionTrace) !void {
    try writer.writeAll("[");
    for (items, 0..) |item, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writer.writeAll("{");
        try writeJsonFieldString(writer, "label", item.label, true);
        try writeJsonFieldString(writer, "tier", abstractions.tierName(item.tier), false);
        try writeJsonFieldString(writer, "category", abstractions.categoryName(item.category), false);
        try writeJsonFieldString(writer, "selectionMode", abstractions.selectionModeName(item.selection_mode), false);
        try writeJsonFieldString(writer, "resolution", abstractions.reuseResolutionName(item.resolution), false);
        try writeJsonFieldString(writer, "source", item.source_spec, false);
        try writer.print(",\"staged\":{s}", .{if (item.staged) "true" else "false"});
        try writer.print(",\"usable\":{s}", .{if (item.usable) "true" else "false"});
        try writer.print(",\"consensusHash\":{d}", .{item.consensus_hash});
        try writer.writeAll(",\"provenance\":{");
        try writeJsonFieldString(writer, "ownerKind", @tagName(item.owner_kind), true);
        try writeJsonFieldString(writer, "ownerId", item.owner_id, false);
        try writer.writeAll("}");
        try writer.print(",\"qualityScore\":{d}", .{item.quality_score});
        try writer.print(",\"confidenceScore\":{d}", .{item.confidence_score});
        try writer.print(",\"lookupScore\":{d}", .{item.lookup_score});
        try writer.print(",\"directSupport\":{d}", .{item.direct_support_count});
        try writer.print(",\"lineageSupport\":{d}", .{item.lineage_support_count});
        if (item.reuse_decision != .none) try writeOptionalStringField(writer, "decision", abstractions.reuseDecisionName(item.reuse_decision));
        if (item.conflict_kind != .none) try writeOptionalStringField(writer, "conflictKind", abstractions.conflictKindName(item.conflict_kind));
        if (item.conflict_concept) |conflict_concept| try writeOptionalStringField(writer, "conflictConcept", conflict_concept);
        if (item.conflict_owner_id) |conflict_owner_id| {
            try writer.writeAll(",\"conflictProvenance\":{");
            try writeJsonFieldString(writer, "ownerKind", @tagName(item.conflict_owner_kind.?), true);
            try writeJsonFieldString(writer, "ownerId", conflict_owner_id, false);
            try writer.writeAll("}");
        }
        if (item.supporting_concept) |supporting_concept| try writeOptionalStringField(writer, "supportingConcept", supporting_concept);
        if (item.parent_concept) |parent_concept| try writeOptionalStringField(writer, "parentConcept", parent_concept);
        try writer.writeAll("}");
    }
    try writer.writeAll("]");
}

fn writeGroundingTraceArray(writer: anytype, items: []const GroundingTrace) !void {
    try writer.writeAll("[");
    for (items, 0..) |item, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writer.writeAll("{");
        try writeJsonFieldString(writer, "surface", item.surface, true);
        try writeJsonFieldString(writer, "concept", item.concept, false);
        try writeJsonFieldString(writer, "relation", item.relation, false);
        try writeJsonFieldString(writer, "selectionMode", abstractions.selectionModeName(item.selection_mode), false);
        try writeJsonFieldString(writer, "resolution", abstractions.reuseResolutionName(item.resolution), false);
        try writeJsonFieldString(writer, "source", item.source_spec, false);
        try writer.print(",\"usable\":{s}", .{if (item.usable) "true" else "false"});
        try writer.print(",\"ambiguous\":{s}", .{if (item.ambiguous) "true" else "false"});
        try writer.print(",\"lookupScore\":{d}", .{item.lookup_score});
        try writer.print(",\"confidenceScore\":{d}", .{item.confidence_score});
        try writer.print(",\"tokenSupport\":{d}", .{item.token_support_count});
        try writer.print(",\"patternSupport\":{d}", .{item.pattern_support_count});
        try writer.print(",\"sourceSupport\":{d}", .{item.source_support_count});
        try writer.print(",\"mappingScore\":{d}", .{item.mapping_score});
        try writer.writeAll(",\"provenance\":{");
        try writeJsonFieldString(writer, "ownerKind", @tagName(item.owner_kind), true);
        try writeJsonFieldString(writer, "ownerId", item.owner_id, false);
        try writer.writeAll("}");
        if (item.conflict_kind != .none) try writeOptionalStringField(writer, "conflictKind", abstractions.conflictKindName(item.conflict_kind));
        if (item.target_label) |target_label| try writeOptionalStringField(writer, "target", target_label);
        if (item.target_rel_path) |target_rel_path| try writeOptionalStringField(writer, "targetPath", target_rel_path);
        if (item.target_kind) |target_kind| try writeOptionalStringField(writer, "targetKind", target_kind);
        if (item.target_line != 0) try writer.print(",\"targetLine\":{d}", .{item.target_line});
        if (item.detail) |detail| try writeOptionalStringField(writer, "detail", detail);
        try writer.writeAll("}");
    }
    try writer.writeAll("]");
}

fn supportNodeKindName(kind: SupportNodeKind) []const u8 {
    return switch (kind) {
        .output => "output",
        .shard => "shard",
        .intent => "intent",
        .reasoning => "reasoning",
        .execution => "execution",
        .target_candidate => "target_candidate",
        .query_hypothesis => "query_hypothesis",
        .evidence => "evidence",
        .contradiction => "contradiction",
        .abstraction => "abstraction",
        .grounding => "grounding",
        .handoff => "handoff",
        .gap => "gap",
    };
}

fn supportEdgeKindName(kind: SupportEdgeKind) []const u8 {
    return switch (kind) {
        .sourced_from => "sourced_from",
        .requested_by => "requested_by",
        .derived_in => "derived_in",
        .selected_from => "selected_from",
        .selected_by => "selected_by",
        .supported_by => "supported_by",
        .checked_by => "checked_by",
        .grounded_by => "grounded_by",
        .handoff_from => "handoff_from",
        .blocked_by => "blocked_by",
    };
}

pub fn writeSupportGraphJson(writer: anytype, graph: SupportGraph) !void {
    try writer.writeAll("{");
    try writeJsonFieldString(writer, "permission", @tagName(graph.permission), true);
    try writer.print(",\"minimumMet\":{s}", .{if (graph.minimum_met) "true" else "false"});
    try writeOptionalStringField(writer, "flowMode", graph.flow_mode);
    if (graph.unresolved_reason) |reason| try writeOptionalStringField(writer, "unresolvedReason", reason);
    try writer.writeAll(",\"nodes\":");
    try writer.writeAll("[");
    for (graph.nodes, 0..) |node, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writer.writeAll("{");
        try writeJsonFieldString(writer, "id", node.id, true);
        try writeJsonFieldString(writer, "kind", supportNodeKindName(node.kind), false);
        try writeJsonFieldString(writer, "label", node.label, false);
        try writer.print(",\"usable\":{s}", .{if (node.usable) "true" else "false"});
        if (node.rel_path) |rel_path| try writeOptionalStringField(writer, "relPath", rel_path);
        if (node.line != 0) try writer.print(",\"line\":{d}", .{node.line});
        if (node.score != 0) try writer.print(",\"score\":{d}", .{node.score});
        if (node.detail) |detail| try writeOptionalStringField(writer, "detail", detail);
        try writer.writeAll("}");
    }
    try writer.writeAll("],\"edges\":");
    try writer.writeAll("[");
    for (graph.edges, 0..) |edge, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writer.writeAll("{");
        try writeJsonFieldString(writer, "from", edge.from_id, true);
        try writeJsonFieldString(writer, "to", edge.to_id, false);
        try writeJsonFieldString(writer, "kind", supportEdgeKindName(edge.kind), false);
        try writer.writeAll("}");
    }
    try writer.writeAll("]}");
}

fn writeSubsystemArray(writer: anytype, items: []const Subsystem) !void {
    try writer.writeAll("[");
    for (items, 0..) |item, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writeJsonString(writer, subsystemName(item));
    }
    try writer.writeAll("]");
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

fn normalizeRootPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fs.cwd().realpathAlloc(allocator, path);
}

fn isIndexedExtension(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".zig") or
        isNativeExtension(path) or
        std.mem.endsWith(u8, path, ".comp") or
        std.mem.endsWith(u8, path, ".sigil") or
        isSymbolicExtension(path);
}

fn isSymbolicExtension(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".md") or
        std.mem.endsWith(u8, path, ".txt") or
        std.mem.endsWith(u8, path, ".rst") or
        std.mem.endsWith(u8, path, ".toml") or
        std.mem.endsWith(u8, path, ".yaml") or
        std.mem.endsWith(u8, path, ".yml") or
        std.mem.endsWith(u8, path, ".json") or
        std.mem.endsWith(u8, path, ".ini") or
        std.mem.endsWith(u8, path, ".cfg") or
        std.mem.endsWith(u8, path, ".conf") or
        std.mem.endsWith(u8, path, ".env") or
        std.mem.endsWith(u8, path, ".xml") or
        std.mem.endsWith(u8, path, ".html") or
        std.mem.endsWith(u8, path, ".rules") or
        std.mem.endsWith(u8, path, ".dsl");
}

fn isNativeExtension(path: []const u8) bool {
    return isNativeHeaderPath(path) or
        std.mem.endsWith(u8, path, ".c") or
        std.mem.endsWith(u8, path, ".cc") or
        std.mem.endsWith(u8, path, ".cpp") or
        std.mem.endsWith(u8, path, ".cxx");
}

fn isNativeHeaderPath(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".h") or
        std.mem.endsWith(u8, path, ".hh") or
        std.mem.endsWith(u8, path, ".hpp") or
        std.mem.endsWith(u8, path, ".hxx");
}

fn shouldSkipWalkPath(path: []const u8) bool {
    const base = std.fs.path.basename(path);
    if (std.mem.eql(u8, base, ".git")) return true;
    if (std.mem.eql(u8, base, ".zig-cache")) return true;
    if (std.mem.eql(u8, base, "zig-out")) return true;
    if (std.mem.eql(u8, base, "state")) return true;
    return false;
}

fn classifySubsystem(path: []const u8) Subsystem {
    if (std.mem.startsWith(u8, path, "src/shell")) return .shell;
    if (std.mem.startsWith(u8, path, "src/sigil")) return .sigil;
    if (std.mem.startsWith(u8, path, "src/sys/")) return .sys;
    if (std.mem.startsWith(u8, path, "src/vsa")) return .vsa;
    if (std.mem.startsWith(u8, path, "src/shaders/")) return .shader;
    if (std.mem.startsWith(u8, path, "src/inference")) return .inference;
    if (std.mem.startsWith(u8, path, "src/engine")) return .engine;
    if (std.mem.startsWith(u8, path, "src/trainer")) return .trainer;
    if (std.mem.startsWith(u8, path, "src/config")) return .config;
    if (std.mem.startsWith(u8, path, "tools/")) return .tools;
    if (std.mem.startsWith(u8, path, "platforms/")) return .platform;
    if (std.mem.startsWith(u8, path, "docs/")) return .docs;
    if (std.mem.startsWith(u8, path, "src/api/")) return .api;
    if (std.mem.startsWith(u8, path, "src/app/")) return .app;
    if (std.mem.startsWith(u8, path, "src/cli/")) return .cli;
    if (std.mem.startsWith(u8, path, "src/reason")) return .reasoning;
    if (std.mem.startsWith(u8, path, "src/test")) return .tests;
    return .other;
}

fn subsystemName(value: Subsystem) []const u8 {
    return switch (value) {
        .api => "api",
        .app => "app",
        .cli => "cli",
        .config => "config",
        .docs => "docs",
        .engine => "engine",
        .inference => "inference",
        .platform => "platform",
        .reasoning => "reasoning",
        .shell => "shell",
        .shader => "shader",
        .sigil => "sigil",
        .sys => "sys",
        .tests => "tests",
        .tools => "tools",
        .trainer => "trainer",
        .vsa => "vsa",
        .other => "other",
    };
}

fn parseSubsystem(text: []const u8) ?Subsystem {
    inline for (std.meta.fields(Subsystem)) |field| {
        if (std.mem.eql(u8, text, field.name)) return @field(Subsystem, field.name);
    }
    return null;
}

fn declKindName(kind: DeclKind) []const u8 {
    return switch (kind) {
        .function => "function",
        .constant => "constant",
        .variable => "variable",
        .module => "module",
        .type => "type",
        .symbolic_unit => "symbolic_unit",
    };
}

fn parseDeclKind(text: []const u8) ?DeclKind {
    inline for (std.meta.fields(DeclKind)) |field| {
        if (std.mem.eql(u8, text, field.name)) return @field(DeclKind, field.name);
    }
    return null;
}

fn declRoleName(role: DeclRole) []const u8 {
    return switch (role) {
        .declaration => "declaration",
        .definition => "definition",
        .declaration_and_definition => "declaration_and_definition",
    };
}

fn parseDeclRole(text: []const u8) ?DeclRole {
    inline for (std.meta.fields(DeclRole)) |field| {
        if (std.mem.eql(u8, text, field.name)) return @field(DeclRole, field.name);
    }
    return null;
}

fn dependencyKindName(kind: DependencyKind) []const u8 {
    return switch (kind) {
        .import => "import",
        .include => "include",
        .companion => "companion",
    };
}

fn parseDependencyKind(text: []const u8) ?DependencyKind {
    inline for (std.meta.fields(DependencyKind)) |field| {
        if (std.mem.eql(u8, text, field.name)) return @field(DependencyKind, field.name);
    }
    return null;
}

fn semanticEdgeKindName(kind: SemanticEdgeKind) []const u8 {
    return switch (kind) {
        .symbol_ref => "symbol_ref",
        .call => "call",
        .signature_type => "signature_type",
        .annotation_type => "annotation_type",
        .declaration_pair => "declaration_pair",
        .structural_hint => "structural_hint",
    };
}

fn parseSemanticEdgeKind(text: []const u8) ?SemanticEdgeKind {
    inline for (std.meta.fields(SemanticEdgeKind)) |field| {
        if (std.mem.eql(u8, text, field.name)) return @field(SemanticEdgeKind, field.name);
    }
    return null;
}

fn resolveImportPathForOwner(
    allocator: std.mem.Allocator,
    owner_rel: []const u8,
    import_text: []const u8,
) ![]u8 {
    if (std.mem.eql(u8, import_text, "ghost_core")) return allocator.dupe(u8, "src/ghost.zig");
    if (!std.mem.endsWith(u8, import_text, ".zig") and !std.mem.endsWith(u8, import_text, ".comp") and !std.mem.endsWith(u8, import_text, ".sigil")) {
        return error.UnsupportedImport;
    }
    const owner_dir = std.fs.path.dirname(owner_rel) orelse ".";
    return std.fs.path.resolve(allocator, &.{ owner_dir, import_text });
}

fn parseNativeCachedFileRecord(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    scan_entries: []const RepoScanEntry,
    entry: RepoScanEntry,
) !CachedFileRecord {
    const file = try std.fs.openFileAbsolute(entry.abs_path, .{});
    defer file.close();

    const source = try file.readToEndAlloc(allocator, MAX_INDEXED_FILE_BYTES);
    defer allocator.free(source);

    var record = CachedFileRecord.init(
        allocator,
        try allocator.dupe(u8, entry.rel_path),
        classifySubsystem(entry.rel_path),
        entry.size_bytes,
        entry.mtime_ns,
    );
    errdefer record.deinit();
    record.content_hash = std.hash.Fnv1a_64.hash(source);

    try collectNativeIncludeEdges(allocator, &record, repo_root, scan_entries, source);

    var tokens = try tokenizeNativeSource(allocator, source);
    defer tokens.deinit();

    for (tokens.items) |token| {
        if (token.tag != .identifier) continue;
        if (isIgnoredNativeIdentifier(token.text)) continue;
        try record.references.append(.{
            .name = try allocator.dupe(u8, token.text),
            .line = token.line,
        });
    }

    try parseNativeScope(&record, tokens.items, "", false);
    return record;
}

fn collectNativeIncludeEdges(
    allocator: std.mem.Allocator,
    record: *CachedFileRecord,
    repo_root: []const u8,
    scan_entries: []const RepoScanEntry,
    source: []const u8,
) !void {
    var in_block_comment = false;
    var line_number: u32 = 1;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| : (line_number += 1) {
        const stripped = try stripNativeCommentsFromLineAlloc(allocator, raw_line, &in_block_comment);
        defer allocator.free(stripped);

        var line = std.mem.trim(u8, stripped, " \t\r");
        if (line.len == 0 or line[0] != '#') continue;
        line = std.mem.trimLeft(u8, line[1..], " \t");
        if (!std.mem.startsWith(u8, line, "include")) continue;
        line = std.mem.trimLeft(u8, line["include".len..], " \t");
        if (line.len < 3) continue;

        var quoted = false;
        var include_text: []const u8 = "";
        if (line[0] == '"') {
            const end = std.mem.indexOfScalar(u8, line[1..], '"') orelse continue;
            include_text = line[1 .. end + 1];
            quoted = true;
        } else if (line[0] == '<') {
            const end = std.mem.indexOfScalar(u8, line[1..], '>') orelse continue;
            include_text = line[1 .. end + 1];
        } else continue;

        const resolved = resolveNativeIncludePath(allocator, repo_root, scan_entries, record.rel_path, include_text, quoted) orelse continue;
        try putOwnedImportEdge(record, resolved, line_number, .include);
    }
}

fn tokenizeNativeSource(allocator: std.mem.Allocator, source: []const u8) !std.ArrayList(NativeToken) {
    var tokens = std.ArrayList(NativeToken).init(allocator);
    errdefer tokens.deinit();

    var i: usize = 0;
    var line: u32 = 1;
    while (i < source.len) {
        const byte = source[i];
        switch (byte) {
            ' ', '\t', '\r' => i += 1,
            '\n' => {
                line += 1;
                i += 1;
            },
            '/' => {
                if (i + 1 < source.len and source[i + 1] == '/') {
                    i += 2;
                    while (i < source.len and source[i] != '\n') : (i += 1) {}
                } else if (i + 1 < source.len and source[i + 1] == '*') {
                    i += 2;
                    while (i + 1 < source.len) : (i += 1) {
                        if (source[i] == '\n') line += 1;
                        if (source[i] == '*' and source[i + 1] == '/') {
                            i += 2;
                            break;
                        }
                    }
                } else {
                    i += 1;
                }
            },
            '"' => {
                const start = i + 1;
                i += 1;
                var escaped = false;
                while (i < source.len) : (i += 1) {
                    const ch = source[i];
                    if (ch == '\n') line += 1;
                    if (ch == '"' and !escaped) break;
                    escaped = ch == '\\' and !escaped;
                    if (ch != '\\') escaped = false;
                }
                if (i >= source.len) break;
                try tokens.append(.{ .tag = .string_lit, .text = source[start..i], .line = line });
                i += 1;
            },
            '\'' => {
                const start = i + 1;
                i += 1;
                var escaped = false;
                while (i < source.len) : (i += 1) {
                    const ch = source[i];
                    if (ch == '\n') line += 1;
                    if (ch == '\'' and !escaped) break;
                    escaped = ch == '\\' and !escaped;
                    if (ch != '\\') escaped = false;
                }
                if (i >= source.len) break;
                try tokens.append(.{ .tag = .char_lit, .text = source[start..i], .line = line });
                i += 1;
            },
            else => {
                if (isIdentifierStart(byte)) {
                    const start = i;
                    i += 1;
                    while (i < source.len and isIdentifierContinue(source[i])) : (i += 1) {}
                    try tokens.append(.{ .tag = .identifier, .text = source[start..i], .line = line });
                    continue;
                }

                if (byte == ':' and i + 1 < source.len and source[i + 1] == ':') {
                    try tokens.append(.{ .tag = .coloncolon, .text = source[i .. i + 2], .line = line });
                    i += 2;
                    continue;
                }
                if (byte == '-' and i + 1 < source.len and source[i + 1] == '>') {
                    try tokens.append(.{ .tag = .arrow, .text = source[i .. i + 2], .line = line });
                    i += 2;
                    continue;
                }

                const tag: NativeTokenTag = switch (byte) {
                    '(' => .l_paren,
                    ')' => .r_paren,
                    '{' => .l_brace,
                    '}' => .r_brace,
                    '[' => .l_bracket,
                    ']' => .r_bracket,
                    ',' => .comma,
                    ':' => .colon,
                    ';' => .semicolon,
                    '.' => .dot,
                    '=' => .eq,
                    '#' => .hash,
                    '~' => .tilde,
                    else => .other,
                };
                try tokens.append(.{ .tag = tag, .text = source[i .. i + 1], .line = line });
                i += 1;
            },
        }
    }

    return tokens;
}

fn parseNativeScope(
    record: *CachedFileRecord,
    tokens: []const NativeToken,
    scope_prefix: []const u8,
    in_type_scope: bool,
) anyerror!void {
    var i: usize = 0;
    while (i < tokens.len) {
        if (in_type_scope and isNativeAccessSpecifier(tokens, i)) {
            i += 2;
            continue;
        }
        if (tokens[i].tag != .identifier) {
            i += 1;
            continue;
        }
        if (i > 0 and tokens[i - 1].tag == .hash) {
            i += 1;
            continue;
        }

        if (std.mem.eql(u8, tokens[i].text, "namespace")) {
            const consumed = try parseNativeNamespace(record, tokens[i..], scope_prefix);
            i += @max(consumed, 1);
            continue;
        }
        if (isNativeTypeKeyword(tokens[i].text)) {
            const consumed = try parseNativeType(record, tokens[i..], scope_prefix);
            i += @max(consumed, 1);
            continue;
        }
        if (std.mem.eql(u8, tokens[i].text, "using")) {
            const consumed = try parseNativeUsingAlias(record, tokens[i..], scope_prefix);
            i += @max(consumed, 1);
            continue;
        }
        if (std.mem.eql(u8, tokens[i].text, "typedef")) {
            const consumed = try parseNativeTypedef(record, tokens[i..], scope_prefix);
            i += @max(consumed, 1);
            continue;
        }

        const consumed = try parseNativeStatement(record, tokens[i..], scope_prefix, in_type_scope);
        i += @max(consumed, 1);
    }
}

fn parseNativeNamespace(record: *CachedFileRecord, tokens: []const NativeToken, scope_prefix: []const u8) anyerror!usize {
    if (tokens.len < 2) return 1;

    var body_start: ?usize = null;
    var name: ?[]const u8 = null;
    if (tokens[1].tag == .identifier) {
        name = tokens[1].text;
        const boundary = findNativeDeclBoundary(tokens, 2) orelse return 2;
        if (boundary.kind != .body) return boundary.index + 1;
        body_start = boundary.index;
    } else if (tokens[1].tag == .l_brace) {
        body_start = 1;
    } else return 1;

    const start = body_start.?;
    const body_end = findMatchingNativeToken(tokens, start, .l_brace, .r_brace) orelse return start + 1;
    const child_prefix = if (name) |named|
        try joinScopePrefix(record.allocator, scope_prefix, named)
    else
        try record.allocator.dupe(u8, scope_prefix);
    defer record.allocator.free(child_prefix);

    try parseNativeScope(record, tokens[start + 1 .. body_end], child_prefix, false);
    return advancePastNativeScope(tokens, body_end);
}

fn parseNativeType(record: *CachedFileRecord, tokens: []const NativeToken, scope_prefix: []const u8) anyerror!usize {
    if (tokens.len < 2) return 1;

    var cursor: usize = 1;
    if (std.mem.eql(u8, tokens[0].text, "enum") and cursor < tokens.len and tokens[cursor].tag == .identifier and std.mem.eql(u8, tokens[cursor].text, "class")) {
        cursor += 1;
    }
    while (cursor < tokens.len and tokens[cursor].tag != .identifier and tokens[cursor].tag != .l_brace and tokens[cursor].tag != .semicolon) : (cursor += 1) {}
    if (cursor >= tokens.len or tokens[cursor].tag != .identifier) return 1;

    const boundary = findNativeDeclBoundary(tokens, cursor + 1) orelse return cursor + 1;
    const qualified_name = try joinScopePrefix(record.allocator, scope_prefix, tokens[cursor].text);
    defer record.allocator.free(qualified_name);

    try appendCachedDecl(record, qualified_name, tokens[cursor].line, .type, true, if (boundary.kind == .body) .definition else .declaration);

    if (boundary.kind != .body or std.mem.eql(u8, tokens[0].text, "enum")) {
        return boundary.index + 1;
    }

    const body_end = findMatchingNativeToken(tokens, boundary.index, .l_brace, .r_brace) orelse return boundary.index + 1;
    const child_prefix = try joinScopePrefix(record.allocator, scope_prefix, tokens[cursor].text);
    defer record.allocator.free(child_prefix);
    try parseNativeScope(record, tokens[boundary.index + 1 .. body_end], child_prefix, true);
    return advancePastNativeScope(tokens, body_end);
}

fn parseNativeUsingAlias(record: *CachedFileRecord, tokens: []const NativeToken, scope_prefix: []const u8) anyerror!usize {
    if (tokens.len < 4 or tokens[1].tag != .identifier) return 1;
    const end = findNativeTopLevelToken(tokens, .semicolon) orelse return 1;
    const eq_index = findNativeTopLevelToken(tokens[0..end], .eq) orelse return end + 1;

    const qualified_name = try joinScopePrefix(record.allocator, scope_prefix, tokens[1].text);
    defer record.allocator.free(qualified_name);
    try appendCachedDecl(record, qualified_name, tokens[1].line, .type, true, .definition);
    try collectNativeTypeUses(record, tokens[eq_index + 1 .. end], tokens[1].line, .annotation_type);
    return end + 1;
}

fn parseNativeTypedef(record: *CachedFileRecord, tokens: []const NativeToken, scope_prefix: []const u8) anyerror!usize {
    const end = findNativeTopLevelToken(tokens, .semicolon) orelse return 1;
    var name_idx: ?usize = null;
    var idx = end;
    while (idx > 0) : (idx -= 1) {
        const current = idx - 1;
        if (tokens[current].tag == .identifier and !isIgnoredNativeIdentifier(tokens[current].text)) {
            name_idx = current;
            break;
        }
    }
    if (name_idx == null or name_idx.? == 0) return end + 1;

    const qualified_name = try joinScopePrefix(record.allocator, scope_prefix, tokens[name_idx.?].text);
    defer record.allocator.free(qualified_name);
    try appendCachedDecl(record, qualified_name, tokens[name_idx.?].line, .type, true, .definition);
    try collectNativeTypeUses(record, tokens[1..name_idx.?], tokens[name_idx.?].line, .annotation_type);
    return end + 1;
}

fn parseNativeStatement(
    record: *CachedFileRecord,
    tokens: []const NativeToken,
    scope_prefix: []const u8,
    in_type_scope: bool,
) anyerror!usize {
    const boundary = findNativeDeclBoundary(tokens, 0) orelse return tokens.len;
    if (try parseNativeFunction(record, tokens, scope_prefix, in_type_scope, boundary)) |consumed| return consumed;
    if (boundary.kind == .semicolon) {
        if (try parseNativeVariable(record, tokens[0 .. boundary.index + 1], scope_prefix, in_type_scope)) return boundary.index + 1;
    }
    return switch (boundary.kind) {
        .semicolon => boundary.index + 1,
        .body => blk: {
            const body_end = findMatchingNativeToken(tokens, boundary.index, .l_brace, .r_brace) orelse break :blk boundary.index + 1;
            break :blk advancePastNativeScope(tokens, body_end);
        },
    };
}

fn parseNativeFunction(
    record: *CachedFileRecord,
    tokens: []const NativeToken,
    scope_prefix: []const u8,
    in_type_scope: bool,
    boundary: NativeDeclBoundary,
) anyerror!?usize {
    const limit = boundary.index;
    const l_paren = findNativeTopLevelTokenBefore(tokens, .l_paren, limit) orelse return null;
    if (l_paren == 0) return null;
    const r_paren = findMatchingNativeToken(tokens, l_paren, .l_paren, .r_paren) orelse return null;

    const name_end = findNativeFunctionNameIndex(tokens, l_paren) orelse return null;
    if (isNativeControlIdentifier(tokens[name_end].text)) return null;

    const name_start = findNativeQualifiedNameStart(tokens, name_end);
    const qualified_name = try buildNativeQualifiedName(record.allocator, scope_prefix, tokens[name_start .. name_end + 1]);
    defer record.allocator.free(qualified_name);

    try appendCachedDecl(
        record,
        qualified_name,
        tokens[name_end].line,
        .function,
        !in_type_scope,
        if (boundary.kind == .body) .definition else .declaration,
    );

    try collectNativeTypeUses(record, tokens[0..name_start], tokens[name_end].line, .signature_type);
    try collectNativeTypeUses(record, tokens[l_paren + 1 .. r_paren], tokens[name_end].line, .signature_type);
    if (findNativeTopLevelToken(tokens[r_paren + 1 .. limit], .arrow)) |arrow_rel| {
        const arrow = r_paren + 1 + arrow_rel;
        try collectNativeTypeUses(record, tokens[arrow + 1 .. limit], tokens[name_end].line, .signature_type);
    }

    if (boundary.kind == .body) {
        const body_end = findMatchingNativeToken(tokens, boundary.index, .l_brace, .r_brace) orelse return boundary.index + 1;
        try collectNativeBodyUses(record, tokens[boundary.index + 1 .. body_end], tokens[name_end].line);
        return advancePastNativeScope(tokens, body_end);
    }

    return boundary.index + 1;
}

fn parseNativeVariable(
    record: *CachedFileRecord,
    tokens: []const NativeToken,
    scope_prefix: []const u8,
    in_type_scope: bool,
) anyerror!bool {
    if (in_type_scope) return false;
    if (findNativeTopLevelToken(tokens, .l_paren) != null) return false;
    if (tokens.len < 2) return false;

    const eq_index = findNativeTopLevelToken(tokens, .eq) orelse tokens.len - 1;
    var name_idx: ?usize = null;
    var idx = eq_index;
    while (idx > 0) : (idx -= 1) {
        const current = idx - 1;
        if (tokens[current].tag == .identifier and !isIgnoredNativeIdentifier(tokens[current].text)) {
            name_idx = current;
            break;
        }
    }
    if (name_idx == null or name_idx.? == 0) return false;

    const qualified_name = try joinScopePrefix(record.allocator, scope_prefix, tokens[name_idx.?].text);
    defer record.allocator.free(qualified_name);
    const kind: DeclKind = if (containsNativeKeyword(tokens, "const") or containsNativeKeyword(tokens, "constexpr")) .constant else .variable;
    const role: DeclRole = if (containsNativeKeyword(tokens, "extern") and findNativeTopLevelToken(tokens, .eq) == null) .declaration else .definition;
    try appendCachedDecl(record, qualified_name, tokens[name_idx.?].line, kind, true, role);
    try collectNativeTypeUses(record, tokens[0..name_idx.?], tokens[name_idx.?].line, .annotation_type);
    return true;
}

fn appendCachedDecl(
    record: *CachedFileRecord,
    name: []const u8,
    line: u32,
    kind: DeclKind,
    is_pub: bool,
    role: DeclRole,
) anyerror!void {
    try record.declarations.append(.{
        .name = try record.allocator.dupe(u8, name),
        .line = line,
        .kind = kind,
        .is_pub = is_pub,
        .role = role,
    });
}

fn collectNativeTypeUses(record: *CachedFileRecord, tokens: []const NativeToken, owner_line: u32, kind: SemanticEdgeKind) anyerror!void {
    var i: usize = 0;
    while (i < tokens.len) {
        if (tokens[i].tag != .identifier or isIgnoredNativeTypeIdentifier(tokens[i].text)) {
            i += 1;
            continue;
        }
        const path_len = nativePathExpressionLength(tokens[i..]);
        if (path_len == 0) {
            i += 1;
            continue;
        }
        const raw_symbol = try joinNativePathTokens(record.allocator, tokens[i .. i + path_len]);
        defer record.allocator.free(raw_symbol);
        try appendDeferredEdge(record, raw_symbol, tokens[i].line, owner_line, kind);
        i += path_len;
    }
}

fn collectNativeBodyUses(record: *CachedFileRecord, tokens: []const NativeToken, owner_line: u32) anyerror!void {
    var i: usize = 0;
    while (i < tokens.len) {
        if (tokens[i].tag != .identifier or isIgnoredNativeIdentifier(tokens[i].text)) {
            i += 1;
            continue;
        }
        if (i > 0 and (tokens[i - 1].tag == .dot or tokens[i - 1].tag == .arrow)) {
            i += 1;
            continue;
        }
        const path_len = nativePathExpressionLength(tokens[i..]);
        if (path_len == 0) {
            i += 1;
            continue;
        }
        const raw_symbol = try joinNativePathTokens(record.allocator, tokens[i .. i + path_len]);
        defer record.allocator.free(raw_symbol);
        const edge_kind: SemanticEdgeKind = if (i + path_len < tokens.len and tokens[i + path_len].tag == .l_paren) .call else .symbol_ref;
        try appendDeferredEdge(record, raw_symbol, tokens[i].line, owner_line, edge_kind);
        i += path_len;
    }
}

fn appendDeferredEdge(
    record: *CachedFileRecord,
    raw_symbol: []const u8,
    line: u32,
    owner_line: u32,
    kind: SemanticEdgeKind,
) anyerror!void {
    for (record.deferred_edges.items) |existing| {
        if (existing.line == line and existing.owner_line == owner_line and existing.kind == kind and std.mem.eql(u8, existing.raw_symbol, raw_symbol)) return;
    }
    try record.deferred_edges.append(.{
        .raw_symbol = try record.allocator.dupe(u8, raw_symbol),
        .line = line,
        .owner_line = owner_line,
        .kind = kind,
    });
}

fn stripNativeCommentsFromLineAlloc(allocator: std.mem.Allocator, line: []const u8, in_block_comment: *bool) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();

    var in_string = false;
    var in_char = false;
    var escaped = false;
    var i: usize = 0;
    while (i < line.len) {
        if (in_block_comment.*) {
            if (i + 1 < line.len and line[i] == '*' and line[i + 1] == '/') {
                in_block_comment.* = false;
                i += 2;
            } else i += 1;
            continue;
        }
        if (!in_string and !in_char and i + 1 < line.len and line[i] == '/' and line[i + 1] == '/') break;
        if (!in_string and !in_char and i + 1 < line.len and line[i] == '/' and line[i + 1] == '*') {
            in_block_comment.* = true;
            i += 2;
            continue;
        }

        const ch = line[i];
        try out.append(ch);
        if (ch == '"' and !in_char and !escaped) in_string = !in_string;
        if (ch == '\'' and !in_string and !escaped) in_char = !in_char;
        escaped = ch == '\\' and !escaped;
        if (ch != '\\') escaped = false;
        i += 1;
    }

    return out.toOwnedSlice();
}

fn resolveNativeIncludePath(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    scan_entries: []const RepoScanEntry,
    owner_rel: []const u8,
    include_text: []const u8,
    quoted: bool,
) ?[]u8 {
    const owner_dir = std.fs.path.dirname(owner_rel) orelse ".";
    if (quoted) {
        const relative = std.fs.path.resolve(allocator, &.{ owner_dir, include_text }) catch return null;
        defer allocator.free(relative);
        if (scanEntriesContainPath(scan_entries, relative)) return allocator.dupe(u8, relative) catch null;
    }
    if (scanEntriesContainPath(scan_entries, include_text)) return allocator.dupe(u8, include_text) catch null;

    const rooted_abs = std.fs.path.resolve(allocator, &.{ repo_root, include_text }) catch return null;
    defer allocator.free(rooted_abs);
    const rooted_rel = std.fs.path.relative(allocator, repo_root, rooted_abs) catch return null;
    defer allocator.free(rooted_rel);
    if (scanEntriesContainPath(scan_entries, rooted_rel)) return allocator.dupe(u8, rooted_rel) catch null;

    return findUniqueScanPathBySuffix(allocator, scan_entries, include_text);
}

fn scanEntriesContainPath(scan_entries: []const RepoScanEntry, rel_path: []const u8) bool {
    for (scan_entries) |entry| {
        if (std.mem.eql(u8, entry.rel_path, rel_path)) return true;
    }
    return false;
}

fn findUniqueScanPathBySuffix(allocator: std.mem.Allocator, scan_entries: []const RepoScanEntry, suffix: []const u8) ?[]u8 {
    var found: ?[]const u8 = null;
    const basename = std.fs.path.basename(suffix);
    for (scan_entries) |entry| {
        if (!std.mem.endsWith(u8, entry.rel_path, suffix) and !std.mem.eql(u8, std.fs.path.basename(entry.rel_path), basename)) continue;
        if (found != null) return null;
        found = entry.rel_path;
    }
    if (found) |path| return allocator.dupe(u8, path) catch null;
    return null;
}

fn isNativeAccessSpecifier(tokens: []const NativeToken, index: usize) bool {
    if (index + 1 >= tokens.len) return false;
    if (tokens[index].tag != .identifier or tokens[index + 1].tag != .colon) return false;
    return std.mem.eql(u8, tokens[index].text, "public") or
        std.mem.eql(u8, tokens[index].text, "protected") or
        std.mem.eql(u8, tokens[index].text, "private");
}

fn isNativeTypeKeyword(text: []const u8) bool {
    return std.mem.eql(u8, text, "struct") or
        std.mem.eql(u8, text, "class") or
        std.mem.eql(u8, text, "union") or
        std.mem.eql(u8, text, "enum");
}

fn containsNativeKeyword(tokens: []const NativeToken, keyword: []const u8) bool {
    for (tokens) |token| {
        if (token.tag == .identifier and std.mem.eql(u8, token.text, keyword)) return true;
    }
    return false;
}

fn advancePastNativeScope(tokens: []const NativeToken, body_end: usize) usize {
    var consumed = body_end + 1;
    if (consumed < tokens.len and tokens[consumed].tag == .semicolon) consumed += 1;
    return consumed;
}

fn buildNativeQualifiedName(allocator: std.mem.Allocator, scope_prefix: []const u8, tokens: []const NativeToken) ![]u8 {
    const joined = try joinNativePathTokens(allocator, tokens);
    defer allocator.free(joined);
    if (scope_prefix.len == 0) return allocator.dupe(u8, joined);
    return std.fmt.allocPrint(allocator, "{s}::{s}", .{ scope_prefix, joined });
}

fn joinScopePrefix(allocator: std.mem.Allocator, prefix: []const u8, name: []const u8) ![]u8 {
    if (prefix.len == 0) return allocator.dupe(u8, name);
    return std.fmt.allocPrint(allocator, "{s}::{s}", .{ prefix, name });
}

fn joinNativePathTokens(allocator: std.mem.Allocator, tokens: []const NativeToken) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    for (tokens, 0..) |token, idx| {
        if (token.tag == .coloncolon) {
            try out.appendSlice("::");
            continue;
        }
        if (token.tag == .tilde) {
            try out.append('~');
            continue;
        }
        if (token.tag != .identifier) continue;
        if (idx != 0 and tokens[idx - 1].tag != .coloncolon and tokens[idx - 1].tag != .tilde) break;
        try out.appendSlice(token.text);
    }
    return out.toOwnedSlice();
}

fn findNativeDeclBoundary(tokens: []const NativeToken, start: usize) ?NativeDeclBoundary {
    var paren_depth: u32 = 0;
    var bracket_depth: u32 = 0;
    var brace_depth: u32 = 0;
    var i = start;
    while (i < tokens.len) : (i += 1) {
        switch (tokens[i].tag) {
            .l_paren => paren_depth += 1,
            .r_paren => {
                if (paren_depth > 0) paren_depth -= 1;
            },
            .l_bracket => bracket_depth += 1,
            .r_bracket => {
                if (bracket_depth > 0) bracket_depth -= 1;
            },
            .l_brace => {
                if (paren_depth == 0 and bracket_depth == 0 and brace_depth == 0) return .{ .kind = .body, .index = i };
                brace_depth += 1;
            },
            .r_brace => {
                if (brace_depth > 0) brace_depth -= 1;
            },
            .semicolon => {
                if (paren_depth == 0 and bracket_depth == 0 and brace_depth == 0) return .{ .kind = .semicolon, .index = i };
            },
            else => {},
        }
    }
    return null;
}

fn findNativeTopLevelToken(tokens: []const NativeToken, tag: NativeTokenTag) ?usize {
    return findNativeTopLevelTokenBefore(tokens, tag, tokens.len);
}

fn findNativeTopLevelTokenBefore(tokens: []const NativeToken, tag: NativeTokenTag, limit: usize) ?usize {
    var paren_depth: u32 = 0;
    var bracket_depth: u32 = 0;
    var brace_depth: u32 = 0;
    for (tokens[0..limit], 0..) |token, idx| {
        if (paren_depth == 0 and bracket_depth == 0 and brace_depth == 0 and token.tag == tag) return idx;
        switch (token.tag) {
            .l_paren => paren_depth += 1,
            .r_paren => {
                if (paren_depth > 0) paren_depth -= 1;
            },
            .l_bracket => bracket_depth += 1,
            .r_bracket => {
                if (bracket_depth > 0) bracket_depth -= 1;
            },
            .l_brace => brace_depth += 1,
            .r_brace => {
                if (brace_depth > 0) brace_depth -= 1;
            },
            else => {},
        }
    }
    return null;
}

fn findMatchingNativeToken(tokens: []const NativeToken, start: usize, open: NativeTokenTag, close: NativeTokenTag) ?usize {
    var depth: u32 = 0;
    var i = start;
    while (i < tokens.len) : (i += 1) {
        if (tokens[i].tag == open) depth += 1;
        if (tokens[i].tag == close) {
            if (depth == 0) return null;
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

fn findNativeFunctionNameIndex(tokens: []const NativeToken, l_paren: usize) ?usize {
    var i = l_paren;
    while (i > 0) : (i -= 1) {
        const current = i - 1;
        if (tokens[current].tag == .identifier) return current;
        if (tokens[current].tag == .semicolon or tokens[current].tag == .l_brace) break;
    }
    return null;
}

fn findNativeQualifiedNameStart(tokens: []const NativeToken, name_end: usize) usize {
    var start = name_end;
    while (start > 0) {
        if (tokens[start - 1].tag == .tilde) {
            start -= 1;
            continue;
        }
        if (start >= 2 and tokens[start - 1].tag == .coloncolon and tokens[start - 2].tag == .identifier) {
            start -= 2;
            continue;
        }
        break;
    }
    return start;
}

fn nativePathExpressionLength(tokens: []const NativeToken) usize {
    if (tokens.len == 0 or tokens[0].tag != .identifier) return 0;
    var i: usize = 1;
    while (i + 1 < tokens.len and tokens[i].tag == .coloncolon and tokens[i + 1].tag == .identifier) : (i += 2) {}
    return i;
}

fn isNativeControlIdentifier(text: []const u8) bool {
    return std.mem.eql(u8, text, "if") or
        std.mem.eql(u8, text, "for") or
        std.mem.eql(u8, text, "while") or
        std.mem.eql(u8, text, "switch") or
        std.mem.eql(u8, text, "catch") or
        std.mem.eql(u8, text, "return") or
        std.mem.eql(u8, text, "sizeof") or
        std.mem.eql(u8, text, "alignof");
}

fn attachCompanionEdges(allocator: std.mem.Allocator, index: *RepoIndex) !void {
    _ = allocator;
    for (index.files.items, 0..) |lhs, lhs_idx| {
        if (!isNativeExtension(lhs.rel_path)) continue;
        for (index.files.items[lhs_idx + 1 ..], lhs_idx + 1..) |rhs, rhs_idx| {
            if (!isNativeExtension(rhs.rel_path)) continue;
            if (!sameNativeStem(lhs.rel_path, rhs.rel_path)) continue;
            if (isNativeHeaderPath(lhs.rel_path) == isNativeHeaderPath(rhs.rel_path)) continue;
            try appendDependencyUnique(&index.files.items[lhs_idx].imports, .{
                .file_index = @intCast(rhs_idx),
                .line = 0,
                .kind = .companion,
            });
            try appendDependencyUnique(&index.files.items[rhs_idx].imports, .{
                .file_index = @intCast(lhs_idx),
                .line = 0,
                .kind = .companion,
            });
        }
    }
}

fn resolveDeferredEdges(
    allocator: std.mem.Allocator,
    index: *RepoIndex,
    cached_file: CachedFileRecord,
    file_index: u32,
) !void {
    for (cached_file.deferred_edges.items) |edge| {
        const owner_decl_index = if (edge.owner_line == 0) null else findDeclarationByLine(index, file_index, edge.owner_line);
        const target_decl_index = try resolveDeferredEdgeTarget(allocator, index, file_index, owner_decl_index, edge.raw_symbol, edge.kind) orelse continue;
        try appendSemanticEdgeUnique(index, .{
            .kind = edge.kind,
            .source_file_index = file_index,
            .owner_decl_index = owner_decl_index,
            .target_decl_index = target_decl_index,
            .line = edge.line,
        });
    }
}

fn appendDeclarationPairs(index: *RepoIndex) !void {
    for (index.declarations.items, 0..) |decl, decl_idx_usize| {
        const decl_idx: u32 = @intCast(decl_idx_usize);
        if (!isNativeExtension(index.files.items[decl.file_index].rel_path)) continue;
        if (decl.role == .declaration_and_definition) continue;
        const paired = findPairedDeclaration(index, decl_idx) orelse continue;
        try appendSemanticEdgeUnique(index, .{
            .kind = .declaration_pair,
            .source_file_index = decl.file_index,
            .owner_decl_index = decl_idx,
            .target_decl_index = paired,
            .line = decl.line,
        });
        try appendSemanticEdgeUnique(index, .{
            .kind = .declaration_pair,
            .source_file_index = index.declarations.items[paired].file_index,
            .owner_decl_index = paired,
            .target_decl_index = decl_idx,
            .line = index.declarations.items[paired].line,
        });
    }
}

fn findPairedDeclaration(index: *const RepoIndex, decl_index: u32) ?u32 {
    const decl = index.declarations.items[decl_index];
    var best: ?u32 = null;
    var best_score: u32 = 0;
    var ambiguous = false;

    for (index.declarations.items, 0..) |candidate, candidate_idx_usize| {
        const candidate_idx: u32 = @intCast(candidate_idx_usize);
        if (candidate_idx == decl_index) continue;
        if (candidate.kind != decl.kind) continue;
        if (!std.mem.eql(u8, candidate.name, decl.name)) continue;
        if (candidate.file_index == decl.file_index) continue;
        if (!isOpposingRole(decl.role, candidate.role)) continue;

        const score = pairedDeclarationScore(index, decl.file_index, candidate.file_index);
        if (score == 0) continue;
        if (best == null or score > best_score) {
            best = candidate_idx;
            best_score = score;
            ambiguous = false;
        } else if (score == best_score) {
            ambiguous = true;
        }
    }

    if (ambiguous) return null;
    return best;
}

fn resolveDeferredEdgeTarget(
    allocator: std.mem.Allocator,
    index: *const RepoIndex,
    file_index: u32,
    owner_decl_index: ?u32,
    raw_symbol: []const u8,
    edge_kind: SemanticEdgeKind,
) !?u32 {
    var candidate_names = try buildResolutionNames(allocator, index, owner_decl_index, raw_symbol);
    defer {
        for (candidate_names.items) |name| allocator.free(name);
        candidate_names.deinit();
    }

    var best: ?u32 = null;
    var best_score: u32 = 0;
    var ambiguous = false;
    for (index.declarations.items, 0..) |decl, decl_idx_usize| {
        const decl_idx: u32 = @intCast(decl_idx_usize);
        const score = scoreDeferredTarget(index, file_index, decl_idx, decl, candidate_names.items, raw_symbol, edge_kind);
        if (score == 0) continue;
        if (best == null or score > best_score) {
            best = decl_idx;
            best_score = score;
            ambiguous = false;
        } else if (score == best_score) {
            ambiguous = true;
        }
    }

    if (ambiguous) return null;
    return best;
}

fn buildResolutionNames(
    allocator: std.mem.Allocator,
    index: *const RepoIndex,
    owner_decl_index: ?u32,
    raw_symbol: []const u8,
) !std.ArrayList([]u8) {
    var out = std.ArrayList([]u8).init(allocator);
    errdefer {
        for (out.items) |name| allocator.free(name);
        out.deinit();
    }
    try appendOwnedNameUnique(allocator, &out, raw_symbol);
    if (owner_decl_index) |owner_idx| {
        const owner = index.declarations.items[owner_idx].name;
        var scope_end = lastScopeSeparator(owner) orelse return out;
        while (true) {
            const prefix = owner[0..scope_end];
            const combined = try std.fmt.allocPrint(allocator, "{s}::{s}", .{ prefix, raw_symbol });
            try appendOwnedNameUniqueFromOwned(allocator, &out, combined);
            scope_end = lastScopeSeparator(prefix) orelse break;
        }
    }
    return out;
}

fn appendOwnedNameUnique(allocator: std.mem.Allocator, out: *std.ArrayList([]u8), text: []const u8) !void {
    const owned = try allocator.dupe(u8, text);
    errdefer allocator.free(owned);
    try appendOwnedNameUniqueFromOwned(allocator, out, owned);
}

fn appendOwnedNameUniqueFromOwned(allocator: std.mem.Allocator, out: *std.ArrayList([]u8), owned: []u8) !void {
    for (out.items) |existing| {
        if (std.mem.eql(u8, existing, owned)) {
            allocator.free(owned);
            return;
        }
    }
    try out.append(owned);
}

fn scoreDeferredTarget(
    index: *const RepoIndex,
    source_file_index: u32,
    decl_index: u32,
    decl: DeclRecord,
    candidate_names: []const []u8,
    raw_symbol: []const u8,
    edge_kind: SemanticEdgeKind,
) u32 {
    var name_score: u32 = 0;
    for (candidate_names) |candidate| {
        if (std.mem.eql(u8, decl.name, candidate)) {
            name_score = @max(name_score, 120);
        }
    }
    if (name_score == 0 and !std.mem.containsAtLeast(u8, raw_symbol, 1, "::")) {
        if (std.mem.eql(u8, nativeLeafName(decl.name), raw_symbol)) name_score = 60;
    }
    if (name_score == 0) return 0;

    const distance = dependencyDistance(index, source_file_index, decl.file_index);
    if (distance == 3 and name_score < 120) return 0;
    var score: u32 = switch (distance) {
        0 => 320,
        1 => 280,
        2 => 220,
        else => 140,
    };
    if (decl.role != .declaration) score += 20;
    if (edge_kind == .call and decl.kind == .function) score += 16;
    if (edge_kind != .call and decl.kind == .type) score += 12;
    score += name_score;
    _ = decl_index;
    return score;
}

fn pairedDeclarationScore(index: *const RepoIndex, file_index: u32, candidate_file_index: u32) u32 {
    if (dependencyDistance(index, file_index, candidate_file_index) == 1) return 220;
    if (dependencyDistance(index, file_index, candidate_file_index) == 2) return 160;
    return 0;
}

fn dependencyDistance(index: *const RepoIndex, source_file_index: u32, target_file_index: u32) u32 {
    if (source_file_index == target_file_index) return 0;
    const source = index.files.items[source_file_index];
    for (source.imports.items) |edge| {
        if (edge.file_index == target_file_index) return 1;
    }
    for (source.imports.items) |edge| {
        const mid = index.files.items[edge.file_index];
        for (mid.imports.items) |nested| {
            if (nested.file_index == target_file_index) return 2;
        }
    }
    return 3;
}

fn appendDependencyUnique(list: *std.ArrayList(ImportEdge), edge: ImportEdge) !void {
    for (list.items) |existing| {
        if (existing.file_index == edge.file_index and existing.kind == edge.kind) return;
    }
    try list.append(edge);
}

fn appendSemanticEdgeUnique(index: *RepoIndex, edge: SemanticEdge) !void {
    for (index.semantic_edges.items) |existing| {
        if (existing.kind == edge.kind and existing.source_file_index == edge.source_file_index and existing.owner_decl_index == edge.owner_decl_index and existing.target_decl_index == edge.target_decl_index and existing.line == edge.line) return;
    }
    try index.semantic_edges.append(edge);
}

fn isOpposingRole(lhs: DeclRole, rhs: DeclRole) bool {
    return switch (lhs) {
        .declaration => rhs == .definition or rhs == .declaration_and_definition,
        .definition => rhs == .declaration,
        .declaration_and_definition => rhs == .declaration,
    };
}

fn sameNativeStem(lhs: []const u8, rhs: []const u8) bool {
    return std.mem.eql(u8, nativeStem(lhs), nativeStem(rhs));
}

fn nativeStem(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    return path[0 .. path.len - ext.len];
}

fn nativeLeafName(name: []const u8) []const u8 {
    if (lastScopeSeparator(name)) |sep| return name[sep + 2 ..];
    return name;
}

fn symbolicLeafName(name: []const u8) []const u8 {
    const start = if (std.mem.indexOfScalar(u8, name, ':')) |idx| idx + 1 else 0;
    const tail = name[start..];
    if (std.mem.lastIndexOfScalar(u8, tail, '@')) |idx| return tail[0..idx];
    return tail;
}

fn lastScopeSeparator(text: []const u8) ?usize {
    var i = text.len;
    while (i > 1) : (i -= 1) {
        if (text[i - 2] == ':' and text[i - 1] == ':') return i - 2;
    }
    return null;
}

fn stripLineComment(line: []const u8) []const u8 {
    var in_string = false;
    var escaped = false;
    var i: usize = 0;
    while (i + 1 < line.len) : (i += 1) {
        const ch = line[i];
        if (ch == '"' and !escaped) in_string = !in_string;
        escaped = ch == '\\' and !escaped;
        if (!in_string and ch == '/' and line[i + 1] == '/') return line[0..i];
        if (ch != '\\') escaped = false;
    }
    return line;
}

fn braceDelta(line: []const u8) i32 {
    var delta: i32 = 0;
    var in_string = false;
    var escaped = false;
    for (line) |ch| {
        if (ch == '"' and !escaped) in_string = !in_string;
        if (in_string) {
            escaped = ch == '\\' and !escaped;
            if (ch != '\\') escaped = false;
            continue;
        }
        switch (ch) {
            '{' => delta += 1,
            '}' => delta -= 1,
            else => {},
        }
        escaped = false;
    }
    return delta;
}

fn parseTopLevelDecl(line: []const u8) ?ParsedDecl {
    var trimmed = std.mem.trimLeft(u8, line, " \t\r");
    var is_pub = false;
    if (std.mem.startsWith(u8, trimmed, "pub ")) {
        is_pub = true;
        trimmed = std.mem.trimLeft(u8, trimmed[4..], " \t");
    }
    if (std.mem.startsWith(u8, trimmed, "fn ")) {
        const name = parseIdent(trimmed[3..]) orelse return null;
        return .{ .name = name, .kind = .function, .is_pub = is_pub };
    }
    if (std.mem.startsWith(u8, trimmed, "const ")) {
        const rest = trimmed[6..];
        const name = parseIdent(rest) orelse return null;
        const eq = std.mem.indexOfScalar(u8, rest, '=') orelse return .{ .name = name, .kind = .constant, .is_pub = is_pub };
        const rhs = rest[eq + 1 ..];
        return .{
            .name = name,
            .kind = if (std.mem.indexOf(u8, rhs, "@import(") != null) .module else .constant,
            .is_pub = is_pub,
        };
    }
    if (std.mem.startsWith(u8, trimmed, "var ")) {
        const name = parseIdent(trimmed[4..]) orelse return null;
        return .{ .name = name, .kind = .variable, .is_pub = is_pub };
    }
    return null;
}

fn parseIdent(text: []const u8) ?[]const u8 {
    if (text.len == 0 or !isIdentifierStart(text[0])) return null;
    var end: usize = 1;
    while (end < text.len and isIdentifierContinue(text[end])) : (end += 1) {}
    return text[0..end];
}

fn isIdentifierStart(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '_';
}

fn isIdentifierContinue(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

fn isIgnoredIdentifier(token: []const u8) bool {
    return std.mem.eql(u8, token, "const") or
        std.mem.eql(u8, token, "var") or
        std.mem.eql(u8, token, "fn") or
        std.mem.eql(u8, token, "pub") or
        std.mem.eql(u8, token, "return") or
        std.mem.eql(u8, token, "if") or
        std.mem.eql(u8, token, "else") or
        std.mem.eql(u8, token, "while") or
        std.mem.eql(u8, token, "for") or
        std.mem.eql(u8, token, "switch") or
        std.mem.eql(u8, token, "try") or
        std.mem.eql(u8, token, "catch") or
        std.mem.eql(u8, token, "defer") or
        std.mem.eql(u8, token, "errdefer") or
        std.mem.eql(u8, token, "break") or
        std.mem.eql(u8, token, "continue") or
        std.mem.eql(u8, token, "struct") or
        std.mem.eql(u8, token, "enum") or
        std.mem.eql(u8, token, "union") or
        std.mem.eql(u8, token, "true") or
        std.mem.eql(u8, token, "false") or
        std.mem.eql(u8, token, "null") or
        std.mem.eql(u8, token, "undefined");
}

fn isIgnoredNativeIdentifier(token: []const u8) bool {
    return std.mem.eql(u8, token, "if") or
        std.mem.eql(u8, token, "else") or
        std.mem.eql(u8, token, "for") or
        std.mem.eql(u8, token, "while") or
        std.mem.eql(u8, token, "switch") or
        std.mem.eql(u8, token, "case") or
        std.mem.eql(u8, token, "break") or
        std.mem.eql(u8, token, "continue") or
        std.mem.eql(u8, token, "return") or
        std.mem.eql(u8, token, "class") or
        std.mem.eql(u8, token, "struct") or
        std.mem.eql(u8, token, "union") or
        std.mem.eql(u8, token, "enum") or
        std.mem.eql(u8, token, "template") or
        std.mem.eql(u8, token, "typename") or
        std.mem.eql(u8, token, "using") or
        std.mem.eql(u8, token, "typedef") or
        std.mem.eql(u8, token, "const") or
        std.mem.eql(u8, token, "constexpr") or
        std.mem.eql(u8, token, "static") or
        std.mem.eql(u8, token, "extern") or
        std.mem.eql(u8, token, "inline") or
        std.mem.eql(u8, token, "virtual") or
        std.mem.eql(u8, token, "override") or
        std.mem.eql(u8, token, "final") or
        std.mem.eql(u8, token, "public") or
        std.mem.eql(u8, token, "protected") or
        std.mem.eql(u8, token, "private") or
        std.mem.eql(u8, token, "namespace") or
        std.mem.eql(u8, token, "new") or
        std.mem.eql(u8, token, "delete") or
        std.mem.eql(u8, token, "nullptr") or
        std.mem.eql(u8, token, "true") or
        std.mem.eql(u8, token, "false") or
        std.mem.eql(u8, token, "this");
}

fn isIgnoredNativeTypeIdentifier(token: []const u8) bool {
    return isIgnoredNativeIdentifier(token) or
        std.mem.eql(u8, token, "void") or
        std.mem.eql(u8, token, "bool") or
        std.mem.eql(u8, token, "char") or
        std.mem.eql(u8, token, "short") or
        std.mem.eql(u8, token, "int") or
        std.mem.eql(u8, token, "long") or
        std.mem.eql(u8, token, "float") or
        std.mem.eql(u8, token, "double") or
        std.mem.eql(u8, token, "signed") or
        std.mem.eql(u8, token, "unsigned") or
        std.mem.eql(u8, token, "size_t") or
        std.mem.eql(u8, token, "auto") or
        std.mem.eql(u8, token, "decltype") or
        std.mem.eql(u8, token, "noexcept");
}

fn shouldLeaveBareSymbolUnresolved(index: *const RepoIndex, raw_target: []const u8, candidates: []const ResolutionCandidate) bool {
    if (std.mem.indexOfScalar(u8, raw_target, '/') != null or std.mem.indexOfScalar(u8, raw_target, ':') != null) return false;

    var seen_native_decl = false;
    var seen_symbolic_decl = false;
    var matched_decl_count: u32 = 0;
    var first_file: ?u32 = null;
    for (candidates) |candidate| {
        if (candidate.target_kind != .declaration or candidate.decl_index == null) continue;
        const decl = index.declarations.items[candidate.decl_index.?];
        if (!std.mem.eql(u8, decl.name, raw_target) and !std.mem.eql(u8, nativeLeafName(decl.name), raw_target) and !std.mem.eql(u8, symbolicLeafName(decl.name), raw_target)) continue;
        if (decl.kind == .symbolic_unit) {
            seen_symbolic_decl = true;
        } else {
            if (!isNativeExtension(index.files.items[decl.file_index].rel_path)) continue;
            seen_native_decl = true;
        }
        matched_decl_count += 1;
        if (first_file == null) {
            first_file = decl.file_index;
        } else if (first_file.? != decl.file_index) {
            return true;
        }
    }
    return (seen_native_decl or seen_symbolic_decl) and matched_decl_count > 1;
}

fn lessThanResolutionCandidate(_: void, lhs: ResolutionCandidate, rhs: ResolutionCandidate) bool {
    if (lhs.score != rhs.score) return lhs.score > rhs.score;
    if (lhs.evidence_count != rhs.evidence_count) return lhs.evidence_count > rhs.evidence_count;
    return lhs.branch_id < rhs.branch_id;
}

fn lessThanRepoScanEntry(_: void, lhs: RepoScanEntry, rhs: RepoScanEntry) bool {
    return std.mem.order(u8, lhs.rel_path, rhs.rel_path) == .lt;
}

fn lessThanCachedFileRecord(_: void, lhs: CachedFileRecord, rhs: CachedFileRecord) bool {
    return std.mem.order(u8, lhs.rel_path, rhs.rel_path) == .lt;
}

fn lessThanEvidenceSeed(index: *const RepoIndex, lhs: EvidenceSeed, rhs: EvidenceSeed) bool {
    const lhs_path = index.files.items[lhs.file_index].rel_path;
    const rhs_path = index.files.items[rhs.file_index].rel_path;
    const order = std.mem.order(u8, lhs_path, rhs_path);
    if (order != .eq) return order == .lt;
    if (lhs.line != rhs.line) return lhs.line < rhs.line;
    return std.mem.order(u8, lhs.reason, rhs.reason) == .lt;
}

fn lessThanContradictionSeed(index: *const RepoIndex, lhs: ContradictionSeed, rhs: ContradictionSeed) bool {
    if (lhs.weight != rhs.weight) return lhs.weight > rhs.weight;
    const lhs_path = index.files.items[lhs.file_index].rel_path;
    const rhs_path = index.files.items[rhs.file_index].rel_path;
    const order = std.mem.order(u8, lhs_path, rhs_path);
    if (order != .eq) return order == .lt;
    if (lhs.line != rhs.line) return lhs.line < rhs.line;
    const category_order = std.mem.order(u8, contradictionCategoryName(lhs.category), contradictionCategoryName(rhs.category));
    if (category_order != .eq) return category_order == .lt;
    return std.mem.order(u8, lhs.reason, rhs.reason) == .lt;
}

fn surfaceContainsFile(surface: []const EvidenceSeed, file_index: u32) bool {
    for (surface) |seed| {
        if (seed.file_index == file_index) return true;
    }
    return false;
}
