<p align="center">
  <img src="docs/assets/img/banner.png" alt="Copy: a visual shelf for everything you copy" width="820">
</p>

<p align="center">
  <a href="https://github.com/tarikbc/Copy/actions/workflows/ci.yml"><img src="https://github.com/tarikbc/Copy/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/tarikbc/Copy/releases/latest"><img src="https://img.shields.io/github/v/release/tarikbc/Copy?sort=semver&color=4C9DFF" alt="Latest release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0-4C9DFF.svg" alt="License: GPL-3.0"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-1C1F27?logo=apple&logoColor=white" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-5-1C1F27?logo=swift&logoColor=white" alt="Swift 5">
</p>

**Copy is a free, open-source clipboard manager for macOS.** Press <kbd>⇧⌘V</kbd> and a
shelf of cards slides up from the bottom of your screen showing everything you have
copied, ready to search, pin, edit, and paste back. It is local-first, native, and
deliberately quiet: no account, no cloud, no telemetry.

<p align="center">
  <b><a href="https://tarikbc.github.io/Copy/">Website</a> &nbsp;·&nbsp; <a href="https://github.com/tarikbc/Copy/releases/latest">Download</a> &nbsp;·&nbsp; <a href="#install">Install</a> &nbsp;·&nbsp; <a href="#keyboard-shortcuts">Shortcuts</a></b>
</p>

## See it in action

<p align="center">
  <a href="docs/assets/video/copy-showcase.mp4"><img src="docs/assets/img/showcase-poster.png" alt="Watch the one minute Copy demo" width="820"></a>
</p>

<p align="center">
  <b><a href="docs/assets/video/copy-showcase.mp4">Watch the one minute demo</a></b> (MP4, 11 MB). The video is built from code in <a href="video/">video/</a>.
</p>

## Why Copy

The built-in clipboard remembers one thing. Copy remembers all of it, as a visual shelf
you summon from any app. Every copy becomes a card the moment you make it: text, images,
links, files, colors, all captured automatically, newest first, and instantly searchable,
including the text inside screenshots.

## Features

**The shelf**
- Summon with <kbd>⇧⌘V</kbd> from any app; every copy becomes a card, instantly searchable
- Unlimited history with full-text search and scope chips (All / Text / Images / Links / Files)
- On-device OCR makes text inside images searchable, with the match highlighted in results
- Space bar previews a card before you commit, Quick Look for files
- Drag any card out of the shelf, or select several and drag them out together
- Liquid Glass on macOS 26, with a solid, legible fallback (and Reduce Transparency support)
- Follow the system appearance, or keep the shelf light or dark; attach it to the screen edge or let it float
- Haptic feedback on the trackpad when you switch tabs, file a card, paste, and more (optional)

**Organizing**
- Pinboards with colors and any emoji; drag a card onto a tab to keep it, switch with <kbd>⌘1</kbd>–<kbd>⌘9</kbd>
- A callout names the board a dragged card will land in; reorder pinboards by dragging their tabs
- Favorites keep starred cards at the front of the shelf, and can be switched off entirely
- Search scoped to the active pinboard, or your whole history
- Click a card's title to rename it in place; multi-select for bulk actions
- Drawer-first: reach Settings, Updates, and every action from inside the shelf, and
  optionally hide the menu bar icon entirely

**Editing and power tools**
- A real rich text editor: bold, italic, underline, strikethrough, with a live
  character / word / line count
- Copied source code is detected and syntax-highlighted right on the card, like Xcode
- Copy a hex color like `#4C9DFF` and the card shows the actual color
- Rotate copied images; adjust and re-copy colors
- Apple Writing Tools in the editor on macOS 15+

**Pasting**
- <kbd>⏎</kbd> pastes the selected card; <kbd>⌥⏎</kbd> strips formatting and pastes plain text
- Two-click-to-paste by default (single click selects, double click pastes), or switch to single-click
- Paste stack: queue several cards and walk through them on successive <kbd>⌘V</kbd> presses,
  shown as a numbered queue with the next item marked
- Right-click a text card and select **Split into Paste Stack…** to split a list by a separator.
  Preview the entries and remove duplicates if needed. Split entries stay in Paste Stack only and disappear when the app closes.
  Regex separators support mixed lists, such as `[,;\s]+` for commas, semicolons, and whitespace.
  Apple Intelligence suggests a separator or regex when its local model is available. Manual selection works on all supported Macs.
- <kbd>⌘O</kbd> opens the selected link or file without pasting; <kbd>⌘Z</kbd> undoes a delete
- App Intents so Shortcuts can paste your latest item, search, or paste from a pinboard

**Private by design**
- Everything stays on your Mac. No account, no cloud sync, no telemetry
- Respects the system concealed-type marker, so password managers are never recorded
- Per-app exclusions, plus hide the shelf from screen recordings and shares
- Configurable history retention; export and import your history as a single archive

## Install

### Homebrew (recommended)

```sh
brew install --cask tarikbc/tap/copy
```

### Direct download

Grab the latest DMG from [Releases](https://github.com/tarikbc/Copy/releases/latest),
open it, and drag Copy to Applications. Requires **macOS 14 (Sonoma) or later**.

On first launch, Copy asks for Accessibility access (to paste for you) and, on macOS
15.4+, pasteboard access. Summon it any time with <kbd>⇧⌘V</kbd>.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| <kbd>⇧⌘V</kbd> | Open the shelf |
| <kbd>←</kbd> / <kbd>→</kbd> | Move selection |
| <kbd>⌘C</kbd> | Copy the selection to the clipboard |
| <kbd>⌘V</kbd> | Paste the selection |
| <kbd>⏎</kbd> | Paste selected card |
| <kbd>⌥⏎</kbd> | Paste as plain text |
| <kbd>Space</kbd> | Preview selected card |
| <kbd>1</kbd>–<kbd>9</kbd> | Quick-paste the Nth card |
| <kbd>⌘1</kbd>–<kbd>⌘9</kbd> | Switch to history / pinboard tab |
| <kbd>⌘E</kbd> | Edit selected card |
| <kbd>⌘R</kbd> | Rename selected card |
| <kbd>⌘O</kbd> | Open selected link or file |
| <kbd>⌘Z</kbd> | Undo the last delete |
| <kbd>⌫</kbd> | Delete selected card (when the search box is empty) |
| <kbd>⌘⌫</kbd> | Clear the search, or delete the selected card |
| <kbd>⌘N</kbd> | New item |
| <kbd>⇧⌘C</kbd> | Toggle the paste stack |

## Build from source

Requirements: macOS 14+, Xcode 16+, and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
xcodegen generate
xcodebuild -project Copy.xcodeproj -scheme Copy -configuration Debug build
```

Core engine tests:

```sh
swift test --package-path CopyCore
```

The app is a thin SwiftUI + AppKit shell over **CopyCore**, a local Swift package
(GRDB / SQLite + FTS5) that holds the clipboard engine, storage, and all the logic that
carries a test suite. UI lives in the app target; behavior lives in CopyCore.

### Cutting a release

Pushing a version tag (`vX.Y.Z`) runs `.github/workflows/release.yml`, which builds,
signs, notarizes, and publishes the full release: a Developer ID signed and notarized
DMG, a signed Sparkle update zip, an updated `docs/appcast.xml` committed back to `main`,
and a GitHub release with both artifacts attached. See `RELEASING.md` for the
required secrets and the release ritual, and `Scripts/release.sh` for the underlying
pipeline (the same script CI runs).

## Privacy

Copy is local-only, with one exception: link previews fetch the page title and favicon
for copied links directly from the web. This is on by default and can be turned off in
Settings under History. Aside from that and checking for app updates, Copy makes no
network calls, has no analytics or crash reporting, and your clipboard history never
leaves your Mac. Any app that marks its pasteboard content as concealed, such as a
password manager, is skipped entirely, and you can add per-app exclusions for anything
else you would rather Copy ignore.

## Contributing

Copy is built in the open and contributions are welcome. Good places to start:

- ⭐ Star the repo and follow along
- 🐛 [Open an issue](https://github.com/tarikbc/Copy/issues) for a bug or a feature idea
- 🔧 Send a pull request. The core engine lives in `CopyCore` and has its own test suite
  (`swift test --package-path CopyCore`); please add or update tests for any engine change

The design language is deliberately quiet and native (no colored card stripes, no
clutter), and the app keeps a macOS 14 floor with newer-OS features gated behind
availability checks.

Commits need a `Signed-off-by` trailer, which `git commit -s` adds for you. CI
checks it. [CONTRIBUTING.md](CONTRIBUTING.md) has the build commands and explains
what the sign-off certifies.

## License

[GPL-3.0](LICENSE). © 2026 Tarik Caramanico.

Forks are welcome and the code is yours to take. The name and the artwork are not
part of that grant: [NOTICE](NOTICE) records an additional term under GPL-3.0
section 7(e), and [TRADEMARK.md](TRADEMARK.md) says what it means in practice. The
short version is to ship your fork under your own name.
