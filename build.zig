const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── 0. CPU Feature Detection ──
    const arch = target.result.cpu.arch;
    const features = target.result.cpu.features;

    var core_options = b.addOptions();
    const is_x86_64 = arch == .x86_64;
    core_options.addOption(bool, "use_avx2", is_x86_64 and std.Target.x86.featureSetHas(features, .avx2));
    core_options.addOption(bool, "use_neon", arch == .aarch64 or arch == .arm);
    
    // ── 1. External Dependencies (Vulkan) ──
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

    // ── 3. Shader Compilation ──
    const glslc = if (vulkan_sdk) |sdk| b.pathJoin(&.{ sdk, "Bin", "glslc.exe" }) else "glslc";
    const shader_names = [_][]const u8{ "resonance_query", "genesis_etch", "thermal_prune", "recursive_lookahead", "lattice_etch" };
    const shaders_step = b.step("shaders", "Compile SPIR-V Shaders");
    
    // Ensure shaders directory exists in zig-out
    for (shader_names) |name| {
        const input = b.pathJoin(&.{ "src", "shaders", b.fmt("{s}.comp", .{name}) });
        const output = b.pathJoin(&.{ "src", "shaders", b.fmt("{s}.spv", .{name}) });
        const cmd = b.addSystemCommand(&.{ glslc, "-o", output, input });
        shaders_step.dependOn(&cmd.step);
    }

    // ── 4. Ghost Sovereign (Inference) ──
    const ghost_exe = b.addExecutable(.{
        .name = "ghost_sovereign",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    ghost_exe.root_module.addImport("ghost_core", ghost_core);
    ghost_exe.root_module.linkSystemLibrary("c", .{});

    if (target.result.os.tag == .windows) {
        if (vulkan_sdk) |sdk| {
            const include_path = b.pathJoin(&.{ sdk, "Include" });
            const lib_path = b.pathJoin(&.{ sdk, "Lib" });
            ghost_exe.root_module.addIncludePath(.{ .cwd_relative = include_path });
            ghost_exe.root_module.addLibraryPath(.{ .cwd_relative = lib_path });
        }
        ghost_exe.root_module.linkSystemLibrary("vulkan-1", .{});
    } else {
        ghost_exe.root_module.linkSystemLibrary("vulkan", .{});
    }
    
    b.installArtifact(ghost_exe);

    // ── 4. OHL Trainer ──
    const trainer_exe = b.addExecutable(.{
        .name = "ohl_trainer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/trainer.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    trainer_exe.root_module.addImport("ghost_core", ghost_core);
    trainer_exe.root_module.linkSystemLibrary("c", .{});
    
    if (target.result.os.tag == .windows) {
        if (vulkan_sdk) |sdk| {
            const include_path = b.pathJoin(&.{ sdk, "Include" });
            const lib_path = b.pathJoin(&.{ sdk, "Lib" });
            trainer_exe.root_module.addIncludePath(.{ .cwd_relative = include_path });
            trainer_exe.root_module.addLibraryPath(.{ .cwd_relative = lib_path });
        }
        trainer_exe.root_module.linkSystemLibrary("vulkan-1", .{});
    } else {
        trainer_exe.root_module.linkSystemLibrary("vulkan", .{});
    }

    b.installArtifact(trainer_exe);

    // ── 5. Run Step ──
    const run_cmd = b.addRunArtifact(ghost_exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
