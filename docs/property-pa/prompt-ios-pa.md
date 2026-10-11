# Build Prompt — Property PA in the WSL CRM iOS app (follow-up)

> Follows the opsapi **Property PA** prompt (PA-first: "the CRM is the system of record, the PA is
> the system of work"). Start **after** opsapi has delivered the PA APIs for the phase you are
> building (see §8). Paste this at the root of `wslcrm-app`. Copy into `docs/property-pa/` first:
> `PRD.md`, `HOW-IT-WORKS.md`, `SUPPLIER-RESPONSE.md`, and opsapi's `00-gap-map.md` and PA API doc.
>
> Work in phases. Stop at the end of each one and show me simulator screenshots.

---

## 0. The product on the phone

A seller agent opens Workstation CRM, sees **what to do next and why**, gets **prepared in 30
seconds** before a call, **speaks a voice note** after it, **confirms** what the PA understood, and
never fills in a form. A manager sees **only exceptions** and answers **handoff cards** with one tap.

The web (Next.js) PA is the main PoC surface. The native app adds what a phone does best:
push at the right moment, Face ID for approvals, one-tap call, the microphone, and offline capture.

---

## 1. Hard rules

1. **Reuse the app.** Same networking (`APIClient`, envelopes), auth, workspaces, Keychain,
   design system (`Tone`, `StatusBadge`, Plus Jakarta Sans), offline queue (`MutationQueue`,
   chained steps, `Idempotency-Key`), push (`PushCenter`, `DeepLink`), and `BiometricGate`.
2. **No AI on the device beyond the OS.** No model keys, prompts or provider names in the app.
   Every PA answer comes from opsapi (which routes to the private UK GPU). Never call a public LLM.
3. **Audio.** Follow opsapi's decision in the gap map:
   - *Server STT* (default for the PA): upload the recording to `POST /pa/capture` (multipart),
     delete it from the phone once accepted; or
   - *On-device* `SFSpeechRecognizer` with `requiresOnDeviceRecognition` (as Quick capture does
     today), sending only the transcript.
   Never use Apple's server-side recognition. State which one is used on the capture screen.
4. **Grounded or silent, on screen too.** Every fact in a brief or answer shows its source
   (tap → the record). Unknowns are shown as gaps, not hidden.
5. **Fact vs inference is visible.** Inferred values are labelled (e.g. "SOPHIE'S JUDGEMENT,
   UNCONFIRMED") in a distinct style that also reads correctly in VoiceOver.
6. **Authority levels.** The app never executes level 4 actions without a human tap, and level 5
   is not offered. Offer changes, commitments and external messages need confirmation; decisions
   on handoffs and approvals need Face ID / passcode.
7. **Fallback.** If a PA call fails or the PA is off for the workspace, the existing screens
   (Deals Today, tasks, deals, leads) keep working. The PA tab shows why, not a blank screen.
8. **Gated per workspace and role.** Show the PA only where opsapi says it's on for this
   workspace and role (a `GET /pa/me`-style endpoint; ask for one if missing). Manager views only
   for managers.
9. **Don't break what's shipped.** The Deals module (`/api/v2/property-deals/*`) stays as is until
   the gap map says what the PA replaces. Change it only with an agreed migration.
10. **Missing API pieces:** write `opsapi docs/property-pa/api-requests/ios-<name>.md` (what, why,
    example response) and use a clearly marked mock until it ships. No workarounds.
11. Dynamic Type, VoiceOver, dark mode, iPhone SE to Pro Max. Swift 6 strict concurrency.

---

## 2. Phase 1 — Plan (no code)

Write `docs/property-pa/IOS_PLAN.md`:
- Screen map (below) → exact PA endpoints and fields from opsapi's doc.
- What overlaps the Deals module (Today ranking, hot leads, Quick capture, approvals) and the
  proposal: replace, merge or keep both. Recommend one.
- Offline: what's cached (Today, briefs read recently), what's queued (captures, confirmations of
  non-material fields), what's never queued (material confirmations, handoff decisions, approvals).
- Push: routes, payloads, categories, deep links.
- Gaps → api-request files.

**Stop and wait for my OK.**

---

## 3. Screens

| Screen | Calls | Notes |
|---|---|---|
| **PA Today** (new home tab where the PA is on) | `GET /pa/today?mode=full` · `?mode=minutes:30` | Morning brief, then ranked cards: person/property, recommended action, why now, objective. Buttons: Prepare me · Call · Message · Ask PA · Later. "I have 30 minutes" chip. When a card is done, show the PA's next one. Cache for offline reading. |
| **Why #1?** | `GET /pa/why/:cardId` | The real signals and weights as a list, not prose only. |
| **Prepare me** | `GET /pa/prepare/:opportunityId` | 30–60 s brief: snapshot, motivation, last meaningful contact, price/offer position, decision makers and promises, objections, questions, playbook, objective. Each fact → source. Call button at the bottom. |
| **Capture** (mic on every PA screen; also after a call ends) | `POST /pa/capture` (audio or text) | Hold-to-talk or tap; shows recording time and where audio goes. Queued offline as a chained write with `Idempotency-Key`; audio kept in `PendingUploads` until accepted. |
| **Confirm sheet** | `POST /pa/capture/:id/confirm` | Who/which property (ask if unsure), extracted fields with confidence, inferred ones labelled, [Confirm] [Change something]. Material fields (price, offer, decision makers, next action time) can't be confirmed without a deliberate tap each; never auto-confirmed, never queued. Shows the next action created ("Call Sarah tomorrow 11:00"). |
| **Ask PA** (bar on PA screens) | `POST /pa/ask` | Chat with sources and stated gaps. Coaching answers separate fact from assumption. Tool results (e.g. "Ask Ashley") show what was done. |
| **Handoff** | `POST /pa/handoff` | From Ask PA or a card: exact question + recommendation preview → send. |
| **Manager Today** | `GET /pa/today?role=manager` | Exceptions only. Decision cards: [Agree] [Reply] [Open deal]; Agree / Reply behind Face ID. "Everything else is being handled." |
| **Teach PA** (managers; personal scope for agents) | `POST /pa/teach`, `POST /pa/knowledge/:id/approve` | Natural explanation → proposed rule, rationale, triggers → scope [Company] [Only my PA] [Edit]. Company approval behind Face ID. |
| **Record view** | existing Deals/lead screens + `timeline`, sources, AI change history | Show what the AI changed: source, time, model label (provider-neutral), approver. |

---

## 4. Push

- New routes on the existing payload `{ namespace_id, route, uuid }`: `pa_card` (a priority card,
  e.g. a promised follow-up due), `handoff` (decision needed / reply arrived), `pa_brief` (morning
  brief). Switch workspace first, then open the screen.
- Notification actions: **Call** and **Prepare me** on `pa_card`; **Open** on `handoff`
  (no decision from the lock screen).
- Respect `/notification-preferences` categories and quiet hours (add PA categories there).
- Add the routes to `AppDeepLink`, the `wslcrm://pa/<route>/<uuid>` scheme and the UI-test hooks.

---

## 5. Call flow (the moment that matters)

1. Card → **Prepare me** → **Call** (tel: link).
2. When the app returns to the foreground after a call from a card, offer **"How did it go?"** with
   the mic already armed (one tap to start). No call recording, no call-log scraping.
3. Voice note → capture → confirm sheet → next action. The card closes and the next one appears.

---

## 6. Tests

- Unit: decoding (nulls left out, numbers as strings, `2026-10-09 15:31:19+00` timestamps),
  card ranking display, inferred-field labelling, offline chain resume for capture, material
  fields never queued.
- UI (stub server seeded from `HOW-IT-WORKS.md`: Sophie, Ashley, Sarah / 22 Station Road, Michael /
  14 Green Lane, Rick / 18 Market Street, James, 94 Milton Road, 10 sellers):
  - Demo scenes 1–6 as one XCUITest: focus list → Prepare me for Sarah → voice note (stubbed
    transcript) → confirm with £225k shown as unconfirmed judgement → 11:00 follow-up created →
    "what would you do?" coaching without a higher offer → Ask Ashley → handoff on Ashley's
    Manager Today → reply back on Sophie's card.
  - Teach PA: Ashley's rule appears in the next brief.
  - PA off / PA error → Deals screens still work.
  - Dark mode and largest Dynamic Type screenshots of Today, Prepare me and the confirm sheet.
- Look-only tour against int once the PA is deployed there (seed script in `scripts/`).

---

## 7. Measurement (PRD §13)

Send opsapi the events it asks for (card opened, prepare viewed, capture started/confirmed,
corrections, recommendation accepted/rejected, time on confirm sheet). No content in analytics,
only ids and timings.

---

## 8. Phases (each starts when the matching opsapi week has shipped)

| Phase | Needs from opsapi | Build |
|---|---|---|
| 1 | Gap map, PA API doc | Plan (§2) |
| 2 | Week 2 — Capture | Mic, capture (online + offline), confirm sheet, next action |
| 3 | Week 3 — Think | PA Today, Why #1?, Prepare me, Ask PA, Teach PA (personal) |
| 4 | Week 4 — Work | Manager Today, handoffs, push routes, Face ID on decisions, company Teach PA |
| 5 | — | Polish, accessibility, the demo XCUITest, int tour, TestFlight |

Stop after each phase with simulator screenshots. Ship to TestFlight only when asked.

---

## 9. Done when

- The demo script (How It Works scenes 1–6 and 10) runs on the phone against int with fake data.
- No AI keys or prompts in the app; audio handled as the gap map decided; nothing sent to a public LLM.
- Deals module and plain CRM screens still work with the PA off or failing.
- `docs/property-pa/IOS_PLAN.md`, screenshots and test results are up to date; open questions listed.
