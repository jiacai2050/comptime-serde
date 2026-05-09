const std = @import("std");
const common = @import("formats/common.zig");
const format_adapters = @import("adapters/formats.zig");

/// Supported serialization formats.
pub const Format = format_adapters.Format;

/// Declares adapter capabilities for a format.
pub const FormatCapability = format_adapters.Capability;

/// Owns a deserialized value and its backing arena allocator; call `deinit()` to free.
pub const Parsed = common.Parsed;

/// Returns a comptime-generated type with serialize/deserialize methods
/// for `T` in the given `format`.
pub fn Serde(comptime format: Format, comptime T: type) type {
    return format_adapters.Serde(format, T);
}

/// Returns capability metadata for a format adapter.
pub fn formatCapability(comptime format: Format) FormatCapability {
    return format_adapters.capability(format);
}

test {
    std.testing.refAllDecls(@This());
}
