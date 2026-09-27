#!/bin/bash
# Decodes the downloaded audio candidates (assets/_candidates, ignored by
# Godot) into 32 kHz mono 16-bit PCM WAVs that Godot's AudioStreamWAV can
# load, for scripts/audio/tools/call_prep.gd. macOS only (afconvert).
#   scripts/audio/tools/decode_candidates.sh <out_dir>
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
OUT="${1:?usage: decode_candidates.sh <out_dir>}"
mkdir -p "$OUT"
cd "$ROOT/assets/_candidates"
for f in nps/*.mp3 wikimedia/*.ogg wikimedia/*.mp3 wikimedia/*.wav oga/*.ogg oga/*.mp3 oga/*.wav oga/sfx_loops/*.ogg; do
	b=$(echo "$f" | tr '/' '_'); b="${b%.*}"
	afconvert -f WAVE -d LEI16@32000 -c 1 "$f" "$OUT/$b.wav"
done
# afconvert writes WAVE_FORMAT_EXTENSIBLE headers, which Godot rejects.
python3 "$ROOT/scripts/audio/tools/plain_pcm_wav.py" "$OUT"/*.wav
echo "[audio] decoded $(ls "$OUT"/*.wav | wc -l) files into $OUT"
