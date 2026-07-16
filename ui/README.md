# Control UI — DigitalOcean App Platform source directory

## Stack (important)

| Layer | Tech |
|-------|------|
| Browser UI | **HTML + CSS + JS** (`control/static/`) |
| Server | **Python 3** (`control_ui.py` + `control/`) — SSH to droplets, proxy reports |

App Platform must run the **Python process**, not static site hosting alone. Without Python, Previous reports / start-run APIs will not work.

## Local run

```bash
cd ui
cp control.local.conf.example control.local.conf   # or use env vars
# edit DROPLET_MAP / DROPLET_HOST / DROPLET_SSH_KEY
python3 control_ui.py
# open http://127.0.0.1:8765
```

From repo root: `python3 control_ui.py` (wrapper into `ui/`).

## App Platform

1. Create app from this GitHub repo.
2. Set **Source Directory** / Root Directory to **`ui`**.
3. Run command: `python3 control_ui.py --host 0.0.0.0 --port $PORT`  
   (or use `Procfile`).
4. HTTP health check path: **`/api/ping`** (does not SSH).
5. Env / secrets:

| Name | Example | Notes |
|------|---------|--------|
| `BENCHMARK_DROPLET_MAP` | `high2:209.38.88.104,multi:174.138.56.251` | Droplet picker |
| `BENCHMARK_REMOTE_REPO` | `/root/mysql-benchmark` | Path on droplet |
| `BENCHMARK_DROPLET_USER` | `root` | Optional (default root) |
| `BENCHMARK_SSH_PRIVATE_KEY` | (private key PEM) | **Secret** — same key as GHA |
| `RUNS_MIN_ID` | `failover_20260702_020852` | Optional list cutoff |
| `PORT` | set by App Platform | Bound automatically |

Ensure each droplet has the matching **public** key in `authorized_keys`, and the app can reach droplet port 22.

## Verify after deploy

1. Open app URL → droplet picker shows map entries.
2. Select **high2** → Previous reports lists `failover_*` with timestamps.
3. Select **multi** → list refreshes for that host.
4. Open a primary report link → HTML loads.

## Extensibility

`control/features.py` defines failover (enabled) plus backup/scaling stubs (`enabled=False`). Turn them on after harness + ctl scripts exist on droplets — same App Platform app.
