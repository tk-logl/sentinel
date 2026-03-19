#!/bin/bash
# Sentinel PostToolUse Hook: Task Completion Gate (WARNING)
# Verifies evidence before task completion claims.
# Fires on TaskUpdate when status → completed.
# Exit 0 = ALLOW (always — warning only, never blocks task tools)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/_common.sh"
sentinel_require_jq "task-completion-gate"
sentinel_check_enabled "task_completion_gate"

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

# Only fire on TaskUpdate
[[ "$TOOL_NAME" != "TaskUpdate" ]] && exit 0

# Check if status was set to completed
NEW_STATUS=$(echo "$INPUT" | jq -r '.tool_input.status // empty' 2>/dev/null)
[[ "$NEW_STATUS" != "completed" ]] && exit 0

TASK_ID=$(echo "$INPUT" | jq -r '.tool_input.taskId // empty' 2>/dev/null)

PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
[[ -z "$PROJECT_ROOT" ]] && exit 0

WARNINGS=""

# 1. Check for uncommitted changes
DIRTY_COUNT=$(git status --porcelain 2>/dev/null | wc -l)
if [[ $DIRTY_COUNT -gt 0 ]]; then
  WARNINGS="${WARNINGS}  ⚠️ ${DIRTY_COUNT} uncommitted file(s) — commit before claiming done\n"
fi

# 2. Check current-task.json verify_command
TASK_FILE="${PROJECT_ROOT}/.sentinel/current-task.json"
if [[ -f "$TASK_FILE" ]]; then
  VERIFY_CMD=$(jq -r '.verify_command // empty' "$TASK_FILE" 2>/dev/null)
  if [[ -n "$VERIFY_CMD" ]]; then
    WARNINGS="${WARNINGS}  ⚠️ verify_command not confirmed: ${VERIFY_CMD}\n"
    WARNINGS="${WARNINGS}    Run this command to validate the implementation before marking done.\n"
  fi
fi

# 3. Check for TODO/FIXME in recently modified files
MODIFIED_FILES=$(git diff --cached --name-only 2>/dev/null; git diff --name-only 2>/dev/null)
if [[ -n "$MODIFIED_FILES" ]]; then
  TODO_FILES=""
  while IFS= read -r mf; do
    [[ -z "$mf" || ! -f "${PROJECT_ROOT}/${mf}" ]] && continue
    if grep -qP '(TODO|FIXME|PLACEHOLDER|HACK)\b' "${PROJECT_ROOT}/${mf}" 2>/dev/null; then
      TODO_FILES="${TODO_FILES}    - ${mf}\n"
    fi
  done <<< "$MODIFIED_FILES"
  if [[ -n "$TODO_FILES" ]]; then
    WARNINGS="${WARNINGS}  ⚠️ TODO/FIXME found in modified files:\n${TODO_FILES}"
  fi
fi

# 4. Check recent errors (last 5 minutes)
ERROR_LOG="${PROJECT_ROOT}/.sentinel/error-log.jsonl"
if [[ -f "$ERROR_LOG" ]]; then
  RECENT_ERRORS=$(tail -5 "$ERROR_LOG" 2>/dev/null | wc -l)
  if [[ $RECENT_ERRORS -gt 0 ]]; then
    LAST_ERROR_TYPE=$(tail -1 "$ERROR_LOG" | jq -r '.type // "unknown"' 2>/dev/null)
    WARNINGS="${WARNINGS}  ⚠️ ${RECENT_ERRORS} recent error(s) in log (last: ${LAST_ERROR_TYPE})\n"
    WARNINGS="${WARNINGS}    Verify these errors are resolved, not just ignored.\n"
  fi
fi

if [[ -n "$WARNINGS" ]]; then
  echo "🔎 [Sentinel Task-Completion-Gate] Task ${TASK_ID:-unknown} → completed"
  echo ""
  echo "Pre-completion evidence check:"
  echo -e "$WARNINGS"
  echo "Verify all warnings are addressed before claiming this task is done."
  sentinel_stats_increment "warnings"
fi

exit 0
