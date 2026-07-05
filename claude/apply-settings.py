#!/usr/bin/env python3
# apply-settings.py — merge settings.template.json into ~/.claude/settings.json.
# Cross-platform (used by install.ps1 on Windows and by the README steps).
# usage: apply-settings.py <template.json> <dst.json> <master_key> [--env-only]
import json, os, sys, time

tmpl_path, dst_path, key = sys.argv[1], sys.argv[2], sys.argv[3]
env_only = "--env-only" in sys.argv[4:]

tmpl = json.load(open(tmpl_path))
os.makedirs(os.path.dirname(dst_path), exist_ok=True)

cur = {}
if os.path.exists(dst_path):
    raw = open(dst_path, encoding="utf-8").read()
    open(dst_path + ".bak." + str(int(time.time())), "w", encoding="utf-8").write(raw)  # back up RAW
    try: cur = json.loads(raw)
    except Exception: cur = {}
if not isinstance(cur, dict): cur = {}

env = {k: (key if v == "__MASTER_KEY__" else v) for k, v in tmpl.get("env", {}).items()}
if not isinstance(cur.get("env"), dict): cur["env"] = {}
cur["env"].update(env)                                # env: ours win, keep user's others
if not env_only:
    for k, v in tmpl.items():                         # top-level: model, statusLine, effort, theme, ...
        if k != "env": cur[k] = v

# powershell -File does NOT resolve ~ on Windows; expand it to an absolute forward-slash
# path (works on Windows AND macOS/linux) so the status line actually loads.
sl = cur.get("statusLine")
if isinstance(sl, dict) and isinstance(sl.get("command"), str) and "~" in sl["command"]:
    sl["command"] = sl["command"].replace("~", os.path.expanduser("~").replace("\\", "/"), 1)

json.dump(cur, open(dst_path, "w", encoding="utf-8"), indent=2)
print("wrote", dst_path)
