#!/bin/bash
set -euo pipefail
shopt -s globstar

echo -e "\n[INFO]: BUILD STARTED..!\n"
rm -rf AnyKernel3/
# init submodules
git submodule init && git submodule update

export KERNEL_ROOT="$(pwd)"
export ARCH=arm64
export KBUILD_BUILD_USER="@sauronbach"

# Read SUSFS environment variables (defaults)
ENABLE_SUSFS="${ENABLE_SUSFS:-0}"
SUSFS_REPO="${SUSFS_REPO:-https://gitlab.com/simonpunk/susfs4ksu.git}"
SUSFS_BRANCH="${SUSFS_BRANCH:-gki-android14-5.15}"
SUSFS_MODULE_REPO="${SUSFS_MODULE_REPO:-https://github.com/sidex15/susfs4ksu-module.git}"
SUSFS_WORKDIR="${KERNEL_ROOT}/.susfs"

# Function to detect OS and install dependencies (unchanged, simplified a bit)
install_dependencies() {
    echo -e "\n[INFO]: Detecting OS and installing dependencies...\n"
    if command -v apt &> /dev/null; then
        echo -e "[INFO]: Ubuntu/Debian-based system detected, using apt...\n"
        sudo apt update
        sudo apt install -y git device-tree-compiler lz4 xz-utils zlib1g-dev openjdk-17-jdk \
            gcc g++ python3 python-is-python3 p7zip-full android-sdk-libsparse-utils erofs-utils \
            default-jdk gnupg flex bison gperf build-essential zip curl libc6-dev libncurses-dev \
            libx11-dev libreadline-dev libgl1-mesa-dev make bc tofrodos python3-markdown libxml2-utils \
            xsltproc cpio kmod openssl libelf-dev pahole libssl-dev libarchive-tools zstd rsync \
            patch binutils-aarch64-linux-gnu gcc-aarch64-linux-gnu || true
    elif command -v dnf &> /dev/null; then
        echo -e "[INFO]: Fedora/RHEL-based system detected, using dnf...\n"
        sudo dnf group install -y "c-development" "development-tools" || true
        sudo dnf install -y dtc lz4 xz zlib-devel java-latest-openjdk-devel python3 p7zip \
            p7zip-plugins android-tools erofs-utils ncurses-devel libX11-devel readline-devel \
            python3-markdown kmod openssl elfutils-libelf-devel dwarves libarchive zstd rsync || true
    else
        echo -e "[ERROR]: Neither dnf nor apt package manager found. Please install dependencies manually.\n"
        exit 1
    fi
    touch .requirements
}

# Install the requirements for building the kernel when running the script for the first time
if [ ! -f ".requirements" ]; then
    install_dependencies
fi

mkdir -p "${KERNEL_ROOT}/out" "${KERNEL_ROOT}/build" "${HOME}/toolchains" "${SUSFS_WORKDIR}"

# Init clang-r450784e
if [ ! -d "${HOME}/toolchains/clang-r450784e" ]; then
    echo -e "\n[INFO] Cloning clang-r450784e Toolchain\n"
    mkdir -p "${HOME}/toolchains/clang-r450784e" && cd "${HOME}/toolchains/clang-r450784e"
    curl -LO "https://android.googlesource.com/platform//prebuilts/clang/host/linux-x86/+archive/722c840a8e4d58b5ebdab62ce78eacdafd301208/clang-r450784e.tar.gz"
    tar -xf clang-r450784e.tar.gz && rm clang-r450784e.tar.gz
    cd "${KERNEL_ROOT}"
fi

# Init arm gnu toolchain
if [ ! -d "${HOME}/toolchains/gcc" ]; then
    echo -e "\n[INFO] Cloning ARM GNU Toolchain\n"
    mkdir -p "${HOME}/toolchains/gcc" && cd "${HOME}/toolchains/gcc"
    curl -LO "https://developer.arm.com/-/media/Files/downloads/gnu/14.2.rel1/binrel/arm-gnu-toolchain-14.2.rel1-x86_64-aarch64-none-linux-gnu.tar.xz"
    tar -xf arm-gnu-toolchain-14.2.rel1-x86_64-aarch64-none-linux-gnu.tar.xz
    cd "${KERNEL_ROOT}"
fi

# Export toolchain paths
export PATH="${HOME}/toolchains/clang-r450784e/bin:${PATH}"
export LD_LIBRARY_PATH="${HOME}/toolchains/clang-r450784e/lib64:${LD_LIBRARY_PATH:-}"

# Set cross-compile environment variables
export BUILD_CROSS_COMPILE="${HOME}/toolchains/gcc/arm-gnu-toolchain-14.2.rel1-x86_64-aarch64-none-linux-gnu/bin/aarch64-none-linux-gnu-"
export BUILD_CC="${HOME}/toolchains/clang-r450784e/bin/clang"

# Build options for the kernel
export BUILD_OPTIONS=(
    -C "${KERNEL_ROOT}"
    O="${KERNEL_ROOT}/out"
    -j"$(nproc)"
    ARCH=arm64
    LLVM=1
    LLVM_IAS=1
    CROSS_COMPILE="${BUILD_CROSS_COMPILE}"
    CC="${BUILD_CC}"
    CLANG_TRIPLE=aarch64-linux-gnu-
)

# Integrate SUSFS: clone, apply patches, build/copy userspace tools
integrate_susfs() {
    if [ "${ENABLE_SUSFS}" != "1" ]; then
        echo "[INFO] SUSFS integration disabled (ENABLE_SUSFS != 1)."
        return 0
    fi

    echo -e "\n[INFO] SUSFS integration requested. Cloning ${SUSFS_REPO} (branch ${SUSFS_BRANCH})...\n"
    rm -rf "${SUSFS_WORKDIR}"
    git clone --depth 1 --branch "${SUSFS_BRANCH}" "${SUSFS_REPO}" "${SUSFS_WORKDIR}" || {
        echo "[WARN] Failed to clone SUSFS repo with branch ${SUSFS_BRANCH}, trying default branch..."
        rm -rf "${SUSFS_WORKDIR}"
        git clone --depth 1 "${SUSFS_REPO}" "${SUSFS_WORKDIR}" || { echo "[ERROR] Cannot clone SUSFS repo."; return 1; }
    }

    # Search for patch files
    echo "[INFO] Searching for .patch files in ${SUSFS_WORKDIR}..."
    mapfile -t PATCH_FILES < <(find "${SUSFS_WORKDIR}" -type f -iname "*.patch" -o -iname "*.diff" -o -iname "*.patches" 2>/dev/null || true)

    if [ "${#PATCH_FILES[@]}" -eq 0 ]; then
        echo "[WARN] No .patch files found in SUSFS repository. The repo may not contain kernel patches for your kernel."
    else
        echo "[INFO] Found ${#PATCH_FILES[@]} patch file(s). Applying to kernel source..."
        # Apply patches one-by-one
        for p in "${PATCH_FILES[@]}"; do
            echo "[INFO] Applying patch: ${p}"
            # Try git apply first
            if git apply --whitespace=fix "${p}"; then
                echo "[OK] Applied ${p}"
            else
                # As fallback, try patch -p1
                if patch -p1 --forward --silent < "${p}"; then
                    echo "[OK] Applied ${p} with patch -p1"
                else
                    echo "[ERROR] Failed to apply ${p}. Aborting SUSFS integration."
                    return 1
                fi
            fi
        done
        # Optionally commit the changes to kernel tree (non-essential but useful)
        git add -A || true
        git commit -m "Apply SUSFS patches" || true
    fi

    # Attempt to build the ksu_susfs userspace tool (arm/arm64)
    # Many SUSFS repos provide a build script; try to use it
    cd "${SUSFS_WORKDIR}" || return 0

    # If repo provides a build script for ksu_susfs
    if [ -x "./build_ksu_susfs_tool.sh" ]; then
        echo "[INFO] Found build_ksu_susfs_tool.sh. Attempting to build ksu_susfs..."
        # Make sure cross compiler is available via aarch64-linux-gnu-gcc
        export AARCH64_CC="aarch64-linux-gnu-gcc"
        chmod +x ./build_ksu_susfs_tool.sh
        # The script may output arm/arm64 binaries under some tools/ directory
        ./build_ksu_susfs_tool.sh || {
            echo "[WARN] build_ksu_susfs_tool.sh failed, proceeding to search for prebuilt binaries..."
        }
    else
        echo "[INFO] No build_ksu_susfs_tool.sh found; attempting to find prebuilt binaries."
    fi

    # Search for ksu_susfs binary (arm64) in common locations
    cd "${KERNEL_ROOT}" || return 0
    mapfile -t SUSFS_BIN_CANDIDATES < <(find "${SUSFS_WORKDIR}" -type f -iname "ksu_susfs*" -o -iname "sus_su*" 2>/dev/null || true)

    if [ "${#SUSFS_BIN_CANDIDATES[@]}" -gt 0 ]; then
        echo "[INFO] Found user-space binary candidate(s):"
        for b in "${SUSFS_BIN_CANDIDATES[@]}"; do
            echo "  - $b"
        done
    else
        echo "[WARN] No ksu_susfs binary was found after build attempt. Trying to clone the sidex15 module repo for prebuilt files..."
        # Try SIDEX15 module repository (it typically contains prebuilt binaries inside the module)
        TMP_MODULE="${KERNEL_ROOT}/.susfs_module"
        rm -rf "${TMP_MODULE}"
        if git clone --depth 1 "${SUSFS_MODULE_REPO}" "${TMP_MODULE}"; then
            echo "[INFO] Cloned module repo. Searching for prebuilt ksu_susfs in module..."
            mapfile -t SUSFS_BIN_CANDIDATES < <(find "${TMP_MODULE}" -type f -iname "ksu_susfs*" -o -iname "sus_su*" 2>/dev/null || true)
            if [ "${#SUSFS_BIN_CANDIDATES[@]}" -gt 0 ]; then
                echo "[INFO] Found prebuilt module binary(s)."
            else
                echo "[WARN] sidex15 module clone did not reveal prebuilt binaries. SUSFS userspace will not be included."
            fi
        else
            echo "[WARN] Could not clone sidex15 module repo; skipping prebuilt userland fallback."
        fi
    fi

    # Prepare AnyKernel3/ksu directory so we can include the userspace tool in ZIP
    cd "${KERNEL_ROOT}" || return 0
    mkdir -p AnyKernel3/ksu/bin

    # Copy any found ksu_susfs candidate that looks like an arm64 binary
    for cand in "${SUSFS_BIN_CANDIDATES[@]:-}"; do
        if [ -f "${cand}" ]; then
            # if filename contains "aarch64" or "arm64" or is ELF with aarch64 arch, prefer it
            file_out=$(file "${cand}" || true)
            if echo "${file_out}" | grep -qi "aarch64"; then
                echo "[INFO] Copying ${cand} -> AnyKernel3/ksu/bin/ksu_susfs"
                cp "${cand}" AnyKernel3/ksu/bin/ksu_susfs
                chmod +x AnyKernel3/ksu/bin/ksu_susfs || true
                break
            fi
            # fallback: copy the first candidate
            echo "[INFO] Copying fallback ${cand} -> AnyKernel3/ksu/bin/ksu_susfs"
            cp "${cand}" AnyKernel3/ksu/bin/ksu_susfs
            chmod +x AnyKernel3/ksu/bin/ksu_susfs || true
            break
        fi
    done

    echo "[INFO] SUSFS integration completed (patches applied and userspace tool added if available)."
    return 0
}

build_kernel(){
    # Integrate SUSFS BEFORE configuring/building the kernel
    integrate_susfs || { echo "[ERROR] SUSFS integration failed. Aborting build."; exit 1; }

    # Make default configuration.
    make "${BUILD_OPTIONS[@]}" gki_defconfig

    # Build the kernel
    make "${BUILD_OPTIONS[@]}" Image || exit 1

    echo -e "\n[INFO]: BUILD FINISHED..!"
    cd ${KERNEL_ROOT}
    git clone https://github.com/voltage-dmxq/AnyKernel3.git

    # Copy the built kernel to the AnyKernel3 directory
    mv "${KERNEL_ROOT}/out/arch/arm64/boot/Image" "${KERNEL_ROOT}/AnyKernel3" || {
        echo "[WARN] Built Image not found in expected location; please check build logs."
    }

    # Optional: copy ksu_susfs from AnyKernel3/ksu/bin into the ZIP if present
    if [ -d "AnyKernel3/ksu/bin" ]; then
        echo "[INFO] Including SUSFS userspace binaries into AnyKernel ZIP..."
    fi

    (cd AnyKernel3/ && zip -r ../DMXQ-KERNEL.ZIP ./*)
    mv DMXQ-KERNEL.ZIP build/
}
build_kernel
