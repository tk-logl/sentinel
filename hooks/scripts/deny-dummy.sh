#!/bin/bash
# Sentinel PreToolUse Hook: Deny Dummy Code (BLOCKING)
# Blocks placeholder/stub/debug code from being written.
# Exit 2 = DENY | Exit 0 = ALLOW

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/_common.sh"
sentinel_require_jq "deny-dummy"
sentinel_require_pcre "deny-dummy"

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

if [[ "$TOOL_NAME" != "Edit" && "$TOOL_NAME" != "Write" ]]; then
  exit 0
fi

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[[ -z "$FILE_PATH" ]] && exit 0

# Only check source code
EXT="${FILE_PATH##*.}"
case "$EXT" in
  py|ts|tsx|js|jsx|go|rs|java|c|cpp|svelte|vue) ;;
  *) exit 0 ;;
esac

# Skip test files — assert patterns are valid in tests
if echo "$FILE_PATH" | grep -qP '(\.test\.|\.spec\.|/tests/|/test_|_test\.)'; then
  exit 0
fi

# Skip sentinel/config/hook files
case "$FILE_PATH" in
  */.sentinel/*|*/.claude/*|*/.omc/*|*/.github/*) exit 0 ;;
esac

# Get the content being written/edited
if [[ "$TOOL_NAME" == "Write" ]]; then
  CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // empty' 2>/dev/null)
elif [[ "$TOOL_NAME" == "Edit" ]]; then
  CONTENT=$(echo "$INPUT" | jq -r '.tool_input.new_string // empty' 2>/dev/null)
fi

[[ -z "$CONTENT" ]] && exit 0

VIOLATIONS=""

# 1. Standalone pass (Python) — not in @abstractmethod, __del__, finally, or cleanup
if echo "$CONTENT" | grep -qP '^\s+pass\s*$'; then
  # Allow pass in: @abstractmethod, __del__, finally blocks, cleanup/teardown functions
  if ! echo "$CONTENT" | grep -qP '@abstractmethod|def __del__|def teardown|def tearDown|def cleanup|def close|finally\s*:'; then
    VIOLATIONS="${VIOLATIONS}  - 'pass' as standalone statement (implement the function body)\n"
  fi
fi

# 2. raise NotImplementedError without @abstractmethod
if echo "$CONTENT" | grep -qP 'raise NotImplementedError'; then
  if ! echo "$CONTENT" | grep -qP '@abstractmethod'; then
    VIOLATIONS="${VIOLATIONS}  - 'raise NotImplementedError' without @abstractmethod (implement the logic)\n"
  fi
fi

# 3. TODO/FIXME/PLACEHOLDER/HACK comments
if echo "$CONTENT" | grep -qP '#\s*(TODO|FIXME|PLACEHOLDER|HACK|XXX)\b|//\s*(TODO|FIXME|PLACEHOLDER|HACK|XXX)\b'; then
  VIOLATIONS="${VIOLATIONS}  - TODO/FIXME/PLACEHOLDER/HACK comment (implement now, don't defer)\n"
fi

# 4. Meaningless test assertions
if echo "$CONTENT" | grep -qP 'assert\s+True|assert\s+1\s*==\s*1|assert\s+.*is\s+not\s+None\s*$|expect\(true\)\.toBe\(true\)'; then
  VIOLATIONS="${VIOLATIONS}  - Meaningless assertion (assert True / expect(true).toBe(true)) — test real behavior\n"
fi

# 5. Debug print/console.log left in code
if echo "$CONTENT" | grep -qP '^\s*print\s*\(\s*["\x27](debug|test|here|xxx|TODO)' ; then
  VIOLATIONS="${VIOLATIONS}  - Debug print() statement — use logging module instead\n"
fi
if echo "$CONTENT" | grep -qP '^\s*console\.log\s*\(\s*["\x27](debug|test|here|xxx|TODO)'; then
  VIOLATIONS="${VIOLATIONS}  - Debug console.log() — remove before committing\n"
fi

# 6. Empty function bodies (return None / return undefined / {})
if echo "$CONTENT" | grep -qP '^\s*def\s+\w+\(.*\).*:\s*$' && echo "$CONTENT" | grep -qP '^\s+return\s*$|^\s+return\s+None\s*$'; then
  VIOLATIONS="${VIOLATIONS}  - Empty function body (return None) — implement real logic\n"
fi

# 7. Pattern #3: Silent Error Swallowing — moved to post-edit-verify (WARNING)
# except:pass has legitimate uses (cleanup, __del__, retry). Don't block, just warn.

# 8. Pattern #5: Abandoned Test Code — skipped tests without reason
if echo "$CONTENT" | grep -qP '@pytest\.mark\.skip\s*$|@pytest\.mark\.skip\(\s*\)|@unittest\.skip\s*$|@unittest\.skip\(\s*\)|\.skip\(\s*["\x27]\s*["\x27]\s*\)'; then
  VIOLATIONS="${VIOLATIONS}  - Skipped test without reason — provide skip reason or remove [Pattern #5]\n"
fi
if echo "$CONTENT" | grep -qP '^\s*#\s*(def test_|class Test|it\(|describe\()'; then
  VIOLATIONS="${VIOLATIONS}  - Commented-out test code — delete or implement, don't comment out [Pattern #5]\n"
fi

# 9. Pattern #10: Security Bypass — disabling SSL/verification
# WARNING only (not blocking) — local dev with self-signed certs is legitimate
if echo "$CONTENT" | grep -qP 'verify\s*=\s*False|ssl\s*=\s*False|check_hostname\s*=\s*False|VERIFY_SSL\s*=\s*False'; then
  echo "⚠️ [Sentinel] verify=False detected — ensure this is not production code [Pattern #10]"
fi

# 10. Pattern #27: Unsafe Deserialization
# WARNING only for pickle (ML model/cache is legitimate), BLOCK for yaml.unsafe_load
if echo "$CONTENT" | grep -qP 'yaml\.unsafe_load|marshal\.loads?\('; then
  VIOLATIONS="${VIOLATIONS}  - Unsafe deserialization (yaml.unsafe_load/marshal) — use safe alternatives [Pattern #27]\n"
fi
if echo "$CONTENT" | grep -qP 'pickle\.loads?\('; then
  echo "⚠️ [Sentinel] pickle usage detected — ensure input is trusted (not user-controlled) [Pattern #27]"
fi
if echo "$CONTENT" | grep -qP 'yaml\.load\(' ; then
  if ! echo "$CONTENT" | grep -qP 'yaml\.safe_load|Loader=yaml\.SafeLoader|Loader=yaml\.FullLoader'; then
    VIOLATIONS="${VIOLATIONS}  - yaml.load() without SafeLoader — use yaml.safe_load() [Pattern #27]\n"
  fi
fi

# 11. Pattern #29: Command Injection — moved to post-edit-verify (WARNING)
# shell=True has legitimate uses (pipes, globbing). Warn, don't block.
if echo "$CONTENT" | grep -qP 'os\.system\s*\(|os\.popen\s*\('; then
  VIOLATIONS="${VIOLATIONS}  - os.system()/os.popen() — use subprocess.run() instead [Pattern #29]\n"
fi

# Deep AST analysis is handled by post-edit-verify.sh (WARNING only).
# deny-dummy.sh only blocks patterns that are ALWAYS wrong — no legitimate use case.

if [[ -n "$VIOLATIONS" ]]; then
  echo "⛔ [Sentinel Deny-Dummy] Placeholder/stub code detected in: $(basename "$FILE_PATH")"
  echo ""
  echo -e "Violations:\n${VIOLATIONS}"
  echo "Every function must have a real implementation. No stubs, no deferred work."
  echo "→ Implement the actual logic, then retry."
  exit 2
fi

exit 0
