<h1 align="center">Command Space</h1>

<p align="center">Spotlight, replaced. Apps, documents, commands and an AI agent behind ⌘Space.</p>

Press **⌘Space** and a black bubble opens in the upper middle of the screen, then stretches into a search bar. Start typing and results grow underneath. Type a name and you get the app or document. Type a question or a task and Space, the agent, takes it.

Command Space grew out of [Notch Agent](https://github.com/MoMia7/boring.notch). It's the same agent with the same look, moved out of the notch and into a launcher.

## What you can type

| You type | You get |
| --- | --- |
| `saf`, `vsc`, `code` | Apps, matched by prefix, initials or any word. Learns what you pick for each query. |
| `q3 report`, `invoice` | Documents and folders from the Spotlight index, most recently used first |
| `downloads`, `~/Doc…`, `/usr/lo` | Places and path completion |
| `github.com`, `localhost:3000` | Opens in your default browser |
| anything, then **⌥⏎** | Google search in your default browser |
| `12*(3+4)`, `15% of 80` | The answer. ⏎ copies it. |
| `wifi`, `displays` | System Settings panes |
| `lock`, `sleep`, `restart` | System commands. Restart, shut down and log out ask first. |
| `vol`, `next`, `dark` | **System One commands**: instant actions, plus everything Space has learned |
| your Shortcuts' names | Runs the Shortcut |
| `summarize this`, `what's eating my disk?` | **Ask Space**: the agent gets the request, plus what you're looking at |

**Keys:** ⏎ open · ⌘⏎ reveal in Finder · ⇥ ask Space · ⌥⏎ Google · ⌘1–9 pick a row · ↑↓ move · esc back/close · ⌘N new conversation · ⌘, settings. **⌥Space** goes straight to Space.

## Conversations

Every time you open Command Space, or talk with push-to-talk or a whistle, you start a **new thread**. You stay in an existing thread only by continuing it on purpose:
- typing in a conversation that's open in the panel,
- holding the talk key while one is showing,
- or replying in the conversations window.

Once System Two has answered in a thread, everything you say there goes to the agent. A reply like "the Command Space app" is an answer, not an instant command.

Old threads are in the **conversations window**: press ⌘Y in the panel, or use the menu bar → Conversations…. It's a regular window that stays open until you close it. It has every thread grouped by day, search, approvals pinned above the composer, and a marker showing which threads are working right now. ⌘O moves the panel's conversation into it. Typing a conversation's title in Command Space also finds it.

## Two systems

**System One** is instant. [Snap 1](https://huggingface.co/Otron/snap-1) is a small decision model that runs on this Mac:
- **It ranks search.** As you type, it reads the query and the top matches and decides whether you want an app, a document, a quick open, a command, a web search or the agent. Its pick gets a ✦, and the footer shows what it decided and how long it took. App and file names never leave the Mac.
- **It runs commands.** "Volume 40", "next song", "remind me to call mom at 6", "timer 10 minutes", "play my gym playlist" and the front app's menu commands run in a blink, with no LLM involved. [Jev](https://typesafe.ai), TypeSafe's hosted equivalent, works too.

**System Two** is the agent: [opencode](https://opencode.ai) running in the background, using ChatGPT, an API key, or a local model. Every shell command or file edit asks for your approval first. When a task finishes using simple commands, Command Space offers **Make this instant**. After that, System One replays it directly, and it appears in search as a learned command.

**It knows what "this" is.** Command Space never takes focus from your app, so when you ask about "this", it reads your selection, the selected Finder files, the browser page and the window you were in.

## Without opening it

- **Push-to-talk:** hold **right ⌥**, speak, release.
- **Whistle commands** (opt-in): bind a whistle to a request. Record patterns in **Settings → Voice**.
- A small black **live pill** at the top of the screen shows listening, instant results, timers, work in progress and approvals. Click it to open the conversation. Approvals bring Command Space up and keep it there until you answer.

## Install

1. Download **Command-Space.dmg** from [Releases](../../releases/latest) and drag it to Applications (or build it, see Development).
   The app isn't notarized, so macOS blocks the first launch. Right-click it → **Open** → **Open**, or run:
   ```sh
   xattr -dr com.apple.quarantine "/Applications/Command Space.app"
   ```
   New versions install themselves (Sparkle).
2. Set up System Two (installs opencode and a login service; retires Notch Agent's service if present):
   ```sh
   curl -fsSL https://raw.githubusercontent.com/otron-io/command-space/main/agent/setup.sh | zsh
   ```
3. The first-run guide does the rest:
   - It imports your Notch Agent settings.
   - It takes **⌘Space** from Spotlight. This flips the same switch as System Settings → Keyboard → Keyboard Shortcuts → Spotlight, and **Settings → General → Give back to Spotlight** undoes it.
   - It walks through permissions and downloads Snap 1.

Requires macOS 14+. Voice input needs macOS 26+.

## Privacy

- **Search** runs on this Mac: Spotlight's index, the app list, and Snap 1.
- **Speech** is transcribed on-device. Audio never leaves the computer.
- **Jev** (if you use it instead of Snap 1) sees requests and coarse context, never your selected text, file contents or file names.
- **The agent** sees what you ask and, for "this" requests, what you were looking at. It goes only to the model you chose.

## Development

```sh
swift build && swift test                 # 39 tests: parsing, whistle matching, fuzzy match, calculator, URLs
.build/debug/CommandSpace --query "saf"   # open the panel pre-filled (also --agent)
scripts/build-app.sh                      # → build/Command Space.app (signed, universal)
scripts/build-app.sh --install            # … and copy to /Applications
scripts/build-app.sh --dmg                # … and Command-Space.dmg + signed appcast.xml entry
bun test agent/local-gemma                # local-model proxy tests
log stream --predicate 'subsystem == "io.otron.commandspace"'
```

The app is a SwiftPM package. `build-app.sh` builds it with `xcodebuild` so package resource bundles end up in `Contents/Resources`. It isn't sandboxed: a launcher needs to list every app, read other apps' menus over Accessibility and run Shortcuts. That's also why Notch Agent's XPC helper is gone and its code runs in-process (`SystemHelper`).

Layout:
- `Panel/`: the bubble, results, and live pill
- `Search/`: apps, files, quick opens, the calculator, usage learning, and Snap 1 ranking
- `Agent/`: System One and System Two, carried over from Notch Agent
- `Settings/`
- `System/`: volume, brightness, media, calendar, battery

## Credits

Built on [boring.notch](https://github.com/TheBoredTeam/boring.notch) by TheBoredTeam, via Notch Agent. GPL-3.0.
