#!/usr/bin/env python3
# Stop hook -> publish an agent's latest reply to the local artifact gallery.
# Best-effort ONLY (always exits 0). Only for tmux-run agents; title = tmux session.
#
# The read+publish runs in a DETACHED worker that first waits for the transcript to
# flush, so it captures the FULL final reply instead of just the pre-tool-call
# preamble (Claude Code fires Stop before the last message is persisted).
import sys, os, json, subprocess, time

ARTIFACT = os.path.expanduser("~/.claude/skills/artifact/artifact.py")
FLUSH_WAIT = 2.5  # seconds to let Claude Code persist the final message


def extract(tpath):
    try:
        rows = []
        with open(tpath) as f:
            for line in f:
                s = line.strip()
                if not s.startswith("{"):
                    continue
                try:
                    rows.append(json.loads(s))
                except Exception:
                    continue
    except Exception:
        return ""

    def is_prompt(o):
        m = o.get("message") if isinstance(o.get("message"), dict) else {}
        if not (o.get("type") == "user" or m.get("role") == "user"):
            return False
        c = m.get("content")
        if isinstance(c, str):
            return bool(c.strip())
        if isinstance(c, list):
            if any(isinstance(b, dict) and b.get("type") == "tool_result" for b in c):
                return False  # tool results are not real prompts
            return any(isinstance(b, dict) and b.get("type") == "text" and b.get("text", "").strip() for b in c)
        return False

    def atext(o):
        m = o.get("message") if isinstance(o.get("message"), dict) else {}
        if not (o.get("type") == "assistant" or m.get("role") == "assistant"):
            return ""
        c = m.get("content", [])
        if not isinstance(c, list):
            return ""
        return "\n\n".join(
            b.get("text", "").strip() for b in c
            if isinstance(b, dict) and b.get("type") == "text" and b.get("text", "").strip()
        )

    start = 0
    for i, o in enumerate(rows):
        if is_prompt(o):
            start = i
    parts = [t for t in (atext(o) for o in rows[start:]) if t]
    return "\n\n".join(parts).strip()


def publish(sess, text):
    safe = "".join(c for c in sess if c.isalnum() or c in "-_") or "agent"
    tmpf = "/tmp/artifact-{}.md".format(safe)
    try:
        with open(tmpf, "w") as f:
            f.write("# {} — latest reply\n\n{}\n".format(sess, text))
        subprocess.run(
            ["python3", ARTIFACT, "publish", "--file", tmpf, "--type", "md",
             "--title", sess, "--emoji", "\U0001f916", "--no-open"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30,
        )
    except Exception:
        pass


def worker(tpath, sess):
    time.sleep(FLUSH_WAIT)
    text = extract(tpath)
    if text:
        publish(sess, text)


def main():
    if len(sys.argv) >= 4 and sys.argv[1] == "--worker":
        worker(sys.argv[2], sys.argv[3])
        return
    if not os.environ.get("TMUX"):
        return
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return
    tpath = payload.get("transcript_path") or ""
    if not os.path.exists(tpath):
        return
    sess = ""
    pane = os.environ.get("TMUX_PANE", "")
    try:
        args = ["tmux", "display-message", "-p"] + (["-t", pane] if pane else []) + ["#S"]
        sess = subprocess.run(args, capture_output=True, text=True, timeout=3).stdout.strip()
    except Exception:
        pass
    if not sess:
        sess = (payload.get("session_id") or "agent")[:8]
    try:
        subprocess.Popen(
            [sys.executable, os.path.abspath(__file__), "--worker", tpath, sess],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL,
            start_new_session=True,
        )
    except Exception:
        return


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
