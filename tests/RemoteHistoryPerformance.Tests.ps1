[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'Synthetic fixture validates DPAPI round-trip behavior and is not a real secret.')]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'DiskHealth.ps1'
$manifestPath = Join-Path (Split-Path -Parent $PSScriptRoot) '.assets\WinRMConnection\WinRMConnection.psd1'
Import-Module -Name $manifestPath -Force -ErrorAction Stop
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $scriptPath,
    [ref]$tokens,
    [ref]$parseErrors
)
if ($parseErrors.Count -gt 0) {
    throw ($parseErrors | Format-List | Out-String)
}

foreach ($functionName in @(
    'Get-DiskHealthStoredCredential'
    'Save-DiskHealthStoredCredential'
    'Remove-DiskHealthStoredCredential'
)) {
    $functionAst = $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq $functionName
    }, $true) | Select-Object -First 1
    if (-not $functionAst) {
        throw "Missing credential helper: $functionName"
    }
    Invoke-Expression $functionAst.Extent.Text
}

$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) "DiskHealthCredentialTest-$PID-$([guid]::NewGuid().ToString('N'))"
try {
    $securePassword = ConvertTo-SecureString 'fixture-secret' -AsPlainText -Force
    $fixtureCredential = [PSCredential]::new('LAB\Technician', $securePassword)

    Save-DiskHealthStoredCredential `
        -NetworkId 'network-a' `
        -ComputerNames @('SE', '192.0.2.15') `
        -CredentialToStore $fixtureCredential `
        -StateRoot $temporaryRoot

    $stored = Get-DiskHealthStoredCredential `
        -NetworkId 'network-a' `
        -ComputerNames @('192.0.2.15') `
        -StateRoot $temporaryRoot
    if ($null -eq $stored -or $stored.UserName -ne 'LAB\Technician') {
        throw 'DPAPI credential round-trip failed for the matching network and target.'
    }

    $wrongNetwork = Get-DiskHealthStoredCredential `
        -NetworkId 'network-b' `
        -ComputerNames @('192.0.2.15') `
        -StateRoot $temporaryRoot
    if ($null -ne $wrongNetwork) {
        throw 'A credential escaped its network scope.'
    }

    Remove-DiskHealthStoredCredential `
        -NetworkId 'network-a' `
        -ComputerNames @('SE', '192.0.2.15') `
        -StateRoot $temporaryRoot
    $afterRemoval = Get-DiskHealthStoredCredential `
        -NetworkId 'network-a' `
        -ComputerNames @('SE', '192.0.2.15') `
        -StateRoot $temporaryRoot
    if ($null -ne $afterRemoval) {
        throw 'Credential removal did not delete all aliases.'
    }
} finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}

$source = Get-Content -LiteralPath $scriptPath -Raw
if ($source -notmatch 'Get-WinRMConnectionHistory\s+-NetworkId') {
    throw 'Connection history is not filtered by current network identity.'
}
if ($source -notmatch 'Add-WinRMConnectionHistoryEntry') {
    throw 'Successful WinRM connections are not written to shared history.'
}
foreach ($profileApi in @('Get-WinRMCredentialProfile', 'Save-WinRMCredentialProfile', 'Remove-WinRMCredentialProfile')) {
    if ($source -notmatch $profileApi) {
        throw "Credential storage must use shared API $profileApi."
    }
}
if ($source -match 'Export-Clixml|Import-Clixml|ConvertFrom-SecureString\s+-AsPlainText') {
    throw 'DiskHealth must not own a duplicate credential serialization implementation.'
}
if ($source -notmatch '(?s)\$indexedDevices\.Count\s+-eq\s+0\).*?\$identityOutput\s*=\s*&\s*\$smartctlPath\s+-i') {
    throw 'Slow smartctl identity probing is not guarded as an index-mapping fallback.'
}
if ($source -notmatch '(?s)\$physDisk\.BusType\s+-ne\s+"USB".{0,500}Get-StorageReliabilityCounter') {
    throw 'Storage reliability counters are not guarded against the measured USB timeout path.'
}
foreach ($phase in @(
    'WinRM.NewPSSession'
    'WinRM.PrerequisiteProbe'
    'Collector.Total'
    'Operation.Total'
)) {
    if ($source -notmatch [regex]::Escape($phase)) {
        throw "Missing benchmark phase: $phase"
    }
}

Write-Host 'PASS: network-scoped DPAPI credential reuse and performance guardrails.' -ForegroundColor Green
