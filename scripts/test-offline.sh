#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# First run: bash scripts/test.sh --integration (downloads two fixtures).
# No global network settings are changed. This restriction applies only to the test process and its children.
/usr/bin/sandbox-exec -p '(version 1) (allow default) (deny network*) (allow network-inbound (local ip "localhost:*")) (allow network-outbound (remote ip "localhost:*"))' \
    .build/debug/hearth-smoke --extended
