# Build "WSLCRM" — a native iOS app (Swift) for the OpsAPI / Workstation platform

## Context

WSLCRM is the iOS client for an existing multi-tenant SaaS backend (OpsAPI: OpenResty +
Lua/Lapis + PostgreSQL). **The backend already exists and must not be changed** — the web
dashboard and this app consume the *same* REST API. Your job is the iOS app only. If you
believe an endpoint is missing, list it in your final report rather than editing the backend.

- API base (int/test): `https://int-opsapi.workstation.co.uk`
- API base (prod): supplied at build time — make it a build-configuration value, never hardcoded
- Interactive API reference: `<base>/swagger` and `<base>/openapi.json` — **read this first and
  treat it as the source of truth**; the endpoint list below is a summary, not a substitute.

## Scope — ship these modules

1. **CRM** — accounts, contacts, deals (pipeline view)
2. **Customers**
3. **Products**
4. **Orders**
5. **Invoices**
6. **Service requests** (customer complaints/enquiries) → convert to job
7. **Jobs and job phases** (field service), including engineer site visits

## Authentication (mandatory 2FA — get this right first)

Every user requires 2FA; there is no single-call login.

1. `POST /auth/login` with `{ "identifier": "<email or username>", "password": "..." }`
   → `200 { requires_2fa: true, session_token: "...", email: "..." }` (no JWT yet)
2. `POST /auth/2fa/verify` with `{ "session_token": "...", "code": "123456" }`
   → `{ token: "<JWT>", refresh_token: "...", user: {...}, namespaces: [...] }`
3. `POST /auth/2fa/resend` to re-send the emailed code
4. `POST /auth/refresh` with `{ "refresh_token": "..." }` to renew; `POST /auth/logout` revokes
5. `GET /auth/me` returns the current user

Also: `POST /auth/forgot-password`, `POST /auth/reset-password`.

**Every authenticated request must send BOTH:**

- `Authorization: Bearer <JWT>`
- `X-Namespace-Id: <namespace uuid>` — the tenant. A user may belong to several namespaces;
  provide an in-app workspace switcher, persist the selection, and re-fetch everything on change.

Store the JWT and refresh token in the **Keychain** (never UserDefaults). On `401`, attempt one
refresh, then fall back to logout. Support Face ID / Touch ID to unlock a stored session.

## The API's real shape — three things that will bite you

1. **Response envelopes are inconsistent between modules.** Do not write one generic decoder
   and assume it fits:
   - CRM + field service: `{ "success": true, "data": <object|array>, "meta": { total, page, per_page, total_pages } }`
   - Customers / products: `{ "data": [...], "total": N }`
   - Invoices: `{ "success": true, "data": ... }`, paging via `perPage`

   Model this explicitly (e.g. per-module `Envelope` types), and write tests for each.
2. **Timestamps are naive UTC strings** like `"2026-09-12 08:00:00"`, sometimes with
   microseconds (`"...:44.861944"`). They carry no timezone. Write a custom `JSONDecoder`
   date strategy: replace the space with `T`, truncate fractional seconds to milliseconds,
   append `Z`. When sending times, always send ISO-8601 UTC.
3. **Errors come in two shapes**: `{ "success": false, "error": "message" }` and a catalogued
   envelope `{ "error": { code, title, message, correlation_id } }`. Decode both; surface
   `correlation_id` in a copyable debug view — support asks for it.

Entities are addressed by `uuid`, never by numeric id. Paginated lists use `page` / `per_page`.

## Endpoints (verified — check Swagger for parameters and bodies)

**CRM**

- `GET|POST /api/v2/crm/accounts`, `GET|PUT|DELETE /api/v2/crm/accounts/:uuid`
- `GET|POST /api/v2/crm/contacts`, `GET|PUT|DELETE /api/v2/crm/contacts/:uuid`
- `GET|POST /api/v2/crm/deals`, `GET|PUT|DELETE /api/v2/crm/deals/:uuid`
- `GET /api/v2/crm/pipelines/:pipeline_uuid/deals`, `GET /api/v2/crm/dashboard/stats`

**Customers / Products**

- `GET|POST /api/v2/customers`, `GET|PUT|DELETE /api/v2/customers/:id`
- `GET|POST /api/v2/products`, `GET|PUT|DELETE /api/v2/products/:id`

**Orders**

- `GET|POST /api/v2/orders`, `GET /api/v2/orders/:id`, `POST /api/v2/orders/:id/status`
- `GET /api/v2/orders/stats`, `GET /api/v2/orders/:id/available-transitions`,
  `GET /api/v2/orders/:id/status-history`

**Invoices**

- `GET|POST /api/v2/invoices`, `GET|PUT|DELETE /api/v2/invoices/:uuid`
- `GET /api/v2/invoices/dashboard/stats`, `GET /api/v2/invoices/tax-rates`
- Line items and payments — see Swagger (21 endpoints in this module)

**Service requests**

- `GET|POST /api/v2/field-service/service-requests`
- `GET|PUT|DELETE /api/v2/field-service/service-requests/:uuid`
- `POST .../:uuid/status`, `POST .../:uuid/assign`, `POST .../:uuid/convert-to-job`

**Jobs and job phases** (the heart of the app)

- `GET|POST /api/v2/field-service/jobs`, `GET|PUT|DELETE /api/v2/field-service/jobs/:uuid`
- `POST /api/v2/field-service/jobs/:uuid/status` — body `{ status, reason?, force? }`
- `POST /api/v2/field-service/jobs/:uuid/phases`, `PUT /api/v2/field-service/jobs/:uuid/phases/reorder`
- `PUT|DELETE /api/v2/field-service/job-phases/:uuid`
- `POST /api/v2/field-service/job-phases/:uuid/status` — `{ status, signoff_name?, force?, notes? }`
- `POST /api/v2/field-service/job-phases/:uuid/checklist/:index` — `{ done }`, index is **0-based**
- Items: `POST /api/v2/field-service/jobs/:uuid/items`, `PUT|DELETE /api/v2/field-service/job-items/:uuid`,
  `POST /api/v2/field-service/job-items/:uuid/approve|reject`
- Billing: `GET /api/v2/field-service/jobs/:uuid/invoice-preview`, `POST /api/v2/field-service/jobs/:uuid/invoice`

**Visits** (engineer on site)

- `GET /api/v2/field-service/visits` (`?mine=true`, `from`/`to` as UTC ISO bounds)
- `POST /api/v2/field-service/jobs/:uuid/visits`, `GET|PUT|DELETE /api/v2/field-service/visits/:uuid`
- `POST /api/v2/field-service/visits/:uuid/en-route|check-in|check-out|no-access|cancel`

**Supporting**: `GET /api/v2/field-service/stats`, `/engineers`, `/job-types`, `/parts`,
`GET /api/v2/user/menu` (backend-driven navigation + the caller's permissions).

## Domain rules the UI must respect

- **Job status**: `draft → scheduled → in_progress → completed`, plus `on_hold` / `cancelled`.
  The job payload carries `allowed_transitions` — **render actions from that**, don't hardcode.
  Completing a job with unfinished phases returns `422` mentioning `force`; offer "complete anyway".
- **Phase status**: `pending`, `in_progress`, `blocked`, `completed`, `skipped`.
  - A phase with `requires_signoff` cannot complete without `signoff_name` → prompt for it.
  - Completing with unticked checklist items returns `422` → offer a "complete anyway" (`force`) path.
  - Phases are ordered by `sort_order`; support drag-to-reorder via the reorder endpoint.
- **Visits**: `scheduled → en_route → on_site → completed`, plus `no_access` / `cancelled`.
  Check-in/out accept optional `latitude`/`longitude` — request location only at that moment, with
  a clear purpose string. Check-out submits the work report, labour hours, customer sign-off name,
  a follow-up flag, and can complete the linked phase.
- **Permissions**: the API enforces RBAC per module (`fs_jobs`, `fs_visits`, `crm_accounts`,
  `invoices`, …) and returns `403` with `{ required: { module, action } }`. Read the caller's
  permissions from `GET /api/v2/user/menu` and **hide actions the user cannot perform** rather
  than letting them fail. Engineers typically see only their own visits.

## Technical requirements

- **Swift 6 / SwiftUI**, iOS 17+, MVVM with `@Observable` view models, `async/await` throughout.
- **No third-party dependencies** unless justified in the report — `URLSession`, `Codable`,
  Swift Concurrency and Keychain cover this.
- One `APIClient` actor: base URL from config, header injection, token refresh (single-flight,
  no thundering herd), typed errors, request/response logging behind a debug flag.
- Offline-friendly for engineers: cache the current user's visits and their jobs/phases
  (SwiftData or a simple file cache), queue check-in/check-out/checklist mutations made while
  offline and replay them on reconnect, showing clear pending/failed state. Never silently drop a write.
- **Phone-first layouts.** Engineers use this one-handed, outdoors, in gloves: large tap targets,
  high contrast, minimal typing, `tel:` links for site contacts, and a maps link for the address.
- Accessibility: Dynamic Type, VoiceOver labels on every control, no colour-only status encoding.
- Pull-to-refresh, empty states, skeleton loading, and inline error rows with a retry action.
- Tests: unit tests for decoding each module's envelope shape and the date strategy, the
  token-refresh path, and the offline replay queue. UI tests for login → 2FA → job → phase
  completion. Stub the network with fixtures captured from the real API.

## Deliverables

1. Xcode project building cleanly for simulator and device, no warnings.
2. `README.md`: setup, how to point at int vs prod, test credentials guidance, architecture overview.
3. A short note listing any API gaps, inconsistencies or bugs you hit (do not fix the backend).

## Working method

Start by fetching `<base>/openapi.json` and hand-writing the model layer from it — do not guess
field names. Build in this order, verifying each against the live int API before moving on:
**auth + namespace switching → jobs list → job detail with phases → visits and check-in/out →
service requests → CRM/customers/products → orders → invoices.** Get one vertical slice working
end to end before broadening.
