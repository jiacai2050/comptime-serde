# Copilot instructions for `comptime-serde`

## Build, test, and lint

- **Required Zig version:** `0.16.0` (the codebase uses Zig 0.16 APIs like `std.Io.Writer`).
- **Run all tests:** `zig build test`
- **Run tests in release mode:** `zig build test -Doptimize=ReleaseFast`
- **Format source:** `zig fmt src/`
- **Check formatting:** `zig fmt --check src/`

Convenience `make` targets are also used in CI:

- `make lint` → `zig fmt --check .`
- `make test` → `zig build test --test-timeout 5s --summary all`

Single-test workflow:

- The main test entrypoint is aggregated through `src/root.zig` + `std.testing.refAllDecls`, so `zig build test` runs the full suite.
- Do not assume individual test files can be run directly; use the aggregated test entrypoint instead.
- For focused local debugging, run the suite with a test filter, e.g.:
  `zig build test --test-filter "serialize bool"`

## High-level architecture

- **Public API dispatch:** `src/root.zig` defines `Format` and `Serde(format, T)`, which dispatches to format modules (`json`, `toml`, `yaml`, `protobuf`) at comptime.
- **Shared ownership model:** `src/formats/common.zig` defines `Parsed(T)` (arena allocator + `value` + `deinit()`); each format’s `deserialize` returns this ownership wrapper.
- **Format module contract:** every format module exposes `Serde(comptime T: type) type` that returns a generated struct with `serialize` / `deserialize`.
- **Format-specific parsing strategies:**
  - `json.zig`: token scanner–based parser, unknown object fields are skipped, missing required fields error unless default values exist.
  - `toml.zig`: two-phase struct parse (KV lines first, then `[table]` / `[[array]]` sections).
  - `yaml.zig`: indentation-driven parser with mapping/sequence handling and block scalar support.
  - `protobuf.zig`: proto3-style wire encoding; struct field order maps to field numbers (1-based), repeated scalars are packed, repeated structs are length-delimited.
- **CLI tool (`serde-gen`):** `src/cli/main.zig` routes to `infer_json.zig`, `infer_toml.zig`, or `infer_yaml.zig`; each infers struct defs from sample data and renders Zig code.
- **Build graph:** `build.zig` always builds library tests; CLI build/tests are wired through lazy dependency `zigcli` and share the same `test` step when dependency is available.

## Key conventions specific to this repository

- **Comptime-first type dispatch:** serializers/deserializers branch on `@typeInfo` and reject unsupported shapes with `@compileError`; preserve this style when extending types.
- **Missing-field semantics:** deserializers consistently apply `field.default_value_ptr` when present; otherwise they return `error.MissingField`.
- **Memory lifecycle contract:** deserialization allocates through an arena and returns `Parsed(T)`; callers must call `deinit()`.
- **Format-extension pattern:** to add a format, update `Format` in `src/root.zig`, add `src/formats/<name>.zig` implementing the same `Serde/Parsed` contract, then wire dispatch in `root.zig`.
- **Naming/style baseline:** follow TigerStyle conventions from `CLAUDE.md` (type-returning functions in `PascalCase`, regular functions in `camelCase`, avoid abbreviations in variable names).
