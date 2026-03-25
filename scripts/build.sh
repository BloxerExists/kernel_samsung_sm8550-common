#!/usr/bin/env bash
set -euo pipefail

# -------------------------
# Configurable variables
# -------------------------
JOBS=${JOBS:-1}
KERNEL_DEFCONFIG=${KERNEL_DEFCONFIG:-gki_defconfig}
CLANG_VERSION=${CLANG_VERSION:-clang-r584948}
OUT_DIR=${OUT_DIR:-out}
CLANG_DIR=${CLANG_DIR:-"$HOME/tools/google-clang"}
CLANG_BINARY="$CLANG_DIR/bin/clang"

KSU_DIR=${KSU_DIR:-KernelSU-Next}
KSU_REPO=${KSU_REPO:-https://github.com/KernelSU-Next/KernelSU-Next.git}
KSU_BRANCH=${KSU_BRANCH:-stable}

# Optional: disable LTO to avoid CI OOM
CI_NO_LTO=${CI_NO_LTO:-1}

LLVM_PARALLEL_LINK_JOBS=1
START_TIME=$(date +%s)

# -------------------------
# Pretty logging
# -------------------------
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info(){ echo -e "${GREEN}[INFO]${NC} $*"; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $*"; }
err(){  echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# -------------------------
# Setup Clang
# -------------------------
setup_clang() {
  info "Checking for Clang ($CLANG_VERSION)..."

  if [ ! -x "$CLANG_BINARY" ]; then
    warn "Clang not found. Fetching..."
    mkdir -p "$CLANG_DIR"

    TARBALL="$(mktemp)"
    URL_BASE="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive"
    PRIMARY_URL="$URL_BASE/refs/heads/main/${CLANG_VERSION}.tar.gz"
    ALT_URL="$URL_BASE/mirror-goog-main-llvm-toolchain-source/${CLANG_VERSION}.tar.gz"

    if command -v wget >/dev/null 2>&1; then
      DOWN_PRIMARY=(wget -q --show-progress -O "$TARBALL" "$PRIMARY_URL")
      DOWN_ALT=(wget -q --show-progress -O "$TARBALL" "$ALT_URL")
    elif command -v curl >/dev/null 2>&1; then
      DOWN_PRIMARY=(curl -L --fail -o "$TARBALL" "$PRIMARY_URL")
      DOWN_ALT=(curl -L --fail -o "$TARBALL" "$ALT_URL")
    else
      err "Need wget or curl to download the toolchain."
    fi

    if ! "${DOWN_PRIMARY[@]}"; then
      warn "Primary URL failed, trying mirror..."
      "${DOWN_ALT[@]}" || err "Download failed from both URLs."
    fi

    info "Extracting toolchain..."
    tar -xzf "$TARBALL" -C "$CLANG_DIR"
    rm -f "$TARBALL"
  fi

  export PATH="/usr/lib/ccache:$CLANG_DIR/bin:$PATH"
  export BUILD_CC="$CLANG_BINARY"
  ver="$("$CLANG_BINARY" --version | head -n1)"
  ver="$(echo "$ver" | sed -E 's/\(http[^)]*\)//g; s/[[:space:]]+/ /g; s/[[:space:]]+$//')"
  export KBUILD_COMPILER_STRING="$ver"
}

# -------------------------
# Setup GCC cross compiler
# -------------------------
setup_cross() {
  CROSS_DIR="$HOME/toolchains/gcc"
  ARCH_GCC_DIR="$CROSS_DIR/arm-gnu-toolchain-14.2.rel1-x86_64-aarch64-none-linux-gnu"
  CROSS_BIN="$ARCH_GCC_DIR/bin/aarch64-none-linux-gnu-"

  if [ ! -x "${CROSS_BIN}gcc" ]; then
    info "Fetching ARM64 GCC cross-compiler..."
    mkdir -p "$CROSS_DIR"
    pushd "$CROSS_DIR" >/dev/null
    curl -fLO "https://developer.arm.com/-/media/Files/downloads/gnu/14.2.rel1/binrel/arm-gnu-toolchain-14.2.rel1-x86_64-aarch64-none-linux-gnu.tar.xz"
    tar -xf arm-gnu-toolchain-14.2.rel1-x86_64-aarch64-none-linux-gnu.tar.xz
    rm -f arm-gnu-toolchain-14.2.rel1-x86_64-aarch64-none-linux-gnu.tar.xz
    popd >/dev/null
  fi

  export CROSS_COMPILE="$CROSS_BIN"
  export CLANG_TRIPLE=aarch64-linux-gnu-
}

# -------------------------
# Setup KernelSU Next
# -------------------------
setup_kernelsu() {
  info "Setting up KernelSU Next..."
  # Run from kernel source root
  curl -fLSs "https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/next/kernel/setup.sh" \
    | bash -s "${KSU_BRANCH}"
}

# -------------------------
# Kernel build
# -------------------------
build_kernel() {
  info "Starting kernel build..."

  setup_clang
  setup_cross
  setup_kernelsu

  mkdir -p "$OUT_DIR"

  info "Running defconfig..."
  make -j"$JOBS" \
       O="$OUT_DIR" \
       ARCH=arm64 \
       CC="$BUILD_CC" \
       CROSS_COMPILE="$CROSS_COMPILE" \
       LD=ld.lld \
       LLVM=1 \
       LLVM_IAS=1 \
       "$KERNEL_DEFCONFIG" || err "defconfig failed"

  # Disable LTO for CI if requested
  if [ "$CI_NO_LTO" = "1" ]; then
    info "Disabling LTO for CI to prevent OOM..."
    sed -i -E 's/^CONFIG_LTO_[A-Z0-9_]+=.*/# \0 is not set/' "$OUT_DIR/.config" || true
    echo "CONFIG_LTO_NONE=y" >> "$OUT_DIR/.config"
    make -j"$JOBS" O="$OUT_DIR" ARCH=arm64 olddefconfig
  fi

  info "Building kernel..."
  make -j"$JOBS" \
       O="$OUT_DIR" \
       ARCH=arm64 \
       CC="$BUILD_CC" \
       CROSS_COMPILE="$CROSS_COMPILE" \
       LD=ld.lld \
       LLVM=1 \
       LLVM_IAS=1 || err "build failed"

  total=$(( $(date +%s) - START_TIME ))
  info "Build finished in $((total/60))m $((total%60))s."
}

# Always build
build_kernel
