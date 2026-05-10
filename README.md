# comptime-serde

![](https://img.shields.io/badge/zig%20version-0.16.0-F7A41D.svg)
![](https://github.com/jiacai2050/comptime-serde/actions/workflows/ci.yml/badge.svg)

> Compile-time serialization and deserialization for Zig.

Define your struct once, automatically serialize/deserialize across JSON, TOML, YAML, and Protobuf — zero runtime overhead, all type dispatch happens at comptime via `@typeInfo`.

```
                          ┌─────────────┐
                          │  Zig Struct │
                          └──────┬──────┘
                                 │
                      Serde(format, T)
                                 │
            ┌────────┬───────────┼───────────┬──────────┐
            ▼        ▼           ▼           ▼          ▼
        ┌──────┐ ┌──────┐  ┌────────┐  ┌────────┐ ┌──────────┐
        │ JSON │ │ TOML │  │  YAML  │  │Protobuf│ │  ...     │
        └──────┘ └──────┘  └────────┘  └────────┘ └──────────┘
```

Requires **Zig 0.16.0**.

## Usage

```zig
const serde = @import("comptime_serde");

const User = struct {
    name: []const u8,
    age: u32,
    active: bool,
};

// JSON
const json = serde.Serde(.json, User);
var json_buf: [512]u8 = undefined;
var json_writer = std.Io.Writer.fixed(&json_buf);
try json.serialize(&json_writer, User{ .name = "alice", .age = 30, .active = true });
// json_buf contains: {"name":"alice","age":30,"active":true}

var json_result = try json.deserialize(allocator, "{\"name\":\"alice\",\"age\":30,\"active\":true}");
defer json_result.deinit();
// json_result.value is a User

// TOML
const toml = serde.Serde(.toml, User);
var toml_buf: [512]u8 = undefined;
var toml_writer = std.Io.Writer.fixed(&toml_buf);
try toml.serialize(&toml_writer, User{ .name = "alice", .age = 30, .active = true });
// toml_buf contains:
// name = "alice"
// age = 30
// active = true

// YAML
const yaml = serde.Serde(.yaml, User);
var yaml_buf: [512]u8 = undefined;
var yaml_writer = std.Io.Writer.fixed(&yaml_buf);
try yaml.serialize(&yaml_writer, User{ .name = "alice", .age = 30, .active = true });
// yaml_buf contains:
// name: alice
// age: 30
// active: true

// Protobuf (binary wire format)
const pb = serde.Serde(.protobuf, User);
var pb_buf: [512]u8 = undefined;
var pb_writer = std.Io.Writer.fixed(&pb_buf);
try pb.serialize(&pb_writer, allocator, User{ .name = "alice", .age = 30, .active = true });
// pb_writer.buffered() contains proto3 wire format bytes

var pb_result = try pb.deserialize(allocator, pb_writer.buffered());
defer pb_result.deinit();
// pb_result.value is a User
```

## Supported types

| Type | JSON | TOML | YAML | Protobuf |
|------|------|------|------|----------|
| `bool` | `true` / `false` | `true` / `false` | `true` / `false` | varint |
| Integers | `42` | `42` | `42` | varint (zigzag for signed) |
| Floats | `3.14` | `3.14` | `3.14` | fixed32 / fixed64 |
| `[]const u8` | `"hello"` | `"hello"` | `hello` | length-delimited |
| `[N]u8` | `"hello"` | `"hello"` | `hello` | — |
| `[]T` / `[N]T` | `[1,2,3]` | `[1, 2, 3]` | `- 1`<br>`- 2` | packed repeated |
| `?T` | value or `null` | value or `""` | value or `null` | field absent if null |
| `struct` | `{"key":value}` | `[table]` sections | indented mapping | nested message |
| `[]const Struct` | `[{...}]` | `[[array]]` sections | `- key: val` | repeated message |
| Multi-line `[]const u8` | `"a\nb"` | `"""\na\nb"""` | `\|-` block scalar | — |
| `enum` | `"active"` | `"active"` | `active` | varint |

### Protobuf notes

The protobuf format encodes structs as proto3 wire format. Field numbers are assigned by struct field declaration order (1-based). No `.proto` file is needed — just define your Zig struct and serialize directly. Signed integers use zigzag encoding (equivalent to `sint32`/`sint64` in proto3).

Struct fields with default values are optional during deserialization.

## Installation

Add to your `build.zig.zon`:

```bash
# Latest version
zig fetch --save git+https://github.com/jiacai2050/comptime-serde.git
# Tagged version
zig fetch --save git+https://github.com/jiacai2050/comptime-serde.git#v0.1.0
```

Then in `build.zig`:

```zig
const serde_dep = b.dependency("comptime_serde", .{});
exe.root_module.addImport("comptime_serde", serde_dep.module("comptime_serde"));
```

## serde-gen CLI

A code generation tool that infers Zig struct definitions from data files.

### Install serde-gen

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

Pre-built binaries are also available on the [GitHub Releases](https://github.com/jiacai2050/comptime-serde/releases) page, or build from source:

```bash
# Build from source
zig build

# Generate from JSON (format auto-detected from extension)
serde-gen config.json

# Force format explicitly
serde-gen --format toml config.txt

# Custom top-level struct name
serde-gen --root-name Config config.yaml

# Show help / version
serde-gen --help
serde-gen --version
```

Options:

| Flag | Description |
|------|-------------|
| `--format json\|toml\|yaml` | Force format (default: auto-detect from extension) |
| `--root-name NAME` | Name of the top-level struct (default: `Root`) |
| `-h`, `--help` | Show usage |

Example — given `config.json`:

```json
{"name": "myapp", "port": 8080, "server": {"host": "localhost", "tls": true}}
```

Output:

```zig
const Server = struct {
    host: []const u8,
    tls: bool,
};

const Root = struct {
    name: []const u8,
    port: i64,
    server: Server,
};
```

## Running tests

```
zig build test
```

## License

MIT
