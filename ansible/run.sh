#!/bin/bash
# Wrapper script to run an Ansible playbook.
# Uses 'script' to provide blocking IO that Ansible requires.
#
# Defaults to site.yml, the full cluster build. Override for the experiments,
# which deploy one thing and must not be reached by a bare ./run.sh:
#
#     ./run.sh odf-experiment.yml
#     PLAYBOOK=odf-experiment.yml ./run.sh
#
# Note there is no --tags form for the experiments: they are separate
# playbooks, not roles inside site.yml, because odf and odf_experiment both
# manage ocs-storagecluster with incompatible specs and a single playbook
# holding both would fight itself. `./run.sh --tags odf-experiment` matches
# only site.yml's always-tagged pre_tasks and deploys nothing.
set -euo pipefail
cd "$(dirname "$0")"

# First argument wins if it names a playbook here, so the natural form works:
#   ./run.sh odf-experiment.yml -e foo=bar
# Everything after it passes through to ansible-playbook untouched.
#
# Anything ending .yml is taken as the playbook whether or not it exists, so a
# typo reports the available playbooks instead of being passed through as a
# second positional and dying inside ansible-playbook with "the playbook:
# not-a-playbook.yml could not be found".
PLAYBOOK="${PLAYBOOK:-site.yml}"
if [[ $# -gt 0 && "$1" == *.yml ]]; then
  PLAYBOOK="$1"
  shift
fi

if [[ ! -f "$PLAYBOOK" ]]; then
  echo "No such playbook: $PLAYBOOK" >&2
  echo "Available:" >&2
  ls -1 ./*.yml 2>/dev/null | grep -vE 'requirements\.yml' | sed 's|^\./|  |' >&2
  exit 1
fi

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

# Install required collections if not present
ansible-galaxy collection install -r requirements.yml 2>/dev/null || true

# Run playbook with blocking IO wrapper.
# -e/--return makes script exit with the playbook's status; without it a
# failed run reports success on Linux. printf %q quotes each argument so the
# shell re-parse cannot mangle values containing spaces or metacharacters.
if [[ "$(uname)" == "Darwin" ]]; then
  script -q /dev/null ansible-playbook "$PLAYBOOK" "$@"
else
  # Build the argument suffix only when there is something to quote: bash's
  # printf emits '' for a %q with no corresponding argument, so a bare
  # ./run.sh produced "ansible-playbook site.yml ''" and died with
  # "the playbook:  could not be found".
  extra=""
  if (( $# )); then
    extra=" $(printf '%q ' "$@")"
  fi
  script -qe -c "ansible-playbook $(printf %q "$PLAYBOOK")$extra" /dev/null
fi
