---
name: file-headers
description: "Generate and manage file header comments for key source files. Headers describe the file's role, co-modify files, invariants, and verification commands. Use for files over 200 lines."
triggers:
  - "file header"
  - "add header"
  - "generate header"
  - "update header"
---

# File Header System

Short, structured comments at the top of key source files that capture critical context.

## Why Headers Exist

When AI assistants (or developers) edit a file, they often don't know:
- What this file's actual role is in the system
- Which other files MUST change together with it
- What invariants must never be broken
- How to verify changes work

Headers solve this in 5-12 lines, saving investigation time and preventing mistakes.

## When to Add Headers

- Files over 200 lines (configurable in sentinel.json: `header_threshold_lines`)
- Files that are frequently co-modified with others
- Files containing critical business logic or security code
- Entry points (main.py, app.ts, index.js)

## Header Format

### Python
```python
"""
main.py — FastAPI application server with LLM routing and PM Engine integration.

Co-modify: pm_engine/engine.py, pm_engine/dispatcher.py, commands.py
Invariants:
  - All SSE endpoints must use ticket-based auth (never token in URL)
  - LLM responses must stream via StreamingResponse, never buffered
  - Session objects must be cleaned up on disconnect
Verify: pytest tests/test_main.py -x && curl -s localhost:8443/health | jq .status
"""
```

### TypeScript/JavaScript
```typescript
/**
 * App.tsx — Root application component with routing and theme management.
 *
 * Co-modify: stores/authStore.ts, services/api.ts, components/layout/MainLayout.tsx
 * Invariants:
 *   - AuthProvider must wrap all routes (no unauthenticated renders)
 *   - Theme CSS variables must be set before first paint (no flash)
 *   - Error boundary must catch all route-level errors
 * Verify: npm run build && npm run test -- --run
 */
```

### Go
```go
// server.go — HTTP server with middleware chain and graceful shutdown.
//
// Co-modify: middleware/auth.go, handlers/api.go, config/config.go
// Invariants:
//   - Shutdown must drain all active connections (30s timeout)
//   - Auth middleware must run before any handler (middleware order matters)
//   - Config must be loaded before server starts (no lazy init)
// Verify: go test ./... && go build ./cmd/server
```

### Rust
```rust
//! engine.rs — Core processing engine with async pipeline and error recovery.
//!
//! Co-modify: pipeline/mod.rs, error.rs, config.rs
//! Invariants:
//!   - Pipeline stages must be idempotent (safe to retry)
//!   - Errors must propagate with context (never lose the original cause)
//!   - Resource cleanup must happen in Drop (not just on success path)
//! Verify: cargo test && cargo clippy -- -D warnings
```

## Header Fields

### Role (line 1)
`filename — One sentence describing what this file does and its place in the system.`

Keep it specific:
- BAD: "Utility functions" / "Helper module" / "Main file"
- GOOD: "FastAPI application server with LLM routing and PM Engine integration"
- GOOD: "Redux store for authentication state with token refresh logic"

### Co-modify (required)
List 2-4 files that almost always change together with this one:
- If you change the model → change the serializer, view, and test
- If you change the API handler → change the frontend service and types
- If you change the config → change the deployment and docs

### Invariants (required)
2-3 rules that must NEVER be broken, no matter what changes are made:
- These are the "if you break this, the system fails" rules
- Focus on security, data integrity, and architectural contracts
- Not style rules — only critical behavioral requirements

### Verify (required)
1-2 commands that prove changes to this file work correctly:
- Must be copy-pasteable (no placeholders)
- Should run fast (< 30 seconds)
- Should catch the most common failure modes

## Generating Headers

### Manual
Read the file, understand its role, write the header yourself.

### Using /sentinel:header
```
/sentinel:header path/to/file.py
```
This command analyzes the file and generates a header based on:
1. The file's imports (determines dependencies)
2. The file's exports (determines role)
3. Git log (determines co-modify files — which files change in the same commits)
4. Test files (determines verify commands)

## Maintenance

Headers should be updated when:
- The file's role changes significantly
- New co-modify relationships are discovered
- Invariants change (new security requirements, architectural changes)
- Verify commands change (new test runner, different test file)

The `file-header-check.sh` hook will remind you to add headers to large files that don't have them.
