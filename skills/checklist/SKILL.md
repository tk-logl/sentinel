---
name: checklist
description: "Pre-implementation checklist workflow. Use before writing any source code to analyze impact, choose approach, and document blast radius. This is your blueprint — fill it with real analysis."
triggers:
  - "checklist"
  - "pre-implementation"
  - "pre-impl"
  - "before coding"
  - "task setup"
---

# Pre-Implementation Checklist

**This is not a checkbox exercise.** This is your implementation blueprint — a real analysis document that you fill with actual research before writing any code.

## When to Use

Before editing ANY source code file (.py, .ts, .tsx, .js, .jsx, .go, .rs, .java, .c, .cpp), you must create `.sentinel/current-task.json`. The pre-edit-gate hook will block edits without it.

## The Checklist File

Create `.sentinel/current-task.json` with ALL of these fields:

```json
{
  "task_id": "UNIQUE-ID",
  "why": "Business/quality reason for this change",
  "approach": "Chosen approach with reasoning (Option A because X, rejected Option B because Y)",
  "impact_files": [
    "path/to/file.py:function_name — description of impact",
    "path/to/other.ts:Component — imports changed module"
  ],
  "blast_radius": {
    "tests_break": ["test_name — why it breaks"],
    "tests_add": ["new_test_name — what it verifies"]
  },
  "verify_command": "pytest tests/test_module.py -x && npm run build"
}
```

## How to Fill Each Field (with real analysis, not placeholders)

### task_id
A unique identifier for this task. Use your project's convention (CRIT-1, FEAT-42, BUG-7) or create a descriptive one (fix-login-crash, add-rate-limit).

### why
**Not "because the audit said so."** State the actual business or quality reason:
- BAD: "Fix bug" / "Audit item" / "Needs fixing"
- GOOD: "Users get 500 error when clicking Save because PMRequest.get() doesn't exist on dataclasses"
- GOOD: "API endpoint leaks internal paths in error messages, violating OWASP information disclosure rules"

### approach
**Pick ONE approach, explain why, and document what you rejected:**

1. Research the options:
   - Read the current code
   - Check documentation for the framework/library
   - Consider 2-3 different ways to fix it

2. Choose one and justify:
   ```
   "Option A: Use attribute access (req.phase) instead of dict access (req.get('phase')).
    Reason: PMRequest is a dataclass, not a dict. Direct attribute access is correct.
    Rejected Option B: Convert PMRequest to dict first — unnecessary overhead, changes API contract.
    Band-aid check: This is root-cause fix — the dataclass was always a dataclass, the code was always wrong."
   ```

### impact_files
**Actually run the grep. Don't guess.**

```bash
# Find every file that imports/uses what you're changing
grep -rn "function_name" . --include="*.py"
grep -rn "from module import" . --include="*.py"
grep -rn "ComponentName" . --include="*.tsx"
```

Document each hit:
```json
"impact_files": [
  "main.py:3299 — only caller of get_request().get('phase')",
  "main.py:3301 — same block, also uses .get('session_id')",
  "tests/test_n8n.py:45 — test that calls this endpoint"
]
```

### blast_radius
**Run existing tests BEFORE making changes.** Record which pass now.

```json
"blast_radius": {
  "tests_break": [
    "test_n8n_status — currently passing, will need update for new attribute access"
  ],
  "tests_add": [
    "test_n8n_status_missing_request — tests behavior when no active request",
    "test_n8n_status_with_request — tests correct attribute access"
  ]
}
```

### verify_command
The exact command(s) that prove the change works:
```
"pytest tests/test_n8n.py -x && python3 -c \"import requests; r=requests.get('http://localhost:8443/api/n8n/status'); print(r.status_code, r.json())\""
```

## Workflow

1. **Read** the task requirement
2. **Research** the code — grep for all callers, read the affected files
3. **Analyze** the impact — who calls this, what breaks, what needs testing
4. **Write** `.sentinel/current-task.json` with your analysis
5. **Implement** the change (now the pre-edit-gate allows it)
6. **Verify** — run your verify_command
7. **Commit** — the task file is automatically cleaned up after successful commit

## Anti-Patterns (DO NOT DO)

- **Copy-paste the template without filling it**: Every field must have real analysis
- **Guess the impact**: Run grep. Read the code. Don't assume.
- **Skip the approach decision**: If you don't pick an approach explicitly, you'll make random choices during implementation
- **Forget blast_radius**: Run tests before AND after. Compare results.
- **Write "will add tests later"**: List the specific tests now. Implement them before claiming done.

## When You're Done

After committing the fix:
1. Run your verify_command one more time
2. Delete `.sentinel/current-task.json` (or let the commit hook clean it up)
3. The pre-edit-gate resets — ready for the next task
