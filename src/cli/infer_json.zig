const std = @import("std");
const common = @import("common.zig");
const StructDef = common.StructDef;
const FieldDef = common.FieldDef;

/// Infers Zig struct definitions from JSON content.
/// Returns the generated source code as a string.
pub fn generate(allocator: std.mem.Allocator, content: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const parsed = try std.json.parseFromSlice(std.json.Value, arena_alloc, content, .{});

    var structs = std.ArrayList(StructDef).empty;
    try inferObject(arena_alloc, parsed.value, "Root", &structs);

    return try common.renderStructs(allocator, arena_alloc, structs.items);
}

fn inferObject(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    name: []const u8,
    structs: *std.ArrayList(StructDef),
) !void {
    const object = switch (value) {
        .object => |obj| obj,
        else => return,
    };

    var fields = std.ArrayList(FieldDef).empty;

    var iter = object.iterator();
    while (iter.next()) |entry| {
        const field_name = entry.key_ptr.*;
        const field_value = entry.value_ptr.*;
        const type_name = try inferType(allocator, field_value, field_name, structs);
        try fields.append(allocator, .{ .name = field_name, .type_name = type_name });
    }

    try structs.append(allocator, .{
        .name = name,
        .fields = fields,
    });
}

const InferError = std.mem.Allocator.Error;

fn inferType(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    field_name: []const u8,
    structs: *std.ArrayList(StructDef),
) InferError![]const u8 {
    return switch (value) {
        .bool => "bool",
        .integer => "i64",
        .float => "f64",
        .string => "[]const u8",
        .null => "?[]const u8",
        .array => |array| try inferArrayType(allocator, array, field_name, structs),
        .object => {
            const struct_name = try common.capitalizeFirst(allocator, field_name);
            try inferObject(allocator, value, struct_name, structs);
            return struct_name;
        },
        .number_string => "[]const u8",
    };
}

fn inferArrayType(
    allocator: std.mem.Allocator,
    array: std.json.Array,
    field_name: []const u8,
    structs: *std.ArrayList(StructDef),
) InferError![]const u8 {
    if (array.items.len == 0) {
        return "[]const std.json.Value";
    }

    const first = array.items[0];
    const element_type = try inferType(allocator, first, field_name, structs);

    return try std.fmt.allocPrint(allocator, "[]const {s}", .{element_type});
}

// ==================== Tests ====================

test "infer flat struct" {
    const output = try generate(std.testing.allocator,
        \\{"name":"alice","age":30,"active":true}
    );
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings(
        \\const Root = struct {
        \\    name: []const u8,
        \\    age: i64,
        \\    active: bool,
        \\};
        \\
    , output);
}

test "infer nested struct" {
    const output = try generate(std.testing.allocator,
        \\{"server":{"host":"localhost","port":8080}}
    );
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings(
        \\const Server = struct {
        \\    host: []const u8,
        \\    port: i64,
        \\};
        \\
        \\const Root = struct {
        \\    server: Server,
        \\};
        \\
    , output);
}

test "infer array types" {
    const output = try generate(std.testing.allocator,
        \\{"tags":["web","api"],"scores":[1,2,3]}
    );
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings(
        \\const Root = struct {
        \\    tags: []const []const u8,
        \\    scores: []const i64,
        \\};
        \\
    , output);
}

test "infer null and float" {
    const output = try generate(std.testing.allocator,
        \\{"ratio":3.14,"optional":null}
    );
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings(
        \\const Root = struct {
        \\    ratio: f64,
        \\    optional: ?[]const u8,
        \\};
        \\
    , output);
}

test "infer special field names" {
    const output = try generate(std.testing.allocator,
        \\{"user-name":"alice","2fast":true}
    );
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings(
        \\const Root = struct {
        \\    @"user-name": []const u8,
        \\    @"2fast": bool,
        \\};
        \\
    , output);
}

test "infer keyword field names" {
    const output = try generate(std.testing.allocator,
        \\{"type":"server","error":false,"return":1}
    );
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings(
        \\const Root = struct {
        \\    type: []const u8,
        \\    @"error": bool,
        \\    @"return": i64,
        \\};
        \\
    , output);
}
