const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "ghost_core",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    const run_step = b.step("run", "Run the Ghost Core probe");
    run_step.dependOn(&run.step);

    const tests = b.addTest(.{
        .root_source_file = b.path("src/flame.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run Ghost Core tests");
    test_step.dependOn(&run_tests.step);

    // Synthesis Executables
    const synthesis_files = [_][]const u8{
        "ask_experts", "audit_experts", "debate_experts", "final_questions",
        "synth_aether_synthesis", "synth_echo_synthesis", "synth_five_round_synthesis",
        "synth_honesty_synthesis", "synth_hyper_manifold_synthesis", "synth_infinite_synthesis",
        "synth_lore_synthesis", "synth_omniscience_synthesis", "synth_pulse_synthesis",
        "synth_spectral_synthesis", "multimodal_synthesis", "omni_modal_synthesis",
        "omni_ingest_verdict", "final_audit", "wave1_timeline", "angry_critic_response",
        "total_audit", "filter_synthesis", "transcendence_synthesis",
        "pros_cons_audit", "final_merge_synthesis", "calibration", "vsa_leap_synthesis", "decoder_synthesis", "wiki_ingestion_synthesis", "ingestion_strategy_synthesis", "ghost_zero_synthesis", "ghost_infinity_synthesis", "infinity_stress_test", "reiteration_synthesis", "ghost_null_synthesis", "null_manifesto_synthesis", "absolute_synthesis", "absolute_proof_synthesis", "grounded_singularity_synthesis", "zero_scalar_proof", "absolute_final_synthesis", "hardware_mirror_synthesis", "native_mirror_synthesis", "simd_resonance_synthesis", "primitive_resonance_synthesis", "zero_unit_synthesis",
    };

    for (synthesis_files) |name| {
        const synth_exe = b.addExecutable(.{
            .name = name,
            .root_source_file = b.path(b.fmt("src/{s}.zig", .{name})),
            .target = target,
            .optimize = optimize,
        });
        b.installArtifact(synth_exe);
    }

    // Main Engine Adapters
    const chat = b.addExecutable(.{
        .name = "chat",
        .root_source_file = b.path("src/chat.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(chat);
    const run_chat = b.addRunArtifact(chat);
    if (b.args) |args| run_chat.addArgs(args);
    const chat_step = b.step("chat", "Run the Ghost Chat Steering Wheel");
    chat_step.dependOn(&run_chat.step);

    const alien = b.addExecutable(.{
        .name = "ghost_alien_voice",
        .root_source_file = b.path("src/aetheric_adapter.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(alien);

    const void_adapter = b.addExecutable(.{
        .name = "ghost_invent_void",
        .root_source_file = b.path("src/void_cli_adapter.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(void_adapter);

    const search = b.addExecutable(.{
        .name = "ghost_search",
        .root_source_file = b.path("src/search.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(search);

    const infinity_exe = b.addExecutable(.{
        .name = "ghost_infinity",
        .root_source_file = b.path("src/infinity_adapter.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(infinity_exe);

    const null_exe = b.addExecutable(.{
        .name = "ghost_null",
        .root_source_file = b.path("src/ghost_null_adapter.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(null_exe);

    const absolute_proof_exe = b.addExecutable(.{
        .name = "ghost_absolute_proof",
        .root_source_file = b.path("src/ghost_absolute_proof_adapter.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(absolute_proof_exe);

    const grounded_probe = b.addExecutable(.{
        .name = "ghost_grounded_probe",
        .root_source_file = b.path("src/ghost_grounded_probe.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(grounded_probe);

    const zeroscalar_probe = b.addExecutable(.{
        .name = "ghost_zeroscalar_probe",
        .root_source_file = b.path("src/ghost_zeroscalar_probe.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(zeroscalar_probe);

    const final_probe = b.addExecutable(.{
        .name = "ghost_final_probe",
        .root_source_file = b.path("src/ghost_final_probe.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(final_probe);

    const absolute_exe = b.addExecutable(.{
        .name = "ghost_absolute",
        .root_source_file = b.path("src/ghost_absolute_adapter.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(absolute_exe);

    const calibration_absolute = b.addExecutable(.{
        .name = "calibration_absolute",
        .root_source_file = b.path("src/calibration_absolute.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(calibration_absolute);
}
