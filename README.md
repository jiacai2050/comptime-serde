# comptime-serde

Compile-time serialization and deserialization for Zig. Zero runtime overhead — all type dispatch happens at comptime.

Requires **Zig 0.16.0**.

## Usage

```zig
const serde = @import("comptime_serde");

const User = struct {
    name: []const u8,
    age: u32,
    active: bool,
};

// Serialize
const S = serde.Serde(.json, User);
var buf: [512]u8 = undefined;
var writer = std.Io.Writer.fixed(&buf);
try S.serialize(&writer, User{ .name = "alice", .age = 30, .active = true });
// buf contains: {"name":"alice","age":30,"active":true}

// Deserialize
var result = try S.deserialize(allocator, "{\"name\":\"alice\",\"age\":30,\"active\":true}");
defer result.deinit();
// result.value is a User
```

## Supported types

| Type | JSON |
|------|------|
| `bool` | `true` / `false` |
| Integers | `42` |
| Floats | `3.14` |
| `[]const u8` | `"hello"` |
| `[N]u8` | `"hello"` |
| `[]T` / `[N]T` | `[1,2,3]` |
| `?T` | value or `null` |
| `struct` | `{"key":value}` |

Struct fields with default values are optional during deserialization.

## Installation

Add to your `build.zig.zon`:

```bash
# Latest version
zig fetch --save git+https://github.com/jiacai2050/comptime-serde.git
# Tagged version
zig fetch --save git+https://github.com/jiacai2050/comptime-serde.git#v0.5.0
```

Then in `build.zig`:

```zig
const serde_dep = b.dependency("comptime_serde", .{});
exe.root_module.addImport("comptime_serde", serde_dep.module("comptime_serde"));
```

## Running tests

```
zig build test
```

## License

MIT
