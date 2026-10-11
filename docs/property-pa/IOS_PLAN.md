# Property PA on iOS — Phase 1 plan

Follows `prompt-ios-pa.md`. Built from opsapi's draft gap map (`docs/property-pa/00-gap-map.md`,
branch `feat/property-pa-poc`, 11 Oct) and the draft How It Works. **The PA API isn't built yet**:
the shapes below are what the app needs, sent to opsapi as `api-requests/ios-pa-native-client.md`.
Until the real routes ship, the app runs against a **clearly marked mock** (the UI-test stub server
and a "PA preview" banner in Debug builds). No workarounds against other endpoints.

## 1. Decisions

| Question | Recommendation | Why |
|---|---|---|
| Where does the PA live? | A **PA** tab, first and home, only where `GET /pa/me` says it's on. Deals stays as its own tab. | PA-first product; Deals keeps working (fallback rule) and stays on TestFlight unchanged. |
| PA Today vs Deals Today | Both, for now. PA Today is the seller agent's home; Deals Today stays for the deal pipeline (tasks by urgency, money at risk). Revisit when the gap map says which engine wins. | `pa_priority` generalises today's urgency engine; until it ships we don't remove anything. |
| Next actions | PA next actions are kanban tasks with `property_deals_task_details` (gap map: extend tasks with `reason`, `created_from_interaction_uuid`). They open in the existing **task detail**. | No duplicate task UI. |
| Capture | **New PA capture** (voice → ProposedUpdates → confirm). The existing **Quick capture** stays for structured doorstep capture (new seller + property + photos) until `/pa/capture` handles properties and photos. | Different jobs today; merge later. |
| Speech to text | **Server STT** (`/pa/capture` with audio; opsapi forwards to `PA_STT_URL`, self-hosted Speaches now, the UK GPU later). The app records AAC (m4a, 16 kHz mono), max 5 minutes, and deletes the file once accepted. On-device recognition only as a fallback when `GET /pa/me` says `stt: "on_device"`. | The gap map's STT path is live on int; one transcription model for web and phone. |
| Approvals vs handoffs | Approvals inbox stays (agent drafts to send). Handoff/decision cards are a new list on Manager Today. Both decisions behind Face ID. | Different objects (`pa_handoffs`, `pa_decisions`). |
| Latency | Ask PA, Prepare me and capture extraction are **asynchronous**: POST returns a job id (202), the app polls (or listens on push). Never block the UI for a model call. | Gap map risk 1: 2–6 min per answer on today's shared Mac; target < 10 s on the GPU. |

## 2. Screen map → calls

All under `/api/v2/property-pa` (or wherever opsapi mounts the plugin; one constant in `PropertyPAAPI`).

| Screen | Calls | Offline |
|---|---|---|
| Gate | `GET /pa/me` | cached |
| PA Today | `GET /pa/today?mode=full` · `mode=minutes:30` · `mode=minutes:60` | cached, "saved at" notice |
| Why #1? | `GET /pa/why/:cardId` | cached with Today |
| Card actions | `POST /pa/cards/:id/later {until?}`, `POST /pa/cards/:id/done` | queued |
| Prepare me | `POST /pa/prepare/:opportunityId` → job; `GET /pa/jobs/:id` | last brief cached per opportunity |
| Capture | `POST /pa/capture` multipart `audio` or `{text}` + `context` (card/opportunity) → capture id (202) | **queued** (audio kept until accepted) |
| Capture status | `GET /pa/capture/:id` → `transcribing / extracting / ready / failed` + proposed updates | — |
| Confirm sheet | `POST /pa/capture/:id/confirm {decisions:[{update_id, action: confirm/correct/reject, value?}]}` | **never queued** for material fields; non-material may queue |
| Ask PA | `POST /pa/ask {question, context}` → job; `GET /pa/jobs/:id` | no |
| Handoff | `POST /pa/handoff {to_user_uuid?, opportunity_uuid, question, recommendation}` | no |
| Manager Today | `GET /pa/today?role=manager` | cached |
| Decision card | `POST /pa/handoffs/:id/reply {decision: agree/reply, text?}` | never queued, Face ID |
| Teach PA | `POST /pa/teach {text, scope}` → proposed rule; `POST /pa/knowledge/:id/approve` | no; company approval behind Face ID |
| Record view | `GET /pa/records/:table/:uuid/history` (AI changes: source, model, prompt version, approver) | no |

## 3. Navigation and UI

- **PA tab** (icon `sparkles`), home when on. Toolbar: Ask PA, Teach PA (managers), Manager toggle (managers).
- **Mic button** floating bottom-trailing on PA screens; hold to talk or tap to start/stop; shows time
  and "Goes to Workstation's private speech service". **Ask bar** under the brief.
- **Cards**: name + property, recommended action, why now, objective; buttons Prepare me · Call ·
  Message · Ask · Later. "Why #1?" on the top card. After Done, the next card scrolls into place.
- **Facts with sources**: each fact row has a source chip (tap → lead, deal, task, interaction).
  Inferred facts use an outlined badge "JUDGEMENT · UNCONFIRMED" (VoiceOver: "Unconfirmed judgement").
- **Confirm sheet**: grouped by person/property; each field: value, type (stated / inferred /
  proposed), confidence; material fields need their own tick; [Confirm] [Change something].
- **After a call** started from a card: on return to the app, a banner "How did it go?" arms the mic.

## 4. Offline

| What | How |
|---|---|
| Today, Manager Today, last brief per opportunity, `GET /pa/me` | `ResponseCache`, workspace-scoped |
| Voice notes and text captures | `PendingMutation` `.paCapture` with the audio in `PendingUploads`, `Idempotency-Key`; sent when online, then status polled |
| Card Later / Done | queued `.paCardAction` |
| Confirming material fields, handoff replies, knowledge approval | never queued: needs a signal and a tap (Face ID for decisions) |

## 5. Push

New routes on the existing payload `{namespace_id, route, uuid}`: `pa_card`, `handoff`, `pa_brief`,
`pa_capture_ready` (the extraction finished: open the confirm sheet). Categories with actions:
`pa_card` → Call, Prepare me. Requested in `api-requests/ios-keep-property-deals-contract.md`.

## 6. Tests

- Stub server PA routes seeded from How It Works (Sophie, Ashley, Sarah / 22 Station Road, Michael,
  Rick, James / 94 Milton Road, 10 sellers).
- Unit: decoding, card ordering is the server's (the app never re-ranks), inferred labelling,
  material fields block confirm until ticked, capture chain resume, never-queued rules.
- UI: scenes 1–6 and 10 as one test; PA off → Deals still works; dark mode and largest text.

## 7. Gaps → api-requests (opsapi)

- `ios-keep-property-deals-contract.md` (written): Deals API stable, push routes, `/pa/me`.
- `ios-pa-native-client.md` (written): the JSON shapes in §2, async jobs, card actions, source links.

## 8. Build order

1. PA gate, PA tab, Today with cards, Why #1?, card actions (mock).
2. Capture: recorder, offline chain, status, confirm sheet with inferred labels.
3. Prepare me, Ask PA (async), source links into existing screens.
4. Manager Today, handoffs, Teach PA, push routes, Face ID on decisions.
5. Switch each screen from mock to the real API as opsapi ships it; int tour; TestFlight on request.
