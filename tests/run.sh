#!/usr/bin/env bash
# Run every Slack Water test suite headlessly.
# These do not need Roblox Studio — the simulation is pure Luau by design.
set -uo pipefail
cd "$(dirname "$0")/.."

export PATH="$HOME/.local/bin:$PATH"

status=0
for suite in tests/run-tests.luau tests/economy-tests.luau tests/tide-chart-tests.luau; do
  echo ""
  echo "########## $suite ##########"
  if luau "$suite"; then
    echo "-> $suite PASSED"
  else
    echo "-> $suite FAILED"
    status=1
  fi
done

echo ""
if [ "$status" -eq 0 ]; then
  echo "all suites passed"
else
  echo "one or more suites failed"
fi
exit "$status"
