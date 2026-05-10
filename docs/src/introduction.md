# Introduction

![](https://img.shields.io/badge/zig%20version-0.16.0-F7A41D.svg)
[![](https://github.com/jiacai2050/comptime-serde/actions/workflows/ci.yml/badge.svg)](https://github.com/jiacai2050/comptime-serde/actions/workflows/ci.yml)

> **comptime-serde** is a compile-time serialization/deserialization library for Zig.

Define your struct once, automatically serialize/deserialize across JSON, TOML, YAML, and Protobuf — zero runtime overhead, all type dispatch happens at comptime via `@typeInfo`.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="./architecture-dark.svg">
  <img alt="comptime-serde architecture" src="./architecture.svg" width="640">
</picture>

## Features

- **Zero-cost abstractions**: All serialization/deserialization logic is generated at compile time. No runtime reflection, no vtables, no allocations beyond what you explicitly request.
- **Multi-format support**: JSON, TOML, YAML, and Protobuf (WIP) out of the box, with a uniform API across all formats.
- **Ergonomic field options**: Rename fields, skip fields, accept aliases, and omit nulls — all configured via a single `serde_fields` declaration on your type.
- **Arena-backed deserialization**: Deserialized values are returned in a `Parsed(T)` wrapper with an arena allocator. Call `deinit()` to free everything at once.

## API Reference

Auto-generated API docs for every public type and function are available at [apidocs](./apidocs/index.html).

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
