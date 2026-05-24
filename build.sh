#!/bin/bash
set -euo pipefail

APP_NAME="ImperatorEQ"
BUILD_DIR=".build"
APP_BUNDLE="Imperator EQ.app"

echo "Building ${APP_NAME}..."
swift build -c release 2>&1

echo "Creating app bundle..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cp "${BUILD_DIR}/release/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/"
cp "Resources/Info.plist" "${APP_BUNDLE}/Contents/"

echo "Signing app bundle..."
codesign --sign - --force --deep "${APP_BUNDLE}"

echo "Installing to /Applications..."
rm -rf "/Applications/${APP_BUNDLE}"
cp -R "${APP_BUNDLE}" "/Applications/${APP_BUNDLE}"

echo ""
echo "Build complete: /Applications/${APP_BUNDLE}"
echo "Run with: open '/Applications/${APP_BUNDLE}'"
