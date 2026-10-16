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
# group_vars/all.yml.sample instead. Missing it used to be fatal, with a
# message telling you to run one cp - which is a thing the script can simply
# do. The reason it must not just proceed without the file stands, though:
# every variable would silently fall back to a role default and the run
# would target the wrong things.
if [[ ! -f group_vars/all.yml ]]; then
  if [[ ! -f group_vars/all.yml.sample ]]; then
    echo "Neither group_vars/all.yml nor group_vars/all.yml.sample exists." >&2
    echo "The sample is tracked, so this is not a clean checkout:" >&2
    echo "    git checkout ansible/group_vars/all.yml.sample" >&2
    exit 1
  fi
  # 600, not the sample's 644. This is the file documented as the one place
  # a pull secret, HF token or AWS secret key may live, and the questions
  # below are about to write some into it; starting it world-readable and
  # tightening later leaves a window where it is not.
  if ! (umask 077 && cp group_vars/all.yml.sample group_vars/all.yml); then
    echo "Could not create group_vars/all.yml from the sample." >&2
    exit 1
  fi
  chmod 600 group_vars/all.yml 2>/dev/null || true
  echo
  echo "Created group_vars/all.yml from the sample (mode 600)."
  echo "It is untracked, so credentials can live in it. What each setting"
  echo "does is in group_vars/all.README.md."
fi

# Interactive configuration, but only for a full run.
#
# Deliberately here rather than in Ansible's vars_prompt: vars_prompt is
# evaluated at play start, before tags are filtered, so it would also stop
# and ask on `./run.sh --tags summary` and on every other partial re-run.
# Here the prompts are skipped whenever any argument is passed, which is
# exactly the case where someone is not doing a full deploy.
#
# Skipped as well when stdin is not a terminal, so CI and nohup keep working,
# and when RUN_SH_NO_PROMPT is set - which exists because passing an argument
# was previously the only way to suppress the questions, and an argument also
# changes what Ansible does.
#
# The answers are written into group_vars/all.yml rather than passed as -e,
# because -e lasts exactly one run. A later ./run.sh --tags litellm skips
# these prompts and reads all.yml, so an unpersisted choice would leave those
# roles wiring everything to a model the cluster does not have - the same
# class of mismatch that had OpenRAG pointing at a stale model name. It also
# keeps the secrets out of the process table: run.sh:197 builds a shell
# command string for `script -c`, so an -e'd token would be visible in ps.
#
# The questions themselves live in lib/configure.sh, which exists so they can
# be tested - lib/configure.test.sh covers the cases that are painful to
# reach by hand, like a token containing the sed delimiter, a key missing
# from all.yml, and EOF on stdin part way through.
if [[ $# -eq 0 && -t 0 && -z "${RUN_SH_NO_PROMPT:-}" ]]; then
  if [[ ! -f lib/configure.sh ]]; then
    # Deliberately not fatal. Without the questions this script still does
    # its actual job, which is to run the playbook against whatever all.yml
    # already says - and refusing to deploy because a prompt is missing
    # would be a worse failure than the one it is reporting.
    echo "WARNING: lib/configure.sh is missing, so the setup questions are" >&2
    echo "         skipped. group_vars/all.yml is used exactly as it is." >&2
    echo "         Restore it with: git checkout ansible/lib/configure.sh" >&2
    echo >&2
  else
    # shellcheck source=lib/configure.sh
    source lib/configure.sh
    configure_interactive
  fi
fi

# Install required collections if not present.
#
# Deliberately not fatal. On a disconnected host this cannot reach Galaxy,
# but the collections may already be in ansible/collections from a pre-seed,
# in which case the run is fine and aborting would be wrong.
#
# What was wrong was saying nothing. "2>/dev/null || true" hid both the
# error and the cause, and because ansible.cfg narrows collections_paths to
# the gitignored ./collections, a fresh clone that fails here has no system
# fallback to fall back to - it resurfaces much later as "couldn't resolve
# module kubernetes.core.k8s", which reads like a bug in the playbook.
if ! ansible-galaxy collection install -r requirements.yml; then
  echo
  echo "WARNING: ansible-galaxy could not install the collections in" >&2
  echo "         requirements.yml. If this host is offline that is expected," >&2
  echo "         and the run will work provided they are already present in" >&2
  echo "         ansible/collections. If they are not, the run will fail later" >&2
  echo "         with 'couldn't resolve module kubernetes.core.k8s'. Pre-seed" >&2
  echo "         them on a connected host with:" >&2
  echo "             ansible-galaxy collection download -r requirements.yml" >&2
  echo "         then, here:" >&2
  echo "             ansible-galaxy collection install <tarball> -p collections" >&2
  echo
fi

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
