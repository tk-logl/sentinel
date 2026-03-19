#!/bin/bash
# Sentinel PostToolUse Hook: Error Logger (LOGGING)
# Classifies and logs Bash errors. Detects repeated failures.
# Exit 0 = ALLOW (always, just logs)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/_common.sh"
sentinel_require_jq "error-logger"
sentinel_require_pcre "error-logger"
sentinel_compat_check "error_logger"

# Check per-item action
ACTION=$(sentinel_get_action "analysis" "error_logging" "on")
[[ "$ACTION" == "off" ]] && exit 0

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

# Skip user-cancelled operations
IS_INTERRUPT=$(echo "$INPUT" | jq -r '.is_interrupt // false' 2>/dev/null)
[[ "$IS_INTERRUPT" == "true" ]] && exit 0

if [[ "$TOOL_NAME" == "Bash" ]]; then
  # PostToolUse path: check exit code
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

  COMMAND_SHORT=$(echo "$COMMAND" | head -1 | cut -c1-100)
  OUTPUT_SHORT=$(echo "$OUTPUT" | head -3 | tr '\n' ' ' | cut -c1-200)
  DISPLAY_CMD="$COMMAND_SHORT"
else
  # PostToolUseFailure path: non-Bash tools
  ERROR_FIELD=$(echo "$INPUT" | jq -r '.error // empty' 2>/dev/null)
  [[ -z "$ERROR_FIELD" ]] && exit 0

  EXIT_CODE="fail"
  OUTPUT="$ERROR_FIELD"
  ERROR_TYPE="tool-failure"
  COMMAND="${TOOL_NAME}"
  COMMAND_SHORT="${TOOL_NAME}"
  OUTPUT_SHORT=$(echo "$ERROR_FIELD" | head -3 | tr '\n' ' ' | cut -c1-200)
  DISPLAY_CMD="${TOOL_NAME}"
fi

# Find project root and log
PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
[[ -z "$PROJECT_ROOT" ]] && exit 0

LOG_DIR="${PROJECT_ROOT}/.sentinel"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/error-log.jsonl"

# Create log entry (using jq for safe JSON construction — no injection via quotes/backslashes)
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
ERROR_HASH=$(echo "${COMMAND}${ERROR_TYPE}" | md5sum | cut -c1-8)

# Write to log — jq --arg safely escapes all special characters
jq -n --arg ts "$TIMESTAMP" \
      --arg type "$ERROR_TYPE" \
      --arg exit "$EXIT_CODE" \
      --arg hash "$ERROR_HASH" \
      --arg cmd "$COMMAND_SHORT" \
      --arg output "$OUTPUT_SHORT" \
      '{ts:$ts,type:$type,exit:$exit,hash:$hash,cmd:$cmd,output:$output}' \
      -c >> "$LOG_FILE"

# === MANDATORY ERROR RESPONSE — injected on EVERY error ===
# Sanitize user-controlled output (uses sentinel_sanitize from _common.sh)
echo "🚨 [Sentinel Error-Logger] Tool failed (${ERROR_TYPE}, exit ${EXIT_CODE})"
echo "  Tool/Command: $(sentinel_sanitize "$DISPLAY_CMD")"
echo "  Output: $(sentinel_sanitize "$OUTPUT_SHORT")"
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

# Check for repeated failures (same error hash N+ times, configurable)
REPEAT_LIMIT=$(sentinel_read_config '.error_repeat_limit' '3')
REPEAT_COUNT=0
if [[ -f "$LOG_FILE" ]]; then
  REPEAT_COUNT=$(grep -c "\"hash\":\"${ERROR_HASH}\"" "$LOG_FILE" 2>/dev/null || true)
  [[ -z "$REPEAT_COUNT" || "$REPEAT_COUNT" == *$'\n'* ]] && REPEAT_COUNT=0
fi

if [[ $REPEAT_COUNT -ge $REPEAT_LIMIT ]]; then
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
