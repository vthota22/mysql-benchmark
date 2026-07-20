const form = document.getElementById("config-form");
const runSummary = document.getElementById("run-summary");
const runLog = document.getElementById("run-log");
const actionMessage = document.getElementById("action-message");
const connectionStatus = document.getElementById("connection-status");
const remoteConfPath = document.getElementById("remote-conf-path");
const btnSave = document.getElementById("btn-save");
const btnStart = document.getElementById("btn-start");
const btnRefresh = document.getElementById("btn-refresh");
const currentReportLinks = document.getElementById("current-report-links");

const runsList = document.getElementById("runs-list");
const runsFilterNote = document.getElementById("runs-filter-note");
const btnRefreshRuns = document.getElementById("btn-refresh-runs");

const compareContent = document.getElementById("compare-content");
const compareFilterNote = document.getElementById("compare-filter-note");
const compareLimitNote = document.getElementById("compare-limit-note");
const btnRefreshCompare = document.getElementById("btn-refresh-compare");

const globalDropletPicker = document.getElementById("global-droplet-picker");
const globalDropletWrap = document.getElementById("global-droplet-wrap");
const globalFeaturePicker = document.getElementById("global-feature-picker");
const reportsIntro = document.getElementById("reports-intro");
const reportsBrowseNote = document.getElementById("reports-browse-note");

let schemaFields = [];
let runPollTimer = null;
let reportsPollTimer = null;
let reportsLoaded = false;
let compareLoaded = false;

function updateReportsCopy(data = {}) {
  const label = data.feature_label || FeatureContext.label || "Failover";
  if (reportsIntro) {
    reportsIntro.textContent =
      `${label} runs on the active droplet. Reports are fetched over SSH and cached locally when opened.`;
  }
  if (reportsBrowseNote) {
    if (data.browse_only || !FeatureContext.capability("can_start")) {
      reportsBrowseNote.textContent =
        "Browse-only for now: start/config stay under Failover until backup/scaling ctl wrappers are wired.";
      reportsBrowseNote.classList.remove("hidden");
    } else {
      reportsBrowseNote.textContent = "";
      reportsBrowseNote.classList.add("hidden");
    }
  }
}

function showMessage(text, kind = "ok") {
  actionMessage.hidden = false;
  actionMessage.textContent = text;
  actionMessage.className = `message ${kind}`;
}

function activeHost() {
  return DropletContext.host || "";
}

function openTab(tabId) {
  if (typeof window.activateFailoverTab === "function") {
    window.activateFailoverTab(tabId);
  }
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
      if (field.type === "password") {
        input.type = "password";
        input.autocomplete = "current-password";
      } else {
        input.type = field.type === "number" ? "number" : "text";
      }
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

function bindReportPanelActions(root) {
  root.querySelectorAll("[data-open-tab]").forEach((el) => {
    el.addEventListener("click", () => openTab(el.dataset.openTab));
  });
  const btn = root.querySelector(".btn-generate");
  btn?.addEventListener("click", async () => {
    btn.disabled = true;
    btn.textContent = "Generating…";
    try {
      await generateRunReport(btn.dataset.resultsDir, btn, activeHost());
      await refreshStatus();
    } catch (err) {
      showMessage(err.message, "err");
      btn.disabled = false;
      btn.textContent = "Generate report";
    }
  });
}

function renderCurrentReports(status) {
  const reports = status.reports || [];
  const primary = status.primary_report || (status.report_url ? { view_url: status.report_url, label: "Combined report" } : null);
  const reportsTab = `<button type="button" class="link-button" data-open-tab="reports">Benchmark run reports</button>`;
  const pending = status.running && !primary?.view_url;

  if (!reports.length && !primary && !pending) {
    currentReportLinks.hidden = false;
    if (status.completed && status.results_dir) {
      currentReportLinks.innerHTML =
        `<strong>Reports:</strong> ` +
        `<span class="muted">No HTML on droplet (graph generation was off).</span> ` +
        `<button type="button" class="btn-generate inline" data-results-dir="${status.results_dir}">Generate report</button>` +
        ` · ${reportsTab}`;
      bindReportPanelActions(currentReportLinks);
      return;
    }
    currentReportLinks.innerHTML = `<strong>Reports:</strong> ${reportsTab}`;
    bindReportPanelActions(currentReportLinks);
    return;
  }

  currentReportLinks.hidden = false;
  const parts = [];

  if (primary?.view_url) {
    parts.push(reportLinkHtml(primary, primary.label || "View report"));
  }

  for (const report of reports) {
    if (primary && report.path === primary.path) continue;
    parts.push(reportLinkHtml(report));
  }

  currentReportLinks.innerHTML =
    `<strong>Reports:</strong> ` +
    (parts.length ? parts.join(" · ") : "") +
    (pending ? `${parts.length ? " · " : ""}<span class="muted">Report available when the run finishes</span>` : "") +
    ` · ${reportsTab}`;
  bindReportPanelActions(currentReportLinks);
}

function renderRunStatus(status, config) {
  const running = !!status.running;
  const badge = running
    ? '<span class="badge running">Running</span>'
    : '<span class="badge idle">Idle</span>';

  const dropletLabel = status.droplet_name || DropletContext.name || "";
  const est = config?.estimated_runtime_sec ?? status.estimated_runtime_sec;
  const lines = [
    badge,
    dropletLabel ? `<span class="muted">Droplet: ${dropletLabel}</span>` : "",
    running && status.pid ? `PID ${status.pid}` : "",
    status.started_utc ? `Started ${status.started_utc}` : "",
    status.results_dir ? `Results: ${status.results_dir}` : "",
    est != null ? `Estimated runtime: ~${formatDuration(est)}` : "",
  ].filter(Boolean);

  runSummary.innerHTML = lines.map((line) => `<div>${line}</div>`).join("");
  renderCurrentReports(status);
  btnStart.disabled = running;
}

async function loadRunConfig() {
  const config = await api(DropletContext.withHost("/api/config/failover"));
  remoteConfPath.textContent = config.remote_conf || "benchmark.conf";
  renderForm(schemaFields, config.values || {});
  return config;
}

async function refreshStatus() {
  const [status, config] = await Promise.all([
    api(DropletContext.withHost("/api/run/status")),
    api(DropletContext.withHost("/api/config/failover")).catch(() => ({})),
  ]);
  renderRunStatus(status, config);

  try {
    const logData = await api(DropletContext.withHost("/api/run/log?lines=120"));
    runLog.textContent = logData.log || "(empty log)";
    runLog.scrollTop = runLog.scrollHeight;
  } catch {
    if (!status.running) {
      runLog.textContent = "No active run log.";
    }
  }

  if (status.running && !runPollTimer) {
    runPollTimer = setInterval(() => refreshStatus().catch(() => {}), 5000);
  }
  if (!status.running && runPollTimer) {
    clearInterval(runPollTimer);
    runPollTimer = null;
  }

  if (status.running || status.completed) {
    reportsLoaded = false;
    compareLoaded = false;
  }
}

async function refreshReports() {
  runsList.textContent = "Loading…";
  runsList.className = "runs-list muted";
  const data = await api(DropletContext.withHost("/api/reports?limit=50"));
  updateReportsCopy(data);
  updateFilterNote(runsFilterNote, data.runs_min_id, "Showing runs from");
  renderRunsList(runsList, data, {
    onGenerate: async (resultsDir, button) => {
      try {
        await generateRunReport(resultsDir, button, activeHost());
        await refreshReports();
        compareLoaded = false;
      } catch (err) {
        alert(err.message);
      }
    },
  });
  reportsLoaded = true;

  const running = (data.runs || []).some((run) => run.running);
  if (running && !reportsPollTimer) {
    reportsPollTimer = setInterval(() => refreshReports().catch(() => {}), 10000);
  }
  if (!running && reportsPollTimer) {
    clearInterval(reportsPollTimer);
    reportsPollTimer = null;
  }
}

function updateCompareLimitNote() {
  if (!compareLimitNote) return;
  const limit = DropletContext.compareRunsLimit || 6;
  const droplet = DropletContext.name || DropletContext.host || "active droplet";
  compareLimitNote.textContent =
    `Last ${limit} runs on ${droplet} — failure detection and time to promote (election) from failover_kpi.csv.`;
}

async function refreshCompare() {
  updateCompareLimitNote();
  compareContent.textContent = "Loading…";
  compareContent.className = "compare-content muted";
  const limit = DropletContext.compareRunsLimit || 6;
  const data = await api(DropletContext.withHost(`/api/runs/compare?limit=${limit}`));
  updateFilterNote(compareFilterNote, data.runs_min_id, "Comparing runs from");
  renderCompareTable(compareContent, data);
  compareLoaded = true;
}

async function reloadActiveDropletData() {
  if (reportsPollTimer) {
    clearInterval(reportsPollTimer);
    reportsPollTimer = null;
  }
  if (runPollTimer) {
    clearInterval(runPollTimer);
    runPollTimer = null;
  }

  reportsLoaded = false;
  compareLoaded = false;
  actionMessage.hidden = true;
  FeatureContext.applyTabVisibility();

  await DropletContext.loadForFeature(FeatureContext.id, {
    persistHost: true,
    notify: false,
  });
  DropletContext.renderPicker(globalDropletPicker, globalDropletWrap);

  if (DropletContext.mapEmpty) {
    connectionStatus.textContent = DropletContext.mapHint || "No droplets for this feature.";
    connectionStatus.style.color = "var(--warn)";
    if (runsList) {
      runsList.textContent = DropletContext.mapHint || "No droplets configured for this feature.";
      runsList.className = "runs-list muted";
    }
    return;
  }

  await loadConnectionStatus(connectionStatus);

  const canStart = FeatureContext.capability("can_start");
  if (canStart) {
    await loadRunConfig();
    await refreshStatus();
  }

  const activeTab = document.querySelector(".tab-panel.active")?.id?.replace("panel-", "") || "run";
  if (!canStart && (activeTab === "run" || activeTab === "prepare" || activeTab === "compare")) {
    openTab("reports");
    await refreshReports();
    return;
  }
  if (activeTab === "reports") {
    await refreshReports();
  } else if (activeTab === "compare" && FeatureContext.capability("can_compare")) {
    await refreshCompare();
  }
}

async function loadInitial() {
  await FeatureContext.init();
  FeatureContext.renderPicker(globalFeaturePicker);
  FeatureContext.applyTabVisibility();

  await DropletContext.init();
  DropletContext.renderPicker(globalDropletPicker, globalDropletWrap);
  updateCompareLimitNote();
  updateReportsCopy();

  if (DropletContext.mapEmpty) {
    connectionStatus.textContent = DropletContext.mapHint || "No droplets for this feature.";
    connectionStatus.style.color = "var(--warn)";
    openTab("reports");
    if (runsList) {
      runsList.textContent = DropletContext.mapHint || "No droplets configured for this feature.";
      runsList.className = "runs-list muted";
    }
    return;
  }

  const schema = await api(DropletContext.withHost("/api/schema"));
  schemaFields = schema.fields;

  await loadConnectionStatus(connectionStatus);

  const canStart = FeatureContext.capability("can_start");
  let initialTab = (window.location.hash || "").replace(/^#/, "") || "reports";
  if (!canStart && (initialTab === "run" || initialTab === "prepare" || initialTab === "compare")) {
    initialTab = "reports";
  }
  openTab(initialTab);

  if (canStart && (initialTab === "run" || initialTab === "prepare")) {
    await loadRunConfig();
    await refreshStatus();
  }
  if (initialTab === "reports") {
    await refreshReports();
  } else if (initialTab === "compare") {
    await refreshCompare();
  }
  if (canStart && initialTab === "reports") {
    // Warm failover config/status in background for when user opens Run.
    loadRunConfig().catch(() => {});
  }
}

btnSave.addEventListener("click", async () => {
  btnSave.disabled = true;
  try {
    const values = collectValues();
    const result = await api("/api/config/failover", {
      method: "POST",
      body: JSON.stringify(DropletContext.withHostBody({ values })),
    });
    showMessage(`Saved to ${DropletContext.name || "droplet"}. Estimated runtime ~${formatDuration(result.estimated_runtime_sec)}.`, "ok");
  } catch (err) {
    showMessage(err.message, "err");
  } finally {
    btnSave.disabled = false;
  }
});

btnStart.addEventListener("click", async () => {
  const values = collectValues();
  const droplet = DropletContext.name || DropletContext.host || "the droplet";
  const est = document.querySelector("#run-summary")?.textContent || "";
  const ok = window.confirm(
    `Start failover benchmark on ${droplet}?\n\n` +
      "Current form values will be saved to benchmark.conf first.\n\n" +
      est
  );
  if (!ok) return;

  btnStart.disabled = true;
  try {
    await api("/api/config/failover", {
      method: "POST",
      body: JSON.stringify(DropletContext.withHostBody({ values })),
    });
    const result = await api("/api/run/start", {
      method: "POST",
      body: JSON.stringify(DropletContext.withHostBody({})),
    });
    if (!result.ok) {
      throw new Error(result.error || "Start failed");
    }
    showMessage(result.message || `Benchmark started on ${droplet}.`, "ok");
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

btnRefreshRuns?.addEventListener("click", () => {
  refreshReports().catch((err) => {
    runsList.textContent = err.message;
    runsList.className = "runs-list muted";
  });
});

btnRefreshCompare?.addEventListener("click", () => {
  refreshCompare().catch((err) => {
    compareContent.textContent = err.message;
    compareContent.className = "compare-content muted";
  });
});

globalDropletPicker?.addEventListener("change", () => {
  DropletContext.setHost(globalDropletPicker.value || "");
});

globalFeaturePicker?.addEventListener("change", () => {
  FeatureContext.setFeature(globalFeaturePicker.value || "failover");
});

window.addEventListener("failover-droplet", () => {
  reloadActiveDropletData().catch((err) => {
    connectionStatus.textContent = err.message;
    connectionStatus.style.color = "var(--err)";
  });
});

window.addEventListener("benchmark-feature", () => {
  reloadActiveDropletData().catch((err) => {
    connectionStatus.textContent = err.message;
    connectionStatus.style.color = "var(--err)";
  });
});

window.addEventListener("failover-tab", (event) => {
  const tab = event.detail?.tab;
  if (tab === "reports" && !reportsLoaded) {
    refreshReports().catch((err) => {
      runsList.textContent = err.message;
      runsList.className = "runs-list muted";
    });
  }
  if (tab === "compare" && !compareLoaded && FeatureContext.capability("can_compare")) {
    refreshCompare().catch((err) => {
      compareContent.textContent = err.message;
      compareContent.className = "compare-content muted";
    });
  }
});

loadInitial().catch((err) => {
  connectionStatus.textContent = err.message;
  connectionStatus.style.color = "var(--err)";
});
