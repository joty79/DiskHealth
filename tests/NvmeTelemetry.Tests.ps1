[CmdletBinding()]
param()

$scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'DiskHealth.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors) {
    throw "Production script has parser errors: $($parseErrors -join '; ')"
}

$requiredFunctions = @('ConvertTo-NvmeCounter', 'Get-NvmeMediaErrorAssessment')
foreach ($name in $requiredFunctions) {
    $functionAst = $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true) | Select-Object -First 1

    if (-not $functionAst) {
        throw "Required production function not found: $name"
    }
    Invoke-Expression $functionAst.Extent.Text
}

function Assert-Equal {
    param($Actual, $Expected, [string]$Label)
    if ($Actual -ne $Expected) {
        throw "$Label failed. Expected '$Expected', got '$Actual'."
    }
}

$fixtureValue = ConvertTo-NvmeCounter -Value 0 -StringValue '36804482607263454645452800'
$fixtureAssessment = Get-NvmeMediaErrorAssessment -MediaErrors $fixtureValue -ErrorLogEntries 0 -CriticalWarning 0
Assert-Equal $fixtureValue.ToString() '36804482607263454645452800' 'Full 128-bit fixture preservation'
Assert-Equal $fixtureAssessment.Low64.ToString() '0' 'Fixture low 64 bits'
Assert-Equal $fixtureAssessment.Upper64.ToString() '1995175' 'Fixture upper 64 bits'
Assert-Equal $fixtureAssessment.IsStructuralAnomaly $true 'Fixture anomaly classification'

$realErrorValue = ConvertTo-NvmeCounter -Value 12
$realErrorAssessment = Get-NvmeMediaErrorAssessment -MediaErrors $realErrorValue -ErrorLogEntries 3 -CriticalWarning 0
Assert-Equal $realErrorAssessment.Low64.ToString() '12' 'Ordinary counter low 64 bits'
Assert-Equal $realErrorAssessment.IsStructuralAnomaly $false 'Ordinary counter classification'

$criticalFixture = Get-NvmeMediaErrorAssessment -MediaErrors $fixtureValue -ErrorLogEntries 0 -CriticalWarning 1
Assert-Equal $criticalFixture.IsStructuralAnomaly $false 'Critical-warning fixture is not suppressed as telemetry anomaly'

$invalidRejected = $false
try {
    $null = ConvertTo-NvmeCounter -Value 'not-a-counter'
} catch {
    $invalidRejected = $true
}
Assert-Equal $invalidRejected $true 'Invalid counters are rejected instead of rewritten to zero'

Write-Host 'PASS: NVMe 128-bit telemetry regression fixtures.' -ForegroundColor Green
