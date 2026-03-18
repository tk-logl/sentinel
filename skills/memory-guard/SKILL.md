---
name: memory-guard
description: "Protect against context loss during compaction and session changes. Structured state preservation with 5-section format and multi-location recovery chain."
triggers:
  - "memory guard"
  - "context loss"
  - "context preservation"
  - "memory protection"
  - "compaction"
  - "state save"
---

# Memory Guard — Context Preservation System

Prevents information loss during context compaction, session switches, and /clear commands.

## The Problem

AI assistants lose context when:
1. **Context compaction** — the system summarizes old messages to fit the window
2. **Session end** — user runs /clear or closes the session
3. **Session crash** — unexpected termination
4. **Long tasks** — context fills up during extended work

Lost information includes: current task, decisions made, files being edited, error patterns, and next steps.

## The Solution: 5-Section Structured State

Every state save captures five sections:

### 1. Session Intent
What you're working on and why. Includes the task_id if one exists.

### 2. Modified Files
All files with uncommitted changes, plus a diff summary.

### 3. Decisions Made
Rationale for choices made during the session, including rejected alternatives. This is the most valuable section — it prevents re-debating the same decisions.

### 4. Current State
Git status, recent commits, recent errors, and any blockers.

### 5. Next Steps
What was in progress when the save happened, and what should come next.

## How State is Saved

### Automatic (hooks handle this)

| Event | Hook | Location |
|-------|------|----------|
| Context compaction | `state-preserve.sh` (PreCompact) | `.sentinel/state/latest.md` + timestamped archive |
| Session end / /clear | `session-save.sh` (SessionEnd) | `.sentinel/state/latest.md` + timestamped archive |
| Session start | `session-init.sh` (SessionStart) | Re-injects `.sentinel/state/latest.md` into context |

### Manual

You can also save state manually at any time:
```
Write the 5-section state to .sentinel/state/latest.md
```

## Recovery Chain

When a session starts, recovery follows this priority chain:

```
1. .sentinel/state/latest.md          ← Most recent structured state
2. .sentinel/current-task.json        ← Active task context
3. .sentinel/error-log.jsonl          ← Recent error patterns
4. git log --oneline -5               ← Recent commits (always available)
5. git status                         ← Uncommitted work (always available)
```

## Best Practices for Preserving Context

### During Long Tasks
1. **Commit frequently** — committed changes survive any context loss
2. **Update current-task.json** — keep the task file current as you progress
3. **Save agent results to files** — long agent outputs should be written to `.sentinel/agent-results/`
4. **Summarize intermediate results** — instead of keeping raw output in context, write summaries

### Before Compaction
The PreCompact hook runs automatically, but you can improve its output by:
- Keeping current-task.json up to date (it gets included in the state)
- Making sure important decisions are mentioned in recent messages (they get captured)
- Committing work-in-progress (even WIP commits are better than losing changes)

### After Recovery
When a session starts with a previous state:
1. **Read the state file first** — it tells you exactly where you left off
2. **Check for uncommitted changes** — git status shows what was in progress
3. **Resume the active task** — don't start new work unless the old task is done
4. **Don't re-debate decisions** — Section 3 records what was decided and why

## State File Format

```markdown
# Pre-Compaction State (20260315-143022)
## Trigger: auto | Branch: feature/my-feature

## 1. Session Intent
Active task: BUG-42 — Fix user login timeout on slow connections
Last commits: abc1234 fix: increase connection timeout to 30s

## 2. Modified Files
M  src/auth/login.py
M  tests/test_auth.py
Diff summary: 2 files changed, 15 insertions(+), 3 deletions(-)

## 3. Decisions Made
- Used connection pooling instead of per-request connections for better performance
- Rejected retry-on-timeout approach — masks underlying network issues
- Added graceful timeout with user-facing error message

## 4. Current State
Git status: 2 modified files (uncommitted)
Recent errors: none
Blockers: none

## 5. Next Steps
- Run tests: pytest tests/test_n8n.py -x
- If pass, commit with message "fix: CRIT-1 correct PMRequest attribute access"
- Next task: CRIT-2
```

## Archive Management

State archives are stored with timestamps:
```
.sentinel/state/
├── latest.md                    ← Always current
├── 20260315-143022.md          ← Archive
├── 20260315-120000.md          ← Archive
└── ...
```

Only the 20 most recent archives are kept. Older ones are automatically cleaned up.

## Integration with OMC

When oh-my-claudecode is installed alongside sentinel:
- OMC's `state_read`/`state_write` system operates independently
- Sentinel's `.sentinel/state/` complements OMC's `.omc/state/`
- Both systems can coexist — sentinel handles code quality state, OMC handles orchestration state
- The session-init hook checks both locations for recovery
