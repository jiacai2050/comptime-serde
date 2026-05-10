# Introduction

**comptime-serde** is a compile-time serialization/deserialization library for Zig. All type dispatch happens at comptime via `@typeInfo`, with zero runtime overhead.

## Features

- **Zero-cost abstractions**: All serialization/deserialization logic is generated at compile time. No runtime reflection, no vtables, no allocations beyond what you explicitly request.
- **Multi-format support**: JSON, TOML, YAML, and Protobuf (WIP) out of the box, with a uniform API across all formats.
- **Ergonomic field options**: Rename fields, skip fields, accept aliases, and omit nulls — all configured via a single `serde_fields` declaration on your type.
- **Arena-backed deserialization**: Deserialized values are returned in a `Parsed(T)` wrapper with an arena allocator. Call `deinit()` to free everything at once.

## Requirements

- Zig 0.16.0 or later

## Quick Example

```zig
const std = @import("std");
const serde = @import("comptime_serde");

const User = struct {
    name: []const u8,
    age: u32,
    email: ?[]const u8 = null,

    pub const serde_fields = .{
        .name = .{
            .json = .{
                .serialize = .{ .rename = "userName" },
                .deserialize = .{ .rename = "userName", .alias = &.{"username"} },
            },
        },
    };
};

pub fn main() !void {
    // Serialize
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const json_serde = serde.Serde(.json, User);
    try json_serde.serialize(&writer, .{ .name = "alice", .age = 30 });
    // Output: {"userName":"alice","age":30}

    // Deserialize
    var result = try json_serde.deserialize(std.heap.page_allocator,
        \\{"userName":"bob","age":25}
    );
    defer result.deinit();
    // result.value.name == "bob"
}
```
