"""Register extra model names on LiteLLM that point at models it already serves.

Runs inside the LiteLLM pod, which is the only place the admin API is
reachable without a Route - "oc exec -i ... -- python - '<json>'".

Why this exists: the OpenShell sandbox image from the aicatalyst-team POC
bakes in an opencode.json naming four models from their cluster (gemma-4,
gpt-oss-20b, granite-31-8b-lab-v1, granite-40-h-small). This cluster serves
none of those four, and gemma-4 is the default every session starts on, so
without this the agent gets through the sandbox, through the gateway, and
then 404s on the model - which looks like a broken sandbox.

Each alias is registered as a second model_name over the SAME litellm_params
as the model it points at, so no new upstream route is created. Writes go to
the database (this LiteLLM runs store_model_in_db: true), so nothing needs a
restart.

Idempotent: an alias that already exists is left alone. An alias whose target
is not served is skipped and reported, never invented.
"""

import json
import os
import sys
import urllib.error
import urllib.request

BASE = "http://localhost:4000"


def call(path, key, payload=None):
    req = urllib.request.Request(
        BASE + path,
        headers={
            "Authorization": "Bearer " + key,
            "Content-Type": "application/json",
        },
        data=json.dumps(payload).encode() if payload is not None else None,
        method="POST" if payload is not None else "GET",
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        body = resp.read().decode()
    return json.loads(body) if body.strip() else {}


def main():
    aliases = json.loads(sys.argv[1]) if len(sys.argv) > 1 else {}
    if not aliases:
        print("no aliases requested")
        return 0

    key = os.environ.get("LITELLM_MASTER_KEY", "")
    if not key:
        print("LITELLM_MASTER_KEY is not set in the LiteLLM pod; skipping")
        return 0

    try:
        info = call("/model/info", key)
    except (urllib.error.URLError, OSError) as exc:
        print("could not read the model list: %s" % exc)
        return 0

    # model_name -> litellm_params, first wins. A model group with several
    # deployments is fine; the alias only needs one of them to copy.
    served = {}
    for entry in info.get("data", []):
        name = entry.get("model_name")
        if name and name not in served:
            served[name] = entry.get("litellm_params", {})

    for alias, target in sorted(aliases.items()):
        if alias in served:
            print("exists  %s" % alias)
            continue
        if target not in served:
            print("SKIP    %s -> %s (target not served here)" % (alias, target))
            continue

        params = dict(served[target])
        # model_info carries the old id; dropping it lets LiteLLM mint a new
        # one rather than colliding with the model being cloned.
        params.pop("model_info", None)
        try:
            call("/model/new", key, {"model_name": alias, "litellm_params": params})
            print("created %s -> %s" % (alias, target))
        except (urllib.error.URLError, OSError) as exc:
            print("FAILED  %s -> %s: %s" % (alias, target, exc))

    return 0


if __name__ == "__main__":
    sys.exit(main())
