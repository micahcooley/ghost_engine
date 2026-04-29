const std = @import("std");
const builtin = @import("builtin");

fn addCoreOptions(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    test_mode: bool,
) *std.Build.Step.Options {
    const arch = target.result.cpu.arch;
    const features = target.result.cpu.features;
    const is_x86_64 = arch == .x86_64;

    var core_options = b.addOptions();
    core_options.addOption([]const u8, "ghost_version", "V32");
    core_options.addOption([]const u8, "project_root", b.pathFromRoot("."));
    core_options.addOption([]const u8, "platform_subdir", b.fmt(
        "platforms/{s}/{s}",
        .{ @tagName(target.result.os.tag), @tagName(arch) },
    ));
    core_options.addOption(bool, "test_mode", test_mode);
    core_options.addOption(bool, "use_avx2", is_x86_64 and std.Target.x86.featureSetHas(features, .avx2));
    core_options.addOption(bool, "use_neon", arch == .aarch64 or arch == .arm);
    return core_options;
}

pub fn build(b: *std.Build) void {
    // Linux is the primary documented target. `zig build` uses the host target
    // by default, or an explicit target such as `-Dtarget=x86_64-linux`.
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const core_options = addCoreOptions(b, target, false);

    // ── 1. External Dependencies (Vulkan headers only) ──
    // NOTE: We do NOT link against vulkan-1.dll at build time.
    // The DLL is loaded dynamically at runtime via LoadLibraryA.
    // If the DLL is missing (no GPU driver), the engine falls back to CPU mode.
    const vulkan_sdk = b.graph.env_map.get("VULKAN_SDK");

    // ── 2. Sovereign Core Module ──
    const ghost_core = b.createModule(.{
        .root_source_file = b.path("src/ghost.zig"),
    });
    ghost_core.addOptions("build_options", core_options);
    if (target.result.os.tag == .windows) {
        if (vulkan_sdk) |sdk| {
            ghost_core.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "Include" }) });
        }
    } else if (target.result.os.tag == .linux) {
        ghost_core.addSystemIncludePath(.{ .cwd_relative = "/usr/include" });
        ghost_core.addSystemIncludePath(.{ .cwd_relative = "/usr/include/x86_64-linux-gnu" });
    }

    // Helper: add Vulkan include path to any module that imports ghost_core
    // (needed because @cImport in vulkan_loader.zig resolves headers at the root_module level)
    const addVulkanIncludes = struct {
        fn add(mod: *std.Build.Module, os: std.Target.Os, sdk_opt: ?[]const u8, builder: *std.Build) void {
            if (os.tag == .windows) {
                if (sdk_opt) |sdk| {
                    mod.addIncludePath(.{ .cwd_relative = builder.pathJoin(&.{ sdk, "Include" }) });
                }
            } else if (os.tag == .linux) {
                mod.addSystemIncludePath(.{ .cwd_relative = "/usr/include" });
                mod.addSystemIncludePath(.{ .cwd_relative = "/usr/include/x86_64-linux-gnu" });
            }
        }
    }.add;

    const addGhostExecutable = struct {
        fn add(
            builder: *std.Build,
            exe_name: []const u8,
            root: []const u8,
            exe_target: std.Build.ResolvedTarget,
            exe_optimize: std.builtin.OptimizeMode,
            core_module: *std.Build.Module,
            options: *std.Build.Step.Options,
            os: std.Target.Os,
            sdk_opt: ?[]const u8,
            add_vulkan_includes: *const fn (*std.Build.Module, std.Target.Os, ?[]const u8, *std.Build) void,
        ) *std.Build.Step.Compile {
            const exe = builder.addExecutable(.{
                .name = exe_name,
                .root_module = builder.createModule(.{
                    .root_source_file = builder.path(root),
                    .target = exe_target,
                    .optimize = exe_optimize,
                }),
            });
            exe.root_module.addImport("ghost_core", core_module);
            exe.root_module.addOptions("build_options", options);
            exe.root_module.linkSystemLibrary("c", .{});
            if (os.tag == .linux) {
                exe.root_module.linkSystemLibrary("dl", .{});
            }
            add_vulkan_includes(exe.root_module, os, sdk_opt, builder);
            if (std.mem.eql(u8, exe_name, "ghost_sovereign") and os.tag == .windows) {
                exe.root_module.linkSystemLibrary("ws2_32", .{});
            }
            return exe;
        }
    }.add;

    // ── 3. Shader SPIR-V (Pre-compiled, embedded via @embedFile) ──
    const shader_names = [_][]const u8{
        "resonance_query",
        "genesis_etch",
        "thermal_prune",
        "recursive_lookahead",
        "lattice_etch",
        "candidate_score",
        "neighborhood_score",
        "contradiction_filter",
    };
    for (shader_names) |name| {
        const spv_path = b.pathJoin(&.{ "src", "shaders", b.fmt("{s}.spv", .{name}) });
        _ = b.path(spv_path);
    }

    // Helper: configure an executable with ghost_core (no Vulkan link-time dependency)
    const ExeConfig = struct {
        name: []const u8,
        root: []const u8,
    };
    const monolith = addGhostExecutable(
        b,
        "ghost_sovereign",
        "src/main.zig",
        target,
        optimize,
        ghost_core,
        core_options,
        target.result.os,
        vulkan_sdk,
        addVulkanIncludes,
    );
    b.installArtifact(monolith);

    const exes = [_]ExeConfig{
        .{ .name = "ohl_trainer", .root = "src/trainer.zig" },
        .{ .name = "probe_inference", .root = "src/probe_inference.zig" },
        .{ .name = "sigil_core", .root = "src/sigil_core.zig" },
        .{ .name = "ghost_code_intel", .root = "src/code_intel_cli.zig" },
        .{ .name = "ghost_corpus_ingest", .root = "src/corpus_ingest_cli.zig" },
        .{ .name = "ghost_patch_candidates", .root = "src/patch_candidates_cli.zig" },
        .{ .name = "ghost_panic_dump", .root = "src/panic_dump_cli.zig" },
        .{ .name = "ghost_task_intent", .root = "src/task_intent_cli.zig" },
        .{ .name = "ghost_task_operator", .root = "src/task_operator_cli.zig" },
        .{ .name = "ghost_intent_grounding", .root = "src/intent_grounding_cli.zig" },
        .{ .name = "ghost_knowledge_pack", .root = "src/knowledge_packs.zig" },
        .{ .name = "ghost_gip", .root = "src/gip_cli.zig" },
        .{ .name = "ghost_project_autopsy", .root = "src/project_autopsy_cli.zig" },
    };

    for (exes) |cfg| {
        const exe = addGhostExecutable(
            b,
            cfg.name,
            cfg.root,
            target,
            optimize,
            ghost_core,
            core_options,
            target.result.os,
            vulkan_sdk,
            addVulkanIncludes,
        );
        b.installArtifact(exe);
    }

    // ── 8. Run Step ──
    const run_cmd = b.addRunArtifact(monolith);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const bench_exe = addGhostExecutable(
        b,
        "ghost_bench_serious_workflows",
        "src/bench_serious_workflows.zig",
        target,
        optimize,
        ghost_core,
        core_options,
        target.result.os,
        vulkan_sdk,
        addVulkanIncludes,
    );
    const run_bench = b.addRunArtifact(bench_exe);
    run_bench.step.dependOn(b.getInstallStep());
    const bench_step = b.step("bench-serious-workflows", "Run the serious workflow benchmark suite");
    bench_step.dependOn(&run_bench.step);

    const hygiene_cmd = b.addSystemCommand(&.{
        "git",
        "status",
        "--short",
        "--untracked-files=all",
    });
    hygiene_cmd.has_side_effects = true;
    const hygiene_step = b.step("repo-hygiene", "Print repository status after ignoring generated Ghost state");
    hygiene_step.dependOn(&hygiene_cmd.step);

    // ── 9. Unit & Integration Tests ──
    const main_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_smoke.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const test_core_options = addCoreOptions(b, target, true);
    const ghost_core_test = b.createModule(.{
        .root_source_file = b.path("src/ghost.zig"),
    });
    ghost_core_test.addOptions("build_options", test_core_options);
    if (target.result.os.tag == .windows) {
        if (vulkan_sdk) |sdk| {
            ghost_core_test.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "Include" }) });
        }
    } else if (target.result.os.tag == .linux) {
        ghost_core_test.addSystemIncludePath(.{ .cwd_relative = "/usr/include" });
        ghost_core_test.addSystemIncludePath(.{ .cwd_relative = "/usr/include/x86_64-linux-gnu" });
    }
    main_tests.root_module.addOptions("build_options", test_core_options);
    main_tests.root_module.linkSystemLibrary("c", .{});
    if (target.result.os.tag == .linux) {
        main_tests.root_module.linkSystemLibrary("dl", .{});
    }
    addVulkanIncludes(main_tests.root_module, target.result.os, vulkan_sdk, b);

    const run_main_tests = b.addRunArtifact(main_tests);
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_main_tests.step);

    const lifecycle_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_verifier_lifecycle.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    lifecycle_tests.root_module.addOptions("build_options", test_core_options);
    lifecycle_tests.root_module.linkSystemLibrary("c", .{});
    if (target.result.os.tag == .linux) {
        lifecycle_tests.root_module.linkSystemLibrary("dl", .{});
    }
    const run_lifecycle_tests = b.addRunArtifact(lifecycle_tests);
    test_step.dependOn(&run_lifecycle_tests.step);

    const gip_cli_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gip_cli.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    gip_cli_tests.root_module.addImport("ghost_core", ghost_core_test);
    gip_cli_tests.root_module.addOptions("build_options", test_core_options);
    gip_cli_tests.root_module.linkSystemLibrary("c", .{});
    if (target.result.os.tag == .linux) {
        gip_cli_tests.root_module.linkSystemLibrary("dl", .{});
    }
    addVulkanIncludes(gip_cli_tests.root_module, target.result.os, vulkan_sdk, b);
    const run_gip_cli_tests = b.addRunArtifact(gip_cli_tests);
    test_step.dependOn(&run_gip_cli_tests.step);

    // ── 10. Parity Test ──
    const parity_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_parity.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .test_runner = .{
            .path = b.path("src/parity_test_runner.zig"),
            .mode = .simple,
        },
    });
    parity_test.root_module.addImport("ghost_core", ghost_core);
    parity_test.root_module.addOptions("build_options", core_options);
    parity_test.root_module.linkSystemLibrary("c", .{});
    if (target.result.os.tag == .linux) {
        parity_test.root_module.addLibraryPath(.{ .cwd_relative = "/lib/x86_64-linux-gnu" });
        parity_test.root_module.addLibraryPath(.{ .cwd_relative = "/usr/lib/x86_64-linux-gnu" });
        parity_test.root_module.linkSystemLibrary("dl", .{});
        parity_test.root_module.linkSystemLibrary("vulkan", .{});
    }
    addVulkanIncludes(parity_test.root_module, target.result.os, vulkan_sdk, b);

    const run_parity_test = b.addRunArtifact(parity_test);
    run_parity_test.stdio = .inherit;
    run_parity_test.has_side_effects = true;
    const parity_step = b.step("test-parity", "Run Vulkan GPU <-> CPU Parity Tests");
    parity_step.dependOn(&run_parity_test.step);

    // ── 11. Release Packaging ──
    // Creates a clean distributable folder with the selected target layout.
    const release_step = b.step("release", "Build and package a distributable release");
    const release_exe = b.addExecutable(.{
        .name = "ghost_sovereign",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    release_exe.root_module.addImport("ghost_core", ghost_core);
    release_exe.root_module.addOptions("build_options", core_options);
    release_exe.root_module.linkSystemLibrary("c", .{});
    if (target.result.os.tag == .linux) {
        release_exe.root_module.linkSystemLibrary("dl", .{});
    }
    addVulkanIncludes(release_exe.root_module, target.result.os, vulkan_sdk, b);
    if (target.result.os.tag == .windows) {
        release_exe.root_module.linkSystemLibrary("ws2_32", .{});
    }

    const release_install = b.addInstallArtifact(release_exe, .{
        .dest_dir = .{ .override = .{ .custom = "ghost_release" } },
    });
    release_step.dependOn(&release_install.step);

    // Release packaging no longer shells out to `cmd /c`.

    // ── 12. Unicode Resonance Probe ──
    const unicode_probe = b.addExecutable(.{
        .name = "unicode_probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/unicode_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    unicode_probe.root_module.addImport("ghost_core", ghost_core);
    unicode_probe.root_module.linkSystemLibrary("c", .{});
    if (target.result.os.tag == .linux) {
        unicode_probe.root_module.linkSystemLibrary("dl", .{});
    }
    const run_unicode_probe = b.addRunArtifact(unicode_probe);
    const unicode_step = b.step("probe-unicode", "Run Unicode Resonance Probe");
    unicode_step.dependOn(&run_unicode_probe.step);

    // ── 13. Tools: Seed Lattice & Generate Corpus ──
    const seed_exe = b.addExecutable(.{
        .name = "seed_lattice",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/seed_lattice.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    seed_exe.root_module.addImport("ghost_core", ghost_core);
    seed_exe.root_module.linkSystemLibrary("c", .{});
    if (target.result.os.tag == .linux) {
        seed_exe.root_module.linkSystemLibrary("dl", .{});
    }
    const run_seed = b.addRunArtifact(seed_exe);
    const seed_step = b.step("seed", "Initialize the seeded platform state files (lattice, semantic monolith, tags)");
    seed_step.dependOn(&run_seed.step);

    const corpus_exe = b.addExecutable(.{
        .name = "gen_corpus",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gen_corpus.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    corpus_exe.root_module.addImport("ghost_core", ghost_core);
    corpus_exe.root_module.linkSystemLibrary("c", .{});
    if (target.result.os.tag == .linux) {
        corpus_exe.root_module.linkSystemLibrary("dl", .{});
    }
    const run_corpus = b.addRunArtifact(corpus_exe);
    const corpus_step = b.step("corpus", "Generate the mixed_sovereign.txt test corpus");
    corpus_step.dependOn(&run_corpus.step);
}
