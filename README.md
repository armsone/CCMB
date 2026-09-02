# CCMB — Codex & Claude Meter Bar

CCMB (Codex & Claude Meter Bar) is an unofficial macOS menu bar app that displays Codex, Claude, Gemini/Antigravity, and Grok usage, reset times, account information, and available Codex and Gemini credits without requiring a terminal window.

> CCMB is a community project. It is not affiliated with or endorsed by OpenAI, Anthropic, Google, or xAI.

## Features

- Codex weekly usage remaining, switching to the positive credit balance when the weekly allowance reaches zero
- Claude five-hour session and weekly usage remaining
- Gemini/Antigravity five-hour and weekly usage remaining, plus AI credit balance, read from the local `agy` CLI
- Grok plan, monthly credit usage, weekly reset time, and extra credit balance, read from the Grok CLI's own local OAuth credential
- A compact four-column Codex, Claude, Gemini, and Grok usage panel with exact reset times and account information
- Manual and configurable automatic refresh
- Signed automatic updates through Sparkle and GitHub Releases
- Local JSON sharing for other apps and Codex chats, with freshness evidence
- Offline and sleep/wake recovery
- Optional launch at login

## Requirements

- macOS 10.15 Catalina or later
- Swift 5.9 or later when building from source
- Codex CLI installed and signed in for the current macOS user
- Claude Code installed and signed in when Claude usage information is required
- Antigravity's `agy` CLI installed and signed in when Gemini usage information is required
- The Grok CLI signed in (`~/.grok/auth.json`, or `$GROK_HOME/auth.json`) when Grok usage information is required

CCMB starts the local `codex app-server` process and uses the current user's existing Codex session. It does not bundle an API key or login credential. Gemini usage is read by launching the locally installed `agy` CLI in read-only plan/sandbox mode; CCMB never sends its own network requests for Gemini data. Grok usage is read by calling the Grok CLI's own billing endpoint with the OAuth token the `grok` CLI already stored locally. When needed, CCMB asks the official Grok CLI to refresh that token or start its browser login flow; CCMB never writes or displays the credential itself.

## Share usage with other apps and chats

After every successful refresh, CCMB writes an owner-readable JSON snapshot to:

```text
~/Library/Application Support/CCMB/usage-v1.json
```

CCMB also installs a small local command at `~/.codex/bin/ccmb-usage`. In another Codex chat, ask:

```text
Run ~/.codex/bin/ccmb-usage and tell me the remaining weekly usage for Codex, Claude, Gemini, and Grok, plus the Codex and Gemini credit balances. If any fresh value is false, say that data is old.
```

Use `~/.codex/bin/ccmb-usage --verify-live` when an independent `codex app-server` read should be compared with the saved CCMB value. The top-level fields describe Codex directly for backward compatibility; the nested `codex`, `claude`, `gemini`, and `grok` objects mirror the same status/weekly remaining/reset/freshness shape for each service, with `codex` also carrying credit and window fields, `claude` also carrying session/model/extra-usage/account fields, `gemini` also carrying its five-hour window and AI credit balance, and `grok` also carrying its plan, monthly used credits, monthly reset, and extra credit balance. Existing consumers reading only the top-level fields or the `codex`/`claude` objects keep working unchanged. It never includes login tokens, Grok access tokens, or Gemini's account-specific upgrade link.

`ccmb-usage` never makes a Claude network request, including with `--verify-live`; it only reads the Claude snapshot already brokered by the running CCMB app or the passive Claude Code statusLine cache. The Claude object reports `source`, `fetchedAt`, `freshForSeconds`, `fresh`, and—while a 429 circuit is open—`circuitState`, `nextEligibleAt`, and `staleReason`, so Codex can distinguish a current reading from an explicitly stale last-known value without increasing Anthropic request frequency.

## iPhone remote sync (CloudKit)

After each successful local publish of `usage-v1.json`, CCMB can also upload the same snapshot to your own iCloud **private database** (container `iCloud.com.armsone.ccmb`, one fixed record overwritten in place — no history accumulates). The companion CCMB-iOS app, signed into the **same Apple ID**, reads that record from anywhere. The record carries only the snapshot JSON, its schema version, the publish time, and the Mac app version — never tokens, cookies, OAuth credentials, raw CLI responses, or local paths. Transport and storage are protected by Apple; only your Apple ID can read the data.

Control it from the menu's **iPhone 원격 동기화** submenu: last sync success/failure time with advice, an automatic-upload toggle, and **지금 동기화** for a manual push. CloudKit failures never delay or fail local refreshes or the local file publish. Values on the iPhone only advance while the Mac is running and uploading fresh data.

As an optional provider-neutral path, choose **Dropbox·Google Drive 폴더 선택…** in the same submenu. CCMB then refreshes `CCMB-usage-v1.json` in that folder after every local publish. The iPhone selects that file once through Files and keeps reading it on refresh. This also works with iCloud Drive, OneDrive, and other File Provider extensions without giving CCMB provider passwords or OAuth tokens.

Remaining external setup (not done by this repository):

1. Register the iCloud container `iCloud.com.armsone.ccmb` in the Apple Developer account and enable it for both app identifiers.
2. Sign the Mac app with `Configuration/CCMB.entitlements` (iCloud container + CloudKit service) and an appropriate provisioning profile. Until then the menu shows "iCloud 서명 없음" and no upload is attempted.
3. Deploy the CloudKit schema (record type `CCMBUsageSnapshot`) from the development environment to production in the CloudKit Console before distributing builds.

The packaging script embeds and signs with that profile for a notarized build:

```sh
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
PROVISIONING_PROFILE="/path/to/CCMB_Developer_ID.provisionprofile" \
NOTARY_PROFILE="ccmb-notary" \
./Scripts/package-macos.sh --notarize
```

## Run from source

```sh
git clone https://github.com/armsone/CCMB.git
cd CCMB
swift run CodexCreditMenuBar
```

For a release build:

```sh
swift build -c release
```

## Package for macOS

Create a Universal (`arm64` and `x86_64`) app bundle and a local test DMG:

```sh
./Scripts/package-macos.sh
```

The generated files are:

```text
Products/Release/CCMB-local.app
Products/CCMB-local.dmg
```

The local package is ad-hoc signed and is not suitable for redistribution. To create a distributable build, use an installed Developer ID Application certificate and an Apple notarization profile:

```sh
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="ccmb-notary" \
./Scripts/package-macos.sh --notarize
```

You can create the notarization profile with:

```sh
xcrun notarytool store-credentials "ccmb-notary"
```

Enter the Apple ID, team ID, and app-specific password at the secure prompts. Do not place the password in command arguments or shell history.

Never commit signing credentials, notarization profiles, or generated app/DMG files. Generated files under `Products/` are ignored by Git.

## Publish a release

Release publishing requires the Developer ID Application certificate, the `ccmb-notary` notarization profile, the Sparkle signing key stored in the login Keychain under the `CCMB` account, and an authenticated GitHub CLI. Then run:

```sh
./Scripts/publish-release.sh
```

The script creates and verifies a notarized Universal app and DMG, signs the update metadata, publishes the versioned DMG to GitHub Releases, and commits the updated `appcast.xml`. Installed builds check that feed every six hours and install signed updates automatically. Keep the Sparkle private key in Keychain and back it up securely; losing it prevents existing installations from trusting future updates.

## Privacy and diagnostics

CCMB reads account usage data from the locally installed Codex CLI, Claude Code session, Antigravity `agy` CLI, Gemini's signed-in usage page, and the Grok CLI's local OAuth credential, and displays it on the Mac where it runs. The Gemini web connection stores only the parsed usage percentages and reset captions; it does not extract or persist cookies, tokens, passwords, or page content. CCMB does not add its own analytics or telemetry. Diagnostic messages use macOS unified logging with private string fields; raw service responses and credentials are not logged. Gemini's account-specific upgrade link (`upgrade_uri`) is never read, persisted, or displayed, and the Grok access token is never logged, displayed, or persisted by CCMB.

## Contributing

Issues and pull requests are welcome. Please do not include account details, credentials, or diagnostic logs containing personal information in public reports.

## License

CCMB is available under the [MIT License](LICENSE).

OpenAI and Codex are trademarks of OpenAI. Claude is a trademark of Anthropic. Gemini and Antigravity are trademarks of Google. Grok is a trademark of xAI. Their use here is solely to describe compatibility with Codex CLI, Claude Code, the Antigravity `agy` CLI, and the Grok CLI.
