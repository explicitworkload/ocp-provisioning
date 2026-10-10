"""Call the served model with real rows and check it predicts correctly.

A Ready InferenceService means the pod started, not that the model works. The
failure this guards against is specific: the estimator is a pickle, and a
pickle written by a different scikit-learn version than the runtime image
ships either refuses to load or - worse - loads and predicts nonsense. That
shows up here and nowhere earlier.

Uses the V2 (Open Inference) protocol, which is what MLServer speaks.
"""

from __future__ import annotations

import json
import os
import urllib3
import requests
from sklearn.datasets import load_breast_cancer
from sklearn.model_selection import train_test_split

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# Port 8080, not 80. The predictor Service is headless (ClusterIP: None),
# so its 80->8080 mapping is never applied - DNS resolves straight to pod
# IPs and you have to name the container port yourself. Using port 80 gives
# "Connection refused" against a perfectly healthy model.
BASE = os.environ.get(
    "PREDICTOR_URL",
    "http://breast-cancer-predictor.rag-eval.svc.cluster.local:8080")
MODEL = os.environ.get("MODEL_NAME", "breast-cancer")
N = int(os.environ.get("N_ROWS", "20"))
SEED = int(os.environ.get("SEED", "1337"))


def main():
    data = load_breast_cancer()
    # The same split and seed the training job used, so these rows are the
    # holdout the model never saw - not rows it memorised.
    _, X_te, _, y_te = train_test_split(
        data.data, data.target, test_size=0.25, random_state=SEED,
        stratify=data.target)
    X, y = X_te[:N], y_te[:N]

    meta = requests.get(f"{BASE}/v2/models/{MODEL}", timeout=60)
    print(f"metadata {meta.status_code}: {json.dumps(meta.json())[:220]}")

    payload = {"inputs": [{
        "name": "predict",
        "shape": list(X.shape),
        "datatype": "FP64",
        "data": X.flatten().tolist(),
    }]}
    r = requests.post(f"{BASE}/v2/models/{MODEL}/infer", json=payload, timeout=120)
    r.raise_for_status()
    preds = r.json()["outputs"][0]["data"]

    correct = sum(int(p) == int(t) for p, t in zip(preds, y))
    print(f"\npredicted : {[int(p) for p in preds]}")
    print(f"actual    : {[int(t) for t in y]}")
    print(f"\n{correct}/{len(y)} correct on unseen holdout rows")
    if correct < len(y) * 0.8:
        raise SystemExit("served model is predicting badly - suspect a "
                         "scikit-learn version mismatch in the pickle")
    print("SMOKE TEST PASSED")


if __name__ == "__main__":
    main()
