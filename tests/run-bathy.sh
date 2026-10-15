#!/usr/bin/env bash
# Bathymetry test runner — unit tests plus an end-to-end exercise of the
# converter CLI on the sample fixtures.
#
# Self-contained on purpose: the owner will wire this into tests/run.sh later;
# until then nothing else in the repo depends on it.
#
# What the e2e half covers that the unit tests cannot: convert.sh's file
# handling, the bash<->luau handoff, and the exact bytes that land in the
# output JSON.
set -uo pipefail
cd "$(dirname "$0")/.."

export PATH="$HOME/.local/bin:$PATH"

status=0

step() { echo ""; echo "########## $* ##########"; }
check() {
	if [ "$1" -eq 0 ]; then
		echo "  PASS  $2"
	else
		echo "  FAIL  $2"
		status=1
	fi
}

# grep -qF: assert a fixed string occurs in a file
expect_in() {
	grep -qF -- "$2" "$1"
	check $? "$1 contains '$2'"
}

step "unit tests"
if luau tests/bathy-tests.luau; then
	echo "-> unit tests PASSED"
else
	echo "-> unit tests FAILED"
	status=1
fi

step "end-to-end: convert.sh on the fixtures"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 1. NOAA-style XYZ, geographic degrees, metres, no assertion
./pipeline/bathy/convert.sh pipeline/bathy/fixtures/sample-geographic.xyz \
	--units m --cell 400 --source "synthetic fixture - not real data" \
	--out "$TMP/geo.json" >/dev/null 2>"$TMP/geo.err"
check $? "xyz fixture converts"
if [ ! -s "$TMP/geo.json" ]; then
	cat "$TMP/geo.err"
	status=1
fi
expect_in "$TMP/geo.json" '"formatDetected":"xyz"'
expect_in "$TMP/geo.json" '"delimiter":"ws"'
expect_in "$TMP/geo.json" '"surveyed":false'
expect_in "$TMP/geo.json" '"unitsInput":"m"'

# 2. CSV with header, projected metres, fathoms
./pipeline/bathy/convert.sh pipeline/bathy/fixtures/sample-projected.csv \
	--units fm --cell 100 --coords projected --source "synthetic fixture" \
	--out "$TMP/csv.json" >/dev/null 2>&1
check $? "csv fixture converts"
expect_in "$TMP/csv.json" '"formatDetected":"csv"'
expect_in "$TMP/csv.json" '"headerRow":true'
expect_in "$TMP/csv.json" '"unitsInput":"fm"'
# 10 fm = 18.288 m: the shallowest grid value must not be a metres reading
# of a fathom column (that would be ~10); with a 10-20 fm range, min is ~18ish
expect_in "$TMP/csv.json" '"depthMinMetres":18.3'

# 3. TSV with header, feet, WITH the operator assertion
./pipeline/bathy/convert.sh pipeline/bathy/fixtures/sample-tab.tsv \
	--units ft --cell 150 --coords projected --surveyed \
	--source "synthetic fixture" --timestamp 2026-10-14T00:00:00Z \
	--out "$TMP/tsv.json" >/dev/null 2>&1
check $? "tsv fixture converts"
expect_in "$TMP/tsv.json" '"formatDetected":"tsv"'
expect_in "$TMP/tsv.json" '"unitsInput":"ft"'
expect_in "$TMP/tsv.json" '"surveyed":true'
expect_in "$TMP/tsv.json" '"provenance":"measured"'
# 60 ft = 18.288 m — the same real depth as fixture 2's 10 fm, a cross-check
# that feet and fathoms land on one number
expect_in "$TMP/tsv.json" '"depthMinMetres":18.3'

step "end-to-end: converter refuses to guess units"
if ./pipeline/bathy/convert.sh pipeline/bathy/fixtures/sample-tab.tsv \
	--cell 150 --out "$TMP/no-units.json" >/dev/null 2>&1; then
	echo "  FAIL  conversion without --units should fail"
	status=1
else
	echo "  PASS  conversion without --units fails loudly"
fi

step "end-to-end: pinned timestamp gives byte-identical output"
./pipeline/bathy/convert.sh pipeline/bathy/fixtures/sample-projected.csv \
	--units fm --cell 100 --coords projected --timestamp 2026-10-14T00:00:00Z \
	--out "$TMP/det1.json" >/dev/null 2>&1
./pipeline/bathy/convert.sh pipeline/bathy/fixtures/sample-projected.csv \
	--units fm --cell 100 --coords projected --timestamp 2026-10-14T00:00:00Z \
	--out "$TMP/det2.json" >/dev/null 2>&1
cmp -s "$TMP/det1.json" "$TMP/det2.json"
check $? "two runs with the same input and timestamp are identical"

step "committed fallback artifact"
FALLBACK="shared/bathy/fallback-depth.json"
if [ -s "$FALLBACK" ]; then
	echo "  PASS  $FALLBACK exists"
else
	echo "  FAIL  $FALLBACK missing"
	status=1
fi
expect_in "$FALLBACK" '"surveyed":false'
expect_in "$FALLBACK" '"provenance":"grown"'
expect_in "$FALLBACK" 'NOT real survey data'

luau pipeline/bathy/bake.luau >"$TMP/rebake.json" 2>/dev/null
cmp -s "$TMP/rebake.json" "$FALLBACK"
check $? "re-baking reproduces the committed file byte for byte"

step "sampler benchmark (informational, not gating)"
luau pipeline/bathy/bench.luau || echo "  (bench failed; not gating)"

echo ""
if [ "$status" -eq 0 ]; then
	echo "bathymetry: all green"
else
	echo "bathymetry: one or more checks failed"
fi
exit "$status"
