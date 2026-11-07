# DevNotch

> **Status: abandoned.** Not longer developed. An experiment, finished as far as it goes. Its Git panel idea lives on as one module of Ashira, my current (private) app.

DevNotch is a macOS menu-bar app that turns the notch (or the top of the screen on Macs without one) into a live Git status panel, visible only while you're working in Xcode or Terminal. It can also draft Conventional Commits messages and release notes with a local model through [Ollama](https://ollama.com), so no code leaves your machine.

## Why it exists

It was an experiment: I wanted to see what a notch could do for a developer. I designed the app and made the decisions; the code was written entirely by Claude, which let me test the idea quickly instead of spending weeks on it.

## What works, what doesn't

- **Works:** the live Git status in the notch, finding the active repository, committing and tagging from the app.
- **Unstable:** the AI assistant. The prompt isn't great (I wrote a better one later, in Ashira), and a small local model like `qwen2.5-coder:7b` is often not enough to understand a whole diff.

## Features (as left)

- **Live Git status in the notch:** branch, staged / modified / untracked / conflicted files, last commit, last tag.
- **Active-repo detection:** works out whether you're in Xcode (via AppleScript) or Terminal (via the process tree) and finds the repository on its own.
- **Remote branch awareness:** recent activity on other branches, and a warning when the same files are being edited on different branches.
- **Two display styles:** flush with the notch, or a floating pill under the menu bar, chosen automatically depending on whether the Mac has a notch.
- **Commit assistant:** reads `git diff --staged` and drafts a Conventional Commits message.
- **Tagging assistant:** suggests a semver bump from the commits since the last tag and drafts release notes for an annotated tag. The version is computed from the commit prefixes; the model only writes the wording.
- **Ollama auto-start:** optionally runs `ollama serve` when needed and stops it when the popover closes.
- **Version from Git tags:** a build phase sets `CFBundleShortVersionString` from the latest tag.

## Requirements

<!-- quieta:requirements -->
- macOS 26.5 or later
- Xcode 26.6 or later
<!-- /quieta:requirements -->

## Running it

```bash
git clone https://github.com/oblivi0n-arch/DevNotch.git
cd DevNotch
open DevNotch.xcodeproj
```

Build and run (`⌘R`). The app has no Dock icon: click the menu-bar icon for the commit assistant, right-click it for Settings (display style, position, show only while Xcode / Terminal is active).

### Ollama

DevNotch looks for the Ollama binary in:

```
/opt/homebrew/bin/ollama
/usr/local/bin/ollama
/Applications/Ollama.app/Contents/Resources/ollama
```

The path, host (default `http://localhost:11434`) and model can be changed through `UserDefaults` (keys: `ollamaExecutablePath`, `ollamaHost`, `ollamaModel`, `autoStartOllama`).

## Architecture

```
DevNotch/
├── App/        # entry point, AppDelegate (status item, popover, overlay window)
├── Models/     # AppearanceSettings, GeneratedDrafts (commit / tag draft parsing)
├── Services/   # GitStatusService, AppModeService, OllamaClient, OllamaLauncher
├── Utilities/  # PointerTracker, ProcessInspector
└── Views/      # NotchContentView, OllamaChatView, SettingsView, AboutView, SplashView
```

- The status refreshes through **FSEvents** watching `.git`, with no polling.
- Terminal's working directory is read straight from the shell process (`proc_pidinfo` / `PROC_PIDVNODEPATHINFO`), not through AppleScript.
- `git fetch --prune` runs in the background every 180 s on its own queue, with a watchdog for timeouts.

## License

MIT. Take the code and do what you like with it. The project is archived, so there's no support and pull requests aren't accepted.