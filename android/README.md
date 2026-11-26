# WSLCRM for Android

A native Kotlin/Compose mirror of the SwiftUI app in `../WSLCRM`. It has the core (networking,
auth, offline queue, permissions, theme), the work-management rules, an app shell (sign-in with
2FA, biometric unlock, workspace choice, Home, AI, Projects, Shop and Menu tabs) and the **shop back office**
(`features/shop`): dashboard, orders, quotes, products, categories, stock, market prices, and the
shop assistant's chats and knowledge, over `/api/v2/shop/admin`. The Shop tab appears only where
the workspace's menu includes `shop`.

**Menu = the web's menu** (`features/menu`), as on iOS: the Menu tab shows the web dashboard's sidebar
from `GET /api/v2/user/menu` (same groups, order and items for the person and workspace, so the
workspace's modules and the person's permissions apply exactly as on the web). The shop opens its own
screens; every other module opens its web page inside the app, signed in to the selected workspace
(`WebPageScreen`: a WebView that first writes the dashboard's sign-in on its own origin, plus the
in-app flag that hides the dashboard's top bar). The **Projects** tab (the web's project management)
appears wherever the person's menu has it. Web storage is wiped on sign-out; links to other sites open
outside the app.

**Home** (`features/home`, the first tab) puts the AI agent first, as iOS does: one box that searches the
person's menu ("Jump to") and sends anything else to the agent, suggestions led by what needs them today,
"Continue where you left off", the shop's counts and the apps grid. **AI** (`features/assistant`) is the agent,
native (`AssistantScreen` on `POST /api/chat/agent`): it does jobs with the person's permissions, asks before
deleting anything (Confirm / Cancel), says what happened, keeps a failed message in the box and offers "Open …"
for the screens it worked in. `CommandRouter` decides what opens at once and what goes to the agent; it only
offers places the app can open.

## Flavours

| Flavour  | API                                   | Brand   | iOS scheme       |
|----------|---------------------------------------|---------|------------------|
| `int`    | https://int-opsapi.workstation.co.uk  | WSLCRM  | `WSLCRM-Int`     |
| `dbsInt` | https://int-opsapi.workstation.co.uk  | DBS Ltd | `WSLCRM-DBS-Int` |
| `local`  | http://10.0.2.2:4011 (the Mac, from the emulator) | DBS Ltd | `WSLCRM-Local` |
| `prod`   | supplied at build time, https only    | WSLCRM  | `WSLCRM-Prod`    |

The prod URL is never committed. Pass `-Pwslcrm.prodApiBaseUrl=https://…`, set
`WSLCRM_PROD_API_BASE_URL`, or put `wslcrm.prodApiBaseUrl=https://…` in `local.properties`
(git-ignored). A prod build fails without it. `wslcrm.localApiPort` changes the local port.

## Build and test

```sh
./gradlew :app:assembleIntDebug
./gradlew :app:testIntDebugUnitTest
```

Unit tests run on the JVM. Captured API payloads are shared with iOS from `../WSLCRMTests/Fixtures`.
