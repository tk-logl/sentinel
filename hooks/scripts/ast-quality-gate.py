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


def check_hollow_implementations(file_path: str) -> list[str]:
    """Detect functions that appear implemented but do no meaningful work.

    Catches sophisticated no-ops that pass the basic checks:
    - Functions that ignore ALL parameters and return a hardcoded constant
    - Identity functions that return a single parameter unchanged
    - Functions whose body is only logging calls (print/logger) with no real logic
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

        # Skip dunder methods, test helpers, lifecycle hooks
        if node.name.startswith("_"):
            continue

        skip_names = {
            "setUp", "tearDown", "setUpClass", "tearDownClass",
            "setup", "teardown", "cleanup", "close", "dispose",
            "configure", "register", "emit", "on",
        }
        if node.name in skip_names:
            continue

        # Skip decorated functions (property, staticmethod, classmethod, etc.)
        if node.decorator_list:
            continue

        # Collect parameter names (excluding self/cls)
        param_names = set()
        for arg in node.args.args:
            if arg.arg not in ("self", "cls"):
                param_names.add(arg.arg)
        for arg in node.args.posonlyargs:
            if arg.arg not in ("self", "cls"):
                param_names.add(arg.arg)
        for arg in node.args.kwonlyargs:
            param_names.add(arg.arg)
        if node.args.vararg:
            param_names.add(node.args.vararg.arg)
        if node.args.kwarg:
            param_names.add(node.args.kwarg.arg)

        # Need at least one parameter to check (zero-param functions are fine)
        if not param_names:
            continue

        # Strip docstring from body
        body = list(node.body)
        if (
            body
            and isinstance(body[0], ast.Expr)
            and isinstance(body[0].value, ast.Constant)
            and isinstance(body[0].value.value, str)
        ):
            body = body[1:]

        if not body:
            continue  # Already caught by check_placeholder_functions

        # --- Pattern 1: Ignores ALL params, returns a hardcoded constant ---
        # A function that takes params but never references them and just returns a literal
        if len(body) == 1 and isinstance(body[0], ast.Return) and body[0].value is not None:
            ret_val = body[0].value
            # Check if the return value is a constant (not involving any parameter)
            names_in_return = {n.id for n in ast.walk(ret_val) if isinstance(n, ast.Name)}
            if not names_in_return.intersection(param_names) and len(param_names) >= 2:
                # Returns something that uses NONE of the 2+ parameters
                if isinstance(ret_val, ast.Constant):
                    violations.append(
                        f"  Line {node.lineno}: {node.name}() ignores all {len(param_names)} "
                        f"parameters, returns hardcoded {ret_val.value!r}"
                    )
                    continue
                if isinstance(ret_val, (ast.Dict, ast.List, ast.Tuple)):
                    child_names = {n.id for n in ast.walk(ret_val) if isinstance(n, ast.Name)}
                    if not child_names.intersection(param_names):
                        violations.append(
                            f"  Line {node.lineno}: {node.name}() ignores all {len(param_names)} "
                            f"parameters, returns a hardcoded literal"
                        )
                        continue

        # --- Pattern 2: Identity function — returns a single parameter unchanged ---
        if len(body) == 1 and isinstance(body[0], ast.Return) and body[0].value is not None:
            ret_val = body[0].value
            if isinstance(ret_val, ast.Name) and ret_val.id in param_names and len(param_names) >= 2:
                # Returns one param, ignores the rest — likely a no-op
                other_params = param_names - {ret_val.id}
                violations.append(
                    f"  Line {node.lineno}: {node.name}() returns '{ret_val.id}' unchanged, "
                    f"ignoring {len(other_params)} other parameter(s): {', '.join(sorted(other_params))}"
                )
                continue

        # --- Pattern 3: Body is only logging calls (no real logic) ---
        log_funcs = {"print", "log", "debug", "info", "warning", "error", "critical"}
        real_stmts = []
        for stmt in body:
            if isinstance(stmt, ast.Expr) and isinstance(stmt.value, ast.Call):
                func = stmt.value.func
                fname = ""
                if isinstance(func, ast.Name):
                    fname = func.id
                elif isinstance(func, ast.Attribute):
                    fname = func.attr
                if fname in log_funcs:
                    continue
            real_stmts.append(stmt)

        if len(real_stmts) == 0 and len(body) >= 1:
            violations.append(
                f"  Line {node.lineno}: {node.name}() body contains only "
                f"logging/print calls (no real logic)"
            )

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

    # Skip enforcement tools themselves
    basename = os.path.basename(file_path)
    tool_patterns = ["gate", "guard", "scan", "check", "verify", "lint", "analyz", "detect", "enforc"]
    if any(p in basename.lower() for p in tool_patterns):
        sys.exit(0)

    violations = check_placeholder_functions(file_path)
    violations.extend(check_hollow_implementations(file_path))

    if violations:
        print(f"⛔ [Sentinel AST-Gate] Incomplete code in: {basename}", file=sys.stderr)
        print(file=sys.stderr)
        print("Violations:", file=sys.stderr)
        for v in violations:
            print(v, file=sys.stderr)
        print(file=sys.stderr)
        print("Every function must have a real implementation.", file=sys.stderr)
        print("AST analysis detected empty/stub function bodies — comment tricks will NOT bypass this.", file=sys.stderr)
        print("→ Write actual logic, then retry.", file=sys.stderr)
        sys.exit(2)

    sys.exit(0)


if __name__ == "__main__":
    main()
