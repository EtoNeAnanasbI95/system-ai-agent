# System AI Agent

Chat with [Claude Code](https://docs.anthropic.com/en/docs/claude-code) in a Noctalia panel that slides in from the right edge of the screen.

> **Unofficial.** This plugin is not made, endorsed or supported by Anthropic. "Claude" and "Claude Code" are trademarks of Anthropic, PBC. The plugin drives the `claude` CLI you already have installed and signed in to.

## Plugin

| Field | Value |
| --- | --- |
| ID | `notkirilov/system-ai-agent` |
| Entries | Bar widget: `agent`; panel: `panel`; service: `service` |

## Requirements

- `claude`: the Claude Code CLI on `PATH` (or set `claude_path`), already signed in with `claude /login`. Tested with 2.1.322.
- `python3` on `PATH` (or set `python_path`). The bridge uses only the standard library.
- Noctalia 5.4.1 or newer (plugin API 43).
- Optional: `wl-paste` (wl-clipboard) for pasting with Ctrl+V, and `magick` (ImageMagick) to shrink large pasted images.

## Usage

### Open the panel

```sh
noctalia msg panel-toggle notkirilov/system-ai-agent:panel
```

Bind it to a key. For Hyprland with a Lua config:

```lua
hl.bind("SUPER + A", hl.dsp.exec_cmd("noctalia msg panel-toggle notkirilov/system-ai-agent:panel"), { description = "System AI Agent" })
```

For a classic `hyprland.conf`:

```
bind = SUPER, A, exec, noctalia msg panel-toggle notkirilov/system-ai-agent:panel
```

In the panel:
- **Ctrl+Enter** sends the message. With "Send on Enter" turned on, **Enter** sends and **Shift+Enter** adds a new line.
- **Esc** closes the panel; it stays open when you click or type in other windows. Claude keeps working while the panel is closed.

### Features

- **Local chat history.** Open **Chats** to search conversations created by Claude Code in the terminal, Zed, or this panel. The picker shows the title, update time and working folder. Selecting a chat restores its recent messages; history pages let you read older messages. The next message resumes that session in its original folder. Only one conversation runs in the plugin at a time; stop or finish the current turn before switching. A live session in another application requires an explicit confirmation; the plugin never kills that application.
- **Slash commands.** Type `/` to see a compact, paginated list of commands discovered from your installed Claude Code, including personal/project skills and plugin commands. Pick a suggestion with the keyboard (see **Suggestion keys**) or click it, add arguments and send it with Ctrl+Enter (or Enter if configured). Close suggestions with ×; Escape stays Noctalia's key for closing the panel. `/new` or `/clear` starts a new chat; `/resume` opens the local chat picker. Unknown commands are rejected rather than accidentally sent as a model prompt. Commands requiring the terminal UI are not offered.
- **Streaming.** It streams with Markdown, shows tool calls as collapsible rows, and has Stop and New chat buttons. Closing and reopening the panel keeps the conversation.
- **File references.** Click the paperclip to browse local files, or type `@` followed by a filename/path to get compact suggestions. Searches use the active chat’s working folder; `~/` and absolute paths also work. Choose a folder to navigate, or a file to attach it. Remove a reference before sending with ×. You can send up to 10 files, including a message with files only. References send quoted absolute paths, not file contents: Claude reads them using its normal tools when needed. Failed sends preserve the draft and file references. Large folder searches are bounded and report incomplete results; narrow the query or browse a subfolder.
- **Suggestion keys.** Command and `@` file suggestions highlight their first row. By default **↓/↑** move the highlight (wrapping around, and paging through file results) and **Tab** inserts it; the line above the list shows the current keys. Change them in the settings `suggestion_next`, `suggestion_previous` and `suggestion_accept`, e.g. Tab/Shift+Tab to move and Enter to pick. Enter picks only while suggestions are shown; otherwise it sends or adds a line as usual. In the file browser, Enter in an empty path field picks the highlighted file.
- **Copy.** Every code block in an answer has its own **Copy** button (it copies just the code, without the fences). **Copy answer** on the line under a finished turn copies everything Claude wrote in that turn.
- **Images.** Copy a screenshot and press **Ctrl+V** in the panel (or click the photo button). Thumbnails appear above the input; remove one with ×. Up to 5 images per message, PNG/JPEG/WebP/GIF; an image file copied in a file manager works too. Images over 3.75 MB are shrunk with ImageMagick (`magick`) when it is installed. Images are read with `wl-paste` and kept privately (mode 0600) in the plugin data directory for 7 days, so they still show in the feed.
- **Pasting text.** Ctrl+V asks the bridge what the clipboard holds (Noctalia's text field would otherwise paste the newest *text* from clipboard history over a screenshot). Text is appended to the message (or to the chat search, or attached when it is a path while the file browser is open). To paste in the middle of the text, use **Ctrl+Shift+V**, the field's own paste at the cursor.
- **Branch from an answer.** Every finished answer from Claude has a small fork button. It starts a branch that keeps the conversation up to and including that answer: the feed is cut there, and your next message continues a copy under a new session id (`--resume … --fork-session --resume-session-at <message>`). The original chat stays untouched in **Chats**. `/fork` branches the whole current chat.
- **Model, effort and access.** Choose them in the panel. Access defaults to **Bypass**, as requested: tools run without approval cards in that mode. Choose **Default**, **Accept edits**, or **Plan** when you want another workflow. Controls are locked during a running turn; a change closes the idle Claude process and the next message resumes the same chat with the new settings. Panel choices persist in the plugin data directory and override corresponding plugin settings until changed in the panel.
- **Permission cards.** In Default or another approval-based mode, when Claude Code wants to run a command or edit a file that your rules do not already allow, the panel shows what it wants to do. You choose **Allow** (once), **Deny**, or **Allow for this session**. The session option grants only the exact narrow rule shown on the card, and only for the current `claude` process. Nothing is ever approved automatically.
- **Resume.** If the `claude` process dies, the next message continues the same conversation with `--resume`. After a Noctalia restart, the panel restores the recent history of the last conversation and the next message continues it.
- **Bar widget** with the state (idle, working, waiting for approval). There are notifications when Claude needs approval and when a turn finishes while the panel is closed. Successful completion and errors have different titles; Stop does not send a completion notification. Reconnecting does not replay an already observed result.

### Bar widget

The widget entry is `notkirilov/system-ai-agent:agent`. After you enable the plugin, add it from the bar's **Add widget** picker. To add it by hand, put this in your widgets config (for example `~/.config/noctalia/widgets.toml`):

```toml
[widget.system-ai-agent]
type = "notkirilov/system-ai-agent:agent"
```

Then list `system-ai-agent` in a bar section, for example in the `end` list of your bar in Settings → Bar.

| Icon | Meaning |
|---|---|
| sparkles | idle |
| spinner | Claude is working |
| alert circle (red) and a number | waiting for your approval (the number is how many requests wait) |
| warning triangle | error, or the bridge is not running |

- **Left click** toggles the panel.
- **Middle click** stops the current answer.
- The tooltip shows the chat title and the state.

## Settings

Open the gear on the plugin's row in **Settings → Plugins**, or the gear in the panel header. The normal settings show the working folder, permission/completion notifications and Send on Enter. Model, effort and access are chosen in the chat panel; their fallback defaults, executable paths, custom instructions and config-loading switch are under Noctalia's **Advanced** settings filter. Noctalia also adds its own panel placement controls. You can also set values in `~/.config/noctalia/plugins.toml`:

```toml
[plugin_settings."notkirilov/system-ai-agent"]
model = "sonnet"
default_cwd = "~/work"
```

| Key | Type | Default | What it does |
|---|---|---|---|
| `claude_path` | string | `""` | Path to the `claude` executable. Empty: search `PATH`, then `~/.local/bin/claude`. |
| `default_cwd` | folder | `~` | Folder where Claude starts a new chat. |
| `model` | select | `default` | `default` (your Claude Code setting), `fable`, `opus`, `sonnet`, `haiku`. |
| `permission_mode` | select | `bypassPermissions` | `bypassPermissions`: no approval prompts; `default`: standard prompts; `acceptEdits`: approve edits; `plan`: planning mode. |
| `effort` | select | `default` | `default`, `low`, `medium`, `high`, `xhigh`, `max`, passed to Claude Code with `--effort`. Model support may vary. |
| `load_user_config` | bool | `true` | Use your `~/.claude` setup: CLAUDE.md, settings, permission rules, MCP servers, hooks. Off: `claude --safe-mode`. |
| `extra_prompt` | string | `""` | Text appended to the plugin's system instructions. |
| `notify_on_permission` | bool | `true` | Notify when Claude waits for approval while the panel is closed. |
| `notify_on_completion` | bool | `true` | Notify when a turn finishes or fails while the panel is closed. |
| `send_on_enter` | bool | `false` | Enter sends and Shift+Enter adds a new line. Off: Ctrl+Enter sends. |
| `python_path` | string | `""` | Python interpreter for the bridge. Empty: `python3` from `PATH`. |
| `suggestion_next` | select | `down` | Key that moves the suggestion highlight down: `down`, `up`, `tab`, `shift_tab`. |
| `suggestion_previous` | select | `up` | Key that moves it up (same choices). |
| `suggestion_accept` | select | `tab` | Key that inserts the highlighted suggestion: `tab`, `enter`, `shift_tab`. A key chosen for two actions picks. |

Tab/Shift+Tab to move and Enter to pick:

```toml
[plugin_settings."notkirilov/system-ai-agent"]
suggestion_next = "tab"
suggestion_previous = "shift_tab"
suggestion_accept = "enter"
```

A model, mode or folder change applies to the next `claude` process: after **New chat**, or when the current process has ended. A `python_path` change restarts the bridge.

The plugin appends a short system instruction to every chat. It says the agent runs in a Noctalia panel on Linux, should answer in your language, and must not run `sudo` or other commands that wait for a password or TTY. When root is needed, Claude shows the command for you to run.

## IPC

```sh
noctalia msg plugin notkirilov/system-ai-agent:service all status
```

Writes a one-line summary of the bridge (address, pid, state, pending approvals, last error) to `~/.cache/noctalia/noctalia.log`. It takes no payload and changes nothing.

## Notes

### Security and privacy

- **Processes.**
  - The plugin's service starts one bridge, `python3 -I bridge/agentd.py`. It uses only the standard library.
  - The bridge starts one `claude -p --input-format stream-json --output-format stream-json --permission-prompt-tool stdio …` process when you send the first message. The process gets `CLAUDE_AGENT_BRIDGE=1` in its environment and dies with the bridge.
  - Pasting runs `wl-paste` to read the clipboard, and `magick` to shrink an image over 3.75 MB. Nothing else is spawned.
  - When you disable the plugin or Noctalia exits, the bridge and `claude` stop within a few seconds. The bridge also exits when Noctalia stops reading its output.
- **Network.**
  - The panel talks to the bridge over HTTP on `127.0.0.1`, on a random port, with a random 256-bit token that is never written to disk.
  - The bridge rejects requests that carry an `Origin` header or a wrong `Host` header.
  - The plugin itself makes no other network connections. Claude Code talks to Anthropic as it always does.
- **Your text.**
  - Messages go to `claude` over stdin, never on a command line, so they do not show in `ps`.
  - The bridge logs (stderr, `warn` level by default) and the Noctalia log do not contain message text.
  - The "Extra instructions" setting is passed to `claude` as `--append-system-prompt`, so it is visible in `ps`. Do not put secrets there.
- **Permissions.**
  - The chosen permission mode is passed explicitly with `--permission-mode`. The default is `bypassPermissions`; Default, Accept edits and Plan are also available in the panel. In bypass mode Claude executes tools without asking for approval.
  - A request waits until you answer, press Stop, or start a new chat. Stop and New chat count as Deny.
  - "Allow for this session" adds only the narrow `addRules` entry for that tool, with destination `session`. It never writes `~/.claude/settings*.json` or a project's `.claude/settings.local.json`, and never changes the permission mode.
  - Approval cards and session-rule decisions apply when the selected Claude Code mode requests approval.
- **Files written.**
  - `~/.local/state/noctalia/plugins/data/notkirilov/system-ai-agent/preferences.json` (mode 0600) stores panel-selected model, effort and access mode.
  - `~/.local/state/noctalia/plugins/data/notkirilov/system-ai-agent/images/` (directory 0700, files 0600) keeps pasted images for 7 days.
  - `~/.local/state/noctalia/plugins/data/notkirilov/system-ai-agent/last_session.json` (mode 0600) holds the id of the last conversation, used for `--resume`.
  - `$XDG_RUNTIME_DIR/system-ai-agent/agentd.lock` (or `/tmp/system-ai-agent-<uid>/agentd.lock` without `XDG_RUNTIME_DIR`) keeps a single bridge running.
  - Claude Code itself keeps its transcripts in `~/.claude/projects/`, as usual. The bridge reads main conversation transcripts there to populate the chat picker and history (or `$CLAUDE_CONFIG_DIR/projects` when configured). It does not edit those files; Claude Code appends to a conversation when you send a message after selecting it.
  - Chat content is treated as display data. Replayed tool calls never become approval requests. Opening the picker does not launch a model request; slash-command discovery initializes Claude without sending a user prompt (your configured startup hooks can run).

### Limitations (v0.1)

- One active conversation at a time. Opening another chat is unavailable until the current turn finishes or is stopped. Chat deletion/renaming and concurrent background conversations are not implemented.
- The feed restores the latest 200 normalized history events. Older history is available in pages. Transcript parsing follows Claude Code’s local JSONL format; a future CLI update may require compatibility changes. Missing working folders produce an error instead of silently starting in another project.
- The Bash tool has no TTY. Commands that need `sudo` or interactive input cannot run, so Claude shows them for you to run in a terminal.
- `AskUserQuestion` is disabled. Claude asks follow-up questions as plain text.
- Single line breaks inside a paragraph render as spaces (standard Markdown). Use lists or code blocks for line-by-line output.
- Thinking appears when its block ends, not while it streams.
- Noctalia lets a panel capture only a fixed list of keys, and always. So Tab, Shift+Tab, ↑ and ↓ belong to the suggestions in every configuration: in a multi-line message ↑/↓ do not move the cursor between lines (use the mouse, Home/End or Page Up/Down), and Tab does not move focus between the panel's controls.
- The panel is tested on Hyprland with Noctalia 5.4.1 and Claude Code 2.1.322. The permission protocol (`--permission-prompt-tool stdio`) is not listed in `claude --help`; a future CLI release could change it.

### Troubleshooting

- **"Claude Code is not signed in"** card: run `claude /login` in a terminal.
- **"Cannot start claude"** card: set `claude_path` to the full path of `claude`.
- **The widget shows a warning, or the panel says "Reconnecting…" for a long time:** check that `python3` works, or set `python_path`. Then run `noctalia msg plugin notkirilov/system-ai-agent:service all status` and look for the `system-ai-agent:` line in `~/.cache/noctalia/noctalia.log`.

### License

MIT, see [LICENSE](../LICENSE).
