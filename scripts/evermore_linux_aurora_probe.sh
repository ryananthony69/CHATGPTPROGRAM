#!/usr/bin/env bash
set -Eeuo pipefail
mkdir -p artifacts /tmp/evermore
PKG='com.evermoregames.evermorearcade'
AURORA='com.aurora.store'
REF_CUSTOM='evermorearcade://referral?code=J32R6Q'
REF_HTTPS='https://evermoregamesllc.com/referral?code=J32R6Q'

exec > >(tee artifacts/controller.log) 2>&1

snap() {
  local n="$1"
  adb exec-out screencap -p > "artifacts/${n}.png" || true
  adb shell uiautomator dump /sdcard/window.xml >/dev/null 2>&1 || true
  adb pull /sdcard/window.xml "artifacts/${n}.xml" >/dev/null 2>&1 || true
  adb shell dumpsys activity activities > "artifacts/${n}-activities.txt" 2>&1 || true
  adb shell dumpsys window windows > "artifacts/${n}-windows.txt" 2>&1 || true
}
installed() { adb shell pm path "$PKG" 2>/dev/null | grep -q '^package:'; }

cat > /tmp/evermore/ui.py <<'PY'
import re, subprocess, sys, xml.etree.ElementTree as ET

def adb(*args):
    return subprocess.run(['adb', *args], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                          text=True, timeout=40).stdout
adb('shell','uiautomator','dump','/sdcard/window.xml')
adb('pull','/sdcard/window.xml','/tmp/evermore/window.xml')
root=ET.parse('/tmp/evermore/window.xml').getroot()
nodes=[]
for e in root.iter('node'):
    a=e.attrib
    m=re.fullmatch(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]', a.get('bounds',''))
    if not m: continue
    x1,y1,x2,y2=map(int,m.groups())
    nodes.append((a.get('text',''),a.get('content-desc',''),a.get('resource-id',''),a.get('clickable')=='true',(x1+x2)//2,(y1+y2)//2))
cmd=sys.argv[1]
if cmd=='dump':
    print(' | '.join(v for n in nodes for v in n[:3] if isinstance(v,str) and v))
    raise SystemExit(0)
pat=re.compile(sys.argv[2],re.I)
exact=cmd=='tap-exact'
choices=[]
for n in nodes:
    vals=n[:3]
    if any((pat.fullmatch(v) if exact else pat.search(v)) for v in vals if v):
        choices.append(n)
if not choices: raise SystemExit(1)
choices.sort(key=lambda n:(0 if n[3] else 1,n[5]))
n=choices[0]
adb('shell','input','tap',str(n[4]),str(n[5]))
print(n)
PY
ui(){ python3 /tmp/evermore/ui.py "$@"; }

adb devices -l | tee artifacts/adb-devices.txt
adb shell getprop > artifacts/getprop.txt
adb shell getprop ro.product.cpu.abilist | tee artifacts/abilist.txt
adb shell getprop ro.dalvik.vm.native.bridge | tee artifacts/native-bridge.txt
adb shell getprop ro.build.version.release | tee artifacts/android-version.txt
adb shell settings put global window_animation_scale 0 || true
adb shell settings put global transition_animation_scale 0 || true
adb shell settings put global animator_duration_scale 0 || true
adb shell settings put global package_verifier_enable 0 || true
adb shell settings put global verifier_verify_adb_installs 0 || true

curl --fail --location --retry 6 --retry-all-errors --connect-timeout 30 --max-time 600 \
  'https://f-droid.org/repo/com.aurora.store_75.apk' -o /tmp/evermore/AuroraStore.apk
sha256sum /tmp/evermore/AuroraStore.apk | tee artifacts/aurora-sha256.txt
adb install -r -g /tmp/evermore/AuroraStore.apk | tee artifacts/aurora-install.txt
adb shell appops set "$AURORA" REQUEST_INSTALL_PACKAGES allow || true
adb shell appops set "$AURORA" RUN_IN_BACKGROUND allow || true
adb shell appops set "$AURORA" RUN_ANY_IN_BACKGROUND allow || true
adb shell dumpsys deviceidle whitelist +"$AURORA" || true

adb shell monkey -p "$AURORA" -c android.intent.category.LAUNCHER 1 > artifacts/aurora-first-launch.txt 2>&1 || true
sleep 7
snap 01-aurora-welcome
for i in $(seq 1 35); do
  screen="$(ui dump 2>/dev/null || true)"
  echo "onboarding[$i] $screen"
  if grep -qi 'Anonymous' <<<"$screen"; then break; fi
  ui tap-exact '^Skip$' || ui tap-exact '^Next$' || ui tap-exact '^Finish$' || ui tap 'Continue|Accept|Agree|OK' || true
  sleep 3
done
snap 02-aurora-login
ui tap-exact '^Anonymous$' || adb shell input tap 540 1985 || true
sleep 12

login=no
for i in $(seq 1 75); do
  screen="$(ui dump 2>/dev/null || true)"
  echo "login[$i] $screen"
  if grep -Eqi 'Games|Apps|For you|Top charts|Categories|Updates|Search' <<<"$screen"; then login=yes; break; fi
  ui tap 'Continue|Proceed|Accept|Agree|OK|Retry|Try again|Anonymous' || true
  if (( i % 12 == 0 )); then snap "aurora-login-${i}"; fi
  sleep 4
done
echo "anonymous_login=$login" | tee artifacts/login-status.txt
snap 03-aurora-after-login

if [[ "$login" == yes ]]; then
  adb shell am start -W -a android.intent.action.VIEW -d "market://details?id=$PKG" -p "$AURORA" \
    | tee artifacts/aurora-evermore-deeplink.txt || true
  sleep 15
  snap 04-evermore-listing
  for i in $(seq 1 180); do
    installed && break
    screen="$(ui dump 2>/dev/null || true)"
    echo "install[$i] $screen"
    ui tap-exact '^Install$' || ui tap-exact '^Download$' || ui tap-exact '^Get$' || \
      ui tap 'Install anyway|Continue|Allow from this source|Allow|OK|Done|Retry|Try again' || true
    if (( i % 12 == 0 )); then snap "install-progress-${i}"; fi
    sleep 4
  done
fi

INSTALLED=no
installed && INSTALLED=yes
adb shell pm path "$PKG" | tee artifacts/package-paths.txt || true
adb shell dumpsys package "$PKG" > artifacts/package-dump.txt 2>&1 || true
adb shell cmd package query-activities -a android.intent.action.VIEW -c android.intent.category.BROWSABLE -d "$REF_CUSTOM" > artifacts/custom-referral-handlers.txt 2>&1 || true
adb shell cmd package query-activities -a android.intent.action.VIEW -c android.intent.category.BROWSABLE -d "$REF_HTTPS" > artifacts/https-referral-handlers.txt 2>&1 || true

if [[ "$INSTALLED" == yes ]]; then
  adb logcat -c || true
  adb shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 | tee artifacts/first-launch.txt || true
  sleep 20; snap 05-evermore-first-launch-20s
  sleep 30; snap 06-evermore-first-launch-50s
  adb shell am force-stop "$PKG" || true
  adb shell am start -W -a android.intent.action.VIEW -c android.intent.category.BROWSABLE -d "$REF_CUSTOM" -p "$PKG" | tee artifacts/custom-referral-launch.txt || true
  sleep 15; snap 07-custom-referral-15s
  sleep 30; snap 08-custom-referral-45s
  adb shell am force-stop "$PKG" || true
  adb shell am start -W -a android.intent.action.VIEW -c android.intent.category.BROWSABLE -d "$REF_HTTPS" -p "$PKG" | tee artifacts/https-referral-launch.txt || true
  sleep 15; snap 09-https-referral-15s
fi

adb shell dumpsys activity activities > artifacts/activities.txt 2>&1 || true
adb shell dumpsys window windows > artifacts/windows.txt 2>&1 || true
adb logcat -d -v threadtime > artifacts/logcat.txt 2>&1 || true
TOP="$(adb shell dumpsys activity activities | grep -E 'mResumedActivity|topResumedActivity' | head -1 | tr -d '\r' || true)"
{
 echo "installed=$INSTALLED"
 echo "anonymous_login=$login"
 echo "package=$PKG"
 echo "custom_referral=$REF_CUSTOM"
 echo "https_referral=$REF_HTTPS"
 echo "guest_abilist=$(adb shell getprop ro.product.cpu.abilist | tr -d '\r')"
 echo "native_bridge=$(adb shell getprop ro.dalvik.vm.native.bridge | tr -d '\r')"
 echo "top_activity=$TOP"
} | tee artifacts/RESULT.txt
[[ "$INSTALLED" == yes ]]
