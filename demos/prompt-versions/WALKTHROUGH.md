# Walkthrough — prompt versions

**6 minutes.** The third act: *we know retrieval works and we can score
answers — so which prompt should we ship?*

## Before you start

Open `openrag-prompt-versions`, workspace `rag-eval`.

MLflow is at `https://<data-science-gateway>/mlflow`, and the experiment
URL keeps `?workspace=rag-eval` on the end. The bare path lands in a
different workspace with an empty experiment list, which looks exactly like
nothing ever ran.

Down the left sidebar, top to bottom: the workspace pill (it should read
**rag-eval**), the **GenAI** | **Model training** toggle, then a back-arrow
button naming the experiment you are in. Everything below is under
**GenAI** — set that toggle once and leave it.

## In plain English

The instruction you give a model — the actual wording of the request — is
normally a line of text buried in somebody's code. Someone edits it, the
system starts behaving differently, and there is no record of what the old
wording was or whether the change helped. This demo puts three wordings of
the same instruction on file with version numbers, asks the same ten
questions through each of them, and scores the answers. The shortest one,
with no guidance at all beyond the question, did at least as well as the
other two and better than the most elaborate — which is the sort of thing
you only find out by measuring.

## 1. The question (30s)

**Tell** — ask this before opening anything. It is the one part of the demo
where the room gets to have an opinion, and it is what makes the result
land later.

> "Prompts normally change by someone editing a string in a source file.
> No record of what the previous one was, no evidence the change helped.
> We treat them like code everywhere else. Why not here?"

**Show** — nothing to click. Leave the screen on the experiment and let
someone answer.

**Tell** — whatever they say, nobody can point at where the previous
wording went. That is the gap the rest of this closes.

## 2. The registry (1 min)

**Tell** — establish first that the prompt is an object on the platform
rather than a line someone owns in a repository. Three wordings of the same
instruction, on file, each with a version number.

**Show**

Sidebar **GenAI** → **Prompts & versions** → **Prompts** →
`openrag-rag-answer`, three versions, each with a commit message:

```
v1  terse: no guidance beyond the task
v2  grounded: forbid invention, allow refusal
v3  grounded + cite: same, but attribute the claim
```

Show the line that matters:

```python
mlflow.genai.load_prompt(f"prompts:/{name}/{version}")
```

**Tell**

> "A prompt is now a registry artifact with a version and a commit message.
> The agent references it by URI — the string is not in the source."

> **Plain English:** these are three wordings of the same instruction, kept
> side by side like three drafts of a letter. Each has a version number and
> a line saying what changed, so you can always get back to the one you had
> last month.

> **Plain English:** the code asks for the prompt by name and version, the
> way you would cite a particular edition of a book rather than the title
> alone. Changing the wording means publishing a new version, not quietly
> editing a line in a file.

## 3. The result (2 min)

**Tell** — same ten questions, same retrieval, same judges, three prompts.
Ask the room which one they would ship before you show the scores. Most
pick the most careful-looking one.

**Show**

Sidebar **GenAI** → **Evaluation** → **Evaluation runs**, or the three
nested runs under `prompt-version-ab`.

To get them side by side: in the experiment's run list, tick the
checkboxes of the three per-version runs under `prompt-version-ab`, then
press **Compare**. The page is headed "Comparing 3 runs from 1 experiment",
and the **Run details** table at the bottom — Run ID, Run Name, Start Time,
End Time, one column per run — confirms you have the right three.

Under **Visualizations**, the **Parallel Coordinates Plot** tab puts the
versions and their scores on one chart:

- **Parameters:** `prompt_version`, `strategy`
- **Metrics:** the three scorer chips — correctness, grounded, relevance

**Clear All** empties both dropdowns if the chart arrives with other chips
already in place.

The numbers either way:

```
v   strategy                     correctness   grounded   relevance
1   terse                              0.900      1.000       1.000
2   grounded, allow refusal            0.900      1.000       1.000
3   grounded + cite source             0.800      1.000       0.800
```

**Tell**

> **Plain English:** each column is a score between 0 and 1, averaged over
> the ten questions, so 0.900 means nine out of ten. The marking is done by
> a model acting as a judge rather than by a person: *correctness* is
> whether the answer is right, *relevance* whether it addresses the
> question that was asked.

> "The elaborate prompt lost. Numbered rules, a length limit and a citation
> requirement scored *worse* than two lines. More instruction is not better,
> and you would never know from reading them."

That's the demo. It's a better result than "the careful prompt won" because
it's the one nobody expects.

> **Plain English:** the long prompt is the one that looks like more care
> went into it — numbered rules, a length cap, a citation requirement — and
> it still scored worse. Reading the three would not have told you that;
> running them did.

## 4. Why it beats eyeballing (1 min)

**Tell** — close on method rather than on the result. The question forming
in the room is whether the difference came from the wording or from luck.

**Show** — nothing new to open. Stay on the three rows of scores from step
3. If anyone asks who did the marking, the judges are listed at Sidebar
**GenAI** → **Evaluation** → **Judges**.

**Tell**

> "Three people would have three opinions about which of these prompts is
> best. This is the same questions, same retrieval, same judges, varying one
> thing. That's the difference between an opinion and a measurement."

> **Plain English:** retrieval is the step that goes and finds the relevant
> documents before the model writes anything. Holding it still — same
> questions, same documents, same judges — means any difference in the
> scores can only have come from the wording.

## Say these before anyone else does

**Ten questions means 0.1 is one item.** The v1/v3 gap is a single
question. Directionally interesting, not significant.

> **Plain English:** with ten questions, one question is worth 0.1. The gap
> between 0.900 and 0.800 is a single answer going the other way, which is
> a hint rather than a finding.

**`grounded` is 1.000 across the board, so it is telling you nothing here.**
Every question was generated *from* a chunk that retrieval then found, so
nothing was ever tempted to invent. Making that scorer discriminate needs
adversarial questions the corpus genuinely cannot answer — which is the
obvious next iteration, and worth saying out loud.

> **Plain English:** a score that everything passes is not measuring
> anything, in the way that an exam nobody fails tells you about the exam
> rather than about the candidates.
