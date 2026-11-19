#!/usr/bin/env bash
# Retired (review 5 of the layer guard, B2, 2026-11-19). This script used to put the zip on GitHub as the prerelease
# dev-<N>.<M> of stormie-labs/RayLink-Coop with no gate at all: no stand marks, no tests.ok, no clean tree, no HEAD
# check, and a tag GitHub made on the default branch. The launcher serves the newest dev-* prerelease, so that was a Dev
# build nobody had checked. A Dev build now goes out only through tools/release.py: its draft and publish refuse without
# its own verify of this tag (check_gates.py --release --layers: both stand marks and tests.ok of both HEADs, the exe
# built from engine HEAD, clean trees, the package against HEAD's blobs). It publishes the zip and the engine exe together.
# tests/tools/test_release.py keeps every publishing command in tools/ inside release.py.
#   bash tools/publish_dev.sh <N>.<M> ...   -> refuses and prints the release.py commands
set -euo pipefail
BUILD='<N>'
if [ "$#" -ge 1 ] && [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,2})?$ ]]; then BUILD="$1"; fi
{
	echo "! tools/publish_dev.sh no longer publishes: a Dev build goes out only through tools/release.py (review 5, B2)."
	echo "  python -I tools/release.py --channel dev --build $BUILD prepare   (writes temp/dev-$BUILD/, names the package step)"
	echo "  python -I tools/release.py --channel dev --build $BUILD verify    (the gate: stand marks, tests.ok, exe, package)"
	echo "  python -I tools/release.py --channel dev --build $BUILD draft     (pushes the tag, drafts both releases)"
	echo "  python -I tools/release.py --channel dev --build $BUILD publish   (undrafts both; Stable's latest stays)"
	echo "  Nothing was published."
} >&2
exit 2
