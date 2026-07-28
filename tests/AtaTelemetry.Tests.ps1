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

foreach ($functionName in @('Get-AtaTemperatureCelsius', 'Get-AtaSpinUpTimeDisplay', 'Get-AtaPowerOnHoursValue', 'Get-SeagateNormalizedRateState')) {
    $functionAst = $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
    }, $true) | Select-Object -First 1
    if (-not $functionAst) {
        throw "Required production function not found: $functionName"
    }
    Invoke-Expression $functionAst.Extent.Text
}

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

Assert-Equal (Get-AtaSpinUpTimeDisplay -RawMilliseconds 7433) '7433 ms (7.43 s)' 'WD 8 TB spin-up time formatting'
Assert-Equal (Get-AtaSpinUpTimeDisplay -RawMilliseconds 750) '750 ms (0.75 s)' 'sub-second spin-up time formatting'
Assert-Equal (Get-AtaSpinUpTimeDisplay -RawMilliseconds 700000) '700000' 'implausible spin-up value remains raw'

$seagateHoursFixture = [PSCustomObject]@{
    Raw       = [uint64]10733608604013536
    RawString = '5088h+41m+39.113s'
}
$seagateSmartFixture = [PSCustomObject]@{ power_on_time = [PSCustomObject]@{ hours = 5088 } }
Assert-Equal (Get-AtaPowerOnHoursValue -Attribute $seagateHoursFixture -SmartData $seagateSmartFixture) 5088 'Seagate top-level decoded power-on hours'
Assert-Equal (Get-AtaPowerOnHoursValue -Attribute $seagateHoursFixture -SmartData $null) 5088 'Seagate raw-string decoded power-on hours'

$plainHoursFixture = [PSCustomObject]@{ Raw = [uint64]9639; RawString = '9639' }
Assert-Equal (Get-AtaPowerOnHoursValue -Attribute $plainHoursFixture -SmartData $null) 9639 'plain ATA power-on hours'

Assert-Equal (Get-SeagateNormalizedRateState -AttributeId 0x01 -Current 80 -Threshold 6 -IsSeagateHdd $true) 'Normal' 'Seagate Raw Read Error Rate above threshold'
Assert-Equal (Get-SeagateNormalizedRateState -AttributeId 0x07 -Current 72 -Threshold 45 -IsSeagateHdd $true) 'Normal' 'Seagate Seek Error Rate above threshold'
Assert-Equal (Get-SeagateNormalizedRateState -AttributeId 0xC3 -Current 80 -Threshold 0 -IsSeagateHdd $true) 'Neutral' 'Seagate ECC counter without threshold'
Assert-Equal (Get-SeagateNormalizedRateState -AttributeId 0x01 -Current 6 -Threshold 6 -IsSeagateHdd $true) 'Critical' 'Seagate normalized threshold crossing'
Assert-Equal (Get-SeagateNormalizedRateState -AttributeId 0x01 -Current 80 -Threshold 6 -IsSeagateHdd $false) 'NotApplicable' 'Non-Seagate drive retains its profile rules'

$productionText = Get-Content -LiteralPath $scriptPath -Raw
if (-not $productionText.Contains("if (`$null -eq `$health -and `$isRotationalMedia) { 'SMART' }")) {
    throw 'HDD status must identify SMART-based evaluation instead of displaying N/A.'
}
if (-not $productionText.Contains('Οι μηχανικοί HDD δεν διαθέτουν τυποποιημένο wear/health percentage.')) {
    throw 'Missing HDD-specific health explanation.'
}
if (-not $productionText.Contains('Seagate 01/07/C3: τα raw πεδία είναι proprietary vendor telemetry')) {
    throw 'Missing Seagate proprietary raw-counter explanation.'
}

Write-Host 'PASS: ATA temperature, Seagate rate, and HDD presentation regression fixtures.' -ForegroundColor Green
