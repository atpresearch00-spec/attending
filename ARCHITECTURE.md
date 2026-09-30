# Architecture

Attending is a native macOS app built with Swift Package Manager: SwiftUI views inside an
AppKit `NSPanel` that sits over the notch, plus a menu bar item. It is an accessory app
(no Dock icon) and does its work locally.

## Targets

| Target | Role |
|---|---|
| `Attending` | The app: panel and animation, the views, and the services (media, calendar, study, Salah, camera, shelf and more). |
| `AttendingCore` | Portable logic with no UI: agent session models and persistence, the approval broker, the Codex app-server transport, notch geometry, and prayer-time calculation. |
| `AttendingBridge` (`attending-bridge`) | A small command-line tool that Claude Code hooks call. It writes sanitized lifecycle events to the app's inbox, relays permission requests over a private Unix socket, and records plan usage from the status line. |
| `AttendingMedia` | A tiny Objective-C library that streams Now Playing information. macOS only gives MediaRemote data to Apple-signed processes, so it runs inside `/usr/bin/perl` and reports JSON over a pipe. |
| `AttendingCoreChecks` | Test runner for `AttendingCore` (Command Line Tools ship without XCTest). |

## Principles

- **Local first.** Metadata is stored as atomic JSON in `~/Library/Application Support/Attending` with 0600 permissions. There are no servers or analytics.
- **Nothing runs while idle.** Work is driven by events (file-system events, EventKit, IOKit power, Core Audio, distributed notifications) instead of polling. The audio visualizer runs only while music plays; the camera only while its tab is open.
- **Real notch geometry.** The panel is placed from `NSScreen.auxiliaryTopLeftArea` and `auxiliaryTopRightArea` rather than hardware model lists.
- **Smooth animation without resizing the window.** The window grows to the union of the old and new island frames, SwiftUI springs the island inside it, and then the window settles. Window frames are never animated.
- **Agents stay in charge of permissions.** Observing a session never grants permission to answer for it. Approvals are allow-once or deny, and timeouts fall back to the agent's own prompt.

## Scripts

| Script | Purpose |
|---|---|
| `scripts/build-app.sh [release]` | Builds `build/Attending.app` and signs it. |
| `scripts/install-app.sh` | Copies the app to `/Applications`, keeping the previous version as a backup. |
| `scripts/test.sh` | Core checks plus Python tests for the bridge, approvals and Codex transport. |
| `scripts/create-signing-identity.sh` | Creates a local code-signing identity so macOS permissions survive rebuilds. |
| `scripts/install-claude-hooks.py` | Merges Attending's hooks into Claude Code settings, with a dry run first and a backup. |
| `scripts/release.sh` | Builds a release zip (see [docs/releasing.md](docs/releasing.md)). |

Provider protocol notes are in [docs/integrations.md](docs/integrations.md).
