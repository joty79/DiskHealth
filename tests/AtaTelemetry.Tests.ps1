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

foreach ($functionName in @('Get-AtaTemperatureCelsius', 'Get-AtaSpinUpTimeDisplay', 'Get-AtaPowerOnHoursValue', 'Get-SeagateNormalizedRateState', 'Get-SeagateReadEccContext')) {
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

Assert-Equal (Get-SeagateNormalizedRateState -AttributeId 0x01 -Current 80 -Threshold 6 -IsSeagateHdd $true) 'AboveThreshold' 'Seagate Raw Read Error Rate above threshold is not a health claim'
Assert-Equal (Get-SeagateNormalizedRateState -AttributeId 0x07 -Current 72 -Threshold 45 -IsSeagateHdd $true) 'AboveThreshold' 'Seagate Seek Error Rate above threshold is not a health claim'
Assert-Equal (Get-SeagateNormalizedRateState -AttributeId 0xC3 -Current 80 -Threshold 0 -IsSeagateHdd $true) 'NoThreshold' 'Seagate ECC counter without threshold'
Assert-Equal (Get-SeagateNormalizedRateState -AttributeId 0x01 -Current 6 -Threshold 6 -IsSeagateHdd $true) 'ThresholdCrossed' 'Seagate normalized threshold crossing'
Assert-Equal (Get-SeagateNormalizedRateState -AttributeId 0x01 -Current 80 -Threshold 6 -IsSeagateHdd $false) 'NotApplicable' 'Non-Seagate drive retains its profile rules'

$seagateContextAttributes = @(
    [PSCustomObject]@{ ID = 0x01; Current = 80; Worst = 64; Threshold = 6; Raw = [uint64]110952844 }
    [PSCustomObject]@{ ID = 0x05; Current = 100; Worst = 100; Threshold = 10; Raw = [uint64]0 }
    [PSCustomObject]@{ ID = 0xBB; Current = 100; Worst = 100; Threshold = 0; Raw = [uint64]0 }
    [PSCustomObject]@{ ID = 0xC3; Current = 80; Worst = 64; Threshold = 0; Raw = [uint64]110952844 }
    [PSCustomObject]@{ ID = 0xC5; Current = 100; Worst = 100; Threshold = 0; Raw = [uint64]0 }
    [PSCustomObject]@{ ID = 0xC6; Current = 100; Worst = 100; Threshold = 0; Raw = [uint64]0 }
)
$seagateContextSmart = [PSCustomObject]@{
    ata_smart_error_log = [PSCustomObject]@{
        summary = [PSCustomObject]@{ count = 0 }
    }
}
$seagateContext = Get-SeagateReadEccContext -Attributes $seagateContextAttributes -SmartData $seagateContextSmart -IsSeagateHdd $true
Assert-Equal $seagateContext.HasMirroredRawTelemetry $true 'Seagate 01/C3 mirrored raw telemetry'
Assert-Equal $seagateContext.HasUnresolvedIndicators $false 'Seagate zero unresolved indicators'
Assert-Equal $seagateContext.ErrorLogCount 0 'Seagate SMART error log count'

$pendingContextAttributes = @($seagateContextAttributes | ForEach-Object {
    if ($_.ID -eq 0xC5) { [PSCustomObject]@{ ID = $_.ID; Current = $_.Current; Worst = $_.Worst; Threshold = $_.Threshold; Raw = [uint64]2 } }
    else { $_ }
})
$pendingContext = Get-SeagateReadEccContext -Attributes $pendingContextAttributes -SmartData $seagateContextSmart -IsSeagateHdd $true
Assert-Equal $pendingContext.HasUnresolvedIndicators $true 'Seagate pending sector remains a warning'

$productionText = Get-Content -LiteralPath $scriptPath -Raw
if (-not $productionText.Contains("if (`$null -eq `$health -and `$isRotationalMedia) { 'SMART' }")) {
    throw 'HDD status must identify SMART-based evaluation instead of displaying N/A.'
}
if (-not $productionText.Contains('Οι μηχανικοί HDD δεν διαθέτουν τυποποιημένο wear/health percentage.')) {
    throw 'Missing HDD-specific health explanation.'
}
if (-not $productionText.Contains('Το Current πάνω από Threshold σημαίνει μόνο ότι δεν ενεργοποιήθηκε failure condition')) {
    throw 'Missing Seagate proprietary raw-counter explanation.'
}
if (-not $productionText.Contains("if (`$seagateRateState -eq 'ThresholdCrossed') { `$lineColor = `$Red }")) {
    throw 'Seagate proprietary rate rows must remain neutral unless the firmware threshold is crossed.'
}
if (-not $productionText.Contains('| Score   | Worst   | Fail <=   | Vendor Raw')) {
    throw 'ATA SMART table must identify normalized scores and opaque vendor raw values.'
}
if (-not $productionText.Contains('### 🔵 Seagate Read / ECC Context')) {
    throw 'Missing dedicated Seagate read/ECC context block.'
}

Write-Host 'PASS: ATA temperature, Seagate rate, and HDD presentation regression fixtures.' -ForegroundColor Green
