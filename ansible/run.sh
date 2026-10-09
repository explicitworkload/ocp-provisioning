#!/bin/bash
# Wrapper script to run the Ansible playbook.
# Uses 'script' to provide blocking IO that Ansible requires.
set -euo pipefail
cd "$(dirname "$0")"

# Activate the project venv if present, so the script works from any shell
# rather than only an already-activated one.
if [[ -f .venv/bin/activate ]]; then
  # shellcheck disable=SC1091
  source .venv/bin/activate
fi

if ! command -v ansible-playbook >/dev/null 2>&1; then
  cat >&2 <<'MSG'
ansible-playbook not found.

Create the project virtualenv (from the ansible/ directory):

    python3 -m venv .venv
    source .venv/bin/activate
    pip install ansible kubernetes

Do NOT run `python3 -m venv .` in the repository root: venv writes its own
.gitignore containing `*`, which overwrites the repo's and disables every
rule, including the ones keeping Terraform state and tfvars out of git.
MSG
  exit 1
fi

# group_vars/all.yml is untracked so it can hold credentials; the repo ships
# group_vars/all.yml.sample instead. A missing one is not an obscure failure
# worth debugging - every variable silently falls back to a role default and
# the run targets the wrong things.
if [[ ! -f group_vars/all.yml ]]; then
  cat >&2 <<'MSG'
group_vars/all.yml not found.

It is deliberately untracked, so that a pull secret, API key or endpoint
credential can live in it without being committed. Start from the sample:

    cp group_vars/all.yml.sample group_vars/all.yml

then edit it. The sample carries every setting with its documentation, and
no secrets.
MSG
  exit 1
fi

# Interactive choice of model and GPU instance, but only for a full run.
#
# Deliberately here rather than in Ansible's vars_prompt: vars_prompt is
# evaluated at play start, before tags are filtered, so it would also stop
# and ask on `./run.sh --tags summary` and on every other partial re-run.
# Here the prompt is skipped whenever any argument is passed, which is
# exactly the case where someone is not doing a full deploy.
#
# Skipped as well when stdin is not a terminal, so CI and nohup keep working,
# and when the caller already set either value with -e.
if [[ $# -eq 0 && -t 0 ]]; then
  echo
  echo "Model to serve (Enter keeps the value in group_vars/all.yml):"
  echo "    1) qwen3-4b          bf16  1 GPU    8 GB   32k context"
  echo "    2) qwen3-8b          bf16  1 GPU   16 GB   32k context"
  echo "    3) qwen3-14b         bf16  1 GPU   29 GB   16k context"
  echo "    4) qwen3.8-27b       bf16  4 GPUs  55 GB   32k context   (needs g6e.12xlarge)"
  echo "    5) qwen3.8-27b-fp8   FP8   1 GPU   28 GB   16k context   (Hugging Face, needs hf_token)"
  read -r -p "  choice [Enter to keep current]: " MODEL_CHOICE
  case "${MODEL_CHOICE:-}" in
    1) EXTRA_MODEL="qwen3-4b" ;;
    2) EXTRA_MODEL="qwen3-8b" ;;
    3) EXTRA_MODEL="qwen3-14b" ;;
    4) EXTRA_MODEL="qwen3.8-27b" ;;
    5) EXTRA_MODEL="qwen3.8-27b-fp8" ;;
    "") EXTRA_MODEL="" ;;
    *) echo "  not one of the choices - keeping the configured model" >&2; EXTRA_MODEL="" ;;
  esac

  echo
  echo "GPU instance to create (Enter keeps gpu_machinesets in all.yml):"
  echo "    1) g4dn.4xlarge   1 x T4         16 GB"
  echo "    2) g6e.4xlarge    1 x L40S       48 GB"
  echo "    3) g6e.12xlarge   4 x L40S      192 GB"
  echo "    4) p4d.24xlarge   8 x A100 40G  320 GB"
  echo "    5) p4de.24xlarge  8 x A100 80G  640 GB"
  read -r -p "  choice [Enter to keep current]: " GPU_CHOICE
  case "${GPU_CHOICE:-}" in
    1) EXTRA_GPU="g4dn.4xlarge" ;;
    2) EXTRA_GPU="g6e.4xlarge" ;;
    3) EXTRA_GPU="g6e.12xlarge" ;;
    4) EXTRA_GPU="p4d.24xlarge" ;;
    5) EXTRA_GPU="p4de.24xlarge" ;;
    "") EXTRA_GPU="" ;;
    *) echo "  not one of the choices - keeping the configured instances" >&2; EXTRA_GPU="" ;;
  esac

  # Written into group_vars/all.yml rather than passed as -e, because -e
  # lasts exactly one run. A later ./run.sh --tags litellm or --tags summary
  # skips this prompt and reads all.yml, so an unpersisted choice would leave
  # those roles wiring everything to a model the cluster does not have - the
  # same class of mismatch that had OpenRAG pointing at a stale model name.
  #
  # all.yml is untracked, so this is editing local configuration, not the
  # repo. Both edits are line-level on purpose: rewriting the file through a
  # YAML library would strip its comments, which are the only documentation
  # of what these settings mean.
  if [[ -n "$EXTRA_MODEL" ]]; then
    sed -i.bak -E "s|^model_preset: .*$|model_preset: ${EXTRA_MODEL}|" group_vars/all.yml \
      && rm -f group_vars/all.yml.bak
    echo "  model_preset set to $EXTRA_MODEL in group_vars/all.yml"
  fi
  if [[ -n "$EXTRA_GPU" ]]; then
    # Appends the chosen type when the file does not already list it. Without
    # that, picking an instance all.yml had never heard of zeroed every entry
    # and added nothing: the run then built four MachineSets at 0 replicas and
    # model_serving sat waiting half an hour for a GPU node nobody had asked
    # AWS for. Hit on sandbox3270, where all.yml came from the sample and the
    # sample had no g6e.12xlarge while the menu above offered it.
    awk -v want="$EXTRA_GPU" '
      /^gpu_machinesets:/ { inblock=1; print; next }
      inblock && /^[^ -]/ {
        if (!seen) { print "- instance_type: " want; print "  replicas: 1"; seen=1 }
        inblock=0
      }
      inblock && /^- instance_type:/ { cur=$3; if (cur==want) seen=1; print; next }
      inblock && /^  replicas:/ { print "  replicas: " (cur==want ? 1 : 0); next }
      { print }
      END {
        if (inblock && !seen) { print "- instance_type: " want; print "  replicas: 1" }
      }
    ' group_vars/all.yml > group_vars/all.yml.tmp \
      && mv group_vars/all.yml.tmp group_vars/all.yml
    echo "  gpu_machinesets set to $EXTRA_GPU x1 in group_vars/all.yml"
    # Say it out loud rather than trusting the edit, because the failure this
    # replaces was silent in exactly this spot.
    if ! grep -A1 "^- instance_type: ${EXTRA_GPU}\$" group_vars/all.yml | grep -q "replicas: 1"; then
      echo "  WARNING: ${EXTRA_GPU} is still not at 1 replica in group_vars/all.yml." >&2
      echo "           Check the gpu_machinesets block by hand before continuing." >&2
    fi
  fi
  echo
fi

# Install required collections if not present
ansible-galaxy collection install -r requirements.yml 2>/dev/null || true

# Run playbook with blocking IO wrapper.
# -e/--return makes script exit with the playbook's status; without it a
# failed run reports success on Linux. printf %q quotes each argument so the
# shell re-parse cannot mangle values containing spaces or metacharacters.
if [[ "$(uname)" == "Darwin" ]]; then
  script -q /dev/null ansible-playbook site.yml "$@"
else
  # Build the argument suffix only when there is something to quote: bash's
  # printf emits '' for a %q with no corresponding argument, so a bare
  # ./run.sh produced "ansible-playbook site.yml ''" and died with
  # "the playbook:  could not be found".
  extra=""
  if (( $# )); then
    extra=" $(printf '%q ' "$@")"
  fi
  script -qe -c "ansible-playbook site.yml$extra" /dev/null
fi
