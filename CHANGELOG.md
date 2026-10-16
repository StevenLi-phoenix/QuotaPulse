# Changelog

All notable changes to this project will be documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/).

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
