# Reference key host

This Linux/Bash reference is the other end of `backend.conf`. It reads a private
file store owned by a **separate principal**: another OS user on the same machine
(reached with one pinned sudo rule) or another machine (reached with a restricted
SSH key). For choosing between them and the same-machine setup, see
[docs/backends.md](../../docs/backends.md); this guide covers the SSH setup and the
key host's own rules. It needs Bash, GNU coreutils, and `/proc` mounted. It does not
need a vault service, network API, `pass`, or `age`.

## Boundary and threat model

Use a dedicated key-host account and a separate SSH key for each client. Each
client's public key gets a forced command with its own bundle allowlist. With
`command="...",restrict` in `authorized_keys`, that key cannot select another
program, obtain a shell, allocate a PTY, or forward connections. This assumes a
current OpenSSH server that supports `restrict`, correctly configured SSH access,
and no other unrestricted login method for that client. Disable password and
keyboard-interactive login for this dedicated account as appropriate. Do not use
a shared unrestricted SSH identity for the same account.

Over SSH, the endpoint accepts **only** these exact strings in `SSH_ORIGINAL_COMMAND`:

```text
get 'bundle' 'KEY'
list 'bundle'
```

Locally (same machine, `host=local`), the same request arrives as arguments after the
options: `secrets-exec-keyhost --store ... --allow ... get BUNDLE KEY` or `list BUNDLE`.
It is rebuilt into the quoted form above and checked by the same parser. Arguments
win over an inherited `SSH_ORIGINAL_COMMAND`.

Names use letters, digits, underscores, dots and hyphens, but cannot start with a
dot. Whitespace variations, newlines, extra arguments, shell syntax and client
options are refused. Requests are parsed, never evaluated. Bundles must appear in
the forced command's explicit `--allow` list. `--store` and `--log` are trusted
administrator options on that command, not request options.

**An authorized client can read every value in an allowed bundle.** The allowlist
is not per-key or per-consumer authorization. A compromised client SSH key can
fetch these values directly, regardless of the local registry. Keep bundles narrow
and credentials scoped/read-only. The local engine remains leak reduction, not
containment; this endpoint does not make an untrusted consumer safe.

The account, script, system tools, store, and log directory must be trusted. The
reference rejects symlinks in the store path, non-regular values, wrong owners,
and group/other file permissions. Store and bundle directories must belong to the
account and not be group/other writable; use 0700 throughout. These checks do not
provide race-proof isolation against a malicious same-account process or someone
able to replace parent directories. Hard links, backups, memory, filesystem root
access and SSH server compromise remain outside the boundary. Do not let other
users modify ancestor directories. No values are encrypted at rest by this script.

Values must be nonempty, contain no NUL, and have at most one trailing newline.
Successful `get` returns the exact file bytes with no banner; the local engine
strips a trailing newline when capturing stdout. Internal newlines are preserved.
`list` emits only valid, private regular-file names and fails without a partial
listing if any entry is unsafe. For the engine's wildcard lookup, use shell
identifier key names, such as `API_TOKEN`; its list parser ignores dotted or
hyphenated names. Such names can still be fetched as exact keys.

Errors go to stderr, never deliberately containing values or raw request text.
Optional `--log /absolute/private/requests.log` records parsed action/bundle/key
names only, before reading a value. A logging failure refuses the request. It is
not a complete security audit: malformed/unauthorized requests are not logged,
and there is no log rotation or rate limiting. Existing logs must be private and
owned by the account. Keep their parent directory private too.

## Set up the key host over SSH

Review the script before installing it. On the **key host**, as the dedicated
account (not root):

```sh
umask 077
install -d -m 0700 "$HOME/bin" "$HOME/.ssh" \
  "$HOME/.local/share/secrets-exec-keyhost/store/example-code"
install -m 0755 examples/keyhost/secrets-exec-keyhost "$HOME/bin/secrets-exec-keyhost"
touch "$HOME/.ssh/authorized_keys"
chmod 0600 "$HOME/.ssh/authorized_keys"
```

Add a line to `authorized_keys` using the actual **absolute** script path and the
client public key. The example home/account and key below are placeholders:

```text
command="/home/keykeeper/bin/secrets-exec-keyhost --allow example-code",restrict ssh-ed25519 AAAA_REPLACE_WITH_CLIENT_PUBLIC_KEY client-reference
```

The default store is `~/.local/share/secrets-exec-keyhost/store`, derived from the
key-host account's HOME. To choose a different location, add
`--store /absolute/private/store` to the forced command; to allow two bundles, use
`--allow example-code,example-demo`. Do not let the client edit this line or the
script/store. Do not enable `AcceptEnv` for HOME or shell/runtime configuration.
Keep the account's login shell and startup files trusted: sshd invokes the forced
command via that shell, before this script's privileged Bash mode takes effect.

On the **client**, configure an SSH alias named `keyhost` with the dedicated key
and verified host keys. Install this exact backend configuration (0600):

```ini
host=keyhost
get=get {bundle} {key}
list=list {bundle}
```

These templates intentionally contain **no quotes**. They pass the engine's
plain-word template validation; the engine inserts the quoted bundle/key tokens.
Do not weaken SSH host-key verification. The local installer does not deploy an
SSH server, key, forced command, or remote store.

## Add or rotate a value

On the key host, as the dedicated account, read a value interactively so it does
not enter shell history or command arguments. Replace the generic bundle/key
below as needed. Keep tracing disabled. The temporary file and final value remain
mode 0600; `mv` publishes a complete file atomically within the bundle directory.

```bash
set +x
umask 077
bundle="$HOME/.local/share/secrets-exec-keyhost/store/example-code"
install -d -m 0700 "$bundle"
tmp="$(mktemp "$bundle/rotation-XXXXXXXX")"
trap 'rm -f -- "$tmp"; unset value' EXIT
IFS= read -r -s -p 'New API_TOKEN: ' value
printf '\n' >&2
printf '%s' "$value" > "$tmp"
unset value
chmod 0600 "$tmp"
mv -- "$tmp" "$bundle/API_TOKEN"
trap - EXIT
```

For actual credential rotation, provision the new credential at its issuer,
update the file, verify a reviewed consumer, and revoke the old credential at its
issuer. Replacing the file alone does not revoke old copies. Revoke a compromised
client by removing its public-key line and terminating any existing sessions using
your normal administrative procedure. Account for copies in backups and snapshots.

An encrypted-at-rest variant could replace the file-read implementation with a
reviewed `pass` lookup or `age` decryption. Keep the same strict parser and
allowlist, a fixed mapping from validated names to entries, and stdout/error
contract. The key-host account still needs access to the decryption key or agent;
encryption at rest does not protect against that account's compromise. These
variants are design notes only, not implemented or tested here.
