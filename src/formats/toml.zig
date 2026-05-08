const std = @import("std");

/// Returns a comptime-generated TOML serializer/deserializer for type `T`.
pub fn Serde(comptime T: type) type {
    return struct {
        /// Writes `value` as TOML to `writer`.
        pub fn serialize(writer: *std.Io.Writer, value: T) !void {
            try writeTable(writer, value);
        }

        /// Parses `input` as TOML into a `Parsed(T)` that owns all allocated memory; caller must call `deinit()`.
        pub fn deserialize(allocator: std.mem.Allocator, input: []const u8) !Parsed(T) {
            var arena = std.heap.ArenaAllocator.init(allocator);
            errdefer arena.deinit();

            const arena_allocator = arena.allocator();
            var lines = std.mem.splitScalar(u8, input, '\n');
            var line_ptr: ?[]const u8 = lines.next();

            const value = try parseStructFull(T, arena_allocator, &lines, &line_ptr, false);

            return .{ .arena = arena, .value = value };
        }
    };
}

// ==================== Serialization ====================

/// Writes a struct as TOML: key-value pairs first, then nested table sections.
fn writeTable(writer: *std.Io.Writer, value: anytype) !void {
    const T = @TypeOf(value);
    const info = @typeInfo(T);
    switch (info) {
        .@"struct" => |struct_info| {
            // Pass 1: write key-value pairs (primitives, strings, inline arrays).
            inline for (struct_info.fields) |field| {
                const field_type_info = @typeInfo(field.type);
                switch (field_type_info) {
                    .@"struct" => {}, // handled in pass 2
                    .pointer => |pointer_info| {
                        if (pointer_info.size == .slice and pointer_info.child == u8) {
                            // String slice → inline KV.
                            try writeKeyValue(writer, field.name, @field(value, field.name));
                        } else if (pointer_info.size == .slice) {
                            // Non-string slice: inline if primitives, table array if structs.
                            const child_info = @typeInfo(pointer_info.child);
                            if (child_info != .@"struct") {
                                try writeKeyValue(writer, field.name, @field(value, field.name));
                            }
                        }
                    },
                    else => {
                        try writeKeyValue(writer, field.name, @field(value, field.name));
                    },
                }
            }
            // Pass 2: write [table] and [[array]] sections.
            inline for (struct_info.fields) |field| {
                const field_type_info = @typeInfo(field.type);
                switch (field_type_info) {
                    .@"struct" => {
                        try writer.print("[{s}]\n", .{field.name});
                        try writeTable(writer, @field(value, field.name));
                    },
                    .pointer => |pointer_info| {
                        if (pointer_info.size == .slice and pointer_info.child != u8) {
                            const child_info = @typeInfo(pointer_info.child);
                            if (child_info == .@"struct") {
                                for (@field(value, field.name)) |item| {
                                    try writer.print("[[{s}]]\n", .{field.name});
                                    try writeTable(writer, item);
                                }
                            }
                        }
                    },
                    .array => |array_info| {
                        if (array_info.child != u8) {
                            const child_info = @typeInfo(array_info.child);
                            if (child_info == .@"struct") {
                                for (@field(value, field.name)) |item| {
                                    try writer.print("[[{s}]]\n", .{field.name});
                                    try writeTable(writer, item);
                                }
                            }
                        }
                    },
                    else => {},
                }
            }
        },
        else => {},
    }
}

fn writeKeyValue(writer: *std.Io.Writer, comptime key: []const u8, value: anytype) !void {
    try writer.print("{s} = ", .{key});
    try writeValue(writer, value);
    try writer.writeByte('\n');
}

fn writeValue(writer: *std.Io.Writer, value: anytype) !void {
    const T = @TypeOf(value);
    const info = @typeInfo(T);
    switch (info) {
        .bool => try writer.writeAll(if (value) "true" else "false"),
        .int => try writer.print("{d}", .{value}),
        .float => try writer.print("{d}", .{value}),
        .pointer => |pointer_info| {
            if (pointer_info.size == .slice and pointer_info.child == u8) {
                try writeString(writer, value);
            } else if (pointer_info.size == .slice) {
                try writeInlineArray(writer, value);
            } else {
                @compileError("unsupported pointer type: " ++ @typeName(T));
            }
        },
        .array => |array_info| {
            if (array_info.child == u8) {
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
        else => @compileError("unsupported type: " ++ @typeName(T)),
    }
}

fn writeString(writer: *std.Io.Writer, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |char| {
        switch (char) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (char < 0x20) {
                    try writer.print("\\u{x:0>4}", .{char});
                } else {
                    try writer.writeByte(char);
                }
            },
        }
    }
    try writer.writeByte('"');
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
/// When `in_array` is true, stops at [[array]] headers without dispatching them
/// (the caller handles subsequent elements).
fn parseStructFull(
    comptime T: type,
    allocator: std.mem.Allocator,
    lines: *std.mem.SplitIterator(u8, .scalar),
    line_ptr: *?[]const u8,
    in_array: bool,
) !T {
    const info = @typeInfo(T);
    switch (info) {
        .@"struct" => |struct_info| {
            var result: T = undefined;
            var fields_seen = [_]bool{false} ** struct_info.fields.len;

            // Phase 1: parse key-value lines.
            try parseKvLines(T, &result, &fields_seen, allocator, lines, line_ptr);

            // Phase 2: dispatch [table] and [[array]] headers.
            while (line_ptr.*) |raw_line| {
                const trimmed = std.mem.trim(u8, raw_line, " \r");
                if (trimmed.len == 0 or trimmed[0] == '#') {
                    line_ptr.* = lines.next();
                    continue;
                }

                if (trimmed[0] == '[') {
                    if (trimmed.len > 2 and trimmed[1] == '[') {
                        if (in_array) {
                            // Inside a table array element: [[array]] belongs to the caller.
                            return result;
                        }
                        // Top level: dispatch [[array]].
                        const array_name = extractBracketedName(trimmed, 2, trimmed.len - 2);
                        line_ptr.* = lines.next();
                        try dispatchTableArray(T, &result, &fields_seen, allocator, lines, line_ptr, array_name);
                    } else {
                        // [table] header.
                        const table_name = extractBracketedName(trimmed, 1, trimmed.len - 1);
                        line_ptr.* = lines.next();
                        try dispatchTable(T, &result, &fields_seen, allocator, lines, line_ptr, table_name);
                    }
                    continue;
                }

                // Unknown line format — skip.
                line_ptr.* = lines.next();
            }

            inline for (struct_info.fields, 0..) |field, index| {
                if (!fields_seen[index]) {
                    if (field.default_value_ptr) |default_ptr| {
                        @field(result, field.name) = @as(*const field.type, @ptrCast(@alignCast(default_ptr))).*;
                    } else {
                        return error.MissingField;
                    }
                }
            }
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
    allocator: std.mem.Allocator,
    lines: *std.mem.SplitIterator(u8, .scalar),
    line_ptr: *?[]const u8,
) !void {
    while (line_ptr.*) |raw_line| {
        const trimmed = std.mem.trim(u8, raw_line, " \r");
        if (trimmed.len == 0 or trimmed[0] == '#') {
            line_ptr.* = lines.next();
            continue;
        }
        if (trimmed[0] == '[') {
            return;
        }

        const eq_pos = std.mem.indexOfScalar(u8, trimmed, '=');
        if (eq_pos == null) {
            line_ptr.* = lines.next();
            continue;
        }
        const eq_index = eq_pos.?;
        const key = std.mem.trim(u8, trimmed[0..eq_index], " ");
        const raw_value = std.mem.trim(u8, trimmed[eq_index + 1 ..], " ");

        try parseKvLine(T, result, fields_seen, allocator, key, raw_value);
        line_ptr.* = lines.next();
    }
}

fn extractBracketedName(line: []const u8, start_index: usize, end_index: usize) []const u8 {
    return std.mem.trim(u8, line[start_index..end_index], " ");
}

fn dispatchTable(
    comptime T: type,
    result: *T,
    fields_seen: *[std.meta.fields(T).len]bool,
    allocator: std.mem.Allocator,
    lines: *std.mem.SplitIterator(u8, .scalar),
    line_ptr: *?[]const u8,
    table_name: []const u8,
) !void {
    const struct_info = @typeInfo(T).@"struct";

    inline for (struct_info.fields, 0..) |field, index| {
        if (std.mem.eql(u8, field.name, table_name)) {
            if (fields_seen[index]) return error.DuplicateField;
            const field_info = @typeInfo(field.type);
            if (field_info == .@"struct") {
                @field(result, field.name) = try parseStructFull(field.type, allocator, lines, line_ptr, false);
                fields_seen[index] = true;
                return;
            }
        }
    }
    skipSection(lines, line_ptr);
}

fn dispatchTableArray(
    comptime T: type,
    result: *T,
    fields_seen: *[std.meta.fields(T).len]bool,
    allocator: std.mem.Allocator,
    lines: *std.mem.SplitIterator(u8, .scalar),
    line_ptr: *?[]const u8,
    array_name: []const u8,
) !void {
    const struct_info = @typeInfo(T).@"struct";

    inline for (struct_info.fields, 0..) |field, index| {
        if (std.mem.eql(u8, field.name, array_name)) {
            if (fields_seen[index]) return error.DuplicateField;
            const field_info = @typeInfo(field.type);
            if (field_info == .pointer and field_info.pointer.size == .slice) {
                const child_info = @typeInfo(field_info.pointer.child);
                if (child_info == .@"struct") {
                    @field(result, field.name) = try parseTableArray(
                        field_info.pointer.child,
                        allocator,
                        lines,
                        line_ptr,
                        array_name,
                    );
                    fields_seen[index] = true;
                    return;
                }
            }
        }
    }
    skipSection(lines, line_ptr);
}

fn parseTableArray(
    comptime Item: type,
    allocator: std.mem.Allocator,
    lines: *std.mem.SplitIterator(u8, .scalar),
    line_ptr: *?[]const u8,
    array_name: []const u8,
) ![]Item {
    var list = std.ArrayList(Item).empty;
    errdefer list.deinit(allocator);

    // line_ptr already points past the first [[array]] header (advanced by caller).
    while (true) {
        const item = try parseStructFull(Item, allocator, lines, line_ptr, true);
        try list.append(allocator, item);

        // parseStructFull(in_array=true) stops at [[array]] headers without consuming them.
        // Check if it's another element of this array.
        if (line_ptr.*) |next_line| {
            const next_trimmed = std.mem.trim(u8, next_line, " \r");
            if (next_trimmed.len > 3 and next_trimmed[0] == '[' and next_trimmed[1] == '[') {
                const next_name = extractBracketedName(next_trimmed, 2, next_trimmed.len - 2);
                if (std.mem.eql(u8, next_name, array_name)) {
                    line_ptr.* = lines.next();
                    continue;
                }
            }
        }
        break;
    }
    return try list.toOwnedSlice(allocator);
}

fn skipSection(
    lines: *std.mem.SplitIterator(u8, .scalar),
    line_ptr: *?[]const u8,
) void {
    while (line_ptr.*) |raw_line| {
        const trimmed = std.mem.trim(u8, raw_line, " \r");
        if (trimmed.len == 0 or trimmed[0] == '#') {
            line_ptr.* = lines.next();
            continue;
        }
        if (trimmed[0] == '[') {
            return;
        }
        line_ptr.* = lines.next();
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
        if (std.mem.eql(u8, field.name, key)) {
            if (fields_seen[index]) return error.DuplicateField;
            // Use a comptime switch to avoid instantiating parseTomlValue for struct types.
            switch (@typeInfo(field.type)) {
                .@"struct" => {},
                .pointer => |pointer_info| {
                    if (pointer_info.size == .slice) {
                        @field(result, field.name) = try parseTomlValue(field.type, allocator, raw_value);
                        fields_seen[index] = true;
                    }
                },
                else => {
                    @field(result, field.name) = try parseTomlValue(field.type, allocator, raw_value);
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
    const info = @typeInfo(T);
    switch (info) {
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
        .pointer => |pointer_info| {
            if (pointer_info.size == .slice and pointer_info.child == u8) {
                return try scanString(allocator, raw_value);
            } else if (pointer_info.size == .slice) {
                return try parseInlineArray(pointer_info.child, allocator, raw_value);
            } else {
                @compileError("unsupported pointer type: " ++ @typeName(T));
            }
        },
        .array => |array_info| {
            if (array_info.child == u8) {
                const src = try scanString(allocator, raw_value);
                var result: T = undefined;
                const len = @min(src.len, array_info.len);
                @memcpy(result[0..len], src[0..len]);
                if (len < array_info.len) result[len] = 0;
                return result;
            }
            @compileError("unsupported array type: " ++ @typeName(T));
        },
        .optional => |optional_info| {
            if (std.mem.eql(u8, raw_value, "\"\"") or std.mem.eql(u8, raw_value, "null")) {
                return null;
            }
            return try parseTomlValue(optional_info.child, allocator, raw_value);
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
    if (content.len < 2 or content[0] != '[' or content[content.len - 1] != ']') {
        return error.UnexpectedToken;
    }
    const inner = std.mem.trim(u8, content[1 .. content.len - 1], " ");
    if (inner.len == 0) return &[_]Item{};

    var list = std.ArrayList(Item).empty;
    errdefer list.deinit(allocator);

    var parts = std.mem.splitScalar(u8, inner, ',');
    while (parts.next()) |part| {
        const element = std.mem.trim(u8, part, " ");
        try list.append(allocator, try parseTomlPrimitive(Item, allocator, element));
    }
    return try list.toOwnedSlice(allocator);
}

fn parseTomlPrimitive(comptime T: type, allocator: std.mem.Allocator, raw_value: []const u8) !T {
    const info = @typeInfo(T);
    switch (info) {
        .bool => {
            if (std.mem.eql(u8, raw_value, "true")) return true;
            if (std.mem.eql(u8, raw_value, "false")) return false;
            return error.UnexpectedToken;
        },
        .int => return std.fmt.parseInt(T, raw_value, 10),
        .float => return std.fmt.parseFloat(T, raw_value),
        .pointer => |pointer_info| {
            if (pointer_info.size == .slice and pointer_info.child == u8) {
                return try scanString(allocator, raw_value);
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
        .string => |s| s,
        .allocated_string => |s| s,
        else => error.UnexpectedToken,
    };
}

// ==================== Parsed ====================

pub fn Parsed(comptime T: type) type {
    return struct {
        arena: std.heap.ArenaAllocator,
        value: T,

        /// Frees all memory allocated during deserialization.
        pub fn deinit(self: *@This()) void {
            self.arena.deinit();
        }
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
