#!/bin/zsh
# Reproduces the verification evidence: unit/integration tests, the two-run
# self-test, and a consolidated post-processing / I/O log with real models.
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT=${1:-"$ROOT/evidence"}
CLI="$ROOT/.build/release/starryhaven-cli"
cd "$ROOT"

mkdir -p "$OUT/tests" "$OUT/selftest" "$OUT/assets"
swift build -c release

STARRYHAVEN_SCRATCH="$OUT/tests" swift test 2>&1 | tee "$OUT/test-run.log"

"$CLI" selftest --out "$OUT/selftest" 2>&1 | tee "$OUT/selftest-run.log"

"$CLI" gen --out "$OUT/assets/field.png" --width 512 --height 512 --count 70 --noise 0.003 --stretch
"$CLI" gen --out "$OUT/assets/horizon.png" --width 640 --height 480 --horizon 220 --seed 99
"$CLI" demo-sequence --out "$OUT/assets/trails" --kind trails
"$CLI" demo-sequence --out "$OUT/assets/timelapse" --kind timelapse
"$CLI" demo-sequence --out "$OUT/assets/pano" --kind pano
"$CLI" demo-sequence --out "$OUT/assets/narrowband" --kind narrowband
"$CLI" gen --out "$OUT/assets/vignetted.png" --width 256 --height 192 --count 0 --background 0.5 --vignette 0.7

mkdir -p "$OUT/entrypoints"
"$CLI" trails --input "$OUT/assets/trails" --output "$OUT/entrypoints/trails.tif" \
    --preview "$OUT/entrypoints/trails-preview.png" --glow 0.5 2>&1 | tee "$OUT/entrypoints/trails.log"
"$CLI" timelapse --input "$OUT/assets/timelapse" --output "$OUT/entrypoints/timelapse.mp4" \
    --deflicker 15 --fps 24 2>&1 | tee "$OUT/entrypoints/timelapse.log"
"$CLI" pano --input "$OUT/assets/pano" --output "$OUT/entrypoints/pano.tif" \
    --preview "$OUT/entrypoints/pano-preview.png" 2>&1 | tee "$OUT/entrypoints/pano.log"
"$CLI" narrowband --ha "$OUT/assets/narrowband/ha.tif" --oiii "$OUT/assets/narrowband/oiii.tif" \
    --sii "$OUT/assets/narrowband/sii.tif" --palette sho --output "$OUT/entrypoints/narrowband.tif" 2>&1 | tee "$OUT/entrypoints/narrowband.log"
"$CLI" lens --input "$OUT/assets/vignetted.png" --output "$OUT/entrypoints/lens-after.png" \
    --preview-before "$OUT/entrypoints/lens-before.png" --auto --make Sony \
    --lens-model "E 16mm f/2.8" --focal 16 --aperture 2.8 2>&1 | tee "$OUT/entrypoints/lens.log"
LCP_ZIP="${STARRYHAVEN_LCP_ZIP:-$HOME/Library/Application Support/StarryHaven/LensProfiles.zip}"
if [[ -f "$LCP_ZIP" ]]; then
    unzip -p "$LCP_ZIP" "1.0/Sony/SONY (Sony FE 24-70mm F2.8 GM II) - RAW.lcp" > "$OUT/entrypoints/profile.lcp"
    "$CLI" lens --input "$OUT/assets/field.png" --output "$OUT/entrypoints/lens-lcp-after.png" \
        --lcp "$OUT/entrypoints/profile.lcp" 2>&1 | tee "$OUT/entrypoints/lens-lcp.log"
fi
"$CLI" enhance --input "$OUT/assets/field.png" --output "$OUT/entrypoints/enhance-after.png" \
    --preview-before "$OUT/entrypoints/enhance-before.png" --local-contrast 0.8 --structure 0.5 \
    --skylight 0.4 --glow 0.5 2>&1 | tee "$OUT/entrypoints/enhance.log"
"$CLI" enhance --input "$OUT/assets/horizon.png" --output "$OUT/entrypoints/enhance-sky-after.png" \
    --preview-before "$OUT/entrypoints/enhance-sky-before.png" --local-contrast 0.8 --structure 0.4 \
    --skylight 0.6 --sky-only 2>&1 | tee "$OUT/entrypoints/enhance-sky.log"

"$ROOT/Scripts/build-app.sh" release >/dev/null 2>&1
"$ROOT/Scripts/capture-workspaces.sh" "$OUT/workspaces-ui" 2>&1 | tee "$OUT/workspaces-ui.log"

{
    echo "=== models"
    "$CLI" models --describe || true
    echo
    echo "=== StarNet2"
    "$CLI" detect "$OUT/assets/field.png" --display
    "$CLI" starnet "$OUT/assets/field.png" "$OUT/assets/starless.png" \
        --stars "$OUT/assets/stars.png" --recompose "$OUT/assets/recomposed.png"
    "$CLI" detect "$OUT/assets/starless.png" --display
    "$CLI" detect "$OUT/assets/recomposed.png" --display
    echo
    echo "=== DeepSNR"
    "$CLI" denoise "$OUT/assets/field.png" "$OUT/assets/denoised.png"
    echo
    echo "=== SkySeg"
    "$CLI" skyseg "$OUT/assets/horizon.png" "$OUT/assets/sky-mask.png"
    echo
    echo "=== test metrics"
    for f in starnet.log deepsnr.log skyseg.log; do
        [[ -f "$OUT/tests/$f" ]] && { cat "$OUT/tests/$f"; echo; }
    done
} | tee "$OUT/postprocess.log"

{
    echo "=== image I/O"
    for f in io-formats.log io-fits.log io-fits-2d.log io-fits-padding.log io-raw.log; do
        [[ -f "$OUT/tests/$f" ]] && { cat "$OUT/tests/$f"; echo; }
    done
    echo
    ls -la "$OUT/tests"/io-image.* 2>/dev/null || true
} | tee "$OUT/io.log"

{
    echo "=== 星轨"
    for f in startrails.log startrails-aircraft.log; do [[ -f "$OUT/tests/$f" ]] && { cat "$OUT/tests/$f"; echo; }; done
    echo "=== 星空延时"
    [[ -f "$OUT/tests/timelapse.log" ]] && { cat "$OUT/tests/timelapse.log"; echo; }
    echo "=== 全景接片"
    [[ -f "$OUT/tests/panorama.log" ]] && { cat "$OUT/tests/panorama.log"; echo; }
    echo "=== 窄带"
    [[ -f "$OUT/tests/narrowband.log" ]] && { cat "$OUT/tests/narrowband.log"; echo; }
    echo "=== 镜头校正"
    [[ -f "$OUT/tests/lens.log" ]] && { cat "$OUT/tests/lens.log"; echo; }
    echo "=== FITS 2D / padding"
    for f in io-fits-2d.log io-fits-padding.log; do [[ -f "$OUT/tests/$f" ]] && { cat "$OUT/tests/$f"; echo; }; done
    echo "=== 镜头配置"
    for f in lensfun.log lensfun-apply.log lcp.log lcp-auto.log lens-metadata.log; do [[ -f "$OUT/tests/$f" ]] && { cat "$OUT/tests/$f"; echo; }; done
    echo "=== 项目文件"
    [[ -f "$OUT/tests/project.log" ]] && { cat "$OUT/tests/project.log"; echo; }
    echo "=== 图像增强"
    for f in enhance-local.log enhance-skylight.log enhance-glow.log enhance-sky.log; do [[ -f "$OUT/tests/$f" ]] && { cat "$OUT/tests/$f"; echo; }; done
} | tee "$OUT/workspaces.log"

RAW_SAMPLE="${STARRYHAVEN_RAW_SAMPLE:-}"
if [[ -n "$RAW_SAMPLE" && -f "$RAW_SAMPLE" ]]; then
    "$CLI" thumb "$RAW_SAMPLE" "$OUT/assets/raw-thumb.png" --size 900 | tee -a "$OUT/io.log"
    "$CLI" meta "$RAW_SAMPLE" | tee -a "$OUT/io.log"
else
    echo "RAW sample skipped; set STARRYHAVEN_RAW_SAMPLE to a camera RAW file" | tee -a "$OUT/io.log"
fi

{
    echo "=== native UI source scan"
    grep -RInE "import (AppKit|SwiftUI)|WKWebView|Electron|tkinter|webview" "$ROOT/Sources" || true
    echo
    echo "=== linked frameworks"
    otool -L "$ROOT/build/StarryHaven.app/Contents/MacOS/StarryHaven" || true
} | tee "$OUT/ui-source-scan.log"

{
    echo "=== FITS 2D / padding"
    for f in io-fits-2d.log io-fits-padding.log; do [[ -f "$OUT/tests/$f" ]] && { cat "$OUT/tests/$f"; echo; }; done
    echo
    echo "=== StarNet2"
    grep -E "reduction:|recomposed stars:|recomposition (RMS|flux)|input stars:|starless stars:" "$OUT/tests/starnet.log" 2>/dev/null || true
    echo "=== DeepSNR"
    grep -E "noise ratio:|center before:|after:" "$OUT/tests/deepsnr.log" 2>/dev/null || true
    echo "=== SkySeg"
    grep -E "IoU:|ground pixels changed:|manual" "$OUT/tests/skyseg.log" 2>/dev/null || true
    echo "=== CLI entry points"
    for f in trails timelapse pano narrowband lens lens-lcp enhance enhance-sky; do
        [[ -f "$OUT/entrypoints/$f.log" ]] && { echo "-- $f"; grep -E "trails:|timelapse:|pano:|narrowband:|lens:|enhance:" "$OUT/entrypoints/$f.log"; }
    done
    echo "=== workspace UI"
    cat "$OUT/workspaces-ui.log" 2>/dev/null || true
    echo "=== entry point"
    grep -E "RUN DIFF|SELFTEST" "$OUT/selftest-run.log" 2>/dev/null || true
} | tee "$OUT/gate-summary.log"

echo "Evidence written to $OUT"
