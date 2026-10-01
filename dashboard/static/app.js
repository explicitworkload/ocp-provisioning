function updateClock() {
  const now = new Date();
  const utc = now.toISOString().replace("T", " ").slice(0, 19) + "Z";
  const local = now.toLocaleTimeString("en-GB", { hour12: false }) + " SGT";
  document.getElementById("clock").textContent = local + " | " + utc;
}
setInterval(updateClock, 1000);
updateClock();

let pollInterval = null;
let activeTaskId = null;

function setMode(mode) {
  document.querySelectorAll(".mode-btn").forEach((b) => {
    b.classList.toggle("active", b.dataset.mode === mode);
  });
  document.getElementById("burst-inputs").style.display =
    mode === "burst" ? "flex" : "none";
  document.getElementById("sustained-inputs").style.display =
    mode === "sustained" ? "flex" : "none";
}

async function launchTraffic() {
  const btn = document.getElementById("btn-traffic");
  const count = parseInt(document.getElementById("traffic-count").value) || 100;
  const concurrency =
    parseInt(document.getElementById("traffic-concurrency").value) || 10;
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

async function launchSustained() {
  const btn = document.getElementById("btn-sustained");
  const btnStop = document.getElementById("btn-stop");
  const duration =
    parseFloat(document.getElementById("traffic-duration").value) || 15;
  const concurrency =
    parseInt(document.getElementById("sustained-concurrency").value) || 10;
  const footer = document.getElementById("traffic-status");

  btn.disabled = true;
  footer.textContent = "STARTING SUSTAINED TRAFFIC...";
  footer.className = "card-footer active";

  try {
    const res = await fetch("/api/traffic/bookinfo", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ duration, concurrency }),
    });
    const task = await res.json();
    activeTaskId = task.id;
    btnStop.style.display = "inline-flex";
    footer.textContent = "SUSTAINED — " + duration + "m @ " + concurrency + " threads";
    startPolling();
  } catch (e) {
    footer.textContent = "ERROR: " + e.message;
    footer.className = "card-footer error";
    btn.disabled = false;
  }
}

async function stopTraffic() {
  if (!activeTaskId) return;
  try {
    await fetch("/api/traffic/stop/" + activeTaskId, { method: "POST" });
    document.getElementById("traffic-status").textContent = "STOPPING...";
  } catch (e) {
    // ignore
  }
}

function formatTime(secs) {
  const m = Math.floor(secs / 60);
  const s = secs % 60;
  return m + ":" + String(s).padStart(2, "0");
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

    const running = tasks.some(
      (t) => t.status === "running" || t.status === "queued"
    );
    const btnBurst = document.getElementById("btn-traffic");
    const btnSustained = document.getElementById("btn-sustained");
    const btnStop = document.getElementById("btn-stop");
    const footer = document.getElementById("traffic-status");

    if (!running && pollInterval) {
      clearInterval(pollInterval);
      pollInterval = null;
      btnBurst.disabled = false;
      btnSustained.disabled = false;
      btnStop.style.display = "none";
      activeTaskId = null;
      const last = tasks[0];
      if (last && last.status === "complete") {
        const dur = last.duration
          ? " in " + formatTime(last.elapsed || 0)
          : "";
        footer.textContent =
          "COMPLETE — " + last.success + " OK / " + last.fail + " FAIL" + dur;
        footer.className =
          last.fail > 0 ? "card-footer error" : "card-footer active";
      }
    } else if (running) {
      const active = tasks.find((t) => t.status === "running");
      if (active) {
        if (active.duration) {
          const elapsed = active.elapsed || 0;
          const remaining = active.duration - elapsed;
          footer.textContent =
            "SUSTAINED — " +
            formatTime(elapsed) +
            " / " +
            formatTime(active.duration) +
            " | " +
            active.progress +
            " reqs | " +
            active.success +
            " OK";
        } else {
          const pct = Math.round((active.progress / active.total) * 100);
          footer.textContent =
            "EXECUTING — " +
            active.progress +
            "/" +
            active.total +
            " (" +
            pct +
            "%)";
        }
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
      const pct =
        t.duration && t.status === "running"
          ? Math.round(((t.elapsed || 0) / t.duration) * 100)
          : t.total > 0
            ? Math.round((t.progress / t.total) * 100)
            : 0;
      const time = t.started_at
        ? new Date(t.started_at).toLocaleTimeString("en-GB", { hour12: false })
        : "";
      let detail;
      if (t.status === "complete") {
        detail = t.success + " OK / " + t.fail + " FAIL";
      } else if (t.status === "running" && t.duration) {
        detail = formatTime(t.elapsed || 0) + " / " + formatTime(t.duration) + " | " + t.progress + " reqs";
      } else if (t.status === "running") {
        detail = t.progress + "/" + t.total;
      } else {
        detail = "QUEUED";
      }

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
