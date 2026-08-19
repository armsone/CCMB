# CCMB — Codex & Claude Meter Bar

CCMB (Codex & Claude Meter Bar) is an unofficial macOS menu bar app that displays Codex, Claude, and Gemini/Antigravity usage, reset times, account information, and available Codex and Gemini credits without requiring a terminal window.

> CCMB is a community project. It is not affiliated with or endorsed by OpenAI, Anthropic, or Google.

## Features

- Codex weekly usage remaining, switching to the positive credit balance when the weekly allowance reaches zero
- Claude five-hour session and weekly usage remaining
- Gemini/Antigravity five-hour and weekly usage remaining, plus AI credit balance, read from the local `agy` CLI
- A compact three-column Codex, Claude, and Gemini usage panel with exact reset times and account information
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

CCMB starts the local `codex app-server` process and uses the current user's existing Codex session. It does not bundle an API key or login credential. Gemini usage is read by launching the locally installed `agy` CLI in read-only plan/sandbox mode; CCMB never sends its own network requests for Gemini data.

## Share usage with other apps and chats

After every successful refresh, CCMB writes an owner-readable JSON snapshot to:

```text
~/Library/Application Support/CCMB/usage-v1.json
```

CCMB also installs a small local command at `~/.codex/bin/ccmb-usage`. In another Codex chat, ask:

```text
Run ~/.codex/bin/ccmb-usage and tell me the remaining weekly usage for Codex, Claude, and Gemini, plus the Codex and Gemini credit balances. If any fresh value is false, say that data is old.
```

Use `~/.codex/bin/ccmb-usage --verify-live` when an independent `codex app-server` read should be compared with the saved CCMB value. The top-level fields describe Codex directly for backward compatibility; the nested `codex`, `claude`, and `gemini` objects mirror the same status/weekly remaining/reset/freshness shape for each service, with `codex` also carrying credit and window fields, `claude` also carrying session/model/extra-usage/account fields, and `gemini` also carrying its five-hour window and AI credit balance. Existing consumers reading only the top-level fields or the `codex`/`claude` objects keep working unchanged. It never includes login tokens or Gemini's account-specific upgrade link.

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

CCMB reads account usage data from the locally installed Codex CLI, Claude Code session, and Antigravity `agy` CLI, and displays it on the Mac where it runs. It does not add its own analytics or telemetry. Diagnostic messages use macOS unified logging with private string fields; raw service responses and credentials are not logged. Gemini's account-specific upgrade link (`upgrade_uri`) is never read, persisted, or displayed.

## Contributing

Issues and pull requests are welcome. Please do not include account details, credentials, or diagnostic logs containing personal information in public reports.

## License

CCMB is available under the [MIT License](LICENSE).

OpenAI and Codex are trademarks of OpenAI. Claude is a trademark of Anthropic. Gemini and Antigravity are trademarks of Google. Their use here is solely to describe compatibility with Codex CLI, Claude Code, and the Antigravity `agy` CLI.
