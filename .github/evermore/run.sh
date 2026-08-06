#!/usr/bin/env bash
set -Eeuo pipefail

mkdir -p artifacts
exec > >(tee artifacts/controller.log) 2>&1

snap() {
  local name="$1"
  adb exec-out screencap -p > "artifacts/${name}.png" || true
  adb shell uiautomator dump /sdcard/window.xml >/dev/null 2>&1 || true
  adb pull /sdcard/window.xml "artifacts/${name}.xml" >/dev/null 2>&1 || true
}

top_activity() {
  adb shell dumpsys activity activities 2>/dev/null \
    | sed -n 's/.*mResumedActivity:.* \([^ ]*\) .*/\1/p' \
    | head -n1 | tr -d '\r'
}

installed() {
  adb shell pm path "$PKG" 2>/dev/null | grep -q '^package:'
}

install_set() {
  local label="$1"
  shift
  local files=("$@")
  [ "${#files[@]}" -gt 0 ] || return 1
  echo "=== install attempt: $label (${#files[@]} files) ==="
  printf '%s\n' "${files[@]}" | tee "artifacts/install-${label}-apks.txt"
  set +e
  adb install-multiple -r -t -g "${files[@]}" 2>&1 \
    | tee "artifacts/install-${label}-result.txt"
  local rc=${PIPESTATUS[0]}
  set -e
  echo "$rc" > "artifacts/install-${label}-rc.txt"
  [ "$rc" -eq 0 ]
}

adb wait-for-device
until [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; do
  sleep 2
done
adb shell input keyevent 82 || true
adb shell settings put global window_animation_scale 0
adb shell settings put global transition_animation_scale 0
adb shell settings put global animator_duration_scale 0
adb shell settings put global package_verifier_enable 0 || true
adb shell settings put global verifier_verify_adb_installs 0 || true
adb shell svc wifi enable || true
adb shell svc data enable || true
adb devices -l | tee artifacts/adb-devices.txt
adb shell getprop > artifacts/getprop.txt
adb shell getprop ro.product.cpu.abilist | tee artifacts/abilist.txt
adb shell getprop ro.dalvik.vm.native.bridge | tee artifacts/native-bridge.txt
adb shell wm size | tee artifacts/display-size.txt

mapfile -t ALL_APKS < /tmp/apk-list.txt
COMMON=()
ARM64=()
V7A=()
for apk in "${ALL_APKS[@]}"; do
  lower=$(basename "$apk" | tr '[:upper:]' '[:lower:]')
  case "$lower" in
    *arm64*|*arm64_v8a*) ARM64+=("$apk") ;;
    *armeabi*v7a*|*armeabi_v7a*|*v7a*) V7A+=("$apk") ;;
    *) COMMON+=("$apk") ;;
  esac
done

install_ok=no
if install_set all "${ALL_APKS[@]}"; then
  install_ok=yes
elif [ "${#ARM64[@]}" -gt 0 ] && install_set arm64 "${COMMON[@]}" "${ARM64[@]}"; then
  install_ok=yes
elif [ "${#V7A[@]}" -gt 0 ] && install_set v7a "${COMMON[@]}" "${V7A[@]}"; then
  install_ok=yes
elif [ "${#COMMON[@]}" -gt 0 ] && install_set common "${COMMON[@]}"; then
  install_ok=yes
fi

echo "install_ok=$install_ok" | tee artifacts/install-status.txt

while IFS= read -r obb; do
  [ -n "$obb" ] || continue
  adb shell mkdir -p "/sdcard/Android/obb/$PKG"
  adb push "$obb" "/sdcard/Android/obb/$PKG/"
done < <(find /tmp/evermore-unpacked -type f -iname '*.obb' -print)

installed_state=no
custom_rc=-1
https_rc=-1
if installed; then
  installed_state=yes
  adb shell pm path "$PKG" | tee artifacts/package-paths.txt
  adb shell dumpsys package "$PKG" > artifacts/package.txt
  adb shell cmd package query-activities -a android.intent.action.VIEW \
    -c android.intent.category.BROWSABLE -d "$REFERRAL_URI" \
    > artifacts/custom-referral-handlers-before.txt 2>&1 || true

  adb logcat -c || true
  adb shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 \
    2>&1 | tee artifacts/first-launch.txt || true
  sleep 15
  snap 01-first-launch-15s
  sleep 30
  snap 02-first-launch-45s

  adb shell am force-stop "$PKG" || true
  set +e
  adb shell am start -W -a android.intent.action.VIEW \
    -c android.intent.category.BROWSABLE \
    -d "$REFERRAL_URI" -p "$PKG" \
    2>&1 | tee artifacts/custom-referral-launch.txt
  custom_rc=${PIPESTATUS[0]}
  set -e
  sleep 12
  snap 03-custom-referral-12s
  sleep 30
  snap 04-custom-referral-42s

  set +e
  adb shell am start -W -a android.intent.action.VIEW \
    -c android.intent.category.BROWSABLE \
    -d "$REFERRAL_PAGE" -p "$PKG" \
    2>&1 | tee artifacts/https-referral-launch.txt
  https_rc=${PIPESTATUS[0]}
  set -e
  sleep 12
  snap 05-https-referral-12s
fi

adb shell cmd package query-activities -a android.intent.action.VIEW \
  -c android.intent.category.BROWSABLE -d "$REFERRAL_URI" \
  > artifacts/custom-referral-handlers.txt 2>&1 || true
adb shell cmd package query-activities -a android.intent.action.VIEW \
  -c android.intent.category.BROWSABLE -d "$REFERRAL_PAGE" \
  > artifacts/https-referral-handlers.txt 2>&1 || true
adb shell dumpsys activity activities > artifacts/activities.txt || true
adb shell dumpsys window windows > artifacts/windows.txt || true
adb logcat -d -v threadtime > artifacts/logcat.txt || true

{
  echo "installed=$installed_state"
  echo "install_ok=$install_ok"
  echo "package=$PKG"
  echo "referral_uri=$REFERRAL_URI"
  echo "custom_launch_rc=$custom_rc"
  echo "https_launch_rc=$https_rc"
  echo "top_activity=$(top_activity)"
  echo "android=$(adb shell getprop ro.build.version.release | tr -d '\r')"
  echo "sdk=$(adb shell getprop ro.build.version.sdk | tr -d '\r')"
  echo "abilist=$(adb shell getprop ro.product.cpu.abilist | tr -d '\r')"
  echo "native_bridge=$(adb shell getprop ro.dalvik.vm.native.bridge | tr -d '\r')"
} | tee artifacts/RESULT.txt

test "$installed_state" = yes
