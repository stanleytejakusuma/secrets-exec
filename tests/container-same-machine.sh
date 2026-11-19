#!/bin/bash
# Same-machine setup, end to end, with real sudo, in a throwaway Debian container.
# Follows docs/backends.md option A: a separate store user, a pinned sudo rule and host=local.
# Needs Docker and network (it pulls debian:stable-slim and installs sudo/python3), so it runs
# as its own CI job, not in tests/run-all.sh. Nothing outside the container is changed.
#
#   bash tests/container-same-machine.sh
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
if [ "${1:-}" != --inside ]; then
  exec docker run --rm -v "$REPO":/src:ro debian:stable-slim bash /src/tests/container-same-machine.sh --inside
fi
apt-get update -qq >/dev/null && apt-get install -y -qq sudo python3 >/dev/null
cp -r /src /opt/src && chmod -R a+rX /opt/src
useradd -m agent

# --- documented setup (as root): docs/backends.md option A, run as written ---
# Its first shell block, with `you` -> agent and two allowed bundles (tests the \, escaping).
awk '/^## Option A/{a=1} a && /^```sh$/{b=1; next} b && /^```$/{exit} b' /opt/src/docs/backends.md \
  | sed -e "s/'you ALL=/'agent ALL=/" -e 's/--allow example-code/--allow example-code,shared/' \
        -e 's#examples/keyhost/#/opt/src/examples/keyhost/#' > /root/setup-a.sh
grep -q "agent ALL=" /root/setup-a.sh && grep -q 'visudo -cf' /root/setup-a.sh
bash -euo pipefail /root/setup-a.sh
grep -q 'NOLOG_OUTPUT' /etc/sudoers.d/secrets-exec && grep -qF 'example-code\,shared' /etc/sudoers.d/secrets-exec
install -d -m 0700 -o secrets-store -g secrets-store /var/lib/secrets-store/store/shared /var/lib/secrets-store/store/other
# Same token-adding command as docs/backends.md, with the value piped instead of typed.
add() { printf '%s' "$3" | install -m 0600 -o secrets-store -g secrets-store /dev/stdin "/var/lib/secrets-store/store/$1/$2"; }
add example-code GITHUB_TOKEN fake-container-value
add shared TOKEN shared-value
add other TOKEN other-value

# --- agent side (as agent) ---
su agent -s /bin/bash -c '
set -euo pipefail
umask 077
mkdir -p ~/bin ~/.config/secrets-exec/consumers.d
install -m 0755 /opt/src/bin/secrets-exec ~/bin/secrets-exec
cat > ~/.config/secrets-exec/consumers.d/check <<"E2"
#!/bin/bash -p
printf "check: got %d chars\n" "${#GITHUB_PAT}"
E2
chmod 0755 ~/.config/secrets-exec/consumers.d/check
echo "check|example-code|GITHUB_TOKEN|GITHUB_PAT|$HOME/.config/secrets-exec/consumers.d/check|" > ~/.config/secrets-exec/consumers.conf
echo "shared|shared|TOKEN|GITHUB_PAT|$HOME/.config/secrets-exec/consumers.d/check|" >> ~/.config/secrets-exec/consumers.conf
echo "other|other|TOKEN|GITHUB_PAT|$HOME/.config/secrets-exec/consumers.d/check|" >> ~/.config/secrets-exec/consumers.conf
sed -n "s/^#\(host=local\)$/\1/p; /Option A/,/Option B/ s/^#\(get=.*\)$/\1/p; /Option A/,/Option B/ s/^#\(list=.*\)$/\1/p" /opt/src/examples/backend.example.conf \
  | sed "s/--allow example-code/--allow example-code,shared/" > ~/.config/secrets-exec/backend.conf
chmod 0600 ~/.config/secrets-exec/*.conf
echo "--- backend.conf"; cat ~/.config/secrets-exec/backend.conf
echo "--- 1 allowed consumer"; ~/bin/secrets-exec check
echo "--- 1b second allowed bundle (comma in allowlist)"; ~/bin/secrets-exec shared
echo "--- 2 store unreadable to agent"; if cat /var/lib/secrets-store/store/example-code/GITHUB_TOKEN; then exit 9; fi
echo "--- 3 bundle outside allowlist refused"; if ~/bin/secrets-exec other; then exit 9; fi
echo "--- 4 agent cannot widen the allowlist via sudo"
if sudo -n -u secrets-store /usr/local/bin/secrets-exec-keyhost --store /var/lib/secrets-store/store --allow other get other TOKEN; then exit 9; fi
echo "--- 5 agent cannot run anything else as the store user"
if sudo -n -u secrets-store /bin/cat /var/lib/secrets-store/store/other/TOKEN; then exit 9; fi
echo "--- 6 extra arguments after the pinned prefix: sudo lets them through, the key host refuses"
if out="$(sudo -n -u secrets-store /usr/local/bin/secrets-exec-keyhost --store /var/lib/secrets-store/store --allow example-code,shared get example-code GITHUB_TOKEN --allow other 2>&1)"; then echo "$out"; exit 9; fi
echo "$out"; [ "$out" = "secrets-exec-keyhost: invalid request" ] || exit 9
echo "--- 8 crafted arguments that match the sudo rule as a joined string are refused"
KH="/usr/local/bin/secrets-exec-keyhost"; ST=/var/lib/secrets-store/store
if out="$(sudo -n -u secrets-store $KH --store "$ST --allow example-code,shared get x" --store "$ST" --allow other get other TOKEN 2>&1)"; then echo "$out"; exit 9; fi
echo "$out"; [ "$out" = "secrets-exec-keyhost: option values must be nonempty, without whitespace" ] || exit 9
echo "--- 7 audit"; cat ~/.config/secrets-exec/audit.log
if grep -qE "fake-container-value|shared-value" ~/.config/secrets-exec/audit.log; then exit 9; fi; echo "value not in audit"
'
echo CONTAINER-TEST-PASSED
