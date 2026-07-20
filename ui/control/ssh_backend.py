"""SSH access to the benchmark droplet (uses system ssh/scp)."""

from __future__ import annotations

import os
import shlex
import subprocess
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class DropletConfig:
    host: str
    user: str
    remote_repo: str
    remote_conf: str
    ssh_key: str = ""
    ssh_port: int = 22
    runs_min_id: str = ""
    name: str = ""
    compare_runs_limit: int = 6
    # Additional droplets to browse reports from, as ((name, host), ...).
    droplets: tuple[tuple[str, str], ...] = ()

    @property
    def remote_conf_path(self) -> str:
        repo = self.remote_repo.rstrip("/")
        conf = self.remote_conf.lstrip("/")
        return f"{repo}/{conf}"

    def with_overrides(self, overrides: dict[str, str]) -> DropletConfig:
        """Return a copy with optional droplet SSH fields replaced."""
        host = overrides.get("DROPLET_HOST") or overrides.get("host") or self.host
        user = overrides.get("DROPLET_USER") or overrides.get("user") or self.user
        repo = overrides.get("REMOTE_REPO") or overrides.get("remote_repo") or self.remote_repo
        name = overrides.get("DROPLET_NAME") or overrides.get("name") or self.name
        port_raw = overrides.get("DROPLET_SSH_PORT") or overrides.get("ssh_port") or str(self.ssh_port)
        try:
            port = int(port_raw)
        except ValueError:
            port = self.ssh_port
        return DropletConfig(
            host=host,
            user=user,
            remote_repo=repo,
            remote_conf=self.remote_conf,
            ssh_key=self.ssh_key,
            ssh_port=port,
            runs_min_id=self.runs_min_id,
            name=name,
            droplets=self.droplets,
        )


def parse_droplet_map(raw: str) -> tuple[tuple[str, str], ...]:
    """Parse ``name:host, name:host`` pairs into a ((name, host), ...) tuple.

    Entries without a colon are treated as a bare host (name defaults to host).
    """
    entries: list[tuple[str, str]] = []
    seen: set[str] = set()
    for chunk in raw.split(","):
        chunk = chunk.strip()
        if not chunk:
            continue
        if ":" in chunk:
            name, host = chunk.split(":", 1)
        else:
            name = host = chunk
        name = name.strip()
        host = host.strip()
        if not host or host in seen:
            continue
        seen.add(host)
        entries.append((name or host, host))
    return tuple(entries)


def _read_kv_file(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip().strip('"').strip("'")
    return values


def _env_first(*names: str, default: str = "") -> str:
    for name in names:
        raw = os.environ.get(name)
        if raw is not None and str(raw).strip() != "":
            return str(raw).strip()
    return default


def materialize_ssh_key_from_env(artifacts_dir: Path | None = None) -> str:
    """Write BENCHMARK_SSH_PRIVATE_KEY to a file if set; return key path."""
    existing = _env_first("CI_SSH_KEY_FILE", "DROPLET_SSH_KEY")
    if existing:
        path = Path(os.path.expanduser(existing))
        if path.is_file():
            return str(path)

    private_key = os.environ.get("BENCHMARK_SSH_PRIVATE_KEY", "")
    if not private_key.strip():
        return ""

    base = artifacts_dir or Path(os.environ.get("TMPDIR") or "/tmp") / "mysql-benchmark-ui"
    key_dir = base / ".ssh"
    key_dir.mkdir(parents=True, exist_ok=True)
    key_dir.chmod(0o700)
    key_path = key_dir / "benchmark_ui_key"
    # Normalize newlines; strip accidental CRLF from secret stores.
    text = private_key.replace("\r\n", "\n").replace("\r", "\n")
    if not text.endswith("\n"):
        text += "\n"
    key_path.write_text(text, encoding="utf-8")
    key_path.chmod(0o600)
    return str(key_path)


def load_droplet_config(path: Path) -> DropletConfig:
    values = _read_kv_file(path)
    return _build_droplet_config(values, source=str(path))


def resolve_droplet_config(config_path: Path | None = None) -> DropletConfig:
    """Load from optional file, then overlay App Platform / env settings."""
    values: dict[str, str] = {}
    source = "environment"
    if config_path is not None and config_path.is_file():
        values.update(_read_kv_file(config_path))
        source = str(config_path)

    # Env overlays (GHA / App Platform naming).
    overlays = {
        "DROPLET_HOST": _env_first("BENCHMARK_DROPLET_HOST", "DROPLET_HOST"),
        "DROPLET_NAME": _env_first("BENCHMARK_DROPLET_NAME", "DROPLET_NAME"),
        "DROPLET_USER": _env_first("BENCHMARK_DROPLET_USER", "DROPLET_USER"),
        "DROPLET_SSH_PORT": _env_first("BENCHMARK_DROPLET_SSH_PORT", "DROPLET_SSH_PORT"),
        "REMOTE_REPO": _env_first("BENCHMARK_REMOTE_REPO", "REMOTE_REPO"),
        "REMOTE_BENCHMARK_CONF": _env_first("BENCHMARK_REMOTE_BENCHMARK_CONF", "REMOTE_BENCHMARK_CONF"),
        "DROPLET_MAP": _env_first("BENCHMARK_DROPLET_MAP", "DROPLET_MAP"),
        "RUNS_MIN_ID": _env_first("RUNS_MIN_ID"),
        "COMPARE_RUNS_LIMIT": _env_first("COMPARE_RUNS_LIMIT"),
        "DROPLET_SSH_KEY": _env_first("CI_SSH_KEY_FILE", "DROPLET_SSH_KEY"),
    }
    for key, value in overlays.items():
        if value:
            values[key] = value

    ssh_key = materialize_ssh_key_from_env()
    if ssh_key:
        values["DROPLET_SSH_KEY"] = ssh_key

    # If only MAP is set, default host is the first entry.
    if not values.get("DROPLET_HOST") and values.get("DROPLET_MAP"):
        mapped = parse_droplet_map(values["DROPLET_MAP"])
        if mapped:
            values.setdefault("DROPLET_NAME", mapped[0][0])
            values["DROPLET_HOST"] = mapped[0][1]

    values.setdefault("DROPLET_USER", "root")
    values.setdefault("REMOTE_REPO", "/root/mysql-benchmark")
    values.setdefault("REMOTE_BENCHMARK_CONF", "benchmark.conf")

    return _build_droplet_config(values, source=source)


def _build_droplet_config(values: dict[str, str], *, source: str) -> DropletConfig:
    missing = [key for key in ("DROPLET_HOST", "DROPLET_USER", "REMOTE_REPO") if not values.get(key)]
    if missing:
        raise ValueError(
            f"Missing required config ({', '.join(missing)}). "
            f"Set them in {source} or env (DROPLET_HOST / BENCHMARK_DROPLET_MAP, "
            f"DROPLET_USER, REMOTE_REPO / BENCHMARK_REMOTE_REPO)."
        )

    ssh_key = values.get("DROPLET_SSH_KEY", "")
    if ssh_key.startswith("~"):
        ssh_key = os.path.expanduser(ssh_key)

    runs_min_id = values.get("RUNS_MIN_ID", "").strip()
    if runs_min_id and not runs_min_id.startswith("failover_"):
        runs_min_id = f"failover_{runs_min_id}"

    return DropletConfig(
        host=values["DROPLET_HOST"],
        user=values["DROPLET_USER"],
        remote_repo=values["REMOTE_REPO"],
        remote_conf=values.get("REMOTE_BENCHMARK_CONF", "benchmark.conf"),
        ssh_key=ssh_key,
        ssh_port=int(values.get("DROPLET_SSH_PORT", "22") or "22"),
        runs_min_id=runs_min_id,
        name=values.get("DROPLET_NAME", "").strip(),
        compare_runs_limit=max(1, min(int(values.get("COMPARE_RUNS_LIMIT", "6") or "6"), 12)),
        droplets=parse_droplet_map(values.get("DROPLET_MAP", "")),
    )


class SshBackend:
    def __init__(self, config: DropletConfig) -> None:
        self.config = config

    def _base_ssh(self) -> list[str]:
        cmd = [
            "ssh",
            "-o",
            "BatchMode=yes",
            "-o",
            "ConnectTimeout=15",
            "-o",
            "StrictHostKeyChecking=accept-new",
            "-p",
            str(self.config.ssh_port),
        ]
        if self.config.ssh_key:
            cmd.extend(["-i", self.config.ssh_key])
        cmd.append(f"{self.config.user}@{self.config.host}")
        return cmd

    def _base_scp(self) -> list[str]:
        cmd = [
            "scp",
            "-o",
            "BatchMode=yes",
            "-o",
            "ConnectTimeout=15",
            "-o",
            "StrictHostKeyChecking=accept-new",
            "-P",
            str(self.config.ssh_port),
        ]
        if self.config.ssh_key:
            cmd.extend(["-i", self.config.ssh_key])
        return cmd

    def run(self, remote_command: str, *, check: bool = True) -> subprocess.CompletedProcess[str]:
        cmd = self._base_ssh() + [remote_command]
        return subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            check=check,
        )

    def read_file(self, remote_path: str) -> str:
        result = self.run(f"cat {shlex.quote(remote_path)}")
        return result.stdout

    def write_file(self, remote_path: str, content: str) -> None:
        local_tmp = Path(os.environ.get("TMPDIR", "/tmp")) / "benchmark_conf_upload.tmp"
        local_tmp.write_text(content, encoding="utf-8")
        remote_tmp = f"{remote_path}.ui_upload"
        backup = f"{remote_path}.bak"

        scp_cmd = self._base_scp() + [str(local_tmp), f"{self.config.user}@{self.config.host}:{remote_tmp}"]
        subprocess.run(scp_cmd, capture_output=True, text=True, check=True)

        install_cmd = (
            f"set -e; "
            f"if [ -f {shlex.quote(remote_path)} ]; then cp {shlex.quote(remote_path)} {shlex.quote(backup)}; fi; "
            f"mv {shlex.quote(remote_tmp)} {shlex.quote(remote_path)}"
        )
        self.run(install_cmd)

    def _ssh_run(self, remote_command: str) -> subprocess.CompletedProcess[str]:
        """Run SSH without raising; always captures stdout/stderr."""
        cmd = self._base_ssh() + [remote_command]
        return subprocess.run(cmd, capture_output=True, text=True, check=False)

    @staticmethod
    def _ssh_error_detail(result: subprocess.CompletedProcess[str]) -> str:
        parts = [result.stderr.strip(), result.stdout.strip()]
        detail = "\n".join(p for p in parts if p)
        return detail or f"SSH exited with code {result.returncode}"

    def test_connection(self) -> tuple[bool, str]:
        target = f"{self.config.user}@{self.config.host}:{self.config.ssh_port}"
        repo = self.config.remote_repo

        ping = self._ssh_run("echo OK")
        if ping.returncode != 0:
            detail = self._ssh_error_detail(ping)
            hint = ""
            if "Permission denied" in detail or ping.returncode == 255:
                hint = (
                    " Check SSH key access (add DROPLET_SSH_KEY to control.local.conf "
                    "or your ~/.ssh/config for this host)."
                )
            return False, f"SSH to {target} failed: {detail}.{hint}"

        if ping.stdout.strip() != "OK":
            return False, f"SSH to {target} returned unexpected response."

        repo_q = shlex.quote(repo)
        repo_check = self._ssh_run(f"test -d {repo_q} && echo REPO_OK")
        if repo_check.returncode != 0 or "REPO_OK" not in repo_check.stdout:
            return False, (
                f"SSH to {target} works, but repo path is missing: {repo}\n"
                f"Clone and set up the benchmark repo on this droplet, e.g.:\n"
                f"  ssh {self.config.user}@{self.config.host} "
                f"'git clone <your-repo-url> {repo} && cd {repo} && ./bootstrap/setup_benchmark.sh'"
            )

        ctl = f"{repo_q}/scripts/prepare_run_ctl.sh"
        script_check = self._ssh_run(f"test -x {ctl} && echo SCRIPTS_OK")
        if script_check.returncode != 0 or "SCRIPTS_OK" not in script_check.stdout:
            return False, (
                f"SSH and repo path OK ({repo}), but prepare scripts are missing or not executable.\n"
                f"On the droplet run: chmod +x {repo}/scripts/prepare_*.sh"
            )

        return True, f"Connected to {target} — repo ready at {repo}"

    def ctl(self, action: str, *args: str) -> subprocess.CompletedProcess[str]:
        repo = shlex.quote(self.config.remote_repo)
        ctl = f"{repo}/scripts/failover_run_ctl.sh"
        remote = f"cd {repo} && BENCHMARK_CONF={shlex.quote(self.config.remote_conf_path)} {ctl} {action}"
        if args:
            remote += " " + " ".join(shlex.quote(arg) for arg in args)
        return self.run(remote, check=False)

    def prepare_ctl(self, action: str, *args: str) -> subprocess.CompletedProcess[str]:
        repo = shlex.quote(self.config.remote_repo)
        ctl = f"{repo}/scripts/prepare_run_ctl.sh"
        remote = f"cd {repo} && {ctl} {action}"
        if args:
            remote += " " + " ".join(shlex.quote(arg) for arg in args)
        return self.run(remote, check=False)

    def parse_ctl_status(self, stdout: str) -> dict[str, str]:
        data: dict[str, str] = {}
        for line in stdout.splitlines():
            if "=" in line:
                key, value = line.split("=", 1)
                data[key.strip()] = value.strip()
        return data

    def scp_download(self, remote_path: str, local_path: Path) -> None:
        local_path.parent.mkdir(parents=True, exist_ok=True)
        target = f"{self.config.user}@{self.config.host}:{remote_path}"
        cmd = self._base_scp() + [target, str(local_path)]
        subprocess.run(cmd, capture_output=True, text=True, check=True)
