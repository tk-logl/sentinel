#!/bin/bash
# Sentinel UserPromptSubmit Hook: Scope Guard (WARNING)
# Detects scope-reduction language in prompts and injects warnings.
# Exit 0 = ALLOW (with context injection)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/_common.sh"
sentinel_require_jq "scope-guard"
sentinel_require_pcre "scope-guard"
sentinel_compat_check "scope_guard"

INPUT=$(cat)

# Post-compact restore: detect flag left by PreCompact and run restore
PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
COMPACT_FLAG="${PROJECT_ROOT}/.sentinel/state/.compact-pending"
if [[ -f "$COMPACT_FLAG" ]]; then
  rm -f "$COMPACT_FLAG"
  RESTORE_SCRIPT="${SCRIPT_DIR}/post-compact-restore.sh"
  if [[ -f "$RESTORE_SCRIPT" ]]; then
    RESTORE_OUTPUT=$(echo "$INPUT" | bash "$RESTORE_SCRIPT" 2>&1)
    if [[ -n "$RESTORE_OUTPUT" ]]; then
      echo "$RESTORE_OUTPUT"
      echo ""
    fi
  fi
fi

# Check per-item action
ACTION=$(sentinel_get_action "workflow" "warn_scope_reduction_prompt" "warn")
[[ "$ACTION" == "off" ]] && exit 0

USER_PROMPT=$(echo "$INPUT" | jq -r '.tool_input.user_prompt // .tool_input.content // empty' 2>/dev/null)

[[ -z "$USER_PROMPT" ]] && exit 0

WARNINGS=""

# Korean scope-reduction patterns (precise — common conversational fillers removed)
if echo "$USER_PROMPT" | grep -qP '대충|임시로|간소화해|단순화해|기본만|추후에.*구현|나중에.*추가|향후.*개선'; then
  WARNINGS="${WARNINGS}  🇰🇷 범위 축소 표현 감지\n"
fi

# English scope-reduction patterns (precise — common phrases removed)
if echo "$USER_PROMPT" | grep -qiP 'placeholder|will add later|good enough for now|skip.*(test|validation|error)|just.*(stub|mock|placeholder)|rough draft|mvp only|bare minimum|implement later|add later|todo for later|hack for now'; then
  WARNINGS="${WARNINGS}  🇬🇧 Scope reduction language detected\n"
fi

# Japanese scope-reduction patterns (precise — common fillers removed)
if echo "$USER_PROMPT" | grep -qP 'とりあえず|後で.*追加|仮に.*実装'; then
  WARNINGS="${WARNINGS}  🇯🇵 Scope reduction language detected\n"
fi

if [[ -n "$WARNINGS" ]]; then
  echo "⚠️ [Sentinel Scope-Guard] Scope reduction detected in prompt"
  echo ""
  echo -e "$WARNINGS"
  echo ""
  echo "Reminder: Implement completely or don't implement at all."
  echo "  - No 'for now' shortcuts — they become permanent technical debt"
  echo "  - No 'basic version first' — build the real version"
  echo "  - No 'placeholder' — write the actual implementation"
  echo "  - If scope is genuinely too large, discuss with the user first"
  sentinel_stats_increment "warnings"
  sentinel_stats_increment "pattern_scope_reduction"
fi

exit 0
