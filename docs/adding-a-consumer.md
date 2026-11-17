# Adding a consumer

The registry owner reviews and installs policy. Untrusted callers should only name
already-installed consumers; they should not be able to approve their own policy.
This remains a conduct/ownership rule until enforced by a separate OS principal.

## Registry format

Each row is a literal pipe-separated record:

```text
consumer|bundle|key|environment_name|absolute_command|optional_guard_phrases
```

No shell expansions, quoting or command arguments are supported in the command
column. Use an executable reviewed script for commands needing fixed arguments.
Use simple names, no whitespace around fields, and no duplicate consumer rows:
the engine selects the first exact name match. Single exact bundle/key names use
letters, digits, underscore, dot and dash. A single-key `*` pattern resolves against
backend key names; it must match exactly one name, case-insensitively.

A multi-key row uses `+`-joined lists of equal length in the key and environment
columns, at least two entries. These names must be exact UPPER_SNAKE identifiers;
no wildcards, duplicates in environment names or empty entries. Multi-key bundle
names permit letters, digits, underscore and dash. Any failed/empty fetch prevents
the whole run. Reserved runtime-control variables (PATH, proxies, loader options,
TLS overrides, interpreter hooks and others) are refused for single and multi rows.
See `reserved_env` in the engine for the actual list.

## Consumer review checklist

1. Prefer a closed set of verbs, each mapped to constant methods, destinations and
   paths. Validate every argument; do not accept arbitrary URLs, hosts, curl options,
   commands, config files or caller-defined time windows. Review path normalization
   and encoded input against the specific service.
2. Register the consumer's absolute path, never a raw shell/interpreter or general
   HTTP client. Review program contents and all dependencies; basename checks do
   not certify a program. Minimize permissions on the underlying credential itself.
3. Read credentials only from their documented environment variables. Do not print
   them or place them in argv, temporary files, log records or exception messages.
   Never use `env -i TOKEN=value command`: that exposes the value as an argument.
4. Call trusted utilities by absolute path. Use `/usr/bin/curl -q --config -` with
   `-q` first and secrets in stdin configuration, never curl headers on argv. Reject
   credential control characters before building curl configuration. Fix HTTPS
   destinations, disable redirects, and bound runtime, response size and pagination.
5. Do not inherit runtime hooks intentionally. If a proxy or CA override is truly
   needed, set a reviewed constant inside the consumer, not a caller option. Run
   shell consumers through the engine's protected entry point, not by sourcing them
   in an untrusted shell.
6. Minimize response fields. Upstream JSON, errors and reflected inputs can contain
   credentials or sensitive account metadata. Do not claim an output is safe just
   because the request is read-only. Never run consumers with shell tracing enabled.
7. Test success, every refusal branch, failed/empty fetches, output leakage, fixed
   destination/method, injection characters and size/page/time limits using local
   stubs. The examples' offline suite is not a test of a new consumer's live API.
8. Run `bash tests/run-all.sh`, review the diff, then manually install the script
   and its row using the README layout. Keep directories 0700 and config files 0600.

## Shared GET-only HTTP engine

Copy `examples/consumers.d/github-read` and its matching HTTP config, then pin the
new config filename in the dispatcher. `API_BASE` is one fixed HTTPS origin,
`TOKEN_VAR` names the injected credential, `HEADER` adds trusted fixed headers,
and each `ALLOW` adds a shell-glob path allowlist. Config files are parsed, not
sourced. Use one API_BASE and TOKEN_VAR entry; duplicate assignments currently
replace earlier ones rather than being rejected. Headers and token bytes are
trusted inputs, not generally sanitized; use single-line tokens and reviewed
headers. Tighten the GitHub example's broad path set to your actual use case.

## Exchange examples

Bitget and MEXC show multi-key HMAC authentication while preserving fixed public
hosts, closed read verbs and credential-shape validation. Their `check` verbs do
not make HTTP requests; invoking them through the engine still fetches credentials.
Unknown permission codes fail the `keyinfo` allowlist. Review code meanings against
current service documentation; a read-only endpoint set is distinct from the
actual key's privileges. Output uses example schema identifiers, not a standardized
exchange format. Check each feed's completeness/error flags, not only process exit.
