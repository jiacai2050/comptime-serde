const std = @import("std");
const common = @import("common.zig");
const Parsed = common.Parsed;

/// Returns a comptime-generated JSON serializer/deserializer for type `T`.
pub fn Serde(comptime T: type) type {
    return struct {
        /// Writes `value` as JSON to `writer`.
        pub fn serialize(writer: *std.Io.Writer, value: T) !void {
            comptime common.validateFieldConfigs(.json, T);
            const info = @typeInfo(T);
            switch (info) {
                .bool => try writer.writeAll(if (value) "true" else "false"),
                .int => try writer.print("{}", .{value}),
                .float => try writer.print("{}", .{value}),
                .pointer => |pointer_info| {
                    if (pointer_info.size == .slice and pointer_info.child == u8) {
                        try writeString(writer, value);
                    } else if (pointer_info.size == .slice) {
                        try writer.writeByte('[');
                        const ItemSerializer = Serde(pointer_info.child);
                        for (value, 0..) |item, index| {
                            if (index > 0) try writer.writeByte(',');
                            try ItemSerializer.serialize(writer, item);
                        }
                        try writer.writeByte(']');
                    } else if (pointer_info.size == .one) {
                        const child = @typeInfo(pointer_info.child);
                        if (child == .array and child.array.child == u8) {
                            try writeString(writer, @as([]const u8, value));
                        } else {
                            @compileError("unsupported pointer type: " ++ @typeName(T));
                        }
                    } else {
                        @compileError("unsupported pointer type: " ++ @typeName(T));
                    }
                },
                .array => |array_info| {
                    if (array_info.child == u8) {
                        try writeString(writer, &value);
                    } else {
                        const ItemSerializer = Serde(array_info.child);
                        try writer.writeByte('[');
                        inline for (value, 0..) |item, index| {
                            if (index > 0) try writer.writeByte(',');
                            try ItemSerializer.serialize(writer, item);
                        }
                        try writer.writeByte(']');
                    }
                },
                .optional => {
                    if (value) |present| {
                        const OptionalSerializer = Serde(@TypeOf(present));
                        try OptionalSerializer.serialize(writer, present);
                    } else {
                        try writer.writeAll("null");
                    }
                },
                .@"struct" => |struct_info| {
                    try writer.writeByte('{');
                    var first = true;
                    inline for (struct_info.fields) |field| {
                        const field_value = @field(value, field.name);
                        if (common.shouldIncludeField(.json, T, field.name, field_value)) {
                            if (!first) try writer.writeByte(',');
                            first = false;
                            try writeString(writer, common.serializedFieldName(.json, T, field.name));
                            try writer.writeByte(':');
                            const FieldSerializer = Serde(field.type);
                            try FieldSerializer.serialize(writer, field_value);
                        }
                    }
                    try writer.writeByte('}');
                },
                .@"enum" => try writeString(writer, @tagName(value)),
                else => @compileError("unsupported type: " ++ @typeName(T)),
            }
        }

        /// Parses `input` as JSON into a `Parsed(T)` that owns all allocated memory.
        /// Caller must call `deinit()`.
        pub fn deserialize(allocator: std.mem.Allocator, input: []const u8) !Parsed(T) {
            comptime common.validateFieldConfigs(.json, T);
            var arena = std.heap.ArenaAllocator.init(allocator);
            errdefer arena.deinit();

            const arena_allocator = arena.allocator();
            var scanner = std.json.Scanner.initCompleteInput(arena_allocator, input);
            defer scanner.deinit();

            const value = try parseValue(&scanner, arena_allocator);

            return .{ .arena = arena, .value = value };
        }

        fn parseValue(scanner: *std.json.Scanner, allocator: std.mem.Allocator) !T {
            const info = @typeInfo(T);
            switch (info) {
                .bool => {
                    return switch (try scanner.next()) {
                        .true => true,
                        .false => false,
                        else => error.UnexpectedToken,
                    };
                },
                .int => {
                    return switch (try scanner.next()) {
                        .number => |num_str| std.fmt.parseInt(T, num_str, 10),
                        else => error.UnexpectedToken,
                    };
                },
                .float => {
                    return switch (try scanner.next()) {
                        .number => |num_str| std.fmt.parseFloat(T, num_str),
                        else => error.UnexpectedToken,
                    };
                },
                .pointer => |pointer_info| {
                    if (pointer_info.size == .slice and pointer_info.child == u8) {
                        return switch (try scanner.nextAlloc(allocator, .alloc_always)) {
                            .string => |str| str,
                            .allocated_string => |str| str,
                            else => error.UnexpectedToken,
                        };
                    } else if (pointer_info.size == .slice) {
                        if (try scanner.next() != .array_begin) return error.UnexpectedToken;
                        var list = std.ArrayList(pointer_info.child).empty;
                        errdefer list.deinit(allocator);
                        while (true) {
                            if ((try scanner.peekNextTokenType()) == .array_end) {
                                _ = try scanner.next();
                                break;
                            }
                            const ItemParser = Serde(pointer_info.child);
                            const item = try ItemParser.parseValue(scanner, allocator);
                            try list.append(allocator, item);
                        }
                        return try list.toOwnedSlice(allocator);
                    } else {
                        @compileError("unsupported pointer type: " ++ @typeName(T));
                    }
                },
                .array => |array_info| {
                    if (array_info.child == u8) {
                        const src = switch (try scanner.nextAlloc(allocator, .alloc_always)) {
                            .string => |str| str,
                            .allocated_string => |str| str,
                            else => return error.UnexpectedToken,
                        };
                        var result: T = undefined;
                        const len = @min(src.len, array_info.len);
                        @memcpy(result[0..len], src[0..len]);
                        @memset(result[len..], 0);
                        return result;
                    } else {
                        if (try scanner.next() != .array_begin) return error.UnexpectedToken;
                        var result: T = undefined;
                        inline for (0..array_info.len) |index| {
                            const ItemParser = Serde(array_info.child);
                            result[index] = try ItemParser.parseValue(scanner, allocator);
                        }
                        if (try scanner.next() != .array_end) return error.UnexpectedToken;
                        return result;
                    }
                },
                .optional => |optional_info| {
                    if ((try scanner.peekNextTokenType()) == .null) {
                        _ = try scanner.next();
                        return null;
                    }
                    const OptionalParser = Serde(optional_info.child);
                    return try OptionalParser.parseValue(scanner, allocator);
                },
                .@"struct" => |struct_info| {
                    if (try scanner.next() != .object_begin) return error.UnexpectedToken;
                    var result: T = undefined;
                    var fields_seen = [_]bool{false} ** struct_info.fields.len;
                    while (true) {
                        const key = switch (try scanner.nextAlloc(allocator, .alloc_if_needed)) {
                            .string => |str| str,
                            .allocated_string => |str| str,
                            .object_end => break,
                            else => return error.UnexpectedToken,
                        };
                        inline for (struct_info.fields, 0..) |field, index| {
                            if (common.matchesInputKey(.json, T, field.name, key)) {
                                const config = common.deserializeConfig(.json, T, field.name);
                                if (config.skip) {
                                    try scanner.skipValue();
                                    break;
                                }
                                if (fields_seen[index]) return error.DuplicateField;
                                const FieldParser = Serde(field.type);
                                const parsed = try FieldParser.parseValue(scanner, allocator);
                                @field(result, field.name) = parsed;
                                fields_seen[index] = true;
                                break;
                            }
                        } else {
                            try scanner.skipValue();
                        }
                    }
                    try common.fillMissingFields(.json, T, &result, &fields_seen);
                    return result;
                },
                .@"enum" => |enum_info| {
                    const str = switch (try scanner.nextAlloc(allocator, .alloc_if_needed)) {
                        .string => |s| s,
                        .allocated_string => |s| s,
                        else => return error.UnexpectedToken,
                    };
                    inline for (enum_info.fields) |field| {
                        if (std.mem.eql(u8, field.name, str)) {
                            return @enumFromInt(field.value);
                        }
                    }
                    return error.UnexpectedToken;
                },
                else => @compileError("unsupported type: " ++ @typeName(T)),
            }
        }
    };
}

fn writeString(writer: *std.Io.Writer, string: []const u8) !void {
    try writer.writeByte('"');
    for (string) |char| {
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

test "serialize bool" {
    const serde = Serde(bool);
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try serde.serialize(&writer, true);
    try std.testing.expectEqualStrings("true", writer.buffered());
}

test "serialize int" {
    const serde = Serde(u32);
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try serde.serialize(&writer, 42);
    try std.testing.expectEqualStrings("42", writer.buffered());
}

test "serialize float" {
    const serde = Serde(f64);
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try serde.serialize(&writer, 3.14);
    try std.testing.expect(std.mem.startsWith(u8, writer.buffered(), "3.14"));
}

test "serialize string" {
    const serde = Serde([]const u8);
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try serde.serialize(&writer, "hello");
    try std.testing.expectEqualStrings("\"hello\"", writer.buffered());
}

test "serialize string with escapes" {
    const serde = Serde([]const u8);
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try serde.serialize(&writer, "line1\nline2");
    try std.testing.expectEqualStrings("\"line1\\nline2\"", writer.buffered());
}

test "serialize optional present" {
    const serde = Serde(?u32);
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try serde.serialize(&writer, 42);
    try std.testing.expectEqualStrings("42", writer.buffered());
}

test "serialize optional null" {
    const serde = Serde(?u32);
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try serde.serialize(&writer, null);
    try std.testing.expectEqualStrings("null", writer.buffered());
}

test "serialize struct" {
    const User = struct {
        name: []const u8,
        age: u32,
        active: bool,
    };
    const serde = Serde(User);
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try serde.serialize(&writer, User{ .name = "alice", .age = 30, .active = true });
    try std.testing.expectEqualStrings(
        \\{"name":"alice","age":30,"active":true}
    , writer.buffered());
}

test "serialize nested struct" {
    const Address = struct { city: []const u8, zip: u32 };
    const User = struct { name: []const u8, address: Address };
    const serde = Serde(User);
    var buf: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try serde.serialize(&writer, User{
        .name = "bob",
        .address = .{ .city = "Beijing", .zip = 100000 },
    });
    try std.testing.expectEqualStrings(
        \\{"name":"bob","address":{"city":"Beijing","zip":100000}}
    , writer.buffered());
}

test "serialize string slice array" {
    const Team = struct { members: []const []const u8 };
    const serde = Serde(Team);
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try serde.serialize(&writer, Team{ .members = &.{ "alice", "bob" } });
    try std.testing.expectEqualStrings(
        \\{"members":["alice","bob"]}
    , writer.buffered());
}

test "serialize numeric array" {
    const Data = struct { scores: []const u32 };
    const serde = Serde(Data);
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try serde.serialize(&writer, Data{ .scores = &.{ 100, 90, 80 } });
    try std.testing.expectEqualStrings(
        \\{"scores":[100,90,80]}
    , writer.buffered());
}

test "deserialize bool" {
    const serde = Serde(bool);
    var result = try serde.deserialize(std.testing.allocator, "true");
    defer result.deinit();
    try std.testing.expectEqual(true, result.value);
}

test "deserialize int" {
    const serde = Serde(u32);
    var result = try serde.deserialize(std.testing.allocator, "42");
    defer result.deinit();
    try std.testing.expectEqual(@as(u32, 42), result.value);
}

test "deserialize string" {
    const serde = Serde([]const u8);
    var result = try serde.deserialize(std.testing.allocator, "\"hello\"");
    defer result.deinit();
    try std.testing.expectEqualStrings("hello", result.value);
}

test "deserialize struct" {
    const User = struct {
        name: []const u8,
        age: u32,
        active: bool,
    };
    const serde = Serde(User);
    var result = try serde.deserialize(std.testing.allocator,
        \\{"name":"alice","age":30,"active":true}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("alice", result.value.name);
    try std.testing.expectEqual(@as(u32, 30), result.value.age);
    try std.testing.expectEqual(true, result.value.active);
}

test "deserialize nested struct" {
    const Address = struct { city: []const u8, zip: u32 };
    const User = struct { name: []const u8, address: Address };
    const serde = Serde(User);
    var result = try serde.deserialize(std.testing.allocator,
        \\{"name":"bob","address":{"city":"Beijing","zip":100000}}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("bob", result.value.name);
    try std.testing.expectEqualStrings("Beijing", result.value.address.city);
    try std.testing.expectEqual(@as(u32, 100000), result.value.address.zip);
}

test "deserialize optional present" {
    const Config = struct { host: []const u8, port: ?u16 };
    const serde = Serde(Config);
    var result = try serde.deserialize(std.testing.allocator,
        \\{"host":"localhost","port":8080}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("localhost", result.value.host);
    try std.testing.expectEqual(@as(?u16, 8080), result.value.port);
}

test "deserialize optional null" {
    const Config = struct { host: []const u8, port: ?u16 };
    const serde = Serde(Config);
    var result = try serde.deserialize(std.testing.allocator,
        \\{"host":"localhost","port":null}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("localhost", result.value.host);
    try std.testing.expectEqual(@as(?u16, null), result.value.port);
}

test "deserialize array" {
    const Team = struct { members: []const []const u8 };
    const serde = Serde(Team);
    var result = try serde.deserialize(std.testing.allocator,
        \\{"members":["alice","bob"]}
    );
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), result.value.members.len);
    try std.testing.expectEqualStrings("alice", result.value.members[0]);
    try std.testing.expectEqualStrings("bob", result.value.members[1]);
}

test "roundtrip: basic struct" {
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

test "roundtrip: nested struct with optional and array" {
    const Config = struct {
        host: []const u8,
        port: ?u16,
        tags: []const []const u8,
    };
    const serde = Serde(Config);
    const original = Config{
        .host = "localhost",
        .port = 8080,
        .tags = &.{ "web", "api" },
    };

    var buf: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try serde.serialize(&writer, original);

    var restored = try serde.deserialize(std.testing.allocator, writer.buffered());
    defer restored.deinit();

    try std.testing.expectEqualStrings(original.host, restored.value.host);
    try std.testing.expectEqual(original.port, restored.value.port);
    try std.testing.expectEqual(original.tags.len, restored.value.tags.len);
    try std.testing.expectEqualStrings("web", restored.value.tags[0]);
    try std.testing.expectEqualStrings("api", restored.value.tags[1]);
}

// ==================== Error Case Tests ====================

test "error: missing required field" {
    const User = struct { name: []const u8, age: u32 };
    const serde = Serde(User);
    const result = serde.deserialize(std.testing.allocator, "{\"name\":\"alice\"}");
    try std.testing.expectError(error.MissingField, result);
}

test "error: duplicate field" {
    const User = struct { name: []const u8 };
    const serde = Serde(User);
    const result = serde.deserialize(std.testing.allocator,
        \\{"name":"alice","name":"bob"}
    );
    try std.testing.expectError(error.DuplicateField, result);
}

test "error: type mismatch string for int" {
    const Data = struct { count: u32 };
    const serde = Serde(Data);
    const result = serde.deserialize(std.testing.allocator,
        \\{"count":"hello"}
    );
    try std.testing.expectError(error.UnexpectedToken, result);
}

test "error: type mismatch int for bool" {
    const Data = struct { flag: bool };
    const serde = Serde(Data);
    const result = serde.deserialize(std.testing.allocator,
        \\{"flag":123}
    );
    try std.testing.expectError(error.UnexpectedToken, result);
}

test "error: empty input" {
    const Data = struct { name: []const u8 };
    const serde = Serde(Data);
    const result = serde.deserialize(std.testing.allocator, "");
    try std.testing.expect(std.meta.isError(result));
}

test "error: malformed json missing closing brace" {
    const Data = struct { name: []const u8 };
    const serde = Serde(Data);
    const result = serde.deserialize(std.testing.allocator,
        \\{"name":"alice"
    );
    try std.testing.expect(std.meta.isError(result));
}

test "error: malformed json invalid value" {
    const Data = struct { name: []const u8 };
    const serde = Serde(Data);
    const result = serde.deserialize(std.testing.allocator,
        \\{"name":undefined}
    );
    try std.testing.expect(std.meta.isError(result));
}

test "error: array expected but got object" {
    const Data = struct { items: []const u32 };
    const serde = Serde(Data);
    const result = serde.deserialize(std.testing.allocator,
        \\{"items":{"a":1}}
    );
    try std.testing.expectError(error.UnexpectedToken, result);
}

test "error: object expected but got array" {
    const Inner = struct { x: u32 };
    const Data = struct { inner: Inner };
    const serde = Serde(Data);
    const result = serde.deserialize(std.testing.allocator,
        \\{"inner":[1,2]}
    );
    try std.testing.expectError(error.UnexpectedToken, result);
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

test "serialize enum" {
    const Status = enum { active, inactive };
    const Data = struct { status: Status };
    const serde = Serde(Data);
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try serde.serialize(&writer, Data{ .status = .active });
    try std.testing.expectEqualStrings(
        \\{"status":"active"}
    , writer.buffered());
}

test "deserialize enum" {
    const Status = enum { active, inactive };
    const Data = struct { status: Status };
    const serde = Serde(Data);
    var result = try serde.deserialize(std.testing.allocator,
        \\{"status":"inactive"}
    );
    defer result.deinit();
    try std.testing.expectEqual(Status.inactive, result.value.status);
}

test "roundtrip: enum" {
    const Color = enum { red, green, blue };
    const Data = struct { color: Color };
    const serde = Serde(Data);
    const original = Data{ .color = .green };

    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try serde.serialize(&writer, original);

    var restored = try serde.deserialize(std.testing.allocator, writer.buffered());
    defer restored.deinit();

    try std.testing.expectEqual(original.color, restored.value.color);
}

test "error: invalid enum value" {
    const Status = enum { active, inactive };
    const Data = struct { status: Status };
    const serde = Serde(Data);
    const result = serde.deserialize(std.testing.allocator,
        \\{"status":"unknown"}
    );
    try std.testing.expectError(error.UnexpectedToken, result);
}

test "serde_fields json rename and alias" {
    const Data = struct {
        name: []const u8,

        pub const serde_fields = .{
            .name = .{
                .json = .{
                    .serialize = .{ .rename = "userName" },
                    .deserialize = .{ .rename = "userName", .alias = &.{"username"} },
                },
            },
        };
    };
    const serde = Serde(Data);

    var serialized: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&serialized);
    try serde.serialize(&writer, .{ .name = "alice" });
    try std.testing.expectEqualStrings("{\"userName\":\"alice\"}", writer.buffered());

    var result = try serde.deserialize(std.testing.allocator,
        \\{"username":"bob"}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("bob", result.value.name);
}

test "serde_fields json omit_null" {
    const Data = struct {
        id: u32,
        note: ?[]const u8 = null,

        pub const serde_fields = .{
            .note = .{
                .json = .{ .serialize = .{ .omit_null = true } },
            },
        };
    };
    const serde = Serde(Data);

    var serialized: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&serialized);
    try serde.serialize(&writer, .{ .id = 1, .note = null });
    try std.testing.expectEqualStrings("{\"id\":1}", writer.buffered());
}

test "serde_fields json skip with default" {
    const Data = struct {
        id: u32,
        secret: []const u8 = "hidden",

        pub const serde_fields = .{
            .secret = .{
                .json = .{
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
    try std.testing.expectEqualStrings("{\"id\":7}", writer.buffered());

    var result = try serde.deserialize(std.testing.allocator,
        \\{"id":9,"secret":"ignored"}
    );
    defer result.deinit();
    try std.testing.expectEqual(@as(u32, 9), result.value.id);
    try std.testing.expectEqualStrings("hidden", result.value.secret);
}
