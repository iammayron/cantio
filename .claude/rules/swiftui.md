---
description: SwiftUI idioms for Cantio. Loaded when editing files matching `Cantio/**/*.swift` that use SwiftUI views.
globs: Cantio/**/*.swift
---

# SwiftUI rules — Cantio

## State ownership

- `@StateObject` for owning a reference type's lifecycle. Initialize in the view that creates it.
- `@ObservedObject` when receiving an already-owned object.
- `@EnvironmentObject` only for app-wide singletons (`Preferences.shared`).
- Never `@State` for ref types.
- Never instantiate `@StateObject` with `=` to a fresh value at top of `body` — use the `init` form or `@StateObject private var x = X()`.

## View modifiers

- Order matters. Conventional order: layout → padding → background/foreground → clipShape → overlay → shadow → animation → transition.
- `.frame(maxWidth: .infinity)` only when intentional. Avoid stacking with explicit width.
- `.fixedSize(horizontal: false, vertical: true)` for text that should wrap, not truncate.
- Use `.contentShape(Rectangle())` before `.onTapGesture` on transparent regions.

## Animations

- Default animation token: `.spring(response: 0.32, dampingFraction: 0.88)`.
- For property changes: `.easeOut(duration: 0.22)`.
- Lyric line transitions: short asymmetric crossfade (≤4pt slide), see `LyricsContentView.syncedRender`.
- Honor `@Environment(\.accessibilityReduceMotion)` — disable transitions, keep crossfade.
- Never animate longer than 0.4s for routine state changes.

## Backgrounds

- Never hand-roll blur. macOS 26+: `.glassEffect(.regular, in:)`. macOS 14–15 fallback: `NSVisualEffectView` via `VisualEffectBackground`. Deployment target is 14.0 — both branches ship, gate with `if #available(macOS 26, *)`.
- Glass is navigation-layer only: panels, pills, floating chrome. Never on lyric lines, list rows, or anything inside a scroll view. Never glass on glass — it cannot sample itself and degrades to flat tint.
- For materials over transparent windows, host window MUST be `isOpaque = false` + `backgroundColor = .clear`.
- Apply `.clipShape(...)` AFTER `.background(...)` to clip the material.
- For `MenuBarExtra(.window)` panels: use the `WindowTransparencyApplier` pattern in `MenuBarPanel.swift` — re-apply across runloop ticks.

## Colors

- All colors derive from `FL.Palette`. Never inline `Color(red:green:blue:)` in views — only inside palette definitions or one-off documented exceptions.
- Both light + dark variants tested before commit.

## Layout

- 8pt grid. Padding multiples of 4 (8/12/16/20/24).
- Min hit target 28pt; 44pt for primary actions.
- Window corner radius 12pt; capsule for pill shapes.

## Anti-patterns

- `GeometryReader` deep in view tree → use `.frame` and `.fixedSize` first.
- `AnyView` to bridge conditionals → use `Group` or `@ViewBuilder`.
- `.onAppear { Task { ... } }` for async setup → use `.task { ... }` (auto-cancels).
- `EmptyView()` returns from conditional → use `if`/`else` inside `@ViewBuilder`.
- Animating `id`-driven transitions without explicit `.transition(...)` — silent jump.
