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
