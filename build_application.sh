#!/bin/zsh
# Builds "Local Dictation.app" into ./dist and installs it to ~/Applications, replacing any installed copy.
# Signs with the "Local Dictation Development" identity when it exists, so that macOS privacy grants survive rebuilds.
# Without that identity the script signs ad hoc.
set -euo pipefail
cd "${0:A:h}"
swift build -c release --product LocalDictation
application="dist/Local Dictation.app"
rm -rf "$application"
mkdir -p "$application/Contents/MacOS" "$application/Contents/Resources/Cues" "$application/Contents/Frameworks"
cp .build/release/LocalDictation "$application/Contents/MacOS/LocalDictation"
cp -R .build/release/LocalDictation_MoonRendering.bundle "$application/Contents/Resources/"
ditto .build/release/Sparkle.framework "$application/Contents/Frameworks/Sparkle.framework"
cp .build/artifacts/sparkle/Sparkle/LICENSE "$application/Contents/Resources/Sparkle-LICENSE"
cp Packaging/Info.plist "$application/Contents/Info.plist"
cp Packaging/NOTICE Packaging/LICENSE Packaging/FluidAudio-LICENSE Packaging/AppIcon.icns "$application/Contents/Resources/"
cp Packaging/Cues/Start.wav Packaging/Cues/Stop.wav "$application/Contents/Resources/Cues/"
identity=$(security find-identity -p codesigning | awk '/"Local Dictation Development"/ {print $2; exit}')
# Sparkle includes its installer, updater application, and XPC services inside the framework.
framework="$application/Contents/Frameworks/Sparkle.framework"
for service in "$framework"/Versions/B/XPCServices/*.xpc; do
  codesign --force --options runtime --timestamp=none --preserve-metadata=entitlements \
    --sign "${identity:--}" "$service"
done
codesign --force --options runtime --timestamp=none --sign "${identity:--}" "$framework/Versions/B/Autoupdate"
codesign --force --options runtime --timestamp=none --sign "${identity:--}" "$framework/Versions/B/Updater.app"
codesign --force --options runtime --timestamp=none --sign "${identity:--}" "$framework"
codesign --force --options runtime --timestamp=none --entitlements Packaging/LocalDictation.entitlements \
  --sign "${identity:--}" "$application"
codesign --verify --deep --strict "$application"
installed="$HOME/Applications/Local Dictation.app"
mkdir -p "$HOME/Applications"
rm -rf "$installed"
cp -R "$application" "$installed"
echo "Installed $installed (signed with ${identity:-ad hoc identity})"
