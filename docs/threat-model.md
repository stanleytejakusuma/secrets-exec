# Threat model

## Claim: leak reduction, not containment

The intended outcome is fewer accidental credential disclosures in tool output,
conversation transcripts, command arguments and logs. This depends on trusted,
reviewed consumers. It is not a security boundary against a process running as the
installation owner. The installed files, local OS, SSH implementation, remote key
store, system utilities and consumer dependencies are trusted.

## Controls implemented

- A caller selects a consumer, not an arbitrary bundle/key or executable. Exact
  string matching and a restricted name alphabet prevent pattern-based row selection.
- The registry fixes absolute commands. Obvious interpreter/environment-dumper
  basenames are blocked, caller-supplied URLs are denied, and optional argument guards
  catch credential-printing phrases and redirecting flag prefixes/short clusters.
  A renamed malicious script still passes: program review is the primary control.
- Configuration and audit locations derive from the engine's own installation path;
  caller environment variables cannot select another registry or backend.
- Bash `-p` ignores imported options/functions. PATH is pinned before external
  utilities run, HOME is pinned for the consumer, and known shell/loader/proxy/TLS/
  interpreter hooks are scrubbed from programs started by the engine. Ordinary
  environment variables remain, so consumer-specific hooks still need review.
- Values travel from SSH stdout into shell variables, then into the consumer's
  environment. Secret assignments do not appear in argv. Multi-key fetch failures
  and empty values stop execution before exporting a partial credential set.
- An allow audit record must succeed before the consumer starts. Refusals are
  recorded best-effort, and exit-status auditing is also best-effort. Audit creation
  uses `umask 077`; existing permissions are not repaired automatically. Records
  contain names, arguments and reasons, never deliberately the fetched values.
  Every event carries a validated/generated call identifier. Exclusive advisory locks
  serialize whole appends (util-linux flock, or isolated Python fcntl when absent);
  lock failure prevents execution when the allow event cannot be recorded.
- Opt-in first-line metadata names the resolved credential selection before fetch,
  not proof of a successful fetch or consumer execution. Internal controls are cleared
  before child programs start and reserved as credential destinations. The header is
  unauthenticated same-user data, not an authorization assertion. See
  [structured results](structured-results.md).
- Example HTTP consumers pin destinations, use HTTPS and do not follow redirects.
  The shared engine rejects dot segments and single-encoded dot/slash/backslash
  path components. Curl reads secret headers from stdin with `-q` first to disable
  user curl configuration, and requests have timeouts and a byte-limit option.
- Exchange examples accept only fixed verbs, validate credential characters/length,
  bound pagination/time windows and avoid passing HMAC keys to command-line signing
  tools. Python signing uses isolated mode and the standard library.

## Non-goals and residual risks

| Attack or failure | Residual risk |
| --- | --- |
| Edit engine, registry, backend or consumers as their owner | Trivial bypass. Separate principals and immutable policy are not implemented. |
| Read child environments or process memory as the same user | Values exist in memory and exported environments; process inspection and dumps can disclose them. |
| Inject native code before the engine starts | A dynamic loader can run caller code before the script can scrub variables; equivalent to same-user code execution. |
| A consumer or dependency prints credentials | The engine cannot generally distinguish secrets from legitimate output. Consumer review and least-privilege credentials are necessary. |
| Unrecognized environment or configuration hooks | The scrub list is deliberately finite, not a clean-room environment. System/user configuration still matters. |
| Malicious remote key store or SSH account | The backend supplies the values. SSH authentication is transport trust, not assurance that values or remote commands are safe. |
| Stalled backend command | Connection timeouts exist; a remote command that never finishes has no overall deadline. |
| Backend interprets double encoding or service-specific routes | Single-encoding traversal checks and globs do not model every server's URL semantics. Tight per-service paths are needed. |
| Arbitrary header/token bytes in generic HTTP configuration | Trusted installation data is not comprehensively validated. Use simple single-line tokens and review header values. Exchange examples perform stricter credential validation. |
| Upstream response echoes a credential or contains hostile text | Generic HTTP output is not universally redacted. Treat returned text as untrusted and account data as sensitive. |
| Huge unknown-length HTTP response | Curl's max-filesize behavior varies with version and response framing. It is defense in depth, not a guaranteed streaming cap. |
| Secrets supplied as caller arguments or correlation IDs | Arguments, refusal reasons and valid call IDs enter the audit; never put credentials there. |
| Forged metadata or output as the same user | The header is unauthenticated; matching IDs catch mix-ups, not forgery. Selection metadata does not establish successful secret use. |
| Missing audit exit/refusal line, or full disk | Pre-execution allow logging fails closed, but subsequent exit/refusal logging cannot be guaranteed. No log rotation is bundled. |
| Exchange permission changes after keyinfo | The verdict is a point-in-time self-report. It does not prevent an owner or service from changing permissions. |

## Testing scope

Offline fixtures test callers controlling names, arguments and environment without
editing installed policy. They also test fail-closed behavior for malformed rows,
backend configuration and failed credential fetches. Metadata tests cover selection
framing, control isolation and concurrent large audit records with both lock helpers. Native-loader checks only
establish that later child programs are not instrumented by the supplied test
library; they cannot protect the engine's pre-start loader.

No live exchange authentication, remote store, end-to-end forced-command deployment,
macOS compatibility, containment claim or exhaustive exfiltration proof is covered.
See [the roadmap](roadmap.md) for prospective stronger boundaries.
