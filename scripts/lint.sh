#!/bin/sh
# Lints every shell script and every GitHub Actions workflow in the repository.
#
# Shell scripts are found by searching the whole tree (except .git): any file
# named *.sh, or whose first line is a #! line naming sh, dash or bash. They are
# checked by ShellCheck in POSIX mode (-s sh). Workflows are found by actionlint
# itself under .github/workflows, with its settings in .github/actionlint.yaml.
#
# Both tools run in Docker, pinned by image digest.
#
# Usage: sh scripts/lint.sh
# Exit codes: 0 both linters passed, 1 a linter reported a problem, failed to
# run, or no shell scripts were found.

set -u

SHELLCHECK_IMAGE=koalaman/shellcheck@sha256:61862eba1fcf09a484ebcc6feea46f1782532571a34ed51fedf90dd25f925a8d # v0.11.0
ACTIONLINT_IMAGE=rhysd/actionlint@sha256:b1934ee5f1c509618f2508e6eb47ee0d3520686341fec936f3b79331f9315667 # 1.7.12

root=$(cd "$(dirname "$0")/.." && pwd) || exit 1
cd "$root" || exit 1

files=$(mktemp "${TMPDIR:-/tmp}/lint.XXXXXX") || exit 1
trap 'rm -f "$files"' EXIT
find . -path ./.git -prune -o -type f -print | sort >"$files"

set --
while IFS= read -r f; do
  case $f in
    *.sh) set -- "$@" "$f"; continue ;;
  esac
  first=$(head -n 1 "$f")
  case $first in
    '#!'*/sh | '#!'*/sh' '* | '#!'*' sh' | '#!'*' sh '* | \
    '#!'*/dash | '#!'*/dash' '* | '#!'*' dash' | '#!'*' dash '* | \
    '#!'*/bash | '#!'*/bash' '* | '#!'*' bash' | '#!'*' bash '*)
      set -- "$@" "$f"
      ;;
  esac
done <"$files"

status=0

if [ $# -eq 0 ]; then
  echo "ShellCheck: no shell scripts found" >&2
  status=1
else
  echo "ShellCheck ($#):"
  printf '  %s\n' "$@"
  docker run --rm -v "$root:/repo:ro" -w /repo "$SHELLCHECK_IMAGE" -s sh "$@" || status=1
fi

echo "actionlint:"
docker run --rm -v "$root:/repo:ro" -w /repo "$ACTIONLINT_IMAGE" -no-color -verbose || status=1

exit "$status"
