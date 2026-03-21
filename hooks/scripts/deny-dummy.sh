#!/bin/bash
# Sentinel PreToolUse Hook: Deny Dummy Code (BLOCKING)
# Blocks placeholder/stub/debug code from being written.
# v1.5.0: Per-item configurable actions (block/warn/off).
# Exit 2 = DENY | Exit 0 = ALLOW

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/_common.sh"
sentinel_require_jq "deny-dummy" "blocking"
sentinel_require_pcre "deny-dummy" "blocking"
sentinel_compat_check "deny_dummy"

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

if [[ "$TOOL_NAME" != "Edit" && "$TOOL_NAME" != "Write" ]]; then
  exit 0
fi

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[[ -z "$FILE_PATH" ]] && exit 0

# Only check source code (config-driven extensions)
if ! sentinel_is_source_file "$FILE_PATH"; then exit 0; fi

# Skip test files, config dirs, and user-configured skip patterns
if sentinel_should_skip "$FILE_PATH"; then exit 0; fi

# Get the content being written/edited
if [[ "$TOOL_NAME" == "Write" ]]; then
  CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // empty' 2>/dev/null)
elif [[ "$TOOL_NAME" == "Edit" ]]; then
  CONTENT=$(echo "$INPUT" | jq -r '.tool_input.new_string // empty' 2>/dev/null)
fi

[[ -z "$CONTENT" ]] && exit 0

# ─── Context Map Integration ───
CTXMAP_PASS_OK=false
CTXMAP_RAISE_OK=false

PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
if [[ -n "$PROJECT_ROOT" && -f "${PROJECT_ROOT}/.sentinel/context-map.json" && ! -f "${PROJECT_ROOT}/.sentinel/context-map.building" ]]; then
  REL_PATH="${FILE_PATH#"${PROJECT_ROOT}"/}"
  FILE_FUNCS=$(jq -r --arg f "$REL_PATH" '(.files[$f].functions // {}) | to_entries[] | "\(.key)=\(.value.classification)"' \
    "${PROJECT_ROOT}/.sentinel/context-map.json" 2>/dev/null)

  if [[ -n "$FILE_FUNCS" ]]; then
    CONTENT_FUNCS=$(echo "$CONTENT" | grep -oP '(?<=def )\w+' 2>/dev/null || true)
    if [[ -n "$CONTENT_FUNCS" ]]; then
      ALL_PASS_OK=true
      ALL_RAISE_OK=true
      while IFS= read -r fname; do
        [[ -z "$fname" ]] && continue
        MATCHES=$(echo "$FILE_FUNCS" | grep -E "(^|\\.)${fname}=" 2>/dev/null || true)
        if [[ -n "$MATCHES" ]]; then
          HAS_EXEMPT=false
          while IFS= read -r match_line; do
            case "${match_line##*=}" in
              abstract|intentional_noop) HAS_EXEMPT=true ;;
            esac
          done <<< "$MATCHES"
          if ! $HAS_EXEMPT; then
            ALL_PASS_OK=false; ALL_RAISE_OK=false
          fi
        else
          ALL_PASS_OK=false
          ALL_RAISE_OK=false
        fi
      done <<< "$CONTENT_FUNCS"
      $ALL_PASS_OK && CTXMAP_PASS_OK=true
      $ALL_RAISE_OK && CTXMAP_RAISE_OK=true
    fi
  fi
fi

BLOCKS=""
WARNINGS=""

# 1. Standalone pass (Python)
ACTION=$(sentinel_get_action "codeQuality" "block_standalone_pass")
if [[ "$ACTION" != "off" ]]; then
  if ! $CTXMAP_PASS_OK && echo "$CONTENT" | grep -qP '^\s+pass\s*(#.*)?$'; then
    if ! echo "$CONTENT" | grep -qP '@abstractmethod|def __del__|def teardown|def tearDown|def cleanup|def close|finally\s*:'; then
      MSG="  - 'pass' as standalone statement\n    → Read the function name + params + return type. Implement logic matching that signature.\n    → Check callers: grep -rn 'function_name' . — understand what they expect.\n    → If unsure what it should do, read the test file for this module first.\n"
      [[ "$ACTION" == "block" ]] && BLOCKS="${BLOCKS}${MSG}" || WARNINGS="${WARNINGS}${MSG}"
    fi
  fi
fi

# 2. raise NotImplementedError without @abstractmethod
ACTION=$(sentinel_get_action "codeQuality" "block_not_implemented")
if [[ "$ACTION" != "off" ]]; then
  if ! $CTXMAP_RAISE_OK && echo "$CONTENT" | grep -qP 'raise NotImplementedError'; then
    if ! echo "$CONTENT" | grep -qP '@abstractmethod'; then
      MSG="  - 'raise NotImplementedError' without @abstractmethod\n    → This function needs real logic. grep -rn 'function_name' . to find callers.\n    → Read what callers pass in and what they do with the return value.\n    → Implement the actual computation/query/transformation, not a placeholder.\n"
      [[ "$ACTION" == "block" ]] && BLOCKS="${BLOCKS}${MSG}" || WARNINGS="${WARNINGS}${MSG}"
    fi
  fi
fi

# 3. TODO/FIXME/PLACEHOLDER/HACK comments
ACTION=$(sentinel_get_action "codeQuality" "block_todo_comments")
if [[ "$ACTION" != "off" ]]; then
  if echo "$CONTENT" | grep -qP '#\s*(TODO|FIXME|PLACEHOLDER|HACK|XXX)\b|//\s*(TODO|FIXME|PLACEHOLDER|HACK|XXX)\b'; then
    MSG="  - TODO/FIXME/PLACEHOLDER/HACK comment found\n    → Read the comment text — it describes what needs to be done.\n    → Implement that logic NOW, then delete the comment.\n    → If the TODO requires external info you don't have, ask the user instead of leaving it.\n"
    [[ "$ACTION" == "block" ]] && BLOCKS="${BLOCKS}${MSG}" || WARNINGS="${WARNINGS}${MSG}"
  fi
fi

# 4. Meaningless test assertions
ACTION=$(sentinel_get_action "codeQuality" "block_meaningless_assertions")
if [[ "$ACTION" != "off" ]]; then
  # 4a. Trivially true assertions
  if echo "$CONTENT" | grep -qP 'assert\s+True|assert\s+1\s*==\s*1|expect\(true\)\.toBe\(true\)'; then
    MSG="  - Trivially true assertion (assert True / 1==1)\n    → Call the function with specific inputs and assert the OUTPUT matches expected values.\n    → Example: assert get_user(id=1).name == 'expected_name'\n    → Test edge cases: empty input, invalid input, boundary values, error conditions.\n"
    [[ "$ACTION" == "block" ]] && BLOCKS="${BLOCKS}${MSG}" || WARNINGS="${WARNINGS}${MSG}"
  fi
  # 4b. assert X is not None as the ONLY assertion in a test function
  if echo "$CONTENT" | grep -qP 'assert\s+\w+\s+is\s+not\s+None\s*$'; then
    # Check if there's a more specific assertion after it
    if ! echo "$CONTENT" | grep -qP 'assert\s+\w+\s*[=!<>]|assert\s+\w+\.\w+|assert\s+len\(|assert\s+isinstance'; then
      MSG="  - Weak assertion: 'assert X is not None' without checking actual value\n    → Assert specific properties: assert result.name == 'expected'\n    → Check type, length, or field values — not just existence.\n"
      [[ "$ACTION" == "block" ]] && BLOCKS="${BLOCKS}${MSG}" || WARNINGS="${WARNINGS}${MSG}"
    fi
  fi
  # 4c. mock.assert_called() without argument verification
  if echo "$CONTENT" | grep -qP '\.assert_called\(\s*\)'; then
    MSG="  - mock.assert_called() without verifying arguments\n    → Use assert_called_with(expected_arg1, expected_arg2) instead.\n    → Or use assert_called_once_with() to verify both call count and arguments.\n"
    [[ "$ACTION" == "block" ]] && BLOCKS="${BLOCKS}${MSG}" || WARNINGS="${WARNINGS}${MSG}"
  fi
  # 4d. assert len(X) >= 0 (always true for any collection)
  if echo "$CONTENT" | grep -qP 'assert\s+len\(\w+\)\s*>=\s*0'; then
    MSG="  - Always-true assertion: len(X) >= 0 is true for any collection\n    → Assert a specific expected length: assert len(result) == 3\n    → Or check content: assert result[0].name == 'expected'\n"
    [[ "$ACTION" == "block" ]] && BLOCKS="${BLOCKS}${MSG}" || WARNINGS="${WARNINGS}${MSG}"
  fi
fi

# 5. Debug print/console.log left in code
ACTION=$(sentinel_get_action "codeQuality" "block_debug_prints")
if [[ "$ACTION" != "off" ]]; then
  if echo "$CONTENT" | grep -qP '^\s*print\s*\(\s*["\'\''](debug|test|here|xxx|TODO)'; then
    MSG="  - Debug print() statement — use logging module instead\n"
    [[ "$ACTION" == "block" ]] && BLOCKS="${BLOCKS}${MSG}" || WARNINGS="${WARNINGS}${MSG}"
  fi
  if echo "$CONTENT" | grep -qP '^\s*console\.log\s*\(\s*["\'\''](debug|test|here|xxx|TODO)'; then
    MSG="  - Debug console.log() — remove before committing\n"
    [[ "$ACTION" == "block" ]] && BLOCKS="${BLOCKS}${MSG}" || WARNINGS="${WARNINGS}${MSG}"
  fi
fi

# 6. Empty function bodies (return None / return undefined / {})
# NOTE: Regex check is imprecise in multi-function files (M1 false positive fix).
# AST gates (ast-quality-gate.py, pre-write-ast.sh) handle this properly.
# Only flag when def and return None are on adjacent lines (2-line function body).
ACTION=$(sentinel_get_action "codeQuality" "block_empty_functions")
if [[ "$ACTION" != "off" ]]; then
  if echo "$CONTENT" | grep -qP '^\s*def\s+\w+\(.*\).*:\s*\n\s+return\s*(None)?\s*(#.*)?$'; then
    MSG="  - Empty function body (return None immediately after def)\n    → Read the function name and return type to understand what it should return.\n    → Implement the actual query/computation/transformation.\n    → If it's a handler/callback, implement the event processing logic.\n"
    [[ "$ACTION" == "block" ]] && BLOCKS="${BLOCKS}${MSG}" || WARNINGS="${WARNINGS}${MSG}"
  fi
fi

# 7. Skipped tests without reason
ACTION=$(sentinel_get_action "codeQuality" "block_skipped_tests")
if [[ "$ACTION" != "off" ]]; then
  if echo "$CONTENT" | grep -qP '@pytest\.mark\.skip\s*$|@pytest\.mark\.skip\(\s*\)|@unittest\.skip\s*$|@unittest\.skip\(\s*\)|\.skip\(\s*["\'\''"]\s*["\'\''"]\s*\)'; then
    MSG="  - Skipped test without reason [Pattern #5]\n    → Either implement the test or delete it entirely.\n    → If skipping is necessary, provide a specific reason: @pytest.mark.skip(reason='...')\n"
    [[ "$ACTION" == "block" ]] && BLOCKS="${BLOCKS}${MSG}" || WARNINGS="${WARNINGS}${MSG}"
  fi
  if echo "$CONTENT" | grep -qP '^\s*#\s*(def test_|class Test|it\(|describe\()'; then
    MSG="  - Commented-out test code [Pattern #5]\n    → Uncomment and fix the test, or delete it entirely.\n    → Commented-out code is dead code. Never keep it 'for later'.\n"
    [[ "$ACTION" == "block" ]] && BLOCKS="${BLOCKS}${MSG}" || WARNINGS="${WARNINGS}${MSG}"
  fi
fi

# 8. Unsafe deserialization
ACTION=$(sentinel_get_action "codeQuality" "block_unsafe_deserialization")
if [[ "$ACTION" != "off" ]]; then
  if echo "$CONTENT" | grep -qP 'yaml\.unsafe_load|marshal\.loads?\('; then
    MSG="  - Unsafe deserialization (yaml.unsafe_load/marshal) — use safe alternatives [Pattern #27]\n"
    [[ "$ACTION" == "block" ]] && BLOCKS="${BLOCKS}${MSG}" || WARNINGS="${WARNINGS}${MSG}"
  fi
  if echo "$CONTENT" | grep -qP 'yaml\.load\(' ; then
    if ! echo "$CONTENT" | grep -qP 'yaml\.safe_load|Loader=yaml\.SafeLoader|Loader=yaml\.FullLoader'; then
      MSG="  - yaml.load() without SafeLoader — use yaml.safe_load() [Pattern #27]\n"
      [[ "$ACTION" == "block" ]] && BLOCKS="${BLOCKS}${MSG}" || WARNINGS="${WARNINGS}${MSG}"
    fi
  fi
fi

# 9. Unsafe system commands
ACTION=$(sentinel_get_action "codeQuality" "block_unsafe_commands")
if [[ "$ACTION" != "off" ]]; then
  if echo "$CONTENT" | grep -qP 'os\.system\s*\(|os\.popen\s*\('; then
    MSG="  - os.system()/os.popen() — use subprocess.run() instead [Pattern #29]\n"
    [[ "$ACTION" == "block" ]] && BLOCKS="${BLOCKS}${MSG}" || WARNINGS="${WARNINGS}${MSG}"
  fi
fi

# 10. SSL bypass (always warn-level at most)
ACTION=$(sentinel_get_action "codeQuality" "warn_ssl_bypass" "warn")
if [[ "$ACTION" != "off" ]]; then
  if echo "$CONTENT" | grep -qP 'verify\s*=\s*False|ssl\s*=\s*False|check_hostname\s*=\s*False|VERIFY_SSL\s*=\s*False'; then
    echo "⚠️ [Sentinel] verify=False detected — ensure this is not production code [Pattern #10]"
  fi
fi

# 11. Pickle usage (always warn-level at most)
ACTION=$(sentinel_get_action "codeQuality" "warn_pickle_usage" "warn")
if [[ "$ACTION" != "off" ]]; then
  if echo "$CONTENT" | grep -qP 'pickle\.loads?\('; then
    echo "⚠️ [Sentinel] pickle usage detected — ensure input is trusted (not user-controlled) [Pattern #27]"
  fi
fi

# --- Output ---
if [[ -n "$BLOCKS" ]]; then
  {
    echo "⛔ [Sentinel Deny-Dummy] Placeholder/stub code detected in: $(basename "$FILE_PATH")"
    echo ""
    echo -e "Violations:\n${BLOCKS}"
    if [[ -n "$WARNINGS" ]]; then
      echo -e "Warnings:\n${WARNINGS}"
    fi
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "HOW TO FIX:"
    echo "  1. Read each violation's → guidance above"
    echo "  2. For each function: check signature, callers, and tests"
    echo "  3. Write real logic that processes inputs and returns correct outputs"
    echo "  4. No stubs, no deferred work, no placeholders"
    echo "  5. Retry this edit after implementing"
  } >&2
  sentinel_stats_increment "blocks"
  sentinel_stats_increment "pattern_dummy_code"
  exit 2
fi

if [[ -n "$WARNINGS" ]]; then
  echo "⚠️ [Sentinel Deny-Dummy] Code quality warnings in: $(basename "$FILE_PATH")"
  echo ""
  echo -e "Warnings:\n${WARNINGS}"
  sentinel_stats_increment "warnings"
fi

sentinel_stats_increment "checks"
exit 0
