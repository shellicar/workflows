#!/bin/sh
# Runs verify-commit-signatures.sh against every case in tests/cases, with a
# stub gh that answers from the case's response files, and compares the exit
# code, the number of GitHub calls, the retry delays, each commit's verdict and
# failed rule, and any workflow command lines (::error ...) with the case's
# expected file. No network is used.
#
# Usage: run-logic-tests.sh [CASE...]
#   SH  the shell that runs the script under test (default: sh)
#
# Exit codes: 0 every case matched, 1 at least one did not, 64 bad usage.

set -u

here=$(cd "$(dirname "$0")" && pwd)
script="$here/../verify-commit-signatures.sh"
shell=${SH:-sh}

if [ $# -gt 0 ]; then
  cases=""
  for c in "$@"; do
    [ -d "$here/cases/$c" ] || { printf 'error: no case named %s\n' "$c" >&2; exit 64; }
    cases="$cases $here/cases/$c"
  done
else
  cases=$(ls -d "$here"/cases/*/)
fi

passed=0
failed=0
for dir in $cases; do
  dir=${dir%/}
  name=${dir##*/}
  state=$(mktemp -d "${TMPDIR:-/tmp}/logic-test.XXXXXX")

  if [ -f "$dir/args" ]; then
    # shellcheck disable=SC2046
    set -- $(cat "$dir/args")
  else
    set --
  fi
  # The script sees GITHUB_ACTIONS only when the case sets it, so a case gives
  # the same result locally and in CI.
  github_actions=""
  if [ -f "$dir/github-actions" ]; then
    github_actions=$(cat "$dir/github-actions")
  fi
  PATH="$here/stub:$PATH" STUB_CASE="$dir" STUB_STATE="$state" GITHUB_ACTIONS="$github_actions" \
    "$shell" "$script" "$@" >"$state/stdout" 2>"$state/stderr"
  rc=$?

  {
    echo "exit $rc"
    echo "calls $(cat "$state/count" 2>/dev/null || echo 0)"
    if grep -q '^sleeps ' "$dir/expected"; then
      touch "$state/sleeps"
      echo "sleeps $(tr '\n' ' ' <"$state/sleeps" | sed 's/ $//')"
    fi
    sed -n \
      -e 's/^\([0-9a-f]\{7\}\) PASS  .*$/\1 PASS/p' \
      -e 's/^\([0-9a-f]\{7\}\) FAIL  .*  rule=\([a-z-]*\): .*$/\1 FAIL \2/p' \
      -e '/^::/p' \
      "$state/stdout"
  } >"$state/actual"

  if diff "$dir/expected" "$state/actual" >"$state/diff"; then
    passed=$((passed + 1))
    printf 'ok    %s\n' "$name"
  else
    failed=$((failed + 1))
    printf 'FAIL  %s\n' "$name"
    sed 's/^/      diff: /' "$state/diff"
  fi
  sed 's/^/      | /' "$state/stdout" "$state/stderr"
  rm -rf "$state"
done

printf '\n%s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
