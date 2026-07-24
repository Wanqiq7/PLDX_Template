#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

failures=0

require_pattern() {
  local pattern="$1"
  local path="$2"
  local description="$3"

  if ! rg -q -U --pcre2 -- "${pattern}" "${path}"; then
    echo "FAIL: ${description} (${path})" >&2
    failures=$((failures + 1))
  fi
}

require_count() {
  local expected="$1"
  local pattern="$2"
  local path="$3"
  local description="$4"
  local actual

  actual="$(rg -c --pcre2 -- "${pattern}" "${path}" || true)"
  if [[ "${actual:-0}" -ne "${expected}" ]]; then
    echo "FAIL: ${description}; expected ${expected}, found ${actual:-0} (${path})" >&2
    failures=$((failures + 1))
  fi
}

require_pattern 'set\(XROBOT_CONFIG[[:space:]]+"\$\{CMAKE_SOURCE_DIR\}/User/xrobot\.yaml"[[:space:]]+CACHE[[:space:]]+FILEPATH' \
  CMakeLists.txt "XROBOT_CONFIG must be a FILEPATH cache input"
require_pattern 'get_filename_component\(XROBOT_CONFIG[[:space:]]+"\$\{XROBOT_CONFIG\}"[[:space:]]+ABSOLUTE' \
  CMakeLists.txt "XROBOT_CONFIG must be normalized to an absolute path"
require_pattern 'find_program\(XROBOT_GEN_MAIN[[:space:]]+xrobot_gen_main' \
  CMakeLists.txt "CMake must resolve xrobot_gen_main"
require_pattern '--output[[:space:]]+"\$\{XROBOT_GENERATED_HEADER\}"' \
  CMakeLists.txt "CMake must invoke xrobot_gen_main with --output"
require_pattern 'XROBOT_GENERATED_DIR' \
  CMakeLists.txt "CMake must define and use a generated include directory"
require_pattern 'XROBOT_GENERATED_DIR' \
  cmake/LibXR.CMake "the executable must include the generated directory"
require_pattern 'target_include_directories\(\$\{CMAKE_PROJECT_NAME\}[[:space:]]+BEFORE[[:space:]]+PRIVATE' \
  cmake/LibXR.CMake "the generated include directory must have precedence"
require_pattern 'set\(XROBOT_GENERATION_INPUTS[[:space:]]+"\$\{XROBOT_CONFIG\}"' \
  CMakeLists.txt "header generation must depend on XROBOT_CONFIG"
require_pattern '"\$\{CMAKE_SOURCE_DIR\}/Modules/modules\.yaml"' \
  CMakeLists.txt "header generation must depend on Modules/modules.yaml"
require_pattern 'DEPENDS[[:space:]]+\$\{XROBOT_GENERATION_INPUTS\}[[:space:]]+"\$\{XROBOT_GEN_MAIN\}"' \
  CMakeLists.txt "header generation must depend on the resolved generator"
require_pattern 'BYPRODUCTS[[:space:]]+"\$\{XROBOT_GENERATED_DIR\}/xrobot_constexpr\.hpp"' \
  CMakeLists.txt "CMake must declare the constexpr byproduct"
require_pattern 'COMMAND[[:space:]]+"\$\{CMAKE_COMMAND\}"[[:space:]]+-E[[:space:]]+rm[[:space:]]+-f[[:space:]]+"\$\{XROBOT_GENERATED_DIR\}/xrobot_constexpr\.hpp"' \
  CMakeLists.txt "generation must remove a stale constexpr byproduct first"
require_pattern 'COMMAND[[:space:]]+"\$\{CMAKE_COMMAND\}"[[:space:]]+-E[[:space:]]+touch[[:space:]]+"\$\{XROBOT_GENERATED_DIR\}/xrobot_constexpr\.hpp"' \
  CMakeLists.txt "generation must materialize the constexpr byproduct"

rm_line="$(rg -n 'COMMAND "\$\{CMAKE_COMMAND\}" -E rm -f' CMakeLists.txt \
  | head -n 1 | cut -d: -f1 || true)"
generator_line="$(rg -n 'COMMAND "\$\{XROBOT_GEN_MAIN\}"' CMakeLists.txt \
  | head -n 1 | cut -d: -f1 || true)"
touch_line="$(rg -n 'COMMAND "\$\{CMAKE_COMMAND\}" -E touch' CMakeLists.txt \
  | head -n 1 | cut -d: -f1 || true)"
if [[ -z "${rm_line}" || -z "${generator_line}" || -z "${touch_line}" ]] \
    || ((rm_line >= generator_line || generator_line >= touch_line)); then
  echo "FAIL: constexpr cleanup, generation, and touch commands are out of order" >&2
  failures=$((failures + 1))
fi

require_pattern 'add_custom_target\(xrobot_generated_header[[:space:]]+DEPENDS[[:space:]]+"\$\{XROBOT_GENERATED_HEADER\}"\)' \
  CMakeLists.txt "CMake must expose the generated-header target"
require_pattern 'add_dependencies\(\$\{CMAKE_PROJECT_NAME\}[[:space:]]+xrobot_generated_header\)' \
  CMakeLists.txt "the firmware target must depend on header generation"
require_pattern 'target_sources\(\$\{CMAKE_PROJECT_NAME\}[[:space:]]+PRIVATE[[:space:]]+"\$\{XROBOT_GENERATED_HEADER\}"\)' \
  CMakeLists.txt "the generated header must be a firmware target source"
require_pattern '#include[[:space:]]*<xrobot_main\.hpp>' \
  User/app_main.cpp "app_main.cpp must include the generated header with angle brackets"
require_count 2 '-DXROBOT_CONFIG:FILEPATH="\$\{CONFIG_PATH\}"' tools/build.sh \
  "normal and preset configure paths must both forward XROBOT_CONFIG"

if rg -n --pcre2 'xrobot_gen_main[[:space:]]+--config' tools/build.sh; then
  echo "FAIL: tools/build.sh must not generate xrobot headers directly" >&2
  failures=$((failures + 1))
fi

if [[ -e User/xrobot_main.hpp ]]; then
  echo "FAIL: source-tree User/xrobot_main.hpp must not exist" >&2
  failures=$((failures + 1))
fi

if rg -n --pcre2 'User/xrobot_main\.hpp|#include[[:space:]]*[\"]xrobot_main\.hpp[\"]' \
  CMakeLists.txt cmake tools/build.sh User/app_main.cpp; then
  echo "FAIL: source-tree xrobot_main.hpp dependency remains" >&2
  failures=$((failures + 1))
fi

if [[ "${failures}" -ne 0 ]]; then
  echo "Build isolation check failed with ${failures} issue(s)." >&2
  exit 1
fi

echo "Build isolation check passed."
