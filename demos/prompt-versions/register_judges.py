"""Register judges on the experiment so they persist and are reusable.

Passing scorers to `mlflow.genai.evaluate(scorers=[...])` runs them ad hoc:
the scores land on the run, but nothing is stored about the judges
themselves, so the Judges tab stays empty and the next evaluation has to
re-declare them in code. Registering makes a judge a first-class object on
the experiment - visible in the UI, fetchable with `get_scorer`, and
versioned when its definition changes.

The distinction is easy to miss because the evaluation looks completely
successful either way.

Also registers one CUSTOM judge via `make_judge`, which is the more
interesting half: the built-ins score generic qualities, while a custom
judge encodes a rule that matters for this corpus specifically.
"""

from __future__ import annotations

import os

import mlflow
import mlflow.genai
from mlflow.genai.judges import make_judge
from mlflow.genai.scorers import Correctness, Guidelines, RelevanceToQuery

EXPERIMENT = os.environ.get("MLFLOW_EXPERIMENT", "openrag-prompt-versions")
JUDGE = os.environ.get("MLFLOW_GENAI_JUDGE_DEFAULT_MODEL",
                       "openai:/granite-3-2-8b-instruct")


def main():
    exp = mlflow.set_experiment(EXPERIMENT)
    eid = exp.experiment_id
    print(f"experiment {EXPERIMENT} (id={eid}), judge model {JUDGE}", flush=True)

    builtin = [
        Correctness(model=JUDGE),
        RelevanceToQuery(model=JUDGE),
        Guidelines(
            name="grounded",
            guidelines=("The response must be supported by the retrieved context. "
                        "If the context does not contain the answer, it must say "
                        "it does not know."),
            model=JUDGE,
        ),
    ]

    # A judge specific to this corpus rather than a generic quality. The
    # OpenRAG docs are technical, so an answer that is correct but vague
    # ("configure the setting appropriately") is useless to a reader - and
    # none of the built-in scorers penalise it.
    custom = make_judge(
        name="actionable",
        instructions=(
            "You are judging answers about technical documentation.\n\n"
            "Rate whether the response in {{ outputs }} is ACTIONABLE for the "
            "question in {{ inputs }}: does it name the specific setting, "
            "command, file or value a reader would need, rather than "
            "describing what to do in general terms?\n\n"
            "Answer 'yes' if a reader could act on it without consulting "
            "anything else. Answer 'no' if it is correct but too vague to use."
        ),
        model=JUDGE,
        description="Is the answer specific enough to act on?",
    )

    for s in builtin + [custom]:
        try:
            r = s.register(experiment_id=eid)
            print(f"  registered {getattr(r, 'name', s.name)}", flush=True)
        except Exception as exc:
            print(f"  {s.name}: {type(exc).__name__}: {exc}", flush=True)

    print("\nregistered judges on this experiment:", flush=True)
    for s in mlflow.genai.list_scorers(experiment_id=eid):
        print(f"  {s.name}", flush=True)


if __name__ == "__main__":
    main()
