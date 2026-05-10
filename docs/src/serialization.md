# Serialization

## Basic Usage

Every `Serde(format, T)` instance exposes a `serialize` method:

```zig
const json = serde.Serde(.json, MyStruct);

var buf: [1024]u8 = undefined;
var writer = std.Io.Writer.fixed(&buf);
try json.serialize(&writer, my_value);
const output = writer.buffered(); // the serialized bytes
```

The writer is a `std.Io.Writer`, which is the standard Zig I/O interface. You can use fixed buffers, buffered writers, or any other writer implementation.

## Struct Serialization

Struct fields are serialized in declaration order:

```zig
const Point = struct {
    x: i32,
    y: i32,
};

// JSON: {"x":1,"y":2}
// TOML: x = 1\ny = 2
// YAML: x: 1\ny: 2
```

## Optional Fields

Optional fields with `null` values are included by default:

```zig
const Data = struct {
    name: []const u8,
    note: ?[]const u8 = null,
};

// JSON: {"name":"alice","note":null}
```

Use `omit_null` to suppress null values from output. See [Field Options](./field-options.md).

## Enum Serialization

Enums are serialized as their tag name string:

```zig
const Color = enum { red, green, blue };
// "red", "green", "blue"
```

## Nested Types

Structs, arrays, and slices can be nested arbitrarily:

```zig
const Config = struct {
    name: []const u8,
    tags: []const []const u8,
    metadata: struct {
        version: u32,
        debug: bool,
    },
};
```
