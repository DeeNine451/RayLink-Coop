#!/usr/bin/env bash
# A build for the launcher's Dev channel: prerelease dev-<N>.<M> of stormie-labs/RayLink-Coop. Needs `gh auth login` first.
#   bash tools/publish_dev.sh <N>.<M> <anomaly-coop-*.zip> <notes-file> [title]
# The launcher takes the newest prerelease whose tag starts with dev- and holds it to the rules of a stable release: exactly
# one anomaly-coop-*.zip. Stable players see nothing: Latest stays on the last b<N>. The engine exe of the same build goes
# out with tools/publish_dev_engine.sh. A tag that does not exist yet is made by GitHub on the default branch.
set -euo pipefail
export GH_HOST=github.com
REPO=stormie-labs/RayLink-Coop

refuse() { echo "! $1. Nothing was published." >&2; exit 2; }

for arg in "$@"; do
	case "$arg" in --latest*|--prerelease=*) refuse "a dev build is a prerelease and is never marked Latest" ;; esac
done
[ "$#" -eq 3 ] || [ "$#" -eq 4 ] || refuse "usage: bash tools/publish_dev.sh <N>.<M> <anomaly-coop-*.zip> <notes-file> [title]"
VERSION="$1"
ZIP="$2"
NOTES="$3"
TITLE="${4:-Dev-сборка $VERSION}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+$ ]] || refuse "the version is <N>.<M>, not '$VERSION'"
[ -s "$ZIP" ] || refuse "no zip at '$ZIP'"
case "$(basename "$ZIP")" in
	anomaly-coop-*.zip) ;;
	*) refuse "the launcher takes only anomaly-coop-*.zip, not '$(basename "$ZIP")'" ;;
esac
[ -s "$NOTES" ] || refuse "no notes at '$NOTES'"

gh release create "dev-$VERSION" "$ZIP" --prerelease --latest=false --repo "$REPO" --title "$TITLE" --notes-file "$NOTES"
echo "published: https://github.com/$REPO/releases/tag/dev-$VERSION"
