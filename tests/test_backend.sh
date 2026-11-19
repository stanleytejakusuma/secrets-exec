#!/usr/bin/env bash
# backend.conf: where bin/secrets-exec fetches values from. A sandbox copy replaces ssh with a
# fake that records host and remote command; no remote, key store or network is touched.
# Usage: bash tests/test_backend.sh   (ENGINE_FILE=<path> to test another engine revision)
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE_FILE="${ENGINE_FILE:-$REPO/bin/secrets-exec}"
SECRET="FAKE-BACKEND-VALUE-3361"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/.config/secrets-exec"
VE="$T/bin/secrets-exec"
cp "$ENGINE_FILE" "$VE"
sed -i -E "s#(^|[^/[:alnum:]])ssh( -n)? -o BatchMode=yes#\1$T/fakessh\2 -o BatchMode=yes#" "$VE"
# Abort before running if any real transport invocation remains.
grep -q "$T/fakessh -n -o BatchMode=yes" "$VE" && ! grep -qE '(^|[[:space:]])ssh( -n)? -o BatchMode=yes' "$VE" \
  || { echo 'FAIL sandbox transport substitution'; exit 1; }
chmod 0755 "$VE"

# Fake ssh: logs "<host> | <remote command>"; answers get/list by the first word.
cat > "$T/fakessh" <<EOF
#!/bin/bash -p
host="\${@: -2:1}"; cmd="\${@: -1}"
builtin echo "\$host | \$cmd" >> "$T/ssh.log"
case "\$cmd" in
  /opt/kv/get*)  builtin echo "$SECRET" ;;
  /opt/kv/list*) builtin echo "keys:"; builtin echo "  TOKEN_A" ;;
  *) exit 1 ;;
esac
EOF
chmod 0700 "$T/fakessh"
cat > "$T/consumer" <<EOF
#!/bin/sh
echo ran > "$T/ran"; [ "\$DEMO_TOKEN" = "$SECRET" ] && echo got-value > "$T/ran"
EOF
chmod 0755 "$T/consumer"

CONF="$T/.config/secrets-exec/consumers.conf"
B="$T/.config/secrets-exec/backend.conf"
cat > "$CONF" <<EOF
demo|fixture-bundle|TOKEN_A|DEMO_TOKEN|$T/consumer|
glob|fixture-bundle|TOKEN_*|DEMO_TOKEN|$T/consumer|
badbundle|fix'ture|TOKEN_A|DEMO_TOKEN|$T/consumer|
badkey|fixture-bundle|TOK;EN|DEMO_TOKEN|$T/consumer|
globbadbundle|fix'ture;id|TOKEN_*|DEMO_TOKEN|$T/consumer|
globinterp|fixture-bundle|TOKEN_*|DEMO_TOKEN|/usr/bin/python3|
EOF
good() { printf '%s\n' '# fixture backend' host=keyhost.example 'get=/opt/kv/get {bundle} {key} --reveal' \
  'list=/opt/kv/list {bundle}' > "$B"; }

pass=0; fail=0
ok() { pass=$((pass+1)); echo "PASS $1"; }
ko() { fail=$((fail+1)); echo "FAIL $1"; }
run() { rm -f "$T/ran" "$T/ssh.log"; out="$("$VE" "$@" 2>&1)"; rc=$?; }
nossh() { [ ! -s "$T/ssh.log" ] && [ ! -e "$T/ran" ]; }

# 1. happy path: host and both templates come from backend.conf, bundle/key are quoted
good; run demo
if [ "$rc" = 0 ] && [ "$(cat "$T/ran" 2>/dev/null)" = got-value ] \
   && [ "$(cat "$T/ssh.log")" = "keyhost.example | /opt/kv/get 'fixture-bundle' 'TOKEN_A' --reveal" ]; then
  ok "fetch uses backend host and get template"
else ko "happy path: rc=$rc ssh=$(cat "$T/ssh.log" 2>/dev/null) out=$out"; fi
run glob
if [ "$rc" = 0 ] && grep -qx "keyhost.example | /opt/kv/list 'fixture-bundle'" "$T/ssh.log"; then ok "key listing uses list template"
else ko "glob: rc=$rc ssh=$(cat "$T/ssh.log" 2>/dev/null)"; fi

# 2. refusals happen before any remote call or consumer run
rm -f "$B"; run demo
if [ "$rc" = 2 ] && nossh && grep -q 'no backend' <<<"$out"; then ok "missing backend.conf refused"; else ko "missing: rc=$rc out=$out"; fi
rm -f "$B"; run not-a-consumer
if [ "$rc" = 2 ] && grep -q "unknown consumer" <<<"$out"; then ok "refusals do not depend on backend.conf"; else ko "unknown without backend: $out"; fi

bad_backend() { # bad_backend <label> <lines...>
  local label="$1"; shift; printf '%s\n' "$@" > "$B"; run demo
  if [ "$rc" = 2 ] && nossh; then ok "$label refused"; else ko "$label: rc=$rc out=$out"; fi
}
G='get=/opt/kv/get {bundle} {key}'; L='list=/opt/kv/list {bundle}'
bad_backend "host as ssh option"     'host=-oProxyCommand=touch_x' "$G" "$L"
bad_backend "host with space"        'host=a b' "$G" "$L"
bad_backend "missing host"           "$G" "$L"
bad_backend "get with ;"             host=k 'get=/opt/kv/get {bundle} {key}; id' "$L"
bad_backend "get with quote"         host=k "get=/opt/kv/get '{bundle}' {key}" "$L"
bad_backend "get with \$()"          host=k 'get=$(id) {bundle} {key}' "$L"
bad_backend "get without {key}"      host=k 'get=/opt/kv/get {bundle}' "$L"
bad_backend "key before bundle"      host=k 'get=/opt/kv/get {key} {bundle}' "$L"
bad_backend "list without {bundle}"  host=k "$G" 'list=/opt/kv/list'
bad_backend "unknown key"            host=k "$G" "$L" 'proxy=x'
bad_backend "duplicate host"         host=k host=j "$G" "$L"

# 3. registry bundle/key are plain tokens before they reach the remote command
good; run badbundle
if [ "$rc" = 2 ] && nossh; then ok "quote in bundle refused before fetch"; else ko "badbundle: rc=$rc out=$out"; fi
run badkey
if [ "$rc" = 2 ] && nossh; then ok "metacharacter in key refused before fetch"; else ko "badkey: rc=$rc out=$out"; fi
# Wildcard rows list key names remotely; every local check must run before that listing.
run globbadbundle
if [ "$rc" = 2 ] && nossh; then ok "wildcard row: bad bundle refused before key listing"; else ko "globbadbundle: rc=$rc ssh=$(cat "$T/ssh.log" 2>/dev/null)"; fi
run globinterp
if [ "$rc" = 2 ] && nossh; then ok "wildcard row: interpreter refused before key listing"; else ko "globinterp: rc=$rc ssh=$(cat "$T/ssh.log" 2>/dev/null)"; fi
run glob https://attacker.example
if [ "$rc" = 2 ] && nossh; then ok "wildcard row: caller URL refused before key listing"; else ko "glob URL: rc=$rc ssh=$(cat "$T/ssh.log" 2>/dev/null)"; fi

# 4. the engine source names no host or remote path of its own
if ! grep -qE '^(REMOTE|SCRIPTS)="[^"]' "$ENGINE_FILE"; then ok "no hardcoded backend in the engine"
else ko "engine still hardcodes a backend"; fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
