"""Read and merge benchmark.conf key=value settings (shell-style)."""

from __future__ import annotations

import re
from dataclasses import dataclass

_ASSIGNMENT_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$")

# Keys where surrounding quotes must not be stored (space-separated tokens for bash word-split).
_TOKEN_LIST_KEYS = frozenset(
    {
        "FAILOVER_EDITIONS",
        "FAILOVER_SCENARIOS",
        "FAILOVER_THREAD_MATRIX",
    }
)

_NUMERIC_KEYS = frozenset(
    {
        "FAILOVER_THREADS",
        "FAILOVER_WARMUP_SEC",
        "FAILOVER_BASELINE_SEC",
        "FAILOVER_OBSERVE_SEC",
        "FAILOVER_TRIGGER_SECOND",
        "FAILOVER_REPORT_INTERVAL",
        "FAILOVER_THREAD_DELAY_SEC",
        "FAILOVER_SCENARIO_DELAY_SEC",
        "FAILOVER_POD_DELETE_GRACE_SEC",
        "FAILOVER_MYSQLD_KILL_SIGNAL",
        "FAILOVER_TRIGGER_PREPARE_SEC",
        "FAILOVER_MONITOR_INTERVAL",
        "FAILOVER_MONITOR_CONNECT_TIMEOUT",
        "FAILOVER_MONITOR_OP_TIMEOUT",
        "FAILOVER_RECOVERY_STABLE_SEC",
    }
)


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


def _parse_quoted_token(raw: str, quote: str) -> tuple[str, str]:
    i = 1
    while i < len(raw):
        if raw[i] == "\\" and i + 1 < len(raw):
            i += 2
            continue
        if raw[i] == quote:
            return raw[: i + 1], raw[i + 1 :]
        i += 1
    return raw, ""


def _split_value_and_comment(raw: str) -> tuple[str, str]:
    """Split an assignment RHS into shell value text and trailing inline comment."""
    raw = raw.rstrip()
    if not raw:
        return "", ""

    if raw[0] in "\"'":
        quote = raw[0]
        value_token, rest = _parse_quoted_token(raw, quote)
        rest = rest.lstrip()
        if rest.startswith("#"):
            return value_token, rest
        return value_token, ""

    for index, char in enumerate(raw):
        if char == "#":
            return raw[:index].rstrip(), raw[index:]
    return raw, ""


def parse_shell_value(raw: str) -> str:
    """Parse a shell assignment RHS the way bash would (ignore inline comments)."""
    value_token, _comment = _split_value_and_comment(raw)
    if not value_token:
        return ""
    return _unquote(value_token.strip())


def normalize_failover_value(key: str, value: str) -> str:
    """Normalize values written by the control UI so bash/sysbench see clean tokens."""
    cleaned = parse_shell_value(value)
    if key in _TOKEN_LIST_KEYS or key in _NUMERIC_KEYS:
        while len(cleaned) >= 2 and cleaned[0] == cleaned[-1] and cleaned[0] in "\"'":
            cleaned = cleaned[1:-1].strip()
    return cleaned.strip()


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
            values[match.group(1)] = parse_shell_value(match.group(2))
    return ParsedConfig(lines=lines, values=values)


def get_keys(config: ParsedConfig, keys: list[str]) -> dict[str, str]:
    return {key: config.values.get(key, "") for key in keys}


def merge_keys(text: str, updates: dict[str, str], *, insert_after: str | None = None) -> str:
    """Replace or append KEY=value assignments; preserve comments and unrelated lines."""
    parsed = parse_config(text)
    remaining = {key: normalize_failover_value(key, value) for key, value in updates.items()}
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
        _value_token, comment = _split_value_and_comment(match.group(2))
        indent = line[: len(line) - len(line.lstrip())]
        suffix = f" {comment.lstrip()}" if comment.strip() else ""
        out.append(f"{indent}{key}={format_value(value)}{suffix}")

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
