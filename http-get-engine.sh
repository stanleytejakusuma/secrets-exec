#!/bin/bash
# http-get-engine.sh — the reviewed logic behind every GET-only header-auth consumer.
#
#   http-get-engine.sh <config-file> <path>
#
# WHY THIS EXISTS
# ----------------
# Header-auth consumers often differ only in host, fixed headers and allowed paths.
# Sharing the parser and validation avoids duplicating curl-config-injection checks.
#
# This is that logic, written ONCE, parameterized by a config file. Adding a target group
# now means writing a config file (below) plus a two-line dispatcher that names it — no new
# bash to get right, and nothing new to adversarially review beyond the config's own values
# (host, headers, path prefixes), which are data, not code.
#
# THE CONFIG FILE
# ----------------
#   API_BASE=https://api.example.com      (exactly one, must be https://)
#   TOKEN_VAR=SOME_ENV_VAR                (exactly one; secrets-exec already exported it)
#   HEADER=Accept: application/json        (zero or more, verbatim extra headers)
#   ALLOW=/things/*                        (one or more; the read allowlist, glob-style)
#
# It is parsed line-by-line, NOT sourced and NOT eval'd — a typo in a config file can only
# make a path fail to match, it can never execute code. That is deliberate: the promise of
# "no new code review" only holds if the config genuinely cannot become a script.
#
# See docs/adding-a-consumer.md for the consumer review checklist. Configuration is
# trusted installation data; it must be reviewed along with the dispatcher.
#
# NOTE ON WHAT THIS IS NOT: leak-reduction, not containment. It runs as the same OS user as
# the agent, which can edit this file, the configs, and the wrapper.
set -euo pipefail

self_usage() { echo "http-get-engine: usage: http-get-engine.sh <config-file> <path>" >&2; exit 2; }
[ "$#" -eq 2 ] || self_usage
config="$1"; path="$2"
[ -f "$config" ] || { echo "http-get-engine: no such config file: $config" >&2; exit 2; }

API_BASE=""
TOKEN_VAR=""
HEADERS=()
ALLOW=()

# Line-oriented parse. Blank/`#` lines ignored. Anything else must be KEY=VALUE with a
# recognised KEY, or the config is rejected outright — a config that partially matches
# what this engine understands is more dangerous silently accepted than loudly refused.
line_no=0
while IFS= read -r line || [ -n "$line" ]; do
  line_no=$((line_no + 1))
  case "$line" in
    ''|'#'*) continue ;;
    API_BASE=*) API_BASE="${line#API_BASE=}" ;;
    TOKEN_VAR=*) TOKEN_VAR="${line#TOKEN_VAR=}" ;;
    HEADER=*) HEADERS+=("${line#HEADER=}") ;;
    ALLOW=*) ALLOW+=("${line#ALLOW=}") ;;
    *) echo "http-get-engine: $config:$line_no: unrecognised line '$line'" >&2; exit 2 ;;
  esac
done < "$config"

case "$API_BASE" in
  https://*) ;;
  *) echo "http-get-engine: $config: API_BASE must start with https:// (got '$API_BASE')" >&2; exit 2 ;;
esac
[ -n "$TOKEN_VAR" ] || { echo "http-get-engine: $config: TOKEN_VAR is required" >&2; exit 2; }
[ "${#ALLOW[@]}" -gt 0 ] || { echo "http-get-engine: $config: at least one ALLOW= entry is required" >&2; exit 2; }

token="${!TOKEN_VAR:-}"
[ -n "$token" ] || { echo "http-get-engine: \$$TOKEN_VAR is not set — this must be run via secrets-exec" >&2; exit 2; }

CURL=/usr/bin/curl
refuse() { echo "http-get-engine: refusing: $*" >&2; exit 2; }

case "$path" in
  *://*) refuse "'$path' — supply a PATH, not a URL. The host is fixed by $config." ;;
  *@*)   refuse "'$path' contains '@', which curl parses as userinfo and would send the credential to a different host." ;;
  /*) ;;
  *)     refuse "path must start with '/' (got '$path')" ;;
esac
case "$path" in
  *[[:space:]]*) refuse "'$path' contains whitespace" ;;
esac
# Regex in a variable: bash 3.2 (macOS) cannot parse `&` inside an unquoted `[[ =~ ]]`.
# Ranges like [A-Za-z] follow the locale (some UTF-8 locales also match 'é'): check in C.
LC_ALL=C
path_re='^/[A-Za-z0-9._~/?=&%+-]*$'
[[ "$path" =~ $path_re ]] \
  || refuse "'$path' contains characters outside the permitted set"
# curl removes dot segments before sending, so '/repos/../user/emails' would pass a '/repos/*'
# allowlist and fetch '/user/emails'. Refuse dot segments and encoded separators in the path
# (the query after '?' is not normalised and may legitimately carry %2F).
path_only="${path%%\?*}"
case "/$path_only/" in
  */./*|*/../*) refuse "'$path' contains a '.' or '..' path segment" ;;
esac
case "$(printf '%s' "$path_only" | tr '[:upper:]' '[:lower:]')" in
  *%2e*|*%2f*|*%5c*) refuse "'$path' contains an encoded '.', '/' or '\\' in the path" ;;
esac

allowed=0
for pat in "${ALLOW[@]}"; do
  # Expand the trusted allowlist entry as a glob, not a literal string.
  # shellcheck disable=SC2254
  case "$path" in
    $pat) allowed=1; break ;;
  esac
done
[ "$allowed" -eq 1 ] || refuse "'$path' is not in the read allowlist. Allowed prefixes: ${ALLOW[*]}"

esc() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; printf '%s' "$s"; }

{
  printf 'silent\nshow-error\n'
  printf 'proto = "=https"\n'
  printf 'request = "GET"\n'
  printf 'connect-timeout = 10\nmax-time = 60\nmax-filesize = 10000000\n'
  printf 'header = "Authorization: Bearer %s"\n' "$(esc "$token")"
  # bash 3.2 (macOS default) treats "${arr[@]}" as an unbound-variable error under `set -u`
  # when arr is empty, even though the array itself was declared. Guard the count first —
  # an empty array needs this explicit guard for portability.
  if [ "${#HEADERS[@]}" -gt 0 ]; then
    for h in "${HEADERS[@]}"; do
      printf 'header = "%s"\n' "$(esc "$h")"
    done
  fi
  printf 'url = "%s"\n' "$(esc "${API_BASE}${path}")"
} | exec "$CURL" -q --config -
