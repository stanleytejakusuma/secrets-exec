# Roadmap

These are possible directions, not implemented features or release promises.

1. **A real privilege boundary.** Run a narrow broker as a different OS principal,
   ideally beside the key store. Policy must not be writable by callers. Limit the
   agent-facing interface to named verbs; unrestricted SSH defeats containment.
2. **Smaller consumer permissions.** Define fixed method/path/response projections
   per verb. Extend leak and refusal tests per consumer, including dependency hooks,
   service-specific URL decoding, reflected errors and strict streaming limits.
3. **Operational bounds.** Add an overall backend-call deadline, audit rotation and
   clear behavior for full disks and interrupted consumers. Improve parser validation
   for duplicate HTTP settings, header bytes and generic token shapes.
4. **Credential lifetime and revocation.** Explore short-lived leases and a narrow
   revocation interface only after backend support and trust boundaries are defined.
5. **Implementation portability.** Consider a small compiled launcher if measured
   installation, loader or portability constraints justify replacing shell code.

Current guarantees remain those in [the threat model](threat-model.md). A new
language, extra policy file or larger test suite alone does not create containment.
