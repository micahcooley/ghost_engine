const std = @import("std");
const gutf = @import("../codec/gutf.zig");
const gip_mapping = @import("../gip/mapping.zig");

pub const DEFAULT_MMAP_WINDOW_BYTES: usize = 64 * 1024 * 1024;
pub const SWE_MMAP_WINDOW_BYTES: usize = 128 * 1024 * 1024;
pub const MAX_SINGLE_INSTANCE_BYTES: usize = 2 * 1024 * 1024;

pub const DatasetId = enum {
    swe_bench_pro,
    mmlu_pro,
    humaneval_plus,
    mbpp_plus,
    autumnbench,

    pub fn name(self: DatasetId) []const u8 {
        return @tagName(self);
    }
};

pub const DatasetKind = enum {
    software_engineering,
    multi_subject_reasoning,
    function_logic,
    world_model,
};

pub const StorageFormat = enum {
    jsonl,
    parquet,
    huggingface_dataset,
    web_interface,
};

pub const AccessClass = enum {
    public,
    public_subset_only,
    private_or_commercial_unavailable,
};

pub const DatasetSpec = struct {
    id: DatasetId,
    kind: DatasetKind,
    source: []const u8,
    storage_format: StorageFormat,
    access: AccessClass,
    requires_docker_upstream: bool,
    native_only_supported: bool,
    target_domain: gutf.IntentClass,
};

pub const DATASETS = [_]DatasetSpec{
    .{
        .id = .swe_bench_pro,
        .kind = .software_engineering,
        .source = "ScaleAI/SWE-bench_Pro",
        .storage_format = .huggingface_dataset,
        .access = .public_subset_only,
        .requires_docker_upstream = true,
        .native_only_supported = true,
        .target_domain = .software_engineering,
    },
    .{
        .id = .mmlu_pro,
        .kind = .multi_subject_reasoning,
        .source = "TIGER-Lab/MMLU-Pro",
        .storage_format = .huggingface_dataset,
        .access = .public,
        .requires_docker_upstream = false,
        .native_only_supported = true,
        .target_domain = .world_model,
    },
    .{
        .id = .humaneval_plus,
        .kind = .function_logic,
        .source = "evalplus/humanevalplus",
        .storage_format = .huggingface_dataset,
        .access = .public,
        .requires_docker_upstream = false,
        .native_only_supported = true,
        .target_domain = .logic_verification,
    },
    .{
        .id = .mbpp_plus,
        .kind = .function_logic,
        .source = "evalplus/mbppplus",
        .storage_format = .huggingface_dataset,
        .access = .public,
        .requires_docker_upstream = false,
        .native_only_supported = true,
        .target_domain = .logic_verification,
    },
    .{
        .id = .autumnbench,
        .kind = .world_model,
        .source = "https://autumn.basis.ai",
        .storage_format = .web_interface,
        .access = .public,
        .requires_docker_upstream = false,
        .native_only_supported = true,
        .target_domain = .world_model,
    },
};

pub const LoadPlan = struct {
    dataset: DatasetSpec,
    mode: enum { mmap_window, streaming_rows, interactive_probe },
    window_bytes: usize,
    forbids_full_dataset_alloc: bool = true,
};

pub const OracleOutcome = struct {
    compile_passed: bool = false,
    fail_to_pass_passed: bool = false,
    pass_to_pass_passed: bool = false,
    used_native_sandbox: bool = false,
    used_docker: bool = false,

    pub fn passed(self: OracleOutcome) bool {
        return self.compile_passed and
            self.fail_to_pass_passed and
            self.pass_to_pass_passed and
            self.used_native_sandbox and
            !self.used_docker;
    }
};

pub const IngestionDecision = enum {
    reject_unverified,
    distill_gutf_rune,
    halt_manual_sigil_override,
};

pub const GroundingRecord = struct {
    dataset: DatasetId,
    instance_id: []const u8,
    problem_statement: []const u8,
    oracle: OracleOutcome,
    truth_density_per_mille: u16,
    output_tier: gip_mapping.EpistemicTier,

    pub fn decision(self: GroundingRecord) IngestionDecision {
        if (self.truth_density_per_mille < gip_mapping.AUTONOMOUS_TRUTH_DENSITY_FLOOR_PER_MILLE) {
            return .halt_manual_sigil_override;
        }
        if (self.oracle.passed()) return .distill_gutf_rune;
        return .reject_unverified;
    }
};

pub const RootTierReport = struct {
    axioms_total: u32,
    verified_axioms: u32,
    truth_density_per_mille: u16,
    can_assist_zenith: bool,
};

pub fn datasetSpec(id: DatasetId) DatasetSpec {
    for (DATASETS) |spec| {
        if (spec.id == id) return spec;
    }
    unreachable;
}

pub fn loadPlan(id: DatasetId) LoadPlan {
    const spec = datasetSpec(id);
    return switch (id) {
        .swe_bench_pro => .{
            .dataset = spec,
            .mode = .mmap_window,
            .window_bytes = SWE_MMAP_WINDOW_BYTES,
        },
        .mmlu_pro, .humaneval_plus, .mbpp_plus => .{
            .dataset = spec,
            .mode = .streaming_rows,
            .window_bytes = DEFAULT_MMAP_WINDOW_BYTES,
        },
        .autumnbench => .{
            .dataset = spec,
            .mode = .interactive_probe,
            .window_bytes = 0,
        },
    };
}

pub fn makeDownloadArgv(
    allocator: std.mem.Allocator,
    id: DatasetId,
    output_dir: []const u8,
    allow_private: bool,
) ![]const []const u8 {
    const spec = datasetSpec(id);
    if (spec.access == .private_or_commercial_unavailable and !allow_private) return error.PrivateDatasetUnavailable;
    var argv = try allocator.alloc([]const u8, 8);
    errdefer allocator.free(argv);
    argv[0] = "python3";
    argv[1] = "scripts/download_grounding_dataset.py";
    argv[2] = "--dataset";
    argv[3] = spec.source;
    argv[4] = "--output-dir";
    argv[5] = output_dir;
    argv[6] = "--mode";
    argv[7] = if (id == .swe_bench_pro) "public-only" else "public";
    return argv;
}

pub fn freeDownloadArgv(allocator: std.mem.Allocator, argv: []const []const u8) void {
    allocator.free(argv);
}

pub fn ensureNoDockerArgv(argv: []const []const u8) !void {
    for (argv) |part| {
        if (std.mem.indexOf(u8, part, "docker") != null or std.mem.indexOf(u8, part, "podman") != null) {
            return error.ContainerRuntimeForbidden;
        }
    }
}

pub fn rootTierReport(records: []const GroundingRecord) RootTierReport {
    var verified: u32 = 0;
    for (records) |record| {
        if (record.output_tier == .root or record.output_tier == .verified) verified += 1;
    }
    const total: u32 = @intCast(records.len);
    const density: u16 = if (total == 0) 0 else @intCast((@as(u64, verified) * 1000) / total);
    return .{
        .axioms_total = total,
        .verified_axioms = verified,
        .truth_density_per_mille = density,
        .can_assist_zenith = total != 0 and density == 1000,
    };
}

pub fn distillRuneBytes(record: GroundingRecord) !gutf.RuneBytes {
    if (record.decision() != .distill_gutf_rune) return error.OracleGateNotSatisfied;
    const seed = std.hash.Wyhash.hash(0, record.instance_id) ^ std.hash.Wyhash.hash(1, record.problem_statement);
    return gutf.deterministicRuneBytes(seed, @intFromEnum(datasetSpec(record.dataset).target_domain));
}

pub fn parseSweBenchInstanceFields(
    allocator: std.mem.Allocator,
    json_bytes: []const u8,
) !struct { instance_id: []u8, problem_statement: []u8 } {
    if (json_bytes.len > MAX_SINGLE_INSTANCE_BYTES) return error.InstanceTooLarge;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidInstanceJson;
    const obj = parsed.value.object;
    const instance = obj.get("instance_id") orelse return error.MissingInstanceId;
    const statement = obj.get("problem_statement") orelse return error.MissingProblemStatement;
    if (instance != .string or statement != .string) return error.InvalidInstanceJson;
    return .{
        .instance_id = try allocator.dupe(u8, instance.string),
        .problem_statement = try allocator.dupe(u8, statement.string),
    };
}

test "dataset registry keeps public/private and no-docker facts explicit" {
    const swe = datasetSpec(.swe_bench_pro);
    try std.testing.expectEqual(AccessClass.public_subset_only, swe.access);
    try std.testing.expect(swe.requires_docker_upstream);
    try std.testing.expect(swe.native_only_supported);

    const mmlu = datasetSpec(.mmlu_pro);
    try std.testing.expectEqual(StorageFormat.huggingface_dataset, mmlu.storage_format);
    try std.testing.expect(!mmlu.requires_docker_upstream);
}

test "load plans forbid full dataset allocation" {
    const swe = loadPlan(.swe_bench_pro);
    try std.testing.expectEqual(@as(usize, SWE_MMAP_WINDOW_BYTES), swe.window_bytes);
    try std.testing.expect(swe.forbids_full_dataset_alloc);

    const mmlu = loadPlan(.mmlu_pro);
    try std.testing.expectEqual(@as(usize, DEFAULT_MMAP_WINDOW_BYTES), mmlu.window_bytes);
    try std.testing.expect(mmlu.forbids_full_dataset_alloc);
}

test "oracle gate rejects unproven and halts below truth floor" {
    const passed = OracleOutcome{
        .compile_passed = true,
        .fail_to_pass_passed = true,
        .pass_to_pass_passed = true,
        .used_native_sandbox = true,
    };
    const good = GroundingRecord{
        .dataset = .humaneval_plus,
        .instance_id = "HumanEval/0",
        .problem_statement = "return x",
        .oracle = passed,
        .truth_density_per_mille = 1000,
        .output_tier = .verified,
    };
    try std.testing.expectEqual(IngestionDecision.distill_gutf_rune, good.decision());
    _ = try distillRuneBytes(good);

    var bad = good;
    bad.oracle.compile_passed = false;
    try std.testing.expectEqual(IngestionDecision.reject_unverified, bad.decision());
    try std.testing.expectError(error.OracleGateNotSatisfied, distillRuneBytes(bad));

    var low_density = good;
    low_density.truth_density_per_mille = 849;
    try std.testing.expectEqual(IngestionDecision.halt_manual_sigil_override, low_density.decision());
}

test "download argv never routes through docker" {
    const allocator = std.testing.allocator;
    const argv = try makeDownloadArgv(allocator, .swe_bench_pro, ".ghost/knowledge/swe_bench_pro", false);
    defer freeDownloadArgv(allocator, argv);
    try ensureNoDockerArgv(argv);
    try std.testing.expectEqualStrings("ScaleAI/SWE-bench_Pro", argv[3]);
    try std.testing.expectEqualStrings("public-only", argv[7]);
}

test "SWE-bench instance parser extracts only grounding fields" {
    const allocator = std.testing.allocator;
    const fields = try parseSweBenchInstanceFields(allocator,
        \\{"instance_id":"repo__issue-1","problem_statement":"Fix the failing limiter test.","patch":"ignored"}
    );
    defer allocator.free(fields.instance_id);
    defer allocator.free(fields.problem_statement);
    try std.testing.expectEqualStrings("repo__issue-1", fields.instance_id);
    try std.testing.expectEqualStrings("Fix the failing limiter test.", fields.problem_statement);
}

test "root tier report refuses Zenith assist until every axiom is verified" {
    const records = [_]GroundingRecord{
        .{ .dataset = .humaneval_plus, .instance_id = "a", .problem_statement = "a", .oracle = .{}, .truth_density_per_mille = 1000, .output_tier = .root },
        .{ .dataset = .mbpp_plus, .instance_id = "b", .problem_statement = "b", .oracle = .{}, .truth_density_per_mille = 700, .output_tier = .shadow },
    };
    const report = rootTierReport(&records);
    try std.testing.expectEqual(@as(u32, 2), report.axioms_total);
    try std.testing.expectEqual(@as(u32, 1), report.verified_axioms);
    try std.testing.expectEqual(@as(u16, 500), report.truth_density_per_mille);
    try std.testing.expect(!report.can_assist_zenith);
}
