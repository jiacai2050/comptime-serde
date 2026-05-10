const std = @import("std");
const common = @import("common.zig");
const StructDefinition = common.StructDefinition;
const FieldDefinition = common.FieldDefinition;

/// Infers Zig struct definitions from TOML content.
/// Returns the generated source code as a string.
pub fn generate(allocator: std.mem.Allocator, content: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var structs = std.ArrayList(StructDefinition).empty;
    var lines = std.mem.splitScalar(u8, content, '\n');
    try parseTopLevel(arena_alloc, &lines, "Root", &structs);

    return try common.renderStructs(allocator, arena_alloc, structs.items);
}

fn parseTopLevel(
    allocator: std.mem.Allocator,
    lines: *std.mem.SplitIterator(u8, .scalar),
    name: []const u8,
    structs: *std.ArrayList(StructDefinition),
) !void {
    var root_fields = std.ArrayList(FieldDefinition).empty;

    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \r");
        if (line.len == 0 or line[0] == '#') continue;

        if (line[0] == '[') {
            if (line.len > 2 and line[1] == '[') {
                // [[array]] — array of tables.
                const raw_name = extractName(line, 2, line.len - 2);
                const struct_name = try common.capitalizeFirst(allocator, raw_name);
                try parseTableInto(allocator, lines, struct_name, structs);
                if (!hasField(root_fields.items, raw_name)) {
                    const type_name = try std.fmt.allocPrint(
                        allocator,
                        "[]const {s}",
                        .{struct_name},
                    );
                    try root_fields.append(allocator, .{
                        .name = raw_name,
                        .type_name = type_name,
                    });
                }
            } else {
                // [table] — nested struct.
                const raw_name = extractName(line, 1, line.len - 1);
                const struct_name = try common.capitalizeFirst(allocator, raw_name);
                try parseTableInto(allocator, lines, struct_name, structs);
                if (!hasField(root_fields.items, raw_name)) {
                    try root_fields.append(allocator, .{
                        .name = raw_name,
                        .type_name = struct_name,
                    });
                }
            }
        } else {
            // Key-value pair.
            if (parseKv(line)) |kv| {
                try root_fields.append(allocator, .{
                    .name = kv.key,
                    .type_name = inferValueType(kv.value),
                });
            }
        }
    }

    try structs.append(allocator, .{ .name = name, .fields = root_fields });
}

fn parseTableInto(
    allocator: std.mem.Allocator,
    lines: *std.mem.SplitIterator(u8, .scalar),
    name: []const u8,
    structs: *std.ArrayList(StructDefinition),
) !void {
    // Check if we already have this struct defined (from a previous [[array]] entry).
    // Still need to consume the lines belonging to this section.
    for (structs.items) |s| {
        if (std.mem.eql(u8, s.name, name)) {
            skipSection(lines);
            return;
        }
    }

    var fields = std.ArrayList(FieldDefinition).empty;

    while (lines.peek()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \r");
        if (line.len == 0 or line[0] == '#') {
            _ = lines.next();
            continue;
        }
        if (line[0] == '[') break;

        _ = lines.next();
        if (parseKv(line)) |kv| {
            try fields.append(allocator, .{
                .name = kv.key,
                .type_name = inferValueType(kv.value),
            });
        }
    }

    try structs.append(allocator, .{ .name = name, .fields = fields });
}

fn skipSection(lines: *std.mem.SplitIterator(u8, .scalar)) void {
    while (lines.peek()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \r");
        if (line.len == 0 or line[0] == '#') {
            _ = lines.next();
            continue;
        }
        if (line[0] == '[') return;
        _ = lines.next();
    }
}

fn hasField(fields: []const FieldDefinition, name: []const u8) bool {
    for (fields) |f| {
        if (std.mem.eql(u8, f.name, name)) return true;
    }
    return false;
}

const Kv = struct { key: []const u8, value: []const u8 };

fn parseKv(line: []const u8) ?Kv {
    const eq_index = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    const key = std.mem.trim(u8, line[0..eq_index], " ");
    const value = std.mem.trim(u8, line[eq_index + 1 ..], " ");
    return .{ .key = key, .value = value };
}

fn inferValueType(value: []const u8) []const u8 {
    if (value.len == 0) return "[]const u8";

    if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "false")) {
        return "bool";
    }
    if (std.mem.eql(u8, value, "\"\"") or std.mem.eql(u8, value, "null")) {
        return "?[]const u8";
    }
    if (value[0] == '"' or (value.len >= 3 and std.mem.startsWith(u8, value, "\"\"\""))) {
        return "[]const u8";
    }
    if (value[0] == '[') return "[]const []const u8";

    // Try integer.
    if (common.isInteger(value)) return "i64";
    // Try float.
    if (common.isFloat(value)) return "f64";

    return "[]const u8";
}

fn extractName(line: []const u8, start: usize, end: usize) []const u8 {
    return std.mem.trim(u8, line[start..end], " ");
}

// ==================== Tests ====================

test "infer flat struct" {
    const output = try generate(std.testing.allocator,
        \\name = "myapp"
        \\port = 8080
        \\debug = true
    );
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings(
        \\const Root = struct {
        \\    name: []const u8,
        \\    port: i64,
        \\    debug: bool,
        \\};
        \\
    , output);
}

test "infer nested table" {
    const output = try generate(std.testing.allocator,
        \\name = "myapp"
        \\[server]
        \\host = "localhost"
        \\port = 443
    );
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings(
        \\const Server = struct {
        \\    host: []const u8,
        \\    port: i64,
        \\};
        \\
        \\const Root = struct {
        \\    name: []const u8,
        \\    server: Server,
        \\};
        \\
    , output);
}

test "infer table array" {
    const output = try generate(std.testing.allocator,
        \\[[servers]]
        \\host = "a.com"
        \\port = 80
        \\[[servers]]
        \\host = "b.com"
        \\port = 443
    );
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings(
        \\const Servers = struct {
        \\    host: []const u8,
        \\    port: i64,
        \\};
        \\
        \\const Root = struct {
        \\    servers: []const Servers,
        \\};
        \\
    , output);
}

test "infer float and null" {
    const output = try generate(std.testing.allocator,
        \\ratio = 3.14
        \\missing = null
    );
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings(
        \\const Root = struct {
        \\    ratio: f64,
        \\    missing: ?[]const u8,
        \\};
        \\
    , output);
}

test "infer keyword field names" {
    const output = try generate(std.testing.allocator,
        \\type = "server"
        \\error = false
        \\return = 1
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
