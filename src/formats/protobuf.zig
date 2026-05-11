const std = @import("std");
const common = @import("common.zig");
const Parsed = common.Parsed;
const assert = std.debug.assert;

// Wire types per protobuf spec.
const WIRE_VARINT = 0;
const WIRE_I64 = 1;
const WIRE_LEN = 2;
const WIRE_I32 = 5;

/// Returns a comptime-generated protobuf serializer/deserializer for type `T`.
/// Field numbers are 1-based struct field order.
pub fn Serde(comptime T: type) type {
    return struct {
        /// Writes `value` as protobuf wire format to `writer`.
        pub fn serialize(
            writer: *std.Io.Writer,
            allocator: std.mem.Allocator,
            value: T,
        ) !void {
            comptime common.validateProtobufFieldNumbers(T);
            var buffer = std.ArrayList(u8).empty;
            defer buffer.deinit(allocator);
            try serializeMessage(allocator, &buffer, value);
            try writer.writeAll(buffer.items);
        }

        /// Deserializes protobuf wire format into `Parsed(T)`.
        /// Caller must call `deinit()`.
        pub fn deserialize(allocator: std.mem.Allocator, input: []const u8) !Parsed(T) {
            comptime common.validateProtobufFieldNumbers(T);
            var arena = std.heap.ArenaAllocator.init(allocator);
            errdefer arena.deinit();
            const arena_alloc = arena.allocator();

            const value = try deserializeMessage(T, arena_alloc, input);
            return .{ .arena = arena, .value = value };
        }
    };
}

// ==================== Serialization ====================

fn serializeMessage(
    allocator: std.mem.Allocator,
    buffer: *std.ArrayList(u8),
    value: anytype,
) !void {
    const T = @TypeOf(value);
    const struct_info = @typeInfo(T).@"struct";

    inline for (struct_info.fields, 0..) |field, index| {
        const field_num = common.effectiveProtobufFieldNumber(T, index);
        const field_value = @field(value, field.name);
        try serializeField(allocator, buffer, field.type, field_num, field_value);
    }
}

fn serializeField(
    allocator: std.mem.Allocator,
    buffer: *std.ArrayList(u8),
    comptime T: type,
    field_num: u32,
    value: anytype,
) !void {
    assert(field_num > 0);

    const type_info = @typeInfo(T);
    switch (type_info) {
        .bool => {
            try writeTag(buffer, allocator, field_num, WIRE_VARINT);
            try writeVarint(buffer, allocator, @intFromBool(value));
        },
        .int => {
            try writeTag(buffer, allocator, field_num, WIRE_VARINT);
            try writeVarint(buffer, allocator, value);
        },
        .float => |float_type_info| {
            if (float_type_info.bits == 32) {
                try writeTag(buffer, allocator, field_num, WIRE_I32);
                try writeFixed32(buffer, allocator, @bitCast(value));
            } else {
                try writeTag(buffer, allocator, field_num, WIRE_I64);
                try writeFixed64(buffer, allocator, @bitCast(value));
            }
        },
        .pointer => |pointer_type_info| {
            if (pointer_type_info.size == .slice) {
                if (pointer_type_info.child == u8) {
                    try writeTag(buffer, allocator, field_num, WIRE_LEN);
                    try writeVarint(buffer, allocator, value.len);
                    try buffer.appendSlice(allocator, value);
                } else {
                    const child_type_info = @typeInfo(pointer_type_info.child);
                    if (child_type_info == .@"struct") {
                        for (value) |item| {
                            try writeTag(buffer, allocator, field_num, WIRE_LEN);
                            var nested = std.ArrayList(u8).empty;
                            defer nested.deinit(allocator);
                            try serializeMessage(allocator, &nested, item);
                            try writeVarint(buffer, allocator, nested.items.len);
                            try buffer.appendSlice(allocator, nested.items);
                        }
                    } else {
                        // Packed repeated scalars.
                        try writeTag(buffer, allocator, field_num, WIRE_LEN);
                        var packed_buffer = std.ArrayList(u8).empty;
                        defer packed_buffer.deinit(allocator);
                        for (value) |item| {
                            try serializeScalar(allocator, &packed_buffer, pointer_type_info.child, item);
                        }
                        try writeVarint(buffer, allocator, packed_buffer.items.len);
                        try buffer.appendSlice(allocator, packed_buffer.items);
                    }
                }
            }
        },
        .@"struct" => {
            try writeTag(buffer, allocator, field_num, WIRE_LEN);
            var nested = std.ArrayList(u8).empty;
            defer nested.deinit(allocator);
            try serializeMessage(allocator, &nested, value);
            try writeVarint(buffer, allocator, nested.items.len);
            try buffer.appendSlice(allocator, nested.items);
        },
        .@"enum" => {
            try writeTag(buffer, allocator, field_num, WIRE_VARINT);
            const tag_value = @intFromEnum(value);
            // Must sign-extend to 64-bit if signed, then bitcast to unsigned 64-bit
            // to produce the standard 10-byte protobuf varint for negative enums.
            const value64: u64 = if (comptime @typeInfo(@TypeOf(tag_value)).int.signedness == .signed)
                @bitCast(@as(i64, tag_value))
            else
                @intCast(tag_value);
            try writeVarint(buffer, allocator, value64);
        },
        .optional => {
            if (value) |present| {
                try serializeField(allocator, buffer, type_info.optional.child, field_num, present);
            }
        },
        else => @compileError("unsupported protobuf type: " ++ @typeName(T)),
    }
}

fn serializeScalar(
    allocator: std.mem.Allocator,
    buffer: *std.ArrayList(u8),
    comptime T: type,
    value: anytype,
) !void {
    const type_info = @typeInfo(T);
    switch (type_info) {
        .bool => try writeVarint(buffer, allocator, @intFromBool(value)),
        .int => try writeVarint(buffer, allocator, value),
        .float => |float_type_info| {
            if (float_type_info.bits == 32) {
                try writeFixed32(buffer, allocator, @bitCast(value));
            } else {
                try writeFixed64(buffer, allocator, @bitCast(value));
            }
        },
        .@"enum" => {
            const tag_value = @intFromEnum(value);
            const value64: u64 = if (comptime @typeInfo(@TypeOf(tag_value)).int.signedness == .signed)
                @bitCast(@as(i64, tag_value))
            else
                @intCast(tag_value);
            try writeVarint(buffer, allocator, value64);
        },
        else => @compileError("unsupported packed type: " ++ @typeName(T)),
    }
}

// ==================== Deserialization ====================

fn deserializeMessage(
    comptime T: type,
    allocator: std.mem.Allocator,
    input: []const u8,
) !T {
    const struct_info = @typeInfo(T).@"struct";
    var result: T = undefined;
    var fields_seen = [_]bool{false} ** struct_info.fields.len;

    // Temporary storage for repeated fields.
    var repeated_buffers: [struct_info.fields.len]std.ArrayList(u8) = undefined;
    inline for (0..struct_info.fields.len) |index| {
        repeated_buffers[index] = std.ArrayList(u8).empty;
    }
    defer inline for (0..struct_info.fields.len) |index| {
        repeated_buffers[index].deinit(allocator);
    };

    var position: usize = 0;
    while (position < input.len) {
        const tag_value_raw = readVarint(input, &position) orelse return error.UnexpectedToken;
        const field_num: u32 = @intCast(tag_value_raw >> 3);
        const wire_type: u3 = @intCast(tag_value_raw & 0x7);

        if (field_num == 0) return error.UnexpectedToken;

        var matched = false;
        inline for (struct_info.fields, 0..) |field, index| {
            const expected_num = common.effectiveProtobufFieldNumber(T, index);
            if (field_num == expected_num) {
                matched = true;
                try deserializeFieldValue(
                    T,
                    field.type,
                    allocator,
                    input,
                    &position,
                    wire_type,
                    &result,
                    field.name,
                    &fields_seen[index],
                    &repeated_buffers[index],
                );
            }
        }

        if (!matched) {
            try skipField(input, &position, wire_type);
        }
    }

    // Finalize repeated fields and apply defaults.
    inline for (struct_info.fields, 0..) |field, index| {
        const field_info = @typeInfo(field.type);
        const is_repeated = if (field_info == .pointer)
            if (field_info.pointer.size == .slice)
                field_info.pointer.child != u8
            else
                false
        else
            false;

        if (is_repeated) {
            if (repeated_buffers[index].items.len > 0) {
                const child_type = field_info.pointer.child;
                const child_type_info = @typeInfo(child_type);
                if (child_type_info == .@"struct") {
                    @field(result, field.name) = try finalizeRepeatedMessages(
                        child_type,
                        allocator,
                        repeated_buffers[index].items,
                    );
                } else {
                    @field(result, field.name) = try finalizePackedScalars(
                        child_type,
                        allocator,
                        repeated_buffers[index].items,
                    );
                }
                fields_seen[index] = true;
            }
        }
    }

    try common.fillMissingFields(T, &result, &fields_seen);
    return result;
}

fn deserializeFieldValue(
    comptime Parent: type,
    comptime T: type,
    allocator: std.mem.Allocator,
    input: []const u8,
    position: *usize,
    wire_type: u3,
    result: *Parent,
    comptime field_name: []const u8,
    seen: *bool,
    repeated_buffer: *std.ArrayList(u8),
) !void {
    const type_info = @typeInfo(T);
    switch (type_info) {
        .bool => {
            const raw = readVarint(input, position) orelse return error.UnexpectedToken;
            @field(result, field_name) = raw != 0;
            seen.* = true;
        },
        .int => |int_type_info| {
            const raw = readVarint(input, position) orelse return error.UnexpectedToken;
            if (int_type_info.signedness == .signed) {
                @field(result, field_name) = @truncate(zigzagDecode(raw));
            } else {
                @field(result, field_name) = @truncate(raw);
            }
            seen.* = true;
        },
        .float => |float_type_info| {
            if (float_type_info.bits == 32) {
                const bytes = readFixed32(input, position) orelse return error.UnexpectedToken;
                @field(result, field_name) = @bitCast(bytes);
                seen.* = true;
            } else {
                const bytes = readFixed64(input, position) orelse return error.UnexpectedToken;
                @field(result, field_name) = @bitCast(bytes);
                seen.* = true;
            }
        },
        .pointer => |pointer_type_info| {
            if (pointer_type_info.size == .slice) {
                if (pointer_type_info.child == u8) {
                    const length_value = readVarint(input, position) orelse return error.UnexpectedToken;
                    const length: usize = @intCast(length_value);
                    if (position.* + length > input.len) return error.UnexpectedToken;
                    @field(result, field_name) = try allocator.dupe(u8, input[position.* .. position.* + length]);
                    position.* += length;
                    seen.* = true;
                } else {
                    // Repeated field: accumulate raw bytes for later finalization.
                    const length_value = readVarint(input, position) orelse return error.UnexpectedToken;
                    const length: usize = @intCast(length_value);
                    if (position.* + length > input.len) return error.UnexpectedToken;
                    const child_type_info = @typeInfo(pointer_type_info.child);
                    if (child_type_info == .@"struct") {
                        // Length-prefix each message for later parsing.
                        var length_buffer: [10]u8 = undefined;
                        const length_bytes = encodeVarint(&length_buffer, length);
                        try repeated_buffer.appendSlice(allocator, length_buffer[0..length_bytes]);
                    }
                    try repeated_buffer.appendSlice(allocator, input[position.* .. position.* + length]);
                    position.* += length;
                }
            }
        },
        .@"struct" => {
            const length_value = readVarint(input, position) orelse return error.UnexpectedToken;
            const length: usize = @intCast(length_value);
            if (position.* + length > input.len) return error.UnexpectedToken;
            const message_data = input[position.* .. position.* + length];
            @field(result, field_name) = try deserializeMessage(T, allocator, message_data);
            position.* += length;
            seen.* = true;
        },
        .@"enum" => {
            const raw = readVarint(input, position) orelse return error.UnexpectedToken;
            const enum_type_info = @typeInfo(T).@"enum";
            const tag_value: enum_type_info.tag_type = if (comptime (@typeInfo(enum_type_info.tag_type).int.signedness == .signed))
                @bitCast(@as(std.meta.Int(.unsigned, @typeInfo(enum_type_info.tag_type).int.bits), @truncate(raw)))
            else
                @intCast(raw);
            @field(result, field_name) = @enumFromInt(tag_value);
            seen.* = true;
        },
        .optional => {
            // Decode the inner type.
            const inner_type = type_info.optional.child;
            const inner_type_info = @typeInfo(inner_type);
            switch (inner_type_info) {
                .bool => {
                    const raw = readVarint(input, position) orelse return error.UnexpectedToken;
                    @field(result, field_name) = raw != 0;
                    seen.* = true;
                },
                .int => |int_type_info| {
                    const raw = readVarint(input, position) orelse return error.UnexpectedToken;
                    if (int_type_info.signedness == .signed) {
                        @field(result, field_name) = @truncate(zigzagDecode(raw));
                    } else {
                        @field(result, field_name) = @truncate(raw);
                    }
                    seen.* = true;
                },
                else => {
                    @field(result, field_name) = null;
                    seen.* = true;
                },
            }
        },
        else => {
            try skipField(input, position, wire_type);
        },
    }
}

fn finalizeRepeatedMessages(
    comptime T: type,
    allocator: std.mem.Allocator,
    data: []const u8,
) ![]const T {
    var list = std.ArrayList(T).empty;
    defer list.deinit(allocator);

    var position: usize = 0;
    while (position < data.len) {
        const length_value = readVarint(data, &position) orelse return error.UnexpectedToken;
        const length: usize = @intCast(length_value);
        if (position + length > data.len) return error.UnexpectedToken;
        const item = try deserializeMessage(T, allocator, data[position .. position + length]);
        try list.append(allocator, item);
        position += length;
    }
    return try list.toOwnedSlice(allocator);
}

fn finalizePackedScalars(
    comptime T: type,
    allocator: std.mem.Allocator,
    data: []const u8,
) ![]const T {
    var list = std.ArrayList(T).empty;
    defer list.deinit(allocator);

    const type_info = @typeInfo(T);
    var position: usize = 0;
    while (position < data.len) {
        switch (type_info) {
            .bool => {
                const raw = readVarint(data, &position) orelse return error.UnexpectedToken;
                try list.append(allocator, raw != 0);
            },
            .int => |int_type_info| {
                const raw = readVarint(data, &position) orelse return error.UnexpectedToken;
                if (int_type_info.signedness == .signed) {
                    try list.append(allocator, @truncate(zigzagDecode(raw)));
                } else {
                    try list.append(allocator, @truncate(raw));
                }
            },
            .float => |float_type_info| {
                if (float_type_info.bits == 32) {
                    const bytes = readFixed32(data, &position) orelse return error.UnexpectedToken;
                    try list.append(allocator, @bitCast(bytes));
                } else {
                    const bytes = readFixed64(data, &position) orelse return error.UnexpectedToken;
                    try list.append(allocator, @bitCast(bytes));
                }
            },
            .@"enum" => {
                const raw = readVarint(data, &position) orelse return error.UnexpectedToken;
                try list.append(allocator, @enumFromInt(raw));
            },
            else => @compileError("unsupported packed type: " ++ @typeName(T)),
        }
    }
    return try list.toOwnedSlice(allocator);
}

fn skipField(input: []const u8, position: *usize, wire_type: u3) !void {
    switch (wire_type) {
        WIRE_VARINT => _ = readVarint(input, position),
        WIRE_I64 => position.* = @min(position.* + 8, input.len),
        WIRE_LEN => {
            if (readVarint(input, position)) |length_value| {
                const length: usize = @intCast(length_value);
                position.* = @min(position.* + length, input.len);
            }
        },
        WIRE_I32 => position.* = @min(position.* + 4, input.len),
        else => return error.UnsupportedWireType,
    }
}

// ==================== Encoding Primitives ====================

fn writeTag(
    buffer: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    field_num: u32,
    wire_type: u3,
) !void {
    assert(field_num > 0);
    const tag: u64 = (@as(u64, field_num) << 3) | wire_type;
    try writeVarint(buffer, allocator, tag);
}

fn writeVarint(
    buffer: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    value: anytype,
) !void {
    const T = @TypeOf(value);
    var remaining: u64 = undefined;
    if (comptime (@typeInfo(T) == .int and @typeInfo(T).int.signedness == .signed) or @typeInfo(T) == .comptime_int) {
        remaining = zigzagEncode(value);
    } else {
        remaining = @intCast(value);
    }
    while (remaining > 0x7f) {
        try buffer.append(allocator, @intCast((remaining & 0x7f) | 0x80));
        remaining >>= 7;
    }
    try buffer.append(allocator, @intCast(remaining));
}

fn writeFixed32(
    buffer: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    value: u32,
) !void {
    const bytes: [4]u8 = @bitCast(std.mem.nativeToLittle(u32, value));
    try buffer.appendSlice(allocator, &bytes);
}

fn writeFixed64(
    buffer: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    value: u64,
) !void {
    const bytes: [8]u8 = @bitCast(std.mem.nativeToLittle(u64, value));
    try buffer.appendSlice(allocator, &bytes);
}

fn encodeVarint(buffer: *[10]u8, value: anytype) usize {
    var remaining: u64 = @intCast(value);
    var index: usize = 0;
    while (remaining > 0x7f) {
        buffer[index] = @intCast((remaining & 0x7f) | 0x80);
        remaining >>= 7;
        index += 1;
    }
    buffer[index] = @intCast(remaining);
    return index + 1;
}

// ==================== Decoding Primitives ====================

fn readVarint(input: []const u8, position: *usize) ?u64 {
    var result: u64 = 0;
    var shift: u6 = 0;
    while (position.* < input.len) {
        const byte = input[position.*];
        position.* += 1;
        result |= @as(u64, byte & 0x7f) << shift;
        if (byte & 0x80 == 0) return result;
        shift +|= 7;
        if (shift > 63) return null;
    }
    return null;
}

fn readFixed32(input: []const u8, position: *usize) ?u32 {
    if (position.* + 4 > input.len) return null;
    const bytes = input[position.*..][0..4];
    position.* += 4;
    return std.mem.littleToNative(u32, @bitCast(bytes.*));
}

fn readFixed64(input: []const u8, position: *usize) ?u64 {
    if (position.* + 8 > input.len) return null;
    const bytes = input[position.*..][0..8];
    position.* += 8;
    return std.mem.littleToNative(u64, @bitCast(bytes.*));
}

// ==================== ZigZag Encoding ====================

fn zigzagEncode(value: anytype) std.meta.Int(.unsigned, @typeInfo(@TypeOf(value)).int.bits) {
    const T = @TypeOf(value);
    const UnsignedType = std.meta.Int(.unsigned, @typeInfo(T).int.bits);
    const value_unsigned: UnsignedType = @bitCast(value);
    const shift = @typeInfo(T).int.bits - 1;
    return (value_unsigned << 1) ^ @as(UnsignedType, @bitCast(value >> @intCast(shift)));
}

fn zigzagDecode(value: anytype) std.meta.Int(.signed, @typeInfo(@TypeOf(value)).int.bits) {
    const UnsignedType = @TypeOf(value);
    return @bitCast((value >> 1) ^ (-%@as(UnsignedType, value & 1)));
}

// ==================== Tests ====================

test "roundtrip: flat struct" {
    const Data = struct { name: []const u8, age: u32, active: bool };
    const serde = Serde(Data);
    const original = Data{ .name = "alice", .age = 30, .active = true };

    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try serde.serialize(&writer, std.testing.allocator, original);

    var result = try serde.deserialize(std.testing.allocator, writer.buffered());
    defer result.deinit();

    try std.testing.expectEqualStrings("alice", result.value.name);
    try std.testing.expectEqual(@as(u32, 30), result.value.age);
    try std.testing.expectEqual(true, result.value.active);
}

test "roundtrip: nested struct" {
    const Inner = struct { host: []const u8, port: u32 };
    const Outer = struct { name: []const u8, server: Inner };
    const serde = Serde(Outer);
    const original = Outer{
        .name = "myapp",
        .server = .{ .host = "localhost", .port = 8080 },
    };

    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try serde.serialize(&writer, std.testing.allocator, original);

    var result = try serde.deserialize(std.testing.allocator, writer.buffered());
    defer result.deinit();

    try std.testing.expectEqualStrings("myapp", result.value.name);
    try std.testing.expectEqualStrings("localhost", result.value.server.host);
    try std.testing.expectEqual(@as(u32, 8080), result.value.server.port);
}

test "roundtrip: repeated scalars (packed)" {
    const Data = struct { scores: []const u32 };
    const serde = Serde(Data);
    const original = Data{ .scores = &.{ 100, 200, 300 } };

    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try serde.serialize(&writer, std.testing.allocator, original);

    var result = try serde.deserialize(std.testing.allocator, writer.buffered());
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 3), result.value.scores.len);
    try std.testing.expectEqual(@as(u32, 100), result.value.scores[0]);
    try std.testing.expectEqual(@as(u32, 200), result.value.scores[1]);
    try std.testing.expectEqual(@as(u32, 300), result.value.scores[2]);
}

test "roundtrip: repeated messages" {
    const Server = struct { host: []const u8, port: u32 };
    const Config = struct { servers: []const Server };
    const serde = Serde(Config);
    const original = Config{
        .servers = &.{
            .{ .host = "a.com", .port = 80 },
            .{ .host = "b.com", .port = 443 },
        },
    };

    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try serde.serialize(&writer, std.testing.allocator, original);

    var result = try serde.deserialize(std.testing.allocator, writer.buffered());
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.value.servers.len);
    try std.testing.expectEqualStrings("a.com", result.value.servers[0].host);
    try std.testing.expectEqual(@as(u32, 80), result.value.servers[0].port);
    try std.testing.expectEqualStrings("b.com", result.value.servers[1].host);
    try std.testing.expectEqual(@as(u32, 443), result.value.servers[1].port);
}

test "roundtrip: enum" {
    const Status = enum(u32) { active = 0, inactive = 1 };
    const Data = struct { status: Status };
    const serde = Serde(Data);
    const original = Data{ .status = .inactive };

    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try serde.serialize(&writer, std.testing.allocator, original);

    var result = try serde.deserialize(std.testing.allocator, writer.buffered());
    defer result.deinit();

    try std.testing.expectEqual(Status.inactive, result.value.status);
}

test "roundtrip: signed integers (zigzag)" {
    const Data = struct { value: i32 };
    const serde = Serde(Data);
    const original = Data{ .value = -42 };

    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try serde.serialize(&writer, std.testing.allocator, original);

    var result = try serde.deserialize(std.testing.allocator, writer.buffered());
    defer result.deinit();

    try std.testing.expectEqual(@as(i32, -42), result.value.value);
}

test "roundtrip: float and double" {
    const Data = struct { f: f32, d: f64 };
    const serde = Serde(Data);
    const original = Data{ .f = 3.14, .d = 2.71828 };

    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try serde.serialize(&writer, std.testing.allocator, original);

    var result = try serde.deserialize(std.testing.allocator, writer.buffered());
    defer result.deinit();

    try std.testing.expectApproxEqAbs(@as(f32, 3.14), result.value.f, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 2.71828), result.value.d, 0.00001);
}

test "roundtrip: optional field" {
    const Data = struct { name: []const u8, port: ?u32 = null };
    const serde = Serde(Data);
    const original = Data{ .name = "test", .port = 8080 };

    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try serde.serialize(&writer, std.testing.allocator, original);

    var result = try serde.deserialize(std.testing.allocator, writer.buffered());
    defer result.deinit();

    try std.testing.expectEqualStrings("test", result.value.name);
    try std.testing.expectEqual(@as(?u32, 8080), result.value.port);
}

test "roundtrip: optional field null" {
    const Data = struct { name: []const u8, port: ?u32 = null };
    const serde = Serde(Data);
    const original = Data{ .name = "test", .port = null };

    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try serde.serialize(&writer, std.testing.allocator, original);

    var result = try serde.deserialize(std.testing.allocator, writer.buffered());
    defer result.deinit();

    try std.testing.expectEqualStrings("test", result.value.name);
    try std.testing.expectEqual(@as(?u32, null), result.value.port);
}

test "error: empty input missing fields" {
    const Data = struct { name: []const u8 };
    const serde = Serde(Data);
    const result = serde.deserialize(std.testing.allocator, "");
    try std.testing.expectError(error.MissingField, result);
}

test "roundtrip: custom field numbers" {
    const Data = struct {
        name: []const u8,
        port: u32,
        flag: bool,

        pub const serde_fields = .{
            .name = .{ .protobuf = .{ .field_number = 3 } },
            .port = .{ .protobuf = .{ .field_number = 1 } },
            .flag = .{ .protobuf = .{ .field_number = 2 } },
        };
    };
    const serde = Serde(Data);
    const original = Data{ .name = "test", .port = 9090, .flag = true };

    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try serde.serialize(&writer, std.testing.allocator, original);

    var result = try serde.deserialize(std.testing.allocator, writer.buffered());
    defer result.deinit();

    try std.testing.expectEqualStrings("test", result.value.name);
    try std.testing.expectEqual(@as(u32, 9090), result.value.port);
    try std.testing.expectEqual(true, result.value.flag);
}

test "roundtrip: partial field numbers with defaults" {
    const Data = struct {
        a: u32,
        b: u32 = 0,
        c: []const u8,

        pub const serde_fields = .{
            .a = .{ .protobuf = .{ .field_number = 1 } },
            .b = .{ .protobuf = .{ .field_number = 5 } },
            .c = .{ .protobuf = .{ .field_number = 3 } },
        };
    };
    const serde = Serde(Data);
    const original = Data{ .a = 42, .b = 0, .c = "hello" };

    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try serde.serialize(&writer, std.testing.allocator, original);

    var result = try serde.deserialize(std.testing.allocator, writer.buffered());
    defer result.deinit();

    try std.testing.expectEqual(@as(u32, 42), result.value.a);
    try std.testing.expectEqual(@as(u32, 0), result.value.b);
    try std.testing.expectEqualStrings("hello", result.value.c);
}

test "roundtrip: large u64" {
    const Data = struct { val: u64 };
    const serde = Serde(Data);
    const original = Data{ .val = 0xFFFFFFFFFFFFFFFF };

    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try serde.serialize(&writer, std.testing.allocator, original);

    var result = try serde.deserialize(std.testing.allocator, writer.buffered());
    defer result.deinit();

    try std.testing.expectEqual(original.val, result.value.val);
}

test "roundtrip: negative enum varint" {
    const Status = enum(i32) { active = -1, inactive = 1 };
    const Data = struct { status: Status };
    const serde = Serde(Data);
    const original = Data{ .status = .active };

    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try serde.serialize(&writer, std.testing.allocator, original);

    // Standard protobuf: negative enum values are encoded as 10-byte varints.
    try std.testing.expectEqual(@as(usize, 11), writer.buffered().len); // 1 byte tag + 10 bytes varint.

    var result = try serde.deserialize(std.testing.allocator, writer.buffered());
    defer result.deinit();

    try std.testing.expectEqual(original.status, result.value.status);
}

test "roundtrip: i8 zigzag" {
    const Data = struct { val: i8 };
    const serde = Serde(Data);
    const original = Data{ .val = -5 };

    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try serde.serialize(&writer, std.testing.allocator, original);

    // ZigZag: -5 -> 9. Varint for 9 is 1 byte. Tag is 1 byte.
    try std.testing.expectEqual(@as(usize, 2), writer.buffered().len);

    var result = try serde.deserialize(std.testing.allocator, writer.buffered());
    defer result.deinit();

    try std.testing.expectEqual(original.val, result.value.val);
}

test "roundtrip: u8 varint" {
    const Data = struct { val: u8 };
    const serde = Serde(Data);
    const original = Data{ .val = 200 };

    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try serde.serialize(&writer, std.testing.allocator, original);

    // 200 -> 2 bytes varint. Tag 1 byte.
    try std.testing.expectEqual(@as(usize, 3), writer.buffered().len);

    var result = try serde.deserialize(std.testing.allocator, writer.buffered());
    defer result.deinit();

    try std.testing.expectEqual(original.val, result.value.val);
}

test "roundtrip: negative i32 varint" {
    const Data = struct { val: i32 };
    const serde = Serde(Data);
    const original = Data{ .val = -1 };

    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try serde.serialize(&writer, std.testing.allocator, original);

    // Protobuf negative numbers using ZigZag encoding take fewer bytes.
    // -1 becomes 1 after ZigZag, so 1 byte tag + 1 byte varint = 2 bytes.
    try std.testing.expectEqual(@as(usize, 2), writer.buffered().len);

    var result = try serde.deserialize(std.testing.allocator, writer.buffered());
    defer result.deinit();

    try std.testing.expectEqual(original.val, result.value.val);
}
