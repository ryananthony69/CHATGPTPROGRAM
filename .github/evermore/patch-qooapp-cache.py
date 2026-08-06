from pathlib import Path

path = Path('.github/evermore/qooapp-native-run.sh')
text = path.read_text()
old_find = '''  adb shell find "/data/user/0/$QOOAPP_PKG" "/sdcard/Android/data/$QOOAPP_PKG" /sdcard/Download \\
    -type f 2>/dev/null | tee artifacts/qooapp-downloaded-files.txt || true
  adb pull "/data/user/0/$QOOAPP_PKG" /tmp/qoo-cache/private >/dev/null 2>&1 || true
  adb pull "/sdcard/Android/data/$QOOAPP_PKG" /tmp/qoo-cache/external >/dev/null 2>&1 || true
'''
new_find = '''  adb shell find "/data/user/0/$QOOAPP_PKG" "/sdcard/Android/data/$QOOAPP_PKG" /sdcard/Download /sdcard/QooApp /sdcard/QooApp/apk \\
    -type f 2>/dev/null | tee artifacts/qooapp-downloaded-files.txt || true
  adb pull "/data/user/0/$QOOAPP_PKG" /tmp/qoo-cache/private >/dev/null 2>&1 || true
  adb pull "/sdcard/Android/data/$QOOAPP_PKG" /tmp/qoo-cache/external >/dev/null 2>&1 || true
  adb pull /sdcard/QooApp /tmp/qoo-cache/qooapp-shared >/dev/null 2>&1 || true
  adb pull /sdcard/Download /tmp/qoo-cache/download >/dev/null 2>&1 || true
'''
if old_find not in text:
    raise SystemExit('QooApp cache block not found')
text = text.replace(old_find, new_find, 1)
path.write_text(text)
print('QooApp shared APK folder fallback patched')
