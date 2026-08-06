#!/usr/bin/env bash
set -Eeuo pipefail

mkdir -p artifacts /tmp/evermore-runtime /tmp/qoo-cache
exec > >(tee artifacts/qooapp-native.log) 2>&1

EVERMORE_PKG='com.evermoregames.evermorearcade'
QOOAPP_PKG='com.qooapp.qoohelper'
QOOAPP_APK_URL='https://d.qoo-apk.com/QooApp.apk'
QOOAPP_APP_ID='150473'
REFERRAL_URI='evermorearcade://referral?code=J32R6Q'
REFERRAL_PAGE='https://evermoregamesllc.com/referral?code=J32R6Q'

printf 'macos=%s\narch=%s\n' "$(sw_vers -productVersion)" "$(uname -m)" | tee artifacts/host.txt
test "$(uname -m)" = x86_64

snap() {
  local name="$1"
  adb exec-out screencap -p > "artifacts/${name}.png" || true
  adb shell uiautomator dump /sdcard/window.xml >/dev/null 2>&1 || true
  adb pull /sdcard/window.xml "artifacts/${name}.xml" >/dev/null 2>&1 || true
}

installed() {
  adb shell pm path "$EVERMORE_PKG" 2>/dev/null | grep -q '^package:'
}

cat > /tmp/ui.py <<'PY'
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

def adb(*args, timeout=40):
    return subprocess.run(['adb', *args], stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, text=True,
                          timeout=timeout, check=False).stdout

adb('shell', 'uiautomator', 'dump', '/sdcard/window.xml')
adb('pull', '/sdcard/window.xml', '/tmp/window.xml')
root = ET.parse('/tmp/window.xml').getroot()
nodes = []
for element in root.iter('node'):
    a = element.attrib
    match = re.fullmatch(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]', a.get('bounds', ''))
    if not match:
        continue
    x1, y1, x2, y2 = map(int, match.groups())
    nodes.append({
        'text': a.get('text', '').strip(),
        'desc': a.get('content-desc', '').strip(),
        'rid': a.get('resource-id', '').strip(),
        'class': a.get('class', ''),
        'clickable': a.get('clickable') == 'true',
        'enabled': a.get('enabled') != 'false',
        'x': (x1 + x2) // 2,
        'y': (y1 + y2) // 2,
    })

def vals(n):
    return (n['text'], n['desc'], n['rid'])

cmd = sys.argv[1]
if cmd == 'dump':
    print(' | '.join(v for n in nodes for v in (n['text'], n['desc']) if v))
    raise SystemExit(0)

pattern = re.compile(sys.argv[2], re.I)
exact = cmd == 'tap-exact'
candidates = []
for n in nodes:
    if not n['enabled']:
        continue
    if any((pattern.fullmatch(v) if exact else pattern.search(v)) for v in vals(n) if v):
        candidates.append(n)
if not candidates:
    raise SystemExit(1)
candidates.sort(key=lambda n: (0 if n['clickable'] else 1, n['y']))
n = candidates[0]
adb('shell', 'input', 'tap', str(n['x']), str(n['y']))
print(n)
PY

ui() { python3 /tmp/ui.py "$@"; }

echo '=== Download QooApp first ==='
curl --fail --location --retry 6 --retry-all-errors --connect-timeout 30 --max-time 600 \
  "$QOOAPP_APK_URL" -o /tmp/evermore-runtime/QooApp.apk
test "$(head -c 2 /tmp/evermore-runtime/QooApp.apk)" = 'PK'
unzip -tq /tmp/evermore-runtime/QooApp.apk >/dev/null
shasum -a 256 /tmp/evermore-runtime/QooApp.apk | tee artifacts/qooapp-sha256.txt
ls -lh /tmp/evermore-runtime/QooApp.apk | tee artifacts/qooapp-size.txt

# Record QooApp manifest/deeplink information before boot.
if command -v aapt >/dev/null 2>&1; then
  aapt dump badging /tmp/evermore-runtime/QooApp.apk > artifacts/qooapp-badging.txt 2>&1 || true
  aapt dump xmltree /tmp/evermore-runtime/QooApp.apk AndroidManifest.xml > artifacts/qooapp-manifest.txt 2>&1 || true
fi

echo '=== Download official Intel Android runtime ==='
export ANDROID_SDK_ROOT="$RUNNER_TEMP/android-sdk"
export ANDROID_HOME="$ANDROID_SDK_ROOT"
mkdir -p "$ANDROID_SDK_ROOT"
python3 - <<'PY'
import re
import urllib.request
from pathlib import Path

def fetch(url):
    req = urllib.request.Request(url, headers={'User-Agent': 'AndroidSDKManager/1.0'})
    with urllib.request.urlopen(req, timeout=120) as response:
        return response.read().decode('utf-8', 'replace')

repository = fetch('https://dl.google.com/android/repository/repository2-3.xml')
images = fetch('https://dl.google.com/android/repository/sys-img/google_apis/sys-img2-3.xml')
emulators = [(int(build), name) for name, build in re.findall(
    r'<url>(emulator-darwin_x64-(\d+)\.zip)</url>', repository)]
sysimgs = [(int(api), int(rev), name) for name, api, rev in re.findall(
    r'<url>(x86_64-(\d+)_r(\d+)\.zip)</url>', images)]
if not emulators:
    raise SystemExit('No official Intel macOS emulator archive found')
compatible = [x for x in sysimgs if 31 <= x[0] <= 35]
if not compatible:
    raise SystemExit('No API 31-35 Google APIs x86_64 image found')
_, emulator = max(emulators)
api, _, image = max(compatible)
vals = {
    'ANDROID_API': str(api),
    'EMULATOR_URL': 'https://dl.google.com/android/repository/' + emulator,
    'PLATFORM_TOOLS_URL': 'https://dl.google.com/android/repository/platform-tools-latest-darwin.zip',
    'SYSTEM_IMAGE_URL': 'https://dl.google.com/android/repository/sys-img/google_apis/' + image,
}
Path('/tmp/evermore-runtime/runtime.env').write_text(''.join(f'{k}={v}\n' for k,v in vals.items()))
print(vals)
PY
source /tmp/evermore-runtime/runtime.env
cat /tmp/evermore-runtime/runtime.env | tee artifacts/runtime-urls.txt

curl --fail --location --retry 6 --retry-all-errors --connect-timeout 30 --max-time 900 \
  "$EMULATOR_URL" -o /tmp/evermore-runtime/emulator.zip
curl --fail --location --retry 6 --retry-all-errors --connect-timeout 30 --max-time 600 \
  "$PLATFORM_TOOLS_URL" -o /tmp/evermore-runtime/platform-tools.zip
curl --fail --location --retry 6 --retry-all-errors --connect-timeout 30 --max-time 1200 \
  "$SYSTEM_IMAGE_URL" -o /tmp/evermore-runtime/system-image.zip
for archive in /tmp/evermore-runtime/*.zip; do
  test "$(head -c 2 "$archive")" = 'PK'
  unzip -tq "$archive" >/dev/null
done
shasum -a 256 /tmp/evermore-runtime/*.zip | tee artifacts/runtime-sha256.txt

unzip -q /tmp/evermore-runtime/emulator.zip -d "$ANDROID_SDK_ROOT"
unzip -q /tmp/evermore-runtime/platform-tools.zip -d "$ANDROID_SDK_ROOT"
IMAGE_PARENT="$ANDROID_SDK_ROOT/system-images/android-$ANDROID_API/google_apis"
mkdir -p "$IMAGE_PARENT"
unzip -q /tmp/evermore-runtime/system-image.zip -d "$IMAGE_PARENT"
IMAGE_FILE=$(find "$IMAGE_PARENT" -type f -name system.img -print -quit)
test -n "$IMAGE_FILE"
IMAGE_DIR=$(dirname "$IMAGE_FILE")
chmod +x "$ANDROID_SDK_ROOT/emulator/emulator" "$ANDROID_SDK_ROOT/platform-tools/adb"
export PATH="$ANDROID_SDK_ROOT/platform-tools:$ANDROID_SDK_ROOT/emulator:$PATH"

echo '=== Create and boot Android ==='
AVD="$HOME/.android/avd/evermore.avd"
mkdir -p "$AVD"
cat > "$HOME/.android/avd/evermore.ini" <<EOF
avd.ini.encoding=UTF-8
path=$AVD
path.rel=avd/evermore.avd
target=android-$ANDROID_API
EOF
cat > "$AVD/config.ini" <<EOF
AvdId=evermore
PlayStore.enabled=false
abi.type=x86_64
avd.ini.displayname=Evermore QooApp Intel
avd.ini.encoding=UTF-8
disk.dataPartition.size=12G
fastboot.forceColdBoot=yes
fastboot.forceFastBoot=no
hw.accelerometer=yes
hw.audioInput=no
hw.battery=yes
hw.camera.back=none
hw.camera.front=none
hw.cpu.arch=x86_64
hw.cpu.ncore=4
hw.gps=yes
hw.gpu.enabled=yes
hw.gpu.mode=auto
hw.keyboard=yes
hw.lcd.density=420
hw.lcd.height=2400
hw.lcd.width=1080
hw.mainKeys=no
hw.ramSize=6144
image.sysdir.1=$IMAGE_DIR/
runtime.network.latency=none
runtime.network.speed=full
sdcard.size=1024M
showDeviceFrame=no
skin.dynamic=yes
skin.name=1080x2400
skin.path=_no_skin
tag.display=Google APIs
tag.id=google_apis
vm.heapSize=768
EOF

"$ANDROID_SDK_ROOT/emulator/emulator" -version | tee artifacts/emulator-version.txt
nohup "$ANDROID_SDK_ROOT/emulator/emulator" @evermore \
  -no-window -gpu swiftshader_indirect -no-snapshot -noaudio -no-boot-anim \
  -camera-back none -camera-front none -memory 6144 -cores 4 -netdelay none -netspeed full \
  > artifacts/emulator.log 2>&1 &
echo $! > artifacts/emulator.pid

adb_ready=no
for i in $(seq 1 240); do
  if adb get-state >/dev/null 2>&1; then adb_ready=yes; break; fi
  sleep 3
done
test "$adb_ready" = yes
booted=no
for i in $(seq 1 240); do
  if [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; then booted=yes; break; fi
  sleep 3
done
test "$booted" = yes
adb shell input keyevent 82 || true
adb shell settings put global window_animation_scale 0
adb shell settings put global transition_animation_scale 0
adb shell settings put global animator_duration_scale 0
adb shell settings put global package_verifier_enable 0 || true
adb shell settings put global verifier_verify_adb_installs 0 || true
adb shell svc wifi enable || true
adb shell svc data enable || true
adb devices -l | tee artifacts/adb-devices.txt
adb shell getprop ro.product.cpu.abilist | tee artifacts/abilist.txt
adb shell getprop ro.dalvik.vm.native.bridge | tee artifacts/native-bridge.txt

echo '=== Install and launch QooApp ==='
adb install -r -g /tmp/evermore-runtime/QooApp.apk | tee artifacts/qooapp-install.txt
adb shell appops set "$QOOAPP_PKG" REQUEST_INSTALL_PACKAGES allow || true
adb shell appops set "$QOOAPP_PKG" MANAGE_EXTERNAL_STORAGE allow || true
adb shell appops set "$QOOAPP_PKG" RUN_IN_BACKGROUND allow || true
adb shell appops set "$QOOAPP_PKG" RUN_ANY_IN_BACKGROUND allow || true
adb shell dumpsys deviceidle whitelist +"$QOOAPP_PKG" || true
adb shell monkey -p "$QOOAPP_PKG" -c android.intent.category.LAUNCHER 1 >/dev/null || true
sleep 10
snap 01-qooapp-launch

for i in $(seq 1 35); do
  screen=$(ui dump 2>/dev/null || true)
  echo "onboarding[$i] $screen"
  if printf '%s' "$screen" | grep -Eqi 'Search|Games|Home|Featured|Updates|Ranking'; then break; fi
  ui tap 'Agree|Accept|Continue|Start|Skip|Next|Got it|I understand|Allow|OK|Later|Not now' || true
  sleep 3
done
snap 02-qooapp-ready

echo '=== Open Evermore catalog in QooApp ==='
opened=no
for target in \
  "https://apps.qoo-app.com/en/app/$QOOAPP_APP_ID" \
  "https://m-apps.qoo-app.com/en-US/app/$QOOAPP_APP_ID" \
  "qooapp://app/$QOOAPP_APP_ID" \
  "qooapp://apps/$QOOAPP_APP_ID"; do
  echo "target=$target"
  adb shell am start -W -a android.intent.action.VIEW -d "$target" -p "$QOOAPP_PKG" || true
  sleep 8
  screen=$(ui dump 2>/dev/null || true)
  echo "$screen"
  if printf '%s' "$screen" | grep -Eqi 'Evermore|Download|Install'; then opened=yes; break; fi
done
snap 03-qooapp-evermore-deeplink

if [ "$opened" != yes ]; then
  echo '=== QooApp search fallback ==='
  adb shell monkey -p "$QOOAPP_PKG" -c android.intent.category.LAUNCHER 1 >/dev/null || true
  sleep 4
  ui tap 'Search|搜尋|検索' || true
  sleep 3
  adb shell input text 'Evermore%20Arcade'
  adb shell input keyevent 66
  sleep 12
  snap 04-qooapp-search-results
  ui tap 'Evermore' || true
  sleep 10
fi
snap 05-qooapp-evermore-detail

echo '=== Download/install Evermore through QooApp ==='
for i in $(seq 1 180); do
  installed && break
  screen=$(ui dump 2>/dev/null || true)
  echo "install[$i] $screen"
  ui tap-exact '^Download$' || ui tap-exact '^Install$' || ui tap-exact '^Get$' || \
    ui tap 'Update|Continue|Allow|Settings|Install anyway|OK|Done|Retry|Try again' || true

  if printf '%s' "$screen" | grep -qi 'Allow from this source'; then
    # Find/tap a switch if exposed, otherwise tap the standard switch region.
    adb shell input tap 930 390 || true
    sleep 2
    adb shell input keyevent 4 || true
  fi
  if (( i % 15 == 0 )); then snap "install-progress-${i}"; fi
  sleep 4
done

if ! installed; then
  echo '=== QooApp private/external cache fallback ==='
  adb root || true
  adb wait-for-device
  for i in $(seq 1 120); do
    [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ] && break
    sleep 2
  done
  adb shell find "/data/user/0/$QOOAPP_PKG" "/sdcard/Android/data/$QOOAPP_PKG" /sdcard/Download \
    -type f 2>/dev/null | tee artifacts/qooapp-downloaded-files.txt || true
  adb pull "/data/user/0/$QOOAPP_PKG" /tmp/qoo-cache/private >/dev/null 2>&1 || true
  adb pull "/sdcard/Android/data/$QOOAPP_PKG" /tmp/qoo-cache/external >/dev/null 2>&1 || true

  # Identify Evermore APKs by package name using available Android build tools.
  AAPT=$(command -v aapt || true)
  if [ -z "$AAPT" ]; then
    AAPT=$(find "$ANDROID_SDK_ROOT/build-tools" -type f -name aapt -print 2>/dev/null | sort -V | tail -n1 || true)
  fi
  : > artifacts/qooapp-evermore-apks.txt
  if [ -n "$AAPT" ]; then
    while IFS= read -r apk; do
      if "$AAPT" dump badging "$apk" 2>/dev/null | head -n1 | grep -q "name='$EVERMORE_PKG'"; then
        printf '%s\n' "$apk" | tee -a artifacts/qooapp-evermore-apks.txt
      fi
    done < <(find /tmp/qoo-cache -type f -iname '*.apk' -print 2>/dev/null)
  fi
  mapfile -t APKS < artifacts/qooapp-evermore-apks.txt
  if [ "${#APKS[@]}" -gt 0 ]; then
    adb install-multiple -r -t -g "${APKS[@]}" | tee artifacts/qooapp-cache-install.txt || true
  fi
fi

echo '=== Verify Evermore and open referral ==='
if installed; then
  echo 'installed=yes' | tee artifacts/install-status.txt
  adb shell pm path "$EVERMORE_PKG" | tee artifacts/evermore-package-paths.txt
  adb shell dumpsys package "$EVERMORE_PKG" > artifacts/evermore-package.txt || true
  adb logcat -c || true
  adb shell monkey -p "$EVERMORE_PKG" -c android.intent.category.LAUNCHER 1 | tee artifacts/evermore-first-launch.txt || true
  sleep 20
  snap 06-evermore-first-launch-20s
  sleep 25
  snap 07-evermore-first-launch-45s

  adb shell am force-stop "$EVERMORE_PKG" || true
  adb shell am start -W -a android.intent.action.VIEW -c android.intent.category.BROWSABLE \
    -d "$REFERRAL_URI" -p "$EVERMORE_PKG" | tee artifacts/referral-custom.txt || true
  sleep 12
  snap 08-referral-custom-12s
  sleep 25
  snap 09-referral-custom-37s

  adb shell am start -W -a android.intent.action.VIEW -c android.intent.category.BROWSABLE \
    -d "$REFERRAL_PAGE" -p "$EVERMORE_PKG" | tee artifacts/referral-https.txt || true
  sleep 12
  snap 10-referral-https
else
  echo 'installed=no' | tee artifacts/install-status.txt
fi

adb shell cmd package query-activities -a android.intent.action.VIEW -c android.intent.category.BROWSABLE \
  -d "$REFERRAL_URI" > artifacts/referral-custom-handlers.txt 2>&1 || true
adb shell cmd package query-activities -a android.intent.action.VIEW -c android.intent.category.BROWSABLE \
  -d "$REFERRAL_PAGE" > artifacts/referral-https-handlers.txt 2>&1 || true
adb shell dumpsys activity activities > artifacts/activities.txt || true
adb shell dumpsys window windows > artifacts/windows.txt || true
adb logcat -d -v threadtime > artifacts/logcat.txt || true
TOP=$(adb shell dumpsys activity activities | sed -n 's/.*mResumedActivity:.* \([^ ]*\) .*/\1/p' | head -n1 | tr -d '\r')
{
  echo "evermore_installed=$(installed && echo yes || echo no)"
  echo "top_activity=$TOP"
  echo "referral_uri=$REFERRAL_URI"
  echo "android=$(adb shell getprop ro.build.version.release | tr -d '\r')"
  echo "sdk=$(adb shell getprop ro.build.version.sdk | tr -d '\r')"
  echo "abilist=$(adb shell getprop ro.product.cpu.abilist | tr -d '\r')"
  echo "native_bridge=$(adb shell getprop ro.dalvik.vm.native.bridge | tr -d '\r')"
} | tee artifacts/RESULT.txt
