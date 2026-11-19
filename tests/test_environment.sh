#!/usr/bin/env bash
# Environment and consumer-name hardening of bin/secrets-exec.
# A sandbox copy replaces the engine's ssh fetch with a fake that serves a fixture value,
# so no remote, vault or network is touched. Each case checks that a caller who controls
# only the environment or the consumer name cannot disclose that value.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE_FILE="${ENGINE_FILE:-$REPO/bin/secrets-exec}"
SECRET="FAKE-SECRET-VALUE-4729"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/.config/secrets-exec"
VE="$T/bin/secrets-exec"
cp "$ENGINE_FILE" "$VE"
sed -i -E "s#(^|[^/[:alnum:]])ssh( -n)? -o BatchMode=yes#\1$T/fakessh\2 -o BatchMode=yes#" "$VE"
# Abort before running if the transport substitution ever stops matching the source.
grep -q "$T/fakessh -n -o BatchMode=yes" "$VE" && ! grep -qE '(^|[[:space:]])ssh( -n)? -o BatchMode=yes' "$VE" \
  || { echo 'FAIL sandbox transport substitution'; exit 1; }
chmod 0755 "$VE"

# Fake ssh: privileged-mode bash so the caller's hooks cannot act inside the fixture itself.
cat > "$T/fakessh" <<EOF
#!/bin/bash -p
cmd="\${!#}"
builtin echo "\$cmd" >> "$T/ssh-calls.log"
case "\$cmd" in kv-get*) builtin echo "$SECRET" ;; *) exit 1 ;; esac
EOF
chmod 0700 "$T/fakessh"
printf '%s\n' host=fixture-keyhost 'get=kv-get {bundle} {key}' 'list=kv-list {bundle}' \
  > "$T/.config/secrets-exec/backend.conf"

# Fixture consumer: reports through printf and records its environment.
cat > "$T/consumer" <<EOF
#!/bin/bash
printf 'consumer-ran\n'
/usr/bin/env > "$T/env.out"
EOF
chmod 0755 "$T/consumer"

CONF="$T/.config/secrets-exec/consumers.conf"
AUDIT="$T/.config/secrets-exec/audit.log"
cat > "$CONF" <<EOF
# x|fixture-bundle|FIXTURE_KEY|DEMO_TOKEN|$T/consumer|
envdump|fixture-bundle|FIXTURE_KEY|DEMO_TOKEN|$T/consumer|
1|fixture-bundle|FIXTURE_KEY|DEMO_TOKEN|$T/consumer|
1000|fixture-bundle|FIXTURE_KEY|DEMO_TOKEN|$T/consumer|
sentinel|fixture-bundle|FIXTURE_KEY|__SECRETS_EXEC_NONE__|$T/consumer|
EOF

pass=0; fail=0
ok() { pass=$((pass+1)); echo "PASS $1"; }
ko() { fail=$((fail+1)); echo "FAIL $1"; }
fetches() { [ -f "$T/ssh-calls.log" ] && wc -l < "$T/ssh-calls.log" || echo 0; }

# sanity: the sandbox really fetches the fixture value and runs the consumer
rm -f "$T/env.out"
out="$("$VE" envdump 2>&1)"
if grep -qx consumer-ran <<<"$out" && grep -qx "DEMO_TOKEN=$SECRET" "$T/env.out"; then ok "sandbox fetch reaches consumer"
else ko "sandbox fetch: $(head -c 200 <<<"$out")"; fi

# 1. caller-enabled tracing cannot reach the engine or the consumer
out="$(env SHELLOPTS=xtrace "$VE" envdump 2>&1)"
if ! grep -q "$SECRET" <<<"$out" && ! grep -q '^+' <<<"$out"; then ok "SHELLOPTS=xtrace: no trace, no value"
else ko "SHELLOPTS=xtrace leaked: $(grep -c "$SECRET" <<<"$out") value lines"; fi

# 2. an exported function cannot override a builtin inside the consumer
out="$(env 'BASH_FUNC_printf%%=() { builtin echo "HIJACK:$DEMO_TOKEN"; }' "$VE" envdump 2>&1)"
if grep -qx consumer-ran <<<"$out" && ! grep -q "HIJACK" <<<"$out" && ! grep -q "$SECRET" <<<"$out"; then
  ok "exported printf function ignored"
else ko "exported function: $(head -c 200 <<<"$out")"; fi

# 3. proxy, CA, key-log and loader variables do not reach the consumer; ordinary ones do
rm -f "$T/env.out"
HTTPS_PROXY=http://proxy.example.invalid:9 CURL_CA_BUNDLE=/tmp/ca.pem SSLKEYLOGFILE=/tmp/keys \
  LD_PRELOAD=/nonexistent-lib.so MY_ORDINARY=keep "$VE" envdump >/dev/null 2>&1
if [ -f "$T/env.out" ] && grep -qx "DEMO_TOKEN=$SECRET" "$T/env.out" && grep -qx MY_ORDINARY=keep "$T/env.out" \
   && ! grep -qE '^(HTTPS_PROXY|CURL_CA_BUNDLE|SSLKEYLOGFILE|LD_PRELOAD)=' "$T/env.out"; then
  ok "proxy/CA/keylog/loader scrubbed, ordinary kept"
else ko "scrub: $(grep -E '^(HTTPS_PROXY|CURL_CA_BUNDLE|SSLKEYLOGFILE|LD_PRELOAD|MY_ORDINARY|DEMO_TOKEN)=' "$T/env.out" 2>/dev/null | cut -d= -f1 | tr '\n' ' ')"; fi

# 3b. other trust-store and curl settings (Python requests CA bundle, any CURL_* setting)
rm -f "$T/env.out"
REQUESTS_CA_BUNDLE=/tmp/attacker-ca.pem CURL_NETRC_FILE=/tmp/netrc CURL_SSL_BACKEND=x SSL_CERT_X=y \
  "$VE" envdump >/dev/null 2>&1
if [ -f "$T/env.out" ] && grep -qx "DEMO_TOKEN=$SECRET" "$T/env.out" \
   && ! grep -qE '^(REQUESTS_CA_BUNDLE|CURL_NETRC_FILE|CURL_SSL_BACKEND|SSL_CERT_X)=' "$T/env.out"; then
  ok "REQUESTS_CA_BUNDLE, CURL_* and SSL_CERT_* scrubbed"
else ko "trust-store scrub: $(grep -E '^(REQUESTS_CA_BUNDLE|CURL_NETRC_FILE|CURL_SSL_BACKEND|SSL_CERT_X)=' "$T/env.out" 2>/dev/null | cut -d= -f1 | tr '\n' ' ')"; fi

# 4. new files are private even under a permissive umask
rm -f "$AUDIT"
(umask 000; "$VE" not-a-consumer >/dev/null 2>&1)
if [ "$(stat -c %a "$AUDIT" 2>/dev/null)" = 600 ]; then ok "audit created 600 under umask 000"
else ko "audit mode $(stat -c %a "$AUDIT" 2>/dev/null)"; fi

# 5. consumer names are exact, never patterns; refused before any fetch
for bad in 'env.*' '.*' 'envdump|x' $'envdump\nx' '# x' 'env[a-z]ump'; do
  before="$(fetches)"; rm -f "$T/env.out"
  "$VE" "$bad" >/dev/null 2>&1; rc=$?
  if [ "$rc" = 2 ] && [ "$(fetches)" = "$before" ] && [ ! -f "$T/env.out" ]; then ok "name $(printf '%q' "$bad") refused before fetch"
  else ko "name $(printf '%q' "$bad"): rc=$rc"; fi
done

# 6. numeric-looking names are strings: '01' or '1e3' must not select rows '1' or '1000'
for bad in 01 1e3 1.0 +1; do
  before="$(fetches)"; rm -f "$T/env.out"
  "$VE" "$bad" >/dev/null 2>&1; rc=$?
  if [ "$rc" = 2 ] && [ "$(fetches)" = "$before" ] && [ ! -f "$T/env.out" ]; then ok "numeric alias $bad refused"
  else ko "numeric alias $bad: rc=$rc"; fi
done
rm -f "$T/env.out"; "$VE" 1 >/dev/null 2>&1
if grep -qx "DEMO_TOKEN=$SECRET" "$T/env.out" 2>/dev/null; then ok "exact numeric name 1 runs"; else ko "exact numeric name 1"; fi

# 7. the scrub never removes a legitimate credential variable
rm -f "$T/env.out"; "$VE" sentinel >/dev/null 2>&1
if grep -qx "__SECRETS_EXEC_NONE__=$SECRET" "$T/env.out" 2>/dev/null; then ok "no invented sentinel removes a credential"; else ko "sentinel envvar was scrubbed"; fi

# 8. a poisoned PATH cannot move the registry before the engine pins PATH
mkdir -p "$T/evil" "$T/evilhome/bin" "$T/evilhome/.config/secrets-exec"
cat > "$T/evil/dirname" <<EOF
#!/bin/sh
case "\$1" in */bin) echo "$T/evilhome" ;; *) echo "$T/evilhome/bin" ;; esac
EOF
cat > "$T/evilconsumer" <<'EOF'
#!/bin/sh
echo "EVIL:$DEMO_TOKEN"
EOF
chmod 0755 "$T/evil/dirname" "$T/evilconsumer"
echo "envdump|fixture-bundle|FIXTURE_KEY|DEMO_TOKEN|$T/evilconsumer|" > "$T/evilhome/.config/secrets-exec/consumers.conf"
cp "$T/.config/secrets-exec/backend.conf" "$T/evilhome/.config/secrets-exec/backend.conf"
out="$(PATH="$T/evil:/usr/bin:/bin" "$VE" envdump 2>&1)"
if ! grep -q EVIL <<<"$out" && ! grep -q "$SECRET" <<<"$out"; then ok "poisoned PATH cannot redirect the registry"
else ko "poisoned PATH: $(head -c 120 <<<"$out")"; fi

# 9. a real preloaded library in the caller's environment is not loaded by programs started
#    after the credential is exported (the engine's own process is out of scope: see threat model)
if command -v gcc >/dev/null 2>&1; then
  cat > "$T/pre.c" <<'EOF'
#include <stdio.h>
#include <stdlib.h>
__attribute__((constructor)) static void c(void) {
  const char *v = getenv("DEMO_TOKEN"); if (v) fprintf(stderr, "PRELOAD:%s\n", v); }
EOF
  gcc -shared -fPIC -o "$T/pre.so" "$T/pre.c"
  out="$(LD_PRELOAD="$T/pre.so" "$VE" envdump 2>&1)"
  if grep -qx consumer-ran <<<"$out" && ! grep -q "PRELOAD:" <<<"$out"; then ok "preloaded library not loaded after export"
  else ko "preload: $(grep -c PRELOAD: <<<"$out") disclosure lines"; fi
else
  echo "SKIP preload library test (no gcc)"
fi

# 10. bash special variables in the caller's environment do not break the output contract
for fd in 1 2; do
  out="$(env BASH_XTRACEFD=$fd "$VE" envdump 2>&1)"
  if grep -qx consumer-ran <<<"$out" && ! grep -qi 'bad file descriptor\|readonly' <<<"$out"; then ok "BASH_XTRACEFD=$fd: consumer output intact"
  else ko "BASH_XTRACEFD=$fd: $(head -c 160 <<<"$out")"; fi
  err="$(env BASH_XTRACEFD=$fd "$VE" not-a-consumer 2>&1 >/dev/null)"
  if grep -q '^secrets-exec: ' <<<"$err"; then ok "BASH_XTRACEFD=$fd: refusal text intact"
  else ko "BASH_XTRACEFD=$fd refusal: $(head -c 160 <<<"$err")"; fi
done
out="$(env SHELLOPTS=xtrace BASHOPTS=extglob "$VE" envdump 2>&1)"
if grep -qx consumer-ran <<<"$out" && ! grep -qi 'readonly' <<<"$out"; then ok "SHELLOPTS/BASHOPTS: no diagnostics"
else ko "SHELLOPTS/BASHOPTS diagnostics: $(grep -i readonly <<<"$out" | head -2)"; fi

# no value ever reaches the audit log
if ! grep -q "$SECRET" "$AUDIT"; then ok "audit holds no value"; else ko "audit holds the value"; fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
