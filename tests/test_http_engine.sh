#!/usr/bin/env bash
# Path and limit checks of http-get-engine.sh. A sandbox copy points CURL at a stub that only
# records the curl config it receives, so nothing touches the network.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
cp "$REPO/http-get-engine.sh" "$T/engine.sh"
sed -i "s#^CURL=/usr/bin/curl\$#CURL=$T/stubcurl#" "$T/engine.sh"
grep -q "^CURL=$T/stubcurl\$" "$T/engine.sh" || { echo "FAIL sandbox: CURL line not found"; exit 1; }
cat > "$T/stubcurl" <<EOF
#!/bin/bash
cat > "$T/curl-config"
EOF
chmod 0755 "$T/engine.sh" "$T/stubcurl"
cat > "$T/fixture.conf" <<'EOF'
API_BASE=https://api.example.com
TOKEN_VAR=FIXTURE_TOK
ALLOW=/repos/*
EOF
export FIXTURE_TOK=fixture-token-value

pass=0; fail=0
ok() { pass=$((pass+1)); echo "PASS $1"; }
ko() { fail=$((fail+1)); echo "FAIL $1"; }

for bad in '/repos/../user/emails' '/repos/./x' '/repos/x/..' '/repos/x/.' '/repos/%2e%2e/user' \
           '/repos/%2E%2E/user' '/repos/x%2Fy' '/repos/x%2fy' '/repos/x%5Cy' '/repos/x/..?a=1'; do
  rm -f "$T/curl-config"
  "$T/engine.sh" "$T/fixture.conf" "$bad" >/dev/null 2>&1; rc=$?
  if [ "$rc" = 2 ] && [ ! -f "$T/curl-config" ]; then ok "refused $bad"; else ko "$bad: rc=$rc"; fi
done

rm -f "$T/curl-config"
"$T/engine.sh" "$T/fixture.conf" '/repos/a/b.c?q=x%2Fy' >/dev/null 2>&1; rc=$?
if [ "$rc" = 0 ] && grep -qx 'url = "https://api.example.com/repos/a/b.c?q=x%2Fy"' "$T/curl-config"; then
  ok "plain path with encoded query allowed"
else ko "allowed path: rc=$rc"; fi
for want in 'connect-timeout = 10' 'max-time = 60' 'max-filesize = 10000000'; do
  if grep -qx "$want" "$T/curl-config" 2>/dev/null; then ok "curl limit: $want"; else ko "missing curl limit: $want"; fi
done

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
