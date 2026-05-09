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
```

## Supported types

| Type | JSON | TOML | YAML |
|------|------|------|------|
| `bool` | `true` / `false` | `true` / `false` | `true` / `false` |
| Integers | `42` | `42` | `42` |
| Floats | `3.14` | `3.14` | `3.14` |
| `[]const u8` | `"hello"` | `"hello"` | `hello` |
| `[N]u8` | `"hello"` | `"hello"` | `hello` |
| `[]T` / `[N]T` | `[1,2,3]` | `[1, 2, 3]` | `- 1`<br>`- 2` |
| `?T` | value or `null` | value or `""` | value or `null` |
| `struct` | `{"key":value}` | `[table]` sections | indented mapping |
| `[]const Struct` | `[{...}]` | `[[array]]` sections | `- key: val` |
| Multi-line `[]const u8` | `"a\nb"` | `"""\na\nb"""` | `\|-` block scalar |

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

```bash
# Build
zig build

# Generate from JSON
zig build run -- config.json

# Generate from TOML
zig build run -- config.toml

# Generate from YAML
zig build run -- config.yaml
```

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
