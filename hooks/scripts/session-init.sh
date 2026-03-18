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

# 8. Version check (non-blocking, cached once per day)
SENTINEL_VERSION="1.3.0"
VERSION_CACHE="/tmp/.sentinel-version-check"
VERSION_CHECK_INTERVAL=86400  # 24 hours

should_check_version() {
  [[ ! -f "$VERSION_CACHE" ]] && return 0
  local last_check
  last_check=$(stat -c %Y "$VERSION_CACHE" 2>/dev/null || stat -f %m "$VERSION_CACHE" 2>/dev/null || echo 0)
  local now
  now=$(date +%s)
  [[ $((now - last_check)) -gt $VERSION_CHECK_INTERVAL ]]
}

if should_check_version && command -v curl &>/dev/null; then
  # Fetch latest version from GitHub API (timeout 3s, non-blocking)
  LATEST_JSON=$(curl -s --max-time 3 "https://api.github.com/repos/tk-logl/sentinel/releases/latest" 2>/dev/null || true)
  if [[ -n "$LATEST_JSON" ]]; then
    LATEST_VERSION=$(echo "$LATEST_JSON" | jq -r '.tag_name // empty' 2>/dev/null | sed 's/^v//')
    echo "$LATEST_VERSION" > "$VERSION_CACHE" 2>/dev/null || true
    if [[ -n "$LATEST_VERSION" && "$LATEST_VERSION" != "$SENTINEL_VERSION" ]]; then
      echo "=== Sentinel Update Available ==="
      echo "  Current: v${SENTINEL_VERSION} → Latest: v${LATEST_VERSION}"
      echo "  Update: claude plugin install github:tk-logl/sentinel"
      echo ""
    fi
  else
    # Cache empty result to avoid repeated failed checks
    touch "$VERSION_CACHE" 2>/dev/null || true
  fi
elif [[ -f "$VERSION_CACHE" ]]; then
  CACHED_VERSION=$(cat "$VERSION_CACHE" 2>/dev/null)
  if [[ -n "$CACHED_VERSION" && "$CACHED_VERSION" != "$SENTINEL_VERSION" ]]; then
    echo "=== Sentinel Update Available ==="
    echo "  Current: v${SENTINEL_VERSION} → Latest: v${CACHED_VERSION}"
    echo "  Update: claude plugin install github:tk-logl/sentinel"
    echo ""
  fi
fi

echo "=== Sentinel Active ==="
if [[ "$SENTINEL_NO_PCRE" == "1" || "$SENTINEL_NO_JQ" == "1" ]]; then
  echo "⛔ DEGRADED MODE — missing dependencies disable protection:"
  if [[ "$SENTINEL_NO_JQ" == "1" ]]; then
    echo "  BLOCKED (jq missing — these hooks REFUSE all edits until jq is installed):"
    echo "    - secret-scan, deny-dummy, pre-edit-gate, env-safety"
    echo "  DISABLED (jq missing — these hooks silently skip):"
    echo "    - surgical-change, scope-guard, post-edit-verify, error-logger,"
    echo "      file-header-check, completion-check, state-preserve, session-save"
  fi
  if [[ "$SENTINEL_NO_PCRE" == "1" ]]; then
    echo "  DISABLED (PCRE grep missing — pattern matching unavailable):"
    echo "    - All hooks that use regex pattern detection"
  fi
  echo ""
  echo "  FIX: Install missing tools to enable full protection."
  echo "  Linux: sudo apt install jq    macOS: brew install grep jq"
else
  echo "Enforcement: pre-edit-gate, deny-dummy, surgical-change, scope-guard,"
  echo "             secret-scan, env-safety, error-logger, post-edit-verify"
fi
echo ""

# Reset session stats for new session
if [[ -n "$PROJECT_ROOT" ]]; then
  mkdir -p "${PROJECT_ROOT}/.sentinel"
  cat > "${PROJECT_ROOT}/.sentinel/stats.json" << 'STATS_EOF'
{"session_start":"","checks":0,"blocks":0,"warnings":0,"patterns":{}}
STATS_EOF
fi
exit 0
