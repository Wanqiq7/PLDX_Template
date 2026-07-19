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
xrobot_src_man create-sources
xrobot_init_mod --config Modules/modules.yaml --sources Modules/sources.yaml --directory .\Modules
xrobot_setup

$env:GCC_TOOLCHAIN_ROOT = "C:\Users\$env:USERNAME\AppData\Local\stm32cube\bundles\gnu-tools-for-stm32\<version>\bin"
$env:CLANG_GCC_CMSIS_COMPILER = "C:\Users\$env:USERNAME\AppData\Local\stm32cube\bundles\st-arm-clang\<version>"

xrobot_gen_main --config User/RobotConfig/sentry_gimbal.yaml
cmake . -DCMAKE_TOOLCHAIN_FILE:STRING=cmake/starm-clang.cmake -DCMAKE_EXPORT_COMPILE_COMMANDS:BOOL=TRUE -Bbuild/sentry_gimbal -G Ninja
cmake --build build/sentry_gimbal

xrobot_gen_main --config User/RobotConfig/sentry_chassis.yaml
cmake . -DCMAKE_TOOLCHAIN_FILE:STRING=cmake/starm-clang.cmake -DCMAKE_EXPORT_COMPILE_COMMANDS:BOOL=TRUE -Bbuild/sentry_chassis -G Ninja
cmake --build build/sentry_chassis

Get-ChildItem build/sentry_gimbal
Get-ChildItem build/sentry_chassis
```

### Linux

```bash
git clone https://github.com/Wanqiq7/PLDX_Template.git
cd PLDX_Template
git submodule update --init --recursive
pip install libxr xrobot
xr_cubemx_cfg -d ./ --xrobot
xrobot_src_man create-sources
xrobot_init_mod --config Modules/modules.yaml --sources Modules/sources.yaml --directory ./Modules
xrobot_setup

export GCC_TOOLCHAIN_ROOT=/opt/arm-gnu-toolchain-14.2.rel1-x86_64-arm-none-eabi/bin
export CLANG_GCC_CMSIS_COMPILER=/opt/st-arm-clang

xrobot_gen_main --config User/RobotConfig/sentry_gimbal.yaml
cmake . -DCMAKE_TOOLCHAIN_FILE:STRING=cmake/starm-clang.cmake -DCMAKE_EXPORT_COMPILE_COMMANDS:BOOL=TRUE -Bbuild/sentry_gimbal -G Ninja
cmake --build build/sentry_gimbal

xrobot_gen_main --config User/RobotConfig/sentry_chassis.yaml
cmake . -DCMAKE_TOOLCHAIN_FILE:STRING=cmake/starm-clang.cmake -DCMAKE_EXPORT_COMPILE_COMMANDS:BOOL=TRUE -Bbuild/sentry_chassis -G Ninja
cmake --build build/sentry_chassis

ls build/sentry_gimbal
ls build/sentry_chassis
```
