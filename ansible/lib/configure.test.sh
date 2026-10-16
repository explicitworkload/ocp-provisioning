#!/bin/bash
# Tests for lib/configure.sh. Run from the ansible/ directory:
#
#     ./lib/configure.test.sh
#
# No cluster and no network needed: the MaaS endpoint is pointed at a local
# stub, and every other function works on a throwaway YAML file in TMPDIR.
#
# These cover the cases that are painful to reach by hand and expensive to
# get wrong - a secret containing the sed delimiter, a key missing from
# all.yml, EOF part way through the questions - which is the whole reason
# the questions live in a sourceable file rather than inline in run.sh.
set -uo pipefail
cd "$(dirname "$0")/.."

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n       %s\n' "$1" "${2:-}"; }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "want [$3] got [$2]"; fi; }
# A `case` inside $( ) does not parse on bash 3.2 - the pattern's ')' closes
# the substitution - so substring tests go through a function.
has()  { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"; [ -n "${STUB_PID:-}" ] && kill "$STUB_PID" 2>/dev/null' EXIT

export AY="$WORK/all.yml"
source lib/configure.sh

fresh() {
  cat > "$AY" <<'EOF'
---
ocp_context: ""
hf_token: ""
gpu_machinesets:
- instance_type: g4dn.4xlarge
  replicas: 0
- instance_type: g6e.4xlarge
  replicas: 1
model_preset: qwen3-4b
deploy_openrag: true
deploy_milvus: true
dashboard_aws_access_key_id: ""
dashboard_aws_secret_access_key: ""
#demos_gen_model: granite-3-2-8b-instruct
litellm_extra_models:
- name: maas-rhdp
  credential_name: rhdp-maas
  base_url: https://example.invalid/v1
  api_key: "seedkey"
  models:
  - alpha
  - beta
EOF
}
yget() { python3 -c "
import yaml,sys
d=yaml.safe_load(open('$AY'))
v=d
for k in sys.argv[1].split('.'):
    v = v[int(k)] if k.isdigit() else v.get(k)
    if v is None: break
print('' if v is None else v, end='')" "$1"; }
parses() { python3 -c "import yaml;yaml.safe_load(open('$AY'))" 2>/dev/null; }

# ---------------------------------------------------------------------------
echo "== reading =="
fresh
chk "has_var finds a present key"        "$(has_var model_preset && echo y || echo n)" y
chk "has_var rejects an absent key"      "$(has_var deploy_demos && echo y || echo n)" n
chk "has_var ignores a commented key"    "$(has_var demos_gen_model && echo y || echo n)" n
chk "has_var ignores an indented key"    "$(has_var credential_name && echo y || echo n)" n
chk "get_var unquotes"                   "$(get_var model_preset)" "qwen3-4b"
chk "truthy reads true"                  "$(truthy deploy_openrag false && echo y || echo n)" y
chk "truthy falls back when absent"      "$(truthy deploy_demos true && echo y || echo n)" y
chk "truthy falls back to false"         "$(truthy deploy_omnigent false && echo y || echo n)" n

# ---------------------------------------------------------------------------
echo "== writing scalars =="
fresh; set_raw model_preset qwen3-14b
chk "substitute in place"                "$(yget model_preset)" "qwen3-14b"
chk "no duplicate definition"            "$(grep -c '^model_preset:' "$AY")" "1"
fresh; set_bool deploy_demos true
chk "append an absent key"               "$(yget deploy_demos)" "True"
fresh; set_raw demos_gen_model granite-3-2-8b-instruct
chk "revive a commented key"             "$(yget demos_gen_model)" "granite-3-2-8b-instruct"
chk "comment not duplicated"             "$(grep -c 'demos_gen_model' "$AY")" "1"
fresh; set_bool deploy_demos false
chk "false is a real boolean"            "$(python3 -c "import yaml;print(yaml.safe_load(open('$AY'))['deploy_demos'] is False)")" "True"

echo "== writing nasty secrets =="
# Each of these breaks at least one of sed, awk -v, or double-quoted YAML.
while IFS='|' read -r val desc; do
  [ -z "$desc" ] && continue
  fresh; set_string hf_token "$val"
  got=$(python3 -c "import yaml;print(yaml.safe_load(open('$AY'))['hf_token'],end='')")
  chk "$desc" "$got" "$val"
done <<'CASES'
sk-abc|def|pipe, the sed delimiter
sk-a&b|ampersand, the sed whole-match
sk-a\nb\tc|backslash escapes, which awk -v would expand
sk-it's-mine|single quote
sk-"quoted"|double quote
sk-a#comment|hash
sk-a:b|colon
@leading-at|YAML reserved indicator @
%leading-pct|YAML reserved indicator %
*anchor|YAML alias indicator
$(whoami)|command substitution
sk-ünïcödé|unicode
---|document separator
0755|an all-digit value that would octal-coerce
yes|a value YAML would coerce to boolean True
CASES

echo "== the writer never corrupts the file =="
fresh; set_string hf_token 'x'; set_bool deploy_demos true; set_gpu g7e.12xlarge
chk "still valid YAML"                   "$(parses && echo y || echo n)" y
chk "neighbours intact"                  "$(yget model_preset)" "qwen3-4b"

echo "== file permissions survive a write =="
fresh; chmod 600 "$AY"; set_bool deploy_demos true
chk "600 is preserved"                   "$(_mode "$AY")" "600"

echo "== guard_yaml reverts a bad write =="
fresh; cp "$AY" "$WORK/pre"
breaker() { printf 'oops: [unclosed\n' >> "$AY"; }
guard_yaml "a deliberate break" -- breaker 2>/dev/null
chk "file restored byte for byte"        "$(cmp -s "$WORK/pre" "$AY" && echo y || echo n)" y
guard_yaml hf_token -- set_string hf_token 'good|value' 2>/dev/null
chk "a good write passes through"        "$(yget hf_token)" "good|value"
chk "no temp files left behind"          "$(ls "$AY".?????? 2>/dev/null | wc -l | tr -d ' ')" "0"

# ---------------------------------------------------------------------------
echo "== gpu_machinesets, every run.sh menu option =="
for t in g4dn.4xlarge g6e.4xlarge g6e.12xlarge g7e.2xlarge g7e.4xlarge \
         g7e.8xlarge g7e.12xlarge g7e.24xlarge p4d.24xlarge p4de.24xlarge; do
  fresh; set_gpu "$t"
  r=$(python3 -c "
import yaml
d=yaml.safe_load(open('$AY'))['gpu_machinesets']
h=[e['replicas'] for e in d if e['instance_type']=='$t']
nz=[e['instance_type'] for e in d if e['replicas']>0]
print('ok' if h==[1] and nz==['$t'] else f'dup={len(h)} nz={nz}')")
  chk "$t -> exactly one entry at 1 replica" "$r" "ok"
done

echo "== gpu block is idempotent =="
fresh; set_gpu g7e.4xlarge; cp "$AY" "$WORK/g1"; set_gpu g7e.4xlarge
chk "same type twice is byte-identical"  "$(cmp -s "$WORK/g1" "$AY" && echo y || echo n)" y

# ---------------------------------------------------------------------------
echo "== prompts =="
chk "yn: Enter takes default yes"        "$(printf '\n'  | { ask_yn q y; } >/dev/null 2>&1 && echo y || echo n)" y
chk "yn: Enter takes default no"         "$(printf '\n'  | { ask_yn q n; } >/dev/null 2>&1 && echo y || echo n)" n
chk "yn: explicit n beats default yes"   "$(printf 'n\n' | { ask_yn q y; } >/dev/null 2>&1 && echo y || echo n)" n
chk "yn: uppercase Y"                    "$(printf 'Y\n' | { ask_yn q n; } >/dev/null 2>&1 && echo y || echo n)" y
chk "yn: typo takes the default"         "$(printf 'wat\n' | { ask_yn q y; } >/dev/null 2>&1 && echo y || echo n)" y
chk "yn: EOF takes the default"          "$(: | { ask_yn q y; } >/dev/null 2>&1 && echo y || echo n)" y
chk "text: Enter keeps current"          "$(printf '\n' | ask_text q old 2>/dev/null)" "old"
chk "text: EOF keeps current"            "$(: | ask_text q old 2>/dev/null)" "old"
chk "text: metacharacters survive"       "$(printf 'a & b | c\n' | ask_text q '' 2>/dev/null)" "a & b | c"
chk "secret: Enter keeps current"        "$(printf '\n' | ask_secret q sk-old 2>/dev/null)" "sk-old"
chk "secret: typed value wins"           "$(printf 'sk-new\n' | ask_secret q sk-old 2>/dev/null)" "sk-new"
leak=$(printf '\n' | ask_secret q 'sk-supersecret-abcd' 2>&1 >/dev/null)
chk "secret: existing value never shown" "$(has supersecret "$leak" && echo LEAK || echo safe)" "safe"
chk "mask: empty"                        "$(mask '')" "(not set)"
chk "mask: short shows no tail"          "$(mask 'abc')" "(set, 3 chars)"
chk "mask: long shows last four only"    "$(mask 'abcdefghijkl')" "(set, 12 chars, ends ijkl)"

# ---------------------------------------------------------------------------
echo "== maas endpoint =="
python3 - "$WORK" <<'PY' &
import http.server, json, sys, threading, time
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(s):
        if s.headers.get("Authorization") != "Bearer goodkey":
            s.send_response(401); s.end_headers()
            s.wfile.write(b'{"error":{"message":"bad key sk-abcd hash=deadbeef"}}'); return
        s.send_response(200); s.send_header("Content-Type","application/json"); s.end_headers()
        s.wfile.write(json.dumps({"data":[{"id":"zeta"},{"id":"alpha"},
                                          {"id":"bad id!"},{"id":"Docling"}]}).encode())
    def log_message(s,*a): pass
srv = http.server.HTTPServer(("127.0.0.1", 8749), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
time.sleep(25)
PY
STUB_PID=$!
sleep 1.2
STUB=http://127.0.0.1:8749/v1
chk "good key lists models, sorted"      "$(maas_models "$STUB" goodkey 2>/dev/null | tr '\n' ' ')" "Docling alpha zeta "
chk "an id with a space is dropped"      "$(maas_models "$STUB" goodkey 2>/dev/null | grep -c 'bad id')" "0"
err=$(maas_models "$STUB" wrongkey 2>&1 >/dev/null)
chk "bad key is reported"                "$(has rejected "$err" && echo y || echo "n:$err")" y
chk "401 body is never printed"          "$( { has deadbeef "$err" || has sk-abcd "$err"; } && echo LEAK || echo safe)" "safe"
err=$(maas_models "http://127.0.0.1:1/v1" k 2>&1 >/dev/null)
chk "unreachable is reported plainly"    "$(has "could not reach" "$err" && echo y || echo "n:$err")" y
chk "key is absent from curl's argv"     "$(printf 'url = "x"\nheader = "Authorization: Bearer K"\n' | curl --help >/dev/null 2>&1; pgrep -fl 'curl.*Bearer' >/dev/null 2>&1 && echo LEAK || echo safe)" "safe"

echo "== maas block rendering =="
fresh
body=$(render_maas_block 'sk-a|b&c' alpha beta)
guard_yaml litellm_extra_models -- set_block litellm_extra_models "$body"
chk "block replaced"                     "$(yget litellm_extra_models.0.name)" "maas-rhdp"
chk "nasty key round-trips"              "$(yget litellm_extra_models.0.api_key)" 'sk-a|b&c'
chk "models written"                     "$(python3 -c "import yaml;print(' '.join(yaml.safe_load(open('$AY'))['litellm_extra_models'][0]['models']))")" "alpha beta"
chk "old models gone"                    "$(grep -c 'seedkey' "$AY")" "0"
cp "$AY" "$WORK/b1"; guard_yaml litellm_extra_models -- set_block litellm_extra_models "$body"
chk "block write is idempotent"          "$(cmp -s "$WORK/b1" "$AY" && echo y || echo n)" y
chk "neighbours intact after block"      "$(yget model_preset)" "qwen3-4b"

# ---------------------------------------------------------------------------
echo "== materialise_defaults =="
fresh; materialise_defaults >/dev/null
chk "deploy_omnigent written as false"   "$(python3 -c "import yaml;print(yaml.safe_load(open('$AY'))['deploy_omnigent'] is False)")" "True"
chk "deploy_demos NOT written"           "$(has_var deploy_demos && echo y || echo n)" "n"
chk "no demos_* noise added"             "$(python3 -c "
import yaml;d=yaml.safe_load(open('$AY'))
print(sum(1 for k in d if k.startswith('demos_')))")" "0"
chk "omnigent_sandboxes NOT written"     "$(has_var omnigent_sandboxes && echo y || echo n)" "n"
chk "omnigent_version NOT written"       "$(has_var omnigent_version && echo y || echo n)" "n"
chk "an existing value is not touched"   "$(yget deploy_openrag)" "True"
cp "$AY" "$WORK/m1"; materialise_defaults >/dev/null
chk "materialise is idempotent"          "$(cmp -s "$WORK/m1" "$AY" && echo y || echo n)" y

echo "== staging: a failed walkthrough writes nothing =="
fresh; cp "$AY" "$WORK/pre2"
_walkthrough() { set_bool deploy_demos true; set_string hf_token 'half-written'; return 1; }
printf 'n\n' | configure_interactive >/dev/null 2>&1
chk "all.yml untouched after a failure"  "$(cmp -s "$WORK/pre2" "$AY" && echo y || echo n)" y
chk "no staged file left behind"         "$(ls "$AY".?????? 2>/dev/null | wc -l | tr -d ' ')" "0"
_walkthrough() { set_bool deploy_demos true; return 0; }
fresh; printf 'n\n' | configure_interactive >/dev/null 2>&1
chk "a successful walkthrough lands"     "$(yget deploy_demos)" "True"
# Re-source rather than `unset -f`: unset removes the REAL _walkthrough that
# sourcing defined, not just the stub above it, and everything after would
# then run against a configure_interactive whose walkthrough does not exist.
source lib/configure.sh
chk "the real _walkthrough is back"      "$(type -t _walkthrough)" "function"

echo "== the fast path only fills in what is missing =="
fresh; set_bool deploy_demos false
printf '\n' | configure_interactive >/dev/null 2>&1
chk "a deliberate false is respected"    "$(python3 -c "import yaml;print(yaml.safe_load(open('$AY'))['deploy_demos'] is False)")" "True"
chk "truthy matches the role defaults"   "$(truthy deploy_openrag false && echo y || echo n)" "y"
chk "and the absent key is filled in"    "$(python3 -c "import yaml;print(yaml.safe_load(open('$AY'))['deploy_omnigent'] is False)")" "True"

# ---------------------------------------------------------------------------
# Regressions. Every one of these is a bug that shipped and was found by
# review afterwards; the assertions are what would have caught them.
echo "== regressions =="

# secure_file ran against the staged 0600 copy, always took its early return,
# and _replace then restored the real file's 644 - so a token typed at a
# hidden prompt landed world-readable with nothing on screen saying so.
fresh; chmod 644 "$AY"
printf 'n\n\n5\n\n\n\n\nTOKEN123\n\n\n' | configure_interactive >/dev/null 2>&1
chk "a typed secret leaves all.yml at 600" "$(_mode "$AY")" "600"
chk "and the secret was actually written"  "$(yget hf_token)" "TOKEN123"
fresh; chmod 644 "$AY"
printf '\n' | configure_interactive >/dev/null 2>&1
chk "no secret typed: mode left alone"     "$(_mode "$AY")" "644"

# The INT trap only cleaned up; bash then CONTINUED, so the rest of the
# walkthrough wrote to a path that had just been deleted.
fresh; cp "$AY" "$WORK/pre3"
cat > "$WORK/int.sh" <<INTEOF
#!/bin/bash
set -uo pipefail
cd "$(pwd)"
export AY="$AY"
source lib/configure.sh
# Stand in for a Ctrl-C arriving part way through the questions.
_walkthrough() { set_bool deploy_demos true; kill -INT \$\$; set_string hf_token 'written-after-the-signal'; return 0; }
# Redirected, not piped: a pipeline would run configure_interactive in a
# subshell, where \$\$ is still the PARENT's pid, so the kill below would
# signal a shell that has no trap. run.sh calls it directly, so this is the
# arrangement that matches production.
printf 'n\n' > "\$AY.in"
configure_interactive < "\$AY.in"
INTEOF
chmod +x "$WORK/int.sh"
"$WORK/int.sh" >/dev/null 2>&1
chk "Ctrl-C exits 130, not 0"              "$?" "130"
chk "Ctrl-C leaves all.yml untouched"      "$(cmp -s "$WORK/pre3" "$AY" && echo y || echo n)" y
chk "nothing written after the signal"     "$(grep -c 'written-after-the-signal' "$AY")" "0"
chk "Ctrl-C leaves no staged file"         "$(ls "$AY".?????? 2>/dev/null | wc -l | tr -d ' ')" "0"

# guard_yaml validated after the write but never before, so a file that was
# already unparseable made every answer look like the thing that broke it.
printf -- '---\nbroken: [unclosed\n' > "$AY"
guard_yaml deploy_demos -- set_bool deploy_demos true 2>/dev/null
chk "a pre-broken file does not block writes" "$(grep -c '^deploy_demos: true' "$AY")" "1"

# set_block replaced the whole list, deleting any endpoint the questions do
# not know about - and all.yml is untracked, so it was not in git either.
cat > "$AY" <<'YEOF'
---
litellm_extra_models:
- name: corporate-azure
  base_url: https://corp/v1
  api_key: 'x'
  mode: embedding
  models:
  - gpt-4o
- name: maas-rhdp
  base_url: https://maas/v1
  api_key: 'y'
  models:
  - alpha
YEOF
set_block litellm_extra_models "$(render_maas_block newkey beta gamma)"
chk "a sibling endpoint survives"          "$(python3 -c "
import yaml;print(','.join(e['name'] for e in yaml.safe_load(open('$AY'))['litellm_extra_models']))")" "corporate-azure,maas-rhdp"
chk "the sibling keeps its own keys"       "$(yget litellm_extra_models.0.mode)" "embedding"
chk "the maas entry is updated"            "$(yget litellm_extra_models.1.api_key)" "newkey"
chk "and its models replaced"              "$(python3 -c "
import yaml;print(' '.join(yaml.safe_load(open('$AY'))['litellm_extra_models'][1]['models']))")" "beta gamma"
cp "$AY" "$WORK/sib1"; set_block litellm_extra_models "$(render_maas_block newkey beta gamma)"
chk "merge is still idempotent"            "$(cmp -s "$WORK/sib1" "$AY" && echo y || echo n)" y

# set_gpu compared $3 raw, so a quoted value or a CRLF file never matched:
# the existing entry was zeroed and a duplicate inserted at 1 replica - the
# exact sandbox3270 failure the function exists to prevent.
printf -- '---\ngpu_machinesets:\n- instance_type: "g6e.4xlarge"\n  replicas: 1\n' > "$AY"
set_gpu g6e.4xlarge
chk "a quoted instance_type is matched"    "$(python3 -c "
import yaml;d=yaml.safe_load(open('$AY'))['gpu_machinesets']
print(len([e for e in d if str(e['instance_type']).strip('\"')=='g6e.4xlarge']))")" "1"
printf -- '---\r\ngpu_machinesets:\r\n- instance_type: g6e.4xlarge\r\n  replicas: 1\r\n' > "$AY"
set_gpu g6e.4xlarge
chk "a CRLF file is matched"               "$(python3 -c "
import yaml;d=yaml.safe_load(open('$AY'))['gpu_machinesets']
print(len([e for e in d if str(e['instance_type']).strip()=='g6e.4xlarge']))")" "1"

# ask_context returned '' when oc listed nothing, erasing a pin with no
# prompt, two lines after promising that Enter keeps the current value.
printf -- "---\nocp_context: 'default/api-pinned:6443/admin'\n" > "$AY"
chk "no contexts keeps the pin"            "$(KUBECONFIG=/nonexistent ask_context "$(get_var ocp_context)" 2>/dev/null)" "default/api-pinned:6443/admin"

# The summary counted models litellm will drop, and ignored the HF_TOKEN
# fallback the model_serving role actually reads.
fresh; set_block litellm_extra_models "$(render_maas_block '' alpha beta)"
chk "models with no key are marked dropped" "$(has 'dropped, no api_key' "$(summarise 2>&1)" && echo y || echo n)" y
fresh
chk "models with a key are not"             "$(has 'dropped, no api_key' "$(summarise 2>&1)" && echo y || echo n)" n
fresh; set_raw model_preset qwen3.8-27b-fp8; set_string hf_token ''
chk "HF_TOKEN env suppresses the warning"  "$(HF_TOKEN=hf_fromenv123456 summarise 2>&1 | grep -c 'pulls from Hugging Face and hf_token is empty')" "0"
chk "and is shown as coming from the env"  "$(HF_TOKEN=hf_fromenv123456 summarise 2>&1 | grep -c 'from \$HF_TOKEN')" "1"

# ---------------------------------------------------------------------------
echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
