# PLDX_Template

Two-board RoboMaster Sentry firmware for STM32F407 gimbal and chassis boards.

## Build in Terminal

### Windows

```powershell
git clone https://github.com/Wanqiq7/PLDX_Template.git
cd PLDX_Template
git submodule update --init --recursive
pip install libxr xrobot
xr_cubemx_cfg -d ./ --xrobot
xrobot_init_mod
xrobot_setup

$env:GCC_TOOLCHAIN_ROOT = "C:\Users\$env:USERNAME\AppData\Local\stm32cube\bundles\gnu-tools-for-stm32\<version>\bin"
$env:CLANG_GCC_CMSIS_COMPILER = "C:\Users\$env:USERNAME\AppData\Local\stm32cube\bundles\st-arm-clang\<version>"

bash tools/buildgimbal.sh
bash tools/buildchassis.sh
```

### Linux

```bash
git clone https://github.com/Wanqiq7/PLDX_Template.git
cd PLDX_Template
git submodule update --init --recursive
pip install libxr xrobot
xr_cubemx_cfg -d ./ --xrobot
xrobot_init_mod
xrobot_setup

export GCC_TOOLCHAIN_ROOT=/opt/arm-gnu-toolchain-14.2.rel1-x86_64-arm-none-eabi/bin
export CLANG_GCC_CMSIS_COMPILER=/opt/st-arm-clang

tools/buildgimbal.sh
tools/buildchassis.sh
```
