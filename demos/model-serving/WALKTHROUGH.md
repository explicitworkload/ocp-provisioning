# Walkthrough — registry to serving

**5 minutes.** Run this straight after [tabular-mlops](../tabular-mlops/);
it deploys what that demo registered.

## 1. The gap (30s)

> "Everyone's MLOps slide has an arrow from 'registry' to 'serving'. That
> arrow is doing a lot of work. MLflow addresses models as
> `models:/name/version` on its own volume; KServe wants a storageUri it can
> download. **Nothing bridges those two.** Something has to carry it."

## 2. The carry (1 min)

Show the export Job's output:

```
registry: breast-cancer-classifier version 2
loaded Pipeline from the registry
wrote /tmp/model.joblib (161 KiB)
uploaded s3://model-artifacts-.../breast-cancer/model.joblib
verified: 165282 bytes at the destination
```

> "Out of MLflow, into a NooBaa bucket, in the layout the runtime expects.
> Three steps, and each one has a way to go wrong silently."

## 3. The deployment (1 min)

RHOAI → **Projects → RAG Eval & MLflow Demos → Deployments**.

```
breast-cancer   MLServer ServingRuntime for KServe   Ready
```

> "CPU only. Both GPUs stay free for language models."

## 4. The proof (2 min)

Ready means the pod started, not that the model works. Run the smoke test:

```bash
oc -n rag-eval delete job smoke-test --ignore-not-found
oc apply -f demos/model-serving/smoke-test-job.yaml
oc -n rag-eval logs -f job/smoke-test
```

```
predicted : [0, 1, 1, 0, 0, 0, 1, 1, 0, 0, ...]
actual    : [0, 1, 1, 0, 0, 0, 1, 1, 0, 1, ...]
19/20 correct on unseen holdout rows
```

> "Those are rows from the same holdout split the training job used — data
> this model has never seen. That's the arrow, actually working."

## The engineering story, if they want it

Four things fail here in ways that don't point at their cause, and they are
the reason this takes an afternoon rather than ten minutes:

1. **The runtime doesn't accept MLflow models** — `mlserver-runtime`
   declares sklearn/xgboost/lightgbm/onnx. The estimator has to be lifted
   out of the MLflow wrapper.
2. **scikit-learn must match in three places.** The runtime image ships
   1.9.0. A pickle is only reliably loadable by the version that wrote it,
   and a mismatch fails at *inference*, in a pod nobody is tailing.
3. **`storageUri` names the prefix, not the object.**
4. **The predictor Service is headless**, so use port 8080 — port 80 gives
   `Connection refused` against a perfectly healthy model.

That list is the honest answer to "how hard is this really?"
