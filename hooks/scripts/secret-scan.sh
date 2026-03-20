#!/bin/bash
# Sentinel PreToolUse Hook: Secret Scanner (BLOCKING)
# Blocks hardcoded secrets/credentials in source code.
# v1.5.0: Per-item configurable actions (block/warn/off).
# Exit 2 = DENY | Exit 0 = ALLOW

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/_common.sh"
sentinel_require_jq "secret-scan" "blocking"
sentinel_require_pcre "secret-scan" "blocking"
sentinel_compat_check "secret_scan"

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

if [[ "$TOOL_NAME" != "Edit" && "$TOOL_NAME" != "Write" ]]; then
  exit 0
fi

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[[ -z "$FILE_PATH" ]] && exit 0

# Secret scan checks BOTH source code AND config files
EXT="${FILE_PATH##*.}"
case "$EXT" in
  py|ts|tsx|js|jsx|go|rs|java|c|cpp|svelte|vue|env|yml|yaml|json|toml|ini|cfg) ;;
  *) exit 0 ;;
esac

if sentinel_should_skip "$FILE_PATH"; then exit 0; fi

# Get content
if [[ "$TOOL_NAME" == "Write" ]]; then
  CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // empty' 2>/dev/null)
elif [[ "$TOOL_NAME" == "Edit" ]]; then
  CONTENT=$(echo "$INPUT" | jq -r '.tool_input.new_string // empty' 2>/dev/null)
fi

[[ -z "$CONTENT" ]] && exit 0

BLOCKS=""
WARNINGS=""

# 1. OpenAI / Stripe secret keys
ACTION=$(sentinel_get_action "security" "block_openai_stripe_keys")
if [[ "$ACTION" != "off" ]]; then
  if echo "$CONTENT" | grep -qP 'sk-[a-zA-Z0-9-]{20,}'; then
    if ! echo "$CONTENT" | grep -qP 'sk-(test|fake|dummy|example|placeholder|xxx)'; then
      MSG="  - OpenAI/Stripe secret key pattern (sk-...)\n"
      [[ "$ACTION" == "block" ]] && BLOCKS="${BLOCKS}${MSG}" || WARNINGS="${WARNINGS}${MSG}"
    fi
  fi
fi

# 2. GitHub tokens
ACTION=$(sentinel_get_action "security" "block_github_tokens")
if [[ "$ACTION" != "off" ]]; then
  if echo "$CONTENT" | grep -qP '(ghp_|gho_|github_pat_)[a-zA-Z0-9]{20,}'; then
    MSG="  - GitHub token pattern (ghp_/gho_/github_pat_)\n"
    [[ "$ACTION" == "block" ]] && BLOCKS="${BLOCKS}${MSG}" || WARNINGS="${WARNINGS}${MSG}"
  fi
fi

# 3. Slack tokens
ACTION=$(sentinel_get_action "security" "block_slack_tokens")
if [[ "$ACTION" != "off" ]]; then
  if echo "$CONTENT" | grep -qP '(xoxb-|xoxp-|xoxs-)[a-zA-Z0-9-]{20,}'; then
    MSG="  - Slack token pattern (xoxb-/xoxp-)\n"
    [[ "$ACTION" == "block" ]] && BLOCKS="${BLOCKS}${MSG}" || WARNINGS="${WARNINGS}${MSG}"
  fi
fi

# 4. AWS access keys
ACTION=$(sentinel_get_action "security" "block_aws_keys")
if [[ "$ACTION" != "off" ]]; then
  if echo "$CONTENT" | grep -qP 'AKIA[A-Z0-9]{16}'; then
    MSG="  - AWS access key pattern (AKIA...)\n"
    [[ "$ACTION" == "block" ]] && BLOCKS="${BLOCKS}${MSG}" || WARNINGS="${WARNINGS}${MSG}"
  fi
fi

# 5. Generic credentials (API_KEY=, SECRET=, PASSWORD=)
ACTION=$(sentinel_get_action "security" "block_generic_credentials")
if [[ "$ACTION" != "off" ]]; then
  if echo "$CONTENT" | grep -qP '(API_KEY|SECRET_KEY|ACCESS_TOKEN|AUTH_TOKEN|PRIVATE_KEY|PASSWORD|DB_PASSWORD)\s*=\s*["\x27][^"\x27]{8,}["\x27]'; then
    if ! echo "$CONTENT" | grep -qP '(os\.environ|process\.env|getenv|config\(|settings\.|ENV\[|placeholder|example|changeme|your[-_]?\w+[-_]?here)'; then
      MSG="  - Hardcoded credential assignment (use environment variables)\n"
      [[ "$ACTION" == "block" ]] && BLOCKS="${BLOCKS}${MSG}" || WARNINGS="${WARNINGS}${MSG}"
    fi
  fi
fi

# 6. JWT tokens
ACTION=$(sentinel_get_action "security" "block_jwt_tokens")
if [[ "$ACTION" != "off" ]]; then
  if echo "$CONTENT" | grep -qP 'eyJ[a-zA-Z0-9_-]{10,}\.[a-zA-Z0-9_-]{10,}\.[a-zA-Z0-9_-]{10,}'; then
    if ! echo "$CONTENT" | grep -qP '(test|fake|mock|example|sample).*eyJ|eyJ.*(test|fake|mock)'; then
      MSG="  - JWT token embedded in source code\n"
      [[ "$ACTION" == "block" ]] && BLOCKS="${BLOCKS}${MSG}" || WARNINGS="${WARNINGS}${MSG}"
    fi
  fi
fi

# 7. Google API keys
ACTION=$(sentinel_get_action "security" "block_google_api_keys")
if [[ "$ACTION" != "off" ]]; then
  if echo "$CONTENT" | grep -qP 'AIza[a-zA-Z0-9_-]{35}'; then
    MSG="  - Google API key pattern (AIza...)\n"
    [[ "$ACTION" == "block" ]] && BLOCKS="${BLOCKS}${MSG}" || WARNINGS="${WARNINGS}${MSG}"
  fi
fi

# 8. Private keys
ACTION=$(sentinel_get_action "security" "block_private_keys")
if [[ "$ACTION" != "off" ]]; then
  if echo "$CONTENT" | grep -qP 'BEGIN (RSA |EC |DSA |OPENSSH )?PRIVATE KEY'; then
    MSG="  - Private key embedded in source code\n"
    [[ "$ACTION" == "block" ]] && BLOCKS="${BLOCKS}${MSG}" || WARNINGS="${WARNINGS}${MSG}"
  fi
fi

# 9. Database connection strings
ACTION=$(sentinel_get_action "security" "block_db_connection_strings")
if [[ "$ACTION" != "off" ]]; then
  if echo "$CONTENT" | grep -qP '(postgres|mysql|mongodb|redis)://\w+:[^@]{8,}@'; then
    if ! echo "$CONTENT" | grep -qP '(localhost|127\.0\.0\.1|example\.com|placeholder|changeme)'; then
      MSG="  - Database connection string with embedded password\n"
      [[ "$ACTION" == "block" ]] && BLOCKS="${BLOCKS}${MSG}" || WARNINGS="${WARNINGS}${MSG}"
    fi
  fi
fi

# --- Output ---
if [[ -n "$BLOCKS" ]]; then
  {
    echo "⛔ [Sentinel Secret-Scan] Hardcoded secrets detected in: $(basename "$FILE_PATH")"
    echo ""
    echo -e "Found:\n${BLOCKS}"
    if [[ -n "$WARNINGS" ]]; then
      echo -e "Warnings:\n${WARNINGS}"
    fi
    echo ""
    echo "Never hardcode credentials. Use:"
    echo "  Python: os.environ.get('API_KEY') or django-environ"
    echo "  Node:   process.env.API_KEY or dotenv"
    echo "  Go:     os.Getenv(\"API_KEY\")"
    echo "→ Move secrets to environment variables, then retry."
  } >&2
  sentinel_stats_increment "blocks"
  sentinel_stats_increment "pattern_hardcoded_secret"
  exit 2
fi

if [[ -n "$WARNINGS" ]]; then
  echo "⚠️ [Sentinel Secret-Scan] Credential warnings in: $(basename "$FILE_PATH")"
  echo ""
  echo -e "Warnings:\n${WARNINGS}"
  sentinel_stats_increment "warnings"
fi

sentinel_stats_increment "checks"
exit 0
