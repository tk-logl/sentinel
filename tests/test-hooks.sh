#!/bin/bash
# Sentinel Hook Test Suite
# Run: bash tests/test-hooks.sh

set -uo pipefail

# --- Test Framework ---
PASS_COUNT=0; FAIL_COUNT=0; TOTAL_COUNT=0
RED='\033[0;31m'; GREEN='\033[0;32m'; BOLD='\033[1m'; RESET='\033[0m'

_pass() { PASS_COUNT=$((PASS_COUNT+1)); TOTAL_COUNT=$((TOTAL_COUNT+1)); printf "  ${GREEN}PASS${RESET} %s\n" "$1"; }
_fail() { FAIL_COUNT=$((FAIL_COUNT+1)); TOTAL_COUNT=$((TOTAL_COUNT+1)); printf "  ${RED}FAIL${RESET} %s %s\n" "$1" "${2:-}"; }
section() { printf "\n${BOLD}--- %s ---${RESET}\n" "$1"; }

# --- Setup ---
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)/hooks/scripts"
TMPDIR_ROOT=$(mktemp -d)
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

# Create fake git project
FAKE_PROJECT="${TMPDIR_ROOT}/project"
mkdir -p "$FAKE_PROJECT"
git -C "$FAKE_PROJECT" init -q 2>/dev/null
git -C "$FAKE_PROJECT" config user.email "test@test.com"
git -C "$FAKE_PROJECT" config user.name "Test"
touch "$FAKE_PROJECT/.gitkeep"
git -C "$FAKE_PROJECT" add .gitkeep
git -C "$FAKE_PROJECT" commit -q -m "init" 2>/dev/null

# --- Helpers ---
run_hook() {
  local hook="$1"; local input="$2"
  HOOK_OUTPUT=$(echo "$input" | bash "$SCRIPT_DIR/$hook" 2>&1) || true
  HOOK_EXIT=$(echo "$input" | bash "$SCRIPT_DIR/$hook" >/dev/null 2>&1; echo $?)
}

write_json() {
  local fp="$1"; local content="$2"
  printf '{"tool_name":"Write","tool_input":{"file_path":"%s","content":"%s"}}' \
    "$fp" "$(echo "$content" | sed 's/"/\\"/g' | tr '\n' ' ')"
}

edit_json() {
  local fp="$1"; local old="$2"; local new="$3"
  # Use jq to properly encode multiline strings as JSON (preserves \n)
  local old_escaped new_escaped
  old_escaped=$(printf '%s' "$old" | jq -Rs .)
  new_escaped=$(printf '%s' "$new" | jq -Rs .)
  printf '{"tool_name":"Edit","tool_input":{"file_path":"%s","old_string":%s,"new_string":%s}}' \
    "$fp" "$old_escaped" "$new_escaped"
}

bash_json() {
  printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$(echo "$1" | sed 's/"/\\"/g')"
}

bash_post_json() {
  local cmd="$1"; local ec="${2:-0}"; local out="${3:-}"; local err="${4:-}"
  printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"tool_response":{"exit_code":%s,"stdout":"%s","stderr":"%s"}}' \
    "$(echo "$cmd" | sed 's/"/\\"/g')" "$ec" "$(echo "$out" | sed 's/"/\\"/g')" "$(echo "$err" | sed 's/"/\\"/g')"
}

post_edit_json() {
  printf '{"tool_name":"%s","tool_input":{"file_path":"%s"},"tool_response":{}}' "$1" "$2"
}

prompt_json() {
  printf '{"tool_input":{"user_prompt":"%s"}}' "$(echo "$1" | sed 's/"/\\"/g')"
}

make_project_file() {
  local ext="$1"; local content="$2"
  local fp="${FAKE_PROJECT}/src/module${ext}"
  mkdir -p "$(dirname "$fp")"
  printf '%s' "$content" > "$fp"
  echo "$fp"
}

printf "${BOLD}========================================${RESET}\n"
printf "${BOLD}  Sentinel Hook Test Suite${RESET}\n"
printf "${BOLD}========================================${RESET}\n"

# ===================================================================
section "1. deny-dummy.sh"
# ===================================================================

# standalone pass -> block
run_hook "deny-dummy.sh" "$(write_json "/app/views.py" "def foo():\n    pass")"
[[ $HOOK_EXIT -eq 2 ]] && _pass "standalone pass -> blocked" || _fail "standalone pass" "exit=$HOOK_EXIT"

# pass with @abstractmethod -> allow
run_hook "deny-dummy.sh" "$(write_json "/app/views.py" "@abstractmethod\ndef foo():\n    pass")"
[[ $HOOK_EXIT -eq 0 ]] && _pass "@abstractmethod pass -> allowed" || _fail "@abstractmethod pass" "exit=$HOOK_EXIT"

# raise NotImplementedError -> block
run_hook "deny-dummy.sh" "$(write_json "/app/views.py" "def foo():\n    raise NotImplementedError")"
[[ $HOOK_EXIT -eq 2 ]] && _pass "NotImplementedError -> blocked" || _fail "NotImplementedError" "exit=$HOOK_EXIT"

# assert True -> block
run_hook "deny-dummy.sh" "$(write_json "/app/views.py" "assert True")"
[[ $HOOK_EXIT -eq 2 ]] && _pass "assert True -> blocked" || _fail "assert True" "exit=$HOOK_EXIT"

# test file -> allow
run_hook "deny-dummy.sh" "$(write_json "/app/tests/test_views.py" "assert True")"
[[ $HOOK_EXIT -eq 0 ]] && _pass "test file -> allowed" || _fail "test file" "exit=$HOOK_EXIT"

# clean code -> allow
run_hook "deny-dummy.sh" "$(write_json "/app/views.py" "def greet(name):\n    return f'Hello {name}'")"
[[ $HOOK_EXIT -eq 0 ]] && _pass "clean code -> allowed" || _fail "clean code" "exit=$HOOK_EXIT"

# .md file -> allow (non-source)
run_hook "deny-dummy.sh" "$(write_json "/app/README.md" "# docs")"
[[ $HOOK_EXIT -eq 0 ]] && _pass ".md file -> allowed" || _fail ".md file" "exit=$HOOK_EXIT"

# ===================================================================
section "2. secret-scan.sh"
# ===================================================================

run_hook "secret-scan.sh" "$(write_json "/app/config.py" "KEY = 'sk-abc123def456ghi789jkl012mno345'")"
[[ $HOOK_EXIT -eq 2 ]] && _pass "sk- key -> blocked" || _fail "sk- key" "exit=$HOOK_EXIT"

run_hook "secret-scan.sh" "$(write_json "/app/config.py" "T = 'ghp_aBcDeFgHiJkLmNoPqRsTuVwXyZ012'")"
[[ $HOOK_EXIT -eq 2 ]] && _pass "ghp_ token -> blocked" || _fail "ghp_ token" "exit=$HOOK_EXIT"

run_hook "secret-scan.sh" "$(write_json "/app/config.py" "K = 'AKIAIOSFODNN7EXAMPLE'")"
[[ $HOOK_EXIT -eq 2 ]] && _pass "AWS AKIA -> blocked" || _fail "AWS AKIA" "exit=$HOOK_EXIT"

run_hook "secret-scan.sh" "$(write_json "/app/config.py" "import os\nKEY = os.environ.get('KEY')")"
[[ $HOOK_EXIT -eq 0 ]] && _pass "env var ref -> allowed" || _fail "env var ref" "exit=$HOOK_EXIT"

run_hook "secret-scan.sh" "$(write_json "/app/tests/test_api.py" "K = 'sk-test1234567890abcdefghij'")"
[[ $HOOK_EXIT -eq 0 ]] && _pass "test file secret -> allowed" || _fail "test file secret" "exit=$HOOK_EXIT"

# ===================================================================
section "3. env-safety.sh"
# ===================================================================

run_hook "env-safety.sh" "$(bash_json "brew install jq")"
if [[ "$(uname)" == "Linux" ]]; then
  [[ $HOOK_EXIT -eq 2 ]] && _pass "brew on Linux -> blocked" || _fail "brew on Linux" "exit=$HOOK_EXIT"
else
  _pass "brew on macOS -> skipped (platform)"
fi

run_hook "env-safety.sh" "$(bash_json "python script.py")"
[[ $HOOK_EXIT -eq 2 ]] && _pass "bare python -> blocked" || _fail "bare python" "exit=$HOOK_EXIT"

run_hook "env-safety.sh" "$(bash_json "python3 script.py")"
[[ $HOOK_EXIT -eq 0 ]] && _pass "python3 -> allowed" || _fail "python3" "exit=$HOOK_EXIT"

run_hook "env-safety.sh" "$(bash_json "git commit --no-verify -m msg")"
[[ $HOOK_EXIT -eq 2 ]] && _pass "--no-verify -> blocked" || _fail "--no-verify" "exit=$HOOK_EXIT"

run_hook "env-safety.sh" "$(bash_json "ls -la")"
[[ $HOOK_EXIT -eq 0 ]] && _pass "ls -la -> allowed" || _fail "ls -la" "exit=$HOOK_EXIT"

# ===================================================================
section "4. pre-edit-gate.sh"
# ===================================================================

GATE_PROJ="${TMPDIR_ROOT}/gate-proj"
mkdir -p "$GATE_PROJ/src"
git -C "$GATE_PROJ" init -q 2>/dev/null
git -C "$GATE_PROJ" config user.email "t@t.com"
git -C "$GATE_PROJ" config user.name "T"
touch "$GATE_PROJ/.gitkeep" "$GATE_PROJ/src/app.py"
git -C "$GATE_PROJ" add -A
git -C "$GATE_PROJ" commit -q -m "init" 2>/dev/null
GT="${GATE_PROJ}/src/app.py"

# No task file -> block
( cd "$GATE_PROJ"; run_hook "pre-edit-gate.sh" "$(write_json "$GT" "x = 1")"
  [[ $HOOK_EXIT -eq 2 ]] && _pass "no task file -> blocked" || _fail "no task file" "exit=$HOOK_EXIT" )

# Valid task file -> allow
mkdir -p "${GATE_PROJ}/.sentinel"
cat > "${GATE_PROJ}/.sentinel/current-task.json" << 'EOF'
{"task_id":"T-1","why":"fix","approach":"A","impact_files":["a.py"],"blast_radius":{"tests_break":[],"tests_add":[]},"verify_command":"pytest"}
EOF
( cd "$GATE_PROJ"; run_hook "pre-edit-gate.sh" "$(write_json "$GT" "x = 1")"
  [[ $HOOK_EXIT -eq 0 ]] && _pass "valid task -> allowed" || _fail "valid task" "exit=$HOOK_EXIT" )

# Missing fields -> block
echo '{"task_id":"T-2","why":"r"}' > "${GATE_PROJ}/.sentinel/current-task.json"
( cd "$GATE_PROJ"; run_hook "pre-edit-gate.sh" "$(write_json "$GT" "x = 1")"
  [[ $HOOK_EXIT -eq 2 ]] && _pass "missing fields -> blocked" || _fail "missing fields" "exit=$HOOK_EXIT" )

# Test file -> allow (skip gate)
( cd "$GATE_PROJ"; run_hook "pre-edit-gate.sh" "$(write_json "${GATE_PROJ}/tests/test_x.py" "x")"
  [[ $HOOK_EXIT -eq 0 ]] && _pass "test file -> gate skipped" || _fail "test file" "exit=$HOOK_EXIT" )

# .md file -> allow
( cd "$GATE_PROJ"; run_hook "pre-edit-gate.sh" "$(write_json "${GATE_PROJ}/README.md" "docs")"
  [[ $HOOK_EXIT -eq 0 ]] && _pass ".md -> non-source skipped" || _fail ".md" "exit=$HOOK_EXIT" )

# ===================================================================
section "5. surgical-change.sh"
# ===================================================================

BIG_OLD=$(printf 'line %d\n' $(seq 1 20))
run_hook "surgical-change.sh" "$(edit_json "/app/views.py" "$BIG_OLD" "x = 1")"
[[ $HOOK_EXIT -eq 0 ]] && echo "$HOOK_OUTPUT" | grep -qi "Large" \
  && _pass ">15 lines -> warning" || _fail ">15 lines warning" "exit=$HOOK_EXIT"

SMALL_OLD=$(printf 'line %d\n' $(seq 1 5))
run_hook "surgical-change.sh" "$(edit_json "/app/views.py" "$SMALL_OLD" "x = 1")"
[[ $HOOK_EXIT -eq 0 ]] && ! echo "$HOOK_OUTPUT" | grep -qi "Large" \
  && _pass "<15 lines -> no warning" || _fail "<15 lines" "exit=$HOOK_EXIT"

# ===================================================================
section "6. scope-guard.sh"
# ===================================================================

run_hook "scope-guard.sh" "$(prompt_json "just use a placeholder for the API")"
[[ $HOOK_EXIT -eq 0 ]] && echo "$HOOK_OUTPUT" | grep -qi "Scope" \
  && _pass "'placeholder' -> warning" || _fail "placeholder" "exit=$HOOK_EXIT"

run_hook "scope-guard.sh" "$(prompt_json "skip the test, will add later")"
[[ $HOOK_EXIT -eq 0 ]] && echo "$HOOK_OUTPUT" | grep -qi "Scope" \
  && _pass "'will add later' -> warning" || _fail "will add later" "exit=$HOOK_EXIT"

run_hook "scope-guard.sh" "$(prompt_json "fix the login bug where passwords are not hashed")"
[[ $HOOK_EXIT -eq 0 ]] && ! echo "$HOOK_OUTPUT" | grep -qi "Scope" \
  && _pass "normal prompt -> no warning" || _fail "normal prompt" "exit=$HOOK_EXIT"

# ===================================================================
section "7. post-edit-verify.sh"
# ===================================================================

BARE_F=$(make_project_file ".py" "$(printf 'from __future__ import annotations\ndef r() -> None:\n    try:\n        x = 1\n    except:\n        return\n')")
run_hook "post-edit-verify.sh" "$(post_edit_json "Edit" "$BARE_F")"
[[ $HOOK_EXIT -eq 0 ]] && echo "$HOOK_OUTPUT" | grep -qi "except" \
  && _pass "bare except -> warning" || _fail "bare except" "exit=$HOOK_EXIT"

CLEAN_F=$(make_project_file ".py" "$(printf 'from __future__ import annotations\ndef g(n: str) -> str:\n    return f\"Hi {n}\"\n')")
run_hook "post-edit-verify.sh" "$(post_edit_json "Edit" "$CLEAN_F")"
[[ $HOOK_EXIT -eq 0 ]] && _pass "clean file -> exit 0" || _fail "clean file" "exit=$HOOK_EXIT"

# ===================================================================
section "8. error-logger.sh"
# ===================================================================

ERR_PROJ="${TMPDIR_ROOT}/err-proj"
mkdir -p "$ERR_PROJ"
git -C "$ERR_PROJ" init -q 2>/dev/null
git -C "$ERR_PROJ" config user.email "t@t.com"
git -C "$ERR_PROJ" config user.name "T"
touch "$ERR_PROJ/.gitkeep"; git -C "$ERR_PROJ" add -A; git -C "$ERR_PROJ" commit -q -m "init" 2>/dev/null

( cd "$ERR_PROJ"; run_hook "error-logger.sh" "$(bash_post_json "pytest" 1 "" "FAILED")"
  [[ $HOOK_EXIT -eq 0 ]] && [[ -f "${ERR_PROJ}/.sentinel/error-log.jsonl" ]] \
    && _pass "exit=1 -> log created" || _fail "exit=1 log" "exit=$HOOK_EXIT" )

( cd "$ERR_PROJ"
  B=$(wc -l < "${ERR_PROJ}/.sentinel/error-log.jsonl" 2>/dev/null || echo 0)
  run_hook "error-logger.sh" "$(bash_post_json "ls" 0 "ok" "")"
  A=$(wc -l < "${ERR_PROJ}/.sentinel/error-log.jsonl" 2>/dev/null || echo 0)
  [[ $A -eq $B ]] && _pass "exit=0 -> no log" || _fail "exit=0 log" "B=$B A=$A" )

# ===================================================================
section "9. file-header-check.sh"
# ===================================================================

LONG_F=$(make_project_file ".py" "$(printf 'x = %d\n' $(seq 1 300))")
run_hook "file-header-check.sh" "$(post_edit_json "Edit" "$LONG_F")"
[[ $HOOK_EXIT -eq 0 ]] && echo "$HOOK_OUTPUT" | grep -qi "header" \
  && _pass "300-line no header -> warning" || _fail "300-line" "exit=$HOOK_EXIT"

SHORT_F=$(make_project_file ".py" "$(printf 'x = %d\n' $(seq 1 50))")
run_hook "file-header-check.sh" "$(post_edit_json "Edit" "$SHORT_F")"
[[ $HOOK_EXIT -eq 0 ]] && ! echo "$HOOK_OUTPUT" | grep -qi "header" \
  && _pass "50-line -> no warning" || _fail "50-line" "exit=$HOOK_EXIT"

# ===================================================================
section "10. completion-check.sh"
# ===================================================================

CK_PROJ="${TMPDIR_ROOT}/ck-proj"
mkdir -p "$CK_PROJ"
git -C "$CK_PROJ" init -q 2>/dev/null
git -C "$CK_PROJ" config user.email "t@t.com"
git -C "$CK_PROJ" config user.name "T"
touch "$CK_PROJ/.gitkeep"; git -C "$CK_PROJ" add -A; git -C "$CK_PROJ" commit -q -m "init" 2>/dev/null

( cd "$CK_PROJ"; run_hook "completion-check.sh" "{}"
  [[ $HOOK_EXIT -eq 0 ]] && echo "$HOOK_OUTPUT" | grep -qi "No issues" \
    && _pass "clean -> 'No issues detected'" || _fail "completion clean" "exit=$HOOK_EXIT" )

# ===================================================================
section "11. session-init.sh"
# ===================================================================

( cd "$FAKE_PROJECT"; run_hook "session-init.sh" "{}"
  [[ $HOOK_EXIT -eq 0 ]] && _pass "session-init -> exit 0" || _fail "session-init" "exit=$HOOK_EXIT" )

( cd "$FAKE_PROJECT"
  OUT=$(echo "{}" | bash "$SCRIPT_DIR/session-init.sh" 2>&1) || true
  echo "$OUT" | grep -qi "Sentinel" \
    && _pass "session-init -> banner" || _fail "session-init banner" )

# ===================================================================
section "12. state-preserve.sh"
# ===================================================================

SP_PROJ="${TMPDIR_ROOT}/sp-proj"
mkdir -p "$SP_PROJ"
git -C "$SP_PROJ" init -q 2>/dev/null
git -C "$SP_PROJ" config user.email "t@t.com"
git -C "$SP_PROJ" config user.name "T"
touch "$SP_PROJ/.gitkeep"; git -C "$SP_PROJ" add -A; git -C "$SP_PROJ" commit -q -m "init" 2>/dev/null

( cd "$SP_PROJ"; run_hook "state-preserve.sh" "{}"
  [[ $HOOK_EXIT -eq 0 ]] && [[ -f "${SP_PROJ}/.sentinel/state/latest.md" ]] \
    && _pass "state-preserve -> latest.md created" || _fail "state-preserve" "exit=$HOOK_EXIT" )

( cd "$SP_PROJ"; run_hook "state-preserve.sh" "{}"
  grep -q "## 1. Session Intent" "${SP_PROJ}/.sentinel/state/latest.md" 2>/dev/null \
    && _pass "state-preserve -> 5-section format" || _fail "5-section" )

# ===================================================================
section "13. session-save.sh"
# ===================================================================

SS_PROJ="${TMPDIR_ROOT}/ss-proj"
mkdir -p "$SS_PROJ"
git -C "$SS_PROJ" init -q 2>/dev/null
git -C "$SS_PROJ" config user.email "t@t.com"
git -C "$SS_PROJ" config user.name "T"
touch "$SS_PROJ/.gitkeep"; git -C "$SS_PROJ" add -A; git -C "$SS_PROJ" commit -q -m "init" 2>/dev/null

( cd "$SS_PROJ"; run_hook "session-save.sh" "{}"
  [[ $HOOK_EXIT -eq 0 ]] && [[ -f "${SS_PROJ}/.sentinel/state/latest.md" ]] \
    && _pass "session-save -> latest.md created" || _fail "session-save" "exit=$HOOK_EXIT" )

( cd "$SS_PROJ"; run_hook "session-save.sh" "{}"
  grep -qi "session.end\|Session End" "${SS_PROJ}/.sentinel/state/latest.md" 2>/dev/null \
    && _pass "session-save -> session-end marker" || _fail "session-end marker" )

# ===================================================================
printf "\n${BOLD}========================================${RESET}\n"
printf "${BOLD}Results: %d total | ${GREEN}%d passed${RESET} | ${RED}%d failed${RESET}\n" \
  "$TOTAL_COUNT" "$PASS_COUNT" "$FAIL_COUNT"
printf "${BOLD}========================================${RESET}\n\n"

[[ $FAIL_COUNT -gt 0 ]] && exit 1
exit 0
