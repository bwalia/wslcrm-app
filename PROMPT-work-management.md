# Work management for WSLCRM — one board, people and agents working it together

## Context

WSLCRM is the native iOS client (Swift 6 / SwiftUI, iOS 17+) for the OpsAPI / Workstation
platform. It already ships field service (My Work, guided visits, jobs, phases, service requests,
invoicing), the Simpro-aligned asset register and report pack, CRM, customers, products and
orders. **The backend already exists and must not be changed** — the web dashboard and this app
consume the same REST API. Where the backend needs to change for this to work properly, say so in
the report; a section at the end lists what I already know is missing.

Four things exist server-side and on the web dashboard, and **none is in the iOS app today**
(verified: no timesheet, project, task, board, sprint or kanban code anywhere in `WSLCRM/`):

1. **Timesheets** — time capture with submit → approve → reject → reopen.
2. **Projects** — kanban projects with members, roles, stars and stats.
3. **Task boards** — JIRA-style boards, columns, task numbers, assignees, labels, comments,
   checklists, attachments and a per-task activity log.
4. **Sprints and time tracking** — backlog, sprint start/complete, burndown, velocity, a running
   timer and per-task time entries with approval.

The app parses `timesheets` and `timesheet_approvals` out of the caller's grants
(`GET /api/v2/user/menu`) and ignores them. Nothing parses `projects`.

## What this is really for

Build the four modules — and build them so that **a task is worked either by a person on a phone
or by an AI agent over the API, on the same board, under the same rules**. Not an "AI features"
sidebar. The same columns, the same sprint, the same activity log, the same time entries; the
phone is where a person steers the machine work, reviews it, takes it over when it stalls, and
signs it off.

Two consequences run through everything below:

- **Nothing in the app may assume the actor is human.** Every card, comment, activity row, time
  entry and approval shows who did it and whether that "who" is a person or an agent.
- **Two workers will touch one task at the same time.** The API has no locking, no versioning and
  no idempotency (see "Working in parallel"). The client has to behave well anyway.

## Read these first

- **The live API** — `https://int-opsapi.workstation.co.uk/swagger` and `/openapi.json`. Source of
  truth; the list below is a verified summary, not a substitute.
- **The web dashboard**, which is the behaviour to mirror (`opsapi/opsapi-dashboard`):
  `app/dashboard/timesheets/page.tsx` (list, two tabs, log-time modal, summary, approve/reject),
  `app/dashboard/timesheets/[uuid]/page.tsx`, `app/dashboard/projects/page.tsx` (cards,
  Active/Completed/Starred, progress), `app/dashboard/projects/[uuid]/page.tsx` (the board),
  `app/dashboard/projects/[uuid]/sprints/page.tsx` and `sprints/burndown/page.tsx`,
  `components/kanban/*`, and the services `kanban.service.ts`, `sprint.service.ts`,
  `time-tracking.service.ts`, `timesheets.service.ts` with the types in `types/index.ts`.
- **The machine-credential path** (`opsapi/lapis`): `routes/api-keys.lua`, `helper/api-key.lua`,
  `middleware/auth.lua`, `middleware/namespace.lua`. Read these before designing anything for
  agents — they decide what an agent can and cannot be.
- **This repo**: `README.md`, `docs/API-NOTES.md`, and the feature folders under
  `WSLCRM/Features/` as the pattern to copy.

## Scope

**A. The four modules on iOS**, phone-first, in this order: timesheets (mine, then approval
queue) → projects → board and task detail → sprints, backlog and time tracking. Plus a **My Tasks**
home (`GET /api/v2/kanban/my-tasks`), which is where a phone user starts.

**B. The agent-aware layer in the app** — actor identity, the review queue, run state on a card,
takeover, stop, conflict handling, and agent time in the same reports as human time.

**C. The agent contract** — `docs/AGENTS.md` in this repo: the JSON an agent reads off a task, the
lifecycle it must follow, the claim rules, and a worked example. The app renders this contract, so
it lives with the app; an agent runtime or MCP server built against it belongs beside opsapi.

**D. The server gaps** — a written list of what the backend needs before this is safe in
production. Do not implement them here.

## Endpoints (verified against `lapis/routes/` on the int branch)

**Timesheets** — envelope `{ success, data }`, paging `page` / `per_page`

- `GET|POST /api/v2/timesheets`, `GET|PUT|DELETE /api/v2/timesheets/:uuid`
- `POST /api/v2/timesheets/:uuid/submit|approve|reject|reopen`
- `GET|POST /api/v2/timesheets/:uuid/entries`, `PUT|DELETE /api/v2/timesheets/entries/:entry_uuid`
- `GET /api/v2/timesheets/approval-queue`, `/summary`, `/lookups/customers`, `/lookups/tasks`

**Projects** — envelope `{ success, data, meta: { total, page, perPage, totalPages }, permissions }`

- `GET|POST /api/v2/kanban/projects`, `GET|PUT|DELETE /api/v2/kanban/projects/:uuid`
- `GET /api/v2/kanban/projects/:uuid/stats`, `POST /api/v2/kanban/projects/:uuid/star`
- `GET|POST /api/v2/kanban/projects/:uuid/members`,
  `PUT /api/v2/kanban/projects/:uuid/members/:user_uuid/role`,
  `DELETE /api/v2/kanban/projects/:uuid/members/:user_uuid`
- `GET /api/v2/kanban/my-tasks`, `GET /api/v2/kanban/namespace/projects`

**Boards and columns**

- `GET|POST /api/v2/kanban/projects/:project_uuid/boards`
- `GET|PUT|DELETE /api/v2/kanban/boards/:uuid`, `GET /api/v2/kanban/boards/:uuid/full`
- `GET /api/v2/kanban/boards/:uuid/stats`, `PUT /api/v2/kanban/boards/:uuid/reorder`
- `POST /api/v2/kanban/boards/:uuid/columns`, `PUT|DELETE /api/v2/kanban/columns/:uuid`,
  `PUT /api/v2/kanban/boards/:uuid/columns/reorder`

**Tasks**

- `GET|POST /api/v2/kanban/boards/:board_uuid/tasks`, `GET|PUT|DELETE /api/v2/kanban/tasks/:uuid`
- `PUT /api/v2/kanban/tasks/:uuid/move` — body `{ column_id, position? }`
- `GET|POST /api/v2/kanban/tasks/:uuid/assignees`, `DELETE .../assignees/:user_uuid`
- `GET|POST /api/v2/kanban/tasks/:uuid/labels`, `DELETE .../labels/:label_id`
- `GET|POST /api/v2/kanban/tasks/:uuid/comments`, `PUT|DELETE /api/v2/kanban/comments/:uuid`
- `GET|POST /api/v2/kanban/tasks/:uuid/checklists`, `POST /api/v2/kanban/checklists/:uuid/items`,
  `PUT /api/v2/kanban/checklist-items/:uuid/toggle`, `DELETE /api/v2/kanban/checklist-items/:uuid`
- `GET /api/v2/kanban/tasks/:uuid/activities`, `GET|POST /api/v2/kanban/tasks/:uuid/attachments`
- `GET|POST /api/v2/kanban/projects/:project_uuid/labels`, `PUT|DELETE /api/v2/kanban/labels/:uuid`

**Sprints**

- `GET|POST /api/v2/kanban/projects/:project_uuid/sprints`, `GET|PUT|DELETE /api/v2/kanban/sprints/:uuid`
- `POST /api/v2/kanban/sprints/:uuid/start|complete|cancel`
- `GET|POST|DELETE /api/v2/kanban/sprints/:uuid/tasks`
- `GET /api/v2/kanban/sprints/:uuid/burndown`, `/summary`
- `GET /api/v2/kanban/projects/:project_uuid/backlog`, `/velocity`

**Time tracking**

- `POST /api/v2/kanban/timer/start|stop`, `GET /api/v2/kanban/timer/current`
- `GET|POST /api/v2/kanban/tasks/:uuid/time-entries`, `GET /api/v2/kanban/tasks/:uuid/time-summary`
- `PUT|DELETE /api/v2/kanban/time-entries/:uuid`, `PUT /api/v2/kanban/time-entries/:uuid/approve|reject`
- `GET /api/v2/kanban/timesheet`, `GET /api/v2/kanban/projects/:uuid/time-report`

**Supporting**: `GET /api/v2/kanban/notifications`, `/unread-count`, `PUT .../:uuid/read`,
`POST .../mark-all-read`; analytics under `GET /api/v2/kanban/projects/:uuid/analytics`,
`/completion-trend`, `/priority-distribution`, `/team-workload`, `/cycle-time`, `/activity`;
per-task chat under `/api/chat/channels/...` (note: **not** `/api/v2`), reachable via the task's
`chat_channel_uuid`; machine credentials at `GET|POST /api/v2/api-keys`, `DELETE /api/v2/api-keys/:uuid`.

## Seven things that will bite you

1. **`/api/v2/projects` is not this.** That route set is the platform's own project registry
   (`project_code`, dashboard config, migration status). Everything here lives under
   `/api/v2/kanban/`. Separately, the "projects" already in the DBS demo data are Simpro **project
   jobs** in field service — a different concept with a colliding name. Do not join them.
2. **A third envelope shape.** Kanban lists are `Envelope.Standard` (camelCase `perPage`,
   `totalPages`) **plus a top-level `permissions` object**; single-project reads carry
   `permissions` on the object (`can_update`, `can_delete`, `can_manage`). Drive the UI from it,
   the way job detail drives actions from `allowed_transitions`. Timesheets use plain
   `{ success, data }` with snake_case `per_page`. Extend `Core/Networking/Envelopes.swift`.
3. **Task move takes a numeric `column_id`, not a uuid**, and it is `PUT`. Keep the numeric id on
   the column model deliberately, with a comment saying why.
4. **Project membership gates everything.** Task and board routes check membership, not just the
   `projects` grant. Someone with `projects.read` and no memberships correctly sees nothing — the
   empty state should say that rather than looking broken. **This is also what stops an API key
   working**; see below.
5. **Timesheet permissions are asymmetric.** Your own timesheets need no module grant (the routes
   are namespace-gated only). Others' need `timesheet_approvals.read` or `timesheets.manage`;
   approving needs `timesheet_approvals.approve`, rejecting `timesheet_approvals.reject`. In the
   seeded field-service roles a service manager has `timesheets: read` +
   `timesheet_approvals: manage`; engineers have neither and must still log and submit their own.
6. **Naive UTC timestamps** (`"2026-09-12 08:00:00"`, sometimes microseconds) and date-only
   strings. Use the app's existing `APIDate` strategy. Hours arrive as numbers *or* numeric
   strings — decode leniently, as `JSONValue.swift` already does.
7. **`task_number` is the JIRA key.** Per-board sequential, alongside `uuid`. It is what people say
   out loud. Show it everywhere and make it copyable.

## Agent identity: what works today, and the one thing that does not

OpsAPI already has machine credentials, and they are well built:

- `POST /api/v2/api-keys` (namespace admin only) mints `opsk_…`, returned once, stored as a
  SHA-256 hash, with `{ name, scopes, expires_at? }`. `GET` lists them without the secret;
  `DELETE /api/v2/api-keys/:uuid` revokes, idempotently. Last-used is tracked.
- `scopes` is `{ module: [actions] }`. The `namespace` module is refused outright, so a key can
  never mint keys, add members or change roles.
- Keys are **confined by URI, fail-closed**: a key may only reach `/api/v2/<module>/…` for a module
  it is scoped for. For kanban that first path segment is `kanban`, while the RBAC check inside the
  route is on `projects` — an agent key needs **both** `kanban` (to be admitted) and `projects`
  (to pass permission checks), and `timesheets` if it logs time.

**The blocker:** an API key authenticates as a principal whose `uuid` is the *key's* uuid and
matches no `users` row. Kanban checks `isMember(project_id, user.uuid)` on every task and board
route, so **a key cannot be a project member, an assignee, or the author of a comment that resolves
to anybody**. Today an agent with a key gets `403 Access denied` on the endpoints that matter.

So there are two paths, and the app must work with either:

- **Bot user accounts** — a real `users` row per agent, added to projects like any member. This
  works now on int (the seeds obtain a JWT through the real 2FA flow using the `TEST_OTP_CODE`
  bypass) but there is **no machine login path on production**, where 2FA is mandatory and the code
  goes to an inbox.
- **Keys as members** — a server change letting a key principal be a project member and an
  assignee, carrying its own identity into the activity log.

Build the client so an actor is `{ uuid, display name, kind: person | agent }` resolved from
whatever the payload gives, and never hardcode the assumption that an assignee resolves to a
person. Put the gap in the report.

## The task contract

A card an agent may pick up carries a contract under the task's `metadata` JSONB — which the API
accepts on create and update (`metadata` is in the allowed-fields list on `PUT`). Everything is
under one key so nothing collides with other writers:

```jsonc
{
  "agent": {
    "version": 1,
    "goal": "One sentence a person would recognise as the point of the task.",
    "inputs": { "customer_uuid": "…", "site_uuid": "…", "report": "fgas_register" },
    "constraints": ["read-only against production", "no customer email"],
    "acceptance": [
      "The F-Gas register for Q3 is attached as a PDF",
      "Every asset with a failed leak check appears in it"
    ],
    "definition_of_done": "Reviewer can send the attached PDF to the customer unchanged.",
    "budget": { "minutes": 30, "attempts": 2 },
    "tools": ["opsapi:read", "pdf:render"],
    "review": { "required": true, "reviewers": ["<user uuid>"] },
    "claim": { "by": "<actor uuid>", "kind": "agent", "at": "…Z", "expires_at": "…Z" },
    "run": { "id": "…", "attempt": 1, "started_at": "…Z", "heartbeat_at": "…Z", "cost": {} },
    "result": { "status": "needs_review", "summary": "…", "artifacts": [], "notes": "" }
  }
}
```

Rules: a task without `agent.goal`, `acceptance` and `definition_of_done` is **not** agent-eligible,
and the app must not offer it as such. `review.required` defaults to true. Labels mirror the state
for board-level filtering — `agent:eligible`, `agent:running`, `needs:human` — because a label is
cheap to filter on and metadata is not; the label is the index, the contract is the detail.

## Lifecycle

Columns are user-defined per board, so this is a convention mapped in project settings, never
hardcoded:

**Backlog → Ready for agent → Claimed → In progress → Needs review → Done**, with **Rejected**
returning the card to *Ready for agent* with the reviewer's reasons appended to the contract.
Human-worked cards skip the middle and go Backlog → In progress → Done. A card in *Needs review*
belongs to a person; nothing an agent does moves it out of there.

## Working in parallel without treading on each other

The API has **no optimistic concurrency** (updates are last-write-wins, `updated_at = NOW()`), **no
claim or lease**, **no idempotency keys** and **no realtime transport** — there is no websocket or
SSE anywhere in OpsAPI. Everything below is therefore a client-side convention that both the app
and the agent runtime must implement identically, and every one of them belongs in the report as a
server gap.

- **Claim by lease.** Write `agent.claim` with `expires_at` (a few minutes out) and refresh it with
  `run.heartbeat_at` while working. Before claiming, re-read the task: if a live claim belongs to
  someone else, do not take it. A claim whose `expires_at` has passed is stale and may be taken,
  with a comment saying so. The app shows a stale claim as such rather than hiding it.
- **Compare and set, by hand.** Read `updated_at`, write, then re-read: if `updated_at` moved in a
  way your write does not explain, treat it as a conflict — do not retry blindly. In the app that
  is a banner: *"This task changed while you were editing"*, with the option to reload or overwrite.
- **Idempotency.** Generate a UUID per intended write and carry it in the payload
  (`metadata.agent.run.id` for contract writes, a trailing `<!-- idem:… -->` marker on comments).
  Before retrying a failed POST, look for your own marker. A retried comment or time entry that
  lands twice is the most likely visible failure of this whole design.
- **Polling, politely.** The app refreshes on appear, on foreground and on pull; a board that is
  open may poll on a slow interval, and it must back off when nothing changes. Agents poll their
  queue, not the whole board.
- **Never impersonate.** An agent writes as itself. If a write must be attributed to a person, a
  person makes it.

## What the iOS app must do about all this

- **Actor chips everywhere.** Every assignee, comment, activity row and time entry names its actor
  and marks person or agent — with a shape or icon, not colour alone.
- **"Waiting for me" is a home screen**, beside My Tasks: cards in *Needs review* where I am a
  reviewer, oldest first. This is the screen that makes parallel work supervisable, so it gets the
  same care as My Work does for engineers.
- **Run state on the card.** Running or claimed, attempt *n* of *m*, how long since the last
  heartbeat, spend against budget. A claim with a cold heartbeat reads as stalled, plainly.
- **The review screen.** Acceptance criteria as a checklist, the agent's result and artefacts
  beside them, the activity log, then Approve or Send back. Sending back requires a reason, which
  is written into the contract and posted as a comment so the agent's next attempt can read it.
- **Take over.** One action that claims the card for me, clears the agent's lease, moves it to *In
  progress* and says so in the activity log.
- **Stop.** A per-task stop flag in the contract that a well-behaved agent honours, and — when it
  does not — the honest escalation: revoke the key. Show the key's name on the agent chip so a
  person knows which credential to revoke, and link to where that is done.
- **Conflicts surface, never resolve themselves.** If the row moved under an edit, say so.
- **Agent time counts.** Agent-logged time entries appear in the task's time summary, the project
  time report and the sprint burndown, marked as machine time so a person can read the split.
- **Permissions.** Gate every action on the caller's grants (`projects`, `timesheets`,
  `timesheet_approvals`), on the `permissions` block the API returns, and on project membership.
  Extend `PermissionSet.Module` and `PermissionSet.Feature` (menu keys `projects`, `timesheets`).

## Safety rules, not negotiable

- **Least privilege per agent.** One key per agent, scoped to the modules it needs, with an expiry.
  Never the `namespace` module. Never `timesheet_approvals`.
- **No agent approves anything.** Not its own work, not another agent's, not a human's timesheet.
  Approval endpoints are for a human session; the app must not offer approval to an agent actor
  even if a future server change would permit it.
- **Review by default** for anything a customer could see — quotes, reports, invoices, emails.
- **Budgets are caps, not suggestions.** The runtime enforces them; the app shows spend against
  them and flags an overrun.
- **Revocation is instant and visible.** A revoked key's agent stops appearing as a claimant; its
  past work stays attributed. Never delete the history.
- **Credentials never travel through the app.** The app holds a person's session in the Keychain;
  agent keys live in the agent runtime's secret store. The app may *name* a key, never show it.

## Phone-first: a board on a six-inch screen

Do not transliterate the web board. **My Tasks and Waiting for me come first** — the board is
context, not the daily driver. Show the board as a **column pager**: one column full-width, a
segmented control or pager dots naming the columns and their counts, swipe between them, server
order. **Move by sheet, not by drag** — a "Move to…" list is faster, more accurate and accessible;
drag is an iPad enhancement at most. Task detail is a scroll, not a stack of modals: header
(number, title, status, priority, actor), then assignees, labels, dates and estimate, then the
contract and result if there is one, then checklists, comments and activity. Large tap targets,
Dynamic Type, VoiceOver labels, no colour-only status — the bar the rest of the app already meets.

## How it fits the app that is already here

Reuse rather than reinvent: `APIClient` (actor, refresh, retry), `Endpoint`, `Envelope`, `APIDate`,
`PagedList` + `PagedListModel`, `ModelHost`, `LoadState`, `StatusPresentation`,
`DesignSystem/Components.swift`, `Formatters`, `Brand`. One feature folder per module under
`WSLCRM/Features/` (`Timesheets/`, `Projects/`), each with its own `…API.swift`, `…Models.swift`
and views, as `Features/Simpro/` does. Wire entry points through `MainTabView`'s More tab, the
Field Service hub, and `MyWorkView` for my tasks and a running timer. Give every control an
`accessibilityIdentifier` on the existing convention (`timesheet.submit`, `task.row.<number>`,
`board.column.<name>`, `review.approve`, …) — the screenshot and video tours depend on it. Offline:
queue only what is safe to replay through `MutationQueue` — a checklist toggle, a comment, a
timesheet entry — and **never** a task move, a claim, or timer start/stop, because positions,
leases and clocks are contended and replaying them later invents history. New files are picked up
by `xcodegen generate`.

## Tests

- **Unit** (`WSLCRMTests`): decoding for every new envelope and entity against fixtures captured
  from the real API, including the `permissions` block; contract encode/decode round-trip with
  unknown keys preserved (an agent must be able to add fields without the app dropping them);
  timesheet status transitions; per-role visibility (engineer, service manager, telecaller) in the
  style of `RolePermissionTests`; the timer's single-flight rule.
- **Parallelism** — the tests that matter most here: a stale claim is reclaimable and a live one is
  not; a conflicting `updated_at` raises a conflict rather than overwriting; a retried write with
  the same idempotency marker does not duplicate; an agent actor is refused every approval path; a
  card in *Needs review* cannot be moved on by an agent.
- **UI** (`WSLCRMUITests`) against `-UITestStubServer`: log time → submit → approve as a manager;
  project → board → move a task → comment; review an agent's result → send back with a reason →
  approve on the second attempt; take over a stalled agent task. Extend
  `WSLCRM/Support/UITestSupport.swift` with the new responses, including an agent actor.
- **The DBS tour**: add chapters to `WSLCRMUITests/DBSLimitedTourUITests.swift` and lines to
  `WSLCRMUITests/DBSTourNarration.swift` so the new modules — and a human reviewing an agent's
  work — appear in the screenshot tour and the recorded video (`scripts/record-dbs-video.sh`).
- **Demo data**: the DBS seeds create nothing for any of these modules. Extend
  `scripts/seed-dbs-limited.py` with a believable slice seeded through the API as the person who
  would do it: two projects with boards and a sprint in flight, tasks across the columns with
  assignees, comments and contracts, one agent-claimed card mid-run and one waiting for review, and
  a week of timesheets per engineer — some draft, some submitted, one rejected with a reason.

## Deliverables

1. The four modules and the agent-aware layer, building cleanly for simulator and device, no new
   warnings.
2. `docs/AGENTS.md` — the contract, the lifecycle, the claim and idempotency rules, the scopes an
   agent key needs, and a worked example: a small script that authenticates, finds an eligible
   task, claims it, does something trivial, posts its result and moves the card to *Needs review*
   against int. If the key-as-member gap blocks it, make the example a bot user and say so at the
   top.
3. Tests as above, all green, plus the seed extension and tour chapters.
4. `README.md` and `docs/API-NOTES.md` updated: the new envelope shape, the `column_id` quirk, the
   timesheet permission asymmetry, and how agent actors are resolved and displayed.
5. The report (below).

## Server changes to propose — write them up, do not build them

1. **Let a machine credential be a project member and an assignee**, carrying its own identity into
   the activity log. Without this, agents cannot touch kanban at all.
2. **A machine login path** that does not require an emailed code, so agents work on production the
   way they work on int.
3. **Optimistic concurrency** — a version or `If-Unmodified-Since` on task update and move.
4. **Idempotency keys** honoured on POST, so a retry cannot duplicate a comment or a time entry.
5. **A claim/lease endpoint**, so claiming is atomic instead of a convention two clients agree on.
6. **Events** — webhooks or SSE for task and board changes, so neither the app nor an agent has to
   poll.
7. **Scope naming**: a key needs the `kanban` scope for URI admission and the `projects` scope for
   RBAC. One of those names should change, or the mismatch should be documented.

## Working method

Fetch `openapi.json` and hand-write the models from it; do not guess field names. Then build one
vertical slice at a time, verifying each against int before widening:

**timesheets (my own) → submit and approve → projects list → board and task detail → move and
comment → my tasks → the contract, claim and review flow with a scripted agent on the other side →
sprints and backlog → timer and time entries → analytics.**

Get a person and a scripted agent working the same board end to end before polishing anything. The
first time they collide, the design is either right or it is not, and you want to find that out in
week one rather than after the UI is finished.
