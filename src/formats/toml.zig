const std = @import("std");
const common = @import("common.zig");
const Parsed = common.Parsed;

/// Internal state for the TOML parser.
const Parser = struct {
    allocator: std.mem.Allocator,
    /// The source input split into lines.
    line_iterator: std.mem.SplitIterator(u8, .scalar),
    /// The current line being peeked/examined.
    line_ptr: ?[]const u8,

    fn next(self: *Parser) void {
        self.line_ptr = self.line_iterator.next();
    }
};

/// Defines the current context of the recursive descent parser.
const Mode = enum {
    /// The top-level of the TOML document.
    root,
    /// A nested [table].
    nested,
    /// An element within a [[table_array]].
    array_element,
};

/// Returns a comptime-generated TOML serializer/deserializer for type `T`.
pub fn Serde(comptime T: type) type {
    return struct {
        /// Writes `value` as TOML to `writer`.
        pub fn serialize(writer: *std.Io.Writer, value: T) !void {
            comptime common.validateFieldConfigs(.toml, T);
            try writeTable(writer, value);
        }

        /// Parses `source` as TOML into a `Parsed(T)` that owns all allocated memory.
        /// Caller must call `deinit()`.
        pub fn deserialize(allocator: std.mem.Allocator, source: []const u8) !Parsed(T) {
            comptime common.validateFieldConfigs(.toml, T);
            var arena = std.heap.ArenaAllocator.init(allocator);
            errdefer arena.deinit();

            const arena_allocator = arena.allocator();
            var parser = Parser{
                .allocator = arena_allocator,
                .line_iterator = std.mem.splitScalar(u8, source, '\n'),
                .line_ptr = null,
            };
            // Prime the first line.
            parser.next();

            const value = try parseStructFull(T, &parser, .root);

            return .{ .arena = arena, .value = value };
        }
    };
}

// ==================== Serialization ====================

/// Writes a struct as TOML: key-value pairs first, then nested table sections.
fn writeTable(writer: *std.Io.Writer, value: anytype) !void {
    const T = @TypeOf(value);
    const type_info = @typeInfo(T);
    switch (type_info) {
        .@"struct" => |struct_info| {
            // Pass 1: write key-value pairs (primitives, strings, inline arrays).
            inline for (struct_info.fields) |field| {
                const field_key = common.serializedFieldName(.toml, T, field.name);
                const field_value = @field(value, field.name);
                if (common.shouldIncludeField(.toml, T, field.name, field_value)) {
                    const field_type_info = @typeInfo(field.type);
                    switch (field_type_info) {
                        .@"struct" => {}, // Handled in pass 2.
                        .optional => |optional_type_info| {
                            // Optional struct: handled in pass 2; optional primitives: write inline.
                            if (@typeInfo(optional_type_info.child) == .@"struct") {
                                // Handled in pass 2.
                            } else {
                                try writeKeyValue(writer, field_key, field_value);
                            }
                        },
                        .pointer => |pointer_type_info| {
                            if (pointer_type_info.size == .slice) {
                                if (pointer_type_info.child == u8) {
                                    // String slice → inline KV.
                                    try writeKeyValue(writer, field_key, field_value);
                                } else {
                                    // Non-string slice: inline if primitives, table array if structs.
                                    const child_type_info = @typeInfo(pointer_type_info.child);
                                    if (child_type_info != .@"struct") {
                                        try writeKeyValue(writer, field_key, field_value);
                                    }
                                }
                            }
                        },
                        else => {
                            try writeKeyValue(writer, field_key, field_value);
                        },
                    }
                }
            }
            // Pass 2: write [table] and [[array]] sections.
            inline for (struct_info.fields) |field| {
                const field_key = common.serializedFieldName(.toml, T, field.name);
                const field_value = @field(value, field.name);
                if (common.shouldIncludeField(.toml, T, field.name, field_value)) {
                    const field_type_info = @typeInfo(field.type);
                    switch (field_type_info) {
                        .@"struct" => {
                            try writer.print("[{s}]\n", .{field_key});
                            try writeTable(writer, field_value);
                        },
                        .optional => |optional_type_info| {
                            if (@typeInfo(optional_type_info.child) == .@"struct") {
                                if (field_value) |present| {
                                    try writer.print("[{s}]\n", .{field_key});
                                    try writeTable(writer, present);
                                }
                            }
                        },
                        .pointer => |pointer_type_info| {
                            if (pointer_type_info.size == .slice) {
                                if (pointer_type_info.child != u8) {
                                    const child_type_info = @typeInfo(pointer_type_info.child);
                                    if (child_type_info == .@"struct") {
                                        for (field_value) |item| {
                                            try writer.print("[[{s}]]\n", .{field_key});
                                            try writeTable(writer, item);
                                        }
                                    }
                                }
                            }
                        },
                        .array => |array_info| {
                            if (array_info.child != u8) {
                                const child_type_info = @typeInfo(array_info.child);
                                if (child_type_info == .@"struct") {
                                    for (field_value) |item| {
                                        try writer.print("[[{s}]]\n", .{field_key});
                                        try writeTable(writer, item);
                                    }
                                }
                            }
                        },
                        else => {},
                    }
                }
            }
        },
        else => {},
    }
}

fn writeKeyValue(writer: *std.Io.Writer, key: []const u8, value: anytype) !void {
    std.debug.assert(key.len > 0);

    try writer.print("{s} = ", .{key});
    try writeValue(writer, value);
    try writer.writeByte('\n');
}

fn writeValue(writer: *std.Io.Writer, value: anytype) !void {
    const T = @TypeOf(value);
    const type_info = @typeInfo(T);
    switch (type_info) {
        .bool => try writer.writeAll(if (value) "true" else "false"),
        .int => try writer.print("{d}", .{value}),
        .float => try writer.print("{d}", .{value}),
        .pointer => |pointer_type_info| {
            if (pointer_type_info.size == .slice) {
                if (pointer_type_info.child == u8) {
                    try writeString(writer, value);
                } else {
                    try writeInlineArray(writer, value);
                }
            } else {
                @compileError("unsupported pointer type: " ++ @typeName(T));
            }
        },
        .array => |array_type_info| {
            if (array_type_info.child == u8) {
                try writeString(writer, &value);
            } else {
                try writeInlineArray(writer, &value);
            }
        },
        .optional => {
            if (value) |present| {
                try writeValue(writer, present);
            } else {
                try writer.writeAll("\"\"");
            }
        },
        .@"enum" => try writeString(writer, @tagName(value)),
        else => @compileError("unsupported type: " ++ @typeName(T)),
    }
}

fn writeString(writer: *std.Io.Writer, string: []const u8) !void {
    if (std.mem.indexOfScalar(u8, string, '\n')) |_| {
        try writer.writeAll("\"\"\"\n");
        var consecutive_quotes: u32 = 0;
        for (string) |char| {
            switch (char) {
                '\\' => {
                    try writer.writeAll("\\\\");
                    consecutive_quotes = 0;
                },
                '\r' => {
                    try writer.writeAll("\\r");
                    consecutive_quotes = 0;
                },
                '"' => {
                    consecutive_quotes += 1;
                    if (consecutive_quotes >= 3) {
                        try writer.writeAll("\\\"");
                        consecutive_quotes = 0;
                    } else {
                        try writer.writeByte('"');
                    }
                },
                else => {
                    consecutive_quotes = 0;
                    if (char < 0x20) {
                        if (char != '\n') {
                            try writer.print("\\u{x:0>4}", .{char});
                        } else {
                            try writer.writeByte(char);
                        }
                    } else {
                        try writer.writeByte(char);
                    }
                },
            }
        }
        try writer.writeAll("\"\"\"");
        return;
    }
    try common.writeEscapedString(writer, string);
}

fn writeInlineArray(writer: *std.Io.Writer, slice: anytype) !void {
    try writer.writeByte('[');
    for (slice, 0..) |item, index| {
        if (index > 0) try writer.writeAll(", ");
        try writeValue(writer, item);
    }
    try writer.writeByte(']');
}

// ==================== Deserialization ====================

/// Parses a full struct including KV lines, [table] headers, and [[array]] headers.
///
/// This function implements a "header bubbling" mechanism to prevent infinite loops:
/// 1. If a header ([name] or [[name]]) matches a field in T, it is consumed and parsed.
/// 2. If it does NOT match and we are in a nested context (.nested or .array_element),
///    we return immediately WITHOUT consuming the header, allowing the caller (parent)
///     to try matching it.
/// 3. If it does NOT match and we are at the .root, we consume and skip it.
fn parseStructFull(
    comptime T: type,
    parser: *Parser,
    mode: Mode,
) !T {
    const type_info = @typeInfo(T);
    switch (type_info) {
        .@"struct" => |struct_info| {
            var result: T = undefined;
            var fields_seen = [_]bool{false} ** struct_info.fields.len;

            // Phase 1: parse key-value lines at the current level.
            try parseKvLines(T, &result, &fields_seen, parser);

            // Phase 2: dispatch [table] and [[array]] headers.
            while (parser.line_ptr) |raw_line| {
                const trimmed = std.mem.trim(u8, raw_line, " \r");
                if (trimmed.len == 0) {
                    parser.next();
                    continue;
                }
                if (trimmed[0] == '#') {
                    parser.next();
                    continue;
                }

                // If we hit a header, try to handle it.
                if (trimmed[0] == '[') {
                    if (trimmed.len > 2 and trimmed[1] == '[') {
                        // Table Array Header: [[array_name]]
                        if (mode == .array_element) {
                            // We are inside an array element; a NEW [[array]] header
                            // means this element is finished. Return to the loop in parseTableArray.
                            return result;
                        }

                        const array_name = try parseHeaderName(trimmed, 2);
                        if (try dispatchTableArray(T, &result, &fields_seen, parser, array_name)) {
                            // Successfully parsed the array, continue looking for more headers.
                            continue;
                        }
                    } else {
                        // Table Header: [table_name]
                        const table_name = try parseHeaderName(trimmed, 1);
                        if (try dispatchTable(T, &result, &fields_seen, parser, table_name)) {
                            // Successfully parsed the table, continue looking for more headers.
                            continue;
                        }
                    }

                    // No field in T matched this header.
                    if (mode == .root) {
                        // At root: skip unknown sections to be robust.
                        parser.next();
                        skipSection(parser);
                        continue;
                    } else {
                        // In nested context: return to parent to let them try matching it.
                        return result;
                    }
                }

                // Unexpected line format in section dispatch phase.
                parser.next();
            }

            try common.fillMissingFields(T, &result, &fields_seen);
            return result;
        },
        else => @compileError("unsupported type: " ++ @typeName(T)),
    }
}

/// Parses key-value lines until a section header or EOF.
fn parseKvLines(
    comptime T: type,
    result: *T,
    fields_seen: *[std.meta.fields(T).len]bool,
    parser: *Parser,
) !void {
    while (parser.line_ptr) |raw_line| {
        const trimmed = std.mem.trim(u8, raw_line, " \r");
        if (trimmed.len == 0) {
            parser.next();
            continue;
        }
        if (trimmed[0] == '#') {
            parser.next();
            continue;
        }

        // Section headers terminate the KV parsing phase.
        if (trimmed[0] == '[') {
            return;
        }

        const eq_index = std.mem.indexOfScalar(u8, trimmed, '=') orelse {
            parser.next();
            continue;
        };
        const key = std.mem.trim(u8, trimmed[0..eq_index], " ");
        const raw_value = std.mem.trim(u8, trimmed[eq_index + 1 ..], " ");

        if (std.mem.startsWith(u8, raw_value, "\"\"\"")) {
            const multi_line_value = try collectMultiLineString(
                raw_value,
                parser,
            );
            try parseKvLineWithString(T, result, fields_seen, key, multi_line_value);
        } else {
            try parseKvLine(T, result, fields_seen, parser.allocator, key, raw_value);
            parser.next();
        }
    }
}

fn collectMultiLineString(
    raw_value: []const u8,
    parser: *Parser,
) ![]const u8 {
    var result = std.ArrayList(u8).empty;
    defer result.deinit(parser.allocator);

    // Content after opening """: per TOML spec, a newline immediately after """ is trimmed.
    const after_open = raw_value[3..];
    if (after_open.len > 0) {
        // Check if closing """ is on the same line.
        if (std.mem.indexOf(u8, after_open, "\"\"\"")) |close_position| {
            try appendUnescaped(&result, parser.allocator, after_open[0..close_position]);
            parser.next();
            return try result.toOwnedSlice(parser.allocator);
        }
        // Non-empty content on opening line (after trimming leading newline per spec, we skip it).
    }

    // Read subsequent lines until closing """.
    while (parser.line_iterator.next()) |next_line| {
        const line = stripTrailingCr(next_line);
        if (std.mem.indexOf(u8, line, "\"\"\"")) |close_position| {
            if (result.items.len > 0) {
                try result.append(parser.allocator, '\n');
            }
            try appendUnescaped(&result, parser.allocator, line[0..close_position]);
            parser.next();
            return try result.toOwnedSlice(parser.allocator);
        }
        if (result.items.len > 0) {
            try result.append(parser.allocator, '\n');
        }
        try appendUnescaped(&result, parser.allocator, line);
    }
    parser.line_ptr = null;
    return error.UnexpectedToken;
}

fn appendUnescaped(
    result: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    input: []const u8,
) !void {
    var index: usize = 0;
    while (index < input.len) {
        if (input[index] == '\\') {
            if (index + 1 < input.len) {
                switch (input[index + 1]) {
                    '\\' => {
                        try result.append(allocator, '\\');
                        index += 2;
                    },
                    'n' => {
                        try result.append(allocator, '\n');
                        index += 2;
                    },
                    'r' => {
                        try result.append(allocator, '\r');
                        index += 2;
                    },
                    't' => {
                        try result.append(allocator, '\t');
                        index += 2;
                    },
                    '"' => {
                        try result.append(allocator, '"');
                        index += 2;
                    },
                    'u' => {
                        if (index + 5 < input.len) {
                            const code = std.fmt.parseInt(u21, input[index + 2 .. index + 6], 16) catch {
                                try result.append(allocator, input[index]);
                                index += 1;
                                continue;
                            };
                            if (code < 0x80) {
                                try result.append(allocator, @intCast(code));
                            } else {
                                var buffer: [4]u8 = undefined;
                                const utf8_length = std.unicode.utf8Encode(code, &buffer) catch {
                                    try result.append(allocator, input[index]);
                                    index += 1;
                                    continue;
                                };
                                try result.appendSlice(allocator, buffer[0..utf8_length]);
                            }
                            index += 6;
                        } else {
                            try result.append(allocator, input[index]);
                            index += 1;
                        }
                    },
                    else => {
                        try result.append(allocator, input[index]);
                        index += 1;
                    },
                }
            } else {
                try result.append(allocator, input[index]);
                index += 1;
            }
        } else {
            try result.append(allocator, input[index]);
            index += 1;
        }
    }
}

fn stripTrailingCr(line: []const u8) []const u8 {
    if (line.len > 0) {
        if (line[line.len - 1] == '\r') {
            return line[0 .. line.len - 1];
        }
    }
    return line;
}

fn parseKvLineWithString(
    comptime T: type,
    result: *T,
    fields_seen: *[std.meta.fields(T).len]bool,
    key: []const u8,
    value: []const u8,
) !void {
    const struct_info = @typeInfo(T).@"struct";
    inline for (struct_info.fields, 0..) |field, index| {
        if (common.matchesInputKey(.toml, T, field.name, key)) {
            const config = common.deserializeConfig(.toml, T, field.name);
            if (config.skip) return;
            if (fields_seen[index]) return error.DuplicateField;

            const field_type_info = @typeInfo(field.type);
            if (field_type_info == .pointer) {
                if (field_type_info.pointer.size == .slice) {
                    if (field_type_info.pointer.child == u8) {
                        @field(result, field.name) = value;
                        fields_seen[index] = true;
                        return;
                    }
                }
            } else if (field_type_info == .optional) {
                const child_type_info = @typeInfo(field_type_info.optional.child);
                if (child_type_info == .pointer) {
                    if (child_type_info.pointer.size == .slice) {
                        if (child_type_info.pointer.child == u8) {
                            @field(result, field.name) = value;
                            fields_seen[index] = true;
                            return;
                        }
                    }
                }
            }
        }
    }
}

/// Safely extracts and validates the name from a header like [name] or [[name]].
fn parseHeaderName(line: []const u8, bracket_count: usize) ![]const u8 {
    // Minimum length check: brackets + at least one character name.
    // e.g., "[a]" (3) or "[[a]]" (5)
    if (line.len < (bracket_count * 2) + 1) return error.UnexpectedToken;

    // Check opening brackets.
    var index: usize = 0;
    while (index < bracket_count) : (index += 1) {
        if (line[index] != '[') return error.UnexpectedToken;
    }

    // Check closing brackets.
    index = 0;
    while (index < bracket_count) : (index += 1) {
        if (line[line.len - 1 - index] != ']') return error.UnexpectedToken;
    }

    return std.mem.trim(u8, line[bracket_count .. line.len - bracket_count], " ");
}

fn dispatchTable(
    comptime T: type,
    result: *T,
    fields_seen: *[std.meta.fields(T).len]bool,
    parser: *Parser,
    table_name: []const u8,
) !bool {
    const struct_info = @typeInfo(T).@"struct";

    inline for (struct_info.fields, 0..) |field, index| {
        if (common.matchesInputKey(.toml, T, field.name, table_name)) {
            const config = common.deserializeConfig(.toml, T, field.name);
            if (config.skip) {
                parser.next();
                skipSection(parser);
                return true;
            }
            if (fields_seen[index]) return error.DuplicateField;

            const field_type_info = @typeInfo(field.type);
            if (field_type_info == .@"struct") {
                parser.next();
                const parsed = try parseStructFull(field.type, parser, .nested);
                @field(result, field.name) = parsed;
                fields_seen[index] = true;
                return true;
            }
            if (field_type_info == .optional) {
                if (@typeInfo(field_type_info.optional.child) == .@"struct") {
                    parser.next();
                    const parsed = try parseStructFull(field_type_info.optional.child, parser, .nested);
                    @field(result, field.name) = parsed;
                    fields_seen[index] = true;
                    return true;
                }
            }
        }
    }
    return false;
}

fn dispatchTableArray(
    comptime T: type,
    result: *T,
    fields_seen: *[std.meta.fields(T).len]bool,
    parser: *Parser,
    array_name: []const u8,
) !bool {
    const struct_info = @typeInfo(T).@"struct";

    inline for (struct_info.fields, 0..) |field, index| {
        if (common.matchesInputKey(.toml, T, field.name, array_name)) {
            const config = common.deserializeConfig(.toml, T, field.name);
            if (config.skip) {
                parser.next();
                skipSection(parser);
                return true;
            }
            if (fields_seen[index]) return error.DuplicateField;

            const field_type_info = @typeInfo(field.type);
            if (field_type_info == .pointer) {
                if (field_type_info.pointer.size == .slice) {
                    const child_type_info = @typeInfo(field_type_info.pointer.child);
                    if (child_type_info == .@"struct") {
                        parser.next();
                        @field(result, field.name) = try parseTableArray(
                            field_type_info.pointer.child,
                            parser,
                            array_name,
                        );
                        fields_seen[index] = true;
                        return true;
                    }
                }
            }
        }
    }
    return false;
}

fn parseTableArray(
    comptime Item: type,
    parser: *Parser,
    array_name: []const u8,
) ![]Item {
    var list = std.ArrayList(Item).empty;
    errdefer list.deinit(parser.allocator);

    // Initial [[array]] header was already consumed by dispatchTableArray.
    while (true) {
        const item = try parseStructFull(Item, parser, .array_element);
        try list.append(parser.allocator, item);

        // Check if the next header is another element of this same array.
        if (parser.line_ptr) |next_line| {
            const next_trimmed = std.mem.trim(u8, next_line, " \r");
            if (next_trimmed.len > 0 and next_trimmed[0] == '[') {
                if (parseHeaderName(next_trimmed, 2)) |next_name| {
                    if (std.mem.eql(u8, next_name, array_name)) {
                        parser.next();
                        continue;
                    }
                } else |_| {}
            }
        }
        break;
    }
    return try list.toOwnedSlice(parser.allocator);
}

fn skipSection(parser: *Parser) void {
    while (parser.line_ptr) |raw_line| {
        const trimmed = std.mem.trim(u8, raw_line, " \r");
        if (trimmed.len == 0) {
            parser.next();
            continue;
        }
        if (trimmed[0] == '#') {
            parser.next();
            continue;
        }

        if (trimmed[0] == '[') {
            return;
        }
        parser.next();
    }
}

fn parseKvLine(
    comptime T: type,
    result: *T,
    fields_seen: *[std.meta.fields(T).len]bool,
    allocator: std.mem.Allocator,
    key: []const u8,
    raw_value: []const u8,
) !void {
    const struct_info = @typeInfo(T).@"struct";
    inline for (struct_info.fields, 0..) |field, index| {
        if (common.matchesInputKey(.toml, T, field.name, key)) {
            const config = common.deserializeConfig(.toml, T, field.name);
            if (config.skip) return;
            if (fields_seen[index]) return error.DuplicateField;

            // Use a comptime switch to avoid instantiating parseTomlValue for struct types.
            switch (@typeInfo(field.type)) {
                .@"struct" => {},
                .optional => |optional_type_info| {
                    if (@typeInfo(optional_type_info.child) == .@"struct") {
                        // Optional structs are handled by dispatchTable for [table] sections.
                    } else {
                        const parsed = try parseTomlValue(field.type, allocator, raw_value);
                        @field(result, field.name) = parsed;
                        fields_seen[index] = true;
                    }
                },
                .pointer => |pointer_type_info| {
                    if (pointer_type_info.size == .slice) {
                        const parsed = try parseTomlValue(field.type, allocator, raw_value);
                        @field(result, field.name) = parsed;
                        fields_seen[index] = true;
                    }
                },
                else => {
                    const parsed = try parseTomlValue(field.type, allocator, raw_value);
                    @field(result, field.name) = parsed;
                    fields_seen[index] = true;
                },
            }
            return;
        }
    }
}

fn parseTomlValue(
    comptime T: type,
    allocator: std.mem.Allocator,
    raw_value: []const u8,
) !T {
    const type_info = @typeInfo(T);
    switch (type_info) {
        .bool => {
            if (std.mem.eql(u8, raw_value, "true")) return true;
            if (std.mem.eql(u8, raw_value, "false")) return false;
            return error.UnexpectedToken;
        },
        .int => {
            return std.fmt.parseInt(T, raw_value, 10);
        },
        .float => {
            return std.fmt.parseFloat(T, raw_value);
        },
        .pointer => |pointer_type_info| {
            if (pointer_type_info.size == .slice) {
                if (pointer_type_info.child == u8) {
                    return try scanString(allocator, raw_value);
                } else {
                    return try parseInlineArray(pointer_type_info.child, allocator, raw_value);
                }
            } else {
                @compileError("unsupported pointer type: " ++ @typeName(T));
            }
        },
        .array => |array_type_info| {
            if (array_type_info.child == u8) {
                const source = try scanString(allocator, raw_value);
                var result: T = undefined;
                const length = @min(source.len, array_type_info.len);
                @memcpy(result[0..length], source[0..length]);
                @memset(result[length..], 0);
                return result;
            }
            @compileError("unsupported array type: " ++ @typeName(T));
        },
        .optional => |optional_type_info| {
            if (std.mem.eql(u8, raw_value, "\"\"")) return null;
            if (std.mem.eql(u8, raw_value, "null")) return null;
            return try parseTomlValue(optional_type_info.child, allocator, raw_value);
        },
        .@"enum" => |enum_type_info| {
            const string = try scanString(allocator, raw_value);
            inline for (enum_type_info.fields) |field| {
                if (std.mem.eql(u8, field.name, string)) {
                    return @enumFromInt(field.value);
                }
            }
            return error.UnexpectedToken;
        },
        else => @compileError("unsupported type: " ++ @typeName(T)),
    }
}

fn parseInlineArray(
    comptime Item: type,
    allocator: std.mem.Allocator,
    raw_value: []const u8,
) ![]Item {
    const content = std.mem.trim(u8, raw_value, " ");
    if (content.len < 2) return error.UnexpectedToken;
    if (content[0] != '[') return error.UnexpectedToken;
    if (content[content.len - 1] != ']') return error.UnexpectedToken;

    const inner = std.mem.trim(u8, content[1 .. content.len - 1], " ");
    if (inner.len == 0) return &[_]Item{};

    var list = std.ArrayList(Item).empty;
    errdefer list.deinit(allocator);

    var index: usize = 0;
    while (index < inner.len) {
        // Skip leading whitespace.
        while (index < inner.len) {
            if (inner[index] == ' ') {
                index += 1;
            } else {
                break;
            }
        }
        if (index >= inner.len) break;

        // Find end of element, respecting quoted strings.
        const start = index;
        if (inner[index] == '"') {
            index += 1;
            while (index < inner.len) : (index += 1) {
                if (inner[index] == '\\') {
                    if (index + 1 < inner.len) {
                        index += 1;
                    }
                } else if (inner[index] == '"') {
                    index += 1;
                    break;
                }
            }
        } else {
            while (index < inner.len) {
                if (inner[index] != ',') {
                    index += 1;
                } else {
                    break;
                }
            }
        }
        const end = index;

        // Skip comma.
        if (index < inner.len) {
            if (inner[index] == ',') {
                index += 1;
            }
        }

        const element = std.mem.trim(u8, inner[start..end], " ");
        const parsed = try parseTomlPrimitive(Item, allocator, element);
        try list.append(allocator, parsed);
    }
    return try list.toOwnedSlice(allocator);
}

fn parseTomlPrimitive(comptime T: type, allocator: std.mem.Allocator, raw_value: []const u8) !T {
    const type_info = @typeInfo(T);
    switch (type_info) {
        .bool => {
            if (std.mem.eql(u8, raw_value, "true")) return true;
            if (std.mem.eql(u8, raw_value, "false")) return false;
            return error.UnexpectedToken;
        },
        .int => return std.fmt.parseInt(T, raw_value, 10),
        .float => return std.fmt.parseFloat(T, raw_value),
        .pointer => |pointer_type_info| {
            if (pointer_type_info.size == .slice) {
                if (pointer_type_info.child == u8) {
                    return try scanString(allocator, raw_value);
                }
            }
            return error.UnsupportedType;
        },
        else => return error.UnsupportedType,
    }
}

fn scanString(allocator: std.mem.Allocator, raw_value: []const u8) ![]const u8 {
    var scanner = std.json.Scanner.initCompleteInput(allocator, raw_value);
    defer scanner.deinit();
    return switch (try scanner.nextAlloc(allocator, .alloc_always)) {
        .string => |string| string,
        .allocated_string => |string| string,
        else => error.UnexpectedToken,
    };
}

// ==================== Tests ====================

test "serialize flat struct" {
    const User = struct {
        name: []const u8,
        age: u32,
        active: bool,
    };
    const serde = Serde(User);
    var buf: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try serde.serialize(&writer, User{ .name = "alice", .age = 30, .active = true });
    try std.testing.expectEqualStrings(
        \\name = "alice"
        \\age = 30
        \\active = true
        \\
    , writer.buffered());
}

test "serialize nested struct" {
    const Server = struct { host: []const u8, port: u16 };
    const Config = struct { name: []const u8, server: Server };
    const serde = Serde(Config);
    var buf: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try serde.serialize(&writer, Config{
        .name = "myapp",
        .server = .{ .host = "localhost", .port = 8080 },
    });
    try std.testing.expectEqualStrings(
        \\name = "myapp"
        \\[server]
        \\host = "localhost"
        \\port = 8080
        \\
    , writer.buffered());
}

test "serialize struct with string array" {
    const Config = struct { tags: []const []const u8 };
    const serde = Serde(Config);
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try serde.serialize(&writer, Config{ .tags = &.{ "web", "api" } });
    try std.testing.expectEqualStrings(
        \\tags = ["web", "api"]
        \\
    , writer.buffered());
}

test "serialize struct with numeric array" {
    const Data = struct { scores: []const u32 };
    const serde = Serde(Data);
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try serde.serialize(&writer, Data{ .scores = &.{ 100, 90, 80 } });
    try std.testing.expectEqualStrings(
        \\scores = [100, 90, 80]
        \\
    , writer.buffered());
}

test "serialize struct with optional" {
    const Config = struct { host: []const u8, port: ?u16 };
    const serde = Serde(Config);
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try serde.serialize(&writer, Config{ .host = "localhost", .port = null });
    try std.testing.expectEqualStrings(
        \\host = "localhost"
        \\port = ""
        \\
    , writer.buffered());
}

test "serialize table array" {
    const Server = struct { host: []const u8, port: u16 };
    const Config = struct { servers: []const Server };
    const serde = Serde(Config);
    var buf: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try serde.serialize(&writer, Config{
        .servers = &.{
            .{ .host = "a.com", .port = 80 },
            .{ .host = "b.com", .port = 443 },
        },
    });
    try std.testing.expectEqualStrings(
        \\[[servers]]
        \\host = "a.com"
        \\port = 80
        \\[[servers]]
        \\host = "b.com"
        \\port = 443
        \\
    , writer.buffered());
}

test "deserialize flat struct" {
    const User = struct {
        name: []const u8,
        age: u32,
        active: bool,
    };
    const serde = Serde(User);
    var result = try serde.deserialize(
        std.testing.allocator,
        "name = \"alice\"\nage = 30\nactive = true\n",
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("alice", result.value.name);
    try std.testing.expectEqual(@as(u32, 30), result.value.age);
    try std.testing.expectEqual(true, result.value.active);
}

test "deserialize nested struct" {
    const Server = struct { host: []const u8, port: u16 };
    const Config = struct { name: []const u8, server: Server };
    const serde = Serde(Config);
    var result = try serde.deserialize(std.testing.allocator,
        \\name = "myapp"
        \\[server]
        \\host = "localhost"
        \\port = 8080
        \\
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("myapp", result.value.name);
    try std.testing.expectEqualStrings("localhost", result.value.server.host);
    try std.testing.expectEqual(@as(u16, 8080), result.value.server.port);
}

test "deserialize struct with optional" {
    const Config = struct { host: []const u8, port: ?u16 };
    const serde = Serde(Config);
    var result = try serde.deserialize(
        std.testing.allocator,
        "host = \"localhost\"\nport = 8080\n",
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("localhost", result.value.host);
    try std.testing.expectEqual(@as(?u16, 8080), result.value.port);
}

test "deserialize struct with optional null" {
    const Config = struct { host: []const u8, port: ?u16 };
    const serde = Serde(Config);
    var result = try serde.deserialize(
        std.testing.allocator,
        "host = \"localhost\"\nport = \"\"\n",
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("localhost", result.value.host);
    try std.testing.expectEqual(@as(?u16, null), result.value.port);
}

test "deserialize inline array" {
    const Data = struct { scores: []const u32 };
    const serde = Serde(Data);
    var result = try serde.deserialize(
        std.testing.allocator,
        "scores = [100, 90, 80]\n",
    );
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 3), result.value.scores.len);
    try std.testing.expectEqual(@as(u32, 100), result.value.scores[0]);
    try std.testing.expectEqual(@as(u32, 90), result.value.scores[1]);
    try std.testing.expectEqual(@as(u32, 80), result.value.scores[2]);
}

test "deserialize table array" {
    const Server = struct { host: []const u8, port: u16 };
    const Config = struct { servers: []const Server };
    const serde = Serde(Config);
    var result = try serde.deserialize(std.testing.allocator,
        \\[[servers]]
        \\host = "a.com"
        \\port = 80
        \\[[servers]]
        \\host = "b.com"
        \\port = 443
        \\
    );
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), result.value.servers.len);
    try std.testing.expectEqualStrings("a.com", result.value.servers[0].host);
    try std.testing.expectEqual(@as(u16, 80), result.value.servers[0].port);
    try std.testing.expectEqualStrings("b.com", result.value.servers[1].host);
    try std.testing.expectEqual(@as(u16, 443), result.value.servers[1].port);
}

test "roundtrip: flat struct" {
    const User = struct {
        name: []const u8,
        age: u32,
        active: bool,
    };
    const serde = Serde(User);
    const original = User{ .name = "alice", .age = 30, .active = true };

    var buf: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try serde.serialize(&writer, original);

    var restored = try serde.deserialize(std.testing.allocator, writer.buffered());
    defer restored.deinit();

    try std.testing.expectEqualStrings(original.name, restored.value.name);
    try std.testing.expectEqual(original.age, restored.value.age);
    try std.testing.expectEqual(original.active, restored.value.active);
}

test "roundtrip: nested struct" {
    const Server = struct { host: []const u8, port: u16 };
    const Config = struct { name: []const u8, server: Server };
    const serde = Serde(Config);
    const original = Config{
        .name = "myapp",
        .server = .{ .host = "localhost", .port = 8080 },
    };

    var buf: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try serde.serialize(&writer, original);

    var restored = try serde.deserialize(std.testing.allocator, writer.buffered());
    defer restored.deinit();

    try std.testing.expectEqualStrings(original.name, restored.value.name);
    try std.testing.expectEqualStrings(original.server.host, restored.value.server.host);
    try std.testing.expectEqual(original.server.port, restored.value.server.port);
}

test "roundtrip: table array" {
    const Server = struct { host: []const u8, port: u16 };
    const Config = struct { servers: []const Server };
    const serde = Serde(Config);
    const original = Config{
        .servers = &.{
            .{ .host = "a.com", .port = 80 },
            .{ .host = "b.com", .port = 443 },
        },
    };

    var buf: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try serde.serialize(&writer, original);

    var restored = try serde.deserialize(std.testing.allocator, writer.buffered());
    defer restored.deinit();

    try std.testing.expectEqual(original.servers.len, restored.value.servers.len);
    try std.testing.expectEqualStrings("a.com", restored.value.servers[0].host);
    try std.testing.expectEqual(@as(u16, 80), restored.value.servers[0].port);
    try std.testing.expectEqualStrings("b.com", restored.value.servers[1].host);
    try std.testing.expectEqual(@as(u16, 443), restored.value.servers[1].port);
}

test "serialize multi-line string" {
    const Doc = struct { content: []const u8 };
    const serde = Serde(Doc);
    var buf: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try serde.serialize(&writer, Doc{ .content = "line1\nline2\nline3" });
    try std.testing.expectEqualStrings(
        \\content = """
        \\line1
        \\line2
        \\line3"""
        \\
    , writer.buffered());
}

test "deserialize multi-line string" {
    const Doc = struct { content: []const u8 };
    const serde = Serde(Doc);
    var result = try serde.deserialize(std.testing.allocator,
        \\content = """
        \\line1
        \\line2
        \\line3"""
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("line1\nline2\nline3", result.value.content);
}

test "roundtrip: multi-line string" {
    const Doc = struct { content: []const u8 };
    const serde = Serde(Doc);
    const original = Doc{ .content = "line1\nline2\nline3" };

    var buf: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try serde.serialize(&writer, original);

    var restored = try serde.deserialize(std.testing.allocator, writer.buffered());
    defer restored.deinit();

    try std.testing.expectEqualStrings(original.content, restored.value.content);
}

test "roundtrip: string array with commas" {
    const Config = struct { tags: []const []const u8 };
    const serde = Serde(Config);
    const original = Config{ .tags = &.{ "hello, world", "foo" } };

    var buf: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try serde.serialize(&writer, original);

    var restored = try serde.deserialize(std.testing.allocator, writer.buffered());
    defer restored.deinit();

    try std.testing.expectEqual(@as(usize, 2), restored.value.tags.len);
    try std.testing.expectEqualStrings("hello, world", restored.value.tags[0]);
    try std.testing.expectEqualStrings("foo", restored.value.tags[1]);
}

test "roundtrip: multi-line string with triple quotes" {
    const Doc = struct { content: []const u8 };
    const serde = Serde(Doc);
    const original = Doc{ .content = "has \"\"\" triple\nquotes" };

    var buf: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try serde.serialize(&writer, original);

    var restored = try serde.deserialize(std.testing.allocator, writer.buffered());
    defer restored.deinit();

    try std.testing.expectEqualStrings(original.content, restored.value.content);
}

test "roundtrip: string with control character" {
    const Doc = struct { content: []const u8 };
    const serde = Serde(Doc);
    const original = Doc{ .content = "has\x01ctrl\nchar" };

    var buf: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try serde.serialize(&writer, original);

    var restored = try serde.deserialize(std.testing.allocator, writer.buffered());
    defer restored.deinit();

    try std.testing.expectEqualStrings(original.content, restored.value.content);
}

test "roundtrip: fixed-size u8 array" {
    const Data = struct { name: [8]u8 };
    const serde = Serde(Data);
    var original: Data = undefined;
    @memcpy(original.name[0..2], "hi");
    @memset(original.name[2..], 0);

    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try serde.serialize(&writer, original);

    var restored = try serde.deserialize(std.testing.allocator, writer.buffered());
    defer restored.deinit();

    try std.testing.expectEqualSlices(u8, &original.name, &restored.value.name);
}

// ==================== Error Case Tests ====================

test "error: missing required field" {
    const Config = struct { host: []const u8, port: u16 };
    const serde = Serde(Config);
    const result = serde.deserialize(std.testing.allocator, "host = \"localhost\"\n");
    try std.testing.expectError(error.MissingField, result);
}

test "error: duplicate field" {
    const Config = struct { host: []const u8 };
    const serde = Serde(Config);
    const result = serde.deserialize(std.testing.allocator,
        \\host = "a"
        \\host = "b"
    );
    try std.testing.expectError(error.DuplicateField, result);
}

test "error: type mismatch string for int" {
    const Data = struct { count: u32 };
    const serde = Serde(Data);
    const result = serde.deserialize(std.testing.allocator, "count = \"hello\"\n");
    try std.testing.expect(std.meta.isError(result));
}

test "error: type mismatch string for bool" {
    const Data = struct { flag: bool };
    const serde = Serde(Data);
    const result = serde.deserialize(std.testing.allocator, "flag = \"yes\"\n");
    try std.testing.expectError(error.UnexpectedToken, result);
}

test "error: invalid integer" {
    const Data = struct { count: u32 };
    const serde = Serde(Data);
    const result = serde.deserialize(std.testing.allocator, "count = abc\n");
    try std.testing.expect(std.meta.isError(result));
}

test "error: empty input missing fields" {
    const Data = struct { name: []const u8 };
    const serde = Serde(Data);
    const result = serde.deserialize(std.testing.allocator, "");
    try std.testing.expectError(error.MissingField, result);
}

test "error: unclosed multi-line string" {
    const Doc = struct { content: []const u8 };
    const serde = Serde(Doc);
    const result = serde.deserialize(std.testing.allocator,
        \\content = """
        \\this never closes
    );
    try std.testing.expectError(error.UnexpectedToken, result);
}

test "error: duplicate key-value field" {
    const Config = struct { name: []const u8, port: u16 };
    const serde = Serde(Config);
    const result = serde.deserialize(std.testing.allocator,
        \\name = "a"
        \\port = 80
        \\name = "b"
    );
    try std.testing.expectError(error.DuplicateField, result);
}

test "roundtrip: enum" {
    const Status = enum { active, inactive };
    const Data = struct { status: Status };
    const serde = Serde(Data);
    const original = Data{ .status = .active };

    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try serde.serialize(&writer, original);

    var restored = try serde.deserialize(std.testing.allocator, writer.buffered());
    defer restored.deinit();

    try std.testing.expectEqual(original.status, restored.value.status);
}

test "error: invalid enum value" {
    const Status = enum { active, inactive };
    const Data = struct { status: Status };
    const serde = Serde(Data);
    const result = serde.deserialize(std.testing.allocator, "status = \"unknown\"\n");
    try std.testing.expectError(error.UnexpectedToken, result);
}

test "serde_fields toml rename and alias" {
    const Data = struct {
        name: []const u8,

        pub const serde_fields = .{
            .name = .{
                .toml = .{
                    .serialize = .{ .rename = "user_name" },
                    .deserialize = .{ .rename = "user_name", .alias = &.{"username"} },
                },
            },
        };
    };
    const serde = Serde(Data);

    var serialized: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&serialized);
    try serde.serialize(&writer, .{ .name = "alice" });
    try std.testing.expectEqualStrings("user_name = \"alice\"\n", writer.buffered());

    var result = try serde.deserialize(std.testing.allocator,
        \\username = "bob"
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("bob", result.value.name);
}

test "serde_fields toml omit_null" {
    const Data = struct {
        id: u32,
        note: ?[]const u8 = null,

        pub const serde_fields = .{
            .note = .{
                .toml = .{ .serialize = .{ .omit_null = true } },
            },
        };
    };
    const serde = Serde(Data);

    var serialized: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&serialized);
    try serde.serialize(&writer, .{ .id = 1, .note = null });
    try std.testing.expectEqualStrings("id = 1\n", writer.buffered());
}

test "serde_fields toml skip with default" {
    const Data = struct {
        id: u32,
        secret: []const u8 = "hidden",

        pub const serde_fields = .{
            .secret = .{
                .toml = .{
                    .serialize = .{ .skip = true },
                    .deserialize = .{ .skip = true },
                },
            },
        };
    };
    const serde = Serde(Data);

    var serialized: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&serialized);
    try serde.serialize(&writer, .{ .id = 7, .secret = "token" });
    try std.testing.expectEqualStrings("id = 7\n", writer.buffered());

    var result = try serde.deserialize(std.testing.allocator,
        \\id = 9
        \\secret = "ignored"
    );
    defer result.deinit();
    try std.testing.expectEqual(@as(u32, 9), result.value.id);
    try std.testing.expectEqualStrings("hidden", result.value.secret);
}

test "deserialize nested structs in order" {
    const A = struct { x: i32 };
    const B = struct { y: i32 };
    const Config = struct { a: A, b: B };
    const serde = Serde(Config);
    const input =
        \\[a]
        \\x = 1
        \\[b]
        \\y = 2
    ;
    var result = try serde.deserialize(std.testing.allocator, input);
    defer result.deinit();
    try std.testing.expectEqual(@as(i32, 1), result.value.a.x);
    try std.testing.expectEqual(@as(i32, 2), result.value.b.y);
}

test "roundtrip: optional struct" {
    const Server = struct { host: []const u8, port: u16 };
    const Config = struct { name: []const u8, server: ?Server };
    const serde = Serde(Config);

    // Non-null optional struct
    const original = Config{
        .name = "myapp",
        .server = .{ .host = "localhost", .port = 8080 },
    };

    var buf: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try serde.serialize(&writer, original);
    try std.testing.expectEqualStrings(
        \\name = "myapp"
        \\[server]
        \\host = "localhost"
        \\port = 8080
        \\
    , writer.buffered());

    var restored = try serde.deserialize(std.testing.allocator, writer.buffered());
    defer restored.deinit();
    try std.testing.expectEqualStrings("myapp", restored.value.name);
    try std.testing.expect(restored.value.server != null);
    try std.testing.expectEqualStrings("localhost", restored.value.server.?.host);
    try std.testing.expectEqual(@as(u16, 8080), restored.value.server.?.port);

    // Null optional struct
    const null_original = Config{ .name = "myapp", .server = null };
    var buf2: [512]u8 = undefined;
    var writer2 = std.Io.Writer.fixed(&buf2);
    try serde.serialize(&writer2, null_original);
    try std.testing.expectEqualStrings(
        \\name = "myapp"
        \\
    , writer2.buffered());

    var restored2 = try serde.deserialize(std.testing.allocator, writer2.buffered());
    defer restored2.deinit();
    try std.testing.expectEqualStrings("myapp", restored2.value.name);
    try std.testing.expect(restored2.value.server == null);
}
