const std = @import("std");
const correction_review = @import("correction_review.zig");
const negative_knowledge_review = @import("negative_knowledge_review.zig");

pub const DEFAULT_MAX_FACTS: usize = 128;
pub const DEFAULT_MAX_RULES: usize = 64;
pub const DEFAULT_MAX_FIRED_RULES: usize = 32;
pub const DEFAULT_MAX_OUTPUTS: usize = 128;

pub const HARD_MAX_FACTS: usize = 512;
pub const HARD_MAX_RULES: usize = 256;
pub const HARD_MAX_FIRED_RULES: usize = 128;
pub const HARD_MAX_OUTPUTS: usize = 512;

pub const Fact = struct {
    subject: []const u8,
    predicate: []const u8,
    object: []const u8,
    source: []const u8 = "request",
};

pub const Condition = struct {
    subject: []const u8,
    predicate: []const u8,
    object: ?[]const u8 = null,
};

pub const OutputKind = enum {
    risk_candidate,
    check_candidate,
    evidence_expectation,
    unknown,
    follow_up_candidate,
    fact,

    pub fn text(self: OutputKind) []const u8 {
        return @tagName(self);
    }
};

pub const RuleOutput = struct {
    kind: OutputKind,
    id: []const u8,
    summary: []const u8,
    detail: []const u8 = "",
    risk_level: []const u8 = "medium",
};

pub const Rule = struct {
    id: []const u8,
    name: []const u8,
    all: []const Condition = &.{},
    any: []const Condition = &.{},
    outputs: []const RuleOutput = &.{},
};

pub const Limits = struct {
    max_facts: usize = DEFAULT_MAX_FACTS,
    max_rules: usize = DEFAULT_MAX_RULES,
    max_fired_rules: usize = DEFAULT_MAX_FIRED_RULES,
    max_outputs: usize = DEFAULT_MAX_OUTPUTS,

    pub fn capped(self: Limits) Limits {
        return .{
            .max_facts = @min(self.max_facts, HARD_MAX_FACTS),
            .max_rules = @min(self.max_rules, HARD_MAX_RULES),
            .max_fired_rules = @min(self.max_fired_rules, HARD_MAX_FIRED_RULES),
            .max_outputs = @min(self.max_outputs, HARD_MAX_OUTPUTS),
        };
    }
};

pub const SafetyFlags = struct {
    commands_executed: bool = false,
    verifiers_executed: bool = false,
    corpus_mutation: bool = false,
    pack_mutation: bool = false,
    negative_knowledge_mutation: bool = false,
    proof_discharged: bool = false,
    support_granted: bool = false,
};

pub const AcceptedCorrectionWarning = struct {
    line_number: usize,
    reason: []u8,

    fn deinit(self: *AcceptedCorrectionWarning, allocator: std.mem.Allocator) void {
        allocator.free(self.reason);
        self.* = undefined;
    }
};

pub const AcceptedNegativeKnowledgeWarning = struct {
    line_number: usize,
    reason: []u8,

    fn deinit(self: *AcceptedNegativeKnowledgeWarning, allocator: std.mem.Allocator) void {
        allocator.free(self.reason);
        self.* = undefined;
    }
};

pub const CorrectionMutationFlags = struct {
    corpus_mutation: bool = false,
    pack_mutation: bool = false,
    negative_knowledge_mutation: bool = false,
    commands_executed: bool = false,
    verifiers_executed: bool = false,
};

pub const CorrectionInfluence = struct {
    id: []u8,
    source_reviewed_correction_id: []u8,
    influence_kind: []u8,
    applies_to: []u8,
    matched_rule_id: ?[]u8 = null,
    matched_output_id: ?[]u8 = null,
    reason: []u8,
    non_authorizing: bool = true,
    treated_as_proof: bool = false,
    global_promotion: bool = false,
    mutation_flags: CorrectionMutationFlags = .{},

    fn deinit(self: *CorrectionInfluence, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.source_reviewed_correction_id);
        allocator.free(self.influence_kind);
        allocator.free(self.applies_to);
        if (self.matched_rule_id) |value| allocator.free(value);
        if (self.matched_output_id) |value| allocator.free(value);
        allocator.free(self.reason);
        self.* = undefined;
    }
};

pub const FutureBehaviorCandidate = struct {
    kind: []u8,
    status: []u8,
    reason: []u8,
    source_reviewed_correction_id: ?[]u8 = null,
    source_reviewed_negative_knowledge_id: ?[]u8 = null,
    candidate_only: bool = true,
    non_authorizing: bool = true,
    treated_as_proof: bool = false,
    used_as_evidence: bool = false,
    global_promotion: bool = false,
    mutation_flags: CorrectionMutationFlags = .{},

    fn deinit(self: *FutureBehaviorCandidate, allocator: std.mem.Allocator) void {
        allocator.free(self.kind);
        allocator.free(self.status);
        allocator.free(self.reason);
        if (self.source_reviewed_correction_id) |value| allocator.free(value);
        if (self.source_reviewed_negative_knowledge_id) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub const NegativeKnowledgeInfluence = struct {
    id: []u8,
    source_reviewed_negative_knowledge_id: []u8,
    influence_kind: []u8,
    applies_to: []u8,
    matched_rule_id: ?[]u8 = null,
    matched_output_id: ?[]u8 = null,
    matched_pattern: []u8,
    reason: []u8,
    non_authorizing: bool = true,
    treated_as_proof: bool = false,
    used_as_evidence: bool = false,
    global_promotion: bool = false,
    mutation_flags: CorrectionMutationFlags = .{},

    fn deinit(self: *NegativeKnowledgeInfluence, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.source_reviewed_negative_knowledge_id);
        allocator.free(self.influence_kind);
        allocator.free(self.applies_to);
        if (self.matched_rule_id) |value| allocator.free(value);
        if (self.matched_output_id) |value| allocator.free(value);
        allocator.free(self.matched_pattern);
        allocator.free(self.reason);
        self.* = undefined;
    }
};

pub const InfluenceTelemetry = struct {
    records_read: usize = 0,
    accepted_records: usize = 0,
    rejected_records: usize = 0,
    malformed_lines: usize = 0,
    warnings: usize = 0,
    influences_loaded: usize = 0,
    influences_applied: usize = 0,
    outputs_suppressed: usize = 0,
    truncated: bool = false,
    same_shard_only: bool = true,
    mutation_performed: bool = false,
    verifiers_executed: bool = false,
    commands_executed: bool = false,
};

pub const NegativeKnowledgeTelemetry = struct {
    records_read: usize = 0,
    accepted_records: usize = 0,
    rejected_records: usize = 0,
    malformed_lines: usize = 0,
    warnings: usize = 0,
    influences_loaded: usize = 0,
    influences_applied: usize = 0,
    outputs_suppressed: usize = 0,
    truncated: bool = false,
    same_shard_only: bool = true,
    mutation_performed: bool = false,
    verifiers_executed: bool = false,
    commands_executed: bool = false,
};

pub const CapacityTelemetry = struct {
    dropped_runes: usize = 0,
    collision_stalls: usize = 0,
    saturated_slots: usize = 0,
    truncated_inputs: usize = 0,
    truncated_snippets: usize = 0,
    skipped_inputs: usize = 0,
    skipped_files: usize = 0,
    budget_hits: usize = 0,
    max_results_hit: bool = false,
    max_outputs_hit: bool = false,
    max_rules_hit: bool = false,
    max_fired_rules_hit: bool = false,
    max_facts_hit: bool = false,
    rejected_outputs: usize = 0,
    unknowns_created: usize = 0,
    expansion_recommended: bool = false,
    spillover_recommended: bool = false,

    pub fn hasPressure(self: CapacityTelemetry) bool {
        return self.budget_hits != 0 or
            self.max_outputs_hit or
            self.max_rules_hit or
            self.max_fired_rules_hit or
            self.max_facts_hit or
            self.rejected_outputs != 0;
    }
};

pub const FiredRule = struct {
    id: []const u8,
    name: []const u8,
    matched_all: usize,
    matched_any: bool,
};

pub const EmittedOutput = struct {
    kind: OutputKind,
    id: []const u8,
    rule_id: []const u8,
    summary: []const u8,
    detail: []const u8,
    risk_level: []const u8,
    candidate_only: bool = true,
    non_authorizing: bool = true,
    executes_by_default: bool = false,
    status: []const u8 = "pending",
    executed: bool = false,
    treated_as_proof: bool = false,
};

pub const ExplanationTrace = struct {
    rule_id: []const u8,
    rule_name: []const u8,
    fired: bool,
    matched_all: usize,
    required_all: usize,
    matched_any: bool,
    required_any: usize,
    reason: []const u8,
};

pub const EvaluationResult = struct {
    allocator: std.mem.Allocator,
    fired_rules: []FiredRule,
    emitted_candidates: []EmittedOutput,
    emitted_obligations: []EmittedOutput,
    emitted_unknowns: []EmittedOutput,
    explanation_trace: []ExplanationTrace,
    limits: Limits,
    facts_considered: usize,
    rules_considered: usize,
    outputs_emitted: usize,
    budget_exhausted: bool = false,
    non_authorizing: bool = true,
    safety_flags: SafetyFlags = .{},
    capacity_telemetry: CapacityTelemetry = .{},
    accepted_correction_warnings: []AcceptedCorrectionWarning = &.{},
    correction_influences: []CorrectionInfluence = &.{},
    accepted_negative_knowledge_warnings: []AcceptedNegativeKnowledgeWarning = &.{},
    negative_knowledge_influences: []NegativeKnowledgeInfluence = &.{},
    future_behavior_candidates: []FutureBehaviorCandidate = &.{},
    influence_telemetry: InfluenceTelemetry = .{},
    negative_knowledge_telemetry: NegativeKnowledgeTelemetry = .{},

    pub fn deinit(self: *EvaluationResult) void {
        self.allocator.free(self.fired_rules);
        self.allocator.free(self.emitted_candidates);
        self.allocator.free(self.emitted_obligations);
        self.allocator.free(self.emitted_unknowns);
        self.allocator.free(self.explanation_trace);
        for (self.accepted_correction_warnings) |*item| item.deinit(self.allocator);
        self.allocator.free(self.accepted_correction_warnings);
        for (self.correction_influences) |*item| item.deinit(self.allocator);
        self.allocator.free(self.correction_influences);
        for (self.accepted_negative_knowledge_warnings) |*item| item.deinit(self.allocator);
        self.allocator.free(self.accepted_negative_knowledge_warnings);
        for (self.negative_knowledge_influences) |*item| item.deinit(self.allocator);
        self.allocator.free(self.negative_knowledge_influences);
        for (self.future_behavior_candidates) |*item| item.deinit(self.allocator);
        self.allocator.free(self.future_behavior_candidates);
        self.* = undefined;
    }
};

pub const Request = struct {
    facts: []const Fact,
    rules: []const Rule,
    limits: Limits = .{},
    project_shard: ?[]const u8 = null,
};

pub const Error = error{
    InvalidRule,
    FactLimitExceeded,
    RuleLimitExceeded,
};

pub fn validateRule(rule: Rule) Error!void {
    if (rule.id.len == 0 or rule.name.len == 0) return error.InvalidRule;
    if (rule.all.len == 0 and rule.any.len == 0) return error.InvalidRule;
    if (rule.outputs.len == 0) return error.InvalidRule;
    for (rule.all) |condition| try validateCondition(condition);
    for (rule.any) |condition| try validateCondition(condition);
    for (rule.outputs) |output| {
        if (output.id.len == 0 or output.summary.len == 0) return error.InvalidRule;
        if (output.kind == .fact) return error.InvalidRule;
    }
}

fn validateCondition(condition: Condition) Error!void {
    if (condition.subject.len == 0 or condition.predicate.len == 0) return error.InvalidRule;
}

pub fn evaluate(allocator: std.mem.Allocator, request: Request) !EvaluationResult {
    const limits = request.limits.capped();
    if (request.facts.len > limits.max_facts) return error.FactLimitExceeded;
    if (request.rules.len > limits.max_rules) return error.RuleLimitExceeded;

    for (request.rules) |rule| try validateRule(rule);

    var fired = std.ArrayList(FiredRule).init(allocator);
    errdefer fired.deinit();
    var candidates = std.ArrayList(EmittedOutput).init(allocator);
    errdefer candidates.deinit();
    var obligations = std.ArrayList(EmittedOutput).init(allocator);
    errdefer obligations.deinit();
    var unknowns = std.ArrayList(EmittedOutput).init(allocator);
    errdefer unknowns.deinit();
    var trace = std.ArrayList(ExplanationTrace).init(allocator);
    errdefer trace.deinit();

    var total_outputs: usize = 0;
    var budget_exhausted = false;
    var telemetry = CapacityTelemetry{};

    for (request.rules) |rule| {
        const all_count = countMatchingConditions(request.facts, rule.all);
        const any_match = anyConditionMatches(request.facts, rule.any);
        const all_match = all_count == rule.all.len;
        const any_ok = rule.any.len == 0 or any_match;
        const did_fire = all_match and any_ok;

        try trace.append(.{
            .rule_id = rule.id,
            .rule_name = rule.name,
            .fired = did_fire,
            .matched_all = all_count,
            .required_all = rule.all.len,
            .matched_any = any_match,
            .required_any = rule.any.len,
            .reason = if (did_fire) "all required conditions matched and optional any condition was satisfied" else "rule conditions were not satisfied",
        });

        if (!did_fire) continue;
        if (fired.items.len >= limits.max_fired_rules) {
            budget_exhausted = true;
            telemetry.max_fired_rules_hit = true;
            telemetry.max_rules_hit = true;
            telemetry.rejected_outputs += rule.outputs.len;
            telemetry.budget_hits += 1;
            break;
        }
        try fired.append(.{
            .id = rule.id,
            .name = rule.name,
            .matched_all = all_count,
            .matched_any = any_match,
        });

        for (rule.outputs, 0..) |output, output_idx| {
            if (total_outputs >= limits.max_outputs) {
                budget_exhausted = true;
                telemetry.max_outputs_hit = true;
                telemetry.rejected_outputs += rule.outputs.len - output_idx;
                telemetry.budget_hits += 1;
                break;
            }
            const emitted = emittedFromOutput(rule.id, output);
            switch (output.kind) {
                .risk_candidate, .check_candidate, .follow_up_candidate => try candidates.append(emitted),
                .evidence_expectation => try obligations.append(emitted),
                .unknown => try unknowns.append(emitted),
                .fact => unreachable,
            }
            total_outputs += 1;
        }
        if (budget_exhausted) break;
    }
    telemetry.unknowns_created = unknowns.items.len;
    telemetry.expansion_recommended = telemetry.hasPressure();

    return .{
        .allocator = allocator,
        .fired_rules = try fired.toOwnedSlice(),
        .emitted_candidates = try candidates.toOwnedSlice(),
        .emitted_obligations = try obligations.toOwnedSlice(),
        .emitted_unknowns = try unknowns.toOwnedSlice(),
        .explanation_trace = try trace.toOwnedSlice(),
        .limits = limits,
        .facts_considered = request.facts.len,
        .rules_considered = request.rules.len,
        .outputs_emitted = total_outputs,
        .budget_exhausted = budget_exhausted,
        .capacity_telemetry = telemetry,
    };
}

fn emittedFromOutput(rule_id: []const u8, output: RuleOutput) EmittedOutput {
    return .{
        .kind = output.kind,
        .id = output.id,
        .rule_id = rule_id,
        .summary = output.summary,
        .detail = output.detail,
        .risk_level = output.risk_level,
        .executes_by_default = false,
        .status = "pending",
        .executed = false,
        .treated_as_proof = false,
    };
}

fn countMatchingConditions(facts: []const Fact, conditions: []const Condition) usize {
    var matched: usize = 0;
    for (conditions) |condition| {
        if (conditionMatchesAnyFact(facts, condition)) matched += 1;
    }
    return matched;
}

fn anyConditionMatches(facts: []const Fact, conditions: []const Condition) bool {
    if (conditions.len == 0) return false;
    for (conditions) |condition| {
        if (conditionMatchesAnyFact(facts, condition)) return true;
    }
    return false;
}

fn conditionMatchesAnyFact(facts: []const Fact, condition: Condition) bool {
    for (facts) |fact| {
        if (!std.mem.eql(u8, fact.subject, condition.subject)) continue;
        if (!std.mem.eql(u8, fact.predicate, condition.predicate)) continue;
        if (condition.object) |object| {
            if (!std.mem.eql(u8, fact.object, object)) continue;
        }
        return true;
    }
    return false;
}

pub fn parseRequest(allocator: std.mem.Allocator, root: std.json.Value) !Request {
    if (root != .object) return error.InvalidRule;
    const obj = root.object;
    const facts_value = obj.get("facts") orelse return error.InvalidRule;
    const rules_value = obj.get("rules") orelse return error.InvalidRule;
    if (facts_value != .array or rules_value != .array) return error.InvalidRule;

    var facts = std.ArrayList(Fact).init(allocator);
    for (facts_value.array.items) |item| {
        const fact_obj = valueObject(item) orelse return error.InvalidRule;
        try facts.append(.{
            .subject = getRequiredString(fact_obj, "subject") orelse return error.InvalidRule,
            .predicate = getRequiredString(fact_obj, "predicate") orelse return error.InvalidRule,
            .object = getStringAliases(fact_obj, &.{ "object", "value" }) orelse return error.InvalidRule,
            .source = getStringAliases(fact_obj, &.{"source"}) orelse "request",
        });
    }

    var rules = std.ArrayList(Rule).init(allocator);
    for (rules_value.array.items) |item| {
        const rule_obj = valueObject(item) orelse return error.InvalidRule;
        const when_obj = if (rule_obj.get("when")) |when| valueObject(when) orelse return error.InvalidRule else null;
        const all_value = if (when_obj) |when| when.get("all") else rule_obj.get("all");
        const any_value = if (when_obj) |when| when.get("any") else rule_obj.get("any");
        const outputs_value = rule_obj.get("emit") orelse rule_obj.get("outputs") orelse return error.InvalidRule;
        if (outputs_value != .array) return error.InvalidRule;
        const parsed_rule = Rule{
            .id = getRequiredString(rule_obj, "id") orelse return error.InvalidRule,
            .name = getRequiredString(rule_obj, "name") orelse return error.InvalidRule,
            .all = try parseConditions(allocator, all_value),
            .any = try parseConditions(allocator, any_value),
            .outputs = try parseOutputs(allocator, outputs_value.array),
        };
        try validateRule(parsed_rule);
        try rules.append(parsed_rule);
    }

    return .{
        .facts = try facts.toOwnedSlice(),
        .rules = try rules.toOwnedSlice(),
        .limits = parseLimits(obj),
        .project_shard = getStringAliases(obj, &.{ "projectShard", "project_shard" }),
    };
}

fn parseConditions(allocator: std.mem.Allocator, value: ?std.json.Value) ![]const Condition {
    const actual = value orelse return &.{};
    if (actual != .array) return error.InvalidRule;
    var out = std.ArrayList(Condition).init(allocator);
    for (actual.array.items) |item| {
        const obj = valueObject(item) orelse return error.InvalidRule;
        try out.append(.{
            .subject = getRequiredString(obj, "subject") orelse return error.InvalidRule,
            .predicate = getRequiredString(obj, "predicate") orelse return error.InvalidRule,
            .object = getStringAliases(obj, &.{ "object", "value" }),
        });
    }
    return try out.toOwnedSlice();
}

fn parseOutputs(allocator: std.mem.Allocator, array: std.json.Array) ![]const RuleOutput {
    var out = std.ArrayList(RuleOutput).init(allocator);
    for (array.items) |item| {
        const obj = valueObject(item) orelse return error.InvalidRule;
        const kind_text = getStringAliases(obj, &.{ "kind", "type" }) orelse return error.InvalidRule;
        try out.append(.{
            .kind = parseOutputKind(kind_text) orelse return error.InvalidRule,
            .id = getRequiredString(obj, "id") orelse return error.InvalidRule,
            .summary = getStringAliases(obj, &.{ "summary", "purpose" }) orelse return error.InvalidRule,
            .detail = getStringAliases(obj, &.{ "detail", "reason" }) orelse "",
            .risk_level = getStringAliases(obj, &.{ "risk_level", "riskLevel" }) orelse "medium",
        });
    }
    return try out.toOwnedSlice();
}

fn parseOutputKind(text: []const u8) ?OutputKind {
    inline for (std.meta.fields(OutputKind)) |field| {
        if (std.mem.eql(u8, text, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

fn parseLimits(obj: std.json.ObjectMap) Limits {
    const value = obj.get("limits") orelse return .{};
    if (value != .object) return .{};
    const limits = value.object;
    return .{
        .max_facts = getUsize(limits, "maxFacts", "max_facts") orelse DEFAULT_MAX_FACTS,
        .max_rules = getUsize(limits, "maxRules", "max_rules") orelse DEFAULT_MAX_RULES,
        .max_fired_rules = getUsize(limits, "maxFiredRules", "max_fired_rules") orelse DEFAULT_MAX_FIRED_RULES,
        .max_outputs = getUsize(limits, "maxOutputs", "max_outputs") orelse DEFAULT_MAX_OUTPUTS,
    };
}

fn valueObject(value: std.json.Value) ?std.json.ObjectMap {
    return if (value == .object) value.object else null;
}

fn getRequiredString(obj: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = obj.get(name) orelse return null;
    if (value != .string or value.string.len == 0) return null;
    return value.string;
}

fn getStringAliases(obj: std.json.ObjectMap, names: []const []const u8) ?[]const u8 {
    for (names) |name| {
        if (obj.get(name)) |value| {
            if (value == .string) return value.string;
        }
    }
    return null;
}

fn getUsize(obj: std.json.ObjectMap, camel: []const u8, snake: []const u8) ?usize {
    const value = obj.get(camel) orelse obj.get(snake) orelse return null;
    if (value != .integer or value.integer < 0) return null;
    return @intCast(value.integer);
}

pub fn applyAcceptedCorrectionInfluence(allocator: std.mem.Allocator, result: *EvaluationResult, reviewed: *const correction_review.ReadResult) !void {
    result.accepted_correction_warnings = try cloneWarnings(allocator, reviewed.warnings);
    result.influence_telemetry.records_read = reviewed.records_read;
    result.influence_telemetry.accepted_records = reviewed.accepted_records;
    result.influence_telemetry.rejected_records = reviewed.rejected_records;
    result.influence_telemetry.malformed_lines = reviewed.malformed_lines;
    result.influence_telemetry.warnings = reviewed.warnings.len;
    result.influence_telemetry.influences_loaded = reviewed.influences.len;
    result.influence_telemetry.truncated = reviewed.truncated;

    for (reviewed.influences) |influence| {
        if (!std.mem.eql(u8, influence.applies_to, "rule.evaluate")) continue;
        if (matchInfluence(result, influence)) |matched| {
            try appendCorrectionInfluence(allocator, result, influence, matched.rule_id, matched.output_id);
            result.influence_telemetry.influences_applied += 1;
            switch (influence.influence_kind) {
                .suppress_exact_repeat => if (matched.output_id) |output_id| {
                    const removed = try suppressOutputById(allocator, result, output_id);
                    if (removed) {
                        result.influence_telemetry.outputs_suppressed += 1;
                        try appendFutureBehaviorCandidate(allocator, result, "verifier_check_candidate", "suppressed exact repeated bad rule output requires explicit verifier/check candidate before reintroduction", influence.source_reviewed_correction_id);
                    }
                },
                .require_stronger_evidence => try appendFutureBehaviorCandidate(allocator, result, "follow_up_evidence_request", "accepted missing-evidence correction requires explicit evidence expectation before relying on this rule output", influence.source_reviewed_correction_id),
                .require_verifier_candidate => try appendFutureBehaviorCandidate(allocator, result, "verifier_check_candidate", "accepted unsafe rule-output correction requires stronger review and a verifier/check candidate; no verifier was executed", influence.source_reviewed_correction_id),
                .warning, .penalty => try appendFutureBehaviorCandidate(allocator, result, "rule_update_candidate", "accepted reviewed correction warns on a repeated misleading rule output and may rank it lower after explicit review", influence.source_reviewed_correction_id),
                .propose_negative_knowledge => try appendFutureBehaviorCandidate(allocator, result, "negative_knowledge_candidate", "accepted reviewed correction proposes negative knowledge candidate only", influence.source_reviewed_correction_id),
                .propose_pack_guidance => try appendFutureBehaviorCandidate(allocator, result, "pack_guidance_candidate", "accepted reviewed correction proposes pack guidance candidate only", influence.source_reviewed_correction_id),
                .propose_corpus_update => try appendFutureBehaviorCandidate(allocator, result, "corpus_update_candidate", "accepted reviewed correction proposes corpus update candidate only", influence.source_reviewed_correction_id),
            }
        }
    }
}

pub fn applyAcceptedNegativeKnowledgeInfluence(allocator: std.mem.Allocator, result: *EvaluationResult, reviewed: *const negative_knowledge_review.ReadResult) !void {
    result.accepted_negative_knowledge_warnings = try cloneNegativeKnowledgeWarnings(allocator, reviewed.warnings);
    result.negative_knowledge_telemetry.records_read = reviewed.records_read;
    result.negative_knowledge_telemetry.accepted_records = reviewed.accepted_records;
    result.negative_knowledge_telemetry.rejected_records = reviewed.rejected_records;
    result.negative_knowledge_telemetry.malformed_lines = reviewed.malformed_lines;
    result.negative_knowledge_telemetry.warnings = reviewed.warnings.len;
    result.negative_knowledge_telemetry.influences_loaded = reviewed.influences.len;
    result.negative_knowledge_telemetry.truncated = reviewed.truncated;

    for (reviewed.influences) |influence| {
        if (!std.mem.eql(u8, influence.applies_to, "rule.evaluate")) continue;
        if (matchNegativeKnowledgeInfluence(result, influence)) |matched| {
            try appendNegativeKnowledgeInfluence(allocator, result, influence, matched.rule_id, matched.output_id);
            result.negative_knowledge_telemetry.influences_applied += 1;
            switch (influence.influence_kind) {
                .suppress_exact_repeat => if (matched.output_id) |output_id| {
                    const removed = try suppressOutputById(allocator, result, output_id);
                    if (removed) {
                        result.negative_knowledge_telemetry.outputs_suppressed += 1;
                        try appendNegativeKnowledgeFutureBehaviorCandidate(allocator, result, "verifier_check_candidate", "suppressed exact repeated known-bad rule output requires explicit verifier/check candidate before reintroduction", influence.source_reviewed_negative_knowledge_id);
                    }
                },
                .require_stronger_evidence => try appendNegativeKnowledgeFutureBehaviorCandidate(allocator, result, "follow_up_evidence_request", "accepted reviewed negative knowledge requires explicit evidence expectation before relying on this rule output", influence.source_reviewed_negative_knowledge_id),
                .require_verifier_candidate => try appendNegativeKnowledgeFutureBehaviorCandidate(allocator, result, "verifier_check_candidate", "accepted reviewed negative knowledge requires stronger review and a verifier/check candidate; no verifier was executed", influence.source_reviewed_negative_knowledge_id),
                .warning, .penalty => try appendNegativeKnowledgeFutureBehaviorCandidate(allocator, result, "rule_update_candidate", "accepted reviewed negative knowledge warns on a repeated known-bad rule output and may rank it lower after explicit review", influence.source_reviewed_negative_knowledge_id),
                .propose_pack_guidance => try appendNegativeKnowledgeFutureBehaviorCandidate(allocator, result, "pack_guidance_candidate", "accepted reviewed negative knowledge proposes pack guidance candidate only", influence.source_reviewed_negative_knowledge_id),
                .propose_corpus_update => try appendNegativeKnowledgeFutureBehaviorCandidate(allocator, result, "corpus_update_candidate", "accepted reviewed negative knowledge proposes corpus update candidate only", influence.source_reviewed_negative_knowledge_id),
                .propose_rule_update => try appendNegativeKnowledgeFutureBehaviorCandidate(allocator, result, "rule_update_candidate", "accepted reviewed negative knowledge proposes rule update candidate only", influence.source_reviewed_negative_knowledge_id),
            }
        }
    }
}

const InfluenceMatch = struct {
    rule_id: ?[]const u8,
    output_id: ?[]const u8,
};

fn matchNegativeKnowledgeInfluence(result: *const EvaluationResult, influence: negative_knowledge_review.AcceptedNegativeKnowledgeInfluence) ?InfluenceMatch {
    for (result.emitted_candidates) |output| {
        if (outputMatchesNegativeKnowledge(output, influence)) return .{ .rule_id = output.rule_id, .output_id = output.id };
    }
    for (result.emitted_obligations) |output| {
        if (outputMatchesNegativeKnowledge(output, influence)) return .{ .rule_id = output.rule_id, .output_id = output.id };
    }
    for (result.emitted_unknowns) |output| {
        if (outputMatchesNegativeKnowledge(output, influence)) return .{ .rule_id = output.rule_id, .output_id = output.id };
    }
    for (result.explanation_trace) |trace| {
        if (textMatchesNegativeKnowledge(trace.rule_id, influence) or
            textMatchesNegativeKnowledge(trace.rule_name, influence) or
            textMatchesNegativeKnowledge(trace.reason, influence))
        {
            return .{ .rule_id = trace.rule_id, .output_id = null };
        }
    }
    return null;
}

fn outputMatchesNegativeKnowledge(output: EmittedOutput, influence: negative_knowledge_review.AcceptedNegativeKnowledgeInfluence) bool {
    if (influence.matched_output_id) |output_id| {
        if (std.mem.eql(u8, output.id, output_id)) return true;
    }
    if (influence.matched_rule_id) |rule_id| {
        if (std.mem.eql(u8, output.rule_id, rule_id)) return true;
    }
    return textMatchesNegativeKnowledge(output.id, influence) or
        textMatchesNegativeKnowledge(output.rule_id, influence) or
        textMatchesNegativeKnowledge(output.summary, influence) or
        textMatchesNegativeKnowledge(output.detail, influence) or
        textMatchesNegativeKnowledge(output.kind.text(), influence);
}

fn textMatchesNegativeKnowledge(text: []const u8, influence: negative_knowledge_review.AcceptedNegativeKnowledgeInfluence) bool {
    if (text.len == 0 or influence.matched_pattern.len == 0) return false;
    if (std.mem.eql(u8, text, influence.matched_pattern)) return true;
    if (std.mem.indexOf(u8, text, influence.matched_pattern) != null) return true;
    if (std.mem.indexOf(u8, influence.matched_pattern, text) != null) return true;
    return fingerprintMatches(text, influence.pattern_fingerprint);
}

fn matchInfluence(result: *const EvaluationResult, influence: correction_review.AcceptedCorrectionInfluence) ?InfluenceMatch {
    for (result.emitted_candidates) |output| {
        if (outputMatchesInfluence(output, influence)) return .{ .rule_id = output.rule_id, .output_id = output.id };
    }
    for (result.emitted_obligations) |output| {
        if (outputMatchesInfluence(output, influence)) return .{ .rule_id = output.rule_id, .output_id = output.id };
    }
    for (result.emitted_unknowns) |output| {
        if (outputMatchesInfluence(output, influence)) return .{ .rule_id = output.rule_id, .output_id = output.id };
    }
    for (result.explanation_trace) |trace| {
        if (textMatchesInfluence(trace.rule_id, influence) or
            textMatchesInfluence(trace.rule_name, influence) or
            textMatchesInfluence(trace.reason, influence))
        {
            return .{ .rule_id = trace.rule_id, .output_id = null };
        }
    }
    return null;
}

fn outputMatchesInfluence(output: EmittedOutput, influence: correction_review.AcceptedCorrectionInfluence) bool {
    return textMatchesInfluence(output.id, influence) or
        textMatchesInfluence(output.rule_id, influence) or
        textMatchesInfluence(output.summary, influence) or
        textMatchesInfluence(output.detail, influence) or
        textMatchesInfluence(output.kind.text(), influence);
}

fn textMatchesInfluence(text: []const u8, influence: correction_review.AcceptedCorrectionInfluence) bool {
    if (text.len == 0 or influence.matched_pattern.len == 0) return false;
    if (std.mem.eql(u8, text, influence.matched_pattern)) return true;
    if (std.mem.indexOf(u8, text, influence.matched_pattern) != null) return true;
    if (std.mem.indexOf(u8, influence.matched_pattern, text) != null) return true;
    return fingerprintMatches(text, influence.disputed_output_fingerprint);
}

fn fingerprintMatches(text: []const u8, fingerprint: []const u8) bool {
    var buf: [32]u8 = undefined;
    const own = std.fmt.bufPrint(&buf, "fnv1a64:{x:0>16}", .{std.hash.Fnv1a_64.hash(text)}) catch return false;
    return std.mem.eql(u8, own, fingerprint);
}

fn suppressOutputById(allocator: std.mem.Allocator, result: *EvaluationResult, output_id: []const u8) !bool {
    if (try suppressFromSlice(allocator, &result.emitted_candidates, output_id)) |removed| {
        if (removed) result.outputs_emitted -= 1;
        return removed;
    }
    if (try suppressFromSlice(allocator, &result.emitted_obligations, output_id)) |removed| {
        if (removed) result.outputs_emitted -= 1;
        return removed;
    }
    if (try suppressFromSlice(allocator, &result.emitted_unknowns, output_id)) |removed| {
        if (removed) result.outputs_emitted -= 1;
        result.capacity_telemetry.unknowns_created = result.emitted_unknowns.len;
        return removed;
    }
    return false;
}

fn suppressFromSlice(allocator: std.mem.Allocator, outputs: *[]EmittedOutput, output_id: []const u8) !?bool {
    var found: ?usize = null;
    for (outputs.*, 0..) |output, idx| {
        if (std.mem.eql(u8, output.id, output_id)) {
            found = idx;
            break;
        }
    }
    const idx = found orelse return null;
    const old = outputs.*;
    const next = try allocator.alloc(EmittedOutput, old.len - 1);
    var write_idx: usize = 0;
    for (old, 0..) |output, read_idx| {
        if (read_idx == idx) continue;
        next[write_idx] = output;
        write_idx += 1;
    }
    allocator.free(old);
    outputs.* = next;
    return true;
}

fn cloneWarnings(allocator: std.mem.Allocator, warnings: []const correction_review.ReadWarning) ![]AcceptedCorrectionWarning {
    const out = try allocator.alloc(AcceptedCorrectionWarning, warnings.len);
    var built: usize = 0;
    errdefer {
        for (out[0..built]) |*item| item.deinit(allocator);
        allocator.free(out);
    }
    for (warnings, 0..) |warning, idx| {
        out[idx] = .{
            .line_number = warning.line_number,
            .reason = try allocator.dupe(u8, warning.reason),
        };
        built += 1;
    }
    return out;
}

fn cloneNegativeKnowledgeWarnings(allocator: std.mem.Allocator, warnings: []const negative_knowledge_review.ReadWarning) ![]AcceptedNegativeKnowledgeWarning {
    const out = try allocator.alloc(AcceptedNegativeKnowledgeWarning, warnings.len);
    var built: usize = 0;
    errdefer {
        for (out[0..built]) |*item| item.deinit(allocator);
        allocator.free(out);
    }
    for (warnings, 0..) |warning, idx| {
        out[idx] = .{
            .line_number = warning.line_number,
            .reason = try allocator.dupe(u8, warning.reason),
        };
        built += 1;
    }
    return out;
}

fn appendCorrectionInfluence(
    allocator: std.mem.Allocator,
    result: *EvaluationResult,
    source: correction_review.AcceptedCorrectionInfluence,
    matched_rule_id: ?[]const u8,
    matched_output_id: ?[]const u8,
) !void {
    const old = result.correction_influences;
    var out = try allocator.alloc(CorrectionInfluence, old.len + 1);
    @memcpy(out[0..old.len], old);
    out[old.len] = .{
        .id = try allocator.dupe(u8, source.id),
        .source_reviewed_correction_id = try allocator.dupe(u8, source.source_reviewed_correction_id),
        .influence_kind = try allocator.dupe(u8, @tagName(source.influence_kind)),
        .applies_to = try allocator.dupe(u8, "rule.evaluate"),
        .matched_rule_id = if (matched_rule_id) |value| try allocator.dupe(u8, value) else null,
        .matched_output_id = if (matched_output_id) |value| try allocator.dupe(u8, value) else null,
        .reason = try allocator.dupe(u8, source.reason),
    };
    allocator.free(old);
    result.correction_influences = out;
}

fn appendNegativeKnowledgeInfluence(
    allocator: std.mem.Allocator,
    result: *EvaluationResult,
    source: negative_knowledge_review.AcceptedNegativeKnowledgeInfluence,
    matched_rule_id: ?[]const u8,
    matched_output_id: ?[]const u8,
) !void {
    const old = result.negative_knowledge_influences;
    var out = try allocator.alloc(NegativeKnowledgeInfluence, old.len + 1);
    @memcpy(out[0..old.len], old);
    out[old.len] = .{
        .id = try allocator.dupe(u8, source.id),
        .source_reviewed_negative_knowledge_id = try allocator.dupe(u8, source.source_reviewed_negative_knowledge_id),
        .influence_kind = try allocator.dupe(u8, @tagName(source.influence_kind)),
        .applies_to = try allocator.dupe(u8, "rule.evaluate"),
        .matched_rule_id = if (matched_rule_id) |value| try allocator.dupe(u8, value) else null,
        .matched_output_id = if (matched_output_id) |value| try allocator.dupe(u8, value) else null,
        .matched_pattern = try allocator.dupe(u8, source.matched_pattern),
        .reason = try allocator.dupe(u8, source.reason),
    };
    allocator.free(old);
    result.negative_knowledge_influences = out;
}

fn appendFutureBehaviorCandidate(allocator: std.mem.Allocator, result: *EvaluationResult, kind: []const u8, reason: []const u8, source_id: []const u8) !void {
    const old = result.future_behavior_candidates;
    var out = try allocator.alloc(FutureBehaviorCandidate, old.len + 1);
    @memcpy(out[0..old.len], old);
    out[old.len] = .{
        .kind = try allocator.dupe(u8, kind),
        .status = try allocator.dupe(u8, "candidate"),
        .reason = try allocator.dupe(u8, reason),
        .source_reviewed_correction_id = try allocator.dupe(u8, source_id),
    };
    allocator.free(old);
    result.future_behavior_candidates = out;
}

fn appendNegativeKnowledgeFutureBehaviorCandidate(allocator: std.mem.Allocator, result: *EvaluationResult, kind: []const u8, reason: []const u8, source_id: []const u8) !void {
    const old = result.future_behavior_candidates;
    var out = try allocator.alloc(FutureBehaviorCandidate, old.len + 1);
    @memcpy(out[0..old.len], old);
    out[old.len] = .{
        .kind = try allocator.dupe(u8, kind),
        .status = try allocator.dupe(u8, "candidate"),
        .reason = try allocator.dupe(u8, reason),
        .source_reviewed_negative_knowledge_id = try allocator.dupe(u8, source_id),
    };
    allocator.free(old);
    result.future_behavior_candidates = out;
}

pub fn renderJson(allocator: std.mem.Allocator, result: *const EvaluationResult) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    try w.writeAll("{\"ruleEvaluation\":{");
    try w.writeAll("\"nonAuthorizing\":true,\"candidateOnly\":true,\"proofDischarged\":false,\"supportGranted\":false");
    try w.print(",\"factsConsidered\":{d},\"rulesConsidered\":{d},\"outputsEmitted\":{d},\"budgetExhausted\":{s}", .{
        result.facts_considered,
        result.rules_considered,
        result.outputs_emitted,
        if (result.budget_exhausted) "true" else "false",
    });
    try w.writeAll(",\"limits\":{");
    try w.print("\"maxFacts\":{d},\"maxRules\":{d},\"maxFiredRules\":{d},\"maxOutputs\":{d}", .{
        result.limits.max_facts,
        result.limits.max_rules,
        result.limits.max_fired_rules,
        result.limits.max_outputs,
    });
    try w.writeAll("},\"firedRules\":[");
    for (result.fired_rules, 0..) |rule, idx| {
        if (idx != 0) try w.writeByte(',');
        try w.writeAll("{\"id\":\"");
        try writeEscaped(w, rule.id);
        try w.writeAll("\",\"name\":\"");
        try writeEscaped(w, rule.name);
        try w.print("\",\"matchedAll\":{d},\"matchedAny\":{s}}}", .{
            rule.matched_all,
            if (rule.matched_any) "true" else "false",
        });
    }
    try w.writeAll("],\"emittedCandidates\":");
    try writeOutputs(w, result.emitted_candidates, false);
    try w.writeAll(",\"emittedObligations\":");
    try writeOutputs(w, result.emitted_obligations, true);
    try w.writeAll(",\"emittedUnknowns\":");
    try writeOutputs(w, result.emitted_unknowns, false);
    try w.writeAll(",\"correctionReviewCandidates\":");
    try writeCorrectionReviewCandidates(w, result);
    try w.writeAll(",\"acceptedCorrectionWarnings\":[");
    for (result.accepted_correction_warnings, 0..) |warning, idx| {
        if (idx != 0) try w.writeByte(',');
        try w.writeAll("{");
        try w.print("\"lineNumber\":{d}", .{warning.line_number});
        try w.writeAll(",\"reason\":\"");
        try writeEscaped(w, warning.reason);
        try w.writeAll("\"}");
    }
    try w.writeAll("],\"correctionInfluences\":[");
    for (result.correction_influences, 0..) |influence, idx| {
        if (idx != 0) try w.writeByte(',');
        try w.writeAll("{\"sourceReviewedCorrectionId\":\"");
        try writeEscaped(w, influence.source_reviewed_correction_id);
        try w.writeAll("\",\"influenceKind\":\"");
        try writeEscaped(w, influence.influence_kind);
        try w.writeAll("\",\"appliesTo\":\"rule.evaluate\"");
        if (influence.matched_rule_id) |value| {
            try w.writeAll(",\"matchedRuleId\":\"");
            try writeEscaped(w, value);
            try w.writeByte('"');
        }
        if (influence.matched_output_id) |value| {
            try w.writeAll(",\"matchedOutputId\":\"");
            try writeEscaped(w, value);
            try w.writeByte('"');
        }
        try w.writeAll(",\"reason\":\"");
        try writeEscaped(w, influence.reason);
        try w.writeAll("\",\"nonAuthorizing\":true,\"treatedAsProof\":false,\"globalPromotion\":false,\"mutationFlags\":");
        try writeCorrectionMutationFlags(w, influence.mutation_flags);
        try w.writeAll("}");
    }
    try w.writeAll("],\"acceptedNegativeKnowledgeWarnings\":[");
    for (result.accepted_negative_knowledge_warnings, 0..) |warning, idx| {
        if (idx != 0) try w.writeByte(',');
        try w.writeAll("{");
        try w.print("\"lineNumber\":{d}", .{warning.line_number});
        try w.writeAll(",\"reason\":\"");
        try writeEscaped(w, warning.reason);
        try w.writeAll("\"}");
    }
    try w.writeAll("],\"negativeKnowledgeInfluences\":[");
    for (result.negative_knowledge_influences, 0..) |influence, idx| {
        if (idx != 0) try w.writeByte(',');
        try w.writeAll("{\"sourceReviewedNegativeKnowledgeId\":\"");
        try writeEscaped(w, influence.source_reviewed_negative_knowledge_id);
        try w.writeAll("\",\"influenceKind\":\"");
        try writeEscaped(w, influence.influence_kind);
        try w.writeAll("\",\"appliesTo\":\"rule.evaluate\"");
        if (influence.matched_rule_id) |value| {
            try w.writeAll(",\"matchedRuleId\":\"");
            try writeEscaped(w, value);
            try w.writeByte('"');
        }
        if (influence.matched_output_id) |value| {
            try w.writeAll(",\"matchedOutputId\":\"");
            try writeEscaped(w, value);
            try w.writeByte('"');
        }
        try w.writeAll(",\"matchedPattern\":\"");
        try writeEscaped(w, influence.matched_pattern);
        try w.writeAll("\",\"reason\":\"");
        try writeEscaped(w, influence.reason);
        try w.writeAll("\",\"nonAuthorizing\":true,\"treatedAsProof\":false,\"usedAsEvidence\":false,\"globalPromotion\":false,\"mutationFlags\":");
        try writeCorrectionMutationFlags(w, influence.mutation_flags);
        try w.writeAll("}");
    }
    try w.writeAll("],\"futureBehaviorCandidates\":[");
    for (result.future_behavior_candidates, 0..) |candidate, idx| {
        if (idx != 0) try w.writeByte(',');
        try w.writeAll("{\"kind\":\"");
        try writeEscaped(w, candidate.kind);
        try w.writeAll("\",\"status\":\"");
        try writeEscaped(w, candidate.status);
        try w.writeAll("\",\"reason\":\"");
        try writeEscaped(w, candidate.reason);
        if (candidate.source_reviewed_correction_id) |value| {
            try w.writeAll("\",\"sourceReviewedCorrectionId\":\"");
            try writeEscaped(w, value);
        }
        if (candidate.source_reviewed_negative_knowledge_id) |value| {
            try w.writeAll("\",\"sourceReviewedNegativeKnowledgeId\":\"");
            try writeEscaped(w, value);
        }
        try w.writeAll("\",\"candidateOnly\":true,\"nonAuthorizing\":true,\"treatedAsProof\":false,\"usedAsEvidence\":false,\"globalPromotion\":false,\"mutationFlags\":");
        try writeCorrectionMutationFlags(w, candidate.mutation_flags);
        try w.writeAll("}");
    }
    try w.writeAll("],\"influenceTelemetry\":");
    try writeInfluenceTelemetry(w, result.influence_telemetry);
    try w.writeAll(",\"negativeKnowledgeTelemetry\":");
    try writeNegativeKnowledgeTelemetry(w, result.negative_knowledge_telemetry);
    try w.writeAll(",\"capacityTelemetry\":");
    try writeCapacityTelemetry(w, result.capacity_telemetry);
    try w.writeAll(",\"explanationTrace\":[");
    for (result.explanation_trace, 0..) |trace, idx| {
        if (idx != 0) try w.writeByte(',');
        try w.writeAll("{\"ruleId\":\"");
        try writeEscaped(w, trace.rule_id);
        try w.writeAll("\",\"ruleName\":\"");
        try writeEscaped(w, trace.rule_name);
        try w.print("\",\"fired\":{s},\"matchedAll\":{d},\"requiredAll\":{d},\"matchedAny\":{s},\"requiredAny\":{d},\"reason\":\"", .{
            if (trace.fired) "true" else "false",
            trace.matched_all,
            trace.required_all,
            if (trace.matched_any) "true" else "false",
            trace.required_any,
        });
        try writeEscaped(w, trace.reason);
        try w.writeAll("\"}");
    }
    try w.writeAll("],\"safetyFlags\":{");
    try w.print("\"commandsExecuted\":{s},\"verifiersExecuted\":{s},\"corpusMutation\":{s},\"packMutation\":{s},\"negativeKnowledgeMutation\":{s},\"proofDischarged\":{s},\"supportGranted\":{s}", .{
        if (result.safety_flags.commands_executed) "true" else "false",
        if (result.safety_flags.verifiers_executed) "true" else "false",
        if (result.safety_flags.corpus_mutation) "true" else "false",
        if (result.safety_flags.pack_mutation) "true" else "false",
        if (result.safety_flags.negative_knowledge_mutation) "true" else "false",
        if (result.safety_flags.proof_discharged) "true" else "false",
        if (result.safety_flags.support_granted) "true" else "false",
    });
    try w.writeAll("}}}");
    return try out.toOwnedSlice();
}

fn writeCorrectionReviewCandidates(w: anytype, result: *const EvaluationResult) !void {
    try w.writeByte('[');
    var wrote = false;
    for (result.emitted_candidates) |candidate| {
        const reason = switch (candidate.kind) {
            .risk_candidate => "review bad or unsafe rule output through correction.propose with correctionType=unsafe_candidate",
            .check_candidate, .follow_up_candidate => "review missing or misleading rule output through correction.propose before future influence",
            else => "review rule output through correction.propose before future influence",
        };
        try writeCorrectionReviewCandidate(w, &wrote, candidate.id, candidate.rule_id, @tagName(candidate.kind), reason);
    }
    for (result.emitted_obligations) |obligation| {
        try writeCorrectionReviewCandidate(w, &wrote, obligation.id, obligation.rule_id, @tagName(obligation.kind), "misleading obligation can be disputed through correction.propose with correctionType=misleading_rule");
    }
    if (result.capacity_telemetry.hasPressure()) {
        try writeCorrectionReviewCandidate(w, &wrote, "capacity:rule.evaluate", "capacity", "capacity_warning", "capacity-limited evaluation requires stronger review and cannot authorize candidates");
    }
    try w.writeByte(']');
}

fn writeCorrectionReviewCandidate(w: anytype, wrote: *bool, output_id: []const u8, rule_id: []const u8, disputed_kind: []const u8, reason: []const u8) !void {
    if (wrote.*) try w.writeByte(',');
    wrote.* = true;
    try w.writeAll("{\"operationKind\":\"rule.evaluate\",\"outputId\":\"");
    try writeEscaped(w, output_id);
    try w.writeAll("\",\"ruleId\":\"");
    try writeEscaped(w, rule_id);
    try w.writeAll("\",\"disputedOutput\":\"");
    try writeEscaped(w, disputed_kind);
    try w.writeAll("\",\"proposedOperation\":\"correction.propose\",\"requiredReview\":true,\"candidateOnly\":true,\"nonAuthorizing\":true,\"treatedAsProof\":false,\"persisted\":false,\"reason\":\"");
    try writeEscaped(w, reason);
    try w.writeAll("\"}");
}

fn writeCorrectionMutationFlags(w: anytype, flags: CorrectionMutationFlags) !void {
    try w.print("{{\"corpusMutation\":{s},\"packMutation\":{s},\"negativeKnowledgeMutation\":{s},\"commandsExecuted\":{s},\"verifiersExecuted\":{s}}}", .{
        if (flags.corpus_mutation) "true" else "false",
        if (flags.pack_mutation) "true" else "false",
        if (flags.negative_knowledge_mutation) "true" else "false",
        if (flags.commands_executed) "true" else "false",
        if (flags.verifiers_executed) "true" else "false",
    });
}

fn writeInfluenceTelemetry(w: anytype, telemetry: InfluenceTelemetry) !void {
    try w.print("{{\"recordsRead\":{d},\"acceptedRecords\":{d},\"rejectedRecords\":{d},\"malformedLines\":{d},\"warnings\":{d}", .{
        telemetry.records_read,
        telemetry.accepted_records,
        telemetry.rejected_records,
        telemetry.malformed_lines,
        telemetry.warnings,
    });
    try w.print(",\"influencesLoaded\":{d},\"influencesApplied\":{d},\"outputsSuppressed\":{d},\"truncated\":{s}", .{
        telemetry.influences_loaded,
        telemetry.influences_applied,
        telemetry.outputs_suppressed,
        if (telemetry.truncated) "true" else "false",
    });
    try w.print(",\"sameShardOnly\":{s},\"mutationPerformed\":{s},\"commandsExecuted\":{s},\"verifiersExecuted\":{s}}}", .{
        if (telemetry.same_shard_only) "true" else "false",
        if (telemetry.mutation_performed) "true" else "false",
        if (telemetry.commands_executed) "true" else "false",
        if (telemetry.verifiers_executed) "true" else "false",
    });
}

fn writeNegativeKnowledgeTelemetry(w: anytype, telemetry: NegativeKnowledgeTelemetry) !void {
    try w.print("{{\"recordsRead\":{d},\"acceptedRecords\":{d},\"rejectedRecords\":{d},\"malformedLines\":{d},\"warnings\":{d}", .{
        telemetry.records_read,
        telemetry.accepted_records,
        telemetry.rejected_records,
        telemetry.malformed_lines,
        telemetry.warnings,
    });
    try w.print(",\"influencesLoaded\":{d},\"influencesApplied\":{d},\"outputsSuppressed\":{d},\"truncated\":{s}", .{
        telemetry.influences_loaded,
        telemetry.influences_applied,
        telemetry.outputs_suppressed,
        if (telemetry.truncated) "true" else "false",
    });
    try w.print(",\"sameShardOnly\":{s},\"mutationPerformed\":{s},\"commandsExecuted\":{s},\"verifiersExecuted\":{s}}}", .{
        if (telemetry.same_shard_only) "true" else "false",
        if (telemetry.mutation_performed) "true" else "false",
        if (telemetry.commands_executed) "true" else "false",
        if (telemetry.verifiers_executed) "true" else "false",
    });
}

fn writeCapacityTelemetry(w: anytype, telemetry: CapacityTelemetry) !void {
    try w.writeAll("{");
    try w.print("\"droppedRunes\":{d},\"collisionStalls\":{d},\"saturatedSlots\":{d}", .{ telemetry.dropped_runes, telemetry.collision_stalls, telemetry.saturated_slots });
    try w.print(",\"truncatedInputs\":{d},\"truncatedSnippets\":{d},\"skippedInputs\":{d},\"skippedFiles\":{d}", .{ telemetry.truncated_inputs, telemetry.truncated_snippets, telemetry.skipped_inputs, telemetry.skipped_files });
    try w.print(",\"budgetHits\":{d},\"maxResultsHit\":{s},\"maxOutputsHit\":{s},\"maxRulesHit\":{s}", .{
        telemetry.budget_hits,
        if (telemetry.max_results_hit) "true" else "false",
        if (telemetry.max_outputs_hit) "true" else "false",
        if (telemetry.max_rules_hit) "true" else "false",
    });
    try w.print(",\"maxFiredRulesHit\":{s},\"maxFactsHit\":{s},\"rejectedOutputs\":{d},\"unknownsCreated\":{d}", .{
        if (telemetry.max_fired_rules_hit) "true" else "false",
        if (telemetry.max_facts_hit) "true" else "false",
        telemetry.rejected_outputs,
        telemetry.unknowns_created,
    });
    try w.writeAll(",\"capacityWarnings\":[");
    var wrote = false;
    try writeWarningIf(w, &wrote, telemetry.max_outputs_hit, "max_outputs_hit");
    try writeWarningIf(w, &wrote, telemetry.max_fired_rules_hit, "max_fired_rules_hit");
    try writeWarningIf(w, &wrote, telemetry.max_rules_hit, "max_rules_hit");
    try writeWarningIf(w, &wrote, telemetry.max_facts_hit, "max_facts_hit");
    try writeWarningIf(w, &wrote, telemetry.rejected_outputs != 0, "outputs_rejected_by_capacity");
    try w.print("],\"expansionRecommended\":{s},\"spilloverRecommended\":{s}", .{
        if (telemetry.expansion_recommended) "true" else "false",
        if (telemetry.spillover_recommended) "true" else "false",
    });
    try w.writeAll("}");
}

fn writeWarningIf(w: anytype, wrote: *bool, condition: bool, warning: []const u8) !void {
    if (!condition) return;
    if (wrote.*) try w.writeByte(',');
    try w.writeByte('"');
    try writeEscaped(w, warning);
    try w.writeByte('"');
    wrote.* = true;
}

fn writeOutputs(w: anytype, outputs: []const EmittedOutput, obligations: bool) !void {
    try w.writeByte('[');
    for (outputs, 0..) |output, idx| {
        if (idx != 0) try w.writeByte(',');
        try w.writeAll("{\"kind\":\"");
        try writeEscaped(w, output.kind.text());
        try w.writeAll("\",\"id\":\"");
        try writeEscaped(w, output.id);
        try w.writeAll("\",\"ruleId\":\"");
        try writeEscaped(w, output.rule_id);
        try w.writeAll("\",\"summary\":\"");
        try writeEscaped(w, output.summary);
        try w.writeAll("\",\"detail\":\"");
        try writeEscaped(w, output.detail);
        try w.writeAll("\",\"riskLevel\":\"");
        try writeEscaped(w, output.risk_level);
        try w.writeAll("\",\"candidateOnly\":true,\"nonAuthorizing\":true,\"executesByDefault\":false");
        if (obligations) {
            try w.writeAll(",\"status\":\"pending\",\"executed\":false,\"treatedAsProof\":false");
        }
        try w.writeAll("}");
    }
    try w.writeByte(']');
}

fn writeEscaped(w: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try w.print("\\u{x:0>4}", .{@as(u16, c)});
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
}

test "simple rule fires from matching facts" {
    const facts = [_]Fact{.{ .subject = "build", .predicate = "has", .object = "test" }};
    const outputs = [_]RuleOutput{.{ .kind = .check_candidate, .id = "check:test", .summary = "run explicit test verifier" }};
    const rules = [_]Rule{.{ .id = "rule:test", .name = "test rule", .all = &.{.{ .subject = "build", .predicate = "has", .object = "test" }}, .outputs = &outputs }};
    var result = try evaluate(std.testing.allocator, .{ .facts = &facts, .rules = &rules });
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.fired_rules.len);
    try std.testing.expectEqual(@as(usize, 1), result.emitted_candidates.len);
}

test "non-matching rule does not fire" {
    const facts = [_]Fact{.{ .subject = "build", .predicate = "has", .object = "lint" }};
    const outputs = [_]RuleOutput{.{ .kind = .unknown, .id = "unknown:test", .summary = "missing test signal" }};
    const rules = [_]Rule{.{ .id = "rule:test", .name = "test rule", .all = &.{.{ .subject = "build", .predicate = "has", .object = "test" }}, .outputs = &outputs }};
    var result = try evaluate(std.testing.allocator, .{ .facts = &facts, .rules = &rules });
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.fired_rules.len);
    try std.testing.expectEqual(@as(usize, 0), result.emitted_unknowns.len);
}

test "multiple rules fire in deterministic order" {
    const facts = [_]Fact{.{ .subject = "artifact", .predicate = "kind", .object = "zig" }};
    const out_a = [_]RuleOutput{.{ .kind = .follow_up_candidate, .id = "a", .summary = "first" }};
    const out_b = [_]RuleOutput{.{ .kind = .follow_up_candidate, .id = "b", .summary = "second" }};
    const rules = [_]Rule{
        .{ .id = "rule:a", .name = "A", .all = &.{.{ .subject = "artifact", .predicate = "kind", .object = "zig" }}, .outputs = &out_a },
        .{ .id = "rule:b", .name = "B", .all = &.{.{ .subject = "artifact", .predicate = "kind", .object = "zig" }}, .outputs = &out_b },
    };
    var result = try evaluate(std.testing.allocator, .{ .facts = &facts, .rules = &rules });
    defer result.deinit();

    try std.testing.expectEqualStrings("rule:a", result.fired_rules[0].id);
    try std.testing.expectEqualStrings("rule:b", result.fired_rules[1].id);
}

test "rule explanation trace includes why it fired" {
    const facts = [_]Fact{.{ .subject = "risk", .predicate = "present", .object = "external_state" }};
    const outputs = [_]RuleOutput{.{ .kind = .risk_candidate, .id = "risk:external", .summary = "external state risk" }};
    const rules = [_]Rule{.{ .id = "rule:risk", .name = "risk rule", .all = &.{.{ .subject = "risk", .predicate = "present", .object = "external_state" }}, .outputs = &outputs }};
    var result = try evaluate(std.testing.allocator, .{ .facts = &facts, .rules = &rules });
    defer result.deinit();

    try std.testing.expectEqual(true, result.explanation_trace[0].fired);
    try std.testing.expect(std.mem.indexOf(u8, result.explanation_trace[0].reason, "matched") != null);
}

test "invalid rule is rejected cleanly" {
    const outputs = [_]RuleOutput{.{ .kind = .unknown, .id = "unknown", .summary = "unknown" }};
    const rules = [_]Rule{.{ .id = "", .name = "invalid", .all = &.{.{ .subject = "a", .predicate = "b" }}, .outputs = &outputs }};
    try std.testing.expectError(error.InvalidRule, evaluate(std.testing.allocator, .{ .facts = &.{}, .rules = &rules }));
}

test "bounded max fired rules and outputs enforced" {
    const facts = [_]Fact{.{ .subject = "s", .predicate = "p", .object = "o" }};
    const out_a = [_]RuleOutput{
        .{ .kind = .follow_up_candidate, .id = "a1", .summary = "a1" },
        .{ .kind = .follow_up_candidate, .id = "a2", .summary = "a2" },
    };
    const out_b = [_]RuleOutput{.{ .kind = .follow_up_candidate, .id = "b1", .summary = "b1" }};
    const rules = [_]Rule{
        .{ .id = "a", .name = "a", .all = &.{.{ .subject = "s", .predicate = "p", .object = "o" }}, .outputs = &out_a },
        .{ .id = "b", .name = "b", .all = &.{.{ .subject = "s", .predicate = "p", .object = "o" }}, .outputs = &out_b },
    };
    var result = try evaluate(std.testing.allocator, .{
        .facts = &facts,
        .rules = &rules,
        .limits = .{ .max_fired_rules = 1, .max_outputs = 1 },
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.fired_rules.len);
    try std.testing.expectEqual(@as(usize, 1), result.outputs_emitted);
    try std.testing.expectEqual(true, result.budget_exhausted);
    try std.testing.expectEqual(true, result.capacity_telemetry.max_outputs_hit);
    try std.testing.expectEqual(@as(usize, 1), result.capacity_telemetry.budget_hits);
    try std.testing.expectEqual(true, result.capacity_telemetry.expansion_recommended);
}

test "cyclic recursive fact output pattern is rejected" {
    const outputs = [_]RuleOutput{.{ .kind = .fact, .id = "fact:derived", .summary = "derive fact" }};
    const rules = [_]Rule{.{ .id = "recursive", .name = "recursive", .all = &.{.{ .subject = "a", .predicate = "b" }}, .outputs = &outputs }};
    try std.testing.expectError(error.InvalidRule, evaluate(std.testing.allocator, .{ .facts = &.{}, .rules = &rules }));
}

test "emitted check candidate has executes_by_default false" {
    const facts = [_]Fact{.{ .subject = "s", .predicate = "p", .object = "o" }};
    const outputs = [_]RuleOutput{.{ .kind = .check_candidate, .id = "check", .summary = "check" }};
    const rules = [_]Rule{.{ .id = "r", .name = "r", .all = &.{.{ .subject = "s", .predicate = "p", .object = "o" }}, .outputs = &outputs }};
    var result = try evaluate(std.testing.allocator, .{ .facts = &facts, .rules = &rules });
    defer result.deinit();

    try std.testing.expectEqual(false, result.emitted_candidates[0].executes_by_default);
}

test "emitted obligation is pending unexecuted non-proof" {
    const facts = [_]Fact{.{ .subject = "s", .predicate = "p", .object = "o" }};
    const outputs = [_]RuleOutput{.{ .kind = .evidence_expectation, .id = "obl", .summary = "collect evidence" }};
    const rules = [_]Rule{.{ .id = "r", .name = "r", .all = &.{.{ .subject = "s", .predicate = "p", .object = "o" }}, .outputs = &outputs }};
    var result = try evaluate(std.testing.allocator, .{ .facts = &facts, .rules = &rules });
    defer result.deinit();

    try std.testing.expectEqualStrings("pending", result.emitted_obligations[0].status);
    try std.testing.expectEqual(false, result.emitted_obligations[0].executed);
    try std.testing.expectEqual(false, result.emitted_obligations[0].treated_as_proof);
    try std.testing.expectEqual(true, result.emitted_obligations[0].non_authorizing);
}

test "rule firing does not produce proof support or mutation flags" {
    const facts = [_]Fact{.{ .subject = "s", .predicate = "p", .object = "o" }};
    const outputs = [_]RuleOutput{.{ .kind = .risk_candidate, .id = "risk", .summary = "risk" }};
    const rules = [_]Rule{.{ .id = "r", .name = "r", .all = &.{.{ .subject = "s", .predicate = "p", .object = "o" }}, .outputs = &outputs }};
    var result = try evaluate(std.testing.allocator, .{ .facts = &facts, .rules = &rules });
    defer result.deinit();

    try std.testing.expectEqual(true, result.non_authorizing);
    try std.testing.expectEqual(false, result.safety_flags.commands_executed);
    try std.testing.expectEqual(false, result.safety_flags.verifiers_executed);
    try std.testing.expectEqual(false, result.safety_flags.corpus_mutation);
    try std.testing.expectEqual(false, result.safety_flags.pack_mutation);
    try std.testing.expectEqual(false, result.safety_flags.negative_knowledge_mutation);
    try std.testing.expectEqual(false, result.safety_flags.proof_discharged);
    try std.testing.expectEqual(false, result.safety_flags.support_granted);
}

test "validateRule validates required fields and conditions" {
    const valid_outputs = [_]RuleOutput{.{ .kind = .unknown, .id = "out1", .summary = "sum" }};
    const valid_rule = Rule{
        .id = "rule1",
        .name = "name1",
        .all = &.{.{ .subject = "subj", .predicate = "pred" }},
        .outputs = &valid_outputs,
    };

    // Valid minimal rule passes
    try validateRule(valid_rule);

    // Empty id rejected
    var invalid_rule = valid_rule;
    invalid_rule.id = "";
    try std.testing.expectError(error.InvalidRule, validateRule(invalid_rule));

    // Empty name rejected
    invalid_rule = valid_rule;
    invalid_rule.name = "";
    try std.testing.expectError(error.InvalidRule, validateRule(invalid_rule));

    // Missing both all/any conditions rejected
    invalid_rule = valid_rule;
    invalid_rule.all = &.{};
    invalid_rule.any = &.{};
    try std.testing.expectError(error.InvalidRule, validateRule(invalid_rule));

    // Missing outputs rejected
    invalid_rule = valid_rule;
    invalid_rule.outputs = &.{};
    try std.testing.expectError(error.InvalidRule, validateRule(invalid_rule));

    // Empty condition subject rejected
    invalid_rule = valid_rule;
    invalid_rule.all = &.{.{ .subject = "", .predicate = "pred" }};
    try std.testing.expectError(error.InvalidRule, validateRule(invalid_rule));

    // Empty condition predicate rejected
    invalid_rule = valid_rule;
    invalid_rule.all = &.{.{ .subject = "subj", .predicate = "" }};
    try std.testing.expectError(error.InvalidRule, validateRule(invalid_rule));

    // Empty output id rejected
    const invalid_output_id = [_]RuleOutput{.{ .kind = .unknown, .id = "", .summary = "sum" }};
    invalid_rule = valid_rule;
    invalid_rule.outputs = &invalid_output_id;
    try std.testing.expectError(error.InvalidRule, validateRule(invalid_rule));

    // Empty output summary rejected
    const invalid_output_summary = [_]RuleOutput{.{ .kind = .unknown, .id = "out1", .summary = "" }};
    invalid_rule = valid_rule;
    invalid_rule.outputs = &invalid_output_summary;
    try std.testing.expectError(error.InvalidRule, validateRule(invalid_rule));

    // Output kind .fact rejected
    const invalid_output_fact = [_]RuleOutput{.{ .kind = .fact, .id = "out1", .summary = "sum" }};
    invalid_rule = valid_rule;
    invalid_rule.outputs = &invalid_output_fact;
    try std.testing.expectError(error.InvalidRule, validateRule(invalid_rule));
}
