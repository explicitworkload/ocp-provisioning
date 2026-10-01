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

// --- Service Mesh Controls ---

function updateWeightTotal() {
  const v1 = parseInt(document.getElementById("shift-v1").value) || 0;
  const v2 = parseInt(document.getElementById("shift-v2").value) || 0;
  const v3 = parseInt(document.getElementById("shift-v3").value) || 0;
  const total = v1 + v2 + v3;
  const el = document.getElementById("weight-total");
  el.textContent = "= " + total + "%";
  el.style.color = total === 100 ? "var(--green-400)" : "var(--red-400)";
}

document.addEventListener("DOMContentLoaded", function () {
  ["shift-v1", "shift-v2", "shift-v3"].forEach(function (id) {
    var el = document.getElementById(id);
    if (el) el.addEventListener("input", updateWeightTotal);
  });
});

function setFaultMode(mode) {
  document.querySelectorAll("#fault-mode-toggle .mode-btn").forEach(function (b) {
    b.classList.toggle("active", b.dataset.mode === mode);
  });
  document.getElementById("fault-delay-inputs").style.display =
    mode === "delay" ? "flex" : "none";
  document.getElementById("fault-abort-inputs").style.display =
    mode === "abort" ? "flex" : "none";
}

function setStatusBar(id, text, type) {
  var el = document.getElementById(id);
  el.textContent = text;
  el.className = "card-footer" + (type ? " " + type : "");
}

async function applyTrafficShift() {
  var v1 = parseInt(document.getElementById("shift-v1").value) || 0;
  var v2 = parseInt(document.getElementById("shift-v2").value) || 0;
  var v3 = parseInt(document.getElementById("shift-v3").value) || 0;
  setStatusBar("shift-status", "APPLYING...", "active");
  try {
    var res = await fetch("/api/mesh/traffic-shift", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ v1: v1, v2: v2, v3: v3 }),
    });
    var data = await res.json();
    if (res.ok) {
      setStatusBar("shift-status", "APPLIED — v1:" + v1 + "% v2:" + v2 + "% v3:" + v3 + "%", "active");
    } else {
      setStatusBar("shift-status", "ERROR: " + data.error, "error");
    }
  } catch (e) {
    setStatusBar("shift-status", "ERROR: " + e.message, "error");
  }
}

async function applyFaultInjection() {
  var activeMode = document.querySelector("#fault-mode-toggle .mode-btn.active").dataset.mode;
  var body = { target: "ratings", type: activeMode };
  if (activeMode === "delay") {
    body.delay_ms = parseInt(document.getElementById("fault-delay").value) || 5000;
    body.percentage = parseInt(document.getElementById("fault-pct").value) || 100;
  } else {
    body.status_code = parseInt(document.getElementById("fault-status").value) || 500;
    body.percentage = parseInt(document.getElementById("fault-abort-pct").value) || 100;
  }
  setStatusBar("fault-status-bar", "INJECTING...", "active");
  try {
    var res = await fetch("/api/mesh/fault-injection", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    if (res.ok) {
      var label = activeMode === "delay"
        ? "DELAY " + body.delay_ms + "ms @ " + body.percentage + "%"
        : "ABORT HTTP " + body.status_code + " @ " + body.percentage + "%";
      setStatusBar("fault-status-bar", "ACTIVE — " + label, "error");
    } else {
      var data = await res.json();
      setStatusBar("fault-status-bar", "ERROR: " + data.error, "error");
    }
  } catch (e) {
    setStatusBar("fault-status-bar", "ERROR: " + e.message, "error");
  }
}

async function applyCircuitBreaker() {
  var body = {
    maxConnections: parseInt(document.getElementById("cb-max-conn").value) || 1,
    maxPendingRequests: parseInt(document.getElementById("cb-max-pending").value) || 1,
    maxRequests: parseInt(document.getElementById("cb-max-req").value) || 1,
  };
  setStatusBar("cb-status", "APPLYING...", "active");
  try {
    var res = await fetch("/api/mesh/circuit-breaker", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    if (res.ok) {
      setStatusBar("cb-status",
        "ACTIVE — max:" + body.maxConnections + " pending:" + body.maxPendingRequests + " req:" + body.maxRequests,
        "active");
    }
  } catch (e) {
    setStatusBar("cb-status", "ERROR: " + e.message, "error");
  }
}

async function applyTimeout() {
  var body = {
    timeout: document.getElementById("timeout-val").value || "3s",
    retries: parseInt(document.getElementById("retry-attempts").value) || 2,
    retryTimeout: document.getElementById("retry-timeout").value || "2s",
  };
  setStatusBar("timeout-status", "APPLYING...", "active");
  try {
    var res = await fetch("/api/mesh/timeout", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    if (res.ok) {
      setStatusBar("timeout-status",
        "ACTIVE — timeout:" + body.timeout + " retries:" + body.retries + " @" + body.retryTimeout,
        "active");
    }
  } catch (e) {
    setStatusBar("timeout-status", "ERROR: " + e.message, "error");
  }
}

async function resetMesh(feature) {
  var statusMap = {
    "traffic-shift": "shift-status",
    "fault-injection": "fault-status-bar",
    "circuit-breaker": "cb-status",
    "timeout": "timeout-status",
  };
  try {
    await fetch("/api/mesh/" + feature, { method: "DELETE" });
    setStatusBar(statusMap[feature], "STANDBY", "");
  } catch (e) {
    // ignore
  }
}

async function resetAllMesh() {
  try {
    await fetch("/api/mesh/reset-all", { method: "POST" });
    ["shift-status", "fault-status-bar", "cb-status", "timeout-status"].forEach(function (id) {
      setStatusBar(id, "STANDBY", "");
    });
  } catch (e) {
    // ignore
  }
}

// initial load
startPolling();
