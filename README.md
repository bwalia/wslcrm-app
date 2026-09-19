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
| `WSLCRM-DBS-Int` | `Debug-DBS-Int`, `Release-DBS-Int` | the same int host, DBS white-label (`Config/DBS-Int.xcconfig`) |
| `WSLCRM-Prod` | `Debug-Prod`, `Release-Prod` | supplied at build time |
| `WSLCRM-Local` | `Debug-Local` | `http://127.0.0.1:4011` (`Config/Local-API.xcconfig`) — Simulator only |

`WSLCRM-DBS-Int` is the demo build: int's data with DBS Ltd branding, so a demo needs no local
stack. `WSLCRM-Int` stays house-branded for ordinary integration testing. Sign in with the
accounts in `build/dbs-group-demo.env` (see "Seeding the demo into int" below).

### Switching environment without a rebuild

The **gear on the sign-in screen** repoints a build at any API. The address is validated (https
anywhere, plain http only for `127.0.0.1` / `localhost`), kept across relaunches, and shown on the
sign-in badge, which names the host once it differs from the build's own. "Use this build's default"
puts it back. Switching signs you out and clears cached responses: tokens minted by one server mean
nothing to another. `APIEndpoint` owns the rules, `APIEndpointController` applies them.

The badge is how to tell at a glance which server a build is talking to — a build showing
**Local environment** is on `127.0.0.1`, and accounts that exist only on int will not sign in there.

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
  Its data is a slice of the DBS Limited workspace below: Tom Fletcher on site at FreshWay Streatham
  with a tripping walk-in chiller (`JOB-2418`), invoiced as `INV-4821`.

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
| `WorkManagementTests` | the kanban envelope and its `permissions` block, the agent contract's round trip (including keys this build never reads), claim leases and staleness, run health, budgets, review decisions, idempotency markers, conflict detection, actor resolution, and the rule that an agent approves nothing |
| `WorkManagementUITests` | against the stub: logging and submitting time with no grant, a manager approving somebody else's, the board as a column pager with move-by-sheet, reviewing an agent's result and sending it back with a reason, taking over a stalled agent, and a card being refused agent-ready status without a definition of done |
| `DBSLimitedTourUITests` | a screenshot **and video** tour as DBS Limited's engineer, service manager and service desk against a seeded API, plus the DBS Ltd Simpro screens (asset register, PDF share, reports, sync status), an engineer recording a survey, the modules and permissions behind the More tab, and a checklist tick made with no signal. Skipped unless run by `scripts/run-dbs-screenshots.sh` or `scripts/record-dbs-video.sh` |
| `SimproDemoTests` | who sees assets, reports and Simpro sync per role (real grants from opsapi #612), asset and report decoding, report cell formatting, the report PDF (letterhead, legal footer, pagination), and white-label brand resolution |

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

### DBS Limited: realistic data and a screenshot tour

`scripts/seed-dbs-limited.py` adds a second workspace to the same local stack, modelled on an air
conditioning and refrigeration contractor working in London and the South East:

- **People.** Service managers Claire Donnelly and Marcus Reid, service desk coordinator Aisha Rahman,
  and six engineers (Tom Fletcher, Kwame Mensah, Jake Harrison, Ryan O'Connell, Piotr Kowalski,
  Sanjay Mistry). Sign in with the username, e.g. `tom.fletcher`.
- **Customers and sites.** A managing agent's offices, a restaurant group, a convenience-store chain, a
  GP practice's vaccine fridges, a data centre, a hotel, a primary school and a domestic heat pump.
  Each has site contacts, access notes, the plant on site and a stock list with low-stock parts.
- **The day.** It is built around *now*. Tom is on an out-of-hours cold-room call-out (F-Gas leak found,
  refrigerant waiting for approval) and Kwame is at a warm dairy multideck. The day's finished work has
  sign-offs and F-Gas records, and one visit was no-access. There is a vaccine-fridge job on hold for a
  part, a multi-day installation, tomorrow's bookings, an overdue PPM visit, a quotation, a guest
  complaint that has missed its SLA, and invoices that are draft, sent, overdue and paid.

Each step goes through the API as the person who would do it, then its timestamps are moved to when it
happened. Staff emails end in `@e2e.invalid`, so the server doesn't email sign-in codes, and customers
use `.example` addresses. The seed never calls the email routes.

```bash
scripts/seed-dbs-limited.py            # after scripts/local-opsapi-fs-seed.sh; writes build/dbs-limited.env
scripts/seed-dbs-limited.py --reset    # rebuild requests, jobs, visits and invoices around the current time
scripts/run-dbs-screenshots.sh         # opens the Simulator, runs the tour, PNGs in build/dbs-screenshots/
```

A curated set of that tour is committed in [`docs/screenshots/dbs-limited/`](docs/screenshots/dbs-limited):
the engineer's day (My Work, the guided visit, the checklist, the quote sheet with its F-Gas record,
the stock list, a job on hold for a part), the manager's board (hub, requests with a breached SLA,
an installation's parts and hire, a quotation, an invoice preview, the invoice list) and the service
desk logging a call.

### DBS Ltd: the CRM in front of Simpro

DBS Ltd (David Blakey Services Limited, 03806201) run their business on Simpro. The demo positions
OPSAPI as the CRM in front of it: the same data shapes and screens as Simpro, a connector that pulls
from and pushes to a Simpro build, and the report pack DBS publish on
[dbs.uk.com/simpro](https://dbs.uk.com/simpro). The server side is opsapi
[#612](https://github.com/bwalia/opsapi/pull/612); run the local stack from that branch.

`scripts/seed-dbs-portfolio.py` runs after `seed-dbs-limited.py` and loads DBS's real portfolio from
`scripts/dbs-portfolio.json`:

- **Customers, sites and projects** from the 22 case studies on [dbs.uk.com/projects](https://dbs.uk.com/projects)
  (BNP Paribas, Skanska's City of London contract, Sky Studios, Fitzharry's School, St Mary Magdalene
  Academy, Verulam Point, PureGym and others). Each project is a Simpro project job with cost
  centres, and three live projects are added.
- **Plant.** 129 assets built from the published plant: Sky's three Hoval UltraGas boilers, the 990 kW
  and 2 × 500 kW heat pumps, Verulam Point's 7 VRVs with 49 ducted FCUs and 4 Lossnays, and a sample
  of Skanska's 100+ boilers and 40 chillers. Each asset has contracts, service levels, 18 months of
  condition surveys on DBS's 1–6 scale, F-Gas leak checks and failures.
- **The business** at the scale Companies House shows: turnover £6.6m (FY24), 46 employees (FY25).
  The seed also adds licences (some expiring), remedial quotes, and a mock Simpro connection with a
  first pull and push already run.

Every value is tagged in the JSON as published (from DBS's site, their Simpro report pack or Companies
House) or assumed, e.g. project values, contract terms after handover, refrigerant charges and serial
numbers. Assumed values are illustrative, not DBS's figures. People are not taken from the website:
contacts are role-based with `.example` addresses, and the DBS team is the synthetic one above.

The Local configuration is white-labelled as **DBS Ltd** through `Config/Brand-DBS.xcconfig`: the app
name and icon, the sign-in mark, and the letterhead and legal footer on report PDFs. Int and Prod keep
the house brand (`Config/Brand-Default.xcconfig`). In the app:

- **Guided visit → Replace part.** An engineer proposes a replacement rather than logging a line:
  the part comes from the workspace catalogue, the price and VAT come with it, and a photo of the
  fault is required. All three go in one request (opsapi #619), which the server keeps together —
  no evidence, no proposal. The manager sees those photos against the pending line on the job, which
  is what they approve it on.
- **Field Service → Assets.** The register with condition, F-Gas and overdue filters. An asset shows
  its F-Gas position, service schedule and surveys, and an asset-history PDF. Engineers open it from
  **More** and record surveys on site.
- **Field Service → Reports.** The Simpro report pack (failure history, PPM forecast, routine
  maintenance, F-Gas register, licences, labour, response times, admin efficiency, Power BI extract).
  Each shares as a branded PDF (rendered on the phone) or the server's CSV. Engineers don't get
  reports.
- **Field Service → Simpro sync.** Read-only sync status for managers; pulls and pushes run from the
  web dashboard.

```bash
scripts/seed-dbs-limited.py --reset && scripts/seed-dbs-portfolio.py
OUT_DIR=build/dbs-simpro-screenshots scripts/run-dbs-screenshots.sh \
  -only-testing:WSLCRMUITests/DBSLimitedTourUITests/test4ManagerSimproReportsAndAssets \
  -only-testing:WSLCRMUITests/DBSLimitedTourUITests/test5EngineerSurveysAnAsset
```

For the web dashboard, run `opsapi-dashboard` with `NEXT_PUBLIC_API_URL=http://127.0.0.1:4011`,
`NEXT_PUBLIC_BRAND_NAME="DBS Ltd"` and `NEXT_PUBLIC_BRAND_LOGO_URL=/brands/dbs-ltd.svg`.
Screenshots of both surfaces, and a page of a generated report PDF, are in
[`docs/screenshots/dbs-ltd-simpro/`](docs/screenshots/dbs-ltd-simpro).

### Seeding the demo into int

Both seeds default to the local Docker stack, and take the same data to a cluster environment when
pointed at one. `psql` and the OTP lookup then go through `kubectl exec` instead of `docker exec`;
the API is reached over HTTPS either way. The demo lives in its own namespace, so it never touches
anyone else's workspace on a shared server.

```bash
export KUBECONFIG=~/.kube/k3s1.yaml
export KUBE_NAMESPACE=int PG_POD=workstation-db-0 DB=workstation_opsapi
export API_POD=$(kubectl -n int get pods -l app=workstation-opsapi -o name | head -1 | cut -d/ -f2)
export API=https://int-opsapi.workstation.co.uk
export NAMESPACE_SLUG=dbs-group-demo NAMESPACE_NAME="DBS Group"
export WSL_PASSWORD='…'          # one password for every seeded account; keep it out of the shell history

scripts/seed-dbs-limited.py && scripts/seed-dbs-portfolio.py
```

Usernames land in `build/$NAMESPACE_SLUG.env` (mode 600, git-ignored). The server needs
`TEST_OTP_CODE` set and `OPSAPI_DEPLOY_ENV` to be something other than prod, which is how int is
configured — the seed signs each person in through the real 2FA flow using that bypass. Build the
**WSLCRM-DBS-Int** scheme to point the branded app at it, and the screenshot tour takes the same
two variables:

```bash
SCHEME=WSLCRM-DBS-Int ENV_FILE=build/dbs-group-demo.env scripts/run-dbs-screenshots.sh
```

Screenshots from that run against int — the engineer's day, the manager's board, the service desk
and the Simpro screens, all reading the seeded **DBS Group** workspace — are in
[`docs/screenshots/dbs-int/`](docs/screenshots/dbs-int).

### The video tour

The same tour, filmed. `scripts/record-dbs-video.sh` records the Simulator while
`DBSLimitedTourUITests` drives every feature, then cuts the recording into a 1920×1080 video with a
chapter card per persona and a caption on each screen:

```bash
scripts/record-dbs-video.sh                                   # DBS Ltd build against int
SCHEME=WSLCRM-Local ENV_FILE=build/dbs-limited.env scripts/record-dbs-video.sh   # the local stack
scripts/record-dbs-video.sh -only-testing:WSLCRMUITests/DBSLimitedTourUITests/test4ManagerSimproReportsAndAssets
```

| Output | |
|---|---|
| `build/dbs-video/dbs-ltd-tour.mp4` | the tour: eight chapters, phone screen framed on a branded canvas |
| `build/dbs-video/dbs-ltd-tour-contents.pdf` | the contents sheet to send with it: every chapter and caption, timestamped |
| `build/dbs-video/chapters.txt` | chapter timestamps, for publishing it |
| `build/dbs-video/index.json` | the same contents as data |
| `build/dbs-video/screenshots/` | the same tour as stills |
| `build/dbs-video/raw.mov` | the untouched Simulator recording |

The chapters are signing in, the engineer's day, the manager's board, the service desk, the Simpro
CRM, an engineer surveying an asset, the modules and permissions behind the More tab, and working
with no signal. It runs about 21 minutes at roughly 850 MB, H.264 so anything will play it;
`chapters.txt` gives the timestamps to jump by.

How it fits together:

- **`WSLCRMUITests/DBSTourNarration.swift`** holds the script — one line per screenshot — and
  stamps a marker each time a screen has settled. With `TOUR_VIDEO=1` the tour also holds each
  screen long enough for its caption to be read.
- **`scripts/tour-video.swift`** cuts and captions the recording with AVFoundation and Core
  Graphics. Nothing to install: no ffmpeg, no editor.
- **`scripts/cut-dbs-video.sh <out-dir>`** runs that step on its own, so the captions or the title
  can be changed and the video re-cut without filming the tour again.
- **`scripts/tour-chapters-pdf.swift`** draws the contents sheet from `index.json`. That index is
  written by the compositor, so its timestamps are the video's own arithmetic rather than a second
  copy of it — `swift scripts/tour-video.swift <spec.json> --index-only` recomputes it in seconds
  when only the sheet needs redoing.
- Captions are lined up by comparing the tour's own screenshots against frames of the recording,
  so a slow recorder start cannot put every line a second out.
- Footage between chapters is dropped, as is anything a `TourNarration.cut` marks — the wait while
  a faked outage runs its course, and **the two-factor code being typed**, which would otherwise be
  readable on film.

The tour writes as little as it can: a part proposal with its photo, a condition survey, and one
checklist tick made offline. `scripts/seed-dbs-limited.py --reset && scripts/seed-dbs-portfolio.py`
puts the workspace back.

### Capturing fixtures from the real API

```bash
scripts/vault-env.py exec -- scripts/capture-fixtures.py   # credentials from WSL Vault; waits for the 2FA code
```

It logs in, performs **read-only** requests, anonymises names/emails/phones/addresses and writes
`WSLCRMTests/Fixtures/live/live_*.json`. Without a TTY it waits for the code in
`scripts/.capture/otp`. Review the files before committing.

---

## Work management: projects, tasks, timesheets — and agents

One board carries work done by people and work done by agents, under the same rules. The modules
are `Features/Projects` (kanban projects, boards, tasks, sprints, time tracking) and
`Features/Timesheets`, reached from the More tab.

- **Timesheets** — your own time needs no module grant (those routes are namespace-gated only), so
  everyone gets "My time"; the approval queue appears only for someone holding
  `timesheet_approvals`. Statuses follow the server: draft → submitted → approved or sent back,
  and a rejection carries its reason.
- **Projects and boards** — you see only projects you are a member of. A board is shown as a
  **column pager** rather than a scrolling wall: one column at a time, named with its count, and
  cards move through a "Move to…" sheet, which is faster one-handed and works with VoiceOver.
- **My tasks** and **Waiting for me** are the two home screens. The second is the review queue —
  everything an agent has finished that needs a person's decision.

### The agent side

A card an agent may pick up carries a contract under `metadata.agent`: goal, acceptance criteria,
definition of done, budget, review requirement, claim, run state and result. The app reads and
writes it losslessly — an agent may add keys this build has never heard of and they survive the
round trip. `docs/AGENTS.md` is the contract as an agent builder needs it, and
`scripts/agent-example.py` runs the whole loop against a real server in about a hundred lines.

Four things the app does because the API cannot yet:

| | |
|---|---|
| **Claims are leases** | with an expiry and a heartbeat. A lease that runs out is offered to whoever is looking at the card, so an agent that dies mid-run cannot hold work for ever. |
| **Conflicts surface** | `updated_at` is compared either side of a write; if the row moved, the app says so and reloads rather than overwriting somebody's edit. |
| **Writes are idempotent by convention** | comments carry an `<!-- idem:… -->` marker so a retry can recognise its own write. |
| **Nothing is queued that shouldn't be** | these modules do not use the offline queue yet: a write needs a connection and says so. When queueing is added it covers a checklist tick or a comment only — never a task move, a claim or a timer, because positions, leases and clocks are contended and replaying them later invents history. |

And two rules that do not bend: an agent approves nothing — not its own work, not another agent's,
not a timesheet — and every actor is named and marked as person or agent wherever it appears, by
glyph as well as colour. An agent is identified by the credential it holds (`api-key:<name>`),
because revoking that key is how a person stops it.

**Known gap:** an `opsk_…` API key authenticates as a principal whose uuid matches no `users` row,
while every kanban task route checks project membership by user uuid — so a key is refused today
and an agent must run as a bot user account. That, and the six other server changes this design
wants, are listed at the end of `PROMPT-work-management.md`.

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
| **Service manager** | `manage` on requests, jobs, visits, job types, parts, employees, customers, products, invoices, payments and timesheet approvals; `timesheets` read | The full board: convert and assign, approve items, quote, invoice, email the invoice and record the payment. |
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
  draft as sent. Needs `invoices.update`, which the Service Manager role now has.
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
