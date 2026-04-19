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
const FILE_ATTRIBUTE_READONLY: u32 = 0x00000001;
const INVALID_FILE_ATTRIBUTES: u32 = 0xFFFFFFFF;
extern "kernel32" fn GetFileAttributesW(lpFileName: [*:0]const u16) callconv(WINAPI) u32;

var global_vk_engine: ?*vsa_vulkan.VulkanEngine = null;
var global_shutdown_requested = std.atomic.Value(bool).init(false);

var global_paged_lattice: ?ghost_state.PagedLatticeProvider = null;
var global_lattice_provider: ?ghost_state.LatticeProvider = null;
var global_mapped_meaning: ?sys.MappedFile = null;
var global_mapped_tags: ?sys.MappedFile = null;
var global_lattice_path: ?[]const u8 = null;
var global_host_lattice_words: ?[]u16 = null;
var global_meaning_data: ?[]u32 = null;
var global_tags_data: ?[]u64 = null;

const INPUT_LINE_CAPACITY = 1024;
const TYPEAHEAD_CAPACITY = 8;

const LaunchConfig = struct {
    daemon_mode: bool = false,
    shell_enabled: bool = true,
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
    var launch = LaunchConfig{};
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--daemon")) {
            launch.daemon_mode = true;
        } else if (std.mem.eql(u8, arg, "--no-shell")) {
            launch.shell_enabled = false;
        }
    }
    return launch;
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
            if (global_paged_lattice) |*paged| {
                if (syncSliceToPagedLattice(vk.getLatticeData(), paged)) |_| {
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
        if (global_mapped_meaning) |*m| {
            sys.printOut("[TEARDOWN] Flushing and Unmapping Meaning Matrix...\n");
            sys.flushMappedMemory(m) catch |err| {
                sys.print("[WARNING] Meaning Matrix flush failed: {any}\n", .{err});
            };
            m.unmap();
        }
        if (global_mapped_tags) |*m| {
            sys.printOut("[TEARDOWN] Flushing and Unmapping Tags...\n");
            sys.flushMappedMemory(m) catch |err| {
                sys.print("[WARNING] Tags flush failed: {any}\n", .{err});
            };
            m.unmap();
        }
        sys.printOut("[TEARDOWN] Persisted state flushed.\n");
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
    var vm_ctx = sigil_vm.Context{
        .allocator = allocator,
        .control = control,
        .meaning = meaning,
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

    var paged_lattice = ghost_state.PagedLatticeProvider.init(allocator, lattice_abs_path, config.IDEAL_LATTICE_SIZE) catch |err| {
        sys.print("\n[FATAL] Failed to initialize paged Unified Lattice: {any}\n", .{err});
        sys.print("[HINT] Ensure you have run .\\tools\\seed_lattice.ps1 to create the 1GB state files.\n", .{});
        sys.exit(1);
    };
    errdefer paged_lattice.deinit();
    var lattice_provider = ghost_state.LatticeProvider.initPaged(&paged_lattice);

    sys.printOut("[CHECKSUM] Verifying Lattice Integrity (16 Blocks / 64MB each)...\n");
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

    try executeBootSigil(allocator, &sigil_control, &meaning_matrix, &soul);
    try paged_lattice.setCacheCap(selectedLatticeCacheCap(&sigil_control));

    global_paged_lattice = paged_lattice;
    global_lattice_provider = ghost_state.LatticeProvider.initPaged(&global_paged_lattice.?);
    global_mapped_meaning = mapped_meaning;
    global_mapped_tags = mapped_tags;
    global_lattice_path = try allocator.dupe(u8, lattice_abs_path);
    global_meaning_data = meaning_matrix.data;
    global_tags_data = meaning_matrix.tags;
    global_host_lattice_words = null;

    if (!sigil_control.force_cpu_only and sigil_control.enable_vulkan) {
        sys.printOut("[VULKAN] Initializing Sovereign Compute...\n");
        if (vsa_vulkan.initRuntime(allocator, init.io)) |vk| {
            global_vk_engine = vk;
            try syncPagedLatticeToSlice(&global_paged_lattice.?, vk.getLatticeData());
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
        .meaning = &meaning_matrix,
        .soul = &soul,
        .canvas = try ghost_state.MesoLattice.initText(allocator),
        .is_live = false,
        .vulkan = vsa_vulkan.getEngine(),
        .allocator = allocator,
    };
    shell_engine.setLatticeProvider(&global_lattice_provider.?);
    try shell_engine.setCacheCap(selectedLatticeCacheCap(&sigil_control));

    const args = try sys.getArgs(allocator);
    const launch = parseLaunchConfig(args);

    if (launch.daemon_mode) {
        const surveil = try allocator.create(core.surveillance.SovereignSurveillance);
        surveil.* = core.surveillance.SovereignSurveillance.init(allocator, &soul, &meaning_matrix, undefined, &state_queue);

        // The bridge outlives this stack frame, so it must own heap-backed state.
        const bridge_thread = try std.Thread.spawn(.{ .allocator = allocator }, core.surveillance.SovereignSurveillance.startBridge, .{surveil});
        bridge_thread.detach();
    }

    if (launch.shell_enabled) {
        shell.startEmbedded(.{
            .allocator = allocator,
            .io = init.io,
            .soul = &soul,
            .live_engine = &shell_engine,
            .lattice_file = null,
            .meaning_file = mapped_meaning,
            .tags_file = mapped_tags,
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
            .meaning = &meaning_matrix,
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

            const chosen = engine.resolveTopology() orelse break;
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
