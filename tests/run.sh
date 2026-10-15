#!/usr/bin/env bash
# Run every Slack Water test suite headlessly.
# These do not need Roblox Studio — the simulation is pure Luau by design.
set -uo pipefail
cd "$(dirname "$0")/.."

export PATH="$HOME/.local/bin:$PATH"

status=0
for suite in tests/run-tests.luau tests/economy-tests.luau tests/tide-chart-tests.luau tests/progression-tests.luau tests/reconcile-tests.luau tests/client-tests.luau; do
  echo ""
  echo "########## $suite ##########"
  if luau "$suite"; then
    echo "-> $suite PASSED"
  else
    echo "-> $suite FAILED"
    status=1
  fi
done

# The boot smoke test needs its wrapper: the luau CLI has no file I/O, so
# run-boot.sh feeds the server and shared sources in as program arguments.
echo ""
echo "########## tests/boot-tests.luau (via tests/run-boot.sh) ##########"
if ./tests/run-boot.sh; then
  echo "-> tests/boot-tests.luau PASSED"
else
  echo "-> tests/boot-tests.luau FAILED"
  status=1
fi

echo ""
echo "########## tests/bathy-tests.luau (via tests/run-bathy.sh) ##########"
if ./tests/run-bathy.sh; then
  echo "-> tests/bathy-tests.luau PASSED"
else
  echo "-> tests/bathy-tests.luau FAILED"
  status=1
fi

echo ""
if [ "$status" -eq 0 ]; then
  echo "all suites passed"
else
  echo "one or more suites failed"
fi
exit "$status"
