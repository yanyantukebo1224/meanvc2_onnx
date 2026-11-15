#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/example/assets/models"
REVISION="2db97430c6e315a819daa30e255e14615205a3d1"
BASE="https://huggingface.co/kiarina/MeanVC2-ONNX/resolve/$REVISION"

mkdir -p "$DEST"
MANIFEST="$(mktemp)"
trap 'rm -f "$MANIFEST"' EXIT
curl --retry 3 --retry-delay 2 --fail --location "$BASE/manifest.json" --output "$MANIFEST"

python3 - "$MANIFEST" "$DEST" "$BASE" <<'PY'
import hashlib
import json
import pathlib
import subprocess
import sys

manifest_path, destination, base = sys.argv[1:]
destination = pathlib.Path(destination)
manifest = json.loads(pathlib.Path(manifest_path).read_text())["files"]
names = [
    "fbank.onnx",
    "asr.int8.onnx",
    "gtm.onnx",
    "dit.int8.onnx",
    "vocos.int8.onnx",
    "speaker/speaker.int8.onnx",
]
for name in names:
    entry = manifest[name]
    target = destination / name
    target.parent.mkdir(parents=True, exist_ok=True)
    expected = entry["sha256"]
    if target.exists() and hashlib.sha256(target.read_bytes()).hexdigest() == expected:
        print(f"verified cached {name}")
        continue
    print(f"downloading {name} ({entry['bytes']} bytes)", flush=True)
    temporary = target.with_suffix(target.suffix + ".part")
    subprocess.run([
        "curl", "--retry", "3", "--retry-delay", "2", "--fail", "--location",
        f"{base}/{name}", "--output", str(temporary)
    ], check=True)
    actual = hashlib.sha256(temporary.read_bytes()).hexdigest()
    if actual != expected:
        temporary.unlink(missing_ok=True)
        raise SystemExit(f"SHA-256 mismatch for {name}: {actual} != {expected}")
    temporary.replace(target)
    print(f"verified {name}")
PY

cp "$ROOT/huggingface/NOTICE" "$DEST/NOTICE.txt"
mkdir -p "$DEST/licenses"
cp "$ROOT"/huggingface/licenses/*.txt "$DEST/licenses/"

echo "Bundled MeanVC2 int8 models and license notices are ready in $DEST"
