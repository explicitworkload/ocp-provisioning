"""Token usage and modelled cost on MLflow spans.

MLflow's Overview -> Usage tab reads two span attributes:

    mlflow.chat.tokenUsage   {input_tokens, output_tokens, total_tokens}
    mlflow.llm.cost          {input_cost, output_cost, total_cost}

Set neither and the Token usage, Tokens per trace, Cost breakdown and Cost
over time panels all read zero, which is how these demos started out -
LiteLLM returns a `usage` block on every response and the demos discarded it.

## Why cost has to be supplied by hand here

MLflow does compute cost on its own, server-side in
sqlalchemy_store.log_spans(), by calling LiteLLM's cost_per_token(). That
works for commercial endpoints: gpt-4o-mini prices at $0.00015/$0.0003 per
1K. It cannot work for ours. Asked about qwen3-4b, LiteLLM raises
"LLM Provider NOT provided" - there is no public price for a model running
on your own card.

Registering a price with the LiteLLM *proxy* does not help either, because
the lookup happens inside the MLflow server pod, not the proxy. What does
work is setting mlflow.llm.cost on the span ourselves: the server reads and
aggregates that attribute rather than recomputing it, so a value supplied
here survives storage.

## What the numbers mean, and their honest status

These are MODELLED, not billed. A self-hosted model has no per-token price;
it has a per-hour one. The model below converts the second into the first:

    cost per token = instance $/hour / 3600 / tokens per second

Throughput is measured on this cluster, from the vLLM server's own log
lines ("Avg prompt throughput: 183.7 tokens/s, Avg generation throughput:
29.3 tokens/s" for qwen3-4b on a T4). The hourly rate is the AWS on-demand
list price and is the number most worth arguing about - it ignores reserved
pricing, ignores the node sitting idle between requests, and ignores every
other pod sharing the box.

So treat the figure as "what a token costs in GPU-seconds at full tilt",
which is a floor, not a bill. Say that out loud if you show it.
"""

from __future__ import annotations

import mlflow
from mlflow.tracing.constant import SpanAttributeKey

# instance $/hour -> $/second. Adjust to your actual rate; on-demand list
# price is the pessimistic end for anything long-running.
GPU_HOURLY = {
    "g4dn.4xlarge": 1.204,   # 1x T4, 16 GiB
    "g6e.4xlarge": 2.242,    # 1x L40S, 48 GiB
    "g6e.12xlarge": 10.493,  # 4x L40S
}

# Measured on this cluster from vLLM's own throughput logs. Re-measure after
# changing model, card or max-num-seqs - all three move these numbers.
MODEL_PROFILE = {
    "qwen3-4b": {
        "instance": "g4dn.4xlarge",
        "prompt_tps": 183.7,
        "generation_tps": 29.3,
    },
}


def price_per_token(model: str):
    """($/input token, $/output token), or None for models we do not host.

    Returns None rather than guessing for remote MaaS endpoints: we do not
    pay for their GPU-hours and have no basis for a figure. A wrong cost is
    worse than a blank one.
    """
    prof = MODEL_PROFILE.get(model)
    if not prof:
        return None
    per_second = GPU_HOURLY[prof["instance"]] / 3600.0
    return (per_second / prof["prompt_tps"], per_second / prof["generation_tps"])


def record_usage(usage: dict, model: str) -> None:
    """Attach token usage, and modelled cost where we can justify one.

    Call inside an active span - typically the one wrapping the LLM call.
    `usage` is LiteLLM's usage block, straight from the response.
    """
    span = mlflow.get_current_active_span()
    if span is None or not usage:
        return

    prompt = int(usage.get("prompt_tokens") or 0)
    completion = int(usage.get("completion_tokens") or 0)
    span.set_attribute(SpanAttributeKey.CHAT_USAGE, {
        "input_tokens": prompt,
        "output_tokens": completion,
        "total_tokens": int(usage.get("total_tokens") or prompt + completion),
    })

    rate = price_per_token(model)
    if rate is None:
        # Deliberately no cost attribute. The panels then show tokens for
        # this model and no money, which is the truthful rendering.
        return
    in_rate, out_rate = rate
    input_cost = prompt * in_rate
    output_cost = completion * out_rate
    span.set_attribute(SpanAttributeKey.LLM_COST, {
        "input_cost": input_cost,
        "output_cost": output_cost,
        "total_cost": input_cost + output_cost,
    })
