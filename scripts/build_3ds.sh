#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/build_3ds.sh [--run] <target.nim> [output-name]

Build a Nintendo 3DS .3dsx for a Nim target using devkitARM/libctru.

Examples:
  scripts/build_3ds.sh examples/observy_3ds.nim observy_3ds
  scripts/build_3ds.sh --run examples/observy_3ds.nim observy_3ds

Environment:
  OBSERVY_HTTP_SRC  Path to the ~/git/http src directory (default: ../http/src)
  NIMFLAGS_3DS      Extra flags passed to nim c for this build

--run deploys the built .3dsx with 3dslink after a successful build.
USAGE
}

run_after_build=0
if [[ "${1:-}" == "--run" ]]; then
  run_after_build=1
  shift
fi

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage >&2
  exit 2
fi

target=$1
name=${2:-$(basename "${target%.nim}")}
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
build_dir="$repo_root/build"
nim_cfg="$repo_root/nim.cfg"
template_cfg="$repo_root/nim_3ds.cfg"
http_src=${OBSERVY_HTTP_SRC:-"$repo_root/../http/src"}

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required tool: $1" >&2
    echo "Install devkitPro 3DS tools, for example: dkp-pacman -S 3ds-dev" >&2
    exit 1
  fi
}

need nim
need arm-none-eabi-ar
need 3dsxtool
if [[ "$run_after_build" -eq 1 ]]; then
  need 3dslink
fi

if [[ ! -f "$template_cfg" ]]; then
  echo "missing $template_cfg" >&2
  exit 1
fi

if [[ ! -d "$http_src" ]]; then
  echo "missing http library source directory: $http_src" >&2
  echo "Set OBSERVY_HTTP_SRC to the src directory from ~/git/http." >&2
  exit 1
fi

mkdir -p "$repo_root/stubs" "$build_dir"
if [[ ! -f "$repo_root/stubs/libdl.a" ]]; then
  arm-none-eabi-ar rcs "$repo_root/stubs/libdl.a"
fi
if [[ ! -f "$repo_root/stubs/librt.a" ]]; then
  arm-none-eabi-ar rcs "$repo_root/stubs/librt.a"
fi

if [[ -e "$nim_cfg" ]]; then
  echo "$nim_cfg already exists; refusing to overwrite it" >&2
  exit 1
fi

cleanup() {
  rm -f "$nim_cfg"
}
trap cleanup EXIT

cp -f "$template_cfg" "$nim_cfg"

cd "$repo_root"
extra_flags=()
if [[ -n "${NIMFLAGS_3DS:-}" ]]; then
  read -r -a extra_flags <<< "$NIMFLAGS_3DS"
fi
nim c -d:ds3 -d:release --path:"$http_src" "${extra_flags[@]}" --out:"$build_dir/$name.elf" "$target"
3dsxtool "$build_dir/$name.elf" "$build_dir/$name.3dsx"

echo "built $build_dir/$name.3dsx"

if [[ "$run_after_build" -eq 1 ]]; then
  3dslink "$build_dir/$name.3dsx"
fi
