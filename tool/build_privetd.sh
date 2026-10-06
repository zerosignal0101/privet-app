#!/usr/bin/env bash
set -euo pipefail
# Cross-compiles privetd for Android ABIs and stages the embeddable cdylib
# under android/app/src/main/jniLibs/<abi>/ so the APK ships it as a native
# library. On Android >= 10 an app cannot execve a bundled ELF extracted into
# its own data dir (SELinux W^X on untrusted_app since targetSdk 29), so the
# app dlopens libprivetd_embed.so and runs the daemon on a thread.
#
# Usage:
#   ABI=arm64-v8a bash tool/build_privetd.sh   # single ABI (spike)
#   bash tool/build_privetd.sh                 # all three ABIs
#
# Requirements:
#   - cargo-ndk installed (cargo install cargo-ndk)
#   - an Android NDK (ANDROID_NDK_HOME set, or discovered under the SDK)
#   - rustup targets: aarch64-linux-android, armv7-linux-androideabi,
#     x86_64-linux-android

# The daemon checkout to cross-compile. Defaults to the sibling repo, so a
# normal `../privet` + `../privet-app` layout works with no environment set;
# the binaries are no longer committed, so this step is required before an
# Android build.
APP_ROOT_FOR_DEFAULT="$(cd "$(dirname "$0")/.." && pwd)"
PRIVET_REPO="${PRIVET_REPO:-$(cd "$APP_ROOT_FOR_DEFAULT/../privet" && pwd)}"
APP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$APP_ROOT/android/app/src/main/jniLibs"
ABI="${ABI:-arm64-v8a armeabi-v7a x86_64}"
# Minimum Android API level. Must be >= 24: `getifaddrs` (used by the if-addrs
# crate for interface enumeration) is only in libc from API 24. cargo-ndk
# defaults to 21, which links with an undefined symbol. Matches Flutter's
# default minSdkVersion (24).
MIN_SDK="${MIN_SDK:-24}"

# Locate an NDK deterministically: ANDROID_NDK_HOME wins, else newest under the
# Android SDK (cargo-ndk would probe on its own, but we pin it for reproducibility).
if [[ -z "${ANDROID_NDK_HOME:-}" ]]; then
  sdk="${ANDROID_HOME:-}"
  if [[ -z "$sdk" && -n "$LOCALAPPDATA" ]]; then
    sdk="$(cygpath "$LOCALAPPDATA" 2>/dev/null || echo "$LOCALAPPDATA")/Android/sdk"
  fi
  newest="$(ls -1 "$sdk"/ndk 2>/dev/null | sort -V | tail -1 || true)"
  if [[ -z "$newest" ]]; then
    echo "error: no NDK found. Set ANDROID_NDK_HOME or install an NDK under the SDK." >&2
    exit 1
  fi
  ANDROID_NDK_HOME="$sdk/ndk/$newest"
fi
export ANDROID_NDK_HOME
echo "NDK: $ANDROID_NDK_HOME"

cd "$PRIVET_REPO"
for abi in $ABI; do
  case "$abi" in
    arm64-v8a)   triple="aarch64-linux-android" ;;
    armeabi-v7a) triple="armv7-linux-androideabi" ;;
    x86_64)      triple="x86_64-linux-android" ;;
    *) echo "error: unknown ABI: $abi" >&2; exit 1 ;;
  esac
  mkdir -p "$OUT/$abi"
  echo "=== building privetd for $abi ($triple) ==="
  cargo ndk -P "$MIN_SDK" -t "$abi" build -p privet-daemon --lib --release
  cp "target/$triple/release/libprivetd_embed.so" "$OUT/$abi/libprivetd_embed.so"
  file "$OUT/$abi/libprivetd_embed.so" || true
done
echo "staged:"
ls -la "$OUT"/*/libprivetd_embed.so
