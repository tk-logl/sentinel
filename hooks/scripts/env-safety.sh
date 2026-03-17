#!/bin/bash
# Sentinel PreToolUse Hook: Environment Safety (BLOCKING)
# Blocks dangerous system commands. Exit 2 = DENY | Exit 0 = ALLOW

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

[[ "$TOOL_NAME" != "Bash" ]] && exit 0

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
[[ -z "$COMMAND" ]] && exit 0

# 1. Block brew on Linux
if echo "$COMMAND" | grep -qP '\bbrew\s+(install|uninstall|upgrade|tap)'; then
  if [[ "$(uname)" == "Linux" ]]; then
    echo "⛔ [Sentinel Env-Safety] 'brew' is not available on Linux"
    echo "  Use apt, pip, npm, or the appropriate package manager."
    exit 2
  fi
fi

# 2. Block bare 'python' (should be 'python3')
if echo "$COMMAND" | grep -qP '(?<!\w)python(?!3)\s' ; then
  # Allow 'python3', 'python -m venv' check, and shebang references
  if ! echo "$COMMAND" | grep -qP 'python3|/usr/bin/env python|which python|python --version'; then
    echo "⛔ [Sentinel Env-Safety] Use 'python3' instead of 'python'"
    echo "  On modern systems, 'python' may not exist or point to Python 2."
    exit 2
  fi
fi

# 3. Block dangerous rm commands
if echo "$COMMAND" | grep -qP 'rm\s+(-rf|-fr|--recursive)\s+(/|~/|\./|\.\.|/home|/etc|/var|/usr)\b'; then
  echo "⛔ [Sentinel Env-Safety] Dangerous rm command blocked"
  echo "  Target: $(echo "$COMMAND" | grep -oP 'rm\s+\S+\s+\S+')"
  echo "  Never delete root, home, or system directories."
  echo "  If you need to clean up, specify exact paths."
  exit 2
fi

# 4. Block pip without --break-system-packages on managed systems
if echo "$COMMAND" | grep -qP 'pip3?\s+install(?!.*--break-system-packages)(?!.*-e\s+\.)(?!.*venv)'; then
  # Check if we're in a venv
  if [[ -z "$VIRTUAL_ENV" ]]; then
    # Check if system is externally managed (Ubuntu 24.04+)
    if [[ -f /usr/lib/python3*/EXTERNALLY-MANAGED ]] 2>/dev/null; then
      echo "⚠️ [Sentinel Env-Safety] pip install without --break-system-packages"
      echo "  This system uses externally managed Python (Ubuntu 24.04+)."
      echo "  Add --break-system-packages flag, or use a virtual environment."
    fi
  fi
fi

# 5. Block --no-verify (bypassing pre-commit hooks)
if echo "$COMMAND" | grep -qP 'git\s+(commit|push|merge)\s+.*--no-verify'; then
  echo "⛔ [Sentinel Env-Safety] --no-verify detected — bypassing safety hooks"
  echo "  Pre-commit hooks exist for a reason. Fix the underlying issue instead."
  echo "  If a hook is broken, fix the hook — don't skip it."
  exit 2
fi

# 6. Warn on sudo usage
if echo "$COMMAND" | grep -qP '^\s*sudo\s'; then
  echo "⚠️ [Sentinel Env-Safety] sudo detected"
  echo "  Avoid running commands as root unless absolutely necessary."
  echo "  Check if the operation works without sudo first."
fi

# 7. Warn on force push (not block — requires justification)
if echo "$COMMAND" | grep -qP 'git\s+push\s+.*--force(?!-with-lease)'; then
  echo "⚠️ [Sentinel Env-Safety] git push --force detected"
  echo "  Force pushing rewrites remote history and can destroy others' work."
  echo "  Consider: git push --force-with-lease (safer alternative)"
  echo "  If you must force push, explain why in the commit message."
fi

# 6. Warn on git reset --hard
if echo "$COMMAND" | grep -qP 'git\s+reset\s+--hard'; then
  echo "⚠️ [Sentinel Env-Safety] git reset --hard detected"
  echo "  This permanently discards uncommitted changes."
  echo "  Consider: git stash (preserves changes for later)"
fi

exit 0
