const std = @import("std");
const common = @import("common.zig");
const Parsed = common.Parsed;

/// Returns a comptime-generated YAML serializer/deserializer for type `T`.
pub fn Serde(comptime T: type) type {
    return struct {
        /// Writes `value` as YAML to `writer`.
        pub fn serialize(writer: *std.Io.Writer, value: T) !void {
            comptime validateFieldConfigs(T);
            try writeValue(writer, value, 0);
        }

        /// Parses `input` as YAML into a `Parsed(T)`.
        /// Caller must call `deinit()` to free all allocated memory.
        pub fn deserialize(allocator: std.mem.Allocator, input: []const u8) !Parsed(T) {
            comptime validateFieldConfigs(T);
            var arena = std.heap.ArenaAllocator.init(allocator);
            errdefer arena.deinit();

            const arena_allocator = arena.allocator();
            var lines = std.mem.splitScalar(u8, input, '\n');
            var line_list = std.ArrayList([]const u8).empty;
            defer line_list.deinit(arena_allocator);

            while (lines.next()) |line| {
                try line_list.append(arena_allocator, stripCr(line));
            }
            const all_lines = try line_list.toOwnedSlice(arena_allocator);

            var pos: usize = 0;
            const value = try parseValue(T, arena_allocator, all_lines, &pos, 0);

            return .{ .arena = arena, .value = value };
        }
    };
}

// ==================== Serialization ====================

fn writeValue(writer: *std.Io.Writer, value: anytype, indent: usize) !void {
    const T = @TypeOf(value);
    comptime validateFieldConfigs(T);
    const info = @typeInfo(T);
    switch (info) {
        .@"struct" => |struct_info| {
            var wrote_any = false;
            inline for (struct_info.fields) |field| {
                const config = fieldConfig(T, field.name);
                const field_value = @field(value, field.name);
                var include_field = !config.skip;
                if (config.omit_null and @typeInfo(field.type) == .optional and field_value == null) {
                    include_field = false;
                }
                if (include_field) {
                    if (wrote_any or indent > 0) {
                        try writeIndent(writer, indent);
                    }
                    wrote_any = true;
                    try writer.print("{s}:", .{serializedFieldName(T, field.name)});
                    try writeFieldValue(writer, field_value, indent);
                }
            }
        },
        else => @compileError("top-level YAML value must be a struct, got: " ++ @typeName(T)),
    }
}

fn writeFieldValue(writer: *std.Io.Writer, value: anytype, indent: usize) !void {
    const T = @TypeOf(value);
    const info = @typeInfo(T);
    switch (info) {
        .bool => {
            try writer.writeByte(' ');
            try writer.writeAll(if (value) "true" else "false");
            try writer.writeByte('\n');
        },
        .int => {
            try writer.writeByte(' ');
            try writer.print("{d}", .{value});
            try writer.writeByte('\n');
        },
        .float => {
            try writer.writeByte(' ');
            try writer.print("{d}", .{value});
            try writer.writeByte('\n');
        },
        .pointer => |pointer_info| {
            if (pointer_info.size == .slice and pointer_info.child == u8) {
                try writeStringValue(writer, value, indent);
            } else if (pointer_info.size == .slice) {
                try writer.writeByte('\n');
                for (value) |item| {
                    try writeIndent(writer, indent + 2);
                    try writer.writeAll("- ");
                    try writeSequenceItem(writer, item, indent + 2);
                }
            } else {
                @compileError("unsupported pointer type: " ++ @typeName(T));
            }
        },
        .array => |array_info| {
            if (array_info.child == u8) {
                try writeStringValue(writer, &value, indent);
            } else {
                try writer.writeByte('\n');
                for (&value) |*item| {
                    try writeIndent(writer, indent + 2);
                    try writer.writeAll("- ");
                    try writeSequenceItem(writer, item.*, indent + 2);
                }
            }
        },
        .optional => {
            if (value) |present| {
                try writeFieldValue(writer, present, indent);
            } else {
                try writer.writeAll(" null\n");
            }
        },
        .@"struct" => {
            try writer.writeByte('\n');
            try writeValue(writer, value, indent + 2);
        },
        .@"enum" => {
            try writer.writeByte(' ');
            try writer.writeAll(@tagName(value));
            try writer.writeByte('\n');
        },
        else => @compileError("unsupported type: " ++ @typeName(T)),
    }
}

fn writeSequenceItem(writer: *std.Io.Writer, value: anytype, indent: usize) !void {
    const T = @TypeOf(value);
    const info = @typeInfo(T);
    switch (info) {
        .bool => {
            try writer.writeAll(if (value) "true" else "false");
            try writer.writeByte('\n');
        },
        .int => {
            try writer.print("{d}", .{value});
            try writer.writeByte('\n');
        },
        .float => {
            try writer.print("{d}", .{value});
            try writer.writeByte('\n');
        },
        .pointer => |pointer_info| {
            if (pointer_info.size == .slice and pointer_info.child == u8) {
                try writeScalarString(writer, value);
                try writer.writeByte('\n');
            } else {
                @compileError("unsupported slice in sequence: " ++ @typeName(T));
            }
        },
        .array => |array_info| {
            if (array_info.child == u8) {
                try writeScalarString(writer, &value);
                try writer.writeByte('\n');
            } else {
                @compileError("unsupported array in sequence: " ++ @typeName(T));
            }
        },
        .@"struct" => |struct_info| {
            // First field on same line as "- ", rest indented.
            var wrote_any = false;
            inline for (struct_info.fields) |field| {
                const config = fieldConfig(T, field.name);
                const field_value = @field(value, field.name);
                var include_field = !config.skip;
                if (config.omit_null and @typeInfo(field.type) == .optional and field_value == null) {
                    include_field = false;
                }
                if (include_field) {
                    if (wrote_any) {
                        try writeIndent(writer, indent + 2);
                    }
                    wrote_any = true;
                    try writer.print("{s}:", .{serializedFieldName(T, field.name)});
                    try writeFieldValue(writer, field_value, indent + 2);
                }
            }
            if (!wrote_any) try writer.writeByte('\n');
        },
        .@"enum" => {
            try writer.writeAll(@tagName(value));
            try writer.writeByte('\n');
        },
        else => @compileError("unsupported sequence item type: " ++ @typeName(T)),
    }
}

fn writeStringValue(writer: *std.Io.Writer, string: []const u8, indent: usize) !void {
    if (std.mem.indexOfScalar(u8, string, '\n')) |_| {
        // Use |- (strip) to indicate no trailing newline is added by parser.
        try writer.writeAll(" |-\n");
        var lines = std.mem.splitScalar(u8, string, '\n');
        // Skip only the final empty segment produced by splitScalar when
        // the string does NOT end with '\n'. When it does end with '\n',
        // the split produces an extra "" that we must still write as an
        // empty indented line to preserve the trailing newline content.
        const has_trailing_newline = string[string.len - 1] == '\n';
        while (lines.next()) |line| {
            if (!has_trailing_newline and line.len == 0 and lines.peek() == null) break;
            try writeIndent(writer, indent + 2);
            try writer.writeAll(line);
            try writer.writeByte('\n');
        }
    } else {
        try writer.writeByte(' ');
        try writeScalarString(writer, string);
        try writer.writeByte('\n');
    }
}

fn writeScalarString(writer: *std.Io.Writer, string: []const u8) !void {
    if (needsQuoting(string)) {
        try writer.writeByte('"');
        for (string) |char| {
            switch (char) {
                '"' => try writer.writeAll("\\\""),
                '\\' => try writer.writeAll("\\\\"),
                '\t' => try writer.writeAll("\\t"),
                '\r' => try writer.writeAll("\\r"),
                else => {
                    if (char < 0x20) {
                        try writer.print("\\x{x:0>2}", .{char});
                    } else {
                        try writer.writeByte(char);
                    }
                },
            }
        }
        try writer.writeByte('"');
    } else {
        try writer.writeAll(string);
    }
}

fn needsQuoting(string: []const u8) bool {
    if (string.len == 0) return true;
    if (string[0] == ' ' or string[string.len - 1] == ' ') return true;
    if (std.mem.eql(u8, string, "true") or
        std.mem.eql(u8, string, "false") or
        std.mem.eql(u8, string, "null")) return true;
    for (string) |char| {
        switch (char) {
            ':',
            '#',
            '"',
            '\'',
            '{',
            '}',
            '[',
            ']',
            ',',
            '&',
            '*',
            '?',
            '|',
            '-',
            '<',
            '>',
            '=',
            '!',
            '%',
            '@',
            '`',
            '\t',
            '\r',
            => return true,
            else => {},
        }
    }
    if (looksLikeNumber(string)) return true;
    return false;
}

fn looksLikeNumber(string: []const u8) bool {
    if (string.len == 0) return false;
    var start: usize = 0;
    if (string[0] == '-' or string[0] == '+') {
        start = 1;
        if (start >= string.len) return false;
    }
    var has_dot = false;
    for (string[start..]) |char| {
        if (char == '.') {
            if (has_dot) return false;
            has_dot = true;
        } else if (char < '0' or char > '9') {
            return false;
        }
    }
    return true;
}

fn writeIndent(writer: *std.Io.Writer, indent: usize) !void {
    for (0..indent) |_| {
        try writer.writeByte(' ');
    }
}

const YamlFieldConfig = common.YamlFieldOptions;

fn fieldConfig(comptime T: type, comptime field_name: []const u8) YamlFieldConfig {
    const options = common.fieldOptions(T, field_name);
    return options.yaml orelse .{};
}

fn serializedFieldName(comptime T: type, comptime field_name: []const u8) []const u8 {
    const config = fieldConfig(T, field_name);
    return config.rename orelse field_name;
}

fn matchesInputKey(comptime T: type, comptime field_name: []const u8, key: []const u8) bool {
    const config = fieldConfig(T, field_name);
    if (std.mem.eql(u8, field_name, key)) return true;
    if (config.rename) |rename| {
        if (std.mem.eql(u8, rename, key)) return true;
    }
    for (config.alias) |alias| {
        if (std.mem.eql(u8, alias, key)) return true;
    }
    return false;
}

fn validateFieldConfigs(comptime T: type) void {
    const info = @typeInfo(T);
    if (info != .@"struct") return;
    comptime common.validateSerdeFieldNames(T);
    const struct_info = info.@"struct";

    inline for (struct_info.fields) |field| {
        const config = fieldConfig(T, field.name);
        if (config.skip and field.default_value_ptr == null and @typeInfo(field.type) != .optional) {
            @compileError("yaml skip field must be optional or have a default: " ++ @typeName(T) ++ "." ++ field.name);
        }
    }

    inline for (struct_info.fields, 0..) |left, left_index| {
        const left_name = serializedFieldName(T, left.name);
        const left_config = fieldConfig(T, left.name);
        inline for (struct_info.fields, 0..) |right, right_index| {
            if (left_index == right_index) continue;
            const right_name = serializedFieldName(T, right.name);
            if (std.mem.eql(u8, left_name, right_name)) {
                @compileError("yaml field key conflict in " ++ @typeName(T) ++ ": " ++ left.name ++ " and " ++ right.name);
            }
            for (left_config.alias) |alias| {
                if (std.mem.eql(u8, alias, right_name) or std.mem.eql(u8, alias, right.name)) {
                    @compileError("yaml alias conflict in " ++ @typeName(T) ++ ": alias '" ++ alias ++ "' conflicts with field " ++ right.name);
                }
            }
        }
    }
}

// ==================== Deserialization ====================

fn stripCr(line: []const u8) []const u8 {
    if (line.len > 0 and line[line.len - 1] == '\r') {
        return line[0 .. line.len - 1];
    }
    return line;
}

fn lineIndent(line: []const u8) usize {
    var count: usize = 0;
    for (line) |char| {
        if (char == ' ') {
            count += 1;
        } else {
            break;
        }
    }
    return count;
}

fn parseValue(
    comptime T: type,
    allocator: std.mem.Allocator,
    all_lines: []const []const u8,
    pos: *usize,
    base_indent: usize,
) !T {
    comptime validateFieldConfigs(T);
    const info = @typeInfo(T);
    switch (info) {
        .@"struct" => |struct_info| {
            var result: T = undefined;
            var fields_seen = [_]bool{false} ** struct_info.fields.len;

            while (pos.* < all_lines.len) {
                const line = all_lines[pos.*];
                if (line.len == 0 or isBlankOrComment(line)) {
                    pos.* += 1;
                    continue;
                }
                const line_indent = lineIndent(line);
                if (line_indent < base_indent) break;

                const trimmed = std.mem.trimStart(u8, line, " ");

                // Check if this is a sequence item (shouldn't happen at struct level).
                if (trimmed.len >= 2 and trimmed[0] == '-' and trimmed[1] == ' ') break;

                const colon_pos = findKeyColon(trimmed) orelse {
                    pos.* += 1;
                    continue;
                };
                const key = trimmed[0..colon_pos];
                const after_colon = std.mem.trimStart(u8, trimmed[colon_pos + 1 ..], " ");

                inline for (struct_info.fields, 0..) |field, index| {
                    if (matchesInputKey(T, field.name, key)) {
                        const config = fieldConfig(T, field.name);
                        const is_skipped: bool = config.skip;
                        if (is_skipped) {
                            pos.* += 1;
                            skipNestedBlock(all_lines, pos, line_indent);
                            break;
                        }
                        if (fields_seen[index]) return error.DuplicateField;
                        pos.* += 1;
                        const parsed = try parseFieldValue(
                            field.type,
                            allocator,
                            all_lines,
                            pos,
                            line_indent,
                            after_colon,
                        );
                        @field(result, field.name) = parsed;
                        fields_seen[index] = true;
                        break;
                    }
                } else {
                    // Unknown field — skip.
                    pos.* += 1;
                    skipNestedBlock(all_lines, pos, line_indent);
                }
            }

            inline for (struct_info.fields, 0..) |field, index| {
                if (!fields_seen[index]) {
                    const config = fieldConfig(T, field.name);
                    if (config.skip and @typeInfo(field.type) == .optional) {
                        @field(result, field.name) = null;
                    } else if (field.default_value_ptr) |default_ptr| {
                        const ptr: *const field.type = @ptrCast(@alignCast(default_ptr));
                        @field(result, field.name) = ptr.*;
                    } else {
                        return error.MissingField;
                    }
                }
            }
            return result;
        },
        else => @compileError("top-level YAML parse must target a struct, got: " ++ @typeName(T)),
    }
}

fn parseFieldValue(
    comptime T: type,
    allocator: std.mem.Allocator,
    all_lines: []const []const u8,
    pos: *usize,
    parent_indent: usize,
    inline_value: []const u8,
) !T {
    const info = @typeInfo(T);
    switch (info) {
        .bool => {
            if (std.mem.eql(u8, inline_value, "true")) return true;
            if (std.mem.eql(u8, inline_value, "false")) return false;
            return error.UnexpectedToken;
        },
        .int => {
            return std.fmt.parseInt(T, inline_value, 10);
        },
        .float => {
            return std.fmt.parseFloat(T, inline_value);
        },
        .pointer => |pointer_info| {
            if (pointer_info.size == .slice and pointer_info.child == u8) {
                return try parseStringValue(
                    allocator,
                    all_lines,
                    pos,
                    parent_indent,
                    inline_value,
                );
            } else if (pointer_info.size == .slice) {
                return try parseSequence(
                    pointer_info.child,
                    allocator,
                    all_lines,
                    pos,
                    parent_indent,
                );
            } else {
                @compileError("unsupported pointer type: " ++ @typeName(T));
            }
        },
        .array => |array_info| {
            if (array_info.child == u8) {
                const src = try parseStringValue(
                    allocator,
                    all_lines,
                    pos,
                    parent_indent,
                    inline_value,
                );
                var result: T = undefined;
                const len = @min(src.len, array_info.len);
                @memcpy(result[0..len], src[0..len]);
                @memset(result[len..], 0);
                return result;
            }
            @compileError("unsupported array type: " ++ @typeName(T));
        },
        .optional => |optional_info| {
            const is_null = std.mem.eql(u8, inline_value, "null") or
                std.mem.eql(u8, inline_value, "~") or
                inline_value.len == 0;
            if (is_null) {
                if (inline_value.len == 0) {
                    const next_indent = peekNextIndent(all_lines, pos.*);
                    if (next_indent != null and next_indent.? > parent_indent) {
                        return try parseFieldValue(
                            optional_info.child,
                            allocator,
                            all_lines,
                            pos,
                            parent_indent,
                            inline_value,
                        );
                    }
                }
                return null;
            }
            return try parseFieldValue(
                optional_info.child,
                allocator,
                all_lines,
                pos,
                parent_indent,
                inline_value,
            );
        },
        .@"struct" => {
            if (inline_value.len == 0) {
                return try parseValue(T, allocator, all_lines, pos, parent_indent + 2);
            }
            return error.UnexpectedToken;
        },
        .@"enum" => |enum_info| {
            inline for (enum_info.fields) |field| {
                if (std.mem.eql(u8, field.name, inline_value)) {
                    return @enumFromInt(field.value);
                }
            }
            return error.UnexpectedToken;
        },
        else => @compileError("unsupported type: " ++ @typeName(T)),
    }
}

fn parseStringValue(
    allocator: std.mem.Allocator,
    all_lines: []const []const u8,
    pos: *usize,
    parent_indent: usize,
    inline_value: []const u8,
) ![]const u8 {
    // Literal block scalar.
    if (std.mem.eql(u8, inline_value, "|") or std.mem.eql(u8, inline_value, "|-")) {
        return try parseLiteralBlock(allocator, all_lines, pos, parent_indent);
    }
    if (inline_value.len >= 2 and inline_value[0] == '"' and
        inline_value[inline_value.len - 1] == '"')
    {
        return try unescapeString(allocator, inline_value[1 .. inline_value.len - 1]);
    }
    if (inline_value.len >= 2 and inline_value[0] == '\'' and
        inline_value[inline_value.len - 1] == '\'')
    {
        return try allocator.dupe(u8, inline_value[1 .. inline_value.len - 1]);
    }
    // Plain scalar.
    return try allocator.dupe(u8, inline_value);
}

fn parseLiteralBlock(
    allocator: std.mem.Allocator,
    all_lines: []const []const u8,
    pos: *usize,
    parent_indent: usize,
) ![]const u8 {
    const block_indent = parent_indent + 2;
    var result = std.ArrayList(u8).empty;
    defer result.deinit(allocator);

    var first = true;
    while (pos.* < all_lines.len) {
        const line = all_lines[pos.*];
        if (line.len == 0) {
            // Could be end of block or an empty line within the block.
            // Peek ahead to see if more block content follows.
            var peek = pos.* + 1;
            var still_in_block = false;
            while (peek < all_lines.len) : (peek += 1) {
                if (all_lines[peek].len == 0) continue;
                if (lineIndent(all_lines[peek]) >= block_indent) {
                    still_in_block = true;
                }
                break;
            }
            if (still_in_block) {
                if (!first) try result.append(allocator, '\n');
                pos.* += 1;
                continue;
            }
            break;
        }
        const line_indent = lineIndent(line);
        if (line_indent < block_indent) break;

        if (!first) try result.append(allocator, '\n');
        first = false;
        try result.appendSlice(allocator, line[block_indent..]);
        pos.* += 1;
    }

    return try result.toOwnedSlice(allocator);
}

fn parseSequence(
    comptime Item: type,
    allocator: std.mem.Allocator,
    all_lines: []const []const u8,
    pos: *usize,
    parent_indent: usize,
) ![]Item {
    var list = std.ArrayList(Item).empty;
    defer list.deinit(allocator);

    const seq_indent = parent_indent + 2;

    while (pos.* < all_lines.len) {
        const line = all_lines[pos.*];
        if (line.len == 0 or isBlankOrComment(line)) {
            pos.* += 1;
            continue;
        }
        const line_indent = lineIndent(line);
        if (line_indent < seq_indent) break;

        const trimmed = std.mem.trimStart(u8, line, " ");
        if (trimmed.len < 2 or trimmed[0] != '-' or trimmed[1] != ' ') break;

        const item_content = trimmed[2..];
        pos.* += 1;

        const item = try parseSequenceItem(
            Item,
            allocator,
            all_lines,
            pos,
            line_indent,
            item_content,
        );
        try list.append(allocator, item);
    }

    return try list.toOwnedSlice(allocator);
}

fn parseSequenceItem(
    comptime T: type,
    allocator: std.mem.Allocator,
    all_lines: []const []const u8,
    pos: *usize,
    item_indent: usize,
    item_content: []const u8,
) !T {
    const info = @typeInfo(T);
    switch (info) {
        .bool => {
            if (std.mem.eql(u8, item_content, "true")) return true;
            if (std.mem.eql(u8, item_content, "false")) return false;
            return error.UnexpectedToken;
        },
        .int => {
            return std.fmt.parseInt(T, item_content, 10);
        },
        .float => {
            return std.fmt.parseFloat(T, item_content);
        },
        .pointer => |pointer_info| {
            if (pointer_info.size == .slice and pointer_info.child == u8) {
                return try parseInlineString(allocator, item_content);
            }
            @compileError("unsupported pointer in sequence: " ++ @typeName(T));
        },
        .@"enum" => |enum_info| {
            inline for (enum_info.fields) |field| {
                if (std.mem.eql(u8, field.name, item_content)) {
                    return @enumFromInt(field.value);
                }
            }
            return error.UnexpectedToken;
        },
        .@"struct" => |struct_info| {
            // Inline struct: "- key: value\n  key: value\n..."
            // Parse first key-value from item_content, then continue with indented lines.
            var result: T = undefined;
            var fields_seen = [_]bool{false} ** struct_info.fields.len;

            // Parse first KV pair from item_content.
            const colon_pos = findKeyColon(item_content) orelse return error.UnexpectedToken;
            const key = item_content[0..colon_pos];
            const after_colon = std.mem.trimStart(u8, item_content[colon_pos + 1 ..], " ");

            inline for (struct_info.fields, 0..) |field, index| {
                if (matchesInputKey(T, field.name, key)) {
                    const config = fieldConfig(T, field.name);
                    const is_skipped: bool = config.skip;
                    if (is_skipped) {
                        skipNestedBlock(all_lines, pos, item_indent + 2);
                        break;
                    }
                    if (fields_seen[index]) return error.DuplicateField;
                    const parsed = try parseFieldValue(
                        field.type,
                        allocator,
                        all_lines,
                        pos,
                        item_indent + 2,
                        after_colon,
                    );
                    @field(result, field.name) = parsed;
                    fields_seen[index] = true;
                    break;
                }
            } else {
                skipNestedBlock(all_lines, pos, item_indent + 2);
            }

            // Parse remaining fields from subsequent indented lines.
            while (pos.* < all_lines.len) {
                const line = all_lines[pos.*];
                if (line.len == 0 or isBlankOrComment(line)) {
                    pos.* += 1;
                    continue;
                }
                const line_indent = lineIndent(line);
                if (line_indent <= item_indent) break;

                const trimmed = std.mem.trimStart(u8, line, " ");
                // If it's another sequence item, stop.
                if (trimmed.len >= 2 and trimmed[0] == '-' and trimmed[1] == ' ') break;

                const kv_colon = findKeyColon(trimmed) orelse {
                    pos.* += 1;
                    continue;
                };
                const kv_key = trimmed[0..kv_colon];
                const kv_val = std.mem.trimStart(u8, trimmed[kv_colon + 1 ..], " ");

                pos.* += 1;

                inline for (struct_info.fields, 0..) |field, index| {
                    if (matchesInputKey(T, field.name, kv_key)) {
                        const config = fieldConfig(T, field.name);
                        const is_skipped: bool = config.skip;
                        if (is_skipped) {
                            skipNestedBlock(all_lines, pos, line_indent);
                            break;
                        }
                        if (fields_seen[index]) return error.DuplicateField;
                        const parsed = try parseFieldValue(
                            field.type,
                            allocator,
                            all_lines,
                            pos,
                            line_indent,
                            kv_val,
                        );
                        @field(result, field.name) = parsed;
                        fields_seen[index] = true;
                        break;
                    }
                } else {
                    skipNestedBlock(all_lines, pos, line_indent);
                }
            }

            inline for (struct_info.fields, 0..) |field, index| {
                if (!fields_seen[index]) {
                    const config = fieldConfig(T, field.name);
                    if (config.skip and @typeInfo(field.type) == .optional) {
                        @field(result, field.name) = null;
                    } else if (field.default_value_ptr) |default_ptr| {
                        const ptr: *const field.type = @ptrCast(@alignCast(default_ptr));
                        @field(result, field.name) = ptr.*;
                    } else {
                        return error.MissingField;
                    }
                }
            }
            return result;
        },
        else => @compileError("unsupported sequence item type: " ++ @typeName(T)),
    }
}

fn parseInlineString(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    if (input.len >= 2 and input[0] == '"' and input[input.len - 1] == '"') {
        return try unescapeString(allocator, input[1 .. input.len - 1]);
    }
    if (input.len >= 2 and input[0] == '\'' and input[input.len - 1] == '\'') {
        return try allocator.dupe(u8, input[1 .. input.len - 1]);
    }
    return try allocator.dupe(u8, input);
}

fn unescapeString(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var result = std.ArrayList(u8).empty;
    defer result.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '\\' and i + 1 < input.len) {
            switch (input[i + 1]) {
                '"' => {
                    try result.append(allocator, '"');
                    i += 2;
                },
                '\\' => {
                    try result.append(allocator, '\\');
                    i += 2;
                },
                'n' => {
                    try result.append(allocator, '\n');
                    i += 2;
                },
                'r' => {
                    try result.append(allocator, '\r');
                    i += 2;
                },
                't' => {
                    try result.append(allocator, '\t');
                    i += 2;
                },
                'x' => {
                    if (i + 3 < input.len) {
                        const byte = std.fmt.parseInt(u8, input[i + 2 .. i + 4], 16) catch {
                            try result.append(allocator, input[i]);
                            i += 1;
                            continue;
                        };
                        try result.append(allocator, byte);
                        i += 4;
                    } else {
                        try result.append(allocator, input[i]);
                        i += 1;
                    }
                },
                else => {
                    try result.append(allocator, input[i]);
                    i += 1;
                },
            }
        } else {
            try result.append(allocator, input[i]);
            i += 1;
        }
    }
    return try result.toOwnedSlice(allocator);
}

fn findKeyColon(line: []const u8) ?usize {
    for (line, 0..) |char, i| {
        if (char == ':') return i;
    }
    return null;
}

fn isBlankOrComment(line: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, line, " ");
    return trimmed.len == 0 or trimmed[0] == '#';
}

fn peekNextIndent(all_lines: []const []const u8, start: usize) ?usize {
    var i = start;
    while (i < all_lines.len) : (i += 1) {
        const line = all_lines[i];
        if (line.len == 0 or isBlankOrComment(line)) continue;
        return lineIndent(line);
    }
    return null;
}

fn skipNestedBlock(all_lines: []const []const u8, pos: *usize, parent_indent: usize) void {
    while (pos.* < all_lines.len) {
        const line = all_lines[pos.*];
        if (line.len == 0 or isBlankOrComment(line)) {
            pos.* += 1;
            continue;
        }
        if (lineIndent(line) <= parent_indent) return;
        pos.* += 1;
    }
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
        \\name: alice
        \\age: 30
        \\active: true
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
        \\name: myapp
        \\server:
        \\  host: localhost
        \\  port: 8080
        \\
    , writer.buffered());
}

test "serialize sequence of strings" {
    const Config = struct { tags: []const []const u8 };
    const serde = Serde(Config);
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try serde.serialize(&writer, Config{ .tags = &.{ "web", "api" } });
    try std.testing.expectEqualStrings(
        \\tags:
        \\  - web
        \\  - api
        \\
    , writer.buffered());
}

test "serialize sequence of numbers" {
    const Data = struct { scores: []const u32 };
    const serde = Serde(Data);
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try serde.serialize(&writer, Data{ .scores = &.{ 100, 90, 80 } });
    try std.testing.expectEqualStrings(
        \\scores:
        \\  - 100
        \\  - 90
        \\  - 80
        \\
    , writer.buffered());
}

test "serialize optional null" {
    const Config = struct { host: []const u8, port: ?u16 };
    const serde = Serde(Config);
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try serde.serialize(&writer, Config{ .host = "localhost", .port = null });
    try std.testing.expectEqualStrings(
        \\host: localhost
        \\port: null
        \\
    , writer.buffered());
}

test "serialize optional present" {
    const Config = struct { host: []const u8, port: ?u16 };
    const serde = Serde(Config);
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try serde.serialize(&writer, Config{ .host = "localhost", .port = 8080 });
    try std.testing.expectEqualStrings(
        \\host: localhost
        \\port: 8080
        \\
    , writer.buffered());
}

test "serialize multi-line string" {
    const Doc = struct { content: []const u8 };
    const serde = Serde(Doc);
    var buf: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try serde.serialize(&writer, Doc{ .content = "line1\nline2\nline3" });
    try std.testing.expectEqualStrings(
        \\content: |-
        \\  line1
        \\  line2
        \\  line3
        \\
    , writer.buffered());
}

test "serialize struct sequence" {
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
        \\servers:
        \\  - host: a.com
        \\    port: 80
        \\  - host: b.com
        \\    port: 443
        \\
    , writer.buffered());
}

test "serialize string needing quotes" {
    const Config = struct { value: []const u8 };
    const serde = Serde(Config);
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try serde.serialize(&writer, Config{ .value = "has: colon" });
    try std.testing.expectEqualStrings(
        \\value: "has: colon"
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
    var result = try serde.deserialize(std.testing.allocator,
        \\name: alice
        \\age: 30
        \\active: true
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
        \\name: myapp
        \\server:
        \\  host: localhost
        \\  port: 8080
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("myapp", result.value.name);
    try std.testing.expectEqualStrings("localhost", result.value.server.host);
    try std.testing.expectEqual(@as(u16, 8080), result.value.server.port);
}

test "deserialize sequence of strings" {
    const Config = struct { tags: []const []const u8 };
    const serde = Serde(Config);
    var result = try serde.deserialize(std.testing.allocator,
        \\tags:
        \\  - web
        \\  - api
    );
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), result.value.tags.len);
    try std.testing.expectEqualStrings("web", result.value.tags[0]);
    try std.testing.expectEqualStrings("api", result.value.tags[1]);
}

test "deserialize sequence of numbers" {
    const Data = struct { scores: []const u32 };
    const serde = Serde(Data);
    var result = try serde.deserialize(std.testing.allocator,
        \\scores:
        \\  - 100
        \\  - 90
        \\  - 80
    );
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 3), result.value.scores.len);
    try std.testing.expectEqual(@as(u32, 100), result.value.scores[0]);
    try std.testing.expectEqual(@as(u32, 90), result.value.scores[1]);
    try std.testing.expectEqual(@as(u32, 80), result.value.scores[2]);
}

test "deserialize optional null" {
    const Config = struct { host: []const u8, port: ?u16 };
    const serde = Serde(Config);
    var result = try serde.deserialize(std.testing.allocator,
        \\host: localhost
        \\port: null
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("localhost", result.value.host);
    try std.testing.expectEqual(@as(?u16, null), result.value.port);
}

test "deserialize optional present" {
    const Config = struct { host: []const u8, port: ?u16 };
    const serde = Serde(Config);
    var result = try serde.deserialize(std.testing.allocator,
        \\host: localhost
        \\port: 8080
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("localhost", result.value.host);
    try std.testing.expectEqual(@as(?u16, 8080), result.value.port);
}

test "deserialize literal block scalar" {
    const Doc = struct { content: []const u8 };
    const serde = Serde(Doc);
    var result = try serde.deserialize(std.testing.allocator,
        \\content: |-
        \\  line1
        \\  line2
        \\  line3
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("line1\nline2\nline3", result.value.content);
}

test "deserialize struct sequence" {
    const Server = struct { host: []const u8, port: u16 };
    const Config = struct { servers: []const Server };
    const serde = Serde(Config);
    var result = try serde.deserialize(std.testing.allocator,
        \\servers:
        \\  - host: a.com
        \\    port: 80
        \\  - host: b.com
        \\    port: 443
    );
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), result.value.servers.len);
    try std.testing.expectEqualStrings("a.com", result.value.servers[0].host);
    try std.testing.expectEqual(@as(u16, 80), result.value.servers[0].port);
    try std.testing.expectEqualStrings("b.com", result.value.servers[1].host);
    try std.testing.expectEqual(@as(u16, 443), result.value.servers[1].port);
}

test "deserialize quoted string" {
    const Config = struct { value: []const u8 };
    const serde = Serde(Config);
    var result = try serde.deserialize(std.testing.allocator,
        \\value: "has: colon"
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("has: colon", result.value.value);
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

test "roundtrip: struct sequence" {
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

test "roundtrip: string ending with newline" {
    const Doc = struct { content: []const u8 };
    const serde = Serde(Doc);
    const original = Doc{ .content = "hello\nworld\n" };

    var buf: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try serde.serialize(&writer, original);

    var restored = try serde.deserialize(std.testing.allocator, writer.buffered());
    defer restored.deinit();

    try std.testing.expectEqualStrings(original.content, restored.value.content);
}

// ==================== Error Case Tests ====================

test "error: missing required field" {
    const Config = struct { host: []const u8, port: u16 };
    const serde = Serde(Config);
    const result = serde.deserialize(std.testing.allocator, "host: localhost\n");
    try std.testing.expectError(error.MissingField, result);
}

test "error: duplicate field" {
    const Config = struct { host: []const u8 };
    const serde = Serde(Config);
    const result = serde.deserialize(std.testing.allocator,
        \\host: first
        \\host: second
    );
    try std.testing.expectError(error.DuplicateField, result);
}

test "error: type mismatch string for int" {
    const Data = struct { count: u32 };
    const serde = Serde(Data);
    const result = serde.deserialize(std.testing.allocator, "count: hello\n");
    try std.testing.expect(std.meta.isError(result));
}

test "error: type mismatch string for bool" {
    const Data = struct { flag: bool };
    const serde = Serde(Data);
    const result = serde.deserialize(std.testing.allocator, "flag: yes\n");
    try std.testing.expectError(error.UnexpectedToken, result);
}

test "error: empty input missing fields" {
    const Data = struct { name: []const u8 };
    const serde = Serde(Data);
    const result = serde.deserialize(std.testing.allocator, "");
    try std.testing.expectError(error.MissingField, result);
}

test "error: sequence item type mismatch" {
    const Data = struct { scores: []const u32 };
    const serde = Serde(Data);
    const result = serde.deserialize(std.testing.allocator,
        \\scores:
        \\  - hello
        \\  - world
    );
    try std.testing.expect(std.meta.isError(result));
}

test "error: nested struct missing field" {
    const Inner = struct { host: []const u8, port: u16 };
    const Config = struct { server: Inner };
    const serde = Serde(Config);
    const result = serde.deserialize(std.testing.allocator,
        \\server:
        \\  host: localhost
    );
    try std.testing.expectError(error.MissingField, result);
}

test "error: struct sequence item missing field" {
    const Server = struct { host: []const u8, port: u16 };
    const Config = struct { servers: []const Server };
    const serde = Serde(Config);
    const result = serde.deserialize(std.testing.allocator,
        \\servers:
        \\  - host: a.com
    );
    try std.testing.expectError(error.MissingField, result);
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

test "serialize enum in sequence" {
    const Color = enum { red, green, blue };
    const Data = struct { colors: []const Color };
    const serde = Serde(Data);
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try serde.serialize(&writer, Data{ .colors = &.{ .red, .blue } });
    try std.testing.expectEqualStrings(
        \\colors:
        \\  - red
        \\  - blue
        \\
    , writer.buffered());
}

test "deserialize enum in sequence" {
    const Color = enum { red, green, blue };
    const Data = struct { colors: []const Color };
    const serde = Serde(Data);
    var result = try serde.deserialize(std.testing.allocator,
        \\colors:
        \\  - red
        \\  - blue
    );
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), result.value.colors.len);
    try std.testing.expectEqual(Color.red, result.value.colors[0]);
    try std.testing.expectEqual(Color.blue, result.value.colors[1]);
}

test "error: invalid enum value" {
    const Status = enum { active, inactive };
    const Data = struct { status: Status };
    const serde = Serde(Data);
    const result = serde.deserialize(std.testing.allocator, "status: unknown\n");
    try std.testing.expectError(error.UnexpectedToken, result);
}

test "serde_fields yaml rename and alias" {
    const Data = struct {
        name: []const u8,

        pub const serde_fields = .{
            .name = .{
                .yaml = .{
                    .rename = "user-name",
                    .alias = &.{"username"},
                },
            },
        };
    };
    const serde = Serde(Data);

    var serialized: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&serialized);
    try serde.serialize(&writer, .{ .name = "alice" });
    try std.testing.expectEqualStrings(
        \\user-name: alice
        \\
    , writer.buffered());

    var result = try serde.deserialize(std.testing.allocator,
        \\username: bob
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("bob", result.value.name);
}

test "serde_fields yaml omit_null" {
    const Data = struct {
        id: u32,
        note: ?[]const u8 = null,

        pub const serde_fields = .{
            .note = .{
                .yaml = .{ .omit_null = true },
            },
        };
    };
    const serde = Serde(Data);

    var serialized: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&serialized);
    try serde.serialize(&writer, .{ .id = 1, .note = null });
    try std.testing.expectEqualStrings(
        \\id: 1
        \\
    , writer.buffered());
}

test "serde_fields yaml skip with default" {
    const Data = struct {
        id: u32,
        secret: []const u8 = "hidden",

        pub const serde_fields = .{
            .secret = .{
                .yaml = .{ .skip = true },
            },
        };
    };
    const serde = Serde(Data);

    var serialized: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&serialized);
    try serde.serialize(&writer, .{ .id = 7, .secret = "token" });
    try std.testing.expectEqualStrings(
        \\id: 7
        \\
    , writer.buffered());

    var result = try serde.deserialize(std.testing.allocator,
        \\id: 9
        \\secret: ignored
    );
    defer result.deinit();
    try std.testing.expectEqual(@as(u32, 9), result.value.id);
    try std.testing.expectEqualStrings("hidden", result.value.secret);
}
