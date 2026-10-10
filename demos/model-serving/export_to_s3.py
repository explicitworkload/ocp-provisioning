"""Move a registered MLflow model into object storage KServe can fetch.

This is the hop between the two halves of an MLOps story, and it is the part
that is never as simple as the slide suggests. MLflow's registry addresses
models as `models:/name/version` and stores artifacts on its own volume;
KServe wants a `storageUri` it can download from. Nothing bridges the two
automatically, so something has to carry the artifact across - this.

It also re-serialises. The registry holds an MLflow model directory (MLmodel,
python_env.yaml, a pickled estimator), but the cluster's `mlserver-runtime`
declares support for sklearn / xgboost / lightgbm / onnx and *not* mlflow. So
the sklearn estimator is loaded out of the MLflow wrapper and written as the
bare `model.joblib` that MLServer's sklearn runtime looks for.

The version pinning matters more than it looks. A pickle is only reliably
loadable by the library version that wrote it, and the runtime image ships
scikit-learn 1.9.0 - so the training job pins the same version. Get this
wrong and nothing fails until inference time, in a pod whose logs nobody is
watching.
"""

from __future__ import annotations

import os
import time

import boto3
import joblib
import mlflow
import urllib3
from botocore.client import Config

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

MODEL_NAME = os.environ.get("MODEL_NAME", "breast-cancer-classifier")
MODEL_VERSION = os.environ.get("MODEL_VERSION", "")  # empty = latest
BUCKET = os.environ["BUCKET_NAME"]
PREFIX = os.environ.get("S3_PREFIX", "breast-cancer")
ENDPOINT = os.environ["S3_ENDPOINT"]


def log(m):
    print(f"[{time.strftime('%H:%M:%S')}] {m}", flush=True)


def main():
    client = mlflow.MlflowClient()

    version = MODEL_VERSION
    if not version:
        versions = client.search_model_versions(f"name='{MODEL_NAME}'")
        if not versions:
            raise SystemExit(f"no versions registered for '{MODEL_NAME}'")
        version = str(max(int(v.version) for v in versions))
    log(f"registry: {MODEL_NAME} version {version}")

    # Loading through the sklearn flavour, not pyfunc: pyfunc would hand back
    # a wrapper whose pickle MLServer cannot read.
    model = mlflow.sklearn.load_model(f"models:/{MODEL_NAME}/{version}")
    log(f"loaded {type(model).__name__} from the registry")

    local = "/tmp/model.joblib"
    joblib.dump(model, local)
    size = os.path.getsize(local)
    log(f"wrote {local} ({size/1024:.0f} KiB)")

    s3 = boto3.client(
        "s3", endpoint_url=ENDPOINT,
        aws_access_key_id=os.environ["AWS_ACCESS_KEY_ID"],
        aws_secret_access_key=os.environ["AWS_SECRET_ACCESS_KEY"],
        config=Config(signature_version="s3v4"), verify=False,
    )
    key = f"{PREFIX}/model.joblib"
    s3.upload_file(local, BUCKET, key)
    log(f"uploaded s3://{BUCKET}/{key}")

    # Prove it is readable the way KServe will read it, rather than trusting
    # that a successful PUT means a fetchable object.
    head = s3.head_object(Bucket=BUCKET, Key=key)
    log(f"verified: {head['ContentLength']} bytes at the destination")

    print(f"\nstorageUri: s3://{BUCKET}/{PREFIX}")
    print(f"registry:   {MODEL_NAME} v{version}")


if __name__ == "__main__":
    main()
