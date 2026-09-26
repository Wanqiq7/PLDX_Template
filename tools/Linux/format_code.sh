#!/usr/bin/env bash
# 对应 tools/Windows/format_code.ps1。
# 使用 clang-format（默认 21.1.8）格式化 Modules/ 下的 C/C++ 文件。
# 自举顺序: CLANG_FORMAT_BIN -> 本地 cache/venv -> venv 安装 -> 官方 LLVM 归档下载。
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

MODE='format'
REQUIRED_VERSION="${CLANG_FORMAT_REQUIRED_VERSION:-21.1.8}"

usage() {
  cat <<'EOF'
Usage:
  tools/Linux/format_code.sh [--check]

Description:
  Format C/C++ files under Modules/ using clang-format.
  Requires clang-format version 21.1.8 by default.

Options:
  --check   Run clang-format in dry-run mode with --Werror.
  -h, --help
EOF
}

if [ $# -gt 0 ]; then
  case "$1" in
    --check) MODE='check' ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 2
      ;;
  esac
fi

die() { echo "Error: $*" >&2; exit 1; }

command_exists() { command -v "$1" >/dev/null 2>&1; }
is_exec_file() { [ -n "$1" ] && [ -f "$1" ]; }

host_platform() {
  case "$(uname -s)" in
    Linux*) printf 'linux' ;;
    Darwin*) printf 'darwin' ;;
    MINGW* | MSYS* | CYGWIN*) printf 'win32' ;;
    *) printf 'unknown' ;;
  esac
}

host_arch() {
  local a
  a="$(uname -m)"
  case "$a" in
    x86_64 | amd64 | AMD64) printf 'x86_64' ;;
    arm64 | aarch64 | ARM64) printf 'arm64' ;;
    *) printf '%s' "$(printf '%s' "$a" | tr '[:upper:]' '[:lower:]')" ;;
  esac
}

CLANG_FORMAT_BIN="${CLANG_FORMAT_BIN:-}"
PLATFORM="$(host_platform)"
ARCH="$(host_arch)"
CACHE_DIR="$REPO_ROOT/.cache/clang-format"
TOOL_ROOT="$CACHE_DIR/llvm-$REQUIRED_VERSION-$PLATFORM-$ARCH"

clang_format_version() {
  is_exec_file "$1" || { printf ''; return 0; }
  local out
  out="$("$1" --version 2>/dev/null)" || { printf ''; return 0; }
  printf '%s' "$out" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1
}

# 查找顺序对应 ps1 Find-ExistingClangFormat（bin/Scripts 两种 venv 布局都试）。
find_existing_clang_format() {
  local c
  for c in \
    "$TOOL_ROOT/bin/clang-format" \
    "$TOOL_ROOT/bin/clang-format.exe" \
    "$REPO_ROOT/.venv-clang-format/bin/clang-format" \
    "$REPO_ROOT/.venv-clang-format/Scripts/clang-format.exe" \
    "$REPO_ROOT/../.venv-clang-format/bin/clang-format" \
    "$REPO_ROOT/../.venv-clang-format/Scripts/clang-format.exe"; do
    if is_exec_file "$c"; then
      printf '%s' "$c"
      return 0
    fi
  done
  if command_exists clang-format.exe; then command -v clang-format.exe; return 0; fi
  if command_exists clang-format; then command -v clang-format; return 0; fi
  return 1
}

# 官方 LLVM 资产名映射（与 ps1 Get-LlvmAssetPattern 一致）。
llvm_asset_pattern() {
  local v="$3"
  case "$1:$2" in
    win32:x86_64) printf '^clang\\+llvm-%s-x86_64-pc-windows-msvc\\.tar\\.xz$' "$v" ;;
    win32:arm64) printf '^clang\\+llvm-%s-aarch64-pc-windows-msvc\\.tar\\.xz$' "$v" ;;
    linux:x86_64) printf '^LLVM-%s-Linux-X64\\.tar\\.xz$' "$v" ;;
    linux:arm64) printf '^LLVM-%s-Linux-ARM64\\.tar\\.xz$' "$v" ;;
    darwin:arm64) printf '^LLVM-%s-macOS-ARM64\\.tar\\.xz$' "$v" ;;
    darwin:x86_64) printf '^LLVM-%s-macOS-X64\\.tar\\.xz$|^clang\\+llvm-%s-x86_64-apple-darwin.*\\.tar\\.xz$' "$v" "$v" ;;
    *) printf '' ;;
  esac
}

pick_python() {
  if command_exists python3; then printf 'python3'; return 0; fi
  if command_exists python; then printf 'python'; return 0; fi
  return 1
}

# 通过 venv 安装 pip 版 clang-format（对应 ps1 Install-LocalClangFormatVenv）。
install_local_clang_format_venv() {
  local py
  py="$(pick_python)" || die '未找到 Python。请安装 Python 3，或手动设置 CLANG_FORMAT_BIN。'
  local venv_dir="$REPO_ROOT/.venv-clang-format"
  echo "Preparing local clang-format $REQUIRED_VERSION in $venv_dir..."

  if [ ! -d "$venv_dir" ]; then
    "$py" -m venv "$venv_dir" || die "创建 Python venv 失败: $venv_dir"
  fi

  local venv_python='' clang_bin=''
  if [ -f "$venv_dir/bin/python" ]; then
    venv_python="$venv_dir/bin/python"
    clang_bin="$venv_dir/bin/clang-format"
  elif [ -f "$venv_dir/Scripts/python.exe" ]; then
    venv_python="$venv_dir/Scripts/python.exe"
    clang_bin="$venv_dir/Scripts/clang-format.exe"
  else
    die "创建 Python venv 失败: $venv_dir"
  fi

  "$venv_python" -m pip install --upgrade pip || die "pip 升级失败 (exit $?)"
  "$venv_python" -m pip install "clang-format==$REQUIRED_VERSION" || die "安装 clang-format==$REQUIRED_VERSION 失败 (exit $?)"
  is_exec_file "$clang_bin" || die "pip 安装 clang-format 后未找到可执行文件: $clang_bin"
  CLANG_FORMAT_BIN="$clang_bin"
}

# 官方 LLVM 归档下载并抽取 clang-format + 动态库（对应 ps1 Install-OfficialClangFormat）。
install_official_clang_format() {
  local py
  py="$(pick_python)" || die '未找到 Python。请安装 Python 3，或手动设置 CLANG_FORMAT_BIN。'

  local pattern
  pattern="$(llvm_asset_pattern "$PLATFORM" "$ARCH" "$REQUIRED_VERSION")"
  [ -n "$pattern" ] || die "没有适用于 $PLATFORM/$ARCH 的官方 LLVM clang-format 包映射。"

  mkdir -p "$CACHE_DIR"
  local archive_path="$CACHE_DIR/clang-format-$REQUIRED_VERSION-$PLATFORM-$ARCH.tar.xz"

  if [ ! -f "$archive_path" ]; then
    echo "Downloading official LLVM clang-format $REQUIRED_VERSION for $PLATFORM/$ARCH..."
    "$py" - "$REQUIRED_VERSION" "$pattern" "$archive_path" <<'PYEOF'
import json
import re
import sys
import urllib.request

version, pattern, archive_path = sys.argv[1:4]
api_url = f"https://api.github.com/repos/llvm/llvm-project/releases/tags/llvmorg-{version}"

with urllib.request.urlopen(api_url) as response:
    release = json.load(response)

asset = next(
    (candidate for candidate in release.get("assets", []) if re.fullmatch(pattern, candidate["name"])),
    None,
)

if asset is None:
    raise SystemExit(f"No LLVM clang-format archive matches pattern: {pattern}")

urllib.request.urlretrieve(asset["browser_download_url"], archive_path)
print(f"Downloaded {asset['name']}")
PYEOF
    [ $? -eq 0 ] || die "下载 LLVM clang-format 失败。"
  fi

  rm -rf "$TOOL_ROOT"
  mkdir -p "$TOOL_ROOT"

  tar -tf "$archive_path" >/dev/null 2>&1 || die "无法列出 LLVM 压缩包内容: $archive_path"

  local entry_re
  case "$PLATFORM" in
    win32) entry_re='(^|/)bin/(clang-format\.exe|.*\.dll)$' ;;
    darwin) entry_re='(^|/)bin/clang-format$|(^|/)(bin|lib)/.*\.dylib$' ;;
    *) entry_re='(^|/)bin/clang-format$|(^|/)(bin|lib)/.*\.so(\..*)?$' ;;
  esac

  local entries_file="$CACHE_DIR/entries-$PLATFORM-$ARCH.txt"
  tar -tf "$archive_path" | grep -E "$entry_re" > "$entries_file"
  [ -s "$entries_file" ] || die "未能在 $archive_path 中定位 clang-format 文件。"

  tar -xf "$archive_path" -C "$TOOL_ROOT" --strip-components=1 -T "$entries_file" ||
    die "解压 LLVM clang-format 失败: $archive_path"
  rm -f "$archive_path" "$entries_file"

  case "$PLATFORM" in
    win32) CLANG_FORMAT_BIN="$TOOL_ROOT/bin/clang-format.exe" ;;
    *) CLANG_FORMAT_BIN="$TOOL_ROOT/bin/clang-format" ;;
  esac
}

# ---------------- 主流程（对应 ps1 L329-383）----------------

if [ -z "$CLANG_FORMAT_BIN" ]; then
  CLANG_FORMAT_BIN="$(find_existing_clang_format || printf '')"
fi

CF_VERSION="$(clang_format_version "$CLANG_FORMAT_BIN")"

if [ -z "$CLANG_FORMAT_BIN" ] || [ "$CF_VERSION" != "$REQUIRED_VERSION" ]; then
  install_local_clang_format_venv
  CF_VERSION="$(clang_format_version "$CLANG_FORMAT_BIN")"
  if [ "$CF_VERSION" != "$REQUIRED_VERSION" ]; then
    install_official_clang_format
    CF_VERSION="$(clang_format_version "$CLANG_FORMAT_BIN")"
  fi
fi

[ -n "$CF_VERSION" ] || die "无法从 $CLANG_FORMAT_BIN 解析 clang-format 版本。"
[ "$CF_VERSION" = "$REQUIRED_VERSION" ] || die "未能准备 clang-format $REQUIRED_VERSION；在 $CLANG_FORMAT_BIN 找到 $CF_VERSION。"

if [ ! -d 'Modules' ]; then
  # 无 Modules 目录时无可格式化文件，直接成功返回（对应 ps1 Get-SourceFiles 空列表）。
  echo 'No Modules/ directory; nothing to format.'
  exit 0
fi

if [ "$MODE" = 'check' ]; then
  CF_ARGS=(--dry-run --Werror --style=file)
  find Modules -type f \( -name '*.c' -o -name '*.cc' -o -name '*.cpp' -o -name '*.cxx' -o -name '*.h' -o -name '*.hh' -o -name '*.hpp' -o -name '*.hxx' \) -print0 2>/dev/null |
    xargs -0 -r -n 80 "$CLANG_FORMAT_BIN" "${CF_ARGS[@]}" || die "clang-format 失败 (exit $?)"
  echo 'clang-format check passed for Modules/.'
else
  CF_ARGS=(-i --style=file)
  find Modules -type f \( -name '*.c' -o -name '*.cc' -o -name '*.cpp' -o -name '*.cxx' -o -name '*.h' -o -name '*.hh' -o -name '*.hpp' -o -name '*.hxx' \) -print0 2>/dev/null |
    xargs -0 -r -n 80 "$CLANG_FORMAT_BIN" "${CF_ARGS[@]}" || die "clang-format 失败 (exit $?)"
  echo 'Formatted C/C++ files under Modules/.'
fi

exit 0
