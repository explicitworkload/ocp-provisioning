# Registry → serving

Completes [../tabular-mlops](../tabular-mlops) into a full lifecycle: the
model that demo registered is exported to object storage, served by KServe,
and called with holdout rows it has never seen.

This is the hop people don't believe until they watch it, and it is the part
the slide always skips. MLflow addresses models as `models:/name/version` on
its own volume; KServe wants a `storageUri` it can download. **Nothing
bridges the two automatically.**

```
MLflow registry  ──export──▶  NooBaa bucket  ──storageUri──▶  KServe/MLServer
breast-cancer-classifier v2    s3://…/breast-cancer            InferenceService
```

CPU only. Both T4s stay free for language models.

## Running it

Needs `breast-cancer-classifier` already registered — run
[../tabular-mlops](../tabular-mlops) first.

```bash
# 1. a bucket (generates the Secret and ConfigMap the Job reads)
oc apply -f demos/model-serving/obc.yaml

# 2. carry the model across
oc create configmap export-model-script -n rag-eval \
  --from-file=export_to_s3.py=demos/model-serving/export_to_s3.py \
  --dry-run=client -o yaml | oc apply -f -
oc apply -f demos/model-serving/export-job.yaml

# 3. runtime, credentials, and the InferenceService
oc process -n redhat-ods-applications mlserver-runtime-template -o yaml | oc apply -n rag-eval -f -
oc apply -f demos/model-serving/inferenceservice.yaml   # edit the bucket name first

# 4. prove it predicts
oc create configmap smoke-test-script -n rag-eval \
  --from-file=smoke_test.py=demos/model-serving/smoke_test.py \
  --dry-run=client -o yaml | oc apply -f -
oc apply -f demos/model-serving/smoke-test-job.yaml
oc -n rag-eval logs -f job/smoke-test
```

The InferenceService went Ready in about 30 seconds; the smoke test scored
**19/20** on unseen holdout rows.

## Four things that are easy to get wrong

**The runtime does not accept MLflow models.** `mlserver-runtime` declares
`sklearn`, `xgboost`, `lightgbm` and `onnx` — not `mlflow`. So the exporter
loads the estimator out of the MLflow wrapper with
`mlflow.sklearn.load_model` and writes the bare `model.joblib` that
MLServer's sklearn runtime looks for. Loading via `pyfunc` instead would
give a wrapper MLServer cannot read.

**scikit-learn has to match in three places.** The runtime image ships
**1.9.0**, so the training Job, the export Job and the smoke test all pin
`scikit-learn==1.9.0`. A pickle is only reliably loadable by the version
that wrote it, and a mismatch does not fail at export — it fails at
inference, in a pod nobody is tailing. Check the image before assuming:

```bash
oc run probe -n rag-eval --image=<mlserver-image> --restart=Never --command -- sleep 300
oc exec -n rag-eval probe -- python -c "import sklearn; print(sklearn.__version__)"
```

**`storageUri` names the prefix, not the object.** KServe downloads the
whole prefix into `/mnt/models` and MLServer then looks for `model.joblib`
inside it. Pointing at the file gives a directory containing a file where a
directory is expected.

**The predictor Service is headless, so use port 8080.** `ClusterIP: None`
means the `80 → 8080` mapping is never applied — DNS resolves straight to
pod IPs and you must name the container port. Port 80 gives `Connection
refused` against a perfectly healthy model, which reads like a broken
deployment.

## S3 credentials

KServe's storage initializer reads credentials from a Secret attached to the
predictor's ServiceAccount, and the endpoint comes from annotations on that
Secret rather than from the Secret's data:

```
serving.kserve.io/s3-endpoint:  s3.openshift-storage.svc:443   # no scheme
serving.kserve.io/s3-usehttps:  "1"
serving.kserve.io/s3-verifyssl: "0"                            # NooBaa self-signs
serving.kserve.io/s3-region:    us-east-1                      # NooBaa ignores it, boto wants one
```

The ObjectBucketClaim generates its own Secret and ConfigMap, but without
those annotations — hence the separate `s3-model-store` Secret that copies
the keys and adds them.
