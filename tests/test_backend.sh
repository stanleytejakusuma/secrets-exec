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

# 4. placeholders are whole words; no other braces (a remote shell would brace-expand them)
bad_backend "placeholder inside a word" host=k 'get=/opt/kv/get x{bundle} {key}' "$L"
bad_backend "brace expansion word"      host=k 'get=/opt/kv/get {a,b} {bundle} {key}' "$L"

# 5. host=local runs a local helper directly: no ssh, no shell, names passed as separate argv
cat > "$T/localhelper" <<EOF
#!/bin/bash -p
IFS='|'; builtin echo "\$*" >> "$T/local.log"
IFS= read -r -t 1 line && builtin echo "stdin:\$line" >> "$T/local.log"
case "\$1" in
  get)  builtin printf '%s' "$SECRET" ;;
  list) builtin echo TOKEN_A ;;
  *) exit 1 ;;
esac
EOF
chmod 0755 "$T/localhelper"
local_backend() { printf '%s\n' host=local "get=$T/localhelper get {bundle} {key}" \
  "list=$T/localhelper list {bundle}" > "$B"; }
lrun() { rm -f "$T/local.log"; run "$@"; }
local_backend; lrun demo < <(echo piped-input)
if [ "$rc" = 0 ] && [ "$(cat "$T/ran" 2>/dev/null)" = got-value ] && [ ! -e "$T/ssh.log" ] \
   && [ "$(cat "$T/local.log" 2>/dev/null)" = "get|fixture-bundle|TOKEN_A" ]; then
  ok "local backend: helper gets bare names as argv, no ssh, no stdin"
else ko "local happy: rc=$rc out=$out log=$(cat "$T/local.log" 2>/dev/null)"; fi
lrun glob
if [ "$rc" = 0 ] && grep -qx "list|fixture-bundle" "$T/local.log" && [ ! -e "$T/ssh.log" ]; then
  ok "local backend: key listing uses list template"
else ko "local glob: rc=$rc log=$(cat "$T/local.log" 2>/dev/null)"; fi
# The local helper starts with a minimal environment, not the caller's.
cat > "$T/envhelper" <<EOF
#!/bin/bash -p
/usr/bin/env > "$T/helper-env"
builtin printf '%s' "$SECRET"
EOF
chmod 0755 "$T/envhelper"
printf '%s\n' host=local "get=$T/envhelper {bundle} {key}" "list=$T/envhelper {bundle}" > "$B"
rm -f "$T/helper-env"
rm -f "$T/ran"; out="$(VAULT_ADDR=x GNUPGHOME=/evil PASSWORD_STORE_DIR=/evil "$VE" demo 2>&1)"; rc=$?
if [ "$rc" = 0 ] && ! grep -qE '^(VAULT_ADDR|GNUPGHOME|PASSWORD_STORE_DIR)=' "$T/helper-env" \
   && grep -qx "HOME=$T" "$T/helper-env" && grep -qx 'PATH=/usr/bin:/bin' "$T/helper-env"; then
  ok "local backend: helper gets a minimal environment, HOME pinned"
else ko "local env: rc=$rc env=$(tr '\n' ' ' < "$T/helper-env" 2>/dev/null)"; fi
# A name starting with '-' never reaches a local helper (it could be read as an option).
printf 'dash|-bundle|TOKEN_A|DEMO_TOKEN|%s|\n' "$T/consumer" >> "$CONF"
local_backend; lrun dash
if [ "$rc" = 2 ] && [ ! -e "$T/local.log" ] && [ ! -e "$T/ran" ] && grep -q "starting with .-." <<<"$out"; then ok "local backend: leading-dash name refused with a reason"
else ko "dash name: rc=$rc log=$(cat "$T/local.log" 2>/dev/null)"; fi

bad_local() { # bad_local <label> <lines...>
  local label="$1"; shift; printf '%s\n' host=local "$@" > "$B"; lrun demo
  if [ "$rc" = 2 ] && nossh && [ ! -e "$T/local.log" ]; then ok "$label refused"; else ko "$label: rc=$rc out=$out"; fi
}
LL="list=$T/localhelper list {bundle}"
bad_local "local: relative helper"     'get=localhelper get {bundle} {key}' "$LL"
bad_local "local: missing helper"      "get=$T/no-such-helper get {bundle} {key}" "$LL"
bad_local "local: helper is a dir"     "get=$T get {bundle} {key}" "$LL"
bad_local "local: list helper relative" "get=$T/localhelper get {bundle} {key}" 'list=localhelper list {bundle}'

# 6. the engine source names no host or remote path of its own
if ! grep -qE '^(REMOTE|SCRIPTS)="[^"]' "$ENGINE_FILE"; then ok "no hardcoded backend in the engine"
else ko "engine still hardcodes a backend"; fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
