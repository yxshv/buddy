# Contributing to Buddy

Thanks for helping out! Buddy is a small, dependency-free Swift app, so getting started is quick.

## Build and run

```bash
./build.sh            # builds build/Buddy.app
./build.sh --install  # copies it to /Applications and links the `buddy` CLI
```

Then quit and reopen Buddy: `osascript -e 'quit app "Buddy"'; open -a Buddy`.

Your own folders, bundle ID and signing certificate go in `local.env` (copy `local.env.example`; it's gitignored). Never hard-code personal paths or URLs: add a key to `Sources/Config.swift` and `build.sh` instead.

There's no Xcode project: `build.sh` calls `swiftc` on `Sources/*.swift` directly. Signing with a stable certificate (see the README's Notes) keeps macOS permissions across rebuilds.

## Checking your change without a mic or Claude

- `open -n -a Buddy --args --demo` plays every panel state; add `--snap <folder>` to save screenshots.
- `open -n -a Buddy --args --scene scene.json` stages one exchange (question, reply with Claude's drawing tags, optional OK card) on the screen under the mouse, for screenshots like the README's. The format is documented on `runScene` in `Sources/AppDelegate.swift`.
- `open -n -a Buddy --args --canvas-test <folder>` draws a sample on the pen layer and saves `canvas.png`.
- The web UI in `canvas/` runs in any browser: `python3 -m http.server --directory canvas`, then open `preview.html`, `reply.html`, `chats.html` or `settings.html` and call `chats.load(...)`, `settings.load(...)` or `chat.set(...)` with sample data.

## Where things live

| Area | Files |
|---|---|
| Talking to Claude Code | `Sources/ClaudeBridge.swift` |
| Parsing replies, tags, steps | `Sources/Reply.swift` |
| Panel, cursor buddy | `Sources/Overlay.swift`, `canvas/reply.html` |
| Drawing layer | `Sources/Canvas.swift`, `canvas/canvas.*` |
| Clicking and typing | `Sources/Executor.swift`, `Sources/AXTree.swift` |
| What asks first | `Sources/Permissions.swift`, `Sources/ToolPermission.swift` |
| `buddy` CLI commands | `Sources/Commands.swift`, `tools/buddy.swift` |
| Voice shortcuts | `features/` (see `features/README.md`; no Swift needed) |

## Ground rules

- **Safety first.** Loosening a permission level, or adding or removing a feature, must keep requiring Touch ID. Destructive actions (deleting, sending, paying) always ask. PRs that weaken this won't be merged.
- **Keep prompts short.** `ClaudeBridge.systemPrompt` and feature `guidance` lines are added to every request and shape spoken answers.
- **No new dependencies** without a good reason; Buddy builds with only the Swift toolchain.
- Describe how you tested the change (demo, canvas test, a real question) in the PR.
