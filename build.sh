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
SUSFS_REPO="${SUSFS_REPO:-https://github.com/WildKernels/kernel_patches.git}"
SUSFS_BRANCH="${SUSFS_BRANCH:-main}"
SUSFS_MODULE_REPO="${SUSFS_MODULE_REPO:-https://github.com/sidex15/susfs4ksu-module.git}"
SUSFS_PATCH_SET="${SUSFS_PATCH_SET:-next}"
STRICT_SUSFS_PATCH="${STRICT_SUSFS_PATCH:-0}"
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
# Helper: apply only CONFIG_* changes from a patch to arch/arm64/configs/gki_defconfig
apply_gki_defconfig_patch() {
    local patchfile="$1"
    local defconf="arch/arm64/configs/gki_defconfig"
    [ -f "${defconf}" ] || { echo "[WARN] ${defconf} not found; skipping defconfig patch."; return 1; }

    echo "[INFO] Extracting CONFIG_* additions from ${patchfile}..."
    # Extract added lines starting with '+' but skip patch metadata lines like '+++'
    # We only keep lines that are CONFIG_* or "# CONFIG_* is not set"
    mapfile -t cfg_lines < <(grep '^+' "${patchfile}" | grep -v '^+++' | sed 's/^+//' | grep -E '^CONFIG_|^# CONFIG_' || true)

    if [ "${#cfg_lines[@]}" -eq 0 ]; then
        echo "[INFO] No CONFIG_* lines found in ${patchfile}."
        return 0
    fi

    # Apply each CONFIG line: replace existing line or append
    for line in "${cfg_lines[@]}"; do
        # normalize key name
        if [[ "${line}" =~ ^#\ CONFIG_([A-Za-z0-9_]+)\ is\ not\ set ]]; then
            key="${BASH_REMATCH[1]}"
            new_line="${line}"
        elif [[ "${line}" =~ ^CONFIG_([A-Za-z0-9_]+)= ]]; then
            key="${BASH_REMATCH[1]}"
            new_line="${line}"
        else
            # not a config line we care about
            continue
        fi

        # Escape slashes for sed
        esc_new_line=$(printf '%s\n' "${new_line}" | sed 's/[\/&]/\\&/g')

        # If a CONFIG_*= exists, replace it; if "# CONFIG_* is not set", replace that; otherwise append
        if grep -qE "^CONFIG_${key}=" "${defconf}"; then
            sed -i "s/^CONFIG_${key}=.*/${esc_new_line}/" "${defconf}"
            echo "[INFO] Replaced existing CONFIG_${key} in ${defconf}"
        elif grep -qE "^# CONFIG_${key} is not set" "${defconf}"; then
            sed -i "s|^# CONFIG_${key} is not set.*|${esc_new_line}|" "${defconf}"
            echo "[INFO] Replaced '# CONFIG_${key} is not set' with ${esc_new_line} in ${defconf}"
        else
            # append at end
            printf '%s\n' "${new_line}" >> "${defconf}"
            echo "[INFO] Appended ${new_line} to ${defconf}"
        fi
    done

    return 0
}

# Robust integrate_susfs() — tolerant application and special handling for gki_defconfig
integrate_susfs() {
    if [ "${ENABLE_SUSFS}" != "1" ]; then
        echo "[INFO] SUSFS integration disabled (ENABLE_SUSFS != 1)."
        return 0
    fi

    echo -e "\n[INFO] SUSFS integration requested. Cloning ${SUSFS_REPO} (branch ${SUSFS_BRANCH})...\n"
    rm -rf "${SUSFS_WORKDIR}"
    if ! git clone --depth 1 --branch "${SUSFS_BRANCH}" "${SUSFS_REPO}" "${SUSFS_WORKDIR}" 2>/dev/null; then
        echo "[WARN] Failed to clone SUSFS repo with branch ${SUSFS_BRANCH}, trying default branch..."
        rm -rf "${SUSFS_WORKDIR}"
        if ! git clone --depth 1 "${SUSFS_REPO}" "${SUSFS_WORKDIR}"; then
            echo "[ERROR] Cannot clone SUSFS repo."
            return 1
        fi
    fi

    # Determine patch directory
    if [ "${SUSFS_PATCH_SET}" = "none" ]; then
        echo "[INFO] SUSFS_PATCH_SET=none -> skipping kernel patch application."
        PATCH_FILES=()
    else
        PATCH_DIR="${SUSFS_WORKDIR}/kernel_patches/${SUSFS_PATCH_SET}"
        if [ -d "${PATCH_DIR}" ]; then
            echo "[INFO] Using patch directory: ${PATCH_DIR}"
            mapfile -t PATCH_FILES < <(find "${PATCH_DIR}" -type f \( -iname "*.patch" -o -iname "*.diff" \) -print || true)
        else
            echo "[WARN] Patch directory ${PATCH_DIR} not found. Searching entire repo for patch files as fallback..."
            mapfile -t PATCH_FILES < <(find "${SUSFS_WORKDIR}" -type f \( -iname "*.patch" -o -iname "*.diff" \) -print || true)
        fi
    fi

    echo "[INFO] Found ${#PATCH_FILES[@]} patch file(s) to consider."

    applied_count=0
    skipped_count=0
    failed_count=0

    for p in "${PATCH_FILES[@]:-}"; do
        [ -f "$p" ] || continue
        echo "[INFO] Processing patch: $p"

        # Pre-check
        if git apply --check --whitespace=nowarn "$p" 2>/dev/null; then
            echo "[INFO] Patch cleanly checks out. Applying via git apply..."
            if git apply --whitespace=nowarn "$p"; then
                echo "[OK] Applied $p"
                applied_count=$((applied_count+1))
                continue
            else
                echo "[WARN] git apply failed even though check passed. Will try fallbacks..."
            fi
        else
            echo "[WARN] git apply --check failed for $p. Will try fallback methods..."
        fi

        # Fallback 1: try git apply with 3-way merge
        if git apply --3way --whitespace=nowarn "$p" 2>/dev/null; then
            echo "[OK] Applied via git apply --3way: $p"
            applied_count=$((applied_count+1))
            continue
        else
            echo "[WARN] git apply --3way failed for $p."
        fi

        # Fallback 2: try patch --merge
        if patch -p1 --merge < "$p" 2>/dev/null; then
            echo "[OK] Applied via patch --merge: $p"
            applied_count=$((applied_count+1))
            continue
        else
            echo "[WARN] patch --merge failed for $p."
        fi

        # Special-case: if patch touches gki_defconfig, apply config changes directly
        if grep -q "arch/arm64/configs/gki_defconfig" "$p" 2>/dev/null; then
            echo "[INFO] Patch touches gki_defconfig. Attempting to apply CONFIG_* lines directly."
            if apply_gki_defconfig_patch "$p"; then
                echo "[OK] Applied config changes from $p"
                applied_count=$((applied_count+1))
                continue
            else
                echo "[WARN] apply_gki_defconfig_patch failed for $p."
            fi
        fi

        # Last resort: create rejects and try to continue
        echo "[WARN] Attempting git apply --reject to produce .rej (non-fatal)."
        if git apply --reject --whitespace=nowarn "$p" 2>/dev/null; then
            echo "[INFO] git apply --reject produced rejects for $p (check .rej files). Treating as skipped/partial."
            skipped_count=$((skipped_count+1))
            continue
        else
            echo "[WARN] git apply --reject also failed for $p."
        fi

        # If we reach here, this patch failed all strategies
        echo "[ERROR] Failed to apply $p by all methods."
        failed_count=$((failed_count+1))
        if [ "${STRICT_SUSFS_PATCH}" = "1" ]; then
            echo "[ERROR] STRICT_SUSFS_PATCH=1 and a patch failed -> aborting SUSFS integration."
            return 1
        else
            echo "[WARN] Skipping failed patch (STRICT_SUSFS_PATCH=0). Continuing with remaining patches."
            continue
        fi
    done

    echo "[INFO] Patch apply summary: applied=${applied_count}, skipped=${skipped_count}, failed=${failed_count}"

    # Try to build/copy userspace binary (non-fatal)
    cd "${SUSFS_WORKDIR}" || return 0
    if [ -x "./build_ksu_susfs_tool.sh" ]; then
        echo "[INFO] Found build_ksu_susfs_tool.sh. Attempting to build ksu_susfs..."
        export AARCH64_CC="aarch64-linux-gnu-gcc"
        chmod +x ./build_ksu_susfs_tool.sh || true
        if ./build_ksu_susfs_tool.sh; then
            echo "[INFO] SUSFS userland build script finished."
        else
            echo "[WARN] SUSFS userland build script failed (non-fatal). Searching repo for binaries."
        fi
    else
        echo "[INFO] No SUSFS build script found; searching for prebuilt binaries."
    fi

    cd "${KERNEL_ROOT}" || return 0
    mkdir -p AnyKernel3/ksu/bin
    mapfile -t SUSFS_BIN_CANDIDATES < <(find "${SUSFS_WORKDIR}" -type f -iname "ksu_susfs*" -o -iname "sus_su*" 2>/dev/null || true)

    if [ "${#SUSFS_BIN_CANDIDATES[@]}" -eq 0 ]; then
        TMP_MODULE="${KERNEL_ROOT}/.susfs_module"
        rm -rf "${TMP_MODULE}"
        if git clone --depth 1 "${SUSFS_MODULE_REPO}" "${TMP_MODULE}" 2>/dev/null; then
            mapfile -t SUSFS_BIN_CANDIDATES < <(find "${TMP_MODULE}" -type f -iname "ksu_susfs*" -o -iname "sus_su*" 2>/dev/null || true)
        fi
    fi

    for cand in "${SUSFS_BIN_CANDIDATES[@]:-}"; do
        [ -f "$cand" ] || continue
        file_out=$(file "$cand" 2>/dev/null || true)
        if echo "$file_out" | grep -qi "aarch64"; then
            cp "$cand" AnyKernel3/ksu/bin/ksu_susfs
            chmod +x AnyKernel3/ksu/bin/ksu_susfs || true
            echo "[INFO] Copied aarch64 userspace binary into AnyKernel3/ksu/bin/"
            break
        fi
        cp "$cand" AnyKernel3/ksu/bin/ksu_susfs
        chmod +x AnyKernel3/ksu/bin/ksu_susfs || true
        echo "[INFO] Copied fallback userspace binary into AnyKernel3/ksu/bin/"
        break
    done

    echo "[INFO] SUSFS integration completed."
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
