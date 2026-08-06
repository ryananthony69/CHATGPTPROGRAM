#!/usr/bin/env bash
set -Eeuo pipefail

mkdir -p artifacts /tmp/evermore-unpacked

echo 'KERNEL=="kvm", GROUP="kvm", MODE="0666", OPTIONS+="static_node=kvm"' \
  | sudo tee /etc/udev/rules.d/99-kvm4all.rules
sudo udevadm control --reload-rules
sudo udevadm trigger --name-match=kvm
ls -l /dev/kvm | tee artifacts/kvm.txt

UA='Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/138.0 Safari/537.36'
XAPK=/tmp/Evermore.xapk

echo '=== Direct XAPK headers ===' | tee artifacts/xapk-download.txt
curl --silent --show-error --location --head \
  --connect-timeout 30 --max-time 120 \
  -A "$UA" -e "$APKCOMBO_PAGE" "$XAPK_URL" \
  | tee -a artifacts/xapk-download.txt || true

curl --fail --location --retry 6 --retry-all-errors \
  --connect-timeout 30 --max-time 2400 \
  -A "$UA" -e "$APKCOMBO_PAGE" \
  -D artifacts/xapk-response-headers.txt \
  "$XAPK_URL" -o "$XAPK"

test "$(head -c 2 "$XAPK")" = 'PK'
unzip -tq "$XAPK" >/dev/null
ls -lh "$XAPK" | tee -a artifacts/xapk-download.txt
sha256sum "$XAPK" | tee artifacts/xapk-sha256.txt
unzip -q "$XAPK" -d /tmp/evermore-unpacked
find /tmp/evermore-unpacked -type f -printf '%s %p\n' | sort -n \
  | tee artifacts/xapk-files.txt

python3 - <<'PY'
from pathlib import Path
import json

root = Path('/tmp/evermore-unpacked')
apks = sorted(root.rglob('*.apk'))
if not apks:
    raise SystemExit('XAPK contained no APK files')
Path('/tmp/apk-list.txt').write_text('\n'.join(str(p) for p in apks) + '\n')
manifest = {
    'apk_count': len(apks),
    'apks': [{'path': str(p), 'size': p.stat().st_size} for p in apks],
    'obb': [str(p) for p in sorted(root.rglob('*.obb'))],
}
Path('artifacts/unpacked-manifest.json').write_text(json.dumps(manifest, indent=2))
print(json.dumps(manifest, indent=2))
PY
cp /tmp/apk-list.txt artifacts/apk-list.txt
