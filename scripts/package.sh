#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$PROJECT_ROOT"

CONFIGURATION="${CONFIGURATION:-release}"
VARIANT="dev"

for arg in "$@"; do
  case "$arg" in
    --dev) VARIANT="dev" ;;
    --shipped) VARIANT="shipped" ;;
    *)
      echo "Usage: $0 [--dev|--shipped]" >&2
      exit 1
      ;;
  esac
done

case "$VARIANT" in
  dev)
    APP_NAME="Harnais Dev"
    IDENTIFIER="com.jean.harnais.dev"
    EXECUTABLE_NAME="HarnaisDev"
    ;;
  shipped)
    APP_NAME="Harnais"
    IDENTIFIER="com.jean.harnais"
    EXECUTABLE_NAME="Harnais"
    ;;
esac

FINAL_APP="$PROJECT_ROOT/dist/${APP_NAME}.app"
STAGE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/Harnais-package.XXXXXX")"
STAGED_APP="$STAGE_ROOT/${APP_NAME}.app"
cleanup() {
  [[ "$STAGE_ROOT" == *"/Harnais-package."* ]] && /bin/rm -rf "$STAGE_ROOT"
}
trap cleanup EXIT
ENTITLEMENTS="$PROJECT_ROOT/Sources/HarnaisCore/Harnais.entitlements"
ICON="$PROJECT_ROOT/Sources/HarnaisCore/Resources/Harnais.icns"

echo "Building Harnais (${CONFIGURATION}, ${VARIANT})..."
swift build -c "$CONFIGURATION" --product HarnaisApp
swift build -c "$CONFIGURATION" --product harnais
BINARY_DIRECTORY="$(swift build -c "$CONFIGURATION" --show-bin-path)"
BINARY="$BINARY_DIRECTORY/HarnaisApp"
CLI_BINARY="$BINARY_DIRECTORY/harnais"
WHATSAPP_BINARY="$BINARY_DIRECTORY/harnais-whatsapp"
echo "Building the WhatsApp linked-device helper..."
(cd Helpers/WhatsAppBridge && go build -trimpath -o "$WHATSAPP_BINARY" .)
[[ -x "$BINARY" ]] || { echo "Missing executable: $BINARY" >&2; exit 1; }
[[ -x "$CLI_BINARY" ]] || { echo "Missing executable: $CLI_BINARY" >&2; exit 1; }

if [[ ! -f "$ICON" || "$PROJECT_ROOT/scripts/make-icon.sh" -nt "$ICON" || "$PROJECT_ROOT/scripts/render-icon.swift" -nt "$ICON" ]]; then
  "$PROJECT_ROOT/scripts/make-icon.sh"
fi

mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
install -m 0755 "$BINARY" "$STAGED_APP/Contents/MacOS/$EXECUTABLE_NAME"
install -m 0755 "$CLI_BINARY" "$STAGED_APP/Contents/MacOS/harnais"
install -m 0755 "$WHATSAPP_BINARY" "$STAGED_APP/Contents/MacOS/harnais-whatsapp"
install -m 0644 Sources/HarnaisCore/Info.plist "$STAGED_APP/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "$IDENTIFIER" "$STAGED_APP/Contents/Info.plist"
plutil -replace CFBundleName -string "$APP_NAME" "$STAGED_APP/Contents/Info.plist"
plutil -replace CFBundleDisplayName -string "$APP_NAME" "$STAGED_APP/Contents/Info.plist"
plutil -replace CFBundleExecutable -string "$EXECUTABLE_NAME" "$STAGED_APP/Contents/Info.plist"
if [[ -f "$ICON" ]]; then
  install -m 0644 "$ICON" "$STAGED_APP/Contents/Resources/Harnais.icns"
fi
install -m 0644 Sources/HarnaisCore/Resources/PrivacyInfo.xcprivacy "$STAGED_APP/Contents/Resources/PrivacyInfo.xcprivacy"
install -m 0644 LICENSE "$STAGED_APP/Contents/Resources/LICENSE.txt"
install -m 0644 THIRD_PARTY_NOTICES.md "$STAGED_APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
install -m 0644 Helpers/WhatsAppBridge/THIRD_PARTY_LICENSES.txt "$STAGED_APP/Contents/Resources/WhatsApp-licenses.txt"

# Copy SwiftPM resource bundles into Contents/Resources. SPM's generated
# Bundle.module looks next to the .app, which codesign rejects, so runtime
# lookup reads this copy instead.
MODULE_BUNDLE="$BINARY_DIRECTORY/Harnais_HarnaisCore.bundle"
if [[ -d "$MODULE_BUNDLE" ]]; then
  rm -rf "$STAGED_APP/Contents/Resources/Harnais_HarnaisCore.bundle"
  cp -R "$MODULE_BUNDLE" "$STAGED_APP/Contents/Resources/Harnais_HarnaisCore.bundle"
fi
INFRA_BUNDLE="$BINARY_DIRECTORY/Harnais_Infrastructure.bundle"
if [[ ! -d "$INFRA_BUNDLE" ]]; then
  INFRA_BUNDLE="$BINARY_DIRECTORY/Infrastructure_Infrastructure.bundle"
fi
if [[ ! -d "$INFRA_BUNDLE/iles-extension" ]]; then
  echo "Missing Iles extension bundle at $INFRA_BUNDLE" >&2
  exit 1
fi
rm -rf "$STAGED_APP/Contents/Resources/Harnais_Infrastructure.bundle"
cp -R "$INFRA_BUNDLE" "$STAGED_APP/Contents/Resources/Harnais_Infrastructure.bundle"

SIGNATURE="${SIGNING_IDENTITY:--}"
SIGN_ARGUMENTS=(--force --sign "$SIGNATURE")
if [[ "$SIGNATURE" != "-" ]]; then
  SIGN_ARGUMENTS+=(--options runtime --timestamp)
fi
for executable in harnais-whatsapp harnais; do
  codesign "${SIGN_ARGUMENTS[@]}" "$STAGED_APP/Contents/MacOS/$executable"
done
codesign "${SIGN_ARGUMENTS[@]}" --entitlements "$ENTITLEMENTS" "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP"

mkdir -p "$PROJECT_ROOT/dist"
PREVIOUS_APP="$STAGE_ROOT/previous.app"
if [[ -e "$FINAL_APP" ]]; then mv "$FINAL_APP" "$PREVIOUS_APP"; fi
if ! mv "$STAGED_APP" "$FINAL_APP"; then
  [[ -e "$PREVIOUS_APP" ]] && mv "$PREVIOUS_APP" "$FINAL_APP"
  exit 1
fi

echo "Packaged $FINAL_APP"
