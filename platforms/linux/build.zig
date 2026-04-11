const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const arch_tag = target.result.cpu.arch;
    const arch_name = if (arch_tag == .x86_64) "x86_64" else "arm64";

    // Use system glslc on Linux
    const glslc_path = "glslc";

    // Install directly into the architecture subfolder (e.g., linux/x86_64/bin)
    b.install_path = b.fmt("{s}", .{arch_name});

    // ── 1. Sovereign Core Module (Narrowed to CPU) ──
    const core_path = b.fmt("{s}/src/ghost.zig", .{arch_name});
    const ghost_core = b.createModule(.{
        .root_source_file = b.path(core_path),
    });

    // ── 2. Shader Compilation (Per-CPU) ──
    const shaders = [_][]const u8{ "resonance_query", "genesis_etch", "thermal_prune", "recursive_lookahead" };
    var shader_steps: [shaders.len]*std.Build.Step = undefined;
    for (shaders, 0..) |s, i| {
        const input = b.fmt("{s}/src/shaders/{s}.comp", .{arch_name, s});
        const output = b.fmt("{s}/src/shaders/{s}.spv", .{arch_name, s});
        const cmd = b.addSystemCommand(&[_][]const u8{ glslc_path, "-o", output, input });
        shader_steps[i] = &cmd.step;
    }

    // ── 3. Ghost Pulse (Inference Engine) ──
    const entry_path = b.fmt("{s}/src/main.zig", .{arch_name});
    const ghost_exe = b.addExecutable(.{
        .name = "ghost_pulse",
        .root_module = b.createModule(.{
            .root_source_file = b.path(entry_path),
            .target = target,
            .optimize = optimize,
        }),
    });

    ghost_exe.root_module.addImport("ghost_core", ghost_core);
    ghost_exe.root_module.linkSystemLibrary("c", .{});
    ghost_exe.root_module.linkSystemLibrary("vulkan", .{});
    
    for (&shader_steps) |step| ghost_exe.step.dependOn(step);
    b.installArtifact(ghost_exe);

    // ── 4. OHL Trainer ──
    const trainer_entry = b.fmt("{s}/src/trainer.zig", .{arch_name});
    const trainer_exe = b.addExecutable(.{
        .name = "ohl_trainer",
        .root_module = b.createModule(.{
            .root_source_file = b.path(trainer_entry),
            .target = target,
            .optimize = optimize,
        }),
    });

    trainer_exe.root_module.addImport("ghost_core", ghost_core);
    trainer_exe.root_module.linkSystemLibrary("c", .{});
    trainer_exe.root_module.linkSystemLibrary("vulkan", .{});

    for (&shader_steps) |step| trainer_exe.step.dependOn(step);
    b.installArtifact(trainer_exe);
}
