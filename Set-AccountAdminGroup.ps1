#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Sets a group as the account administrator in Azure Databricks 
.DESCRIPTION
    This script sets or removes a group as an account administrator role in Azure Databricks.
    This enables the use of groups to designate access rather than manual assignment on users.
.PARAMETER GroupName
    The name of the existing group to add or remove as account administrator (https://accounts.azuredatabricks.net/users/groups)
.PARAMETER AccountId
    The Databricks account identifier - found in the top right hand corner of the Databricks account page (https://accounts.azuredatabricks.net)
.PARAMETER Operation
    Operation to perform: 'add' or 'remove'. Default is 'add'
.EXAMPLE
    .\Set-DatabricksGroupRole.ps1 -GroupName "Admins" -AccountId "xxxxxxxxxxxxxx" -Operation "add"
.NOTES
    This code is licenced under the MIT License
    Copyright (c) 2025 Nathan Holland   
    Copyright (c) 2023 AWARE GROUP, for licencing see https://github.com/awaregroup/databricks-powershell/blob/main/LICENSE
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory=$false, HelpMessage="Name of the existing group to manage")]
    [string]$GroupName,
    
    [Parameter(Mandatory=$false, HelpMessage="Databricks account identifier")]
    [string]$AccountId,
    
    [Parameter(Mandatory=$false, HelpMessage="Operation to perform")]
    [ValidateSet("add", "remove")]
    [string]$Operation = "add"
)
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrEmpty($GroupName)) {
    $GroupName = Read-Host "Please enter the existing group name you would like to designate as an administrative group (https://accounts.azuredatabricks.net/users/groups)"
}

if ([string]::IsNullOrEmpty($AccountId)) {
    $AccountId = Read-Host "Please enter the Databricks account identifier (this can be found by clicking in the top right hand corner (https://accounts.azuredatabricks.net)"
}

$DatabricksApiBaseUrl = "https://accounts.azuredatabricks.net/api/2.0/accounts/$AccountId/scim/v2/"
$DatabricksResource = "2ff814a6-3304-4ab8-85cb-cd0e6f879c1d"

Write-Information "Retrieving Azure access token for Databricks"
try {
    $AccessToken = az account get-access-token --resource=$DatabricksResource --query accessToken --output tsv
    
    if ([string]::IsNullOrEmpty($AccessToken)) {
        throw "Failed to obtain access token"
    }
    
    Write-Information "Successfully retrieved access token"
} catch {
    $ErrorMessage = "Failed to obtain Azure access token. Ensure that: `n" +
                   "1. Azure CLI is installed (https://learn.microsoft.com/en-us/cli/azure/install-azure-cli)`n" +
                   "2. You are logged in (az login)`n" +
                   "Error details: $($_.Exception.Message)"
    Write-Error $ErrorMessage
    exit 1
}

$RequestHeaders = @{
    "Authorization" = "Bearer $AccessToken"
    "Content-Type" = "application/json"
}

Write-Information "Searching for group: '$GroupName'"
$FindGroupQueryUrl = "$DatabricksApiBaseUrl/Groups?filter=displayName eq '$GroupName'"

$GroupSearchParams = @{
    Uri = $FindGroupQueryUrl
    Method = "Get"
    Headers = $RequestHeaders
    ErrorAction = "Stop"
}

$GroupInformation = Invoke-RestMethod @GroupSearchParams

if ($GroupInformation.totalResults -eq 0) {
    throw "No groups found with name '$GroupName'. Please verify the group name exists in your Databricks account."
} elseif ($GroupInformation.totalResults -gt 1) {
    $groupDetails = $GroupInformation.Resources | Select-Object id, displayName | Format-Table | Out-String
    throw "Found multiple groups ($($GroupInformation.totalResults)) with name '$GroupName'. Please ensure you're using a unique group name: $groupDetails"
}

$GroupId = $GroupInformation.Resources.id
Write-Information "Found group '$GroupName' with ID: $GroupId"
Write-Information "Performing $($Operation) to account_admin on group '$GroupName'"
$PatchBody = @{
    schemas = @("urn:ietf:params:scim:api:messages:2.0:PatchOp")
    Operations = @(
        @{
            op = $Operation
            path = "roles"
            value = @(
                @{
                    value = "account_admin"
                }
            )
        }
    )
} | ConvertTo-Json -Depth 5

$PatchParams = @{
    Uri = "$DatabricksApiBaseUrl/Groups/$GroupId"
    Method = "Patch"
    Headers = $RequestHeaders
    Body = $PatchBody
    ContentType = "application/json"
    ErrorAction = "Stop"
}

$Result = Invoke-RestMethod @PatchParams
Write-Information "Successfully performed $($Operation) to account_admin on group '$GroupName'"

# Display result
$Result | Format-List

