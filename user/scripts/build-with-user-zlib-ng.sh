#!/usr/bin/env bash
set -euo pipefail

# Build selected 7-Zip-zstd target with user-scoped zlib-ng dynamic dependency hints.
# This wrapper avoids touching core makefiles.
#
# Usage:
#   user/scripts/build-with-user-zlib-ng.sh
#   user/scripts/build-with-user-zlib-ng.sh <platform> <arch> <version> <target>
#
# Targets:
#   format7zf -> CPP/7zip/Bundles/Format7zF/makefile.gcc (7z.dylib / 7z.so / 7z.dll)
#   alone2  -> CPP/7zip/Bundles/Alone2/makefile.gcc (7zz)
#   console -> CPP/7zip/UI/Console/makefile.gcc (7z)
#
# Default mode (no arguments):
#   - Detect platform and arch from current system.
#   - Pick newest version found in user/deps/zlib-ng/<platform>/<arch>/
#   - Use target=format7zf (dynamic library).

if [[ $# -ne 0 && $# -ne 4 ]]; then
  echo "[ERROR] Usage: $0 OR $0 <platform> <arch> <version> <target>" >&2
  exit 2
fi

script_dir="$(cd "$(dirname "$0")" && pwd)"
user_dir="$(cd "$script_dir/.." && pwd)"
repo_root="$(cd "$user_dir/.." && pwd)"
log_dir="$user_dir/logs"
mkdir -p "$log_dir"
log_file="$log_dir/build-$(date +%Y%m%d-%H%M%S).log"

if [[ $# -eq 0 ]]; then
  os_name="$(uname -s)"
  cpu_name="$(uname -m)"

  case "$os_name" in
    Darwin)
      platform="mac"
      ;;
    Linux)
      platform="linux"
      ;;
    MINGW*|MSYS*|CYGWIN*)
      platform="windows"
      ;;
    *)
      echo "[ERROR] Unsupported OS for auto-detect: $os_name" >&2
      exit 2
      ;;
  esac

  case "$cpu_name" in
    arm64|aarch64)
      arch="arm64"
      ;;
    x86_64|amd64)
      arch="x64"
      ;;
    i386|i686|x86)
      arch="x86"
      ;;
    *)
      echo "[ERROR] Unsupported arch for auto-detect: $cpu_name" >&2
      exit 2
      ;;
  esac

  versions_root="$user_dir/deps/zlib-ng/$platform/$arch"
  if [[ ! -d "$versions_root" ]]; then
    echo "[ERROR] Missing dependency root: $versions_root" >&2
    echo "[ERROR] Provide explicit args: <platform> <arch> <version> <target>" >&2
    exit 3
  fi

  version="$(find "$versions_root" -mindepth 1 -maxdepth 1 -type d -print | sed 's#.*/##' | sort -V | tail -n 1)"
  if [[ -z "$version" ]]; then
    echo "[ERROR] No version directories found under: $versions_root" >&2
    exit 3
  fi

  target="format7zf"
else
  platform="$1"
  arch="$2"
  version="$3"
  target="$4"
fi

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
  format7zf)
    make_dir="$repo_root/CPP/7zip/Bundles/Format7zF"
    if [[ "$platform" == "windows" ]]; then
      out_name="7z.dll"
    elif [[ "$platform" == "mac" ]]; then
      out_name="7z.dylib"
    else
      out_name="7z.so"
    fi
    ;;
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

build_dir="$user_dir/release/_build/$platform/$arch/$version/$target"
if [[ "$target" == "format7zf" ]]; then
  out_dir="$user_dir/release/$platform/$arch/$version/dynamic"
else
  out_dir="$user_dir/release/$platform/$arch/$version/$target"
fi
mkdir -p "$build_dir" "$out_dir"

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
  echo "[INFO] build_dir=$build_dir"
  echo "[INFO] out_dir=$out_dir"
} | tee -a "$log_file"

cd "$make_dir"

set -x
make -f makefile.gcc $arch_flags \
  O="$build_dir" \
  CFLAGS_BASE2="-I$include_dir" \
  CXXFLAGS_BASE2="-I$include_dir" \
  MY_LIBS="-L$dynamic_dir $rpath_flag -lz" 2>&1 | tee -a "$log_file"
set +x

built_bin=""
copy_name="$out_name"

if [[ "$target" == "format7zf" && "$platform" == "mac" ]]; then
  # Upstream makefile typically emits 7z.so; expose a mac-friendly 7z.dylib in release output.
  if [[ -f "$build_dir/7z.dylib" ]]; then
    built_bin="$build_dir/7z.dylib"
    copy_name="7z.dylib"
  elif [[ -f "$build_dir/7z.so" ]]; then
    built_bin="$build_dir/7z.so"
    copy_name="7z.dylib"
  fi
else
  if [[ -f "$build_dir/$out_name" ]]; then
    built_bin="$build_dir/$out_name"
  elif [[ -f "$build_dir/$out_name.exe" ]]; then
    built_bin="$build_dir/$out_name.exe"
    copy_name="$(basename "$built_bin")"
  fi
fi

if [[ ! -f "$built_bin" ]]; then
  echo "[ERROR] Built binary not found in: $build_dir" | tee -a "$log_file"
  exit 5
fi

cp -f "$built_bin" "$out_dir/$copy_name"

if [[ "$target" == "format7zf" && "$platform" == "mac" ]]; then
  # Normalize install name for app embedding usage.
  if command -v install_name_tool >/dev/null 2>&1; then
    install_name_tool -id "@rpath/7z.dylib" "$out_dir/$copy_name"
  fi

  # Ship zlib side-by-side for runtime dependency resolution.
  if [[ -f "$dynamic_dir/libz.dylib" ]]; then
    cp -f "$dynamic_dir/libz.dylib" "$out_dir/libz.dylib"
  fi
  if [[ -L "$dynamic_dir/libz.1.dylib" ]]; then
    ln -sfn "libz.dylib" "$out_dir/libz.1.dylib"
  elif [[ -f "$dynamic_dir/libz.1.dylib" ]]; then
    cp -f "$dynamic_dir/libz.1.dylib" "$out_dir/libz.1.dylib"
  fi
fi

echo "[INFO] build finished, binary: $built_bin" | tee -a "$log_file"
echo "[INFO] copied output to: $out_dir/$copy_name" | tee -a "$log_file"
