const form = document.getElementById("config-form");
const runSummary = document.getElementById("run-summary");
const runLog = document.getElementById("run-log");
const actionMessage = document.getElementById("action-message");
const connectionStatus = document.getElementById("connection-status");
const remoteConfPath = document.getElementById("remote-conf-path");
const btnSave = document.getElementById("btn-save");
const btnStart = document.getElementById("btn-start");
const btnRefresh = document.getElementById("btn-refresh");

let schemaFields = [];
let pollTimer = null;

async function api(path, options = {}) {
  const res = await fetch(path, {
    headers: { "Content-Type": "application/json", ...(options.headers || {}) },
    ...options,
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok && !data.error) {
    throw new Error(`${res.status} ${res.statusText}`);
  }
  if (data.error) {
    throw new Error(data.error);
  }
  return data;
}

function showMessage(text, kind = "ok") {
  actionMessage.hidden = false;
  actionMessage.textContent = text;
  actionMessage.className = `message ${kind}`;
}

function formatDuration(sec) {
  if (sec == null) return "unknown";
  const m = Math.floor(sec / 60);
  const s = sec % 60;
  if (m >= 60) {
    const h = Math.floor(m / 60);
    const rm = m % 60;
    return `${h}h ${rm}m`;
  }
  return m ? `${m}m ${s}s` : `${s}s`;
}

function renderForm(fields, values) {
  form.innerHTML = "";
  let currentSection = null;

  for (const field of fields) {
    if (field.section !== currentSection) {
      currentSection = field.section;
      const heading = document.createElement("div");
      heading.className = "form-section";
      heading.textContent = currentSection;
      form.appendChild(heading);
    }

    const wrap = document.createElement("div");
    wrap.className = "field";

    const label = document.createElement("label");
    label.setAttribute("for", field.key);
    label.textContent = field.label;

    let input;
    const value = values[field.key] ?? "";

    if (field.type === "checkbox") {
      input = document.createElement("div");
      input.className = "checkbox-row";
      const cb = document.createElement("input");
      cb.type = "checkbox";
      cb.id = field.key;
      cb.name = field.key;
      cb.checked = value === "1";
      cb.addEventListener("change", () => {
        cb.dataset.value = cb.checked ? "1" : "0";
      });
      cb.dataset.value = cb.checked ? "1" : "0";
      input.appendChild(cb);
      input.appendChild(document.createTextNode("Enabled (1)"));
    } else if (field.type === "select") {
      input = document.createElement("select");
      input.id = field.key;
      input.name = field.key;
      for (const opt of field.options) {
        const o = document.createElement("option");
        o.value = opt;
        o.textContent = opt;
        if (opt === value) o.selected = true;
        input.appendChild(o);
      }
    } else {
      input = document.createElement("input");
      input.id = field.key;
      input.name = field.key;
      input.type = field.type === "number" ? "number" : "text";
      input.value = value;
    }

    wrap.appendChild(label);
    wrap.appendChild(input);

    if (field.help) {
      const help = document.createElement("div");
      help.className = "help";
      help.textContent = field.help;
      wrap.appendChild(help);
    }

    form.appendChild(wrap);
  }
}

function collectValues() {
  const values = {};
  for (const field of schemaFields) {
    const el = document.getElementById(field.key);
    if (!el) continue;
    if (field.type === "checkbox") {
      values[field.key] = el.checked ? "1" : "0";
    } else {
      values[field.key] = el.value.trim();
    }
  }
  return values;
}

function renderRunStatus(status, config) {
  const running = !!status.running;
  const badge = running
    ? '<span class="badge running">Running</span>'
    : '<span class="badge idle">Idle</span>';

  const est = config?.estimated_runtime_sec ?? status.estimated_runtime_sec;
  const lines = [
    badge,
    running && status.pid ? `PID ${status.pid}` : "",
    status.started_utc ? `Started ${status.started_utc}` : "",
    status.results_dir ? `Results: ${status.results_dir}` : "",
    est != null ? `Estimated runtime: ~${formatDuration(est)}` : "",
  ].filter(Boolean);

  runSummary.innerHTML = lines.map((line) => `<div>${line}</div>`).join("");
  btnStart.disabled = running;
}

async function refreshStatus() {
  const [status, config] = await Promise.all([
    api("/api/run/status"),
    api("/api/config/failover").catch(() => ({})),
  ]);
  renderRunStatus(status, config);

  try {
    const logData = await api("/api/run/log?lines=120");
    runLog.textContent = logData.log || "(empty log)";
    runLog.scrollTop = runLog.scrollHeight;
  } catch {
    if (!status.running) {
      runLog.textContent = "No active run log.";
    }
  }

  if (status.running && !pollTimer) {
    pollTimer = setInterval(refreshStatus, 5000);
  }
  if (!status.running && pollTimer) {
    clearInterval(pollTimer);
    pollTimer = null;
  }
}

async function loadInitial() {
  const health = await api("/api/health");
  connectionStatus.textContent = health.message;
  connectionStatus.style.color = health.ok ? "var(--ok)" : "var(--err)";

  const schema = await api("/api/schema");
  schemaFields = schema.fields;

  const config = await api("/api/config/failover");
  remoteConfPath.textContent = config.remote_conf || "benchmark.conf";
  renderForm(schemaFields, config.values || {});
  await refreshStatus();
}

btnSave.addEventListener("click", async () => {
  btnSave.disabled = true;
  try {
    const values = collectValues();
    const result = await api("/api/config/failover", {
      method: "POST",
      body: JSON.stringify({ values }),
    });
    showMessage(`Saved to droplet. Estimated runtime ~${formatDuration(result.estimated_runtime_sec)}.`, "ok");
  } catch (err) {
    showMessage(err.message, "err");
  } finally {
    btnSave.disabled = false;
  }
});

btnStart.addEventListener("click", async () => {
  const values = collectValues();
  const est = document.querySelector("#run-summary")?.textContent || "";
  const ok = window.confirm(
    "Start failover benchmark on the droplet?\n\n" +
      "Current form values will be saved to benchmark.conf first.\n\n" +
      est
  );
  if (!ok) return;

  btnStart.disabled = true;
  try {
    await api("/api/config/failover", {
      method: "POST",
      body: JSON.stringify({ values }),
    });
    const result = await api("/api/run/start", { method: "POST" });
    if (!result.ok) {
      throw new Error(result.error || "Start failed");
    }
    showMessage(result.message || "Benchmark started on droplet.", "ok");
    await refreshStatus();
  } catch (err) {
    showMessage(err.message, "err");
  } finally {
    btnStart.disabled = false;
  }
});

btnRefresh.addEventListener("click", () => {
  refreshStatus().catch((err) => showMessage(err.message, "err"));
});

loadInitial().catch((err) => {
  connectionStatus.textContent = err.message;
  connectionStatus.style.color = "var(--err)";
});
