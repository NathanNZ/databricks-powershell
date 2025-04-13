#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Downloads and installs the Databricks CLI
.DESCRIPTION
    This script downloads and installs the Databricks CLI for the current operating system.
    It automatically detects the OS and architecture and downloads the appropriate version.
.PARAMETER RegisterPathInCurrentSession
    If specified, adds the Databricks CLI installation directory to the current session's PATH
.PARAMETER Version
    Specifies the version of Databricks CLI to install. Defaults to 0.247.1
.EXAMPLE
    .\Install-DatabricksCLI.ps1
    Downloads and installs the Databricks CLI
.EXAMPLE
    .\Install-DatabricksCLI.ps1 -RegisterPathInCurrentSession
    Downloads and installs the Databricks CLI and adds it to the current session's PATH
.EXAMPLE
    .\Install-DatabricksCLI.ps1 -Version 0.247.1
    Downloads and installs a specific version of the Databricks CLI
.NOTES
    This code is licenced under the MIT License
    Copyright (c) 2025 Nathan Holland   
    Copyright (c) 2023 AWARE GROUP, for licencing see https://github.com/awaregroup/databricks-powershell/blob/main/LICENSE
#>
param(
    [switch]$RegisterPathInCurrentSession,
    [string]$Version = "0.247.1"
)

$ErrorActionPreference = "Stop"

$FileName = "databricks_cli_$Version"
$TargetPath = "$PSScriptRoot/databricks-cli"
$TempFile = [System.IO.Path]::GetTempPath() + "${FileName}.zip"

$OSPlatform = [System.Runtime.InteropServices.RuntimeInformation,mscorlib]::OSDescription.ToString().ToLower()
$Architecture =  [System.Runtime.InteropServices.RuntimeInformation,mscorlib]::OSArchitecture.ToString().ToLower()

$ActiveOs = switch -Wildcard ($OSPlatform) {
    "*windows*" { "Windows" }
    "*linux*"   { "linux" }
    "*darwin*"  { "darwin" }
    Default     { "unknown" }
}
$arch = switch ($architecture) {
    "x64"  { "amd64" }
    "amd64"  { "amd64" }
    "arm64" { "arm64" }
    Default { "unknown" }
}

# Set the path to the download
if ($ActiveOs -eq "Windows") {
    $FileName = "${FileName}_windows"
}
elseif ($ActiveOs -eq "darwin") {
    $FileName = "${FileName}_darwin"
    $ActiveOs = "MacOS"
}
elseif ($ActiveOs -eq "linux") {
    $FileName = "${FileName}_linux"
    $ActiveOs = "Linux"
} else {
    Write-Error "Unknown operating system: $OSPlatform"
}

if($arch -eq "unknown") {
    Write-Error "Unknown architecture: $Architecture"
}

$FileName = "${FileName}_${Arch}"
# Ensure target directory exists
New-Item -ItemType Directory -Force -Path $TargetPath | Out-Null

$DownloadUrl = "https://github.com/databricks/cli/releases/download/v${Version}/${FileName}.zip"
Write-Host "Downloading Databricks CLI v$Version for $ActiveOS ($arch)..."
Invoke-WebRequest -Uri $DownloadUrl -OutFile $TempFile

# Extract the CLI
Write-Host "Extracting files..."
Expand-Archive -Path $TempFile -DestinationPath $TargetPath -Force

# Set executable permissions on Unix systems
if ($IsLinux -or $IsMacOS) {
    Write-Verbose "Setting executable permissions"
    & chmod +x "$TargetPath/databricks"
}

# Verify installation using proper PowerShell variable naming
$ExecutablePath = if ($ActiveOs -eq "Windows") { Join-Path -Path $TargetPath -ChildPath "databricks.exe" } else { Join-Path -Path $TargetPath -ChildPath "databricks" }
if (Test-Path -Path $ExecutablePath) {
    Write-Output "Databricks CLI installed successfully at: $ExecutablePath"
    & $ExecutablePath version
    
    if ($RegisterPathInCurrentSession) {
        $Env:PATH = $Env:PATH + [IO.Path]::PathSeparator + $TargetPath
    }
    else {
        Write-Output "To use the Databricks CLI from any location, add this directory to your PATH: $TargetPath"
    }
    
}
else {
    Write-Error -Message "Failed to install Databricks CLI. Executable not found at $ExecutablePath"
}

# Clean up temporary files using proper PowerShell cmdlets
if (Test-Path -Path $TempFile) {
    Remove-Item -Path $TempFile -Force
    Write-Verbose "Removed temporary file: $TempFile"
}

