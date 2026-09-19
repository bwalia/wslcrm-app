# Working the board as an agent

This is the contract between WSLCRM and any agent that works cards alongside people. The iOS app
renders what is described here, so an agent that follows it is visible, steerable and reviewable
from a phone; one that does not is a stranger writing to the database.

Read it with `PROMPT-work-management.md`, which says why the design is shaped this way, and with
`scripts/agent-example.py`, which does the whole loop in about a hundred lines.

## 1. Get an identity

Ask a namespace admin for a machine credential:

```http
POST /api/v2/api-keys
{ "name": "fgas-report-bot", "scopes": { "kanban": ["read", "update"], "timesheets": ["create"] },
  "expires_at": "2027-01-01" }
```

The raw key (`opsk_…`) comes back **once**. Send it as `Authorization: Bearer opsk_…` together
with `X-Namespace-Id`, exactly as a person's JWT would be.

Two things to know before you build on this:

- **Scope names differ from module names.** A key is admitted to a URL by its first path segment,
  so touching `/api/v2/kanban/...` needs a `kanban` scope — while the permission check inside the
  route is on `projects`. Ask for both.
- **A key is not a user yet.** Its principal's uuid matches no `users` row, and every kanban task
  route checks project membership by user uuid, so today a key is refused (`403`) on the endpoints
  that matter. Until that is fixed server-side (it is the first item on the gaps list in
  `PROMPT-work-management.md`), run your agent as a **bot user account** that has been added to the
  project as a member. The app treats both the same: an actor is a uuid, a name and a kind.

Whichever identity you hold, the app shows it as an agent when the username looks like
`api-key:<key name>`, and names the key — because revoking that key is how a person stops you.

## 2. Find work

```http
GET /api/v2/kanban/projects                      # only projects you are a member of
GET /api/v2/kanban/boards/<board_uuid>/full      # columns with their tasks
GET /api/v2/kanban/my-tasks                      # anything assigned to you
```

A card is yours to pick up only when all of this is true:

- it sits in the column your project uses for agent-ready work;
- its `metadata.agent` contract has a **goal**, at least one **acceptance** line and a
  **definition of done** (the app refuses to mark a card agent-ready without them);
- nobody holds a live claim on it.

## 3. The contract

Everything lives under `metadata.agent` on the task. Write keys in lowercase `snake_case`, and
never replace the whole `metadata` blob — read it, change your own key, write it back. Other
writers keep things in there too.

```jsonc
{
  "agent": {
    "version": 1,
    "goal": "Produce the Q3 F-Gas register for Brightwell and attach it.",
    "inputs": { "customer_uuid": "…", "report": "fgas_register", "period": "2026-Q3" },
    "constraints": ["read-only against production", "no customer email"],
    "acceptance": [
      "Every asset with a failed leak check appears in it",
      "The PDF carries the DBS letterhead"
    ],
    "definition_of_done": "A reviewer can send the attached PDF to the customer unchanged.",
    "budget": { "minutes": 30, "attempts": 2 },
    "tools": ["opsapi:read", "pdf:render"],
    "review": { "required": true, "reviewers": ["<user uuid>"] },

    "claim": { "by": "<your uuid>", "kind": "agent", "name": "fgas-report-bot",
               "at": "2026-09-19 08:30:00", "expires_at": "2026-09-19 08:40:00" },
    "run": { "id": "<run uuid>", "attempt": 1, "started_at": "…",
             "heartbeat_at": "…", "cost": { "minutes": 12 } },
    "result": { "status": "needs_review", "summary": "…", "notes": "…",
                "artifacts": [{ "name": "fgas-register-q3.pdf", "url": "…", "kind": "pdf" }],
                "finished_at": "…" },

    "stop_requested": false
  }
}
```

`result.status` is one of `running`, `needs_review`, `approved`, `rejected`, `failed`. You set the
first two; a person sets the rest. When a reviewer sends work back, they write `review_reason` into
`result` and post it as a comment — **read it before your next attempt**.

Timestamps are naive UTC (`"YYYY-MM-DD HH:MM:SS"`), like the rest of the API.

## 4. Claim by lease, and keep breathing

There is no locking endpoint, so a claim is a convention both sides keep:

1. `GET` the task. If `metadata.agent.claim` exists and its `expires_at` is in the future and it is
   not yours, **leave the card alone**.
2. Write a claim with a short `expires_at` — minutes, not hours.
3. `GET` the task again. If the claim that came back is not yours, you lost the race: back off.
4. While you work, refresh `run.heartbeat_at` (and `claim.expires_at`) every minute or two.

A lease that has expired is fair game for anyone, and the app offers the card to whoever is
looking at it. That is the point: an agent that dies mid-run must not hold a card for ever.

The app treats a run whose heartbeat has been quiet for **five minutes** as stalled, and says so.

## 5. Write carefully

- **Check before you retry.** Every POST is repeatable, and nothing on the server stops a duplicate.
  Comments carry a marker — `<!-- idem:<uuid> -->` on the end — so a retry can look for its own
  write before posting again. Do the same for time entries.
- **Watch `updated_at`.** Read it before you write, read it again after: if it moved in a way your
  own write does not explain, somebody else touched the card. Stop and re-read rather than
  overwriting a person's edit.
- **Stay inside the budget.** `budget.minutes` and `budget.attempts` are caps, not suggestions.
  Record what you spend in `run.cost`, and stop when you reach it.
- **Honour `stop_requested`.** A person sets it from the app. Finish the write you are in the
  middle of, put the card down and set `result.status` to `failed` with a note. If you ignore it,
  the next thing that happens is your key being revoked.
- **Never approve anything.** Not your own work, not another agent's, and never a timesheet. Those
  endpoints are for people, and the app refuses them to an agent even when the grants would allow
  it.

## 6. Log your time like everybody else

Agent time counts in the same reports as human hours:

```http
POST /api/v2/kanban/tasks/<uuid>/time-entries
{ "description": "Agent run", "duration_minutes": 12, "is_billable": false }
```

The app marks it as machine time, so a person can read the split at a glance. Do not bill it
unless the project says to.

## 7. Hand it back

When the work is done:

1. Write `result` with a **summary a person can act on**, the artefacts, and
   `status: "needs_review"`.
2. Move the card to the review column: `PUT /api/v2/kanban/tasks/<uuid>/move` with
   `{ "column_id": <numeric id> }` — that endpoint takes the column's **numeric id**, not a uuid.
3. Post a comment saying what you did, with your idempotency marker.
4. Release nothing else: keep the claim until a person decides, so the card cannot be picked up
   twice while it waits.

## The loop, in short

```
find eligible card → claim (short lease) → re-read to confirm the claim is yours
  → work, heartbeating, inside the budget, checking stop_requested
  → write result + artefacts → move to review → comment → wait for a person
```

`scripts/agent-example.py` is exactly this loop against int, with nothing clever in it. Run it
beside the app and watch the card change under your thumb — that collision is the thing worth
testing before you build anything bigger.
