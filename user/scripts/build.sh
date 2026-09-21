#!/usr/bin/env bash
set -euo pipefail

# Builds sevenzip.dll / libsevenzip.so / libsevenzip.dylib: a zip+7z-only archive
# library (see user/sevenzip_lib.h) using user/Makefile.sevenzip_lib. This wrapper
# avoids touching core makefiles -- see Makefile.sevenzip_lib's own header comment for
# why it is invoked from inside CPP/7zip/Bundles/Format7zF/ (an existing, untouched
# directory used purely as a stable relative-path anchor for 7zip_gcc.mak's rules).
#
# Usage:
#   user/scripts/build_sevenzip_lib.sh                 # auto-detect platform/arch
#   user/scripts/build_sevenzip_lib.sh <platform> <arch>

if [[ $# -ne 0 && $# -ne 2 ]]; then
  echo "[ERROR] Usage: $0  OR  $0 <platform> <arch>" >&2
  exit 2
fi

script_dir="$(cd "$(dirname "$0")" && pwd)"
user_dir="$(cd "$script_dir/.." && pwd)"
repo_root="$(cd "$user_dir/.." && pwd)"
make_dir="$repo_root/CPP/7zip/Bundles/Format7zF"
log_dir="$user_dir/logs"
mkdir -p "$log_dir"
log_file="$log_dir/build-sevenzip-$(date +%Y%m%d-%H%M%S).log"

if [[ $# -eq 0 ]]; then
  os_name="$(uname -s)"
  cpu_name="$(uname -m)"

  case "$os_name" in
    Darwin) platform="mac" ;;
    Linux) platform="linux" ;;
    MINGW*|MSYS*|CYGWIN*) platform="windows" ;;
    *) echo "[ERROR] Unsupported OS for auto-detect: $os_name" >&2; exit 2 ;;
  esac

  case "$cpu_name" in
    arm64|aarch64) arch="arm64" ;;
    x86_64|amd64) arch="x64" ;;
    i386|i686|x86) arch="x86" ;;
    *) echo "[ERROR] Unsupported arch for auto-detect: $cpu_name" >&2; exit 2 ;;
  esac
else
  platform="$1"
  arch="$2"
fi

output_version="$(git -C "$repo_root" describe --tags 2>/dev/null || echo dev)"

# Disposable scratch build dir -- see build.sh's own history for why: object paths get
# repeated once per linked object, and a long path here can blow past Windows' ~32K
# command-line limit. Always removed on exit, success or failure.
build_dir="$(mktemp -d /tmp/sevenzip_build.XXXXXX)"
trap 'rm -rf "$build_dir"' EXIT

out_dir="$user_dir/release/$platform/$arch/$output_version"
mkdir -p "$build_dir" "$out_dir"

arch_flags=()
case "$arch" in
  arm64)
    # USE_ASM intentionally omitted, not set to 0: GNU Make's `ifdef` only checks
    # whether a variable is defined, so USE_ASM=0 would still count as defined and
    # re-trigger the ASM rules in 7zip_gcc.mak/LzmaDec_gcc.mak.
    arch_flags=(IS_ARM64=1)
    ;;
  x64|x86_64)
    if [[ "$platform" == "windows" ]]; then
      # These specific object files (Sha1Opt/Sha256Opt/Sha512Opt/7zCrcOpt/XzCrc64Opt) are
      # MASM-family hand-tuned x86_64 asm, gated behind USE_ASM in 7zip_gcc.mak -- same
      # asm dependency build.sh already solved. uasm before asmc: verified directly (see
      # build.sh's own history) that asmc fails to assemble Sha1Opt.asm's SHA1RNDS4
      # macro while uasm handles the same file cleanly.
      asm_tool=""
      for candidate in uasm uasm64 UASM UASM64 jwasm jwasm64 asmc asmc64 ml64; do
        if command -v "$candidate" >/dev/null 2>&1; then
          asm_tool="$candidate"
          break
        fi
      done
      if [[ -z "$asm_tool" ]]; then
        for fixed_path in /c/uasm/uasm64.exe /c/uasm/uasm.exe \
          "/c/Program Files/uasm/uasm64.exe" "/c/Program Files/uasm/uasm.exe" \
          /c/jwasm/jwasm.exe \
          /c/asmc/asmc64.exe /c/asmc/asmc.exe; do
          if [[ -f "$fixed_path" ]]; then
            asm_tool="$fixed_path"
            break
          fi
        done
      fi
      if [[ -n "$asm_tool" ]]; then
        arch_flags=(IS_X64=1 USE_ASM=1 "MY_ASM=$asm_tool" "AFLAGS_ABI=-win64 -c")
      else
        echo "[WARN] No MASM-compatible assembler (uasm/asmc/jwasm/ml64) found in PATH or under C:\\uasm/C:\\asmc." >&2
        echo "[WARN] Building without hand-tuned x86_64 ASM; functionally identical, just C fallback for those routines." >&2
        arch_flags=(IS_X64=1)
      fi
    elif [[ "$platform" == "linux" ]]; then
      # Linux only needs LzmaDecOpt.asm -- hashing (Sha1/Sha256/CrcOpt) goes through
      # Rust crates, not this library, and AesOpt.asm isn't needed either. LzmaDecOpt
      # is gated independently via USE_LZMA_DEC_ASM (decoupled from USE_ASM, which
      # would also pull in Sha1Opt/Sha256Opt/AesOpt/CrcOpt). jwasm verified clean on
      # LzmaDecOpt.asm; asmc has a confirmed evaluator bug on Sha1Opt.asm's SHA1RNDS4
      # macro (irrelevant here since USE_ASM stays unset), and jwasm separately lacks
      # the AES-NI/AVX2 opcodes AesOpt.asm needs (also irrelevant here).
      asm_tool=""
      for candidate in jwasm jwasm64 uasm uasm64; do
        if command -v "$candidate" >/dev/null 2>&1; then
          asm_tool="$candidate"
          break
        fi
      done
      if [[ -n "$asm_tool" ]]; then
        arch_flags=(IS_X64=1 USE_LZMA_DEC_ASM=1 "MY_ASM=$asm_tool" "AFLAGS_ABI=-elf64 -DABI_LINUX -c")
      else
        echo "[WARN] No MASM-compatible assembler (jwasm/uasm) found in PATH." >&2
        echo "[WARN] Building without hand-tuned LzmaDecOpt ASM; functionally identical, just C fallback." >&2
        arch_flags=(IS_X64=1)
      fi
    else
      echo "[INFO] ASM not supported for mac in this makefile (no Mach-O AFLAGS_ABI branch); using C fallback." >&2
      arch_flags=(IS_X64=1)
    fi
    ;;
  x86|i386)
    arch_flags=(IS_X86=1)
    ;;
  *)
    echo "[ERROR] unsupported arch: $arch" >&2
    exit 2
    ;;
esac

o_value="$build_dir"
if [[ "$platform" == "windows" ]] && command -v cygpath >/dev/null 2>&1; then
  o_value="$(cygpath -m "$build_dir")"
fi

make_vars=("O=$o_value")
if [[ "$platform" == "windows" ]]; then
  # See build.sh's own history: needed because C/fast-lzma2/util.c's Windows
  # CPU-count detection casts GetProcAddress()'s FARPROC to a specific function
  # pointer type -- the standard, unavoidable idiom for calling a dynamically
  # resolved WinAPI function, which newer GCC's -Wcast-function-type (implied by
  # -Wextra) flags as an error under -Werror.
  make_vars+=("CFLAGS_WARN_WALL=-Werror -Wall -Wextra -Wno-cast-function-type")
fi

{
  echo "[INFO] platform=$platform arch=$arch output_version=$output_version"
  echo "[INFO] make_dir=$make_dir"
  echo "[INFO] build_dir=$build_dir"
  echo "[INFO] out_dir=$out_dir"
} | tee -a "$log_file"

cd "$make_dir"

set -x
MSYS2_ARG_CONV_EXCL="-Fo" \
make -f "$user_dir/Makefile.sevenzip_lib" "${arch_flags[@]}" "${make_vars[@]}" 2>&1 | tee -a "$log_file"
set +x

case "$platform" in
  windows) out_name="7z.dll" ;;
  mac) out_name="7z.dylib" ;;
  *) out_name="7z.so" ;;
esac

built_bin=""
if [[ "$platform" == "mac" ]]; then
  # Upstream makefile typically emits 7z.so even on mac; expose a mac-friendly
  # 7z.dylib in release output (same fallback build.sh used).
  if [[ -f "$build_dir/7z.dylib" ]]; then
    built_bin="$build_dir/7z.dylib"
  elif [[ -f "$build_dir/7z.so" ]]; then
    built_bin="$build_dir/7z.so"
  fi
elif [[ "$platform" == "windows" ]]; then
  [[ -f "$build_dir/7z.dll" ]] && built_bin="$build_dir/7z.dll"
else
  [[ -f "$build_dir/7z.so" ]] && built_bin="$build_dir/7z.so"
fi

if [[ -z "$built_bin" || ! -f "$built_bin" ]]; then
  echo "[ERROR] Built binary not found in: $build_dir" | tee -a "$log_file"
  exit 5
fi

cp -f "$built_bin" "$out_dir/$out_name"

if [[ "$platform" == "mac" ]] && command -v install_name_tool >/dev/null 2>&1; then
  install_name_tool -id "@rpath/$out_name" "$out_dir/$out_name"
fi

echo "[INFO] build finished, binary: $built_bin" | tee -a "$log_file"
echo "[INFO] copied output to: $out_dir/$out_name" | tee -a "$log_file"
