#!/bin/bash
# Sentinel Cross-Platform Compatibility Layer
# Source this at the top of every hook script.
# Provides: PCRE grep compatibility, jq check, platform detection.

# --- Platform detection ---
SENTINEL_OS="$(uname -s)"

# --- PCRE grep compatibility ---
# All sentinel hooks use grep -P (Perl regex).
# macOS ships BSD grep which does NOT support -P.
# Windows requires WSL or Git Bash for bash scripts.
#
# Strategy:
#   1. Test if system grep supports -P (Linux, WSL)
#   2. Try ggrep (macOS: brew install grep)
#   3. Set SENTINEL_NO_PCRE=1 if neither available

SENTINEL_NO_PCRE=0
if ! echo "test" | command grep -P "test" &>/dev/null 2>&1; then
  if command -v ggrep &>/dev/null && echo "test" | ggrep -P "test" &>/dev/null 2>&1; then
    # macOS with Homebrew GNU grep — override grep for this session
    grep() { command ggrep "$@"; }
  else
    SENTINEL_NO_PCRE=1
  fi
fi

# --- jq availability ---
SENTINEL_NO_JQ=0
if ! command -v jq &>/dev/null; then
  SENTINEL_NO_JQ=1
fi

# --- Guard functions ---
# Call these at the top of hooks that require PCRE or jq.
# If the tool is missing, the hook warns and exits 0 (safe — never blocks).

sentinel_require_pcre() {
  if [[ "$SENTINEL_NO_PCRE" == "1" ]]; then
    local hook_name="${1:-hook}"
    echo "⚠️ [Sentinel] GNU grep (PCRE) not available — ${hook_name} disabled."
    echo "  Linux: sudo apt install grep"
    echo "  macOS: brew install grep"
    echo "  Windows: use WSL or Git Bash"
    exit 0
  fi
}

sentinel_require_jq() {
  if [[ "$SENTINEL_NO_JQ" == "1" ]]; then
    local hook_name="${1:-hook}"
    echo "⚠️ [Sentinel] jq not found — ${hook_name} disabled."
    echo "  Linux: sudo apt install jq"
    echo "  macOS: brew install jq"
    echo "  Windows: choco install jq (or scoop install jq)"
    exit 0
  fi
}

# --- Enforcement toggle check ---
# Reads config/sentinel.json (or .sentinel/config.json) enforcement toggles.
# Usage: sentinel_check_enabled "hook_name"
# If enforcement.$hook_name is false, exits 0 (skip silently).
# If config not found or jq missing, defaults to ENABLED (safe default).

sentinel_check_enabled() {
  local hook_name="${1:-}"
  [[ -z "$hook_name" ]] && return 0

  # Skip check if jq not available — default to enabled
  [[ "$SENTINEL_NO_JQ" == "1" ]] && return 0

  # Find config: project-level first, then plugin default
  local config_file=""
  local project_root
  project_root=$(git rev-parse --show-toplevel 2>/dev/null)

  if [[ -n "$project_root" && -f "${project_root}/.sentinel/config.json" ]]; then
    config_file="${project_root}/.sentinel/config.json"
  elif [[ -n "$SENTINEL_PLUGIN_ROOT" && -f "${SENTINEL_PLUGIN_ROOT}/config/sentinel.json" ]]; then
    config_file="${SENTINEL_PLUGIN_ROOT}/config/sentinel.json"
  elif [[ -n "$SCRIPT_DIR" && -f "${SCRIPT_DIR}/../../config/sentinel.json" ]]; then
    config_file="${SCRIPT_DIR}/../../config/sentinel.json"
  fi

  # No config found — default to enabled
  [[ -z "$config_file" ]] && return 0

  # Read the toggle value
  # NOTE: jq's // operator treats false as falsy, so "false // true" returns true.
  # Must check explicitly whether the key exists and equals false.
  local enabled
  enabled=$(jq -r "if .enforcement.${hook_name} == false then \"disabled\" else \"enabled\" end" "$config_file" 2>/dev/null)

  if [[ "$enabled" == "disabled" ]]; then
    exit 0
  fi

  return 0
}

# --- Utility: get script directory ---
# Usage: source "${SCRIPT_DIR}/_common.sh"
# The calling script should set SCRIPT_DIR before sourcing.
