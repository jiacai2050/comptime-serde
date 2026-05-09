# Roadmap

## Library (comptime-serde)

- [ ] Enum support — serialize as string, deserialize string back to enum value
- [ ] Tagged union support — `union(enum)` for polymorphic JSON structures
- [ ] Field name mapping — comptime `snake_case` <-> `camelCase` renaming
- [ ] Custom serialize hooks — allow types to declare `pub const serde_serialize` to override default behavior
- [ ] Comptime validation — clear compile errors when a type has unsupported fields
- [ ] Streaming deserialization — avoid requiring entire input in memory

## CLI (serde-gen)

- [ ] `--stdin` flag — read from stdin for pipe usage (`curl ... | serde-gen --stdin --format json`)
- [ ] `--root-name` flag — customize the top-level struct name (default: `Root`)
- [ ] `--output` flag — write directly to a file instead of stdout
- [ ] Multi-file merge inference — read multiple files of the same type, merge fields (missing fields become optional)
- [ ] Build step integration — provide a `build.zig` helper to generate `.zig` from data files as a compile step
- [ ] Format conversion mode — `serde-gen convert config.toml --to yaml`

## Ecosystem

- [ ] JSON Schema to struct — generate typed structs from JSON Schema (more precise than value inference)
- [ ] Benchmarks — compare performance against `std.json` and hand-written serialization to demonstrate zero overhead
