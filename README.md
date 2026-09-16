# WSLCRM — iOS

Native iOS client (Swift 6, SwiftUI, iOS 17+) for the OpsAPI / Workstation platform. It uses
the same REST API as the web dashboard; the backend is not modified by this project.

Modules: **field service** (engineer *My Work* with a guided visit, service requests with customer
sites, assets, jobs and phases, visits, quote sheet lines, F-Gas records, photos, and invoicing
from jobs), **CRM** (accounts, contacts, deal pipeline), **customers**, **products**, **orders**
and **invoices**.

No third-party dependencies — `URLSession`, `Codable`, Swift Concurrency, Keychain,
CoreLocation and LocalAuthentication only.

---

## Requirements

- Xcode 26 or later (Swift 6 toolchain), iOS 17+ simulator or device
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) *only* if you add targets or change build
  settings (`brew install xcodegen`). The generated `WSLCRM.xcodeproj` is committed.

## Setup

```bash
git clone https://github.com/bwalia/wslcrm-app.git
cd wslcrm-app
open WSLCRM.xcodeproj
```

Pick the **WSLCRM-Int** scheme and run on a simulator. After adding or removing source files,
run `xcodegen generate` so the project picks them up.

For a physical device, create the git-ignored `Config/Local.xcconfig`:

```
DEVELOPMENT_TEAM = ABCDE12345
```

## Environments: int vs prod

The API base URL is a build setting (`API_BASE_URL`) written into Info.plist and read by
`AppConfig`. It is never hard-coded in Swift.

| Scheme | Configurations | Base URL |
|---|---|---|
| `WSLCRM-Int` | `Debug-Int`, `Release-Int` | `https://int-opsapi.workstation.co.uk` (`Config/Int.xcconfig`) |
| `WSLCRM-Prod` | `Debug-Prod`, `Release-Prod` | supplied at build time |
| `WSLCRM-Local` | `Debug-Local` | `http://127.0.0.1:4011` (`Config/Local-API.xcconfig`) — Simulator only |

The production URL is never committed. Supply it in one of two ways:

```bash
# on the command line / CI
xcodebuild -scheme WSLCRM-Prod -configuration Release-Prod \
  WSLCRM_PROD_API_BASE_URL='https://api.example.com' archive …
```

or in a git-ignored `Config/Prod.local.xcconfig` (note `//` starts a comment in xcconfig files):

```
WSLCRM_PROD_API_BASE_URL = https:/$()/api.example.com
```

The **Validate API base URL** build phase fails the build if the URL is missing or not `https`.
Plain `http` is accepted only for `127.0.0.1`/`localhost` in the Local configuration, whose
`Info-Local.plist` is the only one with `NSAllowsLocalNetworking`.
The login screen shows an environment badge on non-production builds.

## Test credentials

- Use a dedicated **int** account that belongs to at least one workspace. Engineer-role accounts
  exercise the offline visit flow; a service-manager or owner account exercises dispatcher actions.
- 2FA is mandatory. The code is emailed to the account and expires **5 minutes after login**
  (resending does not extend it). If int has `TEST_OTP_CODE` configured, that code also works.
- Credentials live in **WSL Vault** (`https://vault.workstation.co.uk`), never in git. The secret
  is a flat KV v2 map at `kv/wslcrm/int/app` (override with `WSLCRM_VAULT_PATH`):

  | Key | Value |
  |---|---|
  | `WSL_IDENTIFIER` | int account email or username |
  | `WSL_PASSWORD` | its password |
  | `WSL_NAMESPACE` | optional workspace uuid or slug |
  | `WSL_OTP` | optional, only if int has `TEST_OTP_CODE` |

  Authenticate to the vault with `wslvault init` (writes `~/.wslvault/config.toml`), or set
  `WSLVAULT_TOKEN` (or `WSLVAULT_API_KEY`) and `WSLVAULT_TENANT_ID`. Then:

  ```bash
  scripts/vault-env.py keys                                   # check access (prints key names only)
  scripts/vault-env.py exec -- scripts/capture-fixtures.py    # secrets injected in memory
  scripts/vault-env.py write-env                              # only if a tool needs a .env (mode 600, git-ignored)
  ```

- UI tests need **no credentials**: they launch the app with `-UITestStubServer`, a Debug-only
  in-memory OpsAPI (`WSLCRM/Support/UITestSupport.swift`) that reproduces the real response shapes.

## Tests

```bash
# unit + UI tests
xcodebuild -project WSLCRM.xcodeproj -scheme WSLCRM-Int \
  -destination 'platform=iOS Simulator,name=iPhone 17' test

# unit tests only
xcodebuild … -only-testing:WSLCRMTests test
```

| Suite | Covers |
|---|---|
| `APIDateTests` | naive-UTC timestamps, microsecond truncation, offsets, date-only values, ISO-8601 output |
| `EnvelopeDecodingTests` | every module's envelope: field service/CRM `{success,data,meta}`, customers/products `{data,total}`, orders top-level paging, invoices camelCase `meta`, auth, menu permissions |
| `ServerErrorTests` | the catalogued / plain / `success:false` / RBAC / legacy error shapes, 401 messaging |
| `TokenRefreshTests` | refresh-and-retry, single-flight refresh under concurrent 401s, rotation, offline refresh keeps session, revoked refresh ends session |
| `MutationQueueTests` | offline replay order, persistence across relaunch, failed writes kept, same-entity blocking, per-user replay |
| `LiveFixtureDecodingTests` | decodes every captured `live_*.json` (skipped until fixtures are captured) |
| `FieldServicePR610Tests` | opsapi #610 payloads: sites (`+00` timestamps), presigned photos, quote lines (labour category, days, supplier, hire), visit F-Gas fields, job site fallback, convert-to-job body (UTC), multipart upload, JPEG cap, site link follow-up `PUT` |
| `MyWorkBucketingTests` | My Work window, shared background-refresh cache key, offline prefetch of open visits only, new-assignment detection |
| `PhaseCompletionUITests` | login → wrong/right 2FA code → My Work → job → phase: force prompt, checklist tick, completion |
| `RetryPolicyTests`, `APIClientRetryTests` | which failures are retried (reads only), bounded attempts, exponential backoff, `Retry-After` |
| `ResponseCacheEvictionTests` | cached responses expire and the cache is trimmed to its size limit |
| `LogRedactionTests` | passwords, tokens and OTPs never reach the log — including form-encoded bodies |
| `EngineerFlowUITests` | the guided visit against the stub: labour from the stepper, a material from the stock list, an F-Gas record, check-out — with an **accessibility audit** of every screen |
| `LargeTextUITests` | the same screens at an accessibility text size, with screenshots |
| `FieldServiceLocalFlowUITests` | the full request → invoice happy path against a real local OPSAPI, including a checklist tick made **offline** that syncs on reconnect (skipped unless run by `scripts/run-local-fs-uitest.sh`) |
| `LocalPhotoUploadTests` | photo upload, listing and delete against the real local API (multipart, presigned URL) |

UI test screenshots are kept in the result bundle:
`xcrun xcresulttool export attachments --path <bundle>.xcresult --output-path screens/`.

### Local OPSAPI for Simulator testing (Field Service, opsapi #610)

`FieldServiceLocalFlowUITests` drives the whole flow against a real backend, using three
non-admin users in their own workspace:

1. The telecaller logs a request with a customer site.
2. The manager converts it, assigning the engineer and a first visit, and the job becomes **Scheduled**.
3. The engineer sees it in My Work and taps On my way, then I've arrived (GPS from the simulated
   location). They log labour and a material, then finish.
4. The manager ticks a phase checklist item, completes the job and creates the invoice.

Run it against an isolated copy of the backend, never a shared database:

```bash
# 1. PR branch checkout, inside the git-ignored build/ (Docker Desktop can mount it)
git clone --depth 1 -b feat/field-service-engineer-app https://github.com/bwalia/opsapi.git build/opsapi-pr610

# 2. A copy of your local dev database, and a second lapis container on :4011 using the same image,
#    network and env as the local `opsapi` container but POSTGRES_DB=opsapi-wslcrm-pr610
docker exec opsapi-postgres-dev-db sh -c 'createdb -U "$POSTGRES_USER" opsapi-wslcrm-pr610 &&
  pg_dump -U "$POSTGRES_USER" --no-owner <dev-db> | psql -U "$POSTGRES_USER" -q opsapi-wslcrm-pr610'
docker run -d --name wslcrm-opsapi-pr610 --network lapis_opsapi-network -p 4011:80 --env-file <env> \
  -v "$PWD/build/opsapi-pr610/lapis:/app" -v "$PWD/build/opsapi-pr610/projects:/app/projects" lapis-lapis lapis server
docker exec wslcrm-opsapi-pr610 sh -c 'cd /app && lapis migrate'   # adds fs_sites, fs_job_photos, …

# 3. Test tenant: owner, manager, telecaller, engineer, store + unit, customer, job type with phases.
#    Writes build/local-fs-test.env (mode 600, git-ignored); the container must have TEST_OTP_CODE.
scripts/local-opsapi-fs-seed.sh

# 4. Run: resets that tenant's open jobs, sets the simulator location, records video
scripts/run-local-fs-uitest.sh
```

`-WSLOfflineWindow <from>,<to>` (Debug builds only) fakes a loss of connectivity for a window of
seconds after launch; the local flow uses it to prove a checklist tick made with no signal is
queued, shown as waiting, and sent on reconnect.

Screenshots are in `build/local-fs-run/result.xcresult` (export them as shown above) and the video
is saved to `build/local-fs-run/happy-path.mp4`. To run the app by hand, pick the **WSLCRM-Local**
scheme and set `LOCAL_API_PORT` in `Config/Local.xcconfig` if the backend isn't on 4011. To clean up,
run `docker rm -f wslcrm-opsapi-pr610`, drop the `opsapi-wslcrm-pr610` database and delete `build/opsapi-pr610`.

### Capturing fixtures from the real API

```bash
scripts/vault-env.py exec -- scripts/capture-fixtures.py   # credentials from WSL Vault; waits for the 2FA code
```

It logs in, performs **read-only** requests, anonymises names/emails/phones/addresses and writes
`WSLCRMTests/Fixtures/live/live_*.json`. Without a TTY it waits for the code in
`scripts/.capture/otp`. Review the files before committing.

---

## Architecture

```
WSLCRM/
  App/            composition root (AppEnvironment), RootView, AppConfig
  Core/
    Networking/   APIClient (actor), Endpoint, Envelopes, APIDate, APIError, JSONValue & lenient decoders
    Auth/         AuthAPI, SessionStore, TokenStore (Keychain), BiometricGate
    Permissions/  PermissionSet (menu-driven RBAC), FieldServicePolicy
    Offline/      ResponseCache, MutationQueue, SyncCenter, ConnectivityMonitor
    Location/     one-shot LocationProvider for check-in/out
  DesignSystem/   status badges, large buttons, skeletons, inline errors, paged lists
  Features/       Auth, Workspace, Home, FieldService (My Work, guided visit, sites, assets, quote sheet,
                  photos, F-Gas), Jobs, Visits, ServiceRequests, CRM, Customers, Products, Orders, Invoices
  Support/        Debug-only UI-test stub server
```

**MVVM.** Views own `@Observable @MainActor` view models; view models call stateless API facades
(`FieldServiceAPI`, `CRMAPI`, `CommerceAPI`, `InvoicesAPI`) injected through the environment.

**`APIClient` actor.** Builds requests from `Endpoint`s, injects `Authorization: Bearer` and
`X-Namespace-Id`, and maps responses to typed `APIError`s. Tokens refresh proactively before the
JWT's `exp` and on a 401. Refresh is single-flight because the server rotates refresh tokens and
revokes the whole token family if one is reused. Logging is redacted and is on in Debug, or with
`-WSLNetworkLogging YES`. Cookies are disabled so the server's `refresh_token` cookie never becomes
a second refresh path.

**API shape.** OpsAPI is inconsistent, so each shape is handled explicitly:

- Per-module envelope types (`Envelope.Standard`, `.DataTotal`, `.Orders`, `.Invoices`).
- `APIDate` normalises naive UTC timestamps (space → `T`, fraction → milliseconds, append `Z`).
  Requests always send ISO-8601 UTC.
- Lenient wrappers (`LossyArray`, `FlexibleDecimal`…) absorb omitted NULLs, `[]` sent for empty
  objects, and JSON stored inside TEXT columns.
- `ServerError.parse` understands every error body. `correlation_id` / `X-Request-ID` is shown in
  a copyable "Details" view.

**Auth.** Login is form-encoded (the server doesn't parse JSON on that route), followed by 2FA
verify. Tokens are stored in the Keychain (`AfterFirstUnlockThisDeviceOnly`). Face ID / Touch ID
optionally re-locks the app after five minutes in the background. The workspace switcher persists
the selection, calls `/switch`, reloads permissions, and bumps `workspaceGeneration` so every screen
re-fetches.

**Roles.** The three roles OPSAPI seeds decide what the app offers:

| Role | Grants (from the seed) | In the app |
|---|---|---|
| **Telecaller** | `fs_service_requests` create/read/update, `customers` create/read | Opens on Field Service: logs and edits requests with a site, customer and faulty unit. No jobs, visits, parts or invoices, and no My Work tab. |
| **Service manager** | `manage` on requests, jobs, visits, job types, parts, employees and customers; `invoices` create/read; `timesheets` read (plus `products` manage on workspaces seeded after #611) | The full board: convert and assign, approve items, quote, invoice. Cannot *send* an invoice — that needs `invoices.update`, which the seed doesn't grant (API-NOTES 54). |
| **Engineer** | `fs_jobs` read, `fs_visits` read, `fs_parts` read | Opens on My Work; the guided visit, the stock list for materials, checklist and phase work on jobs they're booked on. Never sees prices, approvals, quotes or invoices. |

`RolePermissionTests` and `RoleAccessUITests` pin this per role, using the menu payloads the
server actually returns.

**Permissions.** `GET /api/v2/user/menu` provides grants plus `is_owner`/`is_admin`, and
`PermissionSet` mirrors the server rule. `FieldServicePolicy` adds the API's "engineer booked on
this job" overlay. Actions a user can't perform are hidden, not left to fail. Job and
service-request actions come from `allowed_transitions`.

**Field Service (opsapi #610).**

- **Navigation.** Engineers land on **My Work**; managers and telecallers land on the
  **Field Service** hub (stats, log a request, then requests, jobs, assets, sites and invoices).
  The area navigates by value routes only (`withAppDestinations`).
- **My Work.** Shows one hero card for the job in front of the engineer, today at a glance, then
  in progress / overdue / later today / coming up, over the dashboard's −3…+21-day window. It polls
  every 30s in the foreground, announces newly assigned jobs and shows in-app notifications.
- **Guided visit.** The flow is On my way → I've arrived (GPS) → checklist, labour / materials /
  hire / refrigerant tiles and photos → Finish job. Pricing and approval are hidden from engineers.
- **Assets.** OPSAPI has no assets API (see API-NOTES 45), so an asset is the store product that
  was serviced. Asset search is product search, and history is jobs and requests filtered by `product_uuid`.
- **Sites.** Sites are customer-scoped. The app re-sends `site_uuid` after create or convert
  because the server drops it (API-NOTES 44).
- **Quotation (#611).** A manager can price the job's quote sheet up as a customer quotation,
  share the PDF, or email it (`POST /jobs/:uuid/quote-email`). The PDF is rendered on device —
  the server has no renderer and expects `pdf_base64`. A quote is an estimate; it bills nothing.
- **Fault category (#611)** is a reuse-or-create picker backed by
  `GET /field-service/fault-categories`, so categories converge instead of being retyped.
- **Invoices (#611)** can be emailed to the customer with the PDF attached, which also marks a
  draft as sent. Needs `invoices.update` — see the roles table.
- **Parts** show a low-stock flag at the catalogue's reorder level, since approving a part line
  now decrements stock server-side.

**Offline (engineers).**

- `ResponseCache` stores raw responses for the user's visits, their jobs (with phases) and visit
  details. These are prefetched when My Work loads (again when the open visits change or after ten
  minutes) and renewed by a `BGAppRefreshTask` (`MyWorkRefresh`) while the app is in the background.
  Cached data goes through the same decoders and is flagged "Offline copy from …".
- En-route, check-in, check-out, no-access, checklist ticks, phase status and quote-sheet lines go through
  `SyncCenter`. It sends online first and falls back to the persistent `MutationQueue` when there
  is no connection (or an earlier write to the same entity is still queued).
- The queue replays in order on reconnect or foreground. A server-rejected write is kept as
  **failed** with its message and offered as retry or discard. Nothing is removed without the user.
- Screens overlay queued writes (a ticked item shows "Waiting to sync"). A banner shows pending and
  failed counts.

**Reliability.**

- **Retries.** Reads retry twice with exponential backoff and jitter on a 5xx, a 429 (honouring
  `Retry-After`) or a dropped connection. Writes are never retried by the client: the mutation
  queue owns them, so a check-in can't be applied twice.
- **The offline queue backs off.** A write rejected by a struggling server waits (2s, doubling, up
  to five minutes) and holds only its own entity, so unrelated writes keep syncing. After eight
  attempts it is shown to the user as failed instead of retrying forever.
- **The cache is bounded.** Cached responses expire after 30 days, and the oldest are evicted once
  the cache passes 64MB.
- **Nothing sensitive is logged.** The redacting logger covers JSON *and* form-encoded bodies
  (`/auth/login` is form-encoded); anything it can't parse is logged as a byte count, not content.
- **Privacy manifest.** `WSLCRM/Resources/PrivacyInfo.xcprivacy` declares the required-reason APIs
  (UserDefaults, file timestamps) and the data the app sends to its own server. Confirm the
  collected-data list with the product owner before each App Store submission.

**Phone-first & accessibility.**

- Buttons are at least 56pt tall, and checklist rows are full-width toggles.
- Customer phone numbers are `tel:` links, and addresses open Apple Maps.
- Check-out uses steppers and quick reasons to keep typing to a minimum.
- Dynamic Type fonts are used throughout.
- Every status has an icon and a label, never colour alone.
- Controls have VoiceOver labels, values and hints.
- `EngineerFlowUITests` runs Apple's accessibility audit on every screen it visits (contrast,
  hit areas, labels, traits), and `LargeTextUITests` drives the app at an accessibility text size.
  Status pills wrap instead of truncating, and prominent buttons use darker fills so white text
  clears 4.5:1 — the system greens and oranges do not.

**Location.** Requested only at check-in/out, with a clear purpose string, and it never blocks the
action. There is an 8-second timeout, and denial is fine.

## Known limitations

See [`docs/API-NOTES.md`](docs/API-NOTES.md) for the backend gaps and bugs the app works around.
In short:

- Order detail may return 500 on some schemas; the app falls back to the list row plus status history.
- The product list is not tenant-scoped; it is scoped by store, with a client-side filter as fallback.
- Invoice PDFs are rendered on device, because the API has no PDF download.
- Push notifications are not implemented: the backend sends via FCM only, which would add Firebase.
  New assignments show through foreground polling and the in-app notification list.
- Assets are store products (the backend has no assets API), and jobs can't be searched by unit serial.
- Background refresh can't run on the Simulator. Test it on a device with Xcode's
  `_simulateLaunchForTaskWithIdentifier`.
