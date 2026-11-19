# Where tokens live: backends

secrets-exec does not store tokens. Each call fetches them from a **backend** named in
`~/.config/secrets-exec/backend.conf`. Keep the store somewhere the agent's OS user cannot
read directly; otherwise a misbehaving agent can skip secrets-exec and read the file.

| Option | Store lives | Needs | Good for |
| --- | --- | --- | --- |
| Trial (`scripts/quickstart.sh`) | under your own user, in a temp directory | nothing | trying it out; never real tokens |
| **A. Same machine, separate user** | another OS account, reached through one pinned sudo rule | root once, for setup | a single workstation or server |
| **B. Separate machine** | another host, reached through a restricted SSH key | a second machine you control | stronger separation; several clients |

Both A and B use the reference key host in [`examples/keyhost/`](../examples/keyhost/):
a small Bash program that answers only `get <bundle> <key>` and `list <bundle>`, for
bundles on its `--allow` list, from a private file store.

What they protect: the agent's user cannot read the store, and can fetch only allowed
bundles. What they don't: anything running as the agent's user can still fetch those
allowed bundles by calling the backend itself (see the [threat model](threat-model.md)).
Keep each allowlist to the bundles that user really needs.

## Option A: same machine, separate user

Use this when the agent runs as an ordinary account **with no other sudo rights**. If
the agent's account can already run anything as root, a sudo rule adds no separation:
create a separate account for the agent first.

Run as root once, in bash, from this repository's checkout. Replace `you` with the account your agent runs as, and
`example-code` with your bundle names (comma-separated for several).

```sh
# 1. A locked account that owns the store, and the key host where only root can change it
useradd --system --create-home --home-dir /var/lib/secrets-store \
  --shell /usr/sbin/nologin secrets-store
install -m 0755 examples/keyhost/secrets-exec-keyhost /usr/local/bin/secrets-exec-keyhost
install -d -m 0700 -o secrets-store -g secrets-store \
  /var/lib/secrets-store/store /var/lib/secrets-store/store/example-code

# 2. Let `you` run only that program, as that account, with these exact options.
#    Check the rule before installing it: a broken file in sudoers.d can break sudo.
KH='/usr/local/bin/secrets-exec-keyhost --store /var/lib/secrets-store/store --allow example-code'
KS="${KH//,/\\,}"   # sudoers needs commas written as \, (only matters for several bundles)
tmp="$(mktemp)"
printf 'you ALL=(secrets-store) NOPASSWD:NOLOG_OUTPUT: %s get *, %s list *\n' "$KS" "$KS" > "$tmp"
visudo -cf "$tmp" && install -m 0440 "$tmp" /etc/sudoers.d/secrets-exec
rm -f "$tmp"
```

`NOLOG_OUTPUT` keeps the token out of sudo's I/O log when output logging is turned on
with `log_output`. If your sudoers instead sets `log_stdout` or `log_ttyout` directly,
also add `Defaults!/usr/local/bin/secrets-exec-keyhost !log_stdout, !log_ttyout` (and
check it with `visudo -c`). sudo matches the arguments as one space-joined string; the key host
refuses repeated options and option values containing spaces, so a crafted argument
list cannot match this rule while selecting another store or allowlist.

Add a token without it touching shell history or arguments (as root):

```sh
read -r -s -p 'GITHUB_TOKEN: ' v; printf '\n'
printf '%s' "$v" | install -m 0600 -o secrets-store -g secrets-store /dev/stdin \
  /var/lib/secrets-store/store/example-code/GITHUB_TOKEN
unset v
```

Then, as `you`, use Option A from
[`examples/backend.example.conf`](../examples/backend.example.conf):

```ini
host=local
get=/usr/bin/sudo -n -u secrets-store /usr/local/bin/secrets-exec-keyhost --store /var/lib/secrets-store/store --allow example-code get {bundle} {key}
list=/usr/bin/sudo -n -u secrets-store /usr/local/bin/secrets-exec-keyhost --store /var/lib/secrets-store/store --allow example-code list {bundle}
```

The `--store` and `--allow` text must match the sudoers line exactly (with plain commas
here), or sudo refuses. The sudo rule fixes those options, so the agent's user cannot
widen its own allowlist, pick another store, or run anything else as `secrets-store`.
It **can** still run the key host for the allowed bundles itself, and print a value:
block that command in your agent's tool rules ([AI-agent setup](ai-agents.md)).

This whole flow, including those refusals and a crafted-argument bypass attempt, runs
with real sudo in a Debian container in CI:
[`tests/container-same-machine.sh`](../tests/container-same-machine.sh).

If a call fails with only `backend rc=1`, run the `get` command from `backend.conf`
yourself with a test bundle to see the key host's or sudo's error (secrets-exec
discards backend error output, since it could contain a value). If sudo says it needs
a terminal, your sudoers has `requiretty`; add `Defaults:you !requiretty`.

## Option B: separate machine over SSH

Set up the key host on the other machine with a forced-command SSH key, as described in
the [key-host guide](../examples/keyhost/README.md). On this machine, add an SSH alias
(for example `keyhost`) with that dedicated key and verified host keys, then:

```ini
host=keyhost
get=get {bundle} {key}
list=list {bundle}
```

## backend.conf reference

```ini
host=<local | ssh destination>
get=<command words with {bundle} then {key}>
list=<command words with {bundle}>
```

- `host=local` runs `get`/`list` on this machine **without a shell**: each word is one
  argument and `{bundle}`/`{key}` are replaced by one name each. The first word must be
  an absolute path to an executable. The helper's stdin is closed, and it starts with
  only `PATH=/usr/bin:/bin`, `HOME` (the installation home) and `LC_ALL=C`. Bundle and
  key names starting with `-` are refused. (`local` is therefore not usable as an SSH
  alias name.)
- Any other `host` is an SSH destination: a hostname, `~/.ssh/config` alias or
  `user@host`, never an SSH option. The names are inserted single-quoted into the
  remote command. SSH runs non-interactively (`BatchMode=yes`, `-n`) with a connection
  timeout. Configure keys and host verification in SSH configuration; don't disable it.
- Templates are plain words: letters, digits, `_ . / ~ , -`, spaces, and the
  placeholders as whole words. Quotes, substitutions and other shell characters are
  refused. The file is parsed, never sourced, and only read when a value is needed.
- `get` prints one nonempty value on stdout and exits 0. Errors go to stderr with a
  nonzero exit. No banner or JSON.
- `list` prints key **names**, one per line. It is used only for registry rows whose key
  contains `*`. Zero or several matches refuse the call.
- There is no overall timeout for a backend command that never finishes.

To use another store, write a helper that follows the same `get`/`list` contract and
keeps its own allowlist. Never point `get` at a general shell or a program that accepts
arbitrary input.
