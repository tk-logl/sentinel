#!/bin/bash
# Sentinel PreToolUse Hook: Secret Scanner (BLOCKING)
# Blocks hardcoded secrets/credentials in source code.
# Exit 2 = DENY | Exit 0 = ALLOW

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/_common.sh"
sentinel_require_jq "secret-scan"
sentinel_require_pcre "secret-scan"
sentinel_check_enabled "secret_scan"

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

if [[ "$TOOL_NAME" != "Edit" && "$TOOL_NAME" != "Write" ]]; then
  exit 0
fi

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[[ -z "$FILE_PATH" ]] && exit 0

# Skip non-source files
EXT="${FILE_PATH##*.}"
case "$EXT" in
  py|ts|tsx|js|jsx|go|rs|java|c|cpp|env|yml|yaml|json|toml|ini|cfg) ;;
  *) exit 0 ;;
esac

# Skip test files with known fake credentials
if echo "$FILE_PATH" | grep -qP '(\.test\.|\.spec\.|/tests/|/test_|_test\.|/fixtures/|/mocks/)'; then
  exit 0
fi

# Get content
if [[ "$TOOL_NAME" == "Write" ]]; then
  CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // empty' 2>/dev/null)
elif [[ "$TOOL_NAME" == "Edit" ]]; then
  CONTENT=$(echo "$INPUT" | jq -r '.tool_input.new_string // empty' 2>/dev/null)
fi

[[ -z "$CONTENT" ]] && exit 0

VIOLATIONS=""

# OpenAI / Stripe secret keys
if echo "$CONTENT" | grep -qP 'sk-[a-zA-Z0-9-]{20,}'; then
  # Exclude obvious fake keys
  if ! echo "$CONTENT" | grep -qP 'sk-(test|fake|dummy|example|placeholder|xxx)'; then
    VIOLATIONS="${VIOLATIONS}  - OpenAI/Stripe secret key pattern (sk-...)\n"
  fi
fi

# GitHub tokens
if echo "$CONTENT" | grep -qP '(ghp_|gho_|github_pat_)[a-zA-Z0-9]{20,}'; then
  VIOLATIONS="${VIOLATIONS}  - GitHub token pattern (ghp_/gho_/github_pat_)\n"
fi

# Slack tokens
if echo "$CONTENT" | grep -qP '(xoxb-|xoxp-|xoxs-)[a-zA-Z0-9-]{20,}'; then
  VIOLATIONS="${VIOLATIONS}  - Slack token pattern (xoxb-/xoxp-)\n"
fi

# AWS access key
if echo "$CONTENT" | grep -qP 'AKIA[A-Z0-9]{16}'; then
  VIOLATIONS="${VIOLATIONS}  - AWS access key pattern (AKIA...)\n"
fi

# Generic secret patterns (API_KEY="value", SECRET="value", etc.)
if echo "$CONTENT" | grep -qP '(API_KEY|SECRET_KEY|ACCESS_TOKEN|AUTH_TOKEN|PRIVATE_KEY|PASSWORD|DB_PASSWORD)\s*=\s*["\x27][^"\x27]{8,}["\x27]'; then
  # Exclude env var references and placeholder values
  if ! echo "$CONTENT" | grep -qP '(os\.environ|process\.env|getenv|config\(|settings\.|ENV\[|placeholder|example|changeme|your[-_]?\w+[-_]?here)'; then
    VIOLATIONS="${VIOLATIONS}  - Hardcoded credential assignment (use environment variables)\n"
  fi
fi

# JWT tokens (eyJ prefix = base64 of {"alg":...)
if echo "$CONTENT" | grep -qP 'eyJ[a-zA-Z0-9_-]{10,}\.[a-zA-Z0-9_-]{10,}\.[a-zA-Z0-9_-]{10,}'; then
  if ! echo "$CONTENT" | grep -qP '(test|fake|mock|example|sample).*eyJ|eyJ.*(test|fake|mock)'; then
    VIOLATIONS="${VIOLATIONS}  - JWT token embedded in source code\n"
  fi
fi

# Google API keys
if echo "$CONTENT" | grep -qP 'AIza[a-zA-Z0-9_-]{35}'; then
  VIOLATIONS="${VIOLATIONS}  - Google API key pattern (AIza...)\n"
fi

# Private keys
if echo "$CONTENT" | grep -qP 'BEGIN (RSA |EC |DSA |OPENSSH )?PRIVATE KEY'; then
  VIOLATIONS="${VIOLATIONS}  - Private key embedded in source code\n"
fi

# Database connection strings with passwords
if echo "$CONTENT" | grep -qP '(postgres|mysql|mongodb|redis)://\w+:[^@]{8,}@'; then
  if ! echo "$CONTENT" | grep -qP '(localhost|127\.0\.0\.1|example\.com|placeholder|changeme)'; then
    VIOLATIONS="${VIOLATIONS}  - Database connection string with embedded password\n"
  fi
fi

if [[ -n "$VIOLATIONS" ]]; then
  echo "⛔ [Sentinel Secret-Scan] Hardcoded secrets detected in: $(basename "$FILE_PATH")"
  echo ""
  echo -e "Found:\n${VIOLATIONS}"
  echo ""
  echo "Never hardcode credentials. Use:"
  echo "  Python: os.environ.get('API_KEY') or django-environ"
  echo "  Node:   process.env.API_KEY or dotenv"
  echo "  Go:     os.Getenv(\"API_KEY\")"
  echo "→ Move secrets to environment variables, then retry."
  exit 2
fi

exit 0
