#!/usr/bin/env bash
set -euo pipefail
PORT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APK="${1:-$PORT_ROOT/Builds/Soaring.apk}"
ANDROID_TOOLS="/Applications/Unity/Hub/Editor/6000.6.4f1/PlaybackEngines/AndroidPlayer"
AAPT="$ANDROID_TOOLS/SDK/build-tools/36.0.0/aapt2"
mkdir -p "$PORT_ROOT/Logs"
"$AAPT" dump badging "$APK" > "$PORT_ROOT/Logs/apk-badging.txt"
"$AAPT" dump xmltree "$APK" --file AndroidManifest.xml > "$PORT_ROOT/Logs/apk-manifest.txt"
python3 - "$APK" "$PORT_ROOT/Logs/apk-manifest.txt" <<'PY'
import sys,zipfile
from pathlib import Path
apk=Path(sys.argv[1]); manifest=Path(sys.argv[2]).read_text()
with zipfile.ZipFile(apk) as z:
 assert z.testzip() is None, 'Damaged APK'
 libs=[n for n in z.namelist() if n.startswith('lib/') and n.endswith('.so')]
 assert libs and all(n.startswith('lib/arm64-v8a/') for n in libs), 'Expected ARM64 only'
 assert 'lib/arm64-v8a/libil2cpp.so' in libs, 'Missing IL2CPP'
 assert any('openxr' in n.lower() for n in libs), 'Missing OpenXR'
for value in ['com.soaring.unity','cambria','android.hardware.vr.headtracking','com.oculus.intent.category.VR']:
 assert value in manifest, 'Missing manifest value: '+value
print('SOARING_APK_VERIFIED',apk.stat().st_size//1048576,'MiB',len(libs),'ARM64 native libraries')
PY
"$ANDROID_TOOLS/OpenJDK/bin/java" -jar "$ANDROID_TOOLS/SDK/build-tools/36.0.0/lib/apksigner.jar" verify --verbose "$APK"
