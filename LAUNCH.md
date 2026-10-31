# Sweepwell launch

| | |
|---|---|
| Version | 1.0 (macOS 26+, Apple silicon) |
| Bundle ID | com.williamsepahi.Sweepwell |
| Price | 7-day trial, then US$1.99 once (Stripe) |
| Stripe | Live account acct_1UJb6jIHG7uC8Ovc, product prod_VXXXAUAzrAkZot; payment link not created yet |
| Licence service | Tools/LicenceWorker, Worker sweepwell-licence, KV created, not deployed yet |
| Signing key | ~/.sweepwell/licence-signing-key.json (never in a repo) |
| GitHub | perseus-sepahi/sweepwell (private source), perseus-sepahi/sweepwell-app (public releases): not created yet |
| Website | content/software/sweepwell.json written, not pushed |
| App Store | Not possible for this edition: it needs the App Sandbox off. See below. |
| Discount codes | None created. Tools/discount_codes.py + launch.json (Stripe side only) |

## App Store

Apple requires the App Sandbox. A sandboxed build cannot reach other apps' caches and support files,
run launchctl, simctl or ps, or script Finder, so System Junk, Uninstaller, Storage Audit, Startup and
Maintenance would not work. An App Store edition would be a smaller product limited to folders the user
picks (Large Files, Duplicates, Space Lens, Shredder, menu bar readings), sold through In-App Purchase.
