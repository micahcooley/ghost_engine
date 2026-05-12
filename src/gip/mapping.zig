const std = @import("std");
const gutf = @import("../codec/gutf.zig");

pub const SYSTEM_RAM_BOUNDARY_BYTES: u64 = 16 * 1024 * 1024 * 1024;
pub const ORACLE_PAUSE_THRESHOLD_BYTES: u64 = 14 * 1024 * 1024 * 1024;
pub const SNAPSHOT_INTERVAL_NS: u64 = 10 * std.time.ns_per_ms;
pub const PAUSE_SIGNAL_LATENCY_TARGET_NS: u64 = std.time.ns_per_ms;
pub const AUTONOMOUS_TRUTH_DENSITY_FLOOR_PER_MILLE: u16 = 850;

pub const GeometricUid = u128;

pub const GipOpCode = enum(u8) {
    GIP_OP_NULL = 0x00,
    GIP_OP_GET_TELEMETRY = 0x01,
    GIP_OP_PAUSE_ORACLE = 0x02,
    GIP_OP_WATCH_LOG = 0x03,
    GIP_OP_SEC_FAULT = 0x1F,

    GIP_OP_RUNE_SEARCH = 0x80,
    GIP_OP_RUNE_INJECT = 0x81,
    GIP_OP_TRUTH_SYNC = 0x82,
    GIP_OP_RUNE_COMMIT = 0x83,
    GIP_OP_LATTICE_QUERY = 0x86,
    GIP_OP_PATCH_INTEGRITY = 0x87,
    GIP_OP_LANDLOCK_STRICT = 0x89,

    GIP_OP_ORACLE_PROVE = 0xA0,
    GIP_OP_AUTO_FIX = 0xA1,
    GIP_OP_RECURSIVE_BOOT = 0xAF,
    GIP_OP_RESOLVE_BUILD_ROOT = 0xB1,

    GIP_OP_DSP_GENERATE = 0xC0,
    GIP_OP_HOT_RELOAD = 0xC1,
};

pub const EpistemicTier = enum(u8) {
    root = 0,
    verified = 1,
    shadow = 2,
    unverified = 3,

    pub fn authorizes(self: EpistemicTier) bool {
        return self == .root or self == .verified;
    }
};

pub const GipHeader = extern struct {
    geometric_uid_hi: u64,
    geometric_uid_lo: u64,
    opcode: u8,
    flags: u8 = 0,
    payload_len: u16 = 0,
    reserved: u32 = 0,

    pub fn uid(self: GipHeader) GeometricUid {
        return (@as(GeometricUid, self.geometric_uid_hi) << 64) | self.geometric_uid_lo;
    }
};

pub const GipPacket = struct {
    header: GipHeader,
    payload: []const u8 = &.{},

    pub fn opcode(self: GipPacket) !GipOpCode {
        return std.meta.intToEnum(GipOpCode, self.header.opcode) catch error.UnknownOpCode;
    }
};

pub const RuneRecord = struct {
    uid: GeometricUid,
    opcode: GipOpCode,
    tier: EpistemicTier,
    truth_density_per_mille: u16,
    latency_score_us: u16,
    domain: gutf.IntentClass,
    label: []const u8,
    rune: *align(gutf.RUNE_ALIGNMENT) const gutf.RuneBytes,

    pub fn runeView(self: RuneRecord) gutf.RuneView {
        return gutf.viewRuneBlock(self.rune);
    }

    pub fn canEnterZenithBridge(self: RuneRecord) bool {
        return self.tier.authorizes() and
            self.truth_density_per_mille == 1000 and
            self.latency_score_us < 500;
    }
};

pub const ResolvedRune = struct {
    record: RuneRecord,
    bucket: u8,
};

pub const MachineSnapshot = struct {
    monotonic_ns: u64,
    ram_used_bytes: u64,
    cpu_load_per_mille: u16,
    vram_resident_bytes: u64 = 0,
    system_ram_boundary_bytes: u64 = SYSTEM_RAM_BOUNDARY_BYTES,

    pub fn ramPressurePerMille(self: MachineSnapshot) u16 {
        if (self.system_ram_boundary_bytes == 0) return 1000;
        const scaled = (@as(u128, self.ram_used_bytes) * 1000) / self.system_ram_boundary_bytes;
        return @intCast(@min(scaled, 1000));
    }

    pub fn shouldPauseOracle(self: MachineSnapshot) bool {
        return self.ram_used_bytes >= ORACLE_PAUSE_THRESHOLD_BYTES or self.ramPressurePerMille() >= 875;
    }
};

pub const GipSignal = struct {
    opcode: GipOpCode,
    uid: GeometricUid,
    target_latency_ns: u64,
    snapshot: MachineSnapshot,
};

pub const GpuSearchHandshake = struct {
    packet: GipPacket,
    query: gutf.RuneView,
    shader_path: []const u8 = "src/gpu/search.comp",
    starts_at_socket_boundary: bool = true,
};

pub const UID_NULL: GeometricUid = 0x0000_0000_0000_0000_0000_0000_0000_0000;
pub const UID_TELEMETRY_ROOT: GeometricUid = 0x4749_5000_0000_0001_0000_0000_5445_4c45;
pub const UID_PAUSE_ORACLE_ROOT: GeometricUid = 0x4749_5000_0000_0002_0000_0000_5041_5553;
pub const UID_WATCH_LOG_ROOT: GeometricUid = 0x4749_5000_0000_0003_0000_0000_5741_5443;
pub const UID_ZERO_ALLOC_DSP: GeometricUid = 0x5a45_4e44_5350_0001_0000_0000_4453_5030;
pub const UID_RUNE_SEARCH_ROOT: GeometricUid = 0x4749_5053_4541_5243_0000_0000_0000_0001;
pub const UID_RUNE_INJECT_ROOT: GeometricUid = 0x4749_5052_554e_4549_0000_0000_0000_0001;
pub const UID_RUNE_COMMIT_ROOT: GeometricUid = 0x4749_5052_554e_4543_0000_0000_0000_0001;
pub const UID_LATTICE_QUERY_ROOT: GeometricUid = 0x4749_504c_4154_5449_0000_0000_0000_0001;
pub const UID_PATCH_INTEGRITY_ROOT: GeometricUid = 0x4749_5050_4154_4348_0000_0000_0000_0001;
pub const UID_ORACLE_PROVE_ROOT: GeometricUid = 0x4749_504f_5241_434c_0000_0000_0000_0001;
pub const UID_AUTO_FIX_ROOT: GeometricUid = 0x4749_5041_5554_4f46_0000_0000_0000_0001;
pub const UID_RECURSIVE_BOOT_ROOT: GeometricUid = 0x4749_5052_424f_4f54_0000_0000_0000_0001;
pub const UID_RESOLVE_BUILD_ROOT: GeometricUid = 0x4749_5042_524f_4f54_0000_0000_0000_0001;
pub const UID_HOT_RELOAD_ROOT: GeometricUid = 0x4749_5048_4f54_524c_0000_0000_0000_0001;
pub const UID_SHADOW_TRUTH_SYNC: GeometricUid = 0x4749_5053_4841_444f_0000_0000_0000_0001;

pub const NULL_RUNE: gutf.RuneBytes align(gutf.RUNE_ALIGNMENT) = gutf.deterministicRuneBytes(0, 0x03);
pub const TELEMETRY_RUNE: gutf.RuneBytes align(gutf.RUNE_ALIGNMENT) = gutf.deterministicRuneBytes(1, 0x03);
pub const PAUSE_ORACLE_RUNE: gutf.RuneBytes align(gutf.RUNE_ALIGNMENT) = gutf.deterministicRuneBytes(2, 0x02);
pub const WATCH_LOG_RUNE: gutf.RuneBytes align(gutf.RUNE_ALIGNMENT) = gutf.deterministicRuneBytes(3, 0x03);
pub const ZERO_ALLOC_DSP_RUNE: gutf.RuneBytes align(gutf.RUNE_ALIGNMENT) = gutf.deterministicRuneBytes(4, 0x01);
pub const RUNE_SEARCH_RUNE: gutf.RuneBytes align(gutf.RUNE_ALIGNMENT) = gutf.deterministicRuneBytes(5, 0x03);
pub const RUNE_INJECT_RUNE: gutf.RuneBytes align(gutf.RUNE_ALIGNMENT) = gutf.deterministicRuneBytes(6, 0x04);
pub const RUNE_COMMIT_RUNE: gutf.RuneBytes align(gutf.RUNE_ALIGNMENT) = gutf.deterministicRuneBytes(7, 0x04);
pub const LATTICE_QUERY_RUNE: gutf.RuneBytes align(gutf.RUNE_ALIGNMENT) = gutf.deterministicRuneBytes(14, 0x04);
pub const PATCH_INTEGRITY_RUNE: gutf.RuneBytes align(gutf.RUNE_ALIGNMENT) = gutf.deterministicRuneBytes(15, 0x04);
pub const ORACLE_PROVE_RUNE: gutf.RuneBytes align(gutf.RUNE_ALIGNMENT) = gutf.deterministicRuneBytes(8, 0x02);
pub const AUTO_FIX_RUNE: gutf.RuneBytes align(gutf.RUNE_ALIGNMENT) = gutf.deterministicRuneBytes(9, 0x02);
pub const RECURSIVE_BOOT_RUNE: gutf.RuneBytes align(gutf.RUNE_ALIGNMENT) = gutf.deterministicRuneBytes(10, 0x03);
pub const RESOLVE_BUILD_ROOT_RUNE: gutf.RuneBytes align(gutf.RUNE_ALIGNMENT) = gutf.deterministicRuneBytes(11, 0x04);
pub const HOT_RELOAD_RUNE: gutf.RuneBytes align(gutf.RUNE_ALIGNMENT) = gutf.deterministicRuneBytes(12, 0x03);
pub const SHADOW_TRUTH_SYNC_RUNE: gutf.RuneBytes align(gutf.RUNE_ALIGNMENT) = gutf.deterministicRuneBytes(13, 0x04);

pub const RUNE_MAP = [_]RuneRecord{
    .{ .uid = UID_NULL, .opcode = .GIP_OP_NULL, .tier = .root, .truth_density_per_mille = 1000, .latency_score_us = 0, .domain = .hardware_abstraction, .label = "null_root", .rune = &NULL_RUNE },
    .{ .uid = UID_TELEMETRY_ROOT, .opcode = .GIP_OP_GET_TELEMETRY, .tier = .root, .truth_density_per_mille = 1000, .latency_score_us = 20, .domain = .hardware_abstraction, .label = "machine_state_snapshot", .rune = &TELEMETRY_RUNE },
    .{ .uid = UID_PAUSE_ORACLE_ROOT, .opcode = .GIP_OP_PAUSE_ORACLE, .tier = .root, .truth_density_per_mille = 1000, .latency_score_us = 10, .domain = .logic_verification, .label = "pause_oracle_ram_guard", .rune = &PAUSE_ORACLE_RUNE },
    .{ .uid = UID_WATCH_LOG_ROOT, .opcode = .GIP_OP_WATCH_LOG, .tier = .root, .truth_density_per_mille = 1000, .latency_score_us = 100, .domain = .hardware_abstraction, .label = "watch_log_snapshot", .rune = &WATCH_LOG_RUNE },
    .{ .uid = UID_ZERO_ALLOC_DSP, .opcode = .GIP_OP_DSP_GENERATE, .tier = .verified, .truth_density_per_mille = 1000, .latency_score_us = 420, .domain = .audio_dsp, .label = "zero_allocation_dsp", .rune = &ZERO_ALLOC_DSP_RUNE },
    .{ .uid = UID_RUNE_SEARCH_ROOT, .opcode = .GIP_OP_RUNE_SEARCH, .tier = .root, .truth_density_per_mille = 1000, .latency_score_us = 120, .domain = .hardware_abstraction, .label = "vulkan_hamming_search", .rune = &RUNE_SEARCH_RUNE },
    .{ .uid = UID_RUNE_INJECT_ROOT, .opcode = .GIP_OP_RUNE_INJECT, .tier = .root, .truth_density_per_mille = 1000, .latency_score_us = 300, .domain = .software_engineering, .label = "verified_rune_inject", .rune = &RUNE_INJECT_RUNE },
    .{ .uid = UID_RUNE_COMMIT_ROOT, .opcode = .GIP_OP_RUNE_COMMIT, .tier = .root, .truth_density_per_mille = 1000, .latency_score_us = 300, .domain = .software_engineering, .label = "verified_rune_commit", .rune = &RUNE_COMMIT_RUNE },
    .{ .uid = UID_LATTICE_QUERY_ROOT, .opcode = .GIP_OP_LATTICE_QUERY, .tier = .root, .truth_density_per_mille = 1000, .latency_score_us = 80, .domain = .software_engineering, .label = "lattice_query_vulkan_hamming", .rune = &LATTICE_QUERY_RUNE },
    .{ .uid = UID_PATCH_INTEGRITY_ROOT, .opcode = .GIP_OP_PATCH_INTEGRITY, .tier = .root, .truth_density_per_mille = 1000, .latency_score_us = 160, .domain = .software_engineering, .label = "patch_integrity_telemetry", .rune = &PATCH_INTEGRITY_RUNE },
    .{ .uid = UID_ORACLE_PROVE_ROOT, .opcode = .GIP_OP_ORACLE_PROVE, .tier = .root, .truth_density_per_mille = 1000, .latency_score_us = 450, .domain = .logic_verification, .label = "reality_oracle_prove", .rune = &ORACLE_PROVE_RUNE },
    .{ .uid = UID_AUTO_FIX_ROOT, .opcode = .GIP_OP_AUTO_FIX, .tier = .verified, .truth_density_per_mille = 1000, .latency_score_us = 470, .domain = .logic_verification, .label = "bounded_auto_fix", .rune = &AUTO_FIX_RUNE },
    .{ .uid = UID_RECURSIVE_BOOT_ROOT, .opcode = .GIP_OP_RECURSIVE_BOOT, .tier = .root, .truth_density_per_mille = 1000, .latency_score_us = 200, .domain = .hardware_abstraction, .label = "recursive_boot_measurement", .rune = &RECURSIVE_BOOT_RUNE },
    .{ .uid = UID_RESOLVE_BUILD_ROOT, .opcode = .GIP_OP_RESOLVE_BUILD_ROOT, .tier = .root, .truth_density_per_mille = 1000, .latency_score_us = 150, .domain = .software_engineering, .label = "resolve_build_root", .rune = &RESOLVE_BUILD_ROOT_RUNE },
    .{ .uid = UID_HOT_RELOAD_ROOT, .opcode = .GIP_OP_HOT_RELOAD, .tier = .root, .truth_density_per_mille = 1000, .latency_score_us = 400, .domain = .hardware_abstraction, .label = "hot_reload_dynlib", .rune = &HOT_RELOAD_RUNE },
    .{ .uid = UID_SHADOW_TRUTH_SYNC, .opcode = .GIP_OP_TRUTH_SYNC, .tier = .shadow, .truth_density_per_mille = 700, .latency_score_us = 500, .domain = .software_engineering, .label = "shadow_truth_sync_non_authorizing", .rune = &SHADOW_TRUTH_SYNC_RUNE },
};

pub fn makeHeader(uid: GeometricUid, opcode: GipOpCode, payload_len: usize) !GipHeader {
    if (payload_len > std.math.maxInt(u16)) return error.PayloadTooLarge;
    return .{
        .geometric_uid_hi = @intCast(uid >> 64),
        .geometric_uid_lo = @truncate(uid),
        .opcode = @intFromEnum(opcode),
        .payload_len = @intCast(payload_len),
    };
}

pub fn makePacket(uid: GeometricUid, opcode: GipOpCode, payload: []const u8) !GipPacket {
    return .{ .header = try makeHeader(uid, opcode, payload.len), .payload = payload };
}

pub fn bucketFor(uid: GeometricUid) u8 {
    const hi: u64 = @intCast(uid >> 64);
    const lo: u64 = @truncate(uid);
    const mixed = (hi ^ lo) *% 0x9e37_79b9_7f4a_7c15;
    return @truncate(mixed >> 60);
}

pub fn lookup(uid: GeometricUid, opcode: GipOpCode) ?ResolvedRune {
    const bucket = bucketFor(uid);
    for (RUNE_MAP) |record| {
        if (record.uid == uid and record.opcode == opcode) {
            return .{ .record = record, .bucket = bucket };
        }
    }
    return null;
}

pub fn resolveVerifiedRune(packet: GipPacket) !ResolvedRune {
    const opcode = try packet.opcode();
    const resolved = lookup(packet.header.uid(), opcode) orelse return error.GipSecFault;
    if (!resolved.record.tier.authorizes()) return error.GipSecFault;
    if (resolved.record.truth_density_per_mille < AUTONOMOUS_TRUTH_DENSITY_FLOOR_PER_MILLE) return error.TruthDensityBelowAutonomousThreshold;
    return resolved;
}

pub fn sigilCommandToOpCode(command: []const u8) !GipOpCode {
    if (std.ascii.eqlIgnoreCase(command, "status")) return .GIP_OP_GET_TELEMETRY;
    if (std.ascii.eqlIgnoreCase(command, "inject")) return .GIP_OP_RUNE_INJECT;
    if (std.ascii.eqlIgnoreCase(command, "reload") or std.ascii.eqlIgnoreCase(command, "reload-plugin")) return .GIP_OP_HOT_RELOAD;
    if (std.ascii.eqlIgnoreCase(command, "watch")) return .GIP_OP_WATCH_LOG;
    if (std.ascii.eqlIgnoreCase(command, "commit")) return .GIP_OP_RUNE_COMMIT;
    return error.UnknownSigilCommand;
}

pub fn uidForSigilCommand(command: []const u8) !GeometricUid {
    const opcode = try sigilCommandToOpCode(command);
    return switch (opcode) {
        .GIP_OP_GET_TELEMETRY => UID_TELEMETRY_ROOT,
        .GIP_OP_RUNE_INJECT => UID_RUNE_INJECT_ROOT,
        .GIP_OP_HOT_RELOAD => UID_HOT_RELOAD_ROOT,
        .GIP_OP_WATCH_LOG => UID_WATCH_LOG_ROOT,
        .GIP_OP_RUNE_COMMIT => UID_RUNE_COMMIT_ROOT,
        else => error.UnknownSigilCommand,
    };
}

pub fn packetForSigilCommand(command: []const u8, payload: []const u8) !GipPacket {
    const opcode = try sigilCommandToOpCode(command);
    return makePacket(try uidForSigilCommand(command), opcode, payload);
}

pub fn pauseSignalIfPressured(snapshot: MachineSnapshot) ?GipSignal {
    if (!snapshot.shouldPauseOracle()) return null;
    return .{
        .opcode = .GIP_OP_PAUSE_ORACLE,
        .uid = UID_PAUSE_ORACLE_ROOT,
        .target_latency_ns = PAUSE_SIGNAL_LATENCY_TARGET_NS,
        .snapshot = snapshot,
    };
}

pub fn shouldRecordSnapshot(last_snapshot_ns: u64, now_ns: u64) bool {
    return now_ns >= last_snapshot_ns and now_ns - last_snapshot_ns >= SNAPSHOT_INTERVAL_NS;
}

pub fn makeGpuSearchHandshake(query: gutf.RuneView) !GpuSearchHandshake {
    const packet = try makePacket(UID_RUNE_SEARCH_ROOT, .GIP_OP_RUNE_SEARCH, query.bytes);
    _ = try resolveVerifiedRune(packet);
    return .{ .packet = packet, .query = query };
}

pub fn makeLatticeQueryHandshake(query: gutf.RuneView) !GpuSearchHandshake {
    const packet = try makePacket(UID_LATTICE_QUERY_ROOT, .GIP_OP_LATTICE_QUERY, query.bytes);
    _ = try resolveVerifiedRune(packet);
    return .{ .packet = packet, .query = query };
}

pub fn makePatchIntegrityHandshake(payload: []const u8) !GipPacket {
    const packet = try makePacket(UID_PATCH_INTEGRITY_ROOT, .GIP_OP_PATCH_INTEGRITY, payload);
    _ = try resolveVerifiedRune(packet);
    return packet;
}

test "GIP opcode values match deterministic neural bus contract" {
    try std.testing.expectEqual(@as(u8, 0x00), @intFromEnum(GipOpCode.GIP_OP_NULL));
    try std.testing.expectEqual(@as(u8, 0x01), @intFromEnum(GipOpCode.GIP_OP_GET_TELEMETRY));
    try std.testing.expectEqual(@as(u8, 0x1F), @intFromEnum(GipOpCode.GIP_OP_SEC_FAULT));
    try std.testing.expectEqual(@as(u8, 0x80), @intFromEnum(GipOpCode.GIP_OP_RUNE_SEARCH));
    try std.testing.expectEqual(@as(u8, 0x81), @intFromEnum(GipOpCode.GIP_OP_RUNE_INJECT));
    try std.testing.expectEqual(@as(u8, 0x82), @intFromEnum(GipOpCode.GIP_OP_TRUTH_SYNC));
    try std.testing.expectEqual(@as(u8, 0x86), @intFromEnum(GipOpCode.GIP_OP_LATTICE_QUERY));
    try std.testing.expectEqual(@as(u8, 0x87), @intFromEnum(GipOpCode.GIP_OP_PATCH_INTEGRITY));
    try std.testing.expectEqual(@as(u8, 0x89), @intFromEnum(GipOpCode.GIP_OP_LANDLOCK_STRICT));
    try std.testing.expectEqual(@as(u8, 0xA0), @intFromEnum(GipOpCode.GIP_OP_ORACLE_PROVE));
    try std.testing.expectEqual(@as(u8, 0xA1), @intFromEnum(GipOpCode.GIP_OP_AUTO_FIX));
    try std.testing.expectEqual(@as(u8, 0xAF), @intFromEnum(GipOpCode.GIP_OP_RECURSIVE_BOOT));
    try std.testing.expectEqual(@as(u8, 0xB1), @intFromEnum(GipOpCode.GIP_OP_RESOLVE_BUILD_ROOT));
    try std.testing.expectEqual(@as(u8, 0xC0), @intFromEnum(GipOpCode.GIP_OP_DSP_GENERATE));
    try std.testing.expectEqual(@as(u8, 0xC1), @intFromEnum(GipOpCode.GIP_OP_HOT_RELOAD));
}

test "sigil commands map to unique GIP opcodes" {
    try std.testing.expectEqual(GipOpCode.GIP_OP_RUNE_INJECT, try sigilCommandToOpCode("inject"));
    try std.testing.expectEqual(GipOpCode.GIP_OP_GET_TELEMETRY, try sigilCommandToOpCode("status"));
    try std.testing.expectEqual(GipOpCode.GIP_OP_HOT_RELOAD, try sigilCommandToOpCode("reload"));
    try std.testing.expectEqual(GipOpCode.GIP_OP_WATCH_LOG, try sigilCommandToOpCode("watch"));
    try std.testing.expectEqual(GipOpCode.GIP_OP_RUNE_COMMIT, try sigilCommandToOpCode("commit"));
    try std.testing.expectError(error.UnknownSigilCommand, sigilCommandToOpCode("chat"));
}

test "unverified or missing rune mapping sec-faults" {
    const missing = try makePacket(0xdead, .GIP_OP_DSP_GENERATE, "");
    try std.testing.expectError(error.GipSecFault, resolveVerifiedRune(missing));

    const shadow = try makePacket(UID_SHADOW_TRUTH_SYNC, .GIP_OP_TRUTH_SYNC, "");
    try std.testing.expectError(error.GipSecFault, resolveVerifiedRune(shadow));
}

test "verified DSP rune can enter Zenith bridge only at full truth density and latency budget" {
    const packet = try makePacket(UID_ZERO_ALLOC_DSP, .GIP_OP_DSP_GENERATE, "");
    const resolved = try resolveVerifiedRune(packet);
    try std.testing.expectEqualStrings("zero_allocation_dsp", resolved.record.label);
    try std.testing.expect(resolved.record.canEnterZenithBridge());
    const view = resolved.record.runeView();
    try std.testing.expectEqual(gutf.ByteClass.hyper_bitstream, gutf.classifyByte(view.bytes[0]));
}

test "16GB guard emits pause signal at 14GB pressure and snapshots every 10ms" {
    const low = MachineSnapshot{ .monotonic_ns = 0, .ram_used_bytes = 8 * 1024 * 1024 * 1024, .cpu_load_per_mille = 200 };
    try std.testing.expect(pauseSignalIfPressured(low) == null);
    const high = MachineSnapshot{ .monotonic_ns = 10, .ram_used_bytes = ORACLE_PAUSE_THRESHOLD_BYTES, .cpu_load_per_mille = 900 };
    const signal = pauseSignalIfPressured(high).?;
    try std.testing.expectEqual(GipOpCode.GIP_OP_PAUSE_ORACLE, signal.opcode);
    try std.testing.expectEqual(@as(u64, PAUSE_SIGNAL_LATENCY_TARGET_NS), signal.target_latency_ns);
    try std.testing.expect(!shouldRecordSnapshot(100, 100 + SNAPSHOT_INTERVAL_NS - 1));
    try std.testing.expect(shouldRecordSnapshot(100, 100 + SNAPSHOT_INTERVAL_NS));
}

test "GPU search handshake carries rune query as packet payload without copy" {
    var query_storage: gutf.RuneBytes align(gutf.RUNE_ALIGNMENT) = gutf.deterministicRuneBytes(44, 0x03);
    const query = gutf.viewRuneBlock(&query_storage);
    const handshake = try makeGpuSearchHandshake(query);
    try std.testing.expectEqual(@intFromPtr(&query_storage), @intFromPtr(handshake.packet.payload.ptr));
    try std.testing.expectEqual(GipOpCode.GIP_OP_RUNE_SEARCH, try handshake.packet.opcode());
    try std.testing.expectEqualStrings("src/gpu/search.comp", handshake.shader_path);
}

test "lattice query handshake uses opcode 0x86" {
    var query_storage: gutf.RuneBytes align(gutf.RUNE_ALIGNMENT) = gutf.deterministicRuneBytes(86, 0x04);
    const query = gutf.viewRuneBlock(&query_storage);
    const handshake = try makeLatticeQueryHandshake(query);
    try std.testing.expectEqual(GipOpCode.GIP_OP_LATTICE_QUERY, try handshake.packet.opcode());
    try std.testing.expectEqualStrings("lattice_query_vulkan_hamming", (try resolveVerifiedRune(handshake.packet)).record.label);
}

test "patch integrity handshake uses opcode 0x87" {
    const packet = try makePatchIntegrityHandshake("git apply --check");
    try std.testing.expectEqual(GipOpCode.GIP_OP_PATCH_INTEGRITY, try packet.opcode());
    try std.testing.expectEqualStrings("patch_integrity_telemetry", (try resolveVerifiedRune(packet)).record.label);
}
