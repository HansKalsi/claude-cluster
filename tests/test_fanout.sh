#!/usr/bin/env bash

# Tests for fanout, qa, --orchestrate, and the helpers that back them.
# All tests stub state on disk; no `claude` invocations and no token-burning workers.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_DIR/claude-cluster"

if ! command -v jq &> /dev/null; then
    echo "ERROR: jq is required (brew install jq)"
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

check_contains() {
    local label="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "  PASS  $label"
        pass=$((pass + 1))
    else
        echo "  FAIL  $label"
        echo "    expected to contain: $needle"
        echo "    actual:              ${haystack:0:200}"
        fail=$((fail + 1))
    fi
}

# Run the script under a sandboxed HOME so state lands in our temp dir.
run() {
    local home="$1"
    shift
    HOME="$home" bash "$SCRIPT" "$@"
}

# Run from inside a non-git directory so fanout's "must be in a git repo" check fires.
run_outside_git() {
    local home="$1"
    shift
    (cd "$home" && HOME="$home" bash "$SCRIPT" "$@")
}

# ---------------------------------------------------------------------------
# Test 1: help text covers all new commands and flags
# ---------------------------------------------------------------------------
echo "Test 1: help text covers fanout / qa / --orchestrate"
help_home="$TMPROOT/help"
mkdir -p "$help_home"
help_out=$(run "$help_home" help 2>&1)
check_contains "help mentions fanout"        "fanout"        "$help_out"
check_contains "help mentions qa"            " qa "          "$help_out"
check_contains "help mentions --orchestrate" "--orchestrate" "$help_out"
check_contains "help mentions --approach"    "--approach"    "$help_out"
check_contains "help mentions --task"        "--task"        "$help_out"

# ---------------------------------------------------------------------------
# Test 2: fanout argument validation
# ---------------------------------------------------------------------------
echo ""
echo "Test 2: fanout rejects bad arguments"
fan_home="$TMPROOT/fanout-args"
mkdir -p "$fan_home"

out=$(run "$fan_home" fanout 2>&1 || true)
check_contains "no args -> usage"             "Usage:"             "$out"

out=$(run "$fan_home" fanout test --approach "x" 2>&1 || true)
check_contains "missing --task -> error"      "task is required"   "$out"

out=$(run "$fan_home" fanout test --task "do thing" 2>&1 || true)
check_contains "missing --approach -> error"  "approach is required" "$out"

out=$(run_outside_git "$fan_home" fanout test --task "x" --approach "a1" 2>&1 || true)
check_contains "outside git repo -> error"    "git repo"           "$out"

# ---------------------------------------------------------------------------
# Test 3: qa argument validation
# ---------------------------------------------------------------------------
echo ""
echo "Test 3: qa rejects bad arguments"
qa_home="$TMPROOT/qa-args"
mkdir -p "$qa_home"

out=$(run "$qa_home" qa 2>&1 || true)
check_contains "no args -> usage" "Usage:" "$out"

out=$(run "$qa_home" qa nonexistent --branch foo --task "criteria" 2>&1 || true)
check_contains "unknown fanout -> error" "not found" "$out"

# ---------------------------------------------------------------------------
# Test 4: status of a fanout emits structured JSON
#
# We stub a coordination dir on disk, then verify `status` reads it correctly.
# No claude or workers involved.
# ---------------------------------------------------------------------------
echo ""
echo "Test 4: status of a fanout emits parseable JSON"
status_home="$TMPROOT/fanout-status"
coord_dir="$status_home/.claude/cluster/coordination/myfanout"
mkdir -p "$coord_dir/worker-1" "$coord_dir/worker-2"

cat > "$coord_dir/meta.json" <<'JSON'
{
  "type": "fanout",
  "name": "myfanout",
  "task": "test the thing",
  "base": "main",
  "git_root": "/tmp/example",
  "repo_name": "example",
  "approaches": ["library X", "library Y"],
  "started": "2026-05-01T00:00:00Z"
}
JSON

echo "done"        > "$coord_dir/worker-1/status"
echo "library X"   > "$coord_dir/worker-1/approach.txt"
echo "summary 1"   > "$coord_dir/worker-1/summary.md"
echo "running"     > "$coord_dir/worker-2/status"
echo "library Y"   > "$coord_dir/worker-2/approach.txt"

out=$(run "$status_home" status myfanout 2>&1)

# Suppress migration logs (might appear on first invocation under fresh HOME)
json=$(echo "$out" | sed -n '/^{/,$p')

type_field=$(echo "$json" | jq -r '.type' 2>/dev/null || echo "PARSE_FAIL")
check "type=fanout"                "fanout"   "$type_field"

worker_count=$(echo "$json" | jq '.workers | length' 2>/dev/null || echo "PARSE_FAIL")
check "two workers reported"       "2"        "$worker_count"

worker1_status=$(echo "$json" | jq -r '.workers[] | select(.index==1) | .status' 2>/dev/null || echo "PARSE_FAIL")
check "worker 1 status read"       "done"     "$worker1_status"

worker1_summary_exists=$(echo "$json" | jq -r '.workers[] | select(.index==1) | .summary_exists' 2>/dev/null || echo "PARSE_FAIL")
check "worker 1 summary detected"  "true"     "$worker1_summary_exists"

worker2_status=$(echo "$json" | jq -r '.workers[] | select(.index==2) | .status' 2>/dev/null || echo "PARSE_FAIL")
check "worker 2 status read"       "running"  "$worker2_status"

worker2_summary_exists=$(echo "$json" | jq -r '.workers[] | select(.index==2) | .summary_exists' 2>/dev/null || echo "PARSE_FAIL")
check "worker 2 summary missing"   "false"    "$worker2_summary_exists"

worker1_approach=$(echo "$json" | jq -r '.workers[] | select(.index==1) | .approach' 2>/dev/null || echo "PARSE_FAIL")
check "worker 1 approach passed through" "library X" "$worker1_approach"

meta_task=$(echo "$json" | jq -r '.meta.task' 2>/dev/null || echo "PARSE_FAIL")
check "meta.task surfaced"         "test the thing"  "$meta_task"

# ---------------------------------------------------------------------------
# Test 5: kill <fanout> removes the coordination dir
# ---------------------------------------------------------------------------
echo ""
echo "Test 5: kill <fanout> removes coordination dir"
kill_home="$TMPROOT/fanout-kill"
kill_coord="$kill_home/.claude/cluster/coordination/dead"
mkdir -p "$kill_coord/worker-1"
cat > "$kill_coord/meta.json" <<'JSON'
{"type":"fanout","name":"dead","task":"x","base":"main","git_root":"/tmp/x","repo_name":"x","approaches":["a"],"started":"2026-01-01T00:00:00Z"}
JSON

run "$kill_home" kill dead > /dev/null 2>&1 || true

if [[ -d "$kill_coord" ]]; then
    coord_state="present"
else
    coord_state="removed"
fi
check "coord dir removed after kill" "removed" "$coord_state"

# ---------------------------------------------------------------------------
# Test 6: unit tests for substitute_template (sourced)
# ---------------------------------------------------------------------------
echo ""
echo "Test 6: substitute_template (sourced helper)"

# Source the script to expose its functions without running main.
# shellcheck disable=SC1090
source "$SCRIPT"

# Build a small template for testing
unit_dir="$TMPROOT/unit"
mkdir -p "$unit_dir"
cat > "$unit_dir/basic.md" <<'TPL'
Name: {name}
Task: {task}
Name again: {name}
TPL

result=$(substitute_template "$unit_dir/basic.md" name "alice" task "review code")
expected=$'Name: alice\nTask: review code\nName again: alice'
check "literal substitution + repeated key" "$expected" "$result"

# Special characters: quotes, dollar signs, backslashes, paths
cat > "$unit_dir/special.md" <<'TPL'
Path: {path}
Quote: {quote}
Dollar: {dollar}
TPL

result=$(substitute_template "$unit_dir/special.md" \
    path "/tmp/with spaces/and 'quotes'" \
    quote 'a "double" b' \
    dollar '$NOT_EXPANDED')
check_contains "substitutes quoted values"     "and 'quotes'"       "$result"
check_contains "substitutes double quotes"     'a "double" b'       "$result"
check_contains "substitutes literal dollars"   '$NOT_EXPANDED'      "$result"

# Multi-line value
cat > "$unit_dir/multi.md" <<'TPL'
Before
{block}
After
TPL

multi_value=$'line1\nline2\nline3'
result=$(substitute_template "$unit_dir/multi.md" block "$multi_value")
check_contains "multi-line values preserved"   "line1"              "$result"
check_contains "multi-line values preserved 2" "line3"              "$result"

# Missing template
out=$(substitute_template "$unit_dir/nonexistent.md" foo bar 2>&1 || true)
check_contains "missing template -> error" "Template not found" "$out"

# ---------------------------------------------------------------------------
# Test 7: unit tests for is_fanout (sourced)
# ---------------------------------------------------------------------------
echo ""
echo "Test 7: is_fanout (sourced helper)"

# Override COORDINATION_DIR for isolation
COORDINATION_DIR="$TMPROOT/coordination"
mkdir -p "$COORDINATION_DIR/has-meta"
echo '{}' > "$COORDINATION_DIR/has-meta/meta.json"
mkdir -p "$COORDINATION_DIR/no-meta"   # dir but no meta.json

if is_fanout "has-meta"; then a="yes"; else a="no"; fi
check "is_fanout: real fanout dir" "yes" "$a"

if is_fanout "no-meta"; then b="yes"; else b="no"; fi
check "is_fanout: dir without meta" "no" "$b"

if is_fanout "doesnt-exist"; then c="yes"; else c="no"; fi
check "is_fanout: nonexistent name" "no" "$c"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $pass passed, $fail failed"

if (( fail > 0 )); then
    exit 1
fi
echo "All tests passed."
