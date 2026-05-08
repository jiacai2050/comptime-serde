const std = @import("std");
const json = @import("formats/json.zig");
pub const toml = @import("formats/toml.zig");
pub const yaml = @import("formats/yaml.zig");
const common = @import("formats/common.zig");

/// Supported serialization formats.
pub const Format = enum { json, toml, yaml };

/// Returns a comptime-generated type with serialize/deserialize methods
/// for `T` in the given `format`.
pub fn Serde(format: Format, comptime T: type) type {
    return switch (format) {
        .json => json.Serde(T),
        .toml => toml.Serde(T),
        .yaml => yaml.Serde(T),
    };
}

/// Owns a deserialized value and its backing arena allocator; call `deinit()` to free.
pub const Parsed = common.Parsed;

test {
    std.testing.refAllDecls(@This());
}
