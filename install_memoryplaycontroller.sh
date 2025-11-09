#!/bin/bash

# ==============================================================================
#
# build_mpc.sh - Autonomous builder for MemoryPlayControllerSDK
#
# Description:
#   This script automates the process of compiling the
#   MemoryPlayControllerSDK and its FLAC dependency. It auto-detects
#   the CPU architecture, GCC version, and host system to apply optimal
#   compiler flags and link against the correct pre-compiled libraries.
#
# Usage:
#   ./build_mpc.sh <MPC_VERSION> <FLAC_VERSION>
#
# Example:
#   ./build_mpc.sh 0_144_1 1.4.3
#
# ==============================================================================

# --- Configuration and Helpers ---
set -euo pipefail

C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_BLUE='\033[0;34m'
C_NC='\033[0m' # No Color

die() {
    echo -e "${C_RED}ERROR: $*${C_NC}" >&2
    exit 1
}

info() {
    echo -e "${C_BLUE}INFO: $*${C_NC}"
}

# --- Cleanup Function ---
SAVED_DIR=""
cleanup() {
  if [[ -n "$SAVED_DIR" ]]; then
    info "Returning to the original directory: $SAVED_DIR"
    cd "$SAVED_DIR" 2>/dev/null
  fi
}
trap cleanup EXIT


# --- Main Logic ---

main() {
    # --- 1. Argument Validation ---
    if [[ $# -ne 2 ]]; then
        die "Invalid arguments. Usage: $0 <MPC_VERSION> <FLAC_VERSION>\nExample: $0 0_144_1 1.4.3"
    fi

    local mpc_version="$1"
    local flac_version="$2"

    info "Starting MemoryPlayController installation..."
    info "MPC Version: ${C_YELLOW}${mpc_version}${C_NC}"
    info "FLAC Version: ${C_YELLOW}${flac_version}${C_NC}"

    # --- 2. Environment Detection for Makefile ---
    info "Detecting system environment to build library name..."

    # Detect GCC Major Version (e.g., 15)
    local gcc_major
    gcc_major=$(gcc -dumpversion | cut -d. -f1)
    info "Detected GCC Major Version: ${C_YELLOW}${gcc_major}${C_NC}"

    # Detect CPU Architecture and set compiler flags + library suffix
    local kcflags
    local cpu_suffix
    if gcc -march=native -Q --help=target | grep -q 'znver4'; then
        info "Detected CPU: ${C_YELLOW}AMD Zen 4${C_NC}"
        cpu_suffix="zen4"
        kcflags="-march=znver4 -mtune=znver4 -O3"
    elif /lib/ld-linux-x86-64.so.2 --help 2>/dev/null | grep -q 'x86-64-v4'; then
        info "Detected CPU supporting: ${C_YELLOW}x86-64-v4${C_NC}"
        cpu_suffix="v4"
        kcflags="-march=x86-64-v4 -O3"
    elif /lib/ld-linux-x86-64.so.2 --help 2>/dev/null | grep -q 'x86-64-v3'; then
        info "Detected CPU supporting: ${C_YELLOW}x86-64-v3${C_NC}"
        cpu_suffix="v3"
        kcflags="-march=x86-64-v3 -O3"
    elif /lib/ld-linux-x86-64.so.2 --help 2>/dev/null | grep -q 'x86-64-v2'; then
        info "Detected CPU supporting: ${C_YELLOW}x86-64-v2${C_NC}"
        cpu_suffix="v2"
        kcflags="-march=x86-64-v2 -O3"
    else
        die "Unsupported CPU architecture. Could not determine x86-64-v2/v3/v4/zen4 support."
    fi
    
    # *** CRITICAL FIX ***
    # The Makefile uses ARCH_NAME as the *entire* suffix for the library files.
    # We construct this string here, e.g., "x64-linux-15zen4".
    local makefile_arch_name="x64-linux-${gcc_major}${cpu_suffix}"
    info "Constructed Makefile ARCH_NAME: ${C_YELLOW}${makefile_arch_name}${C_NC}"
    info "Using KCFLAGS: ${C_YELLOW}${kcflags}${C_NC}"

    # --- 3. Setup and Compilation ---
    SAVED_DIR=$(pwd)
    local build_dir="/home/$USER"
    cd "$build_dir" || die "Failed to change directory to ${build_dir}"
    info "Changed directory to ${build_dir}"

    local mpc_archive="MemoryPlayControllerSDK_${mpc_version}.tar.zst"
    local flac_archive="flac-${flac_version}.tar.xz"
    local flac_url="https://github.com/xiph/flac/releases/download/${flac_version}/${flac_archive}"
    local sdk_dir="MemoryPlayControllerSDK"
    local flac_src_dir="flac-${flac_version}"

    # Download FLAC source
    if [[ ! -f "$flac_archive" ]]; then
        info "Downloading FLAC source from ${flac_url}"
        wget --no-verbose -c "$flac_url" || die "Failed to download FLAC source"
    else
        info "FLAC source archive already exists."
    fi

    # Extract SDK and FLAC
    info "Extracting ${mpc_archive}..."
    tar --use-compress-program=unzstd -xvf "$mpc_archive" || die "Failed to extract SDK"
    info "Extracting ${flac_archive}..."
    tar xvf "$flac_archive" || die "Failed to extract FLAC"

    # --- 4. Build FLAC ---
    info "Configuring and building FLAC..."
    local flac_target_dir="${sdk_dir}/flac"

    info "Preparing FLAC source tree inside ${sdk_dir}"
    rm -rf "${flac_target_dir}"
    mv "${flac_src_dir}" "${flac_target_dir}" || die "Failed to move FLAC source directory"
    
    cd "$flac_target_dir" || die "Failed to enter FLAC directory: ${flac_target_dir}"

    # Detect Host Triplet for './configure'
    local host_triplet
    host_triplet=$(gcc -dumpmachine)
    info "Configuring FLAC for host ${C_YELLOW}${host_triplet}${C_NC}..."
    ./configure --host="$host_triplet" --disable-ogg --enable-static || die "Failed to configure FLAC"

    info "Compiling FLAC..."
    make "KCFLAGS=${kcflags}" -j"$(nproc)" || die "Failed to compile FLAC"
    
    cd .. || die "Failed to return to SDK root directory"
    info "FLAC compiled successfully."

    # --- 5. Build MemoryPlayController SDK ---
    info "Configuring and building MemoryPlayController SDK..."

    info "Patching Makefile to remove '-static' from LDFLAGS..."
    sed -i 's/ -static//g' Makefile || die "'sed' operation on Makefile failed"

    info "Compiling SDK with custom ARCH_NAME and KCFLAGS..."
    make \
      "ARCH_NAME=${makefile_arch_name}" \
      "KCFLAGS=${kcflags}" \
      -j"$(nproc)" \
    || die "Failed to make SDK"

    echo -e "\n${C_GREEN}MemoryPlayController compiled successfully!${C_NC}"
}

# --- Script Entry Point ---
main "$@"
