---
name: init
description: "Initialize sentinel in the current project — creates .sentinel/ directory and configuration"
---

# /sentinel:init

Set up sentinel enforcement in the current project.

## What to Do

1. **Create `.sentinel/` directory** in the project root:
   ```
   .sentinel/
   ├── state/           # Session state archives
   ├── config.json      # Project-specific settings (optional overrides)
   └── .gitignore       # Ignore state files, keep config
   ```

2. **Create `.sentinel/.gitignore`**:
   ```
   # Sentinel runtime state — not committed
   state/
   error-log.jsonl
   current-task.json
   agent-results/
   ```

3. **Create `.sentinel/config.json`** with project defaults:
   ```json
   {
     "language": "auto",
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

4. **Detect project type** and customize:
   - Python project (pyproject.toml/setup.py): add `"py"` extensions, set linter to ruff
   - Node project (package.json): add `"ts", "tsx", "js", "jsx"`, set linter to eslint
   - Go project (go.mod): add `"go"`, set linter to golangci-lint
   - Rust project (Cargo.toml): add `"rs"`, set linter to clippy

5. **Add to .gitignore** (project root) if not already present:
   ```
   .sentinel/state/
   .sentinel/error-log.jsonl
   .sentinel/current-task.json
   ```

6. **Report** what was created and suggest next steps:
   ```
   Sentinel initialized in [project].

   Created:
     .sentinel/config.json — project settings
     .sentinel/.gitignore — runtime state exclusions
     .sentinel/state/ — session state directory

   Next steps:
     1. Review .sentinel/config.json and adjust settings
     2. Commit: git add .sentinel/config.json .sentinel/.gitignore && git commit -m "chore: add sentinel config"
     3. Start working — sentinel hooks are now active
   ```
