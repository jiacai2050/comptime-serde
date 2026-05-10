const std = @import("std");

pub const StructDef = struct {
    name: []const u8,
    fields: std.ArrayList(FieldDef),
};

pub const FieldDef = struct {
    name: []const u8,
    type_name: []const u8,
};

/// Returns true if `name` is not a valid Zig identifier and needs `@"..."` quoting.
pub fn needsQuoting(name: []const u8) bool {
    if (name.len == 0) return true;
    if (name[0] >= '0' and name[0] <= '9') return true;
    if (std.zig.Token.getKeyword(name) != null) return true;
    for (name) |char| {
        const is_alnum = (char >= 'a' and char <= 'z') or
            (char >= 'A' and char <= 'Z') or
            (char >= '0' and char <= '9') or
            char == '_';
        if (!is_alnum) return true;
    }
    return false;
}

/// Wraps `name` in `@"..."` if it is not a valid Zig identifier.
pub fn formatName(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    if (needsQuoting(name)) {
        return try std.fmt.allocPrint(allocator, "@\"{s}\"", .{name});
    }
    return name;
}

/// Capitalizes the first character of `name`.
pub fn capitalizeFirst(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    if (name.len == 0) return name;
    if (name[0] >= 'a' and name[0] <= 'z') {
        const result = try allocator.dupe(u8, name);
        result[0] -= 32;
        return result;
    }
    return name;
}

/// Returns true if `value` looks like an integer (optional leading sign, all digits).
pub fn isInteger(value: []const u8) bool {
    var start: usize = 0;
    if (value.len > 0 and (value[0] == '-' or value[0] == '+')) start = 1;
    if (start >= value.len) return false;
    for (value[start..]) |char| {
        if (char < '0' or char > '9') return false;
    }
    return true;
}

/// Returns true if `value` looks like a float (digits with exactly one dot).
pub fn isFloat(value: []const u8) bool {
    var has_dot = false;
    var start: usize = 0;
    if (value.len > 0 and (value[0] == '-' or value[0] == '+')) start = 1;
    if (start >= value.len) return false;
    for (value[start..]) |char| {
        if (char == '.') {
            if (has_dot) return false;
            has_dot = true;
        } else if (char < '0' or char > '9') {
            return false;
        }
    }
    return has_dot;
}

/// Renders a list of struct definitions into Zig source code.
pub fn renderStructs(
    caller_alloc: std.mem.Allocator,
    arena_alloc: std.mem.Allocator,
    structs: []const StructDef,
) ![]const u8 {
    var output = std.ArrayList(u8).empty;

    for (structs) |struct_def| {
        const capitalized = capitalizeFirst(arena_alloc, struct_def.name) catch struct_def.name;
        const formatted_name = formatName(arena_alloc, capitalized) catch capitalized;
        const header = try std.fmt.allocPrint(
            arena_alloc,
            "const {s} = struct {{\n",
            .{formatted_name},
        );
        try output.appendSlice(arena_alloc, header);

        for (struct_def.fields.items) |field| {
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

    return try caller_alloc.dupe(u8, output.items);
}
