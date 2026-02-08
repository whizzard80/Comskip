#!/bin/bash
# Wrapper script to ensure we use the local fork build, not system comskip

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORK_BINARY="${SCRIPT_DIR}/Comskip/comskip"

# Ensure we use local build
if [ ! -f "${FORK_BINARY}" ]; then
    echo "Error: Fork binary not found at ${FORK_BINARY}" >&2
    echo "Please build it first: cd Comskip && PKG_CONFIG_PATH=/usr/local/lib/ffmpeg/pkgconfig:\$PKG_CONFIG_PATH make" >&2
    exit 1
fi

# Set PKG_CONFIG_PATH for runtime if needed
export PKG_CONFIG_PATH=/usr/local/lib/ffmpeg/pkgconfig:${PKG_CONFIG_PATH}

# Default to sports ini if it exists and no --ini was passed
HAS_INI=0
for arg in "$@"; do
    case "$arg" in --ini=*) HAS_INI=1 ;; esac
done

if [ "$HAS_INI" -eq 0 ] && [ -f "${SCRIPT_DIR}/comskip-sports.ini" ]; then
    exec "${FORK_BINARY}" --ini="${SCRIPT_DIR}/comskip-sports.ini" "$@"
elif [ "$HAS_INI" -eq 0 ] && [ -f "${SCRIPT_DIR}/comskip.ini" ]; then
    exec "${FORK_BINARY}" --ini="${SCRIPT_DIR}/comskip.ini" "$@"
else
    exec "${FORK_BINARY}" "$@"
fi
