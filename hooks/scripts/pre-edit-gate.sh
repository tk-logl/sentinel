#!/bin/bash
# Sentinel PreToolUse Hook: Pre-Edit Gate (BLOCKING)
# Requires .sentinel/current-task.json before source code edits.
# Exit 2 = DENY | Exit 0 = ALLOW

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/_common.sh"
sentinel_require_jq "pre-edit-gate" "blocking"
sentinel_require_pcre "pre-edit-gate" "blocking"
sentinel_compat_check "pre_edit_gate"

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

# Check per-item action for pre-edit checklist requirement
ACTION=$(sentinel_get_action "workflow" "require_pre_edit_checklist")
[[ "$ACTION" == "off" ]] && { sentinel_stats_increment "checks"; exit 0; }

if [[ ! -f "$TASK_FILE" ]]; then
  _msg() {
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
  }
  if [[ "$ACTION" == "block" ]]; then
    _msg >&2
    sentinel_stats_increment "blocks"
    exit 2
  else
    _msg
    sentinel_stats_increment "warnings"
  fi
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
  _msg2() {
    echo "⛔ [Sentinel Pre-Edit Gate] current-task.json missing required fields"
    echo "  Current task: ${TASK_ID:-not set}"
    echo ""
    echo -e "Missing:\n${MISSING}"
    echo "→ Update .sentinel/current-task.json with all fields, then retry."
  }
  if [[ "$ACTION" == "block" ]]; then
    _msg2 >&2
    sentinel_stats_increment "blocks"
    exit 2
  else
    _msg2
    sentinel_stats_increment "warnings"
  fi
fi

sentinel_stats_increment "checks"
echo "✅ [Sentinel Pre-Edit Gate] Checklist passed: ${TASK_ID}"

# ─── Behavior Spec Gate ───
# Require .sentinel/specs/{task-id}.json with given/when/then/assert behaviors
SPEC_ACTION=$(sentinel_get_action "workflow" "require_behavior_spec")
if [[ "$SPEC_ACTION" != "off" ]]; then
  SPEC_DIR="${PROJECT_ROOT}/.sentinel/specs"
  SPEC_FILE="${SPEC_DIR}/${TASK_ID}.json"

  if [[ ! -f "$SPEC_FILE" ]]; then
    _spec_msg() {
      echo "⛔ [Sentinel Spec Gate] Behavior spec not found: .sentinel/specs/${TASK_ID}.json"
      echo ""
      echo "Before implementing, you MUST create a behavior spec defining expected input/output."
      echo ""
      echo "Required file: .sentinel/specs/${TASK_ID}.json"
      echo '{'
      echo '  "task_id": "'"${TASK_ID}"'",'
      echo '  "module": "apps/service/module.py",'
      echo '  "functions": ["function_name"],'
      echo '  "behavior": ['
      echo '    {'
      echo '      "id": "B1",'
      echo '      "given": "specific input description",'
      echo '      "when": "function is called with that input",'
      echo '      "then": "specific expected output/behavior",'
      echo '      "assert": "result.field == expected_value"'
      echo '    },'
      echo '    {'
      echo '      "id": "B2",'
      echo '      "given": "invalid/edge-case input",'
      echo '      "when": "function is called",'
      echo '      "then": "raises specific error",'
      echo '      "assert": "pytest.raises(ValueError)"'
      echo '    }'
      echo '  ],'
      echo '  "edge_cases": ["empty input", "null", "boundary values"]'
      echo '}'
      echo ""
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      echo "HOW TO CREATE A GOOD SPEC:"
      echo "  1. Read the function signature (params + return type)"
      echo "  2. Write at least 3 behaviors: happy path, error case, edge case"
      echo "  3. Each 'assert' must be a concrete Python expression (not 'works correctly')"
      echo "  4. Include edge_cases: empty input, None, 0, MAX_INT, special chars"
      echo "  5. Write .sentinel/specs/${TASK_ID}.json, then retry this edit"
    }
    if [[ "$SPEC_ACTION" == "block" ]]; then
      _spec_msg >&2
      sentinel_stats_increment "blocks"
      sentinel_stats_increment "pattern_missing_spec"
      exit 2
    else
      _spec_msg
      sentinel_stats_increment "warnings"
    fi
  else
    # Validate spec has behavior array with required fields
    BEHAVIOR_COUNT=$(jq '.behavior | length' "$SPEC_FILE" 2>/dev/null || echo "0")
    if [[ "$BEHAVIOR_COUNT" -lt 1 ]]; then
      _spec_empty() {
        echo "⛔ [Sentinel Spec Gate] Spec has no behaviors: .sentinel/specs/${TASK_ID}.json"
        echo ""
        echo "  The 'behavior' array is empty or missing."
        echo "  → Add at least 3 behavior entries with given/when/then/assert fields."
        echo "  → Each entry defines ONE expected input/output scenario."
      }
      if [[ "$SPEC_ACTION" == "block" ]]; then
        _spec_empty >&2
        sentinel_stats_increment "blocks"
        exit 2
      else
        _spec_empty
        sentinel_stats_increment "warnings"
      fi
    else
      # Validate each behavior has required fields
      INVALID=$(jq '[.behavior[] | select(.given == null or .then == null or .assert == null)] | length' "$SPEC_FILE" 2>/dev/null || echo "0")
      if [[ "$INVALID" -gt 0 ]]; then
        _spec_invalid() {
          echo "⛔ [Sentinel Spec Gate] Spec has ${INVALID} behaviors missing required fields"
          echo ""
          echo "  Every behavior MUST have: given, then, assert"
          echo "  → 'given': specific input/precondition"
          echo "  → 'then': expected output/behavior"
          echo "  → 'assert': concrete Python assertion expression"
        }
        if [[ "$SPEC_ACTION" == "block" ]]; then
          _spec_invalid >&2
          sentinel_stats_increment "blocks"
          exit 2
        else
          _spec_invalid
          sentinel_stats_increment "warnings"
        fi
      else
        # Spec is valid — inject into AI context
        echo ""
        echo "=== Behavior Spec (${TASK_ID}) — ${BEHAVIOR_COUNT} behaviors ==="
        jq -r '.behavior[] | "  [\(.id // "?")] GIVEN: \(.given) → THEN: \(.then) | ASSERT: \(.assert)"' "$SPEC_FILE" 2>/dev/null
        EDGE_CASES=$(jq -r '.edge_cases // [] | join(", ")' "$SPEC_FILE" 2>/dev/null)
        if [[ -n "$EDGE_CASES" ]]; then
          echo "  Edge cases: ${EDGE_CASES}"
        fi
        INVARIANTS=$(jq -r '.invariants // [] | join(", ")' "$SPEC_FILE" 2>/dev/null)
        if [[ -n "$INVARIANTS" ]]; then
          echo "  Invariants: ${INVARIANTS}"
        fi
        echo "=== Implementation MUST pass ALL assertions above ==="
      fi
    fi
  fi
fi

# Inject task spec from task-list if configured
INJECT_SPEC=$(sentinel_read_config '.preImplGate.injectSpecOnAllow' 'true')
if [[ "$INJECT_SPEC" == "true" ]]; then
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
