/// ── Dynamic Vulkan Loader ──
/// Eliminates load-time dependency on the platform Vulkan loader.
/// Windows resolves `vulkan-1`; Linux resolves `libvulkan.so.1`.
const std = @import("std");
const builtin = @import("builtin");

const DynHandle = *anyopaque;

pub const vk = @cImport({
    @cDefine("VK_NO_PROTOTYPES", "");
    @cInclude("vulkan/vulkan.h");
});

const linked = switch (builtin.os.tag) {
    .linux => struct {
        extern "c" fn vkGetInstanceProcAddr(instance: vk.VkInstance, pName: [*c]const u8) vk.PFN_vkVoidFunction;
    },
    else => struct {},
};

const dyn = switch (builtin.os.tag) {
    .windows => struct {
        extern "kernel32" fn LoadLibraryA(lpLibFileName: [*:0]const u8) callconv(.c) ?*anyopaque;
        extern "kernel32" fn GetProcAddress(hModule: ?*anyopaque, lpProcName: [*:0]const u8) callconv(.c) ?*anyopaque;
        extern "kernel32" fn FreeLibrary(hLibModule: *anyopaque) callconv(.c) i32;

        pub fn open(name: [*:0]const u8) ?*anyopaque {
            return LoadLibraryA(name);
        }

        pub fn lookup(comptime T: type, handle: ?*anyopaque, symbol: [*:0]const u8) ?T {
            if (GetProcAddress(handle, symbol)) |raw| {
                return @ptrCast(@alignCast(raw));
            }
            return null;
        }

        pub fn close(handle: *anyopaque) void {
            _ = FreeLibrary(handle);
        }
    },
    else => struct {
        extern "c" fn dlopen(filename: [*:0]const u8, flags: c_int) ?*anyopaque;
        extern "c" fn dlsym(handle: ?*anyopaque, symbol: [*:0]const u8) ?*anyopaque;
        extern "c" fn dlclose(handle: *anyopaque) c_int;
        extern "c" fn dlerror() ?[*:0]const u8;

        const RTLD_NOW: c_int = 2;
        const RTLD_LOCAL: c_int = 0;

        pub fn open(name: [*:0]const u8) ?DynHandle {
            if (dlopen(name, RTLD_NOW | RTLD_LOCAL)) |handle| return handle;
            if (builtin.os.tag == .linux) {
                inline for (linux_vulkan_fallbacks) |path| {
                    if (dlopen(path, RTLD_NOW | RTLD_LOCAL)) |handle| return handle;
                }
            }
            if (dlerror()) |err| {
                std.debug.print("[VK LOADER] dlerror: {s}\n", .{std.mem.span(err)});
            }
            return null;
        }

        pub fn lookup(comptime T: type, handle: DynHandle, symbol: [*:0]const u8) ?T {
            if (dlsym(handle, symbol)) |raw| {
                return @as(T, @ptrCast(raw));
            }
            return null;
        }

        pub fn close(handle: DynHandle) void {
            _ = dlclose(handle);
        }
    },
};

const linux_vulkan_fallbacks = [_][*:0]const u8{
    "/lib/x86_64-linux-gnu/libvulkan.so.1",
    "/usr/lib/x86_64-linux-gnu/libvulkan.so.1",
    "/lib64/libvulkan.so.1",
    "/usr/lib64/libvulkan.so.1",
    "/lib/libvulkan.so.1",
    "/usr/lib/libvulkan.so.1",
};

fn vulkanLibraryName() [*:0]const u8 {
    return switch (builtin.os.tag) {
        .windows => "vulkan-1",
        .linux => "libvulkan.so.1",
        .macos => "libvulkan.dylib",
        else => "libvulkan.so.1",
    };
}

pub const VulkanCtx = struct {
    dll: ?DynHandle = null,

    // Bootstrap (loaded from the loader directly)
    vkCreateInstance: vk.PFN_vkCreateInstance = null,
    vkGetInstanceProcAddr: vk.PFN_vkGetInstanceProcAddr = null,
    vkEnumerateInstanceLayerProperties: vk.PFN_vkEnumerateInstanceLayerProperties = null,
    vkEnumerateInstanceExtensionProperties: vk.PFN_vkEnumerateInstanceExtensionProperties = null,

    // All other functions (loaded via vkGetInstanceProcAddr after instance creation)
    vkEnumeratePhysicalDevices: vk.PFN_vkEnumeratePhysicalDevices = null,
    vkGetPhysicalDeviceProperties: vk.PFN_vkGetPhysicalDeviceProperties = null,
    vkGetPhysicalDeviceFeatures: vk.PFN_vkGetPhysicalDeviceFeatures = null,
    vkGetPhysicalDeviceQueueFamilyProperties: vk.PFN_vkGetPhysicalDeviceQueueFamilyProperties = null,
    vkGetPhysicalDeviceMemoryProperties: vk.PFN_vkGetPhysicalDeviceMemoryProperties = null,
    vkCreateDevice: vk.PFN_vkCreateDevice = null,
    vkGetDeviceQueue: vk.PFN_vkGetDeviceQueue = null,
    vkDestroyDevice: vk.PFN_vkDestroyDevice = null,
    vkDestroyInstance: vk.PFN_vkDestroyInstance = null,

    vkCreateBuffer: vk.PFN_vkCreateBuffer = null,
    vkGetBufferMemoryRequirements: vk.PFN_vkGetBufferMemoryRequirements = null,
    vkAllocateMemory: vk.PFN_vkAllocateMemory = null,
    vkBindBufferMemory: vk.PFN_vkBindBufferMemory = null,
    vkMapMemory: vk.PFN_vkMapMemory = null,
    vkUnmapMemory: vk.PFN_vkUnmapMemory = null,
    vkFreeMemory: vk.PFN_vkFreeMemory = null,
    vkDestroyBuffer: vk.PFN_vkDestroyBuffer = null,

    vkCreateDescriptorSetLayout: vk.PFN_vkCreateDescriptorSetLayout = null,
    vkDestroyDescriptorSetLayout: vk.PFN_vkDestroyDescriptorSetLayout = null,
    vkCreateDescriptorPool: vk.PFN_vkCreateDescriptorPool = null,
    vkDestroyDescriptorPool: vk.PFN_vkDestroyDescriptorPool = null,
    vkAllocateDescriptorSets: vk.PFN_vkAllocateDescriptorSets = null,
    vkUpdateDescriptorSets: vk.PFN_vkUpdateDescriptorSets = null,

    vkCreatePipelineLayout: vk.PFN_vkCreatePipelineLayout = null,
    vkDestroyPipelineLayout: vk.PFN_vkDestroyPipelineLayout = null,
    vkCreateShaderModule: vk.PFN_vkCreateShaderModule = null,
    vkDestroyShaderModule: vk.PFN_vkDestroyShaderModule = null,
    vkCreateComputePipelines: vk.PFN_vkCreateComputePipelines = null,
    vkDestroyPipeline: vk.PFN_vkDestroyPipeline = null,

    vkCreateCommandPool: vk.PFN_vkCreateCommandPool = null,
    vkDestroyCommandPool: vk.PFN_vkDestroyCommandPool = null,
    vkAllocateCommandBuffers: vk.PFN_vkAllocateCommandBuffers = null,
    vkBeginCommandBuffer: vk.PFN_vkBeginCommandBuffer = null,
    vkEndCommandBuffer: vk.PFN_vkEndCommandBuffer = null,
    vkCmdBindPipeline: vk.PFN_vkCmdBindPipeline = null,
    vkCmdBindDescriptorSets: vk.PFN_vkCmdBindDescriptorSets = null,
    vkCmdPushConstants: vk.PFN_vkCmdPushConstants = null,
    vkCmdDispatch: vk.PFN_vkCmdDispatch = null,
    vkCmdPipelineBarrier: vk.PFN_vkCmdPipelineBarrier = null,
    vkCmdCopyBuffer: vk.PFN_vkCmdCopyBuffer = null,

    vkCreateFence: vk.PFN_vkCreateFence = null,
    vkDestroyFence: vk.PFN_vkDestroyFence = null,
    vkCreateSemaphore: vk.PFN_vkCreateSemaphore = null,
    vkDestroySemaphore: vk.PFN_vkDestroySemaphore = null,
    vkWaitForFences: vk.PFN_vkWaitForFences = null,
    vkResetFences: vk.PFN_vkResetFences = null,
    vkDeviceWaitIdle: vk.PFN_vkDeviceWaitIdle = null,
    vkWaitSemaphores: vk.PFN_vkWaitSemaphores = null,
    vkQueueSubmit: vk.PFN_vkQueueSubmit = null,
    vkCreateDebugUtilsMessengerEXT: vk.PFN_vkCreateDebugUtilsMessengerEXT = null,
    vkDestroyDebugUtilsMessengerEXT: vk.PFN_vkDestroyDebugUtilsMessengerEXT = null,

    pub fn load() !VulkanCtx {
        var ctx = VulkanCtx{};
        if (dyn.open(vulkanLibraryName())) |dll| {
            errdefer dyn.close(dll);
            ctx.dll = dll;

            ctx.vkGetInstanceProcAddr = dyn.lookup(vk.PFN_vkGetInstanceProcAddr, dll, "vkGetInstanceProcAddr") orelse return error.VulkanEntryPointMissing;
        } else {
            if (builtin.os.tag == .linux and builtin.is_test) {
                ctx.vkGetInstanceProcAddr = linked.vkGetInstanceProcAddr;
            } else {
                return error.VulkanDllNotFound;
            }
        }

        const gipa = ctx.vkGetInstanceProcAddr orelse return error.VulkanEntryPointMissing;
        ctx.vkCreateInstance = @ptrCast(@alignCast(gipa(null, "vkCreateInstance") orelse return error.VulkanEntryPointMissing));
        ctx.vkEnumerateInstanceLayerProperties = @ptrCast(@alignCast(gipa(null, "vkEnumerateInstanceLayerProperties") orelse return error.VulkanEntryPointMissing));
        ctx.vkEnumerateInstanceExtensionProperties = @ptrCast(@alignCast(gipa(null, "vkEnumerateInstanceExtensionProperties") orelse return error.VulkanEntryPointMissing));

        return ctx;
    }

    pub fn loadInstance(self: *VulkanCtx, instance: vk.VkInstance) !void {
        const gipa = self.vkGetInstanceProcAddr orelse return;
        inline for (required_instance_fn_names) |name| {
            @field(self, name) = if (gipa(instance, name)) |raw| @ptrCast(@alignCast(raw)) else null;
            if (@field(self, name) == null) return error.VulkanEntryPointMissing;
        }
        inline for (optional_instance_fn_names) |name| {
            @field(self, name) = if (gipa(instance, name)) |raw| @ptrCast(@alignCast(raw)) else null;
        }
    }

    pub fn unload(self: *VulkanCtx) void {
        if (self.dll) |handle| {
            dyn.close(handle);
            self.dll = null;
        }
    }
};

const required_instance_fn_names = [_][:0]const u8{
    "vkEnumeratePhysicalDevices",
    "vkGetPhysicalDeviceProperties",
    "vkGetPhysicalDeviceFeatures",
    "vkGetPhysicalDeviceQueueFamilyProperties",
    "vkGetPhysicalDeviceMemoryProperties",
    "vkCreateDevice",
    "vkGetDeviceQueue",
    "vkDestroyDevice",
    "vkDestroyInstance",
    "vkCreateBuffer",
    "vkGetBufferMemoryRequirements",
    "vkAllocateMemory",
    "vkBindBufferMemory",
    "vkMapMemory",
    "vkUnmapMemory",
    "vkFreeMemory",
    "vkDestroyBuffer",
    "vkCreateDescriptorSetLayout",
    "vkDestroyDescriptorSetLayout",
    "vkCreateDescriptorPool",
    "vkDestroyDescriptorPool",
    "vkAllocateDescriptorSets",
    "vkUpdateDescriptorSets",
    "vkCreatePipelineLayout",
    "vkDestroyPipelineLayout",
    "vkCreateShaderModule",
    "vkDestroyShaderModule",
    "vkCreateComputePipelines",
    "vkDestroyPipeline",
    "vkCreateCommandPool",
    "vkDestroyCommandPool",
    "vkAllocateCommandBuffers",
    "vkBeginCommandBuffer",
    "vkEndCommandBuffer",
    "vkCmdBindPipeline",
    "vkCmdBindDescriptorSets",
    "vkCmdPushConstants",
    "vkCmdDispatch",
    "vkCmdPipelineBarrier",
    "vkCmdCopyBuffer",
    "vkCreateFence",
    "vkDestroyFence",
    "vkCreateSemaphore",
    "vkDestroySemaphore",
    "vkWaitForFences",
    "vkResetFences",
    "vkDeviceWaitIdle",
    "vkWaitSemaphores",
    "vkQueueSubmit",
};

const optional_instance_fn_names = [_][:0]const u8{
    "vkCreateDebugUtilsMessengerEXT",
    "vkDestroyDebugUtilsMessengerEXT",
};
