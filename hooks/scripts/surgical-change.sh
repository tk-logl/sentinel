#!/bin/bash
# Sentinel PreToolUse Hook: Surgical Change Enforcer (WARNING/BLOCKING)
# Enforces minimal diffs. Warns on large edits, blocks risky deletions.
# v1.5.0: Per-item configurable actions (block/warn/off).
# Exit 0 = ALLOW (with warning) | Exit 2 = DENY (confirmed risk)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/_common.sh"
sentinel_require_jq "surgical-change"
sentinel_require_pcre "surgical-change"
sentinel_compat_check "surgical_change"

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

BLOCKS=""
WARNINGS=""

if [[ "$TOOL_NAME" == "Write" ]]; then
  # Check if this is overwriting an existing file (not creating new)
  ACTION=$(sentinel_get_action "editDiscipline" "warn_write_overwrites" "warn")
  if [[ "$ACTION" != "off" && -f "$FILE_PATH" ]]; then
    EXISTING_LINES=$(wc -l < "$FILE_PATH" 2>/dev/null || echo 0)
    if [[ $EXISTING_LINES -gt 20 ]]; then
      MSG="  Write tool overwrites existing file (${EXISTING_LINES} lines)\n"
      MSG="${MSG}   Prefer Edit tool with minimal old_string/new_string diffs.\n"
      MSG="${MSG}   Full file rewrites lose context and risk breaking working code.\n\n"
      [[ "$ACTION" == "block" ]] && BLOCKS="${BLOCKS}${MSG}" || WARNINGS="${WARNINGS}${MSG}"
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
    ACTION=$(sentinel_get_action "editDiscipline" "warn_large_edits" "warn")
    if [[ "$ACTION" != "off" ]]; then
      MAX_LINES=$(sentinel_read_config '.surgical_change_max_lines' '15')
      if [[ $OLD_LINES -gt $MAX_LINES ]]; then
        MSG="  Large edit: replacing ${OLD_LINES} lines -> ${NEW_LINES} lines\n"
        MSG="${MSG}   Break this into smaller, focused edits (one logical change per Edit call).\n\n"
        [[ "$ACTION" == "block" ]] && BLOCKS="${BLOCKS}${MSG}" || WARNINGS="${WARNINGS}${MSG}"
      fi
    fi

    # Detect function/class deletion
    ACTION=$(sentinel_get_action "editDiscipline" "warn_function_deletion" "warn")
    if [[ "$ACTION" != "off" ]]; then
      if echo "$OLD_STRING" | grep -qP '^\s*(def |class |function |const \w+ = |export )' ; then
        if [[ -z "$NEW_STRING" ]] || ! echo "$NEW_STRING" | grep -qP '^\s*(def |class |function |const \w+ = |export )'; then
          FN_NAME=$(echo "$OLD_STRING" | grep -oP '(?:def |class |function )\K\w+' | head -1)
          if [[ -n "$FN_NAME" ]]; then
            MSG="  Deleting function/class: ${FN_NAME}\n"
            MSG="${MSG}   Before deleting, run: grep -rn \"${FN_NAME}\" . --include='*.${FILE_PATH##*.}'\n"
            MSG="${MSG}   Ensure zero callers/importers exist before removing.\n\n"
            [[ "$ACTION" == "block" ]] && BLOCKS="${BLOCKS}${MSG}" || WARNINGS="${WARNINGS}${MSG}"
          fi
        fi
      fi
    fi
  fi
fi

if [[ -n "$BLOCKS" ]]; then
  echo "⛔ [Sentinel Surgical-Change] Edit blocked:"
  echo ""
  echo -e "$BLOCKS"
  echo "Surgical Change Rule: smallest diff possible. Add before replace. Grep before delete."
  sentinel_stats_increment "blocks"
  sentinel_stats_increment "pattern_large_edit"
  exit 2
fi

if [[ -n "$WARNINGS" ]]; then
  echo "🔍 [Sentinel Surgical-Change]"
  echo ""
  echo -e "$WARNINGS"
  echo "Surgical Change Rule: smallest diff possible. Add before replace. Grep before delete."
  sentinel_stats_increment "warnings"
  sentinel_stats_increment "pattern_large_edit"
fi

sentinel_stats_increment "checks"
exit 0
