[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$manifest = Join-Path -Path $repoRoot -ChildPath '.assets\WinRMConnection\WinRMConnection.psd1'
$scriptPath = Join-Path -Path $repoRoot -ChildPath 'DiskHealth.ps1'

Test-ModuleManifest -Path $manifest -ErrorAction Stop | Out-Null
Import-Module -Name $manifest -Force -ErrorAction Stop
foreach ($requiredExport in @(
    'Connect-WinRMSession'
    'Get-WinRMCredentialProfile'
    'Get-WinRMConnectionErrorCategory'
    'New-WinRMBlankPasswordCredential'
    'Remove-WinRMCredentialProfile'
    'Save-WinRMCredentialProfile'
)) {
    if (-not (Get-Command -Name $requiredExport -ErrorAction SilentlyContinue)) {
        throw "Vendored WinRMConnection module did not export $requiredExport."
    }
}

$tokens = $null
$parseErrors = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
    throw "DiskHealth.ps1 has $($parseErrors.Count) parser error(s)."
}

$source = Get-Content -LiteralPath $scriptPath -Raw
foreach ($requiredFunction in @(
    'Import-DiskHealthWinRMConnection'
    'Write-DiskHealthWinRMConnectionStatus'
)) {
    if ($source -notmatch "function\s+$requiredFunction") {
        throw "DiskHealth.ps1 is missing $requiredFunction."
    }
}
if ($source -notmatch 'Connect-WinRMSession') {
    throw 'DiskHealth.ps1 does not use the shared WinRM session connector.'
}
if ($source -match '\bNew-PSSession\b') {
    throw 'DiskHealth.ps1 still contains an ad-hoc New-PSSession call.'
}
if ($source -notmatch 'New-WinRMBlankPasswordCredential') {
    throw 'DiskHealth.ps1 does not use the safe blank-password credential helper.'
}
foreach ($profileApi in @(
    'Get-WinRMCredentialProfile'
    'Save-WinRMCredentialProfile'
    'Remove-WinRMCredentialProfile'
)) {
    if ($source -notmatch $profileApi) {
        throw "DiskHealth.ps1 does not use shared credential API $profileApi."
    }
}
if ($source -match 'Export-Clixml|Import-Clixml|Get-DiskHealthCredentialKey') {
    throw 'DiskHealth.ps1 still contains a consumer-owned DPAPI profile implementation.'
}
if ($source -notmatch "Get-WinRMConnectionErrorCategory\s+-ErrorObject" -or $source -notmatch "AuthenticationRejected") {
    throw 'DiskHealth.ps1 does not classify authentication rejection through WinRMConnection.'
}
if ($source -notmatch '(?s)\$CredentialFromSavedProfile.{0,300}Remove-DiskHealthStoredCredential') {
    throw 'DiskHealth.ps1 does not limit stale-profile removal to a credential loaded from the saved store.'
}

Write-Host 'DiskHealth WinRMConnection integration tests passed.' -ForegroundColor Green
