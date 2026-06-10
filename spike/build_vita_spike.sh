#!/usr/bin/env bash
# Build the M0 PlayStation Vita networking/time spike to a .vpk.
set -euo pipefail
cd "$(dirname "$0")/.."

usage() {
  cat <<'USAGE'
Usage: spike/build_vita_spike.sh [target.nim] [output-name]

Build a headless PlayStation Vita .vpk for the observy M0 spike.

Environment:
  VITASDK           VitaSDK root (required; usually /usr/local/vitasdk)
  OBSERVY_HTTP_SRC  Path to the ~/git/http src directory (default: ../http/src)
  NIMFLAGS_VITA     Extra flags passed to nim c for this build
  TITLE_ID          Vita title id (default: OBSV00001)
USAGE
}

if [[ $# -gt 2 ]]; then
  usage >&2
  exit 2
fi

if [[ -z "${VITASDK:-}" ]]; then
  echo "VITASDK is required, for example: export VITASDK=/usr/local/vitasdk" >&2
  echo "Install VitaSDK from https://vitasdk.org and bootstrap packages with vdpm." >&2
  exit 1
fi
if [[ "$VITASDK" != "/usr/local/vitasdk" ]]; then
  echo "this M0 spike cfg currently assumes VITASDK=/usr/local/vitasdk" >&2
  echo "got: $VITASDK" >&2
  echo "M1 will productize a repo-root nim_vita.cfg/build script; keep the spike fixed-path for now." >&2
  exit 1
fi

export PATH="$VITASDK/bin:$PATH"

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required Vita tool: $1" >&2
    echo "Install VitaSDK from https://vitasdk.org and bootstrap packages with vdpm." >&2
    exit 1
  fi
}

need nim
need arm-vita-eabi-gcc
need arm-vita-eabi-ar
need vita-elf-create
need vita-make-fself
need vita-mksfoex
need zip

target=${1:-spike/observy_vita_spike.nim}
name=${2:-observy_vita_spike}
repo_root=$(pwd)
build_dir="$repo_root/spike/build"
http_src=${OBSERVY_HTTP_SRC:-"$repo_root/../http/src"}
title_id=${TITLE_ID:-OBSV00001}

if [[ ! -f "$target" ]]; then
  echo "missing target: $target" >&2
  exit 1
fi

if [[ ! -d "$http_src" ]]; then
  echo "missing http library source directory: $http_src" >&2
  echo "Set OBSERVY_HTTP_SRC to the src directory from ~/git/http." >&2
  exit 1
fi

mkdir -p "$repo_root/stubs" "$build_dir"
if [[ ! -f "$repo_root/stubs/libdl.a" ]]; then
  arm-vita-eabi-ar rcs "$repo_root/stubs/libdl.a"
fi
if [[ ! -f "$repo_root/stubs/librt.a" ]]; then
  arm-vita-eabi-ar rcs "$repo_root/stubs/librt.a"
fi

extra_flags=()
if [[ -n "${NIMFLAGS_VITA:-}" ]]; then
  read -r -a extra_flags <<< "$NIMFLAGS_VITA"
fi

nim c -d:vita -d:release --path:"$http_src" "${extra_flags[@]}" \
  --out:"$build_dir/$name.elf" "$target"

vita-elf-create "$build_dir/$name.elf" "$build_dir/$name.velf"
vita-make-fself "$build_dir/$name.velf" "$build_dir/eboot.bin"
vita-mksfoex -s "TITLE_ID=$title_id" "$name" "$build_dir/param.sfo"

stage="$build_dir/vpk_stage"
rm -rf "$stage"
mkdir -p "$stage/sce_sys"
cp -f "$build_dir/eboot.bin" "$stage/"
cp -f "$build_dir/param.sfo" "$stage/sce_sys/"
( cd "$stage" && zip -qr "../$name.vpk" . )

echo "built: $build_dir/$name.vpk"
echo "deploy with VitaShell FTP, for example:"
echo "  curl -T $build_dir/$name.vpk ftp://<vita-ip>:1337/ux0:/"
