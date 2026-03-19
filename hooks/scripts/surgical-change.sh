#!/bin/bash
# Sentinel PreToolUse Hook: Surgical Change Enforcer (WARNING/BLOCKING)
# Enforces minimal diffs. Warns on large edits, blocks risky deletions.
# Exit 0 = ALLOW (with warning) | Exit 2 = DENY (confirmed risk)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/_common.sh"
sentinel_require_jq "surgical-change"
sentinel_require_pcre "surgical-change"
sentinel_check_enabled "surgical_change"

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

if [[ "$TOOL_NAME" != "Edit" && "$TOOL_NAME" != "Write" ]]; then
  exit 0
fi

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[[ -z "$FILE_PATH" ]] && exit 0

# Only check source code (config-driven extensions)
if ! sentinel_is_source_file "$FILE_PATH"; then exit 0; fi

# Skip test files, config dirs, and user-configured skip patterns
if sentinel_should_skip "$FILE_PATH"; then exit 0; fi

WARNINGS=""

if [[ "$TOOL_NAME" == "Write" ]]; then
  # Check if this is overwriting an existing file (not creating new)
  if [[ -f "$FILE_PATH" ]]; then
    EXISTING_LINES=$(wc -l < "$FILE_PATH" 2>/dev/null || echo 0)
    NEW_CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // empty' 2>/dev/null)
    NEW_LINES=$(echo "$NEW_CONTENT" | wc -l)

    if [[ $EXISTING_LINES -gt 20 ]]; then
      WARNINGS="${WARNINGS}⚠️  Write tool overwrites existing file (${EXISTING_LINES} lines)\n"
      WARNINGS="${WARNINGS}   Prefer Edit tool with minimal old_string/new_string diffs.\n"
      WARNINGS="${WARNINGS}   Full file rewrites lose context and risk breaking working code.\n\n"
    fi
  fi
fi

if [[ "$TOOL_NAME" == "Edit" ]]; then
  OLD_STRING=$(echo "$INPUT" | jq -r '.tool_input.old_string // empty' 2>/dev/null)
  NEW_STRING=$(echo "$INPUT" | jq -r '.tool_input.new_string // empty' 2>/dev/null)

  if [[ -n "$OLD_STRING" ]]; then
    OLD_LINES=$(echo "$OLD_STRING" | wc -l)
    NEW_LINES=$(echo "$NEW_STRING" | wc -l)

    # Warn on large replacements (configurable threshold)
    MAX_LINES=$(sentinel_read_config '.surgical_change_max_lines' '15')
    if [[ $OLD_LINES -gt $MAX_LINES ]]; then
      WARNINGS="${WARNINGS}⚠️  Large edit: replacing ${OLD_LINES} lines → ${NEW_LINES} lines\n"
      WARNINGS="${WARNINGS}   Break this into smaller, focused edits (one logical change per Edit call).\n\n"
    fi

    # Detect function/class deletion (old_string has def/class, new_string doesn't)
    if echo "$OLD_STRING" | grep -qP '^\s*(def |class |function |const \w+ = |export )' ; then
      if [[ -z "$NEW_STRING" ]] || ! echo "$NEW_STRING" | grep -qP '^\s*(def |class |function |const \w+ = |export )'; then
        FN_NAME=$(echo "$OLD_STRING" | grep -oP '(?:def |class |function )\K\w+' | head -1)
        if [[ -n "$FN_NAME" ]]; then
          WARNINGS="${WARNINGS}⚠️  Deleting function/class: ${FN_NAME}\n"
          WARNINGS="${WARNINGS}   Before deleting, run: grep -rn \"${FN_NAME}\" . --include='*.${FILE_PATH##*.}'\n"
          WARNINGS="${WARNINGS}   Ensure zero callers/importers exist before removing.\n\n"
        fi
      fi
    fi
  fi
fi

if [[ -n "$WARNINGS" ]]; then
  echo "🔍 [Sentinel Surgical-Change]"
  echo ""
  echo -e "$WARNINGS"
  echo "Surgical Change Rule: smallest diff possible. Add before replace. Grep before delete."
  sentinel_stats_increment "warnings"
  sentinel_stats_increment "pattern_large_edit"
fi

exit 0
