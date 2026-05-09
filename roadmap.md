# Roadmap

## Current priorities (Top 3)

### 1) Field metadata and compatibility controls (library)

- [ ] Add field-level metadata for `rename` and `alias`
- [ ] Add output controls: `skip` and `omit_null`
- [ ] Unify default-value behavior across JSON / TOML / YAML
- [ ] Add cross-format compatibility tests for renamed/aliased fields

### 2) Explicit protobuf schema controls (library)

- [ ] Support explicit protobuf field numbers instead of relying only on declaration order
- [ ] Add compile-time checks for field-number conflicts
- [ ] Add `reserved` / `deprecated` metadata support
- [ ] Add `oneof` design + MVP implementation

### 3) Better error diagnostics (library + CLI)

- [ ] Introduce a unified error model (`kind`, `path`, `span`)
- [ ] Include field path in deserialize errors (`a.b.c`)
- [ ] Add line/column context for JSON / TOML / YAML parse failures
- [ ] Surface structured errors in `serde-gen` output

## Backlog

### Library (comptime-serde)

- [ ] Tagged union support — `union(enum)` for polymorphic structures
- [ ] Custom serialize hooks — allow types to declare custom serialization behavior
- [ ] Streaming deserialization — avoid requiring entire input in memory

### CLI (serde-gen)

- [ ] `--stdin` flag — read from stdin for pipe usage (`curl ... | serde-gen --stdin --format json`)
- [ ] `--output` flag — write directly to a file instead of stdout
- [ ] Multi-file merge inference — read multiple files of the same type, merge fields (missing fields become optional)
- [ ] Build step integration — provide a `build.zig` helper to generate `.zig` from data files as a compile step
- [ ] Format conversion mode — `serde-gen convert config.toml --to yaml`

### Ecosystem

- [ ] JSON Schema to struct — generate typed structs from JSON Schema
- [ ] Benchmarks — compare performance against `std.json` and hand-written serialization
