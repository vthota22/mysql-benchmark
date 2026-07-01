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
    container.innerHTML = "No failover runs found on the droplet.";
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
        `<div class="run-meta">${run.results_dir}</div>` +
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

async function generateRunReport(resultsDir, button) {
  if (button) {
    button.disabled = true;
    button.textContent = "Generating…";
  }
  try {
    return await api("/api/runs/generate-report", {
      method: "POST",
      body: JSON.stringify({ results_dir: resultsDir }),
    });
  } finally {
    if (button) {
      button.disabled = false;
      button.textContent = "Generate HTML report";
    }
  }
}

async function loadConnectionStatus(el) {
  try {
    const health = await api("/api/health");
    el.textContent = health.message;
    el.style.color = health.ok ? "var(--ok)" : "var(--err)";
  } catch (err) {
    el.textContent = err.message;
    el.style.color = "var(--err)";
  }
}
