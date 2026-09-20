# Sweepwell

A native Apple silicon Mac cleaner and maintenance app, built with SwiftUI.
(Working title was "Mac Maid"; that name is already used by other Mac cleaners.)

| Module | What it does |
| --- | --- |
| Overview | Live CPU, memory, storage and battery gauges; one-button Smart Scan |
| System Junk | App caches, logs, Xcode build data, developer tool caches, incomplete downloads, Mail downloads, Trash |
| Large & Old Files | Files over a threshold in your personal folders, filterable by size and last-opened date |
| Duplicates | Byte-for-byte identical files (size, then 64 KB hash, then full SHA-256) |
| Space Lens | Squarified treemap of any folder, with drill-down |
| Uninstaller | Removes an app together with its `~/Library` support files |
| Startup & Activity | Launch agents and daemons (flags broken ones), top memory consumers |
| Maintenance | Flush DNS, free inactive memory, thin snapshots, rebuild Spotlight, reset Quick Look, and more |

Also: a menu bar monitor, a settings window (⌘,), and day and night themes. **Auto** (the default)
follows the macOS appearance; the switch at the bottom of the sidebar forces Day or Night.

## Menu bar panel and glass

Clicking the ✦ menu bar icon opens a summary: a health score, storage, memory pressure, battery
(with capacity and cycle count), processor load and temperature, network throughput, connected
drives with eject, and one suggestion based on what Sweepwell has found locally. Click a tile
(Storage, Memory, Battery, Processor, Network) for the apps behind the number, helpers rolled
into their app, with Quit on hover. There is no
speed test or update check, because Sweepwell makes no network connections.

The **Glass** slider (sidebar and Settings) runs from solid cards to Liquid Glass. It needs
macOS 26 or later for real glass; older systems get a material-based approximation. The panel
always stays frosted, because unblurred glass over other windows' text is unreadable.

## Always there

Sweepwell opens at login (on by default once it lives in an Applications folder; toggle in
Settings → Startup, or in System Settings → General → Login Items) and starts quietly in the
menu bar. Closing the window leaves the ✦ menu bar icon running without a Dock icon; the power
button in the menu bar panel (or ⌘Q) stops it. `Sweepwell --login-item-status` prints what macOS has on file.

## Safety model

- Removal goes to the **Trash by default** (Settings can switch to immediate deletion).
- Scanners only *offer* items. A separate `SafetyGuard` decides what may be *removed*, from the
  resolved path alone, with a narrow allow-list per purpose. Documents, Desktop, Pictures,
  Keychains, iCloud Drive, Mail and similar are refused even if a scanner bug offered them,
  and a symlinked parent folder cannot redirect a removal.
- Risky finds (iOS backups, Xcode archives, caches of running apps) are listed but never pre-ticked.
- No network access, no account, no analytics. Administrator tasks use the standard macOS
  password dialog; Sweepwell never sees the password.

## Build and install

Requires Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
scripts/build-release.sh          # → dist/Sweepwell.app (arm64, ad-hoc signed)
ditto dist/Sweepwell.app /Applications/Sweepwell.app
open -a Sweepwell
```

Then grant **Full Disk Access** (System Settings → Privacy & Security) so scans can see the
Trash, Mail downloads and other apps' containers. Without it, scans are incomplete and the
first one is slow, because macOS evaluates every protected folder it refuses. An ad-hoc signed
build gets a new identity on every rebuild, so the grant has to be repeated after rebuilding.

## Trying it without touching real files

```bash
scripts/make-demo-home.sh /tmp/sweepwell-demo      # ~6 GB of fake junk, apps and duplicates
SWEEPWELL_HOME=/tmp/sweepwell-demo dist/Sweepwell.app/Contents/MacOS/Sweepwell
```

With `SWEEPWELL_HOME` set the app shows a "Demo folder" badge, only looks inside that folder,
and keeps trashed items in the folder's own `.Trash`. `SWEEPWELL_THEME=light|dark` forces a theme
for one launch without changing the saved choice.

## Layout

- `SweepwellKit/` – Swift package with all scanning and removal logic, plus tests (`swift test`).
  `SWEEPWELL_REAL_SCAN=~/Library swift test --filter RealWorldTests` compares the scanner with `du` (read-only).
- `Sweepwell/` – the SwiftUI app. `Tools/MakeAppIcon.swift` regenerates the icon.

## Not included

No malware scanner (that needs a maintained signature database to be honest), no privileged
helper (items owned by root are handed to Finder, which asks for a password), and no
notarization: share builds only after signing with a Developer ID.
