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
