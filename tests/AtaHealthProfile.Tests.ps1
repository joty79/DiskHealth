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

foreach ($name in @('Get-AtaTelemetryProfile', 'Get-AtaHealthEstimate', 'Get-AttributeName')) {
    $functionAst = $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true) | Select-Object -First 1
    if (-not $functionAst) { throw "Required production function not found: $name" }
    Invoke-Expression $functionAst.Extent.Text
}

function Assert-Equal {
    param($Actual, $Expected, [string]$Label)
    if ($Actual -ne $Expected) {
        throw "$Label failed. Expected '$Expected', got '$Actual'."
    }
}

function New-JsonAttributeFixture {
    param([int]$Id, [long]$Raw, [int]$Current = 100)
    [PSCustomObject]@{
        id = $Id
        value = $Current
        raw = [PSCustomObject]@{ value = $Raw; string = "$Raw" }
    }
}

function New-ParsedAttributeFixture {
    param([int]$Id, [long]$Raw, [int]$Current = 100)
    [PSCustomObject]@{ ID = $Id; Raw = $Raw; Current = $Current }
}

# Live regression: generic model SSD 120GB / U0510A0 from DESKTOP-BTBRTH8.
# smartctl does not have this firmware in drivedb.h, but the complete attribute
# layout matches the official Silicon Motion OEM layout and A9 is life remaining.
$smiIds = @(0x01, 0x05, 0x09, 0x0C, 0xA0, 0xA1, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7, 0xA8, 0xA9, 0xAF, 0xB0, 0xB1, 0xB2, 0xB5, 0xB6, 0xC0, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xC7, 0xE8, 0xF1, 0xF2, 0xF5)
$smiFixture = @($smiIds | ForEach-Object { New-JsonAttributeFixture -Id $_ -Raw $(if ($_ -eq 0xA9) { 91 } else { 0 }) })
$smiProfile = Get-AtaTelemetryProfile -Model 'SSD 120GB' -Firmware 'U0510A0' -Attributes $smiFixture
Assert-Equal $smiProfile 'SiliconMotionOEM' 'Live generic SMI profile classification'

$parsedSmi = @($smiIds | ForEach-Object { New-ParsedAttributeFixture -Id $_ -Raw $(if ($_ -eq 0xA9) { 91 } else { 0 }) })
$smiHealth = Get-AtaHealthEstimate -Profile $smiProfile -Attributes $parsedSmi
Assert-Equal $smiHealth.IsTrusted $true 'Live SMI health trust'
Assert-Equal $smiHealth.Percentage 91 'Live SMI A9 health'
Assert-Equal (Get-AttributeName 0xA3 $smiProfile) 'Initial Bad Block Count' 'SMI A3 mapping'
Assert-Equal (Get-AttributeName 0xA8 $smiProfile) 'Maximum Erase Count of Spec' 'SMI A8 mapping'
Assert-Equal (Get-AttributeName 0xA9 $smiProfile) 'Remaining Lifetime Percentage' 'SMI A9 mapping'
Assert-Equal (Get-AttributeName 0xB1 $smiProfile) 'Total Wear Level Count' 'SMI B1 is not remaining life'

# Existing Patriot Burst Elite fixture uses a different controller layout.
$burstIds = @(0x01, 0x05, 0x09, 0x0C, 0xA1, 0xA2, 0xA3, 0xA4, 0xA6, 0xA7, 0xA8, 0xA9, 0xAB, 0xAC, 0xAE, 0xAF, 0xBB, 0xC2, 0xC3, 0xC4, 0xC7, 0xCE, 0xCF, 0xE8, 0xF1, 0xF2, 0xF9)
$burstFixture = @($burstIds | ForEach-Object { New-JsonAttributeFixture -Id $_ -Raw $(if ($_ -eq 0xA9) { 100 } else { 0 }) })
$burstProfile = Get-AtaTelemetryProfile -Model 'Patriot Burst Elite 240GB' -Firmware 'VG01100V' -Attributes $burstFixture
Assert-Equal $burstProfile 'PatriotBurst' 'Patriot Burst profile classification'
Assert-Equal (Get-AttributeName 0xA3 $burstProfile) 'Max PE Cycle' 'Patriot Burst A3 mapping remains distinct'

# Live regression: Patriot Burst / SBFM61.3 from DESKTOP-RLT4E3M. The official
# smartctl Phison profile identifies E7 as SSD_Life_Left and F1 as GiB written.
$phisonFixture = @(
    [PSCustomObject]@{ id = 0x01; name = 'Raw_Read_Error_Rate'; value = 100; raw = [PSCustomObject]@{ value = 0 } }
    [PSCustomObject]@{ id = 0xA8; name = 'SATA_Phy_Error_Count'; value = 100; raw = [PSCustomObject]@{ value = 0 } }
    [PSCustomObject]@{ id = 0xAA; name = 'Bad_Blk_Ct_Lat/Erl'; value = 100; raw = [PSCustomObject]@{ value = 60 } }
    [PSCustomObject]@{ id = 0xAD; name = 'MaxAvgErase_Ct'; value = 100; raw = [PSCustomObject]@{ value = 1835067 } }
    [PSCustomObject]@{ id = 0xE7; name = 'SSD_Life_Left'; value = 100; raw = [PSCustomObject]@{ value = 99 } }
    [PSCustomObject]@{ id = 0xF1; name = 'Lifetime_Writes_GiB'; value = 100; raw = [PSCustomObject]@{ value = 2127 } }
)
$phisonProfile = Get-AtaTelemetryProfile -Model 'Patriot Burst' -Firmware 'SBFM61.3' -Attributes $phisonFixture
Assert-Equal $phisonProfile 'Phison' 'Live Patriot Burst Phison classification'
$parsedPhison = @(
    New-ParsedAttributeFixture -Id 0xE7 -Raw 99
    New-ParsedAttributeFixture -Id 0xF1 -Raw 2127
)
$phisonHealth = Get-AtaHealthEstimate -Profile $phisonProfile -Attributes $parsedPhison
Assert-Equal $phisonHealth.IsTrusted $true 'Phison health trust'
Assert-Equal $phisonHealth.Percentage 99 'Phison E7 health'
Assert-Equal (Get-AttributeName 0xE7 $phisonProfile) 'SSD Life Left' 'Phison E7 mapping'
Assert-Equal (Get-AttributeName 0xF1 $phisonProfile) 'Lifetime Writes (GiB)' 'Phison F1 mapping'

# A generic B1 must never be silently presented as a trusted health percentage.
$unknownFixture = @(New-ParsedAttributeFixture -Id 0xB1 -Raw 0 -Current 100)
$unknownHealth = Get-AtaHealthEstimate -Profile 'Generic' -Attributes $unknownFixture
Assert-Equal $unknownHealth.IsTrusted $false 'Generic B1 is not trusted health'
Assert-Equal $unknownHealth.Percentage $null 'Generic B1 has no invented percentage'

Write-Host 'PASS: ATA controller profile and health-source regression fixtures.' -ForegroundColor Green
