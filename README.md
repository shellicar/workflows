# workflows

Shared GitHub Actions workflows for the shellicar repositories.

## Verify commit signatures

`.github/workflows/verify-commit-signatures.yml` is a reusable workflow that checks every commit in a pull request. It runs `verify-commit-signatures.sh` from this repository.

### Motivation

Every commit in these repositories should be signed, by the identity that made it. Setting up signing on each machine does not guarantee that, so it is checked on every pull request. The repositories squash-merge, so the "main" ruleset's signed-commits rule only ever sees the squash commit GitHub makes, never the pull request's own commits.

### What it checks

A commit passes only when all three rules hold:

| Rule | Passes when |
|---|---|
| `signed` | the commit carries a signature |
| `valid` | GitHub reports the signature's state as `VALID` |
| `key-matches-committer` | the signing key belongs to the committer's GitHub account, or GitHub signed the commit itself (`wasSignedByGitHub` is true and the signer is `web-flow`) |

GitHub's `verified` flag alone is not enough: a key can be valid and still belong to someone other than the committer.

> Untested: no commit signed with one account's key and committed as another account has been checked yet. A test pull request with such a commit would settle it: GitHub reporting it `VALID` with the two accounts confirms the claim, and the script should then fail it on `key-matches-committer`. If GitHub reports another state, such as `BAD_EMAIL`, the `valid` rule already fails it.

The check fails closed. A failed or partial call, a missing field, an unexpected value or an empty commit list fails it. A rule that cannot be evaluated is a failure, never a skip.

### Permissions and calls

The workflow needs `contents: read` and nothing else. It takes the pull request's base and head from the event, so it never reads the pull request itself.

This was seen on this repository's first pull request (shellicar/workflows#1): with only `contents: read`, the check listed and checked all 7 of its commits.

It makes two calls for a pull request of up to 100 commits, and one more of each kind for every further 100 commits. When the pull request's head shares no history with its base, the first call is refused and the commits are listed another way, so it makes at least three.

### Calling it

Add a small workflow of its own to the repository, with the reference pinned to a full commit hash of this repository:

```yaml
name: Verify Signatures

on:
  pull_request:
    branches: [main]

permissions:
  contents: read

jobs:
  verify-signatures:
    uses: shellicar/workflows/.github/workflows/verify-commit-signatures.yml@<full 40-character commit hash>
```

It is its own check, required by the ruleset on its own, separately from the repository's CI `gate`. This repository does the same: `.github/workflows/verify-signatures.yml` calls the reusable workflow for its own pull requests.

The workflow checks out `verify-commit-signatures.sh` from this repository at its own commit (`job.workflow_sha`). For a caller in another repository that is the commit the caller pinned, never the pull request being checked. For this repository's own pull requests, which call the workflow locally (`./`), it is the pull request's own version, so a pull request here that changes the script is checked by the changed script: one that makes the script pass everything passes its own check.

Both cases have been seen. On shellicar/workflows#1 the job ran the workflow at `refs/pull/1/merge`, and the "Check out the verifier" step checked out that same commit, the pull request's merge commit. On a pull request in another, private, repository that called the workflow pinned by hash, the job ran the workflow at the pinned commit and the step checked out that commit.

### The check name

GitHub names the check `<caller job> / <called job>`. With the caller above, the check is:

```
verify-signatures / verify
```

That name has been seen both for this repository's own caller, on shellicar/workflows#1, and for a caller in another, private, repository pinned by hash, whose job is also `verify-signatures`.

A ruleset requires that check by name, as well as the repository's `gate`. A ruleset that still requires plain `verify-signatures` (the name of the per-repository copies this replaces) waits for a check that never reports.

### Running it locally

```sh
sh verify-commit-signatures.sh --repo OWNER/NAME --pr NUMBER
sh verify-commit-signatures.sh --repo OWNER/NAME --base SHA --head SHA
```

It needs `gh` (logged in, or `GH_TOKEN` set) and `jq`. `--pr` also reads the pull request to find its base and head, so it needs pull-request read access as well.

For each commit it prints the short hash, the verdict, the committer, the signer and the state, and for a failure the rule it failed and why:

```
Checking 2 commits in OWNER/NAME (BASE...HEAD)
c000001 FAIL  committer=alice  signer=(none)  state=UNSIGNED  rule=signed: the commit is not signed
c000002 PASS  committer=GitHub <noreply@github.com> (no GitHub account)  signer=web-flow  state=VALID
1 of 2 commits failed.
```

In GitHub Actions (`GITHUB_ACTIONS` is `true`) it also prints an `::error` annotation after each failing commit's line, naming the short hash, the rule and why, so the failure shows on the pull request's checks without opening the log:

```
::error title=Commit c000001 failed rule signed::c000001: the commit is not signed
```

The runner keeps at most 10 error annotations per step, so past 10 failing commits the rest show only in the log, which still lists every commit checked.

When the run stops with exit 2 or 3, it prints the error as an `::error` annotation too, so the reason shows on the checks rather than only that the job failed:

```
::error title=Signature check could not read the commits::GitHub request failed (HTTP 403): Resource not accessible by integration
```

Control characters in the data from GitHub, such as a terminal escape in a committer's name, are printed as spaces, so none reaches the log.

### Exit codes

| Code | Meaning |
|---|---|
| 0 | every commit passed |
| 1 | at least one commit failed a rule |
| 2 | GitHub's answer was still 5xx, rate-limited or no answer after retries; running again later can help |
| 3 | the commits could not be fetched or read, or the data was missing or unexpected |
| 64 | bad usage |
| 130 | interrupted (SIGINT or SIGTERM) |

## Tests

### Logic tests

```sh
sh tests/run-logic-tests.sh            # every case
sh tests/run-logic-tests.sh CASE...    # some cases, by directory name
```

They use no network. A stub `gh` (`tests/stub/gh`) answers each call the script makes with the case's next response, so the whole script runs: fetching, retrying, validating and judging. A stub `sleep` makes the retries instant and records their delays.

Each directory in `tests/cases` is one case:

| File | Holds |
|---|---|
| `args` | the script's arguments |
| `responses/N.json` | the body of the Nth call's answer, served as HTTP 200 |
| `responses/N.http` | the Nth call's whole answer: status line, headers, blank line, body |
| `responses/N.exit` | the exit status gh gives for the Nth call, when it differs from the default |
| `responses/N.stderr` | what gh prints to stderr for the Nth call, when it has neither `N.json` nor `N.http` |
| `github-actions` | the value of `GITHUB_ACTIONS` the script sees; without this file it sees an empty value |
| `expected` | the expected exit code, number of calls, retry delays (when listed), each commit's verdict and failed rule, and any `::error` lines |
| `description` | what the case covers |

A call with neither `responses/N.json` nor `responses/N.http` gets no answer: gh prints nothing to stdout and exits 1, or with `N.exit` when present, as it does when it reaches no server. The runner also fails any case whose output carries a control character other than the line ends.

Every case uses example data in the shape of GitHub's answers. The `combo-*` cases cover each combination of author, committer, signer and state seen in practice; the `annotate-*` cases cover the annotations; the `synthetic-*`, `retry-*`, `closed-*` and `usage-*` cases cover the other rules, retries, failures and bad usage.

To run the suite under BusyBox sh and BusyBox's tools, which shows the scripts run under BusyBox as well as dash:

```sh
docker run --rm -v "$PWD:/w:ro" alpine@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc sh /w/tests/docker-entry.sh # alpine:3.20
```

### Lint

```sh
sh scripts/lint.sh
```

It lints only the files git tracks (`git ls-files`), so untracked and ignored files such as `tests/local/` are left out. Among them, the shell scripts (any `*.sh` file, or any file whose `#!` line names sh, dash or bash) are checked with ShellCheck in POSIX mode (`-s sh`), and the workflows (`.github/workflows/*.yml` and `*.yaml`) with actionlint, which also runs ShellCheck on each workflow's `run:` steps. It fails if it finds no shell scripts or no workflows. Both tools run in Docker, pinned by image digest.

actionlint 1.7.12 does not know the `job.workflow_repository` and `job.workflow_sha` properties, which GitHub documents. `.github/actionlint.yaml` ignores only that error, and only in `.github/workflows/verify-commit-signatures.yml`.

### CI

`.github/workflows/ci.yml` runs the code checks on pull requests and on pushes to main. Its jobs are `lint`, `test-dash` and `test-busybox` (the logic tests under each shell). A final `gate` job needs all of them and fails unless each succeeded; a skipped job fails it too, since none of them is meant to skip. A ruleset can require the single check `gate`.

The signature check is separate: `.github/workflows/verify-signatures.yml` runs the reusable workflow on this repository's own pull requests, as its own check (`verify-signatures / verify`). `.github/workflows/codeql.yml` runs CodeQL separately.

`tests/local/` is ignored by git. It holds tests that run against real pull requests on one machine; they are never committed.

### macOS

The scripts are written for macOS's BSD tools as well, but have been run only on Linux (dash, and BusyBox in Docker). To check them on macOS, run `sh tests/run-logic-tests.sh` there.

## Inside the script

For whoever works on `verify-commit-signatures.sh`. Everything is fetched before anything is judged:

1. The REST compare endpoint (`compare/BASE...HEAD`) lists the pull request's commits, 100 per call.
2. One GraphQL query per 100 commits reads each commit's signature (`state`, `isValid`, `wasSignedByGitHub`, `signer`) and committer.

When a pull request's head shares no history with its base, the compare endpoint answers 404 ("No common ancestor"). The script then lists every commit reachable from head through GraphQL, which in that case are exactly the commits the pull request adds.

5xx answers, rate limits (HTTP 429, a 403 with `X-RateLimit-Remaining: 0` or `Retry-After`, or a GraphQL `RATE_LIMITED` error) and calls with no answer (gh fails before GitHub answers, as on a network failure) are retried twice, after 10 and then 30 seconds. If they still fail, the script exits 2. gh failing because it has no login or token (gh exit 4) is not retried, since running again won't help. That, and any other failure, exits 3 at once.

Annotations are escaped the way `actions/toolkit` escapes workflow commands: `%`, carriage return and line feed in the message become `%25`, `%0D` and `%0A`, and the title also escapes `:` and `,`. Other control characters become spaces. The error annotation for an exit 2 or 3 carries the error line, which has every control character, line feeds included, as a space, so only its `%` needs escaping.
