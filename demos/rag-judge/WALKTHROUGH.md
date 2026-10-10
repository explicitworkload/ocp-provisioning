# Walkthrough — traced and judged

**6–8 minutes.** Follows demo 1 naturally: *we proved retrieval finds the
right chunk; are the answers any good?*

Open `openrag-answer-quality` (experiment 2), workspace `rag-eval`.

## 1. The question (30s)

> "Retrieval working doesn't mean the answer is good. The model can be
> handed the right chunk and still waffle, or invent something fluent that
> isn't in the text at all. How would we know?"

## 2. Traces — one request, opened up (2 min)

**Observability → Traces.** Pick any trace, expand it.

> "Every question produces a trace with two spans: RETRIEVER, showing
> exactly which chunks came back, and LLM, showing the prompt and the
> answer. When someone says 'the bot gave me a wrong answer', this is where
> you look — not at an aggregate."

Point out this is two decorators, nothing more:

```python
@mlflow.trace(span_type="RETRIEVER")
def retrieve(question, k): ...

@mlflow.trace(span_type="LLM")
def generate(question, context): ...
```

## 3. Judges — the scores (2 min)

**Evaluation → Evaluation runs** → the `rag-answer-quality` run.

```
correctness/mean         0.917
grounded/mean            0.917
relevance_to_query/mean  0.917
```

Explain the three in one line each:

- **Correctness** — does the answer support the facts in the source chunk?
- **RelevanceToQuery** — does it address what was actually asked?
- **grounded** — is it supported by the context, or invented?

> "Groundedness is the one that matters in RAG. A confident answer made up
> from nothing scores well on everything else."

## 4. The best moment — find the failure (2 min)

0.917 is exactly **11 of 12**, and all three scorers landing on the same
number suggests one question failing all three rather than three
independent failures.

Find it, open its trace, and read what was retrieved versus what was said.

> "One concrete failure you can inspect end to end beats three aggregate
> means. This is what you can't do with a spreadsheet of scores."

## Say these before anyone else does

**The judge and the generator are currently the same model.** granite
judging granite. That is the first objection anyone raises and it is a fair
one. Point `MLFLOW_GENAI_JUDGE_DEFAULT_MODEL` at `qwen38-27b` before
presenting and the demo is materially stronger.

**Twelve questions.** 0.917 is 11/12; one item moves it by 8 points.

**Cost scales at ~4× the question count** — each question is one retrieval,
one generation and three judge calls.
