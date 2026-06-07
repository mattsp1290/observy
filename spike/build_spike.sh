#!/usr/bin/env bash
# Build the M0 networking spike to a .3dsx. Throwaway scaffolding for the gate.
set -euo pipefail
cd "$(dirname "$0")"

export DEVKITPRO="${DEVKITPRO:-/opt/devkitpro}"
export DEVKITARM="${DEVKITARM:-$DEVKITPRO/devkitARM}"
export PATH="$DEVKITPRO/tools/bin:$DEVKITARM/bin:$PATH"

SRC="${1:-net_spike_3ds.nim}"
NAME="${2:-net_spike}"
mkdir -p build

# -d:ds3 selects the arc/threads:off branch in ../config.nims.
# Toolchain (devkitARM paths, passC/passL) comes from <SRC>.nim.cfg.
nim c -d:ds3 -d:release --out:build/"$NAME".elf "$SRC"

3dsxtool build/"$NAME".elf build/"$NAME".3dsx
echo "built: spike/build/$NAME.3dsx"
