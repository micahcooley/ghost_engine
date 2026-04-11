const std = @import("std");
const sys = @import("sys.zig");
const vsa = @import("vsa_core.zig");
const ghost_state = @import("ghost_state.zig");

// ── Canvas Constants (must match ghost.zig exactly) ──
const FLUENT_SIZE: u32 = 268_435_456;       // 256MB logical
const FLUENT_ELEMS: u32 = FLUENT_SIZE / 2;

// ══════════════════════════════════════════════════════
//  Lexer
// ══════════════════════════════════════════════════════

const TokenTag = enum {
    keyword_let,
    keyword_test,
    keyword_loom,
    keyword_var,
    keyword_mood,
    keyword_etch,
    keyword_void,
    keyword_lock,
    keyword_scan,
    keyword_bind,
    identifier,
    string_literal,
    number_literal,
    weight_literal,   // @N
    arrow,            // ->
    colon_colon,      // ::
    equal,            // =
    bracket_open,     // [
    bracket_close,    // ]
    brace_open,       // {
    brace_close,      // }
    op_lt,            // <
    op_gt,            // >
    semicolon,        // ;
    eof,
    invalid,
};

const Token = struct {
    tag:  TokenTag,
    text: []const u8,
    line: u32,
    col:  u32,
};

const Lexer = struct {
    buffer: []const u8,
    pos:    usize = 0,
    line:   u32   = 1,
    col:    u32   = 1,

    fn advance(self: *Lexer) void {
        if (self.pos >= self.buffer.len) return;
        if (self.buffer[self.pos] == '\n') { self.line += 1; self.col = 1; }
        else { self.col += 1; }
        self.pos += 1;
    }

    fn peek(self: *Lexer) u8 {
        if (self.pos + 1 >= self.buffer.len) return 0;
        return self.buffer[self.pos + 1];
    }

    fn skipWhitespace(self: *Lexer) void {
        while (self.pos < self.buffer.len) {
            const c = self.buffer[self.pos];
            if (std.ascii.isWhitespace(c)) {
                self.advance();
            } else if (c == '/' and self.peek() == '/') {
                while (self.pos < self.buffer.len and self.buffer[self.pos] != '\n') self.advance();
            } else if (c == '#') {
                while (self.pos < self.buffer.len and self.buffer[self.pos] != '\n') self.advance();
            } else break;
        }
    }

    fn next(self: *Lexer) Token {
        self.skipWhitespace();
        const sl = self.pos;
        const ll = self.line;
        const cl = self.col;
        if (self.pos >= self.buffer.len) return .{ .tag = .eof, .text = "", .line = ll, .col = cl };

        const c = self.buffer[self.pos];

        if (c == '"') {
            self.advance();
            const str_start = self.pos;
            while (self.pos < self.buffer.len and self.buffer[self.pos] != '"') self.advance();
            if (self.pos < self.buffer.len) {
                const text = self.buffer[str_start..self.pos];
                self.advance();
                return .{ .tag = .string_literal, .text = text, .line = ll, .col = cl };
            }
            return .{ .tag = .invalid, .text = "Unterminated string", .line = ll, .col = cl };
        }

        if (c == '@') {
            self.advance();
            const ws = self.pos;
            while (self.pos < self.buffer.len and std.ascii.isDigit(self.buffer[self.pos])) self.advance();
            return .{ .tag = .weight_literal, .text = self.buffer[ws..self.pos], .line = ll, .col = cl };
        }

        if (std.ascii.isDigit(c)) {
            while (self.pos < self.buffer.len and std.ascii.isDigit(self.buffer[self.pos])) self.advance();
            return .{ .tag = .number_literal, .text = self.buffer[sl..self.pos], .line = ll, .col = cl };
        }

        if (c == '-' and self.peek() == '>') {
            self.advance(); self.advance();
            return .{ .tag = .arrow, .text = "->", .line = ll, .col = cl };
        }

        if (c == ':' and self.peek() == ':') {
            self.advance(); self.advance();
            return .{ .tag = .colon_colon, .text = "::", .line = ll, .col = cl };
        }

        switch (c) {
            '=' => { self.advance(); return .{ .tag = .equal,         .text = "=", .line = ll, .col = cl }; },
            '<' => { self.advance(); return .{ .tag = .op_lt,         .text = "<", .line = ll, .col = cl }; },
            '>' => { self.advance(); return .{ .tag = .op_gt,         .text = ">", .line = ll, .col = cl }; },
            '[' => { self.advance(); return .{ .tag = .bracket_open,  .text = "[", .line = ll, .col = cl }; },
            ']' => { self.advance(); return .{ .tag = .bracket_close, .text = "]", .line = ll, .col = cl }; },
            '{' => { self.advance(); return .{ .tag = .brace_open,    .text = "{", .line = ll, .col = cl }; },
            '}' => { self.advance(); return .{ .tag = .brace_close,   .text = "}", .line = ll, .col = cl }; },
            ';' => { self.advance(); return .{ .tag = .semicolon,     .text = ";", .line = ll, .col = cl }; },
            else => {},
        }

        if (c > 127 or std.ascii.isAlphabetic(c) or c == '_') {
            while (self.pos < self.buffer.len) {
                const peek_c = self.buffer[self.pos];
                if (peek_c > 127 or std.ascii.isAlphanumeric(peek_c) or peek_c == '_') {
                    self.advance();
                } else break;
            }
            const text = self.buffer[sl..self.pos];
            if (std.mem.eql(u8, text, "LET"))  return .{ .tag = .keyword_let,  .text = text, .line = ll, .col = cl };
            if (std.mem.eql(u8, text, "TEST")) return .{ .tag = .keyword_test, .text = text, .line = ll, .col = cl };
            if (std.mem.eql(u8, text, "LOOM")) return .{ .tag = .keyword_loom, .text = text, .line = ll, .col = cl };
            if (std.mem.eql(u8, text, "VAR"))  return .{ .tag = .keyword_var,  .text = text, .line = ll, .col = cl };
            if (std.mem.eql(u8, text, "MOOD")) return .{ .tag = .keyword_mood, .text = text, .line = ll, .col = cl };
            if (std.mem.eql(u8, text, "ETCH")) return .{ .tag = .keyword_etch, .text = text, .line = ll, .col = cl };
            if (std.mem.eql(u8, text, "VOID")) return .{ .tag = .keyword_void, .text = text, .line = ll, .col = cl };
            if (std.mem.eql(u8, text, "LOCK")) return .{ .tag = .keyword_lock, .text = text, .line = ll, .col = cl };
            if (std.mem.eql(u8, text, "SCAN")) return .{ .tag = .keyword_scan, .text = text, .line = ll, .col = cl };
            if (std.mem.eql(u8, text, "BIND")) return .{ .tag = .keyword_bind, .text = text, .line = ll, .col = cl };
            return .{ .tag = .identifier, .text = text, .line = ll, .col = cl };
        }

        self.advance();
        return .{ .tag = .invalid, .text = self.buffer[sl..self.pos], .line = ll, .col = cl };
    }
};

// ══════════════════════════════════════════════════════
//  Dense Cartridge State (128MB Phantom Lobe output)
// ══════════════════════════════════════════════════════

var arena_alloc: std.heap.ArenaAllocator = undefined;
var vars: std.StringHashMap(u16) = undefined;

var loom_stack: u16 = 0;
var loom_depth: u8  = 0;

var current_sigil_path: ?[]const u8 = null;
var current_id_vector: vsa.HyperVector = @splat(0);

/// Dense CMS buffer for the cartridge output.
/// We use it to accumulate deltas before writing a sparse cartridge.
var dense_cms: ?[]u16 = null;

const SparseDelta = extern struct {
    index: u32,
    delta: i16,
};


fn sigilErr(line: u32, col: u32, msg: []const u8, extra: []const u8) void {
    var buf: [128]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "\n[SIGIL ERR {d}:{d}] {s} '{s}'\n", .{line, col, msg, extra}) catch "";
    sys.printOut(s);
}

fn canExecute() bool {
    if (loom_depth == 0) return true;
    const mask = (@as(u16, 1) << @as(u4, @truncate(loom_depth))) - 1;
    return (loom_stack & mask) == mask;
}

fn executeBind(lex: *Lexer) void {
    const path_tok = lex.next();
    if (path_tok.tag != .string_literal) {
        sigilErr(path_tok.line, path_tok.col, "BIND expects quoted filename", "");
        return;
    }
    
    // Standalone Sigil Compiler always outputs to .sigil files
    if (!std.mem.endsWith(u8, path_tok.text, ".sigil")) {
        sigilErr(path_tok.line, path_tok.col, "Standalone Sigil must bind to .sigil files", path_tok.text);
        return;
    }

    current_sigil_path = arena_alloc.allocator().dupe(u8, path_tok.text) catch return;
    current_id_vector = @splat(0);
    // Zero the dense CMS buffer for the new cartridge target
    if (dense_cms) |cms| {
        const cms_bytes: []u8 = @as([*]u8, @ptrCast(@alignCast(cms.ptr)))[0..ghost_state.LOBE_CMS_BYTES];
        @memset(cms_bytes, 0);
    }
    sys.printOut("[BIND] Targeted: "); sys.printOut(path_tok.text); sys.printOut("\n");
}

fn generateWordVec(word: []const u8) vsa.HyperVector {
    var v: vsa.HyperVector = @splat(0);
    for (word) |c| v ^= vsa.generate(c);
    return v;
}

fn executeEtch(lex: *Lexer) void {
    const concept_tok = lex.next();
    const weight_tok  = lex.next();

    if (concept_tok.tag != .string_literal) {
        sigilErr(concept_tok.line, concept_tok.col, "ETCH expects quoted string", "");
        return;
    }

    if (!canExecute()) return;

    const raw_w = if (weight_tok.tag == .weight_literal)
        std.fmt.parseInt(u16, weight_tok.text[1..], 10) catch 15
    else 15;
    const weight: u16 = if (raw_w == 0) 0 else std.math.mul(u16, raw_w, 4096) catch std.math.maxInt(u16);

    // Update ID Vector
    const concept_vec = generateWordVec(concept_tok.text);
    current_id_vector ^= concept_vec;

    // Etch directly into the CMS buffer using saturated addition
    const cms = dense_cms orelse return;
    var window: u64 = 0;
    for (concept_tok.text) |c| {
        const h1 = ghost_state.wyhash(window & 0xFFFF, @as(u64, c));
        const h2 = ghost_state.wyhash(window & 0xFFFFFFFF, @as(u64, c));
        const idx1 = getLobeIndices(h1);
        const idx2 = getLobeIndices(h2);
        inline for (idx1) |i| cms[i] = std.math.add(u16, cms[i], weight) catch std.math.maxInt(u16);
        inline for (idx2) |i| cms[i] = std.math.add(u16, cms[i], weight) catch std.math.maxInt(u16);
        window = std.math.rotl(u64, window, 7) ^ @as(u64, c);
    }

    sys.printOut("[ETCH] "); sys.printOut(concept_tok.text); sys.printOut("\n");
}

fn executeVoid(lex: *Lexer) void {
    const concept_tok = lex.next();

    if (concept_tok.tag != .string_literal) {
        sigilErr(concept_tok.line, concept_tok.col, "VOID expects quoted string", "");
        return;
    }

    if (!canExecute()) return;
    
    // Update ID Vector
    const concept_vec = generateWordVec(concept_tok.text);
    current_id_vector ^= concept_vec;

    const cms = dense_cms orelse return;
    var window: u64 = 0;
    for (concept_tok.text) |c| {
        const h1 = ghost_state.wyhash(window & 0xFFFF, @as(u64, c));
        const h2 = ghost_state.wyhash(window & 0xFFFFFFFF, @as(u64, c));
        const idx1 = getLobeIndices(h1);
        const idx2 = getLobeIndices(h2);
        
        // Use 0xFFFF as a tombstone marker for VOID instructions
        inline for (idx1) |i| cms[i] = 0xFFFF;
        inline for (idx2) |i| cms[i] = 0xFFFF;
        
        window = std.math.rotl(u64, window, 7) ^ @as(u64, c);
    }

    sys.printOut("[VOID] "); sys.printOut(concept_tok.text); sys.printOut("\n");
}

/// CMS probe indices for the Lobe's 67M-entry address space.
fn getLobeIndices(h: u64) [4]u32 {
    const s: u32 = ghost_state.LOBE_CMS_ENTRIES / 4;
    return .{
        @as(u32, @truncate(h & 0xFFFFFFFF)) % s,
        (@as(u32, @truncate(h >> 32)) % s) + s,
        (@as(u32, @truncate(ghost_state.wyhash(h, 0x12345678))) % s) + (s * 2),
        (@as(u32, @truncate(ghost_state.wyhash(h, 0x87654321))) % s) + (s * 3),
    };
}

fn finalizeSigil(allocator: std.mem.Allocator) !void {
    const path = current_sigil_path orelse return;
    const cms = dense_cms orelse return;
    const h = try sys.openForWrite(allocator, path);
    defer sys.closeFile(h);


    // 1. Write VSA Identity Header (128 bytes)
    const id_bytes: [128]u8 = @bitCast(current_id_vector);
    try sys.writeAll(h, &id_bytes);

    // 2. Generate Sparse Deltas
    var output_deltas = std.ArrayListUnmanaged(SparseDelta).empty;
    const alloc = arena_alloc.allocator();
    for (cms, 0..) |val, i| {
        if (val > 0) {
            const index = @as(u32, @intCast(i));
            var delta: i16 = 0;
            if (val == 0xFFFF) {
                // VOID marker
                delta = -32768;
            } else {
                delta = @as(i16, @intCast(@min(val, 32767)));
            }
            try output_deltas.append(alloc, SparseDelta{ .index = index, .delta = delta });
        }
    }

    // 3. Write Sparse Array bounds
    try sys.writeAll(h, std.mem.sliceAsBytes(output_deltas.items));

    sys.printOut("[SIGIL] Saved sparse cartridge: "); sys.printOut(path);
    sys.printOut(" (");
    var buf: [32]u8 = undefined;
    const bytes_saved = output_deltas.items.len * @sizeOf(SparseDelta);
    sys.printOut(std.fmt.bufPrint(&buf, "{d}", .{bytes_saved + 128}) catch "?");
    sys.printOut(" bytes)\n");
}

pub fn main() !void {
    arena_alloc = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_alloc.deinit();
    vars = std.StringHashMap(u16).init(arena_alloc.allocator());

    // Allocate the 128MB dense CMS buffer (zero-initialized)
    const cms_raw = sys.allocSectorAligned(ghost_state.LOBE_CMS_BYTES) orelse {
        sys.printOut("[SIGIL] FATAL: Failed to allocate 128 MiB CMS buffer.\n");
        return;
    };
    defer sys.freeSectorAligned(cms_raw);
    // Reinterpret as u16 array
    dense_cms = @as([*]u16, @ptrCast(@alignCast(cms_raw.ptr)))[0..ghost_state.LOBE_CMS_ENTRIES];
    // Zero-init
    @memset(cms_raw, 0);

    const args = try sys.getArgs(arena_alloc.allocator());
    if (args.len < 2) {
        sys.printOut("Usage: sigil_core <script.sgl>\n");
        return;
    }

    const script_path = args[1];
    const fh = try sys.openForRead(arena_alloc.allocator(), script_path);
    defer sys.closeFile(fh);


    const size = try sys.getFileSize(fh);
    const buffer = try arena_alloc.allocator().alloc(u8, size);
    _ = try sys.readAll(fh, buffer);

    var lex = Lexer{ .buffer = buffer };
    while (true) {
        const tok = lex.next();
        if (tok.tag == .eof) break;
        switch (tok.tag) {
            .keyword_bind => executeBind(&lex),
            .keyword_etch => executeEtch(&lex),
            .keyword_void => executeVoid(&lex),
            .keyword_let => {
                _ = lex.next(); // var
                _ = lex.next(); // =
                _ = lex.next(); // val
            },
            .brace_close => { if (loom_depth > 0) loom_depth -= 1; },
            else => {},
        }
    }

    try finalizeSigil(arena_alloc.allocator());

    sys.printOut("\nSigil compilation complete (128 MiB dense cartridge format).\n");
}
