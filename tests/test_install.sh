#!/usr/bin/env bash
# A local source fixture stubs its test runner, avoiding recursive run-all/install.
# The real run-all runs this suite; the installer must always invoke its own runner.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
umask 077
mkdir -p "$T/source/scripts" "$T/source/tests" "$T/home"
cp "$REPO/scripts/install.sh" "$T/source/scripts/"
cp -r "$REPO/bin" "$REPO/examples" "$T/source/"
cp "$REPO/http-get-engine.sh" "$T/source/"
printf '#!/bin/bash\nprintf tested >> "$(dirname "$0")/ran"\n[ ! -f "$(dirname "$0")/fail" ]\n' > "$T/source/tests/run-all.sh"
INSTALL="$T/source/scripts/install.sh"
pass=0
ok() { pass=$((pass+1)); printf 'PASS %s\n' "$1"; }
run() { HOME="$T/home" "$INSTALL" "$@" > "$T/out" 2> "$T/err"; }
# Source in a privileged shell with an in-process id stub: exercises the root guard
# without sudo or user namespaces. Executing the -p script ignores imported functions.
if HOME="$T/home" bash -p -c 'id() { printf "0\n"; }; source "$1" --apply' _ "$INSTALL" > "$T/out" 2> "$T/err"; then
  echo 'FAIL root refused'; exit 1
fi
grep -q 'root' "$T/err"
[ -z "$(find "$T/home" -mindepth 1 -print -quit)" ] && [ ! -e "$T/source/tests/ran" ] || exit 1
ok 'root guard refuses before tests or installation (simulated uid)'
# When genuinely root, the ordinary calls below must also refuse; skip only these
# non-root scenarios, because this installer deliberately cannot apply as root.
if [ "$(id -u)" -eq 0 ]; then
  if run --apply; then echo 'FAIL real root accepted'; exit 1; fi
  grep -q root "$T/err"
  ok 'real root execution refused'
  printf '%s passed, 0 failed (non-root installation checks SKIP as root)\n' "$pass"
  exit 0
fi
run
[ -z "$(find "$T/home" -mindepth 1 -print -quit)" ] && [ -s "$T/source/tests/ran" ] || exit 1
grep -qi 'dry run' "$T/out"; ok 'default dry run runs tests and changes nothing in HOME'
printf 'printf injected > %q\nexit 0\n' "$T/injected" > "$T/poison"
BASH_ENV="$T/poison" run
[ ! -e "$T/injected" ]; ok 'caller BASH_ENV cannot bypass the test gate'
touch "$T/source/tests/fail"
if run --apply; then echo 'FAIL tests must gate install'; exit 1; fi
[ -z "$(find "$T/home" -mindepth 1 -print -quit)" ]; ok 'failed test suite blocks apply'
rm "$T/source/tests/fail"
run --apply
C="$T/home/.config/secrets-exec"
[ "$(stat -c %a "$T/home/bin/secrets-exec")" = 755 ]
for dir in "$C" "$C/consumers.d" "$C/http-consumers"; do [ "$(stat -c %a "$dir")" = 700 ]; done
for file in "$C/http-get-engine.sh" "$C/consumers.d/"*; do [ "$(stat -c %a "$file")" = 755 ]; done
for file in "$C/consumers.conf" "$C/backend.conf" "$C/http-consumers/"*; do [ "$(stat -c %a "$file")" = 600 ]; done
cmp -s "$T/source/bin/secrets-exec" "$T/home/bin/secrets-exec"
ok 'apply creates complete layout with correct modes'
grep -qi 'edit' "$T/out"; ok 'new configuration requires explicit review/edit'
find "$T/home" -printf '%P %m %T@\n' | sort > "$T/before"
run --apply
find "$T/home" -printf '%P %m %T@\n' | sort > "$T/after"
cmp -s "$T/before" "$T/after"; ok 'second apply is idempotent, without backups'
printf 'custom registry\n' > "$C/consumers.conf"
printf 'custom backend\n' > "$C/backend.conf"
run --apply
[ "$(< "$C/consumers.conf")" = 'custom registry' ] && [ "$(< "$C/backend.conf")" = 'custom backend' ] || exit 1
ok 'existing consumers.conf and backend.conf untouched'
printf '# changed source\n' >> "$T/source/bin/secrets-exec"
cp "$T/home/bin/secrets-exec" "$T/original"
find "$T/home" -printf '%P %m %T@\n' | sort > "$T/before"
run
find "$T/home" -printf '%P %m %T@\n' | sort > "$T/after"
cmp -s "$T/before" "$T/after"
grep -q '^+.*changed source' "$T/out"; ok 'dry run shows existing file diff without writing'
run --apply
backups=("$C"/backup-*)
[ "${#backups[@]}" -eq 1 ] && [ -d "${backups[0]}" ] || exit 1
[ "$(stat -c %a "${backups[0]}")" = 700 ]
[[ "${backups[0]##*/}" =~ ^backup-[0-9]{8}T[0-9]{6}[0-9]+Z$ ]] || { echo "FAIL backup name not UTC: ${backups[0]##*/}"; exit 1; }
cmp -s "$T/original" "${backups[0]}/bin/secrets-exec"
cmp -s "$T/source/bin/secrets-exec" "$T/home/bin/secrets-exec"
ok 'changed file backed up before replacement'
chmod 0644 "$C/http-get-engine.sh"
run --apply
[ "$(stat -c %a "$C/http-get-engine.sh")" = 755 ]; ok 'incorrect managed file mode repaired with backup'
chmod 0755 "$C"
run --apply
[ "$(stat -c %a "$C")" = 700 ]; ok 'existing configuration directory mode repaired'
if run --unknown; then echo 'FAIL unknown option'; exit 1; fi
ok 'unknown arguments refused'
# Refuse unsafe destinations, rather than write outside the chosen home.
mkdir "$T/otherhome"
ln -s "$T/otherhome" "$T/"$'\nlinkedhome'
if HOME="$T/"$'\nlinkedhome' "$INSTALL" --apply > "$T/out" 2> "$T/err"; then
  echo 'FAIL newline HOME bypassed symlink checks'; exit 1
fi
[ -z "$(find "$T/otherhome" -mindepth 1 -print -quit)" ]; ok 'newline HOME cannot bypass symlink checks'
mv "$C/http-get-engine.sh" "$T/target"
ln -s "$T/target" "$C/http-get-engine.sh"
if run --apply; then echo 'FAIL destination symlink'; exit 1; fi
[ -L "$C/http-get-engine.sh" ]; ok 'symlink destination refused'
printf '%s passed, 0 failed\n' "$pass"
