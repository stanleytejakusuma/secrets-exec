#!/usr/bin/env bash
# Offline forced-command protocol, filesystem checks, and engine integration.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
KEYHOST="$REPO/examples/keyhost/secrets-exec-keyhost"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
umask 077
mkdir -p "$T/store/a" "$T/store/other"
printf 'fixture-value' > "$T/store/a/TOKEN"
printf 'second\n' > "$T/store/a/SECOND"
pass=0
ok() { pass=$((pass+1)); printf 'PASS %s\n' "$1"; }
run() {
  rc=0
  SSH_ORIGINAL_COMMAND="$1" "$KEYHOST" --store "$T/store" --allow a --log "$T/requests" \
    > "$T/out" 2> "$T/err" || rc=$?
}
reject() {
  run "$2"
  [ "$rc" -ne 0 ] && [ ! -s "$T/out" ] && [ -s "$T/err" ] || { echo "FAIL $1"; exit 1; }
  ! grep -q 'fixture-value' "$T/err" || { echo 'FAIL value in error'; exit 1; }
  ok "$1"
}
run "get 'a' 'TOKEN'"
[ "$rc" -eq 0 ] && cmp -s "$T/out" "$T/store/a/TOKEN" && [ ! -s "$T/err" ] || exit 1
ok 'allowed get returns exact bytes, no banner'
run "get 'a' 'SECOND'"
[ "$rc" -eq 0 ] && cmp -s "$T/out" "$T/store/a/SECOND" || exit 1
ok 'one trailing newline preserved'
run "list 'a'"
[ "$rc" -eq 0 ] && [ "$(sort "$T/out")" = $'SECOND\nTOKEN' ] || exit 1
ok 'list emits only key names'
! grep -qE 'fixture-value|second' "$T/requests" || exit 1
grep -qx 'get a TOKEN' "$T/requests"
ok 'request log contains names, not values'
reject 'bundle not allowlisted' "get 'other' 'TOKEN'"
reject 'semicolon injection' "get 'a' 'TOKEN'; id"
reject 'command substitution' 'get '\''a'\'' '\''$(id)'\'
reject 'backtick substitution' 'get '\''a'\'' '\''`id`'\'
reject 'extra argument' "get 'a' 'TOKEN' extra"
reject 'missing quotes' 'get a TOKEN'
reject 'dotdot key' "get 'a' '..'"
reject 'dotdot bundle' "list '..'"
reject 'hidden key' "get 'a' '.TOKEN'"
reject 'hidden bundle' "list '.a'"
reject 'newline suffix' $'get \'a\' \'TOKEN\'\n'
reject 'embedded newline' $'get \'a\nb\' \'TOKEN\''
reject 'empty command' ''
reject 'leading space' " get 'a' 'TOKEN'"
reject 'list extra argument' "list 'a' 'TOKEN'"
reject 'client cannot select store' "get 'a' 'TOKEN' --store /elsewhere"
ln -s TOKEN "$T/store/a/LINK"
reject 'symlink value' "get 'a' 'LINK'"
reject 'list refuses unsafe files without partial output' "list 'a'"
rm "$T/store/a/LINK"
chmod 0640 "$T/store/a/TOKEN"
reject 'group-readable value' "get 'a' 'TOKEN'"
chmod 0604 "$T/store/a/TOKEN"
reject 'other-readable value' "get 'a' 'TOKEN'"
chmod 0600 "$T/store/a/TOKEN"
printf 'fixture-value\0tail' > "$T/store/a/NUL"
reject 'NUL value' "get 'a' 'NUL'"
printf 'fixture-value\n\n' > "$T/store/a/NUL"
reject 'multiple trailing newlines' "get 'a' 'NUL'"
: > "$T/store/a/NUL"
reject 'empty value' "get 'a' 'NUL'"
printf 'first\n\nsecond' > "$T/store/a/NUL"
run "get 'a' 'NUL'"
[ "$rc" -eq 0 ] && cmp -s "$T/out" "$T/store/a/NUL" || exit 1
ok 'internal blank line value preserved'
rm "$T/store/a/NUL"
mkfifo "$T/store/a/FIFO"
reject 'FIFO refused without opening' "get 'a' 'FIFO'"
rm "$T/store/a/FIFO"
# Simulate a different file owner without chown privileges. The real script is
# sourced unchanged; its -p executable cannot import a caller's stat function.
rc=0
SSH_ORIGINAL_COMMAND="get 'a' 'TOKEN'" bash -p -c '
  stat() {
    if [[ "${@: -1}" == */TOKEN ]]; then printf "%s 600\n" "$((EUID+1))";
    else /usr/bin/stat "$@"; fi
  }
  source "$1" --store "$2" --allow a
' _ "$KEYHOST" "$T/store" > "$T/out" 2> "$T/err" || rc=$?
[ "$rc" -ne 0 ] && [ ! -s "$T/out" ] || exit 1
ok 'wrong file owner refused (simulated metadata)'
mkdir "$T/store/a/DIR"
reject 'nonregular value' "get 'a' 'DIR'"
rmdir "$T/store/a/DIR"
chmod 0770 "$T/store/a"
reject 'group-writable bundle directory' "get 'a' 'TOKEN'"
chmod 0700 "$T/store/a"
chmod 0702 "$T/store"
reject 'other-writable store directory' "get 'a' 'TOKEN'"
chmod 0700 "$T/store"
rc=0
SSH_ORIGINAL_COMMAND="list 'a'" "$KEYHOST" --store relative/store --allow a > "$T/out" 2> "$T/err" || rc=$?
[ "$rc" -ne 0 ] && [ ! -s "$T/out" ] && grep -q 'absolute' "$T/err" || exit 1
ok 'relative store refused'
ln -s "$T/store" "$T/linked-parent"
rc=0
SSH_ORIGINAL_COMMAND="get 'a' 'TOKEN'" "$KEYHOST" --store "$T/linked-parent/" --allow a > "$T/out" 2> "$T/err" || rc=$?
[ "$rc" -ne 0 ] && [ ! -s "$T/out" ] && grep -q 'symlink' "$T/err" || exit 1
ok 'symlink store ancestor refused'
ln -s a "$T/store/alias"
rc=0
SSH_ORIGINAL_COMMAND="get 'alias' 'TOKEN'" "$KEYHOST" --store "$T/store" --allow alias > "$T/out" 2> "$T/err" || rc=$?
[ "$rc" -ne 0 ] && [ ! -s "$T/out" ] || exit 1; ok 'symlink bundle refused'
rc=0
SSH_ORIGINAL_COMMAND="list 'a'" "$KEYHOST" --store "$T/store" > "$T/out" 2> "$T/err" || rc=$?
[ "$rc" -ne 0 ] && [ ! -s "$T/out" ] || exit 1; ok 'allowlist required'
rc=0
SSH_ORIGINAL_COMMAND="list 'a'" "$KEYHOST" --store "$T/store" --allow a, > "$T/out" 2> "$T/err" || rc=$?
[ "$rc" -ne 0 ]; ok 'malformed allowlist refused'
rc=0
SSH_ORIGINAL_COMMAND="list 'a'" "$KEYHOST" --store "$T/store" --allow $'a\nignored' > "$T/out" 2> "$T/err" || rc=$?
[ "$rc" -ne 0 ] && [ ! -s "$T/out" ] || exit 1
ok 'newline in administrator allowlist refused'
ln -s "$T/store" "$T/"$'\nlinked-store'
rc=0
SSH_ORIGINAL_COMMAND="get 'a' 'TOKEN'" "$KEYHOST" --store "$T/"$'\nlinked-store' --allow a > "$T/out" 2> "$T/err" || rc=$?
[ "$rc" -ne 0 ] && [ ! -s "$T/out" ] || exit 1
ok 'newline path cannot bypass symlink traversal checks'
mkdir -p "$T/home/.local/share/secrets-exec-keyhost"
cp -r "$T/store" "$T/home/.local/share/secrets-exec-keyhost/store"
HOME="$T/home" SSH_ORIGINAL_COMMAND="get 'a' 'TOKEN'" "$KEYHOST" --allow a,other > "$T/out"
cmp -s "$T/out" "$T/store/a/TOKEN"; ok 'default store and multiple allowed bundles'

# Local request form: same parser, same allowlist and file checks; no SSH involved.
lrun() { rc=0; env -u SSH_ORIGINAL_COMMAND "$KEYHOST" --store "$T/store" --allow a "$@" > "$T/out" 2> "$T/err" || rc=$?; }
lreject() { local label="$1"; shift; lrun "$@"
  [ "$rc" -ne 0 ] && [ ! -s "$T/out" ] || { echo "FAIL $label"; exit 1; }; ok "$label"; }
lrun get a TOKEN
[ "$rc" -eq 0 ] && cmp -s "$T/out" "$T/store/a/TOKEN" || { echo 'FAIL local get'; exit 1; }
ok 'local get returns exact bytes'
lrun list a
[ "$rc" -eq 0 ] && [ "$(sort "$T/out")" = $'SECOND\nTOKEN' ] || { echo 'FAIL local list'; exit 1; }
ok 'local list emits key names'
lreject 'local: bundle not allowlisted' get other TOKEN
lreject 'local: quote in name'           get "a' 'x" TOKEN
lreject 'local: newline in name'         get $'a\nb' TOKEN
lreject 'local: dotdot key'              get a ..
lreject 'local: extra argument'          get a TOKEN extra
lreject 'local: missing key'             get a
lreject 'local: unknown verb'            cat a
lreject 'local: option after request'    get a TOKEN --store /elsewhere
rc=0
SSH_ORIGINAL_COMMAND="get 'other' 'TOKEN'" "$KEYHOST" --store "$T/store" --allow a get a TOKEN > "$T/out" 2> "$T/err" || rc=$?
[ "$rc" -eq 0 ] && cmp -s "$T/out" "$T/store/a/TOKEN" || { echo 'FAIL local precedence'; exit 1; }
ok 'local arguments, not an inherited SSH_ORIGINAL_COMMAND, select the request'

# Real local engine -> host=local -> unmodified key host -> reviewed fixture. No SSH.
mkdir -p "$T/local/bin" "$T/local/.config/secrets-exec"
cp "$REPO/bin/secrets-exec" "$T/local/bin/secrets-exec"
printf '#!/bin/bash -p\n[ "$DEMO_TOKEN" = fixture-value ] && printf received > %q\n' "$T/received" > "$T/local-consumer"
chmod 0755 "$T/local/bin/secrets-exec" "$T/local-consumer"
printf 'demo|a|TOKEN|DEMO_TOKEN|%s|\nglob|a|TOK*|DEMO_TOKEN|%s|\n' "$T/local-consumer" "$T/local-consumer" > "$T/local/.config/secrets-exec/consumers.conf"
printf '%s\n' host=local "get=$KEYHOST --store $T/store --allow a,other get {bundle} {key}" \
  "list=$KEYHOST --store $T/store --allow a list {bundle}" > "$T/local/.config/secrets-exec/backend.conf"
PATH="$T/no-ssh:/usr/bin:/bin" "$T/local/bin/secrets-exec" demo > "$T/out" 2> "$T/err"
[ "$(< "$T/received")" = received ] && [ ! -s "$T/out" ] && [ ! -s "$T/err" ] || { echo 'FAIL local engine'; cat "$T/err"; exit 1; }
ok 'engine host=local: consumer receives value from the key host, no SSH'
rm "$T/received"
"$T/local/bin/secrets-exec" glob > "$T/out" 2> "$T/err"
[ "$(< "$T/received")" = received ] || { echo 'FAIL local glob'; exit 1; }
ok 'engine host=local resolves a glob through the key host list'
rm "$T/received"

# Real local engine -> fake SSH -> unmodified forced command -> reviewed fixture.
mkdir -p "$T/client/bin" "$T/client/.config/secrets-exec"
cp "$REPO/bin/secrets-exec" "$T/client/bin/secrets-exec"
sed -i -E "s#(^|[^/[:alnum:]])ssh( -n)? -o BatchMode=yes#\1$T/fakessh\2 -o BatchMode=yes#" "$T/client/bin/secrets-exec"
grep -q "$T/fakessh -n -o BatchMode=yes" "$T/client/bin/secrets-exec"
! grep -qE '(^|[[:space:]])ssh( -n)? -o BatchMode=yes' "$T/client/bin/secrets-exec" || exit 1
printf '#!/bin/bash -p\nexport SSH_ORIGINAL_COMMAND="${@: -1}"\nexec %q --store %q --allow a\n' "$KEYHOST" "$T/store" > "$T/fakessh"
printf '#!/bin/bash -p\n[ "$DEMO_TOKEN" = fixture-value ] && printf received > %q\n' "$T/received" > "$T/consumer"
chmod 0755 "$T/client/bin/secrets-exec" "$T/fakessh" "$T/consumer"
printf 'demo|a|TOKEN|DEMO_TOKEN|%s|\nglob|a|TOK*|DEMO_TOKEN|%s|\n' "$T/consumer" "$T/consumer" > "$T/client/.config/secrets-exec/consumers.conf"
printf '%s\n' host=keyhost 'get=get {bundle} {key}' 'list=list {bundle}' > "$T/client/.config/secrets-exec/backend.conf"
"$T/client/bin/secrets-exec" demo > "$T/out" 2> "$T/err"
[ "$(< "$T/received")" = received ] && [ ! -s "$T/out" ] && [ ! -s "$T/err" ] || exit 1
ok 'engine template validates and consumer receives value via fake SSH'
rm "$T/received"
"$T/client/bin/secrets-exec" glob > "$T/out" 2> "$T/err"
[ "$(< "$T/received")" = received ] && [ ! -s "$T/out" ] || exit 1
ok 'engine list template resolves glob through forced command'
printf '%s passed, 0 failed\n' "$pass"
