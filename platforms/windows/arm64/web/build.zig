const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 1. Shaders (Points back to central src)
    const res_cmd = b.addSystemCommand(&[_][]const u8{
        "C:/VulkanSDK/1.4.341.1/Bin/glslc.exe",
        "-o", "resonance_query.spv", "../../../../../src/resonance_query.comp",
    });
    const etch_cmd = b.addSystemCommand(&[_][]const u8{
        "C:/VulkanSDK/1.4.341.1/Bin/glslc.exe",
        "-o", "genesis_etch.spv", "../../../../../src/genesis_etch.comp",
    });

    const ghost_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const ghost_exe = b.addExecutable(.{
        .name = "ghost_web_node",
        .root_module = ghost_mod,
    });
    
    ghost_exe.root_module.linkSystemLibrary("c", .{});
    ghost_exe.root_module.linkSystemLibrary("vulkan-1", .{});
    ghost_exe.root_module.addIncludePath(.{ .cwd_relative = "C:/VulkanSDK/1.4.341.1/Include" });
    ghost_exe.root_module.addLibraryPath(.{ .cwd_relative = "C:/VulkanSDK/1.4.341.1/Lib" });

    ghost_exe.step.dependOn(&res_cmd.step);
    ghost_exe.step.dependOn(&etch_cmd.step);
    b.installArtifact(ghost_exe);
}
