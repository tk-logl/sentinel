#!/bin/bash
# Sentinel PostToolUse Hook: Lint Gate (BLOCKING)
# Runs language-appropriate linters on edited files and blocks if errors found.
# Forces AI to fix lint/type errors immediately after writing code.
# v1.5.1: Per-item configurable actions (block/warn/off).
# Exit 2 = DENY | Exit 0 = ALLOW

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/_common.sh"
sentinel_require_jq "post-edit-lint" "blocking"
sentinel_compat_check "post_edit_lint"

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

if [[ "$TOOL_NAME" != "Edit" && "$TOOL_NAME" != "Write" ]]; then
  exit 0
fi

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[[ -z "$FILE_PATH" || ! -f "$FILE_PATH" ]] && exit 0

# Only check source code files
if ! sentinel_is_source_file "$FILE_PATH"; then
  exit 0
fi

# Skip test/config files
if sentinel_should_skip "$FILE_PATH"; then
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
ACTION=$(sentinel_get_action "codeQuality" "post_edit_lint" "block")
[[ "$ACTION" == "off" ]] && exit 0

EXT="${FILE_PATH##*.}"
VIOLATIONS=""

# --- Python: ruff check ---
if [[ "$EXT" == "py" ]]; then
  if command -v ruff &>/dev/null; then
    # Run ruff check on the single file (fast, <1s)
    RUFF_OUT=$(ruff check "$FILE_PATH" --no-fix --output-format=concise 2>/dev/null)
    RUFF_EXIT=$?
    RUFF_OUT=$(echo "$RUFF_OUT" | head -20)
    if [[ $RUFF_EXIT -ne 0 && -n "$RUFF_OUT" ]]; then
      RUFF_COUNT=$(echo "$RUFF_OUT" | grep -cP '^\S+:\d+:\d+:' 2>/dev/null || true)
      [[ -z "$RUFF_COUNT" || "$RUFF_COUNT" -eq 0 ]] && RUFF_COUNT=1
      VIOLATIONS="${VIOLATIONS}  ruff found ${RUFF_COUNT} issue(s):\n"
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        VIOLATIONS="${VIOLATIONS}    ${line}\n"
      done <<< "$(echo "$RUFF_OUT" | head -10)"
      [[ $(echo "$RUFF_OUT" | wc -l) -gt 10 ]] && VIOLATIONS="${VIOLATIONS}    ... and more\n"
    fi
  fi

  # Run mypy on the single file (type checking)
  # Uses file's own directory to find config; falls back to no-config if plugin errors
  if command -v mypy &>/dev/null; then
    FILE_DIR=$(dirname "$FILE_PATH")
    FILE_BASE=$(basename "$FILE_PATH")
    # First try with project config (from file's directory)
    MYPY_RAW=$(cd "$FILE_DIR" && timeout 15 mypy "$FILE_BASE" --no-color-output --no-error-summary --ignore-missing-imports 2>&1)
    MYPY_EXIT=$?
    # If plugin error, retry without config
    if echo "$MYPY_RAW" | grep -q 'Error importing plugin' 2>/dev/null; then
      MYPY_RAW=$(cd "$FILE_DIR" && timeout 15 mypy "$FILE_BASE" --no-color-output --no-error-summary --ignore-missing-imports --config-file /dev/null 2>&1)
      MYPY_EXIT=$?
    fi
    # Filter to only errors in this specific file (not imports/deps)
    MYPY_OUT=$(echo "$MYPY_RAW" | grep -P "^${FILE_BASE}:\d+: error:" | head -10)
    if [[ -n "$MYPY_OUT" ]]; then
      MYPY_COUNT=$(echo "$MYPY_OUT" | wc -l)
      VIOLATIONS="${VIOLATIONS}  mypy found ${MYPY_COUNT} type error(s):\n"
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        VIOLATIONS="${VIOLATIONS}    ${line}\n"
      done <<< "$MYPY_OUT"
    fi
  fi
fi

# --- TypeScript/JavaScript: tsc type check ---
if [[ "$EXT" == "ts" || "$EXT" == "tsx" ]]; then
  # Find tsconfig.json by walking up from the file
  SEARCH_DIR=$(dirname "$FILE_PATH")
  TSCONFIG=""
  while [[ "$SEARCH_DIR" != "/" && "$SEARCH_DIR" != "." ]]; do
    if [[ -f "$SEARCH_DIR/tsconfig.json" ]]; then
      TSCONFIG="$SEARCH_DIR/tsconfig.json"
      break
    fi
    SEARCH_DIR=$(dirname "$SEARCH_DIR")
  done

  if [[ -n "$TSCONFIG" ]]; then
    TSC_DIR=$(dirname "$TSCONFIG")
    # Check if npx tsc is available (timeout 15s to prevent hangs)
    TSC_OUT=$(cd "$TSC_DIR" && timeout 15 npx tsc --noEmit --pretty false 2>/dev/null | grep "$(basename "$FILE_PATH")" | head -10)
    if [[ -n "$TSC_OUT" ]]; then
      TSC_COUNT=$(echo "$TSC_OUT" | wc -l)
      VIOLATIONS="${VIOLATIONS}  TypeScript found ${TSC_COUNT} type error(s) in this file:\n"
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        VIOLATIONS="${VIOLATIONS}    ${line}\n"
      done <<< "$TSC_OUT"
    fi
  fi
fi

if [[ -n "$VIOLATIONS" ]]; then
  if [[ "$ACTION" == "block" ]]; then
    {
      echo "⛔ [Sentinel Lint-Gate] Lint/type errors in: $(basename "$FILE_PATH")"
      echo ""
      echo -e "Errors:\n${VIOLATIONS}"
      echo "Code must be lint-clean before proceeding."
      echo "→ Fix the errors above, then retry."
    } >&2
    sentinel_stats_increment "blocks"
    sentinel_stats_increment "pattern_lint_errors"
    exit 2
  else
    echo "⚠️ [Sentinel Lint-Gate] Lint/type warnings in: $(basename "$FILE_PATH")"
    echo ""
    echo -e "Warnings:\n${VIOLATIONS}"
    sentinel_stats_increment "warnings"
  fi
fi

sentinel_stats_increment "checks"
exit 0
