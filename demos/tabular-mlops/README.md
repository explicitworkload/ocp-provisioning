# Classic MLOps — train, compare, register

The non-LLM demo. A grid of scikit-learn models, autologged, compared on a
holdout, and the winner promoted into the MLflow Model Registry.

Worth having for two reasons. It is the loop a traditional data scientist
recognises, which matters if there is one in the room. And it needs no GPU,
no inference endpoint and no corpus — so it still runs when the model-serving
stack is unhappy, which is not hypothetical here.

## Running it

```bash
oc -n rag-eval delete job tabular-mlops --ignore-not-found
oc create configmap tabular-mlops-script -n rag-eval \
  --from-file=train.py=demos/tabular-mlops/train.py \
  --dry-run=client -o yaml | oc apply -f -
oc apply -f demos/tabular-mlops/job.yaml
oc -n rag-eval logs -f job/tabular-mlops
```

Under two minutes, most of it installing scikit-learn.

## The point is autolog

`mlflow.sklearn.autolog()` is one line, and nothing in `train.py` calls
`log_param` or `log_metric` for the models. Parameters, training metrics, the
fitted pipeline, its signature and an input example are all captured because
autolog patches sklearn's `fit()`.

The contrast with the other demos is the lesson: those are hand-instrumented
because a RAG pipeline is bespoke; this is a framework MLflow already knows,
so the instrumentation is free.

The one explicit metric is `holdout_roc_auc`. Autolog logs *training*
metrics; it has no idea which data you held out, so the number you actually
select on has to be logged by hand. That distinction is worth making out
loud — it is a common way to accidentally select on training performance.

## Reading the result

First run: `rf-50` won with a holdout ROC AUC of **0.9996**, registered as
`breast-cancer-classifier` v1.

Say the quiet part: this is sklearn's bundled breast-cancer set, 569 rows and
30 well-separated features. Everything in the grid scores near the ceiling,
so the comparison is not discriminating and the winner is close to noise. It
demonstrates the *workflow*, not a modelling result. Claiming otherwise is
the fastest way to lose a technical audience.

If you want the comparison view to show something real, swap in a harder
dataset or add label noise — then the grid separates and the registry
promotion means something.

## Serving it

Not done here. `mlserver-runtime-template` is available on the cluster for
CPU inference, so the registered model can be deployed through KServe, but
that needs the model artifact somewhere KServe can fetch it (S3/NooBaa rather
than MLflow's PVC-backed artifact store). Worth knowing the artifact PVC is
only 2Gi — see the note on `mlflow_storage_size` being silently pruned.
