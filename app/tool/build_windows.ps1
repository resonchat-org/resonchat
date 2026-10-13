# Copyright (C) 2026 resonchat contributors.
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Build the Windows x86_64 Inno Setup installer from the Flutter release tree.
#
# Usage (from app/ or repo root, on Windows):
#   .\tool\build_windows.ps1              # flutter build + setup.exe
#   .\tool\build_windows.ps1 -SkipBuild   # pack an existing Release tree
#
# Requires: Visual Studio C++ desktop toolchain, Inno Setup 6 (ISCC.exe).
#
# Output:
#   app/build/windows/installer/resonchat-<version>-x86_64-setup.exe

[CmdletBinding()]
param(
  [switch]$SkipBuild,
  [string]$Version = ""
)

$ErrorActionPreference = "Stop"

$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$App = (Resolve-Path (Join-Path $Here "..")).Path
Set-Location $App

function Get-AppVersion {
  param([string]$Fallback)
  if ($Fallback) { return $Fallback }
  $line = Get-Content -Path (Join-Path $App "pubspec.yaml") |
    Where-Object { $_ -match '^version:\s*' } |
    Select-Object -First 1
  if (-not $line) { throw "could not read version from pubspec.yaml" }
  $v = ($line -replace '^version:\s*', '' -replace '\+.*$', '').Trim()
  if (-not $v) { throw "empty version in pubspec.yaml" }
  return $v
}

$Ver = Get-AppVersion -Fallback $Version
$ReleaseDir = Join-Path $App "build\windows\x64\runner\Release"
$Iss = Join-Path $App "windows\packaging\resonchat.iss"
$InstallerDir = Join-Path $App "build\windows\installer"
$SetupExe = Join-Path $InstallerDir "resonchat-$Ver-x86_64-setup.exe"

if (-not $SkipBuild) {
  Write-Host "==> flutter build windows --release"
  flutter config --enable-windows-desktop | Out-Null
  flutter build windows --release
  if ($LASTEXITCODE -ne 0) {
    throw "flutter build windows failed with exit $LASTEXITCODE"
  }
}

if (-not (Test-Path (Join-Path $ReleaseDir "resonchat.exe"))) {
  throw "missing $ReleaseDir\resonchat.exe — run without -SkipBuild first"
}
if (-not (Test-Path $Iss)) { throw "missing Inno script: $Iss" }

$iscc = @(
  "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
  "${env:ProgramFiles}\Inno Setup 6\ISCC.exe",
  "ISCC.exe"
) | Where-Object {
  $_ -eq "ISCC.exe" -or (Test-Path $_)
} | Select-Object -First 1

if (-not $iscc) {
  throw "Inno Setup 6 (ISCC.exe) not found — install with: choco install innosetup"
}

New-Item -ItemType Directory -Force -Path $InstallerDir | Out-Null
Write-Host "==> Inno Setup → $SetupExe"
& $iscc $Iss "/DMyAppVersion=$Ver"
if ($LASTEXITCODE -ne 0) { throw "ISCC failed with exit $LASTEXITCODE" }
if (-not (Test-Path $SetupExe)) { throw "installer not produced: $SetupExe" }

Write-Host "done."
Write-Host "  setup: $SetupExe"
