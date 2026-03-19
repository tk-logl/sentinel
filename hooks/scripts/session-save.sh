#!/bin/bash
# Sentinel SessionEnd Hook: Session State Save (STATE SAVE)
# Saves state on session end. Uses shared logic with state-preserve.
# Exit 0 = ALLOW (always)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/_common.sh"
source "${SCRIPT_DIR}/_state-common.sh"

OUTPUT=$(sentinel_save_state "session-end" "false")

if [[ -n "$OUTPUT" ]]; then
  echo "💾 [Sentinel Session-Save] State saved for next session"
fi

exit 0
