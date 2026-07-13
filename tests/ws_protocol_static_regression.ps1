$ErrorActionPreference = 'Stop'

function Assert-Contains {
  param([string]$Content, [string]$Expected, [string]$Message)
  if (-not $Content.Contains($Expected)) {
    throw $Message
  }
}

function Assert-NotContains {
  param([string]$Content, [string]$Forbidden, [string]$Message)
  if ($Content.Contains($Forbidden)) {
    throw $Message
  }
}

function Get-YamlModuleBlock {
  param([string]$Content, [string]$Id)
  $pattern = "(?ms)^- id: $([regex]::Escape($Id))\r?\n.*?(?=^- id: |\z)"
  $match = [regex]::Match($Content, $pattern)
  if (-not $match.Success) {
    throw "YAML module '$Id' is missing."
  }
  return $match.Value
}

$module = Get-Content -LiteralPath 'Modules/WsProtocol/WsProtocol.hpp' -Raw
$moduleList = Get-Content -LiteralPath 'Modules/modules.yaml' -Raw
$sentry = Get-Content -LiteralPath 'User/RobotConfig/sentry.yaml' -Raw

Assert-Contains $module '  - uart_name: "uart_ext_controller"' `
    'WsProtocol manifest must expose uart_name.'
Assert-Contains $module '  - chassis_topic_name: "chassis_data"' `
    'WsProtocol manifest must expose chassis_topic_name.'
Assert-Contains $module '  - task_stack_depth: 1024' `
    'WsProtocol manifest must expose task_stack_depth.'
Assert-Contains $module '  - thread_priority: LibXR::Thread::Priority::MEDIUM' `
    'WsProtocol manifest must expose thread_priority.'
Assert-Contains $module '  - pldx/HostData' `
    'WsProtocol must declare its HostData dependency.'
Assert-Contains $module `
    'uart_->SetConfig({115200U, LibXR::UART::Parity::NO_PARITY, 8U, 1U});' `
    'WsProtocol must configure USART as 115200 8N1.'
Assert-Contains $module 'parser_.Push(byte, command)' `
    'WsProtocol must validate bytes with its parser.'
Assert-Contains $module 'chassis_topic_.Publish(chassis);' `
    'WsProtocol must publish validated chassis velocity.'
Assert-NotContains $module 'uart_->Write' `
    'WsProtocol must remain receive-only.'
Assert-NotContains $module 'FeedRC' `
    'WsProtocol must publish through HostData instead of calling CMD directly.'

$hostDataIndex = $moduleList.IndexOf('- pldx/HostData')
$wsProtocolIndex = $moduleList.IndexOf('- pldx/WsProtocol')
if ($hostDataIndex -lt 0 -or $wsProtocolIndex -le $hostDataIndex) {
  throw 'pldx/WsProtocol must be registered after pldx/HostData.'
}

$wsBlock = Get-YamlModuleBlock $sentry 'ws_protocol'
Assert-Contains $wsBlock '  name: WsProtocol' `
    'Sentry must instantiate WsProtocol.'
Assert-Contains $wsBlock '    uart_name: uart_ext_controller' `
    'Sentry WsProtocol must own uart_ext_controller.'
Assert-Contains $wsBlock '    chassis_topic_name: chassis_data' `
    'Sentry WsProtocol must publish chassis_data.'
Assert-Contains $wsBlock '    task_stack_depth: 1024' `
    'Sentry WsProtocol stack depth must match the module contract.'
Assert-Contains $wsBlock `
    '    thread_priority: LibXR::Thread::Priority::MEDIUM' `
    'Sentry WsProtocol priority must match the module contract.'

$sharedTopicBlock = Get-YamlModuleBlock $sentry 'sharetopic'
Assert-NotContains $sharedTopicBlock '    - chassis_data' `
    'SharedTopic must not compete with WsProtocol for chassis_data.'

Write-Output 'PASS: WsProtocol static regression checks'
