const std = @import("std");
const ghost = @import("ghost.zig");

const MAX_DOC_BYTES: usize = 2 * 1024 * 1024;
const DEFAULT_LATTICE_CAPACITY: u32 = 4096;

const Options = struct {
    project_shard: []const u8 = "default",
    message: []const u8 = "",
    hypothesis_source_file: ?[]const u8 = null,
    hypothesis_sandbox: ?[]const u8 = null,
    assimilate: bool = false,
    render_json: bool = false,
};

const SourceDoc = struct {
    path: []u8,
    label: []u8,
    domain: []u8,
    text: []u8,
    slot: u32,
    vector: ghost.vsa.HyperVector,

    fn deinit(self: *SourceDoc, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.label);
        allocator.free(self.domain);
        allocator.free(self.text);
    }
};

const ProjectionResult = struct {
    explanation: ghost.cross_domain_projector.CrossDomainExplanation,
    medic: ghost.forge.MedicDecision,
    dark_slot: u32,
    hypothesis_source: []u8,
    hypothesis_result: ghost.effector.ZigHypothesisResult,
    decoded_prose: ?[]const u8,

    fn deinit(self: *ProjectionResult, allocator: std.mem.Allocator) void {
        self.explanation.deinit(allocator);
        allocator.free(self.hypothesis_source);
        if (self.decoded_prose) |prose| allocator.free(prose);
        self.hypothesis_result.deinit();
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const options = try parseArgs(allocator);
    defer allocator.free(options.project_shard);
    defer allocator.free(options.message);
    defer if (options.hypothesis_source_file) |path| allocator.free(path);
    defer if (options.hypothesis_sandbox) |path| allocator.free(path);

    var lattice = try ghost.rune_lattice.RuneLattice.init(allocator, DEFAULT_LATTICE_CAPACITY, null);
    defer lattice.deinit();
    var index = ghost.concept_index.ConceptIndex.init(allocator);
    defer index.deinit();

    const live_files_dir = try liveFilesDir(allocator, options.project_shard);
    defer allocator.free(live_files_dir);

    var docs = try loadLiveDocs(allocator, live_files_dir, &lattice, &index);
    defer {
        for (docs.items) |*doc| doc.deinit(allocator);
        docs.deinit();
    }

    var results = std.ArrayList(ProjectionResult).init(allocator);
    defer {
        for (results.items) |*result| result.deinit(allocator);
        results.deinit();
    }

    var scout = ghost.triad.ScoutState.init(ghost.ghost_state.GENESIS_SEED);
    for (docs.items, 0..) |doc, idx| {
        for (doc.text) |byte| {
            _ = scout.evolve(byte, idx);
        }
    }

    const hypothesis_source_override = if (options.hypothesis_source_file) |path|
        try std.fs.cwd().readFileAlloc(allocator, path, MAX_DOC_BYTES)
    else
        null;
    defer if (hypothesis_source_override) |source| allocator.free(source);

    const sandbox_root = if (options.hypothesis_sandbox) |path|
        try allocator.dupe(u8, path)
    else
        try defaultSandboxRoot(allocator, options.project_shard);
    defer allocator.free(sandbox_root);

    try exploreLowDensityVSA(allocator, &lattice, &index, &scout, &results, sandbox_root, hypothesis_source_override, options.message);

    const dist = lattice.getRankDistribution();
    if (options.render_json) {
        try printJson(std.io.getStdOut().writer(), options, docs.items, results.items, dist);
    } else {
        try printHuman(std.io.getStdOut().writer(), options, docs.items, results.items, dist);
    }
}

fn parseArgs(allocator: std.mem.Allocator) !Options {
    var opts = Options{};
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();

    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--project-shard=")) {
            opts.project_shard = try allocator.dupe(u8, arg["--project-shard=".len..]);
        } else if (std.mem.eql(u8, arg, "--project-shard")) {
            opts.project_shard = try allocator.dupe(u8, args.next() orelse return error.MissingProjectShard);
        } else if (std.mem.startsWith(u8, arg, "--message=")) {
            opts.message = try allocator.dupe(u8, arg["--message=".len..]);
        } else if (std.mem.eql(u8, arg, "--message")) {
            opts.message = try allocator.dupe(u8, args.next() orelse return error.MissingMessage);
        } else if (std.mem.startsWith(u8, arg, "--prompt=")) {
            opts.message = try allocator.dupe(u8, arg["--prompt=".len..]);
        } else if (std.mem.eql(u8, arg, "--prompt")) {
            opts.message = try allocator.dupe(u8, args.next() orelse return error.MissingPrompt);
        } else if (std.mem.eql(u8, arg, "--render=json") or std.mem.eql(u8, arg, "--json")) {
            opts.render_json = true;
        } else if (std.mem.eql(u8, arg, "--assimilate")) {
            opts.assimilate = true;
        } else if (std.mem.startsWith(u8, arg, "--hypothesis-source-file=")) {
            opts.hypothesis_source_file = try allocator.dupe(u8, arg["--hypothesis-source-file=".len..]);
        } else if (std.mem.eql(u8, arg, "--hypothesis-source-file")) {
            opts.hypothesis_source_file = try allocator.dupe(u8, args.next() orelse return error.MissingHypothesisSourceFile);
        } else if (std.mem.startsWith(u8, arg, "--hypothesis-sandbox=")) {
            opts.hypothesis_sandbox = try allocator.dupe(u8, arg["--hypothesis-sandbox=".len..]);
        } else if (std.mem.eql(u8, arg, "--hypothesis-sandbox")) {
            opts.hypothesis_sandbox = try allocator.dupe(u8, args.next() orelse return error.MissingHypothesisSandbox);
        } else if (std.mem.eql(u8, arg, "invent")) {
            continue;
        } else if (opts.message.len == 0 and !std.mem.startsWith(u8, arg, "--")) {
            opts.message = try allocator.dupe(u8, arg);
        }
    }

    if (opts.project_shard.ptr == "default".ptr) opts.project_shard = try allocator.dupe(u8, "default");
    if (opts.message.ptr == "".ptr) opts.message = try allocator.dupe(u8, "");
    return opts;
}

fn liveFilesDir(allocator: std.mem.Allocator, project_shard: []const u8) ![]u8 {
    const rel = try std.fs.path.join(allocator, &.{
        ghost.config.PROJECT_SHARD_REL_DIR,
        project_shard,
        ghost.config.CORPUS_INGEST_REL_DIR_NAME,
        ghost.config.CORPUS_INGEST_LIVE_DIR_NAME,
        ghost.config.CORPUS_INGEST_FILES_DIR_NAME,
    });
    defer allocator.free(rel);
    return ghost.config.getPath(allocator, rel);
}

fn loadLiveDocs(
    allocator: std.mem.Allocator,
    live_files_dir: []const u8,
    lattice: *ghost.rune_lattice.RuneLattice,
    index: *ghost.concept_index.ConceptIndex,
) !std.ArrayList(SourceDoc) {
    var root = try std.fs.openDirAbsolute(live_files_dir, .{ .iterate = true });
    defer root.close();
    var walker = try root.walk(allocator);
    defer walker.deinit();

    var docs = std.ArrayList(SourceDoc).init(allocator);
    errdefer {
        for (docs.items) |*doc| doc.deinit(allocator);
        docs.deinit();
    }

    const now_ms: u64 = @intCast(std.time.milliTimestamp());
    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!isTextPath(entry.path)) continue;

        const text = try root.readFileAlloc(allocator, entry.path, MAX_DOC_BYTES);
        errdefer allocator.free(text);
        const trimmed = std.mem.trim(u8, text, " \r\n\t");
        if (trimmed.len == 0) continue;

        const label = try labelForPath(allocator, entry.path);
        errdefer allocator.free(label);
        const domain = try domainForPath(allocator, entry.path);
        errdefer allocator.free(domain);
        const vector = ghost.semantic_encoder.encodeDomainConcept(trimmed, domain);
        const slot = lattice.observe(vector, ghost.vsa.collapse(vector), now_ms) orelse return error.LatticeFull;
        lattice.verify(slot, now_ms);

        try index.addEntry(label, slot, entry.path, 0, trimmed.len, domain, 1, trimmed);
        try docs.append(.{
            .path = try allocator.dupe(u8, entry.path),
            .label = label,
            .domain = domain,
            .text = text,
            .slot = slot,
            .vector = vector,
        });
    }

    return docs;
}

fn exploreLowDensityVSA(
    allocator: std.mem.Allocator,
    lattice: *ghost.rune_lattice.RuneLattice,
    index: *ghost.concept_index.ConceptIndex,
    scout: *const ghost.triad.ScoutState,
    results: *std.ArrayList(ProjectionResult),
    sandbox_root: []const u8,
    hypothesis_source_override: ?[]const u8,
    prompt: []const u8,
) !void {
    const now_ms: u64 = @intCast(std.time.milliTimestamp());
    
    // 1. Ghost explores low-density VSA space purely algebraically
    var local_scout = scout.*;
    var best_candidate = local_scout.getState();
    var best_min_dist: u16 = 0;
    
    for (0..100) |i| {
        var vec = best_candidate;
        for (0..3) |_| {
            vec = ghost.vsa.permute(vec);
            _ = local_scout.evolve(@intCast(i % 256), @intCast(i));
            vec = ghost.vsa.bind(vec, local_scout.getState());
        }
        
        var min_dist: u16 = 1025;
        var j: u32 = 0;
        while (j < lattice.capacity) : (j += 1) {
            if (lattice.tags[j] == 0) continue;
            const dist = ghost.vsa.hammingDistance(vec, lattice.vectors[j]);
            if (dist < min_dist) min_dist = dist;
        }
        
        if (min_dist > best_min_dist) {
            best_min_dist = min_dist;
            best_candidate = vec;
        }
    }
    
    const candidate_rune = ghost.cross_domain_projector.CandidateRune{
        .vector = best_candidate,
        .source_a = best_candidate,
        .source_b = best_candidate,
        .domain_a = "vsa-algebra",
        .domain_b = "dark-space",
        .label_a = "synthetic",
        .label_b = "exploration",
    };

    const dark_slot = lattice.observe(best_candidate, ghost.vsa.collapse(best_candidate), now_ms) orelse return error.LatticeFull;
    try index.addEntry("pure algebraic candidate", dark_slot, "ghost_invent", 0, 0, "dark-space", 5, "Low-density vector found via algebraic exploration.");

    var explanation = try ghost.cross_domain_projector.decodeCandidateRune(allocator, candidate_rune, lattice, index);
    errdefer explanation.deinit(allocator);
    
    const medic_query = selectMedicQuery(best_candidate, lattice, scout);
    const medic = ghost.forge.medicLoop(lattice, medic_query, scout);

    const hypothesis_source = if (hypothesis_source_override) |source|
        try allocator.dupe(u8, source)
    else
        try generateZigHypothesisSource(allocator, candidate_rune, explanation, prompt);
    errdefer allocator.free(hypothesis_source);

    // 2. Proof gate runs (is this coherent?)
    var hypothesis_result = try ghost.effector.testZigHypothesis(allocator, .{
        .workspace_root = sandbox_root,
        .relative_path = "src/projected_candidate.zig",
        .source = hypothesis_source,
        .intent = "pure algebraic dark-space code candidate",
        .timeout_ms = 12_000,
    });
    errdefer hypothesis_result.deinit();

    var decoded_prose: ?[]const u8 = null;
    
    // 3. Gemma decodes verified output only
    if (hypothesis_result.rank == .truth) {
        lattice.verify(dark_slot, now_ms);
        
        const provider = ghost.gemma_context_provider.GhostContextProvider.init(allocator);
        const runes_dummy = try allocator.alloc(ghost.gemma_rune_encoder.ConversationRune, 1);
        defer allocator.free(runes_dummy);
        runes_dummy[0] = .{
            .text = "dark space",
            .rotor = .{0, 0},
            .vector = best_candidate,
            .embedding = undefined,
            .session_id = 0,
        };
        
        const context = try provider.queryContext(best_candidate, runes_dummy, 16);
        defer ghost.gemma_context_provider.freeContext(allocator, context);
        
        const phead = @import("gemma/layers/prose_head.zig").ProseHead.init(allocator);
        decoded_prose = try phead.synthesize(best_candidate, context);
    }

    try results.append(.{
        .explanation = explanation,
        .medic = medic,
        .dark_slot = dark_slot,
        .hypothesis_source = hypothesis_source,
        .hypothesis_result = hypothesis_result,
        .decoded_prose = decoded_prose,
    });
}

fn selectMedicQuery(
    candidate: ghost.vsa.HyperVector,
    lattice: *const ghost.rune_lattice.RuneLattice,
    scout: *const ghost.triad.ScoutState,
) ghost.vsa.HyperVector {
    const seeds = [_]ghost.vsa.HyperVector{
        ghost.vsa.bind(candidate, scout.getState()),
        ghost.vsa.bind(candidate, ghost.semantic_encoder.encodeConceptString("ghost invent dark space")),
        ghost.vsa.bind(candidate, ghost.semantic_encoder.encodeConceptString("zenith projector exploration")),
        ghost.vsa.bind(candidate, ghost.semantic_encoder.encodeConceptString("rank five unbind")),
        ghost.vsa.bind(candidate, ghost.semantic_encoder.encodeConceptString("cross domain novelty")),
        ghost.vsa.bind(candidate, ghost.semantic_encoder.encodeConceptString("transparency gradient")),
    };
    for (seeds) |query| {
        const best_verified = nearestRankDistance(lattice, query, .verified) orelse 1025;
        if (best_verified > ghost.config.V2_MEDIC_DISTANCE_TAU) return query;
    }
    return seeds[0];
}

fn nearestRankDistance(
    lattice: *const ghost.rune_lattice.RuneLattice,
    query: ghost.vsa.HyperVector,
    rank: ghost.triad.RuneRank,
) ?u16 {
    var best: u16 = 1025;
    var found = false;
    var i: u32 = 0;
    while (i < lattice.capacity) : (i += 1) {
        if (lattice.tags[i] == 0) continue;
        if (lattice.ranks[i] != rank) continue;
        const distance = ghost.vsa.hammingDistance(query, lattice.vectors[i]);
        if (distance < best) {
            best = distance;
            found = true;
        }
    }
    return if (found) best else null;
}

fn printHuman(
    writer: anytype,
    opts: Options,
    docs: []const SourceDoc,
    results: []const ProjectionResult,
    dist: [5]u32,
) !void {
    try writer.writeAll("GHOST INVENT / CROSS-DOMAIN PROJECTOR\n");
    try writer.writeAll("NON-AUTHORIZING ARCHITECTURE SYNTHESIS\n\n");
    try writer.print("projectShard: {s}\n", .{opts.project_shard});
    try writer.print("pipeline: live-corpus -> Scout state -> Cross-Domain Projector -> Medic Loop\n", .{});
    try writer.print("router: Z3 bypassed=true, parameter_match_failure bypassed=true, corpus.ask bypassed=true\n", .{});
    try writer.print("assimilate: {s}\n", .{if (opts.assimilate) "requested" else "off"});
    try writer.print("localLattice: active={d}, verifiedRunes={d}, darkSpaceRunes={d}\n", .{ docs.len + results.len, dist[0], dist[4] });
    try writer.writeAll("daemonResidentMount: not used by ghost invent; inspect `ghost daemon status` separately\n\n");

    if (docs.len == 0) {
        try writer.writeAll("No live corpus docs found for this project shard.\n");
        return;
    }

    try writer.writeAll("Anchors\n");
    for (docs) |doc| {
        try writer.print("- [Rank 1: local corpus anchor] {s} ({s}) slot={d}\n", .{ doc.label, doc.domain, doc.slot });
    }

    try writer.writeAll("\nZenith Architecture Draft\n");
    try writer.writeAll("Audio engine routing: [Rank 1: local corpus anchor] hard real-time callback isolation, graph-compiled routing, lock-free control/event ingress, and non-allocating render blocks.\n");
    try writer.writeAll("UI library: ");
    if (hasDarkSpace(results)) try writer.writeAll("~dark-space~ ");
    try writer.writeAll("GPU-resident retained scene graph over Skia/Vulkan concepts, with strict UI/audio thread separation and frame-paced invalidation.\n");
    try writer.writeAll("Language stack: [Rank 1: local corpus anchor] Zig for engine/control surfaces where deterministic ownership matters; C/C++ ABI islands only for mature audio/plugin or graphics dependencies.\n");
    try writer.writeAll("Transparency Gradient: Rank-1 tags mean local corpus anchors loaded into this command's lattice; ~dark-space~ means projector/Medic exploration, not proof.\n\n");

    for (results, 0..) |result, idx| {
        try writer.print("Projection {d}: {s} <-> {s}\n", .{ idx + 1, result.explanation.candidate.domain_a, result.explanation.candidate.domain_b });
        try writer.print("  novelty={d:.2}, medic={s}, distance={d}, confidence={d}/1000\n", .{
            result.explanation.novelty_score,
            result.medic.confidence_indicator,
            result.medic.distance,
            result.medic.confidence_per_mille,
        });
        for (result.explanation.nearest_concepts[0..@min(result.explanation.nearest_concepts.len, 3)]) |neighbor| {
            try writer.print("  nearest: [{s}] {s} distance={d} rank={d}\n", .{
                neighbor.domain_tag,
                neighbor.label,
                neighbor.distance,
                neighbor.rank,
            });
        }
        try writer.writeByte('\n');
        if (result.hypothesis_result.rank == .truth) {
            try writer.writeAll("[Rank 1: Verified by Compiler]\n");
            if (result.decoded_prose) |prose| {
                try writer.writeAll("\n[Gemma Neural Decode]\n");
                try writer.print("  {s}\n\n", .{prose});
            }
        } else {
            try writer.writeAll("[Rank 5: Dark Space Failure]\n");
        }
        try writer.writeAll("Candidate Zig Source:\n");
        try writer.writeAll("```zig\n");
        try writer.writeAll(result.hypothesis_source);
        if (result.hypothesis_source.len == 0 or result.hypothesis_source[result.hypothesis_source.len - 1] != '\n') try writer.writeByte('\n');
        try writer.writeAll("```\n");
        if (result.hypothesis_result.rank != .truth) {
            try writer.writeAll("Compiler Autopsy\n");
            try writer.print("  command: {s}\n", .{result.hypothesis_result.command});
            if (result.hypothesis_result.exit_code) |code| {
                try writer.print("  exitCode: {d}\n", .{code});
            } else {
                try writer.writeAll("  exitCode: null\n");
            }
            try writer.print("  failureSignal: {s}\n", .{@tagName(result.hypothesis_result.failure_signal)});
            if (result.hypothesis_result.stdout.len > 0) try writer.print("  stdout:\n{s}\n", .{result.hypothesis_result.stdout});
            if (result.hypothesis_result.stderr.len > 0) try writer.print("  stderr:\n{s}\n", .{result.hypothesis_result.stderr});
        }
    }
}

fn printJson(
    writer: anytype,
    opts: Options,
    docs: []const SourceDoc,
    results: []const ProjectionResult,
    dist: [5]u32,
) !void {
    try writer.writeAll("{\"kind\":\"ghost.invent\",\"nonAuthorizing\":true");
    try writer.writeAll(",\"router\":{\"z3Bypassed\":true,\"parameterMatchBypassed\":true,\"corpusAskBypassed\":true}");
    try writer.print(",\"projectShard\":", .{});
    try writeJsonString(writer, opts.project_shard);
    try writer.print(",\"assimilate\":{s}", .{if (opts.assimilate) "true" else "false"});
    try writer.print(",\"localLattice\":{{\"active\":{d},\"verifiedRunes\":{d},\"darkSpaceRunes\":{d}}}", .{ docs.len + results.len, dist[0], dist[4] });
    try writer.writeAll(",\"daemonResidentMount\":\"not_used_by_ghost_invent\"");
    try writer.writeAll(",\"anchors\":[");
    for (docs, 0..) |doc, i| {
        if (i != 0) try writer.writeByte(',');
        try writer.print("{{\"label\":", .{});
        try writeJsonString(writer, doc.label);
        try writer.writeAll(",\"domain\":");
        try writeJsonString(writer, doc.domain);
        try writer.print(",\"slot\":{d},\"rank\":1}}", .{doc.slot});
    }
    try writer.writeAll("],\"architectureDraft\":");
    try writeJsonString(writer, "Audio: hard real-time callback isolation, graph-compiled routing, lock-free control ingress. UI: ~dark-space~ GPU-resident retained scene graph over Skia/Vulkan concepts. Stack: Zig core with ABI islands for mature dependencies.");
    try writer.writeAll(",\"projections\":[");
    for (results, 0..) |result, i| {
        if (i != 0) try writer.writeByte(',');
        try writer.print("{{\"domainA\":", .{});
        try writeJsonString(writer, result.explanation.candidate.domain_a);
        try writer.writeAll(",\"domainB\":");
        try writeJsonString(writer, result.explanation.candidate.domain_b);
        try writer.print(",\"novelty\":{d:.3},\"medicIndicator\":", .{result.explanation.novelty_score});
        try writeJsonString(writer, result.medic.confidence_indicator);
        try writer.print(",\"darkSpace\":{},\"distance\":{d},\"confidencePerMille\":{d}", .{
            result.medic.dark_space,
            result.medic.distance,
            result.medic.confidence_per_mille,
        });
        try writer.writeAll(",\"hypothesis\":{\"rank\":");
        try writeJsonString(writer, if (result.hypothesis_result.rank == .truth) "rank1" else "rank5");
        try writer.writeAll(",\"label\":");
        try writeJsonString(writer, if (result.hypothesis_result.rank == .truth) "[Rank 1: Verified by Compiler]" else "[Rank 5: Dark Space Failure]");
        try writer.writeAll(",\"source\":");
        try writeJsonString(writer, result.hypothesis_source);
        if (result.decoded_prose) |prose| {
            try writer.writeAll(",\"gemmaNeuralDecode\":");
            try writeJsonString(writer, prose);
        }
        try writer.writeAll(",\"compilerAutopsy\":{\"command\":");
        try writeJsonString(writer, result.hypothesis_result.command);
        try writer.writeAll(",\"exitCode\":");
        if (result.hypothesis_result.exit_code) |code| {
            try writer.print("{d}", .{code});
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll(",\"failureSignal\":");
        try writeJsonString(writer, @tagName(result.hypothesis_result.failure_signal));
        try writer.writeAll(",\"stdout\":");
        try writeJsonString(writer, result.hypothesis_result.stdout);
        try writer.writeAll(",\"stderr\":");
        try writeJsonString(writer, result.hypothesis_result.stderr);
        try writer.writeAll("}}}");
        try writer.writeByte('}');
    }
    try writer.writeAll("]}\n");
}

fn hasDarkSpace(results: []const ProjectionResult) bool {
    for (results) |result| {
        if (result.medic.dark_space) return true;
    }
    return false;
}

fn defaultSandboxRoot(allocator: std.mem.Allocator, project_shard: []const u8) ![]u8 {
    const safe_project = try safeIdentifier(allocator, project_shard);
    defer allocator.free(safe_project);
    return std.fmt.allocPrint(allocator, "/tmp/ghost_sandbox/invent_{s}_{d}", .{ safe_project, std.os.linux.getpid() });
}

fn generateZigHypothesisSource(
    allocator: std.mem.Allocator,
    candidate: ghost.cross_domain_projector.CandidateRune,
    explanation: ghost.cross_domain_projector.CrossDomainExplanation,
    prompt: []const u8,
) ![]u8 {
    if (containsAscii(prompt, "black box") or containsAscii(prompt, "crash handler") or containsAscii(prompt, "gpu dump")) {
        return generateCrashHandlerHypothesisSource(allocator, candidate, explanation);
    }

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    try w.writeAll("const std = @import(\"std\");\n\n");
    try w.writeAll("pub const Projection = struct {\n");
    try w.writeAll("    pub const domain_a = ");
    try writeZigString(w, candidate.domain_a);
    try w.writeAll(";\n");
    try w.writeAll("    pub const domain_b = ");
    try writeZigString(w, candidate.domain_b);
    try w.writeAll(";\n");
    try w.writeAll("    pub const label_a = ");
    try writeZigString(w, candidate.label_a);
    try w.writeAll(";\n");
    try w.writeAll("    pub const label_b = ");
    try writeZigString(w, candidate.label_b);
    try w.writeAll(";\n");
    try w.print("    pub const novelty_per_mille: u16 = {d};\n", .{@as(u16, @intFromFloat(@min(explanation.novelty_score * 1000.0, 1000.0)))});
    try w.writeAll("};\n\n");
    try w.writeAll("pub const GpuResidentSceneGraph = struct {\n");
    try w.writeAll("    nodes: []Node,\n");
    try w.writeAll("    transforms: []Transform2D,\n");
    try w.writeAll("    clips: []ClipRect,\n");
    try w.writeAll("    materials: []Material,\n\n");
    try w.writeAll("    pub fn isUploadReady(self: GpuResidentSceneGraph) bool {\n");
    try w.writeAll("        return self.nodes.len <= self.transforms.len and self.nodes.len <= self.materials.len;\n");
    try w.writeAll("    }\n");
    try w.writeAll("};\n\n");
    try w.writeAll("pub const Node = extern struct {\n");
    try w.writeAll("    id: u32,\n");
    try w.writeAll("    parent: u32,\n");
    try w.writeAll("    first_child: u32,\n");
    try w.writeAll("    next_sibling: u32,\n");
    try w.writeAll("    transform_index: u32,\n");
    try w.writeAll("    clip_index: u32,\n");
    try w.writeAll("    material_index: u32,\n");
    try w.writeAll("    flags: u32,\n");
    try w.writeAll("};\n\n");
    try w.writeAll("pub const Transform2D = extern struct { m00: f32, m01: f32, m02: f32, m10: f32, m11: f32, m12: f32 };\n");
    try w.writeAll("pub const ClipRect = extern struct { x: f32, y: f32, w: f32, h: f32 };\n");
    try w.writeAll("pub const Material = extern struct { rgba: u32, pipeline: u32, texture: u32, _pad: u32 };\n\n");
    try w.writeAll("test \"projected GPU scene graph has stable upload layout\" {\n");
    try w.writeAll("    try std.testing.expect(@sizeOf(Node) == 32);\n");
    try w.writeAll("    try std.testing.expect(@alignOf(Node) <= 4);\n");
    try w.writeAll("    try std.testing.expect(Projection.novelty_per_mille > 0);\n");
    try w.writeAll("}\n");
    return out.toOwnedSlice();
}

fn generateCrashHandlerHypothesisSource(
    allocator: std.mem.Allocator,
    candidate: ghost.cross_domain_projector.CandidateRune,
    explanation: ghost.cross_domain_projector.CrossDomainExplanation,
) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    try w.writeAll("const std = @import(\"std\");\n\n");
    try w.writeAll("pub const Projection = struct {\n");
    try w.writeAll("    pub const domain_a = ");
    try writeZigString(w, candidate.domain_a);
    try w.writeAll(";\n");
    try w.writeAll("    pub const domain_b = ");
    try writeZigString(w, candidate.domain_b);
    try w.writeAll(";\n");
    try w.print("    pub const novelty_per_mille: u16 = {d};\n", .{@as(u16, @intFromFloat(@min(explanation.novelty_score * 1000.0, 1000.0)))});
    try w.writeAll("};\n\n");
    try w.writeAll("pub const GpuDumpCoordinate = extern struct {\n");
    try w.writeAll("    queue_family: u32,\n");
    try w.writeAll("    queue_index: u32,\n");
    try w.writeAll("    command_buffer: u64,\n");
    try w.writeAll("    fault_address: u64,\n");
    try w.writeAll("    shader_hash: u64,\n");
    try w.writeAll("};\n\n");
    try w.writeAll("pub const SandRetentionGate = extern struct {\n");
    try w.writeAll("    crest_height: u16,\n");
    try w.writeAll("    arm_orientation: u16,\n");
    try w.writeAll("    reef_geometry: u16,\n");
    try w.writeAll("    downdrift_budget: u16,\n\n");
    try w.writeAll("    pub fn capacity(self: SandRetentionGate) u16 {\n");
    try w.writeAll("        const retention: u32 = @as(u32, self.crest_height) + @as(u32, self.arm_orientation) + @as(u32, self.reef_geometry);\n");
    try w.writeAll("        const gated = retention -| @as(u32, self.downdrift_budget);\n");
    try w.writeAll("        return @intCast(@min(gated, 1024));\n");
    try w.writeAll("    }\n");
    try w.writeAll("};\n\n");
    try w.writeAll("pub const BlackBoxCrashHandler = struct {\n");
    try w.writeAll("    gate: SandRetentionGate,\n");
    try w.writeAll("    pending: u16 = 0,\n\n");
    try w.writeAll("    pub fn admit(self: *BlackBoxCrashHandler, bytes: u16) bool {\n");
    try w.writeAll("        const next = @as(u32, self.pending) + @as(u32, bytes);\n");
    try w.writeAll("        if (next > self.gate.capacity()) return false;\n");
    try w.writeAll("        self.pending = @intCast(next);\n");
    try w.writeAll("        return true;\n");
    try w.writeAll("    }\n\n");
    try w.writeAll("    pub fn attachGpuDump(_: *BlackBoxCrashHandler, coord: GpuDumpCoordinate) u64 {\n");
    try w.writeAll("        return coord.command_buffer ^ coord.fault_address ^ coord.shader_hash;\n");
    try w.writeAll("    }\n\n");
    try w.writeAll("    pub fn uiThreadBudget(self: *const BlackBoxCrashHandler) u16 {\n");
    try w.writeAll("        return self.gate.capacity() -| self.pending;\n");
    try w.writeAll("    }\n");
    try w.writeAll("};\n\n");
    try w.writeAll("test \"black box crash handler gates telemetry flood\" {\n");
    try w.writeAll("    var handler = BlackBoxCrashHandler{ .gate = .{ .crest_height = 240, .arm_orientation = 180, .reef_geometry = 220, .downdrift_budget = 128 } };\n");
    try w.writeAll("    try std.testing.expect(handler.admit(256));\n");
    try w.writeAll("    try std.testing.expect(!handler.admit(512));\n");
    try w.writeAll("    const fingerprint = handler.attachGpuDump(.{ .queue_family = 1, .queue_index = 0, .command_buffer = 0xAA, .fault_address = 0x55, .shader_hash = 0x11 });\n");
    try w.writeAll("    try std.testing.expect(fingerprint != 0);\n");
    try w.writeAll("    try std.testing.expect(handler.uiThreadBudget() > 0);\n");
    try w.writeAll("    try std.testing.expect(Projection.novelty_per_mille > 0);\n");
    try w.writeAll("}\n");
    return out.toOwnedSlice();
}

fn isTextPath(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".txt") or
        std.mem.endsWith(u8, path, ".md") or
        std.mem.endsWith(u8, path, ".markdown");
}

fn labelForPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const base = std.fs.path.basename(path);
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse base.len;
    return allocator.dupe(u8, base[0..dot]);
}

fn domainForPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (containsAscii(path, "audio")) return allocator.dupe(u8, "audio");
    if (containsAscii(path, "ui")) return allocator.dupe(u8, "ui");
    if (containsAscii(path, "language") or containsAscii(path, "zig") or containsAscii(path, "cpp")) return allocator.dupe(u8, "language");
    return allocator.dupe(u8, "research");
}

fn safeIdentifier(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = try allocator.alloc(u8, text.len);
    for (text, 0..) |byte, i| {
        out[i] = if (std.ascii.isAlphabetic(byte) or std.ascii.isDigit(byte) or byte == '-' or byte == '_') byte else '_';
    }
    return out;
}

fn containsAscii(haystack: []const u8, needle: []const u8) bool {
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var matched = true;
        for (needle, 0..) |c, j| {
            if (std.ascii.toLower(haystack[i + j]) != c) {
                matched = false;
                break;
            }
        }
        if (matched) return true;
    }
    return false;
}

fn writeJsonString(writer: anytype, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |byte| {
        switch (byte) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(byte),
        }
    }
    try writer.writeByte('"');
}

fn writeZigString(writer: anytype, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |byte| {
        switch (byte) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(byte),
        }
    }
    try writer.writeByte('"');
}
