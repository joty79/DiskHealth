[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$manifest = Join-Path -Path $repoRoot -ChildPath '.assets\WinRMWorkshop\WinRMWorkshop.psd1'
$scriptPath = Join-Path -Path $repoRoot -ChildPath 'DiskHealth.ps1'

$moduleInfo = Test-ModuleManifest -Path $manifest -ErrorAction Stop
if ($moduleInfo.Version -ne [version]'1.0.0') {
    throw "Expected WinRMWorkshop 1.0.0, found $($moduleInfo.Version)."
}

Import-Module -Name $manifest -Force -ErrorAction Stop -WarningAction Stop
foreach ($requiredExport in @(
    'Add-WinRMWorkshopTrustedHost'
    'Get-WinRMWorkshopTrustedHost'
    'Remove-WinRMWorkshopTrustedHost'
)) {
    if (-not (Get-Command -Name $requiredExport -ErrorAction SilentlyContinue)) {
        throw "Vendored WinRMWorkshop module did not export $requiredExport."
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
    'Import-DiskHealthWinRMWorkshop'
    'Write-DiskHealthWinRMWorkshopStatus'
)) {
    if ($source -notmatch "function\s+$requiredFunction") {
        throw "DiskHealth.ps1 is missing $requiredFunction."
    }
}
if ($source -notmatch 'Add-WinRMWorkshopTrustedHost') {
    throw 'DiskHealth.ps1 does not use the shared exact-target TrustedHosts preparation.'
}
if ($source -match '(?s)Set-Item.{0,80}WSMan:\\localhost\\Client\\TrustedHosts') {
    throw 'DiskHealth.ps1 still contains a consumer-owned TrustedHosts mutation.'
}
if ($source -match 'set-trustedhosts-|Start-Process\s+pwsh.+-Verb\s+RunAs|Get-Command\s+gsudo') {
    throw 'DiskHealth.ps1 still contains the legacy scratch/elevation TrustedHosts implementation.'
}

Write-Host 'DiskHealth WinRMWorkshop integration tests passed.' -ForegroundColor Green
