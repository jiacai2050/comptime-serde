const std = @import("std");
const common = @import("common.zig");

const ProtoDefinition = union(enum) {
    message: MessageDefinition,
    enum_definition: EnumDefinition,
};

const MessageDefinition = struct {
    name: []const u8,
    fields: std.ArrayList(FieldDefinition),
    nested: std.ArrayList(ProtoDefinition),
};

const EnumDefinition = struct {
    name: []const u8,
    values: std.ArrayList(EnumValueDefinition),
};

const FieldDefinition = struct {
    name: []const u8,
    type_name: []const u8,
    field_number: u32,
    is_repeated: bool,
};

const EnumValueDefinition = struct {
    name: []const u8,
    number: u32,
};

/// Infers Zig struct definitions from protobuf .proto content.
/// Returns the generated source code as a string.
pub fn generate(allocator: std.mem.Allocator, content: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var definitions = std.ArrayList(ProtoDefinition).empty;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = stripComment(raw_line);
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0) continue;

        if (isSkippableLine(trimmed)) continue;

        if (std.mem.startsWith(u8, trimmed, "message ")) {
            const definition = try parseMessage(arena_alloc, &lines, trimmed);
            try definitions.append(arena_alloc, definition);
        } else if (std.mem.startsWith(u8, trimmed, "enum ")) {
            const definition = try parseEnum(arena_alloc, &lines, trimmed);
            try definitions.append(arena_alloc, definition);
        }
    }

    var flat = std.ArrayList(ProtoDefinition).empty;
    try flattenDefinitions(arena_alloc, definitions.items, &flat);

    return try renderDefinitions(allocator, arena_alloc, flat.items);
}

fn isSkippableLine(line: []const u8) bool {
    if (std.mem.startsWith(u8, line, "syntax ")) return true;
    if (std.mem.startsWith(u8, line, "package ")) return true;
    if (std.mem.startsWith(u8, line, "import ")) return true;
    if (std.mem.startsWith(u8, line, "option ")) return true;
    if (std.mem.startsWith(u8, line, "reserved ")) return true;
    return false;
}

fn stripComment(raw_line: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, raw_line, '/')) |slash_pos| {
        if (slash_pos + 1 < raw_line.len and raw_line[slash_pos + 1] == '/') {
            return raw_line[0..slash_pos];
        }
    }
    return raw_line;
}

fn extractNameFromDecl(line: []const u8, keyword: []const u8) ?[]const u8 {
    const after_keyword = std.mem.trim(u8, line[keyword.len..], " ");
    if (after_keyword.len == 0) return null;
    // Find the name before '{' or whitespace
    var end: usize = 0;
    while (end < after_keyword.len and after_keyword[end] != ' ' and after_keyword[end] != '{') {
        end += 1;
    }
    if (end == 0) return null;
    return std.mem.trim(u8, after_keyword[0..end], " ");
}

fn parseMessage(allocator: std.mem.Allocator, lines: *std.mem.SplitIterator(u8, .scalar), first_line: []const u8) !ProtoDefinition {
    const name = extractNameFromDecl(first_line, "message") orelse "UnnamedMessage";

    var fields = std.ArrayList(FieldDefinition).empty;
    var nested = std.ArrayList(ProtoDefinition).empty;

    // Handle single-line message: message Foo {}
    if (std.mem.indexOfScalar(u8, first_line, '}') != null) {
        return .{ .message = .{ .name = name, .fields = fields, .nested = nested } };
    }

    var brace_depth: u32 = 1;
    while (lines.next()) |raw_line| {
        const line = stripComment(raw_line);
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0) continue;

        // Count braces
        for (trimmed) |char| {
            if (char == '{') brace_depth += 1;
            if (char == '}') {
                brace_depth -= 1;
                if (brace_depth == 0) {
                    return .{ .message = .{ .name = name, .fields = fields, .nested = nested } };
                }
            }
        }

        // Check for nested message/enum.
        // The opening '{' was already counted above; the recursive call
        // consumes the closing '}', so decrement brace_depth to stay in sync.
        if (std.mem.startsWith(u8, trimmed, "message ")) {
            const nested_definition = try parseMessage(allocator, lines, trimmed);
            try nested.append(allocator, nested_definition);
            brace_depth -= 1;
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "enum ")) {
            const nested_definition = try parseEnum(allocator, lines, trimmed);
            try nested.append(allocator, nested_definition);
            brace_depth -= 1;
            continue;
        }

        // Skip reserved, oneof, map, etc.
        if (std.mem.startsWith(u8, trimmed, "reserved ")) continue;
        if (std.mem.startsWith(u8, trimmed, "oneof ")) continue;
        if (std.mem.startsWith(u8, trimmed, "map<")) continue;

        if (parseFieldLine(allocator, trimmed)) |field| {
            try fields.append(allocator, field);
        }
    }

    return .{ .message = .{ .name = name, .fields = fields, .nested = nested } };
}

fn parseEnum(allocator: std.mem.Allocator, lines: *std.mem.SplitIterator(u8, .scalar), first_line: []const u8) !ProtoDefinition {
    const name = extractNameFromDecl(first_line, "enum") orelse "UnnamedEnum";

    var values = std.ArrayList(EnumValueDefinition).empty;

    // Handle single-line enum: enum Foo {}
    if (std.mem.indexOfScalar(u8, first_line, '}') != null) {
        return .{ .enum_definition = .{ .name = name, .values = values } };
    }

    var brace_depth: u32 = 1;
    while (lines.next()) |raw_line| {
        const line = stripComment(raw_line);
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0) continue;

        for (trimmed) |char| {
            if (char == '{') brace_depth += 1;
            if (char == '}') {
                brace_depth -= 1;
                if (brace_depth == 0) {
                    return .{ .enum_definition = .{ .name = name, .values = values } };
                }
            }
        }

        if (parseEnumValueLine(allocator, trimmed)) |value| {
            try values.append(allocator, value);
        }
    }

    return .{ .enum_definition = .{ .name = name, .values = values } };
}

fn parseFieldLine(allocator: std.mem.Allocator, line: []const u8) ?FieldDefinition {
    // Tokenize on whitespace and structural characters so that
    // "string host=1;" and "string host = 1;" both parse correctly.
    var tokenizer = std.mem.tokenizeAny(u8, line, " \t=;[]{}");
    var tokens: [5][]const u8 = undefined;
    var count: usize = 0;

    while (tokenizer.next()) |token| {
        if (count >= 5) break;
        tokens[count] = token;
        count += 1;
    }

    if (count < 3) return null;

    var is_repeated = false;
    var type_offset: usize = 0;

    if (std.mem.eql(u8, tokens[0], "repeated")) {
        is_repeated = true;
        type_offset = 1;
    }

    if (type_offset + 2 >= count) return null;

    const proto_type = tokens[type_offset];
    const field_name = tokens[type_offset + 1];
    const number_str = tokens[type_offset + 2];

    const field_number = std.fmt.parseInt(u32, number_str, 10) catch return null;
    const zig_type = mapProtoType(allocator, proto_type, is_repeated) catch return null;

    return .{
        .name = field_name,
        .type_name = zig_type,
        .field_number = field_number,
        .is_repeated = is_repeated,
    };
}

fn parseEnumValueLine(allocator: std.mem.Allocator, line: []const u8) ?EnumValueDefinition {
    // Tokenize on whitespace and structural characters so that
    // "UNKNOWN=0;" and "UNKNOWN = 0;" both parse correctly.
    var tokenizer = std.mem.tokenizeAny(u8, line, " \t=;[]{}");
    var tokens: [3][]const u8 = undefined;
    var count: usize = 0;

    while (tokenizer.next()) |token| {
        if (count >= 3) break;
        tokens[count] = token;
        count += 1;
    }

    if (count < 2) return null;

    const value_name = tokens[0];
    const number_str = tokens[1];

    const number = std.fmt.parseInt(u32, number_str, 10) catch return null;
    const lowercase = toLowercase(allocator, value_name) catch return null;

    return .{
        .name = lowercase,
        .number = number,
    };
}

fn mapProtoType(allocator: std.mem.Allocator, proto_type: []const u8, is_repeated: bool) ![]const u8 {
    const base = mapScalarType(proto_type) orelse proto_type;
    if (is_repeated) {
        return try std.fmt.allocPrint(allocator, "[]const {s}", .{base});
    }
    return base;
}

fn mapScalarType(proto_type: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, proto_type, "string")) return "[]const u8";
    if (std.mem.eql(u8, proto_type, "bytes")) return "[]const u8";
    if (std.mem.eql(u8, proto_type, "bool")) return "bool";
    if (std.mem.eql(u8, proto_type, "int32")) return "i32";
    if (std.mem.eql(u8, proto_type, "sint32")) return "i32";
    if (std.mem.eql(u8, proto_type, "sfixed32")) return "i32";
    if (std.mem.eql(u8, proto_type, "int64")) return "i64";
    if (std.mem.eql(u8, proto_type, "sint64")) return "i64";
    if (std.mem.eql(u8, proto_type, "sfixed64")) return "i64";
    if (std.mem.eql(u8, proto_type, "uint32")) return "u32";
    if (std.mem.eql(u8, proto_type, "fixed32")) return "u32";
    if (std.mem.eql(u8, proto_type, "uint64")) return "u64";
    if (std.mem.eql(u8, proto_type, "fixed64")) return "u64";
    if (std.mem.eql(u8, proto_type, "float")) return "f32";
    if (std.mem.eql(u8, proto_type, "double")) return "f64";
    return null;
}

fn flattenDefinitions(allocator: std.mem.Allocator, definitions: []const ProtoDefinition, output: *std.ArrayList(ProtoDefinition)) !void {
    for (definitions) |definition| {
        switch (definition) {
            .message => |message| {
                // Hoist nested definitions before the parent
                try flattenDefinitions(allocator, message.nested.items, output);
                try output.append(allocator, .{ .message = .{
                    .name = message.name,
                    .fields = message.fields,
                    .nested = std.ArrayList(ProtoDefinition).empty,
                } });
            },
            .enum_definition => {
                try output.append(allocator, definition);
            },
        }
    }
}

fn renderDefinitions(caller_alloc: std.mem.Allocator, arena_alloc: std.mem.Allocator, definitions: []const ProtoDefinition) ![]const u8 {
    var output = std.ArrayList(u8).empty;

    for (definitions) |definition| {
        switch (definition) {
            .message => |message| try renderMessage(arena_alloc, &output, message),
            .enum_definition => |enum_definition| try renderEnum(arena_alloc, &output, enum_definition),
        }
    }

    while (output.items.len > 0 and output.items[output.items.len - 1] == '\n') {
        output.items.len -= 1;
    }
    try output.append(arena_alloc, '\n');

    return try caller_alloc.dupe(u8, output.items);
}

fn renderMessage(arena_alloc: std.mem.Allocator, output: *std.ArrayList(u8), message: MessageDefinition) !void {
    const formatted_name = try common.formatName(arena_alloc, message.name);
    const header = try std.fmt.allocPrint(arena_alloc, "const {s} = struct {{\n", .{formatted_name});
    try output.appendSlice(arena_alloc, header);

    for (message.fields.items) |field| {
        const formatted_field = try common.formatName(arena_alloc, field.name);
        const line = try std.fmt.allocPrint(arena_alloc, "    {s}: {s},\n", .{ formatted_field, field.type_name });
        try output.appendSlice(arena_alloc, line);
    }

    // Render serde_fields with protobuf field numbers
    if (message.fields.items.len == 0) {
        try output.appendSlice(arena_alloc, "    pub const serde_fields = .{};\n");
    } else {
        try output.appendSlice(arena_alloc, "    pub const serde_fields = .{\n");
        for (message.fields.items) |field| {
            const formatted_field = try common.formatName(arena_alloc, field.name);
            const entry = try std.fmt.allocPrint(
                arena_alloc,
                "        .{s} = .{{ .protobuf = .{{ .field_number = {d} }} }},\n",
                .{ formatted_field, field.field_number },
            );
            try output.appendSlice(arena_alloc, entry);
        }
        try output.appendSlice(arena_alloc, "    };\n");
    }
    try output.appendSlice(arena_alloc, "};\n\n");
}

fn renderEnum(arena_alloc: std.mem.Allocator, output: *std.ArrayList(u8), enum_definition: EnumDefinition) !void {
    const formatted_name = try common.formatName(arena_alloc, enum_definition.name);
    const header = try std.fmt.allocPrint(arena_alloc, "const {s} = enum(u32) {{\n", .{formatted_name});
    try output.appendSlice(arena_alloc, header);

    for (enum_definition.values.items) |value| {
        const formatted_value = try common.formatName(arena_alloc, value.name);
        const line = try std.fmt.allocPrint(arena_alloc, "    {s} = {d},\n", .{ formatted_value, value.number });
        try output.appendSlice(arena_alloc, line);
    }
    try output.appendSlice(arena_alloc, "};\n\n");
}

fn toLowercase(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    const result = try allocator.alloc(u8, name.len);
    for (name, 0..) |char, index| {
        if (char >= 'A' and char <= 'Z') {
            result[index] = char + 32;
        } else {
            result[index] = char;
        }
    }
    return result;
}

// ==================== Tests ====================

test "infer flat message" {
    const output = try generate(std.testing.allocator,
        \\syntax = "proto3";
        \\
        \\message Server {
        \\  string host = 1;
        \\  uint32 port = 2;
        \\}
    );
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings(
        \\const Server = struct {
        \\    host: []const u8,
        \\    port: u32,
        \\    pub const serde_fields = .{
        \\        .host = .{ .protobuf = .{ .field_number = 1 } },
        \\        .port = .{ .protobuf = .{ .field_number = 2 } },
        \\    };
        \\};
        \\
    , output);
}

test "infer enum" {
    const output = try generate(std.testing.allocator,
        \\syntax = "proto3";
        \\
        \\enum Status {
        \\  UNKNOWN = 0;
        \\  ACTIVE = 1;
        \\  INACTIVE = 2;
        \\}
    );
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings(
        \\const Status = enum(u32) {
        \\    unknown = 0,
        \\    active = 1,
        \\    inactive = 2,
        \\};
        \\
    , output);
}

test "infer repeated field" {
    const output = try generate(std.testing.allocator,
        \\syntax = "proto3";
        \\
        \\message Config {
        \\  string name = 1;
        \\  repeated string tags = 2;
        \\  repeated uint32 ports = 3;
        \\}
    );
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings(
        \\const Config = struct {
        \\    name: []const u8,
        \\    tags: []const []const u8,
        \\    ports: []const u32,
        \\    pub const serde_fields = .{
        \\        .name = .{ .protobuf = .{ .field_number = 1 } },
        \\        .tags = .{ .protobuf = .{ .field_number = 2 } },
        \\        .ports = .{ .protobuf = .{ .field_number = 3 } },
        \\    };
        \\};
        \\
    , output);
}

test "infer nested message and enum references" {
    const output = try generate(std.testing.allocator,
        \\syntax = "proto3";
        \\
        \\message Server {
        \\  string host = 1;
        \\  uint32 port = 2;
        \\}
        \\
        \\enum Status {
        \\  UNKNOWN = 0;
        \\  ACTIVE = 1;
        \\}
        \\
        \\message Config {
        \\  string name = 1;
        \\  Server server = 2;
        \\  Status status = 3;
        \\}
    );
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings(
        \\const Server = struct {
        \\    host: []const u8,
        \\    port: u32,
        \\    pub const serde_fields = .{
        \\        .host = .{ .protobuf = .{ .field_number = 1 } },
        \\        .port = .{ .protobuf = .{ .field_number = 2 } },
        \\    };
        \\};
        \\
        \\const Status = enum(u32) {
        \\    unknown = 0,
        \\    active = 1,
        \\};
        \\
        \\const Config = struct {
        \\    name: []const u8,
        \\    server: Server,
        \\    status: Status,
        \\    pub const serde_fields = .{
        \\        .name = .{ .protobuf = .{ .field_number = 1 } },
        \\        .server = .{ .protobuf = .{ .field_number = 2 } },
        \\        .status = .{ .protobuf = .{ .field_number = 3 } },
        \\    };
        \\};
        \\
    , output);
}

test "skip comments" {
    const output = try generate(std.testing.allocator,
        \\// This is a proto file
        \\syntax = "proto3";
        \\
        \\message Foo {
        \\  // Name field
        \\  string name = 1;
        \\  uint32 value = 2; // inline comment
        \\}
    );
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings(
        \\const Foo = struct {
        \\    name: []const u8,
        \\    value: u32,
        \\    pub const serde_fields = .{
        \\        .name = .{ .protobuf = .{ .field_number = 1 } },
        \\        .value = .{ .protobuf = .{ .field_number = 2 } },
        \\    };
        \\};
        \\
    , output);
}

test "nested message hoisted before parent" {
    const output = try generate(std.testing.allocator,
        \\syntax = "proto3";
        \\
        \\message Outer {
        \\  message Inner {
        \\    string name = 1;
        \\  }
        \\  Inner inner = 1;
        \\}
    );
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings(
        \\const Inner = struct {
        \\    name: []const u8,
        \\    pub const serde_fields = .{
        \\        .name = .{ .protobuf = .{ .field_number = 1 } },
        \\    };
        \\};
        \\
        \\const Outer = struct {
        \\    inner: Inner,
        \\    pub const serde_fields = .{
        \\        .inner = .{ .protobuf = .{ .field_number = 1 } },
        \\    };
        \\};
        \\
    , output);
}

test "nested message with sibling field and nested enum" {
    const output = try generate(std.testing.allocator,
        \\syntax = "proto3";
        \\
        \\message Outer {
        \\  message Inner {
        \\    string name = 1;
        \\  }
        \\  Inner inner = 1;
        \\  enum Kind {
        \\    DEFAULT = 0;
        \\    CUSTOM = 1;
        \\  }
        \\  Kind kind = 2;
        \\}
    );
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings(
        \\const Inner = struct {
        \\    name: []const u8,
        \\    pub const serde_fields = .{
        \\        .name = .{ .protobuf = .{ .field_number = 1 } },
        \\    };
        \\};
        \\
        \\const Kind = enum(u32) {
        \\    default = 0,
        \\    custom = 1,
        \\};
        \\
        \\const Outer = struct {
        \\    inner: Inner,
        \\    kind: Kind,
        \\    pub const serde_fields = .{
        \\        .inner = .{ .protobuf = .{ .field_number = 1 } },
        \\        .kind = .{ .protobuf = .{ .field_number = 2 } },
        \\    };
        \\};
        \\
    , output);
}

test "nested message does not consume following top-level definition" {
    const output = try generate(std.testing.allocator,
        \\syntax = "proto3";
        \\
        \\message Outer {
        \\  message Inner {
        \\    string name = 1;
        \\  }
        \\  string after = 1;
        \\}
        \\
        \\enum Standalone {
        \\  ZERO = 0;
        \\  ONE = 1;
        \\}
    );
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings(
        \\const Inner = struct {
        \\    name: []const u8,
        \\    pub const serde_fields = .{
        \\        .name = .{ .protobuf = .{ .field_number = 1 } },
        \\    };
        \\};
        \\
        \\const Outer = struct {
        \\    after: []const u8,
        \\    pub const serde_fields = .{
        \\        .after = .{ .protobuf = .{ .field_number = 1 } },
        \\    };
        \\};
        \\
        \\const Standalone = enum(u32) {
        \\    zero = 0,
        \\    one = 1,
        \\};
        \\
    , output);
}

test "all scalar types" {
    const output = try generate(std.testing.allocator,
        \\syntax = "proto3";
        \\
        \\message AllTypes {
        \\  string s = 1;
        \\  bytes b = 2;
        \\  bool flag = 3;
        \\  int32 i32 = 4;
        \\  sint32 si32 = 5;
        \\  sfixed32 sf32 = 6;
        \\  int64 i64 = 7;
        \\  sint64 si64 = 8;
        \\  sfixed64 sf64 = 9;
        \\  uint32 u32 = 10;
        \\  fixed32 f32_ = 11;
        \\  uint64 u64 = 12;
        \\  fixed64 f64_ = 13;
        \\  float f = 14;
        \\  double d = 15;
        \\}
    );
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings(
        \\const AllTypes = struct {
        \\    s: []const u8,
        \\    b: []const u8,
        \\    flag: bool,
        \\    i32: i32,
        \\    si32: i32,
        \\    sf32: i32,
        \\    i64: i64,
        \\    si64: i64,
        \\    sf64: i64,
        \\    u32: u32,
        \\    f32_: u32,
        \\    u64: u64,
        \\    f64_: u64,
        \\    f: f32,
        \\    d: f64,
        \\    pub const serde_fields = .{
        \\        .s = .{ .protobuf = .{ .field_number = 1 } },
        \\        .b = .{ .protobuf = .{ .field_number = 2 } },
        \\        .flag = .{ .protobuf = .{ .field_number = 3 } },
        \\        .i32 = .{ .protobuf = .{ .field_number = 4 } },
        \\        .si32 = .{ .protobuf = .{ .field_number = 5 } },
        \\        .sf32 = .{ .protobuf = .{ .field_number = 6 } },
        \\        .i64 = .{ .protobuf = .{ .field_number = 7 } },
        \\        .si64 = .{ .protobuf = .{ .field_number = 8 } },
        \\        .sf64 = .{ .protobuf = .{ .field_number = 9 } },
        \\        .u32 = .{ .protobuf = .{ .field_number = 10 } },
        \\        .f32_ = .{ .protobuf = .{ .field_number = 11 } },
        \\        .u64 = .{ .protobuf = .{ .field_number = 12 } },
        \\        .f64_ = .{ .protobuf = .{ .field_number = 13 } },
        \\        .f = .{ .protobuf = .{ .field_number = 14 } },
        \\        .d = .{ .protobuf = .{ .field_number = 15 } },
        \\    };
        \\};
        \\
    , output);
}

test "empty message" {
    const output = try generate(std.testing.allocator,
        \\syntax = "proto3";
        \\
        \\message Empty {}
    );
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings(
        \\const Empty = struct {
        \\    pub const serde_fields = .{};
        \\};
        \\
    , output);
}

test "non-sequential field numbers" {
    const output = try generate(std.testing.allocator,
        \\syntax = "proto3";
        \\
        \\message Sparse {
        \\  string name = 1;
        \\  uint32 value = 5;
        \\  bool flag = 10;
        \\}
    );
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings(
        \\const Sparse = struct {
        \\    name: []const u8,
        \\    value: u32,
        \\    flag: bool,
        \\    pub const serde_fields = .{
        \\        .name = .{ .protobuf = .{ .field_number = 1 } },
        \\        .value = .{ .protobuf = .{ .field_number = 5 } },
        \\        .flag = .{ .protobuf = .{ .field_number = 10 } },
        \\    };
        \\};
        \\
    , output);
}

test "enum values lowercased" {
    const output = try generate(std.testing.allocator,
        \\syntax = "proto3";
        \\
        \\enum State {
        \\  STATE_UNKNOWN = 0;
        \\  STATE_ACTIVE = 1;
        \\  SOME_VALUE = 2;
        \\}
    );
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings(
        \\const State = enum(u32) {
        \\    state_unknown = 0,
        \\    state_active = 1,
        \\    some_value = 2,
        \\};
        \\
    , output);
}

test "compact field syntax (no spaces around =)" {
    const output = try generate(std.testing.allocator,
        \\syntax = "proto3";
        \\
        \\message Compact {
        \\  string name=1;
        \\  uint32 port=2;
        \\  bool active=3;
        \\}
    );
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings(
        \\const Compact = struct {
        \\    name: []const u8,
        \\    port: u32,
        \\    active: bool,
        \\    pub const serde_fields = .{
        \\        .name = .{ .protobuf = .{ .field_number = 1 } },
        \\        .port = .{ .protobuf = .{ .field_number = 2 } },
        \\        .active = .{ .protobuf = .{ .field_number = 3 } },
        \\    };
        \\};
        \\
    , output);
}

test "compact enum syntax (no spaces around =)" {
    const output = try generate(std.testing.allocator,
        \\syntax = "proto3";
        \\
        \\enum State {
        \\  UNKNOWN=0;
        \\  ACTIVE=1;
        \\  INACTIVE=2;
        \\}
    );
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings(
        \\const State = enum(u32) {
        \\    unknown = 0,
        \\    active = 1,
        \\    inactive = 2,
        \\};
        \\
    , output);
}

test "repeated field with bracket options" {
    const output = try generate(std.testing.allocator,
        \\syntax = "proto3";
        \\
        \\message Packed {
        \\  repeated uint32 values = 1 [packed = true];
        \\}
    );
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings(
        \\const Packed = struct {
        \\    values: []const u32,
        \\    pub const serde_fields = .{
        \\        .values = .{ .protobuf = .{ .field_number = 1 } },
        \\    };
        \\};
        \\
    , output);
}
