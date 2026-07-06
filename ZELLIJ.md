# tmux → Zellij porting guide

Map the tmux workflow (one detached session per agent, attach/detach from the phone,
`beam`) onto **[Zellij](https://zellij.dev)**, a modern Rust terminal multiplexer.

## Zellij on Windows — yes, natively
Zellij runs on **Windows natively** in Windows Terminal / PowerShell (Windows' ConPTY gives it
the pseudo-console it needs). If you already have it running there, you're set — **the command
map below is OS-agnostic** and applies directly in PowerShell. (tmux, by contrast, is still
Unix-only on Windows — Zellij is the one that replaces it here.) WSL2 is only a fallback if a
given build misbehaves. On macOS/Linux it's native too.

## Install
- Windows: however you got it — `winget install Zellij.Zellij` / `scoop install zellij` /
  `cargo install zellij` / the release binary. Then run `zellij` in PowerShell.
- macOS: `brew install zellij`
- Linux/WSL: `bash <(curl -L https://zellij.dev/launch)` or your package manager / `cargo install zellij`

## Command map (tmux → Zellij)

| Goal | tmux | Zellij |
| --- | --- | --- |
| List sessions | `tmux ls` | `zellij list-sessions`  (`zellij ls`) |
| Attach to a session | `tmux attach -t a1` | `zellij attach a1`  (`zellij a a1`) |
| Attach OR create | `tmux new -A -s a1` | `zellij attach --create a1`  (`zellij a -c a1`) |
| Detach (keybinding) | `Ctrl-b  d` | `Ctrl-o  d` |
| Kill one session | `tmux kill-session -t a1` | `zellij kill-session a1`  (`zellij k a1`) |
| Kill all | `tmux kill-server` | `zellij kill-all-sessions` |
| New tab/window | `Ctrl-b  c` | `Ctrl-t  n` |
| Split pane | `Ctrl-b  %` / `"` | `Ctrl-p` then `r` (right) / `d` (down) |
| Scrollback | `Ctrl-b  [` | `Ctrl-s`  (or just the mouse — on by default) |
| Mouse | `set -g mouse on` | on by default (no config needed) |

> Zellij is **modal**: a prefix like `Ctrl-o`/`Ctrl-p`/`Ctrl-t` enters *session*/*pane*/*tab*
> mode, then a single key acts. `Ctrl-o d` = detach. It also shows a hint bar, so you don't
> have to memorize.

## One detached session per agent (the `ccnew` equivalent)

tmux does `tmux new -d -s a1 claude` (start detached, auto-running claude). Zellij auto-runs a
command via a **layout**. Create `~/.config/zellij/layouts/claude.kdl`:
```kdl
layout {
    pane command="claude" {
        args "--dangerously-skip-permissions"
    }
}
```
Then start a named session that runs claude:
```bash
zellij --session a1 --layout claude      # opens attached; detach with Ctrl-o d
```
Shell helper (drop in your `.bashrc`/`.zshrc` inside WSL or on the Mac):
```bash
ccnew() { zellij --session "${1:-a1}" --layout claude; }   # attach; Ctrl-o d to leave it running
cclist() { zellij list-sessions; }
cckill() { zellij kill-session "$1"; }
```
> To create it **already-detached** (no attach), recent Zellij supports
> `zellij attach --create-background a1` (then attach later). Check `zellij attach --help` for
> your version; otherwise use the create-then-`Ctrl-o d` method above.

## From the phone (Termius)
1. SSH into the box over Tailscale (into PowerShell on Windows).
2. `zellij ls` to see running agents → `zellij attach a1`.
3. Work; leave it running with `Ctrl-o d`; reconnect anytime with `zellij attach a1`.
Swipe between Termius tabs = one `zellij attach <name>` per agent, same as the tmux flow.

## The `beam` equivalent
`beam` (Mac skill) forks the current chat into a detached tmux session and prints the attach
command. The Zellij version of the *concept*: start a named session that resumes the chat, then
detach:
```bash
zellij --session <topic> --layout claude-resume   # a layout whose pane runs: claude --resume <session-id>
# Ctrl-o d to detach, then from the phone:  zellij attach <topic>
```
Porting the `beam` **skill** itself to Zellij means swapping its `tmux new-session`/`tmux
attach` calls for `zellij --session … --layout …` / `zellij attach …` and generating a resume
layout on the fly — a small rewrite of the skill script, not covered here.

## Gotchas
- Zellij keybindings differ from tmux; the on-screen hint bar helps. You can remap in
  `~/.config/zellij/config.kdl` (e.g. set a tmux-like `Ctrl-b` prefix via the built-in `tmux` mode).
- `zellij setup --dump-config > ~/.config/zellij/config.kdl` to start customizing.
- On Windows the config lives at `%APPDATA%\zellij\config.kdl` (or `~/.config/zellij/` if set);
  layouts go in the `layouts\` subfolder next to it.
- The `ccnew`/`cclist`/`cckill` shell helpers above are bash (Mac/WSL). In PowerShell, the repo's
  `claude-remote.ps1` `ccnew` uses `zellij --session <name> --layout claude` when zellij is present.
