#!/usr/bin/env python3
"""Inspect the actual signed Android export; no headset connection required."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('apk', type=Path)
    parser.add_argument('--sdk', type=Path, default=Path(os.environ.get('ANDROID_HOME', '/opt/homebrew/share/android-commandlinetools')))
    args = parser.parse_args()
    apk = args.apk.resolve()
    versions = sorted((args.sdk / 'build-tools').iterdir(), key=lambda p: tuple(int(v) for v in p.name.split('.') if v.isdigit()))
    build_tools = versions[-1]
    environment = os.environ.copy()
    if not environment.get('JAVA_HOME') and Path('/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home').exists():
        environment['JAVA_HOME'] = '/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home'
    def command(*parts):
        return subprocess.check_output(list(map(str, parts)), stderr=subprocess.STDOUT, text=True, env=environment)
    badging = command(build_tools / 'aapt', 'dump', 'badging', apk)
    manifest = command(build_tools / 'aapt', 'dump', 'xmltree', apk, 'AndroidManifest.xml')
    signing = command(build_tools / 'apksigner', 'verify', '--verbose', apk)
    with zipfile.ZipFile(apk) as archive:
        names = archive.namelist()
        libraries = [name for name in names if name.startswith('lib/') and name.endswith('.so')]
        forbidden = [name for name in names if any('/' + folder + '/' in name for folder in ('artifacts', 'tests', 'tools'))]
        notices = [name for name in names if name.endswith('THIRD_PARTY_NOTICES.txt')]
    checks = {
        'package_identity': "name='com.soaring.godotsol'" in badging,
        'app_label': "application-label:'Soaring godot-sol'" in badging,
        'arm64_only': libraries and all(name.startswith('lib/arm64-v8a/') for name in libraries),
        'godot_and_vendor_libraries': any(name.endswith('/libgodot_android.so') for name in libraries) and any(name.endswith('/libgodotopenxrvendors.so') for name in libraries),
        'one_openxr_loader': sum(name.endswith('/libopenxr_loader.so') for name in libraries) == 1,
        'vr_launch_category': 'com.oculus.intent.category.VR' in manifest,
        'quest_pro_support': 'questpro' in manifest.lower(),
        'openxr_permissions': 'org.khronos.openxr.permission.OPENXR' in badging,
        'no_unneeded_permissions': not any('android.permission.' + name in badging for name in ('INTERNET', 'CAMERA', 'RECORD_AUDIO', 'READ_EXTERNAL_STORAGE', 'WRITE_EXTERNAL_STORAGE')),
        'test_and_diagnostic_files_excluded': not forbidden,
        'third_party_notices_bundled': bool(notices),
        'signature_verified': 'Verifies' in signing,
    }
    evidence = {'apk':str(apk),'bytes':apk.stat().st_size,'sha256':hashlib.sha256(apk.read_bytes()).hexdigest(),'checks':checks,'libraries':libraries,'signing':signing,'manifest':manifest}
    (ROOT / 'artifacts/apk-verification.json').write_text(json.dumps(evidence, indent=2))
    for name, passed in checks.items():
        print(('PASS ' if passed else 'FAIL ') + name)
    if not all(checks.values()):
        raise SystemExit(1)
    print(f'All {len(checks)} APK checks passed ({apk.stat().st_size / 1024 / 1024:.1f} MiB).')


if __name__ == '__main__':
    main()
