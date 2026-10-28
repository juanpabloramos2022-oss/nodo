# AGENTS.md — Nodo

Nodo is an iOS app for chatting with AI models using the user's own API keys, from the phone, without needing a computer switched on. Current release line: v0.3.2 (build 6), minimum iOS 17.0, bundle id `com.nodo.ios`.

## Stack and layout

- Swift 5, SwiftUI, iOS 17+. The Xcode project is generated, not versioned: `project.yml` (XcodeGen) produces `Nodo.xcodeproj` and `Nodo/Info.plist`, both gitignored on purpose.
- `Nodo/` — the app: `NodoApp.swift` entry point, `Views/` screens, `Support/` (Keychain, networking, theme), `Assets.xcassets` icon.
- `NodoCore/` — the pure-logic core, Foundation only, no UIKit, no SwiftUI. `Package.swift` defines it as a local Swift package, so the same code runs under `swift test` and inside the app, with no copy.
- `NodoAppTests/` — app unit tests, hosted by the app in the simulator.
- `NodoCapturas/` — UI-test target that launches the app in the simulator and attaches one PNG per capture.
- `herramientas/` — helper scripts (icon generation, trace/capture extraction, closing-version check).
- `docs/VPS.md` — how to set up an optional own MCP server.
- `.github/workflows/ios.yml` — CI on macOS 15.

## Read these before changing behaviour or UI

- `SPEC.md` — master product specification.
- `CONTRATO-DISENO.md` — design contract, the product's laws.
- `UI_INVARIANTS.md` — presentation invariants for the thread, treated as immutable.
- `LEEME.md` — what the app does, how to build, test and install it.

If code and one of these documents disagree, flag the mismatch instead of silently picking a side.

## Build, test, CI

- Core tests, no simulator needed, on any machine with Swift:
  ```bash
  swift test
  ```
- Full app tests and build need macOS + Xcode. Generate the project first, then test the `Nodo` scheme on an iPhone 16 simulator, or the `Capturas` scheme for capture-only runs:
  ```bash
  brew install xcodegen
  xcodegen generate
  xcodebuild test -project Nodo.xcodeproj -scheme Nodo \
    -destination 'platform=iOS Simulator,name=iPhone 16' \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
  ```
- CI (`.github/workflows/ios.yml`) has three jobs: `tests` (core + app tests, for commits marked `[solo-tests]`), `compilar` (tests + unsigned build + `Nodo.ipa` artifact), and `capturas` (simulator captures). A failing test stops the build; never publish a binary from a red run.
- The `.ipa` produced by CI is UNSIGNED by design. Signing happens outside GitHub, by whoever installs it, with their own certificate (ESign on iPhone). Never add signing certificates, provisioning profiles, or private keys to this repo.

## Hard rules

- API keys live only in the phone's Keychain (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`). Never put a key, secret, certificate, or personal data in code, configuration, logs, tests, or captures.
- This repo contains zero personal data, no analytics, no telemetry, and no third-party services. Keep it that way.
- No analytics, no push notifications, no iCloud, no app groups — deliberately, so signing stays trivial.
- iOS limits are not app bugs: an app cannot edit files, run commands, or run background processes outside its sandbox. Agents that do things need an external machine; Nodo talks to that machine over MCP when one exists, it does not replace it.
- Version and bundle id live in `project.yml`. Keep `MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`, and the closing-version check (`herramientas/verificar-cierre.py`) consistent.
- Work on a branch and open a pull request. Never push directly to `main`, never merge your own pull request, and never merge a branch whose CI is red.
- Small, reviewable changes beat large rewrites. Keep tests passing, add or update a test for behaviour you change, and explain the why in the PR, not just the what.
