#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -z "${SIGNING_IDENTITY:-}" ]]; then
  SIGNING_IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)"
fi
export SIGNING_IDENTITY
: "${NOTARY_PROFILE:?Set the name of a notarytool Keychain profile}"
[[ "$SIGNING_IDENTITY" == 'Developer ID Application:'* ]] || { echo 'Developer ID Application identity required.' >&2; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Sources/HarnaisCore/Info.plist)"
[[ "$(git describe --tags --exact-match 2>/dev/null || true)" == "v$VERSION" ]] || { echo "Release from tag v$VERSION." >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo 'Commit changes before releasing.' >&2; exit 1; }
[[ -s Sources/Infrastructure/Resources/official-oauth-clients.json ]] || {
  echo 'The protected release build must inject its native OAuth catalog.' >&2
  exit 1
}
python3 scripts/check-public-release.py
./scripts/test.sh
(cd Helpers/WhatsAppBridge && go test ./...)
./scripts/package.sh --shipped
APP="$PWD/dist/Harnais.app"
ARCHIVE="$PWD/dist/Harnais-$VERSION-$(uname -m).zip"
WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/Harnais-release.XXXXXX")"
trap '[[ "$WORK_ROOT" == *"/Harnais-release."* ]] && rm -rf "$WORK_ROOT"' EXIT
codesign --verify --deep --strict "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$WORK_ROOT/submission.zip"
xcrun notarytool submit "$WORK_ROOT/submission.zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
(cd dist && shasum -a 256 "${ARCHIVE:t}" > "${ARCHIVE:t}.sha256")
echo "Release artifact: $ARCHIVE"
