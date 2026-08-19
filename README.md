# DevNotch

**DevNotch** is a lightweight macOS menu-bar app that turns your notch (or the top of the screen on Macs without one) into a live Git status panel — visible only while you're working in Xcode or Terminal.

On top of that, it ships a built-in AI assistant (powered by local [Ollama](https://ollama.com)) that generates Conventional Commits-style commit messages and release notes when tagging a new version — everything runs locally, no code ever leaves your machine.

![platform](https://img.shields.io/badge/platform-macOS-black)
![swift](https://img.shields.io/badge/Swift-5-orange)
![license](https://img.shields.io/badge/license-All%20rights%20reserved-lightgrey)

---

## ✨ Features

- **Live Git status in the notch** — branch, staged/modified/untracked/conflicted file counts, last commit, last tag.
- **Automatic active-repo detection** — DevNotch figures out whether you're working in Xcode or Terminal and resolves the repository path on its own (via AppleScript for Xcode, via the process tree for Terminal).
- **Remote branch awareness** — shows recent activity on other branches and flags file collisions (when you and someone else are editing the same files on different branches).
- **Two display styles**: "Hug the notch" (flush with the physical notch) or "Floating island" (a rounded pill under the menu bar) — with automatic detection of whether the Mac has a notch at all.
- **AI commit assistant (Ollama)** — reads `git diff --staged` and drafts a ready-to-use commit message following Conventional Commits (type, scope, summary, body, breaking change).
- **AI tagging / release notes assistant** — analyzes commits since the last tag, suggests a semver bump (major/minor/patch), and generates categorized release notes ready to ship as an annotated Git tag.
- **Ollama auto-start** — optionally launches `ollama serve` in the background when needed, and cleans up after itself once the popover closes.
- **Version derived from Git tags** — an Xcode build phase automatically sets `CFBundleShortVersionString` from the latest tag.

## 🧩 Requirements

- macOS 26.5+ (Tahoe) — per `MACOSX_DEPLOYMENT_TARGET` in the project
- Xcode 26.6+ to build
- [Ollama](https://ollama.com) installed locally (optional, but crucial — only needed for the AI features)
  - default model: `qwen2.5-coder:7b` (configurable in Settings)

## 🚀 Installation

### From source

```bash
git clone https://github.com/oblivi0n-arch/DevNotch.git
cd DevNotch
open DevNotch.xcodeproj
```

Build and run (`⌘R`) in Xcode. The app runs as an `LSUIElement` (no Dock icon) — access it through the menu bar icon.

### First run

1. Click the DevNotch menu bar icon to open the commit assistant.
2. Right-click the icon to open **Settings** and configure:
   - display style (notch / floating island / automatic),
   - position (left / center / right),
   - whether the overlay should only show while Xcode/Terminal is active.

## ⚙️ Ollama configuration

DevNotch looks for the Ollama binary in:

```
/opt/homebrew/bin/ollama
/usr/local/bin/ollama
/Applications/Ollama.app/Contents/Resources/ollama
```

You can also set a custom path, change the host (defaults to `http://localhost:11434`), and pick a model via `UserDefaults` (keys: `ollamaExecutablePath`, `ollamaHost`, `ollamaModel`, `autoStartOllama`).

## 🏗️ Architecture

```
DevNotch/
├── App/              # Entry point, AppDelegate (status item, popover, overlay window)
├── Models/           # AppearanceSettings, GeneratedDrafts (commit/tag draft parsing)
├── Services/         # GitStatusService, AppModeService, OllamaClient, OllamaLauncher
├── Utilities/        # PointerTracker, ProcessInspector
├── Views/            # NotchContentView, OllamaChatView, SettingsView, AboutView, SplashView
```

A few technical notes:

- Repo status refreshes reactively via **FSEvents** watching the `.git` directory, so there's no polling on every file change.
- Terminal repo detection reads the active shell process's working directory directly (`proc_pidinfo` / `PROC_PIDVNODEPATHINFO`) rather than relying on AppleScript.
- Remote branch fetching (`git fetch --prune`) runs periodically in the background (every 180s) on a dedicated queue, with a watchdog to enforce a timeout.
- The semver bump for tagging is computed from Conventional Commits prefixes — the AI model does **not** decide the version, only the wording of the release notes.

## 📄 License

This repository is source-available, not open source: no license is granted. All rights reserved.

You're welcome to read the code, fork it for personal reference, and open pull requests. Redistribution, commercial use, or shipping a product based on this code is not permitted without prior written permission from the author.

## 🙌 Contributing

Pull requests are welcome. The contributor list is fetched automatically from the GitHub API and shown in the app's "About" window.

By submitting a pull request, you agree that your contribution may be used and relicensed by the project owner.
