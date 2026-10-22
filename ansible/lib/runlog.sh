# shellcheck shell=bash
# Keep a copy of the ./run.sh log on the cluster, so a failed run can be read
# back with oc instead of being copied out of a terminal on the run host.
#
# Sourced by run.sh. Every function here is best-effort and returns 0: a log
# that fails to upload must never be the reason a deployment fails, or the
# reason a failed one reports the wrong exit code.
#
# Read it back with:
#   oc get configmap ansible-run-log -n dashboard -o jsonpath='{.data.status}'
#   oc extract configmap/ansible-run-log -n dashboard --keys=run.log --to=- | tail -100
#
# --- credentials never leave the run host ---------------------------------
# The end-of-run summary prints the LiteLLM master key and every generated
# admin password. Those lines are cut from the uploaded copy - see
# runlog_clean - and the local file under logs/ keeps them. Nothing else a
# run prints is a credential: every task that touches one runs under no_log,
# and the remaining report tasks were checked and print only names, hosts
# and URLs. A second, pattern-based pass masks anything shaped like a token
# anyway, in case that ever stops being true.
#
# It fails CLOSED. If the redaction step cannot run - no python3 - nothing is
# uploaded at all, rather than the unredacted log.
#
# Knobs, all optional:
#   RUN_LOG_UPLOAD=0          keep the local file only
#   RUN_LOG_NAMESPACE         default dashboard
#   RUN_LOG_NAME              default ansible-run-log
#   RUN_LOG_KIND              configmap (default) | secret
#   RUN_LOG_INTERVAL          seconds between uploads during a run, default 60
#   RUN_LOG_CONTEXT           kube context; default ocp_context from all.yml,
#                             else the current context

RUN_LOG_NAMESPACE="${RUN_LOG_NAMESPACE:-dashboard}"
RUN_LOG_NAME="${RUN_LOG_NAME:-ansible-run-log}"
RUN_LOG_KIND="${RUN_LOG_KIND:-configmap}"
RUN_LOG_INTERVAL="${RUN_LOG_INTERVAL:-60}"

# 900 KB of log, leaving room under the 1 MiB object limit for the other keys
# and the object's own metadata. The end of a log is the part that explains a
# failure, so it is the start that gets dropped.
RUN_LOG_CAP=900000

runlog_enabled() {
  [[ "${RUN_LOG_UPLOAD:-1}" != "0" ]] \
    && command -v oc >/dev/null 2>&1 \
    && command -v python3 >/dev/null 2>&1
}

# The same cluster the playbook targets. run.sh's only reliable source for
# that is all.yml; a context passed as -e ocp_context=... is invisible from
# here, which is what RUN_LOG_CONTEXT is for.
runlog_context() {
  if [[ -n "${RUN_LOG_CONTEXT:-}" ]]; then
    printf '%s' "$RUN_LOG_CONTEXT"
    return 0
  fi
  [[ -f group_vars/all.yml ]] || return 0
  sed -n 's/^ocp_context:[[:space:]]*//p' group_vars/all.yml | head -n 1 \
    | sed -e 's/[[:space:]]#.*$//' -e "s/^[\"']//" -e "s/[\"'][[:space:]]*$//"
}

runlog_oc() {
  local ctx
  ctx="$(runlog_context)"
  if [[ -n "$ctx" ]]; then
    oc --context "$ctx" "$@"
  else
    oc "$@"
  fi
}

# runlog_clean <src> <dst>
#
# script(1) records the terminal rather than the text - colour codes,
# carriage-return redraws, CRLF line ends - so that is stripped first. Then
# the credentials go, and the result is capped to fit. Prints "true" when the
# log had to be cut; exits non-zero if it could not produce a clean copy.
runlog_clean() {
  python3 -I - "$1" "$2" "$RUN_LOG_CAP" <<'PY'
import re, sys
src, dst, cap = sys.argv[1], sys.argv[2], int(sys.argv[3])
text = open(src, "rb").read().decode("utf-8", "replace")

# terminal noise
text = re.sub(r"\x1b\[[0-9;?]*[ -/]*[@-~]", "", text)          # CSI: colours, cursor
text = re.sub(r"\x1b\][^\x07\x1b]*(\x07|\x1b\\)", "", text)    # OSC: window titles
text = text.replace("\r\n", "\n")
lines = [l.rsplit("\r", 1)[-1] for l in text.split("\n")]

# The summary's credentials section. The debug callback prints the message
# list one JSON string per line, so the section is everything after the
# CREDENTIALS heading up to the run-time line, the reprint footer, or the
# closing bracket - whichever the summary got to.
START = "CREDENTIALS   (generated per cluster"
END = ("TOTAL RUN TIME", "Reprint any time with")
out, skipping = [], False
for line in lines:
    if skipping:
        if any(e in line for e in END) or line.strip() in ("]", "],"):
            skipping = False
        else:
            continue
    out.append(line)
    if START in line:
        indent = line[: len(line) - len(line.lstrip())]
        out.append(indent + '"[credentials removed from the uploaded copy - see the '
                   'Ops Dashboard Access page, or logs/ on the run host]",')
        skipping = True

# Belt and braces: anything shaped like a token, wherever it appears.
text = "\n".join(out)
for pat, repl in (
    (r"\bsk-[A-Za-z0-9_\-]{12,}", "sk-[masked]"),                  # LiteLLM / OpenAI keys
    (r"\bhf_[A-Za-z0-9]{20,}", "hf_[masked]"),                     # Hugging Face tokens
    (r"\b(AKIA|ASIA)[0-9A-Z]{16}\b", r"\1[masked]"),               # AWS access key ids
    (r"\bsha256~[A-Za-z0-9_\-]{20,}", "sha256~[masked]"),          # OpenShift tokens
    (r"(?i)(\"?(?:password|passwd|secret|token|api_key|apikey)\"?\s*[:=]\s*\"?)"
     r"(?!\[masked\]|\*)[^\s\",}]{6,}", r"\1[masked]"),
):
    text = re.sub(pat, repl, text)

data = text.encode()
cut = len(data) > cap
if cut:
    kept = data[-cap:]
    kept = kept[kept.find(b"\n") + 1:]
    data = ("[... first %d bytes dropped to fit the object size limit; the full "
            "log is %s on the run host ...]\n" % (len(data) - len(kept), src)).encode() + kept
open(dst, "wb").write(data)
print("true" if cut else "false")
PY
}

# runlog_publish <logfile> <status> [exit_code]
runlog_publish() {
  runlog_enabled || return 0
  local log="$1" run_status="$2" rc="${3:-}" clean truncated
  local -a kind_args
  [[ -f "$log" ]] || return 0
  clean="$(mktemp)" || return 0
  if ! truncated="$(runlog_clean "$log" "$clean" 2>/dev/null)"; then
    rm -f "$clean"   # closed: an unredacted copy is never the fallback
    return 0
  fi

  # Created here as well as by the dashboard role, because a run that fails
  # before reaching that role is exactly the run whose log is wanted.
  runlog_oc get namespace "$RUN_LOG_NAMESPACE" >/dev/null 2>&1 \
    || runlog_oc create namespace "$RUN_LOG_NAMESPACE" >/dev/null 2>&1 || true

  if [[ "$RUN_LOG_KIND" == "secret" ]]; then
    kind_args=(secret generic)
  else
    kind_args=(configmap)
  fi

  # Server-side apply, not plain apply: client-side apply copies the whole
  # object into a last-applied-configuration annotation, annotations are
  # capped at 256 KB, and a long log would be refused on its second upload.
  oc create "${kind_args[@]}" "$RUN_LOG_NAME" -n "$RUN_LOG_NAMESPACE" \
      --from-file=run.log="$clean" \
      --from-literal=status="$run_status" \
      --from-literal=exit_code="$rc" \
      --from-literal=started="${RUN_LOG_STARTED:-}" \
      --from-literal=updated="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --from-literal=host="$(hostname 2>/dev/null)" \
      --from-literal=commit="$(git rev-parse --short HEAD 2>/dev/null)" \
      --from-literal=args="${RUN_LOG_ARGS:-}" \
      --from-literal=local_log="$([[ "$log" = /* ]] && printf %s "$log" || printf %s "$PWD/$log")" \
      --from-literal=truncated="$truncated" \
      --dry-run=client -o yaml 2>/dev/null \
    | runlog_oc apply --server-side --force-conflicts --field-manager=run.sh -f - \
      >/dev/null 2>&1 || true

  rm -f "$clean"
  return 0
}

# Re-upload every RUN_LOG_INTERVAL seconds while the playbook runs, so a run
# that is still going - or whose host has gone away - can be read too.
runlog_start() {
  runlog_enabled || return 0
  local log="$1"
  (
    set +e
    while sleep "$RUN_LOG_INTERVAL"; do
      runlog_publish "$log" running
    done
  ) >/dev/null 2>&1 &
  RUNLOG_PID=$!
}

runlog_stop() {
  [[ -n "${RUNLOG_PID:-}" ]] || return 0
  kill "$RUNLOG_PID" 2>/dev/null || true
  wait "$RUNLOG_PID" 2>/dev/null || true
  RUNLOG_PID=""
}

runlog_status_for() {
  case "$1" in
    0)   echo succeeded ;;
    130) echo interrupted ;;
    *)   echo failed ;;
  esac
}
