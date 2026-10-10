"""Token usage and cost on MLflow spans, taken from LiteLLM.

MLflow's Overview -> Usage tab reads two span attributes:

    mlflow.chat.tokenUsage   {input_tokens, output_tokens, total_tokens}
    mlflow.llm.cost          {input_cost, output_cost, total_cost}

Set neither and Token usage, Tokens per trace, Cost breakdown and Cost over
time all read zero, which is how these demos started out - LiteLLM returns
both a usage block and a cost header on every response, and the demos were
discarding them.

## Why cost is read from LiteLLM rather than computed here

MLflow does compute cost on its own, server-side in
sqlalchemy_store.log_spans(), by calling LiteLLM's cost_per_token(). That
works for commercial endpoints - gpt-4o-mini prices fine - but asked about
qwen3-4b it raises "LLM Provider NOT provided", because MLflow's own copy of
LiteLLM has no entry for a model served from this cluster.

Registering the price on the model in the LiteLLM PROXY fixes it at the
source instead: the proxy then computes cost per request and returns it as
the x-litellm-response-cost-original header. One place to maintain, every
client benefits, and LiteLLM's own budget and spend tracking start working
too. This module just forwards that number onto the span, where MLflow
aggregates it rather than recomputing.

So there is deliberately NO pricing table here. If a cost looks wrong, fix
the model in LiteLLM, not this file:

    POST /model/update
      {"model_id": "...",
       "litellm_params":  {..., "input_cost_per_token": X, "output_cost_per_token": Y},
       "model_info":      {"id": "...", "input_cost_per_token": X, "output_cost_per_token": Y}}

model_info is required - omit it and the call fails with
"model_info not provided".

## What the numbers mean

For the MaaS models the rates are the real published RHDPS subscription
prices, so the figures are what the usage actually costs.

qwen3-4b is the exception and is MODELLED, because a model on your own card
has no per-token price - it has a per-hour one. Its rate is
instance $/hour / 3600 / measured tokens per second, from the vLLM server's
own throughput logs. Treat it as what a token costs in GPU-seconds at full
tilt: a floor, not a bill. It ignores reserved pricing, the node sitting
idle between requests, and everything else sharing the box.
"""

from __future__ import annotations

import mlflow
from mlflow.tracing.constant import SpanAttributeKey

COST_HEADER = "x-litellm-response-cost-original"


def _cost_from_headers(headers) -> float:
    """LiteLLM's calculated cost, whatever it chose to call the header.

    Two spellings occur, and which one you get depends on the route rather
    than on anything you control:

        x-litellm-response-cost-original                 direct call
        llm_provider-x-litellm-response-cost-original    relayed call

    The second appears when the model is itself behind another endpoint -
    every MaaS model here, reached through the in-cluster service - because
    LiteLLM prefixes headers it passes through from an upstream provider.
    Matching only the bare name silently finds nothing for exactly the
    models whose cost is a real published price, which is how this was
    first written.
    """
    if not headers:
        return 0.0
    exact = headers.get(COST_HEADER)
    if exact is None:
        for name, value in headers.items():
            if name.lower().endswith(COST_HEADER):
                exact = value
                break
    try:
        return float(exact or 0.0)
    except (TypeError, ValueError):
        return 0.0


def record_usage(usage: dict, headers=None) -> None:
    """Attach token usage, and cost when LiteLLM reports one.

    Call inside an active span - normally the one wrapping the LLM call.

    Args:
        usage: LiteLLM's usage block, straight off the response body.
        headers: the response headers, for the cost LiteLLM calculated.
            Omit them and tokens are still recorded; only cost is lost.
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

    total = _cost_from_headers(headers)
    if total <= 0:
        # A model with no price registered in LiteLLM. Record tokens and no
        # money rather than inventing a figure - a blank cost is honest, a
        # wrong one is not.
        return

    # LiteLLM reports one total. Split it by token share so the Cost
    # breakdown panel has an input/output split to draw; the total, which is
    # the number anyone acts on, stays exactly what LiteLLM calculated.
    tokens = prompt + completion
    in_share = (prompt / tokens) if tokens else 0.0
    span.set_attribute(SpanAttributeKey.LLM_COST, {
        "input_cost": total * in_share,
        "output_cost": total * (1.0 - in_share),
        "total_cost": total,
    })
