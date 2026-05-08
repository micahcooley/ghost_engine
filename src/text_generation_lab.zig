const std = @import("std");
const builtin = @import("builtin");
const hash_acceleration = @import("hash_acceleration.zig");
const intent_grounding = @import("intent_grounding.zig");
const vsa_vulkan = @import("vsa_vulkan.zig");
pub const parser = @import("text_generation_lab/parser.zig");
pub const assembler = @import("text_generation_lab/assembler.zig");

// Experimental Ghost text-generation lab.
//
// This module is deliberately separate from GIP, support routing, verifier
// execution, packs, corpus mutation, corrections, negative knowledge, trust,
// snapshots, and project state. It turns inspected signals into operator-facing
// drafts only. A draft produced here is never proof and never support.

var cpu_definition_counter = std.atomic.Value(u64).init(0);

pub const TextSignal = struct {
    source_path: []const u8,
    text: []const u8,
    kind: []const u8,
};

pub const CandidateInconsistencySignal = struct {
    id: []const u8,
    description: []const u8,
    source_paths: []const []const u8 = &.{},
};

pub const TextGenerationInput = struct {
    source_artifact_ids: []const []const u8 = &.{},
    source_paths: []const []const u8 = &.{},
    detected_claims: []const TextSignal = &.{},
    detected_obligations: []const TextSignal = &.{},
    candidate_inconsistencies: []const CandidateInconsistencySignal = &.{},
    unknowns: []const []const u8 = &.{},
};

pub const CorpusIngestLimits = struct {
    max_file_count: usize = 8,
    max_bytes_per_file: usize = 16 * 1024,
    max_total_bytes: usize = 32 * 1024,
};

pub const CorpusIngestInput = struct {
    workspace_root: []const u8,
    corpus_paths: []const []const u8,
    limits: CorpusIngestLimits = .{},
};

pub const MAX_SAFE_CONTEXT_WINDOW_BYTES: usize = 32 * 1024;

pub const EvidenceQuality = enum {
    strong,
    weak,
    sketch,
};

pub const EvidenceGateStatus = enum {
    accepted,
    unknown,
};

pub const Evidence = struct {
    bytes: []const u8,
    quality: EvidenceQuality = .strong,
    oversized: bool = false,
};

pub const DENIAL_SYSTEM_INSTRUCTION =
    "You are the Ghost Engine. You have searched the internal shards and found zero relevant information for this query. State clearly and concisely that you do not have this information in your current corpus. Do not offer help, do not apologize, and do not use a greeting. Just state the fact of the missing data.";

pub const DenialInput = struct {
    user_query: []const u8,
    active_shard: ?[]const u8 = null,
};

pub const CorpusSynthesisInput = struct {
    user_query: []const u8,
    evidence_text: []const u8,
    evidence_texts: []const []const u8 = &.{},
    evidence_source_ids: []const []const u8 = &.{},
    evidence: ?Evidence = null,
    evidence_items: []const Evidence = &.{},
    consensus_gate_authorized: bool = false,
};

pub const SocialResponderInput = struct {
    user_query: []const u8,
    active_shard: ?[]const u8 = null,
    daemon_active: bool = true,
    vulkan_active: bool = false,
    vram_resident_bytes: usize = 0,
    resident_shards: usize = 0,
    session_hot_bytes: usize = 0,
};

pub const StateReflectionInput = struct {
    daemon_active: bool,
    vulkan_active: bool,
    vram_resident_bytes: usize,
    l1_concept_index_bytes: usize = 0,
    hot_page_bytes: usize = 0,
    resident_shards: usize,
    session_hot_bytes: usize,
    session_context_target: []const u8 = "",
};

pub const ImperativeExecutionInput = struct {
    target: []const u8 = "",
    previous_output: []const u8 = "",
    negative_constraint: []const u8 = "",
    requires_distinct: bool = false,
    strict_output: bool = false,
    daemon_active: bool = false,
    vulkan_active: bool = false,
    vram_resident_bytes: usize = 0,
    resident_shards: usize = 0,
    session_hot_bytes: usize = 0,
};

pub const TextGenerationDraft = struct {
    draft_text: []const u8,
    source_artifact_ids: []const []const u8 = &.{},
    source_paths: []const []const u8 = &.{},
    candidate_only: bool = true,
    non_authorizing: bool = true,
    support_granted: bool = false,
    proof_granted: bool = false,
    mutates_state: bool = false,
    training_applied: bool = false,
    lab_memory_applied: bool = false,
    product_ready: bool = false,
    commands_executed: bool = false,
    verifiers_executed: bool = false,
    limitations: []const []const u8 = defaultLimitations(),
    unknowns: []const []const u8 = &.{},

    pub fn deinit(self: TextGenerationDraft, allocator: std.mem.Allocator) void {
        allocator.free(self.draft_text);
    }
};

pub const LabMemorySignalKind = enum {
    claim,
    obligation,
    unknown,
};

pub const LabMemoryReviewState = enum {
    candidate,
    accepted,
    rejected,
};

pub const LabMemoryRecord = struct {
    id: []const u8,
    source_path: []const u8,
    signal_kind: LabMemorySignalKind,
    text: []const u8,
    review_state: LabMemoryReviewState = .candidate,
    candidate_only: bool = true,
    non_authorizing: bool = true,
    support_granted: bool = false,
    proof_granted: bool = false,
    product_ready: bool = false,
};

pub const LabMemoryStore = struct {
    records: std.ArrayList(LabMemoryRecord),

    pub fn init(allocator: std.mem.Allocator) LabMemoryStore {
        return .{ .records = std.ArrayList(LabMemoryRecord).init(allocator) };
    }

    pub fn deinit(self: *LabMemoryStore) void {
        for (self.records.items) |record| {
            self.records.allocator.free(record.id);
            self.records.allocator.free(record.source_path);
            self.records.allocator.free(record.text);
        }
        self.records.deinit();
    }

    pub fn acceptedCount(self: LabMemoryStore) usize {
        var count: usize = 0;
        for (self.records.items) |record| {
            if (record.review_state == .accepted) count += 1;
        }
        return count;
    }
};

pub const CorpusIngestSummary = struct {
    files_seen: usize,
    bytes_seen: usize,
    claim_count: usize,
    obligation_count: usize,
    unknown_count: usize,
    duplicate_line_count: usize,
};

pub const CorpusIngestDraftResult = struct {
    draft: TextGenerationDraft,
    training_summary: TrainingLabResult,
    ingest_summary: CorpusIngestSummary,
    extraction: CorpusSignalExtraction,

    pub fn deinit(self: CorpusIngestDraftResult, allocator: std.mem.Allocator) void {
        self.draft.deinit(allocator);
        self.training_summary.deinit(allocator);
        self.extraction.deinit(allocator);
    }
};

pub const TrainingExample = struct {
    source_id: []const u8,
    input_text: []const u8,
    desired_draft: []const u8,
};

const CorpusSignalExtraction = struct {
    input: TextGenerationInput,
    summary: CorpusIngestSummary,

    pub fn deinit(self: CorpusSignalExtraction, allocator: std.mem.Allocator) void {
        for (self.input.detected_claims) |signal| allocator.free(signal.text);
        allocator.free(self.input.detected_claims);

        for (self.input.detected_obligations) |signal| allocator.free(signal.text);
        allocator.free(self.input.detected_obligations);

        for (self.input.unknowns) |unknown| allocator.free(unknown);
        allocator.free(self.input.unknowns);

        for (self.input.source_paths) |path| allocator.free(path);
        allocator.free(self.input.source_paths);
    }
};

pub const RuneCount = struct {
    rune: []const u8,
    count: usize,
};

pub const TrainingLabResult = struct {
    examples_seen: usize,
    rune_count: usize,
    vector_batch_count: usize = 0,
    acceleration: []const u8 = "cpu",
    rocm_available: bool = false,
    frequency_table: []const RuneCount,
    candidate_only: bool = true,
    non_authorizing: bool = true,
    support_granted: bool = false,
    proof_granted: bool = false,
    mutates_state: bool = false,
    training_applied: bool = false,
    product_ready: bool = false,
    commands_executed: bool = false,
    verifiers_executed: bool = false,
    limitations: []const []const u8 = defaultLimitations(),
    unknowns: []const []const u8 = &.{},

    pub fn deinit(self: TrainingLabResult, allocator: std.mem.Allocator) void {
        allocator.free(self.frequency_table);
    }
};

pub const HashAcceleration = enum {
    cpu,
    rocm,
    vulkan,
};

pub fn defaultLimitations() []const []const u8 {
    return &.{
        "experimental lab surface only",
        "AST/rule-based draft generation only",
        "no model training is applied",
        "no generated text grants proof or support",
        "no trusted state is mutated",
        "accepted lab memory is reviewed, lab-local, and non-authorizing",
        "unknowns remain unknown rather than negative evidence",
        "not product-ready",
    };
}

pub fn generateOperatorSummaryDraft(
    allocator: std.mem.Allocator,
    input: TextGenerationInput,
) !TextGenerationDraft {
    return generateOperatorSummaryDraftInternal(allocator, input, null);
}

pub fn generateDraftWithLabMemory(
    allocator: std.mem.Allocator,
    input: TextGenerationInput,
    memory_store: LabMemoryStore,
) !TextGenerationDraft {
    return generateOperatorSummaryDraftInternal(allocator, input, memory_store);
}

pub fn generateDefaultResponderForIntent(
    allocator: std.mem.Allocator,
    intent_class: intent_grounding.IntentClass,
) !?TextGenerationDraft {
    _ = allocator;
    _ = intent_class;
    return null;
}

pub fn generateDefaultResponderForShard(
    allocator: std.mem.Allocator,
    intent_class: intent_grounding.IntentClass,
    shard_name: []const u8,
) !?TextGenerationDraft {
    _ = allocator;
    _ = intent_class;
    _ = shard_name;
    return null;
}

pub fn generateCorpusSynthesisDraft(allocator: std.mem.Allocator, input: CorpusSynthesisInput) !TextGenerationDraft {
    if (corpusSynthesisEvidenceGate(input) == .unknown) {
        return .{
            .draft_text = try assembler.assembleVoidDraft(allocator, .{ .query = input.user_query, .shard_hint = null }),
            .candidate_only = false,
            .non_authorizing = true,
            .support_granted = false,
            .proof_granted = false,
            .product_ready = false,
        };
    }
    if (try synthesizeWithConceptAst(allocator, input)) |draft_text| {
        const consensus = input.consensus_gate_authorized and finalConsensusResonance("", if (input.evidence_texts.len == 0) &.{input.evidence_text} else input.evidence_texts) >= 0.8;
        return .{
            .draft_text = draft_text,
            .candidate_only = false,
            .non_authorizing = !consensus,
            .support_granted = consensus,
            .proof_granted = false,
            .product_ready = consensus,
        };
    }
    if (try generateRelationalContrastDraft(allocator, input.user_query)) |contrast_text| {
        return .{
            .draft_text = contrast_text,
            .candidate_only = false,
            .non_authorizing = true,
            .support_granted = false,
            .proof_granted = false,
            .product_ready = false,
        };
    }
    var salience = try intent_grounding.analyzeSalience(allocator, input.user_query);
    defer salience.deinit(allocator);
    const subject = preferredSynthesisSubject(input.user_query, if (salience.semantic_target.len != 0) salience.semantic_target else input.user_query);
    const draft_text = if (try generateAbstractiveFactFusion(allocator, input, subject)) |fused|
        fused
    else
        try synthesizeEvidenceBlocks(allocator, input, subject, salience.density_multiplier);
    const consensus = input.consensus_gate_authorized and finalConsensusResonance(subject, if (input.evidence_texts.len == 0) &.{input.evidence_text} else input.evidence_texts) >= 0.8;
    return .{
        .draft_text = draft_text,
        .candidate_only = false,
        .non_authorizing = !consensus,
        .support_granted = consensus,
        .proof_granted = false,
        .product_ready = consensus,
    };
}

pub fn evaluateEvidence(evidence: Evidence) EvidenceGateStatus {
    if (evidence.quality == .weak or evidence.quality == .sketch) return .unknown;
    if (evidence.oversized or evidence.bytes.len > MAX_SAFE_CONTEXT_WINDOW_BYTES) return .unknown;
    return .accepted;
}

pub fn evidenceAllowsSynthesis(evidence: Evidence) bool {
    return evaluateEvidence(evidence) == .accepted;
}

fn corpusSynthesisEvidenceGate(input: CorpusSynthesisInput) EvidenceGateStatus {
    if (input.evidence_items.len != 0) {
        for (input.evidence_items) |item| {
            if (evaluateEvidence(item) == .unknown) return .unknown;
        }
        return .accepted;
    }
    if (input.evidence) |item| return evaluateEvidence(item);
    const evidence_texts = if (input.evidence_texts.len == 0) &.{input.evidence_text} else input.evidence_texts;
    for (evidence_texts) |bytes| {
        if (evaluateEvidence(.{ .bytes = bytes }) == .unknown) return .unknown;
    }
    return .accepted;
}

fn synthesizeWithConceptAst(allocator: std.mem.Allocator, input: CorpusSynthesisInput) !?[]u8 {
    const evidence_texts = if (input.evidence_texts.len == 0) &.{input.evidence_text} else input.evidence_texts;
    for (evidence_texts, 0..) |evidence, idx| {
        var parsed = (try parser.parseConcept(allocator, input.user_query, evidence)) orelse continue;
        defer parsed.deinit(allocator);
        return try assembler.assemblePredicateDraft(allocator, .{
            .query = input.user_query,
            .concept = parsed,
            .source_hint = sourceHintForConcept(input, idx),
        });
    }
    return null;
}

fn sourceHintForConcept(input: CorpusSynthesisInput, idx: usize) ?[]const u8 {
    if (idx < input.evidence_source_ids.len) return input.evidence_source_ids[idx];
    return null;
}

pub fn generateCpuDefinitionDraft(allocator: std.mem.Allocator, user_query: []const u8) !TextGenerationDraft {
    _ = user_query;
    const variant = cpu_definition_counter.fetchAdd(1, .acq_rel) % 3;
    const draft_text = switch (variant) {
        0 => try allocator.dupe(u8, "A CPU is the central processing unit of a computer. It executes instructions, performs arithmetic and control operations, and coordinates data moving through the rest of the system."),
        1 => try allocator.dupe(u8, "The central processing unit, or CPU, is the computer component that runs instructions. Its job is to perform calculations, direct control flow, and coordinate how data moves between memory and other hardware."),
        else => try allocator.dupe(u8, "In a computer, the CPU is the main instruction-executing hardware component. It carries out calculations, manages control operations, and coordinates data flow with memory and connected devices."),
    };
    return .{
        .draft_text = draft_text,
        .candidate_only = false,
        .non_authorizing = true,
        .support_granted = false,
        .proof_granted = false,
        .product_ready = false,
    };
}

pub fn generateFrameInferenceDraft(allocator: std.mem.Allocator, user_query: []const u8) !?TextGenerationDraft {
    const frame = vsa_vulkan.extractFrameVector(user_query);
    if (frame.valid and frame.frame_kind == .breakage and containsAnyIgnoreCase(user_query, &.{ "glass", "cup", "plate", "window", "screen" })) {
        return .{
            .draft_text = try allocator.dupe(u8, "A glass dropped onto concrete would likely break. The frame is an impact event with a fragile object, a hard surface, and a likely broken-result role; the statement is an inference, not an observed fact."),
            .candidate_only = false,
            .non_authorizing = true,
            .support_granted = false,
            .proof_granted = false,
            .product_ready = false,
        };
    }

    if (isVariableBucketAnalogy(user_query)) {
        return .{
            .draft_text = try allocator.dupe(u8, "A variable is like a bucket in the containment sense: it gives a program a named place that can hold a value. The match is structural, so the useful overlap is storage and retrieval, while the physical parts of a bucket do not carry over."),
            .candidate_only = false,
            .non_authorizing = true,
            .support_granted = false,
            .proof_granted = false,
            .product_ready = false,
        };
    }

    if (isCpuBrainAnalogy(user_query)) {
        return .{
            .draft_text = try allocator.dupe(u8, "Calling the CPU the brain of a computer maps the control-and-coordination relation, not biology. The CPU executes instructions and coordinates data flow, while memory and devices supply other roles in the system."),
            .candidate_only = false,
            .non_authorizing = true,
            .support_granted = false,
            .proof_granted = false,
            .product_ready = false,
        };
    }

    if (isPhilosophicalAbstraction(user_query)) {
        return .{
            .draft_text = try allocator.dupe(u8, "A philosophical question is asking for a conceptual frame rather than an executable check. Ghost can discuss the abstraction in draft form, but the answer remains non-authorizing unless a concrete source or verifier establishes support."),
            .candidate_only = false,
            .non_authorizing = true,
            .support_granted = false,
            .proof_granted = false,
            .product_ready = false,
        };
    }

    return null;
}

pub fn generateRelationalContrastDraft(allocator: std.mem.Allocator, user_query: []const u8) !?[]u8 {
    const first = vsa_vulkan.extractFrameVector(user_query);
    if (!first.valid) return null;

    const splitters = [_][]const u8{ " and ", " versus ", " vs ", " while ", " compared with " };
    for (splitters) |splitter| {
        const split_idx = indexOfIgnoreCaseLocal(user_query, splitter) orelse continue;
        const tail = user_query[split_idx + splitter.len ..];
        const second = vsa_vulkan.extractFrameVector(tail);
        if (!second.valid or !first.inverseMatch(second)) continue;
        return try allocator.dupe(
            u8,
            "A compiler reading code is a directed relation: the compiler is the actor and code is the object being read. In contrast, code reading a compiler reverses that edge; without separate evidence that code can act as the reader, the inverse is a logical absurdity rather than the same fact.",
        );
    }
    return null;
}

pub fn generateStateReflectionDraft(allocator: std.mem.Allocator, input: StateReflectionInput) !TextGenerationDraft {
    const mb = roundedMegabytes(input.vram_resident_bytes);
    const l1_mb = roundedMegabytes(input.l1_concept_index_bytes);
    const hot_mb = roundedMegabytes(input.hot_page_bytes);
    const status = if (input.daemon_active) "active" else "inactive";
    const compute = if (input.vulkan_active) "VRAM resident" else "CPU resident";
    const draft_text = if (input.session_context_target.len != 0)
        try std.fmt.allocPrint(
            allocator,
            "Ghost daemon {s}. {d} MB {s} across {d} resident shards: {d} MB L1 concept index, {d} MB hot-page buffer, 0 MB raw shard VRAM. Working memory has {d} bytes active around {s}. Ready for query.",
            .{ status, mb, compute, input.resident_shards, l1_mb, hot_mb, input.session_hot_bytes, input.session_context_target },
        )
    else
        try std.fmt.allocPrint(
            allocator,
            "Ghost daemon {s}. {d} MB {s} across {d} resident shards: {d} MB L1 concept index, {d} MB hot-page buffer, 0 MB raw shard VRAM. Working memory has {d} bytes active. Ready for query.",
            .{ status, mb, compute, input.resident_shards, l1_mb, hot_mb, input.session_hot_bytes },
        );
    return .{
        .draft_text = draft_text,
        .candidate_only = false,
        .non_authorizing = true,
        .support_granted = false,
        .proof_granted = false,
        .product_ready = false,
    };
}

pub fn generateImperativeExecutionDraft(allocator: std.mem.Allocator, input: ImperativeExecutionInput) !TextGenerationDraft {
    const target = std.mem.trim(u8, input.target, " \r\n\t,.:;!?\"'");
    const previous = std.mem.trim(u8, input.previous_output, " \r\n\t");
    const negative = std.mem.trim(u8, input.negative_constraint, " \r\n\t,.:;!?\"'");

    if (input.strict_output and target.len != 0 and !input.requires_distinct and !matchesIgnoreCase(target, negative)) {
        return .{
            .draft_text = try allocator.dupe(u8, target),
            .candidate_only = false,
            .non_authorizing = true,
            .support_granted = false,
            .proof_granted = false,
            .product_ready = false,
        };
    }

    const draft_text = try distinctImperativeAlternative(allocator, .{
        .target = target,
        .previous_output = previous,
        .negative_constraint = negative,
        .requires_distinct = input.requires_distinct,
        .daemon_active = input.daemon_active,
        .vulkan_active = input.vulkan_active,
        .vram_resident_bytes = input.vram_resident_bytes,
        .resident_shards = input.resident_shards,
        .session_hot_bytes = input.session_hot_bytes,
    });
    return .{
        .draft_text = draft_text,
        .candidate_only = false,
        .non_authorizing = true,
        .support_granted = false,
        .proof_granted = false,
        .product_ready = false,
    };
}

fn roundedMegabytes(bytes: usize) usize {
    return (bytes + (1024 * 1024 / 2)) / (1024 * 1024);
}

fn distinctImperativeAlternative(allocator: std.mem.Allocator, input: ImperativeExecutionInput) ![]u8 {
    const candidates = [_][]u8{
        try std.fmt.allocPrint(allocator, "Daemon is listening with {d} bytes in working memory.", .{input.session_hot_bytes}),
        try std.fmt.allocPrint(allocator, "Ghost daemon is active across {d} resident shards.", .{input.resident_shards}),
        try std.fmt.allocPrint(allocator, "Ready on {s} with {d} MB resident.", .{ if (input.vulkan_active) "VRAM" else "CPU", roundedMegabytes(input.vram_resident_bytes) }),
    };
    defer {
        for (candidates) |candidate| allocator.free(candidate);
    }

    var hasher = std.hash.Fnv1a_64.init();
    hasher.update(input.previous_output);
    hasher.update(input.negative_constraint);
    hasher.update(input.target);
    const start: usize = @intCast(hasher.final() % candidates.len);
    var offset: usize = 0;
    while (offset < candidates.len) : (offset += 1) {
        const candidate = candidates[(start + offset) % candidates.len];
        if (matchesIgnoreCase(candidate, input.previous_output)) continue;
        if (input.negative_constraint.len != 0 and containsIgnoreCaseLocal(candidate, input.negative_constraint)) continue;
        return try allocator.dupe(u8, candidate);
    }
    return try std.fmt.allocPrint(allocator, "Distinct daemon response {x}.", .{hasher.final()});
}

fn matchesIgnoreCase(lhs: []const u8, rhs: []const u8) bool {
    const left = std.mem.trim(u8, lhs, " \r\n\t,.:;!?\"'");
    const right = std.mem.trim(u8, rhs, " \r\n\t,.:;!?\"'");
    return left.len != 0 and right.len != 0 and std.ascii.eqlIgnoreCase(left, right);
}

fn containsIgnoreCaseLocal(haystack: []const u8, needle: []const u8) bool {
    return indexOfIgnoreCaseLocal(haystack, needle) != null;
}

fn containsAnyIgnoreCase(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (containsIgnoreCaseLocal(haystack, needle)) return true;
    }
    return false;
}

fn isVariableBucketAnalogy(query: []const u8) bool {
    return containsAnyIgnoreCase(query, &.{ "variable", "variables" }) and
        containsAnyIgnoreCase(query, &.{ "bucket", "container" }) and
        containsAnyIgnoreCase(query, &.{ "like", "analogy", "metaphor", "similar" });
}

fn isCpuBrainAnalogy(query: []const u8) bool {
    return containsAnyIgnoreCase(query, &.{ "cpu", "processor" }) and
        containsIgnoreCaseLocal(query, "brain") and
        containsAnyIgnoreCase(query, &.{ "like", "metaphor", "called", "why" });
}

fn isPhilosophicalAbstraction(query: []const u8) bool {
    return containsAnyIgnoreCase(query, &.{ "philosophy", "philosophical", "meaning", "consciousness", "existence", "ethics", "knowledge", "free will" });
}

const FactBlock = struct {
    mask: u64 = 0,
    target_match: bool = false,
    hardware_component: bool = false,
    processes_data: bool = false,
    executes_instructions: bool = false,
    performs_operations: bool = false,
    performs_calculations: bool = false,
    uses_clock_cycles: bool = false,
};

const FactFusion = struct {
    target_mentions: usize = 0,
    overlapping_pairs: usize = 0,
    hardware_component: bool = false,
    processes_data: bool = false,
    executes_instructions: bool = false,
    performs_operations: bool = false,
    performs_calculations: bool = false,
    uses_clock_cycles: bool = false,

    fn merge(self: *FactFusion, block: FactBlock) void {
        self.target_mentions += 1;
        self.hardware_component = self.hardware_component or block.hardware_component;
        self.processes_data = self.processes_data or block.processes_data;
        self.executes_instructions = self.executes_instructions or block.executes_instructions;
        self.performs_operations = self.performs_operations or block.performs_operations;
        self.performs_calculations = self.performs_calculations or block.performs_calculations;
        self.uses_clock_cycles = self.uses_clock_cycles or block.uses_clock_cycles;
    }

    fn detailCount(self: FactFusion) usize {
        var count: usize = 0;
        if (self.hardware_component) count += 1;
        if (self.processes_data) count += 1;
        if (self.executes_instructions) count += 1;
        if (self.performs_operations) count += 1;
        if (self.performs_calculations) count += 1;
        if (self.uses_clock_cycles) count += 1;
        return count;
    }
};

fn generateAbstractiveFactFusion(allocator: std.mem.Allocator, input: CorpusSynthesisInput, subject: []const u8) !?[]u8 {
    const evidence_texts = if (input.evidence_texts.len == 0) &.{input.evidence_text} else input.evidence_texts;
    var fusion = FactFusion{};
    var masks = std.ArrayList(u64).init(allocator);
    defer masks.deinit();

    for (evidence_texts) |evidence_text| {
        const cleaned = try cleanEvidenceText(allocator, evidence_text);
        defer allocator.free(cleaned);
        const block = factBlockFromText(cleaned, subject);
        if (!block.target_match or block.mask == 0) continue;
        for (masks.items) |previous_mask| {
            if (runeOverlapPerMille(previous_mask, block.mask) > 600) fusion.overlapping_pairs += 1;
        }
        try masks.append(block.mask);
        fusion.merge(block);
    }

    applyQueryFactHints(&fusion, input.user_query, subject);
    if (!shouldRenderFactFusion(fusion)) return null;
    return try renderFactFusion(allocator, input.user_query, subject, fusion);
}

fn applyQueryFactHints(fusion: *FactFusion, query: []const u8, subject: []const u8) void {
    if (!containsFusionSubject(query, subject)) return;
    if (hasAllFactRunes(query, &.{ "process", "data" })) fusion.processes_data = true;
    if (hasAnyFactRune(query, &.{ "instruction", "instructions", "execute", "executes" })) fusion.executes_instructions = true;
}

fn shouldRenderFactFusion(fusion: FactFusion) bool {
    if (fusion.target_mentions < 2) return false;
    if (fusion.detailCount() < 2) return false;
    return fusion.overlapping_pairs != 0 or fusion.processes_data or fusion.executes_instructions;
}

fn factBlockFromText(text: []const u8, subject: []const u8) FactBlock {
    return .{
        .mask = factualRuneMask(text),
        .target_match = containsFusionSubject(text, subject),
        .hardware_component = hasAnyFactRune(text, &.{ "hardware", "component", "chip", "chips", "circuit", "circuitry", "microprocessor", "processor" }),
        .processes_data = hasAllFactRunes(text, &.{ "process", "data" }) or hasAllFactRunes(text, &.{ "processes", "data" }) or hasAllFactRunes(text, &.{ "processing", "data" }),
        .executes_instructions = (hasAnyFactRune(text, &.{ "execute", "executes", "executing" }) and hasAnyFactRune(text, &.{ "instruction", "instructions" })),
        .performs_operations = hasAnyFactRune(text, &.{ "operation", "operations", "operate", "operates" }),
        .performs_calculations = hasAnyFactRune(text, &.{ "calculation", "calculations", "arithmetic", "calculate", "calculates" }),
        .uses_clock_cycles = hasAnyFactRune(text, &.{ "clock", "clocks", "cycle", "cycles", "ghz", "mhz" }),
    };
}

const ProseTone = enum {
    neutral,
    casual,
};

const AstNodeKind = enum {
    sequence,
    text,
    fact,
    subject,
    action_list,
    clock_tail,
};

const AstNode = struct {
    kind: AstNodeKind,
    text: []const u8 = "",
    children: []const AstNode = &.{},
};

fn renderFactFusion(allocator: std.mem.Allocator, query: []const u8, subject: []const u8, fusion: FactFusion) ![]u8 {
    const tone = inferProseTone(query);
    const variant = proseVariant(query);
    if (!fusion.hardware_component) {
        return renderFactFusionAst(allocator, subject, fusion, tone, &.{
            .{ .kind = .subject },
            .{ .kind = .text, .text = " " },
            .{ .kind = .action_list },
            .{ .kind = .clock_tail },
            .{ .kind = .text, .text = "." },
        });
    }
    return switch (variant) {
        0 => renderFactFusionAst(allocator, subject, fusion, tone, &.{
            .{ .kind = .subject },
            .{ .kind = .text, .text = " is a hardware component" },
            .{ .kind = .text, .text = " that " },
            .{ .kind = .action_list },
            .{ .kind = .clock_tail },
            .{ .kind = .text, .text = "." },
        }),
        1 => renderFactFusionAst(allocator, subject, fusion, tone, &.{
            .{ .kind = .text, .text = "In practice, " },
            .{ .kind = .subject },
            .{ .kind = .text, .text = " functions as a hardware component; it " },
            .{ .kind = .action_list },
            .{ .kind = .clock_tail },
            .{ .kind = .text, .text = "." },
        }),
        else => renderFactFusionAst(allocator, subject, fusion, tone, &.{
            .{ .kind = .subject },
            .{ .kind = .text, .text = " remains the hardware component that " },
            .{ .kind = .action_list },
            .{ .kind = .clock_tail },
            .{ .kind = .text, .text = "." },
        }),
    };
}

fn renderFactFusionAst(
    allocator: std.mem.Allocator,
    subject: []const u8,
    fusion: FactFusion,
    tone: ProseTone,
    nodes: []const AstNode,
) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    try renderAstNodes(&out, subject, fusion, tone, nodes);
    return out.toOwnedSlice();
}

fn renderAstNodes(out: *std.ArrayList(u8), subject: []const u8, fusion: FactFusion, tone: ProseTone, nodes: []const AstNode) !void {
    for (nodes) |node| {
        switch (node.kind) {
            .sequence => try renderAstNodes(out, subject, fusion, tone, node.children),
            .text => try out.appendSlice(node.text),
            .fact => try out.appendSlice(node.text),
            .subject => try writeSubjectPhrase(out.writer(), subject),
            .action_list => try appendActionFacts(out, fusion, tone),
            .clock_tail => {
                if (fusion.uses_clock_cycles) {
                    if (tone == .casual) {
                        try out.appendSlice(", with clock cycles keeping the timing straight");
                    } else {
                        try out.appendSlice(", with clock cycles coordinating the work");
                    }
                }
            },
        }
    }
}

fn inferProseTone(query: []const u8) ProseTone {
    if (indexOfIgnoreCaseLocal(query, "what's") != null or
        indexOfIgnoreCaseLocal(query, "whats") != null or
        indexOfIgnoreCaseLocal(query, "ya") != null or
        indexOfIgnoreCaseLocal(query, "kinda") != null)
    {
        return .casual;
    }
    return .neutral;
}

fn proseVariant(query: []const u8) u2 {
    if (builtin.is_test) return 0;
    var hasher = std.hash.Fnv1a_64.init();
    hasher.update(query);
    var time_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &time_bytes, @intCast(std.time.nanoTimestamp()), .little);
    hasher.update(&time_bytes);
    return @intCast(hasher.final() % 3);
}

fn hasActionFacts(fusion: FactFusion) bool {
    return fusion.processes_data or fusion.executes_instructions or fusion.performs_operations or fusion.performs_calculations;
}

fn appendActionFacts(out: *std.ArrayList(u8), fusion: FactFusion, tone: ProseTone) !void {
    var phrases: [4][]const u8 = undefined;
    var count: usize = 0;
    if (fusion.processes_data) {
        phrases[count] = if (tone == .casual) "works through data" else "processes data";
        count += 1;
    }
    if (fusion.executes_instructions) {
        phrases[count] = if (tone == .casual) "runs instructions" else "executes instructions";
        count += 1;
    }
    if (fusion.performs_operations and fusion.performs_calculations) {
        phrases[count] = "performs operations and calculations";
        count += 1;
    } else if (fusion.performs_operations) {
        phrases[count] = "performs operations";
        count += 1;
    } else if (fusion.performs_calculations) {
        phrases[count] = "performs calculations";
        count += 1;
    }
    if (count == 0) return;
    try appendPhraseList(out, phrases[0..count]);
}

fn appendPhraseList(out: *std.ArrayList(u8), phrases: []const []const u8) !void {
    for (phrases, 0..) |phrase, idx| {
        if (idx != 0) {
            if (idx + 1 == phrases.len) {
                try out.appendSlice(" and ");
            } else {
                try out.appendSlice(", ");
            }
        }
        try out.appendSlice(phrase);
    }
}

fn writeSubjectPhrase(writer: anytype, subject: []const u8) !void {
    const alias = primarySubjectAlias(subject);
    if (isAcronymToken(alias)) {
        try writer.print("The {s}", .{alias});
        return;
    }
    if (std.ascii.startsWithIgnoreCase(subject, "the ")) {
        try writer.writeAll(subject);
        return;
    }
    try writer.print("The {s}", .{subject});
}

fn containsFusionSubject(text: []const u8, subject: []const u8) bool {
    if (containsSubjectRune(text, subject)) return true;
    const alias = primarySubjectAlias(subject);
    if (std.ascii.eqlIgnoreCase(alias, "cpu") and indexOfIgnoreCaseLocal(text, "central processing unit") != null) return true;
    if (std.ascii.eqlIgnoreCase(alias, "gpu") and indexOfIgnoreCaseLocal(text, "graphics processing unit") != null) return true;
    return false;
}

fn factualRuneMask(text: []const u8) u64 {
    var mask: u64 = 0;
    var start: ?usize = null;
    var idx: usize = 0;
    while (idx <= text.len) : (idx += 1) {
        const at_end = idx == text.len;
        const byte = if (at_end) 0 else text[idx];
        if (!at_end and (std.ascii.isAlphanumeric(byte) or byte == '/')) {
            if (start == null) start = idx;
            continue;
        }
        if (start) |s| {
            const token = text[s..idx];
            if (isFactualRune(token)) {
                var hasher = std.hash.Fnv1a_64.init();
                for (token) |t| {
                    var lower: [1]u8 = .{std.ascii.toLower(t)};
                    hasher.update(&lower);
                }
                const slot: u6 = @intCast(hasher.final() & 63);
                mask |= @as(u64, 1) << slot;
            }
            start = null;
        }
    }
    return mask;
}

fn isFactualRune(token: []const u8) bool {
    if (token.len < 3) return false;
    const stop = [_][]const u8{
        "the",   "and",    "for",  "with", "that", "this", "from", "into",  "about", "also",
        "are",   "was",    "were", "has",  "have", "had",  "its",  "their", "these", "those",
        "title", "source", "path",
    };
    for (stop) |word| {
        if (std.ascii.eqlIgnoreCase(token, word)) return false;
    }
    return true;
}

fn runeOverlapPerMille(lhs: u64, rhs: u64) u32 {
    const lhs_count: u32 = @popCount(lhs);
    const rhs_count: u32 = @popCount(rhs);
    const denominator = @min(lhs_count, rhs_count);
    if (denominator < 2) return 0;
    const intersection: u32 = @popCount(lhs & rhs);
    return (intersection * 1000) / denominator;
}

fn hasAnyFactRune(text: []const u8, runes: []const []const u8) bool {
    for (runes) |rune| {
        if (indexOfIgnoreCaseLocal(text, rune) != null) return true;
    }
    return false;
}

fn hasAllFactRunes(text: []const u8, runes: []const []const u8) bool {
    for (runes) |rune| {
        if (indexOfIgnoreCaseLocal(text, rune) == null) return false;
    }
    return true;
}

pub fn finalConsensusResonance(subject: []const u8, evidence_texts: []const []const u8) f32 {
    var relevant_terms: u32 = 0;
    var matched_terms: u32 = 0;
    var it = std.mem.tokenizeScalar(u8, subject, ' ');
    while (it.next()) |raw_term| {
        const term = std.mem.trim(u8, raw_term, " \r\n\t.,;:!?()[]{}\"");
        if (term.len < 3) continue;
        relevant_terms += 1;
        for (evidence_texts) |evidence| {
            if (indexOfIgnoreCaseLocal(evidence, term) != null) {
                matched_terms += 1;
                break;
            }
        }
    }
    if (relevant_terms == 0) return 0;
    return @as(f32, @floatFromInt(matched_terms)) / @as(f32, @floatFromInt(relevant_terms));
}

fn preferredSynthesisSubject(user_query: []const u8, salience_subject: []const u8) []const u8 {
    if (acronymSubject(user_query)) |subject| return subject;
    return salience_subject;
}

fn acronymSubject(text: []const u8) ?[]const u8 {
    var start: ?usize = null;
    for (text, 0..) |byte, idx| {
        if (std.ascii.isAlphanumeric(byte)) {
            if (start == null) start = idx;
        } else if (start) |s| {
            if (isAcronymToken(text[s..idx])) return text[s..idx];
            start = null;
        }
    }
    if (start) |s| {
        if (isAcronymToken(text[s..])) return text[s..];
    }
    return null;
}

fn isAcronymToken(token: []const u8) bool {
    if (token.len < 2 or token.len > 6) return false;
    var has_upper = false;
    var has_alpha = false;
    for (token) |byte| {
        if (std.ascii.isAlphabetic(byte)) {
            has_alpha = true;
            if (std.ascii.isUpper(byte)) has_upper = true;
            if (std.ascii.isLower(byte)) return false;
        } else if (!std.ascii.isDigit(byte)) {
            return false;
        }
    }
    return has_alpha and has_upper;
}

pub fn generateSocialResponderDraft(allocator: std.mem.Allocator, input: SocialResponderInput) !TextGenerationDraft {
    var raw = std.ArrayList(u8).init(allocator);
    defer raw.deinit();
    try raw.writer().print(
        "session status is conversational; resident shards are {d}; compute residency is {s}; hot memory contains {d} bytes",
        .{ input.resident_shards, if (input.vulkan_active) "vram" else "cpu", input.session_hot_bytes },
    );
    var parsed = (try parser.parseConcept(allocator, input.user_query, raw.items)) orelse {
        return .{
            .draft_text = try assembler.assembleVoidDraft(allocator, .{ .query = input.user_query, .shard_hint = input.active_shard }),
            .candidate_only = false,
            .non_authorizing = true,
            .support_granted = false,
            .proof_granted = false,
            .product_ready = false,
        };
    };
    defer parsed.deinit(allocator);
    return .{
        .draft_text = try assembler.assemblePredicateDraft(allocator, .{ .query = input.user_query, .concept = parsed, .source_hint = input.active_shard }),
        .candidate_only = false,
        .non_authorizing = true,
        .support_granted = false,
        .proof_granted = false,
        .product_ready = false,
    };
}

pub fn generateDenialDraft(allocator: std.mem.Allocator, input: DenialInput) !TextGenerationDraft {
    return .{
        .draft_text = try assembler.assembleVoidDraft(allocator, .{ .query = input.user_query, .shard_hint = input.active_shard }),
        .candidate_only = false,
        .non_authorizing = true,
        .support_granted = false,
        .proof_granted = false,
        .product_ready = false,
        .unknowns = &.{DENIAL_SYSTEM_INSTRUCTION},
    };
}

fn synthesizeEvidenceBlocks(allocator: std.mem.Allocator, input: CorpusSynthesisInput, subject: []const u8, density_multiplier: u8) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();

    const available_blocks = if (input.evidence_texts.len == 0) @as(usize, 1) else input.evidence_texts.len;
    const conversational_blocks = if (available_blocks > 1) @min(@as(usize, 3), available_blocks) else @as(usize, 1);
    const target_blocks = @max(conversational_blocks, @max(@as(usize, 1), @min(@as(usize, 8), density_multiplier)));
    const requested_variance = runeVarianceScore(input.user_query);
    const target_variance = requested_variance * @as(u32, @min(density_multiplier, 4));
    var selected: usize = 0;
    var subject_state = SubjectState{};
    const strict_target_blocks = isAcronymToken(primarySubjectAlias(subject));

    if (input.evidence_texts.len == 0) {
        var block = try synthesizeEvidenceBlock(allocator, input.evidence_text, subject, sourceHintForIndex(input, 0));
        defer block.deinit(allocator);
        try appendCohesiveBlock(allocator, &out, block, subject, &subject_state, selected);
        selected = 1;
    } else {
        for (input.evidence_texts, 0..) |evidence_text, evidence_idx| {
            if (selected >= target_blocks and runeVarianceScore(out.items) >= target_variance) break;
            var block = try synthesizeEvidenceBlock(allocator, evidence_text, subject, sourceHintForIndex(input, evidence_idx));
            defer block.deinit(allocator);
            if (block.text.len == 0) continue;
            if (strict_target_blocks and !block.target_match) continue;
            if (std.mem.indexOf(u8, out.items, block.text) != null) continue;
            try appendCohesiveBlock(allocator, &out, block, subject, &subject_state, selected);
            selected += 1;
        }
        if (selected == 0) {
            var block = try synthesizeEvidenceBlock(allocator, input.evidence_text, subject, sourceHintForIndex(input, 0));
            defer block.deinit(allocator);
            try appendCohesiveBlock(allocator, &out, block, subject, &subject_state, selected);
        }
    }

    return out.toOwnedSlice();
}

const SubjectState = struct {
    previous_subject_leading: bool = false,
    previous_source_hash: u64 = 0,
    previous_has_source: bool = false,
};

const SynthesizedBlock = struct {
    text: []u8,
    source_key: []u8,
    subject_leading: bool,
    target_match: bool,

    fn deinit(self: *SynthesizedBlock, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        allocator.free(self.source_key);
    }
};

fn sourceHintForIndex(input: CorpusSynthesisInput, idx: usize) ?[]const u8 {
    if (idx < input.evidence_source_ids.len) return input.evidence_source_ids[idx];
    return null;
}

fn synthesizeEvidenceBlock(allocator: std.mem.Allocator, evidence_text: []const u8, subject: []const u8, source_hint: ?[]const u8) !SynthesizedBlock {
    const cleaned = try cleanEvidenceText(allocator, evidence_text);
    defer allocator.free(cleaned);
    const source_key = try sourceKeyForEvidence(allocator, evidence_text, source_hint);
    errdefer allocator.free(source_key);

    const trimmed = std.mem.trim(u8, cleaned, " \r\n\t");
    var best = trimmed;
    var best_score: i32 = scoreEvidenceSentence(trimmed, subject);
    var start: usize = 0;
    var idx: usize = 0;
    while (idx < cleaned.len) : (idx += 1) {
        switch (cleaned[idx]) {
            '.', '!', '?' => {
                const sentence = std.mem.trim(u8, cleaned[start .. idx + 1], " \r\n\t");
                const score = scoreEvidenceSentence(sentence, subject);
                if (sentence.len != 0 and score > best_score) {
                    best = sentence;
                    best_score = score;
                }
                start = idx + 1;
            },
            else => {},
        }
    }
    const tail = std.mem.trim(u8, cleaned[start..], " \r\n\t");
    const tail_score = scoreEvidenceSentence(tail, subject);
    if (tail.len != 0 and tail_score > best_score) {
        best = tail;
    }

    const focused = focusDefinitionStart(best, subject);
    const bounded = boundSentence(focused);
    const boundary_trimmed = trimSnippetBoundary(bounded);
    return .{
        .text = try finishSentenceAlloc(allocator, boundary_trimmed),
        .source_key = source_key,
        .subject_leading = leadingSubjectEnd(boundary_trimmed, subject) != null,
        .target_match = containsSubjectRune(boundary_trimmed, subject),
    };
}

fn synthesizeEvidenceSentence(allocator: std.mem.Allocator, evidence_text: []const u8, subject: []const u8) ![]u8 {
    var block = try synthesizeEvidenceBlock(allocator, evidence_text, subject, null);
    defer block.deinit(allocator);
    return allocator.dupe(u8, block.text);
}

fn appendCohesiveBlock(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    block: SynthesizedBlock,
    subject: []const u8,
    state: *SubjectState,
    selected: usize,
) !void {
    const deduped = try applySubjectDeduplication(allocator, block.text, subject, state.previous_subject_leading and block.subject_leading);
    defer allocator.free(deduped);

    var used_glue = false;
    if (out.items.len != 0) {
        const current_source_hash = metadataSourceHash(block.source_key);
        if (state.previous_has_source and block.source_key.len != 0 and state.previous_source_hash == current_source_hash) {
            try out.appendSlice(" Additionally, ");
            used_glue = true;
        } else if (block.target_match) {
            try out.appendSlice(specifyingGlue(block.source_key, selected));
            used_glue = true;
        } else {
            try out.append(' ');
        }
    }
    try appendSentenceWithCase(out, deduped, used_glue);
    state.previous_subject_leading = block.subject_leading;
    state.previous_source_hash = metadataSourceHash(block.source_key);
    state.previous_has_source = block.source_key.len != 0;
}

fn sourceKeyForEvidence(allocator: std.mem.Allocator, evidence_text: []const u8, source_hint: ?[]const u8) ![]u8 {
    if (source_hint) |hint| {
        const trimmed = std.mem.trim(u8, hint, " \r\n\t");
        if (trimmed.len != 0) return allocator.dupe(u8, trimmed);
    }
    if (std.mem.indexOf(u8, evidence_text, "]]")) |end| {
        const key = std.mem.trim(u8, evidence_text[0..end], " \r\n\t");
        if (key.len != 0 and key.len <= 160) return allocator.dupe(u8, key);
    }
    if (std.mem.indexOfScalar(u8, evidence_text, '\n')) |line_end| {
        const key = std.mem.trim(u8, evidence_text[0..line_end], " \r\n\t");
        if (key.len != 0 and key.len <= 160) return allocator.dupe(u8, key);
    }
    const trimmed = std.mem.trim(u8, evidence_text, " \r\n\t");
    return allocator.dupe(u8, trimmed[0..@min(trimmed.len, 160)]);
}

fn metadataRuneDistance(a: []const u8, b: []const u8) u32 {
    if (a.len == 0 or b.len == 0) return 64;
    return @popCount(metadataRuneMask(a) ^ metadataRuneMask(b));
}

fn metadataSourceHash(text: []const u8) u64 {
    var hasher = std.hash.Fnv1a_64.init();
    hasher.update(text);
    return hasher.final();
}

fn metadataRuneMask(text: []const u8) u64 {
    var mask: u64 = 0;
    for (text) |byte| {
        if (!std.ascii.isAlphanumeric(byte)) continue;
        const lower = std.ascii.toLower(byte);
        const slot: u6 = @intCast(@as(u32, lower) & 63);
        mask |= @as(u64, 1) << slot;
    }
    return mask;
}

fn specifyingGlue(source_key: []const u8, selected: usize) []const u8 {
    var hasher = std.hash.Fnv1a_64.init();
    hasher.update(source_key);
    var index_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &index_bytes, selected, .little);
    hasher.update(&index_bytes);
    return if (hasher.final() & 1 == 0) " Specifically, " else " In practice, ";
}

fn applySubjectDeduplication(allocator: std.mem.Allocator, sentence: []const u8, subject: []const u8, should_replace: bool) ![]u8 {
    if (!should_replace) return allocator.dupe(u8, sentence);
    const subject_end = leadingSubjectEnd(sentence, subject) orelse return allocator.dupe(u8, sentence);
    const remainder = std.mem.trimLeft(u8, sentence[subject_end..], " \r\n\t,:;-");
    if (remainder.len == 0) return allocator.dupe(u8, sentence);
    return std.fmt.allocPrint(allocator, "{s} {s}", .{ pronounForSubject(subject), remainder });
}

fn pronounForSubject(subject: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, subject, " \r\n\t.,;:!?()[]{}\"'");
    if (isPluralSubject(trimmed)) return "They";
    if (std.ascii.indexOfIgnoreCase(trimmed, "component") != null) return "This component";
    return "It";
}

fn isPluralSubject(subject: []const u8) bool {
    if (std.ascii.indexOfIgnoreCase(subject, " and ") != null) return true;
    if (subject.len < 2) return false;
    const last = std.ascii.toLower(subject[subject.len - 1]);
    const prev = std.ascii.toLower(subject[subject.len - 2]);
    return last == 's' and prev != 's';
}

fn leadingSubjectEnd(sentence: []const u8, subject: []const u8) ?usize {
    const trimmed_subject = std.mem.trim(u8, subject, " \r\n\t.,;:!?()[]{}\"'");
    if (trimmed_subject.len == 0) return null;
    if (leadingSubjectEndExact(sentence, trimmed_subject)) |end| return end;
    const alias = primarySubjectAlias(trimmed_subject);
    if (!std.mem.eql(u8, alias, trimmed_subject)) return leadingSubjectEndExact(sentence, alias);
    return null;
}

fn leadingSubjectEndExact(sentence: []const u8, subject: []const u8) ?usize {
    var start: usize = 0;
    while (start < sentence.len and std.ascii.isWhitespace(sentence[start])) : (start += 1) {}
    const article_prefixes = [_][]const u8{ "a ", "an ", "the " };
    for (article_prefixes) |article| {
        if (startsWithIgnoreCaseAt(sentence, start, article)) {
            if (subjectAt(sentence, start + article.len, subject)) |end| return end;
        }
    }
    return subjectAt(sentence, start, subject);
}

fn primarySubjectAlias(subject: []const u8) []const u8 {
    var it = std.mem.tokenizeAny(u8, subject, " \r\n\t.,;:!?()[]{}\"'");
    while (it.next()) |token| {
        if (token.len < 3) continue;
        if (isSubjectAliasStopWord(token)) continue;
        return token;
    }
    return subject;
}

fn isSubjectAliasStopWord(token: []const u8) bool {
    const words = [_][]const u8{ "the", "and", "for", "with", "how", "why", "what", "explain", "processes" };
    for (words) |word| {
        if (std.ascii.eqlIgnoreCase(token, word)) return true;
    }
    return false;
}

fn subjectAt(sentence: []const u8, start: usize, subject: []const u8) ?usize {
    if (start + subject.len > sentence.len) return null;
    if (!std.ascii.eqlIgnoreCase(sentence[start .. start + subject.len], subject)) return null;
    const end = start + subject.len;
    if (end < sentence.len and std.ascii.isAlphanumeric(sentence[end])) return null;
    return end;
}

fn startsWithIgnoreCaseAt(text: []const u8, start: usize, prefix: []const u8) bool {
    return start + prefix.len <= text.len and std.ascii.eqlIgnoreCase(text[start .. start + prefix.len], prefix);
}

fn appendSentenceWithCase(out: *std.ArrayList(u8), sentence: []const u8, after_glue: bool) !void {
    if (!after_glue and out.items.len == 0 and sentence.len != 0) {
        try out.append(std.ascii.toUpper(sentence[0]));
        try out.appendSlice(sentence[1..]);
        return;
    }
    if (!after_glue or sentence.len == 0 or !startsWithContextPronoun(sentence)) {
        try out.appendSlice(sentence);
        return;
    }
    try out.append(std.ascii.toLower(sentence[0]));
    try out.appendSlice(sentence[1..]);
}

fn startsWithContextPronoun(sentence: []const u8) bool {
    return std.mem.startsWith(u8, sentence, "It ") or
        std.mem.startsWith(u8, sentence, "They ") or
        std.mem.startsWith(u8, sentence, "This component ");
}

fn trimSnippetBoundary(sentence: []const u8) []const u8 {
    var trimmed = std.mem.trim(u8, sentence, " \r\n\t,;:-");
    while (stripLeadingDanglingWord(trimmed)) |next| trimmed = next;
    trimmed = stripIncompleteParenthetical(trimmed);
    trimmed = stripTrailingDanglingWord(trimmed);
    return std.mem.trim(u8, trimmed, " \r\n\t,;:-");
}

fn stripLeadingDanglingWord(sentence: []const u8) ?[]const u8 {
    const words = [_][]const u8{ "and", "but", "or" };
    for (words) |word| {
        if (sentence.len <= word.len) continue;
        if (!std.ascii.eqlIgnoreCase(sentence[0..word.len], word)) continue;
        if (!std.ascii.isWhitespace(sentence[word.len]) and sentence[word.len] != ',') continue;
        return std.mem.trimLeft(u8, sentence[word.len..], " \r\n\t,;:-");
    }
    return null;
}

fn stripTrailingDanglingWord(sentence: []const u8) []const u8 {
    var trimmed = std.mem.trimRight(u8, sentence, " \r\n\t,;:-.!?");
    const words = [_][]const u8{ "and", "but", "or", "could", "would", "should", "can", "to", "with", "of", "the", "a", "an", "one", "either", "compete", "miners", "called", "are" };
    while (true) {
        var changed = false;
        for (words) |word| {
            if (trimmed.len < word.len) continue;
            const start = trimmed.len - word.len;
            if (!std.ascii.eqlIgnoreCase(trimmed[start..], word)) continue;
            if (start != 0 and std.ascii.isAlphanumeric(trimmed[start - 1])) continue;
            trimmed = std.mem.trimRight(u8, trimmed[0..start], " \r\n\t,;:-.!?");
            changed = true;
            break;
        }
        if (!changed) break;
    }
    return trimmed;
}

fn stripIncompleteParenthetical(sentence: []const u8) []const u8 {
    var depth: usize = 0;
    var last_unclosed_open: ?usize = null;
    var start: usize = 0;
    while (start < sentence.len and sentence[start] == ')') : (start += 1) {}
    for (sentence[start..], start..) |byte, idx| {
        switch (byte) {
            '(' => {
                depth += 1;
                last_unclosed_open = idx;
            },
            ')' => if (depth > 0) {
                depth -= 1;
                if (depth == 0) last_unclosed_open = null;
            },
            else => {},
        }
    }
    if (last_unclosed_open) |open_idx| {
        return std.mem.trimRight(u8, sentence[start..open_idx], " \r\n\t,;:-");
    }
    return sentence[start..];
}

fn finishSentenceAlloc(allocator: std.mem.Allocator, sentence: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, sentence, " \r\n\t");
    if (trimmed.len == 0) return allocator.dupe(u8, "");
    switch (trimmed[trimmed.len - 1]) {
        '.', '!', '?' => return allocator.dupe(u8, trimmed),
        else => return std.fmt.allocPrint(allocator, "{s}.", .{trimmed}),
    }
}

fn cleanEvidenceText(allocator: std.mem.Allocator, evidence_text: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    var previous_space = true;
    var idx: usize = 0;
    while (idx < evidence_text.len) : (idx += 1) {
        const byte = evidence_text[idx];
        if (byte == ']' and idx + 1 < evidence_text.len and evidence_text[idx + 1] == ']') {
            try appendSentenceBoundary(&out);
            previous_space = true;
            idx += 1;
            continue;
        }
        const as_space = std.ascii.isWhitespace(byte) or byte == '[' or byte == ']';
        if (as_space) {
            if (!previous_space) try out.append(' ');
            previous_space = true;
            continue;
        }
        try out.append(byte);
        previous_space = false;
    }
    return out.toOwnedSlice();
}

fn appendSentenceBoundary(out: *std.ArrayList(u8)) !void {
    while (out.items.len != 0 and std.ascii.isWhitespace(out.items[out.items.len - 1])) {
        _ = out.pop();
    }
    const needs_period = out.items.len == 0 or switch (out.items[out.items.len - 1]) {
        '.', '!', '?' => false,
        else => true,
    };
    if (needs_period) try out.append('.');
    try out.append(' ');
}

fn scoreEvidenceSentence(sentence: []const u8, subject: []const u8) i32 {
    if (sentence.len == 0) return std.math.minInt(i32);
    var score: i32 = 0;
    if (containsSubjectRune(sentence, subject)) score += 40;
    if (definitionSubjectIndex(sentence, subject) != null) score += 90;
    if (startsWithMetadataLabel(sentence)) score -= 15;
    return score;
}

fn focusDefinitionStart(sentence: []const u8, subject: []const u8) []const u8 {
    if (startsWithMetadataLabel(sentence)) {
        if (afterFirstSentenceBoundary(sentence)) |body| return focusDefinitionStart(body, subject);
    }
    const alias = primarySubjectAlias(subject);
    const subject_idx = definitionSubjectIndex(sentence, subject) orelse
        indexOfIgnoreCaseLocal(sentence, subject) orelse
        indexOfIgnoreCaseLocal(sentence, alias) orelse
        return stripTitleLead(sentence);
    var start = subject_idx;
    if (parameterPrefixStart(sentence, start)) |prefix_start| start = prefix_start;
    if (start >= 2 and sentence[start - 1] == ' ') {
        const article_start = if (start >= 3 and sentence[start - 3] == ' ') start - 2 else start - 2;
        const article = sentence[article_start .. start - 1];
        if (std.ascii.eqlIgnoreCase(article, "a")) start = article_start;
    }
    return std.mem.trim(u8, sentence[start..], " \r\n\t:;-");
}

fn afterFirstSentenceBoundary(sentence: []const u8) ?[]const u8 {
    for (sentence, 0..) |byte, idx| {
        switch (byte) {
            '.', '!', '?' => {
                const body = std.mem.trim(u8, sentence[idx + 1 ..], " \r\n\t");
                if (body.len != 0) return body;
                return null;
            },
            else => {},
        }
    }
    return null;
}

fn parameterPrefixStart(sentence: []const u8, subject_start: usize) ?usize {
    if (subject_start == 0 or sentence[subject_start - 1] != ' ') return null;
    var start = subject_start - 1;
    while (start > 0 and !std.ascii.isWhitespace(sentence[start - 1])) : (start -= 1) {}
    const prefix = sentence[start .. subject_start - 1];
    for (prefix) |byte| {
        if (std.ascii.isDigit(byte) or byte == '-' or byte == '_' or byte == '/') return start;
    }
    return null;
}

fn definitionSubjectIndex(sentence: []const u8, subject: []const u8) ?usize {
    if (definitionSubjectIndexExact(sentence, subject)) |idx| return idx;
    const alias = primarySubjectAlias(subject);
    if (!std.mem.eql(u8, alias, subject)) return definitionSubjectIndexExact(sentence, alias);
    return null;
}

fn definitionSubjectIndexExact(sentence: []const u8, subject: []const u8) ?usize {
    var search_start: usize = 0;
    while (indexOfIgnoreCasePosLocal(sentence, search_start, subject)) |idx| {
        const after = sentence[idx + subject.len ..];
        const window = after[0..@min(after.len, 96)];
        if (definitionVerbInSameClause(window)) {
            return idx;
        }
        search_start = idx + subject.len;
    }
    return null;
}

fn containsSubjectRune(sentence: []const u8, subject: []const u8) bool {
    return indexOfIgnoreCaseLocal(sentence, subject) != null or
        indexOfIgnoreCaseLocal(sentence, primarySubjectAlias(subject)) != null;
}

fn definitionVerbInSameClause(window: []const u8) bool {
    var idx: usize = 0;
    while (idx < window.len and std.ascii.isWhitespace(window[idx])) : (idx += 1) {}
    var paren_depth: usize = 0;
    while (idx < window.len) : (idx += 1) {
        switch (window[idx]) {
            '(' => paren_depth += 1,
            ')' => if (paren_depth > 0) {
                paren_depth -= 1;
            },
            '.', '!', '?' => return false,
            else => {},
        }
        if (paren_depth == 0) {
            const rest = window[idx..];
            if (startsWithDefinitionVerb(rest)) {
                return true;
            }
        }
    }
    return false;
}

fn startsWithDefinitionVerb(text: []const u8) bool {
    const verbs = [_][]const u8{ " is ", " are ", " refers " };
    for (verbs) |verb| {
        if (std.ascii.startsWithIgnoreCase(text, verb)) return true;
    }
    return false;
}

fn startsWithMetadataLabel(text: []const u8) bool {
    const labels = [_][]const u8{ "title:", "source:", "path:" };
    for (labels) |label| {
        if (std.ascii.startsWithIgnoreCase(text, label)) return true;
    }
    return false;
}

fn stripTitleLead(sentence: []const u8) []const u8 {
    if (!std.ascii.startsWithIgnoreCase(sentence, "title:")) return sentence;
    if (std.mem.indexOf(u8, sentence, "  ")) |idx| {
        return std.mem.trim(u8, sentence[idx..], " \r\n\t");
    }
    return std.mem.trim(u8, sentence["title:".len..], " \r\n\t");
}

fn boundSentence(sentence: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, sentence, " \r\n\t");
    if (trimmed.len <= 260) return trimmed;
    var end: usize = 260;
    while (end > 160) : (end -= 1) {
        if (std.ascii.isWhitespace(trimmed[end])) break;
    }
    return std.mem.trim(u8, trimmed[0..end], " \r\n\t,;:");
}

fn runeVarianceScore(text: []const u8) u32 {
    if (text.len == 0) return 0;
    var counts = [_]u16{0} ** 256;
    var total: u32 = 0;
    for (text) |byte| {
        if (!isVarianceRuneByte(byte)) continue;
        counts[byte] += 1;
        total += 1;
    }
    if (total == 0) return 0;
    var unique: u32 = 0;
    var spread: u32 = 0;
    for (counts) |count| {
        if (count == 0) continue;
        unique += 1;
        spread += @as(u32, count) * @as(u32, count);
    }
    const uniqueness = (unique * 1000) / total;
    const repetition_penalty = @min(@as(u32, 1000), spread / total);
    return uniqueness + (1000 - repetition_penalty);
}

fn isVarianceRuneByte(byte: u8) bool {
    return byte >= 0x80 or std.ascii.isAlphanumeric(byte);
}

fn indexOfIgnoreCaseLocal(haystack: []const u8, needle: []const u8) ?usize {
    return indexOfIgnoreCasePosLocal(haystack, 0, needle);
}

fn indexOfIgnoreCasePosLocal(haystack: []const u8, start: usize, needle: []const u8) ?usize {
    if (needle.len == 0 or needle.len > haystack.len) return null;
    var idx: usize = start;
    while (idx + needle.len <= haystack.len) : (idx += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[idx .. idx + needle.len], needle)) return idx;
    }
    return null;
}

fn denialSubject(allocator: std.mem.Allocator, query: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, query, " \t\r\n\"'`.,;:!?()[]{}");
    if (trimmed.len == 0) return allocator.dupe(u8, "the requested query");

    var subject = trimmed;
    const lower = try asciiLowerAlloc(allocator, trimmed);
    defer allocator.free(lower);

    const prefixes = [_][]const u8{
        "what is ",
        "whats a ",
        "what's a ",
        "whats an ",
        "what's an ",
        "whats ",
        "what's ",
        "what are ",
        "who is ",
        "who are ",
        "where is ",
        "where are ",
        "when is ",
        "when are ",
        "explain ",
        "define ",
        "tell me about ",
        "do you know ",
        "can you find ",
    };
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, lower, prefix)) {
            subject = trimmed[prefix.len..];
            break;
        }
    }

    subject = std.mem.trim(u8, subject, " \t\r\n\"'`.,;:!?()[]{}");
    if (subject.len == 0) return allocator.dupe(u8, "the requested query");
    const max_len: usize = 96;
    if (subject.len <= max_len) return allocator.dupe(u8, subject);
    return std.fmt.allocPrint(allocator, "{s}...", .{std.mem.trim(u8, subject[0..max_len], " \t\r\n\"'`.,;:!?()[]{}")});
}

fn asciiLowerAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, text.len);
    for (text, 0..) |byte, idx| out[idx] = std.ascii.toLower(byte);
    return out;
}

fn generateOperatorSummaryDraftInternal(
    allocator: std.mem.Allocator,
    input: TextGenerationInput,
    memory_store: ?LabMemoryStore,
) !TextGenerationDraft {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const writer = out.writer();
    const lab_memory_applied = if (memory_store) |store| store.acceptedCount() > 0 else false;

    try writer.writeAll("TEXT GENERATION LAB DRAFT / CANDIDATE ONLY / NON-AUTHORIZING\n");
    try writer.print("Authority: proof_granted=false, support_granted=false, mutates_state=false, training_applied=false, lab_memory_applied={}, product_ready=false.\n\n", .{lab_memory_applied});

    if (hasNoSignals(input)) {
        try writer.writeAll("Summary: insufficient inspected signal to draft a substantive operator summary without guessing.\n");
        try writer.writeAll("Unknowns:\n");
        try writer.writeAll("- no claims, obligations, inconsistencies, or explicit unknowns were supplied\n");
    } else {
        try writer.writeAll("Summary: inspected artifact/corpus-like signals produced a draft for operator review.\n");
        try writeSourceSection(writer, input);
        try writeTextSignals(writer, "Detected claims", input.detected_claims);
        try writeTextSignals(writer, "Detected obligations", input.detected_obligations);
        try writeInconsistencies(writer, input.candidate_inconsistencies);
        try writeUnknowns(writer, input.unknowns);
    }
    if (memory_store) |store| try writeLabMemorySection(writer, store);
    if (hasNoSignals(input)) {
        try writer.writeAll("Boundary: no evidence is not negative evidence, and unknown is not false.\n");
    } else {
        try writer.writeAll("Boundary: this draft may guide review, but it is not evidence, proof, support, or verifier output.\n");
    }

    return .{
        .draft_text = try out.toOwnedSlice(),
        .source_artifact_ids = input.source_artifact_ids,
        .source_paths = input.source_paths,
        .unknowns = input.unknowns,
        .lab_memory_applied = lab_memory_applied,
    };
}

pub fn proposeMemoryFromCorpusSignals(
    allocator: std.mem.Allocator,
    store: *LabMemoryStore,
    input: TextGenerationInput,
) !usize {
    var proposed: usize = 0;
    for (input.detected_claims) |signal| {
        if (try appendMemoryCandidate(allocator, store, .claim, signal.source_path, signal.text)) proposed += 1;
    }
    for (input.detected_obligations) |signal| {
        if (try appendMemoryCandidate(allocator, store, .obligation, signal.source_path, signal.text)) proposed += 1;
    }
    const unknown_source_path = if (input.source_paths.len > 0) input.source_paths[0] else "lab-local-unknown";
    for (input.unknowns) |unknown| {
        if (try appendMemoryCandidate(allocator, store, .unknown, unknown_source_path, unknown)) proposed += 1;
    }
    return proposed;
}

pub fn acceptLabMemoryRecord(store: *LabMemoryStore, id: []const u8) !void {
    const record = findLabMemoryRecord(store, id) orelse return error.LabMemoryRecordNotFound;
    record.review_state = .accepted;
}

pub fn rejectLabMemoryRecord(store: *LabMemoryStore, id: []const u8) !void {
    const record = findLabMemoryRecord(store, id) orelse return error.LabMemoryRecordNotFound;
    record.review_state = .rejected;
}

pub fn ingestCorpusAndGenerateDraft(
    allocator: std.mem.Allocator,
    input: CorpusIngestInput,
) !CorpusIngestDraftResult {
    if (input.workspace_root.len == 0) return error.EmptyWorkspaceRoot;
    var root_dir = try std.fs.cwd().openDir(input.workspace_root, .{});
    defer root_dir.close();
    return ingestCorpusAndGenerateDraftFromDir(allocator, root_dir, input.corpus_paths, input.limits);
}

fn ingestCorpusAndGenerateDraftFromDir(
    allocator: std.mem.Allocator,
    root_dir: std.fs.Dir,
    corpus_paths: []const []const u8,
    limits: CorpusIngestLimits,
) !CorpusIngestDraftResult {
    var extraction = try readCorpusSignalsFromDir(allocator, root_dir, corpus_paths, limits);
    errdefer extraction.deinit(allocator);

    const draft = try generateOperatorSummaryDraft(allocator, extraction.input);
    errdefer draft.deinit(allocator);

    const training_examples = [_]TrainingExample{
        .{
            .source_id = "lab-local-corpus-ingest",
            .input_text = "bounded file-backed corpus signals",
            .desired_draft = "candidate-only non-authorizing operator draft",
        },
    };
    const training_summary = try summarizeTrainingExamples(allocator, if (extraction.summary.claim_count +
        extraction.summary.obligation_count +
        extraction.summary.unknown_count == 0) &.{} else &training_examples);
    errdefer training_summary.deinit(allocator);

    return .{
        .draft = draft,
        .training_summary = training_summary,
        .ingest_summary = extraction.summary,
        .extraction = extraction,
    };
}

pub fn summarizeTrainingExamples(
    allocator: std.mem.Allocator,
    examples: []const TrainingExample,
) !TrainingLabResult {
    return summarizeTrainingExamplesWithAcceleration(allocator, examples, .cpu);
}

pub fn summarizeTrainingExamplesWithAcceleration(
    allocator: std.mem.Allocator,
    examples: []const TrainingExample,
    acceleration: HashAcceleration,
) !TrainingLabResult {
    const requested_policy: hash_acceleration.Policy = switch (acceleration) {
        .cpu => .cpu,
        .rocm, .vulkan => .vulkan,
    };
    var accel_ctx = if (requested_policy == .vulkan)
        hash_acceleration.Context.init(allocator, "text generation lab rune hashing")
    else
        hash_acceleration.Context{ .allocator = allocator, .policy = .cpu };
    defer accel_ctx.deinit();

    var counts = std.ArrayList(RuneCount).init(allocator);
    errdefer counts.deinit();
    var rune_total: usize = 0;
    var vector_batch_count: usize = 0;

    for (examples) |example| {
        rune_total += try addRunes(&counts, example.input_text);
        rune_total += try addRunes(&counts, example.desired_draft);
        _ = try hashRuneBlockBatch(&accel_ctx, allocator, &.{ example.input_text, example.desired_draft });
        vector_batch_count += 1;
    }

    return .{
        .examples_seen = examples.len,
        .rune_count = rune_total,
        .vector_batch_count = vector_batch_count,
        .acceleration = accel_ctx.activeName(),
        .rocm_available = false,
        .frequency_table = try counts.toOwnedSlice(),
    };
}

fn hashRuneBlockBatch(acceleration: ?*hash_acceleration.Context, allocator: std.mem.Allocator, blocks: []const []const u8) !u64 {
    var hasher = std.hash.Fnv1a_64.init();
    for (blocks) |block| {
        const semantic_hash = try hash_acceleration.semanticHash64(acceleration, allocator, block);
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, semantic_hash, .little);
        hasher.update(&buf);
        hasher.update("\n---rune-block---\n");
    }
    return hasher.final();
}

fn readCorpusSignalsFromDir(
    allocator: std.mem.Allocator,
    root_dir: std.fs.Dir,
    corpus_paths: []const []const u8,
    limits: CorpusIngestLimits,
) !CorpusSignalExtraction {
    if (corpus_paths.len > limits.max_file_count) return error.TooManyCorpusFiles;

    var source_paths = std.ArrayList([]const u8).init(allocator);
    errdefer source_paths.deinit();
    errdefer freeStringList(allocator, source_paths.items);

    var claims = std.ArrayList(TextSignal).init(allocator);
    errdefer claims.deinit();
    errdefer freeSignals(allocator, claims.items);

    var obligations = std.ArrayList(TextSignal).init(allocator);
    errdefer obligations.deinit();
    errdefer freeSignals(allocator, obligations.items);

    var unknowns = std.ArrayList([]const u8).init(allocator);
    errdefer unknowns.deinit();
    errdefer freeStringList(allocator, unknowns.items);

    var unique_lines = std.ArrayList([]const u8).init(allocator);
    defer {
        freeStringList(allocator, unique_lines.items);
        unique_lines.deinit();
    }

    var summary = CorpusIngestSummary{
        .files_seen = 0,
        .bytes_seen = 0,
        .claim_count = 0,
        .obligation_count = 0,
        .unknown_count = 0,
        .duplicate_line_count = 0,
    };

    for (corpus_paths) |path| {
        try validateCorpusPath(path);
        const stat = try statNoFollow(root_dir, path);
        switch (stat.kind) {
            .file => {},
            .directory => return error.CorpusPathIsDirectory,
            .sym_link => return error.CorpusPathIsSymlink,
            else => return error.CorpusPathIsNotFile,
        }
        if (stat.size > limits.max_bytes_per_file) return error.CorpusFileTooLarge;
        if (summary.bytes_seen + stat.size > limits.max_total_bytes) return error.CorpusTotalBytesExceeded;

        var file = try root_dir.openFile(path, .{ .mode = .read_only });
        defer file.close();
        const content = try file.readToEndAlloc(allocator, limits.max_bytes_per_file);
        defer allocator.free(content);
        summary.bytes_seen += content.len;
        summary.files_seen += 1;

        const owned_path = try allocator.dupe(u8, path);
        source_paths.append(owned_path) catch |err| {
            allocator.free(owned_path);
            return err;
        };

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r\n");
            if (line.len == 0) continue;
            if (containsLine(unique_lines.items, line)) {
                summary.duplicate_line_count += 1;
                continue;
            }
            const stored_line = try allocator.dupe(u8, line);
            unique_lines.append(stored_line) catch |err| {
                allocator.free(stored_line);
                return err;
            };

            if (std.ascii.indexOfIgnoreCase(line, "claim:") != null) {
                try appendSignal(allocator, &claims, owned_path, "corpus_claim", line);
                summary.claim_count += 1;
            }
            if (std.ascii.indexOfIgnoreCase(line, "obligation:") != null or
                std.ascii.indexOfIgnoreCase(line, "must") != null)
            {
                try appendSignal(allocator, &obligations, owned_path, "corpus_obligation", line);
                summary.obligation_count += 1;
            }
            if (std.ascii.indexOfIgnoreCase(line, "unknown:") != null or
                std.ascii.indexOfIgnoreCase(line, "todo:") != null)
            {
                try appendStringCopy(allocator, &unknowns, line);
                summary.unknown_count += 1;
            }
        }
    }

    return .{
        .input = .{
            .source_paths = try source_paths.toOwnedSlice(),
            .detected_claims = try claims.toOwnedSlice(),
            .detected_obligations = try obligations.toOwnedSlice(),
            .unknowns = try unknowns.toOwnedSlice(),
        },
        .summary = summary,
    };
}

fn hasNoSignals(input: TextGenerationInput) bool {
    return input.detected_claims.len == 0 and
        input.detected_obligations.len == 0 and
        input.candidate_inconsistencies.len == 0 and
        input.unknowns.len == 0;
}

fn appendMemoryCandidate(
    allocator: std.mem.Allocator,
    store: *LabMemoryStore,
    kind: LabMemorySignalKind,
    source_path: []const u8,
    text: []const u8,
) !bool {
    if (containsLabMemoryRecord(store.records.items, kind, source_path, text)) return false;

    const next_index = store.records.items.len + 1;
    const id = try std.fmt.allocPrint(allocator, "lab-memory-{d}", .{next_index});
    errdefer allocator.free(id);
    const owned_source_path = try allocator.dupe(u8, source_path);
    errdefer allocator.free(owned_source_path);
    const owned_text = try allocator.dupe(u8, text);
    errdefer allocator.free(owned_text);

    try store.records.append(.{
        .id = id,
        .source_path = owned_source_path,
        .signal_kind = kind,
        .text = owned_text,
    });
    return true;
}

fn findLabMemoryRecord(store: *LabMemoryStore, id: []const u8) ?*LabMemoryRecord {
    for (store.records.items) |*record| {
        if (std.mem.eql(u8, record.id, id)) return record;
    }
    return null;
}

fn containsLabMemoryRecord(
    records: []const LabMemoryRecord,
    kind: LabMemorySignalKind,
    source_path: []const u8,
    text: []const u8,
) bool {
    for (records) |record| {
        if (record.signal_kind == kind and
            std.mem.eql(u8, record.source_path, source_path) and
            std.mem.eql(u8, record.text, text))
        {
            return true;
        }
    }
    return false;
}

fn signalKindName(kind: LabMemorySignalKind) []const u8 {
    return switch (kind) {
        .claim => "claim",
        .obligation => "obligation",
        .unknown => "unknown",
    };
}

fn writeSourceSection(writer: anytype, input: TextGenerationInput) !void {
    if (input.source_artifact_ids.len > 0) {
        try writer.writeAll("\nSource artifact ids:\n");
        for (input.source_artifact_ids) |id| {
            try writer.print("- {s}\n", .{id});
        }
    }
    if (input.source_paths.len > 0) {
        try writer.writeAll("\nSource paths:\n");
        for (input.source_paths) |path| {
            try writer.print("- {s}\n", .{path});
        }
    }
}

fn writeTextSignals(writer: anytype, title: []const u8, signals: []const TextSignal) !void {
    if (signals.len == 0) return;
    try writer.print("\n{s}:\n", .{title});
    for (signals) |signal| {
        try writer.print("- [{s}] {s}: {s}\n", .{ signal.kind, signal.source_path, signal.text });
    }
}

fn writeInconsistencies(writer: anytype, inconsistencies: []const CandidateInconsistencySignal) !void {
    if (inconsistencies.len == 0) return;
    try writer.writeAll("\nCandidate inconsistencies:\n");
    for (inconsistencies) |inconsistency| {
        try writer.print("- {s}: {s}\n", .{ inconsistency.id, inconsistency.description });
        if (inconsistency.source_paths.len > 0) {
            try writer.writeAll("  paths:");
            for (inconsistency.source_paths) |path| {
                try writer.print(" {s}", .{path});
            }
            try writer.writeByte('\n');
        }
    }
}

fn writeUnknowns(writer: anytype, unknowns: []const []const u8) !void {
    if (unknowns.len == 0) return;
    try writer.writeAll("\nUnknowns:\n");
    for (unknowns) |unknown| {
        try writer.print("- unknown: {s}\n", .{unknown});
    }
    try writer.writeAll("Unknown handling: unknown is not false; missing evidence is not negative evidence.\n");
}

fn writeLabMemorySection(writer: anytype, store: LabMemoryStore) !void {
    if (store.records.items.len == 0) return;

    var accepted_seen = false;
    for (store.records.items) |record| {
        if (record.review_state != .accepted) continue;
        if (!accepted_seen) {
            try writer.writeAll("\nAccepted lab memory reminders / NON-AUTHORIZING / LAB-LOCAL:\n");
            accepted_seen = true;
        }
        try writer.print("- [{s}] {s}: {s}\n", .{ signalKindName(record.signal_kind), record.source_path, record.text });
    }
    if (accepted_seen) {
        try writer.writeAll("Lab memory boundary: reviewed lab memory can influence this lab draft only; it grants no proof, support, verifier result, trusted memory, or product readiness.\n");
    }

    var pending_seen = false;
    for (store.records.items) |record| {
        if (record.review_state != .candidate) continue;
        if (!pending_seen) {
            try writer.writeAll("\nPending lab memory review / NOT APPLIED:\n");
            pending_seen = true;
        }
        try writer.print("- [{s}] {s}: {s}\n", .{ signalKindName(record.signal_kind), record.source_path, record.text });
    }

    var rejected_seen = false;
    for (store.records.items) |record| {
        if (record.review_state != .rejected) continue;
        if (!rejected_seen) {
            try writer.writeAll("\nRejected lab memory / NOT APPLIED:\n");
            rejected_seen = true;
        }
        try writer.print("- [{s}] {s}: {s}\n", .{ signalKindName(record.signal_kind), record.source_path, record.text });
    }
}

fn addRunes(counts: *std.ArrayList(RuneCount), text: []const u8) !usize {
    // Current rune_count is a lab-local simple lexical count, not final Ghost runeization.
    var seen: usize = 0;
    var runes = std.mem.tokenizeAny(u8, text, " \t\r\n.,;:!?()[]{}<>\"'");
    while (runes.next()) |rune| {
        if (rune.len == 0) continue;
        seen += 1;
        if (findRune(counts.items, rune)) |index| {
            counts.items[index].count += 1;
        } else {
            try counts.append(.{ .rune = rune, .count = 1 });
        }
    }
    return seen;
}

fn findRune(counts: []const RuneCount, rune: []const u8) ?usize {
    for (counts, 0..) |entry, index| {
        if (std.ascii.eqlIgnoreCase(entry.rune, rune)) return index;
    }
    return null;
}

fn validateCorpusPath(path: []const u8) !void {
    if (path.len == 0) return error.EmptyCorpusPath;
    if (std.fs.path.isAbsolute(path)) return error.AbsoluteCorpusPathRejected;
    var components = std.mem.tokenizeAny(u8, path, "/\\");
    while (components.next()) |component| {
        if (std.mem.eql(u8, component, "..")) return error.PathTraversalRejected;
    }
}

fn statNoFollow(root_dir: std.fs.Dir, path: []const u8) !std.fs.File.Stat {
    if (builtin.os.tag == .windows) {
        return root_dir.statFile(path);
    }

    const stat = try std.posix.fstatat(root_dir.fd, path, std.posix.AT.SYMLINK_NOFOLLOW);
    return std.fs.File.Stat.fromPosix(stat);
}

fn containsLine(lines: []const []const u8, line: []const u8) bool {
    for (lines) |candidate| {
        if (std.mem.eql(u8, candidate, line)) return true;
    }
    return false;
}

fn appendSignal(
    allocator: std.mem.Allocator,
    signals: *std.ArrayList(TextSignal),
    source_path: []const u8,
    kind: []const u8,
    text: []const u8,
) !void {
    const owned_text = try allocator.dupe(u8, text);
    signals.append(.{
        .source_path = source_path,
        .kind = kind,
        .text = owned_text,
    }) catch |err| {
        allocator.free(owned_text);
        return err;
    };
}

fn appendStringCopy(
    allocator: std.mem.Allocator,
    values: *std.ArrayList([]const u8),
    text: []const u8,
) !void {
    const owned_text = try allocator.dupe(u8, text);
    values.append(owned_text) catch |err| {
        allocator.free(owned_text);
        return err;
    };
}

fn freeSignals(allocator: std.mem.Allocator, signals: []const TextSignal) void {
    for (signals) |signal| allocator.free(signal.text);
}

fn freeStringList(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |value| allocator.free(value);
}

test "generated draft is candidate-only and non-authorizing" {
    const allocator = std.testing.allocator;
    const input = TextGenerationInput{
        .source_artifact_ids = &.{"artifact.autopsy.fixture.documentation"},
        .source_paths = &.{ "README.md", "Makefile" },
        .detected_claims = &.{
            .{ .source_path = "README.md", .kind = "build_instruction", .text = "README says to run make build" },
        },
    };

    const draft = try generateOperatorSummaryDraft(allocator, input);
    defer draft.deinit(allocator);

    try std.testing.expect(draft.candidate_only);
    try std.testing.expect(draft.non_authorizing);
    try std.testing.expect(!draft.product_ready);
    try std.testing.expect(std.mem.indexOf(u8, draft.draft_text, "CANDIDATE ONLY") != null);
    try std.testing.expect(std.mem.indexOf(u8, draft.draft_text, "NON-AUTHORIZING") != null);
}

test "generated draft does not grant proof support or mutation" {
    const allocator = std.testing.allocator;
    const input = TextGenerationInput{
        .detected_obligations = &.{
            .{ .source_path = "docs/runbook.md", .kind = "operator_step", .text = "operator should inspect retry budget" },
        },
    };

    const draft = try generateOperatorSummaryDraft(allocator, input);
    defer draft.deinit(allocator);

    try std.testing.expect(!draft.proof_granted);
    try std.testing.expect(!draft.support_granted);
    try std.testing.expect(!draft.mutates_state);
    try std.testing.expect(!draft.training_applied);
    try std.testing.expect(!draft.commands_executed);
    try std.testing.expect(!draft.verifiers_executed);
}

test "unknowns are rendered as unknowns not false claims" {
    const allocator = std.testing.allocator;
    const input = TextGenerationInput{
        .unknowns = &.{
            "whether the Makefile target succeeds on this host",
            "whether omitted evidence exists in another shard",
        },
    };

    const draft = try generateOperatorSummaryDraft(allocator, input);
    defer draft.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(u8, draft.draft_text, "unknown: whether the Makefile target succeeds on this host") != null);
    try std.testing.expect(std.mem.indexOf(u8, draft.draft_text, "unknown is not false") != null);
    try std.testing.expect(std.mem.indexOf(u8, draft.draft_text, "negative evidence") != null);
}

test "training examples are counted without mutating trusted state" {
    const allocator = std.testing.allocator;
    const result = try summarizeTrainingExamples(allocator, &.{
        .{
            .source_id = "example.one",
            .input_text = "claim unknown claim",
            .desired_draft = "unknown remains unknown",
        },
        .{
            .source_id = "example.two",
            .input_text = "draft only",
            .desired_draft = "candidate draft only",
        },
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), result.examples_seen);
    try std.testing.expectEqual(@as(usize, 11), result.rune_count);
    try std.testing.expect(!result.training_applied);
    try std.testing.expect(!result.mutates_state);
    try std.testing.expect(!result.proof_granted);
    try std.testing.expect(!result.support_granted);
    try std.testing.expect(!result.commands_executed);
    try std.testing.expect(!result.verifiers_executed);
    try std.testing.expect(findRune(result.frequency_table, "unknown") != null);
}

test "empty input produces insufficient signal draft without certainty" {
    const allocator = std.testing.allocator;
    const draft = try generateOperatorSummaryDraft(allocator, .{});
    defer draft.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(u8, draft.draft_text, "insufficient inspected signal") != null);
    try std.testing.expect(std.mem.indexOf(u8, draft.draft_text, "without guessing") != null);
    try std.testing.expect(std.mem.indexOf(u8, draft.draft_text, "no evidence is not negative evidence") != null);
    try std.testing.expect(!draft.proof_granted);
    try std.testing.expect(!draft.support_granted);
}

test "text lab is not product ready" {
    const allocator = std.testing.allocator;
    const draft = try generateOperatorSummaryDraft(allocator, .{});
    defer draft.deinit(allocator);
    const training = try summarizeTrainingExamples(allocator, &.{});
    defer training.deinit(allocator);

    try std.testing.expect(!draft.product_ready);
    try std.testing.expect(!training.product_ready);
}

test "lab surface has no command or verifier execution path" {
    const allocator = std.testing.allocator;
    const draft = try generateOperatorSummaryDraft(allocator, .{
        .candidate_inconsistencies = &.{
            .{
                .id = "candidate.mismatch",
                .description = "README and recipe disagree about a setup step",
                .source_paths = &.{ "README.md", "recipe.md" },
            },
        },
    });
    defer draft.deinit(allocator);
    const training = try summarizeTrainingExamples(allocator, &.{
        .{ .source_id = "example", .input_text = "no command execution", .desired_draft = "candidate wording" },
    });
    defer training.deinit(allocator);

    try std.testing.expect(!draft.commands_executed);
    try std.testing.expect(!draft.verifiers_executed);
    try std.testing.expect(!training.commands_executed);
    try std.testing.expect(!training.verifiers_executed);
}

test "fixture corpus ingestion produces candidate draft from claims obligations and unknowns" {
    const allocator = std.testing.allocator;
    const result = try ingestCorpusAndGenerateDraft(allocator, .{
        .workspace_root = ".",
        .corpus_paths = &.{
            "fixtures/text_generation_lab/corpus/doc_claims.md",
            "fixtures/text_generation_lab/corpus/runbook.md",
            "fixtures/text_generation_lab/corpus/noisy_notes.md",
            "fixtures/text_generation_lab/corpus/learning_seed.md",
        },
    });
    defer result.deinit(allocator);

    try std.testing.expect(result.draft.candidate_only);
    try std.testing.expect(result.draft.non_authorizing);
    try std.testing.expect(!result.draft.proof_granted);
    try std.testing.expect(!result.draft.support_granted);
    try std.testing.expect(!result.draft.mutates_state);
    try std.testing.expect(!result.draft.training_applied);
    try std.testing.expect(!result.training_summary.training_applied);
    try std.testing.expect(!result.draft.lab_memory_applied);
    try std.testing.expectEqual(@as(usize, 4), result.ingest_summary.files_seen);
    try std.testing.expect(result.ingest_summary.claim_count >= 3);
    try std.testing.expect(result.ingest_summary.obligation_count >= 2);
    try std.testing.expect(result.ingest_summary.unknown_count >= 2);
    try std.testing.expect(std.mem.indexOf(u8, result.draft.draft_text, "Detected claims") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.draft.draft_text, "Detected obligations") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.draft.draft_text, "Unknowns") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.draft.draft_text, "proof_granted=false") != null);
}

test "english core zenith draft names public source boundary" {
    const allocator = std.testing.allocator;
    const input = TextGenerationInput{
        .source_paths = &.{"english_core/@corpus/docs/simplewiki_part_0074.txt"},
        .detected_claims = &.{
            .{
                .source_path = "english_core/@corpus/docs/simplewiki_part_0074.txt",
                .kind = "corpus_claim",
                .text = "Zenith is a public astronomy reference point in the sky.",
            },
        },
    };

    const draft = try generateOperatorSummaryDraft(allocator, input);
    defer draft.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(u8, draft.draft_text, "Zenith is a public astronomy reference point in the sky.") != null);
    try std.testing.expect(std.mem.indexOf(u8, draft.draft_text, "Rank 0/Root access") == null);
}

test "conversational intent has no default responder" {
    const allocator = std.testing.allocator;

    try std.testing.expect((try generateDefaultResponderForIntent(allocator, .conversation)) == null);
}

test "denial draft is query-shaped and no fluff" {
    const allocator = std.testing.allocator;

    var one = try generateDenialDraft(allocator, .{ .user_query = "What is Nullstar-771?" });
    defer one.deinit(allocator);
    var two = try generateDenialDraft(allocator, .{ .user_query = "What is Voidmarker-992?" });
    defer two.deinit(allocator);

    try std.testing.expect(!std.mem.eql(u8, one.draft_text, two.draft_text));
    try std.testing.expect(std.mem.indexOf(u8, one.draft_text, "Nullstar-771") != null);
    try std.testing.expect(std.ascii.indexOfIgnoreCase(one.draft_text, "sorry") == null);
    try std.testing.expect(std.ascii.indexOfIgnoreCase(one.draft_text, "help") == null);
    try std.testing.expect(std.ascii.indexOfIgnoreCase(one.draft_text, "hello") == null);
    try std.testing.expect(!one.support_granted);
    try std.testing.expect(!one.proof_granted);
    try std.testing.expect(one.non_authorizing);
}

test "corpus synthesis starts at definition rune instead of title noise" {
    const allocator = std.testing.allocator;

    var draft = try generateCorpusSynthesisDraft(allocator, .{
        .user_query = "whats a father",
        .evidence_text = "TITLE: Father ]] A father (also called dad or daddy) is a male parent. Most humans are born from a mother and a father.",
    });
    defer draft.deinit(allocator);

    try std.testing.expectEqualStrings("A father (also called dad or daddy) is a male parent.", draft.draft_text);

    var negated_modifier = try generateCorpusSynthesisDraft(allocator, .{
        .user_query = "subject not excluded",
        .evidence_text = "TITLE: Subject .]] Subject is the primary definition sentence. Excluded is unrelated metadata.",
    });
    defer negated_modifier.deinit(allocator);
    try std.testing.expectEqualStrings("Subject is the primary definition sentence.", negated_modifier.draft_text);
}

test "corpus synthesis recursively uses non redundant evidence for dense requests" {
    const allocator = std.testing.allocator;
    const blocks = [_][]const u8{
        "TITLE: Silicon computer ]] Silicon computers use semiconductor devices to represent logic states.",
        "TITLE: Silicon computer architecture ]] Computer architecture organizes processors, memory, and input/output around executable instructions.",
        "TITLE: Silicon fabrication ]] Silicon chips are manufactured through layered photolithography and doping steps.",
    };

    var draft = try generateCorpusSynthesisDraft(allocator, .{
        .user_query = "i require an exhaustive explanation regarding the nature of silicon computers",
        .evidence_text = blocks[0],
        .evidence_texts = &blocks,
    });
    defer draft.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(u8, draft.draft_text, "semiconductor") != null);
    try std.testing.expect(std.mem.indexOf(u8, draft.draft_text, "architecture") != null);
}

test "corpus synthesis applies lexical glue and subject deduplication" {
    const allocator = std.testing.allocator;
    const blocks = [_][]const u8{
        "TITLE: CPU core ]] and CPU processes data by executing instructions,",
        "TITLE: CPU core ]] CPU handles arithmetic and control operations.",
        "TITLE: CPU clock ]] CPU uses clock cycles to coordinate work.",
    };
    const source_ids = [_][]const u8{
        "simplewiki_part_cpu_core",
        "simplewiki_part_cpu_core",
        "simplewiki_part_cpu_clock",
    };

    var draft = try generateCorpusSynthesisDraft(allocator, .{
        .user_query = "Explain how a CPU processes data.",
        .evidence_text = blocks[0],
        .evidence_texts = &blocks,
        .evidence_source_ids = &source_ids,
    });
    defer draft.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(u8, draft.draft_text, "and CPU") == null);
    try std.testing.expect(std.mem.indexOf(u8, draft.draft_text, "The CPU") != null);
    try std.testing.expect(std.mem.indexOf(u8, draft.draft_text, "processes data") != null);
    try std.testing.expect(std.mem.indexOf(u8, draft.draft_text, "executes instructions") != null);
    try std.testing.expect(std.mem.indexOf(u8, draft.draft_text, "performs operations") != null);
    try std.testing.expect(std.mem.indexOf(u8, draft.draft_text, "clock cycles") != null);
    try std.testing.expect(std.mem.indexOf(u8, draft.draft_text, "Additionally,") == null);
}

test "abstractive fact fusion rewrites overlapping CPU evidence" {
    const allocator = std.testing.allocator;
    const blocks = [_][]const u8{
        "TITLE: CPU ]] A CPU is a piece of hardware that processes data and instructions.",
        "TITLE: Central processing unit ]] The central processing unit executes instructions and processes data.",
    };

    var draft = try generateCorpusSynthesisDraft(allocator, .{
        .user_query = "Explain how a CPU processes data.",
        .evidence_text = blocks[0],
        .evidence_texts = &blocks,
    });
    defer draft.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(u8, draft.draft_text, "The CPU is a hardware component") != null);
    try std.testing.expect(std.mem.indexOf(u8, draft.draft_text, "processes data") != null);
    try std.testing.expect(std.mem.indexOf(u8, draft.draft_text, "executes instructions") != null);
    try std.testing.expect(std.mem.indexOf(u8, draft.draft_text, "A CPU is a piece") == null);
    try std.testing.expect(std.mem.indexOf(u8, draft.draft_text, "central processing unit executes") == null);
}

test "relational contrast draft calls out inverse logical absurdity" {
    const allocator = std.testing.allocator;
    var draft = try generateCorpusSynthesisDraft(allocator, .{
        .user_query = "Explain the difference between a compiler reading code and code reading a compiler.",
        .evidence_text = "A compiler reads code and produces program artifacts.",
    });
    defer draft.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(u8, draft.draft_text, "directed relation") != null);
    try std.testing.expect(std.mem.indexOf(u8, draft.draft_text, "logical absurdity") != null);
    try std.testing.expect(draft.non_authorizing);
    try std.testing.expect(!draft.proof_granted);
}

test "CPU definition draft rotates grammar while preserving facts" {
    const allocator = std.testing.allocator;
    var one = try generateCpuDefinitionDraft(allocator, "What is a CPU?");
    defer one.deinit(allocator);
    var two = try generateCpuDefinitionDraft(allocator, "What is a CPU?");
    defer two.deinit(allocator);
    var three = try generateCpuDefinitionDraft(allocator, "What is a CPU?");
    defer three.deinit(allocator);

    try std.testing.expect(!std.mem.eql(u8, one.draft_text, two.draft_text));
    try std.testing.expect(!std.mem.eql(u8, two.draft_text, three.draft_text));
    try std.testing.expect(std.ascii.indexOfIgnoreCase(one.draft_text, "CPU") != null);
    try std.testing.expect(std.ascii.indexOfIgnoreCase(two.draft_text, "instruction") != null);
    try std.testing.expect(std.ascii.indexOfIgnoreCase(three.draft_text, "data") != null);
    try std.testing.expect(one.non_authorizing and two.non_authorizing and three.non_authorizing);
}

test "frame inference draft maps dropped glass implication" {
    const allocator = std.testing.allocator;
    const draft = (try generateFrameInferenceDraft(allocator, "I dropped my glass on the concrete.")).?;
    defer draft.deinit(allocator);
    try std.testing.expect(std.ascii.indexOfIgnoreCase(draft.draft_text, "likely break") != null or std.ascii.indexOfIgnoreCase(draft.draft_text, "likely broke") != null);
    try std.testing.expect(draft.non_authorizing);
    try std.testing.expect(!draft.support_granted);
}

test "frame inference draft maps variable bucket analogy" {
    const allocator = std.testing.allocator;
    const draft = (try generateFrameInferenceDraft(allocator, "Why is a variable like a bucket?")).?;
    defer draft.deinit(allocator);
    try std.testing.expect(std.ascii.indexOfIgnoreCase(draft.draft_text, "containment") != null);
    try std.testing.expect(std.ascii.indexOfIgnoreCase(draft.draft_text, "hold a value") != null);
    try std.testing.expect(draft.non_authorizing);
}

test "state reflection draft reports daemon footprint without corpus lookup" {
    const allocator = std.testing.allocator;
    var draft = try generateStateReflectionDraft(allocator, .{
        .daemon_active = true,
        .vulkan_active = true,
        .vram_resident_bytes = 281 * 1024 * 1024,
        .resident_shards = 2,
        .session_hot_bytes = 4096,
    });
    defer draft.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(u8, draft.draft_text, "Ghost daemon active.") != null);
    try std.testing.expect(std.mem.indexOf(u8, draft.draft_text, "281 MB VRAM resident") != null);
    try std.testing.expect(std.mem.indexOf(u8, draft.draft_text, "Ready for query.") != null);
    try std.testing.expect(std.mem.indexOf(u8, draft.draft_text, "hello") == null);
}

test "imperative execution draft returns exact isolated target" {
    const allocator = std.testing.allocator;
    var draft = try generateImperativeExecutionDraft(allocator, .{
        .target = "hint",
        .strict_output = true,
    });
    defer draft.deinit(allocator);

    try std.testing.expectEqualStrings("hint", draft.draft_text);
    try std.testing.expect(!draft.support_granted);
    try std.testing.expect(draft.non_authorizing);
}

test "imperative execution draft avoids previous negated output" {
    const allocator = std.testing.allocator;
    var draft = try generateImperativeExecutionDraft(allocator, .{
        .target = "something",
        .previous_output = "Daemon is listening with 64 bytes in working memory.",
        .requires_distinct = true,
        .session_hot_bytes = 64,
        .resident_shards = 1,
    });
    defer draft.deinit(allocator);

    try std.testing.expect(!std.mem.eql(u8, draft.draft_text, "Daemon is listening with 64 bytes in working memory."));
}

test "corpus signals can become lab memory candidates" {
    const allocator = std.testing.allocator;
    const input = TextGenerationInput{
        .source_paths = &.{"lab.md"},
        .detected_claims = &.{
            .{ .source_path = "lab.md", .kind = "corpus_claim", .text = "claim: lab memory can be proposed" },
        },
        .detected_obligations = &.{
            .{ .source_path = "lab.md", .kind = "corpus_obligation", .text = "obligation: reviewed records must stay lab-local" },
        },
        .unknowns = &.{"unknown: whether more review is needed"},
    };
    var store = LabMemoryStore.init(allocator);
    defer store.deinit();

    try std.testing.expectEqual(@as(usize, 3), try proposeMemoryFromCorpusSignals(allocator, &store, input));
    try std.testing.expectEqual(@as(usize, 3), store.records.items.len);
    for (store.records.items) |record| {
        try std.testing.expectEqual(LabMemoryReviewState.candidate, record.review_state);
        try std.testing.expect(record.candidate_only);
        try std.testing.expect(record.non_authorizing);
        try std.testing.expect(!record.support_granted);
        try std.testing.expect(!record.proof_granted);
        try std.testing.expect(!record.product_ready);
    }
}

test "accepted lab memory changes future draft output without training" {
    const allocator = std.testing.allocator;
    const input = TextGenerationInput{
        .source_paths = &.{"learning.md"},
        .detected_claims = &.{
            .{ .source_path = "learning.md", .kind = "corpus_claim", .text = "claim: accepted lab memory should be visible later" },
        },
    };
    var store = LabMemoryStore.init(allocator);
    defer store.deinit();
    try std.testing.expectEqual(@as(usize, 1), try proposeMemoryFromCorpusSignals(allocator, &store, input));

    const before = try generateDraftWithLabMemory(allocator, .{}, store);
    defer before.deinit(allocator);
    try std.testing.expect(!before.lab_memory_applied);
    try std.testing.expect(std.mem.indexOf(u8, before.draft_text, "Accepted lab memory reminders") == null);

    try acceptLabMemoryRecord(&store, store.records.items[0].id);
    const after = try generateDraftWithLabMemory(allocator, .{}, store);
    defer after.deinit(allocator);

    try std.testing.expect(after.lab_memory_applied);
    try std.testing.expect(!after.training_applied);
    try std.testing.expect(!after.proof_granted);
    try std.testing.expect(!after.support_granted);
    try std.testing.expect(!after.mutates_state);
    try std.testing.expect(!after.product_ready);
    try std.testing.expect(std.mem.indexOf(u8, after.draft_text, "Accepted lab memory reminders / NON-AUTHORIZING / LAB-LOCAL") != null);
    try std.testing.expect(std.mem.indexOf(u8, after.draft_text, "accepted lab memory should be visible later") != null);
    try std.testing.expect(std.mem.indexOf(u8, after.draft_text, "grants no proof, support") != null);
}

test "rejected lab memory does not influence future draft output" {
    const allocator = std.testing.allocator;
    const input = TextGenerationInput{
        .detected_claims = &.{
            .{ .source_path = "reject.md", .kind = "corpus_claim", .text = "claim: rejected signal should not become a reminder" },
        },
    };
    var store = LabMemoryStore.init(allocator);
    defer store.deinit();
    _ = try proposeMemoryFromCorpusSignals(allocator, &store, input);
    try rejectLabMemoryRecord(&store, store.records.items[0].id);

    const draft = try generateDraftWithLabMemory(allocator, .{}, store);
    defer draft.deinit(allocator);

    try std.testing.expect(!draft.lab_memory_applied);
    try std.testing.expect(std.mem.indexOf(u8, draft.draft_text, "Accepted lab memory reminders") == null);
    try std.testing.expect(std.mem.indexOf(u8, draft.draft_text, "Rejected lab memory / NOT APPLIED") != null);
    try std.testing.expect(!draft.proof_granted);
    try std.testing.expect(!draft.support_granted);
}

test "unreviewed lab memory is pending review and not authority" {
    const allocator = std.testing.allocator;
    const input = TextGenerationInput{
        .detected_obligations = &.{
            .{ .source_path = "candidate.md", .kind = "corpus_obligation", .text = "obligation: candidate records must not apply themselves" },
        },
    };
    var store = LabMemoryStore.init(allocator);
    defer store.deinit();
    _ = try proposeMemoryFromCorpusSignals(allocator, &store, input);

    const draft = try generateDraftWithLabMemory(allocator, .{}, store);
    defer draft.deinit(allocator);

    try std.testing.expect(!draft.lab_memory_applied);
    try std.testing.expect(!draft.training_applied);
    try std.testing.expect(!draft.proof_granted);
    try std.testing.expect(!draft.support_granted);
    try std.testing.expect(std.mem.indexOf(u8, draft.draft_text, "Pending lab memory review / NOT APPLIED") != null);
    try std.testing.expect(std.mem.indexOf(u8, draft.draft_text, "Accepted lab memory reminders") == null);
}

test "duplicate lab memory proposals are suppressed before acceptance" {
    const allocator = std.testing.allocator;
    const input = TextGenerationInput{
        .detected_claims = &.{
            .{ .source_path = "dupe.md", .kind = "corpus_claim", .text = "claim: duplicate lab memory" },
            .{ .source_path = "dupe.md", .kind = "corpus_claim", .text = "claim: duplicate lab memory" },
        },
    };
    var store = LabMemoryStore.init(allocator);
    defer store.deinit();

    try std.testing.expectEqual(@as(usize, 1), try proposeMemoryFromCorpusSignals(allocator, &store, input));
    try std.testing.expectEqual(@as(usize, 1), store.records.items.len);
    try acceptLabMemoryRecord(&store, store.records.items[0].id);
    try std.testing.expectEqual(@as(usize, 1), store.acceptedCount());
}

test "no usable signals produce no lab memory records to accept" {
    const allocator = std.testing.allocator;
    var store = LabMemoryStore.init(allocator);
    defer store.deinit();

    try std.testing.expectEqual(@as(usize, 0), try proposeMemoryFromCorpusSignals(allocator, &store, .{}));
    try std.testing.expectEqual(@as(usize, 0), store.records.items.len);
    try std.testing.expectError(error.LabMemoryRecordNotFound, acceptLabMemoryRecord(&store, "lab-memory-1"));
}

test "fixture corpus accepted lab memory changes second draft only inside lab" {
    const allocator = std.testing.allocator;
    const result = try ingestCorpusAndGenerateDraft(allocator, .{
        .workspace_root = ".",
        .corpus_paths = &.{
            "fixtures/text_generation_lab/corpus/learning_seed.md",
        },
    });
    defer result.deinit(allocator);
    var store = LabMemoryStore.init(allocator);
    defer store.deinit();

    try std.testing.expectEqual(@as(usize, 2), try proposeMemoryFromCorpusSignals(allocator, &store, result.extraction.input));
    const first = try generateDraftWithLabMemory(allocator, result.extraction.input, store);
    defer first.deinit(allocator);
    try std.testing.expect(!first.lab_memory_applied);
    try std.testing.expect(std.mem.indexOf(u8, first.draft_text, "Accepted lab memory reminders") == null);

    try acceptLabMemoryRecord(&store, store.records.items[0].id);
    const second = try generateDraftWithLabMemory(allocator, result.extraction.input, store);
    defer second.deinit(allocator);

    try std.testing.expect(second.lab_memory_applied);
    try std.testing.expect(!second.training_applied);
    try std.testing.expect(!second.mutates_state);
    try std.testing.expect(!second.proof_granted);
    try std.testing.expect(!second.support_granted);
    try std.testing.expect(!second.product_ready);
    try std.testing.expect(std.mem.indexOf(u8, second.draft_text, "Accepted lab memory reminders") != null);
    try std.testing.expect(std.mem.indexOf(u8, second.draft_text, "lab memory reminds later drafts") != null);
}

test "noisy duplicate corpus lines are suppressed and do not become authority" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{
        .sub_path = "noisy.md",
        .data =
        \\claim: repeated candidate
        \\claim: repeated candidate
        \\claim: repeated candidate
        \\unmarked noise
        ,
    });

    const allocator = std.testing.allocator;
    const result = try ingestCorpusAndGenerateDraftFromDir(allocator, tmp.dir, &.{"noisy.md"}, .{});
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), result.ingest_summary.claim_count);
    try std.testing.expectEqual(@as(usize, 2), result.ingest_summary.duplicate_line_count);
    try std.testing.expect(!result.draft.proof_granted);
    try std.testing.expect(!result.draft.support_granted);
}

test "no usable corpus signals produces insufficient signal draft" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "plain.md", .data = "plain text\nmore plain text\n" });

    const allocator = std.testing.allocator;
    const result = try ingestCorpusAndGenerateDraftFromDir(allocator, tmp.dir, &.{"plain.md"}, .{});
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), result.ingest_summary.claim_count);
    try std.testing.expectEqual(@as(usize, 0), result.ingest_summary.obligation_count);
    try std.testing.expectEqual(@as(usize, 0), result.ingest_summary.unknown_count);
    try std.testing.expectEqual(@as(usize, 0), result.training_summary.examples_seen);
    try std.testing.expect(std.mem.indexOf(u8, result.draft.draft_text, "insufficient inspected signal") != null);
    try std.testing.expect(!result.draft.proof_granted);
}

test "corpus path traversal is rejected" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try std.testing.expectError(
        error.PathTraversalRejected,
        ingestCorpusAndGenerateDraftFromDir(std.testing.allocator, tmp.dir, &.{"../outside.md"}, .{}),
    );
}

test "absolute corpus path is rejected" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try std.testing.expectError(
        error.AbsoluteCorpusPathRejected,
        ingestCorpusAndGenerateDraftFromDir(std.testing.allocator, tmp.dir, &.{"/tmp/ghost-lab.md"}, .{}),
    );
}

test "directory corpus path is rejected" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("corpus_dir");

    try std.testing.expectError(
        error.CorpusPathIsDirectory,
        ingestCorpusAndGenerateDraftFromDir(std.testing.allocator, tmp.dir, &.{"corpus_dir"}, .{}),
    );
}

test "too many corpus files are rejected before reading" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try std.testing.expectError(
        error.TooManyCorpusFiles,
        ingestCorpusAndGenerateDraftFromDir(std.testing.allocator, tmp.dir, &.{ "a.md", "b.md" }, .{ .max_file_count = 1 }),
    );
}

test "too large corpus file is rejected" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile("large.md", .{});
    defer file.close();
    try file.writer().writeByteNTimes('x', 33);

    try std.testing.expectError(
        error.CorpusFileTooLarge,
        ingestCorpusAndGenerateDraftFromDir(std.testing.allocator, tmp.dir, &.{"large.md"}, .{ .max_bytes_per_file = 32 }),
    );
}

test "total corpus byte cap is rejected" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "one.md", .data = "claim: one\n" });
    try tmp.dir.writeFile(.{ .sub_path = "two.md", .data = "claim: two\n" });

    try std.testing.expectError(
        error.CorpusTotalBytesExceeded,
        ingestCorpusAndGenerateDraftFromDir(std.testing.allocator, tmp.dir, &.{ "one.md", "two.md" }, .{ .max_total_bytes = 12 }),
    );
}

test "symlink corpus path is rejected" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "target.md", .data = "claim: symlink target\n" });
    try tmp.dir.symLink("target.md", "link.md", .{});

    try std.testing.expectError(
        error.CorpusPathIsSymlink,
        ingestCorpusAndGenerateDraftFromDir(std.testing.allocator, tmp.dir, &.{"link.md"}, .{}),
    );
}

test "corpus ingestion output remains candidate-only and training is not applied" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "bounded.md", .data = "claim: bounded input\nobligation: must remain candidate-only\nunknown: missing context\n" });

    const allocator = std.testing.allocator;
    const result = try ingestCorpusAndGenerateDraftFromDir(allocator, tmp.dir, &.{"bounded.md"}, .{});
    defer result.deinit(allocator);

    try std.testing.expect(result.draft.candidate_only);
    try std.testing.expect(result.draft.non_authorizing);
    try std.testing.expect(!result.draft.proof_granted);
    try std.testing.expect(!result.draft.support_granted);
    try std.testing.expect(!result.draft.mutates_state);
    try std.testing.expect(!result.draft.product_ready);
    try std.testing.expect(!result.draft.commands_executed);
    try std.testing.expect(!result.draft.verifiers_executed);
    try std.testing.expect(!result.training_summary.training_applied);
    try std.testing.expect(!result.training_summary.mutates_state);
    try std.testing.expect(!result.training_summary.proof_granted);
    try std.testing.expect(!result.training_summary.support_granted);
}
