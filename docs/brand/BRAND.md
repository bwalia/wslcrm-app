# Workstation CRM brand

**Workstation CRM runs the work: jobs, visits, boards, timesheets and property deals, from the
office to the van.** It is the phone and tablet side of OpsAPI, so it shares OpsAPI's colours
and type, and adds a mark and a style of its own.

Open `index.html` for the visual guide.

## Name

- Write **Workstation CRM**: "Workstation" as one word, "CRM" in capitals.
  Not "WorkStation", "Workstation crm" or "WSL CRM".
- **WSLCRM** is the code name (bundle, scheme, repo). People never see it in the app.
- In the wordmark, "Workstation" is ink (white on dark) and "CRM" is the primary pink.

## Tagline

- Primary: **Work, done.**
- Alternatives: *From booked to done.* · *Every job, one route.*

## Logo

| File | Use |
|---|---|
| `logo-icon.svg` | iOS app icon, full bleed 1024 (iOS rounds the corners). Rendered into `WSLCRM/Resources/Assets.xcassets/AppIcon.appiconset`. |
| `logo-icon-dark.svg` / `logo-icon-tinted.svg` | The iOS 18+ dark and tinted home-screen icons. |
| `logo-glyph.svg` / `logo-glyph-on-dark.svg` | The mark alone: in-app, favicons, avatars. The start dot is ink on light and white on dark. |
| `logo-mono.svg` | One colour (`currentColor`) for embossing, watermarks and single-colour print. |
| `lockup.svg` / `lockup-on-dark.svg` | Mark + wordmark, the default logo. |
| `wordmark.svg` / `wordmark-on-dark.svg` | Wordmark alone, where the mark is already nearby. |
| `icon-layers/` | Layers for Icon Composer (Liquid Glass). |
| `png/` | PNG renders (`@2x`) and `brand-preview.png`. |

**The mark** is a "W" drawn as one continuous route. It starts at a dot (the job, the place
someone is heading) and its last stroke climbs past the first, so the W finishes as a tick:
work, done. The colour runs light to deep along the route.

- **Clear space:** the height of the start dot's halo, about a quarter of the mark's height, on every side.
- **Minimum size:** the mark is 16 px tall on screen; the lockup is 140 px wide.
- **Don't:** recolour the route, flip or rotate it, move the start dot, outline it, add
  effects, or set the full-colour logo on busy photos (use the mono mark there).
- The wordmark is **Plus Jakarta Sans ExtraBold** converted to outlines
  (SIL Open Font License, `fonts/OFL.txt`), so it renders the same everywhere.

Every file here comes from `tools/build-brand.py`. Change the mark or a colour there and rerun:

```sh
pip install fonttools          # rsvg-convert comes from `brew install librsvg`
python3 docs/brand/tools/build-brand.py docs/brand --app WSLCRM/Resources/Assets.xcassets
```

## Colour

The OpsAPI dashboard palette (`opsapi-dashboard/app/globals.css`), so the app and the web
dashboard look like one product.

| Token | Hex | Role |
|---|---|---|
| Primary | `#FF004E` | The brand colour: the mark, "CRM", hero moments |
| Primary 400 / 700 | `#FF6088` / `#C20035` | The route gradient's ends. 700 is the solid button fill on light (white text 6:1) |
| Primary 600 | `#E6003F` | App tint on light; button fill on dark |
| Ink | `#0F172A` | Text and the wordmark on light |
| Night | `#0B1120` / `#131A2B` | Dark backgrounds and surfaces; the icon background |
| Slate | `#64748B` | Secondary text |
| Emerald | `#10B981` | Done, on track |
| Amber | `#F59E0B` | At risk, warnings |
| Red | `#EF4444` | Late, overdue, errors |

**Route gradient:** Primary 400 → Primary → Primary 700, left to right, booked to done.
Use it for the mark and hero moments, never behind body text.

Red, amber and green mean status (late, at risk, on track) and nothing else, and they always
come with an icon and words.

## In the app

- `AccentColor` is the tint (`#E6003F` light, `#FF6088` dark). `AccentColor-Fill` and
  `AccentColor-Text` are the contrast-checked button fill and text colours behind `Tone.brand`,
  which every large primary button uses.
- A white-label build brings its own: `Config/Brand-DBS.xcconfig` sets
  `BRAND_ACCENT_COLOR = AccentColor-DBS`, its icon and mark.
- Text is the system font (SF Pro) so Dynamic Type, VoiceOver and Bold Text work. Apple's
  licence keeps SF out of logos and marketing, which is why the brand uses Plus Jakarta Sans.

## Typography

- **Brand, marketing and the web dashboard:** Plus Jakarta Sans. ExtraBold 800 for headlines
  and the wordmark, SemiBold 600 for subheads, Regular 400 for body.
- **In the iOS app:** SF Pro, Apple's system font.
- **Code:** SF Mono / ui-monospace.

## Shape and motion

- Rounded everything: strokes with round caps and joins, cards at 14–18 pt corners.
- The **route** is the brand motif: a single line with a start dot. Use it for empty states,
  progress and onboarding illustrations.
- Motion is quick and calm: 150–250 ms, ease-out. Respect Reduce Motion.

## Voice

Plain, confident, practical. Say what happened and what's next.

| Do | Don't |
|---|---|
| "Visit checked in at 09:12. Photos upload when you're back online." | "Success! Your check-in has been processed!" |
| "7 Mill Lane is £7,000 at risk. The buyer's AML check is missing." | "Warning: deal health degraded." |
| "Couldn't reach the server. Your changes are saved on this phone." | "Error -1009." |
