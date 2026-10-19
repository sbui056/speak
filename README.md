# Speak

Hold a key, talk, let go. Clean text appears at your cursor in any Mac app, and everything runs on your Mac.

[![CI](https://github.com/sbui056/speak/actions/workflows/ci.yml/badge.svg)](https://github.com/sbui056/speak/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
![macOS 26](https://img.shields.io/badge/macOS-26%20Tahoe-black?logo=apple)
![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-only-555)

![Speak in action](docs/demo.gif)

Speak is a menu-bar app built on Apple's SpeechAnalyzer and on-device Foundation Models. It makes no network calls, never writes audio to disk, and costs nothing to run.

## Features

- Push to talk in any app. Hold Right Option (or Right Command / Right Control), speak, and release. The text is pasted at your cursor and your clipboard is restored.
- Three modes. Literal types what you said, tidied and with your dictionary applied. Concise and Polished rewrite it with Apple Intelligence.
- By default, a rewrite that changes your words opens a preview first. You can insert it, insert your original words, edit, copy, or cancel.
- Polished keeps your facts. If a rewrite changes a number, date, name, acronym, dictionary term, or a "not", Speak inserts what you said instead.
- A dictionary for names and jargon, replacements for words it keeps mishearing ("pool request" → "pull request"), and an optional pack of about 70 common tech terms.
- Undo insert for 30 seconds, and paste or copy the last transcript from the menu bar.
- When Speak can't paste (no text field, a password field, keys still held), it copies the text and tells you why.
- Optional history of your last 50 dictations, as text only. Off by default.

## Demos

Polished mode: preview the rewrite, press ⏎ to insert.

![Polished mode preview](docs/demo-polish.gif)

Works in any app.

![Dictating into Notes, Terminal, and a browser](docs/demo-anywhere.gif)

Teach it names.

![Adding names to the dictionary](docs/demo-dictionary.gif)

## Install

Requirements: macOS 26 (Tahoe) on Apple Silicon, and the Swift toolchain (Xcode, or the Command Line Tools via `xcode-select --install`). Apple Intelligence is needed only for Concise and Polished.

There is no prebuilt app yet. Build from source:

```sh
git clone https://github.com/sbui056/speak.git
cd speak
scripts/make-identity.sh   # once: creates a local self-signed signing identity
scripts/bundle.sh          # builds, signs, installs to ~/Applications/Speak.app, and launches
```

The local signing identity stays the same across rebuilds, so macOS keeps your permission grants. To update, run `git pull && scripts/bundle.sh`.

Speak asks for three permissions:

| Permission | Used for |
|---|---|
| Microphone | Hearing your dictation. Audio stays in memory. |
| Input Monitoring | Noticing when you hold the shortcut. The key tap only listens; it never blocks or changes keys. |
| Accessibility | Pasting at your cursor, checking that a text field is focused, and Undo. |

After you grant Input Monitoring, Speak relaunches once, because macOS applies that permission only to a new process.

## Usage

| Action | How |
|---|---|
| Dictate | Hold Right Option, speak, release |
| Cancel while talking | Esc, or press another key with the shortcut |
| Preview: insert the rewrite | ⏎ |
| Preview: insert your exact words | ⌥⏎ |
| Preview: copy instead | ⌘C |
| Preview: discard | Esc |
| Change mode or preview behavior | Menu bar → Mode |
| Undo the last paste | Menu bar → Undo insert (within 30 s) |
| Paste or copy the last transcript | Menu bar → Paste last transcript / Copy last transcript |
| Add names and jargon | Menu bar → Dictionary… |
| Browse history (when on) | Menu bar → History… |

Settings covers permissions, the shortcut key, language, Apple Intelligence status, preview behavior, history, launch at login, diagnostics, and a typing test that inserts a fixed sentence without using the microphone.

## Privacy

- No network. Speak has no networking code and no network entitlement. CI checks both on every push (`scripts/check-privacy.sh`).
- No audio on disk. Audio is held in memory for the length of one dictation.
- History is off by default. When on, it stores the text of your last 50 dictations in `~/Library/Application Support/Speak/`, readable only by your account and excluded from backups. Delete all history removes it.
- Logs and Copy diagnostics record states, timings, and error codes, never text.

## Performance

Time from releasing the key to text at the cursor, on an M2 MacBook Air, from Speak's own timing logs:

| Mode | Median | p90 | Dictations |
|---|---|---|---|
| Literal | 0.12 s | 0.20 s | 182 |
| Polished (no preview) | 0.58 s | 0.95 s | 21 |

## Architecture

```mermaid
flowchart LR
  key(["Hold shortcut"]) --> tap["Hotkey tap"]
  tap --> mic["Microphone<br/><small>RAM only</small>"]
  mic --> stt["SpeechAnalyzer<br/><small>on-device</small>"]
  stt --> clean["Literal cleanup<br/><small>+ dictionary</small>"]
  clean -->|Concise / Polished| rw["Foundation Models<br/><small>on-device</small>"]
  rw --> pv["Preview<br/><small>when words change</small>"]
  clean -->|Literal| rules{"Delivery checks"}
  rw -.->|same words| rules
  pv --> rules
  rules -->|pass| paste["Paste at cursor"]
  rules -->|fail| copy["Copy + reason"]
```

All decisions live in `SpeakCore`, a pure state machine with no UI or system frameworks. It reaches the system through small protocols, and the `Speak` target supplies the real adapters. [docs/architecture/v1.md](docs/architecture/v1.md) covers the state machine, delivery rules, and design decisions.

## Development

```sh
scripts/test.sh            # SpeakCore tests, with fakes for audio, speech, keys, and the model
scripts/check-privacy.sh   # no networking, no text in logs, SpeakCore stays framework-free
scripts/latency.sh         # latency per mode and stage, plus memory, from Speak's logs
scripts/soak.sh            # 100 fake dictations in a debug build; memory growth and leaks
scripts/corpus.sh          # 55 fixed dictations through the real model; flags dropped meaning
```

The tests need no microphone, permissions, or Apple Intelligence, so they run in CI. They cover the session state machine, delivery rules, clipboard restore, undo, the rewrite guards (including prompt-injection attempts), the dictionary, and history storage.

## Known limits

- The shortcut key and Esc also reach the focused app, because the key tap only listens.
- Undo is best-effort. It is offered only while the same app and field are focused and the text length still matches.
- Concise and Polished need Apple Intelligence. Without it, Speak uses Literal.
- On layouts where Right Option is AltGr, choose Right Command as the shortcut.
- Terminal editors that remap ⌘V may not paste. Use Copy last transcript instead.
- Remote-desktop and VM apps read the clipboard slowly. If a paste comes out wrong, add the app's bundle ID to `slowPasteApps` in `Sources/SpeakCore/Constants.swift`.

## License

[MIT](LICENSE)
