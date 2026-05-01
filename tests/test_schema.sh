#!/usr/bin/env bash

# Regression test for the migration system.
#
# Catches the class of bug where SCHEMA_VERSION is bumped but only one of
# init_sessions / migrate_sessions is updated — making fresh installs and
# upgraded installs land on different shapes.
#
# Strategy: drive the script via HOME override so each scenario gets a clean
# isolated state directory under /tmp. No mocking, no sourcing.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_DIR/claude-cluster"

if ! command -v jq &> /dev/null; then
    echo "ERROR: jq is required to run this test (brew install jq)"
    exit 1
fi
if [[ ! -x "$SCRIPT" ]]; then
    echo "ERROR: $SCRIPT not found or not executable"
    exit 1
fi

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

pass=0
fail=0

check() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  PASS  $label"
        pass=$((pass + 1))
    else
        echo "  FAIL  $label"
        echo "    expected: $expected"
        echo "    actual:   $actual"
        fail=$((fail + 1))
    fi
}

# Run the script under a sandboxed HOME so state lands in our temp dir.
run_isolated() {
    local home="$1"
    shift
    HOME="$home" bash "$SCRIPT" "$@" > /dev/null
}

# Pull SCHEMA_VERSION out of the script so the test always reflects the source.
expected_version=$(awk -F= '/^SCHEMA_VERSION=/ {gsub(/[^0-9]/, "", $2); print $2; exit}' "$SCRIPT")

echo "Testing claude-cluster against SCHEMA_VERSION=$expected_version"
echo ""

# ---------------------------------------------------------------------------
# Test 1: fresh install writes schema_version = SCHEMA_VERSION on first run.
# ---------------------------------------------------------------------------
echo "Test 1: fresh install lands at SCHEMA_VERSION"
fresh_home="$TMPROOT/fresh"
mkdir -p "$fresh_home"
run_isolated "$fresh_home" help

fresh_file="$fresh_home/.claude/cluster/sessions.json"
[[ -f "$fresh_file" ]] || { echo "  FAIL  sessions.json was not created"; exit 1; }

fresh_version=$(jq -r '.schema_version' "$fresh_file")
check "schema_version field present" "$expected_version" "$fresh_version"

fresh_sessions=$(jq -r '.sessions | length' "$fresh_file")
check "sessions array starts empty" "0" "$fresh_sessions"

# Capture the canonical fresh-install shape for the next test.
fresh_shape=$(jq -S . "$fresh_file")

# ---------------------------------------------------------------------------
# Test 2: legacy v0 file migrates to the SAME shape as a fresh install.
# This is the headline assertion — it fails if init_sessions and
# migrate_sessions disagree on the target shape.
# ---------------------------------------------------------------------------
echo ""
echo "Test 2: legacy v0 file migrates to the fresh-install shape"
legacy_home="$TMPROOT/legacy"
mkdir -p "$legacy_home/.claude/cluster"
echo '{"sessions": []}' > "$legacy_home/.claude/cluster/sessions.json"

run_isolated "$legacy_home" help
migrated_shape=$(jq -S . "$legacy_home/.claude/cluster/sessions.json")
check "migrated v0 shape == fresh-install shape" "$fresh_shape" "$migrated_shape"

# ---------------------------------------------------------------------------
# Test 3: migration is idempotent — re-running on already-migrated state
# changes nothing.
# ---------------------------------------------------------------------------
echo ""
echo "Test 3: migration is idempotent on up-to-date state"
run_isolated "$legacy_home" help
double_shape=$(jq -S . "$legacy_home/.claude/cluster/sessions.json")
check "second run produces no change" "$migrated_shape" "$double_shape"

# ---------------------------------------------------------------------------
# Test 4: legacy session entries survive migration intact.
# ---------------------------------------------------------------------------
echo ""
echo "Test 4: legacy sessions data is preserved through migration"
data_home="$TMPROOT/data"
mkdir -p "$data_home/.claude/cluster"
cat > "$data_home/.claude/cluster/sessions.json" <<'JSON'
{
  "sessions": [
    {
      "name": "legacy-session",
      "pid": 99999,
      "branch": "claude/legacy",
      "working_dir": "/tmp/legacy",
      "started": "2026-01-01T00:00:00Z"
    }
  ]
}
JSON

run_isolated "$data_home" help
data_file="$data_home/.claude/cluster/sessions.json"

check "session count preserved" "1" "$(jq -r '.sessions | length' "$data_file")"
check "session name preserved"  "legacy-session" "$(jq -r '.sessions[0].name'        "$data_file")"
check "session pid preserved"   "99999"          "$(jq -r '.sessions[0].pid'         "$data_file")"
check "session branch preserved" "claude/legacy" "$(jq -r '.sessions[0].branch'      "$data_file")"
check "schema_version added"    "$expected_version" "$(jq -r '.schema_version'       "$data_file")"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $pass passed, $fail failed"

if (( fail > 0 )); then
    exit 1
fi
echo "All tests passed."
