#!/bin/bash
# Same-machine setup, end to end, with real sudo, in a throwaway Debian container.
# Follows docs/backends.md option A: a separate store user, a pinned sudo rule and host=local.
# Needs Docker and network (it pulls debian:stable-slim and installs sudo/python3), so it is
# not part of tests/run-all.sh or CI. Nothing outside the container is changed.
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
useradd --system --create-home --home-dir /var/lib/secrets-store --shell /usr/sbin/nologin secrets-store

# --- documented setup (as root), see docs/backends.md option A ---
install -m 0755 /opt/src/examples/keyhost/secrets-exec-keyhost /usr/local/bin/secrets-exec-keyhost
install -d -m 0700 -o secrets-store -g secrets-store /var/lib/secrets-store/store /var/lib/secrets-store/store/example-code /var/lib/secrets-store/store/other
# Same token-adding command as docs/backends.md, with the value piped instead of typed.
printf '%s' fake-container-value | install -m 0600 -o secrets-store -g secrets-store /dev/stdin \
  /var/lib/secrets-store/store/example-code/GITHUB_TOKEN
printf '%s' other-value | install -m 0600 -o secrets-store -g secrets-store /dev/stdin \
  /var/lib/secrets-store/store/other/TOKEN
KH='/usr/local/bin/secrets-exec-keyhost --store /var/lib/secrets-store/store --allow example-code'
cat > /etc/sudoers.d/secrets-exec <<EOF
agent ALL=(secrets-store) NOPASSWD: $KH get *, $KH list *
EOF
chmod 0440 /etc/sudoers.d/secrets-exec
visudo -cf /etc/sudoers.d/secrets-exec >/dev/null

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
echo "other|other|TOKEN|GITHUB_PAT|$HOME/.config/secrets-exec/consumers.d/check|" >> ~/.config/secrets-exec/consumers.conf
sed -n "s/^#\(host=local\)$/\1/p; /Option A/,/Option B/ s/^#\(get=.*\)$/\1/p; /Option A/,/Option B/ s/^#\(list=.*\)$/\1/p" /opt/src/examples/backend.example.conf > ~/.config/secrets-exec/backend.conf
chmod 0600 ~/.config/secrets-exec/*.conf
echo "--- backend.conf"; cat ~/.config/secrets-exec/backend.conf
echo "--- 1 allowed consumer"; ~/bin/secrets-exec check
echo "--- 2 store unreadable to agent"; if cat /var/lib/secrets-store/store/example-code/GITHUB_TOKEN; then exit 9; fi
echo "--- 3 bundle outside allowlist refused"; if ~/bin/secrets-exec other; then exit 9; fi
echo "--- 4 agent cannot widen the allowlist via sudo"
if sudo -n -u secrets-store /usr/local/bin/secrets-exec-keyhost --store /var/lib/secrets-store/store --allow other get other TOKEN; then exit 9; fi
echo "--- 5 agent cannot run anything else as the store user"
if sudo -n -u secrets-store /bin/cat /var/lib/secrets-store/store/other/TOKEN; then exit 9; fi
echo "--- 6 extra arguments after the pinned prefix refused"
if sudo -n -u secrets-store /usr/local/bin/secrets-exec-keyhost --store /var/lib/secrets-store/store --allow example-code get example-code GITHUB_TOKEN --allow other; then exit 9; fi
echo "--- 7 audit"; cat ~/.config/secrets-exec/audit.log
if grep -q fake-container-value ~/.config/secrets-exec/audit.log; then exit 9; fi; echo "value not in audit"
'
echo CONTAINER-TEST-PASSED
