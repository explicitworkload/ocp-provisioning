# Prompt versions, compared

Three versions of the same RAG answering prompt, registered in MLflow's
Prompt Registry, evaluated head to head with the same questions and the
same judges. The output is a ranking rather than an opinion.

Prompts normally change by editing a string in a source file — no record of
what the previous one was, no evidence the change helped. Here the prompt is
a registry artifact with a version and a commit message, the agent loads it
by URI, and the evaluation says which one to ship.

Fills four GenAI sections that are otherwise empty: **Prompts**,
**Datasets**, **Evaluation runs** and **Traces**.

## Running it

```bash
oc -n rag-eval delete job prompt-versions --ignore-not-found
oc create configmap prompt-versions-script -n rag-eval \
  --from-file=prompt_ab.py=demos/prompt-versions/prompt_ab.py \
  --dry-run=client -o yaml | oc apply -f -
oc apply -f demos/prompt-versions/job.yaml
oc -n rag-eval logs -f job/prompt-versions
```

About four minutes for three versions over ten questions. Cost is roughly
`versions × questions × 4` model calls — one retrieval, one generation and
three judge calls each — so raise `N_QUESTIONS` deliberately.

Reuses the `rag-eval` namespace and credentials from
[../rag-eval](../rag-eval). Set those up first.

## The three variants

Deliberately different in *kind* rather than in wording, so the comparison
says something about approach rather than synonyms:

| v | strategy |
|---|---|
| 1 | terse — no guidance beyond the task |
| 2 | grounded — forbid invention, allow refusal |
| 3 | grounded + cite — same, plus attribute the claim and cap the length |

## Result

```
v   strategy                     correctness   grounded   relevance
1   terse                              0.900      1.000       1.000
2   grounded, allow refusal            0.900      1.000       1.000
3   grounded + cite source             0.800      1.000       0.800
```

**The elaborate prompt lost.** v3 — numbered rules, a length limit, a
citation requirement — scored worse on correctness and relevance than two
lines of instruction.

Two caveats that belong beside that number:

**Ten questions means 0.1 is one item.** The v1/v3 gap is a single
question. Directionally interesting, not significant.

**`grounded` is 1.000 everywhere, so it is not discriminating here.** Every
question was generated *from* a chunk that retrieval then found, so nothing
was tempted to invent. Making it meaningful needs adversarial questions the
corpus genuinely cannot answer.

## Notes

`mlflow.genai.register_prompt` with the same `name` creates a new version
each run, so re-running grows the version history rather than overwriting —
which is the behaviour you want, but means version numbers climb.

Prompt templates use `{{double braces}}`; `PromptVersion.format(**kwargs)`
renders them.

`mlflow.genai.optimize_prompt` exists in 3.14 but has no docstring and an
opaque signature, so these variants are hand-written. Worth revisiting.
