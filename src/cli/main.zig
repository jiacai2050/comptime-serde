const std = @import("std");
const infer_json = @import("infer_json.zig");
const infer_toml = @import("infer_toml.zig");
const infer_yaml = @import("infer_yaml.zig");

pub fn main(init: std.process.Init.Minimal) !void {
    var debug_allocator = std.heap.DebugAllocator(.{}){};
    const allocator = debug_allocator.allocator();

    var args_iter = std.process.Args.Iterator.init(init.args);
    _ = args_iter.skip();

    const file_path: [:0]const u8 = args_iter.next() orelse {
        writeStderr("Usage: serde-gen <file.json|file.toml|file.yaml>\n");
        std.process.exit(1);
    };

    const ext = std.fs.path.extension(file_path);

    const generator = selectGenerator(ext) orelse {
        writeStderr("Error: unsupported format (use .json, .toml, .yaml, or .yml)\n");
        std.process.exit(1);
    };

    const content = readFile(allocator, file_path) orelse {
        writeStderr("Error: failed to read file\n");
        std.process.exit(1);
    };
    defer allocator.free(content);

    const output = generator(allocator, content) catch {
        writeStderr("Error: failed to generate struct definitions\n");
        std.process.exit(1);
    };
    defer allocator.free(output);

    writeStdout(output);
}

const GenerateFn = *const fn (std.mem.Allocator, []const u8) anyerror![]const u8;

fn selectGenerator(ext: []const u8) ?GenerateFn {
    if (std.mem.eql(u8, ext, ".json")) return &infer_json.generate;
    if (std.mem.eql(u8, ext, ".toml")) return &infer_toml.generate;
    if (std.mem.eql(u8, ext, ".yaml") or std.mem.eql(u8, ext, ".yml")) return &infer_yaml.generate;
    return null;
}

fn readFile(allocator: std.mem.Allocator, path: [:0]const u8) ?[]u8 {
    const file = std.c.fopen(path, "r") orelse return null;
    defer _ = std.c.fclose(file);

    var content = std.ArrayList(u8).empty;
    var buf: [4096]u8 = undefined;
    while (true) {
        const read = std.c.fread(&buf, 1, buf.len, file);
        if (read > 0) {
            content.appendSlice(allocator, buf[0..read]) catch return null;
        }
        if (read < buf.len) break;
    }
    return content.toOwnedSlice(allocator) catch null;
}

fn writeStdout(bytes: []const u8) void {
    _ = std.c.write(std.posix.STDOUT_FILENO, bytes.ptr, bytes.len);
}

fn writeStderr(bytes: []const u8) void {
    _ = std.c.write(std.posix.STDERR_FILENO, bytes.ptr, bytes.len);
}

test {
    std.testing.refAllDecls(@This());
}
