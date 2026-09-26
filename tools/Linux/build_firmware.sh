#!/usr/bin/env bash
# 由 buildchassis.sh / buildgimbal.sh source。对应 tools/Windows/build_firmware.ps1。
# 流程: 1) clang-format Modules/  2) cube-cmake(或 cmake) configure  3) build
set -u

if [ -z "${USAGENAME:-}" ]; then
  echo '请通过 tools/Linux/buildchassis.sh 或 tools/Linux/buildgimbal.sh 调用。' >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

die() { echo "Error: $*" >&2; exit 1; }

run_or_die() {
  "$@"
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "命令失败 (exit $rc): $*" >&2
    exit "$rc"
  fi
  return 0
}

usage() {
  cat <<EOF
Usage:
  $USAGENAME [options]

Description:
  1) Run clang-format for C/C++ files under Modules/
  2) Configure firmware and its generated xrobot header with cube-cmake
  3) Build firmware with cube-cmake

Options:
  -c, --config <path>     YAML config path (default: $DEFAULT_CONFIG_PRIMARY)
  -p, --preset <name>     CMake preset name (default: \$CMAKE_BUILD_PRESET or debug)
  -b, --build-dir <dir>   Build dir (overrides --preset)
      --skip-format       Skip clang-format step
  -h, --help              Show this help message

Examples:
  $USAGENAME
  $USAGENAME -p release
  $USAGENAME -c $DEFAULT_CONFIG_PRIMARY -p relWithDebInfo
  $USAGENAME -c $DEFAULT_CONFIG_PRIMARY -b $DEFAULT_BUILD_DIR
EOF
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

add_path_front() {
  [ -n "$1" ] && [ -d "$1" ] || return 0
  case ":$PATH:" in *":$1:"*) return 0 ;; esac
  PATH="$1:$PATH"
}

find_latest_subdir() {
  [ -d "$1" ] || return 1
  local d
  d="$(find "$1" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -n 1)"
  [ -n "$d" ] || return 1
  printf '%s' "$d"
}

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
    aarch64 | arm64 | ARM64) printf 'aarch64' ;;
    *) printf '%s' "$(printf '%s' "$a" | tr '[:upper:]' '[:lower:]')" ;;
  esac
}

# 在编辑器扩展目录中查找工具（对应 ps1 Find-ToolInExtensions）。
# $1 = 扩展目录前缀, $2 = 相对候选路径（含 {platform}/{arch} 占位符）
find_tool_in_extensions() {
  local prefix="$1" rel="$2"
  local platform arch
  platform="$(host_platform)"
  arch="$(host_arch)"

  local -a roots=()
  [ -n "${VSCODE_EXTENSIONS:-}" ] && [ -d "$VSCODE_EXTENSIONS" ] && roots+=("$VSCODE_EXTENSIONS")
  local r
  for r in \
    "$HOME/.vscode/extensions" \
    "$HOME/.vscode-insiders/extensions" \
    "$HOME/.vscode-oss/extensions" \
    "$HOME/.cursor/extensions" \
    "$HOME/.windsurf/extensions"; do
    [ -d "$r" ] && roots+=("$r")
  done

  local root ext cand full
  for root in ${roots[@]+"${roots[@]}"}; do
    for ext in "$root/$prefix"*/; do
      [ -d "$ext" ] || continue
      cand="${rel//\{platform\}/$platform}"
      cand="${cand//\{arch\}/$arch}"
      full="$ext$cand"
      if [ -f "$full" ]; then printf '%s' "$full"; return 0; fi
      if [ -f "$full.exe" ]; then printf '%s' "$full.exe"; return 0; fi
    done
  done
  return 1
}

# STM32Cube bundle 根目录（对应 ps1 Get-Stm32BundleRoots；
# $HOME/AppData/Local/... 一项使同一脚本在 Git Bash 与 Linux 均可命中）。
get_bundle_roots() {
  [ -n "${CUBE_BUNDLE_PATH:-}" ] && [ -d "$CUBE_BUNDLE_PATH" ] && printf '%s\n' "$CUBE_BUNDLE_PATH"
  local r
  for r in \
    "$HOME/AppData/Local/stm32cube/bundles" \
    "$HOME/.stm32cube/bundles" \
    "$HOME/.local/share/stm32cube/bundles" \
    "$HOME/.config/stm32cube/bundles"; do
    [ -d "$r" ] && printf '%s\n' "$r"
  done
  return 0
}

# STM32CubeCLT 安装根目录（Windows: C:\ST\STM32CubeCLT_*；Linux: /opt/st/...）。
get_cubeclt_roots() {
  local p
  case "$(uname -s)" in
    MINGW* | MSYS* | CYGWIN*)
      for p in /c/ST/STM32CubeCLT_*/; do [ -d "$p" ] && printf '%s\n' "${p%/}"; done
      ;;
    Linux*)
      for p in /opt/st/*[Ss][Tt][Mm]32[Cc]ube[Cc][Ll][Tt]*/ /opt/STM32CubeCLT_*/; do
        [ -d "$p" ] && printf '%s\n' "${p%/}"
      done
      ;;
  esac
  return 0
}

resolve_local_python_tools() {
  local tool_root="$REPO_ROOT/.tooling/python"
  [ -d "$tool_root" ] || return 0
  if [ -n "${PYTHONPATH:-}" ]; then
    PYTHONPATH="$tool_root:$PYTHONPATH"
  else
    PYTHONPATH="$tool_root"
  fi
  export PYTHONPATH
  add_path_front "$tool_root/bin"
  add_path_front "$tool_root/Scripts"
}

CUBE_BIN=''
CUBE_CMAKE_BIN=''

resolve_cube_cli() {
  if command_exists cube; then
    CUBE_BIN="$(command -v cube)"
    return 0
  fi
  local d
  d="$(find_tool_in_extensions 'stmicroelectronics.stm32cube-ide-core-' 'resources/binaries/{platform}/{arch}/cube')" || return 1
  CUBE_BIN="$d"
  add_path_front "$(dirname "$d")"
  echo "[preflight] cube not in PATH; using STM32 extension copy at $CUBE_BIN."
  return 0
}

resolve_cube_cmake() {
  if command_exists cube-cmake; then
    CUBE_CMAKE_BIN="$(command -v cube-cmake)"
    return 0
  fi
  local d
  if d="$(find_tool_in_extensions 'stmicroelectronics.stm32cube-ide-build-cmake-' 'resources/cube-cmake/{platform}/{arch}/cube-cmake')"; then
    CUBE_CMAKE_BIN="$d"
    add_path_front "$(dirname "$d")"
    echo "[preflight] cube-cmake not in PATH; using STM32 extension copy at $CUBE_CMAKE_BIN."
    return 0
  fi
  if command_exists cmake; then
    CUBE_CMAKE_BIN="$(command -v cmake)"
    echo "[preflight] cube-cmake not found; using cmake at $CUBE_CMAKE_BIN."
    return 0
  fi
  return 1
}

resolve_stm32_toolchains() {
  # 失效的环境变量先清理（对应 ps1 Resolve-Stm32Toolchains 开头）。
  if [ -n "${GCC_TOOLCHAIN_ROOT:-}" ] && [ ! -d "$GCC_TOOLCHAIN_ROOT" ]; then
    unset GCC_TOOLCHAIN_ROOT
  fi
  if [ -n "${CLANG_GCC_CMSIS_COMPILER:-}" ] && [ ! -d "$CLANG_GCC_CMSIS_COMPILER" ]; then
    unset CLANG_GCC_CMSIS_COMPILER
  fi

  local detected_gcc='' detected_clang=''
  local root latest bindir

  # 1) STM32Cube bundles（gnu-tools-for-stm32 取最新版本的 bin）
  while IFS= read -r root; do
    if [ -z "${GCC_TOOLCHAIN_ROOT:-}" ] && [ -z "$detected_gcc" ]; then
      if latest="$(find_latest_subdir "$root/gnu-tools-for-stm32")"; then
        bindir="$latest/bin"
        if [ -d "$bindir" ]; then detected_gcc="$bindir"; else detected_gcc="$latest"; fi
      fi
    fi
    if [ -z "${CLANG_GCC_CMSIS_COMPILER:-}" ] && [ -z "$detected_clang" ]; then
      if latest="$(find_latest_subdir "$root/st-arm-clang")"; then
        detected_clang="$latest"
      fi
    fi
    if { [ -n "${GCC_TOOLCHAIN_ROOT:-}" ] || [ -n "$detected_gcc" ]; } &&
      { [ -n "${CLANG_GCC_CMSIS_COMPILER:-}" ] || [ -n "$detected_clang" ]; }; then
      break
    fi
  done < <(get_bundle_roots)

  # 2) STM32CubeCLT 安装目录兜底
  if { [ -z "${GCC_TOOLCHAIN_ROOT:-}" ] && [ -z "$detected_gcc" ]; } ||
    { [ -z "${CLANG_GCC_CMSIS_COMPILER:-}" ] && [ -z "$detected_clang" ]; }; then
    local clt
    while IFS= read -r clt; do
      if [ -z "${GCC_TOOLCHAIN_ROOT:-}" ] && [ -z "$detected_gcc" ]; then
        if [ -d "$clt/GNU-tools-for-STM32/bin" ]; then
          detected_gcc="$clt/GNU-tools-for-STM32/bin"
        elif [ -d "$clt/STM32CubeCLT/GNU-tools-for-STM32/bin" ]; then
          detected_gcc="$clt/STM32CubeCLT/GNU-tools-for-STM32/bin"
        fi
      fi
      if [ -z "${CLANG_GCC_CMSIS_COMPILER:-}" ] && [ -z "$detected_clang" ]; then
        if [ -d "$clt/st-arm-clang" ]; then
          detected_clang="$clt/st-arm-clang"
        elif [ -d "$clt/STM32CubeCLT/st-arm-clang" ]; then
          detected_clang="$clt/STM32CubeCLT/st-arm-clang"
        fi
      fi
    done < <(get_cubeclt_roots)
  fi

  if [ -z "${GCC_TOOLCHAIN_ROOT:-}" ] && [ -n "$detected_gcc" ]; then
    GCC_TOOLCHAIN_ROOT="$detected_gcc"
    echo "[preflight] GCC_TOOLCHAIN_ROOT not set; using $GCC_TOOLCHAIN_ROOT."
  fi
  if [ -z "${CLANG_GCC_CMSIS_COMPILER:-}" ] && [ -n "$detected_clang" ]; then
    CLANG_GCC_CMSIS_COMPILER="$detected_clang"
    echo "[preflight] CLANG_GCC_CMSIS_COMPILER not set; using $CLANG_GCC_CMSIS_COMPILER."
  fi

  [ -n "${GCC_TOOLCHAIN_ROOT:-}" ] && add_path_front "$GCC_TOOLCHAIN_ROOT"
  [ -n "${CLANG_GCC_CMSIS_COMPILER:-}" ] && add_path_front "$CLANG_GCC_CMSIS_COMPILER/bin"
  return 0
}

resolve_ninja() {
  command_exists ninja && return 0
  local root latest clt
  while IFS= read -r root; do
    latest="$(find_latest_subdir "$root/ninja")" || continue
    if [ -f "$latest/bin/ninja" ]; then
      add_path_front "$latest/bin"
      echo "[preflight] ninja not in PATH; using $latest/bin/ninja."
      return 0
    fi
  done < <(get_bundle_roots)
  while IFS= read -r clt; do
    if [ -f "$clt/Ninja/bin/ninja" ]; then
      add_path_front "$clt/Ninja/bin"
      echo "[preflight] ninja not in PATH; using $clt/Ninja/bin/ninja."
      return 0
    fi
    if [ -f "$clt/STM32CubeCLT/Ninja/bin/ninja" ]; then
      add_path_front "$clt/STM32CubeCLT/Ninja/bin"
      echo "[preflight] ninja not in PATH; using $clt/STM32CubeCLT/Ninja/bin/ninja."
      return 0
    fi
  done < <(get_cubeclt_roots)
  echo 'Error: ninja not found in PATH or STM32 Cube bundle directories.' >&2
  return 1
}

preset_build_type() {
  case "$1" in
    debug) printf 'Debug' ;;
    relWithDebInfo) printf 'RelWithDebInfo' ;;
    release) printf 'Release' ;;
    minSizeRel) printf 'MinSizeRel' ;;
    *) printf 'Debug' ;;
  esac
}

# 构建目录与当前仓库不匹配时清掉旧 cache（对应 ps1 Reset-IncompatibleCMakeCache）。
reset_incompatible_cmake_cache() {
  local cache="$BUILD_PATH/CMakeCache.txt"
  [ -f "$cache" ] || return 0
  local home_dir
  home_dir="$(sed -n 's/^CMAKE_HOME_DIRECTORY:INTERNAL=//p' "$cache" | head -n 1)"
  [ -n "$home_dir" ] || return 0

  normalize_path() {
    local v
    v="$(realpath -m "$1" 2>/dev/null || printf '%s' "$1")"
    v="${v%/}"
    # Git Bash 下把 /d/... 与 d:/... 视为同一位置
    v="$(printf '%s' "$v" | sed -E 's#^/([A-Za-z])/#\1:/#')"
    printf '%s' "$v" | tr '[:upper:]' '[:lower:]'
  }

  local cached_norm current_norm
  cached_norm="$(normalize_path "$home_dir")"
  current_norm="$(normalize_path "$REPO_ROOT")"
  [ "$cached_norm" = "$current_norm" ] && return 0

  echo "[preflight] CMake cache was created at $home_dir; resetting $BUILD_PATH for $REPO_ROOT."
  rm -f "$cache"
  rm -rf "$BUILD_PATH/CMakeFiles"
}

# ---------------- 参数解析 ----------------

CONFIG=''
DEFAULT_PRESET='debug'
PRESET="${CMAKE_BUILD_PRESET:-${CMAKE_PRESET:-}}"
BUILD_DIR="$DEFAULT_BUILD_DIR"
SKIP_FORMAT=0

while [ $# -gt 0 ]; do
  case "$1" in
    -c | --config)
      [ $# -ge 2 ] || { echo "Error: $1 requires a path value." >&2; usage; exit 2; }
      case "$2" in -*) echo "Error: $1 requires a path value." >&2; usage; exit 2 ;; esac
      CONFIG="$2"
      shift 2
      ;;
    -p | --preset)
      [ $# -ge 2 ] || { echo "Error: $1 requires a preset name value." >&2; usage; exit 2; }
      case "$2" in -*) echo "Error: $1 requires a preset name value." >&2; usage; exit 2 ;; esac
      PRESET="$2"
      shift 2
      ;;
    -b | --build-dir)
      [ $# -ge 2 ] || { echo "Error: $1 requires a directory value." >&2; usage; exit 2; }
      case "$2" in -*) echo "Error: $1 requires a directory value." >&2; usage; exit 2 ;; esac
      BUILD_DIR="$2"
      shift 2
      ;;
    --skip-format)
      SKIP_FORMAT=1
      shift
      ;;
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
done

# ---------------- 路径解析（对应 ps1 L515-546）----------------

if [ -n "$BUILD_DIR" ]; then
  case "$BUILD_DIR" in
    /*) BUILD_PATH="$BUILD_DIR" ;;
    *) BUILD_PATH="$REPO_ROOT/$BUILD_DIR" ;;
  esac
  BUILD_TARGET_DESC="directory: $BUILD_PATH"
else
  [ -n "$PRESET" ] || PRESET="$DEFAULT_PRESET"
  BUILD_PATH="$REPO_ROOT/build/$PRESET"
  BUILD_TARGET_DESC="preset: $PRESET (dir: $BUILD_PATH)"
fi

[ -n "$CONFIG" ] || CONFIG="$DEFAULT_CONFIG_PRIMARY"
case "$CONFIG" in
  /*) ;;
  *) CONFIG="$REPO_ROOT/$CONFIG" ;;
esac
[ -f "$CONFIG" ] || die "YAML config not found: $CONFIG"

BUILD_TYPE="$(preset_build_type "${PRESET:-$DEFAULT_PRESET}")"

# ---------------- preflight（对应 ps1 L548-579）----------------

resolve_local_python_tools

command_exists xrobot_gen_main || die 'xrobot_gen_main not found in PATH.'

resolve_cube_cli || die 'cube not found in PATH or STM32 VS Code extension directories.'
resolve_cube_cmake || die 'cube-cmake not found in PATH or STM32 VS Code extension directories.'

resolve_stm32_toolchains

resolve_ninja || exit 1

[ -n "${GCC_TOOLCHAIN_ROOT:-}" ] && [ -d "$GCC_TOOLCHAIN_ROOT" ] ||
  die 'GCC_TOOLCHAIN_ROOT is not configured and could not be auto-detected.'
[ -n "${CLANG_GCC_CMSIS_COMPILER:-}" ] && [ -d "$CLANG_GCC_CMSIS_COMPILER" ] ||
  die 'CLANG_GCC_CMSIS_COMPILER is not configured and could not be auto-detected.'

command_exists starm-clang || die 'starm-clang not found in PATH after toolchain detection.'

# ---------------- 1/3 format ----------------

if [ "$SKIP_FORMAT" -eq 1 ]; then
  echo '[1/3] Skip clang-format.'
else
  echo '[1/3] Running clang-format...'
  bash "$REPO_ROOT/tools/Linux/format_code.sh" || {
    echo "clang-format 失败 (exit $?)" >&2
    exit 1
  }
fi

# ---------------- 2/3 configure ----------------

echo "[2/3] Configuring with cube-cmake ($BUILD_TARGET_DESC)..."
[ -n "$BUILD_DIR" ] && reset_incompatible_cmake_cache

run_or_die "$CUBE_CMAKE_BIN" \
  -S "$REPO_ROOT" \
  -B "$BUILD_PATH" \
  -G Ninja \
  --toolchain "$REPO_ROOT/cmake/starm-clang.cmake" \
  -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
  "-DCMAKE_BUILD_TYPE=$BUILD_TYPE" \
  "-DXROBOT_CONFIG:FILEPATH=$CONFIG"

# ---------------- 3/3 build ----------------

echo "[3/3] Building with cube-cmake ($BUILD_TARGET_DESC)..."
run_or_die "$CUBE_CMAKE_BIN" --build "$BUILD_PATH"

echo 'Done.'
exit 0
