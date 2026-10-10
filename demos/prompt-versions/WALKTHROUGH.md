# Walkthrough — prompt versions

**6 minutes.** The third act: *we know retrieval works and we can score
answers — so which prompt should we ship?*

Open `openrag-prompt-versions`, workspace `rag-eval`.

## 1. The question (30s)

> "Prompts normally change by someone editing a string in a source file.
> No record of what the previous one was, no evidence the change helped.
> We treat them like code everywhere else. Why not here?"

## 2. The registry (1 min)

**Prompts & versions → Prompts** → `openrag-rag-answer`, three versions,
each with a commit message:

```
v1  terse: no guidance beyond the task
v2  grounded: forbid invention, allow refusal
v3  grounded + cite: same, but attribute the claim
```

> "A prompt is now a registry artifact with a version and a commit message.
> The agent references it by URI — the string is not in the source."

Show the line that matters:

```python
mlflow.genai.load_prompt(f"prompts:/{name}/{version}")
```

## 3. The result (2 min)

**Evaluation runs**, or the three nested runs under `prompt-version-ab`:

```
v   strategy                     correctness   grounded   relevance
1   terse                              0.900      1.000       1.000
2   grounded, allow refusal            0.900      1.000       1.000
3   grounded + cite source             0.800      1.000       0.800
```

> "The elaborate prompt lost. Numbered rules, a length limit and a citation
> requirement scored *worse* than two lines. More instruction is not better,
> and you would never know from reading them."

That's the demo. It's a better result than "the careful prompt won" because
it's the one nobody expects.

## 4. Why it beats eyeballing (1 min)

> "Three people would have three opinions about which of these prompts is
> best. This is the same questions, same retrieval, same judges, varying one
> thing. That's the difference between an opinion and a measurement."

## Say these before anyone else does

**Ten questions means 0.1 is one item.** The v1/v3 gap is a single
question. Directionally interesting, not significant.

**`grounded` is 1.000 across the board, so it is telling you nothing here.**
Every question was generated *from* a chunk that retrieval then found, so
nothing was ever tempted to invent. Making that scorer discriminate needs
adversarial questions the corpus genuinely cannot answer — which is the
obvious next iteration, and worth saying out loud.
