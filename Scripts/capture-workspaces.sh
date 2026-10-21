#!/bin/zsh
# Launches the packaged app in every workspace, drives its real core entry point
# on the generated demo sequence, captures a window screenshot and writes a
# machine-readable log. Used as UI evidence for the native workspace selector.
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT=${1:-"$ROOT/evidence/workspaces-ui"}
APP="$ROOT/build/StarryHaven.app"
CLI="$ROOT/.build/release/starryhaven-cli"
mkdir -p "$OUT"

if [[ ! -x "$APP/Contents/MacOS/StarryHaven" ]]; then
    "$ROOT/Scripts/build-app.sh" release
fi

if [[ ! -d "$OUT/../assets/trails" ]]; then
    mkdir -p "$OUT/../assets"
    "$CLI" demo-sequence --out "$OUT/../assets/trails" --kind trails
    "$CLI" demo-sequence --out "$OUT/../assets/timelapse" --kind timelapse
    "$CLI" demo-sequence --out "$OUT/../assets/pano" --kind pano
    "$CLI" demo-sequence --out "$OUT/../assets/narrowband" --kind narrowband
fi

swiftc -O "$ROOT/Scripts/winlist.swift" -o "$OUT/winlist"
caffeinate -dimsu -t 600 >/dev/null 2>&1 &
CAFFEINATE_PID=$!

python3 - "$OUT" "$APP/Contents/MacOS/StarryHaven" "$CLI" <<'PY'
import os, signal, subprocess, sys, time, re, json

out, exe, cli = sys.argv[1], sys.argv[2], sys.argv[3]
assets = os.path.join(os.path.dirname(os.path.abspath(out)), "assets")
winlist = os.path.join(out, "winlist")

def find_window():
    text = subprocess.check_output([winlist], text=True)
    for line in text.splitlines():
        owner = re.search(r"owner=([^\t]*)", line)
        if not owner or owner.group(1) not in ("星空难民营", "StarryHaven"):
            continue
        m = re.search(r"size=(\d+)x(\d+)", line)
        i = re.search(r"id=(\d+)", line)
        if m and int(m.group(2)) >= 500 and i:
            return i.group(1), line
    return None, None

def run(name, args, envs, output, wait):
    log = open(os.path.join(out, f"{name}.log"), "w")
    env = dict(os.environ)
    env.update(envs)
    p = subprocess.Popen([exe] + args, stdout=log, stderr=subprocess.STDOUT,
                         start_new_session=True, env=env)
    time.sleep(wait)
    wid, info = find_window()
    shot = os.path.join(out, f"workspace-{name}.png")
    capture_rc = 99
    if wid:
        r = subprocess.run(["screencapture", "-l", wid, "-x", "-o", shot], capture_output=True)
        capture_rc = r.returncode
    exists = os.path.exists(output) if output else "n/a"
    size = os.path.getsize(output) if (output and os.path.exists(output)) else 0
    detail = ""
    if output and os.path.exists(output) and not output.endswith(".mp4"):
        r = subprocess.run([cli, "inspect", output], capture_output=True, text=True)
        detail = (r.stdout or "").strip().splitlines()[0] if r.stdout else ""
    print(f"workspace={name} arg={args} window={wid} capture_rc={capture_rc} "
          f"output={output} bytes={size} exists={exists} inspect={detail}", flush=True)
    try:
        os.killpg(os.getpgid(p.pid), signal.SIGTERM)
    except Exception:
        pass
    log.close()
    time.sleep(1.0)

def env_frames(d): return {"STARRYHAVEN_UI_FRAMES_DIR": os.path.join(assets, d), "STARRYHAVEN_UI_RUN": "1"}

run("home", [], {}, "", 2)
run("help", ["--help"], {}, "", 2)

run("stack", ["--stack"], {"STARRYHAVEN_UI_STACK_DIR": os.path.join(assets, "trails"),
                  "STARRYHAVEN_UI_STACK_OUT": os.path.join(out, "stack.tif"),
                  "STARRYHAVEN_UI_STACK_RUN": "1"}, os.path.join(out, "stack.tif"), 12)

run("trails", ["--trails"], {**env_frames("trails"), "STARRYHAVEN_UI_OUTPUT": os.path.join(out, "trails.tif")},
    os.path.join(out, "trails.tif"), 14)

run("timelapse", ["--timelapse"], {**env_frames("timelapse"), "STARRYHAVEN_UI_OUTPUT": os.path.join(out, "timelapse.mp4")},
    os.path.join(out, "timelapse.mp4"), 16)

run("panorama", ["--panorama"], {**env_frames("pano"), "STARRYHAVEN_UI_OUTPUT": os.path.join(out, "pano.tif")},
    os.path.join(out, "pano.tif"), 10)

run("narrowband", ["--narrowband"], {
    "STARRYHAVEN_UI_HA": os.path.join(assets, "narrowband", "ha.tif"),
    "STARRYHAVEN_UI_OIII": os.path.join(assets, "narrowband", "oiii.tif"),
    "STARRYHAVEN_UI_SII": os.path.join(assets, "narrowband", "sii.tif"),
    "STARRYHAVEN_UI_OUTPUT": os.path.join(out, "narrowband.tif"),
    "STARRYHAVEN_UI_RUN": "1"}, os.path.join(out, "narrowband.tif"), 8)

run("toolbox", ["--toolbox"], {}, "", 2)
PY

kill "$CAFFEINATE_PID" 2>/dev/null || true
echo "Workspace UI evidence written to $OUT"
