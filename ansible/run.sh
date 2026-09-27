#!/bin/bash
# Wrapper script to run the Ansible playbook.
# Uses 'script' to provide blocking IO that Ansible requires.
set -euo pipefail
cd "$(dirname "$0")"

# Install required collections if not present
ansible-galaxy collection install -r requirements.yml 2>/dev/null || true

# Run playbook with blocking IO wrapper
if [[ "$(uname)" == "Darwin" ]]; then
  script -q /dev/null ansible-playbook site.yml "$@"
else
  script -qc "ansible-playbook site.yml $*" /dev/null
fi
