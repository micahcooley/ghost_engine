const std = @import("std");

/// [ASPIRATIONAL] This interface is not yet used by any production code.
/// Plugin hot-loading is a planned feature.
pub const PluginApi = struct {
    name: []const u8,
    version: u32,
    
    /// Called when the plugin is loaded. Perform initialization here.
    init: *const fn () void,
    
    /// Called periodically or on demand to perform optimizations.
    optimize: *const fn () void,
    
    /// Called before the plugin is unloaded or engine shuts down.
    cleanup: *const fn () void,
};
