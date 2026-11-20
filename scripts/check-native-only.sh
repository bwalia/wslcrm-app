#!/usr/bin/env bash
# The iOS app is native only: every screen is SwiftUI. No web page is ever shown inside the app,
# and the app never sends people to the web dashboard instead of a screen of its own.
#
# This fails the build when any web view or web-page route appears in the app's sources, so it
# can't come back by accident. A missing screen is built natively (see README "Native modules"),
# never replaced with a web page.
#
#   scripts/check-native-only.sh        # exit 0 = clean, 1 = a web view crept in
set -euo pipefail
cd "$(dirname "$0")/.."

# What counts as a web page in the app:
#   WebKit / WKWebView        an embedded browser
#   SafariServices            an in-app Safari sheet
#   WebPageView/Route/Session the old "dashboard page inside the app" plumbing
#   loadHTMLString            HTML rendered as a screen
banned='import WebKit|WKWebView|WKWebsiteDataStore|import SafariServices|SFSafariViewController|WebPageView|WebPageRoute|WebSession|loadHTMLString|webView\('

matches=$(grep -rnE "$banned" WSLCRM --include='*.swift' || true)
if [ -n "$matches" ]; then
  echo "error: the app must be native only — no web views or web pages (scripts/check-native-only.sh)."
  echo "Build the screen in SwiftUI instead. Found:"
  echo "$matches"
  exit 1
fi

# The project must not link WebKit either.
if grep -nE 'WebKit\.framework|SafariServices\.framework' project.yml WSLCRM.xcodeproj/project.pbxproj >/dev/null 2>&1; then
  echo "error: WebKit or SafariServices is linked in the project. The app is native only."
  exit 1
fi

echo "native-only check passed: no web views in WSLCRM/"
