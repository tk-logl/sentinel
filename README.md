# sentinel

Universal AI code quality enforcement plugin for Claude Code.

Prevents 47 common AI coding mistakes, enforces surgical edits, blocks dummy code, scans for secrets, and manages context memory — automatically.

## Install

```bash
# From GitHub
claude plugin install github:tk-logl/sentinel

# From local directory (development)
claude plugin marketplace add /path/to/sentinel
claude plugin install sentinel@sentinel
```

## What It Does

### Blocking Hooks (exit 2 — prevents the action)
| Hook | Event | What It Blocks |
|------|-------|---------------|
| `pre-edit-gate` | PreToolUse:Write\|Edit | Source code edits without `.sentinel/current-task.json` |
| `deny-dummy` | PreToolUse:Write\|Edit | `pass`, `TODO`, `assert True`, debug prints, `NotImplementedError` |
| `secret-scan` | PreToolUse:Write\|Edit | Hardcoded API keys, tokens, passwords (sk-, ghp_, AKIA, xoxb-) |
| `env-safety` | PreToolUse:Bash | `brew` on Linux, bare `python`, dangerous `rm -rf` |

### Warning Hooks (exit 0 — warns but allows)
| Hook | Event | What It Warns About |
|------|-------|-------------------|
| `surgical-change` | PreToolUse:Write\|Edit | Large diffs (>15 lines), file overwrites, function deletion |
| `scope-guard` | UserPromptSubmit | "for now", "simplified", "basic version" language |
| `post-edit-verify` | PostToolUse:Write\|Edit | Remaining stubs, missing type hints, debug code |
| `file-header-check` | PostToolUse:Write\|Edit | Files >200 lines without descriptive headers |
| `completion-check` | Stop | Uncommitted changes, active tasks, unresolved errors |

### State Management Hooks
| Hook | Event | What It Does |
|------|-------|-------------|
| `session-init` | SessionStart | Injects environment info + previous session state |
| `state-preserve` | PreCompact | Saves 5-section structured state before compaction |
| `session-save` | SessionEnd | Saves state on session end |
| `error-logger` | PostToolUse:Bash | Classifies errors, detects repeated failures |

## Agents

- **sentinel-reviewer** — Code review against 47 AI mistake patterns
- **sentinel-verifier** — Evidence-based completion verification

## Skills

- **/sentinel:ai-mistakes** — Reference guide for all 47 patterns
- **/sentinel:checklist** — Pre-implementation checklist workflow
- **/sentinel:file-headers** — File header generation guide
- **/sentinel:memory-guard** — Context preservation strategies

## Commands

- **/sentinel:check** — Scan project for rule violations
- **/sentinel:init** — Initialize sentinel in a project
- **/sentinel:header [file]** — Generate file header for a specific file

## Configuration

After installing, run `/sentinel:init` to create `.sentinel/config.json`:

```json
{
  "source_extensions": ["py", "ts", "tsx", "js", "jsx"],
  "header_threshold_lines": 200,
  "error_repeat_limit": 3,
  "enforcement": {
    "pre_edit_gate": true,
    "deny_dummy": true,
    "surgical_change": true,
    "scope_guard": true,
    "secret_scan": true,
    "file_header_check": true
  }
}
```

## Works With

- **oh-my-claudecode** — Auto-detected. Both systems coexist without conflict.
- **Any Claude Code project** — No dependencies. Pure bash hooks.

## Requirements

- Claude Code CLI
- bash, jq, git (standard on Linux/macOS)

## License

MIT
