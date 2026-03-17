#!/bin/bash
# Sentinel PostToolUse Hook: File Header Check (WARNING)
# Checks that key files (200+ lines) have descriptive headers.
# Exit 0 = ALLOW (warning only)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/_common.sh"
sentinel_require_jq "file-header-check"
sentinel_require_pcre "file-header-check"

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
  py|ts|tsx|js|jsx|go|rs|java) ;;
  *) exit 0 ;;
esac

# Skip test/config files
if echo "$FILE_PATH" | grep -qP '(\.test\.|\.spec\.|/tests/|/test_|_test\.|\.sentinel|\.claude|\.omc)'; then
  exit 0
fi

# Read config for threshold
PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
THRESHOLD=200
if [[ -n "$PROJECT_ROOT" && -f "${PROJECT_ROOT}/.sentinel/config.json" ]]; then
  CUSTOM_THRESHOLD=$(jq -r '.header_threshold_lines // empty' "${PROJECT_ROOT}/.sentinel/config.json" 2>/dev/null)
  [[ -n "$CUSTOM_THRESHOLD" ]] && THRESHOLD=$CUSTOM_THRESHOLD
fi

# Check line count
LINE_COUNT=$(wc -l < "$FILE_PATH" 2>/dev/null || echo 0)
[[ $LINE_COUNT -lt $THRESHOLD ]] && exit 0

# Check if header exists (look for structured comment block in first 15 lines)
HEADER_EXISTS=false
HEAD_CONTENT=$(head -15 "$FILE_PATH")

case "$EXT" in
  py)
    # Python: look for docstring or # comment block with role/purpose
    if echo "$HEAD_CONTENT" | grep -qP '""".*role|""".*purpose|# ={3,}|# -{3,}|# File:|# Role:|# Purpose:'; then
      HEADER_EXISTS=true
    fi
    ;;
  ts|tsx|js|jsx)
    # JS/TS: look for /** block or // block with role/purpose
    if echo "$HEAD_CONTENT" | grep -qP '/\*\*|// ={3,}|// -{3,}|// File:|// Role:|// Purpose:'; then
      HEADER_EXISTS=true
    fi
    ;;
  go)
    if echo "$HEAD_CONTENT" | grep -qP '// Package|// File:|// Role:'; then
      HEADER_EXISTS=true
    fi
    ;;
  rs)
    if echo "$HEAD_CONTENT" | grep -qP '//!|// File:|// Role:'; then
      HEADER_EXISTS=true
    fi
    ;;
  java)
    if echo "$HEAD_CONTENT" | grep -qP '/\*\*|// File:|// Role:'; then
      HEADER_EXISTS=true
    fi
    ;;
esac

if [[ "$HEADER_EXISTS" == "false" ]]; then
  echo "📝 [Sentinel File-Header] $(basename "$FILE_PATH") (${LINE_COUNT} lines) has no header"
  echo ""
  echo "  Files over ${THRESHOLD} lines benefit from a descriptive header (5-12 lines):"
  echo ""
  case "$EXT" in
    py)
      echo '  """'
      echo "  $(basename "$FILE_PATH") — [Role: what this file does]"
      echo "  "
      echo "  Co-modify: [2-4 files that change together with this one]"
      echo "  Invariants: [2-3 things that must never break]"
      echo "  Verify: [1-2 commands to confirm changes work]"
      echo '  """'
      ;;
    ts|tsx|js|jsx)
      echo "  /**"
      echo "   * $(basename "$FILE_PATH") — [Role: what this file does]"
      echo "   *"
      echo "   * Co-modify: [2-4 files that change together with this one]"
      echo "   * Invariants: [2-3 things that must never break]"
      echo "   * Verify: [1-2 commands to confirm changes work]"
      echo "   */"
      ;;
  esac
  echo ""
  echo "  Use /sentinel:header $(basename "$FILE_PATH") to generate one."
fi

exit 0
