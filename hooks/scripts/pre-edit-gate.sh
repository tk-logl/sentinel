#!/bin/bash
# Sentinel PreToolUse Hook: Pre-Edit Gate (BLOCKING)
# Requires .sentinel/current-task.json before source code edits.
# Exit 2 = DENY | Exit 0 = ALLOW

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/_common.sh"
sentinel_require_jq "pre-edit-gate"
sentinel_require_pcre "pre-edit-gate"

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

if [[ "$TOOL_NAME" != "Edit" && "$TOOL_NAME" != "Write" ]]; then
  exit 0
fi

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[[ -z "$FILE_PATH" ]] && exit 0

# Only gate source code files
EXT="${FILE_PATH##*.}"
case "$EXT" in
  py|ts|tsx|js|jsx|go|rs|java|c|cpp|svelte|vue) ;;
  *) exit 0 ;;
esac

# Skip non-project files
case "$FILE_PATH" in
  */.sentinel/*|*/.claude/*|*/.omc/*|*/.github/*|*/node_modules/*|*/__pycache__/*) exit 0 ;;
esac

# Skip test files
if echo "$FILE_PATH" | grep -qP '(\.test\.|\.spec\.|/tests/|/test_|_test\.)'; then
  exit 0
fi

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
  exit 2
fi

# Validate required fields
TASK_ID=$(jq -r '.task_id // empty' "$TASK_FILE" 2>/dev/null)
WHY=$(jq -r '.why // empty' "$TASK_FILE" 2>/dev/null)
APPROACH=$(jq -r '.approach // empty' "$TASK_FILE" 2>/dev/null)
IMPACT=$(jq -r '.impact_files // empty' "$TASK_FILE" 2>/dev/null)
BLAST=$(jq -r '.blast_radius // empty' "$TASK_FILE" 2>/dev/null)
VERIFY=$(jq -r '.verify_command // empty' "$TASK_FILE" 2>/dev/null)

MISSING=""
[[ -z "$TASK_ID" ]] && MISSING="${MISSING}  - task_id (unique task identifier)\n"
[[ -z "$WHY" ]] && MISSING="${MISSING}  - why (business/quality reason)\n"
[[ -z "$APPROACH" ]] && MISSING="${MISSING}  - approach (chosen method + reasoning)\n"
[[ "$IMPACT" == "null" || -z "$IMPACT" ]] && MISSING="${MISSING}  - impact_files (affected callers/importers list)\n"
[[ "$BLAST" == "null" || -z "$BLAST" ]] && MISSING="${MISSING}  - blast_radius (tests that break + tests to add)\n"
[[ -z "$VERIFY" ]] && MISSING="${MISSING}  - verify_command (how to verify this change works)\n"

if [[ -n "$MISSING" ]]; then
  echo "⛔ [Sentinel Pre-Edit Gate] current-task.json missing required fields"
  echo "  Current task: ${TASK_ID:-not set}"
  echo ""
  echo -e "Missing:\n${MISSING}"
  echo "→ Update .sentinel/current-task.json with all fields, then retry."
  exit 2
fi

echo "✅ [Sentinel Pre-Edit Gate] Checklist passed: ${TASK_ID}"
exit 0
