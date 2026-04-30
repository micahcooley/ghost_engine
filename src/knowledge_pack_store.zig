const std = @import("std");
const config = @import("config.zig");
const shards = @import("shards.zig");
const sys = @import("sys.zig");

pub const PACK_SCHEMA_VERSION = "ghost_knowledge_pack_v1";
pub const MOUNT_SCHEMA_VERSION = "ghost_knowledge_pack_mounts_v1";
pub const MOUNT_PREFIX = "@pack";
const MAX_PREVIEW_ITEMS: usize = 16;

pub const SourceState = enum {
    staged,
    live,
};

pub const PackFreshness = enum {
    active,
    stale,
};

pub const Compatibility = struct {
    engine_version: []u8,
    linux_first: bool = true,
    deterministic_only: bool = true,
    mount_schema: []u8,

    pub fn deinit(self: *Compatibility, allocator: std.mem.Allocator) void {
        allocator.free(self.engine_version);
        allocator.free(self.mount_schema);
        self.* = undefined;
    }
};

pub const StorageLayout = struct {
    corpus_manifest_rel_path: []u8,
    corpus_files_rel_path: []u8,
    abstraction_catalog_rel_path: []u8,
    reuse_catalog_rel_path: []u8,
    lineage_state_rel_path: []u8,
    influence_manifest_rel_path: []u8,
    autopsy_guidance_rel_path: ?[]u8 = null,

    pub fn deinit(self: *StorageLayout, allocator: std.mem.Allocator) void {
        allocator.free(self.corpus_manifest_rel_path);
        allocator.free(self.corpus_files_rel_path);
        allocator.free(self.abstraction_catalog_rel_path);
        allocator.free(self.reuse_catalog_rel_path);
        allocator.free(self.lineage_state_rel_path);
        allocator.free(self.influence_manifest_rel_path);
        if (self.autopsy_guidance_rel_path) |path| allocator.free(path);
        self.* = undefined;
    }
};

pub const Provenance = struct {
    pack_lineage_id: []u8,
    source_kind: []u8,
    source_id: []u8,
    source_state: SourceState,
    freshness_state: PackFreshness,
    source_summary: []u8,
    source_lineage_summary: []u8,

    pub fn deinit(self: *Provenance, allocator: std.mem.Allocator) void {
        allocator.free(self.pack_lineage_id);
        allocator.free(self.source_kind);
        allocator.free(self.source_id);
        allocator.free(self.source_summary);
        allocator.free(self.source_lineage_summary);
        self.* = undefined;
    }
};

pub const ContentSummary = struct {
    corpus_item_count: u32 = 0,
    concept_count: u32 = 0,
    corpus_hash: u64 = 0,
    abstraction_hash: u64 = 0,
    reuse_hash: u64 = 0,
    lineage_hash: u64 = 0,
    corpus_preview: [][]u8 = &.{},
    concept_preview: [][]u8 = &.{},

    pub fn deinit(self: *ContentSummary, allocator: std.mem.Allocator) void {
        for (self.corpus_preview) |item| allocator.free(item);
        allocator.free(self.corpus_preview);
        for (self.concept_preview) |item| allocator.free(item);
        allocator.free(self.concept_preview);
        self.* = undefined;
    }
};

pub const Manifest = struct {
    allocator: std.mem.Allocator,
    schema_version: []u8,
    pack_id: []u8,
    pack_version: []u8,
    domain_family: []u8,
    trust_class: []u8,
    compatibility: Compatibility,
    storage: StorageLayout,
    provenance: Provenance,
    content: ContentSummary,

    pub fn deinit(self: *Manifest) void {
        self.allocator.free(self.schema_version);
        self.allocator.free(self.pack_id);
        self.allocator.free(self.pack_version);
        self.allocator.free(self.domain_family);
        self.allocator.free(self.trust_class);
        self.compatibility.deinit(self.allocator);
        self.storage.deinit(self.allocator);
        self.provenance.deinit(self.allocator);
        self.content.deinit(self.allocator);
        self.* = undefined;
    }
};

pub const MountEntry = struct {
    allocator: std.mem.Allocator,
    pack_id: []u8,
    pack_version: []u8,
    enabled: bool = true,

    pub fn deinit(self: *MountEntry) void {
        self.allocator.free(self.pack_id);
        self.allocator.free(self.pack_version);
        self.* = undefined;
    }
};

pub const MountRegistry = struct {
    allocator: std.mem.Allocator,
    version: []u8,
    entries: []MountEntry,

    pub fn deinit(self: *MountRegistry) void {
        self.allocator.free(self.version);
        for (self.entries) |*entry| entry.deinit();
        self.allocator.free(self.entries);
        self.* = undefined;
    }
};

pub const ResolvedMount = struct {
    allocator: std.mem.Allocator,
    entry: MountEntry,
    manifest: Manifest,
    root_abs_path: []u8,
    manifest_abs_path: []u8,
    corpus_manifest_abs_path: []u8,
    corpus_files_abs_path: []u8,
    abstraction_catalog_abs_path: []u8,
    reuse_catalog_abs_path: []u8,
    lineage_state_abs_path: []u8,
    influence_manifest_abs_path: []u8,
    autopsy_guidance_abs_path: ?[]u8 = null,

    pub fn ownerId(self: *const ResolvedMount, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "pack/{s}@{s}", .{ self.entry.pack_id, self.entry.pack_version });
    }

    pub fn mountPrefix(self: *const ResolvedMount, allocator: std.mem.Allocator) ![]u8 {
        return mountPrefixFor(allocator, self.entry.pack_id, self.entry.pack_version);
    }

    pub fn deinit(self: *ResolvedMount) void {
        self.entry.deinit();
        self.manifest.deinit();
        self.allocator.free(self.root_abs_path);
        self.allocator.free(self.manifest_abs_path);
        self.allocator.free(self.corpus_manifest_abs_path);
        self.allocator.free(self.corpus_files_abs_path);
        self.allocator.free(self.abstraction_catalog_abs_path);
        self.allocator.free(self.reuse_catalog_abs_path);
        self.allocator.free(self.lineage_state_abs_path);
        self.allocator.free(self.influence_manifest_abs_path);
        if (self.autopsy_guidance_abs_path) |path| self.allocator.free(path);
        self.* = undefined;
    }
};

pub fn sanitizePackId(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    return sanitizeToken(allocator, raw, "pack");
}

pub fn sanitizeVersion(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    return sanitizeToken(allocator, raw, "v1");
}

pub fn mountPrefixFor(allocator: std.mem.Allocator, pack_id: []const u8, pack_version: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ MOUNT_PREFIX, pack_id, pack_version });
}

pub fn globalRootAbsPath(allocator: std.mem.Allocator) ![]u8 {
    return config.getPath(allocator, config.STATE_SUBDIR ++ "/knowledge_packs");
}

pub fn packsRootAbsPath(allocator: std.mem.Allocator) ![]u8 {
    const global_root = try globalRootAbsPath(allocator);
    defer allocator.free(global_root);
    return std.fs.path.join(allocator, &.{ global_root, "packs" });
}

pub fn packRootAbsPath(allocator: std.mem.Allocator, pack_id: []const u8, pack_version: []const u8) ![]u8 {
    const packs_root = try packsRootAbsPath(allocator);
    defer allocator.free(packs_root);
    return std.fs.path.join(allocator, &.{ packs_root, pack_id, pack_version });
}

pub fn manifestAbsPath(allocator: std.mem.Allocator, pack_id: []const u8, pack_version: []const u8) ![]u8 {
    const root = try packRootAbsPath(allocator, pack_id, pack_version);
    defer allocator.free(root);
    return std.fs.path.join(allocator, &.{ root, "manifest.json" });
}

pub fn mountRegistryAbsPath(allocator: std.mem.Allocator, paths: *const shards.Paths) ![]u8 {
    return std.fs.path.join(allocator, &.{ paths.root_abs_path, "knowledge_packs", "mounts.json" });
}

pub fn loadManifest(allocator: std.mem.Allocator, pack_id: []const u8, pack_version: []const u8) !Manifest {
    const abs_path = try manifestAbsPath(allocator, pack_id, pack_version);
    defer allocator.free(abs_path);
    return loadManifestFromPath(allocator, abs_path);
}

pub fn loadManifestFromPath(allocator: std.mem.Allocator, abs_path: []const u8) !Manifest {
    const bytes = try readFileAbsoluteAlloc(allocator, abs_path, 512 * 1024);
    defer allocator.free(bytes);

    const DiskCompatibility = struct {
        engineVersion: []const u8,
        linuxFirst: bool,
        deterministicOnly: bool,
        mountSchema: []const u8,
    };
    const DiskStorage = struct {
        corpusManifestRelPath: []const u8,
        corpusFilesRelPath: []const u8,
        abstractionCatalogRelPath: []const u8,
        reuseCatalogRelPath: []const u8,
        lineageStateRelPath: []const u8,
        influenceManifestRelPath: []const u8,
        autopsyGuidanceRelPath: ?[]const u8 = null,
        autopsy_guidance_rel_path: ?[]const u8 = null,
    };
    const DiskProvenance = struct {
        packLineageId: []const u8,
        sourceKind: []const u8,
        sourceId: []const u8,
        sourceState: []const u8,
        freshnessState: ?[]const u8 = null,
        sourceSummary: []const u8,
        sourceLineageSummary: []const u8,
    };
    const DiskContent = struct {
        corpusItemCount: u32,
        conceptCount: u32,
        corpusHash: u64,
        abstractionHash: u64,
        reuseHash: u64,
        lineageHash: u64,
        corpusPreview: []const []const u8,
        conceptPreview: []const []const u8,
    };
    const DiskManifest = struct {
        schemaVersion: []const u8,
        packId: []const u8,
        packVersion: []const u8,
        domainFamily: []const u8,
        trustClass: []const u8,
        compatibility: DiskCompatibility,
        storage: DiskStorage,
        provenance: DiskProvenance,
        content: DiskContent,
    };

    const parsed = try std.json.parseFromSlice(DiskManifest, allocator, bytes, .{});
    defer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.schemaVersion, PACK_SCHEMA_VERSION)) return error.InvalidKnowledgePackManifest;
    const manifest_dir = std.fs.path.dirname(abs_path) orelse return error.InvalidKnowledgePackManifest;
    const autopsy_guidance_rel_path = guidanceRelPathFromDiskStorage(parsed.value.storage) catch return error.InvalidKnowledgePackManifest;
    try validateStorageLayout(allocator, manifest_dir, parsed.value.storage);

    return .{
        .allocator = allocator,
        .schema_version = try allocator.dupe(u8, parsed.value.schemaVersion),
        .pack_id = try allocator.dupe(u8, parsed.value.packId),
        .pack_version = try allocator.dupe(u8, parsed.value.packVersion),
        .domain_family = try allocator.dupe(u8, parsed.value.domainFamily),
        .trust_class = try allocator.dupe(u8, parsed.value.trustClass),
        .compatibility = .{
            .engine_version = try allocator.dupe(u8, parsed.value.compatibility.engineVersion),
            .linux_first = parsed.value.compatibility.linuxFirst,
            .deterministic_only = parsed.value.compatibility.deterministicOnly,
            .mount_schema = try allocator.dupe(u8, parsed.value.compatibility.mountSchema),
        },
        .storage = .{
            .corpus_manifest_rel_path = try allocator.dupe(u8, parsed.value.storage.corpusManifestRelPath),
            .corpus_files_rel_path = try allocator.dupe(u8, parsed.value.storage.corpusFilesRelPath),
            .abstraction_catalog_rel_path = try allocator.dupe(u8, parsed.value.storage.abstractionCatalogRelPath),
            .reuse_catalog_rel_path = try allocator.dupe(u8, parsed.value.storage.reuseCatalogRelPath),
            .lineage_state_rel_path = try allocator.dupe(u8, parsed.value.storage.lineageStateRelPath),
            .influence_manifest_rel_path = try allocator.dupe(u8, parsed.value.storage.influenceManifestRelPath),
            .autopsy_guidance_rel_path = if (autopsy_guidance_rel_path) |path| try allocator.dupe(u8, path) else null,
        },
        .provenance = .{
            .pack_lineage_id = try allocator.dupe(u8, parsed.value.provenance.packLineageId),
            .source_kind = try allocator.dupe(u8, parsed.value.provenance.sourceKind),
            .source_id = try allocator.dupe(u8, parsed.value.provenance.sourceId),
            .source_state = parseSourceState(parsed.value.provenance.sourceState) orelse return error.InvalidKnowledgePackManifest,
            .freshness_state = if (parsed.value.provenance.freshnessState) |value|
                (parsePackFreshness(value) orelse return error.InvalidKnowledgePackManifest)
            else
                .active,
            .source_summary = try allocator.dupe(u8, parsed.value.provenance.sourceSummary),
            .source_lineage_summary = try allocator.dupe(u8, parsed.value.provenance.sourceLineageSummary),
        },
        .content = .{
            .corpus_item_count = parsed.value.content.corpusItemCount,
            .concept_count = parsed.value.content.conceptCount,
            .corpus_hash = parsed.value.content.corpusHash,
            .abstraction_hash = parsed.value.content.abstractionHash,
            .reuse_hash = parsed.value.content.reuseHash,
            .lineage_hash = parsed.value.content.lineageHash,
            .corpus_preview = try cloneSlice(allocator, parsed.value.content.corpusPreview),
            .concept_preview = try cloneSlice(allocator, parsed.value.content.conceptPreview),
        },
    };
}

pub fn saveManifest(allocator: std.mem.Allocator, root_abs_path: []const u8, manifest: *const Manifest) !void {
    try sys.makePath(allocator, root_abs_path);
    const abs_path = try std.fs.path.join(allocator, &.{ root_abs_path, "manifest.json" });
    defer allocator.free(abs_path);

    var out = std.ArrayList(u8).init(allocator);
    defer out.deinit();
    try std.json.stringify(.{
        .schemaVersion = manifest.schema_version,
        .packId = manifest.pack_id,
        .packVersion = manifest.pack_version,
        .domainFamily = manifest.domain_family,
        .trustClass = manifest.trust_class,
        .compatibility = .{
            .engineVersion = manifest.compatibility.engine_version,
            .linuxFirst = manifest.compatibility.linux_first,
            .deterministicOnly = manifest.compatibility.deterministic_only,
            .mountSchema = manifest.compatibility.mount_schema,
        },
        .storage = .{
            .corpusManifestRelPath = manifest.storage.corpus_manifest_rel_path,
            .corpusFilesRelPath = manifest.storage.corpus_files_rel_path,
            .abstractionCatalogRelPath = manifest.storage.abstraction_catalog_rel_path,
            .reuseCatalogRelPath = manifest.storage.reuse_catalog_rel_path,
            .lineageStateRelPath = manifest.storage.lineage_state_rel_path,
            .influenceManifestRelPath = manifest.storage.influence_manifest_rel_path,
            .autopsyGuidanceRelPath = manifest.storage.autopsy_guidance_rel_path,
        },
        .provenance = .{
            .packLineageId = manifest.provenance.pack_lineage_id,
            .sourceKind = manifest.provenance.source_kind,
            .sourceId = manifest.provenance.source_id,
            .sourceState = sourceStateName(manifest.provenance.source_state),
            .freshnessState = packFreshnessName(manifest.provenance.freshness_state),
            .sourceSummary = manifest.provenance.source_summary,
            .sourceLineageSummary = manifest.provenance.source_lineage_summary,
        },
        .content = .{
            .corpusItemCount = manifest.content.corpus_item_count,
            .conceptCount = manifest.content.concept_count,
            .corpusHash = manifest.content.corpus_hash,
            .abstractionHash = manifest.content.abstraction_hash,
            .reuseHash = manifest.content.reuse_hash,
            .lineageHash = manifest.content.lineage_hash,
            .corpusPreview = manifest.content.corpus_preview,
            .conceptPreview = manifest.content.concept_preview,
        },
    }, .{ .whitespace = .indent_2 }, out.writer());
    try writeFileAbsolute(abs_path, out.items);
}

pub fn loadMountRegistry(allocator: std.mem.Allocator, paths: *const shards.Paths) !MountRegistry {
    const abs_path = try mountRegistryAbsPath(allocator, paths);
    defer allocator.free(abs_path);
    const bytes = readFileAbsoluteAlloc(allocator, abs_path, 256 * 1024) catch |err| switch (err) {
        error.FileNotFound => return .{
            .allocator = allocator,
            .version = try allocator.dupe(u8, MOUNT_SCHEMA_VERSION),
            .entries = try allocator.alloc(MountEntry, 0),
        },
        else => return err,
    };
    defer allocator.free(bytes);

    const DiskEntry = struct {
        packId: []const u8,
        packVersion: []const u8,
        enabled: bool,
    };
    const DiskRegistry = struct {
        version: []const u8,
        entries: []const DiskEntry,
    };
    const parsed = try std.json.parseFromSlice(DiskRegistry, allocator, bytes, .{});
    defer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.version, MOUNT_SCHEMA_VERSION)) return error.InvalidKnowledgePackMounts;

    var entries = try allocator.alloc(MountEntry, parsed.value.entries.len);
    var initialized: usize = 0;
    errdefer {
        for (entries[0..initialized]) |*entry| entry.deinit();
        allocator.free(entries);
    }
    for (parsed.value.entries, 0..) |item, idx| {
        entries[idx] = .{
            .allocator = allocator,
            .pack_id = try allocator.dupe(u8, item.packId),
            .pack_version = try allocator.dupe(u8, item.packVersion),
            .enabled = item.enabled,
        };
        initialized += 1;
    }
    return .{
        .allocator = allocator,
        .version = try allocator.dupe(u8, parsed.value.version),
        .entries = entries,
    };
}

pub fn saveMountRegistry(allocator: std.mem.Allocator, paths: *const shards.Paths, registry: *const MountRegistry) !void {
    const abs_path = try mountRegistryAbsPath(allocator, paths);
    defer allocator.free(abs_path);
    const parent_dir = std.fs.path.dirname(abs_path) orelse return error.InvalidKnowledgePackMounts;
    try sys.makePath(allocator, parent_dir);

    var out = std.ArrayList(u8).init(allocator);
    defer out.deinit();
    const DiskEntry = struct {
        packId: []const u8,
        packVersion: []const u8,
        enabled: bool,
    };
    var disk_entries = try allocator.alloc(DiskEntry, registry.entries.len);
    defer allocator.free(disk_entries);
    for (registry.entries, 0..) |entry, idx| {
        disk_entries[idx] = .{
            .packId = entry.pack_id,
            .packVersion = entry.pack_version,
            .enabled = entry.enabled,
        };
    }
    try std.json.stringify(.{
        .version = registry.version,
        .entries = disk_entries,
    }, .{ .whitespace = .indent_2 }, out.writer());
    try writeFileAbsolute(abs_path, out.items);
}

pub fn listResolvedMounts(allocator: std.mem.Allocator, paths: *const shards.Paths) ![]ResolvedMount {
    var registry = try loadMountRegistry(allocator, paths);
    defer registry.deinit();

    var out = std.ArrayList(ResolvedMount).init(allocator);
    errdefer {
        for (out.items) |*item| item.deinit();
        out.deinit();
    }

    for (registry.entries) |entry| {
        const manifest_abs = try manifestAbsPath(allocator, entry.pack_id, entry.pack_version);
        errdefer allocator.free(manifest_abs);
        const manifest = loadManifestFromPath(allocator, manifest_abs) catch |err| switch (err) {
            error.FileNotFound => return error.InvalidKnowledgePackMounts,
            else => return err,
        };
        errdefer {
            var doomed = manifest;
            doomed.deinit();
        }

        const root_abs = try packRootAbsPath(allocator, entry.pack_id, entry.pack_version);
        errdefer allocator.free(root_abs);
        var mount_entry = MountEntry{
            .allocator = allocator,
            .pack_id = try allocator.dupe(u8, entry.pack_id),
            .pack_version = try allocator.dupe(u8, entry.pack_version),
            .enabled = entry.enabled,
        };
        errdefer mount_entry.deinit();
        try out.append(try resolveMountFromManifest(allocator, mount_entry, manifest, root_abs, manifest_abs));
    }

    return out.toOwnedSlice();
}

pub fn sourceStateName(state: SourceState) []const u8 {
    return switch (state) {
        .staged => "staged",
        .live => "live",
    };
}

pub fn parseSourceState(text: []const u8) ?SourceState {
    if (std.mem.eql(u8, text, "staged")) return .staged;
    if (std.mem.eql(u8, text, "live")) return .live;
    return null;
}

pub fn packFreshnessName(state: PackFreshness) []const u8 {
    return switch (state) {
        .active => "active",
        .stale => "stale",
    };
}

pub fn parsePackFreshness(text: []const u8) ?PackFreshness {
    if (std.mem.eql(u8, text, "active")) return .active;
    if (std.mem.eql(u8, text, "stale")) return .stale;
    return null;
}

pub fn appendPreviewItem(allocator: std.mem.Allocator, list: *std.ArrayList([]u8), value: []const u8) !void {
    if (list.items.len >= MAX_PREVIEW_ITEMS) return;
    for (list.items) |item| {
        if (std.mem.eql(u8, item, value)) return;
    }
    try list.append(try allocator.dupe(u8, value));
}

fn resolveMountFromManifest(
    allocator: std.mem.Allocator,
    entry: MountEntry,
    manifest: Manifest,
    root_abs_path: []u8,
    manifest_abs_path: []u8,
) !ResolvedMount {
    const corpus_manifest_abs_path = try resolveContainedPath(allocator, root_abs_path, manifest.storage.corpus_manifest_rel_path);
    errdefer allocator.free(corpus_manifest_abs_path);
    const corpus_files_abs_path = try resolveCorpusFilesRoot(allocator, root_abs_path, manifest.storage.corpus_files_rel_path);
    errdefer allocator.free(corpus_files_abs_path);
    const abstraction_catalog_abs_path = try resolveContainedPath(allocator, root_abs_path, manifest.storage.abstraction_catalog_rel_path);
    errdefer allocator.free(abstraction_catalog_abs_path);
    const reuse_catalog_abs_path = try resolveContainedPath(allocator, root_abs_path, manifest.storage.reuse_catalog_rel_path);
    errdefer allocator.free(reuse_catalog_abs_path);
    const lineage_state_abs_path = try resolveContainedPath(allocator, root_abs_path, manifest.storage.lineage_state_rel_path);
    errdefer allocator.free(lineage_state_abs_path);
    const influence_manifest_abs_path = try resolveContainedPath(allocator, root_abs_path, manifest.storage.influence_manifest_rel_path);
    errdefer allocator.free(influence_manifest_abs_path);
    const autopsy_guidance_abs_path = if (manifest.storage.autopsy_guidance_rel_path) |rel_path|
        try resolveContainedPath(allocator, root_abs_path, rel_path)
    else
        null;
    errdefer if (autopsy_guidance_abs_path) |path| allocator.free(path);

    return .{
        .allocator = allocator,
        .entry = entry,
        .manifest = manifest,
        .root_abs_path = root_abs_path,
        .manifest_abs_path = manifest_abs_path,
        .corpus_manifest_abs_path = corpus_manifest_abs_path,
        .corpus_files_abs_path = corpus_files_abs_path,
        .abstraction_catalog_abs_path = abstraction_catalog_abs_path,
        .reuse_catalog_abs_path = reuse_catalog_abs_path,
        .lineage_state_abs_path = lineage_state_abs_path,
        .influence_manifest_abs_path = influence_manifest_abs_path,
        .autopsy_guidance_abs_path = autopsy_guidance_abs_path,
    };
}

fn validateStorageLayout(allocator: std.mem.Allocator, manifest_root_abs_path: []const u8, storage: anytype) !void {
    const corpus_manifest = try resolveContainedPath(allocator, manifest_root_abs_path, storage.corpusManifestRelPath);
    defer allocator.free(corpus_manifest);
    const corpus_files = try resolveContainedPath(allocator, manifest_root_abs_path, storage.corpusFilesRelPath);
    defer allocator.free(corpus_files);
    const abstraction_catalog = try resolveContainedPath(allocator, manifest_root_abs_path, storage.abstractionCatalogRelPath);
    defer allocator.free(abstraction_catalog);
    const reuse_catalog = try resolveContainedPath(allocator, manifest_root_abs_path, storage.reuseCatalogRelPath);
    defer allocator.free(reuse_catalog);
    const lineage_state = try resolveContainedPath(allocator, manifest_root_abs_path, storage.lineageStateRelPath);
    defer allocator.free(lineage_state);
    const influence_manifest = try resolveContainedPath(allocator, manifest_root_abs_path, storage.influenceManifestRelPath);
    defer allocator.free(influence_manifest);
    if (try guidanceRelPathFromDiskStorage(storage)) |rel_path| {
        const autopsy_guidance = try resolveContainedPath(allocator, manifest_root_abs_path, rel_path);
        defer allocator.free(autopsy_guidance);
    }
}

fn guidanceRelPathFromDiskStorage(storage: anytype) !?[]const u8 {
    const camel = storage.autopsyGuidanceRelPath;
    const snake = storage.autopsy_guidance_rel_path;
    if (camel) |camel_path| {
        if (snake) |snake_path| {
            if (!std.mem.eql(u8, camel_path, snake_path)) return error.InvalidKnowledgePackManifest;
        }
        return camel_path;
    }
    return snake;
}

fn resolveContainedPath(allocator: std.mem.Allocator, root_abs_path: []const u8, rel_path: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, rel_path, " \r\n\t");
    if (trimmed.len == 0) return error.InvalidKnowledgePackManifest;
    if (std.fs.path.isAbsolute(trimmed)) return error.InvalidKnowledgePackManifest;

    const resolved = try std.fs.path.resolve(allocator, &.{ root_abs_path, trimmed });
    errdefer allocator.free(resolved);
    if (!pathWithinRoot(root_abs_path, resolved)) return error.InvalidKnowledgePackManifest;
    return resolved;
}

fn resolveCorpusFilesRoot(allocator: std.mem.Allocator, root_abs_path: []const u8, rel_path: []const u8) ![]u8 {
    const resolved = try resolveContainedPath(allocator, root_abs_path, rel_path);
    errdefer allocator.free(resolved);

    const trimmed = std.mem.trim(u8, rel_path, " \r\n\t");
    if (std.mem.eql(u8, std.fs.path.basename(trimmed), "files")) {
        const parent = std.fs.path.dirname(resolved) orelse return resolved;
        const rooted = try allocator.dupe(u8, parent);
        allocator.free(resolved);
        return rooted;
    }
    return resolved;
}

fn pathWithinRoot(root_abs_path: []const u8, candidate_abs_path: []const u8) bool {
    if (!std.mem.startsWith(u8, candidate_abs_path, root_abs_path)) return false;
    if (candidate_abs_path.len == root_abs_path.len) return true;
    if (root_abs_path.len == 0) return false;
    return std.fs.path.isSep(candidate_abs_path[root_abs_path.len]);
}

fn sanitizeToken(allocator: std.mem.Allocator, raw: []const u8, fallback: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, raw, " \r\n\t");
    if (trimmed.len == 0) return allocator.dupe(u8, fallback);
    var out = try allocator.alloc(u8, trimmed.len);
    errdefer allocator.free(out);
    var written: usize = 0;
    var last_dash = false;
    for (trimmed) |ch| {
        const next: u8 = switch (ch) {
            'a'...'z', '0'...'9' => ch,
            'A'...'Z' => std.ascii.toLower(ch),
            '.', '-', '_' => ch,
            else => '-',
        };
        if (next == '-' and (written == 0 or last_dash)) continue;
        out[written] = next;
        written += 1;
        last_dash = next == '-';
    }
    while (written > 0 and out[written - 1] == '-') written -= 1;
    if (written == 0) {
        allocator.free(out);
        return allocator.dupe(u8, fallback);
    }
    return allocator.realloc(out, written);
}

fn cloneSlice(allocator: std.mem.Allocator, items: []const []const u8) ![][]u8 {
    const out = try allocator.alloc([]u8, items.len);
    var built: usize = 0;
    errdefer {
        for (out[0..built]) |item| allocator.free(item);
        allocator.free(out);
    }
    for (items, 0..) |item, idx| {
        out[idx] = try allocator.dupe(u8, item);
        built += 1;
    }
    return out;
}

fn readFileAbsoluteAlloc(allocator: std.mem.Allocator, abs_path: []const u8, max_bytes: usize) ![]u8 {
    const file = try std.fs.openFileAbsolute(abs_path, .{});
    defer file.close();
    return file.readToEndAlloc(allocator, max_bytes);
}

fn writeFileAbsolute(abs_path: []const u8, bytes: []const u8) !void {
    var file = try std.fs.createFileAbsolute(abs_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(bytes);
}

pub const EXPORT_SCHEMA_VERSION = "ghost_pack_export_v1";

pub const ExportIntegrity = struct {
    manifest_hash: u64,
    corpus_manifest_hash: u64,
    corpus_files_hash: u64,
    abstraction_hash: u64,
    reuse_hash: u64,
    lineage_hash: u64,
    influence_hash: u64,
    total_files_hash: u64,
};

pub const ExportEnvelopeSource = struct {
    source_pack_lineage_id: []u8,
    source_kind: []u8,
    export_reason: []u8,

    pub fn deinit(self: *ExportEnvelopeSource, allocator: std.mem.Allocator) void {
        allocator.free(self.source_pack_lineage_id);
        allocator.free(self.source_kind);
        allocator.free(self.export_reason);
        self.* = undefined;
    }
};

pub const ExportEnvelope = struct {
    allocator: std.mem.Allocator,
    schema_version: []u8,
    exported_at: u64,
    export_engine_version: []u8,
    pack_id: []u8,
    pack_version: []u8,
    integrity: ExportIntegrity,
    provenance: ExportEnvelopeSource,

    pub fn deinit(self: *ExportEnvelope) void {
        self.allocator.free(self.schema_version);
        self.allocator.free(self.export_engine_version);
        self.allocator.free(self.pack_id);
        self.allocator.free(self.pack_version);
        self.provenance.deinit(self.allocator);
        self.* = undefined;
    }
};

pub fn loadExportEnvelope(allocator: std.mem.Allocator, abs_path: []const u8) !ExportEnvelope {
    const bytes = try readFileAbsoluteAlloc(allocator, abs_path, 512 * 1024);
    defer allocator.free(bytes);

    const DiskIntegrity = struct {
        manifestHash: u64,
        corpusManifestHash: u64,
        corpusFilesHash: u64,
        abstractionHash: u64,
        reuseHash: u64,
        lineageHash: u64,
        influenceHash: u64,
        totalFilesHash: u64,
    };
    const DiskProvenance = struct {
        sourcePackLineageId: []const u8,
        sourceKind: []const u8,
        exportReason: []const u8,
    };
    const DiskEnvelope = struct {
        schemaVersion: []const u8,
        exportedAt: u64,
        exportEngineVersion: []const u8,
        packId: []const u8,
        packVersion: []const u8,
        integrity: DiskIntegrity,
        provenance: DiskProvenance,
    };

    const parsed = try std.json.parseFromSlice(DiskEnvelope, allocator, bytes, .{});
    defer parsed.deinit();

    if (!std.mem.eql(u8, parsed.value.schemaVersion, EXPORT_SCHEMA_VERSION))
        return error.InvalidExportEnvelope;

    return .{
        .allocator = allocator,
        .schema_version = try allocator.dupe(u8, parsed.value.schemaVersion),
        .exported_at = parsed.value.exportedAt,
        .export_engine_version = try allocator.dupe(u8, parsed.value.exportEngineVersion),
        .pack_id = try allocator.dupe(u8, parsed.value.packId),
        .pack_version = try allocator.dupe(u8, parsed.value.packVersion),
        .integrity = .{
            .manifest_hash = parsed.value.integrity.manifestHash,
            .corpus_manifest_hash = parsed.value.integrity.corpusManifestHash,
            .corpus_files_hash = parsed.value.integrity.corpusFilesHash,
            .abstraction_hash = parsed.value.integrity.abstractionHash,
            .reuse_hash = parsed.value.integrity.reuseHash,
            .lineage_hash = parsed.value.integrity.lineageHash,
            .influence_hash = parsed.value.integrity.influenceHash,
            .total_files_hash = parsed.value.integrity.totalFilesHash,
        },
        .provenance = .{
            .source_pack_lineage_id = try allocator.dupe(u8, parsed.value.provenance.sourcePackLineageId),
            .source_kind = try allocator.dupe(u8, parsed.value.provenance.sourceKind),
            .export_reason = try allocator.dupe(u8, parsed.value.provenance.exportReason),
        },
    };
}

pub fn saveExportEnvelope(allocator: std.mem.Allocator, root_abs_path: []const u8, envelope: *const ExportEnvelope) !void {
    const abs_path = try std.fs.path.join(allocator, &.{ root_abs_path, "export.json" });
    defer allocator.free(abs_path);

    var out = std.ArrayList(u8).init(allocator);
    defer out.deinit();
    try std.json.stringify(.{
        .schemaVersion = envelope.schema_version,
        .exportedAt = envelope.exported_at,
        .exportEngineVersion = envelope.export_engine_version,
        .packId = envelope.pack_id,
        .packVersion = envelope.pack_version,
        .integrity = .{
            .manifestHash = envelope.integrity.manifest_hash,
            .corpusManifestHash = envelope.integrity.corpus_manifest_hash,
            .corpusFilesHash = envelope.integrity.corpus_files_hash,
            .abstractionHash = envelope.integrity.abstraction_hash,
            .reuseHash = envelope.integrity.reuse_hash,
            .lineageHash = envelope.integrity.lineage_hash,
            .influenceHash = envelope.integrity.influence_hash,
            .totalFilesHash = envelope.integrity.total_files_hash,
        },
        .provenance = .{
            .sourcePackLineageId = envelope.provenance.source_pack_lineage_id,
            .sourceKind = envelope.provenance.source_kind,
            .exportReason = envelope.provenance.export_reason,
        },
    }, .{ .whitespace = .indent_2 }, out.writer());
    try writeFileAbsolute(abs_path, out.items);
}
