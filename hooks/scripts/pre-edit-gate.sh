#!/bin/bash
# Sentinel PreToolUse Hook: Pre-Edit Gate (BLOCKING)
# Requires .sentinel/current-task.json before source code edits.
# Exit 2 = DENY | Exit 0 = ALLOW

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/_common.sh"
sentinel_require_jq "pre-edit-gate" "blocking"
sentinel_require_pcre "pre-edit-gate" "blocking"
sentinel_check_enabled "pre_edit_gate"

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

if [[ "$TOOL_NAME" != "Edit" && "$TOOL_NAME" != "Write" ]]; then
  exit 0
fi

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[[ -z "$FILE_PATH" ]] && exit 0

# Only gate source code files (config-driven extensions)
if ! sentinel_is_source_file "$FILE_PATH"; then exit 0; fi

# Skip test files, config dirs, and user-configured skip patterns
if sentinel_should_skip "$FILE_PATH"; then exit 0; fi

# Find project root
PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
[[ -z "$PROJECT_ROOT" ]] && exit 0

TASK_FILE="${PROJECT_ROOT}/.sentinel/current-task.json"

if [[ ! -f "$TASK_FILE" ]]; then
  echo "⛔ [Sentinel Pre-Edit Gate] .sentinel/current-task.json not found"
  echo ""
  echo "Before editing source code, you MUST create a pre-implementation checklist."
  echo ""
  echo "Required file: .sentinel/current-task.json"
  echo '{'
  echo '  "task_id": "TASK-1",'
  echo '  "why": "Business/quality reason for this change",'
  echo '  "approach": "Chosen approach + reasoning (Option A because...)",'
  echo '  "impact_files": ["file1.py:fn_name — only caller", "file2.ts:Component — imports this"],'
  echo '  "blast_radius": {"tests_break": [], "tests_add": ["test_new_feature"]},'
  echo '  "verify_command": "pytest tests/ -x"'
  echo '}'
  echo ""
  echo "This is your blueprint. Fill it with real analysis, not placeholders."
  echo "→ Write .sentinel/current-task.json first, then edit source code."
  sentinel_stats_increment "blocks"
  exit 2
fi

# Validate required fields — single jq call for performance (avoids 7 forks)
FIELDS_JSON=$(jq -r '[
  (.task_id // ""),
  (.why // ""),
  (.approach // ""),
  (.impact_files | if . == null then "" else (. | tostring) end),
  (.blast_radius | if . == null then "" else (. | tostring) end),
  (.verify_command // "")
] | join("\t")' "$TASK_FILE" 2>/dev/null)

IFS=$'\t' read -r TASK_ID WHY APPROACH IMPACT BLAST VERIFY <<< "$FIELDS_JSON"

MISSING=""
[[ -z "$TASK_ID" ]] && MISSING="${MISSING}  - task_id (unique task identifier)\n"
[[ -z "$WHY" ]] && MISSING="${MISSING}  - why (business/quality reason)\n"
[[ -z "$APPROACH" ]] && MISSING="${MISSING}  - approach (chosen method + reasoning)\n"
[[ -z "$IMPACT" ]] && MISSING="${MISSING}  - impact_files (affected callers/importers list)\n"
[[ -z "$BLAST" ]] && MISSING="${MISSING}  - blast_radius (tests that break + tests to add)\n"
[[ -z "$VERIFY" ]] && MISSING="${MISSING}  - verify_command (how to verify this change works)\n"

if [[ -n "$MISSING" ]]; then
  echo "⛔ [Sentinel Pre-Edit Gate] current-task.json missing required fields"
  echo "  Current task: ${TASK_ID:-not set}"
  echo ""
  echo -e "Missing:\n${MISSING}"
  echo "→ Update .sentinel/current-task.json with all fields, then retry."
  sentinel_stats_increment "blocks"
  exit 2
fi

sentinel_stats_increment "checks"
echo "✅ [Sentinel Pre-Edit Gate] Checklist passed: ${TASK_ID}"

# Inject task spec from task-list if configured
INJECT_SPEC=$(sentinel_read_config '.preImplGate.injectSpecOnAllow' 'true')
if [[ "$INJECT_SPEC" == "true" ]]; then
  # Use item_id or task_id from current-task.json
  ITEM_ID=$(jq -r '.item_id // .task_id // empty' "$TASK_FILE" 2>/dev/null)
  if [[ -n "$ITEM_ID" ]]; then
    SPEC=$(sentinel_task_get_spec "$ITEM_ID" 2>/dev/null)
    if [[ -n "$SPEC" ]]; then
      echo ""
      echo "=== Active Item Spec (${ITEM_ID}) ==="
      echo "$SPEC"
      echo "=== Implement exactly as specified ==="
    fi
  fi
fi

exit 0
