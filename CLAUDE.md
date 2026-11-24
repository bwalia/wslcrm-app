# CLAUDE.md

Guidance for anyone (people and AI agents) changing the wslcrm iOS app.

## The rule that matters most: native only

Every screen is SwiftUI. The app contains **no web views** — no `WKWebView`, no
`SFSafariViewController`, no web dashboard page shown inside the app, no "open on the web" link
and no "do this on the web dashboard" wording. This is the owner's firm decision.

- A page the app doesn't have yet is **built natively**, never linked to the web dashboard.
- `scripts/check-native-only.sh` fails CI if WebKit, SafariServices or a web-page route appears.
- `NativeModulesTests.testEveryServerModuleIsNative` fails if the server's menu has a module with no
  native screen. A new OpsAPI module means a new native screen, in the same PR as the server change
  or the next one.
- Allowed, because they are not our pages: HMRC's own sign-in in Apple's sign-in sheet
  (`Features/Tax/HMRCSignIn.swift`, that one step only), and links to other sites (a customer's
  website, YouTube, maps, phone, email) opening in their own apps.
- Payments for our own plans are never taken in the app ("like Netflix"): say they're managed on
  our website, with no button or link (App Store rules).

## How a page reaches the app

Read `docs/NATIVE_MODULES.md` before adding a screen. In short:

- The server's menu (`GET /api/v2/user/menu`, `menu_items.key`) decides what a person may open.
  `NativeModules.destination(forKey:)` maps each key to a native screen.
- Each area of the app is a **module group** in its own file,
  `WSLCRM/ModuleKit/Catalog/ModuleGroup+<Area>.swift`, listed once in `ModuleCatalog.groups`.
- Prefer the **module kit**: a `ResourceDescriptor` (API paths, paging, list row, detail sections,
  form fields, actions, filters, permissions) is drawn by the shared list / detail / form / picker /
  report screens. Hand-build a screen only when a description can't express it (chat, a till,
  charts, a wizard, a map), and build it from the shared components.
- Plugin pages with a server description (`sdk.crud`) are drawn generically by `PluginPageScreen`.

## Getting the API right

The server is the truth. Read OpsAPI's route (`lapis/routes/*.lua`, `projects/<plugin>/api/`),
queries, and the dashboard's service and types for field names and permissions. Never guess a field
name; test descriptors and request bodies against real response shapes.

## Conventions

- Swift 6 strict concurrency; XcodeGen — run `xcodegen generate` after adding or removing files
  (`project.yml` is the source of truth; never hand-edit `project.pbxproj`).
- Plain UK English a beginner understands; say what happened after every action; no dead ends.
- Respect RBAC exactly as the server checks it (`module.action`; owners and admins pass).
- Never put `.sheet` / `.alert` / `.confirmationDialog` / `.task` / `.fullScreenCover` on a
  `Section` inside a `List` — SwiftUI copies them onto every row and they clash. Put them on the
  List or a header view. Likewise a List row that shows nothing never appears, so it can't load
  its own data with `.task`: load from the screen.
- Shared helpers live in the core (`Core/Networking`, `ModuleKit`, `DesignSystem`). Before adding
  an extension on a shared type (`String`, `JSONValue`, `Record`, `APIError`), check one doesn't
  already exist — duplicates from different areas break the build.
- Personalisation: Home (`HomeDigest`, "Edit Home"), the tab bar (Settings › Tab bar: Home and Apps
  fixed, three pins) and Appearance (`ThemeStore`) are per person; don't hard-code a module first.

## Build and test

```bash
xcodegen generate
scripts/check-native-only.sh
xcodebuild test -project WSLCRM.xcodeproj -scheme WSLCRM-Int \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -only-testing:WSLCRMTests CODE_SIGNING_ALLOWED=NO
```

The same app runs on the Mac through Mac Catalyst (docs/DESKTOP.md). A framework that isn't on the
Mac (VisionKit's live scanner, for one) gets a `#if targetEnvironment(macCatalyst)` fallback, never
a removed feature; `.github/workflows/desktop.yml` builds for Catalyst on every change.

Local OpsAPI testing (scheme `WSLCRM-Local`, `Config/Local.xcconfig`) and test credentials are in the
README. A merge to `main` uploads a TestFlight build (`.github/workflows/ios_release.yml`).
