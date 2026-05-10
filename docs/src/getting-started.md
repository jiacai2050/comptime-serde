# Getting Started

## Installation

Add comptime-serde as a dependency in your `build.zig.zon`:

```bash
# Latest version
zig fetch --save git+https://github.com/jiacai2050/comptime-serde.git
# Tagged version
zig fetch --save git+https://github.com/jiacai2050/comptime-serde.git#v0.2.0
```

Then in your `build.zig`:

```zig
const serde_dep = b.dependency("comptime_serde", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("comptime_serde", serde_dep.module("comptime_serde"));
```

## Core API

The public API lives in the root module:

```zig
const serde = @import("comptime_serde");
```

### `Serde(format, T)`

Returns a comptime-generated struct with `serialize` and `deserialize` methods for type `T` in the given format.

```zig
const json = serde.Serde(.json, MyStruct);
const toml = serde.Serde(.toml, MyStruct);
const yaml = serde.Serde(.yaml, MyStruct);
```

### `Parsed(T)`

Wraps a deserialized value with its backing arena allocator. Always call `deinit()` when done.

```zig
var result = try json.deserialize(allocator, input);
defer result.deinit();
// use result.value
```

### `Format`

Enum of supported formats: `.json`, `.toml`, `.yaml`, `.protobuf`.

## Supported Types

comptime-serde supports all common Zig types:

| Zig Type | JSON | TOML | YAML |
|---|---|---|---|
| `bool` | `true`/`false` | `true`/`false` | `true`/`false` |
| `u8`–`u64`, `i8`–`i64` | number | integer | integer |
| `f32`, `f64` | number | float | float |
| `[]const u8` | string | string | string |
| `?T` | `null` or value | omitted or value | `null` or value |
| `[N]T` | array | array | sequence |
| `[]T` | array | array of tables | sequence |
| `struct { ... }` | object | table | mapping |
| `enum { ... }` | string | string | string |
