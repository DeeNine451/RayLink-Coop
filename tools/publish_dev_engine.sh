#!/usr/bin/env bash
# Retired (review 5 of the layer guard, B2, 2026-11-19). This script used to put an engine exe on GitHub as the
# prerelease dev-<N>.<M> of stormie-labs/RayLink-Engine with no gate at all (no stand marks, no tests.ok, no check that
# the exe is engine-ci's build of engine HEAD). tools/release.py publishes the engine exe of a Dev build together with
# the zip, after its own verify of this tag (check_gates.py --release --layers --exe <the exe>).
# tests/tools/test_release.py keeps every publishing command in tools/ inside release.py.
#   bash tools/publish_dev_engine.sh <N>.<M> ...   -> refuses and prints the release.py commands
set -euo pipefail
BUILD='<N>'
if [ "$#" -ge 1 ] && [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,2})?$ ]]; then BUILD="$1"; fi
{
	echo "! tools/publish_dev_engine.sh no longer publishes: the engine exe of a Dev build goes out with the zip, only"
	echo "  through tools/release.py (review 5, B2):"
	echo "  python -I tools/release.py --channel dev --build $BUILD verify --exe <the exe>   (the gate)"
	echo "  python -I tools/release.py --channel dev --build $BUILD draft"
	echo "  python -I tools/release.py --channel dev --build $BUILD publish"
	echo "  Nothing was published."
} >&2
exit 2
