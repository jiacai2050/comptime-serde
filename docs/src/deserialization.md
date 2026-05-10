# Deserialization

## Basic Usage

Every `Serde(format, T)` instance exposes a `deserialize` method:

```zig
const json = serde.Serde(.json, MyStruct);

var result = try json.deserialize(allocator, input_bytes);
defer result.deinit();

// result.value is of type MyStruct
```

The returned `Parsed(T)` owns an arena allocator. All strings and slices in the deserialized value point into this arena. Call `deinit()` to free everything at once.

## Error Handling

Deserialization can fail with:

- `error.MissingField` — a required field is absent from the input
- `error.DuplicateField` — the same key appears twice (JSON)
- `error.UnexpectedToken` — malformed input
- `error.Overflow` — numeric value out of range
- Format-specific parse errors

## Default Values

Fields with default values are optional in the input:

```zig
const Config = struct {
    host: []const u8 = "localhost",
    port: u16 = 8080,
    debug: bool = false,
};

// Input: {"port":9090}
// Result: host="localhost", port=9090, debug=false
```

## Optional Fields

Optional fields default to `null` when absent:

```zig
const User = struct {
    name: []const u8,
    bio: ?[]const u8 = null,
};

// Input: {"name":"alice"}
// Result: name="alice", bio=null
```

## Unknown Keys

Unknown keys in the input are silently ignored. This allows forward-compatible deserialization — new fields added to the struct won't break parsing of old input.

## Nested Types

Nested structs, arrays, and slices are deserialized recursively, following the same rules at each level.
