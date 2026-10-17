#!/bin/bash
# Interactive configuration for run.sh: ask what to deploy, write the answers
# into group_vars/all.yml.
#
# A separate file from run.sh for one reason that matters - it is testable.
# lib/configure.test.sh exercises every function here against throwaway YAML,
# including the cases that are awkward to reach by hand: a secret containing
# the sed delimiter, a key absent from all.yml, EOF on stdin, an endpoint
# that 401s. run.sh itself stays what it says it is, a wrapper that runs the
# playbook.
#
# bash 3.2 compatible throughout. macOS ships 3.2.57 and ${var,,} is a syntax
# error there, not a graceful degradation.

# The one file these functions may write. Hardcoded rather than a parameter:
# group_vars/all.yml.sample is committed to a public repo, and the whole
# point of this script is to put live credentials somewhere. A variable here
# is one typo away from writing an HF token into a tracked file.
# The test suite overrides it; nothing else may.
AY="${AY:-group_vars/all.yml}"

MAAS_NAME="maas-rhdp"
MAAS_CREDENTIAL="rhdp-maas"
MAAS_BASE_URL="https://maas-rhdp.apps.maas.redhatworkshops.io/v1"

# ---------------------------------------------------------------------------
# Reading all.yml
# ---------------------------------------------------------------------------

# has_var <key> - true when the key is defined, uncommented, at column 0.
# Distinct from "get_var returned empty", which is also what a key set to ""
# looks like. The difference decides whether a missing key gets written.
has_var() {
  _K="$1" awk 'BEGIN{k=ENVIRON["_K"]} index($0, k ":")==1 {found=1; exit} END{exit !found}' "$AY"
}

# get_var <key> - the current value with one layer of quoting removed, or
# empty. Used to show what is already configured, so a re-run can say
# "Enter keeps this".
# A trailing comment is part of the line but not part of the value, and
# missing that made this lie about the thing it exists to report. all.yml
# files written from an older sample carry
#
#     demos_rag_eval: true          # retrieval A/B across OpenSearch
#
# and the whole string came back, so `truthy` never matched "true" and the
# summary said "demos yes (2 of 8)" on a file where all eight were on. The
# playbook read the YAML correctly throughout - only the report was wrong,
# which is the worst kind of wrong for a screen whose job is to tell you
# what is about to happen.
#
# A '#' only opens a comment when whitespace precedes it, and never inside
# quotes, so a quoted value is taken up to its closing quote and an
# unquoted one is cut at the first whitespace-hash.
get_var() {
  _K="$1" awk '
    BEGIN { k = ENVIRON["_K"] }
    index($0, k ":") == 1 {
      sub(/^[^:]*:[ \t]*/, "")
      q = substr($0, 1, 1)
      if (q == "'"'"'" || q == "\"") {
        for (i = length($0); i > 1; i--) if (substr($0, i, 1) == q) break
        $0 = substr($0, 1, i)
      } else {
        sub(/[ \t]+#.*$/, "")
      }
      sub(/[ \t]+$/, "")
      if (match($0, /^'"'"'.*'"'"'$/)) { $0 = substr($0, 2, length($0)-2); gsub(/'"'"''"'"'/, "'"'"'") }
      else if (match($0, /^".*"$/))    { $0 = substr($0, 2, length($0)-2) }
      print; exit
    }' "$AY"
}

# truthy <key> <default-when-absent> - how Ansible will actually read it.
truthy() {
  if ! has_var "$1"; then [ "$2" = true ]; return; fi
  case "$(_lower "$(get_var "$1")")" in
    true|yes|y|on|1) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Writing all.yml
# ---------------------------------------------------------------------------

_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# yaml_quote <value> - a YAML-safe single-quoted scalar.
#
# Single-quoted YAML has exactly one escape, '' for a literal '. Nothing else
# is special inside it: no backslash processing, no # comment, no : mapping,
# no leading @ or % reserved indicator. Quoting unconditionally is therefore
# both correct and simpler than deciding case by case.
#
# Double quotes would NOT do: "sk-a\bc" parses to a literal backspace, so the
# key that reaches LiteLLM is not the key that was typed, with no error.
yaml_quote() {
  # The replacement half of ${v//pat/rep} does not process backslash escapes,
  # so ${v//\'/\'\'} writes literal backslashes into the value. Hold the
  # quote in a variable instead.
  local v="$1" q="'"
  printf '%s%s%s' "$q" "${v//$q/$q$q}" "$q"
}

# _mode <file> -> the permission bits as octal, or nothing.
#
# GNU and BSD stat disagree about -f, and not in a way a `||` fallback
# survives. On BSD it is the format flag. On GNU it is --file-system, which
# SUCCEEDS and prints a block of filesystem statistics, so
#
#     stat -f %Lp "$1" || stat -c %a "$1"
#
# never reaches the fallback on Linux and hands the caller an xfs dump where
# it expected "644". That reached the screen in the middle of a summary line,
# and - worse - _replace passed it to chmod, so the mode of a file holding
# credentials was not preserved on the one platform this mostly runs on.
#
# So: try the GNU form first, and validate that whatever comes back is octal
# digits. Neither variant can then return something that merely looks like a
# mode, and a stat that is missing entirely returns nothing rather than junk.
_mode() {
  local m
  m=$(stat -c %a "$1" 2>/dev/null)
  case "$m" in ''|*[!0-7]*) m=$(stat -f %Lp "$1" 2>/dev/null) ;; esac
  case "$m" in ''|*[!0-7]*) return 1 ;; esac
  printf '%s' "$m"
}

# _replace <tmpfile> - move a rewritten temp file over all.yml, keeping the
# original permissions. `awk > tmp && mv` resets the mode to the umask -
# verified, 600 becomes 644 - and this is the file documented as the place a
# real pull secret, HF token and AWS secret key may live. Downgrading it to
# world-readable while setting a boolean is not a trade to make silently.
_replace() {
  local tmp="$1" m
  m="$(_mode "$AY")"
  mv "$tmp" "$AY" || return 1
  [ -n "$m" ] && chmod "$m" "$AY" 2>/dev/null
  return 0
}

# 077 so the temp file is never momentarily readable by anyone else: it holds
# the same secrets as the file it is about to become.
_mktemp() { ( umask 077; mktemp "${AY}.XXXXXX" ); }

# _upsert <key> <rendered-value>
#
# Substitutes the first uncommented `key:` at column 0. Failing that, revives
# a commented `#key:` or `# key:` line in place, so a value the sample ships
# commented out lands where its documentation expects it. Failing both,
# appends at EOF.
#
# The append path is not a nicety. The live all.yml on this machine is missing
# 12 of the 33 keys in the sample, deploy_omnigent among them, and
# site.yml:424 reads it as `deploy_omnigent | default(false)`. A plain sed
# substitution would match nothing, write nothing, report success, and
# omnigent would silently not deploy. That is the sandbox3270 failure class
# the gpu_machinesets awk already exists to avoid.
#
# Values are passed through ENVIRON, never argv and never a sed pattern: awk
# -v processes backslash escapes (a \n in a token becomes a newline) and sed
# is destroyed outright by a token containing its delimiter or an &.
_upsert() {
  local key="$1" rendered="$2" tmp
  tmp="$(_mktemp)" || return 1
  _K="$key" _V="$rendered" awk '
    BEGIN { k = ENVIRON["_K"]; v = ENVIRON["_V"] }
    { lines[NR] = $0 }
    live == 0 && index($0, k ":") == 1 { live = NR }
    commented == 0 && (index($0, "#" k ":") == 1 || index($0, "# " k ":") == 1) { commented = NR }
    END {
      if (live) lines[live] = k ": " v
      else if (commented) lines[commented] = k ": " v
      for (i = 1; i <= NR; i++) print lines[i]
      if (!live && !commented) print k ": " v
    }' "$AY" > "$tmp" && _replace "$tmp"
}

# set_string <key> <value> - always quoted. For tokens, keys, contexts.
set_string() { _upsert "$1" "$(yaml_quote "$2")"; }

# set_bool <key> <true|false> - bare, so Ansible gets a real boolean.
# Never quoted: 'false' is a non-empty string, and `k: no` coerces to False
# while `k: yes` coerces to True, which is a trap worth stepping around.
set_bool() { _upsert "$1" "$2"; }

# set_raw <key> <value> - verbatim. For numbers and known-safe identifiers.
set_raw() { _upsert "$1" "$2"; }

# set_block <key> <body> - replace a whole list-of-mappings block.
#
# The block runs from the `key:` line to the first following line that is
# neither blank, nor indented, nor a `- ` item at column 0 - the same
# terminator the gpu_machinesets awk uses, and it carries the same hazard: a
# `#` at column 0 inside the block ends it early. guard_yaml is what makes
# that safe; a write that produces unparseable YAML is reverted.
set_block() {
  local key="$1" body="$2" tmp
  tmp="$(_mktemp)" || return 1
  _K="$key" _B="$body" awk '
    BEGIN { k = ENVIRON["_K"]; b = ENVIRON["_B"] }
    inblock {
      if ($0 ~ /^[[:space:]]*$/) next
      if ($0 ~ /^[ -]/)          next
      inblock = 0; print ""
    }
    !hit && index($0, k ":") == 1 { print k ":"; printf "%s", b; inblock = 1; hit = 1; next }
    { print }
    END { if (!hit) { print ""; print k ":"; printf "%s", b } }' "$AY" > "$tmp" && _replace "$tmp"
}

# guard_yaml <label> -- <command...>
#
# Runs a write, then checks the file still parses. If it does not, the file
# is restored and the caller is told. Every edit goes through this.
#
# These writes are line-level by necessity - all.yml carries comments that a
# YAML round-trip would strip, which is why run.sh has always edited it this
# way - and line-level editing of YAML can always be defeated by a file
# shaped unexpectedly. Reverting beats corrupting the one file in this repo
# that is not in git and cannot be recovered from it.
_yaml_ok() { python3 -c 'import yaml,sys; yaml.safe_load(open(sys.argv[1]))' "$1" >/dev/null 2>&1; }
_NO_PYYAML_WARNED=0
_WAS_INVALID_WARNED=0

guard_yaml() {
  local label="$1"; shift
  [ "${1:-}" = "--" ] && shift
  local snap rc=0 check=1

  # Two reasons this write must not be judged, both of which previously
  # reverted every answer and blamed the write for it.
  #
  # No PyYAML: the validator cannot run. Reverting everything because the
  # checker is missing turns a missing library into "none of your answers
  # were saved", which is a far worse failure than the one it guards.
  if ! python3 -c 'import yaml' >/dev/null 2>&1; then
    check=0
    if [ "$_NO_PYYAML_WARNED" = 0 ]; then
      echo "  note: python3 has no PyYAML here, so writes are not" >&2
      echo "        re-checked for validity. They still happen." >&2
      _NO_PYYAML_WARNED=1
    fi
  # Already unparseable before we touched it: whatever is wrong with
  # group_vars/all.yml, this write did not cause it, and refusing every
  # write leaves the user unable to fix it from here either.
  elif ! _yaml_ok "$AY"; then
    check=0
    if [ "$_WAS_INVALID_WARNED" = 0 ]; then
      echo "  note: group_vars/all.yml does not parse as YAML already, so" >&2
      echo "        writes cannot be verified. Fix it by hand if a later" >&2
      echo "        task complains." >&2
      _WAS_INVALID_WARNED=1
    fi
  fi

  snap="$(_mktemp)" || return 1
  cp "$AY" "$snap"
  if ! "$@"; then rc=1
  elif [ "$check" = 1 ] && ! _yaml_ok "$AY"; then
    rc=2
  fi
  case "$rc" in
    0) rm -f "$snap" ;;
    1) cp "$snap" "$AY"; rm -f "$snap"
       echo "  WARNING: could not write $label - left unchanged" >&2 ;;
    2) cp "$snap" "$AY"; rm -f "$snap"
       echo "  WARNING: writing $label would have made group_vars/all.yml" >&2
       echo "           invalid YAML. Reverted; set it by hand." >&2 ;;
  esac
  return $rc
}

# ---------------------------------------------------------------------------
# Prompting
# ---------------------------------------------------------------------------
#
# Every read is guarded with `|| ans=`. Under `set -e` a read that hits EOF
# returns 1 and kills the script - verified - so a stray Ctrl-D part way
# through would abort the run after some answers had been written and before
# others, which is the worst possible moment. EOF is treated as Enter.

# mask <value> - safe to print. Never echoes a secret back. The live all.yml
# holds a real HF token and a real MaaS key; rendering either as an
# "[Enter to keep]" hint would put both into the scrollback on every run.
mask() {
  local v="$1" n=${#1}
  if   [ -z "$v" ];  then printf '(not set)'
  elif [ "$n" -le 8 ]; then printf '(set, %d chars)' "$n"
  else printf '(set, %d chars, ends %s)' "$n" "${v: -4}"
  fi
}

# ask_yn <question> <default: y|n> - status 0 for yes, 1 for no.
# An unrecognised answer takes the default rather than re-asking: this runs
# in front of a 90-minute deploy and a typo should not become a dialogue.
ask_yn() {
  local q="$1" def="$2" ans hint
  if [ "$def" = y ]; then hint="[Y/n]"; else hint="[y/N]"; fi
  read -r -p "  $q $hint " ans || ans=""
  ans=$(_lower "${ans:-$def}")
  case "$ans" in
    y|yes) return 0 ;;
    n|no)  return 1 ;;
    *)     [ "$def" = y ] ;;
  esac
}

# ask_text <question> <current> - prints the chosen value on stdout.
# read -p writes its prompt to stderr, so $( ) capture stays clean.
ask_text() {
  local q="$1" cur="$2" ans shown
  if [ -n "$cur" ]; then shown="[$cur]"; else shown="[none set]"; fi
  read -r -p "  $q $shown: " ans || ans=""
  if [ -z "$ans" ]; then printf '%s' "$cur"; else printf '%s' "$ans"; fi
}

# ask_secret <question> <current> - prints the chosen value on stdout.
# Never echoes what is typed, and never prints the existing value back; only
# its length and last four characters, which is enough to recognise "yes,
# that is the key I set last time" without putting it on a shared terminal.
ask_secret() {
  local q="$1" cur="$2" ans hint
  # "Enter keeps" is wrong when there is nothing to keep.
  if [ -n "$cur" ]; then hint="Enter keeps"; else hint="Enter skips"; fi
  read -rs -p "  $q $(mask "$cur"), $hint: " ans || ans=""
  printf '\n' >&2
  if [ -z "$ans" ]; then printf '%s' "$cur"; else printf '%s' "$ans"; fi
}

# ---------------------------------------------------------------------------
# The MaaS model list
# ---------------------------------------------------------------------------

# maas_models <base_url> <api_key> - prints the ids this endpoint serves, one
# per line, sorted. Non-zero with a reason on stderr if it cannot.
#
# The key goes to curl through a config file on stdin, not -H on the command
# line: arguments are visible to every user on the host through ps, and this
# runs on shared bastions. A pipe is not.
#
# The body is never printed. A 401 from this endpoint contains both a prefix
# of the key and a full SHA-256 of it, so echoing the error for the user to
# read would leak more than the prompt ever did.
#
# Ids are filtered to [A-Za-z0-9._-]. They are remote data on their way into
# a YAML file, and an id containing a quote or a leading * would break the
# parse or create an alias.
maas_models() {
  local base="$1" key="$2" raw code body
  raw=$(printf 'url = "%s/models"\nheader = "Authorization: Bearer %s"\n' "$base" "$key" \
        | curl -sS --max-time 20 -w '\n%{http_code}' -K - 2>/dev/null) || raw=""
  if [ -z "$raw" ]; then echo "could not reach $base" >&2; return 1; fi
  code="${raw##*$'\n'}"
  body="${raw%$'\n'*}"
  case "$code" in
    200) ;;
    # curl reports 000 when it got no HTTP response at all - DNS, refused
    # connection, TLS, timeout. "HTTP 000" would send someone looking for a
    # status code that does not exist.
    000)     echo "could not reach $base (no response)" >&2; return 1 ;;
    401|403) echo "that key was rejected (HTTP $code)" >&2; return 1 ;;
    404)     echo "no /models at $base - does the base_url end in /v1?" >&2; return 1 ;;
    *)       echo "the endpoint answered HTTP $code" >&2; return 1 ;;
  esac
  printf '%s' "$body" | python3 -c '
import json, re, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
ok = [m["id"] for m in d.get("data", [])
      if isinstance(m, dict) and isinstance(m.get("id"), str)
      and re.fullmatch(r"[A-Za-z0-9._-]+", m["id"])]
if not ok:
    sys.exit(1)
print("\n".join(sorted(ok)))
' 2>/dev/null || { echo "the endpoint returned no usable model list" >&2; return 1; }
}

# render_maas_block <api_key> <model...> - the YAML body for the WHOLE
# litellm_extra_models list, with the maas entry replaced or appended and
# every other endpoint carried through untouched.
#
# It has to emit the whole list because set_block replaces the whole block,
# and rendering only the maas entry silently deleted any sibling - a
# corporate Azure gateway, a second MaaS, a local vLLM. That produced valid
# YAML, so the guard passed, and the only thing printed was "registered N
# models"; all.yml is untracked, so the deleted entry was not in git either.
#
# Sorted model ids, so re-running with the same answers rewrites the same
# bytes. Built with yaml.safe_dump rather than printf, because the siblings
# are arbitrary user data and hand-rolling their quoting is how this breaks.
render_maas_block() {
  local key="$1"; shift
  _K="$key" _N="$MAAS_NAME" _C="$MAAS_CREDENTIAL" _U="$MAAS_BASE_URL" \
  _M="$*" python3 - "$AY" <<'PY'
import os, sys, yaml
try:
    doc = yaml.safe_load(open(sys.argv[1])) or {}
except Exception:
    doc = {}
existing = doc.get("litellm_extra_models")
if not isinstance(existing, list):
    existing = []
name = os.environ["_N"]
entry = {
    "name": name,
    "credential_name": os.environ["_C"],
    "base_url": os.environ["_U"],
    "api_key": os.environ["_K"],
    "models": sorted(os.environ["_M"].split()),
}
out, replaced = [], False
for e in existing:
    if isinstance(e, dict) and e.get("name") == name:
        # Keep any key the questions do not ask about - mode, provider,
        # namespace, publish_as_ai_asset - rather than dropping it.
        merged = dict(e); merged.update(entry); out.append(merged); replaced = True
    else:
        out.append(e)
if not replaced:
    out.append(entry)
sys.stdout.write(yaml.safe_dump(out, default_flow_style=False, sort_keys=False))
PY
}

# maas_current_models - the ids already configured for the maas endpoint.
maas_current_models() {
  python3 - "$AY" "$MAAS_NAME" <<'PY' 2>/dev/null || true
import sys, yaml
try:
    d = yaml.safe_load(open(sys.argv[1])) or {}
except Exception:
    sys.exit(0)
for e in (d.get("litellm_extra_models") or []):
    if isinstance(e, dict) and e.get("name") == sys.argv[2]:
        for m in (e.get("models") or []):
            print(m)
PY
}

# maas_current_key - the api_key already configured, so a re-run can query
# the endpoint without making the user paste it again.
maas_current_key() {
  python3 - "$AY" "$MAAS_NAME" <<'PY' 2>/dev/null || true
import sys, yaml
try:
    d = yaml.safe_load(open(sys.argv[1])) or {}
except Exception:
    sys.exit(0)
for e in (d.get("litellm_extra_models") or []):
    if isinstance(e, dict) and e.get("name") == sys.argv[2]:
        print(e.get("api_key") or "", end="")
PY
}

# ---------------------------------------------------------------------------
# Reporting the current state
# ---------------------------------------------------------------------------

DEMO_KEYS="demos_rag_eval demos_rag_judge demos_prompt_versions demos_tabular
           demos_model_serving demos_autorag demos_workbenches demos_run_jobs"

# gpu_selected - the instance types currently at one or more replicas.
gpu_selected() {
  python3 - "$AY" <<'PY' 2>/dev/null || echo "unreadable"
import sys, yaml
try:
    d = yaml.safe_load(open(sys.argv[1])) or {}
except Exception:
    print("unreadable"); raise SystemExit
g = [e for e in (d.get("gpu_machinesets") or [])
     if isinstance(e, dict) and (e.get("replicas") or 0) > 0]
print(", ".join("%s x%s" % (e["instance_type"], e["replicas"]) for e in g) or "none")
PY
}

# preset_needs_hf <preset> - only the hf:// presets pull from Hugging Face.
# Checked against roles/model_serving/defaults/main.yml: qwen3.8-27b-fp8 is
# the only one, every other preset is an oci:// modelcar. Asking for a token
# the run will never use is the kind of question that makes people stop
# reading the questions.
preset_needs_hf() { [ "$1" = "qwen3.8-27b-fp8" ]; }

# gpu_fit_warning - empty when the chosen model fits the chosen instance,
# otherwise a one-line reason.
#
# A count check only, deliberately: site.yml computes the real VRAM budget
# (weights + KV at max_model_len + per-sequence state, against
# gpu_count x per-GPU GB x 0.9313 x 0.9) and a second implementation of that
# in bash would drift from it. Two fit checks that disagree are worse than
# one. This catches only the unambiguous case - a 4-GPU model on a 1-GPU
# instance - which is also the most expensive wrong answer available here:
# two keystrokes, then 95 minutes, then a GPU node that can never serve it.
gpu_fit_warning() {
  python3 - "$AY" <<'PY' 2>/dev/null || true
import sys, yaml
try:
    cfg = yaml.safe_load(open(sys.argv[1])) or {}
    ms  = yaml.safe_load(open("roles/model_serving/defaults/main.yml")) or {}
    gw  = yaml.safe_load(open("roles/gpu_worker/defaults/main.yml")) or {}
except Exception:
    raise SystemExit
preset = cfg.get("model_preset") or ms.get("model_preset")
need = ((ms.get("model_presets") or {}).get(preset) or {}).get("gpu_count")
chosen = [e for e in (cfg.get("gpu_machinesets") or [])
          if isinstance(e, dict) and (e.get("replicas") or 0) > 0]
if not need or not chosen:
    raise SystemExit
specs = gw.get("gpu_instance_specs") or {}
for e in chosen:
    have = (specs.get(e["instance_type"]) or {}).get("gpus")
    if have is not None and have < need:
        print("%s needs %d GPUs on one node, %s has %d"
              % (preset, need, e["instance_type"], have))
        break
PY
}

# kube_contexts - the contexts in the caller's kubeconfig, one per line.
# `oc config get-contexts` exits 0 with no output when there is no kubeconfig
# at all, so callers must count lines rather than trust the status.
kube_contexts() { oc config get-contexts -o name 2>/dev/null || true; }

# summarise - the state of play, and anything about it that looks wrong.
# Printed before the single accept-or-change question, because the fast path
# is only safe if what you are accepting is on the screen.
summarise() {
  local ctx model gpu hf hf_src hf_show maaskey nmodels aws_id ndemos warn ctxlist fit
  ctx=$(get_var ocp_context); model=$(get_var model_preset); gpu=$(gpu_selected)
  # Read the same two sources the role does. model_hf_token in
  # roles/model_serving/defaults is `hf_token if set else env HF_TOKEN`, so
  # reporting all.yml alone told someone with HF_TOKEN exported - the setup
  # the defaults explicitly document - that their run would stop, and
  # invited them to paste a live token into a file they did not need to.
  hf=$(get_var hf_token); hf_src="all.yml"
  if [ -z "$hf" ] && [ -n "${HF_TOKEN:-}" ]; then hf="$HF_TOKEN"; hf_src="\$HF_TOKEN"; fi
  maaskey=$(maas_current_key)
  nmodels=$(maas_current_models | grep -c . || true)
  aws_id=$(get_var dashboard_aws_access_key_id)
  ndemos=0
  for k in $DEMO_KEYS; do truthy "$k" true && ndemos=$((ndemos+1)); done

  echo
  echo "  ------------------------------------------------------------------"
  if [ -n "$ctx" ]; then
    echo "   cluster     $ctx"
  else
    echo "   cluster     (follows oc config current-context: $(oc config current-context 2>/dev/null || echo 'none - not logged in'))"
  fi
  printf '   model       %-28s gpu       %s\n' "${model:-unset}" "$gpu"
  # The fallbacks here are not guesses - they are what Ansible resolves when
  # the key is absent, and the four keys do not agree. openrag and milvus
  # default to FALSE in their own roles; demos defaults to TRUE in its; and
  # omnigent has no role default at all, so site.yml's `| default(false)`
  # decides. Reporting all four as "on unless you turned them off" would be
  # a comfortable lie about three of them.
  printf '   openrag     %-28s milvus    %s\n' \
    "$(truthy deploy_openrag false && echo yes || echo no)" \
    "$(truthy deploy_milvus  false && echo yes || echo no)"
  printf '   demos       %-28s omnigent  %s\n' \
    "$(truthy deploy_demos true && echo "yes ($ndemos of 8)" || echo no)" \
    "$(has_var deploy_omnigent && { truthy deploy_omnigent false && echo yes || echo no; } || echo 'not set')"
  if [ "$hf_src" = "all.yml" ]; then hf_show="$(mask "$hf")"
  else hf_show="$(mask "$hf") from \$HF_TOKEN"; fi
  printf '   hf_token    %-28s maas key  %s\n' "$hf_show" "$(mask "$maaskey")"
  # Say what litellm will actually register. An entry with an empty api_key
  # is dropped by roles/litellm, so printing a bare count beside an unset
  # key claimed N remote models the cluster will not serve.
  if [ "$nmodels" -gt 0 ] && [ -z "$maaskey" ]; then
    nmodels="$nmodels (dropped, no api_key)"
  fi
  printf '   aws keys    %-28s maas models %s\n' "$(mask "$aws_id")" "$nmodels"
  echo "  ------------------------------------------------------------------"

  # Everything below is a real inconsistency, not a style note. Each one has
  # cost a run before.
  warn=0
  if [ -n "$ctx" ]; then
    ctxlist=$(kube_contexts)
    if [ -n "$ctxlist" ] && ! printf '%s\n' "$ctxlist" | grep -qxF "$ctx"; then
      echo "   !  ocp_context names a context that is not in your kubeconfig."
      echo "      Nothing validates this until a task fails: ocp_expected_api"
      echo "      is empty, so the preflight guard is inactive."
      warn=1
    fi
  fi
  if truthy deploy_demos true && ! truthy deploy_openrag false; then
    echo "   !  demos are on but openrag is off. The demos role needs the"
    echo "      OpenSearch that openrag deploys and fails when it is absent -"
    echo "      about 80 minutes in, after ODF, RHOAI and the GPU node."
    warn=1
  fi
  if ! has_var deploy_omnigent; then
    echo "   !  deploy_omnigent is absent from all.yml and has no role"
    echo "      default, so site.yml reads it as false and omnigent is"
    echo "      skipped silently. Answer the questions to set it either way."
    warn=1
  fi
  fit=$(gpu_fit_warning)
  if [ -n "$fit" ]; then
    echo "   !  $fit."
    echo "      site.yml reports this and proceeds by design, so the run"
    echo "      costs its full length and then vLLM refuses to start."
    warn=1
  fi
  if preset_needs_hf "$model" && [ -z "$hf" ]; then
    echo "   !  $model pulls from Hugging Face and hf_token is empty."
    echo "      The run stops at model_serving rather than downloading 31 GB"
    echo "      and getting a 401."
    warn=1
  fi
  # No file-permission warning here on purpose. run.sh creates all.yml at
  # 600, and apply_file_mode tightens it whenever a secret is written, so a
  # standing nag on the one screen you read before every deploy was noise
  # about a problem the script already fixes.
  if truthy deploy_demos true && ! truthy deploy_milvus false; then
    echo "   -  milvus is off: demos_rag_eval loses half its comparison and"
    echo "      demos_autorag loses its vector_io provider."
  fi
  [ "$warn" = 1 ] && echo
  return 0
}

# ---------------------------------------------------------------------------
# The questions
# ---------------------------------------------------------------------------

# ask_context - a menu of the kubeconfig's contexts, not a free-text field.
#
# The live all.yml on this machine pins a context that no longer exists, which
# is what free text gets you: a 56-character string nobody re-reads, pointing
# at a sandbox that was deleted. A menu makes a typo unrepresentable and the
# common answer one keystroke.
ask_context() {
  local cur="$1" list n i choice cur_live stale=0
  list=$(kube_contexts)
  cur_live=$(oc config current-context 2>/dev/null || true)
  n=$(printf '%s\n' "$list" | grep -c . || true)
  if [ -n "$cur" ] && [ "$n" -gt 0 ] && ! printf '%s\n' "$list" | grep -qxF "$cur"; then
    stale=1
  fi
  echo >&2
  if [ "$n" -eq 0 ]; then
    # Keep whatever is pinned. Returning '' here erased an existing pin with
    # no prompt, two lines after the banner promised "Enter keeps the
    # current value at every step".
    if command -v oc >/dev/null 2>&1; then
      echo "  No contexts in your kubeconfig - run 'oc login' first." >&2
    else
      echo "  oc is not on PATH, so the context list cannot be read." >&2
    fi
    if [ -n "$cur" ]; then
      echo "  Keeping the pinned ocp_context: $cur" >&2
    else
      echo "  ocp_context stays empty, so the run follows current-context." >&2
    fi
    printf '%s' "$cur"
    return 0
  fi
  echo "  Cluster to deploy to:" >&2
  echo "     0) follow 'oc config current-context' at run time   (recommended)" >&2
  i=0
  while IFS= read -r c; do
    [ -z "$c" ] && continue
    i=$((i+1))
    if [ "$c" = "$cur_live" ]; then printf '    %2d) %s   (current)\n' "$i" "$c" >&2
    else                            printf '    %2d) %s\n' "$i" "$c" >&2; fi
  done <<EOF
$list
EOF
  # A stale pin must not survive a keypress. Leaving it is the one answer
  # that is certainly wrong - every oc call fails with `context "..." does
  # not exist` - so Enter clears it instead of keeping it, which is also the
  # self-healing answer across sandbox rebuilds. Pinning is what rotted this
  # file in the first place.
  if [ "$stale" = 1 ]; then
    echo "  !! the pinned context is not in this kubeconfig:" >&2
    echo "       $cur" >&2
    echo "     Enter CLEARS the pin, so the run follows current-context." >&2
    read -r -p "  choice [Enter clears the stale pin]: " choice || choice=""
    [ -z "$choice" ] && { printf ''; return 0; }
  else
    if [ -n "$cur" ]; then
      echo "  currently pinned: $cur" >&2
    else
      echo "  currently: not pinned, follows current-context" >&2
    fi
    read -r -p "  choice [Enter keeps current]: " choice || choice=""
  fi
  case "$choice" in
    "")  printf '%s' "$cur" ;;
    0)   printf '' ;;
    *[!0-9]*) echo "  not a number - keeping what is there" >&2; printf '%s' "$cur" ;;
    *)   if [ "$choice" -ge 1 ] && [ "$choice" -le "$n" ]; then
           printf '%s' "$(printf '%s\n' "$list" | grep -c . >/dev/null; printf '%s\n' "$list" | sed -n "${choice}p")"
         else
           echo "  out of range - keeping what is there" >&2; printf '%s' "$cur"
         fi ;;
  esac
}

# ask_maas - the key, then the model list, then which of them to register.
#
# Queried rather than typed because the list drifts: all.yml here names five
# models and the endpoint currently serves six. A list nobody can refresh
# without curl is a list that goes stale.
#
# Returns 0 and sets MAAS_KEY_OUT / MAAS_MODELS_OUT, or returns 1 to mean
# "leave litellm_extra_models alone".
ask_maas() {
  local cur_key="$1" key models sel chosen i id n picked
  MAAS_KEY_OUT=""; MAAS_MODELS_OUT=""
  echo >&2
  echo "  Red Hat MaaS endpoint ($MAAS_NAME)" >&2
  echo "    $MAAS_BASE_URL" >&2
  if [ -n "$cur_key" ]; then
    echo "    The key in all.yml is a first-run seed: LiteLLM stores its own" >&2
    echo "    copy after the first deploy, so a key rotated in the LiteLLM UI" >&2
    echo "    survives. Enter keeps the stored one." >&2
  fi
  key=$(ask_secret "api key" "$cur_key")
  if [ -z "$key" ]; then
    echo "    no key - leaving the endpoint out. An entry with an empty key" >&2
    echo "    is dropped by the litellm role anyway, with only a debug line." >&2
    return 1
  fi

  echo "    asking the endpoint what it serves..." >&2
  # mktemp, not a fixed /tmp/.maaserr: that path is in a world-writable
  # directory, so any other user on the host can pre-plant it as a symlink
  # to something of ours and have `2>` follow it. group_vars/all.yml is an
  # obvious target.
  # An explicit template, not `mktemp -t NAME`: -t is deprecated on GNU and
  # means something different on BSD, and the two place the file differently.
  local errf; errf="$(mktemp "${TMPDIR:-/tmp}/maaserr.XXXXXX")" || errf=""
  if ! models=$(maas_models "$MAAS_BASE_URL" "$key" 2>"${errf:-/dev/null}"); then
    [ -n "$errf" ] && echo "    $(cat "$errf" 2>/dev/null)" >&2
    [ -n "$errf" ] && rm -f "$errf"
    # A failed lookup must not lose a working configuration.
    picked=$(maas_current_models | tr '\n' ' ')
    if [ -n "$picked" ]; then
      echo "    keeping the $(printf '%s' "$picked" | wc -w | tr -d ' ') models already in all.yml" >&2
      MAAS_KEY_OUT="$key"; MAAS_MODELS_OUT="$picked"; return 0
    fi
    return 1
  fi
  [ -n "$errf" ] && rm -f "$errf"
  n=$(printf '%s\n' "$models" | grep -c . || true)
  echo "    $n models available:" >&2
  i=0
  while IFS= read -r id; do
    [ -z "$id" ] && continue
    i=$((i+1)); printf '      %2d) %s\n' "$i" "$id" >&2
  done <<EOF
$models
EOF
  read -r -p "  which to register? [Enter = all, or e.g. 1,3,5]: " sel || sel=""
  if [ -z "$sel" ]; then
    chosen=$(printf '%s\n' "$models" | grep . | tr '\n' ' ')
  else
    chosen=""
    # Commas or spaces, either way. A junk entry is skipped with a note
    # rather than silently dropping the whole selection.
    for i in $(printf '%s' "$sel" | tr ',' ' '); do
      case "$i" in
        *[!0-9]*) echo "    ignoring '$i'" >&2; continue ;;
      esac
      if [ "$i" -ge 1 ] && [ "$i" -le "$n" ]; then
        chosen="$chosen $(printf '%s\n' "$models" | grep . | sed -n "${i}p")"
      else
        echo "    ignoring '$i' - out of range" >&2
      fi
    done
    if [ -z "$chosen" ]; then
      echo "    nothing valid selected - registering all $n" >&2
      chosen=$(printf '%s\n' "$models" | grep . | tr '\n' ' ')
    fi
  fi
  MAAS_KEY_OUT="$key"
  MAAS_MODELS_OUT="$chosen"
  return 0
}

ask_model() {
  local cur="$1" c
  echo >&2
  echo "  Model to serve (Enter keeps $cur):" >&2
  echo "     1) qwen3-4b          bf16  1 GPU    8 GB    32k context" >&2
  echo "     2) qwen3-8b          bf16  1 GPU   16 GB    40k context" >&2
  echo "     3) qwen3-14b         bf16  1 GPU   29 GB    40k context" >&2
  echo "     4) qwen3.8-27b       bf16  4 GPUs  56 GB   256k context   (needs g6e.12xlarge)" >&2
  echo "     5) qwen3.8-27b-fp8   FP8   1 GPU   31 GB    64k context   (Hugging Face, needs hf_token)" >&2
  read -r -p "  choice [Enter to keep current]: " c || c=""
  case "$c" in
    1) printf 'qwen3-4b' ;;        2) printf 'qwen3-8b' ;;
    3) printf 'qwen3-14b' ;;       4) printf 'qwen3.8-27b' ;;
    5) printf 'qwen3.8-27b-fp8' ;;
    "") printf '%s' "$cur" ;;
    *) echo "  not one of the choices - keeping $cur" >&2; printf '%s' "$cur" ;;
  esac
}

ask_gpu() {
  local c
  echo >&2
  echo "  GPU instance to create (Enter keeps gpu_machinesets as they are):" >&2
  echo "     1) g4dn.4xlarge   1 x T4         16 GB    4 vCPU" >&2
  echo "     2) g6e.4xlarge    1 x L40S       48 GB   16 vCPU" >&2
  echo "     3) g6e.12xlarge   4 x L40S      192 GB   48 vCPU" >&2
  echo "     4) g7e.2xlarge    1 x RTX6000    96 GB    8 vCPU" >&2
  echo "     5) g7e.4xlarge    1 x RTX6000    96 GB   16 vCPU" >&2
  echo "     6) g7e.8xlarge    1 x RTX6000    96 GB   32 vCPU" >&2
  echo "     7) g7e.12xlarge   2 x RTX6000   192 GB   48 vCPU" >&2
  echo "     8) g7e.24xlarge   4 x RTX6000   384 GB   96 vCPU" >&2
  echo "     9) p4d.24xlarge   8 x A100 40G  320 GB   96 vCPU" >&2
  echo "    10) p4de.24xlarge  8 x A100 80G  640 GB   96 vCPU" >&2
  echo "  4-6 are one Blackwell card each and differ only in CPU and host" >&2
  echo "  RAM; 96 GB on a single GPU often replaces four L40S at option 3." >&2
  echo "  g7e only adds cards at 12xlarge and above." >&2
  read -r -p "  choice [Enter to keep current]: " c || c=""
  case "$c" in
    1) printf 'g4dn.4xlarge' ;;  2) printf 'g6e.4xlarge' ;;  3) printf 'g6e.12xlarge' ;;
    4) printf 'g7e.2xlarge' ;;   5) printf 'g7e.4xlarge' ;;  6) printf 'g7e.8xlarge' ;;
    7) printf 'g7e.12xlarge' ;;  8) printf 'g7e.24xlarge' ;; 9) printf 'p4d.24xlarge' ;;
    10) printf 'p4de.24xlarge' ;;
    "") printf '' ;;
    *) echo "  not one of the choices - keeping the configured instances" >&2; printf '' ;;
  esac
}

# set_gpu <type> - put this type at one replica and every other at zero,
# appending it when all.yml has never heard of it.
#
# Without the append, choosing an instance the file did not list zeroed every
# entry and added nothing: the run then built MachineSets at 0 replicas and
# model_serving waited half an hour for a GPU node nobody had asked AWS for.
# Hit on sandbox3270.
#
# The block must contain no comments. This awk ends the list at the first
# line starting with neither a space nor a dash, which a '#' matches - a
# comment between entries makes it insert a duplicate at 1 replica and leave
# the original at 0, and the role then re-applies the same MachineSet name at
# zero and scales away the node it just waited for.
set_gpu() {
  local want="$1" tmp
  tmp="$(_mktemp)" || return 1
  _W="$want" awk '
    BEGIN { want = ENVIRON["_W"] }
    /^gpu_machinesets:/ { inblock=1; print; next }
    inblock && /^[^ -]/ {
      if (!seen) { print "- instance_type: " want; print "  replicas: 1"; seen=1 }
      inblock=0
    }
    # Normalise before comparing. `- instance_type: "g6e.4xlarge"` gives
    # cur with the quotes attached and a CRLF file gives a trailing \r;
    # either way the compare failed, the existing entry was zeroed and a
    # SECOND entry for the same type was inserted at 1 replica. That is the
    # sandbox3270 duplicate this function exists to prevent, and grep -A1
    # cannot see it.
    inblock && /^- instance_type:/ {
      cur=$3; sub(/\r$/, "", cur); gsub(/^["'"'"']|["'"'"']$/, "", cur)
      if (cur==want) seen=1; print; next
    }
    inblock && /^  replicas:/ { print "  replicas: " (cur==want ? 1 : 0); next }
    { print }
    END { if (inblock && !seen) { print "- instance_type: " want; print "  replicas: 1" } }
  ' "$AY" > "$tmp" && _replace "$tmp"
}

# ---------------------------------------------------------------------------
# Writing the answers
# ---------------------------------------------------------------------------

# secure_file - tighten all.yml to 0600 once it is known to hold a secret.
#
# Called only after a secret is actually written, so it is never a silent
# surprise: the user has just typed a token into a hidden prompt, and a
# hidden prompt reasonably implies the value is not going somewhere
# world-readable. It currently is - the default umask here is 022 - so say
# what happened rather than quietly leaving it, or quietly changing it.
# Only records the intent. The walkthrough runs against a staged copy that
# _mktemp already created under umask 077, so a mode check here would always
# see 0600, always take the early return, and never tighten the real file -
# which is exactly what it did until this was split in two. The decision has
# to be applied at the hand-off, against the path that survives.
_NEEDS_600=0
secure_file() { _NEEDS_600=1; }

# apply_file_mode <path> - act on the intent recorded above.
apply_file_mode() {
  [ "$_NEEDS_600" = 1 ] || return 0
  # An unknown mode falls through to the chmod on purpose: if we cannot tell
  # whether the file is already tight, tightening it is the safe answer.
  case "$(_mode "$1" || true)" in
    600|400) return 0 ;;
  esac
  chmod 600 "$1" 2>/dev/null \
    && echo "  group_vars/all.yml set to mode 600: it now holds a credential"
}

# seed_absent <key> <value> - write only when the key is not there.
# Used by the fast path: accepting the summary should make all.yml say what
# the run will do, without overwriting anything deliberate.
seed_absent() {
  has_var "$1" && return 0
  guard_yaml "$1" -- set_bool "$1" "$2"
  echo "    + $1: $2   (was absent)"
}

# materialise_defaults - make the implicit explicit.
#
# deploy_omnigent has no role default and site.yml reads it as
# `| default(false)`, so leaving it out means omnigent is skipped with
# nothing saying so. deploy_demos is the opposite - roles/demos/defaults
# carries `true`, so leaving it out means it runs. Two keys, opposite
# meanings when absent, which is exactly why neither should be absent.
# Deliberately only ONE key. Writing a value that merely restates a role
# default looks tidy and costs you the next repo bump: omnigent_version is
# v0.1.1 in roles/omnigent/defaults, and copying it into all.yml turns a
# repo-managed pin into a local override that never moves again. The same
# argument covers omnigent_sandboxes and all eight demos_* switches, which
# are already true in roles/demos/defaults.
#
# deploy_omnigent is the exception worth writing, because its absence is not
# a default - there is no role default anywhere, so site.yml:424 falls back
# to `| default(false)` and the role is skipped with nothing saying so.
materialise_defaults() {
  seed_absent deploy_omnigent false
}

# ---------------------------------------------------------------------------
# The flow
# ---------------------------------------------------------------------------

# configure_interactive - summary, one question, and the walkthrough behind it.
#
# The summary-first shape is deliberate. Nine sequential prompts in front of
# every deploy is itself a regression for the person running this on their
# fifth sandbox of the week; the common case has to be one keystroke. What
# makes that safe is that everything being accepted is on the screen above
# the question, including the things that are wrong.
#
# The walkthrough runs against a COPY and is moved into place at the end, so
# answering four questions and then hitting Ctrl-C leaves all.yml exactly as
# it was. Today's script writes model_preset and then asks the GPU question,
# so that window already exists; staging closes it without costing a
# keystroke, which a final are-you-sure confirm would not.
_STAGED=""
_stage_cleanup() { [ -n "$_STAGED" ] && rm -f "$_STAGED"; _STAGED=""; }

# An INT trap that only cleans up does not abort: bash runs the handler and
# then CARRIES ON, so Ctrl-C half way through the questions deleted the
# staged file and left the rest of the walkthrough writing to a path that no
# longer existed. A Ctrl-C has to end the run, which means the handler must
# exit, and with 130 so callers can tell it from a failure.
_stage_interrupt() {
  _stage_cleanup
  echo >&2
  echo "  Interrupted. Nothing was written to group_vars/all.yml." >&2
  exit 130
}

# The real path, for the things that must not be answered from inside the
# staged copy: its permissions, and the summary line about them.
_REAL_AY=""

# ask_missing_credentials - offer the three credentials that are not set.
#
# Asked before the accept question rather than only inside the walkthrough,
# because a freshly created all.yml has none of them and accepting the
# summary would otherwise deploy with no Hugging Face token, no MaaS
# endpoint and no AWS key, having never mentioned them. Each one is skipped
# with Enter, and one already set is not asked about at all - so this costs
# nothing on a re-run and the fast path stays one keystroke.
ask_missing_credentials() {
  local model hf asked=0 new_hf aws_id aws_sec
  model=$(get_var model_preset)
  hf=$(get_var hf_token)
  [ -z "$hf" ] && hf="${HF_TOKEN:-}"

  if [ -z "$hf" ]; then
    echo
    if preset_needs_hf "$model"; then
      echo "  hf_token - $model pulls ~31 GB from Hugging Face, so it needs one."
    else
      echo "  hf_token - not needed by $model, which is a modelcar. Only the"
      echo "  fp8 preset pulls from Hugging Face. Enter skips."
    fi
    new_hf=$(ask_secret "hf_token" "")
    if [ -n "$new_hf" ]; then
      guard_yaml hf_token -- set_string hf_token "$new_hf"
      secure_file; asked=1
    fi
  fi

  if [ -z "$(maas_current_key)" ]; then
    if ask_maas ""; then
      guard_yaml litellm_extra_models -- \
        set_block litellm_extra_models "$(render_maas_block "$MAAS_KEY_OUT" $MAAS_MODELS_OUT)"
      echo "    registered $(printf '%s' "$MAAS_MODELS_OUT" | wc -w | tr -d ' ') models from $MAAS_NAME"
      secure_file; asked=1
    fi
  fi

  if [ -z "$(get_var dashboard_aws_access_key_id)" ]; then
    echo
    echo "  AWS keys - without them the Operations Dashboard still deploys,"
    echo "  but its node Stop/Start resiliency tests are disabled, so you get"
    echo "  a read-only view of the nodes rather than the full one. Needs only"
    echo "  ec2:DescribeInstances, StopInstances, StartInstances. Enter skips."
    aws_id=$(ask_secret "access key id" "")
    if [ -n "$aws_id" ]; then
      aws_sec=$(ask_secret "secret access key" "")
      guard_yaml dashboard_aws_access_key_id     -- set_string dashboard_aws_access_key_id "$aws_id"
      guard_yaml dashboard_aws_secret_access_key -- set_string dashboard_aws_secret_access_key "$aws_sec"
      secure_file; asked=1
    fi
  fi

  # These write straight to the real file rather than to a staged copy, so
  # the tightening has to happen here too: configure_interactive applies it
  # after the walkthrough, and the fast path never enters one.
  apply_file_mode "$AY"

  # Only re-print when something actually changed above.
  [ "$asked" = 1 ] && return 0
  return 1
}

configure_interactive() {
  summarise
  if ask_missing_credentials; then
    echo
    summarise
  fi
  if ask_yn "Deploy with these?" y; then
    materialise_defaults
    echo
    return 0
  fi

  local real="$AY" rc=0
  _STAGED="$(_mktemp)" || return 1
  trap '_stage_cleanup' EXIT
  trap '_stage_interrupt' INT TERM
  cp "$real" "$_STAGED"
  AY="$_STAGED"; _REAL_AY="$real"
  _walkthrough || rc=$?
  AY="$real"
  if [ "$rc" = 0 ]; then
    _replace "$_STAGED"
    _STAGED=""
    apply_file_mode "$real"
  else
    echo "  Nothing was written to group_vars/all.yml." >&2
    _stage_cleanup
  fi
  _REAL_AY=""
  trap - EXIT INT TERM
  return 0
}

_walkthrough() {
  local ctx model gpu hf aws_id aws_sec demo_default
  local new_ctx new_model new_gpu new_hf

  echo
  echo "  Changing settings. Enter keeps the current value at every step."

  # --- cluster -------------------------------------------------------------
  ctx=$(get_var ocp_context)
  new_ctx=$(ask_context "$ctx")
  guard_yaml ocp_context -- set_string ocp_context "$new_ctx"

  # --- model and hardware --------------------------------------------------
  model=$(get_var model_preset)
  new_model=$(ask_model "$model")
  [ -n "$new_model" ] && guard_yaml model_preset -- set_raw model_preset "$new_model"
  new_gpu=$(ask_gpu)
  if [ -n "$new_gpu" ]; then
    guard_yaml gpu_machinesets -- set_gpu "$new_gpu"
    # Say it out loud rather than trusting the edit: the failure this
    # replaces was silent in exactly this spot.
    if ! grep -A1 "^- instance_type: ${new_gpu}\$" "$AY" | grep -q "replicas: 1"; then
      echo "  WARNING: ${new_gpu} is still not at 1 replica. Check" >&2
      echo "           gpu_machinesets by hand before continuing." >&2
    fi
  fi

  # --- components ----------------------------------------------------------
  # openrag is asked BEFORE demos, because the answer changes what the demos
  # question should default to. The other order produces the single most
  # plausible broken combination - skip the heavy RAG stack, keep the demos -
  # which builds ODF, RHOAI, a GPU node and a model and then fails.
  echo
  echo "  OpenRAG adds a 3-node OpenSearch (~9Gi RAM, 3x20Gi PVCs), docling"
  echo "  and a CPU embedding model. Milvus adds a third vector store that"
  echo "  two of the demos compare against."
  if ask_yn "Deploy OpenRAG and Milvus?" y; then
    guard_yaml deploy_openrag -- set_bool deploy_openrag true
    guard_yaml deploy_milvus  -- set_bool deploy_milvus  true
    demo_default=y
  else
    guard_yaml deploy_openrag -- set_bool deploy_openrag false
    guard_yaml deploy_milvus  -- set_bool deploy_milvus  false
    demo_default=n
    echo "    note: the demos need OpenSearch from OpenRAG, so they are"
    echo "          defaulted off below."
  fi

  echo
  if [ "$demo_default" = n ]; then
    echo "  The demos role fails without OpenSearch - about 80 minutes in."
  else
    echo "  Eight demos: retrieval A/B, answer judging, prompt versions,"
    echo "  tabular MLOps, model serving, workbenches, AutoRAG. Roughly ten"
    echo "  minutes of extra build time."
  fi
  if ask_yn "Deploy the demos?" "$demo_default"; then
    guard_yaml deploy_demos -- set_bool deploy_demos true
    # Only the master switch. The eight individual demos_* are already true
    # in roles/demos/defaults, so writing them here would add eight lines of
    # noise to all.yml and freeze them against any later change in the repo.
    # A demo deliberately turned off before also stays off, which answering
    # "yes, deploy the demos" should not silently undo.
  else
    guard_yaml deploy_demos -- set_bool deploy_demos false
  fi

  echo
  echo "  Omnigent orchestrates agent CLIs behind one server, logging in with"
  echo "  your OpenShift identity and using the cluster's own LiteLLM."
  if ask_yn "Deploy Omnigent?" y; then
    guard_yaml deploy_omnigent -- set_bool deploy_omnigent true
    has_var omnigent_sandboxes || guard_yaml omnigent_sandboxes -- set_bool omnigent_sandboxes true
  else
    guard_yaml deploy_omnigent -- set_bool deploy_omnigent false
  fi

  # --- credentials ---------------------------------------------------------
  # Only asked when the chosen model actually pulls from Hugging Face.
  # Everything but qwen3.8-27b-fp8 is an oci:// modelcar and never touches
  # it, and a question whose answer is never used teaches people to stop
  # reading the questions.
  model=$(get_var model_preset)
  hf=$(get_var hf_token)
  if preset_needs_hf "$model"; then
    echo
    echo "  $model pulls ~31 GB from Hugging Face at pod start, so it needs a"
    echo "  token."
    if [ -z "$hf" ] && [ -n "${HF_TOKEN:-}" ]; then
      # roles/model_serving reads hf_token or else the HF_TOKEN environment
      # variable, so this run already has one. Inviting a paste here would
      # put a live token into a file that did not need to hold it.
      echo "  \$HF_TOKEN is exported $(mask "$HF_TOKEN"), and the role uses it"
      echo "  when hf_token is empty, so there is nothing to set."
      if ask_yn "Store it in all.yml as well?" n; then
        guard_yaml hf_token -- set_string hf_token "$HF_TOKEN"
        secure_file
      fi
    else
      echo "  The run stops before creating anything if it is missing."
      new_hf=$(ask_secret "hf_token" "$hf")
      guard_yaml hf_token -- set_string hf_token "$new_hf"
      [ -n "$new_hf" ] && secure_file
    fi
  elif [ -n "$hf" ]; then
    echo
    echo "  hf_token $(mask "$hf") - kept. $model is a modelcar and will not use it."
  fi

  if ask_maas "$(maas_current_key)"; then
    # $MAAS_MODELS_OUT is deliberately unquoted: it is a space-separated list
    # and each id must become its own argument. The ids are safe to split on
    # whitespace because maas_models filters them to [A-Za-z0-9._-] first -
    # they are remote data, and an id with a space or a quote in it would
    # otherwise reach the YAML writer.
    guard_yaml litellm_extra_models -- \
      set_block litellm_extra_models "$(render_maas_block "$MAAS_KEY_OUT" $MAAS_MODELS_OUT)"
    echo "    registered $(printf '%s' "$MAAS_MODELS_OUT" | wc -w | tr -d ' ') models from $MAAS_NAME"
    secure_file
  fi

  # Defaults to NO, unlike the component switches above. This one is a
  # credential prompt, not a deploy toggle: defaulting to "yes, stop and ask
  # for two AWS secrets" is the opposite of fast, and the dashboard works
  # without them - it loses only the node Stop/Start resiliency tests.
  echo
  aws_id=$(get_var dashboard_aws_access_key_id)
  aws_sec=$(get_var dashboard_aws_secret_access_key)
  echo "  A dedicated AWS key lets the dashboard run node Stop/Start tests."
  echo "  Needs only ec2:DescribeInstances, StopInstances, StartInstances."
  if [ -n "$aws_id" ]; then
    if ask_yn "AWS keys are set $(mask "$aws_id"). Change them?" n; then
      aws_id=$(ask_secret "access key id" "$aws_id")
      aws_sec=$(ask_secret "secret access key" "$aws_sec")
      guard_yaml dashboard_aws_access_key_id     -- set_string dashboard_aws_access_key_id "$aws_id"
      guard_yaml dashboard_aws_secret_access_key -- set_string dashboard_aws_secret_access_key "$aws_sec"
      [ -n "$aws_sec" ] && secure_file
    fi
  elif ask_yn "Set them now?" n; then
    aws_id=$(ask_secret "access key id" "")
    aws_sec=$(ask_secret "secret access key" "")
    guard_yaml dashboard_aws_access_key_id     -- set_string dashboard_aws_access_key_id "$aws_id"
    guard_yaml dashboard_aws_secret_access_key -- set_string dashboard_aws_secret_access_key "$aws_sec"
    [ -n "$aws_sec" ] && secure_file
  fi

  materialise_defaults
  echo
  echo "  This is what will be written to group_vars/all.yml:"
  summarise
}
