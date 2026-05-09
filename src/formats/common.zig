const std = @import("std");

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

pub const JsonFieldOptions = struct {
    rename: ?[]const u8 = null,
    alias: []const []const u8 = &.{},
    skip: bool = false,
    omit_null: bool = false,
};

pub const TomlFieldOptions = struct {
    rename: ?[]const u8 = null,
    alias: []const []const u8 = &.{},
    skip: bool = false,
    omit_null: bool = false,
};

pub const YamlFieldOptions = struct {
    rename: ?[]const u8 = null,
    alias: []const []const u8 = &.{},
    skip: bool = false,
    omit_null: bool = false,
};

pub const ProtobufFieldOptions = struct {
    field_number: ?u32 = null,
    @"packed": ?bool = null,
    deprecated: bool = false,
};

pub const SerdeFieldOptions = struct {
    json: ?JsonFieldOptions = null,
    toml: ?TomlFieldOptions = null,
    yaml: ?YamlFieldOptions = null,
    protobuf: ?ProtobufFieldOptions = null,
};

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
    if (@hasField(field_meta_type, "json")) options.json = parseJsonFieldOptions(T, field_name, @field(field_meta, "json"));
    if (@hasField(field_meta_type, "toml")) options.toml = parseTomlFieldOptions(T, field_name, @field(field_meta, "toml"));
    if (@hasField(field_meta_type, "yaml")) options.yaml = parseYamlFieldOptions(T, field_name, @field(field_meta, "yaml"));
    if (@hasField(field_meta_type, "protobuf")) options.protobuf = parseProtobufFieldOptions(T, field_name, @field(field_meta, "protobuf"));
    return options;
}

fn parseJsonFieldOptions(comptime T: type, comptime field_name: []const u8, json_meta: anytype) JsonFieldOptions {
    const meta_type = @TypeOf(json_meta);
    const info = @typeInfo(meta_type);
    if (info != .@"struct") {
        @compileError(@typeName(T) ++ ".serde_fields." ++ field_name ++ ".json must be a struct");
    }
    inline for (info.@"struct".fields) |meta_field| {
        if (!@hasField(JsonFieldOptions, meta_field.name)) {
            @compileError(@typeName(T) ++ ".serde_fields." ++ field_name ++ ".json has unknown key: " ++ meta_field.name);
        }
    }
    var options: JsonFieldOptions = .{};
    if (@hasField(meta_type, "rename")) options.rename = @field(json_meta, "rename");
    if (@hasField(meta_type, "alias")) options.alias = @field(json_meta, "alias");
    if (@hasField(meta_type, "skip")) options.skip = @field(json_meta, "skip");
    if (@hasField(meta_type, "omit_null")) options.omit_null = @field(json_meta, "omit_null");
    return options;
}

fn parseTomlFieldOptions(comptime T: type, comptime field_name: []const u8, toml_meta: anytype) TomlFieldOptions {
    const meta_type = @TypeOf(toml_meta);
    const info = @typeInfo(meta_type);
    if (info != .@"struct") {
        @compileError(@typeName(T) ++ ".serde_fields." ++ field_name ++ ".toml must be a struct");
    }
    inline for (info.@"struct".fields) |meta_field| {
        if (!@hasField(TomlFieldOptions, meta_field.name)) {
            @compileError(@typeName(T) ++ ".serde_fields." ++ field_name ++ ".toml has unknown key: " ++ meta_field.name);
        }
    }
    var options: TomlFieldOptions = .{};
    if (@hasField(meta_type, "rename")) options.rename = @field(toml_meta, "rename");
    if (@hasField(meta_type, "alias")) options.alias = @field(toml_meta, "alias");
    if (@hasField(meta_type, "skip")) options.skip = @field(toml_meta, "skip");
    if (@hasField(meta_type, "omit_null")) options.omit_null = @field(toml_meta, "omit_null");
    return options;
}

fn parseYamlFieldOptions(comptime T: type, comptime field_name: []const u8, yaml_meta: anytype) YamlFieldOptions {
    const meta_type = @TypeOf(yaml_meta);
    const info = @typeInfo(meta_type);
    if (info != .@"struct") {
        @compileError(@typeName(T) ++ ".serde_fields." ++ field_name ++ ".yaml must be a struct");
    }
    inline for (info.@"struct".fields) |meta_field| {
        if (!@hasField(YamlFieldOptions, meta_field.name)) {
            @compileError(@typeName(T) ++ ".serde_fields." ++ field_name ++ ".yaml has unknown key: " ++ meta_field.name);
        }
    }
    var options: YamlFieldOptions = .{};
    if (@hasField(meta_type, "rename")) options.rename = @field(yaml_meta, "rename");
    if (@hasField(meta_type, "alias")) options.alias = @field(yaml_meta, "alias");
    if (@hasField(meta_type, "skip")) options.skip = @field(yaml_meta, "skip");
    if (@hasField(meta_type, "omit_null")) options.omit_null = @field(yaml_meta, "omit_null");
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
