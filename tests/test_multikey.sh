#!/usr/bin/env bash
# Direct behavioral tests with fictional single-key, glob and multi-key registry rows.
# Only sandbox copies run. Their ssh calls are replaced by a local fixture reader.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
N="$SB/home"; mkdir -p "$N/bin" "$N/.config/secrets-exec" "$SB/fx/single" "$SB/fx/multi" "$SB/fx/ambiguous"
ENGINE="$N/bin/secrets-exec"
CONFN="$N/.config/secrets-exec/consumers.conf"; AUD="$N/.config/secrets-exec/audit.log"
cp "$HERE/bin/secrets-exec" "$ENGINE"
sed -i -E "s#(^|[^/[:alnum:]])ssh( -n)? -o BatchMode=yes#\1$SB/fakessh\2 -o BatchMode=yes#" "$ENGINE"
grep -q "$SB/fakessh -n -o BatchMode=yes" "$ENGINE" && ! grep -qE '(^|[[:space:]])ssh( -n)? -o BatchMode=yes' "$ENGINE" \
  || { echo 'FAIL sandbox transport substitution'; exit 1; }
chmod 0700 "$ENGINE"
printf '%s\n' host=fixture-keyhost 'get=kv-get {bundle} {key}' 'list=kv-list {bundle}' > "$N/.config/secrets-exec/backend.conf"
cat > "$SB/fakessh" <<'EOF'
#!/bin/bash -p
cmd="${@: -1}"; d="$(dirname "$0")"
printf '%s\n' "$cmd" >> "$d/ssh-calls.log"
# Like ssh, consume stdin unless the engine explicitly requests -n.
case " $* " in *" -n "*) ;; *) cat >/dev/null ;; esac
list_rx="^kv-list '([A-Za-z0-9_.-]+)'$"
get_rx="^kv-get '([A-Za-z0-9_.-]+)' '([A-Za-z0-9_.-]+)'$"
if [[ $cmd =~ $list_rx ]]; then
  b="${BASH_REMATCH[1]}"
  echo "keys in $b:"
  shopt -s nullglob
  for f in "$d/fx/$b"/*; do
    n="$(basename "$f")"; case "$n" in *.fail) ;; *) echo "  $n" ;; esac
  done
  [ ! -f "$d/fx/$b/.list-fail" ] || exit 255
elif [[ $cmd =~ $get_rx ]]; then
  f="$d/fx/${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
  [ ! -e "$f.fail" ] || exit 255
  [ ! -f "$f" ] || cat "$f"
else
  exit 1
fi
EOF
cat > "$N/probe" <<'EOF'
#!/bin/bash
d="$(dirname "$0")"; : > "$d/ran"; cat > "$d/probe.stdin"
for v in ONE_VAR E_A E_B E_C; do
  if [ -n "${!v+x}" ]; then printf '%s=%s\n' "$v" "${!v}"; fi
done > "$d/probe.out"
printf 'argv=%s\n' "$*" >> "$d/probe.out"
exit 7
EOF
chmod 0700 "$SB/fakessh" "$N/probe"
printf 'v-one' > "$SB/fx/single/ONE"
printf 'alpha value' > "$SB/fx/multi/K_A"
printf 'beta' > "$SB/fx/multi/K_B"
printf 'gamma-3' > "$SB/fx/multi/K_C"
: > "$SB/fx/multi/K_EMPTY"; : > "$SB/fx/multi/K_DOWN.fail"
printf 'va' > "$SB/fx/ambiguous/OA"; printf 'vb' > "$SB/fx/ambiguous/OB"
pass=0; fail=0
ok() { pass=$((pass+1)); printf 'PASS %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got [$2] want [$3])"; fi; }
mk() { printf '%s\n' "$1" > "$CONFN"; rm -f "$N/ran" "$N/probe.out" "$SB/ssh-calls.log"; : > "$AUD"; }
run() { OUT="$(env -u BASH_ENV "$ENGINE" "$@" 2>&1 < "${STDIN_FILE:-/dev/null}")"; RC=$?; }
calls() { [ -f "$SB/ssh-calls.log" ] && wc -l < "$SB/ssh-calls.log" | tr -d ' ' || echo 0; }
ran() { [ -f "$N/ran" ] && echo yes || echo no; }

mk "single|single|ONE|ONE_VAR|$N/probe|"
run --list; check "list contains fixture only" "$(grep -c 'single / ONE -> ONE_VAR' <<<"$OUT")" 1
check "list does not fetch" "$(calls)" 0
run not-a-consumer; check "unknown consumer refused" "$RC" 2
check "unknown consumer does not fetch" "$(calls)" 0
run single a1 b2
check "single: child exit status" "$RC" 7
check "single: injected value" "$(grep ONE_VAR "$N/probe.out")" ONE_VAR=v-one
check "single: arguments preserved" "$(grep '^argv=' "$N/probe.out")" 'argv=a1 b2'
check "single: one fetch" "$(calls)" 1
check "single: audit does not contain value" "$(grep -c v-one "$AUD")" 0
check "single: both audit records include invocation name" "$(grep -c 'outcome=\(allowed\|exit\).* via=secrets-exec args=' "$AUD")" 2

for row in 'sglob|single|O*|ONE_VAR' 'amb|ambiguous|O*|ONE_VAR' 'none|ambiguous|Z*|ONE_VAR'; do
  mk "$row|$N/probe|"; c="${row%%|*}"; run "$c"
  case "$c" in
    sglob)
      check "glob resolves one name" "$RC" 7
      check "glob gets matching value" "$(grep ONE_VAR "$N/probe.out")" ONE_VAR=v-one
      check "glob lists then fetches" "$(calls)" 2 ;;
    *)
      check "glob $c refused" "$RC" 2
      check "glob $c never fetches a value" "$(calls)" 1
      check "glob $c does not run consumer" "$(ran)" no ;;
  esac
done
# A nonzero listing status must fail even if stdout contains a valid matching name.
: > "$SB/fx/single/.list-fail"
mk "sglob|single|O*|ONE_VAR|$N/probe|"; run sglob
check "failed listing with partial output refused" "$RC" 2
check "failed listing does not fetch value" "$(calls)" 1
check "failed listing does not run consumer" "$(ran)" no
rm -f "$SB/fx/single/.list-fail"

mk "multi|multi|K_A+K_B+K_C|E_A+E_B+E_C|$N/probe|"; run multi x1
check "multi happy: child rc passed through" "$RC" 7
check "multi happy: all values in order" "$(grep -E '^E_' "$N/probe.out" | tr '\n' ';')" 'E_A=alpha value;E_B=beta;E_C=gamma-3;'
check "multi happy: one fetch per key" "$(calls)" 3
check "multi happy: audit names every key" "$(grep -c 'outcome=allowed .*key=K_A+K_B+K_C' "$AUD")" 1
check "multi happy: audit exit line" "$(grep -c 'outcome=exit .*rc=7' "$AUD")" 1
check "multi happy: no value in audit" "$(grep -cE 'alpha value|beta|gamma-3' "$AUD")" 0
mk "multi|multi|K_A+K_EMPTY+K_C|E_A+E_B+E_C|$N/probe|"; run multi
check "empty value: refused" "$RC" 2; check "empty value: child not run" "$(ran)" no
check "empty value: stops at failing key" "$(calls)" 2
mk "multi|multi|K_A+K_DOWN+K_C|E_A+E_B+E_C|$N/probe|"; run multi
check "fetch failure: refused" "$RC" 2; check "fetch failure: child not run" "$(ran)" no
check "fetch failure: stops at failing key" "$(calls)" 2
refused_before_fetch() {
  mk "$2"; run multi
  check "$1: refused" "$RC" 2; check "$1: no fetch" "$(calls)" 0; check "$1: child not run" "$(ran)" no
}
refused_before_fetch "count mismatch" "multi|multi|K_A+K_B+K_C|E_A+E_B|$N/probe|"
refused_before_fetch "wildcard key" "multi|multi|K_*+K_B|E_A+E_B|$N/probe|"
refused_before_fetch "lowercase key" "multi|multi|k_a+K_B|E_A+E_B|$N/probe|"
refused_before_fetch "quote in key" "multi|multi|K_A+K'B|E_A+E_B|$N/probe|"
refused_before_fetch "trailing plus" "multi|multi|K_A+K_B+|E_A+E_B+|$N/probe|"
refused_before_fetch "empty entry" "multi|multi|K_A++K_B|E_A++E_B|$N/probe|"
refused_before_fetch "duplicate envvar" "multi|multi|K_A+K_B|E_A+E_A|$N/probe|"
refused_before_fetch "bad bundle" "multi|bad'bundle|K_A+K_B|E_A+E_B|$N/probe|"
refused_before_fetch "interpreter command" "multi|multi|K_A+K_B|E_A+E_B|/usr/bin/python3|"
for ev in PATH HOME IFS LD_PRELOAD HTTPS_PROXY CURL_HOME SSLKEYLOGFILE OPENSSL_CONF GCONV_PATH GLIBC_TUNABLES LOCPATH NLSPATH XDG_CONFIG_HOME TMPDIR GIT_SSH_COMMAND GODEBUG GOFLAGS PERL5DB PYTHONWARNINGS NODE_EXTRA_CA_CERTS RUBYLIB JAVA_HOME; do
  refused_before_fetch "multi reserved $ev" "multi|multi|K_A+K_B|E_A+$ev|$N/probe|"
done
mk "multi|multi|K_A+K_B|E_A+E_B|$N/probe|"; run multi https://example.invalid
check "multi URL argument refused" "$RC" 2; check "multi URL argument no fetch" "$(calls)" 0
check "multi URL argument child not run" "$(ran)" no
printf 'hello-stdin' > "$SB/stdin.txt"
mk "multi|multi|K_A+K_B+K_C|E_A+E_B+E_C|$N/probe|"; STDIN_FILE="$SB/stdin.txt" run multi
check "multi: stdin preserved with ssh -n" "$(cat "$N/probe.stdin" 2>/dev/null)" hello-stdin
mk "single|single|ONE|ONE_VAR|$N/probe|"; STDIN_FILE="$SB/stdin.txt" run single
check "single: stdin preserved with ssh -n" "$(cat "$N/probe.stdin" 2>/dev/null)" hello-stdin
for ev in LD_PRELOAD https_proxy PATH XDG_CONFIG_HOME; do
  mk "single|single|ONE|$ev|$N/probe|"; run single
  check "single reserved $ev: refused" "$RC" 2
  check "single reserved $ev: no fetch" "$(calls)" 0
  check "single reserved $ev: child not run" "$(ran)" no
done
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
