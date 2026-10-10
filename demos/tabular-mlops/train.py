"""The non-LLM half of OpenShift AI: train, compare, register.

Everything else in demos/ is about language models. This is the classic loop
a data scientist recognises - a grid of models, autologged, compared on a
holdout, and the winner promoted into the Model Registry - and it is worth
having because it needs no GPU and no inference endpoint, so it still works
when the GPU node is down or the serving stack is reconciling.

mlflow.sklearn.autolog() is the point. Nothing below calls log_param or
log_metric: parameters, metrics, the fitted model, the signature and an input
example are all captured because autolog patches sklearn's fit(). The
contrast with the hand-instrumented demos is the lesson.

Dataset is sklearn's bundled breast-cancer set - 569 rows, 30 features, no
download. Small and clean, which is honest to say out loud: this demonstrates
the workflow, not a modelling achievement.
"""

from __future__ import annotations

import os
import time

import mlflow
import mlflow.sklearn
from sklearn.datasets import load_breast_cancer
from sklearn.ensemble import GradientBoostingClassifier, RandomForestClassifier
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import roc_auc_score
from sklearn.model_selection import train_test_split
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import StandardScaler

SEED = int(os.environ.get("SEED", "1337"))
REGISTERED_NAME = os.environ.get("REGISTERED_NAME", "breast-cancer-classifier")


def log(m):
    print(f"[{time.strftime('%H:%M:%S')}] {m}", flush=True)


# A grid wide enough that the comparison view has something to say, and small
# enough to finish in under a minute on CPU.
GRID = [
    ("logreg-C0.1", LogisticRegression(C=0.1, max_iter=5000, random_state=SEED)),
    ("logreg-C1", LogisticRegression(C=1.0, max_iter=5000, random_state=SEED)),
    ("logreg-C10", LogisticRegression(C=10.0, max_iter=5000, random_state=SEED)),
    ("rf-50", RandomForestClassifier(n_estimators=50, random_state=SEED)),
    ("rf-200", RandomForestClassifier(n_estimators=200, random_state=SEED)),
    ("rf-200-d3", RandomForestClassifier(n_estimators=200, max_depth=3, random_state=SEED)),
    ("gb-lr0.05", GradientBoostingClassifier(learning_rate=0.05, random_state=SEED)),
    ("gb-lr0.2", GradientBoostingClassifier(learning_rate=0.2, random_state=SEED)),
]


def main():
    mlflow.set_experiment(os.environ.get("MLFLOW_EXPERIMENT", "breast-cancer-tabular"))

    data = load_breast_cancer()
    X_tr, X_te, y_tr, y_te = train_test_split(
        data.data, data.target, test_size=0.25, random_state=SEED, stratify=data.target)
    log(f"train {X_tr.shape}, holdout {X_te.shape}, {len(data.feature_names)} features")

    # One line. Every run below is logged without another MLflow call.
    mlflow.sklearn.autolog(log_models=True, log_input_examples=True)

    best = {"auc": -1.0}
    for name, clf in GRID:
        # Scaling inside the pipeline, not before the split - otherwise the
        # holdout's statistics leak into training and every score is flattered.
        pipe = Pipeline([("scale", StandardScaler()), ("clf", clf)])
        with mlflow.start_run(run_name=name) as run:
            pipe.fit(X_tr, y_tr)
            auc = roc_auc_score(y_te, pipe.predict_proba(X_te)[:, 1])
            # The one metric autolog cannot know about: it logs training
            # metrics, and this is the holdout it never sees.
            mlflow.log_metric("holdout_roc_auc", auc)
            log(f"  {name:<12} holdout ROC AUC {auc:.4f}")
            if auc > best["auc"]:
                best = {"auc": auc, "name": name, "run_id": run.info.run_id}

    log(f"best: {best['name']} at {best['auc']:.4f} -> registering as "
        f"'{REGISTERED_NAME}'")
    result = mlflow.register_model(f"runs:/{best['run_id']}/model", REGISTERED_NAME)
    log(f"registered {REGISTERED_NAME} version {result.version}")

    print("\n=== WINNER " + "=" * 50)
    print(f"  model      {best['name']}")
    print(f"  holdout    ROC AUC {best['auc']:.4f}")
    print(f"  registered {REGISTERED_NAME} v{result.version}")
    print(f"  run        {best['run_id']}")


if __name__ == "__main__":
    main()
