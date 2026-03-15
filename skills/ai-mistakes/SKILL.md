---
name: ai-mistakes
description: "Reference guide for 47 common AI coding mistake patterns. Use when you need to check code against known anti-patterns, or when reviewing changes for quality issues."
triggers:
  - "ai mistakes"
  - "common mistakes"
  - "mistake patterns"
  - "check patterns"
  - "anti-patterns"
  - "code review patterns"
---

# 47 AI Coding Mistake Patterns

A comprehensive catalog of mistakes that AI coding assistants frequently make. Organized by severity.

## How to Use This Guide

1. **During code review**: Check changed code against each applicable pattern
2. **Before claiming completion**: Verify none of these patterns are present in your work
3. **When debugging**: Check if the bug matches a known pattern
4. **When planning**: Design your approach to avoid these patterns from the start

---

## CRITICAL (12 patterns) — Must fix immediately. These cause production failures or security holes.

### #1 False Completion Claim
**Symptom**: Saying "done" or "complete" without running verification commands.
**Prevention**: ALWAYS run tests, build, and lint BEFORE claiming done. Show the output.
**Rule**: No completion claim without fresh command output as evidence.

### #2 Phantom Code Reference
**Symptom**: Importing or calling a function/class that doesn't exist.
**Prevention**: `grep -rn "function_name" .` before using any reference. Check imports resolve.
**Rule**: Every import must resolve to an actual file/module. Every function call must have a definition.

### #3 Silent Error Swallowing
**Symptom**: `except: pass`, `catch(e) {}`, ignoring error return values.
**Prevention**: Every error handler must log, re-raise, or explicitly handle the error condition.
**Rule**: No bare except, no empty catch blocks, no ignored errors.

### #4 Test That Tests Nothing
**Symptom**: `assert True`, `assert response is not None`, `expect(true).toBe(true)`.
**Prevention**: Every test must assert specific behavior — values, side effects, or state changes.
**Rule**: Each test function must have at least one meaningful assertion about business logic.

### #5 Abandoned Test Code
**Symptom**: Test files created but not included in test runner, or test code left in production.
**Prevention**: Run the test suite and verify your test file appears in the output.
**Rule**: Every test file must be discovered and run by the test runner.

### #6 Scope Reduction
**Symptom**: "for now", "basic version", "simplified" — delivering less than requested.
**Prevention**: Before starting, list every requirement. After finishing, check each one off.
**Rule**: Deliver 100% of what was asked. If scope must change, get explicit approval first.

### #7 Cascading Breakage
**Symptom**: Changed a function signature/behavior and broke all callers.
**Prevention**: `grep -rn "function_name" .` BEFORE editing. Fix all callers.
**Rule**: Before modifying any shared code, list all callers and update them.

### #8 Data Shape Mismatch
**Symptom**: API returns `{data: [...]}` but frontend expects `[...]`.
**Prevention**: Check both producer and consumer of every data structure.
**Rule**: Interface contracts must match between all layers.

### #9 Hardcoded Secrets
**Symptom**: API keys, passwords, tokens directly in source code.
**Prevention**: Use environment variables. Check with secret scanner.
**Rule**: Zero credentials in source code. All secrets via env vars.

### #10 Security Bypass
**Symptom**: `CORS: *`, `DEBUG=True` in prod, auth checks disabled "temporarily".
**Prevention**: Security settings must be environment-specific. Never disable globally.
**Rule**: Security controls are never optional, temporary, or conditional on DEBUG.

### #11 Working Code Deletion
**Symptom**: Replacing working code with new implementation instead of adding to it.
**Prevention**: Add checks/validation BEFORE existing code. Don't replace unless necessary.
**Rule**: Surgical changes only. Add before replace. Never delete without grep verification.

### #12 False Evidence
**Symptom**: Showing old test output as current, fabricating command results.
**Prevention**: Every verification must be run fresh in the current session.
**Rule**: All evidence must be from commands run NOW, not from history or memory.

---

## HIGH (22 patterns) — Should fix before merge. These cause bugs, performance issues, or maintenance problems.

### #13 Repeating Failed Approach
Trying the same fix 3+ times. Stop, read the error, try something different.

### #14 Configuration Drift
Dev, staging, and prod configs diverge silently. Use env-specific overrides from a shared base.

### #15 Missing Error Handling
Only the happy path works. Add timeout, retry, fallback, and error logging.

### #16 Type Coercion Bug
Implicit type conversions cause silent data corruption. Be explicit about types.

### #17 Race Condition
Shared mutable state without synchronization. Use locks, atomic operations, or message passing.

### #18 N+1 Query
One query per item in a loop. Use select_related, prefetch_related, JOINs.

### #19 Memory Leak
Event listeners, caches, connections that grow forever. Add cleanup and eviction.

### #20 Encoding Mismatch
UTF-8 vs Latin-1, URL encoding, JSON escaping. Be explicit about encoding at boundaries.

### #21 Off-by-One
Array bounds, pagination, date ranges. Test boundary values explicitly.

### #22 Null Reference
Accessing properties on null/undefined. Add null checks or use optional chaining.

### #23 Import Cycle
Module A imports B, B imports A. Restructure to break the cycle.

### #24 Dead Code
Unreachable branches, unused functions. Delete them — they confuse readers.

### #25 Inconsistent Naming
Same concept with different names. Pick one name and use it everywhere.

### #26 Missing Index
Queries on unindexed columns cause full table scans. Add indexes for common queries.

### #27 Unsafe Deserialization
Pickle.loads, eval(), untrusted JSON.parse without validation. Validate before deserializing.

### #28 Path Traversal
User input in file paths. Use `pathlib.resolve()` and `is_relative_to()`.

### #29 SQL/Command Injection
String interpolation in queries. Use parameterized queries and subprocess lists.

### #30 SSRF
User-controlled URLs in server requests. Validate and whitelist allowed hosts.

### #31 Missing Rate Limit
Public endpoints without throttling. Add rate limiting per user/IP.

### #32 Broken Migration
Schema change without data migration. Test migrate forward AND backward.

### #33 Timezone Bug
Naive datetime mixing with aware datetime. Always use UTC internally.

### #34 Resource Exhaustion
Unbounded loops, unlimited uploads, no pagination. Add limits to everything.

---

## MEDIUM (13 patterns) — Consider fixing. These affect maintainability and developer experience.

### #35 Over-Engineering
Abstraction for a single use case. Keep it simple until you have 3+ use cases.

### #36 God Object
Single file doing everything. Split by responsibility when it exceeds 500 lines.

### #37 Magic Numbers
Unexplained constants. Create named variables: `MAX_RETRIES = 3`.

### #38 Copy-Paste Code
Duplicated logic. Extract shared code when pattern repeats 3+ times.

### #39 Missing Logging
No logs at decision points. Add structured logging at boundaries and error paths.

### #40 Inconsistent Error Format
Different error shapes across endpoints. Standardize: `{error, message, details}`.

### #41 Missing Validation
User input accepted without checks. Validate at system boundaries.

### #42 Stale Comment
Comment describes old behavior. Update or delete when code changes.

### #43 Missing Cleanup
Temp files, connections, listeners not cleaned up. Add finally/defer/cleanup handlers.

### #44 Version Pinning
Dependencies without version pins. Pin exact versions for reproducibility.

### #45 Missing Docs
Public API without examples. Add usage examples for every public function.

### #46 Platform Assumption
Hardcoded paths, OS-specific code. Use os.path, platform detection, env vars.

### #47 Context Window Waste
Reading entire files when grep suffices. Use targeted searches, not bulk reads.
