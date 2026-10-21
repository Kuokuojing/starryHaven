#!/bin/zsh
# Builds build/StarryHaven.app. Model weights are not part of this repository;
# the bundle links to a local model directory when one is available.
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CONFIG=${1:-release}
cd "$ROOT"

swift build -c "$CONFIG"

APP="$ROOT/build/StarryHaven.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONFIG/StarryHaven" "$APP/Contents/MacOS/StarryHaven"
cp "$ROOT/Scripts/Info.plist" "$APP/Contents/Info.plist"
if [[ -d "$ROOT/Assets" ]]; then
    cp "$ROOT/Assets"/*.png "$ROOT/Assets/AppIcon.icns" "$APP/Contents/Resources/"
fi

SUPPORT="$HOME/Library/Application Support/StarryHaven"
MODELS="${STARRYHAVEN_MODELS_DIR:-}"
if [[ -z "$MODELS" ]]; then
    for candidate in "$ROOT/Models" "$SUPPORT/Models"; do
        if [[ -d "$candidate" ]]; then MODELS="$candidate"; break; fi
    done
fi

if [[ -n "$MODELS" && -d "$MODELS" ]]; then
    mkdir -p "$APP/Contents/Resources/Models"
    for item in split clean skyseg lensfun; do
        [[ -e "$MODELS/$item" ]] && ln -sfn "$MODELS/$item" "$APP/Contents/Resources/Models/$item"
    done
    echo "Linked local model assets from $MODELS"
else
    echo "No local models found; set STARRYHAVEN_MODELS_DIR or create ~/Library/Application Support/StarryHaven/Models"
fi

for lcp in "$ROOT/Assets/LensProfiles.zip" "$SUPPORT/LensProfiles.zip"; do
    if [[ -f "$lcp" ]]; then
        ln -sfn "$lcp" "$APP/Contents/Resources/LensProfiles.zip"
        break
    fi
done

RUNTIME="${ONNXRUNTIME_LIB:-$SUPPORT/libonnxruntime.dylib}"
if [[ -f "$RUNTIME" ]]; then
    ln -sfn "$RUNTIME" "$APP/Contents/Resources/libonnxruntime.dylib"
fi

# Ad-hoc signature so Gatekeeper treats the locally built bundle consistently.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP"
