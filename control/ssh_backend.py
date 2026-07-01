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

    @property
    def remote_conf_path(self) -> str:
        repo = self.remote_repo.rstrip("/")
        conf = self.remote_conf.lstrip("/")
        return f"{repo}/{conf}"


def load_droplet_config(path: Path) -> DropletConfig:
    values: dict[str, str] = {}
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip().strip('"').strip("'")

    missing = [key for key in ("DROPLET_HOST", "DROPLET_USER", "REMOTE_REPO") if key not in values]
    if missing:
        raise ValueError(f"Missing required keys in {path}: {', '.join(missing)}")

    ssh_key = values.get("DROPLET_SSH_KEY", "")
    if ssh_key.startswith("~"):
        ssh_key = os.path.expanduser(ssh_key)

    return DropletConfig(
        host=values["DROPLET_HOST"],
        user=values["DROPLET_USER"],
        remote_repo=values["REMOTE_REPO"],
        remote_conf=values.get("REMOTE_BENCHMARK_CONF", "benchmark.conf"),
        ssh_key=ssh_key,
        ssh_port=int(values.get("DROPLET_SSH_PORT", "22") or "22"),
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

    def test_connection(self) -> tuple[bool, str]:
        try:
            result = self.run(f"test -d {shlex.quote(self.config.remote_repo)} && echo OK")
        except subprocess.CalledProcessError as exc:
            detail = (exc.stderr or exc.stdout or str(exc)).strip()
            return False, detail or "SSH connection failed"
        if "OK" in result.stdout:
            return True, f"Connected to {self.config.user}@{self.config.host}:{self.config.remote_repo}"
        return False, result.stderr.strip() or "Unexpected SSH response"

    def ctl(self, action: str, *args: str) -> subprocess.CompletedProcess[str]:
        repo = shlex.quote(self.config.remote_repo)
        ctl = f"{repo}/scripts/failover_run_ctl.sh"
        remote = f"cd {repo} && BENCHMARK_CONF={shlex.quote(self.config.remote_conf_path)} {ctl} {action}"
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
