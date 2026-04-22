const std = @import("std");
const code_intel = @import("code_intel.zig");
const mc = @import("inference.zig");
const patch_candidates = @import("patch_candidates.zig");

pub const RENDERING_MODEL = "ghost_technical_renderer_v1";

pub const DraftType = enum {
    proof_backed_explanation,
    refactor_plan,
    contradiction_report,
    code_change_summary,
    technical_design_alternatives,
};

pub const ClaimStatus = enum {
    supported,
    unresolved,
    novel_but_unverified,
    rejected,
};

pub const Source = union(enum) {
    code_intel: *const code_intel.Result,
    patch_candidates: *const patch_candidates.Result,
};

pub const Options = struct {
    draft_type: DraftType = .proof_backed_explanation,
    max_items: usize = 6,
};

pub fn render(allocator: std.mem.Allocator, source: Source, options: Options) ![]u8 {
    return switch (source) {
        .code_intel => |result| renderCodeIntel(allocator, result, options),
        .patch_candidates => |result| renderPatchCandidates(allocator, result, options),
    };
}

pub fn draftTypeName(draft_type: DraftType) []const u8 {
    return switch (draft_type) {
        .proof_backed_explanation => "proof-backed-explanation",
        .refactor_plan => "refactor-plan",
        .contradiction_report => "contradiction-report",
        .code_change_summary => "code-change-summary",
        .technical_design_alternatives => "technical-design-alternatives",
    };
}

pub fn parseDraftType(text: []const u8) ?DraftType {
    if (std.mem.eql(u8, text, "proof-backed-explanation") or std.mem.eql(u8, text, "proof_backed_explanation")) {
        return .proof_backed_explanation;
    }
    if (std.mem.eql(u8, text, "refactor-plan") or std.mem.eql(u8, text, "refactor_plan")) {
        return .refactor_plan;
    }
    if (std.mem.eql(u8, text, "contradiction-report") or std.mem.eql(u8, text, "contradiction_report")) {
        return .contradiction_report;
    }
    if (std.mem.eql(u8, text, "code-change-summary") or std.mem.eql(u8, text, "code_change_summary")) {
        return .code_change_summary;
    }
    if (std.mem.eql(u8, text, "technical-design-alternatives") or std.mem.eql(u8, text, "technical_design_alternatives")) {
        return .technical_design_alternatives;
    }
    return null;
}

pub fn claimStatusName(status: ClaimStatus) []const u8 {
    return @tagName(status);
}

fn renderCodeIntel(allocator: std.mem.Allocator, result: *const code_intel.Result, options: Options) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const writer = out.writer();

    const status = classifyCodeIntel(result, options.draft_type);
    try writeHeader(writer, options.draft_type, status, "code_intel", result.reasoning_mode);
    try writeQuerySectionCodeIntel(writer, result);

    switch (options.draft_type) {
        .proof_backed_explanation => try renderCodeIntelExplanation(writer, result, status, options.max_items),
        .refactor_plan => try renderCodeIntelRefactorPlan(writer, result, status, options.max_items),
        .contradiction_report => try renderCodeIntelContradictionReport(writer, result, status, options.max_items),
        .code_change_summary => try renderUnsupportedTemplate(writer, "code_intel does not carry patch hunks or committed code-change deltas"),
        .technical_design_alternatives => try renderCodeIntelAlternatives(writer, result, status, options.max_items),
    }

    try writeCodeIntelLimits(writer, result);
    return out.toOwnedSlice();
}

fn renderPatchCandidates(allocator: std.mem.Allocator, result: *const patch_candidates.Result, options: Options) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const writer = out.writer();

    const status = classifyPatchCandidates(result, options.draft_type);
    try writeHeader(writer, options.draft_type, status, "patch_candidates", .proof);
    try writeQuerySectionPatch(writer, result);

    switch (options.draft_type) {
        .proof_backed_explanation => try renderPatchExplanation(writer, result, status, options.max_items),
        .refactor_plan => try renderPatchRefactorPlan(writer, result, status, options.max_items),
        .contradiction_report => try renderPatchContradictionReport(writer, result, status, options.max_items),
        .code_change_summary => try renderPatchCodeChangeSummary(writer, result, status, options.max_items),
        .technical_design_alternatives => try renderPatchAlternatives(writer, result, status, options.max_items),
    }

    try writePatchLimits(writer, result);
    return out.toOwnedSlice();
}

fn classifyCodeIntel(result: *const code_intel.Result, draft_type: DraftType) ClaimStatus {
    return switch (draft_type) {
        .technical_design_alternatives => if (result.target_candidates.len > 0 or result.query_hypotheses.len > 0) .novel_but_unverified else .unresolved,
        .refactor_plan => if (result.refactor_path.len == 0) .unresolved else baseCodeIntelStatus(result),
        .contradiction_report => if (result.contradiction_traces.len == 0 and result.contradiction_kind == null) .unresolved else baseCodeIntelStatus(result),
        .code_change_summary => .unresolved,
        .proof_backed_explanation => baseCodeIntelStatus(result),
    };
}

fn baseCodeIntelStatus(result: *const code_intel.Result) ClaimStatus {
    if (result.status != .supported or result.stop_reason != .none) return .unresolved;
    if (result.reasoning_mode != .proof) return .novel_but_unverified;
    return .supported;
}

fn classifyPatchCandidates(result: *const patch_candidates.Result, draft_type: DraftType) ClaimStatus {
    const selected_supported = selectedSupportedCandidate(result) != null;
    return switch (draft_type) {
        .proof_backed_explanation => if (selected_supported) .supported else .unresolved,
        .refactor_plan => if (selected_supported) .supported else if (preferredCandidate(result) != null) .novel_but_unverified else .unresolved,
        .contradiction_report => if (result.contradiction_evidence.len > 0) if (selected_supported) .supported else .novel_but_unverified else .unresolved,
        .code_change_summary => if (selected_supported) .supported else if (preferredCandidate(result) != null) .novel_but_unverified else .unresolved,
        .technical_design_alternatives => if (result.candidates.len > 0 or result.strategy_hypotheses.len > 0) .novel_but_unverified else .unresolved,
    };
}

fn writeHeader(writer: anytype, draft_type: DraftType, status: ClaimStatus, source_name: []const u8, reasoning_mode: mc.ReasoningMode) !void {
    try writer.print(
        "rendering_model: {s}\nsource: {s}\ndraft_type: {s}\nclaim_status: {s}\nreasoning_mode: {s}\nverification_label: {s}\n",
        .{
            RENDERING_MODEL,
            source_name,
            draftTypeName(draft_type),
            claimStatusName(status),
            mc.reasoningModeName(reasoning_mode),
            verificationLabel(status, reasoning_mode),
        },
    );
}

fn verificationLabel(status: ClaimStatus, reasoning_mode: mc.ReasoningMode) []const u8 {
    return switch (status) {
        .supported => if (reasoning_mode == .proof) "proof_backed" else "exploratory_only",
        .novel_but_unverified => "exploratory_only",
        .rejected => "rejected",
        .unresolved => "unresolved",
    };
}

fn writeQuerySectionCodeIntel(writer: anytype, result: *const code_intel.Result) !void {
    try writer.writeAll("\n[query]\n");
    try writer.print("- kind: {s}\n", .{queryKindName(result.query_kind)});
    try writer.print("- target: {s}\n", .{result.query_target});
    if (result.query_other_target) |other| try writer.print("- other_target: {s}\n", .{other});
    try writer.print("- shard: {s}/{s}\n", .{ @tagName(result.shard_kind), result.shard_id });
    try writer.print("- cache_lifecycle: {s}\n", .{@tagName(result.cache_lifecycle)});
}

fn writeQuerySectionPatch(writer: anytype, result: *const patch_candidates.Result) !void {
    try writer.writeAll("\n[query]\n");
    try writer.print("- kind: {s}\n", .{queryKindName(result.query_kind)});
    try writer.print("- target: {s}\n", .{result.target});
    if (result.other_target) |other| try writer.print("- other_target: {s}\n", .{other});
    try writer.print("- request: {s}\n", .{result.request_label});
    try writer.print("- shard: {s}/{s}\n", .{ @tagName(result.shard_kind), result.shard_id });
}

fn renderCodeIntelExplanation(writer: anytype, result: *const code_intel.Result, status: ClaimStatus, max_items: usize) !void {
    try writer.writeAll("\n[summary]\n");
    if (status == .supported) {
        try writer.print("- supported_claim: bounded {s} analysis survived proof-mode selection.\n", .{queryKindName(result.query_kind)});
    } else if (status == .novel_but_unverified) {
        try writer.writeAll("- exploratory_label: bounded analysis produced a candidate explanation, but proof mode did not verify it.\n");
    } else {
        try writer.writeAll("- unresolved_label: no supported explanation can be emitted without guessing.\n");
    }
    if (result.primary) |subject| try writer.print("- primary_subject: {s} at {s}:{d}\n", .{ subject.name, subject.rel_path, subject.line });
    if (result.secondary) |subject| try writer.print("- secondary_subject: {s} at {s}:{d}\n", .{ subject.name, subject.rel_path, subject.line });
    if (result.selected_scope) |scope| try writer.print("- selected_scope: {s}\n", .{scope});
    try writer.print("- confidence: {d}\n", .{result.confidence});
    try writer.print("- stop_reason: {s}\n", .{@tagName(result.stop_reason)});
    if (result.invariant_model) |model| try writer.print("- invariant_model: {s}\n", .{model});

    try writeEvidenceSection(writer, "evidence", result.evidence, max_items);
    try writeSubsystemSection(writer, result.affected_subsystems);
    try writeUnresolvedSection(writer, result.unresolved_detail);
}

fn renderCodeIntelRefactorPlan(writer: anytype, result: *const code_intel.Result, status: ClaimStatus, max_items: usize) !void {
    try writer.writeAll("\n[summary]\n");
    if (status == .supported) {
        try writer.writeAll("- supported_plan: this bounded refactor path remained supported after proof-mode selection.\n");
    } else if (status == .novel_but_unverified) {
        try writer.writeAll("- exploratory_plan: this is a bounded candidate refactor path and must not be treated as verified fact.\n");
    } else {
        try writer.writeAll("- unresolved_plan: the current result does not contain a supportable refactor path.\n");
    }
    if (result.selected_scope) |scope| try writer.print("- selected_scope: {s}\n", .{scope});
    if (result.primary) |subject| try writer.print("- anchor_subject: {s} at {s}:{d}\n", .{ subject.name, subject.rel_path, subject.line });
    try writer.print("- confidence: {d}\n", .{result.confidence});

    try writer.writeAll("\n[plan_steps]\n");
    if (result.refactor_path.len == 0) {
        try writer.writeAll("- none\n");
    } else {
        const count = @min(result.refactor_path.len, max_items);
        for (result.refactor_path[0..count], 0..) |item, idx| {
            try writer.print("{d}. touch {s}:{d} because {s}\n", .{ idx + 1, item.rel_path, item.line, item.reason });
        }
    }

    try writeEvidenceSection(writer, "supporting_evidence", result.evidence, max_items);
    try writeUnresolvedSection(writer, result.unresolved_detail);
}

fn renderCodeIntelContradictionReport(writer: anytype, result: *const code_intel.Result, status: ClaimStatus, max_items: usize) !void {
    try writer.writeAll("\n[summary]\n");
    switch (status) {
        .supported => try writer.writeAll("- supported_report: the contradiction surface remained supported in proof mode.\n"),
        .novel_but_unverified => try writer.writeAll("- exploratory_report: contradiction candidates exist, but they are not proof-backed.\n"),
        else => try writer.writeAll("- unresolved_report: no contradiction report can be emitted as verified fact.\n"),
    }
    if (result.contradiction_kind) |kind| try writer.print("- contradiction_kind: {s}\n", .{kind});
    if (result.primary) |subject| try writer.print("- left_subject: {s} at {s}:{d}\n", .{ subject.name, subject.rel_path, subject.line });
    if (result.secondary) |subject| try writer.print("- right_subject: {s} at {s}:{d}\n", .{ subject.name, subject.rel_path, subject.line });

    try writer.writeAll("\n[contradictions]\n");
    if (result.contradiction_traces.len == 0) {
        try writer.writeAll("- none\n");
    } else {
        const count = @min(result.contradiction_traces.len, max_items);
        for (result.contradiction_traces[0..count]) |item| {
            if (item.owner) |owner| {
                try writer.print("- {s}:{d} {s}; owner={s}; reason={s}\n", .{ item.rel_path, item.line, item.category, owner, item.reason });
            } else {
                try writer.print("- {s}:{d} {s}; reason={s}\n", .{ item.rel_path, item.line, item.category, item.reason });
            }
        }
    }

    try writeEvidenceSection(writer, "supporting_evidence", result.evidence, max_items);
    try writeUnresolvedSection(writer, result.unresolved_detail);
}

fn renderCodeIntelAlternatives(writer: anytype, result: *const code_intel.Result, status: ClaimStatus, max_items: usize) !void {
    _ = status;
    try writer.writeAll("\n[summary]\n");
    try writer.writeAll("- exploratory_label: the items below are bounded candidate surfaces and hypotheses, not verified fact.\n");

    try writer.writeAll("\n[target_candidates]\n");
    if (result.target_candidates.len == 0) {
        try writer.writeAll("- none\n");
    } else {
        const count = @min(result.target_candidates.len, max_items);
        for (result.target_candidates[0..count], 0..) |item, idx| {
            try writer.print("{d}. {s}; score={d}; evidence_count={d}\n", .{ idx + 1, item.label, item.score, item.evidence_count });
        }
    }

    try writer.writeAll("\n[query_hypotheses]\n");
    if (result.query_hypotheses.len == 0) {
        try writer.writeAll("- none\n");
    } else {
        const count = @min(result.query_hypotheses.len, max_items);
        for (result.query_hypotheses[0..count], 0..) |item, idx| {
            try writer.print("{d}. {s}; score={d}; evidence_count={d}\n", .{ idx + 1, item.label, item.score, item.evidence_count });
        }
    }

    try writeUnresolvedSection(writer, "candidate lists are exploratory only until a proof-backed result selects and supports one branch");
}

fn renderPatchExplanation(writer: anytype, result: *const patch_candidates.Result, status: ClaimStatus, max_items: usize) !void {
    const candidate = selectedSupportedCandidate(result);

    try writer.writeAll("\n[summary]\n");
    if (status == .supported and candidate != null) {
        try writer.writeAll("- supported_claim: the final patch summary is backed by proof-mode verification and bounded winner selection.\n");
    } else {
        try writer.writeAll("- unresolved_label: no proof-backed final explanation is available.\n");
    }
    try writer.print("- refactor_plan_status: {s}\n", .{@tagName(result.refactor_plan_status)});
    try writer.print("- confidence: {d}\n", .{result.confidence});
    try writer.print("- stop_reason: {s}\n", .{@tagName(result.stop_reason)});
    if (result.selected_strategy) |strategy| try writer.print("- selected_strategy: {s}\n", .{strategy});
    if (result.selected_scope) |scope| try writer.print("- selected_scope: {s}\n", .{scope});
    if (result.selected_refactor_scope) |scope| try writer.print("- selected_refactor_scope: {s}\n", .{scope});
    if (result.minimality_model) |model| try writer.print("- minimality_model: {s}\n", .{model});

    if (candidate) |item| {
        try writer.writeAll("\n[selected_candidate]\n");
        try writeCandidateSummary(writer, item, max_items);
    }

    try writeSupportTraceSection(writer, "invariant_evidence", result.invariant_evidence, max_items);
    try writeSupportTraceSection(writer, "contradiction_evidence", result.contradiction_evidence, max_items);
    try writeUnresolvedSection(writer, result.unresolved_detail);
}

fn renderPatchRefactorPlan(writer: anytype, result: *const patch_candidates.Result, status: ClaimStatus, max_items: usize) !void {
    const candidate = selectedSupportedCandidate(result) orelse preferredCandidate(result);

    try writer.writeAll("\n[summary]\n");
    switch (status) {
        .supported => try writer.writeAll("- supported_plan: the selected plan passed bounded proof verification on Linux.\n"),
        .novel_but_unverified => try writer.writeAll("- exploratory_plan: the selected plan is a bounded draft candidate and is not verified fact.\n"),
        else => try writer.writeAll("- unresolved_plan: no bounded plan survived to a supportable final output.\n"),
    }
    if (candidate) |item| {
        try writer.print("- candidate_id: {s}\n", .{item.id});
        try writer.print("- strategy: {s}\n", .{item.strategy});
        try writer.print("- scope: {s}\n", .{item.scope});
        try writer.print("- minimality_total_cost: {d}\n", .{item.minimality.total_cost});
    }

    try writer.writeAll("\n[plan_steps]\n");
    if (candidate) |item| {
        if (item.hunks.len == 0) {
            try writer.writeAll("- none\n");
        } else {
            const count = @min(item.hunks.len, max_items);
            for (item.hunks[0..count], 0..) |hunk, idx| {
                try writer.print("{d}. edit {s}:{d}-{d} around anchor {d}\n", .{
                    idx + 1,
                    hunk.rel_path,
                    hunk.start_line,
                    hunk.end_line,
                    hunk.anchor_line,
                });
            }
        }
    } else {
        try writer.writeAll("- none\n");
    }

    if (candidate) |item| {
        try writer.writeAll("\n[verification]\n");
        try writeVerification(writer, item);
    }

    try writeUnresolvedSection(writer, result.unresolved_detail);
}

fn renderPatchContradictionReport(writer: anytype, result: *const patch_candidates.Result, status: ClaimStatus, max_items: usize) !void {
    try writer.writeAll("\n[summary]\n");
    switch (status) {
        .supported => try writer.writeAll("- supported_report: contradiction evidence informed a proof-backed patch decision.\n"),
        .novel_but_unverified => try writer.writeAll("- exploratory_report: contradiction evidence exists, but the final patch was not proof-backed.\n"),
        else => try writer.writeAll("- unresolved_report: no contradiction-backed final statement can be emitted.\n"),
    }
    if (result.contradiction_kind) |kind| try writer.print("- contradiction_kind: {s}\n", .{kind});
    if (result.selected_candidate_id) |candidate_id| try writer.print("- selected_candidate_id: {s}\n", .{candidate_id});

    try writeSupportTraceSection(writer, "contradictions", result.contradiction_evidence, max_items);
    try writeSupportTraceSection(writer, "invariant_context", result.invariant_evidence, max_items);
    try writeUnresolvedSection(writer, result.unresolved_detail);
}

fn renderPatchCodeChangeSummary(writer: anytype, result: *const patch_candidates.Result, status: ClaimStatus, max_items: usize) !void {
    const candidate = selectedSupportedCandidate(result) orelse preferredCandidate(result);

    try writer.writeAll("\n[summary]\n");
    switch (status) {
        .supported => try writer.writeAll("- supported_summary: this code-change summary is backed by the selected verified survivor.\n"),
        .novel_but_unverified => try writer.writeAll("- exploratory_summary: this code-change summary describes a bounded draft candidate only.\n"),
        else => try writer.writeAll("- unresolved_summary: there is no supportable final code-change summary.\n"),
    }

    if (candidate) |item| {
        try writer.print("- candidate_id: {s}\n", .{item.id});
        try writer.print("- status: {s}\n", .{@tagName(item.status)});
        try writer.print("- validation_state: {s}\n", .{@tagName(item.validation_state)});
        try writer.print("- summary_text: {s}\n", .{item.summary});
    }

    try writer.writeAll("\n[changed_files]\n");
    if (candidate) |item| {
        if (item.files.len == 0) {
            try writer.writeAll("- none\n");
        } else {
            const count = @min(item.files.len, max_items);
            for (item.files[0..count]) |path| try writer.print("- {s}\n", .{path});
        }
    } else {
        try writer.writeAll("- none\n");
    }

    try writer.writeAll("\n[hunks]\n");
    if (candidate) |item| {
        if (item.hunks.len == 0) {
            try writer.writeAll("- none\n");
        } else {
            const count = @min(item.hunks.len, max_items);
            for (item.hunks[0..count]) |hunk| {
                try writer.print("- {s}:{d}-{d}\n", .{ hunk.rel_path, hunk.start_line, hunk.end_line });
            }
        }
    } else {
        try writer.writeAll("- none\n");
    }

    if (candidate) |item| {
        try writer.writeAll("\n[verification]\n");
        try writeVerification(writer, item);
    }
    try writeUnresolvedSection(writer, result.unresolved_detail);
}

fn renderPatchAlternatives(writer: anytype, result: *const patch_candidates.Result, status: ClaimStatus, max_items: usize) !void {
    _ = status;
    try writer.writeAll("\n[summary]\n");
    try writer.writeAll("- exploratory_label: alternatives are listed for comparison and must not be relabeled as verified fact.\n");

    try writer.writeAll("\n[strategy_hypotheses]\n");
    if (result.strategy_hypotheses.len == 0) {
        try writer.writeAll("- none\n");
    } else {
        const hypothesis_count = @min(result.strategy_hypotheses.len, max_items);
        for (result.strategy_hypotheses[0..hypothesis_count], 0..) |item, idx| {
            try writer.print("{d}. {s}; score={d}; evidence_count={d}\n", .{ idx + 1, item.label, item.score, item.evidence_count });
        }
    }

    try writer.writeAll("\n[candidates]\n");
    if (result.candidates.len == 0) {
        try writer.writeAll("- none\n");
    } else {
        const candidate_count = @min(result.candidates.len, max_items);
        for (result.candidates[0..candidate_count], 0..) |item, idx| {
            try writer.print(
                "{d}. id={s}; status={s}; validation_state={s}; strategy={s}; scope={s}; summary={s}\n",
                .{ idx + 1, item.id, @tagName(item.status), @tagName(item.validation_state), item.strategy, item.scope, item.summary },
            );
        }
    }

    try writeUnresolvedSection(writer, "alternatives outside the final supported survivor remain exploratory unless proof mode explicitly selects them");
}

fn writeEvidenceSection(writer: anytype, section_name: []const u8, items: []const code_intel.Evidence, max_items: usize) !void {
    try writer.print("\n[{s}]\n", .{section_name});
    if (items.len == 0) {
        try writer.writeAll("- none\n");
        return;
    }

    const count = @min(items.len, max_items);
    for (items[0..count]) |item| {
        try writer.print("- {s}:{d} {s}; subsystem={s}\n", .{ item.rel_path, item.line, item.reason, item.subsystem });
    }
}

fn writeSupportTraceSection(writer: anytype, section_name: []const u8, items: []const patch_candidates.SupportTrace, max_items: usize) !void {
    try writer.print("\n[{s}]\n", .{section_name});
    if (items.len == 0) {
        try writer.writeAll("- none\n");
        return;
    }

    const count = @min(items.len, max_items);
    for (items[0..count]) |item| {
        if (item.rel_path) |rel_path| {
            if (item.reason) |reason| {
                try writer.print("- {s}:{d} {s}; score={d}; kind={s}; reason={s}\n", .{
                    rel_path,
                    item.line,
                    item.label,
                    item.score,
                    @tagName(item.kind),
                    reason,
                });
            } else {
                try writer.print("- {s}:{d} {s}; score={d}; kind={s}\n", .{
                    rel_path,
                    item.line,
                    item.label,
                    item.score,
                    @tagName(item.kind),
                });
            }
        } else if (item.reason) |reason| {
            try writer.print("- {s}; score={d}; kind={s}; reason={s}\n", .{
                item.label,
                item.score,
                @tagName(item.kind),
                reason,
            });
        } else {
            try writer.print("- {s}; score={d}; kind={s}\n", .{
                item.label,
                item.score,
                @tagName(item.kind),
            });
        }
    }
}

fn writeSubsystemSection(writer: anytype, subsystems: anytype) !void {
    try writer.writeAll("\n[affected_subsystems]\n");
    if (subsystems.len == 0) {
        try writer.writeAll("- none\n");
        return;
    }
    for (subsystems) |item| try writer.print("- {s}\n", .{@tagName(item)});
}

fn writeUnresolvedSection(writer: anytype, detail: ?[]const u8) !void {
    try writer.writeAll("\n[unresolved]\n");
    if (detail) |text| {
        try writer.print("- {s}\n", .{text});
    } else {
        try writer.writeAll("- none\n");
    }
}

fn writeCandidateSummary(writer: anytype, candidate: *const patch_candidates.Candidate, max_items: usize) !void {
    try writer.print("- id: {s}\n", .{candidate.id});
    try writer.print("- summary: {s}\n", .{candidate.summary});
    try writer.print("- strategy: {s}\n", .{candidate.strategy});
    try writer.print("- scope: {s}\n", .{candidate.scope});
    try writer.print("- status: {s}\n", .{@tagName(candidate.status)});
    try writer.print("- validation_state: {s}\n", .{@tagName(candidate.validation_state)});
    try writer.print("- proof_score: {d}\n", .{candidate.verification.proof_score});
    if (candidate.status_reason) |reason| try writer.print("- status_reason: {s}\n", .{reason});
    if (candidate.verification.proof_reason) |reason| try writer.print("- proof_reason: {s}\n", .{reason});

    try writer.writeAll("\n[selected_candidate_files]\n");
    if (candidate.files.len == 0) {
        try writer.writeAll("- none\n");
    } else {
        const file_count = @min(candidate.files.len, max_items);
        for (candidate.files[0..file_count]) |path| try writer.print("- {s}\n", .{path});
    }
}

fn writeVerification(writer: anytype, candidate: *const patch_candidates.Candidate) !void {
    try writer.print("- build_state: {s}\n", .{@tagName(candidate.verification.build.state)});
    if (candidate.verification.build.command) |command| try writer.print("- build_command: {s}\n", .{command});
    if (candidate.verification.build.summary) |summary| try writer.print("- build_summary: {s}\n", .{summary});
    try writer.print("- test_state: {s}\n", .{@tagName(candidate.verification.test_step.state)});
    if (candidate.verification.test_step.command) |command| try writer.print("- test_command: {s}\n", .{command});
    if (candidate.verification.test_step.summary) |summary| try writer.print("- test_summary: {s}\n", .{summary});
    try writer.print("- runtime_state: {s}\n", .{@tagName(candidate.verification.runtime_step.state)});
    if (candidate.verification.runtime_step.command) |command| try writer.print("- runtime_command: {s}\n", .{command});
    if (candidate.verification.runtime_step.summary) |summary| try writer.print("- runtime_summary: {s}\n", .{summary});
    if (candidate.verification.refinements.len > 0) {
        try writer.print("- refinement_count: {d}\n", .{candidate.verification.refinements.len});
        const first = candidate.verification.refinements[0];
        try writer.print("- first_refinement: {s}; retained_hunks={d}\n", .{ first.label, first.retained_hunk_count });
    }
    try writer.print("- proof_score: {d}\n", .{candidate.verification.proof_score});
    try writer.print("- proof_confidence: {d}\n", .{candidate.verification.proof_confidence});
    if (candidate.verification.proof_reason) |reason| try writer.print("- proof_reason: {s}\n", .{reason});
}

fn writeCodeIntelLimits(writer: anytype, result: *const code_intel.Result) !void {
    try writer.writeAll("\n[current_limits]\n");
    try writer.writeAll("- renderer consumes bounded code_intel traces only; it does not infer missing facts.\n");
    try writer.writeAll("- supported final claims require proof reasoning mode plus a supported status.\n");
    try writer.writeAll("- candidate alternatives remain exploratory even when they are ranked.\n");
    if (result.unresolved_detail) |detail| {
        try writer.print("- current_result_limit: {s}\n", .{detail});
    }
}

fn writePatchLimits(writer: anytype, result: *const patch_candidates.Result) !void {
    try writer.writeAll("\n[current_limits]\n");
    try writer.writeAll("- renderer reuses bounded candidate traces and verification traces; it does not synthesize extra code changes.\n");
    try writer.writeAll("- supported final plans require the proof-backed selected survivor.\n");
    try writer.writeAll("- preserved alternatives stay labeled novel_but_unverified or rejected.\n");
    if (result.unresolved_detail) |detail| {
        try writer.print("- current_result_limit: {s}\n", .{detail});
    }
}

fn renderUnsupportedTemplate(writer: anytype, reason: []const u8) !void {
    try writer.writeAll("\n[summary]\n");
    try writer.writeAll("- unresolved_template: this template is defined, but the current source payload is insufficient.\n");
    try writeUnresolvedSection(writer, reason);
}

fn selectedSupportedCandidate(result: *const patch_candidates.Result) ?*const patch_candidates.Candidate {
    if (result.selected_candidate_id) |candidate_id| {
        for (result.candidates) |*candidate| {
            if (candidate.status == .supported and std.mem.eql(u8, candidate.id, candidate_id)) return candidate;
        }
    }
    for (result.candidates) |*candidate| {
        if (candidate.status == .supported) return candidate;
    }
    return null;
}

fn preferredCandidate(result: *const patch_candidates.Result) ?*const patch_candidates.Candidate {
    if (result.selected_candidate_id) |candidate_id| {
        for (result.candidates) |*candidate| {
            if (std.mem.eql(u8, candidate.id, candidate_id)) return candidate;
        }
    }
    var best_novel: ?*const patch_candidates.Candidate = null;
    var best_unresolved: ?*const patch_candidates.Candidate = null;
    var best_rejected: ?*const patch_candidates.Candidate = null;

    for (result.candidates) |*candidate| {
        switch (candidate.status) {
            .supported => return candidate,
            .novel_but_unverified => {
                if (best_novel == null or candidate.exploration_rank < best_novel.?.exploration_rank) best_novel = candidate;
            },
            .unresolved => {
                if (best_unresolved == null or candidate.exploration_rank < best_unresolved.?.exploration_rank) best_unresolved = candidate;
            },
            .rejected => {
                if (best_rejected == null or candidate.exploration_rank < best_rejected.?.exploration_rank) best_rejected = candidate;
            },
        }
    }

    return best_novel orelse best_unresolved orelse best_rejected;
}

fn queryKindName(kind: code_intel.QueryKind) []const u8 {
    return switch (kind) {
        .impact => "impact",
        .breaks_if => "breaks-if",
        .contradicts => "contradicts",
    };
}

test "code_intel exploratory alternatives stay labeled novel_but_unverified" {
    const allocator = std.testing.allocator;

    var target_candidates = try allocator.alloc(code_intel.CandidateTrace, 1);
    defer {
        allocator.free(target_candidates[0].label);
        allocator.free(target_candidates);
    }
    target_candidates[0] = .{
        .label = try allocator.dupe(u8, "src/engine.zig"),
        .score = 210,
        .evidence_count = 2,
    };

    var result = code_intel.Result{
        .allocator = allocator,
        .status = .supported,
        .query_kind = .impact,
        .query_target = try allocator.dupe(u8, "engine"),
        .repo_root = try allocator.dupe(u8, "/repo"),
        .shard_root = try allocator.dupe(u8, "/repo/platforms/linux/x86_64/state/shards/core/core"),
        .shard_id = try allocator.dupe(u8, "core"),
        .shard_kind = .core,
        .reasoning_mode = .exploratory,
        .target_candidates = target_candidates,
    };
    defer result.deinit();

    const rendered = try render(allocator, .{ .code_intel = &result }, .{ .draft_type = .technical_design_alternatives });
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "claim_status: novel_but_unverified") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "exploratory_label") != null);
}

test "patch candidate refactor plan exposes proof-backed support" {
    const allocator = std.testing.allocator;

    var files = try allocator.alloc([]u8, 1);
    files[0] = try allocator.dupe(u8, "src/technical_drafts.zig");

    var hunks = try allocator.alloc(patch_candidates.PatchHunk, 1);
    hunks[0] = .{
        .rel_path = try allocator.dupe(u8, "src/technical_drafts.zig"),
        .anchor_line = 42,
        .start_line = 40,
        .end_line = 48,
        .diff = try allocator.dupe(u8, "@@"),
    };

    var candidates = try allocator.alloc(patch_candidates.Candidate, 1);
    candidates[0] = .{
        .id = try allocator.dupe(u8, "cand-1"),
        .summary = try allocator.dupe(u8, "Add deterministic draft renderer"),
        .strategy = try allocator.dupe(u8, "seam_adapter"),
        .scope = try allocator.dupe(u8, "focused_single_surface"),
        .status = .supported,
        .validation_state = .verified_supported,
        .exploration_rank = 1,
        .score = 260,
        .files = files,
        .hunks = hunks,
        .verification = .{
            .build = .{ .state = .passed, .summary = try allocator.dupe(u8, "zig build passed") },
            .test_step = .{ .state = .passed, .summary = try allocator.dupe(u8, "renderer tests passed") },
            .proof_score = 260,
            .proof_confidence = 260,
            .proof_reason = try allocator.dupe(u8, "proof mode selected this verified survivor"),
        },
    };

    var result = patch_candidates.Result{
        .allocator = allocator,
        .status = .supported,
        .query_kind = .breaks_if,
        .target = try allocator.dupe(u8, "technical_drafts"),
        .request_label = try allocator.dupe(u8, "draft layer"),
        .repo_root = try allocator.dupe(u8, "/repo"),
        .shard_id = try allocator.dupe(u8, "core"),
        .shard_root = try allocator.dupe(u8, "/repo/platforms/linux/x86_64/state/shards/core/core"),
        .shard_kind = .core,
        .stop_reason = .none,
        .confidence = 260,
        .refactor_plan_status = .verified_supported,
        .selected_strategy = try allocator.dupe(u8, "seam_adapter"),
        .selected_scope = try allocator.dupe(u8, "focused_single_surface"),
        .selected_refactor_scope = try allocator.dupe(u8, "focused_single_surface"),
        .selected_candidate_id = try allocator.dupe(u8, "cand-1"),
        .code_intel_result_path = try allocator.dupe(u8, "/repo/last_result.json"),
        .caps = .{},
        .candidates = candidates,
    };
    defer result.deinit();

    const rendered = try render(allocator, .{ .patch_candidates = &result }, .{ .draft_type = .refactor_plan });
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "claim_status: supported") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "supported_plan") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "edit src/technical_drafts.zig:40-48") != null);
}
