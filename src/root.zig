const std = @import("std");
const core = @import("core.zig");
pub const json = @import("formats/json.zig");
pub const toml = @import("formats/toml.zig");
pub const yaml = @import("formats/yaml.zig");
pub const protobuf = @import("formats/protobuf.zig");
pub const format_adapters = @import("adapters/formats.zig");

/// Supported serialization formats.
pub const Format = core.Format;
pub const FormatCapability = core.FormatCapability;

/// Returns a comptime-generated type with serialize/deserialize methods
/// for `T` in the given `format`.
pub fn Serde(comptime format: Format, comptime T: type) type {
    return core.Serde(format, T);
}

/// Returns capability metadata for a format adapter.
pub fn formatCapability(comptime format: Format) FormatCapability {
    return core.formatCapability(format);
}

/// Owns a deserialized value and its backing arena allocator; call `deinit()` to free.
pub const Parsed = core.Parsed;

test {
    std.testing.refAllDecls(@This());
}
