# Walkthrough — classic MLOps

**5 minutes.** The non-LLM demo. Show this when there are traditional data
scientists in the room, or as the setup for [model-serving](../model-serving/).

Open `breast-cancer-tabular`, workspace `rag-eval`.

## In plain English

A data scientist rarely builds one model. They build a dozen variants, score
each one, and keep the best — and the fiddly part is holding an honest record
of which variant was which, and how well each one did on data it had not
already seen. This demo is about that record: eight models trained, every
setting and score captured automatically, and the winner given a version
number the deployment step can ask for by name. No language models are
involved, which is deliberate — this is the classic kind of machine learning,
and the demo is about the discipline around it rather than the model itself.

## 1. The question (20s)

**Tell**

> "Not everything is a language model. Here's the loop a data scientist
> actually lives in: try a grid of models, compare them honestly, promote
> the winner."

**Show**

Get the screen right before you say any of that. This demo lives in the
**Model training** half of MLflow, not **GenAI** — there are no traces and no
judges here.

1. Workspace pill, top of the left sidebar -> check it reads **rag-eval**.
   The dropdown caret changes it.
2. The two-way toggle underneath -> **Model training**. The sidebar becomes
   Overview, Runs, Models, Traces, Model registry.
3. Open the experiment **breast-cancer-tabular**. The back-arrow button below
   the toggle names whichever experiment is currently open, so it is also how
   you check you are in the right one.

**Tell**

> **Plain English:** a grid of models is the same job tried several ways —
> different algorithms, different dial settings. Those dials are the
> hyperparameters: choices made before training starts, rather than anything
> the model works out for itself.

## 2. Autolog is the point (2 min)

**Tell**

Everything in the table you are about to open was written without a single
logging call in the training script. Say that first — it is the claim the
rest of the step proves.

**Show**

1. Sidebar **Runs** -> the run list for **breast-cancer-tabular**. 8 runs,
   one row per variant in the grid (`rf-50`, `gb-lr0.2`, and so on).
2. Read across a row: the hyperparameter columns and the metric columns are
   both populated, and nobody typed them in.
3. Then show the source — `demos/tabular-mlops/train.py`:

```python
mlflow.sklearn.autolog(log_models=True, log_input_examples=True)
```

**Tell**

> "That's the instrumentation. One line. Nothing in this script calls
> log_param or log_metric for the models — parameters, metrics, the fitted
> pipeline, its signature and an input example are all captured because
> autolog patches sklearn's fit()."

> **Plain English:** autolog is a lab notebook that writes itself. Without it,
> someone has to remember to write down every setting and every result for
> every run, and what does not get written down cannot be compared later.

Contrast with the RAG demos, which are hand-instrumented because a RAG
pipeline is bespoke. A framework MLflow already knows is free.

## 3. The trap worth teaching (1 min)

**Tell**

Autolog filled in nearly every column in that table. There is exactly one it
could not have written, and it is the one the decision rests on.

**Show**

1. Back to the **Runs** table -> point at `holdout_roc_auc`, the one metric
   logged by hand. Every other metric on the row came from autolog.
2. If the script is still to hand, that column comes from the only
   `log_metric` call in it: `mlflow.log_metric("holdout_roc_auc", auc)`.

**Tell**

> **Plain English:** the holdout is a slice of the data put to one side before
> training and never shown to the model, so scoring against it says something
> about cases the model has not already met.

> "Autolog logs *training* metrics. It has no idea which data you held out.
> So the number you actually select on has to be logged yourself — and if
> you forget, you'll happily select on training performance and never
> notice."

> **Plain English:** scoring a model on the data it trained on is like setting
> a student an exam made only of the questions they revised from — they do
> well, and you know nothing about whether they understand the subject. The
> trap is that the flattering number turns up on its own and looks exactly
> like a real one.

## 4. Compare and promote (1 min)

**Tell**

One column decides the winner, so name the column before you sort by it —
otherwise the sort looks like picking a favourite after the fact.

**Show**

1. In the **Runs** table -> click the `holdout_roc_auc` column header to sort
   by it. Click it again if it sorts the wrong way up. `rf-50` wins at
   **0.9996**.
2. Optional, if the room wants them side by side: tick the checkboxes of the
   runs you want and press **Compare**. The page is headed "Comparing N runs
   from 1 experiment". Under **Visualizations** choose **Parallel Coordinates
   Plot**, press **Clear All** if the dropdowns come pre-filled, then add
   `holdout_roc_auc` to **Metrics:**. The chips on offer in **Parameters:**
   are whatever autolog captured, and they differ between the logistic,
   forest and boosting runs — add one only if the question in the room is
   about that dial. The **Run details** table underneath maps each column
   back to its Run Name and Run ID.
3. Sidebar **Models** -> **breast-cancer-classifier**, now at v2.

**Tell**

> **Plain English:** ROC AUC measures how well a model tells the two classes
> apart, where 1.0 is perfect and 0.5 is a coin toss. 0.9996 is all but the
> top of the scale, which is less impressive than it sounds — see the last
> section.

> "The winner is registered. That version is what the serving demo deploys."

> **Plain English:** the registry is a numbered shelf for finished models.
> Deploying a version number rather than a file means you can always say
> which exact model is answering, and which run produced it.

## Say this before anyone else does

**The dataset is a toy.** sklearn's bundled breast-cancer set, 569 rows, 30
well-separated features. Everything scores near the ceiling, the grid is
not discriminating, and the winner is close to noise.

> **Plain English:** when every contestant scores almost full marks, the test
> is too easy to rank them by. The gaps between these eight models are small
> enough that a different shuffle of the data could hand the win to another
> one.

> "This demonstrates the workflow, not a modelling result."

Claiming otherwise is the fastest way to lose a technical audience. If you
want the comparison to show something real, swap in a harder dataset or add
label noise — then the grid separates and the promotion means something.
