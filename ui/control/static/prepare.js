const prepareForm = document.getElementById("prepare-form");
const prepareSummary = document.getElementById("prepare-summary");
const prepareLog = document.getElementById("prepare-log");
const prepareMessage = document.getElementById("prepare-message");
const prepareEstimate = document.getElementById("prepare-estimate");
const prepareProfilePicker = document.getElementById("prepare-profile-picker");
const prepareWatchPicker = document.getElementById("prepare-watch-picker");
const prepareWatchNote = document.getElementById("prepare-watch-note");
const prepareDropletCards = document.getElementById("prepare-droplet-cards");
const btnPrepareStart = document.getElementById("btn-prepare-start");
const btnPrepareRefresh = document.getElementById("btn-prepare-refresh");
const btnPrepareWatch = document.getElementById("btn-prepare-watch");
const btnPrepareRefreshAll = document.getElementById("btn-prepare-refresh-all");
const btnPrepareTest = document.getElementById("btn-prepare-test");

const PREPARE_LAST_KEY = "failover_prepare_last_v2";
const PREPARE_HISTORY_KEY = "failover_prepare_history_v2";
const PREPARE_JOBS_KEY = "failover_prepare_jobs_v1";
const PREPARE_HISTORY_MAX = 20;

const PREPARE_SUGGEST_KEYS = new Set([
  "DROPLET_NAME",
  "DROPLET_HOST",
  "DROPLET_USER",
  "REMOTE_REPO",
  "MYSQL_HOST",
]);

let prepareSchemaFields = [];
let preparePollTimer = null;
let prepareLoaded = false;
let watchedDropletHost = "";
let dropletStatusCache = {};
let prepareEstimateCache = {
  estimated_prepare_sec: null,
  data_size_label: "",
  data_size_gb: null,
};
let saveFormTimer = null;

function showPrepareMessage(text, kind = "ok") {
  prepareMessage.hidden = false;
  prepareMessage.textContent = text;
  prepareMessage.className = `message ${kind}`;
}

function dropletKey(values) {
  return (values?.DROPLET_HOST || "").trim();
}

function dropletDisplayName(values) {
  return values?.DROPLET_NAME || values?.DROPLET_HOST || "droplet";
}

function nameForDropletHost(host) {
  const h = (host || "").trim();
  if (!h) return "";
  const job = loadPrepareJobs().find((j) => j.dropletHost === h);
  if (job?.dropletName) return job.dropletName;
  const configured = DropletContext.findDroplet(h);
  if (configured?.name) return configured.name;
  return h;
}

function applyConfiguredDroplet(host) {
  const configured = DropletContext.findDroplet(host);
  if (!configured) return;
  const nameEl = document.getElementById("prepare-DROPLET_NAME");
  const hostEl = document.getElementById("prepare-DROPLET_HOST");
  if (nameEl) nameEl.value = configured.name;
  if (hostEl) hostEl.value = configured.host;
  savePrepareLast(collectPrepareValues());
  renderWatchPicker();
  renderDropletCards();
}

function estimatePrepareLocal(values) {
  let tables = parseInt(values.TPCC_TABLES || "10", 10);
  let scale = parseInt(values.TPCC_SCALE || "100", 10);
  if (!Number.isFinite(tables) || tables < 1) tables = 10;
  if (!Number.isFinite(scale) || scale < 1) scale = 100;

  const gb = tables * scale * 0.1;
  const minutes = Math.max(5, Math.min(120, Math.round(5 + gb * 0.75)));
  const gbLabel = gb === Math.floor(gb) ? `~${gb} GB` : `~${gb.toFixed(1)} GB`;

  return {
    estimated_prepare_sec: minutes * 60,
    data_size_label: `${gbLabel} (tables=${tables}, scale=${scale})`,
    data_size_gb: Math.round(gb * 100) / 100,
  };
}

function updatePrepareEstimateDisplay(values) {
  const est = estimatePrepareLocal(values);
  prepareEstimateCache = est;
  prepareEstimate.textContent =
    `Dataset: ${est.data_size_label} · Estimated prepare: ~${formatDuration(est.estimated_prepare_sec)}`;
  prepareEstimate.className = "prepare-estimate";
  renderPrepareStatusLast();
}

function profileLabel(values) {
  const droplet = dropletDisplayName(values);
  const mysql = values.MYSQL_HOST || "database";
  const tables = values.TPCC_TABLES || "?";
  const scale = values.TPCC_SCALE || "?";
  return `${droplet} · ${mysql} · ${tables}/${scale}`;
}

function loadPrepareHistory() {
  try {
    const raw = localStorage.getItem(PREPARE_HISTORY_KEY);
    const list = raw ? JSON.parse(raw) : [];
    return Array.isArray(list) ? list : [];
  } catch {
    return [];
  }
}

function savePrepareHistory(list) {
  try {
    localStorage.setItem(PREPARE_HISTORY_KEY, JSON.stringify(list.slice(0, PREPARE_HISTORY_MAX)));
  } catch {
    /* ignore */
  }
}

function loadPrepareJobs() {
  try {
    const raw = localStorage.getItem(PREPARE_JOBS_KEY);
    const list = raw ? JSON.parse(raw) : [];
    return Array.isArray(list) ? list : [];
  } catch {
    return [];
  }
}

function savePrepareJobs(list) {
  try {
    localStorage.setItem(PREPARE_JOBS_KEY, JSON.stringify(list.slice(0, PREPARE_HISTORY_MAX)));
  } catch {
    /* ignore */
  }
}

function upsertPrepareJob(values, status = {}) {
  const host = dropletKey(values);
  if (!host) return;
  const jobs = loadPrepareJobs().filter((j) => j.dropletHost !== host);
  jobs.unshift({
    dropletHost: host,
    dropletName: dropletDisplayName(values),
    mysqlHost: values.MYSQL_HOST || "",
    label: profileLabel(values),
    updatedAt: new Date().toISOString(),
    values: { ...values },
    lastResultsDir: status.results_dir || "",
    lastRunning: !!status.running,
    lastSuccess: !!status.success,
    lastFailed: !!status.failed,
  });
  savePrepareJobs(jobs);
  renderWatchPicker(jobs);
}

function valuesForDropletHost(host) {
  if (!host) return collectPrepareValues();
  const job = loadPrepareJobs().find((j) => j.dropletHost === host);
  if (job?.values) return { ...job.values };
  const hist = loadPrepareHistory().find((h) => h.values?.DROPLET_HOST === host);
  if (hist?.values) return { ...hist.values };
  const form = collectPrepareValues();
  if (form.DROPLET_HOST === host) return form;
  const configured = DropletContext.findDroplet(host);
  if (configured) {
    return {
      ...form,
      DROPLET_NAME: configured.name,
      DROPLET_HOST: configured.host,
    };
  }
  return { ...form, DROPLET_HOST: host };
}

function uniqueDropletHosts() {
  const seen = new Set();
  const out = [];
  const add = (host) => {
    const h = (host || "").trim();
    if (!h || seen.has(h)) return;
    seen.add(h);
    out.push(h);
  };
  for (const droplet of DropletContext.droplets || []) {
    add(droplet.host);
  }
  for (const job of loadPrepareJobs()) {
    add(job.dropletHost);
  }
  for (const item of loadPrepareHistory()) {
    add(item.values?.DROPLET_HOST);
  }
  add(collectPrepareValues().DROPLET_HOST);
  return out;
}

function renderWatchPicker(jobs = loadPrepareJobs()) {
  if (!prepareWatchPicker) return;
  const current = prepareWatchPicker.value || watchedDropletHost;
  const hosts = uniqueDropletHosts();
  prepareWatchPicker.innerHTML =
    '<option value="">— Current form droplet —</option>' +
    hosts
      .map((host) => {
        const name = nameForDropletHost(host);
        const st = dropletStatusCache[host];
        let suffix = "";
        if (st?.running) suffix = " · running";
        else if (st?.success) suffix = " · done";
        else if (st?.failed) suffix = " · failed";
        return `<option value="${host}">${name} (${host})${suffix}</option>`;
      })
      .join("");
  if (current && hosts.includes(current)) {
    prepareWatchPicker.value = current;
    watchedDropletHost = current;
  }
}

function updateWatchNote(values) {
  if (!prepareWatchNote) return;
  const formHost = collectPrepareValues().DROPLET_HOST;
  const watchHost = watchedDropletHost || formHost;
  if (watchedDropletHost && watchedDropletHost !== formHost) {
    prepareWatchNote.hidden = false;
    prepareWatchNote.textContent =
      `Watching ${dropletDisplayName(values)} (${watchedDropletHost}) — form shows a different droplet.`;
  } else {
    prepareWatchNote.hidden = true;
    prepareWatchNote.textContent = "";
  }
}

function statusBadgeHtml(status) {
  if (status?.running) return '<span class="badge running">Loading data…</span>';
  if (status?.success) return '<span class="badge completed">Done</span>';
  if (status?.failed) return '<span class="badge failed">Failed</span>';
  return '<span class="badge idle">Idle</span>';
}

function renderDropletCards() {
  if (!prepareDropletCards) return;
  const hosts = uniqueDropletHosts();
  if (!hosts.length) {
    prepareDropletCards.className = "prepare-droplet-cards muted";
    prepareDropletCards.textContent =
      "Configured droplets appear here. Start a load to track progress — each droplet runs independently.";
    return;
  }

  prepareDropletCards.className = "prepare-droplet-cards";
  prepareDropletCards.innerHTML = hosts
    .map((host) => {
      const job = loadPrepareJobs().find((j) => j.dropletHost === host);
      const values = valuesForDropletHost(host);
      const st = dropletStatusCache[host] || {};
      const watchHost = watchedDropletHost || collectPrepareValues().DROPLET_HOST;
      const active = host === watchHost ? " active-watch" : "";
      const meta = [
        job?.mysqlHost || values.MYSQL_HOST || "",
        st.results_dir || job?.lastResultsDir || "",
        st.started_utc ? `started ${st.started_utc}` : "",
      ]
        .filter(Boolean)
        .join(" · ");
      return (
        `<article class="prepare-droplet-card${active}" data-host="${host}">` +
        `<div class="card-main">` +
        `<div class="card-title">${nameForDropletHost(host)} ${statusBadgeHtml(st)}</div>` +
        `<div class="card-meta">${host}${meta ? ` · ${meta}` : ""}</div>` +
        `</div>` +
        `<button type="button" class="linkish" data-watch-host="${host}">View log</button>` +
        `</article>`
      );
    })
    .join("");

  prepareDropletCards.querySelectorAll("[data-watch-host]").forEach((btn) => {
    btn.addEventListener("click", () => {
      watchedDropletHost = btn.dataset.watchHost;
      if (prepareWatchPicker) prepareWatchPicker.value = watchedDropletHost;
      refreshPrepareStatus().catch((err) => showPrepareMessage(err.message, "err"));
    });
  });
}

function loadPrepareLast() {
  try {
    const raw = localStorage.getItem(PREPARE_LAST_KEY);
    return raw ? JSON.parse(raw) : null;
  } catch {
    return null;
  }
}

function savePrepareLast(values) {
  try {
    localStorage.setItem(PREPARE_LAST_KEY, JSON.stringify(values));
  } catch {
    /* ignore */
  }
}

function rememberPrepareProfile(values) {
  if (!values.DROPLET_HOST && !values.MYSQL_HOST) return;
  const entry = {
    id: `${values.DROPLET_HOST}|${values.MYSQL_HOST}|${Date.now()}`,
    label: profileLabel(values),
    savedAt: new Date().toISOString(),
    values: { ...values },
  };
  let history = loadPrepareHistory();
  history = history.filter(
    (item) =>
      !(
        item.values?.DROPLET_HOST === values.DROPLET_HOST &&
        item.values?.MYSQL_HOST === values.MYSQL_HOST
      )
  );
  history.unshift(entry);
  savePrepareHistory(history);
  savePrepareLast(values);
  renderPrepareProfilePicker(history);
  renderWatchPicker();
}

function renderPrepareProfilePicker(history = loadPrepareHistory()) {
  if (!prepareProfilePicker) return;
  const current = prepareProfilePicker.value;
  prepareProfilePicker.innerHTML =
    '<option value="">— Select a previous entry —</option>' +
    history
      .map(
        (item) =>
          `<option value="${item.id}">${item.label}${item.savedAt ? ` (${item.savedAt.slice(0, 10)})` : ""}</option>`
      )
      .join("");
  if (current && history.some((item) => item.id === current)) {
    prepareProfilePicker.value = current;
  }
}

function suggestionValuesForField(fieldKey, history = loadPrepareHistory()) {
  const seen = new Set();
  const out = [];
  for (const item of history) {
    const val = (item.values?.[fieldKey] || "").trim();
    if (!val || seen.has(val)) continue;
    seen.add(val);
    out.push(val);
  }
  const last = loadPrepareLast();
  const lastVal = (last?.[fieldKey] || "").trim();
  if (lastVal && !seen.has(lastVal)) out.unshift(lastVal);
  return out;
}

function ensurePrepareDatalists() {
  let root = document.getElementById("prepare-datalists");
  if (!root) {
    root = document.createElement("div");
    root.id = "prepare-datalists";
    root.hidden = true;
    prepareForm.before(root);
  }
  root.innerHTML = "";
  for (const key of PREPARE_SUGGEST_KEYS) {
    const dl = document.createElement("datalist");
    dl.id = `prepare-suggest-${key}`;
    for (const val of suggestionValuesForField(key)) {
      const opt = document.createElement("option");
      opt.value = val;
      dl.appendChild(opt);
    }
    root.appendChild(dl);
  }
}

function applyPrepareValues(values) {
  for (const field of prepareSchemaFields) {
    const el = document.getElementById(`prepare-${field.key}`);
    if (!el || values[field.key] == null) continue;
    if (field.type === "checkbox") {
      el.checked = values[field.key] === "1";
    } else {
      el.value = values[field.key];
    }
  }
  updatePrepareEstimateDisplay(collectPrepareValues());
}

function renderPrepareForm(fields, values) {
  prepareForm.innerHTML = "";
  let currentSection = null;

  for (const field of fields) {
    if (field.section !== currentSection) {
      currentSection = field.section;
      const heading = document.createElement("div");
      heading.className = "form-section";
      heading.textContent = currentSection;
      prepareForm.appendChild(heading);
    }

    const wrap = document.createElement("div");
    wrap.className = "field";

    const label = document.createElement("label");
    label.setAttribute("for", `prepare-${field.key}`);
    label.textContent = field.label;

    let input;
    const value = values[field.key] ?? "";

    if (field.type === "checkbox") {
      input = document.createElement("div");
      input.className = "checkbox-row";
      const cb = document.createElement("input");
      cb.type = "checkbox";
      cb.id = `prepare-${field.key}`;
      cb.name = field.key;
      cb.checked = value === "1";
      input.appendChild(cb);
      input.appendChild(document.createTextNode(" Enabled"));
    } else if (field.type === "select") {
      input = document.createElement("select");
      input.id = `prepare-${field.key}`;
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
      input.id = `prepare-${field.key}`;
      input.name = field.key;
      if (field.type === "password" || field.key === "MYSQL_PASSWORD") {
        input.type = "password";
        input.autocomplete = "current-password";
      } else {
        input.type = field.type === "number" ? "number" : "text";
        if (PREPARE_SUGGEST_KEYS.has(field.key)) {
          input.setAttribute("list", `prepare-suggest-${field.key}`);
          input.autocomplete = "off";
        }
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

    prepareForm.appendChild(wrap);
  }

  ensurePrepareDatalists();
  injectPrepareDropletPicker();
  bindPrepareFormListeners();
  updatePrepareEstimateDisplay(collectPrepareValues());
}

function injectPrepareDropletPicker() {
  const droplets = DropletContext.droplets || [];
  document.getElementById("prepare-droplet-quickpick-wrap")?.remove();
  if (droplets.length <= 1) return;

  const wrap = document.createElement("div");
  wrap.id = "prepare-droplet-quickpick-wrap";
  wrap.className = "field prepare-droplet-quickpick";

  const label = document.createElement("label");
  label.setAttribute("for", "prepare-droplet-quickpick");
  label.textContent = "Pick droplet";

  const select = document.createElement("select");
  select.id = "prepare-droplet-quickpick";
  select.innerHTML =
    '<option value="">— Manual entry —</option>' +
    droplets
      .map((d) => `<option value="${d.host}">${DropletContext.dropletLabel(d)}</option>`)
      .join("");

  const currentHost = collectPrepareValues().DROPLET_HOST;
  if (DropletContext.findDroplet(currentHost)) {
    select.value = currentHost;
  }

  select.addEventListener("change", () => {
    if (!select.value) return;
    applyConfiguredDroplet(select.value);
    showPrepareMessage(`Selected ${nameForDropletHost(select.value)}`, "ok");
  });

  wrap.appendChild(label);
  wrap.appendChild(select);

  const help = document.createElement("div");
  help.className = "help";
  help.textContent = "Fills droplet name and IP from control.local.conf (DROPLET_MAP).";
  wrap.appendChild(help);

  const firstSection = prepareForm.querySelector(".form-section");
  if (firstSection) {
    prepareForm.insertBefore(wrap, firstSection);
  } else {
    prepareForm.prepend(wrap);
  }
}

function bindPrepareFormListeners() {
  const datasetKeys = new Set(["TPCC_TABLES", "TPCC_SCALE", "PREP_THREADS"]);
  for (const field of prepareSchemaFields) {
    const el = document.getElementById(`prepare-${field.key}`);
    if (!el) continue;
    const handler = () => {
      const values = collectPrepareValues();
      if (datasetKeys.has(field.key)) {
        updatePrepareEstimateDisplay(values);
      }
      clearTimeout(saveFormTimer);
      saveFormTimer = setTimeout(() => savePrepareLast(values), 400);
    };
    el.addEventListener("input", handler);
    el.addEventListener("change", handler);
  }
}

function collectPrepareValues() {
  const values = {};
  for (const field of prepareSchemaFields) {
    const el = document.getElementById(`prepare-${field.key}`);
    if (!el) continue;
    if (field.type === "checkbox") {
      values[field.key] = el.checked ? "1" : "0";
    } else {
      values[field.key] = el.value.trim();
    }
  }
  return values;
}

function getStatusValues() {
  if (watchedDropletHost) return valuesForDropletHost(watchedDropletHost);
  return collectPrepareValues();
}

async function fetchPrepareStatus(values) {
  return api("/api/prepare/status", {
    method: "POST",
    body: JSON.stringify({ values }),
  });
}

async function fetchPrepareLog(values, lines = 150) {
  return api("/api/prepare/log", {
    method: "POST",
    body: JSON.stringify({ values, lines }),
  });
}

let lastPrepareStatus = {};

function renderPrepareStatusLast() {
  renderPrepareStatus(lastPrepareStatus);
}

function renderPrepareStatus(status, values) {
  lastPrepareStatus = status;
  const running = !!status.running;
  const success = !!status.success;
  const failed = !!status.failed;

  let badge;
  if (running) {
    badge = '<span class="badge running">Loading data…</span>';
  } else if (success) {
    badge = '<span class="badge completed">Data load successful</span>';
  } else if (failed) {
    badge = '<span class="badge failed">Data load failed</span>';
  } else {
    badge = '<span class="badge idle">Idle</span>';
  }

  const est = estimatePrepareLocal(values).estimated_prepare_sec;

  const lines = [
    badge,
    status.droplet_name || dropletDisplayName(values)
      ? `Droplet: ${status.droplet_name || dropletDisplayName(values)} (${values.DROPLET_HOST || status.droplet_host || "?"})`
      : "",
    values.MYSQL_HOST ? `MySQL: ${values.MYSQL_HOST}` : "",
    running && status.pid ? `PID ${status.pid}` : "",
    status.started_utc ? `Started ${status.started_utc}` : "",
    status.results_dir ? `Results: ${status.results_dir}` : "",
    status.check_ok === "1" ? "TPC-C check: passed" : status.check_ok === "0" ? "TPC-C check: failed" : "",
    est != null ? `Estimated prepare: ~${formatDuration(est)}` : "",
  ].filter(Boolean);

  prepareSummary.innerHTML = lines.map((line) => `<div>${line}</div>`).join("");

  const formValues = collectPrepareValues();
  const formStatus = dropletStatusCache[formValues.DROPLET_HOST];
  btnPrepareStart.disabled = !!(formStatus && formStatus.running);
}

async function refreshPrepareStatusForHost(host) {
  const values = valuesForDropletHost(host);
  if (!values.DROPLET_HOST) return null;
  const status = await fetchPrepareStatus(values);
  dropletStatusCache[host] = status;
  upsertPrepareJob(values, status);
  return status;
}

async function refreshAllDropletStatuses() {
  const hosts = uniqueDropletHosts();
  await Promise.all(hosts.map((h) => refreshPrepareStatusForHost(h).catch(() => null)));
  renderWatchPicker();
  renderDropletCards();
}

async function refreshPrepareStatus() {
  const values = getStatusValues();
  savePrepareLast(collectPrepareValues());

  if (!values.DROPLET_HOST) {
    showPrepareMessage("Set droplet IP or pick a droplet under Progress by droplet.", "err");
    return;
  }

  updateWatchNote(values);

  const status = await refreshPrepareStatusForHost(values.DROPLET_HOST);
  if (!status) return;
  renderPrepareStatus(status, values);

  try {
    const logData = await fetchPrepareLog(values);
    prepareLog.textContent = logData.log || "(empty log)";
    prepareLog.scrollTop = prepareLog.scrollHeight;
  } catch {
    if (!status.running) {
      prepareLog.textContent = "No prepare job log yet.";
    }
  }

  renderWatchPicker();
  renderDropletCards();

  const anyRunning = Object.values(dropletStatusCache).some((s) => s?.running);
  const watchRunning = !!status.running;

  if (watchRunning && !preparePollTimer) {
    preparePollTimer = setInterval(() => {
      refreshAllDropletStatuses()
        .then(() => refreshPrepareStatus())
        .catch(() => {});
    }, 5000);
  }
  if (!anyRunning && preparePollTimer) {
    clearInterval(preparePollTimer);
    preparePollTimer = null;
    if (status.success) {
      showPrepareMessage("TPC-C data loaded successfully. Set SKIP_PREPARE=1 for failover runs.", "ok");
    } else if (status.failed) {
      showPrepareMessage("Data load failed — see log below.", "err");
    }
  }
}

async function loadPrepareTab() {
  await DropletContext.init();

  const [schema, defaults] = await Promise.all([
    api("/api/prepare/schema"),
    api("/api/prepare/defaults"),
  ]);
  prepareSchemaFields = schema.fields;

  const last = loadPrepareLast();
  const values = { ...(defaults.values || {}), ...(last || {}) };
  prepareEstimateCache = {
    estimated_prepare_sec: defaults.estimated_prepare_sec ?? null,
    data_size_label: defaults.data_size_label || "",
    data_size_gb: defaults.data_size_gb ?? null,
  };

  renderPrepareProfilePicker();
  renderWatchPicker();
  renderPrepareForm(prepareSchemaFields, values);

  await refreshAllDropletStatuses();
  const runningHost = Object.entries(dropletStatusCache).find(([, s]) => s?.running)?.[0];
  if (runningHost) {
    watchedDropletHost = runningHost;
    if (prepareWatchPicker) prepareWatchPicker.value = runningHost;
  }
  await refreshPrepareStatus();
  prepareLoaded = true;
}

prepareProfilePicker?.addEventListener("change", () => {
  const id = prepareProfilePicker.value;
  if (!id) return;
  const item = loadPrepareHistory().find((entry) => entry.id === id);
  if (!item?.values) return;
  applyPrepareValues(item.values);
  savePrepareLast(item.values);
  watchedDropletHost = "";
  if (prepareWatchPicker) prepareWatchPicker.value = "";
  showPrepareMessage(`Loaded profile: ${item.label}`, "ok");
});

prepareWatchPicker?.addEventListener("change", () => {
  watchedDropletHost = prepareWatchPicker.value || "";
  refreshPrepareStatus().catch((err) => showPrepareMessage(err.message, "err"));
});

btnPrepareWatch?.addEventListener("click", () => {
  watchedDropletHost = prepareWatchPicker?.value || collectPrepareValues().DROPLET_HOST || "";
  if (prepareWatchPicker && watchedDropletHost) prepareWatchPicker.value = watchedDropletHost;
  refreshPrepareStatus().catch((err) => showPrepareMessage(err.message, "err"));
});

btnPrepareRefreshAll?.addEventListener("click", () => {
  refreshAllDropletStatuses()
    .then(() => refreshPrepareStatus())
    .catch((err) => showPrepareMessage(err.message, "err"));
});

btnPrepareRefresh?.addEventListener("click", () => {
  refreshPrepareStatus().catch((err) => showPrepareMessage(err.message, "err"));
});

btnPrepareTest?.addEventListener("click", async () => {
  btnPrepareTest.disabled = true;
  try {
    const values = collectPrepareValues();
    rememberPrepareProfile(values);
    const result = await api("/api/prepare/test", {
      method: "POST",
      body: JSON.stringify({ values }),
    });
    showPrepareMessage(result.message, result.ok ? "ok" : "err");
  } catch (err) {
    showPrepareMessage(err.message, "err");
  } finally {
    btnPrepareTest.disabled = false;
  }
});

btnPrepareStart?.addEventListener("click", async () => {
  const values = collectPrepareValues();
  if (!values.DROPLET_HOST || !values.MYSQL_HOST || !values.MYSQL_PASSWORD) {
    showPrepareMessage("Droplet IP, MySQL hostname, and password are required.", "err");
    return;
  }

  const formStatus = dropletStatusCache[values.DROPLET_HOST];
  if (formStatus?.running) {
    showPrepareMessage("A load is already running on this droplet. Watch it under Progress by droplet.", "err");
    return;
  }

  const est = formatDuration(estimatePrepareLocal(values).estimated_prepare_sec);
  const size = prepareEstimateCache.data_size_label || `tables=${values.TPCC_TABLES} scale=${values.TPCC_SCALE}`;
  const ok = window.confirm(
    "Load TPC-C data on the droplet?\n\n" +
      `Droplet: ${values.DROPLET_NAME || values.DROPLET_HOST}\n` +
      `MySQL: ${values.MYSQL_HOST}\n` +
      `Dataset: ${size}\n\n` +
      `Estimated time: ~${est}\n\n` +
      "This will drop and reload existing TPC-C tables on the target database."
  );
  if (!ok) return;

  btnPrepareStart.disabled = true;
  rememberPrepareProfile(values);
  try {
    const result = await api("/api/prepare/start", {
      method: "POST",
      body: JSON.stringify({ values }),
    });
    if (!result.ok) {
      throw new Error(result.error || "Start failed");
    }
    watchedDropletHost = values.DROPLET_HOST;
    if (prepareWatchPicker) prepareWatchPicker.value = watchedDropletHost;
    upsertPrepareJob(values, result.status || {});
    prepareEstimateCache = {
      estimated_prepare_sec: result.estimated_prepare_sec ?? prepareEstimateCache.estimated_prepare_sec,
      data_size_label: result.data_size_label || prepareEstimateCache.data_size_label,
      data_size_gb: result.data_size_gb ?? prepareEstimateCache.data_size_gb,
    };
    updatePrepareEstimateDisplay(values);
    showPrepareMessage(result.message || "Data load started on droplet.", "ok");
    await refreshPrepareStatus();
  } catch (err) {
    showPrepareMessage(err.message, "err");
  } finally {
    btnPrepareStart.disabled = false;
  }
});

window.addEventListener("failover-droplet", () => {
  if (!prepareLoaded) return;
  renderWatchPicker();
  renderDropletCards();
});

window.addEventListener("failover-tab", (event) => {
  const tab = event.detail?.tab;
  if (tab === "prepare" && !prepareLoaded) {
    loadPrepareTab().catch((err) => {
      prepareSummary.textContent = err.message;
      prepareSummary.className = "run-summary muted";
    });
  } else if (tab === "prepare" && prepareLoaded) {
    refreshAllDropletStatuses()
      .then(() => refreshPrepareStatus())
      .catch(() => {});
  }
});
