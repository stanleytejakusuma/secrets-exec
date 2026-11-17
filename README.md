# secrets-exec

Run a named, allowlisted consumer with credentials injected into its environment,
without returning the credential values to the caller. Intended for automation and
AI tools that need to **use** a credential without pasting it into a transcript.

**Status:** Early release; reviewed, but not independently security-audited.

**Leak reduction, not containment.** The engine, registry and consumers normally
belong to the same OS user. A caller with that user's shell can edit them or inspect
process environments. This is not a sandbox, a vault, or a defense against a hostile
same-user process. See [the threat model](docs/threat-model.md).

## How it works

1. The caller provides a consumer name and arguments, never a command or secret name.
2. A local registry fixes the bundle, key name(s), injected environment name(s), and
   absolute consumer command. Unknown names, unsafe rows and caller URLs fail closed.
3. The engine fetches values over SSH using the installed `backend.conf`. Failed or
   empty fetches stop the call; multi-key credentials are never partially injected.
4. The engine writes an audit record, exports the values, starts the consumer as a
   **child**, then records its exit status. Secret assignments are not put in argv.

Bash privileged mode ignores imported shell options/functions. The engine pins PATH
and HOME, scrubs known runtime hooks, proxies, TLS overrides and loader/interpreter
variables, and creates files with `umask 077`. Ordinary variables are still inherited.
The audit includes consumer, bundle/key names, arguments, outcome, exit status and
`via=` invocation name, not fetched values. Never supply secrets as arguments:
arguments and refusal reasons are logged.

## Requirements

Runtime targets Linux with Bash, OpenSSH, GNU coreutils, awk, grep and sed at the
standard system paths. HTTP examples require `/usr/bin/curl`; the exchange examples
also require `/usr/bin/jq`, `/usr/bin/python3` with its standard library, and GNU date.
macOS and nonstandard layouts are not fully tested. Use the executable engine as
installed; **do not run it with `bash bin/secrets-exec`**, which bypasses its `-p`
shebang protection, and do not enable shell tracing around credential use.

## Install by hand

Review the source and examples first. Nothing is installed automatically. From this
source directory, copy files into the layout below (no remote calls occur here):

```sh
install -d -m 0700 "$HOME/bin" "$HOME/.config/secrets-exec" \
  "$HOME/.config/secrets-exec/consumers.d" "$HOME/.config/secrets-exec/http-consumers"
install -m 0755 bin/secrets-exec "$HOME/bin/secrets-exec"
install -m 0755 http-get-engine.sh "$HOME/.config/secrets-exec/http-get-engine.sh"
install -m 0755 examples/consumers.d/* "$HOME/.config/secrets-exec/consumers.d/"
install -m 0600 examples/http-consumers/github-read.conf "$HOME/.config/secrets-exec/http-consumers/github-read.conf"
install -m 0600 examples/consumers.example.conf "$HOME/.config/secrets-exec/consumers.conf"
install -m 0600 examples/backend.example.conf "$HOME/.config/secrets-exec/backend.conf"
```

Edit `consumers.conf`: replace `/home/you` with your absolute home path, choose your
own bundle/key names, and **remove every row you do not intend to authorize**. These
examples contain no credential values. Edit `backend.conf` to your reviewed backend.
Do not add a general CLI simply because it accepts a token environment variable;
many CLIs have flags or verbs that reveal the token or redirect requests.

The engine expects to live at `<home>/bin/secrets-exec`; it derives
`<home>/.config/secrets-exec/{consumers.conf,backend.conf,audit.log}` from its own
location, not the caller's HOME. Keep configuration directories mode 0700, files
0600, and reviewed programs executable. Avoid symlinking the engine from a different
installation root: its invocation location determines configuration lookup.

After configuring a real backend, `~/bin/secrets-exec --list` lists names only.
`~/bin/secrets-exec github-read /user` makes an authenticated GitHub GET request;
it returns account data, not a token. Do not use live credentials to test installation
until you have reviewed the chosen consumer's entire behavior.

## Backend protocol

The backend is **not bundled**. Supply an SSH destination running commands that can
read your chosen key store. The example is:

```ini
host=keyhost.example
get=kv-get {bundle} {key}
list=kv-list {bundle}
```

- `host` is a hostname, SSH config alias or `user@host`, not an SSH option. Configure
  identity and known-host verification in SSH configuration; do not disable it.
- `get` prints one nonempty value on stdout and exits zero. Errors/diagnostics belong
  on stderr with a nonzero exit status. No JSON envelope or success banner.
- `list` prints key **names**, one per line; used only for single-key `*` patterns.
  Names must look like shell identifiers. Zero or multiple matches refuse the call.
- The engine replaces `{bundle}` and `{key}` with validated, single-quoted names.
  Templates are plain words using letters, digits, `_ . / ~ { } -` and spaces;
  shell quotes, substitutions and metacharacters are refused. These are command
  templates, not executable local configuration: files are parsed, never sourced.
- SSH is noninteractive (`BatchMode=yes`), uses `-n` to preserve consumer stdin, and
  has connection timeouts. There is no overall timeout for a stalled remote command.

Use a dedicated restricted SSH identity, for example an `authorized_keys` forced
command that independently parses and authorizes `SSH_ORIGINAL_COMMAND`, rejects
unexpected input, disables forwarding/PTY access, and limits readable bundles/keys.
The remote command must not be a general shell. The local template grammar alone
is not remote access control. No SSH server or forced-command implementation is
included here; adapting an existing trusted store is an installation responsibility.

## Examples and extension

- `github-read`: shared GET-only header-auth engine; fixed GitHub host and configured
  path allowlist. It accepts a path, not a URL. Scope the token and allowlist narrowly.
- `bitget-read` and `mexc-read`: closed read-only verbs, fixed public exchange endpoints,
  HMAC signing through Python's standard library, credentials through environment and
  curl stdin (not argv). Use read-only exchange keys with withdrawals/trading disabled.
- `demo`: `/usr/bin/true`; demonstrates a single-key row without printing the value.

Exchange JSON schema tags use an `example.bitget` or `example.mexc` prefix. Outputs
can include sensitive balances, positions and wallet metadata; these are not
anonymization tools. `keyinfo` has `allow`, `deny` and `error` verdicts; it is an
exchange self-report, not proof of an immutable permission boundary. `check` is a
network-free credential-shape/signer check when invoked directly; using it through
the engine still fetches credentials over SSH first. Review every permission code
against current exchange documentation. Live API behavior is not verified by the
offline tests. API changes may require review before use.

Read [adding a consumer](docs/adding-a-consumer.md),
[AI-agent integration](docs/ai-agents.md), [security reporting](SECURITY.md),
[the changelog](CHANGELOG.md), and [future directions](docs/roadmap.md).

## Offline tests

```sh
bash tests/run-all.sh
```

No key store, credentials or network required. Tests copy the engines into temporary
homes and replace SSH/curl with local stubs before running them. Suites cover
refusals, environment/name hardening, HTTP traversal and time/size configuration,
backend parsing, single-key/glob/multi-key execution, stdin preservation and audit
behavior. The optional native-loader test compiles a local library when GCC is
available; otherwise that individual check reports `SKIP`.

## Limitations

Same-user code execution defeats the wrapper. Fetched values remain in process
memory/environments and may be observable through process inspection, crash dumps,
consumer output or dependencies. Consumers are trusted code; filename blocking and
argument guards are only secondary mistake prevention. Unknown environment hooks
may survive the scrub list. HTTP path globs are not semantic authorization and do
not cover every service's decoding behavior. The HTTP engine trusts installed
headers and token shape; it is not a general sanitizer for arbitrary credentials or
upstream bodies. Some responses may echo inputs. Curl byte limits are version- and
response-dependent, not a universal streaming bound. Audit rotation, leases,
revocation, remote authorization and a separate security principal are not provided.

## License

MIT; see [LICENSE](LICENSE).
