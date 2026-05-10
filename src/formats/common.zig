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

/// Per-format field options shared by JSON, TOML, and YAML.
pub const FormatFieldOptions = struct {
    rename: ?[]const u8 = null,
    alias: []const []const u8 = &.{},
    skip: bool = false,
    omit_null: bool = false,
};

/// Protobuf-specific field options.
pub const ProtobufFieldOptions = struct {
    field_number: ?u32 = null,
    @"packed": ?bool = null,
    deprecated: bool = false,
};

/// Aggregated field options keyed by format, populated from `T.serde_fields`.
pub const SerdeFieldOptions = struct {
    json: ?FormatFieldOptions = null,
    toml: ?FormatFieldOptions = null,
    yaml: ?FormatFieldOptions = null,
    protobuf: ?ProtobufFieldOptions = null,
};

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
    if (info != .@"struct") {
        @compileError(@typeName(T) ++ ".serde_fields." ++ field_name ++ "." ++ format_tag ++ " must be a struct");
    }
    inline for (info.@"struct".fields) |meta_field| {
        if (!@hasField(FormatFieldOptions, meta_field.name)) {
            @compileError(@typeName(T) ++ ".serde_fields." ++ field_name ++ "." ++ format_tag ++ " has unknown key: " ++ meta_field.name);
        }
    }
    var options: FormatFieldOptions = .{};
    if (@hasField(meta_type, "rename")) options.rename = @field(format_meta, "rename");
    if (@hasField(meta_type, "alias")) options.alias = @field(format_meta, "alias");
    if (@hasField(meta_type, "skip")) options.skip = @field(format_meta, "skip");
    if (@hasField(meta_type, "omit_null")) options.omit_null = @field(format_meta, "omit_null");
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
    if (@hasField(meta_type, "packed")) options.@"packed" = @field(protobuf_meta, "packed");
    if (@hasField(meta_type, "deprecated")) options.deprecated = @field(protobuf_meta, "deprecated");
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

/// Returns the renamed key for `field_name` on `T`, or `field_name` itself if no rename is set.
pub fn serializedFieldName(comptime format: Format, comptime T: type, comptime field_name: []const u8) []const u8 {
    const config = fieldConfig(format, T, field_name);
    return config.rename orelse field_name;
}

/// Returns true if `key` matches `field_name` on `T` via its original name, rename, or any alias.
pub fn matchesInputKey(comptime format: Format, comptime T: type, comptime field_name: []const u8, key: []const u8) bool {
    const config = fieldConfig(format, T, field_name);
    if (std.mem.eql(u8, field_name, key)) return true;
    if (config.rename) |rename| {
        if (std.mem.eql(u8, rename, key)) return true;
    }
    for (config.alias) |alias| {
        if (std.mem.eql(u8, alias, key)) return true;
    }
    return false;
}

/// Validates field configs for `T` in the given `format`: skip fields must be optional or have defaults,
/// and no two fields may share the same serialized name or alias.
pub fn validateFieldConfigs(comptime format: Format, comptime T: type) void {
    const format_tag = @tagName(format);
    const info = @typeInfo(T);
    if (info != .@"struct") return;
    validateSerdeFieldNames(T);
    const struct_info = info.@"struct";

    inline for (struct_info.fields) |field| {
        const config = fieldConfig(format, T, field.name);
        if (config.skip and field.default_value_ptr == null and @typeInfo(field.type) != .optional) {
            @compileError(format_tag ++ " skip field must be optional or have a default: " ++ @typeName(T) ++ "." ++ field.name);
        }
    }

    inline for (struct_info.fields, 0..) |left, left_index| {
        const left_name = serializedFieldName(format, T, left.name);
        const left_config = fieldConfig(format, T, left.name);
        inline for (struct_info.fields, 0..) |right, right_index| {
            if (left_index == right_index) continue;
            const right_name = serializedFieldName(format, T, right.name);
            if (std.mem.eql(u8, left_name, right_name)) {
                @compileError(format_tag ++ " field key conflict in " ++ @typeName(T) ++ ": " ++ left.name ++ " and " ++ right.name);
            }
            for (left_config.alias) |left_alias| {
                if (std.mem.eql(u8, left_alias, right_name) or std.mem.eql(u8, left_alias, right.name)) {
                    @compileError(format_tag ++ " alias conflict in " ++ @typeName(T) ++ ": alias '" ++ left_alias ++ "' conflicts with field " ++ right.name);
                }
                const right_config = fieldConfig(format, T, right.name);
                for (right_config.alias) |right_alias| {
                    if (std.mem.eql(u8, left_alias, right_alias)) {
                        @compileError(format_tag ++ " alias conflict in " ++ @typeName(T) ++ ": alias '" ++ left_alias ++ "' of " ++ left.name ++ " conflicts with alias of " ++ right.name);
                    }
                }
            }
        }
    }
}
