#Requires -Version 7.0
# 由 buildchassis.ps1 / buildgimbal.ps1 dot-source。
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$global:LASTEXITCODE = 0

if (-not $script:UsageName) {
  throw '请通过 tools/buildchassis.ps1 或 tools/buildgimbal.ps1 调用。'
}

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location $RepoRoot

function Show-Usage {
  @"
Usage:
  $($script:UsageName) [options]

Description:
  1) Run clang-format for C/C++ files under Modules/
  2) Configure firmware and its generated xrobot header with cube-cmake
  3) Build firmware with cube-cmake

Options:
  -c, --config <path>     YAML config path (default: xrobot.yaml)
  -p, --preset <name>     CMake preset name (default: `$CMAKE_BUILD_PRESET or debug)
  -b, --build-dir <dir>   Build dir for cube-cmake (overrides --preset)
      --skip-format       Skip clang-format step
  -h, --help              Show this help message

Examples:
  $($script:UsageName)
  $($script:UsageName) -p release
  $($script:UsageName) -c $($script:DefaultConfigPrimary) -p relWithDebInfo
  $($script:UsageName) -c $($script:DefaultConfigPrimary) -b $($script:DefaultBuildDir)
"@ | Write-Host
}

function Exit-FromBuild([int]$Code) {
  $global:LASTEXITCODE = $Code
}

function Test-CommandExists([string]$Name) {
  return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Get-CommandPath([string]$Name) {
  $cmd = Get-Command $Name -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  return ''
}

function Add-PathFront([string]$Dir) {
  if ([string]::IsNullOrWhiteSpace($Dir)) { return }
  if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return }

  $resolved = [System.IO.Path]::GetFullPath($Dir)
  $parts = @($env:PATH -split [IO.Path]::PathSeparator)
  if ($parts | Where-Object { $_ -eq $resolved }) { return }
  $env:PATH = $resolved + [IO.Path]::PathSeparator + $env:PATH
}

function Get-CubeCMakePlatform {
  if ($IsWindows) { return 'win32' }
  if ($IsMacOS) { return 'darwin' }
  if ($IsLinux) { return 'linux' }
  throw '无法识别当前主机平台。'
}

function Get-CubeCMakeArchCandidates {
  $arch = if ($IsWindows -and $env:PROCESSOR_ARCHITECTURE) {
    $env:PROCESSOR_ARCHITECTURE
  } else {
    [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
  }

  switch -Regex ($arch) {
    '^(amd64|x64|X64|x86_64)$' { return @('x86_64', 'amd64') }
    '^(arm64|ARM64)$' { return @('arm64', 'aarch64', 'x86_64') }
    '^(aarch64)$' { return @('aarch64', 'arm64', 'x86_64') }
    default { return @($arch.ToLowerInvariant()) }
  }
}

function Get-EditorExtensionRoots {
  $roots = [System.Collections.Generic.List[string]]::new()
  if ($env:VSCODE_EXTENSIONS) {
    $roots.Add($env:VSCODE_EXTENSIONS)
  }

  $homeRoots = @(
    (Join-Path $HOME '.vscode/extensions')
    (Join-Path $HOME '.vscode-insiders/extensions')
    (Join-Path $HOME '.vscode-oss/extensions')
    (Join-Path $HOME '.cursor/extensions')
    (Join-Path $HOME '.windsurf/extensions')
  )
  foreach ($root in $homeRoots) {
    $roots.Add($root)
  }

  return @($roots | Where-Object { Test-Path -LiteralPath $_ -PathType Container } | Select-Object -Unique)
}

function Find-ToolInExtensions {
  param(
    [Parameter(Mandatory)][string]$ExtensionPrefix,
    [Parameter(Mandatory)][string[]]$RelativeCandidates
  )

  $platform = Get-CubeCMakePlatform
  $archs = Get-CubeCMakeArchCandidates
  foreach ($root in Get-EditorExtensionRoots) {
    $extensions = Get-ChildItem -LiteralPath $root -Directory -Filter "$ExtensionPrefix*" -ErrorAction SilentlyContinue
    foreach ($extensionDir in $extensions) {
      foreach ($arch in $archs) {
        foreach ($relative in $RelativeCandidates) {
          $candidate = $relative.
            Replace('{platform}', $platform).
            Replace('{arch}', $arch)
          $full = $extensionDir.FullName
          foreach ($part in ($candidate -split '[\\/]')) {
            if ($part) {
              $full = Join-Path $full $part
            }
          }
          if ($IsWindows) {
            $exe = $full
            if (-not $exe.EndsWith('.exe', [System.StringComparison]::OrdinalIgnoreCase)) {
              $exe = "$full.exe"
            }
            if (Test-Path -LiteralPath $exe -PathType Leaf) {
              return $exe
            }
          }
          if (Test-Path -LiteralPath $full -PathType Leaf) {
            return $full
          }
        }
      }
    }
  }
  return ''
}

function Resolve-LocalPythonTools {
  $toolRoot = Join-Path $RepoRoot '.tooling/python'
  if (-not (Test-Path -LiteralPath $toolRoot -PathType Container)) {
    return
  }

  $sep = [IO.Path]::PathSeparator
  if ($env:PYTHONPATH) {
    $env:PYTHONPATH = $toolRoot + $sep + $env:PYTHONPATH
  } else {
    $env:PYTHONPATH = $toolRoot
  }
  Add-PathFront (Join-Path $toolRoot 'bin')
  Add-PathFront (Join-Path $toolRoot 'Scripts')
}

function Resolve-CubeCli {
  $fromPath = Get-CommandPath 'cube'
  if ($fromPath) {
    $script:CubeBin = $fromPath
    return $true
  }

  $detected = Find-ToolInExtensions -ExtensionPrefix 'stmicroelectronics.stm32cube-ide-core-' -RelativeCandidates @(
    'resources/binaries/{platform}/{arch}/cube'
  )
  if ($detected) {
    Add-PathFront ([System.IO.Path]::GetDirectoryName($detected))
    $script:CubeBin = $detected
    Write-Host "[preflight] cube not in PATH; using STM32 extension copy at $($script:CubeBin)."
    return $true
  }

  return $false
}

function Resolve-CubeCMake {
  foreach ($name in @('cube-cmake', 'cube-cmake.exe')) {
    $fromPath = Get-CommandPath $name
    if ($fromPath) {
      $script:CubeCMakeBin = $fromPath
      return $true
    }
  }

  $detected = Find-ToolInExtensions -ExtensionPrefix 'stmicroelectronics.stm32cube-ide-build-cmake-' -RelativeCandidates @(
    'resources/cube-cmake/{platform}/{arch}/cube-cmake'
  )
  if ($detected) {
    Add-PathFront ([System.IO.Path]::GetDirectoryName($detected))
    $script:CubeCMakeBin = $detected
    Write-Host "[preflight] cube-cmake not in PATH; using STM32 extension copy at $($script:CubeCMakeBin)."
    return $true
  }

  foreach ($name in @('cmake', 'cmake.exe')) {
    $cmake = Get-CommandPath $name
    if ($cmake) {
      $script:CubeCMakeBin = $cmake
      Write-Host "[preflight] cube-cmake not found; using cmake at $($script:CubeCMakeBin)."
      return $true
    }
  }

  return $false
}

function Get-LatestSubdir([string]$ParentDir) {
  if (-not (Test-Path -LiteralPath $ParentDir -PathType Container)) {
    return ''
  }
  $dirs = @(Get-ChildItem -LiteralPath $ParentDir -Directory | Sort-Object Name)
  if ($dirs.Count -eq 0) {
    return ''
  }
  return $dirs[-1].FullName
}

function Get-Stm32BundleRoots {
  $roots = [System.Collections.Generic.List[string]]::new()
  if ($env:CUBE_BUNDLE_PATH) {
    $roots.Add($env:CUBE_BUNDLE_PATH)
  }

  $candidates = @(
    (Join-Path $HOME 'AppData/Local/stm32cube/bundles')
    (Join-Path $HOME '.stm32cube/bundles')
    (Join-Path $HOME '.local/share/stm32cube/bundles')
    (Join-Path $HOME '.config/stm32cube/bundles')
    (Join-Path $HOME 'Library/Application Support/stm32cube/bundles')
  )
  if ($env:LOCALAPPDATA) {
    $candidates += (Join-Path $env:LOCALAPPDATA 'stm32cube/bundles')
  }

  foreach ($root in $candidates) {
    $roots.Add($root)
  }

  return @($roots | Where-Object { Test-Path -LiteralPath $_ -PathType Container } | Select-Object -Unique)
}

function Get-CubeCltRoots {
  if (-not $IsWindows) { return @() }
  $stRoot = 'C:\ST'
  if (-not (Test-Path -LiteralPath $stRoot -PathType Container)) { return @() }
  return @(Get-ChildItem -LiteralPath $stRoot -Directory -Filter 'STM32CubeCLT_*' | Sort-Object Name | ForEach-Object { $_.FullName })
}

function Resolve-Stm32Toolchains {
  if ($env:GCC_TOOLCHAIN_ROOT -and -not (Test-Path -LiteralPath $env:GCC_TOOLCHAIN_ROOT -PathType Container)) {
    Remove-Item Env:GCC_TOOLCHAIN_ROOT
  }
  if ($env:CLANG_GCC_CMSIS_COMPILER -and -not (Test-Path -LiteralPath $env:CLANG_GCC_CMSIS_COMPILER -PathType Container)) {
    Remove-Item Env:CLANG_GCC_CMSIS_COMPILER
  }

  $detectedGccRoot = ''
  $detectedClangRoot = ''

  foreach ($bundleRoot in Get-Stm32BundleRoots) {
    if (-not $env:GCC_TOOLCHAIN_ROOT -and -not $detectedGccRoot) {
      $latest = Get-LatestSubdir (Join-Path $bundleRoot 'gnu-tools-for-stm32')
      if ($latest) {
        $binDir = Join-Path $latest 'bin'
        $detectedGccRoot = if (Test-Path -LiteralPath $binDir -PathType Container) { $binDir } else { $latest }
      }
    }

    if (-not $env:CLANG_GCC_CMSIS_COMPILER -and -not $detectedClangRoot) {
      $detectedClangRoot = Get-LatestSubdir (Join-Path $bundleRoot 'st-arm-clang')
    }

    if (($env:GCC_TOOLCHAIN_ROOT -or $detectedGccRoot) -and ($env:CLANG_GCC_CMSIS_COMPILER -or $detectedClangRoot)) {
      break
    }
  }

  if ((-not $env:GCC_TOOLCHAIN_ROOT -and -not $detectedGccRoot) -or (-not $env:CLANG_GCC_CMSIS_COMPILER -and -not $detectedClangRoot)) {
    foreach ($cltRoot in Get-CubeCltRoots) {
      if (-not $env:GCC_TOOLCHAIN_ROOT -and -not $detectedGccRoot) {
        $cltGcc = Join-Path $cltRoot 'GNU-tools-for-STM32/bin'
        if (Test-Path -LiteralPath $cltGcc -PathType Container) {
          $detectedGccRoot = $cltGcc
        }
      }
      if (-not $env:CLANG_GCC_CMSIS_COMPILER -and -not $detectedClangRoot) {
        $cltClang = Join-Path $cltRoot 'st-arm-clang'
        if (Test-Path -LiteralPath $cltClang -PathType Container) {
          $detectedClangRoot = $cltClang
        }
      }
    }
  }

  if (-not $env:GCC_TOOLCHAIN_ROOT -and $detectedGccRoot) {
    $env:GCC_TOOLCHAIN_ROOT = $detectedGccRoot
    Write-Host "[preflight] GCC_TOOLCHAIN_ROOT not set; using $($env:GCC_TOOLCHAIN_ROOT)."
  }
  if (-not $env:CLANG_GCC_CMSIS_COMPILER -and $detectedClangRoot) {
    $env:CLANG_GCC_CMSIS_COMPILER = $detectedClangRoot
    Write-Host "[preflight] CLANG_GCC_CMSIS_COMPILER not set; using $($env:CLANG_GCC_CMSIS_COMPILER)."
  }

  if ($env:GCC_TOOLCHAIN_ROOT) {
    Add-PathFront $env:GCC_TOOLCHAIN_ROOT
  }
  if ($env:CLANG_GCC_CMSIS_COMPILER) {
    Add-PathFront (Join-Path $env:CLANG_GCC_CMSIS_COMPILER 'bin')
  }
}

function Test-NinjaExecutable([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
  return (Test-Path -LiteralPath $Path -PathType Leaf)
}

function Resolve-Ninja {
  if ((Test-CommandExists 'ninja') -or (Test-CommandExists 'ninja.exe')) {
    return $true
  }

  foreach ($bundleRoot in Get-Stm32BundleRoots) {
    $ninjaRoot = Get-LatestSubdir (Join-Path $bundleRoot 'ninja')
    if (-not $ninjaRoot) { continue }
    $candidates = @(
      (Join-Path $ninjaRoot 'bin/ninja.exe')
      (Join-Path $ninjaRoot 'bin/ninja')
    )
    foreach ($candidate in $candidates) {
      if (Test-NinjaExecutable $candidate) {
        Add-PathFront (Join-Path $ninjaRoot 'bin')
        Write-Host "[preflight] ninja not in PATH; using $candidate."
        return $true
      }
    }
  }

  foreach ($cltRoot in Get-CubeCltRoots) {
    $cltNinjaDir = Join-Path $cltRoot 'Ninja/bin'
    $cltNinja = Join-Path $cltNinjaDir 'ninja.exe'
    if (Test-NinjaExecutable $cltNinja) {
      Add-PathFront $cltNinjaDir
      Write-Host "[preflight] ninja not in PATH; using $cltNinja."
      return $true
    }
  }

  [Console]::Error.WriteLine('Error: ninja not found in PATH or STM32 Cube bundle directories.')
  return $false
}

function Get-PresetBuildType([string]$Preset) {
  switch ($Preset) {
    'debug' { return 'Debug' }
    'relWithDebInfo' { return 'RelWithDebInfo' }
    'release' { return 'Release' }
    'minSizeRel' { return 'MinSizeRel' }
    default { return 'Debug' }
  }
}

function Invoke-Native {
  param(
    [Parameter(Mandatory)][string]$FilePath,
    [string[]]$ArgumentList = @()
  )

  & $FilePath @ArgumentList
  if ($global:LASTEXITCODE -ne 0) {
    throw "命令失败 (exit $global:LASTEXITCODE): $FilePath $($ArgumentList -join ' ')"
  }
}

function Reset-IncompatibleCMakeCache([string]$BuildPath) {
  $cache = Join-Path $BuildPath 'CMakeCache.txt'
  if (-not (Test-Path -LiteralPath $cache -PathType Leaf)) {
    return
  }

  $homeDir = ''
  foreach ($line in Get-Content -LiteralPath $cache) {
    if ($line -match '^CMAKE_HOME_DIRECTORY:INTERNAL=(.*)$') {
      $homeDir = $Matches[1].Trim()
      break
    }
  }
  if (-not $homeDir) {
    return
  }

  $normalize = {
    param([string]$PathValue)
    try {
      return [System.IO.Path]::GetFullPath($PathValue).TrimEnd('\', '/').ToLowerInvariant()
    } catch {
      return $PathValue.Replace('\', '/').TrimEnd('/').ToLowerInvariant()
    }
  }

  $cachedRoot = & $normalize $homeDir
  $currentRoot = & $normalize $RepoRoot
  if ($cachedRoot -eq $currentRoot) {
    return
  }

  Write-Host "[preflight] CMake cache was created at $homeDir; resetting $BuildPath for $RepoRoot."
  Remove-Item -LiteralPath $cache -Force
  $cmakeFiles = Join-Path $BuildPath 'CMakeFiles'
  if (Test-Path -LiteralPath $cmakeFiles) {
    Remove-Item -LiteralPath $cmakeFiles -Recurse -Force
  }
}

function Invoke-ConfigureBuildTree {
  param(
    [string]$BuildDir,
    [string]$BuildPath,
    [string]$Preset,
    [string]$ConfigPath
  )

  if ($BuildDir) {
    $buildType = Get-PresetBuildType $Preset
    Invoke-Native -FilePath $script:CubeCMakeBin -ArgumentList @(
      '-S', $RepoRoot
      '-B', $BuildPath
      '-G', 'Ninja'
      '--toolchain', (Join-Path $RepoRoot 'cmake/starm-clang.cmake')
      '-DCMAKE_EXPORT_COMPILE_COMMANDS=ON'
      "-DCMAKE_BUILD_TYPE=$buildType"
      "-DXROBOT_CONFIG:FILEPATH=$ConfigPath"
    )
  } else {
    Invoke-Native -FilePath $script:CubeCMakeBin -ArgumentList @(
      '--preset', $Preset
      "-DXROBOT_CONFIG:FILEPATH=$ConfigPath"
    )
  }
}

function Get-RequiredOptionValue {
  param(
    [string]$Option,
    [System.Collections.IList]$AllArgs,
    [int]$Index,
    [string]$Kind
  )

  if ($Index + 1 -ge $AllArgs.Count) {
    throw "Error: $Option requires a $Kind value."
  }
  $value = [string]$AllArgs[$Index + 1]
  if ([string]::IsNullOrWhiteSpace($value) -or $value.StartsWith('-')) {
    throw "Error: $Option requires a $Kind value."
  }
  return $value
}

$ConfigPath = ''
$DefaultPreset = 'debug'
$Preset = if ($env:CMAKE_BUILD_PRESET) {
  $env:CMAKE_BUILD_PRESET
} elseif ($env:CMAKE_PRESET) {
  $env:CMAKE_PRESET
} else {
  ''
}
$BuildDir = $script:DefaultBuildDir
$SkipFormat = $false
$script:CubeBin = ''
$script:CubeCMakeBin = ''
$AllArgs = @($args)

try {
  $i = 0
  while ($i -lt $AllArgs.Count) {
    $current = [string]$AllArgs[$i]
    if ($current -in @('-c', '--config')) {
      $ConfigPath = Get-RequiredOptionValue -Option $current -AllArgs $AllArgs -Index $i -Kind 'path'
      $i += 2
    } elseif ($current -in @('-p', '--preset')) {
      $Preset = Get-RequiredOptionValue -Option $current -AllArgs $AllArgs -Index $i -Kind 'preset name'
      $i += 2
    } elseif ($current -in @('-b', '--build-dir')) {
      $BuildDir = Get-RequiredOptionValue -Option $current -AllArgs $AllArgs -Index $i -Kind 'directory'
      $i += 2
    } elseif ($current -eq '--skip-format') {
      $SkipFormat = $true
      $i += 1
    } elseif ($current -in @('-h', '--help')) {
      Show-Usage
      Exit-FromBuild 0
      return
    } else {
      [Console]::Error.WriteLine("Unknown option: $current")
      Show-Usage
      Exit-FromBuild 2
      return
    }
  }
} catch {
  [Console]::Error.WriteLine($_.Exception.Message)
  Show-Usage
  Exit-FromBuild 2
  return
}

if ($BuildDir) {
  if ([System.IO.Path]::IsPathRooted($BuildDir)) {
    $BuildPath = $BuildDir
  } else {
    $BuildPath = Join-Path $RepoRoot $BuildDir
  }
  $BuildTargetDesc = "directory: $BuildPath"
} else {
  if (-not $Preset) {
    $Preset = $DefaultPreset
  }
  $BuildPath = Join-Path $RepoRoot "build/$Preset"
  $BuildTargetDesc = "preset: $Preset (dir: $BuildPath)"
}

if (-not $ConfigPath) {
  if (Test-Path -LiteralPath $script:DefaultConfigPrimary -PathType Leaf) {
    $ConfigPath = $script:DefaultConfigPrimary
  } elseif (Test-Path -LiteralPath $script:DefaultConfigFallback -PathType Leaf) {
    $ConfigPath = $script:DefaultConfigFallback
  } else {
    $ConfigPath = $script:DefaultConfigPrimary
  }
}

if (-not [System.IO.Path]::IsPathRooted($ConfigPath)) {
  $ConfigPath = Join-Path $RepoRoot $ConfigPath
}

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
  throw "Error: YAML config not found: $ConfigPath"
}

Resolve-LocalPythonTools

if (-not (Test-CommandExists 'xrobot_gen_main') -and -not (Test-CommandExists 'xrobot_gen_main.exe')) {
  throw 'Error: xrobot_gen_main not found in PATH.'
}

if (-not (Resolve-CubeCli)) {
  throw 'Error: cube not found in PATH or STM32 VS Code extension directories.'
}

if (-not (Resolve-CubeCMake)) {
  throw 'Error: cube-cmake not found in PATH or STM32 VS Code extension directories.'
}

Resolve-Stm32Toolchains

if (-not (Resolve-Ninja)) {
  Exit-FromBuild 1
  return
}

if (-not $env:GCC_TOOLCHAIN_ROOT -or -not (Test-Path -LiteralPath $env:GCC_TOOLCHAIN_ROOT -PathType Container)) {
  throw 'Error: GCC_TOOLCHAIN_ROOT is not configured and could not be auto-detected.'
}

if (-not $env:CLANG_GCC_CMSIS_COMPILER -or -not (Test-Path -LiteralPath $env:CLANG_GCC_CMSIS_COMPILER -PathType Container)) {
  throw 'Error: CLANG_GCC_CMSIS_COMPILER is not configured and could not be auto-detected.'
}

if (-not (Test-CommandExists 'starm-clang') -and -not (Test-CommandExists 'starm-clang.exe')) {
  throw 'Error: starm-clang not found in PATH after toolchain detection.'
}

if (-not $SkipFormat) {
  Write-Host '[1/3] Running clang-format...'
  & (Join-Path $RepoRoot 'tools/format_code.ps1')
  if ($global:LASTEXITCODE -ne 0) {
    throw "clang-format 失败 (exit $global:LASTEXITCODE)"
  }
} else {
  Write-Host '[1/3] Skip clang-format.'
}

Write-Host "[2/3] Configuring with cube-cmake ($BuildTargetDesc)..."
if ($BuildDir) {
  Reset-IncompatibleCMakeCache $BuildPath
}
Invoke-ConfigureBuildTree -BuildDir $BuildDir -BuildPath $BuildPath -Preset $Preset -ConfigPath $ConfigPath

Write-Host "[3/3] Building with cube-cmake ($BuildTargetDesc)..."
Invoke-Native -FilePath $script:CubeCMakeBin -ArgumentList @('--build', $BuildPath)

Write-Host 'Done.'
$global:LASTEXITCODE = 0
