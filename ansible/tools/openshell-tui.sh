#!/bin/bash
# Open the OpenShell TUI ("openshell term") from inside the cluster.
#
#   ansible/tools/openshell-tui.sh            open it, creating the helper pod if needed
#   ansible/tools/openshell-tui.sh --delete   remove the helper pod
#
# Why not just run it on your laptop through a port-forward: the TUI gives up
# on slow requests and draws empty tables - "No providers found", "No
# sandboxes" - without ever reporting an error. Through a port-forward every
# call crosses the API server, and from a laptop on an ordinary connection
# that was 2.2s a call on sandbox897, against 22 ms from a pod beside the
# gateway. The CLI waits long enough and works from anywhere; only the TUI
# needs to be close.
#
# So this keeps a small pod in the gateway's namespace holding the OpenShell
# CLI, registered against the in-cluster gateway, and opens the TUI in it with
# "oc exec -it". exec matters: with "oc run -it" the container starts before
# the terminal attaches, the TUI's startup query for the cursor position goes
# unanswered, and it exits with "The cursor position could not be read".
#
# The pod holds no credentials of its own - the gateway is unauthenticated
# and cluster-internal by design (see openshell_disable_tls in
# roles/openshell/defaults/main.yml) - and runs under the namespace's default
# ServiceAccount and SCC. It sleeps when idle; --delete removes it.
#
# Uses the current oc context, or OCP_CONTEXT if set.
#
# AIR GAP: the CLI is fetched from GitHub when the pod starts, exactly as the
# provider Job fetches it. Mirror the tarball and set OPENSHELL_CLI_URL.
set -euo pipefail
cd "$(dirname "$0")/.."

DEFAULTS=roles/openshell/defaults/main.yml
# One source of truth: the same CLI release and image the provider Job uses.
_default() { sed -n "s/^$1:[[:space:]]*\"\{0,1\}\([^\"]*\)\"\{0,1\}[[:space:]]*$/\1/p" "$DEFAULTS" | head -1; }

NS="${OPENSHELL_NAMESPACE:-$(_default openshell_namespace)}"
VERSION="${OPENSHELL_CLI_VERSION:-$(_default openshell_cli_version)}"
IMAGE="${OPENSHELL_TUI_IMAGE:-$(_default openshell_cli_job_image)}"
URL="${OPENSHELL_CLI_URL:-https://github.com/NVIDIA/OpenShell/releases/download/${VERSION}/openshell-x86_64-unknown-linux-musl.tar.gz}"
POD=openshell-tui

oc_() { if [ -n "${OCP_CONTEXT:-}" ]; then oc --context "$OCP_CONTEXT" "$@"; else oc "$@"; fi; }

if [ "${1:-}" = "--delete" ]; then
  oc_ delete pod "$POD" -n "$NS" --ignore-not-found
  exit 0
fi

if [ ! -t 0 ] || [ ! -t 1 ]; then
  echo "openshell-tui: needs an interactive terminal." >&2
  exit 1
fi

if ! oc_ get service openshell -n "$NS" >/dev/null 2>&1; then
  echo "openshell-tui: no OpenShell gateway in namespace $NS on $(oc_ config current-context)." >&2
  echo "               Deploy it with: ./run.sh --tags openshell" >&2
  exit 1
fi

phase="$(oc_ get pod "$POD" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
case "$phase" in
  Running|Pending) ;;
  "") ;;
  *)  # Succeeded/Failed/Unknown: the sleep ended or setup failed. Start over.
      oc_ delete pod "$POD" -n "$NS" --wait=true >/dev/null 2>&1 || true
      phase="" ;;
esac

if [ -z "$phase" ]; then
  echo "Starting the OpenShell TUI pod in $NS (CLI $VERSION)..."
  oc_ run "$POD" -n "$NS" --restart=Never --image="$IMAGE" \
    --labels=app.kubernetes.io/name=openshell-tui -- bash -c "
      set -e
      cd /tmp
      curl -fsSL '$URL' | tar -xz
      HOME=/tmp ./openshell gateway add http://openshell.$NS.svc.cluster.local:8080 --name incluster >/dev/null
      touch /tmp/ready
      exec sleep infinity" >/dev/null
fi

# Running is not ready: the CLI download and gateway registration happen
# after the container starts, and /tmp/ready is written last.
for _ in $(seq 1 60); do
  if oc_ exec -n "$NS" "$POD" -- test -f /tmp/ready >/dev/null 2>&1; then
    exec_args=(exec -it -n "$NS" "$POD" -- env HOME=/tmp TERM="${TERM:-xterm-256color}" /tmp/openshell term)
    if [ -n "${OCP_CONTEXT:-}" ]; then
      exec oc --context "$OCP_CONTEXT" "${exec_args[@]}"
    fi
    exec oc "${exec_args[@]}"
  fi
  case "$(oc_ get pod "$POD" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)" in
    Failed|Succeeded)
      echo "openshell-tui: the helper pod stopped during setup:" >&2
      oc_ logs "$POD" -n "$NS" 2>&1 | tail -5 >&2
      exit 1 ;;
  esac
  sleep 3
done

echo "openshell-tui: the helper pod was not ready after 3 minutes." >&2
oc_ logs "$POD" -n "$NS" 2>&1 | tail -5 >&2
exit 1
