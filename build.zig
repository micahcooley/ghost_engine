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
    core_options.addOption([]const u8, "ghost_version", "V31");
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
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const core_options = addCoreOptions(b, target, false);

    // ── 1. External Dependencies (Vulkan headers only) ──
    // NOTE: We do NOT link against vulkan-1.dll at build time.
    // The DLL is loaded dynamically at runtime via LoadLibraryA.
    // If the DLL is missing (no GPU driver), the engine falls back to CPU mode.
    const vulkan_sdk = b.graph.environ_map.get("VULKAN_SDK");

    // ── 2. Sovereign Core Module ──
    const ghost_core = b.createModule(.{
        .root_source_file = b.path("src/ghost.zig"),
    });
    ghost_core.addOptions("build_options", core_options);
    if (target.result.os.tag == .windows) {
        if (vulkan_sdk) |sdk| {
            ghost_core.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "Include" }) });
        }
    }

    // Helper: add Vulkan include path to any module that imports ghost_core
    // (needed because @cImport in vulkan_loader.zig resolves headers at the root_module level)
    const addVulkanIncludes = struct {
        fn add(mod: *std.Build.Module, os: std.Target.Os, sdk_opt: ?[]const u8, builder: *std.Build) void {
            if (os.tag == .windows) {
                if (sdk_opt) |sdk| {
                    mod.addIncludePath(.{ .cwd_relative = builder.pathJoin(&.{ sdk, "Include" }) });
                }
            }
        }
    }.add;

    // ── 3. Shader SPIR-V (Pre-compiled, embedded via @embedFile) ──
    const shader_names = [_][]const u8{ "resonance_query", "genesis_etch", "thermal_prune", "recursive_lookahead", "lattice_etch" };
    for (shader_names) |name| {
        const spv_path = b.pathJoin(&.{ "src", "shaders", b.fmt("{s}.spv", .{name}) });
        _ = b.path(spv_path);
    }

    // Helper: configure an executable with ghost_core (no Vulkan link-time dependency)
    const ExeConfig = struct {
        name: []const u8,
        root: []const u8,
    };
    const exes = [_]ExeConfig{
        .{ .name = "ghost_sovereign", .root = "src/main.zig" },
        .{ .name = "ohl_trainer", .root = "src/trainer.zig" },
        .{ .name = "probe_inference", .root = "src/probe_inference.zig" },
        .{ .name = "sigil_core", .root = "src/sigil_core.zig" },
    };

    for (exes) |cfg| {
        const exe = b.addExecutable(.{
            .name = cfg.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(cfg.root),
                .target = target,
                .optimize = optimize,
            }),
        });
        exe.root_module.addImport("ghost_core", ghost_core);
        exe.root_module.addOptions("build_options", core_options);
        exe.root_module.linkSystemLibrary("c", .{});
        addVulkanIncludes(exe.root_module, target.result.os, vulkan_sdk, b);

        if (std.mem.eql(u8, cfg.name, "ghost_sovereign") and target.result.os.tag == .windows) {
            exe.root_module.linkSystemLibrary("ws2_32", .{});
        }

        b.installArtifact(exe);
    }

    // ── 8. Run Step ──
    const ghost_exe = b.addExecutable(.{
        .name = "ghost_sovereign",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    ghost_exe.root_module.addImport("ghost_core", ghost_core);
    ghost_exe.root_module.addOptions("build_options", core_options);
    ghost_exe.root_module.linkSystemLibrary("c", .{});
    addVulkanIncludes(ghost_exe.root_module, target.result.os, vulkan_sdk, b);
    if (target.result.os.tag == .windows) {
        ghost_exe.root_module.linkSystemLibrary("ws2_32", .{});
    }
    const run_cmd = b.addRunArtifact(ghost_exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

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
    }
    main_tests.root_module.addOptions("build_options", test_core_options);
    main_tests.root_module.linkSystemLibrary("c", .{});
    addVulkanIncludes(main_tests.root_module, target.result.os, vulkan_sdk, b);

    const run_main_tests = b.addRunArtifact(main_tests);
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_main_tests.step);

    // ── 10. Parity Test ──
    const parity_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_parity.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    parity_test.root_module.addImport("ghost_core", ghost_core);
    parity_test.root_module.addOptions("build_options", core_options);
    parity_test.root_module.linkSystemLibrary("c", .{});
    addVulkanIncludes(parity_test.root_module, target.result.os, vulkan_sdk, b);

    const run_parity_test = b.addRunArtifact(parity_test);
    const parity_step = b.step("test-parity", "Run Vulkan GPU <-> CPU Parity Tests");
    parity_step.dependOn(&run_parity_test.step);

    // ── 11. Release Packaging ──
    // Creates a clean distributable folder with exe, empty state/, empty corpus/
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
    const run_seed = b.addRunArtifact(seed_exe);
    const seed_step = b.step("seed", "Initialize the 2GB state files (Lattice & Meaning Matrix)");
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
    const run_corpus = b.addRunArtifact(corpus_exe);
    const corpus_step = b.step("corpus", "Generate the mixed_sovereign.txt test corpus");
    corpus_step.dependOn(&run_corpus.step);
}
