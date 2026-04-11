const std = @import("std");

/// Ghost Engine Native Plugin Interface (Sovereign Contract)
/// Every plugin must export a symbol named 'plugin_info' of this type.
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
