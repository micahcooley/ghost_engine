

const std = @import("std");
const builtin = @import("builtin");
const sys = @import("sys.zig");
const ghost_state = @import("ghost_state.zig");
const vsa = @import("vsa_core.zig");
const vsa_vulkan = @import("vsa_vulkan.zig");
const compute_api = @import("compute_api.zig");

const VERSION = "V28";

var active_compute: ?*const compute_api.ComputeApi = null;
var global_lattice: ?*ghost_state.UnifiedLattice = null;
var global_mapped: ?sys.MappedFile = null;
var using_cpu_fallback: bool = false;
var loaded_plugins = std.ArrayListUnmanaged(sys.NativeLibrary).empty;

// Signal handler (Platform agnostic through sys layer or direct if needed)
fn ctrlHandler(ctrl_type: u32) void {
    if (ctrl_type == 0) { // SIGINT/Interrupt
        sys.printOut("\n[SIGNAL] Interrupt detected. Releasing Silicon...\n");
        if (active_compute) |_| vsa_vulkan.GHOST_COMPUTE_PLUGIN.deinit();
        if (global_mapped) |*m| m.flush();
        for (loaded_plugins.items) |*lib| {
            if (lib.lookup(*const fn () void, "cleanup")) |cleanup| cleanup();
            lib.close();
        }
        sys.exit(0);
    }
}

// ── Stream State: Independent Temporal Rotor per corpus file ──
const StreamState = struct {
    lexical_rotor: u64,
    semantic_rotor: u64,
    claimed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    concept: vsa.HyperVector,
    syntax: vsa.HyperVector,
    phrase: vsa.HyperVector,
    sentence_pool: vsa.HyperVector,
    spell_vector: vsa.HyperVector,
    file_data: []const u8,
    cursor: usize,
    name: []const u8,
    done: bool,
    last_rune_byte: u8 = 0,

    pub fn init(data: []const u8, name: []const u8) StreamState {
        return .{
            .lexical_rotor = ghost_state.FNV_OFFSET_BASIS,
            .semantic_rotor = ghost_state.FNV_OFFSET_BASIS,
            .concept = @splat(0),
            .syntax = @splat(0),
            .phrase = @splat(0),
            .sentence_pool = @splat(0),
            .spell_vector = @splat(0),
            .file_data = data,
            .cursor = 0,
            .name = name,
            .done = false,
            .last_rune_byte = 0,
        };
    }

    pub fn advance(self: *StreamState) ?u8 {
        if (self.cursor >= self.file_data.len) {
            self.done = true;
            return null;
        }
        const byte = self.file_data[self.cursor];
        self.cursor += 1;

        // Update rotors (fast path - no boredom tracking)
        self.lexical_rotor = (self.lexical_rotor ^ @as(u64, byte)) *% ghost_state.FNV_PRIME;
        self.semantic_rotor = (self.semantic_rotor ^ @as(u64, byte)) *% ghost_state.FNV_PRIME;
        
        // Universal Boundary Check: ASCII whitespace/punctuation + anything > 127 (Unicode start)
        const is_boundary = (byte <= ' ' or byte == '.' or byte == ';' or byte == '=' or byte > 127);
        if (is_boundary) self.semantic_rotor = ghost_state.FNV_OFFSET_BASIS;

        return byte;
    }

    /// Pulls the next full Rune (UTF-8 multi-byte sequence) from the stream.
    pub fn nextRune(self: *StreamState) ?u32 {
        if (self.cursor >= self.file_data.len) {
            self.done = true;
            return null;
        }

        const first_byte = self.file_data[self.cursor];
        const len = std.unicode.utf8ByteSequenceLength(first_byte) catch 1;
        
        if (self.cursor + len > self.file_data.len) {
            self.done = true;
            return null;
        }

        const rune_bytes = self.file_data[self.cursor .. self.cursor + len];
        const rune = if (len == 1) @as(u32, first_byte) else std.unicode.utf8Decode(rune_bytes) catch @as(u32, first_byte);
        
        self.cursor += len;
        
        // Update rotors with the full Rune hash
        const rune_hash = ghost_state.wyhash(ghost_state.FNV_OFFSET_BASIS, rune);
        self.lexical_rotor = (self.lexical_rotor ^ rune_hash) *% ghost_state.FNV_PRIME;
        
        // Semantic rotor reset: uses a broader set of boundaries including Unicode whitespace
        const is_boundary = (rune <= 32 or rune == '.' or rune == ';' or rune == '=' or rune == 0x3000); 
        if (is_boundary) {
            self.semantic_rotor = ghost_state.FNV_OFFSET_BASIS;
        } else {
            self.semantic_rotor = (self.semantic_rotor ^ rune_hash) *% ghost_state.FNV_PRIME;
        }

        self.last_rune_byte = @as(u8, @truncate(rune));
        return rune;
    }

    pub fn progress(self: *const StreamState) f64 {
        if (self.file_data.len == 0) return 100.0;
        return @as(f64, @floatFromInt(self.cursor)) / @as(f64, @floatFromInt(self.file_data.len)) * 100.0;
    }
};

// ── Multi-Stream Greedy Pool Batcher (V28: Unified Stream Pool) ──
const MAX_STREAMS = 64;
const WAVEFRONT_ALIGN = 64;

/// V28.1: Sovereign Worker Pool eliminates per-batch thread spawning.
const WorkerPool = struct {
    threads: []std.Thread,
    work_queue: [MAX_STREAMS]?*StreamState,
    active_count: std.atomic.Value(usize),
    pending_count: std.atomic.Value(usize),
    stop: std.atomic.Value(bool),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, num_threads: usize) !*WorkerPool {
        const self = try allocator.create(WorkerPool);
        self.* = .{
            .threads = try allocator.alloc(std.Thread, num_threads),
            .work_queue = [_]?*StreamState{null} ** MAX_STREAMS,
            .active_count = std.atomic.Value(usize).init(0),
            .pending_count = std.atomic.Value(usize).init(0),
            .stop = std.atomic.Value(bool).init(false),
            .allocator = allocator,
        };

        for (0..num_threads) |i| {
            self.threads[i] = try std.Thread.spawn(.{ .allocator = allocator }, workerMain, .{self});
        }
        return self;
    }

    fn workerMain(self: *WorkerPool) void {
        while (!self.stop.load(.acquire)) {
            // Spin-wait for work (Parallel Preprocessing Wavefront)
            while (self.pending_count.load(.acquire) == 0) {
                if (self.stop.load(.acquire)) return;
                std.atomic.spinLoopHint();
            }

            const total = self.active_count.load(.acquire);
            for (0..total) |i| {
                const stream = self.work_queue[i] orelse continue;
                // Atomic claim to ensure only one worker processes this stream per wavefront
                if (stream.claimed.swap(true, .acquire) == false) {
                    _ = stream.nextRune();
                    _ = self.pending_count.fetchSub(1, .release);
                }
            }
        }
    }

    pub fn deinit(self: *WorkerPool) void {
        self.stop.store(true, .release);
        for (self.threads) |t| t.join();
        self.allocator.free(self.threads);
        self.allocator.destroy(self);
    }
};

const GreedyBatcher = struct {
    streams: []StreamState,
    pool: ?*WorkerPool = null,
    active_count: usize,
    batch_bytes: [20480]u8,
    batch_index: [20480]u32,
    batch_len: usize,

    pub fn init(streams: []StreamState, pool: ?*WorkerPool) GreedyBatcher {
        return .{
            .streams = streams,
            .pool = pool,
            .active_count = streams.len,
            .batch_bytes = [_]u8{0} ** 20480,
            .batch_index = [_]u32{0} ** 20480,
            .batch_len = 0,
        };
    }

    pub fn fillBatch(self: *GreedyBatcher, max_batch: u32) usize {
        const cap: usize = @min(max_batch, self.batch_bytes.len);
        var pos: usize = 0;
        
        // Greedy fill with Parallel Preprocessing
        // V28.1: Instead of serial pull, we pull in wavefronts to keep GPU saturated.
        while (pos < cap and self.active_count > 0) {
            if (self.pool) |p| {
                // Prepare work for the pool: All active streams pull their NEXT rune.
                var streams_this_pass: usize = 0;
                for (self.streams, 0..) |*s, si| {
                    if (s.done) continue;
                    p.work_queue[streams_this_pass] = s;
                    // Pre-store index for demux
                    self.batch_index[pos + streams_this_pass] = @as(u32, @intCast(si));
                    streams_this_pass += 1;
                }
                
                if (streams_this_pass == 0) break;
                
                p.active_count.store(streams_this_pass, .release);
                p.pending_count.store(streams_this_pass, .release);
                // Wait for pool to finish processing this wavefront
                while (p.pending_count.load(.acquire) > 0) {
                    std.atomic.spinLoopHint();
                }

                // Now collect the results into the batch
                for (0..streams_this_pass) |i| {
                    const s = p.work_queue[i].?;
                    // Stream.cursor was already advanced, but we need the rune that WAS pulled.
                    // To avoid another loop, we change nextRune to store the result in the stream state.
                    self.batch_bytes[pos + i] = s.last_rune_byte;
                }
                pos += streams_this_pass;
            } else {
                // Serial Fallback
                var any_active = false;
                for (self.streams, 0..) |*s, si| {
                    if (pos >= cap) break;
                    if (s.done) continue;
                    const rune = s.nextRune() orelse continue;
                    self.batch_bytes[pos] = @as(u8, @truncate(rune));
                    self.batch_index[pos] = @as(u32, @intCast(si));
                    pos += 1;
                    any_active = true;
                }
                if (!any_active) break;
            }
        }

        if (pos > 0) {
            pos = (pos / WAVEFRONT_ALIGN) * WAVEFRONT_ALIGN;
            if (pos == 0) pos = @min(WAVEFRONT_ALIGN, self.batch_len);
        }
        self.batch_len = pos;
        self.active_count = 0;
        for (self.streams) |*s| {
            if (!s.done) self.active_count += 1;
        }
        return self.batch_len;
    }

    pub fn allDone(self: *const GreedyBatcher) bool {
        for (self.streams) |s| {
            if (!s.done) return false;
        }
        return true;
    }

    pub fn totalSize(self: *const GreedyBatcher) usize {
        var total: usize = 0;
        for (self.streams) |s| total += s.file_data.len;
        return total;
    }

    /// Returns a snapshot of per-stream rotor pairs for the current batch.
    /// Format: [stream0_lex, stream0_sem, stream1_lex, stream1_sem, ...]
    /// This is uploaded to the GPU once per dispatch so each wavefront can
    /// resolve its context via batch_index[] without re-reading the CPU state.
    pub fn buildRotorSnapshot(self: *const GreedyBatcher, out: []u64) void {
        for (self.streams, 0..) |s, i| {
            if (i * 2 + 1 >= out.len) break;
            out[i * 2]     = s.lexical_rotor;
            out[i * 2 + 1] = s.semantic_rotor;
        }
    }
};

pub fn main() void {
    main_wrapped() catch |err| {
        sys.print("\n[FATAL ERROR] {any}\n", .{err});
        if (active_compute) |_| vsa_vulkan.GHOST_COMPUTE_PLUGIN.deinit();
        sys.exit(1);
    };
}

fn main_wrapped() !void {
    const allocator = std.heap.page_allocator;

    // ── 1. Parse Args ──
    const args = try sys.getArgs(allocator);
    if (args.len < 2) {
        sys.printOut("Usage: ohl_trainer <corpus_path> [--max|--high|--standard|--background]\n");
        sys.exit(1);
    }
    const corpus_path = args[1];

    var tier: vsa_vulkan.OperationalTier = .standard;
    var plugins_on: bool = false;
    for (args[2..]) |arg| {
        if (std.mem.eql(u8, arg, "--god")) tier = .god
        else if (std.mem.eql(u8, arg, "--hyper")) tier = .hyper
        else if (std.mem.eql(u8, arg, "--ultra")) tier = .ultra
        else if (std.mem.eql(u8, arg, "--extreme")) tier = .extreme
        else if (std.mem.eql(u8, arg, "--max")) tier = .max
        else if (std.mem.eql(u8, arg, "--high")) tier = .high
        else if (std.mem.eql(u8, arg, "--standard")) tier = .standard
        else if (std.mem.eql(u8, arg, "--background")) tier = .background
        else if (std.mem.eql(u8, arg, "--plugins")) plugins_on = true;
    }

    const cpu_cores = std.Thread.getCpuCount() catch 4;

    if (plugins_on) {
        sys.printOut("[PLUGINS] Scanning for native optimizations...\n");
        const plugin_files = try sys.findNativePlugins(allocator);
        for (plugin_files) |fpath| {
            var lib = sys.NativeLibrary.open(fpath) catch {
                sys.print("[WARN] Failed to load plugin: {s}\n", .{fpath});
                continue;
            };
            if (lib.lookup(*const fn () void, "init")) |init_fn| {
                init_fn();
                try loaded_plugins.append(allocator, lib);
                sys.print("[LOADED] {s}\n", .{fpath});
            } else {
                lib.close();
            }
        }
    }

    const batch_size = @intFromEnum(tier);
    // Constrain batch to 20480 (our buffer cap) and wavefront-align it
    const aligned_batch_size: u32 = @min(batch_size, 20480);
    const num_streams: usize = switch (tier) {
        .god, .hyper, .ultra, .extreme => MAX_STREAMS,
        .max      => @min(MAX_STREAMS, cpu_cores * 2),
        .high     => cpu_cores,
        .standard => @min(cpu_cores, 4),
        .background => 1,
    };
    const sleep_ms: u32 = switch (tier) {
        .god, .hyper, .ultra, .extreme, .max, .high, .standard => 0,
        .background => 15,
    };

    sys.print("\nGhost Trainer {s}: Sovereign Trinity Engine (V28 Greedy Saturation)\n", .{VERSION});
    sys.printOut("========================================================\n\n");
    sys.print("[TIER] {s} | batch={d} (wavefront-aligned) | streams={d} | cpu_cores={d}\n\n", .{ @tagName(tier), aligned_batch_size, num_streams, cpu_cores });

    // ── 2. Map the 1GB Unified Lattice ──
    sys.printOut("[CORTEX] Mapping 1GB Unified Lattice...\n");
    var mapped = try sys.createMappedFile(allocator, "state/unified_lattice.bin", ghost_state.UNIFIED_SIZE_BYTES);
    global_mapped = mapped;
    var lattice = @as(*ghost_state.UnifiedLattice, @ptrCast(@alignCast(mapped.data.ptr)));

    // ── 3. Initialize Compute Provider ──
    sys.printOut("[COMPUTE] Initializing Sovereign Compute Provider...\n");
    const compute_or_err = vsa_vulkan.GHOST_COMPUTE_PLUGIN.init(allocator) catch null;
    var meaning_matrix: vsa.MeaningMatrix = undefined;

    if (compute_or_err) |compute| {
        active_compute = compute;
        compute.setTier(@intFromEnum(tier));
        const matrix_data = compute.getMatrixData();
        const tags_data = compute.getTagsData();
        meaning_matrix = vsa.MeaningMatrix{
            .data = matrix_data.ptr[0..matrix_data.len],
            .tags = tags_data.ptr[0..tags_data.len]
        };
        sys.print("[COMPUTE] {s} initialized on device.\n", .{compute.name});

        sys.printOut("[CORTEX] Transferring lattice to Silicon...\n");
        const compute_lattice = compute.getLatticeData();
        const mapped_u16 = @as([*]const u16, @ptrCast(@alignCast(mapped.data.ptr)));
        const total_u16 = ghost_state.UNIFIED_SIZE_BYTES / 2;
        @memcpy(compute_lattice[0..total_u16], mapped_u16[0..total_u16]);
    } else {
        using_cpu_fallback = true;
        sys.printOut("[COMPUTE] *** GPU init FAILED. Falling back to CPU-only VSA. ***\n");
        const cpu_buf = sys.allocSectorAligned(1024 * 1024 * 2) orelse return error.OutOfMemory;
        meaning_matrix = vsa.MeaningMatrix{
            .data = @as([*]u16, @ptrCast(@alignCast(cpu_buf.ptr)))[0..(1024 * 1024)],
            .tags = null,
        };
    }

    // ── 4. Load Existing Meaning Matrix ──
    if (sys.openForRead(allocator, "state/semantic_monolith.bin")) |h| {
        _ = try sys.readAll(h, @as([]u8, @ptrCast(meaning_matrix.data)));
        sys.closeFile(h);
    } else |_| {}

    // ── 5. Load Corpus Files ──
    const corpus_handle = try sys.openForRead(allocator, corpus_path);
    const corpus_size = try sys.getFileSize(corpus_handle);
    var corpus_buf = try allocator.alloc(u8, corpus_size);
    const bytes_read = try sys.readAll(corpus_handle, corpus_buf);
    sys.closeFile(corpus_handle);
    const primary_corpus = corpus_buf[0..bytes_read];

    sys.print("[CORPUS] Primary: {d} bytes ({d:.1} MB)\n", .{ primary_corpus.len, @as(f64, @floatFromInt(primary_corpus.len)) / 1048576.0 });

    var stream_data: [MAX_STREAMS][]const u8 = [_][]const u8{&[_]u8{}} ** MAX_STREAMS;
    var stream_names: [MAX_STREAMS][]const u8 = [_][]const u8{"primary"} ** MAX_STREAMS;
    stream_data[0] = primary_corpus;
    stream_names[0] = corpus_path;

    if (num_streams > 1) {
        const extra_files: [7][]const u8 = .{ 
            "platforms/windows/x86_64/corpus/shakespeare.txt", 
            "platforms/windows/x86_64/corpus/The GCIDE.txt", 
            "platforms/windows/x86_64/corpus/Moby dick.txt",
            "platforms/windows/x86_64/corpus/wikitext_train.txt", 
            "platforms/windows/x86_64/corpus/a tale of two cities.txt",
            "platforms/windows/x86_64/corpus/The Adventures of Huckleberry Finn.txt", 
            "platforms/windows/x86_64/corpus/wikitext_test.txt"
        };
        var loaded: usize = 1;
        for (extra_files) |fpath| {
            if (loaded >= num_streams) break;
            if (sys.openForRead(allocator, fpath)) |h| {
                const sz = sys.getFileSize(h) catch 0;
                if (sz > 0) {
                    var buf = try allocator.alloc(u8, sz);
                    const n = sys.readAll(h, buf) catch 0;
                    sys.closeFile(h);
                    if (n > 0) {
                        stream_data[loaded] = buf[0..n];
                        stream_names[loaded] = fpath;
                        loaded += 1;
                        sys.print("[CORPUS] Stream {d}: {s} ({d:.1} MB)\n", .{ loaded, fpath, @as(f64, @floatFromInt(n)) / 1048576.0 });
                    }
                }
            } else |_| {}
        }
        while (loaded < num_streams) {
            stream_data[loaded] = primary_corpus;
            stream_names[loaded] = "primary (mirror)";
            loaded += 1;
        }
    }

    // ── 6. Hard-Lock Universal Sigils ──
    sys.printOut("[SIGIL] Locking Universal identities (Latin + CJK Base)...\n");
    for (0..128) |c| meaning_matrix.hardLockSigil(@as(u64, @truncate(vsa.generate(@intCast(c))[0])), @intCast(c));
    const extra_locks: [4]u32 = .{ 0x4E00, 0x4E01, 0x4E02, 0x4E03 };
    for (extra_locks) |r| meaning_matrix.hardLockUniversalSigil(ghost_state.wyhash(0, r), r);
    sys.printOut("[SIGIL] Done.\n");

    // ── 7. Initialize Greedy Stream Pool ──
    const pool = try WorkerPool.init(allocator, cpu_cores);
    defer pool.deinit();

    var streams: [MAX_STREAMS]StreamState = undefined;
    for (0..num_streams) |si| streams[si] = StreamState.init(stream_data[si], stream_names[si]);
    var batcher = GreedyBatcher.init(streams[0..num_streams], pool);
    // Pre-allocated rotor snapshot buffer: 2 u64s per stream (lex + sem)
    var rotor_snapshot: [MAX_STREAMS * 2]u64 = [_]u64{0} ** (MAX_STREAMS * 2);

    // ── 8. Greedy Training Loop ──
    sys.printOut("\n[TRAIN] Starting V28 Greedy Saturation training pass...\n");
    sys.print("[TRAIN] Buffer: 4096 slots | Wavefront align: {d} | Active streams: {d}\n",
        .{ WAVEFRONT_ALIGN, num_streams });
    const start_time = sys.getMilliTick();
    var last_report_time = start_time;
    var last_report_bytes: usize = 0;
    var solstice_position: usize = 0;
    var total_bytes_processed: usize = 0;
    var dispatch_count: usize = 0;

    while (!batcher.allDone()) {
        // ── V28: Build per-stream rotor snapshot BEFORE greedy fill ──
        // The snapshot captures each stream's current rotating context.
        // After fillBatch() advances cursors, rotors will be in the NEXT state.
        // We send the STARTING state to the GPU so it can reconstruct context.
        batcher.buildRotorSnapshot(rotor_snapshot[0 .. num_streams * 2]);

        // ── V28 Greedy Fill: fills from any active stream, wavefront-aligned ──
        const filled = batcher.fillBatch(aligned_batch_size);
        if (filled == 0) break;

        if (active_compute) |compute| {
            // etch() signature V28: (total_batch, num_streams, rotors, chars, rotor_indices)
            try compute.etch(
                @intCast(filled),
                @intCast(num_streams),
                rotor_snapshot[0 .. num_streams * 2],
                batcher.batch_bytes[0..filled],
                batcher.batch_index[0..filled],
            );
        } else {
            sys.printOut("[WARN] CPU Fallback active — no GPU etch this batch.\n");
        }

        total_bytes_processed += filled;
        dispatch_count += 1;
        if (sleep_ms > 0) sys.sleep(sleep_ms);

        const now = sys.getMilliTick();
        if (now - last_report_time >= 2000) {
            const elapsed_ms = now - start_time;
            const total_throughput = if (elapsed_ms > 0) (total_bytes_processed * 1000 / elapsed_ms) else 0;
            const chunk_bytes = total_bytes_processed - last_report_bytes;
            const chunk_elapsed = now - last_report_time;
            const instant_throughput = if (chunk_elapsed > 0) (chunk_bytes * 1000 / chunk_elapsed) else 0;
            const occupancy = lattice.sampleOccupancy(0x1337);
            const total_size = batcher.totalSize();
            const overall_pct = if (total_size > 0) @as(f64, @floatFromInt(total_bytes_processed)) / @as(f64, @floatFromInt(total_size)) * 100.0 else 0;

            // V28: Report active stream count for saturation visibility
            sys.print("[TRAIN] {d:.1}% | {d} KB/s inst | {d} KB/s avg | {d:.1}% occ | active={d}/{d} | buf={d}/{d}\n",
                .{ overall_pct, instant_throughput / 1024, total_throughput / 1024,
                   @as(f64, @floatFromInt(occupancy)) / 100.0,
                   batcher.active_count, num_streams,
                   filled, aligned_batch_size });

            for (batcher.streams) |s| {
                const status: []const u8 = if (s.done) "[DONE]" else "[ OK ]";
                sys.print("  {s} {s}: {d:.1}% ({d:.1} MB / {d:.1} MB)\n", .{
                    status, s.name, s.progress(),
                    @as(f64, @floatFromInt(s.cursor)) / 1048576.0,
                    @as(f64, @floatFromInt(s.file_data.len)) / 1048576.0
                });
            }

            last_report_time = now;
            last_report_bytes = total_bytes_processed;
        }

        if (dispatch_count % 128 == 0) _ = lattice.chunkedSolsticeDecay(&solstice_position);
    }

    // ── 9. Final Report ──
    const total_elapsed_ms = sys.getMilliTick() - start_time;
    const final_throughput = if (total_elapsed_ms > 0) (total_bytes_processed * 1000 / total_elapsed_ms) else 0;
    sys.print("\n  TRAINING COMPLETE | {s} | Bytes: {d} | Time: {d}ms | {d} KB/s\n",
        .{ @tagName(tier), total_bytes_processed, total_elapsed_ms, final_throughput / 1024 });

    // ── 10. Save State ──
    if (active_compute) |compute| {
        const compute_lattice = compute.getLatticeData();
        @memcpy(@as([*]u16, @ptrCast(@alignCast(mapped.data.ptr))), compute_lattice);
    }
    mapped.flush();
    mapped.unmap();

    if (sys.openForWrite(allocator, "state/semantic_monolith.bin")) |h| {
        _ = try sys.writeAll(h, std.mem.sliceAsBytes(meaning_matrix.data));
        sys.closeFile(h);
    } else |_| {}

    if (active_compute) |_| vsa_vulkan.GHOST_COMPUTE_PLUGIN.deinit();
}
