#!/usr/bin/env python3
"""
artifact.py — local, self-contained "Artifacts" for phone viewing over Tailscale.

Mimics Claude Code's claude.ai Artifacts (gallery, versioning, reopen-latest,
titles+emoji, self-contained pages) but serves them from THIS Mac so a phone
SSH'd in over Tailscale can open them in a browser. Replaces `code tunnel` +
vscode.dev for reading diffs / code / docs on the phone.

stdlib only. no external deps, no external network requests in the pages (CSP-safe).

layout under ~/claude-artifacts/:
  store.json            metadata
  index.html            gallery (landing page)
  a/<slug>/index.html   latest version of an artifact
  a/<slug>/vN.html      each published version
  .server.pid/.host/.log

binding: prefers the Tailscale 100.x address (private to your tailnet); falls
back to 127.0.0.1 (safe) unless --lan is passed (binds 0.0.0.0, prints a warning).
"""
import argparse, http.server, json, os, re, socket, struct, subprocess, sys, time, zlib, html as htmllib

BASE = os.path.expanduser("~/claude-artifacts")
PORT = int(os.environ.get("ARTIFACT_PORT", "8787"))
PIDFILE = os.path.join(BASE, ".server.pid")
HOSTFILE = os.path.join(BASE, ".server.host")
LOGFILE = os.path.join(BASE, ".server.log")
STORE = os.path.join(BASE, "store.json")

# ---------------------------------------------------------------- network

def tailscale_ip():
    # try the tailscale CLI (mac/linux/windows), then scan interfaces for the CGNAT range
    for cand in ("tailscale", "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
                 r"C:\Program Files\Tailscale\tailscale.exe"):
        try:
            out = subprocess.run([cand, "ip", "-4"], capture_output=True, text=True, timeout=4)
            ip = out.stdout.strip().splitlines()[0].strip() if out.stdout.strip() else ""
            if ip.startswith("100."):
                return ip
        except Exception:
            pass
    try:
        cmd = ["ipconfig"] if os.name == "nt" else ["ifconfig"]
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=4).stdout
        m = re.search(r"(100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.\d+\.\d+)", out)
        if m:
            return m.group(1)
    except Exception:
        pass
    return None

def lan_ip():
    # cross-platform: a dummy UDP socket reveals the primary outbound interface IP
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.settimeout(1); s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]; s.close()
        if ip and not ip.startswith("127."):
            return ip
    except Exception:
        pass
    return None

def choose_host(lan=False):
    """returns (bind_host, advertise_host, label)."""
    ts = tailscale_ip()
    if ts:
        return ts, ts, "tailscale"
    if lan:
        ip = lan_ip() or "0.0.0.0"
        return "0.0.0.0", ip, "lan"
    return "127.0.0.1", "127.0.0.1", "loopback"

# ---------------------------------------------------------------- server

def port_open(host, port):
    with socket.socket() as s:
        s.settimeout(0.5)
        try:
            s.connect((host if host != "0.0.0.0" else "127.0.0.1", port))
            return True
        except OSError:
            return False

def server_running():
    if not os.path.exists(PIDFILE):
        return False
    try:
        pid = int(open(PIDFILE).read().strip())
        if os.name == "nt":
            # os.kill(pid, 0) TERMINATES the process on Windows — use tasklist instead
            out = subprocess.run(["tasklist", "/FI", "PID eq %d" % pid, "/NH"],
                                 capture_output=True, text=True)
            return str(pid) in out.stdout
        os.kill(pid, 0)
        return True
    except Exception:
        return False

def current_bind():
    try:
        return open(HOSTFILE).read().strip()
    except Exception:
        return None

def start_server(bind_host):
    log = open(LOGFILE, "ab")
    p = subprocess.Popen(
        [sys.executable, os.path.abspath(__file__), "serve", "--host", bind_host, "--port", str(PORT)],
        stdout=log, stderr=log, start_new_session=True,
    )
    with open(PIDFILE, "w") as f:
        f.write(str(p.pid))
    with open(HOSTFILE, "w") as f:
        f.write(bind_host)
    time.sleep(0.6)

def stop_server():
    if os.path.exists(PIDFILE):
        try:
            os.kill(int(open(PIDFILE).read().strip()), 15)
        except Exception:
            pass
        for f in (PIDFILE, HOSTFILE):
            try: os.remove(f)
            except OSError: pass

def ensure_server(lan=False):
    bind_host, advertise, label = choose_host(lan)
    # restart if not running, or if the desired bind host changed (e.g. tailscale came up)
    if not server_running() or current_bind() != bind_host:
        stop_server()
        start_server(bind_host)
    return advertise, label

def serve(host, port):
    os.chdir(BASE)
    class H(http.server.SimpleHTTPRequestHandler):
        def end_headers(self):
            self.send_header("Cache-Control", "no-store")
            super().end_headers()
        def log_message(self, *a):  # quiet
            pass
    httpd = http.server.ThreadingHTTPServer((host, port), H)
    httpd.serve_forever()

# ---------------------------------------------------------------- store

def load_store():
    try:
        return json.load(open(STORE))
    except Exception:
        return {"artifacts": {}}

def save_store(s):
    json.dump(s, open(STORE, "w"), indent=2)

def slugify(t):
    s = re.sub(r"[^a-z0-9]+", "-", t.lower()).strip("-")
    return s or "artifact"

def now_ts():
    return int(time.time())

def human_time(ts):
    return time.strftime("%b %d %H:%M", time.localtime(ts))

# ---------------------------------------------------------------- ios assets

def _png(path, size, pixels):
    def chunk(typ, data):
        return struct.pack(">I", len(data)) + typ + data + struct.pack(">I", zlib.crc32(typ + data) & 0xffffffff)
    raw = bytearray()
    for y in range(size):
        raw.append(0)
        raw.extend(pixels[y * size * 4:(y + 1) * size * 4])
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)))
        f.write(chunk(b"IDAT", zlib.compress(bytes(raw), 9)))
        f.write(chunk(b"IEND", b""))

def _icon_pixels(s):
    """dark tile with three diff-colored 'lines' (blue/green/red) — the app glyph."""
    def rgba(c): return bytes((c[0], c[1], c[2], 255))
    bg = (13, 17, 23)
    buf = bytearray(rgba(bg) * (s * s))
    bars = [((31, 111, 235), 0.80), ((63, 185, 80), 0.64), ((248, 81, 73), 0.72)]
    left = int(0.20 * s); bh = int(0.105 * s); gap = int(0.075 * s); top = int(0.30 * s); rad = bh // 2
    y = top
    for col, wfrac in bars:
        right = int(wfrac * s)
        for yy in range(y, min(s, y + bh)):
            dy = min(yy - y, (y + bh - 1) - yy)
            for xx in range(left, min(s, right)):
                # crude rounded caps
                if xx < left + rad or xx > right - rad:
                    dx = min(xx - left, right - xx)
                    if dx * dx + (rad - dy) * (rad - dy) > rad * rad:
                        continue
                i = (yy * s + xx) * 4
                buf[i:i + 4] = rgba(col)
        y += bh + gap
    return bytes(buf)

def ensure_assets():
    man = os.path.join(BASE, "manifest.json")
    if not os.path.exists(man):
        json.dump({
            "name": "Claude Artifacts", "short_name": "Artifacts", "display": "standalone",
            "background_color": "#0d1117", "theme_color": "#0d1117", "start_url": "/",
            "icons": [{"src": "/icon-192.png", "sizes": "192x192", "type": "image/png"},
                      {"src": "/icon-512.png", "sizes": "512x512", "type": "image/png"}],
        }, open(man, "w"), indent=2)
    for size, name in [(180, "icon.png"), (192, "icon-192.png"), (512, "icon-512.png")]:
        p = os.path.join(BASE, name)
        if not os.path.exists(p):
            _png(p, size, _icon_pixels(size))

# ---------------------------------------------------------------- page shell

SHELL = """<!DOCTYPE html><html lang="en"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>{{EMOJI}} {{TITLE}}</title>
<meta name="theme-color" content="#0d1117">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="apple-mobile-web-app-title" content="Artifacts">
<link rel="apple-touch-icon" href="/icon.png">
<link rel="manifest" href="/manifest.json">
<style>
:root{color-scheme:dark;--bg:#0d1117;--fg:#c9d1d9;--mut:#8b949e;--bd:#21262d;--acc:#1f6feb;--add:#3fb950;--del:#f85149;}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;-webkit-text-size-adjust:100%;-webkit-tap-highlight-color:rgba(255,255,255,.06);overscroll-behavior-y:none}
.top{position:sticky;top:0;z-index:5;background:#0d1117ee;backdrop-filter:blur(8px);border-bottom:1px solid var(--bd);padding:max(10px,env(safe-area-inset-top)) 16px 10px;display:flex;gap:10px;align-items:center}
.top a.home{color:var(--mut);text-decoration:none;font-size:20px;padding:4px 8px;margin:-4px 0 -4px -8px;border-radius:8px}
.top a.home:active{background:#21262d}
.top h1{font-size:16px;margin:0;flex:1;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.top .ver{background:#161b22;color:var(--fg);border:1px solid var(--bd);border-radius:8px;padding:6px 8px;font-size:13px}
.wrap{padding:14px 16px calc(40px + env(safe-area-inset-bottom))}
h2{font-size:15px;color:#79c0ff;margin:22px 0 8px}
ul{padding-left:20px;margin:6px 0}li{margin:3px 0}
code{background:#161b22;border:1px solid #30363d;border-radius:5px;padding:1px 5px;font:13px ui-monospace,"SF Mono",Menlo,monospace;color:#a5d6ff}
strong{color:#e6edf3}
pre.block{background:#161b22;border:1px solid var(--bd);border-radius:10px;padding:12px;overflow:auto;font:12.5px/1.5 ui-monospace,Menlo,monospace}
/* file section (diff/code) */
.file{border:1px solid var(--bd);border-radius:10px;margin:12px 0;overflow:hidden}
.file>summary{cursor:pointer;list-style:none;padding:11px 14px;background:#161b22;display:flex;gap:10px;align-items:center;font:13px ui-monospace,Menlo,monospace}
.file>summary::-webkit-details-marker{display:none}
.file>summary .nm{flex:1;word-break:break-all}
.file>summary .cnt{font-size:12px}
.add{color:var(--add)}.del{color:var(--del)}
.rows{font:12.5px/1.5 ui-monospace,Menlo,monospace;overflow-x:auto}
.r{display:grid;grid-template-columns:44px 1fr;white-space:pre}
.r.wrapon{white-space:pre-wrap;word-break:break-word}
.r .g{color:#6e7681;text-align:right;padding:0 10px;user-select:none;position:sticky;left:0;background:var(--bg)}
.r.a{background:rgba(63,185,80,.14)} .r.d{background:rgba(248,81,73,.14)} .r.h{background:rgba(56,139,253,.14);color:#79c0ff}
.r.a .g,.r.d .g,.r.h .g{background:inherit}
.tok-c{color:#8b949e;font-style:italic}.tok-s{color:#a5d6ff}.tok-n{color:#79c0ff}
.bar{display:flex;gap:8px;flex-wrap:wrap;margin:2px 0 8px}
.bar button{background:#21262d;color:var(--fg);border:1px solid #30363d;border-radius:8px;padding:7px 12px;font-size:13px}
.bar button:active{background:var(--acc);border-color:var(--acc)}
.meta{color:var(--mut);font-size:12px;margin-top:4px}
</style></head><body>
<div class="top"><a class="home" href="/">&#8592;</a><h1>{{EMOJI}} {{TITLE}}</h1>{{VERSEL}}</div>
<div class="wrap">{{BODY}}</div>
<script>
function toggleWrap(){document.querySelectorAll('.r').forEach(function(r){r.classList.toggle('wrapon')});}
function gotoV(sel){if(sel.value)location.href=sel.value;}
/* live: pull the newest content in-place every 5s (no flash, keeps scroll). latest view only. */
(function(){
  if(/[/]v[0-9]+[.]html$/.test(location.pathname)) return;
  setInterval(function(){
    fetch(location.pathname,{cache:'no-store'}).then(function(r){return r.text();}).then(function(t){
      var doc=new DOMParser().parseFromString(t,'text/html');
      var nb=doc.querySelector('.wrap'), cb=document.querySelector('.wrap');
      if(nb&&cb&&nb.innerHTML!==cb.innerHTML){var y=window.scrollY;cb.innerHTML=nb.innerHTML;window.scrollTo(0,y);}
      var nv=doc.querySelector('.top .ver'), cv=document.querySelector('.top .ver');
      if(nv&&cv&&nv.outerHTML!==cv.outerHTML) cv.replaceWith(nv);
    }).catch(function(){});
  },5000);
})();
</script>
</body></html>"""

def shell(title, emoji, body, versel=""):
    return (SHELL.replace("{{TITLE}}", htmllib.escape(title))
                 .replace("{{EMOJI}}", emoji or "\U0001F4C4")
                 .replace("{{VERSEL}}", versel)
                 .replace("{{BODY}}", body))

# ---------------------------------------------------------------- renderers

def light_highlight(line):
    """language-agnostic: comments, strings, numbers. input already html-escaped."""
    # strings
    line = re.sub(r"(&#x27;[^&]*?&#x27;|&quot;[^&]*?&quot;|`[^`]*?`)", r'<span class="tok-s">\1</span>', line)
    # line comments (// or #) not inside an existing span — best-effort
    line = re.sub(r"(//[^<]*$|#[^<]*$)", r'<span class="tok-c">\1</span>', line)
    # bare integers/floats
    line = re.sub(r"\b(\d+\.?\d*)\b", r'<span class="tok-n">\1</span>', line)
    return line

def rows_html(lines, kinds=None, hl=False, start=1):
    """lines: list[str]; kinds: optional list of ''|'a'|'d'|'h'; returns .rows html."""
    out = ['<div class="rows">']
    n = start
    for i, ln in enumerate(lines):
        k = (kinds[i] if kinds else "")
        esc = htmllib.escape(ln)
        if hl and k != "h":
            esc = light_highlight(esc)
        gutter = "⋯" if k == "h" else ("+" if k == "a" else ("−" if k == "d" else str(n)))
        if k != "h":
            n += 1
        out.append('<div class="r %s"><span class="g">%s</span><span>%s</span></div>' % (k, gutter, esc or "&nbsp;"))
    out.append("</div>")
    return "".join(out)

def render_diff(text):
    """split a (possibly multi-file) unified/git diff into collapsible per-file sections."""
    body = ['<div class="bar"><button onclick="toggleWrap()">Toggle wrap</button>'
            '<button onclick="document.querySelectorAll(\'details.file\').forEach(d=>d.open=true)">Expand all</button>'
            '<button onclick="document.querySelectorAll(\'details.file\').forEach(d=>d.open=false)">Collapse all</button></div>']
    # break into files on `diff --git` or a fresh `--- ` header
    files, cur = [], []
    for line in text.splitlines():
        if line.startswith("diff --git ") and cur:
            files.append(cur); cur = [line]
        else:
            cur.append(line)
    if cur:
        files.append(cur)
    if len(files) == 1 and not files[0] or (len(files) == 1 and not any(l.startswith(("diff --git", "@@", "+", "-")) for l in files[0])):
        files = [text.splitlines()]
    for fl in files:
        name = "diff"
        for l in fl:
            m = re.match(r"diff --git a/(.+?) b/(.+)$", l)
            if m: name = m.group(2); break
            m = re.match(r"\+\+\+ b/(.+)$", l)
            if m: name = m.group(1); break
        lines, kinds, adds, dels = [], [], 0, 0
        for l in fl:
            if l.startswith(("diff --git", "index ", "--- ", "+++ ", "new file", "deleted file", "similarity", "rename ")):
                continue
            if l.startswith("@@"):
                lines.append(l); kinds.append("h")
            elif l.startswith("+"):
                lines.append(l[1:]); kinds.append("a"); adds += 1
            elif l.startswith("-"):
                lines.append(l[1:]); kinds.append("d"); dels += 1
            else:
                lines.append(l[1:] if l.startswith(" ") else l); kinds.append("")
        cnt = '<span class="cnt"><span class="add">+%d</span> <span class="del">−%d</span></span>' % (adds, dels)
        body.append('<details class="file" open><summary><span class="nm">%s</span>%s</summary>%s</details>'
                     % (htmllib.escape(name), cnt, rows_html(lines, kinds)))
    return "".join(body)

def render_code(files):
    """files: list of (name, text). collapsible per-file with line numbers + light highlight."""
    body = ['<div class="bar"><button onclick="toggleWrap()">Toggle wrap</button></div>']
    for name, text in files:
        lines = text.split("\n")
        body.append('<details class="file" open><summary><span class="nm">%s</span>'
                    '<span class="cnt">%d lines</span></summary>%s</details>'
                    % (htmllib.escape(name), len(lines), rows_html(lines, hl=True)))
    return "".join(body)

def render_markdown(md):
    lines = md.replace("\r\n", "\n").split("\n")
    out, depth, in_fence, fence = [], 0, False, []
    def close(to):
        nonlocal depth
        while depth > to:
            out.append("</ul>"); depth -= 1
    def inl(s):
        s = htmllib.escape(s)
        s = re.sub(r"`([^`]+)`", r"<code>\1</code>", s)
        s = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", s)
        return s
    for line in lines:
        if line.strip().startswith("```"):
            if in_fence:
                out.append('<pre class="block">%s</pre>' % htmllib.escape("\n".join(fence))); fence = []
            in_fence = not in_fence
            continue
        if in_fence:
            fence.append(line); continue
        if re.match(r"^#\s+", line): close(0); out.append("<h1>%s</h1>" % inl(re.sub(r"^#\s+", "", line))); continue
        if re.match(r"^##\s+", line): close(0); out.append("<h2>%s</h2>" % inl(re.sub(r"^##\s+", "", line))); continue
        m = re.match(r"^(\s*)-\s+(.*)$", line)
        if m:
            d = len(m.group(1)) // 2 + 1
            while depth < d: out.append("<ul>"); depth += 1
            while depth > d: out.append("</ul>"); depth -= 1
            out.append("<li>%s</li>" % inl(m.group(2))); continue
        if line.strip() == "": continue
        close(0); out.append("<p>%s</p>" % inl(line))
    close(0)
    if in_fence and fence:
        out.append('<pre class="block">%s</pre>' % htmllib.escape("\n".join(fence)))
    return "".join(out)

# ---------------------------------------------------------------- gallery

def regen_gallery():
    s = load_store()
    arts = sorted(s["artifacts"].values(), key=lambda a: a["updated"], reverse=True)
    rows = []
    for a in arts:
        vcount = len(a["versions"])
        rows.append(
            '<a class="card" href="/a/%s/"><span class="emo">%s</span>'
            '<span class="col"><span class="t">%s</span>'
            '<span class="m">%s · v%d · %s</span></span></a>'
            % (a["slug"], a.get("emoji", "\U0001F4C4"), htmllib.escape(a["title"]),
               human_time(a["updated"]), vcount, a["slug"]))
    page = """<!DOCTYPE html><html lang="en"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>Artifacts</title>
<meta name="theme-color" content="#0d1117">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="apple-mobile-web-app-title" content="Artifacts">
<link rel="apple-touch-icon" href="/icon.png">
<link rel="manifest" href="/manifest.json">
<style>
:root{color-scheme:dark}
body{margin:0;background:#0d1117;color:#c9d1d9;font:15px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;-webkit-tap-highlight-color:rgba(255,255,255,.06);overscroll-behavior-y:none}
.hd{position:sticky;top:0;background:#0d1117ee;backdrop-filter:blur(8px);border-bottom:1px solid #21262d;padding:max(14px,env(safe-area-inset-top)) 18px 12px}
.hd h1{margin:0;font-size:18px}.hd .s{color:#8b949e;font-size:12px;margin-top:2px}
.list{padding:10px 14px calc(40px + env(safe-area-inset-bottom))}
.card{display:flex;gap:12px;align-items:center;padding:14px;border:1px solid #21262d;border-radius:12px;margin:9px 0;text-decoration:none;color:inherit}
.card:active{background:#161b22}
.emo{font-size:26px;width:32px;text-align:center}
.col{display:flex;flex-direction:column;min-width:0}
.t{font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.m{color:#8b949e;font-size:12px;margin-top:2px}
.empty{color:#8b949e;padding:40px 18px;text-align:center}
.a2hs{color:#8b949e;font-size:12px;text-align:center;padding:14px;border:1px dashed #21262d;border-radius:12px;margin:14px 2px}
</style></head><body>
<div class="hd"><h1>&#128241; Artifacts</h1><div class="s">served from this Mac · tap to open</div></div>
<div class="list">__ROWS__
<div class="a2hs" id="a2hs">Tip: <b>Share &#8594; Add to Home Screen</b> to run this fullscreen, like an app.</div>
</div>
<script>if(window.navigator.standalone||matchMedia('(display-mode: standalone)').matches){var e=document.getElementById('a2hs');if(e)e.style.display='none';}
/* live gallery: refresh the card list in-place every 4s (no flash, keeps scroll) */
(function(){setInterval(function(){fetch('/',{cache:'no-store'}).then(function(r){return r.text();}).then(function(t){var doc=new DOMParser().parseFromString(t,'text/html');var nl=doc.querySelector('.list'),cl=document.querySelector('.list');if(nl&&cl&&nl.innerHTML!==cl.innerHTML){var y=window.scrollY;cl.innerHTML=nl.innerHTML;window.scrollTo(0,y);}}).catch(function(){});},4000);})();</script>
</body></html>"""
    inner = "".join(rows) if rows else '<div class="empty">No artifacts yet.</div>'
    open(os.path.join(BASE, "index.html"), "w").write(page.replace("__ROWS__", inner))

# ---------------------------------------------------------------- publish

def publish(title, emoji, body_html, slug=None):
    s = load_store()
    slug = slug or slugify(title)
    a = s["artifacts"].get(slug)
    ts = now_ts()
    if not a:
        a = {"slug": slug, "title": title, "emoji": emoji, "created": ts, "updated": ts, "versions": []}
        s["artifacts"][slug] = a
    a["title"] = title
    if emoji:
        a["emoji"] = emoji
    a["updated"] = ts
    v = len(a["versions"]) + 1
    a["versions"].append({"v": v, "ts": ts})
    # version selector
    versel = ""
    if v > 1:
        opts = "".join('<option value="/a/%s/v%d.html"%s>v%d</option>'
                       % (slug, k["v"], " selected" if k["v"] == v else "", k["v"])
                       for k in reversed(a["versions"]))
        versel = '<select class="ver" onchange="gotoV(this)">%s</select>' % opts
    page = shell(title, a.get("emoji"), body_html, versel)
    d = os.path.join(BASE, "a", slug)
    os.makedirs(d, exist_ok=True)
    open(os.path.join(d, "v%d.html" % v), "w").write(page)
    open(os.path.join(d, "index.html"), "w").write(page)  # latest
    save_store(s)
    regen_gallery()
    return slug, v

# ---------------------------------------------------------------- cli

def read_input(args):
    if args.stdin:
        return sys.stdin.read()
    if args.file:
        return open(os.path.expanduser(args.file)).read()
    return ""

def urls_for(advertise, slug=None):
    base = "http://%s:%d" % (advertise, PORT)
    return base + ("/a/%s/" % slug if slug else "/")

def cmd_publish(args):
    content = read_input(args)
    typ = args.type
    if typ == "auto":
        f = (args.file or "").lower()
        typ = "md" if f.endswith((".md", ".markdown")) else ("diff" if f.endswith((".diff", ".patch")) else "html")
    if typ == "md":
        body = render_markdown(content)
    elif typ == "diff":
        body = render_diff(content)
    elif typ == "code":
        body = render_code([(os.path.basename(args.file or "code"), content)])
    else:
        body = content  # raw html body/page fragment
    slug, v = publish(args.title, args.emoji, body, args.slug)
    advertise, label = ensure_server(args.lan)
    url = urls_for(advertise, slug)
    print(url)
    print("published '%s' v%d  [%s]  gallery: %s" % (args.title, v, label, urls_for(advertise)))
    if label == "loopback":
        print("note: bound to loopback (Tailscale not up) — reachable only on this Mac. "
              "start Tailscale and re-publish, or pass --lan for same-wifi phone access.")
    if label == "lan":
        print("warning: bound to 0.0.0.0 — reachable by any device on this LAN while the server runs.")
    if args.open and label != "lan":
        try:
            if os.name == "nt": os.startfile(url)                       # windows
            elif sys.platform == "darwin": subprocess.run(["open", url], timeout=4)
            else: subprocess.run(["xdg-open", url], timeout=4)          # linux
        except Exception: pass

def cmd_code(args):
    files = []
    for p in args.files:
        p = os.path.expanduser(p)
        files.append((os.path.basename(p), open(p).read()))
    title = args.title or (files[0][0] if files else "code")
    slug, v = publish(title, args.emoji or "\U0001F4C4", render_code(files), args.slug)
    advertise, label = ensure_server(args.lan)
    print(urls_for(advertise, slug))
    print("published '%s' v%d  [%s]" % (title, v, label))

def cmd_last(args):
    s = load_store()
    if not s["artifacts"]:
        print("no artifacts yet"); return
    a = max(s["artifacts"].values(), key=lambda x: x["updated"])
    advertise, _ = ensure_server(args.lan)
    print(urls_for(advertise, a["slug"]))

def cmd_list(args):
    s = load_store()
    arts = sorted(s["artifacts"].values(), key=lambda a: a["updated"], reverse=True)
    if not arts:
        print("no artifacts yet"); return
    advertise, label = choose_host()[1], choose_host()[2]
    for a in arts:
        print("%s  %-28s v%-2d  %s  %s" % (a.get("emoji", "\U0001F4C4"), a["title"][:28],
              len(a["versions"]), human_time(a["updated"]), urls_for(advertise, a["slug"])))

def cmd_status(args):
    advertise, label = choose_host()[1], choose_host()[2]
    print("server running: %s" % server_running())
    print("bind host:      %s" % (current_bind() or "-"))
    print("transport:      %s" % label)
    print("gallery:        %s" % urls_for(advertise))
    ts = tailscale_ip()
    print("tailscale ip:   %s" % (ts or "(not up)"))

def cmd_serve(args):
    serve(args.host, args.port)

def cmd_stop(args):
    stop_server(); print("stopped")

def cmd_rm(args):
    import shutil
    s = load_store()
    guard = os.path.realpath(os.path.join(BASE, "a")) + os.sep
    removed = []
    for slug in args.slugs:
        if slug in s["artifacts"]:
            del s["artifacts"][slug]
            d = os.path.join(BASE, "a", slug)
            if os.path.isdir(d) and os.path.realpath(d).startswith(guard):
                shutil.rmtree(d, ignore_errors=True)
            removed.append(slug)
    save_store(s)
    regen_gallery()
    print("removed: %s" % (", ".join(removed) if removed else "(none matched)"))

def main():
    os.makedirs(os.path.join(BASE, "a"), exist_ok=True)
    ensure_assets()
    if not os.path.exists(os.path.join(BASE, "index.html")):
        regen_gallery()
    p = argparse.ArgumentParser(prog="artifact")
    sub = p.add_subparsers(dest="cmd", required=True)

    pp = sub.add_parser("publish")
    pp.add_argument("--file"); pp.add_argument("--stdin", action="store_true")
    pp.add_argument("--title", required=True); pp.add_argument("--emoji", default="")
    pp.add_argument("--type", choices=["auto", "html", "md", "diff", "code"], default="auto")
    pp.add_argument("--slug", default=None); pp.add_argument("--lan", action="store_true")
    pp.add_argument("--open", action="store_true", default=(os.environ.get("CLAUDE_CODE_ARTIFACT_AUTO_OPEN", "1") != "0"))
    pp.add_argument("--no-open", dest="open", action="store_false")
    pp.set_defaults(func=cmd_publish)

    pc = sub.add_parser("code")
    pc.add_argument("files", nargs="+"); pc.add_argument("--title", default=None)
    pc.add_argument("--emoji", default=""); pc.add_argument("--slug", default=None)
    pc.add_argument("--lan", action="store_true"); pc.set_defaults(func=cmd_code)

    pl = sub.add_parser("last"); pl.add_argument("--lan", action="store_true"); pl.set_defaults(func=cmd_last)
    sub.add_parser("list").set_defaults(func=cmd_list)
    sub.add_parser("status").set_defaults(func=cmd_status)
    sub.add_parser("stop").set_defaults(func=cmd_stop)
    prm = sub.add_parser("rm"); prm.add_argument("slugs", nargs="+"); prm.set_defaults(func=cmd_rm)

    ps = sub.add_parser("serve"); ps.add_argument("--host", default="127.0.0.1")
    ps.add_argument("--port", type=int, default=PORT); ps.set_defaults(func=cmd_serve)

    args = p.parse_args()
    args.func(args)

if __name__ == "__main__":
    main()
