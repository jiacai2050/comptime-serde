const std = @import("std");
const infer_json = @import("infer_json.zig");
const infer_toml = @import("infer_toml.zig");
const infer_yaml = @import("infer_yaml.zig");

/// Supported inference adapters.
pub const InputFormat = enum { json, toml, yaml };

pub const GenerateFn = *const fn (std.mem.Allocator, []const u8) anyerror![]const u8;

/// Detects input format from file extension.
pub fn detectFormat(path: []const u8) ?InputFormat {
    const ext = std.fs.path.extension(path);
    if (std.mem.eql(u8, ext, ".json")) return .json;
    if (std.mem.eql(u8, ext, ".toml")) return .toml;
    if (std.mem.eql(u8, ext, ".yaml") or std.mem.eql(u8, ext, ".yml")) return .yaml;
    return null;
}

/// Selects a generator adapter for input format.
pub fn selectGenerator(format: InputFormat) GenerateFn {
    return switch (format) {
        .json => &infer_json.generate,
        .toml => &infer_toml.generate,
        .yaml => &infer_yaml.generate,
    };
}

/// Generates Zig structs from a known input format.
pub fn generate(
    allocator: std.mem.Allocator,
    format: InputFormat,
    content: []const u8,
) ![]const u8 {
    const generator = selectGenerator(format);
    return try generator(allocator, content);
}

test {
    std.testing.refAllDecls(@This());
}
