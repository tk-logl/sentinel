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
      MSG="  - 'pass' as standalone statement (implement the function body)\n"
      [[ "$ACTION" == "block" ]] && BLOCKS="${BLOCKS}${MSG}" || WARNINGS="${WARNINGS}${MSG}"
    fi
  fi
fi

# 2. raise NotImplementedError without @abstractmethod
ACTION=$(sentinel_get_action "codeQuality" "block_not_implemented")
if [[ "$ACTION" != "off" ]]; then
  if ! $CTXMAP_RAISE_OK && echo "$CONTENT" | grep -qP 'raise NotImplementedError'; then
    if ! echo "$CONTENT" | grep -qP '@abstractmethod'; then
      MSG="  - 'raise NotImplementedError' without @abstractmethod (implement the logic)\n"
      [[ "$ACTION" == "block" ]] && BLOCKS="${BLOCKS}${MSG}" || WARNINGS="${WARNINGS}${MSG}"
    fi
  fi
fi

# 3. TODO/FIXME/PLACEHOLDER/HACK comments
ACTION=$(sentinel_get_action "codeQuality" "block_todo_comments")
if [[ "$ACTION" != "off" ]]; then
  if echo "$CONTENT" | grep -qP '#\s*(TODO|FIXME|PLACEHOLDER|HACK|XXX)\b|//\s*(TODO|FIXME|PLACEHOLDER|HACK|XXX)\b'; then
    MSG="  - TODO/FIXME/PLACEHOLDER/HACK comment (implement now, don't defer)\n"
    [[ "$ACTION" == "block" ]] && BLOCKS="${BLOCKS}${MSG}" || WARNINGS="${WARNINGS}${MSG}"
  fi
fi

# 4. Meaningless test assertions
ACTION=$(sentinel_get_action "codeQuality" "block_meaningless_assertions")
if [[ "$ACTION" != "off" ]]; then
  if echo "$CONTENT" | grep -qP 'assert\s+True|assert\s+1\s*==\s*1|assert\s+.*is\s+not\s+None\s*$|expect\(true\)\.toBe\(true\)'; then
    MSG="  - Meaningless assertion (assert True / expect(true).toBe(true)) — test real behavior\n"
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
    MSG="  - Empty function body (return None) — implement real logic\n"
    [[ "$ACTION" == "block" ]] && BLOCKS="${BLOCKS}${MSG}" || WARNINGS="${WARNINGS}${MSG}"
  fi
fi

# 7. Skipped tests without reason
ACTION=$(sentinel_get_action "codeQuality" "block_skipped_tests")
if [[ "$ACTION" != "off" ]]; then
  if echo "$CONTENT" | grep -qP '@pytest\.mark\.skip\s*$|@pytest\.mark\.skip\(\s*\)|@unittest\.skip\s*$|@unittest\.skip\(\s*\)|\.skip\(\s*["\'\''"]\s*["\'\''"]\s*\)'; then
    MSG="  - Skipped test without reason — provide skip reason or remove [Pattern #5]\n"
    [[ "$ACTION" == "block" ]] && BLOCKS="${BLOCKS}${MSG}" || WARNINGS="${WARNINGS}${MSG}"
  fi
  if echo "$CONTENT" | grep -qP '^\s*#\s*(def test_|class Test|it\(|describe\()'; then
    MSG="  - Commented-out test code — delete or implement, don't comment out [Pattern #5]\n"
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
    echo "Every function must have a real implementation. No stubs, no deferred work."
    echo "→ Implement the actual logic, then retry."
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
