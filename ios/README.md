# InFocus Portal for iPhone and iPad

A native SwiftUI app for the program's Portal: a role-aware tab bar (Home · Packages or Groups · Calendar · Messages · More), native screens built on a shared Portal client, and every remaining Portal page available inside the app, signed in. How it's organized and how to add a screen: [ARCHITECTURE.md](ARCHITECTURE.md). Also:

- **Browser sign-in hand-off.** Google refuses to run inside an app's web view, so sign-in goes through `ASWebAuthenticationSession` → the Portal's `/app-sign-in` page → `infocus://signed-in?code=…` → `POST /api/auth/app/token` (PKCE, same protocol as the Mac app). Signing in with an emailed code runs on the Portal's own page.
- **Notifications.** The app registers its APNs token with `POST /api/push/native-device` (`platform: "ios"`) under the signed-in account, every launch and whenever the session changes. Tapping a notification opens its Portal page, even from a cold launch. The Portal's Sign out button runs natively, so the device is unregistered before the session ends. One native pre-prompt is shown after the first sign-in.
- **Portal pages without a native screen** open in a signed-in web view inside the tab: pull to refresh, a green progress line, downloads to the share sheet, uploads from the camera or library, Safari sheets for other sites, mailto/tel to the system, and a native offline screen instead of a blank page.
- **The Portal Settings bridge** (`window.webkit.messageHandlers.infocus`): `notificationStatus`, `requestNotifications`, `openNotificationSettings`, the same replies as the Mac app. The user agent ends in `InFocusiOSApp/<version>` so the Portal can tell it apart.

The source has no hostnames: `Config/Portal.xcconfig` reads them from `Config/Portal.local.xcconfig` (gitignored), and the release script passes them on the command line.

## Layout

```
project.yml                XcodeGen spec (the .xcodeproj is generated and gitignored)
Config/Portal.xcconfig     Build-time hosts and team (real values in Portal.local.xcconfig)
InFocusPortal/App          Entry point, app delegate (push), AppModel (welcome ⇄ tabs), RootView, AppConfig
InFocusPortal/Design       Colors, Lexend + Geist Mono, buttons, cards, nameplate, loading/empty/error states
InFocusPortal/Networking   PortalClient (signed-in JSON API), errors, dates, Loadable, streamed uploads
InFocusPortal/Session      Signed-in person and role flags (SessionStore), appearance preference
InFocusPortal/Navigation   Tabs, typed routes, deep links, router, badges
InFocusPortal/Features     One folder per area: Work (Home, Packages/Groups), Calendar, Grades, Messages, More
InFocusPortal/Web          Signed-in Portal pages (fallback), navigation policy, JS bridge, downloads
InFocusPortal/SignIn       PKCE hand-off, Portal cookies, welcome and email sign-in screens
InFocusPortal/Push         APNs registration with the Portal, notification taps, the notifications offer
InFocusPortalTests         Unit tests (client, deep links, roles, catalog, PKCE, cookies, push, failures)
scripts/make-assets.swift  App icon, launch mark and wordmark from the InFocus logo package
scripts/release-ios.sh     Archive, sign and upload to TestFlight
scripts/asc-profile.mjs    App Store provisioning profile via the App Store Connect API
```

## Develop

```sh
brew install xcodegen
cd ios
printf 'INFOCUS_PORTAL_HOST = portal.example.com\nINFOCUS_DRIVE_HOST = drive.example.com\nINFOCUS_TEAM_ID = ABCDE12345\n' > Config/Portal.local.xcconfig
xcodegen
open InFocusPortal.xcodeproj
```

Tests (use the release Xcode if a beta is selected):

```sh
xcodebuild -project InFocusPortal.xcodeproj -scheme InFocusPortal \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

Brand images are generated, not drawn by hand: `swift scripts/make-assets.swift "<path to the logo package's 01 Logos folder>"`.

## Release to TestFlight

The App Store Connect app record must exist first (App Store Connect → Apps → + → New App, bundle ID `com.infocuspaly.portal`; the API can't create apps). Then:

```sh
ios/scripts/release-ios.sh              # archive, sign, upload
ios/scripts/release-ios.sh --no-upload  # archive, sign, export ios/build/InFocusPortal.ipa
VERSION=1.0.1 ios/scripts/release-ios.sh
```

It needs the release Xcode, `xcodegen`, Node and the 1Password CLI. Credentials are read from 1Password at run time and never stored here. The script reads its settings from the environment or from `ios/release.env` (gitignored): see the comment at its top. Build numbers are UTC timestamps. Listing, privacy and review notes: [APP_STORE.md](APP_STORE.md).
