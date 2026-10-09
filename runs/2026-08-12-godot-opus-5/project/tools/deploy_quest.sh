#!/usr/bin/env bash
# Build, install, launch and *verify* on a connected Quest.
#
#   tools/deploy_quest.sh
#
# The verify step is the point. Deploying this game by hand once left a fix
# sitting in a local file while the headset ran an older APK, and the resulting
# "the bug persists" cost a whole debugging session. Every build now carries a
# stamp, and this script refuses to claim success until it has read that exact
# stamp back out of the device's log.
set -uo pipefail
cd "$(dirname "$0")/.."

JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home}"
ANDROID_HOME="${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}"
export JAVA_HOME ANDROID_HOME
export PATH="$JAVA_HOME/bin:$PATH"

PACKAGE=com.soaring.opus5
ACTIVITY="$PACKAGE/com.godot.game.GodotAppLauncher"

stamp="$(git rev-parse --short HEAD 2>/dev/null || echo nogit)-$(date +%H%M%S)"
echo "$stamp" > build_stamp.txt
echo "== stamping build $stamp"

echo "== importing"
godot --headless --xr-mode off --import >/dev/null 2>&1

echo "== exporting"
rm -f build/Soaring.apk
if ! godot --headless --xr-mode off --export-debug "Meta Quest" build/Soaring.apk \
     > /tmp/soaring_export.log 2>&1 || [ ! -f build/Soaring.apk ]; then
  echo "FAIL: export produced no APK"; tail -20 /tmp/soaring_export.log; exit 1
fi
ls -la build/Soaring.apk

if ! adb get-state >/dev/null 2>&1; then
  echo "FAIL: no device connected"; exit 1
fi

echo "== installing"
adb install -r build/Soaring.apk 2>&1 | tail -1

echo "== launching"
# Force-stop first. Without it, `am start` on an already-running app merely
# brings it back to the front: no restart, no fresh log, and the stamp check
# below reports "unknown" while an old process keeps running the old code.
adb shell am force-stop "$PACKAGE" >/dev/null 2>&1
sleep 2
# The device churns its default log buffer in seconds under Meta's own spam,
# and world generation takes the better part of a minute on the headset CPU —
# so the startup line is long gone by the time a fixed sleep finishes. Enlarge
# the buffer and poll for the stamp instead of guessing at a delay.
adb logcat -G 16M >/dev/null 2>&1
adb logcat -c
adb shell am start -n "$ACTIVITY" >/dev/null 2>&1

deadline=$(( $(date +%s) + 120 ))
running=""
while [ "$(date +%s)" -lt "$deadline" ]; do
  running="$(adb logcat -d -s godot 2>/dev/null \
    | grep -oE "build [a-z0-9]+-[0-9]+" | tail -1 | cut -d' ' -f2)"
  [ -n "$running" ] && break
  sleep 5
done

if ! adb shell pidof "$PACKAGE" >/dev/null 2>&1; then
  echo "FAIL: app is not running."
  if adb logcat -d 2>/dev/null | grep -q RequiresControllersLaunchInterceptor; then
    echo "      The headset is refusing to launch it because the controllers"
    echo "      are asleep. Wake them and re-run."
  fi
  exit 1
fi

if [ "$running" != "$stamp" ]; then
  echo "FAIL: device is running build '${running:-unknown}', expected '$stamp'"
  exit 1
fi

echo "== running build $running, verified on device"
adb logcat -d -s godot 2>/dev/null | grep -E "\[diag\]|\[Soaring\]" | tail -8
