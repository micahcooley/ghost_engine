const std = @import("std");

const vk = @cImport({
    @cInclude("vulkan/vulkan.h");
});

pub const SparsityMask = struct {
    data: [131072]u8, // 1 bit per MeaningMatrix slot (1,048,576 slots)

    pub fn init() SparsityMask {
        return .{ .data = [_]u8{0} ** 131072 };
    }

    pub fn isHot(self: *const SparsityMask, slot_idx: u32) bool {
        const byte_idx = slot_idx >> 3;
        const bit_idx = @as(u3, @intCast(slot_idx & 7));
        return (self.data[byte_idx] & (@as(u8, 1) << bit_idx)) != 0;
    }

    pub fn setHot(self: *SparsityMask, slot_idx: u32) void {
        const byte_idx = slot_idx >> 3;
        const bit_idx = @as(u3, @intCast(slot_idx & 7));
        self.data[byte_idx] |= (@as(u8, 1) << bit_idx);
    }
};

pub const BATCH_SIZE = 1024;

pub const OperationalTier = enum(u32) {
    max = 4096,
    high = 2048,
    standard = 1024,
    background = 512,
};

pub const VulkanEngine = struct {
    instance: vk.VkInstance = null,
    pdev: vk.VkPhysicalDevice = null,
    dev: vk.VkDevice = null,
    queue: vk.VkQueue = null,
    queue_family: u32 = 0,

    compute_pipeline: vk.VkPipeline = null,
    etch_pipeline: vk.VkPipeline = null,
    prune_pipeline: vk.VkPipeline = null,
    lookahead_pipeline: vk.VkPipeline = null,
    lattice_pipeline: vk.VkPipeline = null,
    pipeline_layout: vk.VkPipelineLayout = null,

    // ── 1. Meaning Matrix (2GB) ──
    matrix_buffer: vk.VkBuffer = null,
    matrix_memory: vk.VkDeviceMemory = null,
    mapped_matrix: ?[*]u8 = null,

    // ── 1.5. Tag Buffer (8MB) ──
    tag_buffer: vk.VkBuffer = null,
    tag_memory: vk.VkDeviceMemory = null,
    mapped_tags: ?[*]u64 = null,

    // ── 2. Batch Rotors (4096 * 8 bytes) ──
    rotor_buffer: vk.VkBuffer = null,
    rotor_memory: vk.VkDeviceMemory = null,
    mapped_rotors: ?[*]u64 = null,

    // ── 3. Batch Chars (4096 * 4 bytes) ──
    char_buffer: vk.VkBuffer = null,
    char_memory: vk.VkDeviceMemory = null,
    mapped_chars: ?[*]u32 = null,

    // ── 4. Batch Output Energies (4096 * 4 bytes) ──
    energy_buffer: vk.VkBuffer = null,
    energy_memory: vk.VkDeviceMemory = null,
    mapped_energy: ?[*]u32 = null,

    // ── 5. Unified Lattice (1GB, for GPU etching) ──
    lattice_buffer: vk.VkBuffer = null,
    lattice_memory: vk.VkDeviceMemory = null,
    mapped_lattice: ?[*]u32 = null,

    matrix_slots: u32 = 0,

    command_pool: vk.VkCommandPool = null,
    command_buffer: vk.VkCommandBuffer = null,
    descriptor_pool: vk.VkDescriptorPool = null,
    descriptor_set: vk.VkDescriptorSet = null,
    fence: vk.VkFence = null,

    // ── V23: Operational Tier & Hardware Detection ──
    tier: OperationalTier = .standard,
    max_workgroup_invocations: u32 = 1024,
    supports_int16: bool = false,

    allocator: std.mem.Allocator,

    fn check(result: vk.VkResult) !void {
        if (result != vk.VK_SUCCESS) {
            std.debug.print("Vulkan Error: {d}\n", .{result});
            return error.VulkanError;
        }
    }

    fn findMemoryType(pdev: vk.VkPhysicalDevice, typeFilter: u32, properties: vk.VkMemoryPropertyFlags) !u32 {
        var memProperties: vk.VkPhysicalDeviceMemoryProperties = undefined;
        vk.vkGetPhysicalDeviceMemoryProperties(pdev, &memProperties);
        var i: u32 = 0;
        while (i < memProperties.memoryTypeCount) : (i += 1) {
            if ((typeFilter & (@as(u32, 1) << @intCast(i))) != 0 and (memProperties.memoryTypes[i].propertyFlags & properties) == properties) {
                return i;
            }
        }
        return error.MemoryTypeNotFound;
    }

    fn createBuffer(self: *VulkanEngine, size: vk.VkDeviceSize, usage: vk.VkBufferUsageFlags, properties: vk.VkMemoryPropertyFlags, buffer: *vk.VkBuffer, memory: *vk.VkDeviceMemory) !?*anyopaque {
        var bufferInfo = std.mem.zeroes(vk.VkBufferCreateInfo);
        bufferInfo.sType = vk.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
        bufferInfo.size = size;
        bufferInfo.usage = usage;
        bufferInfo.sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE;

        try check(vk.vkCreateBuffer(self.dev, &bufferInfo, null, buffer));

        var memReqs: vk.VkMemoryRequirements = undefined;
        vk.vkGetBufferMemoryRequirements(self.dev, buffer.*, &memReqs);

        var allocInfo = std.mem.zeroes(vk.VkMemoryAllocateInfo);
        allocInfo.sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        allocInfo.allocationSize = memReqs.size;
        allocInfo.memoryTypeIndex = try findMemoryType(self.pdev, memReqs.memoryTypeBits, properties);

        try check(vk.vkAllocateMemory(self.dev, &allocInfo, null, memory));
        try check(vk.vkBindBufferMemory(self.dev, buffer.*, memory.*, 0));

        var pData: ?*anyopaque = null;
        try check(vk.vkMapMemory(self.dev, memory.*, 0, size, 0, &pData));
        return pData;
    }

    fn updateDescriptorSets(self: *VulkanEngine) void {
        var bInfos = [_]vk.VkDescriptorBufferInfo{
            .{ .buffer = self.matrix_buffer, .offset = 0, .range = vk.VK_WHOLE_SIZE },
            .{ .buffer = self.rotor_buffer, .offset = 0, .range = vk.VK_WHOLE_SIZE },
            .{ .buffer = self.char_buffer, .offset = 0, .range = vk.VK_WHOLE_SIZE },
            .{ .buffer = self.energy_buffer, .offset = 0, .range = vk.VK_WHOLE_SIZE },
            .{ .buffer = self.tag_buffer, .offset = 0, .range = vk.VK_WHOLE_SIZE },
            .{ .buffer = self.lattice_buffer, .offset = 0, .range = vk.VK_WHOLE_SIZE },
        };
        var wds = [_]vk.VkWriteDescriptorSet{ std.mem.zeroes(vk.VkWriteDescriptorSet) } ** 6;
        for (&wds, 0..) |*w, i| {
            w.sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            w.dstSet = self.descriptor_set;
            w.dstBinding = @intCast(i);
            w.descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
            w.descriptorCount = 1;
            w.pBufferInfo = &bInfos[i];
        }
        vk.vkUpdateDescriptorSets(self.dev, 6, &wds[0], 0, null);
    }

    pub fn init(allocator: std.mem.Allocator) !VulkanEngine {
        var engine = VulkanEngine{ .allocator = allocator };

        // 1. Instance
        var appInfo = std.mem.zeroes(vk.VkApplicationInfo);
        appInfo.sType = vk.VK_STRUCTURE_TYPE_APPLICATION_INFO;
        appInfo.apiVersion = vk.VK_API_VERSION_1_0;
        var createInfo = std.mem.zeroes(vk.VkInstanceCreateInfo);
        createInfo.sType = vk.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
        createInfo.pApplicationInfo = &appInfo;
        try check(vk.vkCreateInstance(&createInfo, null, &engine.instance));

        // 2. Physical Device Selection (Scoring)
        var deviceCount: u32 = 0;
        try check(vk.vkEnumeratePhysicalDevices(engine.instance, &deviceCount, null));
        if (deviceCount == 0) return error.NoVulkanDevicesFound;

        const pdevs = try allocator.alloc(vk.VkPhysicalDevice, deviceCount);
        defer allocator.free(pdevs);
        try check(vk.vkEnumeratePhysicalDevices(engine.instance, &deviceCount, pdevs.ptr));

        var best_score: u32 = 0;
        for (pdevs) |pd| {
            var props: vk.VkPhysicalDeviceProperties = undefined;
            vk.vkGetPhysicalDeviceProperties(pd, &props);
            
            var features: vk.VkPhysicalDeviceFeatures = undefined;
            vk.vkGetPhysicalDeviceFeatures(pd, &features);

            // Required features for Ghost Engine V23
            if (features.shaderInt64 != vk.VK_TRUE) continue;
            
            var score: u32 = 0;
            if (props.deviceType == vk.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU) score += 10000;
            score += props.limits.maxComputeWorkGroupInvocations;

            var qfCount: u32 = 0;
            vk.vkGetPhysicalDeviceQueueFamilyProperties(pd, &qfCount, null);
            const qfs = try allocator.alloc(vk.VkQueueFamilyProperties, qfCount);
            defer allocator.free(qfs);
            vk.vkGetPhysicalDeviceQueueFamilyProperties(pd, &qfCount, qfs.ptr);

            var found_compute = false;
            for (qfs, 0..) |qf, i| {
                if ((qf.queueFlags & vk.VK_QUEUE_COMPUTE_BIT) != 0) {
                    if (score > best_score) {
                        best_score = score;
                        engine.pdev = pd;
                        engine.queue_family = @intCast(i);
                        found_compute = true;
                    }
                    break;
                }
            }
        }

        if (engine.pdev == null) return error.NoSuitableGPUFound;

        // ── V23 Hardware Feature Detection ──
        var deviceFeatures: vk.VkPhysicalDeviceFeatures = undefined;
        vk.vkGetPhysicalDeviceFeatures(engine.pdev, &deviceFeatures);
        engine.supports_int16 = deviceFeatures.shaderInt16 == vk.VK_TRUE;

        var devProps: vk.VkPhysicalDeviceProperties = undefined;
        vk.vkGetPhysicalDeviceProperties(engine.pdev, &devProps);
        engine.max_workgroup_invocations = devProps.limits.maxComputeWorkGroupInvocations;

        std.debug.print("[VULKAN] Selected Device: {s}\n", .{devProps.deviceName});
        std.debug.print("[VULKAN] shaderInt16: {any}\n", .{engine.supports_int16});
        std.debug.print("[VULKAN] maxComputeWorkGroupInvocations: {d}\n", .{engine.max_workgroup_invocations});

        // 3. Logical Device
        const qPriority: f32 = 1.0;
        var qCreateInfo = std.mem.zeroes(vk.VkDeviceQueueCreateInfo);
        qCreateInfo.sType = vk.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
        qCreateInfo.queueFamilyIndex = engine.queue_family;
        qCreateInfo.queueCount = 1;
        qCreateInfo.pQueuePriorities = &qPriority;

        var features = std.mem.zeroes(vk.VkPhysicalDeviceFeatures);
        features.shaderInt64 = vk.VK_TRUE;
        features.shaderInt16 = vk.VK_TRUE;

        var dCreateInfo = std.mem.zeroes(vk.VkDeviceCreateInfo);
        dCreateInfo.sType = vk.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
        dCreateInfo.queueCreateInfoCount = 1;
        dCreateInfo.pQueueCreateInfos = &qCreateInfo;
        dCreateInfo.pEnabledFeatures = &features;
        try check(vk.vkCreateDevice(engine.pdev, &dCreateInfo, null, &engine.dev));
        vk.vkGetDeviceQueue(engine.dev, engine.queue_family, 0, &engine.queue);

        // 4. Buffers
        const batch_flags = vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;

        // 2GB Meaning Matrix (1M slots × 1024 u16)
        engine.matrix_slots = 1_048_576;
        const init_matrix_size = @as(usize, 1024) * 1024 * 1024 * 2; // 2GB
        const init_tag_size = @as(usize, engine.matrix_slots) * 8;

        engine.mapped_matrix = @ptrCast(engine.createBuffer(init_matrix_size, vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, batch_flags, &engine.matrix_buffer, &engine.matrix_memory) catch |err| {
            return err;
        });

        engine.mapped_tags = @ptrCast(@alignCast(try engine.createBuffer(init_tag_size, vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, batch_flags, &engine.tag_buffer, &engine.tag_memory)));
        engine.mapped_rotors = @ptrCast(@alignCast(try engine.createBuffer(4096 * 8 * 2, vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, batch_flags, &engine.rotor_buffer, &engine.rotor_memory)));
        engine.mapped_chars = @ptrCast(@alignCast(try engine.createBuffer(4096 * 4, vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, batch_flags, &engine.char_buffer, &engine.char_memory)));
        engine.mapped_energy = @ptrCast(@alignCast(try engine.createBuffer(4096 * 4, vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, batch_flags, &engine.energy_buffer, &engine.energy_memory)));

        // 1GB Unified Lattice (536M u16 = 268M u32 packed)
        const lattice_size = @as(usize, 1024) * 1024 * 1024;
        engine.mapped_lattice = @ptrCast(@alignCast(try engine.createBuffer(lattice_size, vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, batch_flags, &engine.lattice_buffer, &engine.lattice_memory) orelse return error.VulkanError));

        // 5. Descriptor Layout
        var pcRange = std.mem.zeroes(vk.VkPushConstantRange);
        pcRange.stageFlags = vk.VK_SHADER_STAGE_COMPUTE_BIT;
        pcRange.offset = 0;
        pcRange.size = 8; // uint batch_size, uint mode

        var bindings = [_]vk.VkDescriptorSetLayoutBinding{
            std.mem.zeroes(vk.VkDescriptorSetLayoutBinding),
            std.mem.zeroes(vk.VkDescriptorSetLayoutBinding),
            std.mem.zeroes(vk.VkDescriptorSetLayoutBinding),
            std.mem.zeroes(vk.VkDescriptorSetLayoutBinding),
            std.mem.zeroes(vk.VkDescriptorSetLayoutBinding),
            std.mem.zeroes(vk.VkDescriptorSetLayoutBinding),
        };
        for (&bindings, 0..) |*b, i| {
            b.binding = @intCast(i);
            b.descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
            b.descriptorCount = 1;
            b.stageFlags = vk.VK_SHADER_STAGE_COMPUTE_BIT;
        }

        var dslCreateInfo = std.mem.zeroes(vk.VkDescriptorSetLayoutCreateInfo);
        dslCreateInfo.sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
        dslCreateInfo.bindingCount = 6;
        dslCreateInfo.pBindings = &bindings[0];
        var dsl: vk.VkDescriptorSetLayout = null;
        try check(vk.vkCreateDescriptorSetLayout(engine.dev, &dslCreateInfo, null, &dsl));
        defer vk.vkDestroyDescriptorSetLayout(engine.dev, dsl, null);

        var plCreateInfo = std.mem.zeroes(vk.VkPipelineLayoutCreateInfo);
        plCreateInfo.sType = vk.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
        plCreateInfo.setLayoutCount = 1;
        plCreateInfo.pSetLayouts = &dsl;
        plCreateInfo.pushConstantRangeCount = 1;
        plCreateInfo.pPushConstantRanges = &pcRange;
        try check(vk.vkCreatePipelineLayout(engine.dev, &plCreateInfo, null, &engine.pipeline_layout));

        // 6. Resonance Pipeline
        const res_spv = @embedFile("shaders/resonance_query.spv");
        var smCreateInfoRes = std.mem.zeroes(vk.VkShaderModuleCreateInfo);
        smCreateInfoRes.sType = vk.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
        smCreateInfoRes.codeSize = res_spv.len;
        smCreateInfoRes.pCode = @alignCast(@ptrCast(res_spv.ptr));
        var resModule: vk.VkShaderModule = null;
        try check(vk.vkCreateShaderModule(engine.dev, &smCreateInfoRes, null, &resModule));
        defer vk.vkDestroyShaderModule(engine.dev, resModule, null);

        var ssCreateInfoRes = std.mem.zeroes(vk.VkPipelineShaderStageCreateInfo);
        ssCreateInfoRes.sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        ssCreateInfoRes.stage = vk.VK_SHADER_STAGE_COMPUTE_BIT;
        ssCreateInfoRes.module = resModule;
        ssCreateInfoRes.pName = "main";
        var pCreateInfoRes = std.mem.zeroes(vk.VkComputePipelineCreateInfo);
        pCreateInfoRes.sType = vk.VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO;
        pCreateInfoRes.stage = ssCreateInfoRes;
        pCreateInfoRes.layout = engine.pipeline_layout;
        try check(vk.vkCreateComputePipelines(engine.dev, null, 1, &pCreateInfoRes, null, &engine.compute_pipeline));

        // 7. Etch Pipeline (with specialization constant for workgroup size)
        const etch_spv = @embedFile("shaders/genesis_etch.spv");
        var smCreateInfoEtch = std.mem.zeroes(vk.VkShaderModuleCreateInfo);
        smCreateInfoEtch.sType = vk.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
        smCreateInfoEtch.codeSize = etch_spv.len;
        smCreateInfoEtch.pCode = @alignCast(@ptrCast(etch_spv.ptr));
        var etchModule: vk.VkShaderModule = null;
        try check(vk.vkCreateShaderModule(engine.dev, &smCreateInfoEtch, null, &etchModule));
        defer vk.vkDestroyShaderModule(engine.dev, etchModule, null);

        // Specialization constant: local_size_x adapts to GPU capability
        var etch_wg_size: u32 = @min(1024, engine.max_workgroup_invocations);
        var etch_spec_map = vk.VkSpecializationMapEntry{
            .constantID = 0,
            .offset = 0,
            .size = @sizeOf(u32),
        };
        var etch_spec_info = vk.VkSpecializationInfo{
            .mapEntryCount = 1,
            .pMapEntries = &etch_spec_map,
            .dataSize = @sizeOf(u32),
            .pData = &etch_wg_size,
        };

        var ssCreateInfoEtch = std.mem.zeroes(vk.VkPipelineShaderStageCreateInfo);
        ssCreateInfoEtch.sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        ssCreateInfoEtch.stage = vk.VK_SHADER_STAGE_COMPUTE_BIT;
        ssCreateInfoEtch.module = etchModule;
        ssCreateInfoEtch.pName = "main";
        ssCreateInfoEtch.pSpecializationInfo = &etch_spec_info;
        var pCreateInfoEtch = std.mem.zeroes(vk.VkComputePipelineCreateInfo);
        pCreateInfoEtch.sType = vk.VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO;
        pCreateInfoEtch.stage = ssCreateInfoEtch;
        pCreateInfoEtch.layout = engine.pipeline_layout;
        try check(vk.vkCreateComputePipelines(engine.dev, null, 1, &pCreateInfoEtch, null, &engine.etch_pipeline));

        // 7.1 Prune Pipeline
        const prune_spv = @embedFile("shaders/thermal_prune.spv");
        var smCreateInfoPrune = std.mem.zeroes(vk.VkShaderModuleCreateInfo);
        smCreateInfoPrune.sType = vk.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
        smCreateInfoPrune.codeSize = prune_spv.len;
        smCreateInfoPrune.pCode = @alignCast(@ptrCast(prune_spv.ptr));
        var pruneModule: vk.VkShaderModule = null;
        try check(vk.vkCreateShaderModule(engine.dev, &smCreateInfoPrune, null, &pruneModule));
        defer vk.vkDestroyShaderModule(engine.dev, pruneModule, null);

        var ssCreateInfoPrune = std.mem.zeroes(vk.VkPipelineShaderStageCreateInfo);
        ssCreateInfoPrune.sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        ssCreateInfoPrune.stage = vk.VK_SHADER_STAGE_COMPUTE_BIT;
        ssCreateInfoPrune.module = pruneModule;
        ssCreateInfoPrune.pName = "main";
        var pCreateInfoPrune = std.mem.zeroes(vk.VkComputePipelineCreateInfo);
        pCreateInfoPrune.sType = vk.VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO;
        pCreateInfoPrune.stage = ssCreateInfoPrune;
        pCreateInfoPrune.layout = engine.pipeline_layout;
        try check(vk.vkCreateComputePipelines(engine.dev, null, 1, &pCreateInfoPrune, null, &engine.prune_pipeline));

        // 7.2 Lookahead Pipeline
        const lookahead_spv = @embedFile("shaders/recursive_lookahead.spv");
        var smCreateInfoLookahead = std.mem.zeroes(vk.VkShaderModuleCreateInfo);
        smCreateInfoLookahead.sType = vk.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
        smCreateInfoLookahead.codeSize = lookahead_spv.len;
        smCreateInfoLookahead.pCode = @alignCast(@ptrCast(lookahead_spv.ptr));
        var lookaheadModule: vk.VkShaderModule = null;
        try check(vk.vkCreateShaderModule(engine.dev, &smCreateInfoLookahead, null, &lookaheadModule));
        defer vk.vkDestroyShaderModule(engine.dev, lookaheadModule, null);

        var ssCreateInfoLookahead = std.mem.zeroes(vk.VkPipelineShaderStageCreateInfo);
        ssCreateInfoLookahead.sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        ssCreateInfoLookahead.stage = vk.VK_SHADER_STAGE_COMPUTE_BIT;
        ssCreateInfoLookahead.module = lookaheadModule;
        ssCreateInfoLookahead.pName = "main";
        var pCreateInfoLookahead = std.mem.zeroes(vk.VkComputePipelineCreateInfo);
        pCreateInfoLookahead.sType = vk.VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO;
        pCreateInfoLookahead.stage = ssCreateInfoLookahead;
        pCreateInfoLookahead.layout = engine.pipeline_layout;
        try check(vk.vkCreateComputePipelines(engine.dev, null, 1, &pCreateInfoLookahead, null, &engine.lookahead_pipeline));

        // 7.3 Lattice Etch Pipeline
        const lattice_spv = @embedFile("shaders/lattice_etch.spv");
        var smCreateInfoLattice = std.mem.zeroes(vk.VkShaderModuleCreateInfo);
        smCreateInfoLattice.sType = vk.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
        smCreateInfoLattice.codeSize = lattice_spv.len;
        smCreateInfoLattice.pCode = @alignCast(@ptrCast(lattice_spv.ptr));
        var latticeModule: vk.VkShaderModule = null;
        try check(vk.vkCreateShaderModule(engine.dev, &smCreateInfoLattice, null, &latticeModule));
        defer vk.vkDestroyShaderModule(engine.dev, latticeModule, null);

        var ssCreateInfoLattice = std.mem.zeroes(vk.VkPipelineShaderStageCreateInfo);
        ssCreateInfoLattice.sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        ssCreateInfoLattice.stage = vk.VK_SHADER_STAGE_COMPUTE_BIT;
        ssCreateInfoLattice.module = latticeModule;
        ssCreateInfoLattice.pName = "main";
        var pCreateInfoLattice = std.mem.zeroes(vk.VkComputePipelineCreateInfo);
        pCreateInfoLattice.sType = vk.VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO;
        pCreateInfoLattice.stage = ssCreateInfoLattice;
        pCreateInfoLattice.layout = engine.pipeline_layout;
        try check(vk.vkCreateComputePipelines(engine.dev, null, 1, &pCreateInfoLattice, null, &engine.lattice_pipeline));


        // 8. Descriptors
        var poolSize = std.mem.zeroes(vk.VkDescriptorPoolSize);
        poolSize.type = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
        poolSize.descriptorCount = 6;
        var dpCreateInfo = std.mem.zeroes(vk.VkDescriptorPoolCreateInfo);
        dpCreateInfo.sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
        dpCreateInfo.poolSizeCount = 1;
        dpCreateInfo.pPoolSizes = &poolSize;
        dpCreateInfo.maxSets = 1;
        try check(vk.vkCreateDescriptorPool(engine.dev, &dpCreateInfo, null, &engine.descriptor_pool));

        var dsAllocInfo = std.mem.zeroes(vk.VkDescriptorSetAllocateInfo);
        dsAllocInfo.sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
        dsAllocInfo.descriptorPool = engine.descriptor_pool;
        dsAllocInfo.descriptorSetCount = 1;
        dsAllocInfo.pSetLayouts = &dsl;
        try check(vk.vkAllocateDescriptorSets(engine.dev, &dsAllocInfo, &engine.descriptor_set));
        
        engine.updateDescriptorSets();

        // 9. Commands
        var cpCreateInfo = std.mem.zeroes(vk.VkCommandPoolCreateInfo);
        cpCreateInfo.sType = vk.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
        cpCreateInfo.queueFamilyIndex = engine.queue_family;
        cpCreateInfo.flags = vk.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
        try check(vk.vkCreateCommandPool(engine.dev, &cpCreateInfo, null, &engine.command_pool));
        var cbAllocInfo = std.mem.zeroes(vk.VkCommandBufferAllocateInfo);
        cbAllocInfo.sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
        cbAllocInfo.commandPool = engine.command_pool;
        cbAllocInfo.level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        cbAllocInfo.commandBufferCount = 1;
        try check(vk.vkAllocateCommandBuffers(engine.dev, &cbAllocInfo, &engine.command_buffer));

        var fCreateInfo = std.mem.zeroes(vk.VkFenceCreateInfo);
        fCreateInfo.sType = vk.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
        try check(vk.vkCreateFence(engine.dev, &fCreateInfo, null, &engine.fence));

        return engine;
    }

    pub fn dispatchEtch(self: *VulkanEngine, batch_size: u32) !void {
        var beginInfo = std.mem.zeroes(vk.VkCommandBufferBeginInfo);
        beginInfo.sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        try check(vk.vkBeginCommandBuffer(self.command_buffer, &beginInfo));

        vk.vkCmdBindPipeline(self.command_buffer, vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.etch_pipeline);
        vk.vkCmdBindDescriptorSets(self.command_buffer, vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline_layout, 0, 1, &self.descriptor_set, 0, null);
        
        vk.vkCmdPushConstants(self.command_buffer, self.pipeline_layout, vk.VK_SHADER_STAGE_COMPUTE_BIT, 0, 4, &batch_size);

        vk.vkCmdDispatch(self.command_buffer, batch_size, 1, 1);
        try check(vk.vkEndCommandBuffer(self.command_buffer));

        var submitInfo = std.mem.zeroes(vk.VkSubmitInfo);
        submitInfo.sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submitInfo.commandBufferCount = 1;
        submitInfo.pCommandBuffers = &self.command_buffer;
        try check(vk.vkResetFences(self.dev, 1, &self.fence));
        try check(vk.vkQueueSubmit(self.queue, 1, &submitInfo, self.fence));
        try check(vk.vkWaitForFences(self.dev, 1, &self.fence, vk.VK_TRUE, std.math.maxInt(u64)));
    }

    pub fn dispatchPrune(self: *VulkanEngine) !void {
        var beginInfo = std.mem.zeroes(vk.VkCommandBufferBeginInfo);
        beginInfo.sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        try check(vk.vkBeginCommandBuffer(self.command_buffer, &beginInfo));

        vk.vkCmdBindPipeline(self.command_buffer, vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.prune_pipeline);
        vk.vkCmdBindDescriptorSets(self.command_buffer, vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline_layout, 0, 1, &self.descriptor_set, 0, null);
        
        const params = [_]u32{ 1048576, 0 }; // Full lattice tags
        vk.vkCmdPushConstants(self.command_buffer, self.pipeline_layout, vk.VK_SHADER_STAGE_COMPUTE_BIT, 0, 8, &params[0]);

        vk.vkCmdDispatch(self.command_buffer, (1048576 + 255) / 256, 1, 1);
        try check(vk.vkEndCommandBuffer(self.command_buffer));

        var submitInfo = std.mem.zeroes(vk.VkSubmitInfo);
        submitInfo.sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submitInfo.commandBufferCount = 1;
        submitInfo.pCommandBuffers = &self.command_buffer;
        try check(vk.vkResetFences(self.dev, 1, &self.fence));
        try check(vk.vkQueueSubmit(self.queue, 1, &submitInfo, self.fence));
        try check(vk.vkWaitForFences(self.dev, 1, &self.fence, vk.VK_TRUE, std.math.maxInt(u64)));
    }

    pub fn dispatchRecursiveLookahead(self: *VulkanEngine, num_rotors: u32, depth: u32, allocator: std.mem.Allocator) ![]u32 {
        var beginInfo = std.mem.zeroes(vk.VkCommandBufferBeginInfo);
        beginInfo.sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        try check(vk.vkBeginCommandBuffer(self.command_buffer, &beginInfo));

        vk.vkCmdBindPipeline(self.command_buffer, vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.lookahead_pipeline);
        vk.vkCmdBindDescriptorSets(self.command_buffer, vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline_layout, 0, 1, &self.descriptor_set, 0, null);
        
        const params = [_]u32{ num_rotors, depth };
        vk.vkCmdPushConstants(self.command_buffer, self.pipeline_layout, vk.VK_SHADER_STAGE_COMPUTE_BIT, 0, 8, &params[0]);

        vk.vkCmdDispatch(self.command_buffer, num_rotors, 1, 1); 
        try check(vk.vkEndCommandBuffer(self.command_buffer));

        var submitInfo = std.mem.zeroes(vk.VkSubmitInfo);
        submitInfo.sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submitInfo.commandBufferCount = 1;
        submitInfo.pCommandBuffers = &self.command_buffer;
        try check(vk.vkResetFences(self.dev, 1, &self.fence));
        try check(vk.vkQueueSubmit(self.queue, 1, &submitInfo, self.fence));
        try check(vk.vkWaitForFences(self.dev, 1, &self.fence, vk.VK_TRUE, std.math.maxInt(u64)));

        const result = try allocator.alloc(u32, num_rotors);
        std.mem.copy(u32, result, self.mapped_energy.?[0..num_rotors]);
        return result;
    }


    pub fn dispatchBatch(self: *VulkanEngine, batch_size: u32) ![]u32 {
        var beginInfo = std.mem.zeroes(vk.VkCommandBufferBeginInfo);
        beginInfo.sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        try check(vk.vkBeginCommandBuffer(self.command_buffer, &beginInfo));

        vk.vkCmdBindPipeline(self.command_buffer, vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.compute_pipeline);
        vk.vkCmdBindDescriptorSets(self.command_buffer, vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline_layout, 0, 1, &self.descriptor_set, 0, null);
        
        const params = [_]u32{ batch_size, 0 }; // 0 = Training Resonance
        vk.vkCmdPushConstants(self.command_buffer, self.pipeline_layout, vk.VK_SHADER_STAGE_COMPUTE_BIT, 0, 8, &params[0]);

        vk.vkCmdDispatch(self.command_buffer, (batch_size + 63) / 64, 1, 1);
        try check(vk.vkEndCommandBuffer(self.command_buffer));

        var submitInfo = std.mem.zeroes(vk.VkSubmitInfo);
        submitInfo.sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submitInfo.commandBufferCount = 1;
        submitInfo.pCommandBuffers = &self.command_buffer;
        try check(vk.vkResetFences(self.dev, 1, &self.fence));
        try check(vk.vkQueueSubmit(self.queue, 1, &submitInfo, self.fence));
        try check(vk.vkWaitForFences(self.dev, 1, &self.fence, vk.VK_TRUE, std.math.maxInt(u64)));

        const result = try self.allocator.alloc(u32, batch_size);
        std.mem.copy(u32, result, self.mapped_energy.?[0..batch_size]);
        return result;
    }

    pub fn dispatchResonance(self: *VulkanEngine, lexical_rotor: u64, semantic_rotor: u64, allocator: std.mem.Allocator) ![]u32 {
        self.mapped_rotors.?[0] = lexical_rotor;
        self.mapped_rotors.?[1] = semantic_rotor;
        
        var beginInfo = std.mem.zeroes(vk.VkCommandBufferBeginInfo);
        beginInfo.sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        try check(vk.vkBeginCommandBuffer(self.command_buffer, &beginInfo));

        vk.vkCmdBindPipeline(self.command_buffer, vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.compute_pipeline);
        vk.vkCmdBindDescriptorSets(self.command_buffer, vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline_layout, 0, 1, &self.descriptor_set, 0, null);
        
        const params = [_]u32{ 1, 1 }; // 1 = Inference (Multiscale)
        vk.vkCmdPushConstants(self.command_buffer, self.pipeline_layout, vk.VK_SHADER_STAGE_COMPUTE_BIT, 0, 8, &params[0]);

        vk.vkCmdDispatch(self.command_buffer, 4, 1, 1); // 4 * 64 = 256
        try check(vk.vkEndCommandBuffer(self.command_buffer));

        var submitInfo = std.mem.zeroes(vk.VkSubmitInfo);
        submitInfo.sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submitInfo.commandBufferCount = 1;
        submitInfo.pCommandBuffers = &self.command_buffer;
        try check(vk.vkResetFences(self.dev, 1, &self.fence));
        try check(vk.vkQueueSubmit(self.queue, 1, &submitInfo, self.fence));
        try check(vk.vkWaitForFences(self.dev, 1, &self.fence, vk.VK_TRUE, std.math.maxInt(u64)));

        const result = try allocator.alloc(u32, 256);
        std.mem.copyForwards(u32, result, self.mapped_energy.?[0..256]);
        return result;
    }

    pub fn growMatrix(self: *VulkanEngine, extra_elements: u32) !void {
        const old_elements: u32 = self.matrix_slots;
        const new_elements = old_elements + extra_elements;
        const new_data_size = @as(usize, new_elements) * 1024;
        const new_tag_size = @as(usize, new_elements) * 8;
        
        std.debug.print("[VSA] Growing Matrix: {d} slots -> {d} slots\n", .{ old_elements, new_elements });

        const batch_flags = vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;

        var next_matrix_buffer: vk.VkBuffer = null;
        var next_matrix_memory: vk.VkDeviceMemory = null;
        const next_matrix_ptr = @as([*]u8, @ptrCast(self.createBuffer(new_data_size, vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, batch_flags, &next_matrix_buffer, &next_matrix_memory) catch |err| blk: {
            if (err == error.MemoryTypeNotFound) {
                break :blk try self.createBuffer(new_data_size, vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, batch_flags, &next_matrix_buffer, &next_matrix_memory);
            }
            return err;
        } orelse return error.VulkanError));

        // 2. Allocate New Tag Buffer
        var next_tag_buffer: vk.VkBuffer = null;
        var next_tag_memory: vk.VkDeviceMemory = null;
        const next_tag_ptr = @as([*]u64, @ptrCast(@alignCast(try self.createBuffer(new_tag_size, vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, batch_flags, &next_tag_buffer, &next_tag_memory) orelse return error.VulkanError)));

        // 3. Migrate Data
        @memcpy(next_matrix_ptr[0 .. @as(usize, old_elements) * 1024], self.mapped_matrix.?[0 .. @as(usize, old_elements) * 1024]);
        @memset(next_matrix_ptr[@as(usize, old_elements) * 1024 .. new_data_size], 128); // Neutral anchor
        
        @memcpy(next_tag_ptr[0 .. old_elements], self.mapped_tags.?[0 .. old_elements]);
        @memset(std.mem.sliceAsBytes(next_tag_ptr[old_elements .. new_elements]), 0); // Empty slots

        // 4. Cleanup Legacy Silicon
        vk.vkUnmapMemory(self.dev, self.matrix_memory);
        vk.vkDestroyBuffer(self.dev, self.matrix_buffer, null);
        vk.vkFreeMemory(self.dev, self.matrix_memory, null);

        vk.vkUnmapMemory(self.dev, self.tag_memory);
        vk.vkDestroyBuffer(self.dev, self.tag_buffer, null);
        vk.vkFreeMemory(self.dev, self.tag_memory, null);

        // 5. Update Sovereign State
        self.matrix_buffer = next_matrix_buffer;
        self.matrix_memory = next_matrix_memory;
        self.mapped_matrix = next_matrix_ptr;

        self.tag_buffer = next_tag_buffer;
        self.tag_memory = next_tag_memory;
        self.mapped_tags = next_tag_ptr;
        
        self.matrix_slots = new_elements;

        // 6. Refresh Descriptor Bindings
        self.updateDescriptorSets();
    }

    pub fn setTier(self: *VulkanEngine, tier: OperationalTier) void {
        self.tier = tier;
        const batch = @intFromEnum(tier);
        std.debug.print("[VULKAN] Operational tier set: {s} (batch={d})\n", .{ @tagName(tier), batch });
        if (batch > self.max_workgroup_invocations) {
            std.debug.print("[VULKAN] WARNING: batch {d} > maxWorkGroupInvocations {d}, will use loop-carry dispatch\n", .{ batch, self.max_workgroup_invocations });
        }
    }

    /// Loop-Carry Dispatch: splits a batch into sub-batches that fit
    /// within maxComputeWorkGroupInvocations, carrying rotor state across.
    /// Chunked Multi-Stream Dispatch: Handles massive batches by splitting them
    /// into GPU-sized workgroups, carrying rotors across streams.
    pub fn dispatchEtchChunked(self: *VulkanEngine, total_batch: u32, starting_rotors: []const u64) !void {
        // Upload the starting rotors for this batch
        std.mem.copy(u64, self.mapped_rotors.?[0..starting_rotors.len], starting_rotors);

        // We assume the batch is blocked: [Chunk S0][Chunk S1][Chunk S2][Chunk S3]
        // Each chunk is handled by a dedicated workgroup (1024 threads).
        try self.dispatchMergedEtch(total_batch);
    }

    /// GPU Lattice Etch: dispatches the lattice_etch shader for a batch.
    /// Each work item etches one (rotor, char) pair into 3 domains.
    pub fn dispatchLatticeEtch(self: *VulkanEngine, batch_size: u32) !void {
        var beginInfo = std.mem.zeroes(vk.VkCommandBufferBeginInfo);
        beginInfo.sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        try check(vk.vkBeginCommandBuffer(self.command_buffer, &beginInfo));

        vk.vkCmdBindPipeline(self.command_buffer, vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.lattice_pipeline);
        vk.vkCmdBindDescriptorSets(self.command_buffer, vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline_layout, 0, 1, &self.descriptor_set, 0, null);

        const params = [_]u32{ batch_size, 0 };
        vk.vkCmdPushConstants(self.command_buffer, self.pipeline_layout, vk.VK_SHADER_STAGE_COMPUTE_BIT, 0, 8, &params[0]);

        vk.vkCmdDispatch(self.command_buffer, (batch_size + 63) / 64, 1, 1);
        try check(vk.vkEndCommandBuffer(self.command_buffer));

        var submitInfo = std.mem.zeroes(vk.VkSubmitInfo);
        submitInfo.sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submitInfo.commandBufferCount = 1;
        submitInfo.pCommandBuffers = &self.command_buffer;
        try check(vk.vkResetFences(self.dev, 1, &self.fence));
        try check(vk.vkQueueSubmit(self.queue, 1, &submitInfo, self.fence));
        try check(vk.vkWaitForFences(self.dev, 1, &self.fence, vk.VK_TRUE, std.math.maxInt(u64)));
    }

    /// Merged Dispatch: records both lattice etch AND meaning matrix etch into
    /// a single command buffer, one fence wait for both operations.
    /// Merged Dispatch: records both lattice etch AND meaning matrix etch into
    /// a single command buffer, one fence wait for both operations.
    /// Utilizes Prefix Scan on GPU to calculate rotors internally.
    pub fn dispatchMergedEtch(self: *VulkanEngine, batch_size: u32) !void {
        var beginInfo = std.mem.zeroes(vk.VkCommandBufferBeginInfo);
        beginInfo.sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        try check(vk.vkBeginCommandBuffer(self.command_buffer, &beginInfo));

        const num_workgroups = (batch_size + 1023) / 1024;

        // Pass 1: Lattice etch (3-domain CMS)
        vk.vkCmdBindPipeline(self.command_buffer, vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.lattice_pipeline);
        vk.vkCmdBindDescriptorSets(self.command_buffer, vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline_layout, 0, 1, &self.descriptor_set, 0, null);
        const params = [_]u32{ batch_size, 0 };
        vk.vkCmdPushConstants(self.command_buffer, self.pipeline_layout, vk.VK_SHADER_STAGE_COMPUTE_BIT, 0, 8, &params[0]);
        vk.vkCmdDispatch(self.command_buffer, num_workgroups, 1, 1);

        // Memory barrier between the two dispatches
        var barrier = std.mem.zeroes(vk.VkMemoryBarrier);
        barrier.sType = vk.VK_STRUCTURE_TYPE_MEMORY_BARRIER;
        barrier.srcAccessMask = vk.VK_ACCESS_SHADER_WRITE_BIT;
        barrier.dstAccessMask = vk.VK_ACCESS_SHADER_READ_BIT | vk.VK_ACCESS_SHADER_WRITE_BIT;
        vk.vkCmdPipelineBarrier(
            self.command_buffer,
            vk.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
            vk.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
            0, 1, &barrier, 0, null, 0, null,
        );

        // Pass 2: Meaning matrix etch
        vk.vkCmdBindPipeline(self.command_buffer, vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.etch_pipeline);
        vk.vkCmdPushConstants(self.command_buffer, self.pipeline_layout, vk.VK_SHADER_STAGE_COMPUTE_BIT, 0, 8, &params[0]);
        vk.vkCmdDispatch(self.command_buffer, num_workgroups, 1, 1);

        try check(vk.vkEndCommandBuffer(self.command_buffer));

        var submitInfo = std.mem.zeroes(vk.VkSubmitInfo);
        submitInfo.sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submitInfo.commandBufferCount = 1;
        submitInfo.pCommandBuffers = &self.command_buffer;
        try check(vk.vkResetFences(self.dev, 1, &self.fence));
        try check(vk.vkQueueSubmit(self.queue, 1, &submitInfo, self.fence));
        try check(vk.vkWaitForFences(self.dev, 1, &self.fence, vk.VK_TRUE, std.math.maxInt(u64)));
    }

    pub fn deinit(self: *VulkanEngine) void {
        vk.vkDestroyFence(self.dev, self.fence, null);
        vk.vkDestroyCommandPool(self.dev, self.command_pool, null);
        vk.vkDestroyDescriptorPool(self.dev, self.descriptor_pool, null);
        vk.vkDestroyPipeline(self.dev, self.etch_pipeline, null);
        vk.vkDestroyPipeline(self.dev, self.prune_pipeline, null);
        vk.vkDestroyPipeline(self.dev, self.lookahead_pipeline, null);
        vk.vkDestroyPipeline(self.dev, self.lattice_pipeline, null);
        vk.vkDestroyPipeline(self.dev, self.compute_pipeline, null);
        vk.vkDestroyPipelineLayout(self.dev, self.pipeline_layout, null);

        vk.vkUnmapMemory(self.dev, self.lattice_memory);
        vk.vkDestroyBuffer(self.dev, self.lattice_buffer, null);
        vk.vkFreeMemory(self.dev, self.lattice_memory, null);

        vk.vkUnmapMemory(self.dev, self.energy_memory);
        vk.vkDestroyBuffer(self.dev, self.energy_buffer, null);
        vk.vkFreeMemory(self.dev, self.energy_memory, null);
        
        vk.vkUnmapMemory(self.dev, self.char_memory);
        vk.vkDestroyBuffer(self.dev, self.char_buffer, null);
        vk.vkFreeMemory(self.dev, self.char_memory, null);

        vk.vkUnmapMemory(self.dev, self.rotor_memory);
        vk.vkDestroyBuffer(self.dev, self.rotor_buffer, null);
        vk.vkFreeMemory(self.dev, self.rotor_memory, null);

        vk.vkUnmapMemory(self.dev, self.tag_memory);
        vk.vkDestroyBuffer(self.dev, self.tag_buffer, null);
        vk.vkFreeMemory(self.dev, self.tag_memory, null);

        vk.vkUnmapMemory(self.dev, self.matrix_memory);
        vk.vkDestroyBuffer(self.dev, self.matrix_buffer, null);
        vk.vkFreeMemory(self.dev, self.matrix_memory, null);
        
        vk.vkDestroyDevice(self.dev, null);
        vk.vkDestroyInstance(self.instance, null);
    }
};

const compute_api = @import("compute_api.zig");

var global_instance: ?VulkanEngine = null;

const VulkanComputeProvider = struct {
    pub fn getMatrixData() []u16 {
        const engine = &global_instance.?;
        return @as([*]u16, @ptrCast(@alignCast(engine.mapped_matrix.?)))[0 .. engine.matrix_slots * 1024];
    }
    
    pub fn getTagsData() []u64 {
        const engine = &global_instance.?;
        return engine.mapped_tags.?[0 .. engine.matrix_slots];
    }

    pub fn getLatticeData() []u16 {
        const engine = &global_instance.?;
        return @as([*]u16, @ptrCast(@alignCast(engine.mapped_lattice.?)))[0 .. (1024 * 1024 * 1024) / 2];
    }

    pub fn etch(total_batch: u32, starting_rotors: []const u64, chars: []const u8) anyerror!void {
        const engine = &global_instance.?;
        // Transfer data to GPU buffers
        std.mem.copy(u64, engine.mapped_rotors.?[0..starting_rotors.len], starting_rotors);
        for (chars, 0..) |c, i| {
            engine.mapped_chars.?[i] = @as(u32, c);
        }
        try engine.dispatchMergedEtch(total_batch);
    }

    pub fn queryResonance(lexical_rotor: u64, semantic_rotor: u64, allocator: std.mem.Allocator) anyerror![]u32 {
        return try global_instance.?.dispatchResonance(lexical_rotor, semantic_rotor, allocator);
    }

    pub fn lookahead(num_rotors: u32, depth: u32, allocator: std.mem.Allocator) anyerror![]u32 {
        return try global_instance.?.dispatchRecursiveLookahead(num_rotors, depth, allocator);
    }

    pub fn prune() anyerror!void {
        try global_instance.?.dispatchPrune();
    }

    pub fn setTier(tier: u32) void {
        global_instance.?.setTier(@enumFromInt(tier));
    }
};

const VULKAN_API = compute_api.ComputeApi{
    .name = "Vulkan Spirit V23",
    .getMatrixData = VulkanComputeProvider.getMatrixData,
    .getTagsData = VulkanComputeProvider.getTagsData,
    .getLatticeData = VulkanComputeProvider.getLatticeData,
    .etch = VulkanComputeProvider.etch,
    .queryResonance = VulkanComputeProvider.queryResonance,
    .lookahead = VulkanComputeProvider.lookahead,
    .prune = VulkanComputeProvider.prune,
    .setTier = VulkanComputeProvider.setTier,
};

pub const GHOST_COMPUTE_PLUGIN = compute_api.ComputePlugin{
    .name = "Ghost-Vulkan-Native",
    .version = 0x17, // V23
    .init = pluginInit,
    .deinit = pluginDeinit,
};

fn pluginInit(allocator: std.mem.Allocator) anyerror!*const compute_api.ComputeApi {
    global_instance = try VulkanEngine.init(allocator);
    return &VULKAN_API;
}

fn pluginDeinit() void {
    if (global_instance) |*engine| {
        engine.deinit();
    }
}
