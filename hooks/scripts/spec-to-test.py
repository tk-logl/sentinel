#!/usr/bin/env python3
"""Sentinel Spec-to-Test Generator.

Reads a behavior spec JSON and generates a pytest skeleton with
Boss-authored assertions verbatim. This is template expansion,
not AI generation — the assert expressions come directly from the spec.

Usage:
  python3 spec-to-test.py .sentinel/specs/TASK-1.json [--output path/to/test_file.py]
  python3 spec-to-test.py .sentinel/specs/TASK-1.json --stdout
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path


def slugify(text: str) -> str:
    """Convert text to a valid Python identifier."""
    slug = re.sub(r"[^a-zA-Z0-9_]", "_", text.lower())
    slug = re.sub(r"_+", "_", slug).strip("_")
    return slug[:60]


def _placeholder_call(func_names: list[str], comment: str) -> str:
    """Generate a placeholder function call line."""
    if func_names:
        return f"        {func_names[0]}()  # <- {comment}"
    return f"        ...  # <- {comment}"


def generate_test_function(behavior: dict, func_names: list[str]) -> str:
    """Generate a single test function from a behavior entry."""
    bid = behavior.get("id", "unknown")
    given = behavior.get("given", "")
    when = behavior.get("when", "")
    then = behavior.get("then", "")
    assert_expr = behavior.get("assert", "")

    func_suffix = slugify(then) if then else slugify(given)
    test_name = f"test_{func_suffix}"

    is_exception_test = "raises" in assert_expr.lower() or "pytest.raises" in assert_expr

    lines = []
    lines.append(f"def {test_name}():")
    lines.append(f'    """SPEC {bid}: {then}"""')
    lines.append(f"    # GIVEN: {given}")

    if is_exception_test:
        exc_match = re.search(r"pytest\.raises\((\w+)", assert_expr)
        exc_class = exc_match.group(1) if exc_match else "Exception"
        lines.append(f"    # WHEN + THEN: {then}")
        lines.append(f"    with pytest.raises({exc_class}):")
        lines.append(_placeholder_call(func_names, "add args from GIVEN"))
    else:
        lines.append(f"    # WHEN: {when}")
        if func_names:
            lines.append(f"    result = {func_names[0]}()  # <- add args from GIVEN")
        else:
            lines.append("    result = None  # <- call function under test")
        lines.append(f"    # THEN: {then}")
        lines.append(f"    # SPEC ASSERTION (from spec — do NOT weaken):")
        lines.append(f"    assert {assert_expr}")

    lines.append("")
    return "\n".join(lines)


def generate_edge_case_tests(edge_cases: list[str], func_names: list[str]) -> str:
    """Generate parametrized test for edge cases."""
    if not edge_cases:
        return ""

    lines = []
    params = ", ".join(f'"{ec}"' for ec in edge_cases)
    lines.append(f"@pytest.mark.parametrize(\"edge_input\", [{params}])")
    lines.append(f"def test_edge_cases(edge_input):")
    lines.append(f'    """Edge cases from spec — each must be handled without crashing."""')
    if func_names:
        lines.append(f"    # Convert edge_input to appropriate type and call {func_names[0]}")
        lines.append(f"    result = {func_names[0]}(edge_input)  # <- adjust call signature")
        lines.append(f"    assert result is not None  # <- replace with real assertion per edge case")
    else:
        lines.append("    # Call function under test with edge_input")
        lines.append("    assert edge_input is not None  # <- replace with real assertion")
    lines.append("")
    return "\n".join(lines)


def generate_invariant_tests(invariants: list[str], func_names: list[str]) -> str:
    """Generate tests for invariants."""
    if not invariants:
        return ""

    lines = []
    for inv in invariants:
        fname = slugify(inv)
        lines.append(f"def test_invariant_{fname}():")
        lines.append(f'    """Invariant: {inv}"""')
        if func_names:
            lines.append(f"    result = {func_names[0]}()  # <- add appropriate args")
            lines.append(f"    assert result is not None  # <- replace with invariant check: {inv}")
        else:
            lines.append(f"    assert len([]) == 0  # <- replace with invariant check: {inv}")
        lines.append("")
    return "\n".join(lines)


def generate_test_file(spec: dict) -> str:
    """Generate complete test file from spec."""
    task_id = spec.get("task_id", "UNKNOWN")
    module = spec.get("module", "unknown_module")
    func_names = spec.get("functions", [])
    behaviors = spec.get("behavior", [])
    edge_cases = spec.get("edge_cases", [])
    invariants = spec.get("invariants", [])

    lines = []
    lines.append(f'"""Auto-generated tests from spec: {task_id}')
    lines.append(f"")
    lines.append(f"Source module: {module}")
    lines.append(f"Functions: {', '.join(func_names)}")
    lines.append(f"Behaviors: {len(behaviors)}")
    lines.append(f"")
    lines.append(f"WARNING: Assertion expressions are from the spec.")
    lines.append(f"DO NOT weaken, remove, or replace them.")
    lines.append(f'"""')
    lines.append("from __future__ import annotations")
    lines.append("")
    lines.append("import pytest")
    lines.append("")

    if module and module != "unknown_module":
        import_path = module.replace("/", ".").replace(".py", "")
        if func_names:
            imports = ", ".join(func_names)
            lines.append(f"# Verify import path:")
            lines.append(f"# from {import_path} import {imports}")
        lines.append("")

    for behavior in behaviors:
        lines.append(generate_test_function(behavior, func_names))
        lines.append("")

    edge_test = generate_edge_case_tests(edge_cases, func_names)
    if edge_test:
        lines.append(edge_test)
        lines.append("")

    inv_test = generate_invariant_tests(invariants, func_names)
    if inv_test:
        lines.append(inv_test)

    return "\n".join(lines)


def main() -> int:
    """Entry point for spec-to-test generator."""
    if len(sys.argv) < 2:
        print("Usage: spec-to-test.py <spec.json> [--output <path>] [--stdout]", file=sys.stderr)
        return 1

    spec_path = Path(sys.argv[1])
    if not spec_path.exists():
        print(f"Error: spec file not found: {spec_path}", file=sys.stderr)
        return 1

    try:
        spec = json.loads(spec_path.read_text())
    except json.JSONDecodeError as e:
        print(f"Error: invalid JSON in {spec_path}: {e}", file=sys.stderr)
        return 1

    behaviors = spec.get("behavior", [])
    if not behaviors:
        print("Error: spec has no behaviors", file=sys.stderr)
        return 1

    test_content = generate_test_file(spec)

    use_stdout = "--stdout" in sys.argv
    output_path = None
    if "--output" in sys.argv:
        idx = sys.argv.index("--output")
        if idx + 1 < len(sys.argv):
            output_path = Path(sys.argv[idx + 1])

    if use_stdout or not output_path:
        print(test_content)
        if not use_stdout:
            module = spec.get("module", "")
            if module:
                parts = module.replace(".py", "").split("/")
                if len(parts) >= 2:
                    test_dir = "/".join(parts[:-1]) + "/tests"
                    test_file = f"test_{parts[-1]}.py"
                    print(f"\n# Suggested output: {test_dir}/{test_file}", file=sys.stderr)
    else:
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(test_content)
        print(f"Generated: {output_path} ({len(behaviors)} behaviors, {len(spec.get('edge_cases', []))} edge cases)")

    return 0


if __name__ == "__main__":
    sys.exit(main())
