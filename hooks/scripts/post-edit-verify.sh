#!/bin/bash
# Sentinel PostToolUse Hook: Post-Edit Verification (WARNING)
# Scans edited files for quality issues after edits complete.
# Exit 0 = ALLOW (warnings only, never blocks)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/_common.sh"
sentinel_require_jq "post-edit-verify"
sentinel_require_pcre "post-edit-verify"

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

if [[ "$TOOL_NAME" != "Edit" && "$TOOL_NAME" != "Write" ]]; then
  exit 0
fi

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[[ -z "$FILE_PATH" || ! -f "$FILE_PATH" ]] && exit 0

# Only check source code
EXT="${FILE_PATH##*.}"
case "$EXT" in
  py|ts|tsx|js|jsx|go|rs) ;;
  *) exit 0 ;;
esac

# Skip test/config files
if echo "$FILE_PATH" | grep -qP '(\.test\.|\.spec\.|/tests/|/test_|_test\.|\.sentinel|\.claude|\.omc)'; then
  exit 0
fi

WARNINGS=""

# 1. Check for remaining stubs
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

# 2. Python-specific checks
if [[ "$EXT" == "py" ]]; then
  # Check for future annotations
  LINE_COUNT=$(wc -l < "$FILE_PATH")
  if [[ $LINE_COUNT -gt 10 ]]; then
    if ! head -5 "$FILE_PATH" | grep -qP 'from __future__ import annotations'; then
      WARNINGS="${WARNINGS}⚠️  Missing 'from __future__ import annotations' (Python best practice)\n\n"
    fi
  fi

  # Check for functions missing type hints
  UNTYPED=$(grep -cP '^\s*def\s+\w+\([^)]*\)\s*:' "$FILE_PATH" 2>/dev/null || true)
  TYPED=$(grep -cP '^\s*def\s+\w+\([^)]*\)\s*->' "$FILE_PATH" 2>/dev/null || true)
  MISSING_HINTS=$((UNTYPED - TYPED))
  if [[ $MISSING_HINTS -gt 0 ]]; then
    WARNINGS="${WARNINGS}⚠️  ${MISSING_HINTS} function(s) missing return type hints (def fn() -> ReturnType:)\n\n"
  fi

  # Check for bare except
  if grep -qP '^\s*except\s*:' "$FILE_PATH" 2>/dev/null; then
    WARNINGS="${WARNINGS}⚠️  Bare 'except:' found — catch specific exceptions\n\n"
  fi

  # Check for print() in non-test code
  PRINT_COUNT=$(grep -cP '^\s*print\(' "$FILE_PATH" 2>/dev/null || true)
  if [[ $PRINT_COUNT -gt 0 ]]; then
    WARNINGS="${WARNINGS}⚠️  ${PRINT_COUNT} print() call(s) — use logging module instead\n\n"
  fi
fi

# 3. Pattern #3: Silent Error Swallowing (all languages)
SILENT_EXCEPT=$(grep -cP '^\s*except\s*:\s*$|except\s+\w+.*:\s*(pass|return\s*$|return\s+None|continue)\s*$' "$FILE_PATH" 2>/dev/null || true)
[[ -z "$SILENT_EXCEPT" ]] && SILENT_EXCEPT=0
if [[ $SILENT_EXCEPT -gt 0 ]]; then
  WARNINGS="${WARNINGS}⚠️  ${SILENT_EXCEPT} silent error swallowing pattern(s) (except: pass/return None) [Pattern #3]\n\n"
fi

# 4. Pattern #39: Missing Logging in except blocks
if [[ "$EXT" == "py" ]]; then
  EXCEPT_BLOCKS=$(grep -cP '^\s*except\s' "$FILE_PATH" 2>/dev/null || true)
  [[ -z "$EXCEPT_BLOCKS" ]] && EXCEPT_BLOCKS=0
  LOGGED_EXCEPTS=$(grep -cP '^\s*except\s.*:.*$' "$FILE_PATH" 2>/dev/null || true)
  [[ -z "$LOGGED_EXCEPTS" ]] && LOGGED_EXCEPTS=0
  if [[ $EXCEPT_BLOCKS -gt 0 ]]; then
    # Check if logger is used anywhere near except blocks
    HAS_LOGGER=$(grep -cP 'logger\.(error|warning|exception|critical|info)' "$FILE_PATH" 2>/dev/null || true)
    [[ -z "$HAS_LOGGER" ]] && HAS_LOGGER=0
    if [[ $EXCEPT_BLOCKS -gt 0 && $HAS_LOGGER -eq 0 ]]; then
      WARNINGS="${WARNINGS}⚠️  ${EXCEPT_BLOCKS} except block(s) but no logger usage — add logging [Pattern #39]\n\n"
    fi
  fi
fi

# 5. Pattern #33: Timezone Bug — datetime.now() without tz
if [[ "$EXT" == "py" ]]; then
  NAIVE_DT=$(grep -cP 'datetime\.now\(\s*\)|datetime\.utcnow\(\)' "$FILE_PATH" 2>/dev/null || true)
  [[ -z "$NAIVE_DT" ]] && NAIVE_DT=0
  if [[ $NAIVE_DT -gt 0 ]]; then
    WARNINGS="${WARNINGS}⚠️  ${NAIVE_DT} naive datetime usage (datetime.now()) — use datetime.now(tz=UTC) or timezone.now() [Pattern #33]\n\n"
  fi
fi

# 6. TypeScript/JS-specific checks
if [[ "$EXT" == "ts" || "$EXT" == "tsx" || "$EXT" == "js" || "$EXT" == "jsx" ]]; then
  # Check for console.log
  CONSOLE_COUNT=$(grep -cP '^\s*console\.(log|debug|info)\(' "$FILE_PATH" 2>/dev/null || true)
  if [[ $CONSOLE_COUNT -gt 0 ]]; then
    WARNINGS="${WARNINGS}⚠️  ${CONSOLE_COUNT} console.log() call(s) — remove or use proper logger\n\n"
  fi

  # Check for 'any' type
  ANY_COUNT=$(grep -cP ':\s*any\b' "$FILE_PATH" 2>/dev/null || true)
  if [[ $ANY_COUNT -gt 0 ]]; then
    WARNINGS="${WARNINGS}⚠️  ${ANY_COUNT} 'any' type usage(s) — use specific types\n\n"
  fi
fi

# 7. Deep AST analysis on full file (patterns grep can't catch)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ -f "${SCRIPT_DIR}/deep-analyze.py" ]]; then
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
fi

exit 0
