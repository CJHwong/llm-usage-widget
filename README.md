# LLM Usage Widget

A macOS menu-bar widget that shows Ollama and ChatGPT Codex usage at a glance. It reuses your browser's existing login session, so there's nothing extra to authenticate.

## Tutorial: first run

Requirements:

- macOS 15+, Swift 6 / Xcode 16+
- Zen or Firefox, signed into [ollama.com](https://ollama.com)

Build and run:

```bash
cd LLMUsageWidget
swift build
swift run
```

The widget appears in the top-right corner and refreshes every 5 minutes.

## How-to guides

### Run it at login

```bash
./install.sh
```

Builds a release binary and registers a LaunchAgent. Logs go to `/tmp/llm-widget.log`.
Stop with `launchctl bootout gui/$(id -u)/com.llmwidget`.

### Enable ChatGPT Codex usage

Needs `playwright-cli` and the Playwright Firefox bundle:

```bash
playwright-cli install-browser firefox
touch ~/.llm-usage-widget/include-chatgpt
```

Disable with `rm ~/.llm-usage-widget/include-chatgpt`.

## Reference

### Browser support

Firefox-family only. The app reads cookies from a Firefox `cookies.sqlite`, so support is limited to:

- Zen
- Firefox

Chrome, Safari, Arc, and Edge are **not** supported. You must be signed into the sites in one of the supported browsers.

### Data directory: `~/.llm-usage-widget/`

- `usage.json`: last scraped payload
- `include-chatgpt`: presence enables ChatGPT scraping

A legacy `~/.ollama-usage/` directory is migrated automatically on startup.

### Preflight checks

Before scraping, the app reports any of these in-window instead of showing "No data":

- no supported Zen/Firefox profile found
- missing `sqlite3` or `curl`
- ChatGPT enabled without `playwright-cli`
- ChatGPT enabled without the Playwright Firefox bundle

## Explanation: how it works

**Ollama:** reads session cookies from the browser profile and fetches `ollama.com/settings` with `curl`, then parses the usage meters out of the HTML.

**ChatGPT:** launches a Playwright Firefox session that reuses the browser's cookies, opens the Codex analytics page, and polls until it renders before parsing.

Both run locally. The only network traffic is the requests to ollama.com and chatgpt.com that your browser would make anyway.
