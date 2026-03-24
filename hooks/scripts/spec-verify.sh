#!/bin/bash
# Sentinel Stop Hook: Spec Verify
# Verifies that behavior specs have corresponding tests with matching assertions.
# Exit 0 = allow (warnings only) | Exit 2 = block (if configured)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/_common.sh"
sentinel_require_jq "spec-verify" "non-blocking"

# Check action
ACTION=$(sentinel_get_action "workflow" "require_behavior_spec")
[[ "$ACTION" == "off" ]] && exit 0

PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
[[ -z "$PROJECT_ROOT" ]] && exit 0

SPEC_DIR="${PROJECT_ROOT}/.sentinel/specs"
[[ ! -d "$SPEC_DIR" ]] && exit 0

TASK_FILE="${PROJECT_ROOT}/.sentinel/current-task.json"
[[ ! -f "$TASK_FILE" ]] && exit 0

TASK_ID=$(jq -r '.task_id // empty' "$TASK_FILE" 2>/dev/null)
[[ -z "$TASK_ID" ]] && exit 0

SPEC_FILE="${SPEC_DIR}/${TASK_ID}.json"
[[ ! -f "$SPEC_FILE" ]] && exit 0

# Read spec
BEHAVIOR_COUNT=$(jq '.behavior | length' "$SPEC_FILE" 2>/dev/null || echo "0")
[[ "$BEHAVIOR_COUNT" -lt 1 ]] && exit 0

# Find test files — look in common locations
MODULE=$(jq -r '.module // empty' "$SPEC_FILE" 2>/dev/null)
# shellcheck disable=SC2034  # reserved for future per-function matching
_FUNC_NAMES=$(jq -r '.functions // [] | .[]' "$SPEC_FILE" 2>/dev/null)

# Build list of candidate test files
TEST_FILES=""
if [[ -n "$MODULE" ]]; then
  # apps/brain/services.py -> apps/brain/tests/test_services.py
  MODULE_DIR=$(dirname "$MODULE")
  MODULE_BASE=$(basename "$MODULE" .py)
  CANDIDATE="${PROJECT_ROOT}/${MODULE_DIR}/tests/test_${MODULE_BASE}.py"
  [[ -f "$CANDIDATE" ]] && TEST_FILES="$CANDIDATE"
  
  # Also check tests/ at project root
  CANDIDATE2="${PROJECT_ROOT}/tests/test_${MODULE_BASE}.py"
  [[ -f "$CANDIDATE2" ]] && TEST_FILES="${TEST_FILES} ${CANDIDATE2}"
fi

# Also search for recently modified test files
RECENT_TESTS=$(find "$PROJECT_ROOT" -name "test_*.py" -newer "$SPEC_FILE" -type f 2>/dev/null | head -5)
if [[ -n "$RECENT_TESTS" ]]; then
  TEST_FILES="${TEST_FILES} ${RECENT_TESTS}"
fi

# Deduplicate
TEST_FILES=$(echo "$TEST_FILES" | tr ' ' '\n' | sort -u | tr '\n' ' ')

if [[ -z "$TEST_FILES" ]]; then
  {
    echo "⚠️ [Sentinel Spec Verify] No test files found for spec ${TASK_ID}"
    echo "  Module: ${MODULE:-not specified}"
    echo "  → Create test file at: ${MODULE_DIR:-tests}/tests/test_${MODULE_BASE:-module}.py"
    echo "  → Or run: python3 \${CLAUDE_PLUGIN_ROOT}/hooks/scripts/spec-to-test.py ${SPEC_FILE} --output <path>"
  } >&2
  sentinel_stats_increment "warnings"
  exit 0
fi

# Check each behavior assertion against test files
TOTAL=0
COVERED=0
MISSING=""
ALL_TEST_CONTENT=""

for tf in $TEST_FILES; do
  [[ -f "$tf" ]] && ALL_TEST_CONTENT="${ALL_TEST_CONTENT}$(cat "$tf" 2>/dev/null)"
done

while IFS= read -r behavior_json; do
  TOTAL=$((TOTAL + 1))
  BID=$(echo "$behavior_json" | jq -r '.id // "?"')
  ASSERT_EXPR=$(echo "$behavior_json" | jq -r '.assert // empty')
  THEN_DESC=$(echo "$behavior_json" | jq -r '.then // empty')
  
  if [[ -z "$ASSERT_EXPR" ]]; then
    MISSING="${MISSING}  [$BID] No assert expression in spec\n"
    continue
  fi

  # Check 1: assert expression appears in test code (exact or partial match)
  # Escape special regex chars for grep
  FOUND=false
  for tf in $TEST_FILES; do
    if [[ -f "$tf" ]] && grep -qF "$ASSERT_EXPR" "$tf" 2>/dev/null; then
      FOUND=true
      break
    fi
  done

  # Check 2: if exact match fails, look for key parts of the assertion
  if ! $FOUND; then
    # Extract function/method names from assert for fuzzy matching
    KEY_PARTS=$(echo "$ASSERT_EXPR" | grep -oP '\w+' | head -3)
    PARTIAL_MATCH=0
    for part in $KEY_PARTS; do
      if echo "$ALL_TEST_CONTENT" | grep -qF "$part" 2>/dev/null; then
        PARTIAL_MATCH=$((PARTIAL_MATCH + 1))
      fi
    done
    # If at least 2 key parts found, consider it a partial match
    if [[ $PARTIAL_MATCH -ge 2 ]]; then
      FOUND=true
    fi
  fi

  if $FOUND; then
    COVERED=$((COVERED + 1))
  else
    MISSING="${MISSING}  [$BID] ${THEN_DESC}\n    assert: ${ASSERT_EXPR}\n"
  fi
done < <(jq -c '.behavior[]' "$SPEC_FILE" 2>/dev/null)

# Check edge cases
EDGE_COUNT=$(jq '.edge_cases // [] | length' "$SPEC_FILE" 2>/dev/null || echo "0")
EDGE_TESTED=0
if [[ "$EDGE_COUNT" -gt 0 ]]; then
  if echo "$ALL_TEST_CONTENT" | grep -qP 'parametrize|edge_case|edge_input|boundary' 2>/dev/null; then
    EDGE_TESTED=1
  fi
fi

# Report
if [[ $COVERED -eq $TOTAL ]] && [[ "$EDGE_TESTED" -gt 0 || "$EDGE_COUNT" -eq 0 ]]; then
  echo "✅ [Sentinel Spec Verify] All ${TOTAL} behaviors covered for ${TASK_ID}" >&2
  sentinel_stats_increment "checks"
  exit 0
fi

{
  echo "⚠️ [Sentinel Spec Verify] Spec coverage: ${COVERED}/${TOTAL} behaviors for ${TASK_ID}"
  if [[ -n "$MISSING" ]]; then
    echo ""
    echo "Missing test coverage:"
    echo -e "$MISSING"
  fi
  if [[ "$EDGE_COUNT" -gt 0 ]] && [[ "$EDGE_TESTED" -eq 0 ]]; then
    echo "  Edge cases (${EDGE_COUNT}): no parametrized test found"
    echo "  → Run: python3 \${CLAUDE_PLUGIN_ROOT}/hooks/scripts/spec-to-test.py ${SPEC_FILE} --stdout"
  fi
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "HOW TO FIX:"
  echo "  1. For each missing behavior, write a test with the exact assert expression"
  echo "  2. Use spec-to-test.py to generate skeleton: python3 spec-to-test.py ${SPEC_FILE}"
  echo "  3. Ensure edge cases have parametrized tests"
  echo "  4. Do NOT weaken spec assertions — implement code to pass them"
} >&2

sentinel_stats_increment "warnings"

# In block mode, exit 2 if coverage is below 100%
if [[ "$ACTION" == "block" ]] && [[ $COVERED -lt $TOTAL ]]; then
  sentinel_stats_increment "blocks"
  exit 2
fi

exit 0
