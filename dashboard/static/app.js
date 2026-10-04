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
var taskPanelCollapsed = true;

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
      // Reflect server state in the controls. Without this a page refresh
      // during a sustained run left Stop hidden and the start buttons live,
      // so the task could not be stopped and a second one could be queued.
      if (btnBurst) btnBurst.disabled = true;
      if (btnSustained) btnSustained.disabled = true;
      if (btnStop) btnStop.style.display = activeSustained ? "inline-flex" : "none";

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

// Toggle only the state classes. Overwriting className here used to wipe the
// element's own class, which forced every status onto card-footer styling
// regardless of where it was placed.
function setStatusBar(id, text, type) {
  var el = document.getElementById(id);
  if (!el) return;
  el.textContent = text;
  el.classList.remove("active", "error");
  if (type) el.classList.add(type);
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
      var detail = [];
      if (n.phase) detail.push(n.phase);
      if (n.ec2State) detail.push(n.ec2State);
      var select = n.isMaster
        ? '<span class="node-guard" title="Control-plane node — protected">&#8212;</span>'
        : '<input type="checkbox" class="node-pick" value="' + escapeHtml(n.name) + '">';
      return (
        '<div class="node-row">' +
        select +
        '<div class="node-status ' + statusClass + '"></div>' +
        '<span class="node-name">' + escapeHtml(n.name) + "</span>" +
        '<span class="node-roles">' + n.roles.join(", ") + "</span>" +
        '<span class="node-detail">' + detail.join(" / ") + "</span>" +
        "</div>"
      );
    })
    .join("");
}

function selectedNodes() {
  return Array.prototype.slice
    .call(document.querySelectorAll(".node-pick:checked"))
    .map(function (el) { return el.value; });
}

async function nodeAction(action) {
  var nodes = selectedNodes();
  if (!nodes.length) {
    showToast("Select one or two worker nodes first", "info");
    return;
  }
  if (nodes.length > 2) {
    showToast("At most two nodes at a time", "error");
    return;
  }
  var prompts = {
    stop: "Stop the EC2 instance(s) for:\n\n" + nodes.join("\n") +
      "\n\nThe node goes NotReady and its workloads reschedule. Start it again to recover.",
    start: "Start the EC2 instance(s) for:\n\n" + nodes.join("\n"),
    destroy: "DESTROY:\n\n" + nodes.join("\n") +
      "\n\nThe Machine is deleted and its MachineSet provisions a replacement. " +
      "This is irreversible for the current instance.",
  };
  if (!confirm(prompts[action])) return;

  var labels = { stop: "STOPPING", start: "STARTING", destroy: "DESTROYING" };
  setStatusBar("platform-status", labels[action] + " " + nodes.length + " NODE(S)...", "active");
  try {
    var res = await fetch("/api/platform/node/" + action, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ nodes: nodes }),
    });
    var data = await res.json();
    if (res.ok) {
      setStatusBar("platform-status", labels[action] + " REQUESTED — " + nodes.join(", "), "active");
      showToast(action + " requested for " + nodes.join(", "), "success");
      addPlatformTask(action, action + " — " + nodes.join(", "));
      setTimeout(refreshPlatform, 5000);
    } else {
      setStatusBar("platform-status", "ERROR: " + data.error, "error");
      showToast(action + " error: " + data.error, "error");
      addPlatformTask(action + "-error", "Failed to " + action + " " + nodes.join(", "));
    }
  } catch (e) {
    setStatusBar("platform-status", "ERROR: " + e.message, "error");
    showToast(action + " error: " + e.message, "error");
  }
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
// Which MCP servers the user has switched on. Persisted so the choice
// survives a reload — it previously lived only in memory, so every refresh
// silently dropped the model's tools.
var MCP_STORAGE_KEY = "opsDashboard.enabledMcpServers";

function loadEnabledMcpServers() {
  try {
    return JSON.parse(localStorage.getItem(MCP_STORAGE_KEY)) || {};
  } catch (_) {
    return {};
  }
}

function saveEnabledMcpServers() {
  try {
    localStorage.setItem(MCP_STORAGE_KEY, JSON.stringify(enabledMcpServers));
  } catch (_) { /* private browsing or quota — not worth failing over */ }
}

var enabledMcpServers = loadEnabledMcpServers();

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
    var healthyCount = 0;
    data.models.forEach(function (m) {
      var opt = document.createElement("option");
      opt.value = m.id;
      opt.textContent = m.id + (m.healthy ? "" : " (unavailable)");
      if (!m.healthy) {
        opt.style.color = "#f87171";
        opt.disabled = true;
      } else {
        healthyCount++;
      }
      select.appendChild(opt);
    });
    if (healthyCount === 0) {
      setStatusBar("ai-model-status", data.models.length + " MODEL(S) — ALL UNAVAILABLE", "error");
    } else {
      var firstHealthy = data.models.find(function (m) { return m.healthy; });
      if (firstHealthy) select.value = firstHealthy.id;
      setStatusBar("ai-model-status", healthyCount + "/" + data.models.length + " MODEL(S) AVAILABLE", "active");
    }
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

    // Re-verify anything restored from storage: the server may have gone away
    // or its URL changed since, and a stale entry would be sent to the model.
    data.servers.forEach(function (s) {
      var key = s.namespace + "/" + s.name;
      if (!enabledMcpServers[key]) return;
      var toolsEl = document.getElementById("mcp-tools-" + key.replace("/", "-"));
      if (toolsEl) toolsEl.textContent = "reconnecting...";
      fetch("/api/ai/mcp-servers/" + s.namespace + "/" + s.name + "/tools")
        .then(function (r) { return r.ok ? r.json() : Promise.reject(r); })
        .then(function (d) {
          enabledMcpServers[key] = {url: d.url, tools: d.tools};
          saveEnabledMcpServers();
          if (toolsEl) toolsEl.textContent = d.tools.length + " tools";
        })
        .catch(function () {
          delete enabledMcpServers[key];
          saveEnabledMcpServers();
          var t = document.getElementById("mcp-toggle-" + key.replace("/", "-"));
          if (t) t.classList.remove("active");
          if (toolsEl) toolsEl.textContent = "unavailable";
        });
    });
  } catch (e) {
    setStatusBar("mcp-status", "ERROR: " + e.message, "error");
  }
}

async function toggleMcpServer(key, namespace, name) {
  var toggleEl = document.getElementById("mcp-toggle-" + key.replace("/", "-"));
  var toolsEl = document.getElementById("mcp-tools-" + key.replace("/", "-"));

  if (enabledMcpServers[key]) {
    delete enabledMcpServers[key];
    saveEnabledMcpServers();
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
    saveEnabledMcpServers();
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
  // Only pin to the bottom if the reader is already there, so scrolling back
  // through history is not yanked away on every streamed delta.
  var stick = container.scrollHeight - container.scrollTop - container.clientHeight < 80;

  container.innerHTML = chatHistory
    .filter(function (m) { return m.role !== "system"; })
    .map(function (m) {
      var cls = m.role === "user" ? "user" : m.role === "tool" ? "tool-result" : "assistant";
      if (m.streaming) cls += " streaming";
      var roleLabel = m.role.toUpperCase();
      var body = m.role === "user"
        ? escapeHtml(m.content || "")
        : m.role === "tool"
          ? renderToolResult(m)
          : renderAssistant(m.content || "");
      return (
        '<div class="chat-msg ' + cls + '">' +
        (m.role === "tool" ? "" : '<div class="chat-msg-role">' + roleLabel + "</div>") +
        '<div>' + body + "</div>" +
        renderMetrics(m.metrics) +
        "</div>"
      );
    })
    .join("");

  // A still-growing reasoning block is uncapped, so keep its tail in view too.
  var liveThink = container.querySelector(".chat-msg.streaming .chat-think-body");
  if (liveThink) liveThink.scrollTop = liveThink.scrollHeight;
  if (stick) container.scrollTop = container.scrollHeight;
}

function escapeHtml(text) {
  var div = document.createElement("div");
  div.textContent = text;
  return div.innerHTML;
}

// Tool output is raw cluster data and can run to thousands of lines. Fold it
// so the model's answer stays readable, but keep it one click away.
function renderToolResult(m) {
  var text = m.content || "";
  var size = text.length > 1200
    ? Math.round(text.length / 1000) + "k chars"
    : text.length + " chars";
  return (
    '<details class="chat-tool">' +
    "<summary>Tool result &middot; " + escapeHtml(m.name || "tool") +
    " &middot; " + size + "</summary>" +
    '<div class="chat-tool-body">' + escapeHtml(text) + "</div>" +
    "</details>"
  );
}

function renderMetrics(mx) {
  if (!mx) return "";
  function stat(label, value, title) {
    return (
      '<span class="chat-metric"' + (title ? ' title="' + title + '"' : "") + ">" +
      '<span class="chat-metric-k">' + label + "</span>" +
      escapeHtml(String(value)) +
      "</span>"
    );
  }
  var items = [];
  if (mx.ttftMs !== null && mx.ttftMs !== undefined) {
    items.push(stat("TTFT", (mx.ttftMs / 1000).toFixed(2) + "s",
      "Time to first token. Reasoning counts — for a thinking model this is the opening <think>, not visible text."));
  }
  // Only worth showing when reasoning delayed visible text enough to notice.
  if (mx.ttfoMs !== null && mx.ttfoMs !== undefined && mx.ttftMs !== null &&
      mx.ttfoMs - mx.ttftMs > 50) {
    items.push(stat("TTFO", (mx.ttfoMs / 1000).toFixed(2) + "s",
      "Time to first visible output, after the reasoning block closed"));
  }
  items.push(stat("", (mx.completionTokens || 0) + " tokens", "Completion tokens"));
  items.push(stat("", (mx.tokensPerSec || 0) + " T/s",
    "Decode throughput, measured from the first token so prefill is excluded"));
  items.push(stat("", (mx.promptTokens || 0) + " prompt", "Prompt tokens"));
  items.push(stat("", ((mx.totalMs || 0) / 1000).toFixed(1) + "s", "Total wall clock"));
  if (mx.costUsd > 0) items.push(stat("cost", "$" + mx.costUsd.toFixed(6), "Reported by LiteLLM"));
  if (mx.rounds > 1) items.push(stat("rounds", mx.rounds, "LLM calls including tool-call follow-ups"));
  if (mx.toolCalls > 0) items.push(stat("tools", mx.toolCalls, "MCP tool invocations"));
  return '<div class="chat-metrics">' + items.join("") + "</div>";
}

// Reasoning models (qwen3 and friends) emit their scratchpad in <think> tags.
// Split it off so the answer leads and the reasoning is available but folded.
function splitThinking(text) {
  var src = text || "";
  var reasoning = [];
  var answer = src.replace(/<think>([\s\S]*?)<\/think>/gi, function (_m, inner) {
    reasoning.push(inner.trim());
    return "";
  });
  // A block left open means the reply was cut off mid-thought.
  var open = answer.match(/<think>([\s\S]*)$/i);
  if (open) {
    reasoning.push(open[1].trim());
    answer = answer.slice(0, open.index);
  }
  return {
    reasoning: reasoning.join("\n\n").trim(),
    answer: answer.trim(),
  };
}

function renderAssistant(content) {
  var parts = splitThinking(content);
  if (!parts.reasoning) return renderMarkdown(content || "");
  // With no answer the model only ever produced reasoning, so show it.
  var openAttr = parts.answer ? "" : " open";
  var words = parts.reasoning.split(/\s+/).length;
  return (
    '<details class="chat-think"' + openAttr + ">" +
    "<summary>Reasoning &middot; " + words + " words</summary>" +
    '<div class="chat-think-body">' + renderMarkdown(parts.reasoning) + "</div>" +
    "</details>" +
    (parts.answer ? '<div class="chat-answer">' + renderMarkdown(parts.answer) + "</div>" : "")
  );
}

function renderMarkdown(text) {
  var html = escapeHtml(text);
  html = html.replace(/```([\s\S]*?)```/g, '<pre class="chat-code-block">$1</pre>');
  html = html.replace(/`([^`]+)`/g, '<code class="chat-code-inline">$1</code>');
  html = html.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
  html = html.replace(/(?<!\*)\*([^*]+)\*(?!\*)/g, '<em>$1</em>');
  html = html.replace(/^(\d+)\.\s/gm, '<span class="chat-list-num">$1.</span> ');
  html = html.replace(/^[-•]\s/gm, '<span class="chat-list-num">•</span> ');
  return html;
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
    var stats = { startTime: performance.now(), firstTokenTime: null, firstOutputTime: null, deltas: 0 };

    var res = await fetch("/api/ai/chat", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        messages: chatHistory,
        model: model,
        mcpServers: mcpUrls,
      }),
    });

    if (!res.ok || !res.body) {
      var errText = "unknown";
      try { errText = (await res.json()).error || errText; } catch (_) {}
      setStatusBar("chat-status", "ERROR: " + errText, "error");
      showToast("Chat error: " + errText, "error");
      btn.disabled = false;
      return;
    }

    // Placeholder the stream writes into, so text paints as it arrives.
    var live = { role: "assistant", content: "", streaming: true };
    chatHistory.push(live);
    renderChatMessages();

    var reader = res.body.getReader();
    var decoder = new TextDecoder();
    var buffer = "";
    var finalPayload = null;
    var streamError = null;

    function handleEvent(name, payload) {
      if (name === "delta") {
        // Reasoning counts: for a thinking model the first token is the
        // opening <think>, not visible prose. TTFO tracks the latter.
        var piece = payload.reasoning || payload.content || "";
        if (!piece) return;
        if (stats.firstTokenTime === null) stats.firstTokenTime = performance.now();
        stats.deltas += 1;
        live.content += piece;
        if (stats.firstOutputTime === null && splitThinking(live.content).answer) {
          stats.firstOutputTime = performance.now();
        }
        renderChatMessages();
      } else if (name === "tool") {
        if (payload.status === "running") {
          setStatusBar("chat-status", "TOOL: " + payload.name, "active");
        } else {
          chatHistory.splice(chatHistory.length - 1, 0, {
            role: "tool",
            name: payload.name,
            content: payload.result || "(tool call)",
          });
          renderChatMessages();
        }
      } else if (name === "done") {
        finalPayload = payload;
      } else if (name === "error") {
        streamError = payload.error || "stream failed";
      }
    }

    while (true) {
      var step = await reader.read();
      if (step.done) break;
      buffer += decoder.decode(step.value, { stream: true });
      var blocks = buffer.split("\n\n");
      buffer = blocks.pop();
      blocks.forEach(function (block) {
        var name = null, raw = null;
        block.split("\n").forEach(function (l) {
          if (l.indexOf("event: ") === 0) name = l.slice(7).trim();
          else if (l.indexOf("data: ") === 0) raw = l.slice(6);
        });
        if (!name || raw === null) return;
        try { handleEvent(name, JSON.parse(raw)); } catch (_) {}
      });
    }

    if (streamError) {
      setStatusBar("chat-status", "ERROR: " + streamError, "error");
      showToast("Chat error: " + streamError, "error");
      btn.disabled = false;
      return;
    }

    var endTime = performance.now();
    var mx = (finalPayload && finalPayload.metrics) || {};
    // Prefer the server's real usage; delta count is only an approximation
    // because one delta is not reliably one token.
    var outTokens = mx.completionTokens || stats.deltas;
    // Decode throughput: exclude prefill by measuring from the first token.
    var decodeMs = stats.firstTokenTime === null ? 0 : endTime - stats.firstTokenTime;

    live.streaming = false;
    live.content = (finalPayload && finalPayload.reply) || live.content;
    live.metrics = Object.assign({}, mx, {
      ttftMs: stats.firstTokenTime === null ? null : Math.round(stats.firstTokenTime - stats.startTime),
      ttfoMs: stats.firstOutputTime === null ? null : Math.round(stats.firstOutputTime - stats.startTime),
      totalMs: Math.round(endTime - stats.startTime),
      completionTokens: outTokens,
      tokensPerSec: decodeMs > 0 ? Math.round((outTokens / (decodeMs / 1000)) * 10) / 10 : 0,
    });
    renderChatMessages();

    if (tokens) {
      tokens.textContent = (mx.promptTokens || 0) + " in / " + outTokens + " out tokens";
    }
    setStatusBar("chat-status", (finalPayload && finalPayload.model) || model, "active");
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
