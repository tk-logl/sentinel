#!/bin/bash
# Sentinel PreToolUse Hook: Deny Dummy Code (BLOCKING)
# Blocks placeholder/stub/debug code from being written.
# Exit 2 = DENY | Exit 0 = ALLOW

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

# 1. Standalone pass (Python) — not after @abstractmethod or in type stub
if echo "$CONTENT" | grep -qP '^\s+pass\s*$'; then
  # Check it's not in a class with @abstractmethod context
  if ! echo "$CONTENT" | grep -qP '@abstractmethod'; then
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

# 7. Pattern #3: Silent Error Swallowing — except blocks that hide errors
if echo "$CONTENT" | grep -qP '^\s*except\s*:\s*$|^\s*except\s+\w+\s*:\s*pass\s*$|^\s*except\s+Exception\s*(as\s+\w+)?\s*:\s*(pass|return\s*$|return\s+None|continue)'; then
  if ! echo "$CONTENT" | grep -qP 'logger\.|logging\.|log\.'; then
    VIOLATIONS="${VIOLATIONS}  - Silent error swallowing (except: pass/return None) — log the error, then handle it [Pattern #3]\n"
  fi
fi

# 8. Pattern #5: Abandoned Test Code — skipped tests without reason
if echo "$CONTENT" | grep -qP '@pytest\.mark\.skip\s*$|@pytest\.mark\.skip\(\s*\)|@unittest\.skip\s*$|@unittest\.skip\(\s*\)|\.skip\(\s*["\x27]\s*["\x27]\s*\)'; then
  VIOLATIONS="${VIOLATIONS}  - Skipped test without reason — provide skip reason or remove [Pattern #5]\n"
fi
if echo "$CONTENT" | grep -qP '^\s*#\s*(def test_|class Test|it\(|describe\()'; then
  VIOLATIONS="${VIOLATIONS}  - Commented-out test code — delete or implement, don't comment out [Pattern #5]\n"
fi

# 9. Pattern #10: Security Bypass — disabling SSL/verification
if echo "$CONTENT" | grep -qP 'verify\s*=\s*False|ssl\s*=\s*False|check_hostname\s*=\s*False|VERIFY_SSL\s*=\s*False'; then
  VIOLATIONS="${VIOLATIONS}  - SSL/TLS verification disabled (verify=False) — never disable in production [Pattern #10]\n"
fi

# 10. Pattern #27: Unsafe Deserialization
if echo "$CONTENT" | grep -qP 'pickle\.loads?\(|yaml\.load\([^)]*(?!Loader)|yaml\.unsafe_load|marshal\.loads?\(|shelve\.open'; then
  if ! echo "$CONTENT" | grep -qP 'yaml\.safe_load|Loader=yaml\.SafeLoader|Loader=yaml\.FullLoader'; then
    VIOLATIONS="${VIOLATIONS}  - Unsafe deserialization (pickle/yaml.load) — use safe alternatives [Pattern #27]\n"
  fi
fi

# 11. Pattern #29: Command Injection — shell=True with variables
if echo "$CONTENT" | grep -qP 'subprocess\.\w+\(.*shell\s*=\s*True|os\.system\s*\(|os\.popen\s*\('; then
  if echo "$CONTENT" | grep -qP 'f["\x27]|\.format\(|\%\s'; then
    VIOLATIONS="${VIOLATIONS}  - Command injection risk (shell=True + string formatting) — use subprocess with list args [Pattern #29]\n"
  fi
fi

# 12. Deep AST analysis (Python/TS/Go patterns grep can't catch)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ -f "${SCRIPT_DIR}/deep-analyze.py" ]]; then
  DEEP_RESULTS=$(echo "$CONTENT" | python3 "${SCRIPT_DIR}/deep-analyze.py" --mode pre --ext "$EXT" 2>/dev/null | head -10)
  if [[ -n "$DEEP_RESULTS" ]]; then
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      VIOLATIONS="${VIOLATIONS}  - ${line}\n"
    done <<< "$DEEP_RESULTS"
  fi
fi

if [[ -n "$VIOLATIONS" ]]; then
  echo "⛔ [Sentinel Deny-Dummy] Placeholder/stub code detected in: $(basename "$FILE_PATH")"
  echo ""
  echo -e "Violations:\n${VIOLATIONS}"
  echo "Every function must have a real implementation. No stubs, no deferred work."
  echo "→ Implement the actual logic, then retry."
  exit 2
fi

exit 0
