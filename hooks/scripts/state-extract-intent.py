#!/usr/bin/env python3
"""Extract recent user intent from Claude Code transcript JSONL.

Reads the transcript file and returns the last N user messages,
truncated to max_chars each. Used by state-preserve to auto-populate
Section 1 (Session Intent) without relying on AI to fill it.

Usage: python3 state-extract-intent.py /path/to/transcript.jsonl
"""
from __future__ import annotations

import json
import sys


def extract_intent(
    transcript_path: str,
    max_messages: int = 3,
    max_chars: int = 200,
) -> str:
    """Read transcript JSONL and return recent user messages."""
    user_messages: list[str] = []
    try:
        with open(transcript_path, encoding="utf-8") as f:
            for raw_line in f:
                raw_line = raw_line.strip()
                if not raw_line:
                    continue
                try:
                    entry = json.loads(raw_line)
                except json.JSONDecodeError:
                    continue
                role = entry.get("role", "")
                if role != "user":
                    continue
                content = entry.get("content", "")
                if isinstance(content, list):
                    text_parts = [
                        p.get("text", "")
                        for p in content
                        if isinstance(p, dict) and p.get("type") == "text"
                    ]
                    content = " ".join(text_parts)
                if isinstance(content, str) and content.strip():
                    user_messages.append(content.strip()[:max_chars])
    except (OSError, IOError):
        return ""

    recent = user_messages[-max_messages:] if user_messages else []
    if not recent:
        return ""

    lines: list[str] = []
    for i, msg in enumerate(recent, 1):
        lines.append(f"  User message {i}: {msg}")
    return "\n".join(lines)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(0)
    result = extract_intent(sys.argv[1])
    if result:
        print(result)
