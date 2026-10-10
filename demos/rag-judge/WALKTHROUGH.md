# Walkthrough — traced and judged

**6–8 minutes.** Follows demo 1 naturally: *we proved retrieval finds the
right chunk; are the answers any good?*

Open `openrag-answer-quality` (experiment 2), workspace `rag-eval`.

## In plain English

A question-answering system does two things: it searches our own
documentation for a relevant passage, then it writes an answer out of that
passage. Demo 1 checked the first half. This one checks the second — was the
answer any good, and did it come from the passage or did the model make it
up? Two things make that checkable: a recording of every individual
question, and a score on every answer, so you can go from "the bot told me
something wrong" to the one request that went wrong and read it.

## 1. The question (30s)

**Tell**

Open on the gap demo 1 leaves behind: finding the right passage is not the
same as answering well. Ask it and leave a pause before you touch anything.

> "Retrieval working doesn't mean the answer is good. The model can be
> handed the right chunk and still waffle, or invent something fluent that
> isn't in the text at all. How would we know?"

**Show**

Nothing to click yet — this one is said to the room. While you talk, check
you are parked in the right place:

1. Workspace pill, top-left → **rag-eval**
2. The toggle below it → **GenAI**
3. The back-arrow button under the toggle should read
   **openrag-answer-quality**

**Tell**

Nobody in the room can answer that question from an average. The rest of the
demo is the two things that make it answerable: a recording of every single
request, then a score on every answer.

## 2. Traces — one request, opened up (2 min)

**Tell**

Start with one request rather than the totals. Before any score means
anything, the room has to see that each question is kept on its own.

**Show**

1. Sidebar **GenAI** → **Observability** → **Traces**
2. Pick any trace in the list and open it
3. Expand the **RETRIEVER** span — the chunks that came back
4. Expand the **LLM** span — the prompt that went out and the answer that
   came back

**Tell**

Leave both spans open on screen while you say this.

> "Every question produces a trace with two spans: RETRIEVER, showing
> exactly which chunks came back, and LLM, showing the prompt and the
> answer. When someone says 'the bot gave me a wrong answer', this is where
> you look — not at an aggregate."

> **Plain English:** a trace is the recorded story of one question going
> through the system, and the spans are the steps inside it — the look-up,
> then the answer-writing. Chunks are the short passages the documentation
> was cut into; a trace is the itemised receipt for one request, not the
> monthly total.

Point out this is two decorators, nothing more:

```python
@mlflow.trace(span_type="RETRIEVER")
def retrieve(question, k): ...

@mlflow.trace(span_type="LLM")
def generate(question, context): ...
```

> **Plain English:** a decorator is one line added above a function. Those
> two lines are the whole of the recording; the code inside the functions is
> unchanged.

## 3. Judges — the scores (2 min)

**Tell**

Now go from the one request to all twelve. Every answer in this run was read
and marked by three separate judges, and the run holds their means.

**Show**

1. Sidebar **GenAI** → **Evaluation** → **Evaluation runs**
2. Open the run named `rag-answer-quality`
3. Read the three scorer means:

```
correctness/mean         0.917
grounded/mean            0.917
relevance_to_query/mean  0.917
```

**Tell**

Three identical numbers, and no human produced any of them. Say where the
marks came from before anyone asks.

> **Plain English:** nobody marked these answers by hand — a second model
> read the question, the source text and the answer, then gave a verdict.
> Marking is an easier job than writing was, because the marker has the
> source text in front of it; the limits of that are in the last section.

Explain the three in one line each:

- **Correctness** — does the answer support the facts in the source chunk?
- **RelevanceToQuery** — does it address what was actually asked?
- **grounded** — is it supported by the context, or invented?

> "Groundedness is the one that matters in RAG. A confident answer made up
> from nothing scores well on everything else."

> **Plain English:** RAG is this pattern — look something up, then answer
> from what you found — and *grounded* asks whether the answer stayed
> inside what was found. An invented answer can be fluent and on topic,
> which is exactly why it passes the other two checks; this is what people
> mean when they say a model hallucinated.

## 4. The best moment — find the failure (2 min)

**Tell**

0.917 is exactly **11 of 12**, and all three scorers landing on the same
number suggests one question failing all three rather than three
independent failures.

> **Plain English:** each answer either passes or fails, so the score is the
> share that passed, and 0.917 is eleven out of twelve. Three separate
> checks all stopping at eleven points at one bad answer failing all three,
> not at three different answers each failing once.

Say the prediction out loud before you go looking. The room then watches you
test a claim rather than watching you search.

**Show**

Find it, open its trace, and read what was retrieved versus what was said.

1. Sidebar **GenAI** → **Evaluation** → **Evaluation runs** → the
   `rag-answer-quality` run — where step 3 left you
2. In that run, go to the per-question results and find the one question
   marked as failing all three scorers. One row in twelve
3. Note the question text on that row
4. Open the trace for that row. If the row does not take you there, go
   Sidebar **GenAI** → **Observability** → **Traces** and open the trace
   whose question matches the one you noted
5. In the trace, expand **RETRIEVER** — what came back — then **LLM** —
   what the model did with it

Walk this once before you present and leave the trace open in a second tab.
Finding the row live is the one part of this demo that can stall.

**Tell**

Read the retrieved chunk and the answer side by side, and name which half
went wrong: the look-up, or the writing.

> "One concrete failure you can inspect end to end beats three aggregate
> means. This is what you can't do with a spreadsheet of scores."

## Say these before anyone else does

**The judge and the generator are currently the same model.** granite
judging granite. That is the first objection anyone raises and it is a fair
one. Point `MLFLOW_GENAI_JUDGE_DEFAULT_MODEL` at `qwen38-27b` before
presenting and the demo is materially stronger.

> **Plain English:** the model marking the homework is the model that wrote
> it. It still catches real mistakes, because it marks with the source text
> in view — but it cannot be relied on to spot the kind of error it is
> itself prone to, which is why the line above says to point it at a
> different model.

**Twelve questions.** 0.917 is 11/12; one item moves it by 8 points.

> **Plain English:** twelve is a small sample. One answer going the other
> way moves the headline number by eight points, so the figure is rough by
> construction — say so before someone treats 0.917 as precise.

**Cost scales at ~4× the question count** — each question is one retrieval,
one generation and three judge calls.

> **Plain English:** grading costs more than answering. Each question is
> answered once and then marked three times, so the bill is roughly four
> model calls per question, and asking more questions raises it in
> proportion.
