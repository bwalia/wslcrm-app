# Add work management to WSLCRM — timesheets, projects, tasks and boards

## Context

WSLCRM is the native iOS client (Swift 6 / SwiftUI, iOS 17+) for the OpsAPI / Workstation
platform. It already ships field service (My Work, guided visits, jobs, phases, service requests,
invoicing), the Simpro-aligned asset register and report pack, CRM, customers, products and
orders. **The backend already exists and must not be changed** — the web dashboard and this app
consume the same REST API. If an endpoint is missing or wrong, say so in your report; do not edit
the backend.

Four things exist server-side and on the web dashboard, and **none of them is in the iOS app
today** (verified: no timesheet, project, task, board, sprint or kanban screen, model or API call
anywhere in `WSLCRM/`):

1. **Timesheets** — weekly/daily time capture with submit → approve → reject → reopen.
2. **Projects** — kanban projects with members, roles, stars and stats.
3. **Task boards** — JIRA-style boards, columns, task numbers, assignees, labels, comments,
   checklists, attachments and an activity log.
4. **Sprints and time tracking** — backlog, sprint start/complete, burndown, velocity, a running
   timer and per-task time entries with approval.

The app does already parse `timesheets` and `timesheet_approvals` out of the caller's grants
(`GET /api/v2/user/menu`) — it simply ignores them. Nothing parses `projects`.

Your job: build these four modules in the iOS app, working the way the web dashboard works.

## Read these first

- **The live API** — `https://int-opsapi.workstation.co.uk/swagger` and `/openapi.json`. Treat it
  as the source of truth; the endpoint list below is a verified summary, not a substitute.
- **The web dashboard**, which is the behaviour to mirror (`opsapi/opsapi-dashboard`):
  - `app/dashboard/timesheets/page.tsx` — the list, the two tabs, the log-time modal, the summary
    cards, approve/reject.
  - `app/dashboard/timesheets/[uuid]/page.tsx` — one timesheet and its entries.
  - `app/dashboard/projects/page.tsx` — project cards, Active/Completed/Starred filters, progress.
  - `app/dashboard/projects/[uuid]/page.tsx` — the board.
  - `app/dashboard/projects/[uuid]/sprints/page.tsx` and `sprints/burndown/page.tsx`.
  - `components/kanban/*` — `KanbanBoard`, `KanbanColumn`, `KanbanTaskCard`, `TaskDetailModal`,
    `CreateTaskModal`, `CreateProjectModal`, `ProjectCard`.
  - `services/kanban.service.ts`, `services/sprint.service.ts`, `services/time-tracking.service.ts`,
    `services/timesheets.service.ts`, and the types in `types/index.ts`.
- **This repo's own conventions** — `README.md` (architecture, environments, tests),
  `docs/API-NOTES.md` (envelope and date behaviour already catalogued), and the existing feature
  folders under `WSLCRM/Features/` as the pattern to copy.

## Scope

Ship these, phone-first, in this order:

1. **Timesheets** — my timesheets, log time, submit; approval queue with approve/reject for
   managers; summary totals.
2. **Projects** — list (active / completed / starred), detail with stats and members.
3. **Task board** — columns, tasks, move between columns, task detail with assignees, labels,
   comments, checklists and activity; create and edit a task.
4. **Sprints, backlog and time tracking** — backlog, sprint board, start/complete a sprint,
   burndown; start/stop timer, task time entries, my time.

Plus a **My Tasks** home for the module (`GET /api/v2/kanban/my-tasks`), which is where a phone
user starts — the board is for context, not for daily driving.

## Endpoints (verified against `lapis/routes/` on the int branch)

**Timesheets** — envelope `{ success, data }`, paging via `page` / `per_page`

- `GET|POST /api/v2/timesheets`, `GET|PUT|DELETE /api/v2/timesheets/:uuid`
- `POST /api/v2/timesheets/:uuid/submit|approve|reject|reopen`
- `GET|POST /api/v2/timesheets/:uuid/entries`, `PUT|DELETE /api/v2/timesheets/entries/:entry_uuid`
- `GET /api/v2/timesheets/approval-queue`, `GET /api/v2/timesheets/summary`
- `GET /api/v2/timesheets/lookups/customers`, `GET /api/v2/timesheets/lookups/tasks`

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
- `PUT /api/v2/kanban/tasks/:uuid/move`
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
- `GET /api/v2/kanban/sprints/:uuid/burndown`, `GET /api/v2/kanban/sprints/:uuid/summary`
- `GET /api/v2/kanban/projects/:project_uuid/backlog`, `GET /api/v2/kanban/projects/:project_uuid/velocity`

**Time tracking**

- `POST /api/v2/kanban/timer/start|stop`, `GET /api/v2/kanban/timer/current`
- `GET|POST /api/v2/kanban/tasks/:uuid/time-entries`, `GET /api/v2/kanban/tasks/:uuid/time-summary`
- `PUT|DELETE /api/v2/kanban/time-entries/:uuid`, `PUT /api/v2/kanban/time-entries/:uuid/approve|reject`
- `GET /api/v2/kanban/timesheet`, `GET /api/v2/kanban/projects/:uuid/time-report`

**Analytics and notifications** (nice to have, last): `GET /api/v2/kanban/projects/:uuid/analytics`,
`/completion-trend`, `/priority-distribution`, `/team-workload`, `/cycle-time`, `/activity`;
`GET /api/v2/kanban/notifications`, `/unread-count`, `PUT .../:uuid/read`, `POST .../mark-all-read`.

## Seven things that will bite you

1. **`/api/v2/projects` is not this.** That route set is the platform's own project registry
   (`project_code`, dashboard config, migration status) and has nothing to do with work
   management. Everything here lives under `/api/v2/kanban/`. Likewise, the "projects" already in
   the DBS demo data are Simpro **project jobs** in field service — a different concept with a
   colliding name. Do not join them; if the two ever need linking, report it.
2. **A third envelope shape.** Kanban list responses are `Envelope.Standard` (`meta` with camelCase
   `perPage` / `totalPages`) **plus a top-level `permissions` object** — and single-project reads
   carry `permissions` on the object itself (`can_update`, `can_delete`, `can_manage`). Decode it
   and drive the UI from it, the way job detail already drives actions from `allowed_transitions`.
   Timesheets use the plain `{ success, data }` shape with snake_case `per_page`. Extend
   `Core/Networking/Envelopes.swift` rather than bending one decoder over both.
3. **Task move takes a numeric `column_id`, not a uuid**, and it is `PUT`, not `POST`:
   `PUT /api/v2/kanban/tasks/:uuid/move` with `{ column_id, position? }`. The rest of the platform
   is uuid-addressed, so keep the numeric id on the column model deliberately and comment why.
4. **Project membership gates everything.** `GET /api/v2/kanban/projects` returns only projects the
   caller is a member of; task and board endpoints check membership, not just the `projects` grant.
   A user with `projects.read` and no memberships sees an empty list — that is correct, and the
   empty state should say so rather than looking broken.
5. **Timesheet permissions are asymmetric.** Creating and reading *your own* timesheets needs no
   module grant — the routes are namespace-gated only. Seeing *other people's* needs
   `timesheet_approvals.read` or `timesheets.manage`; approving needs `timesheet_approvals.approve`
   and rejecting `timesheet_approvals.reject`. So: show "My timesheets" to everyone signed in, and
   the approval queue only to approvers. In the seeded field-service roles, the service manager has
   `timesheets: read` + `timesheet_approvals: manage`; engineers have neither, and must still be
   able to log and submit their own time.
6. **Timestamps are naive UTC strings** (`"2026-09-12 08:00:00"`, sometimes with microseconds) and
   dates are date-only strings. The app's `APIDate` strategy already handles this — use it, and do
   not invent a second one. Timesheet `hours` come back as numbers *or* numeric strings in places;
   decode leniently, as `WSLCRM/Core/Networking/JSONValue.swift` already does elsewhere.
7. **`task_number` is the JIRA key.** Tasks carry a per-board sequential `task_number` alongside
   `uuid`; that is what people say out loud and search for. Show it everywhere (`PROJ-14` style
   using the project key if the payload has one, otherwise `#14`), and make it copyable.

## Domain rules the UI must respect

- **Timesheet status**: `draft → submitted → approved | rejected`, `rejected → reopen → draft`,
  plus `void`. Only draft rows are editable; only draft rows can be submitted; only submitted rows
  can be approved or rejected. Rejection carries a reason — show it on the row, not behind a tap.
- **Task status and priority** are enumerations from the API, and columns are user-defined per
  board. Never hardcode "To Do / In Progress / Done"; render the columns the board returns.
- **Sprints**: a project has at most one active sprint; `start` and `complete` are actions with
  their own endpoints, and completing asks what happens to unfinished tasks (see the dashboard's
  sprint page). Burndown is a series — render it as a simple chart, and make it readable in both
  colour schemes.
- **The timer is global state.** `GET /api/v2/kanban/timer/current` on launch and on foreground; if
  a timer is running, show it in the module's header wherever the user is, and let them stop it in
  one tap. Two timers must never run at once — stop the current one before starting another.
- **Permissions**: gate every action on the caller's grants (`projects`, `timesheets`,
  `timesheet_approvals`) and on the `permissions` block the API returns. Hide what the user cannot
  do rather than letting it 403. Extend `PermissionSet.Module` and `PermissionSet.Feature`
  (menu keys: `projects`, `timesheets`) so the More tab and hub only offer what is granted.

## How it must fit the app that is already here

- Reuse, do not reinvent: `APIClient` (actor, refresh, retry), `Endpoint`, `Envelope`, `APIDate`,
  `PagedList` + `PagedListModel`, `ModelHost`, `LoadState`, `StatusPresentation` for status chips,
  `DesignSystem/Components.swift`, `Formatters`, and `Brand` for anything that prints.
- One feature folder per module under `WSLCRM/Features/` (`Timesheets/`, `Projects/`), each with
  its own `…API.swift`, `…Models.swift` and views, exactly like `Features/Simpro/`.
- Wire entry points the way the others are wired: `MainTabView`'s More tab, the Field Service hub
  where it belongs, and `MyWorkView` for "my tasks" and a running timer. Give every control an
  `accessibilityIdentifier` following the existing convention (`timesheet.submit`,
  `task.row.<number>`, `board.column.<name>`, …) — the screenshot and video tours depend on it.
- Offline: queue only what is safe to replay through `MutationQueue` — a checklist toggle, a
  comment, a timesheet entry. Do **not** queue task moves or timer start/stop: positions and clocks
  are contended, and replaying them later invents history. Reads should use `ResponseCache` as the
  other modules do.
- New files must be picked up by `xcodegen generate` (sources are directory-based in `project.yml`).

## Phone-first: how a kanban board works on a 6-inch screen

The web board is a horizontally scrolling set of columns with drag-and-drop. Do not transliterate
it. Instead:

- **My Tasks first.** Grouped by due date and project, with the task number, priority and assignee
  avatars. This is the screen an engineer or a manager opens ten times a day.
- **The board as a column pager.** One column at a time, full width, with a segmented control or
  pager dots naming the columns and their counts; swipe between them. Show the board's columns in
  their server order.
- **Move by sheet, not by drag.** A task's "Move to…" sheet listing the columns is faster, more
  accurate and accessible; offer drag only as an enhancement on iPad.
- **Task detail is a scroll, not a modal stack**: header (number, title, status, priority), then
  assignees, labels, dates and estimate, then checklists, comments and activity.
- Large tap targets, Dynamic Type, VoiceOver labels, no colour-only status encoding — the same bar
  the rest of the app is held to.

## Tests — the bar this repo already meets

- **Unit** (`WSLCRMTests`): decoding for every new envelope and entity against fixtures captured
  from the real API; the `permissions` block; timesheet status transitions; per-role visibility
  (engineer vs service manager vs telecaller) in the style of `RolePermissionTests` and
  `SimproDemoTests`; the timer's single-flight rule.
- **UI** (`WSLCRMUITests`): stub-backed flows against `-UITestStubServer` — log time → submit →
  approve as a manager; open a project → board → move a task → comment; start and stop a timer.
  Extend `WSLCRM/Support/UITestSupport.swift` with the new responses.
- **The DBS tour**: add chapters to `WSLCRMUITests/DBSLimitedTourUITests.swift` and lines to
  `WSLCRMUITests/DBSTourNarration.swift` so the new modules appear in the screenshot tour and in
  the recorded video (`scripts/record-dbs-video.sh`). Keep the tour's discipline: it looks, and
  writes only what it must.
- **Demo data**: the DBS seeds create no timesheets, projects, boards or tasks — the workspace is
  empty for all four modules. Extend `scripts/seed-dbs-limited.py` (and `seed-dbs-portfolio.py` if
  the work belongs with the portfolio) with a believable slice: a couple of projects with boards
  and a sprint in flight, tasks across the columns with assignees and comments, and a week of
  timesheets per engineer — some draft, some submitted, one rejected with a reason. Seed through
  the API as the person who would do it, as the existing seeds do.

## Deliverables

1. The four modules, building cleanly for simulator and device, no new warnings.
2. Tests as above, all green, plus the seed extension and a tour that shows the new screens.
3. `README.md` and `docs/API-NOTES.md` updated: the new envelope shape, the `column_id` quirk, the
   timesheet permission asymmetry, and where the screens live.
4. A short report listing any API gaps, inconsistencies or bugs you hit — especially anything where
   the web dashboard depends on behaviour the API does not document. Do not fix the backend.

## Working method

Fetch `openapi.json` and hand-write the models from it; do not guess field names. Then build one
vertical slice at a time, verifying each against int before widening:

**timesheets (my own) → submit and approve → projects list → board and task detail → task move and
comments → my tasks → sprints and backlog → timer and time entries → analytics.**

Check each slice against the web dashboard's behaviour for the same data before moving on: same
filters, same statuses, same counts. Where the phone must differ, differ deliberately and say why
in the report.
