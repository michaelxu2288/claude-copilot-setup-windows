---
name: artifact
description: >
  Publish a self-contained, mobile-friendly HTML "artifact" (rendered diff, code
  viewer, markdown doc, or custom page) and serve it from this Mac so a phone
  SSH'd in over Tailscale can open it in a browser. Use whenever visual output
  beats terminal text — reviewing a diff, reading code/files, a dashboard, a
  comparison, or a progress timeline. This is the phone "read richly" surface
  that replaces `code tunnel` + vscode.dev in the remote-Mac workflow. Invoke
  when the user says /artifact, or asks to "see / open / view this on my phone",
  "make an artifact", "show me the diff", etc.
---

# artifact — local Artifacts, served to the phone over Tailscale

Mimics claude.ai Artifacts (gallery, versioning, reopen-latest, title+emoji,
self-contained CSP-safe pages) but hosts them from THIS Mac. A phone connected
over Tailscale opens `http://<mac-tailnet-ip>:8787/`. Purpose: replace vscode.dev
for reading diffs / code / docs on the phone.

Engine: `~/.claude/skills/artifact/artifact.py` (python3, stdlib only).
Store:  `~/claude-artifacts/`  ·  Server port: 8787 (override with `$ARTIFACT_PORT`).

## When to reach for this
The user is (or will be) driving Claude Code from their phone via Tailscale+tmux.
Terminal scrollback is fine for watching an agent work, but bad for *reading*
diffs, multi-file code, or formatted docs. Whenever you'd otherwise say "open
this in your editor" or paste a big diff into the terminal, publish an artifact
instead and hand back the URL.

## How to use it (you, the agent)

Prefer the built-in renderers — they produce consistent, phone-optimized pages
and cost fewer tokens than hand-writing HTML:

```bash
A=~/.claude/skills/artifact/artifact.py

# a git/unified diff  (multi-file: auto-splits into collapsible per-file sections)
git -C <repo> diff | python3 "$A" publish --stdin --type diff --title "PR: <what>" --emoji "🔍"

# a markdown doc  (headings, lists, code fences, inline code)
python3 "$A" publish --file <file.md> --type md --title "<title>" --emoji "📋"

# one or more source files, line-numbered + light syntax highlight
python3 "$A" code src/server.py src/router.py --title "server + router" --emoji "🧩"

# a fully custom page you generated (self-contained HTML — inline ALL css/js, no external URLs)
python3 "$A" publish --file /tmp/page.html --type html --title "<title>" --emoji "📊"
```

Other commands:
```bash
python3 "$A" last      # print URL of the most-recent artifact  (the Ctrl+] equivalent)
python3 "$A" list      # list all artifacts + URLs
python3 "$A" status    # server state, bind host, transport, tailscale ip
python3 "$A" stop      # stop the server
```

Rules:
- **Always print the returned URL back to the user** so they can tap it on the phone.
- **Self-contained pages only.** For `--type html`, inline every stylesheet/script
  and embed images as data URIs — no external hosts, no `fetch` at view time
  (same constraint as real Artifacts). The built-in renderers already do this.
- **Republish the same `--title`** (or pass `--slug`) to update in place → new
  version, same URL, with a version selector in the header. Use a new title for
  a genuinely new artifact.
- Pick a short title + a fitting emoji (shows in the gallery and browser tab).

## Transport (auto-detected each publish)
- **Tailscale up** → binds to the `100.x` address; the URL is private to the
  tailnet and works from the phone anywhere. This is the intended path.
- **Tailscale down** → binds to `127.0.0.1` (safe); reachable only on the Mac.
  Tell the user to bring Tailscale up (their `setup-remote.sh`) — the next
  publish auto-rebinds; no code change needed.
- **`--lan`** → binds `0.0.0.0` and prints the LAN IP for same-WiFi testing.
  Only use when asked; it exposes the store to the local subnet while running.

## Notes
- The server is started detached (survives this Claude session) and is a
  singleton; it auto-restarts if the desired bind host changes (e.g. Tailscale
  comes up between publishes).
- Design-system: honors the repo/CLAUDE.md palette if you pass custom HTML; the
  default theme is a dark, GitHub-like mobile layout.
