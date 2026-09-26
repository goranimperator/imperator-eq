#!/bin/bash
set -euo pipefail

APP_NAME="ImperatorEQ"
APP_BUNDLE="Imperator EQ.app"

# AppKit picks which generation of a control to draw from the sdk field in the
# binary's LC_BUILD_VERSION. SwiftPM stamps that field with the deployment
# target, so without this the app would draw macOS 14 era controls forever.
# Stamping it here keeps the minimum at 14.2, the first release with Core Audio
# process taps, while drawing current controls. Keep it equal to platforms: in
# Package.swift.
MIN_MACOS="14.2"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"

# The minimum lives in three files. A mismatch ships a binary that launches on a
# macOS it does not support, or refuses one it does, so the build stops instead.
PLIST_MIN="$(plutil -extract LSMinimumSystemVersion raw Resources/Info.plist)"
if [ "${PLIST_MIN}" != "${MIN_MACOS}" ] || ! grep -q "\.macOS(\"${MIN_MACOS}\")" Package.swift; then
    echo "error: MIN_MACOS ${MIN_MACOS}, Info.plist ${PLIST_MIN} and Package.swift platforms must agree." >&2
    exit 1
fi

# Intel Macs run macOS 14.2 and later too, so the app is built universal rather
# than inheriting whichever architecture the build machine happens to be.
ARCHS=(--arch arm64 --arch x86_64)

# An ad-hoc signature's designated requirement is the cdhash, which changes on
# every build, so macOS treats each update as a different app and drops its TCC
# grants. This app needs the System Audio Recording grant to read its process
# tap, and re-granting it on every update is not acceptable. Signing with the
# stable self-signed identity pins the requirement to the certificate instead.
SIGN_IDENTITY="${IMPERATOR_SIGN_IDENTITY:-Imperator Dev}"

echo "Building ${APP_NAME}..."
swift build -c release "${ARCHS[@]}" \
    -Xlinker -platform_version \
    -Xlinker macos \
    -Xlinker "${MIN_MACOS}" \
    -Xlinker "${SDK_VERSION}" 2>&1

BIN_PATH="$(swift build -c release "${ARCHS[@]}" --show-bin-path)"

echo "Creating app bundle..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cp "${BIN_PATH}/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/"
cp "Resources/Info.plist" "${APP_BUNDLE}/Contents/"
cp "Resources/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/"

echo "Signing app bundle as '${SIGN_IDENTITY}'..."
if ! security find-identity -v -p codesigning | grep -q "${SIGN_IDENTITY}"; then
    echo "error: codesigning identity '${SIGN_IDENTITY}' not found in the keychain." >&2
    echo "Set IMPERATOR_SIGN_IDENTITY to an identity you have, or '-' for ad-hoc." >&2
    echo "Ad-hoc drops the System Audio Recording grant on every update." >&2
    exit 1
fi
codesign --sign "${SIGN_IDENTITY}" --force "${APP_BUNDLE}"

echo "Installing to /Applications..."
rm -rf "/Applications/${APP_BUNDLE}"
cp -R "${APP_BUNDLE}" "/Applications/${APP_BUNDLE}"

echo ""
echo "Build complete: /Applications/${APP_BUNDLE}"
echo "Run with: open '/Applications/${APP_BUNDLE}'"
