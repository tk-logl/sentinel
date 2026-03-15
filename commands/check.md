---
name: check
description: "Run a comprehensive rule compliance check on the current project"
---

# /sentinel:check

Scan the current project for rule violations and generate a compliance report.

## What to Do

1. **Find all source files** in the project (py, ts, tsx, js, jsx, go, rs, java, c, cpp)
2. **Skip**: test files, node_modules, __pycache__, .sentinel/, .claude/, .omc/
3. **Check each file for**:
   - Standalone `pass` without @abstractmethod
   - `raise NotImplementedError` without @abstractmethod
   - TODO/FIXME/PLACEHOLDER/HACK comments
   - Hardcoded secrets (sk-, ghp_, AKIA, xoxb-)
   - `print()` or `console.log()` debug statements
   - Missing type hints (Python: def without ->)
   - Bare `except:` or empty `catch {}`
   - `assert True` or meaningless assertions
   - Files over 200 lines without headers
4. **Check git status** for uncommitted changes
5. **Check for .sentinel/current-task.json** — is there an active task?
6. **Check error log** for repeated failures

## Output Format

```markdown
## Sentinel Compliance Report

**Project**: [project name]
**Branch**: [current branch]
**Files scanned**: [count]
**Date**: [timestamp]

### Summary
- CRITICAL violations: [count]
- HIGH violations: [count]
- MEDIUM warnings: [count]
- Files needing headers: [count]

### Violations

#### CRITICAL
- `path/to/file.py:45` — Hardcoded API key (sk-abc...)
- `path/to/views.py:12` — Bare except: pass (silent error swallowing)

#### HIGH
- `path/to/main.py:200` — Missing type hints on 5 functions
- `path/to/utils.js:30` — console.log debug statement

#### MEDIUM
- `path/to/config.py:1` — No file header (350 lines)

### Status
- Active task: [task_id or "none"]
- Uncommitted changes: [count]
- Recent errors: [summary]

### Recommendation
[Actionable next steps based on findings]
```
