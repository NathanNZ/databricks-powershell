#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Configures Databricks SQL ODBC driver and DSN.
.DESCRIPTION
    This script installs the Simba Spark ODBC Driver if not already installed,
    and configures a Databricks SQL ODBC DSN for connecting to Databricks.
.PARAMETER DsnName
    The name of the DSN to create.
.PARAMETER OverrideBitness
    Determines the bitness of the driver to install (32 or 64). If not specified, it will be determined based on what version of excel is installed.
.PARAMETER HostName
    The Databricks host name to connect to.
.PARAMETER HttpPath
    The HTTP path for the Databricks SQL warehouse.
.PARAMETER DsnDescription
    Description for the DSN. Defaults to DsnName + HostName.
.NOTES
    Copyright (c) 2025 Nathan Holland
    This script is licensed under the MIT License. See the LICENSE file for details.
#>
[CmdletBinding()]
Param (    
    [Parameter()]
    [string]$DsnName = $null,
    
    [Parameter()]
    [string]$HostName = $null,
    
    [Parameter()]
    [string]$HttpPath = $null,
        
    [Parameter()]
    [string]$OverrideBitness = $null,
    
    [Parameter()]
    [string]$DsnDescription = $null
)
$ErrorActionPreference = "Stop"

# Validation check
$CurrentVersion = (Get-WmiObject -Class Win32_OperatingSystem).Version
$NumericVersion = [double]::Parse(($CurrentVersion -split "\." | Select-Object -First 2) -Join ".")
$TestedVersions = @(10.0, 6.3)
if ($NumericVersion -notin $TestedVersions) {
    Write-Warning "This script has not been tested on this version of Windows, the install may not work as expected."
}

# Current Driver Install State and System Information
$DriverName = "Simba Spark ODBC Driver"
$Is64Bit = [Environment]::Is64BitOperatingSystem

if ($OverrideBitness) {
    if ($OverrideBitness -eq "32") {
        $Is64Bit = $false
    }
    elseif ($OverrideBitness -eq "64") {
        $Is64Bit = $true
    }
    else {
        throw "Invalid value for OverrideBitness. Use '32' or '64'."
    }
}

$InstalledDrivers = Get-OdbcDriver -Name $DriverName -ErrorAction SilentlyContinue
$Has64BitDriver = $null -ne ($InstalledDrivers | Where-Object { $_.Platform -eq "64-bit" })
$Has32BitDriver = $null -ne ($InstalledDrivers | Where-Object { $_.Platform -eq "32-bit" })

# Driver Install Information
$DriverVersion = "2.9"
$DriverSupportStartDate = Get-Date "2024-11-15"
$DriverSupportEndDate = $DriverSupportStartDate.AddYears(2.0)
$Fallback32bit = "https://databricks-bi-artifacts.s3.us-east-2.amazonaws.com/simbaspark-drivers/odbc/2.9.1/SimbaSparkODBC-2.9.1.1001-Windows-32bit.zip"
$Sha256sum32bit = "d2decf8b6745b6d890d68adeb990ad07537e90fe5b155997a255e7fa81666805"
$Executable32bit = "Simba Spark 2.9 32-bit.msi"
$Fallback64bit = "https://databricks-bi-artifacts.s3.us-east-2.amazonaws.com/simbaspark-drivers/odbc/2.9.1/SimbaSparkODBC-2.9.1.1001-Windows-64bit.zip"
$Sha256sum64bit = "85a41aedb20d3e5899430868a8d45ba1769e2196fe118314eb0963fef3f82745"
$Executable64bit = "Simba Spark 2.9 64-bit.msi"

$CurrentDate = Get-Date
if ($DriverSupportStartDate -gt $CurrentDate.AddYears(1.5)) {
    Write-Warning "The current version of the driver defined in this script ($DriverVersion) has a support date that ends soon ($DriverSupportEndDate)."
} 

if ($null -eq $Bitness) {
    $Version = Get-ItemPropertyValue -Path HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration -Name platform -ErrorAction SilentlyContinue

    if ($Version -eq 'x86') {
        $Is64Bit = $false
    }
    elseif ($Version -eq 'x64') {
        $Is64Bit = $true
    }
    if (!$Version) {
        # Okay we're not using click to run? So we'll have to do a bit more digging...
        $ExcelApplicationRegKey = "HKLM:\SOFTWARE\Classes\Excel.Application\CurVer"
        if (!(Test-Path $ExcelApplicationRegKey)) {
            throw "Excel does not seem to be installed, either disable the auto-detection of excel or manually specify the bitness to install."
        }        
        $ExcelApplicationCurrentVersion = (Get-ItemProperty $ExcelApplicationRegKey).'(default)'
        $Version = $($ExcelApplicationCurrentVersion -replace "Excel.Application.", "") + ".0"
        $Path = "HKLM:\SOFTWARE\Microsoft\Office\$Version\Excel\InstallRoot"
        $WowPath = $Path -replace 'SOFTWARE', 'SOFTWARE\Wow6432Node'

        if (Test-Path $Path) {
            $Is64Bit = $true         
        }
        elseif (Test-Path $WowPath) {
            $Is64Bit = $false            
        }
        else {
            throw "Excel does not seem to be installed, either disable the auto-detection of excel or manually specify the bitness to install."
        }
    }
    if ($Is64Bit) {
        Write-Host "64-bit Excel is installed."
    }
    else {
        Write-Host "32-bit Excel is installed - this may cause issues in the future"
    }
}

# Function because it looks like msiexec quits with a successful error code - but spawns another thread anyway.
function Wait-ForMsiExec {
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $timeoutMs = 30 * 1000
    while ($stopwatch.ElapsedMilliseconds -lt $timeoutMs) {
        $msiProcesses = Get-Process -Name "msiexec" -ErrorAction SilentlyContinue        
        if ($null -eq $msiProcesses -or $msiProcesses.Count -eq 0) {            
            return $true
        }
        Write-Host "Waiting for installer to complete..."
        Start-Sleep -Seconds 5
    }    
    return $false
}


# Function to download and extract the driver
function Install-OdbcDriver {
    param (
        [object]$ParentInvocation,
        [string]$Url,
        [string]$ExpectedHash,
        [string]$ExecutableName
    )    
    $TempFile = Join-Path $env:TEMP (Split-Path $Url -Leaf)
    $OutputPath = Join-Path $env:TEMP "SimbaSparkODBC"
            
    Write-Host "Installing the ODBC driver - by doing so you agree to the terms and conditions (https://www.databricks.com/legal/jdbc-odbc-driver-license)"
    Invoke-WebRequest -Uri $Url -OutFile $TempFile
    $FileHash = Get-FileHash -Path $TempFile -Algorithm SHA256
    if ($FileHash.Hash -ne $ExpectedHash) {
        Write-Error "SHA-256 hash mismatch for file: $TempFile"
    }
    
    Expand-Archive -Path $TempFile -DestinationPath $OutputPath -Force
    Remove-Item -Path $TempFile -Force
    $InstallerPath = Join-Path $OutputPath $ExecutableName
    if (-Not (Test-Path $InstallerPath)) {
        Write-Error "Installer not found at expected path: $InstallerPath"
    }
    
    $DataStamp = Get-Date -Format yyyyMMddTHHmmss
    $LogFile = '{0}-{1}.log' -f ([System.IO.Path]::GetFileNameWithoutExtension($InstallerPath)), $DataStamp
    $LogFilePath = Join-Path $env:TEMP $LogFile
    

    # Create a temporary script file that will run with elevation (would be nice to figure out a better way to do this - wish msiexec supported this out of the box)
    $tempScriptPath = Join-Path $OutputPath "InstallMsi.ps1"
    @"
`$MsiArguments = @(
    "/i", ('"{0}"' -f '$InstallerPath'), "/qn", "/norestart",  "/L*v", ('"{0}"' -f '$LogFilePath')
)
`$exitCode = (Start-Process -FilePath 'msiexec.exe' -ArgumentList `$MsiArguments -Wait -NoNewWindow -PassThru).ExitCode
exit `$exitCode
"@ | Out-File -FilePath $tempScriptPath -Encoding utf8

    try {
        $Process = Start-Process -FilePath "powershell.exe" -ArgumentList "-File", $tempScriptPath -Verb RunAs -Wait -PassThru
        if ($Process.ExitCode -ne 0) {
            Write-Error "Install failed with exit code $($Process.ExitCode). Check the log file: $LogFilePath"
        }
        else {
            Write-Host "Install completed successfully."
        }
    }
    finally {
        if (Test-Path $tempScriptPath) {
            Remove-Item -Path $tempScriptPath -Force
            if ((Wait-ForMsiExec -TimeoutSeconds 60)) {                
                Remove-Item -Path $OutputPath -Recurse -Force
            }
        }
    }
}

# Check if the driver was installed successfully
$InstalledDrivers = Get-OdbcDriver -Name $DriverName -ErrorAction SilentlyContinue
$Has64BitDriver = $null -ne ($InstalledDrivers | Where-Object { $_.Platform -eq "64-bit" })
$Has32BitDriver = $null -ne ($InstalledDrivers | Where-Object { $_.Platform -eq "32-bit" })

# Determine which driver to download and install
if ($Is64Bit -and -not $Has64BitDriver) {
    Install-OdbcDriver -Url $Fallback64bit -ExpectedHash $Sha256sum64bit -ExecutableName $Executable64bit -ParentInvocation $MyInvocation
}
elseif (-not $Is64Bit -and -not $Has32BitDriver) {
    Install-OdbcDriver -Url $Fallback32bit -ExpectedHash $Sha256sum32bit -ExecutableName $Executable32bit -ParentInvocation $MyInvocation
}
else {
    Write-Host "All required drivers already installed - configuring DSN."
}

if ([string]::IsNullOrWhiteSpace($DsnName)) {
    $defaultDsnName = "Databricks SQL ODBC"
    $DsnName = Read-Host -Prompt "DSN connection name or push enter to use the default: [$defaultDsnName]"
    if ([string]::IsNullOrWhiteSpace($DsnName)) {
        $DsnName = $defaultDsnName
        Write-Host "Using default DSN name: $DsnName"
    }
}

if ([string]::IsNullOrWhiteSpace($DsnDescription)) {
    $DsnDescription = "$DsnName - $HostName"
}

Write-Host "Configuring connection to Databricks (https://learn.microsoft.com/en-us/azure/databricks/integrations/compute-details)"

# Prompt for HostName if not provided
if ([string]::IsNullOrWhiteSpace($HostName)) {
    $defaultHostName = "adb-xxxxxxxxxx.xx.azuredatabricks.net"
    $HostName = Read-Host -Prompt "Databricks host name (e.g. $defaultHostName)"
    if ([string]::IsNullOrWhiteSpace($HostName)) {
        Write-Error "HostName is required and cannot be empty."
        exit 1
    }
    if (-not $HostName.StartsWith("adb-") -or -not $HostName.EndsWith(".net")) {
        Write-Warning "Normally the HostName parameter would start with 'adb-' and end with '.net' - if the connection fails validate you have this right."
    }
}

# Prompt for HttpPath if not provided
if ([string]::IsNullOrWhiteSpace($HttpPath)) {
    $defaultHttpPath = "/sql/1.0/warehouses/xxxxxxxxxx"
    $HttpPath = Read-Host -Prompt "SQL warehouse HTTP path (e.g. $defaultHttpPath)"
    if ([string]::IsNullOrWhiteSpace($HttpPath)) {
        Write-Error "HttpPath is required and cannot be empty."
        exit 1
    }    
    if (-not $HttpPath.StartsWith("/sql/1.0/warehouses")) {
        Write-Warning "Normally the HttpPath parameter would start start with '/sql/1.0/warehouses' - if the connection fails validate you have this right."
    }
}


# https://learn.microsoft.com/en-us/azure/databricks/integrations/odbc/authentication#authentication-u2m
# Setting up the ODBC DSN...
$OdbcSettings = @(
    # Description - this should probably be a friendly name
    "Description=$DsnDescription",

    ### HTTP Settings###
    # This is the Databricks host name we're connecting to
    "Host=$HostName",
    # The spark server type is always a Thrift Server instance
    "SparkServerType=3",
    # Use HTTP as transport
    "ThriftTransport=2",
    # this is the path to the warehouse
    "HTTPPath=$HttpPath",
    # This is the Databricks port it's always 443
    "Port=443",
    # Use Window's Trust Store, this is required so intercepting proxies won't cause TLS issues
    "UseSystemTrustStore=1",
    # Configure the connector to apply service side properties without additional round tripping
    "ApplySSPWithQueries=0",
    # Enable TLSv1.2 or higher
    "SSL=1",
    "Min_TLS=1.2",

    ### OAuth Settings ###
    # Client ID for Databricks
    "Auth_Client_ID=databricks-sql-odbc",
    # Set this to 11 for OAuth2 Authentication
    "AuthMech=11",
    # Token Passthrough 0, Client Credentials 1, Browser based 2, Azure Managed Identity 3
    "Auth_Flow=2",

    ### Performance Settings ###
    # The maximum number of rows that a query returns at a time
    "RowsFetchedPerBlock=200000",

    ### Data Type Settings ###
    # Note : Strings over 65535 characters will be truncated
    "DefaultStringColumnLength=65535",
    ## The maximum number of digits to the right of the decimal point for numeric data types
    "DecimalColumnScale=10",
    ## Use SQL_WVARCHAR rather than VARCHAR for string types
    "UseUnicodeSqlCharacterTypes=1"
)

if (Get-OdbcDsn -Name $DsnName -DsnType "User" -ErrorAction SilentlyContinue) {
    Write-Host "ODBC DSN '$DsnName' already exists. Replacing it with this new configuration."
    Remove-OdbcDsn -Name $DsnName -DsnType "User"    
}

if ($Is64Bit) {    
    Add-OdbcDsn -Name $DsnName -DriverName $DriverName -DsnType "User" -Platform "64-bit" -SetPropertyValue $OdbcSettings
}
else {
    Write-Host "Creating 32-bit DSN."
    Add-OdbcDsn -Name $DsnName -DriverName $DriverName -DsnType "User" -Platform "32-bit" -SetPropertyValue $OdbcSettings
}

