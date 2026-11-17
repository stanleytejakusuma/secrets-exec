#!/usr/bin/env bash
# All transports in these tests are local stubs; no backend credentials are needed.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Do not let a caller accidentally substitute a different source tree's engine.
unset ENGINE_FILE
for test in test_refusals.sh test_environment.sh test_http_engine.sh test_backend.sh test_multikey.sh test_keyhost.sh test_install.sh; do
  printf '\n== %s ==\n' "$test"
  bash "$HERE/$test"
done
printf '\nAll offline suites passed.\n'
