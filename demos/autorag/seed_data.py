"""Put AutoRAG's sample corpus and benchmark into object storage.

AutoRAG reads its documents and its test questions from S3, via RHOAI
Connections. This fetches Red Hat's published sample set - the Summit 2026
session catalogue, which is a good corpus because the questions have
unambiguous answers - and uploads it to the NooBaa bucket.

Downloading in the Job rather than shipping the files through a ConfigMap
is not a style choice: the corpus is about 912 KB and a ConfigMap's
last-applied-configuration annotation caps at 256 KB, so staging it that
way fails outright.

Layout matches what the pipeline expects: documents and test data in the
SAME bucket under different prefixes.

    s3://<bucket>/input_data/*.md
    s3://<bucket>/benchmark_data.json
"""

from __future__ import annotations

import os
import urllib.request

import boto3
import urllib3
from botocore.client import Config

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

RAW = ("https://raw.githubusercontent.com/red-hat-data-services/"
       "red-hat-ai-examples/main/examples/autorag/data/rh_summit_2026")
DOCS = [
    "rh_summit_2026_20260511.md",
    "rh_summit_2026_20260512.md",
    "rh_summit_2026_20260513.md",
    "rh_summit_2026_20260514.md",
]
BENCHMARK = "benchmark_data.json"

BUCKET = os.environ["BUCKET_NAME"]
ENDPOINT = os.environ["S3_ENDPOINT"]


def main():
    s3 = boto3.client(
        "s3", endpoint_url=ENDPOINT,
        aws_access_key_id=os.environ["AWS_ACCESS_KEY_ID"],
        aws_secret_access_key=os.environ["AWS_SECRET_ACCESS_KEY"],
        config=Config(signature_version="s3v4"), verify=False,
    )

    def put(url: str, key: str):
        with urllib.request.urlopen(url, timeout=120) as r:
            body = r.read()
        s3.put_object(Bucket=BUCKET, Key=key, Body=body)
        # Read it back rather than trusting the PUT: a successful write and
        # a fetchable object are not the same thing.
        size = s3.head_object(Bucket=BUCKET, Key=key)["ContentLength"]
        print(f"  {key:<42} {size:>8} bytes", flush=True)
        return size

    total = sum(put(f"{RAW}/input_data/{d}", f"input_data/{d}") for d in DOCS)
    total += put(f"{RAW}/{BENCHMARK}", BENCHMARK)

    listed = s3.list_objects_v2(Bucket=BUCKET).get("Contents", [])
    print(f"\n  bucket now holds {len(listed)} objects, {total} bytes")
    print(f"  documents: s3://{BUCKET}/input_data/")
    print(f"  test data: s3://{BUCKET}/{BENCHMARK}")


if __name__ == "__main__":
    main()
