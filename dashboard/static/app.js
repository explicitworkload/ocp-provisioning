// === Clock ===
function updateClock() {
  var el = document.getElementById("clock");
  if (!el) return;
  var now = new Date();
  var local = now.toLocaleTimeString("en-GB", { hour12: false }) + " SGT";
  var utc = now.toISOString().replace("T", " ").slice(0, 19) + "Z";
  el.textContent = local + " | " + utc;
}
setInterval(updateClock, 1000);
updateClock();

// === Toast Notifications ===
function showToast(message, type) {
  var container = document.getElementById("toast-container");
  if (!container) return;
  var icons = { success: "&#10003;", error: "&#10007;", info: "&#9642;" };
  var toast = document.createElement("div");
  toast.className = "toast " + (type || "info");
  toast.innerHTML = '<span class="toast-icon">' + (icons[type] || icons.info) + "</span>" + message;
  container.appendChild(toast);
  setTimeout(function () {
    toast.classList.add("toast-fade-out");
    setTimeout(function () { toast.remove(); }, 300);
  }, 4000);
}

// === Task Panel ===
var taskPanelCollapsed = false;

function toggleTaskPanel() {
  var panel = document.getElementById("task-panel");
  if (!panel) return;
  taskPanelCollapsed = !taskPanelCollapsed;
  panel.classList.toggle("collapsed", taskPanelCollapsed);
}

// === Traffic Generator ===
var pollInterval = null;
var activeTaskId = null;
var previousTaskCount = 0;

function setMode(mode) {
  document.querySelectorAll("#mode-toggle .mode-btn").forEach(function (b) {
    b.classList.toggle("active", b.dataset.mode === mode);
  });
  var burst = document.getElementById("burst-inputs");
  var sustained = document.getElementById("sustained-inputs");
  if (burst) burst.style.display = mode === "burst" ? "flex" : "none";
  if (sustained) sustained.style.display = mode === "sustained" ? "flex" : "none";
}

async function launchTraffic() {
  var btn = document.getElementById("btn-traffic");
  var count = parseInt(document.getElementById("traffic-count").value) || 100;
  var concurrency = parseInt(document.getElementById("traffic-concurrency").value) || 10;
  var footer = document.getElementById("traffic-status");

  btn.disabled = true;
  footer.textContent = "INITIATING...";
  footer.className = "card-footer active";

  try {
    var res = await fetch("/api/traffic/bookinfo", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ count: count, concurrency: concurrency }),
    });
    var task = await res.json();
    footer.textContent = "TASK " + task.id.toUpperCase() + " DISPATCHED";
    showToast("Traffic task " + task.id + " started — " + count + " requests", "info");
    startPolling();
  } catch (e) {
    footer.textContent = "ERROR: " + e.message;
    footer.className = "card-footer error";
    btn.disabled = false;
    showToast("Traffic error: " + e.message, "error");
  }
}

async function launchSustained() {
  var btn = document.getElementById("btn-sustained");
  var btnStop = document.getElementById("btn-stop");
  var duration = parseFloat(document.getElementById("traffic-duration").value) || 15;
  var concurrency = parseInt(document.getElementById("sustained-concurrency").value) || 10;
  var footer = document.getElementById("traffic-status");

  btn.disabled = true;
  footer.textContent = "STARTING SUSTAINED TRAFFIC...";
  footer.className = "card-footer active";

  try {
    var res = await fetch("/api/traffic/bookinfo", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ duration: duration, concurrency: concurrency }),
    });
    var task = await res.json();
    activeTaskId = task.id;
    btnStop.style.display = "inline-flex";
    footer.textContent = "SUSTAINED — " + duration + "m @ " + concurrency + " threads";
    showToast("Sustained traffic started — " + duration + "m @ " + concurrency + " threads", "info");
    startPolling();
  } catch (e) {
    footer.textContent = "ERROR: " + e.message;
    footer.className = "card-footer error";
    btn.disabled = false;
    showToast("Traffic error: " + e.message, "error");
  }
}

async function stopTraffic() {
  if (!activeTaskId) return;
  await stopTaskById(activeTaskId);
}

async function stopTaskById(taskId) {
  try {
    await fetch("/api/traffic/stop/" + taskId, { method: "POST" });
    var footer = document.getElementById("traffic-status");
    if (footer) footer.textContent = "STOPPING...";
    showToast("Stopping sustained traffic...", "info");
  } catch (e) { /* ignore */ }
}

function formatTime(secs) {
  var m = Math.floor(secs / 60);
  var s = secs % 60;
  return m + ":" + String(s).padStart(2, "0");
}

function startPolling() {
  if (pollInterval) return;
  pollInterval = setInterval(refreshTasks, 1500);
  refreshTasks();
}

async function refreshTasks() {
  try {
    var res = await fetch("/api/tasks");
    var tasks = await res.json();
    renderTaskLog(tasks);

    // Toast for newly completed tasks
    if (tasks.length > 0 && previousTaskCount > 0) {
      var completed = tasks.filter(function (t) { return t.status === "complete"; });
      if (completed.length > previousTaskCount) {
        var last = completed[0];
        showToast(last.type.toUpperCase() + " complete — " + last.success + " OK / " + last.fail + " FAIL", last.fail > 0 ? "error" : "success");
      }
    }
    previousTaskCount = tasks.filter(function (t) { return t.status === "complete"; }).length;

    // Track active sustained task from server state
    var running = tasks.filter(function (t) { return t.status === "running"; });
    var activeSustained = running.find(function (t) { return t.duration; });
    if (activeSustained) activeTaskId = activeSustained.id;

    // Update badge
    var badge = document.getElementById("task-badge");
    if (badge) {
      if (running.length > 0) {
        badge.textContent = running.length;
        badge.style.display = "inline";
      } else {
        badge.style.display = "none";
      }
    }

    var hasRunning = tasks.some(function (t) { return t.status === "running" || t.status === "queued"; });
    var btnBurst = document.getElementById("btn-traffic");
    var btnSustained = document.getElementById("btn-sustained");
    var btnStop = document.getElementById("btn-stop");
    var footer = document.getElementById("traffic-status");

    if (!hasRunning && pollInterval) {
      clearInterval(pollInterval);
      pollInterval = null;
      if (btnBurst) btnBurst.disabled = false;
      if (btnSustained) btnSustained.disabled = false;
      if (btnStop) btnStop.style.display = "none";
      activeTaskId = null;
      var last = tasks[0];
      if (last && last.status === "complete" && footer) {
        var dur = last.duration ? " in " + formatTime(last.elapsed || 0) : "";
        footer.textContent = "COMPLETE — " + last.success + " OK / " + last.fail + " FAIL" + dur;
        footer.className = last.fail > 0 ? "card-footer error" : "card-footer active";
      }
    } else if (hasRunning) {
      var active = tasks.find(function (t) { return t.status === "running"; });
      if (active && footer) {
        if (active.duration) {
          var elapsed = active.elapsed || 0;
          footer.textContent = "SUSTAINED — " + formatTime(elapsed) + " / " + formatTime(active.duration) + " | " + active.progress + " reqs | " + active.success + " OK";
        } else {
          var pct = Math.round((active.progress / active.total) * 100);
          footer.textContent = "EXECUTING — " + active.progress + "/" + active.total + " (" + pct + "%)";
        }
        footer.className = "card-footer active";
      }
    }
  } catch (e) { /* silently retry */ }
}

function renderTaskLog(tasks) {
  var log = document.getElementById("task-log");
  if (!log) return;
  if (!tasks.length) {
    log.innerHTML = '<div class="log-empty">No operations recorded</div>';
    return;
  }

  log.innerHTML = tasks
    .map(function (t) {
      var pct =
        t.duration && t.status === "running"
          ? Math.round(((t.elapsed || 0) / t.duration) * 100)
          : t.total > 0
            ? Math.round((t.progress / t.total) * 100)
            : t.status === "complete" ? 100 : 0;
      var time = t.started_at
        ? new Date(t.started_at).toLocaleTimeString("en-GB", { hour12: false })
        : "";
      var detail;
      if (t.status === "complete") {
        detail = t.success + " OK / " + t.fail + " FAIL";
      } else if (t.status === "running" && t.duration) {
        detail = formatTime(t.elapsed || 0) + " / " + formatTime(t.duration) + " | " + t.progress + " reqs";
      } else if (t.status === "running") {
        detail = t.progress + "/" + t.total;
      } else if (t.status === "error") {
        detail = t.detail || "FAILED";
      } else {
        detail = "QUEUED";
      }

      var statusClass = t.status;
      var stopBtn = "";
      if (t.status === "running" && t.duration) {
        stopBtn = '<button class="btn-log-stop" onclick="stopTaskById(\'' + t.id + '\')">&#9632;</button>';
      }
      return (
        '<div class="log-entry">' +
        '<div class="log-status ' + statusClass + '"></div>' +
        '<span class="log-type">' + (t.type || "task").toUpperCase() + "</span>" +
        '<span class="log-detail">' + detail + "</span>" +
        stopBtn +
        '<div class="log-bar-wrap"><div class="log-bar ' + statusClass + '" style="width:' + pct + '%"></div></div>' +
        '<span class="log-time">' + time + "</span>" +
        "</div>"
      );
    })
    .join("");
}

// === Service Mesh Controls ===

function updateWeightTotal() {
  var v1 = parseInt(document.getElementById("shift-v1").value) || 0;
  var v2 = parseInt(document.getElementById("shift-v2").value) || 0;
  var v3 = parseInt(document.getElementById("shift-v3").value) || 0;
  var total = v1 + v2 + v3;
  var el = document.getElementById("weight-total");
  if (!el) return;
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
  var delay = document.getElementById("fault-delay-inputs");
  var abort = document.getElementById("fault-abort-inputs");
  if (delay) delay.style.display = mode === "delay" ? "flex" : "none";
  if (abort) abort.style.display = mode === "abort" ? "flex" : "none";
}

function setStatusBar(id, text, type) {
  var el = document.getElementById(id);
  if (!el) return;
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
      showToast("Traffic shift applied — v1:" + v1 + "% v2:" + v2 + "% v3:" + v3 + "%", "success");
    } else {
      setStatusBar("shift-status", "ERROR: " + data.error, "error");
      showToast("Traffic shift error: " + data.error, "error");
    }
  } catch (e) {
    setStatusBar("shift-status", "ERROR: " + e.message, "error");
    showToast("Traffic shift error: " + e.message, "error");
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
      showToast("Fault injection active — " + label, "success");
    } else {
      var data = await res.json();
      setStatusBar("fault-status-bar", "ERROR: " + data.error, "error");
      showToast("Fault injection error", "error");
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
      setStatusBar("cb-status", "ACTIVE — max:" + body.maxConnections + " pending:" + body.maxPendingRequests + " req:" + body.maxRequests, "active");
      showToast("Circuit breaker applied", "success");
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
      setStatusBar("timeout-status", "ACTIVE — timeout:" + body.timeout + " retries:" + body.retries + " @" + body.retryTimeout, "active");
      showToast("Timeout & retries applied", "success");
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
    showToast(feature.replace("-", " ") + " reset", "info");
  } catch (e) { /* ignore */ }
}

async function resetAllMesh() {
  try {
    await fetch("/api/mesh/reset-all", { method: "POST" });
    ["shift-status", "fault-status-bar", "cb-status", "timeout-status"].forEach(function (id) {
      setStatusBar(id, "STANDBY", "");
    });
    showToast("All mesh policies reset", "success");
  } catch (e) { /* ignore */ }
}

// === Platform Admin ===

async function refreshPlatform() {
  var container = document.getElementById("platform-machinesets");
  if (!container) return;
  setStatusBar("platform-status", "LOADING...", "active");
  try {
    var res = await fetch("/api/platform/status");
    var data = await res.json();
    if (!res.ok) {
      setStatusBar("platform-status", "ERROR: " + (data.error || "unknown"), "error");
      return;
    }
    renderMachineSets(data.machinesets);
    renderNodes(data.nodes);
    var totalReady = data.nodes.filter(function (n) { return n.ready; }).length;
    setStatusBar("platform-status", totalReady + " NODES READY", "active");
  } catch (e) {
    setStatusBar("platform-status", "ERROR: " + e.message, "error");
  }
}

function renderMachineSets(machinesets) {
  var container = document.getElementById("platform-machinesets");
  if (!container) return;
  if (!machinesets.length) {
    container.innerHTML = '<div class="log-empty">No MachineSets found</div>';
    return;
  }
  container.innerHTML = machinesets
    .map(function (ms) {
      var badge = ms.isGpu
        ? '<span class="platform-badge gpu">GPU</span>'
        : '<span class="platform-badge worker">WORKER</span>';
      return (
        '<div class="platform-row">' +
        badge +
        '<span class="platform-name">' + ms.name + "</span>" +
        '<span class="platform-type">' + ms.instanceType + "</span>" +
        '<span class="platform-ready">' + ms.ready + "/" + ms.replicas + " ready</span>" +
        '<div class="platform-replicas">' +
        '<input type="number" min="0" max="10" value="' + ms.replicas + '" id="scale-' + ms.name + '">' +
        '<button class="btn-scale" onclick="scaleMachineSet(\'' + ms.name + '\')">Scale</button>' +
        "</div>" +
        "</div>"
      );
    })
    .join("");
}

function renderNodes(nodes) {
  var container = document.getElementById("platform-nodes");
  if (!container) return;
  if (!nodes.length) {
    container.innerHTML = '<div class="log-empty">No nodes found</div>';
    return;
  }
  container.innerHTML = nodes
    .map(function (n) {
      var statusClass = n.ready ? "ready" : "not-ready";
      return (
        '<div class="node-row">' +
        '<div class="node-status ' + statusClass + '"></div>' +
        '<span class="node-name">' + n.name + "</span>" +
        '<span class="node-roles">' + n.roles.join(", ") + "</span>" +
        "</div>"
      );
    })
    .join("");
}

async function scaleMachineSet(name) {
  var input = document.getElementById("scale-" + name);
  var replicas = parseInt(input.value);
  if (isNaN(replicas) || replicas < 0) return;
  setStatusBar("platform-status", "SCALING " + name + " TO " + replicas + "...", "active");
  try {
    var res = await fetch("/api/platform/scale", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ machineset: name, replicas: replicas }),
    });
    var data = await res.json();
    if (res.ok) {
      setStatusBar("platform-status", "SCALED " + name + " → " + replicas, "active");
      showToast("Scaled " + name + " to " + replicas + " replicas", "success");
      addPlatformTask("scale", "Scaled " + name + " → " + replicas);
      setTimeout(refreshPlatform, 3000);
    } else {
      setStatusBar("platform-status", "ERROR: " + data.error, "error");
      showToast("Scale error: " + data.error, "error");
      addPlatformTask("scale-error", "Failed to scale " + name);
    }
  } catch (e) {
    setStatusBar("platform-status", "ERROR: " + e.message, "error");
    showToast("Scale error: " + e.message, "error");
  }
}

async function shutdownCluster() {
  if (!confirm("This will scale ALL worker and GPU MachineSets to 0 replicas. Masters and control plane stay running. Continue?")) return;
  setStatusBar("platform-status", "SHUTTING DOWN...", "error");
  try {
    var res = await fetch("/api/platform/shutdown", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
    });
    var data = await res.json();
    if (res.ok) {
      setStatusBar("platform-status", "SHUTDOWN INITIATED — " + data.scaled.length + " MACHINESETS SCALED TO 0", "error");
      showToast("Shutdown initiated — " + data.scaled.length + " MachineSets scaling to 0", "error");
      addPlatformTask("shutdown", "Shutdown — " + data.scaled.length + " MachineSets → 0");
      setTimeout(refreshPlatform, 5000);
    } else {
      setStatusBar("platform-status", "ERROR: " + data.error, "error");
      showToast("Shutdown error: " + data.error, "error");
    }
  } catch (e) {
    setStatusBar("platform-status", "ERROR: " + e.message, "error");
  }
}

function addPlatformTask(type, detail) {
  var log = document.getElementById("task-log");
  if (!log) return;
  var empty = log.querySelector(".log-empty");
  if (empty) empty.remove();
  var time = new Date().toLocaleTimeString("en-GB", { hour12: false });
  var statusClass = type.includes("error") ? "error" : "complete";
  var entry = document.createElement("div");
  entry.className = "log-entry";
  entry.innerHTML =
    '<div class="log-status ' + statusClass + '"></div>' +
    '<span class="log-type">PLATFORM</span>' +
    '<span class="log-detail">' + detail + "</span>" +
    '<div class="log-bar-wrap"><div class="log-bar ' + statusClass + '" style="width:100%"></div></div>' +
    '<span class="log-time">' + time + "</span>";
  log.insertBefore(entry, log.firstChild);

  // Expand task panel if collapsed
  var panel = document.getElementById("task-panel");
  if (panel && panel.classList.contains("collapsed")) {
    taskPanelCollapsed = false;
    panel.classList.remove("collapsed");
  }
}

// === AI ===
var chatHistory = [];
var enabledMcpServers = {};

async function refreshAiModels() {
  var select = document.getElementById("ai-model");
  if (!select) return;
  setStatusBar("ai-model-status", "LOADING...", "active");
  try {
    var res = await fetch("/api/ai/models");
    var data = await res.json();
    if (!res.ok) {
      setStatusBar("ai-model-status", "ERROR: " + (data.error || "unknown"), "error");
      return;
    }
    select.innerHTML = "";
    if (!data.models.length) {
      select.innerHTML = '<option value="">No models available</option>';
      setStatusBar("ai-model-status", "NO MODELS", "error");
      return;
    }
    data.models.forEach(function (m) {
      var opt = document.createElement("option");
      opt.value = m;
      opt.textContent = m;
      select.appendChild(opt);
    });
    setStatusBar("ai-model-status", data.models.length + " MODEL(S) AVAILABLE", "active");
  } catch (e) {
    setStatusBar("ai-model-status", "ERROR: " + e.message, "error");
  }
}

async function refreshMcpServers() {
  var container = document.getElementById("mcp-server-list");
  if (!container) return;
  setStatusBar("mcp-status", "SCANNING...", "active");
  try {
    var res = await fetch("/api/ai/mcp-servers");
    var data = await res.json();
    if (!res.ok) {
      container.innerHTML = '<div class="log-empty">Error: ' + (data.error || "unknown") + "</div>";
      setStatusBar("mcp-status", "ERROR", "error");
      return;
    }
    if (!data.servers.length) {
      container.innerHTML = '<div class="log-empty">No MCP servers found</div>';
      setStatusBar("mcp-status", "NO SERVERS", "");
      return;
    }
    container.innerHTML = data.servers
      .map(function (s) {
        var statusClass = s.phase === "Ready" ? "ready" : s.phase === "Unknown" ? "pending" : "error";
        var key = s.namespace + "/" + s.name;
        var isActive = !!enabledMcpServers[key];
        var toggleClass = isActive ? "mcp-toggle active" : "mcp-toggle";
        return (
          '<div class="mcp-row">' +
          '<div class="mcp-status ' + statusClass + '"></div>' +
          '<span class="mcp-name">' + s.name + "</span>" +
          '<span class="mcp-ns">' + s.namespace + "</span>" +
          '<span class="mcp-tools-count" id="mcp-tools-' + key.replace("/", "-") + '"></span>' +
          '<div class="' + toggleClass + '" onclick="toggleMcpServer(\'' + key + '\', \'' + s.namespace + '\', \'' + s.name + '\')" id="mcp-toggle-' + key.replace("/", "-") + '"></div>' +
          "</div>"
        );
      })
      .join("");
    var readyCount = data.servers.filter(function (s) { return s.phase === "Ready"; }).length;
    setStatusBar("mcp-status", readyCount + "/" + data.servers.length + " READY", readyCount > 0 ? "active" : "");
  } catch (e) {
    setStatusBar("mcp-status", "ERROR: " + e.message, "error");
  }
}

async function toggleMcpServer(key, namespace, name) {
  var toggleEl = document.getElementById("mcp-toggle-" + key.replace("/", "-"));
  var toolsEl = document.getElementById("mcp-tools-" + key.replace("/", "-"));

  if (enabledMcpServers[key]) {
    delete enabledMcpServers[key];
    if (toggleEl) toggleEl.classList.remove("active");
    if (toolsEl) toolsEl.textContent = "";
    showToast("MCP server " + name + " disabled", "info");
    return;
  }

  if (toolsEl) toolsEl.textContent = "loading...";

  try {
    var res = await fetch("/api/ai/mcp-servers/" + namespace + "/" + name + "/tools");
    var data = await res.json();
    if (!res.ok) {
      showToast("Failed to connect: " + (data.error || "unknown"), "error");
      if (toolsEl) toolsEl.textContent = "error";
      return;
    }
    enabledMcpServers[key] = {
      url: data.url,
      tools: data.tools,
    };
    if (toggleEl) toggleEl.classList.add("active");
    if (toolsEl) toolsEl.textContent = data.tools.length + " tools";
    showToast("MCP server " + name + " enabled — " + data.tools.length + " tools", "success");
  } catch (e) {
    showToast("Error: " + e.message, "error");
    if (toolsEl) toolsEl.textContent = "error";
  }
}

function getSelectedModel() {
  var el = document.getElementById("ai-model");
  return el ? el.value : "";
}

function getEnabledMcpUrls() {
  var urls = [];
  for (var key in enabledMcpServers) {
    if (enabledMcpServers[key].url) {
      urls.push(enabledMcpServers[key].url);
    }
  }
  return urls;
}

function renderChatMessages() {
  var container = document.getElementById("chat-messages");
  if (!container) return;
  if (!chatHistory.length) {
    container.innerHTML = '<div class="chat-empty">Start a conversation with the model</div>';
    return;
  }
  container.innerHTML = chatHistory
    .filter(function (m) { return m.role !== "system"; })
    .map(function (m) {
      var cls = m.role === "user" ? "user" : m.role === "tool" ? "tool-result" : "assistant";
      var roleLabel = m.role === "tool" ? "TOOL RESULT" : m.role.toUpperCase();
      return (
        '<div class="chat-msg ' + cls + '">' +
        '<div class="chat-msg-role">' + roleLabel + "</div>" +
        '<div>' + escapeHtml(m.content || "") + "</div>" +
        "</div>"
      );
    })
    .join("");
  container.scrollTop = container.scrollHeight;
}

function escapeHtml(text) {
  var div = document.createElement("div");
  div.textContent = text;
  return div.innerHTML;
}

async function sendChat() {
  var input = document.getElementById("chat-input");
  var btn = document.getElementById("btn-chat");
  var tokens = document.getElementById("chat-tokens");
  var model = getSelectedModel();
  if (!model) { showToast("Select a model first", "error"); return; }
  var text = input.value.trim();
  if (!text && !pendingAttachment) return;

  var content = text;
  if (pendingAttachment) {
    content = (text ? text + "\n\n" : "") + "--- Attached file: " + pendingAttachment.name + " ---\n" + pendingAttachment.content;
    removeAttachment();
  }

  chatHistory.push({ role: "user", content: content });
  input.value = "";
  renderChatMessages();
  btn.disabled = true;
  setStatusBar("chat-status", "THINKING...", "active");

  var mcpUrls = getEnabledMcpUrls();

  try {
    var res = await fetch("/api/ai/chat", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        messages: chatHistory,
        model: model,
        mcpServers: mcpUrls,
      }),
    });
    var data = await res.json();
    if (!res.ok) {
      setStatusBar("chat-status", "ERROR: " + (data.error || "unknown"), "error");
      showToast("Chat error: " + (data.error || "unknown"), "error");
      btn.disabled = false;
      return;
    }

    if (data.toolCalls && data.toolCalls.length > 0) {
      data.toolCalls.forEach(function (tc) {
        chatHistory.push({ role: "tool", content: tc.content || "(tool call)" });
      });
    }

    chatHistory.push({ role: "assistant", content: data.reply });
    renderChatMessages();
    if (tokens) {
      tokens.textContent = data.usage.prompt_tokens + " in / " + data.usage.completion_tokens + " out tokens";
    }
    setStatusBar("chat-status", data.model, "active");
  } catch (e) {
    setStatusBar("chat-status", "ERROR: " + e.message, "error");
    showToast("Chat error: " + e.message, "error");
  }
  btn.disabled = false;
}

var pendingAttachment = null;

function handleFileAttach(input) {
  var file = input.files[0];
  if (!file) return;
  var maxSize = 512 * 1024;
  if (file.size > maxSize) {
    showToast("File too large (max 512 KB)", "error");
    input.value = "";
    return;
  }
  var reader = new FileReader();
  reader.onload = function (e) {
    pendingAttachment = { name: file.name, content: e.target.result };
    var el = document.getElementById("chat-attachment");
    var nameEl = document.getElementById("chat-attachment-name");
    if (el) el.style.display = "flex";
    if (nameEl) nameEl.textContent = file.name;
  };
  reader.readAsText(file);
  input.value = "";
}

function removeAttachment() {
  pendingAttachment = null;
  var el = document.getElementById("chat-attachment");
  if (el) el.style.display = "none";
}

function chatKeydown(e) {
  if (e.key === "Enter" && !e.shiftKey) {
    e.preventDefault();
    sendChat();
  }
}

function clearChat() {
  chatHistory = [];
  renderChatMessages();
  var tokens = document.getElementById("chat-tokens");
  if (tokens) tokens.textContent = "";
  setStatusBar("chat-status", "STANDBY", "");
}

// === Init ===
startPolling();

if (document.getElementById("ai-model")) {
  refreshAiModels();
  refreshMcpServers();
}
