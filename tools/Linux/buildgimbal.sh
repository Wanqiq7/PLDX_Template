#!/usr/bin/env bash
# 对应 tools/Windows/buildgimbal.ps1
USAGENAME='tools/Linux/buildgimbal.sh'
DEFAULT_CONFIG_PRIMARY='User/RobotConfig/sentry_gimbal.yaml'
DEFAULT_CONFIG_FALLBACK='User/RobotConfig/sentry_gimbal.yaml'
DEFAULT_BUILD_DIR='build/sentry_gimbal'

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/build_firmware.sh" "$@"
