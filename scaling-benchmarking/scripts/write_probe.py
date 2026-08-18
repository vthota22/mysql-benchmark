#!/usr/bin/env python3
"""Canary writer for scaling runs: detect write loss and sent-vs-committed latency.

Every INTERVAL seconds the probe INSERTs the next seq into `test_writes`:
  seq         client-assigned 1, 2, 3, ... (gaps vs the attempt log = never committed)
  sent_at     client UTC clock when the INSERT was sent
  created_at  MySQL DEFAULT CURRENT_TIMESTAMP(6) when the server executed the INSERT

A local attempts CSV is the ground truth of what the client tried. The table is
only what actually committed. Compare the two after the run.

Client-perceived latency is ack_at - sent_at (same clock, no skew).
created_at - sent_at is a secondary signal and includes client/server clock skew.
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import re
import signal
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

ERROR_RE = re.compile(r"ERROR\s+(\d+)", re.IGNORECASE)
TABLE_NAME = "test_writes"

CREATE_SQL = f"""
SET time_zone = '+00:00';
CREATE TABLE IF NOT EXISTS `{TABLE_NAME}` (
  seq BIGINT UNSIGNED NOT NULL,
  sent_at DATETIME(6) NOT NULL,
  created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  PRIMARY KEY (seq)
) ENGINE=InnoDB;
TRUNCATE TABLE `{TABLE_NAME}`;
"""


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def utc_now_mysql() -> str:
    return utc_now().strftime("%Y-%m-%d %H:%M:%S.%f")


def utc_now_iso() -> str:
    return utc_now().strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def mysql_env() -> dict[str, str]:
    host = os.environ.get("MYSQL_HOST", "")
    port = os.environ.get("MYSQL_PORT", "3306")
    user = os.environ.get("MYSQL_USER", "")
    password = os.environ.get("MYSQL_PASSWORD", "")
    db = os.environ.get("MYSQL_DB", "")
    missing = [n for n, v in (
        ("MYSQL_HOST", host), ("MYSQL_USER", user),
        ("MYSQL_PASSWORD", password), ("MYSQL_DB", db),
    ) if not v]
    if missing:
        raise SystemExit(f"ERROR: missing env: {', '.join(missing)}")
    return {
        "host": host,
        "port": port,
        "user": user,
        "password": password,
        "db": db,
    }


def mysql_cmd(env: dict[str, str], extra: list[str] | None = None) -> list[str]:
    cmd = [
        "mysql",
        "-h", env["host"],
        "-P", str(env["port"]),
        "-u", env["user"],
        f"-p{env['password']}",
        "--ssl-mode=REQUIRED",
        "--connect-timeout=5",
        "-N",
        "-B",
        env["db"],
    ]
    if extra:
        cmd.extend(extra)
    return cmd


def run_mysql(
    env: dict[str, str],
    sql: str,
    timeout_sec: float,
) -> tuple[int, str, str, subprocess.Popen[str] | None]:
    """Run SQL via mysql CLI. Returns (rc, stdout, stderr, proc_if_still_needed)."""
    proc = subprocess.Popen(
        mysql_cmd(env, ["-e", sql]),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        stdout, stderr = proc.communicate(timeout=timeout_sec)
        return proc.returncode, stdout, stderr, None
    except subprocess.TimeoutExpired:
        proc.kill()
        try:
            stdout, stderr = proc.communicate(timeout=2)
        except Exception:
            stdout, stderr = "", "timeout"
        return 124, stdout, stderr or "timeout", None


def parse_errno(stderr: str) -> str:
    m = ERROR_RE.search(stderr or "")
    return m.group(1) if m else ""


def one_line(text: str, limit: int = 240) -> str:
    return " ".join((text or "").split())[:limit]


class ProbeState:
    def __init__(self) -> None:
        self.stop = False
        self.current_proc: subprocess.Popen[str] | None = None

    def request_stop(self, _signum: int | None = None, _frame: Any = None) -> None:
        self.stop = True
        proc = self.current_proc
        if proc is not None and proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=2)
            except Exception:
                proc.kill()


def cmd_prepare(args: argparse.Namespace) -> int:
    env = mysql_env()
    rc, stdout, stderr, _ = run_mysql(env, CREATE_SQL, timeout_sec=60)
    if rc != 0:
        print(f"ERROR: failed to prepare {TABLE_NAME}: {one_line(stderr or stdout)}", file=sys.stderr)
        return rc or 1
    print(f"prepared table {TABLE_NAME} (created if missing, truncated)")
    return 0


def cmd_run(args: argparse.Namespace) -> int:
    env = mysql_env()
    interval = float(args.interval)
    timeout_sec = float(args.timeout)
    attempts_path = Path(args.attempts)
    attempts_path.parent.mkdir(parents=True, exist_ok=True)

    state = ProbeState()
    signal.signal(signal.SIGTERM, state.request_stop)
    signal.signal(signal.SIGINT, state.request_stop)

    fieldnames = [
        "seq", "sent_at_utc", "ack_at_utc", "status",
        "errno", "error", "latency_ms",
    ]
    out = attempts_path.open("w", encoding="utf-8", newline="")
    writer = csv.DictWriter(out, fieldnames=fieldnames)
    writer.writeheader()
    out.flush()

    seq = 0
    next_tick = time.monotonic()
    print(
        f"write probe running interval={interval}s timeout={timeout_sec}s "
        f"attempts={attempts_path}",
        flush=True,
    )

    try:
        while not state.stop:
            now = time.monotonic()
            if now < next_tick:
                time.sleep(min(0.05, next_tick - now))
                continue

            seq += 1
            sent_mysql = utc_now_mysql()
            sent_iso = utc_now_iso()
            sql = (
                "SET time_zone = '+00:00'; "
                f"INSERT INTO `{TABLE_NAME}` (seq, sent_at) "
                f"VALUES ({seq}, '{sent_mysql}');"
            )

            t0 = time.monotonic()
            proc = subprocess.Popen(
                mysql_cmd(env, ["-e", sql]),
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            state.current_proc = proc
            status = "ok"
            errno = ""
            err = ""
            rc = 0
            try:
                stdout, stderr = proc.communicate(timeout=timeout_sec)
                rc = proc.returncode
            except subprocess.TimeoutExpired:
                proc.kill()
                try:
                    stdout, stderr = proc.communicate(timeout=2)
                except Exception:
                    stdout, stderr = "", "timeout"
                status = "timeout"
                errno = "timeout"
                err = "INSERT exceeded probe timeout (row may still commit)"
                rc = 124
            finally:
                state.current_proc = None

            if state.stop and status == "ok" and rc != 0:
                status = "interrupted"
                errno = parse_errno(stderr) or "interrupted"
                err = one_line(stderr or "interrupted")
            elif status != "timeout" and rc != 0:
                status = "error"
                errno = parse_errno(stderr) or str(rc)
                err = one_line(stderr or stdout)

            ack_iso = utc_now_iso()
            latency_ms = round((time.monotonic() - t0) * 1000.0, 3)
            writer.writerow({
                "seq": seq,
                "sent_at_utc": sent_iso,
                "ack_at_utc": ack_iso,
                "status": status,
                "errno": errno,
                "error": err,
                "latency_ms": f"{latency_ms:.3f}",
            })
            out.flush()

            if state.stop:
                break

            next_tick += interval
            if next_tick < time.monotonic():
                next_tick = time.monotonic()
    finally:
        out.close()

    print(f"write probe stopped after seq={seq}", flush=True)
    return 0


def cmd_dump(args: argparse.Namespace) -> int:
    env = mysql_env()
    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    sql = (
        "SET time_zone = '+00:00'; "
        f"SELECT seq, sent_at, created_at, "
        f"TIMESTAMPDIFF(MICROSECOND, sent_at, created_at) AS commit_delay_us "
        f"FROM `{TABLE_NAME}` ORDER BY seq;"
    )
    rc, stdout, stderr, _ = run_mysql(env, sql, timeout_sec=120)
    if rc != 0:
        print(f"ERROR: dump failed: {one_line(stderr or stdout)}", file=sys.stderr)
        # Still write an empty CSV so summarize can run off the attempt log.
        with out_path.open("w", encoding="utf-8", newline="") as f:
            csv.DictWriter(f, fieldnames=[
                "seq", "sent_at", "created_at", "commit_delay_us",
            ]).writeheader()
        return rc or 1

    fieldnames = ["seq", "sent_at", "created_at", "commit_delay_us"]
    rows = 0
    with out_path.open("w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        for line in stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            parts = line.split("\t")
            if len(parts) < 3:
                continue
            delay = parts[3] if len(parts) > 3 else ""
            writer.writerow({
                "seq": parts[0],
                "sent_at": parts[1],
                "created_at": parts[2],
                "commit_delay_us": delay,
            })
            rows += 1
    print(f"dumped {rows} rows from {TABLE_NAME} to {out_path}")
    return 0


def _pct(values: list[float], p: float) -> float | None:
    if not values:
        return None
    s = sorted(values)
    if len(s) == 1:
        return round(s[0], 3)
    k = (len(s) - 1) * (p / 100.0)
    lo = int(k)
    hi = min(lo + 1, len(s) - 1)
    return round(s[lo] + (s[hi] - s[lo]) * (k - lo), 3)


def _ms_stats(values: list[float]) -> dict[str, float | None]:
    if not values:
        return {"n": 0, "p50": None, "p95": None, "p99": None, "max": None}
    return {
        "n": len(values),
        "p50": _pct(values, 50),
        "p95": _pct(values, 95),
        "p99": _pct(values, 99),
        "max": round(max(values), 3),
    }


def _load_csv(path: Path) -> list[dict[str, str]]:
    if not path.is_file():
        return []
    with path.open(encoding="utf-8", newline="") as f:
        return list(csv.DictReader(f))


def cmd_summarize(args: argparse.Namespace) -> int:
    attempts = _load_csv(Path(args.attempts))
    committed_rows = _load_csv(Path(args.committed))
    summary_json = Path(args.summary_json)
    summary_txt = Path(args.summary_txt)

    committed_by_seq = {int(r["seq"]): r for r in committed_rows if r.get("seq")}
    committed_seqs = set(committed_by_seq)

    by_status: dict[str, int] = {}
    by_errno: dict[str, int] = {}
    ack_but_missing: list[int] = []
    never_committed: list[int] = []
    late_commit: list[int] = []
    ok_seqs: list[int] = []
    client_lat: list[float] = []
    server_delay: list[float] = []

    for row in attempts:
        try:
            seq = int(row["seq"])
        except (KeyError, ValueError):
            continue
        status = (row.get("status") or "").strip() or "unknown"
        by_status[status] = by_status.get(status, 0) + 1
        errno = (row.get("errno") or "").strip()
        if errno:
            by_errno[errno] = by_errno.get(errno, 0) + 1
        in_table = seq in committed_seqs
        if status == "ok":
            try:
                client_lat.append(float(row["latency_ms"]))
            except (KeyError, ValueError):
                pass
            if in_table:
                ok_seqs.append(seq)
            else:
                ack_but_missing.append(seq)
        elif in_table:
            late_commit.append(seq)
        else:
            never_committed.append(seq)

    for seq, row in committed_by_seq.items():
        raw = (row.get("commit_delay_us") or "").strip()
        if raw in ("", "NULL"):
            continue
        try:
            server_delay.append(int(raw) / 1000.0)
        except ValueError:
            continue

    lost_count = len(ack_but_missing) + len(never_committed)
    payload = {
        "table": TABLE_NAME,
        "attempted": len(attempts),
        "committed": len(committed_rows),
        "ok": len(ok_seqs),
        "lost": lost_count,
        "ack_but_missing": ack_but_missing,
        "never_committed": never_committed,
        "late_commit": late_commit,
        "by_status": by_status,
        "by_errno": by_errno,
        "client_latency_ms": _ms_stats(client_lat),
        "server_delay_ms": _ms_stats(server_delay),
        "notes": {
            "ack_but_missing": (
                "Client got OK but the row is not in the table. This is true "
                "durability loss from the application's point of view."
            ),
            "never_committed": (
                "INSERT failed or timed out and no row exists. Expected during "
                "group_replication_set_as_primary() (errno 4094) or disconnects. "
                "Not silent data loss — the client must retry."
            ),
            "late_commit": (
                "Client gave up (timeout/kill) but MySQL still committed the row."
            ),
            "server_delay_ms": (
                "created_at - sent_at. Mixes two clocks; use client_latency_ms "
                "(ack - sent) as the source of truth for application latency."
            ),
        },
    }

    summary_json.parent.mkdir(parents=True, exist_ok=True)
    summary_json.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

    def fmt_stats(s: dict[str, float | None]) -> str:
        if not s.get("n"):
            return "n=0"
        return (
            f"n={s['n']} p50={s['p50']}ms p95={s['p95']}ms "
            f"p99={s['p99']}ms max={s['max']}ms"
        )

    lines = [
        f"Write probe summary ({TABLE_NAME})",
        f"  attempted:        {payload['attempted']}",
        f"  committed:        {payload['committed']}",
        f"  ok (ack+row):     {payload['ok']}",
        f"  lost (no row):    {lost_count}",
        f"    ack but missing:{len(ack_but_missing)}"
        + (f"  seqs={ack_but_missing[:40]}" if ack_but_missing else ""),
        f"    never committed:{len(never_committed)}"
        + (f"  seqs={never_committed[:40]}" if never_committed else ""),
        f"  late commit:      {len(late_commit)}"
        + (f"  seqs={late_commit[:40]}" if late_commit else ""),
        f"  by status:        {by_status}",
        f"  by errno:         {by_errno}",
        f"  client latency:   {fmt_stats(payload['client_latency_ms'])}",
        f"  server delay:     {fmt_stats(payload['server_delay_ms'])}  (clock-skew-prone)",
        "",
        "Lost = attempted seq with no row in the table. Those statements were",
        "not queued; they failed or were rolled back. Retry from the client.",
        "client latency (ack - sent) is the reliable latency number.",
        "created_at - sent_at mixes client and MySQL clocks.",
    ]
    text = "\n".join(lines) + "\n"
    summary_txt.write_text(text, encoding="utf-8")
    print(text, end="")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_prep = sub.add_parser("prepare", help="CREATE TABLE IF NOT EXISTS + TRUNCATE")
    p_prep.set_defaults(func=cmd_prepare)

    p_run = sub.add_parser("run", help="Insert seq 1,2,3... until SIGTERM")
    p_run.add_argument("--attempts", required=True, help="Attempts CSV path")
    p_run.add_argument("--interval", type=float, default=0.25)
    p_run.add_argument("--timeout", type=float, default=8.0)
    p_run.set_defaults(func=cmd_run)

    p_dump = sub.add_parser("dump", help="Dump committed rows to CSV")
    p_dump.add_argument("--out", required=True)
    p_dump.set_defaults(func=cmd_dump)

    p_sum = sub.add_parser("summarize", help="Compare attempts vs committed rows")
    p_sum.add_argument("--attempts", required=True)
    p_sum.add_argument("--committed", required=True)
    p_sum.add_argument("--summary-json", required=True)
    p_sum.add_argument("--summary-txt", required=True)
    p_sum.set_defaults(func=cmd_summarize)

    return parser


def main() -> int:
    args = build_parser().parse_args()
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
