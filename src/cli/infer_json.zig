const std = @import("std");

const StructDef = struct {
    name: []const u8,
    fields: []const FieldDef,
};

const FieldDef = struct {
    name: []const u8,
    type_name: []const u8,
};

/// Infers Zig struct definitions from JSON content.
/// Returns the generated source code as a string.
pub fn generate(allocator: std.mem.Allocator, content: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const parsed = try std.json.parseFromSlice(std.json.Value, arena_alloc, content, .{});

    var structs = std.ArrayList(StructDef).empty;
    try inferObject(arena_alloc, parsed.value, "Root", &structs);

    var output = std.ArrayList(u8).empty;
    for (structs.items) |struct_def| {
        const capitalized = capitalizeFirst(arena_alloc, struct_def.name) catch struct_def.name;
        const formatted_name = formatName(arena_alloc, capitalized) catch capitalized;
        const header = try std.fmt.allocPrint(
            arena_alloc,
            "const {s} = struct {{\n",
            .{formatted_name},
        );
        try output.appendSlice(arena_alloc, header);

        for (struct_def.fields) |field| {
            const formatted_field = formatName(arena_alloc, field.name) catch field.name;
            const line = try std.fmt.allocPrint(
                arena_alloc,
                "    {s}: {s},\n",
                .{ formatted_field, field.type_name },
            );
            try output.appendSlice(arena_alloc, line);
        }
        try output.appendSlice(arena_alloc, "};\n\n");
    }

    while (output.items.len > 0 and output.items[output.items.len - 1] == '\n') {
        output.items.len -= 1;
    }
    try output.append(arena_alloc, '\n');

    return try allocator.dupe(u8, output.items);
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
    defer fields.deinit(allocator);

    var iter = object.iterator();
    while (iter.next()) |entry| {
        const field_name = entry.key_ptr.*;
        const field_value = entry.value_ptr.*;
        const type_name = try inferType(allocator, field_value, field_name, structs);
        try fields.append(allocator, .{ .name = field_name, .type_name = type_name });
    }

    try structs.append(allocator, .{
        .name = name,
        .fields = try fields.toOwnedSlice(allocator),
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
        .array => |arr| try inferArrayType(allocator, arr, field_name, structs),
        .object => {
            const struct_name = try capitalizeFirst(allocator, field_name);
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

fn needsQuoting(name: []const u8) bool {
    if (name.len == 0) return true;
    if (name[0] >= '0' and name[0] <= '9') return true;
    for (name) |char| {
        const is_alnum = (char >= 'a' and char <= 'z') or
            (char >= 'A' and char <= 'Z') or
            (char >= '0' and char <= '9') or
            char == '_';
        if (!is_alnum) return true;
    }
    return false;
}

fn formatName(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    if (needsQuoting(name)) {
        return try std.fmt.allocPrint(allocator, "@\"{s}\"", .{name});
    }
    return name;
}

fn capitalizeFirst(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    if (name.len == 0) return name;
    if (name[0] >= 'a' and name[0] <= 'z') {
        const result = try allocator.dupe(u8, name);
        result[0] -= 32;
        return result;
    }
    return name;
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
