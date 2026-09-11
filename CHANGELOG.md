# Changelog

All notable changes to Copy are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.7] - 2026-09-11

The keyboard shortcuts you already expect, image files that look like images, and a quieter close.

### Added

- <kbd>⌘C</kbd> copies the selected cards to the clipboard and <kbd>⌘V</kbd> pastes them, while a bare <kbd>⌫</kbd> deletes the selected card. All three act on your whole selection, the way <kbd>⌘⌫</kbd> already did. The two clipboard shortcuts step aside whenever there is text in the search box, so you can still paste a search term in and copy one back out.
- A card holding an image file previews as the picture when you press <kbd>Space</kbd>, instead of a generic document icon. The Image filter in search finds those cards now too, not only pictures you copied directly.
- An optional sound when Copy records something new, under Settings, General. It is off unless you turn it on, and you can pick any of the sounds macOS already ships.

### Fixed

- Closing the shelf on macOS 26 no longer flashes for a frame. The app underneath gets focus back after the shelf is fully gone, so a paste lands where you meant it to.
- Card timestamps no longer get cut short. The source app name gives way instead.
- <kbd>⌘,</kbd> opens Settings. It used to open an empty window.

## [0.1.6] - 2026-08-15

Favorites hold their place while you scroll back through history.

### Fixed

- Starred items no longer appeared from nowhere and pushed the row sideways as you scrolled into older history. Every favorite now loads alongside the newest cards, however old it is, so the front of the shelf stays where you left it. Search results behave the same way.

## [0.1.5] - 2026-08-15

The shelf scrolls through your whole history now, not just the last couple of days.

### Fixed

- The shelf stopped roughly 100 cards back, about two days of normal use, whatever you had set under Keep History. It now loads older cards as you scroll toward the end, so you can reach everything your retention setting keeps. Text search does the same instead of capping at the first 100 matches.

## [0.1.4] - 2026-08-01

Drag a card onto a pinboard and it just works now, plus a fix so updates install.

### Added

- An unpin button appears on card hover while you're viewing a pinboard, to remove the card from that pinboard without opening the menu.

### Changed

- Dragging a card now shows a compact chip under the cursor instead of a full-size card, so the pinboard tabs you're aiming for stay visible, and the target tab highlights clearly.

### Fixed

- Dragging a card onto a pinboard reliably files it there now. It previously did nothing, or dropped the text into whatever app was behind the shelf.
- Automatic updates install correctly again. The update feed pointed at the wrong download, so the app reported new versions as improperly signed.

## [0.1.3] - 2026-07-30

Smart search lands, plus a rounder shelf and some paper-cut fixes.

### Added

- Smart search: start typing in the shelf to filter by app, type, time range, favorites, or pinboard. Each pick becomes a filter pill, and you can stack several and add free text, which searches content including text recognized inside images. Right-click a result and choose Show in History to jump straight to it.
- A Paste Stack button in the shelf header, with its shortcut shown when you hold Command.
- "View Onboarding Again" in Settings, under About.

### Changed

- The shelf opens ready to browse: the search field no longer grabs focus, and you can just start typing to search.
- Quick-pasting a card by number moved to Option and a number, so plain numbers type into search. Hold Option to see each card's number.
- The shelf now animates closed with a gentle fade and slide.
- Pinboards: click the pinboard you're already on to edit it, and choose any custom color.

### Fixed

- Copied hex colors, with or without a leading #, now show as a color swatch and match the Color filter.
- Code snippets keep their indentation, and more Swift snippets get syntax colors.
- Command-Delete clears an active search.

## [0.1.2] - 2026-07-30

A settings overhaul, plus finer control over what Copy keeps.

### Added

- Redesigned Settings as a sidebar: General, Shortcuts, History, Privacy, and a new About page (version, Check for Updates, and project links). The keyboard shortcuts now have their own page instead of crowding General.
- History retention is now a slider, from 1 Day up to Unlimited.
- Storage usage in History: see how much space each type of item uses (Text, Links, Images, Files, Colors), and clear a single type or the whole history, with the reclaimable size shown up front.

### Fixed

- The Keyboard & Tips window now has its background instead of rendering transparent.

## [0.1.1] - 2026-07-30

A refinement release: the Paste Stack is rebuilt from the ground up, the shelf and
editor get a polish pass, and there's an optional dark theme.

### Added

- Optional pro-dark shelf theme (dark with an electric-blue accent), off by default
- Hold Command to reveal keyboard hotkey hints on the shelf, plus a dismissible keyboard legend
- Force-click a card to preview it; force-click a text card to open it in the editor
- Favorites now sort to the top of the shelf, separated from the rest by a divider
- A first-copy coach and onboarding motion to make the shelf easier to discover

### Changed

- Rebuilt the Paste Stack palette: clicks land reliably everywhere, you can add, edit, remove, and reorder queued items, drag the header to move it, and edit text in the full rich editor
- Redesigned the rich text editor with formatting hotkeys, on-screen tips, and Command-Return to save
- The card header now shows the copy's title where the app name used to be; click it to rename
- You can scroll the shelf from anywhere, including the gaps between cards
- Image cards are labeled "Image" with a photo icon in the header
- Dropping a card onto a pinboard now opens that pinboard
- Larger, easier-to-hit menu and icon buttons throughout

### Fixed

- Cards highlight instantly on click (removed a delay caused by the double-click gesture)
- The installer's DMG background is lighter so its icon labels stay legible

## [0.1.0] - 2026-07-29

Initial release.

### Added

**The shelf**
- Menu bar app with a bottom shelf summoned by ⇧⌘V, showing clipboard history as cards
- Unlimited history with instant full-text search
- Scope chips to filter by type: All, Text, Images, Links, Files
- Space bar preview of the selected card
- Drag-out support to drop a card wherever you need it

**Organizing**
- Pinboards: tabs you can drag cards into, switched with ⌘1-9
- Multi-select for bulk actions
- Edit-in-place for text cards before pasting
- Link previews with page titles and favicons for copied URLs

**Pasting**
- Paste selected card (⏎) or paste as plain text (⌥⏎)
- Paste stack (⌃⌥⌘V) that walks its queue on successive plain ⌘V presses

**Privacy and settings**
- Per-app privacy exclusions
- Respect for the system concealed-type marker, so password managers and
  similar apps are never recorded
- Configurable history retention
- A Settings window for all of the above

**Onboarding and polish**
- First-run onboarding covering the Accessibility permission, the clipboard
  access permission on macOS 15.4+, and the global hotkey
- A permission banner in the shelf when Accessibility access is missing
- A native app icon
- Auto-updates via Sparkle
- Native design throughout: quiet cards, SF Mono for card bodies, no colored
  stripes
