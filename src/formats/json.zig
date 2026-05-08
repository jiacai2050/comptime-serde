const std = @import("std");

/// Returns a comptime-generated JSON serializer/deserializer for type `T`.
pub fn Serde(comptime T: type) type {
    return struct {
        /// Writes `value` as JSON to `writer`.
        pub fn serialize(writer: *std.Io.Writer, value: T) !void {
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
                    inline for (struct_info.fields, 0..) |field, index| {
                        if (index > 0) try writer.writeByte(',');
                        try writeString(writer, field.name);
                        try writer.writeByte(':');
                        const FieldSerializer = Serde(field.type);
                        try FieldSerializer.serialize(writer, @field(value, field.name));
                    }
                    try writer.writeByte('}');
                },
                else => @compileError("unsupported type: " ++ @typeName(T)),
            }
        }

        /// Parses `input` as JSON into a `Parsed(T)` that owns all allocated memory; caller must call `deinit()`.
        pub fn deserialize(allocator: std.mem.Allocator, input: []const u8) !Parsed(T) {
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
                            try list.append(allocator, try ItemParser.parseValue(scanner, allocator));
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
                        if (len < array_info.len) result[len] = 0;
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
                            if (std.mem.eql(u8, field.name, key)) {
                                if (fields_seen[index]) return error.DuplicateField;
                                const FieldParser = Serde(field.type);
                                @field(result, field.name) = try FieldParser.parseValue(scanner, allocator);
                                fields_seen[index] = true;
                                break;
                            }
                        } else {
                            try scanner.skipValue();
                        }
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
    };
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

/// Wraps a deserialized value of type `T` with an arena allocator for deterministic cleanup.
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
