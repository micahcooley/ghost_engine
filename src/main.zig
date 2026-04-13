const std = @import("std");
const core = @import("ghost_core");
const sys = core.sys;
const vsa = core.vsa;
const ghost_state = core.ghost_state;
const vsa_vulkan = core.vsa_vulkan;
const engine_logic = core.engine;
const config = core.config;
const sigil_runtime = core.sigil_runtime;
const sigil_vm = core.sigil_vm;
const shell = @import("shell.zig");

const builtin = @import("builtin");
const WINAPI = if (builtin.os.tag == .windows) std.builtin.CallingConvention.winapi else .C;
extern "kernel32" fn SetConsoleCtrlHandler(handler: ?*const fn (u32) callconv(WINAPI) i32, add: i32) callconv(WINAPI) i32;

var global_vk_engine: ?*vsa_vulkan.VulkanEngine = null;
var global_shutdown_requested = std.atomic.Value(bool).init(false);

var global_mapped_lattice: ?sys.MappedFile = null;
var global_mapped_meaning: ?sys.MappedFile = null;
var global_mapped_tags: ?sys.MappedFile = null;
var global_lattice_data: ?[]u16 = null;
var global_meaning_data: ?[]u32 = null;
var global_tags_data: ?[]u64 = null;

fn requestShutdown() bool {
    return global_shutdown_requested.cmpxchgStrong(false, true, .acq_rel, .acquire) == null;
}

fn isShutdownRequested() bool {
    return global_shutdown_requested.load(.acquire);
}

fn crystallizeStateAndExit() noreturn {
    _ = shell.requestStop();
    if (global_vk_engine) |vk| {
        if (global_lattice_data != null and global_meaning_data != null and global_tags_data != null) {
            vk.syncDeviceToHost(global_meaning_data.?, global_tags_data.?, global_lattice_data.?) catch |err| {
                sys.print("\n[FATAL] Failed to sync GPU to Host: {any}\n", .{err});
            };
        }
        vsa_vulkan.deinitRuntime();
        global_vk_engine = null;
    }
    if (global_mapped_lattice) |m| sys.flushMappedMemory(&m);
    if (global_mapped_meaning) |m| sys.flushMappedMemory(&m);
    if (global_mapped_tags) |m| sys.flushMappedMemory(&m);

    sys.printOut("[MONOLITH] State crystallized. Clean exit.\n");
    sys.exit(0);
}

fn ctrlHandler(ctrl_type: u32) callconv(WINAPI) i32 {
    if (ctrl_type == 0) {
        if (requestShutdown()) {
            sys.printOut("\n[SIGNAL] Interrupt detected. Halting new work...\n");
        }
        _ = shell.requestStop();
        crystallizeStateAndExit();
    }
    return 1;
}

fn executeBootSigil(
    allocator: std.mem.Allocator,
    control: *sigil_runtime.ControlPlane,
    meaning: *vsa.MeaningMatrix,
    soul: *ghost_state.GhostSoul,
    lattice: *ghost_state.UnifiedLattice,
) !void {
    var vm_ctx = sigil_vm.Context{
        .allocator = allocator,
        .control = control,
        .meaning = meaning,
        .soul = soul,
        .lattice = lattice,
    };

    const boot_path = try config.getPath(allocator, "boot.sigil");
    defer allocator.free(boot_path);

    sigil_vm.executeFile(&vm_ctx, boot_path) catch |err| switch (err) {
        error.FileNotFound => {
            control.enable_vulkan = true;
            sys.printOut("[SIGIL BOOT] No boot.sigil found. Falling back to default VULKAN_INIT.\n");
        },
        else => return err,
    };
}

pub fn main_wrapped(init: std.process.Init) !void {
    if (builtin.os.tag == .windows) {
        _ = SetConsoleCtrlHandler(ctrlHandler, 1);
    }

    const allocator = init.gpa;
    _ = init.io;

    sys.printOut("[MONOLITH] Mapping Cortex...\n");

    const lattice_abs_path = try config.getPath(allocator, config.LATTICE_REL_PATH);
    const semantic_abs_path = try config.getPath(allocator, config.SEMANTIC_REL_PATH);
    const tag_abs_path = try config.getPath(allocator, config.TAG_REL_PATH);
    defer allocator.free(lattice_abs_path);
    defer allocator.free(semantic_abs_path);
    defer allocator.free(tag_abs_path);

    const mapped_lattice = sys.createMappedFile(allocator, lattice_abs_path, config.UNIFIED_SIZE_BYTES) catch |err| {
        sys.print("\n[FATAL] Failed to map Unified Lattice: {any}\n", .{err});
        sys.print("[HINT] Ensure you have run .\\tools\\seed_lattice.ps1 to create the 1GB state files.\n", .{});
        sys.exit(1);
    };
    if (mapped_lattice.data.len < config.UNIFIED_SIZE_BYTES) return error.LatticeMapFailed;

    const lattice: *ghost_state.UnifiedLattice = @as(*ghost_state.UnifiedLattice, @ptrCast(@alignCast(mapped_lattice.data.ptr)));

    sys.printOut("[CHECKSUM] Verifying Lattice Integrity (16 Blocks / 64MB each)...\n");
    var corrupted_blocks: u32 = 0;
    inline for (0..16) |block_idx| {
        if (!lattice.verifyBlock(block_idx)) {
            sys.print("[FATAL] Block {d} corruption detected. Resetting block (data lost)...\n", .{block_idx});
            lattice.resetBlock(block_idx);
            corrupted_blocks += 1;
        }
    }
    if (corrupted_blocks > 0) {
        sys.printOut("[CHECKSUM] Block reset complete. {d} blocks zeroed (awaiting re-etch).\n");
    } else {
        sys.printOut("[CHECKSUM] All blocks verified. Checksums match.\n");
    }
    mapped_lattice.flush(); // V31: Commit hashes to disk immediately
    const mapped_meaning = sys.createMappedFile(allocator, semantic_abs_path, config.SEMANTIC_SIZE_BYTES) catch |err| {
        sys.print("\n[FATAL] Failed to map Semantic Monolith: {any}\n", .{err});
        sys.exit(1);
    };
    const mapped_tags = sys.createMappedFile(allocator, tag_abs_path, config.TAG_SIZE_BYTES) catch |err| {
        sys.print("\n[FATAL] Failed to map Semantic Tags: {any}\n", .{err});
        sys.exit(1);
    };

    var meaning_matrix = vsa.MeaningMatrix{ .data = @as([*]u32, @ptrCast(@alignCast(mapped_meaning.data.ptr)))[0..(config.SEMANTIC_ENTRIES)], .tags = @as([*]u64, @ptrCast(@alignCast(mapped_tags.data.ptr)))[0..config.TAG_ENTRIES] };

    var soul = try ghost_state.GhostSoul.init(allocator);
    defer soul.deinit();
    soul.meaning_matrix = &meaning_matrix;

    var sigil_control = sigil_runtime.ControlPlane.init(allocator);
    defer sigil_control.deinit();
    sigil_runtime.setActive(&sigil_control);
    defer sigil_runtime.setActive(null);

    try executeBootSigil(allocator, &sigil_control, &meaning_matrix, &soul, lattice);

    global_mapped_lattice = mapped_lattice;
    global_mapped_meaning = mapped_meaning;
    global_mapped_tags = mapped_tags;
    global_lattice_data = @as([*]u16, @ptrCast(@alignCast(mapped_lattice.data.ptr)))[0 .. mapped_lattice.data.len / @sizeOf(u16)];
    global_meaning_data = meaning_matrix.data;
    global_tags_data = meaning_matrix.tags;

    if (!sigil_control.force_cpu_only and sigil_control.enable_vulkan) {
        sys.printOut("[VULKAN] Initializing Sovereign Compute...\n");
        if (vsa_vulkan.initRuntime(allocator, init.io)) |vk| {
            global_vk_engine = vk;
            vk.bindHostState(meaning_matrix.data, meaning_matrix.tags.?, global_lattice_data.?);
            sys.printOut("[COMPUTE] Ghost-Vulkan-Native active.\n");
        } else |_| sys.printOut("[COMPUTE] GPU not available. Running in CPU-only mode.\n");
    } else {
        sys.printOut("[COMPUTE] Sigil boot selected CPU-only mode.\n");
    }

    var state_queue = try core.sync.StateQueue.init(allocator, 1024);
    defer state_queue.deinit(allocator);

    var shell_engine = engine_logic.SingularityEngine{
        .lattice = lattice,
        .meaning = &meaning_matrix,
        .soul = &soul,
        .canvas = try ghost_state.MesoLattice.initText(allocator),
        .is_live = false,
        .vulkan = vsa_vulkan.getEngine(),
        .allocator = allocator,
    };

    const args = try sys.getArgs(allocator);
    var daemon_mode = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--daemon")) daemon_mode = true;
    }

    if (daemon_mode) {
        const surveil = try allocator.create(core.surveillance.SovereignSurveillance);
        surveil.* = core.surveillance.SovereignSurveillance.init(allocator, &soul, &meaning_matrix, lattice, &state_queue);

        // The bridge outlives this stack frame, so it must own heap-backed state.
        const bridge_thread = try std.Thread.spawn(.{ .allocator = allocator }, core.surveillance.SovereignSurveillance.startBridge, .{surveil});
        bridge_thread.detach();
    }

    try shell.startEmbedded(.{
        .allocator = allocator,
        .io = init.io,
        .soul = &soul,
        .live_engine = &shell_engine,
        .lattice_file = mapped_lattice,
        .meaning_file = mapped_meaning,
        .tags_file = mapped_tags,
        .lattice_words = global_lattice_data.?,
        .meaning_words = global_meaning_data.?,
        .tags_words = global_tags_data.?,
    });

    if (daemon_mode) {
        while (!isShutdownRequested()) {
            sys.sleep(100);
        }
        crystallizeStateAndExit();
    }

    while (!isShutdownRequested()) {
        var loop_arena = std.heap.ArenaAllocator.init(allocator);
        defer loop_arena.deinit();
        const loop_allocator = loop_arena.allocator();

        // Safe Window: Drain the lock-free state queue before next interaction
        {
            shell.lockInference();
            defer shell.unlockInference();
            while (state_queue.pop()) |diff| {
                _ = try soul.absorb(diff.vector, diff.rune, null);
            }
        }

        sys.printOut("User > ");
        var input_buf: [1024]u8 = undefined;
        const raw_line = sys.readStdin(&input_buf) catch break;
        if (raw_line.len == 0) break;
        if (isShutdownRequested()) break;
        const prompt = std.mem.trim(u8, raw_line, " \r\n");
        if (prompt.len == 0) continue;

        // --- THE INNOVATION: Unicode Iterator ---
        var utf8 = (std.unicode.Utf8View.init(prompt) catch {
            sys.printOut("[SAFETY] Invalid UTF-8 sequence detected. Filtering...\n");
            continue;
        }).iterator();

        shell.lockInference();
        defer shell.unlockInference();

        while (utf8.nextCodepoint()) |rune| {
            _ = try soul.absorb(vsa.generate(rune), rune, null);
        }

        sys.printOut("Ghost > ");
        const generation_start_concept = soul.concept;
        var engine = engine_logic.SingularityEngine{
            .lattice = lattice,
            .meaning = &meaning_matrix,
            .soul = &soul,
            .canvas = try ghost_state.MesoLattice.initText(loop_allocator),
            .is_live = sys.isTrainerActive(loop_allocator),
            .vulkan = vsa_vulkan.getEngine(),
            .allocator = loop_allocator,
        };
        defer engine.canvas.deinit();

        // Task 3: Safety Valve Generation
        var runes_generated: u32 = 0;
        const MAX_RUNES = 2048;

        while (runes_generated < MAX_RUNES and !isShutdownRequested()) : (runes_generated += 1) {
            // Drain queue even during generation for real-time external influence
            while (state_queue.pop()) |diff| {
                _ = try soul.absorb(diff.vector, diff.rune, null);
            }

            // Interrupt check: Check if bridge sent a 'STOP' command
            if (sys.pollStdin()) {
                var stop_buf: [64]u8 = undefined;
                const int_line = sys.readStdin(&stop_buf) catch "";
                if (std.mem.indexOf(u8, int_line, "STOP") != null) {
                    sys.printOut("\n[INTERRUPT] Generation halted by user signal.\n");
                    break;
                }
            }

            const chosen = engine.resolveTopology() orelse break;
            var utf8_buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(@intCast(chosen), &utf8_buf) catch 1;
            sys.printOut(utf8_buf[0..len]);

            engine.inventory[engine.inv_cursor] = if (len == 1) utf8_buf[0] else '?';
            engine.inv_cursor = (engine.inv_cursor + 1) % 128;
            _ = try soul.absorb(vsa.generate(chosen), chosen, null);
            if (soul.last_boundary == .paragraph or vsa.hammingDistance(soul.concept, generation_start_concept) > 450) break;
        }
        if (runes_generated == MAX_RUNES) {
            sys.printOut("\n[SAFETY] Concept Drift Limit: Forced Break.\n");
        }
        sys.printOut("\n\n");
    }

    crystallizeStateAndExit();
}

test "Sovereign Pipeline: Golden Run" {
    const testing = std.testing;
    const allocator = std.testing.allocator;

    sys.printOut("\n[TEST] Initializing Golden Pipeline...\n");

    // 1. Initialize an empty 10MB memory-mapped lattice for testing
    const test_lattice_path = "state/test_lattice.bin";
    const mapped_lattice = try sys.createMappedFile(allocator, test_lattice_path, config.TEST_LATTICE_SIZE);
    var m = mapped_lattice;
    defer m.unmap();

    // We need to zero it out for a clean test
    @memset(mapped_lattice.data, 0);

    // 2. Mock Meaning Matrix (Heap allocated for test)
    const meaning_entries = 1024 * 1024;
    const meaning_data = try allocator.alloc(u32, meaning_entries);
    defer allocator.free(meaning_data);
    const tag_entries = 1024;
    const tag_data = try allocator.alloc(u64, tag_entries);
    defer allocator.free(tag_data);
    @memset(meaning_data, 0);
    @memset(tag_data, 0);

    var meaning_matrix = vsa.MeaningMatrix{
        .data = meaning_data,
        .tags = tag_data,
    };

    // 3. Initialize Soul
    var soul = try ghost_state.GhostSoul.init(allocator);
    defer soul.deinit();
    soul.meaning_matrix = &meaning_matrix;

    // 4. Run a sequence on the TEST_STRING
    sys.printOut("[TEST] Etching Test String...\n");

    for (config.TEST_STRING) |byte| {
        const vec = vsa.generate(byte);
        _ = try soul.absorb(vec, byte, null);
    }

    try testing.expect(soul.lexical_rotor != ghost_state.FNV_OFFSET_BASIS);
    sys.printOut("[TEST] Golden Run: SUCCESS\n");
}

pub fn main(init: std.process.Init) void {
    main_wrapped(init) catch |err| {
        sys.print("\n[MONOLITH] Panic: {any}\n", .{err});
        std.process.exit(1);
    };
}
