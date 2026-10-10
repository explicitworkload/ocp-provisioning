# Walkthrough — classic MLOps

**5 minutes.** The non-LLM demo. Show this when there are traditional data
scientists in the room, or as the setup for [model-serving](../model-serving/).

Open `breast-cancer-tabular`, workspace `rag-eval`.

## 1. The question (20s)

> "Not everything is a language model. Here's the loop a data scientist
> actually lives in: try a grid of models, compare them honestly, promote
> the winner."

## 2. Autolog is the point (2 min)

Show the runs table — 8 runs, each with hyperparameters and metrics
populated. Then show the source:

```python
mlflow.sklearn.autolog(log_models=True, log_input_examples=True)
```

> "That's the instrumentation. One line. Nothing in this script calls
> log_param or log_metric for the models — parameters, metrics, the fitted
> pipeline, its signature and an input example are all captured because
> autolog patches sklearn's fit()."

Contrast with the RAG demos, which are hand-instrumented because a RAG
pipeline is bespoke. A framework MLflow already knows is free.

## 3. The trap worth teaching (1 min)

Point at `holdout_roc_auc`, the one metric logged by hand.

> "Autolog logs *training* metrics. It has no idea which data you held out.
> So the number you actually select on has to be logged yourself — and if
> you forget, you'll happily select on training performance and never
> notice."

## 4. Compare and promote (1 min)

Sort by `holdout_roc_auc`. `rf-50` wins at **0.9996**. Then
**Models → breast-cancer-classifier**, now at v2.

> "The winner is registered. That version is what the serving demo deploys."

## Say this before anyone else does

**The dataset is a toy.** sklearn's bundled breast-cancer set, 569 rows, 30
well-separated features. Everything scores near the ceiling, the grid is
not discriminating, and the winner is close to noise.

> "This demonstrates the workflow, not a modelling result."

Claiming otherwise is the fastest way to lose a technical audience. If you
want the comparison to show something real, swap in a harder dataset or add
label noise — then the grid separates and the promotion means something.
