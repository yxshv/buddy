# Buddy

A macOS voice assistant (Swift 5, macOS 14) that drives Claude Code. Start with README.md.

- Build: `./build.sh`. Install: `./build.sh --install`, then quit and reopen Buddy (`osascript -e 'quit app "Buddy"'; open -a Buddy`).
- Adding, editing or removing a feature (a voice shortcut like "check it"): follow `features/README.md`. It doesn't need Swift or a rebuild.
- Permissions (what asks first): `Sources/Permissions.swift`, shown in the Settings window (`canvas/settings.html`, `Sources/SettingsWindow.swift`). Loosening a level, or adding or removing a feature, must keep requiring Touch ID.
- Claude's prompt: `ClaudeBridge.systemPrompt`, plus the enabled features' lines from `FeatureStore.prompt()`. Keep both short, because they're spoken-answer instructions.
- The web pages in `canvas/` can be previewed in a browser: `.claude/launch.json` has `canvas-preview`. Call `chats.load(...)`, `settings.load(...)` or `chat.set(...)` with sample data.
- GUI testing: prefer `--demo --snap <dir>` and `--canvas-test <dir>` (see CONTRIBUTING.md). If a virtual test display is available, run GUI tests there rather than on the main screen.
