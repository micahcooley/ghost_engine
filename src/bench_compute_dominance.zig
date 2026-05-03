const std = @import("std");
const builtin = @import("builtin");
const core = @import("ghost_core");

const config = core.config;
const corpus_ask = core.corpus_ask;
const corpus_ingest = core.corpus_ingest;
const correction_candidates = core.correction_candidates;
const correction_review = core.correction_review;
const learning_status = core.learning_status;
const negative_knowledge_review = core.negative_knowledge_review;
const procedure_pack_candidates = core.procedure_pack_candidates;
const rule_reasoning = core.rule_reasoning;
const shards = core.shards;

const REPORT_JSON_REL_PATH = "zig-out/bench/compute_dominance.json";
const REPORT_MD_REL_PATH = "zig-out/bench/compute_dominance.md";

const OperationKind = enum {
    @"corpus.ask",
    @"rule.evaluate",
    @"correction.propose",
    @"correction.reviewed",
    @"negative_knowledge.reviewed",
    @"learning.status",
    @"procedure_pack.candidate",
    @"corpus.lifecycle",
};

const ScenarioResult = struct {
    name: []const u8,
    operation_kind: OperationKind,
    success: bool,
    duration_ns: u64,
    input_bytes: usize = 0,
    corpus_entries_considered: ?usize = null,
    evidence_count: usize = 0,
    similar_candidate_count: usize = 0,
    unknown_count: usize = 0,
    capacity_warning_count: usize = 0,
    correction_candidate_count: usize = 0,
    correction_influence_count: usize = 0,
    learning_candidate_count: usize = 0,
    future_behavior_candidate_count: usize = 0,
    commands_executed: u32 = 0,
    verifiers_executed: u32 = 0,
    corpus_mutation: bool = false,
    pack_mutation: bool = false,
    negative_knowledge_mutation: bool = false,
    answer_draft_present: bool = false,
    non_authorizing: bool = true,
    required_review: ?bool = null,
    local_only: bool = true,
    deterministic_rank_stability: ?bool = null,
    setup_corpus_mutation: bool = false,
};

const SuiteResult = struct {
    allocator: std.mem.Allocator,
    scenarios: []ScenarioResult,
    total_duration_ns: u64,

    fn deinit(self: *SuiteResult) void {
        self.allocator.free(self.scenarios);
        self.* = undefined;
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var suite = try runSuite(allocator);
    defer suite.deinit();

    const json = try renderJsonReport(allocator, suite);
    defer allocator.free(json);
    const md = try renderMarkdownReport(allocator, suite);
    defer allocator.free(md);

    const json_path = try config.getPath(allocator, REPORT_JSON_REL_PATH);
    defer allocator.free(json_path);
    const md_path = try config.getPath(allocator, REPORT_MD_REL_PATH);
    defer allocator.free(md_path);

    try writeAbsoluteFile(allocator, json_path, json);
    try writeAbsoluteFile(allocator, md_path, md);

    std.debug.print("{s}\n", .{md});
    if (!allScenariosPassed(suite.scenarios)) return error.ComputeDominanceBenchmarkFailures;
}

pub fn runSuite(allocator: std.mem.Allocator) !SuiteResult {
    const started = std.time.nanoTimestamp();
    var results = std.ArrayList(ScenarioResult).init(allocator);
    errdefer results.deinit();

    try results.append(try runCorpusNoCorpus(allocator));
    try results.append(try runCorpusExactPhrase(allocator));
    try results.append(try runCorpusAcceptedCorrectionInfluence(allocator));
    try results.append(try runCorpusAcceptedNegativeKnowledgeInfluence(allocator));
    try results.append(try runCorpusWeakUnrelated(allocator));
    try results.append(try runCorpusConflicting(allocator));
    try results.append(try runCorpusApproximateOnly(allocator));
    try results.append(try runCorpusCapacityLimited(allocator));
    try results.append(try runCorpusLargerBounded(allocator));
    try results.append(try runRuleSimpleFires(allocator));
    try results.append(try runRuleAcceptedCorrectionInfluence(allocator));
    try results.append(try runRuleAcceptedNegativeKnowledgeInfluence(allocator));
    try results.append(try runRuleNonMatching(allocator));
    try results.append(try runRuleMultipleDeterministic(allocator));
    try results.append(try runRuleMaxFiredRulesCap(allocator));
    try results.append(try runRuleMaxOutputCap(allocator));
    try results.append(try runRuleInvalidOutputRejection(allocator));
    try results.append(runCorrectionWrongAnswer());
    try results.append(runCorrectionMissingEvidence());
    try results.append(runCorrectionRepeatedFailedPattern());
    try results.append(runCorrectionUnderspecified());
    try results.append(try runCorrectionReviewedList(allocator));
    try results.append(try runCorrectionReviewedGet(allocator));
    try results.append(try runCorrectionInfluenceStatusNoFile(allocator));
    try results.append(try runCorrectionInfluenceStatusPopulated(allocator));
    try results.append(try runNegativeKnowledgeReviewAccepted(allocator));
    try results.append(try runNegativeKnowledgeReviewRejected(allocator));
    try results.append(try runNegativeKnowledgeReviewedListGet(allocator));
    try results.append(try runLearningStatusNoFile(allocator));
    try results.append(try runLearningStatusPopulated(allocator));
    try results.append(try runProcedurePackCandidateLifecycle(allocator));
    try results.append(try runLifecycleScenario(allocator));

    return .{
        .allocator = allocator,
        .scenarios = try results.toOwnedSlice(),
        .total_duration_ns = elapsedNs(started),
    };
}

fn runCorpusNoCorpus(allocator: std.mem.Allocator) !ScenarioResult {
    const shard_id = "bench-compute-dominance-no-corpus";
    try cleanProjectShard(allocator, shard_id);
    defer cleanProjectShard(allocator, shard_id) catch {};

    const question = "what is the retention policy";
    const started = std.time.nanoTimestamp();
    var result = try corpus_ask.ask(allocator, .{ .question = question, .project_shard = shard_id });
    defer result.deinit();

    var out = scenarioFromAsk("corpus.ask/no_corpus", question.len, elapsedNs(started), &result);
    out.success = result.status == .unknown and result.unknowns.len > 0 and result.unknowns[0].kind == .no_corpus_available and result.answer_draft == null;
    return out;
}

fn runCorpusExactPhrase(allocator: std.mem.Allocator) !ScenarioResult {
    const shard_id = "bench-compute-dominance-exact";
    try withCorpus(allocator, shard_id, &.{
        .{ .path = "runtime.md", .body = "Retention policy is enabled for event audit logs.\nOperators cite exact local evidence before drafting.\n" },
    });
    defer cleanProjectShard(allocator, shard_id) catch {};

    const question = "is retention policy enabled";
    const started = std.time.nanoTimestamp();
    var result = try corpus_ask.ask(allocator, .{ .question = question, .project_shard = shard_id, .max_snippet_bytes = 96 });
    defer result.deinit();

    var out = scenarioFromAsk("corpus.ask/exact_phrase_match", question.len, elapsedNs(started), &result);
    out.success = result.status == .answered and result.answer_draft != null and result.evidence_used.len == 1 and result.evidence_used[0].matched_phrase != null;
    out.setup_corpus_mutation = true;
    return out;
}

fn runCorpusAcceptedCorrectionInfluence(allocator: std.mem.Allocator) !ScenarioResult {
    const shard_id = "bench-compute-dominance-correction-influence";
    try cleanProjectShard(allocator, shard_id);
    defer cleanProjectShard(allocator, shard_id) catch {};
    try withCorpus(allocator, shard_id, &.{
        .{ .path = "runtime.md", .body = "Retention policy is enabled for event audit logs.\nOperators cite exact local evidence before drafting.\n" },
    });

    var reviewed = try correction_review.reviewAndAppend(allocator, .{
        .project_shard = shard_id,
        .decision = .accepted,
        .reviewer_note = "benchmark accepted repeated bad draft",
        .rejected_reason = null,
        .source_candidate_id = "correction:candidate:bench-influence",
        .correction_candidate_json =
        \\{"id":"correction:candidate:bench-influence","originalOperationKind":"corpus.ask","originalRequestSummary":"is retention policy enabled","disputedOutput":{"kind":"answerDraft","summary":"Retention policy is enabled"},"userCorrection":"that repeated exact answer pattern needs verification","correctionType":"wrong_answer"}
        ,
        .accepted_learning_outputs_json = "[{\"kind\":\"verifier_check_candidate\",\"status\":\"candidate\"}]",
    });
    defer reviewed.deinit();

    const question = "is retention policy enabled";
    const started = std.time.nanoTimestamp();
    var result = try corpus_ask.ask(allocator, .{ .question = question, .project_shard = shard_id, .max_snippet_bytes = 96 });
    defer result.deinit();

    var out = scenarioFromAsk("corpus.ask/accepted_correction_exact_suppression", question.len, elapsedNs(started), &result);
    out.success = result.status == .unknown and result.answer_draft == null and result.evidence_used.len == 1 and result.correction_influences.len == 1 and
        result.future_behavior_candidates.len >= 1 and result.influence_telemetry.answer_suppressed and !result.safety_flags.corpus_mutation and
        !result.safety_flags.pack_mutation and !result.safety_flags.negative_knowledge_mutation and !result.safety_flags.commands_executed and !result.safety_flags.verifiers_executed;
    out.setup_corpus_mutation = true;
    return out;
}

fn runCorpusAcceptedNegativeKnowledgeInfluence(allocator: std.mem.Allocator) !ScenarioResult {
    const shard_id = "bench-compute-dominance-nk-corpus-influence";
    try cleanProjectShard(allocator, shard_id);
    defer cleanProjectShard(allocator, shard_id) catch {};
    try withCorpus(allocator, shard_id, &.{
        .{ .path = "runtime.md", .body = "Retention policy is enabled for event audit logs.\nOperators cite exact local evidence before drafting.\n" },
    });

    var reviewed = try negative_knowledge_review.reviewAndAppend(allocator, .{
        .project_shard = shard_id,
        .decision = .accepted,
        .reviewer_note = "benchmark accepted reviewed NK corpus pattern",
        .rejected_reason = null,
        .source_candidate_id = "nk:candidate:bench-corpus-influence",
        .negative_knowledge_candidate_json =
        \\{"id":"nk:candidate:bench-corpus-influence","operationKind":"corpus.ask","kind":"failed_hypothesis","condition":"Retention policy is enabled","suppression_rule":"Retention policy is enabled","nonAuthorizing":true}
        ,
    });
    defer reviewed.deinit();

    const question = "is retention policy enabled";
    const started = std.time.nanoTimestamp();
    var result = try corpus_ask.ask(allocator, .{ .question = question, .project_shard = shard_id, .max_snippet_bytes = 96 });
    defer result.deinit();

    var out = scenarioFromAsk("corpus.ask/accepted_negative_knowledge_exact_suppression", question.len, elapsedNs(started), &result);
    out.success = result.status == .unknown and result.answer_draft == null and result.evidence_used.len == 1 and
        result.negative_knowledge_influences.len == 1 and result.future_behavior_candidates.len >= 1 and
        result.negative_knowledge_telemetry.answer_suppressed and result.negative_knowledge_telemetry.influences_applied == 1 and
        !result.negative_knowledge_telemetry.mutation_performed and !result.safety_flags.corpus_mutation and !result.safety_flags.pack_mutation and
        !result.safety_flags.negative_knowledge_mutation and !result.safety_flags.commands_executed and !result.safety_flags.verifiers_executed;
    out.correction_influence_count = result.negative_knowledge_influences.len;
    out.setup_corpus_mutation = true;
    return out;
}

fn runCorpusWeakUnrelated(allocator: std.mem.Allocator) !ScenarioResult {
    const shard_id = "bench-compute-dominance-weak";
    try withCorpus(allocator, shard_id, &.{
        .{ .path = "runtime.md", .body = "Retention policy is enabled for event audit logs.\n" },
    });
    defer cleanProjectShard(allocator, shard_id) catch {};

    const question = "database backup window";
    const started = std.time.nanoTimestamp();
    var result = try corpus_ask.ask(allocator, .{ .question = question, .project_shard = shard_id });
    defer result.deinit();

    var out = scenarioFromAsk("corpus.ask/weak_unrelated_evidence", question.len, elapsedNs(started), &result);
    out.success = result.status == .unknown and result.evidence_used.len == 0 and result.answer_draft == null;
    out.setup_corpus_mutation = true;
    return out;
}

fn runCorpusConflicting(allocator: std.mem.Allocator) !ScenarioResult {
    const shard_id = "bench-compute-dominance-conflict";
    try withCorpus(allocator, shard_id, &.{
        .{ .path = "enabled.md", .body = "Retention policy is enabled for event audit logs.\n" },
        .{ .path = "disabled.md", .body = "Retention policy is disabled for event audit logs.\n" },
    });
    defer cleanProjectShard(allocator, shard_id) catch {};

    const question = "is retention policy enabled";
    const started = std.time.nanoTimestamp();
    var result = try corpus_ask.ask(allocator, .{ .question = question, .project_shard = shard_id, .max_results = 2 });
    defer result.deinit();

    var out = scenarioFromAsk("corpus.ask/conflicting_evidence", question.len, elapsedNs(started), &result);
    out.success = result.status == .unknown and result.unknowns.len > 0 and result.unknowns[0].kind == .conflicting_evidence and result.answer_draft == null and result.learning_candidates.len == 1;
    out.setup_corpus_mutation = true;
    return out;
}

fn runCorpusApproximateOnly(allocator: std.mem.Allocator) !ScenarioResult {
    const shard_id = "bench-compute-dominance-approx";
    try withCorpus(allocator, shard_id, &.{
        .{ .path = "a.md", .body = "Frobulator quiescence window requires bounded local recurrence detection for duplicate corpus chunks.\n" },
        .{ .path = "b.md", .body = "Frobulator quiescence window requires bounded local recurrence detection for duplicate corpus chunk review.\n" },
        .{ .path = "c.md", .body = "Shader compilation diagnostics belong to graphics startup logs and runtime driver setup.\n" },
    });
    defer cleanProjectShard(allocator, shard_id) catch {};

    const question = "frobulatr quiescense windos requir boundid lokel recurence detecton duplikate korpus chonks";
    const started = std.time.nanoTimestamp();
    var result = try corpus_ask.ask(allocator, .{ .question = question, .project_shard = shard_id, .max_results = 3 });
    defer result.deinit();

    var out = scenarioFromAsk("corpus.ask/approximate_only_similarity_hint", question.len, elapsedNs(started), &result);
    out.success = result.status == .unknown and result.evidence_used.len == 0 and result.similar_candidates.len >= 2 and result.answer_draft == null and result.similar_candidates[0].non_authorizing;
    out.setup_corpus_mutation = true;
    return out;
}

fn runCorpusCapacityLimited(allocator: std.mem.Allocator) !ScenarioResult {
    const shard_id = "bench-compute-dominance-capacity";
    try withCorpus(allocator, shard_id, &.{
        .{ .path = "a.md", .body = "Alpha recall policy enabled with exact local evidence and bounded snippets for answer drafting.\n" },
        .{ .path = "b.md", .body = "Beta recall policy enabled with exact local evidence and bounded snippets for answer drafting.\n" },
        .{ .path = "c.md", .body = "Gamma recall policy enabled with exact local evidence and bounded snippets for answer drafting.\n" },
    });
    defer cleanProjectShard(allocator, shard_id) catch {};

    const question = "recall policy enabled";
    const started = std.time.nanoTimestamp();
    var result = try corpus_ask.ask(allocator, .{ .question = question, .project_shard = shard_id, .max_results = 2, .max_snippet_bytes = 32 });
    defer result.deinit();

    var out = scenarioFromAsk("corpus.ask/capacity_limited_max_results_and_snippets", question.len, elapsedNs(started), &result);
    out.success = result.status == .answered and result.evidence_used.len == 2 and result.capacity_telemetry.max_results_hit and result.capacity_telemetry.truncated_snippets == 2 and result.unknowns.len > 0;
    out.setup_corpus_mutation = true;
    return out;
}

fn runCorpusLargerBounded(allocator: std.mem.Allocator) !ScenarioResult {
    const shard_id = "bench-compute-dominance-larger";
    try withCorpus(allocator, shard_id, &.{
        .{ .path = "a.md", .body = "Alpha recall policy enabled with exact local evidence and bounded snippets.\n" },
        .{ .path = "b.md", .body = "Beta recall policy enabled with exact local evidence and bounded snippets.\n" },
        .{ .path = "c.md", .body = "Gamma recall policy enabled with exact local evidence and bounded snippets.\n" },
        .{ .path = "d.md", .body = "Delta recall policy enabled with exact local evidence and bounded snippets.\n" },
        .{ .path = "noise.md", .body = "Unrelated shader startup diagnostics are local but not recall policy evidence.\n" },
    });
    defer cleanProjectShard(allocator, shard_id) catch {};

    const question = "recall policy enabled";
    const started = std.time.nanoTimestamp();
    var first = try corpus_ask.ask(allocator, .{ .question = question, .project_shard = shard_id, .max_results = 3, .max_snippet_bytes = 72 });
    defer first.deinit();
    var second = try corpus_ask.ask(allocator, .{ .question = question, .project_shard = shard_id, .max_results = 3, .max_snippet_bytes = 72 });
    defer second.deinit();

    var out = scenarioFromAsk("corpus.ask/larger_bounded_corpus_deterministic_ranking", question.len, elapsedNs(started), &first);
    const stable = sameEvidenceRanking(&first, &second);
    out.success = first.status == .answered and first.evidence_used.len == 3 and first.corpus_entries_considered >= 5 and stable;
    out.deterministic_rank_stability = stable;
    out.setup_corpus_mutation = true;
    return out;
}

fn runRuleSimpleFires(allocator: std.mem.Allocator) !ScenarioResult {
    const facts = [_]rule_reasoning.Fact{.{ .subject = "build", .predicate = "has", .object = "test" }};
    const outputs = [_]rule_reasoning.RuleOutput{.{ .kind = .check_candidate, .id = "check:test", .summary = "run explicit test verifier" }};
    const rules = [_]rule_reasoning.Rule{.{ .id = "rule:test", .name = "test rule", .all = &.{.{ .subject = "build", .predicate = "has", .object = "test" }}, .outputs = &outputs }};
    return runRuleScenario(allocator, "rule.evaluate/simple_rule_fires", &facts, &rules, .{}, true, 1, 1);
}

fn runRuleAcceptedCorrectionInfluence(allocator: std.mem.Allocator) !ScenarioResult {
    const shard_id = "bench-compute-dominance-rule-correction-influence";
    try cleanProjectShard(allocator, shard_id);
    defer cleanProjectShard(allocator, shard_id) catch {};

    var reviewed = try correction_review.reviewAndAppend(allocator, .{
        .project_shard = shard_id,
        .decision = .accepted,
        .reviewer_note = "benchmark accepted repeated bad rule output",
        .rejected_reason = null,
        .source_candidate_id = "correction:candidate:bench-rule-influence",
        .correction_candidate_json =
        \\{"id":"correction:candidate:bench-rule-influence","originalOperationKind":"rule.evaluate","originalRequestSummary":"rule:bench","disputedOutput":{"kind":"rule_candidate","ref":"check:bench","summary":"run explicit test verifier"},"userCorrection":"suppress this exact repeated bad rule output and require explicit review","correctionType":"repeated_failed_pattern"}
        ,
        .accepted_learning_outputs_json = "[{\"kind\":\"verifier_check_candidate\",\"status\":\"candidate\"}]",
    });
    defer reviewed.deinit();

    const facts = [_]rule_reasoning.Fact{.{ .subject = "build", .predicate = "has", .object = "test" }};
    const outputs = [_]rule_reasoning.RuleOutput{.{ .kind = .check_candidate, .id = "check:bench", .summary = "run explicit test verifier" }};
    const rules = [_]rule_reasoning.Rule{.{ .id = "rule:bench", .name = "bench rule", .all = &.{.{ .subject = "build", .predicate = "has", .object = "test" }}, .outputs = &outputs }};

    var read = try correction_review.readAcceptedInfluences(allocator, shard_id);
    defer read.deinit();
    const started = std.time.nanoTimestamp();
    var result = try rule_reasoning.evaluate(allocator, .{ .facts = &facts, .rules = &rules, .project_shard = shard_id });
    defer result.deinit();
    try rule_reasoning.applyAcceptedCorrectionInfluence(allocator, &result, &read);

    var out = scenarioFromRule("rule.evaluate/accepted_correction_exact_suppression", estimateRuleInputBytes(&facts, &rules), elapsedNs(started), &result);
    out.success = result.fired_rules.len == 1 and result.outputs_emitted == 0 and result.correction_influences.len == 1 and
        result.future_behavior_candidates.len >= 1 and result.influence_telemetry.outputs_suppressed == 1 and
        !result.influence_telemetry.mutation_performed and !result.safety_flags.corpus_mutation and !result.safety_flags.pack_mutation and
        !result.safety_flags.negative_knowledge_mutation and !result.safety_flags.commands_executed and !result.safety_flags.verifiers_executed;
    return out;
}

fn runRuleAcceptedNegativeKnowledgeInfluence(allocator: std.mem.Allocator) !ScenarioResult {
    const shard_id = "bench-compute-dominance-rule-nk-influence";
    try cleanProjectShard(allocator, shard_id);
    defer cleanProjectShard(allocator, shard_id) catch {};

    var reviewed = try negative_knowledge_review.reviewAndAppend(allocator, .{
        .project_shard = shard_id,
        .decision = .accepted,
        .reviewer_note = "benchmark accepted reviewed NK rule output",
        .rejected_reason = null,
        .source_candidate_id = "nk:candidate:bench-rule-influence",
        .negative_knowledge_candidate_json =
        \\{"id":"nk:candidate:bench-rule-influence","operationKind":"rule.evaluate","kind":"overbroad_rule","condition":"run explicit test verifier","matchedOutputId":"check:nk-bench","ruleUpdateCandidate":"tighten the rule","nonAuthorizing":true}
        ,
    });
    defer reviewed.deinit();

    const facts = [_]rule_reasoning.Fact{.{ .subject = "build", .predicate = "has", .object = "test" }};
    const outputs = [_]rule_reasoning.RuleOutput{.{ .kind = .check_candidate, .id = "check:nk-bench", .summary = "run explicit test verifier" }};
    const rules = [_]rule_reasoning.Rule{.{ .id = "rule:nk-bench", .name = "bench nk rule", .all = &.{.{ .subject = "build", .predicate = "has", .object = "test" }}, .outputs = &outputs }};

    var read = try negative_knowledge_review.readAcceptedInfluences(allocator, shard_id);
    defer read.deinit();
    const started = std.time.nanoTimestamp();
    var result = try rule_reasoning.evaluate(allocator, .{ .facts = &facts, .rules = &rules, .project_shard = shard_id });
    defer result.deinit();
    try rule_reasoning.applyAcceptedNegativeKnowledgeInfluence(allocator, &result, &read);

    var out = scenarioFromRule("rule.evaluate/accepted_negative_knowledge_rule_update_candidate", estimateRuleInputBytes(&facts, &rules), elapsedNs(started), &result);
    out.success = result.fired_rules.len == 1 and result.outputs_emitted == 1 and result.negative_knowledge_influences.len == 1 and
        result.future_behavior_candidates.len >= 1 and result.negative_knowledge_telemetry.influences_applied == 1 and
        result.negative_knowledge_telemetry.outputs_suppressed == 0 and !result.negative_knowledge_telemetry.mutation_performed and
        !result.safety_flags.corpus_mutation and !result.safety_flags.pack_mutation and !result.safety_flags.negative_knowledge_mutation and
        !result.safety_flags.commands_executed and !result.safety_flags.verifiers_executed;
    out.correction_influence_count = result.negative_knowledge_influences.len;
    return out;
}

fn runRuleNonMatching(allocator: std.mem.Allocator) !ScenarioResult {
    const facts = [_]rule_reasoning.Fact{.{ .subject = "build", .predicate = "has", .object = "lint" }};
    const outputs = [_]rule_reasoning.RuleOutput{.{ .kind = .check_candidate, .id = "check:test", .summary = "run explicit test verifier" }};
    const rules = [_]rule_reasoning.Rule{.{ .id = "rule:test", .name = "test rule", .all = &.{.{ .subject = "build", .predicate = "has", .object = "test" }}, .outputs = &outputs }};
    return runRuleScenario(allocator, "rule.evaluate/non_matching_rule", &facts, &rules, .{}, true, 0, 0);
}

fn runRuleMultipleDeterministic(allocator: std.mem.Allocator) !ScenarioResult {
    const facts = [_]rule_reasoning.Fact{
        .{ .subject = "build", .predicate = "has", .object = "test" },
        .{ .subject = "runtime", .predicate = "has", .object = "oracle" },
    };
    const out_a = [_]rule_reasoning.RuleOutput{.{ .kind = .check_candidate, .id = "check:test", .summary = "run explicit test verifier" }};
    const out_b = [_]rule_reasoning.RuleOutput{.{ .kind = .evidence_expectation, .id = "evidence:oracle", .summary = "cite runtime oracle output" }};
    const rules = [_]rule_reasoning.Rule{
        .{ .id = "rule:a", .name = "test rule", .all = &.{.{ .subject = "build", .predicate = "has", .object = "test" }}, .outputs = &out_a },
        .{ .id = "rule:b", .name = "oracle rule", .all = &.{.{ .subject = "runtime", .predicate = "has", .object = "oracle" }}, .outputs = &out_b },
    };
    return runRuleScenario(allocator, "rule.evaluate/multiple_deterministic_rules", &facts, &rules, .{}, true, 2, 2);
}

fn runRuleMaxFiredRulesCap(allocator: std.mem.Allocator) !ScenarioResult {
    const facts = [_]rule_reasoning.Fact{.{ .subject = "build", .predicate = "has", .object = "test" }};
    const out_a = [_]rule_reasoning.RuleOutput{.{ .kind = .check_candidate, .id = "check:a", .summary = "candidate a" }};
    const out_b = [_]rule_reasoning.RuleOutput{.{ .kind = .check_candidate, .id = "check:b", .summary = "candidate b" }};
    const rules = [_]rule_reasoning.Rule{
        .{ .id = "rule:a", .name = "rule a", .all = &.{.{ .subject = "build", .predicate = "has", .object = "test" }}, .outputs = &out_a },
        .{ .id = "rule:b", .name = "rule b", .all = &.{.{ .subject = "build", .predicate = "has", .object = "test" }}, .outputs = &out_b },
    };
    return runRuleScenario(allocator, "rule.evaluate/max_fired_rules_cap", &facts, &rules, .{ .max_fired_rules = 1 }, true, 1, 1);
}

fn runRuleMaxOutputCap(allocator: std.mem.Allocator) !ScenarioResult {
    const facts = [_]rule_reasoning.Fact{.{ .subject = "build", .predicate = "has", .object = "test" }};
    const outputs = [_]rule_reasoning.RuleOutput{
        .{ .kind = .check_candidate, .id = "check:a", .summary = "candidate a" },
        .{ .kind = .unknown, .id = "unknown:a", .summary = "bounded unknown" },
    };
    const rules = [_]rule_reasoning.Rule{.{ .id = "rule:a", .name = "rule a", .all = &.{.{ .subject = "build", .predicate = "has", .object = "test" }}, .outputs = &outputs }};
    return runRuleScenario(allocator, "rule.evaluate/max_output_cap", &facts, &rules, .{ .max_outputs = 1 }, true, 1, 1);
}

fn runRuleInvalidOutputRejection(allocator: std.mem.Allocator) !ScenarioResult {
    const facts = [_]rule_reasoning.Fact{.{ .subject = "build", .predicate = "has", .object = "test" }};
    const outputs = [_]rule_reasoning.RuleOutput{.{ .kind = .fact, .id = "fact:recursive", .summary = "recursive fact output" }};
    const rules = [_]rule_reasoning.Rule{.{ .id = "rule:recursive", .name = "recursive rule", .all = &.{.{ .subject = "build", .predicate = "has", .object = "test" }}, .outputs = &outputs }};
    const input_bytes = estimateRuleInputBytes(&facts, &rules);
    const started = std.time.nanoTimestamp();
    const rejected = if (rule_reasoning.evaluate(allocator, .{ .facts = &facts, .rules = &rules })) |result_value| blk: {
        var result = result_value;
        result.deinit();
        break :blk false;
    } else |err| err == error.InvalidRule;
    return .{
        .name = "rule.evaluate/recursive_invalid_output_rejection",
        .operation_kind = .@"rule.evaluate",
        .success = rejected,
        .duration_ns = elapsedNs(started),
        .input_bytes = input_bytes,
        .unknown_count = if (rejected) 1 else 0,
        .non_authorizing = true,
    };
}

fn runRuleScenario(
    allocator: std.mem.Allocator,
    name: []const u8,
    facts: []const rule_reasoning.Fact,
    rules: []const rule_reasoning.Rule,
    limits: rule_reasoning.Limits,
    expect_success: bool,
    expected_fired: usize,
    expected_outputs: usize,
) !ScenarioResult {
    const started = std.time.nanoTimestamp();
    var result = try rule_reasoning.evaluate(allocator, .{ .facts = facts, .rules = rules, .limits = limits });
    defer result.deinit();

    var out = scenarioFromRule(name, estimateRuleInputBytes(facts, rules), elapsedNs(started), &result);
    out.success = expect_success and result.fired_rules.len == expected_fired and result.outputs_emitted == expected_outputs;
    if (std.mem.indexOf(u8, name, "cap") != null) out.success = out.success and result.budget_exhausted;
    return out;
}

fn runCorrectionWrongAnswer() ScenarioResult {
    return runCorrectionScenario("correction.propose/wrong_answer", .{
        .operation_kind = "corpus.ask",
        .disputed_output_kind = .answerDraft,
        .disputed_output_ref = "answer:1",
        .user_correction = "the answer is wrong",
        .correction_type = .wrong_answer,
    }, 3);
}

fn runCorrectionMissingEvidence() ScenarioResult {
    return runCorrectionScenario("correction.propose/missing_evidence", .{
        .operation_kind = "corpus.ask",
        .disputed_output_kind = .unknown,
        .user_correction = "the answer needs a citation",
        .correction_type = .missing_evidence,
    }, 1);
}

fn runCorrectionRepeatedFailedPattern() ScenarioResult {
    return runCorrectionScenario("correction.propose/repeated_failed_pattern", .{
        .operation_kind = "context.autopsy",
        .disputed_output_kind = .unknown,
        .user_correction = "this same missing-context pattern keeps failing",
        .correction_type = .repeated_failed_pattern,
    }, 1);
}

fn runCorrectionUnderspecified() ScenarioResult {
    return runCorrectionScenario("correction.propose/underspecified_correction", .{
        .operation_kind = "rule.evaluate",
        .correction_type = .missing_evidence,
    }, 1);
}

fn runCorrectionScenario(name: []const u8, request: correction_candidates.Request, expected_learning: usize) ScenarioResult {
    const input_bytes = estimateCorrectionInputBytes(request);
    const started = std.time.nanoTimestamp();
    const proposal = correction_candidates.propose(request, 0xfeed_cafe);
    var out = scenarioFromCorrection(name, input_bytes, elapsedNs(started), proposal);
    out.success = proposal.required_review and proposal.non_authorizing and !proposal.treated_as_proof and proposal.learning_outputs.len == expected_learning and
        !proposal.mutation_flags.corpus_mutation and !proposal.mutation_flags.pack_mutation and !proposal.mutation_flags.negative_knowledge_mutation and
        !proposal.mutation_flags.commands_executed and !proposal.mutation_flags.verifiers_executed;
    if (std.mem.indexOf(u8, name, "underspecified") != null) {
        out.success = out.success and std.mem.eql(u8, proposal.status, "request_more_detail") and proposal.candidate_id_hash == null and proposal.unknown_reason != null;
    } else {
        out.success = out.success and std.mem.eql(u8, proposal.status, "proposed") and proposal.candidate_id_hash != null;
        out.correction_candidate_count = 1;
    }
    return out;
}

fn runLifecycleScenario(allocator: std.mem.Allocator) !ScenarioResult {
    const shard_id = "bench-compute-dominance-lifecycle";
    try cleanProjectShard(allocator, shard_id);
    defer cleanProjectShard(allocator, shard_id) catch {};

    const fixture_root = try prepareCorpusFixture(allocator, "lifecycle", &.{
        .{ .path = "verifier-policy.md", .body = "Verifier execution must remain explicit and never run by default.\nCorpus answers draft from cited evidence only.\n" },
    });
    defer allocator.free(fixture_root);
    defer deleteTreeIfExistsAbsolute(fixture_root) catch {};

    var project_metadata = try shards.resolveProjectMetadata(allocator, shard_id);
    defer project_metadata.deinit();
    var project_paths = try shards.resolvePaths(allocator, project_metadata.metadata);
    defer project_paths.deinit();

    const question = "what does the corpus say about verifier execution";
    const input_bytes = question.len + fixture_root.len;
    const started = std.time.nanoTimestamp();
    var stage_result = try corpus_ingest.stage(allocator, .{
        .corpus_path = fixture_root,
        .project_shard = shard_id,
        .trust_class = .project,
        .source_label = "compute-dominance-lifecycle",
    });
    defer stage_result.deinit();
    try corpus_ingest.applyStaged(allocator, &project_paths);

    var ask_result = try corpus_ask.ask(allocator, .{
        .question = question,
        .project_shard = shard_id,
        .max_results = 2,
        .max_snippet_bytes = 96,
    });
    defer ask_result.deinit();

    const proposal = correction_candidates.propose(.{
        .operation_kind = "corpus.ask",
        .disputed_output_kind = .answerDraft,
        .disputed_output_ref = "answer:lifecycle",
        .user_correction = "missing evidence should stay review-required",
        .correction_type = .missing_evidence,
    }, 0x51);

    var out = scenarioFromAsk("end_to_end/lifecycle_ingest_apply_ask_correction_no_hidden_mutation", input_bytes, elapsedNs(started), &ask_result);
    out.operation_kind = .@"corpus.lifecycle";
    out.setup_corpus_mutation = true;
    out.required_review = proposal.required_review;
    out.correction_candidate_count = if (proposal.candidate_id_hash != null) 1 else 0;
    out.learning_candidate_count += proposal.learning_outputs.len;
    out.success = stage_result.staged_items == 1 and ask_result.status == .answered and ask_result.answer_draft != null and ask_result.evidence_used.len == 1 and
        proposal.required_review and proposal.non_authorizing and
        !ask_result.safety_flags.corpus_mutation and !ask_result.safety_flags.pack_mutation and !ask_result.safety_flags.negative_knowledge_mutation and
        !proposal.mutation_flags.corpus_mutation and !proposal.mutation_flags.pack_mutation and !proposal.mutation_flags.negative_knowledge_mutation;
    return out;
}

fn runCorrectionReviewedList(allocator: std.mem.Allocator) !ScenarioResult {
    const shard_id = "bench-compute-dominance-reviewed-list";
    try cleanProjectShard(allocator, shard_id);
    defer cleanProjectShard(allocator, shard_id) catch {};
    const path = try correction_review.reviewedCorrectionsPath(allocator, shard_id);
    defer allocator.free(path);
    const first = try reviewedRecordJson(allocator, shard_id, "bench-reviewed-list-accepted", .accepted, 0);
    defer allocator.free(first);
    const second = try reviewedRecordJson(allocator, shard_id, "bench-reviewed-list-rejected", .rejected, first.len + 1);
    defer allocator.free(second);
    var file = try createReviewedFile(path);
    defer file.close();
    try file.writeAll(first);
    try file.writeAll("\n");
    try file.writeAll(second);
    try file.writeAll("\n");

    const started = std.time.nanoTimestamp();
    var inspected = try correction_review.listReviewedCorrections(allocator, shard_id, .all, null, 8, 0, correction_review.MAX_REVIEWED_CORRECTIONS_READ);
    defer inspected.deinit();

    return .{
        .name = "correction.reviewed.list/read_only_append_order",
        .operation_kind = .@"correction.reviewed",
        .success = inspected.returned_count == 2 and inspected.malformed_lines == 0 and !inspected.max_records_hit and
            std.mem.indexOf(u8, inspected.records[0].record_json, "bench-reviewed-list-accepted") != null and
            std.mem.indexOf(u8, inspected.records[1].record_json, "bench-reviewed-list-rejected") != null,
        .duration_ns = elapsedNs(started),
        .input_bytes = first.len + second.len,
        .correction_candidate_count = inspected.returned_count,
        .capacity_warning_count = if (inspected.limit_hit or inspected.max_records_hit or inspected.truncated) 1 else 0,
        .commands_executed = 0,
        .verifiers_executed = 0,
        .corpus_mutation = false,
        .pack_mutation = false,
        .negative_knowledge_mutation = false,
        .non_authorizing = true,
    };
}

fn runCorrectionReviewedGet(allocator: std.mem.Allocator) !ScenarioResult {
    const shard_id = "bench-compute-dominance-reviewed-get";
    try cleanProjectShard(allocator, shard_id);
    defer cleanProjectShard(allocator, shard_id) catch {};
    const path = try correction_review.reviewedCorrectionsPath(allocator, shard_id);
    defer allocator.free(path);
    const record = try reviewedRecordJson(allocator, shard_id, "bench-reviewed-get", .accepted, 0);
    defer allocator.free(record);
    var file = try createReviewedFile(path);
    defer file.close();
    try file.writeAll("malformed\n");
    try file.writeAll(record);
    try file.writeAll("\n");
    const id = try reviewedRecordId(allocator, record);
    defer allocator.free(id);

    const started = std.time.nanoTimestamp();
    var inspected = try correction_review.getReviewedCorrection(allocator, shard_id, id, correction_review.MAX_REVIEWED_CORRECTIONS_READ);
    defer inspected.deinit();

    return .{
        .name = "correction.reviewed.get/read_only_existing_with_malformed_warning",
        .operation_kind = .@"correction.reviewed",
        .success = inspected.record != null and inspected.malformed_lines == 1 and !inspected.max_records_hit,
        .duration_ns = elapsedNs(started),
        .input_bytes = record.len,
        .correction_candidate_count = if (inspected.record != null) 1 else 0,
        .capacity_warning_count = inspected.warnings.len,
        .commands_executed = 0,
        .verifiers_executed = 0,
        .corpus_mutation = false,
        .pack_mutation = false,
        .negative_knowledge_mutation = false,
        .non_authorizing = true,
    };
}

fn runCorrectionInfluenceStatusNoFile(allocator: std.mem.Allocator) !ScenarioResult {
    const shard_id = "bench-compute-dominance-influence-status-empty";
    try cleanProjectShard(allocator, shard_id);
    defer cleanProjectShard(allocator, shard_id) catch {};

    const started = std.time.nanoTimestamp();
    var status = try correction_review.correctionInfluenceStatus(allocator, shard_id, null, false, 0, correction_review.MAX_REVIEWED_CORRECTIONS_READ);
    defer status.deinit();

    return .{
        .name = "correction.influence.status/no_file_zero_summary",
        .operation_kind = .@"correction.reviewed",
        .success = status.missing_file and status.summary.total_records == 0 and status.summary.accepted_records == 0 and
            status.summary.rejected_records == 0 and status.summary.malformed_lines == 0 and status.records.len == 0 and
            !status.max_records_hit and !status.limit_hit,
        .duration_ns = elapsedNs(started),
        .correction_candidate_count = status.summary.total_records,
        .capacity_warning_count = if (status.max_records_hit or status.truncated) 1 else 0,
        .commands_executed = 0,
        .verifiers_executed = 0,
        .corpus_mutation = false,
        .pack_mutation = false,
        .negative_knowledge_mutation = false,
        .non_authorizing = true,
    };
}

fn runCorrectionInfluenceStatusPopulated(allocator: std.mem.Allocator) !ScenarioResult {
    const shard_id = "bench-compute-dominance-influence-status-populated";
    try cleanProjectShard(allocator, shard_id);
    defer cleanProjectShard(allocator, shard_id) catch {};
    const path = try correction_review.reviewedCorrectionsPath(allocator, shard_id);
    defer allocator.free(path);
    const accepted = try reviewedRecordJson(allocator, shard_id, "bench-status-accepted", .accepted, 0);
    defer allocator.free(accepted);
    const rejected = try reviewedRecordJson(allocator, shard_id, "bench-status-rejected", .rejected, accepted.len + 1);
    defer allocator.free(rejected);
    var file = try createReviewedFile(path);
    defer file.close();
    try file.writeAll(accepted);
    try file.writeAll("\n");
    try file.writeAll(rejected);
    try file.writeAll("\n");

    const started = std.time.nanoTimestamp();
    var status = try correction_review.correctionInfluenceStatus(allocator, shard_id, null, true, 1, correction_review.MAX_REVIEWED_CORRECTIONS_READ);
    defer status.deinit();

    return .{
        .name = "correction.influence.status/accepted_rejected_summary",
        .operation_kind = .@"correction.reviewed",
        .success = status.summary.total_records == 2 and status.summary.accepted_records == 1 and status.summary.rejected_records == 1 and
            status.summary.suppression_candidate_count == 1 and status.summary.verifier_candidate_count == 1 and
            status.summary.future_behavior_candidate_count == 1 and status.records.len == 1 and status.limit_hit and
            !status.max_records_hit and status.summary.malformed_lines == 0,
        .duration_ns = elapsedNs(started),
        .input_bytes = accepted.len + rejected.len,
        .correction_candidate_count = status.summary.total_records,
        .correction_influence_count = status.summary.suppression_candidate_count + status.summary.stronger_evidence_candidate_count +
            status.summary.verifier_candidate_count + status.summary.negative_knowledge_candidate_count + status.summary.corpus_update_candidate_count +
            status.summary.pack_guidance_candidate_count + status.summary.rule_update_candidate_count,
        .future_behavior_candidate_count = status.summary.future_behavior_candidate_count,
        .capacity_warning_count = if (status.limit_hit or status.max_records_hit or status.truncated) 1 else 0,
        .commands_executed = 0,
        .verifiers_executed = 0,
        .corpus_mutation = false,
        .pack_mutation = false,
        .negative_knowledge_mutation = false,
        .non_authorizing = true,
    };
}

fn runNegativeKnowledgeReviewAccepted(allocator: std.mem.Allocator) !ScenarioResult {
    const shard_id = "bench-compute-dominance-nk-review-accepted";
    try cleanProjectShard(allocator, shard_id);
    defer cleanProjectShard(allocator, shard_id) catch {};

    const started = std.time.nanoTimestamp();
    var reviewed = try negative_knowledge_review.reviewAndAppend(allocator, .{
        .project_shard = shard_id,
        .decision = .accepted,
        .reviewer_note = "benchmark accepted reviewed negative knowledge",
        .rejected_reason = null,
        .source_candidate_id = "nk:candidate:bench-accepted",
        .source_correction_review_id = "reviewed-correction:bench",
        .negative_knowledge_candidate_json =
        \\{"id":"nk:candidate:bench-accepted","kind":"failed_hypothesis","condition":"exact repeated bad draft","nonAuthorizing":true}
        ,
    });
    defer reviewed.deinit();

    return .{
        .name = "negative_knowledge.review/accepted_append_only",
        .operation_kind = .@"negative_knowledge.reviewed",
        .success = std.mem.indexOf(u8, reviewed.record_json, "\"reviewDecision\":\"accepted\"") != null and
            std.mem.indexOf(u8, reviewed.record_json, "\"nonAuthorizing\":true") != null and
            std.mem.indexOf(u8, reviewed.record_json, "\"treatedAsProof\":false") != null and
            std.mem.indexOf(u8, reviewed.record_json, "\"usedAsEvidence\":false") != null and
            std.mem.indexOf(u8, reviewed.record_json, "\"globalPromotion\":false") != null,
        .duration_ns = elapsedNs(started),
        .input_bytes = reviewed.record_json.len,
        .future_behavior_candidate_count = 1,
        .commands_executed = 0,
        .verifiers_executed = 0,
        .corpus_mutation = false,
        .pack_mutation = false,
        .negative_knowledge_mutation = true,
        .non_authorizing = true,
        .required_review = false,
    };
}

fn runNegativeKnowledgeReviewRejected(allocator: std.mem.Allocator) !ScenarioResult {
    const shard_id = "bench-compute-dominance-nk-review-rejected";
    try cleanProjectShard(allocator, shard_id);
    defer cleanProjectShard(allocator, shard_id) catch {};

    const started = std.time.nanoTimestamp();
    var reviewed = try negative_knowledge_review.reviewAndAppend(allocator, .{
        .project_shard = shard_id,
        .decision = .rejected,
        .reviewer_note = "benchmark rejected reviewed negative knowledge",
        .rejected_reason = "candidate was too broad",
        .source_candidate_id = "nk:candidate:bench-rejected",
        .negative_knowledge_candidate_json =
        \\{"id":"nk:candidate:bench-rejected","kind":"overbroad_rule","condition":"too broad","nonAuthorizing":true}
        ,
    });
    defer reviewed.deinit();

    return .{
        .name = "negative_knowledge.review/rejected_append_only",
        .operation_kind = .@"negative_knowledge.reviewed",
        .success = std.mem.indexOf(u8, reviewed.record_json, "\"reviewDecision\":\"rejected\"") != null and
            std.mem.indexOf(u8, reviewed.record_json, "\"rejectedReason\":\"candidate was too broad\"") != null and
            std.mem.indexOf(u8, reviewed.record_json, "\"futureInfluenceCandidate\":null") != null,
        .duration_ns = elapsedNs(started),
        .input_bytes = reviewed.record_json.len,
        .commands_executed = 0,
        .verifiers_executed = 0,
        .corpus_mutation = false,
        .pack_mutation = false,
        .negative_knowledge_mutation = true,
        .non_authorizing = true,
        .required_review = false,
    };
}

fn runNegativeKnowledgeReviewedListGet(allocator: std.mem.Allocator) !ScenarioResult {
    const shard_id = "bench-compute-dominance-nk-reviewed-list-get";
    try cleanProjectShard(allocator, shard_id);
    defer cleanProjectShard(allocator, shard_id) catch {};

    var accepted = try negative_knowledge_review.reviewAndAppend(allocator, .{
        .project_shard = shard_id,
        .decision = .accepted,
        .reviewer_note = "benchmark list accepted",
        .rejected_reason = null,
        .source_candidate_id = "nk:candidate:list-accepted",
        .negative_knowledge_candidate_json = "{\"id\":\"nk:candidate:list-accepted\"}",
    });
    defer accepted.deinit();
    var rejected = try negative_knowledge_review.reviewAndAppend(allocator, .{
        .project_shard = shard_id,
        .decision = .rejected,
        .reviewer_note = "benchmark list rejected",
        .rejected_reason = "not accepted",
        .source_candidate_id = "nk:candidate:list-rejected",
        .negative_knowledge_candidate_json = "{\"id\":\"nk:candidate:list-rejected\"}",
    });
    defer rejected.deinit();

    const id = try reviewedNegativeKnowledgeId(allocator, accepted.record_json);
    defer allocator.free(id);

    const started = std.time.nanoTimestamp();
    var listed = try negative_knowledge_review.listReviewedNegativeKnowledge(allocator, shard_id, .all, 8, 0, negative_knowledge_review.MAX_REVIEWED_NEGATIVE_KNOWLEDGE_READ);
    defer listed.deinit();
    var accepted_only = try negative_knowledge_review.listReviewedNegativeKnowledge(allocator, shard_id, .accepted, 8, 0, negative_knowledge_review.MAX_REVIEWED_NEGATIVE_KNOWLEDGE_READ);
    defer accepted_only.deinit();
    var got = try negative_knowledge_review.getReviewedNegativeKnowledge(allocator, shard_id, id, negative_knowledge_review.MAX_REVIEWED_NEGATIVE_KNOWLEDGE_READ);
    defer got.deinit();

    return .{
        .name = "negative_knowledge.reviewed.list_get/read_only_append_order",
        .operation_kind = .@"negative_knowledge.reviewed",
        .success = listed.returned_count == 2 and accepted_only.returned_count == 1 and got.record != null and
            !listed.missing_file and listed.malformed_lines == 0,
        .duration_ns = elapsedNs(started),
        .input_bytes = accepted.record_json.len + rejected.record_json.len,
        .commands_executed = 0,
        .verifiers_executed = 0,
        .corpus_mutation = false,
        .pack_mutation = false,
        .negative_knowledge_mutation = false,
        .non_authorizing = true,
        .required_review = false,
    };
}

fn runLearningStatusNoFile(allocator: std.mem.Allocator) !ScenarioResult {
    const shard_id = "bench-compute-dominance-learning-status-empty";
    try cleanProjectShard(allocator, shard_id);
    defer cleanProjectShard(allocator, shard_id) catch {};

    const started = std.time.nanoTimestamp();
    var status = try learning_status.readStatus(allocator, .{ .project_shard = shard_id });
    defer status.deinit();

    return .{
        .name = "learning.status/no_file_zero_summary",
        .operation_kind = .@"learning.status",
        .success = status.storage.correction_missing_file and status.storage.negative_knowledge_missing_file and
            status.correction_status.summary.total_records == 0 and status.negative_knowledge_summary.reviewed_records == 0 and
            status.records.len == 0 and !status.warning_summary.read_caps_hit and !status.warning_summary.byte_caps_hit,
        .duration_ns = elapsedNs(started),
        .capacity_warning_count = status.warning_summary.capacity_warnings,
        .commands_executed = 0,
        .verifiers_executed = 0,
        .corpus_mutation = false,
        .pack_mutation = false,
        .negative_knowledge_mutation = false,
        .non_authorizing = true,
    };
}

fn runLearningStatusPopulated(allocator: std.mem.Allocator) !ScenarioResult {
    const shard_id = "bench-compute-dominance-learning-status-populated";
    try cleanProjectShard(allocator, shard_id);
    defer cleanProjectShard(allocator, shard_id) catch {};

    var correction_accepted = try correction_review.reviewAndAppend(allocator, .{
        .project_shard = shard_id,
        .decision = .accepted,
        .reviewer_note = "benchmark learning status accepted correction",
        .rejected_reason = null,
        .source_candidate_id = "correction:candidate:bench-learning-status",
        .correction_candidate_json =
        \\{"id":"correction:candidate:bench-learning-status","originalOperationKind":"corpus.ask","disputedOutput":{"kind":"answerDraft","summary":"bad answer"},"userCorrection":"suppress bad answer","correctionType":"wrong_answer"}
        ,
        .accepted_learning_outputs_json = "[{\"kind\":\"verifier_check_candidate\",\"status\":\"candidate\"}]",
    });
    defer correction_accepted.deinit();
    var correction_rejected = try correction_review.reviewAndAppend(allocator, .{
        .project_shard = shard_id,
        .decision = .rejected,
        .reviewer_note = "benchmark learning status rejected correction",
        .rejected_reason = "not valid",
        .source_candidate_id = "correction:candidate:bench-learning-status-rejected",
        .correction_candidate_json =
        \\{"id":"correction:candidate:bench-learning-status-rejected","originalOperationKind":"rule.evaluate","disputedOutput":{"kind":"rule_candidate","summary":"rule"},"userCorrection":"ignore","correctionType":"misleading_rule"}
        ,
        .accepted_learning_outputs_json = "[]",
    });
    defer correction_rejected.deinit();
    var nk_accepted = try negative_knowledge_review.reviewAndAppend(allocator, .{
        .project_shard = shard_id,
        .decision = .accepted,
        .reviewer_note = "benchmark learning status accepted NK",
        .rejected_reason = null,
        .source_candidate_id = "nk:candidate:bench-learning-status",
        .negative_knowledge_candidate_json =
        \\{"id":"nk:candidate:bench-learning-status","operationKind":"rule.evaluate","kind":"overbroad_rule","condition":"bad rule","ruleUpdateCandidate":"tighten","nonAuthorizing":true}
        ,
    });
    defer nk_accepted.deinit();
    var nk_rejected = try negative_knowledge_review.reviewAndAppend(allocator, .{
        .project_shard = shard_id,
        .decision = .rejected,
        .reviewer_note = "benchmark learning status rejected NK",
        .rejected_reason = "not valid",
        .source_candidate_id = "nk:candidate:bench-learning-status-rejected",
        .negative_knowledge_candidate_json = "{\"id\":\"nk:candidate:bench-learning-status-rejected\"}",
    });
    defer nk_rejected.deinit();

    const started = std.time.nanoTimestamp();
    var status = try learning_status.readStatus(allocator, .{ .project_shard = shard_id, .include_records = true, .limit = 2 });
    defer status.deinit();

    return .{
        .name = "learning.status/populated_correction_nk_summary",
        .operation_kind = .@"learning.status",
        .success = status.correction_status.summary.total_records == 2 and status.correction_status.summary.accepted_records == 1 and
            status.correction_status.summary.rejected_records == 1 and status.negative_knowledge_summary.reviewed_records == 2 and
            status.negative_knowledge_summary.accepted_records == 1 and status.negative_knowledge_summary.rejected_records == 1 and
            status.records.len == 2 and status.capacity_telemetry.limit_hit and status.warning_summary.capacity_warnings == 0,
        .duration_ns = elapsedNs(started),
        .input_bytes = correction_accepted.record_json.len + correction_rejected.record_json.len + nk_accepted.record_json.len + nk_rejected.record_json.len,
        .correction_candidate_count = status.correction_status.summary.total_records,
        .correction_influence_count = status.correction_status.summary.suppression_candidate_count + status.negative_knowledge_summary.rule_update_candidate_count,
        .future_behavior_candidate_count = status.correction_status.summary.future_behavior_candidate_count + status.negative_knowledge_summary.future_behavior_candidate_count,
        .capacity_warning_count = status.warning_summary.capacity_warnings,
        .commands_executed = 0,
        .verifiers_executed = 0,
        .corpus_mutation = false,
        .pack_mutation = false,
        .negative_knowledge_mutation = false,
        .non_authorizing = true,
    };
}

fn runProcedurePackCandidateLifecycle(allocator: std.mem.Allocator) !ScenarioResult {
    const shard_id = "bench-compute-dominance-procedure-pack-candidate";
    try cleanProjectShard(allocator, shard_id);
    defer cleanProjectShard(allocator, shard_id) catch {};

    var reviewed_correction = try correction_review.reviewAndAppend(allocator, .{
        .project_shard = shard_id,
        .decision = .accepted,
        .reviewer_note = "benchmark procedure pack source",
        .rejected_reason = null,
        .source_candidate_id = "correction:candidate:procedure-pack",
        .correction_candidate_json =
        \\{"id":"correction:candidate:procedure-pack","originalOperationKind":"corpus.ask","disputedOutput":{"kind":"answerDraft","summary":"bad answer"},"userCorrection":"review the corpus answer before reuse","correctionType":"wrong_answer"}
        ,
        .accepted_learning_outputs_json = "[{\"kind\":\"corpus_review_candidate\",\"status\":\"candidate\"}]",
    });
    defer reviewed_correction.deinit();
    const reviewed_id = try reviewedRecordId(allocator, reviewed_correction.record_json);
    defer allocator.free(reviewed_id);

    const started = std.time.nanoTimestamp();
    var proposal = try procedure_pack_candidates.propose(allocator, .{
        .project_shard = shard_id,
        .source_kind = .reviewed_correction,
        .source_id = reviewed_id,
    });
    defer proposal.deinit();
    var reviewed_candidate = try procedure_pack_candidates.reviewAndAppend(allocator, .{
        .project_shard = shard_id,
        .decision = .accepted,
        .reviewer_note = "benchmark accepted procedure pack candidate",
        .rejected_reason = null,
        .procedure_pack_candidate_json = proposal.candidate_json,
    });
    defer reviewed_candidate.deinit();
    const reviewed_candidate_id = try reviewedRecordId(allocator, reviewed_candidate.record_json);
    defer allocator.free(reviewed_candidate_id);
    var listed = try procedure_pack_candidates.listReviewedCandidates(
        allocator,
        shard_id,
        .all,
        8,
        0,
        procedure_pack_candidates.MAX_REVIEWED_PROCEDURE_PACK_CANDIDATES_READ,
    );
    defer listed.deinit();
    var got = try procedure_pack_candidates.getReviewedCandidate(
        allocator,
        shard_id,
        reviewed_candidate_id,
        procedure_pack_candidates.MAX_REVIEWED_PROCEDURE_PACK_CANDIDATES_READ,
    );
    defer got.deinit();

    return .{
        .name = "procedure_pack.candidate/propose_review_list_get_no_pack_mutation",
        .operation_kind = .@"procedure_pack.candidate",
        .success = !proposal.missing_source and listed.returned_count == 1 and got.record != null and
            std.mem.indexOf(u8, proposal.candidate_json, "\"nonAuthorizing\":true") != null and
            std.mem.indexOf(u8, proposal.candidate_json, "\"treatedAsProof\":false") != null and
            std.mem.indexOf(u8, proposal.candidate_json, "\"executesByDefault\":false") != null and
            std.mem.indexOf(u8, proposal.candidate_json, "\"packMutation\":false") != null and
            std.mem.indexOf(u8, reviewed_candidate.record_json, "\"packMutation\":false") != null,
        .duration_ns = elapsedNs(started),
        .input_bytes = reviewed_correction.record_json.len + proposal.candidate_json.len + reviewed_candidate.record_json.len,
        .correction_candidate_count = 1,
        .future_behavior_candidate_count = 1,
        .commands_executed = 0,
        .verifiers_executed = 0,
        .corpus_mutation = false,
        .pack_mutation = false,
        .negative_knowledge_mutation = false,
        .non_authorizing = true,
        .required_review = false,
    };
}

const CorpusFile = struct {
    path: []const u8,
    body: []const u8,
};

fn withCorpus(allocator: std.mem.Allocator, shard_id: []const u8, files: []const CorpusFile) !void {
    try cleanProjectShard(allocator, shard_id);
    const fixture_root = try prepareCorpusFixture(allocator, shard_id, files);
    defer allocator.free(fixture_root);
    defer deleteTreeIfExistsAbsolute(fixture_root) catch {};

    var project_metadata = try shards.resolveProjectMetadata(allocator, shard_id);
    defer project_metadata.deinit();
    var project_paths = try shards.resolvePaths(allocator, project_metadata.metadata);
    defer project_paths.deinit();

    var stage_result = try corpus_ingest.stage(allocator, .{
        .corpus_path = fixture_root,
        .project_shard = shard_id,
        .trust_class = .project,
        .source_label = "compute-dominance-corpus",
    });
    defer stage_result.deinit();
    try corpus_ingest.applyStaged(allocator, &project_paths);
}

fn prepareCorpusFixture(allocator: std.mem.Allocator, name: []const u8, files: []const CorpusFile) ![]u8 {
    const root = try std.fmt.allocPrint(allocator, "/tmp/ghost_compute_dominance/{s}", .{name});
    errdefer allocator.free(root);
    try deleteTreeIfExistsAbsolute(root);
    try std.fs.cwd().makePath(root);
    for (files) |file| {
        const abs = try std.fs.path.join(allocator, &.{ root, file.path });
        defer allocator.free(abs);
        try ensureParentDirAbsolute(abs);
        const handle = try std.fs.createFileAbsolute(abs, .{ .truncate = true });
        defer handle.close();
        try handle.writeAll(file.body);
    }
    return root;
}

fn cleanProjectShard(allocator: std.mem.Allocator, shard_id: []const u8) !void {
    var project_metadata = try shards.resolveProjectMetadata(allocator, shard_id);
    defer project_metadata.deinit();
    var project_paths = try shards.resolvePaths(allocator, project_metadata.metadata);
    defer project_paths.deinit();
    try deleteTreeIfExistsAbsolute(project_paths.root_abs_path);
}

fn createReviewedFile(path: []const u8) !std.fs.File {
    try ensureParentDirAbsolute(path);
    return std.fs.createFileAbsolute(path, .{ .truncate = true });
}

fn reviewedRecordJson(allocator: std.mem.Allocator, project_shard: []const u8, candidate_id: []const u8, decision: correction_review.Decision, append_offset: u64) ![]u8 {
    const candidate_json = try std.fmt.allocPrint(
        allocator,
        "{{\"id\":\"correction:candidate:{s}\",\"originalOperationKind\":\"corpus.ask\",\"originalRequestSummary\":\"compute dominance reviewed inspection\",\"disputedOutput\":{{\"kind\":\"answerDraft\",\"summary\":\"compute dominance disputed output {s}\"}},\"userCorrection\":\"operator reviewed {s}\",\"correctionType\":\"wrong_answer\"}}",
        .{ candidate_id, candidate_id, candidate_id },
    );
    defer allocator.free(candidate_json);
    return correction_review.renderRecordJson(allocator, .{
        .project_shard = project_shard,
        .decision = decision,
        .reviewer_note = "compute dominance reviewed inspection",
        .rejected_reason = if (decision == .rejected) "not accepted" else null,
        .source_candidate_id = candidate_id,
        .correction_candidate_json = candidate_json,
        .accepted_learning_outputs_json = "[{\"kind\":\"verifier_check_candidate\",\"status\":\"candidate\"}]",
    }, append_offset);
}

fn reviewedRecordId(allocator: std.mem.Allocator, json: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    const obj = if (parsed.value == .object) parsed.value.object else return error.InvalidJson;
    const id_value = obj.get("id") orelse return error.InvalidJson;
    if (id_value != .string) return error.InvalidJson;
    return allocator.dupe(u8, id_value.string);
}

fn reviewedNegativeKnowledgeId(allocator: std.mem.Allocator, json: []const u8) ![]u8 {
    return reviewedRecordId(allocator, json);
}

fn scenarioFromAsk(name: []const u8, input_bytes: usize, duration_ns: u64, result: *const corpus_ask.Result) ScenarioResult {
    return .{
        .name = name,
        .operation_kind = .@"corpus.ask",
        .success = false,
        .duration_ns = duration_ns,
        .input_bytes = input_bytes,
        .corpus_entries_considered = result.corpus_entries_considered,
        .evidence_count = result.evidence_used.len,
        .similar_candidate_count = result.similar_candidates.len,
        .unknown_count = result.unknowns.len,
        .capacity_warning_count = capacityWarningsFromAsk(result.capacity_telemetry),
        .learning_candidate_count = result.learning_candidates.len,
        .correction_influence_count = result.correction_influences.len + result.negative_knowledge_influences.len,
        .future_behavior_candidate_count = result.future_behavior_candidates.len,
        .commands_executed = if (result.safety_flags.commands_executed) 1 else 0,
        .verifiers_executed = if (result.safety_flags.verifiers_executed) 1 else 0,
        .corpus_mutation = result.safety_flags.corpus_mutation,
        .pack_mutation = result.safety_flags.pack_mutation,
        .negative_knowledge_mutation = result.safety_flags.negative_knowledge_mutation,
        .answer_draft_present = result.answer_draft != null,
        .non_authorizing = true,
    };
}

fn scenarioFromRule(name: []const u8, input_bytes: usize, duration_ns: u64, result: *const rule_reasoning.EvaluationResult) ScenarioResult {
    return .{
        .name = name,
        .operation_kind = .@"rule.evaluate",
        .success = false,
        .duration_ns = duration_ns,
        .input_bytes = input_bytes,
        .evidence_count = result.emitted_obligations.len,
        .unknown_count = result.emitted_unknowns.len,
        .capacity_warning_count = capacityWarningsFromRule(result.capacity_telemetry),
        .correction_candidate_count = result.emitted_candidates.len,
        .correction_influence_count = result.correction_influences.len + result.negative_knowledge_influences.len,
        .future_behavior_candidate_count = result.future_behavior_candidates.len,
        .commands_executed = if (result.safety_flags.commands_executed) 1 else 0,
        .verifiers_executed = if (result.safety_flags.verifiers_executed) 1 else 0,
        .corpus_mutation = result.safety_flags.corpus_mutation,
        .pack_mutation = result.safety_flags.pack_mutation,
        .negative_knowledge_mutation = result.safety_flags.negative_knowledge_mutation,
        .non_authorizing = result.non_authorizing,
    };
}

fn scenarioFromCorrection(name: []const u8, input_bytes: usize, duration_ns: u64, proposal: correction_candidates.Proposal) ScenarioResult {
    return .{
        .name = name,
        .operation_kind = .@"correction.propose",
        .success = false,
        .duration_ns = duration_ns,
        .input_bytes = input_bytes,
        .unknown_count = if (proposal.unknown_reason != null) 1 else 0,
        .learning_candidate_count = proposal.learning_outputs.len,
        .commands_executed = if (proposal.mutation_flags.commands_executed) 1 else 0,
        .verifiers_executed = if (proposal.mutation_flags.verifiers_executed) 1 else 0,
        .corpus_mutation = proposal.mutation_flags.corpus_mutation,
        .pack_mutation = proposal.mutation_flags.pack_mutation,
        .negative_knowledge_mutation = proposal.mutation_flags.negative_knowledge_mutation,
        .non_authorizing = proposal.non_authorizing,
        .required_review = proposal.required_review,
    };
}

fn capacityWarningsFromAsk(telemetry: corpus_ask.CapacityTelemetry) usize {
    var count: usize = 0;
    if (telemetry.hasPressure()) count += 1;
    if (telemetry.max_results_hit) count += 1;
    if (telemetry.truncated_snippets != 0) count += telemetry.truncated_snippets;
    if (telemetry.truncated_inputs != 0) count += telemetry.truncated_inputs;
    return count;
}

fn capacityWarningsFromRule(telemetry: rule_reasoning.CapacityTelemetry) usize {
    var count: usize = 0;
    if (telemetry.hasPressure()) count += 1;
    if (telemetry.max_outputs_hit) count += 1;
    if (telemetry.max_fired_rules_hit) count += 1;
    if (telemetry.rejected_outputs != 0) count += telemetry.rejected_outputs;
    return count;
}

fn sameEvidenceRanking(lhs: *const corpus_ask.Result, rhs: *const corpus_ask.Result) bool {
    if (lhs.evidence_used.len != rhs.evidence_used.len) return false;
    for (lhs.evidence_used, 0..) |item, idx| {
        if (item.rank != rhs.evidence_used[idx].rank) return false;
        if (!std.mem.eql(u8, item.source_path, rhs.evidence_used[idx].source_path)) return false;
    }
    return true;
}

fn estimateRuleInputBytes(facts: []const rule_reasoning.Fact, rules: []const rule_reasoning.Rule) usize {
    var total: usize = 0;
    for (facts) |fact| total += fact.subject.len + fact.predicate.len + fact.object.len + fact.source.len;
    for (rules) |rule| {
        total += rule.id.len + rule.name.len;
        for (rule.all) |condition| total += condition.subject.len + condition.predicate.len + if (condition.object) |object| object.len else 0;
        for (rule.any) |condition| total += condition.subject.len + condition.predicate.len + if (condition.object) |object| object.len else 0;
        for (rule.outputs) |output| total += output.id.len + output.summary.len + output.detail.len + output.risk_level.len;
    }
    return total;
}

fn estimateCorrectionInputBytes(request: correction_candidates.Request) usize {
    var total: usize = 0;
    if (request.operation_kind) |value| total += value.len;
    if (request.original_request_id) |value| total += value.len;
    if (request.original_request_summary) |value| total += value.len;
    if (request.disputed_output_ref) |value| total += value.len;
    if (request.disputed_output_summary) |value| total += value.len;
    if (request.user_correction) |value| total += value.len;
    if (request.project_shard) |value| total += value.len;
    for (request.evidence_refs) |value| total += value.len;
    return total;
}

pub fn renderJsonReport(allocator: std.mem.Allocator, suite: SuiteResult) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const writer = out.writer();

    try writer.writeAll("{");
    try writeJsonFieldString(writer, "suite", "ghost_compute_dominance", true);
    try writeJsonFieldString(writer, "os", @tagName(builtin.os.tag), false);
    try writer.print(",\"localOnly\":true,\"networkUsed\":false,\"cloudUsed\":false,\"transformersUsed\":false,\"embeddingsUsed\":false,\"fabricatedBaselines\":false,\"totalScenarios\":{d},\"passedScenarios\":{d},\"failedScenarios\":{d},\"totalDurationNs\":{d}", .{
        suite.scenarios.len,
        passedCount(suite.scenarios),
        suite.scenarios.len - passedCount(suite.scenarios),
        suite.total_duration_ns,
    });
    try writer.writeAll(",\"scenarios\":[");
    for (suite.scenarios, 0..) |scenario, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writer.writeByte('{');
        try writeJsonFieldString(writer, "scenarioName", scenario.name, true);
        try writeJsonFieldString(writer, "operationKind", @tagName(scenario.operation_kind), false);
        try writer.print(",\"success\":{s},\"durationNs\":{d},\"inputBytes\":{d}", .{ boolText(scenario.success), scenario.duration_ns, scenario.input_bytes });
        if (scenario.corpus_entries_considered) |value| {
            try writer.print(",\"corpusEntriesConsidered\":{d}", .{value});
        } else {
            try writer.writeAll(",\"corpusEntriesConsidered\":null");
        }
        try writer.print(",\"evidenceCount\":{d},\"similarCandidateCount\":{d},\"unknownCount\":{d},\"capacityWarningCount\":{d},\"correctionCandidateCount\":{d},\"correctionInfluenceCount\":{d},\"learningCandidateCount\":{d},\"futureBehaviorCandidateCount\":{d}", .{
            scenario.evidence_count,
            scenario.similar_candidate_count,
            scenario.unknown_count,
            scenario.capacity_warning_count,
            scenario.correction_candidate_count,
            scenario.correction_influence_count,
            scenario.learning_candidate_count,
            scenario.future_behavior_candidate_count,
        });
        try writer.print(",\"commandsExecuted\":{d},\"verifiersExecuted\":{d}", .{ scenario.commands_executed, scenario.verifiers_executed });
        try writer.print(",\"corpusMutation\":{s},\"packMutation\":{s},\"negativeKnowledgeMutation\":{s},\"answerDraftPresent\":{s},\"nonAuthorizing\":{s}", .{
            boolText(scenario.corpus_mutation),
            boolText(scenario.pack_mutation),
            boolText(scenario.negative_knowledge_mutation),
            boolText(scenario.answer_draft_present),
            boolText(scenario.non_authorizing),
        });
        if (scenario.required_review) |value| {
            try writer.print(",\"requiredReview\":{s}", .{boolText(value)});
        } else {
            try writer.writeAll(",\"requiredReview\":null");
        }
        try writer.print(",\"localOnly\":{s},\"setupCorpusMutation\":{s}", .{ boolText(scenario.local_only), boolText(scenario.setup_corpus_mutation) });
        if (scenario.deterministic_rank_stability) |value| {
            try writer.print(",\"deterministicRankStability\":{s}", .{boolText(value)});
        }
        try writer.writeByte('}');
    }
    try writer.writeAll("]}");
    return out.toOwnedSlice();
}

pub fn renderMarkdownReport(allocator: std.mem.Allocator, suite: SuiteResult) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const writer = out.writer();

    try writer.writeAll("# Ghost Compute Dominance Benchmark\n\n");
    try writer.print("- scenarios: {d}\n- passed: {d}\n- failed: {d}\n- total duration ns: {d}\n- local only: true\n- cloud/Transformer/embedding baselines: none\n\n", .{
        suite.scenarios.len,
        passedCount(suite.scenarios),
        suite.scenarios.len - passedCount(suite.scenarios),
        suite.total_duration_ns,
    });
    try writer.writeAll("| scenario | kind | ok | duration ns | evidence | similar | unknown | capacity | corrections | influences | learning | future |\n");
    try writer.writeAll("| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |\n");
    for (suite.scenarios) |scenario| {
        try writer.print("| {s} | {s} | {s} | {d} | {d} | {d} | {d} | {d} | {d} | {d} | {d} | {d} |\n", .{
            scenario.name,
            @tagName(scenario.operation_kind),
            if (scenario.success) "yes" else "no",
            scenario.duration_ns,
            scenario.evidence_count,
            scenario.similar_candidate_count,
            scenario.unknown_count,
            scenario.capacity_warning_count,
            scenario.correction_candidate_count,
            scenario.correction_influence_count,
            scenario.learning_candidate_count,
            scenario.future_behavior_candidate_count,
        });
    }
    return out.toOwnedSlice();
}

fn allScenariosPassed(scenarios: []const ScenarioResult) bool {
    for (scenarios) |scenario| if (!scenario.success) return false;
    return true;
}

fn passedCount(scenarios: []const ScenarioResult) usize {
    var count: usize = 0;
    for (scenarios) |scenario| {
        if (scenario.success) count += 1;
    }
    return count;
}

fn elapsedNs(started: i128) u64 {
    const now = std.time.nanoTimestamp();
    return @intCast(@max(now - started, 0));
}

fn boolText(value: bool) []const u8 {
    return if (value) "true" else "false";
}

fn writeAbsoluteFile(allocator: std.mem.Allocator, path: []const u8, body: []const u8) !void {
    try ensureParentDirAbsolute(path);
    const file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(body);
    _ = allocator;
}

fn ensureParentDirAbsolute(path: []const u8) !void {
    const dir = std.fs.path.dirname(path) orelse return;
    try std.fs.cwd().makePath(dir);
}

fn deleteTreeIfExistsAbsolute(path: []const u8) !void {
    std.fs.deleteTreeAbsolute(path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn writeJsonFieldString(writer: anytype, key: []const u8, value: []const u8, first: bool) !void {
    if (!first) try writer.writeByte(',');
    try writeJsonString(writer, key);
    try writer.writeByte(':');
    try writeJsonString(writer, value);
}

fn writeJsonString(writer: anytype, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |c| {
        switch (c) {
            '\\' => try writer.writeAll("\\\\"),
            '"' => try writer.writeAll("\\\""),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try writer.print("\\u{X:0>4}", .{@as(u8, c)});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
    try writer.writeByte('"');
}

test "compute dominance report is generated with required scenarios and safety fields" {
    const allocator = std.testing.allocator;
    var suite = try runSuite(allocator);
    defer suite.deinit();

    try std.testing.expectEqual(@as(usize, 32), suite.scenarios.len);
    try std.testing.expect(allScenariosPassed(suite.scenarios));

    const json = try renderJsonReport(allocator, suite);
    defer allocator.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    try std.testing.expect(std.mem.indexOf(u8, json, "\"suite\":\"ghost_compute_dominance\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"scenarioName\":\"corpus.ask/no_corpus\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"scenarioName\":\"corpus.ask/accepted_correction_exact_suppression\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"scenarioName\":\"corpus.ask/accepted_negative_knowledge_exact_suppression\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"scenarioName\":\"rule.evaluate/accepted_correction_exact_suppression\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"scenarioName\":\"rule.evaluate/accepted_negative_knowledge_rule_update_candidate\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"scenarioName\":\"corpus.ask/larger_bounded_corpus_deterministic_ranking\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"correctionInfluenceCount\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"scenarioName\":\"rule.evaluate/recursive_invalid_output_rejection\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"scenarioName\":\"correction.propose/repeated_failed_pattern\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"scenarioName\":\"correction.reviewed.list/read_only_append_order\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"scenarioName\":\"correction.reviewed.get/read_only_existing_with_malformed_warning\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"scenarioName\":\"correction.influence.status/no_file_zero_summary\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"scenarioName\":\"correction.influence.status/accepted_rejected_summary\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"scenarioName\":\"negative_knowledge.review/accepted_append_only\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"scenarioName\":\"negative_knowledge.review/rejected_append_only\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"scenarioName\":\"negative_knowledge.reviewed.list_get/read_only_append_order\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"scenarioName\":\"learning.status/no_file_zero_summary\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"scenarioName\":\"learning.status/populated_correction_nk_summary\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"scenarioName\":\"procedure_pack.candidate/propose_review_list_get_no_pack_mutation\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"scenarioName\":\"end_to_end/lifecycle_ingest_apply_ask_correction_no_hidden_mutation\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"cloudUsed\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"transformersUsed\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"embeddingsUsed\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"fabricatedBaselines\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"packMutation\":true") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"negativeKnowledgeMutation\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"commandsExecuted\":1") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"verifiersExecuted\":1") == null);
}
