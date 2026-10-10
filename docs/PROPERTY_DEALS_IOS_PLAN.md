# Property Deals on iOS — Phase 1 plan

Status: **draft for approval**. Built against the Property Deals contract v1
(`opsapi/docs/property-deals/API.md`, OpenAPI in `projects/property-deals/api/openapi.lua`, opsapi
branch `bsw/property_deals_backoffice` at `e40988b`). No backend code changes in this repo; gaps are
written up in `opsapi/docs/property-deals/api-requests/ios-*.md` (§7).

Base path below: `/api/v2/property-deals`, abbreviated `PD`.

## 1. What we reuse (nothing new at the core level)

| Need | Existing piece |
|---|---|
| Networking, envelopes, paging, errors, retries | `APIClient`, `Endpoint`, `Envelopes`, `APIError`, `RetryPolicy` |
| Auth, 2FA, Keychain tokens, refresh | `SessionStore`, `KeychainTokenStore` (no LLM or integration keys on device; all AI is server-side) |
| Workspace switch | `WorkspacePickerView`, `X-Namespace-Id`, `MainTabView().id(workspaceGeneration)` |
| Roles | `PermissionSet` for core; new `PDAccess` from `GET PD/me` for the plugin (§2) |
| Read cache | `ResponseCache` (per namespace) |
| Offline writes | `MutationQueue` / `PendingMutation` / `SyncCenter`, `SyncStatusBanner`, `PendingChangesView` |
| Face ID / Touch ID + passcode | `BiometricGate.authenticate(reason:)` |
| Photos | `Endpoint` multipart (as `FieldServiceAPI.uploadPhoto`) |
| GPS | `LocationProvider` |
| Task checklist, comments, attachments | `KanbanAPI` (property tasks **are** kanban tasks: same `task_uuid`) |
| Design system | `LoadState`, `PagedList`, `StatusPresentation`, `Formatters`, `Components` |
| UI tests | `UITestStubServer` (in-process OpsAPI) + launch args |

New code lives in `WSLCRM/Features/PropertyDeals/` (`PropertyDealsAPI.swift`, `PropertyDealsModels.swift`,
one file per screen), plus small additions in `Core/Push/` and `Core/Offline/`. Models are written by
hand to match the OpenAPI schemas exactly (the app has no generator), with every non-required field
optional because the API leaves nulls out. Decoding tests use fixtures taken from the contract examples.

## 2. Module on/off and roles

- After sign-in and on every workspace switch, call `GET PD/me`.
  - `404` with `code: PLUGIN_DISABLED` (or `setup_done == false`) → module hidden.
  - Otherwise keep `permissions[module]` (`deals, properties, tasks, approvals, compliance, …`) in a
    `PDAccess` value on `SessionStore`, and use it for every button. A 403 still shows "You don't have
    access" and hides the button next time.
- The plugin has no main menu key (its only menu entry is "Bank holidays"), so `/user/menu` can't be
  used to gate it the way the Shop tab is gated; `/me` is the gate.
- `pd_agent` (AI service account) never sees approve buttons, matching the existing
  `canReviewAgentWork` rule.

## 3. Screen map

A new **Deals** tab (house icon), shown when `PDAccess` is present. `NavigationPolicy.home` lands
property users on it when the workspace has no field service.

```
Deals tab
├─ Today (root)            counts strip · Overdue / Due today / Waiting on others · red deals · approvals banner
│   ├─ Task detail         context · deal link · checklist · notes · attachments · call / WhatsApp / email
│   └─ Deal view
├─ Approvals (toolbar, badge = approvals_waiting_count)
│   └─ Approval detail     draft · sources · agent / model / JobShout · edit · approve (Face ID) / reject + note
├─ Deals list              filter chips: Red · Amber · Mine
│   └─ Deal view           stage strip · health + £ at risk · dates · blockers · next tasks · compliance · parties
└─ Quick capture (＋)       seller lead and/or property · photos · voice note · GPS + address · situation · deadline
More → Settings            + Notifications section (per-category push toggles) — workspace switch and sign out exist
```

Deep links (push taps and `wslcrm://pd/<route>/<uuid>` for tests): `task` → Task detail, `approval` →
Approval detail, `deal` → Deal view, `digest` → Today. The app switches to the payload's `namespace_id`
first.

## 4. API calls per screen

| Screen | Read | Write |
|---|---|---|
| Today | `GET PD/today?limit=100` (poll every 60 s while visible; pull to refresh). Sections: `overdue == true` → Overdue; due today (workspace `timezone` from `/me`) → Due today; `pd_status` `waiting_third_party` / `awaiting_approval` / `agent_running` → Waiting on others; the rest → Later. Colour from `urgency_score` + `overdue`; "why" = top `urgency_why[].why` | Swipe: complete `PUT PD/tasks/{uuid} {pd_status:"done", evidence:{note}}` · snooze `{snoozed_until, snooze_reason}` (reason sheet) · Let AI do it (§6) |
| Task detail | `GET PD/tasks/{uuid}`; checklist `GET /api/v2/kanban/tasks/{uuid}/checklists`; notes `…/comments`; attachments `GET PD/documents?task_uuid=`; contact from `GET PD/deals/{id}/overview` → `parties` | Complete / snooze as above; tick checklist `PUT /kanban/checklist-items/{uuid}/toggle`; add note `POST /kanban/tasks/{uuid}/comments`; after call / WhatsApp / email: `POST PD/chases {deal_uuid, task_uuid, to_party, to_name, channel, subject}` |
| Approvals | `GET PD/approvals/inbox` (cached read-only offline) | `POST PD/approvals/{id}/decide` — `approve` (optionally with edited `payload`, `note`) after Face ID, or `reject` with required `note`. **Online only** (§5) |
| Deals | `GET PD/deals?status=active&health=red` · `…&health=amber` · `…&owner_user_uuid=<me>`; detail `GET PD/deals/{id}/overview` (blockers = `enquiries` + `stage.next_gate.missing`; next tasks = `tasks.open`) | none (read-mostly) |
| Quick capture | — | `POST /api/v2/crm/leads` → `PUT PD/leads/{uuid}/details {lead_kind:"seller", situation, deadline_date, vulnerability_flag?, property_uuid?}`; `POST PD/properties {address_line1, postcode, town, lat, lng}`; photos `POST PD/documents` multipart `file`, `category:"photo"`, `property_uuid`; voice note transcript into lead `notes` |
| Notifications | — | `POST /api/v2/device-tokens {token, token_type:"apns", apns_environment, bundle_id, device_name}`; delete on sign-out |
| Settings | preferences (gap, §7) | preferences (gap, §7) |

## 5. Offline and poor signal

- **Cached for reading:** `/today`, `/approvals/inbox`, each opened `/deals/{id}/overview` and
  `/tasks/{uuid}`; the Deals lists. Shown with the existing "cached at …" treatment.
- **Queued:** complete, snooze, notes, checklist ticks, contact logs, and captured leads/properties/photos,
  as new `PendingMutation.Kind`s. They use the existing replay rules (per-entity order, backoff, 4xx shown
  as failed, never dropped silently) and show in the sync banner and Pending changes. Today and the task
  show the optimistic state with an "Not synced" badge.
- **Capture is a chain** (lead → details → property → photos; later steps need ids from earlier
  responses). It is one queued "capture" item with ordered steps; each finished step stores the returned
  uuid in the item, so a retry resumes where it stopped. Photos are kept on disk until uploaded.
- **Approvals are never queued.** The decide call bypasses `MutationQueue`, the Approve / Reject buttons
  are disabled offline with a reason, and a unit test proves no approval reaches the queue. (API.md §3
  says decides *may* be queued; the iOS rules forbid it, and we follow the iOS rules.)
- Before approving, the app re-fetches the approval so it shows the current version (plus the version
  guard requested in §7 so the server refuses a stale approval).

## 6. Not in v1 of the API (handled, not worked around)

- **Let AI do it**: `POST PD/tasks/{uuid}/agent-run` is Phase 5. The swipe action and button appear only
  for `agent_eligible` tasks and call the planned endpoint; until it exists the call returns 404 and the
  app says "AI pick-up isn't switched on for this server yet". The UI test uses a clearly marked mock in
  the stub server with the planned shape `{ agent_run, approval? }`.
- **Approval execution** (`executed` / `failed`) is Phase 5: shown when present, otherwise "Approved".
- **Approval-request pushes** are Phase 5; the payload contract is already fixed, so the app handles
  `route: approval` now.

## 7. Missing API pieces (api-request files written)

| File | What |
|---|---|
| `ios-approval-version-guard.md` | `decide` accepts the `payload_version` (or `payload_sha256`) the approver saw and answers 409 if the draft has changed — so nothing is sent based on old data. |
| `ios-idempotent-creates.md` | `Idempotency-Key` header (or client uuid) on `POST /crm/leads`, `POST PD/properties`, `POST PD/documents`, `POST PD/chases`, so an offline replay after a lost response doesn't create duplicates. |
| `ios-notification-preferences.md` | Per-user push/email toggles for SLA warnings, overdue, escalations, approvals, digest, compliance expiring; honoured by `property_deals/notify.lua`. Nothing exists today (core `notification_preferences` covers only shop orders). |
| `ios-contact-log-without-deal.md` | Log a call / WhatsApp / email on a task that has no deal yet (lead-stage tasks): `property_deals_chases.deal_uuid` is NOT NULL. |

Mocks for these are behind `PDMock` flags in the stub server only; the live app degrades (e.g. the
notification toggles are hidden until the endpoint exists).

## 8. Platform work (no API needed)

- Push: `aps-environment` entitlement, `UIApplicationDelegateAdaptor` for token callbacks,
  `UNUserNotificationCenter` delegate for taps, `apns_environment` from the build (Debug → development,
  TestFlight/App Store → production). **Ops step for you:** enable Push Notifications on the App ID
  `uk.co.workstation.wslcrm` and give the OpsAPI server `APNS_KEY_ID`, `APNS_TEAM_ID` and
  `APNS_KEY_PATH` (path to the `.p8` key file inside the container).
- Voice: `AVAudioRecorder` + `SFSpeechRecognizer` with `requiresOnDeviceRecognition` when supported
  (falls back to typing, never to server transcription of the audio in v1).
- Address from GPS: `CLGeocoder` reverse geocode on device.
- Contacts: `tel:`, `https://wa.me/<number>`, `mailto:`; when the user comes back, "Log this call?"
  pre-filled.
- Info.plist: new strings for microphone and speech recognition; camera, photo library and location
  strings reworded to cover property capture; `whatsapp` added to `LSApplicationQueriesSchemes`.
- Dynamic Type, VoiceOver labels (urgency read as words, not colour alone), dark mode via semantic
  colours — checked on every screen, audited in Phase 5.

## 9. Tests

- Unit: model decoding from contract fixtures (nulls omitted), Today sectioning across time zones,
  urgency colour mapping, capture chain resume, "approvals never queued", deep-link routing incl.
  workspace switch.
- XCUITest (stub server), the SPEC §5 phone path: launch with an injected push payload for the overdue
  EPC task → task opens; Approvals shows the AI chase draft; approve with simulated Face ID (biometric
  gate stubbed in UI-test builds) → stub records the decide call; Deal view shows red and £7,000 at risk.
  Plus a negative test: offline → approve disabled.

## 10. Phases after approval

2. Today, Task detail, Deals (+ `/me` gating, models, cache, queue kinds for complete/snooze/notes).
3. Approvals with Face ID; push registration and deep links.
4. Quick capture (photos, voice, GPS) and the capture chain in the offline queue.
5. Polish, accessibility pass, XCUITests incl. the SPEC §5 scenario.

Each phase ends with simulator screenshots in `docs/screenshots/property-deals/`.

## 11. Contract v1.4–1.5 and purchase orders (opsapi #709–#711)

| Screen | Calls | Notes |
|---|---|---|
| Today → Hot leads: call now | `GET /hot-leads` | Call dials; Called logs `POST /tasks/{call_task}/contact-log` then `PUT /tasks/{call_task} pd_status=done`, queued as one chain (`.pdCalled`) |
| Lead | `GET /leads/{id}`, `GET/POST /leads/{id}/replies`, `GET/POST /leads/{id}/signals` | A logged reply shows its score; hot raises the server's call task. Social posts are pasted, never fetched |
| Today → Due soon | `GET /due?days=&mine=` | Overdue / Today / Tomorrow / Later in the workspace zone; managers see the team, "Only mine" filters. Renovation jobs open as kanban cards |
| Today → Renovations, deal → Renovation | `GET/POST /renovations` | Opens the board in Projects; "Purchase orders" lists that board's POs |
| More → Purchase orders | `/api/v2/purchase-orders` (+ `stats`, `send`, `email`, `acknowledge`, `receive`, `convert-to-bill`, `cancel`, lines) | Gated on menu key / grant `purchase_orders`. Receive sends running totals per line |
| Settings → Notifications | category `hot_lead` | Push and email switches; ntfy / Telegram / SMS are set up on the web |

Seen on int: `due_at` and other timestamps come back as `2026-10-09 15:31:19.360831+00` (not ISO 8601); `APIDate` already reads them.
