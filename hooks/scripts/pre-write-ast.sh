#!/bin/bash
# Sentinel PreToolUse Hook: Pre-Write AST Gate (BLOCKING)
# Analyzes Write content BEFORE it hits disk using AST parsing.
# Catches placeholder/stub code at the source — the file is never written with bad code.
# For Edit operations, PostToolUse AST gates handle analysis after the edit is applied.
#
# Self-contained: uses plugin's vendored TypeScript (no project dependencies needed).
# Python AST: uses stdlib ast module (always available).
#
# Exit 2 = DENY | Exit 0 = ALLOW

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/_common.sh"
sentinel_require_jq "pre-write-ast" "blocking"
sentinel_compat_check "pre_write_ast"

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

# Only analyze Write operations (full file content available)
# Edit operations only have the replacement fragment — not valid code on its own
if [[ "$TOOL_NAME" != "Write" ]]; then
  exit 0
fi

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[[ -z "$FILE_PATH" ]] && exit 0

# Only check source code files
if ! sentinel_is_source_file "$FILE_PATH"; then
  exit 0
fi

# Skip test/config files
if sentinel_should_skip "$FILE_PATH"; then
  exit 0
fi

# Skip enforcement tools
BASENAME=$(basename "$FILE_PATH")
case "$BASENAME" in
  *gate*|*guard*|*scan*|*check*|*verify*|*lint*|*analyz*|*detect*|*enforc*) exit 0 ;;
esac
case "$FILE_PATH" in
  */sentinel/*|*/.claude/plugins/*|*/.claude/hooks/*) exit 0 ;;
esac

# Check per-item action
ACTION=$(sentinel_get_action "codeQuality" "pre_write_ast" "block")
[[ "$ACTION" == "off" ]] && exit 0

# Extract content from tool_input
CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // empty' 2>/dev/null)
[[ -z "$CONTENT" ]] && exit 0

# Determine file extension
EXT="${FILE_PATH##*.}"

# Create temp file with correct extension for AST parsing
TMPFILE=$(mktemp "${TMPDIR:-/tmp}/sentinel-pre-ast-XXXXXX.${EXT}")
trap 'rm -f "$TMPFILE"' EXIT
echo "$CONTENT" > "$TMPFILE"

VIOLATIONS=""

# --- Python AST analysis ---
if [[ "$EXT" == "py" ]]; then
  # Use inline Python AST analysis (stdlib — no dependencies)
  # Pass temp file path as argv[1] to avoid shell injection via path characters
  VIOLATIONS=$(python3 - "$TMPFILE" <<'PYEOF'
import ast, sys

tmpfile = sys.argv[1]
source = open(tmpfile, 'r').read()
try:
    tree = ast.parse(source)
except SyntaxError:
    sys.exit(0)

# Canonical noop names (unified with ast-quality-gate.py + ast-quality-gate-ts.js)
NOOP = {
    '__del__','__repr__','__str__','__hash__',
    '__enter__','__exit__','__aenter__','__aexit__',
    '__init_subclass__','__class_getitem__',
    'setUp','tearDown','setUpClass','tearDownClass',
    'setup','teardown','setup_method','teardown_method',
    'cleanup','close','dispose','destroy','reset',
    'finalize','free','shutdown','stop',
    'handleClose','onClose','onDestroy',
    'componentDidMount','componentWillUnmount','componentDidUpdate',
    'componentDidCatch','getDerivedStateFromProps','shouldComponentUpdate',
    'getSnapshotBeforeUpdate',
    'ngOnInit','ngOnDestroy','ngAfterViewInit','ngOnChanges',
    'ngDoCheck','ngAfterContentInit','ngAfterContentChecked','ngAfterViewChecked',
    'mounted','unmounted','created','beforeDestroy','beforeUnmount',
    'toString','valueOf','toJSON',
    'configure','register','emit','on',
}

# Only these decorators excuse empty implementations
EXEMPT_DECORATORS = {'abstractmethod', 'overload', 'override'}

violations = []
for node in ast.walk(tree):
    if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
        continue
    name = node.name
    if name in NOOP:
        continue
    # Skip dunder methods only (NOT all underscore-prefixed)
    if name.startswith('__') and name.endswith('__'):
        continue
    # Only skip functions with exempt decorators
    dec_names = set()
    for dec in node.decorator_list:
        if isinstance(dec, ast.Name):
            dec_names.add(dec.id)
        elif isinstance(dec, ast.Attribute):
            dec_names.add(dec.attr)
    if dec_names.intersection(EXEMPT_DECORATORS):
        continue

    body = node.body
    # Filter docstrings
    real = [s for s in body if not (isinstance(s, ast.Expr) and isinstance(s.value, (ast.Constant, ast.Str)))]

    line = node.lineno

    if len(real) == 0:
        # Empty body or docstring-only
        if any(isinstance(s, ast.Expr) and isinstance(s.value, (ast.Constant, ast.Str)) for s in body):
            violations.append(f'  Line {line}: {name}() has only a docstring (no implementation)')
        else:
            violations.append(f'  Line {line}: {name}() has empty body')
    elif len(real) == 1:
        s = real[0]
        # pass
        if isinstance(s, ast.Pass):
            violations.append(f'  Line {line}: {name}() has only pass (no implementation)')
        # return None / return
        elif isinstance(s, ast.Return):
            if s.value is None:
                violations.append(f'  Line {line}: {name}() has only bare return (no-op)')
            elif isinstance(s.value, ast.Constant) and s.value.value is None:
                violations.append(f'  Line {line}: {name}() has only return None (no-op)')
        # raise NotImplementedError
        elif isinstance(s, ast.Raise) and s.exc:
            exc = s.exc
            if isinstance(exc, ast.Call) and hasattr(exc.func, 'id') and exc.func.id in ('NotImplementedError', 'NotImplemented'):
                violations.append(f'  Line {line}: {name}() has only raise NotImplementedError (unimplemented)')
            elif isinstance(exc, ast.Name) and exc.id in ('NotImplementedError', 'NotImplemented'):
                violations.append(f'  Line {line}: {name}() has only raise NotImplementedError (unimplemented)')

    # Hollow: function with 2+ params that ignores all of them and returns a literal
    params = [a.arg for a in node.args.args if a.arg != 'self' and a.arg != 'cls']
    if len(params) >= 2 and len(real) == 1 and isinstance(real[0], ast.Return) and real[0].value is not None:
        ret = real[0].value
        # Collect all Name nodes in the return expression
        used = {n.id for n in ast.walk(ret) if isinstance(n, ast.Name)}
        if not any(p in used for p in params):
            if isinstance(ret, ast.Constant):
                violations.append(f'  Line {line}: {name}() ignores all {len(params)} params, returns hardcoded {repr(ret.value)}')

if violations:
    for v in violations:
        print(v)
PYEOF
  )
fi

# --- TypeScript/JavaScript AST analysis ---
if [[ "$EXT" == "ts" || "$EXT" == "tsx" || "$EXT" == "js" || "$EXT" == "jsx" || "$EXT" == "mjs" || "$EXT" == "cjs" ]]; then
  # Construct fake hook input pointing to temp file, reuse ast-quality-gate-ts.js logic
  FAKE_INPUT=$(echo "$INPUT" | jq --arg fp "$TMPFILE" '.tool_input.file_path = $fp')
  TS_RESULT=$(echo "$FAKE_INPUT" | node "$SCRIPT_DIR/ast-quality-gate-ts.js" 2>&1)
  TS_EXIT=$?
  if [[ $TS_EXIT -eq 2 ]]; then
    # Extract violations from stderr output
    TS_VIOLATIONS=$(echo "$TS_RESULT" | grep '^\s*Line ' || true)
    if [[ -n "$TS_VIOLATIONS" ]]; then
      VIOLATIONS="${VIOLATIONS}${TS_VIOLATIONS}"
    fi
  fi
fi

if [[ -n "$VIOLATIONS" ]]; then
  if [[ "$ACTION" == "block" ]]; then
    {
      echo "⛔ [Sentinel Pre-Write AST] Incomplete code detected BEFORE write: $(basename "$FILE_PATH")"
      echo ""
      echo "Violations:"
      echo "$VIOLATIONS"
      echo ""
      echo "The file was NOT written. AST analysis caught placeholder code before it reached disk."
      echo "→ Write actual implementation, then retry."
    } >&2
    sentinel_stats_increment "blocks"
    sentinel_stats_increment "pattern_pre_write_ast"
    exit 2
  else
    echo "⚠️ [Sentinel Pre-Write AST] Code quality warnings: $(basename "$FILE_PATH")"
    echo ""
    echo "$VIOLATIONS"
    sentinel_stats_increment "warnings"
  fi
fi

sentinel_stats_increment "checks"
exit 0
