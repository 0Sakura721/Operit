#!/usr/bin/env bash
# Builds all terminal native libraries for armeabi-v7a (and optionally arm64-v8a).
#
# These libraries are standalone executables disguised as .so files so that
# Android packages them into the APK's lib/ directory. They are NOT shared
# libraries that get linked at build time.
#
# Output: terminal/src/main/jniLibs/<abi>/{libbash,libbusybox,liboperit_loader,liboperit_proot,libsudo}.so
#
# Usage:
#   export ANDROID_NDK_HOME=/path/to/ndk
#   ./build_terminal_libs.sh armeabi-v7a
#   ./build_terminal_libs.sh armeabi-v7a,arm64-v8a
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TERMINAL_DIR="$REPO_ROOT/terminal"

ABIS="${1:-armeabi-v7a}"
API_LEVEL="${API_LEVEL:-26}"
BUILD_DIR="${BUILD_DIR:-$REPO_ROOT/build-terminal-libs}"

# NDK detection
NDK="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-${ANDROID_HOME:-}/ndk/*}}"
if [[ ! -d "$NDK" ]]; then
  # Try common locations
  for candidate in "$HOME/Android/Sdk/ndk/"* "/opt/android-ndk"*; do
    if [[ -d "$candidate" ]]; then
      NDK="$candidate"
      break
    fi
  done
fi
if [[ ! -d "$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin" ]]; then
  echo "ERROR: Android NDK not found. Set ANDROID_NDK_HOME." >&2
  exit 1
fi

TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64"
export LD_LIBRARY_PATH="$TOOLCHAIN/lib64:${LD_LIBRARY_PATH:-}"
export PATH="$TOOLCHAIN/bin:$PATH"

# Map ABI to NDK triple and Rust target
declare -A ABI_TRIPLE=(
  ["armeabi-v7a"]="armv7a-linux-androideabi"
  ["arm64-v8a"]="aarch64-linux-android"
)

mkdir -p "$BUILD_DIR"

###############################################################################
# libsudo.so — architecture-independent shell passthrough script
###############################################################################
build_libsudo() {
  local abi="$1"
  local outdir="$TERMINAL_DIR/src/main/jniLibs/$abi"
  mkdir -p "$outdir"
  # The original libsudo.so is a text file containing just "$@"
  printf '$@' > "$outdir/libsudo.so"
  echo "  [libsudo.so] text passthrough -> $outdir/libsudo.so"
}

###############################################################################
# libbusybox.so — static BusyBox executable
###############################################################################
build_busybox() {
  local abi="$1"
  local triple="${ABI_TRIPLE[$abi]}"
  local outdir="$TERMINAL_DIR/src/main/jniLibs/$abi"
  mkdir -p "$outdir"

  local version="1.36.1"
  local srcdir="$BUILD_DIR/busybox-$version"

  if [[ ! -d "$srcdir" ]]; then
    echo "  Downloading BusyBox $version..."
    curl -fsSL -o "$BUILD_DIR/busybox-$version.tar.bz2" \
      "https://busybox.net/downloads/busybox-$version.tar.bz2"
    tar xjf "$BUILD_DIR/busybox-$version.tar.bz2" -C "$BUILD_DIR"
  fi

  cd "$srcdir"
  make distclean 2>/dev/null || true
  cp configs/android_ndk_defconfig .config

  # Create gcc wrapper if needed (NDK r23+ has clang only)
  local wrapper_dir="$BUILD_DIR/bin-wrapper"
  mkdir -p "$wrapper_dir"
  if [[ ! -x "$wrapper_dir/${triple}${API_LEVEL}-gcc" ]]; then
    cat > "$wrapper_dir/${triple}${API_LEVEL}-gcc" << WRAPPER
#!/bin/bash
exec "$TOOLCHAIN/bin/${triple}${API_LEVEL}-clang" "\$@"
WRAPPER
    chmod +x "$wrapper_dir/${triple}${API_LEVEL}-gcc"
  fi

  export PATH="$wrapper_dir:$PATH"
  make ARCH=arm CROSS_COMPILE="${triple}${API_LEVEL}-" HOSTCC=gcc HOSTCXX=g++ -j"$(nproc)" 2>&1 | tail -5

  # BusyBox produces a static executable named "busybox"
  if [[ -f "$srcdir/busybox" ]]; then
    "$TOOLCHAIN/bin/llvm-strip" "$srcdir/busybox" 2>/dev/null || true
    cp "$srcdir/busybox" "$outdir/libbusybox.so"
    echo "  [libbusybox.so] static BusyBox -> $outdir/libbusybox.so"
  else
    echo "  ERROR: BusyBox build failed" >&2
    return 1
  fi
}

###############################################################################
# libbash.so — static GNU Bash executable
###############################################################################
build_bash() {
  local abi="$1"
  local triple="${ABI_TRIPLE[$abi]}"
  local outdir="$TERMINAL_DIR/src/main/jniLibs/$abi"
  mkdir -p "$outdir"

  local version="5.2.15"
  local srcdir="$BUILD_DIR/bash-$version"

  if [[ ! -d "$srcdir" ]]; then
    echo "  Downloading Bash $version..."
    curl -fsSL -o "$BUILD_DIR/bash-$version.tar.gz" \
      "https://ftp.gnu.org/gnu/bash/bash-$version.tar.gz"
    tar xzf "$BUILD_DIR/bash-$version.tar.gz" -C "$BUILD_DIR"
  fi

  cd "$srcdir"
  make distclean 2>/dev/null || true

  # Configure for Android cross-compilation
  # Bash needs some workarounds for Bionic libc
  export CC="${triple}${API_LEVEL}-clang"
  export CXX="${triple}${API_LEVEL}-clang++"
  export AR="$TOOLCHAIN/bin/llvm-ar"
  export RANLIB="$TOOLCHAIN/bin/llvm-ranlib"
  export STRIP="$TOOLCHAIN/bin/llvm-strip"
  export CFLAGS="-static -fPIC -O2 -DANDROID -DNO_TTY_DRIVERS -DHAVE_DEV_FD=0"
  export LDFLAGS="-static"

  ./configure \
    --host="$triple" \
    --disable-nls \
    --without-bash-malloc \
    --disable-readline \
    --disable-history \
    --disable-job-control \
    ac_cv_func_setvbuf_reversed=no \
    ac_cv_have_decl_sys_siglist=yes \
    ac_cv_func_working_mktime=yes \
    bash_cv_dev_fd=absent \
    bash_cv_dev_stdin=absent \
    bash_cv_termcap_lib=none \
    2>&1 | tail -5

  make -j"$(nproc)" 2>&1 | tail -5

  if [[ -f "$srcdir/bash" ]]; then
    "$STRIP" "$srcdir/bash" 2>/dev/null || true
    cp "$srcdir/bash" "$outdir/libbash.so"
    echo "  [libbash.so] static Bash -> $outdir/libbash.so"
  else
    echo "  ERROR: Bash build failed" >&2
    return 1
  fi
}

###############################################################################
# liboperit_proot.so + liboperit_loader.so — PRoot for Android
# Based on termux/proot with Android-specific patches
###############################################################################
build_proot() {
  local abi="$1"
  local triple="${ABI_TRIPLE[$abi]}"
  local outdir="$TERMINAL_DIR/src/main/jniLibs/$abi"
  mkdir -p "$outdir"

  local srcdir="$BUILD_DIR/proot-android"

  if [[ ! -d "$srcdir" ]]; then
    echo "  Cloning termux/proot..."
    git clone --depth 1 https://github.com/termux/proot.git "$srcdir"
  fi

  cd "$srcdir"

  export CC="${triple}${API_LEVEL}-clang"
  export AR="$TOOLCHAIN/bin/llvm-ar"
  export STRIP="$TOOLCHAIN/bin/llvm-strip"

  # Build proot (dynamically linked against Android Bionic)
  echo "  Building proot..."
  make -C src clean 2>/dev/null || true
  make -C src PROOT_UNBUNDLE_LOADER=1 -j"$(nproc)" 2>&1 | tail -5

  if [[ -f "$srcdir/src/proot" ]]; then
    "$STRIP" "$srcdir/src/proot" 2>/dev/null || true
    cp "$srcdir/src/proot" "$outdir/liboperit_proot.so"
    echo "  [liboperit_proot.so] -> $outdir/liboperit_proot.so"
  else
    echo "  ERROR: proot build failed" >&2
    return 1
  fi

  # Build loader (static, position-independent, no libc)
  echo "  Building proot loader..."
  local loader_src="$srcdir/src/loader/loader.c"
  local loader_flags="-static -nostdlib -fPIC -O2 -ffreestanding \
    -I$srcdir/src -I$srcdir/src/loader \
    -Wl,-e,_start -Wl,--build-id=none"

  if [[ "$abi" == "armeabi-v7a" ]]; then
    loader_flags="$loader_flags -march=armv7-a -mfpu=neon -mfloat-abi=softfp"
  fi

  "$CC" $loader_flags "$loader_src" -o "$outdir/liboperit_loader.so" 2>&1 | tail -5

  if [[ -f "$outdir/liboperit_loader.so" ]]; then
    "$STRIP" "$outdir/liboperit_loader.so" 2>/dev/null || true
    echo "  [liboperit_loader.so] -> $outdir/liboperit_loader.so"
  else
    echo "  ERROR: proot loader build failed" >&2
    return 1
  fi
}

###############################################################################
# Main
###############################################################################
echo "Building terminal native libraries for: $ABIS"
echo "NDK: $NDK"
echo "Build dir: $BUILD_DIR"
echo ""

IFS=',' read -ra ABI_LIST <<< "$ABIS"
for abi in "${ABI_LIST[@]}"; do
  abi="$(echo "$abi" | xargs)"
  echo "=== ABI: $abi ==="

  build_libsudo "$abi"
  build_busybox "$abi"
  build_bash "$abi"
  build_proot "$abi"

  echo ""
  echo "Result for $abi:"
  ls -lh "$TERMINAL_DIR/src/main/jniLibs/$abi/"
  echo ""
done

echo "All done. Libraries placed in terminal/src/main/jniLibs/<abi>/"
