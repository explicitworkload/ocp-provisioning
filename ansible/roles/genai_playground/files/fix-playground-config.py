#!/usr/bin/env python3
"""Correct the Gen AI BFF's llama-stack config.

    fix-playground-config.py --in BFF.yaml --out FIXED.yaml --params PARAMS.json

Reads the config RHOAI's Gen AI BFF generated, applies the corrections the
genai_playground role exists for, and writes the result. Pure function of
its inputs: no cluster access, so it can be tested on a file.

Every correction below is for a failure observed on a real cluster, not a
tidiness pass. See roles/genai_playground/defaults/main.yml for the list.
"""

import argparse
import json
import sys

try:
    import yaml
except ImportError:
    sys.exit("PyYAML is required")


def dedupe(items, key="provider_id"):
    """First occurrence wins. The BFF appends a provider block per model
    added to the playground and never collapses them - twelve identical
    endpoint-1 entries on sandbox544."""
    seen, out = set(), []
    for it in items or []:
        k = it.get(key)
        if k in seen:
            continue
        seen.add(k)
        out.append(it)
    return out


def fix(cfg, p):
    changes = []
    providers = cfg.setdefault("providers", {})

    # --- drop providers that cannot work ---------------------------------
    inf = providers.get("inference") or []
    before = len(inf)
    inf = [x for x in inf if x.get("provider_id") not in p["drop_providers"]]
    if len(inf) != before:
        changes.append(f"dropped {before - len(inf)} unusable inference provider(s)")

    # --- collapse duplicates ---------------------------------------------
    for api in ("inference", "vector_io", "responses", "file_processors",
                "files", "tool_runtime"):
        lst = providers.get(api)
        if not lst:
            continue
        if api == "inference":
            lst = inf
        n = len(lst)
        providers[api] = dedupe(lst)
        if len(providers[api]) != n:
            changes.append(f"{api}: {n} providers -> {len(providers[api])}")
    inf = providers.get("inference") or []

    # --- the API key, and what the provider may advertise ----------------
    pid = p["provider_id"]
    for prov in inf:
        if prov.get("provider_id") != pid:
            continue
        c = prov.setdefault("config", {})
        if not c.get("api_key"):
            c["api_key"] = "${env.%s:=}" % p["key_env"]
            changes.append(f"{pid}: added api_key from ${{env.{p['key_env']}}}")
        if p["allowed_models"]:
            # Sorted, and that is not cosmetic. The list arrives in whatever
            # order LiteLLM's /v1/models happened to return, which is not
            # stable between calls - so an unsorted list differs from the
            # published one on most runs, the role reports a change, and the
            # playground restarts every time the playbook runs. Sorting makes
            # the output a function of the model SET rather than of the order
            # one API call happened to use.
            want_models = sorted(p["allowed_models"])
            if c.get("allowed_models") != want_models:
                c["allowed_models"] = want_models
                changes.append(
                    f"{pid}: allowed_models set to {len(want_models)} "
                    f"model(s), excluding {', '.join(p['exclude_models']) or 'nothing'}")

    # --- Milvus ----------------------------------------------------------
    if p["register_milvus"]:
        vio = providers.setdefault("vector_io", [])
        if not any(x.get("provider_id") == "milvus" for x in vio):
            vio.append({
                "provider_id": "milvus",
                "provider_type": "remote::milvus",
                "config": {
                    "uri": p["milvus_uri"],
                    # Both required by MilvusVectorIOConfig. Omitting either
                    # fails validation at startup and exits 0, so the pod
                    # CrashLoopBackOffs with a clean exit code.
                    "token": "",
                    "persistence": {"backend": "kv_default",
                                    "namespace": "vector_io::milvus"},
                },
            })
            changes.append("registered the milvus vector_io provider")

    rr = cfg.setdefault("registered_resources", {})

    # The embedding model the vector store needs, under the provider that
    # actually serves it.
    models = rr.setdefault("models", [])
    emb_plain = p["embedding_model"]
    emb_full = f"{pid}/{emb_plain}"
    if not any(m.get("model_id") == emb_plain for m in models):
        models.append({
            "provider_id": pid,
            "model_id": emb_plain,
            "model_type": "embedding",
            "metadata": {"embedding_dimension": p["embedding_dimension"]},
        })
        changes.append(f"registered {emb_plain} as an embedding model")
    rr["models"] = dedupe(models, key="model_id")

    # Drop registrations belonging to providers that no longer exist, or
    # startup fails resolving them.
    live = {x.get("provider_id") for x in inf} | {
        x.get("provider_id") for x in (providers.get("vector_io") or [])}
    n = len(rr["models"])
    rr["models"] = [m for m in rr["models"] if m.get("provider_id") in live]
    if len(rr["models"]) != n:
        changes.append(f"removed {n - len(rr['models'])} model(s) of dropped providers")

    # The default embedding model for vector stores has to point at a
    # provider that still exists, and at a model that can actually load.
    vs = cfg.get("vector_stores")
    if isinstance(vs, dict):
        cur = vs.get("default_embedding_model") or {}
        if cur.get("provider_id") in p["drop_providers"]:
            vs["default_embedding_model"] = {
                "provider_id": pid, "model_id": emb_plain,
            }
            changes.append(
                f"default_embedding_model repointed to {pid}/{emb_plain} "
                f"(was on dropped provider {cur.get('provider_id')})")

    if p["register_milvus"]:
        # embedding_model MUST be the provider-namespaced identifier. The
        # bare name raises ModelNotFoundError at startup - same silent
        # exit-0 crash as a missing required field.
        want = [{
            "vector_store_id": "milvus-default",
            "vector_store_name": "Milvus (standalone)",
            "provider_id": "milvus",
            "embedding_model": emb_full,
            "embedding_dimension": p["embedding_dimension"],
        }]
        # Only report a change when there is one, or every run shows changed
        # and nobody can tell a real edit from a no-op.
        if rr.get("vector_stores") != want:
            rr["vector_stores"] = want
            changes.append(f"registered the milvus vector store against {emb_full}")

    return cfg, changes


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="src", required=True)
    ap.add_argument("--out", dest="dst", required=True)
    ap.add_argument("--params", required=True)
    a = ap.parse_args()

    cfg = yaml.safe_load(open(a.src)) or {}
    p = json.load(open(a.params))
    cfg, changes = fix(cfg, p)

    with open(a.dst, "w") as fh:
        yaml.safe_dump(cfg, fh, default_flow_style=False, sort_keys=False, width=200)

    print(json.dumps({"changed": bool(changes), "changes": changes}))


if __name__ == "__main__":
    main()
