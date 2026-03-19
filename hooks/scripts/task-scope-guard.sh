#!/bin/bash
# Sentinel UserPromptSubmit Hook: Task Scope Guard (WARNING)
# Detects numbered/bulleted task lists in user prompts and enforces complete implementation.
# Exit 0 = ALLOW (injects enforcement message via stdout)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/_common.sh"
sentinel_require_jq "task-scope-guard"
sentinel_check_enabled "task_scope_guard"

INPUT=$(cat)
USER_PROMPT=$(echo "$INPUT" | jq -r '.tool_input.user_prompt // empty' 2>/dev/null)
[[ -z "$USER_PROMPT" ]] && exit 0

# Detect numbered/bulleted lists (multiple items = scope to enforce)
# Patterns: 1. 2. 3. / ①②③ / 가. 나. 다. / a) b) c) / - item / * item
ITEM_COUNT=0

# Numbered lists: "1." "2." etc.
NUM_ITEMS=$(echo "$USER_PROMPT" | grep -cP '^\s*\d+[\.\)]\s' 2>/dev/null || true)
[[ -n "$NUM_ITEMS" ]] && ITEM_COUNT=$((ITEM_COUNT + NUM_ITEMS))

# Circle numbers: ① ② ③ etc.
CIRCLE_ITEMS=$(echo "$USER_PROMPT" | grep -coP '[①②③④⑤⑥⑦⑧⑨⑩]' 2>/dev/null || true)
[[ -n "$CIRCLE_ITEMS" ]] && ITEM_COUNT=$((ITEM_COUNT + CIRCLE_ITEMS))

# Korean enumeration: 가. 나. 다. / 첫째 둘째 셋째
KO_ITEMS=$(echo "$USER_PROMPT" | grep -cP '^\s*[가-힣]\.\s|첫째|둘째|셋째|넷째|다섯째' 2>/dev/null || true)
[[ -n "$KO_ITEMS" ]] && ITEM_COUNT=$((ITEM_COUNT + KO_ITEMS))

# Lettered lists: a) b) c) or A. B. C.
LETTER_ITEMS=$(echo "$USER_PROMPT" | grep -cP '^\s*[a-zA-Z][\.\)]\s' 2>/dev/null || true)
[[ -n "$LETTER_ITEMS" ]] && ITEM_COUNT=$((ITEM_COUNT + LETTER_ITEMS))

# Dash/bullet lists: - item or * item (only if 3+)
DASH_ITEMS=$(echo "$USER_PROMPT" | grep -cP '^\s*[-\*]\s' 2>/dev/null || true)
[[ -n "$DASH_ITEMS" && "$DASH_ITEMS" -ge 3 ]] && ITEM_COUNT=$((ITEM_COUNT + DASH_ITEMS))

# Only enforce if 2+ items detected
if [[ $ITEM_COUNT -ge 2 ]]; then
  echo ""
  echo "📋 [Sentinel Task-Scope-Guard] ${ITEM_COUNT} items detected in request"
  echo ""
  echo "  ENFORCEMENT: All ${ITEM_COUNT} items MUST be implemented completely."
  echo "  - No 'for now' or partial implementation"
  echo "  - No skipping items or deferring to later"
  echo "  - No scope reduction ('simplified version', 'basic only')"
  echo "  - If blocked on an item, report it — do not silently skip"
  echo ""

  # Detect scope amplification keywords (user explicitly wants everything)
  if echo "$USER_PROMPT" | grep -qiP '전부|모두|100%|완전히|빠짐없이|all of|every|each one|complete|everything'; then
    echo "  ⚡ SCOPE AMPLIFICATION: User explicitly requested COMPLETE implementation."
    echo "  Zero tolerance for scope reduction. Every single item, fully implemented."
    echo ""
  fi

  sentinel_stats_increment "checks"
fi

exit 0
