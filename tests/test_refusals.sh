#!/usr/bin/env bash
# Refusals must happen before fetching. No backend is installed in these sandboxes.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/.config/secrets-exec"
cp "$REPO/bin/secrets-exec" "$T/bin/secrets-exec"; chmod 0755 "$T/bin/secrets-exec"
cat > "$T/.config/secrets-exec/consumers.conf" <<'EOF'
demo|fixture-bundle|FIXTURE_KEY|DEMO_TOKEN|/bin/echo|-u,--api-url,--config
EOF
VE="$T/bin/secrets-exec"
AUDIT="$T/.config/secrets-exec/audit.log"
pass=0; fail=0
ok() { pass=$((pass+1)); echo "PASS $1"; }
ko() { fail=$((fail+1)); echo "FAIL $1"; }
expect_refused() { # <name> <want-rc> <want-text> <args...>
  local name="$1" want="$2" text="$3"; shift 3
  out="$("$VE" "$@" 2>&1)"; rc=$?
  if [ "$rc" -eq "$want" ] && grep -q '^secrets-exec: ' <<<"$out" && grep -qi -- "$text" <<<"$out"; then ok "$name"
  else ko "$name (rc=$rc): $(head -c 200 <<<"$out")"; fi
}
expect_refused "no args" 1 "usage"
expect_refused "unknown consumer" 2 "not-a-consumer" not-a-consumer
expect_refused "path as consumer" 2 "/bin/sh" /bin/sh
expect_refused "guarded long flag" 2 "guarded" demo --api-url=https://attacker.example
expect_refused "guarded short flag" 2 "guarded" demo -u https://attacker.example
expect_refused "guarded flag prefix" 2 "guarded" demo --configx /tmp/c
expect_refused "guarded short-option cluster" 2 "guarded" demo -vu/tmp/c
out="$("$VE" --list 2>&1)"
if grep -q demo <<<"$out" && ! grep -q secret-value <<<"$out"; then ok "--list names only"; else ko "--list"; fi
if [ -s "$AUDIT" ] && grep -q refused "$AUDIT"; then ok "refusals audited"; else ko "refusals audited"; fi
if grep -q ' via=secrets-exec args=' "$AUDIT"; then ok "audit invocation name"; else ko "audit invocation name missing"; fi
before="$(wc -l < "$AUDIT")"
"$VE" $'not-a-consumer\nforged-consumer' >/dev/null 2>&1; rc=$?
after="$(wc -l < "$AUDIT")"
if [ "$rc" = 2 ] && [ "$after" = "$((before+1))" ] && tail -1 "$AUDIT" | grep -q ' via=secrets-exec args='; then
  ok "newline consumer is one audit record"
else ko "newline consumer split audit metadata"; fi
mkdir -p "$T/elsewhere/bin"; cp "$VE" "$T/elsewhere/bin/secrets-exec"
"$T/elsewhere/bin/secrets-exec" demo hi >/dev/null 2>&1; rc=$?
if [ "$rc" -ne 0 ]; then ok "missing registry fails closed"; else ko "missing registry ran"; fi
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
