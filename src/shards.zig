const std = @import("std");
const config = @import("config.zig");
const ghost_state = @import("ghost_state.zig");
const sys = @import("sys.zig");
const vsa = @import("vsa_core.zig");

pub const DEFAULT_PROJECT_ID = "default";

/// Layer 1 substrate kinds. Core and project are the committed shard types the
/// runtime mounts directly. Scratch behavior is shard-local and transient.
pub const Kind = enum {
    core,
    project,
    scratch,
};

pub const Ownership = struct {
    kind: Kind,
    id: []const u8,
};

pub const Metadata = struct {
    kind: Kind,
    id: []const u8,
    owner: ?Ownership,
    rel_root: []const u8,

    pub fn hasCommittedState(self: Metadata) bool {
        return self.kind != .scratch;
    }
};

pub const OwnedMetadata = struct {
    allocator: std.mem.Allocator,
    metadata: Metadata,
    owned_id: []u8,
    owned_rel_root: []u8,
    owned_owner_id: ?[]u8 = null,

    pub fn deinit(self: *OwnedMetadata) void {
        self.allocator.free(self.owned_id);
        self.allocator.free(self.owned_rel_root);
        if (self.owned_owner_id) |owner_id| self.allocator.free(owner_id);
        self.* = undefined;
    }
};

pub const Paths = struct {
    allocator: std.mem.Allocator,
    metadata: Metadata,
    owned_id: []u8,
    owned_rel_root: []u8,
    owned_owner_id: ?[]u8 = null,
    root_abs_path: []u8,
    lattice_abs_path: []u8,
    semantic_abs_path: []u8,
    tags_abs_path: []u8,
    sigil_root_abs_path: []u8,
    sigil_scratch_abs_path: []u8,
    sigil_committed_abs_path: []u8,
    sigil_snapshot_abs_path: []u8,
    abstractions_root_abs_path: []u8,
    abstractions_live_abs_path: []u8,
    abstractions_staged_abs_path: []u8,
    code_intel_root_abs_path: []u8,
    code_intel_cache_abs_path: []u8,
    patch_candidates_root_abs_path: []u8,
    patch_candidates_staged_abs_path: []u8,
    scratch_file_prefix: []u8,

    pub fn deinit(self: *Paths) void {
        self.allocator.free(self.owned_id);
        self.allocator.free(self.owned_rel_root);
        if (self.owned_owner_id) |owner_id| self.allocator.free(owner_id);
        self.allocator.free(self.root_abs_path);
        self.allocator.free(self.lattice_abs_path);
        self.allocator.free(self.semantic_abs_path);
        self.allocator.free(self.tags_abs_path);
        self.allocator.free(self.sigil_root_abs_path);
        self.allocator.free(self.sigil_scratch_abs_path);
        self.allocator.free(self.sigil_committed_abs_path);
        self.allocator.free(self.sigil_snapshot_abs_path);
        self.allocator.free(self.abstractions_root_abs_path);
        self.allocator.free(self.abstractions_live_abs_path);
        self.allocator.free(self.abstractions_staged_abs_path);
        self.allocator.free(self.code_intel_root_abs_path);
        self.allocator.free(self.code_intel_cache_abs_path);
        self.allocator.free(self.patch_candidates_root_abs_path);
        self.allocator.free(self.patch_candidates_staged_abs_path);
        self.allocator.free(self.scratch_file_prefix);
        self.* = undefined;
    }
};

/// Mounted Layer 1 state for one committed shard. Scratch-only behavior is
/// attached separately through the scratchpad overlay and Sigil snapshot flow.
pub const MountedStateShard = struct {
    allocator: std.mem.Allocator,
    paths: Paths,
    paged_lattice: ghost_state.PagedLatticeProvider,
    semantic_file: sys.MappedFile,
    tags_file: sys.MappedFile,
    meaning_words: []u32,
    tags_words: []u64,
    meaning_matrix: vsa.MeaningMatrix,

    pub fn mount(allocator: std.mem.Allocator, metadata: Metadata, cache_cap_bytes: usize) !MountedStateShard {
        if (!metadata.hasCommittedState()) return error.ScratchShardHasNoCommittedState;

        var paths = try resolvePaths(allocator, metadata);
        errdefer paths.deinit();

        var paged_lattice = try ghost_state.PagedLatticeProvider.init(allocator, paths.lattice_abs_path, cache_cap_bytes);
        errdefer paged_lattice.deinit();

        var semantic_file = try sys.createMappedFile(allocator, paths.semantic_abs_path, config.SEMANTIC_SIZE_BYTES);
        errdefer semantic_file.unmap();

        var tags_file = try sys.createMappedFile(allocator, paths.tags_abs_path, config.TAG_SIZE_BYTES);
        errdefer tags_file.unmap();

        return .{
            .allocator = allocator,
            .paths = paths,
            .paged_lattice = paged_lattice,
            .semantic_file = semantic_file,
            .tags_file = tags_file,
            .meaning_words = @as([*]u32, @ptrCast(@alignCast(semantic_file.data.ptr)))[0..config.SEMANTIC_ENTRIES],
            .tags_words = @as([*]u64, @ptrCast(@alignCast(tags_file.data.ptr)))[0..config.TAG_ENTRIES],
            .meaning_matrix = .{
                .data = @as([*]u32, @ptrCast(@alignCast(semantic_file.data.ptr)))[0..config.SEMANTIC_ENTRIES],
                .tags = @as([*]u64, @ptrCast(@alignCast(tags_file.data.ptr)))[0..config.TAG_ENTRIES],
            },
        };
    }

    pub fn mountCore(allocator: std.mem.Allocator, cache_cap_bytes: usize) !MountedStateShard {
        var metadata = try resolveCoreMetadata(allocator);
        defer metadata.deinit();
        return mount(allocator, metadata.metadata, cache_cap_bytes);
    }

    pub fn mountProject(allocator: std.mem.Allocator, raw_id: []const u8, cache_cap_bytes: usize) !MountedStateShard {
        var metadata = try resolveProjectMetadata(allocator, raw_id);
        defer metadata.deinit();
        return mount(allocator, metadata.metadata, cache_cap_bytes);
    }

    pub fn latticeProvider(self: *MountedStateShard) ghost_state.LatticeProvider {
        return ghost_state.LatticeProvider.initPaged(&self.paged_lattice);
    }

    pub fn deinit(self: *MountedStateShard) void {
        self.semantic_file.unmap();
        self.tags_file.unmap();
        self.paged_lattice.deinit();
        self.paths.deinit();
        self.* = undefined;
    }
};

pub fn resolveCoreMetadata(allocator: std.mem.Allocator) !OwnedMetadata {
    const owned_id = try allocator.dupe(u8, "core");
    errdefer allocator.free(owned_id);
    const rel_root = try allocator.dupe(u8, config.CORE_SHARD_REL_DIR);
    errdefer allocator.free(rel_root);

    return .{
        .allocator = allocator,
        .metadata = .{
            .kind = .core,
            .id = owned_id,
            .owner = null,
            .rel_root = rel_root,
        },
        .owned_id = owned_id,
        .owned_rel_root = rel_root,
    };
}

pub fn resolveProjectMetadata(allocator: std.mem.Allocator, raw_id: []const u8) !OwnedMetadata {
    const owned_id = try sanitizeShardId(allocator, raw_id, DEFAULT_PROJECT_ID);
    errdefer allocator.free(owned_id);
    const rel_root = try std.fs.path.join(allocator, &.{ config.PROJECT_SHARD_REL_DIR, owned_id });
    errdefer allocator.free(rel_root);

    return .{
        .allocator = allocator,
        .metadata = .{
            .kind = .project,
            .id = owned_id,
            .owner = null,
            .rel_root = rel_root,
        },
        .owned_id = owned_id,
        .owned_rel_root = rel_root,
    };
}

pub fn resolveScratchMetadata(allocator: std.mem.Allocator, owner: Metadata) !OwnedMetadata {
    const owned_id = try allocator.dupe(u8, "scratch");
    errdefer allocator.free(owned_id);
    const rel_root = try std.fs.path.join(allocator, &.{ owner.rel_root, "scratch" });
    errdefer allocator.free(rel_root);
    const owner_id = try allocator.dupe(u8, owner.id);
    errdefer allocator.free(owner_id);

    return .{
        .allocator = allocator,
        .metadata = .{
            .kind = .scratch,
            .id = owned_id,
            .owner = .{
                .kind = owner.kind,
                .id = owner_id,
            },
            .rel_root = rel_root,
        },
        .owned_id = owned_id,
        .owned_rel_root = rel_root,
        .owned_owner_id = owner_id,
    };
}

pub fn resolveDefaultProjectMetadata(allocator: std.mem.Allocator) !OwnedMetadata {
    const env = std.process.getEnvVarOwned(allocator, "GHOST_PROJECT_SHARD") catch null;
    defer if (env) |value| allocator.free(value);
    return resolveProjectMetadata(allocator, if (env) |value| value else DEFAULT_PROJECT_ID);
}

pub fn resolvePaths(allocator: std.mem.Allocator, metadata: Metadata) !Paths {
    if (!metadata.hasCommittedState()) return error.ScratchShardHasNoCommittedState;

    const owned_id = try allocator.dupe(u8, metadata.id);
    errdefer allocator.free(owned_id);
    const owned_rel_root = try allocator.dupe(u8, metadata.rel_root);
    errdefer allocator.free(owned_rel_root);
    const owned_owner_id = if (metadata.owner) |owner|
        try allocator.dupe(u8, owner.id)
    else
        null;
    errdefer if (owned_owner_id) |owner_id| allocator.free(owner_id);

    const root_abs = try config.getPath(allocator, metadata.rel_root);
    errdefer allocator.free(root_abs);

    const lattice_rel = try std.fs.path.join(allocator, &.{ metadata.rel_root, config.LATTICE_FILE_NAME });
    defer allocator.free(lattice_rel);
    const semantic_rel = try std.fs.path.join(allocator, &.{ metadata.rel_root, config.SEMANTIC_FILE_NAME });
    defer allocator.free(semantic_rel);
    const tags_rel = try std.fs.path.join(allocator, &.{ metadata.rel_root, config.TAG_FILE_NAME });
    defer allocator.free(tags_rel);
    const sigil_rel = try std.fs.path.join(allocator, &.{ metadata.rel_root, "sigil" });
    defer allocator.free(sigil_rel);
    const scratch_rel = try std.fs.path.join(allocator, &.{ sigil_rel, "scratch" });
    defer allocator.free(scratch_rel);
    const committed_rel = try std.fs.path.join(allocator, &.{ sigil_rel, "committed" });
    defer allocator.free(committed_rel);
    const snapshot_rel = try std.fs.path.join(allocator, &.{ sigil_rel, "snapshot" });
    defer allocator.free(snapshot_rel);
    const abstractions_root_rel = try std.fs.path.join(allocator, &.{ metadata.rel_root, config.ABSTRACTIONS_REL_DIR_NAME });
    defer allocator.free(abstractions_root_rel);
    const abstractions_live_rel = try std.fs.path.join(allocator, &.{ abstractions_root_rel, config.ABSTRACTION_CATALOG_FILE_NAME });
    defer allocator.free(abstractions_live_rel);
    const abstractions_staged_rel = try std.fs.path.join(allocator, &.{ abstractions_root_rel, config.ABSTRACTION_STAGED_FILE_NAME });
    defer allocator.free(abstractions_staged_rel);
    const code_intel_root_rel = try std.fs.path.join(allocator, &.{ metadata.rel_root, "code_intel" });
    defer allocator.free(code_intel_root_rel);
    const code_intel_cache_rel = try std.fs.path.join(allocator, &.{ code_intel_root_rel, "cache" });
    defer allocator.free(code_intel_cache_rel);
    const patch_candidates_root_rel = try std.fs.path.join(allocator, &.{ metadata.rel_root, config.PATCH_CANDIDATE_REL_DIR_NAME });
    defer allocator.free(patch_candidates_root_rel);
    const patch_candidates_staged_rel = try std.fs.path.join(allocator, &.{ patch_candidates_root_rel, config.PATCH_CANDIDATE_STAGED_FILE_NAME });
    defer allocator.free(patch_candidates_staged_rel);

    const scratch_prefix = try std.fmt.allocPrint(allocator, "ghost-scratch-{s}-{s}", .{
        @tagName(metadata.kind),
        metadata.id,
    });
    errdefer allocator.free(scratch_prefix);

    return .{
        .allocator = allocator,
        .metadata = .{
            .kind = metadata.kind,
            .id = owned_id,
            .owner = if (metadata.owner) |owner|
                .{
                    .kind = owner.kind,
                    .id = owned_owner_id.?,
                }
            else
                null,
            .rel_root = owned_rel_root,
        },
        .owned_id = owned_id,
        .owned_rel_root = owned_rel_root,
        .owned_owner_id = owned_owner_id,
        .root_abs_path = root_abs,
        .lattice_abs_path = try config.getPath(allocator, lattice_rel),
        .semantic_abs_path = try config.getPath(allocator, semantic_rel),
        .tags_abs_path = try config.getPath(allocator, tags_rel),
        .sigil_root_abs_path = try config.getPath(allocator, sigil_rel),
        .sigil_scratch_abs_path = try config.getPath(allocator, scratch_rel),
        .sigil_committed_abs_path = try config.getPath(allocator, committed_rel),
        .sigil_snapshot_abs_path = try config.getPath(allocator, snapshot_rel),
        .abstractions_root_abs_path = try config.getPath(allocator, abstractions_root_rel),
        .abstractions_live_abs_path = try config.getPath(allocator, abstractions_live_rel),
        .abstractions_staged_abs_path = try config.getPath(allocator, abstractions_staged_rel),
        .code_intel_root_abs_path = try config.getPath(allocator, code_intel_root_rel),
        .code_intel_cache_abs_path = try config.getPath(allocator, code_intel_cache_rel),
        .patch_candidates_root_abs_path = try config.getPath(allocator, patch_candidates_root_rel),
        .patch_candidates_staged_abs_path = try config.getPath(allocator, patch_candidates_staged_rel),
        .scratch_file_prefix = scratch_prefix,
    };
}

fn sanitizeShardId(allocator: std.mem.Allocator, raw_id: []const u8, fallback: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, raw_id, " \r\n\t/");
    const source = if (trimmed.len == 0) fallback else trimmed;

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();

    for (source) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.') {
            try out.append(std.ascii.toLower(byte));
        } else {
            try out.append('_');
        }
    }

    while (out.items.len > 0 and out.items[0] == '_') {
        _ = out.orderedRemove(0);
    }
    while (out.items.len > 0 and out.items[out.items.len - 1] == '_') {
        _ = out.pop();
    }
    if (out.items.len == 0) {
        try out.appendSlice(fallback);
    }

    return out.toOwnedSlice();
}
