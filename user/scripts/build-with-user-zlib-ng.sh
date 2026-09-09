#!/usr/bin/env bash
set -euo pipefail

# Build selected 7-Zip-zstd target with user-scoped zlib-ng dynamic dependency hints.
# This wrapper avoids touching core makefiles.
#
# Usage:
#   user/scripts/build-with-user-zlib-ng.sh <platform> <arch> <version> <target>
#
# Targets:
#   alone2  -> CPP/7zip/Bundles/Alone2/makefile.gcc (7zz)
#   console -> CPP/7zip/UI/Console/makefile.gcc (7z)

if [[ $# -ne 4 ]]; then
  echo "[ERROR] Usage: $0 <platform> <arch> <version> <target>" >&2
  exit 2
fi

platform="$1"
arch="$2"
version="$3"
target="$4"

script_dir="$(cd "$(dirname "$0")" && pwd)"
user_dir="$(cd "$script_dir/.." && pwd)"
repo_root="$(cd "$user_dir/.." && pwd)"
log_dir="$user_dir/logs"
mkdir -p "$log_dir"
log_file="$log_dir/build-$(date +%Y%m%d-%H%M%S).log"

deps_base="$user_dir/deps/zlib-ng/$platform/$arch/$version"
include_dir="$deps_base/include"
dynamic_dir="$deps_base/dynamic"

[[ -d "$include_dir" ]] || { echo "[ERROR] missing include: $include_dir" >&2; exit 3; }
[[ -d "$dynamic_dir" ]] || { echo "[ERROR] missing dynamic: $dynamic_dir" >&2; exit 3; }

case "$platform" in
  mac)
    lib_file="$dynamic_dir/libz.dylib"
    [[ -f "$lib_file" ]] || { echo "[ERROR] missing $lib_file" >&2; exit 4; }
    rpath_flag="-Wl,-rpath,$dynamic_dir"
    ;;
  linux)
    if ! ls "$dynamic_dir"/libz.so* >/dev/null 2>&1; then
      echo "[ERROR] missing $dynamic_dir/libz.so*" >&2
      exit 4
    fi
    rpath_flag="-Wl,-rpath,$dynamic_dir"
    ;;
  windows)
    if ! ls "$dynamic_dir"/*.dll >/dev/null 2>&1; then
      echo "[ERROR] missing $dynamic_dir/*.dll" >&2
      exit 4
    fi
    rpath_flag=""
    ;;
  *)
    echo "[ERROR] unsupported platform: $platform" >&2
    exit 2
    ;;
esac

case "$target" in
  alone2)
    make_dir="$repo_root/CPP/7zip/Bundles/Alone2"
    out_name="7zz"
    ;;
  console)
    make_dir="$repo_root/CPP/7zip/UI/Console"
    out_name="7z"
    ;;
  *)
    echo "[ERROR] unsupported target: $target" >&2
    exit 2
    ;;
esac

case "$arch" in
  arm64)
    arch_flags="IS_ARM64=1 USE_ASM=0"
    ;;
  x64|x86_64)
    arch_flags="IS_X64=1 USE_ASM=1 MY_ASM=uasm"
    ;;
  x86|i386)
    arch_flags="IS_X86=1 USE_ASM=0"
    ;;
  *)
    echo "[ERROR] unsupported arch: $arch" >&2
    exit 2
    ;;
esac

{
  echo "[INFO] platform=$platform arch=$arch version=$version target=$target"
  echo "[INFO] include_dir=$include_dir"
  echo "[INFO] dynamic_dir=$dynamic_dir"
  echo "[INFO] make_dir=$make_dir"
} | tee -a "$log_file"

cd "$make_dir"

set -x
make -f makefile.gcc $arch_flags \
  CFLAGS_BASE2="-I$include_dir" \
  CXXFLAGS_BASE2="-I$include_dir" \
  MY_LIBS="-L$dynamic_dir $rpath_flag -lz" 2>&1 | tee -a "$log_file"
set +x

echo "[INFO] build finished, expected output under: $make_dir/_o/$out_name" | tee -a "$log_file"
