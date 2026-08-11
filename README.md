# CCMB

CCMB is an unofficial macOS menu bar app that displays Codex usage and credit information without requiring a terminal window.

> CCMB is a community project. It is not affiliated with or endorsed by OpenAI.

## Features

- Weekly Codex usage remaining and positive credit balance, including values below one, in the menu bar
- Spark usage, credit balance, and reset information in the detail menu when the signed-in account provides it
- Manual and configurable automatic refresh
- Local JSON sharing for other apps and Codex chats, with freshness evidence
- Offline and sleep/wake recovery
- Optional launch at login

## Requirements

- macOS 10.15 Catalina or later
- Swift 5.9 or later when building from source
- Codex CLI installed and signed in for the current macOS user

CCMB starts the local `codex app-server` process and uses the current user's existing Codex session. It does not bundle an API key or login credential.

## Share usage with other apps and chats

After every successful refresh, CCMB writes an owner-readable JSON snapshot to:

```text
~/Library/Application Support/CCMB/usage-v1.json
```

CCMB also installs a small local command at `~/.codex/bin/ccmb-usage`. In another Codex chat, ask:

```text
Run ~/.codex/bin/ccmb-usage and tell me the remaining weekly usage and credit balance. If fresh is false, say that the data is old.
```

Use `~/.codex/bin/ccmb-usage --verify-live` when an independent `codex app-server` read should be compared with the saved CCMB value. The JSON includes its source, fetch time, age, running-process check, and verification result. It never includes login tokens.

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

## Privacy and diagnostics

CCMB reads account usage data from the locally installed Codex CLI and displays it on the Mac where it runs. It does not add its own analytics or telemetry. Diagnostic messages use macOS unified logging with private string fields; raw app-server request and response bodies are not logged.

## Contributing

Issues and pull requests are welcome. Please do not include account details, credentials, or diagnostic logs containing personal information in public reports.

## License

CCMB is available under the [MIT License](LICENSE).

OpenAI and Codex are trademarks of OpenAI. Their use here is solely to describe compatibility with the Codex CLI.
