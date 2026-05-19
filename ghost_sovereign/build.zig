const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const modules = makeGhostModules(b, target, optimize);

    const exe = b.addExecutable(.{
        .name = "ghost_core",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    addGhostImports(exe.root_module, modules);
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

    const sovereign_interface_tests = b.addTest(.{
        .root_source_file = b.path("src/adapters/sovereign_interface.zig"),
        .target = target,
        .optimize = optimize,
    });
    addGhostImports(sovereign_interface_tests.root_module, modules);
    const run_sovereign_interface_tests = b.addRunArtifact(sovereign_interface_tests);
    test_step.dependOn(&run_sovereign_interface_tests.step);

    const grammar_pulse_tests = b.addTest(.{
        .root_source_file = b.path("src/adapters/grammar_pulse.zig"),
        .target = target,
        .optimize = optimize,
    });
    addGhostImports(grammar_pulse_tests.root_module, modules);
    const run_grammar_pulse_tests = b.addRunArtifact(grammar_pulse_tests);
    test_step.dependOn(&run_grammar_pulse_tests.step);

    // Synthesis Executables
    const synthesis_files = [_][]const u8{
        "absolute_final_synthesis", "absolute_proof_synthesis", "absolute_synthesis",
        "decoder_synthesis", "final_merge_synthesis", "ghost_infinity_synthesis",
        "ghost_null_synthesis", "ghost_zero_synthesis", "grounded_singularity_synthesis",
        "hardware_mirror_synthesis", "infinity_stress_test", "ingestion_strategy_synthesis",
        "native_mirror_synthesis", "null_manifesto_synthesis", "primitive_resonance_synthesis",
        "probe_map", "reiteration_synthesis", "simd_resonance_synthesis", "vsa_leap_synthesis",
        "wiki_ingestion_synthesis", "zero_scalar_proof", "zero_unit_synthesis", "entangled_singularity_synthesis", "bridge_synthesis", "neologism_bridge_synthesis", "cli_overhaul_synthesis", "wave2_synthesis", "truth_verdict_synthesis", "wave3_synthesis", "semantic_overlap_synthesis",
    };

    for (synthesis_files) |name| {
        const synth_exe = b.addExecutable(.{
            .name = name,
            .root_source_file = b.path(b.fmt("src/synthesis/{s}.zig", .{name})),
            .target = target,
            .optimize = optimize,
        });
        addGhostImports(synth_exe.root_module, modules);
        b.installArtifact(synth_exe);
    }

    // Main Engine Adapters
    const chat = b.addExecutable(.{
        .name = "chat",
        .root_source_file = b.path("src/adapters/chat.zig"),
        .target = target,
        .optimize = optimize,
    });
    addGhostImports(chat.root_module, modules);
    b.installArtifact(chat);
    const run_chat = b.addRunArtifact(chat);
    if (b.args) |args| run_chat.addArgs(args);
    const chat_step = b.step("chat", "Run the Ghost Chat Steering Wheel");
    chat_step.dependOn(&run_chat.step);

    const alien = b.addExecutable(.{
        .name = "ghost_alien_voice",
        .root_source_file = b.path("src/adapters/aetheric_adapter.zig"),
        .target = target,
        .optimize = optimize,
    });
    addGhostImports(alien.root_module, modules);
    b.installArtifact(alien);

    const void_adapter = b.addExecutable(.{
        .name = "ghost_invent_void",
        .root_source_file = b.path("src/adapters/void_cli_adapter.zig"),
        .target = target,
        .optimize = optimize,
    });
    addGhostImports(void_adapter.root_module, modules);
    b.installArtifact(void_adapter);

    const search = b.addExecutable(.{
        .name = "ghost_search",
        .root_source_file = b.path("src/adapters/search.zig"),
        .target = target,
        .optimize = optimize,
    });
    addGhostImports(search.root_module, modules);
    b.installArtifact(search);

    const infinity_exe = b.addExecutable(.{
        .name = "ghost_infinity",
        .root_source_file = b.path("src/adapters/infinity_adapter.zig"),
        .target = target,
        .optimize = optimize,
    });
    addGhostImports(infinity_exe.root_module, modules);
    b.installArtifact(infinity_exe);

    const null_exe = b.addExecutable(.{
        .name = "ghost_null",
        .root_source_file = b.path("src/adapters/ghost_null_adapter.zig"),
        .target = target,
        .optimize = optimize,
    });
    addGhostImports(null_exe.root_module, modules);
    b.installArtifact(null_exe);

    const absolute_proof_exe = b.addExecutable(.{
        .name = "ghost_absolute_proof",
        .root_source_file = b.path("src/adapters/ghost_absolute_proof_adapter.zig"),
        .target = target,
        .optimize = optimize,
    });
    addGhostImports(absolute_proof_exe.root_module, modules);
    b.installArtifact(absolute_proof_exe);

    const grounded_probe = b.addExecutable(.{
        .name = "ghost_grounded_probe",
        .root_source_file = b.path("src/adapters/ghost_grounded_probe.zig"),
        .target = target,
        .optimize = optimize,
    });
    addGhostImports(grounded_probe.root_module, modules);
    b.installArtifact(grounded_probe);

    const zeroscalar_probe = b.addExecutable(.{
        .name = "ghost_zeroscalar_probe",
        .root_source_file = b.path("src/adapters/ghost_zeroscalar_probe.zig"),
        .target = target,
        .optimize = optimize,
    });
    addGhostImports(zeroscalar_probe.root_module, modules);
    b.installArtifact(zeroscalar_probe);

    const final_probe = b.addExecutable(.{
        .name = "ghost_final_probe",
        .root_source_file = b.path("src/adapters/ghost_final_probe.zig"),
        .target = target,
        .optimize = optimize,
    });
    addGhostImports(final_probe.root_module, modules);
    b.installArtifact(final_probe);

    const reproduce_baseline = b.addExecutable(.{
        .name = "reproduce_baseline",
        .root_source_file = b.path("src/reproduce_baseline.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(reproduce_baseline);

    const absolute_exe = b.addExecutable(.{
        .name = "ghost_absolute",
        .root_source_file = b.path("src/adapters/ghost_absolute_adapter.zig"),
        .target = target,
        .optimize = optimize,
    });
    addGhostImports(absolute_exe.root_module, modules);
    b.installArtifact(absolute_exe);

    const calibration_absolute = b.addExecutable(.{
        .name = "calibration_absolute",
        .root_source_file = b.path("src/adapters/calibration_absolute.zig"),
        .target = target,
        .optimize = optimize,
    });
    addGhostImports(calibration_absolute.root_module, modules);
    b.installArtifact(calibration_absolute);

    const throughput_bench = b.addExecutable(.{
        .name = "ghost_throughput_bench",
        .root_source_file = b.path("src/adapters/ghost_throughput_bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    addGhostImports(throughput_bench.root_module, modules);
    b.installArtifact(throughput_bench);

    const sovereign_interface = b.addExecutable(.{
        .name = "sovereign_interface",
        .root_source_file = b.path("src/adapters/sovereign_interface.zig"),
        .target = target,
        .optimize = optimize,
    });
    addGhostImports(sovereign_interface.root_module, modules);
    b.installArtifact(sovereign_interface);

    const grammar_pulse = b.addExecutable(.{
        .name = "grammar_pulse",
        .root_source_file = b.path("src/adapters/grammar_pulse.zig"),
        .target = target,
        .optimize = optimize,
    });
    addGhostImports(grammar_pulse.root_module, modules);
    b.installArtifact(grammar_pulse);

    const bridge_transceiver = b.addExecutable(.{
        .name = "bridge_transceiver",
        .root_source_file = b.path("src/adapters/bridge_transceiver.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(bridge_transceiver);

    const anchor_readout = b.addExecutable(.{
        .name = "anchor_readout",
        .root_source_file = b.path("src/adapters/anchor_readout.zig"),
        .target = target,
        .optimize = optimize,
    });
    addGhostImports(anchor_readout.root_module, modules);
    b.installArtifact(anchor_readout);

    const anchor_distribution = b.addExecutable(.{
        .name = "anchor_distribution",
        .root_source_file = b.path("src/adapters/anchor_distribution.zig"),
        .target = target,
        .optimize = optimize,
    });
    addGhostImports(anchor_distribution.root_module, modules);
    b.installArtifact(anchor_distribution);

    const persistence_check = b.addExecutable(.{
        .name = "persistence_check",
        .root_source_file = b.path("src/adapters/persistence_check.zig"),
        .target = target,
        .optimize = optimize,
    });
    addGhostImports(persistence_check.root_module, modules);
    b.installArtifact(persistence_check);

    const anchor_readout_tests = b.addTest(.{
        .root_source_file = b.path("src/adapters/anchor_readout.zig"),
        .target = target,
        .optimize = optimize,
    });
    addGhostImports(anchor_readout_tests.root_module, modules);
    const run_anchor_readout_tests = b.addRunArtifact(anchor_readout_tests);
    test_step.dependOn(&run_anchor_readout_tests.step);

    const anchor_distribution_tests = b.addTest(.{
        .root_source_file = b.path("src/adapters/anchor_distribution.zig"),
        .target = target,
        .optimize = optimize,
    });
    addGhostImports(anchor_distribution_tests.root_module, modules);
    const run_anchor_distribution_tests = b.addRunArtifact(anchor_distribution_tests);
    test_step.dependOn(&run_anchor_distribution_tests.step);

    const understanding_bench = b.addExecutable(.{
        .name = "understanding_bench",
        .root_source_file = b.path("src/adapters/understanding_bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    addGhostImports(understanding_bench.root_module, modules);
    b.installArtifact(understanding_bench);

    const understanding_bench_tests = b.addTest(.{
        .root_source_file = b.path("src/adapters/understanding_bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    addGhostImports(understanding_bench_tests.root_module, modules);
    const run_understanding_bench_tests = b.addRunArtifact(understanding_bench_tests);
    test_step.dependOn(&run_understanding_bench_tests.step);
}

const GhostModules = struct {
    flame: *std.Build.Module,
    void: *std.Build.Module,
    flux: *std.Build.Module,
    vsa: *std.Build.Module,
    vsa_decoder: *std.Build.Module,
    aetheric: *std.Build.Module,
    sovereign: *std.Build.Module,
    lore: *std.Build.Module,
    manifold: *std.Build.Module,
    absolute_final: *std.Build.Module,
    absolute_archived: *std.Build.Module,
    absolute_production: *std.Build.Module,
    absolute_proof_core: *std.Build.Module,
    grounded_core: *std.Build.Module,
    infinity_core: *std.Build.Module,
    null_core: *std.Build.Module,
};

fn makeGhostModules(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) GhostModules {
    const modules = GhostModules{
        .flame = b.createModule(.{ .root_source_file = b.path("src/flame.zig"), .target = target, .optimize = optimize }),
        .void = b.createModule(.{ .root_source_file = b.path("src/void.zig"), .target = target, .optimize = optimize }),
        .flux = b.createModule(.{ .root_source_file = b.path("src/flux.zig"), .target = target, .optimize = optimize }),
        .vsa = b.createModule(.{ .root_source_file = b.path("src/vsa.zig"), .target = target, .optimize = optimize }),
        .vsa_decoder = b.createModule(.{ .root_source_file = b.path("src/adapters/vsa_decoder.zig"), .target = target, .optimize = optimize }),
        .aetheric = b.createModule(.{ .root_source_file = b.path("src/aetheric.zig"), .target = target, .optimize = optimize }),
        .sovereign = b.createModule(.{ .root_source_file = b.path("src/sovereign.zig"), .target = target, .optimize = optimize }),
        .lore = b.createModule(.{ .root_source_file = b.path("src/lore.zig"), .target = target, .optimize = optimize }),
        .manifold = b.createModule(.{ .root_source_file = b.path("src/manifold.zig"), .target = target, .optimize = optimize }),
        .absolute_final = b.createModule(.{ .root_source_file = b.path("src/absolute_final.zig"), .target = target, .optimize = optimize }),
        .absolute_archived = b.createModule(.{ .root_source_file = b.path("src/archived_cores/absolute.zig"), .target = target, .optimize = optimize }),
        .absolute_production = b.createModule(.{ .root_source_file = b.path("src/archived_cores/absolute_production.zig"), .target = target, .optimize = optimize }),
        .absolute_proof_core = b.createModule(.{ .root_source_file = b.path("src/archived_cores/absolute_proof_core.zig"), .target = target, .optimize = optimize }),
        .grounded_core = b.createModule(.{ .root_source_file = b.path("src/archived_cores/grounded_core.zig"), .target = target, .optimize = optimize }),
        .infinity_core = b.createModule(.{ .root_source_file = b.path("src/archived_cores/infinity.zig"), .target = target, .optimize = optimize }),
        .null_core = b.createModule(.{ .root_source_file = b.path("src/archived_cores/null_core.zig"), .target = target, .optimize = optimize }),
    };

    addGhostImports(modules.flame, modules);
    addGhostImports(modules.void, modules);
    addGhostImports(modules.flux, modules);
    addGhostImports(modules.vsa, modules);
    addGhostImports(modules.vsa_decoder, modules);
    addGhostImports(modules.aetheric, modules);
    addGhostImports(modules.sovereign, modules);
    addGhostImports(modules.lore, modules);
    addGhostImports(modules.manifold, modules);
    addGhostImports(modules.absolute_final, modules);
    addGhostImports(modules.absolute_archived, modules);
    addGhostImports(modules.absolute_production, modules);
    addGhostImports(modules.absolute_proof_core, modules);
    addGhostImports(modules.grounded_core, modules);
    addGhostImports(modules.infinity_core, modules);
    addGhostImports(modules.null_core, modules);
    return modules;
}

fn addGhostImports(module: *std.Build.Module, modules: GhostModules) void {
    module.addImport("flame", modules.flame);
    module.addImport("void", modules.void);
    module.addImport("flux", modules.flux);
    module.addImport("vsa", modules.vsa);
    module.addImport("vsa_decoder", modules.vsa_decoder);
    module.addImport("aetheric", modules.aetheric);
    module.addImport("sovereign", modules.sovereign);
    module.addImport("lore", modules.lore);
    module.addImport("manifold", modules.manifold);
    module.addImport("absolute_final", modules.absolute_final);
    module.addImport("absolute_archived", modules.absolute_archived);
    module.addImport("absolute_production", modules.absolute_production);
    module.addImport("absolute_proof_core", modules.absolute_proof_core);
    module.addImport("grounded_core", modules.grounded_core);
    module.addImport("infinity_core", modules.infinity_core);
    module.addImport("null_core", modules.null_core);
}
