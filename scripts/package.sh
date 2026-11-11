#!/bin/zsh
# Builds a release binary and wraps it in dist/SOPS Vault.app (ad-hoc signed).
set -euo pipefail
cd "${0:A:h}/.."

# Release builds get VERSION from the updater; local builds use the newest tag, or 0.0.0.
VERSION="${VERSION:-$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null | sed 's/^v//')}"
VERSION="${VERSION:-0.0.0}"
APP="dist/SOPS Vault.app"
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

swift build -c release --product SOPSVault
BIN="$(swift build -c release --show-bin-path)/SOPSVault"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SOPSVault"

# Localizations live in the app bundle so SwiftUI and String(localized:) find them via Bundle.main.
cp -R Localization/*.lproj "$APP/Contents/Resources/"

swift scripts/make-icon.swift "$BUILD_DIR/AppIcon.iconset"
iconutil -c icns "$BUILD_DIR/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>SOPS Vault</string>
  <key>CFBundleDisplayName</key><string>SOPS Vault</string>
  <key>CFBundleIdentifier</key><string>io.github.jsred.sops-vault</string>
  <key>CFBundleExecutable</key><string>SOPSVault</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>es</string></array>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>SOPS references</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>None</string>
      <key>LSItemContentTypes</key>
      <array><string>public.folder</string><string>public.data</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

codesign --force --deep --sign - --options runtime "$APP"
codesign --verify --strict --verbose=2 "$APP"
echo "Built $APP"
