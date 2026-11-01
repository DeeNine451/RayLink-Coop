#!/usr/bin/env bash
# The engine of a Dev channel build: prerelease dev-<N>.<M> of stormie-labs/RayLink-Engine. Needs `gh auth login` first.
#   bash tools/publish_dev_engine.sh <N>.<M> <AnomalyCoopDX11AVX.exe> <notes-file> [title]
# The launcher never reads this repository: the zip of tools/publish_dev.sh already holds the exe. This is the record of it,
# like release b<N> in tools/publish_github.sh. Latest stays on the last b<N>.
set -euo pipefail
export GH_HOST=github.com
REPO=stormie-labs/RayLink-Engine

refuse() { echo "! $1. Nothing was published." >&2; exit 2; }

for arg in "$@"; do
	case "$arg" in --latest*|--prerelease=*) refuse "a dev build is a prerelease and is never marked Latest" ;; esac
done
[ "$#" -eq 3 ] || [ "$#" -eq 4 ] || refuse "usage: bash tools/publish_dev_engine.sh <N>.<M> <AnomalyCoopDX11AVX.exe> <notes-file> [title]"
VERSION="$1"
EXE="$2"
NOTES="$3"
TITLE="${4:-RayLink Engine, dev-сборка $VERSION}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+$ ]] || refuse "the version is <N>.<M>, not '$VERSION'"
[ -s "$EXE" ] || refuse "no engine exe at '$EXE'"
[ "$(basename "$EXE")" = AnomalyCoopDX11AVX.exe ] || refuse "the asset is AnomalyCoopDX11AVX.exe, as in every b<N>, not '$(basename "$EXE")'"
[ -s "$NOTES" ] || refuse "no notes at '$NOTES'"

gh release create "dev-$VERSION" "$EXE" --prerelease --latest=false --repo "$REPO" --title "$TITLE" --notes-file "$NOTES"
echo "published: https://github.com/$REPO/releases/tag/dev-$VERSION"
