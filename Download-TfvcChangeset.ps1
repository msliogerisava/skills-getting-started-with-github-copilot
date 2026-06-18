<#
.SYNOPSIS
    Downloads all files from a specific TFVC changeset in Azure DevOps Services.

.DESCRIPTION
    Connects to Azure DevOps via PAT token, retrieves the list of changed files
    in a given changeset, and downloads each file to a local directory.

.PARAMETER Organization
    The Azure DevOps organization name (e.g. "myorg" from dev.azure.com/myorg).

.PARAMETER Project
    The Azure DevOps project name.

.PARAMETER ChangesetId
    The TFVC changeset number to download files from.

.PARAMETER Pat
    The Personal Access Token for authentication.

.PARAMETER OutputDirectory
    The local directory to save downloaded files. Defaults to ".\changeset_<id>".

.EXAMPLE
    .\Download-TfvcChangeset.ps1 -Organization "myorg" -Project "myproject" -ChangesetId 12345 -Pat "your-pat-token"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Organization,

    [Parameter(Mandatory)]
    [string]$Project,

    [Parameter(Mandatory)]
    [int]$ChangesetId,

    [Parameter(Mandatory)]
    [string]$Pat,

    [Parameter()]
    [string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $PWD "changeset_$ChangesetId"
}

# Build auth header from PAT
$base64Auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$Pat"))
$headers = @{
    Authorization = "Basic $base64Auth"
}

$baseUrl = "https://dev.azure.com/$Organization/$Project/_apis/tfvc"

# --- Step 1: Get changeset details (list of changed items) ---
Write-Host "Fetching changeset $ChangesetId..." -ForegroundColor Cyan

$changesetUrl = "$baseUrl/changesets/$ChangesetId/changes?api-version=7.1"
try {
    $response = Invoke-RestMethod -Uri $changesetUrl -Headers $headers -Method Get
}
catch {
    Write-Error "Failed to retrieve changeset $ChangesetId. Verify your organization, project, changeset ID, and PAT. Error: $_"
    exit 1
}

$changes = $response.value
if (-not $changes -or $changes.Count -eq 0) {
    Write-Warning "Changeset $ChangesetId contains no file changes."
    exit 0
}

Write-Host "Found $($changes.Count) change(s) in changeset $ChangesetId." -ForegroundColor Green

# Filter to files only (exclude folders) and exclude deletes
$filesToDownload = $changes | Where-Object {
    $_.item.isFolder -ne $true -and $_.changeType -notmatch 'delete'
}

if ($filesToDownload.Count -eq 0) {
    Write-Warning "No downloadable files in changeset $ChangesetId (all changes are folder-level or deletes)."
    exit 0
}

Write-Host "$($filesToDownload.Count) file(s) to download." -ForegroundColor Green

# --- Step 2: Download each file ---
$successCount = 0
$failCount = 0

foreach ($change in $filesToDownload) {
    $serverPath = $change.item.path      # e.g. $/Project/src/file.cs
    $version = $change.item.version
    if (-not $version) { $version = $ChangesetId }

    # Convert server path to a relative local path (strip leading $/)
    $relativePath = $serverPath -replace '^\$/', ''
    $localPath = Join-Path $OutputDirectory $relativePath

    $localDir = Split-Path $localPath -Parent
    if (-not (Test-Path $localDir)) {
        New-Item -ItemType Directory -Path $localDir -Force | Out-Null
    }

    # Download the file content at the specific changeset version
    $encodedPath = [Uri]::EscapeDataString($serverPath)
    $itemUrl = "$baseUrl/items?path=$encodedPath&versionDescriptor.version=$version&versionDescriptor.versionType=changeset&api-version=7.1"

    Write-Host "  Downloading: $serverPath (version $version)" -ForegroundColor Gray
    try {
        Invoke-RestMethod -Uri $itemUrl -Headers $headers -Method Get -OutFile $localPath
        $successCount++
    }
    catch {
        Write-Warning "  Failed to download $serverPath : $_"
        $failCount++
    }
}

# --- Summary ---
Write-Host ""
Write-Host "Download complete." -ForegroundColor Cyan
Write-Host "  Success: $successCount" -ForegroundColor Green
if ($failCount -gt 0) {
    Write-Host "  Failed:  $failCount" -ForegroundColor Red
}
Write-Host "  Output:  $OutputDirectory" -ForegroundColor Cyan
