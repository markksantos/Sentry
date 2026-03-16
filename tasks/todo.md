# Sentry - macOS Menu Bar Network Monitor

## Phase 1: Scaffold + Connection Scanning
- [x] 1.1 Package.swift + directory structure
- [x] 1.2 ConnectionEntry model
- [x] 1.3 LSOFParser + tests with fixture data (17 tests passing)
- [x] 1.4 NetworkScanner actor
- [x] 1.5 DashboardViewModel
- [x] 1.6 UI Views (MenuBarView, AppListView, ConnectionRowView)
- [x] 1.7 App entry point (SentryApp.swift, AppDelegate.swift)
- [x] 1.8 Verify Phase 1: `swift build` succeeds

## Phase 2: GeoIP + DNS + History
- [x] 2.1 MMDBReader (pure Swift binary MMDB parser)
- [x] 2.2 GeoIPLookup wrapper
- [x] 2.3 ReverseDNSResolver actor
- [x] 2.4 SQLiteStore (sqlite3 C API)
- [x] 2.5 UI Updates (flags, hostnames, history view with search/filter/export)
- [x] 2.6 Verify Phase 2: build succeeds, integrated into ViewModel

## Phase 3: Trust System + Alerts
- [x] 3.1 TrustManager (SQLite-backed, UserDefaults per-app overrides)
- [x] 3.2 BlocklistMatcher (104 tracker domains, suffix matching)
- [x] 3.3 First-seen notifications (UNUserNotificationCenter)
- [x] 3.4 Trust UI (badges, context menus on connections and apps)
- [x] 3.5 SettingsView (launch at login, scan interval, notifications)
- [x] 3.6 Verify Phase 3: build succeeds, all 17 tests pass

## Notes
- Platform: macOS 14+ (required for @Observable/@Bindable)
- GeoLite2-Country.mmdb is a placeholder; needs real MaxMind DB for GeoIP to work
- Zero external dependencies; uses sqlite3 C API directly
