#!/bin/sh
# Runs the logic tests inside an Alpine container, so the script runs under
# BusyBox sh and BusyBox's sed, grep and friends rather than the host's.
# The repository is mounted read-only at /w:
#
#   docker run --rm -v "$PWD:/w:ro" alpine:3.20 sh /w/tests/docker-entry.sh
set -eu
command -v jq >/dev/null 2>&1 || apk add --no-cache jq >/dev/null
exec sh /w/tests/run-logic-tests.sh "$@"
