#!/bin/bash
# Sentinel PreToolUse Hook: Scope Reduction Guard (BLOCKING)
# Blocks code edits that contain scope-reduction language in comments.
# v1.5.0: Per-item configurable actions (block/warn/off).
# Exit 2 = DENY | Exit 0 = ALLOW

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/_common.sh"
sentinel_require_jq "scope-reduction-guard" "blocking"
sentinel_require_pcre "scope-reduction-guard" "blocking"
sentinel_compat_check "scope_reduction_guard"

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

if [[ "$TOOL_NAME" != "Edit" && "$TOOL_NAME" != "Write" ]]; then
  exit 0
fi

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[[ -z "$FILE_PATH" ]] && exit 0

# Only check source code files
if ! sentinel_is_source_file "$FILE_PATH"; then
  exit 0
fi

# Skip test/config files
if sentinel_should_skip "$FILE_PATH"; then
  exit 0
fi

# Skip enforcement/analysis tools — they legitimately reference the patterns they detect.
# A quality gate describing "detects empty functions" is not scope reduction.
BASENAME=$(basename "$FILE_PATH")
case "$BASENAME" in
  *gate*|*guard*|*scan*|*check*|*verify*|*lint*|*analyz*|*detect*|*enforc*) exit 0 ;;
esac
case "$FILE_PATH" in
  */sentinel/hooks/*|*/sentinel/scripts/*|*/.claude/plugins/*|*/.claude/hooks/*) exit 0 ;;
esac

# Check per-item action
ACTION=$(sentinel_get_action "codeQuality" "block_scope_reduction_comments")
[[ "$ACTION" == "off" ]] && exit 0

# Get content being written
if [[ "$TOOL_NAME" == "Write" ]]; then
  CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // empty' 2>/dev/null)
elif [[ "$TOOL_NAME" == "Edit" ]]; then
  CONTENT=$(echo "$INPUT" | jq -r '.tool_input.new_string // empty' 2>/dev/null)
fi

[[ -z "$CONTENT" ]] && exit 0

# Extract only comment lines (where scope-reduction language is problematic)
COMMENT_LINES=$(echo "$CONTENT" | grep -P '^\s*(#|//|/\*|\*)' 2>/dev/null)
[[ -z "$COMMENT_LINES" ]] && exit 0

VIOLATIONS=""

# Korean scope-reduction patterns (21 groups)
KO_PATTERN='일단\s*(기본|간단|최소|대충)|나중에\s*(구현|추가|개선|처리|하자)|임시\s*(로|처리|코드|구현)|기본만\s*(구현|처리)|간소화\s*(된|한|하여)|단순화\s*(된|한|하여|버전)|추후\s*(개선|구현|추가|확장)|향후\s*(추가|개선|구현)|당분간|우선\s*(이것만|기본)|최소한(만|으로)|대충\s*(처리|구현|넣)|다음에\s*(하자|처리|추가|구현)|급한\s*대로|임시방편|생략\s*(하|된|한)|핵심만\s*(우선|먼저)|나머지는\s*(나중|추후|향후)|스킵\s*(하고|해도)|간략(히|하게)\s*(구현|처리)|대략적(인|으로)\s*(구현|처리)'
if echo "$COMMENT_LINES" | grep -qP "$KO_PATTERN" 2>/dev/null; then
  MATCH=$(echo "$COMMENT_LINES" | grep -oP "$KO_PATTERN" 2>/dev/null | head -3)
  while IFS= read -r m; do
    [[ -z "$m" ]] && continue
    VIOLATIONS="${VIOLATIONS}  - Korean scope reduction: '$(sentinel_sanitize "$m")'\n"
  done <<< "$MATCH"
fi

# English scope-reduction patterns (16 patterns)
EN_PATTERN='simplified?\s+(version|implementation|approach)|for\s+now|basic\s+(version|only|implementation)|placeholder|skeleton\s+(code|implementation)|stub\s+(implementation|for|code)|temporary\s+(fix|hack|solution|workaround)|will\s+(add|implement|fix|improve)\s+later|bare\s+minimum|good\s+enough\s+for\s+now|quick\s+(and\s+dirty|hack|fix)|not\s+fully\s+implemented|partial\s+implementation|deferred|minimal\s+viable|just\s+enough\s+to'
if echo "$COMMENT_LINES" | grep -qiP "$EN_PATTERN" 2>/dev/null; then
  MATCH=$(echo "$COMMENT_LINES" | grep -oiP "$EN_PATTERN" 2>/dev/null | head -3)
  while IFS= read -r m; do
    [[ -z "$m" ]] && continue
    VIOLATIONS="${VIOLATIONS}  - English scope reduction: '$(sentinel_sanitize "$m")'\n"
  done <<< "$MATCH"
fi

# Japanese scope-reduction patterns (5 patterns)
JA_PATTERN='とりあえず|暫定的|仮の?(実装|コード|対応)|後で\s*(実装|追加|修正)|簡易版'
if echo "$COMMENT_LINES" | grep -qP "$JA_PATTERN" 2>/dev/null; then
  MATCH=$(echo "$COMMENT_LINES" | grep -oP "$JA_PATTERN" 2>/dev/null | head -3)
  while IFS= read -r m; do
    [[ -z "$m" ]] && continue
    VIOLATIONS="${VIOLATIONS}  - Japanese scope reduction: '$(sentinel_sanitize "$m")'\n"
  done <<< "$MATCH"
fi

if [[ -n "$VIOLATIONS" ]]; then
  if [[ "$ACTION" == "block" ]]; then
    {
      echo "⛔ [Sentinel Scope-Reduction-Guard] Scope reduction in code comments detected"
      echo "  File: $(basename "$FILE_PATH")"
      echo ""
      echo -e "Violations:\n${VIOLATIONS}"
      echo "Code comments must NOT contain scope-reduction language."
      echo "Either implement completely or do not write the code at all."
      echo "→ Remove scope-reduction comments and implement fully, then retry."
    } >&2
    sentinel_stats_increment "blocks"
    sentinel_stats_increment "pattern_scope_reduction"
    exit 2
  else
    echo "⚠️ [Sentinel Scope-Reduction-Guard] Scope reduction language detected"
    echo "  File: $(basename "$FILE_PATH")"
    echo ""
    echo -e "Warnings:\n${VIOLATIONS}"
    sentinel_stats_increment "warnings"
  fi
fi

sentinel_stats_increment "checks"
exit 0
