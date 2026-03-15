#!/bin/bash
# Sentinel PreCompact Hook: State Preservation (STATE SAVE)
# Saves structured 5-section state before context compaction.
# Exit 0 = ALLOW (always)

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
STAGED_STAT=$(git diff --cached --stat 2>/dev/null | tail -1)

# Active task
TASK_INFO=""
TASK_FILE="${PROJECT_ROOT}/.sentinel/current-task.json"
if [[ -f "$TASK_FILE" ]]; then
  TASK_ID=$(jq -r '.task_id // "unknown"' "$TASK_FILE" 2>/dev/null)
  TASK_WHY=$(jq -r '.why // ""' "$TASK_FILE" 2>/dev/null)
  TASK_INFO="Active task: ${TASK_ID} — ${TASK_WHY}"
fi

# Recent errors
ERROR_SUMMARY=""
LOG_FILE="${PROJECT_ROOT}/.sentinel/error-log.jsonl"
if [[ -f "$LOG_FILE" ]]; then
  ERROR_SUMMARY=$(tail -10 "$LOG_FILE" 2>/dev/null | jq -r '"  \(.type): \(.cmd)"' 2>/dev/null | head -5)
fi

# Build the 5-section state file
STATE_CONTENT="# Pre-Compaction State (${TIMESTAMP})
## Trigger: auto | Branch: ${BRANCH}

## 1. Session Intent
${TASK_INFO}
Last commits: $(echo "$RECENT_COMMITS" | head -2 | tr '\n' ' ')

## 2. Modified Files
$(if [[ -n "$GIT_STATUS" ]]; then echo "$GIT_STATUS"; else echo "(no uncommitted changes)"; fi)
Diff summary: ${DIFF_STAT} ${STAGED_STAT}

## 3. Decisions Made
(Record rationale + rejected alternatives during session — filled by AI)

## 4. Current State
Git status:
${GIT_STATUS:-clean}

Recent commits:
${RECENT_COMMITS}

Errors:
${ERROR_SUMMARY:-none}

## 5. Next Steps
(AI should fill: what was in progress, what comes next)

## RECOVERY INSTRUCTIONS:
1. Read this state file FIRST — it has the structured context
2. Check .sentinel/current-task.json for active task
3. Check .sentinel/error-log.jsonl for recent error patterns
4. Do NOT restart completed work
"

# Save to latest + timestamped archive
echo "$STATE_CONTENT" > "${STATE_DIR}/latest.md"
echo "$STATE_CONTENT" > "${STATE_DIR}/${TIMESTAMP}.md"

# Clean old archives (keep last 20)
ls -t "${STATE_DIR}"/20*.md 2>/dev/null | tail -n +21 | xargs -r rm -f

echo "💾 [Sentinel State-Preserve] Saved to .sentinel/state/latest.md"
echo "  Branch: ${BRANCH} | Task: ${TASK_INFO:-none}"

exit 0
