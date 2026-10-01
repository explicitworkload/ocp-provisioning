import os
import threading
import uuid
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone

import requests as http_requests
from flask import Flask, render_template, jsonify, request

app = Flask(__name__)

BOOKINFO_URL = os.environ.get(
    "BOOKINFO_URL",
    "http://productpage.bookinfo.svc.cluster.local:9080/productpage",
)
GATUS_URL = os.environ.get("GATUS_URL", "")

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
        for f in as_completed(futures):
            done += 1
            if f.result():
                success += 1
            else:
                fail += 1
            tasks[task_id]["progress"] = done
            tasks[task_id]["success"] = success
            tasks[task_id]["fail"] = fail
    tasks[task_id]["status"] = "complete"
    tasks[task_id]["completed_at"] = datetime.now(timezone.utc).isoformat()


@app.route("/")
def index():
    return render_template("index.html", gatus_url=GATUS_URL)


@app.route("/api/traffic/bookinfo", methods=["POST"])
def generate_bookinfo_traffic():
    body = request.get_json(silent=True) or {}
    count = min(int(body.get("count", 100)), 10000)
    concurrency = max(1, min(int(body.get("concurrency", 1)), 50))
    task_id = str(uuid.uuid4())[:8]
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
    t = threading.Thread(target=_run_traffic, args=(task_id, BOOKINFO_URL, count, concurrency))
    t.daemon = True
    t.start()
    return jsonify(tasks[task_id]), 202


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
