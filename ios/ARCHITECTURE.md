# InFocus Portal for iPhone: architecture

A native SwiftUI app for the InFocus Portal. Tabs: **Home · Packages** (students) or **Groups** (producers) **· Calendar · Messages · More**. Every Portal page without a native screen still opens inside the app, signed in, in a web view. So nothing is ever unreachable, and native screens can replace web pages one at a time.

iOS 17+, Swift 5 mode, no third-party packages. Generate the project with `xcodegen` (from `ios/`). Build and test with the release Xcode:
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project InFocusPortal.xcodeproj -scheme InFocusPortal -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test`.

## Folders (`InFocusPortal/`)

| Folder | What's in it | Owner |
|---|---|---|
| `App/` | `InFocusPortalApp`, `AppDelegate` (push), `AppModel` (phases, sign-in/out, session end, deep links), `RootView`, `SystemAppearance`, `AppConfig` | shell |
| `Design/` | `Brand` (colors), `Typography` (Lexend, Geist Mono, type scale, `Eyebrow`), `Buttons`, `Components` (`card()`, `Nameplate`, `SectionHeader`, `StatusTag`, `LiveTag`), `StateViews` (`Skeleton`, `SkeletonList`, `ErrorStateView`, `EmptyStateView`, `LoadableView`), `MessageView` | shell (add, don't change) |
| `Networking/` | `PortalClient`, `PortalError`, `PortalJSON`, `Loadable`, `PortalUpload` | shell |
| `Session/` | `PortalUser` (roles and flags), `SessionStore`, `Preferences` (appearance) | shell |
| `Navigation/` | `AppTab`, `Route`, `DeepLink`, `Router`, `BadgeCenter`, `RouteDestination`, `MainTabView` | shell |
| `Features/Work/` | `HomeTab`, `WorkTab`, `WorkRoute`, `WorkDestination` | **Work agent** (Home, my packages and stages, Groups review) |
| `Features/Calendar/` | `CalendarTab`, `CalendarRoute`, `CalendarDestination` | **Calendar agent** (Master Calendar, The Show, announcements) |
| `Features/Grades/` | `GradesScreen`, `ExtensionsScreen`, `GradesRoute`, `GradesDestination` | **Grades agent** (grades, extension requests) |
| `Features/Messages/` | `MessagesTab`, `MessagesRoute`, `MessagesDestination`, `Equipment/EquipmentScreen`, `Livestreams/LivestreamsScreen` | **Messages agent** (chats, equipment checkout, livestream sign-ups) |
| `Features/More/` | `MoreTab`, `SettingsScreen`, `PortalPagesScreen`, `PortalPagesCatalog`, `MoreRoute` | shell |
| `Web/` | `PortalWebController` (one WKWebView), `PortalWebView`, `PortalPageScreen` (fallback page), `PortalNavigation` (link policy), `PortalBridge` (JS bridge), downloads, offline view | shell |
| `Push/` | `PushRegistrar` (APNs token → `POST /api/push/native-device` with `platform: "ios"`), `NotificationRouter` (taps → deep links), `NotificationOfferView` | shell |
| `SignIn/` | PKCE hand-off (`PortalSignIn`, `/app-sign-in` → `infocus://signed-in`), `PortalAPI`/`PortalCookies`, `WelcomeView`, `EmailSignInScreen` | shell |

**Rule for feature agents:** only edit your own `Features/<Area>/` folder. Every placeholder root and destination there may be replaced, and you can add files. If you need something shared (a new design component, a client helper), add a new file in your folder first and say so in your report. Don't edit shell files. Two exceptions: adding a case to your own route enum is fine, and so is adding a file under `Design/` that nobody else touches, as long as you mention it.

## Adding a native screen

1. Add a case to your route enum (for example `WorkRoute.group(rowId:stage:)`). These enums are already wired into `Route`, `RouteDestination` and `DeepLink`.
2. Return your view for it in your `…Destination`.
3. Push it from anywhere: `router.push(.work(.group(rowId: id, stage: nil)))`, or with a `NavigationLink(value: Route.work(…))`.
4. If a Portal URL should open it (from a notification or a link), parse that path in your enum's `static func deepLink(_ path: [String], _ query: [URLQueryItem]) -> DeepLinkMatch?`. `path` is the URL path split on `/` (`["groups", "row1", "initial-cut"]`); a subdomain becomes the first component (`equipment.` → `["equipment", …]`). Return the tab to switch to and the route to push (nil means the tab's root). Return nil to fall through: the page then opens in the web view.
5. Add an XCTest for the decoding and for any deep link you parse (see `InFocusPortalTests/`, which has a `StubProtocol` for network tests).

The reserved cases, wired today to placeholders that show the Portal page:

| Enum | Cases | Deep links parsed today |
|---|---|---|
| `WorkRoute` | `group(rowId:stage:)`, `studentStage(StudentStage)` | `/groups` (Work root), `/groups/<rowId>[/<stage>]`, `/information`, `/brainstorming`, `/a-roll`, `/initial-cut`, `/final-cut` |
| `CalendarRoute` | `day(date:)`, `theShow`, `announcements` | `/master-calendar[?date=]`, `/show-roles`, `/announcements` |
| `GradesRoute` | `grades`, `extensions`, `extensionRequest(id:)` | `/grades` (and `grades.` host), `/extensions[/<id>]`, `/extension-requests[/<id>]` (all on More) |
| `MessagesRoute` | `conversation(id:)`, `equipment`, `livestreams`, `livestream(id:)` | `/equipment` (and `equipment.` host), `/livestreams[/<id>]` (on More) |
| `MoreRoute` | `settings`, `portalPages` | `/settings` |

`/` and `/dashboard` go to Home. Anything else becomes `.portal(PortalPage(url:))` on the current tab.

## Talking to the Portal

```swift
@Environment(\.portalClient) private var client

struct GroupTile: Decodable, Identifiable { let id: String; let topic: String; let updatedAt: Date }
let tiles: [GroupTile] = try await client.get("api/groups", query: [URLQueryItem(name: "cycle", value: "2")])
try await client.post("api/comments", body: NewComment(mediaId: id, body: text))            // answer ignored
let saved: Comment = try await client.post("api/comments", body: NewComment(…))            // decoded
try await client.patch(…); try await client.put(…); try await client.delete("api/x/\(id)")
```

- Paths are relative to the Portal, like `api/...`. The client sends the signed-in session cookie, which is the same session the web view uses, along with a Mobile Safari + `InFocusiOSApp/<version>` user agent.
- Responses are the Portal's `{ data }` envelope; you get `data` decoded. Dates decode from ISO 8601 (with or without fractional seconds) or from `YYYY-MM-DD`. Keep date keys like `"2026-10-07"` as `String` when they're keys, not instants.
- Errors throw `PortalError` with words ready to show (`error.localizedDescription`):
  - `.forbidden(message)`: the person (or the sample account) can't see this. Show it as "not available", don't crash.
  - `.offline`.
  - `.server(status:message:)`: carries the Portal's `{ error: { message } }` text.
  - `.decoding`.
  - `.unauthorized` (401) is handled for you: the app goes back to sign-in.
- Find the API you need by reading the Portal repo: routes live in `app/api/**/route.ts` and logic in `src/server/`. Match the web client's calls, which are in the page's `*-client.tsx`. Don't invent endpoints. If one is missing, say so in your report.
- Uploads: ask the Portal's upload route for a destination, then `PortalUpload.file(at:to:method:headers:progress:)` streams the file from disk with progress. See the Portal's `docs/NAS-STORAGE.md` for the Drive/NAS flow the web uses.
- Load state: hold a `Loadable<T>`. Render it with `LoadableView(state, retry:) { value in … }`, or by hand with `SkeletonList` / `ErrorStateView` / `EmptyStateView`. Use `.refreshable` for pull-to-refresh.

## Session and roles

`@Environment(SessionStore.self) private var session`, then `session.user` (`PortalUser`). It's loaded after sign-in from `GET api/profile`, `GET api/platform/me` and `GET api/package-cycle/stage`. The flags match the web sidebar (`components/app-shell.tsx`):

| Flag | Meaning |
|---|---|
| `role` | `PlatformRole?`; nil means a student |
| `isProducer` | associate producer and up (Groups, Members, Package Cycle, Publishing Queue, The Show) |
| `isAssociate` | `ASSOCIATE_PRODUCER` |
| `isExecutive` | stage 3: EP or super admin; never the adviser |
| `isAdviser`, `isSuperAdmin` | super admin includes the adviser (platform admin powers) |
| `onStudentPackage` | on a Package Cycle roster this cycle |
| `doesStudentWork` | `!isProducer \|\| (isAssociate && onStudentPackage)`: shows the student cycle stages |
| `seesStudentGrades` | below EP (EPs, the adviser and the super admin have no gradebook) |
| `canManageGrades`, `canManageAccounts` | EP and up |
| `sampleOnly` | the Apple App Review account (see below) |

The server enforces access no matter what. These flags only decide what to show.

### The App Review sample account (`sampleOnly`)

Apple's reviewer signs in through **Sign in with an email code** on the welcome screen. That's the Portal's own `/sign-in` page in a web view, and its code field accepts 6–32 digits. The account is confined on the server: only its dashboard/workspace/projects, settings and the `/api/workspaces|projects|media|comments|guest-links|profile|onboarding|notification-preferences|push|auth` APIs. Everything else answers **403**, or redirects pages to `/dashboard`. `GET api/profile` returns `sampleOnly: true` for it, and the app then:

- shows only the **Home** and **More** tabs (`AppTab.visible(for:)`), with More holding just the profile row and **Settings**;
- refuses routes outside Home, Settings and Portal pages in `Router` (deep links land on Home);
- skips `platform/me`, `package-cycle/stage` and badge calls.

Feature agents:
- **Work (Home):** for `session.user?.sampleOnly == true`, Home must show that account's workspace and projects: a sample project with images and comments, which it can comment on. Use only the allowed APIs above, and none of the class surfaces (packages, groups, cycle).
- **Every agent:** never call class APIs when `sampleOnly`, and treat `PortalError.forbidden` as "not available here" with an `EmptyStateView`, not an error screen.

## Navigation, deep links, badges

- `@Environment(Router.self) private var router`. Use `router.push(_:)`, `router.openPortal("announcements/submitted", title: "Submitted")`, or `router.open(url)` for a deep link (switches tab and resets it). Tapping the selected tab pops to its root.
- Notification taps carry `url` (a Portal page): `NotificationRouter` → `AppModel.open` → `Router.open` → `DeepLink.resolve`. If the person is signed out, the page opens right after sign-in.
- `@Environment(BadgeCenter.self) private var badges`, then `badges.set(count, for: .messages)` to set your tab's badge (unread chats, stages waiting on you). More's badge is extension requests waiting on this person. It refreshes on sign-in and whenever the app becomes active.

## Fallback web view

`PortalPageScreen(page:)` or `PortalPageScreen(path:title:)` shows any Portal page in its own `PortalWebController` (`embedded: true`). It shares the cookie store with every other web view, so it's signed in. It has the page title, a progress line, the offline view, and Back/Reload/Share. Links keep the Portal's in-app/out-of-app policy (`PortalNavigation`): Google sign-in becomes the native hand-off, and the Portal's Sign out becomes the native sign-out. The Portal page shows its own header too; that's expected for fallbacks.

## Design

Follow the Portal's `DESIGN.md` §10/§13:
- Ink / Mist 20 surfaces with light and dark (System/Light/Dark in Settings).
- InFocus Green (`Brand.fill`) only for primary fills with Soft White text (`Brand.onBrand`). `Brand.green` is for small marks and links. Record Red only for a LIVE dot. Errors use `Brand.danger`, never Record Red.
- Lexend everywhere (`.lexend(size, weight)`, `.h1/.h2/.h3/.bodyText/.small`). `.mono` (Geist Mono) only for data that lines up or ticks: timecodes, counts in columns, IDs.
- Square plates (`Nameplate` with its 4px green strip) and a 6px radius for everyday UI. Flat: no gradients or shadows. Touch targets at least 44pt. Status never by color alone.
- Lists: `List` with `.scrollContentBackground(.hidden).brandBackground()`, like More.

## DEBUG helpers

`-InFocusStubSession <student|associate|producer|admin|sample>` shows the tabs without a Portal, with fictional people. `-InFocusOpen <portal path|more|portal-pages>` opens a screen at launch. For screenshots, build with `INFOCUS_PORTAL_HOST=portal.example.com` so no web view loads the real Portal (never QA the live Portal in a simulator), then use `xcrun simctl io <device> screenshot`.
