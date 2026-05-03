const std = @import("std");
const sys = @import("sys.zig");

pub const VERSION = "SVM1";
pub const INVALID_STRING_INDEX = std.math.maxInt(u32);

pub const Opcode = enum(u8) {
    halt,
    mood,
    loom,
    lock,
    scan,
    bind,
    etch,
    void_op,
    jmp_if_false,
};

pub const OperandMode = enum(u8) {
    none,
    string,
    integer,
    rune_and_string,
    loom_command,
    immediate_bool,
};

pub const LoomCommand = enum(u8) {
    none,
    vulkan_init,
    cpu_only,
    proof,
    exploratory,
    tier_1,
    tier_2,
    tier_3,
    tier_4,
};

pub const Instruction = extern struct {
    opcode: Opcode,
    mode: OperandMode,
    a: i64,
    b: i64,
    string_index: u32,
};

pub const Program = struct {
    allocator: std.mem.Allocator,
    instructions: []Instruction,
    strings: [][]const u8,

    pub fn deinit(self: *Program) void {
        for (self.strings) |item| self.allocator.free(item);
        self.allocator.free(self.strings);
        self.allocator.free(self.instructions);
    }
};

/// Sigil is a bounded Ghost procedure/control DSL. Its compiler recognizes only
/// the opcodes in this file; unknown source statements must fail closed instead
/// of becoming comments or implicit authority. Sigil can steer local control
/// state and stage scratch-session meaning candidates. It cannot grant support,
/// execute shell commands, promote negative knowledge, mutate packs directly, or
/// bypass verifier/proof gates.
pub const ValidationScope = enum {
    boot_control,
    scratch_session,
};

pub const ValidationIssueCode = enum {
    missing_halt,
    invalid_operand_mode,
    invalid_string_index,
    invalid_jump_target,
    unsupported_loom_command,
    forbidden_authority_token,
    mutation_requires_scratch_session,
};

pub const ValidationIssue = struct {
    code: ValidationIssueCode,
    instruction_index: usize,
    message: []const u8,
};

pub const DisassemblyInstruction = struct {
    instruction_index: usize,
    opcode: Opcode,
    mode: OperandMode,
    a: i64,
    b: i64,
    string_index: u32,
    string_payload: ?[]const u8,
};

pub const ProcedureCandidateKind = enum {
    halt,
    mood_control,
    loom_control,
    lock_control,
    scan_target,
    bind_candidate,
    etch_candidate,
    void_candidate,
    test_jump,
    unknown_procedure,
};

pub const ProcedureInspectionRecord = struct {
    instruction_index: usize,
    kind: ProcedureCandidateKind,
    opcode: Opcode,
    operand_mode: OperandMode,
    a: i64,
    b: i64,
    string_index: u32,
    string_payload: ?[]const u8,
    non_authorizing: bool = true,
    authority_effect: []const u8,
    requires_review: bool,
    requires_verification: bool,
};

pub const Disassembly = struct {
    allocator: std.mem.Allocator,
    validation_scope: ValidationScope,
    validation_issue: ?ValidationIssue,
    instructions: []DisassemblyInstruction,
    procedure_records: []ProcedureInspectionRecord,

    pub fn deinit(self: *Disassembly) void {
        self.allocator.free(self.instructions);
        self.allocator.free(self.procedure_records);
    }
};

const AtomTag = enum {
    keyword_bind,
    keyword_etch,
    keyword_loom,
    keyword_lock,
    keyword_mood,
    keyword_scan,
    keyword_test,
    keyword_void,
    identifier,
    string_literal,
    number_literal,
    weight_literal,
    brace_open,
    brace_close,
    eof,
    invalid,
};

const Atom = struct {
    tag: AtomTag,
    text: []const u8,
    line: u32,
    col: u32,
};

const CompileError = error{
    ParseFailed,
};

const Lexer = struct {
    buffer: []const u8,
    pos: usize = 0,
    line: u32 = 1,
    col: u32 = 1,

    fn advance(self: *Lexer) void {
        if (self.pos >= self.buffer.len) return;
        if (self.buffer[self.pos] == '\n') {
            self.line += 1;
            self.col = 1;
        } else {
            self.col += 1;
        }
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
            } else {
                break;
            }
        }
    }

    fn next(self: *Lexer) Atom {
        self.skipWhitespace();
        const start = self.pos;
        const line = self.line;
        const col = self.col;

        if (self.pos >= self.buffer.len) {
            return .{ .tag = .eof, .text = "", .line = line, .col = col };
        }

        const c = self.buffer[self.pos];
        if (c == '"') {
            self.advance();
            const str_start = self.pos;
            while (self.pos < self.buffer.len and self.buffer[self.pos] != '"') self.advance();
            if (self.pos >= self.buffer.len) {
                return .{ .tag = .invalid, .text = "Unterminated string", .line = line, .col = col };
            }
            const text = self.buffer[str_start..self.pos];
            self.advance();
            return .{ .tag = .string_literal, .text = text, .line = line, .col = col };
        }

        if (c == '@') {
            self.advance();
            const weight_start = self.pos;
            while (self.pos < self.buffer.len and isNumberChar(self.buffer[self.pos])) self.advance();
            return .{ .tag = .weight_literal, .text = self.buffer[weight_start..self.pos], .line = line, .col = col };
        }

        if (std.ascii.isDigit(c)) {
            self.advance();
            if (c == '0' and (self.pos < self.buffer.len) and (self.buffer[self.pos] == 'x' or self.buffer[self.pos] == 'X')) {
                self.advance();
            }
            while (self.pos < self.buffer.len and isNumberChar(self.buffer[self.pos])) self.advance();
            return .{ .tag = .number_literal, .text = self.buffer[start..self.pos], .line = line, .col = col };
        }

        switch (c) {
            '{' => {
                self.advance();
                return .{ .tag = .brace_open, .text = "{", .line = line, .col = col };
            },
            '}' => {
                self.advance();
                return .{ .tag = .brace_close, .text = "}", .line = line, .col = col };
            },
            else => {},
        }

        if (c > 127 or std.ascii.isAlphabetic(c) or c == '_') {
            while (self.pos < self.buffer.len) {
                const peek_c = self.buffer[self.pos];
                if (peek_c > 127 or std.ascii.isAlphanumeric(peek_c) or peek_c == '_') {
                    self.advance();
                } else {
                    break;
                }
            }

            const text = self.buffer[start..self.pos];
            if (std.mem.eql(u8, text, "BIND")) return .{ .tag = .keyword_bind, .text = text, .line = line, .col = col };
            if (std.mem.eql(u8, text, "ETCH")) return .{ .tag = .keyword_etch, .text = text, .line = line, .col = col };
            if (std.mem.eql(u8, text, "LOOM")) return .{ .tag = .keyword_loom, .text = text, .line = line, .col = col };
            if (std.mem.eql(u8, text, "LOCK")) return .{ .tag = .keyword_lock, .text = text, .line = line, .col = col };
            if (std.mem.eql(u8, text, "MOOD")) return .{ .tag = .keyword_mood, .text = text, .line = line, .col = col };
            if (std.mem.eql(u8, text, "SCAN")) return .{ .tag = .keyword_scan, .text = text, .line = line, .col = col };
            if (std.mem.eql(u8, text, "TEST")) return .{ .tag = .keyword_test, .text = text, .line = line, .col = col };
            if (std.mem.eql(u8, text, "VOID")) return .{ .tag = .keyword_void, .text = text, .line = line, .col = col };
            return .{ .tag = .identifier, .text = text, .line = line, .col = col };
        }

        self.advance();
        return .{ .tag = .invalid, .text = self.buffer[start..self.pos], .line = line, .col = col };
    }
};

const Parser = struct {
    allocator: std.mem.Allocator,
    tokens: []Atom,
    idx: usize = 0,
    instructions: std.ArrayList(Instruction),
    strings: std.ArrayList([]const u8),

    fn init(allocator: std.mem.Allocator, tokens: []Atom) Parser {
        return .{
            .allocator = allocator,
            .tokens = tokens,
            .instructions = std.ArrayList(Instruction).init(allocator),
            .strings = std.ArrayList([]const u8).init(allocator),
        };
    }

    fn deinit(self: *Parser) void {
        self.instructions.deinit();
        self.strings.deinit();
    }

    fn current(self: *Parser) Atom {
        return self.tokens[@min(self.idx, self.tokens.len - 1)];
    }

    fn advance(self: *Parser) void {
        if (self.idx < self.tokens.len - 1) self.idx += 1;
    }

    fn consume(self: *Parser, expected: AtomTag, comptime message: []const u8) anyerror!Atom {
        const token = self.current();
        if (token.tag != expected) {
            reportError(token.line, token.col, message, token.text);
            return error.ParseFailed;
        }
        self.advance();
        return token;
    }

    fn appendString(self: *Parser, text: []const u8) anyerror!u32 {
        const owned = try self.allocator.dupe(u8, text);
        try self.strings.append(owned);
        return @intCast(self.strings.items.len - 1);
    }

    fn emit(self: *Parser, opcode: Opcode, mode: OperandMode, a: i64, b: i64, string_index: u32) anyerror!usize {
        try self.instructions.append(.{
            .opcode = opcode,
            .mode = mode,
            .a = a,
            .b = b,
            .string_index = string_index,
        });
        return self.instructions.items.len - 1;
    }

    fn parseProgram(self: *Parser) anyerror!void {
        while (self.current().tag != .eof and self.current().tag != .brace_close) {
            try self.parseStatement();
        }
        _ = try self.emit(.halt, .none, 0, 0, INVALID_STRING_INDEX);
    }

    fn parseStatement(self: *Parser) anyerror!void {
        switch (self.current().tag) {
            .keyword_mood => try self.parseMood(),
            .keyword_loom => try self.parseLoom(),
            .keyword_lock => try self.parseLock(),
            .keyword_scan => try self.parseScan(),
            .keyword_bind => try self.parseBind(),
            .keyword_etch => try self.parseEtch(),
            .keyword_void => try self.parseVoid(),
            .keyword_test => try self.parseTest(),
            .brace_close => {},
            .invalid => {
                const token = self.current();
                reportError(token.line, token.col, "Invalid token", token.text);
                return error.ParseFailed;
            },
            else => {
                const token = self.current();
                reportError(token.line, token.col, "Unknown Sigil statement", token.text);
                return error.ParseFailed;
            },
        }
    }

    fn parseMood(self: *Parser) anyerror!void {
        self.advance();
        const token = self.current();
        switch (token.tag) {
            .string_literal, .identifier => {
                const idx = try self.appendString(token.text);
                self.advance();
                _ = try self.emit(.mood, .string, 0, 0, idx);
            },
            .number_literal => {
                const value = try parseInteger(token.text);
                self.advance();
                _ = try self.emit(.mood, .integer, value, 0, INVALID_STRING_INDEX);
            },
            else => {
                reportError(token.line, token.col, "MOOD expects a name or integer", token.text);
                return error.ParseFailed;
            },
        }
    }

    fn parseLoom(self: *Parser) anyerror!void {
        self.advance();
        const token = try self.consume(.identifier, "LOOM expects an identifier");
        const command = parseLoomCommand(token.text);
        _ = try self.emit(.loom, .loom_command, @intFromEnum(command), 0, INVALID_STRING_INDEX);
    }

    fn parseLock(self: *Parser) anyerror!void {
        self.advance();
        const token = self.current();
        switch (token.tag) {
            .number_literal => {
                const value = try parseInteger(token.text);
                self.advance();
                _ = try self.emit(.lock, .integer, value, 0, INVALID_STRING_INDEX);
            },
            .string_literal, .identifier => {
                const idx = try self.appendString(token.text);
                self.advance();
                _ = try self.emit(.lock, .string, 0, 0, idx);
            },
            else => {
                reportError(token.line, token.col, "LOCK expects a slot number or symbol", token.text);
                return error.ParseFailed;
            },
        }
    }

    fn parseScan(self: *Parser) anyerror!void {
        self.advance();
        const token = self.current();
        if (token.tag != .string_literal and token.tag != .identifier) {
            reportError(token.line, token.col, "SCAN expects a string or identifier target", token.text);
            return error.ParseFailed;
        }
        const idx = try self.appendString(token.text);
        self.advance();
        _ = try self.emit(.scan, .string, 0, 0, idx);
    }

    fn parseBind(self: *Parser) anyerror!void {
        self.advance();
        const rune_token = self.current();
        if (rune_token.tag != .number_literal) {
            reportError(rune_token.line, rune_token.col, "BIND expects a rune literal", rune_token.text);
            return error.ParseFailed;
        }
        const rune_value = try parseInteger(rune_token.text);
        self.advance();

        const maybe_to = self.current();
        if (maybe_to.tag == .identifier and std.ascii.eqlIgnoreCase(maybe_to.text, "TO")) self.advance();

        const label_token = self.current();
        if (label_token.tag != .string_literal and label_token.tag != .identifier) {
            reportError(label_token.line, label_token.col, "BIND expects a label", label_token.text);
            return error.ParseFailed;
        }
        const idx = try self.appendString(label_token.text);
        self.advance();
        _ = try self.emit(.bind, .rune_and_string, rune_value, 0, idx);
    }

    fn parseEtch(self: *Parser) anyerror!void {
        self.advance();
        const text_token = self.current();
        if (text_token.tag != .string_literal and text_token.tag != .identifier) {
            reportError(text_token.line, text_token.col, "ETCH expects a string payload", text_token.text);
            return error.ParseFailed;
        }
        const idx = try self.appendString(text_token.text);
        self.advance();

        var weight: i64 = 1;
        if (self.current().tag == .weight_literal or self.current().tag == .number_literal) {
            weight = try parseInteger(self.current().text);
            self.advance();
        }
        _ = try self.emit(.etch, .string, weight, 0, idx);
    }

    fn parseVoid(self: *Parser) anyerror!void {
        self.advance();
        const token = self.current();
        if (token.tag != .string_literal and token.tag != .identifier) {
            reportError(token.line, token.col, "VOID expects a string payload", token.text);
            return error.ParseFailed;
        }
        const idx = try self.appendString(token.text);
        self.advance();
        _ = try self.emit(.void_op, .string, 0, 0, idx);
    }

    fn parseTest(self: *Parser) anyerror!void {
        self.advance();
        const condition_token = self.current();
        const cond = switch (condition_token.tag) {
            .number_literal => (try parseInteger(condition_token.text)) != 0,
            .identifier => !std.ascii.eqlIgnoreCase(condition_token.text, "FALSE") and !std.ascii.eqlIgnoreCase(condition_token.text, "OFF"),
            .string_literal => condition_token.text.len > 0,
            else => {
                reportError(condition_token.line, condition_token.col, "TEST expects a literal condition", condition_token.text);
                return error.ParseFailed;
            },
        };
        self.advance();
        _ = try self.consume(.brace_open, "TEST expects a '{' block");
        const jmp_index = try self.emit(.jmp_if_false, .immediate_bool, if (cond) 1 else 0, 0, INVALID_STRING_INDEX);
        while (self.current().tag != .brace_close and self.current().tag != .eof) {
            try self.parseStatement();
        }
        _ = try self.consume(.brace_close, "Missing closing '}' for TEST block");
        self.instructions.items[jmp_index].b = @intCast(self.instructions.items.len);
    }
};

pub fn compileScript(allocator: std.mem.Allocator, source: []const u8) !Program {
    var lexer = Lexer{ .buffer = source };
    var tokens = std.ArrayList(Atom).init(allocator);
    defer tokens.deinit();

    while (true) {
        const token = lexer.next();
        try tokens.append(token);
        if (token.tag == .eof) break;
    }

    var parser = Parser.init(allocator, tokens.items);
    defer parser.deinit();
    try parser.parseProgram();

    return .{
        .allocator = allocator,
        .instructions = try parser.instructions.toOwnedSlice(),
        .strings = try parser.strings.toOwnedSlice(),
    };
}

pub fn validateProgram(program: *const Program, scope: ValidationScope) !void {
    const validation_issue = firstValidationIssue(program, scope) orelse return;
    reportValidationIssue(validation_issue);
    return error.SigilValidationFailed;
}

pub fn firstValidationIssue(program: *const Program, scope: ValidationScope) ?ValidationIssue {
    if (program.instructions.len == 0 or program.instructions[program.instructions.len - 1].opcode != .halt) {
        return issue(.missing_halt, program.instructions.len, "Sigil program must end with HALT");
    }

    for (program.instructions, 0..) |inst, index| {
        if (!operandModeAllowed(inst.opcode, inst.mode)) {
            return issue(.invalid_operand_mode, index, "Sigil instruction has an invalid operand mode");
        }
        if (inst.mode == .string or inst.mode == .rune_and_string) {
            if (inst.string_index == INVALID_STRING_INDEX or inst.string_index >= program.strings.len) {
                return issue(.invalid_string_index, index, "Sigil instruction references an invalid string");
            }
            if (isForbiddenAuthorityToken(program.strings[inst.string_index])) {
                return issue(.forbidden_authority_token, index, "Sigil source names an authority-forbidden operation");
            }
        }
        switch (inst.opcode) {
            .loom => {
                if (inst.a < 0 or inst.a > std.math.maxInt(u8)) {
                    return issue(.unsupported_loom_command, index, "Sigil LOOM command is unsupported");
                }
                const command = std.meta.intToEnum(LoomCommand, @as(u8, @intCast(inst.a))) catch .none;
                if (command == .none) {
                    return issue(.unsupported_loom_command, index, "Sigil LOOM command is unsupported");
                }
            },
            .bind, .etch, .void_op => {
                if (scope != .scratch_session) {
                    return issue(.mutation_requires_scratch_session, index, "Sigil meaning mutation requires an explicit scratch session");
                }
            },
            .jmp_if_false => {
                if (inst.b < 0 or @as(usize, @intCast(inst.b)) > program.instructions.len) {
                    return issue(.invalid_jump_target, index, "Sigil jump target is outside the program");
                }
            },
            else => {},
        }
    }
    return null;
}

pub fn disassembleProgram(allocator: std.mem.Allocator, program: *const Program, scope: ValidationScope) !Disassembly {
    var instructions = std.ArrayList(DisassemblyInstruction).init(allocator);
    errdefer instructions.deinit();

    var procedure_records = std.ArrayList(ProcedureInspectionRecord).init(allocator);
    errdefer procedure_records.deinit();

    for (program.instructions, 0..) |inst, index| {
        const payload = instructionStringPayload(program, inst);
        try instructions.append(.{
            .instruction_index = index,
            .opcode = inst.opcode,
            .mode = inst.mode,
            .a = inst.a,
            .b = inst.b,
            .string_index = inst.string_index,
            .string_payload = payload,
        });
        try procedure_records.append(procedureRecordForInstruction(index, inst, payload));
    }

    return .{
        .allocator = allocator,
        .validation_scope = scope,
        .validation_issue = firstValidationIssue(program, scope),
        .instructions = try instructions.toOwnedSlice(),
        .procedure_records = try procedure_records.toOwnedSlice(),
    };
}

pub fn renderDisassembly(allocator: std.mem.Allocator, program: *const Program, scope: ValidationScope) ![]u8 {
    var disassembly = try disassembleProgram(allocator, program, scope);
    defer disassembly.deinit();

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const writer = out.writer();

    try writer.print("sigil_disassembly version={s} scope={s} instructions={d} strings={d}\n", .{
        VERSION,
        @tagName(scope),
        program.instructions.len,
        program.strings.len,
    });
    if (disassembly.validation_issue) |validation_issue| {
        try writer.print("validation=failed instruction={d} code={s} message=\"{s}\"\n", .{
            validation_issue.instruction_index,
            @tagName(validation_issue.code),
            validation_issue.message,
        });
    } else {
        try writer.writeAll("validation=ok safety=\"candidate/control only; not proof; not support; no VM execution\"\n");
    }

    try writer.writeAll("[instructions]\n");
    for (disassembly.instructions) |inst| {
        try writer.print(
            "{d:0>4} opcode={s} mode={s} a={d} b={d} string_index=",
            .{
                inst.instruction_index,
                @tagName(inst.opcode),
                @tagName(inst.mode),
                inst.a,
                inst.b,
            },
        );
        try writeStringIndex(writer, inst.string_index);
        if (inst.string_payload) |payload| {
            try writer.print(" string=\"{s}\"", .{payload});
        }
        try writer.writeByte('\n');
    }

    try writer.writeAll("[procedure_records]\n");
    for (disassembly.procedure_records) |record| {
        try writer.print(
            "{d:0>4} kind={s} opcode={s} mode={s} authority_effect={s} non_authorizing={s} requires_review={s} requires_verification={s}",
            .{
                record.instruction_index,
                @tagName(record.kind),
                @tagName(record.opcode),
                @tagName(record.operand_mode),
                record.authority_effect,
                boolText(record.non_authorizing),
                boolText(record.requires_review),
                boolText(record.requires_verification),
            },
        );
        if (record.string_payload) |payload| {
            try writer.print(" payload=\"{s}\"", .{payload});
        }
        try writer.print(" a={d} b={d} string_index=", .{
            record.a,
            record.b,
        });
        try writeStringIndex(writer, record.string_index);
        try writer.writeByte('\n');
    }

    return out.toOwnedSlice();
}

fn instructionStringPayload(program: *const Program, inst: Instruction) ?[]const u8 {
    if ((inst.mode == .string or inst.mode == .rune_and_string) and inst.string_index != INVALID_STRING_INDEX and inst.string_index < program.strings.len) {
        return program.strings[inst.string_index];
    }
    return null;
}

fn procedureRecordForInstruction(index: usize, inst: Instruction, payload: ?[]const u8) ProcedureInspectionRecord {
    const kind: ProcedureCandidateKind = switch (inst.opcode) {
        .halt => .halt,
        .mood => .mood_control,
        .loom => .loom_control,
        .lock => .lock_control,
        .scan => .scan_target,
        .bind => .bind_candidate,
        .etch => .etch_candidate,
        .void_op => .void_candidate,
        .jmp_if_false => .test_jump,
    };
    const requires_review = switch (kind) {
        .bind_candidate, .etch_candidate, .void_candidate => true,
        else => false,
    };
    const requires_verification = switch (kind) {
        .scan_target, .bind_candidate, .etch_candidate, .void_candidate => true,
        else => false,
    };
    const authority_effect: []const u8 = switch (kind) {
        .halt, .test_jump => "none",
        else => "candidate",
    };

    return .{
        .instruction_index = index,
        .kind = kind,
        .opcode = inst.opcode,
        .operand_mode = inst.mode,
        .a = inst.a,
        .b = inst.b,
        .string_index = inst.string_index,
        .string_payload = payload,
        .non_authorizing = true,
        .authority_effect = authority_effect,
        .requires_review = requires_review,
        .requires_verification = requires_verification,
    };
}

fn writeStringIndex(writer: anytype, index: u32) !void {
    if (index == INVALID_STRING_INDEX) {
        try writer.writeAll("none");
    } else {
        try writer.print("{d}", .{index});
    }
}

fn boolText(value: bool) []const u8 {
    return if (value) "true" else "false";
}

fn issue(code: ValidationIssueCode, instruction_index: usize, message: []const u8) ValidationIssue {
    return .{
        .code = code,
        .instruction_index = instruction_index,
        .message = message,
    };
}

fn operandModeAllowed(opcode: Opcode, mode: OperandMode) bool {
    return switch (opcode) {
        .halt => mode == .none,
        .mood => mode == .string or mode == .integer,
        .loom => mode == .loom_command,
        .lock => mode == .integer or mode == .string,
        .scan => mode == .string,
        .bind => mode == .rune_and_string,
        .etch => mode == .string,
        .void_op => mode == .string,
        .jmp_if_false => mode == .immediate_bool,
    };
}

fn isForbiddenAuthorityToken(text: []const u8) bool {
    const forbidden = [_][]const u8{
        "support",
        "supported",
        "grant_support",
        "proof_grant",
        "bypass_proof",
        "shell",
        "exec",
        "execute_shell",
        "system",
        "sh",
        "bash",
        "negative_knowledge.promote",
        "nk_promote",
        "promote_negative_knowledge",
        "pack_mutate",
        "pack_commit",
        "pack.update_from_negative_knowledge",
    };
    for (forbidden) |item| {
        if (std.ascii.eqlIgnoreCase(text, item)) return true;
    }
    return false;
}

fn reportValidationIssue(validation_issue: ValidationIssue) void {
    std.debug.print(
        "[SIGIL VALIDATION] instruction={d} code={s}: {s}\n",
        .{ validation_issue.instruction_index, @tagName(validation_issue.code), validation_issue.message },
    );
}

test "sigil validation accepts bounded control scripts" {
    const allocator = std.testing.allocator;

    var program = try compileScript(allocator,
        \\MOOD "focused"
        \\LOOM CPU_ONLY
        \\LOOM TIER_1
        \\LOCK 7
        \\SCAN "system_memory"
    );
    defer program.deinit();

    try validateProgram(&program, .boot_control);
}

test "sigil validation keeps meaning mutation scratch scoped" {
    const allocator = std.testing.allocator;

    var program = try compileScript(allocator,
        \\BIND 65 TO alpha
        \\ETCH "candidate_anchor" @2
        \\VOID "candidate_void"
    );
    defer program.deinit();

    try validateProgram(&program, .scratch_session);
    try std.testing.expectError(error.SigilValidationFailed, validateProgram(&program, .boot_control));
}

test "sigil validation fails unknown source and unsupported loom" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(error.ParseFailed, compileScript(allocator, "SHELL \"echo hidden\""));

    var program = try compileScript(allocator, "LOOM SUPPORT");
    defer program.deinit();
    const validation_issue = firstValidationIssue(&program, .scratch_session) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(ValidationIssueCode.unsupported_loom_command, validation_issue.code);
}

test "sigil validation blocks authority and global mutation tokens" {
    const allocator = std.testing.allocator;

    var support_program = try compileScript(allocator, "SCAN \"support\"");
    defer support_program.deinit();
    const support_issue = firstValidationIssue(&support_program, .scratch_session) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(ValidationIssueCode.forbidden_authority_token, support_issue.code);

    var nk_program = try compileScript(allocator, "SCAN \"negative_knowledge.promote\"");
    defer nk_program.deinit();
    const nk_issue = firstValidationIssue(&nk_program, .scratch_session) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(ValidationIssueCode.forbidden_authority_token, nk_issue.code);

    var pack_program = try compileScript(allocator, "SCAN \"pack.update_from_negative_knowledge\"");
    defer pack_program.deinit();
    const pack_issue = firstValidationIssue(&pack_program, .scratch_session) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(ValidationIssueCode.forbidden_authority_token, pack_issue.code);
}

test "sigil disassembly is deterministic for safe loom scripts" {
    const allocator = std.testing.allocator;

    var program = try compileScript(allocator,
        \\LOOM CPU_ONLY
        \\LOOM TIER_1
        \\SCAN "system_memory"
    );
    defer program.deinit();

    const rendered = try renderDisassembly(allocator, &program, .boot_control);
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        \\sigil_disassembly version=SVM1 scope=boot_control instructions=4 strings=1
        \\validation=ok safety="candidate/control only; not proof; not support; no VM execution"
        \\[instructions]
        \\0000 opcode=loom mode=loom_command a=2 b=0 string_index=none
        \\0001 opcode=loom mode=loom_command a=5 b=0 string_index=none
        \\0002 opcode=scan mode=string a=0 b=0 string_index=0 string="system_memory"
        \\0003 opcode=halt mode=none a=0 b=0 string_index=none
        \\[procedure_records]
        \\0000 kind=loom_control opcode=loom mode=loom_command authority_effect=candidate non_authorizing=true requires_review=false requires_verification=false a=2 b=0 string_index=none
        \\0001 kind=loom_control opcode=loom mode=loom_command authority_effect=candidate non_authorizing=true requires_review=false requires_verification=false a=5 b=0 string_index=none
        \\0002 kind=scan_target opcode=scan mode=string authority_effect=candidate non_authorizing=true requires_review=false requires_verification=true payload="system_memory" a=0 b=0 string_index=0
        \\0003 kind=halt opcode=halt mode=none authority_effect=none non_authorizing=true requires_review=false requires_verification=false a=0 b=0 string_index=none
        \\
    , rendered);
}

test "sigil disassembly exposes test block jump targets without executing" {
    const allocator = std.testing.allocator;

    var program = try compileScript(allocator,
        \\TEST FALSE {
        \\  SCAN "system_memory"
        \\}
    );
    defer program.deinit();

    var disassembly = try disassembleProgram(allocator, &program, .boot_control);
    defer disassembly.deinit();

    try std.testing.expect(disassembly.validation_issue == null);
    try std.testing.expectEqual(@as(usize, 3), disassembly.instructions.len);
    try std.testing.expectEqual(Opcode.jmp_if_false, disassembly.instructions[0].opcode);
    try std.testing.expectEqual(@as(i64, 0), disassembly.instructions[0].a);
    try std.testing.expectEqual(@as(i64, 2), disassembly.instructions[0].b);
    try std.testing.expectEqual(ProcedureCandidateKind.test_jump, disassembly.procedure_records[0].kind);
    try std.testing.expectEqualStrings("none", disassembly.procedure_records[0].authority_effect);
}

test "sigil disassembly marks scratch mutation procedure records as candidates only" {
    const allocator = std.testing.allocator;

    var program = try compileScript(allocator,
        \\BIND 65 TO alpha
        \\ETCH "candidate_anchor" @2
        \\VOID "candidate_void"
    );
    defer program.deinit();

    var disassembly = try disassembleProgram(allocator, &program, .scratch_session);
    defer disassembly.deinit();

    try std.testing.expect(disassembly.validation_issue == null);
    try std.testing.expectEqual(ProcedureCandidateKind.bind_candidate, disassembly.procedure_records[0].kind);
    try std.testing.expectEqual(ProcedureCandidateKind.etch_candidate, disassembly.procedure_records[1].kind);
    try std.testing.expectEqual(ProcedureCandidateKind.void_candidate, disassembly.procedure_records[2].kind);
    for (disassembly.procedure_records[0..3]) |record| {
        try std.testing.expect(record.non_authorizing);
        try std.testing.expectEqualStrings("candidate", record.authority_effect);
        try std.testing.expect(record.requires_review);
        try std.testing.expect(record.requires_verification);
    }

    const boot_issue = firstValidationIssue(&program, .boot_control) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(ValidationIssueCode.mutation_requires_scratch_session, boot_issue.code);
}

test "sigil disassembly reports validation failure without VM execution" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(error.ParseFailed, compileScript(allocator, "SHELL \"echo hidden\""));

    var program = try compileScript(allocator, "SCAN \"support\"");
    defer program.deinit();

    var disassembly = try disassembleProgram(allocator, &program, .scratch_session);
    defer disassembly.deinit();

    const validation_issue = disassembly.validation_issue orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(ValidationIssueCode.forbidden_authority_token, validation_issue.code);
    try std.testing.expectEqual(@as(usize, 0), validation_issue.instruction_index);
    try std.testing.expectEqual(ProcedureCandidateKind.scan_target, disassembly.procedure_records[0].kind);
    try std.testing.expect(disassembly.procedure_records[0].non_authorizing);
    try std.testing.expect(disassembly.procedure_records[0].requires_verification);
}

pub fn serializeProgram(allocator: std.mem.Allocator, program: *const Program) ![]u8 {
    var output = std.ArrayList(u8).init(allocator);
    errdefer output.deinit();

    try output.appendSlice("SVM1");

    var counts: [2]u32 = .{
        @intCast(program.instructions.len),
        @intCast(program.strings.len),
    };
    try output.appendSlice(std.mem.asBytes(&counts));
    try output.appendSlice(std.mem.sliceAsBytes(program.instructions));

    for (program.strings) |item| {
        const len: u32 = @intCast(item.len);
        try output.appendSlice(std.mem.asBytes(&len));
        try output.appendSlice(item);
    }

    return output.toOwnedSlice();
}

fn parseLoomCommand(text: []const u8) LoomCommand {
    if (std.ascii.eqlIgnoreCase(text, "VULKAN_INIT")) return .vulkan_init;
    if (std.ascii.eqlIgnoreCase(text, "CPU_ONLY")) return .cpu_only;
    if (std.ascii.eqlIgnoreCase(text, "PROOF")) return .proof;
    if (std.ascii.eqlIgnoreCase(text, "EXPLORATORY")) return .exploratory;
    if (std.ascii.eqlIgnoreCase(text, "TIER_1")) return .tier_1;
    if (std.ascii.eqlIgnoreCase(text, "TIER_2")) return .tier_2;
    if (std.ascii.eqlIgnoreCase(text, "TIER_3")) return .tier_3;
    if (std.ascii.eqlIgnoreCase(text, "TIER_4")) return .tier_4;
    return .none;
}

fn parseInteger(text: []const u8) !i64 {
    if (std.mem.startsWith(u8, text, "0x") or std.mem.startsWith(u8, text, "0X")) {
        return std.fmt.parseInt(i64, text[2..], 16);
    }
    return std.fmt.parseInt(i64, text, 10);
}

fn isNumberChar(c: u8) bool {
    return std.ascii.isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F') or c == 'x' or c == 'X';
}

fn reportError(line: u32, col: u32, msg: []const u8, extra: []const u8) void {
    std.debug.print("[SIGIL ERR {d}:{d}] {s}: {s}\n", .{ line, col, msg, extra });
}

fn parseValidationScope(text: []const u8) ?ValidationScope {
    if (std.ascii.eqlIgnoreCase(text, "boot_control")) return .boot_control;
    if (std.ascii.eqlIgnoreCase(text, "scratch_session")) return .scratch_session;
    return null;
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try sys.getArgs(allocator);
    if (args.len < 2) {
        sys.printOut("Usage: sigil_core <script.sigil> [output.sigbc]\n");
        sys.printOut("       sigil_core --disassemble <script.sigil> [boot_control|scratch_session]\n");
        return;
    }

    const disassemble_only = std.mem.eql(u8, args[1], "--disassemble");
    const input_path = if (disassemble_only) blk: {
        if (args.len < 3) {
            sys.printOut("Usage: sigil_core --disassemble <script.sigil> [boot_control|scratch_session]\n");
            return;
        }
        break :blk args[2];
    } else args[1];
    const input_handle = try sys.openForRead(allocator, input_path);
    defer sys.closeFile(input_handle);

    const input_size = try sys.getFileSize(input_handle);
    const buffer = try allocator.alloc(u8, input_size);
    _ = try sys.readAll(input_handle, buffer);

    var program = try compileScript(allocator, buffer);
    defer program.deinit();

    if (disassemble_only) {
        const scope = if (args.len >= 4) parseValidationScope(args[3]) orelse {
            std.debug.print("[SIGIL ERR] unknown validation scope: {s}\n", .{args[3]});
            return error.SigilValidationFailed;
        } else ValidationScope.scratch_session;
        const rendered = try renderDisassembly(allocator, &program, scope);
        const stdout = std.io.getStdOut().writer();
        try stdout.writeAll(rendered);
        return;
    }

    try validateProgram(&program, .scratch_session);

    const output_path = if (args.len >= 3) args[2] else blk: {
        const ext = std.fs.path.extension(input_path);
        if (ext.len == 0) break :blk try std.fmt.allocPrint(allocator, "{s}.sigbc", .{input_path});
        const stem = input_path[0 .. input_path.len - ext.len];
        break :blk try std.fmt.allocPrint(allocator, "{s}.sigbc", .{stem});
    };

    const output_handle = try sys.openForWrite(allocator, output_path);
    defer sys.closeFile(output_handle);

    const serialized = try serializeProgram(allocator, &program);
    try sys.writeAll(output_handle, serialized);

    sys.print("[SIGIL] Compiled {s} -> {s} ({d} instructions)\n", .{ input_path, output_path, program.instructions.len });
}
