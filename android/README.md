# WSLCRM for Android

A native Kotlin/Compose mirror of the SwiftUI app in `../WSLCRM`. It has the core (networking,
auth, offline queue, permissions, theme), the work-management rules, an app shell (sign-in with
2FA, biometric unlock, workspace choice, Shop and More tabs) and the **shop back office**
(`features/shop`): dashboard, orders, quotes, products, categories, stock, market prices, and the
shop assistant's chats and knowledge, over `/api/v2/shop/admin`. The Shop tab appears only where
the workspace's menu includes `shop`. Field service, CRM and project screens come next.

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
