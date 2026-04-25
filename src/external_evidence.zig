const std = @import("std");
const abstractions = @import("abstractions.zig");
const config = @import("config.zig");
const corpus_ingest = @import("corpus_ingest.zig");
const shards = @import("shards.zig");

pub const EXTERNAL_METADATA_FILE_NAME = ".ghost_external_evidence.json";
pub const SEARCH_PROVIDER_LABEL = "duckduckgo_html";
pub const DEFAULT_MAX_SOURCES: u8 = 4;
pub const DEFAULT_MAX_BYTES_PER_SOURCE: usize = 256 * 1024;
pub const DEFAULT_MAX_SEARCH_BYTES: usize = 256 * 1024;
pub const DEFAULT_MAX_FETCH_TIME_MS: u32 = 10_000;

pub const AcquisitionState = enum {
    not_needed,
    requested,
    fetched,
    ingested,
    conflicting,
    insufficient,
};

pub const OriginKind = enum {
    direct_url,
    search_query,
};

pub const QueryInput = struct {
    text: []const u8,
    max_results: u8 = 2,
};

pub const RequestInput = struct {
    urls: []const []const u8 = &.{},
    queries: []const QueryInput = &.{},
    max_sources: u8 = DEFAULT_MAX_SOURCES,
    max_bytes_per_source: usize = DEFAULT_MAX_BYTES_PER_SOURCE,
    max_search_bytes: usize = DEFAULT_MAX_SEARCH_BYTES,
    max_fetch_time_ms: u32 = DEFAULT_MAX_FETCH_TIME_MS,
    trust_class: abstractions.TrustClass = .exploratory,
};

pub const Query = struct {
    text: []u8,
    max_results: u8 = 2,

    fn clone(self: Query, allocator: std.mem.Allocator) !Query {
        return .{
            .text = try allocator.dupe(u8, self.text),
            .max_results = self.max_results,
        };
    }

    fn deinit(self: *Query, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.* = undefined;
    }
};

pub const Request = struct {
    urls: [][]u8,
    queries: []Query,
    max_sources: u8,
    max_bytes_per_source: usize,
    max_search_bytes: usize,
    max_fetch_time_ms: u32,
    trust_class: abstractions.TrustClass,

    pub fn initOwned(allocator: std.mem.Allocator, input: RequestInput) !Request {
        var urls = try allocator.alloc([]u8, input.urls.len);
        var url_built: usize = 0;
        errdefer {
            for (urls[0..url_built]) |item| allocator.free(item);
            allocator.free(urls);
        }
        for (input.urls, 0..) |item, idx| {
            urls[idx] = try allocator.dupe(u8, item);
            url_built += 1;
        }

        var queries = try allocator.alloc(Query, input.queries.len);
        var query_built: usize = 0;
        errdefer {
            for (queries[0..query_built]) |*item| item.deinit(allocator);
            allocator.free(queries);
        }
        for (input.queries, 0..) |item, idx| {
            queries[idx] = .{
                .text = try allocator.dupe(u8, item.text),
                .max_results = item.max_results,
            };
            query_built += 1;
        }

        return .{
            .urls = urls,
            .queries = queries,
            .max_sources = input.max_sources,
            .max_bytes_per_source = input.max_bytes_per_source,
            .max_search_bytes = input.max_search_bytes,
            .max_fetch_time_ms = input.max_fetch_time_ms,
            .trust_class = input.trust_class,
        };
    }

    pub fn clone(self: *const Request, allocator: std.mem.Allocator) !Request {
        var urls = try allocator.alloc([]u8, self.urls.len);
        var url_built: usize = 0;
        errdefer {
            for (urls[0..url_built]) |item| allocator.free(item);
            allocator.free(urls);
        }
        for (self.urls, 0..) |item, idx| {
            urls[idx] = try allocator.dupe(u8, item);
            url_built += 1;
        }

        var queries = try allocator.alloc(Query, self.queries.len);
        var query_built: usize = 0;
        errdefer {
            for (queries[0..query_built]) |*item| item.deinit(allocator);
            allocator.free(queries);
        }
        for (self.queries, 0..) |item, idx| {
            queries[idx] = try item.clone(allocator);
            query_built += 1;
        }

        return .{
            .urls = urls,
            .queries = queries,
            .max_sources = self.max_sources,
            .max_bytes_per_source = self.max_bytes_per_source,
            .max_search_bytes = self.max_search_bytes,
            .max_fetch_time_ms = self.max_fetch_time_ms,
            .trust_class = self.trust_class,
        };
    }

    pub fn deinit(self: *Request, allocator: std.mem.Allocator) void {
        for (self.urls) |item| allocator.free(item);
        allocator.free(self.urls);
        for (self.queries) |*item| item.deinit(allocator);
        allocator.free(self.queries);
        self.* = undefined;
    }

    pub fn isEmpty(self: *const Request) bool {
        return self.urls.len == 0 and self.queries.len == 0;
    }
};

pub const SourceRecord = struct {
    allocator: std.mem.Allocator,
    origin: OriginKind,
    source_url: []u8,
    query_text: ?[]u8 = null,
    considered_reason: []u8,
    fetch_time_ms: i64,
    http_status: u16 = 0,
    content_hash: u64,
    trust_class: abstractions.TrustClass,
    local_rel_path: []u8,
    local_abs_path: []u8,
    lineage_id: ?[]u8 = null,
    lineage_version: u32 = 0,
    ingested_target_path: ?[]u8 = null,
    stage_status: ?[]u8 = null,
    stage_provenance: ?[]u8 = null,

    pub fn deinit(self: *SourceRecord) void {
        self.allocator.free(self.source_url);
        if (self.query_text) |value| self.allocator.free(value);
        self.allocator.free(self.considered_reason);
        self.allocator.free(self.local_rel_path);
        self.allocator.free(self.local_abs_path);
        if (self.lineage_id) |value| self.allocator.free(value);
        if (self.ingested_target_path) |value| self.allocator.free(value);
        if (self.stage_status) |value| self.allocator.free(value);
        if (self.stage_provenance) |value| self.allocator.free(value);
        self.* = undefined;
    }
};

pub const QueryRecord = struct {
    allocator: std.mem.Allocator,
    text: []u8,
    result_urls: [][]u8,

    pub fn deinit(self: *QueryRecord) void {
        self.allocator.free(self.text);
        for (self.result_urls) |item| self.allocator.free(item);
        self.allocator.free(self.result_urls);
        self.* = undefined;
    }
};

pub const Result = struct {
    allocator: std.mem.Allocator,
    state: AcquisitionState,
    detail: ?[]u8 = null,
    shard_kind: shards.Kind,
    shard_id: []u8,
    shard_root: []u8,
    request_id: []u8,
    fetch_root_abs_path: []u8,
    metadata_manifest_abs_path: []u8,
    query_records: []QueryRecord,
    source_records: []SourceRecord,
    stage_result: corpus_ingest.StageResult,

    pub fn deinit(self: *Result) void {
        if (self.detail) |value| self.allocator.free(value);
        self.allocator.free(self.shard_id);
        self.allocator.free(self.shard_root);
        self.allocator.free(self.request_id);
        self.allocator.free(self.fetch_root_abs_path);
        self.allocator.free(self.metadata_manifest_abs_path);
        for (self.query_records) |*item| item.deinit();
        self.allocator.free(self.query_records);
        for (self.source_records) |*item| item.deinit();
        self.allocator.free(self.source_records);
        self.stage_result.deinit();
        self.* = undefined;
    }
};

pub const AcquireOptions = struct {
    project_shard: []const u8,
    request: *const Request,
    request_id_hint: ?[]const u8 = null,
    considered_reason: []const u8,
};

pub const ExternalMetadataItem = struct {
    relPath: []const u8,
    sourceUrl: []const u8,
    fetchTimeMs: i64,
    contentHash: u64,
    consideredReason: []const u8,
    queryText: ?[]const u8 = null,
    origin: OriginKind,
};

pub fn acquisitionStateName(state: AcquisitionState) []const u8 {
    return @tagName(state);
}

pub fn acquire(allocator: std.mem.Allocator, options: AcquireOptions) !Result {
    var shard_metadata = try shards.resolveProjectMetadata(allocator, options.project_shard);
    defer shard_metadata.deinit();

    var paths = try shards.resolvePaths(allocator, shard_metadata.metadata);
    defer paths.deinit();

    if (pathExists(paths.corpus_ingest_staged_manifest_abs_path)) {
        return buildEmptyResult(allocator, &paths, options.request_id_hint, .insufficient, "corpus ingestion already has staged state; commit or discard before acquiring external evidence");
    }

    try corpus_ingest.validateTrustClass(paths.metadata.kind, options.request.trust_class);

    const request_id = try computeRequestId(allocator, options.request_id_hint, options.project_shard, options.request);
    errdefer allocator.free(request_id);
    const fetch_root = try std.fs.path.join(allocator, &.{ paths.corpus_ingest_root_abs_path, "external_evidence", request_id });
    errdefer allocator.free(fetch_root);

    deleteTreeIfExistsAbsolute(fetch_root) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    try std.fs.cwd().makePath(fetch_root);

    var query_records = std.ArrayList(QueryRecord).init(allocator);
    errdefer {
        for (query_records.items) |*item| item.deinit();
        query_records.deinit();
    }
    var source_records = std.ArrayList(SourceRecord).init(allocator);
    errdefer {
        for (source_records.items) |*item| item.deinit();
        source_records.deinit();
    }
    var metadata_items = std.ArrayList(ExternalMetadataItem).init(allocator);
    defer {
        for (metadata_items.items) |item| {
            allocator.free(item.relPath);
            allocator.free(item.sourceUrl);
            allocator.free(item.consideredReason);
            if (item.queryText) |value| allocator.free(value);
        }
        metadata_items.deinit();
    }

    var remaining_budget: usize = options.request.max_sources;
    for (options.request.urls) |item| {
        if (remaining_budget == 0) break;
        const record = try fetchOneSource(
            allocator,
            fetch_root,
            .direct_url,
            item,
            null,
            options.considered_reason,
            options.request.max_bytes_per_source,
            options.request.max_fetch_time_ms,
            options.request.trust_class,
            source_records.items.len,
        );
        try appendMetadataItem(allocator, &metadata_items, record);
        try source_records.append(record);
        remaining_budget -= 1;
    }

    for (options.request.queries) |query| {
        if (remaining_budget == 0) break;
        const resolved = try resolveSearchQuery(
            allocator,
            query.text,
            @min(@as(usize, query.max_results), remaining_budget),
            options.request.max_search_bytes,
            options.request.max_fetch_time_ms,
        );
        defer {
            for (resolved) |item| allocator.free(item);
            allocator.free(resolved);
        }
        if (resolved.len == 0) continue;

        var query_urls = try allocator.alloc([]u8, resolved.len);
        errdefer {
            for (query_urls) |item| allocator.free(item);
            allocator.free(query_urls);
        }
        for (resolved, 0..) |item, idx| query_urls[idx] = try allocator.dupe(u8, item);
        try query_records.append(.{
            .allocator = allocator,
            .text = try allocator.dupe(u8, query.text),
            .result_urls = query_urls,
        });

        for (resolved) |url| {
            if (remaining_budget == 0) break;
            const considered = try std.fmt.allocPrint(allocator, "{s}; search query: {s}", .{ options.considered_reason, query.text });
            defer allocator.free(considered);
            const record = try fetchOneSource(
                allocator,
                fetch_root,
                .search_query,
                url,
                query.text,
                considered,
                options.request.max_bytes_per_source,
                options.request.max_fetch_time_ms,
                options.request.trust_class,
                source_records.items.len,
            );
            try appendMetadataItem(allocator, &metadata_items, record);
            try source_records.append(record);
            remaining_budget -= 1;
        }
    }

    if (source_records.items.len == 0) {
        return buildEmptyResult(allocator, &paths, options.request_id_hint, .insufficient, "bounded external evidence request produced no fetchable sources");
    }

    const metadata_manifest_path = try std.fs.path.join(allocator, &.{ fetch_root, EXTERNAL_METADATA_FILE_NAME });
    errdefer allocator.free(metadata_manifest_path);
    const metadata_json = try renderMetadataJson(allocator, metadata_items.items);
    defer allocator.free(metadata_json);
    try writeAbsoluteFile(metadata_manifest_path, metadata_json);

    var stage_result = try corpus_ingest.stage(allocator, .{
        .corpus_path = fetch_root,
        .project_shard = options.project_shard,
        .trust_class = options.request.trust_class,
        .source_label = "external_evidence",
        .max_file_bytes = options.request.max_bytes_per_source,
        .max_files = @as(usize, options.request.max_sources) + 1,
        .merge_live = true,
    });
    errdefer stage_result.deinit();
    try corpus_ingest.applyStaged(allocator, &paths);
    try enrichRecordsFromStageResult(allocator, source_records.items, &stage_result);

    return .{
        .allocator = allocator,
        .state = .ingested,
        .shard_kind = paths.metadata.kind,
        .shard_id = try allocator.dupe(u8, paths.metadata.id),
        .shard_root = try allocator.dupe(u8, paths.root_abs_path),
        .request_id = request_id,
        .fetch_root_abs_path = fetch_root,
        .metadata_manifest_abs_path = metadata_manifest_path,
        .query_records = try query_records.toOwnedSlice(),
        .source_records = try source_records.toOwnedSlice(),
        .stage_result = stage_result,
    };
}

pub fn renderJson(allocator: std.mem.Allocator, result: *const Result) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const writer = out.writer();

    try writer.writeAll("{");
    try writeJsonFieldString(writer, "state", acquisitionStateName(result.state), true);
    if (result.detail) |detail| try writeOptionalStringField(writer, "detail", detail);
    try writer.writeAll(",\"shard\":{");
    try writeJsonFieldString(writer, "kind", @tagName(result.shard_kind), true);
    try writeJsonFieldString(writer, "id", result.shard_id, false);
    try writeJsonFieldString(writer, "root", result.shard_root, false);
    try writer.writeAll("}");
    try writeOptionalStringField(writer, "requestId", result.request_id);
    try writeOptionalStringField(writer, "fetchRoot", result.fetch_root_abs_path);
    try writeOptionalStringField(writer, "metadataManifest", result.metadata_manifest_abs_path);
    try writer.writeAll(",\"queries\":[");
    for (result.query_records, 0..) |item, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writer.writeAll("{");
        try writeJsonFieldString(writer, "text", item.text, true);
        try writer.writeAll(",\"results\":");
        try writeStringArray(writer, item.result_urls);
        try writer.writeAll("}");
    }
    try writer.writeAll("],\"sources\":[");
    for (result.source_records, 0..) |item, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writer.writeAll("{");
        try writeJsonFieldString(writer, "origin", @tagName(item.origin), true);
        try writeJsonFieldString(writer, "sourceUrl", item.source_url, false);
        if (item.query_text) |value| try writeOptionalStringField(writer, "queryText", value);
        try writeJsonFieldString(writer, "consideredReason", item.considered_reason, false);
        try writer.print(",\"fetchTimeMs\":{d}", .{item.fetch_time_ms});
        try writer.print(",\"httpStatus\":{d}", .{item.http_status});
        try writer.print(",\"contentHash\":{d}", .{item.content_hash});
        try writeOptionalStringField(writer, "trustClass", abstractions.trustClassName(item.trust_class));
        try writeOptionalStringField(writer, "localRelPath", item.local_rel_path);
        try writeOptionalStringField(writer, "localAbsPath", item.local_abs_path);
        if (item.lineage_id) |value| {
            try writer.writeAll(",\"lineage\":{");
            try writeJsonFieldString(writer, "id", value, true);
            try writer.print(",\"version\":{d}", .{item.lineage_version});
            try writer.writeAll("}");
        }
        if (item.ingested_target_path) |value| try writeOptionalStringField(writer, "ingestedTargetPath", value);
        if (item.stage_status) |value| try writeOptionalStringField(writer, "stageStatus", value);
        if (item.stage_provenance) |value| try writeOptionalStringField(writer, "stageProvenance", value);
        try writer.writeAll("}");
    }
    try writer.writeAll("],\"ingest\":");
    const stage_json = try corpus_ingest.renderJson(allocator, &result.stage_result);
    defer allocator.free(stage_json);
    try writer.writeAll(stage_json);
    try writer.writeAll("}");
    return out.toOwnedSlice();
}

fn buildEmptyResult(
    allocator: std.mem.Allocator,
    paths: *const shards.Paths,
    request_id_hint: ?[]const u8,
    state: AcquisitionState,
    detail: []const u8,
) !Result {
    const empty_queries = try allocator.alloc(QueryRecord, 0);
    errdefer allocator.free(empty_queries);
    const empty_sources = try allocator.alloc(SourceRecord, 0);
    errdefer allocator.free(empty_sources);
    const empty_items = try allocator.alloc(corpus_ingest.ItemResult, 0);
    errdefer allocator.free(empty_items);
    return .{
        .allocator = allocator,
        .state = state,
        .detail = try allocator.dupe(u8, detail),
        .shard_kind = paths.metadata.kind,
        .shard_id = try allocator.dupe(u8, paths.metadata.id),
        .shard_root = try allocator.dupe(u8, paths.root_abs_path),
        .request_id = if (request_id_hint) |value| try allocator.dupe(u8, value) else try allocator.dupe(u8, "none"),
        .fetch_root_abs_path = try allocator.dupe(u8, ""),
        .metadata_manifest_abs_path = try allocator.dupe(u8, ""),
        .query_records = empty_queries,
        .source_records = empty_sources,
        .stage_result = .{
            .allocator = allocator,
            .shard_kind = paths.metadata.kind,
            .shard_id = try allocator.dupe(u8, paths.metadata.id),
            .shard_root = try allocator.dupe(u8, paths.root_abs_path),
            .corpus_root = try allocator.dupe(u8, ""),
            .source_label = try allocator.dupe(u8, ""),
            .trust_class = .exploratory,
            .staged_manifest_path = try allocator.dupe(u8, ""),
            .staged_files_root = try allocator.dupe(u8, ""),
            .scanned_files = 0,
            .staged_items = 0,
            .duplicate_items = 0,
            .rejected_items = 0,
            .concept_count = 0,
            .items = empty_items,
        },
    };
}

fn enrichRecordsFromStageResult(
    allocator: std.mem.Allocator,
    records: []SourceRecord,
    stage_result: *const corpus_ingest.StageResult,
) !void {
    for (records) |*record| {
        for (stage_result.items) |item| {
            if (!std.mem.eql(u8, item.source_rel_path, record.local_rel_path)) continue;
            record.stage_status = try allocator.dupe(u8, item.status);
            if (item.lineage_id) |value| record.lineage_id = try allocator.dupe(u8, value);
            record.lineage_version = item.lineage_version;
            if (item.target_rel_path) |value| record.ingested_target_path = try allocator.dupe(u8, value) else if (item.synthetic_rel_path) |value| record.ingested_target_path = try allocator.dupe(u8, value);
            if (item.provenance) |value| record.stage_provenance = try allocator.dupe(u8, value);
            break;
        }
    }
}

fn appendMetadataItem(allocator: std.mem.Allocator, list: *std.ArrayList(ExternalMetadataItem), record: SourceRecord) !void {
    try list.append(.{
        .relPath = try allocator.dupe(u8, record.local_rel_path),
        .sourceUrl = try allocator.dupe(u8, record.source_url),
        .fetchTimeMs = record.fetch_time_ms,
        .contentHash = record.content_hash,
        .consideredReason = try allocator.dupe(u8, record.considered_reason),
        .queryText = if (record.query_text) |value| try allocator.dupe(u8, value) else null,
        .origin = record.origin,
    });
}

fn fetchOneSource(
    allocator: std.mem.Allocator,
    fetch_root: []const u8,
    origin: OriginKind,
    source_url: []const u8,
    query_text: ?[]const u8,
    considered_reason: []const u8,
    max_bytes: usize,
    timeout_ms: u32,
    trust_class: abstractions.TrustClass,
    index: usize,
) !SourceRecord {
    const fetched = try fetchUrlBytes(allocator, source_url, max_bytes, timeout_ms);
    defer allocator.free(fetched.bytes);

    const rel_name = try buildLocalRelPath(allocator, source_url, index);
    errdefer allocator.free(rel_name);
    const abs_path = try std.fs.path.join(allocator, &.{ fetch_root, rel_name });
    errdefer allocator.free(abs_path);
    try ensureParentDirAbsolute(abs_path);
    try writeAbsoluteFile(abs_path, fetched.bytes);

    return .{
        .allocator = allocator,
        .origin = origin,
        .source_url = try allocator.dupe(u8, source_url),
        .query_text = if (query_text) |value| try allocator.dupe(u8, value) else null,
        .considered_reason = try allocator.dupe(u8, considered_reason),
        .fetch_time_ms = std.time.milliTimestamp(),
        .http_status = fetched.http_status,
        .content_hash = std.hash.Fnv1a_64.hash(fetched.bytes),
        .trust_class = trust_class,
        .local_rel_path = rel_name,
        .local_abs_path = abs_path,
    };
}

fn resolveSearchQuery(
    allocator: std.mem.Allocator,
    query_text: []const u8,
    max_results: usize,
    max_bytes: usize,
    timeout_ms: u32,
) ![][]u8 {
    if (max_results == 0) return &.{};
    const encoded = try percentEncodeQuery(allocator, query_text);
    defer allocator.free(encoded);
    const url = try std.fmt.allocPrint(allocator, "https://duckduckgo.com/html/?q={s}", .{encoded});
    defer allocator.free(url);

    const fetched = try fetchUrlBytes(allocator, url, max_bytes, timeout_ms);
    defer allocator.free(fetched.bytes);
    return parseDuckDuckGoResults(allocator, fetched.bytes, max_results);
}

fn parseDuckDuckGoResults(allocator: std.mem.Allocator, html: []const u8, max_results: usize) ![][]u8 {
    var urls = std.ArrayList([]u8).init(allocator);
    errdefer {
        for (urls.items) |item| allocator.free(item);
        urls.deinit();
    }

    var start: usize = 0;
    while (urls.items.len < max_results) {
        const found = std.mem.indexOfPos(u8, html, start, "uddg=") orelse break;
        const value_start = found + "uddg=".len;
        const value_end = std.mem.indexOfScalarPos(u8, html, value_start, '&') orelse html.len;
        const decoded = try percentDecode(allocator, html[value_start..value_end]);
        errdefer allocator.free(decoded);
        if (decoded.len > 0 and !containsOwned(urls.items, decoded)) {
            try urls.append(decoded);
        } else {
            allocator.free(decoded);
        }
        start = value_end;
    }
    return urls.toOwnedSlice();
}

fn percentEncodeQuery(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    for (text) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~') {
            try out.append(byte);
        } else if (byte == ' ') {
            try out.appendSlice("+");
        } else {
            try out.writer().print("%{X:0>2}", .{byte});
        }
    }
    return out.toOwnedSlice();
}

fn percentDecode(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    var idx: usize = 0;
    while (idx < text.len) : (idx += 1) {
        if (text[idx] == '%' and idx + 2 < text.len) {
            const hi = std.fmt.charToDigit(text[idx + 1], 16) catch {
                try out.append(text[idx]);
                continue;
            };
            const lo = std.fmt.charToDigit(text[idx + 2], 16) catch {
                try out.append(text[idx]);
                continue;
            };
            try out.append(@as(u8, @intCast(hi * 16 + lo)));
            idx += 2;
            continue;
        }
        if (text[idx] == '+') {
            try out.append(' ');
            continue;
        }
        try out.append(text[idx]);
    }
    return out.toOwnedSlice();
}

fn fetchUrlBytes(allocator: std.mem.Allocator, source_url: []const u8, max_bytes: usize, timeout_ms: u32) !struct { bytes: []u8, http_status: u16 } {
    if (std.mem.startsWith(u8, source_url, "file://")) {
        const local_path = source_url["file://".len..];
        const bytes = try std.fs.cwd().readFileAlloc(allocator, local_path, max_bytes);
        return .{ .bytes = bytes, .http_status = 200 };
    }

    var argv = std.ArrayList([]const u8).init(allocator);
    defer argv.deinit();
    const max_time_seconds: u32 = @max(@as(u32, 1), (timeout_ms + 999) / 1000);
    const max_time_text = try std.fmt.allocPrint(allocator, "{d}", .{max_time_seconds});
    defer allocator.free(max_time_text);

    try argv.appendSlice(&.{
        "curl",
        "--fail",
        "--location",
        "--silent",
        "--show-error",
        "--max-time",
        max_time_text,
        "--user-agent",
        "GhostExternalEvidence/1.0",
        source_url,
    });

    const child_run = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
        .max_output_bytes = max_bytes,
    });
    errdefer {
        allocator.free(child_run.stdout);
        allocator.free(child_run.stderr);
    }
    const exited_ok = switch (child_run.term) {
        .Exited => |code| code == 0,
        else => false,
    };
    if (!exited_ok) {
        allocator.free(child_run.stdout);
        const stderr = child_run.stderr;
        defer allocator.free(stderr);
        return error.ExternalFetchFailed;
    }
    allocator.free(child_run.stderr);
    return .{
        .bytes = child_run.stdout,
        .http_status = 200,
    };
}

fn computeRequestId(
    allocator: std.mem.Allocator,
    request_id_hint: ?[]const u8,
    project_shard: []const u8,
    request: *const Request,
) ![]u8 {
    if (request_id_hint) |value| return sanitizeToken(allocator, value, "evidence");
    var hasher = std.hash.Fnv1a_64.init();
    hasher.update(project_shard);
    for (request.urls) |item| hasher.update(item);
    for (request.queries) |item| {
        hasher.update(item.text);
        hasher.update(std.mem.asBytes(&item.max_results));
    }
    return std.fmt.allocPrint(allocator, "evidence-{x:0>16}", .{hasher.final()});
}

fn buildLocalRelPath(allocator: std.mem.Allocator, source_url: []const u8, index: usize) ![]u8 {
    if (std.mem.startsWith(u8, source_url, "file://")) {
        const path = source_url["file://".len..];
        const base = std.fs.path.basename(path);
        const safe = try sanitizeToken(allocator, if (base.len > 0) base else "source.txt", "source.txt");
        defer allocator.free(safe);
        return std.fmt.allocPrint(allocator, "{d:0>2}-{s}", .{ index + 1, safe });
    }

    const url_no_scheme = if (std.mem.startsWith(u8, source_url, "https://"))
        source_url["https://".len..]
    else if (std.mem.startsWith(u8, source_url, "http://"))
        source_url["http://".len..]
    else
        source_url;
    const safe = try sanitizeToken(allocator, url_no_scheme, "source.txt");
    defer allocator.free(safe);
    return std.fmt.allocPrint(allocator, "{d:0>2}-{s}", .{ index + 1, safe });
}

fn sanitizeToken(allocator: std.mem.Allocator, text: []const u8, fallback: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    for (text) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '.' or byte == '_' or byte == '-') {
            try out.append(byte);
        } else if (byte == '/' or byte == '\\' or byte == ':' or byte == '?' or byte == '&' or byte == '=' or byte == '#') {
            try out.append('_');
        }
    }
    if (out.items.len == 0) try out.appendSlice(fallback);
    return out.toOwnedSlice();
}

fn renderMetadataJson(allocator: std.mem.Allocator, items: []const ExternalMetadataItem) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const writer = out.writer();
    try writer.writeAll("{\"version\":\"ghost_external_evidence_v1\",\"sources\":[");
    for (items, 0..) |item, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writer.writeAll("{");
        try writeJsonFieldString(writer, "relPath", item.relPath, true);
        try writeJsonFieldString(writer, "sourceUrl", item.sourceUrl, false);
        try writer.print(",\"fetchTimeMs\":{d}", .{item.fetchTimeMs});
        try writer.print(",\"contentHash\":{d}", .{item.contentHash});
        try writeJsonFieldString(writer, "consideredReason", item.consideredReason, false);
        try writeJsonFieldString(writer, "origin", @tagName(item.origin), false);
        if (item.queryText) |value| try writeOptionalStringField(writer, "queryText", value);
        try writer.writeAll("}");
    }
    try writer.writeAll("]}");
    return out.toOwnedSlice();
}

fn containsOwned(items: []const []u8, needle: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

fn pathExists(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

fn deleteTreeIfExistsAbsolute(abs_path: []const u8) !void {
    std.fs.deleteTreeAbsolute(abs_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn ensureParentDirAbsolute(abs_path: []const u8) !void {
    const parent = std.fs.path.dirname(abs_path) orelse return;
    try std.fs.cwd().makePath(parent);
}

fn writeAbsoluteFile(abs_path: []const u8, bytes: []const u8) !void {
    const file = try std.fs.createFileAbsolute(abs_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(bytes);
}

fn writeJsonString(writer: anytype, text: []const u8) !void {
    try std.json.stringify(text, .{}, writer);
}

fn writeJsonFieldString(writer: anytype, field: []const u8, text: []const u8, first: bool) !void {
    if (!first) try writer.writeByte(',');
    try writeJsonString(writer, field);
    try writer.writeByte(':');
    try writeJsonString(writer, text);
}

fn writeOptionalStringField(writer: anytype, field: []const u8, text: []const u8) !void {
    try writer.writeByte(',');
    try writeJsonString(writer, field);
    try writer.writeByte(':');
    try writeJsonString(writer, text);
}

fn writeStringArray(writer: anytype, items: []const []const u8) !void {
    try writer.writeAll("[");
    for (items, 0..) |item, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writeJsonString(writer, item);
    }
    try writer.writeAll("]");
}
