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

foreach ($name in @(
    'Get-AtaTelemetryProfile'
    'Get-AtaHealthEstimate'
    'Get-AtaStandardizedEnduranceEstimate'
    'Get-AtaSmartctlDatabaseEnduranceEstimate'
    'Get-WindowsStorageWearEstimate'
    'Get-AtaLifeEstimate'
    'Get-AtaDataTransferEstimate'
    'Test-SmartctlAtaLifeEvidence'
    'Get-SmartctlHealthArguments'
    'Get-AttributeName'
    'Test-AtaRawWarningAttribute'
)) {
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

# Live regression: KINGSTON SUV400S37120G / 0C3J96R9 from 192.168.1.65.
# Kingston MKP-521.3 defines E7 as a normalized remaining-life metric and does
# not document B7. The live drive reports E7 Current=80, raw=20 and B7 raw=106.
$kingstonUv400Fixture = @(
    [PSCustomObject]@{ id = 0x05; name = 'Reallocated_Sector_Ct'; value = 100; raw = [PSCustomObject]@{ value = 0 } }
    [PSCustomObject]@{ id = 0xB1; name = 'Wear_Leveling_Count'; value = 80; raw = [PSCustomObject]@{ value = 6464 } }
    [PSCustomObject]@{ id = 0xB4; name = 'Unused_Rsvd_Blk_Cnt_Tot'; value = 100; raw = [PSCustomObject]@{ value = 616 } }
    [PSCustomObject]@{ id = 0xB7; name = 'Runtime_Bad_Block'; value = 83; raw = [PSCustomObject]@{ value = 106 } }
    [PSCustomObject]@{ id = 0xBB; name = 'Reported_Uncorrect'; value = 100; raw = [PSCustomObject]@{ value = 0 } }
    [PSCustomObject]@{ id = 0xC5; name = 'Current_Pending_Sector'; value = 100; raw = [PSCustomObject]@{ value = 0 } }
    [PSCustomObject]@{ id = 0xE7; name = 'SSD_Life_Left'; value = 80; raw = [PSCustomObject]@{ value = 20 } }
    [PSCustomObject]@{ id = 0xF1; name = 'Host_Writes_GiB'; value = 100; raw = [PSCustomObject]@{ value = 16014 } }
)
$kingstonUv400Profile = Get-AtaTelemetryProfile -Model 'KINGSTON SUV400S37120G' -Firmware '0C3J96R9' -Attributes $kingstonUv400Fixture
Assert-Equal $kingstonUv400Profile 'KingstonUV400' 'Live Kingston UV400 profile classification'
$parsedKingstonUv400 = @(
    New-ParsedAttributeFixture -Id 0xB7 -Raw 106 -Current 83
    New-ParsedAttributeFixture -Id 0xE7 -Raw 20 -Current 80
)
$kingstonUv400Health = Get-AtaHealthEstimate -Profile $kingstonUv400Profile -Attributes $parsedKingstonUv400
Assert-Equal $kingstonUv400Health.IsTrusted $true 'Kingston UV400 health trust'
Assert-Equal $kingstonUv400Health.Percentage 80 'Kingston UV400 normalized E7 health'
Assert-Equal $kingstonUv400Health.Source 'SSD Life Left (0xE7 normalized)' 'Kingston UV400 health source'
Assert-Equal (Get-AttributeName 0xE7 $kingstonUv400Profile) 'SSD Life Left' 'Kingston UV400 E7 mapping'
Assert-Equal (Get-AttributeName 0xB7 $kingstonUv400Profile) 'Vendor-specific (not in Kingston spec)' 'Kingston UV400 B7 stays opaque'
Assert-Equal (Test-AtaRawWarningAttribute -Profile $kingstonUv400Profile -AttributeId 0xB7) $false 'Kingston UV400 B7 is not an invented warning'
Assert-Equal (Test-AtaRawWarningAttribute -Profile $kingstonUv400Profile -AttributeId 0xAB) $true 'Kingston UV400 program failures remain warnings'
Assert-Equal (Test-AtaRawWarningAttribute -Profile 'Samsung' -AttributeId 0xB7) $true 'Samsung B7 warning remains profile-scoped'
Assert-Equal (Test-AtaRawWarningAttribute -Profile 'Generic' -AttributeId 0xB7) $false 'Generic B7 stays vendor-specific'

# Live regression: WDC WDS120G2G0A-00JH30 / UE220400 from 192.168.1.221.
# smartctl 7.5 recognizes this exact WD/SanDisk family. E8 is the available
# reserved-space percentage; AA is grown bad blocks, while A9 is total bad blocks.
$wdFixture = @(
    New-JsonAttributeFixture -Id 0x05 -Raw 6
    New-JsonAttributeFixture -Id 0xA5 -Raw 918
    New-JsonAttributeFixture -Id 0xA6 -Raw 7
    New-JsonAttributeFixture -Id 0xA7 -Raw 15
    New-JsonAttributeFixture -Id 0xA8 -Raw 17
    New-JsonAttributeFixture -Id 0xA9 -Raw 83
    New-JsonAttributeFixture -Id 0xAA -Raw 6
    New-JsonAttributeFixture -Id 0xAB -Raw 0
    New-JsonAttributeFixture -Id 0xAC -Raw 0
    New-JsonAttributeFixture -Id 0xAD -Raw 7
    New-JsonAttributeFixture -Id 0xE6 -Raw 2465330627134
    New-JsonAttributeFixture -Id 0xE8 -Raw 95
    New-JsonAttributeFixture -Id 0xE9 -Raw 856
    New-JsonAttributeFixture -Id 0xEA -Raw 4994
    New-JsonAttributeFixture -Id 0xF1 -Raw 1760
    New-JsonAttributeFixture -Id 0xF2 -Raw 1600
    New-JsonAttributeFixture -Id 0xF4 -Raw 0
)
$wdProfile = Get-AtaTelemetryProfile -Model 'WDC WDS120G2G0A-00JH30' -Firmware 'UE220400' -Attributes $wdFixture
Assert-Equal $wdProfile 'SanDisk' 'Live WD Green profile classification'
$parsedWd = @(
    New-ParsedAttributeFixture -Id 0xE8 -Raw 95
    New-ParsedAttributeFixture -Id 0xAA -Raw 6
)
$wdHealth = Get-AtaHealthEstimate -Profile $wdProfile -Attributes $parsedWd
Assert-Equal $wdHealth.IsTrusted $true 'WD E8 reserve trust'
Assert-Equal $wdHealth.Percentage 95 'WD E8 reserve percentage'
Assert-Equal $wdHealth.MetricLabel 'Reserve' 'WD E8 metric label'
Assert-Equal (Get-AttributeName 0xA7 $wdProfile) 'Max Bad Blocks per Die' 'WD A7 mapping'
Assert-Equal (Get-AttributeName 0xA8 $wdProfile) 'Maximum P/E Cycles (TLC)' 'WD A8 mapping'
Assert-Equal (Get-AttributeName 0xAA $wdProfile) 'Grown Bad Blocks' 'WD AA mapping'
Assert-Equal (Get-AttributeName 0xE9 $wdProfile) 'NAND GB Written (TLC)' 'WD E9 mapping'
Assert-Equal (Get-AttributeName 0xF4 $wdProfile) 'Temperature Throttle Status' 'WD F4 mapping'
Assert-Equal (Get-AttributeName 0xF1 $wdProfile) 'Host Writes (LBAs)' 'SanDisk/WD F1 unit is not mislabeled as GiB'
Assert-Equal (Get-AttributeName 0xF2 $wdProfile) 'Host Reads (LBAs)' 'SanDisk/WD F2 unit is not mislabeled as GiB'
Assert-Equal (Get-AttributeName 0xEE $wdProfile) 'Media Wearout Cycles Remaining' 'SanDisk/WD EE mapping'

$x600TransferFixture = @(
    New-ParsedAttributeFixture -Id 0xF1 -Raw 31862404748
    New-ParsedAttributeFixture -Id 0xF2 -Raw 56447295832
)
$x600SmartFixture = [PSCustomObject]@{ logical_block_size = 512 }
$x600Transfers = Get-AtaDataTransferEstimate -Profile 'SanDisk' -Attributes $x600TransferFixture -SmartData $x600SmartFixture
Assert-Equal $x600Transfers.IsSupported $true 'SanDisk X600 transfer totals are supported with logical block size'
Assert-Equal $x600Transfers.HostWritesGiB 15193.18 'SanDisk X600 F1 LBA conversion'
Assert-Equal $x600Transfers.HostReadsGiB 26916.17 'SanDisk X600 F2 LBA conversion'

$x600WithoutBlockSize = Get-AtaDataTransferEstimate -Profile 'SanDisk' -Attributes $x600TransferFixture -SmartData $null
Assert-Equal $x600WithoutBlockSize.IsSupported $false 'SanDisk LBA totals require logical block size'
Assert-Equal $x600WithoutBlockSize.HostWritesGiB $null 'SanDisk LBA totals are not guessed without block size'

$x600LifeAttributes = @(
    New-ParsedAttributeFixture -Id 0xE6 -Raw 6932150224462 -Current 100
    New-ParsedAttributeFixture -Id 0xEE -Raw 15640225 -Current 94
)
$x600VendorHealth = Get-AtaHealthEstimate -Profile 'SanDisk' -Attributes $x600LifeAttributes
Assert-Equal $x600VendorHealth.IsTrusted $true 'SanDisk X600 normalized EE life trust'
Assert-Equal $x600VendorHealth.Percentage 94 'SanDisk X600 normalized EE remaining life'
Assert-Equal $x600VendorHealth.MetricLabel 'Life' 'SanDisk X600 vendor metric is remaining life'

$x600StandardizedFixture = [PSCustomObject]@{
    ata_device_statistics = [PSCustomObject]@{
        pages = @([PSCustomObject]@{
            number = 7
            table = @([PSCustomObject]@{
                offset = 8
                value = 4
                flags = [PSCustomObject]@{ valid = $true }
            })
        })
    }
}
$x600ReconciledHealth = Get-AtaLifeEstimate -SmartData $x600StandardizedFixture -Profile 'SanDisk' -Attributes $x600LifeAttributes -ReliabilityCounter $null
Assert-Equal $x600ReconciledHealth.IsTrusted $true 'SanDisk X600 close standard/vendor readings reconcile'
Assert-Equal $x600ReconciledHealth.Percentage 94 'SanDisk X600 uses conservative close agreement'
if ($x600ReconciledHealth.Source -notmatch '96%.*94%') {
    throw "SanDisk X600 reconciliation source did not preserve both readings: $($x600ReconciledHealth.Source)"
}

$conflictingStandardizedFixture = [PSCustomObject]@{
    ata_device_statistics = [PSCustomObject]@{
        pages = @([PSCustomObject]@{
            number = 7
            table = @([PSCustomObject]@{
                offset = 8
                value = 30
                flags = [PSCustomObject]@{ valid = $true }
            })
        })
    }
}
$conflictingLife = Get-AtaLifeEstimate -SmartData $conflictingStandardizedFixture -Profile 'SanDisk' -Attributes $x600LifeAttributes -ReliabilityCounter $null
Assert-Equal $conflictingLife.IsTrusted $false 'Large standard/vendor life conflict is unsupported'
Assert-Equal $conflictingLife.Percentage $null 'Large standard/vendor conflict has no invented percentage'
if ($conflictingLife.Source -notmatch '70%.*94%') {
    throw "Large lifetime conflict did not preserve both readings: $($conflictingLife.Source)"
}

# A WDC model name alone must not apply SSD-specific WD/SanDisk mappings to HDDs.
$wdHddProfile = Get-AtaTelemetryProfile -Model 'WDC WD10EZEX-08WN4A0' -Firmware '01.01A01' -Attributes @()
Assert-Equal $wdHddProfile 'Generic' 'WDC HDD is not classified as SanDisk SSD'

$productionText = Get-Content -LiteralPath $scriptPath -Raw
foreach ($requiredBinarySupportText in @(
    "`$status = 'REVIEW'"
    "elseif (`$null -eq `$health) { 'UNSUPPORTED' }"
    'Υποστήριξη διάγνωσης:'
)) {
    if (-not $productionText.Contains($requiredBinarySupportText)) {
        throw "Missing binary supported/unsupported report behavior: $requiredBinarySupportText"
    }
}
foreach ($staleConclusion in @(
    'ΠΡΟΧΩΡΗΣΤΕ ΑΜΕΣΑ ΣΕ BACKUP / CLONE ΚΑΙ ΑΝΤΙΚΑΤΑΣΤΑΣΗ ΤΟΥ ΔΙΣΚΟΥ.',
    'Δεν συνιστάται να παραμείνει ως C: boot drive.'
)) {
    if ($productionText.Contains($staleConclusion)) {
        throw "Retired-block CAUTION still contains the stale unconditional replacement conclusion: $staleConclusion"
    }
}
foreach ($requiredConclusion in @(
    'δεν αποδεικνύει ότι η φθορά συνεχίζεται τώρα',
    'Αν τα 05/AA αυξηθούν'
)) {
    if (-not $productionText.Contains($requiredConclusion)) {
        throw "Missing evidence-based WD retired-block guidance: $requiredConclusion"
    }
}

# A generic B1 must never be silently presented as a trusted health percentage.
$unknownFixture = @(New-ParsedAttributeFixture -Id 0xB1 -Raw 0 -Current 100)
$unknownHealth = Get-AtaHealthEstimate -Profile 'Generic' -Attributes $unknownFixture
Assert-Equal $unknownHealth.IsTrusted $false 'Generic B1 is not trusted health'
Assert-Equal $unknownHealth.Percentage $null 'Generic B1 has no invented percentage'

# Live regression: ADATA SSD DM900 256GB-DL4 / R0427ANR from
# 192.168.1.242. The model is absent from smartmontools 7.5 drivedb, but ATA
# Device Statistics page 7 reports 53% used. openSeaChest 26.03 independently
# returned the same standardized value, corresponding to 47% remaining life.
$dm900StandardizedFixture = [PSCustomObject]@{
    ata_device_statistics = [PSCustomObject]@{
        pages = @(
            [PSCustomObject]@{
                number = 7
                name = 'Solid State Device Statistics'
                table = @(
                    [PSCustomObject]@{
                        offset = 8
                        name = 'Percentage Used Endurance Indicator'
                        value = 53
                        flags = [PSCustomObject]@{ valid = $true }
                    }
                )
            }
        )
    }
}
$dm900StandardizedHealth = Get-AtaStandardizedEnduranceEstimate -SmartData $dm900StandardizedFixture
Assert-Equal $dm900StandardizedHealth.IsTrusted $true 'DM900 standardized endurance trust'
Assert-Equal $dm900StandardizedHealth.UsedPercentage 53 'DM900 standardized used endurance'
Assert-Equal $dm900StandardizedHealth.Percentage 47 'DM900 standardized remaining life'
Assert-Equal $dm900StandardizedHealth.MetricLabel 'Life' 'DM900 standardized metric label'

$dm900Ids = @(0x01, 0x05, 0x09, 0x0C, 0x94, 0x95, 0x96, 0x97, 0x9F, 0xA0, 0xA1, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7, 0xA8, 0xA9, 0xB1, 0xB5, 0xB6, 0xC0, 0xC2, 0xC3, 0xC4, 0xC7, 0xE8, 0xF1, 0xF2, 0xF5)
$dm900ProfileFixture = @($dm900Ids | ForEach-Object {
    New-JsonAttributeFixture -Id $_ -Raw $(if ($_ -eq 0xA9) { 47 } else { 0 })
})
$dm900Profile = Get-AtaTelemetryProfile -Model 'ADATA SSD DM900 256GB-DL4' -Firmware 'R0427ANR' -Attributes $dm900ProfileFixture
Assert-Equal $dm900Profile 'SiliconMotionOEM' 'DM900 classified by SM2258-family attribute layout'
Assert-Equal (Get-AttributeName 0x94 $dm900Profile) 'SLC Total Erase Count' 'DM900 SLC erase mapping'
Assert-Equal (Get-AttributeName 0xF5 $dm900Profile) 'TLC Writes (32 MiB)' 'DM900 internal write-unit mapping'

$dm900TransferFixture = @(
    New-ParsedAttributeFixture -Id 0xF1 -Raw 1380758
    New-ParsedAttributeFixture -Id 0xF2 -Raw 1006173
    New-ParsedAttributeFixture -Id 0xF5 -Raw 6831576
)
$dm900Transfers = Get-AtaDataTransferEstimate -Profile $dm900Profile -Attributes $dm900TransferFixture
Assert-Equal $dm900Transfers.IsSupported $true 'DM900 lifetime data totals are supported by controller profile'
Assert-Equal $dm900Transfers.HostReadsGiB 31442.91 'DM900 F2 host reads conversion'
Assert-Equal $dm900Transfers.HostWritesGiB 43148.69 'DM900 F1 host writes conversion'
Assert-Equal $dm900Transfers.NandWritesGiB 213486.75 'DM900 F5 NAND writes conversion'
Assert-Equal $dm900Transfers.WriteAmplification 4.95 'DM900 lifetime write amplification'

$unknownTransfers = Get-AtaDataTransferEstimate -Profile 'Generic' -Attributes $dm900TransferFixture
Assert-Equal $unknownTransfers.IsSupported $false 'Unknown counter units remain unsupported'
Assert-Equal $unknownTransfers.HostWritesGiB $null 'Unknown counter units are not guessed'

$beyondRatingFixture = [PSCustomObject]@{
    ata_device_statistics = [PSCustomObject]@{
        pages = @([PSCustomObject]@{
            number = 7
            table = @([PSCustomObject]@{
                offset = 8
                value = 120
                flags = [PSCustomObject]@{ valid = $true }
            })
        })
    }
}
$beyondRatingHealth = Get-AtaStandardizedEnduranceEstimate -SmartData $beyondRatingFixture
Assert-Equal $beyondRatingHealth.IsTrusted $true 'Endurance above rating remains valid evidence'
Assert-Equal $beyondRatingHealth.UsedPercentage 120 'Used endurance above 100 is preserved'
Assert-Equal $beyondRatingHealth.Percentage 0 'Remaining life is clamped, not wrapped'

$invalidStandardizedFixture = [PSCustomObject]@{
    ata_device_statistics = [PSCustomObject]@{
        pages = @([PSCustomObject]@{
            number = 7
            table = @([PSCustomObject]@{
                offset = 8
                value = 53
                flags = [PSCustomObject]@{ valid = $false }
            })
        })
    }
    in_smartctl_database = $false
    endurance_used = [PSCustomObject]@{ current_percent = 53 }
}
$invalidStandardizedHealth = Get-AtaStandardizedEnduranceEstimate -SmartData $invalidStandardizedFixture
Assert-Equal $invalidStandardizedHealth.IsTrusted $false 'Invalid page-7 evidence is not replaced by a heuristic top-level value'
Assert-Equal $invalidStandardizedHealth.Percentage $null 'Invalid standardized endurance does not become zero'

# A common smartctl endurance value is accepted only when smartctl confirms that
# its interpretation came from a matching drivedb entry.
$databaseEnduranceFixture = [PSCustomObject]@{
    in_smartctl_database = $true
    endurance_used = [PSCustomObject]@{ current_percent = 53 }
}
$databaseHealth = Get-AtaSmartctlDatabaseEnduranceEstimate -SmartData $databaseEnduranceFixture
Assert-Equal $databaseHealth.IsTrusted $true 'Matched smartmontools database endurance trust'
Assert-Equal $databaseHealth.Percentage 47 'Matched smartmontools database remaining life'
Assert-Equal $databaseHealth.UsedPercentage 53 'Matched smartmontools database used endurance'

$unmatchedDatabaseHealth = Get-AtaSmartctlDatabaseEnduranceEstimate -SmartData $invalidStandardizedFixture
Assert-Equal $unmatchedDatabaseHealth.IsTrusted $false 'Unmatched common smartctl endurance remains untrusted'

$windowsWearHealth = Get-WindowsStorageWearEstimate -ReliabilityCounter ([PSCustomObject]@{ Wear = 53 })
Assert-Equal $windowsWearHealth.IsTrusted $true 'Windows Storage wear trust'
Assert-Equal $windowsWearHealth.Percentage 47 'Windows Storage wear converts to remaining life'

$unknownWindowsWear = Get-WindowsStorageWearEstimate -ReliabilityCounter ([PSCustomObject]@{ Wear = 255 })
Assert-Equal $unknownWindowsWear.IsTrusted $false 'Windows unknown wear sentinel is rejected'
Assert-Equal $unknownWindowsWear.Percentage $null 'Windows unknown wear never becomes zero life'

$defaultWindowsWear = Get-WindowsStorageWearEstimate -ReliabilityCounter ([PSCustomObject]@{ Wear = 0 })
Assert-Equal $defaultWindowsWear.IsTrusted $false 'Windows zero wear fallback is ambiguous and rejected'
Assert-Equal $defaultWindowsWear.Percentage $null 'Windows default zero wear never becomes invented 100 percent life'

$combinedStandardHealth = Get-AtaLifeEstimate -SmartData $dm900StandardizedFixture -Profile 'Generic' -Attributes @() -ReliabilityCounter ([PSCustomObject]@{ Wear = 90 })
Assert-Equal $combinedStandardHealth.Percentage 47 'Standard ATA evidence wins over fallback readings'
Assert-Equal $combinedStandardHealth.Source 'ATA Device Statistics: Percentage Used Endurance (53% used)' 'Standard ATA source remains explicit'

$combinedDatabaseHealth = Get-AtaLifeEstimate -SmartData $databaseEnduranceFixture -Profile 'Generic' -Attributes @() -ReliabilityCounter $null
Assert-Equal $combinedDatabaseHealth.Percentage 47 'Matched smartmontools database is a generic life source'

$combinedWindowsHealth = Get-AtaLifeEstimate -SmartData $invalidStandardizedFixture -Profile 'Generic' -Attributes @() -ReliabilityCounter ([PSCustomObject]@{ Wear = 53 })
Assert-Equal $combinedWindowsHealth.Percentage 47 'Windows wear is used when ATA evidence is unavailable'

$unsupportedHealth = Get-AtaLifeEstimate -SmartData $invalidStandardizedFixture -Profile 'Generic' -Attributes @() -ReliabilityCounter $null
Assert-Equal $unsupportedHealth.IsTrusted $false 'Missing evidence remains binary unsupported'
Assert-Equal $unsupportedHealth.Percentage $null 'Unsupported SSD has no invented health value'

Assert-Equal (Test-SmartctlAtaLifeEvidence -Payload $dm900StandardizedFixture) $true 'Collector detects valid standardized ATA life'
Assert-Equal (Test-SmartctlAtaLifeEvidence -Payload $databaseEnduranceFixture) $true 'Collector detects matched database life'
Assert-Equal (Test-SmartctlAtaLifeEvidence -Payload $invalidStandardizedFixture) $false 'Collector rejects invalid unmatched endurance'

$ataSsdArguments = @(Get-SmartctlHealthArguments -Device '/dev/pd0' -RequestAtaSsdStatistics)
$nvmeArguments = @(Get-SmartctlHealthArguments -Device '/dev/pd1')
$bridgeArguments = @(Get-SmartctlHealthArguments -Device '/dev/sda' -DeviceType 'sat' -RequestAtaSsdStatistics)
Assert-Equal ($ataSsdArguments -join ' ') '-a -l ssd /dev/pd0 --json' 'ATA SSD requests only standardized SSD statistics'
Assert-Equal ($nvmeArguments -join ' ') '-a /dev/pd1 --json' 'NVMe does not receive ATA-only log option'
Assert-Equal ($bridgeArguments -join ' ') '-a -l ssd -d sat /dev/sda --json' 'ATA bridge preserves type and standardized SSD statistics'

Write-Host 'PASS: ATA controller profile and health-source regression fixtures.' -ForegroundColor Green
