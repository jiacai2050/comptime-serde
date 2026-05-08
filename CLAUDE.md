# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

comptime-serde — a compile-time serialization/deserialization library for Zig. All type dispatch happens at comptime via `@typeInfo`, zero runtime overhead.

Requires **Zig 0.16.0**.

## Commands

```
zig build test                        # run all tests
zig build test -Doptimize=ReleaseFast # run tests in release mode
zig fmt src/                          # format source
zig fmt --check src/                  # check formatting only
```

Individual test files cannot be run separately — `zig build test` compiles from `src/root.zig` which pulls in all modules via `refAllDecls`.

## Architecture

- `src/root.zig` — Public API entry point. `Serde(format, T)` dispatches to the format-specific implementation. `Parsed` is re-exported from the format module.
- `src/formats/json.zig` — Complete JSON format implementation. Contains `Serde(T)` which returns a comptime-generated struct with `serialize`/`deserialize` methods, `Parsed(T)` wrapper with arena-backed `deinit()`, and all tests.

Adding a new format: add it to the `Format` enum in root.zig, create `src/formats/<name>.zig` with the same `Serde(T)` / `Parsed(T)` interface, and wire the dispatch in root.zig's `Serde()`.

## Code style

Follow TigerStyle conventions:
- Functions that return types are `PascalCase` (`Serde`, `Parsed`), regular functions are `camelCase`.
- No abbreviations in variable names (use `struct_info`, not `s`; `pointer_info`, not `p`).
- Always run `zig fmt` before committing.
