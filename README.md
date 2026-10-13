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

The firmware uses **LibXR v2.0.1** and **xrobot 1.0.1**. Module implementations remain PLDX, with explicit dependency injection and static assembly. The existing vendor checkout under `Middlewares/` is preserved.

```bash
python3 tools/setup_libxr2.py
export PATH="$PWD/.venv-xrobot2/bin:/opt/st-arm-clang/bin:$PATH"
export GCC_TOOLCHAIN_ROOT=/opt/arm-gnu-toolchain-14.2.rel1-x86_64-arm-none-eabi/bin
export CLANG_GCC_CMSIS_COMPILER=/opt/st-arm-clang
bash tools/Linux/buildgimbal.sh --skip-format
bash tools/Linux/buildchassis.sh --skip-format
```

On Windows, run `python tools/setup_libxr2.py` and use `.venv-xrobot2\Scripts`; the PowerShell build scripts add this directory to PATH. Setup creates junctions for the package names used by xrobot.

Setup checks out the published module commits pinned in `xrobot.lock`. It preserves existing checkouts and stops when their HEAD differs from the lock. Modules remain independent repositories.

CMake generates the selected configuration with `xrobot gen`, then builds it. The generator uses `User/xrobot_main.hpp`, so build the two products sequentially. Do not run the old CubeMX/xrobot setup commands over the migrated application files.

See [migration and validation](docs/libxr2_migration_completed.md) for the module inventory, preserved behavior and checks.

## Two Ways to Build

- **Manual CMake** — smallest dependency set (no `cube` CLI, no clang-format); skips formatting entirely.
- **`tools/Windows/buildgimbal.ps1` / `tools/Windows/buildchassis.ps1`** (PowerShell 7) and **`tools/Linux/buildgimbal.sh` / `tools/Linux/buildchassis.sh`** (bash) — auto-detect the toolchain and Ninja, run clang-format on `Modules/` first, then build. The scripts prefer CMake and use `cube-cmake` as a fallback. Formatting requires clang-format 21.1.8 (see `tools/Windows/format_code.ps1` / `tools/Linux/format_code.sh` for the `.venv-clang-format` setup).

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
