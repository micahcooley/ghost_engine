const std = @import("std");
const code_intel = @import("code_intel.zig");
const compute_budget = @import("compute_budget.zig");
const execution = @import("execution.zig");
const verifier_adapter = @import("verifier_adapter.zig");

pub const ExecutionJobStatus = enum {
    pending,
    scheduled,
    running,
    completed,
    failed,
    blocked,
    skipped,
    budget_exhausted,
};

pub const ExecutionKind = enum {
    check_plan_eval,
    generated_file_verifier,
    generated_patch_verifier,
    command_plan,
    existing_adapter_bridge,
};

pub const ExecutionBlockedReason = enum {
    missing_candidate,
    not_approved,
    not_materialized,
    unbound_scope,
    missing_input_evidence,
    unsafe_execution,
    command_not_allowed,
    network_denied,
    sudo_denied,
    write_outside_workspace,
    budget_exhausted,
    response_mode_disallows_execution,
    verifier_policy_denied,
    expected_observation_unknown,
    shell_string_rejected,
    command_empty,
};

pub const ExecutionResultStatus = enum {
    passed,
    failed,
    blocked,
    skipped,
    budget_exhausted,
    timeout,
};

pub const VerificationPolicy = struct {
    allow_network: bool = false,
    allow_sudo: bool = false,
    allow_system_mutation: bool = false,
    default_timeout_ms: u32 = execution.DEFAULT_TIMEOUT_MS,
    max_output_bytes: usize = execution.DEFAULT_MAX_OUTPUT_BYTES,
    workspace_root: []const u8 = "",
};

pub const ExecutionEligibility = struct {
    eligible: bool = false,
    status_ok: bool = false,
    approved: bool = false,
    materialized_if_needed: bool = true,
    scope_bound: bool = false,
    input_evidence_present: bool = false,
    execution_plan_safe: bool = false,
    command_allowed: bool = false,
    no_network_violation: bool = true,
    no_sudo_violation: bool = true,
    no_workspace_escape: bool = true,
    budget_available: bool = true,
    policy_allows: bool = true,
    blocked_reason: ?ExecutionBlockedReason = null,
};

pub const ExecutionJob = struct {
    allocator: std.mem.Allocator,
    id: []u8,
    candidate_id: []u8,
    hypothesis_id: ?[]u8 = null,
    materialization_id: ?[]u8 = null,
    execution_kind: ExecutionKind,
    argv: [][]u8 = &.{},
    cwd: ?[]u8 = null,
    artifact_refs: [][]u8 = &.{},
    input_evidence_refs: [][]u8 = &.{},
    expected_observations: [][]u8 = &.{},
    safety_policy: VerificationPolicy = .{},
    budget_cost: u32 = 1,
    status: ExecutionJobStatus = .pending,
    result_ref: ?[]u8 = null,
    evidence_ref: ?[]u8 = null,
    correction_ref: ?[]u8 = null,
    non_authorizing_input: bool = true,
    trace: []u8,

    pub fn deinit(self: *ExecutionJob) void {
        self.allocator.free(self.id);
        self.allocator.free(self.candidate_id);
        if (self.hypothesis_id) |v| self.allocator.free(v);
        if (self.materialization_id) |v| self.allocator.free(v);
        freeStringList(self.allocator, self.argv);
        if (self.cwd) |v| self.allocator.free(v);
        freeStringList(self.allocator, self.artifact_refs);
        freeStringList(self.allocator, self.input_evidence_refs);
        freeStringList(self.allocator, self.expected_observations);
        if (self.result_ref) |v| self.allocator.free(v);
        if (self.evidence_ref) |v| self.allocator.free(v);
        if (self.correction_ref) |v| self.allocator.free(v);
        self.allocator.free(self.trace);
        self.* = undefined;
    }

    pub fn clone(self: *const ExecutionJob, allocator: std.mem.Allocator) !ExecutionJob {
        return .{
            .allocator = allocator,
            .id = try allocator.dupe(u8, self.id),
            .candidate_id = try allocator.dupe(u8, self.candidate_id),
            .hypothesis_id = if (self.hypothesis_id) |v| try allocator.dupe(u8, v) else null,
            .materialization_id = if (self.materialization_id) |v| try allocator.dupe(u8, v) else null,
            .execution_kind = self.execution_kind,
            .argv = try cloneStringList(allocator, self.argv),
            .cwd = if (self.cwd) |v| try allocator.dupe(u8, v) else null,
            .artifact_refs = try cloneStringList(allocator, self.artifact_refs),
            .input_evidence_refs = try cloneStringList(allocator, self.input_evidence_refs),
            .expected_observations = try cloneStringList(allocator, self.expected_observations),
            .safety_policy = self.safety_policy,
            .budget_cost = self.budget_cost,
            .status = self.status,
            .result_ref = if (self.result_ref) |v| try allocator.dupe(u8, v) else null,
            .evidence_ref = if (self.evidence_ref) |v| try allocator.dupe(u8, v) else null,
            .correction_ref = if (self.correction_ref) |v| try allocator.dupe(u8, v) else null,
            .non_authorizing_input = self.non_authorizing_input,
            .trace = try allocator.dupe(u8, self.trace),
        };
    }
};

pub const ExecutionResult = struct {
    allocator: std.mem.Allocator,
    job_id: []u8,
    candidate_id: []u8,
    status: ExecutionResultStatus,
    exit_code: ?i32 = null,
    stdout_ref: ?[]u8 = null,
    stderr_ref: ?[]u8 = null,
    elapsed_ms: u64 = 0,
    evidence_kind: []u8,
    observations_matched: [][]u8 = &.{},
    observations_failed: [][]u8 = &.{},
    obligations_discharged: [][]u8 = &.{},
    obligations_remaining: [][]u8 = &.{},
    contradiction_signals: [][]u8 = &.{},
    blocker_signals: [][]u8 = &.{},
    trace: []u8,

    pub fn deinit(self: *ExecutionResult) void {
        self.allocator.free(self.job_id);
        self.allocator.free(self.candidate_id);
        if (self.stdout_ref) |v| self.allocator.free(v);
        if (self.stderr_ref) |v| self.allocator.free(v);
        self.allocator.free(self.evidence_kind);
        freeStringList(self.allocator, self.observations_matched);
        freeStringList(self.allocator, self.observations_failed);
        freeStringList(self.allocator, self.obligations_discharged);
        freeStringList(self.allocator, self.obligations_remaining);
        freeStringList(self.allocator, self.contradiction_signals);
        freeStringList(self.allocator, self.blocker_signals);
        self.allocator.free(self.trace);
        self.* = undefined;
    }
};

pub const ExecutionSummary = struct {
    allocator: std.mem.Allocator,
    eligible_count: usize = 0,
    scheduled_count: usize = 0,
    completed_count: usize = 0,
    failed_count: usize = 0,
    blocked_count: usize = 0,
    skipped_count: usize = 0,
    budget_exhausted_count: usize = 0,
    timeout_count: usize = 0,
    jobs: []ExecutionJob = &.{},
    results: []ExecutionResult = &.{},

    pub fn deinit(self: *ExecutionSummary) void {
        for (self.jobs) |*job| job.deinit();
        if (self.jobs.len != 0) self.allocator.free(self.jobs);
        for (self.results) |*result| result.deinit();
        if (self.results.len != 0) self.allocator.free(self.results);
        self.* = undefined;
    }
};

pub fn checkExecutionEligibility(
    candidate: *const verifier_adapter.VerifierCandidate,
    policy: VerificationPolicy,
    budget: compute_budget.Effective,
    jobs_used: usize,
) ExecutionEligibility {
    var elig: ExecutionEligibility = .{
        .eligible = false,
        .no_network_violation = true,
        .no_sudo_violation = true,
        .no_workspace_escape = true,
    };

    // Gate 1: candidate status must be accepted or materialized
    if (candidate.status != .accepted and candidate.status != .materialized) {
        elig.blocked_reason = .not_approved;
        return elig;
    }
    elig.status_ok = true;

    // Gate 2: explicit approval exists
    if (candidate.approval == null) {
        elig.blocked_reason = .not_approved;
        return elig;
    }
    elig.approved = true;

    // Gate 3: materialization exists if candidate requires artifact/check file
    if (candidate.status == .materialized and candidate.materialization == null) {
        elig.blocked_reason = .not_materialized;
        return elig;
    }
    elig.materialized_if_needed = true;

    // Gate 4: artifact scope is bound
    if (!boundScope(candidate.artifact_scope)) {
        elig.blocked_reason = .unbound_scope;
        return elig;
    }
    elig.scope_bound = true;

    // Gate 5: required input evidence exists
    if (candidate.required_inputs.len == 0) {
        elig.blocked_reason = .missing_input_evidence;
        return elig;
    }
    elig.input_evidence_present = true;

    // Gate 6: command plan is safe and bounded
    if (candidate.command_plan) |plan| {
        if (plan.argv.len == 0) {
            elig.blocked_reason = .command_empty;
            return elig;
        }
        // Shell strings rejected — argv-only
        for (plan.argv) |arg| {
            if (containsShellMeta(arg)) {
                elig.execution_plan_safe = false;
                elig.blocked_reason = .shell_string_rejected;
                return elig;
            }
        }
        // Check for network/sudo/system mutation patterns
        for (plan.argv) |arg| {
            if (isNetworkCommand(arg)) {
                if (!policy.allow_network) {
                    elig.no_network_violation = false;
                    elig.blocked_reason = .network_denied;
                    return elig;
                }
            }
            if (isSudoCommand(arg)) {
                if (!policy.allow_sudo) {
                    elig.no_sudo_violation = false;
                    elig.blocked_reason = .sudo_denied;
                    return elig;
                }
            }
            if (isSystemMutationCommand(arg)) {
                if (!policy.allow_system_mutation) {
                    elig.no_workspace_escape = false;
                    elig.blocked_reason = .write_outside_workspace;
                    return elig;
                }
            }
        }
        elig.command_allowed = true;
    } else {
        // No command plan — check if this is a check_plan_eval that doesn't need one
        elig.command_allowed = true;
    }
    elig.execution_plan_safe = true;

    // Gate 7: budget allows execution
    if (jobs_used >= budget.max_verifier_candidate_execution_jobs) {
        elig.budget_available = false;
        elig.blocked_reason = .budget_exhausted;
        return elig;
    }

    // Gate 8: non-authorizing invariant
    if (!candidate.non_authorizing) {
        elig.blocked_reason = .unsafe_execution;
        return elig;
    }

    // Gate 9: expected observations known
    if (candidate.expected_observations.len == 0) {
        elig.blocked_reason = .expected_observation_unknown;
        return elig;
    }

    // Gate 10: policy allows
    if (policy.workspace_root.len == 0) {
        elig.policy_allows = false;
        elig.blocked_reason = .verifier_policy_denied;
        return elig;
    }
    elig.policy_allows = true;

    elig.eligible = true;
    return elig;
}

pub fn createExecutionJob(
    allocator: std.mem.Allocator,
    candidate: *const verifier_adapter.VerifierCandidate,
    policy: VerificationPolicy,
    execution_kind: ExecutionKind,
) !ExecutionJob {
    const argv = if (candidate.command_plan) |plan|
        try cloneStringList(allocator, plan.argv)
    else
        try allocator.alloc([]u8, 0);

    const mat_id = if (candidate.materialization) |mat|
        try allocator.dupe(u8, mat.id)
    else
        null;

    const hyp_id = try allocator.dupe(u8, candidate.hypothesis_id);
    const cwd = if (policy.workspace_root.len > 0)
        try allocator.dupe(u8, policy.workspace_root)
    else
        null;

    return .{
        .allocator = allocator,
        .id = try std.fmt.allocPrint(allocator, "exec_job:{s}", .{candidate.id}),
        .candidate_id = try allocator.dupe(u8, candidate.id),
        .hypothesis_id = hyp_id,
        .materialization_id = mat_id,
        .execution_kind = execution_kind,
        .argv = argv,
        .cwd = cwd,
        .artifact_refs = try cloneStringList(allocator, candidate.generated_artifacts),
        .input_evidence_refs = try cloneStringList(allocator, candidate.required_inputs),
        .expected_observations = try cloneStringList(allocator, candidate.expected_observations),
        .safety_policy = policy,
        .budget_cost = 1,
        .status = .scheduled,
        .trace = try std.fmt.allocPrint(allocator, "scheduled from candidate {s}", .{candidate.id}),
    };
}

pub fn executeJob(
    allocator: std.mem.Allocator,
    job: *ExecutionJob,
) !ExecutionResult {
    job.status = .running;

    if (job.argv.len == 0) {
        job.status = .completed;
        return ExecutionResult{
            .allocator = allocator,
            .job_id = try allocator.dupe(u8, job.id),
            .candidate_id = try allocator.dupe(u8, job.candidate_id),
            .status = .passed,
            .evidence_kind = try allocator.dupe(u8, "check_plan_eval"),
            .trace = try std.fmt.allocPrint(allocator, "check plan evaluation completed for {s}", .{job.candidate_id}),
        };
    }

    const step = execution.Step{
        .label = job.candidate_id,
        .kind = .shell,
        .phase = .@"test",
        .argv = constSliceToConstSlice(job.argv),
        .timeout_ms = job.safety_policy.default_timeout_ms,
    };

    const options = execution.Options{
        .workspace_root = job.safety_policy.workspace_root,
        .cwd = job.cwd,
        .max_output_bytes = job.safety_policy.max_output_bytes,
    };

    var result = execution.run(allocator, options, step) catch {
        job.status = .failed;
        return ExecutionResult{
            .allocator = allocator,
            .job_id = try allocator.dupe(u8, job.id),
            .candidate_id = try allocator.dupe(u8, job.candidate_id),
            .status = .failed,
            .evidence_kind = try allocator.dupe(u8, "execution_failure"),
            .contradiction_signals = try allocator.alloc([]u8, 0),
            .blocker_signals = try allocator.alloc([]u8, 1),
            .trace = try std.fmt.allocPrint(allocator, "execution spawn failed for {s}", .{job.candidate_id}),
        };
    };

    const result_status: ExecutionResultStatus = if (result.succeeded())
        .passed
    else if (result.timed_out)
        .timeout
    else
        .failed;

    job.status = if (result_status == .passed) .completed else .failed;

    var contradiction_signals = std.ArrayList([]u8).init(allocator);
    var blocker_signals = std.ArrayList([]u8).init(allocator);

    if (result_status == .failed) {
        try contradiction_signals.append(try std.fmt.allocPrint(allocator, "execution failed for {s}: exit_code={?}", .{ job.candidate_id, result.exit_code }));
    }
    if (result.timed_out) {
        try blocker_signals.append(try allocator.dupe(u8, "timeout"));
    }

    var observations_matched = std.ArrayList([]u8).init(allocator);
    var observations_failed = std.ArrayList([]u8).init(allocator);

    for (job.expected_observations) |obs| {
        if (result.stdout.len > 0 and std.mem.indexOf(u8, result.stdout, obs) != null) {
            try observations_matched.append(try allocator.dupe(u8, obs));
        } else {
            try observations_failed.append(try allocator.dupe(u8, obs));
        }
    }

    const stdout_ref: ?[]u8 = if (result.stdout.len > 0) try allocator.dupe(u8, result.stdout) else null;
    const stderr_ref: ?[]u8 = if (result.stderr.len > 0) try allocator.dupe(u8, result.stderr) else null;

    // Capture exit code before deinit
    const exit_code = result.exit_code;
    const elapsed_ms = result.duration_ms;
    result.deinit(allocator);

    const exec_result = ExecutionResult{
        .allocator = allocator,
        .job_id = try allocator.dupe(u8, job.id),
        .candidate_id = try allocator.dupe(u8, job.candidate_id),
        .status = result_status,
        .exit_code = exit_code,
        .stdout_ref = stdout_ref,
        .stderr_ref = stderr_ref,
        .elapsed_ms = elapsed_ms,
        .evidence_kind = try allocator.dupe(u8, "verifier_candidate_execution"),
        .observations_matched = try observations_matched.toOwnedSlice(),
        .observations_failed = try observations_failed.toOwnedSlice(),
        .contradiction_signals = try contradiction_signals.toOwnedSlice(),
        .blocker_signals = try blocker_signals.toOwnedSlice(),
        .trace = try std.fmt.allocPrint(allocator, "execution {s} for {s}", .{ @tagName(result_status), job.candidate_id }),
    };

    if (result_status == .passed) {
        job.result_ref = try allocator.dupe(u8, exec_result.job_id);
        job.evidence_ref = try allocator.dupe(u8, exec_result.evidence_kind);
    }

    return exec_result;
}

pub fn appendExecutionToSupportGraph(
    allocator: std.mem.Allocator,
    nodes: *std.ArrayList(code_intel.SupportGraphNode),
    edges: *std.ArrayList(code_intel.SupportGraphEdge),
    output_id: []const u8,
    job: *const ExecutionJob,
    result: ?*const ExecutionResult,
) !void {
    // Execution job node (non-authorizing)
    try nodes.append(.{
        .id = try std.fmt.allocPrint(allocator, "{s}:exec_job:{s}", .{ output_id, job.id }),
        .kind = .verifier_execution_job,
        .label = try std.fmt.allocPrint(allocator, "execution job {s}", .{job.id}),
        .score = 0,
        .usable = false,
        .detail = try std.fmt.allocPrint(allocator, "execution_kind={s} status={s} non_authorizing=true", .{ @tagName(job.execution_kind), @tagName(job.status) }),
    });
    const job_node_idx = nodes.items.len - 1;

    // Edge: executes_candidate
    try edges.append(.{
        .from_id = try allocator.dupe(u8, nodes.items[job_node_idx].id),
        .to_id = try std.fmt.allocPrint(allocator, "{s}:candidate:{s}", .{ output_id, job.candidate_id }),
        .kind = .executes_candidate,
    });

    // Edge: execution_for_materialization
    if (job.materialization_id) |mat_id| {
        try edges.append(.{
            .from_id = try allocator.dupe(u8, nodes.items[job_node_idx].id),
            .to_id = try std.fmt.allocPrint(allocator, "{s}:materialization:{s}", .{ output_id, mat_id }),
            .kind = .execution_for_materialization,
        });
    }

    if (result) |res| {
        // Execution result node (non-authorizing)
        try nodes.append(.{
            .id = try std.fmt.allocPrint(allocator, "{s}:exec_result:{s}", .{ output_id, res.job_id }),
            .kind = .verifier_execution_result,
            .label = try std.fmt.allocPrint(allocator, "execution result {s}", .{res.job_id}),
            .score = 0,
            .usable = false,
            .detail = try std.fmt.allocPrint(allocator, "status={s} elapsed_ms={d} non_authorizing=true", .{ @tagName(res.status), res.elapsed_ms }),
        });
        const result_node_idx = nodes.items.len - 1;

        // Edge: execution_produces_evidence
        try edges.append(.{
            .from_id = try allocator.dupe(u8, nodes.items[job_node_idx].id),
            .to_id = try allocator.dupe(u8, nodes.items[result_node_idx].id),
            .kind = .execution_produces_evidence,
        });

        // Edge: execution_contradicts if result has contradiction signals
        if (res.contradiction_signals.len > 0) {
            try edges.append(.{
                .from_id = try allocator.dupe(u8, nodes.items[result_node_idx].id),
                .to_id = try std.fmt.allocPrint(allocator, "{s}:candidate:{s}", .{ output_id, res.candidate_id }),
                .kind = .execution_contradicts,
            });
        }
    }
}

fn boundScope(scope: []const u8) bool {
    return scope.len > 0 and
        !std.mem.eql(u8, scope, "unknown") and
        !std.mem.eql(u8, scope, "unbound") and
        std.mem.indexOf(u8, scope, "unbound") == null;
}

fn containsShellMeta(arg: []const u8) bool {
    const metas = "&|;`$(){}[]<>!#~\n\r";
    return std.mem.indexOfAny(u8, arg, metas) != null;
}

fn isNetworkCommand(arg: []const u8) bool {
    const needles = [_][]const u8{ "curl", "wget", "ssh", "scp", "nc", "netcat", "ncat" };
    for (needles) |needle| {
        if (std.mem.eql(u8, arg, needle)) return true;
    }
    return false;
}

fn isSudoCommand(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "sudo") or std.mem.eql(u8, arg, "su") or std.mem.eql(u8, arg, "pkexec");
}

fn isSystemMutationCommand(arg: []const u8) bool {
    const needles = [_][]const u8{ "rm", "rmdir", "mkfs", "dd", "fdisk", "parted", "mkswap", "mount", "umount", "systemctl", "apt", "yum", "dnf", "pacman" };
    for (needles) |needle| {
        if (std.mem.eql(u8, arg, needle)) return true;
    }
    return false;
}

fn constSliceToConstSlice(items: [][]u8) []const []const u8 {
    const ptr: [*]const []const u8 = @ptrCast(items.ptr);
    return ptr[0..items.len];
}

fn freeStringList(allocator: std.mem.Allocator, items: [][]u8) void {
    for (items) |item| allocator.free(item);
    if (items.len != 0) allocator.free(items);
}

fn cloneStringList(allocator: std.mem.Allocator, items: []const []const u8) ![][]u8 {
    var list = try allocator.alloc([]u8, items.len);
    var copied: usize = 0;
    errdefer {
        for (list[0..copied]) |item| allocator.free(item);
        allocator.free(list);
    }
    for (items, 0..) |item, idx| {
        list[idx] = try allocator.dupe(u8, item);
        copied += 1;
    }
    return list;
}

pub fn executionJobStatusName(status: ExecutionJobStatus) []const u8 {
    return @tagName(status);
}

pub fn executionKindName(kind: ExecutionKind) []const u8 {
    return @tagName(kind);
}

pub fn executionResultStatusName(status: ExecutionResultStatus) []const u8 {
    return @tagName(status);
}

pub fn executionBlockedReasonName(reason: ExecutionBlockedReason) []const u8 {
    return @tagName(reason);
}
