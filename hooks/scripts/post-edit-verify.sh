#!/bin/bash
# Sentinel PostToolUse Hook: Post-Edit Verification (WARNING)
# Scans edited files for quality issues after edits complete.
# v1.5.0: Per-item configurable actions (block/warn/off).
# Exit 0 = ALLOW (warnings only, never blocks)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/_common.sh"
sentinel_require_jq "post-edit-verify"
sentinel_require_pcre "post-edit-verify"
sentinel_compat_check "post_edit_verify"

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

if [[ "$TOOL_NAME" != "Edit" && "$TOOL_NAME" != "Write" ]]; then
  exit 0
fi

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[[ -z "$FILE_PATH" || ! -f "$FILE_PATH" ]] && exit 0

if ! sentinel_is_source_file "$FILE_PATH"; then exit 0; fi
if sentinel_should_skip "$FILE_PATH"; then exit 0; fi

EXT="${FILE_PATH##*.}"
WARNINGS=""

# 1. Remaining stubs
ACTION=$(sentinel_get_action "analysis" "warn_remaining_stubs" "warn")
if [[ "$ACTION" != "off" ]]; then
  STUB_COUNT=$(grep -cP '^\s+pass\s*$|raise NotImplementedError|# TODO|# FIXME|# HACK|# PLACEHOLDER' "$FILE_PATH" 2>/dev/null || true)
  if [[ $STUB_COUNT -gt 0 ]]; then
    STUB_LINES=$(grep -nP '^\s+pass\s*$|raise NotImplementedError|# TODO|# FIXME|# HACK|# PLACEHOLDER' "$FILE_PATH" | head -5)
    WARNINGS="${WARNINGS}⚠️  ${STUB_COUNT} stub/placeholder(s) remain:\n"
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      WARNINGS="${WARNINGS}  ${line}\n"
    done <<< "$STUB_LINES"
    WARNINGS="${WARNINGS}\n"
  fi
fi

# 2. Python-specific checks
if [[ "$EXT" == "py" ]]; then
  # Missing future annotations
  ACTION=$(sentinel_get_action "analysis" "warn_missing_future_annotations" "warn")
  if [[ "$ACTION" != "off" ]]; then
    LINE_COUNT=$(wc -l < "$FILE_PATH")
    if [[ $LINE_COUNT -gt 10 ]]; then
      if ! head -5 "$FILE_PATH" | grep -qP 'from __future__ import annotations'; then
        WARNINGS="${WARNINGS}⚠️  Missing 'from __future__ import annotations' (Python best practice)\n\n"
      fi
    fi
  fi

  # Missing type hints
  ACTION=$(sentinel_get_action "analysis" "warn_missing_type_hints" "warn")
  if [[ "$ACTION" != "off" ]]; then
    UNTYPED=$(grep -cP '^\s*def\s+\w+\([^)]*\)\s*:' "$FILE_PATH" 2>/dev/null || true)
    TYPED=$(grep -cP '^\s*def\s+\w+\([^)]*\)\s*->' "$FILE_PATH" 2>/dev/null || true)
    MISSING_HINTS=$((UNTYPED - TYPED))
    if [[ $MISSING_HINTS -gt 0 ]]; then
      WARNINGS="${WARNINGS}⚠️  ${MISSING_HINTS} function(s) missing return type hints (def fn() -> ReturnType:)\n\n"
    fi
  fi

  # Bare except
  ACTION=$(sentinel_get_action "analysis" "warn_bare_except" "warn")
  if [[ "$ACTION" != "off" ]]; then
    if grep -qP '^\s*except\s*:' "$FILE_PATH" 2>/dev/null; then
      WARNINGS="${WARNINGS}⚠️  Bare 'except:' found — catch specific exceptions\n\n"
    fi
  fi

  # Print in source code
  ACTION=$(sentinel_get_action "analysis" "warn_print_in_source" "warn")
  if [[ "$ACTION" != "off" ]]; then
    PRINT_COUNT=$(grep -cP '^\s*print\(' "$FILE_PATH" 2>/dev/null || true)
    if [[ $PRINT_COUNT -gt 0 ]]; then
      WARNINGS="${WARNINGS}⚠️  ${PRINT_COUNT} print() call(s) — use logging module instead\n\n"
    fi
  fi
fi

# 3. Silent Error Swallowing (all languages)
ACTION=$(sentinel_get_action "analysis" "warn_silent_error_swallowing" "warn")
if [[ "$ACTION" != "off" ]]; then
  SILENT_EXCEPT=$(grep -cP '^\s*except\s*:\s*$|except\s+\w+.*:\s*(pass|return\s*$|return\s+None|continue)\s*$' "$FILE_PATH" 2>/dev/null || true)
  [[ -z "$SILENT_EXCEPT" ]] && SILENT_EXCEPT=0
  if [[ $SILENT_EXCEPT -gt 0 ]]; then
    WARNINGS="${WARNINGS}⚠️  ${SILENT_EXCEPT} silent error swallowing pattern(s) (except: pass/return None) [Pattern #3]\n\n"
  fi
fi

# 4. Missing Logging in except blocks
ACTION=$(sentinel_get_action "analysis" "warn_missing_logging" "warn")
if [[ "$ACTION" != "off" && "$EXT" == "py" ]]; then
  EXCEPT_BLOCKS=$(grep -cP '^\s*except\s' "$FILE_PATH" 2>/dev/null || true)
  [[ -z "$EXCEPT_BLOCKS" ]] && EXCEPT_BLOCKS=0
  if [[ $EXCEPT_BLOCKS -gt 0 ]]; then
    HAS_LOGGER=$(grep -cP 'logger\.(error|warning|exception|critical|info)' "$FILE_PATH" 2>/dev/null || true)
    [[ -z "$HAS_LOGGER" ]] && HAS_LOGGER=0
    if [[ $EXCEPT_BLOCKS -gt 0 && $HAS_LOGGER -eq 0 ]]; then
      WARNINGS="${WARNINGS}⚠️  ${EXCEPT_BLOCKS} except block(s) but no logger usage — add logging [Pattern #39]\n\n"
    fi
  fi
fi

# 5. Naive datetime
ACTION=$(sentinel_get_action "analysis" "warn_naive_datetime" "warn")
if [[ "$ACTION" != "off" && "$EXT" == "py" ]]; then
  NAIVE_DT=$(grep -cP 'datetime\.now\(\s*\)|datetime\.utcnow\(\)' "$FILE_PATH" 2>/dev/null || true)
  [[ -z "$NAIVE_DT" ]] && NAIVE_DT=0
  if [[ $NAIVE_DT -gt 0 ]]; then
    WARNINGS="${WARNINGS}⚠️  ${NAIVE_DT} naive datetime usage (datetime.now()) — use datetime.now(tz=UTC) or timezone.now() [Pattern #33]\n\n"
  fi
fi

# 6. TypeScript/JS-specific checks
if [[ "$EXT" == "ts" || "$EXT" == "tsx" || "$EXT" == "js" || "$EXT" == "jsx" ]]; then
  # console.log
  ACTION=$(sentinel_get_action "analysis" "warn_console_log" "warn")
  if [[ "$ACTION" != "off" ]]; then
    CONSOLE_COUNT=$(grep -cP '^\s*console\.(log|debug|info)\(' "$FILE_PATH" 2>/dev/null || true)
    if [[ $CONSOLE_COUNT -gt 0 ]]; then
      WARNINGS="${WARNINGS}⚠️  ${CONSOLE_COUNT} console.log() call(s) — remove or use proper logger\n\n"
    fi
  fi

  # any type
  ACTION=$(sentinel_get_action "analysis" "warn_any_type" "warn")
  if [[ "$ACTION" != "off" ]]; then
    ANY_COUNT=$(grep -cP ':\s*any\b' "$FILE_PATH" 2>/dev/null || true)
    if [[ $ANY_COUNT -gt 0 ]]; then
      WARNINGS="${WARNINGS}⚠️  ${ANY_COUNT} 'any' type usage(s) — use specific types\n\n"
    fi
  fi
fi

# 7. Deep AST analysis
ACTION=$(sentinel_get_action "analysis" "deep_ast_analysis" "warn")
if [[ "$ACTION" != "off" && -f "${SCRIPT_DIR}/deep-analyze.py" ]]; then
  DEEP_RESULTS=$(python3 "${SCRIPT_DIR}/deep-analyze.py" --mode post --file "$FILE_PATH" 2>/dev/null | head -15)
  if [[ -n "$DEEP_RESULTS" ]]; then
    DEEP_COUNT=$(echo "$DEEP_RESULTS" | wc -l)
    WARNINGS="${WARNINGS}⚠️  ${DEEP_COUNT} deep pattern issue(s):\n"
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      WARNINGS="${WARNINGS}  ${line}\n"
    done <<< "$DEEP_RESULTS"
    WARNINGS="${WARNINGS}\n"
  fi
fi

if [[ -n "$WARNINGS" ]]; then
  echo "🔍 [Sentinel Post-Edit Verify] $(basename "$FILE_PATH")"
  echo ""
  echo -e "$WARNINGS"
  echo "These are warnings — review and fix if applicable."
  sentinel_stats_increment "warnings"
fi

exit 0
