#!/bin/bash
# Sentinel PostToolUse Hook: Auto-generate tests from spec
# When a .sentinel/specs/*.json file is written, auto-run spec-to-test.py
# Exit 0 = allow (informational only)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/_common.sh"
sentinel_require_jq "spec-auto-test" "non-blocking"

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

if [[ "$TOOL_NAME" != "Edit" && "$TOOL_NAME" != "Write" ]]; then
  exit 0
fi

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[[ -z "$FILE_PATH" ]] && exit 0

# Only trigger for .sentinel/specs/*.json files
if [[ ! "$FILE_PATH" =~ \.sentinel/specs/[^/]+\.json$ ]]; then
  exit 0
fi

# Verify file exists and is valid JSON with behaviors
if [[ ! -f "$FILE_PATH" ]]; then
  exit 0
fi

BEHAVIOR_COUNT=$(jq '.behavior | length' "$FILE_PATH" 2>/dev/null || echo "0")
if [[ "$BEHAVIOR_COUNT" -lt 1 ]]; then
  exit 0
fi

# Find spec-to-test.py
SPEC_TO_TEST="${SCRIPT_DIR}/spec-to-test.py"
if [[ ! -f "$SPEC_TO_TEST" ]]; then
  exit 0
fi

# Determine output path from spec metadata
PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
[[ -z "$PROJECT_ROOT" ]] && exit 0

MODULE=$(jq -r '.module // empty' "$FILE_PATH" 2>/dev/null)
if [[ -n "$MODULE" ]]; then
  MODULE_DIR=$(dirname "$MODULE")
  MODULE_BASE=$(basename "$MODULE" .py)
  TEST_DIR="${PROJECT_ROOT}/${MODULE_DIR}/tests"
  TEST_FILE="${TEST_DIR}/test_${MODULE_BASE}.py"

  # Only generate if test file doesn't exist yet
  if [[ ! -f "$TEST_FILE" ]]; then
    mkdir -p "$TEST_DIR"
    python3 "$SPEC_TO_TEST" "$FILE_PATH" --output "$TEST_FILE" 2>/dev/null

    if [[ $? -eq 0 && -f "$TEST_FILE" ]]; then
      {
        echo "🧪 [Sentinel Spec→Test] Auto-generated test skeleton:"
        echo "  Spec: $(basename "$FILE_PATH")"
        echo "  Test: ${TEST_FILE#"${PROJECT_ROOT}"/}"
        echo "  Behaviors: ${BEHAVIOR_COUNT}"
        echo ""
        echo "  The test file contains EXACT assertions from your spec."
        echo "  Implement the function to make these assertions pass."
      }
      sentinel_stats_increment "spec_tests_generated"
    fi
  else
    {
      echo "ℹ️ [Sentinel Spec→Test] Test file already exists:"
      echo "  ${TEST_FILE#"${PROJECT_ROOT}"/}"
      echo "  Run manually: python3 ${SPEC_TO_TEST} ${FILE_PATH} --stdout"
    }
  fi
else
  {
    echo "ℹ️ [Sentinel Spec→Test] Spec written but no 'module' field — cannot auto-generate test."
    echo "  Add \"module\": \"path/to/module.py\" to your spec, or run manually:"
    echo "  python3 ${SPEC_TO_TEST} ${FILE_PATH} --stdout"
  }
fi

exit 0
