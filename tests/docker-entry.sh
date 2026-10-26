#!/bin/sh
# Runs the logic tests inside an Alpine container, so the script runs under
# BusyBox sh and BusyBox's sed, grep and friends rather than the host's.
# The repository is mounted read-only at /w; the image is alpine:3.20, pinned:
#
#   docker run --rm -v "$PWD:/w:ro" alpine@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc sh /w/tests/docker-entry.sh
set -eu
command -v jq >/dev/null 2>&1 || apk add --no-cache jq >/dev/null
exec sh /w/tests/run-logic-tests.sh "$@"
