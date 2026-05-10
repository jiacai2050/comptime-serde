const std = @import("std");
const common = @import("common.zig");
const Parsed = common.Parsed;

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
            var buf = std.ArrayList(u8).empty;
            defer buf.deinit(allocator);
            try serializeMessage(allocator, &buf, value);
            try writer.writeAll(buf.items);
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
    buf: *std.ArrayList(u8),
    value: anytype,
) !void {
    const T = @TypeOf(value);
    const struct_info = @typeInfo(T).@"struct";

    inline for (struct_info.fields, 0..) |field, index| {
        const options = common.fieldOptions(T, field.name);
        const field_num: u32 = if (options.protobuf) |protobuf_options| protobuf_options.field_number orelse index + 1 else @intCast(index + 1);
        const field_value = @field(value, field.name);
        try serializeField(allocator, buf, field.type, field_num, field_value);
    }
}

fn serializeField(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    comptime T: type,
    field_num: u32,
    value: anytype,
) !void {
    const info = @typeInfo(T);
    switch (info) {
        .bool => {
            try writeTag(buf, allocator, field_num, WIRE_VARINT);
            try writeVarint(buf, allocator, @intFromBool(value));
        },
        .int => |int_info| {
            if (int_info.bits <= 32 and int_info.signedness == .signed) {
                try writeTag(buf, allocator, field_num, WIRE_VARINT);
                try writeVarint(buf, allocator, zigzagEncode32(value));
            } else if (int_info.bits <= 32) {
                try writeTag(buf, allocator, field_num, WIRE_VARINT);
                try writeVarint(buf, allocator, value);
            } else if (int_info.signedness == .signed) {
                try writeTag(buf, allocator, field_num, WIRE_VARINT);
                try writeVarint(buf, allocator, zigzagEncode64(value));
            } else {
                try writeTag(buf, allocator, field_num, WIRE_VARINT);
                try writeVarint(buf, allocator, value);
            }
        },
        .float => |float_info| {
            if (float_info.bits == 32) {
                try writeTag(buf, allocator, field_num, WIRE_I32);
                try writeFixed32(buf, allocator, @bitCast(value));
            } else {
                try writeTag(buf, allocator, field_num, WIRE_I64);
                try writeFixed64(buf, allocator, @bitCast(value));
            }
        },
        .pointer => |pointer_info| {
            if (pointer_info.size == .slice and pointer_info.child == u8) {
                try writeTag(buf, allocator, field_num, WIRE_LEN);
                try writeVarint(buf, allocator, value.len);
                try buf.appendSlice(allocator, value);
            } else if (pointer_info.size == .slice) {
                const child_info = @typeInfo(pointer_info.child);
                if (child_info == .@"struct") {
                    for (value) |item| {
                        try writeTag(buf, allocator, field_num, WIRE_LEN);
                        var nested = std.ArrayList(u8).empty;
                        defer nested.deinit(allocator);
                        try serializeMessage(allocator, &nested, item);
                        try writeVarint(buf, allocator, nested.items.len);
                        try buf.appendSlice(allocator, nested.items);
                    }
                } else {
                    // Packed repeated scalars.
                    try writeTag(buf, allocator, field_num, WIRE_LEN);
                    var packed_buf = std.ArrayList(u8).empty;
                    defer packed_buf.deinit(allocator);
                    for (value) |item| {
                        try serializeScalar(allocator, &packed_buf, pointer_info.child, item);
                    }
                    try writeVarint(buf, allocator, packed_buf.items.len);
                    try buf.appendSlice(allocator, packed_buf.items);
                }
            }
        },
        .@"struct" => {
            try writeTag(buf, allocator, field_num, WIRE_LEN);
            var nested = std.ArrayList(u8).empty;
            defer nested.deinit(allocator);
            try serializeMessage(allocator, &nested, value);
            try writeVarint(buf, allocator, nested.items.len);
            try buf.appendSlice(allocator, nested.items);
        },
        .@"enum" => {
            try writeTag(buf, allocator, field_num, WIRE_VARINT);
            try writeVarint(buf, allocator, @intFromEnum(value));
        },
        .optional => {
            if (value) |present| {
                try serializeField(allocator, buf, info.optional.child, field_num, present);
            }
        },
        else => @compileError("unsupported protobuf type: " ++ @typeName(T)),
    }
}

fn serializeScalar(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    comptime T: type,
    value: anytype,
) !void {
    const info = @typeInfo(T);
    switch (info) {
        .bool => try writeVarint(buf, allocator, @intFromBool(value)),
        .int => |int_info| {
            if (int_info.signedness == .signed and int_info.bits <= 32) {
                try writeVarint(buf, allocator, zigzagEncode32(value));
            } else if (int_info.signedness == .signed) {
                try writeVarint(buf, allocator, zigzagEncode64(value));
            } else {
                try writeVarint(buf, allocator, value);
            }
        },
        .float => |float_info| {
            if (float_info.bits == 32) {
                try writeFixed32(buf, allocator, @bitCast(value));
            } else {
                try writeFixed64(buf, allocator, @bitCast(value));
            }
        },
        .@"enum" => try writeVarint(buf, allocator, @intFromEnum(value)),
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
    var repeated_bufs: [struct_info.fields.len]std.ArrayList(u8) = undefined;
    inline for (0..struct_info.fields.len) |i| {
        repeated_bufs[i] = std.ArrayList(u8).empty;
    }
    defer inline for (0..struct_info.fields.len) |i| {
        repeated_bufs[i].deinit(allocator);
    };

    var pos: usize = 0;
    while (pos < input.len) {
        const tag_value = readVarint(input, &pos) orelse return error.UnexpectedToken;
        const field_num: u32 = @intCast(tag_value >> 3);
        const wire_type: u3 = @intCast(tag_value & 0x7);

        if (field_num == 0) return error.UnexpectedToken;

        var matched = false;
        inline for (struct_info.fields, 0..) |field, index| {
            const options = common.fieldOptions(T, field.name);
            const expected_num: u32 = if (options.protobuf) |protobuf_options| protobuf_options.field_number orelse index + 1 else @intCast(index + 1);
            if (field_num == expected_num) {
                matched = true;
                try deserializeFieldValue(
                    T,
                    field.type,
                    allocator,
                    input,
                    &pos,
                    wire_type,
                    &result,
                    field.name,
                    &fields_seen[index],
                    &repeated_bufs[index],
                );
            }
        }
        if (!matched) {
            skipField(input, &pos, wire_type);
        }
    }

    // Finalize repeated fields and apply defaults.
    inline for (struct_info.fields, 0..) |field, index| {
        const field_info = @typeInfo(field.type);
        const is_repeated = field_info == .pointer and
            field_info.pointer.size == .slice and
            field_info.pointer.child != u8;
        if (is_repeated) {
            if (repeated_bufs[index].items.len > 0) {
                const child_type = field_info.pointer.child;
                const child_info = @typeInfo(child_type);
                if (child_info == .@"struct") {
                    @field(result, field.name) = try finalizeRepeatedMessages(
                        child_type,
                        allocator,
                        repeated_bufs[index].items,
                    );
                } else {
                    @field(result, field.name) = try finalizePackedScalars(
                        child_type,
                        allocator,
                        repeated_bufs[index].items,
                    );
                }
                fields_seen[index] = true;
            }
        }
        if (!fields_seen[index]) {
            if (field.default_value_ptr) |default_ptr| {
                const ptr: *const field.type = @ptrCast(@alignCast(default_ptr));
                @field(result, field.name) = ptr.*;
            } else {
                return error.MissingField;
            }
        }
    }
    return result;
}

fn deserializeFieldValue(
    comptime Parent: type,
    comptime T: type,
    allocator: std.mem.Allocator,
    input: []const u8,
    pos: *usize,
    wire_type: u3,
    result: *Parent,
    comptime field_name: []const u8,
    seen: *bool,
    repeated_buf: *std.ArrayList(u8),
) !void {
    const info = @typeInfo(T);
    switch (info) {
        .bool => {
            const raw = readVarint(input, pos) orelse return error.UnexpectedToken;
            @field(result, field_name) = raw != 0;
            seen.* = true;
        },
        .int => |int_info| {
            const raw = readVarint(input, pos) orelse return error.UnexpectedToken;
            if (int_info.signedness == .signed and int_info.bits <= 32) {
                @field(result, field_name) = zigzagDecode32(@intCast(raw));
            } else if (int_info.signedness == .signed) {
                @field(result, field_name) = zigzagDecode64(raw);
            } else {
                @field(result, field_name) = @intCast(raw);
            }
            seen.* = true;
        },
        .float => |float_info| {
            if (float_info.bits == 32) {
                const bytes = readFixed32(input, pos) orelse return error.UnexpectedToken;
                @field(result, field_name) = @bitCast(bytes);
                seen.* = true;
            } else {
                const bytes = readFixed64(input, pos) orelse return error.UnexpectedToken;
                @field(result, field_name) = @bitCast(bytes);
                seen.* = true;
            }
        },
        .pointer => |pointer_info| {
            if (pointer_info.size == .slice and pointer_info.child == u8) {
                const len_val = readVarint(input, pos) orelse return error.UnexpectedToken;
                const len: usize = @intCast(len_val);
                if (pos.* + len > input.len) return error.UnexpectedToken;
                @field(result, field_name) = try allocator.dupe(u8, input[pos.* .. pos.* + len]);
                pos.* += len;
                seen.* = true;
            } else if (pointer_info.size == .slice) {
                // Repeated field: accumulate raw bytes for later finalization.
                const len_val = readVarint(input, pos) orelse return error.UnexpectedToken;
                const len: usize = @intCast(len_val);
                if (pos.* + len > input.len) return error.UnexpectedToken;
                const child_info = @typeInfo(pointer_info.child);
                if (child_info == .@"struct") {
                    // Length-prefix each message for later parsing.
                    var len_buf: [10]u8 = undefined;
                    const len_bytes = encodeVarint(&len_buf, len);
                    try repeated_buf.appendSlice(allocator, len_buf[0..len_bytes]);
                }
                try repeated_buf.appendSlice(allocator, input[pos.* .. pos.* + len]);
                pos.* += len;
            }
        },
        .@"struct" => {
            const len_val = readVarint(input, pos) orelse return error.UnexpectedToken;
            const len: usize = @intCast(len_val);
            if (pos.* + len > input.len) return error.UnexpectedToken;
            const msg_data = input[pos.* .. pos.* + len];
            @field(result, field_name) = try deserializeMessage(T, allocator, msg_data);
            pos.* += len;
            seen.* = true;
        },
        .@"enum" => {
            const raw = readVarint(input, pos) orelse return error.UnexpectedToken;
            @field(result, field_name) = @enumFromInt(raw);
            seen.* = true;
        },
        .optional => |optional_info| {
            _ = optional_info;
            // Decode the inner type.
            const inner_type = info.optional.child;
            const inner_info = @typeInfo(inner_type);
            switch (inner_info) {
                .bool => {
                    const raw = readVarint(input, pos) orelse return error.UnexpectedToken;
                    @field(result, field_name) = raw != 0;
                    seen.* = true;
                },
                .int => |int_info| {
                    const raw = readVarint(input, pos) orelse return error.UnexpectedToken;
                    if (int_info.signedness == .signed and int_info.bits <= 32) {
                        @field(result, field_name) = zigzagDecode32(@intCast(raw));
                    } else if (int_info.signedness == .signed) {
                        @field(result, field_name) = zigzagDecode64(raw);
                    } else {
                        @field(result, field_name) = @intCast(raw);
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
            skipField(input, pos, wire_type);
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

    var pos: usize = 0;
    while (pos < data.len) {
        const len_val = readVarint(data, &pos) orelse return error.UnexpectedToken;
        const len: usize = @intCast(len_val);
        if (pos + len > data.len) return error.UnexpectedToken;
        const item = try deserializeMessage(T, allocator, data[pos .. pos + len]);
        try list.append(allocator, item);
        pos += len;
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

    const info = @typeInfo(T);
    var pos: usize = 0;
    while (pos < data.len) {
        switch (info) {
            .bool => {
                const raw = readVarint(data, &pos) orelse return error.UnexpectedToken;
                try list.append(allocator, raw != 0);
            },
            .int => |int_info| {
                const raw = readVarint(data, &pos) orelse return error.UnexpectedToken;
                if (int_info.signedness == .signed and int_info.bits <= 32) {
                    try list.append(allocator, zigzagDecode32(@intCast(raw)));
                } else if (int_info.signedness == .signed) {
                    try list.append(allocator, zigzagDecode64(raw));
                } else {
                    try list.append(allocator, @intCast(raw));
                }
            },
            .float => |float_info| {
                if (float_info.bits == 32) {
                    const bytes = readFixed32(data, &pos) orelse return error.UnexpectedToken;
                    try list.append(allocator, @bitCast(bytes));
                } else {
                    const bytes = readFixed64(data, &pos) orelse return error.UnexpectedToken;
                    try list.append(allocator, @bitCast(bytes));
                }
            },
            .@"enum" => {
                const raw = readVarint(data, &pos) orelse return error.UnexpectedToken;
                try list.append(allocator, @enumFromInt(raw));
            },
            else => @compileError("unsupported packed type: " ++ @typeName(T)),
        }
    }
    return try list.toOwnedSlice(allocator);
}

fn skipField(input: []const u8, pos: *usize, wire_type: u3) void {
    switch (wire_type) {
        WIRE_VARINT => _ = readVarint(input, pos),
        WIRE_I64 => pos.* = @min(pos.* + 8, input.len),
        WIRE_LEN => {
            if (readVarint(input, pos)) |len_val| {
                const len: usize = @intCast(len_val);
                pos.* = @min(pos.* + len, input.len);
            }
        },
        WIRE_I32 => pos.* = @min(pos.* + 4, input.len),
        else => {},
    }
}

// ==================== Encoding Primitives ====================

fn writeTag(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    field_num: u32,
    wire_type: u3,
) !void {
    const tag: u64 = (@as(u64, field_num) << 3) | wire_type;
    try writeVarint(buf, allocator, tag);
}

fn writeVarint(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    value: anytype,
) !void {
    var remaining: u64 = @bitCast(@as(i64, @intCast(value)));
    while (remaining > 0x7f) {
        try buf.append(allocator, @intCast((remaining & 0x7f) | 0x80));
        remaining >>= 7;
    }
    try buf.append(allocator, @intCast(remaining));
}

fn writeFixed32(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    value: u32,
) !void {
    const bytes: [4]u8 = @bitCast(std.mem.nativeToLittle(u32, value));
    try buf.appendSlice(allocator, &bytes);
}

fn writeFixed64(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    value: u64,
) !void {
    const bytes: [8]u8 = @bitCast(std.mem.nativeToLittle(u64, value));
    try buf.appendSlice(allocator, &bytes);
}

fn encodeVarint(buf: *[10]u8, value: anytype) usize {
    var remaining: u64 = @intCast(value);
    var i: usize = 0;
    while (remaining > 0x7f) {
        buf[i] = @intCast((remaining & 0x7f) | 0x80);
        remaining >>= 7;
        i += 1;
    }
    buf[i] = @intCast(remaining);
    return i + 1;
}

// ==================== Decoding Primitives ====================

fn readVarint(input: []const u8, pos: *usize) ?u64 {
    var result: u64 = 0;
    var shift: u6 = 0;
    while (pos.* < input.len) {
        const byte = input[pos.*];
        pos.* += 1;
        result |= @as(u64, byte & 0x7f) << shift;
        if (byte & 0x80 == 0) return result;
        shift +|= 7;
        if (shift > 63) return null;
    }
    return null;
}

fn readFixed32(input: []const u8, pos: *usize) ?u32 {
    if (pos.* + 4 > input.len) return null;
    const bytes = input[pos.*..][0..4];
    pos.* += 4;
    return std.mem.littleToNative(u32, @bitCast(bytes.*));
}

fn readFixed64(input: []const u8, pos: *usize) ?u64 {
    if (pos.* + 8 > input.len) return null;
    const bytes = input[pos.*..][0..8];
    pos.* += 8;
    return std.mem.littleToNative(u64, @bitCast(bytes.*));
}

// ==================== ZigZag Encoding ====================

fn zigzagEncode32(value: i32) u32 {
    const v: u32 = @bitCast(value);
    return (v << 1) ^ @as(u32, @bitCast(value >> 31));
}

fn zigzagDecode32(value: u32) i32 {
    return @bitCast((value >> 1) ^ (-%@as(u32, value & 1)));
}

fn zigzagEncode64(value: i64) u64 {
    const v: u64 = @bitCast(value);
    return (v << 1) ^ @as(u64, @bitCast(value >> 63));
}

fn zigzagDecode64(value: u64) i64 {
    return @bitCast((value >> 1) ^ (-%@as(u64, value & 1)));
}

// ==================== Tests ====================

test "roundtrip: flat struct" {
    const Data = struct { name: []const u8, age: u32, active: bool };
    const serde = Serde(Data);
    const original = Data{ .name = "alice", .age = 30, .active = true };

    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
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

    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
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

    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
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

    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
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

    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try serde.serialize(&writer, std.testing.allocator, original);

    var result = try serde.deserialize(std.testing.allocator, writer.buffered());
    defer result.deinit();

    try std.testing.expectEqual(Status.inactive, result.value.status);
}

test "roundtrip: signed integers (zigzag)" {
    const Data = struct { value: i32 };
    const serde = Serde(Data);
    const original = Data{ .value = -42 };

    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try serde.serialize(&writer, std.testing.allocator, original);

    var result = try serde.deserialize(std.testing.allocator, writer.buffered());
    defer result.deinit();

    try std.testing.expectEqual(@as(i32, -42), result.value.value);
}

test "roundtrip: float and double" {
    const Data = struct { f: f32, d: f64 };
    const serde = Serde(Data);
    const original = Data{ .f = 3.14, .d = 2.71828 };

    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
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

    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
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

    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
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

    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
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

    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try serde.serialize(&writer, std.testing.allocator, original);

    var result = try serde.deserialize(std.testing.allocator, writer.buffered());
    defer result.deinit();

    try std.testing.expectEqual(@as(u32, 42), result.value.a);
    try std.testing.expectEqual(@as(u32, 0), result.value.b);
    try std.testing.expectEqualStrings("hello", result.value.c);
}
