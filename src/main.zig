const std = @import("std");
const core = @import("ghost_core");
const sys = core.sys;
const vsa = core.vsa;
const ghost_state = core.ghost_state;
const vsa_vulkan = core.vsa_vulkan;
const engine_logic = core.engine;
const mc = core.inference;
const config = core.config;
const shards = core.shards;
const scratchpad = core.scratchpad;
const sigil_runtime = core.sigil_runtime;
const sigil_vm = core.sigil_vm;
const panic_dump = core.panic_dump;
const shell = @import("shell.zig");

pub const panic = std.debug.FullPanic(panic_dump.panicCall);

const builtin = @import("builtin");
const WINAPI = if (builtin.os.tag == .windows) std.builtin.CallingConvention.winapi else .C;
extern "kernel32" fn SetConsoleCtrlHandler(handler: ?*const fn (u32) callconv(WINAPI) i32, add: i32) callconv(WINAPI) i32;
const FILE_ATTRIBUTE_READONLY: u32 = 0x00000001;
const INVALID_FILE_ATTRIBUTES: u32 = 0xFFFFFFFF;
extern "kernel32" fn GetFileAttributesW(lpFileName: [*:0]const u16) callconv(WINAPI) u32;

var global_vk_engine: ?*vsa_vulkan.VulkanEngine = null;
var global_shutdown_requested = std.atomic.Value(bool).init(false);

var global_state_shard: ?shards.MountedStateShard = null;
var global_lattice_provider: ?ghost_state.LatticeProvider = null;
var global_scratchpad: ?scratchpad.ScratchpadLayer = null;
var global_lattice_path: ?[]const u8 = null;
var global_host_lattice_words: ?[]u16 = null;
var global_meaning_data: ?[]u32 = null;
var global_tags_data: ?[]u64 = null;

const INPUT_LINE_CAPACITY = 1024;
const TYPEAHEAD_CAPACITY = 8;

const LaunchConfig = struct {
    daemon_mode: bool = false,
    shell_enabled: bool = true,
    scratchpad_bytes: usize = config.DEFAULT_SCRATCHPAD_BYTES,
    project_shard: ?[]const u8 = null,
    reasoning_mode: sigil_runtime.ReasoningMode = .proof,
    invalid_reasoning_mode: ?[]const u8 = null,
};

const TypeAheadBuffer = struct {
    mutex: core.sync.Mutex = .{},
    lines: [TYPEAHEAD_CAPACITY][INPUT_LINE_CAPACITY]u8 = [_][INPUT_LINE_CAPACITY]u8{[_]u8{0} ** INPUT_LINE_CAPACITY} ** TYPEAHEAD_CAPACITY,
    lens: [TYPEAHEAD_CAPACITY]usize = [_]usize{0} ** TYPEAHEAD_CAPACITY,
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,

    fn push(self: *TypeAheadBuffer, line: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (line.len > INPUT_LINE_CAPACITY) return false;
        if (self.count == TYPEAHEAD_CAPACITY) return false;

        @memcpy(self.lines[self.tail][0..line.len], line);
        self.lens[self.tail] = line.len;
        self.tail = (self.tail + 1) % TYPEAHEAD_CAPACITY;
        self.count += 1;
        return true;
    }

    fn pop(self: *TypeAheadBuffer, dest: []u8) ?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.count == 0) return null;

        const len = self.lens[self.head];
        if (len > dest.len) return null;
        @memcpy(dest[0..len], self.lines[self.head][0..len]);
        self.lens[self.head] = 0;
        self.head = (self.head + 1) % TYPEAHEAD_CAPACITY;
        self.count -= 1;
        return dest[0..len];
    }
};

fn isStopCommand(line: []const u8) bool {
    return std.mem.eql(u8, std.mem.trim(u8, line, " \r\n"), "STOP");
}

fn parseLaunchConfig(args: []const []const u8) LaunchConfig {
    var launch = LaunchConfig{
        .scratchpad_bytes = scratchpadBytesFromEnv() orelse config.DEFAULT_SCRATCHPAD_BYTES,
    };
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--daemon")) {
            launch.daemon_mode = true;
        } else if (std.mem.eql(u8, arg, "--no-shell")) {
            launch.shell_enabled = false;
        } else if (std.mem.startsWith(u8, arg, "--scratchpad-bytes=")) {
            if (parseOptionalUsize(arg["--scratchpad-bytes=".len..])) |bytes| {
                launch.scratchpad_bytes = scratchpad.ScratchpadLayer.normalizeCapacity(bytes);
            }
        } else if (std.mem.startsWith(u8, arg, "--project-shard=")) {
            const shard_id = arg["--project-shard=".len..];
            if (shard_id.len > 0) launch.project_shard = shard_id;
        } else if (std.mem.startsWith(u8, arg, "--reasoning-mode=")) {
            const mode_text = arg["--reasoning-mode=".len..];
            if (sigil_runtime.parseReasoningMode(mode_text)) |mode| {
                launch.reasoning_mode = mode;
            } else if (mode_text.len > 0) {
                launch.invalid_reasoning_mode = mode_text;
            }
        }
    }
    return launch;
}

fn parseOptionalUsize(text: []const u8) ?usize {
    return std.fmt.parseUnsigned(usize, text, 10) catch null;
}

fn scratchpadBytesFromEnv() ?usize {
    const value = std.process.getEnvVarOwned(std.heap.page_allocator, "GHOST_SCRATCHPAD_BYTES") catch return null;
    defer std.heap.page_allocator.free(value);
    const parsed = parseOptionalUsize(value) orelse return null;
    return scratchpad.ScratchpadLayer.normalizeCapacity(parsed);
}

fn requestShutdown() bool {
    return global_shutdown_requested.cmpxchgStrong(false, true, .acq_rel, .acquire) == null;
}

fn isShutdownRequested() bool {
    return global_shutdown_requested.load(.acquire);
}

fn ensureStateFileWritable(path: []const u8, label: []const u8) !void {
    if (builtin.os.tag != .windows) return;

    var wbuf: [1024]u16 = undefined;
    const wlen = std.unicode.utf8ToUtf16Le(&wbuf, path) catch return error.MappingWriteFailed;
    if (wlen >= wbuf.len) return error.MappingWriteFailed;
    wbuf[wlen] = 0;

    const attrs = GetFileAttributesW(@as([*:0]const u16, @ptrCast(&wbuf[0])));
    if (attrs == INVALID_FILE_ATTRIBUTES) return error.MappingWriteFailed;
    if ((attrs & FILE_ATTRIBUTE_READONLY) != 0) {
        sys.print("\n[WARN] {s} is read-only; skipping checksum finalization.\n", .{label});
        return error.MappingWriteFailed;
    }
}

fn finalizeChecksumsSafely(lattice: *ghost_state.LatticeProvider) !void {
    if (global_lattice_path == null) return error.MappingWriteFailed;
    try ensureStateFileWritable(global_lattice_path orelse return error.MappingWriteFailed, "Lattice state");
    try lattice.finalizeChecksums();
}

fn latticeBlockWordRange(block_idx: usize) struct { start: usize, end: usize } {
    const start_byte = block_idx * config.CHECKSUM_BLOCK_SIZE;
    const end_byte = if (block_idx + 1 == ghost_state.UnifiedLattice.BLOCK_COUNT)
        ghost_state.UnifiedLattice.HASH_OFFSET
    else
        start_byte + config.CHECKSUM_BLOCK_SIZE;
    return .{
        .start = start_byte / @sizeOf(u16),
        .end = end_byte / @sizeOf(u16),
    };
}

fn syncPagedLatticeToSlice(provider: *ghost_state.PagedLatticeProvider, dest: []u16) !void {
    for (0..ghost_state.UnifiedLattice.BLOCK_COUNT) |block_idx| {
        const range = latticeBlockWordRange(block_idx);
        var lease = try provider.acquireWords(range.start, range.end - range.start, false);
        defer lease.release();
        @memcpy(dest[range.start..range.end], lease.words());
    }
}

fn syncSliceToPagedLattice(src: []const u16, provider: *ghost_state.PagedLatticeProvider) !void {
    for (0..ghost_state.UnifiedLattice.BLOCK_COUNT) |block_idx| {
        const range = latticeBlockWordRange(block_idx);
        var lease = try provider.acquireWords(range.start, range.end - range.start, true);
        defer lease.release();
        @memcpy(lease.words(), src[range.start..range.end]);
    }
}

fn selectedLatticeCacheCap(control: *sigil_runtime.ControlPlane) u64 {
    const snapshot = control.snapshot();
    return snapshot.lattice_cache_cap_bytes;
}

fn crystallizeStateAndExit() noreturn {
    sys.printOut("[TEARDOWN] Requesting stop...\n");
    _ = shell.requestStop();
    var crystal_integrity_ok = true;
    const had_vk_runtime = global_vk_engine != null;
    const lattice_provider = global_lattice_provider;
    sys.printOut("[TEARDOWN] Waiting for GPU workers to drain...\n");
    if (!shell.waitForBackgroundWorkers(30_000)) {
        sys.printOut("[FATAL] Timed out waiting for GPU workers to drain.\n");
        crystal_integrity_ok = false;
    }
    if (global_vk_engine) |vk| {
        if (crystal_integrity_ok and lattice_provider != null and global_meaning_data != null and global_tags_data != null) {
            sys.printOut("[TEARDOWN] GPU workers drained. Syncing device to host...\n");
            vsa_vulkan.waitForGpuWorkersDrained(vk);
            sys.printOut("[MONOLITH] GPU workers drained.\n");
            if (global_meaning_data) |host_meaning| {
                @memcpy(host_meaning, vk.getMatrixData()[0..host_meaning.len]);
            }
            if (global_tags_data) |host_tags| {
                @memcpy(host_tags, vk.getTagsData()[0..host_tags.len]);
            }
            if (global_state_shard) |*state_shard| {
                if (syncSliceToPagedLattice(vk.getLatticeData(), &state_shard.paged_lattice)) |_| {
                    var provider = lattice_provider.?;
                    if (finalizeChecksumsSafely(&provider)) |_| {
                        provider.flush() catch |err| {
                            sys.print("[WARNING] Pager flush failed: {any}\n", .{err});
                        };
                        sys.printOut("[TEARDOWN] Checksums finalized. Destroying Vulkan context...\n");
                        sys.printOut("[MONOLITH] State checksums finalized.\n");
                    } else |err| {
                        sys.print("\n[WARN] Failed to finalize checksums: {any}\n", .{err});
                    }
                } else |err| {
                    sys.print("\n[FATAL] Failed to sync GPU lattice to pager: {any}\n", .{err});
                    crystal_integrity_ok = false;
                }
            }
        }
    }

    if (had_vk_runtime) {
        vsa_vulkan.deinitRuntime();
        global_vk_engine = null;
        sys.printOut("[TEARDOWN] Vulkan destroyed. Beginning mapped-file handoff...\n");
    }

    if (crystal_integrity_ok and !had_vk_runtime and lattice_provider != null) {
        var provider = lattice_provider.?;
        if (finalizeChecksumsSafely(&provider)) |_| {
            provider.flush() catch |err| {
                sys.print("[WARNING] Pager flush failed: {any}\n", .{err});
            };
            sys.printOut("[MONOLITH] State checksums finalized.\n");
        } else |err| {
            sys.print("\n[WARN] Failed to finalize checksums: {any}\n", .{err});
        }
    }

    if (crystal_integrity_ok) {
        if (lattice_provider) |provider_value| {
            sys.printOut("[TEARDOWN] Flushing paged lattice provider...\n");
            var provider = provider_value;
            provider.flush() catch |err| {
                sys.print("[WARNING] Lattice pager flush failed: {any}\n", .{err});
            };
        }
        if (global_state_shard) |*state_shard| {
            sys.printOut("[TEARDOWN] Flushing and Unmapping Meaning Matrix...\n");
            sys.flushMappedMemory(&state_shard.semantic_file) catch |err| {
                sys.print("[WARNING] Meaning Matrix flush failed: {any}\n", .{err});
            };
            sys.printOut("[TEARDOWN] Flushing and Unmapping Tags...\n");
            sys.flushMappedMemory(&state_shard.tags_file) catch |err| {
                sys.print("[WARNING] Tags flush failed: {any}\n", .{err});
            };
            state_shard.deinit();
            global_state_shard = null;
        }
        sys.printOut("[TEARDOWN] Persisted state flushed.\n");
    }

    if (global_scratchpad) |*scratch| {
        panic_dump.unregisterScratchpad();
        scratch.deinit();
        global_scratchpad = null;
        sys.printOut("[TEARDOWN] Scratchpad released.\n");
    }
    panic_dump.clearRuntimeContext();

    if (global_state_shard) |*state_shard| {
        state_shard.deinit();
        global_state_shard = null;
    }

    if (!crystal_integrity_ok) {
        sys.printOut("[MONOLITH] State crystallization aborted.\n");
        sys.exit(1);
    }

    sys.printOut("[MONOLITH] State crystallized. Clean exit.\n");
    sys.exit(0);
}

fn ctrlHandler(ctrl_type: u32) callconv(WINAPI) i32 {
    if (ctrl_type == 0) {
        if (requestShutdown()) {
            sys.printOut("\n[SIGNAL] Interrupt detected. Halting new work...\n");
        }
        _ = shell.requestStop();
    }
    return 1;
}

fn executeBootSigil(
    allocator: std.mem.Allocator,
    control: *sigil_runtime.ControlPlane,
    meaning: *vsa.MeaningMatrix,
    soul: *ghost_state.GhostSoul,
) !void {
    var meaning_surface = sigil_vm.MeaningSurface{ .permanent = meaning };
    var vm_ctx = sigil_vm.Context{
        .allocator = allocator,
        .control = control,
        .meaning = &meaning_surface,
        .soul = soul,
    };

    const boot_path = try config.getPath(allocator, "boot.sigil");
    defer allocator.free(boot_path);

    sigil_vm.executeFile(&vm_ctx, boot_path) catch |err| switch (err) {
        error.FileNotFound => {
            control.setComputeMode(true, false);
            sys.printOut("[SIGIL BOOT] No boot.sigil found. Falling back to default VULKAN_INIT.\n");
        },
        else => return err,
    };
}

pub fn main_wrapped(allocator: std.mem.Allocator) !void {
    if (builtin.os.tag == .windows) {
        _ = SetConsoleCtrlHandler(ctrlHandler, 1);
    }

    sys.printOut("[MONOLITH] Mapping Cortex...\n");

    const args = try sys.getArgs(allocator);
    const launch = parseLaunchConfig(args);
    if (launch.invalid_reasoning_mode) |mode_text| {
        sys.print("\n[FATAL] Unsupported reasoning mode '{s}'. Use proof or exploratory.\n", .{mode_text});
        sys.exit(1);
    }
    const env_project_shard = std.process.getEnvVarOwned(allocator, "GHOST_PROJECT_SHARD") catch null;
    defer if (env_project_shard) |value| allocator.free(value);
    const selected_project_shard = launch.project_shard orelse env_project_shard;

    global_state_shard = blk: {
        const mounted = if (selected_project_shard) |project_shard_id|
            shards.MountedStateShard.mountProject(allocator, project_shard_id, config.IDEAL_LATTICE_SIZE)
        else
            shards.MountedStateShard.mountCore(allocator, config.IDEAL_LATTICE_SIZE);
        break :blk mounted catch |err| {
            sys.print("\n[FATAL] Failed to initialize paged Unified Lattice: {any}\n", .{err});
            sys.print(
                "[HINT] Seed shard state under {s} before launch.\n",
                .{if (selected_project_shard) |_| config.PROJECT_SHARD_REL_DIR else config.CORE_SHARD_REL_DIR},
            );
            sys.exit(1);
        };
    };
    errdefer {
        global_state_shard.?.deinit();
        global_state_shard = null;
    }
    var lattice_provider = global_state_shard.?.latticeProvider();

    sys.print(
        "[CHECKSUM] Verifying Lattice Integrity ({d} blocks / {} each)...\n",
        .{ config.CHECKSUM_BLOCK_COUNT, std.fmt.fmtIntSizeBin(config.CHECKSUM_BLOCK_SIZE) },
    );
    var corrupted_blocks: u32 = 0;
    inline for (0..ghost_state.UnifiedLattice.BLOCK_COUNT) |block_idx| {
        if (!(lattice_provider.verifyBlock(block_idx) catch |err| {
            sys.print("\n[FATAL] Failed to verify lattice block {d}: {any}\n", .{ block_idx, err });
            sys.exit(1);
        })) {
            sys.print("[FATAL] Block {d} corruption detected. Resetting block (data lost)...\n", .{block_idx});
            lattice_provider.resetBlock(block_idx) catch |err| {
                sys.print("\n[FATAL] Failed to reset lattice block {d}: {any}\n", .{ block_idx, err });
                sys.exit(1);
            };
            corrupted_blocks += 1;
        }
    }
    if (corrupted_blocks > 0) {
        sys.printOut("[CHECKSUM] Block reset complete. {d} blocks zeroed (awaiting re-etch).\n");
    } else {
        sys.printOut("[CHECKSUM] All blocks verified. Checksums match.\n");
    }
    lattice_provider.flush() catch |err| {
        sys.print("[WARN] Initial lattice flush failed: {any}\n", .{err});
    };
    const meaning_matrix = &global_state_shard.?.meaning_matrix;

    var soul = try ghost_state.GhostSoul.init(allocator);
    defer soul.deinit();
    soul.meaning_matrix = meaning_matrix;

    const state_scratchpad = try scratchpad.ScratchpadLayer.init(allocator, .{
        .requested_bytes = launch.scratchpad_bytes,
        .file_prefix = global_state_shard.?.paths.scratch_file_prefix,
        .owner_id = global_state_shard.?.paths.metadata.id,
    }, meaning_matrix);
    global_scratchpad = state_scratchpad;
    panic_dump.registerScratchpad(&global_scratchpad.?);

    var sigil_control = sigil_runtime.ControlPlane.init(allocator);
    defer sigil_control.deinit();
    sigil_runtime.setActive(&sigil_control);
    defer sigil_runtime.setActive(null);
    sigil_control.setReasoningMode(launch.reasoning_mode);
    sys.print("[REASONING] Launch mode: {s}\n", .{sigil_runtime.reasoningModeName(launch.reasoning_mode)});

    try executeBootSigil(allocator, &sigil_control, meaning_matrix, &soul);
    sys.print("[REASONING] Active mode: {s}\n", .{sigil_runtime.reasoningModeName(sigil_control.snapshot().reasoning_mode)});
    panic_dump.noteRuntimeContext(
        global_state_shard.?.paths.metadata.kind,
        global_state_shard.?.paths.metadata.id,
        global_state_shard.?.paths.root_abs_path,
        sigil_control.snapshot().reasoning_mode,
    );
    try global_state_shard.?.paged_lattice.setCacheCap(selectedLatticeCacheCap(&sigil_control));

    global_lattice_provider = ghost_state.LatticeProvider.initPaged(&global_state_shard.?.paged_lattice);
    global_lattice_path = try allocator.dupe(u8, global_state_shard.?.paths.lattice_abs_path);
    global_meaning_data = meaning_matrix.data;
    global_tags_data = meaning_matrix.tags;
    global_host_lattice_words = null;

    if (!sigil_control.force_cpu_only and sigil_control.enable_vulkan) {
        sys.printOut("[VULKAN] Initializing Sovereign Compute...\n");
        if (vsa_vulkan.initRuntime(allocator)) |vk| {
            global_vk_engine = vk;
            try syncPagedLatticeToSlice(&global_state_shard.?.paged_lattice, vk.getLatticeData());
            global_host_lattice_words = vk.getLatticeData();
            vk.bindHostState(meaning_matrix.data, meaning_matrix.tags.?, global_host_lattice_words.?);
            sys.printOut("[COMPUTE] Ghost-Vulkan-Native active.\n");
        } else |_| sys.printOut("[COMPUTE] GPU not available. Running in CPU-only mode.\n");
    } else {
        sys.printOut("[COMPUTE] Sigil boot selected CPU-only mode.\n");
    }

    var state_queue = try core.sync.StateQueue.init(allocator, 1024);
    defer state_queue.deinit(allocator);
    var type_ahead = TypeAheadBuffer{};

    var shell_engine = engine_logic.SingularityEngine{
        .lattice = undefined,
        .meaning = meaning_matrix,
        .soul = &soul,
        .canvas = try ghost_state.MesoLattice.initText(allocator),
        .is_live = false,
        .vulkan = vsa_vulkan.getEngine(),
        .allocator = allocator,
    };
    shell_engine.setLatticeProvider(&global_lattice_provider.?);
    try shell_engine.setCacheCap(selectedLatticeCacheCap(&sigil_control));

    if (launch.daemon_mode) {
        const surveil = try allocator.create(core.surveillance.SovereignSurveillance);
        surveil.* = core.surveillance.SovereignSurveillance.init(allocator, &soul, meaning_matrix, undefined, &state_queue);

        // The bridge outlives this stack frame, so it must own heap-backed state.
        const bridge_thread = try std.Thread.spawn(.{ .allocator = allocator }, core.surveillance.SovereignSurveillance.startBridge, .{surveil});
        bridge_thread.detach();
    }

    if (launch.shell_enabled) {
        shell.startEmbedded(.{
            .allocator = allocator,
            .soul = &soul,
            .live_engine = &shell_engine,
            .state_paths = &global_state_shard.?.paths,
            .lattice_file = null,
            .meaning_file = global_state_shard.?.semantic_file,
            .tags_file = global_state_shard.?.tags_file,
            .scratchpad = &global_scratchpad.?,
            .lattice_words = global_host_lattice_words,
            .meaning_words = global_meaning_data.?,
            .tags_words = global_tags_data.?,
        }) catch |err| {
            sys.print("\n[FATAL] Embedded shell startup failed: {any}\n", .{err});
            sys.exit(1);
        };
    } else {
        sys.printOut("[MONOLITH] Embedded shell disabled via --no-shell.\n");
    }

    if (launch.daemon_mode) {
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
        var input_buf: [INPUT_LINE_CAPACITY]u8 = undefined;
        const raw_line = type_ahead.pop(&input_buf) orelse (sys.readStdin(&input_buf) catch break);
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
            .lattice = undefined,
            .meaning = meaning_matrix,
            .soul = &soul,
            .canvas = try ghost_state.MesoLattice.initText(loop_allocator),
            .is_live = sys.isTrainerActive(loop_allocator),
            .vulkan = vsa_vulkan.getEngine(),
            .allocator = loop_allocator,
        };
        engine.setLatticeProvider(&global_lattice_provider.?);
        try engine.setCacheCap(selectedLatticeCacheCap(&sigil_control));
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
                var stop_buf: [INPUT_LINE_CAPACITY]u8 = undefined;
                const int_line = sys.readStdin(&stop_buf) catch "";
                if (isStopCommand(int_line)) {
                    sys.printOut("\n[INTERRUPT] Generation halted by user signal.\n");
                    break;
                } else if (int_line.len > 0) {
                    if (!type_ahead.push(int_line)) {
                        sys.printOut("\n[WARN] Type-ahead buffer full; dropping queued input.\n");
                    }
                }
            }

            const decision = engine.resolveTopology() orelse break;
            if (decision.stop_reason != .none) break;
            const chosen = decision.output;
            var utf8_buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(@intCast(chosen), &utf8_buf) catch 1;
            sys.printOut(utf8_buf[0..len]);

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

    // 1. Initialize an empty 1 MiB memory-mapped lattice for testing
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

pub fn main() void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    main_wrapped(gpa.allocator()) catch |err| {
        panic_dump.write(std.io.getStdErr().writer(), err) catch {};
        std.process.exit(1);
    };
}
