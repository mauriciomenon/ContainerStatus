# Design: ContainerStatus - macOS menu bar app for the Apple container service

Date: 2026-09-12
Status: approved (autonomous mode; validated by a four-voice council)

## Goal

A native macOS Swift app that lives in the menu bar and:

1. Shows a live dot: green when the Apple container service is running, red when it is off.
2. On click, shows a menu with an on/off toggle for the service.
3. Is simple, elegant and stable. No root, no permission prompts, no user/group management.

## Verified environment facts

- macOS 27.0, Apple Silicon, Swift 6.4 via Command Line Tools (no Xcode; SPM works).
- `container` CLI v1.3.1 at `/usr/local/bin/container`.
- `container system status`: exit 0 = running, exit 1 = off. ~16 ms.
- `container system start`: ~0.4 s, normal user, no prompts. First-run kernel install
  prompt is interactive, so it needs a watchdog.
- `container system stop`: ~0.1 s, stops apiserver + machine-apiserver + core-images +
  vmnet (launchd labels `com.apple.container.*`, gui domain).

## Architecture (council verdict)

Pure AppKit, no windows, accessory app:

- `NSApplication` + `NSStatusItem`; `LSUIElement` in Info.plist (no Dock icon).
- Source of truth: exit code of `container system status` (canonical answer to
  "can I run containers"). `launchctl print` rejected (answers "is the launchd label
  alive", disagrees with reality when apiserver is wedged). MenuBarExtra/SwiftUI
  lifecycle rejected (more machinery, icon-refresh quirks, zero gain).

### State machine

```
notInstalled -> (recheck) -> stopped <-> transitioning <-> running
```

- `running`   green filled dot
- `stopped`   red filled dot
- `transitioning` last-state dot dimmed, menu shows "Alternando..."
- `notInstalled` gray hollow dot (CLI missing or spawn failed) - distinct from stopped

Poll writes are gated: the background poll never overwrites `transitioning`;
only the toggle completion (or its 10 s watchdog) advances out of it.

### Detection

- Serial background queue; `DispatchSourceTimer` every 3 s.
- Skip a tick if the previous check is still in flight (no stacking).
- Spawn `container system status` with a 2 s timeout; kill on timeout
  (timeout = treat as broken -> notInstalled).
- Absolute path resolved once at launch (checked in that order:
  `/usr/local/bin/container`, then `PATH` lookup fallback).
- Explicit environment: `PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`
  (Finder-launched apps inherit a minimal PATH).

### Toggle

- Menu item `Servico: Ligado/Desligado` with checkmark state.
- Click: enter `transitioning`, spawn `container system stop` or
  `container system start` with a 10 s watchdog, then re-poll.
- Start strategy (council synthesis of the flag debate): try plain
  `container system start` first (correct behavior, installs kernel when
  needed); on failure or watchdog timeout, retry once with
  `--disable-kernel-install`; if both fail, exit `transitioning`, show the
  captured stderr as a disabled error line in the menu, re-poll.
- While transitioning the toggle item is disabled. Concurrent toggles ignored.

### Menu layout

```
Apple Container         (disabled header; status text)
[x] Servico ligado      (or [ ] Servico desligado) - the toggle
---                     (only when an error exists)
<last error, disabled>  (one line, cleared on next successful op)
---
[x] Abrir no login      (SMAppService.mainApp, permission-free)
---
Sair
```

- `menuNeedsUpdate` triggers an immediate re-check when the menu opens.

### Error handling

- Every spawn: capture stdout+stderr, enforce timeout, kill on expiry.
- Exit 1 from `status` while the CLI is resolvable = stopped (normal).
- Spawn failure / timeout / unreadable binary = notInstalled (gray).
- Start/stop failure: stderr (first line) surfaces in the menu; state re-polls.

### Testing

- Unit-testable core: `ContainerCLI` maps (exitCode, timedOut) -> ServiceState.
- Manual validation: run toggle cycle start -> status -> stop -> status via the
  same wrapper code path the app uses, plus launch the .app via `open` and
  confirm the icon reacts.

## Packaging

- SPM executable target `ContainerStatus` (single module, 4 small files).
- `scripts/buildapp.sh` assembles `ContainerStatus.app`:
  `Contents/MacOS/ContainerStatus` binary, minimal `Info.plist`
  (`LSUIElement=true`, `LSMinimumSystemVersion=13.0`, bundle id
  `local.menon.ContainerStatus`), no code signing required for local run
  (ad-hoc sign if needed).
- Launch-at-login via `SMAppService.mainApp` (macOS 13+, no extra permissions).

## Non-goals

- Container listing/management, logs, notifications, Sparkle updates, i18n.
