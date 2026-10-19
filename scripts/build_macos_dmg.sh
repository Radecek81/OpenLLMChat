#!/usr/bin/env bash
set -euo pipefail

APP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWIFT_ROOT="${APP_ROOT}/swift-macos"
DIST_ROOT="${APP_ROOT}/dist/macos"
STAGE_ROOT="${DIST_ROOT}/dmg-root"
APP_NAME="Open LLM chat"
EXECUTABLE_NAME="LLMChatMac"
APP_BUNDLE="${DIST_ROOT}/${APP_NAME}.app"
LEGACY_APP_BUNDLE="${DIST_ROOT}/LLM Chat.app"
DMG_PATH="${DIST_ROOT}/llm-chat-macos.dmg"
ZIP_PATH="${DIST_ROOT}/open-llm-chat-macos.zip"
LEGACY_ZIP_PATH="${DIST_ROOT}/Open LLM chat.zip"
INSTALL_NOTE="${APP_ROOT}/INSTALL-macOS.txt"
LOGO_SOURCE="${SWIFT_ROOT}/Sources/LLMChatMac/Resources/logo.png"

mkdir -p "${DIST_ROOT}"
rm -rf "${APP_BUNDLE}" "${LEGACY_APP_BUNDLE}" "${STAGE_ROOT}" "${DMG_PATH}" "${ZIP_PATH}" "${LEGACY_ZIP_PATH}"

if [[ "${MACOS_SKIP_SWIFT_BUILD:-false}" != "true" ]]; then
  swift build -c release --package-path "${SWIFT_ROOT}"
fi

ARCH="$(uname -m)"
BINARY_PATH="${SWIFT_ROOT}/.build/${ARCH}-apple-macosx/release/${EXECUTABLE_NAME}"
RESOURCE_BUNDLE_PATH="${SWIFT_ROOT}/.build/${ARCH}-apple-macosx/release/${EXECUTABLE_NAME}_${EXECUTABLE_NAME}.bundle"

if [[ ! -f "${BINARY_PATH}" ]]; then
  BINARY_PATH="$(find "${SWIFT_ROOT}/.build" -path "*/release/${EXECUTABLE_NAME}" -type f | head -n 1)"
fi
if [[ ! -d "${RESOURCE_BUNDLE_PATH}" ]]; then
  RESOURCE_BUNDLE_PATH="$(find "${SWIFT_ROOT}/.build" -path "*/release/${EXECUTABLE_NAME}_${EXECUTABLE_NAME}.bundle" -type d | head -n 1)"
fi

if [[ -z "${BINARY_PATH}" ]]; then
  echo "Nepodarilo se najit release binarku ${EXECUTABLE_NAME}."
  exit 1
fi

mkdir -p "${APP_BUNDLE}/Contents/MacOS" "${APP_BUNDLE}/Contents/Resources"
cp "${BINARY_PATH}" "${APP_BUNDLE}/Contents/MacOS/${EXECUTABLE_NAME}"
chmod +x "${APP_BUNDLE}/Contents/MacOS/${EXECUTABLE_NAME}"
cp "${APP_ROOT}/LICENSE" "${APP_BUNDLE}/Contents/Resources/LICENSE"
cp "${APP_ROOT}/NOTICE" "${APP_BUNDLE}/Contents/Resources/NOTICE"
cp "${APP_ROOT}/ADDITIONAL_TERMS.md" "${APP_BUNDLE}/Contents/Resources/ADDITIONAL_TERMS.md"
cp "${APP_ROOT}/THIRD_PARTY_NOTICES.md" "${APP_BUNDLE}/Contents/Resources/THIRD_PARTY_NOTICES.md"
if [[ -n "${RESOURCE_BUNDLE_PATH}" && -d "${RESOURCE_BUNDLE_PATH}" ]]; then
  cp -R "${RESOURCE_BUNDLE_PATH}" "${APP_BUNDLE}/Contents/Resources/"
fi

cat > "${APP_BUNDLE}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>cs</string>
  <key>CFBundleExecutable</key>
  <string>LLMChatMac</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>cz.uberit.llmchat.swift</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleDisplayName</key>
  <string>Open LLM chat</string>
  <key>CFBundleName</key>
  <string>Open LLM chat</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>3.0</string>
  <key>CFBundleVersion</key>
  <string>4</string>
  <key>NSHumanReadableCopyright</key>
  <string>Copyright © 2026 Uberit s.r.o. Licensed under AGPL-3.0.</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>Open LLM chat uses the microphone only when you start push-to-talk transcription.</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

printf 'APPL????' > "${APP_BUNDLE}/Contents/PkgInfo"

if command -v sips >/dev/null 2>&1 && command -v iconutil >/dev/null 2>&1; then
  ICONSET_DIR="${DIST_ROOT}/AppIcon.iconset"
  rm -rf "${ICONSET_DIR}"
  mkdir -p "${ICONSET_DIR}"
  sips -z 16 16 "${LOGO_SOURCE}" --out "${ICONSET_DIR}/icon_16x16.png" >/dev/null
  sips -z 32 32 "${LOGO_SOURCE}" --out "${ICONSET_DIR}/icon_16x16@2x.png" >/dev/null
  sips -z 32 32 "${LOGO_SOURCE}" --out "${ICONSET_DIR}/icon_32x32.png" >/dev/null
  sips -z 64 64 "${LOGO_SOURCE}" --out "${ICONSET_DIR}/icon_32x32@2x.png" >/dev/null
  sips -z 128 128 "${LOGO_SOURCE}" --out "${ICONSET_DIR}/icon_128x128.png" >/dev/null
  sips -z 256 256 "${LOGO_SOURCE}" --out "${ICONSET_DIR}/icon_128x128@2x.png" >/dev/null
  sips -z 256 256 "${LOGO_SOURCE}" --out "${ICONSET_DIR}/icon_256x256.png" >/dev/null
  sips -z 512 512 "${LOGO_SOURCE}" --out "${ICONSET_DIR}/icon_256x256@2x.png" >/dev/null
  sips -z 512 512 "${LOGO_SOURCE}" --out "${ICONSET_DIR}/icon_512x512.png" >/dev/null
  sips -z 1024 1024 "${LOGO_SOURCE}" --out "${ICONSET_DIR}/icon_512x512@2x.png" >/dev/null
  if ! iconutil -c icns "${ICONSET_DIR}" -o "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"; then
    echo "Varovani: nepodarilo se vygenerovat AppIcon.icns, pokracuji bez vlastni ikony."
    rm -f "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
  fi
  rm -rf "${ICONSET_DIR}"
fi

SIGNING_IDENTITY="${MACOS_SIGNING_IDENTITY:--}"
if [[ "${SIGNING_IDENTITY}" == "-" ]]; then
  codesign --force --deep --sign - "${APP_BUNDLE}"
else
  codesign --force --deep --options runtime --timestamp --sign "${SIGNING_IDENTITY}" "${APP_BUNDLE}"
fi
codesign --verify --deep --strict --verbose=2 "${APP_BUNDLE}"

ditto -c -k --sequesterRsrc --keepParent "${APP_BUNDLE}" "${ZIP_PATH}"

mkdir -p "${STAGE_ROOT}"
cp -R "${APP_BUNDLE}" "${STAGE_ROOT}/"
if [[ -f "${INSTALL_NOTE}" ]]; then
  cp "${INSTALL_NOTE}" "${STAGE_ROOT}/"
fi
cp "${APP_ROOT}/LICENSE" "${STAGE_ROOT}/"
cp "${APP_ROOT}/NOTICE" "${STAGE_ROOT}/"
cp "${APP_ROOT}/ADDITIONAL_TERMS.md" "${STAGE_ROOT}/"
cp "${APP_ROOT}/THIRD_PARTY_NOTICES.md" "${STAGE_ROOT}/"
ln -s /Applications "${STAGE_ROOT}/Applications"

hdiutil create \
  -volname "${APP_NAME}" \
  -srcfolder "${STAGE_ROOT}" \
  -ov \
  -format UDZO \
  "${DMG_PATH}" >/dev/null

echo "Vytvoreno: ${APP_BUNDLE}"
echo "Vytvoreno: ${DMG_PATH}"
echo "Vytvoreno: ${ZIP_PATH}"
