#!/bin/bash -p
# Offline, home-only installer. No environment-controlled source or test bypass.
set -euo pipefail
umask 077
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH LC_ALL=C

die() { printf 'install: %s\n' "$1" >&2; exit 1; }
# id also makes the root refusal independently testable without sudo/user namespaces.
[[ "$(id -u)" != 0 ]] || die 'refusing to run as root'
apply=0
case "${1:-}" in
  '') (( $# == 0 )) || die 'usage: install.sh [--apply]' ;;
  --apply) (( $# == 1 )) || die 'usage: install.sh [--apply]'; apply=1 ;;
  *) die 'usage: install.sh [--apply]' ;;
esac
[[ "${HOME:-}" == /* && -d "$HOME" ]] || die 'HOME must be an existing absolute directory'
HOME="${HOME%/}"
[[ -n "$HOME" ]] || die 'HOME must not be /'
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONF="$HOME/.config/secrets-exec"
backup=''

# Do not traverse symlinks, even in existing ancestors, or replace special files.
safe_path() {
  local path="$1" current='' part
  local -a parts
  [[ "$path" != *$'\n'* ]] || die 'newline destination refused'
  IFS=/ read -r -a parts <<< "$path"
  for part in "${parts[@]}"; do
    [[ -n "$part" ]] || continue
    [[ "$part" != . && "$part" != .. ]] || die 'dot path component refused'
    current+="/$part"
    [[ ! -L "$current" ]] || die 'symlink destination refused'
  done
}

printf 'Running offline tests before installation.\n'
# The test gate must not source caller BASH_ENV or import shell functions/options.
env -i HOME="$HOME" PATH="$PATH" LC_ALL=C /bin/bash -p "$REPO/tests/run-all.sh" \
  || die 'offline tests failed; nothing installed'
if (( ! apply )); then printf '\nDRY RUN: no installation changes (use --apply).\n'; fi

directory() {
  local path="$1" mode="$2"
  safe_path "$path"
  if [[ -e "$path" ]]; then
    [[ -d "$path" ]] || die 'directory destination is not a directory'
    [[ "$(stat -c %a -- "$path")" != "$mode" ]] || return 0
    printf 'Set directory mode %s: %s\n' "$mode" "$path"
    if (( apply )); then chmod "$mode" -- "$path"; fi
  else
    printf 'Create directory %s: %s\n' "$mode" "$path"
    if (( apply )); then install -d -m "$mode" -- "$path"; fi
  fi
}

file() {
  local source="$1" relative="$2" mode="$3" preserve="${4:-0}" target="$HOME/$2"
  safe_path "$target"
  if [[ -e "$target" ]]; then
    [[ -f "$target" ]] || die 'file destination is not regular'
    if (( preserve )); then
      printf 'Keep existing configuration: %s\n' "$target"
      return 0
    fi
    if cmp -s -- "$source" "$target" && [[ "$(stat -c %a -- "$target")" == "$mode" ]]; then
      printf 'Unchanged: %s\n' "$target"
      return 0
    fi
    printf 'Replace file (mode %s): %s\n' "$mode" "$target"
    if (( ! apply )); then
      # diff returns 1 for differences, which is expected, but real errors refuse.
      local rc=0
      diff -u -- "$target" "$source" || rc=$?
      (( rc <= 1 )) || die 'cannot diff existing file'
    else
      if [[ -z "$backup" ]]; then
        backup="$CONF/backup-$(TZ=Asia/Jakarta date +%Y%m%dT%H%M%S%N%z)"
        install -d -m 0700 -- "$backup"
      fi
      install -d -m 0700 -- "$backup/$(dirname "$relative")"
      cp -p -- "$target" "$backup/$relative"
      printf 'Backup: %s\n' "$backup/$relative"
    fi
  else
    printf 'Create file %s: %s\n' "$mode" "$target"
    if (( preserve )); then printf 'Edit before use: %s\n' "$target"; fi
  fi
  if (( apply )); then install -m "$mode" -- "$source" "$target"; fi
}

# Preserve an existing bin/.config mode; tighten only this tool's directories.
safe_path "$HOME/bin"
if [[ ! -e "$HOME/bin" ]]; then directory "$HOME/bin" 700; fi
safe_path "$HOME/.config"
if [[ ! -e "$HOME/.config" ]]; then directory "$HOME/.config" 700; fi
for path in "$CONF" "$CONF/consumers.d" "$CONF/http-consumers"; do directory "$path" 700; done
file "$REPO/bin/secrets-exec" bin/secrets-exec 755
file "$REPO/http-get-engine.sh" .config/secrets-exec/http-get-engine.sh 755
for source in "$REPO/examples/consumers.d/"*; do
  file "$source" ".config/secrets-exec/consumers.d/${source##*/}" 755
done
for source in "$REPO/examples/http-consumers/"*; do
  file "$source" ".config/secrets-exec/http-consumers/${source##*/}" 600
done
file "$REPO/examples/consumers.example.conf" .config/secrets-exec/consumers.conf 600 1
file "$REPO/examples/backend.example.conf" .config/secrets-exec/backend.conf 600 1
printf '\nReview/edit consumers.conf and backend.conf before using credentials.\n'
