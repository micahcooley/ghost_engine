const std = @import("std");
const abstractions = @import("abstractions.zig");
const artifact_schema = @import("artifact_schema.zig");
const code_intel = @import("code_intel.zig");
const compute_budget = @import("compute_budget.zig");
const execution = @import("execution.zig");

pub const HookKind = enum {
    build,
    @"test",
    runtime,
    schema_validation,
    consistency_check,
    freshness_check,
    citation_check,
    unit_consistency,
    constraint_check,
    custom_external,
};

pub const EvidenceKind = enum {
    build_log,
    test_log,
    runtime_oracle,
    schema_report,
    consistency_report,
    freshness_report,
    citation_report,
    unit_report,
    constraint_report,
    external_report,
};

pub const Status = enum {
    passed,
    failed,
    blocked,
    skipped,
    budget_exhausted,
};

pub const Timing = struct {
    started_ms: u64 = 0,
    duration_ms: u64 = 0,
};

pub const Adapter = struct {
    id: []const u8,
    schema_name: []const u8,
    hook_kind: HookKind,
    input_artifact_types: []const artifact_schema.ArtifactType = &.{},
    required_entity_kinds: []const []const u8 = &.{},
    required_relation_kinds: []const artifact_schema.Relation = &.{},
    required_obligations: []const []const u8 = &.{},
    budget_cost: u32 = 1,
    trust_requirements: []const abstractions.TrustClass = &.{},
    output_evidence_kind: EvidenceKind,
};

pub const RunRequest = struct {
    adapter: Adapter,
    artifact: ?*const artifact_schema.Artifact = null,
    entities: []const artifact_schema.Entity = &.{},
    relations: []const artifact_schema.RelationEdge = &.{},
    obligations: []const artifact_schema.Obligation = &.{},
    fragments: []const artifact_schema.Fragment = &.{},
    provenance: []const u8 = "verifier_adapter",
};

pub const Result = struct {
    allocator: std.mem.Allocator,
    adapter_id: []u8,
    status: Status,
    evidence_kind: EvidenceKind,
    evidence: []u8,
    obligations_discharged: [][]u8 = &.{},
    obligations_remaining: [][]u8 = &.{},
    failure_signal: ?[]u8 = null,
    provenance: []u8,
    timing: Timing = .{},
    budget_exhaustion: ?compute_budget.Exhaustion = null,

    pub fn deinit(self: *Result) void {
        self.allocator.free(self.adapter_id);
        self.allocator.free(self.evidence);
        for (self.obligations_discharged) |item| self.allocator.free(item);
        self.allocator.free(self.obligations_discharged);
        for (self.obligations_remaining) |item| self.allocator.free(item);
        self.allocator.free(self.obligations_remaining);
        if (self.failure_signal) |signal| self.allocator.free(signal);
        self.allocator.free(self.provenance);
        if (self.budget_exhaustion) |*ex| ex.deinit();
        self.* = undefined;
    }
};

pub const BudgetTracker = struct {
    allocator: std.mem.Allocator,
    budget: compute_budget.Effective,
    runs_used: usize = 0,
    external_runs_used: usize = 0,
    evidence_bytes_used: usize = 0,

    pub fn init(allocator: std.mem.Allocator, budget: compute_budget.Effective) BudgetTracker {
        return .{ .allocator = allocator, .budget = budget };
    }

    pub fn reserve(self: *BudgetTracker, adapter: Adapter) !?compute_budget.Exhaustion {
        if (self.runs_used + 1 > self.budget.max_verifier_runs) {
            return try compute_budget.Exhaustion.init(
                self.allocator,
                .max_verifier_runs,
                .verifier_adapter_run,
                self.runs_used + 1,
                self.budget.max_verifier_runs,
                "verifier adapter run count exceeded selected compute budget",
                adapter.id,
            );
        }
        if (isExternal(adapter.hook_kind) and self.external_runs_used + 1 > self.budget.max_external_verifier_runs) {
            return try compute_budget.Exhaustion.init(
                self.allocator,
                .max_external_verifier_runs,
                .verifier_adapter_run,
                self.external_runs_used + 1,
                self.budget.max_external_verifier_runs,
                "external verifier adapter run count exceeded selected compute budget",
                adapter.id,
            );
        }
        self.runs_used += 1;
        if (isExternal(adapter.hook_kind)) self.external_runs_used += 1;
        return null;
    }

    pub fn accountEvidence(self: *BudgetTracker, result: *Result) !void {
        self.evidence_bytes_used += result.evidence.len;
        if (self.evidence_bytes_used > self.budget.max_verifier_evidence_bytes) {
            result.status = .budget_exhausted;
            if (result.failure_signal) |signal| self.allocator.free(signal);
            result.failure_signal = try self.allocator.dupe(u8, "verifier_evidence_budget_exhausted");
            result.budget_exhaustion = try compute_budget.Exhaustion.init(
                self.allocator,
                .max_verifier_evidence_bytes,
                .verifier_adapter_evidence,
                self.evidence_bytes_used,
                self.budget.max_verifier_evidence_bytes,
                "verifier evidence bytes exceeded selected compute budget",
                result.adapter_id,
            );
        }
    }
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    entries: std.StringHashMap(Adapter),
    lookup_cache: std.StringHashMap(Adapter),

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{
            .allocator = allocator,
            .entries = std.StringHashMap(Adapter).init(allocator),
            .lookup_cache = std.StringHashMap(Adapter).init(allocator),
        };
    }

    pub fn deinit(self: *Registry) void {
        var iter = self.entries.iterator();
        while (iter.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.entries.deinit();
        self.clearLookupCache();
        self.lookup_cache.deinit();
        self.* = undefined;
    }

    pub fn register(self: *Registry, adapter: Adapter) !void {
        const key = try self.allocator.dupe(u8, adapter.id);
        errdefer self.allocator.free(key);
        if (self.entries.fetchRemove(adapter.id)) |removed| self.allocator.free(removed.key);
        try self.entries.put(key, adapter);
        self.clearLookupCache();
    }

    pub fn lookup(self: *Registry, schema_name: []const u8, hook_kind: HookKind, obligation: ?[]const u8) ?Adapter {
        const cache_key = self.lookupCacheKey(schema_name, hook_kind, obligation) catch null;
        defer if (cache_key) |key| self.allocator.free(key);
        if (cache_key) |key| {
            if (self.lookup_cache.get(key)) |adapter| return adapter;
        }
        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            const adapter = entry.value_ptr.*;
            if (!std.mem.eql(u8, adapter.schema_name, schema_name)) continue;
            if (adapter.hook_kind != hook_kind) continue;
            if (obligation) |required| {
                if (!adapterDischarges(adapter, required)) continue;
            }
            if (cache_key) |key| {
                const owned_key = self.allocator.dupe(u8, key) catch return adapter;
                self.lookup_cache.put(owned_key, adapter) catch {
                    self.allocator.free(owned_key);
                    return adapter;
                };
            }
            return adapter;
        }
        return null;
    }

    pub fn listApplicable(self: *const Registry, allocator: std.mem.Allocator, schema_name: []const u8, hook_kind: ?HookKind) ![]Adapter {
        var items = std.ArrayList(Adapter).init(allocator);
        errdefer items.deinit();
        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            const adapter = entry.value_ptr.*;
            if (!std.mem.eql(u8, adapter.schema_name, schema_name)) continue;
            if (hook_kind) |kind| {
                if (adapter.hook_kind != kind) continue;
            }
            try items.append(adapter);
        }
        std.mem.sort(Adapter, items.items, {}, lessAdapter);
        return items.toOwnedSlice();
    }

    pub fn missingVerifierObligation(self: *Registry, schema_name: []const u8, hook_kind: HookKind, obligation: []const u8) bool {
        return self.lookup(schema_name, hook_kind, obligation) == null;
    }

    fn lookupCacheKey(self: *Registry, schema_name: []const u8, hook_kind: HookKind, obligation: ?[]const u8) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "{s}|{s}|{s}", .{
            schema_name,
            @tagName(hook_kind),
            obligation orelse "",
        });
    }

    fn clearLookupCache(self: *Registry) void {
        var iter = self.lookup_cache.iterator();
        while (iter.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.lookup_cache.clearRetainingCapacity();
    }
};

fn lessAdapter(_: void, a: Adapter, b: Adapter) bool {
    return std.mem.lessThan(u8, a.id, b.id);
}

fn adapterDischarges(adapter: Adapter, obligation: []const u8) bool {
    for (adapter.required_obligations) |item| {
        if (std.mem.eql(u8, item, obligation)) return true;
    }
    return false;
}

fn isExternal(kind: HookKind) bool {
    return switch (kind) {
        .build, .@"test", .runtime, .custom_external => true,
        else => false,
    };
}

pub fn registerBuiltinAdapters(registry: *Registry) !void {
    try registry.register(codeBuildAdapter());
    try registry.register(codeTestAdapter());
    try registry.register(codeRuntimeOracleAdapter());
    try registry.register(configSchemaValidationAdapter());
    try registry.register(documentCitationCheckAdapter());
    try registry.register(documentFreshnessCheckAdapter());
    try registry.register(genericConsistencyCheckAdapter());
}

pub fn codeBuildAdapter() Adapter {
    return .{
        .id = "code.build.zig_build",
        .schema_name = "code_artifact_schema",
        .hook_kind = .build,
        .input_artifact_types = &.{ .file, .directory, .mixed },
        .required_entity_kinds = &.{ "module", "function" },
        .required_relation_kinds = &.{ .contains, .defines },
        .required_obligations = &.{ "build" },
        .budget_cost = 4,
        .trust_requirements = &.{ .core, .project, .exploratory },
        .output_evidence_kind = .build_log,
    };
}

pub fn codeTestAdapter() Adapter {
    return .{
        .id = "code.test.zig_build_test",
        .schema_name = "code_artifact_schema",
        .hook_kind = .@"test",
        .input_artifact_types = &.{ .file, .directory, .mixed },
        .required_entity_kinds = &.{ "function" },
        .required_relation_kinds = &.{ .references, .depends_on },
        .required_obligations = &.{ "test" },
        .budget_cost = 4,
        .trust_requirements = &.{ .core, .project, .exploratory },
        .output_evidence_kind = .test_log,
    };
}

pub fn codeRuntimeOracleAdapter() Adapter {
    return .{
        .id = "code.runtime.oracle",
        .schema_name = "code_artifact_schema",
        .hook_kind = .runtime,
        .input_artifact_types = &.{ .file, .directory, .mixed },
        .required_entity_kinds = &.{ "function" },
        .required_relation_kinds = &.{ .references },
        .required_obligations = &.{ "runtime" },
        .budget_cost = 5,
        .trust_requirements = &.{ .core, .project, .exploratory },
        .output_evidence_kind = .runtime_oracle,
    };
}

pub fn configSchemaValidationAdapter() Adapter {
    return .{
        .id = "config.schema.validation",
        .schema_name = "config_schema",
        .hook_kind = .schema_validation,
        .input_artifact_types = &.{ .file, .document },
        .required_entity_kinds = &.{ "key", "value" },
        .required_relation_kinds = &.{ .contains },
        .required_obligations = &.{ "schema_validation" },
        .budget_cost = 1,
        .trust_requirements = &.{ .core, .project, .exploratory },
        .output_evidence_kind = .schema_report,
    };
}

pub fn documentCitationCheckAdapter() Adapter {
    return .{
        .id = "document.citation.check",
        .schema_name = "document_schema",
        .hook_kind = .citation_check,
        .input_artifact_types = &.{ .document, .file },
        .required_entity_kinds = &.{ "link" },
        .required_relation_kinds = &.{ .references },
        .required_obligations = &.{ "citation_check" },
        .budget_cost = 1,
        .trust_requirements = &.{ .core, .project, .exploratory },
        .output_evidence_kind = .citation_report,
    };
}

pub fn documentFreshnessCheckAdapter() Adapter {
    return .{
        .id = "document.freshness.check",
        .schema_name = "document_schema",
        .hook_kind = .freshness_check,
        .input_artifact_types = &.{ .document, .file },
        .required_entity_kinds = &.{ "section" },
        .required_relation_kinds = &.{ .contains },
        .required_obligations = &.{ "freshness_check" },
        .budget_cost = 1,
        .trust_requirements = &.{ .core, .project, .exploratory },
        .output_evidence_kind = .freshness_report,
    };
}

pub fn genericConsistencyCheckAdapter() Adapter {
    return .{
        .id = "generic.consistency.check",
        .schema_name = "generic_schema",
        .hook_kind = .consistency_check,
        .input_artifact_types = &.{ .file, .document, .mixed, .corpus },
        .required_entity_kinds = &.{},
        .required_relation_kinds = &.{ .contradicts },
        .required_obligations = &.{ "consistency_check" },
        .budget_cost = 1,
        .trust_requirements = &.{ .core, .project, .exploratory },
        .output_evidence_kind = .consistency_report,
    };
}

pub fn run(allocator: std.mem.Allocator, tracker: *BudgetTracker, request: RunRequest) !Result {
    const started = std.time.milliTimestamp();
    if (try tracker.reserve(request.adapter)) |exhaustion| {
        return budgetResult(allocator, request.adapter, request.provenance, exhaustion);
    }

    var result = switch (request.adapter.hook_kind) {
        .schema_validation => try runSchemaValidation(allocator, request),
        .consistency_check => try runConsistencyCheck(allocator, request),
        .freshness_check => try runFreshnessCheck(allocator, request),
        .citation_check => try runCitationCheck(allocator, request),
        .unit_consistency, .constraint_check => try runRequiredStructureCheck(allocator, request),
        .build, .@"test", .runtime, .custom_external => try skippedResult(
            allocator,
            request.adapter,
            "external adapter execution must be bridged through the bounded execution harness",
            request.provenance,
        ),
    };
    result.timing.started_ms = @intCast(started);
    result.timing.duration_ms = @intCast(std.time.milliTimestamp() - started);
    try tracker.accountEvidence(&result);
    return result;
}

pub fn fromExecutionCapture(
    allocator: std.mem.Allocator,
    adapter: Adapter,
    capture: *const execution.Result,
    obligations: []const []const u8,
    provenance: []const u8,
) !Result {
    const status: Status = if (capture.succeeded()) .passed else .failed;
    const signal: ?[]const u8 = if (capture.failure_signal != .none)
        execution.failureSignalName(capture.failure_signal)
    else if (status == .failed)
        "command_failed"
    else
        null;
    const exit_text = if (capture.exit_code) |code|
        try std.fmt.allocPrint(allocator, "{d}", .{code})
    else
        try allocator.dupe(u8, "none");
    defer allocator.free(exit_text);
    const evidence = try std.fmt.allocPrint(
        allocator,
        "command={s}; exit_code={s}; stdout_bytes={d}; stderr_bytes={d}; summary={s}",
        .{
            capture.command,
            exit_text,
            capture.stdout.len,
            capture.stderr.len,
            capture.invariant_summary orelse "none",
        },
    );
    return makeResult(
        allocator,
        adapter,
        status,
        evidence,
        obligations,
        if (status == .passed) &.{} else obligations,
        signal,
        provenance,
        .{ .duration_ms = capture.duration_ms },
    );
}

fn runSchemaValidation(allocator: std.mem.Allocator, request: RunRequest) !Result {
    if (request.artifact == null) return blockedResult(allocator, request.adapter, "schema validation requires an artifact", request.provenance);
    const missing = try missingEntityKinds(allocator, request.adapter.required_entity_kinds, request.entities);
    defer allocator.free(missing);
    if (missing.len > 0) {
        const evidence = try std.fmt.allocPrint(allocator, "schema={s}; missing_entity_kind={s}", .{ request.adapter.schema_name, missing[0] });
        return makeResult(allocator, request.adapter, .failed, evidence, &.{}, request.adapter.required_obligations, "missing_required_entity_kind", request.provenance, .{});
    }
    return makeResult(allocator, request.adapter, .passed, try allocator.dupe(u8, "required schema entity kinds were present"), request.adapter.required_obligations, &.{}, null, request.provenance, .{});
}

fn runConsistencyCheck(allocator: std.mem.Allocator, request: RunRequest) !Result {
    for (request.relations) |relation| {
        if (relation.relation == .contradicts) {
            const evidence = try std.fmt.allocPrint(allocator, "contradiction relation from {s} to {s}", .{ relation.from_entity_id, relation.to_entity_id });
            return makeResult(allocator, request.adapter, .failed, evidence, &.{}, request.adapter.required_obligations, "contradiction_relation_present", request.provenance, .{});
        }
    }
    return makeResult(allocator, request.adapter, .passed, try allocator.dupe(u8, "no contradiction relations were present"), request.adapter.required_obligations, &.{}, null, request.provenance, .{});
}

fn runFreshnessCheck(allocator: std.mem.Allocator, request: RunRequest) !Result {
    for (request.fragments) |fragment| {
        if (std.mem.indexOf(u8, fragment.raw_text, "stale") != null or std.mem.indexOf(u8, fragment.raw_text, "outdated") != null) {
            return makeResult(allocator, request.adapter, .failed, try allocator.dupe(u8, "freshness marker indicates stale or outdated content"), &.{}, request.adapter.required_obligations, "stale_content_marker", request.provenance, .{});
        }
    }
    return makeResult(allocator, request.adapter, .passed, try allocator.dupe(u8, "no stale freshness markers were present"), request.adapter.required_obligations, &.{}, null, request.provenance, .{});
}

fn runCitationCheck(allocator: std.mem.Allocator, request: RunRequest) !Result {
    for (request.entities) |entity| {
        if (std.mem.eql(u8, entity.entity_type, "link")) {
            return makeResult(allocator, request.adapter, .passed, try allocator.dupe(u8, "document contains at least one citation/link entity"), request.adapter.required_obligations, &.{}, null, request.provenance, .{});
        }
    }
    return makeResult(allocator, request.adapter, .blocked, try allocator.dupe(u8, "citation check requires at least one link entity"), &.{}, request.adapter.required_obligations, "missing_citation_entity", request.provenance, .{});
}

fn runRequiredStructureCheck(allocator: std.mem.Allocator, request: RunRequest) !Result {
    const missing = try missingEntityKinds(allocator, request.adapter.required_entity_kinds, request.entities);
    defer allocator.free(missing);
    if (missing.len > 0) {
        const evidence = try std.fmt.allocPrint(allocator, "missing required entity kind {s}", .{missing[0]});
        return makeResult(allocator, request.adapter, .blocked, evidence, &.{}, request.adapter.required_obligations, "missing_required_structure", request.provenance, .{});
    }
    return makeResult(allocator, request.adapter, .passed, try allocator.dupe(u8, "required structure was present"), request.adapter.required_obligations, &.{}, null, request.provenance, .{});
}

fn missingEntityKinds(allocator: std.mem.Allocator, required: []const []const u8, entities: []const artifact_schema.Entity) ![][]const u8 {
    var missing = std.ArrayList([]const u8).init(allocator);
    errdefer missing.deinit();
    for (required) |kind| {
        var found = false;
        for (entities) |entity| {
            if (std.mem.eql(u8, entity.entity_type, kind)) {
                found = true;
                break;
            }
        }
        if (!found) try missing.append(kind);
    }
    return missing.toOwnedSlice();
}

fn blockedResult(allocator: std.mem.Allocator, adapter: Adapter, evidence: []const u8, provenance: []const u8) !Result {
    return makeResult(allocator, adapter, .blocked, try allocator.dupe(u8, evidence), &.{}, adapter.required_obligations, "blocked", provenance, .{});
}

fn skippedResult(allocator: std.mem.Allocator, adapter: Adapter, evidence: []const u8, provenance: []const u8) !Result {
    return makeResult(allocator, adapter, .skipped, try allocator.dupe(u8, evidence), &.{}, adapter.required_obligations, "skipped", provenance, .{});
}

fn budgetResult(allocator: std.mem.Allocator, adapter: Adapter, provenance: []const u8, exhaustion: compute_budget.Exhaustion) !Result {
    var result = try makeResult(allocator, adapter, .budget_exhausted, try allocator.dupe(u8, "verifier adapter budget exhausted before execution"), &.{}, adapter.required_obligations, "budget_exhausted", provenance, .{});
    result.budget_exhaustion = exhaustion;
    return result;
}

fn makeResult(
    allocator: std.mem.Allocator,
    adapter: Adapter,
    status: Status,
    evidence: []u8,
    discharged: []const []const u8,
    remaining: []const []const u8,
    failure_signal: ?[]const u8,
    provenance: []const u8,
    timing: Timing,
) !Result {
    errdefer allocator.free(evidence);
    return .{
        .allocator = allocator,
        .adapter_id = try allocator.dupe(u8, adapter.id),
        .status = status,
        .evidence_kind = adapter.output_evidence_kind,
        .evidence = evidence,
        .obligations_discharged = try cloneStringList(allocator, discharged),
        .obligations_remaining = try cloneStringList(allocator, remaining),
        .failure_signal = if (failure_signal) |signal| try allocator.dupe(u8, signal) else null,
        .provenance = try allocator.dupe(u8, provenance),
        .timing = timing,
    };
}

fn cloneStringList(allocator: std.mem.Allocator, items: []const []const u8) ![][]u8 {
    const out = try allocator.alloc([]u8, items.len);
    errdefer allocator.free(out);
    for (items, 0..) |item, idx| out[idx] = try allocator.dupe(u8, item);
    return out;
}

pub fn appendResultToSupportGraph(
    allocator: std.mem.Allocator,
    nodes: *std.ArrayList(code_intel.SupportGraphNode),
    edges: *std.ArrayList(code_intel.SupportGraphEdge),
    parent_id: []const u8,
    result: Result,
    ordinal: usize,
) !void {
    const adapter_node = try std.fmt.allocPrint(allocator, "verifier_adapter_{d}", .{ordinal});
    defer allocator.free(adapter_node);
    const run_node = try std.fmt.allocPrint(allocator, "verifier_run_{d}", .{ordinal});
    defer allocator.free(run_node);
    const evidence_node = try std.fmt.allocPrint(allocator, "verifier_evidence_{d}", .{ordinal});
    defer allocator.free(evidence_node);
    try appendNode(allocator, nodes, adapter_node, .verifier_adapter, result.adapter_id, null, 0, 0, false, "capability only; does not authorize support directly");
    try appendNode(allocator, nodes, run_node, .verifier_run, statusName(result.status), null, 0, 0, result.status == .passed, result.provenance);
    try appendNode(allocator, nodes, evidence_node, if (result.status == .failed or result.status == .blocked or result.status == .budget_exhausted) .verifier_failure else .verifier_evidence, evidenceKindName(result.evidence_kind), null, 0, 0, result.status == .passed, result.evidence);
    try appendEdge(allocator, edges, parent_id, adapter_node, .required_by);
    try appendEdge(allocator, edges, adapter_node, run_node, .verifies);
    try appendEdge(allocator, edges, run_node, evidence_node, .produced_evidence);
    if (result.status == .failed) try appendEdge(allocator, edges, parent_id, evidence_node, .failed_by);
    if (result.status == .blocked or result.status == .budget_exhausted) try appendEdge(allocator, edges, parent_id, evidence_node, .blocked_by);
    for (result.obligations_discharged, 0..) |_, idx| {
        if (idx >= 4) break;
        try appendEdge(allocator, edges, evidence_node, parent_id, .discharges);
    }
}

fn appendNode(
    allocator: std.mem.Allocator,
    nodes: *std.ArrayList(code_intel.SupportGraphNode),
    id: []const u8,
    kind: code_intel.SupportNodeKind,
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

fn appendEdge(
    allocator: std.mem.Allocator,
    edges: *std.ArrayList(code_intel.SupportGraphEdge),
    from_id: []const u8,
    to_id: []const u8,
    kind: code_intel.SupportEdgeKind,
) !void {
    try edges.append(.{
        .from_id = try allocator.dupe(u8, from_id),
        .to_id = try allocator.dupe(u8, to_id),
        .kind = kind,
    });
}

pub fn hookKindName(kind: HookKind) []const u8 {
    return @tagName(kind);
}

pub fn statusName(status: Status) []const u8 {
    return @tagName(status);
}

pub fn evidenceKindName(kind: EvidenceKind) []const u8 {
    return @tagName(kind);
}

test "registry selects adapters and detects missing verifier obligations" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();
    try registerBuiltinAdapters(&registry);
    try std.testing.expect(registry.lookup("code_artifact_schema", .build, "build") != null);
    try std.testing.expect(registry.missingVerifierObligation("config_schema", .schema_validation, "runtime"));
    const adapters = try registry.listApplicable(allocator, "document_schema", null);
    defer allocator.free(adapters);
    try std.testing.expect(adapters.len >= 2);
}

test "passed verifier evidence enters graph without direct support authorization" {
    const allocator = std.testing.allocator;
    var tracker = BudgetTracker.init(allocator, compute_budget.resolve(.{ .tier = .medium }));
    const artifact = artifact_schema.Artifact{
        .id = "cfg",
        .source = .user,
        .artifact_type = .file,
        .format_hint = "toml",
        .provenance = "test",
        .trust_class = .project,
        .content_path = null,
        .schema_name = "config_schema",
    };
    const entities = [_]artifact_schema.Entity{
        .{ .id = "key", .entity_type = "key", .fragment_index = 0, .label = "port", .provenance = "test", .artifact_id = "cfg" },
        .{ .id = "value", .entity_type = "value", .fragment_index = 0, .label = "3000", .provenance = "test", .artifact_id = "cfg" },
    };
    var result = try run(allocator, &tracker, .{
        .adapter = configSchemaValidationAdapter(),
        .artifact = &artifact,
        .entities = &entities,
    });
    defer result.deinit();
    try std.testing.expectEqual(Status.passed, result.status);
    try std.testing.expectEqual(@as(usize, 1), result.obligations_discharged.len);

    var nodes = std.ArrayList(code_intel.SupportGraphNode).init(allocator);
    defer {
        for (nodes.items) |node| {
            allocator.free(node.id);
            allocator.free(node.label);
            if (node.rel_path) |path| allocator.free(path);
            if (node.detail) |detail| allocator.free(detail);
        }
        nodes.deinit();
    }
    var edges = std.ArrayList(code_intel.SupportGraphEdge).init(allocator);
    defer {
        for (edges.items) |edge| {
            allocator.free(edge.from_id);
            allocator.free(edge.to_id);
        }
        edges.deinit();
    }
    try appendResultToSupportGraph(allocator, &nodes, &edges, "output", result, 1);
    try std.testing.expect(nodes.items.len >= 3);
    try std.testing.expectEqual(code_intel.SupportNodeKind.verifier_adapter, nodes.items[0].kind);
    try std.testing.expect(!nodes.items[0].usable);
    try std.testing.expectEqual(code_intel.SupportNodeKind.verifier_evidence, nodes.items[2].kind);
    try std.testing.expect(edges.items.len >= 4);
}

test "failed verifier creates blocking failure evidence" {
    const allocator = std.testing.allocator;
    var tracker = BudgetTracker.init(allocator, compute_budget.resolve(.{ .tier = .medium }));
    const relation = artifact_schema.RelationEdge{
        .relation = .contradicts,
        .from_entity_id = "a",
        .to_entity_id = "b",
        .provenance = "test",
    };
    var result = try run(allocator, &tracker, .{
        .adapter = genericConsistencyCheckAdapter(),
        .relations = &.{relation},
    });
    defer result.deinit();
    try std.testing.expectEqual(Status.failed, result.status);
    try std.testing.expect(result.failure_signal != null);
    try std.testing.expectEqual(@as(usize, 1), result.obligations_remaining.len);
}

test "verifier budget exhaustion is explicit" {
    const allocator = std.testing.allocator;
    var tracker = BudgetTracker.init(allocator, compute_budget.resolve(.{
        .tier = .medium,
        .overrides = .{ .max_verifier_runs = 0 },
    }));
    var result = try run(allocator, &tracker, .{
        .adapter = configSchemaValidationAdapter(),
        .provenance = "budget-test",
    });
    defer result.deinit();
    try std.testing.expectEqual(Status.budget_exhausted, result.status);
    try std.testing.expect(result.budget_exhaustion != null);
    try std.testing.expectEqual(compute_budget.Limit.max_verifier_runs, result.budget_exhaustion.?.limit);
}

test "code execution verifier result is adapter traceable" {
    const allocator = std.testing.allocator;
    var capture = execution.Result{
        .label = try allocator.dupe(u8, "zig_build"),
        .kind = .zig_build,
        .phase = .build,
        .command = try allocator.dupe(u8, "zig build"),
        .exit_code = 0,
        .duration_ms = 7,
        .stdout = try allocator.dupe(u8, ""),
        .stderr = try allocator.dupe(u8, ""),
    };
    defer capture.deinit(allocator);
    var result = try fromExecutionCapture(allocator, codeBuildAdapter(), &capture, &.{ "build" }, "execution_harness");
    defer result.deinit();
    try std.testing.expectEqual(Status.passed, result.status);
    try std.testing.expect(std.mem.eql(u8, result.adapter_id, "code.build.zig_build"));
    try std.testing.expectEqual(EvidenceKind.build_log, result.evidence_kind);
}

test "document citation and freshness checks use the same adapter interface" {
    const allocator = std.testing.allocator;
    var tracker = BudgetTracker.init(allocator, compute_budget.resolve(.{ .tier = .medium }));
    const link = artifact_schema.Entity{ .id = "link", .entity_type = "link", .fragment_index = 0, .label = "https://example.test", .provenance = "test", .artifact_id = "doc" };
    var citation = try run(allocator, &tracker, .{
        .adapter = documentCitationCheckAdapter(),
        .entities = &.{link},
    });
    defer citation.deinit();
    try std.testing.expectEqual(Status.passed, citation.status);

    const stale_fragment = artifact_schema.Fragment{
        .artifact_id = "doc",
        .offset = 0,
        .line = 1,
        .region = "line 1",
        .parser_stage = .strict,
        .raw_text = "this section is stale",
        .provenance = "test",
    };
    var freshness = try run(allocator, &tracker, .{
        .adapter = documentFreshnessCheckAdapter(),
        .fragments = &.{stale_fragment},
    });
    defer freshness.deinit();
    try std.testing.expectEqual(Status.failed, freshness.status);
}
