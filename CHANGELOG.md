# Changelog

All notable changes to this project will be documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/).

## [0.3.0] - 2026-11-05

### Added
- iCloud sync: the Mac publishes its snapshot and 7 days of history to a private CloudKit database, and iPhone, Apple Watch and their widgets read it from any network with nothing to pair.
- macOS: **Hub & Devices → iCloud** shows account, last publish and errors, turns sync off and deletes the stored data; the menu panel shows an iCloud status icon.
- iOS: silent push on every publish; the app opens straight to Home, with empty states for "Waiting for your Mac" and "Sign in to iCloud".
- iPhone and Watch show a banner when the newest snapshot is over 30 minutes old, since a Mac that stopped publishing produces no error.
- `iCloud account ID` (short hash) on Mac and iPhone to spot devices on different accounts.
- 53 unit tests for payloads, down-sampled history, publishing, source selection, widget refresh, settings migration and the entitlement check.

### Changed
- The hub is now optional for iPhone and Watch: QR pairing moved under Settings → Direct connection, and a paired hub is asked only when the iCloud copy is over 20 minutes old. Local scripts and device-log upload keep using it.
- macOS app uses Automatic signing because CloudKit needs a provisioning profile; `scripts/install.sh` passes `-allowProvisioningUpdates -allowProvisioningDeviceRegistration`. The hub token, API keys and data folder are unchanged.

### Fixed
- `gen-strings.py` failed on 4 missing translations left over from the `wholeDays` change.
- `ClaudeParsing.parsesKnownWindowsAndLimits` started failing on 2026-10-20: `ProviderSnapshot.primaryWindow` evaluated utilization at the real wall clock, so once the fixture's `seven_day` reset date passed both windows read 0 % and the first one won. Added `primaryWindow(now:)`; the tests pass their fixed clock.

## [0.2.1] - 2026-10-20

### Fixed
- macOS app crashed (`EXC_BREAKPOINT`, "Double value cannot be converted to Int") when the History tab showed a balance that had stopped moving, e.g. Codex credits after a top-up. The least-squares slope of a flat series is rounding noise (~1e-26/s), which became a "days remaining" of ~1e25. A balance now counts as spending only when the fitted line falls by more than 0.01 over the observed span, and every days-left label goes through the clamped `QuotaFormat.wholeDays`.
- `scripts/install.sh` swallowed a failed `xcodebuild` (`| grep … || true`) and went on to delete the installed app and copy an incomplete bundle over it. It now stops on a failed build, leaves the installed app untouched, and points at `security unlock-keychain` when codesign fails with `errSecInternalComponent` (typical over SSH).

## [0.2.0] - 2026-10-16

### Added
- Reset semantics per provider (`UsageWindow.resetSemantics`): Claude windows roll from the first request and read "Fresh · next window starts on first request" once expired; Codex windows roll forward by their fixed cadence. Forecast, pace and countdowns follow the semantics (6 new tests).
- macOS: first launch opens the main window with a dismissible "QuotaPulse lives in the menu bar" tip; "Show in Dock" toggle (General); `quotapulse://open?section=…` deep links.
- Codex: credits balance shown as credits (not dollars). When `secondary_window` is null the missing 5-hour row is kept as a grey `.notReported` placeholder ("Not reported by Codex API (known bug)") on Plus/Team/Business and fills in automatically once the API returns it; on Pro, which has no 5-hour window, it is `.notApplicable` and hidden. Forecast and pace only run on reported windows. Claude `limits[]` kinds `session` / `weekly_all` / `weekly_scoped` parsed without duplicates.
- Simulator automation hooks (`QUOTAPULSE_PAIRING_URL`, `QUOTAPULSE_START_ROUTE=provider/<id>|settings`) and a `QuotaPulseUITests` target that adds the widget to the simulator home screen through the real gallery.
- Verified on iPhone 17 / iOS 27.0 and iPhone 15 Plus / iOS 26.5 + 27.0 (393 pt and 430 pt widths, Dynamic Type XXL, dark mode).

- Telemetry: `FileLogger` (JSON Lines, daily files, 10 MB cap, background queue, upload cursor) on iOS and watchOS records pairing, hub fetches (latency/status/sample counts), background refresh scheduling and runs, WatchConnectivity transfers, widget reloads and forecast summaries; MetricKit crash/hang payloads are stored under `Documents/Diagnostics`. Devices push pending lines to the hub (`POST /v1/telemetry`, bearer token) on every refresh; the Mac keeps them under `telemetry/<device>/YYYY-MM-DD.log` and lists devices (heartbeat, version, last error, Reveal in Finder) under Hub & Devices. iOS Settings → Diagnostics shows the state and exports a zip through the share sheet; `UIFileSharingEnabled` exposes the logs in Files.

### Fixed
- macOS widget never appeared in the widget gallery: chronod refuses unsandboxed extensions ("Extension is not entitled to run in the App Sandbox"). The widget is now sandboxed and both app and widget share the team-prefixed App Group `88U7V98QAC.app.lishuyu.quotapulse`; data moved from Application Support to the group container (migrated automatically). `scripts/install.sh` registers the extension with `lsregister` / `pluginkit` and verifies it.

## [0.1.0] - 2026-10-16

### Added
- `QuotaCore` Swift package: provider protocol with Claude (Claude Code OAuth, Keychain/file credentials), OpenAI Codex (auth.json + token refresh with write-back), DeepSeek balance, OpenCode Zen/Go usage and z.ai / BigModel coding-plan quota; lenient JSON parsing with fixtures.
- Burn-rate forecasting (`ForecastEngine`): per-window least-squares rate, projected usage at reset, exhaustion time, pace vs. linear budget; balance burn per day and days remaining; automatic cycle detection across resets and top-ups.
- Sample history store with retention, per-provider exponential backoff (429 / transient), settings persistence, and the `QuotaEngine` actor that orchestrates polling.
- Hub protocol: `GET /v1/health|snapshot|history` behind a bearer token, `quotapulse://pair` QR payload, `HubClient`, and a Network.framework `HubServer`.
- `QuotaUI` package: provider cards, animated rings/bars, sparklines, Swift Charts history, widget/complication views, en + zh-Hans string catalogs.
- macOS menu-bar app (ring + percent glyph, instant panel from cached snapshot), main window (Overview, History, Providers, Hub & Devices with QR pairing, Alerts, General), launch-at-login, threshold notifications (opt-in), desktop widgets (small/medium/large with provider picker).
- iOS app: QR/manual pairing, provider list and detail charts, background refresh, home/lock-screen widgets, WatchConnectivity push.
- watchOS app with list/detail and accessory complications (circular, corner, rectangular, inline); direct hub fetch with iPhone fallback.
- 35 unit tests (`swift test`), xcodegen project spec, icon generator, localization generator, install script.
