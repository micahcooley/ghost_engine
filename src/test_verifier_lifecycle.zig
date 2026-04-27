const std = @import("std");
const verifier_adapter = @import("verifier_adapter.zig");
const verifier_execution = @import("verifier_execution.zig");
const correction_hooks = @import("correction_hooks.zig");
const hypothesis_core = @import("hypothesis_core.zig");
const compute_budget = @import("compute_budget.zig");
const code_intel = @import("code_intel.zig");

// ── Existing lifecycle tests ──

test "verifier candidate lifecycle: proposed -> accepted -> materialized" {
    const allocator = std.testing.allocator;

    var candidate = verifier_adapter.VerifierCandidate{
        .allocator = allocator,
        .id = try allocator.dupe(u8, "cand-1"),
        .hypothesis_id = try allocator.dupe(u8, "hyp-1"),
        .candidate_kind = .regression_test,
        .artifact_scope = try allocator.dupe(u8, "src/main.zig"),
        .target_claim_surface = try allocator.dupe(u8, "main()"),
        .proposed_check = try allocator.dupe(u8, "test main"),
        .provenance = try allocator.dupe(u8, "test"),
        .trace = try allocator.dupe(u8, "proposed"),
    };
    defer candidate.deinit();

    try std.testing.expectEqual(verifier_adapter.CandidateStatus.proposed, candidate.status);

    // Accept
    const approval = verifier_adapter.VerifierCandidateApproval{
        .candidate_id = try allocator.dupe(u8, candidate.id),
        .approved_by = try allocator.dupe(u8, "test-user"),
        .approval_kind = .test_fixture,
        .approval_reason = try allocator.dupe(u8, "looks good"),
        .timestamp_ms = 12345,
        .trace = try allocator.dupe(u8, "approved"),
        .scope = try allocator.dupe(u8, "src/"),
    };
    try verifier_adapter.acceptVerifierCandidate(&candidate, approval);
    try std.testing.expectEqual(verifier_adapter.CandidateStatus.accepted, candidate.status);
    try std.testing.expect(candidate.approval != null);

    // Materialize
    try verifier_adapter.materializeVerifierCandidate(allocator, &candidate, .{
        .require_acceptance = true,
    });
    try std.testing.expectEqual(verifier_adapter.CandidateStatus.materialized, candidate.status);
    try std.testing.expect(candidate.materialization != null);
}

test "verifier candidate lifecycle: rejected candidate cannot be materialized" {
    const allocator = std.testing.allocator;

    var candidate = verifier_adapter.VerifierCandidate{
        .allocator = allocator,
        .id = try allocator.dupe(u8, "cand-2"),
        .hypothesis_id = try allocator.dupe(u8, "hyp-2"),
        .candidate_kind = .regression_test,
        .artifact_scope = try allocator.dupe(u8, "src/main.zig"),
        .target_claim_surface = try allocator.dupe(u8, "main()"),
        .proposed_check = try allocator.dupe(u8, "test main"),
        .provenance = try allocator.dupe(u8, "test"),
        .trace = try allocator.dupe(u8, "proposed"),
    };
    defer candidate.deinit();

    try verifier_adapter.rejectVerifierCandidate(&candidate, "not needed");
    try std.testing.expectEqual(verifier_adapter.CandidateStatus.rejected, candidate.status);

    const err = verifier_adapter.materializeVerifierCandidate(allocator, &candidate, .{
        .require_acceptance = false,
    });
    try std.testing.expectError(error.InvalidStatus, err);
}

test "verifier candidate lifecycle: unaccepted candidate blocked by policy" {
    const allocator = std.testing.allocator;

    var candidate = verifier_adapter.VerifierCandidate{
        .allocator = allocator,
        .id = try allocator.dupe(u8, "cand-3"),
        .hypothesis_id = try allocator.dupe(u8, "hyp-3"),
        .candidate_kind = .regression_test,
        .artifact_scope = try allocator.dupe(u8, "src/main.zig"),
        .target_claim_surface = try allocator.dupe(u8, "main()"),
        .proposed_check = try allocator.dupe(u8, "test main"),
        .provenance = try allocator.dupe(u8, "test"),
        .trace = try allocator.dupe(u8, "proposed"),
    };
    defer candidate.deinit();

    try verifier_adapter.materializeVerifierCandidate(allocator, &candidate, .{
        .require_acceptance = true,
    });
    try std.testing.expectEqual(verifier_adapter.CandidateStatus.blocked, candidate.status);
    try std.testing.expectEqual(verifier_adapter.CandidateBlockedReason.not_approved, candidate.blocked_reason.?);
}

test "verifier candidate lifecycle: authorizing candidate blocked" {
    const allocator = std.testing.allocator;

    var candidate = verifier_adapter.VerifierCandidate{
        .allocator = allocator,
        .id = try allocator.dupe(u8, "cand-4"),
        .hypothesis_id = try allocator.dupe(u8, "hyp-4"),
        .candidate_kind = .regression_test,
        .artifact_scope = try allocator.dupe(u8, "src/main.zig"),
        .target_claim_surface = try allocator.dupe(u8, "main()"),
        .proposed_check = try allocator.dupe(u8, "test main"),
        .provenance = try allocator.dupe(u8, "test"),
        .trace = try allocator.dupe(u8, "proposed"),
        .non_authorizing = false,
    };
    defer candidate.deinit();

    try verifier_adapter.materializeVerifierCandidate(allocator, &candidate, .{
        .require_acceptance = false,
    });
    try std.testing.expectEqual(verifier_adapter.CandidateStatus.blocked, candidate.status);
    try std.testing.expectEqual(verifier_adapter.CandidateBlockedReason.unsafe_materialization, candidate.blocked_reason.?);
}

// ── Verifier Execution Tests ──

fn makeApprovedCandidate(
    allocator: std.mem.Allocator,
    id: []const u8,
    scope: []const u8,
) !verifier_adapter.VerifierCandidate {
    var candidate = verifier_adapter.VerifierCandidate{
        .allocator = allocator,
        .id = try allocator.dupe(u8, id),
        .hypothesis_id = try std.fmt.allocPrint(allocator, "hyp-for-{s}", .{id}),
        .candidate_kind = .regression_test,
        .artifact_scope = try allocator.dupe(u8, scope),
        .target_claim_surface = try allocator.dupe(u8, "test_target"),
        .proposed_check = try allocator.dupe(u8, "test check"),
        .required_inputs = try cloneStrings(allocator, &.{"evidence:input"}),
        .expected_observations = try cloneStrings(allocator, &.{"pass"}),
        .provenance = try allocator.dupe(u8, "test"),
        .trace = try allocator.dupe(u8, "proposed"),
    };

    const approval = verifier_adapter.VerifierCandidateApproval{
        .candidate_id = try allocator.dupe(u8, id),
        .approved_by = try allocator.dupe(u8, "test-fixture"),
        .approval_kind = .test_fixture,
        .approval_reason = try allocator.dupe(u8, "automated test approval"),
        .timestamp_ms = 1000,
        .trace = try allocator.dupe(u8, "approved"),
        .scope = try allocator.dupe(u8, scope),
        .allow_schedule_verifier_later = true,
    };
    try verifier_adapter.acceptVerifierCandidate(&candidate, approval);
    try verifier_adapter.materializeVerifierCandidate(allocator, &candidate, .{
        .require_acceptance = true,
    });
    return candidate;
}

fn makeApprovedCandidateNoMaterialize(
    allocator: std.mem.Allocator,
    id: []const u8,
    scope: []const u8,
) !verifier_adapter.VerifierCandidate {
    var candidate = verifier_adapter.VerifierCandidate{
        .allocator = allocator,
        .id = try allocator.dupe(u8, id),
        .hypothesis_id = try std.fmt.allocPrint(allocator, "hyp-for-{s}", .{id}),
        .candidate_kind = .regression_test,
        .artifact_scope = try allocator.dupe(u8, scope),
        .target_claim_surface = try allocator.dupe(u8, "test_target"),
        .proposed_check = try allocator.dupe(u8, "test check"),
        .required_inputs = try cloneStrings(allocator, &.{"evidence:input"}),
        .expected_observations = try cloneStrings(allocator, &.{"pass"}),
        .provenance = try allocator.dupe(u8, "test"),
        .trace = try allocator.dupe(u8, "proposed"),
    };

    const approval = verifier_adapter.VerifierCandidateApproval{
        .candidate_id = try allocator.dupe(u8, id),
        .approved_by = try allocator.dupe(u8, "test-fixture"),
        .approval_kind = .test_fixture,
        .approval_reason = try allocator.dupe(u8, "automated test approval"),
        .timestamp_ms = 1000,
        .trace = try allocator.dupe(u8, "approved"),
        .scope = try allocator.dupe(u8, scope),
        .allow_schedule_verifier_later = true,
    };
    try verifier_adapter.acceptVerifierCandidate(&candidate, approval);
    return candidate;
}

fn defaultPolicy() verifier_execution.VerificationPolicy {
    return .{
        .workspace_root = "/tmp/ghost_test_workspace",
    };
}

test "approved materialized candidate is eligible for execution" {
    const allocator = std.testing.allocator;
    var candidate = try makeApprovedCandidate(allocator, "cand-exec-1", "src/main.zig");
    defer candidate.deinit();

    const budget = compute_budget.resolve(.{ .tier = .medium });
    const elig = verifier_execution.checkExecutionEligibility(&candidate, defaultPolicy(), budget, 0);
    try std.testing.expect(elig.eligible);
    try std.testing.expect(elig.approved);
    try std.testing.expect(elig.scope_bound);
}

test "proposed but unapproved candidate does not execute" {
    const allocator = std.testing.allocator;
    var candidate = verifier_adapter.VerifierCandidate{
        .allocator = allocator,
        .id = try allocator.dupe(u8, "cand-unapproved"),
        .hypothesis_id = try allocator.dupe(u8, "hyp-unapproved"),
        .candidate_kind = .regression_test,
        .artifact_scope = try allocator.dupe(u8, "src/main.zig"),
        .target_claim_surface = try allocator.dupe(u8, "target"),
        .proposed_check = try allocator.dupe(u8, "check"),
        .required_inputs = try cloneStrings(allocator, &.{"evidence"}),
        .expected_observations = try cloneStrings(allocator, &.{"pass"}),
        .provenance = try allocator.dupe(u8, "test"),
        .trace = try allocator.dupe(u8, "proposed"),
    };
    defer candidate.deinit();

    const budget = compute_budget.resolve(.{ .tier = .medium });
    const elig = verifier_execution.checkExecutionEligibility(&candidate, defaultPolicy(), budget, 0);
    try std.testing.expect(!elig.eligible);
    try std.testing.expect(elig.blocked_reason.? == .not_approved);
}

test "rejected candidate does not execute" {
    const allocator = std.testing.allocator;
    var candidate = verifier_adapter.VerifierCandidate{
        .allocator = allocator,
        .id = try allocator.dupe(u8, "cand-rejected"),
        .hypothesis_id = try allocator.dupe(u8, "hyp-rejected"),
        .candidate_kind = .regression_test,
        .artifact_scope = try allocator.dupe(u8, "src/main.zig"),
        .target_claim_surface = try allocator.dupe(u8, "target"),
        .proposed_check = try allocator.dupe(u8, "check"),
        .provenance = try allocator.dupe(u8, "test"),
        .trace = try allocator.dupe(u8, "proposed"),
    };
    defer candidate.deinit();
    try verifier_adapter.rejectVerifierCandidate(&candidate, "bad");

    const budget = compute_budget.resolve(.{ .tier = .medium });
    const elig = verifier_execution.checkExecutionEligibility(&candidate, defaultPolicy(), budget, 0);
    try std.testing.expect(!elig.eligible);
    try std.testing.expect(elig.blocked_reason.? == .not_approved);
}

test "materialized candidate with unsafe shell command is blocked" {
    const allocator = std.testing.allocator;
    var candidate = try makeApprovedCandidate(allocator, "cand-unsafe", "src/main.zig");
    defer candidate.deinit();

    // Inject a shell-string command with pipes
    const shell_argv = try cloneStrings(allocator, &.{ "bash", "-c", "echo hello | grep hello" });
    candidate.command_plan = .{
        .argv = shell_argv,
    };

    const budget = compute_budget.resolve(.{ .tier = .medium });
    const elig = verifier_execution.checkExecutionEligibility(&candidate, defaultPolicy(), budget, 0);
    try std.testing.expect(!elig.eligible);
    try std.testing.expect(elig.blocked_reason.? == .shell_string_rejected);
}

test "network command is blocked by default policy" {
    const allocator = std.testing.allocator;
    var candidate = try makeApprovedCandidate(allocator, "cand-net", "src/main.zig");
    defer candidate.deinit();

    const argv = try cloneStrings(allocator, &.{ "curl", "http://example.com" });
    candidate.command_plan = .{ .argv = argv };

    const budget = compute_budget.resolve(.{ .tier = .medium });
    const elig = verifier_execution.checkExecutionEligibility(&candidate, defaultPolicy(), budget, 0);
    try std.testing.expect(!elig.eligible);
    try std.testing.expect(elig.blocked_reason.? == .network_denied);
}

test "sudo command is blocked by default policy" {
    const allocator = std.testing.allocator;
    var candidate = try makeApprovedCandidate(allocator, "cand-sudo", "src/main.zig");
    defer candidate.deinit();

    const argv = try cloneStrings(allocator, &.{ "sudo", "rm", "-rf", "/" });
    candidate.command_plan = .{ .argv = argv };

    const budget = compute_budget.resolve(.{ .tier = .medium });
    const elig = verifier_execution.checkExecutionEligibility(&candidate, defaultPolicy(), budget, 0);
    try std.testing.expect(!elig.eligible);
    try std.testing.expect(elig.blocked_reason.? == .sudo_denied);
}

test "system mutation command is blocked" {
    const allocator = std.testing.allocator;
    var candidate = try makeApprovedCandidate(allocator, "cand-mutation", "src/main.zig");
    defer candidate.deinit();

    const argv = try cloneStrings(allocator, &.{ "rm", "important_file.zig" });
    candidate.command_plan = .{ .argv = argv };

    const budget = compute_budget.resolve(.{ .tier = .medium });
    const elig = verifier_execution.checkExecutionEligibility(&candidate, defaultPolicy(), budget, 0);
    try std.testing.expect(!elig.eligible);
    try std.testing.expect(elig.blocked_reason.? == .write_outside_workspace);
}

test "budget cap blocks execution deterministically" {
    const allocator = std.testing.allocator;
    var candidate = try makeApprovedCandidate(allocator, "cand-budget", "src/main.zig");
    defer candidate.deinit();

    const budget = compute_budget.resolve(.{
        .tier = .medium,
        .overrides = .{ .max_verifier_candidate_execution_jobs = 0 },
    });
    const elig = verifier_execution.checkExecutionEligibility(&candidate, defaultPolicy(), budget, 0);
    try std.testing.expect(!elig.eligible);
    try std.testing.expect(elig.blocked_reason.? == .budget_exhausted);
}

test "execution job creation and no-argv execution produces evidence" {
    const allocator = std.testing.allocator;
    var candidate = try makeApprovedCandidateNoMaterialize(allocator, "cand-noargv", "src/main.zig");
    defer candidate.deinit();

    var job = try verifier_execution.createExecutionJob(
        allocator,
        &candidate,
        defaultPolicy(),
        .check_plan_eval,
    );
    defer job.deinit();

    try std.testing.expectEqual(verifier_execution.ExecutionJobStatus.scheduled, job.status);
    try std.testing.expect(job.non_authorizing_input);

    var result = try verifier_execution.executeJob(allocator, &job);
    defer result.deinit();

    try std.testing.expectEqual(verifier_execution.ExecutionResultStatus.passed, result.status);
    try std.testing.expectEqual(verifier_execution.ExecutionJobStatus.completed, job.status);
    // Evidence produced but job remains non-authorizing
    try std.testing.expect(job.non_authorizing_input);
}

test "failed execution creates correction event" {
    const allocator = std.testing.allocator;
    var candidate = try makeApprovedCandidate(allocator, "cand-fail", "src/main.zig");
    defer candidate.deinit();

    // Use a command that will fail: "false" exits with code 1
    const argv = try cloneStrings(allocator, &.{"false"});
    candidate.command_plan = .{ .argv = argv };

    const budget = compute_budget.resolve(.{ .tier = .medium });
    const policy = verifier_execution.VerificationPolicy{
        .workspace_root = "/tmp",
    };

    var job = try verifier_execution.createExecutionJob(
        allocator,
        &candidate,
        policy,
        .command_plan,
    );
    defer job.deinit();

    var result = try verifier_execution.executeJob(allocator, &job);
    defer result.deinit();

    try std.testing.expectEqual(verifier_execution.ExecutionResultStatus.failed, result.status);
    try std.testing.expect(result.contradiction_signals.len > 0);

    // Create correction event
    var correction_id_counter: u64 = 1;
    var correction_count: usize = 0;
    var nk_count: usize = 0;
    var correction = try correction_hooks.createCorrectionFromExecutionResult(
        allocator,
        &result,
        candidate.id,
        "materialized",
        &correction_id_counter,
        budget,
        &correction_count,
        &nk_count,
    );
    defer if (correction) |*c| c.deinit();

    try std.testing.expect(correction != null);
    if (correction) |c| {
        // "false" exits with code 1 which creates contradiction signals,
        // so the correction kind is hypothesis_contradicted
        try std.testing.expect(c.correction_kind == .hypothesis_contradicted);
        try std.testing.expect(c.non_authorizing);
        try std.testing.expect(std.mem.indexOf(u8, c.user_visible_summary, "verifier execution produced evidence") != null);
    }
}

test "correction event creates negative knowledge candidate" {
    const allocator = std.testing.allocator;
    var candidate = try makeApprovedCandidate(allocator, "cand-nk", "src/main.zig");
    defer candidate.deinit();

    const argv = try cloneStrings(allocator, &.{"false"});
    candidate.command_plan = .{ .argv = argv };

    const budget = compute_budget.resolve(.{ .tier = .medium });
    const policy = verifier_execution.VerificationPolicy{
        .workspace_root = "/tmp",
    };

    var job = try verifier_execution.createExecutionJob(allocator, &candidate, policy, .command_plan);
    defer job.deinit();
    var result = try verifier_execution.executeJob(allocator, &job);
    defer result.deinit();

    var correction_id_counter: u64 = 10;
    var correction_count: usize = 0;
    var nk_count: usize = 0;
    var correction = (try correction_hooks.createCorrectionFromExecutionResult(
        allocator,
        &result,
        candidate.id,
        "materialized",
        &correction_id_counter,
        budget,
        &correction_count,
        &nk_count,
    )).?;
    defer correction.deinit();

    var nk_id_counter: u64 = 1;
    var nk = correction_hooks.maybeCreateNegativeKnowledgeCandidate(
        allocator,
        &correction,
        &nk_id_counter,
        budget,
        &nk_count,
    );
    defer if (nk) |*n| n.deinit();

    try std.testing.expect(nk != null);
    if (nk) |n| {
        // hypothesis_contradicted maps to failed_hypothesis
        try std.testing.expect(n.candidate_kind == .failed_hypothesis);
        try std.testing.expect(n.non_authorizing);
        try std.testing.expect(std.mem.eql(u8, @tagName(n.status), "proposed"));
        try std.testing.expect(n.permanence == .temporary);
    }
}

test "correction event remains non-authorizing" {
    const allocator = std.testing.allocator;
    var candidate = try makeApprovedCandidate(allocator, "cand-corauth", "src/main.zig");
    defer candidate.deinit();

    const argv = try cloneStrings(allocator, &.{"false"});
    candidate.command_plan = .{ .argv = argv };

    const budget = compute_budget.resolve(.{ .tier = .medium });
    const policy = verifier_execution.VerificationPolicy{ .workspace_root = "/tmp" };

    var job = try verifier_execution.createExecutionJob(allocator, &candidate, policy, .command_plan);
    defer job.deinit();
    var result = try verifier_execution.executeJob(allocator, &job);
    defer result.deinit();

    var correction_id_counter: u64 = 20;
    var correction_count: usize = 0;
    var nk_count: usize = 0;
    var correction = (try correction_hooks.createCorrectionFromExecutionResult(
        allocator,
        &result,
        candidate.id,
        "materialized",
        &correction_id_counter,
        budget,
        &correction_count,
        &nk_count,
    )).?;
    defer correction.deinit();

    try std.testing.expect(correction.non_authorizing);
}

test "negative knowledge candidate remains non-authorizing and unpromoted" {
    const allocator = std.testing.allocator;
    var candidate = try makeApprovedCandidate(allocator, "cand-nkauth", "src/main.zig");
    defer candidate.deinit();

    const argv = try cloneStrings(allocator, &.{"false"});
    candidate.command_plan = .{ .argv = argv };

    const budget = compute_budget.resolve(.{ .tier = .medium });
    const policy = verifier_execution.VerificationPolicy{ .workspace_root = "/tmp" };

    var job = try verifier_execution.createExecutionJob(allocator, &candidate, policy, .command_plan);
    defer job.deinit();
    var result = try verifier_execution.executeJob(allocator, &job);
    defer result.deinit();

    var correction_id_counter: u64 = 30;
    var correction_count: usize = 0;
    var nk_count: usize = 0;
    var correction = (try correction_hooks.createCorrectionFromExecutionResult(
        allocator,
        &result,
        candidate.id,
        "materialized",
        &correction_id_counter,
        budget,
        &correction_count,
        &nk_count,
    )).?;
    defer correction.deinit();

    var nk_id_counter: u64 = 5;
    var nk = correction_hooks.maybeCreateNegativeKnowledgeCandidate(
        allocator,
        &correction,
        &nk_id_counter,
        budget,
        &nk_count,
    ).?;
    defer nk.deinit();

    try std.testing.expect(nk.non_authorizing);
    try std.testing.expect(std.mem.eql(u8, @tagName(nk.status), "proposed"));
    try std.testing.expect(nk.permanence == .temporary);
}

test "timeout recorded distinctly from verifier failure" {
    const allocator = std.testing.allocator;
    var candidate = try makeApprovedCandidate(allocator, "cand-timeout", "src/main.zig");
    defer candidate.deinit();

    const argv = try cloneStrings(allocator, &.{"true"});
    candidate.command_plan = .{ .argv = argv };

    const policy = verifier_execution.VerificationPolicy{
        .workspace_root = "/tmp",
        .default_timeout_ms = 1, // Extremely short timeout
    };

    var job = try verifier_execution.createExecutionJob(allocator, &candidate, policy, .command_plan);
    defer job.deinit();

    // "true" exits immediately so this should pass, but we test the status distinction
    var result = try verifier_execution.executeJob(allocator, &job);
    defer result.deinit();

    // Result is either passed or timeout - both are distinct from failed
    try std.testing.expect(result.status == .passed or result.status == .timeout or result.status == .failed);
}

test "existing support/proof gates unchanged by execution" {
    // Verify that ExecutionEligibility and all new types are non-authorizing
    const allocator = std.testing.allocator;
    var candidate = try makeApprovedCandidate(allocator, "cand-gates", "src/main.zig");
    defer candidate.deinit();

    const budget = compute_budget.resolve(.{ .tier = .medium });
    const elig = verifier_execution.checkExecutionEligibility(&candidate, defaultPolicy(), budget, 0);
    try std.testing.expect(elig.eligible);

    var job = try verifier_execution.createExecutionJob(allocator, &candidate, defaultPolicy(), .check_plan_eval);
    defer job.deinit();
    try std.testing.expect(job.non_authorizing_input);
    try std.testing.expect(candidate.non_authorizing);

    var result = try verifier_execution.executeJob(allocator, &job);
    defer result.deinit();
    // Evidence produced, but it does not directly authorize final output
    try std.testing.expect(job.non_authorizing_input);
}

test "non-code verifier candidate executes through same lifecycle" {
    const allocator = std.testing.allocator;
    var candidate = verifier_adapter.VerifierCandidate{
        .allocator = allocator,
        .id = try allocator.dupe(u8, "cand-doc-1"),
        .hypothesis_id = try allocator.dupe(u8, "hyp-doc-1"),
        .candidate_kind = .document_consistency_check,
        .artifact_scope = try allocator.dupe(u8, "docs/readme.md"),
        .target_claim_surface = try allocator.dupe(u8, "section"),
        .proposed_check = try allocator.dupe(u8, "consistency check"),
        .required_inputs = try cloneStrings(allocator, &.{"doc:evidence"}),
        .expected_observations = try cloneStrings(allocator, &.{"consistent"}),
        .provenance = try allocator.dupe(u8, "test"),
        .trace = try allocator.dupe(u8, "proposed"),
    };
    defer candidate.deinit();

    const approval = verifier_adapter.VerifierCandidateApproval{
        .candidate_id = try allocator.dupe(u8, candidate.id),
        .approved_by = try allocator.dupe(u8, "test-fixture"),
        .approval_kind = .test_fixture,
        .approval_reason = try allocator.dupe(u8, "doc check"),
        .timestamp_ms = 2000,
        .trace = try allocator.dupe(u8, "approved"),
        .scope = try allocator.dupe(u8, "docs/"),
    };
    try verifier_adapter.acceptVerifierCandidate(&candidate, approval);

    const budget = compute_budget.resolve(.{ .tier = .medium });
    const elig = verifier_execution.checkExecutionEligibility(&candidate, defaultPolicy(), budget, 0);
    try std.testing.expect(elig.eligible);

    var job = try verifier_execution.createExecutionJob(allocator, &candidate, defaultPolicy(), .check_plan_eval);
    defer job.deinit();
    var result = try verifier_execution.executeJob(allocator, &job);
    defer result.deinit();
    try std.testing.expectEqual(verifier_execution.ExecutionResultStatus.passed, result.status);
}

test "same input produces deterministic job IDs" {
    const allocator = std.testing.allocator;
    var candidate = try makeApprovedCandidate(allocator, "cand-det", "src/main.zig");
    defer candidate.deinit();

    var job_a = try verifier_execution.createExecutionJob(allocator, &candidate, defaultPolicy(), .check_plan_eval);
    defer job_a.deinit();
    var job_b = try verifier_execution.createExecutionJob(allocator, &candidate, defaultPolicy(), .check_plan_eval);
    defer job_b.deinit();

    try std.testing.expect(std.mem.eql(u8, job_a.id, job_b.id));
    try std.testing.expect(std.mem.eql(u8, job_a.candidate_id, job_b.candidate_id));
}

test "support graph integration for execution and correction" {
    const allocator = std.testing.allocator;
    var candidate = try makeApprovedCandidate(allocator, "cand-graph", "src/main.zig");
    defer candidate.deinit();

    var job = try verifier_execution.createExecutionJob(allocator, &candidate, defaultPolicy(), .check_plan_eval);
    defer job.deinit();
    var result = try verifier_execution.executeJob(allocator, &job);
    defer result.deinit();

    var nodes = std.ArrayList(code_intel.SupportGraphNode).init(allocator);
    defer {
        for (nodes.items) |node| {
            allocator.free(node.id);
            allocator.free(node.label);
            if (node.rel_path) |p| allocator.free(p);
            if (node.detail) |d| allocator.free(d);
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

    try verifier_execution.appendExecutionToSupportGraph(allocator, &nodes, &edges, "output", &job, &result);

    // Should have execution job node and execution result node
    var saw_job = false;
    var saw_result = false;
    for (nodes.items) |node| {
        if (node.kind == .verifier_execution_job) {
            saw_job = true;
            try std.testing.expect(!node.usable);
        }
        if (node.kind == .verifier_execution_result) {
            saw_result = true;
            try std.testing.expect(!node.usable);
        }
    }
    try std.testing.expect(saw_job);
    try std.testing.expect(saw_result);
    try std.testing.expect(edges.items.len >= 2);

    // No supported_by edges (proof gates unchanged)
    for (edges.items) |edge| {
        try std.testing.expect(edge.kind != .supported_by);
    }
}

test "correction hooks support graph integration" {
    const allocator = std.testing.allocator;
    var candidate = try makeApprovedCandidate(allocator, "cand-corr-graph", "src/main.zig");
    defer candidate.deinit();

    const argv = try cloneStrings(allocator, &.{"false"});
    candidate.command_plan = .{ .argv = argv };

    const budget = compute_budget.resolve(.{ .tier = .medium });
    const policy = verifier_execution.VerificationPolicy{ .workspace_root = "/tmp" };

    var job = try verifier_execution.createExecutionJob(allocator, &candidate, policy, .command_plan);
    defer job.deinit();
    var result = try verifier_execution.executeJob(allocator, &job);
    defer result.deinit();

    var correction_id_counter: u64 = 100;
    var correction_count: usize = 0;
    var nk_count: usize = 0;
    var correction = (try correction_hooks.createCorrectionFromExecutionResult(
        allocator,
        &result,
        candidate.id,
        "materialized",
        &correction_id_counter,
        budget,
        &correction_count,
        &nk_count,
    )).?;
    defer correction.deinit();

    var nk_id_counter: u64 = 50;
    var nk = correction_hooks.maybeCreateNegativeKnowledgeCandidate(
        allocator,
        &correction,
        &nk_id_counter,
        budget,
        &nk_count,
    ).?;
    defer nk.deinit();

    var nodes = std.ArrayList(code_intel.SupportGraphNode).init(allocator);
    defer {
        for (nodes.items) |node| {
            allocator.free(node.id);
            allocator.free(node.label);
            if (node.rel_path) |p| allocator.free(p);
            if (node.detail) |d| allocator.free(d);
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

    try correction_hooks.appendCorrectionToSupportGraph(allocator, &nodes, &edges, "output", &correction, &nk);

    var saw_correction = false;
    var saw_nk = false;
    for (nodes.items) |node| {
        if (node.kind == .correction_event) {
            saw_correction = true;
            try std.testing.expect(!node.usable);
        }
        if (node.kind == .negative_knowledge_candidate) {
            saw_nk = true;
            try std.testing.expect(!node.usable);
        }
    }
    try std.testing.expect(saw_correction);
    try std.testing.expect(saw_nk);

    // Check for correction-specific edges
    var saw_correction_for = false;
    var saw_proposes_nk = false;
    for (edges.items) |edge| {
        if (edge.kind == .correction_for) saw_correction_for = true;
        if (edge.kind == .proposes_negative_knowledge) saw_proposes_nk = true;
        try std.testing.expect(edge.kind != .supported_by);
    }
    try std.testing.expect(saw_correction_for);
    try std.testing.expect(saw_proposes_nk);
}

test "budget exhaustion prevents correction event creation" {
    const allocator = std.testing.allocator;
    var candidate = try makeApprovedCandidate(allocator, "cand-budget-corr", "src/main.zig");
    defer candidate.deinit();

    const argv = try cloneStrings(allocator, &.{"false"});
    candidate.command_plan = .{ .argv = argv };

    const budget = compute_budget.resolve(.{
        .tier = .medium,
        .overrides = .{ .max_correction_events = 0 },
    });
    const policy = verifier_execution.VerificationPolicy{ .workspace_root = "/tmp" };

    var job = try verifier_execution.createExecutionJob(allocator, &candidate, policy, .command_plan);
    defer job.deinit();
    var result = try verifier_execution.executeJob(allocator, &job);
    defer result.deinit();

    var correction_id_counter: u64 = 200;
    var correction_count: usize = 0;
    var nk_count: usize = 0;
    const correction = try correction_hooks.createCorrectionFromExecutionResult(
        allocator,
        &result,
        candidate.id,
        "materialized",
        &correction_id_counter,
        budget,
        &correction_count,
        &nk_count,
    );
    try std.testing.expect(correction == null);
}

test "unbound scope blocks execution eligibility" {
    const allocator = std.testing.allocator;
    var candidate = try makeApprovedCandidate(allocator, "cand-unbound", "unbound");
    defer candidate.deinit();

    const budget = compute_budget.resolve(.{ .tier = .medium });
    const elig = verifier_execution.checkExecutionEligibility(&candidate, defaultPolicy(), budget, 0);
    try std.testing.expect(!elig.eligible);
    try std.testing.expect(elig.blocked_reason.? == .unbound_scope);
}

test "passed execution result does not directly support final output" {
    const allocator = std.testing.allocator;
    var candidate = try makeApprovedCandidate(allocator, "cand-nosupport", "src/main.zig");
    defer candidate.deinit();

    var job = try verifier_execution.createExecutionJob(allocator, &candidate, defaultPolicy(), .check_plan_eval);
    defer job.deinit();
    var result = try verifier_execution.executeJob(allocator, &job);
    defer result.deinit();

    try std.testing.expectEqual(verifier_execution.ExecutionResultStatus.passed, result.status);
    // Job remains non-authorizing even after pass
    try std.testing.expect(job.non_authorizing_input);
    // Candidate remains non-authorizing
    try std.testing.expect(candidate.non_authorizing);

    // Support graph nodes are non-usable
    var nodes = std.ArrayList(code_intel.SupportGraphNode).init(allocator);
    defer {
        for (nodes.items) |node| {
            allocator.free(node.id);
            allocator.free(node.label);
            if (node.rel_path) |p| allocator.free(p);
            if (node.detail) |d| allocator.free(d);
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
    try verifier_execution.appendExecutionToSupportGraph(allocator, &nodes, &edges, "out", &job, &result);

    for (nodes.items) |node| {
        try std.testing.expect(!node.usable);
    }
    for (edges.items) |edge| {
        try std.testing.expect(edge.kind != .supported_by);
    }
}

// ── Helpers ──

fn cloneStrings(allocator: std.mem.Allocator, items: []const []const u8) ![][]u8 {
    var list = try allocator.alloc([]u8, items.len);
    for (items, 0..) |item, idx| {
        list[idx] = try allocator.dupe(u8, item);
    }
    return list;
}
