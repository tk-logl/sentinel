#!/usr/bin/env python3
"""Build a context map of project source files for Sentinel.

Analyzes Python files via AST and TS/JS files via regex to classify
functions and detect patterns that inform enforcement decisions.

Output: .sentinel/context-map.json

Usage: python3 build-context-map.py [--root /path/to/project] [--max-files 500] [--timeout 10]
"""
from __future__ import annotations

import ast
import json
import os
import re
import signal
import sys
import time
from pathlib import Path


# --- Timeout handler ---
class TimeoutError(Exception):
    pass


def timeout_handler(signum, frame):
    raise TimeoutError("Context map build timed out")


# --- Python AST analysis ---

def classify_python_body(body: list[ast.stmt]) -> str:
    """Classify a function body as implemented, pass_only, raise_only, or ellipsis_only."""
    if not body:
        return "empty"

    # Filter out docstrings (first Expr with Constant str)
    stmts = body
    if (
        stmts
        and isinstance(stmts[0], ast.Expr)
        and isinstance(stmts[0].value, ast.Constant)
    ):
        stmts = stmts[1:]

    if not stmts:
        return "docstring_only"

    # Single statement bodies
    if len(stmts) == 1:
        stmt = stmts[0]
        # pass
        if isinstance(stmt, ast.Pass):
            return "pass_only"
        # ... (Ellipsis)
        if isinstance(stmt, ast.Expr) and isinstance(stmt.value, ast.Constant) and stmt.value.value is ...:
            return "ellipsis_only"
        # raise NotImplementedError
        if isinstance(stmt, ast.Raise) and stmt.exc is not None:
            exc = stmt.exc
            name = ""
            if isinstance(exc, ast.Call) and isinstance(exc.func, ast.Name):
                name = exc.func.id
            elif isinstance(exc, ast.Name):
                name = exc.id
            if name == "NotImplementedError":
                return "raise_only"
        # return None
        if isinstance(stmt, ast.Return) and (stmt.value is None or (isinstance(stmt.value, ast.Constant) and stmt.value.value is None)):
            return "return_none"

    return "implemented"


def get_decorators(node: ast.FunctionDef | ast.AsyncFunctionDef) -> list[str]:
    """Extract decorator names from a function definition."""
    decorators = []
    for dec in node.decorator_list:
        if isinstance(dec, ast.Name):
            decorators.append(dec.id)
        elif isinstance(dec, ast.Attribute):
            decorators.append(ast.dump(dec))
        elif isinstance(dec, ast.Call):
            if isinstance(dec.func, ast.Name):
                decorators.append(dec.func.id)
            elif isinstance(dec.func, ast.Attribute):
                # e.g., @app.route(...)
                parts = []
                node_attr = dec.func
                while isinstance(node_attr, ast.Attribute):
                    parts.append(node_attr.attr)
                    node_attr = node_attr.value
                if isinstance(node_attr, ast.Name):
                    parts.append(node_attr.id)
                decorators.append(".".join(reversed(parts)))
    return decorators


def is_abc_class(node: ast.ClassDef) -> bool:
    """Check if a class inherits from ABC or ABCMeta."""
    for base in node.bases:
        name = ""
        if isinstance(base, ast.Name):
            name = base.id
        elif isinstance(base, ast.Attribute):
            name = base.attr
        if name in ("ABC", "ABCMeta", "Protocol"):
            return True
    # Check metaclass keyword
    for kw in node.keywords:
        if kw.arg == "metaclass":
            if isinstance(kw.value, ast.Name) and kw.value.id == "ABCMeta":
                return True
    return False


# Patterns where pass/ellipsis is intentionally a noop
NOOP_FUNCTION_PATTERNS = re.compile(
    r"^(teardown|tear_down|cleanup|clean_up|close|__del__|__exit__|"
    r"setUp|tearDown|setUpClass|tearDownClass|"
    r"on_close|on_shutdown|on_cleanup|dispose|finalize|"
    r"__aenter__|__aexit__|__enter__|__exit__|"
    r"__post_init__|__init_subclass__|__class_getitem__)$"
)


def classify_function(
    func: ast.FunctionDef | ast.AsyncFunctionDef,
    is_in_abc: bool,
) -> dict:
    """Classify a single function and return its metadata."""
    decorators = get_decorators(func)
    body_class = classify_python_body(func.body)

    # Determine classification
    classification = "implemented"

    if body_class in ("pass_only", "ellipsis_only", "docstring_only"):
        if "abstractmethod" in decorators:
            classification = "abstract"
        elif NOOP_FUNCTION_PATTERNS.match(func.name):
            # Noop patterns (__del__, cleanup, teardown, etc.) are ALWAYS intentional,
            # even inside ABC classes — they are never meant to be overridden.
            classification = "intentional_noop"
        elif is_in_abc:
            classification = "abstract"
        elif body_class == "docstring_only" and any(
            d in ("overload", "override") for d in decorators
        ):
            classification = "intentional_noop"
        else:
            classification = "stub"
    elif body_class == "raise_only":
        if "abstractmethod" in decorators or is_in_abc:
            classification = "abstract"
        else:
            classification = "stub"
    elif body_class == "return_none":
        if NOOP_FUNCTION_PATTERNS.match(func.name):
            classification = "intentional_noop"

    result = {
        "body": body_class,
        "classification": classification,
        "line": func.lineno,
    }
    if decorators:
        result["decorators"] = decorators

    return result


def analyze_python_file(file_path: str) -> dict | None:
    """Analyze a Python file using AST."""
    try:
        with open(file_path, encoding="utf-8", errors="replace") as f:
            source = f.read()
    except (OSError, IOError):
        return None

    line_count = source.count("\n") + 1

    try:
        tree = ast.parse(source, filename=file_path)
    except SyntaxError:
        return {"language": "python", "line_count": line_count, "parse_error": True}

    functions = {}
    abstract_bases = []
    imports_count = sum(
        1 for node in ast.walk(tree) if isinstance(node, (ast.Import, ast.ImportFrom))
    )

    for node in ast.iter_child_nodes(tree):
        # Top-level functions
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            functions[node.name] = classify_function(node, False)

        # Classes
        elif isinstance(node, ast.ClassDef):
            class_is_abc = is_abc_class(node)
            if class_is_abc:
                abstract_bases.append(node.name)

            for item in node.body:
                if isinstance(item, (ast.FunctionDef, ast.AsyncFunctionDef)):
                    key = f"{node.name}.{item.name}"
                    functions[key] = classify_function(item, class_is_abc)

    # Criticality
    criticality = "normal"
    if line_count > 500:
        criticality = "critical"
    elif line_count > 200:
        criticality = "high"

    result = {
        "language": "python",
        "line_count": line_count,
        "imports_count": imports_count,
        "criticality": criticality,
    }
    if functions:
        result["functions"] = functions
    if abstract_bases:
        result["abstract_bases"] = abstract_bases

    return result


# --- TypeScript/JavaScript regex analysis ---

TS_FUNC_RE = re.compile(
    r"^(?:export\s+)?(?:async\s+)?function\s+(\w+)", re.MULTILINE
)
TS_CLASS_RE = re.compile(
    r"^(?:export\s+)?(?:abstract\s+)?class\s+(\w+)", re.MULTILINE
)
TS_ABSTRACT_RE = re.compile(r"^export\s+abstract\s+class\s+(\w+)", re.MULTILINE)
TS_INTERFACE_RE = re.compile(
    r"^(?:export\s+)?interface\s+(\w+)", re.MULTILINE
)


def analyze_ts_file(file_path: str) -> dict | None:
    """Analyze a TypeScript/JavaScript file using regex."""
    try:
        with open(file_path, encoding="utf-8", errors="replace") as f:
            source = f.read()
    except (OSError, IOError):
        return None

    line_count = source.count("\n") + 1
    ext = os.path.splitext(file_path)[1].lstrip(".")
    lang = "typescript" if ext in ("ts", "tsx") else "javascript"

    functions = {}
    for m in TS_FUNC_RE.finditer(source):
        functions[m.group(1)] = {
            "classification": "implemented",
            "line": source[:m.start()].count("\n") + 1,
        }

    classes = [m.group(1) for m in TS_CLASS_RE.finditer(source)]
    abstract_classes = [m.group(1) for m in TS_ABSTRACT_RE.finditer(source)]
    interfaces = [m.group(1) for m in TS_INTERFACE_RE.finditer(source)]

    criticality = "normal"
    if line_count > 500:
        criticality = "critical"
    elif line_count > 200:
        criticality = "high"

    result = {
        "language": lang,
        "line_count": line_count,
        "criticality": criticality,
    }
    if functions:
        result["functions"] = functions
    if classes:
        result["classes"] = classes
    if abstract_classes:
        result["abstract_bases"] = abstract_classes
    if interfaces:
        result["interfaces"] = interfaces

    return result


# --- File discovery ---

SOURCE_EXTENSIONS = {
    ".py", ".ts", ".tsx", ".js", ".jsx",
    ".go", ".rs", ".java", ".c", ".cpp",
    ".svelte", ".vue",
}

SKIP_DIRS = {
    "node_modules", "__pycache__", ".git", ".sentinel",
    ".claude", ".omc", ".github", "dist", "build",
    ".next", ".nuxt", "venv", ".venv", "env",
}


def discover_files(root: str, max_files: int = 500) -> list[str]:
    """Find source files in the project, respecting limits."""
    files = []
    for dirpath, dirnames, filenames in os.walk(root):
        # Prune skip directories
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]

        for fname in filenames:
            ext = os.path.splitext(fname)[1]
            if ext in SOURCE_EXTENSIONS:
                full = os.path.join(dirpath, fname)
                files.append(full)
                if len(files) >= max_files:
                    return files
    return files


# --- Main ---

def build_context_map(
    root: str,
    max_files: int = 500,
    timeout_secs: int = 10,
) -> dict:
    """Build the complete context map."""
    # Set timeout (Unix only)
    if hasattr(signal, "SIGALRM"):
        signal.signal(signal.SIGALRM, timeout_handler)
        signal.alarm(timeout_secs)

    start_time = time.time()
    files = discover_files(root, max_files)

    file_map = {}
    all_abstract_bases = []
    test_files = []

    for fpath in files:
        rel_path = os.path.relpath(fpath, root)

        # Track test files
        basename = os.path.basename(fpath)
        if any(p in basename or p in rel_path for p in (
            "test_", "_test.", ".test.", ".spec.", "/tests/"
        )):
            test_files.append(rel_path)
            continue

        ext = os.path.splitext(fpath)[1]
        analysis = None

        try:
            if ext == ".py":
                analysis = analyze_python_file(fpath)
            elif ext in (".ts", ".tsx", ".js", ".jsx"):
                analysis = analyze_ts_file(fpath)
            else:
                # Basic metadata for other languages
                try:
                    with open(fpath, encoding="utf-8", errors="replace") as f:
                        lc = sum(1 for _ in f)
                    criticality = "critical" if lc > 500 else ("high" if lc > 200 else "normal")
                    analysis = {
                        "language": ext.lstrip("."),
                        "line_count": lc,
                        "criticality": criticality,
                    }
                except (OSError, IOError):
                    pass
        except TimeoutError:
            break
        except Exception:
            continue

        if analysis:
            file_map[rel_path] = analysis
            if "abstract_bases" in analysis:
                for ab in analysis["abstract_bases"]:
                    all_abstract_bases.append(f"{rel_path}:{ab}")

    # Cross-reference functions with test files to set has_test
    # A function is considered tested if any test file name contains its module name
    # or if a test_<module> file exists for the function's source file.
    for rel_path, info in file_map.items():
        if "functions" not in info:
            continue
        # Derive expected test file patterns from source file
        basename = os.path.splitext(os.path.basename(rel_path))[0]
        # Common test file patterns: test_<name>.py, <name>_test.py, <name>.test.ts
        test_patterns = [
            f"test_{basename}",
            f"{basename}_test",
            f"{basename}.test",
            f"{basename}.spec",
        ]
        # Check if any test file matches
        file_has_test = any(
            any(pat in tf for pat in test_patterns)
            for tf in test_files
        )
        for func_name, func_info in info["functions"].items():
            func_info["has_test"] = file_has_test

    elapsed = time.time() - start_time

    # Cancel alarm
    if hasattr(signal, "SIGALRM"):
        signal.alarm(0)

    return {
        "version": "1.0",
        "computed_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "elapsed_seconds": round(elapsed, 2),
        "file_count": len(file_map),
        "files": file_map,
        "abstract_bases": all_abstract_bases,
        "test_files": test_files[:50],
    }


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Build sentinel context map")
    parser.add_argument("--root", default=".", help="Project root directory")
    parser.add_argument("--max-files", type=int, default=500, help="Max files to analyze")
    parser.add_argument("--timeout", type=int, default=10, help="Timeout in seconds")
    args = parser.parse_args()

    root = os.path.abspath(args.root)
    if not os.path.isdir(root):
        print(f"Error: {root} is not a directory", file=sys.stderr)
        sys.exit(1)

    context_map = build_context_map(root, args.max_files, args.timeout)

    # Write to .sentinel/context-map.json
    output_dir = os.path.join(root, ".sentinel")
    os.makedirs(output_dir, exist_ok=True)
    output_file = os.path.join(output_dir, "context-map.json")

    with open(output_file, "w", encoding="utf-8") as f:
        json.dump(context_map, f, indent=2, ensure_ascii=False)

    print(f"Context map: {context_map['file_count']} files analyzed in {context_map['elapsed_seconds']}s")
