const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const structargs = @import("zigcli").structargs;
const infer_json = @import("infer_json.zig");
const infer_toml = @import("infer_toml.zig");
const infer_yaml = @import("infer_yaml.zig");

const version_string = std.fmt.comptimePrint(
    \\serde-gen
    \\ - version: {s}
    \\ - commit: https://github.com/jiacai2050/comptime-serde/commit/{s}
    \\
    \\Build Config:
    \\ - build mode: {s}
    \\ - zig version: {s}
    \\ - zig backend: {s}
, .{
    build_options.version,
    build_options.git_commit,
    @tagName(builtin.mode),
    builtin.zig_version_string,
    @tagName(builtin.zig_backend),
});

const Format = enum { json, toml, yaml };

const Options = struct {
    format: ?Format = null,
    @"root-name": []const u8 = "Root",
    help: bool = false,
    version: bool = false,

    pub const __shorts__ = .{
        .format = .f,
        .help = .h,
        .version = .v,
    };
    pub const __messages__ = .{
        .format = "Force format (json, toml, yaml). Auto-detected from extension if omitted.",
        .@"root-name" = "Name of the top-level struct.",
    };
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const result = structargs.parse(
        allocator,
        io,
        init.minimal.args,
        Options,
        .{
            .argument_prompt = "FILE",
            .version_string = version_string,
        },
    ) catch |err| {
        std.process.fatal("failed to parse arguments: {t}", .{err});
    };
    defer result.deinit();

    const file_path = if (result.positional_arguments.len > 0)
        result.positional_arguments[0]
    else {
        std.process.fatal("missing input file. Use --help for usage.", .{});
    };

    const format = result.options.format orelse detectFormat(file_path) orelse {
        std.process.fatal("cannot detect format from extension. Use --format to specify.", .{});
    };

    const generator = selectGenerator(format);

    const content = std.Io.Dir.cwd().readFileAlloc(
        io,
        file_path,
        allocator,
        std.Io.Limit.limited(10 * 1024 * 1024),
    ) catch {
        std.process.fatal("failed to read file: {s}", .{file_path});
    };
    defer allocator.free(content);

    const raw_output = generator(allocator, content) catch {
        std.process.fatal("failed to generate struct definitions", .{});
    };
    defer allocator.free(raw_output);

    const root_name = result.options.@"root-name";
    const output = if (!std.mem.eql(u8, root_name, "Root"))
        renameRoot(allocator, raw_output, root_name) catch raw_output
    else
        raw_output;
    defer if (!std.mem.eql(u8, root_name, "Root")) allocator.free(output);

    try std.Io.File.stdout().writeStreamingAll(io, output);
}

const GenerateFn = *const fn (std.mem.Allocator, []const u8) anyerror![]const u8;

fn selectGenerator(format: Format) GenerateFn {
    return switch (format) {
        .json => &infer_json.generate,
        .toml => &infer_toml.generate,
        .yaml => &infer_yaml.generate,
    };
}

fn renameRoot(allocator: std.mem.Allocator, source: []const u8, name: []const u8) ![]const u8 {
    const needle = "const Root =";
    const replacement = try std.fmt.allocPrint(allocator, "const {s} =", .{name});
    defer allocator.free(replacement);

    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, source, pos, needle)) |found| {
        try result.appendSlice(allocator, source[pos..found]);
        try result.appendSlice(allocator, replacement);
        pos = found + needle.len;
    }
    try result.appendSlice(allocator, source[pos..]);

    return try result.toOwnedSlice(allocator);
}

fn detectFormat(path: []const u8) ?Format {
    const ext = std.fs.path.extension(path);
    if (std.mem.eql(u8, ext, ".json")) return .json;
    if (std.mem.eql(u8, ext, ".toml")) return .toml;
    if (std.mem.eql(u8, ext, ".yaml") or std.mem.eql(u8, ext, ".yml")) return .yaml;
    return null;
}

test {
    std.testing.refAllDecls(@This());
}
