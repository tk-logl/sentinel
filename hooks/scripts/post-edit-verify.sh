#!/bin/bash
# Sentinel PostToolUse Hook: Post-Edit Verification (WARNING)
# Scans edited files for quality issues after edits complete.
# Exit 0 = ALLOW (warnings only, never blocks)

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

# 3. TypeScript/JS-specific checks
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

if [[ -n "$WARNINGS" ]]; then
  echo "🔍 [Sentinel Post-Edit Verify] $(basename "$FILE_PATH")"
  echo ""
  echo -e "$WARNINGS"
  echo "These are warnings — review and fix if applicable."
fi

exit 0
