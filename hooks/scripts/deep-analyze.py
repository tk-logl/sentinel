#!/usr/bin/env python3
"""
Sentinel Deep Pattern Analyzer — Python AST + heuristic detection.
Catches patterns that bash grep cannot: N+1 queries, race conditions,
resource leaks, dead imports, unsafe patterns, etc.

Usage:
  echo "$CONTENT" | python3 deep-analyze.py --mode pre --ext py
  python3 deep-analyze.py --mode post --file path/to/file.py
"""
from __future__ import annotations

import ast
import argparse
import re
import sys
from pathlib import Path


def analyze_python_ast(source: str, filename: str = "<stdin>") -> list[str]:
    violations = []
    try:
        tree = ast.parse(source, filename=filename)
    except SyntaxError:
        return violations

    imported_names: dict[str, int] = {}
    used_names: set[str] = set()
    function_count = 0
    class_method_counts: dict[str, int] = {}

    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                name = alias.asname or alias.name.split(".")[0]
                imported_names[name] = node.lineno
        elif isinstance(node, ast.ImportFrom):
            if node.module and node.names:
                for alias in node.names:
                    if alias.name == "*":
                        continue
                    name = alias.asname or alias.name
                    imported_names[name] = node.lineno
        elif isinstance(node, ast.Name):
            used_names.add(node.id)
        elif isinstance(node, ast.Attribute):
            if isinstance(node.value, ast.Name):
                used_names.add(node.value.id)
        elif isinstance(node, ast.For):
            _check_n_plus_one(node, violations)
        elif isinstance(node, ast.Assign):
            _check_open_without_context(node, violations)
        elif isinstance(node, ast.Call):
            _check_open_encoding(node, violations)
            _check_unsafe_calls(node, violations)
        elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            function_count += 1
        elif isinstance(node, ast.ClassDef):
            method_count = sum(
                1 for item in node.body
                if isinstance(item, (ast.FunctionDef, ast.AsyncFunctionDef))
            )
            class_method_counts[node.name] = method_count

    # #24 Dead Code: unused imports
    for name, lineno in imported_names.items():
        if name not in used_names and name != "_" and not name.startswith("__"):
            if name not in ("annotations", "TYPE_CHECKING"):
                violations.append(
                    f"L{lineno}: Unused import '{name}' — remove or use it [Pattern #24 Dead Code]"
                )

    # #36 God Object
    for cls_name, count in class_method_counts.items():
        if count > 20:
            violations.append(
                f"Class '{cls_name}' has {count} methods — consider splitting [Pattern #36 God Object]"
            )

    lines = source.count("\n") + 1
    if lines > 500 and function_count > 30:
        violations.append(f"File has {lines} lines and {function_count} functions — decompose [Pattern #36]")

    return violations


def _check_n_plus_one(node: ast.For, violations: list[str]) -> None:
    for child in ast.walk(node):
        if isinstance(child, ast.Call):
            func = child.func
            if isinstance(func, ast.Attribute) and func.attr in ("filter", "get", "all", "exclude", "values", "values_list"):
                if isinstance(func.value, ast.Attribute) and func.value.attr == "objects":
                    violations.append(
                        f"L{child.lineno}: .objects.{func.attr}() inside loop — use select_related/prefetch_related [Pattern #18 N+1 Query]"
                    )
            if isinstance(func, ast.Attribute) and func.attr in ("execute", "raw"):
                violations.append(f"L{child.lineno}: DB query inside loop — batch or prefetch [Pattern #18]")


def _check_open_without_context(node: ast.Assign, violations: list[str]) -> None:
    if isinstance(node.value, ast.Call):
        func = node.value.func
        if isinstance(func, ast.Name) and func.id == "open":
            violations.append(f"L{node.lineno}: open() assigned without 'with' — use context manager [Pattern #19 Resource Leak]")
        elif isinstance(func, ast.Attribute) and func.attr == "open":
            violations.append(f"L{node.lineno}: .open() without 'with' — use context manager [Pattern #19]")


def _check_open_encoding(node: ast.Call, violations: list[str]) -> None:
    func = node.func
    is_open = (isinstance(func, ast.Name) and func.id == "open") or (
        isinstance(func, ast.Attribute) and func.attr == "open"
    )
    if not is_open:
        return
    for kw in node.keywords:
        if kw.arg == "mode" and isinstance(kw.value, ast.Constant):
            if "b" in str(kw.value.value):
                return
    if len(node.args) >= 2 and isinstance(node.args[1], ast.Constant):
        if "b" in str(node.args[1].value):
            return
    has_encoding = any(kw.arg == "encoding" for kw in node.keywords)
    if not has_encoding:
        violations.append(f"L{node.lineno}: open() without encoding= — specify encoding='utf-8' [Pattern #20 Encoding Mismatch]")


def _check_unsafe_calls(node: ast.Call, violations: list[str]) -> None:
    func = node.func
    # #30 SSRF — only flag if URL looks user-controlled, not config/env/constants
    if isinstance(func, ast.Attribute) and func.attr in ("get", "post", "put", "delete", "patch"):
        if isinstance(func.value, ast.Name) and func.value.id in ("requests", "httpx", "aiohttp"):
            if node.args and isinstance(node.args[0], (ast.Name, ast.JoinedStr, ast.BinOp)):
                url_arg = node.args[0]
                safe_url = False
                if isinstance(url_arg, ast.Name):
                    if url_arg.id.isupper() or url_arg.id.endswith(("_URL", "_url", "_URI", "_uri", "_endpoint")):
                        safe_url = True
                if not safe_url:
                    violations.append(f"L{node.lineno}: HTTP request with variable URL — validate/allowlist [Pattern #30 SSRF]")


def analyze_python_regex(source: str) -> list[str]:
    violations = []
    lines = source.split("\n")
    for i, line in enumerate(lines, 1):
        stripped = line.strip()
        if re.match(r"^global\s+\w+", stripped):
            violations.append(f"L{i}: 'global' keyword — shared mutable state risks race conditions [Pattern #17]")
        if re.match(r"^\s*def\s+[a-z]+[A-Z]", stripped):
            fn_name = re.search(r"def\s+(\w+)", stripped)
            known_camel = {"setUp", "tearDown", "setUpClass", "tearDownClass", "setUpModule",
                          "tearDownModule", "addCleanup", "doCleanups", "skipTest",
                          "countTestCases", "defaultTestResult", "shortDescription",
                          "addTypeEqualityFunc", "assertRaises", "maxDiff"}
            if not fn_name or fn_name.group(1) not in known_camel:
                violations.append(f"L{i}: camelCase function name — use snake_case [Pattern #25]")
        match = re.search(r"(?:if|elif|while|return|>=?|<=?|==|!=)\s+(\d{3,})\b", stripped)
        if match and not re.match(r"^\s*#", stripped):
            num = match.group(1)
            if num not in ("100", "200", "201", "204", "301", "302", "400", "401", "403", "404", "409", "429", "500"):
                violations.append(f"L{i}: Magic number {num} — extract to named constant [Pattern #37]")
        if re.search(r'"/usr/(local/)?bin/|"/opt/|"C:\\\\|"/etc/', stripped):
            if not re.match(r"^\s*#", stripped):
                violations.append(f"L{i}: Hardcoded system path — use shutil.which() or pathlib [Pattern #46]")
        if re.search(r"tempfile\.(mktemp|mkdtemp|NamedTemporaryFile)\(", stripped):
            if "delete=True" not in stripped and "with " not in stripped:
                violations.append(f"L{i}: Temp file without cleanup — use with or delete= [Pattern #43]")
        if re.search(r"subprocess\.\w+\(.*shell\s*=\s*True", stripped):
            if re.search(r'f["\'\']|\.format\(|%\s', stripped):
                violations.append(f"L{i}: shell=True + string formatting — use subprocess with list args [Pattern #29]")
    return violations


def analyze_typescript_regex(source: str) -> list[str]:
    violations = []
    lines = source.split("\n")
    imported_names: dict[str, int] = {}
    used_in_code: set[str] = set()

    for i, line in enumerate(lines, 1):
        stripped = line.strip()
        import_match = re.match(r"import\s+\{([^}]+)\}\s+from", stripped)
        if import_match:
            for name in import_match.group(1).split(","):
                clean = name.strip().split(" as ")[-1].strip()
                if clean:
                    imported_names[clean] = i
            continue
        default_import = re.match(r"import\s+(\w+)\s+from", stripped)
        if default_import:
            imported_names[default_import.group(1)] = i
            continue
        for token in re.findall(r"\b([A-Za-z_]\w*)\b", stripped):
            used_in_code.add(token)
        if re.match(r"^\s*//", stripped) or re.match(r"^\s*\*", stripped):
            continue
        if re.match(r"^\s*async\s+function\s+\w+|^\s*\w+\s*=\s*async\s*\(", stripped):
            block = "\n".join(lines[i:i + 10])
            if re.search(r'\btry\b', block) is None and re.search(r'\bcatch\b', block) is None:
                violations.append(f"L{i}: async function without try/catch — handle errors [Pattern #15]")
        if re.match(r"^\s*(const|let|var|function)\s+\w+_\w+", stripped):
            if "require(" not in stripped and "import" not in stripped:
                violations.append(f"L{i}: snake_case in TypeScript — use camelCase [Pattern #25]")
        match = re.search(r"(?:if|return|===?|!==?|>=?|<=?)\s*(\d{3,})\b", stripped)
        if match:
            num = match.group(1)
            if num not in ("100", "200", "201", "204", "301", "302", "400", "401", "403", "404", "409", "429", "500"):
                violations.append(f"L{i}: Magic number {num} — extract to named constant [Pattern #37]")
        if re.search(r'"/usr/|"/opt/|"C:\\\\', stripped):
            violations.append(f"L{i}: Hardcoded system path [Pattern #46]")
        # Loose equality — strip string literals first to avoid false positives
        cleaned = re.sub(r'"[^"]*"|\'[^\']*\'|`[^`]*`', '""', stripped)
        if re.search(r"[^!=]==(?!=)", cleaned) and not re.search(r"null\s*==\s*|==\s*null", cleaned):
            violations.append(f"L{i}: == instead of === — use strict equality [Pattern #41]")
        # var usage
        if re.match(r"^\s*var\s+\w+", stripped):
            violations.append(f"L{i}: 'var' — prefer 'const' or 'let' [Pattern #42]")
        # eval
        if re.search(r"\beval\s*\(", stripped):
            violations.append(f"L{i}: eval() is dangerous — use safer alternatives [Pattern #29]")
        # XSS
        if re.search(r"\.innerHTML\s*=|dangerouslySetInnerHTML", stripped):
            violations.append(f"L{i}: innerHTML/dangerouslySetInnerHTML — sanitize first [Pattern #28 XSS]")
        # Promise without catch
        if re.search(r"\.then\s*\(", stripped) and not re.search(r"\.catch\s*\(", stripped):
            block = "\n".join(lines[i:i + 3])
            if ".catch(" not in block:
                violations.append(f"L{i}: .then() without .catch() — handle rejection [Pattern #15]")
        # useEffect cleanup
        if re.search(r"useEffect\s*\(\s*\(\s*\)\s*=>", stripped):
            block = "\n".join(lines[i:i + 15])
            if re.search(r"(addEventListener|setInterval|setTimeout|subscribe)", block):
                if "return" not in block:
                    violations.append(f"L{i}: useEffect with listener but no cleanup [Pattern #19]")
        # console.log
        if re.search(r"^\s*console\.(log|debug|info)\(", stripped):
            violations.append(f"L{i}: console.log() — remove or use logger [Pattern #6]")
        # any type
        if re.search(r":\s*any\b(?!\w)", stripped):
            violations.append(f"L{i}: 'any' type — use specific type [Pattern #9]")
        # ts-ignore
        if re.search(r"@ts-ignore\s*$|@ts-nocheck", stripped):
            violations.append(f"L{i}: @ts-ignore without reason — fix the type [Pattern #10]")
    # Unused imports
    for name, lineno in imported_names.items():
        if name not in used_in_code and name != "_" and not name.startswith("_"):
            if name not in ("React", "type", "interface"):
                violations.append(f"L{lineno}: Unused import '{name}' [Pattern #24 Dead Code]")
    return violations


def analyze_go_regex(source: str) -> list[str]:
    violations = []
    lines = source.split("\n")
    for i, line in enumerate(lines, 1):
        stripped = line.strip()
        if re.match(r"^\s*_\s*=\s*\w+.*err|^\s*_\s*=\s*err", stripped):
            violations.append(f"L{i}: Discarded error (_ = err) — handle or return it [Pattern #3]")
        if re.search(r"os\.Open\(|os\.Create\(|sql\.Open\(", stripped):
            block = "\n".join(lines[i:i + 5])
            if "defer" not in block and "Close()" not in block:
                violations.append(f"L{i}: Resource opened without defer Close() [Pattern #19]")
    return violations


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=["pre", "post"], required=True)
    parser.add_argument("--ext", default="py")
    parser.add_argument("--file")
    args = parser.parse_args()

    if args.mode == "post" and args.file:
        filepath = Path(args.file)
        if not filepath.exists():
            return
        source = filepath.read_text(errors="replace")
        ext = filepath.suffix.lstrip(".")
    else:
        source = sys.stdin.read()
        ext = args.ext

    if not source.strip():
        return

    violations: list[str] = []
    if ext == "py":
        violations.extend(analyze_python_ast(source, args.file or "<stdin>"))
        violations.extend(analyze_python_regex(source))
    elif ext in ("ts", "tsx", "js", "jsx"):
        violations.extend(analyze_typescript_regex(source))
    elif ext == "go":
        violations.extend(analyze_go_regex(source))

    for v in violations:
        print(v)


if __name__ == "__main__":
    main()
