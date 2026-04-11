const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const arch_tag = target.result.cpu.arch;
    const arch_name = if (arch_tag == .x86_64) "x86_64" else "arm64";

    const toolchain_vulkan = b.pathFromRoot("../../.toolchain/Vulkan");
    
    // Zig 0.13.0 compat: b.graph might not be available or might be named differently in older/newer versions.
    // We'll use a safer approach to get the environment variable.
    const vulkan_sdk = b.graph.environ_map.get("VULKAN_SDK") orelse toolchain_vulkan;

    const glslc_path = b.fmt("{s}/Bin/glslc.exe", .{vulkan_sdk});
    
    const vulkan_include = b.fmt("{s}/Include", .{vulkan_sdk});
    const vulkan_lib = b.fmt("{s}/Lib", .{vulkan_sdk});

    // Install directly into the architecture subfolder (e.g., windows/x86_64/bin)
    b.install_path = b.fmt("{s}", .{arch_name});

    // ── 1. Sovereign Core Module (Narrowed to CPU) ──
    const core_path = b.fmt("{s}/src/ghost.zig", .{arch_name});
    const ghost_core = b.createModule(.{
        .root_source_file = b.path(core_path),
    });
    ghost_core.addIncludePath(.{ .cwd_relative = vulkan_include });

    // ── 2. Shader Compilation (Per-CPU) ──
    const shaders = [_][]const u8{ "resonance_query", "genesis_etch", "thermal_prune", "recursive_lookahead", "lattice_etch" };
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
        .name = "ghost_sovereign",
        .root_module = b.createModule(.{
            .root_source_file = b.path(entry_path),
            .target = target,
            .optimize = optimize,
        }),
    });

    ghost_exe.root_module.addImport("ghost_core", ghost_core);
    ghost_exe.root_module.linkSystemLibrary("c", .{});
    ghost_exe.root_module.addIncludePath(.{ .cwd_relative = vulkan_include });
    ghost_exe.root_module.addLibraryPath(.{ .cwd_relative = vulkan_lib });
    ghost_exe.root_module.linkSystemLibrary("vulkan-1", .{});
    
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
    trainer_exe.root_module.addIncludePath(.{ .cwd_relative = vulkan_include });
    trainer_exe.root_module.addLibraryPath(.{ .cwd_relative = vulkan_lib });
    trainer_exe.root_module.linkSystemLibrary("vulkan-1", .{});

    for (&shader_steps) |step| trainer_exe.step.dependOn(step);
    b.installArtifact(trainer_exe);

    // ── 5. Native Plugins ──
    const plugin_api_module = b.createModule(.{
        .root_source_file = b.path(b.fmt("{s}/src/plugin_api.zig", .{arch_name})),
    });

    const optimizer_plugin = b.addLibrary(.{
        .name = "windows_beast",
        .root_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("{s}/src/plugins/windows_optimizer.zig", .{arch_name})),
            .target = target,
            .optimize = optimize,
        }),
        .linkage = .dynamic,
    });
    optimizer_plugin.root_module.addImport("plugin_api", plugin_api_module);

    optimizer_plugin.root_module.linkSystemLibrary("winmm", .{});
    optimizer_plugin.root_module.linkSystemLibrary("powrprof", .{});
    optimizer_plugin.root_module.linkSystemLibrary("c", .{});

    // Install to platforms/windows/<arch>/plugins/
    const install_plugin = b.addInstallArtifact(optimizer_plugin, .{
        .dest_dir = .{ .override = .{ .custom = "plugins" } },
    });

    b.getInstallStep().dependOn(&install_plugin.step);

    // ── 6. Release Step (Zero-Friction Distribution) ──
    const release_step = b.step("release", "Build a distributable release package (Ghost_V23_Release)");
    const release_dir = "Ghost_V23_Release";

    const release_ghost_sovereign = b.addInstallArtifact(ghost_exe, .{
        .dest_dir = .{ .override = .{ .custom = release_dir } },
    });
    const release_ohl_trainer = b.addInstallArtifact(trainer_exe, .{
        .dest_dir = .{ .override = .{ .custom = release_dir } },
    });
    const release_beast_dll = b.addInstallArtifact(optimizer_plugin, .{
        .dest_dir = .{ .override = .{ .custom = b.fmt("{s}/plugins", .{release_dir}) } },
    });

    // Copy guide.md into the release plugins folder
    const release_guide = b.addInstallFile(
        b.path(b.fmt("{s}/plugins/guide.md", .{arch_name})),
        b.fmt("{s}/plugins/guide.md", .{release_dir}),
    );

    // Create an empty 'state' directory in the release folder
    const mkdir_state = b.addSystemCommand(&[_][]const u8{
        "powershell", "-Command",
        b.fmt("New-Item -ItemType Directory -Path {s}/zig-out/{s}/state -Force", .{ b.install_path, release_dir }),
    });

    release_step.dependOn(&release_ghost_sovereign.step);
    release_step.dependOn(&release_ohl_trainer.step);
    release_step.dependOn(&release_beast_dll.step);
    release_step.dependOn(&release_guide.step);
    release_step.dependOn(&mkdir_state.step);
}

