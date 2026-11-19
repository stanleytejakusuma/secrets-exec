#!/bin/bash -p
# Two-minute local trial. Builds a throwaway installation in ONE new directory and walks
# through a call, a refusal and the audit log. No sudo, no network, no SSH, no real token
# (it generates a fake one), and nothing is written outside that directory.
#
#   ./scripts/quickstart.sh            # uses a new directory under $TMPDIR or /tmp
#   ./scripts/quickstart.sh ~/se-trial # or a new directory you name (must not exist)
set -euo pipefail
umask 077
PATH=/usr/bin:/bin
export PATH LC_ALL=C
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
die() { printf 'quickstart: %s\n' "$1" >&2; exit 1; }
[[ "$(id -u)" != 0 ]] || die 'run this as your normal user, not root'
[ "$(uname -s)" = Linux ] || die 'secrets-exec currently supports Linux only'

if [ "$#" -gt 1 ]; then die 'usage: quickstart.sh [new-directory]'; fi
plain() { # backend.conf templates are plain words, so the trial path must be too
  [[ "$1" =~ ^/[A-Za-z0-9_./-]+$ ]] || die "path '$1' has characters backend.conf cannot hold; pick a simpler one"
}
if [ "$#" -eq 1 ]; then
  [ ! -e "$1" ] && [ ! -L "$1" ] || die "$1 already exists; choose a new directory"
  plain "$(realpath -m -- "$1")"
  mkdir -m 0700 -- "$1"
  D="$(cd -- "$1" && pwd -P)"
else
  base="$(realpath -m -- "${TMPDIR:-/tmp}")"
  plain "$base"
  D="$(mktemp -d "$base/secrets-exec-trial.XXXXXX")"
  D="$(cd -- "$D" && pwd -P)"
fi
plain "$D"

C="$D/.config/secrets-exec"
mkdir -p "$D/bin" "$C/consumers.d" "$D/keyhost/store/demo"
install -m 0755 "$REPO/bin/secrets-exec" "$D/bin/secrets-exec"
install -m 0755 "$REPO/examples/keyhost/secrets-exec-keyhost" "$D/keyhost/secrets-exec-keyhost"

# A fake token. It only exists in this trial's private store.
IFS= read -r uuid < /proc/sys/kernel/random/uuid
token="demo-${uuid//-/}"
printf '%s' "$token" > "$D/keyhost/store/demo/DEMO_TOKEN"
chmod 0600 "$D/keyhost/store/demo/DEMO_TOKEN"

cat > "$C/consumers.d/demo-check" <<'EOF'
#!/bin/bash -p
# Trial consumer: proves the token arrived, without printing it.
[ -n "${DEMO_TOKEN:-}" ] || { echo 'demo-check: no token received' >&2; exit 1; }
printf 'demo-check: I received DEMO_TOKEN (%d characters) and used it. I never print it.\n' "${#DEMO_TOKEN}"
EOF
chmod 0755 "$C/consumers.d/demo-check"

printf 'demo|demo|DEMO_TOKEN|DEMO_TOKEN|%s|\n' "$C/consumers.d/demo-check" > "$C/consumers.conf"
kh="$D/keyhost/secrets-exec-keyhost --store $D/keyhost/store --allow demo"
printf '%s\n' '# Trial backend: a local key host with a private file store in this directory.' \
  host=local "get=$kh get {bundle} {key}" "list=$kh list {bundle}" > "$C/backend.conf"
chmod 0600 "$C/consumers.conf" "$C/backend.conf"

SE="$D/bin/secrets-exec"
seen="$D/.trial-output"
: > "$seen"
show() { # show <title> <args...>: print and run one call, keep its output for the final check
  local title="$1"; shift
  printf '\n== %s\n$ secrets-exec %s\n' "$title" "$*"
  "$SE" "$@" 2>&1 | tee -a "$seen" || true
}

printf 'secrets-exec trial in %s\n' "$D"
show '1. The caller sees consumer names, nothing else' --list
show '2. Run a consumer: it gets the token, the caller only gets its output' demo
show '3. Anything not registered is refused' /bin/sh -c id
show '   ...including names that are not in the registry' env
printf '\n== 4. Every call is audited: names and arguments, never values\n'
tee -a "$seen" < "$C/audit.log"

printf '\n== 5. Was the token in anything you just saw?\n'
if grep -qF "$token" "$seen" "$C/audit.log"; then
  die 'the token appeared in the output; please report this as a bug'
fi
printf 'No. It was in the consumer'"'"'s environment only.\n'
rm -f "$seen"

cat <<EOF

Try it yourself:   $SE demo
See the setup:     $C/
Remove the trial:  rm -rf $D

This trial keeps its store under your own user, which is fine for trying it, not for
real credentials. For real use, see "Real setup" in the README.
EOF
