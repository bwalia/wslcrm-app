# Native modules: every page is SwiftUI

The iOS app is **native only**. No web views, no web dashboard pages inside the app, no "open on
the web" links — not even for the smallest page. `scripts/check-native-only.sh` fails CI if WebKit,
SafariServices or a web page route appears.

A module that has no native screen yet is **hidden**, never linked to the web. The remaining work
is printed by `NativeModulesTests.testTheBacklogIsWhatHasNoScreenYet` ("Not native yet (N): …").

## How a server module reaches the app

The server's menu (`GET /api/v2/user/menu`, `menu_items.key`) decides what a person may open.
`NativeModules.destination(forKey:)` maps each key to a native screen:

1. the app's original hand-built screens (`NativeModules.screens`), or
2. a **module group** (`ModuleCatalog.groups`): a described list (module kit) or a hand-built screen.

Each area of the app is one group in its own file, `WSLCRM/ModuleKit/Catalog/ModuleGroup+<Area>.swift`:

```swift
extension ModuleGroup {
    static let workspace = ModuleGroup(
        id: "workspace",
        descriptors: [ModuleCatalog.webhooks, ModuleCatalog.apiKeys],      // described resources
        reports: [],                                                        // read-only reports
        resources: ["webhooks": "workspace.webhooks"],                      // menu key → descriptor id
        screens: ["namespace": "workspace.home"],                           // menu key → screen id
        screen: { id in                                                     // hand-built screens
            switch id {
            case "workspace.home": AnyView(WorkspaceHomeView())
            default: nil
            }
        })
}
```

…and one line in `ModuleCatalog.groups`. Nothing else is shared, so areas are built side by side.

A group can also own screens that no menu key opens directly, only other screens. The work group
(`ModuleGroup+Work.swift`) does this: project settings, sprints, epics, analytics, labels and AI
runs are reached from Projects and My tasks with `NavigationLink(value: WorkScreen.….route)`, which
carries its parameters in the `NativeScreenRoute` id (`work.sprints?project=…&sprint=…`).

## The module kit (prefer it)

Most pages are lists of records with a detail screen, a form, and some actions. Describe them with
a `ResourceDescriptor` instead of writing screens; the shared `ResourceListView`,
`ResourceDetailView`, `ResourceFormView`, `ReferencePicker` and `ResourceReportView` draw them.

| Piece | What it describes |
| --- | --- |
| `ResourceAPISpec` | list / item / create / update / delete paths (`{uuid}` placeholders), paging (`pageAndPerPage`, `pageAndCamelPerPage`, `pageAndLimit`, `limitOffset`, `none`), search param, fixed query, unusual list/item keys, body wrapper, id keys |
| `ListSpec` | the row: title paths, subtitle fields, status badge, trailing value, filters, empty state |
| `SectionSpec` / `FieldSpec` | detail sections and form sections; `FieldKind`: text, multiline, email, phone, url, integer, decimal, percent, money (pence or pounds, currency), date, dateTime, bool, status (tones + plain labels), choice, tags, count, secret, json, reference (pick another record) |
| `FormSpec` | create/edit fields, constants, `sendOnlyChanges` (nested objects are sent whole) |
| `ActionSpec` | buttons on a record (approve, send, void…): method, path, confirm text, inputs, visibility condition, RBAC |
| `listActions` | buttons on the list itself (erase a person's data, record a payment) |
| `RelatedSpec` / `LinkSpec` | related lists under a record; rows that open another native screen |
| `singleton` | one record at a fixed path (settings): open with `ResourceRoute(descriptorID:, recordID: "settings")` |
| `writableWhen` | which records can be edited/deleted (built-in rows can't) |
| `ReportSpec` | a read-only report: headline numbers and sections of rows |
| `ModuleCatalog.scoped(_:_:)` | a descriptor for one parent record (`/api/v2/billing/apps/{app}/features`): fills the parent's placeholders, registers it at run time, and the kit's list/detail/form screens find it by id |

The response parser accepts every OpsAPI envelope (`{data, meta}`, `{success, data: {data, meta}}`,
`{results}`, bare arrays, a single list under any key, lua-cjson's `{}` for an empty list, paging
under `meta`/`pagination`/top level). Statuses, money, dates and booleans format themselves.

Write a hand-built screen only when a description can't express the page (a chat, a till, a
wizard, a map, charts). Build it from the app's components (`Components.swift`, `Theme.swift`,
`PagedList`, `LoadState`, `StatusBadge`, `InlineErrorRow`, `SkeletonList`) and the kit's pieces
(`RecordRow`, `FieldValueRow`, `FieldEditor`, `ReferencePicker`), and register it in its group.

## Getting the API right

The server is the truth: read the route (`opsapi/lapis/routes/*.lua`, the header comments list the
endpoints and bodies), the dashboard's service (`opsapi-dashboard/services/*.service.ts`) and types
(`opsapi-dashboard/types/*.ts`) for field names, and the dashboard page for behaviour. Never guess a
field name; test a descriptor's parsing with a real response shape (`ModuleKitTests`).

## Rules

- Plain words a beginner understands; no dead ends; say what happened after every action.
- RBAC: `ResourcePermissions.module` is the server's module (`shop`, `crm_accounts`); writes are
  hidden without the grant. Owners/admins pass, as on the server.
- Modals (`.sheet`, `.alert`, `.confirmationDialog`, `.task`) never go on a `Section` inside a List
  (they are copied onto every row): put them on the List or a header view.
- Swift 6 strict concurrency; run `xcodegen generate` after adding files.
- Every group ships with unit tests: descriptor shapes parse real responses, actions and forms
  encode the bodies the server expects.

## The one page the app doesn't draw: HMRC's sign-in

HMRC requires taxpayers (and agents) to sign in and give permission on HMRC's own Government Gateway page.
The app opens that page in Apple's system sign-in sheet (`ASWebAuthenticationSession`), for that one step
only, in one file: `Features/Tax/HMRCSignIn.swift`. It is not a web view inside the app, and nothing of the
web dashboard is shown. OpsAPI's `/auth/hmrc/initiate?redirect_url=wslcrm://hmrc` sends the person back to
`wslcrm://hmrc/<settings|file|vat>?hmrc_connected=true` (or `?hmrc_error=<code>`), which closes the sheet.

## Screen ids with a parameter

A group's screen id may carry one parameter after a colon (`tax.file:2025-26`, `tax.vat:client=<uuid>`,
`tax.income:rental|2025-26`), so one hand-built screen can open another for a record or a year with
`NavigationLink(value: NativeScreenRoute("…"))`, without registering a new route type in a shared file.
