# Property PA on iPhone: demo and tour

The Property PA is the AI personal assistant in Workstation AI-native CRM. The CRM is the system of
record; the PA is the system of work. You ask it what to do next, it prepares you for calls, you
tell it what happened, and the CRM updates underneath after you confirm.

Everything below runs on **int** with the How It Works demo data (fake people and numbers), seeded by
`scripts/seed-property-deals.py`. Screenshots are in `docs/demo/pa-tour/`.

## Try it

TestFlight build 9 or later, workspace **Demo Buyers Ltd**. Password and the test 2FA code are in
`build/demo-buyers-ltd.env` (ask Balinder).

| Sign in as | Who | What you see |
|---|---|---|
| `pd.sophie` | Sophie Turner, seller agent | Her PA Today: 10 sellers and a buyer, ranked |
| `pd.ashley` | Ashley Brooks, manager | Manager Today (exceptions only) and Teach PA |

The **PA** tab is first. The **Deals** tab still has the plain CRM screens.

## The tour

### Sophie, seller agent

1. **"What do I need to focus on today?"** (`tour-01-today`). The brief, then cards in order.
   Sarah Hughes is #1: her second valuation was yesterday and she said she'd decide after it.
2. **"Why is this #1?"** (`tour-02-why`). The real signals and their points (promise due 30,
   event just happened 25, hot 15). The order comes from rules, not from the AI, so it can always
   be explained.
3. **"I have 30 minutes."** (`tour-03-thirty-minutes`). Only the cards that fit, most important
   first; the rest wait.
4. **Prepare me** (`tour-04-prepare`, `tour-05-prepare-questions`). A 30-second brief before the
   call, built from records: snapshot, last conversation, price and offers, promises, likely
   objections, and questions for what isn't known yet. Every fact links to where it came from. An
   inference (e.g. "the valuation may anchor her") is labelled, never shown as fact.
5. **Coach** (`tour-06-coach`): "Sarah won't go below £235k. What should I do?" The PA asks
   questions first (price or speed? has Tom seen the figures?) and never suggests a higher
   offer. Changing an offer is a person's decision.
6. **Ask PA** (`tour-07-ask-pa`): open questions in chat. On int this says *"The PA isn't
   connected"* until JobShout (the agent platform that runs the private model) is linked. The
   app says so plainly rather than guessing.
7. **After the call: tell your PA.** Hold the mic and speak (or type). The voice note goes to
   Workstation's private speech service, never a public AI. The PA proposes changes on a confirm
   sheet: *Seller's stated minimum £235,000 (stated)*, *Price that might work £225,000
   (SOPHIE'S JUDGEMENT, UNCONFIRMED)*, *Next action: call Sarah tomorrow 11:00*. Prices, offers,
   decision makers and next-action times each need their own tick. Needs JobShout too.
8. **Ask your manager.** The exact question, the PA's recommendation and the facts go to Ashley as
   a decision card. (On int, choosing the manager needs opsapi's `/managers` route, requested.)

### Ashley, manager

9. **Manager Today** (`tour-08-manager-today`): *"3 need you. Everything else (10) is being
   handled."* Exceptions only: a relationship at risk (Rick, 21 days without a meaningful
   conversation), deals at risk, decisions waiting. Each opens the brief or the deal.
10. **Decide a handoff**: Agree or reply with Face ID; the answer goes back onto the deal and into
    Sophie's next brief.
11. **Teach PA** (`tour-09-teach`, `tour-10-rule-approved`): *"An agent's valuation is not the
    seller's minimum price. Treat it as their anchor."* Ashley picks when it applies (the app
    suggests *A valuation* and *Talking price* from the words), chooses the company, and approves
    it with Face ID. It's saved as version 1, and from then on it appears in the playbook of
    Prepare me for any seller with a recent valuation, such as Sarah.

## How the PA learns ("AI training")

**The model itself is not trained on your data.** The PA runs on a private model on Workstation's
own servers (swappable by configuration). Client data never goes to ChatGPT, Claude or Gemini, and
nothing you do changes the model's weights. Instead, the PA gets better in four controlled ways,
all visible and reversible:

1. **Teach PA: rules people write and approve.** A manager (or the PA, flagged as a suggestion)
   proposes a rule in plain words. It becomes a versioned record with a rationale and triggers
   (e.g. *valuation*, *price*). Company and team rules need a manager's approval (Face ID on the
   phone); personal rules apply to your own PA only. Approving a new version supersedes the old one,
   and old versions stay readable. When a situation matches a rule's triggers, the PA uses it in
   Prepare me, coaching and chat answers, and cites it. A 10-rule seller playbook is there from
   day one.
2. **Corrections teach the record, with history.** When you change something on the confirm sheet
   (£225k → £230k), the correction is saved as the current value and the PA's version is kept
   in the history: source, model, prompt version and who approved it. Facts are marked stated or
   inferred, so a judgement is never later treated as a known fact.
3. **Priority is rules, tuned by people.** "Why #1?" shows named signals with weights (promise due,
   event just happened, days since meaningful contact, temperature…). Workstation tunes the
   weights; the AI only words the explanation. It never decides the order.
4. **Every change is checked before it's shown.** Answers must cite real records; anything that
   can't be traced is held back with a reason ("grounded or silent"). Before any model or provider
   change, the P01–P12 regression suite (built from these scenes) is run.

So "training" the PA means teaching it your company's way of working (rules), correcting what it
hears (with history), and tuning what matters most (weights). Each of these is a decision a person
can see, approve and undo.

## What needs switching on next (opsapi)

- **JobShout link** for Ask PA chat and voice-note capture (Workspace → AI providers, PA settings).
- **`GET /managers`** so an agent can pick who to ask (handoffs).
- **Card Done / Later** routes (the app hides those buttons until they exist).
