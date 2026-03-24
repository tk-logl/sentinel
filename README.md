<div align="center">

# sentinel

**Universal AI code quality enforcement for Claude Code**

Prevents 47 common AI coding mistakes. Automatically.

[![CI](https://github.com/tk-logl/sentinel/actions/workflows/test.yml/badge.svg)](https://github.com/tk-logl/sentinel/actions/workflows/test.yml)
[![ShellCheck](https://img.shields.io/badge/ShellCheck-passing-brightgreen)](https://www.shellcheck.net/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-1.6.0-orange)](https://github.com/tk-logl/sentinel/releases/tag/v1.6.0)

[Install](#install) · [How It Works](#how-it-works) · [Configuration](#configuration) · [FAQ](#faq)

</div>

---

## Why Sentinel?

AI coding assistants make the same mistakes repeatedly: dummy code (`pass`, `TODO`), hardcoded secrets, scope reduction ("for now"), large destructive edits, and false completion claims. Sentinel catches all of these **before they reach your codebase**.

```
⛔ [Sentinel Deny-Dummy] Placeholder/stub code detected in: api.py

Violations:
  - 'pass' as standalone statement (implement the function body)
  - TODO/FIXME/PLACEHOLDER/HACK comment (implement now, don't defer)

Every function must have a real implementation. No stubs, no deferred work.
→ Implement the actual logic, then retry.
```

## Install

```bash
# One command. Any machine. Takes 5 seconds.
claude plugin install github:tk-logl/sentinel

# Initialize in your project (optional — detects your stack)
/sentinel:init
```

That's it. All 21 hooks are now active. No configuration required.

## Demo: What You'll See

### Session Start
```
=== Sentinel Active ===
Enforcement: pre-edit-gate, deny-dummy, surgical-change, scope-guard,
             secret-scan, env-safety, error-logger, post-edit-verify
```

### Blocking a Hardcoded Secret
```
⛔ [Sentinel Secret-Scan] Hardcoded secrets detected in: config.py

Found:
  - OpenAI/Stripe secret key pattern (sk-...)

Never hardcode credentials. Use:
  Python: os.environ.get('API_KEY') or django-environ
  Node:   process.env.API_KEY or dotenv
→ Move secrets to environment variables, then retry.
```

### Session Quality Report (on Stop)
```
📊 [Sentinel] Session Quality Report
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Session: 2026-03-18T10:48:27Z
  ✅ Checks passed: 24
  ⛔ Blocks (prevented): 3
  ⚠️  Warnings issued: 5
  📈 Quality Score: 91/100 (A)

  Top patterns caught:
    dummy_code: 2x
    large_edit: 1x
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

## How It Works

Sentinel registers **21 hooks** across 9 Claude Code event types. They fire automatically — you don't call them.

### Blocking Hooks (prevents the action)

| Hook | Trigger | What It Blocks |
|------|---------|---------------|
| `pre-edit-gate` | Before Write/Edit | Source edits without `.sentinel/current-task.json` + behavior spec (v1.6.0) |
| `deny-dummy` | Before Write/Edit | `pass`, `TODO`, `assert True`, `mock.assert_called()`, `len>=0`, `is not None`, debug prints, unsafe deserialization |
| `secret-scan` | Before Write/Edit | API keys (sk-, ghp_, AKIA, xoxb-, AIza, eyJ...), private keys, DB passwords |
| `scope-reduction-guard` | Before Write/Edit | Scope reduction in code comments (21 Korean + 16 English + 5 Japanese patterns) |
| `env-safety` | Before Bash | `brew` on Linux, bare `python`, `rm -rf /`, `--no-verify` |

### Warning Hooks (warns but allows)

| Hook | Trigger | What It Warns About |
|------|---------|-------------------|
| `surgical-change` | Before Write/Edit | Large diffs (configurable), file overwrites, function deletion |
| `scope-guard` | User prompt | "for now", "simplified", "일단", "とりあえず" |
| `task-scope-guard` | User prompt | Numbered task lists → enforces complete implementation |
| `post-edit-verify` | After Write/Edit | Stubs, missing types, bare except, naive datetime |
| `file-header-check` | After Write/Edit | Files >200 lines without descriptive headers |
| `task-completion-gate` | After TaskUpdate | Evidence check before marking tasks completed |
| `completion-check` | AI stops | Uncommitted changes, active tasks, TODO in changed files, task-list status |
| `spec-verify` | AI stops | Validates all behavior spec assertions appear in test files (v1.6.0) |
| `spec-auto-test` | After Write/Edit | Auto-generates pytest skeleton from `.sentinel/specs/*.json` (v1.6.0) |

### Task Lifecycle (v1.4.0)

| Hook | Trigger | What It Does |
|------|---------|-------------|
| `task-automark` | After git commit | Auto-marks task IDs as `[x]` done in task list |
| `subagent-context` | Before Task spawn | Injects quality rules into subagents |

### State Management

| Hook | Trigger | What It Does |
|------|---------|-------------|
| `session-init` | Session start | Injects environment, previous state, task list, context map |
| `state-preserve` | Before compaction | Saves fully auto-populated 5-section state |
| `post-compact-restore` | After compaction | Re-injects task context + pre-compaction state |
| `session-save` | Session end | Persists state for next session |
| `error-logger` | After Bash | Classifies errors, detects repeated failures |

### Deep Analysis (Python AST + Regex)

`deep-analyze.py` catches patterns that grep cannot:

**Python** (AST-based):
- N+1 queries (`.objects.filter()` inside loops)
- Resource leaks (`open()` without `with`)
- Unused imports (dead code)
- SSRF (HTTP requests with variable URLs)
- God objects (20+ methods, 500+ lines)
- Command injection (`shell=True` + formatting)

**TypeScript/JavaScript** (regex-based):
- Unused imports
- `any` type usage
- `==` instead of `===`
- `var` instead of `const`/`let`
- `eval()` usage
- `innerHTML`/`dangerouslySetInnerHTML` (XSS)
- Promise `.then()` without `.catch()`
- `useEffect` without cleanup return
- `console.log()` in source
- `@ts-ignore` without reason

**Go**: Discarded errors (`_ = err`), unclosed resources

## Features

### Task Lifecycle (v1.4.0)

Sentinel auto-detects your task list (`tasks.md`, `.claude/action-list.md`, etc.) and tracks progress:

- **Session start**: injects pending/in-progress items with enforcement message
- **Git commit**: auto-marks task IDs (e.g., `CRIT-2`) as `[x]` done
- **Pre-edit**: injects full task spec when editing with an active task
- **Numbered lists**: enforces complete implementation of all items
- **Completion**: warns if uncommitted changes or TODO/FIXME remain

### Context-Aware Analysis (v1.4.0)

`build-context-map.py` analyzes your project using Python AST and TS/JS regex:

```json
{
  "files": {
    "src/base.py": {
      "functions": {
        "Base.handle": { "classification": "abstract" },
        "Base.teardown": { "classification": "intentional_noop" },
        "stub_fn": { "classification": "stub" }
      }
    }
  }
}
```

`deny-dummy.sh` uses this map to **allow** `pass` in abstract methods and cleanup functions while **blocking** it in real stubs.

### i18n (v1.3.0)

Sentinel auto-detects your locale and outputs messages in your language:

| Language | Example Output |
|----------|---------------|
| English | `Placeholder/stub code detected` |
| 한국어 | `더미/플레이스홀더 코드 감지` |
| 日本語 | `ダミー/プレースホルダーコード検出` |

Set explicitly in `.sentinel/config.json`:
```json
{ "language": "ko" }
```

### Usage Statistics (v1.3.0)

Every hook activation is tracked in `.sentinel/stats.json`. When the session ends, you get a quality report with:
- Checks passed / blocks prevented / warnings issued
- Quality score (A+ to F)
- Top patterns detected

### Agents

**sentinel-reviewer** — Code review against 47 AI mistake patterns:
```
Use sentinel-reviewer agent to review this PR
```

**sentinel-verifier** — Evidence-based completion verification:
```
Use sentinel-verifier agent to verify this task is complete
```

### TDD Enforcement (v1.6.0)

Sentinel enforces Test-Driven Development by requiring behavior specs before code edits:

1. **Spec Gate**: `pre-edit-gate.sh` blocks code edits unless `.sentinel/specs/{task-id}.json` exists with `given/when/then/assert` behaviors
2. **Spec→Test**: `spec-to-test.py` converts spec JSON to pytest skeleton — assertions copied verbatim (AI cannot weaken them)
3. **Auto-Trigger**: `spec-auto-test.sh` runs spec-to-test automatically when a spec file is written
4. **Spec Verify**: `spec-verify.sh` validates all spec assertions appear in actual test files at session end
5. **Mutation Testing**: `/sentinel:mutate` runs mutmut on changed files (70% kill threshold)

```json
// .sentinel/specs/CRIT-2.json
{
  "task_id": "CRIT-2",
  "module": "apps/service/views.py",
  "functions": ["create_user"],
  "behavior": [
    {
      "id": "B1",
      "given": "valid user data",
      "when": "create_user is called",
      "then": "returns User with matching email",
      "assert": "result.email == 'test@example.com'"
    },
    {
      "id": "B2",
      "given": "duplicate email",
      "when": "create_user is called",
      "then": "raises ValueError",
      "assert": "pytest.raises(ValueError)"
    }
  ],
  "edge_cases": ["empty string", "None", "email without @"]
}
```

### Slash Commands

```
/sentinel:init                    # Initialize .sentinel/ (detects project type)
/sentinel:check                   # Full project rule compliance scan
/sentinel:header path/to/file.py  # Generate file header comment
/sentinel:mutate                  # Run mutation testing on changed files (v1.6.0)
```

### Skills (reference guides)

```
/sentinel:ai-mistakes     # 47 AI mistake patterns reference
/sentinel:checklist       # Pre-implementation checklist workflow
/sentinel:file-headers    # File header format guide
/sentinel:memory-guard    # Context preservation strategies
```

## Configuration

After `/sentinel:init`, configure at `.sentinel/config.json`:

```json
{
  "mode": "standard",
  "language": "auto",
  "source_extensions": ["py", "ts", "tsx", "js", "jsx", "go"],
  "skip_patterns": ["**/test_*", "**/node_modules/**"],
  "protected_branches": ["main", "master", "develop"],
  "categories": {
    "codeQuality": {
      "block_todo_comments": "off"
    }
  }
}
```

### Preset Modes (v1.5.0)

Choose a mode to set defaults for all 66 items at once:

| Mode | Philosophy | Blocking | Warnings |
|------|-----------|----------|----------|
| `relaxed` | Minimal friction | Secrets only | Few |
| `standard` | Balanced (default) | Code quality + secrets + safety | Most analysis |
| `strict` | Maximum enforcement | Everything | Everything |
| `paranoid` | Zero tolerance | Everything at block level | Everything |

### Per-Item Override

Override any item within its category:

```json
{
  "mode": "standard",
  "categories": {
    "codeQuality": { "block_todo_comments": "off" },
    "safetyNet": { "block_force_push": "block" },
    "analysis": { "warn_any_type": "warn" }
  }
}
```

**Resolution order:** project override → mode default → hook fallback.

### Categories (7)

| Category | Items | What It Controls |
|----------|-------|-----------------|
| `codeQuality` | 12 | pass, TODO, assert True, debug prints, empty functions, unsafe deserialization |
| `security` | 9 | API keys, tokens, credentials, private keys, connection strings |
| `workflow` | 10 | Pre-edit checklist, behavior spec gate, scope guard, task tracking, completion checks |
| `safetyNet` | 13 | Dangerous commands, force push, protected branches, destructive SQL |
| `editDiscipline` | 4 | Large edits, file overwrites, function deletion, file headers |
| `context` | 5 | Session init, state preservation, compaction restore |
| `analysis` | 13 | Silent errors, missing types, bare except, console.log, datetime |

Each item supports 4 actions: `block` (deny edit), `warn` (allow + message), `on` (silently active), `off` (disabled).

See `config/item-catalog.json` for the full list with descriptions and examples.

### Legacy Compatibility

v1.4.0 `enforcement.*` booleans still work. Projects without `mode` or `categories` behave identically to v1.4.0.

## Platform Support

| OS | Status | Notes |
|----|--------|-------|
| **Linux** | ✅ Full | GNU grep + jq (pre-installed on most distros) |
| **macOS** | ✅ Full | `brew install grep jq` (auto-detects `ggrep`) |
| **Windows** | ⚠️ WSL | Requires WSL or Git Bash |

Missing tools? Sentinel **warns and gracefully degrades** — it never blocks incorrectly. Session startup shows a compatibility report.

## Compatibility

- **Claude Code** — Required (this is a Claude Code plugin)
- **oh-my-claudecode (OMC)** — Auto-detected. Session init injects OMC state. Both coexist without conflict.
- **Any project** — No external dependencies beyond bash, jq, git.

## Pre-Implementation Checklist

Sentinel requires `.sentinel/current-task.json` before source code edits:

```json
{
  "item_id": "CRIT-2",
  "why": "API endpoint crashes with TypeError",
  "approach": "Replace dict .get() with dataclass attribute access",
  "impact_files": ["main.py:get_artifact — 2 callers"],
  "blast_radius": {
    "tests_break": ["test_artifact_endpoint"],
    "tests_add": ["test_artifact_not_found"]
  },
  "verify_command": "pytest tests/test_api.py -x"
}
```

Disable with `"categories": {"workflow": {"require_pre_edit_checklist": "off"}}` or use `"mode": "relaxed"`.

## FAQ

**Q: Does sentinel slow down my workflow?**
No. Each hook has a timeout (3-10s) and fail-open design. If a hook crashes or times out, the action proceeds. Median hook execution: <100ms.

**Q: Can I disable specific hooks?**
Yes. Set `"mode": "relaxed"` for minimal enforcement, or override individual items: `"categories": {"codeQuality": {"block_todo_comments": "off"}}`. Legacy `enforcement.*` booleans also still work.

**Q: Will it block my test files?**
No. Test files (`test_*`, `*.test.*`, `*.spec.*`, `/tests/`) are excluded from blocking hooks. You can write `assert True` in tests.

**Q: Does it work with other plugins?**
Yes. Sentinel is designed to coexist with OMC and other Claude Code plugins. Hook order is deterministic.

**Q: What if jq is not installed?**
Blocking hooks (deny-dummy, secret-scan, pre-edit-gate, env-safety) will **refuse all edits** until jq is installed. Warning hooks silently skip. This is by design — missing jq means no JSON parsing, so safety cannot be guaranteed.

**Q: How do I uninstall?**
```bash
claude plugin uninstall sentinel
rm -rf .sentinel/  # Optional: remove project state
```

## Architecture

```
sentinel/
├── .claude-plugin/          # Plugin manifest
├── hooks/
│   ├── hooks.json           # 19 hooks across 9 event types
│   └── scripts/
│       ├── _common.sh       # Cross-platform layer + i18n + stats + task utilities
│       ├── _state-common.sh # Shared state save logic
│       ├── build-context-map.py   # AST file classifier (Python/TS/JS)
│       ├── state-extract-intent.py # Transcript intent extractor
│       ├── deep-analyze.py  # AST analyzer (Python/TS/JS/Go)
│       └── *.sh             # 19 hook scripts
├── agents/                  # sentinel-reviewer + sentinel-verifier
├── skills/                  # 4 reference guides
├── commands/                # 3 slash commands
├── config/                  # Default configuration
├── templates/               # CLAUDE.md, settings.json, file-header
├── tests/                   # 73 automated tests
└── .github/workflows/       # CI (ShellCheck + tests + validation)
```

## Contributing

1. Fork and clone
2. Make changes to hook scripts in `hooks/scripts/`
3. Run tests: `bash tests/test-hooks.sh`
4. Run lint: `shellcheck -s bash -S warning hooks/scripts/*.sh`
5. Submit PR

## License

[MIT](LICENSE) — use it anywhere, modify freely.

---

<div align="center">
<strong>Built by <a href="https://github.com/tk-logl">TopKloud</a></strong>
</div>
