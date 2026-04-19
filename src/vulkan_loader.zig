/// ── Dynamic Vulkan Loader ──
/// Eliminates load-time dependency on vulkan-1.dll.
/// The DLL is loaded at runtime via Win32 LoadLibraryA.
/// If missing, VulkanEngine.init() returns an error → CPU fallback.
const std = @import("std");

// Import Vulkan types and constants WITHOUT function prototypes.
// No linker stubs generated → no load-time DLL dependency.
pub const vk = @cImport({
    @cDefine("VK_NO_PROTOTYPES", "");
    @cInclude("vulkan/vulkan.h");
});

// ── Win32 Dynamic Loading ──
extern "kernel32" fn LoadLibraryA(lpLibFileName: [*:0]const u8) callconv(.c) ?*anyopaque;
extern "kernel32" fn GetProcAddress(hModule: ?*anyopaque, lpProcName: [*:0]const u8) callconv(.c) ?*anyopaque;
extern "kernel32" fn FreeLibrary(hLibModule: *anyopaque) callconv(.c) i32;

pub const VulkanCtx = struct {
    dll: ?*anyopaque = null,

    // Bootstrap (loaded from DLL directly)
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

    /// Load vulkan-1.dll and the two bootstrap entry points.
    /// Returns error.VulkanDllNotFound if the DLL is missing (no GPU driver).
    pub fn load() !VulkanCtx {
        const dll = LoadLibraryA("vulkan-1") orelse return error.VulkanDllNotFound;

        var ctx = VulkanCtx{ .dll = dll };

        const raw_ci = GetProcAddress(dll, "vkCreateInstance") orelse {
            _ = FreeLibrary(dll);
            return error.VulkanEntryPointMissing;
        };
        ctx.vkCreateInstance = @ptrCast(@alignCast(raw_ci));

        const raw_gipa = GetProcAddress(dll, "vkGetInstanceProcAddr") orelse {
            _ = FreeLibrary(dll);
            return error.VulkanEntryPointMissing;
        };
        ctx.vkGetInstanceProcAddr = @ptrCast(@alignCast(raw_gipa));

        const raw_eilp = GetProcAddress(dll, "vkEnumerateInstanceLayerProperties") orelse {
            _ = FreeLibrary(dll);
            return error.VulkanEntryPointMissing;
        };
        ctx.vkEnumerateInstanceLayerProperties = @ptrCast(@alignCast(raw_eilp));

        const raw_eiep = GetProcAddress(dll, "vkEnumerateInstanceExtensionProperties") orelse {
            _ = FreeLibrary(dll);
            return error.VulkanEntryPointMissing;
        };
        ctx.vkEnumerateInstanceExtensionProperties = @ptrCast(@alignCast(raw_eiep));

        return ctx;
    }

    /// After vkCreateInstance succeeds, load all remaining function pointers.
    pub fn loadInstance(self: *VulkanCtx, instance: vk.VkInstance) void {
        const gipa = self.vkGetInstanceProcAddr orelse return;
        inline for (instance_fn_names) |name| {
            @field(self, name) = if (gipa(instance, name)) |raw| @ptrCast(@alignCast(raw)) else null;
        }
    }

    pub fn unload(self: *VulkanCtx) void {
        if (self.dll) |d| {
            _ = FreeLibrary(d);
            self.dll = null;
        }
    }
};

const instance_fn_names = [_][:0]const u8{
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
    "vkCreateDebugUtilsMessengerEXT",
    "vkDestroyDebugUtilsMessengerEXT",
};
