[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'DiskHealth.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors) {
    throw "Production script has parser errors: $($parseErrors -join '; ')"
}

$functionAst = $ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-AtaTemperatureCelsius'
}, $true) | Select-Object -First 1
if (-not $functionAst) {
    throw 'Required production function not found: Get-AtaTemperatureCelsius'
}
Invoke-Expression $functionAst.Extent.Text

function Assert-Equal {
    param($Actual, $Expected, [string]$Label)
    if ($Actual -ne $Expected) {
        throw "$Label failed. Expected '$Expected', got '$Actual'."
    }
}

$wdFixture = [PSCustomObject]@{
    Raw       = [uint64]201864380451
    RawString = '35 (Min/Max 14/47)'
}
$wdSmartFixture = [PSCustomObject]@{ temperature = [PSCustomObject]@{ current = 35 } }
Assert-Equal (Get-AtaTemperatureCelsius -Attribute $wdFixture -SmartData $wdSmartFixture) 35 'WD packed temperature raw string'

$topLevelFallback = [PSCustomObject]@{ Raw = [uint64]201864380451; RawString = '' }
Assert-Equal (Get-AtaTemperatureCelsius -Attribute $topLevelFallback -SmartData $wdSmartFixture) 35 'smartctl top-level temperature fallback'

$plainFixture = [PSCustomObject]@{ Raw = [uint64]42; RawString = '42' }
Assert-Equal (Get-AtaTemperatureCelsius -Attribute $plainFixture -SmartData $null) 42 'plain ATA temperature'

$packedUnknown = [PSCustomObject]@{ Raw = [uint64]201864380451; RawString = '' }
Assert-Equal (Get-AtaTemperatureCelsius -Attribute $packedUnknown -SmartData $null) $null 'unresolved packed temperature is not labeled Celsius'

Write-Host 'PASS: ATA temperature regression fixtures.' -ForegroundColor Green
