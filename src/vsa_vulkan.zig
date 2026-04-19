const std = @import("std");
const vl = @import("vulkan_loader.zig");
const vk = vl.vk; // Types & constants only — no link-time dependency
const builtin = @import("builtin");
const config = @import("config.zig");
const sys = @import("sys.zig");
const vsa_core = @import("vsa_core.zig");
const sigil_runtime = @import("sigil_runtime.zig");

// --- GHOST ENGINE: VULKAN CORE ---
// Multi-GPU Sovereign Fleet.

pub const FRAME_COUNT = 3;
pub const INF_LANE_COUNT = 5; // Parallel inference streams for Monte Carlo
pub const ROTOR_STRIDE = 18; // 16x u64 spatial + 2x u64 (lexical, semantic)
const FENCE_TIMEOUT_NS: u64 = 2_000_000_000;
const SHUTDOWN_FENCE_TIMEOUT_NS: u64 = 5 * std.time.ns_per_s;
const VALIDATION_LAYER_NAME: [*:0]const u8 = "VK_LAYER_KHRONOS_validation";
const DEBUG_UTILS_EXTENSION_NAME: [*:0]const u8 = "VK_EXT_debug_utils";

const Mutex = struct {
    state: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    pub fn lock(self: *Mutex) void {
        while (self.state.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }
    pub fn unlock(self: *Mutex) void {
        self.state.store(0, .release);
    }
};

fn ghostCopy(comptime T: type, dest: []T, source: []const T) void {
    if (comptime builtin.zig_version.minor >= 14 or builtin.zig_version.major > 0) {
        @call(.always_inline, std.mem.copyForwards, .{ T, dest, source });
    } else {
        @call(.always_inline, std.mem.copy, .{ T, dest, source });
    }
}

pub const OperationalTier = enum(u32) {
    background = 1,
    standard = 2,
    high = 3,
    max = 4,
    extreme = 5,
    ultra = 6,
    hyper = 7,
    god = 8,

    pub fn getBatchSize(self: OperationalTier, max_wg: u32) u32 {
        const base = @max(max_wg, 1024);
        return switch (self) {
            .background => base / 8,
            .standard => base / 4,
            .high => base / 2,
            .max => base,
            .extreme => base * 2,
            .ultra => base * 4,
            .hyper => base * 8,
            .god => base * 16,
        };
    }
};

pub const DiagnosticState = struct {
    dropped_runes: u32 = 0,
    collision_stalls: u32 = 0,
};

pub const EngineConfig = struct {
    rotor_stride: u32,
    rotor_offset: u32,
    batch_size: u32,
};

fn check(result: vk.VkResult) !void {
    if (result != vk.VK_SUCCESS) {
        sys.print("[VULKAN] API Error: {d}\n", .{result});
        return error.VulkanError;
    }
}

const InstanceBootstrap = struct {
    instance: vk.VkInstance,
    validation_enabled: bool,
    debug_utils_enabled: bool,
};

fn fixedCStringEquals(buf: []const u8, expected: []const u8) bool {
    const end = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
    return std.mem.eql(u8, buf[0..end], expected);
}

fn beginGpuSubmit(self: *VulkanEngine) void {
    _ = self.active_gpu_submits.fetchAdd(1, .acq_rel);
}

fn endGpuSubmit(self: *VulkanEngine) void {
    _ = self.active_gpu_submits.fetchSub(1, .release);
}

pub fn getActiveGpuSubmitCount(self: *const VulkanEngine) u32 {
    return self.active_gpu_submits.load(.acquire);
}

pub fn waitForGpuWorkersDrained(self: *VulkanEngine) void {
    while (getActiveGpuSubmitCount(self) != 0) {
        sys.sleep(1);
    }
}

fn waitForAllHardwareInterruptsWithTimeout(self: *VulkanEngine, timeout_ns: u64) !void {
    for (0..FRAME_COUNT) |i| try self.waitForHardwareInterruptWithTimeout(i, timeout_ns);
}

fn hasInstanceLayer(ctx: *vl.VulkanCtx, allocator: std.mem.Allocator, layer_name: []const u8) !bool {
    var count: u32 = 0;
    try check(ctx.vkEnumerateInstanceLayerProperties.?(&count, null));
    if (count == 0) return false;

    const props = try allocator.alloc(vk.VkLayerProperties, count);
    defer allocator.free(props);
    try check(ctx.vkEnumerateInstanceLayerProperties.?(&count, props.ptr));

    for (props[0..count]) |prop| {
        if (fixedCStringEquals(prop.layerName[0..], layer_name)) return true;
    }
    return false;
}

fn hasInstanceExtension(ctx: *vl.VulkanCtx, allocator: std.mem.Allocator, extension_name: []const u8) !bool {
    var count: u32 = 0;
    try check(ctx.vkEnumerateInstanceExtensionProperties.?(null, &count, null));
    if (count == 0) return false;

    const props = try allocator.alloc(vk.VkExtensionProperties, count);
    defer allocator.free(props);
    try check(ctx.vkEnumerateInstanceExtensionProperties.?(null, &count, props.ptr));

    for (props[0..count]) |prop| {
        if (fixedCStringEquals(prop.extensionName[0..], extension_name)) return true;
    }
    return false;
}

fn createInstance(ctx: *vl.VulkanCtx, allocator: std.mem.Allocator, app_name: [*:0]const u8, engine_name: [*:0]const u8) !InstanceBootstrap {
    var appInfo = std.mem.zeroes(vk.VkApplicationInfo);
    appInfo.sType = vk.VK_STRUCTURE_TYPE_APPLICATION_INFO;
    appInfo.pApplicationName = app_name;
    appInfo.applicationVersion = vk.VK_MAKE_VERSION(1, 0, 0);
    appInfo.pEngineName = engine_name;
    appInfo.engineVersion = vk.VK_MAKE_VERSION(1, 0, 0);
    appInfo.apiVersion = vk.VK_API_VERSION_1_2;

    const validation_enabled = try hasInstanceLayer(ctx, allocator, std.mem.span(VALIDATION_LAYER_NAME));
    const debug_utils_enabled = validation_enabled and try hasInstanceExtension(ctx, allocator, std.mem.span(DEBUG_UTILS_EXTENSION_NAME));

    if (validation_enabled) {
        sys.printOut("[VULKAN] Validation layer enabled.\n");
    } else {
        sys.printOut("[VULKAN] Validation layer unavailable; continuing without Khronos diagnostics.\n");
    }

    var layers = [_][*:0]const u8{VALIDATION_LAYER_NAME};
    var extensions = [_][*:0]const u8{DEBUG_UTILS_EXTENSION_NAME};

    var createInfo = std.mem.zeroes(vk.VkInstanceCreateInfo);
    createInfo.sType = vk.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    createInfo.pApplicationInfo = &appInfo;
    if (validation_enabled) {
        createInfo.enabledLayerCount = layers.len;
        createInfo.ppEnabledLayerNames = &layers;
    }
    if (debug_utils_enabled) {
        createInfo.enabledExtensionCount = extensions.len;
        createInfo.ppEnabledExtensionNames = &extensions;
    }

    var instance: vk.VkInstance = null;
    try check(ctx.vkCreateInstance.?(&createInfo, null, &instance));
    return .{
        .instance = instance,
        .validation_enabled = validation_enabled,
        .debug_utils_enabled = debug_utils_enabled,
    };
}

fn debugSeverityLabel(severity: vk.VkDebugUtilsMessageSeverityFlagBitsEXT) []const u8 {
    if ((severity & vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT) != 0) return "ERROR";
    if ((severity & vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT) != 0) return "WARN";
    if ((severity & vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT) != 0) return "INFO";
    return "VERBOSE";
}

fn validationCallback(
    severity: vk.VkDebugUtilsMessageSeverityFlagBitsEXT,
    _: vk.VkDebugUtilsMessageTypeFlagsEXT,
    callback_data: ?*const vk.VkDebugUtilsMessengerCallbackDataEXT,
    _: ?*anyopaque,
) callconv(.c) vk.VkBool32 {
    const message = if (callback_data) |data|
        if (data.pMessage != null) std.mem.span(data.pMessage) else "<no message>"
    else
        "<null callback>";
    sys.print("[VULKAN VALIDATION][{s}] {s}\n", .{ debugSeverityLabel(severity), message });
    return vk.VK_FALSE;
}

pub const VulkanEngine = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    vk_ctx: vl.VulkanCtx,
    instance: vk.VkInstance = null,
    debug_messenger: vk.VkDebugUtilsMessengerEXT = null,
    validation_enabled: bool = false,
    pdev: vk.VkPhysicalDevice = null,
    dev: vk.VkDevice = null,
    queues: [8]vk.VkQueue = [_]vk.VkQueue{null} ** 8,
    num_queues: u32 = 0,
    queue_family: u32 = 0,
    queue: vk.VkQueue = null,

    // Performance Profiles
    vram_size: usize = 0,
    is_discrete: bool = false,
    performance_score: u32 = 0,
    device_index: u32 = 0,
    device_name: [256]u8 = [_]u8{0} ** 256,
    max_workgroup_invocations: u32 = 0,
    supports_int16: bool = false,
    max_alloc_count: u32 = 0,

    // Pipeline Objects
    descriptor_set_layout: vk.VkDescriptorSetLayout = null,
    pipeline_layout: vk.VkPipelineLayout = null,
    compute_pipeline: vk.VkPipeline = null,
    etch_pipeline: vk.VkPipeline = null,
    prune_pipeline: vk.VkPipeline = null,
    lookahead_pipeline: vk.VkPipeline = null,
    lattice_pipeline: vk.VkPipeline = null,

    // Synchronization
    timeline_semaphore: vk.VkSemaphore = null,
    timeline_value: u64 = 0,
    dispatch_mutex: Mutex = .{},
    frame_idx: u32 = 0,
    active_gpu_submits: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    fences: [FRAME_COUNT]vk.VkFence = [_]vk.VkFence{null} ** FRAME_COUNT,
    frame_generations: [FRAME_COUNT]u64 = [_]u64{0} ** FRAME_COUNT,

    // ── Dedicated Transfer Queue (V29) ──
    has_dedicated_transfer: bool = false,
    transfer_queue_family: u32 = 0,
    transfer_queue: vk.VkQueue = null,
    transfer_pool: vk.VkCommandPool = null,
    transfer_buffers: [FRAME_COUNT]vk.VkCommandBuffer = [_]vk.VkCommandBuffer{null} ** FRAME_COUNT,
    transfer_fences: [FRAME_COUNT]vk.VkFence = [_]vk.VkFence{null} ** FRAME_COUNT,
    transfer_semaphores: [FRAME_COUNT]vk.VkSemaphore = [_]vk.VkSemaphore{null} ** FRAME_COUNT,

    // Global Silicon Lobe (Monolith)
    matrix_buffer: vk.VkBuffer = null,
    matrix_memory: vk.VkDeviceMemory = null,
    mapped_matrix: ?[*]u32 = null,
    matrix_slots: u32 = 0,
    gpu_matrix_size: usize = 0,
    matrix_flags: vk.VkMemoryPropertyFlags = 0,

    tag_buffer: vk.VkBuffer = null,
    tag_memory: vk.VkDeviceMemory = null,
    mapped_tags: ?[*]u64 = null,

    lattice_buffer: vk.VkBuffer = null,
    lattice_memory: vk.VkDeviceMemory = null,
    mapped_lattice: ?[*]u16 = null,
    gpu_lattice_size: usize = 0,
    lattice_quarter: u32 = 0,

    // Phantom Lobe (Sigil Cartridge)
    sigil_buffer: vk.VkBuffer = null,
    sigil_memory: vk.VkDeviceMemory = null,
    mapped_sigil: ?[*]u16 = null,
    sigil_capacity: usize = 0,

    // Diagnostic Lobe (Telemetry SSBO)
    diag_buffer: vk.VkBuffer = null,
    diag_memory: vk.VkDeviceMemory = null,
    mapped_diag: ?*DiagnosticState = null,

    // Hardware lock mask for Sigil slot freezes
    lock_mask_buffer: vk.VkBuffer = null,
    lock_mask_memory: vk.VkDeviceMemory = null,
    mapped_lock_mask: ?[*]u32 = null,
    lock_mask_words: usize = 0,

    // V33: Panopticon Flat Graph
    panopticon_buffer: vk.VkBuffer = null,
    panopticon_memory: vk.VkDeviceMemory = null,
    mapped_edges: ?[*]u32 = null,

    // Batch Ring Buffers
    rotor_buffers: [FRAME_COUNT]vk.VkBuffer = [_]vk.VkBuffer{null} ** FRAME_COUNT,
    rotor_memories: [FRAME_COUNT]vk.VkDeviceMemory = [_]vk.VkDeviceMemory{null} ** FRAME_COUNT,
    mapped_rotors: [FRAME_COUNT]?[*]u64 = [_]?[*]u64{null} ** FRAME_COUNT,

    char_buffers: [FRAME_COUNT]vk.VkBuffer = [_]vk.VkBuffer{null} ** FRAME_COUNT,
    char_memories: [FRAME_COUNT]vk.VkDeviceMemory = [_]vk.VkDeviceMemory{null} ** FRAME_COUNT,
    mapped_chars: [FRAME_COUNT]?[*]u32 = [_]?[*]u32{null} ** FRAME_COUNT,

    index_buffers: [FRAME_COUNT]vk.VkBuffer = [_]vk.VkBuffer{null} ** FRAME_COUNT,
    index_memories: [FRAME_COUNT]vk.VkDeviceMemory = [_]vk.VkDeviceMemory{null} ** FRAME_COUNT,
    mapped_index: [FRAME_COUNT]?[*]u32 = [_]?[*]u32{null} ** FRAME_COUNT,

    energy_buffers: [FRAME_COUNT]vk.VkBuffer = [_]vk.VkBuffer{null} ** FRAME_COUNT,
    energy_memories: [FRAME_COUNT]vk.VkDeviceMemory = [_]vk.VkDeviceMemory{null} ** FRAME_COUNT,
    mapped_energy: [FRAME_COUNT]?[*]u32 = [_]?[*]u32{null} ** FRAME_COUNT,

    config_buffers: [FRAME_COUNT]vk.VkBuffer = [_]vk.VkBuffer{null} ** FRAME_COUNT,
    config_memories: [FRAME_COUNT]vk.VkDeviceMemory = [_]vk.VkDeviceMemory{null} ** FRAME_COUNT,
    mapped_config: [FRAME_COUNT]?*EngineConfig = [_]?*EngineConfig{null} ** FRAME_COUNT,

    descriptor_pool: vk.VkDescriptorPool = null,
    descriptor_sets: [FRAME_COUNT]vk.VkDescriptorSet = [_]vk.VkDescriptorSet{null} ** FRAME_COUNT,
    command_pools: [FRAME_COUNT]vk.VkCommandPool = [_]vk.VkCommandPool{null} ** FRAME_COUNT,
    command_buffers: [FRAME_COUNT]vk.VkCommandBuffer = [_]vk.VkCommandBuffer{null} ** FRAME_COUNT,

    // Multi-GPU Shared States (cached to avoid re-sync)
    host_matrix: ?[]u32 = null,
    host_tags: ?[]u64 = null,
    host_lattice: ?[]u16 = null,

    result_buffer: []u32,
    batch_flags: vk.VkMemoryPropertyFlags = 0,
    tier: OperationalTier = .standard,

    // ── Inference Resources (Monte Carlo Ring) ──
    inf_rotor_buffers: [INF_LANE_COUNT]vk.VkBuffer = [_]vk.VkBuffer{null} ** INF_LANE_COUNT,
    inf_rotor_memories: [INF_LANE_COUNT]vk.VkDeviceMemory = [_]vk.VkDeviceMemory{null} ** INF_LANE_COUNT,
    inf_mapped_rotors: [INF_LANE_COUNT]?[*]u64 = [_]?[*]u64{null} ** INF_LANE_COUNT,

    inf_energy_buffers: [INF_LANE_COUNT]vk.VkBuffer = [_]vk.VkBuffer{null} ** INF_LANE_COUNT,
    inf_energy_memories: [INF_LANE_COUNT]vk.VkDeviceMemory = [_]vk.VkDeviceMemory{null} ** INF_LANE_COUNT,
    inf_mapped_energy: [INF_LANE_COUNT]?[*]u32 = [_]?[*]u32{null} ** INF_LANE_COUNT,

    inf_config_buffers: [INF_LANE_COUNT]vk.VkBuffer = [_]vk.VkBuffer{null} ** INF_LANE_COUNT,
    inf_config_memories: [INF_LANE_COUNT]vk.VkDeviceMemory = [_]vk.VkDeviceMemory{null} ** INF_LANE_COUNT,
    inf_mapped_config: [INF_LANE_COUNT]?*EngineConfig = [_]?*EngineConfig{null} ** INF_LANE_COUNT,

    inf_descriptor_sets: [INF_LANE_COUNT]vk.VkDescriptorSet = [_]vk.VkDescriptorSet{null} ** INF_LANE_COUNT,
    inf_command_pools: [INF_LANE_COUNT]vk.VkCommandPool = [_]vk.VkCommandPool{null} ** INF_LANE_COUNT,
    inf_command_buffers: [INF_LANE_COUNT]vk.VkCommandBuffer = [_]vk.VkCommandBuffer{null} ** INF_LANE_COUNT,
    inf_fences: [INF_LANE_COUNT]vk.VkFence = [_]vk.VkFence{null} ** INF_LANE_COUNT,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !*VulkanEngine {
        var ctx = try vl.VulkanCtx.load();
        const boot = try createInstance(&ctx, allocator, "Ghost-Sovereign", "Ghost-VSA");
        ctx.loadInstance(boot.instance);

        var pdevCount: u32 = 0;
        try check(ctx.vkEnumeratePhysicalDevices.?(boot.instance, &pdevCount, null));
        if (pdevCount == 0) return error.NoGpuFound;
        const pdevs = try allocator.alloc(vk.VkPhysicalDevice, pdevCount);
        defer allocator.free(pdevs);
        try check(ctx.vkEnumeratePhysicalDevices.?(boot.instance, &pdevCount, pdevs.ptr));

        // Select primary GPU (prefer discrete with most VRAM)
        var best_idx: u32 = 0;
        var max_score: u32 = 0;
        for (pdevs, 0..) |p, i| {
            var props: vk.VkPhysicalDeviceProperties = undefined;
            ctx.vkGetPhysicalDeviceProperties.?(p, &props);
            var score: u32 = 0;
            if (props.deviceType == vk.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU) score += 10000;
            score += props.limits.maxComputeWorkGroupInvocations;
            if (score > max_score) {
                max_score = score;
                best_idx = @intCast(i);
            }
        }

        const engine = try allocator.create(VulkanEngine);
        engine.* = .{
            .allocator = allocator,
            .io = io,
            .vk_ctx = ctx,
            .instance = boot.instance,
            .validation_enabled = boot.validation_enabled,
            .pdev = pdevs[best_idx],
            .result_buffer = try allocator.alloc(u32, 65536),
        };

        try engine.initDebugMessenger(boot.debug_utils_enabled);

        var qfCount: u32 = 0;
        ctx.vkGetPhysicalDeviceQueueFamilyProperties.?(engine.pdev, &qfCount, null);
        const qfs = try allocator.alloc(vk.VkQueueFamilyProperties, qfCount);
        defer allocator.free(qfs);
        ctx.vkGetPhysicalDeviceQueueFamilyProperties.?(engine.pdev, &qfCount, qfs.ptr);

        var compute_family: ?u32 = null;
        for (qfs, 0..) |qf, i| {
            if ((qf.queueFlags & vk.VK_QUEUE_COMPUTE_BIT) != 0) {
                compute_family = @intCast(i);
                engine.num_queues = @min(qf.queueCount, 8);
                break;
            }
        }
        engine.queue_family = compute_family orelse return error.NoComputeQueue;

        return try engine.initCommon();
    }

    pub fn initForDevice(allocator: std.mem.Allocator, device_index: u32, io: std.Io) !VulkanEngine {
        var ctx = try vl.VulkanCtx.load();
        const boot = try createInstance(&ctx, allocator, "Ghost-Sovereign-Multi", "Ghost-VSA");
        ctx.loadInstance(boot.instance);

        var pdevCount: u32 = 0;
        try check(ctx.vkEnumeratePhysicalDevices.?(boot.instance, &pdevCount, null));
        const pdevs = try allocator.alloc(vk.VkPhysicalDevice, pdevCount);
        defer allocator.free(pdevs);
        try check(ctx.vkEnumeratePhysicalDevices.?(boot.instance, &pdevCount, pdevs.ptr));

        if (device_index >= pdevCount) return error.DeviceIndexOutOfBounds;

        var engine = VulkanEngine{
            .allocator = allocator,
            .io = io,
            .vk_ctx = ctx,
            .instance = boot.instance,
            .validation_enabled = boot.validation_enabled,
            .pdev = pdevs[device_index],
            .device_index = device_index,
            .result_buffer = try allocator.alloc(u32, 65536),
        };

        try engine.initDebugMessenger(boot.debug_utils_enabled);

        var qfCount: u32 = 0;
        ctx.vkGetPhysicalDeviceQueueFamilyProperties.?(engine.pdev, &qfCount, null);
        const qfs = try allocator.alloc(vk.VkQueueFamilyProperties, qfCount);
        defer allocator.free(qfs);
        ctx.vkGetPhysicalDeviceQueueFamilyProperties.?(engine.pdev, &qfCount, qfs.ptr);

        var compute_family: ?u32 = null;
        for (qfs, 0..) |qf, i| {
            if ((qf.queueFlags & vk.VK_QUEUE_COMPUTE_BIT) != 0) {
                compute_family = @intCast(i);
                engine.num_queues = @min(qf.queueCount, 8);
                break;
            }
        }
        engine.queue_family = compute_family orelse return error.NoComputeQueue;

        _ = try engine.initCommon();
        return engine;
    }

    fn initDebugMessenger(self: *VulkanEngine, debug_utils_enabled: bool) !void {
        if (!self.validation_enabled or !debug_utils_enabled) return;
        const create_fn = self.vk_ctx.vkCreateDebugUtilsMessengerEXT orelse return;

        var create_info = std.mem.zeroes(vk.VkDebugUtilsMessengerCreateInfoEXT);
        create_info.sType = vk.VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT;
        create_info.messageSeverity =
            vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT |
            vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT |
            vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT |
            vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT;
        create_info.messageType =
            vk.VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT |
            vk.VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT |
            vk.VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT;
        create_info.pfnUserCallback = validationCallback;

        try check(create_fn(self.instance, &create_info, null, &self.debug_messenger));
        sys.printOut("[VULKAN] Debug utils messenger online.\n");
    }

    fn detectHardware(self: *VulkanEngine) !void {
        var deviceFeatures: vk.VkPhysicalDeviceFeatures = undefined;
        self.vk_ctx.vkGetPhysicalDeviceFeatures.?(self.pdev, &deviceFeatures);
        self.supports_int16 = deviceFeatures.shaderInt16 == vk.VK_TRUE;

        var devProps: vk.VkPhysicalDeviceProperties = undefined;
        self.vk_ctx.vkGetPhysicalDeviceProperties.?(self.pdev, &devProps);
        self.max_workgroup_invocations = devProps.limits.maxComputeWorkGroupInvocations;
        self.max_alloc_count = devProps.limits.maxMemoryAllocationCount;
        self.is_discrete = devProps.deviceType == vk.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU;

        var score: u32 = 0;
        if (self.is_discrete) score += 5000;
        score += self.max_workgroup_invocations;
        score += @intCast(devProps.limits.maxBoundDescriptorSets * 10);
        self.performance_score = score;

        for (devProps.deviceName, 0..) |c, i| {
            if (i >= 255) break;
            self.device_name[i] = c;
        }

        var memProps: vk.VkPhysicalDeviceMemoryProperties = undefined;
        self.vk_ctx.vkGetPhysicalDeviceMemoryProperties.?(self.pdev, &memProps);
        self.vram_size = 0;
        for (memProps.memoryHeaps[0..memProps.memoryHeapCount]) |heap| {
            if ((heap.flags & vk.VK_MEMORY_HEAP_DEVICE_LOCAL_BIT) != 0) {
                self.vram_size += heap.size;
            }
        }

        sys.print("[VULKAN-{d}] Selected Device: {s}\n", .{self.device_index, devProps.deviceName});
        sys.print("[VULKAN-{d}] VRAM Detect: {d} MB | Parallel Streams: {d}\n", .{ self.device_index, self.vram_size / 1048576, self.num_queues });

        var qfCount: u32 = 0;
        self.vk_ctx.vkGetPhysicalDeviceQueueFamilyProperties.?(self.pdev, &qfCount, null);
        const qfs = try self.allocator.alloc(vk.VkQueueFamilyProperties, qfCount);
        defer self.allocator.free(qfs);
        self.vk_ctx.vkGetPhysicalDeviceQueueFamilyProperties.?(self.pdev, &qfCount, qfs.ptr);

        var transfer_family: ?u32 = null;
        for (qfs, 0..) |qf, i| {
            const idx = @as(u32, @intCast(i));
            if (idx == self.queue_family) continue;
            if ((qf.queueFlags & vk.VK_QUEUE_TRANSFER_BIT) != 0 and
                (qf.queueFlags & vk.VK_QUEUE_COMPUTE_BIT) == 0 and
                (qf.queueFlags & vk.VK_QUEUE_GRAPHICS_BIT) == 0)
            {
                transfer_family = idx;
                break;
            }
        }
        if (transfer_family == null) {
            for (qfs, 0..) |qf, i| {
                const idx = @as(u32, @intCast(i));
                if (idx == self.queue_family) continue;
                if ((qf.queueFlags & vk.VK_QUEUE_TRANSFER_BIT) != 0 and
                    (qf.queueFlags & vk.VK_QUEUE_COMPUTE_BIT) == 0)
                {
                    transfer_family = idx;
                    break;
                }
            }
        }

        if (transfer_family) |tf| {
            self.has_dedicated_transfer = true;
            self.transfer_queue_family = tf;
            sys.print("[VULKAN-{d}] Dedicated Transfer Queue: Family {d}\n", .{self.device_index, tf});
        } else {
            self.has_dedicated_transfer = false;
            self.transfer_queue_family = self.queue_family;
            sys.print("[VULKAN-{d}] No dedicated transfer queue — using compute queue\n", .{self.device_index});
        }
    }

    fn setupLogicalDevice(self: *VulkanEngine) !void {
        const qPriorities = [_]f32{1.0} ** 8;
        var queue_create_infos: [2]vk.VkDeviceQueueCreateInfo = undefined;
        var queue_create_count: u32 = 1;

        queue_create_infos[0] = std.mem.zeroes(vk.VkDeviceQueueCreateInfo);
        queue_create_infos[0].sType = vk.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
        queue_create_infos[0].queueFamilyIndex = self.queue_family;
        queue_create_infos[0].queueCount = self.num_queues;
        queue_create_infos[0].pQueuePriorities = &qPriorities;

        if (self.has_dedicated_transfer) {
            queue_create_infos[1] = std.mem.zeroes(vk.VkDeviceQueueCreateInfo);
            queue_create_infos[1].sType = vk.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
            queue_create_infos[1].queueFamilyIndex = self.transfer_queue_family;
            queue_create_infos[1].queueCount = 1;
            queue_create_infos[1].pQueuePriorities = &qPriorities;
            queue_create_count = 2;
        }

        var features11 = std.mem.zeroes(vk.VkPhysicalDeviceVulkan11Features);
        features11.sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES;
        features11.storageBuffer16BitAccess = vk.VK_TRUE;
        features11.uniformAndStorageBuffer16BitAccess = vk.VK_TRUE;

        var features12 = std.mem.zeroes(vk.VkPhysicalDeviceVulkan12Features);
        features12.sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES;
        features12.timelineSemaphore = vk.VK_TRUE;
        features12.shaderBufferInt64Atomics = vk.VK_TRUE;
        features12.pNext = &features11;

        var features = std.mem.zeroes(vk.VkPhysicalDeviceFeatures2);
        features.sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2;
        features.features.shaderInt64 = vk.VK_TRUE;
        features.features.shaderInt16 = vk.VK_TRUE;
        features.pNext = &features12;

        var dCreateInfo = std.mem.zeroes(vk.VkDeviceCreateInfo);
        dCreateInfo.sType = vk.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
        dCreateInfo.queueCreateInfoCount = queue_create_count;
        dCreateInfo.pQueueCreateInfos = &queue_create_infos[0];
        dCreateInfo.pNext = &features;
        try check(self.vk_ctx.vkCreateDevice.?(self.pdev, &dCreateInfo, null, &self.dev));

        for (0..self.num_queues) |i| {
            self.vk_ctx.vkGetDeviceQueue.?(self.dev, self.queue_family, @intCast(i), &self.queues[i]);
        }
        if (self.has_dedicated_transfer) {
            self.vk_ctx.vkGetDeviceQueue.?(self.dev, self.transfer_queue_family, 0, &self.transfer_queue);
        } else {
            self.transfer_queue = self.queues[0];
        }
    }

    fn findMemoryType(self: *const VulkanEngine, typeFilter: u32, properties: vk.VkMemoryPropertyFlags) !u32 {
        var memProperties: vk.VkPhysicalDeviceMemoryProperties = undefined;
        self.vk_ctx.vkGetPhysicalDeviceMemoryProperties.?(self.pdev, &memProperties);
        var i: u32 = 0;
        while (i < memProperties.memoryTypeCount) : (i += 1) {
            if ((typeFilter & (@as(u32, 1) << @intCast(i))) != 0 and (memProperties.memoryTypes[i].propertyFlags & properties) == properties) {
                return i;
            }
        }
        return error.MemoryTypeNotFound;
    }

    fn createBuffer(self: *VulkanEngine, size: usize, usage: vk.VkBufferUsageFlags, properties: vk.VkMemoryPropertyFlags, buffer: *vk.VkBuffer, memory: *vk.VkDeviceMemory) !?*anyopaque {
        var bCreateInfo = std.mem.zeroes(vk.VkBufferCreateInfo);
        bCreateInfo.sType = vk.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
        bCreateInfo.size = size;
        bCreateInfo.usage = usage;
        bCreateInfo.sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE;

        try check(self.vk_ctx.vkCreateBuffer.?(self.dev, &bCreateInfo, null, buffer));

        var memReqs: vk.VkMemoryRequirements = undefined;
        self.vk_ctx.vkGetBufferMemoryRequirements.?(self.dev, buffer.*, &memReqs);

        var allocInfo = std.mem.zeroes(vk.VkMemoryAllocateInfo);
        allocInfo.sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        allocInfo.allocationSize = memReqs.size;
        allocInfo.memoryTypeIndex = try self.findMemoryType(memReqs.memoryTypeBits, properties);

        try check(self.vk_ctx.vkAllocateMemory.?(self.dev, &allocInfo, null, memory));
        try check(self.vk_ctx.vkBindBufferMemory.?(self.dev, buffer.*, memory.*, 0));

        if ((properties & vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT) != 0) {
            var data: ?*anyopaque = null;
            try check(self.vk_ctx.vkMapMemory.?(self.dev, memory.*, 0, size, 0, &data));
            return data;
        }
        return null;
    }

    fn allocateBuffers(self: *VulkanEngine) !void {
        const usable = if (self.vram_size > config.VRAM_HIGH_TIER_THRESHOLD) self.vram_size * config.VRAM_HIGH_TIER_USABLE_PERCENT / 100 else self.vram_size * config.VRAM_LOW_TIER_USABLE_PERCENT / 100;
        const max_matrix = if (self.is_discrete)
            @min(config.IDEAL_MATRIX_SIZE, usable * config.VRAM_MATRIX_BUDGET_PERCENT / 100)
        else
            config.SEMANTIC_SIZE_BYTES;
        const max_lattice = if (self.is_discrete)
            @min(config.IDEAL_LATTICE_SIZE, usable * config.VRAM_LATTICE_BUDGET_PERCENT / 100)
        else
            config.UNIFIED_SIZE_BYTES;

        const raw_slots = max_matrix / (config.SLOTS_PER_VECTOR * 4);
        var slots: u32 = 1;
        while (slots * 2 <= raw_slots) : (slots *= 2) {}
        self.matrix_slots = @min(@as(u32, @intCast(config.SEMANTIC_SLOTS)), @min(config.MAX_MATRIX_SLOTS, slots));
        
        self.gpu_matrix_size = @as(usize, self.matrix_slots) * 1024 * 4;
        self.gpu_lattice_size = max_lattice;
        self.lattice_quarter = @intCast(self.gpu_lattice_size / 8);

        self.matrix_flags = vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
        if (self.is_discrete and self.vram_size > config.VRAM_HIGH_TIER_THRESHOLD) {
            self.matrix_flags |= vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT;
        }
        self.batch_flags = vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;

        const matrix_usage = vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | vk.VK_BUFFER_USAGE_TRANSFER_SRC_BIT | vk.VK_BUFFER_USAGE_TRANSFER_DST_BIT;

        self.mapped_matrix = @ptrCast(@alignCast(try self.createBuffer(self.gpu_matrix_size, matrix_usage, self.matrix_flags, &self.matrix_buffer, &self.matrix_memory) orelse return error.VulkanError));
        self.mapped_tags = @ptrCast(@alignCast(try self.createBuffer(@as(usize, self.matrix_slots) * 8, matrix_usage, self.matrix_flags, &self.tag_buffer, &self.tag_memory) orelse return error.VulkanError));
        self.mapped_lattice = @ptrCast(@alignCast(try self.createBuffer(self.gpu_lattice_size, matrix_usage, self.matrix_flags, &self.lattice_buffer, &self.lattice_memory) orelse return error.VulkanError));

        for (0..FRAME_COUNT) |i| {
            self.mapped_rotors[i] = @ptrCast(@alignCast(try self.createBuffer(20480 * 144, vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, self.batch_flags, &self.rotor_buffers[i], &self.rotor_memories[i]) orelse return error.VulkanError));
            self.mapped_chars[i] = @ptrCast(@alignCast(try self.createBuffer(config.MAX_STREAMS * 4, vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, self.batch_flags, &self.char_buffers[i], &self.char_memories[i]) orelse return error.VulkanError));
            self.mapped_index[i] = @ptrCast(@alignCast(try self.createBuffer(config.MAX_STREAMS * 4, vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, self.batch_flags, &self.index_buffers[i], &self.index_memories[i]) orelse return error.VulkanError));
            self.mapped_energy[i] = @ptrCast(@alignCast(try self.createBuffer(65536 * 4, vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, self.batch_flags, &self.energy_buffers[i], &self.energy_memories[i]) orelse return error.VulkanError));
            self.mapped_config[i] = @ptrCast(@alignCast(try self.createBuffer(@sizeOf(EngineConfig), vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, self.batch_flags, &self.config_buffers[i], &self.config_memories[i]) orelse return error.VulkanError));
        }

        for (0..INF_LANE_COUNT) |i| {
            self.inf_mapped_rotors[i] = @ptrCast(@alignCast(try self.createBuffer(config.BMP_SPACE_SIZE * 16, vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, self.batch_flags, &self.inf_rotor_buffers[i], &self.inf_rotor_memories[i]) orelse return error.VulkanError));
            self.inf_mapped_energy[i] = @ptrCast(@alignCast(try self.createBuffer(config.BMP_SPACE_SIZE * 4, vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, self.batch_flags, &self.inf_energy_buffers[i], &self.inf_energy_memories[i]) orelse return error.VulkanError));
            self.inf_mapped_config[i] = @ptrCast(@alignCast(try self.createBuffer(@sizeOf(EngineConfig), vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, self.batch_flags, &self.inf_config_buffers[i], &self.inf_config_memories[i]) orelse return error.VulkanError));
        }

        self.sigil_capacity = 4096;
        self.mapped_sigil = @ptrCast(@alignCast(try self.createBuffer(self.sigil_capacity, matrix_usage, self.matrix_flags, &self.sigil_buffer, &self.sigil_memory) orelse return error.VulkanError));
        self.mapped_diag = @ptrCast(@alignCast(try self.createBuffer(@sizeOf(DiagnosticState), matrix_usage, self.batch_flags, &self.diag_buffer, &self.diag_memory) orelse return error.VulkanError));
        self.lock_mask_words = (self.matrix_slots + 31) / 32;
        self.mapped_lock_mask = @ptrCast(@alignCast(try self.createBuffer(self.lock_mask_words * @sizeOf(u32), matrix_usage, self.batch_flags, &self.lock_mask_buffer, &self.lock_mask_memory) orelse return error.VulkanError));
        @memset(std.mem.sliceAsBytes(self.mapped_lock_mask.?[0..self.lock_mask_words]), 0);
        
        const panop_size = @as(usize, self.matrix_slots) * 16 * 4; // GRAPH_EDGES = 16
        self.mapped_edges = @ptrCast(@alignCast(try self.createBuffer(panop_size, matrix_usage, self.matrix_flags, &self.panopticon_buffer, &self.panopticon_memory) orelse return error.VulkanError));
        var graph = vsa_core.FlatGraph.fromMapped(@as([*]vsa_core.GraphNode, @ptrCast(@alignCast(self.mapped_edges.?))), self.matrix_slots);
        graph.clear();
    }

    fn createComputePipeline(self: *VulkanEngine, spv: []const u8, spec_info: ?*const vk.VkSpecializationInfo) !vk.VkPipeline {
        const spv_u32 = try self.allocator.alloc(u32, spv.len / 4);
        defer self.allocator.free(spv_u32);
        @memcpy(std.mem.sliceAsBytes(spv_u32), spv);

        var smCreateInfo = std.mem.zeroes(vk.VkShaderModuleCreateInfo);
        smCreateInfo.sType = vk.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
        smCreateInfo.codeSize = spv.len;
        smCreateInfo.pCode = spv_u32.ptr;
        var module: vk.VkShaderModule = null;
        try check(self.vk_ctx.vkCreateShaderModule.?(self.dev, &smCreateInfo, null, &module));
        defer self.vk_ctx.vkDestroyShaderModule.?(self.dev, module, null);

        var stageInfo = std.mem.zeroes(vk.VkPipelineShaderStageCreateInfo);
        stageInfo.sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        stageInfo.stage = vk.VK_SHADER_STAGE_COMPUTE_BIT;
        stageInfo.module = module;
        stageInfo.pName = "main";
        stageInfo.pSpecializationInfo = spec_info;

        var pipelineInfo = std.mem.zeroes(vk.VkComputePipelineCreateInfo);
        pipelineInfo.sType = vk.VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO;
        pipelineInfo.stage = stageInfo;
        pipelineInfo.layout = self.pipeline_layout;

        var pipeline: vk.VkPipeline = null;
        try check(self.vk_ctx.vkCreateComputePipelines.?(self.dev, null, 1, &pipelineInfo, null, &pipeline));
        return pipeline;
    }

    fn setupPipelines(self: *VulkanEngine) !void {
        var pcRange = std.mem.zeroes(vk.VkPushConstantRange);
        pcRange.stageFlags = vk.VK_SHADER_STAGE_COMPUTE_BIT;
        pcRange.size = 16;

        var bindings = [_]vk.VkDescriptorSetLayoutBinding{ std.mem.zeroes(vk.VkDescriptorSetLayoutBinding) } ** 12;
        for (&bindings, 0..) |*b, i| {
            b.binding = @intCast(i);
            b.descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
            b.descriptorCount = 1;
            b.stageFlags = vk.VK_SHADER_STAGE_COMPUTE_BIT;
        }

        var dslCreateInfo = std.mem.zeroes(vk.VkDescriptorSetLayoutCreateInfo);
        dslCreateInfo.sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
        dslCreateInfo.bindingCount = 12;
        dslCreateInfo.pBindings = &bindings[0];
        try check(self.vk_ctx.vkCreateDescriptorSetLayout.?(self.dev, &dslCreateInfo, null, &self.descriptor_set_layout));

        var plCreateInfo = std.mem.zeroes(vk.VkPipelineLayoutCreateInfo);
        plCreateInfo.sType = vk.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
        plCreateInfo.setLayoutCount = 1;
        plCreateInfo.pSetLayouts = &self.descriptor_set_layout;
        plCreateInfo.pushConstantRangeCount = 1;
        plCreateInfo.pPushConstantRanges = &pcRange;
        try check(self.vk_ctx.vkCreatePipelineLayout.?(self.dev, &plCreateInfo, null, &self.pipeline_layout));

        self.compute_pipeline = try self.createComputePipeline(@embedFile("shaders/resonance_query.spv"), null);
        
        var etch_wg_size: u32 = @min(1024, self.max_workgroup_invocations);
        var spec_map = vk.VkSpecializationMapEntry{ .constantID = 0, .offset = 0, .size = @sizeOf(u32) };
        var etch_spec = vk.VkSpecializationInfo{ .mapEntryCount = 1, .pMapEntries = &spec_map, .dataSize = @sizeOf(u32), .pData = &etch_wg_size };
        self.etch_pipeline = try self.createComputePipeline(@embedFile("shaders/genesis_etch.spv"), &etch_spec);
        
        self.prune_pipeline = try self.createComputePipeline(@embedFile("shaders/thermal_prune.spv"), null);
        self.lookahead_pipeline = try self.createComputePipeline(@embedFile("shaders/recursive_lookahead.spv"), null);
        
        var lattice_wg_size: u32 = @min(1024, self.max_workgroup_invocations);
        var lattice_spec = vk.VkSpecializationInfo{ .mapEntryCount = 1, .pMapEntries = &spec_map, .dataSize = @sizeOf(u32), .pData = &lattice_wg_size };
        self.lattice_pipeline = try self.createComputePipeline(@embedFile("shaders/lattice_etch.spv"), &lattice_spec);
    }

    fn updateDescriptorSets(self: *VulkanEngine, f: u32) void {
        var info = [_]vk.VkDescriptorBufferInfo{ std.mem.zeroes(vk.VkDescriptorBufferInfo) } ** 12;
        info[0] = .{ .buffer = self.matrix_buffer, .offset = 0, .range = vk.VK_WHOLE_SIZE };
        info[1] = .{ .buffer = self.rotor_buffers[f], .offset = 0, .range = vk.VK_WHOLE_SIZE };
        info[2] = .{ .buffer = self.char_buffers[f], .offset = 0, .range = vk.VK_WHOLE_SIZE };
        info[3] = .{ .buffer = self.index_buffers[f], .offset = 0, .range = vk.VK_WHOLE_SIZE };
        info[4] = .{ .buffer = self.tag_buffer, .offset = 0, .range = vk.VK_WHOLE_SIZE };
        info[5] = .{ .buffer = self.lattice_buffer, .offset = 0, .range = vk.VK_WHOLE_SIZE };
        info[6] = .{ .buffer = self.energy_buffers[f], .offset = 0, .range = vk.VK_WHOLE_SIZE };
        info[7] = .{ .buffer = self.sigil_buffer, .offset = 0, .range = vk.VK_WHOLE_SIZE };
        info[8] = .{ .buffer = self.diag_buffer, .offset = 0, .range = vk.VK_WHOLE_SIZE };
        info[9] = .{ .buffer = self.panopticon_buffer, .offset = 0, .range = vk.VK_WHOLE_SIZE };
        info[10] = .{ .buffer = self.config_buffers[f], .offset = 0, .range = vk.VK_WHOLE_SIZE };
        info[11] = .{ .buffer = self.lock_mask_buffer, .offset = 0, .range = vk.VK_WHOLE_SIZE };

        var write = std.mem.zeroes(vk.VkWriteDescriptorSet);
        write.sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        write.dstSet = self.descriptor_sets[f];
        write.dstBinding = 0;
        write.descriptorCount = 12;
        write.descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
        write.pBufferInfo = &info[0];
        self.vk_ctx.vkUpdateDescriptorSets.?(self.dev, 1, &write, 0, null);
    }

    fn updateInferenceDescriptors(self: *VulkanEngine, l: u32) void {
        var info = [_]vk.VkDescriptorBufferInfo{ std.mem.zeroes(vk.VkDescriptorBufferInfo) } ** 12;
        info[0] = .{ .buffer = self.matrix_buffer, .offset = 0, .range = vk.VK_WHOLE_SIZE };
        info[1] = .{ .buffer = self.inf_rotor_buffers[l], .offset = 0, .range = vk.VK_WHOLE_SIZE };
        info[2] = .{ .buffer = self.char_buffers[0], .offset = 0, .range = vk.VK_WHOLE_SIZE };
        info[3] = .{ .buffer = self.index_buffers[0], .offset = 0, .range = vk.VK_WHOLE_SIZE };
        info[4] = .{ .buffer = self.tag_buffer, .offset = 0, .range = vk.VK_WHOLE_SIZE };
        info[5] = .{ .buffer = self.lattice_buffer, .offset = 0, .range = vk.VK_WHOLE_SIZE };
        info[6] = .{ .buffer = self.inf_energy_buffers[l], .offset = 0, .range = vk.VK_WHOLE_SIZE };
        info[7] = .{ .buffer = self.sigil_buffer, .offset = 0, .range = vk.VK_WHOLE_SIZE };
        info[8] = .{ .buffer = self.diag_buffer, .offset = 0, .range = vk.VK_WHOLE_SIZE };
        info[9] = .{ .buffer = self.panopticon_buffer, .offset = 0, .range = vk.VK_WHOLE_SIZE };
        info[10] = .{ .buffer = self.inf_config_buffers[l], .offset = 0, .range = vk.VK_WHOLE_SIZE };
        info[11] = .{ .buffer = self.lock_mask_buffer, .offset = 0, .range = vk.VK_WHOLE_SIZE };

        var write = std.mem.zeroes(vk.VkWriteDescriptorSet);
        write.sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        write.dstSet = self.inf_descriptor_sets[l];
        write.dstBinding = 0;
        write.descriptorCount = 12;
        write.descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
        write.pBufferInfo = &info[0];
        self.vk_ctx.vkUpdateDescriptorSets.?(self.dev, 1, &write, 0, null);
    }

    fn setupDescriptorPool(self: *VulkanEngine) !void {
        var poolSize = std.mem.zeroes(vk.VkDescriptorPoolSize);
        poolSize.type = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
        poolSize.descriptorCount = 12 * (FRAME_COUNT + INF_LANE_COUNT);
        var dpCreateInfo = std.mem.zeroes(vk.VkDescriptorPoolCreateInfo);
        dpCreateInfo.sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
        dpCreateInfo.poolSizeCount = 1;
        dpCreateInfo.pPoolSizes = &poolSize;
        dpCreateInfo.maxSets = FRAME_COUNT + INF_LANE_COUNT;
        try check(self.vk_ctx.vkCreateDescriptorPool.?(self.dev, &dpCreateInfo, null, &self.descriptor_pool));

        const dsls = try self.allocator.alloc(vk.VkDescriptorSetLayout, FRAME_COUNT + INF_LANE_COUNT);
        defer self.allocator.free(dsls);
        for (dsls) |*d| d.* = self.descriptor_set_layout;

        var dsAllocInfo = std.mem.zeroes(vk.VkDescriptorSetAllocateInfo);
        dsAllocInfo.sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
        dsAllocInfo.descriptorPool = self.descriptor_pool;
        dsAllocInfo.descriptorSetCount = FRAME_COUNT + INF_LANE_COUNT;
        dsAllocInfo.pSetLayouts = dsls.ptr;

        var all_sets = try self.allocator.alloc(vk.VkDescriptorSet, FRAME_COUNT + INF_LANE_COUNT);
        defer self.allocator.free(all_sets);
        try check(self.vk_ctx.vkAllocateDescriptorSets.?(self.dev, &dsAllocInfo, all_sets.ptr));
        
        @memcpy(self.descriptor_sets[0..FRAME_COUNT], all_sets[0..FRAME_COUNT]);
        @memcpy(self.inf_descriptor_sets[0..INF_LANE_COUNT], all_sets[FRAME_COUNT .. FRAME_COUNT + INF_LANE_COUNT]);

        for (0..FRAME_COUNT) |i| self.updateDescriptorSets(@intCast(i));
        for (0..INF_LANE_COUNT) |i| self.updateInferenceDescriptors(@intCast(i));
    }

    fn createCommandSlot(self: *VulkanEngine, qf: u32, pool: *vk.VkCommandPool, buffer: *vk.VkCommandBuffer, fence: *vk.VkFence) !void {
        var cpCreateInfo = std.mem.zeroes(vk.VkCommandPoolCreateInfo);
        cpCreateInfo.sType = vk.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
        cpCreateInfo.queueFamilyIndex = qf;
        cpCreateInfo.flags = vk.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
        try check(self.vk_ctx.vkCreateCommandPool.?(self.dev, &cpCreateInfo, null, pool));

        var cbAllocInfo = std.mem.zeroes(vk.VkCommandBufferAllocateInfo);
        cbAllocInfo.sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
        cbAllocInfo.commandPool = pool.*;
        cbAllocInfo.level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        cbAllocInfo.commandBufferCount = 1;
        try check(self.vk_ctx.vkAllocateCommandBuffers.?(self.dev, &cbAllocInfo, buffer));

        var fCreateInfo = std.mem.zeroes(vk.VkFenceCreateInfo);
        fCreateInfo.sType = vk.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
        fCreateInfo.flags = vk.VK_FENCE_CREATE_SIGNALED_BIT;
        try check(self.vk_ctx.vkCreateFence.?(self.dev, &fCreateInfo, null, fence));
    }

    fn setupCommandInfrastructure(self: *VulkanEngine) !void {
        for (0..FRAME_COUNT) |i| {
            try self.createCommandSlot(self.queue_family, &self.command_pools[i], &self.command_buffers[i], &self.fences[i]);
        }
        for (0..INF_LANE_COUNT) |i| {
            try self.createCommandSlot(self.queue_family, &self.inf_command_pools[i], &self.inf_command_buffers[i], &self.inf_fences[i]);
        }

        if (self.has_dedicated_transfer) {
            var tPoolInfo = std.mem.zeroes(vk.VkCommandPoolCreateInfo);
            tPoolInfo.sType = vk.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
            tPoolInfo.queueFamilyIndex = self.transfer_queue_family;
            tPoolInfo.flags = vk.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
            try check(self.vk_ctx.vkCreateCommandPool.?(self.dev, &tPoolInfo, null, &self.transfer_pool));

            var tAllocInfo = std.mem.zeroes(vk.VkCommandBufferAllocateInfo);
            tAllocInfo.sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
            tAllocInfo.commandPool = self.transfer_pool;
            tAllocInfo.level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
            tAllocInfo.commandBufferCount = 1;

            for (0..FRAME_COUNT) |i| {
                try check(self.vk_ctx.vkAllocateCommandBuffers.?(self.dev, &tAllocInfo, &self.transfer_buffers[i]));
                var tfCreateInfo = std.mem.zeroes(vk.VkFenceCreateInfo);
                tfCreateInfo.sType = vk.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
                tfCreateInfo.flags = vk.VK_FENCE_CREATE_SIGNALED_BIT;
                try check(self.vk_ctx.vkCreateFence.?(self.dev, &tfCreateInfo, null, &self.transfer_fences[i]));
                var tsCreateInfo = std.mem.zeroes(vk.VkSemaphoreCreateInfo);
                tsCreateInfo.sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
                try check(self.vk_ctx.vkCreateSemaphore.?(self.dev, &tsCreateInfo, null, &self.transfer_semaphores[i]));
            }
        }

        var timeline_info = std.mem.zeroes(vk.VkSemaphoreTypeCreateInfo);
        timeline_info.sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO;
        timeline_info.semaphoreType = vk.VK_SEMAPHORE_TYPE_TIMELINE;
        var sCreateInfo = std.mem.zeroes(vk.VkSemaphoreCreateInfo);
        sCreateInfo.sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
        sCreateInfo.pNext = &timeline_info;
        try check(self.vk_ctx.vkCreateSemaphore.?(self.dev, &sCreateInfo, null, &self.timeline_semaphore));
    }

    fn initCommon(self: *VulkanEngine) !*VulkanEngine {
        try self.detectHardware();
        try self.setupLogicalDevice();
        try self.allocateBuffers();
        try self.setupPipelines();
        try self.setupDescriptorPool();
        try self.setupCommandInfrastructure();

        self.vk_ctx.vkGetDeviceQueue.?(self.dev, self.queue_family, 0, &self.queue);
        return self;
    }

    fn destroyBuffer(self: *const VulkanEngine, buffer: *vk.VkBuffer, memory: *vk.VkDeviceMemory, mapped_ptr: ?*anyopaque) void {
        if (buffer.* == null) return;
        if (mapped_ptr != null) {
            self.vk_ctx.vkUnmapMemory.?(self.dev, memory.*);
        }
        self.vk_ctx.vkDestroyBuffer.?(self.dev, buffer.*, null);
        self.vk_ctx.vkFreeMemory.?(self.dev, memory.*, null);
        buffer.* = null;
        memory.* = null;
    }

    pub fn deinit(self: *VulkanEngine) void {
        self.allocator.free(self.result_buffer);

        waitForGpuWorkersDrained(self);
        waitForAllHardwareInterruptsWithTimeout(self, SHUTDOWN_FENCE_TIMEOUT_NS) catch |err| {
            sys.print("[WARN] Final hardware drain before deinit failed: {any}\n", .{err});
        };
        for (0..INF_LANE_COUNT) |i| {
            self.waitForInferenceInterrupt(i) catch |err| {
                sys.print("[WARN] Final inference drain before deinit failed on lane {d}: {any}\n", .{ i, err });
            };
        }
        if (self.dev != null and self.vk_ctx.vkDeviceWaitIdle != null) {
            const idle_res = self.vk_ctx.vkDeviceWaitIdle.?(self.dev);
            if (idle_res != vk.VK_SUCCESS) {
                sys.print("[WARN] vkDeviceWaitIdle failed during deinit: {d}\n", .{idle_res});
            }
        }

        if (self.has_dedicated_transfer) {
            for (0..FRAME_COUNT) |i| {
                if (self.transfer_fences[i] != null) self.vk_ctx.vkDestroyFence.?(self.dev, self.transfer_fences[i], null);
                if (self.transfer_semaphores[i] != null) self.vk_ctx.vkDestroySemaphore.?(self.dev, self.transfer_semaphores[i], null);
            }
            if (self.transfer_pool != null) self.vk_ctx.vkDestroyCommandPool.?(self.dev, self.transfer_pool, null);
        }

        for (0..FRAME_COUNT) |i| {
            if (self.fences[i] != null) self.vk_ctx.vkDestroyFence.?(self.dev, self.fences[i], null);
            if (self.command_pools[i] != null) self.vk_ctx.vkDestroyCommandPool.?(self.dev, self.command_pools[i], null);

            self.destroyBuffer(&self.rotor_buffers[i], &self.rotor_memories[i], self.mapped_rotors[i]);
            self.destroyBuffer(&self.char_buffers[i], &self.char_memories[i], self.mapped_chars[i]);
            self.destroyBuffer(&self.index_buffers[i], &self.index_memories[i], self.mapped_index[i]);
            self.destroyBuffer(&self.energy_buffers[i], &self.energy_memories[i], self.mapped_energy[i]);
            self.destroyBuffer(&self.config_buffers[i], &self.config_memories[i], self.mapped_config[i]);
        }

        for (0..INF_LANE_COUNT) |i| {
            if (self.inf_fences[i] != null) self.vk_ctx.vkDestroyFence.?(self.dev, self.inf_fences[i], null);
            if (self.inf_command_pools[i] != null) self.vk_ctx.vkDestroyCommandPool.?(self.dev, self.inf_command_pools[i], null);
            self.destroyBuffer(&self.inf_rotor_buffers[i], &self.inf_rotor_memories[i], self.inf_mapped_rotors[i]);
            self.destroyBuffer(&self.inf_energy_buffers[i], &self.inf_energy_memories[i], self.inf_mapped_energy[i]);
            self.destroyBuffer(&self.inf_config_buffers[i], &self.inf_config_memories[i], self.inf_mapped_config[i]);
        }

        if (self.descriptor_pool != null) self.vk_ctx.vkDestroyDescriptorPool.?(self.dev, self.descriptor_pool, null);
        
        const pipelines = [_]*vk.VkPipeline{ &self.etch_pipeline, &self.prune_pipeline, &self.lookahead_pipeline, &self.compute_pipeline, &self.lattice_pipeline };
        for (pipelines) |p| if (p.* != null) self.vk_ctx.vkDestroyPipeline.?(self.dev, p.*, null);

        if (self.pipeline_layout != null) self.vk_ctx.vkDestroyPipelineLayout.?(self.dev, self.pipeline_layout, null);
        if (self.descriptor_set_layout != null) self.vk_ctx.vkDestroyDescriptorSetLayout.?(self.dev, self.descriptor_set_layout, null);
        if (self.timeline_semaphore != null) self.vk_ctx.vkDestroySemaphore.?(self.dev, self.timeline_semaphore, null);

        self.destroyBuffer(&self.sigil_buffer, &self.sigil_memory, self.mapped_sigil);
        self.destroyBuffer(&self.diag_buffer, &self.diag_memory, self.mapped_diag);
        self.destroyBuffer(&self.lock_mask_buffer, &self.lock_mask_memory, self.mapped_lock_mask);
        self.destroyBuffer(&self.panopticon_buffer, &self.panopticon_memory, self.mapped_edges);
        self.destroyBuffer(&self.lattice_buffer, &self.lattice_memory, self.mapped_lattice);
        self.destroyBuffer(&self.tag_buffer, &self.tag_memory, self.mapped_tags);
        self.destroyBuffer(&self.matrix_buffer, &self.matrix_memory, self.mapped_matrix);

        if (self.dev != null) self.vk_ctx.vkDestroyDevice.?(self.dev, null);
        if (self.debug_messenger != null and self.vk_ctx.vkDestroyDebugUtilsMessengerEXT != null) {
            self.vk_ctx.vkDestroyDebugUtilsMessengerEXT.?(self.instance, self.debug_messenger, null);
        }
        if (self.instance != null) self.vk_ctx.vkDestroyInstance.?(self.instance, null);
    }

    pub fn dispatchBatch(self: *VulkanEngine, batch_size: u32) ![]u32 {
        beginGpuSubmit(self);
        defer endGpuSubmit(self);

        self.dispatch_mutex.lock();
        defer self.dispatch_mutex.unlock();

        const f = try self.acquireFrameSlot();

        var beginInfo = std.mem.zeroes(vk.VkCommandBufferBeginInfo);
        beginInfo.sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        check(self.vk_ctx.vkBeginCommandBuffer.?(self.command_buffers[f], &beginInfo)) catch |err| {
            sys.print("[VULKAN] Error beginning command buffer: {any}\n", .{err});
            return self.result_buffer[0..0];
        };

        self.vk_ctx.vkCmdBindPipeline.?(self.command_buffers[f], vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.compute_pipeline);
        self.vk_ctx.vkCmdBindDescriptorSets.?(self.command_buffers[f], vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline_layout, 0, 1, &self.descriptor_sets[f], 0, null);
        const pc = [_]u32{ batch_size, 0, self.matrix_slots - 1, self.lattice_quarter };

        self.mapped_config[f].?.* = .{ .rotor_stride = ROTOR_STRIDE, .rotor_offset = 16, .batch_size = batch_size };
        self.vk_ctx.vkCmdPushConstants.?(self.command_buffers[f], self.pipeline_layout, vk.VK_SHADER_STAGE_COMPUTE_BIT, 0, 16, &pc);

        const wg_size = @min(1024, self.max_workgroup_invocations);
        self.vk_ctx.vkCmdDispatch.?(self.command_buffers[f], (batch_size + (wg_size - 1)) / wg_size, 1, 1);
        check(self.vk_ctx.vkEndCommandBuffer.?(self.command_buffers[f])) catch |err| {
            sys.print("[VULKAN] Error ending command buffer: {any}\n", .{err});
            return self.result_buffer[0..0];
        };

        var submitInfo = std.mem.zeroes(vk.VkSubmitInfo);
        submitInfo.sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submitInfo.commandBufferCount = 1;
        submitInfo.pCommandBuffers = &self.command_buffers[f];
        check(self.vk_ctx.vkQueueSubmit.?(self.queue, 1, &submitInfo, self.fences[f])) catch |err| {
            sys.print("[VULKAN] Error submitting queue: {any}\n", .{err});
            return self.result_buffer[0..0];
        };
        self.advanceFrameSlot();
        try self.waitForHardwareInterrupt(f);

        ghostCopy(u32, self.result_buffer[0..batch_size], self.mapped_energy[f].?[0..batch_size]);
        return self.result_buffer[0..batch_size];
    }

    pub fn dispatchResonance(self: *VulkanEngine, lexical_rotor: u64, semantic_rotor: u64) ![]u32 {
        beginGpuSubmit(self);
        defer endGpuSubmit(self);

        self.dispatch_mutex.lock();
        defer self.dispatch_mutex.unlock();

        const f = try self.acquireFrameSlot();

        self.mapped_rotors[f].?[0] = lexical_rotor;
        self.mapped_rotors[f].?[1] = semantic_rotor;
        self.mapped_config[f].?.* = .{ .rotor_stride = 2, .rotor_offset = 0, .batch_size = 1 };

        var beginInfo = std.mem.zeroes(vk.VkCommandBufferBeginInfo);
        beginInfo.sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        check(self.vk_ctx.vkBeginCommandBuffer.?(self.command_buffers[f], &beginInfo)) catch |err| {
            sys.print("[VULKAN] Error beginning command buffer in dispatchResonance: {any}\n", .{err});
            return self.result_buffer[0..0];
        };

        self.vk_ctx.vkCmdBindPipeline.?(self.command_buffers[f], vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.compute_pipeline);
        self.vk_ctx.vkCmdBindDescriptorSets.?(self.command_buffers[f], vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline_layout, 0, 1, &self.descriptor_sets[f], 0, null);
        const pc = [_]u32{ 1, 1, self.matrix_slots - 1, self.lattice_quarter };
        self.vk_ctx.vkCmdPushConstants.?(self.command_buffers[f], self.pipeline_layout, vk.VK_SHADER_STAGE_COMPUTE_BIT, 0, 16, &pc);

        const wg_size = @min(1024, self.max_workgroup_invocations);
        self.vk_ctx.vkCmdDispatch.?(self.command_buffers[f], (256 + (wg_size - 1)) / wg_size, 1, 1);
        check(self.vk_ctx.vkEndCommandBuffer.?(self.command_buffers[f])) catch |err| {
            sys.print("[VULKAN] Error ending command buffer in dispatchResonance: {any}\n", .{err});
            return self.result_buffer[0..0];
        };

        var submitInfo = std.mem.zeroes(vk.VkSubmitInfo);
        submitInfo.sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submitInfo.commandBufferCount = 1;
        submitInfo.pCommandBuffers = &self.command_buffers[f];
        check(self.vk_ctx.vkQueueSubmit.?(self.queue, 1, &submitInfo, self.fences[f])) catch |err| {
            sys.print("[VULKAN] Error submitting queue in dispatchResonance: {any}\n", .{err});
            return self.result_buffer[0..0];
        };
        self.advanceFrameSlot();
        try self.waitForHardwareInterrupt(f);

        ghostCopy(u32, self.result_buffer[0..256], self.mapped_energy[f].?[0..256]);
        return self.result_buffer[0..256];
    }

    pub fn dispatchResonanceBatched(self: *VulkanEngine, num_lanes: u32, rotor_pairs: []const u64) ![]u32 {
        beginGpuSubmit(self);
        defer endGpuSubmit(self);

        self.dispatch_mutex.lock();
        defer self.dispatch_mutex.unlock();

        const actual: u32 = @min(num_lanes, @min(@as(u32, INF_LANE_COUNT), @as(u32, @intCast(self.result_buffer.len / 256))));
        const wg_size = @min(1024, self.max_workgroup_invocations);

        for (0..actual) |lane| {
            try self.recycleInferenceFence(lane);

            self.inf_mapped_rotors[lane].?[0] = rotor_pairs[lane * 2];
            self.inf_mapped_rotors[lane].?[1] = rotor_pairs[lane * 2 + 1];
            self.inf_mapped_config[lane].?.* = .{ .rotor_stride = 2, .rotor_offset = 0, .batch_size = 1 };

            var beginInfo = std.mem.zeroes(vk.VkCommandBufferBeginInfo);
            beginInfo.sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
            try check(self.vk_ctx.vkBeginCommandBuffer.?(self.inf_command_buffers[lane], &beginInfo));

            self.vk_ctx.vkCmdBindPipeline.?(self.inf_command_buffers[lane], vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.compute_pipeline);
            self.vk_ctx.vkCmdBindDescriptorSets.?(self.inf_command_buffers[lane], vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline_layout, 0, 1, &self.inf_descriptor_sets[lane], 0, null);
            const pc = [_]u32{ 1, 1, self.matrix_slots - 1, self.lattice_quarter };
            self.vk_ctx.vkCmdPushConstants.?(self.inf_command_buffers[lane], self.pipeline_layout, vk.VK_SHADER_STAGE_COMPUTE_BIT, 0, 16, &pc);
            self.vk_ctx.vkCmdDispatch.?(self.inf_command_buffers[lane], (256 + (wg_size - 1)) / wg_size, 1, 1);
            try check(self.vk_ctx.vkEndCommandBuffer.?(self.inf_command_buffers[lane]));

            var submitInfo = std.mem.zeroes(vk.VkSubmitInfo);
            submitInfo.sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO;
            submitInfo.commandBufferCount = 1;
            submitInfo.pCommandBuffers = &self.inf_command_buffers[lane];
            const submit_res = self.vk_ctx.vkQueueSubmit.?(self.queues[lane % self.num_queues], 1, &submitInfo, self.inf_fences[lane]);
            if (submit_res != vk.VK_SUCCESS) {
                sys.print("[FATAL] dispatchResonanceBatched vkQueueSubmit failed on lane {d}: {d}\n", .{ lane, submit_res });
                return error.QueueSubmitFailed;
            }
        }

        for (0..actual) |lane| try self.waitForInferenceInterrupt(lane);
        for (0..actual) |lane| ghostCopy(u32, self.result_buffer[lane * 256 .. (lane + 1) * 256], self.inf_mapped_energy[lane].?[0..256]);

        return self.result_buffer[0 .. actual * 256];
    }

    pub fn dispatchEtch(self: *VulkanEngine, batch_size: u32) !void {
        beginGpuSubmit(self);
        defer endGpuSubmit(self);

        self.dispatch_mutex.lock();
        defer self.dispatch_mutex.unlock();
        self.refreshLockMaskFromControl();
        
        const f = try self.acquireFrameSlot();

        var beginInfo = std.mem.zeroes(vk.VkCommandBufferBeginInfo);
        beginInfo.sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        try check(self.vk_ctx.vkBeginCommandBuffer.?(self.command_buffers[f], &beginInfo));

        self.vk_ctx.vkCmdBindPipeline.?(self.command_buffers[f], vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.etch_pipeline);
        self.vk_ctx.vkCmdBindDescriptorSets.?(self.command_buffers[f], vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline_layout, 0, 1, &self.descriptor_sets[f], 0, null);
        const pc = [_]u32{ batch_size, 1, self.matrix_slots - 1, self.lattice_quarter };

        self.mapped_config[f].?.* = .{ .rotor_stride = ROTOR_STRIDE, .rotor_offset = 16, .batch_size = batch_size };
        self.vk_ctx.vkCmdPushConstants.?(self.command_buffers[f], self.pipeline_layout, vk.VK_SHADER_STAGE_COMPUTE_BIT, 0, 16, &pc);

        const wg_size = @min(1024, self.max_workgroup_invocations);
        self.vk_ctx.vkCmdDispatch.?(self.command_buffers[f], (batch_size + (wg_size - 1)) / wg_size, 1, 1);
        try check(self.vk_ctx.vkEndCommandBuffer.?(self.command_buffers[f]));

        var submitInfo = std.mem.zeroes(vk.VkSubmitInfo);
        submitInfo.sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submitInfo.commandBufferCount = 1;
        submitInfo.pCommandBuffers = &self.command_buffers[f];
        try check(self.vk_ctx.vkQueueSubmit.?(self.queue, 1, &submitInfo, self.fences[f]));
        self.advanceFrameSlot();
    }

    pub fn dispatchMergedEtch(self: *VulkanEngine, batch_size: u32, num_streams: u32) !void {
        beginGpuSubmit(self);
        defer endGpuSubmit(self);

        self.dispatch_mutex.lock();
        defer self.dispatch_mutex.unlock();
        self.refreshLockMaskFromControl();

        const f = try self.acquireFrameSlot();

        var beginInfo = std.mem.zeroes(vk.VkCommandBufferBeginInfo);
        beginInfo.sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        try check(self.vk_ctx.vkBeginCommandBuffer.?(self.command_buffers[f], &beginInfo));

        const wg_size = @min(1024, self.max_workgroup_invocations);
        const num_workgroups = (batch_size + (wg_size - 1)) / wg_size;
        const pc = [_]u32{ batch_size, num_streams, self.matrix_slots - 1, self.lattice_quarter };

        self.mapped_config[f].?.* = .{ .rotor_stride = ROTOR_STRIDE, .rotor_offset = 16, .batch_size = batch_size };

        self.vk_ctx.vkCmdBindPipeline.?(self.command_buffers[f], vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.lattice_pipeline);
        self.vk_ctx.vkCmdBindDescriptorSets.?(self.command_buffers[f], vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline_layout, 0, 1, &self.descriptor_sets[f], 0, null);
        self.vk_ctx.vkCmdPushConstants.?(self.command_buffers[f], self.pipeline_layout, vk.VK_SHADER_STAGE_COMPUTE_BIT, 0, 16, &pc);
        self.vk_ctx.vkCmdDispatch.?(self.command_buffers[f], num_workgroups, 1, 1);

        var barrier = std.mem.zeroes(vk.VkMemoryBarrier);
        barrier.sType = vk.VK_STRUCTURE_TYPE_MEMORY_BARRIER;
        barrier.srcAccessMask = vk.VK_ACCESS_SHADER_WRITE_BIT;
        barrier.dstAccessMask = vk.VK_ACCESS_SHADER_READ_BIT | vk.VK_ACCESS_SHADER_WRITE_BIT;
        self.vk_ctx.vkCmdPipelineBarrier.?(self.command_buffers[f], vk.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, vk.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0, 1, &barrier, 0, null, 0, null);

        self.vk_ctx.vkCmdBindPipeline.?(self.command_buffers[f], vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.etch_pipeline);
        self.vk_ctx.vkCmdPushConstants.?(self.command_buffers[f], self.pipeline_layout, vk.VK_SHADER_STAGE_COMPUTE_BIT, 0, 16, &pc);
        self.vk_ctx.vkCmdDispatch.?(self.command_buffers[f], num_workgroups, 1, 1);

        try check(self.vk_ctx.vkEndCommandBuffer.?(self.command_buffers[f]));

        var submitInfo = std.mem.zeroes(vk.VkSubmitInfo);
        submitInfo.sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submitInfo.commandBufferCount = 1;
        submitInfo.pCommandBuffers = &self.command_buffers[f];
        try check(self.vk_ctx.vkQueueSubmit.?(self.queue, 1, &submitInfo, self.fences[f]));
        self.advanceFrameSlot();
    }

    pub fn dispatchPrune(self: *VulkanEngine) !void {
        beginGpuSubmit(self);
        defer endGpuSubmit(self);

        self.dispatch_mutex.lock();
        defer self.dispatch_mutex.unlock();

        const f = try self.acquireFrameSlot();

        var beginInfo = std.mem.zeroes(vk.VkCommandBufferBeginInfo);
        beginInfo.sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        try check(self.vk_ctx.vkBeginCommandBuffer.?(self.command_buffers[f], &beginInfo));

        self.vk_ctx.vkCmdBindPipeline.?(self.command_buffers[f], vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.prune_pipeline);
        self.vk_ctx.vkCmdBindDescriptorSets.?(self.command_buffers[f], vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline_layout, 0, 1, &self.descriptor_sets[f], 0, null);
        const lattice_uints = @as(u32, @intCast(self.gpu_lattice_size / 4));
        const pc = [_]u32{ lattice_uints, 0, self.matrix_slots - 1, self.lattice_quarter };
        self.vk_ctx.vkCmdPushConstants.?(self.command_buffers[f], self.pipeline_layout, vk.VK_SHADER_STAGE_COMPUTE_BIT, 0, 16, &pc);

        const wg_size = @min(1024, self.max_workgroup_invocations);
        self.vk_ctx.vkCmdDispatch.?(self.command_buffers[f], (lattice_uints + (wg_size - 1)) / wg_size, 1, 1);
        try check(self.vk_ctx.vkEndCommandBuffer.?(self.command_buffers[f]));

        var submitInfo = std.mem.zeroes(vk.VkSubmitInfo);
        submitInfo.sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submitInfo.commandBufferCount = 1;
        submitInfo.pCommandBuffers = &self.command_buffers[f];
        try check(self.vk_ctx.vkQueueSubmit.?(self.queue, 1, &submitInfo, self.fences[f]));
        self.advanceFrameSlot();
    }

    pub fn dispatchRecursiveLookahead(self: *VulkanEngine, num_rotors: u32, depth: u32) !u64 {
        beginGpuSubmit(self);
        defer endGpuSubmit(self);

        self.dispatch_mutex.lock();
        defer self.dispatch_mutex.unlock();

        const f = try self.acquireFrameSlot();

        var beginInfo = std.mem.zeroes(vk.VkCommandBufferBeginInfo);
        beginInfo.sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        try check(self.vk_ctx.vkBeginCommandBuffer.?(self.command_buffers[f], &beginInfo));

        self.vk_ctx.vkCmdBindPipeline.?(self.command_buffers[f], vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.lookahead_pipeline);
        self.vk_ctx.vkCmdBindDescriptorSets.?(self.command_buffers[f], vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline_layout, 0, 1, &self.descriptor_sets[f], 0, null);
        const pc = [_]u32{ num_rotors, depth, self.matrix_slots - 1, self.lattice_quarter };

        self.mapped_config[f].?.* = .{ .rotor_stride = ROTOR_STRIDE, .rotor_offset = 16, .batch_size = num_rotors };
        self.vk_ctx.vkCmdPushConstants.?(self.command_buffers[f], self.pipeline_layout, vk.VK_SHADER_STAGE_COMPUTE_BIT, 0, 16, &pc);
        self.vk_ctx.vkCmdDispatch.?(self.command_buffers[f], num_rotors, 1, 1);
        try check(self.vk_ctx.vkEndCommandBuffer.?(self.command_buffers[f]));

        self.timeline_value += 1;
        const ticket = self.timeline_value;
        var timeline_submit = std.mem.zeroes(vk.VkTimelineSemaphoreSubmitInfo);
        timeline_submit.sType = vk.VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO;
        timeline_submit.signalSemaphoreValueCount = 1;
        timeline_submit.pSignalSemaphoreValues = &ticket;

        var submitInfo = std.mem.zeroes(vk.VkSubmitInfo);
        submitInfo.sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submitInfo.pNext = &timeline_submit;
        submitInfo.commandBufferCount = 1;
        submitInfo.pCommandBuffers = &self.command_buffers[f];
        submitInfo.signalSemaphoreCount = 1;
        submitInfo.pSignalSemaphores = &self.timeline_semaphore;

        try check(self.vk_ctx.vkQueueSubmit.?(self.queue, 1, &submitInfo, self.fences[f]));
        self.frame_generations[f] = ticket;
        const receipt = (ticket << 8) | @as(u64, f);
        self.advanceFrameSlot();
        return receipt;
    }

    pub fn collectLookaheadResults(self: *VulkanEngine, receipt: u64, num_rotors: u32) []u32 {
        const f: u32 = @intCast(receipt & 0xFF);
        const ticket = receipt >> 8;

        var waitInfo = std.mem.zeroes(vk.VkSemaphoreWaitInfo);
        waitInfo.sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO;
        waitInfo.semaphoreCount = 1;
        waitInfo.pSemaphores = &self.timeline_semaphore;
        waitInfo.pValues = &ticket;
        _ = self.vk_ctx.vkWaitSemaphores.?(self.dev, &waitInfo, std.math.maxInt(u64));

        if (self.frame_generations[f] != ticket) return self.result_buffer[0..0];
        ghostCopy(u32, self.result_buffer[0..num_rotors], self.mapped_energy[f].?[0..num_rotors]);
        return self.result_buffer[0..num_rotors];
    }

    pub fn getMatrixData(self: *VulkanEngine) []u32 {
        return self.mapped_matrix.?[0 .. self.matrix_slots * 1024];
    }

    pub fn getTagsData(self: *VulkanEngine) []u64 {
        return self.mapped_tags.?[0 .. self.matrix_slots];
    }

    pub fn getLatticeData(self: *VulkanEngine) []u16 {
        return self.mapped_lattice.?[0 .. self.gpu_lattice_size / @sizeOf(u16)];
    }

    pub fn bindHostState(self: *VulkanEngine, host_matrix: []u32, host_tags: []u64, host_lattice: []u16) void {
        self.host_matrix = host_matrix;
        self.host_tags = host_tags;
        self.host_lattice = host_lattice;

        if (self.mapped_matrix) |dst| {
            const len = @min(host_matrix.len, self.matrix_slots * 1024);
            @memcpy(dst[0..len], host_matrix[0..len]);
        }
        if (self.mapped_tags) |dst| {
            const len = @min(host_tags.len, self.matrix_slots);
            @memcpy(dst[0..len], host_tags[0..len]);
        }
        if (self.mapped_lattice) |dst| {
            const len = @min(host_lattice.len, self.gpu_lattice_size / @sizeOf(u16));
            @memcpy(dst[0..len], host_lattice[0..len]);
        }
        self.refreshLockMaskFromControl();
    }

    fn refreshLockMaskFromControl(self: *VulkanEngine) void {
        const mask = self.mapped_lock_mask orelse return;
        @memset(std.mem.sliceAsBytes(mask[0..self.lock_mask_words]), 0);
        const control = sigil_runtime.getActiveControl() orelse return;
        control.fillLockedSlotMask(mask[0..self.lock_mask_words], self.matrix_slots);
    }

    pub fn etch(self: *VulkanEngine, total_batch: u32, num_streams: u32, rotors: []const u64, chars: []const u32, indices: []const u32) !void {
        beginGpuSubmit(self);
        defer endGpuSubmit(self);

        self.dispatch_mutex.lock();
        defer self.dispatch_mutex.unlock();

        self.refreshLockMaskFromControl();
        const f = try self.acquireFrameSlot();
        ghostCopy(u64, self.mapped_rotors[f].?[0..rotors.len], rotors);
        ghostCopy(u32, self.mapped_chars[f].?[0..chars.len], chars);
        ghostCopy(u32, self.mapped_index[f].?[0..indices.len], indices);

        var beginInfo = std.mem.zeroes(vk.VkCommandBufferBeginInfo);
        beginInfo.sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        try check(self.vk_ctx.vkBeginCommandBuffer.?(self.command_buffers[f], &beginInfo));

        const wg_size = @min(1024, self.max_workgroup_invocations);
        const num_workgroups = (total_batch + (wg_size - 1)) / wg_size;
        const pc = [_]u32{ total_batch, num_streams, self.matrix_slots - 1, self.lattice_quarter };

        self.mapped_config[f].?.* = .{ .rotor_stride = ROTOR_STRIDE, .rotor_offset = 16, .batch_size = total_batch };

        self.vk_ctx.vkCmdBindPipeline.?(self.command_buffers[f], vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.lattice_pipeline);
        self.vk_ctx.vkCmdBindDescriptorSets.?(self.command_buffers[f], vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline_layout, 0, 1, &self.descriptor_sets[f], 0, null);
        self.vk_ctx.vkCmdPushConstants.?(self.command_buffers[f], self.pipeline_layout, vk.VK_SHADER_STAGE_COMPUTE_BIT, 0, 16, &pc);
        self.vk_ctx.vkCmdDispatch.?(self.command_buffers[f], num_workgroups, 1, 1);

        var barrier = std.mem.zeroes(vk.VkMemoryBarrier);
        barrier.sType = vk.VK_STRUCTURE_TYPE_MEMORY_BARRIER;
        barrier.srcAccessMask = vk.VK_ACCESS_SHADER_WRITE_BIT;
        barrier.dstAccessMask = vk.VK_ACCESS_SHADER_READ_BIT | vk.VK_ACCESS_SHADER_WRITE_BIT;
        self.vk_ctx.vkCmdPipelineBarrier.?(self.command_buffers[f], vk.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, vk.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0, 1, &barrier, 0, null, 0, null);

        self.vk_ctx.vkCmdBindPipeline.?(self.command_buffers[f], vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.etch_pipeline);
        self.vk_ctx.vkCmdPushConstants.?(self.command_buffers[f], self.pipeline_layout, vk.VK_SHADER_STAGE_COMPUTE_BIT, 0, 16, &pc);
        self.vk_ctx.vkCmdDispatch.?(self.command_buffers[f], num_workgroups, 1, 1);

        try check(self.vk_ctx.vkEndCommandBuffer.?(self.command_buffers[f]));

        var submitInfo = std.mem.zeroes(vk.VkSubmitInfo);
        submitInfo.sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submitInfo.commandBufferCount = 1;
        submitInfo.pCommandBuffers = &self.command_buffers[f];
        try check(self.vk_ctx.vkQueueSubmit.?(self.queue, 1, &submitInfo, self.fences[f]));
        self.advanceFrameSlot();
    }

    fn transferLatticeToHostWithTimeout(self: *VulkanEngine, host_lattice: []u16, timeout_ns: u64) !void {
        const copy_bytes = @min(self.gpu_lattice_size, host_lattice.len * @sizeOf(u16));
        if (copy_bytes == 0) return;

        for (0..FRAME_COUNT) |i| try self.waitForHardwareInterruptWithTimeout(i, timeout_ns);

        var staging_buffer: vk.VkBuffer = null;
        var staging_memory: vk.VkDeviceMemory = null;
        const staging_ptr = try self.createBuffer(
            copy_bytes,
            vk.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
            vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            &staging_buffer,
            &staging_memory,
        ) orelse return error.VulkanError;
        defer self.destroyBuffer(&staging_buffer, &staging_memory, staging_ptr);

        const f = self.frame_idx;
        try self.recycleHardwareFenceWithTimeout(f, timeout_ns);

        var beginInfo = std.mem.zeroes(vk.VkCommandBufferBeginInfo);
        beginInfo.sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        beginInfo.flags = vk.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        try check(self.vk_ctx.vkBeginCommandBuffer.?(self.command_buffers[f], &beginInfo));

        var region = std.mem.zeroes(vk.VkBufferCopy);
        region.size = copy_bytes;
        self.vk_ctx.vkCmdCopyBuffer.?(self.command_buffers[f], self.lattice_buffer, staging_buffer, 1, &region);
        try check(self.vk_ctx.vkEndCommandBuffer.?(self.command_buffers[f]));

        var submitInfo = std.mem.zeroes(vk.VkSubmitInfo);
        submitInfo.sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submitInfo.commandBufferCount = 1;
        submitInfo.pCommandBuffers = &self.command_buffers[f];
        try check(self.vk_ctx.vkQueueSubmit.?(self.queue, 1, &submitInfo, self.fences[f]));
        try self.waitForHardwareInterruptWithTimeout(f, timeout_ns);

        const src: [*]const u16 = @ptrCast(@alignCast(staging_ptr));
        const word_count = copy_bytes / @sizeOf(u16);
        @memcpy(host_lattice[0..word_count], src[0..word_count]);
        self.frame_idx = (self.frame_idx + 1) % FRAME_COUNT;
    }

    pub fn transferLattice(self: *VulkanEngine) !void {
        const host_lattice = self.host_lattice orelse return error.HostLatticeNotBound;
        try self.transferLatticeToHostWithTimeout(host_lattice, FENCE_TIMEOUT_NS);
    }

    pub fn syncDeviceToHost(self: *VulkanEngine, host_matrix: []u32, host_tags: []u64, host_lattice: []u16) !void {
        waitForGpuWorkersDrained(self);
        try waitForAllHardwareInterruptsWithTimeout(self, SHUTDOWN_FENCE_TIMEOUT_NS);
        if (self.mapped_matrix) |src| {
            const len = @min(host_matrix.len, self.matrix_slots * 1024);
            @memcpy(host_matrix[0..len], src[0..len]);
        }
        if (self.mapped_tags) |src| {
            const len = @min(host_tags.len, self.matrix_slots);
            @memcpy(host_tags[0..len], src[0..len]);
        }
        self.host_matrix = host_matrix;
        self.host_tags = host_tags;
        self.host_lattice = host_lattice;
        try self.transferLatticeToHostWithTimeout(host_lattice, SHUTDOWN_FENCE_TIMEOUT_NS);
    }

    pub fn ensureSigilCapacity(self: *VulkanEngine, needed: usize) !void {
        if (needed <= self.sigil_capacity) return;
        const target = @min(needed, 128 * 1024 * 1024);
        const aligned = (target + 4095) & ~@as(usize, 4095);
        for (0..FRAME_COUNT) |i| try self.waitForHardwareInterrupt(i);
        self.destroyBuffer(&self.sigil_buffer, &self.sigil_memory, self.mapped_sigil);
        self.mapped_sigil = @ptrCast(@alignCast(try self.createBuffer(aligned, vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | vk.VK_BUFFER_USAGE_TRANSFER_DST_BIT, self.matrix_flags, &self.sigil_buffer, &self.sigil_memory) orelse return error.VulkanError));
        self.sigil_capacity = aligned;
        for (0..FRAME_COUNT) |i| self.updateDescriptorSets(@intCast(i));
    }

    pub fn setTier(self: *VulkanEngine, tier_val: u32) void {
        const enum_tier = @as(OperationalTier, @enumFromInt(tier_val));
        self.tier = enum_tier;
        sys.print("[VULKAN] Operational tier set: {s}\n", .{ @tagName(enum_tier) });
    }

    pub fn warmRestart(self: *VulkanEngine) !void {
        const h_matrix = self.host_matrix; const h_tags = self.host_tags; const h_lattice = self.host_lattice;
        const target_device = self.device_index; const alloc = self.allocator; const io = self.io;
        self.deinit();
        self.* = try VulkanEngine.initForDevice(alloc, target_device, io);
        if (h_matrix != null and h_tags != null and h_lattice != null) {
            self.bindHostState(h_matrix.?, h_tags.?, h_lattice.?);
        } else {
            self.host_matrix = h_matrix;
            self.host_tags = h_tags;
            self.host_lattice = h_lattice;
        }
        sys.print("[VULKAN] Warm Restart Complete.\n", .{});
    }

    /// Sovereign Hardware Sleep: Halts the CPU thread at 0% utilization until
    /// the GPU PCIe interrupt fires, signaling the frame/batch is complete.
    /// This wait does not reset the fence; callers that plan to reuse the slot
    /// must explicitly recycle it first.
    fn waitForHardwareInterruptWithTimeout(self: *VulkanEngine, f_idx: usize, timeout_ns: u64) !void {
        const wait_res = self.vk_ctx.vkWaitForFences.?(
            self.dev,
            1,
            &self.fences[f_idx],
            vk.VK_TRUE,
            timeout_ns,
        );
        
        if (wait_res != vk.VK_SUCCESS) {
            sys.print("[FATAL] Vulkan Driver failed to sync PCIe interrupt on frame {d}: {d}\n", .{ f_idx, wait_res });
            return error.HardwareSyncFailed;
        }
    }

    pub fn waitForHardwareInterrupt(self: *VulkanEngine, f_idx: usize) !void {
        try self.waitForHardwareInterruptWithTimeout(f_idx, FENCE_TIMEOUT_NS);
    }

    fn recycleHardwareFence(self: *VulkanEngine, f_idx: usize) !void {
        try self.waitForHardwareInterrupt(f_idx);
        const reset_res = self.vk_ctx.vkResetFences.?(self.dev, 1, &self.fences[f_idx]);
        if (reset_res != vk.VK_SUCCESS) return error.FenceResetFailed;
    }

    fn recycleHardwareFenceWithTimeout(self: *VulkanEngine, f_idx: usize, timeout_ns: u64) !void {
        try self.waitForHardwareInterruptWithTimeout(f_idx, timeout_ns);
        const reset_res = self.vk_ctx.vkResetFences.?(self.dev, 1, &self.fences[f_idx]);
        if (reset_res != vk.VK_SUCCESS) return error.FenceResetFailed;
    }

    /// Inference-specific fence wait. Like the frame wait above, this leaves the
    /// fence signaled so post-submit waits do not wipe the slot state.
    pub fn waitForInferenceInterrupt(self: *VulkanEngine, lane_idx: usize) !void {
        const wait_res = self.vk_ctx.vkWaitForFences.?(self.dev, 1, &self.inf_fences[lane_idx], vk.VK_TRUE, FENCE_TIMEOUT_NS);
        if (wait_res != vk.VK_SUCCESS) {
            sys.print("[FATAL] Inference fence wait failed on lane {d}: {d}\n", .{ lane_idx, wait_res });
            return error.HardwareSyncFailed;
        }
    }

    fn recycleInferenceFence(self: *VulkanEngine, lane_idx: usize) !void {
        try self.waitForInferenceInterrupt(lane_idx);
        const reset_res = self.vk_ctx.vkResetFences.?(self.dev, 1, &self.inf_fences[lane_idx]);
        if (reset_res != vk.VK_SUCCESS) return error.FenceResetFailed;
    }

    fn acquireFrameSlot(self: *VulkanEngine) !usize {
        const f: usize = self.frame_idx;
        try self.recycleHardwareFence(f);
        return f;
    }

    fn advanceFrameSlot(self: *VulkanEngine) void {
        self.frame_idx = (self.frame_idx + 1) % FRAME_COUNT;
    }
};

pub const MultiGPU = struct {
    allocator: std.mem.Allocator,
    engines: []VulkanEngine,
    primary: *VulkanEngine,
    engine_count: u32,
    total_score: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !MultiGPU {
        var ctx = try vl.VulkanCtx.load();
        const boot = try createInstance(&ctx, allocator, "Ghost-Sovereign-Fleet", "Ghost-VSA");
        const instance: vk.VkInstance = boot.instance;
        ctx.loadInstance(instance);
        defer ctx.vkDestroyInstance.?(instance, null);

        var pdevCount: u32 = 0;
        try check(ctx.vkEnumeratePhysicalDevices.?(instance, &pdevCount, null));
        const pdevs = try allocator.alloc(vk.VkPhysicalDevice, pdevCount);
        defer allocator.free(pdevs);
        try check(ctx.vkEnumeratePhysicalDevices.?(instance, &pdevCount, pdevs.ptr));

        var engines = try allocator.alloc(VulkanEngine, pdevCount);
        for (0..pdevCount) |i| engines[i] = try VulkanEngine.initForDevice(allocator, @intCast(i), io);
        return MultiGPU{ .allocator = allocator, .engines = engines, .primary = &engines[0], .engine_count = pdevCount };
    }

    pub fn deinit(self: *MultiGPU) void {
        for (self.engines) |*e| e.deinit();
        self.allocator.free(self.engines);
    }
};

var global_fleet: ?MultiGPU = null;
var global_instance: ?*VulkanEngine = null;
threadlocal var thread_engine: ?*VulkanEngine = null;

pub fn setThreadEngine(e: ?*VulkanEngine) void { thread_engine = e; }
pub fn getEngine() ?*VulkanEngine { return thread_engine orelse global_instance; }
pub fn getFleet() ?*MultiGPU {
    return if (global_fleet) |*fleet| fleet else null;
}

pub fn initRuntime(allocator: std.mem.Allocator, io: std.Io) !*VulkanEngine {
    if (config.FLEET_MODE) {
        global_fleet = initFleet(allocator, io) catch |err| {
            sys.print("[MULTI-GPU] Fleet init failed ({any}), falling back to single engine\n", .{err});
            global_instance = try VulkanEngine.init(allocator, io);
            return global_instance.?;
        };
        global_instance = global_fleet.?.primary;
        return global_instance.?;
    }

    global_instance = try VulkanEngine.init(allocator, io);
    return global_instance.?;
}

pub fn initFleet(allocator: std.mem.Allocator, io: std.Io) !MultiGPU {
    return MultiGPU.init(allocator, io);
}

pub fn deinitRuntime() void {
    if (global_fleet) |*f| f.deinit();
    if (global_fleet == null and global_instance != null) global_instance.?.deinit();
    global_fleet = null;
    global_instance = null;
    thread_engine = null;
}
