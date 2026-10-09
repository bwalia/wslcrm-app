# iOS release pipeline (GitHub Actions + fastlane + Vault)

Builds, signs and ships the WSLCRM iOS app to TestFlight testers. It's the same pipeline as
Fishers (`bwalia/fishers`, `ios/fastlane`), adapted to this repo.

| Stage | Workflow | When |
|-------|----------|------|
| **CI** | `.github/workflows/ios.yml` | Every push and pull request touching the app: unit tests, plus an unsigned build of the tester configuration. Runs on GitHub's macOS runners. |
| **TestFlight (auto)** | `.github/workflows/ios_release.yml` | Every merge to `main` that touches the app |
| **TestFlight (tag)** | same | Push a `v1.2.3` tag: ships as version 1.2.3 |
| **TestFlight (manual)** | same, Run workflow → **testflight** | Any time; pick **Int** or **DBS-Int** |
| **Re-invite testers** | same, Run workflow → **invite_testers** | Re-send invites for the latest build, no rebuild |
| **App Store review** | same, Run workflow → **app_store** | After TestFlight sign-off |

Testers get **Workstation CRM** (scheme `WSLCRM-Int`): the house brand (`docs/brand/`),
pointed at the int server. Every configuration shares the bundle id `uk.co.workstation.wslcrm`,
so TestFlight holds one app; a manual run with **DBS-Int** ships the DBS Ltd demo build instead.

Skip an automatic release with `[skip release]` or `[skip ios]` in the merge commit message.

## Flow

```
merge to main (app changed)   or   push v1.2.3   or   Run workflow
                  └──────────────────┬──────────────────┘
                                     ▼
          load ASC secrets (GitHub secrets, else WSLVault kv/wslcrm/ios)
          verify the API key against App Store Connect
                                     ▼
          version: tag → input → project.yml MARKETING_VERSION
          build number: latest TestFlight build for that version + 1
                                     ▼
          fastlane prepare_signing   persistent keychain, App Store profile
          fastlane build_ipa         archive Release-Int → WSLCRM.ipa
                                     ▼
          fastlane beta              upload, wait for processing, then:
            • internal group "WSLCRM Team": installs straight away, no review
            • external group "WSLCRM": after Beta App Review (only if demo login set)
            • each tester invited; anyone not yet on the ASC team gets a team invite
```

## Security

The repo is **public**. The release job runs on the self-hosted Mac Studio, and only for
pushes to `main`, tags and manual runs, all of which need write access. Pull requests run
`ios.yml` on GitHub's runners and never reach that machine. Keep it that way: don't add a
`pull_request` trigger to anything with `runs-on: self-hosted`.

## One-time setup

### 1. The app in App Store Connect

Apple's API can't create apps, so do this once by hand:

1. App Store Connect → Apps → **+** → New App.
2. Platform iOS, name **WSLCRM** (or the name testers should see), bundle id
   **uk.co.workstation.wslcrm**. Register the App ID in the Developer portal first if it isn't
   offered. SKU: anything, e.g. `wslcrm`.

Until it exists, the pipeline stops at "Compute next build number" with a clear message.

### 2. Signing secrets

The same App Store Connect API key as Fishers works, if it's a **Team** key on the same Apple
team. Either option works:

**GitHub secrets** (Settings → Secrets and variables → Actions):

| Secret | Value |
|--------|-------|
| `ASC_KEY_ID` | 10-character Key ID (App Store Connect → Users and Access → Integrations) |
| `ASC_ISSUER_ID` | Issuer ID (UUID) at the top of that page |
| `APPLE_TEAM_ID` | 10-character Team ID |
| `ASC_PRIVATE_KEY_B64` | `base64 -i AuthKey_XXXX.p8 \| tr -d '\n'`. Optional on the Mac Studio when `~/AuthKey_<KEY_ID>.p8` is there. |

```sh
gh secret set ASC_KEY_ID -R bwalia/wslcrm-app
gh secret set ASC_ISSUER_ID -R bwalia/wslcrm-app
gh secret set APPLE_TEAM_ID -R bwalia/wslcrm-app
```

**WSLVault**, at `kv/wslcrm/ios` on https://vault.workstation.co.uk:

```sh
ASC_KEY_ID=... ASC_ISSUER_ID=... APPLE_TEAM_ID=... \
ASC_P8_PATH=$HOME/AuthKey_XXXX.p8 scripts/ci/seed-ios-vault.sh
```

GitHub secrets win when both are set.

Inviting testers to the App Store Connect team, which is what lets them install without
review, needs the key to have the **Admin** role. With a lower role, uploads still work but
testers land on the external group.

### 3. Testers and Beta App Review

| Setting | Kind | Purpose |
|---------|------|---------|
| `TESTFLIGHT_TESTERS` | variable | Comma-separated emails. Defaults to the Fishers testers. |
| `TESTFLIGHT_DEMO_USER` / `TESTFLIGHT_DEMO_PASSWORD` | secrets | A DBS Group demo login for Apple's reviewers. Without these, external review is skipped and only internal testers get builds. |
| `TESTFLIGHT_CONTACT_PHONE` | variable | Reviewer contact phone, needed for external review. |

```sh
gh variable set TESTFLIGHT_TESTERS -R bwalia/wslcrm-app --body "a@example.com,b@example.com"
```

A new internal tester first gets Apple's "You've been invited to App Store Connect" email.
Once they accept it, run the workflow with **invite_testers** and the build appears in their
TestFlight app.

### 4. Self-hosted runner

Register the Mac Studio for this repo, alongside the other `~/actions-runner-*` runners:

```sh
mkdir ~/actions-runner-wslcrm && cd ~/actions-runner-wslcrm
tar xzf ~/actions-runner-fishers/actions-runner-osx-arm64-*.tar.gz
./config.sh --url https://github.com/bwalia/wslcrm-app \
  --token "$(gh api -X POST repos/bwalia/wslcrm-app/actions/runners/registration-token -q .token)" \
  --name Balinders-Mac-Studio-wslcrm --labels self-hosted,macOS,ARM64 --unattended
./svc.sh install && ./svc.sh start
```

It needs Xcode, XcodeGen and Ruby, the same as Fishers.

### Signing keychain

fastlane keeps the Apple Distribution certificate in a persistent keychain so each build
doesn't mint a new one; Apple caps them per team. When the Fishers keychain
(`~/Library/Keychains/fishers-signing.keychain-db`) exists it's reused, because it's the
same team and certificate. Otherwise WSLCRM creates `wslcrm-signing.keychain-db`, with its
password in `~/.secrets/wslcrm/keychain-password`.

## Local dry run (on the Mac Studio)

```sh
bundle install
eval "$(scripts/ci/load-ios-secrets.sh)"
bundle exec ruby scripts/ci/verify-asc-api-key.rb
bundle exec fastlane ios test           # unit tests, no signing
VERSION_NAME=1.0.0 bundle exec fastlane ios ci_build_number
```

## Files

| Path | Role |
|------|------|
| `fastlane/Fastfile` | Lanes: `test`, `ci_build_number`, `prepare_signing`, `build_ipa`, `beta`, `invite_testers`, `release` |
| `fastlane/Appfile` | Bundle id |
| `Gemfile`, `Gemfile.lock` | fastlane and the gems Ruby 4 no longer ships |
| `scripts/ci/load-ios-secrets.sh` | GitHub secrets, else Vault, into the job's environment; writes the `.p8` to a temp file |
| `scripts/ci/verify-asc-api-key.rb` | Fails early, with a readable message, if Apple rejects the key |
| `scripts/ci/seed-ios-vault.sh` | Writes `kv/wslcrm/ios` |
| `.github/workflows/ios.yml` | CI on GitHub's runners |
| `.github/workflows/ios_release.yml` | Release on the Mac Studio |
