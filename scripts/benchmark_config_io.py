"""Read and merge benchmark.conf key=value settings (shell-style)."""

from __future__ import annotations

import re
from dataclasses import dataclass

_ASSIGNMENT_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$")


@dataclass(frozen=True)
class ParsedConfig:
    lines: list[str]
    values: dict[str, str]


def _unquote(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] == '"':
        inner = value[1:-1]
        return inner.replace('\\"', '"').replace("\\\\", "\\")
    if len(value) >= 2 and value[0] == value[-1] == "'":
        return value[1:-1]
    return value


def format_value(value: str) -> str:
    if value == "":
        return ""
    if any(ch in value for ch in ' \t"#$\\'):
        escaped = value.replace("\\", "\\\\").replace('"', '\\"')
        return f'"{escaped}"'
    return value


def parse_config(text: str) -> ParsedConfig:
    values: dict[str, str] = {}
    lines = text.splitlines()
    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        match = _ASSIGNMENT_RE.match(stripped)
        if match:
            values[match.group(1)] = _unquote(match.group(2))
    return ParsedConfig(lines=lines, values=values)


def get_keys(config: ParsedConfig, keys: list[str]) -> dict[str, str]:
    return {key: config.values.get(key, "") for key in keys}


def merge_keys(text: str, updates: dict[str, str], *, insert_after: str | None = None) -> str:
    """Replace or append KEY=value assignments; preserve comments and unrelated lines."""
    parsed = parse_config(text)
    remaining = dict(updates)
    out: list[str] = []

    for line in parsed.lines:
        stripped = line.strip()
        if stripped.startswith("#") or not stripped:
            out.append(line)
            continue
        match = _ASSIGNMENT_RE.match(stripped)
        if not match:
            out.append(line)
            continue
        key = match.group(1)
        if key not in remaining:
            out.append(line)
            continue
        value = remaining.pop(key)
        if value == "" and key not in parsed.values:
            continue
        indent = line[: len(line) - len(line.lstrip())]
        out.append(f"{indent}{key}={format_value(value)}")

    if remaining:
        insert_at = len(out)
        if insert_after:
            marker = insert_after.lower()
            for idx, line in enumerate(out):
                if marker in line.lower():
                    insert_at = idx + 1
                    break
        block: list[str] = []
        if insert_at == len(out) or (insert_at > 0 and out[insert_at - 1].strip()):
            block.append("")
        for key in sorted(remaining):
            value = remaining[key]
            if value == "":
                continue
            block.append(f"{key}={format_value(value)}")
        out[insert_at:insert_at] = block

    merged = "\n".join(out)
    if text.endswith("\n"):
        merged += "\n"
    return merged
