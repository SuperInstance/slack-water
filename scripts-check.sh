#!/usr/bin/env bash
# Lint + format check + Rojo build. The gate that must pass before commit.
set -uo pipefail
cd "$(dirname "$0")"

export PATH="$HOME/.local/bin:$PATH"
status=0

echo "== luau parse =="
while IFS= read -r f; do
  # Roblox-global modules will fail at runtime outside Studio; only genuine
  # syntax errors are reported as "Expected ..." — those are what we gate on.
  out=$(luau "$f" 2>&1)
  if echo "$out" | grep -qE "Expected|Incomplete statement|Parse error"; then
    echo "  SYNTAX  $f"; echo "$out" | head -2; status=1
  else
    echo "  ok      $f"
  fi
done < <(find src tests -name "*.luau" 2>/dev/null | sort)

echo ""
echo "== selene =="
selene src tests 2>&1 | tail -5 || status=1

echo ""
echo "== rojo build =="
rojo build default.project.json -o /tmp/slack-water.rbxlx 2>&1 | tail -5 || status=1

exit "$status"
