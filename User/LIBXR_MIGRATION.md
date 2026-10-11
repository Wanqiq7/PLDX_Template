# LibXR v2.0.1 / XRobot 1.0.1

The BSP now uses upstream static assembly. Hardware and services have static
storage and are declared with `XR_REGISTER(object, Type)`. `XROBOT_MAIN()` passes
these objects to the generated entry. Modules are ordinary classes with explicit
hardware/service references or pointers; no application manager, hardware alias
registry or compatibility headers remain. The generated loop directly calls each
module's public `OnMonitor()`.

Configurations use `module`, `id`, ordered `args` and `settings`. Literal C++
strings include their double quotes in the YAML value. Struct fields follow C++
declaration order. Existing motor settings, Topic names, PID values and event
bindings were preserved. Modules live under `Modules/pldx/<Name>`.

Install and build:

```sh
python -m pip install -r tools/requirements.txt
xrobot setup --frozen
bash tools/Linux/buildgimbal.sh --skip-format -b build/sentry_gimbal
bash tools/Linux/buildchassis.sh --skip-format -b build/sentry_chassis
```

Upstream generates one `User/xrobot_main.hpp`. Build scripts select the product
before configuring CMake. After modules are restored, `xrobot setup --frozen --offline` is also available.
The upstream offline flag requires existing checkouts even for local bundles.
Build boards sequentially: concurrent product builds
would compete for the same header. CMake checks the expected product; LibXR checks
input digests every build and rejects stale generated code. The generated header
is not committed.

The migrated module repositories have not been published upstream. Portable Git
bundles in `tools/module_snapshots/` are a local XRobot source, pinned by
`xrobot.lock`. They include the migration and pre-existing local changes recorded
in `provenance.json`, so a fresh checkout is reproducible without overwriting or
publishing the user's module work. Original checkouts are preserved locally in
`.tooling/module_worktrees/`. This project does not automatically replace these
snapshots with remote modules. After reviewing and publishing module changes,
replace the source and update the lock explicitly.

Inspect a module with `xrobot module show pldx/BMI088`. For independent compile
checks of all 30 modules against the STM32 toolchain:

```sh
python tools/Linux/check_static_modules.py --output build/static_module_probes
xrobot gen -c User/RobotConfig/sentry_chassis.yaml
cmake -S . -B build/sentry_chassis -G Ninja --toolchain cmake/starm-clang.cmake -DCMAKE_BUILD_TYPE=Debug -DXROBOT_CONFIG=User/RobotConfig/sentry_chassis.yaml -DSENTRY_STATIC_MODULE_CHECK_DIR="$PWD/build/static_module_probes"
cmake --build build/sentry_chassis --target sentry_module_compile_check
```

`FlashRegion` describes the physical layout. The database remains in the last two
128 KiB sectors, with format version 3 and the STM32F407 one-byte write unit.
Regenerate the map with `python tools/Linux/generate_flash_map.py` (libxr 6.0.1).
The CDC override forwards `in_isr` and retains the endpoint-binding guard.

Compilation does not replace board tests for USB enumeration, CAN communication,
monitor/failsafe behaviour and persisted calibration.
