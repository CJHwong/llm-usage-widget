# Widget - architecture and gotchas

Ollama Gauge is a real macOS WidgetKit widget (on the `widget-attempt` branch),
replacing the old floating borderless window. This file records how it's built,
the macOS constraints that shaped the design, and every caveat hit along the way.

## Why it's an opaque dark panel (not transparent)

macOS desktop widgets **cannot be transparent over the wallpaper**. A widget
renders in full-color mode on top of a system-provided material/vibrancy surface.
`containerBackground(for: .widget) { Color.clear }` shows that system surface
(reads as pale white), not the wallpaper. The old floating window was a genuine
clear `NSWindow` sitting directly on the desktop, so the wallpaper showed through;
that look is structurally impossible in a widget.

So the **widget** is an **opaque dark command-bar surface** (`GlassPanelBackground`):
a near-black slate fill with a hairline border and a faint top lift. That's the
right call precisely because the widget can't be transparent anyway, so there's
nothing to gain from a low-opacity fill (which only reads as pale white).

The **floating desktop panel** is the other half of the answer: it's a genuine
clear `NSWindow` the host draws (`DesktopPanel`), so it *can* be transparent over
the wallpaper. That's why both exist - the widget for Notification Center, the
panel for an always-on-desktop glanceable with the transparent look.

Secondary gotcha seen earlier, may resurface: the widget gallery would not show
the app icon even though it was correctly bundled (see "Icon" caveat). Likely a
loginwindow-level icon cache that only a logout/login clears.

## Architecture

Two-process design, matching the proven `context-bar` / `CodexBar` pattern:

- **Host app** (`Ollama Gauge.app`, bundle id `com.hoss.ollama-gauge`,
  unsandboxed): menu-bar accessory. Runs the Scraper every 5 min, writes
  `usage.json` into the shared App Group container, and calls
  `WidgetCenter.shared.reloadAllTimelines()`. It also draws the floating desktop
  panel (`DesktopPanel`, an imperatively-created clear `NSWindow` in
  `App.swift`) and owns the two menu-bar toggles. `AppDelegate` is `@MainActor`
  so the load() Task inherits the main actor and can update the panel's
  `PanelModel` without hopping off it.
- **Widget extension** (`OllamaGaugeWidget.appex`, bundle id
  `com.hoss.ollama-gauge.widget`, sandboxed): reads the container and renders.
  Never scrapes.
- **App Group** `3GXP3XQ69M.com.hoss.ollama-gauge` (Team ID `3GXP3XQ69M`
  prefixed) is the **single store** and the bridge between the unsandboxed host
  and the sandboxed widget. Everything lives there (`usage.json`,
  `instance.lock`): no home directory, no mirroring. App Groups require a real
  Team ID; ad-hoc signing cannot do them.
- **Build**: `build.sh` at the repo root. `xcodegen generate` from `project.yml`
  -> `xcodebuild -allowProvisioningUpdates` -> install to `/Applications` ->
  `pluginkit -a` the appex -> write + bootstrap LaunchAgent `com.llmwidget` ->
  `killall OllamaGaugeWidget chronod NotificationCenter` so the freshly installed
  extension actually renders (see caveat #3). Requires `brew install xcodegen`.

### Two widgets

The widget surface is a `WidgetBundle` with two widgets:

- **"Ollama"** - `.systemMedium`, Ollama only.
- **"Ollama + ChatGPT"** - `.systemLarge`, both providers.

The family added in Notification Center decides both what's shown and its size,
so the frame always matches the content (a widget can't resize its own height).

### ChatGPT control

ChatGPT scraping is expensive (Playwright + Firefox), so it's gated on a single
master switch: the **Enable ChatGPT** menu-bar item, persisted in the host's
`UserDefaults` (`chatGPTEnabledKey`). The host scrapes ChatGPT only when it's on.

The sandboxed widget can't read host `UserDefaults`, so the host computes a
derived `ChatGPTStatus` (`on` / `off` / `unavailable`) and writes it into
`usage.json` (`chatgpt_status`). All three surfaces read that one status:

- desktop panel: shows the ChatGPT section only when `on`, else hides it (reflows);
- large widget: `on` -> gauges, `off` -> "ChatGPT off", `unavailable` -> "Sign in to ChatGPT";
- `unavailable` = enabled but no data (not signed in / scrape failing).

(Earlier iterations gated on a `chatgpt_enabled` container file and then on
`WidgetCenter.getCurrentConfigurations`; the menu toggle replaced both as a
clearer master control.)

Entitlements:
- Host: `com.apple.security.application-groups` only. NO app-sandbox (Playwright
  subprocess + browser cookies cannot run sandboxed).
- Widget: `com.apple.security.app-sandbox` = true AND
  `com.apple.security.application-groups`. BOTH are required or `chronod`
  silently rejects the extension from the gallery (the CodexBar #1173 bug).

Swift 6 strict-concurrency fixes that were needed:
- Timer: a `@Sendable` closure timer captured non-Sendable self. Use
  `Timer(timeInterval:target:selector:repeats:)` + `RunLoop.main.add(..., .common)`
  with an `@objc func loadTick()` instead.
- Task: `Task { ... self.scraper ... }` captured self. Capture a local
  `let scraper = self.scraper` before the Task.

Widget UI: shared SwiftUI primitives (`RingView`, `UsageCard`, `ProviderColumn`)
drive both families; the ring size is passed per family (66pt large, 54pt
medium). Widgets cannot hold tap-to-expand state, so the old expandable model
breakdown was dropped; tapping opens `ollama.com/settings` via `widgetURL`.
Timeline policy `.after(now + 300)` is a fallback refresh; the host push is the
primary driver, so the 40-70/day widget budget is never stressed.

## Caveats (read before iterating)

1. **Transparency** - see above. The widget is a dark-glass surface, not
   transparent over the wallpaper. Do not try to make it transparent; the system
   material will make it pale.

2. **Gallery cache is version-keyed.** A rebuilt binary with the SAME
   `CURRENT_PROJECT_VERSION` does NOT re-render in the *gallery*; chronod serves
   the cached preview. Bump `CURRENT_PROJECT_VERSION` in `project.yml` when you
   want the gallery preview to reflect a change. (The *installed, placed* widget
   reloads via the build.sh killall step regardless.)

3. **chronod persists its cache on disk.** `killall chronod` alone just reloads
   the stale cache from `~/Library/Group Containers/group.com.apple.chronod/`.
   `build.sh` now does `killall OllamaGaugeWidget chronod NotificationCenter`
   after install, which is enough to reload a placed widget's code. For a full
   reset (rarely needed): kill chronod, delete that group container and
   `~/Library/Caches/com.apple.chrono`, `defaults delete com.apple.chronod`, then
   let it respawn. The deepest cache (loginwindow/WindowServer) only clears on
   logout/login. Use `find <path> -depth -delete` because the Bash tool blocks
   `rm -rf` (rm is aliased to trash-cli).

4. **Stray appex copies get discovered.** `chronod` scans the disk for appex, not
   just the pluginkit registry. A stale Debug build in Xcode DerivedData was what
   the gallery served even though `pluginkit -m` pointed at `/Applications`.
   Before judging a rebuild, remove every stray copy:
   `~/Library/Developer/Xcode/DerivedData/...` and `LLMUsageWidget/build/...`.
   Verify with `mdfind -name OllamaGaugeWidget.appex`.

5. **Asset catalog icon format.** The modern single-size appiconset
   (`idiom: universal`, `platform: macos`, `size: 1024x1024`, one image) was
   REJECTED by `actool` on this toolchain: "The app icon set AppIcon has an
   unassigned child", and it emitted zero `Assets.car`. Use the multi-size
   `mac`-idiom iconset instead: 10 slots (16/32/64/128/256/512/1024 across 1x/2x).

6. **xcodegen: Assets.xcassets goes in `sources`, not `resources`.** Under
   `resources:` xcodegen dropped it entirely (no `Resources/` dir in the built
   app). Under `sources:` it routes `.xcassets` through `actool` and emits
   `Assets.car` + `AppIcon.icns`.

7. **Icon in the gallery - unresolved.** Even after bundling AppIcon in BOTH the
   host app and the appex, setting `CFBundleIconFile`/`CFBundleIconName` in both
   Info.plists, force-registering with `lsregister -f`, purging caches, and
   bumping the version, the gallery still showed no icon. `lsregister -kill` was
   removed in this macOS. Most likely a logout/login is required.

8. **The widget extension needs its own AppIcon.** On this macOS the gallery
   appears to read the icon from the extension bundle, not (only) the host app,
   so the appex target must include its own `Assets.xcassets` with AppIcon +
   `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` + the icon refs in the appex
   Info.plist. (Still did not fully fix it - see #7.)

9. **`pluginkit -m -i <bundleid>` is the source of truth** for which appex path
   is registered. `pluginkit -m` (no filter) catches duplicate registrations of
   the same bundle id from different paths.

10. **codesign --verify --deep --strict** should pass on the whole `.app` after
    embedding the appex; if it fails, chronod rejects the extension.

## How to build / iterate

1. `brew install xcodegen` if not present.
2. From the repo root: `./build.sh`. It regenerates the Xcode project, builds a
   signed `.app` with the embedded appex, installs to `/Applications`, registers
   the LaunchAgent, `pluginkit -a`s the appex, and reloads the extension so the
   change shows up.
3. Bump `CURRENT_PROJECT_VERSION` in `project.yml` if you need the *gallery
   preview* to re-render (caveat #2). Remove stray appex copies before judging
   (caveat #4).
4. Add the **Ollama** or **Ollama + ChatGPT** widget from Notification Center /
   Edit Widgets. If a widget does not appear, run the troubleshooting block in
   `README.md` (`pluginkit -a`, `chronod` logs). If the icon is missing, expect
   to need a logout/login (caveat #7).

## File map

```
LLMUsageWidget/
  project.yml                  xcodegen spec: app + widget extension targets
  build.sh                     xcodegen -> xcodebuild -> install -> reload
  App/
    App.entitlements           application-groups (no sandbox)
    Info.plist                 host app (APPL, LSUIElement for menu-bar-only)
    Sources/App/               Scraper, AppPaths, BrowserAdapter, App (menu + window),
                               DesktopPanel (floating panel + PanelModel)
    Resources/Assets.xcassets  AppIcon (multi-size mac idiom)
  Widget/
    Widget.entitlements        app-sandbox + application-groups
    Info.plist                 NSExtension widgetkit-extension + CFBundleIconFile/Name
    Sources/Widget/            OllamaGaugeWidget (WidgetBundle: two widgets + provider)
    Resources/Assets.xcassets  AppIcon (multi-size mac idiom, for the gallery icon)
  Shared/Sources/Shared/       Models, UsageDataStore (App Group store), WidgetViews
```

`UsageDataStore` is the only seam between the host and the widget; it owns the
App Group container paths and the shared `WidgetKinds`.
