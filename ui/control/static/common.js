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

const ACTIVE_DROPLET_KEY = "failover_active_droplet_v1";

const DropletContext = {
  host: "",
  name: "",
  droplets: [],
  defaultHost: "",
  compareRunsLimit: 6,
  initialized: false,

  dropletLabel(d) {
    return `${d.name} (${d.host})`;
  },

  findDroplet(host) {
    return (this.droplets || []).find((d) => d.host === host) || null;
  },

  async init() {
    if (this.initialized) return this;
    const data = await api("/api/droplets");
    this.droplets = data.droplets || [];
    this.defaultHost = data.default_host || (this.droplets[0] && this.droplets[0].host) || "";
    this.compareRunsLimit = data.compare_runs_limit || 6;

    const saved = localStorage.getItem(ACTIVE_DROPLET_KEY) || "";
    const initial = this.findDroplet(saved) ? saved : this.defaultHost;
    this.setHost(initial, { persist: false, notify: false });
    this.initialized = true;
    return this;
  },

  setHost(host, { persist = true, notify = true } = {}) {
    const next = host || this.defaultHost;
    const droplet = this.findDroplet(next);
    this.host = droplet ? droplet.host : this.defaultHost;
    this.name = droplet ? droplet.name : this.host;
    if (persist) {
      localStorage.setItem(ACTIVE_DROPLET_KEY, this.host);
    }
    if (notify) {
      window.dispatchEvent(
        new CustomEvent("failover-droplet", {
          detail: { host: this.host, name: this.name },
        })
      );
    }
  },

  hostQuery(prefix = "") {
    if (!this.host || this.host === this.defaultHost) {
      return "";
    }
    const lead = prefix || (this.host.includes("?") ? "&" : "?");
    return `${lead}host=${encodeURIComponent(this.host)}`;
  },

  withHost(path) {
    const sep = path.includes("?") ? "&" : "?";
    const query = this.hostQuery(sep);
    return query ? `${path}${query}` : path;
  },

  withHostBody(body = {}) {
    if (!this.host || this.host === this.defaultHost) {
      return body;
    }
    return { ...body, host: this.host };
  },

  renderPicker(selectEl, wrapEl) {
    if (!selectEl) return;
    selectEl.innerHTML = (this.droplets || [])
      .map((d) => `<option value="${d.host}">${this.dropletLabel(d)}</option>`)
      .join("");
    if (this.findDroplet(this.host)) {
      selectEl.value = this.host;
    } else {
      this.setHost(this.defaultHost, { notify: false });
      selectEl.value = this.host;
    }
    if (wrapEl) {
      wrapEl.hidden = (this.droplets || []).length <= 1;
    }
  },
};

function reportLinkHtml(report, label) {
  const text = label || report.label || "Report";
  return `<a href="${report.view_url}" target="_blank" rel="noopener">${text}</a>`;
}

function runBadgesHtml(run) {
  const badges = [];
  if (run.running) {
    badges.push('<span class="badge running">Running</span>');
  } else if (run.completed) {
    badges.push('<span class="badge completed">Completed</span>');
  }
  if (run.is_latest && !run.running) {
    badges.push('<span class="badge latest-run">Latest</span>');
  }
  return badges.join("");
}

function noReportHtml(run) {
  if (run.running) {
    return '<p class="run-meta">Run in progress — HTML report will appear when the run finishes (if graph generation is enabled).</p>';
  }
  if (run.completed) {
    return (
      '<p class="run-meta">No HTML report on the droplet yet. ' +
      'This usually means <code>FAILOVER_GENERATE_GRAPHS=0</code> during the run.</p>' +
      `<button type="button" class="btn-generate" data-results-dir="${run.results_dir}">Generate HTML report</button>`
    );
  }
  return '<p class="run-meta">No HTML report yet.</p>';
}

function renderRunsList(container, data, { onGenerate } = {}) {
  const runs = data.runs || [];
  if (!runs.length) {
    const minId = (data.runs_min_id || "").trim();
    container.innerHTML = minId
      ? `No failover runs found from ${minId} onward.`
      : "No failover runs found on the droplet.";
    container.className = "runs-list muted";
    return;
  }

  container.className = "runs-list";
  container.innerHTML = runs
    .map((run) => {
      const reportItems = (run.reports || [])
        .map((report) => `<li>${reportLinkHtml(report)}</li>`)
        .join("");

      const reportsBlock = reportItems
        ? `<ul>${reportItems}</ul>`
        : noReportHtml(run);

      const primary = run.primary_report;
      const primaryLink = primary
        ? `<p class="run-primary">${reportLinkHtml(primary, "Open primary report")}</p>`
        : "";

      return (
        `<article class="run-block">` +
        `<div class="run-title">${run.run_id}${runBadgesHtml(run)}</div>` +
        `<div class="run-meta">${run.started_display || run.started_at || "Timestamp unknown"}` +
          (run.results_dir ? ` · ${run.results_dir}` : "") +
        `</div>` +
        primaryLink +
        reportsBlock +
        `</article>`
      );
    })
    .join("");

  if (onGenerate) {
    container.querySelectorAll(".btn-generate").forEach((button) => {
      button.addEventListener("click", () => onGenerate(button.dataset.resultsDir, button));
    });
  }
}

async function generateRunReport(resultsDir, button, host = "") {
  if (button) {
    button.disabled = true;
    button.textContent = "Generating…";
  }
  try {
    return await api("/api/runs/generate-report", {
      method: "POST",
      body: JSON.stringify({ results_dir: resultsDir, host }),
    });
  } finally {
    if (button) {
      button.disabled = false;
      button.textContent = "Generate HTML report";
    }
  }
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

function updateFilterNote(el, minId, prefix) {
  if (!el) return;
  if (!minId) {
    el.textContent = "";
    el.classList.add("hidden");
    return;
  }
  el.textContent = `${prefix} ${minId} and newer only.`;
  el.classList.remove("hidden");
}

function renderCompareTable(container, data) {
  const runs = data.runs || [];
  const slices = data.slices || [];

  if (!runs.length) {
    const minId = (data.runs_min_id || "").trim();
    container.innerHTML = minId
      ? `No runs found from ${minId} onward.`
      : "No failover runs found on the droplet.";
    container.className = "compare-content muted";
    return;
  }

  if (!slices.length) {
    container.innerHTML =
      "<p>No KPI data yet. Runs need to finish and produce " +
      "<code>failover_kpi.csv</code> at the run root (generated after each scenario).</p>";
    container.className = "compare-content muted";
    return;
  }

  container.className = "compare-content";
  container.innerHTML = slices
    .map((slice) => {
      const headerCells = runs
        .map((run) => {
          const report = run.primary_report;
          const title = report?.view_url
            ? `<a href="${report.view_url}" target="_blank" rel="noopener">${run.run_id}</a>`
            : run.run_id;
          const status = run.running
            ? ' <span class="badge running">Running</span>'
            : run.has_kpi
              ? ""
              : ' <span class="badge idle">No KPI</span>';
          return `<th scope="col">${title}${status}</th>`;
        })
        .join("");

      const bodyRows = (slice.rows || [])
        .map((row) => {
          const cells = runs
            .map((run) => `<td>${row.values?.[run.run_id] ?? "—"}</td>`)
            .join("");
          return `<tr><th scope="row">${row.label}</th>${cells}</tr>`;
        })
        .join("");

      return (
        `<div class="compare-slice">` +
        `<h3>${slice.label}</h3>` +
        `<div class="compare-table-wrap">` +
        `<table class="compare-table">` +
        `<thead><tr><th scope="col">Metric</th>${headerCells}</tr></thead>` +
        `<tbody>${bodyRows}</tbody>` +
        `</table></div></div>`
      );
    })
    .join("");
}

async function loadConnectionStatus(el) {
  try {
    const health = await api(DropletContext.withHost("/api/health"));
    const label = health.droplet_name ? `${health.droplet_name}: ` : "";
    el.textContent = `${label}${health.message}`;
    el.style.color = health.ok ? "var(--ok)" : "var(--err)";
  } catch (err) {
    el.textContent = err.message;
    el.style.color = "var(--err)";
  }
}
