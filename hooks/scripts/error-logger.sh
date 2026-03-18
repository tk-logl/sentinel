#!/bin/bash
# Sentinel PostToolUse Hook: Error Logger (LOGGING)
# Classifies and logs Bash errors. Detects repeated failures.
# Exit 0 = ALLOW (always, just logs)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/_common.sh"
sentinel_require_jq "error-logger"
sentinel_require_pcre "error-logger"
sentinel_check_enabled "error_logger"

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
echo "    1. Fix the root cause and retry"
echo "    2. Try a completely different approach"
echo "    3. If you CANNOT fix it — TELL THE USER. Do not hide failures."
echo "  NEVER claim 'done' or 'fixed' when errors remain unresolved."
echo ""

# Session error count (total errors in current log)
TOTAL_ERRORS=0
if [[ -f "$LOG_FILE" ]]; then
  TOTAL_ERRORS=$(wc -l < "$LOG_FILE" 2>/dev/null || true)
  [[ -z "$TOTAL_ERRORS" ]] && TOTAL_ERRORS=0
fi

# Check for repeated failures (same error hash 3+ times)
REPEAT_COUNT=0
if [[ -f "$LOG_FILE" ]]; then
  REPEAT_COUNT=$(grep -c "\"hash\":\"${ERROR_HASH}\"" "$LOG_FILE" 2>/dev/null || true)
  [[ -z "$REPEAT_COUNT" || "$REPEAT_COUNT" == *$'\n'* ]] && REPEAT_COUNT=0
fi

if [[ $REPEAT_COUNT -ge 3 ]]; then
  echo "🔴 [Sentinel] SAME ERROR ${REPEAT_COUNT}x — YOU ARE STUCK"
  echo "  You are repeating the exact same failed approach."
  echo "  STOP. You clearly cannot solve this alone."
  echo "  ➜ REPORT TO USER: explain what you tried, what failed, and ask for guidance."
  echo "  Do NOT try again. Do NOT skip it. Do NOT pretend it's fixed."
  echo ""
fi

# 5+ total errors in session — you need help
if [[ $TOTAL_ERRORS -ge 5 ]]; then
  echo "🆘 [Sentinel] ${TOTAL_ERRORS} errors this session — ASK THE USER FOR HELP"
  echo "  You have accumulated ${TOTAL_ERRORS} errors. This suggests you are struggling."
  echo "  MANDATORY: Tell the user:"
  echo "    - What you were trying to do"
  echo "    - What errors you hit (summarize)"
  echo "    - What approaches you already tried"
  echo "    - Ask for direction before continuing"
  echo "  Continuing silently after this many errors is dishonest."
  echo ""
fi

# Keep log file from growing too large (max 500 entries)
if [[ -f "$LOG_FILE" ]]; then
  LINE_COUNT=$(wc -l < "$LOG_FILE")
  if [[ $LINE_COUNT -gt 500 ]]; then
    tail -250 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
  fi
fi

exit 0
