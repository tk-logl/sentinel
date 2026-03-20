#!/usr/bin/env node
'use strict';
/**
 * Sentinel PostToolUse Hook: TypeScript/JS AST Quality Gate (BLOCKING)
 *
 * Analyzes TypeScript/JavaScript/JSX/TSX files using the TypeScript compiler API
 * to detect empty or incomplete function implementations. AST-based analysis
 * cannot be bypassed by adding comments, changing whitespace, or renaming variables.
 *
 * Detects:
 * - Empty function/method bodies: function foo() {}
 * - Return-only no-ops: return / return null / return undefined / return '' / return {} / return []
 * - throw new Error("Not implemented") or similar unimplemented markers
 * - Arrow function no-ops: () => null, () => undefined, () => {}, () => ''
 * - console.log-only functions (common AI coding anti-pattern)
 * - void expression no-ops: () => void 0
 * - Empty JSX fragment returns: () => <></>
 *
 * Parser: TypeScript compiler API (ts.createSourceFile)
 * Resolution: walk up from file -> git root subdirs -> global
 * If TypeScript compiler not found -> exit 0 (cannot analyze without parser)
 *
 * Exit 2 = DENY (force fix) | Exit 0 = ALLOW
 */

const fs = require('fs');
const pathMod = require('path');

// --- Read hook input from stdin ---
let input;
try {
  input = JSON.parse(fs.readFileSync(0, 'utf-8'));
} catch {
  process.exit(0);
}

const toolName = input.tool_name || '';
if (toolName !== 'Write' && toolName !== 'Edit') process.exit(0);

const filePath = (input.tool_input || {}).file_path || '';
if (!filePath) process.exit(0);

const ext = pathMod.extname(filePath).toLowerCase();
if (!['.ts', '.tsx', '.js', '.jsx', '.mjs', '.cjs'].includes(ext)) process.exit(0);

// Skip test/config/generated/declaration files
const SKIP = [
  '/test_', '.test.', '.spec.', '/tests/', '/__tests__/', '/__mocks__/',
  'node_modules', '.sentinel', '.claude', '.omc',
  '/migrations/', '/fixtures/', '/mocks/', '.d.ts',
  '/dist/', '/build/', '/coverage/', '.min.js', '.min.mjs',
];
if (SKIP.some(p => filePath.includes(p))) process.exit(0);

// --- Find TypeScript compiler ---
function findTS() {
  const tryReq = (p) => { try { return require(p); } catch { return null; } };

  // 1. Walk up from the file being edited
  let dir = pathMod.dirname(pathMod.resolve(filePath));
  const seen = new Set();
  while (dir && dir !== pathMod.dirname(dir) && !seen.has(dir)) {
    seen.add(dir);
    const r = tryReq(pathMod.join(dir, 'node_modules', 'typescript'));
    if (r) return r;
    dir = pathMod.dirname(dir);
  }

  // 2. cwd from hook input
  if (input.cwd) {
    const r = tryReq(pathMod.join(input.cwd, 'node_modules', 'typescript'));
    if (r) return r;
  }

  // 3. git root + common monorepo subdirs
  try {
    const { execSync } = require('child_process');
    const root = execSync('git rev-parse --show-toplevel', {
      encoding: 'utf-8', stdio: ['pipe', 'pipe', 'pipe'],
    }).trim();
    for (const sub of ['', 'frontend', 'client', 'web', 'app', 'packages']) {
      const r = tryReq(pathMod.join(root, sub, 'node_modules', 'typescript'));
      if (r) return r;
    }
  } catch { /* no git root */ }

  // 4. Global typescript
  return tryReq('typescript');
}

const ts = findTS();
if (!ts) {
  // No TypeScript compiler available — cannot perform AST analysis.
  // Python files are handled by ast-quality-gate.py.
  process.exit(0);
}

// --- Names that are legitimately empty (lifecycle, teardown, serialization) ---
const NOOP = new Set([
  'constructor',
  // React lifecycle
  'componentDidMount', 'componentWillUnmount', 'componentDidUpdate',
  'componentDidCatch', 'getDerivedStateFromProps', 'shouldComponentUpdate',
  'getSnapshotBeforeUpdate', 'UNSAFE_componentWillMount',
  'UNSAFE_componentWillReceiveProps', 'UNSAFE_componentWillUpdate',
  // Angular lifecycle
  'ngOnInit', 'ngOnDestroy', 'ngAfterViewInit', 'ngOnChanges',
  'ngDoCheck', 'ngAfterContentInit', 'ngAfterContentChecked', 'ngAfterViewChecked',
  // Vue lifecycle
  'mounted', 'unmounted', 'created', 'beforeDestroy', 'beforeUnmount',
  // Test lifecycle
  'setUp', 'tearDown', 'beforeAll', 'afterAll', 'beforeEach', 'afterEach',
  // Common no-op patterns
  'setup', 'teardown', 'cleanup', 'close', 'dispose', 'destroy', 'reset',
  'finalize', 'free', 'handleClose', 'onClose', 'onDestroy',
  // Serialization
  'toString', 'valueOf', 'toJSON', 'Symbol.iterator',
]);

// --- Detection: is this expression an empty/no-op value? ---
function isNoopExpr(expr) {
  if (!expr) return 'empty';
  // Unwrap parenthesized expressions: () => ({}) or () => (null)
  while (ts.isParenthesizedExpression && ts.isParenthesizedExpression(expr)) {
    expr = expr.expression;
  }
  switch (expr.kind) {
    case ts.SyntaxKind.NullKeyword: return 'null';
    case ts.SyntaxKind.FalseKeyword: return 'false';
    case ts.SyntaxKind.VoidExpression: return 'void 0';
  }
  if (ts.isIdentifier(expr) && expr.text === 'undefined') return 'undefined';
  if (ts.isNumericLiteral(expr) && expr.text === '0') return '0';
  if (ts.isStringLiteral(expr) && expr.text === '') return "''";
  if (ts.isNoSubstitutionTemplateLiteral && ts.isNoSubstitutionTemplateLiteral(expr) && expr.text === '') return '``';
  if (ts.isObjectLiteralExpression(expr) && expr.properties.length === 0) return '{}';
  if (ts.isArrayLiteralExpression(expr) && expr.elements.length === 0) return '[]';
  if (ts.isJsxFragment && ts.isJsxFragment(expr)) {
    if (!expr.children || expr.children.length === 0) return '<></>';
    const nonEmpty = expr.children.filter(c =>
      !(ts.isJsxText && ts.isJsxText(c) && c.text.trim() === '')
    );
    if (nonEmpty.length === 0) return '<></>';
  }
  return null;
}

// --- Detection: throw new Error("Not implemented") pattern ---
function isUnimplementedThrow(stmt) {
  if (!ts.isThrowStatement(stmt) || !stmt.expression) return false;
  if (!ts.isNewExpression(stmt.expression)) return false;
  const ctor = stmt.expression.expression;
  let name = '';
  if (ts.isIdentifier(ctor)) name = ctor.text;
  else if (ts.isPropertyAccessExpression(ctor)) name = ctor.name.text;
  if (!['Error', 'NotImplementedError', 'NotImplemented', 'TypeError'].includes(name)) return false;
  // Single throw new Error() as the only statement = unimplemented function
  return true;
}

// --- Detection: console.log-only body ---
function isConsoleOnly(stmt) {
  if (!ts.isExpressionStatement(stmt)) return false;
  if (!ts.isCallExpression(stmt.expression)) return false;
  const access = stmt.expression.expression;
  if (!ts.isPropertyAccessExpression(access)) return false;
  if (!ts.isIdentifier(access.expression)) return false;
  return access.expression.text === 'console';
}

// --- Name extraction ---
function getName(node) {
  if (node.name) {
    const t = node.name.text || node.name.escapedText;
    if (t) return t;
  }
  const p = node.parent;
  if (p) {
    if (ts.isVariableDeclaration(p) && p.name) return p.name.text || p.name.escapedText || '';
    if (ts.isPropertyDeclaration(p) && p.name) return p.name.text || p.name.escapedText || '';
    if (ts.isPropertyAssignment(p) && p.name) return p.name.text || p.name.escapedText || '';
    if (ts.isExportAssignment && ts.isExportAssignment(p)) return 'default';
  }
  return '<anonymous>';
}

// --- Main analysis ---
function analyzeFile(targetPath) {
  let source;
  try { source = fs.readFileSync(targetPath, 'utf-8'); } catch { return []; }

  const kindMap = {
    '.tsx': ts.ScriptKind.TSX,
    '.jsx': ts.ScriptKind.JSX,
    '.ts': ts.ScriptKind.TS,
    '.mjs': ts.ScriptKind.JS,
    '.cjs': ts.ScriptKind.JS,
  };
  const kind = kindMap[ext] || ts.ScriptKind.JS;

  let sf;
  try {
    sf = ts.createSourceFile(targetPath, source, ts.ScriptTarget.Latest, true, kind);
  } catch { return []; }

  const violations = [];

  function visit(node) {
    const isFn = ts.isFunctionDeclaration(node) || ts.isMethodDeclaration(node) ||
                 ts.isFunctionExpression(node) || ts.isArrowFunction(node);

    if (isFn) {
      const name = getName(node);

      // Skip lifecycle / teardown / serialization methods
      if (NOOP.has(name)) { ts.forEachChild(node, visit); return; }

      // Skip abstract / declare
      if (node.modifiers) {
        for (const m of node.modifiers) {
          if (m.kind === ts.SyntaxKind.AbstractKeyword ||
              m.kind === ts.SyntaxKind.DeclareKeyword) {
            ts.forEachChild(node, visit);
            return;
          }
        }
      }

      // Skip getters/setters (often legitimately minimal)
      if (node.kind === ts.SyntaxKind.GetAccessor || node.kind === ts.SyntaxKind.SetAccessor) {
        ts.forEachChild(node, visit);
        return;
      }

      const body = node.body;
      if (!body) { ts.forEachChild(node, visit); return; } // declaration / overload

      const line = sf.getLineAndCharacterOfPosition(node.getStart(sf)).line + 1;

      // Arrow function with expression body: () => null
      if (!ts.isBlock(body)) {
        const noop = isNoopExpr(body);
        if (noop) {
          violations.push(`  Line ${line}: ${name}() arrow returns ${noop} (no-op)`);
        }
        ts.forEachChild(node, visit);
        return;
      }

      // Block body
      const stmts = Array.from(body.statements);

      // Filter 'use strict' and bare string literal expression statements
      const real = stmts.filter(s =>
        !(ts.isExpressionStatement(s) && ts.isStringLiteral(s.expression))
      );

      if (real.length === 0) {
        violations.push(`  Line ${line}: ${name}() has empty body`);
      } else if (real.length === 1) {
        const s = real[0];

        // return <no-op value>
        if (ts.isReturnStatement(s)) {
          if (!s.expression) {
            violations.push(`  Line ${line}: ${name}() has only 'return' (no value)`);
          } else {
            const noop = isNoopExpr(s.expression);
            if (noop) {
              violations.push(`  Line ${line}: ${name}() has only 'return ${noop}' (no-op)`);
            }
          }
        }
        // throw new Error("Not implemented")
        else if (isUnimplementedThrow(s)) {
          violations.push(`  Line ${line}: ${name}() has only 'throw new Error(...)' (unimplemented)`);
        }
        // console.log only
        else if (isConsoleOnly(s)) {
          const access = s.expression.expression;
          const method = ts.isPropertyAccessExpression(access) ? access.name.text : 'log';
          violations.push(`  Line ${line}: ${name}() has only console.${method}() (no-op)`);
        }
      }
    }

    ts.forEachChild(node, visit);
  }

  visit(sf);
  return violations;
}

// --- Execute ---
const violations = analyzeFile(filePath);

if (violations.length > 0) {
  const name = pathMod.basename(filePath);
  process.stderr.write(`\u26d4 [Sentinel AST-Gate-TS] Incomplete code in: ${name}\n`);
  process.stderr.write('\n');
  process.stderr.write('Violations:\n');
  for (const v of violations) {
    process.stderr.write(v + '\n');
  }
  process.stderr.write('\n');
  process.stderr.write('Every function must have a real implementation.\n');
  process.stderr.write('AST analysis detected empty function bodies \u2014 comment tricks will NOT bypass this.\n');
  process.stderr.write('\u2192 Write actual logic, then retry.\n');
  process.exit(2);
}

process.exit(0);
