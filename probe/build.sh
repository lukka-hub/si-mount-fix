#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
SDK="${ANDROID_SDK_ROOT:-/opt/android-sdk}"
BT="$SDK/build-tools/35.0.0"
AJ="$SDK/platforms/android-35/android.jar"
LINK_JAR="${LINK_JAR:-$SDK/platforms/android-30/android.jar}"
AAPT2="${AAPT2:-/usr/bin/aapt2}"
ZIPALIGN="${ZIPALIGN:-/usr/bin/zipalign}"
D8="$BT/d8"
APKSIGNER="$BT/apksigner"
OUT="$ROOT/build"
APK="$ROOT/DCIMGrid.apk"
KS="${KEYSTORE:-$HOME/.android/debug.keystore}"
rm -rf "$OUT"; mkdir -p "$OUT/classes" "$OUT/dex"
"$AAPT2" link -o "$OUT/base.apk" -I "$LINK_JAR" --manifest "$ROOT/AndroidManifest.xml" --min-sdk-version 29 --target-sdk-version 35 --version-code 1 --version-name 1.0
javac -encoding UTF-8 -source 8 -target 8 -bootclasspath "$AJ" -classpath "$AJ" -d "$OUT/classes" $(find "$ROOT/src" -name '*.java' | sort)
"$D8" --lib "$AJ" --min-api 29 --output "$OUT/dex" $(find "$OUT/classes" -name '*.class')
cp "$OUT/base.apk" "$OUT/withdex.apk"
python3 - "$OUT/withdex.apk" "$OUT/dex/classes.dex" <<'PY'
import sys, zipfile, os
apk, dex = sys.argv[1], sys.argv[2]
tmp = apk + ".tmp"
with zipfile.ZipFile(apk) as zin, zipfile.ZipFile(tmp, "w") as zout:
    for item in zin.infolist():
        if item.filename == "classes.dex": continue
        zout.writestr(item, zin.read(item.filename))
    zout.write(dex, "classes.dex", compress_type=zipfile.ZIP_DEFLATED)
os.replace(tmp, apk)
PY
"$ZIPALIGN" -f 4 "$OUT/withdex.apk" "$OUT/aligned.apk"
"$APKSIGNER" sign --ks "$KS" --ks-pass pass:android --key-pass pass:android --out "$APK" "$OUT/aligned.apk"
"$APKSIGNER" verify "$APK"
ls -l "$APK"; sha256sum "$APK"
