---
description: AppKit + NSWindow rules for Cantio. Loaded when editing files involving NSWindow, NSPanel, NSEvent, NSApplication, or NSViewRepresentable bridges.
globs: Cantio/Window/**/*.swift, Cantio/MenuBarPanel.swift, Cantio/CantioApp.swift, Cantio/Hotkey/**/*.swift
---

# AppKit rules — Cantio

## NSWindow

- Floating panel: `styleMask = [.borderless, .resizable, .fullSizeContentView]`, `level = .floating`, `collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]`.
- `isOpaque = false`, `backgroundColor = .clear` when SwiftUI `VisualEffectBackground` is the visible bg.
- `hasShadow`:
  - `false` for pill / fullscreen (custom silhouette).
  - `true` for minimal (rectangular chrome).
  - Always `invalidateShadow()` after toggling.
- `isMovableByWindowBackground = true` for grab-anywhere drag.
- `hidesOnDeactivate = false` for utility-style persistence.
- `setFrameAutosaveName(...)` for position persistence.
- Borderless windows: override `canBecomeKey` → `true` if you need keyboard focus; `canBecomeMain` → `false` for floating utilities.

## MenuBarExtra

- `MenuBarExtra(.window)` for custom UI; `.menu` for native list.
- Custom `.window` panels need `WindowTransparencyApplier` (see `MenuBarPanel.swift`) — SwiftUI re-installs opaque backing across ticks; retry across multiple `DispatchQueue.main.asyncAfter` delays.
- Clear every NSView ancestor layer + contentView.

## NSApplication

- `LSUIElement = true` in `Info.plist` for menu-bar-only app.
- Settings window: flip `NSApp.setActivationPolicy(.regular)` on appear (joins cmd-tab + Dock); back to `.accessory` on disappear.
- `NSApp.activate(ignoringOtherApps: true)` after policy flip.
- `applicationDidFinishLaunching` for one-time bootstrap, NOT inside `MenuBarPanel.onAppear` (that fires only when menu opens).

## NSEvent monitors

- `addLocalMonitorForEvents` for events targeting your windows; return `nil` to consume, return `event` to pass through.
- `addGlobalMonitorForEvents` for events outside your app — never returns the event.
- Pair both when needed (e.g., mouse passthrough hit-test).
- Always retain the returned token; remove with `NSEvent.removeMonitor(...)` on teardown.

## Carbon hot-keys

- Use `RegisterEventHotKey` + `EventHotKeyID`. Single shared `EventHandler`.
- Modifiers via `cmdKey | optionKey | shiftKey | controlKey` constants.
- Translate keyCode ↔ display string via `UCKeyTranslate` with current keyboard layout.

## NSViewRepresentable

- `makeNSView` runs once. `updateNSView` runs on every state change — keep it idempotent and cheap.
- `DispatchQueue.main.async` for window-traversal work that must happen after view installation.
- Layer-backed views: set `wantsLayer = true` first, then `layer?.backgroundColor`.

## Anti-patterns

- Setting `window.backgroundColor` to a translucent color (use the SwiftUI background instead).
- Calling `window.makeKey()` in viewWillLayout / updateNSView — recursion risk.
- Forgetting `invalidateShadow()` after `hasShadow` toggle — stale shadow.
- Holding NSView strongly inside NSEvent monitor closure — leak.
- `NSApp.terminate(nil)` from anywhere except the explicit Quit menu — bypasses cleanup.
