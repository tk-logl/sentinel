#!/bin/bash
# Sentinel PreToolUse Hook: Environment Safety (BLOCKING)
# Blocks dangerous system commands.
# v1.5.0: Per-item configurable actions (block/warn/off) + 5 new checks.
# Exit 2 = DENY | Exit 0 = ALLOW

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/_common.sh"
sentinel_require_jq "env-safety" "blocking"
sentinel_require_pcre "env-safety" "blocking"
sentinel_compat_check "env_safety"

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

[[ "$TOOL_NAME" != "Bash" ]] && exit 0

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
[[ -z "$COMMAND" ]] && exit 0

# --- Protected branches config ---
# Read from .sentinel/config.json or default to main,master,develop
_PROTECTED_BRANCHES=""
_get_protected_branches() {
  if [[ -z "$_PROTECTED_BRANCHES" ]]; then
    _PROTECTED_BRANCHES=$(sentinel_read_config \
      'if .protected_branches then (.protected_branches | join("|")) else empty end' \
      "main|master|develop")
  fi
  echo "$_PROTECTED_BRANCHES"
}

# 1. Block brew on Linux
ACTION=$(sentinel_get_action "safetyNet" "block_brew_on_linux")
if [[ "$ACTION" != "off" ]]; then
  if echo "$COMMAND" | grep -qP '\bbrew\s+(install|uninstall|upgrade|tap)'; then
    if [[ "$(uname)" == "Linux" ]]; then
      echo "⛔ [Sentinel Env-Safety] 'brew' is not available on Linux"
      echo "  Use apt, pip, npm, or the appropriate package manager."
      sentinel_stats_increment "blocks"
      [[ "$ACTION" == "block" ]] && exit 2
    fi
  fi
fi

# 2. Block bare 'python' (should be 'python3')
ACTION=$(sentinel_get_action "safetyNet" "block_bare_python")
if [[ "$ACTION" != "off" ]]; then
  if echo "$COMMAND" | grep -qP '(?<!\w)python(?!3)\s' ; then
    if ! echo "$COMMAND" | grep -qP 'python3|/usr/bin/env python|which python|python --version'; then
      echo "⛔ [Sentinel Env-Safety] Use 'python3' instead of 'python'"
      echo "  On modern systems, 'python' may not exist or point to Python 2."
      sentinel_stats_increment "blocks"
      [[ "$ACTION" == "block" ]] && exit 2
    fi
  fi
fi

# 3. Block dangerous rm commands
ACTION=$(sentinel_get_action "safetyNet" "block_dangerous_rm")
if [[ "$ACTION" != "off" ]]; then
  if echo "$COMMAND" | grep -qP 'rm\s+(-rf|-fr|--recursive)\s+(/\s*$|/\s+|~/|\./?\.\.|\./\s|/home|/etc|/var|/usr)'; then
    echo "⛔ [Sentinel Env-Safety] Dangerous rm command blocked"
    echo "  Target: $(sentinel_sanitize "$(echo "$COMMAND" | grep -oP 'rm\s+\S+\s+\S+')")"
    echo "  Never delete root, home, or system directories."
    echo "  If you need to clean up, specify exact paths."
    sentinel_stats_increment "blocks"
    [[ "$ACTION" == "block" ]] && exit 2
  fi
fi

# 4. Warn on pip without --break-system-packages
ACTION=$(sentinel_get_action "safetyNet" "warn_pip_without_venv" "warn")
if [[ "$ACTION" != "off" ]]; then
  if echo "$COMMAND" | grep -qP 'pip3?\s+install(?!.*--break-system-packages)(?!.*-e\s+\.)(?!.*venv)'; then
    if [[ -z "$VIRTUAL_ENV" ]]; then
      if compgen -G "/usr/lib/python3*/EXTERNALLY-MANAGED" >/dev/null 2>&1; then
        echo "⚠️ [Sentinel Env-Safety] pip install without --break-system-packages"
        echo "  This system uses externally managed Python (Ubuntu 24.04+)."
        echo "  Add --break-system-packages flag, or use a virtual environment."
        sentinel_stats_increment "warnings"
      fi
    fi
  fi
fi

# 5. Block --no-verify (bypassing pre-commit hooks)
ACTION=$(sentinel_get_action "safetyNet" "block_no_verify")
if [[ "$ACTION" != "off" ]]; then
  if echo "$COMMAND" | grep -qP 'git\s+(commit|push|merge)\s+.*--no-verify'; then
    echo "⛔ [Sentinel Env-Safety] --no-verify detected — bypassing safety hooks"
    echo "  Pre-commit hooks exist for a reason. Fix the underlying issue instead."
    echo "  If a hook is broken, fix the hook — don't skip it."
    sentinel_stats_increment "blocks"
    [[ "$ACTION" == "block" ]] && exit 2
  fi
fi

# 6. Warn on sudo usage
ACTION=$(sentinel_get_action "safetyNet" "warn_sudo" "warn")
if [[ "$ACTION" != "off" ]]; then
  if echo "$COMMAND" | grep -qP '^\s*sudo\s'; then
    echo "⚠️ [Sentinel Env-Safety] sudo detected"
    echo "  Avoid running commands as root unless absolutely necessary."
    echo "  Check if the operation works without sudo first."
    sentinel_stats_increment "warnings"
    [[ "$ACTION" == "block" ]] && exit 2
  fi
fi

# 7. Block/warn force push
ACTION=$(sentinel_get_action "safetyNet" "block_force_push" "warn")
if [[ "$ACTION" != "off" ]]; then
  if echo "$COMMAND" | grep -qP 'git\s+push\s+.*--force(?!-with-lease)'; then
    echo "⛔ [Sentinel Env-Safety] git push --force detected"
    echo "  Force pushing rewrites remote history and can destroy others' work."
    echo "  Consider: git push --force-with-lease (safer alternative)"
    echo "  If you must force push, explain why in the commit message."
    sentinel_stats_increment "blocks"
    [[ "$ACTION" == "block" ]] && exit 2
  fi
fi

# 8. Block/warn git reset --hard
ACTION=$(sentinel_get_action "safetyNet" "block_git_reset_hard" "warn")
if [[ "$ACTION" != "off" ]]; then
  if echo "$COMMAND" | grep -qP 'git\s+reset\s+--hard'; then
    echo "⛔ [Sentinel Env-Safety] git reset --hard detected"
    echo "  This permanently discards uncommitted changes."
    echo "  Consider: git stash (preserves changes for later)"
    sentinel_stats_increment "blocks"
    [[ "$ACTION" == "block" ]] && exit 2
  fi
fi

# 9. Block push to protected branches (NEW in v1.5.0)
ACTION=$(sentinel_get_action "safetyNet" "block_push_protected_branch")
if [[ "$ACTION" != "off" ]]; then
  PROTECTED=$(_get_protected_branches)
  if echo "$COMMAND" | grep -qP "git\s+push\s+\S+\s+(${PROTECTED})\b|git\s+push\s+origin\s+(${PROTECTED})\b"; then
    BRANCH_MATCH=$(echo "$COMMAND" | grep -oP "git\s+push\s+\S+\s+\K(${PROTECTED})" | head -1)
    echo "⛔ [Sentinel Env-Safety] Push to protected branch '${BRANCH_MATCH}' blocked"
    echo "  Protected branches: $(echo "$PROTECTED" | tr '|' ', ')"
    echo "  Use a feature branch and create a pull request instead."
    sentinel_stats_increment "blocks"
    [[ "$ACTION" == "block" ]] && exit 2
  fi
fi

# 10. Block git clean (NEW in v1.5.0)
ACTION=$(sentinel_get_action "safetyNet" "block_git_clean")
if [[ "$ACTION" != "off" ]]; then
  if echo "$COMMAND" | grep -qP 'git\s+clean\s+.*-[a-zA-Z]*f'; then
    echo "⛔ [Sentinel Env-Safety] git clean -f detected"
    echo "  This permanently deletes untracked files."
    echo "  Use 'git clean -n' (dry-run) first to see what would be removed."
    sentinel_stats_increment "blocks"
    [[ "$ACTION" == "block" ]] && exit 2
  fi
fi

# 11. Block git checkout discard (NEW in v1.5.0)
ACTION=$(sentinel_get_action "safetyNet" "block_git_checkout_discard")
if [[ "$ACTION" != "off" ]]; then
  if echo "$COMMAND" | grep -qP 'git\s+checkout\s+--\s+\.|git\s+restore\s+--staged\s+\.|git\s+restore\s+\.'; then
    echo "⛔ [Sentinel Env-Safety] Bulk discard of changes detected"
    echo "  'git checkout -- .' or 'git restore .' discards ALL uncommitted changes."
    echo "  Specify individual files instead, or use 'git stash' to preserve changes."
    sentinel_stats_increment "blocks"
    [[ "$ACTION" == "block" ]] && exit 2
  fi
fi

# 12. Block destructive SQL (NEW in v1.5.0)
ACTION=$(sentinel_get_action "safetyNet" "block_destructive_sql")
if [[ "$ACTION" != "off" ]]; then
  if echo "$COMMAND" | grep -qiP 'DROP\s+(TABLE|DATABASE|SCHEMA|INDEX)\s|TRUNCATE\s+TABLE\s|DELETE\s+FROM\s+\w+\s*;?\s*$|ALTER\s+TABLE\s+\w+\s+DROP\s'; then
    MATCH=$(echo "$COMMAND" | grep -oiP 'DROP\s+(TABLE|DATABASE|SCHEMA|INDEX)\s+\w+|TRUNCATE\s+TABLE\s+\w+|DELETE\s+FROM\s+\w+' | head -1)
    echo "⛔ [Sentinel Env-Safety] Destructive SQL detected: $(sentinel_sanitize "$MATCH")"
    echo "  DROP TABLE/DATABASE/TRUNCATE permanently destroys data."
    echo "  Use Django migrations for schema changes."
    echo "  For data cleanup, use management commands with --dry-run first."
    sentinel_stats_increment "blocks"
    [[ "$ACTION" == "block" ]] && exit 2
  fi
fi

# 13. Block protected branch deletion (NEW in v1.5.0)
ACTION=$(sentinel_get_action "safetyNet" "block_branch_delete_protected")
if [[ "$ACTION" != "off" ]]; then
  PROTECTED=$(_get_protected_branches)
  if echo "$COMMAND" | grep -qP "git\s+branch\s+(-[dD]|--delete)\s+(${PROTECTED})\b|git\s+push\s+\S+\s+:(${PROTECTED})\b"; then
    BRANCH_MATCH=$(echo "$COMMAND" | grep -oP "(${PROTECTED})" | head -1)
    echo "⛔ [Sentinel Env-Safety] Deletion of protected branch '${BRANCH_MATCH}' blocked"
    echo "  Protected branches: $(echo "$PROTECTED" | tr '|' ', ')"
    echo "  These branches should never be deleted."
    sentinel_stats_increment "blocks"
    [[ "$ACTION" == "block" ]] && exit 2
  fi
fi

sentinel_stats_increment "checks"
exit 0
