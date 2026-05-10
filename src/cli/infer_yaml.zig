const std = @import("std");
const common = @import("common.zig");
const StructDefinition = common.StructDefinition;
const FieldDefinition = common.FieldDefinition;

/// Infers Zig struct definitions from YAML content.
/// Returns the generated source code as a string.
pub fn generate(allocator: std.mem.Allocator, content: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var structs = std.ArrayList(StructDefinition).empty;
    const all_lines = try splitLines(arena_alloc, content);

    var pos: usize = 0;
    try parseMapping(arena_alloc, all_lines, &pos, 0, "Root", &structs);

    return try common.renderStructs(allocator, arena_alloc, structs.items);
}

fn splitLines(allocator: std.mem.Allocator, content: []const u8) ![]const []const u8 {
    var list = std.ArrayList([]const u8).empty;
    defer list.deinit(allocator);
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed_cr = if (line.len > 0 and line[line.len - 1] == '\r')
            line[0 .. line.len - 1]
        else
            line;
        try list.append(allocator, trimmed_cr);
    }
    return try list.toOwnedSlice(allocator);
}

const InferError = std.mem.Allocator.Error;

fn parseMapping(
    allocator: std.mem.Allocator,
    all_lines: []const []const u8,
    pos: *usize,
    base_indent: usize,
    name: []const u8,
    structs: *std.ArrayList(StructDefinition),
) InferError!void {
    var fields = std.ArrayList(FieldDefinition).empty;

    while (pos.* < all_lines.len) {
        const line = all_lines[pos.*];
        if (line.len == 0 or isBlankOrComment(line)) {
            pos.* += 1;
            continue;
        }
        const indent = lineIndent(line);
        if (indent < base_indent) break;

        const trimmed = std.mem.trimStart(u8, line, " ");

        // Sequence item — stop, this belongs to the parent.
        if (trimmed.len >= 2 and trimmed[0] == '-' and trimmed[1] == ' ') break;

        const colon_pos = findColon(trimmed) orelse {
            pos.* += 1;
            continue;
        };
        const key = trimmed[0..colon_pos];
        const after_colon = std.mem.trimStart(u8, trimmed[colon_pos + 1 ..], " ");

        pos.* += 1;

        const type_name = try inferFieldType(
            allocator,
            all_lines,
            pos,
            indent,
            after_colon,
            key,
            structs,
        );
        try fields.append(allocator, .{ .name = key, .type_name = type_name });
    }

    try structs.append(allocator, .{ .name = name, .fields = fields });
}

fn inferFieldType(
    allocator: std.mem.Allocator,
    all_lines: []const []const u8,
    pos: *usize,
    parent_indent: usize,
    inline_value: []const u8,
    field_name: []const u8,
    structs: *std.ArrayList(StructDefinition),
) InferError![]const u8 {
    // Nested struct: empty inline value + indented content below.
    if (inline_value.len == 0) {
        const next_indent = peekNextIndent(all_lines, pos.*);
        if (next_indent != null and next_indent.? > parent_indent) {
            // Check if it's a sequence.
            if (pos.* < all_lines.len) {
                const next_line = std.mem.trimStart(u8, all_lines[pos.*], " ");
                if (next_line.len >= 2 and next_line[0] == '-' and next_line[1] == ' ') {
                    return try inferSequenceType(
                        allocator,
                        all_lines,
                        pos,
                        parent_indent,
                        field_name,
                        structs,
                    );
                }
            }
            // Nested mapping.
            const struct_name = try common.capitalizeFirst(allocator, field_name);
            try parseMapping(allocator, all_lines, pos, parent_indent + 2, struct_name, structs);
            return struct_name;
        }
        return "?[]const u8";
    }

    // Block scalar.
    if (std.mem.eql(u8, inline_value, "|") or std.mem.eql(u8, inline_value, "|-")) {
        skipBlock(all_lines, pos, parent_indent + 2);
        return "[]const u8";
    }

    return inferScalarType(inline_value);
}

fn inferSequenceType(
    allocator: std.mem.Allocator,
    all_lines: []const []const u8,
    pos: *usize,
    parent_indent: usize,
    field_name: []const u8,
    structs: *std.ArrayList(StructDefinition),
) ![]const u8 {
    const seq_indent = parent_indent + 2;

    // Parse first item to determine element type.
    if (pos.* < all_lines.len) {
        const line = all_lines[pos.*];
        const indent = lineIndent(line);
        if (indent >= seq_indent) {
            const trimmed = std.mem.trimStart(u8, line, " ");
            if (trimmed.len >= 2 and trimmed[0] == '-' and trimmed[1] == ' ') {
                const item_content = trimmed[2..];
                // Check if it's a struct item (has a colon).
                if (findColon(item_content) != null) {
                    // Struct sequence — parse first item to define the struct.
                    const struct_name = try common.capitalizeFirst(allocator, field_name);
                    try parseSequenceItemStruct(
                        allocator,
                        all_lines,
                        pos,
                        seq_indent,
                        struct_name,
                        structs,
                    );
                    return try std.fmt.allocPrint(allocator, "[]const {s}", .{struct_name});
                }
                // Primitive sequence — skip all items.
                const element_type = inferScalarType(item_content);
                skipSequence(all_lines, pos, seq_indent);
                return try std.fmt.allocPrint(allocator, "[]const {s}", .{element_type});
            }
        }
    }

    skipSequence(all_lines, pos, seq_indent);
    return "[]const []const u8";
}

fn parseSequenceItemStruct(
    allocator: std.mem.Allocator,
    all_lines: []const []const u8,
    pos: *usize,
    seq_indent: usize,
    name: []const u8,
    structs: *std.ArrayList(StructDefinition),
) !void {
    // Check if already defined.
    for (structs.items) |s| {
        if (std.mem.eql(u8, s.name, name)) {
            skipSequence(all_lines, pos, seq_indent);
            return;
        }
    }

    var fields = std.ArrayList(FieldDefinition).empty;

    // Parse first item.
    if (pos.* < all_lines.len) {
        const line = all_lines[pos.*];
        const trimmed = std.mem.trimStart(u8, line, " ");
        if (trimmed.len >= 2 and trimmed[0] == '-' and trimmed[1] == ' ') {
            const item_content = trimmed[2..];
            pos.* += 1;

            // First field from inline content.
            if (findColon(item_content)) |colon_pos| {
                const key = item_content[0..colon_pos];
                const value = std.mem.trimStart(u8, item_content[colon_pos + 1 ..], " ");
                try fields.append(allocator, .{ .name = key, .type_name = inferScalarType(value) });
            }

            // Remaining fields from indented lines.
            const item_indent = seq_indent + 2;
            while (pos.* < all_lines.len) {
                const next_line = all_lines[pos.*];
                if (next_line.len == 0 or isBlankOrComment(next_line)) {
                    pos.* += 1;
                    continue;
                }
                const next_indent = lineIndent(next_line);
                if (next_indent < item_indent) break;
                const next_trimmed = std.mem.trimStart(u8, next_line, " ");
                if (next_trimmed[0] == '-') break;

                if (findColon(next_trimmed)) |colon_pos| {
                    const key = next_trimmed[0..colon_pos];
                    const value = std.mem.trimStart(u8, next_trimmed[colon_pos + 1 ..], " ");
                    try fields.append(allocator, .{
                        .name = key,
                        .type_name = inferScalarType(value),
                    });
                }
                pos.* += 1;
            }
        }
    }

    try structs.append(allocator, .{ .name = name, .fields = fields });

    // Skip remaining sequence items.
    skipSequence(all_lines, pos, seq_indent);
}

fn inferScalarType(value: []const u8) []const u8 {
    if (value.len == 0) return "[]const u8";
    if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "false")) return "bool";
    if (std.mem.eql(u8, value, "null") or std.mem.eql(u8, value, "~")) return "?[]const u8";
    if (common.isInteger(value)) return "i64";
    if (common.isFloat(value)) return "f64";
    return "[]const u8";
}

fn skipBlock(all_lines: []const []const u8, pos: *usize, block_indent: usize) void {
    while (pos.* < all_lines.len) {
        const line = all_lines[pos.*];
        if (line.len == 0) {
            pos.* += 1;
            continue;
        }
        if (lineIndent(line) < block_indent) return;
        pos.* += 1;
    }
}

fn skipSequence(all_lines: []const []const u8, pos: *usize, seq_indent: usize) void {
    while (pos.* < all_lines.len) {
        const line = all_lines[pos.*];
        if (line.len == 0 or isBlankOrComment(line)) {
            pos.* += 1;
            continue;
        }
        if (lineIndent(line) < seq_indent) return;
        pos.* += 1;
    }
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

fn isBlankOrComment(line: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, line, " ");
    return trimmed.len == 0 or trimmed[0] == '#';
}

fn findColon(line: []const u8) ?usize {
    for (line, 0..) |char, i| {
        if (char == ':') return i;
    }
    return null;
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

// ==================== Tests ====================

test "infer flat struct" {
    const output = try generate(std.testing.allocator,
        \\name: myapp
        \\port: 8080
        \\debug: true
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

test "infer nested struct" {
    const output = try generate(std.testing.allocator,
        \\name: myapp
        \\server:
        \\  host: localhost
        \\  port: 443
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

test "infer sequence of primitives" {
    const output = try generate(std.testing.allocator,
        \\tags:
        \\  - web
        \\  - api
    );
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings(
        \\const Root = struct {
        \\    tags: []const []const u8,
        \\};
        \\
    , output);
}

test "infer sequence of structs" {
    const output = try generate(std.testing.allocator,
        \\servers:
        \\  - host: a.com
        \\    port: 80
        \\  - host: b.com
        \\    port: 443
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
        \\ratio: 3.14
        \\missing: null
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
        \\type: server
        \\error: false
        \\return: 1
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
