---
name: init
description: "Initialize sentinel in the current project — creates .sentinel/ directory and configuration"
---

# /sentinel:init

Set up sentinel enforcement in the current project with guided onboarding.

## Step 1: Detect Project Type

Analyze the project root to auto-detect the stack:

```
Check for:
  pyproject.toml / setup.py / requirements.txt  → Python
  package.json / tsconfig.json                  → Node/TypeScript
  go.mod                                        → Go
  Cargo.toml                                    → Rust
  pom.xml / build.gradle                        → Java
  *.sln / *.csproj                              → C#/.NET
  Makefile + *.c/*.cpp                          → C/C++
```

Report what was detected:
```
🔍 Detected: Python project (pyproject.toml found)
   Linter: ruff (pyproject.toml [tool.ruff] present)
   Test: pytest (pyproject.toml [tool.pytest] present)
   Extensions: .py
```

## Step 2: Create `.sentinel/` Directory

```
.sentinel/
├── state/           # Session state archives
├── config.json      # Project-specific settings
├── stats.json       # Usage statistics (auto-reset per session)
└── .gitignore       # Ignore runtime files
```

## Step 3: Create `.sentinel/.gitignore`

```
# Sentinel runtime state — not committed
state/
error-log.jsonl
current-task.json
agent-results/
stats.json
```

## Step 4: Generate `.sentinel/config.json`

Use detected project type to customize. Ask the user to confirm:

```
📋 Proposed sentinel configuration:
```

For **Python** projects:
```json
{
  "language": "auto",
  "source_extensions": ["py"],
  "skip_patterns": ["**/test_*", "**/*.test.*", "**/tests/**", "**/__pycache__/**"],
  "linters": { "python": "ruff" },
  "header_threshold_lines": 200,
  "error_repeat_limit": 3,
  "enforcement": {
    "pre_edit_gate": true,
    "deny_dummy": true,
    "surgical_change": true,
    "scope_guard": true,
    "secret_scan": true,
    "file_header_check": true,
    "env_safety": true,
    "error_logger": true
  }
}
```

For **Node/TypeScript** projects:
```json
{
  "language": "auto",
  "source_extensions": ["ts", "tsx", "js", "jsx"],
  "skip_patterns": ["**/node_modules/**", "**/*.test.*", "**/*.spec.*", "**/dist/**", "**/.next/**"],
  "linters": { "typescript": "eslint" },
  "header_threshold_lines": 200,
  "error_repeat_limit": 3,
  "enforcement": {
    "pre_edit_gate": true,
    "deny_dummy": true,
    "surgical_change": true,
    "scope_guard": true,
    "secret_scan": true,
    "file_header_check": true,
    "env_safety": true,
    "error_logger": true
  }
}
```

For **Go** projects:
```json
{
  "language": "auto",
  "source_extensions": ["go"],
  "skip_patterns": ["**/*_test.go", "**/vendor/**"],
  "linters": { "go": "golangci-lint" },
  "header_threshold_lines": 200,
  "error_repeat_limit": 3,
  "enforcement": {
    "pre_edit_gate": true,
    "deny_dummy": true,
    "surgical_change": true,
    "scope_guard": true,
    "secret_scan": true,
    "file_header_check": true,
    "env_safety": true,
    "error_logger": true
  }
}
```

For **multi-language** or **unknown** projects, combine extensions and ask the user.

## Step 5: Ask User Preferences

Present these choices using AskUserQuestion:

1. **Enforcement level**: "Which enforcement level do you prefer?"
   - **Strict (Recommended)** — All hooks active, pre-edit gate requires checklist
   - **Standard** — All hooks except pre-edit gate (no checklist required)
   - **Minimal** — Only secret-scan and deny-dummy (critical safety only)

2. **Language preference**: "What language should sentinel messages use?"
   - Auto-detect from system locale (Recommended)
   - English
   - Korean (한국어)
   - Japanese (日本語)

Apply the user's choices to config.json before writing.

## Step 6: Update Project `.gitignore`

Add to `.gitignore` (project root) if not already present:
```
# Sentinel runtime state
.sentinel/state/
.sentinel/error-log.jsonl
.sentinel/current-task.json
.sentinel/stats.json
```

## Step 7: Report Summary

```
✅ Sentinel initialized in [project-name]

Created:
  .sentinel/config.json    — project settings ([enforcement-level])
  .sentinel/.gitignore     — runtime state exclusions
  .sentinel/state/         — session state directory
  .sentinel/stats.json     — usage statistics

Detected:
  Project type: [Python/Node/Go/Rust/Multi]
  Linter: [ruff/eslint/golangci-lint]
  Extensions: [.py/.ts/.tsx/.js/.jsx/.go]
  Language: [auto/en/ko/ja]

Active enforcement:
  ✅ pre-edit-gate    — requires .sentinel/current-task.json before edits
  ✅ deny-dummy       — blocks placeholder/stub code
  ✅ surgical-change  — enforces minimal diffs
  ✅ scope-guard      — warns on scope reduction language
  ✅ secret-scan      — blocks hardcoded secrets
  ✅ file-header-check — suggests headers for 200+ line files
  ✅ env-safety       — blocks dangerous system commands
  ✅ error-logger     — tracks and warns on repeated errors

Next steps:
  1. Review .sentinel/config.json — adjust if needed
  2. Commit: git add .sentinel/config.json .sentinel/.gitignore && git commit -m "chore: add sentinel config"
  3. Start working — sentinel hooks enforce quality automatically
  4. Use /sentinel:check to verify compliance anytime
  5. Use /sentinel:header <file> to add headers to key files
```
