#!/bin/bash
# Sentinel PreCompact Hook: State Preservation (STATE SAVE)
# Saves structured 5-section state before context compaction.
# All sections auto-populated — no placeholder text.
# Exit 0 = ALLOW (always)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/_common.sh"
source "${SCRIPT_DIR}/_state-common.sh"

# Read stdin for transcript_path (available in hook context)
INPUT=$(cat)
if [[ "$SENTINEL_NO_JQ" == "0" ]]; then
  TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)
  export TRANSCRIPT_PATH
fi

OUTPUT=$(sentinel_save_state "auto" "true")

if [[ -n "$OUTPUT" ]]; then
  BRANCH=$(git branch --show-current 2>/dev/null || echo "unknown")
  TASK_FILE="$(git rev-parse --show-toplevel 2>/dev/null)/.sentinel/current-task.json"
  TASK_INFO=""
  if [[ -f "$TASK_FILE" && "$SENTINEL_NO_JQ" == "0" ]]; then
    TASK_ID=$(jq -r '.task_id // .item_id // "unknown"' "$TASK_FILE" 2>/dev/null)
    TASK_INFO="Task: ${TASK_ID}"
  fi
  echo "💾 [Sentinel State-Preserve] Saved to .sentinel/state/latest.md"
  echo "  Branch: ${BRANCH} | ${TASK_INFO:-no active task}"
fi

exit 0
