# `group_vars/all.yml` reference

What every variable in `all.yml` does and why it is set the way it is.
`all.yml.sample` deliberately carries no prose — see "Why this file exists"
at the bottom.

`all.yml` itself is untracked, so a pull secret, API key or endpoint
credential can live in it without a stray `git add -A` publishing it. The
tracked copy is `all.yml.sample`, and it must stay free of real values.

When you add a variable to `all.yml`, add it to `all.yml.sample` too — with
the value left empty or an example — and describe it here. Nothing enforces
that; a drifting sample is how the next person ends up with a cluster
configured entirely by role defaults.

Most of these also have a default in the owning role's `defaults/main.yml`,
and that is where the deepest technical detail lives. This file is the
operator's view; the role defaults are the implementer's.

## You may not need to edit it by hand

`./run.sh` with no arguments, on a terminal, prints what is configured and
offers to change it. It can set `ocp_context` (from a menu of your actual
kubeconfig contexts), `model_preset`, `gpu_machinesets`, `deploy_openrag`,
`deploy_milvus`, `deploy_demos`, `deploy_omnigent`, `hf_token`,
`litellm_extra_models` (querying the endpoint for its model list), and the
two `dashboard_aws_*` keys.

It writes only values that change an outcome, so it will not fill your file
with keys that merely restate a role default. Everything else here is still
edited by hand.

---

## Cluster context

### `ocp_context`

Which OpenShift cluster to act on.

Empty means whatever `oc config current-context` points at, so a rebuilt
sandbox needs no commit here. Pinning a name is still supported and is worth
doing when more than one cluster is in reach of the same kubeconfig.

### `ocp_expected_api`

Seatbelt for the empty default above. When set, the target cluster's
`apiServerURL` must contain this substring or the run aborts before it
changes anything. Unset means no check — just the banner the preflight
prints.

Worth setting for a destructive re-run: this playbook creates MachineSets,
installs cluster-wide operators and rotates database passwords, so a run
against the wrong context costs more than a run that simply fails.

```
./run.sh -e ocp_expected_api=sandbox1234
```

### `ocp_context_arg`

Derived. What shell tasks interpolate instead of `--context {{ ocp_context }}`.
You should not need to change it.

`| quote` on an empty string renders the two characters `''` — and bash does
not strip quotes from the result of a parameter expansion, so

```
OC="oc --context '' -n openshift-storage"; $OC get ...
```

word-splits into five argv entries and `oc` is handed a context literally
named `''`, failing every call with `error: context "''" does not exist`.
Tasks that redirect stderr to `/dev/null` then read that as "nothing found"
rather than as an error, which is how it stays invisible.

So the flag has to disappear entirely when nothing is pinned, not become an
empty argument. Module tasks use `{{ ocp_context or omit }}` for the same
reason; this is the shell equivalent.

---

## GPU workers

### `gpu_availability_zone`

Empty is derived from the cluster's worker MachineSets, so pointing the
playbook at a cluster in another region just works. Set it to pin a zone.

### `gpu_volume_size`

Root volume size in GB for GPU workers.

### `gpu_machinesets`

The list of GPU MachineSets to create, as `instance_type` plus `replicas`.
Every type `run.sh` offers in its menu has to appear here, even at zero
replicas — the zero-replica entries are created as scale-up-ready
placeholders.

**Keep this block free of comments.** `run.sh` rewrites it with `awk`, and
that `awk` ends the block at the first line starting with neither a space
nor a dash — which a `#` comment matches. A comment between entries makes
`run.sh` insert a duplicate entry at `replicas: 1` while leaving the
original at `replicas: 0`; the role then re-applies the same MachineSet
name at zero and scales away the node it just provisioned. See
`roles/gpu_worker/tasks/main.yml`, "Create the scale-up-ready MachineSets
alongside the one that worked".

Notes on the types in the sample:

- `g6e.12xlarge` is needed by the bf16 `qwen3.8-27b` preset, which wants
  four GPUs on one node.
- `g7e.2xlarge` / `4xlarge` / `8xlarge` carry one RTX PRO 6000 Blackwell
  each, 96 GB — twice an L40S on a single card, so a model that needed four
  GPUs on a `g6e.12xlarge` may fit on one of these. They differ only in
  vCPU and host RAM (8/64, 16/128, 32/256).
- `g7e.12xlarge` and `g7e.24xlarge` are where g7e actually adds cards: 2 and
  4 respectively. A 2-GPU `g7e.12xlarge` holds 192 GB, the same as four L40S
  on a `g6e.12xlarge`, in half the cards.

Capacity fallback — what happens when the requested type is unavailable in
every zone — is configured in `roles/gpu_worker/defaults/main.yml`
(`gpu_fallback_mode`, `gpu_instance_fallback`, `gpu_requested_rounds`).

#### Asking for more than one type at once

Two things on this cluster want a GPU and neither can share one: the served
model and the GPU workbench. There is no MIG and no time-slicing here, so a
node with one card satisfies exactly one of them. With the sample's single
entry at `replicas: 1` that is the whole story — one card, and whichever of
the two is scheduled first gets it.

To give the workbench a card of its own, raise a **second** entry to
`replicas: 1`. The run then pins the two deliberately:

| | gets |
|---|---|
| served model | the type with the most GPUs, breaking ties on card memory |
| GPU workbench | the type with the fewest |

Ranked by capacity, not by position in the list, so the order you write the
entries in does not change the outcome — listing `g6e.4xlarge` before
`g6e.12xlarge` will not put a four-GPU preset on the one-card node. The
ranking is `gpu_serving_instance_type` / `gpu_workbench_instance_type` in
`roles/gpu_worker/defaults/main.yml`; override either end with
`model_gpu_instance_type`.

A second entry at `replicas: 2` of the *same* type works too, and separates
on GPU count rather than on instance type.

**This costs you capacity odds, and that is the real trade.** Every
non-zero type is attempted *together in the same availability zone*, and a
zone only counts as successful once **every** requested MachineSet has
`readyReplicas`. Asking for two scarce types is therefore strictly worse
odds than asking for one — one type short in a zone fails the whole zone and
moves the run on to the next. If GPU capacity is already hard to come by on
the account, take the single card and let the two contend for it.

---

## Model serving

### `model_preset`

One name sets the image, GPU count, context length and resource limits
together. Full definitions, including why each context length is what it is,
are in `roles/model_serving/defaults/main.yml`.

| Preset | Precision | Source | GPUs | Weights | Context |
|---|---|---|---|---|---|
| `qwen3-4b` | bf16 | modelcar | 1 | 8 GB | 32k |
| `qwen3-8b` | bf16 | modelcar | 1 | 16 GB | 40k |
| `qwen3-14b` | bf16 | modelcar | 1 | 29 GB | 40k |
| `qwen3.8-27b` | bf16 | modelcar | 4 | 56 GB | 256k |
| `qwen3.8-27b-fp8` | FP8 | Hugging Face | 1 | 31 GB | 64k |

40k is the whole native length of the dense Qwen3 models. Only `qwen3-4b` is
held below its own — its default `g4dn.4xlarge` has a 16 GB T4, and weights
plus 32k of cache is all of it. Set `model_max_model_len` to `40960` by hand
if it is going on a 48 GB card.

The GPU instance is chosen separately, in `gpu_machinesets` above — you pick
the hardware. The run prints a fit check before it changes anything, so a
model that cannot fit the instance you chose is called out rather than
discovered at model load.

`qwen3.8-27b` needs four GPUs on one node: `g6e.12xlarge` is the smallest
that has them, and with that much VRAM it serves the model's full native
256k. `qwen3.8-27b-fp8` fits one L40S but downloads ~31 GB from Hugging Face
at pod start instead of pulling a cached image, and one card caps it at 64k.

### `hf_token`

Hugging Face token. Only the `hf://` presets need it — today just
`qwen3.8-27b-fp8` — and a run that selects one without it fails before
anything is created rather than after a 28 GB download returns 401.

Safe to put a real token in `all.yml`: that file is untracked. Never put one
in `all.yml.sample`.

---

## Console

### `console_plugins`

Console plugins to enable.

---

## Quay

### `deploy_quay_registry`

With ODF installed, Quay can use managed object storage (NooBaa). True
deploys the `QuayRegistry` CR.

### `quay_s3_bucket`, `quay_s3_region`, `quay_s3_access_key`, `quay_s3_secret_key`

Only needed when ODF is not available. Commented out in the sample.

---

## Operations dashboard

### `dashboard_aws_access_key_id`, `dashboard_aws_secret_access_key`

Dedicated AWS key for the dashboard's node Stop/Start resiliency tests.
Needs only `ec2:DescribeInstances`, `ec2:StopInstances`, `ec2:StartInstances`.

Leave empty in the sample and supply them one of these ways:

1. **Already in the cluster.** If the `ops-dashboard-aws` Secret exists in
   the dashboard namespace it is used as-is and these can stay empty.
2. **At runtime, kept out of shell history:**
   ```
   read -rs AWS_KEY; read -rs AWS_SECRET
   ansible-playbook site.yml --tags dashboard \
     -e dashboard_aws_access_key_id="$AWS_KEY" \
     -e dashboard_aws_secret_access_key="$AWS_SECRET"
   ```
3. **From a vault file** (`ansible/**/vault.yml` is gitignored):
   ```
   ansible-playbook site.yml -e @vault.yml --tags dashboard
   ```

When set, these overwrite the cluster Secret. The cluster's own machine-api
credential is deliberately NOT reused: scaling uses `ec2:RunInstances` /
`TerminateInstances`, which does not imply Stop/Start. Destroy & Rebuild
needs none of this — it is pure Machine API.

---

## MCP server

### `mcp_write_rules`

Write permissions handed to callers of the OpenShift MCP server — both the
Operations Dashboard AI assistant and the server's own `mcp-viewer` identity.
Paired with `cluster-reader`, which supplies read on everything else.

Deliberately omitted, because an LLM drives these tools:

| Omitted | Why |
|---|---|
| `secrets` | would expose the pull secret, LiteLLM key, Cloudflare token and the dashboard password |
| `rolebindings` / `roles` | self-escalation back to cluster-admin |
| `serviceaccounts` | token minting is escalation by another route |
| `pods/exec`, `attach` | a shell in any container sidesteps every limit above |

The MCP server itself still runs `read_only = false`; this ClusterRole, not
that flag, is what actually bounds the blast radius.

---

## OpenRAG

### `deploy_openrag`

Document RAG platform (Langflow + OpenSearch + Docling).

It adds a 3-node OpenSearch cluster (~9Gi RAM, 3×20Gi PVCs) plus
`docling-serve` and a CPU embedding model, which is a lot to carry on a
cluster that is not using it.

### `openrag_auto_configure`

Configure OpenRAG without anyone clicking through its setup wizard: point it
at the cluster's own models through LiteLLM using OpenRAG's Red Hat OpenShift
AI provider, and advance the wizard's step counter past the end.

False leaves a freshly deployed OpenRAG on its first-run wizard, for setting
up by hand. Doing it by hand is not equivalent: the wizard offers only the
providers OpenRAG advertises, and whoever clicks through picks a model from
whatever LiteLLM happens to serve — on this cluster that included the Azure
model, which does not exist where Lightspeed is absent.

---

## Milvus

### `deploy_milvus`

A vector database, with Attu as its UI, published to RHOAI's Vector stores
tab. It is a third vector store next to the OpenSearch that `openrag` deploys
and the pgvector the Gen AI playground ships with — on by default because
demo 1 exists to compare the three, and demo 7 (AutoRAG) uses Milvus as its
`vector_io` provider. Turn it off and those two have nothing to measure.

Milvus is in no operator catalog, so this comes from the upstream zilliztech
Helm chart — needs the `helm` CLI, like `openrag` — and carries no Red Hat
support path. Object storage is the cluster's own NooBaa rather than a
bundled MinIO, so ODF has to be up.

The Milvus image declares no `USER` and will not run as anything but root, so
the role grants `anyuid` to a dedicated service account in the `milvus`
namespace. Everything else there stays non-root.

---

## Omnigent

### `deploy_omnigent`

An open-source meta-harness that orchestrates agent CLIs — Claude Code,
Codex, Cursor, Pi — behind one server with policies, sandboxing and live
session sharing. <https://omnigent.ai>, Apache-2.0.

Logs in with your OpenShift identity through an `oauth-proxy`, and gets its
models from the cluster's own LiteLLM, so it needs no provider key of its
own. Needs the `litellm` role to have run.

### `omnigent_sandboxes`

Agent sessions run as their own short-lived Pods in an `omnigent-sandboxes`
namespace rather than inside the server. The server gets create/delete on
Pods and Secrets THERE and nowhere else, deliberately without `pods/exec` —
but the code those Pods run is written by a model, so this is a real decision
rather than a default to skim past.

False keeps agents in the server pod and grants nothing.

### `omnigent_version`

Pinned, and not to `latest`: this is v0.1.x software that runs LLM-authored
code with real credentials.

### `omnigent_sandbox_provider`

Which runtime an agent session actually runs in. `kubernetes` or `openshell`.

`kubernetes` is the tested path: each session is a Pod in
`omnigent-sandboxes`, and the boundary is Kubernetes RBAC plus the
namespace. Nothing confines what the agent does *inside* that Pod.

`openshell` hands sessions to [NVIDIA OpenShell](https://github.com/NVIDIA/OpenShell),
which adds Landlock on the filesystem, seccomp on syscalls, and a
deny-by-default egress proxy that brokers credentials so the agent holds
placeholders rather than keys. It is a first-party Omnigent provider, not
something assembled here — upstream ships a 635-line launcher, an 849-line
test file and a kustomize overlay for it — and it needs `deploy_openshell`
as well, plus OpenShift 4.19 or later.

**Untested.** It was written from upstream documentation with no cluster
available; see `deploy_openshell`.

---

## Gen AI playground

### `deploy_genai_playground`

Correct the configuration RHOAI's Gen AI BFF generates for the playground.
On by default, because without it the playground is wrong in ways that only
surface minutes into an AutoRAG run.

RHOAI generates `llama-stack-config` from the `gen-ai-aa-*` ConfigMaps by
unmarshalling them into typed Go structs, silently discarding any key it has
no field for. On sandbox544 the result had no API key on the LiteLLM
provider at all — so every model answered 401 and AutoRAG reported seven of
them as "registered in OGX but do not respond" — plus twelve duplicate
copies of that provider, no Milvus, and a vLLM provider whose token was the
literal string `fake`.

The role reads what the BFF generated, keeps an untouched copy, and writes a
corrected version back: the key wired from `endpoint-api-key-1`, providers
deduplicated, dead ones dropped, Milvus registered with all three fields its
config requires, and `allowed_models` narrowed so a document converter is
not offered as something to chat with.

Note what `OGXServer.spec.overrideConfig` costs, because it is already set
on this cluster and this role keeps it that way: while it points anywhere,
the `gen-ai-aa-*` ConfigMaps are **not read at all**. Everything the
playground uses comes from that one file. See
[demos/autorag/README.md](../../demos/autorag/README.md), "Where that
setting actually lives on this cluster".

---

## OpenShell

### `deploy_openshell`

Deploy the NVIDIA OpenShell gateway and the Agent Sandbox controller, so
`omnigent_sandbox_provider: openshell` has something to talk to. Only read
when that provider is selected — a gateway nothing uses is a StatefulSet
nobody asked for, so `site.yml` gates on both.

**Nothing in this role has been run against a cluster.** Every version in
it was checked to exist in its registry, but that is a long way from the
gateway coming up and Omnigent reaching it. Four things are marked
`FIRST RUN` in `roles/openshell/tasks/main.yml` as the most likely to need
work; the biggest is that the sandbox egress policy is rendered into a
ConfigMap but not yet mounted into the gateway, because upstream documents
four policy sources without naming the Helm value that supplies the first.
Until that is wired, sandboxes get OpenShell's built-in default policy,
which is restrictive enough to block the Omnigent callback and LiteLLM.

Requires OpenShift 4.19+. The RHCOS kernels in 4.16 through 4.18 are built
without Landlock, so every sandbox fails its startup probe; the role checks
the cluster version and refuses rather than letting that happen later.

The gateway needs no `privileged` SCC and no added Linux capability —
its driver reads the namespace's `openshift.io/sa.scc.uid-range` and runs
non-root under the restricted posture, which is unusual enough for a
kernel-level sandbox to be worth saying.

---

# Optional

Nothing below this point is necessary.

## Zero Trust Workload Identity Manager

### `deploy_ztwim`

SPIFFE/SPIRE. Deploys a SPIRE server StatefulSet plus an agent and CSI-driver
DaemonSet on every node, so workloads can obtain cryptographic identities
(SVIDs) instead of long-lived secrets.

The trust domain defaults to the cluster's apps domain and is **immutable**
once the CR is created — see `roles/ztwim/defaults/main.yml` to override
before the first run.

---

## External DNS / Cloudflare

Runs last in the playbook.

### `deploy_external_dns`

Off by default. Enable only when you want real records written to the
Cloudflare zone:

```
ansible-playbook site.yml -e deploy_external_dns=true
```

### `external_dns_domain`

The Cloudflare zone ExternalDNS manages.

### `cloudflare_api_token`

Needs `Zone:Read` + `DNS:Edit` on the zone above. If set, it takes precedence
and overwrites the cluster Secret. Leave it empty in `all.yml.sample`.

### `external_dns_cloudflare_proxied`

Publish records through the Cloudflare proxy (orange cloud) so Cloudflare
terminates TLS with its own `kubernetes.day` certificate — this is what
avoids the browser cert warning, since the cluster wildcard only covers
`*.apps`. Requires the zone's SSL/TLS mode to be "Full" (see
`ansible/README.md`).

### `dashboard_custom_host`, `devspaces_custom_host`

Extra Routes on the ExternalDNS-managed domain are named automatically as
`dashboard<NN>.<domain>` and `devspaces<NN>.<domain>`, where `NN` is two
digits derived from the cluster's infrastructure name — the same cluster
always gets the same hostnames, different clusters do not collide. They are
only created when `deploy_external_dns` is true.

Override either to pin a name, or set either to `""` to skip that Route.

---

## Extra model endpoints

### `litellm_extra_models`

External OpenAI-compatible model APIs to offer alongside the cluster's own
models — Red Hat's MaaS, another cluster's LiteLLM, anything that speaks
`/v1/chat/completions`.

Declared once, here. Each endpoint is registered as a model in LiteLLM, which
is what puts it in OpenRAG, Dev Spaces/Continue and the Ops Dashboard — all
three ask LiteLLM what it serves — and is published to RHOAI's Gen AI
playground as an AI asset endpoint pointing back at LiteLLM. One `base_url`,
one key, one list of models, one proxy in front of them all.

Do **not** list a model that already has an InferenceService on this cluster.
RHOAI lists those from the InferenceService itself, with a description and a
real status; naming it here as well puts a second, statusless row beside it
in the AI asset endpoints table.

**Never put a real `api_key` in `all.yml.sample`.** This repo is public, and
a committed key is a key to rotate. Leave it empty and supply it at run time:

```
./run.sh --tags litellm -e @$HOME/.openshift-ai-endpoints.yml
```

where that file, kept outside the repo, holds the same structure with the
keys filled in. An endpoint with no key is skipped with a warning rather than
published half-configured, because one that 401s on first use is worse than
one that is absent.

Per endpoint:

| Key | Meaning |
|---|---|
| `name` | short id; becomes the provider id and the Secret/ConfigMap suffix, so keep it to lowercase and dashes |
| `base_url` | the OpenAI-compatible root, the part ending in `/v1` — the same URL the provider's own curl example posts `/chat/completions` to |
| `models` | the ids as that endpoint serves them |
| `mode` | `chat` (default) or `embedding` |
| `provider` | `openai` (default), right for anything OpenAI-compatible |
| `credential_name` | the shared LiteLLM credential the models are bound to, shown on the LLM Credentials page and reused by every model on the endpoint, so a rotated key is one edit. Defaults to `name` |
| `namespace` | where the AI asset is published; defaults to `model_namespace` |
| `publish_as_ai_asset` | whether it appears in the Gen AI playground. Defaults to true for `chat`, false for `embedding` — the playground is a chat UI and has no use for an embeddings model. Set it explicitly to serve a model through LiteLLM without listing it in RHOAI |

The default is an empty list in `roles/litellm/defaults`, so there is nothing
to delete first. The sample carries a commented-out example.

---

## Demos

### `deploy_demos`

The demos under `demos/` in this repo: retrieval A/B, answer judging, prompt
versions, tabular MLOps, model serving, workbenches and AutoRAG. All are
deployed into one Data Science Project (`rag-eval` by default) and all log to
MLflow.

The role refuses to run if MLflow, OpenSearch or LiteLLM is missing, naming
which, rather than failing later inside a Job where nobody is tailing the
logs. So `deploy_openrag: true` is effectively a prerequisite.

### `demos_rag_eval`, `demos_rag_judge`, `demos_prompt_versions`, `demos_tabular`, `demos_model_serving`, `demos_autorag`

Individually switchable. Turn one off and the rest still deploy.

| Variable | What it is |
|---|---|
| `demos_rag_eval` | retrieval A/B across OpenSearch and Milvus |
| `demos_rag_judge` | tracing plus LLM judges on answer quality |
| `demos_prompt_versions` | three prompt versions, compared head to head |
| `demos_tabular` | sklearn grid, autologged, winner registered |
| `demos_model_serving` | that registered model served on KServe |
| `demos_autorag` | Pipeline Server and AutoRAG prerequisites |

### `demos_workbenches`

The GPU workbench holds its card for as long as it runs, idle or not. On a
cluster with one spare accelerator that blocks training jobs, so set this
false if the GPU is needed elsewhere.

### `demos_run_jobs`

Run the jobs, not merely create them. A demo that has never run shows empty
panels, which is worse than no demo — the MLflow experiments, traces, judges
and registered model only exist once something has executed.

Costs roughly ten minutes of build time and some MaaS tokens. Set false to
deploy the manifests and run them by hand later.

### `demos_gen_model`

Generation defaults to a MaaS model rather than the cluster's own GPU model,
so the demos survive the GPU node going away. Set it to the value of
`model_name` to exercise the local model instead.

---

## Why this file exists

`all.yml.sample` used to carry all of the above as comments: 390 lines, of
which 285 were comment and 78 were settings. Three reasons it moved here.

1. **It broke `run.sh`.** The `awk` that rewrites `gpu_machinesets` ends the
   block at the first line starting with neither a space nor a dash, and the
   sample had `#` comments between list entries. Copying the sample to
   `all.yml` and picking any of 8 of the 10 GPU menu options produced a
   duplicate MachineSet entry — one at `replicas: 1`, one at `replicas: 0` —
   and the zero won, scaling away the GPU node the role had just waited for.
2. **Most of it was duplicated.** 26 of the 33 keys in the sample also have a
   default, with its own comment, in the owning role's `defaults/main.yml`.
   Two copies of a reason drift apart; the role default is the one next to
   the code.
3. **It was unreadable as a config file.** Finding the variable you wanted to
   change meant scrolling past a page of prose to reach it.

The three tiers now are: `all.yml.sample` for *what to set*, this file for
*why you would set it differently*, and `roles/*/defaults/main.yml` for the
implementation detail behind the default.
