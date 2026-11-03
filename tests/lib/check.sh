# Shared assertions for the script suites. Source it, then:
#   check "<name>" <command...>   one PASS/FAIL line; on FAIL dumps $out, $outputs, $summary, $github_env
#   has "$text" "<needle>"        fixed-string containment
#   report <suite>                prints "<suite>: N/M passed" and exits non-zero when any check failed
failures=0
total=0

check() {
  local name=$1
  shift
  total=$((total + 1))
  if "$@"; then
    echo "PASS $name"
    return
  fi
  echo "FAIL $name"
  local var
  for var in out outputs summary github_env; do
    [ -n "${!var:-}" ] && printf '%s\n' "${!var}" | sed 's/^/    | /'
  done
  failures=$((failures + 1))
}

has() { grep -qF -- "$2" <<< "$1"; }

report() {
  echo "$1: $((total - failures))/$total passed"
  [ "$failures" -eq 0 ]
}
