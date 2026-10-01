function updateClock() {
  const now = new Date();
  const utc = now.toISOString().replace("T", " ").slice(0, 19) + "Z";
  const local = now.toLocaleTimeString("en-GB", { hour12: false }) + " SGT";
  document.getElementById("clock").textContent = local + " | " + utc;
}
setInterval(updateClock, 1000);
updateClock();

let pollInterval = null;

async function launchTraffic() {
  const btn = document.getElementById("btn-traffic");
  const count = parseInt(document.getElementById("traffic-count").value) || 100;
  const concurrency = parseInt(document.getElementById("traffic-concurrency").value) || 10;
  const footer = document.getElementById("traffic-status");

  btn.disabled = true;
  footer.textContent = "INITIATING...";
  footer.className = "card-footer active";

  try {
    const res = await fetch("/api/traffic/bookinfo", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ count, concurrency }),
    });
    const task = await res.json();
    footer.textContent = "TASK " + task.id.toUpperCase() + " DISPATCHED";
    startPolling();
  } catch (e) {
    footer.textContent = "ERROR: " + e.message;
    footer.className = "card-footer error";
    btn.disabled = false;
  }
}

function startPolling() {
  if (pollInterval) return;
  pollInterval = setInterval(refreshTasks, 1500);
  refreshTasks();
}

async function refreshTasks() {
  try {
    const res = await fetch("/api/tasks");
    const tasks = await res.json();
    renderTaskLog(tasks);

    const running = tasks.some((t) => t.status === "running" || t.status === "queued");
    const btn = document.getElementById("btn-traffic");
    const footer = document.getElementById("traffic-status");

    if (!running && pollInterval) {
      clearInterval(pollInterval);
      pollInterval = null;
      btn.disabled = false;
      const last = tasks[0];
      if (last && last.status === "complete") {
        footer.textContent =
          "COMPLETE — " + last.success + " OK / " + last.fail + " FAIL";
        footer.className = last.fail > 0 ? "card-footer error" : "card-footer active";
      }
    } else if (running) {
      const active = tasks.find((t) => t.status === "running");
      if (active) {
        const pct = Math.round((active.progress / active.total) * 100);
        footer.textContent =
          "EXECUTING — " + active.progress + "/" + active.total + " (" + pct + "%)";
        footer.className = "card-footer active";
      }
    }
  } catch (e) {
    // silently retry
  }
}

function renderTaskLog(tasks) {
  const log = document.getElementById("task-log");
  if (!tasks.length) {
    log.innerHTML = '<div class="log-empty">NO OPERATIONS RECORDED</div>';
    return;
  }

  log.innerHTML = tasks
    .map((t) => {
      const pct = t.total > 0 ? Math.round((t.progress / t.total) * 100) : 0;
      const time = t.started_at
        ? new Date(t.started_at).toLocaleTimeString("en-GB", { hour12: false })
        : "";
      const detail =
        t.status === "complete"
          ? t.success + " OK / " + t.fail + " FAIL"
          : t.status === "running"
            ? t.progress + "/" + t.total
            : "QUEUED";

      return (
        '<div class="log-entry">' +
        '<div class="log-status ' + t.status + '"></div>' +
        '<span class="log-type">' + t.type.toUpperCase() + "</span>" +
        '<span class="log-detail">' + detail + "</span>" +
        '<div class="log-bar-wrap"><div class="log-bar ' + t.status + '" style="width:' + pct + '%"></div></div>' +
        '<span class="log-time">' + time + "</span>" +
        "</div>"
      );
    })
    .join("");
}

// initial load
startPolling();
