# LLM Usage Widget

macOS desktop app that shows Ollama and ChatGPT Codex usage at a glance.

## Requirements

- macOS 15+
- Swift 6 / Xcode 16+
- `playwright-cli`
- Playwright Firefox browser bundle for ChatGPT scraping:

```bash
/opt/homebrew/bin/playwright-cli install-browser firefox
```

- Zen or Firefox, signed into the sites you want to monitor

## Build

```bash
cd LLMUsageWidget
swift build
swift run
```

## Data Directory

The app stores runtime files in `~/.llm-usage-widget/`:

- `usage.json`: last scraped usage payload
- `include-chatgpt`: enables ChatGPT scraping when present

If you previously used `~/.ollama-usage/`, the app migrates that directory automatically on startup.

## Enable ChatGPT

```bash
touch ~/.llm-usage-widget/include-chatgpt
```

To disable it:

```bash
rm ~/.llm-usage-widget/include-chatgpt
```

## Browser Support

Current support is Firefox-family only:

- Zen
- Firefox

The app:

1. Finds the first supported Firefox-family profile with cookies
2. Reads Ollama cookies from `cookies.sqlite`
3. Launches a Playwright Firefox session for ChatGPT analytics when enabled
4. Polls until the ChatGPT page is actually ready instead of waiting a fixed delay

## Preflight

Before scraping, the app checks for the main failure conditions:

- supported Zen/Firefox profile not found
- missing `sqlite3` or `curl`
- ChatGPT enabled without `playwright-cli`
- ChatGPT enabled without the Playwright Firefox browser installed

If no usage data is available yet, these issues are shown in the app instead of a generic "No data."

## Project Structure

```text
llm-usage-widget/
├── README.md
└── LLMUsageWidget/
    ├── Package.swift
    └── Sources/LLMUsageWidget/
        ├── App.swift
        ├── AppPaths.swift
        ├── BrowserAdapter.swift
        ├── Models.swift
        ├── Scraper.swift
        ├── Views.swift
        └── Window.swift
```