#!/bin/sh
# Checks every commit in a pull request. A commit passes only when it is signed,
# GitHub reports the signature as VALID, and the signing key belongs to the
# committer's GitHub account (or the commit was signed by GitHub itself).
#
# Usage:
#   verify-commit-signatures.sh --repo OWNER/NAME --base SHA --head SHA
#   verify-commit-signatures.sh --repo OWNER/NAME --pr NUMBER
#
# --base/--head reads only repository contents. --pr also reads the pull
# request to find its base and head, which needs pull-request read access.
#
# Exit codes:
#   0   every commit passed
#   1   at least one commit failed a rule
#   2   GitHub's answer was still 5xx, rate-limited or no answer after retries
#   3   the commits could not be fetched or read, or the data was missing or unexpected
#   64  bad usage
#   130 interrupted (SIGINT or SIGTERM)
#
# In GitHub Actions (GITHUB_ACTIONS=true) each failing commit, and the error
# behind an exit 2 or 3, is also printed as an ::error annotation.
#
# Requires gh (authenticated, or GH_TOKEN set) and jq.

# 'local' is not in POSIX, but dash, BusyBox sh and macOS sh all have it.
# shellcheck disable=SC3043
set -u

ATTEMPTS=3
RETRY_DELAYS="10 30"
PAGE_SIZE=100
CHUNK_SIZE=100

annotate=false
if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
  annotate=true
fi

usage() {
  if [ $# -gt 0 ]; then
    printf 'error: %s\n' "$1" >&2
  fi
  cat >&2 <<'EOF'
usage: verify-commit-signatures.sh --repo OWNER/NAME --base SHA --head SHA
       verify-commit-signatures.sh --repo OWNER/NAME --pr NUMBER
EOF
  exit 64
}

# one_line TEXT
# Prints TEXT with every control character (line feeds included) as a space.
one_line() {
  printf '%s' "$1" | tr '\n\r\t' '   ' | LC_ALL=C sed 's/[[:cntrl:]]/ /g'
}

# die CODE MESSAGE
# Prints the error on one line and exits with CODE (2 or 3). In GitHub Actions
# the error is also an ::error annotation; the message has no control
# characters left, so only % needs escaping for the workflow command.
die() {
  local message title
  message=$(one_line "$2")
  printf 'error: %s\n' "$message" >&2
  if [ "$annotate" = "true" ]; then
    if [ "$1" -eq 2 ]; then
      title="Signature check could not reach GitHub"
    else
      title="Signature check could not read the commits"
    fi
    printf '::error title=%s::%s\n' "$title" "$(printf '%s' "$message" | sed 's/%/%25/g')"
  fi
  exit "$1"
}

fail_data() {
  die 3 "$1"
}

matches() {
  printf '%s' "$1" | grep -Eq "$2"
}

repo=""
pr=""
base=""
head=""
while [ $# -gt 0 ]; do
  case $1 in
    --repo|--pr|--base|--head)
      [ $# -ge 2 ] || usage "$1 needs a value"
      case $1 in
        --repo) repo=$2 ;;
        --pr) pr=$2 ;;
        --base) base=$2 ;;
        --head) head=$2 ;;
      esac
      shift 2
      ;;
    -h|--help) usage ;;
    *) usage "unknown argument: $1" ;;
  esac
done

[ -n "$repo" ] || usage "--repo is required"
matches "$repo" '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' || usage "--repo must be OWNER/NAME: $repo"
if [ -n "$pr" ]; then
  { [ -z "$base" ] && [ -z "$head" ]; } || usage "give --pr or --base and --head, not both"
  matches "$pr" '^[1-9][0-9]*$' || usage "--pr must be a pull request number: $pr"
else
  { [ -n "$base" ] && [ -n "$head" ]; } || usage "give --pr, or both --base and --head"
  matches "$base" '^[0-9a-f]{40}$' || usage "--base must be a full 40-character commit hash: $base"
  matches "$head" '^[0-9a-f]{40}$' || usage "--head must be a full 40-character commit hash: $head"
fi

command -v gh >/dev/null 2>&1 || fail_data "gh is not installed"
# jq is preinstalled on GitHub's Ubuntu runners.
command -v jq >/dev/null 2>&1 || fail_data "jq is not installed"

owner=${repo%%/*}
name=${repo#*/}

work=$(mktemp -d "${TMPDIR:-/tmp}/verify-commit-signatures.XXXXXX") || fail_data "could not create a temporary directory"
trap 'rm -rf "$work"' EXIT
trap 'exit 130' INT TERM

# api_try OUTFILE GH_API_ARGS...
# Runs one gh api call and writes the response body to OUTFILE. Retries 5xx
# answers, rate limits and calls with no answer, and exits 2 when they persist.
# Returns 1 on any other failure, with the HTTP status in api_status and gh's
# message in $work/err.
api_try() {
  local out attempt rc headers delays delay transient
  out=$1
  shift
  attempt=1
  delays=$RETRY_DELAYS
  while :; do
    gh api --include "$@" >"$work/raw" 2>"$work/err"
    rc=$?
    tr -d '\r' <"$work/raw" >"$work/resp"
    api_status=$(sed -n '1s/^HTTP\/[0-9.]* \([0-9][0-9][0-9]\).*$/\1/p' "$work/resp")
    headers=$(sed -n '2,/^$/p' "$work/resp")
    sed '1,/^$/d' "$work/resp" >"$out"

    # A call that may succeed if made again: a 5xx answer, a rate limit, or no
    # HTTP answer at all (gh failed before GitHub answered, as on a network
    # failure). gh exit 4 means it has no login or token, which running again
    # won't fix, so it is not retried.
    transient=""
    case $api_status in
      5[0-9][0-9]) transient="answered HTTP $api_status" ;;
      429) transient="answered HTTP 429 (rate limited)" ;;
      403)
        if printf '%s\n' "$headers" | grep -Eiq '^(x-ratelimit-remaining: 0|retry-after:)'; then
          transient="answered HTTP 403 (rate limited)"
        fi
        ;;
      200)
        if jq -e '(.errors? // []) | map(select(.type? == "RATE_LIMITED")) | length > 0' "$out" >/dev/null 2>&1; then
          transient="answered with a GraphQL RATE_LIMITED error"
        fi
        ;;
      '')
        if [ "$rc" -ne 0 ] && [ "$rc" -ne 4 ]; then
          transient="gave no answer ($(one_line "$(head -n 1 "$work/err" | cut -c1-200)"))"
        fi
        ;;
    esac

    if [ -n "$transient" ]; then
      if [ "$attempt" -ge "$ATTEMPTS" ]; then
        die 2 "GitHub still $transient after $ATTEMPTS attempts"
      fi
      delay=${delays%% *}
      delays=${delays#* }
      printf 'GitHub %s; retrying in %s seconds\n' "$transient" "$delay" >&2
      sleep "$delay"
      attempt=$((attempt + 1))
      continue
    fi

    if [ "$rc" -ne 0 ] || [ "$api_status" != "200" ]; then
      return 1
    fi
    return 0
  done
}

# request_failed OUTFILE
# Reports the failed call api_try left behind and exits 3.
request_failed() {
  local message
  message=$(jq -r '.message // .errors[0].message // empty' "$1" 2>/dev/null | head -n 1)
  [ -n "$message" ] || message=$(head -c 500 "$work/err")
  die 3 "GitHub request failed (HTTP ${api_status:-no answer}): $message"
}

# api OUTFILE GH_API_ARGS...
# As api_try, but any failure that is not retried exits 3.
api() {
  api_try "$@" || request_failed "$1"
}

# Lists the commits reachable from head and not from base into $work/shas,
# oldest first, through the compare endpoint. Returns 1 when GitHub reports
# that base and head share no history.
list_by_compare() {
  local page got cstatus
  : >"$work/shas"
  total=""
  page=1
  count=0
  while :; do
    if ! api_try "$work/compare.json" "repos/$repo/compare/$base...$head?per_page=$PAGE_SIZE&page=$page"; then
      if [ "$page" -eq 1 ] && [ "$api_status" = "404" ] \
        && jq -e '(.message | type) == "string" and (.message | startswith("No common ancestor between"))' "$work/compare.json" >/dev/null 2>&1; then
        return 1
      fi
      request_failed "$work/compare.json"
    fi
    jq -e '
      (.status | type) == "string"
      and (.total_commits | type) == "number"
      and (.commits | type) == "array"
      and all(.commits[]; (.sha | type) == "string" and (.sha | test("^[0-9a-f]{40}$")))
    ' "$work/compare.json" >/dev/null 2>&1 || fail_data "the compare response for page $page is missing fields or is not JSON"

    if [ "$page" -eq 1 ]; then
      total=$(jq -r '.total_commits' "$work/compare.json")
      cstatus=$(jq -r '.status' "$work/compare.json")
      case $cstatus in
        ahead|diverged) ;;
        *) fail_data "compare status is '$cstatus': head has no commits that base lacks" ;;
      esac
      matches "$total" '^[1-9][0-9]*$' || fail_data "compare reports $total commits"
    else
      [ "$(jq -r '.total_commits' "$work/compare.json")" = "$total" ] || fail_data "the commit count changed between pages"
    fi

    got=$(jq -r '.commits | length' "$work/compare.json")
    [ "$got" -gt 0 ] || fail_data "page $page of the commit list is empty after $count of $total commits"
    jq -r '.commits[].sha' "$work/compare.json" >>"$work/shas"
    count=$((count + got))
    if [ "$count" -ge "$total" ]; then
      return 0
    fi
    page=$((page + 1))
  done
}

# Lists every commit reachable from head into $work/shas. When base and head
# share no history, these are exactly the commits head adds, so every one of
# them is checked.
list_by_history() {
  local cursor more got
  : >"$work/shas"
  total=""
  count=0
  cursor=""
  while :; do
    jq -n --arg owner "$owner" --arg name "$name" --arg head "$head" --arg cursor "$cursor" '{
      query: "query($owner: String!, $name: String!, $head: GitObjectID!, $after: String) { repository(owner: $owner, name: $name) { object(oid: $head) { ... on Commit { history(first: 100, after: $after) { totalCount pageInfo { hasNextPage endCursor } nodes { oid } } } } } }",
      variables: { owner: $owner, name: $name, head: $head, after: (if $cursor == "" then null else $cursor end) }
    }' >"$work/query.json" || fail_data "could not build the GraphQL query"
    api "$work/history.json" graphql --input "$work/query.json"
    jq -e '
      (has("errors") | not)
      and (.data.repository.object.history.totalCount | type) == "number"
      and (.data.repository.object.history.pageInfo.hasNextPage | type) == "boolean"
      and (.data.repository.object.history.nodes | type) == "array"
      and all(.data.repository.object.history.nodes[]; (.oid | type) == "string" and (.oid | test("^[0-9a-f]{40}$")))
    ' "$work/history.json" >/dev/null 2>&1 || fail_data "the history response has errors or is missing fields"

    if [ -z "$total" ]; then
      total=$(jq -r '.data.repository.object.history.totalCount' "$work/history.json")
      matches "$total" '^[1-9][0-9]*$' || fail_data "head's history has $total commits"
    fi
    got=$(jq -r '.data.repository.object.history.nodes | length' "$work/history.json")
    [ "$got" -gt 0 ] || fail_data "a page of head's history is empty after $count of $total commits"
    jq -r '.data.repository.object.history.nodes[].oid' "$work/history.json" >>"$work/shas"
    count=$((count + got))
    more=$(jq -r '.data.repository.object.history.pageInfo.hasNextPage' "$work/history.json")
    [ "$more" = "true" ] || break
    cursor=$(jq -r '.data.repository.object.history.pageInfo.endCursor // empty' "$work/history.json")
    [ -n "$cursor" ] || fail_data "head's history has more pages but no cursor"
  done
}

if [ -n "$pr" ]; then
  api "$work/pr.json" "repos/$repo/pulls/$pr"
  base=$(jq -r '.base.sha // empty' "$work/pr.json" 2>/dev/null)
  head=$(jq -r '.head.sha // empty' "$work/pr.json" 2>/dev/null)
  matches "$base" '^[0-9a-f]{40}$' || fail_data "pull request $pr has no readable base commit"
  matches "$head" '^[0-9a-f]{40}$' || fail_data "pull request $pr has no readable head commit"
fi

if ! list_by_compare; then
  printf 'Base and head share no history, so every commit reachable from head is checked.\n'
  list_by_history
fi

[ "$count" -eq "$total" ] || fail_data "listed $count commits but GitHub reports $total"
[ "$(sort -u "$work/shas" | wc -l | tr -d ' ')" -eq "$count" ] || fail_data "the commit list repeats a commit"

# Signature data for every commit, CHUNK_SIZE commits per GraphQL call.
split -l "$CHUNK_SIZE" "$work/shas" "$work/chunk." || fail_data "could not split the commit list"
: >"$work/results"
for chunk in "$work"/chunk.*; do
  jq -Rn --arg owner "$owner" --arg name "$name" '
    [inputs] as $s
    | {
        query: (
          "query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) { "
          + ([range(0; $s | length) as $i | "c\($i): object(oid: \"\($s[$i])\") { ...C }"] | join(" "))
          + " } } fragment C on Commit { oid committer { name email user { login } }"
          + " signature { state isValid wasSignedByGitHub signer { login } } }"
        ),
        variables: { owner: $owner, name: $name }
      }
  ' <"$chunk" >"$work/query.json" || fail_data "could not build the GraphQL query"
  api "$work/gql.json" graphql --input "$work/query.json"
  n=$(wc -l <"$chunk" | tr -d ' ')
  jq -e --argjson n "$n" '
    (has("errors") | not)
    and (.data.repository | type) == "object"
    and (.data.repository | length) == $n
  ' "$work/gql.json" >/dev/null 2>&1 || fail_data "the GraphQL response has errors or is missing commits"
  jq -c --argjson n "$n" '[range(0; $n) as $i | .data.repository["c\($i)"]] | .[]' "$work/gql.json" >>"$work/results" \
    || fail_data "could not read the GraphQL response"
done

# One record per commit: either the problems that stop it being evaluated, or its verdict.
jq -nr --rawfile shas "$work/shas" --slurpfile results "$work/results" '
  def str: type == "string";
  def known_states: [
    "VALID", "INVALID", "MALFORMED_SIG", "UNKNOWN_KEY", "BAD_EMAIL", "UNVERIFIED_EMAIL",
    "NO_USER", "UNKNOWN_SIG_TYPE", "UNSIGNED", "GPGVERIFY_UNAVAILABLE", "GPGVERIFY_ERROR",
    "NOT_SIGNING_KEY", "EXPIRED_KEY", "OCSP_PENDING", "OCSP_ERROR", "BAD_CERT", "OCSP_REVOKED"
  ];

  def problems($sha):
    if type != "object" then ["GitHub returned no commit"]
    else [
      (if .oid != $sha then "GitHub returned commit \(.oid) instead" else empty end),
      (if (.committer | type) != "object" then "committer is missing"
       elif (.committer | has("user") | not) then "committer.user is missing"
       elif .committer.user != null and ((.committer.user | type) != "object" or (.committer.user.login | str | not)) then "committer.user.login is missing"
       elif (.committer.name | str | not) or (.committer.email | str | not) then "committer name or email is missing"
       else empty end),
      (if has("signature") | not then "signature is missing"
       elif .signature == null then empty
       elif (.signature | type) != "object" then "signature is not an object"
       else .signature as $g
         | (if ($g.state | str | not) then "signature.state is missing"
            elif ($g.state as $st | known_states | any(.[]; . == $st) | not) then "signature.state has an unexpected value: \($g.state)"
            else empty end),
           (if ($g.isValid | type) != "boolean" then "signature.isValid is missing" else empty end),
           (if ($g.wasSignedByGitHub | type) != "boolean" then "signature.wasSignedByGitHub is missing" else empty end),
           (if ($g | has("signer") | not) then "signature.signer is missing"
            elif $g.signer != null and (($g.signer | type) != "object" or ($g.signer.login | str | not)) then "signature.signer.login is missing"
            else empty end),
           (if ($g.state | str) and ($g.isValid | type) == "boolean" and (($g.state == "VALID") != $g.isValid)
            then "signature.isValid is \($g.isValid) but signature.state is \($g.state)" else empty end)
       end)
    ] end;

  def committer_label:
    if .committer.user != null then .committer.user.login
    else "\(.committer.name) <\(.committer.email)> (no GitHub account)" end;

  # A field of a tab-separated record: every control character in the data
  # from GitHub (U+0000 to U+001F, and U+007F) becomes a space, so each commit
  # stays on one line and no terminal escape reaches the log.
  def field: gsub("[\\x00-\\x1F\\x7F]"; " ");

  # Escaping for GitHub workflow commands, as actions/toolkit does it: escape_data
  # for the message, escape_property for parameters such as title.
  def escape_data: gsub("%"; "%25") | gsub("\r"; "%0D") | gsub("\n"; "%0A");
  def escape_property: escape_data | gsub(":"; "%3A") | gsub(","; "%2C");

  # Control characters other than carriage return and line feed (which the
  # escaping above encodes) become spaces.
  def other_controls: gsub("[\\x00-\\x09\\x0B\\x0C\\x0E-\\x1F\\x7F]"; " ");

  # The ::error workflow command for a failing commit.
  def annotation($sha; $j):
    "::error title=\("Commit \($sha[0:7]) failed rule \($j.rule)" | other_controls | escape_property)::\("\($sha[0:7]): \($j.reason)" | other_controls | escape_data)";

  def judge:
    .signature as $g
    | if $g == null or $g.state == "UNSIGNED" then
        {verdict: "FAIL", rule: "signed", reason: "the commit is not signed"}
      elif $g.state != "VALID" then
        {verdict: "FAIL", rule: "valid", reason: "GitHub reports the signature as \($g.state), not VALID"}
      elif $g.wasSignedByGitHub then
        if $g.signer != null and $g.signer.login == "web-flow" then {verdict: "PASS"}
        else {verdict: "FAIL", rule: "key-matches-committer", reason: "GitHub says it signed the commit, but the signer is \($g.signer.login // "no account"), not web-flow"}
        end
      elif $g.signer == null then
        {verdict: "FAIL", rule: "key-matches-committer", reason: "the signing key belongs to no GitHub account"}
      elif .committer.user == null then
        {verdict: "FAIL", rule: "key-matches-committer", reason: "the key belongs to \($g.signer.login), but the committer has no GitHub account"}
      elif $g.signer.login == .committer.user.login then {verdict: "PASS"}
      else
        {verdict: "FAIL", rule: "key-matches-committer", reason: "the key belongs to \($g.signer.login), but the committer is \(.committer.user.login)"}
      end;

  ($shas | split("\n") | map(select(length > 0))) as $s
  | range(0; $s | length) as $i
  | $s[$i] as $sha
  | ($results[$i]) as $c
  | ($c | problems($sha)) as $p
  | if ($p | length) > 0 then
      $p[] | "BAD\t\($sha)\t\(field)"
    else
      $c
      | judge as $j
      | [
          $j.verdict, $sha,
          ("committer=\(committer_label)" | field),
          ("signer=\(.signature.signer.login // "(none)")" | field),
          ("state=\(.signature.state // "UNSIGNED")" | field),
          (if $j.verdict == "FAIL" then ("rule=\($j.rule): \($j.reason)" | field), annotation($sha; $j) else empty end)
        ]
      | join("\t")
    end
' >"$work/verdicts" || fail_data "could not evaluate the commits"

[ "$(cut -f2 "$work/verdicts" | sort -u | wc -l | tr -d ' ')" -eq "$count" ] || fail_data "not every commit was evaluated"

# Unreadable data for any commit stops the whole run with exit 3, and no
# verdicts are printed.
if grep -q '^BAD' "$work/verdicts"; then
  grep '^BAD' "$work/verdicts" | while IFS="$(printf '\t')" read -r _ sha problem; do
    printf 'error: %.7s: %s\n' "$sha" "$problem" >&2
  done
  fail_data "the data for some commits is missing or unexpected, so no verdict is given"
fi

# In GitHub Actions, each failing commit also gets an ::error annotation, which
# shows on the pull request's checks without opening the log. The runner shows
# at most 10 error annotations per step; the log still lists every commit.
printf 'Checking %s commits in %s (%s...%s)\n' "$count" "$repo" "$base" "$head"
passed=0
failed=0
while IFS="$(printf '\t')" read -r verdict sha committer signer state detail annotation; do
  if [ "$verdict" = "PASS" ]; then
    passed=$((passed + 1))
    printf '%.7s %s  %s  %s  %s\n' "$sha" "$verdict" "$committer" "$signer" "$state"
  else
    failed=$((failed + 1))
    printf '%.7s %s  %s  %s  %s  %s\n' "$sha" "$verdict" "$committer" "$signer" "$state" "$detail"
    if [ "$annotate" = "true" ]; then
      printf '%s\n' "$annotation"
    fi
  fi
done <"$work/verdicts"

[ $((passed + failed)) -eq "$count" ] || fail_data "counted $((passed + failed)) verdicts for $count commits"

if [ "$failed" -gt 0 ]; then
  printf '%s of %s commits failed.\n' "$failed" "$count"
  exit 1
fi
printf 'All %s commits passed.\n' "$count"
exit 0
