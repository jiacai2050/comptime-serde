#!/bin/sh

set -e

SERDE_GEN="${1:-zig-out/bin/serde-gen}"
PASS=0
FAIL=0

assert_eq() {
    local desc="$1"
    local expected="$2"
    local actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: $desc"
        echo "  expected: $expected"
        echo "  actual:   $actual"
    fi
}

run_test() {
    local desc="$1"
    shift
    local expected="$1"
    shift
    local actual
    actual=$("$@" 2>&1) || true
    assert_eq "$desc" "$expected" "$actual"
}

echo "=== serde-gen tests ==="
echo "Binary: $SERDE_GEN"
echo

# --- JSON ---

run_test "json flat struct" \
"const Root = struct {
    name: []const u8,
    age: i64,
};" \
"$SERDE_GEN" --format json -- - <<'EOF'
{"name":"alice","age":30}
EOF

run_test "json nested struct" \
"const Server = struct {
    host: []const u8,
};

const Root = struct {
    server: Server,
};" \
"$SERDE_GEN" --format json -- - <<'EOF'
{"server":{"host":"localhost"}}
EOF

run_test "json array" \
"const Root = struct {
    tags: []const []const u8,
};" \
"$SERDE_GEN" --format json -- - <<'EOF'
{"tags":["web","api"]}
EOF

run_test "json root-name" \
"const Config = struct {
    port: i64,
};" \
"$SERDE_GEN" --format json --root-name Config -- - <<'EOF'
{"port":8080}
EOF

# --- TOML ---

run_test "toml flat struct" \
"const Root = struct {
    name: []const u8,
    port: i64,
};" \
"$SERDE_GEN" --format toml -- - <<'EOF'
name = "myapp"
port = 8080
EOF

# --- YAML ---

run_test "yaml flat struct" \
"const Root = struct {
    name: []const u8,
    port: i64,
};" \
"$SERDE_GEN" --format yaml -- - <<'EOF'
name: myapp
port: 8080
EOF

# --- File input ---

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

cat > "$TMP_DIR/config.json" <<'EOF'
{"host":"localhost","port":8080}
EOF

run_test "json file input" \
"const Root = struct {
    host: []const u8,
    port: i64,
};" \
"$SERDE_GEN" "$TMP_DIR/config.json"

# --- Summary ---

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
