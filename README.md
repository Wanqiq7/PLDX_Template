# PLDX_Template

Two-board RoboMaster Sentry firmware for STM32F407 gimbal and chassis boards.

## Power Control

`PowerControl` 集中拥有底盘功率预算：其他模块只提交反馈与请求，由其
`OutputLimit()` 统一生成限幅结果。`SuperPower` 集中拥有裁判数据新鲜度，
分别维护 `0x0201` 功率上限和 `0x0202` 缓冲能量的有效状态。

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

$gimbalConfig = (Resolve-Path User/RobotConfig/sentry_gimbal.yaml).Path
cmake . -DCMAKE_TOOLCHAIN_FILE:STRING=cmake/starm-clang.cmake -DCMAKE_EXPORT_COMPILE_COMMANDS:BOOL=TRUE -DXROBOT_CONFIG:FILEPATH="$gimbalConfig" -Bbuild/sentry_gimbal -G Ninja
cmake --build build/sentry_gimbal

$chassisConfig = (Resolve-Path User/RobotConfig/sentry_chassis.yaml).Path
cmake . -DCMAKE_TOOLCHAIN_FILE:STRING=cmake/starm-clang.cmake -DCMAKE_EXPORT_COMPILE_COMMANDS:BOOL=TRUE -DXROBOT_CONFIG:FILEPATH="$chassisConfig" -Bbuild/sentry_chassis -G Ninja
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

cmake . -DCMAKE_TOOLCHAIN_FILE:STRING=cmake/starm-clang.cmake -DCMAKE_EXPORT_COMPILE_COMMANDS:BOOL=TRUE -DXROBOT_CONFIG:FILEPATH="$PWD/User/RobotConfig/sentry_gimbal.yaml" -Bbuild/sentry_gimbal -G Ninja
cmake --build build/sentry_gimbal

cmake . -DCMAKE_TOOLCHAIN_FILE:STRING=cmake/starm-clang.cmake -DCMAKE_EXPORT_COMPILE_COMMANDS:BOOL=TRUE -DXROBOT_CONFIG:FILEPATH="$PWD/User/RobotConfig/sentry_chassis.yaml" -Bbuild/sentry_chassis -G Ninja
cmake --build build/sentry_chassis

ls build/sentry_gimbal
ls build/sentry_chassis
```
