#!/bin/bash
# Sentinel SessionStart Hook: Session Initialization (CONTEXT INJECTION)
# Injects environment status and previous session state on startup.
# Exit 0 = ALLOW (context only)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/_common.sh"
# jq is optional here — graceful fallback if missing

PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)

echo "=== Sentinel Session Init ==="

# 1. Environment snapshot
echo "Host: $(hostname) | OS: $(uname -sr)"
command -v python3 &>/dev/null && echo "Python: $(python3 --version 2>&1)"
command -v node &>/dev/null && echo "Node: $(node --version 2>&1)"
command -v go &>/dev/null && echo "Go: $(go version 2>&1 | awk '{print $3}')"

if [[ -n "$PROJECT_ROOT" ]]; then
  BRANCH=$(git branch --show-current 2>/dev/null)
  echo "Git branch: ${BRANCH:-detached}"
  echo ""

  # 2. Recent commits
  echo "Recent commits:"
  git log --oneline -5 2>/dev/null | sed 's/^/  /'
  echo ""

  # 3. Previous session state
  STATE_FILE="${PROJECT_ROOT}/.sentinel/state/latest.md"
  if [[ -f "$STATE_FILE" ]]; then
    echo "=== Previous Session State ==="
    cat "$STATE_FILE"
    echo ""
  fi

  # 4. Error pattern summary (last 10 errors, grouped by type)
  LOG_FILE="${PROJECT_ROOT}/.sentinel/error-log.jsonl"
  if [[ -f "$LOG_FILE" ]]; then
    RECENT_ERRORS=$(tail -20 "$LOG_FILE" 2>/dev/null | jq -r '.type' 2>/dev/null | sort | uniq -c | sort -rn | head -5)
    if [[ -n "$RECENT_ERRORS" ]]; then
      echo "=== Recent Error Patterns ==="
      echo "$RECENT_ERRORS" | sed 's/^/  /'
      echo ""
    fi
  fi

  # 5. Current task status
  TASK_FILE="${PROJECT_ROOT}/.sentinel/current-task.json"
  if [[ -f "$TASK_FILE" ]]; then
    TASK_ID=$(jq -r '.task_id // "unknown"' "$TASK_FILE" 2>/dev/null)
    TASK_WHY=$(jq -r '.why // "no reason given"' "$TASK_FILE" 2>/dev/null)
    echo "=== Active Task ==="
    echo "  ID: ${TASK_ID}"
    echo "  Why: ${TASK_WHY}"
    echo "  → Resume this task or clean up .sentinel/current-task.json"
    echo ""
  fi

  # 6. Uncommitted changes
  DIRTY=$(git status --porcelain 2>/dev/null | head -10)
  if [[ -n "$DIRTY" ]]; then
    DIRTY_COUNT=$(git status --porcelain 2>/dev/null | wc -l)
    echo "=== Uncommitted Changes (${DIRTY_COUNT} files) ==="
    echo "$DIRTY" | sed 's/^/  /'
    echo ""
  fi

  # 7. OMC (oh-my-claudecode) integration — detect and inject OMC state
  if [[ -d "${PROJECT_ROOT}/.omc" ]]; then
    echo "=== OMC Integration Detected ==="

    # Notepad priority section (session memory)
    if [[ -f "${PROJECT_ROOT}/.omc/notepad.md" ]]; then
      PRIORITY=$(sed -n '/^## Priority/,/^## /p' "${PROJECT_ROOT}/.omc/notepad.md" 2>/dev/null | head -10)
      if [[ -n "$PRIORITY" ]]; then
        echo "OMC Notepad (priority):"
        echo "$PRIORITY" | sed 's/^/  /'
        echo ""
      fi
    fi

    # OMC compaction state (latest)
    if [[ -f "${PROJECT_ROOT}/.omc/compactions/latest.md" ]]; then
      echo "OMC compaction state available at .omc/compactions/latest.md"
    fi

    # Active OMC mode detection
    for MODE_FILE in "${PROJECT_ROOT}"/.omc/state/*-state.json; do
      [[ -f "$MODE_FILE" ]] || continue
      if [[ "$SENTINEL_NO_JQ" == "0" ]]; then
        IS_ACTIVE=$(jq -r '.active // false' "$MODE_FILE" 2>/dev/null)
        MODE_NAME=$(basename "$MODE_FILE" | sed 's/-state\.json//')
        if [[ "$IS_ACTIVE" == "true" ]]; then
          echo "  OMC mode active: ${MODE_NAME}"
        fi
      fi
    done
    echo ""
  fi
fi

# Platform compatibility status
COMPAT_ISSUES=""
if [[ "$SENTINEL_NO_PCRE" == "1" ]]; then
  COMPAT_ISSUES="${COMPAT_ISSUES}  ⚠️ No PCRE grep — pattern detection disabled (brew install grep on macOS)\n"
fi
if [[ "$SENTINEL_NO_JQ" == "1" ]]; then
  COMPAT_ISSUES="${COMPAT_ISSUES}  ⚠️ No jq — JSON parsing disabled (apt/brew install jq)\n"
fi
if [[ -n "$COMPAT_ISSUES" ]]; then
  echo "=== Platform Compatibility ==="
  echo -e "$COMPAT_ISSUES"
fi

echo "=== Sentinel Active ==="
echo "Enforcement: pre-edit-gate, deny-dummy, surgical-change, scope-guard,"
echo "             secret-scan, env-safety, error-logger, post-edit-verify"
if [[ "$SENTINEL_NO_PCRE" == "1" || "$SENTINEL_NO_JQ" == "1" ]]; then
  echo "  (some hooks degraded — see Platform Compatibility above)"
fi
echo ""

exit 0
