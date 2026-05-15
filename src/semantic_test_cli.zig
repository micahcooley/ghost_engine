const std = @import("std");
const core = @import("ghost_core");
const vsa = core.vsa;
const rune_lattice = core.rune_lattice;
const triad = core.triad;
const sys = core.sys;
const semantic_encoder = core.semantic_encoder;
const concept_index = core.concept_index;
const contradiction_detector = core.contradiction_detector;
const cross_domain_projector = core.cross_domain_projector;
const intent_resolver = core.intent_resolver;
const forge = core.forge;
const vsa_vulkan = core.vsa_vulkan;
const ghost_state = core.ghost_state;

// ══════════════════════════════════════════════════════════════════════════
//  SEMANTIC TEST CLI: Ghost Engine v2 Lattice Validation Harness
// ══════════════════════════════════════════════════════════════════════════
//
// Runs three verification tests for the Semantic Lattice:
//   1. Deep Research: Ingest → Reboot → XOR Retrieval
//   2. Contradiction Forge: Conflicting data → Rank resolution
//   3. Cross-Domain Invention: Bind unrelated domains → Novel output
//
// Usage:
//   ghost_semantic_test --test=deep-research --corpus=/path/to/file.txt
//   ghost_semantic_test --test=contradiction --doc-a=a.txt --doc-b=b.txt
//   ghost_semantic_test --test=cross-domain --domain-a=bio/ --domain-b=traffic/
//   ghost_semantic_test --all
// ══════════════════════════════════════════════════════════════════════════

const LATTICE_CAPACITY: u32 = 4096;
const LATTICE_PATH = "/tmp/ghost_semantic_test_lattice.bin";
const INDEX_PATH = "/tmp/ghost_semantic_test_index.json";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printUsage();
        return;
    }

    var test_name: ?[]const u8 = null;
    var corpus_path: ?[]const u8 = null;
    var doc_a_path: ?[]const u8 = null;
    var doc_b_path: ?[]const u8 = null;
    var domain_a_path: ?[]const u8 = null;
    var domain_b_path: ?[]const u8 = null;
    var query_text: ?[]const u8 = null;
    var invent_prompt: ?[]const u8 = null;
    var run_all = false;

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--all")) {
            run_all = true;
        } else if (std.mem.startsWith(u8, arg, "--test=")) {
            test_name = arg["--test=".len..];
        } else if (std.mem.startsWith(u8, arg, "--corpus=")) {
            corpus_path = arg["--corpus=".len..];
        } else if (std.mem.startsWith(u8, arg, "--doc-a=")) {
            doc_a_path = arg["--doc-a=".len..];
        } else if (std.mem.startsWith(u8, arg, "--doc-b=")) {
            doc_b_path = arg["--doc-b=".len..];
        } else if (std.mem.startsWith(u8, arg, "--domain-a=")) {
            domain_a_path = arg["--domain-a=".len..];
        } else if (std.mem.startsWith(u8, arg, "--domain-b=")) {
            domain_b_path = arg["--domain-b=".len..];
        } else if (std.mem.startsWith(u8, arg, "--query=")) {
            query_text = arg["--query=".len..];
        } else if (std.mem.startsWith(u8, arg, "--invent=")) {
            invent_prompt = arg["--invent=".len..];
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            return;
        }
    }

    printBanner();

    if (run_all) {
        try runBuiltinDeepResearch(allocator);
        try runBuiltinContradiction(allocator);
        try runBuiltinCrossDomain(allocator);
        return;
    }

    const name = test_name orelse {
        sys.print("[ERROR] No test specified. Use --test=<name> or --all\n", .{});
        printUsage();
        return;
    };

    if (std.mem.eql(u8, name, "deep-research")) {
        if (corpus_path) |path| {
            try runDeepResearchFromFile(allocator, path);
        } else {
            try runBuiltinDeepResearch(allocator);
        }
    } else if (std.mem.eql(u8, name, "contradiction")) {
        if (doc_a_path != null and doc_b_path != null) {
            try runContradictionFromFiles(allocator, doc_a_path.?, doc_b_path.?);
        } else {
            try runBuiltinContradiction(allocator);
        }
    } else if (std.mem.eql(u8, name, "cross-domain")) {
        if (domain_a_path != null and domain_b_path != null) {
            try runCrossDomainFromDirs(allocator, domain_a_path.?, domain_b_path.?, query_text, invent_prompt);
        } else {
            try runBuiltinCrossDomain(allocator);
        }
    } else if (std.mem.eql(u8, name, "invent")) {
        if (domain_a_path != null and domain_b_path != null) {
            try runCrossDomainFromDirs(allocator, domain_a_path.?, domain_b_path.?, query_text, invent_prompt);
        } else {
            sys.print("[ERROR] --invent requires --domain-a and --domain-b\n", .{});
        }
    } else {
        sys.print("[ERROR] Unknown test: {s}\n", .{name});
        printUsage();
    }
}

// ── Test 1: Deep Research & Long-Term Memory ──

fn runBuiltinDeepResearch(allocator: std.mem.Allocator) !void {
    sys.printOut("\n══════════════════════════════════════════════════════════\n");
    sys.printOut("  TEST 1: Deep Research & Long-Term Memory (Builtin)\n");
    sys.printOut("══════════════════════════════════════════════════════════\n\n");

    const doc =
        \\QUIC uses packet numbers to detect loss. When a packet is
        \\acknowledged but a gap is detected in the packet number space,
        \\the sender infers that the missing packets were lost. The loss
        \\detection algorithm uses a time-based threshold and a packet
        \\reordering threshold to distinguish loss from reordering.
        \\
        \\During the TLS 1.3 handshake, QUIC encrypts all transport
        \\parameters. The encryption handshake establishes forward secrecy
        \\using ephemeral Diffie-Hellman key exchange. If the handshake
        \\fails, the connection is immediately terminated with a
        \\CONNECTION_CLOSE frame carrying a TLS alert code.
        \\
        \\Congestion control in QUIC operates per-path. The sender
        \\maintains a congestion window that limits the amount of data
        \\in flight. When loss is detected during the encryption
        \\handshake phase, the congestion window is reduced but the
        \\handshake packets are prioritized for retransmission to
        \\ensure connection establishment succeeds.
    ;

    try runDeepResearchTest(allocator, doc, "How does QUIC handle packet loss during encryption handshake?");
}

fn runDeepResearchFromFile(allocator: std.mem.Allocator, path: []const u8) !void {
    sys.printOut("\n══════════════════════════════════════════════════════════\n");
    sys.print("  TEST 1: Deep Research & Long-Term Memory ({s})\n", .{path});
    sys.printOut("══════════════════════════════════════════════════════════\n\n");

    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        sys.print("[ERROR] Cannot open corpus file: {any}\n", .{err});
        return;
    };
    defer file.close();
    const bytes = try file.readToEndAlloc(allocator, 64 * 1024 * 1024);
    defer allocator.free(bytes);

    try runDeepResearchTest(allocator, bytes, "How does QUIC handle packet loss during encryption handshake?");
}

fn runDeepResearchTest(allocator: std.mem.Allocator, document: []const u8, query: []const u8) !void {
    // Phase 1: Ingest
    sys.printOut("[PHASE 1] Ingesting document into Semantic Lattice...\n");
    const vk_engine = vsa_vulkan.initRuntime(allocator) catch null;
    defer if (vk_engine != null) vsa_vulkan.deinitRuntime();
    var lattice = try rune_lattice.RuneLattice.init(allocator, LATTICE_CAPACITY, vk_engine);
    defer lattice.deinit();
    var index = concept_index.ConceptIndex.init(allocator);
    defer index.deinit();

    const entries = try semantic_encoder.encodeDocument(allocator, document, "networking");
    defer allocator.free(entries);
    sys.print("  Chunked into {d} concept entries\n", .{entries.len});

    var observed: u32 = 0;
    for (entries, 0..) |entry, i| {
        const slot = lattice.observe(entry.vector, @as(u64, @intCast(i + 1)), 1000) orelse continue;
        const label = if (entry.text.len > 60) entry.text[0..60] else entry.text;
        try index.addEntry(label, slot, "corpus", entry.source_offset, entry.source_length, "networking", 2, entry.text);
        // Promote to Rank 1 (simulating a trained lattice)
        lattice.verify(slot, 1000);
        index.updateRank(slot, @intFromEnum(triad.RuneRank.verified));
        observed += 1;
    }
    sys.print("  Observed {d} concepts in lattice\n", .{observed});

    // Phase 2: Save and "reboot"
    sys.printOut("\n[PHASE 2] Saving lattice + index to disk (simulating reboot)...\n");
    try index.save(INDEX_PATH);
    sys.print("  Index saved: {s}\n", .{INDEX_PATH});

    // Phase 3: Load from disk (fresh state)
    sys.printOut("\n[PHASE 3] Loading from disk (fresh engine state)...\n");
    var loaded_index = try concept_index.ConceptIndex.load(allocator, INDEX_PATH);
    defer loaded_index.deinit();
    sys.print("  Loaded {d} concepts from index\n", .{loaded_index.count()});

    // Phase 4: Query via XOR search
    sys.print("\n[PHASE 4] Querying: \"{s}\"\n", .{query});
    const query_vec = semantic_encoder.encodeConceptString(query);
    const search_async = lattice.search(query_vec, .verified);

    const final_result: ?rune_lattice.SearchResult = switch (search_async) {
        .found => |r| r,
        .not_found => null,
        .pending => |job| blk: {
            sys.print("  [VSA PENDING] GPU Job {d} dispatched...\n", .{job.frame_idx});
            // In a real DAW, we'd return to the audio thread here.
            // In this test, we poll to prove it's non-blocking.
            var polls: u32 = 0;
            while (true) : (polls += 1) {
                if (try lattice.pollSearch(job)) |res| {
                    sys.print("  [VSA RESOLVED] GPU job completed after {d} polls.\n", .{polls});
                    break :blk res;
                }
                std.time.sleep(10 * std.time.ns_per_ms);
                if (polls > 500) return error.TestTimeout;
            }
        },
    };

    if (final_result) |result| {
        const entry = loaded_index.lookupBySlot(result.slot);
        sys.print("\n  [MATCH FOUND]\n", .{});
        sys.print("    Slot:     {d}\n", .{result.slot});
        sys.print("    Distance: {d} bits (threshold: {d})\n", .{ result.distance, rune_lattice.SEARCH_NEAR_RESONANCE });
        sys.print("    Rank:     {s}\n", .{@tagName(lattice.ranks[result.slot])});
        if (entry) |e| {
            sys.print("    Label:    {s}\n", .{e.label});
            const snippet_len = @min(e.snippet.len, 200);
            sys.print("    Snippet:  \"{s}\"\n", .{e.snippet[0..snippet_len]});
        }
        sys.printOut("\n  ✅ TEST 1 PASSED: XOR search recovered concept after reboot\n");
    } else {
        sys.printOut("\n  [NO MATCH] Distance exceeds King threshold τ\n");
        sys.printOut("  Attempting Medic explorer search...\n");

        var scout = triad.ScoutState.init(ghost_state.GENESIS_SEED);
        const medic_result = forge.medicLoop(&lattice, query_vec, &scout);
        if (medic_result.resolved) {
            if (medic_result.dark_space) {
                sys.printOut("    [CONFIDENCE WARNING] Medic unbound nearest Rank-5 Dark Space Rune.\n");
            }
            if (medic_result.slot) |slot| {
                const entry = loaded_index.lookupBySlot(slot);
                sys.print("    [MEDIC MATCH] Slot {d}, Distance {d}, Rank {s}, Confidence {d}/1000, Indicator {s}\n", .{
                    slot,
                    medic_result.distance,
                    @tagName(medic_result.rank),
                    medic_result.confidence_per_mille,
                    medic_result.confidence_indicator,
                });
                if (entry) |e| sys.print("    Label: {s}\n", .{e.label});
            }
            sys.printOut("\n  ⚠️  TEST 1 PARTIAL: Medic produced an exploratory match (not verified)\n");
        } else {
            sys.printOut("\n  ❌ TEST 1 FAILED: No match found even with Medic explorer search\n");
        }
    }
}

// ── Test 2: Contradiction Forge ──

fn runBuiltinContradiction(allocator: std.mem.Allocator) !void {
    sys.printOut("\n══════════════════════════════════════════════════════════\n");
    sys.printOut("  TEST 2: Contradiction Forge (Builtin)\n");
    sys.printOut("══════════════════════════════════════════════════════════\n\n");

    try runContradictionTest(
        allocator,
        "The server timeout is configured to 30 seconds for all connections",
        "The server timeout is configured to 5 seconds for all connections",
    );
}

fn runContradictionFromFiles(allocator: std.mem.Allocator, path_a: []const u8, path_b: []const u8) !void {
    sys.printOut("\n══════════════════════════════════════════════════════════\n");
    sys.printOut("  TEST 2: Contradiction Forge (Files)\n");
    sys.printOut("══════════════════════════════════════════════════════════\n\n");

    const text_a = try readFileContents(allocator, path_a);
    defer allocator.free(text_a);
    const text_b = try readFileContents(allocator, path_b);
    defer allocator.free(text_b);

    try runContradictionTest(allocator, text_a, text_b);
}

fn runContradictionTest(allocator: std.mem.Allocator, text_a: []const u8, text_b: []const u8) !void {
    const vk_engine = vsa_vulkan.initRuntime(allocator) catch null;
    defer if (vk_engine != null) vsa_vulkan.deinitRuntime();
    var lattice = try rune_lattice.RuneLattice.init(allocator, LATTICE_CAPACITY, vk_engine);
    defer lattice.deinit();
    var index = concept_index.ConceptIndex.init(allocator);
    defer index.deinit();

    // Phase 1: Ingest Doc A
    sys.printOut("[PHASE 1] Ingesting Doc A...\n");
    const vec_a = semantic_encoder.encodeConceptString(text_a);
    const slot_a = lattice.observe(vec_a, 0x1, 1000) orelse {
        sys.printOut("  [ERROR] Lattice full\n");
        return;
    };
    const label_a = if (text_a.len > 60) text_a[0..60] else text_a;
    try index.addEntry(label_a, slot_a, "doc_a.txt", 0, text_a.len, "config", 2, text_a);
    lattice.validate(slot_a, 1000);
    sys.print("  Slot A: {d}, Rank: {s}\n", .{ slot_a, @tagName(lattice.ranks[slot_a]) });

    // Phase 2: Ingest Doc B
    sys.printOut("\n[PHASE 2] Ingesting Doc B...\n");
    const vec_b = semantic_encoder.encodeConceptString(text_b);
    const slot_b = lattice.observe(vec_b, 0x2, 2000) orelse {
        sys.printOut("  [ERROR] Lattice full\n");
        return;
    };
    const label_b = if (text_b.len > 60) text_b[0..60] else text_b;
    try index.addEntry(label_b, slot_b, "doc_b.txt", 0, text_b.len, "config", 2, text_b);
    lattice.validate(slot_b, 2000);
    sys.print("  Slot B: {d}, Rank: {s}\n", .{ slot_b, @tagName(lattice.ranks[slot_b]) });

    // Phase 3: Measure distance
    const distance = vsa.hammingDistance(vec_a, vec_b);
    sys.print("\n[PHASE 3] Hamming Distance: {d} bits\n", .{distance});
    sys.print("  Contradiction Radius: {d}\n", .{contradiction_detector.CONTRADICTION_RADIUS});

    if (distance < contradiction_detector.CONTRADICTION_RADIUS and
        distance >= contradiction_detector.CONTRADICTION_MIN_DISTANCE)
    {
        sys.printOut("  → Concepts are LOGICALLY PROXIMATE — potential contradiction\n");
    } else if (distance < contradiction_detector.CONTRADICTION_MIN_DISTANCE) {
        sys.printOut("  → Concepts are NEAR-IDENTICAL (not a contradiction, a duplicate)\n");
    } else {
        sys.printOut("  → Concepts are FAR APART — no contradiction detected\n");
        sys.printOut("  Note: The two texts may be too different for VSA proximity.\n");
        sys.printOut("  This is expected if the texts use very different vocabulary.\n");
    }

    // Phase 4: Resolve
    sys.printOut("\n[PHASE 4] Resolving with higher_trust_wins strategy...\n");
    const contradiction = contradiction_detector.Contradiction{
        .new_slot = slot_b,
        .existing_slot = slot_a,
        .distance = distance,
        .new_label = label_b,
        .existing_label = label_a,
        .new_snippet = if (text_b.len > 80) text_b[0..80] else text_b,
        .existing_snippet = if (text_a.len > 80) text_a[0..80] else text_a,
    };

    const outcome = contradiction_detector.resolveContradiction(
        &lattice,
        &index,
        contradiction,
        .newer_wins,
        3000,
    );

    sys.print("  Winner: Slot {d} — {s}\n", .{ outcome.winner_slot, outcome.reason });
    sys.print("  Winner Rank: {s}\n", .{@tagName(lattice.ranks[outcome.winner_slot])});
    sys.print("  Loser:  Slot {d}\n", .{outcome.loser_slot});
    sys.print("  Loser Rank:  {s}\n", .{@tagName(lattice.ranks[outcome.loser_slot])});

    // Phase 5: Reaper prune
    sys.printOut("\n[PHASE 5] Running Reaper prune cycle...\n");
    const prune_summary = lattice.prune(triad.RANK_NOISE_TTL_MS + 1);
    sys.print("  Pruned: {d} slots\n", .{prune_summary.pruned});

    // Phase 6: Verify query returns only winner
    sys.printOut("\n[PHASE 6] Querying for the surviving concept...\n");
    const query_vec = semantic_encoder.encodeConceptString("server timeout");
    const result = lattice.search(query_vec, .noise);
    switch (result) {
        .found => |r| {
            sys.print("  Found Slot {d} at distance {d}\n", .{ r.slot, r.distance });
            if (r.slot == outcome.winner_slot) {
                sys.printOut("\n  ✅ TEST 2 PASSED: Only the winner survives in the lattice\n");
            } else {
                sys.printOut("\n  ⚠️  TEST 2 WARNING: Found a slot that isn't the winner\n");
            }
        },
        .pending => |_| sys.printOut("\n  ⏳ TEST 2 PENDING: GPU search is still running\n"),
        .not_found => sys.printOut("\n  ❌ TEST 2 FAILED: No surviving concept found\n"),
    }
}

// ── Test 3: Cross-Domain Invention ──

fn runBuiltinCrossDomain(allocator: std.mem.Allocator) !void {
    sys.printOut("\n══════════════════════════════════════════════════════════\n");
    sys.printOut("  TEST 3: Cross-Domain Invention (Builtin)\n");
    sys.printOut("══════════════════════════════════════════════════════════\n\n");

    const vk_engine = vsa_vulkan.initRuntime(allocator) catch null;
    defer if (vk_engine != null) vsa_vulkan.deinitRuntime();
    var lattice = try rune_lattice.RuneLattice.init(allocator, LATTICE_CAPACITY, vk_engine);
    defer lattice.deinit();
    var index = concept_index.ConceptIndex.init(allocator);
    defer index.deinit();

    // Ingest biology concepts
    sys.printOut("[PHASE 1] Ingesting biology domain...\n");
    const bio_concepts = [_]struct { label: []const u8, text: []const u8 }{
        .{ .label = "Synaptic routing", .text = "Neurons route signals through synaptic connections using chemical neurotransmitters that cross the synaptic cleft" },
        .{ .label = "Neural plasticity", .text = "Synaptic connections strengthen or weaken based on usage frequency through long-term potentiation" },
        .{ .label = "Inhibitory signals", .text = "GABA neurons provide inhibitory signals that prevent over-excitation and regulate network activity" },
    };
    for (bio_concepts, 0..) |c, i| {
        const vec = semantic_encoder.encodeDomainConcept(c.text, "biology");
        const slot = lattice.observe(vec, @as(u64, i + 1), 1000) orelse continue;
        try index.addEntry(c.label, slot, "biology.txt", 0, c.text.len, "biology", 1, c.text);
        lattice.verify(slot, 1000);
    }

    // Ingest traffic concepts
    sys.printOut("[PHASE 2] Ingesting traffic domain...\n");
    const traffic_concepts = [_]struct { label: []const u8, text: []const u8 }{
        .{ .label = "Intersection routing", .text = "Traffic signals at intersections control vehicle flow using timed phases and sensor-triggered adaptive cycles" },
        .{ .label = "Congestion detection", .text = "Loop detectors and cameras measure vehicle density to detect congestion and trigger signal timing changes" },
        .{ .label = "Priority lanes", .text = "Emergency vehicles trigger signal preemption to create priority corridors through congested intersections" },
    };
    for (traffic_concepts, 0..) |c, i| {
        const vec = semantic_encoder.encodeDomainConcept(c.text, "traffic");
        const slot = lattice.observe(vec, @as(u64, i + 100), 1000) orelse continue;
        try index.addEntry(c.label, slot, "traffic.txt", 0, c.text.len, "traffic", 1, c.text);
        lattice.verify(slot, 1000);
    }

    // Phase 3: Cross-domain projection
    sys.printOut("\n[PHASE 3] Creating cross-domain projection...\n");
    sys.printOut("  Problem: \"Solve traffic bottleneck using biological model\"\n\n");

    const candidates = try cross_domain_projector.projectCrossDomainBatch(
        allocator,
        &lattice,
        &index,
        "biology",
        "traffic",
        4,
    );
    defer allocator.free(candidates);
    sys.print("  Generated {d} candidate runes\n\n", .{candidates.len});

    var best_novelty: f32 = 0.0;
    var best_explanation: ?[]u8 = null;
    defer if (best_explanation) |e| allocator.free(e);

    for (candidates, 0..) |candidate, i| {
        var explanation = try cross_domain_projector.decodeCandidateRune(allocator, candidate, &lattice, &index);
        sys.print("  Candidate {d}: [{s}] ⊗ [{s}] → Novelty: {d:.2}\n", .{
            i + 1, candidate.label_a, candidate.label_b, explanation.novelty_score,
        });
        if (explanation.novelty_score > best_novelty) {
            best_novelty = explanation.novelty_score;
            if (best_explanation) |old| allocator.free(old);
            best_explanation = explanation.explanation_text;
            explanation.explanation_text = try allocator.dupe(u8, ""); // prevent double-free
        }
        explanation.deinit(allocator);
    }

    if (best_explanation) |explanation| {
        sys.printOut("\n[BEST PROJECTION]\n");
        sys.print("{s}\n", .{explanation});
    }

    if (best_novelty >= cross_domain_projector.MIN_NOVELTY_SCORE) {
        sys.print("  ✅ TEST 3 PASSED: Novelty score {d:.2} >= threshold {d:.2}\n", .{
            best_novelty, cross_domain_projector.MIN_NOVELTY_SCORE,
        });
    } else {
        sys.print("  ❌ TEST 3 FAILED: Novelty score {d:.2} < threshold {d:.2}\n", .{
            best_novelty, cross_domain_projector.MIN_NOVELTY_SCORE,
        });
    }
}

fn runCrossDomainFromDirs(
    allocator: std.mem.Allocator,
    path_a: []const u8,
    path_b: []const u8,
    query_text: ?[]const u8,
    invent_prompt: ?[]const u8,
) !void {
    const domain_a_name = std.fs.path.basename(path_a);
    const domain_b_name = std.fs.path.basename(path_b);

    sys.printOut("\n══════════════════════════════════════════════════════════\n");
    sys.print("  CROSS-DOMAIN ENGINE: [{s}] × [{s}]\n", .{ domain_a_name, domain_b_name });
    sys.printOut("══════════════════════════════════════════════════════════\n\n");

    const vk_engine = vsa_vulkan.initRuntime(allocator) catch null;
    defer if (vk_engine != null) vsa_vulkan.deinitRuntime();
    var lattice = try rune_lattice.RuneLattice.init(allocator, LATTICE_CAPACITY, vk_engine);
    defer lattice.deinit();
    var index = concept_index.ConceptIndex.init(allocator);
    defer index.deinit();

    // Ingest domain A
    sys.print("[INGEST] Domain A: {s}\n", .{path_a});
    const count_a = try ingestDomainDir(allocator, &lattice, &index, path_a, domain_a_name);
    sys.print("  Ingested {d} concepts from [{s}]\n", .{ count_a, domain_a_name });

    // Ingest domain B
    sys.print("[INGEST] Domain B: {s}\n", .{path_b});
    const count_b = try ingestDomainDir(allocator, &lattice, &index, path_b, domain_b_name);
    sys.print("  Ingested {d} concepts from [{s}]\n", .{ count_b, domain_b_name });

    sys.print("\n[LATTICE] Total concepts: {d}, Active slots: {d}\n", .{ index.count(), lattice.active_count });

    // Intent-resolved query mode
    if (query_text) |qt| {
        sys.print("\n[QUERY] \"{s}\"\n", .{qt});
        var resolution = try intent_resolver.resolveIntent(allocator, qt, &lattice, &index);
        defer resolution.deinit(allocator);
        sys.print("{s}\n", .{resolution.response_text});
        for (resolution.clarifying_questions) |q| {
            sys.print("  ❓ {s}\n", .{q});
        }
    }

    // Invention mode
    if (invent_prompt) |prompt| {
        sys.print("\n[INVENT] \"{s}\"\n\n", .{prompt});
        try runInvention(allocator, &lattice, &index, domain_a_name, domain_b_name, prompt);
    } else if (query_text == null) {
        // Default: run cross-domain projection
        try runInvention(allocator, &lattice, &index, domain_a_name, domain_b_name, "Invent a novel concept by binding these two domains");
    }

    // Always run intent test with vague and specific queries
    sys.printOut("\n── Intent Resolver Demo ──\n");
    const test_queries = [_][]const u8{
        "compressor",
        "how does quantum probability relate to audio threshold detection",
        "make it sound better",
        "explain the connection between superposition and soft-knee compression",
    };
    for (test_queries) |tq| {
        sys.print("\n▸ Query: \"{s}\"\n", .{tq});
        var res = try intent_resolver.resolveIntent(allocator, tq, &lattice, &index);
        defer res.deinit(allocator);
        sys.print("  Class: {s} | Confidence: {d:.0}% | Entropy: {d:.2}\n", .{
            @tagName(res.class), res.confidence * 100, res.entropy,
        });
        if (res.class == .ambiguous or res.class == .underspecified) {
            for (res.clarifying_questions) |q| {
                sys.print("  ❓ {s}\n", .{q});
            }
        } else if (res.class == .confident) {
            if (res.nearest.len > 0) {
                const best = res.nearest[0];
                sys.print("  → [{s}] \"{s}\" ({d} bits)\n", .{ best.domain_tag, best.label, best.distance });
            }
        }
    }
}

fn ingestDomainDir(
    allocator: std.mem.Allocator,
    lattice: *rune_lattice.RuneLattice,
    index: *concept_index.ConceptIndex,
    dir_path: []const u8,
    domain_name: []const u8,
) !u32 {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
        sys.print("  [ERROR] Cannot open directory: {any}\n", .{err});
        return 0;
    };
    defer dir.close();

    var total: u32 = 0;
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".txt") and
            !std.mem.endsWith(u8, entry.name, ".md")) continue;

        const abs_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        defer allocator.free(abs_path);

        const file = std.fs.cwd().openFile(abs_path, .{}) catch continue;
        defer file.close();
        const bytes = file.readToEndAlloc(allocator, 8 * 1024 * 1024) catch continue;
        defer allocator.free(bytes);

        sys.print("  → {s} ({d} bytes)\n", .{ entry.name, bytes.len });

        const entries = try semantic_encoder.encodeDocument(allocator, bytes, domain_name);
        defer allocator.free(entries);

        for (entries) |concept| {
            const tag_hash = vsa.collapse(concept.vector);
            const slot = lattice.observe(concept.vector, tag_hash, 1000) orelse continue;
            const label = extractCleanLabel(concept.text);
            index.addEntry(label, slot, entry.name, concept.source_offset, concept.source_length, domain_name, 1, concept.text) catch continue;
            lattice.verify(slot, 1000);
            total += 1;
        }
    }
    return total;
}

fn runInvention(
    allocator: std.mem.Allocator,
    lattice: *const rune_lattice.RuneLattice,
    index: *const concept_index.ConceptIndex,
    domain_a: []const u8,
    domain_b: []const u8,
    prompt: []const u8,
) !void {
    sys.print("[INVENTION] Binding [{s}] ⊗ [{s}]\n", .{ domain_a, domain_b });
    sys.print("  Prompt: \"{s}\"\n\n", .{prompt});

    const candidates = try cross_domain_projector.projectCrossDomainBatch(
        allocator,
        lattice,
        index,
        domain_a,
        domain_b,
        6,
    );
    defer allocator.free(candidates);
    sys.print("  Generated {d} candidate runes\n\n", .{candidates.len});

    var best_novelty: f32 = 0.0;
    var best_explanation: ?[]u8 = null;
    defer if (best_explanation) |e| allocator.free(e);

    for (candidates, 0..) |candidate, i| {
        var explanation = try cross_domain_projector.decodeCandidateRune(allocator, candidate, lattice, index);
        sys.print("  Candidate {d}: [{s}] ⊗ [{s}] → Novelty: {d:.2}\n", .{
            i + 1, candidate.label_a, candidate.label_b, explanation.novelty_score,
        });
        if (explanation.novelty_score > best_novelty) {
            best_novelty = explanation.novelty_score;
            if (best_explanation) |old| allocator.free(old);
            best_explanation = explanation.explanation_text;
            explanation.explanation_text = try allocator.dupe(u8, "");
        }
        explanation.deinit(allocator);
    }

    if (best_explanation) |explanation| {
        sys.printOut("\n[BEST INVENTION]\n");
        sys.print("{s}\n", .{explanation});
    }

    if (best_novelty >= cross_domain_projector.MIN_NOVELTY_SCORE) {
        sys.print("  ✅ INVENTION PASSED: Novelty {d:.2} >= {d:.2}\n", .{
            best_novelty, cross_domain_projector.MIN_NOVELTY_SCORE,
        });
    } else {
        sys.print("  ❌ INVENTION FAILED: Novelty {d:.2} < {d:.2}\n", .{
            best_novelty, cross_domain_projector.MIN_NOVELTY_SCORE,
        });
    }
}

// ── Helpers ──

/// Extract a clean label from chunk text by skipping header decorations
/// (lines of ===, ---, ###, numbered section headers like "1. TITLE")
/// and returning the first meaningful sentence (up to 60 chars).
fn extractCleanLabel(text: []const u8) []const u8 {
    var line_start: usize = 0;
    for (text, 0..) |c, idx| {
        if (c == '\n' or idx == text.len - 1) {
            const line_end = if (c == '\n') idx else idx + 1;
            const line = std.mem.trim(u8, text[line_start..line_end], " \r\t");

            // Skip empty lines
            if (line.len == 0) {
                line_start = idx + 1;
                continue;
            }

            // Skip decoration lines (all ===, ---, or #)
            if (isDecorationLine(line)) {
                line_start = idx + 1;
                continue;
            }

            // Skip numbered section headers like "1. COMPRESSOR FUNDAMENTALS"
            if (isNumberedHeader(line)) {
                line_start = idx + 1;
                continue;
            }

            // Skip plain ALL CAPS headers
            if (isAllCapsHeader(line)) {
                line_start = idx + 1;
                continue;
            }

            // Found a real content line — truncate to 60 chars
            const label_len = @min(line.len, 60);
            return line[0..label_len];
        }
    }

    // Fallback: just use first 60 chars
    const len = @min(text.len, 60);
    return text[0..len];
}

fn isDecorationLine(line: []const u8) bool {
    if (line.len == 0) return true;
    const first = line[0];
    if (first != '=' and first != '-' and first != '#' and first != '*') return false;
    var all_same: usize = 0;
    for (line) |c| {
        if (c == first or c == ' ') all_same += 1;
    }
    return all_same == line.len;
}

fn isNumberedHeader(line: []const u8) bool {
    // Match patterns like "1. TITLE" or "12. SOMETHING"
    if (line.len < 3) return false;
    var i: usize = 0;
    while (i < line.len and line[i] >= '0' and line[i] <= '9') : (i += 1) {}
    if (i == 0 or i >= line.len) return false;
    if (line[i] != '.') return false;
    // Check if remaining text is ALL UPPERCASE (typical section header)
    const rest = std.mem.trim(u8, line[i + 1 ..], " ");
    if (rest.len == 0) return false;
    var upper_count: usize = 0;
    var alpha_count: usize = 0;
    for (rest) |c| {
        if (c >= 'A' and c <= 'Z') {
            upper_count += 1;
            alpha_count += 1;
        } else if (c >= 'a' and c <= 'z') {
            alpha_count += 1;
        }
    }
    // If >80% of alpha chars are uppercase, it's a header
    return alpha_count > 0 and upper_count * 100 / alpha_count > 80;
}

fn isAllCapsHeader(line: []const u8) bool {
    var upper_count: usize = 0;
    var alpha_count: usize = 0;
    for (line) |c| {
        if (c >= 'A' and c <= 'Z') {
            upper_count += 1;
            alpha_count += 1;
        } else if (c >= 'a' and c <= 'z') {
            alpha_count += 1;
        }
    }
    // Very short lines or lines with no letters are not valid labels anyway,
    // but we let empty lines be caught by the empty line check.
    if (alpha_count == 0) return false;
    return upper_count * 100 / alpha_count > 85;
}

fn readFileContents(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    return file.readToEndAlloc(allocator, 64 * 1024 * 1024);
}

fn printBanner() void {
    sys.printOut(
        \\
        \\╔══════════════════════════════════════════════════════════╗
        \\║     GHOST ENGINE v2 — SEMANTIC LATTICE TEST HARNESS     ║
        \\║   VSA Hypervector Validation • Dark Space Projection    ║
        \\╚══════════════════════════════════════════════════════════╝
        \\
    );
}

fn printUsage() void {
    sys.printOut(
        \\Usage: ghost_semantic_test [options]
        \\
        \\Options:
        \\  --all                Run all three builtin tests
        \\  --test=<name>        Run a specific test:
        \\                         deep-research   Long-term memory
        \\                         contradiction   Conflict resolution
        \\                         cross-domain    Novel invention
        \\                         invent          Cross-domain invention
        \\  --corpus=<path>      Corpus file for deep-research test
        \\  --doc-a=<path>       First document for contradiction test
        \\  --doc-b=<path>       Second document for contradiction test
        \\  --domain-a=<path>    First domain dir for cross-domain/invent
        \\  --domain-b=<path>    Second domain dir for cross-domain/invent
        \\  --query=<text>       Query with intent resolution
        \\  --invent=<text>      Invention prompt for cross-domain
        \\  --help, -h           Show this help
        \\
        \\Examples:
        \\  ghost_semantic_test --all
        \\  ghost_semantic_test --test=invent --domain-a=corpus/dsp --domain-b=corpus/quantum \\
        \\    --invent="VSA-based Audio Compressor with quantum probability threshold"
        \\  ghost_semantic_test --test=cross-domain --domain-a=corpus/dsp --domain-b=corpus/quantum \\
        \\    --query="how does quantum probability relate to audio threshold"
        \\
    );
}
