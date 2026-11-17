# Security policy

## Reporting a vulnerability

Please do not publish credential values, real registry rows, account identifiers or
private host details in an issue. Use the repository's **Security → Report a
vulnerability** private reporting feature if enabled. Otherwise ask for a private
reporting channel in a minimal public issue without exploit details. No dedicated
security email address, response-time SLA or bounty program is currently provided.

Include the affected revision, operating system/tool versions, a minimal offline
reproduction with fictional credentials, expected/observed behavior and whether the
attack requires editing installed files or same-user process inspection. Do not
probe another person's key store or make live financial/API writes to demonstrate
an issue. Review [the threat model](docs/threat-model.md) before testing.

## Scope

In scope: credential disclosure or caller-controlled destinations through the
engine or bundled examples without modifying installed policy; bypasses of
refusal, validation or known environment-scrubbing controls; unsafe documentation
that contradicts implemented behavior. Test fixtures use synthetic values.

Same-user file modification, native code loaded before engine startup, hostile
registered programs, compromised remote key stores and upstream service bugs are
not containment guarantees of this project. Reports that clarify or reduce these
risks are still useful, but should not assume a sandbox exists.

There are no supported stable release branches yet. Review the current source and
track security fixes before deploying. Offline test success is not live-service
qualification or a claim that arbitrary consumers are safe.
