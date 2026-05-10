# serde-gen CLI

`serde-gen` is a command-line tool that infers Zig struct definitions from data files. Point it at a JSON, TOML, or YAML file and it outputs the corresponding Zig structs to stdout.

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
| `FILE` | Input data file (JSON, TOML, or YAML) |

### Options

| Option | Short | Description |
|---|---|---|
| `--format <fmt>` | `-f` | Force format (`json`, `toml`, `yaml`). Auto-detected from file extension if omitted. |
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

## Type Inference Rules

| Data Type | Zig Type |
|---|---|
| string | `[]const u8` |
| integer | `i64` |
| float | `f64` |
| boolean | `bool` |
| null | `?[]const u8` |
| array of T | `[]const T` |
| object | nested struct (name capitalized from key) |
| empty array | `[]const std.json.Value` |

## Special Field Names

Field names that are not valid Zig identifiers are wrapped in `@""` syntax:

```bash
$ serde-gen - <<'EOF'
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
