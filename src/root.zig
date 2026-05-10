//! comptime-serde — compile-time serialization and deserialization for Zig.
//!
//! ```text
//!                           ┌─────────────┐
//!                           │  Zig Struct │
//!                           └──────┬──────┘
//!                                  │
//!                       Serde(format, T)
//!                                  │
//!             ┌────────┬───────────┼───────────┬──────────┐
//!             ▼        ▼           ▼           ▼          ▼
//!         ┌──────┐ ┌──────┐  ┌────────┐  ┌────────┐ ┌──────────┐
//!         │ JSON │ │ TOML │  │  YAML  │  │Protobuf│ │  ...     │
//!         └──────┘ └──────┘  └────────┘  └────────┘ └──────────┘
//! ```

const std = @import("std");
pub const json = @import("formats/json.zig");
pub const toml = @import("formats/toml.zig");
pub const yaml = @import("formats/yaml.zig");
pub const protobuf = @import("formats/protobuf.zig");
const common = @import("formats/common.zig");

pub const Format = common.Format;

/// Returns a comptime-generated type with serialize/deserialize methods
/// for `T` in the given `format`.
pub fn Serde(comptime format: Format, comptime T: type) type {
    return switch (format) {
        inline else => |fmt| fmt.Serde(T),
    };
}

/// Owns a deserialized value and its backing arena allocator; call `deinit()` to free.
pub const Parsed = common.Parsed;

test {
    std.testing.refAllDecls(@This());
}
