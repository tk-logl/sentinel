#!/bin/bash
# Sentinel PostToolUse Hook: ast-grep Structural Analysis (BLOCKING)
# Runs ast-grep YAML rules on edited files for tree-sitter based anti-pattern detection.
# Complements ast-quality-gate.py/ts (Python AST / TS compiler) with cross-language rules.
# Requires: ast-grep CLI (pip install ast-grep-cli OR npm i -g @ast-grep/cli)
# Exit 2 = DENY | Exit 0 = ALLOW

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/_common.sh"
sentinel_require_jq "ast-grep-gate" "blocking"
sentinel_compat_check "ast_grep_gate"

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

# Skip enforcement tools (separator-bounded to avoid false positives like "delegate.py")
BASENAME=$(basename "$FILE_PATH")
case "$BASENAME" in
  *[-_.]gate*|gate[-_.]*|*[-_.]guard*|guard[-_.]*|*[-_.]scan*|scan[-_.]*|*[-_.]check*|check[-_.]*|*[-_.]verify*|verify[-_.]*|*[-_.]lint*|lint[-_.]*|*[-_.]analyz*|analyz*|*[-_.]detect*|detect[-_.]*|*[-_.]enforc*|enforc*) exit 0 ;;
esac
case "$FILE_PATH" in
  */sentinel/hooks/*|*/sentinel/scripts/*|*/.claude/plugins/*|*/.claude/hooks/*) exit 0 ;;
esac

# Check per-item action
ACTION=$(sentinel_get_action "codeQuality" "ast_grep_gate" "block")
[[ "$ACTION" == "off" ]] && exit 0

# Check if ast-grep is available
if ! command -v ast-grep &>/dev/null; then
  # Warn once per session that ast-grep is not installed
  AST_GREP_WARNED="${TMPDIR:-/tmp}/.sentinel-ast-grep-warned"
  if [[ ! -f "$AST_GREP_WARNED" ]]; then
    echo "⚠️ [Sentinel] ast-grep CLI not installed — structural anti-pattern rules disabled"
    echo "  Install: pip install ast-grep-cli"
    touch "$AST_GREP_WARNED"
  fi
  exit 0
fi

EXT="${FILE_PATH##*.}"
RULES_DIR="${SCRIPT_DIR}/../rules"
RULE_FILE=""

# Select rule file based on extension
case "$EXT" in
  py)
    RULE_FILE="${RULES_DIR}/python-antipatterns.yml"
    ;;
  ts|tsx|js|jsx)
    RULE_FILE="${RULES_DIR}/typescript-antipatterns.yml"
    ;;
esac

[[ -z "$RULE_FILE" || ! -f "$RULE_FILE" ]] && exit 0

# Run ast-grep scan on the single file with the rule file
# --report-style short for compact output
SCAN_OUT=$(timeout 10 ast-grep scan -r "$RULE_FILE" "$FILE_PATH" 2>/dev/null)
SCAN_EXIT=$?

# ast-grep exit 1 = errors found, exit 0 = clean, exit >1 = tool error
if [[ $SCAN_EXIT -eq 1 && -n "$SCAN_OUT" ]]; then
  # Count errors vs warnings
  ERROR_COUNT=$(echo "$SCAN_OUT" | grep -c '^error\[' 2>/dev/null || true)
  WARN_COUNT=$(echo "$SCAN_OUT" | grep -c '^warning\[' 2>/dev/null || true)
  [[ -z "$ERROR_COUNT" ]] && ERROR_COUNT=0
  [[ -z "$WARN_COUNT" ]] && WARN_COUNT=0

  # Extract violation summaries (rule id + message lines)
  if [[ $ERROR_COUNT -gt 0 ]]; then
    if [[ "$ACTION" == "block" ]]; then
      {
        echo "⛔ [Sentinel ast-grep Gate] Structural anti-patterns in: $(basename "$FILE_PATH")"
        echo ""
        echo "Found ${ERROR_COUNT} error(s), ${WARN_COUNT} warning(s):"
        echo ""
        echo "$SCAN_OUT" | head -40
        echo ""
        echo "These are AST-level issues that cannot be bypassed with formatting tricks."
        echo "→ Fix the structural problems above, then retry."
      } >&2
      sentinel_stats_increment "blocks"
      sentinel_stats_increment "pattern_ast_grep"
      exit 2
    else
      echo "⚠️ [Sentinel ast-grep Gate] Structural warnings in: $(basename "$FILE_PATH")"
      echo ""
      echo "$SCAN_OUT" | head -20
      sentinel_stats_increment "warnings"
    fi
  elif [[ $WARN_COUNT -gt 0 ]]; then
    # Warnings only — always warn, never block
    echo "⚠️ [Sentinel ast-grep Gate] Warnings in: $(basename "$FILE_PATH")"
    echo ""
    echo "$SCAN_OUT" | head -20
    sentinel_stats_increment "warnings"
  fi
fi

sentinel_stats_increment "checks"
exit 0
