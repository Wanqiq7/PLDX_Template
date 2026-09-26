# PLDX_Template

Two-board RoboMaster Sentry firmware for STM32F407 gimbal and chassis boards.

## Prerequisites

Install everything below before building — a fresh machine needs all of them:

| Tool | Purpose | Windows | Linux (Debian/Ubuntu) |
| ---- | ------- | ------- | --------------------- |
| Git | clone, submodules, module fetch | `winget install Git.Git` | `sudo apt install git` |
| Python 3.10+ | `pip` + xrobot CLI tools | `winget install Python.Python.3.12` (python.org installer: tick *Add python.exe to PATH*) | `sudo apt install python3 python3-pip python3-venv` |
| CMake ≥ 3.22 | build system | `winget install Kitware.CMake` | `sudo apt install cmake` |
| Ninja | build generator | `winget install Ninja-build.Ninja` | `sudo apt install ninja-build` |
| Arm cross-toolchain (GNU + st-arm-clang) | cross compiler | [STM32CubeCLT](https://www.st.com/en/development-tools/stm32cubeclt.html) — toolchain bundles cached under `%LOCALAPPDATA%\stm32cube\bundles\` | extract `gnu-tools-for-stm32` and `st-arm-clang` to known paths (used below) |

Note: the pip-installed xrobot CLI tools (`xr_cubemx_cfg`, `xrobot_setup`, `xrobot_gen_main`, ...) must be on `PATH` — CMake aborts at configure time otherwise (`CMakeLists.txt` runs `find_program(... xrobot_gen_main REQUIRED)`).

## Build in Terminal

### Windows

Run in PowerShell:

```powershell
git clone https://github.com/Wanqiq7/PLDX_Template.git
cd PLDX_Template
git submodule update --init --recursive
pip install libxr xrobot
xr_cubemx_cfg -d ./ --xrobot
xrobot_src_man create-sources
xrobot_init_mod --config Modules/modules.yaml --sources Modules/sources.yaml --directory .\Modules
xrobot_setup

# Toolchain env vars: auto-detect the newest bundle versions.
# Env vars are session-scoped — re-run in every new terminal, or add to your PowerShell profile.
$bundles = "$env:LOCALAPPDATA\stm32cube\bundles"
$env:GCC_TOOLCHAIN_ROOT = (Get-ChildItem "$bundles\gnu-tools-for-stm32" -Directory | Sort-Object Name | Select-Object -Last 1).FullName + "\bin"
$env:CLANG_GCC_CMSIS_COMPILER = (Get-ChildItem "$bundles\st-arm-clang" -Directory | Sort-Object Name | Select-Object -Last 1).FullName

$gimbalConfig = (Resolve-Path User/RobotConfig/sentry_gimbal.yaml).Path
cmake . -DCMAKE_TOOLCHAIN_FILE:STRING=cmake/starm-clang.cmake -DCMAKE_EXPORT_COMPILE_COMMANDS:BOOL=TRUE -DXROBOT_CONFIG:FILEPATH="$gimbalConfig" -Bbuild/sentry_gimbal -G Ninja
cmake --build build/sentry_gimbal

$chassisConfig = (Resolve-Path User/RobotConfig/sentry_chassis.yaml).Path
cmake . -DCMAKE_TOOLCHAIN_FILE:STRING=cmake/starm-clang.cmake -DCMAKE_EXPORT_COMPILE_COMMANDS:BOOL=TRUE -DXROBOT_CONFIG:FILEPATH="$chassisConfig" -Bbuild/sentry_chassis -G Ninja
cmake --build build/sentry_chassis

Get-ChildItem build/sentry_gimbal
Get-ChildItem build/sentry_chassis
```

Troubleshooting:

- `xr_cubemx_cfg` / `xrobot_setup` not recognized → Python's `Scripts` dir is not on `PATH` (reinstall Python with *Add to PATH*, or use `python -m pip install libxr xrobot`).
- Auto-detect finds nothing (toolchains installed via STM32CubeCLT under `C:\ST\STM32CubeCLT_<ver>\`) → set the two variables manually: `GCC_TOOLCHAIN_ROOT` = dir containing `arm-none-eabi-gcc.exe` (e.g. `C:\ST\STM32CubeCLT_<ver>\GNU-tools-for-STM32\bin`), `CLANG_GCC_CMSIS_COMPILER` = dir containing `starm-clang.exe` (e.g. `C:\ST\STM32CubeCLT_<ver>\st-arm-clang`).

### Linux

Ubuntu 23.04+ / Debian 12 block global `pip install` (PEP 668), so use a venv:

```bash
sudo apt install git python3 python3-pip python3-venv cmake ninja-build

git clone https://github.com/Wanqiq7/PLDX_Template.git
cd PLDX_Template
git submodule update --init --recursive

python3 -m venv .venv-xrobot
source .venv-xrobot/bin/activate   # re-run in every new terminal before using the xrobot CLI tools
pip install libxr xrobot

xr_cubemx_cfg -d ./ --xrobot
xrobot_src_man create-sources
xrobot_init_mod --config Modules/modules.yaml --sources Modules/sources.yaml --directory ./Modules
xrobot_setup

# Point these at wherever the toolchains were extracted:
#   GCC_TOOLCHAIN_ROOT       = dir containing arm-none-eabi-gcc
#   CLANG_GCC_CMSIS_COMPILER = dir containing starm-clang
export GCC_TOOLCHAIN_ROOT=/opt/arm-gnu-toolchain-14.2.rel1-x86_64-arm-none-eabi/bin
export CLANG_GCC_CMSIS_COMPILER=/opt/st-arm-clang

cmake . -DCMAKE_TOOLCHAIN_FILE:STRING=cmake/starm-clang.cmake -DCMAKE_EXPORT_COMPILE_COMMANDS:BOOL=TRUE -DXROBOT_CONFIG:FILEPATH="$PWD/User/RobotConfig/sentry_gimbal.yaml" -Bbuild/sentry_gimbal -G Ninja
cmake --build build/sentry_gimbal

cmake . -DCMAKE_TOOLCHAIN_FILE:STRING=cmake/starm-clang.cmake -DCMAKE_EXPORT_COMPILE_COMMANDS:BOOL=TRUE -DXROBOT_CONFIG:FILEPATH="$PWD/User/RobotConfig/sentry_chassis.yaml" -Bbuild/sentry_chassis -G Ninja
cmake --build build/sentry_chassis

ls build/sentry_gimbal
ls build/sentry_chassis
```

## Two Ways to Build

- **Manual CMake (shown above)** — smallest dependency set (no `cube` CLI, no clang-format); skips formatting entirely.
- **`tools/Windows/buildgimbal.ps1` / `tools/Windows/buildchassis.ps1`** (PowerShell 7) and **`tools/Linux/buildgimbal.sh` / `tools/Linux/buildchassis.sh`** (bash) — auto-detect the toolchain and Ninja, run clang-format on `Modules/` first, then build. Extra requirements: `cube` + `cube-cmake` CLI (ship with the **STM32Cube for VS Code** extension, or on `PATH`) and clang-format 21.1.8 (see `tools/Windows/format_code.ps1` / `tools/Linux/format_code.sh` for the `.venv-clang-format` setup).

```powershell
pwsh tools/Windows/buildgimbal.ps1 --skip-format
pwsh tools/Windows/buildchassis.ps1 -p release
```

```bash
bash tools/Linux/buildgimbal.sh --skip-format
bash tools/Linux/buildchassis.sh -p release
```

## Build Outputs & Flashing

Each build directory produces `DevC.elf`, `DevC.hex` and `DevC.bin` (project name `DevC`, see `CMakeLists.txt`):

- `build/sentry_gimbal/` — gimbal board firmware
- `build/sentry_chassis/` — chassis board firmware

Flash/debug with **Segger Ozone** using the `DevC.jdebug` project at the repo root (J-Link), or with **STM32CubeProgrammer** using the `.hex`/`.bin`.

## Notes

- CI builds inside `ghcr.io/xrobot-org/docker-image-stm32:main` (`.github/workflows/xrobot_stm32.yml`) — a ready-made Docker environment with all build dependencies, usable as an alternative to a local setup.
