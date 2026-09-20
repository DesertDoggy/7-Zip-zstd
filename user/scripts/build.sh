#!/usr/bin/env bash
set -euo pipefail

# Build selected 7-Zip-zstd target with the sibling zlib-ng submodule's own
# release output, statically linked in. This wrapper avoids touching core makefiles.
# Works both when this repo is the top-level checkout and when it is nested as
# a submodule (e.g. romexplorer/submodules/7-Zip-zstd) -- all paths are resolved
# relative to this script's own location, never the caller's CWD.
#
# zlib-ng is picked up directly from ../zlib-ng/user/release/<platform>/<arch>/
# (sibling submodule, built via zlib-ng's own user/scripts/build-zlib-ng-release.sh)
# -- there is no separate staged copy to keep in sync.
#
# Usage:
#   user/scripts/build-with-user-zlib-ng.sh
#   user/scripts/build-with-user-zlib-ng.sh <platform> <arch> [target]
#
# Targets:
#   format7zf -> CPP/7zip/Bundles/Format7zF/makefile.gcc (7z.dylib / 7z.so / 7z.dll)
#   alone2  -> CPP/7zip/Bundles/Alone2/makefile.gcc (7zz)
#   console -> CPP/7zip/UI/Console/makefile.gcc (7z)
#
# Default mode (no arguments):
#   - Detect platform and arch from current system.
#   - Pick newest zlib-ng version found in ../zlib-ng/user/release/<platform>/<arch>/
#   - Use target=format7zf (dynamic library).
#
# zlib-ng is linked in statically (.../static/libz.a) and is not shipped or
# loaded as a separate runtime dependency.
#
# Output release version (the version segment of user/release/<platform>/<arch>/<version>/...)
# is always derived from this repo's own git tags, independent of the zlib-ng
# dependency version picked above.

if [[ $# -ne 0 && $# -ne 2 && $# -ne 3 ]]; then
  echo "[ERROR] Usage: $0  OR  $0 <platform> <arch> [target]" >&2
  exit 2
fi

script_dir="$(cd "$(dirname "$0")" && pwd)"
user_dir="$(cd "$script_dir/.." && pwd)"
repo_root="$(cd "$user_dir/.." && pwd)"
submodules_root="$(cd "$repo_root/.." && pwd)"
zlibng_root="$submodules_root/zlib-ng"
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

  target="format7zf"
else
  platform="$1"
  arch="$2"
  target="${3:-format7zf}"
fi

# zlib-ng dependency version: always auto-pick the newest one available for
# platform/arch from the sibling zlib-ng submodule's own release output,
# regardless of whether platform/arch were auto-detected or passed explicitly.
# This is independent of the output release version below.
if [[ ! -d "$zlibng_root" ]]; then
  echo "[ERROR] zlib-ng submodule not found at: $zlibng_root" >&2
  echo "[ERROR] Expected the 'zlib-ng' submodule at submodules/zlib-ng (sibling of 7-Zip-zstd)." >&2
  exit 2
fi

versions_root="$zlibng_root/user/release/$platform/$arch"
if [[ ! -d "$versions_root" ]]; then
  echo "[ERROR] Missing zlib-ng release output: $versions_root" >&2
  echo "[ERROR] Build it first: (cd \"$zlibng_root/user\" && ./scripts/build-zlib-ng-release.sh), or pass a different <platform> <arch>." >&2
  exit 3
fi

zlibng_version="$(find "$versions_root" -mindepth 1 -maxdepth 1 -type d -print | sed 's#.*/##' | sort -V | tail -n 1)"
if [[ -z "$zlibng_version" ]]; then
  echo "[ERROR] No version directories found under: $versions_root" >&2
  exit 3
fi

# Output release version: this repo's own version, independent of the zlib-ng
# dependency version above. Falls back to "dev" when no tags are reachable.
output_version="$(git -C "$repo_root" describe --tags 2>/dev/null || echo dev)"

deps_base="$versions_root/$zlibng_version"
include_dir="$deps_base/include"
static_dir="$deps_base/static"

[[ -d "$include_dir" ]] || { echo "[ERROR] missing include: $include_dir" >&2; exit 3; }
[[ -d "$static_dir" ]] || { echo "[ERROR] missing static: $static_dir" >&2; exit 3; }

case "$platform" in
  mac|linux)
    static_lib="$static_dir/libz.a"
    [[ -f "$static_lib" ]] || { echo "[ERROR] missing $static_lib" >&2; exit 4; }
    ;;
  windows)
    static_lib=""
    for candidate in "$static_dir/libz.a" "$static_dir/zlibstatic.lib" "$static_dir/zlib.lib"; do
      if [[ -f "$candidate" ]]; then
        static_lib="$candidate"
        break
      fi
    done
    [[ -n "$static_lib" ]] || { echo "[ERROR] no static zlib-ng lib (libz.a / zlibstatic.lib / zlib.lib) found under $static_dir" >&2; exit 4; }
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

# build_dir is disposable scratch space -- put it in the OS temp dir and always
# remove it on exit (success or failure), so every build is a clean build and
# nothing lingers in the repo. This also avoids repeating a long path (e.g. a
# git-describe output_version like "v26.02-v1.5.7-R2-51-gba3e822f") as a prefix
# on every one of the 300+ object files format7zf links, which previously blew
# past Windows' ~32K argument-length limit ("Argument list too long").
# out_dir (the final release destination) keeps $output_version -- only the
# throwaway intermediate build dir does not.
build_dir="$(mktemp -d /tmp/7zbuild.XXXXXX)"
trap 'rm -rf "$build_dir"' EXIT

if [[ "$target" == "format7zf" ]]; then
  out_dir="$user_dir/release/$platform/$arch/$output_version/dynamic"
else
  out_dir="$user_dir/release/$platform/$arch/$output_version/$target"
fi
mkdir -p "$build_dir" "$out_dir"

arch_flags=()
case "$arch" in
  arm64)
    # USE_ASM intentionally omitted (not just set to 0): GNU Make's `ifdef`
    # only checks whether a variable is defined, so USE_ASM=0 would still
    # count as defined and re-trigger the ASM rules in 7zip_gcc.mak/LzmaDec_gcc.mak.
    arch_flags=(IS_ARM64=1)
    ;;
  x64|x86_64)
    # These .asm sources (Asm/x86/*.asm: 7zAsm.asm [shared macros, not compiled
    # standalone], 7zCrcOpt, AesOpt, LzFindOpt, LzmaDecOpt, Sha1Opt, Sha256Opt,
    # Sort, XzCrc64Opt) are MASM-family syntax -- NASM cannot parse them (different
    # preprocessor syntax entirely). UASM/JWASM/ASMC are multi-target assemblers
    # that support both Windows COFF (-win64) and Linux ELF (-elf64) output despite
    # the MASM syntax, so the same search applies on both platforms; 7zip_gcc.mak
    # has no macOS/Mach-O AFLAGS_ABI branch at all, so ASM is never attempted there
    # -- mac always uses the plain C fallback for these routines.
    #
    # uasm is tried before asmc (despite asmc being 7zip_gcc.mak's own hardcoded
    # default): verified directly that asmc fails to assemble Sha1Opt.asm's
    # SHA1RNDS4 macro ("initializer too large for specified size" in MY_sha1rnds4)
    # while uasm assembles the exact same file cleanly (0 errors) -- a real asmc
    # compatibility bug with this macro construct, not an issue in the source.
    asm_tool=""
    if [[ "$platform" == "windows" || "$platform" == "linux" ]]; then
      for candidate in uasm uasm64 UASM UASM64 jwasm jwasm64 asmc asmc64 ml64; do
        if command -v "$candidate" >/dev/null 2>&1; then
          asm_tool="$candidate"
          break
        fi
      done
      if [[ -z "$asm_tool" && "$platform" == "windows" ]]; then
        # Fall back to known fixed install locations directly, independent of
        # whatever PATH this shell happens to have. uasm first (see note above
        # on the asmc Sha1Opt.asm incompatibility); asmc kept as a last resort.
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
    fi
    if [[ -n "$asm_tool" ]]; then
      # AFLAGS_ABI overrides the makefile's own per-platform assignment (GNU
      # Make command-line vars win over in-makefile assignments) to add -c:
      # without it, asmc/uasm/jwasm try to auto-link each .asm into an
      # executable after assembling (MASM-family default), which fails --
      # we only want a .o here, final linking is done later by gcc/g++.
      arch_flags=(IS_X64=1 USE_ASM=1 "MY_ASM=$asm_tool")
      if [[ "$platform" == "windows" ]]; then
        arch_flags+=("AFLAGS_ABI=-win64 -c")
      elif [[ "$platform" == "linux" ]]; then
        arch_flags+=("AFLAGS_ABI=-elf64 -DABI_LINUX -c")
      fi
    else
      # NOTE: GNU Make's `ifdef` only checks whether a variable is defined, not
      # its value -- USE_ASM=0 would still count as "defined" and re-trigger the
      # ASM rules, so USE_ASM must be omitted entirely to actually disable it.
      if [[ "$platform" == "mac" ]]; then
        echo "[INFO] ASM not supported for mac in this makefile (no Mach-O AFLAGS_ABI branch); using C fallback." >&2
      else
        echo "[WARN] No MASM-compatible assembler (asmc/uasm/jwasm/ml64) found in PATH${platform:+ or under C:\\uasm/C:\\asmc}." >&2
        echo "[WARN] Building without hand-tuned x86_64 ASM; functionally identical, just C fallback for those routines." >&2
      fi
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

{
  echo "[INFO] platform=$platform arch=$arch target=$target"
  echo "[INFO] zlibng_version=$zlibng_version (dependency, statically linked)"
  echo "[INFO] output_version=$output_version (release output path)"
  echo "[INFO] include_dir=$include_dir"
  echo "[INFO] static_lib=$static_lib"
  echo "[INFO] make_dir=$make_dir"
  echo "[INFO] build_dir=$build_dir"
  echo "[INFO] out_dir=$out_dir"
} | tee -a "$log_file"

cd "$make_dir"

# MASM-family assemblers (asmc/uasm/jwasm/ml64) are native Win32 tools invoked
# with a glued -Fo<path> flag. We convert O= to a Windows-style path (cygpath -m)
# so it is a valid path for them -- but MSYS's own implicit argv translation then
# re-mangles that already-correct path a second time (it spots the embedded
# "/Documents/..." after "D:" and re-roots it under the MSYS install dir,
# producing garbage like "D:C:/msys64/Documents/..."). MSYS2_ARG_CONV_EXCL tells
# MSYS to leave -Fo<path> arguments alone entirely so our pre-converted path
# reaches the assembler unmodified.
#
# O= is also repeated as a prefix on every single object file in the final
# link command (format7zf links in every format/codec .o -- hundreds of them),
# so a long path here can blow past Windows' ~32K command-line limit ("Argument
# list too long"); build_dir now lives in the short OS temp dir specifically to
# keep this cheap. (A path relative to make_dir would be even shorter, but
# build_dir can now be on a different drive than the repo -- e.g. temp on C:,
# repo on D: -- where a relative path isn't even expressible, so we always use
# an absolute Windows-style path here instead.)
o_value="$build_dir"
if [[ "$platform" == "windows" ]] && command -v cygpath >/dev/null 2>&1; then
  o_value="$(cygpath -m "$build_dir")"
fi

make_vars=(
  "O=$o_value"
  "CFLAGS_BASE2=-I$include_dir"
  "CXXFLAGS_BASE2=-I$include_dir"
  "MY_LIBS=$static_lib"
)
if [[ "$platform" == "windows" ]]; then
  # CFLAGS_WARN_WALL overrides the makefile's own "-Werror -Wall -Wextra"
  # (GNU Make command-line vars win over in-makefile assignments), appending
  # -Wno-cast-function-type after -Wextra so it actually takes effect (GCC
  # applies later warning flags over earlier ones for the same warning).
  # Needed because C/fast-lzma2/util.c's Windows CPU-count detection casts
  # GetProcAddress()'s FARPROC to a specific function pointer type -- the
  # standard, unavoidable idiom for calling a dynamically-resolved WinAPI
  # function, which newer GCC's -Wcast-function-type (implied by -Wextra)
  # flags as an error under -Werror.
  make_vars+=("CFLAGS_WARN_WALL=-Werror -Wall -Wextra -Wno-cast-function-type")
fi

set -x
MSYS2_ARG_CONV_EXCL="-Fo" \
make -f makefile.gcc "${arch_flags[@]}" "${make_vars[@]}" 2>&1 | tee -a "$log_file"
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
  # Normalize install name for app embedding usage. zlib-ng is statically
  # linked in above, so there is no side-by-side zlib dylib to ship or rpath.
  if command -v install_name_tool >/dev/null 2>&1; then
    install_name_tool -id "@rpath/7z.dylib" "$out_dir/$copy_name"
  fi
fi

echo "[INFO] build finished, binary: $built_bin" | tee -a "$log_file"
echo "[INFO] copied output to: $out_dir/$copy_name" | tee -a "$log_file"
