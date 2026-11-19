# secrets-exec

**Let AI agents and scripts use your API tokens without ever seeing them.**

Your agent runs `secrets-exec github-read /user`. secrets-exec looks up `github-read` in a
list you control, fetches the GitHub token, and runs the program you reviewed with the
token in its environment. The agent gets that program's output. The token never enters
the agent's context, its transcript, or your model provider's logs.

```text
agent ── "github-read /user" ──▶ secrets-exec ── fetch ──▶ key store (another user or machine)
                                     │
                                     │  registry: github-read → GITHUB_TOKEN → reviewed program
                                     ▼
                         reviewed program (token in env) ──▶ GitHub API
agent ◀──────────────── program output only ────────────┘
```

Linux only for now. MIT licensed. Plain Bash, no daemon, no service to run.

## Try it in 2 minutes

```sh
git clone https://github.com/stanleytejakusuma/secrets-exec
cd secrets-exec
./scripts/quickstart.sh
```

The trial builds a throwaway installation in one new temporary directory, with a fake
token. It needs no sudo, network or SSH, and writes nothing anywhere else. You'll see:

```text
== 2. Run a consumer: it gets the token, the caller only gets its output
$ secrets-exec demo
demo-check: I received DEMO_TOKEN (37 characters) and used it. I never print it.

== 3. Anything not registered is refused
$ secrets-exec /bin/sh -c id
secrets-exec: invalid consumer name /bin/sh

== 5. Was the token in anything you just saw?
No. It was in the consumer's environment only.
```

## What it protects, and what it doesn't

| Protected | Not protected |
| --- | --- |
| The token stays out of the agent's context, transcript and provider logs | Anything already running as the agent's OS user can read process memory and environments |
| The agent can only run programs you registered, not "any command with the token" | A registered program that prints its token, or a buggy one |
| Caller URLs, shells and interpreters are refused; destinations are fixed per program | Secrets the agent puts in arguments (arguments are logged) |
| Common environment tricks (proxy, CA bundle, loader and shell hooks) are stripped | Every possible environment hook (the scrub list is finite) |
| Every call and refusal is audited: names and arguments, never values | Audit rotation, leases or revocation (not built in) |

To keep the token store itself out of the agent's reach, put it under another OS user or
another machine ([backends](docs/backends.md)). Details: [threat model](docs/threat-model.md).

## Why not `op run`, Doppler, `aws-vault` or a `.env` file?

Those tools inject a secret into **whatever command you name**. That's right for you at a
terminal. For an agent, it means `op run -- env` or `doppler run -- printenv` hands it
the raw token.

secrets-exec has no "run this command with the token" mode. The caller picks a name from
a short list; you decide in advance which program runs, with which token, against which
destination. Use the others for your own shell, and secrets-exec for what agents and
unattended scripts may touch.

## Real setup

1. **Install** (no sudo; dry run first, then apply):
   ```sh
   ./scripts/install.sh
   ./scripts/install.sh --apply
   ```
   This puts `secrets-exec` in `~/bin` and examples under `~/.config/secrets-exec/`.
   It never overwrites an existing `consumers.conf` or `backend.conf`.
2. **Choose where tokens live** and fill in `backend.conf`: the same machine under a
   separate user (one sudo rule), or a separate machine over SSH. Step-by-step:
   [docs/backends.md](docs/backends.md).
3. **Register programs** in `consumers.conf`. Every example row starts commented out;
   uncomment only what you've reviewed. The GitHub reader's program is already
   installed: uncomment its row and store a read-only token. Writing your own:
   [adding a consumer](docs/adding-a-consumer.md).
4. **Give your agent only `secrets-exec`.** Tell it never to put secrets in arguments,
   and deny it direct access to the store. Checklist and example agent rules:
   [AI-agent setup](docs/ai-agents.md).

Check it: `~/bin/secrets-exec --list` shows what's registered (names, never values).
`~/bin/secrets-exec github-read /user` returns your GitHub account, not the token.

**Requirements:** Linux with Bash, GNU coreutils, awk, grep and sed;
`/usr/bin/flock` or `/usr/bin/python3` for audit locking; OpenSSH for the SSH backend;
`/usr/bin/curl` for the HTTP examples. The engine reads its configuration from
`<home>/.config/secrets-exec/`, where `<home>` is the parent of the `bin/` it is installed
in, never from the caller's environment. Run it directly, never as
`bash bin/secrets-exec`: that skips the protections in its `#!/bin/bash -p` line.

## Examples

- `github-read`: GET-only GitHub API reader. It accepts an API path such as `/user`,
  never a URL, and only paths on its allowlist. Built on a shared, header-auth HTTP
  engine you can reuse for other APIs.
- `scripts/quickstart.sh`: a trial consumer that proves it received a token without
  printing it.
- `examples/advanced/`: read-only crypto-exchange readers (HMAC-signed requests with
  multi-part keys), for a more involved pattern. Not installed by default.
- `examples/wrappers/parse_result.py`: reads the optional JSON header described in
  [structured results](docs/structured-results.md).

## Security

- **Offline test suite** run in CI on every push: refusals, environment scrubbing,
  HTTP path checks, backends, multi-key fetches, key host, installer, quick start.
  Run it yourself with `bash tests/run-all.sh` (no credentials or network needed).
- **Same-machine setup tested with real sudo** in a Debian container:
  `bash tests/container-same-machine.sh`.
- **Published [threat model](docs/threat-model.md)**, including what is out of scope.
- **Independent reviews:** the code has had several independent AI-assisted security
  reviews; their findings and fixes are listed in the [changelog](CHANGELOG.md).
- **Report a vulnerability** privately: see [SECURITY.md](SECURITY.md).

## Documentation

[Backends](docs/backends.md) ·
[AI-agent setup](docs/ai-agents.md) ·
[Adding a consumer](docs/adding-a-consumer.md) ·
[Threat model](docs/threat-model.md) ·
[Structured results](docs/structured-results.md) ·
[Key host](examples/keyhost/README.md) ·
[Roadmap](docs/roadmap.md) ·
[Changelog](CHANGELOG.md)

## License

MIT; see [LICENSE](LICENSE).
