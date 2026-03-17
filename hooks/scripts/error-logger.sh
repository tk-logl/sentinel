#!/bin/bash
# Sentinel PostToolUse Hook: Error Logger (LOGGING)
# Classifies and logs Bash errors. Detects repeated failures.
# Exit 0 = ALLOW (always, just logs)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/_common.sh"
sentinel_require_jq "error-logger"
sentinel_require_pcre "error-logger"

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

[[ "$TOOL_NAME" != "Bash" ]] && exit 0

# Check exit code
EXIT_CODE=$(echo "$INPUT" | jq -r '.tool_response.exit_code // .tool_response.exitCode // 0' 2>/dev/null)
[[ "$EXIT_CODE" == "0" || -z "$EXIT_CODE" ]] && exit 0

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
STDERR=$(echo "$INPUT" | jq -r '.tool_response.stderr // empty' 2>/dev/null)
STDOUT=$(echo "$INPUT" | jq -r '.tool_response.stdout // empty' 2>/dev/null)
OUTPUT="${STDERR}${STDOUT}"

# Classify error
ERROR_TYPE="unknown"
if echo "$OUTPUT" | grep -qiP 'syntax.?error|unexpected.?token|parse.?error'; then
  ERROR_TYPE="syntax"
elif echo "$OUTPUT" | grep -qiP 'import.?error|module.?not.?found|cannot.?find.?module|no.?module.?named'; then
  ERROR_TYPE="import"
elif echo "$OUTPUT" | grep -qiP 'permission.?denied|EACCES|operation.?not.?permitted'; then
  ERROR_TYPE="permission"
elif echo "$OUTPUT" | grep -qiP 'connection.?refused|ECONNREFUSED|network|timeout|ETIMEDOUT'; then
  ERROR_TYPE="network"
elif echo "$OUTPUT" | grep -qiP 'type.?error|TypeError|is.?not.?a.?function|undefined.?is.?not'; then
  ERROR_TYPE="type"
elif echo "$OUTPUT" | grep -qiP 'FAILED|AssertionError|test.*fail|FAIL'; then
  ERROR_TYPE="test"
elif echo "$OUTPUT" | grep -qiP 'out.?of.?memory|heap|MemoryError|ENOMEM'; then
  ERROR_TYPE="memory"
fi

# Find project root and log
PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
[[ -z "$PROJECT_ROOT" ]] && exit 0

LOG_DIR="${PROJECT_ROOT}/.sentinel"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/error-log.jsonl"

# Create log entry
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
ERROR_HASH=$(echo "${COMMAND}${ERROR_TYPE}" | md5sum | cut -c1-8)
COMMAND_SHORT=$(echo "$COMMAND" | head -1 | cut -c1-100)
OUTPUT_SHORT=$(echo "$OUTPUT" | head -3 | tr '\n' ' ' | cut -c1-200)

# Write to log
echo "{\"ts\":\"${TIMESTAMP}\",\"type\":\"${ERROR_TYPE}\",\"exit\":${EXIT_CODE},\"hash\":\"${ERROR_HASH}\",\"cmd\":\"${COMMAND_SHORT}\",\"output\":\"${OUTPUT_SHORT}\"}" >> "$LOG_FILE"

# === MANDATORY ERROR RESPONSE — injected on EVERY error ===
echo "🚨 [Sentinel Error-Logger] Command failed (${ERROR_TYPE}, exit ${EXIT_CODE})"
echo "  Command: ${COMMAND_SHORT}"
echo "  Output: ${OUTPUT_SHORT}"
echo ""
echo "  ⛔ DO NOT SKIP THIS ERROR. DO NOT MOVE ON."
echo "  You MUST either:"
echo "    1. Fix the error and retry the same command"
echo "    2. Try a different approach that solves the same problem"
echo "    3. If truly unrelated to your task, explain WHY before continuing"
echo "  Skipping errors is AI Mistake #12 (Abandoning Failed Path)."
echo ""

# Check for repeated failures (same error hash 3+ times)
if [[ -f "$LOG_FILE" ]]; then
  REPEAT_COUNT=$(grep -c "\"hash\":\"${ERROR_HASH}\"" "$LOG_FILE" 2>/dev/null || true)
  [[ -z "$REPEAT_COUNT" || "$REPEAT_COUNT" == *$'\n'* ]] && REPEAT_COUNT=0
  if [[ $REPEAT_COUNT -ge 3 ]]; then
    echo "🔴 [Sentinel] SAME ERROR ${REPEAT_COUNT}x — STOP REPEATING"
    echo "  AI Mistake #12: You are repeating the exact same failed approach."
    echo "  The definition of insanity: doing the same thing expecting different results."
    echo "  MANDATORY: Try a completely different approach NOW."
    echo "    - Read the error message word by word"
    echo "    - Search for the error in docs/source code"
    echo "    - Ask the user for help"
    echo "    - Do NOT retry the same command"
    echo ""
  fi
fi

# Keep log file from growing too large (max 500 entries)
if [[ -f "$LOG_FILE" ]]; then
  LINE_COUNT=$(wc -l < "$LOG_FILE")
  if [[ $LINE_COUNT -gt 500 ]]; then
    tail -250 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
  fi
fi

exit 0
