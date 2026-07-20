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
const ACTIVE_FEATURE_KEY = "benchmark_active_feature_v1";

const FeatureContext = {
  id: "failover",
  label: "Failover",
  features: [],
  current: null,
  initialized: false,

  find(id) {
    return (this.features || []).find((f) => f.id === id) || null;
  },

  async init() {
    if (this.initialized) return this;
    const data = await api("/api/features");
    this.features = (data.features || []).filter((f) => f.enabled);
    const saved = localStorage.getItem(ACTIVE_FEATURE_KEY) || "";
    const initial = this.find(saved) ? saved : (data.active || "failover");
    this.setFeature(initial, { persist: false, notify: false });
    this.initialized = true;
    return this;
  },

  setFeature(id, { persist = true, notify = true } = {}) {
    const next = this.find(id) || this.find("failover") || this.features[0];
    if (!next) return;
    this.current = next;
    this.id = next.id;
    this.label = next.label;
    if (persist) {
      localStorage.setItem(ACTIVE_FEATURE_KEY, this.id);
    }
    if (notify) {
      window.dispatchEvent(
        new CustomEvent("benchmark-feature", {
          detail: { id: this.id, label: this.label, feature: next },
        })
      );
    }
  },

  capability(name) {
    return !!(this.current && this.current[name]);
  },

  withFeature(path) {
    if (!this.id || this.id === "failover") {
      return path;
    }
    const sep = path.includes("?") ? "&" : "?";
    return `${path}${sep}feature=${encodeURIComponent(this.id)}`;
  },

  renderPicker(selectEl) {
    if (!selectEl) return;
    selectEl.innerHTML = (this.features || [])
      .map((f) => `<option value="${f.id}">${f.label}</option>`)
      .join("");
    selectEl.value = this.id;
  },

  applyTabVisibility() {
    document.querySelectorAll(".tab-bar .tab[data-requires]").forEach((tab) => {
      const req = tab.dataset.requires;
      const allowed = this.capability(req);
      tab.hidden = !allowed;
      if (!allowed && tab.classList.contains("active")) {
        if (typeof window.activateFailoverTab === "function") {
          window.activateFailoverTab("reports");
        }
      }
    });
    const title = document.getElementById("app-title");
    if (title) {
      title.textContent = `${this.label} benchmark control`;
    }
    document.title = `${this.label} benchmark control`;
  },
};

const DropletContext = {
  host: "",
  name: "",
  droplets: [],
  defaultHost: "",
  compareRunsLimit: 6,
  mapEmpty: false,
  mapHint: "",
  featureId: "failover",
  initialized: false,

  dropletLabel(d) {
    return `${d.name} (${d.host})`;
  },

  findDroplet(host) {
    return (this.droplets || []).find((d) => d.host === host) || null;
  },

  async loadForFeature(featureId, { persistHost = true, notify = false } = {}) {
    const fid = featureId || FeatureContext.id || "failover";
    const path =
      fid === "failover"
        ? "/api/droplets"
        : `/api/droplets?feature=${encodeURIComponent(fid)}`;
    const data = await api(path);
    this.featureId = data.feature || fid;
    this.droplets = data.droplets || [];
    this.defaultHost = data.default_host || (this.droplets[0] && this.droplets[0].host) || "";
    this.compareRunsLimit = data.compare_runs_limit || this.compareRunsLimit || 6;
    this.mapEmpty = !!data.map_empty;
    this.mapHint = data.map_hint || "";

    // Locked Active droplet = first entry in the feature map (ignore saved host).
    this.setHost(this.defaultHost, { persist: persistHost, notify });
    return this;
  },

  async init() {
    if (this.initialized) return this;
    await this.loadForFeature(FeatureContext.id || "failover", {
      persistHost: true,
      notify: false,
    });
    this.initialized = true;
    return this;
  },

  setHost(host, { persist = true, notify = true } = {}) {
    const next = host || this.defaultHost;
    const droplet = this.findDroplet(next) || this.droplets[0] || null;
    this.host = droplet ? droplet.host : this.defaultHost;
    this.name = droplet ? droplet.name : this.host;
    if (persist && this.host) {
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
    const withFeature = FeatureContext.withFeature(path);
    const sep = withFeature.includes("?") ? "&" : "?";
    const query = this.hostQuery(sep);
    return query ? `${withFeature}${query}` : withFeature;
  },

  withHostBody(body = {}) {
    const next = { ...body };
    if (FeatureContext.id && FeatureContext.id !== "failover") {
      next.feature = FeatureContext.id;
    }
    if (!this.host || this.host === this.defaultHost) {
      return next;
    }
    return { ...next, host: this.host };
  },

  renderPicker(selectEl, wrapEl) {
    if (!selectEl) return;
    selectEl.disabled = true;
    if (!(this.droplets || []).length) {
      selectEl.innerHTML = `<option value="">No droplets for this feature</option>`;
      if (wrapEl) wrapEl.hidden = false;
      return;
    }
    // Show only the locked default (first map entry) as a read-only field.
    const active = this.findDroplet(this.defaultHost) || this.droplets[0];
    this.host = active.host;
    this.name = active.name;
    selectEl.innerHTML = `<option value="${active.host}">${this.dropletLabel(active)}</option>`;
    selectEl.value = active.host;
    if (wrapEl) wrapEl.hidden = false;
  },
};

function reportLinkHtml(report, label) {
  const text = label || report.label || "Report";
  const mode = report.failover_mode;
  let badge = "";
  if (mode === "planned") {
    badge = '<span class="badge failover-planned" title="Planned failover (set_as_primary)">Planned</span>';
  } else if (mode === "unplanned") {
    badge = '<span class="badge failover-unplanned" title="Unplanned failover">Unplanned</span>';
  }
  return `<a href="${report.view_url}" target="_blank" rel="noopener">${text}</a>${badge}`;
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

function noReportHtml(run, { canGenerate = true } = {}) {
  if (run.running) {
    return '<p class="run-meta">Run in progress — HTML report will appear when the run finishes (if graph generation is enabled).</p>';
  }
  if (run.completed) {
    if (!canGenerate) {
      return '<p class="run-meta">No HTML report on the droplet yet for this run.</p>';
    }
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
  const featureLabel = data.feature_label || FeatureContext.label || "benchmark";
  const canGenerate = data.can_generate !== false;
  if (!runs.length) {
    const minId = (data.runs_min_id || "").trim();
    container.innerHTML = minId
      ? `No ${featureLabel.toLowerCase()} runs found from ${minId} onward.`
      : `No ${featureLabel.toLowerCase()} runs found on the droplet.`;
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
        : noReportHtml(run, { canGenerate });

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

  if (onGenerate && canGenerate) {
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
      body: JSON.stringify(DropletContext.withHostBody({ results_dir: resultsDir, host })),
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

  if (data.error) {
    container.innerHTML = `<p>${data.error}</p>`;
    container.className = "compare-content muted";
    return;
  }

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
