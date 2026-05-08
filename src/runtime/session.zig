const std = @import("std");
const intent_grounding = @import("../intent_grounding.zig");
const negative_knowledge_ledger = @import("ledger.zig");
const vsa_vulkan = @import("../vsa_vulkan.zig");

pub const DynamicTaskEdge = struct {
    from: []u8,
    to: []u8,
    relation: []u8,

    pub fn deinit(self: *DynamicTaskEdge, allocator: std.mem.Allocator) void {
        allocator.free(self.from);
        allocator.free(self.to);
        allocator.free(self.relation);
        self.* = undefined;
    }
};

pub const DynamicTaskGraph = struct {
    allocator: std.mem.Allocator,
    request_hash: []u8,
    concepts: []intent_grounding.OntologyPrimitive,
    tool_bindings: []vsa_vulkan.DynamicToolBinding,
    edges: []DynamicTaskEdge,
    ephemeral: bool = true,

    pub fn deinit(self: *DynamicTaskGraph) void {
        self.allocator.free(self.request_hash);
        intent_grounding.freeOntologicalPrimitives(self.allocator, self.concepts);
        for (self.tool_bindings) |*binding| binding.deinit(self.allocator);
        self.allocator.free(self.tool_bindings);
        for (self.edges) |*edge| edge.deinit(self.allocator);
        self.allocator.free(self.edges);
        self.* = undefined;
    }
};

pub const DynamicGraphExecutionOptions = struct {
    ledger_root_abs_path: ?[]const u8 = null,
    failure_reason: ?[]const u8 = null,
};

pub const DynamicGraphExecutionStatus = enum {
    planned,
    failed,
};

pub const DynamicGraphExecutionResult = struct {
    allocator: std.mem.Allocator,
    status: DynamicGraphExecutionStatus = .planned,
    ledger_recorded: bool = false,
    ledger_hash: ?[]u8 = null,

    pub fn deinit(self: *DynamicGraphExecutionResult) void {
        if (self.ledger_hash) |hash| self.allocator.free(hash);
        self.* = undefined;
    }
};

pub fn buildDynamicTaskGraph(allocator: std.mem.Allocator, request: []const u8) !DynamicTaskGraph {
    const request_hash = try negative_knowledge_ledger.hashBytes(allocator, request);
    errdefer allocator.free(request_hash);

    const concepts = try intent_grounding.extractOntologicalPrimitives(allocator, request);
    errdefer intent_grounding.freeOntologicalPrimitives(allocator, concepts);

    const signals = try allocator.alloc(vsa_vulkan.OntologySignal, concepts.len);
    defer allocator.free(signals);
    for (concepts, 0..) |concept, idx| {
        signals[idx] = .{
            .role = intent_grounding.ontologyRoleName(concept.role),
            .concept = intent_grounding.ontologyConceptName(concept.concept),
            .confidence = concept.confidence,
        };
    }

    const tool_bindings = try vsa_vulkan.bindDynamicAxioms(allocator, signals);
    errdefer {
        for (tool_bindings) |*binding| binding.deinit(allocator);
        allocator.free(tool_bindings);
    }

    const edges = try buildDynamicTaskEdges(allocator, concepts, tool_bindings);
    errdefer {
        for (edges) |*edge| edge.deinit(allocator);
        allocator.free(edges);
    }

    return .{
        .allocator = allocator,
        .request_hash = request_hash,
        .concepts = concepts,
        .tool_bindings = tool_bindings,
        .edges = edges,
    };
}

pub fn executeDynamicTaskGraph(
    allocator: std.mem.Allocator,
    graph: *const DynamicTaskGraph,
    options: DynamicGraphExecutionOptions,
) !DynamicGraphExecutionResult {
    var result = DynamicGraphExecutionResult{ .allocator = allocator };
    errdefer result.deinit();

    const reason = options.failure_reason orelse return result;
    result.status = .failed;
    if (options.ledger_root_abs_path) |root| {
        const fingerprint = try graphFingerprint(allocator, graph);
        defer allocator.free(fingerprint);
        const hash = try negative_knowledge_ledger.hashBytes(allocator, fingerprint);
        errdefer allocator.free(hash);
        const ledger_path = try negative_knowledge_ledger.ledgerPathForShardRoot(allocator, root);
        defer allocator.free(ledger_path);
        result.ledger_recorded = try negative_knowledge_ledger.appendFailureIfNewAtPath(allocator, ledger_path, .{
            .failed_ast_hash = hash,
            .axiom_violation = reason,
            .source = "ontological_router",
            .failure_surface = "dynamic_task_graph",
        });
        result.ledger_hash = hash;
    }
    return result;
}

fn buildDynamicTaskEdges(
    allocator: std.mem.Allocator,
    concepts: []const intent_grounding.OntologyPrimitive,
    tool_bindings: []const vsa_vulkan.DynamicToolBinding,
) ![]DynamicTaskEdge {
    var edges = std.ArrayList(DynamicTaskEdge).init(allocator);
    errdefer {
        for (edges.items) |*edge| edge.deinit(allocator);
        edges.deinit();
    }
    for (tool_bindings) |binding| {
        for (binding.required_concepts) |required| {
            if (!conceptListContains(concepts, required)) continue;
            try edges.append(.{
                .from = try allocator.dupe(u8, required),
                .to = try allocator.dupe(u8, binding.id),
                .relation = try allocator.dupe(u8, "binds_axiom"),
            });
        }
    }
    return edges.toOwnedSlice();
}

fn conceptListContains(concepts: []const intent_grounding.OntologyPrimitive, required: []const u8) bool {
    for (concepts) |concept| {
        if (std.mem.eql(u8, intent_grounding.ontologyConceptName(concept.concept), required)) return true;
    }
    return false;
}

fn graphFingerprint(allocator: std.mem.Allocator, graph: *const DynamicTaskGraph) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();
    try w.print("request={s}\n", .{graph.request_hash});
    for (graph.concepts) |concept| {
        try w.print("concept={s}:{s}:{d}\n", .{
            intent_grounding.ontologyRoleName(concept.role),
            intent_grounding.ontologyConceptName(concept.concept),
            concept.confidence,
        });
    }
    for (graph.tool_bindings) |binding| {
        try w.print("tool={s}:{s}:{s}\n", .{ binding.id, binding.axiom, binding.tool_path });
    }
    return out.toOwnedSlice();
}

pub const ContextTurn = struct {
    role: []const u8,
    text: []const u8,
};

pub const ContextWindow = struct {
    turns: std.ArrayList(ContextTurn),
    allocator: std.mem.Allocator,
    max_turns: usize = 5,

    pub fn init(allocator: std.mem.Allocator) ContextWindow {
        return .{
            .turns = std.ArrayList(ContextTurn).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ContextWindow) void {
        for (self.turns.items) |turn| {
            self.allocator.free(turn.role);
            self.allocator.free(turn.text);
        }
        self.turns.deinit();
    }

    pub fn push(self: *ContextWindow, role: []const u8, text: []const u8) !void {
        if (self.turns.items.len >= self.max_turns) {
            const old = self.turns.orderedRemove(0);
            self.allocator.free(old.role);
            self.allocator.free(old.text);
        }
        try self.turns.append(.{
            .role = try self.allocator.dupe(u8, role),
            .text = try self.allocator.dupe(u8, text),
        });
    }

    pub fn buildBlock(self: *ContextWindow, allocator: std.mem.Allocator) ![]u8 {
        var out = std.ArrayList(u8).init(allocator);
        for (self.turns.items) |turn| {
            try out.writer().print("{s}: {s}\n", .{ turn.role, turn.text });
        }
        return out.toOwnedSlice();
    }
};

test "dynamic task graph binds code and timeline through one router" {
    const allocator = std.testing.allocator;

    var code_graph = try buildDynamicTaskGraph(allocator, "audit TrackManager.cpp against local axioms");
    defer code_graph.deinit();
    try std.testing.expect(code_graph.ephemeral);
    try std.testing.expect(intent_grounding.hasOntologyConcept(code_graph.concepts, .target_system_component));
    try std.testing.expectEqual(@as(usize, 1), code_graph.tool_bindings.len);
    try std.testing.expectEqual(vsa_vulkan.DynamicToolKind.llvm_verifier, code_graph.tool_bindings[0].kind);

    var timeline_graph = try buildDynamicTaskGraph(allocator, "verify the logical consistency of a historical timeline from the Omni-Codex");
    defer timeline_graph.deinit();
    try std.testing.expect(timeline_graph.ephemeral);
    try std.testing.expect(intent_grounding.hasOntologyConcept(timeline_graph.concepts, .target_knowledge_sequence));
    try std.testing.expectEqual(@as(usize, 1), timeline_graph.tool_bindings.len);
    try std.testing.expectEqual(vsa_vulkan.DynamicToolKind.chronology_consistency, timeline_graph.tool_bindings[0].kind);
}

test "dynamic task graph records failures to negative knowledge ledger" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    var graph = try buildDynamicTaskGraph(allocator, "audit TrackManager.cpp against local axioms");
    defer graph.deinit();

    var result = try executeDynamicTaskGraph(allocator, &graph, .{
        .ledger_root_abs_path = root,
        .failure_reason = "LLVM verifier rejected dynamically bound pipeline",
    });
    defer result.deinit();

    try std.testing.expectEqual(DynamicGraphExecutionStatus.failed, result.status);
    try std.testing.expect(result.ledger_recorded);
    try std.testing.expect(result.ledger_hash != null);

    const ledger_path = try negative_knowledge_ledger.ledgerPathForShardRoot(allocator, root);
    defer allocator.free(ledger_path);
    var lookup = try negative_knowledge_ledger.lookupFailureAtPath(allocator, ledger_path, result.ledger_hash.?);
    defer lookup.deinit();
    try std.testing.expect(lookup.matched);
}
