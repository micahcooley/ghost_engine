pub const DEFAULT_UPLOAD_STAGING_SLOTS: usize = 3;
pub const DEFAULT_UPLOAD_STAGING_BYTES: usize = 16 * 1024 * 1024;

pub const ResidentEpoch = struct {
    active_epoch: u64 = 0,
    published_timeline_value: u64 = 0,
};

pub const UploadArenaTelemetry = struct {
    slots: usize = DEFAULT_UPLOAD_STAGING_SLOTS,
    slot_bytes: usize = DEFAULT_UPLOAD_STAGING_BYTES,
    fallback_allocations: u64 = 0,
};

pub const DeviceProfile = struct {
    max_compute_workgroup_invocations: u32 = 1024,
    subgroup_size: u32 = 32,
    total_memory: usize = 8 * 1024 * 1024 * 1024,

    pub fn calculateL1IndexShardSize(self: DeviceProfile) usize {
        // Reduce to 5% (1/20) to ensure we stay within BAR limits on non-Resizable BAR systems
        return self.total_memory / 20;
    }
};
