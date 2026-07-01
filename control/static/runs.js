const runsList = document.getElementById("runs-list");
const connectionStatus = document.getElementById("connection-status");
const btnRefresh = document.getElementById("btn-refresh-runs");

let pollTimer = null;

async function refreshRuns() {
  const data = await api("/api/reports?limit=50");
  renderRunsList(runsList, data, {
    onGenerate: async (resultsDir, button) => {
      try {
        await generateRunReport(resultsDir, button);
        await refreshRuns();
      } catch (err) {
        alert(err.message);
      }
    },
  });

  const running = (data.runs || []).some((run) => run.running);
  if (running && !pollTimer) {
    pollTimer = setInterval(() => refreshRuns().catch(() => {}), 10000);
  }
  if (!running && pollTimer) {
    clearInterval(pollTimer);
    pollTimer = null;
  }
}

btnRefresh.addEventListener("click", () => {
  runsList.textContent = "Loading…";
  refreshRuns().catch((err) => {
    runsList.textContent = err.message;
    runsList.className = "runs-list muted";
  });
});

loadConnectionStatus(connectionStatus);
refreshRuns().catch((err) => {
  runsList.textContent = err.message;
  runsList.className = "runs-list muted";
});
