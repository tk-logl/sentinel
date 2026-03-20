#!/usr/bin/env python3
"""Sentinel PostToolUse Hook: AST Quality Gate (BLOCKING)

Analyzes Python files using Python AST to detect placeholder/stub code.
Unlike regex-based detection, AST analysis cannot be bypassed by adding
comments, changing whitespace, or renaming variables.

Exit 2 = DENY (force fix) | Exit 0 = ALLOW
"""

import ast
import json
import os
import sys


def check_placeholder_functions(file_path: str) -> list[str]:
    """Detect functions with placeholder bodies using AST analysis.

    Catches:
    - Functions with only `pass`
    - Functions with only `return` / `return None`
    - Functions with only `raise NotImplementedError` (without @abstractmethod)
    - Functions with only `return ""` / `return {}` / `return []` / `return 0`
    - Functions with only a docstring and nothing else
    - Functions with only `...` (Ellipsis)
    """
    try:
        with open(file_path, encoding="utf-8") as f:
            source = f.read()
        tree = ast.parse(source, filename=file_path)
    except (SyntaxError, UnicodeDecodeError, OSError):
        return []

    violations = []

    for node in ast.walk(tree):
        if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            continue

        decorators = [
            getattr(d, "attr", getattr(d, "id", ""))
            for d in node.decorator_list
        ]
        if "abstractmethod" in decorators:
            continue

        noop_names = {
            "__del__", "teardown", "tearDown", "cleanup", "close",
            "setUp", "setUpClass", "tearDownClass",
        }
        if node.name in noop_names:
            continue

        body = node.body
        if (
            body
            and isinstance(body[0], ast.Expr)
            and isinstance(body[0].value, ast.Constant)
            and isinstance(body[0].value.value, str)
        ):
            body = body[1:]

        if len(body) == 0:
            violations.append(
                f"  Line {node.lineno}: {node.name}() has no implementation (docstring only)"
            )
            continue

        if len(body) == 1:
            stmt = body[0]

            if isinstance(stmt, ast.Pass):
                violations.append(
                    f"  Line {node.lineno}: {node.name}() has only 'pass'"
                )
                continue

            if isinstance(stmt, ast.Return):
                val = stmt.value
                if val is None:
                    violations.append(
                        f"  Line {node.lineno}: {node.name}() has only 'return'"
                    )
                    continue
                if isinstance(val, ast.Constant) and val.value is None:
                    violations.append(
                        f"  Line {node.lineno}: {node.name}() has only 'return None'"
                    )
                    continue
                if isinstance(val, ast.Constant) and val.value in ("", 0, False):
                    violations.append(
                        f"  Line {node.lineno}: {node.name}() has only 'return {val.value!r}' (empty stub)"
                    )
                    continue
                if isinstance(val, ast.Dict) and len(val.keys) == 0:
                    violations.append(
                        f"  Line {node.lineno}: {node.name}() has only 'return {{}}' (empty stub)"
                    )
                    continue
                if isinstance(val, ast.List) and len(val.elts) == 0:
                    violations.append(
                        f"  Line {node.lineno}: {node.name}() has only 'return []' (empty stub)"
                    )
                    continue

            if isinstance(stmt, ast.Raise) and stmt.exc is not None:
                exc = stmt.exc
                exc_name = ""
                if isinstance(exc, ast.Call):
                    exc_name = getattr(exc.func, "id", getattr(exc.func, "attr", ""))
                elif isinstance(exc, ast.Name):
                    exc_name = exc.id
                if exc_name == "NotImplementedError":
                    violations.append(
                        f"  Line {node.lineno}: {node.name}() has only 'raise NotImplementedError'"
                    )
                    continue

            if (
                isinstance(stmt, ast.Expr)
                and isinstance(stmt.value, ast.Constant)
                and stmt.value.value is ...
            ):
                violations.append(
                    f"  Line {node.lineno}: {node.name}() has only '...' (Ellipsis stub)"
                )
                continue

    return violations


def main() -> None:
    try:
        data = json.load(sys.stdin)
    except (json.JSONDecodeError, EOFError):
        sys.exit(0)

    tool_name = data.get("tool_name", "")
    if tool_name not in ("Write", "Edit"):
        sys.exit(0)

    file_path = data.get("tool_input", {}).get("file_path", "")
    if not file_path or not file_path.endswith(".py"):
        sys.exit(0)

    skip_patterns = [
        "/test_", ".test.", ".spec.", "/tests/",
        "__pycache__", "node_modules", ".sentinel", ".claude", ".omc",
        "/migrations/",
    ]
    if any(p in file_path for p in skip_patterns):
        sys.exit(0)

    violations = check_placeholder_functions(file_path)

    if violations:
        basename = os.path.basename(file_path)
        print(f"[Sentinel AST-Gate] Placeholder code in: {basename}")
        print()
        print("Violations:")
        for v in violations:
            print(v)
        print()
        print("Every function must have a real implementation.")
        print("AST analysis detected empty/stub function bodies — comment tricks will NOT bypass this.")
        print("-> Write actual logic, then retry.")
        sys.exit(2)

    sys.exit(0)


if __name__ == "__main__":
    main()
