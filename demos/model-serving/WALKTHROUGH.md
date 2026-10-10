# Walkthrough — registry to serving

**5 minutes.** Run this straight after [tabular-mlops](../tabular-mlops/);
it deploys what that demo registered.

Set-up happens before the room arrives: the bucket, the export Job, the
serving runtime and the InferenceService are already applied — those
commands are in the [README](README.md). This walkthrough shows the result
and then tests it. Each step below is **Tell** (say it first), **Show** (do
it), **Tell** (say what it meant).

## In plain English

A team trains a model and files it in a catalogue under a name and a version
number. Getting that filed model to the point where other software can send
it a question and get an answer back is a separate piece of work, and nothing
does it for you. On a slide it is one arrow; in practice it is an afternoon.
This demo does that hop in front of the audience and then proves it worked,
by sending the live model twenty records it has never seen and checking the
answers.

## 1. The gap (30s)

**Tell** — name the problem before anything is on screen. This is the one
claim the rest of the demo exists to test.

> "Everyone's MLOps slide has an arrow from 'registry' to 'serving'. That
> arrow is doing a lot of work. MLflow addresses models as
> `models:/name/version` on its own volume; KServe wants a storageUri it can
> download. **Nothing bridges those two.** Something has to carry it."

**Show** — nothing to click. This step is spoken; the terminal and the
dashboard can both stay closed.

**Tell** — make the two ends concrete before moving, because everything
that follows is one end, the other, or the carry between them.

> **Plain English:** the registry is a catalogue — it knows a model by name
> and version, the way a library knows a book by its shelf code. KServe is
> the software that runs a model behind a URL so other systems can call it,
> and it can only load a file it is able to download; a shelf code is not a
> download link.

## 2. The carry (1 min)

**Tell** — the bridge is a Job: it reads the model out of MLflow and writes
it into object storage in the layout the runtime expects. It ran during
set-up, so this is its log rather than a live wait.

**Show**

1. Switch to the terminal.
2. Show the export Job's output:

   ```bash
   oc -n rag-eval logs job/export-model
   ```

   ```
   registry: breast-cancer-classifier version 2
   loaded Pipeline from the registry
   wrote /tmp/model.joblib (161 KiB)
   uploaded s3://model-artifacts-.../breast-cancer/model.joblib
   verified: 165282 bytes at the destination
   ```

3. Read it top to bottom: which version came out of the registry, what was
   loaded, what was written locally, where it was uploaded, and what was
   found at the far end.

**Tell** — the last line is the one to point at: the Job read the object
back and checked its size rather than trusting that the upload returned.

> "Out of MLflow, into a NooBaa bucket, in the layout the runtime expects.
> Three steps, and each one has a way to go wrong silently."

> **Plain English:** a bucket is object storage — you put a whole file in
> under a name and get it back by that name, rather than opening and editing
> it in place like a shared drive. The export copies the model out of MLflow
> and puts it there under the name and path the serving software looks for.

## 3. The deployment (1 min)

**Tell** — that bucket address is what the InferenceService points at. The
dashboard is where you see whether the cluster acted on it.

**Show**

1. RHOAI → left nav **Projects** → **RAG Eval & MLflow Demos** → the
   **Deployments** tab.
2. Read the `breast-cancer` row across: **Model deployment name**,
   **Deployment resource**, **Status**.

   ```
   breast-cancer   MLServer ServingRuntime for KServe   Ready
   ```

**Tell** — Status **Ready** is the dashboard reporting that the pod started.
That is a smaller claim than it looks, which is what step 4 is for.

> "CPU only. Both GPUs stay free for language models."

> **Plain English:** the serving runtime is the general-purpose program that
> loads a model file and answers requests over the network. The model is the
> file it loads — a media player and a track.

## 4. The proof (2 min)

**Tell** — Ready means the pod started, not that the model works. The smoke
test sends the live endpoint twenty holdout rows and compares the answers
with the labels.

> **Plain English:** Ready means the server came up and is listening, not
> that it gives correct answers. The only way to know the second is to ask
> it something whose answer you already have.

**Show**

1. Run the smoke test, in a terminal logged in to the cluster:

   ```bash
   oc -n rag-eval delete job smoke-test --ignore-not-found
   oc apply -f demos/model-serving/smoke-test-job.yaml
   oc -n rag-eval logs -f job/smoke-test
   ```

   The first command clears any earlier run, so the step is repeatable. The
   third follows the log.

2. Wait for the two lists and the score line:

   ```
   predicted : [0, 1, 1, 0, 0, 0, 1, 1, 0, 0, ...]
   actual    : [0, 1, 1, 0, 0, 0, 1, 1, 0, 1, ...]
   19/20 correct on unseen holdout rows
   ```

3. Read `predicted` against `actual` on screen, then the score line.

**Tell** — that closes the gap named in step 1, and closes it with evidence
rather than a Ready badge.

> "Those are rows from the same holdout split the training job used — data
> this model has never seen. That's the arrow, actually working."

> **Plain English:** holdout rows are examples deliberately kept back when
> the model was trained, so it has never seen them. Getting them right is
> evidence it learned the pattern rather than memorised the answers.

## The engineering story, if they want it

Four things fail here in ways that don't point at their cause, and they are
the reason this takes an afternoon rather than ten minutes:

1. **The runtime doesn't accept MLflow models** — `mlserver-runtime`
   declares sklearn/xgboost/lightgbm/onnx. The estimator has to be lifted
   out of the MLflow wrapper.
2. **scikit-learn must match in three places.** The runtime image ships
   1.9.0. A pickle is only reliably loadable by the version that wrote it,
   and a mismatch fails at *inference*, in a pod nobody is tailing.

   > **Plain English:** a pickle is Python's way of saving a trained object
   > to a file, and it is fussy — the library reading it has to be the same
   > version as the one that wrote it. Inference is the moment the model is
   > asked for an answer, which is why a bad save surfaces long after the
   > save itself appeared to succeed.

3. **`storageUri` names the prefix, not the object.**

   > **Plain English:** point it at the folder, not at the file inside it.
   > KServe downloads everything under that address into the pod, and
   > MLServer then looks inside for the model file.

4. **The predictor Service is headless**, so use port 8080 — port 80 gives
   `Connection refused` against a perfectly healthy model.

   > **Plain English:** this Service has no address of its own, so the usual
   > "port 80 maps through to 8080" never happens — the name resolves
   > straight to the pod, which is only listening on 8080. Ask for 8080
   > directly; asking for 80 looks exactly like a model that is down.

That list is the honest answer to "how hard is this really?"
