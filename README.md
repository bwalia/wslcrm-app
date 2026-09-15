# WSLCRM — iOS

Native iOS client (Swift 6, SwiftUI, iOS 17+) for the OpsAPI / Workstation platform. It uses
the same REST API as the web dashboard; the backend is not modified by this project.

Modules: **field service** (jobs, phases, visits with check-in/out, service requests),
**CRM** (accounts, contacts, deal pipeline), **customers**, **products**, **orders** and **invoices**.

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
| `PhaseCompletionUITests` | login → wrong/right 2FA code → job → phase: force prompt, checklist tick, completion |

UI test screenshots are kept in the result bundle:
`xcrun xcresulttool export attachments --path <bundle>.xcresult --output-path screens/`.

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
  Features/       Auth, Workspace, Home, Jobs, Visits, ServiceRequests, CRM, Customers, Products, Orders, Invoices
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

**Permissions.** `GET /api/v2/user/menu` provides grants plus `is_owner`/`is_admin`, and
`PermissionSet` mirrors the server rule. `FieldServicePolicy` adds the API's "engineer booked on
this job" overlay. Actions a user can't perform are hidden, not left to fail. Job and
service-request actions come from `allowed_transitions`.

**Offline (engineers).**

- `ResponseCache` stores raw responses for the user's visits, their jobs (with phases) and visit
  details, prefetched whenever the visit list loads. Cached data goes through the same decoders
  and is flagged "Offline copy from …".
- En-route, check-in, check-out, no-access, checklist ticks and phase status go through
  `SyncCenter`. It sends online first and falls back to the persistent `MutationQueue` when there
  is no connection (or an earlier write to the same entity is still queued).
- The queue replays in order on reconnect or foreground. A server-rejected write is kept as
  **failed** with its message and offered as retry or discard. Nothing is removed without the user.
- Screens overlay queued writes (a ticked item shows "Waiting to sync"). A banner shows pending and
  failed counts.

**Phone-first & accessibility.**

- Buttons are at least 56pt tall, and checklist rows are full-width toggles.
- Customer phone numbers are `tel:` links, and addresses open Apple Maps.
- Check-out uses steppers and quick reasons to keep typing to a minimum.
- Dynamic Type fonts are used throughout.
- Every status has an icon and a label, never colour alone.
- Controls have VoiceOver labels, values and hints.

**Location.** Requested only at check-in/out, with a clear purpose string, and it never blocks the
action. There is an 8-second timeout, and denial is fine.

## Known limitations

See [`docs/API-NOTES.md`](docs/API-NOTES.md) for the backend gaps and bugs the app works around.
In short:

- Order detail may return 500 on some schemas; the app falls back to the list row plus status history.
- The product list is not tenant-scoped; it is scoped by store, with a client-side filter as fallback.
- Invoice PDFs are rendered on device, because the API has no PDF download.
- Push notifications are not implemented: the backend sends via FCM only, which would add Firebase.
