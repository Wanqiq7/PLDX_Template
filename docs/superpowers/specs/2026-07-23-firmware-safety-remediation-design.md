# Firmware Safety Remediation Design

**Date:** 2026-07-23
**Status:** Proposed, awaiting final design approval
**Scope:** PLDX STM32 firmware and its independently versioned module repositories

## 1. Purpose

This design defines a safety-first remediation program for the confirmed firmware,
integration, platform, and build-system findings. It converts the review results
into explicit invariants, repository ownership, delivery phases, failure behavior,
and acceptance criteria before implementation begins.

The implementation will use test-driven changes where host-side tests are
possible. Hardware-only behavior will be verified by compile-time checks,
targeted instrumentation, and a documented bench test.

## 2. Scope and Non-goals

### In scope

- Motion-control decoding, limits, stale-feedback behavior, and safe fallback.
- Cross-context ownership of command, sensor, and module state.
- Reliable gimbal-to-chassis sentry decisions and serialized USB topic transport.
- STM32 interrupt and DMA capability declarations matching actual hardware setup.
- Deterministic generation, dependency pinning, CI gates, and release artifacts.
- Existing documentation, formatting, diagnostic, and configuration regressions.

### Non-goals

- Rewriting LibXR, STM32 HAL, or FreeRTOS vendor code.
- Changing the existing motor CAN wire format.
- Redesigning unrelated control algorithms or retuning the robot globally.
- Combining all nested module repositories into the root repository.
- Adding dynamic allocation or exception handling to runtime control paths.
- Treating a successful firmware build as proof of physical-system safety.

## 3. Safety Classification and Invariants

Findings are prioritized by consequence rather than implementation convenience.

| Class | Meaning | Required release gate |
| --- | --- | --- |
| Critical | Can directly produce unintended actuator output or defeat a safety boundary | Regression test plus target or bench evidence |
| High | Can corrupt control state, lose safety-relevant data, or disable fault handling | Regression test or deterministic concurrency/transport proof |
| Medium | Can make builds, diagnostics, or deployment unreliable | Automated CI check |
| Low | Engineering inconsistency with limited direct runtime impact | Static check or documented resolution |

The following invariants apply to every implementation phase:

1. Invalid, non-finite, stale, or unavailable essential feedback must never create
   a new non-zero actuator command.
2. Loss of an essential control input transitions the affected module to zero
   output or `RELAX`; it must not retain the last active command indefinitely.
3. Only the owning control task mutates controller mode, PID state, and actuator
   submission state.
4. ISR-to-task data transfer must be atomic on Cortex-M4 or use an ISR-safe queue;
   no torn 64-bit timestamp or floating-point state is permitted.
5. Safety-relevant inter-board commands must be versioned, fresh, deduplicated,
   and observable when transport is unavailable.
6. Generated configuration and dependencies must be isolated and reproducible;
   parallel builds may not modify a shared source-tree output.

## 4. Repository and Commit Boundaries

Each nested module repository receives its own buildable, reviewable commits. The
root repository integrates verified module revisions and owns platform, YAML,
CI, and documentation changes.

| Repository | Primary ownership | Integration rule |
| --- | --- | --- |
| `Modules/DMMotor` | F01-F02 decoding and MIT command limits | Pin tested module commit in root metadata |
| `Modules/Gimbal` | F03-F04 and F08 patrol, freshness, mode ownership | Integrate config-unit migration in the same root release |
| `Modules/InfantryLauncher` | Infantry portion of F05 | Pin only after stale-motor regression passes |
| `Modules/HeroLauncher` | Hero portion of F05 | Pin only after stale-motor regression passes |
| `Modules/CMD` | F06 serialized command-state mutation | Verify event publication outside the lock |
| `Modules/HostData` | F07 coherent callback/monitor snapshots | Verify compound-state consistency under stress |
| Chassis module repositories | F09 owner-thread mode and output submission | Apply the same contract to Omni, Mecanum, and Helm variants |
| `Modules/BMI088` | F10 ISR-to-task timing handoff | Bench-verify interrupt cadence and wrap behavior |
| `Modules/SentryProtocol`, `Modules/DualBoard` | F11 versioned decision transport | Land compatible producer and consumer revisions together |
| Shared topic client repository | F12 BUSY handling if library change is needed | Prefer one configured client before changing shared library behavior |
| `Modules/WsProtocol` | F25 configured thread priority | Independent focused commit |
| Root repository | F11-F24, F26-F28 integration, platform, build, CI, docs | Pin all verified module commits; never mix generated output with functional edits |

Cross-repository work is coordinated by a release manifest recording the exact
commit for every changed module. A root integration commit is not considered
complete until both sentry configurations build against that manifest.

## 5. Architecture Decisions

### 5.1 Motion safety

#### DMMotor feedback and MIT command encoding

The DM position field is decoded as an unsigned 16-bit integer over the manual's
full `0..65535` range. A small pure conversion helper will be covered at raw
boundaries `0x0000`, `0x7fff`, `0x8000`, and `0xffff`. This prevents the current
signed cast from mapping the upper half of the encoder domain below `-PMAX`.

MIT `kp` and `kd` inputs are checked for finiteness and clamped to the protocol
range before quantization. Invalid gains take the safe lower bound rather than
wrapping through an unsigned packet field. Existing CAN identifiers and packet
layout remain unchanged.

#### Gimbal automatic patrol and sensor validity

Automatic patrol uses explicit SI configuration keys:

- `patrol_pitch_amplitude_rad: 0.455`
- `patrol_pitch_angular_rate_rad_s: 10.0`
- an explicit yaw rate in radians per second

On entry to `AUTOPATROL`, the owner task captures the patrol center. Each cycle
computes a bounded absolute target from that center and elapsed time. The waveform
is never accumulated into the previous target.

Euler and gyro inputs have independent receive timestamps and finite-value checks.
The initial timeout is 50 ms and becomes a named configuration constant. If
either essential stream is stale or invalid, the gimbal transitions to `RELAX`,
clears or resets relevant controller state in the owner task, and submits zero
output. Recovery requires fresh valid samples and a new accepted mode request.

#### Launcher motor availability

Launcher `Update()` results become part of the control precondition. All essential
motors must be online before firing output is allowed. Friction-wheel loss blocks
triggering and relaxes affected outputs; trigger-motor loss also blocks feeding.
The error must be surfaced through existing module diagnostics rather than being
discarded.

### 5.2 Concurrency ownership

`CMD` serializes mutations from RC and AI producers. While holding the lock it
updates internal state and creates an immutable output/event snapshot. Publishing
topics and activating events occur after unlocking to avoid callback reentrancy
and lock inversion.

`HostData` applies the same snapshot rule to compound values and timestamps:
callbacks update a coherent state under a lock, while the monitor copies one
snapshot and operates on that copy outside the critical section.

Gimbal and chassis event callbacks no longer call `SetMode()` or submit motor
outputs directly. They post a requested mode and reason. The module's control task
consumes the request, owns mode transition, resets PID state, and submits the
resulting output. Omni, Mecanum, and Helm must share this ownership contract.

BMI088 interrupt code publishes only data that is atomic on STM32F407, preferably
an ISR-safe queue entry containing a 32-bit wrap-safe hardware timestamp/sample
marker. The task expands elapsed time and updates floating-point timing state.
No 64-bit timestamp or float is concurrently read and written across ISR/task
contexts.

### 5.3 Inter-board communication

A versioned `SentryDecisionFrame` is added to DualBoard transport from gimbal to
chassis. It carries decision state plus purchase/revival requests, a monotonically
advancing sequence number, and sufficient identity for idempotent handling.

The chassis consumer rejects unsupported versions, stale frames, and duplicate
sequences. Event-like requests are acknowledged or deduplicated; reconnecting may
not replay an old purchase indefinitely. Transport freshness is observable, and
loss of the decision stream selects a documented conservative behavior.

The two gimbal `SharedTopicClient` configurations are merged so one owner manages
`usb_otg_hs_cdc` and the duplicated `ahrs_quaternion` subscription. If legitimate
concurrent producers remain, the client transmit service serializes them and
retries or reports `BUSY`; silent loss is not accepted for safety-relevant data.

Existing CAN and USB topic encodings remain stable except for the new explicitly
versioned decision message.

### 5.4 Platform capability and interrupt wiring

Peripheral registration must describe actual initialized hardware:

- I2C1 will not select DMA while no DMA handles/IRQs are initialized. The preferred
  minimal change is to configure it as interrupt/polling-only unless measurements
  justify fully wiring DMA.
- If `IMU_INT` remains registered on EXTI1, EXTI1 NVIC setup and the IRQ handler
  must dispatch through HAL from an allowed user-code region. Otherwise the mapping
  is removed.
- CAN1/CAN2 SCE interrupts, NVIC setup, and HAL error dispatch are added because
  the driver enables error and bus-off notifications.

Bench verification will inject or observe each interrupt path and confirm that no
enabled IRQ resolves to the startup default handler.

### 5.5 Deterministic build and engineering gates

Generated `xrobot_main.hpp` becomes configuration-specific output inside each
build tree. CMake includes the generated directory; concurrent gimbal and chassis
builds never overwrite `User/xrobot_main.hpp`.

Module revisions, Python tools, and the CI container are pinned to immutable
versions or digests. Module metadata is reconciled with the actual reviewed
branches and commits. CI runs formatting, host/static regressions, both firmware
builds, and an artifact-layout assertion before upload.

The 64 KiB FreeRTOS heap is placed in a `NOLOAD` CCM section so it consumes RAM but
not FLASH image payload. Runtime statistics are disabled unless a real timer
consumer is identified; if retained, they must use a working wrap-safe counter.

C++20 remains the authoritative standard because the active build already requires
it; repository documentation is updated from C++17. Formatting failures are fixed,
PowerControl documentation tests are rewritten around semantic contracts, and
`WsProtocol` passes its configured priority to thread creation.

The default root configuration contains only one owner for the LED GPIO. Release
artifact paths are tested against the hierarchy actually produced by the upload
action. CCM/RAM map checks and the CMake `enable_language()` warning are resolved
as lower-priority engineering cleanup without weakening safety gates.

## 6. Delivery Phases

### Phase 0: Baseline and regression harness

- Record root and nested repository commits in a release manifest.
- Add failing host tests for pure conversions, clamping, patrol bounds, freshness,
  launcher availability, snapshots, decision deduplication, and config validation.
- Capture current map-file FLASH/RAM section sizes and artifact paths.
- Establish CI jobs that can fail independently before functional fixes land.

Exit criterion: every Critical/High finding has either a failing automated test or
a named bench procedure with observable expected results.

### Phase 1: Motion safety

- Correct DMMotor decoding and gain clamping.
- Replace accumulated patrol behavior and migrate patrol configuration units.
- Add gimbal freshness/finite guards and owner-thread safe fallback.
- Enforce launcher motor-online preconditions.

Exit criterion: corrupted/stale feedback and out-of-range commands produce no
unexpected non-zero output; module tests and both root configurations build.

### Phase 2: Concurrency and ownership

- Serialize CMD and HostData compound state.
- Move gimbal/chassis mode transitions to their owner tasks.
- Replace BMI088 shared ISR/task timing state with an atomic handoff.

Exit criterion: stress tests or deterministic instrumentation show coherent
snapshots and single-owner mode/output mutation with no callback-under-lock path.

### Phase 3: Communication and platform

- Add and integrate `SentryDecisionFrame` with freshness and deduplication.
- Consolidate the USB shared-topic client and make BUSY observable/retriable.
- Align I2C1, EXTI1, and CAN SCE declarations with initialized interrupt paths.

Exit criterion: fault-injection tests cover duplicate, stale, disconnected, and
BUSY transport states; bench evidence covers all enabled hardware IRQs.

### Phase 4: Build, diagnostics, and release engineering

- Isolate generated headers per build and prove parallel-build safety.
- Pin dependencies and container/tool versions.
- Fix CCM heap image placement, runtime stats, standard documentation, formatting,
  docs regressions, priority propagation, duplicate LED ownership, and artifacts.
- Promote all regression suites and map/artifact checks to required CI gates.

Exit criterion: a clean checkout reproduces both firmware images in parallel,
passes all gates, and emits verified artifacts without source-tree mutation.

## 7. Failure Handling and Rollback

- Every module change is independently revertible and retains the previous wire
  format unless the root integration explicitly enables the new decision frame.
- The new decision transport is version-gated. A version mismatch disables only
  the new decision path and exposes a diagnostic; it must not reinterpret bytes.
- Configuration migrations fail generation on legacy ambiguous patrol keys rather
  than silently guessing units.
- Safety fallback remains active during partial deployment: missing fresh data,
  missing motors, or missing decisions cannot restore active actuator output.
- Root module pins are advanced only after the corresponding module commit passes
  its tests. Rollback restores the previous complete manifest, not an arbitrary
  mixture of module revisions.
- Linker and build-generation changes retain before/after map and artifact evidence
  so regression can be detected before hardware deployment.

## 8. Acceptance Criteria

1. DM raw values `0x0000..0xffff` decode monotonically into `[-PMAX, +PMAX]`, and
   gain fields cannot wrap for negative, excessive, NaN, or infinite inputs.
2. Gimbal patrol targets remain within configured amplitude for an extended run;
   stale/invalid Euler or gyro input reaches `RELAX` and zero output within timeout.
3. Infantry and Hero launchers cannot feed when any required motor feedback is
   unavailable, and diagnostics identify the failed precondition.
4. CMD, HostData, gimbal, chassis, and BMI088 meet their stated single-owner or
   coherent-snapshot contracts under stress/instrumentation.
5. Sentry decisions arrive gimbal-to-chassis exactly once per sequence, reject
   stale/unsupported data, and fail conservatively across disconnect/reconnect.
6. One USB client owns the endpoint; `BUSY` cannot silently discard a required
   message.
7. I2C1 never selects an uninitialized DMA path, and EXTI1/CAN SCE IRQs dispatch to
   their intended HAL handlers on target.
8. Parallel gimbal/chassis builds do not modify a shared generated file and produce
   reproducible outputs from pinned inputs.
9. The CCM heap occupies no FLASH load payload; runtime statistics are either
   functional or disabled.
10. Formatting, semantic documentation tests, host regressions, both firmware
    builds, map checks, and artifact-layout checks are required and green in CI.
11. Each nested repository has focused commits and the root records their exact
    tested revisions.

## 9. Finding Coverage Matrix

| ID | Confirmed finding | Class | Owner | Phase | Primary verification |
| --- | --- | --- | --- | --- | --- |
| F01 | DMMotor position field decoded through `int16_t` | Critical | DMMotor | 1 | Boundary/monotonic conversion tests and manual vectors |
| F02 | DMMotor MIT `kp/kd` quantization can wrap | Critical | DMMotor | 1 | Range and non-finite property tests |
| F03 | Gimbal patrol accumulates an absolute waveform | Critical | Gimbal + root config | 1 | Long-run bounded-target test |
| F04 | Gimbal lacks Euler/gyro freshness and finite guards | Critical | Gimbal | 1 | Stale/NaN fault-injection test |
| F05 | Launchers ignore motor `Update()` failures | Critical | InfantryLauncher, HeroLauncher | 1 | Per-motor offline matrix test |
| F06 | CMD has multi-producer data races | High | CMD | 2 | Snapshot and concurrency stress test |
| F07 | HostData callbacks race with monitor state | High | HostData | 2 | Coherent compound-state stress test |
| F08 | Gimbal callbacks race through direct `SetMode()` | Critical | Gimbal | 2 | Owner-thread transition instrumentation |
| F09 | Chassis mode/offline events race with motor submission | Critical | chassis modules | 2 | Event/output ordering test across variants |
| F10 | BMI088 shares torn 64-bit/float timing state | High | BMI088 | 2 | ISR/task handoff and wrap test |
| F11 | Sentry decisions do not cross gimbal to chassis | High | DualBoard, SentryProtocol, root config | 3 | End-to-end decision transport test |
| F12 | Two SharedTopicClients share USB and silently drop BUSY | High | root config, shared client | 3 | Single-owner config and BUSY fault test |
| F13 | Default config has two BlinkLED owners | Medium | root config | 4 | Generated config ownership assertion |
| F14 | Parallel builds overwrite `User/xrobot_main.hpp` | High | root build | 4 | Concurrent-build source-tree cleanliness test |
| F15 | I2C1 DMA threshold advertises unavailable DMA | High | root platform | 3 | Capability/config test plus bench transfer |
| F16 | IMU EXTI1 IRQ is not enabled or handled | Critical | root platform | 3 | IRQ dispatch bench test |
| F17 | CAN error/SCE notifications lack IRQ handling | High | root platform | 3 | Bus-off/error injection bench test |
| F18 | Dependencies and module inputs are mutable | High | root build/CI | 4 | Clean-checkout reproducibility check |
| F19 | FreeRTOS CCM heap consumes FLASH load image | Medium | root linker/platform | 4 | ELF/map LMA assertion |
| F20 | Runtime stats enabled with zero counter | Medium | root platform | 4 | Config assertion or advancing-counter test |
| F21 | Documentation says C++17 while build requires C++20 | Low | root docs/build | 4 | Documentation/config consistency check |
| F22 | Module formatting gate fails | Medium | affected modules | 4 | `tools/format_code.sh --check` |
| F23 | PowerControl README regression is brittle/missing | Medium | PowerControl | 4 | Semantic documentation contract test |
| F24 | CI omits formatting and regression suites | High | root CI | 0, 4 | Required CI jobs and branch gate evidence |
| F25 | WsProtocol ignores configured thread priority | Medium | WsProtocol | 4 | Constructor/config propagation test |
| F26 | Release artifact hierarchy may mismatch upload paths | Medium | root CI | 4 | Artifact-layout integration check |
| F27 | CCM/RAM diagnostics and CMake ordering warning remain | Low | root build | 4 | Clean configure plus map budget report |
| F28 | Module pinning and cross-repo coordination are implicit | High | all changed repos | 0, 4 | Release manifest and exact root pins |

## 10. Detailed Plan Set

After this design is approved, implementation will be decomposed into five
Superpowers execution plans:

1. `2026-07-23-motion-safety-remediation.md`
2. `2026-07-23-control-concurrency-remediation.md`
3. `2026-07-23-dual-board-decision-transport.md`
4. `2026-07-23-platform-interrupt-dma-remediation.md`
5. `2026-07-23-deterministic-build-ci-remediation.md`

Each plan will identify exact files, tests, red/green commands, expected results,
module-specific commits, root pin updates, and hardware evidence. No implementation
phase begins until its tests and rollback boundary are explicit.
