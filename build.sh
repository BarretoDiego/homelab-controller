#!/bin/zsh
# Builds everything into dist/:
#   Home Lab.app             universal app, with the host script, the host .deb and the artwork inside
#   Home-Lab-<v>.dmg         installer for people
#   Home-Lab-<v>.app.zip     what the in-app updater downloads
#   homelab-host_<v>_all.deb the host package (also built on its own by the release workflow)
#
#   ./build.sh            build, self-test, then install the app in "~/Desktop/Home Lab"
#   ./build.sh --ci       build and self-test only
#   ./build.sh <path>     build, self-test, install the app at <path>
#
# The app is ad-hoc signed, so every build has a new signature and macOS asks again for Keychain access.
set -euo pipefail
cd "${0:A:h}"
unset __CFBundleIdentifier   # tools started here must not borrow the identity of the app that ran this script
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
app="dist/Home Lab.app"
sources=(Core.swift SelfTest.swift Logic.swift Views.swift Wizard.swift MainWindow.swift Services.swift Network.swift Update.swift)

rm -rf dist
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" dist/obj
deb=$(python3 packaging/build-deb.py host/homelab-host.py dist)

# Artwork: assets/generated holds the originals; make-assets derives the icon, glyphs and DMG background.
swift packaging/make-assets.swift assets/generated assets/build >/dev/null
iconutil -c icns assets/build/AppIcon.iconset -o assets/build/AppIcon.icns
tiffutil -cathidpicheck assets/build/dmg-background.png assets/build/dmg-background@2x.png \
    -out assets/build/dmg-background.tiff >/dev/null 2>&1

for arch in arm64 x86_64; do
    swiftc -O -swift-version 5 -target "$arch-apple-macos14.0" -parse-as-library -o "dist/obj/HomeLab-$arch" $sources
done
lipo -create dist/obj/HomeLab-arm64 dist/obj/HomeLab-x86_64 -output "$app/Contents/MacOS/HomeLab"
rm -rf dist/obj

cp Info.plist "$app/Contents/Info.plist"
cp host/homelab-host.py "$app/Contents/Resources/homelab-host.py"
cp "$deb" "$app/Contents/Resources/homelab-host.deb"
cp assets/build/AppIcon.icns assets/build/menubar*.png "$app/Contents/Resources/"
for hero in assets/generated/hero-*.png; do
    sips -Z 720 "$hero" --out "$app/Contents/Resources/${hero:t}" >/dev/null
done
codesign --force --sign - "$app"
"$app/Contents/MacOS/HomeLab" selftest

# DMG with the styled window (dmgbuild writes the Finder layout without scripting Finder).
[[ -x packaging/.venv/bin/dmgbuild ]] || { python3 -m venv packaging/.venv && packaging/.venv/bin/pip install -q dmgbuild; }
dmg="dist/Home-Lab-$version.dmg"
packaging/.venv/bin/dmgbuild -s packaging/dmg-settings.py \
    -D app="$PWD/$app" -D readme="$PWD/packaging/LEIA-ME.txt" \
    -D icon="$PWD/assets/build/AppIcon.icns" -D background="$PWD/assets/build/dmg-background.tiff" \
    "Home Lab $version" "$dmg" >/dev/null
ditto -c -k --keepParent "$app" "dist/Home-Lab-$version.app.zip"

echo "app: ${0:A:h}/$app"
echo "dmg: ${0:A:h}/$dmg"
echo "zip: ${0:A:h}/dist/Home-Lab-$version.app.zip"
echo "deb: ${0:A:h}/$deb"
[[ "${1:-}" == "--ci" ]] && exit 0
dest="${1:-$HOME/Desktop/Home Lab/Home Lab.app}"
rm -rf "$dest"
cp -R "$app" "$dest"
echo "installed: $dest"
