# Changelog

All notable changes to sentinel will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.4.0] - 2026-03-18

### Added
- **Task lifecycle system** — auto-detect task lists, inject pending items on session start/compaction, enforce complete implementation
  - `task-automark.sh` — auto-marks task IDs as `[x]` on git commit (PostToolUse Bash)
  - `task-scope-guard.sh` — detects numbered lists, enforces complete implementation (UserPromptSubmit)
  - `scope-reduction-guard.sh` — blocks scope reduction in code comments: 21 Korean + 16 English + 5 Japanese patterns (PreToolUse, BLOCKING)
  - `task-completion-gate.sh` — evidence check before task completion: uncommitted changes, TODO/FIXME, verify_command (PostToolUse TaskUpdate)
  - `subagent-context.sh` — injects quality rules into subagent Task spawns (PreToolUse Task)
- **Context-aware analysis** — AST-based file classification replaces regex-only dummy detection
  - `build-context-map.py` — Python AST + TS/JS regex: classifies functions as abstract/intentional_noop/stub/implemented
  - `deny-dummy.sh` context-map integration — allows `pass` in abstract methods and cleanup functions, blocks true stubs
- **Memory/compaction full automation** — all 5 sections auto-populated, zero placeholder text
  - `_state-common.sh` — shared `sentinel_save_state()` for state-preserve and session-save
  - `state-extract-intent.py` — extracts user intent from transcript JSONL (last 3 messages, 200 chars each)
  - `post-compact-restore.sh` — saves compact_summary, re-injects task context + pre-compaction state (PostCompact)
- **Task list utilities in `_common.sh`** — `sentinel_find_task_list`, `sentinel_task_count`, `sentinel_task_list_items`, `sentinel_task_mark`, `sentinel_task_extract_ids`, `sentinel_task_get_spec`
- **Config utilities** — `sentinel_read_config` (cached), `sentinel_is_source_file`, `sentinel_should_skip`
- `session-init.sh` task-list injection (pending/in-progress counts + items, enforcement message)
- `pre-edit-gate.sh` spec injection (outputs full task spec from task list when edit is allowed)
- `completion-check.sh` task-list integration (warns on [~] items remaining)
- Config: `taskList` section (auto-detect, idPattern, states, maxInjectItems), `preImplGate` section
- Config: enforcement toggles for all new hooks + `post_edit_verify` + `completion_check`
- 31 new tests (57 total, up from 26)

### Changed
- `state-preserve.sh` rewritten — uses `_state-common.sh`, auto-populates Section 1 (intent from transcript), Section 3 (decisions from current-task.json), Section 5 (next steps from task list)
- `session-save.sh` rewritten — uses `_state-common.sh`, eliminates ~60 lines of duplication
- `error-logger.sh` — reads `error_repeat_limit` from config instead of hardcoded 3
- `surgical-change.sh` — reads `surgical_change_max_lines` from config instead of hardcoded 15
- `hooks.json` — 6 new hook registrations (PostCompact, TaskUpdate, Task, UserPromptSubmit +1, PreToolUse +2)

### Removed
- Dead config keys: `linters`, `state_dir`, `notifications` (never connected)

## [1.3.0] - 2026-03-18

### Added
- **i18n message system** — auto-detects locale (ko/ja/en), `sentinel_msg()` for localized output
- **Usage statistics tracking** — `.sentinel/stats.json` tracks checks/blocks/warnings per session
- **Session quality report** — quality score (A+ to F), top patterns, shown on Stop hook
- **TS/JS deep analysis patterns** — 10 new: unused imports, `any` type, `==` vs `===`, `var`, `eval()`, innerHTML/XSS, Promise without catch, useEffect cleanup, console.log, @ts-ignore
- **Interactive onboarding** — `/sentinel:init` detects project type, suggests config, asks preferences
- `sentinel_sanitize()` utility in `_common.sh` for terminal escape injection prevention
- JSON injection protection in `error-logger.sh` (uses `jq --arg` instead of string interpolation)
- Automated test suite (`tests/test-hooks.sh`) — 26 tests covering all 13 hooks
- GitHub Actions CI workflow (shellcheck + multi-OS tests + JSON validation + structure checks)
- Version check mechanism in `session-init.sh` (GitHub API, 24h cache)
- `CHANGELOG.md`

### Fixed
- ShellCheck warnings: SC2034 (unused vars), SC2144 (glob in -f), SC2155 (declare/assign)
- Stats auto-reset on session start (prevents stale data)

### Security
- Fixed JSON injection vulnerability in error-logger.sh log entries
- Sanitized all user-controlled output across hooks to prevent terminal escape injection

## [1.2.0] - 2026-03-17

### Added
- Config enforcement toggles connected to all 8 toggleable hooks via `sentinel_check_enabled()`
- Severity-based dependency guards: blocking hooks fail-closed (exit 2) when jq/PCRE missing
- Context-aware facade detection in `completion-check.sh` (single-statement functions only)
- `CHANGED_FILES` deduplication with `sort -u` in `completion-check.sh`
- Explicit degraded-mode listing in `session-init.sh` (BLOCKED vs DISABLED hooks)

### Changed
- `pre-edit-gate.sh` jq optimization: 7 calls → 1 call (tab-delimited output + IFS read)
- Blocking hook timeouts increased: 3s → 10s (pre-edit-gate, deny-dummy, secret-scan, env-safety)
- Warning hook timeouts increased: 3s → 5-10s (surgical-change, post-edit-verify)

### Fixed
- jq `//` operator bug: `false // true` returns `true` in jq — replaced with explicit `== false` check
- Scope-guard false positives: removed overly broad patterns ("일단", "for now", "simplified")
- Added compound Korean/English/Japanese patterns for better precision

## [1.1.0] - 2026-03-16

### Added
- Anti-skip enforcement: error-logger now mandates acknowledgment of every error
- Anti-fraud checklist in `completion-check.sh` (6-point verification)
- Session error count tracking (5+ errors → mandatory user escalation)
- Repeated error detection (3x same hash → stuck warning)
- `rm -rf /` word boundary detection fix

### Fixed
- `rm -rf /` regex: trailing slash no longer bypasses detection
- Project-specific examples removed from skills (file-headers, memory-guard)

## [1.0.0] - 2026-03-15

### Added
- **13 hook scripts** across 7 Claude Code event types
  - `pre-edit-gate.sh` — blocks source edits without `.sentinel/current-task.json`
  - `deny-dummy.sh` — blocks pass/TODO/FIXME/assert True/debug prints/unsafe deserialization
  - `secret-scan.sh` — blocks hardcoded API keys (sk-, ghp_, AKIA, xoxb-, AIza, eyJ, private keys)
  - `env-safety.sh` — blocks brew on Linux, bare python, dangerous rm, --no-verify
  - `surgical-change.sh` — warns on large diffs, file overwrites, function deletion
  - `scope-guard.sh` — warns on scope-reduction language (Korean/English/Japanese)
  - `post-edit-verify.sh` — warns on remaining stubs, missing types, bare except, naive datetime
  - `file-header-check.sh` — warns when 200+ line files lack descriptive headers
  - `completion-check.sh` — warns on uncommitted changes, active tasks, unresolved errors
  - `error-logger.sh` — classifies and logs Bash errors, detects repeated failures
  - `session-init.sh` — injects environment info, previous state, error patterns
  - `state-preserve.sh` — saves 5-section structured state before compaction
  - `session-save.sh` — saves state on session end
- **Python AST deep analyzer** (`deep-analyze.py`) — 15+ patterns including N+1 queries, resource leaks, SSRF, god objects, race conditions, command injection
- **Cross-platform compatibility** (`_common.sh`) — PCRE grep auto-detection, macOS ggrep support, jq availability check
- **2 agents**: sentinel-reviewer (47-pattern code review), sentinel-verifier (evidence-based completion)
- **4 skills**: ai-mistakes (47 patterns), checklist, file-headers, memory-guard
- **3 commands**: /sentinel:check, /sentinel:init, /sentinel:header
- **3 templates**: CLAUDE.md.template, settings.json.template, file-header.template
- **oh-my-claudecode integration** — auto-detected, notepad/compaction state injection
- **Configuration** — `config/sentinel.json` with per-hook enforcement toggles
- MIT License

[Unreleased]: https://github.com/tk-logl/sentinel/compare/v1.4.0...HEAD
[1.4.0]: https://github.com/tk-logl/sentinel/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/tk-logl/sentinel/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/tk-logl/sentinel/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/tk-logl/sentinel/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/tk-logl/sentinel/releases/tag/v1.0.0
