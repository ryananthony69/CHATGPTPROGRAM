from pathlib import Path

path = Path('.github/evermore/qooapp-native-run.sh')
text = path.read_text()
marker = "echo '=== Install and launch QooApp ==='"
insert = r'''if [ -f /tmp/evermore-direct/Evermore.apk ]; then
  echo '=== Direct Evermore APK found: install before QooApp fallback ==='
  set +e
  adb install -r -t -g /tmp/evermore-direct/Evermore.apk | tee artifacts/direct-evermore-install.txt
  direct_rc=${PIPESTATUS[0]}
  set -e
  if [ "$direct_rc" -eq 0 ] && installed; then
    echo 'direct_install=yes' | tee artifacts/direct-install-status.txt
    adb shell pm path "$EVERMORE_PKG" | tee artifacts/evermore-package-paths.txt
    adb logcat -c || true
    adb shell monkey -p "$EVERMORE_PKG" -c android.intent.category.LAUNCHER 1 | tee artifacts/evermore-first-launch.txt || true
    sleep 20
    snap 00-direct-evermore-first-launch
    adb shell am force-stop "$EVERMORE_PKG" || true
    adb shell am start -W -a android.intent.action.VIEW -c android.intent.category.BROWSABLE \
      -d "$REFERRAL_URI" -p "$EVERMORE_PKG" | tee artifacts/referral-custom.txt || true
    sleep 12
    snap 00-direct-referral-custom-12s
    sleep 20
    snap 00-direct-referral-custom-32s
    adb shell cmd package query-activities -a android.intent.action.VIEW -c android.intent.category.BROWSABLE \
      -d "$REFERRAL_URI" > artifacts/referral-custom-handlers.txt 2>&1 || true
    adb shell dumpsys activity activities > artifacts/activities.txt || true
    adb logcat -d -v threadtime > artifacts/logcat.txt || true
    TOP=$(adb shell dumpsys activity activities | sed -n 's/.*mResumedActivity:.* \([^ ]*\) .*/\1/p' | head -n1 | tr -d '\r')
    {
      echo 'evermore_installed=yes'
      echo 'acquisition=direct_qooapp_api'
      echo "top_activity=$TOP"
      echo "referral_uri=$REFERRAL_URI"
      echo "android=$(adb shell getprop ro.build.version.release | tr -d '\r')"
      echo "sdk=$(adb shell getprop ro.build.version.sdk | tr -d '\r')"
      echo "abilist=$(adb shell getprop ro.product.cpu.abilist | tr -d '\r')"
      echo "native_bridge=$(adb shell getprop ro.dalvik.vm.native.bridge | tr -d '\r')"
    } | tee artifacts/RESULT.txt
    exit 0
  fi
  echo "direct_install=no rc=$direct_rc" | tee artifacts/direct-install-status.txt
fi
'''

if marker not in text:
    raise SystemExit('controller marker missing')
path.write_text(text.replace(marker, insert + '\n' + marker, 1))
print('controller patched for direct APK fallback')
