# sentinel

Universal AI code quality enforcement plugin for Claude Code.

Prevents 47 common AI coding mistakes, enforces surgical edits, blocks dummy code, scans for secrets, and manages context memory — automatically.

## Quick Start

```bash
# Install (one command, any machine)
claude plugin install github:tk-logl/sentinel

# Initialize in your project
/sentinel:init

# That's it. All hooks are now active.
```

## What Happens After Install

**You don't need to do anything.** Sentinel hooks fire automatically:

- **Write code** → dummy code blocked (pass, TODO, assert True)
- **Hardcode a secret** → blocked (API keys, JWT, passwords)
- **Run `brew install` on Linux** → blocked
- **Type "for now" or "일단"** → scope reduction warning
- **Edit a 200+ line file** → header check warning
- **Session starts** → environment + previous state injected
- **Session ends** → state saved for next session
- **Context compacts** → structured 5-section state preserved

## How It Works

### Blocking Hooks (prevents the action)

| Hook | Trigger | What It Blocks |
|------|---------|---------------|
| `pre-edit-gate` | Before Write/Edit | Source code edits without `.sentinel/current-task.json` checklist |
| `deny-dummy` | Before Write/Edit | `pass`, `TODO/FIXME`, `assert True`, debug prints, `NotImplementedError`, unsafe deserialization |
| `secret-scan` | Before Write/Edit | Hardcoded API keys (sk-, ghp_, AKIA, xoxb-, AIza, eyJ...), DB passwords, private keys |
| `env-safety` | Before Bash | `brew` on Linux, bare `python`, dangerous `rm -rf`, `--no-verify`, unsafe `pip install` |

### Warning Hooks (warns but allows)

| Hook | Trigger | What It Warns About |
|------|---------|-------------------|
| `surgical-change` | Before Write/Edit | Large diffs (>15 lines), file overwrites, function deletion without grep |
| `scope-guard` | User prompt | "for now", "simplified", "일단", "とりあえず" — scope reduction language |
| `post-edit-verify` | After Write/Edit | Remaining stubs, missing type hints, bare except, naive datetime, silent errors |
| `file-header-check` | After Write/Edit | Files >200 lines without descriptive headers |
| `completion-check` | AI stops | Uncommitted changes, active tasks, unresolved errors, TODO in changed files |

### State Management Hooks

| Hook | Trigger | What It Does |
|------|---------|-------------|
| `session-init` | Session start | Injects environment info, previous state, error patterns, OMC integration |
| `state-preserve` | Before compaction | Saves 5-section structured state (intent/files/decisions/status/next) |
| `session-save` | Session end | Saves state for next session recovery |
| `error-logger` | After Bash | Classifies errors (syntax/import/permission/network), detects repeated failures |

### Deep Analysis (Python AST)

`deep-analyze.py` catches patterns that grep cannot:

| Pattern | Detection |
|---------|-----------|
| N+1 Query | `.objects.filter()` inside loops |
| Resource Leak | `open()` without `with` context manager |
| Encoding Bug | `open()` without `encoding=` parameter |
| Dead Code | Unused imports via AST analysis |
| SSRF Risk | HTTP requests with variable URLs (excludes config constants) |
| God Object | Classes with 20+ methods, files with 500+ lines and 30+ functions |
| Race Condition | `global` keyword usage |
| Magic Numbers | Hardcoded numbers (excludes HTTP status codes) |
| Naming Convention | camelCase in Python / snake_case in TypeScript |
| Command Injection | `shell=True` with string formatting |

## Usage

### Slash Commands

```
/sentinel:init                    # Initialize .sentinel/ in your project
/sentinel:check                   # Scan entire project against all rules
/sentinel:header path/to/file.py  # Generate/update file header comment
```

### Skills (reference guides)

```
/sentinel:ai-mistakes     # 47 AI mistake patterns — full reference
/sentinel:checklist        # Pre-implementation checklist workflow
/sentinel:file-headers     # File header format and generation guide
/sentinel:memory-guard     # Context preservation strategies
```

### Agents (code review & verification)

**Code Review** — checks against 47 AI mistake patterns:
```
Use sentinel-reviewer agent to review this PR
```

**Completion Verification** — evidence-based, not "should work":
```
Use sentinel-verifier agent to verify CRIT-2 fix is complete
```

## Typical Workflow

### Bug Fix
```
1. /sentinel:checklist                    # Read the checklist workflow
2. Create .sentinel/current-task.json     # Pre-edit gate requires this
3. Edit source code                       # Hooks auto-enforce quality
4. /sentinel:check                        # Full project scan
5. Use sentinel-verifier to confirm       # Evidence-based completion
```

### New Feature
```
1. /sentinel:init                         # If first time in this project
2. Create .sentinel/current-task.json     # Document: why, approach, impact, blast radius
3. Implement                              # deny-dummy blocks stubs, secret-scan blocks keys
4. Use sentinel-reviewer for PR review    # 47-pattern automated review
```

### Quick Check
```
/sentinel:check                           # One command — full project scan
```

## Pre-Implementation Checklist

Before editing source code, sentinel requires `.sentinel/current-task.json`:

```json
{
  "task_id": "CRIT-2",
  "why": "API endpoint crashes with TypeError on every call",
  "approach": "Replace dict .get() with dataclass attribute access",
  "impact_files": ["main.py:get_artifact — 2 callers", "test_api.py — needs new test"],
  "blast_radius": {
    "tests_break": ["test_artifact_endpoint"],
    "tests_add": ["test_artifact_not_found", "test_artifact_invalid_id"]
  },
  "verify_command": "pytest tests/test_api.py -x -v"
}
```

This is your blueprint — fill it with real analysis, not placeholders.
The `pre-edit-gate` hook blocks all source code edits until this file exists with all required fields.

## Configuration

`config/sentinel.json` (or `.sentinel/config.json` after `/sentinel:init`):

```json
{
  "source_extensions": ["py", "ts", "tsx", "js", "jsx", "go", "rs", "java", "c", "cpp"],
  "skip_patterns": ["**/test_*", "**/*.test.*", "**/node_modules/**"],
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

## Platform Support

| OS | Status | Requirements |
|----|--------|-------------|
| **Linux** | Full support | GNU grep + jq (pre-installed on most distros) |
| **macOS** | Full support | `brew install grep jq` (auto-detects `ggrep`) |
| **Windows** | WSL/Git Bash | Native PowerShell not supported (bash scripts) |

If PCRE grep or jq is missing, hooks **warn and gracefully degrade** — they never block incorrectly.
Session startup shows a platform compatibility report if any tools are missing.

## Works With

- **oh-my-claudecode (OMC)** — Auto-detected. Session init injects OMC notepad/compaction state. Both systems coexist without conflict.
- **Any Claude Code project** — No external dependencies beyond bash, jq, git.

## Architecture

```
sentinel/
├── .claude-plugin/
│   ├── plugin.json              # Plugin manifest
│   └── marketplace.json         # Discovery metadata
├── hooks/
│   ├── hooks.json               # 13 hooks registered across 7 event types
│   └── scripts/
│       ├── _common.sh           # Cross-platform compatibility layer
│       ├── deep-analyze.py      # Python AST pattern analyzer (15+ patterns)
│       ├── deny-dummy.sh        # Block dummy/stub code (BLOCKING)
│       ├── pre-edit-gate.sh     # Require checklist before edits (BLOCKING)
│       ├── secret-scan.sh       # Block hardcoded secrets (BLOCKING)
│       ├── env-safety.sh        # Block dangerous commands (BLOCKING)
│       ├── surgical-change.sh   # Enforce minimal diffs (WARNING)
│       ├── scope-guard.sh       # Detect scope reduction (WARNING)
│       ├── post-edit-verify.sh  # Quality checks after edit (WARNING)
│       ├── file-header-check.sh # Header existence check (WARNING)
│       ├── completion-check.sh  # Incomplete work detection (WARNING)
│       ├── error-logger.sh      # Error classification + logging
│       ├── session-init.sh      # Session startup context injection
│       ├── state-preserve.sh    # Pre-compaction state save
│       └── session-save.sh      # Session end state save
├── agents/
│   ├── sentinel-reviewer.md     # 47-pattern code review agent
│   └── sentinel-verifier.md     # Evidence-based completion verifier
├── skills/
│   ├── ai-mistakes/SKILL.md     # 47 AI mistake patterns reference
│   ├── checklist/SKILL.md       # Pre-implementation checklist guide
│   ├── file-headers/SKILL.md    # File header generation guide
│   └── memory-guard/SKILL.md    # Context preservation strategies
├── commands/
│   ├── check.md                 # /sentinel:check
│   ├── init.md                  # /sentinel:init
│   └── header.md                # /sentinel:header
├── config/sentinel.json         # Default configuration
├── templates/
│   ├── CLAUDE.md.template       # Project CLAUDE.md starting point
│   ├── settings.json.template   # Claude Code settings.json deny rules
│   └── file-header.template     # File header comment format
├── README.md
└── LICENSE (MIT)
```

## License

MIT
