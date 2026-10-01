import os
import time
import threading
import uuid
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone

import requests as http_requests
from flask import Flask, render_template, jsonify, request
from kubernetes import client, config

app = Flask(__name__)

BOOKINFO_URL = os.environ.get(
    "BOOKINFO_URL",
    "http://productpage.bookinfo.svc.cluster.local:9080/productpage",
)
GATUS_URL = os.environ.get("GATUS_URL", "")
BOOKINFO_NS = "bookinfo"

try:
    config.load_incluster_config()
except config.ConfigException:
    config.load_kube_config()

k8s_custom = client.CustomObjectsApi()

tasks = {}


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


# --- Routes ---

@app.route("/")
def index():
    return render_template("index.html", gatus_url=GATUS_URL)


@app.route("/help")
def help_page():
    return render_template("help.html")


@app.route("/api/traffic/bookinfo", methods=["POST"])
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
def stop_traffic(task_id):
    if task_id not in tasks:
        return jsonify({"error": "not found"}), 404
    tasks[task_id]["_stop"] = True
    return jsonify({"status": "stopping"}), 200


# --- Service Mesh Controls ---

@app.route("/api/mesh/traffic-shift", methods=["POST"])
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
def reset_traffic_shift():
    _delete_istio_resource("networking.istio.io", "v1", "virtualservices",
                           BOOKINFO_NS, "reviews")
    _delete_istio_resource("networking.istio.io", "v1", "destinationrules",
                           BOOKINFO_NS, "reviews")
    return jsonify({"status": "reset"})


@app.route("/api/mesh/fault-injection", methods=["POST"])
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
def reset_fault_injection():
    _delete_istio_resource("networking.istio.io", "v1", "virtualservices",
                           BOOKINFO_NS, "ratings")
    _delete_istio_resource("networking.istio.io", "v1", "virtualservices",
                           BOOKINFO_NS, "reviews")
    _delete_istio_resource("networking.istio.io", "v1", "destinationrules",
                           BOOKINFO_NS, "reviews")
    return jsonify({"status": "reset"})


@app.route("/api/mesh/circuit-breaker", methods=["POST"])
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
def reset_circuit_breaker():
    _delete_istio_resource("networking.istio.io", "v1", "destinationrules",
                           BOOKINFO_NS, "reviews")
    return jsonify({"status": "reset"})


@app.route("/api/mesh/timeout", methods=["POST"])
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
def reset_timeout():
    _delete_istio_resource("networking.istio.io", "v1", "virtualservices",
                           BOOKINFO_NS, "reviews")
    _delete_istio_resource("networking.istio.io", "v1", "destinationrules",
                           BOOKINFO_NS, "reviews")
    return jsonify({"status": "reset"})


@app.route("/api/mesh/reset-all", methods=["POST"])
def reset_all_mesh():
    for name in ["reviews", "ratings", "bookinfo"]:
        _delete_istio_resource("networking.istio.io", "v1", "virtualservices",
                               BOOKINFO_NS, name)
    _delete_istio_resource("networking.istio.io", "v1", "destinationrules",
                           BOOKINFO_NS, "reviews")
    return jsonify({"status": "all mesh policies reset"})


@app.route("/api/tasks")
def list_tasks():
    ordered = sorted(tasks.values(), key=lambda t: t["started_at"], reverse=True)
    return jsonify(ordered[:20])


@app.route("/api/tasks/<task_id>")
def get_task(task_id):
    if task_id not in tasks:
        return jsonify({"error": "not found"}), 404
    return jsonify(tasks[task_id])


@app.route("/healthz")
def healthz():
    return "ok"
