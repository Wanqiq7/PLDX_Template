#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$global:LASTEXITCODE = 0

$script:UsageName = 'tools/buildchassis.ps1'
$script:DefaultConfigPrimary = 'User/RobotConfig/sentry_chassis.yaml'
$script:DefaultConfigFallback = 'User/RobotConfig/sentry_chassis.yaml'
$script:DefaultBuildDir = 'build/sentry_chassis'

try {
  . "$PSScriptRoot\build_firmware.ps1" @args
} catch {
  [Console]::Error.WriteLine($_.Exception.Message)
  exit 1
}
exit $global:LASTEXITCODE
