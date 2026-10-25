# workflows

Shared GitHub Actions workflows for the shellicar repositories.

## Verify commit signatures

`.github/workflows/verify-commit-signatures.yml` is a reusable workflow that checks every commit in a pull request. It runs `verify-commit-signatures.sh` from this repository.

### What it checks, and why

The repositories squash-merge. The "main" ruleset's signed-commits rule only ever sees the squash commit GitHub makes, which GitHub signs itself, so it says nothing about the commits inside the pull request. This workflow is what checks those.

A commit passes only when all three rules hold:

| Rule | Passes when |
|---|---|
| `signed` | the commit carries a signature |
| `valid` | GitHub reports the signature's state as `VALID` |
| `key-matches-committer` | the signing key belongs to the committer's GitHub account, or GitHub signed the commit itself (`wasSignedByGitHub` is true and the signer is `web-flow`) |

GitHub's `verified` flag alone is not enough: a key can be valid and still belong to someone other than the committer.

The check fails closed. A failed or partial call, a missing field, an unexpected value or an empty commit list fails it. A rule that cannot be evaluated is a failure, never a skip.

### How it reads GitHub

Everything is fetched before anything is judged:

1. The REST compare endpoint (`compare/BASE...HEAD`) lists the pull request's commits, 100 per call.
2. One GraphQL query per 100 commits reads each commit's signature (`state`, `isValid`, `wasSignedByGitHub`, `signer`) and committer.

A pull request of up to 100 commits takes two calls. Both read only repository contents, so the workflow needs `contents: read` and nothing else. The base and head come from the pull request event, so the workflow never reads the pull request itself.

When a pull request's head shares no history with its base, the compare endpoint refuses. The script then lists every commit reachable from head, which in that case are exactly the commits the pull request adds.

5xx answers and rate limits (HTTP 429, a 403 with `X-RateLimit-Remaining: 0` or `Retry-After`, or a GraphQL `RATE_LIMITED` error) are retried twice, after 10 and then 30 seconds.

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

The workflow checks out `verify-commit-signatures.sh` from this repository at the same commit the caller pinned (`job.workflow_sha`), never from the pull request being checked.

### The check name

GitHub names the check `<caller job> / <called job>`. With the caller above, the check is:

```
verify-signatures / verify
```

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

### Exit codes

| Code | Meaning |
|---|---|
| 0 | every commit passed |
| 1 | at least one commit failed a rule |
| 2 | GitHub still answered 5xx or rate-limited after retries |
| 3 | the commits could not be fetched or read, or the data was missing or unexpected |
| 64 | bad usage |

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
| `expected` | the expected exit code, number of calls, retry delays (when listed) and each commit's verdict and failed rule |
| `description` | what the case covers |

Every case uses example data in the shape of GitHub's answers. The `combo-*` cases cover each combination of author, committer, signer and state seen in practice; the `synthetic-*`, `retry-*`, `closed-*` and `usage-*` cases cover the other rules, retries, failures and bad usage.

To run the suite under BusyBox sh and BusyBox's tools, as a check that the scripts use nothing beyond POSIX:

```sh
docker run --rm -v "$PWD:/w:ro" alpine@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc sh /w/tests/docker-entry.sh # alpine:3.20
```

### Lint

```sh
sh scripts/lint.sh
```

It searches the whole repository for shell scripts (any `*.sh` file, or any file whose `#!` line names sh, dash or bash) and checks them with ShellCheck in POSIX mode (`-s sh`). It checks every workflow under `.github/workflows` with actionlint, which also runs ShellCheck on each workflow's `run:` steps. Both tools run in Docker, pinned by image digest.

actionlint 1.7.12 does not know the `job.workflow_repository` and `job.workflow_sha` properties, which GitHub documents. `.github/actionlint.yaml` ignores only that error, and only in `.github/workflows/verify-commit-signatures.yml`.

### CI

`.github/workflows/ci.yml` runs the code checks on pull requests and on pushes to main. Its jobs are `lint`, `test-dash` and `test-busybox` (the logic tests under each shell). A final `gate` job needs all of them and fails unless each succeeded; a skipped job fails it too, since none of them is meant to skip. A ruleset can require the single check `gate`.

The signature check is separate: `.github/workflows/verify-signatures.yml` runs the reusable workflow on this repository's own pull requests, as its own check (`verify-signatures / verify`). `.github/workflows/codeql.yml` runs CodeQL separately.

`tests/local/` is ignored by git. It holds tests that run against real pull requests on one machine; they are never committed.

### macOS

The scripts are written for macOS's BSD tools as well, but have been run only on Linux (dash, and BusyBox in Docker). To check them on macOS, run `sh tests/run-logic-tests.sh` there.
