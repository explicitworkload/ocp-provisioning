import asyncio
import functools
import json
import os
import time
import threading
import uuid
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone

import requests as http_requests
from flask import Flask, render_template, jsonify, request, session, redirect, url_for
from kubernetes import client, config
from mcp import ClientSession
from mcp.client.sse import sse_client

app = Flask(__name__)
app.secret_key = os.environ.get("SECRET_KEY", os.urandom(32).hex())

BOOKINFO_URL = os.environ.get(
    "BOOKINFO_URL",
    "http://productpage.bookinfo.svc.cluster.local:9080/productpage",
)
GATUS_URL = os.environ.get("GATUS_URL", "")
GATUS_HOST = os.environ.get("GATUS_HOST", "")
DASHBOARD_PASSWORD = os.environ.get("DASHBOARD_PASSWORD", "")
LITELLM_URL = os.environ.get("LITELLM_URL", "http://litellm.litellm.svc.cluster.local:4000")
LITELLM_API_KEY = os.environ.get("LITELLM_API_KEY", "")
BOOKINFO_NS = "bookinfo"
MACHINE_API_NS = "openshift-machine-api"

try:
    config.load_incluster_config()
except config.ConfigException:
    config.load_kube_config()

k8s_custom = client.CustomObjectsApi()
k8s_apps = client.AppsV1Api()
k8s_core = client.CoreV1Api()

tasks = {}


def login_required(f):
    @functools.wraps(f)
    def decorated(*args, **kwargs):
        if not DASHBOARD_PASSWORD:
            return f(*args, **kwargs)
        if not session.get("authenticated"):
            if request.path.startswith("/api/"):
                return jsonify({"error": "unauthorized"}), 401
            return redirect(url_for("login"))
        return f(*args, **kwargs)
    return decorated


def _single_request(url):
    try:
        r = http_requests.get(url, timeout=10, verify=False)
        return r.status_code == 200
    except Exception:
        return False


def _run_traffic(task_id, url, count, concurrency):
    tasks[task_id]["status"] = "running"
    success = 0
    fail = 0
    done = 0
    with ThreadPoolExecutor(max_workers=concurrency) as pool:
        futures = [pool.submit(_single_request, url) for _ in range(count)]
        for f in futures:
            ok = f.result()
            done += 1
            if ok:
                success += 1
            else:
                fail += 1
            tasks[task_id]["progress"] = done
            tasks[task_id]["success"] = success
            tasks[task_id]["fail"] = fail
    tasks[task_id]["status"] = "complete"
    tasks[task_id]["completed_at"] = datetime.now(timezone.utc).isoformat()


def _run_sustained_traffic(task_id, url, duration_secs, concurrency):
    tasks[task_id]["status"] = "running"
    success = 0
    fail = 0
    done = 0
    start = time.monotonic()
    with ThreadPoolExecutor(max_workers=concurrency) as pool:
        while True:
            elapsed = time.monotonic() - start
            if elapsed >= duration_secs or tasks[task_id].get("_stop"):
                break
            tasks[task_id]["elapsed"] = int(elapsed)
            futures = [pool.submit(_single_request, url) for _ in range(concurrency)]
            for f in futures:
                ok = f.result()
                done += 1
                if ok:
                    success += 1
                else:
                    fail += 1
            tasks[task_id]["progress"] = done
            tasks[task_id]["success"] = success
            tasks[task_id]["fail"] = fail
            tasks[task_id]["total"] = done
    tasks[task_id]["elapsed"] = min(int(time.monotonic() - start), duration_secs)
    tasks[task_id]["total"] = done
    tasks[task_id]["status"] = "complete"
    tasks[task_id]["completed_at"] = datetime.now(timezone.utc).isoformat()


# --- Istio resource helpers ---

def _apply_istio_resource(group, version, plural, namespace, name, body):
    try:
        k8s_custom.get_namespaced_custom_object(group, version, namespace, plural, name)
        k8s_custom.patch_namespaced_custom_object(
            group, version, namespace, plural, name, body
        )
    except client.exceptions.ApiException as e:
        if e.status == 404:
            k8s_custom.create_namespaced_custom_object(
                group, version, namespace, plural, body
            )
        else:
            raise


def _delete_istio_resource(group, version, plural, namespace, name):
    try:
        k8s_custom.delete_namespaced_custom_object(
            group, version, namespace, plural, name
        )
    except client.exceptions.ApiException as e:
        if e.status != 404:
            raise


def _get_reviews_virtualservice(weights, fault=None, timeout=None, retries=None):
    routes = []
    for version, weight in weights.items():
        if weight > 0:
            routes.append({
                "destination": {"host": "reviews", "subset": version,
                                "port": {"number": 9080}},
                "weight": weight,
            })

    http_route = {"route": routes}

    if fault:
        http_route["fault"] = fault
    if timeout:
        http_route["timeout"] = timeout
    if retries:
        http_route["retries"] = retries

    return {
        "apiVersion": "networking.istio.io/v1",
        "kind": "VirtualService",
        "metadata": {"name": "reviews", "namespace": BOOKINFO_NS},
        "spec": {
            "hosts": ["reviews"],
            "http": [http_route],
        },
    }


def _get_reviews_destination_rule(circuit_breaker=None):
    dr = {
        "apiVersion": "networking.istio.io/v1",
        "kind": "DestinationRule",
        "metadata": {"name": "reviews", "namespace": BOOKINFO_NS},
        "spec": {
            "host": "reviews",
            "subsets": [
                {"name": "v1", "labels": {"version": "v1"}},
                {"name": "v2", "labels": {"version": "v2"}},
                {"name": "v3", "labels": {"version": "v3"}},
            ],
        },
    }
    if circuit_breaker:
        dr["spec"]["trafficPolicy"] = {
            "connectionPool": {
                "tcp": {"maxConnections": circuit_breaker.get("maxConnections", 1)},
                "http": {
                    "http1MaxPendingRequests": circuit_breaker.get("maxPendingRequests", 1),
                    "http2MaxRequests": circuit_breaker.get("maxRequests", 1),
                    "maxRequestsPerConnection": circuit_breaker.get("maxRequestsPerConnection", 1),
                },
            },
            "outlierDetection": {
                "consecutive5xxErrors": circuit_breaker.get("consecutiveErrors", 1),
                "interval": circuit_breaker.get("interval", "5s"),
                "baseEjectionTime": circuit_breaker.get("baseEjectionTime", "30s"),
                "maxEjectionPercent": circuit_breaker.get("maxEjectionPercent", 100),
            },
        }
    return dr


def _get_ratings_virtualservice(fault=None):
    http_route = {
        "route": [{"destination": {"host": "ratings", "port": {"number": 9080}}}]
    }
    if fault:
        http_route["fault"] = fault
    return {
        "apiVersion": "networking.istio.io/v1",
        "kind": "VirtualService",
        "metadata": {"name": "ratings", "namespace": BOOKINFO_NS},
        "spec": {
            "hosts": ["ratings"],
            "http": [http_route],
        },
    }


# --- Auth Routes ---

@app.route("/login", methods=["GET", "POST"])
def login():
    if not DASHBOARD_PASSWORD:
        return redirect(url_for("index"))
    if request.method == "POST":
        password = request.form.get("password", "")
        if password == DASHBOARD_PASSWORD:
            session["authenticated"] = True
            return redirect(url_for("index"))
        return render_template("login.html", error="Invalid password")
    return render_template("login.html")


@app.route("/logout")
def logout():
    session.clear()
    return redirect(url_for("login"))


# --- Routes ---

@app.route("/")
@login_required
def index():
    return render_template("index.html", gatus_url=GATUS_URL, gatus_host=GATUS_HOST, active_page="dashboard")


@app.route("/platform")
@login_required
def platform_page():
    return render_template("platform.html", gatus_host=GATUS_HOST, active_page="platform")


@app.route("/ai")
@login_required
def ai_page():
    return render_template("ai.html", gatus_host=GATUS_HOST, active_page="ai")


@app.route("/help")
@login_required
def help_page():
    return render_template("help.html", gatus_host=GATUS_HOST, active_page="help")


@app.route("/api/traffic/bookinfo", methods=["POST"])
@login_required
def generate_bookinfo_traffic():
    body = request.get_json(silent=True) or {}
    concurrency = max(1, min(int(body.get("concurrency", 10)), 50))
    duration_minutes = body.get("duration")

    task_id = str(uuid.uuid4())[:8]

    if duration_minutes:
        duration_secs = max(1, min(int(float(duration_minutes) * 60), 3600))
        tasks[task_id] = {
            "id": task_id,
            "type": "sustained-traffic",
            "status": "queued",
            "total": 0,
            "progress": 0,
            "success": 0,
            "fail": 0,
            "concurrency": concurrency,
            "duration": duration_secs,
            "elapsed": 0,
            "started_at": datetime.now(timezone.utc).isoformat(),
            "completed_at": None,
        }
        t = threading.Thread(
            target=_run_sustained_traffic,
            args=(task_id, BOOKINFO_URL, duration_secs, concurrency),
        )
    else:
        count = min(int(body.get("count", 100)), 10000)
        tasks[task_id] = {
            "id": task_id,
            "type": "bookinfo-traffic",
            "status": "queued",
            "total": count,
            "progress": 0,
            "success": 0,
            "fail": 0,
            "concurrency": concurrency,
            "started_at": datetime.now(timezone.utc).isoformat(),
            "completed_at": None,
        }
        t = threading.Thread(
            target=_run_traffic, args=(task_id, BOOKINFO_URL, count, concurrency)
        )

    t.daemon = True
    t.start()
    return jsonify(tasks[task_id]), 202


@app.route("/api/traffic/stop/<task_id>", methods=["POST"])
@login_required
def stop_traffic(task_id):
    if task_id not in tasks:
        return jsonify({"error": "not found"}), 404
    tasks[task_id]["_stop"] = True
    return jsonify({"status": "stopping"}), 200


# --- Service Mesh Controls ---

@app.route("/api/mesh/traffic-shift", methods=["POST"])
@login_required
def traffic_shift():
    body = request.get_json(silent=True) or {}
    v1 = int(body.get("v1", 34))
    v2 = int(body.get("v2", 33))
    v3 = int(body.get("v3", 33))
    total = v1 + v2 + v3
    if total != 100:
        return jsonify({"error": f"weights must sum to 100, got {total}"}), 400

    dr = _get_reviews_destination_rule()
    _apply_istio_resource("networking.istio.io", "v1", "destinationrules",
                          BOOKINFO_NS, "reviews", dr)

    vs = _get_reviews_virtualservice({"v1": v1, "v2": v2, "v3": v3})
    _apply_istio_resource("networking.istio.io", "v1", "virtualservices",
                          BOOKINFO_NS, "reviews", vs)

    return jsonify({"status": "applied", "weights": {"v1": v1, "v2": v2, "v3": v3}})


@app.route("/api/mesh/traffic-shift", methods=["DELETE"])
@login_required
def reset_traffic_shift():
    _delete_istio_resource("networking.istio.io", "v1", "virtualservices",
                           BOOKINFO_NS, "reviews")
    _delete_istio_resource("networking.istio.io", "v1", "destinationrules",
                           BOOKINFO_NS, "reviews")
    return jsonify({"status": "reset"})


@app.route("/api/mesh/fault-injection", methods=["POST"])
@login_required
def fault_injection():
    body = request.get_json(silent=True) or {}
    fault_type = body.get("type", "delay")
    target = body.get("target", "ratings")
    percentage = int(body.get("percentage", 100))

    fault = {}
    if fault_type == "delay":
        delay_ms = int(body.get("delay_ms", 5000))
        fault["delay"] = {
            "fixedDelay": f"{delay_ms}ms",
            "percentage": {"value": percentage},
        }
    elif fault_type == "abort":
        status_code = int(body.get("status_code", 500))
        fault["abort"] = {
            "httpStatus": status_code,
            "percentage": {"value": percentage},
        }

    if target == "ratings":
        vs = _get_ratings_virtualservice(fault=fault)
        _apply_istio_resource("networking.istio.io", "v1", "virtualservices",
                              BOOKINFO_NS, "ratings", vs)
    elif target == "reviews":
        vs = _get_reviews_virtualservice(
            {"v1": 34, "v2": 33, "v3": 33}, fault=fault
        )
        dr = _get_reviews_destination_rule()
        _apply_istio_resource("networking.istio.io", "v1", "destinationrules",
                              BOOKINFO_NS, "reviews", dr)
        _apply_istio_resource("networking.istio.io", "v1", "virtualservices",
                              BOOKINFO_NS, "reviews", vs)

    return jsonify({"status": "applied", "target": target, "fault": fault})


@app.route("/api/mesh/fault-injection", methods=["DELETE"])
@login_required
def reset_fault_injection():
    _delete_istio_resource("networking.istio.io", "v1", "virtualservices",
                           BOOKINFO_NS, "ratings")
    _delete_istio_resource("networking.istio.io", "v1", "virtualservices",
                           BOOKINFO_NS, "reviews")
    _delete_istio_resource("networking.istio.io", "v1", "destinationrules",
                           BOOKINFO_NS, "reviews")
    return jsonify({"status": "reset"})


@app.route("/api/mesh/circuit-breaker", methods=["POST"])
@login_required
def circuit_breaker():
    body = request.get_json(silent=True) or {}
    cb_config = {
        "maxConnections": int(body.get("maxConnections", 1)),
        "maxPendingRequests": int(body.get("maxPendingRequests", 1)),
        "maxRequests": int(body.get("maxRequests", 1)),
        "maxRequestsPerConnection": int(body.get("maxRequestsPerConnection", 1)),
        "consecutiveErrors": int(body.get("consecutiveErrors", 1)),
        "interval": body.get("interval", "5s"),
        "baseEjectionTime": body.get("baseEjectionTime", "30s"),
        "maxEjectionPercent": int(body.get("maxEjectionPercent", 100)),
    }
    dr = _get_reviews_destination_rule(circuit_breaker=cb_config)
    _apply_istio_resource("networking.istio.io", "v1", "destinationrules",
                          BOOKINFO_NS, "reviews", dr)
    return jsonify({"status": "applied", "config": cb_config})


@app.route("/api/mesh/circuit-breaker", methods=["DELETE"])
@login_required
def reset_circuit_breaker():
    _delete_istio_resource("networking.istio.io", "v1", "destinationrules",
                           BOOKINFO_NS, "reviews")
    return jsonify({"status": "reset"})


@app.route("/api/mesh/timeout", methods=["POST"])
@login_required
def request_timeout():
    body = request.get_json(silent=True) or {}
    timeout_s = body.get("timeout", "3s")
    retries_attempts = int(body.get("retries", 2))
    retry_timeout = body.get("retryTimeout", "2s")

    dr = _get_reviews_destination_rule()
    _apply_istio_resource("networking.istio.io", "v1", "destinationrules",
                          BOOKINFO_NS, "reviews", dr)

    vs = _get_reviews_virtualservice(
        {"v1": 34, "v2": 33, "v3": 33},
        timeout=timeout_s,
        retries={"attempts": retries_attempts, "perTryTimeout": retry_timeout},
    )
    _apply_istio_resource("networking.istio.io", "v1", "virtualservices",
                          BOOKINFO_NS, "reviews", vs)
    return jsonify({
        "status": "applied",
        "timeout": timeout_s,
        "retries": retries_attempts,
        "retryTimeout": retry_timeout,
    })


@app.route("/api/mesh/timeout", methods=["DELETE"])
@login_required
def reset_timeout():
    _delete_istio_resource("networking.istio.io", "v1", "virtualservices",
                           BOOKINFO_NS, "reviews")
    _delete_istio_resource("networking.istio.io", "v1", "destinationrules",
                           BOOKINFO_NS, "reviews")
    return jsonify({"status": "reset"})


@app.route("/api/mesh/reset-all", methods=["POST"])
@login_required
def reset_all_mesh():
    for name in ["reviews", "ratings"]:
        _delete_istio_resource("networking.istio.io", "v1", "virtualservices",
                               BOOKINFO_NS, name)
    _delete_istio_resource("networking.istio.io", "v1", "destinationrules",
                           BOOKINFO_NS, "reviews")
    return jsonify({"status": "all mesh policies reset"})


@app.route("/api/tasks")
@login_required
def list_tasks():
    ordered = sorted(tasks.values(), key=lambda t: t["started_at"], reverse=True)
    return jsonify(ordered[:20])


@app.route("/api/tasks/<task_id>")
@login_required
def get_task(task_id):
    if task_id not in tasks:
        return jsonify({"error": "not found"}), 404
    return jsonify(tasks[task_id])


# --- Platform Admin ---

def _get_machinesets():
    ms_list = k8s_custom.list_namespaced_custom_object(
        "machine.openshift.io", "v1beta1", MACHINE_API_NS, "machinesets"
    )
    results = []
    for ms in ms_list.get("items", []):
        name = ms["metadata"]["name"]
        spec_replicas = ms["spec"].get("replicas", 0)
        ready = (ms.get("status") or {}).get("readyReplicas", 0)
        instance_type = (
            ms.get("spec", {})
            .get("template", {})
            .get("spec", {})
            .get("providerSpec", {})
            .get("value", {})
            .get("instanceType", "unknown")
        )
        is_gpu = any(
            g in name for g in ["g4dn", "g6e", "p4d", "p4de", "p5", "g5"]
        )
        results.append({
            "name": name,
            "replicas": spec_replicas,
            "ready": ready,
            "instanceType": instance_type,
            "isGpu": is_gpu,
        })
    return results


@app.route("/api/platform/status")
@login_required
def platform_status():
    try:
        machinesets = _get_machinesets()
        nodes = k8s_core.list_node()
        node_summary = []
        for n in nodes.items:
            labels = n.metadata.labels or {}
            roles = [
                k.split("/")[1]
                for k in labels
                if k.startswith("node-role.kubernetes.io/")
            ]
            ready = any(
                c.type == "Ready" and c.status == "True"
                for c in (n.status.conditions or [])
            )
            node_summary.append({
                "name": n.metadata.name,
                "roles": roles,
                "ready": ready,
            })
        return jsonify({"machinesets": machinesets, "nodes": node_summary})
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/api/platform/scale", methods=["POST"])
@login_required
def platform_scale():
    body = request.get_json(silent=True) or {}
    ms_name = body.get("machineset", "")
    replicas = body.get("replicas")
    if replicas is None or not ms_name:
        return jsonify({"error": "machineset and replicas required"}), 400
    replicas = max(0, min(int(replicas), 10))
    try:
        k8s_custom.patch_namespaced_custom_object(
            "machine.openshift.io", "v1beta1", MACHINE_API_NS,
            "machinesets", ms_name,
            {"spec": {"replicas": replicas}},
        )
        return jsonify({"status": "scaled", "machineset": ms_name, "replicas": replicas})
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/api/platform/shutdown", methods=["POST"])
@login_required
def platform_shutdown():
    try:
        machinesets = _get_machinesets()
        scaled = []
        for ms in machinesets:
            if ms["replicas"] > 0:
                k8s_custom.patch_namespaced_custom_object(
                    "machine.openshift.io", "v1beta1", MACHINE_API_NS,
                    "machinesets", ms["name"],
                    {"spec": {"replicas": 0}},
                )
                scaled.append(ms["name"])

        nodes = k8s_core.list_node()
        for n in nodes.items:
            try:
                k8s_core.patch_node(
                    n.metadata.name,
                    {"spec": {"unschedulable": True}},
                )
            except Exception:
                pass

        return jsonify({
            "status": "graceful shutdown initiated",
            "scaled": scaled,
            "cordoned": [n.metadata.name for n in nodes.items],
        })
    except Exception as e:
        return jsonify({"error": str(e)}), 500


# --- AI ---

def _run_async(coro):
    loop = asyncio.new_event_loop()
    try:
        return loop.run_until_complete(coro)
    finally:
        loop.close()


async def _mcp_list_tools(server_url):
    async with sse_client(server_url) as (read_stream, write_stream):
        async with ClientSession(read_stream, write_stream) as sess:
            await sess.initialize()
            result = await sess.list_tools()
            return [
                {
                    "name": t.name,
                    "description": t.description or "",
                    "inputSchema": t.inputSchema if hasattr(t, "inputSchema") else {},
                }
                for t in result.tools
            ]


async def _mcp_call_tool(server_url, tool_name, arguments):
    async with sse_client(server_url) as (read_stream, write_stream):
        async with ClientSession(read_stream, write_stream) as sess:
            await sess.initialize()
            result = await sess.call_tool(tool_name, arguments)
            parts = []
            for c in result.content:
                if hasattr(c, "text"):
                    parts.append(c.text)
                else:
                    parts.append(str(c))
            return "\n".join(parts)


def _llm_headers():
    headers = {"Content-Type": "application/json"}
    if LITELLM_API_KEY:
        headers["Authorization"] = f"Bearer {LITELLM_API_KEY}"
    return headers


def _mcp_tools_to_openai(mcp_tools):
    result = []
    for t in mcp_tools:
        schema = t.get("inputSchema", {})
        if not schema:
            schema = {"type": "object", "properties": {}}
        result.append({
            "type": "function",
            "function": {
                "name": t["name"],
                "description": t.get("description", ""),
                "parameters": schema,
            },
        })
    return result


@app.route("/api/ai/mcp-servers")
@login_required
def ai_mcp_servers():
    try:
        servers = k8s_custom.list_custom_object_for_all_namespaces(
            "mcp.x-k8s.io", "v1alpha1", "mcpservers"
        )
        results = []
        for s in servers.get("items", []):
            name = s["metadata"]["name"]
            ns = s["metadata"]["namespace"]
            phase = (s.get("status") or {}).get("phase", "Unknown")
            for cond in (s.get("status") or {}).get("conditions", []):
                if cond.get("type") == "Ready" and cond.get("status") == "True":
                    phase = "Ready"
            url = (s.get("status") or {}).get("connection", {}).get("url", "")
            results.append({
                "name": name,
                "namespace": ns,
                "phase": phase,
                "url": url,
            })
        return jsonify({"servers": results})
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/api/ai/mcp-servers/<namespace>/<name>/tools")
@login_required
def ai_mcp_tools(namespace, name):
    try:
        srv = k8s_custom.get_namespaced_custom_object(
            "mcp.x-k8s.io", "v1alpha1", namespace, "mcpservers", name
        )
        url = (srv.get("status") or {}).get("connection", {}).get("url", "")
        if not url:
            return jsonify({"error": "MCP server has no connection URL"}), 400
        tools = _run_async(_mcp_list_tools(url))
        return jsonify({"tools": tools, "url": url})
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/api/ai/models")
@login_required
def ai_models():
    try:
        r = http_requests.get(
            f"{LITELLM_URL}/v1/models", headers=_llm_headers(), timeout=10
        )
        r.raise_for_status()
        models = r.json().get("data", [])
        return jsonify({"models": [m["id"] for m in models]})
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/api/ai/summarize", methods=["POST"])
@login_required
def ai_summarize():
    body = request.get_json(silent=True) or {}
    text = body.get("text", "").strip()
    model = body.get("model", "")
    if not text:
        return jsonify({"error": "text is required"}), 400
    if not model:
        return jsonify({"error": "model is required"}), 400

    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": "You are a helpful assistant. Summarize the following text concisely. Return only the summary, no preamble."},
            {"role": "user", "content": text},
        ],
        "temperature": 0.3,
        "max_tokens": 1024,
    }

    try:
        r = http_requests.post(
            f"{LITELLM_URL}/v1/chat/completions",
            headers=_llm_headers(), json=payload, timeout=60,
        )
        r.raise_for_status()
        data = r.json()
        summary = data["choices"][0]["message"]["content"]
        usage = data.get("usage", {})
        return jsonify({
            "summary": summary,
            "model": data.get("model", model),
            "usage": {
                "prompt_tokens": usage.get("prompt_tokens", 0),
                "completion_tokens": usage.get("completion_tokens", 0),
            },
        })
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/api/ai/chat", methods=["POST"])
@login_required
def ai_chat():
    body = request.get_json(silent=True) or {}
    messages = body.get("messages", [])
    model = body.get("model", "")
    mcp_server_urls = body.get("mcpServers", [])
    if not messages:
        return jsonify({"error": "messages is required"}), 400
    if not model:
        return jsonify({"error": "model is required"}), 400

    all_mcp_tools = []
    tool_server_map = {}
    for srv_url in mcp_server_urls:
        try:
            tools = _run_async(_mcp_list_tools(srv_url))
            all_mcp_tools.extend(tools)
            for t in tools:
                tool_server_map[t["name"]] = srv_url
        except Exception:
            pass

    payload = {
        "model": model,
        "messages": list(messages),
        "temperature": 0.7,
        "max_tokens": 2048,
    }

    if all_mcp_tools:
        payload["tools"] = _mcp_tools_to_openai(all_mcp_tools)

    try:
        max_rounds = 5
        for _ in range(max_rounds):
            r = http_requests.post(
                f"{LITELLM_URL}/v1/chat/completions",
                headers=_llm_headers(), json=payload, timeout=120,
            )
            r.raise_for_status()
            data = r.json()
            choice = data["choices"][0]
            msg = choice["message"]

            if choice.get("finish_reason") != "tool_calls" and not msg.get("tool_calls"):
                usage = data.get("usage", {})
                return jsonify({
                    "reply": msg.get("content", ""),
                    "model": data.get("model", model),
                    "toolCalls": [
                        m for m in payload["messages"]
                        if m.get("role") == "tool"
                    ],
                    "usage": {
                        "prompt_tokens": usage.get("prompt_tokens", 0),
                        "completion_tokens": usage.get("completion_tokens", 0),
                    },
                })

            payload["messages"].append(msg)

            for tc in msg.get("tool_calls", []):
                fn_name = tc["function"]["name"]
                fn_args = json.loads(tc["function"]["arguments"] or "{}")
                srv_url = tool_server_map.get(fn_name, "")

                if srv_url:
                    try:
                        result = _run_async(_mcp_call_tool(srv_url, fn_name, fn_args))
                    except Exception as e:
                        result = f"Error calling tool: {e}"
                else:
                    result = f"Unknown tool: {fn_name}"

                payload["messages"].append({
                    "role": "tool",
                    "tool_call_id": tc["id"],
                    "content": result,
                })

        usage = data.get("usage", {})
        return jsonify({
            "reply": msg.get("content", "") or "(tool call loop reached max rounds)",
            "model": data.get("model", model),
            "usage": {
                "prompt_tokens": usage.get("prompt_tokens", 0),
                "completion_tokens": usage.get("completion_tokens", 0),
            },
        })
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/healthz")
def healthz():
    return "ok"
