#!/usr/bin/env bash
# Build the WayTV Settings APK (Rust NativeActivity) without Gradle:
#   cargo-ndk (.so) -> aapt2 compile/link (manifest + res) -> add lib/ -> zipalign -> apksigner (v2+v3)
#
# Env (all optional except signing):
#   ANDROID_HOME          Android SDK (needs platforms;android-34, build-tools;34.0.0, ndk;27.3.13750724)
#   ANDROID_NDK_HOME      default: $ANDROID_HOME/ndk/27.3.13750724
#   VERSION_CODE          default 1
#   VERSION_NAME          default 1.0
#   ABIS                  default "x86_64" (space separated cargo-ndk targets, e.g. "x86_64 arm64-v8a")
#   OUT                   default build/waytv-settings.apk
#   WAYTV_KEYSTORE, WAYTV_KEYSTORE_PASSWORD, WAYTV_KEY_ALIAS, WAYTV_KEY_PASSWORD
#                         release signing; if WAYTV_KEYSTORE is unset the APK is left unsigned
#                         (build/waytv-settings-unsigned.apk).
set -euo pipefail
cd "$(dirname "$0")"

: "${ANDROID_HOME:?set ANDROID_HOME}"
NDK_VERSION=27.3.13750724
export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-$ANDROID_HOME/ndk/$NDK_VERSION}"
BT="${BUILD_TOOLS:-$ANDROID_HOME/build-tools/34.0.0}"
PLATFORM_JAR="$ANDROID_HOME/platforms/android-34/android.jar"
VERSION_CODE="${VERSION_CODE:-1}"
VERSION_NAME="${VERSION_NAME:-1.0}"
ABIS="${ABIS:-x86_64}"
OUT="${OUT:-build/waytv-settings.apk}"
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-2}"

for f in "$BT/aapt2" "$BT/zipalign" "$BT/apksigner" "$PLATFORM_JAR" "$ANDROID_NDK_HOME/source.properties"; do
    [ -e "$f" ] || { echo "missing: $f" >&2; exit 1; }
done

rm -rf build/jniLibs build/stage build/res.zip build/*.apk
mkdir -p build/stage

echo "==> cargo ndk ($ABIS)"
targets=()
for a in $ABIS; do targets+=(-t "$a"); done
cargo ndk "${targets[@]}" -P 30 -o build/jniLibs build --release

echo "==> aapt2 (version $VERSION_CODE / $VERSION_NAME)"
"$BT/aapt2" compile --dir res -o build/res.zip
"$BT/aapt2" link -o build/stage/base.apk -I "$PLATFORM_JAR" \
    --manifest AndroidManifest.xml \
    --min-sdk-version 30 --target-sdk-version 34 \
    --version-code "$VERSION_CODE" --version-name "$VERSION_NAME" --replace-version \
    build/res.zip

echo "==> adding native libs"
python3 - build/stage/base.apk build/jniLibs <<'PY'
import os, sys, zipfile
apk, libdir = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(apk, "a") as z:
    for abi in sorted(os.listdir(libdir)):
        for so in sorted(os.listdir(os.path.join(libdir, abi))):
            # stored (uncompressed) + zipalign -p => loadable in place (extractNativeLibs=false)
            z.write(os.path.join(libdir, abi, so), f"lib/{abi}/{so}", compress_type=zipfile.ZIP_STORED)
            print(f"  lib/{abi}/{so}")
PY
"$BT/zipalign" -p -f 4 build/stage/base.apk build/stage/aligned.apk

if [ -n "${WAYTV_KEYSTORE:-}" ]; then
    echo "==> apksigner (v2 + v3)"
    : "${WAYTV_KEYSTORE_PASSWORD:?}" "${WAYTV_KEY_ALIAS:?}" "${WAYTV_KEY_PASSWORD:?}"
    export WAYTV_KEYSTORE_PASSWORD WAYTV_KEY_PASSWORD
    "$BT/apksigner" sign --ks "$WAYTV_KEYSTORE" --ks-key-alias "$WAYTV_KEY_ALIAS" \
        --ks-pass env:WAYTV_KEYSTORE_PASSWORD --key-pass env:WAYTV_KEY_PASSWORD \
        --v1-signing-enabled false --v2-signing-enabled true --v3-signing-enabled true \
        --out "$OUT" build/stage/aligned.apk
    rm -f "$OUT.idsig"
    "$BT/apksigner" verify -v --min-sdk-version 24 "$OUT" | grep -E 'Verified|scheme' || true
else
    OUT="build/waytv-settings-unsigned.apk"
    cp build/stage/aligned.apk "$OUT"
    echo "WARNING: WAYTV_KEYSTORE not set, APK is unsigned" >&2
fi
echo "==> $OUT ($(stat -c %s "$OUT") bytes)"
