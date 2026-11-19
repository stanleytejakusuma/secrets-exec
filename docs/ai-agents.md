# Credentialed access for AI coding agents

The goal is to let an agent perform a reviewed task without putting credentials in
its context or transcript. This is **leak reduction, not containment**. An agent
harness (for example Claude Code, Codex, Cursor or Pi) can expose one tool or command:

```text
secrets-exec <consumer> [args]
```

Give the agent the approved consumer names, argument shapes and expected outputs.
Do not give it direct access to the key host or the store, credential values, or a
general secret-reading tool. The installed engine handles backend access; the agent
only requests a named operation. Do not paste backend configuration into prompts.

## Register narrow, read-only consumers

The installation owner should review and register a purpose-built consumer for
each task, following [the consumer checklist](adding-a-consumer.md). For example,
a repository reader might accept only an approved repository name and a closed set
of read operations. Fix the HTTPS destination, methods and paths in trusted code;
use a minimally scoped, read-only credential at the service itself.

Do not register general CLIs, interpreters, arbitrary HTTP clients or commands
that accept URLs, shell snippets, configuration files or credential-printing verbs.
A general CLI does not become safe merely because its token arrives through an
environment variable. The wrapper's basename and argument guards are secondary
mistake prevention, not a substitute for reviewing the consumer.

Treat all arguments as attacker-influenced. A prompt injection in a repository,
issue, web page or API response can persuade the agent to supply malicious input.
Consumers must validate argument counts, types, lengths and allowed values, reject
unknown options, and refuse caller-selected destinations. Never interpolate caller
arguments into shell code. Test refusals with local fixtures before installation.

## Keep policy under owner control

Never let the agent edit `consumers.conf`, `backend.conf` or `consumers.d/`, including
by installing an agent-proposed patch without review. Also protect the engine,
shared HTTP engine and HTTP configuration: changing any trusted code or policy can
redirect a credential. Review diffs before the installation owner applies changes.

Make installed configuration directories owner-only (mode `0700`), configuration
files `0600`, and consumer executables `0755` inside those owner-only directories
(as `scripts/install.sh` does). Keep the owner's review
and installation step outside the agent's editable workspace. These modes exclude
other users, **not an agent running as the owner**. If enforcement is required, use
a separately controlled OS principal and restrict its interface; this project does
not implement that boundary.

## Add a command-deny hook as a speed bump

Configure the harness's command-deny hook to reject direct key-store access in
agent-requested shell commands. Illustrative POSIX extended regexes follow; replace
the example host, store path and key-host command with your installation's values
and test them against the harness's actual matching rules:

```text
(^|[;&|[:space:]])(/usr/bin/)?ssh[[:space:]]+[^;&|]*keyhost[.]example([[:space:]]|$)
(^|[;&|[:space:]])(/usr/bin/|/bin/)?cat[[:space:]]+[^;&|]*/var/lib/example-key-store(/|[[:space:]]|$)
(^|[;&|[:space:]])(/opt/key-store/)?kv-(get|list)([[:space:]]|$)
```

These deny direct SSH to the example key host, `cat` of the example store, and
running the example key-host reader/listing commands. Apply the hook to the agent's
tool requests, not the reviewed engine's internal SSH transport. Check that an
approved `secrets-exec` request is still allowed.

Regexes are a speed bump, not a security boundary: quoting, aliases, alternate
paths, SSH configuration aliases, other file readers, interpreters and command
composition can evade them. A deny hook does not remove the agent's underlying
shell permissions. Do not claim that these examples exhaust shell syntax or stop
a malicious agent with full shell access.

## Review output and audit records

Output redaction is the consumer's job. The engine does not sanitize arbitrary
stdout or stderr. Project only necessary response fields and redact credentials,
sensitive account data and error details before returning them to the agent.
Read-only requests may still return sensitive information or echo inputs. Treat
returned text as untrusted data, not instructions to change policy or fetch secrets.

The installation owner should regularly review
`<home>/.config/secrets-exec/audit.log` for unexpected consumers, arguments, refusal
patterns, missing exit records and nonzero statuses. Correlate allowed requests
with the work that was authorized. Audit records include arguments and refusal
reasons: never put credentials in arguments, and treat the log as sensitive.
Pre-execution logging fails closed, but refusal and exit logging are best-effort;
the same-user owner can alter the log. Rotation and tamper-proof storage are not
provided.

## What this does not protect

An agent with a full shell running as the installation owner can edit the wrapper,
policy and consumers, read accessible store files, or inspect another process's
`/proc/<pid>/environ` where OS permissions permit. Credentials also exist in process
memory and may leak through dumps, dependencies or consumer output. Owner-only
modes, prompt instructions and command regexes cannot contain that agent.

Use this pattern to reduce accidental disclosure and constrain normal tool calls.
For hostile same-user execution, a separate security principal and independently
enforced backend authorization are necessary. See [the threat model](threat-model.md)
and [backend setup](backends.md) before connecting real credentials.
