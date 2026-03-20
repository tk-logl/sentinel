#!/bin/bash
# Sentinel Cross-Platform Compatibility Layer
# Source this at the top of every hook script.
# Provides: PCRE grep compatibility, jq check, platform detection.

# --- Platform detection ---
SENTINEL_OS="$(uname -s)"
export SENTINEL_OS

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
    local severity="${2:-warning}"  # "blocking" or "warning"
    if [[ "$severity" == "blocking" ]]; then
      {
        echo "⛔ [Sentinel] GNU grep (PCRE) not available — ${hook_name} CANNOT RUN."
        echo "  This is a BLOCKING hook. Install PCRE grep to enable protection."
        echo "  Linux: sudo apt install grep"
        echo "  macOS: brew install grep"
        echo "  Windows: use WSL or Git Bash"
      } >&2
      exit 2
    else
      echo "⚠️ [Sentinel] GNU grep (PCRE) not available — ${hook_name} disabled."
      echo "  Linux: sudo apt install grep | macOS: brew install grep"
      exit 0
    fi
  fi
}

sentinel_require_jq() {
  if [[ "$SENTINEL_NO_JQ" == "1" ]]; then
    local hook_name="${1:-hook}"
    local severity="${2:-warning}"  # "blocking" or "warning"
    if [[ "$severity" == "blocking" ]]; then
      {
        echo "⛔ [Sentinel] jq not found — ${hook_name} CANNOT RUN."
        echo "  This is a BLOCKING hook. Install jq to enable protection."
        echo "  Linux: sudo apt install jq"
        echo "  macOS: brew install jq"
        echo "  Windows: choco install jq (or scoop install jq)"
      } >&2
      exit 2
    else
      echo "⚠️ [Sentinel] jq not found — ${hook_name} disabled."
      echo "  Linux: sudo apt install jq | macOS: brew install jq"
      exit 0
    fi
  fi
}

# ─── Denial Output Helper ───
# Routes violation messages to stderr (for Claude Code denial visibility) or stdout.
# When action=block: outputs to stderr so Claude Code displays the denial reason,
#   increments "blocks" counter, and exits 2 (DENY).
# When action=warn: outputs to stdout as informational context,
#   increments "warnings" counter, and returns (continues execution).
# Usage: sentinel_report "$ACTION" "⛔ Title" "  Detail line 1" "  Detail line 2"
sentinel_report() {
  local action="$1"
  shift
  if [[ "$action" == "block" ]]; then
    printf '%s\n' "$@" >&2
    sentinel_stats_increment "blocks"
    exit 2
  else
    printf '%s\n' "$@"
    sentinel_stats_increment "warnings"
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

# --- Output sanitization ---
# Strip ANSI escape sequences and control characters from user-controlled strings
# before echoing them. Prevents terminal escape injection.
# Usage: echo "$(sentinel_sanitize "$UNTRUSTED_STRING")"
sentinel_sanitize() {
  printf '%s' "$1" | tr -d '\033' | sed 's/[[:cntrl:]]//g'
}

# --- Utility: get script directory ---
# Usage: source "${SCRIPT_DIR}/_common.sh"
# The calling script should set SCRIPT_DIR before sourcing.

# --- i18n Message System ---
# Auto-detects locale from config or system LANG.
# Usage: sentinel_msg "key" → prints localized message

SENTINEL_LANG=""

sentinel_detect_lang() {
  [[ -n "$SENTINEL_LANG" ]] && return 0

  # 1. Check project config
  local project_root
  project_root=$(git rev-parse --show-toplevel 2>/dev/null)
  if [[ -n "$project_root" && -f "${project_root}/.sentinel/config.json" ]] && [[ "$SENTINEL_NO_JQ" == "0" ]]; then
    local cfg_lang
    cfg_lang=$(jq -r '.language // "auto"' "${project_root}/.sentinel/config.json" 2>/dev/null)
    if [[ "$cfg_lang" != "auto" && -n "$cfg_lang" ]]; then
      SENTINEL_LANG="$cfg_lang"
      return 0
    fi
  fi

  # 2. Auto-detect from system locale
  local sys_lang="${LANG:-${LC_ALL:-en}}"
  case "$sys_lang" in
    ko*) SENTINEL_LANG="ko" ;;
    ja*) SENTINEL_LANG="ja" ;;
    zh*) SENTINEL_LANG="zh" ;;
    es*) SENTINEL_LANG="es" ;;
    *)   SENTINEL_LANG="en" ;;
  esac
}

sentinel_msg() {
  local key="$1"
  sentinel_detect_lang

  case "$key" in
    "blocked")
      case "$SENTINEL_LANG" in
        ko) echo "차단됨" ;;
        ja) echo "ブロック" ;;
        *) echo "BLOCKED" ;;
      esac ;;
    "warning")
      case "$SENTINEL_LANG" in
        ko) echo "경고" ;;
        ja) echo "警告" ;;
        *) echo "WARNING" ;;
      esac ;;
    "dummy_detected")
      case "$SENTINEL_LANG" in
        ko) echo "더미/플레이스홀더 코드 감지" ;;
        ja) echo "ダミー/プレースホルダーコード検出" ;;
        *) echo "Placeholder/stub code detected" ;;
      esac ;;
    "secret_detected")
      case "$SENTINEL_LANG" in
        ko) echo "하드코딩된 시크릿 감지" ;;
        ja) echo "ハードコードされたシークレットを検出" ;;
        *) echo "Hardcoded secrets detected" ;;
      esac ;;
    "scope_reduction")
      case "$SENTINEL_LANG" in
        ko) echo "범위 축소 표현 감지 — 완전히 구현하거나 구현하지 마세요" ;;
        ja) echo "スコープ縮小を検出 — 完全に実装するか、実装しないでください" ;;
        *) echo "Scope reduction detected — implement completely or not at all" ;;
      esac ;;
    "surgical_rule")
      case "$SENTINEL_LANG" in
        ko) echo "최소 diff 규칙: 가능한 가장 작은 변경. 추가 후 교체. 삭제 전 검색." ;;
        ja) echo "最小差分ルール: 最小限の変更。追加してから置換。削除前に検索。" ;;
        *) echo "Surgical Change Rule: smallest diff possible. Add before replace. Grep before delete." ;;
      esac ;;
    "env_unsafe")
      case "$SENTINEL_LANG" in
        ko) echo "위험한 시스템 명령 차단" ;;
        ja) echo "危険なシステムコマンドをブロック" ;;
        *) echo "Dangerous system command blocked" ;;
      esac ;;
    "checklist_missing")
      case "$SENTINEL_LANG" in
        ko) echo "사전구현 체크리스트(.sentinel/current-task.json)가 없습니다" ;;
        ja) echo "事前実装チェックリスト(.sentinel/current-task.json)がありません" ;;
        *) echo ".sentinel/current-task.json not found — create pre-implementation checklist" ;;
      esac ;;
    "completion_check")
      case "$SENTINEL_LANG" in
        ko) echo "완료 전 검증 — 아래 항목을 확인하세요" ;;
        ja) echo "完了前の検証 — 以下の項目を確認してください" ;;
        *) echo "Completion verification — review items below" ;;
      esac ;;
    "no_issues")
      case "$SENTINEL_LANG" in
        ko) echo "자동 검사에서 문제가 발견되지 않았습니다" ;;
        ja) echo "自動チェックで問題は検出されませんでした" ;;
        *) echo "No issues detected by automated checks" ;;
      esac ;;
    "stats_header")
      case "$SENTINEL_LANG" in
        ko) echo "세션 품질 리포트" ;;
        ja) echo "セッション品質レポート" ;;
        *) echo "Session Quality Report" ;;
      esac ;;
    *)
      echo "$key" ;;
  esac
}

# --- Usage Statistics Tracking ---
# Tracks hook activations in .sentinel/stats.json
# Usage: sentinel_stats_increment "checks" | "blocks" | "warnings" | "pattern_NAME"

sentinel_stats_increment() {
  local counter="$1"
  [[ -z "$counter" ]] && return 0
  [[ "$SENTINEL_NO_JQ" == "1" ]] && return 0

  local project_root
  project_root=$(git rev-parse --show-toplevel 2>/dev/null)
  [[ -z "$project_root" ]] && return 0

  local stats_file="${project_root}/.sentinel/stats.json"
  mkdir -p "${project_root}/.sentinel"

  # Initialize if missing
  if [[ ! -f "$stats_file" ]]; then
    cat > "$stats_file" << 'INIT_EOF'
{"session_start":"","checks":0,"blocks":0,"warnings":0,"patterns":{}}
INIT_EOF
  fi

  # Set session_start if empty
  local cur_start
  cur_start=$(jq -r '.session_start // ""' "$stats_file" 2>/dev/null)
  if [[ -z "$cur_start" ]]; then
    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    jq --arg ts "$ts" '.session_start = $ts' "$stats_file" > "${stats_file}.tmp" 2>/dev/null && mv "${stats_file}.tmp" "$stats_file"
  fi

  # Increment counter
  if [[ "$counter" == pattern_* ]]; then
    local pname="${counter#pattern_}"
    jq --arg p "$pname" '.patterns[$p] = ((.patterns[$p] // 0) + 1)' "$stats_file" > "${stats_file}.tmp" 2>/dev/null && mv "${stats_file}.tmp" "$stats_file"
  else
    jq --arg k "$counter" '.[$k] = ((.[$k] // 0) + 1)' "$stats_file" > "${stats_file}.tmp" 2>/dev/null && mv "${stats_file}.tmp" "$stats_file"
  fi
}

sentinel_stats_report() {
  [[ "$SENTINEL_NO_JQ" == "1" ]] && return 0

  local project_root
  project_root=$(git rev-parse --show-toplevel 2>/dev/null)
  [[ -z "$project_root" ]] && return 0

  local stats_file="${project_root}/.sentinel/stats.json"
  [[ ! -f "$stats_file" ]] && return 0

  local checks blocks warnings
  checks=$(jq -r '.checks // 0' "$stats_file" 2>/dev/null)
  blocks=$(jq -r '.blocks // 0' "$stats_file" 2>/dev/null)
  warnings=$(jq -r '.warnings // 0' "$stats_file" 2>/dev/null)

  # Only show report if 3+ checks happened
  local total=$((checks + blocks + warnings))
  [[ $total -lt 3 ]] && return 0

  local start_time
  start_time=$(jq -r '.session_start // ""' "$stats_file" 2>/dev/null)

  # Calculate quality score (100 - penalty for blocks)
  local score=100
  if [[ $checks -gt 0 ]]; then
    local block_rate=$(( (blocks * 100) / (checks + blocks + warnings) ))
    score=$((100 - block_rate))
    [[ $score -lt 0 ]] && score=0
  fi

  # Grade
  local grade="A+"
  if [[ $score -lt 50 ]]; then grade="F"
  elif [[ $score -lt 60 ]]; then grade="D"
  elif [[ $score -lt 70 ]]; then grade="C"
  elif [[ $score -lt 80 ]]; then grade="B"
  elif [[ $score -lt 90 ]]; then grade="A"
  fi

  echo ""
  echo "📊 [Sentinel] $(sentinel_msg stats_header)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Session: ${start_time:-unknown}"
  echo "  ✅ Checks passed: ${checks}"
  echo "  ⛔ Blocks (prevented): ${blocks}"
  echo "  ⚠️  Warnings issued: ${warnings}"
  echo "  📈 Quality Score: ${score}/100 (${grade})"

  # Top patterns detected
  local top_patterns
  top_patterns=$(jq -r '.patterns | to_entries | sort_by(-.value) | .[:5][] | "    \(.key): \(.value)x"' "$stats_file" 2>/dev/null)
  if [[ -n "$top_patterns" ]]; then
    echo ""
    echo "  Top patterns caught:"
    echo "$top_patterns"
  fi

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ─── Config Value Reader (cached) ───
# Reads arbitrary values from sentinel config JSON.
# Usage: val=$(sentinel_read_config '.taskList.enabled' 'true')
_sentinel_config_cache=""
sentinel_read_config() {
  local jq_expr="${1:-.}"
  local default_val="${2:-}"
  [[ "$SENTINEL_NO_JQ" == "1" ]] && { echo "$default_val"; return 0; }

  if [[ -z "$_sentinel_config_cache" ]]; then
    local project_root
    project_root=$(git rev-parse --show-toplevel 2>/dev/null)
    if [[ -n "$project_root" && -f "${project_root}/.sentinel/config.json" ]]; then
      _sentinel_config_cache="${project_root}/.sentinel/config.json"
    elif [[ -n "$SENTINEL_PLUGIN_ROOT" && -f "${SENTINEL_PLUGIN_ROOT}/config/sentinel.json" ]]; then
      _sentinel_config_cache="${SENTINEL_PLUGIN_ROOT}/config/sentinel.json"
    elif [[ -n "$SCRIPT_DIR" && -f "${SCRIPT_DIR}/../../config/sentinel.json" ]]; then
      _sentinel_config_cache="${SCRIPT_DIR}/../../config/sentinel.json"
    else
      echo "$default_val"
      return 0
    fi
  fi

  local result
  result=$(jq -r "${jq_expr} // empty" "$_sentinel_config_cache" 2>/dev/null)
  echo "${result:-$default_val}"
}

# ─── Source File Detection ───
# Checks if a file path is a source code file (by extension from config).
# Usage: if sentinel_is_source_file "$FILE_PATH"; then ...
sentinel_is_source_file() {
  local file_path="$1"
  [[ -z "$file_path" ]] && return 1
  local ext="${file_path##*.}"
  [[ "$ext" == "$file_path" ]] && return 1  # no extension

  local extensions
  extensions=$(sentinel_read_config \
    'if .source_extensions then (.source_extensions | join(",")) else empty end' \
    "py,ts,tsx,js,jsx,go,rs,java,c,cpp,svelte,vue")

  [[ ",$extensions," == *",$ext,"* ]] && return 0
  return 1
}

# ─── Skip Pattern Detection ───
# Checks if a file should be skipped (test files, config dirs, fixtures, etc.).
# Reads skip_patterns from config for project-specific exclusions.
# Usage: if sentinel_should_skip "$FILE_PATH"; then exit 0; fi
sentinel_should_skip() {
  local file_path="$1"
  [[ -z "$file_path" ]] && return 1

  # Built-in skip dirs (always applied)
  # Prepend / so patterns match both "src/.claude/x" and ".claude/x"
  local check_path="/${file_path}"
  case "$check_path" in
    */.sentinel/*|*/.claude/*|*/.omc/*|*/.github/*) return 0 ;;
    */node_modules/*|*/__pycache__/*) return 0 ;;
    */fixtures/*|*/mocks/*) return 0 ;;
  esac

  # Test file detection
  if echo "$file_path" | grep -qP '(\.test\.|\.spec\.|/tests/|/test_|_test\.)'; then
    return 0
  fi

  # Config-driven skip patterns (glob-style, converted to grep patterns)
  local skip_json
  skip_json=$(sentinel_read_config '.skip_patterns' '')
  if [[ -n "$skip_json" && "$skip_json" != "null" ]]; then
    local patterns
    patterns=$(echo "$skip_json" | jq -r '.[]' 2>/dev/null)
    if [[ -n "$patterns" ]]; then
      while IFS= read -r pat; do
        [[ -z "$pat" ]] && continue
        # Convert glob to grep: placeholder for **/, escape dots, restore, convert * and ?
        local regex
        regex=$(printf '%s' "$pat" | sed 's|\*\*/|__DSTAR__|g; s|\.|\\.|g; s|__DSTAR__|.*/|g; s|\*|[^/]*|g; s|\?|.|g')
        if echo "$file_path" | grep -qE "$regex" 2>/dev/null; then
          return 0
        fi
      done <<< "$patterns"
    fi
  fi

  return 1
}


# ─── Per-Item Action Resolution (v1.5.0) ───
# 3-tier resolution: project override → mode defaults → "standard" fallback
# Returns: "block" | "warn" | "on" | "off"
# Usage: action=$(sentinel_get_action "codeQuality" "block_standalone_pass")
#
# Resolution order:
#   1. Project config .sentinel/config.json → categories.<category>.<item_key>
#   2. Mode defaults (from config "mode" field) → mode-defaults.json lookup
#   3. Ultimate fallback: "standard" mode from mode-defaults.json
#   4. If nothing found: "block" (safe default)

_sentinel_mode_cache=""
_sentinel_project_config_cache=""
_sentinel_defaults_file_cache=""

sentinel_get_action() {
  local category="$1" item_key="$2" fallback="${3:-block}"
  [[ -z "$category" || -z "$item_key" ]] && echo "off" && return 0
  [[ "$SENTINEL_NO_JQ" == "1" ]] && echo "$fallback" && return 0  # safe default when jq missing

  # --- Locate project config (cached) ---
  if [[ -z "$_sentinel_project_config_cache" ]]; then
    local project_root
    project_root=$(git rev-parse --show-toplevel 2>/dev/null)
    if [[ -n "$project_root" && -f "${project_root}/.sentinel/config.json" ]]; then
      _sentinel_project_config_cache="${project_root}/.sentinel/config.json"
    else
      _sentinel_project_config_cache="__none__"
    fi
  fi

  # --- Locate mode-defaults.json (cached) ---
  if [[ -z "$_sentinel_defaults_file_cache" ]]; then
    if [[ -n "$SENTINEL_PLUGIN_ROOT" && -f "${SENTINEL_PLUGIN_ROOT}/config/mode-defaults.json" ]]; then
      _sentinel_defaults_file_cache="${SENTINEL_PLUGIN_ROOT}/config/mode-defaults.json"
    elif [[ -n "$SCRIPT_DIR" && -f "${SCRIPT_DIR}/../../config/mode-defaults.json" ]]; then
      _sentinel_defaults_file_cache="${SCRIPT_DIR}/../../config/mode-defaults.json"
    else
      _sentinel_defaults_file_cache="__none__"
    fi
  fi

  # --- Tier 1: Project config per-item override ---
  if [[ "$_sentinel_project_config_cache" != "__none__" ]]; then
    local override
    override=$(jq -r ".categories.${category}.${item_key} // empty" "$_sentinel_project_config_cache" 2>/dev/null)
    if [[ -n "$override" && "$override" != "null" ]]; then
      echo "$override"
      return 0
    fi
  fi

  # --- Determine mode (cached) ---
  # If project has no .mode and no .categories in config, it's a legacy (v1.4.0) config.
  # Legacy configs don't use mode-defaults.json → fallback to "block" (all checks active).
  if [[ -z "$_sentinel_mode_cache" ]]; then
    _sentinel_mode_cache="__legacy__"
    if [[ "$_sentinel_project_config_cache" != "__none__" ]]; then
      local cfg_mode has_cats
      cfg_mode=$(jq -r '.mode // empty' "$_sentinel_project_config_cache" 2>/dev/null)
      has_cats=$(jq -r 'if .categories then "yes" else "no" end' "$_sentinel_project_config_cache" 2>/dev/null)
      if [[ -n "$cfg_mode" && "$cfg_mode" != "null" ]]; then
        _sentinel_mode_cache="$cfg_mode"
      elif [[ "$has_cats" == "yes" ]]; then
        _sentinel_mode_cache="standard"
      fi
      # else: stays "__legacy__" — won't consult mode-defaults.json
    fi
  fi

  # --- Tier 2: Mode defaults lookup (only for v1.5.0+ configs) ---
  if [[ "$_sentinel_mode_cache" != "__legacy__" && "$_sentinel_defaults_file_cache" != "__none__" ]]; then
    local default_action
    default_action=$(jq -r ".${_sentinel_mode_cache}.${category}.${item_key} // empty" "$_sentinel_defaults_file_cache" 2>/dev/null)
    if [[ -n "$default_action" && "$default_action" != "null" ]]; then
      echo "$default_action"
      return 0
    fi
  fi

  # --- Tier 3: Fallback to "standard" if current mode didn't have this item ---
  if [[ "$_sentinel_mode_cache" != "__legacy__" && "$_sentinel_mode_cache" != "standard" && "$_sentinel_defaults_file_cache" != "__none__" ]]; then
    local fallback
    fallback=$(jq -r ".standard.${category}.${item_key} // empty" "$_sentinel_defaults_file_cache" 2>/dev/null)
    if [[ -n "$fallback" && "$fallback" != "null" ]]; then
      echo "$fallback"
      return 0
    fi
  fi

  # --- Ultimate fallback: use caller-specified default ---
  echo "$fallback"
  return 0
}

# Helper: check if action is "block" or "warn" (active enforcement)
# Usage: if sentinel_is_active "codeQuality" "block_standalone_pass"; then ...
sentinel_is_active() {
  local action
  action=$(sentinel_get_action "$1" "$2")
  [[ "$action" == "block" || "$action" == "warn" ]]
}

# Helper: emit violation based on action level
# Usage: sentinel_emit_violation "codeQuality" "block_standalone_pass" "message" BLOCKS_VAR WARNINGS_VAR
# Appends to the appropriate variable (block violations vs warning violations)
sentinel_add_violation() {
  local category="$1" item_key="$2" message="$3"
  local action
  action=$(sentinel_get_action "$category" "$item_key")

  case "$action" in
    block)
      # Caller collects blocks — we echo a prefixed line for capture
      echo "BLOCK:${message}"
      ;;
    warn)
      echo "WARN:${message}"
      ;;
    *)
      # off or on — no violation
      echo ""
      ;;
  esac
}

# Backward compatibility bridge: old enforcement.* → new per-item system
# Call at hook start. If old config disables the hook AND no new-style categories exist,
# exits 0 (skip). If new-style categories exist, defers to sentinel_get_action().
# Usage: sentinel_compat_check "deny_dummy"
sentinel_compat_check() {
  local old_key="$1"
  [[ -z "$old_key" ]] && return 0
  [[ "$SENTINEL_NO_JQ" == "1" ]] && return 0

  local project_root
  project_root=$(git rev-parse --show-toplevel 2>/dev/null)

  # If project config has new-style categories or mode, use new system (skip old check)
  if [[ -n "$project_root" && -f "${project_root}/.sentinel/config.json" ]]; then
    local has_new
    has_new=$(jq -r 'if (.categories or .mode) then "yes" else "no" end' "${project_root}/.sentinel/config.json" 2>/dev/null)
    [[ "$has_new" == "yes" ]] && return 0
  fi

  # Fall back to old enforcement toggle check
  sentinel_check_enabled "$old_key"
}

# Reset cached values (useful for testing)
sentinel_reset_action_cache() {
  _sentinel_mode_cache=""
  _sentinel_project_config_cache=""
  _sentinel_defaults_file_cache=""
}

# ─── Task List Utilities ───
# Generic task-list management for markdown checklists.
# Supports auto-detection of task files and configurable ID patterns.

_SENTINEL_TASK_LIST=""

# Find the project's task list file.
# Search order: config > .sentinel/tasks.md > .claude/action-list.md > .claude/tasks.md > tasks.md
# Returns: absolute path to task file (stdout), or exits 1 if not found.
sentinel_find_task_list() {
  [[ -n "$_SENTINEL_TASK_LIST" ]] && { echo "$_SENTINEL_TASK_LIST"; return 0; }

  local project_root
  project_root=$(git rev-parse --show-toplevel 2>/dev/null)
  [[ -z "$project_root" ]] && return 1

  # Check config first
  local cfg_file
  cfg_file=$(sentinel_read_config '.taskList.file' "auto")
  if [[ "$cfg_file" != "auto" && -n "$cfg_file" && -f "${project_root}/${cfg_file}" ]]; then
    _SENTINEL_TASK_LIST="${project_root}/${cfg_file}"
    echo "$_SENTINEL_TASK_LIST"
    return 0
  fi

  # Auto-detect in priority order
  local candidates=(".sentinel/tasks.md" ".claude/action-list.md" ".claude/tasks.md" "tasks.md")
  for c in "${candidates[@]}"; do
    if [[ -f "${project_root}/${c}" ]]; then
      _SENTINEL_TASK_LIST="${project_root}/${c}"
      echo "$_SENTINEL_TASK_LIST"
      return 0
    fi
  done

  return 1
}

# Count task items by state.
# Usage: pending=$(sentinel_task_count "pending")
sentinel_task_count() {
  local state="${1:-pending}"
  local tf
  tf=$(sentinel_find_task_list) || { echo 0; return 0; }

  case "$state" in
    pending)    grep -cP '^\s*- \[ \]' "$tf" 2>/dev/null || echo 0 ;;
    inProgress) grep -cP '^\s*- \[~\]' "$tf" 2>/dev/null || echo 0 ;;
    done)       grep -cP '^\s*- \[x\]' "$tf" 2>/dev/null || echo 0 ;;
    *) echo 0 ;;
  esac
}

# List task items by state (line_number:content format).
# Usage: sentinel_task_list_items "pending" 10
sentinel_task_list_items() {
  local state="${1:-pending}" limit="${2:-999}"
  local tf
  tf=$(sentinel_find_task_list) || return 0

  case "$state" in
    pending)    grep -nP '^\s*- \[ \]' "$tf" 2>/dev/null | head -"$limit" ;;
    inProgress) grep -nP '^\s*- \[~\]' "$tf" 2>/dev/null | head -"$limit" ;;
    done)       grep -nP '^\s*- \[x\]' "$tf" 2>/dev/null | head -"$limit" ;;
  esac
}

# Mark a task item to a new state. Finds by item_id substring match.
# Usage: sentinel_task_mark "CRIT-2" "done" "fc06fca"
sentinel_task_mark() {
  local item_id="$1" new_state="$2" metadata="${3:-}"
  local tf
  tf=$(sentinel_find_task_list) || return 1
  [[ -z "$item_id" || -z "$new_state" ]] && return 1

  local marker
  case "$new_state" in
    done)       marker='[x]' ;;
    inProgress) marker='[~]' ;;
    pending)    marker='[ ]' ;;
    *) return 1 ;;
  esac

  # Find the first line containing this item_id
  local line_num
  line_num=$(grep -n "$item_id" "$tf" 2>/dev/null | head -1 | cut -d: -f1)
  [[ -z "$line_num" ]] && return 1

  # Replace the checkbox marker on that specific line
  sed -i "${line_num}s/- \[[ x~]\]/- ${marker}/" "$tf"

  # Append metadata (e.g., commit hash) if marking done
  if [[ "$new_state" == "done" && -n "$metadata" ]]; then
    local safe_meta
    safe_meta=$(printf '%s' "$metadata" | sed 's/[&/\]/\\&/g')
    local safe_id
    safe_id=$(printf '%s' "$item_id" | sed 's/[&/\]/\\&/g')
    # Try bold format (**ID**) first, then plain ID
    if sed -n "${line_num}p" "$tf" | grep -q "\*\*${item_id}\*\*" 2>/dev/null; then
      sed -i "${line_num}s/\*\*${safe_id}\*\*/\*\*${safe_id}\*\* ${safe_meta}/" "$tf"
    else
      sed -i "${line_num}s/${safe_id}/${safe_id} ${safe_meta}/" "$tf" 2>/dev/null || true
    fi
  fi

  return 0
}

# Extract task IDs from text (e.g., commit messages).
# Uses config idPattern or default [A-Z]+-[0-9]+.
# Usage: ids=$(sentinel_task_extract_ids "fix: CRIT-2 artifact crash")
sentinel_task_extract_ids() {
  local text="$1"
  [[ -z "$text" ]] && return 0

  local pattern
  pattern=$(sentinel_read_config '.taskList.idPattern' '[A-Z]+-[0-9]+')

  echo "$text" | grep -oP "$pattern" 2>/dev/null | sort -u
}

# Extract the full spec block for a task item.
# Returns from the item_id line until the next checklist item or section header.
# Usage: spec=$(sentinel_task_get_spec "CRIT-2")
sentinel_task_get_spec() {
  local item_id="$1"
  local tf
  tf=$(sentinel_find_task_list) || return 1
  [[ -z "$item_id" ]] && return 1

  # Use awk for efficient single-pass extraction
  awk -v id="$item_id" '
    index($0, id) > 0 && !found { found = 1 }
    found && /^\s*- \[[ x~]\]/ && !(index($0, id) > 0) { exit }
    found && /^##[[:space:]]/ { exit }
    found && /^---/ { exit }
    found { print }
  ' "$tf"
}
