import subprocess, glob, os, sys, collections

files = sorted(glob.glob(os.path.expanduser(
    "~/projects/ponylang/ponyc/packages/**/*.pony"), recursive=True))
agree = disagree = wholefail = 0
bad = []
tot_items = tot_ok = 0
for f in files:
    try:
        out = subprocess.run(["./probe", f], capture_output=True,
                             text=True, timeout=60).stdout
    except Exception as e:
        bad.append((f, "crash/timeout")); continue
    whole, item = [], []
    for ln in out.splitlines():
        p = ln.split()
        if not p: continue
        if p[0] == "WHOLE":
            if "FAILED" in ln: whole = None; break
            whole.append((p[1], p[2], p[3], p[4]))
        elif p[0].startswith("ITEM"):
            if "FAILED" in ln: item.append(("FAILED",)); continue
            item.append((p[1], p[2], p[3], p[4]))
        elif "items," in ln:
            n, k = int(p[0]), int(p[2]); tot_items += n; tot_ok += k
    if whole is None:
        wholefail += 1; continue
    if whole == item:
        agree += 1
    else:
        disagree += 1
        if len(bad) < 12:
            bad.append((f, f"whole={len(whole)} item={len(item)}"))
print(f"files              : {len(files)}")
print(f"whole-file parse ok: {len(files)-wholefail}")
print(f"identical item list: {agree}")
print(f"differing          : {disagree}")
print(f"whole-file failed  : {wholefail}")
print(f"items total        : {tot_items}, parsed {tot_ok}")
print()
for f, why in bad:
    print(" ", os.path.relpath(f, os.path.expanduser(
        "~/projects/ponylang/ponyc/packages")), why)
