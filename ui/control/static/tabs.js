const TAB_IDS = ["run", "prepare", "reports", "compare"];

function tabFromHash() {
  const hash = (window.location.hash || "").replace(/^#/, "");
  return TAB_IDS.includes(hash) ? hash : "run";
}

function activateTab(tabId, { updateHash = true } = {}) {
  const id = TAB_IDS.includes(tabId) ? tabId : "run";
  document.querySelectorAll(".tab-bar .tab").forEach((button) => {
    button.classList.toggle("active", button.dataset.tab === id);
  });
  document.querySelectorAll(".tab-panel").forEach((panel) => {
    panel.classList.toggle("active", panel.id === `panel-${id}`);
  });
  if (updateHash && window.location.hash.replace(/^#/, "") !== id) {
    history.replaceState(null, "", `#${id}`);
  }
  window.dispatchEvent(new CustomEvent("failover-tab", { detail: { tab: id } }));
}

window.activateFailoverTab = activateTab;

function initTabs() {
  document.querySelectorAll(".tab-bar .tab").forEach((button) => {
    button.addEventListener("click", () => activateTab(button.dataset.tab));
  });
  activateTab(tabFromHash(), { updateHash: false });
  window.addEventListener("hashchange", () => activateTab(tabFromHash(), { updateHash: false }));
}

document.addEventListener("DOMContentLoaded", initTabs);
