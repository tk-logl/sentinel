#!/bin/bash
# Sentinel PreToolUse Hook: TDD Context Isolation (BLOCKING)
# Enforces test-first development by tracking 3 phases:
#   Phase 1 (test-write): Only test files can be edited
#   Phase 2 (implement): Only source files can be edited
#   Phase 3 (refactor): Both can be edited
#
# Activation: Create .sentinel/tdd-active.json with {"phase":"test","target":"path/to/module"}
# Deactivation: Delete .sentinel/tdd-active.json or set phase to "done"
#
# Exit 2 = DENY | Exit 0 = ALLOW

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/_common.sh"
sentinel_require_jq "tdd-enforce" "blocking"
sentinel_compat_check "tdd_enforce"

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

# Only gate Write/Edit
if [[ "$TOOL_NAME" != "Edit" && "$TOOL_NAME" != "Write" ]]; then
  exit 0
fi

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[[ -z "$FILE_PATH" || ! -f "$FILE_PATH" ]] && exit 0

# Only enforce on source code files
if ! sentinel_is_source_file "$FILE_PATH"; then
  exit 0
fi

# Skip enforcement tools
BASENAME=$(basename "$FILE_PATH")
case "$BASENAME" in
  *gate*|*guard*|*scan*|*check*|*verify*|*lint*|*analyz*|*detect*|*enforc*) exit 0 ;;
esac
case "$FILE_PATH" in
  */sentinel/hooks/*|*/sentinel/scripts/*|*/.claude/plugins/*|*/.claude/hooks/*) exit 0 ;;
esac

# Check per-item action
ACTION=$(sentinel_get_action "workflow" "tdd_enforce" "off")
[[ "$ACTION" == "off" ]] && exit 0

# Check if TDD mode is active
PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
[[ -z "$PROJECT_ROOT" ]] && exit 0

TDD_STATE="${PROJECT_ROOT}/.sentinel/tdd-active.json"
[[ ! -f "$TDD_STATE" ]] && exit 0

PHASE=$(jq -r '.phase // "done"' "$TDD_STATE" 2>/dev/null)
TARGET=$(jq -r '.target // ""' "$TDD_STATE" 2>/dev/null)

[[ "$PHASE" == "done" ]] && exit 0

# Determine if the file being edited is a test file
IS_TEST=false
case "$FILE_PATH" in
  */tests/*|*/test_*|*_test.*|*.test.*|*.spec.*) IS_TEST=true ;;
esac

case "$PHASE" in
  test)
    # Phase 1: Only test files can be edited
    if [[ "$IS_TEST" == "false" ]]; then
      if [[ "$ACTION" == "block" ]]; then
        {
          echo "⛔ [Sentinel TDD] Phase 1 (test-write): Cannot edit source files yet"
          echo ""
          echo "  Current phase: TEST — write tests first"
          echo "  File blocked: $(basename "$FILE_PATH")"
          echo "  Target module: $TARGET"
          echo ""
          echo "  Write tests that define the expected behavior."
          echo "  When tests are ready, update .sentinel/tdd-active.json:"
          echo "    {\"phase\": \"implement\", \"target\": \"$TARGET\"}"
        } >&2
        sentinel_stats_increment "blocks"
        sentinel_stats_increment "pattern_tdd_violation"
        exit 2
      else
        echo "⚠️ [Sentinel TDD] Phase 1: Source file edit during test-write phase"
        echo "  File: $(basename "$FILE_PATH")"
        sentinel_stats_increment "warnings"
      fi
    fi
    ;;

  implement)
    # Phase 2: Only source files can be edited (not tests)
    if [[ "$IS_TEST" == "true" ]]; then
      if [[ "$ACTION" == "block" ]]; then
        {
          echo "⛔ [Sentinel TDD] Phase 2 (implement): Cannot modify tests"
          echo ""
          echo "  Current phase: IMPLEMENT — make existing tests pass"
          echo "  File blocked: $(basename "$FILE_PATH")"
          echo "  Target module: $TARGET"
          echo ""
          echo "  Implement real logic to pass the tests."
          echo "  Do NOT modify tests to match your implementation."
          echo "  When all tests pass, update .sentinel/tdd-active.json:"
          echo "    {\"phase\": \"refactor\", \"target\": \"$TARGET\"}"
        } >&2
        sentinel_stats_increment "blocks"
        sentinel_stats_increment "pattern_tdd_violation"
        exit 2
      else
        echo "⚠️ [Sentinel TDD] Phase 2: Test file edit during implement phase"
        echo "  File: $(basename "$FILE_PATH")"
        sentinel_stats_increment "warnings"
      fi
    fi
    ;;

  refactor)
    # Phase 3: Both can be edited — no restrictions
    ;;

  *)
    # Unknown phase — don't block
    ;;
esac

sentinel_stats_increment "checks"
exit 0
