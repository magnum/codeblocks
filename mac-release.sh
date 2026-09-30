#!/bin/bash
# Sign dist/CodeBlocks.app with a Developer ID certificate, notarize it,
# staple the ticket and publish the zip as a GitHub release.
#
# Prerequisites:
#   - ./mac-build.sh has produced dist/CodeBlocks.app
#   - A "Developer ID Application" certificate in the login keychain
#   - A notarytool keychain profile (default name: notary-codeblocks)
#       xcrun notarytool store-credentials "notary-codeblocks" \
#         --apple-id "you@example.com" --team-id "TEAMID"
#   - gh authenticated: gh auth login
#
# Overrides: APP, SIGN_ID, NOTARY_PROFILE, REPO, TAG, VERSION

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="${APP:-$ROOT/dist/CodeBlocks.app}"
VERSION="${VERSION:-25.03}"
TAG="${TAG:-${VERSION}-arm64}"
NOTARY_PROFILE="${NOTARY_PROFILE:-notary-codeblocks}"
ZIP="$ROOT/dist/CodeBlocks-${VERSION}-arm64.zip"

if [[ ! -d "$APP" ]]; then
	echo "App not found: $APP" >&2
	echo "Run ./mac-build.sh first." >&2
	exit 1
fi

if [[ -z "${SIGN_ID:-}" ]]; then
	SIGN_ID="$(security find-identity -v -p codesigning \
		| sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' \
		| head -1)"
fi
if [[ -z "${SIGN_ID:-}" ]]; then
	echo "No Developer ID Application certificate found. Set SIGN_ID=..." >&2
	exit 1
fi

if [[ -z "${REPO:-}" ]]; then
	origin="$(git -C "$ROOT" remote get-url origin 2>/dev/null || true)"
	REPO="${origin%.git}"
	REPO="${REPO#git@github.com:}"
	REPO="${REPO#https://github.com/}"
	REPO="${REPO#ssh://git@github.com/}"
fi
if [[ -z "${REPO:-}" || "$REPO" != */* ]]; then
	echo "Cannot tell the GitHub repo. Set REPO=owner/name" >&2
	exit 1
fi

WORK="/tmp/CodeBlocks.app"
rm -rf "$WORK"
ditto "$APP" "$WORK"
xattr -cr "$WORK"

sign() {
	codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$@"
}

echo "Signing with: $SIGN_ID"
# Nested code first. The app bundle must be signed last, or its seal is stale.
while IFS= read -r -d '' lib; do
	sign "$lib" || exit 1
done < <(find "$WORK/Contents" -type f -name '*.dylib' -print0)

sign \
	"$WORK/Contents/MacOS/cb_console_runner" \
	"$WORK/Contents/MacOS/cb_share_config"
sign "$WORK"

echo "Verifying signature"
codesign --verify --strict --verbose=2 "$WORK"

mkdir -p "$ROOT/dist"
rm -f "$ZIP"
ditto -c -k --keepParent "$WORK" "$ZIP"

echo "Notarizing $ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

echo "Stapling notarization ticket"
xcrun stapler staple "$WORK"
rm -f "$ZIP"
ditto -c -k --keepParent "$WORK" "$ZIP"

NOTES="$(cat << EOF
Build arm64, firmata con Developer ID e notarizzata.

Scarica lo zip, aprilo e trascina CodeBlocks.app in Applicazioni.
Solo Mac Apple Silicon. Per compilare i programmi serve Xcode o gli strumenti a riga di comando.
EOF
)"

echo "Publishing $TAG on $REPO"
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
	gh release upload "$TAG" --repo "$REPO" --clobber "$ZIP"
else
	gh release create "$TAG" \
		--repo "$REPO" \
		--title "Code::Blocks ${VERSION} per Apple Silicon" \
		--notes "$NOTES" \
		"$ZIP"
fi

echo "Release asset: $ZIP"
