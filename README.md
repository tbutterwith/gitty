# Gitty

Gitty is a focused macOS menu-bar app for keeping up with GitHub pull requests: your open PRs, requests for your review, CI health, and new feedback—without leaving the menu bar.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white)
![GitHub CLI](https://img.shields.io/badge/GitHub%20CLI-required-181717?logo=github)

## What it does

- Shows open pull requests you authored and pull requests awaiting your review.
- Summarises each PR’s CI state: passing, running, failing, or no checks.
- Highlights failed/cancelled CI, review requests, and new review feedback.
- Lets you acknowledge attention items; they return to their normal list and reappear only when something new changes.
- Lets you hide individual repositories or entire owner namespaces from Preferences.
- Refreshes on launch and every five minutes, with a manual refresh action.
- Opens PRs in your default browser. Click a PR to open and dismiss Gitty, or hold <kbd>⌘</kbd> to keep the menu open.
- Uses the locally installed `gh` CLI for every GitHub operation. Gitty never reads or stores a GitHub token.

## Requirements

- macOS 14 or later
- [GitHub CLI (`gh`)](https://cli.github.com/)
- An authenticated GitHub CLI session:

  ```bash
  gh auth login
  ```

Gitty looks for Homebrew and standard `gh` installations. If it cannot find one, its menu offers an **Install GitHub CLI** button.

## Run from source

```bash
git clone https://github.com/tbutterwith/gitty.git
cd gitty
swift run
```

`swift run` is useful for development. macOS notification permissions are intentionally unavailable in this unbundled mode.

## Build the app

Build a double-clickable app bundle with:

```bash
./Scripts/build-app.sh
open dist/Gitty.app
```

The script produces `dist/Gitty.app`, includes Gitty’s icon, and applies an ad-hoc signature for local use. Notifications are available from this bundled app.

## Development

```bash
swift test
```

## License

Gitty is released under the [MIT License](LICENSE).
