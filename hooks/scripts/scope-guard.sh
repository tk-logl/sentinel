#!/bin/bash
# Sentinel UserPromptSubmit Hook: Scope Guard (WARNING)
# Detects scope-reduction language in prompts and injects warnings.
# Exit 0 = ALLOW (with context injection)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/_common.sh"
sentinel_require_jq "scope-guard"
sentinel_require_pcre "scope-guard"
sentinel_check_enabled "scope_guard"

INPUT=$(cat)
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
fi

exit 0
