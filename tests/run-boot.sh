#!/usr/bin/env bash
# Server boot smoke test — executes src/Server/Main.server.luau headlessly.
#
# The luau CLI has no file I/O, so the sources are fed into the process as
# (path, contents) program-argument pairs and reassembled by the harness.
# See docs/TESTING.md for how this works and exactly what it does not cover.
set -uo pipefail
cd "$(dirname "$0")/.."

export PATH="$HOME/.local/bin:$PATH"

args=()
while IFS= read -r f; do
  args+=("$f" "$(cat "$f")")
done < <(find src/Server src/Shared -name '*.luau' | sort)

if [ "${#args[@]}" -eq 0 ]; then
  echo "run-boot.sh: no sources found under src/Server and src/Shared" >&2
  exit 1
fi

exec luau tests/boot-tests.luau -a "${args[@]}"
