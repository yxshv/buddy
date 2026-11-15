# Buddy features

A feature is a shortcut Buddy runs in one go when the user asks for it ("Hey Buddy, check it"). Each one is a folder with a `feature.json` and a script. Buddy reads the folders on every request, so you never rebuild the app to add, edit or remove one.

| Where | What |
|---|---|
| `~/Library/Application Support/Buddy/features/<name>/` | The user's own features. Add new ones here. |
| `features/<name>/` in this repo | Built-in features. They're copied into the app by `./build.sh`, so an edit here needs `./build.sh --install`. |

A folder in the user's directory overrides a built-in one with the same folder name. That's how to change a built-in feature without rebuilding: copy its folder there and edit the copy.

## Add one

1. Run `buddy feature new "Lint this file"`. It asks for Touch ID, then creates a folder with a working `feature.json` and `run.sh` and prints the folder's path. The Settings window's **New Feature** button does the same.
2. Edit `feature.json` (described below) and the script.
3. Approve it: `buddy feature approve <command>` asks for Touch ID, and so does **Approve…** in Settings. Buddy approves the exact files, not the folder, so it won't run a feature that's new or has changed since it was approved. That way nothing, Claude included, can change what a feature does without the user seeing it.
4. Try it: run `buddy <command>` in a terminal, with Buddy running. `buddy features` shows each feature's state: a problem with the folder (a missing script, bad JSON or a command name that's already taken), or `NOT APPROVED`. The Settings window shows the same states as "Needs fixing" and "Needs your approval".
5. Your features start at **Always ask**, whatever `feature.json` says. Once one works, the user can switch it to **Never ask** in Settings, or with `buddy permission <command> allow`, which needs Touch ID.

Changes reach Buddy's Claude on the next question: Buddy restarts its Claude Code process, keeping the conversation, whenever the list of features or the allowed tools changes.

## Edit or remove one

- To edit one, change the files in its folder, then approve it again (step 3 above). A built-in feature is edited in `features/` in this repo, followed by `./build.sh --install`. Built-in features are trusted while Buddy.app's code signature is intact, so a hand edit inside the installed app breaks that trust until the feature is approved.
- To remove one, run `buddy feature remove <command>`, which asks for Touch ID and moves the folder to the Trash. You can also use **Remove…** in Settings. A built-in feature can't be removed, only switched **Off**.

## feature.json

```json
{
  "command": "check",
  "title": "Check my C++ challenge",
  "summary": "Run the checker on the C++ challenge they're working on and report pass or fail.",
  "run": "run.sh",
  "usage": "[PREFIX]",
  "phrases": ["check it", "did F03 pass"],
  "permission": "ask",
  "guidance": "Say pass or fail in one sentence.",
  "timeout": 120
}
```

| Key | Required | Meaning |
|---|---|---|
| `command` | yes | The subcommand, as in `buddy check`. It can contain lowercase letters, digits and dashes, and can't be one of Buddy's own commands (see `buddy help`). |
| `title` | yes | The name shown in Settings and on the Touch ID prompt. |
| `summary` | yes | One line saying what it does. It goes into `buddy help` and Claude's prompt. |
| `run` | yes | The script, relative to the folder. If it's executable it runs by its `#!` line; otherwise it runs with `bash`. |
| `usage` | no | The arguments, shown after the command. |
| `phrases` | no | Things the user might say to mean this feature, so Claude matches the request to it. |
| `permission` | no | The level the feature starts at: `"ask"` (Touch ID every time) or `"off"`. Only built-in features can start at `"allow"`; the user's own features are capped at `"ask"` until the user loosens them. The user's choice in Settings overrides it. |
| `guidance` | no | One short sentence telling Claude how to use the result. Keep it short, because it's added to every request. |
| `timeout` | no | The number of seconds before the script is stopped. The default is 120. |

## The script

- **Arguments:** what comes after `buddy <command>` arrives as `"$@"`. Text piped in arrives on stdin.
- **What's in front:** the script knows what the user is looking at through these variables, so "check *this*" works:
  - `$BUDDY_FRONT_APP`: the front app, e.g. `Code`.
  - `$BUDDY_FRONT_TITLE`: its window title, e.g. `time_of_day.h — F03_time`.
  - `$BUDDY_FRONT_DOC`: the file that window shows (a path), or the page in a browser (a URL), when the app reports it.
  - `$BUDDY_FEATURE_DIR`: the feature's own folder.
- **Working folder and PATH:** the script runs in its own folder. `PATH` includes `~/.local/bin` and Homebrew, so `buddy`, `g++-16`, `zoxide` and `code` are all available.
- **Output:** whatever it prints is what Claude reads. Print one short line a person could be told out loud, such as `PASS F03_time` or `FAIL F03_time` followed by the one line that failed. Exit non-zero on failure, or start the output with `error:`. Output is cut off at 12 KB.
- **Cards:** if it changed something, show a card with `buddy card "Title" --subtitle "Added tasks.json" --url /path --kind file`.

## Permissions

Everything Buddy can do falls under a row in **Settings › Permissions** (`buddy permissions` lists them). The levels, from strictest to loosest:

| Level | Meaning |
|---|---|
| `off` | Never does it. Claude is told it's turned off. |
| `ask` | Asks with Touch ID every time. |
| `risky` | Everyday steps run. Changes and risky steps ask, and one yes covers the rest of that request. |
| `allow` | Never asks. |

Two rules hold whatever the levels say:

- Destructive things ask every time: deleting, sending, paying, `sudo`, force-push.
- Anything that lets Buddy do more needs Touch ID: loosening a level, or adding or removing a feature. Tightening a level never asks.

`permissions.json` is signed with a key in the Keychain that only Buddy can read. If anything else edits the file, the signature fails: every level goes back to its default and Settings says so. On top of that, any command or file edit that touches Buddy's files or Claude Code's `settings.json` shows the OK card every time.

The rows are defined in `Permissions.areas` (`Sources/Permissions.swift`). To add a capability that should have its own row:

1. Add an `Area` there.
2. Give its `BuddyCommand` that `area:` (`Sources/Commands.swift`), or map Claude Code's tool to it in `Permissions.area(forTool:)`.
