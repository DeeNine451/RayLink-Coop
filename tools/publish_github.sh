#!/usr/bin/env bash
# RayLink on GitHub (owner's layout 2026-10-24): three repositories and their releases. Needs `gh auth login` first.
#   BUILD=<N> bash tools/publish_github.sh        (OWNER=stormie-labs, the only owner; VISIBILITY=private for a new
#                                                   launcher repository; SKIP_LAUNCHER=1 for engine/coop only)
# The Stable publish (round 7 of the layer guard, review 6): it goes through tools/release.py and nothing else.
#   1. python -I tools/release.py --channel stable --build <N> verify: the gate (check_gates.py --release --layers:
#      both stand marks and tests.ok of both HEADs, the exe built from engine HEAD, clean trees, the package against
#      HEAD's blobs, the notes; Stable only on a project commit that went out as dev-<N> first). Refused: exit 2 and
#      not one command talks to the network. It talks to no network itself.
#   2. RayLink-Engine's public main must be a commit made here (the branch `publish` of engine\, a local engine tag, or
#      an ancestor of engine HEAD): the build's snapshot goes on top of it and would undo commits made elsewhere.
#   3. release.py draft, then release.py publish: the tag b<N> and main of both public repositories, the drafts with
#      the verified assets (their SHA-256 checked on GitHub), then "latest". This script creates no release itself.
#   4. the launcher (unless SKIP_LAUNCHER=1): its source to the PRIVATE RayLink-Launcher-Source, installers by hand.
# RayLink-Engine    main = one commit per build with the tree of engine\ (branch coop): the history of xray-monolith (74
#                   authors) stays local and upstream, not on GitHub (owner 2026-10-26); release b<N> = the engine exe
# RayLink-Coop      main = this project (gamedata, tools, tests, docs); release b<N> = releases\anomaly-coop-0.<N>.0.zip
#                   (tools\package.ps1: the build the launcher installs)
# RayLink-Launcher = public product page and installers only; application source goes to private RayLink-Launcher-Source.
# tests/tools/test_release.py runs this file with fake python, gh and git (VERIFY_FIRST, test_publish_github_*).
set -euo pipefail
export GH_HOST=github.com
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ORG=stormie-labs  # tools/release.py ORG: the only owner the gated release publishes to
BUILD="${BUILD:-}"
OWNER="${OWNER:-$ORG}"
VIS="${VISIBILITY:-public}"
refuse() {
	echo "! publish_github.sh: $1" >&2
	echo "  Nothing was published." >&2
	exit "${2:-2}"
}
# guard round 8 (R5): a point build is no Stable build in tools/release.py either (names_for: "a Stable build is a whole
# number"); it goes out to Dev only
if [[ "$BUILD" =~ ^[0-9]{1,3}\.[0-9]{1,2}$ ]]; then
	refuse "BUILD=$BUILD is a point build: a Stable build is a whole number (BUILD=57), tools/release.py refuses a Stable $BUILD too. A point build goes out to Dev only: python -I tools/release.py --channel dev --build $BUILD prepare, then verify"
fi
[[ "$BUILD" =~ ^[0-9]{1,3}$ ]] || refuse "BUILD must be a whole Stable build number (BUILD=57): a Stable build is a whole number; a Dev build goes out with release.py --channel dev"
[ "$OWNER" = "$ORG" ] || refuse "tools/release.py publishes to $ORG only: leave OWNER unset or set it to $ORG"
[ "$VIS" = public ] || [ "$VIS" = private ] || refuse "VISIBILITY is public or private"

# 1. the gate: nothing below runs unless release.py verify passed
if ! python -I "$ROOT/tools/release.py" --channel stable --build "$BUILD" verify; then
	refuse "release.py verify refused Stable b$BUILD (above). The steps before it:
  python -I tools/release.py --channel stable --build $BUILD prepare   (temp/b$BUILD/: write notes-coop.md, notes-engine.md)
  powershell -ExecutionPolicy Bypass -File tools/package.ps1 -Version 0.$BUILD.0 -Force
  python -I tools/release.py --channel stable --build $BUILD verify"
fi
gh auth status >/dev/null 2>&1 || refuse "gh is not logged in: run gh auth login" 3
gh auth setup-git
echo "owner: $OWNER, Stable b$BUILD (verified)"

if [ "${SKIP_LAUNCHER:-0}" != "1" ]; then
	SOURCE_REPO="$OWNER/RayLink-Launcher-Source"
	gh repo view "$SOURCE_REPO" >/dev/null 2>&1 || gh repo create "$SOURCE_REPO" --private --description 'Private source for RayLink Launcher'
	[ "$(gh repo view "github.com/$SOURCE_REPO" --json visibility --jq .visibility)" = PRIVATE ] ||
		refuse "the launcher source destination $SOURCE_REPO must be PRIVATE: no source will be pushed" 4
fi

# 2. the public engine main is a commit made here
ENGINE_URL="https://github.com/$ORG/RayLink-Engine.git"
PREV="$(git ls-remote "$ENGINE_URL" refs/heads/main | cut -f1)"
if [ -n "$PREV" ]; then
	git -C "$ROOT/engine" fetch -q "$ENGINE_URL" main
	MADE_HERE=0
	[ "$PREV" = "$(git -C "$ROOT/engine" rev-parse -q --verify publish || true)" ] && MADE_HERE=1
	[ -n "$(git -C "$ROOT/engine" tag --points-at "$PREV" 2>/dev/null || true)" ] && MADE_HERE=1
	git -C "$ROOT/engine" merge-base --is-ancestor "$PREV" HEAD && MADE_HERE=1
	[ "$MADE_HERE" = 1 ] || refuse "RayLink-Engine main ($PREV) has commits made outside this machine's releases: bring
  them into engine\\ (branch coop) first, then publish again" 4
fi

# 3. the release: release.py's draft and publish (they refuse unless verified.json is this tag's and nothing moved)
python -I "$ROOT/tools/release.py" --channel stable --build "$BUILD" draft
python -I "$ROOT/tools/release.py" --channel stable --build "$BUILD" publish

# 4. the launcher
if [ "${SKIP_LAUNCHER:-0}" != "1" ]; then
	LAUNCHER="$(cd "$ROOT/../raylink-launcher" && pwd)"
	gh repo view "$OWNER/RayLink-Launcher" >/dev/null 2>&1 ||
		gh repo create "$OWNER/RayLink-Launcher" "--$VIS" --description "RayLink Launcher - downloads, updates and support (proprietary application)"
	(cd "$LAUNCHER" && npm run build && powershell.exe -NoProfile -File scripts/build-release.ps1)
	git -C "$LAUNCHER" push "https://github.com/$SOURCE_REPO.git" HEAD:refs/heads/main
	echo "launcher release: upload only releases/v<VERSION>/RayLinkSetup.exe to $OWNER/RayLink-Launcher"
fi
echo "done: https://github.com/$ORG/RayLink-Coop/releases  https://github.com/$ORG/RayLink-Engine/releases"
