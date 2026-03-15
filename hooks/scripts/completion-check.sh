#!/bin/bash
# Sentinel Stop Hook: Completion Verification (WARNING)
# Warns about incomplete work before session stops.
# Exit 0 = ALLOW (warnings only)

PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
[[ -z "$PROJECT_ROOT" ]] && exit 0

WARNINGS=""

# 1. Check for uncommitted source changes
DIRTY_SRC=$(git status --porcelain 2>/dev/null | grep -P '\.(py|ts|tsx|js|jsx|go|rs|java|c|cpp|svelte|vue)$' | head -5)
if [[ -n "$DIRTY_SRC" ]]; then
  DIRTY_COUNT=$(echo "$DIRTY_SRC" | wc -l)
  WARNINGS="${WARNINGS}⚠️  ${DIRTY_COUNT} uncommitted source file(s):\n"
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    WARNINGS="${WARNINGS}  ${line}\n"
  done <<< "$DIRTY_SRC"
  WARNINGS="${WARNINGS}\n"
fi

# 2. Check if current-task.json still exists (task not completed)
TASK_FILE="${PROJECT_ROOT}/.sentinel/current-task.json"
if [[ -f "$TASK_FILE" ]]; then
  TASK_ID=$(jq -r '.task_id // "unknown"' "$TASK_FILE" 2>/dev/null)
  WARNINGS="${WARNINGS}⚠️  Active task not completed: ${TASK_ID}\n"
  WARNINGS="${WARNINGS}   .sentinel/current-task.json still exists.\n"
  WARNINGS="${WARNINGS}   Complete the task and commit, or remove the file.\n\n"
fi

# 3. Check for recent unresolved errors
LOG_FILE="${PROJECT_ROOT}/.sentinel/error-log.jsonl"
if [[ -f "$LOG_FILE" ]]; then
  RECENT_ERRORS=$(tail -5 "$LOG_FILE" 2>/dev/null | jq -r '.type' 2>/dev/null | sort | uniq -c | sort -rn)
  if [[ -n "$RECENT_ERRORS" ]]; then
    WARNINGS="${WARNINGS}⚠️  Recent errors in this session:\n"
    echo "$RECENT_ERRORS" | while read -r count type; do
      WARNINGS="${WARNINGS}  ${count}x ${type}\n"
    done
    WARNINGS="${WARNINGS}   Verify these errors are resolved before stopping.\n\n"
  fi
fi

# 4. Summary
if [[ -n "$WARNINGS" ]]; then
  echo "🔍 [Sentinel Completion Check]"
  echo ""
  echo -e "$WARNINGS"
  echo "Before stopping, verify:"
  echo "  1. All source changes committed"
  echo "  2. Active task completed or documented"
  echo "  3. Tests pass (run your verify_command)"
  echo "  4. No repeated errors unresolved"
fi

exit 0
