#!/usr/bin/env bash
# 对应 tools/Windows/buildchassis.ps1
USAGENAME='tools/Linux/buildchassis.sh'
DEFAULT_CONFIG_PRIMARY='User/RobotConfig/sentry_chassis.yaml'
DEFAULT_CONFIG_FALLBACK='User/RobotConfig/sentry_chassis.yaml'
DEFAULT_BUILD_DIR='build/sentry_chassis'

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/build_firmware.sh" "$@"
