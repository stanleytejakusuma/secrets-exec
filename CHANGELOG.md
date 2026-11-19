# Changelog

All notable changes to this project will be documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- `scripts/quickstart.sh`: a two-minute local trial in one throwaway directory, with a
  fake token. No sudo, network or SSH; nothing written outside that directory.
- `host=local` in `backend.conf`: run the `get`/`list` helper on this machine without a
  shell, so the store can live under a separate OS user reached through one pinned sudo
  rule. Step-by-step setup in `docs/backends.md`.
- The reference key host also accepts a local request (`get BUNDLE KEY` /
  `list BUNDLE` after its options), checked by the same parser as SSH requests.
- `tests/container-same-machine.sh`: the same-machine setup end to end with real sudo in
  a Debian container (needs Docker; not part of CI).

### Changed

- **Possibly breaking:** backend template placeholders must be whole words, and no other
  word may contain a brace, so templates like `get=kv-get secret/{bundle}/{key}` are now
  refused. Commas are now allowed in templates (for `--allow a,b`).
- **Possibly breaking:** `host=local` is now the local backend, so an SSH alias named
  `local` can no longer be used as `host`.
- **Possibly breaking:** the reference key host refuses repeated options and option values
  containing whitespace. Without this, a sudo rule (which matches arguments as one
  space-joined string) could be satisfied by crafted arguments that select another
  allowlist. Found by an independent review of this release before it shipped.
- Local backend helpers start with a minimal environment (fixed `PATH`, the installation
  `HOME`, `LC_ALL=C`), and bundle/key names starting with `-` are refused for them.
- README rewritten around what the tool does for you, a quick start and a comparison
  with `op run`/Doppler/`aws-vault`. Backend details moved to `docs/backends.md`.
- Every row in `examples/consumers.example.conf` and `examples/backend.example.conf` is
  commented out, so nothing is authorized until you choose it.
- Exchange examples moved to `examples/advanced/` and are no longer installed by default.

## [0.1.1] - 2026-11-19

### Security

- Wildcard key rows now pass every local check (interpreter refusal, caller-URL
  refusal, bundle name) before the key host is asked for a key listing. Before, a
  refused call could still trigger one remote listing.
- The engine also removes `REQUESTS_CA_BUNDLE`, every `CURL_*` and every `SSL_CERT_*`
  variable from the programs it starts, so a caller cannot swap in its own TLS
  trust store or curl settings.
- `http-get-engine.sh` and the example consumers start with `#!/bin/bash -p`, so they
  ignore a caller's `SHELLOPTS` and exported functions when run directly.

### Changed

- Installer backup directories use UTC timestamps.

## [0.1.0] - 2026-11-18

### Added

- Named, allowlisted consumer engine with environment-based credential injection,
  fail-closed fetches, single-key patterns, multi-key bundles, environment hardening
  and audit records for requests and outcomes.
- Parsed `backend.conf` for an installation-controlled SSH destination and key
  retrieval/listing templates.
- Reference SSH forced-command key host (`examples/keyhost/`) serving allowlisted
  bundles from a private file store, and a dry-run-first `scripts/install.sh`.
- Shared GET-only HTTP read engine with fixed destinations, configured path
  allowlists, traversal checks, request timeouts and a curl response-size limit.
- Example backend and consumer registries, GitHub reader, and read-only Bitget and
  MEXC consumers with multi-key HMAC authentication.
- Offline tests using local transport stubs for refusals, environment hardening,
  HTTP validation, backend parsing and single-key/multi-key execution.
- Opt-in structured metadata (`SECRETS_EXEC_METADATA=1`): a first stdout line naming
  the selected bundle and key names (never values), per-call IDs in the audit log,
  serialized audit writes, and a stdlib reference parser. Early: not yet field-proven.
- GitHub Actions checks for ShellCheck warnings and offline tests, plus installation,
  threat-model, consumer-review and AI-agent integration documentation.
