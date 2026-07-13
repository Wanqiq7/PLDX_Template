# bsp-dev-c

BSP Package for development board C.

## RM2024 Chassis Power Control

Chassis modules submit normal/boost intent, while PowerControl centrally owns
one power budget. Shared motor-group allocation covers all configured M3508 and
GM6020 motors. Referee/supercapacitor validity drives conservative degradation
with immediate recovery from the current LibXR PD result. SuperPower provides
centralized freshness for the independent referee power-limit and energy-buffer
fields. PowerControl intentionally keeps the last valid `0x0201` limit after that
field becomes stale, and each measured supercapacitor power sample is consumed
by RLS at most once. The implementation remains header-only and keeps the
original two-file shape: `RLS.hpp` and `PowerControl.hpp`; tuning defaults stay
internal.

## Build in Terminal

### Windows

```bash
git clone https://github.com/QDU-Robomaster/bsp-dev-c
cd bsp-dev-c
git submodule update --init --recursive
pip install libxr xrobot
xr_cubemx_cfg -d ./ -c --xrobot
xrobot_src_man create-sources
xrobot_init_mod --config https://raw.githubusercontent.com/QDU-Robomaster/dev-c-robots/refs/heads/main/test.yaml --dir .\Modules\
xrobot_setup
$env:GCC_TOOLCHAIN_ROOT = "C:\Users\$env:USERNAME\AppData\Local\stm32cube\bundles\gnu-tools-for-stm32\${版本号}\bin"
$env:CLANG_GCC_CMSIS_COMPILER = "C:\Users\$env:USERNAME\AppData\Local\stm32cube\bundles\st-arm-clang\${版本号}"
cmake . -DCMAKE_TOOLCHAIN_FILE:STRING=cmake/starm-clang.cmake -DCMAKE_EXPORT_COMPILE_COMMANDS:BOOL=TRUE -Bbuild -G Ninja
cmake --build build
ls build/
```

### Linux

```bash
git clone https://github.com/QDU-Robomaster/bsp-dev-c
cd bsp-dev-c
git submodule update --init --recursive
pip install libxr xrobot
xr_cubemx_cfg -d ./ -c --xrobot
xrobot_src_man create-sources
xrobot_init_mod --config https://raw.githubusercontent.com/QDU-Robomaster/dev-c-robots/refs/heads/main/test.yaml --dir ./Modules
xrobot_setup
export GCC_TOOLCHAIN_ROOT=/opt/arm-gnu-toolchain-14.2.rel1-x86_64-arm-none-eabi/bin
export CLANG_GCC_CMSIS_COMPILER=/opt/st-arm-clang
cmake . -DCMAKE_TOOLCHAIN_FILE:STRING=cmake/starm-clang.cmake -DCMAKE_EXPORT_COMPILE_COMMANDS:BOOL=TRUE -Bbuild -G Ninja
cmake --build build
ls build/
```
