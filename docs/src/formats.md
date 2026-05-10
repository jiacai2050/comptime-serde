# Formats

comptime-serde supports multiple serialization formats through a uniform API. All formats share the same `Serde(format, T)` interface and the same field options system.

## JSON

```zig
const json = serde.Serde(.json, MyStruct);

// Serialize
var buf: [1024]u8 = undefined;
var writer = std.Io.Writer.fixed(&buf);
try json.serialize(&writer, value);
// writer.buffered() contains the JSON output

// Deserialize
var result = try json.deserialize(allocator, json_bytes);
defer result.deinit();
```

JSON is the reference format. All Zig types map naturally to JSON:

- Structs → objects
- Arrays/slices → arrays
- Strings → strings
- Numbers → numbers
- Booleans → booleans
- Optionals → `null` or value
- Enums → string tag

## TOML

```zig
const toml = serde.Serde(.toml, MyStruct);
```

TOML has additional structural rules:

- Top-level struct fields become key-value pairs
- Nested structs become `[table]` sections
- Slices of structs become `[[array-of-tables]]` sections
- Slices of primitives become inline arrays

```zig
const Config = struct {
    name: []const u8,
    server: struct {
        host: []const u8,
        port: u16,
    },
    tags: []const []const u8,
};
```

Outputs:

```toml
name = "myapp"

[server]
host = "localhost"
port = 8080

tags = ["web", "api"]
```

## YAML

```zig
const yaml = serde.Serde(.yaml, MyStruct);
```

YAML output uses block style:

- Structs → mappings
- Arrays/slices → sequences
- Strings, numbers, booleans → scalars

```zig
const Data = struct {
    name: []const u8,
    items: []const u32,
};
```

Outputs:

```yaml
name: hello
items:
  - 1
  - 2
  - 3
```

## Protobuf

Protobuf support is work in progress. Zig structs map to protobuf messages:

- Structs → messages (field numbers assigned by declaration order, 1-based)
- `bool` → bool
- `u8`/`u16`/`u32` → uint32, `u64` → uint64
- `i8`/`i16`/`i32` → sint32 (ZigZag), `i64` → sint64 (ZigZag)
- `f32` → float (fixed32), `f64` → double (fixed64)
- `[]const u8` → string/bytes
- `[]const T` → repeated T (packed encoding for scalars)
- `enum(u32)` → enum
- `?T` → optional (omitted when null)

Field numbers and other options can be configured via `ProtobufFieldOptions`:

```zig
pub const serde_fields = .{
    .user_name = .{
        .protobuf = .{
            .field_number = 1,
            .packed = true,
            .deprecated = false,
        },
    },
};
```

The `serde-gen` CLI can generate Zig structs from `.proto` files, including `serde_fields` with explicit field numbers. See [serde-gen CLI](./serde-gen.md#proto).

## Cross-Format Configuration

Each format can have independent field options. A field can be renamed differently in each format:

```zig
const User = struct {
    name: []const u8,

    pub const serde_fields = .{
        .name = .{
            .json = .{
                .serialize = .{ .rename = "userName" },
                .deserialize = .{ .rename = "userName" },
            },
            .toml = .{
                .serialize = .{ .rename = "user_name" },
                .deserialize = .{ .rename = "user_name" },
            },
            .yaml = .{
                .serialize = .{ .rename = "user-name" },
                .deserialize = .{ .rename = "user-name" },
            },
        },
    };
};
```
