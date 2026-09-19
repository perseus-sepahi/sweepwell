#!/bin/bash
# Builds a throwaway "home folder" full of realistic junk, so every Sweepwell feature
# (including the destructive ones) can be tried without touching real files:
#
#   scripts/make-demo-home.sh /tmp/sweepwell-demo
#   SWEEPWELL_HOME=/tmp/sweepwell-demo open -n dist/Sweepwell.app
set -euo pipefail

HOME_DIR="${1:?usage: make-demo-home.sh <folder>}"
rm -rf "$HOME_DIR"
mkdir -p "$HOME_DIR"
cd "$HOME_DIR"

blob() { # blob <path> <megabytes>
    mkdir -p "$(dirname "$1")"
    dd if=/dev/urandom of="$1" bs=1m count="$2" status=none
}

app() { # app <path> <bundle id> <name> <megabytes>
    mkdir -p "$1/Contents/MacOS"
    cat > "$1/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$2</string>
<key>CFBundleName</key><string>$3</string>
<key>CFBundleShortVersionString</key><string>4.2</string>
</dict></plist>
EOF
    blob "$1/Contents/MacOS/$3" "$4"
}

mkdir -p Desktop Documents Downloads Movies Music Pictures Library/Caches Library/Logs .Trash

# System junk
blob "Library/Caches/com.vendor.photoeditor/thumbnails.db" 180
blob "Library/Caches/com.vendor.musicplayer/artwork.cache" 95
blob "Library/Caches/com.browser.web/Cache/data_1" 240
blob "Library/Caches/Homebrew/downloads/llvm-19.tar.gz" 310
blob "Library/Caches/pip/http/wheels.bin" 60
blob ".npm/_cacache/content-v2/sha512/blob" 140
blob "Library/Logs/DiagnosticReports/PhotoEditor-2026-08-30.ips" 2
blob "Library/Logs/MusicPlayer/player.log" 14
blob "Library/Developer/Xcode/DerivedData/Talebright-gxkqvvnbzjwsfa/Build/Products/app.o" 420
blob "Library/Developer/Xcode/DerivedData/Grabbit-bhdqwpxnmzlrtc/Build/Products/app.o" 260
blob "Library/Developer/Xcode/iOS DeviceSupport/iPhone17,1 26.0 (24A335)/Symbols/dyld.cache" 380
blob "Library/Developer/Xcode/Archives/2026-07-04/Talebright.xcarchive/Products/app" 90
blob "Library/Application Support/MobileSync/Backup/00008140-000A1C/Manifest.db" 210
blob "Downloads/ubuntu-26.04-desktop.iso.crdownload" 330
blob ".Trash/old-presentation.key" 75
blob ".Trash/screen recording.mov" 160

# Large & old files, some of them duplicated
blob "Movies/Holiday 2023 raw footage.mov" 640
blob "Documents/Thesis/wrfout_d01_2009-07-01.nc" 520
blob "Downloads/Xcode_26.xip" 410
blob "Documents/Backups/site-backup-2024.zip" 150
touch -a -t 202401150900 "Documents/Backups/site-backup-2024.zip" "Movies/Holiday 2023 raw footage.mov"
cp "Documents/Backups/site-backup-2024.zip" "Downloads/site-backup-2024 (1).zip"
cp "Documents/Backups/site-backup-2024.zip" "Desktop/site-backup copy.zip"
blob "Pictures/Scans/passport-scan.tiff" 12
cp "Pictures/Scans/passport-scan.tiff" "Documents/passport-scan.tiff"
for i in 1 2 3 4 5 6; do blob "Documents/Projects/notes-$i.pdf" 1; done

# Applications and their leftovers
app "Applications/Photo Editor.app" com.vendor.photoeditor "Photo Editor" 220
app "Applications/Music Player.app" com.vendor.musicplayer "Music Player" 85
app "Applications/Old Game.app" com.studio.oldgame "Old Game" 730
blob "Library/Application Support/Photo Editor/Presets/presets.db" 45
blob "Library/Application Support/Old Game/Saves/slot1.sav" 130
blob "Library/Containers/com.studio.oldgame/Data/cache.bin" 55
mkdir -p Library/Preferences "Library/Saved Application State/com.vendor.photoeditor.savedState" Library/LaunchAgents
echo prefs > Library/Preferences/com.vendor.photoeditor.plist
echo prefs > Library/Preferences/com.studio.oldgame.plist
echo state > "Library/Saved Application State/com.vendor.photoeditor.savedState/windows.plist"

# Background items: one healthy, one orphaned by an app that is long gone
agent() { # agent <label> <program>
    cat > "Library/LaunchAgents/$1.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$1</string>
<key>ProgramArguments</key><array><string>$2</string></array>
<key>RunAtLoad</key><true/>
</dict></plist>
EOF
}
agent com.vendor.musicplayer.helper "$HOME_DIR/Applications/Music Player.app/Contents/MacOS/Music Player"
agent com.removedapp.updater "/Applications/Removed App.app/Contents/MacOS/updater"

echo "Demo home ready: $HOME_DIR ($(du -sh "$HOME_DIR" | cut -f1))"
