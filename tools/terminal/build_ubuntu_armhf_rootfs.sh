#!/usr/bin/env bash
# Builds an Ubuntu 24.04 (noble) armhf rootfs tarball for use with PRoot
# on 32-bit ARM Android devices.
#
# The arm64 equivalent is already vendored at:
#   terminal/src/main/assets/ubuntu-noble-aarch64-pd-v4.18.0.tar.xz
#
# This script produces:
#   terminal/src/main/assets/ubuntu-noble-armhf-pd-v4.18.0.tar.xz
#
# Requirements:
#   - debootstrap
#   - qemu-user-static (for cross-architecture chroot on x86_64 build hosts)
#   - xz-utils
#   - root or fakeroot (for creating device nodes and setting ownership)
#
# Usage:
#   sudo ./build_ubuntu_armhf_rootfs.sh
#   # or with fakeroot:
#   fakeroot ./build_ubuntu_armhf_rootfs.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ASSETS_DIR="$REPO_ROOT/terminal/src/main/assets"

UBUNTU_VERSION="noble"  # 24.04
ARCH="armhf"
OUTPUT_NAME="ubuntu-noble-${ARCH}-pd-v4.18.0.tar.xz"
BUILD_DIR="${BUILD_DIR:-$REPO_ROOT/build-ubuntu-rootfs}"
ROOTFS_DIR="$BUILD_DIR/rootfs"

MIRROR="${MIRROR:-http://ports.ubuntu.com/ubuntu-ports}"

# Packages to include in the rootfs (minimal set for terminal/dev use)
PACKAGES=(
  bash
  coreutils
  findutils
  grep
  gzip
  tar
  xz-utils
  sed
  awk
  less
  vim-tiny
  nano
  wget
  curl
  ca-certificates
  openssh-client
  rsync
  git
  python3
  python3-pip
  nodejs
  npm
  build-essential
  pkg-config
  libssl-dev
  zlib1g-dev
  locales
  tzdata
  sudo
  passwd
  procps
  util-linux
  mount
  iproute2
  iputils-ping
  dnsutils
  net-tools
  htop
  tree
  jq
  unzip
  zip
)

echo "=== Ubuntu $UBUNTU_VERSION $ARCH rootfs builder ==="
echo "Mirror: $MIRROR"
echo "Output: $ASSETS_DIR/$OUTPUT_NAME"
echo ""

# Check requirements
if ! command -v debootstrap &>/dev/null; then
  echo "ERROR: debootstrap is not installed." >&2
  echo "  Debian/Ubuntu: sudo apt install debootstrap qemu-user-static" >&2
  exit 1
fi

if [[ "$(id -u)" -ne 0 ]] && ! command -v fakeroot &>/dev/null; then
  echo "WARNING: Not running as root and fakeroot not found." >&2
  echo "  File ownership may be incorrect. Consider using sudo or fakeroot." >&2
fi

# Clean previous build
rm -rf "$ROOTFS_DIR"
mkdir -p "$BUILD_DIR" "$ASSETS_DIR"

# Stage 1: debootstrap first stage
echo "[1/4] Running debootstrap first stage..."
debootstrap \
  --arch="$ARCH" \
  --foreign \
  --variant=minbase \
  --include="$(IFS=,; echo "${PACKAGES[*]}")" \
  "$UBUNTU_VERSION" \
  "$ROOTFS_DIR" \
  "$MIRROR"

# Stage 2: Copy qemu-arm-static for second stage (if cross-compiling)
if [[ "$(uname -m)" != "armv7l" ]] && [[ "$(uname -m)" != "armv8l" ]]; then
  echo "[2/4] Copying qemu-arm-static for cross-architecture second stage..."
  QEMU_ARM=$(command -v qemu-arm-static || echo "/usr/bin/qemu-arm-static")
  if [[ ! -f "$QEMU_ARM" ]]; then
    echo "ERROR: qemu-arm-static not found. Install with: sudo apt install qemu-user-static" >&2
    exit 1
  fi
  mkdir -p "$ROOTFS_DIR/usr/bin"
  cp "$QEMU_ARM" "$ROOTFS_DIR/usr/bin/"
fi

# Stage 3: Second stage debootstrap
echo "[3/4] Running debootstrap second stage..."
if [[ -f "$ROOTFS_DIR/debootstrap/debootstrap" ]]; then
  chroot "$ROOTFS_DIR" /debootstrap/debootstrap --second-stage
fi

# Stage 4: Post-configuration
echo "[4/4] Post-configuring rootfs..."

# Set up DNS
echo "nameserver 8.8.8.8" > "$ROOTFS_DIR/etc/resolv.conf"
echo "nameserver 8.8.4.4" >> "$ROOTFS_DIR/etc/resolv.conf"

# Set up apt sources
cat > "$ROOTFS_DIR/etc/apt/sources.list" << EOF
deb $MIRROR $UBUNTU_VERSION main restricted universe multiverse
deb $MIRROR $UBUNTU_VERSION-updates main restricted universe multiverse
deb $MIRROR $UBUNTU_VERSION-security main restricted universe multiverse
EOF

# Set locale
if [[ -f "$ROOTFS_DIR/etc/locale.gen" ]]; then
  sed -i 's/^# *\(en_US.UTF-8\)/\1/' "$ROOTFS_DIR/etc/locale.gen"
  chroot "$ROOTFS_DIR" locale-gen 2>/dev/null || true
fi
echo "LANG=en_US.UTF-8" > "$ROOTFS_DIR/etc/default/locale"

# Set timezone to UTC
echo "UTC" > "$ROOTFS_DIR/etc/timezone"
ln -sf /usr/share/zoneinfo/UTC "$ROOTFS_DIR/etc/localtime" 2>/dev/null || true

# Create a default user (android-like)
if ! chroot "$ROOTFS_DIR" id android &>/dev/null; then
  chroot "$ROOTFS_DIR" useradd -m -s /bin/bash -G sudo android 2>/dev/null || true
  echo "android:android" | chroot "$ROOTFS_DIR" chpasswd 2>/dev/null || true
fi

# Clean up apt caches to reduce size
chroot "$ROOTFS_DIR" apt-get clean 2>/dev/null || true
chroot "$ROOTFS_DIR" apt-get autoclean 2>/dev/null || true
rm -rf "$ROOTFS_DIR/var/lib/apt/lists/"*
rm -rf "$ROOTFS_DIR/var/cache/apt/archives/"*
rm -rf "$ROOTFS_DIR/tmp/"*
rm -rf "$ROOTFS_DIR/var/tmp/"*

# Remove qemu-arm-static if we copied it
if [[ -f "$ROOTFS_DIR/usr/bin/qemu-arm-static" ]]; then
  rm -f "$ROOTFS_DIR/usr/bin/qemu-arm-static"
fi

# Remove unnecessary documentation and man pages to reduce size
rm -rf "$ROOTFS_DIR/usr/share/doc/"*
rm -rf "$ROOTFS_DIR/usr/share/man/"*
rm -rf "$ROOTFS_DIR/usr/share/info/"*
find "$ROOTFS_DIR/usr/share/locale" -type f ! -name "en_US*" -delete 2>/dev/null || true

# Create the tarball
echo ""
echo "Creating compressed tarball..."
cd "$ROOTFS_DIR"
tar -cJf "$ASSETS_DIR/$OUTPUT_NAME" .

# Show result
SIZE=$(du -h "$ASSETS_DIR/$OUTPUT_NAME" | cut -f1)
echo ""
echo "=== Done ==="
echo "Output: $ASSETS_DIR/$OUTPUT_NAME"
echo "Size: $SIZE"
echo ""
echo "To verify the tarball contains armhf binaries:"
echo "  tar -xOf $ASSETS_DIR/$OUTPUT_NAME bin/bash | file -"
