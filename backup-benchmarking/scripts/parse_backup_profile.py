#!/usr/bin/env python3
"""Parse xtrabackup logs and captured metrics to produce a backup profile summary.

Reads the xtrabackup log to extract phase-level timing (data copy, lock,
redo apply, stream/upload), and combines it with MySQL status and pod
resource CSVs to produce:

  - phase_timing.csv       Phase boundaries and durations
  - redo_log_growth.csv    LSN values over time from xtrabackup log
  - profile_summary.txt    Human-readable breakdown of where time was spent

Usage:
  python3 parse_backup_profile.py \
    --xb-log <path> \
    --mysql-status-csv <path> \
    --pod-resources-csv <path> \
    --disk-io-csv <path> \
    --profile-timing <path> \
    --output-dir <path>
"""

from __future__ import annotations

import argparse
import csv
import re
import sys
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path


# ---------------------------------------------------------------------------
# XtraBackup log line patterns
# ---------------------------------------------------------------------------

# Timestamps that xtrabackup may prefix lines with:
#   "2026-07-01T14:23:01.123456+00:00" or "2026-07-01 14:23:01"
XB_TS_RE = re.compile(
    r"^(\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:[+-]\d{2}:?\d{2}|Z)?)\s+"
)

# Phase markers in xtrabackup output
COPY_FILE_RE = re.compile(r"(?:Copying|Streaming)\s+\./(.+\.ibd|ibdata\d+)", re.IGNORECASE)
REDO_SCAN_RE = re.compile(r">> log scanned up to \((\d+)\)")
LOCK_START_RE = re.compile(r"Executing LOCK INSTANCE FOR BACKUP|LOCK TABLES FOR BACKUP", re.IGNORECASE)
LOCK_END_RE = re.compile(r"UNLOCK INSTANCE|UNLOCK TABLES", re.IGNORECASE)
BINLOG_POS_RE = re.compile(r"LOCK BINLOG FOR BACKUP|MySQL binlog position", re.IGNORECASE)
STREAM_RE = re.compile(r"Streaming|Compressing|xbstream|xbcloud|Uploading", re.IGNORECASE)
COMPLETED_RE = re.compile(r"completed OK!?\s*$")
BACKUP_START_RE = re.compile(r"Percona XtraBackup .* started|xtrabackup: using the following InnoDB|version .* based on MySQL", re.IGNORECASE)
DATA_COPY_DONE_RE = re.compile(r"Finished backing up non-InnoDB|All tables unlocked|Starting to backup non-InnoDB", re.IGNORECASE)
REDO_APPLY_RE = re.compile(r"applying redo log|starting redo log apply|redo log applied|redo apply|crash recovery", re.IGNORECASE)


@dataclass
class LogLine:
    """A parsed xtrabackup log line with optional timestamp."""
    raw: str
    timestamp: datetime | None = None
    line_number: int = 0


@dataclass
class Phase:
    """A detected phase in the backup process."""
    name: str
    start_line: int
    end_line: int = 0
    start_ts: datetime | None = None
    end_ts: datetime | None = None

    @property
    def duration_sec(self) -> float | None:
        if self.start_ts and self.end_ts:
            return (self.end_ts - self.start_ts).total_seconds()
        return None

    @property
    def duration_label(self) -> str:
        d = self.duration_sec
        if d is None:
            return "N/A"
        mins, secs = divmod(int(d), 60)
        if mins:
            return f"{mins}m {secs:02d}s"
        return f"{secs}s"


@dataclass
class RedoLogEntry:
    """A single redo log scan entry."""
    timestamp: datetime | None
    lsn: int
    line_number: int


@dataclass
class ProfileData:
    """All data extracted from the xtrabackup log."""
    phases: list[Phase] = field(default_factory=list)
    redo_entries: list[RedoLogEntry] = field(default_factory=list)
    files_copied: list[str] = field(default_factory=list)
    total_start: datetime | None = None
    total_end: datetime | None = None
    xb_version: str = ""


# ---------------------------------------------------------------------------
# Log parsing
# ---------------------------------------------------------------------------

def parse_timestamp(line: str) -> tuple[datetime | None, str]:
    """Extract a leading timestamp from a log line, return (ts, rest_of_line)."""
    m = XB_TS_RE.match(line)
    if not m:
        return None, line

    ts_str = m.group(1)
    rest = line[m.end():]

    for fmt in (
        "%Y-%m-%dT%H:%M:%S.%f%z",
        "%Y-%m-%dT%H:%M:%S%z",
        "%Y-%m-%dT%H:%M:%S.%fZ",
        "%Y-%m-%dT%H:%M:%SZ",
        "%Y-%m-%d %H:%M:%S",
        "%Y-%m-%dT%H:%M:%S",
    ):
        try:
            ts = datetime.strptime(ts_str, fmt)
            if ts.tzinfo is None:
                ts = ts.replace(tzinfo=timezone.utc)
            return ts, rest
        except ValueError:
            continue

    return None, line


def parse_xb_log(path: Path) -> ProfileData:
    """Parse an xtrabackup log file and extract phase boundaries and redo progress."""
    if not path.is_file():
        return ProfileData()

    data = ProfileData()
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()

    current_phase: str | None = None
    phase_start_ts: datetime | None = None
    phase_start_line: int = 0
    last_ts: datetime | None = None

    for i, raw_line in enumerate(lines, start=1):
        ts, content = parse_timestamp(raw_line)
        if ts:
            last_ts = ts
        effective_ts = ts or last_ts

        # Track overall start
        if data.total_start is None and effective_ts:
            data.total_start = effective_ts

        # XtraBackup version
        if not data.xb_version:
            ver_m = re.search(r"Percona XtraBackup\s+([\d.]+\S*)", raw_line)
            if ver_m:
                data.xb_version = ver_m.group(1)

        # Detect phase transitions
        detected_phase: str | None = None

        if BACKUP_START_RE.search(content):
            detected_phase = "startup"
        elif COPY_FILE_RE.search(content):
            m = COPY_FILE_RE.search(content)
            if m:
                data.files_copied.append(m.group(1))
            detected_phase = "data_copy"
        elif LOCK_START_RE.search(content):
            detected_phase = "lock_and_metadata"
        elif LOCK_END_RE.search(content) or BINLOG_POS_RE.search(content):
            if current_phase == "lock_and_metadata":
                # End of lock phase — don't override, just note end
                pass
            detected_phase = "finalize_metadata"
        elif STREAM_RE.search(content) and current_phase not in ("data_copy",):
            detected_phase = "stream_upload"
        elif REDO_APPLY_RE.search(content):
            detected_phase = "redo_apply"
        elif COMPLETED_RE.search(content):
            detected_phase = "completed"

        # Redo log scan entries (happen during data_copy)
        redo_m = REDO_SCAN_RE.search(content)
        if redo_m:
            data.redo_entries.append(RedoLogEntry(
                timestamp=effective_ts,
                lsn=int(redo_m.group(1)),
                line_number=i,
            ))
            if current_phase is None:
                detected_phase = "data_copy"

        # Record phase transition
        if detected_phase and detected_phase != current_phase:
            if current_phase is not None:
                data.phases[-1].end_line = i - 1
                data.phases[-1].end_ts = effective_ts

            data.phases.append(Phase(
                name=detected_phase,
                start_line=i,
                start_ts=effective_ts,
            ))
            current_phase = detected_phase

    # Close last phase
    if data.phases:
        data.phases[-1].end_line = len(lines)
        data.phases[-1].end_ts = last_ts

    data.total_end = last_ts

    return data


def merge_adjacent_phases(data: ProfileData) -> ProfileData:
    """Merge consecutive phases of the same type."""
    if not data.phases:
        return data

    merged: list[Phase] = [data.phases[0]]
    for phase in data.phases[1:]:
        if phase.name == merged[-1].name:
            merged[-1].end_line = phase.end_line
            merged[-1].end_ts = phase.end_ts
        else:
            merged.append(phase)

    data.phases = merged
    return data


# ---------------------------------------------------------------------------
# Consolidate into canonical phases
# ---------------------------------------------------------------------------

CANONICAL_ORDER = [
    "startup",
    "data_copy",
    "lock_and_metadata",
    "finalize_metadata",
    "stream_upload",
    "redo_apply",
    "completed",
]

PHASE_LABELS = {
    "startup": "Startup / init",
    "data_copy": "InnoDB data copy",
    "lock_and_metadata": "Lock + metadata copy",
    "finalize_metadata": "Binlog position + unlock",
    "stream_upload": "Stream / upload to storage",
    "redo_apply": "Redo log apply (crash recovery)",
    "completed": "Completion",
}


def consolidate_phases(data: ProfileData) -> list[Phase]:
    """Group raw phases into canonical categories, summing durations."""
    by_name: dict[str, Phase] = {}
    for phase in data.phases:
        if phase.name not in by_name:
            by_name[phase.name] = Phase(
                name=phase.name,
                start_line=phase.start_line,
                end_line=phase.end_line,
                start_ts=phase.start_ts,
                end_ts=phase.end_ts,
            )
        else:
            existing = by_name[phase.name]
            existing.end_line = phase.end_line
            if phase.end_ts:
                existing.end_ts = phase.end_ts

    ordered = []
    for name in CANONICAL_ORDER:
        if name in by_name:
            ordered.append(by_name[name])
    for name, phase in by_name.items():
        if name not in CANONICAL_ORDER:
            ordered.append(phase)

    return ordered


# ---------------------------------------------------------------------------
# MySQL status analysis
# ---------------------------------------------------------------------------

@dataclass
class MySQLStatusSummary:
    samples: int = 0
    redo_written_bytes: int = 0
    data_read_bytes: int = 0
    data_written_bytes: int = 0
    peak_dirty_pages: int = 0
    peak_threads_running: int = 0
    peak_checkpoint_age: int = 0


def analyze_mysql_status(csv_path: Path) -> MySQLStatusSummary:
    summary = MySQLStatusSummary()
    if not csv_path.is_file():
        return summary

    rows: list[dict[str, str]] = []
    with csv_path.open(encoding="utf-8", errors="replace", newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            rows.append(row)

    if not rows:
        return summary

    summary.samples = len(rows)

    first = rows[0]
    last = rows[-1]

    def delta(key: str) -> int:
        try:
            return int(last.get(key, 0)) - int(first.get(key, 0))
        except (ValueError, TypeError):
            return 0

    summary.redo_written_bytes = delta("innodb_os_log_written")
    summary.data_read_bytes = delta("innodb_data_read")
    summary.data_written_bytes = delta("innodb_data_written")

    for row in rows:
        try:
            dirty = int(row.get("innodb_buffer_pool_pages_dirty", 0))
            if dirty > summary.peak_dirty_pages:
                summary.peak_dirty_pages = dirty
        except (ValueError, TypeError):
            pass
        try:
            threads = int(row.get("threads_running", 0))
            if threads > summary.peak_threads_running:
                summary.peak_threads_running = threads
        except (ValueError, TypeError):
            pass
        try:
            ckpt = int(row.get("checkpoint_age", 0))
            if ckpt > summary.peak_checkpoint_age:
                summary.peak_checkpoint_age = ckpt
        except (ValueError, TypeError):
            pass

    return summary


# ---------------------------------------------------------------------------
# Pod resource analysis
# ---------------------------------------------------------------------------

@dataclass
class PodResourceSummary:
    samples: int = 0
    peak_cpu_millicores: int = 0
    peak_memory_mib: int = 0
    peak_cpu_container: str = ""


def analyze_pod_resources(csv_path: Path) -> PodResourceSummary:
    summary = PodResourceSummary()
    if not csv_path.is_file():
        return summary

    with csv_path.open(encoding="utf-8", errors="replace", newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            summary.samples += 1
            try:
                cpu = int(row.get("cpu_millicores", 0))
                if cpu > summary.peak_cpu_millicores:
                    summary.peak_cpu_millicores = cpu
                    summary.peak_cpu_container = row.get("container", "")
            except (ValueError, TypeError):
                pass
            try:
                mem = int(row.get("memory_mib", 0))
                if mem > summary.peak_memory_mib:
                    summary.peak_memory_mib = mem
            except (ValueError, TypeError):
                pass

    return summary


# ---------------------------------------------------------------------------
# Disk I/O analysis
# ---------------------------------------------------------------------------

@dataclass
class DiskIOSummary:
    samples: int = 0
    total_sectors_read: int = 0
    total_sectors_written: int = 0
    total_ms_reading: int = 0
    total_ms_writing: int = 0
    device: str = ""


@dataclass
class PhaseIOMetrics:
    """I/O metrics for a single phase, derived from disk_io.csv and mysql_status.csv."""
    bytes_read: int = 0
    bytes_written: int = 0
    duration_sec: float = 0
    redo_lsn_delta: int = 0

    @property
    def read_throughput(self) -> float:
        return self.bytes_read / self.duration_sec if self.duration_sec > 0 else 0

    @property
    def write_throughput(self) -> float:
        return self.bytes_written / self.duration_sec if self.duration_sec > 0 else 0


@dataclass
class TimestampedRow:
    epoch: int
    data: dict[str, str]


def _load_timestamped_csv(csv_path: Path) -> list[TimestampedRow]:
    """Load a CSV with an 'epoch' column into timestamped rows."""
    rows: list[TimestampedRow] = []
    if not csv_path.is_file():
        return rows
    with csv_path.open(encoding="utf-8", errors="replace", newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            try:
                epoch = int(row.get("epoch", 0))
                rows.append(TimestampedRow(epoch=epoch, data=row))
            except (ValueError, TypeError):
                pass
    return rows


def _phase_epoch_range(phase: Phase) -> tuple[int, int]:
    """Convert phase timestamps to epoch range."""
    start = int(phase.start_ts.timestamp()) if phase.start_ts else 0
    end = int(phase.end_ts.timestamp()) if phase.end_ts else 0
    return start, end


def _filter_rows(rows: list[TimestampedRow], start: int, end: int) -> list[TimestampedRow]:
    """Filter rows to those within [start, end] epoch range."""
    if start == 0 or end == 0:
        return []
    return [r for r in rows if start <= r.epoch <= end]


def compute_phase_io(
    phase: Phase,
    disk_rows: list[TimestampedRow],
    mysql_rows: list[TimestampedRow],
    redo_entries: list[RedoLogEntry],
) -> PhaseIOMetrics:
    """Compute I/O metrics for a phase by filtering captured CSVs to its time window."""
    metrics = PhaseIOMetrics()
    start_epoch, end_epoch = _phase_epoch_range(phase)
    if start_epoch == 0 or end_epoch == 0:
        return metrics

    metrics.duration_sec = phase.duration_sec or 0

    # Disk I/O: find delta in sectors for the busiest device within the phase window
    phase_disk = _filter_rows(disk_rows, start_epoch, end_epoch)
    if len(phase_disk) >= 2:
        by_dev: dict[str, list[TimestampedRow]] = {}
        for r in phase_disk:
            dev = r.data.get("device", "")
            by_dev.setdefault(dev, []).append(r)

        max_read = 0
        for dev, dev_rows in by_dev.items():
            first, last = dev_rows[0], dev_rows[-1]
            try:
                sr = int(last.data.get("sectors_read", 0)) - int(first.data.get("sectors_read", 0))
                sw = int(last.data.get("sectors_written", 0)) - int(first.data.get("sectors_written", 0))
                if sr > max_read:
                    max_read = sr
                    metrics.bytes_read = sr * 512
                    metrics.bytes_written = sw * 512
            except (ValueError, TypeError):
                pass

    # Fall back to MySQL innodb_data_read if disk I/O data is sparse
    if metrics.bytes_read == 0:
        phase_mysql = _filter_rows(mysql_rows, start_epoch, end_epoch)
        if len(phase_mysql) >= 2:
            first_m, last_m = phase_mysql[0], phase_mysql[-1]
            try:
                metrics.bytes_read = (
                    int(last_m.data.get("innodb_data_read", 0))
                    - int(first_m.data.get("innodb_data_read", 0))
                )
                metrics.bytes_written = (
                    int(last_m.data.get("innodb_data_written", 0))
                    - int(first_m.data.get("innodb_data_written", 0))
                )
            except (ValueError, TypeError):
                pass

    # Redo log LSN delta during this phase
    phase_redo = [
        e for e in redo_entries
        if e.timestamp and start_epoch <= int(e.timestamp.timestamp()) <= end_epoch
    ]
    if len(phase_redo) >= 2:
        metrics.redo_lsn_delta = phase_redo[-1].lsn - phase_redo[0].lsn

    return metrics


def analyze_disk_io(csv_path: Path) -> DiskIOSummary:
    summary = DiskIOSummary()
    if not csv_path.is_file():
        return summary

    first_by_dev: dict[str, dict[str, str]] = {}
    last_by_dev: dict[str, dict[str, str]] = {}

    with csv_path.open(encoding="utf-8", errors="replace", newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            summary.samples += 1
            dev = row.get("device", "")
            if dev not in first_by_dev:
                first_by_dev[dev] = row
            last_by_dev[dev] = row

    max_read = 0
    for dev in first_by_dev:
        first = first_by_dev[dev]
        last = last_by_dev[dev]
        try:
            sectors_read = int(last.get("sectors_read", 0)) - int(first.get("sectors_read", 0))
            sectors_written = int(last.get("sectors_written", 0)) - int(first.get("sectors_written", 0))
            ms_reading = int(last.get("ms_reading", 0)) - int(first.get("ms_reading", 0))
            ms_writing = int(last.get("ms_writing", 0)) - int(first.get("ms_writing", 0))
            if sectors_read > max_read:
                summary.device = dev
                summary.total_sectors_read = sectors_read
                summary.total_sectors_written = sectors_written
                summary.total_ms_reading = ms_reading
                summary.total_ms_writing = ms_writing
                max_read = sectors_read
        except (ValueError, TypeError):
            pass

    return summary


# ---------------------------------------------------------------------------
# Output: phase_timing.csv
# ---------------------------------------------------------------------------

def write_phase_timing_csv(
    phases: list[Phase],
    phase_io: dict[str, PhaseIOMetrics],
    out_path: Path,
) -> None:
    with out_path.open("w", encoding="utf-8", newline="") as f:
        writer = csv.writer(f)
        writer.writerow([
            "phase", "label", "start_utc", "end_utc", "duration_sec",
            "bytes_read", "bytes_written", "read_throughput_bytes_s",
            "write_throughput_bytes_s", "redo_lsn_delta",
        ])
        for phase in phases:
            start_str = phase.start_ts.strftime("%Y-%m-%dT%H:%M:%SZ") if phase.start_ts else ""
            end_str = phase.end_ts.strftime("%Y-%m-%dT%H:%M:%SZ") if phase.end_ts else ""
            dur = f"{phase.duration_sec:.1f}" if phase.duration_sec is not None else ""
            label = PHASE_LABELS.get(phase.name, phase.name)
            io = phase_io.get(phase.name, PhaseIOMetrics())
            writer.writerow([
                phase.name, label, start_str, end_str, dur,
                io.bytes_read, io.bytes_written,
                f"{io.read_throughput:.0f}", f"{io.write_throughput:.0f}",
                io.redo_lsn_delta,
            ])


# ---------------------------------------------------------------------------
# Output: redo_log_growth.csv
# ---------------------------------------------------------------------------

def write_redo_log_csv(entries: list[RedoLogEntry], out_path: Path) -> None:
    with out_path.open("w", encoding="utf-8", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["timestamp", "lsn", "lsn_delta_bytes"])
        prev_lsn = None
        for entry in entries:
            ts_str = entry.timestamp.strftime("%Y-%m-%dT%H:%M:%SZ") if entry.timestamp else ""
            delta = entry.lsn - prev_lsn if prev_lsn is not None else 0
            writer.writerow([ts_str, entry.lsn, delta])
            prev_lsn = entry.lsn


# ---------------------------------------------------------------------------
# Output: profile_summary.txt
# ---------------------------------------------------------------------------

def fmt_bytes(b: int | float) -> str:
    if b <= 0:
        return "0 B"
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if abs(b) < 1024:
            return f"{b:.1f} {unit}"
        b /= 1024
    return f"{b:.1f} PB"


def fmt_duration(sec: float | int | None) -> str:
    if sec is None or sec < 0:
        return "N/A"
    sec = int(sec)
    mins, secs = divmod(sec, 60)
    hours, mins = divmod(mins, 60)
    if hours:
        return f"{hours}h {mins:02d}m {secs:02d}s ({int(sec + hours * 3600)}s)"
    if mins:
        return f"{mins}m {secs:02d}s ({int(sec + mins * 60)}s)"
    return f"{secs}s"


def _throughput_note(io: PhaseIOMetrics, phase_name: str) -> str:
    """Build a short throughput annotation string for a phase line."""
    parts: list[str] = []

    if phase_name in ("data_copy", "redo_apply") and io.bytes_read > 0:
        parts.append(f"read {fmt_bytes(io.read_throughput)}/s")
    if phase_name in ("stream_upload",) and io.bytes_written > 0:
        parts.append(f"write {fmt_bytes(io.write_throughput)}/s")
    if phase_name == "data_copy" and io.bytes_written == 0 and io.bytes_read == 0:
        pass
    elif phase_name not in ("data_copy", "redo_apply", "stream_upload"):
        if io.bytes_read > 0:
            parts.append(f"read {fmt_bytes(io.read_throughput)}/s")
        if io.bytes_written > 0:
            parts.append(f"write {fmt_bytes(io.write_throughput)}/s")

    if not parts:
        return ""
    return "  [" + ", ".join(parts) + "]"


def write_profile_summary(
    data: ProfileData,
    consolidated: list[Phase],
    phase_io: dict[str, PhaseIOMetrics],
    mysql_summary: MySQLStatusSummary,
    resource_summary: PodResourceSummary,
    disk_summary: DiskIOSummary,
    timing: dict[str, str],
    out_path: Path,
) -> None:
    total_sec: float | None = None
    if data.total_start and data.total_end:
        total_sec = (data.total_end - data.total_start).total_seconds()

    # Use profile_timing.env if xtrabackup timestamps aren't available
    if total_sec is None or total_sec <= 0:
        env_dur = timing.get("BACKUP_PROFILE_DURATION_SEC")
        if env_dur:
            total_sec = float(env_dur)

    lines: list[str] = []
    lines.append("=" * 60)
    lines.append("  Backup Profile Summary")
    lines.append("=" * 60)
    lines.append("")

    if data.xb_version:
        lines.append(f"XtraBackup version:  {data.xb_version}")
    lines.append(f"Total duration:      {fmt_duration(total_sec)}")
    lines.append(f"Files copied:        {len(data.files_copied)}")
    lines.append("")

    # Phase breakdown with throughput
    lines.append("-" * 60)
    lines.append("  Phase Breakdown")
    lines.append("-" * 60)

    has_timing = any(p.duration_sec is not None for p in consolidated)
    if has_timing and total_sec and total_sec > 0:
        for phase in consolidated:
            if phase.name == "completed":
                continue
            dur = phase.duration_sec
            label = PHASE_LABELS.get(phase.name, phase.name)
            io = phase_io.get(phase.name, PhaseIOMetrics())
            throughput = _throughput_note(io, phase.name)
            if dur is not None:
                pct = (dur / total_sec) * 100
                lines.append(
                    f"  {label:<38s} {phase.duration_label:>10s}  ({pct:5.1f}%)"
                    f"{throughput}"
                )
            else:
                lines.append(f"  {label:<38s} {'N/A':>10s}")
    elif consolidated:
        lines.append("  (No timestamps found in xtrabackup log — phase durations unavailable)")
        lines.append("  Detected phases by log markers:")
        for phase in consolidated:
            label = PHASE_LABELS.get(phase.name, phase.name)
            lines.append(f"    - {label} (lines {phase.start_line}-{phase.end_line})")
    else:
        lines.append("  (No xtrabackup phase markers found in log)")

    # Per-phase data volume details
    has_io = any(io.bytes_read > 0 or io.bytes_written > 0 for io in phase_io.values())
    if has_io:
        lines.append("")
        lines.append("  Per-phase data volume:")
        for phase in consolidated:
            if phase.name == "completed":
                continue
            io = phase_io.get(phase.name, PhaseIOMetrics())
            if io.bytes_read <= 0 and io.bytes_written <= 0:
                continue
            label = PHASE_LABELS.get(phase.name, phase.name)
            parts = []
            if io.bytes_read > 0:
                parts.append(f"read {fmt_bytes(io.bytes_read)}")
            if io.bytes_written > 0:
                parts.append(f"written {fmt_bytes(io.bytes_written)}")
            if io.redo_lsn_delta > 0:
                parts.append(f"redo {fmt_bytes(io.redo_lsn_delta)}")
            lines.append(f"    {label:<36s} {', '.join(parts)}")

    lines.append("")

    # Redo log
    if data.redo_entries:
        first_lsn = data.redo_entries[0].lsn
        last_lsn = data.redo_entries[-1].lsn
        lsn_growth = last_lsn - first_lsn
        lines.append("-" * 60)
        lines.append("  Redo Log")
        lines.append("-" * 60)
        lines.append(f"  LSN range:           {first_lsn} -> {last_lsn}")
        lines.append(f"  Redo accumulated:    {fmt_bytes(lsn_growth)}")
        lines.append(f"  Scan entries:        {len(data.redo_entries)}")
        if data.redo_entries[0].timestamp and data.redo_entries[-1].timestamp:
            span = (data.redo_entries[-1].timestamp - data.redo_entries[0].timestamp).total_seconds()
            if span > 0:
                rate = lsn_growth / span
                lines.append(f"  Avg redo rate:       {fmt_bytes(rate)}/s")
        lines.append("")

    # MySQL status
    if mysql_summary.samples > 0:
        lines.append("-" * 60)
        lines.append("  MySQL Server Metrics")
        lines.append("-" * 60)
        lines.append(f"  Samples:             {mysql_summary.samples}")
        if mysql_summary.redo_written_bytes > 0:
            lines.append(f"  Redo log written:    {fmt_bytes(mysql_summary.redo_written_bytes)}")
        if mysql_summary.data_read_bytes > 0:
            lines.append(f"  Data read:           {fmt_bytes(mysql_summary.data_read_bytes)}")
        if mysql_summary.data_written_bytes > 0:
            lines.append(f"  Data written:        {fmt_bytes(mysql_summary.data_written_bytes)}")
        if mysql_summary.peak_dirty_pages > 0:
            lines.append(f"  Peak dirty pages:    {mysql_summary.peak_dirty_pages}")
        if mysql_summary.peak_threads_running > 0:
            lines.append(f"  Peak threads:        {mysql_summary.peak_threads_running}")
        if mysql_summary.peak_checkpoint_age > 0:
            lines.append(f"  Peak checkpoint age: {fmt_bytes(mysql_summary.peak_checkpoint_age)}")
        lines.append("")

    # Pod resources
    if resource_summary.samples > 0:
        lines.append("-" * 60)
        lines.append("  Pod Resources")
        lines.append("-" * 60)
        lines.append(f"  Samples:             {resource_summary.samples}")
        cpu_val = resource_summary.peak_cpu_millicores
        cpu_label = f"{cpu_val}m"
        if cpu_val >= 1000:
            cpu_label += f" ({cpu_val / 1000:.1f} cores)"
        container_note = f" ({resource_summary.peak_cpu_container})" if resource_summary.peak_cpu_container else ""
        lines.append(f"  Peak CPU:            {cpu_label}{container_note}")
        lines.append(f"  Peak memory:         {resource_summary.peak_memory_mib} MiB")
        lines.append("")

    # Disk I/O
    if disk_summary.samples > 0 and disk_summary.total_sectors_read > 0:
        bytes_read = disk_summary.total_sectors_read * 512
        bytes_written = disk_summary.total_sectors_written * 512
        lines.append("-" * 60)
        lines.append("  Disk I/O")
        lines.append("-" * 60)
        lines.append(f"  Device:              {disk_summary.device}")
        lines.append(f"  Data read:           {fmt_bytes(bytes_read)}")
        lines.append(f"  Data written:        {fmt_bytes(bytes_written)}")
        if total_sec and total_sec > 0:
            lines.append(f"  Avg read throughput: {fmt_bytes(bytes_read / total_sec)}/s")
            lines.append(f"  Avg write throughput:{fmt_bytes(bytes_written / total_sec)}/s")
        if disk_summary.total_ms_reading > 0:
            lines.append(f"  Time in reads:       {fmt_duration(disk_summary.total_ms_reading / 1000)}")
        if disk_summary.total_ms_writing > 0:
            lines.append(f"  Time in writes:      {fmt_duration(disk_summary.total_ms_writing / 1000)}")
        lines.append("")

    lines.append("=" * 60)

    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


# ---------------------------------------------------------------------------
# Load profile_timing.env
# ---------------------------------------------------------------------------

def load_timing_env(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.is_file():
        return values
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if "=" in line and not line.startswith("#"):
            k, _, v = line.partition("=")
            values[k] = v
    return values


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--xb-log", type=Path, required=True, help="xtrabackup.log path")
    parser.add_argument("--mysql-status-csv", type=Path, required=True)
    parser.add_argument("--pod-resources-csv", type=Path, required=True)
    parser.add_argument("--disk-io-csv", type=Path, default=None)
    parser.add_argument("--profile-timing", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()

    out_dir = args.output_dir
    out_dir.mkdir(parents=True, exist_ok=True)

    timing = load_timing_env(args.profile_timing)

    # Parse xtrabackup log
    data = parse_xb_log(args.xb_log)
    data = merge_adjacent_phases(data)

    if not data.phases:
        print(
            f"WARNING: No xtrabackup phase markers found in {args.xb_log}",
            file=sys.stderr,
        )
        if args.xb_log.is_file() and args.xb_log.stat().st_size == 0:
            print(
                "  (xtrabackup.log is empty — the backup log stream may not have captured output)",
                file=sys.stderr,
            )

    consolidated = consolidate_phases(data)

    # Load timestamped CSVs for per-phase I/O analysis
    disk_rows = _load_timestamped_csv(args.disk_io_csv) if args.disk_io_csv else []
    mysql_rows = _load_timestamped_csv(args.mysql_status_csv)

    # Compute per-phase I/O metrics
    phase_io: dict[str, PhaseIOMetrics] = {}
    for phase in consolidated:
        phase_io[phase.name] = compute_phase_io(
            phase, disk_rows, mysql_rows, data.redo_entries,
        )

    # Write phase_timing.csv (now includes throughput columns)
    phase_csv = out_dir / "phase_timing.csv"
    write_phase_timing_csv(consolidated, phase_io, phase_csv)
    print(f"  phase_timing.csv     {len(consolidated)} phases")

    # Write redo_log_growth.csv
    if data.redo_entries:
        redo_csv = out_dir / "redo_log_growth.csv"
        write_redo_log_csv(data.redo_entries, redo_csv)
        print(f"  redo_log_growth.csv  {len(data.redo_entries)} entries")

    # Analyze supplementary data (overall summaries)
    mysql_summary = analyze_mysql_status(args.mysql_status_csv)
    resource_summary = analyze_pod_resources(args.pod_resources_csv)
    disk_summary = DiskIOSummary()
    if args.disk_io_csv:
        disk_summary = analyze_disk_io(args.disk_io_csv)

    # Write profile_summary.txt
    summary_path = out_dir / "profile_summary.txt"
    write_profile_summary(
        data, consolidated, phase_io, mysql_summary, resource_summary,
        disk_summary, timing, summary_path,
    )
    print(f"  profile_summary.txt  written")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
