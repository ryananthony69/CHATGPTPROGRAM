#!/usr/bin/env bash
set -Eeuo pipefail

mkdir -p artifacts /tmp/qoo-fast-cache
exec > >(tee artifacts/fast-controller.log) 2>&1

EVERMORE_PKG='com.evermoregames.evermorearcade'
QOOAPP_PKG='com.qooapp.qoohelper'
QOOAPP_APP_ID='150473'
REFERRAL_URI='evermorearcade://referral?code=J32R6Q'
REFERRAL_PAGE='https://evermoregamesllc.com/referral?code=J32R6Q'

snap() {
  local name="$1"
  adb exec-out screencap -p > "artifacts/${name}.png" || true
  adb shell uiautomator dump /sdcard/window.xml >/dev/null 2>&1 || true
  adb pull /sdcard/window.xml "artifacts/${name}.xml" >/dev/null 2>&1 || true
}
installed() { adb shell pm path "$EVERMORE_PKG" 2>/dev/null | grep -q '^package:'; }

cat > /tmp/ui-fast.py <<'PY'
import re, subprocess, sys, xml.etree.ElementTree as ET

def adb(*args, timeout=30):
    return subprocess.run(['adb',*args], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                          text=True, timeout=timeout, check=False).stdout
adb('shell','uiautomator','dump','/sdcard/window.xml')
adb('pull','/sdcard/window.xml','/tmp/window.xml')
root=ET.parse('/tmp/window.xml').getroot(); nodes=[]
for e in root.iter('node'):
    a=e.attrib; m=re.fullmatch(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]',a.get('bounds',''))
    if not m: continue
    x1,y1,x2,y2=map(int,m.groups())
    nodes.append({'text':a.get('text','').strip(),'desc':a.get('content-desc','').strip(),
                  'rid':a.get('resource-id','').strip(),'class':a.get('class',''),
                  'click':a.get('clickable')=='true','enabled':a.get('enabled')!='false',
                  'x':(x1+x2)//2,'y':(y1+y2)//2,'bounds':a.get('bounds','')})
cmd=sys.argv[1]
if cmd=='dump':
    print(' | '.join(v for n in nodes for v in (n['text'],n['desc']) if v)); raise SystemExit(0)
if cmd=='tap-edit':
    c=[n for n in nodes if n['enabled'] and 'EditText' in n['class']]
else:
    pat=re.compile(sys.argv[2],re.I); exact=cmd=='tap-exact'; c=[]
    for n in nodes:
        if not n['enabled']: continue
        vals=(n['text'],n['desc'],n['rid'])
        if any((pat.fullmatch(v) if exact else pat.search(v)) for v in vals if v): c.append(n)
if not c: raise SystemExit(1)
c.sort(key=lambda n:(0 if n['click'] else 1,n['y']))
n=c[0]; adb('shell','input','tap',str(n['x']),str(n['y'])); print(n)
PY
ui(){ python3 /tmp/ui-fast.py "$@"; }

adb wait-for-device
until [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; do sleep 2; done
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

echo '=== install QooApp ==='
adb install -r -g /tmp/qooapp/QooApp.apk | tee artifacts/qooapp-install.txt
adb shell appops set "$QOOAPP_PKG" REQUEST_INSTALL_PACKAGES allow || true
adb shell appops set "$QOOAPP_PKG" MANAGE_EXTERNAL_STORAGE allow || true
adb shell appops set "$QOOAPP_PKG" RUN_IN_BACKGROUND allow || true
adb shell appops set "$QOOAPP_PKG" RUN_ANY_IN_BACKGROUND allow || true
adb shell dumpsys deviceidle whitelist +"$QOOAPP_PKG" || true
adb shell monkey -p "$QOOAPP_PKG" -c android.intent.category.LAUNCHER 1 >/dev/null || true
sleep 8
snap 01-qooapp-launch

for i in $(seq 1 20); do
  screen=$(ui dump 2>/dev/null || true); echo "onboard[$i] $screen"
  if printf '%s' "$screen" | grep -Eqi 'Search|Games|Home|Featured|Updates|Ranking|Store'; then break; fi
  ui tap 'Agree|Accept|Continue|Start|Skip|Next|Got it|I understand|Allow|OK|Later|Not now|Confirm' || true
  sleep 2
done
snap 02-qooapp-ready

echo '=== catalog deeplinks ==='
opened=no
for target in \
  "https://apps.qoo-app.com/en/app/$QOOAPP_APP_ID" \
  "https://m-apps.qoo-app.com/en-US/app/$QOOAPP_APP_ID" \
  "qooapp://app/$QOOAPP_APP_ID" \
  "qooapp://apps/$QOOAPP_APP_ID"; do
  echo "target=$target"
  adb shell am start -W -a android.intent.action.VIEW -d "$target" -p "$QOOAPP_PKG" || true
  sleep 5
  screen=$(ui dump 2>/dev/null || true); echo "$screen"
  if printf '%s' "$screen" | grep -Eqi 'Evermore|Download|Install'; then opened=yes; break; fi
done
snap 03-catalog-deeplink

if [ "$opened" != yes ]; then
  echo '=== search fallback ==='
  adb shell monkey -p "$QOOAPP_PKG" -c android.intent.category.LAUNCHER 1 >/dev/null || true
  sleep 3
  ui tap 'Search|搜尋|検索' || true
  sleep 2
  ui tap-edit '_' || true
  adb shell input text 'Evermore%20Arcade'
  adb shell input keyevent 66
  sleep 8
  snap 04-search-results
  ui tap 'Evermore' || true
  sleep 6
fi
snap 05-evermore-detail

# Short install loop: enough to initiate package download and handle system installer.
for i in $(seq 1 50); do
  installed && break
  screen=$(ui dump 2>/dev/null || true); echo "install[$i] $screen"
  ui tap-exact '^Download$' || ui tap-exact '^Install$' || ui tap-exact '^Get$' || \
    ui tap 'Update|Continue|Allow|Settings|Install anyway|OK|Done|Retry|Try again|Confirm' || true
  if printf '%s' "$screen" | grep -qi 'Allow from this source'; then
    ui tap 'Allow from this source' || adb shell input tap 930 390 || true
    sleep 1
    adb shell input keyevent 4 || true
  fi
  if (( i % 10 == 0 )); then snap "install-progress-${i}"; fi
  sleep 3
done

if ! installed; then
  echo '=== root and inspect every QooApp download location ==='
  adb root || true
  adb wait-for-device
  for i in $(seq 1 60); do
    [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ] && break
    sleep 2
  done
  adb shell find "/data/user/0/$QOOAPP_PKG" "/sdcard/Android/data/$QOOAPP_PKG" \
    /sdcard/QooApp /sdcard/QooApp/apk /sdcard/Download -type f 2>/dev/null \
    | tee artifacts/qooapp-downloaded-files.txt || true
  adb pull "/data/user/0/$QOOAPP_PKG" /tmp/qoo-fast-cache/private >/dev/null 2>&1 || true
  adb pull "/sdcard/Android/data/$QOOAPP_PKG" /tmp/qoo-fast-cache/external >/dev/null 2>&1 || true
  adb pull /sdcard/QooApp /tmp/qoo-fast-cache/qooapp-shared >/dev/null 2>&1 || true
  adb pull /sdcard/Download /tmp/qoo-fast-cache/download >/dev/null 2>&1 || true
  find /tmp/qoo-fast-cache -type f -printf '%s %p\n' 2>/dev/null | sort -n > artifacts/pulled-cache-files.txt || true

  # Try every APK group containing the Evermore package name according to aapt.
  AAPT=$(command -v aapt || true)
  if [ -z "$AAPT" ]; then AAPT=$(find "$ANDROID_HOME/build-tools" -type f -name aapt -print 2>/dev/null | sort -V | tail -n1 || true); fi
  : > artifacts/evermore-apk-candidates.txt
  if [ -n "$AAPT" ]; then
    while IFS= read -r apk; do
      if "$AAPT" dump badging "$apk" 2>/dev/null | head -n1 | grep -q "name='$EVERMORE_PKG'"; then
        printf '%s\n' "$apk" | tee -a artifacts/evermore-apk-candidates.txt
      fi
    done < <(find /tmp/qoo-fast-cache -type f -iname '*.apk' -print 2>/dev/null)
  fi
  mapfile -t APKS < artifacts/evermore-apk-candidates.txt
  if [ "${#APKS[@]}" -gt 0 ]; then
    adb install-multiple -r -t -g "${APKS[@]}" | tee artifacts/cache-install.txt || true
  fi
fi

echo '=== launch referral if installed ==='
if installed; then
  echo installed=yes | tee artifacts/install-status.txt
  adb shell pm path "$EVERMORE_PKG" | tee artifacts/evermore-package-paths.txt
  adb shell dumpsys package "$EVERMORE_PKG" > artifacts/evermore-package.txt || true
  adb logcat -c || true
  adb shell monkey -p "$EVERMORE_PKG" -c android.intent.category.LAUNCHER 1 | tee artifacts/first-launch.txt || true
  sleep 12; snap 06-evermore-first-launch
  adb shell am force-stop "$EVERMORE_PKG" || true
  adb shell am start -W -a android.intent.action.VIEW -c android.intent.category.BROWSABLE \
    -d "$REFERRAL_URI" -p "$EVERMORE_PKG" | tee artifacts/referral-custom.txt || true
  sleep 10; snap 07-referral-custom
  adb shell am start -W -a android.intent.action.VIEW -c android.intent.category.BROWSABLE \
    -d "$REFERRAL_PAGE" -p "$EVERMORE_PKG" | tee artifacts/referral-https.txt || true
  sleep 8; snap 08-referral-https
else
  echo installed=no | tee artifacts/install-status.txt
fi

adb shell cmd package query-activities -a android.intent.action.VIEW -c android.intent.category.BROWSABLE \
  -d "$REFERRAL_URI" > artifacts/referral-handlers.txt 2>&1 || true
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
