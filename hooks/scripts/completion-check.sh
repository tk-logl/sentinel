#!/bin/bash
# Sentinel Stop Hook: Completion Verification (WARNING — AGGRESSIVE)
# Performs thorough incomplete-work detection when AI stops generating.
# Exit 0 = ALLOW (Stop hooks cannot block, but warnings are loud)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/_common.sh"
sentinel_require_jq "completion-check"
sentinel_require_pcre "completion-check"

PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
[[ -z "$PROJECT_ROOT" ]] && exit 0

CRITICAL=""
WARNINGS=""

# 1. Uncommitted source changes
DIRTY_SRC=$(git status --porcelain 2>/dev/null | grep -P '\.(py|ts|tsx|js|jsx|go|rs|java|c|cpp|svelte|vue)$' | head -10)
if [[ -n "$DIRTY_SRC" ]]; then
  DIRTY_COUNT=$(echo "$DIRTY_SRC" | wc -l)
  CRITICAL="${CRITICAL}🔴 ${DIRTY_COUNT} UNCOMMITTED source file(s) — commit or explain:\n"
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    CRITICAL="${CRITICAL}  ${line}\n"
  done <<< "$DIRTY_SRC"
  CRITICAL="${CRITICAL}\n"
fi

# 2. Active task not completed
TASK_FILE="${PROJECT_ROOT}/.sentinel/current-task.json"
if [[ -f "$TASK_FILE" ]]; then
  TASK_ID=$(jq -r '.task_id // "unknown"' "$TASK_FILE" 2>/dev/null)
  VERIFY_CMD=$(jq -r '.verify_command // empty' "$TASK_FILE" 2>/dev/null)
  CRITICAL="${CRITICAL}🔴 Active task NOT completed: ${TASK_ID}\n"
  if [[ -n "$VERIFY_CMD" ]]; then
    CRITICAL="${CRITICAL}   Did you run verify_command: ${VERIFY_CMD} ?\n"
  fi
  CRITICAL="${CRITICAL}\n"
fi

# 3. TODO/FIXME/PLACEHOLDER in recently changed files [Pattern #1]
CHANGED_FILES=$( (git diff --name-only HEAD 2>/dev/null; git diff --cached --name-only 2>/dev/null) | sort -u)
if [[ -n "$CHANGED_FILES" ]]; then
  TODO_FOUND=""
  while IFS= read -r file; do
    [[ -z "$file" || ! -f "$PROJECT_ROOT/$file" ]] && continue
    TODOS=$(grep -nP '#\s*(TODO|FIXME|PLACEHOLDER|HACK|XXX)\b|//\s*(TODO|FIXME|PLACEHOLDER|HACK|XXX)\b' "$PROJECT_ROOT/$file" 2>/dev/null | head -3)
    if [[ -n "$TODOS" ]]; then
      TODO_FOUND="${TODO_FOUND}  ${file}: $(echo "$TODOS" | head -1)\n"
    fi
  done <<< "$CHANGED_FILES"
  if [[ -n "$TODO_FOUND" ]]; then
    CRITICAL="${CRITICAL}🔴 TODO/FIXME left in changed files [Pattern #1 False Completion]:\n${TODO_FOUND}\n"
  fi
fi

# 4. Stub code in changed Python files [Pattern #4]
if [[ -n "$CHANGED_FILES" ]]; then
  STUB_FOUND=""
  while IFS= read -r file; do
    [[ -z "$file" || ! -f "$PROJECT_ROOT/$file" ]] && continue
    [[ "$file" == *.py ]] || continue
    STUBS=$(grep -nP '^\s+pass\s*$|raise NotImplementedError' "$PROJECT_ROOT/$file" 2>/dev/null | head -3)
    if [[ -n "$STUBS" ]]; then
      if ! grep -qP '@abstractmethod' "$PROJECT_ROOT/$file" 2>/dev/null; then
        STUB_FOUND="${STUB_FOUND}  ${file}: $(echo "$STUBS" | head -1)\n"
      fi
    fi
  done <<< "$CHANGED_FILES"
  if [[ -n "$STUB_FOUND" ]]; then
    CRITICAL="${CRITICAL}🔴 Stub code in changed files [Pattern #4]:\n${STUB_FOUND}\n"
  fi
fi

# 5. Repeated same error [Pattern #13]
LOG_FILE="${PROJECT_ROOT}/.sentinel/error-log.jsonl"
if [[ -f "$LOG_FILE" ]]; then
  REPEAT_LINE=$(tail -20 "$LOG_FILE" 2>/dev/null | jq -r '.hash' 2>/dev/null | sort | uniq -c | sort -rn | head -1)
  REPEAT_COUNT=$(echo "$REPEAT_LINE" | awk '{print $1}')
  if [[ -n "$REPEAT_COUNT" ]] && [[ "$REPEAT_COUNT" -ge 3 ]] 2>/dev/null; then
    CRITICAL="${CRITICAL}🔴 Same error repeated ${REPEAT_COUNT}x — did you actually fix it? [Pattern #13]\n\n"
  fi

  RECENT_TYPES=$(tail -10 "$LOG_FILE" 2>/dev/null | jq -r '.type' 2>/dev/null | sort | uniq -c | sort -rn | head -3)
  if [[ -n "$RECENT_TYPES" ]]; then
    WARNINGS="${WARNINGS}⚠️  Recent errors:\n"
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      WARNINGS="${WARNINGS}  ${line}\n"
    done <<< "$RECENT_TYPES"
    WARNINGS="${WARNINGS}\n"
  fi
fi

# 6. Silent error swallowing in changed files [Pattern #3]
if [[ -n "$CHANGED_FILES" ]]; then
  while IFS= read -r file; do
    [[ -z "$file" || ! -f "$PROJECT_ROOT/$file" ]] && continue
    [[ "$file" == *.py ]] || continue
    if grep -qP '^\s*except\s*:\s*$|except\s+\w+.*:\s*(pass|return\s*$|return\s+None)\s*$' "$PROJECT_ROOT/$file" 2>/dev/null; then
      WARNINGS="${WARNINGS}⚠️  Silent error swallowing in ${file} [Pattern #3]\n"
    fi
  done <<< "$CHANGED_FILES"
fi

# 7. Unresolved errors in session [Pattern #12]
LOG_FILE="${PROJECT_ROOT}/.sentinel/error-log.jsonl"
if [[ -f "$LOG_FILE" ]]; then
  TOTAL_ERRORS=$(wc -l < "$LOG_FILE" 2>/dev/null || true)
  [[ -z "$TOTAL_ERRORS" ]] && TOTAL_ERRORS=0
  if [[ $TOTAL_ERRORS -ge 3 ]]; then
    LAST_ERROR=$(tail -1 "$LOG_FILE" 2>/dev/null | jq -r '"  \(.type): \(.cmd)"' 2>/dev/null)
    CRITICAL="${CRITICAL}🔴 ${TOTAL_ERRORS} errors logged this session — were they ALL resolved?\n"
    CRITICAL="${CRITICAL}  Last: ${LAST_ERROR}\n"
    CRITICAL="${CRITICAL}  If any error was skipped without fixing, you are NOT done.\n\n"
  fi
fi

# 8. Shell implementations — functions whose ENTIRE body is just a return statement
# Only flags single-statement functions (def + return with nothing in between).
# A 10-line function ending with return [] is legitimate, NOT a facade.
if [[ -n "$CHANGED_FILES" ]]; then
  SHELL_FOUND=""
  while IFS= read -r file; do
    [[ -z "$file" || ! -f "$PROJECT_ROOT/$file" ]] && continue
    [[ "$file" == *.py ]] || continue
    # Find return lines with empty values
    while IFS= read -r match; do
      [[ -z "$match" ]] && continue
      LINE_NUM=$(echo "$match" | cut -d: -f1)
      # Check if the line directly before is a def statement or docstring close
      PREV_LINE=$(sed -n "$((LINE_NUM - 1))p" "$PROJECT_ROOT/$file" 2>/dev/null)
      PREV2_LINE=$(sed -n "$((LINE_NUM - 2))p" "$PROJECT_ROOT/$file" 2>/dev/null)
      # Flag only if: def is on line-1, or def is on line-2 with docstring on line-1
      if echo "$PREV_LINE" | grep -qP '^\s*(def |class )'; then
        SHELL_FOUND="${SHELL_FOUND}  ${file}:${LINE_NUM}: $(echo "$match" | cut -d: -f2-)\n"
      elif echo "$PREV2_LINE" | grep -qP '^\s*(def |class )' && echo "$PREV_LINE" | grep -qP '^\s*("""|'"'"''"'"''"'"'|#)'; then
        SHELL_FOUND="${SHELL_FOUND}  ${file}:${LINE_NUM}: $(echo "$match" | cut -d: -f2-)\n"
      fi
    done < <(grep -nP '^\s+return\s+(""|{}|\[\]|0|False|None|\{\})\s*$' "$PROJECT_ROOT/$file" 2>/dev/null | head -5)
  done <<< "$CHANGED_FILES"
  if [[ -n "$SHELL_FOUND" ]]; then
    WARNINGS="${WARNINGS}⚠️  Possible shell/facade implementations (single-statement functions):\n${SHELL_FOUND}\n"
  fi
fi

# Output
if [[ -n "$CRITICAL" || -n "$WARNINGS" ]]; then
  echo "🛑 [Sentinel Completion Check] — STOP. Review before claiming done."
  echo ""
  if [[ -n "$CRITICAL" ]]; then
    echo "═══ CRITICAL (you are NOT done) ═══"
    echo -e "$CRITICAL"
  fi
  if [[ -n "$WARNINGS" ]]; then
    echo "═══ WARNINGS (verify) ═══"
    echo -e "$WARNINGS"
  fi
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "ANTI-FRAUD CHECKLIST — answer ALL before saying 'done':"
  echo "  1. ALL source changes committed? (not 'will commit later')"
  echo "  2. Tests actually RUN and PASSED? (show the output, not 'should pass')"
  echo "  3. verify_command executed? (paste the result)"
  echo "  4. No TODO/stub/placeholder in your changes?"
  echo "  5. No errors skipped or unresolved?"
  echo "  6. Implementation is REAL logic, not empty returns/facades?"
  echo ""
  echo "  If you cannot prove ALL of these — DO NOT claim completion."
  echo "  Instead, REPORT to the user: what's done, what's not, what's blocked."
  echo "  Honest partial progress > dishonest 'done' claim."
fi

# Always output (even when no issues found) — prevent silent completion
if [[ -z "$CRITICAL" && -z "$WARNINGS" ]]; then
  echo "✅ [Sentinel Completion Check] No issues detected."
  echo "  Reminder: 'no issues detected' means no AUTOMATED issues."
  echo "  You must still verify: does the implementation actually WORK?"
  echo "  Evidence required: test output, command result, or user confirmation."
fi

# Session quality report (shows when 3+ checks happened)
sentinel_stats_report
exit 0
