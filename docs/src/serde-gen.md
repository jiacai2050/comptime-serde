# serde-gen CLI

`serde-gen` is a command-line tool that infers Zig struct definitions from data files. Point it at a JSON, TOML, YAML, or Proto file and it outputs the corresponding Zig structs to stdout.

## Installation

### From release (recommended)

```bash
curl -fsSL https://jiacai2050.github.io/comptime-serde/install.sh | sh
```

Options:

```bash
# Install a specific version
sh install.sh --version v0.1.0

# Install to a custom directory
sh install.sh --prefix /usr/local/bin

# Use proxy for users in China
sh install.sh --china
```

### From source

```bash
zig build
```

The binary is written to `zig-out/bin/serde-gen`.

## Usage

```bash
serde-gen [OPTIONS] <FILE>
```

### Arguments

| Argument | Description |
|---|---|
| `FILE` | Input data file (JSON, TOML, YAML, or Proto). Use `-` to read from stdin. |

### Options

| Option | Short | Description |
|---|---|---|
| `--format <fmt>` | `-f` | Force format (`json`, `toml`, `yaml`, `proto`). Auto-detected from file extension if omitted. |
| `--root-name <name>` | | Name of the top-level struct (default: `Root`) |
| `--help` | `-h` | Show help |
| `--version` | `-v` | Show version info |

## Examples

### JSON

Given `config.json`:

```json
{
  "host": "localhost",
  "port": 8080,
  "debug": false,
  "tags": ["web", "api"]
}
```

```bash
$ serde-gen config.json
const Root = struct {
    host: []const u8,
    port: i64,
    debug: bool,
    tags: []const []const u8,
};
```

### Nested Objects

Nested objects become separate structs with capitalized names:

```bash
$ serde-gen - <<'EOF'
{"server":{"host":"localhost","port":8080}}
EOF
const Server = struct {
    host: []const u8,
    port: i64,
};

const Root = struct {
    server: Server,
};
```

### Custom Root Name

```bash
$ serde-gen --root-name Config config.json
const Config = struct {
    host: []const u8,
    port: i64,
    debug: bool,
    tags: []const []const u8,
};
```

### TOML

```bash
$ serde-gen config.toml
```

### YAML

```bash
$ serde-gen config.yaml
# or
$ serde-gen config.yml
```

### Proto

Given `server.proto`:

```protobuf
syntax = "proto3";

enum Status {
  STATUS_UNKNOWN = 0;
  STATUS_ACTIVE = 1;
}

message Server {
  string host = 1;
  uint32 port = 2;
  Status status = 3;
  repeated string tags = 4;
}
```

```bash
$ serde-gen server.proto
const Status = enum(u32) {
    status_unknown = 0,
    status_active = 1,
};

const Server = struct {
    host: []const u8,
    port: u32,
    status: Status,
    tags: []const []const u8,
    pub const serde_fields = .{
        .host = .{ .protobuf = .{ .field_number = 1 } },
        .port = .{ .protobuf = .{ .field_number = 2 } },
        .status = .{ .protobuf = .{ .field_number = 3 } },
        .tags = .{ .protobuf = .{ .field_number = 4 } },
    };
};
```

Proto output includes `serde_fields` with explicit `field_number` values so that the generated structs can be used directly with the protobuf serializer/deserializer.

## Type Inference Rules

### JSON / TOML / YAML

| Data Type | Zig Type |
|---|---|
| string | `[]const u8` |
| integer | `i64` |
| float | `f64` |
| boolean | `bool` |
| null | `?[]const u8` |
| array of T | `[]const T` |
| object / mapping | nested struct (name capitalized from key) |
| empty array | `[]const std.json.Value` |

### Proto

| Proto Type | Zig Type |
|---|---|
| `string`, `bytes` | `[]const u8` |
| `bool` | `bool` |
| `int32`, `sint32`, `sfixed32` | `i32` |
| `int64`, `sint64`, `sfixed64` | `i64` |
| `uint32`, `fixed32` | `u32` |
| `uint64`, `fixed64` | `u64` |
| `float` | `f32` |
| `double` | `f64` |
| `repeated T` | `[]const T` |
| `message` | nested struct |
| `enum` | `enum(u32)` (values lowercased) |

## Special Field Names

Field names that are not valid Zig identifiers are wrapped in `@""` syntax:

```bash
$ serde-gen --format json - <<'EOF'
{"user-name":"alice","2fast":true}
EOF
const Root = struct {
    @"user-name": []const u8,
    @"2fast": bool,
};
```

## Pipe from stdin

Read from stdin by using `-` as the file path:

```bash
echo '{"x":1,"y":2}' | serde-gen --format json -
```

`--format` is required when reading from stdin since there is no file extension to auto-detect.

## Limitations

`serde-gen` is an inference tool, not a full parser. It reads one sample file and guesses types from the values present. Keep these limitations in mind.

### JSON

- **All integers become `i64`**, all floats become `f64`. Narrower types (`u32`, `f32`, etc.) must be adjusted by hand.
- **Null always infers `?[]const u8`**. If the actual value is a nullable integer or struct, the type must be corrected manually.
- **Empty arrays** default to `[]const std.json.Value` since the element type cannot be inferred.

### TOML

- **Hand-rolled parser** — only supports a practical subset of the TOML spec. Inline tables (`key = { a = 1 }`), dotted keys (`a.b.c = 1`), and datetime values are not handled.
- **Type is inferred from the first occurrence** of each key. If the first value is `"8080"` (a string), the field will be `[]const u8` even if a later entry has an integer.
- **No nested array-of-tables** — `[[a.b]]` sections inside `[[a]]` are not supported.

### YAML

- **Hand-rolled parser** — only supports block-style mappings and sequences. Flow style (`{a: 1}` or `[1, 2]`), anchors/aliases (`*ref`), and multi-document streams (`---`) are not handled.
- **Type is inferred from the first element** of a sequence. All subsequent elements are assumed to have the same type.
- **Block scalars** (`|`, `>`) are recognized but always inferred as `[]const u8`.

### Proto

- **[Proto3](https://protobuf.dev/programming-guides/proto3/) only** — `syntax = "proto2"` is not supported.
- **No `oneof`, `map`, `service`, `extend`, or `reserved`** declarations. These lines are silently skipped.
- **No imports** — all types must be defined in the same file.
- **Forward references** — a type must be defined before it is referenced. If `message A` references `message B` but `B` is defined later in the file, the generated Zig will have a compile error.
- **Field options** (`[deprecated = true]`, etc.) are recognized and ignored in the output.
- **Enum values are lowercased** — proto convention `STATUS_ACTIVE` becomes Zig `status_active`.
