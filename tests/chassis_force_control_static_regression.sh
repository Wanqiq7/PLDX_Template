#!/usr/bin/env bash

set -euo pipefail

readonly OMNI_HEADER="Modules/Chassis/Omni.hpp"
readonly SENTRY_CONFIG="User/RobotConfig/sentry.yaml"
readonly SENTRY_CHASSIS_CONFIG="User/RobotConfig/sentry_chassis.yaml"
readonly INFANTRY_CONFIGS=(
  "User/RobotConfig/omni_infantry_3.yaml"
  "User/RobotConfig/omni_infantry_4.yaml"
)

assert_contains() {
  local path="$1"
  local pattern="$2"
  local message="$3"

  if ! rg --quiet --multiline "$pattern" "$path"; then
    echo "FAIL: $message" >&2
    exit 1
  fi
}

assert_not_contains() {
  local path="$1"
  local pattern="$2"
  local message="$3"

  if rg --quiet --multiline "$pattern" "$path"; then
    echo "FAIL: $message" >&2
    exit 1
  fi
}

assert_contains "$OMNI_HEADER" \
  'const float TORQUE_Z =[[:space:]]+pid_omega_\.Calculate\(target_omega_, now_omega_, dt_\);' \
  'The chassis angular-velocity loop must produce a chassis torque.'
assert_contains "$OMNI_HEADER" \
  'const float TANGENTIAL_FORCE_Z = TORQUE_Z / PARAM\.wheel_to_center;' \
  'Omni inverse dynamics must convert chassis torque to tangential force with T/r.'
assert_contains "$OMNI_HEADER" \
  'target_motor_force_\[0\][^;]*TANGENTIAL_FORCE_Z' \
  'Omni wheel-force allocation must use the T/r tangential force.'
assert_contains "$OMNI_HEADER" \
  'ResistanceTorque\(target_motor_omega_\[i\]\)' \
  'Wheel resistance torque feedforward must be part of the motor command.'

for dependency in Motor PowerControl Referee SuperPower; do
  assert_contains "Modules/Chassis/Chassis.hpp" \
    "  - pldx/${dependency}" \
    "Chassis manifest must declare pldx/${dependency}."
done

for config in "$SENTRY_CONFIG" "$SENTRY_CHASSIS_CONFIG"; do
  assert_contains "$config" \
    'pid_omega_:\n(?:[[:space:]]+.*\n){0,8}[[:space:]]+cycle: false' \
    "$config must treat angular velocity as a non-cyclic quantity."
  assert_contains "$config" 'reduction_ratio:' \
    "$config must use the ChassisParam reduction_ratio key."
  assert_contains "$config" 'pid_follow_:' \
    "$config must use the Chassis pid_follow_ key."
  assert_contains "$config" 'pid_wheel_speed_0_:' \
    "$config must configure the wheel-speed P loop by its declared key."
  assert_not_contains "$config" 'pid_wheel_angle_[0-3]_:' \
    "$config must not rely on positional mapping through obsolete wheel-angle keys."
done

for config in "${INFANTRY_CONFIGS[@]}"; do
  assert_contains "$config" \
    'wheel_to_center: 0\.26' \
    "$config must retain the 0.26 m yaw-torque lever arm."
  assert_contains "$config" \
    'pid_omega_:\n[[:space:]]+k: 0\.26' \
    "$config must scale the legacy yaw loop by wheel_to_center after T/r conversion."
done

echo 'PASS: chassis force-control static regression checks'
