const std = @import("std");
const core = @import("ghost_core");
const sys = core.sys;
const vsa = core.vsa;
const ghost_state = core.ghost_state;
const vsa_vulkan = core.vsa_vulkan;
const engine_logic = core.engine;
const compute_api = core.compute_api;

const builtin = @import("builtin");
const WINAPI = if (builtin.os.tag == .windows) std.builtin.CallingConvention.winapi else .C;
extern "kernel32" fn SetConsoleCtrlHandler(handler: ?*const fn (u32) callconv(WINAPI) i32, add: i32) callconv(WINAPI) i32;

// ── Shared State ──
var stop_flag = std.atomic.Value(bool).init(false);
var global_vk_engine: ?*vsa_vulkan.VulkanEngine = null;
var global_compute: ?*const compute_api.ComputeApi = null;
var global_mapped_lattice: ?sys.MappedFile = null;

// ── Thread-safe input queue ──
const TrainingQueue = struct {
    mutex: std.atomic.Mutex = .unlocked,
    data: std.ArrayListUnmanaged(u8) = .empty,
    allocator: std.mem.Allocator,

    fn acquire(m: *std.atomic.Mutex) void {
        while (!m.tryLock()) {
            std.atomic.spinLoopHint();
        }
    }

    pub fn push(self: *TrainingQueue, bytes: []const u8) void {
        acquire(&self.mutex);
        defer self.mutex.unlock();
        self.data.appendSlice(self.allocator, bytes) catch return;
    }

    pub fn drain(self: *TrainingQueue, buf: []u8) usize {
        acquire(&self.mutex);
        defer self.mutex.unlock();
        const n = @min(buf.len, self.data.items.len);
        if (n == 0) return 0;
        @memcpy(buf[0..n], self.data.items[0..n]);
        const remaining = self.data.items.len - n;
        if (remaining > 0) {
            std.mem.copyForwards(u8, self.data.items[0..remaining], self.data.items[n .. n + remaining]);
        }
        self.data.shrinkRetainingCapacity(remaining);
        return n;
    }

    pub fn len(self: *TrainingQueue) usize {
        acquire(&self.mutex);
        defer self.mutex.unlock();
        return self.data.items.len;
    }
};

var training_queue: TrainingQueue = undefined;

// ── Background trainer state ──
const ShellStream = struct {
    lexical_rotor: u64,
    semantic_rotor: u64,
    file_data: []const u8,
    cursor: usize,
    done: bool,

    pub fn init() ShellStream {
        return .{
            .lexical_rotor = ghost_state.FNV_OFFSET_BASIS,
            .semantic_rotor = ghost_state.FNV_OFFSET_BASIS,
            .file_data = &.{},
            .cursor = 0,
            .done = false,
        };
    }

    pub fn feed(self: *ShellStream, data: []const u8) void {
        self.file_data = data;
        self.cursor = 0;
        self.done = false;
    }

    pub fn nextRune(self: *ShellStream) ?u32 {
        if (self.cursor >= self.file_data.len) {
            self.done = true;
            return null;
        }
        const b = self.file_data[self.cursor];
        self.cursor += 1;
        
        // Use full rune hash for rotor consistency with trainer
        const rune: u32 = b;
        const rune_hash = ghost_state.wyhash(ghost_state.FNV_OFFSET_BASIS, rune);
        self.lexical_rotor = (self.lexical_rotor ^ rune_hash) *% ghost_state.FNV_PRIME;
        self.semantic_rotor = (self.semantic_rotor ^ rune_hash) *% ghost_state.FNV_PRIME;
        return rune;
    }
};

const WAVEFRONT_ALIGN: usize = 64;

fn backgroundTrainer(compute: *const compute_api.ComputeApi) void {

    var stream = ShellStream.init();
    var batch_runes: [4096]u32 = undefined;
    var batch_index: [4096]u32 = undefined;
    var batch_rotors: [4096 * 2]u64 = undefined;
    var drain_buf: [8192]u8 = undefined;
    var pending: std.ArrayListUnmanaged(u8) = .empty;

    while (!stop_flag.load(.acquire)) {
        const n = training_queue.drain(&drain_buf);
        if (n > 0) {
            pending.appendSlice(std.heap.page_allocator, drain_buf[0..n]) catch continue;
        }

        if (pending.items.len == 0) {
            sys.sleep(15);
            continue;
        }

        // Feed pending bytes into stream
        stream.feed(pending.items);
        pending.clearRetainingCapacity();

        // Fill batch
        var pos: usize = 0;
        while (pos < batch_runes.len) : (pos += 1) {
            const r = stream.nextRune() orelse break;
            batch_runes[pos] = r;
            batch_index[pos] = 0; // single stream
            batch_rotors[pos * 2] = stream.lexical_rotor;
            batch_rotors[pos * 2 + 1] = stream.semantic_rotor;
        }

        // Wavefront-align
        if (pos > 0) {
            const aligned = (pos / WAVEFRONT_ALIGN) * WAVEFRONT_ALIGN;
            pos = if (aligned > 0) aligned else @min(WAVEFRONT_ALIGN, pos);
        }

        if (pos == 0) continue;



        // Dispatch etch
        compute.etch(
            @intCast(pos),
            1,
            batch_rotors[0 .. pos * 2],
            batch_runes[0..pos],
            batch_index[0..pos],
        ) catch {};
    }
}

// ── Ctrl+C Handler ──
fn ctrlHandler(ctrl_type: u32) callconv(WINAPI) i32 {
    if (ctrl_type == 0) {
        sys.printOut("\n[SIGNAL] Releasing Silicon...\n");
        stop_flag.store(true, .release);
        return 1;
    }
    return 1;
}

pub fn main() !void {
    if (builtin.os.tag == .windows) {
        _ = SetConsoleCtrlHandler(ctrlHandler, 1);
    }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    sys.printOut("\nGhost V28 Shell: Sovereign Intelligence\n");
    sys.printOut("Type to interact. Empty line to exit.\n\n");

    // ── 1. Map State ──
    sys.printOut("[MONOLITH] Mapping Cortex...\n");
    const mapped_lattice = try sys.createMappedFile(allocator, "state/unified_lattice.bin", ghost_state.UNIFIED_SIZE_BYTES);
    global_mapped_lattice = mapped_lattice;
    const lattice: *ghost_state.UnifiedLattice = @as(*ghost_state.UnifiedLattice, @ptrCast(@alignCast(mapped_lattice.data.ptr)));

    sys.printOut("[MEANING] Mapping Hippocampus...\n");
    const mapped_meaning = try sys.createMappedFile(allocator, "state/semantic_monolith.bin", 1024 * 1024 * 1024);
    const mapped_tags = try sys.createMappedFile(allocator, "state/semantic_tags.bin", 1048576 * 8);

    // ── 2. Init Vulkan ──
    sys.printOut("[VULKAN] Initializing Sovereign Compute...\n");
    if (vsa_vulkan.GHOST_COMPUTE_PLUGIN.init(allocator)) |compute| {
        global_compute = compute;
        sys.printOut("[COMPUTE] ");
        sys.printOut(compute.name);
        sys.printOut(" active.\n");

        // Upload CPU-trained data to GPU
        const gpu_matrix = compute.getMatrixData();
        const src_ptr: [*]const u16 = @ptrCast(@alignCast(mapped_meaning.data.ptr));
        const copy_len = @min(gpu_matrix.len, mapped_meaning.data.len / 2);
        @memcpy(gpu_matrix[0..copy_len], src_ptr[0..copy_len]);

        // Upload lattice
        const gpu_lattice = compute.getLatticeData();
        const lattice_ptr: [*]const u16 = @ptrCast(@alignCast(mapped_lattice.data.ptr));
        const lattice_copy_len = @min(gpu_lattice.len, mapped_lattice.data.len / 2);
        @memcpy(gpu_lattice[0..lattice_copy_len], lattice_ptr[0..lattice_copy_len]);
    } else |_| {
        sys.printOut("[VULKAN] Failed. Running CPU-only.\n");
    }

    // ── 3. Init Meaning Matrix ──
    var meaning_matrix = vsa.MeaningMatrix{
        .data = @as([*]u16, @ptrCast(@alignCast(mapped_meaning.data.ptr)))[0..(1024 * 1024 * 512)],
        .tags = @as([*]u64, @ptrCast(@alignCast(mapped_tags.data.ptr)))[0..1048576],
    };

    // ── 4. Spawn background trainer ──
    var soul = try allocator.create(ghost_state.GhostSoul);
    soul.* = ghost_state.GhostSoul.init(allocator);
    defer soul.deinit();
    defer allocator.destroy(soul);
    
    soul.meaning_matrix = &meaning_matrix;

    training_queue = .{ .allocator = allocator };

    var trainer_thread: ?std.Thread = null;
    if (global_compute) |compute| {
        trainer_thread = std.Thread.spawn(.{ .allocator = allocator }, backgroundTrainer, .{compute}) catch null;
        if (trainer_thread != null) {
            sys.printOut("[TRAINER] Background learning thread active.\n\n");
        }
    }

    sys.printOut("[SILICON] Pre-calculating BMP VSA Space (65,536 identities)...\n");
    const bmp_vectors = try engine_logic.SingularityEngine.precomputeBMP(allocator);

    // ── 5. REPL Loop ──
    while (!stop_flag.load(.acquire)) {
        sys.printOut("User > ");
        var input_buf: [4096]u8 = undefined;
        const raw_line = sys.readStdin(&input_buf) catch break;
        if (raw_line.len == 0) break;
        const prompt = std.mem.trim(u8, raw_line, " \r\n");
        if (prompt.len == 0) break;

        // Queue raw bytes for background training
        training_queue.push(prompt);

        // Absorb with MASK_SCRIBE binding for inference
        // Queue raw runes for background training
        for (prompt) |rune| {
            const bound_vec = vsa.bind(vsa.generate(rune), vsa.MASK_SCRIBE);
            _ = try soul.absorb(bound_vec, rune, null);
        }

        // Generate response with Monte Carlo
        sys.printOut("Ghost > ");
        const gen_start = soul.concept;
        
        var eng = try allocator.create(engine_logic.SingularityEngine);
        defer allocator.destroy(eng);
        eng.* = engine_logic.SingularityEngine{
            .lattice = lattice,
            .meaning = &meaning_matrix,
            .soul = soul,
            .canvas = ghost_state.MesoLattice.initText(),
            .is_live = true,
            .inventory = [_]u8{0} ** 128,
            .inv_cursor = 0,
            .compute = global_compute,
            .vulkan = vsa_vulkan.getEngine(),
            .bmp_vectors = bmp_vectors,
            .allocator = allocator,
        };

        var runes: u32 = 0;
        const MAX_RUNES = 2048;
        while (runes < MAX_RUNES) : (runes += 1) {
            const chosen = eng.resolveTopology() orelse break;
            sys.printOut(&[_]u8{chosen});
            eng.inventory[eng.inv_cursor] = chosen;
            eng.inv_cursor = (eng.inv_cursor + 1) % 128;

            // Absorb generated rune into soul (bound)
            const bound_chosen = vsa.bind(vsa.generate(chosen), vsa.MASK_SCRIBE);
            _ = try soul.absorb(bound_chosen, chosen, null);

            // Queue generated runes for training too
            training_queue.push(&[_]u8{chosen});

            if (soul.last_boundary == .paragraph or vsa.hammingDistance(soul.concept, gen_start) > 450) break;
        }
        if (runes == MAX_RUNES) {
            sys.printOut("\n[SAFETY] Concept Drift Limit.\n");
        }
        sys.printOut("\n\n");
    }

    // ── 6. Clean shutdown ──
    sys.printOut("[SHUTDOWN] Stopping trainer...\n");
    stop_flag.store(true, .release);
    if (trainer_thread) |t| t.join();

    // Save state
    if (global_compute) |compute| {
        const gpu_lattice = compute.getLatticeData();
        const dst_ptr: [*]u16 = @ptrCast(@alignCast(mapped_lattice.data.ptr));
        @memcpy(dst_ptr[0..gpu_lattice.len], gpu_lattice);
        mapped_lattice.flush();
    }

    if (global_vk_engine) |vk| vk.deinit();
    sys.printOut("[SHUTDOWN] State saved. Goodbye.\n");
}
