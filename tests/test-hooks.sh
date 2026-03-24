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
TMPDIR_ROOT=$(cd "$TMPDIR_ROOT" && pwd -P)  # Resolve symlinks (macOS /var -> /private/var)
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
mkdir -p "${GATE_PROJ}/.sentinel/specs"
cat > "${GATE_PROJ}/.sentinel/current-task.json" << 'EOF'
{"task_id":"T-1","why":"fix","approach":"A","impact_files":["a.py"],"blast_radius":{"tests_break":[],"tests_add":[]},"verify_command":"pytest"}
EOF
cat > "${GATE_PROJ}/.sentinel/specs/T-1.json" << 'EOF'
{"task_id":"T-1","module":"src/app.py","functions":["main"],"behavior":[{"id":"B1","given":"input","when":"called","then":"returns","assert":"result == True"}]}
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
[[ $HOOK_EXIT -eq 0 ]] && echo "$HOOK_OUTPUT" | grep -qi "Scope reduction" \
  && _pass "'placeholder' -> warning" || _fail "placeholder" "exit=$HOOK_EXIT"

run_hook "scope-guard.sh" "$(prompt_json "skip the test, will add later")"
[[ $HOOK_EXIT -eq 0 ]] && echo "$HOOK_OUTPUT" | grep -qi "Scope reduction" \
  && _pass "'will add later' -> warning" || _fail "will add later" "exit=$HOOK_EXIT"

run_hook "scope-guard.sh" "$(prompt_json "fix the login bug where passwords are not hashed")"
[[ $HOOK_EXIT -eq 0 ]] && ! echo "$HOOK_OUTPUT" | grep -qi "Scope reduction" \
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
[[ $HOOK_EXIT -eq 0 ]] && echo "$HOOK_OUTPUT" | grep -qi "has no header" \
  && _pass "300-line no header -> warning" || _fail "300-line" "exit=$HOOK_EXIT"

SHORT_F=$(make_project_file ".py" "$(printf 'x = %d\n' $(seq 1 50))")
run_hook "file-header-check.sh" "$(post_edit_json "Edit" "$SHORT_F")"
[[ $HOOK_EXIT -eq 0 ]] && ! echo "$HOOK_OUTPUT" | grep -qi "has no header" \
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
section "14. task-scope-guard.sh"
# ===================================================================

# Use jq for proper multiline JSON (prompt_json flattens newlines)
TSG_INPUT=$(printf '1. Fix login\n2. Add tests\n3. Deploy' | jq -Rs '{"tool_input":{"user_prompt":.}}')
run_hook "task-scope-guard.sh" "$TSG_INPUT"
[[ $HOOK_EXIT -eq 0 ]] && echo "$HOOK_OUTPUT" | grep -qi "items\|scope\|complete" \
  && _pass "numbered list -> enforcement" || _fail "numbered list" "exit=$HOOK_EXIT"

run_hook "task-scope-guard.sh" "$(prompt_json "fix the login bug")"
[[ $HOOK_EXIT -eq 0 ]] && ! echo "$HOOK_OUTPUT" | grep -qi "items" \
  && _pass "single request -> no enforcement" || _fail "single request" "exit=$HOOK_EXIT"

# ===================================================================
section "15. scope-reduction-guard.sh"
# ===================================================================

run_hook "scope-reduction-guard.sh" "$(edit_json "/app/views.py" "old" "# 일단 기본만 구현\ndef foo(): pass")"
[[ $HOOK_EXIT -eq 2 ]] && _pass "Korean scope reduction -> blocked" || _fail "Korean scope reduction" "exit=$HOOK_EXIT"

run_hook "scope-reduction-guard.sh" "$(edit_json "/app/views.py" "old" "# simplified version for now\ndef foo(): pass")"
[[ $HOOK_EXIT -eq 2 ]] && _pass "English scope reduction -> blocked" || _fail "English scope reduction" "exit=$HOOK_EXIT"

run_hook "scope-reduction-guard.sh" "$(edit_json "/app/views.py" "old" "# Production handler\ndef foo(): return 42")"
[[ $HOOK_EXIT -eq 0 ]] && _pass "normal comment -> allowed" || _fail "normal comment" "exit=$HOOK_EXIT"

# ===================================================================
section "16. task-automark.sh"
# ===================================================================

AM_PROJ="${TMPDIR_ROOT}/am-proj"
mkdir -p "$AM_PROJ/.sentinel"
git -C "$AM_PROJ" init -q 2>/dev/null
git -C "$AM_PROJ" config user.email "t@t.com"
git -C "$AM_PROJ" config user.name "T"
cat > "$AM_PROJ/tasks.md" << 'TASKS'
- [ ] **CRIT-1** — fix crash
- [ ] **CRIT-2** — fix auth
TASKS
git -C "$AM_PROJ" add -A; git -C "$AM_PROJ" commit -q -m "init" 2>/dev/null

( cd "$AM_PROJ"; run_hook "task-automark.sh" "$(bash_post_json "git commit -m 'fix: CRIT-1 crash resolved'" 0 "[main abc1234] fix: CRIT-1 crash resolved" "")"
  grep -q '\[x\].*CRIT-1' "$AM_PROJ/tasks.md" 2>/dev/null \
    && _pass "git commit CRIT-1 -> marked [x]" || _fail "task-automark" )

( cd "$AM_PROJ"; grep -q '\[ \].*CRIT-2' "$AM_PROJ/tasks.md" 2>/dev/null \
    && _pass "CRIT-2 -> still [ ]" || _fail "CRIT-2 unchanged" )

# ===================================================================
section "17. task-completion-gate.sh"
# ===================================================================

( cd "$FAKE_PROJECT"; run_hook "task-completion-gate.sh" '{"tool_name":"TaskUpdate","tool_input":{"taskId":"5","status":"completed"}}'
  [[ $HOOK_EXIT -eq 0 ]] && echo "$HOOK_OUTPUT" | grep -qi "completion\|evidence" \
    && _pass "completed -> evidence check" || _fail "completion gate" "exit=$HOOK_EXIT" )

( cd "$FAKE_PROJECT"; run_hook "task-completion-gate.sh" '{"tool_name":"TaskUpdate","tool_input":{"taskId":"5","status":"in_progress"}}'
  [[ $HOOK_EXIT -eq 0 ]] && ! echo "$HOOK_OUTPUT" | grep -qi "evidence" \
    && _pass "in_progress -> skip" || _fail "skip non-completed" "exit=$HOOK_EXIT" )

# ===================================================================
section "18. subagent-context.sh"
# ===================================================================

( cd "$FAKE_PROJECT"; run_hook "subagent-context.sh" '{"tool_name":"Task","tool_input":{"subagent_type":"executor"}}'
  [[ $HOOK_EXIT -eq 0 ]] && echo "$HOOK_OUTPUT" | grep -qi "Quality Rules" \
    && _pass "Task spawn -> rules injected" || _fail "subagent-context" "exit=$HOOK_EXIT" )

( cd "$FAKE_PROJECT"; run_hook "subagent-context.sh" '{"tool_name":"Bash","tool_input":{"command":"ls"}}'
  [[ $HOOK_EXIT -eq 0 ]] && ! echo "$HOOK_OUTPUT" | grep -qi "Quality" \
    && _pass "non-Task -> skip" || _fail "subagent skip" "exit=$HOOK_EXIT" )

# ===================================================================
section "19. post-compact-restore.sh"
# ===================================================================

PC_PROJ="${TMPDIR_ROOT}/pc-proj"
mkdir -p "$PC_PROJ/.sentinel/state"
git -C "$PC_PROJ" init -q 2>/dev/null
git -C "$PC_PROJ" config user.email "t@t.com"
git -C "$PC_PROJ" config user.name "T"
touch "$PC_PROJ/.gitkeep"; git -C "$PC_PROJ" add -A; git -C "$PC_PROJ" commit -q -m "init" 2>/dev/null

# Create a pre-compaction state
cat > "$PC_PROJ/.sentinel/state/latest.md" << 'STATE'
## 1. Session Intent
Working on CRIT-1 fix

## 2. Modified Files
- main.py

## 3. Decisions Made
Using approach A

## 4. Current State
Branch: main

## 5. Next Steps
Fix CRIT-2

## RECOVERY INSTRUCTIONS:
Read this first.
STATE

( cd "$PC_PROJ"; run_hook "post-compact-restore.sh" '{"compact_summary":"Context was compacted"}'
  [[ $HOOK_EXIT -eq 0 ]] && echo "$HOOK_OUTPUT" | grep -qi "Context Restore" \
    && _pass "post-compact -> context restored" || _fail "post-compact" "exit=$HOOK_EXIT" )

( cd "$PC_PROJ"; ls "$PC_PROJ/.sentinel/state/" | grep -q "compact-" \
    && _pass "compact_summary -> saved" || _fail "compact_summary save" )

# ===================================================================
section "20. build-context-map.py"
# ===================================================================

CM_PROJ="${TMPDIR_ROOT}/cm-proj"
mkdir -p "$CM_PROJ/.sentinel"
git -C "$CM_PROJ" init -q 2>/dev/null
git -C "$CM_PROJ" config user.email "t@t.com"
git -C "$CM_PROJ" config user.name "T"
cat > "$CM_PROJ/app.py" << 'PYFILE'
from abc import ABC, abstractmethod
class Base(ABC):
    @abstractmethod
    def handle(self):
        pass
    def cleanup(self):
        pass
def real():
    return 42
PYFILE
git -C "$CM_PROJ" add -A; git -C "$CM_PROJ" commit -q -m "init" 2>/dev/null

python3 "$SCRIPT_DIR/build-context-map.py" --root "$CM_PROJ" --max-files 10 >/dev/null 2>&1
[[ -f "$CM_PROJ/.sentinel/context-map.json" ]] \
  && _pass "context-map.json created" || _fail "context-map creation"

jq -r '.files["app.py"].functions["Base.handle"].classification' "$CM_PROJ/.sentinel/context-map.json" 2>/dev/null | grep -q "abstract" \
  && _pass "@abstractmethod -> abstract" || _fail "abstract classification"

jq -r '.files["app.py"].functions["real"].classification' "$CM_PROJ/.sentinel/context-map.json" 2>/dev/null | grep -q "implemented" \
  && _pass "real function -> implemented" || _fail "implemented classification"

# ===================================================================
section "21. state-extract-intent.py"
# ===================================================================

INTENT_FILE="${TMPDIR_ROOT}/transcript.jsonl"
printf '{"role":"user","content":"Fix the login bug"}\n' > "$INTENT_FILE"
printf '{"role":"assistant","content":"Working on it"}\n' >> "$INTENT_FILE"
printf '{"role":"user","content":"Also add rate limiting"}\n' >> "$INTENT_FILE"

INTENT_OUT=$(python3 "$SCRIPT_DIR/state-extract-intent.py" "$INTENT_FILE" 2>/dev/null)
echo "$INTENT_OUT" | grep -q "Fix the login bug" \
  && _pass "intent: user msg 1 extracted" || _fail "intent extraction 1"

echo "$INTENT_OUT" | grep -q "rate limiting" \
  && _pass "intent: user msg 2 extracted" || _fail "intent extraction 2"

! echo "$INTENT_OUT" | grep -q "Working on it" \
  && _pass "intent: assistant filtered out" || _fail "intent assistant filter"


# ===================================================================
section "22. sentinel_is_source_file — config-driven extensions"
# ===================================================================

# Create a project with custom config that adds .rb and .kt extensions
ISF_PROJ="${TMPDIR_ROOT}/isf-proj"
mkdir -p "$ISF_PROJ/.sentinel" "$ISF_PROJ/src"
git -C "$ISF_PROJ" init -q 2>/dev/null
git -C "$ISF_PROJ" config user.email "t@t.com"
git -C "$ISF_PROJ" config user.name "T"
cat > "$ISF_PROJ/.sentinel/config.json" << 'ISFC'
{
  "source_extensions": ["py", "ts", "tsx", "js", "jsx", "go", "rs", "java", "c", "cpp", "svelte", "vue", "rb", "kt"],
  "enforcement": {}
}
ISFC
touch "$ISF_PROJ/.gitkeep"; git -C "$ISF_PROJ" add -A; git -C "$ISF_PROJ" commit -q -m "init" 2>/dev/null

# .py is source -> deny-dummy blocks TODO comment
( cd "$ISF_PROJ"; run_hook "deny-dummy.sh" "$(write_json "/app/views.py" "# TODO: implement later\ndef foo(): return 42")"
  [[ $HOOK_EXIT -eq 2 ]] && _pass "is_source_file: .py TODO -> blocked" || _fail "is_source_file .py" "exit=$HOOK_EXIT" )

# .md is NOT source -> deny-dummy allows anything
( cd "$ISF_PROJ"; run_hook "deny-dummy.sh" "$(write_json "/app/README.md" "# TODO: write docs")"
  [[ $HOOK_EXIT -eq 0 ]] && _pass "is_source_file: .md -> allowed (non-source)" || _fail "is_source_file .md" "exit=$HOOK_EXIT" )

# .json is NOT source -> deny-dummy allows
( cd "$ISF_PROJ"; run_hook "deny-dummy.sh" "$(write_json "/app/config.json" "TODO")"
  [[ $HOOK_EXIT -eq 0 ]] && _pass "is_source_file: .json -> allowed (non-source)" || _fail "is_source_file .json" "exit=$HOOK_EXIT" )

# ===================================================================
section "23. sentinel_should_skip — config-driven skip_patterns"
# ===================================================================

SSK_PROJ="${TMPDIR_ROOT}/ssk-proj"
mkdir -p "$SSK_PROJ/.sentinel" "$SSK_PROJ/src" "$SSK_PROJ/generated"
git -C "$SSK_PROJ" init -q 2>/dev/null
git -C "$SSK_PROJ" config user.email "t@t.com"
git -C "$SSK_PROJ" config user.name "T"
cat > "$SSK_PROJ/.sentinel/config.json" << 'SSKC'
{
  "source_extensions": ["py", "ts", "tsx", "js", "jsx", "go", "rs", "java", "c", "cpp", "svelte", "vue"],
  "skip_patterns": [
    "**/generated/**",
    "**/*.generated.py",
    "**/vendor/**",
    "**/test_*",
    "**/*.test.*",
    "**/*.spec.*",
    "**/tests/**"
  ],
  "enforcement": {}
}
SSKC
touch "$SSK_PROJ/.gitkeep"; git -C "$SSK_PROJ" add -A; git -C "$SSK_PROJ" commit -q -m "init" 2>/dev/null

# File in generated/ -> should be skipped -> deny-dummy allows pass
( cd "$SSK_PROJ"; run_hook "deny-dummy.sh" "$(write_json "${SSK_PROJ}/generated/schema.py" "def foo():\n    pass")"
  [[ $HOOK_EXIT -eq 0 ]] && _pass "should_skip: generated/ -> skipped" || _fail "should_skip generated/" "exit=$HOOK_EXIT" )

# File matching *.generated.py -> should be skipped
( cd "$SSK_PROJ"; run_hook "deny-dummy.sh" "$(write_json "${SSK_PROJ}/src/models.generated.py" "def foo():\n    pass")"
  [[ $HOOK_EXIT -eq 0 ]] && _pass "should_skip: *.generated.py -> skipped" || _fail "should_skip .generated.py" "exit=$HOOK_EXIT" )

# Normal source file -> NOT skipped -> deny-dummy blocks pass
( cd "$SSK_PROJ"; run_hook "deny-dummy.sh" "$(write_json "${SSK_PROJ}/src/views.py" "def foo():\n    pass")"
  [[ $HOOK_EXIT -eq 2 ]] && _pass "should_skip: src/views.py -> NOT skipped, blocked" || _fail "should_skip normal file" "exit=$HOOK_EXIT" )

# Built-in skip: .sentinel/ -> always skipped regardless of config
( cd "$SSK_PROJ"; run_hook "deny-dummy.sh" "$(write_json "${SSK_PROJ}/.sentinel/internal.py" "def foo():\n    pass")"
  [[ $HOOK_EXIT -eq 0 ]] && _pass "should_skip: .sentinel/ -> always skipped" || _fail "should_skip .sentinel" "exit=$HOOK_EXIT" )

# Built-in skip: fixtures/ directory
( cd "$SSK_PROJ"; run_hook "deny-dummy.sh" "$(write_json "${SSK_PROJ}/fixtures/sample.py" "def foo():\n    pass")"
  [[ $HOOK_EXIT -eq 0 ]] && _pass "should_skip: fixtures/ -> always skipped" || _fail "should_skip fixtures" "exit=$HOOK_EXIT" )

# ===================================================================
section "24. deny-dummy + context-map integration (end-to-end)"
# ===================================================================

DCTX_PROJ="${TMPDIR_ROOT}/dctx-proj"
mkdir -p "$DCTX_PROJ/.sentinel" "$DCTX_PROJ/src"
git -C "$DCTX_PROJ" init -q 2>/dev/null
git -C "$DCTX_PROJ" config user.email "t@t.com"
git -C "$DCTX_PROJ" config user.name "T"
cat > "$DCTX_PROJ/.sentinel/config.json" << 'DCTXC'
{
  "source_extensions": ["py"],
  "enforcement": {}
}
DCTXC

cat > "$DCTX_PROJ/.sentinel/context-map.json" << 'CTXMAP'
{
  "version": "1.0",
  "files": {
    "src/handler.py": {
      "language": "python",
      "line_count": 50,
      "functions": {
        "Base.handle": {"body": "pass_only", "classification": "abstract", "line": 5},
        "Cleanup.close": {"body": "pass_only", "classification": "intentional_noop", "line": 15}
      }
    }
  }
}
CTXMAP
touch "$DCTX_PROJ/.gitkeep"; git -C "$DCTX_PROJ" add -A; git -C "$DCTX_PROJ" commit -q -m "init" 2>/dev/null

# Abstract method pass -> ALLOWED (context-map says abstract)
( cd "$DCTX_PROJ"; run_hook "deny-dummy.sh" "$(write_json "${DCTX_PROJ}/src/handler.py" "class Base:\n    def handle(self):\n        pass")"
  [[ $HOOK_EXIT -eq 0 ]] && _pass "context-map: abstract pass -> allowed" || _fail "context-map abstract" "exit=$HOOK_EXIT" )

# Intentional noop pass -> ALLOWED
( cd "$DCTX_PROJ"; run_hook "deny-dummy.sh" "$(write_json "${DCTX_PROJ}/src/handler.py" "class Cleanup:\n    def close(self):\n        pass")"
  [[ $HOOK_EXIT -eq 0 ]] && _pass "context-map: intentional_noop pass -> allowed" || _fail "context-map noop" "exit=$HOOK_EXIT" )

# Lock file present -> context-map NOT used (building in progress)
touch "$DCTX_PROJ/.sentinel/context-map.building"
( cd "$DCTX_PROJ"; run_hook "deny-dummy.sh" "$(write_json "${DCTX_PROJ}/src/handler.py" "class Base:\n    def handle(self):\n        pass")"
  [[ $HOOK_EXIT -eq 2 ]] && _pass "context-map: lock file -> NOT used, pass blocked" || _fail "context-map lock" "exit=$HOOK_EXIT" )
rm -f "$DCTX_PROJ/.sentinel/context-map.building"

# ===================================================================
section "25. error-logger — PostToolUseFailure + is_interrupt"
# ===================================================================

ELF_PROJ="${TMPDIR_ROOT}/elf-proj"
mkdir -p "$ELF_PROJ"
git -C "$ELF_PROJ" init -q 2>/dev/null
git -C "$ELF_PROJ" config user.email "t@t.com"
git -C "$ELF_PROJ" config user.name "T"
touch "$ELF_PROJ/.gitkeep"; git -C "$ELF_PROJ" add -A; git -C "$ELF_PROJ" commit -q -m "init" 2>/dev/null

# PostToolUseFailure for non-Bash tool (Read tool failed)
( cd "$ELF_PROJ"
  INPUT='{"tool_name":"Read","error":"File not found: /nonexistent/path.py"}'
  run_hook "error-logger.sh" "$INPUT"
  [[ $HOOK_EXIT -eq 0 ]] && [[ -f "${ELF_PROJ}/.sentinel/error-log.jsonl" ]] \
    && _pass "PostToolUseFailure: Read error -> logged" || _fail "PostToolUseFailure Read" "exit=$HOOK_EXIT" )

# Verify error type is "tool-failure"
( cd "$ELF_PROJ"
  LAST_TYPE=$(tail -1 "${ELF_PROJ}/.sentinel/error-log.jsonl" 2>/dev/null | jq -r '.type' 2>/dev/null)
  [[ "$LAST_TYPE" == "tool-failure" ]] \
    && _pass "PostToolUseFailure: type=tool-failure" || _fail "PostToolUseFailure type" "got=$LAST_TYPE" )

# Verify cmd field contains the tool name
( cd "$ELF_PROJ"
  LAST_CMD=$(tail -1 "${ELF_PROJ}/.sentinel/error-log.jsonl" 2>/dev/null | jq -r '.cmd' 2>/dev/null)
  [[ "$LAST_CMD" == "Read" ]] \
    && _pass "PostToolUseFailure: cmd=Read" || _fail "PostToolUseFailure cmd" "got=$LAST_CMD" )

# is_interrupt: true -> silently skip, no log entry
( cd "$ELF_PROJ"
  BEFORE=$(wc -l < "${ELF_PROJ}/.sentinel/error-log.jsonl" 2>/dev/null || echo 0)
  INPUT='{"tool_name":"Bash","is_interrupt":true,"tool_input":{"command":"sleep 999"},"tool_response":{"exit_code":130}}'
  run_hook "error-logger.sh" "$INPUT"
  AFTER=$(wc -l < "${ELF_PROJ}/.sentinel/error-log.jsonl" 2>/dev/null || echo 0)
  [[ $AFTER -eq $BEFORE ]] \
    && _pass "is_interrupt: true -> no log entry" || _fail "is_interrupt skip" "before=$BEFORE after=$AFTER" )

# Non-Bash tool with no error field -> silently skip
( cd "$ELF_PROJ"
  BEFORE=$(wc -l < "${ELF_PROJ}/.sentinel/error-log.jsonl" 2>/dev/null || echo 0)
  INPUT='{"tool_name":"Glob","tool_input":{"pattern":"*.py"}}'
  run_hook "error-logger.sh" "$INPUT"
  AFTER=$(wc -l < "${ELF_PROJ}/.sentinel/error-log.jsonl" 2>/dev/null || echo 0)
  [[ $AFTER -eq $BEFORE ]] \
    && _pass "non-Bash no error -> no log entry" || _fail "non-Bash no error" "before=$BEFORE after=$AFTER" )

# Bash with exit_code=0 -> no log
( cd "$ELF_PROJ"
  BEFORE=$(wc -l < "${ELF_PROJ}/.sentinel/error-log.jsonl" 2>/dev/null || echo 0)
  run_hook "error-logger.sh" "$(bash_post_json "ls" 0 "file1 file2" "")"
  AFTER=$(wc -l < "${ELF_PROJ}/.sentinel/error-log.jsonl" 2>/dev/null || echo 0)
  [[ $AFTER -eq $BEFORE ]] \
    && _pass "Bash exit=0 -> no log entry" || _fail "Bash exit=0" "before=$BEFORE after=$AFTER" )

# ===================================================================
section "26. completion-check — dynamic extensions from config"
# ===================================================================

DYN_PROJ="${TMPDIR_ROOT}/dyn-proj"
mkdir -p "$DYN_PROJ/.sentinel"
git -C "$DYN_PROJ" init -q 2>/dev/null
git -C "$DYN_PROJ" config user.email "t@t.com"
git -C "$DYN_PROJ" config user.name "T"
cat > "$DYN_PROJ/.sentinel/config.json" << 'DYNCONF'
{
  "source_extensions": ["py", "rb"],
  "enforcement": {}
}
DYNCONF
touch "$DYN_PROJ/.gitkeep"; git -C "$DYN_PROJ" add -A; git -C "$DYN_PROJ" commit -q -m "init" 2>/dev/null

# Create uncommitted .rb file -> completion-check should detect it as source
echo "puts 'hello'" > "$DYN_PROJ/app.rb"
( cd "$DYN_PROJ"
  run_hook "completion-check.sh" "{}"
  echo "$HOOK_OUTPUT" | grep -qi "UNCOMMITTED\|source file" \
    && _pass "completion-check: .rb detected as uncommitted source" || _fail "completion-check .rb" )

# Clean project -> no issues
rm -f "$DYN_PROJ/app.rb"
rm -f "$DYN_PROJ/.sentinel/.completion-check-last"
( cd "$DYN_PROJ"
  run_hook "completion-check.sh" "{}"
  echo "$HOOK_OUTPUT" | grep -qi "No issues" \
    && _pass "completion-check: clean -> no issues" || _fail "completion-check clean" )

# ===================================================================
section "27. config-driven values: error_repeat_limit + surgical_change_max_lines"
# ===================================================================

# Test surgical_change_max_lines override via config
SCL_PROJ="${TMPDIR_ROOT}/scl-proj"
mkdir -p "$SCL_PROJ/.sentinel"
git -C "$SCL_PROJ" init -q 2>/dev/null
git -C "$SCL_PROJ" config user.email "t@t.com"
git -C "$SCL_PROJ" config user.name "T"
cat > "$SCL_PROJ/.sentinel/config.json" << 'SCLCONF'
{
  "source_extensions": ["py"],
  "surgical_change_max_lines": 5,
  "enforcement": {}
}
SCLCONF
touch "$SCL_PROJ/.gitkeep"; git -C "$SCL_PROJ" add -A; git -C "$SCL_PROJ" commit -q -m "init" 2>/dev/null

# 8 lines edit (> config's 5 but < default 15) -> should warn
EIGHT_OLD=$(printf 'line %d\n' $(seq 1 8))
( cd "$SCL_PROJ"; run_hook "surgical-change.sh" "$(edit_json "/app/views.py" "$EIGHT_OLD" "x = 1")"
  [[ $HOOK_EXIT -eq 0 ]] && echo "$HOOK_OUTPUT" | grep -qi "Large\|lines" \
    && _pass "surgical max_lines=5: 8 lines -> warning" || _fail "surgical max_lines=5" "exit=$HOOK_EXIT" )

# 3 lines edit (< config's 5) -> should NOT warn
THREE_OLD=$(printf 'line %d\n' $(seq 1 3))
( cd "$SCL_PROJ"; run_hook "surgical-change.sh" "$(edit_json "/app/views.py" "$THREE_OLD" "x = 1")"
  [[ $HOOK_EXIT -eq 0 ]] && ! echo "$HOOK_OUTPUT" | grep -qi "Large" \
    && _pass "surgical max_lines=5: 3 lines -> no warning" || _fail "surgical 3 lines" "exit=$HOOK_EXIT" )

# Test error_repeat_limit override via config
ERL_PROJ="${TMPDIR_ROOT}/erl-proj"
mkdir -p "$ERL_PROJ/.sentinel"
git -C "$ERL_PROJ" init -q 2>/dev/null
git -C "$ERL_PROJ" config user.email "t@t.com"
git -C "$ERL_PROJ" config user.name "T"
cat > "$ERL_PROJ/.sentinel/config.json" << 'ERLCONF'
{
  "source_extensions": ["py"],
  "error_repeat_limit": 2,
  "enforcement": {}
}
ERLCONF
touch "$ERL_PROJ/.gitkeep"; git -C "$ERL_PROJ" add -A; git -C "$ERL_PROJ" commit -q -m "init" 2>/dev/null

# Create 2 identical error log entries -> should trigger stuck warning (limit=2)
mkdir -p "$ERL_PROJ/.sentinel"
HASH=$(echo "pytest||test" | md5sum | cut -c1-8)
printf '{"ts":"2026-01-01","type":"test","exit":"1","hash":"%s","cmd":"pytest","output":"FAILED"}\n' "$HASH" > "$ERL_PROJ/.sentinel/error-log.jsonl"
printf '{"ts":"2026-01-01","type":"test","exit":"1","hash":"%s","cmd":"pytest","output":"FAILED"}\n' "$HASH" >> "$ERL_PROJ/.sentinel/error-log.jsonl"

( cd "$ERL_PROJ"; run_hook "error-logger.sh" "$(bash_post_json "pytest" 1 "" "FAILED")"
  echo "$HOOK_OUTPUT" | grep -qi "STUCK\|SAME ERROR" \
    && _pass "error_repeat_limit=2: 2+ same errors -> STUCK warning" || _fail "error_repeat_limit=2" )

# ===================================================================
section "28. scope-reduction-guard — all pattern groups"
# ===================================================================

# Korean: original patterns
KO_COMMENT1=$(printf '# \xec\x9d\xbc\xeb\x8b\xa8 \xea\xb8\xb0\xeb\xb3\xb8\xeb\xa7\x8c \xea\xb5\xac\xed\x98\x84\ndef foo(): return 42')
run_hook "scope-reduction-guard.sh" "$(edit_json "/app/views.py" "old" "$KO_COMMENT1")"
[[ $HOOK_EXIT -eq 2 ]] && _pass "KO: ildan gibonman -> blocked" || _fail "KO ildan" "exit=$HOOK_EXIT"

# Korean: new pattern group (skip)
KO_COMMENT2=$(printf '# \xec\x8a\xa4\xed\x82\xb5\xed\x95\x98\xea\xb3\xa0 \xeb\x84\x98\xec\x96\xb4\xea\xb0\x90\ndef foo(): return 42')
run_hook "scope-reduction-guard.sh" "$(edit_json "/app/views.py" "old" "$KO_COMMENT2")"
[[ $HOOK_EXIT -eq 2 ]] && _pass "KO: skip-hago -> blocked" || _fail "KO skip" "exit=$HOOK_EXIT"

# Korean: new pattern group (imsibyeonpyeon)
KO_COMMENT3=$(printf '# \xec\x9e\x84\xec\x8b\x9c\xeb\xb0\xa9\xed\x8e\xb8 \xec\xbd\x94\xeb\x93\x9c\ndef foo(): return 42')
run_hook "scope-reduction-guard.sh" "$(edit_json "/app/views.py" "old" "$KO_COMMENT3")"
[[ $HOOK_EXIT -eq 2 ]] && _pass "KO: imsibyeonpyeon -> blocked" || _fail "KO imsi" "exit=$HOOK_EXIT"

# Korean: new pattern group (saengryak)
KO_COMMENT4=$(printf '# \xec\x83\x9d\xeb\x9e\xb5\xeb\x90\x9c \xeb\xb6\x80\xeb\xb6\x84\ndef foo(): return 42')
run_hook "scope-reduction-guard.sh" "$(edit_json "/app/views.py" "old" "$KO_COMMENT4")"
[[ $HOOK_EXIT -eq 2 ]] && _pass "KO: saengryak-doen -> blocked" || _fail "KO saengryak" "exit=$HOOK_EXIT"

# English: quick and dirty
run_hook "scope-reduction-guard.sh" "$(edit_json "/app/views.py" "old" "# quick and dirty fix\ndef foo(): return 42")"
[[ $HOOK_EXIT -eq 2 ]] && _pass "EN: quick and dirty -> blocked" || _fail "EN quick dirty" "exit=$HOOK_EXIT"

# English: will implement later
run_hook "scope-reduction-guard.sh" "$(edit_json "/app/views.py" "old" "# will implement later\ndef foo(): return 42")"
[[ $HOOK_EXIT -eq 2 ]] && _pass "EN: will implement later -> blocked" || _fail "EN will impl" "exit=$HOOK_EXIT"

# Japanese: toriaezu
JA_COMMENT1=$(printf '# \xe3\x81\xa8\xe3\x82\x8a\xe3\x81\x82\xe3\x81\x88\xe3\x81\x9a\xe5\xae\x9f\xe8\xa3\x85\ndef foo(): return 42')
run_hook "scope-reduction-guard.sh" "$(edit_json "/app/views.py" "old" "$JA_COMMENT1")"
[[ $HOOK_EXIT -eq 2 ]] && _pass "JA: toriaezu -> blocked" || _fail "JA toriaezu" "exit=$HOOK_EXIT"

# Japanese: zanteiteki
JA_COMMENT2=$(printf '# \xe6\x9a\xab\xe5\xae\x9a\xe7\x9a\x84\xe3\x81\xaa\xe5\xaf\xbe\xe5\xbf\x9c\ndef foo(): return 42')
run_hook "scope-reduction-guard.sh" "$(edit_json "/app/views.py" "old" "$JA_COMMENT2")"
[[ $HOOK_EXIT -eq 2 ]] && _pass "JA: zanteiteki -> blocked" || _fail "JA zanteiteki" "exit=$HOOK_EXIT"

# Clean comment -> allowed
run_hook "scope-reduction-guard.sh" "$(edit_json "/app/views.py" "old" "# Production-ready handler\ndef foo(): return 42")"
[[ $HOOK_EXIT -eq 0 ]] && _pass "clean comment -> allowed" || _fail "clean comment" "exit=$HOOK_EXIT"

# Non-comment scope words in code -> allowed
run_hook "scope-reduction-guard.sh" "$(edit_json "/app/views.py" "old" "def get_simplified_version(): return data.simplify()")"
[[ $HOOK_EXIT -eq 0 ]] && _pass "scope words in code (not comments) -> allowed" || _fail "scope words in code" "exit=$HOOK_EXIT"

# ===================================================================
section "29. enforcement toggle — disabled hooks skip"
# ===================================================================

ENF_PROJ="${TMPDIR_ROOT}/enf-proj"
mkdir -p "$ENF_PROJ/.sentinel"
git -C "$ENF_PROJ" init -q 2>/dev/null
git -C "$ENF_PROJ" config user.email "t@t.com"
git -C "$ENF_PROJ" config user.name "T"
cat > "$ENF_PROJ/.sentinel/config.json" << 'ENFCONF'
{
  "source_extensions": ["py"],
  "enforcement": {
    "deny_dummy": false,
    "scope_reduction_guard": false,
    "completion_check": false
  }
}
ENFCONF
touch "$ENF_PROJ/.gitkeep"; git -C "$ENF_PROJ" add -A; git -C "$ENF_PROJ" commit -q -m "init" 2>/dev/null

# deny-dummy disabled -> pass should be allowed
( cd "$ENF_PROJ"; run_hook "deny-dummy.sh" "$(write_json "/app/views.py" "def foo():\n    pass")"
  [[ $HOOK_EXIT -eq 0 ]] && _pass "toggle: deny_dummy=false -> allowed" || _fail "toggle deny_dummy" "exit=$HOOK_EXIT" )

# scope-reduction-guard disabled -> scope reduction should be allowed
( cd "$ENF_PROJ"; run_hook "scope-reduction-guard.sh" "$(edit_json "/app/views.py" "old" "# placeholder version\ndef foo(): pass")"
  [[ $HOOK_EXIT -eq 0 ]] && _pass "toggle: scope_reduction_guard=false -> allowed" || _fail "toggle scope_reduction" "exit=$HOOK_EXIT" )

# completion-check disabled -> should exit 0 silently
( cd "$ENF_PROJ"; run_hook "completion-check.sh" "{}"
  [[ $HOOK_EXIT -eq 0 ]] && _pass "toggle: completion_check=false -> skip" || _fail "toggle completion_check" "exit=$HOOK_EXIT" )

# ===================================================================
section "30. build-context-map.py — deep analysis"
# ===================================================================

DEEP_PROJ="${TMPDIR_ROOT}/deep-proj"
mkdir -p "$DEEP_PROJ/.sentinel" "$DEEP_PROJ/src"
git -C "$DEEP_PROJ" init -q 2>/dev/null
git -C "$DEEP_PROJ" config user.email "t@t.com"
git -C "$DEEP_PROJ" config user.name "T"

cat > "$DEEP_PROJ/src/service.py" << 'DEEPPY'
from abc import ABC, abstractmethod

class Base(ABC):
    @abstractmethod
    def handle(self):
        pass

    def cleanup(self):
        pass

    def __del__(self):
        pass

class Worker:
    def process(self):
        return self.data * 2

    def stub_method(self):
        pass

    def raise_stub(self):
        raise NotImplementedError
DEEPPY
git -C "$DEEP_PROJ" add -A; git -C "$DEEP_PROJ" commit -q -m "init" 2>/dev/null

python3 "$SCRIPT_DIR/build-context-map.py" --root "$DEEP_PROJ" --max-files 10 >/dev/null 2>&1

jq -r '.files["src/service.py"].functions["Base.handle"].classification' "$DEEP_PROJ/.sentinel/context-map.json" 2>/dev/null | grep -q "abstract" \
  && _pass "deep: @abstractmethod -> abstract" || _fail "deep abstract"

jq -r '.files["src/service.py"].functions["Base.cleanup"].classification' "$DEEP_PROJ/.sentinel/context-map.json" 2>/dev/null | grep -q "intentional_noop" \
  && _pass "deep: ABC cleanup pass -> intentional_noop" || _fail "deep ABC cleanup"

jq -r '.files["src/service.py"].functions["Base.__del__"].classification' "$DEEP_PROJ/.sentinel/context-map.json" 2>/dev/null | grep -q "intentional_noop" \
  && _pass "deep: __del__ pass -> intentional_noop" || _fail "deep __del__"

jq -r '.files["src/service.py"].functions["Worker.process"].classification' "$DEEP_PROJ/.sentinel/context-map.json" 2>/dev/null | grep -q "implemented" \
  && _pass "deep: real logic -> implemented" || _fail "deep implemented"

jq -r '.files["src/service.py"].functions["Worker.stub_method"].classification' "$DEEP_PROJ/.sentinel/context-map.json" 2>/dev/null | grep -q "stub" \
  && _pass "deep: plain pass -> stub" || _fail "deep stub"

jq -r '.files["src/service.py"].functions["Worker.raise_stub"].classification' "$DEEP_PROJ/.sentinel/context-map.json" 2>/dev/null | grep -q "stub" \
  && _pass "deep: raise NotImpl (no abstract) -> stub" || _fail "deep raise stub"

jq -r '.abstract_bases[]' "$DEEP_PROJ/.sentinel/context-map.json" 2>/dev/null | grep -q "Base" \
  && _pass "deep: abstract_bases includes Base" || _fail "deep abstract_bases"

jq -r '.files["src/service.py"].criticality' "$DEEP_PROJ/.sentinel/context-map.json" 2>/dev/null | grep -q "normal" \
  && _pass "deep: <200 lines -> normal criticality" || _fail "deep criticality"

# has_test field: no test file exists for service.py -> has_test=false
jq -r '.files["src/service.py"].functions["Worker.process"].has_test' "$DEEP_PROJ/.sentinel/context-map.json" 2>/dev/null | grep -q "false" \
  && _pass "deep: no test file -> has_test=false" || _fail "deep has_test false"

# Create a test file and rebuild -> has_test=true
mkdir -p "$DEEP_PROJ/tests"
cat > "$DEEP_PROJ/tests/test_service.py" << 'TESTPY'
def test_process():
    assert True
TESTPY
git -C "$DEEP_PROJ" add -A; git -C "$DEEP_PROJ" commit -q -m "add test" 2>/dev/null
python3 "$SCRIPT_DIR/build-context-map.py" --root "$DEEP_PROJ" --max-files 10 >/dev/null 2>&1

jq -r '.files["src/service.py"].functions["Worker.process"].has_test' "$DEEP_PROJ/.sentinel/context-map.json" 2>/dev/null | grep -q "true" \
  && _pass "deep: test_service.py exists -> has_test=true" || _fail "deep has_test true"

# ===================================================================
printf "\n${BOLD}========================================${RESET}\n"
# ═══════════════════════════════════════
section "31. sentinel_get_action — mode resolution"
# ═══════════════════════════════════════

GA_PROJ="${TMPDIR_ROOT}/ga-proj"
mkdir -p "$GA_PROJ/.sentinel"
git -C "$GA_PROJ" init -q 2>/dev/null
PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Test 1: Legacy config (no mode/categories) → uses fallback
cat > "$GA_PROJ/.sentinel/config.json" << 'CONF'
{"enforcement":{"deny_dummy":true}}
CONF

RESULT=$(cd "$GA_PROJ" && export SENTINEL_PLUGIN_ROOT="$PLUGIN_ROOT" SCRIPT_DIR="$PLUGIN_ROOT/hooks/scripts" && source "$PLUGIN_ROOT/hooks/scripts/_common.sh" 2>/dev/null && sentinel_get_action "codeQuality" "block_standalone_pass" "block")
[[ "$RESULT" == "block" ]] && _pass "legacy config -> fallback=block" || _fail "legacy config -> fallback=block" "got=$RESULT"

RESULT=$(cd "$GA_PROJ" && export SENTINEL_PLUGIN_ROOT="$PLUGIN_ROOT" SCRIPT_DIR="$PLUGIN_ROOT/hooks/scripts" && source "$PLUGIN_ROOT/hooks/scripts/_common.sh" 2>/dev/null && sentinel_get_action "editDiscipline" "warn_large_edits" "warn")
[[ "$RESULT" == "warn" ]] && _pass "legacy config -> fallback=warn" || _fail "legacy config -> fallback=warn" "got=$RESULT"

# Test 2: v1.5.0 config with mode → reads from mode-defaults.json
cat > "$GA_PROJ/.sentinel/config.json" << 'CONF'
{"mode":"relaxed"}
CONF

RESULT=$(cd "$GA_PROJ" && export SENTINEL_PLUGIN_ROOT="$PLUGIN_ROOT" SCRIPT_DIR="$PLUGIN_ROOT/hooks/scripts" && source "$PLUGIN_ROOT/hooks/scripts/_common.sh" 2>/dev/null && sentinel_reset_action_cache && sentinel_get_action "codeQuality" "block_standalone_pass")
[[ "$RESULT" == "warn" ]] && _pass "relaxed mode -> block_standalone_pass=warn" || _fail "relaxed mode -> block_standalone_pass=warn" "got=$RESULT"

RESULT=$(cd "$GA_PROJ" && export SENTINEL_PLUGIN_ROOT="$PLUGIN_ROOT" SCRIPT_DIR="$PLUGIN_ROOT/hooks/scripts" && source "$PLUGIN_ROOT/hooks/scripts/_common.sh" 2>/dev/null && sentinel_reset_action_cache && sentinel_get_action "codeQuality" "block_todo_comments")
[[ "$RESULT" == "off" ]] && _pass "relaxed mode -> block_todo_comments=off" || _fail "relaxed mode -> block_todo_comments=off" "got=$RESULT"

# Test 3: v1.5.0 config with per-item override
cat > "$GA_PROJ/.sentinel/config.json" << 'CONF'
{"mode":"standard","categories":{"codeQuality":{"block_todo_comments":"off"}}}
CONF

RESULT=$(cd "$GA_PROJ" && export SENTINEL_PLUGIN_ROOT="$PLUGIN_ROOT" SCRIPT_DIR="$PLUGIN_ROOT/hooks/scripts" && source "$PLUGIN_ROOT/hooks/scripts/_common.sh" 2>/dev/null && sentinel_reset_action_cache && sentinel_get_action "codeQuality" "block_todo_comments")
[[ "$RESULT" == "off" ]] && _pass "per-item override -> block_todo_comments=off" || _fail "per-item override -> block_todo_comments=off" "got=$RESULT"

RESULT=$(cd "$GA_PROJ" && export SENTINEL_PLUGIN_ROOT="$PLUGIN_ROOT" SCRIPT_DIR="$PLUGIN_ROOT/hooks/scripts" && source "$PLUGIN_ROOT/hooks/scripts/_common.sh" 2>/dev/null && sentinel_reset_action_cache && sentinel_get_action "codeQuality" "block_standalone_pass")
[[ "$RESULT" == "block" ]] && _pass "standard mode non-overridden -> block" || _fail "standard mode non-overridden -> block" "got=$RESULT"

# Test 4: paranoid mode
cat > "$GA_PROJ/.sentinel/config.json" << 'CONF'
{"mode":"paranoid"}
CONF

RESULT=$(cd "$GA_PROJ" && export SENTINEL_PLUGIN_ROOT="$PLUGIN_ROOT" SCRIPT_DIR="$PLUGIN_ROOT/hooks/scripts" && source "$PLUGIN_ROOT/hooks/scripts/_common.sh" 2>/dev/null && sentinel_reset_action_cache && sentinel_get_action "codeQuality" "warn_ssl_bypass")
[[ "$RESULT" == "block" ]] && _pass "paranoid mode -> warn_ssl_bypass=block" || _fail "paranoid mode -> warn_ssl_bypass=block" "got=$RESULT"

# Test 5: strict mode
cat > "$GA_PROJ/.sentinel/config.json" << 'CONF'
{"mode":"strict"}
CONF

RESULT=$(cd "$GA_PROJ" && export SENTINEL_PLUGIN_ROOT="$PLUGIN_ROOT" SCRIPT_DIR="$PLUGIN_ROOT/hooks/scripts" && source "$PLUGIN_ROOT/hooks/scripts/_common.sh" 2>/dev/null && sentinel_reset_action_cache && sentinel_get_action "workflow" "require_pre_edit_checklist")
[[ "$RESULT" == "block" ]] && _pass "strict mode -> require_pre_edit_checklist=block" || _fail "strict mode -> require_pre_edit_checklist=block" "got=$RESULT"

# ═══════════════════════════════════════
section "32. env-safety — new v1.5.0 checks"
# ═══════════════════════════════════════

ENV_HOOK="$PLUGIN_ROOT/hooks/scripts/env-safety.sh"

# Protected branch push
RESULT=$(echo '{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}' | bash "$ENV_HOOK" 2>&1; echo "EXIT:$?")
echo "$RESULT" | grep -q "EXIT:2" && _pass "push to main -> blocked" || _fail "push to main" "exit=$(echo "$RESULT" | grep -oP 'EXIT:\K\d+')"

# git clean -f
RESULT=$(echo '{"tool_name":"Bash","tool_input":{"command":"git clean -fd"}}' | bash "$ENV_HOOK" 2>&1; echo "EXIT:$?")
echo "$RESULT" | grep -q "EXIT:2" && _pass "git clean -fd -> blocked" || _fail "git clean" "exit=$(echo "$RESULT" | grep -oP 'EXIT:\K\d+')"

# git checkout -- . (bulk discard)
RESULT=$(echo '{"tool_name":"Bash","tool_input":{"command":"git checkout -- ."}}' | bash "$ENV_HOOK" 2>&1; echo "EXIT:$?")
echo "$RESULT" | grep -q "EXIT:2" && _pass "git checkout -- . -> blocked" || _fail "checkout discard" "exit=$(echo "$RESULT" | grep -oP 'EXIT:\K\d+')"

# Destructive SQL
RESULT=$(echo '{"tool_name":"Bash","tool_input":{"command":"psql -c \"DROP TABLE users;\""}}' | bash "$ENV_HOOK" 2>&1; echo "EXIT:$?")
echo "$RESULT" | grep -q "EXIT:2" && _pass "DROP TABLE -> blocked" || _fail "DROP TABLE" "exit=$(echo "$RESULT" | grep -oP 'EXIT:\K\d+')"

# Branch deletion of protected branch
RESULT=$(echo '{"tool_name":"Bash","tool_input":{"command":"git branch -D main"}}' | bash "$ENV_HOOK" 2>&1; echo "EXIT:$?")
echo "$RESULT" | grep -q "EXIT:2" && _pass "delete main branch -> blocked" || _fail "branch delete" "exit=$(echo "$RESULT" | grep -oP 'EXIT:\K\d+')"

# Feature branch push (should be allowed)
RESULT=$(echo '{"tool_name":"Bash","tool_input":{"command":"git push origin feature/my-branch"}}' | bash "$ENV_HOOK" 2>&1; echo "EXIT:$?")
echo "$RESULT" | grep -q "EXIT:0" && _pass "push feature branch -> allowed" || _fail "feature push" "exit=$(echo "$RESULT" | grep -oP 'EXIT:\K\d+')"

# Non-destructive SQL (should be allowed)
RESULT=$(echo '{"tool_name":"Bash","tool_input":{"command":"psql -c \"SELECT * FROM users;\""}}' | bash "$ENV_HOOK" 2>&1; echo "EXIT:$?")
echo "$RESULT" | grep -q "EXIT:0" && _pass "SELECT query -> allowed" || _fail "SELECT" "exit=$(echo "$RESULT" | grep -oP 'EXIT:\K\d+')"

# ═══════════════════════════════════════
section "33. per-item action — deny-dummy with mode override"
# ═══════════════════════════════════════

MODE_PROJ="${TMPDIR_ROOT}/mode-proj"
mkdir -p "$MODE_PROJ/.sentinel" "$MODE_PROJ/src"
git -C "$MODE_PROJ" init -q 2>/dev/null
touch "$MODE_PROJ/src/app.py"

# relaxed mode: TODO comments should be allowed (off)
cat > "$MODE_PROJ/.sentinel/config.json" << 'CONF'
{"mode":"relaxed"}
CONF

RESULT=$(cd "$MODE_PROJ" && echo '{"tool_name":"Edit","tool_input":{"file_path":"'"$MODE_PROJ"'/src/app.py","new_string":"# TODO: add error handling\ndef handler():\n    return process()"}}' | SENTINEL_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$PLUGIN_ROOT/hooks/scripts/deny-dummy.sh" 2>&1; echo "EXIT:$?")
echo "$RESULT" | grep -q "EXIT:0" && _pass "relaxed mode: TODO comment -> allowed" || _fail "relaxed TODO" "exit=$(echo "$RESULT" | grep -oP 'EXIT:\K\d+')"

# ═══════════════════════════════════════
section "34. surgical-change — active caller check"
# ═══════════════════════════════════════

CALLER_PROJ="${TMPDIR_ROOT}/caller-proj"
mkdir -p "$CALLER_PROJ/.sentinel" "$CALLER_PROJ/src"
git -C "$CALLER_PROJ" init -q 2>/dev/null
cat > "$CALLER_PROJ/.sentinel/config.json" << 'CONF'
{"mode":"strict"}
CONF

# Create files with caller relationships
cat > "$CALLER_PROJ/src/utils.py" << 'PYCODE'
def calculate_total(items):
    return sum(i.price for i in items)
PYCODE

cat > "$CALLER_PROJ/src/views.py" << 'PYCODE'
from .utils import calculate_total

def order_view(request):
    total = calculate_total(request.items)
    return {"total": total}
PYCODE

# Try to delete calculate_total — should detect caller in views.py
OLD_STR=$'def calculate_total(items):\n    return sum(i.price for i in items)'
EDIT_INPUT=$(edit_json "$CALLER_PROJ/src/utils.py" "$OLD_STR" "")
RESULT=$(cd "$CALLER_PROJ" && echo "$EDIT_INPUT" | SENTINEL_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$PLUGIN_ROOT/hooks/scripts/surgical-change.sh" 2>&1; echo "EXIT:$?")
echo "$RESULT" | grep -q "caller(s) found" && _pass "caller check: callers found -> reported" || _fail "caller check" "no caller warning"
echo "$RESULT" | grep -q "EXIT:2" && _pass "caller check: strict mode -> blocked" || _fail "caller check block" "exit=$(echo "$RESULT" | grep -oP 'EXIT:\K\d+')"

# Delete a function with no callers — should be allowed
cat > "$CALLER_PROJ/src/orphan.py" << 'PYCODE'
def unused_helper():
    return 42
PYCODE

OLD_STR=$'def unused_helper():\n    return 42'
EDIT_INPUT=$(edit_json "$CALLER_PROJ/src/orphan.py" "$OLD_STR" "")
RESULT=$(cd "$CALLER_PROJ" && echo "$EDIT_INPUT" | SENTINEL_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$PLUGIN_ROOT/hooks/scripts/surgical-change.sh" 2>&1; echo "EXIT:$?")
echo "$RESULT" | grep -q "caller(s) found" && _fail "orphan delete" "false positive callers" || _pass "caller check: no callers -> no block"

# ═══════════════════════════════════════
section "35. post-edit-verify — linter integration"
# ═══════════════════════════════════════

LINT_PROJ="${TMPDIR_ROOT}/lint-proj"
mkdir -p "$LINT_PROJ/.sentinel" "$LINT_PROJ/src"
git -C "$LINT_PROJ" init -q 2>/dev/null

# Config with a simple linter (use grep as fake linter that always finds "issues")
cat > "$LINT_PROJ/.sentinel/config.json" << 'CONF'
{"mode":"standard","linters":[{"command":"echo 'E001: line too long' && exit 1","extensions":["py"],"name":"test-linter"}]}
CONF

# Create a Python file
cat > "$LINT_PROJ/src/app.py" << 'PYCODE'
def hello():
    return "world"
PYCODE

# Run post-edit-verify — should show linter output
RESULT=$(cd "$LINT_PROJ" && echo '{"tool_name":"Edit","tool_input":{"file_path":"'"$LINT_PROJ"'/src/app.py","old_string":"world","new_string":"earth"}}' | SENTINEL_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$PLUGIN_ROOT/hooks/scripts/post-edit-verify.sh" 2>&1; echo "EXIT:$?")
echo "$RESULT" | grep -q "test-linter" && _pass "linter: output shown" || _fail "linter output" "no linter output"
echo "$RESULT" | grep -q "E001" && _pass "linter: issue details shown" || _fail "linter details" "no E001"

# Config without linters — should not run any
cat > "$LINT_PROJ/.sentinel/config.json" << 'CONF'
{"mode":"standard"}
CONF

RESULT=$(cd "$LINT_PROJ" && echo '{"tool_name":"Edit","tool_input":{"file_path":"'"$LINT_PROJ"'/src/app.py","old_string":"earth","new_string":"mars"}}' | SENTINEL_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$PLUGIN_ROOT/hooks/scripts/post-edit-verify.sh" 2>&1; echo "EXIT:$?")
echo "$RESULT" | grep -q "test-linter" && _fail "no-linter config" "linter ran without config" || _pass "linter: no config -> no linter"

# Extension mismatch — .ts file with py-only linter
cat > "$LINT_PROJ/.sentinel/config.json" << 'CONF'
{"mode":"standard","linters":[{"command":"echo 'FAIL' && exit 1","extensions":["py"],"name":"py-only"}]}
CONF
cat > "$LINT_PROJ/src/app.ts" << 'TSCODE'
const x = 1;
TSCODE

RESULT=$(cd "$LINT_PROJ" && echo '{"tool_name":"Edit","tool_input":{"file_path":"'"$LINT_PROJ"'/src/app.ts","old_string":"1","new_string":"2"}}' | SENTINEL_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$PLUGIN_ROOT/hooks/scripts/post-edit-verify.sh" 2>&1; echo "EXIT:$?")
echo "$RESULT" | grep -q "py-only" && _fail "ext mismatch" "linter ran on wrong ext" || _pass "linter: extension mismatch -> skipped"

# ═══════════════════════════════════════
section "36. task-scope-guard — additive connector detection"
# ═══════════════════════════════════════

TSG_HOOK="$PLUGIN_ROOT/hooks/scripts/task-scope-guard.sh"

# Korean connectors
RESULT=$(echo '{"tool_input":{"user_prompt":"로그인 기능 만들고 그리고 회원가입도 추가해줘"}}' | SENTINEL_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$TSG_HOOK" 2>&1)
echo "$RESULT" | grep -q "items detected" && _pass "connector: 그리고 -> multi-task" || _fail "connector 그리고" "not detected"

RESULT=$(echo '{"tool_input":{"user_prompt":"에러 핸들링 추가로 테스트도 작성해"}}' | SENTINEL_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$TSG_HOOK" 2>&1)
echo "$RESULT" | grep -q "items detected" && _pass "connector: 추가로 -> multi-task" || _fail "connector 추가로" "not detected"

# English connectors
RESULT=$(echo '{"tool_input":{"user_prompt":"fix the login bug and also add rate limiting"}}' | SENTINEL_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$TSG_HOOK" 2>&1)
echo "$RESULT" | grep -q "items detected" && _pass "connector: and also -> multi-task" || _fail "connector and-also" "not detected"

# Single task without connector — should not trigger
RESULT=$(echo '{"tool_input":{"user_prompt":"로그인 기능 만들어줘"}}' | SENTINEL_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$TSG_HOOK" 2>&1)
echo "$RESULT" | grep -q "items detected" && _fail "single task" "false positive" || _pass "connector: single task -> no trigger"

# Japanese connector
RESULT=$(echo '{"tool_input":{"user_prompt":"ログイン機能を作って、さらにテストも書いて"}}' | SENTINEL_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$TSG_HOOK" 2>&1)
echo "$RESULT" | grep -q "items detected" && _pass "connector: さらに -> multi-task" || _fail "connector さらに" "not detected"

printf "${BOLD}Results: %d total | ${GREEN}%d passed${RESET} | ${RED}%d failed${RESET}\n" \
  "$TOTAL_COUNT" "$PASS_COUNT" "$FAIL_COUNT"
printf "${BOLD}========================================${RESET}\n\n"

[[ $FAIL_COUNT -gt 0 ]] && exit 1
exit 0
