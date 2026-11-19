#!/usr/bin/env bash
# The quick-start trial: runs end to end offline, never shows the token, and writes only
# inside its own new directory.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
QS="$REPO/scripts/quickstart.sh"
T="$(mktemp -d)"; trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
pass=0; fail=0
ok() { pass=$((pass+1)); echo "PASS $1"; }
ko() { fail=$((fail+1)); echo "FAIL $1"; }

mkdir -p "$T/home" "$T/tmp"
# HOME and TMPDIR point at empty directories so any stray write would show up there.
HOME="$T/home" TMPDIR="$T/tmp" "$QS" "$T/trial" > "$T/out" 2> "$T/err"; rc=$?
token="$(cat "$T/trial/keyhost/store/demo/DEMO_TOKEN" 2>/dev/null)"
if [ "$rc" = 0 ] && [ ! -s "$T/err" ]; then ok "trial runs cleanly"; else ko "trial rc=$rc err=$(cat "$T/err")"; fi
if grep -q 'demo-check: I received DEMO_TOKEN' "$T/out"; then ok "consumer received the token"; else ko "no receipt in output"; fi
if [ -n "$token" ] && ! grep -qF "$token" "$T/out" "$T/err" "$T/trial/.config/secrets-exec/audit.log"; then
  ok "token never in output or audit log"
else ko "token leaked or missing"; fi
if grep -q "outcome=allowed consumer=demo" "$T/trial/.config/secrets-exec/audit.log" \
   && grep -q "outcome=refused" "$T/trial/.config/secrets-exec/audit.log"; then ok "audit has the call and the refusals"
else ko "audit: $(cat "$T/trial/.config/secrets-exec/audit.log" 2>/dev/null)"; fi
if grep -q 'No. It was in the consumer' "$T/out"; then ok "self-check reported"; else ko "self-check missing"; fi
if [ -z "$(ls -A "$T/home")" ] && [ -z "$(ls -A "$T/tmp")" ]; then ok "nothing written outside the trial directory"
else ko "stray files: $(ls -A "$T/home" "$T/tmp")"; fi
if [ "$(stat -c %a "$T/trial")" = 700 ] && [ "$(stat -c %a "$T/trial/keyhost/store/demo/DEMO_TOKEN")" = 600 ] \
   && [ "$(stat -c %a "$T/trial/.config/secrets-exec/backend.conf")" = 600 ]; then ok "private modes"
else ko "modes"; fi
# The trial installation keeps working afterwards.
if "$T/trial/bin/secrets-exec" demo 2>&1 | grep -q 'I received'; then ok "trial engine works afterwards"; else ko "rerun failed"; fi

# Refusals: existing directory, awkward path, extra arguments.
mkdir "$T/exists"
if ! "$QS" "$T/exists" > /dev/null 2> "$T/err" && grep -q 'already exists' "$T/err"; then ok "existing directory refused"
else ko "existing directory accepted"; fi
if ! "$QS" "$T/has space" > /dev/null 2> "$T/err" && grep -q 'simpler' "$T/err"; then ok "unusual path refused"
else ko "unusual path accepted"; fi
if ! "$QS" a b > /dev/null 2>&1; then ok "extra arguments refused"; else ko "extra arguments accepted"; fi
# Default location is a new private directory under TMPDIR.
HOME="$T/home" TMPDIR="$T/tmp" "$QS" > "$T/out2" 2>&1
d="$(ls -d "$T"/tmp/secrets-exec-trial.* 2>/dev/null | head -1)"
if [ -n "$d" ] && [ -x "$d/bin/secrets-exec" ] && grep -qF "rm -rf $d" "$T/out2"; then ok "default trial under TMPDIR"
else ko "default trial: $(tail -3 "$T/out2")"; fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
