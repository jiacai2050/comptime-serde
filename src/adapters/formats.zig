const std = @import("std");
const json = @import("../formats/json.zig");
const toml = @import("../formats/toml.zig");
const yaml = @import("../formats/yaml.zig");
const protobuf = @import("../formats/protobuf.zig");

/// Supported serialization adapters.
pub const Format = enum { json, toml, yaml, protobuf };

/// Declares adapter capabilities for a format.
pub const Capability = struct {
    serialize: bool,
    deserialize: bool,
};

/// Returns a comptime-generated type with serialize/deserialize methods
/// for `T` in the given `format`.
pub fn Serde(comptime format: Format, comptime T: type) type {
    return switch (format) {
        .json => json.Serde(T),
        .toml => toml.Serde(T),
        .yaml => yaml.Serde(T),
        .protobuf => protobuf.Serde(T),
    };
}

/// Returns capability metadata for a format adapter.
pub fn capability(comptime format: Format) Capability {
    return switch (format) {
        .json, .toml, .yaml, .protobuf => .{
            .serialize = true,
            .deserialize = true,
        },
    };
}

test {
    std.testing.refAllDecls(@This());
}
