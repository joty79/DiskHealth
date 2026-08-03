[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'DiskHealth.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
    throw ($parseErrors | Format-List | Out-String)
}

function Get-TestFunctionText {
    param([Parameter(Mandatory)][string]$Name)

    $functionAst = $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
    }, $true) | Select-Object -First 1
    if (-not $functionAst) { throw "Missing performance helper: $Name" }
    return $functionAst.Extent.Text
}

foreach ($name in @(
    'Add-DiskHealthPerformanceRecord'
    'Start-DiskHealthPerformanceStage'
    'Complete-DiskHealthPerformanceStage'
    'Get-DiskHealthPerformanceErrorCategory'
    'Write-DiskHealthBenchmarkLine'
    'Save-DiskHealthPerformanceReport'
)) {
    Invoke-Expression (Get-TestFunctionText -Name $name)
}

$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) "DiskHealthPerformance-$PID-$([guid]::NewGuid().ToString('N'))"
$null = New-Item -ItemType Directory -Path $temporaryRoot -Force
try {
    $runId = [guid]::NewGuid().ToString('N')
    $script:DiskHealthPerformanceContext = [PSCustomObject]@{
        RunId        = $runId
        StartedUtc   = [datetime]::UtcNow
        Watch        = [System.Diagnostics.Stopwatch]::StartNew()
        Records      = [System.Collections.Generic.List[object]]::new()
        NextSequence = 0
        LogPath      = Join-Path $temporaryRoot 'performance.jsonl'
        SummaryPath  = Join-Path $temporaryRoot 'performance_summary.txt'
        Finalized    = $false
    }
    $script:DiskHealthBenchmarkEnabled = $true
    $script:DiskHealthBenchmarkLogPath = ''

    $slowToken = Start-DiskHealthPerformanceStage -Stage 'Fixture.Slow' -ParentStage 'Fixture'
    Start-Sleep -Milliseconds 20
    Complete-DiskHealthPerformanceStage -Token $slowToken -Status success -AttemptCount 1 -ResultCount 2

    $timeoutToken = Start-DiskHealthPerformanceStage -Stage 'Fixture.Timeout' -ParentStage 'Fixture'
    Start-Sleep -Milliseconds 2
    Complete-DiskHealthPerformanceStage -Token $timeoutToken -Status timeout -AttemptCount 3 -ResultCount 0 -ErrorCategory 'Timeout:C:\customer\private.txt'

    $secretPassword = 'fixture-password-never-log'
    $customerFile = 'Customer Name - private report.txt'
    Write-DiskHealthBenchmarkLine -Phase 'Fixture.LegacyBridge' -Milliseconds 1 -Details "password=$secretPassword file=$customerFile SecureString PSCredential"

    $errorCategory = Get-DiskHealthPerformanceErrorCategory ([System.InvalidOperationException]::new("$secretPassword $customerFile"))
    if ($errorCategory -ne 'InvalidOperation') {
        throw "Unexpected sanitized exception category: $errorCategory"
    }

    Save-DiskHealthPerformanceReport -Finalize

    if (-not (Test-Path -LiteralPath $script:DiskHealthPerformanceContext.LogPath -PathType Leaf)) {
        throw 'Structured JSONL performance log was not written.'
    }
    if (-not (Test-Path -LiteralPath $script:DiskHealthPerformanceContext.SummaryPath -PathType Leaf)) {
        throw 'Sorted performance summary was not written.'
    }

    $rawLog = Get-Content -LiteralPath $script:DiskHealthPerformanceContext.LogPath -Raw
    $rawSummary = Get-Content -LiteralPath $script:DiskHealthPerformanceContext.SummaryPath -Raw
    foreach ($forbidden in @($secretPassword, $customerFile, 'SecureString', 'PSCredential', 'C:\customer\private.txt')) {
        if ($rawLog.Contains($forbidden) -or $rawSummary.Contains($forbidden)) {
            throw "Performance output leaked forbidden fixture data: $forbidden"
        }
    }

    $rows = @(Get-Content -LiteralPath $script:DiskHealthPerformanceContext.LogPath | ForEach-Object { $_ | ConvertFrom-Json })
    if ($rows.Count -lt 4) { throw "Expected at least four structured rows, got $($rows.Count)." }
    foreach ($row in $rows) {
        foreach ($property in @('RunId', 'Stage', 'ParentStage', 'StartUtc', 'EndUtc', 'DurationMs', 'Status', 'AttemptCount', 'ResultCount', 'ErrorCategory')) {
            if (-not $row.PSObject.Properties[$property]) { throw "Missing structured property '$property'." }
        }
        if ($row.RunId -ne $runId) { throw 'Correlation ID changed within one performance run.' }
        if ([double]$row.DurationMs -lt 0) { throw 'A monotonic duration became negative.' }
        if ([datetime]$row.EndUtc -lt [datetime]$row.StartUtc) { throw 'A stage end UTC precedes its start UTC.' }
    }

    $timeoutRow = $rows | Where-Object Stage -eq 'Fixture.Timeout' | Select-Object -First 1
    if ($null -eq $timeoutRow -or $timeoutRow.Status -ne 'timeout' -or $timeoutRow.AttemptCount -ne 3 -or $timeoutRow.ErrorCategory -ne 'TimeoutCcustomerprivate.txt') {
        throw 'Timeout/failure metadata was not preserved and sanitized.'
    }
    $slowPosition = $rawSummary.IndexOf('Fixture > Fixture.Slow', [System.StringComparison]::Ordinal)
    $fastPosition = $rawSummary.IndexOf('Fixture.LegacyBridge', [System.StringComparison]::Ordinal)
    if ($slowPosition -lt 0 -or $fastPosition -lt 0 -or $slowPosition -gt $fastPosition) {
        throw 'Performance summary is not sorted by descending duration.'
    }

    $source = Get-Content -LiteralPath $scriptPath -Raw
    foreach ($requiredStage in @(
        'Network.SelectionToFirstProgress'
        'History.NetworkIdentity'
        'History.TargetCatalog'
        'History.SelectedTargetResolve'
        'Discovery.WSDiscovery'
        'Discovery.Tcp5985And445Probe'
        'Discovery.NameResolution.AsyncReverseDns'
        'Discovery.NameResolution.NetBIOS'
        'TargetMenu.FirstFrame'
        'TrustedHosts.ExactTargetPreparation'
        'Credential.DPAPILookup'
        'WinRM.TcpPreflight.Attempt'
        'Collector.SmartctlScanOpen'
        'Collector.PnPTelemetry.Disk'
        'Evaluation.HealthParsing'
        'Report.FirstRenderedFrame'
    )) {
        if (-not $source.Contains($requiredStage)) { throw "Missing required performance stage marker: $requiredStage" }
    }
    if (-not $source.Contains('-DiagnosticsInMemoryOnly:$script:DiskHealthBenchmarkEnabled')) {
        throw 'DiskHealth does not suppress the legacy module-local diagnostics file.'
    }
    $savedTargetAst = $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-DiskHealthSavedWinRMTargets'
    }, $true) | Select-Object -First 1
    $savedTargetSource = if ($savedTargetAst) { $savedTargetAst.Extent.Text } else { '' }
    if (-not $savedTargetSource.Contains('Get-WinRMTargetCatalog') -or $savedTargetSource.Contains('Resolve-DiskHealthSavedWinRMTargetsParallel')) {
        throw 'Initial saved-target loading must be local-only and must not bulk-validate history.'
    }
    if (-not $savedTargetSource.Contains('$catalog.Diagnostics')) {
        throw 'Target-catalog sub-stage diagnostics are not forwarded to the DiskHealth structured logger.'
    }
    $selectedTargetAst = $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-DiscoveredWinRMTarget'
    }, $true) | Select-Object -First 1
    $selectedTargetSource = if ($selectedTargetAst) { $selectedTargetAst.Extent.Text } else { '' }
    if (-not $selectedTargetSource.Contains('Resolve-WinRMHistoryTargetAddress') -or -not $selectedTargetSource.Contains('-IncludeDiagnostics') -or -not $selectedTargetSource.Contains('$resolution.Diagnostics')) {
        throw 'Selected saved-target validation and its canonical sub-stage diagnostics are missing.'
    }

    $gitIgnore = Get-Content -LiteralPath (Join-Path $repoRoot '.gitignore') -Raw
    if ($gitIgnore -notmatch '(?m)^diagnostic_reports/performance/$') {
        throw 'The generated performance report path is not Git-ignored.'
    }
} finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        $resolvedTemporaryRoot = [System.IO.Path]::GetFullPath($temporaryRoot)
        $resolvedSystemTemp = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
        if ($resolvedTemporaryRoot.StartsWith($resolvedSystemTemp, [System.StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $resolvedTemporaryRoot -Recurse -Force
        }
    }
}

Write-Host 'PASS: structured performance instrumentation, failures/timeouts and secret guards.' -ForegroundColor Green
