# Field Options

Field options control how individual struct fields are serialized and deserialized. Configure them via the `serde_fields` declaration on your type.

## Configuration Structure

Options are organized as: **field name → format → direction → option**.

```zig
const MyStruct = struct {
    user_name: []const u8,

    pub const serde_fields = .{
        .user_name = .{
            .json = .{
                .serialize = .{ /* serialize options */ },
                .deserialize = .{ /* deserialize options */ },
            },
        },
    };
};
```

Each format (`.json`, `.toml`, `.yaml`) can have independent configuration. Options not specified default to no-op.

## Serialize Options

| Option | Type | Default | Description |
|---|---|---|---|
| `rename` | `?[]const u8` | `null` | Output this key instead of the Zig field name |
| `skip` | `bool` | `false` | Omit this field from output entirely |
| `omit_null` | `bool` | `false` | Omit this field when its value is null (optional fields only) |

### `rename`

Change the output key name:

```zig
pub const serde_fields = .{
    .user_name = .{
        .json = .{
            .serialize = .{ .rename = "userName" },
        },
    },
};
// Zig: .user_name = "alice"  →  JSON: {"userName":"alice"}
```

### `skip`

Exclude a field from serialized output:

```zig
pub const serde_fields = .{
    .password = .{
        .json = .{
            .serialize = .{ .skip = true },
        },
    },
};
```

### `omit_null`

Suppress optional fields when null:

```zig
const Data = struct {
    id: u32,
    note: ?[]const u8 = null,

    pub const serde_fields = .{
        .note = .{
            .json = .{
                .serialize = .{ .omit_null = true },
            },
        },
    };
};
// note=null  →  {"id":1}       (note omitted)
// note="hi"  →  {"id":1,"note":"hi"}
```

## Deserialize Options

| Option | Type | Default | Description |
|---|---|---|---|
| `rename` | `?[]const u8` | `null` | Accept this key instead of the Zig field name |
| `skip` | `bool` | `false` | Don't read this field from input (uses default/null) |
| `alias` | `[]const []const u8` | `&.{}` | Accept these keys in addition to the effective name |

### `rename`

Accept an alternative key name. When set, the original field name is **no longer accepted** — only the rename and any aliases match.

```zig
pub const serde_fields = .{
    .user_name = .{
        .json = .{
            .deserialize = .{ .rename = "userName" },
        },
    },
};
// {"userName":"alice"}  →  user_name = "alice"   ✓
// {"user_name":"alice"} →  error.MissingField     ✗ (original name rejected)
```

### `alias`

Accept additional key names. Aliases are matched **in addition to** the rename (or field name when no rename is set).

```zig
pub const serde_fields = .{
    .user_name = .{
        .json = .{
            .deserialize = .{
                .rename = "userName",
                .alias = &.{"username", "user"},
            },
        },
    },
};
// {"userName":"alice"}  →  user_name = "alice"   ✓
// {"username":"alice"}  →  user_name = "alice"   ✓ (alias)
// {"user":"alice"}      →  user_name = "alice"   ✓ (alias)
// {"user_name":"alice"} →  error.MissingField     ✗
```

### `skip`

Don't read this field from input. The field retains its default value (or null for optionals):

```zig
const Config = struct {
    host: []const u8 = "localhost",
    secret: []const u8 = "hidden",

    pub const serde_fields = .{
        .secret = .{
            .json = .{
                .deserialize = .{ .skip = true },
            },
        },
    },
};
// {"host":"example.com","secret":"leaked"}  →  secret = "hidden"
```

## Validation Rules

The following combinations are compile-time errors:

| Rule | Reason |
|---|---|
| `skip` + `rename` | skip prevents the field from participating; rename has no effect |
| `skip` + `omit_null` | skip takes precedence; omit_null never triggers |
| `skip` + `alias` | skip prevents reading; alias has no effect |
| `omit_null` on non-optional | the value can never be null |
| `alias` duplicates `rename` | redundant; the rename already matches |
| `alias` duplicates field name | redundant; the field name already matches (when no rename) |
| skip without default or optional | the field would have no value after skipping |
| two fields with same serialized key | ambiguous output |
| two fields with same deserialized key | ambiguous input matching |
