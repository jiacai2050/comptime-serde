const std = @import("std");
const json = @import("formats/json.zig");

/// Supported serialization formats.
pub const Format = enum { json };

/// Returns a comptime-generated type with serialize/deserialize methods for `T` in the given `format`.
pub fn Serde(format: Format, comptime T: type) type {
    return switch (format) {
        .json => json.Serde(T),
    };
}

/// Owns a deserialized value and its backing arena allocator; call `deinit()` to free.
pub const Parsed = json.Parsed;

test {
    std.testing.refAllDecls(@This());
}
