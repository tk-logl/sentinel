#!/bin/bash
# Sentinel State Common Library
# Shared state-saving logic between state-preserve.sh and session-save.sh.
# All 5 sections auto-populated from git, current-task.json, task-list, and error log.
# No placeholder text — every section has real machine-gathered data.

# Requires _common.sh to be sourced first (for task-list utilities, config reader, etc.)

sentinel_save_state() {
  local trigger="${1:-auto}"
  local include_errors="${2:-true}"

  local project_root
  project_root=$(git rev-parse --show-toplevel 2>/dev/null)
  [[ -z "$project_root" ]] && return 1

  local state_dir="${project_root}/.sentinel/state"
  mkdir -p "$state_dir"

  local timestamp
  timestamp=$(date +%Y%m%d-%H%M%S)
  local branch
  branch=$(git branch --show-current 2>/dev/null || echo "unknown")

  # ─── Gather raw data ───
  local git_status
  git_status=$(git status --porcelain 2>/dev/null | head -20)
  local recent_commits
  recent_commits=$(git log --oneline -5 2>/dev/null)
  local diff_stat
  diff_stat=$(git diff --stat 2>/dev/null | tail -1)
  local staged_stat
  staged_stat=$(git diff --cached --stat 2>/dev/null | tail -1)

  # ─── Section 1: Session Intent (auto-populated) ───
  local task_info="" task_approach=""
  local task_file="${project_root}/.sentinel/current-task.json"
  if [[ -f "$task_file" && "$SENTINEL_NO_JQ" == "0" ]]; then
    local task_id task_why
    task_id=$(jq -r '.task_id // .item_id // "unknown"' "$task_file" 2>/dev/null)
    task_why=$(jq -r '.why // ""' "$task_file" 2>/dev/null)
    task_info="Active task: ${task_id} — ${task_why}"
    task_approach=$(jq -r '.approach // .design_decision // ""' "$task_file" 2>/dev/null)
  fi

  # Try to extract user intent from transcript
  local user_intent=""
  local script_dir="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
  if [[ -n "$TRANSCRIPT_PATH" && -f "$TRANSCRIPT_PATH" ]] && command -v python3 &>/dev/null; then
    if [[ -f "${script_dir}/state-extract-intent.py" ]]; then
      user_intent=$(python3 "${script_dir}/state-extract-intent.py" "$TRANSCRIPT_PATH" 2>/dev/null || true)
    fi
  fi

  local section1="${user_intent:-${task_info:-No active task}}"
  section1="${section1}
Last commits: $(echo "$recent_commits" | head -2 | tr '\n' ' ')"

  # ─── Section 2: Modified Files (auto-populated) ───
  local section2
  if [[ -n "$git_status" ]]; then
    section2=$(echo "$git_status" | head -15)
  else
    section2="(no uncommitted changes)"
  fi
  section2="${section2}
Diff summary: ${diff_stat} ${staged_stat}"

  # ─── Section 3: Decisions Made (auto-populated from current-task.json) ───
  local section3="(No design decisions recorded)"
  if [[ -n "$task_approach" ]]; then
    section3="Approach: ${task_approach}"
  fi

  # Add rejected alternatives from error log (same hash 3x = failed approach)
  local log_file="${project_root}/.sentinel/error-log.jsonl"
  if [[ -f "$log_file" && "$SENTINEL_NO_JQ" == "0" ]]; then
    local repeated
    repeated=$(tail -20 "$log_file" 2>/dev/null | jq -r '.hash' 2>/dev/null | sort | uniq -c | sort -rn | awk '$1 >= 3 {print $2}' | head -3)
    if [[ -n "$repeated" ]]; then
      local rejected_cmds
      rejected_cmds=""
      while IFS= read -r h; do
        [[ -z "$h" ]] && continue
        local cmd_info
        cmd_info=$(grep "\"hash\":\"${h}\"" "$log_file" 2>/dev/null | tail -1 | jq -r '"  Rejected: \(.cmd) (failed \(.type))"' 2>/dev/null)
        [[ -n "$cmd_info" ]] && rejected_cmds="${rejected_cmds}${cmd_info}\n"
      done <<< "$repeated"
      [[ -n "$rejected_cmds" ]] && section3="${section3}
$(echo -e "$rejected_cmds")"
    fi
  fi

  # ─── Section 4: Current State (auto-populated) ───
  local section4="Git status:
${git_status:-clean}

Recent commits:
${recent_commits}"

  if [[ "$include_errors" == "true" && -f "$log_file" && "$SENTINEL_NO_JQ" == "0" ]]; then
    local error_summary
    error_summary=$(tail -10 "$log_file" 2>/dev/null | jq -r '"  \(.type): \(.cmd)"' 2>/dev/null | head -5)
    section4="${section4}

Errors:
${error_summary:-none}"
  else
    section4="${section4}

Errors: none"
  fi

  # ─── Section 5: Next Steps (auto-populated from task-list) ───
  local section5=""
  local task_list_file
  task_list_file=$(sentinel_find_task_list 2>/dev/null)
  if [[ -n "$task_list_file" ]]; then
    local in_progress pending
    in_progress=$(sentinel_task_list_items "inProgress" 3 2>/dev/null)
    pending=$(sentinel_task_list_items "pending" 5 2>/dev/null)

    if [[ -n "$in_progress" ]]; then
      section5="### In Progress [~]:
${in_progress}
"
    fi
    if [[ -n "$pending" ]]; then
      section5="${section5}### Next Pending [ ]:
${pending}"
    fi
  fi

  # Verify command reminder
  if [[ -f "$task_file" && "$SENTINEL_NO_JQ" == "0" ]]; then
    local verify_cmd
    verify_cmd=$(jq -r '.verify_command // empty' "$task_file" 2>/dev/null)
    if [[ -n "$verify_cmd" ]]; then
      section5="${section5}

Verify command (run before claiming done): ${verify_cmd}"
    fi
  fi

  [[ -z "$section5" ]] && section5="(No task list found)"

  # ─── Build state file ───
  local state_content="# Pre-Compaction State (${timestamp})
## Trigger: ${trigger} | Branch: ${branch}

## 1. Session Intent
${section1}

## 2. Modified Files
${section2}

## 3. Decisions Made
${section3}

## 4. Current State
${section4}

## 5. Next Steps
${section5}

## RECOVERY INSTRUCTIONS:
1. Read this state file FIRST — it has the structured context
2. Check .sentinel/current-task.json for active task
3. Check task-list for [~] in-progress items — resume those
4. Do NOT restart completed work — check [x] items"

  # Save to latest + timestamped archive
  echo "$state_content" > "${state_dir}/latest.md"
  echo "$state_content" > "${state_dir}/${timestamp}.md"

  # Clean old archives (keep last 20)
  ls -t "${state_dir}"/20*.md 2>/dev/null | tail -n +21 | xargs -r rm -f

  echo "$state_content"
}
