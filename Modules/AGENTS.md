# Modules — xrobot Robot Components

## ROLE

`Modules/` contains reusable robot components consumed by the YAML-driven xrobot application. Each module is an independent checkout with its own `CMakeLists.txt`; most implementations are header-only and expose a `LibXR::Application` or a small reusable C++ type.

## INVENTORY

Use the directory and module manifest as the source of truth. The current workspace contains:

| Area | Modules |
|------|---------|
| Hardware and state estimation | `BMI088`, `IST8310`, `MadgwickAHRS`, `Motor`, `RMMotor`, `DMMotor`, `SuperPower` |
| Robot motion | `Chassis` (`Omni`, `Mecanum`, `Helm`), `Gimbal` (`YawSmc`, `YawLqrEso`), `MiniGimbal`, `InfantryLauncher`, `HeroLauncher`, `PowerControl` |
| Operator and control flow | `CMD`, `DR16`, `VT13`, `HostData`, `EventBinder`, `DebugCore` |
| Board and external links | `DualBoard`, `SentryProtocol`, `NavHostData`, `SharedTopic`, `SharedTopicClient`, `CameraSync` |
| Robot services | `Referee`, `BlinkLED`, `BuzzerAlarm` |

`Modules/modules.yaml` is the xrobot registry and may contain entries not present in the checkout. It currently lists `pldx/Dart`, while `Modules/Dart/` is absent; resolve that mismatch before depending on Dart. `Modules/sources.yaml` points at the PLDX module index (`GUET-PLDX/pldx-modules`).

## WHERE TO LOOK

| Task | Location | Notes |
|------|----------|-------|
| Change robot composition or constructor wiring | `User/RobotConfig/*.yaml` | `module`, `entry_header`, `constructor_args`, and `template_args` are generated from these files |
| Add a module | `Modules/<Name>/` | Add the header and module `CMakeLists.txt`, then add the registry entry in `modules.yaml` |
| Understand build inclusion | `Modules/CMakeLists.txt` | Includes every child directory containing `CMakeLists.txt` |
| Inspect a module API or YAML contract | `Modules/<Name>/<Name>.hpp` and `README.md` | Header and manifest are authoritative for constructor parameters and topics |
| Inspect protocol layouts | `NavHostData`, `SentryProtocol`, `DualBoard` | Keep packed frame definitions and consumers compatible |
| Inspect motor abstraction | `Motor/Motor.hpp`, `RMMotor`, `DMMotor` | Application code should depend on `Motor*` where possible |
| Inspect debug commands | `DebugCore/DebugCore.hpp` and module debug includes | Follow existing `once`/`monitor` conventions |

## MODULE CONTRACT

- Keep changes inside the module's own directory. Treat its nested `.git` checkout as independently owned code; coordinate upstream changes through that repository and update the parent registry/reference afterward.
- Preserve the xrobot manifest at the top of module headers. Constructor argument names and types must stay aligned with YAML `constructor_args`.
- `@&name` passes a pointer to an earlier instance, `@name` passes a reference, and `@nullptr` passes null. Construct dependencies before consumers.
- Prefer the shared `Motor` interface in motion modules; concrete CAN/protocol details belong in `RMMotor` or `DMMotor`.
- Keep topic names, packed protocol structs, timestamps, and timeout/fail-safe behavior compatible with peer modules. Update the module README and YAML examples when a public contract changes.
- Header-only implementation is the normal pattern. Add `.cpp` files only when the module's existing build pattern requires them.

## WORKFLOW

1. Inspect the target module's header, manifest, README, tests, and nested git status before editing.
2. Make the smallest self-contained change and update module tests or examples when behavior changes.
3. Run the repository's pinned clang-format for `Modules/`; do not hand-reorder includes afterward.
4. Build the affected robot configuration with the documented `tools/build*.ps1` flow. The build uses `-Werror`, so warnings are failures.
5. Check that registry entry, directory name, manifest name, and YAML `entry_header` agree. Keep generated-file changes separate from functional changes.

## GUARDRAILS

- Do not edit `Drivers/`, `Middlewares/`, or generated CubeMX files as part of a module change.
- Do not silently change a constructor parameter, topic schema, frame layout, or module name: existing robot YAML files are consumers.
- Do not duplicate a protocol or motor abstraction already owned by another module.
- Verify that a registry entry has a checked-out directory and `CMakeLists.txt` before using it.
- `clang-format` scope is `Modules/` only. Never commit build artifacts.

## REGISTRY COMMANDS

```bash
# Fetch/update modules from the configured index
xrobot_init_mod --config Modules/sources.yaml --dir ./Modules

# Generate xrobot wiring after changing YAML/module metadata
xrobot_gen_main

# Inspect the effective module list
sed -n '1,200p' Modules/modules.yaml
```
