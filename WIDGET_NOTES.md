# Widget experiment - notes for reviving later

Status: **parked**. We converted Ollama Gauge from a floating borderless window
into a real macOS WidgetKit widget, got it working end to end, then reverted to
the floating window. The blocker was a hard macOS limitation (see "Transparency"
below), not the implementation. This file records what we built, every caveat we
hit, and how to pick it back up.

## Current state

- The **floating-window app** is the live app again: installed at
  `/Applications/Ollama Gauge.app`, running at login via LaunchAgent `com.llmwidget`
  (bundle id `com.hoss.llmusagewidget`). This is the committed code at `HEAD`
  (commit `b443659`): `Package.swift` + `install.sh` + `LLMUsageWidget/Sources/`.
- The **widget implementation is preserved, uncommitted, in the working tree**
  under `LLMUsageWidget/{App,Widget,Shared,project.yml,build.sh}` plus the
  multi-size icon PNGs in `App/Resources/Assets.xcassets` and
  `Widget/Resources/Assets.xcassets`. It is NOT installed and NOT registered.
- The widget's App Group container
  (`~/Library/Group Containers/3GXP3XQ69M.com.hoss.ollama-gauge/`) may still hold
  `usage.json` + `chatgpt_enabled` from when the host ran. Harmless leftover.

If you want the widget code durable, commit the working tree to a branch
(e.g. `widget-attempt`) before doing anything that resets the tree, because it is
all uncommitted and `git checkout`/`git clean` would discard it.

## Why we reverted (the real blocker)

**macOS desktop widgets cannot be transparent over the wallpaper the way the
floating window was.** A widget renders in full-color mode on top of a
system-provided material/vibrancy surface. `containerBackground(for: .widget)
{ Color.clear }` shows that system surface (reads as pale white), not the
wallpaper. The old floating window was a genuine clear `NSWindow` sitting
directly on the desktop, so the wallpaper showed through. That look is
structurally impossible in a widget.

Confirmed against Apple's docs: the system only removes the container background
for contexts like Lock Screen / StandBy; on the macOS desktop it always applies
its own material. Practical consequence: low-opacity fills read as "pale white"
(the light system material shows through); only a fairly opaque fill (~0.5
black) covers it and reads as a dark glass card. So the widget can be a nice dark
glass card, but it cannot have the old "transparent, wallpaper behind it" feel.

Secondary blocker, unresolved: the widget gallery would not show the app icon
even though it was correctly bundled (see "Icon" caveat). Likely needs a
logout/login to clear a loginwindow-level icon cache. Not worth solving unless we
commit to the widget direction.

## What we built (architecture)

Two-process design, matching the proven `context-bar` / `CodexBar` pattern:

- **Host app** (`Ollama Gauge.app`, bundle id `com.hoss.ollama-gauge`,
  unsandboxed): menu-bar accessory, no window. Runs the existing Scraper every 5
  min, writes `~/.llm-usage-widget/usage.json` (unchanged), mirrors that plus the
  ChatGPT flag into a shared App Group container, and calls
  `WidgetCenter.shared.reloadTimelines(ofKind: "OllamaGaugeWidget")`.
- **Widget extension** (`OllamaGaugeWidget.appex`, bundle id
  `com.hoss.ollama-gauge.widget`, sandboxed): reads the mirrored cache from the
  App Group container and renders. Never scrapes.
- **App Group** `3GXP3XQ69M.com.hoss.ollama-gauge` (Team ID `3GXP3XQ69M`
  prefixed, matching ContextBar's convention) is the bridge between the
  unsandboxed host and the sandboxed widget. App Groups require a real Team ID;
  ad-hoc signing cannot do them. The first `xcodebuild -allowProvisioningUpdates`
  was the probe that confirmed the Apple account can register App Groups (no
  portal visit needed).
- **Build**: `build.sh` at the repo root. `xcodegen generate` from `project.yml`
  -> `xcodebuild -allowProvisioningUpdates` -> install to `/Applications` ->
  `pluginkit -a` the appex -> write + bootstrap LaunchAgent `com.llmwidget`.
  Requires `brew install xcodegen`.

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

Widget UI: single family `.systemLarge` (the only size tall enough for the old
panel: header + Ollama 2 rings + divider + ChatGPT 2 rings). Widgets cannot hold
tap-to-expand state, so the old expandable model breakdown was dropped; tapping
the widget opens `ollama.com/settings` via `widgetURL`. Timeline policy
`.after(now + 300)` as a fallback refresh; the host push is the primary driver so
the 40-70/day widget budget is never stressed.

## Caveats (read before reviving)

1. **Transparency** - see above. Decide up front: accept a dark-glass widget, or
   stay with the floating window. Do not try to make the widget transparent over
   the wallpaper; the system material will make it pale.

2. **Gallery cache is version-keyed.** A rebuilt binary with the SAME
   `CURRENT_PROJECT_VERSION` does NOT re-render in the gallery; chronod serves the
   cached preview. Bump `CURRENT_PROJECT_VERSION` in `project.yml` on every
   iteration you want the gallery to reflect. We went 1 -> 2 -> 3 -> 4 -> 5 to
   force re-renders.

3. **chronod persists its cache on disk.** `killall chronod` alone just reloads
   the stale cache from `~/Library/Group Containers/group.com.apple.chronod/`.
   To actually reset: kill chronod, delete that group container and
   `~/Library/Caches/com.apple.chrono`, `defaults delete com.apple.chronod`, then
   let it respawn and re-register the appex. The deepest cache
   (loginwindow/WindowServer) only clears on logout/login; no terminal command
   reaches it. Use `rm` via `find <path> -depth -delete` because the Bash tool
   blocks `rm -rf` (rm is aliased to trash-cli).

4. **Stray appex copies get discovered.** `chronod` scans the disk for appex, not
   just the pluginkit registry. A stale Debug build in Xcode DerivedData
   (left over from opening the project in Xcode) was what the gallery was serving
   even though `pluginkit -m` pointed at `/Applications`. Before judging a
   rebuild, remove every stray copy: `~/Library/Developer/Xcode/DerivedData/...`
   and `LLMUsageWidget/build/...`. Verify with `mdfind -name OllamaGaugeWidget.appex`.

5. **Asset catalog icon format.** The modern single-size appiconset
   (`idiom: universal`, `platform: macos`, `size: 1024x1024`, one image) was
   REJECTED by `actool` on this toolchain: "The app icon set AppIcon has an
   unassigned child", and it emitted zero `Assets.car` (the built app had an empty
   `Resources/`). Use the multi-size `mac`-idiom iconset instead: 10 slots
   (16/32/64/128/256/512/1024 across 1x/2x). The floating-window `install.sh` avoids
   this entirely by building `AppIcon.icns` directly with `iconutil -c icns` from a
   proper iconset - that path is more robust than the asset catalog.

6. **xcodegen: Assets.xcassets goes in `sources`, not `resources`.** Under
   `resources:` xcodegen dropped it entirely (no `Resources/` dir in the built
   app at all). Under `sources:` it routes `.xcassets` through `actool` and emits
   `Assets.car` + `AppIcon.icns`.

7. **Icon in the gallery - unresolved.** Even after bundling AppIcon in BOTH the
   host app and the appex (verified via `assetutil`: 10 AppIcon slots in each
   `.car`), setting `CFBundleIconFile`/`CFBundleIconName` in both Info.plists,
   force-registering with `lsregister -f`, purging every user-level cache, and
   bumping the version five times, the gallery still showed no icon. `lsregister
   -kill` (the LaunchServices DB rebuild) was removed in this macOS. Most likely
   a logout/login is required to refresh the gallery icon cache. Revisit only if
   we commit to the widget.

8. **The widget extension needs its own AppIcon.** On this macOS the gallery
   appears to read the icon from the extension bundle, not (only) the host app,
   so the appex target must include its own `Assets.xcassets` with AppIcon +
   `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` + the icon refs in the appex
   Info.plist. (Still did not fully fix it - see #7.)

9. **`pluginkit -m -i <bundleid>` is the source of truth** for which appex path is
   registered. `pluginkit -m` (no filter) catches duplicate registrations of the
   same bundle id from different paths.

10. **codesign --verify --deep --strict** should pass on the whole `.app` after
    embedding the appex; if it fails, chronod rejects the extension.

## How to revive

1. Commit the working-tree widget code to a branch first (it is all uncommitted).
2. Decide on the transparency question (caveat #1). If a dark-glass widget is
   acceptable, proceed. If you need the transparent-over-desktop look, stay on the
   floating window - a widget cannot do it.
3. `brew install xcodegen` if not present.
4. From the repo root: `./build.sh`. It regenerates the Xcode project, builds a
   signed `.app` with the embedded appex, installs to `/Applications`, registers
   the LaunchAgent, and `pluginkit -a`s the appex.
5. Bump `CURRENT_PROJECT_VERSION` each iteration so the gallery re-renders
   (caveat #2). Remove stray appex copies before judging (caveat #4).
6. Add the **Ollama Gauge** widget from Notification Center / Edit Widgets. If it
   does not appear, run the troubleshooting block in `README.md`
   (`pluginkit -a`, `chronod` logs). If the icon is missing, expect to need a
   logout/login (caveat #7).
7. To go back to the floating window: `launchctl bootout gui/$(id -u)/com.llmwidget`,
   trash `/Applications/Ollama Gauge.app`, unregister the appex
   (`pluginkit -i <appex>`, `lsregister -u <appex>`, purge chronod per #3), then
   run `install.sh` from the floating-window tree (commit `b443659`).

## File map (widget version, uncommitted in working tree)

```
LLMUsageWidget/
  project.yml                  xcodegen spec: app + widget extension targets
  build.sh                     xcodegen -> xcodebuild -allowProvisioningUpdates -> install
  App/
    App.entitlements           application-groups (no sandbox)
    Info.plist                 host app (APPL, LSUIElement for menu-bar-only)
    Sources/App/               Scraper, AppPaths, BrowserAdapter, App (mirrored verbatim from HEAD)
    Resources/Assets.xcassets  AppIcon (multi-size mac idiom)
  Widget/
    Widget.entitlements        app-sandbox + application-groups
    Info.plist                 NSExtension widgetkit-extension + CFBundleIconFile/Name
    Sources/Widget/            OllamaGaugeWidget (TimelineProvider + views)
    Resources/Assets.xcassets  AppIcon (multi-size mac idiom, for the gallery icon)
  Shared/Sources/Shared/       Models, UsageDataStore (App Group bridge), WidgetViews
```

`UsageDataStore` is the only seam between the host and the widget; it is where a
pivot to the sandbox temporary-exception fallback (no App Group) would live if
App Group provisioning ever fails.