# Structured broker results

Wrappers can request one first-line metadata header without changing the registered
consumer, its arguments or its output. This is an opt-in transport convention, not
an authorization API or a new consumer output schema.

## Request and framing

Set `SECRETS_EXEC_METADATA=1` in the environment of the **executable** broker. Values
other than exactly `1` do not enable framing. Optionally set `SECRETS_EXEC_CALL_ID`
to an identifier matching `[A-Za-z0-9._-]{1,96}`. A wrapper should generate a fresh
identifier per invocation, for example with Python's `uuid.uuid4().hex`.

When no identifier is supplied, the broker reads a fresh opaque UUID from Linux's
`/proc/sys/kernel/random/uuid`. An explicitly empty, oversized or malformed identifier
is refused without echoing it; the refusal uses a generated identifier instead.
Identifiers are correlation labels only: they never choose policy, paths or keys.

With framing enabled, the first stdout line is a literal ASCII prefix, one JSON
object and a newline:

```text
SECRETS_EXEC_META_V1 {"schema":"secrets-exec/metadata/1","call_id":"wrapper-123","consumer":"demo","credential_source":{"consumer":"demo","bundle":"example","key_names":["TOKEN_A"]}}
```

The object has exactly these fields:

| Field | Meaning |
| --- | --- |
| `schema` | Exactly `secrets-exec/metadata/1`. |
| `call_id` | Validated caller identifier or broker-generated identifier. |
| `consumer` | Requested consumer name; `list` for `--list`/`-l`, `none` for missing arguments. Invalid consumer names can appear here on refusals, JSON-escaped. |
| `credential_source` | `null` before a permitted selection is established, otherwise an object with exactly `consumer`, `bundle` and `key_names`. |

`key_names` contains the **resolved names**, never credential values: the exact key,
the one unambiguous wildcard match, or every key in a multi-key row in registry order.
The header is emitted after policy, destination, name and backend validation, but
**before fetching any value**. Wildcard resolution may first list key names. Listing
consumers and early policy/configuration refusals have a null source.

A later fetch failure, empty value, failed audit write or consumer failure does not
replace the header: it still names the selection. A header therefore proves neither
fetch success, injection, consumer execution nor successful authentication. Check
process status separately; exit code 2 alone does not distinguish broker refusals
from a consumer that itself exits 2. Catastrophic startup/dependency failures can
prevent any valid header; wrappers must treat missing/malformed framing as an error.
The broker does not fetch values if it cannot write its requested header.

All bytes after the first newline are the original CLI/consumer stdout. Stderr and
exit status are unchanged and remain separate channels. Without the flag, ordinary
CLI stdout is unchanged, including `--list` output. Internal controls and other
`SECRETS_EXEC_*` variables are cleared before child programs run; nested calls do
not inherit the flag or identifier. Credential destinations using those names,
`call_id` or the broker's metadata implementation names are refused.

## Parsing in a wrapper

1. Execute the installed file directly, not `bash file` (which bypasses `-p`). Set
   controls in a child environment rather than mutating the wrapper's global one.
2. Capture stdout as bytes, stderr separately and the process return code. Apply
   your own output limits, timeout and process-lifecycle policy.
3. Read only the first line as the metadata frame. Require the exact prefix, schema,
   field types and expected identifier. Do not search later output for a header.
4. Strip exactly that first line; preserve every remaining byte. Parse consumer JSON
   separately only if its own contract calls for JSON. Consumer output can be binary.
5. If the header is missing, truncated or malformed, report a protocol error, not
   fabricated provenance. Do not reflect raw malformed frames/stderr into a sensitive
   transcript without a separate, reviewed output policy.

[`examples/wrappers/parse_result.py`](../examples/wrappers/parse_result.py) is a
standard-library reference parser. It returns `(metadata, body_bytes)` and optionally
checks `expected_call_id`. It rejects duplicate JSON fields and never invokes a
consumer. Its command-line mode strips a frame from already-captured stdin; it is
not a timeout, streaming-limit or redaction implementation. Run its small offline
test with `python3 -B tests/test_result_parser.py`.

## Audit and dependencies

Every refused/allowed/exit audit event includes `call_id=<id>`. Existing `%q` escaping
is retained, and `via=` remains immediately before `args=`. Allowed and exit events
share an identifier; list and usage errors do not claim an audit event was written.
Arguments are still logged: **never put credential values in arguments or call IDs**.

Audit appends hold an exclusive advisory lock across the complete record. Linux
util-linux `/usr/bin/flock` is preferred. If that executable is absent, the broker
uses `/usr/bin/python3 -I -S -B` with standard-library `fcntl.flock` on the same open
file descriptor. Lock failure does not fall back to unlocked writes: an allow-event
failure prevents the consumer from running; refusal/exit auditing stays best-effort.
Use a local filesystem with working advisory locks; no rotation is bundled.

Opt-in JSON framing requires `/usr/bin/python3` and its standard library. Isolated
mode, no site initialization and no bytecode writes avoid caller import hooks. Linux
kernel UUID support is required for generated call IDs. No additional Python package
or network service is needed.

## Trust limits

**The header is unauthenticated same-user data.** A caller who can edit the engine,
registry, consumers or captured output can forge it. Matching call IDs detect mix-ups,
not same-user forgery. Do not derive authorization or a proof of secret use from this
metadata. Names and audit correlation can themselves be sensitive; expose them only
to appropriate callers. Consumers remain trusted code and can print secrets; this
protocol adds neither universal redaction nor a separate security principal. See the
[threat model](threat-model.md).
