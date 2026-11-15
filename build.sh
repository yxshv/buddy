#!/bin/bash
# Builds Buddy.app into ./build. Usage: ./build.sh [--install]  (--install copies it to /Applications)
set -euo pipefail
cd "$(dirname "$0")"

# Personal settings (bundle ID, signing identity, folders, site): local.env, gitignored.
# Copy local.env.example to start. Shell variables already set win over the file.
CONFIG_KEYS=(BUDDY_CF BUDDY_CS BUDDY_PROJECTS BUDDY_PUBLISHER BUDDY_SITE_URL)
if [[ -f local.env ]]; then
  while IFS='=' read -r key value; do
    [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
    value="${value%\"}"; value="${value#\"}"
    [[ -z "${!key:-}" ]] && export "$key=$value"
  done < local.env
fi
BUNDLE_ID="${BUDDY_BUNDLE_ID:-local.buddy}"

APP=build/Buddy.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp kokoro_server.py "$APP/Contents/Resources/"
mkdir -p "$APP/Contents/Resources/canvas"
cp -R canvas/canvas.html canvas/canvas.css canvas/canvas.js canvas/markdown.js canvas/text.css \
  canvas/reply.html canvas/chats.html canvas/settings.html canvas/cards.css canvas/cards.js canvas/katex "$APP/Contents/Resources/canvas/"
# Built-in features (features/README.md): folders of feature.json + a script, read at run time.
rm -rf "$APP/Contents/Resources/features"
cp -R features "$APP/Contents/Resources/features"
# SF Symbols for result cards, rendered as PNG masks (tools/symbols.swift).
swift tools/symbols.swift "$APP/Contents/Resources/canvas/symbols"

# The hashes of the built-in features, compiled in: the app trusts exactly these (Features.swift).
GEN=build/generated
mkdir -p "$GEN"
cp tools/feature-hashes.swift "$GEN/main.swift" # top-level code must be in main.swift when compiled with another file
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos14.0" Sources/FeatureHash.swift "$GEN/main.swift" -o "$GEN/feature-hashes"
"$GEN/feature-hashes" features > "$GEN/BuiltinFeatures.swift"

swiftc -O -swift-version 5 \
  -target "$(uname -m)-apple-macos14.0" \
  Sources/*.swift "$GEN/BuiltinFeatures.swift" \
  -o "$APP/Contents/MacOS/Buddy"

cp Info.plist "$APP/Contents/Info.plist"
PLIST="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$PLIST"
# Folders and the site URL, read at run time by Sources/Config.swift.
/usr/libexec/PlistBuddy -c "Add :BuddyConfig dict" "$PLIST"
for key in "${CONFIG_KEYS[@]}"; do
  [[ -n "${!key:-}" ]] && /usr/libexec/PlistBuddy -c "Add :BuddyConfig:$key string ${!key}" "$PLIST"
done

# The `buddy` CLI (tools/buddy.swift): a thin client that forwards commands to the running app.
# Named buddy-cli inside the bundle because Contents/MacOS/Buddy already exists on a case-insensitive disk.
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos14.0" tools/buddy.swift -o "$APP/Contents/MacOS/buddy-cli"

# Sign with a real certificate so macOS keeps Buddy's permissions (Microphone, Screen Recording,
# Accessibility) across rebuilds. Ad-hoc signatures change every build and reset them.
# Override with BUDDY_SIGN_ID=<name or SHA-1>; falls back to ad-hoc if no certificate is found.
SIGN_ID="${BUDDY_SIGN_ID:-$(security find-identity -p codesigning | awk -F'"' '/"(Buddy|Apple Development)/ {print $2; exit}')}"
codesign --force --sign "${SIGN_ID:--}" --identifier "$BUNDLE_ID.cli" --options runtime "$APP/Contents/MacOS/buddy-cli"
# Hardened runtime: nothing can inject code into Buddy (it holds the key that signs its settings).
# The microphone needs its entitlement under it.
codesign --force --sign "${SIGN_ID:--}" --identifier "$BUNDLE_ID" --options runtime \
  --entitlements Buddy.entitlements "$APP"
echo "Built $APP (signed with: ${SIGN_ID:-ad-hoc})"

if [[ "${1:-}" == "--install" ]]; then
  rm -rf /Applications/Buddy.app
  cp -R "$APP" /Applications/
  echo "Installed to /Applications/Buddy.app"
  # Put `buddy` on PATH (~/.local/bin is where the claude CLI lives too).
  mkdir -p "$HOME/.local/bin"
  ln -sf /Applications/Buddy.app/Contents/MacOS/buddy-cli "$HOME/.local/bin/buddy"
  echo "Linked ~/.local/bin/buddy"
fi
