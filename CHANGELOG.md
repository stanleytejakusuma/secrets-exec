# Changelog

All notable changes to this project will be documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

No changes yet.

## [0.1.0] - Unreleased

### Added

- Named, allowlisted consumer engine with environment-based credential injection,
  fail-closed fetches, single-key patterns, multi-key bundles, environment hardening
  and audit records for requests and outcomes.
- Parsed `backend.conf` for an installation-controlled SSH destination and key
  retrieval/listing templates; no key-store backend is bundled.
- Shared GET-only HTTP read engine with fixed destinations, configured path
  allowlists, traversal checks, request timeouts and a curl response-size limit.
- Example backend and consumer registries, GitHub reader, and read-only Bitget and
  MEXC consumers with multi-key HMAC authentication.
- Offline tests using local transport stubs for refusals, environment hardening,
  HTTP validation, backend parsing and single-key/multi-key execution.
- GitHub Actions checks for ShellCheck warnings and offline tests, plus installation,
  threat-model, consumer-review and AI-agent integration documentation.
