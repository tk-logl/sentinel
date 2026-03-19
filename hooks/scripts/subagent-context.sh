#!/bin/bash
# Sentinel PreToolUse Hook: Subagent Context Injection (CONTEXT)
# Injects sentinel rules into subagent (Task tool) prompts.
# Ensures subagents follow the same quality standards as the main agent.
# Exit 0 = ALLOW (context only)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/_common.sh"
sentinel_require_jq "subagent-context"
sentinel_compat_check "subagent_context"

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

# Only fire on Task tool (subagent spawn)
[[ "$TOOL_NAME" != "Task" ]] && exit 0

# Check per-item action
ACTION=$(sentinel_get_action "context" "subagent_rule_injection" "on")
[[ "$ACTION" == "off" ]] && exit 0

PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
[[ -z "$PROJECT_ROOT" ]] && exit 0

SUBAGENT_TYPE=$(echo "$INPUT" | jq -r '.tool_input.subagent_type // empty' 2>/dev/null)

echo "📋 [Sentinel Subagent-Context] Injecting rules for: ${SUBAGENT_TYPE:-unknown}"
echo ""

# 1. Core enforcement rules
echo "=== Sentinel Quality Rules (apply to all subagents) ==="
echo "  - No pass/TODO/FIXME/PLACEHOLDER in code"
echo "  - No raise NotImplementedError without @abstractmethod"
echo "  - No scope reduction (simplified, for now, basic version)"
echo "  - No silent error swallowing (except: pass without logging)"
echo "  - Implement completely or not at all"
echo ""

# 2. Current task context (if available)
TASK_FILE="${PROJECT_ROOT}/.sentinel/current-task.json"
if [[ -f "$TASK_FILE" ]]; then
  TASK_ID=$(jq -r '.task_id // .item_id // "unknown"' "$TASK_FILE" 2>/dev/null)
  TASK_WHY=$(jq -r '.why // ""' "$TASK_FILE" 2>/dev/null)
  TASK_APPROACH=$(jq -r '.approach // ""' "$TASK_FILE" 2>/dev/null)
  echo "Active Task: ${TASK_ID}"
  [[ -n "$TASK_WHY" ]] && echo "  Why: ${TASK_WHY}"
  [[ -n "$TASK_APPROACH" ]] && echo "  Approach: ${TASK_APPROACH}"
  echo ""
fi

# 3. Task list context (in-progress items)
TASK_LIST_ENABLED=$(sentinel_read_config '.taskList.enabled' 'true')
if [[ "$TASK_LIST_ENABLED" == "true" ]]; then
  TASK_LIST_FILE=$(sentinel_find_task_list)
  if [[ -n "$TASK_LIST_FILE" ]]; then
    INPROG_COUNT=$(sentinel_task_count "inProgress")
    if [[ "$INPROG_COUNT" -gt 0 ]]; then
      echo "In-progress items (must complete):"
      sentinel_task_list_items "inProgress" 5 | sed 's/^/  /'
      echo ""
    fi
  fi
fi

echo "=== End Sentinel Context ==="

exit 0
