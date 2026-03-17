#!/bin/bash
# Sentinel SessionEnd Hook: Session State Save (STATE SAVE)
# Saves state on session end (/clear, exit). Same logic as state-preserve.
# Exit 0 = ALLOW (always)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/_common.sh"
# jq is optional — graceful fallback if missing

PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
[[ -z "$PROJECT_ROOT" ]] && exit 0

STATE_DIR="${PROJECT_ROOT}/.sentinel/state"
mkdir -p "$STATE_DIR"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BRANCH=$(git branch --show-current 2>/dev/null || echo "unknown")

# Gather data
GIT_STATUS=$(git status --porcelain 2>/dev/null | head -20)
RECENT_COMMITS=$(git log --oneline -5 2>/dev/null)
DIFF_STAT=$(git diff --stat 2>/dev/null | tail -1)

# Active task
TASK_INFO=""
TASK_FILE="${PROJECT_ROOT}/.sentinel/current-task.json"
if [[ -f "$TASK_FILE" ]]; then
  TASK_ID=$(jq -r '.task_id // "unknown"' "$TASK_FILE" 2>/dev/null)
  TASK_WHY=$(jq -r '.why // ""' "$TASK_FILE" 2>/dev/null)
  TASK_INFO="Active task: ${TASK_ID} — ${TASK_WHY}"
fi

# Build state file
STATE_CONTENT="# Session End State (${TIMESTAMP})
## Trigger: session-end | Branch: ${BRANCH}

## 1. Session Intent
${TASK_INFO}
Last commits: $(echo "$RECENT_COMMITS" | head -2 | tr '\n' ' ')

## 2. Modified Files
$(if [[ -n "$GIT_STATUS" ]]; then echo "$GIT_STATUS"; else echo "(no uncommitted changes)"; fi)
Diff summary: ${DIFF_STAT}

## 3. Decisions Made
(Preserved from session)

## 4. Current State
Git status:
${GIT_STATUS:-clean}

Recent commits:
${RECENT_COMMITS}

## 5. Next Steps
(Resume from where session ended)

## RECOVERY INSTRUCTIONS:
1. Read this state file on next session start
2. Check .sentinel/current-task.json for active task
3. Resume incomplete work
"

echo "$STATE_CONTENT" > "${STATE_DIR}/latest.md"
echo "$STATE_CONTENT" > "${STATE_DIR}/${TIMESTAMP}.md"

# Clean old archives
ls -t "${STATE_DIR}"/20*.md 2>/dev/null | tail -n +21 | xargs -r rm -f

echo "💾 [Sentinel Session-Save] State saved for next session"

exit 0
