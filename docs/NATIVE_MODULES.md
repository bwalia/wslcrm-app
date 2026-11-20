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

## One record on a hand-built screen, and plugin pages

- **A screen for one record** is still pushed by value: `NativeScreenRoute("pd.buyer", uuid)` makes the
  id `pd.buyer:<uuid>`; the group's `screen:` closure splits it with `NativeScreenRoute.parts(id)`.
  No new `navigationDestination` is needed (`ModuleGroup+Industry.swift`).
- **Several groups as one**: `ModuleGroup.joining(id:_:)` merges parts (the industry area is field
  service, Property Deals, Property PA, health, the AI runner and plugins) behind one line in
  `ModuleCatalog.groups`; `IndustryModuleTests` checks no two parts claim a key.
- **Descriptors built at run time**: `RuntimeDescriptors.register(_:)` makes a descriptor the server
  described (or one per parent record, as health does for a patient's care records) resolvable by id,
  so `ResourceRoute` / `ResourceListRoute` open it with the kit's own screens.
- **Plugin pages** (`/dashboard/plugins/<code>/<key>`): `GET /api/v2/plugins/:code/resources/:key`
  describes a plugin's generated list (`sdk.crud`: fields, columns, filters, search, sort, rights), and
  `PluginPageScreen` draws it natively from that description — helpdesk tickets, bank holidays, and any
  plugin installed later (`MenuDestination.of` falls back to it for an unmapped plugin path). A plugin's
  own HTML page (manifest `pages`) has no description, so it needs a hand-built screen registered in
  `PluginPages.nativePages` (helpdesk overview, Portfolio Lab).
