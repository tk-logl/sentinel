---
name: header
description: "Generate or update a file header comment for the specified file"
args: "[file_path]"
---

# /sentinel:header [file_path]

Generate a structured file header for the specified source file.

## What to Do

1. **Read the target file** — understand its role, imports, exports
2. **Analyze co-modify relationships**:
   ```bash
   # Find files that change together (git log analysis)
   git log --oneline --name-only -- [file_path] | grep -E '\.(py|ts|tsx|js|jsx|go|rs)$' | sort | uniq -c | sort -rn | head -5

   # Find files that import from this file
   grep -rn "from.*$(basename [file_path] .py) import\|import.*$(basename [file_path] .py)" . --include="*.py" | head -5

   # Find files this file imports from
   grep -n "^import\|^from" [file_path] | head -10
   ```
3. **Identify invariants** — what must NEVER break in this file:
   - Security constraints (auth, sanitization, encryption)
   - Data integrity rules (validation, consistency)
   - Architectural contracts (API shapes, interfaces)
4. **Find verify commands** — how to test this file:
   - Look for test files: `test_$(basename).py`, `$(basename).test.ts`
   - Check package.json/pyproject.toml for test commands
5. **Generate the header** in the appropriate format for the file type
6. **Add it to the file** — insert at the very top (after shebang/encoding lines if present)

## Header Template

### Python
```python
"""
{filename} — {one-sentence role description}.

Co-modify: {2-4 related files}
Invariants:
  - {critical rule 1}
  - {critical rule 2}
  - {critical rule 3}
Verify: {test command}
"""
```

### TypeScript/JavaScript
```typescript
/**
 * {filename} — {one-sentence role description}.
 *
 * Co-modify: {2-4 related files}
 * Invariants:
 *   - {critical rule 1}
 *   - {critical rule 2}
 *   - {critical rule 3}
 * Verify: {test command}
 */
```

### Go
```go
// {filename} — {one-sentence role description}.
//
// Co-modify: {2-4 related files}
// Invariants:
//   - {critical rule 1}
//   - {critical rule 2}
// Verify: {test command}
```

## Rules

- Keep headers 5-12 lines (not longer)
- Role description must be specific, not generic
- Co-modify files must be real files that exist in the project
- Invariants must be behavioral (not style rules)
- Verify command must be copy-pasteable and runnable
- If file already has a header, UPDATE it — don't add a second one
