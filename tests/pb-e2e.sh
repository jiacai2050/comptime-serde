#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> Generating Go payloads..."
(cd tests && go run ./cmd/gen.go)

echo "==> Running Zig pb-e2e (deserialize Go payloads + serialize Zig output)..."
zig build pb-e2e

echo "==> Verifying Zig output with Go..."
(cd tests && go run ./cmd/verify.go)

echo "All pb-e2e round-trip tests passed."
