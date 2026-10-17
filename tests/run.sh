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

# The cast-loop suite executes the real client scripts under a fake client
# engine, so it needs its sources fed in as (path, contents) program
# arguments — same technique as the boot and wallet suites below.
echo ""
echo "########## tests/cast-loop-tests.luau (with client sources fed in) ##########"
cast_args=()
for f in src/Client/Ui.luau src/Client/CastBar.client.luau src/Client/Casting.client.luau \
  src/Client/HUD.client.luau src/Shared/Types.luau src/Shared/Species.luau \
  src/Shared/Config.luau src/Shared/Tide.luau src/Shared/Market.luau \
  src/Client/CatchCard.client.luau src/Client/GearBar.client.luau \
  src/Client/MarketPanel.client.luau src/Client/Notify.client.luau \
  src/Client/RegionChart.client.luau src/Client/TideStrip.client.luau; do
  cast_args+=("$f" "$(cat "$f")")
done
if luau tests/cast-loop-tests.luau -a "${cast_args[@]}"; then
  echo "-> tests/cast-loop-tests.luau PASSED"
else
  echo "-> tests/cast-loop-tests.luau FAILED"
  status=1
fi

# The wallet suite drives the real server path (CastService -> WalletService)
# under the fake Roblox engine, so like the boot test it needs its sources fed
# in as (path, contents) program arguments.
echo ""
echo "########## tests/wallet-tests.luau ##########"
wallet_args=()
while IFS= read -r f; do
  wallet_args+=("$f" "$(cat "$f")")
done < <(find src/Server src/Shared -name '*.luau' | sort)
if [ "${#wallet_args[@]}" -gt 0 ] && luau tests/wallet-tests.luau -a "${wallet_args[@]}"; then
  echo "-> tests/wallet-tests.luau PASSED"
else
  echo "-> tests/wallet-tests.luau FAILED"
  status=1
fi

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
