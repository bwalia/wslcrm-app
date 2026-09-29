# Android release (Google Play)

Two workflows, the same split as iOS and as Fishers:

| Workflow | Trigger | Does |
|---|---|---|
| `android.yml` | any change to `android/**` | unit tests, lint, debug build (GitHub's Ubuntu runners) |
| `android_release.yml` | merge to `main`, a `v*.*.*` tag, or a manual run | signed AAB → Play testing track |

Testers get the **dbsInt** flavour: package `uk.co.workstation.wslcrm.dbs`, DBS Ltd branding on
the int server, the Android twin of the iOS TestFlight build. A manual run can ship **int**
(`uk.co.workstation.wslcrm.integration`) instead. Each flavour is its own Play app.

Skip an automatic release with `[skip release]` or `[skip android]` in the commit message.
Until the keystore secret exists, merges don't attempt a release at all (the `gate` job),
so the pipeline stays quiet rather than red.

## Before the first automated release

**Google Play's API can't create an app.** The first bundle has to be uploaded by hand
before `android_release.yml` can push anything. Trying the API first fails with a
package-not-found error that looks like a credentials problem but isn't.

1. Play Console → **Create app**, package `uk.co.workstation.wslcrm.dbs`.
2. Build a signed AAB locally (below) and upload it to **Internal testing** by hand.
   Complete the store listing, content rating and data-safety form enough for testing.
3. **Internal testing → Testers**: add the testers' Google accounts (or a Google Group) and
   share the opt-in link.
4. From then on the workflow takes over.

## Signing

Play App Signing holds the real app signing key. CI holds only the **upload key**, which
proves a bundle came from us. If it leaks, it can be rotated in the Play Console without
republishing the app.

Create it once and keep it with the iOS secrets:

```bash
keytool -genkey -v -keystore upload-keystore.jks \
  -keyalg RSA -keysize 2048 -validity 10000 -alias upload
base64 -i upload-keystore.jks | tr -d '\n' | pbcopy
```

## Repository secrets

| Secret | What |
|---|---|
| `ANDROID_KEYSTORE_B64` | base64 of `upload-keystore.jks` |
| `ANDROID_KEYSTORE_PASSWORD` | its store password |
| `ANDROID_KEY_ALIAS` | the alias (`upload` above) |
| `ANDROID_KEY_PASSWORD` | that key's password |
| `PLAY_SERVICE_ACCOUNT_JSON` | the whole service-account JSON, pasted |

```bash
gh secret set ANDROID_KEYSTORE_B64 -R bwalia/wslcrm-app < <(base64 -i upload-keystore.jks | tr -d '\n')
gh secret set PLAY_SERVICE_ACCOUNT_JSON -R bwalia/wslcrm-app < play-service-account.json
```

If the keystore or service account is missing, the release fails with a named error rather
than uploading an unsigned bundle.

### The Play service account

1. Play Console → **Setup → API access** → link or create a Google Cloud project.
2. Create a service account and grant it **Release manager**, or narrower: release to
   testing tracks only.
3. Create a JSON key and paste the file into `PLAY_SERVICE_ACCOUNT_JSON`.

Permissions can take a few hours to propagate. A `403` on the first run usually means
"not yet", not "wrong".

## Versioning

- **`versionCode`** is the workflow's run number, passed as `-Pwslcrm.versionCode`. Play refuses
  a code it has already seen, and the run number only goes up.
- **`versionName`** comes from the tag (`v1.4.0` ships as `1.4.0`), the manual input, or 1.0.0.

## Building locally

```bash
cd android
./gradlew :app:bundleDbsIntRelease -Pwslcrm.versionCode=1
```

Without `android/key.properties` the bundle is **unsigned** and Play won't take it. To sign
locally, put the `.jks` in `android/` and create `android/key.properties` (both git-ignored):

```properties
storeFile=upload-keystore.jks
storePassword=…
keyAlias=upload
keyPassword=…
```
