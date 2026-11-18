#!/usr/bin/env bash
# Name, ID and path checks must not depend on the caller's locale. In some UTF-8 locales bash
# ranges such as [A-Za-z] also match letters like 'é'. Sandboxed: fake ssh, stub curl, no network.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
LOC=""
for l in en_US.UTF-8 en_US.utf8; do
  if locale -a 2>/dev/null | grep -qix "$l"; then LOC="$l"; break; fi
done
if [ -z "$LOC" ]; then echo "SKIP no en_US UTF-8 locale installed"; echo "0 passed, 0 failed"; exit 0; fi
# Only meaningful if this locale shows the problem in the first place.
if ! LC_ALL="$LOC" bash -c '[[ "é" =~ ^[A-Za-z]$ ]]'; then
  echo "SKIP $LOC does not widen [A-Za-z] here"; echo "0 passed, 0 failed"; exit 0
fi

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/.config/secrets-exec"
VE="$T/bin/secrets-exec"
cp "$REPO/bin/secrets-exec" "$VE"
sed -i -E "s#(^|[^/[:alnum:]])ssh( -n)? -o BatchMode=yes#\1$T/fakessh\2 -o BatchMode=yes#" "$VE"
chmod 0755 "$VE"
cat > "$T/fakessh" <<EOF
#!/bin/bash -p
builtin echo "\${@: -1}" >> "$T/ssh.log"
builtin echo FAKE-LOCALE-VALUE
EOF
chmod 0700 "$T/fakessh"
printf '%s\n' host=keyhost 'get=kv-get {bundle} {key}' 'list=kv-list {bundle}' \
  > "$T/.config/secrets-exec/backend.conf"
printf '#!/bin/sh\necho ran > "%s/ran"\n' "$T" > "$T/consumer"; chmod 0755 "$T/consumer"
cat > "$T/.config/secrets-exec/consumers.conf" <<EOF
démo|bundle|TOKEN|DEMO_TOKEN|$T/consumer|
plain|bündle|TOKEN|DEMO_TOKEN|$T/consumer|
keyed|bundle|TOKÉN|DEMO_TOKEN|$T/consumer|
ok|bundle|TOKEN|DEMO_TOKEN|$T/consumer|
EOF

pass=0; fail=0
ok() { pass=$((pass+1)); echo "PASS $1"; }
ko() { fail=$((fail+1)); echo "FAIL $1"; }
refused() { # refused <label> [VAR=value...] -- <engine args...>
  local label="$1"; shift; local -a envs=(); while [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
  rm -f "$T/ran" "$T/ssh.log"
  env LC_ALL="$LOC" "${envs[@]}" "$VE" "$@" >/dev/null 2>&1; local rc=$?
  if [ "$rc" = 2 ] && [ ! -e "$T/ran" ] && [ ! -s "$T/ssh.log" ]; then ok "$label"; else ko "$label (rc=$rc)"; fi
}
refused "non-ASCII consumer name refused" -- démo
refused "non-ASCII bundle refused before fetch" -- plain
refused "non-ASCII key refused before fetch" -- keyed
refused "non-ASCII call ID refused" SECRETS_EXEC_CALL_ID=é -- ok

rm -f "$T/ran"; env LC_ALL="$LOC" "$VE" ok >/dev/null 2>&1; rc=$?
if [ "$rc" = 0 ] && [ -e "$T/ran" ]; then ok "ASCII consumer still runs under $LOC"; else ko "ASCII consumer (rc=$rc)"; fi

# HTTP engine path check
cp "$REPO/http-get-engine.sh" "$T/http.sh"
sed -i "s#^CURL=/usr/bin/curl\$#CURL=$T/stubcurl#" "$T/http.sh"
printf '#!/bin/bash\ncat > "%s/curl-config"\n' "$T" > "$T/stubcurl"; chmod 0755 "$T/http.sh" "$T/stubcurl"
printf '%s\n' API_BASE=https://api.example.com TOKEN_VAR=FIXTURE_TOK 'ALLOW=/repos/*' > "$T/http.conf"
rm -f "$T/curl-config"
env LC_ALL="$LOC" FIXTURE_TOK=x "$T/http.sh" "$T/http.conf" '/repos/é' >/dev/null 2>&1; rc=$?
if [ "$rc" = 2 ] && [ ! -f "$T/curl-config" ]; then ok "non-ASCII HTTP path refused"; else ko "HTTP path (rc=$rc)"; fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
