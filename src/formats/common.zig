const std = @import("std");

/// Supported serialization formats.
pub const Format = enum { json, toml, yaml, protobuf };

/// Owns a deserialized value and its backing arena allocator; call `deinit()` to free.
pub fn Parsed(comptime T: type) type {
    return struct {
        arena: std.heap.ArenaAllocator,
        value: T,

        pub fn deinit(self: *@This()) void {
            self.arena.deinit();
        }
    };
}

/// Options that apply to serialization only.
pub const SerializeOptions = struct {
    /// Output this key instead of the Zig field name.
    rename: ?[]const u8 = null,
    /// Skip this field during serialization (omit from output entirely).
    skip: bool = false,
    /// Omit this field from output when its value is null (for optional fields only).
    omit_null: bool = false,
};

/// Options that apply to deserialization only.
pub const DeserializeOptions = struct {
    /// Accept this key name instead of the Zig field name.
    rename: ?[]const u8 = null,
    /// Skip this field during deserialization (leave as default/null).
    skip: bool = false,
    /// Accept these alternative input keys in addition to the Zig field name and rename.
    alias: []const []const u8 = &.{},
};

/// Per-format field options shared by JSON, TOML, and YAML.
/// Configure via `T.serde_fields` declaration.
///
/// Example:
/// ```zig
/// pub const serde_fields = .{
///     .user_name = .{
///         .json = .{
///             .serialize = .{ .rename = "userName", .omit_null = true },
///             .deserialize = .{ .rename = "userName", .alias = &.{"username"} },
///         },
///     },
/// };
/// ```
pub const FormatFieldOptions = struct {
    /// Serialize-only options (rename, skip, omit_null).
    serialize: ?SerializeOptions = null,
    /// Deserialize-only options (rename, skip, alias).
    deserialize: ?DeserializeOptions = null,
};

/// Protobuf-specific field options.
pub const ProtobufFieldOptions = struct {
    /// Explicit proto field number instead of relying on declaration order (1-based).
    field_number: ?u32 = null,
};

/// Aggregated field options keyed by format, populated from `T.serde_fields`.
pub const SerdeFieldOptions = struct {
    json: ?FormatFieldOptions = null,
    toml: ?FormatFieldOptions = null,
    yaml: ?FormatFieldOptions = null,
    protobuf: ?ProtobufFieldOptions = null,
};

/// Effective serialize-side options after merging format-level and direction-level fields.
pub const EffectiveSerializeOptions = struct {
    rename: ?[]const u8 = null,
    skip: bool = false,
    omit_null: bool = false,
};

/// Effective deserialize-side options after merging format-level and direction-level fields.
pub const EffectiveDeserializeOptions = struct {
    rename: ?[]const u8 = null,
    skip: bool = false,
    alias: []const []const u8 = &.{},
};

pub fn effectiveSerializeOptions(options: FormatFieldOptions) EffectiveSerializeOptions {
    if (options.serialize) |s| {
        return .{
            .rename = s.rename,
            .skip = s.skip,
            .omit_null = s.omit_null,
        };
    }
    return .{};
}

pub fn effectiveDeserializeOptions(options: FormatFieldOptions) EffectiveDeserializeOptions {
    if (options.deserialize) |d| {
        return .{
            .rename = d.rename,
            .skip = d.skip,
            .alias = d.alias,
        };
    }
    return .{};
}

/// Returns the `SerdeFieldOptions` for `field_name` on `T`, parsed from `T.serde_fields`.
pub fn fieldOptions(comptime T: type, comptime field_name: []const u8) SerdeFieldOptions {
    const info = @typeInfo(T);
    if (info != .@"struct" and info != .@"union" and info != .@"enum" and info != .@"opaque") {
        return .{};
    }
    if (!@hasDecl(T, "serde_fields")) return .{};
    const serde_fields = @field(T, "serde_fields");
    if (!@hasField(@TypeOf(serde_fields), field_name)) return .{};

    const field_meta = @field(serde_fields, field_name);
    const field_meta_type = @TypeOf(field_meta);
    const field_meta_info = @typeInfo(field_meta_type);
    if (field_meta_info != .@"struct") {
        @compileError(@typeName(T) ++ ".serde_fields." ++ field_name ++ " must be a struct");
    }

    inline for (field_meta_info.@"struct".fields) |meta_field| {
        if (!@hasField(SerdeFieldOptions, meta_field.name)) {
            @compileError(@typeName(T) ++ ".serde_fields." ++ field_name ++ " has unknown format key: " ++ meta_field.name);
        }
    }

    var options: SerdeFieldOptions = .{};
    if (@hasField(field_meta_type, "json")) options.json = parseFormatFieldOptions(T, field_name, .json, @field(field_meta, "json"));
    if (@hasField(field_meta_type, "toml")) options.toml = parseFormatFieldOptions(T, field_name, .toml, @field(field_meta, "toml"));
    if (@hasField(field_meta_type, "yaml")) options.yaml = parseFormatFieldOptions(T, field_name, .yaml, @field(field_meta, "yaml"));
    if (@hasField(field_meta_type, "protobuf")) options.protobuf = parseProtobufFieldOptions(T, field_name, @field(field_meta, "protobuf"));
    return options;
}

fn parseFormatFieldOptions(comptime T: type, comptime field_name: []const u8, comptime format_name: Format, format_meta: anytype) FormatFieldOptions {
    const meta_type = @TypeOf(format_meta);
    const info = @typeInfo(meta_type);
    const format_tag = @tagName(format_name);
    const prefix = @typeName(T) ++ ".serde_fields." ++ field_name ++ "." ++ format_tag;
    if (info != .@"struct") {
        @compileError(prefix ++ " must be a struct");
    }
    inline for (info.@"struct".fields) |meta_field| {
        if (!@hasField(FormatFieldOptions, meta_field.name)) {
            @compileError(prefix ++ " has unknown key: " ++ meta_field.name);
        }
    }
    var options: FormatFieldOptions = .{};
    if (@hasField(meta_type, "serialize")) options.serialize = parseSerializeOptions(T, field_name, format_tag, @field(format_meta, "serialize"));
    if (@hasField(meta_type, "deserialize")) options.deserialize = parseDeserializeOptions(T, field_name, format_tag, @field(format_meta, "deserialize"));
    return options;
}

fn parseSerializeOptions(comptime T: type, comptime field_name: []const u8, comptime format_tag: []const u8, serialize_meta: anytype) SerializeOptions {
    const meta_type = @TypeOf(serialize_meta);
    const info = @typeInfo(meta_type);
    if (info != .@"struct") {
        @compileError(@typeName(T) ++ ".serde_fields." ++ field_name ++ "." ++ format_tag ++ ".serialize must be a struct");
    }
    inline for (info.@"struct".fields) |meta_field| {
        if (!@hasField(SerializeOptions, meta_field.name)) {
            @compileError(@typeName(T) ++ ".serde_fields." ++ field_name ++ "." ++ format_tag ++ ".serialize has unknown key: " ++ meta_field.name);
        }
    }
    var options: SerializeOptions = .{};
    if (@hasField(meta_type, "rename")) options.rename = @field(serialize_meta, "rename");
    if (@hasField(meta_type, "skip")) options.skip = @field(serialize_meta, "skip");
    if (@hasField(meta_type, "omit_null")) options.omit_null = @field(serialize_meta, "omit_null");
    return options;
}

fn parseDeserializeOptions(comptime T: type, comptime field_name: []const u8, comptime format_tag: []const u8, deserialize_meta: anytype) DeserializeOptions {
    const meta_type = @TypeOf(deserialize_meta);
    const info = @typeInfo(meta_type);
    if (info != .@"struct") {
        @compileError(@typeName(T) ++ ".serde_fields." ++ field_name ++ "." ++ format_tag ++ ".deserialize must be a struct");
    }
    inline for (info.@"struct".fields) |meta_field| {
        if (!@hasField(DeserializeOptions, meta_field.name)) {
            @compileError(@typeName(T) ++ ".serde_fields." ++ field_name ++ "." ++ format_tag ++ ".deserialize has unknown key: " ++ meta_field.name);
        }
    }
    var options: DeserializeOptions = .{};
    if (@hasField(meta_type, "rename")) options.rename = @field(deserialize_meta, "rename");
    if (@hasField(meta_type, "skip")) options.skip = @field(deserialize_meta, "skip");
    if (@hasField(meta_type, "alias")) options.alias = @field(deserialize_meta, "alias");
    return options;
}

fn parseProtobufFieldOptions(comptime T: type, comptime field_name: []const u8, protobuf_meta: anytype) ProtobufFieldOptions {
    const meta_type = @TypeOf(protobuf_meta);
    const info = @typeInfo(meta_type);
    if (info != .@"struct") {
        @compileError(@typeName(T) ++ ".serde_fields." ++ field_name ++ ".protobuf must be a struct");
    }
    inline for (info.@"struct".fields) |meta_field| {
        if (!@hasField(ProtobufFieldOptions, meta_field.name)) {
            @compileError(@typeName(T) ++ ".serde_fields." ++ field_name ++ ".protobuf has unknown key: " ++ meta_field.name);
        }
    }
    var options: ProtobufFieldOptions = .{};
    if (@hasField(meta_type, "field_number")) options.field_number = @field(protobuf_meta, "field_number");
    return options;
}

/// Validates that every key in `T.serde_fields` corresponds to an actual field on `T`.
pub fn validateSerdeFieldNames(comptime T: type) void {
    const t_info = @typeInfo(T);
    if (t_info != .@"struct" and t_info != .@"union" and t_info != .@"enum" and t_info != .@"opaque") {
        return;
    }
    if (!@hasDecl(T, "serde_fields")) return;
    const serde_fields = @field(T, "serde_fields");
    const info = @typeInfo(@TypeOf(serde_fields));
    if (info != .@"struct") {
        @compileError(@typeName(T) ++ ".serde_fields must be a struct");
    }
    inline for (info.@"struct".fields) |decl_field| {
        if (!@hasField(T, decl_field.name)) {
            @compileError(@typeName(T) ++ ".serde_fields contains unknown field: " ++ decl_field.name);
        }
        _ = fieldOptions(T, decl_field.name);
    }
}

/// Returns the `FormatFieldOptions` for `field_name` on `T` in the given `format`.
pub fn fieldConfig(comptime format: Format, comptime T: type, comptime field_name: []const u8) FormatFieldOptions {
    const options = fieldOptions(T, field_name);
    return @field(options, @tagName(format)) orelse .{};
}

/// Returns the effective serialize-side config for `field_name` on `T`.
pub fn serializeConfig(comptime format: Format, comptime T: type, comptime field_name: []const u8) EffectiveSerializeOptions {
    return effectiveSerializeOptions(fieldConfig(format, T, field_name));
}

/// Returns the effective deserialize-side config for `field_name` on `T`.
pub fn deserializeConfig(comptime format: Format, comptime T: type, comptime field_name: []const u8) EffectiveDeserializeOptions {
    return effectiveDeserializeOptions(fieldConfig(format, T, field_name));
}

/// Returns the renamed key for serialization of `field_name` on `T`, or `field_name` itself.
pub fn serializedFieldName(comptime format: Format, comptime T: type, comptime field_name: []const u8) []const u8 {
    return serializeConfig(format, T, field_name).rename orelse field_name;
}

/// Returns true if `key` matches `field_name` on `T`.
/// When a rename is configured, the original field name is no longer accepted;
/// only the rename and any aliases are matched.
pub fn matchesInputKey(comptime format: Format, comptime T: type, comptime field_name: []const u8, key: []const u8) bool {
    const config = deserializeConfig(format, T, field_name);
    if (config.rename) |rename| {
        if (std.mem.eql(u8, rename, key)) return true;
    } else {
        if (std.mem.eql(u8, field_name, key)) return true;
    }
    for (config.alias) |alias| {
        if (std.mem.eql(u8, alias, key)) return true;
    }
    return false;
}

/// Validates field configs for `T` in the given `format`:
/// - skip fields must be optional or have defaults
/// - skip is mutually exclusive with rename, omit_null, and alias
/// - omit_null on non-optional fields is an error
/// - alias must not duplicate the rename or field name
/// - no two fields may share the same serialized or deserialized name or alias
pub fn validateFieldConfigs(comptime format: Format, comptime T: type) void {
    const format_tag = @tagName(format);
    const info = @typeInfo(T);
    if (info != .@"struct") return;
    validateSerdeFieldNames(T);
    const struct_info = info.@"struct";

    inline for (struct_info.fields) |field| {
        const serialize_options = serializeConfig(format, T, field.name);
        const deserialize_options = deserializeConfig(format, T, field.name);
        const skip = serialize_options.skip or deserialize_options.skip;
        if (skip and field.default_value_ptr == null and @typeInfo(field.type) != .optional) {
            @compileError(format_tag ++ " skip field must be optional or have a default: " ++ @typeName(T) ++ "." ++ field.name);
        }
        // skip makes rename/omit_null/alias meaningless
        if (serialize_options.skip and serialize_options.rename != null) {
            @compileError(format_tag ++ " serialize.skip and serialize.rename are mutually exclusive on " ++ @typeName(T) ++ "." ++ field.name);
        }
        if (serialize_options.skip and serialize_options.omit_null) {
            @compileError(format_tag ++ " serialize.skip and serialize.omit_null are mutually exclusive on " ++ @typeName(T) ++ "." ++ field.name);
        }
        if (deserialize_options.skip and deserialize_options.rename != null) {
            @compileError(format_tag ++ " deserialize.skip and deserialize.rename are mutually exclusive on " ++ @typeName(T) ++ "." ++ field.name);
        }
        if (deserialize_options.skip and deserialize_options.alias.len > 0) {
            @compileError(format_tag ++ " deserialize.skip and deserialize.alias are mutually exclusive on " ++ @typeName(T) ++ "." ++ field.name);
        }
        // omit_null on non-optional field has no effect
        if (serialize_options.omit_null and @typeInfo(field.type) != .optional) {
            @compileError(format_tag ++ " serialize.omit_null on non-optional field has no effect: " ++ @typeName(T) ++ "." ++ field.name);
        }
        // alias must not duplicate the rename or field name
        if (deserialize_options.rename) |rename| {
            for (deserialize_options.alias) |alias_name| {
                if (std.mem.eql(u8, alias_name, rename)) {
                    @compileError(format_tag ++ " deserialize.alias '" ++ alias_name ++ "' duplicates deserialize.rename on " ++ @typeName(T) ++ "." ++ field.name);
                }
            }
        }
        for (deserialize_options.alias) |alias_name| {
            if (std.mem.eql(u8, alias_name, field.name)) {
                @compileError(format_tag ++ " deserialize.alias '" ++ alias_name ++ "' duplicates field name on " ++ @typeName(T) ++ "." ++ field.name);
            }
        }
    }

    inline for (struct_info.fields, 0..) |left, left_index| {
        const left_serialize = serializeConfig(format, T, left.name);
        const left_deserialize = deserializeConfig(format, T, left.name);
        const left_serialize_name = left_serialize.rename orelse left.name;
        // When rename is set, the original field name is no longer accepted on input,
        // so the effective deserialize key is the rename; otherwise it's the field name.
        const left_deserialize_name = left_deserialize.rename orelse left.name;
        inline for (struct_info.fields, 0..) |right, right_index| {
            if (left_index == right_index) continue;
            const right_serialize = serializeConfig(format, T, right.name);
            const right_deserialize = deserializeConfig(format, T, right.name);
            const right_serialize_name = right_serialize.rename orelse right.name;
            const right_deserialize_name = right_deserialize.rename orelse right.name;

            // Serialize names must not collide.
            if (std.mem.eql(u8, left_serialize_name, right_serialize_name)) {
                @compileError(format_tag ++ " field key conflict in " ++ @typeName(T) ++ ": " ++ left.name ++ " and " ++ right.name);
            }
            // Deserialize names must not collide.
            if (std.mem.eql(u8, left_deserialize_name, right_deserialize_name)) {
                @compileError(format_tag ++ " deserialize key conflict in " ++ @typeName(T) ++ ": " ++ left.name ++ " and " ++ right.name);
            }
            // Deserialize name of left must not collide with serialize name of right.
            if (!std.mem.eql(u8, left.name, right.name) and std.mem.eql(u8, left_deserialize_name, right_serialize_name)) {
                @compileError(format_tag ++ " key conflict in " ++ @typeName(T) ++ ": deserialize key of " ++ left.name ++ " collides with serialize key of " ++ right.name);
            }

            for (left_deserialize.alias) |left_alias| {
                if (std.mem.eql(u8, left_alias, right_serialize_name) or std.mem.eql(u8, left_alias, right_deserialize_name)) {
                    @compileError(format_tag ++ " alias conflict in " ++ @typeName(T) ++ ": alias '" ++ left_alias ++ "' conflicts with field " ++ right.name);
                }
                for (right_deserialize.alias) |right_alias| {
                    if (std.mem.eql(u8, left_alias, right_alias)) {
                        @compileError(format_tag ++ " alias conflict in " ++ @typeName(T) ++ ": alias '" ++ left_alias ++ "' of " ++ left.name ++ " conflicts with alias of " ++ right.name);
                    }
                }
            }
        }
    }
}

/// Writes `string` as a double-quoted JSON/TOML string with standard escapes.
pub fn writeEscapedString(writer: *std.Io.Writer, string: []const u8) !void {
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

/// Returns true if `field_name` should be included in serialized output:
/// not skipped, and not omitted when the value is null.
pub fn shouldIncludeField(comptime format: Format, comptime T: type, comptime field_name: []const u8, field_value: anytype) bool {
    const config = serializeConfig(format, T, field_name);
    if (config.skip) return false;
    if (config.omit_null) {
        if (@typeInfo(@TypeOf(field_value)) == .optional) {
            if (field_value == null) return false;
        }
    }
    return true;
}

/// Fills in default/null values for fields not present in the deserialized input.
/// Returns `error.MissingField` if a required field has no default and is not skipped.
pub fn fillMissingFields(comptime format: Format, comptime T: type, result: *T, fields_seen: []const bool) !void {
    _ = format;
    const struct_info = @typeInfo(T).@"struct";
    inline for (struct_info.fields, 0..) |field, index| {
        if (!fields_seen[index]) {
            if (field.default_value_ptr) |default_ptr| {
                const ptr: *const field.type = @ptrCast(@alignCast(default_ptr));
                @field(result, field.name) = ptr.*;
            } else if (@typeInfo(field.type) == .optional) {
                @field(result, field.name) = null;
            } else {
                return error.MissingField;
            }
        }
    }
}
