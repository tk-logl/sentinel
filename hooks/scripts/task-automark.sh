#!/bin/bash
# Sentinel PostToolUse Hook: Task Auto-Mark (LOGGING)
# Detects git commit commands and auto-marks referenced task IDs as done.
# Exit 0 = ALLOW (always, just updates task list)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/_common.sh"
sentinel_require_jq "task-automark"
sentinel_check_enabled "task_automark"

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

[[ "$TOOL_NAME" != "Bash" ]] && exit 0

# Check if task-list feature is enabled
TASK_ENABLED=$(sentinel_read_config '.taskList.enabled' 'true')
[[ "$TASK_ENABLED" != "true" ]] && exit 0

AUTO_MARK=$(sentinel_read_config '.taskList.autoMarkOnCommit' 'true')
[[ "$AUTO_MARK" != "true" ]] && exit 0

# Only trigger on git commit commands
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
echo "$COMMAND" | grep -qP '^\s*git\s+commit\b' || exit 0

# Check for successful commit (exit code 0)
EXIT_CODE=$(echo "$INPUT" | jq -r '.tool_response.exit_code // .tool_response.exitCode // "1"' 2>/dev/null)
[[ "$EXIT_CODE" != "0" ]] && exit 0

# Extract commit hash from stdout
STDOUT=$(echo "$INPUT" | jq -r '.tool_response.stdout // empty' 2>/dev/null)
COMMIT_HASH=$(echo "$STDOUT" | grep -oP '^\[[\w/.-]+\s+\K[a-f0-9]{7,}' | head -1)
[[ -z "$COMMIT_HASH" ]] && COMMIT_HASH=$(echo "$STDOUT" | grep -oP '[a-f0-9]{7,}' | head -1)

# Extract commit message (from command or stdout)
COMMIT_MSG=""
if echo "$COMMAND" | grep -qP -- '-m\s'; then
  COMMIT_MSG=$(echo "$COMMAND" | grep -oP -- '-m\s+["'"'"']?\K[^"'"'"']+' | head -1)
fi
[[ -z "$COMMIT_MSG" ]] && COMMIT_MSG="$STDOUT"

# Extract task IDs from commit message
IDS=$(sentinel_task_extract_ids "$COMMIT_MSG")
[[ -z "$IDS" ]] && exit 0

# Find task list file
TASK_FILE=$(sentinel_find_task_list) || exit 0

PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
MARKED_COUNT=0

while IFS= read -r task_id; do
  [[ -z "$task_id" ]] && continue

  # Only mark if currently pending or in-progress (not already done)
  if grep -P "^\s*- \[[ ~]\].*${task_id}" "$TASK_FILE" &>/dev/null; then
    sentinel_task_mark "$task_id" "done" "$COMMIT_HASH"
    MARKED_COUNT=$((MARKED_COUNT + 1))
    echo "  [x] ${task_id} — auto-marked done (${COMMIT_HASH})"
  fi
done <<< "$IDS"

if [[ $MARKED_COUNT -gt 0 ]]; then
  echo ""
  echo "📋 [Sentinel Task-Automark] ${MARKED_COUNT} task(s) marked done"

  # Clean up current-task.json if its item_id was just completed
  CURRENT_TASK="${PROJECT_ROOT}/.sentinel/current-task.json"
  if [[ -f "$CURRENT_TASK" ]]; then
    CURRENT_ID=$(jq -r '.task_id // .item_id // empty' "$CURRENT_TASK" 2>/dev/null)
    if [[ -n "$CURRENT_ID" ]] && echo "$IDS" | grep -q "$CURRENT_ID"; then
      rm -f "$CURRENT_TASK"
      echo "  Cleared .sentinel/current-task.json (${CURRENT_ID} completed)"
    fi
  fi

  sentinel_stats_increment "checks"
fi

exit 0
