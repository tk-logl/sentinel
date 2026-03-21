---
name: mutate
description: "Run targeted mutation testing on specified files to validate test quality"
---

# /sentinel:mutate

Run mutation testing on specified source files to verify that tests actually catch bugs.

## What to Do

1. **Check if mutmut is installed**:
   ```bash
   python3 -m mutmut --version 2>/dev/null || pip install mutmut
   ```

2. **Determine target files**:
   - If the user specified files: use those
   - If not: find files changed since last commit:
     ```bash
     git diff --name-only HEAD~1 | grep '\.py$' | grep -v test_ | grep -v __pycache__
     ```

3. **Find corresponding test files** for each target:
   - `apps/{service}/module.py` → `apps/{service}/tests/test_module.py`
   - `voice/backend/module.py` → `voice/backend/tests/test_module.py`

4. **Run mutmut on each target file**:
   ```bash
   python3 -m mutmut run --paths-to-mutate=<target_file> --tests-dir=<test_dir>
   ```

5. **Report results**:
   - Show mutation score (killed / total)
   - List surviving mutants (these indicate weak tests)
   - For each survivor, show the mutation and which test should catch it

6. **Provide actionable guidance**:
   - For each surviving mutant, suggest a specific test assertion that would kill it
   - Example: "Mutant changed `>` to `>=` in line 42 — add a boundary test: `assert func(0) == expected`"

## Example Output

```
=== Mutation Testing Report ===
Target: apps/brain/services.py
Tests:  apps/brain/tests/test_services.py

Score: 47/50 killed (94%)

Surviving mutants:
  Line 42: changed > to >= in hybrid_search()
    → Add test: assert hybrid_search(query="x", top_k=0) raises ValueError
  
  Line 78: removed return statement in _normalize_score()
    → Add test: assert _normalize_score(0.5) == 0.5
  
  Line 95: changed True to False in is_valid_query()
    → Add test: assert is_valid_query("valid") == True
```

## Configuration

In `pyproject.toml`:
```toml
[tool.mutmut]
paths_to_mutate = "apps/"
backup = false
runner = "python -m pytest --tb=no -q"
mutate_only_covered_lines = true
```

## Notes
- Mutation testing is SLOW (minutes, not seconds) — this is a command, not a hook
- Only mutate changed files to keep run time practical (2-5 minutes)
- A mutation score below 70% means tests are not constraining behavior
- Target: 80%+ for core logic modules
