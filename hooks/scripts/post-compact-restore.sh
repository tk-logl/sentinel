#!/bin/bash
# Sentinel PostCompact Hook: Post-Compaction Context Restore (CONTEXT INJECTION)
# Saves compact_summary and re-injects critical context after compaction.
# Ensures task-list, current-task, and pre-compaction state survive compaction.
# Exit 0 = ALLOW (context only)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/_common.sh"
# jq is optional — graceful fallback

PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
[[ -z "$PROJECT_ROOT" ]] && exit 0

# Read compact_summary from stdin
INPUT=$(cat)
COMPACT_SUMMARY=""
if [[ "$SENTINEL_NO_JQ" == "0" ]]; then
  COMPACT_SUMMARY=$(echo "$INPUT" | jq -r '.compact_summary // empty' 2>/dev/null)
fi

STATE_DIR="${PROJECT_ROOT}/.sentinel/state"
mkdir -p "$STATE_DIR"

# Save compact_summary if provided
if [[ -n "$COMPACT_SUMMARY" ]]; then
  TIMESTAMP=$(date +%Y%m%d-%H%M%S)
  echo "$COMPACT_SUMMARY" > "${STATE_DIR}/compact-${TIMESTAMP}.md"
fi

echo "=== Post-Compaction Context Restore ==="
echo ""

# 1. Re-inject current-task.json
TASK_FILE="${PROJECT_ROOT}/.sentinel/current-task.json"
if [[ -f "$TASK_FILE" && "$SENTINEL_NO_JQ" == "0" ]]; then
  TASK_ID=$(jq -r '.task_id // .item_id // "unknown"' "$TASK_FILE" 2>/dev/null)
  TASK_WHY=$(jq -r '.why // ""' "$TASK_FILE" 2>/dev/null)
  TASK_APPROACH=$(jq -r '.approach // ""' "$TASK_FILE" 2>/dev/null)
  VERIFY_CMD=$(jq -r '.verify_command // ""' "$TASK_FILE" 2>/dev/null)
  echo "Active Task: ${TASK_ID}"
  echo "  Why: ${TASK_WHY}"
  [[ -n "$TASK_APPROACH" ]] && echo "  Approach: ${TASK_APPROACH}"
  [[ -n "$VERIFY_CMD" ]] && echo "  Verify: ${VERIFY_CMD}"
  echo ""
fi

# 2. Re-inject task-list status
TASK_LIST_ENABLED=$(sentinel_read_config '.taskList.enabled' 'true')
INJECT_ON_COMPACT=$(sentinel_read_config '.taskList.injectOnPostCompact' 'true')
if [[ "$TASK_LIST_ENABLED" == "true" && "$INJECT_ON_COMPACT" == "true" ]]; then
  TASK_LIST_FILE=$(sentinel_find_task_list)
  if [[ -n "$TASK_LIST_FILE" ]]; then
    PENDING_COUNT=$(sentinel_task_count "pending")
    INPROG_COUNT=$(sentinel_task_count "inProgress")
    DONE_COUNT=$(sentinel_task_count "done")
    echo "Task List: ${PENDING_COUNT} pending / ${INPROG_COUNT} in-progress / ${DONE_COUNT} done"

    if [[ "$INPROG_COUNT" -gt 0 ]]; then
      echo ""
      echo "In Progress [~] — RESUME THESE:"
      sentinel_task_list_items "inProgress" | sed 's/^/  /'
    fi

    if [[ "$PENDING_COUNT" -gt 0 ]]; then
      MAX_ITEMS=$(sentinel_read_config '.taskList.maxInjectItems' '30')
      echo ""
      echo "Pending [ ] (next items):"
      sentinel_task_list_items "pending" "$MAX_ITEMS" | sed 's/^/  /'
    fi
    echo ""
  fi
fi

# 3. Re-inject pre-compaction state (Intent + Next Steps)
LATEST_STATE="${STATE_DIR}/latest.md"
if [[ -f "$LATEST_STATE" ]]; then
  echo "--- Pre-Compaction Context ---"
  # Section 1: Session Intent
  awk '/^## 1\. Session Intent/,/^## 2\./' "$LATEST_STATE" | head -n -1
  echo ""
  # Section 5: Next Steps
  awk '/^## 5\. Next Steps/,/^## RECOVERY/' "$LATEST_STATE" | head -n -1
  echo "--- End Context ---"
  echo ""
fi

echo "ENFORCEMENT: Resume from pre-compaction state. Read task list. Implement per spec."
echo "=== Context Restore Complete ==="

exit 0
