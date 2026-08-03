<#
.SYNOPSIS
    Διαγνωστικό Υγείας Δίσκων (Disk Health Diagnostics) μέσω smartctl, WMI/CIM ή CDI Reports.
.DESCRIPTION
    Ανακτά στοιχεία δίσκων, S.M.A.R.T. δεδομένα και Reliability Counters natively.
    Χρησιμοποιεί κατά προτίμηση το smartctl (αν είναι εγκατεστημένο) για πλήρη NVMe/SATA διαγνωστικά.
    Υποστηρίζει επίσης την εισαγωγή και ανάλυση αποθηκευμένων CrystalDiskInfo txt reports.
    Παράγει ένα δομημένο report με emojis και χρώματα συμβατό με το Windows Terminal.
.PARAMETER ComputerName
    Το όνομα ή η IP διεύθυνση του απομακρυσμένου υπολογιστή.
.PARAMETER Username
    Το όνομα χρήστη για τη σύνδεση WinRM.
.PARAMETER Password
    Ο κωδικός πρόσβασης για τη σύνδεση WinRM (κενός από προεπιλογή).
.PARAMETER FilePath
    Τοπικό μονοπάτι σε ένα CrystalDiskInfo txt report για offline ανάλυση.
.PARAMETER Discover
    Εντοπίζει υπολογιστές στο τοπικό δίκτυο και εμφανίζει selector πριν από τη σύνδεση WinRM.
.PARAMETER DiscoveryStateRoot
    Προαιρετικό absolute path για network-scoped discovery history/cache.
.PARAMETER Benchmark
    Καταγράφει structured discovery, WinRM, collector και rendering timings στο Git-ignored diagnostic_reports\performance.
#>
[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingInvokeExpression', '', Justification = 'Loads the pinned canonical PowerShell TUI blueprint into script scope so its state and ANSI palette are shared by DiskHealth.')]
param(
    [string]$ComputerName = "localhost",
    [string]$Username = "user",
    [AllowEmptyString()]
    [string]$Password = "",
    [AllowEmptyString()]
    [string]$FilePath = "",
    [switch]$InstallSmartctl,
    [switch]$Discover,
    [AllowEmptyString()]
    [string]$DiscoveryStateRoot = "",
    [switch]$Benchmark,
    [Parameter(DontShow)]
    [System.Management.Automation.PSCredential]$Credential,
    [Parameter(DontShow)]
    [AllowEmptyString()]
    [string]$ConnectionNetworkId = "",
    [Parameter(DontShow)]
    [AllowEmptyString()]
    [string]$ConnectionDisplayName = "",
    [Parameter(DontShow)]
    [AllowEmptyString()]
    [string]$ConnectionMacAddress = "",
    [Parameter(DontShow)]
    [switch]$NoUI,
    [Parameter(DontShow)]
    [switch]$EmbeddedRemote,
    [Parameter(DontShow)]
    [switch]$CredentialFromSavedProfile,
    [Parameter(DontShow)]
    [AllowNull()]
    $PerformanceContext
)

$script:DiskHealthInvocationStartUtc = [datetime]::UtcNow
$script:DiskHealthInvocationWatch = [System.Diagnostics.Stopwatch]::StartNew()

# 1. Καθορισμός Χρωμάτων (Console Colors)
$Cyan = "Cyan"
$Yellow = "Yellow"
$Red = "Red"
$Green = "Green"
$White = "White"
$Gray = "DarkGray"
$script:DiskHealthPerformanceContext = $PerformanceContext
$script:DiskHealthBenchmarkEnabled = [bool]$Benchmark -or $null -ne $PerformanceContext
$script:DiskHealthBenchmarkLogPath = ""
$script:IsHomeLauncher = (
    -not $PSBoundParameters.ContainsKey('ComputerName') -and
    -not $PSBoundParameters.ContainsKey('FilePath') -and
    -not $PSBoundParameters.ContainsKey('Discover') -and
    -not $EmbeddedRemote
)

$diskHealthTuiBlueprintPath = Join-Path -Path $PSScriptRoot -ChildPath 'PS_UI_Blueprint.psm1'
$diskHealthTuiReceiptPath = Join-Path -Path $PSScriptRoot -ChildPath 'PS_UI_Blueprint.sha256'
if (-not (Test-Path -LiteralPath $diskHealthTuiBlueprintPath -PathType Leaf) -or -not (Test-Path -LiteralPath $diskHealthTuiReceiptPath -PathType Leaf)) {
    throw '⚠️⚠️⚠️ NEED TOOL: Missing the vendored canonical PowerShell TUI blueprint or its SHA-256 receipt.'
}
$diskHealthExpectedTuiHash = (Get-Content -Raw -LiteralPath $diskHealthTuiReceiptPath).Trim()
$diskHealthActualTuiHash = (Get-FileHash -LiteralPath $diskHealthTuiBlueprintPath -Algorithm SHA256).Hash
if ($diskHealthActualTuiHash -ne $diskHealthExpectedTuiHash) {
    throw "⚠️⚠️⚠️ TUI DRIFT: Expected=$diskHealthExpectedTuiHash Actual=$diskHealthActualTuiHash"
}
Invoke-Expression (Get-Content -Raw -LiteralPath $diskHealthTuiBlueprintPath)
$script:DiskHealthInvocationWatch.Stop()
$script:DiskHealthInvocationMetric = [PSCustomObject]@{
    StartUtc   = $script:DiskHealthInvocationStartUtc
    EndUtc     = [datetime]::UtcNow
    DurationMs = $script:DiskHealthInvocationWatch.Elapsed.TotalMilliseconds
}

function Get-DiskHealthLocalStateRoot {
    param(
        [AllowEmptyString()]
        [string]$StateRoot = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($StateRoot)) {
        return [Environment]::ExpandEnvironmentVariables($StateRoot)
    }

    $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if ([string]::IsNullOrWhiteSpace($localAppData)) {
        $localAppData = Join-Path -Path $env:USERPROFILE -ChildPath 'AppData\Local'
    }
    return Join-Path -Path $localAppData -ChildPath 'DiskHealth'
}

function Get-DiskHealthStoredCredential {
    param(
        [Parameter(Mandatory)][string]$NetworkId,
        [Parameter(Mandatory)][string[]]$ComputerNames,
        [AllowEmptyString()][string]$StateRoot = ''
    )

    if ([string]::IsNullOrWhiteSpace($NetworkId)) { return $null }
    return Get-WinRMCredentialProfile `
        -ComputerName $ComputerNames `
        -Scope $NetworkId `
        -StateRoot $StateRoot
}

function Save-DiskHealthStoredCredential {
    param(
        [Parameter(Mandatory)][string]$NetworkId,
        [Parameter(Mandatory)][string[]]$ComputerNames,
        [Parameter(Mandatory)][System.Management.Automation.PSCredential]$CredentialToStore,
        [AllowEmptyString()][string]$StateRoot = ''
    )

    if ([string]::IsNullOrWhiteSpace($NetworkId) -or $null -eq $CredentialToStore) { return }
    Save-WinRMCredentialProfile `
        -ComputerName $ComputerNames `
        -Credential $CredentialToStore `
        -Scope $NetworkId `
        -StateRoot $StateRoot
}

function Remove-DiskHealthStoredCredential {
    param(
        [Parameter(Mandatory)][string]$NetworkId,
        [Parameter(Mandatory)][string[]]$ComputerNames,
        [AllowEmptyString()][string]$StateRoot = ''
    )

    if ([string]::IsNullOrWhiteSpace($NetworkId)) { return }
    Remove-WinRMCredentialProfile `
        -ComputerName $ComputerNames `
        -Scope $NetworkId `
        -StateRoot $StateRoot `
        -Confirm:$false
}

function New-DiskHealthPerformanceContext {
    $logRoot = Join-Path -Path $PSScriptRoot -ChildPath 'diagnostic_reports\performance'
    $null = New-Item -ItemType Directory -Path $logRoot -Force -ErrorAction Stop
    $runId = [guid]::NewGuid().ToString('N')
    $stamp = [datetime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
    $context = [PSCustomObject]@{
        RunId       = $runId
        StartedUtc  = [datetime]::UtcNow
        Watch       = [System.Diagnostics.Stopwatch]::StartNew()
        Records     = [System.Collections.Generic.List[object]]::new()
        NextSequence = 0
        LogPath     = Join-Path -Path $logRoot -ChildPath "performance_${stamp}_${runId}.jsonl"
        SummaryPath = Join-Path -Path $logRoot -ChildPath "performance_${stamp}_${runId}_summary.txt"
        Finalized   = $false
    }
    return $context
}

function Add-DiskHealthPerformanceRecord {
    param(
        [Parameter(Mandatory)][string]$Stage,
        [AllowEmptyString()][string]$ParentStage = '',
        [Parameter(Mandatory)][datetime]$StartUtc,
        [Parameter(Mandatory)][datetime]$EndUtc,
        [Parameter(Mandatory)][double]$DurationMs,
        [ValidateSet('success', 'failure', 'timeout', 'skipped')][string]$Status = 'success',
        [AllowNull()]$AttemptCount = $null,
        [AllowNull()]$ResultCount = $null,
        [AllowEmptyString()][string]$ErrorCategory = ''
    )

    $context = $script:DiskHealthPerformanceContext
    if ($null -eq $context) { return }
    $safeCategory = if ([string]::IsNullOrWhiteSpace($ErrorCategory)) {
        ''
    } else {
        ([string]$ErrorCategory -replace '[^A-Za-z0-9_.-]', '').Substring(0, [Math]::Min(64, ([string]$ErrorCategory -replace '[^A-Za-z0-9_.-]', '').Length))
    }
    $context.NextSequence = [int]$context.NextSequence + 1
    $context.Records.Add([PSCustomObject][ordered]@{
        SchemaVersion = 1
        RunId = [string]$context.RunId
        Sequence = [int]$context.NextSequence
        Stage = $Stage
        ParentStage = $ParentStage
        StartUtc = $StartUtc.ToUniversalTime().ToString('o')
        EndUtc = $EndUtc.ToUniversalTime().ToString('o')
        DurationMs = [Math]::Round([Math]::Max(0, $DurationMs), 3)
        Status = $Status
        AttemptCount = $AttemptCount
        ResultCount = $ResultCount
        ErrorCategory = $safeCategory
    })
}

function Start-DiskHealthPerformanceStage {
    param(
        [Parameter(Mandatory)][string]$Stage,
        [AllowEmptyString()][string]$ParentStage = ''
    )

    if ($null -eq $script:DiskHealthPerformanceContext) { return $null }
    return [PSCustomObject]@{
        Stage       = $Stage
        ParentStage = $ParentStage
        StartUtc    = [datetime]::UtcNow
        Watch       = [System.Diagnostics.Stopwatch]::StartNew()
    }
}

function Complete-DiskHealthPerformanceStage {
    param(
        [AllowNull()]$Token,
        [ValidateSet('success', 'failure', 'timeout', 'skipped')][string]$Status = 'success',
        [AllowNull()]$AttemptCount = $null,
        [AllowNull()]$ResultCount = $null,
        [AllowEmptyString()][string]$ErrorCategory = ''
    )

    if ($null -eq $Token -or $null -eq $script:DiskHealthPerformanceContext) { return }
    $Token.Watch.Stop()
    Add-DiskHealthPerformanceRecord `
        -Stage $Token.Stage `
        -ParentStage $Token.ParentStage `
        -StartUtc $Token.StartUtc `
        -EndUtc ([datetime]::UtcNow) `
        -DurationMs $Token.Watch.Elapsed.TotalMilliseconds `
        -Status $Status `
        -AttemptCount $AttemptCount `
        -ResultCount $ResultCount `
        -ErrorCategory $ErrorCategory
}

function Get-DiskHealthPerformanceErrorCategory {
    param([AllowNull()]$ErrorObject)

    if ($null -eq $ErrorObject) { return '' }
    try {
        if (Get-Command Get-WinRMConnectionErrorCategory -ErrorAction SilentlyContinue) {
            $category = Get-WinRMConnectionErrorCategory -ErrorObject $ErrorObject
            if (-not [string]::IsNullOrWhiteSpace($category) -and $category -ne 'Unknown') { return $category }
        }
    } catch {}
    $exception = if ($ErrorObject -is [System.Management.Automation.ErrorRecord]) {
        $ErrorObject.Exception
    } elseif ($ErrorObject.PSObject.Properties['Exception']) {
        $ErrorObject.Exception
    } else {
        $ErrorObject
    }
    if ($exception -is [System.TimeoutException]) { return 'Timeout' }
    if ($exception -is [System.UnauthorizedAccessException]) { return 'PermissionDenied' }
    if ($exception -is [System.OperationCanceledException]) { return 'Canceled' }
    $typeName = if ($null -ne $exception) { $exception.GetType().Name } else { 'Unknown' }
    return ($typeName -replace 'Exception$', '')
}

function Write-DiskHealthBenchmarkLine {
    param(
        [Parameter(Mandatory)][string]$Phase,
        [Parameter(Mandatory)][double]$Milliseconds,
        [AllowEmptyString()][string]$Details = ''
    )

    if (-not $script:DiskHealthBenchmarkEnabled -or $null -eq $script:DiskHealthPerformanceContext) { return }
    $endUtc = [datetime]::UtcNow
    $parentStage = if ($Phase -like 'Collector.*') { 'Collector.Total' } elseif ($Phase -like 'WinRM.*') { 'WinRM.Total' } elseif ($Phase -like 'Discovery.*') { 'Network.Discovery' } else { '' }
    Add-DiskHealthPerformanceRecord `
        -Stage $Phase `
        -ParentStage $parentStage `
        -StartUtc $endUtc.AddMilliseconds(-[Math]::Max(0, $Milliseconds)) `
        -EndUtc $endUtc `
        -DurationMs $Milliseconds
}

function Save-DiskHealthPerformanceReport {
    param([switch]$Finalize, [switch]$ShowSummary)

    $context = $script:DiskHealthPerformanceContext
    if ($null -eq $context) { return }
    if ($Finalize -and -not $context.Finalized) {
        $context.Watch.Stop()
        Add-DiskHealthPerformanceRecord `
            -Stage 'Run.Total' `
            -StartUtc $context.StartedUtc `
            -EndUtc ([datetime]::UtcNow) `
            -DurationMs $context.Watch.Elapsed.TotalMilliseconds `
            -Status 'success' `
            -ResultCount $context.Records.Count
        $context.Finalized = $true
    }

    $jsonLines = @($context.Records | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 4 })
    $jsonLines | Set-Content -LiteralPath $context.LogPath -Encoding UTF8
    $totalMs = if ($context.Finalized) { [double]$context.Watch.Elapsed.TotalMilliseconds } else { [double]$context.Watch.Elapsed.TotalMilliseconds }
    $summary = [System.Collections.Generic.List[string]]::new()
    $summary.Add("DiskHealth performance summary | Run $($context.RunId)")
    $summary.Add("Total: $([Math]::Round($totalMs, 1)) ms | Records: $($context.Records.Count)")
    $summary.Add('')
    $summary.Add(('{0,-46} {1,11} {2,8} {3,-8}' -f 'Stage', 'Duration', 'Percent', 'Status'))
    foreach ($row in @($context.Records | Where-Object { $_.Stage -ne 'Run.Total' } | Sort-Object DurationMs -Descending)) {
        $percent = if ($totalMs -gt 0) { 100.0 * [double]$row.DurationMs / $totalMs } else { 0 }
        $stageText = if ([string]::IsNullOrWhiteSpace($row.ParentStage)) { $row.Stage } else { "$($row.ParentStage) > $($row.Stage)" }
        if ($stageText.Length -gt 46) { $stageText = $stageText.Substring(0, 43) + '...' }
        $summary.Add(('{0,-46} {1,9:N1}ms {2,7:N1}% {3,-8}' -f $stageText, $row.DurationMs, $percent, $row.Status))
    }
    $summary.Add('')
    $summary.Add("Structured log: $($context.LogPath)")
    $summary | Set-Content -LiteralPath $context.SummaryPath -Encoding UTF8
    $script:DiskHealthBenchmarkLogPath = $context.LogPath
    if ($ShowSummary) {
        [Console]::WriteLine(($summary -join [Environment]::NewLine))
    }
}

function Show-DiskHealthPerformanceProgress {
    param(
        [Parameter(Mandatory)][string]$Stage,
        [AllowEmptyString()][string]$Message = '',
        [switch]$ForceClear
    )

    if ($null -eq $script:DiskHealthPerformanceContext) { return }
    $elapsedSeconds = $script:DiskHealthPerformanceContext.Watch.Elapsed.TotalSeconds
    if ($NoUI -or [Console]::IsOutputRedirected) {
        [Console]::WriteLine("[DiskHealth] $Stage | elapsed $($elapsedSeconds.ToString('N1'))s")
        return
    }
    try {
        $width = Get-UiWidth
        $frame = New-UiFrame
        Add-UiFrameBanner -Frame $frame -Title '💾 DISKHEALTH PERFORMANCE' -Subtitle "Run $($script:DiskHealthPerformanceContext.RunId.Substring(0, 8))" -Width $width
        Add-UiFrameLine -Frame $frame
        Add-UiFrameLine -Frame $frame -Text "$($_C.H1)  Stage: $Stage$($_C.Reset)$($_C.EraseLn)"
        Add-UiFrameLine -Frame $frame -Text "$($_C.Dim)  Elapsed: $($elapsedSeconds.ToString('N1')) s$($_C.Reset)$($_C.EraseLn)"
        if (-not [string]::IsNullOrWhiteSpace($Message)) {
            Add-UiFrameLine -Frame $frame -Text "$($_C.Dim)  $Message$($_C.Reset)$($_C.EraseLn)"
        }
        Add-UiFrameLine -Frame $frame
        Add-UiFrameLine -Frame $frame -Text "$($_C.Dim)  Please wait. Current stage is still active.$($_C.Reset)$($_C.EraseLn)"
        Write-UiFrame -Frame $frame -ForceClear:$ForceClear
    } catch {
        [Console]::WriteLine("[DiskHealth] $Stage | elapsed $($elapsedSeconds.ToString('N1'))s")
    }
}

function Initialize-DiskHealthPerformance {
    if ($null -eq $script:DiskHealthPerformanceContext) {
        $script:DiskHealthPerformanceContext = New-DiskHealthPerformanceContext
    }
    $script:DiskHealthBenchmarkEnabled = $true
    if ($null -ne $script:DiskHealthInvocationMetric) {
        Add-DiskHealthPerformanceRecord `
            -Stage 'Initialization.TUIAsset' `
            -ParentStage 'Initialization' `
            -StartUtc $script:DiskHealthInvocationMetric.StartUtc `
            -EndUtc $script:DiskHealthInvocationMetric.EndUtc `
            -DurationMs $script:DiskHealthInvocationMetric.DurationMs `
            -Status 'success' `
            -ResultCount 1
        $script:DiskHealthInvocationMetric = $null
    }
}

if ($Benchmark -or $null -ne $PerformanceContext) {
    Initialize-DiskHealthPerformance
}

function Import-DiskHealthWinRMDiscovery {
    param([AllowEmptyString()][string]$StateRoot = '')

    $stageToken = Start-DiskHealthPerformanceStage -Stage 'Initialization.WinRMDiscovery' -ParentStage 'Initialization'
    $alreadyLoaded = $null -ne (Get-Module -Name WinRMDiscovery)
    $manifest = Join-Path -Path $PSScriptRoot -ChildPath '.assets\WinRMDiscovery\WinRMDiscovery.psd1'
    try {
        if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
            throw "Το WinRMDiscovery module δεν βρέθηκε: $manifest"
        }

        if (-not $alreadyLoaded) {
            Import-Module -Name $manifest -Force -ErrorAction Stop
        }
        if (-not [string]::IsNullOrWhiteSpace($StateRoot)) {
            Set-WinRMDiscoveryStateRoot -Path $StateRoot
        }
        Complete-DiskHealthPerformanceStage -Token $stageToken -Status $(if ($alreadyLoaded) { 'skipped' } else { 'success' }) -ResultCount 1
    } catch {
        Complete-DiskHealthPerformanceStage -Token $stageToken -Status failure -ErrorCategory (Get-DiskHealthPerformanceErrorCategory $_)
        throw
    }
}

function Import-DiskHealthWinRMConnection {
    $stageToken = Start-DiskHealthPerformanceStage -Stage 'Initialization.WinRMConnection' -ParentStage 'Initialization'
    $alreadyLoaded = $null -ne (Get-Module -Name WinRMConnection)
    $manifest = Join-Path -Path $PSScriptRoot -ChildPath '.assets\WinRMConnection\WinRMConnection.psd1'
    try {
        if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
            throw "Το WinRMConnection module δεν βρέθηκε: $manifest"
        }

        if (-not $alreadyLoaded) {
            Import-Module -Name $manifest -Force -ErrorAction Stop
        }
        Complete-DiskHealthPerformanceStage -Token $stageToken -Status $(if ($alreadyLoaded) { 'skipped' } else { 'success' }) -ResultCount 1
    } catch {
        Complete-DiskHealthPerformanceStage -Token $stageToken -Status failure -ErrorCategory (Get-DiskHealthPerformanceErrorCategory $_)
        throw
    }
}

function Import-DiskHealthWinRMWorkshop {
    $stageToken = Start-DiskHealthPerformanceStage -Stage 'Initialization.WinRMWorkshop' -ParentStage 'Initialization'
    $alreadyLoaded = $null -ne (Get-Module -Name WinRMWorkshop)
    $manifest = Join-Path -Path $PSScriptRoot -ChildPath '.assets\WinRMWorkshop\WinRMWorkshop.psd1'
    try {
        if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
            throw "Το WinRMWorkshop module δεν βρέθηκε: $manifest"
        }

        if (-not $alreadyLoaded) {
            Import-Module -Name $manifest -Force -ErrorAction Stop
        }
        Complete-DiskHealthPerformanceStage -Token $stageToken -Status $(if ($alreadyLoaded) { 'skipped' } else { 'success' }) -ResultCount 1
    } catch {
        Complete-DiskHealthPerformanceStage -Token $stageToken -Status failure -ErrorCategory (Get-DiskHealthPerformanceErrorCategory $_)
        throw
    }
}

function Write-DiskHealthWinRMWorkshopStatus {
    param([Parameter(Mandatory)]$Status)

    if ($null -eq $script:DiskHealthPerformanceContext) {
        $statusColor = if ($Status.State -eq 'Ready') { $Green } else { $Cyan }
        Write-Host "  🔐 $($Status.Message)" -ForegroundColor $statusColor
        return
    }
    Show-DiskHealthPerformanceProgress -Stage "TrustedHosts.$($Status.State)" -Message 'Exact-target preparation; no wildcard entries.'
}

function Write-DiskHealthWinRMConnectionStatus {
    param([Parameter(Mandatory)]$Status)

    if ($null -eq $script:DiskHealthPerformanceContext) {
        $statusColor = if ($Status.State -in @('AttemptFailed', 'Failed')) { $Yellow } elseif ($Status.State -eq 'Connected') { $Green } else { $Cyan }
        Write-Host "  🔌 $($Status.Message)" -ForegroundColor $statusColor
        return
    }
    if ($null -eq $script:DiskHealthConnectionStageTokens) {
        $script:DiskHealthConnectionStageTokens = @{}
    }
    $attempt = [int]$Status.Attempt
    $probeKey = "Tcp.$attempt"
    $sessionKey = "Session.$attempt"
    switch ([string]$Status.State) {
        'TcpProbe' {
            $script:DiskHealthConnectionStageTokens[$probeKey] = Start-DiskHealthPerformanceStage -Stage "WinRM.TcpPreflight.Attempt$attempt" -ParentStage 'WinRM.Connect'
        }
        'Connecting' {
            if ($script:DiskHealthConnectionStageTokens.ContainsKey($probeKey)) {
                Complete-DiskHealthPerformanceStage -Token $script:DiskHealthConnectionStageTokens[$probeKey] -Status success -AttemptCount $attempt -ResultCount 1
                $script:DiskHealthConnectionStageTokens.Remove($probeKey)
            }
            $script:DiskHealthConnectionStageTokens[$sessionKey] = Start-DiskHealthPerformanceStage -Stage "WinRM.PSSession.Attempt$attempt" -ParentStage 'WinRM.Connect'
        }
        'AttemptFailed' {
            $activeKey = if ($script:DiskHealthConnectionStageTokens.ContainsKey($sessionKey)) { $sessionKey } else { $probeKey }
            if ($script:DiskHealthConnectionStageTokens.ContainsKey($activeKey)) {
                $failedStatus = if ([string]$Status.Category -eq 'Timeout') { 'timeout' } else { 'failure' }
                Complete-DiskHealthPerformanceStage -Token $script:DiskHealthConnectionStageTokens[$activeKey] -Status $failedStatus -AttemptCount $attempt -ResultCount 0 -ErrorCategory ([string]$Status.Category)
                $script:DiskHealthConnectionStageTokens.Remove($activeKey)
            }
        }
        'Connected' {
            if ($script:DiskHealthConnectionStageTokens.ContainsKey($sessionKey)) {
                Complete-DiskHealthPerformanceStage -Token $script:DiskHealthConnectionStageTokens[$sessionKey] -Status success -AttemptCount $attempt -ResultCount 1
                $script:DiskHealthConnectionStageTokens.Remove($sessionKey)
            }
        }
    }
    Show-DiskHealthPerformanceProgress -Stage "WinRM.$($Status.State)" -Message "Bounded attempt $attempt/$($Status.MaxAttempts)."
}

function Get-MenuDisplayText {
    param(
        [Parameter(Mandatory)][string]$Text,
        [int]$ReservedColumns = 10
    )

    $windowWidth = 80
    try { $windowWidth = [Math]::Max(30, $Host.UI.RawUI.WindowSize.Width) } catch {}
    $maximumLength = [Math]::Max(20, $windowWidth - $ReservedColumns)
    if ($Text.Length -le $maximumLength) { return $Text }
    return $Text.Substring(0, $maximumLength - 3) + '...'
}

function Show-DiskHealthChoiceMenu {
    param(
        [Parameter(Mandatory)][string]$Title,
        [AllowEmptyString()][string]$Subtitle = '',
        [Parameter(Mandatory)][object[]]$Options,
        [int]$DefaultIndex = 0,
        [AllowNull()]$EscapeValue = $null,
        [ValidateSet('Back', 'Exit')][string]$EscapeMode = 'Back',
        [AllowEmptyString()][string]$PerformanceStage = '',
        [AllowEmptyString()][string]$PerformanceParentStage = '',
        [Parameter(DontShow)][AllowNull()][scriptblock]$ReadKey
    )

    if ($Options.Count -eq 0) { return $EscapeValue }
    $firstFrameToken = if ([string]::IsNullOrWhiteSpace($PerformanceStage)) { $null } else { Start-DiskHealthPerformanceStage -Stage $PerformanceStage -ParentStage $PerformanceParentStage }
    $selectedIndex = [Math]::Max(0, [Math]::Min($DefaultIndex, $Options.Count - 1))
    Initialize-TuiHost
    try {
        while ($true) {
            Lock-ViewportToWindow
            try {
                $width = Get-UiWidth
                $height = $Host.UI.RawUI.WindowSize.Height
            }
            catch {
                $width = 78
                $height = 30
            }

            # Keep the last physical terminal row untouched. Writing there can
            # scroll the viewport even when the logical frame otherwise fits.
            $visibleBudget = [Math]::Max(1, $height - 11)
            $viewTop = [Math]::Max(0, [Math]::Min($selectedIndex - [int]($visibleBudget / 2), [Math]::Max(0, $Options.Count - $visibleBudget)))
            $viewBottom = [Math]::Min($Options.Count - 1, $viewTop + $visibleBudget - 1)
            $labelWidth = [Math]::Max(1, $width - 8)

            $frame = New-UiFrame
            Add-UiFrameBanner -Frame $frame -Title $Title -Subtitle $Subtitle -Width $width
            $aboveText = if ($viewTop -gt 0) { "  $(Get-UiGlyph -Name Up) $viewTop more above" } else { '' }
            Add-UiFrameLine -Frame $frame -Text "$($_C.Dim)$aboveText$($_C.Reset)$($_C.EraseLn)"
            for ($index = $viewTop; $index -le $viewBottom; $index++) {
                $label = "[$($index + 1)] $([string]$Options[$index].Label)"
                if ($label.Length -gt $labelWidth) {
                    $label = if ($labelWidth -le 1) { $label.Substring(0, 1) } else { $label.Substring(0, $labelWidth - 1) + (Get-UiGlyph -Name Ellipsis) }
                }
                $optionColor = if ($Options[$index].PSObject.Properties['Color']) { [string]$Options[$index].Color } else { $_C.White }
                if ($index -eq $selectedIndex) {
                    Add-UiFrameLine -Frame $frame -Text "$($_C.SelBg)$($_C.SelFg)$($_C.Bold)  $(Get-UiGlyph -Name SelectionArrow) $label $($_C.Reset)$($_C.EraseLn)"
                }
                else {
                    Add-UiFrameLine -Frame $frame -Text "    $optionColor$label$($_C.Reset)$($_C.EraseLn)"
                }
            }
            $belowCount = [Math]::Max(0, $Options.Count - 1 - $viewBottom)
            $belowText = if ($belowCount -gt 0) { "  $(Get-UiGlyph -Name Down) $belowCount more below" } else { '' }
            Add-UiFrameLine -Frame $frame -Text "$($_C.Dim)$belowText$($_C.Reset)$($_C.EraseLn)"
            Add-UiFrameLine -Frame $frame
            Add-UiFrameNavFooter -Frame $frame -Mode $EscapeMode -Width $width
            Write-UiFrame -Frame $frame
            if ($null -ne $firstFrameToken) {
                Complete-DiskHealthPerformanceStage -Token $firstFrameToken -Status success -ResultCount $Options.Count
                $firstFrameToken = $null
            }

            $key = if ($null -ne $ReadKey) { & $ReadKey } else { Read-ConsoleKey }
            $keyName = [string]$key.Key
            $keyCharacter = [char]0
            if ($key.PSObject.Properties['KeyChar']) { $keyCharacter = [char]$key.KeyChar }
            switch ($keyName) {
                'UpArrow'    { $selectedIndex = if ($selectedIndex -eq 0) { $Options.Count - 1 } else { $selectedIndex - 1 } }
                'DownArrow'  { $selectedIndex = if ($selectedIndex -eq ($Options.Count - 1)) { 0 } else { $selectedIndex + 1 } }
                'PageUp'     { $selectedIndex = [Math]::Max(0, $selectedIndex - $visibleBudget) }
                'PageDown'   { $selectedIndex = [Math]::Min($Options.Count - 1, $selectedIndex + $visibleBudget) }
                'Home'       { $selectedIndex = 0 }
                'End'        { $selectedIndex = $Options.Count - 1 }
                'Escape'     { return $EscapeValue }
                'Enter'      { return $Options[$selectedIndex] }
                'ResizeEvent' { continue }
            }
            if ($keyCharacter -match '^[1-9]$') {
                $shortcutIndex = [int][string]$keyCharacter - 1
                if ($shortcutIndex -lt $Options.Count) { return $Options[$shortcutIndex] }
            }
        }
    }
    finally {
        Restore-TuiHost
    }
}

function Show-SmartctlInstallMenu {
    param(
        [Parameter(DontShow)]
        [AllowNull()][scriptblock]$ReadKey
    )

    $options = @(
        [PSCustomObject]@{
            Action = 'Install'
            Label  = 'Install smartctl now (official winget package)'
        }
        [PSCustomObject]@{
            Action = 'Continue'
            Label  = 'Continue with limited WMI/CIM diagnostics'
        }
    )
    $choice = Show-DiskHealthChoiceMenu `
        -Title 'DiskHealth dependency' `
        -Subtitle 'Το smartctl δεν βρέθηκε. Επιλέξτε ενέργεια.' `
        -Options $options `
        -EscapeValue ([pscustomobject]@{ Action = 'Back'; Label = '' }) `
        -EscapeMode Back `
        -ReadKey $ReadKey
    return $choice.Action
}

function Add-DiskHealthDiscoveryDiagnostics {
    param(
        [AllowNull()][string[]]$Diagnostics,
        [AllowNull()]$ScanToken
    )

    if ($null -eq $script:DiskHealthPerformanceContext) { return }
    $phaseMap = @{
        'Ifaces'  = 'Discovery.NetworkInterfaces'
        'DNS'     = 'Discovery.SavedNameResolution'
        'ArpClr'  = 'Discovery.NeighborCacheRefresh'
        'Ping'    = 'Discovery.PingSweep'
        'WS-Disc' = 'Discovery.WSDiscovery'
        'PCPort'  = 'Discovery.ComputerPortSweep'
        'Neighbr' = 'Discovery.NeighborMerge'
        'TCPScan' = 'Discovery.Tcp5985And445Probe'
        'Reverse' = 'Discovery.DNSNetBIOSFallbacks'
        'RevCache' = 'Discovery.NameResolution.Cache'
        'RevAsync' = 'Discovery.NameResolution.AsyncReverseDns'
        'RevDNS'   = 'Discovery.NameResolution.ForegroundDnsFallback'
        'NetBIOS'  = 'Discovery.NameResolution.NetBIOS'
        'BgQueue'  = 'Discovery.NameResolution.BackgroundQueue'
        'Result'   = 'Discovery.NameResolution.ResultBuild'
        'MACMap'   = 'Discovery.NameResolution.MacMap'
    }
    foreach ($line in @($Diagnostics)) {
        if ($line -notmatch '^\s*Phase\s+\S+\s+\((?<Name>[^)]+)\)\s*:\s*(?<Ms>[0-9.,]+)\s*ms(?:\s*\((?<Count>\d+)\s+hosts\))?') { continue }
        $phaseName = [string]$Matches.Name
        if (-not $phaseMap.ContainsKey($phaseName)) { continue }
        $milliseconds = [double]::Parse(($Matches.Ms -replace ',', '.'), [Globalization.CultureInfo]::InvariantCulture)
        $endUtc = [datetime]::UtcNow
        $resultCount = if ([string]::IsNullOrWhiteSpace([string]$Matches['Count'])) { $null } else { [int]$Matches['Count'] }
        Add-DiskHealthPerformanceRecord `
            -Stage $phaseMap[$phaseName] `
            -ParentStage 'Discovery.FullScan' `
            -StartUtc $endUtc.AddMilliseconds(-$milliseconds) `
            -EndUtc $endUtc `
            -DurationMs $milliseconds `
            -Status success `
            -ResultCount $resultCount
    }
}

function Get-DiskHealthWinRMComputers {
    param(
        [string]$StateRoot = '',
        [AllowEmptyString()][string]$NetworkId = ''
    )

    Import-DiskHealthWinRMDiscovery -StateRoot $StateRoot
    Show-DiskHealthPerformanceProgress -Stage 'Discovery.FullScan' -Message 'Canonical LAN sources are running.'
    $scanToken = Start-DiskHealthPerformanceStage -Stage 'Discovery.FullScan' -ParentStage 'Network.Discovery'
    try {
        $computers = @(Find-WinRMComputer `
            -StateRoot $StateRoot `
            -NetworkId $NetworkId `
            -IncludeDiagnostics:$script:DiskHealthBenchmarkEnabled `
            -DiagnosticsInMemoryOnly:$script:DiskHealthBenchmarkEnabled)
        Complete-DiskHealthPerformanceStage -Token $scanToken -Status success -ResultCount $computers.Count
        if ($script:DiskHealthBenchmarkEnabled) {
            Add-DiskHealthDiscoveryDiagnostics -Diagnostics @(Get-WinRMDiscoveryDiagnostics) -ScanToken $scanToken
        }
    } catch {
        $category = Get-DiskHealthPerformanceErrorCategory $_
        Complete-DiskHealthPerformanceStage -Token $scanToken -Status $(if ($category -eq 'Timeout') { 'timeout' } else { 'failure' }) -ErrorCategory $category
        throw
    }
    return $computers
}

function Resolve-DiskHealthSavedWinRMTargetsParallel {
    param(
        [AllowNull()][object[]]$History,
        [AllowEmptyString()][string]$StateRoot = '',
        [ValidateRange(1, 16)][int]$MaxConcurrency = 8
    )

    $entries = @($History)
    if ($entries.Count -eq 0) { return @() }
    $manifest = Join-Path -Path $PSScriptRoot -ChildPath '.assets\WinRMDiscovery\WinRMDiscovery.psd1'
    $workerScript = {
        param($Manifest, $DiscoveryStateRoot, $ComputerName, $LastIPAddress, $MACAddress)

        Import-Module -Name $Manifest -Force -ErrorAction Stop
        if (-not [string]::IsNullOrWhiteSpace($DiscoveryStateRoot)) {
            Set-WinRMDiscoveryStateRoot -Path $DiscoveryStateRoot
        }
        $resolution = Resolve-WinRMHistoryTargetAddress `
            -ComputerName $ComputerName `
            -LastIPAddress $LastIPAddress `
            -MACAddress $MACAddress `
            -IncludeDiagnostics
        [PSCustomObject]@{
            ResolvedAddress = [string]$resolution.ResolvedAddress
            Diagnostics     = @($resolution.Diagnostics)
        }
    }

    $poolToken = Start-DiskHealthPerformanceStage -Stage 'History.Resolve.RunspacePool' -ParentStage 'History.Resolve'
    $pool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, [Math]::Min($MaxConcurrency, $entries.Count))
    $pool.Open()
    Complete-DiskHealthPerformanceStage -Token $poolToken -Status success -ResultCount ([Math]::Min($MaxConcurrency, $entries.Count))
    $jobs = [System.Collections.Generic.List[object]]::new()
    $ordinal = 0
    try {
        foreach ($entry in $entries) {
            $ordinal++
            $powerShell = [PowerShell]::Create()
            $powerShell.RunspacePool = $pool
            $null = $powerShell.AddScript($workerScript.ToString()).AddArgument($manifest).AddArgument($StateRoot).AddArgument([string]$entry.ComputerName).AddArgument([string]$entry.LastIPAddress).AddArgument([string]$entry.MACAddress)
            $jobs.Add([PSCustomObject]@{
                Ordinal   = $ordinal
                Entry     = $entry
                PowerShell = $powerShell
                Handle    = $powerShell.BeginInvoke()
                StartUtc  = [datetime]::UtcNow
                Watch     = [System.Diagnostics.Stopwatch]::StartNew()
            })
        }

        $progressWatch = [System.Diagnostics.Stopwatch]::StartNew()
        do {
            $completedCount = @($jobs | Where-Object { $_.Handle.IsCompleted }).Count
            if ($progressWatch.ElapsedMilliseconds -ge 500 -or $completedCount -eq $jobs.Count) {
                Show-DiskHealthPerformanceProgress -Stage "History.ResolveParallel[$completedCount/$($jobs.Count)]" -Message 'Canonical saved-target resolvers are running concurrently.'
                $progressWatch.Restart()
            }
            if ($completedCount -lt $jobs.Count) { Start-Sleep -Milliseconds 100 }
        } while ($completedCount -lt $jobs.Count)

        $resolvedRows = [System.Collections.Generic.List[object]]::new()
        foreach ($job in @($jobs | Sort-Object Ordinal)) {
            $resolvedAddress = ''
            $status = 'success'
            $errorCategory = ''
            try {
                $output = @($job.PowerShell.EndInvoke($job.Handle))
                $payload = $output | Where-Object { $_.PSObject.Properties['ResolvedAddress'] } | Select-Object -Last 1
                if ($null -ne $payload) { $resolvedAddress = [string]$payload.ResolvedAddress }
                if ($null -ne $payload -and $payload.PSObject.Properties['Diagnostics']) {
                    foreach ($diagnostic in @($payload.Diagnostics)) {
                        Add-DiskHealthPerformanceRecord `
                            -Stage "History.Resolve.Entry$($job.Ordinal).$([string]$diagnostic.Stage)" `
                            -ParentStage "History.Resolve.Entry$($job.Ordinal)" `
                            -StartUtc ([datetime]$diagnostic.StartUtc) `
                            -EndUtc ([datetime]$diagnostic.EndUtc) `
                            -DurationMs ([double]$diagnostic.DurationMs) `
                            -Status ([string]$diagnostic.Status) `
                            -AttemptCount ([int]$diagnostic.AttemptCount) `
                            -ResultCount ([int]$diagnostic.ResultCount) `
                            -ErrorCategory ([string]$diagnostic.ErrorCategory)
                    }
                }
                if ([string]::IsNullOrWhiteSpace($resolvedAddress)) {
                    $status = 'failure'
                    $errorCategory = 'Unresolved'
                }
            } catch {
                $status = if ((Get-DiskHealthPerformanceErrorCategory $_) -eq 'Timeout') { 'timeout' } else { 'failure' }
                $errorCategory = Get-DiskHealthPerformanceErrorCategory $_
            } finally {
                $job.Watch.Stop()
                Add-DiskHealthPerformanceRecord `
                    -Stage "History.Resolve.Entry$($job.Ordinal)" `
                    -ParentStage 'History.Resolve' `
                    -StartUtc $job.StartUtc `
                    -EndUtc ([datetime]::UtcNow) `
                    -DurationMs $job.Watch.Elapsed.TotalMilliseconds `
                    -Status $status `
                    -AttemptCount 1 `
                    -ResultCount ([int](-not [string]::IsNullOrWhiteSpace($resolvedAddress))) `
                    -ErrorCategory $errorCategory
                $job.PowerShell.Dispose()
            }
            $resolvedRows.Add([PSCustomObject]@{
                Ordinal         = $job.Ordinal
                Entry           = $job.Entry
                ResolvedAddress = $resolvedAddress
            })
        }
        return @($resolvedRows)
    } finally {
        foreach ($job in @($jobs)) {
            if ($null -ne $job.PowerShell) { $job.PowerShell.Dispose() }
        }
        $pool.Close()
        $pool.Dispose()
    }
}

function Get-DiskHealthCatalogTargetPresentation {
    param(
        [Parameter(Mandatory)]$Entry,
        [bool]$HasFreshSnapshot
    )

    $hasTargetSnapshot = [bool]$Entry.HasDiscoverySnapshot
    $winRMHttpOpen = $(if ($hasTargetSnapshot) { [bool]$Entry.WinRMHttpOpen } else { $false })
    $smbOpen = $(if ($hasTargetSnapshot) { [bool]$Entry.SMBOpen } else { $false })
    $detectedOnly = $(if ($hasTargetSnapshot) { [bool]$Entry.DetectedOnly } else { $false })
    $status = $(if ($hasTargetSnapshot) {
            $cachedStatus = [string]$Entry.CachedStatus
            if ([string]::IsNullOrWhiteSpace($cachedStatus)) { $cachedStatus = 'ComputerDetected' }
            "Fresh scan / $cachedStatus"
        } elseif ($HasFreshSnapshot -and [bool]$Entry.HasSavedHistory) {
            'Fresh scan / offline'
        } elseif ([bool]$Entry.HasSavedHistory) {
            'Saved / not checked'
        } else {
            'Cached discovery'
        })

    return [PSCustomObject]@{
        WinRMHttpOpen      = $winRMHttpOpen
        SMBOpen            = $smbOpen
        DetectedOnly       = $detectedOnly
        Status             = $status
        ValidationStatus   = [string]$Entry.ValidationStatus
        HasDiscoverySnapshot = $hasTargetSnapshot
    }
}

function Get-DiskHealthSavedWinRMTargets {
    param([string]$StateRoot = '')

    $pathToken = Start-DiskHealthPerformanceStage -Stage 'History.SavedTargetPath' -ParentStage 'Network.Discovery'
    Show-DiskHealthPerformanceProgress -Stage 'History.Initialization' -Message 'Loading network-scoped saved targets.'
    Import-DiskHealthWinRMDiscovery -StateRoot $StateRoot
    $identityToken = Start-DiskHealthPerformanceStage -Stage 'History.NetworkIdentity' -ParentStage 'History.SavedTargetPath'
    $networkInfo = Get-WinRMNetworkIdentity
    Complete-DiskHealthPerformanceStage -Token $identityToken -Status success -ResultCount 1
    $historyToken = Start-DiskHealthPerformanceStage -Stage 'History.TargetCatalog' -ParentStage 'History.SavedTargetPath'
    $catalog = Get-WinRMTargetCatalog -NetworkId $networkInfo.NetworkId -IncludeDiagnostics:$script:DiskHealthBenchmarkEnabled
    Complete-DiskHealthPerformanceStage -Token $historyToken -Status success -ResultCount $catalog.TargetCount
    foreach ($diagnostic in @($catalog.Diagnostics)) {
        Add-DiskHealthPerformanceRecord `
            -Stage ([string]$diagnostic.Stage) `
            -ParentStage 'History.TargetCatalog' `
            -StartUtc ([datetime]$diagnostic.StartUtc) `
            -EndUtc ([datetime]$diagnostic.EndUtc) `
            -DurationMs ([double]$diagnostic.DurationMs) `
            -Status ([string]$diagnostic.Status) `
            -AttemptCount ([int]$diagnostic.AttemptCount) `
            -ResultCount ([int]$diagnostic.ResultCount) `
            -ErrorCategory ([string]$diagnostic.ErrorCategory)
    }
    $targets = [System.Collections.Generic.List[object]]::new()
    $hasFreshSnapshot = -not [string]::IsNullOrWhiteSpace([string]$catalog.SnapshotCapturedAtUtc)

    foreach ($entry in @($catalog.Targets)) {
        $presentation = Get-DiskHealthCatalogTargetPresentation -Entry $entry -HasFreshSnapshot $hasFreshSnapshot
        $targets.Add([PSCustomObject]@{
            ComputerName  = $entry.ComputerName
            IPAddress     = $entry.IPAddress
            MACAddress    = $entry.MACAddress
            UserName      = $entry.UserName
            LastConnected = $entry.LastConnected
            WinRMHttpOpen = $presentation.WinRMHttpOpen
            SMBOpen       = $presentation.SMBOpen
            DetectedOnly  = $presentation.DetectedOnly
            Status        = $presentation.Status
            ValidationStatus = $presentation.ValidationStatus
            HasDiscoverySnapshot = $presentation.HasDiscoverySnapshot
            Source        = $entry.Source
            RequiresValidation = [bool]$entry.RequiresValidation
        })
    }

    $mergeToken = Start-DiskHealthPerformanceStage -Stage 'Discovery.MergeDedupSort' -ParentStage 'Network.Discovery'
    Complete-DiskHealthPerformanceStage -Token $mergeToken -Status skipped -ResultCount $targets.Count
    Complete-DiskHealthPerformanceStage -Token $pathToken -Status success -ResultCount $targets.Count

    return [PSCustomObject]@{
        NetworkInfo = $networkInfo
        Targets     = @($targets)
    }
}

function Select-WinRMDiscoveryTarget {
    param(
        [string]$StateRoot = '',
        [AllowNull()]
        [array]$Computers,
        [switch]$AllowScan
    )

    if ($null -eq $Computers) { $Computers = @() }

    Show-DiskHealthPerformanceProgress -Stage 'TargetMenu.Build' -Message 'Building target rows from sanitized discovery results.'
    $buildToken = Start-DiskHealthPerformanceStage -Stage 'TargetMenu.Build' -ParentStage 'Network.TargetSelection'
    $selectedIndex = 0
    for ($index = 0; $index -lt $Computers.Count; $index++) {
        if ($Computers[$index].WinRMHttpOpen) { $selectedIndex = $index; break }
    }

    $options = [System.Collections.Generic.List[object]]::new()
    foreach ($computer in @($Computers)) {
        if (-not $computer.PSObject.Properties['Action']) {
            $computer | Add-Member -NotePropertyName Action -NotePropertyValue 'Target'
        }
        $label = "$($computer.ComputerName)  $($computer.IPAddress)  [$($computer.Status)]"
        $color = if ($computer.WinRMHttpOpen) { $_C.OK } else { $_C.Warn }
        $computer | Add-Member -NotePropertyName Label -NotePropertyValue $label -Force
        $computer | Add-Member -NotePropertyName Color -NotePropertyValue $color -Force
        $options.Add($computer)
    }
    if ($AllowScan) {
        $options.Add([PSCustomObject]@{
            Action        = 'Scan'
            ComputerName  = 'Scan network for more PCs'
            IPAddress     = ''
            WinRMHttpOpen = $false
            Status        = 'Discovery'
            Label         = '🔎 Scan network for more PCs'
            Color         = $_C.H1
        })
    }
    Complete-DiskHealthPerformanceStage -Token $buildToken -Status success -ResultCount $options.Count
    return Show-DiskHealthChoiceMenu `
        -Title 'DiskHealth network targets' `
        -Subtitle 'Επιλέξτε WinRM υπολογιστή.' `
        -Options @($options) `
        -DefaultIndex $selectedIndex `
        -EscapeValue $null `
        -EscapeMode Back `
        -PerformanceStage 'TargetMenu.FirstFrame' `
        -PerformanceParentStage 'Network.TargetSelection'
}

function Invoke-DiscoveredWinRMTarget {
    param(
        [Parameter(Mandatory)]$Target,
        [string]$DefaultUsername = 'user',
        [AllowNull()]$NetworkInfo
    )

    Import-DiskHealthWinRMDiscovery -StateRoot $DiscoveryStateRoot
    Import-DiskHealthWinRMConnection
    if ($null -eq $NetworkInfo) {
        $networkIdentityToken = Start-DiskHealthPerformanceStage -Stage 'History.NetworkIdentity.Refresh' -ParentStage 'Network.Authentication'
        $NetworkInfo = Get-WinRMNetworkIdentity
        Complete-DiskHealthPerformanceStage -Token $networkIdentityToken -Status success -ResultCount 1
    }
    $networkId = [string]$NetworkInfo.NetworkId
    $requiresValidation = $Target.PSObject.Properties['RequiresValidation'] -and [bool]$Target.RequiresValidation
    if ($requiresValidation) {
        Show-DiskHealthPerformanceProgress -Stage 'History.SelectedTargetResolve' -Message 'Validating only the selected saved target.' -ForceClear
        $resolveToken = Start-DiskHealthPerformanceStage -Stage 'History.SelectedTargetResolve' -ParentStage 'Network.Authentication'
        $resolution = Resolve-WinRMHistoryTargetAddress `
            -ComputerName ([string]$Target.ComputerName) `
            -LastIPAddress ([string]$Target.IPAddress) `
            -MACAddress ([string]$Target.MACAddress) `
            -IncludeDiagnostics
        foreach ($diagnostic in @($resolution.Diagnostics)) {
            Add-DiskHealthPerformanceRecord `
                -Stage "History.SelectedTargetResolve.$([string]$diagnostic.Stage)" `
                -ParentStage 'History.SelectedTargetResolve' `
                -StartUtc ([datetime]$diagnostic.StartUtc) `
                -EndUtc ([datetime]$diagnostic.EndUtc) `
                -DurationMs ([double]$diagnostic.DurationMs) `
                -Status ([string]$diagnostic.Status) `
                -AttemptCount ([int]$diagnostic.AttemptCount) `
                -ResultCount ([int]$diagnostic.ResultCount) `
                -ErrorCategory ([string]$diagnostic.ErrorCategory)
        }
        if ([string]::IsNullOrWhiteSpace([string]$resolution.ResolvedAddress)) {
            Complete-DiskHealthPerformanceStage -Token $resolveToken -Status failure -AttemptCount 1 -ErrorCategory 'Unresolved'
            $null = Show-DiskHealthChoiceMenu `
                -Title 'Saved target unavailable' `
                -Subtitle 'Το επιλεγμένο PC δεν απάντησε τώρα στο WinRM 5985.' `
                -Options @([PSCustomObject]@{ Label = '↩ Back to network targets' }) `
                -DefaultIndex 0 `
                -EscapeValue $null `
                -EscapeMode Back
            return $false
        }
        $Target.IPAddress = [string]$resolution.ResolvedAddress
        Complete-DiskHealthPerformanceStage -Token $resolveToken -Status success -AttemptCount 1 -ResultCount 1
    }
    $historyMatchToken = Start-DiskHealthPerformanceStage -Stage 'History.TargetLookup' -ParentStage 'Network.Authentication'
    $historyMatch = Get-WinRMConnectionHistory -NetworkId $networkId |
        Where-Object {
            $_.ComputerName -eq $Target.ComputerName -or
            $_.LastIPAddress -eq $Target.IPAddress
        } |
        Select-Object -First 1
    Complete-DiskHealthPerformanceStage -Token $historyMatchToken -Status success -ResultCount ([int]($null -ne $historyMatch))
    $preferredUsername = if ($historyMatch -and -not [string]::IsNullOrWhiteSpace($historyMatch.UserName) -and $historyMatch.UserName -ne 'Unknown') {
        [string]$historyMatch.UserName
    } elseif (-not [string]::IsNullOrWhiteSpace($Target.UserName) -and $Target.UserName -ne 'Unknown') {
        [string]$Target.UserName
    } else {
        $DefaultUsername
    }
    $credentialAliases = @(
        @($Target.ComputerName, $Target.IPAddress, $historyMatch.ComputerName) |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique
    )
    Show-DiskHealthPerformanceProgress -Stage 'Credential.DPAPILookup' -Message 'Only the canonical DPAPI profile API is used.'
    $credentialLookupToken = Start-DiskHealthPerformanceStage -Stage 'Credential.DPAPILookup' -ParentStage 'Network.Authentication'
    $storedCredential = Get-DiskHealthStoredCredential -NetworkId $networkId -ComputerNames $credentialAliases
    Complete-DiskHealthPerformanceStage -Token $credentialLookupToken -Status success -ResultCount ([int]($null -ne $storedCredential))
    if ($storedCredential) {
        $preferredUsername = $storedCredential.UserName
    }

    Clear-Host
    Write-Host '======================================================================' -ForegroundColor Cyan
    Write-Host '  🌐 WINRM LOGIN' -ForegroundColor Cyan
    Write-Host '======================================================================' -ForegroundColor Cyan
    Write-Host "  Target: $($Target.ComputerName) ($($Target.IPAddress))" -ForegroundColor White
    $credentialToUse = $storedCredential
    if ($credentialToUse) {
        Write-Host "  🔐 Αποθηκευμένα credentials: $($credentialToUse.UserName)" -ForegroundColor Green
        Write-Host "  🔄 Δοκιμή αυτόματης σύνδεσης στο ίδιο αποθηκευμένο δίκτυο..." -ForegroundColor DarkGray
    } else {
        $credentialPromptToken = Start-DiskHealthPerformanceStage -Stage 'Credential.Prompt' -ParentStage 'Network.Authentication'
        Write-Host "  Username: ENTER = '$preferredUsername'" -ForegroundColor DarkGray
        $enteredUsername = (Read-Host '  Username').Trim()
        $remoteUsername = if ([string]::IsNullOrWhiteSpace($enteredUsername)) { $preferredUsername } else { $enteredUsername }
        Write-Host '  Password: ENTER = blank' -ForegroundColor DarkGray
        $securePassword = Read-Host '  Password' -AsSecureString
        $credentialToUse = [System.Management.Automation.PSCredential]::new($remoteUsername, $securePassword)
        Complete-DiskHealthPerformanceStage -Token $credentialPromptToken -Status success -AttemptCount 1 -ResultCount 1
    }

    & $PSCommandPath `
        -ComputerName $Target.IPAddress `
        -Username $credentialToUse.UserName `
        -Credential $credentialToUse `
        -InstallSmartctl:$InstallSmartctl `
        -DiscoveryStateRoot $DiscoveryStateRoot `
        -Benchmark:$script:DiskHealthBenchmarkEnabled `
        -ConnectionNetworkId $networkId `
        -ConnectionDisplayName $Target.ComputerName `
        -ConnectionMacAddress $Target.MACAddress `
        -CredentialFromSavedProfile:($null -ne $storedCredential) `
        -NoUI:$NoUI `
        -EmbeddedRemote `
        -PerformanceContext $script:DiskHealthPerformanceContext
}

function Show-StartupTargetMenu {
    $options = @(
        [PSCustomObject]@{ Action = 'Local'; Label = '💻 Local computer' },
        [PSCustomObject]@{ Action = 'Network'; Label = '🌐 Network computer (WinRM)' }
    )
    $choice = Show-DiskHealthChoiceMenu `
        -Title '💾 DISKHEALTH' `
        -Subtitle 'Επιλέξτε πηγή δίσκων.' `
        -Options $options `
        -EscapeValue ([pscustomobject]@{ Action = 'Exit'; Label = '' }) `
        -EscapeMode Exit
    return $choice.Action
}

if ($script:IsHomeLauncher) {
    while ($true) {
        $startupChoice = Show-StartupTargetMenu
        if ($startupChoice -eq 'Exit') {
            Clear-Host
            return
        }
        if ($startupChoice -eq 'Local') {
            & $PSCommandPath `
                -ComputerName 'localhost' `
                -Username $Username `
                -InstallSmartctl:$InstallSmartctl `
                -DiscoveryStateRoot $DiscoveryStateRoot `
                -Benchmark:$Benchmark `
                -NoUI:$NoUI `
                -EmbeddedRemote
            continue
        }

        if ($startupChoice -eq 'Network') {
            Initialize-DiskHealthPerformance
            $networkFlowToken = Start-DiskHealthPerformanceStage -Stage 'Network.Flow.Total' -ParentStage 'Run'
            $networkFlowFailed = $false
            try {
                $firstProgressToken = Start-DiskHealthPerformanceStage -Stage 'Network.SelectionToFirstProgress' -ParentStage 'Network.Flow.Total'
                Show-DiskHealthPerformanceProgress -Stage 'Network.Starting' -Message 'Loading canonical WinRM assets and saved history.' -ForceClear
                Complete-DiskHealthPerformanceStage -Token $firstProgressToken -Status success -ResultCount 1
                $savedState = Get-DiskHealthSavedWinRMTargets -StateRoot $DiscoveryStateRoot
                $networkInfo = $savedState.NetworkInfo
                $networkComputers = @($savedState.Targets)
                $allowNetworkScan = $true
                while ($true) {
                    $discoveredTarget = Select-WinRMDiscoveryTarget -Computers $networkComputers -AllowScan:$allowNetworkScan
                    if ($null -eq $discoveredTarget) {
                        break
                    }
                    if ($discoveredTarget.Action -eq 'Scan') {
                        Show-DiskHealthPerformanceProgress -Stage 'Discovery.FullScan' -Message 'Refreshing the target list.' -ForceClear
                        $null = @(Get-DiskHealthWinRMComputers -StateRoot $DiscoveryStateRoot -NetworkId $networkInfo.NetworkId)
                        $savedState = Get-DiskHealthSavedWinRMTargets -StateRoot $DiscoveryStateRoot
                        $networkComputers = @($savedState.Targets)
                        continue
                    }
                    Invoke-DiscoveredWinRMTarget -Target $discoveredTarget -DefaultUsername $Username -NetworkInfo $networkInfo
                }
            } catch {
                $networkFlowFailed = $true
                throw
            } finally {
                Complete-DiskHealthPerformanceStage -Token $networkFlowToken -Status $(if ($networkFlowFailed) { 'failure' } else { 'success' }) -ErrorCategory $(if ($networkFlowFailed) { 'NetworkFlow' } else { '' })
                if ($networkFlowFailed) {
                    Save-DiskHealthPerformanceReport -Finalize -ShowSummary
                } else {
                    Save-DiskHealthPerformanceReport
                }
            }
        }
    }
    if ($null -ne $script:DiskHealthPerformanceContext) {
        Save-DiskHealthPerformanceReport -Finalize -ShowSummary
    }
    return
}

if ($Discover) {
    if (-not [string]::IsNullOrWhiteSpace($FilePath)) {
        throw 'Τα -Discover και -FilePath δεν μπορούν να χρησιμοποιηθούν μαζί.'
    }
    Import-DiskHealthWinRMDiscovery -StateRoot $DiscoveryStateRoot
    $discoverNetworkInfo = Get-WinRMNetworkIdentity
    $discoverComputers = @(Get-DiskHealthWinRMComputers -StateRoot $DiscoveryStateRoot -NetworkId $discoverNetworkInfo.NetworkId)
    while ($true) {
        $discoveredTarget = Select-WinRMDiscoveryTarget -Computers $discoverComputers -AllowScan
        if ($null -eq $discoveredTarget) {
            Write-Host 'Η επιλογή στόχου ακυρώθηκε.' -ForegroundColor Yellow
            return
        }
        if ($discoveredTarget.Action -eq 'Scan') {
            $discoverComputers = @(Get-DiskHealthWinRMComputers -StateRoot $DiscoveryStateRoot -NetworkId $discoverNetworkInfo.NetworkId)
            continue
        }
        break
    }
    $ComputerName = $discoveredTarget.IPAddress
    $ConnectionNetworkId = $discoverNetworkInfo.NetworkId
    $ConnectionDisplayName = $discoveredTarget.ComputerName
    $ConnectionMacAddress = $discoveredTarget.MACAddress
    if ($null -eq $Credential -and [string]::IsNullOrWhiteSpace($Password)) {
        $Credential = Get-DiskHealthStoredCredential `
            -NetworkId $ConnectionNetworkId `
            -ComputerNames @($discoveredTarget.ComputerName, $discoveredTarget.IPAddress)
        if ($Credential) {
            $Username = $Credential.UserName
        }
    }
    Write-Host "  ✅ Επιλέχθηκε: $($discoveredTarget.ComputerName) ($ComputerName)" -ForegroundColor Green
}

function ConvertTo-NvmeCounter {
    param(
        [AllowNull()]
        [object]$Value,

        [AllowNull()]
        [string]$StringValue
    )

    $candidate = if ($StringValue -match '^\d+$') { $StringValue } else { [string]$Value }
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        return [System.Numerics.BigInteger]::Zero
    }

    $parsed = [System.Numerics.BigInteger]::Zero
    if ([System.Numerics.BigInteger]::TryParse(
            $candidate,
            [System.Globalization.NumberStyles]::Integer,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [ref]$parsed)) {
        return $parsed
    }

    throw "Invalid NVMe counter value: '$candidate'"
}

function Get-NvmeMediaErrorAssessment {
    param(
        [System.Numerics.BigInteger]$MediaErrors,
        [System.Numerics.BigInteger]$ErrorLogEntries,
        [System.Numerics.BigInteger]$CriticalWarning
    )

    $twoTo64 = [System.Numerics.BigInteger]::Pow([System.Numerics.BigInteger]2, 64)
    $low64 = $MediaErrors % $twoTo64
    $upper64 = $MediaErrors / $twoTo64

    # NVMe counters are 128-bit. A non-zero upper half paired with a zero low
    # half, no critical warning and no error-log entries is internally
    # inconsistent telemetry. Preserve it; never rewrite it to zero.
    $isStructuralAnomaly = (
        $MediaErrors -gt [System.Numerics.BigInteger][uint64]::MaxValue -and
        $low64 -eq [System.Numerics.BigInteger]::Zero -and
        $upper64 -gt [System.Numerics.BigInteger]::Zero -and
        $ErrorLogEntries -eq [System.Numerics.BigInteger]::Zero -and
        $CriticalWarning -eq [System.Numerics.BigInteger]::Zero
    )

    [PSCustomObject]@{
        FullValue           = $MediaErrors
        Low64               = $low64
        Upper64             = $upper64
        IsStructuralAnomaly = $isStructuralAnomaly
    }
}

function Get-AtaTemperatureCelsius {
    param(
        [Parameter(Mandatory)]$Attribute,
        [AllowNull()]$SmartData
    )

    $rawStringProperty = $Attribute.PSObject.Properties['RawString']
    if ($null -ne $rawStringProperty -and [string]$rawStringProperty.Value -match '^\s*(-?\d+)') {
        $stringTemperature = [int]$Matches[1]
        if ($stringTemperature -ge -40 -and $stringTemperature -le 200) {
            return $stringTemperature
        }
    }

    if ($null -ne $SmartData -and $null -ne $SmartData.temperature -and $null -ne $SmartData.temperature.current) {
        $reportedTemperature = [int]$SmartData.temperature.current
        if ($reportedTemperature -ge -40 -and $reportedTemperature -le 200) {
            return $reportedTemperature
        }
    }

    $rawTemperature = [long]$Attribute.Raw
    if ($rawTemperature -ge -40 -and $rawTemperature -le 200) {
        return [int]$rawTemperature
    }

    return $null
}

function Get-AtaSpinUpTimeDisplay {
    param([long]$RawMilliseconds)

    if ($RawMilliseconds -lt 0 -or $RawMilliseconds -gt 600000) {
        return "$RawMilliseconds"
    }

    $seconds = [Math]::Round($RawMilliseconds / 1000.0, 2)
    return "$RawMilliseconds ms ($seconds s)"
}

function Get-AtaPowerOnHoursValue {
    param(
        [Parameter(Mandatory)]$Attribute,
        [AllowNull()]$SmartData
    )

    $powerOnProperty = if ($null -ne $SmartData) { $SmartData.PSObject.Properties['power_on_time'] } else { $null }
    $hoursProperty = if ($null -ne $powerOnProperty -and $null -ne $powerOnProperty.Value) { $powerOnProperty.Value.PSObject.Properties['hours'] } else { $null }
    if ($null -ne $hoursProperty -and $null -ne $hoursProperty.Value) {
        return [long]$hoursProperty.Value
    }

    $rawStringProperty = $Attribute.PSObject.Properties['RawString']
    if ($null -ne $rawStringProperty -and [string]$rawStringProperty.Value -match '^\s*(\d+)h(?:\+|\s|$)') {
        return [long]$Matches[1]
    }

    if ($null -ne $Attribute.Raw -and [long]$Attribute.Raw -ge 0 -and [long]$Attribute.Raw -le 10000000) {
        return [long]$Attribute.Raw
    }

    return $null
}

function Get-SeagateNormalizedRateState {
    param(
        [int]$AttributeId,
        [int]$Current,
        [int]$Threshold,
        [bool]$IsSeagateHdd
    )

    # Seagate documents individual ATA SMART attributes as proprietary. In
    # particular, the non-zero raw fields for 01/07/C3 are not portable error
    # totals. Only the normalized value against its firmware threshold is safe
    # to use here; the overall SMART result remains an independent guard.
    if (-not $IsSeagateHdd -or $AttributeId -notin @(0x01, 0x07, 0xC3)) {
        return 'NotApplicable'
    }

    if ($Threshold -le 0) {
        return 'NoThreshold'
    }

    if ($Current -le $Threshold) {
        return 'ThresholdCrossed'
    }

    # Above-threshold means only that this attribute has not triggered its
    # firmware failure condition. It is not a vendor-independent health claim.
    return 'AboveThreshold'
}

function Get-SeagateReadEccContext {
    param(
        [AllowNull()][object[]]$Attributes,
        [AllowNull()]$SmartData,
        [bool]$IsSeagateHdd
    )

    if (-not $IsSeagateHdd) {
        return $null
    }

    $readRate = $Attributes | Where-Object { $_.ID -eq 0x01 } | Select-Object -First 1
    $hardwareEcc = $Attributes | Where-Object { $_.ID -eq 0xC3 } | Select-Object -First 1
    if (-not $readRate -or -not $hardwareEcc) {
        return $null
    }

    $counterValues = @{}
    foreach ($counterId in @(0x05, 0xBB, 0xC5, 0xC6)) {
        $counterAttribute = $Attributes | Where-Object { $_.ID -eq $counterId } | Select-Object -First 1
        $counterValues[$counterId] = if ($counterAttribute) { [uint64]$counterAttribute.Raw } else { $null }
    }

    $errorLogCount = $null
    $errorLogProperty = if ($null -ne $SmartData) { $SmartData.PSObject.Properties['ata_smart_error_log'] } else { $null }
    $summaryProperty = if ($null -ne $errorLogProperty -and $null -ne $errorLogProperty.Value) { $errorLogProperty.Value.PSObject.Properties['summary'] } else { $null }
    $countProperty = if ($null -ne $summaryProperty -and $null -ne $summaryProperty.Value) { $summaryProperty.Value.PSObject.Properties['count'] } else { $null }
    if ($null -ne $countProperty -and $null -ne $countProperty.Value) {
        $errorLogCount = [uint64]$countProperty.Value
    }

    $hasUnresolvedIndicators = @(
        $counterValues.Values | Where-Object { $null -ne $_ -and $_ -gt 0 }
    ).Count -gt 0
    if ($null -ne $errorLogCount -and $errorLogCount -gt 0) {
        $hasUnresolvedIndicators = $true
    }

    return [PSCustomObject]@{
        Current                 = [int]$readRate.Current
        Worst                   = [int]$readRate.Worst
        Threshold               = [int]$readRate.Threshold
        ReadRaw                 = [uint64]$readRate.Raw
        EccRaw                  = [uint64]$hardwareEcc.Raw
        HasMirroredRawTelemetry = ([uint64]$readRate.Raw -eq [uint64]$hardwareEcc.Raw)
        Reallocated             = $counterValues[0x05]
        ReportedUncorrectable   = $counterValues[0xBB]
        Pending                 = $counterValues[0xC5]
        OfflineUncorrectable    = $counterValues[0xC6]
        ErrorLogCount           = $errorLogCount
        HasUnresolvedIndicators = $hasUnresolvedIndicators
    }
}

function Get-ConsoleSafeTextWidth {
    param([int]$Maximum = 98)

    $detectedWidth = 0
    try {
        $detectedWidth = [Console]::WindowWidth
    } catch {
        $detectedWidth = 0
    }

    if ($detectedWidth -le 0) {
        return $Maximum
    }

    return [Math]::Max(24, [Math]::Min($Maximum, $detectedWidth - 1))
}

function Get-WrappedConsoleLines {
    param(
        [AllowEmptyString()][string]$Text,
        [AllowEmptyString()][string]$FirstPrefix = '',
        [AllowEmptyString()][string]$ContinuationPrefix = '',
        [int]$MaximumWidth = 118
    )

    if ($MaximumWidth -le $FirstPrefix.Length -or $MaximumWidth -le $ContinuationPrefix.Length) {
        throw "MaximumWidth $MaximumWidth is too small for the requested prefixes."
    }

    $words = @($Text -split '\s+' | Where-Object { $_.Length -gt 0 })
    if ($words.Count -eq 0) {
        return @($FirstPrefix)
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    $line = $FirstPrefix
    $hasContent = $false

    foreach ($word in $words) {
        $separator = if ($hasContent) { ' ' } else { '' }
        if (($line.Length + $separator.Length + $word.Length) -le $MaximumWidth) {
            $line += $separator + $word
            $hasContent = $true
            continue
        }

        if ($hasContent) {
            $lines.Add($line)
            $line = $ContinuationPrefix
            $hasContent = $false
        }

        $remainingWord = $word
        while (($line.Length + $remainingWord.Length) -gt $MaximumWidth) {
            $available = [Math]::Max(1, $MaximumWidth - $line.Length)
            $lines.Add($line + $remainingWord.Substring(0, $available))
            $remainingWord = $remainingWord.Substring($available)
            $line = $ContinuationPrefix
        }

        $line += $remainingWord
        $hasContent = $true
    }

    $lines.Add($line)
    return @($lines)
}

function Write-WrappedConsoleText {
    param(
        [AllowEmptyString()][string]$Text,
        [AllowEmptyString()][string]$FirstPrefix = '',
        [AllowEmptyString()][string]$ContinuationPrefix = '',
        [int]$MaximumWidth = 118,
        [ConsoleColor]$ForegroundColor = [ConsoleColor]::Gray
    )

    foreach ($wrappedLine in @(Get-WrappedConsoleLines -Text $Text -FirstPrefix $FirstPrefix -ContinuationPrefix $ContinuationPrefix -MaximumWidth $MaximumWidth)) {
        Write-Host $wrappedLine -ForegroundColor $ForegroundColor
    }
}

function Get-SmartTableLegendRows {
    param([Parameter(Mandatory)][string[]]$TextLines)

    $outerWidth = 99
    $innerBorderWidth = $outerWidth - 4
    $cellTextWidth = $outerWidth - 6
    $rows = [System.Collections.Generic.List[string]]::new()
    $rows.Add('  +' + ('-' * $innerBorderWidth) + '+')

    foreach ($textLine in $TextLines) {
        foreach ($wrappedLine in @(Get-WrappedConsoleLines -Text $textLine -MaximumWidth $cellTextWidth)) {
            $rows.Add('  | ' + $wrappedLine.PadRight($cellTextWidth) + ' |')
        }
    }

    return @($rows)
}

function Get-DiskHealthReportColorPriority {
    param([AllowEmptyString()][string]$Color)

    switch ($Color) {
        'Red'      { return 60 }
        'Yellow'   { return 50 }
        'Green'    { return 40 }
        'Cyan'     { return 30 }
        'White'    { return 20 }
        'Gray'     { return 10 }
        'DarkGray' { return 10 }
        default    { return 0 }
    }
}

function ConvertTo-DiskHealthReportRows {
    param([AllowNull()][object[]]$Records)

    $rows = [System.Collections.Generic.List[object]]::new()
    $currentText = [System.Text.StringBuilder]::new()
    $currentColor = 'DarkGray'

    foreach ($record in @($Records)) {
        $message = ''
        $noNewLine = $false
        $foregroundColor = 'DarkGray'

        if ($record -is [System.Management.Automation.InformationRecord] -and $null -ne $record.MessageData) {
            $messageData = $record.MessageData
            $message = [string]$messageData.Message
            $noNewLine = [bool]$messageData.NoNewLine
            if ($null -ne $messageData.ForegroundColor) {
                $foregroundColor = [string]$messageData.ForegroundColor
            }
        }
        else {
            $message = [string]$record
        }

        if ((Get-DiskHealthReportColorPriority -Color $foregroundColor) -gt (Get-DiskHealthReportColorPriority -Color $currentColor)) {
            $currentColor = $foregroundColor
        }

        $parts = [regex]::Split($message, "\r\n|\n|\r")
        for ($partIndex = 0; $partIndex -lt $parts.Count; $partIndex++) {
            if ($partIndex -gt 0) {
                $rows.Add([pscustomobject]@{ Text = $currentText.ToString(); Color = $currentColor })
                $null = $currentText.Clear()
                $currentColor = $foregroundColor
            }
            $null = $currentText.Append($parts[$partIndex])
        }

        if (-not $noNewLine) {
            $rows.Add([pscustomobject]@{ Text = $currentText.ToString(); Color = $currentColor })
            $null = $currentText.Clear()
            $currentColor = 'DarkGray'
        }
    }

    if ($currentText.Length -gt 0) {
        $rows.Add([pscustomobject]@{ Text = $currentText.ToString(); Color = $currentColor })
    }

    while ($rows.Count -gt 0 -and [string]::IsNullOrWhiteSpace([string]$rows[$rows.Count - 1].Text)) {
        $rows.RemoveAt($rows.Count - 1)
    }
    return @($rows)
}

function Split-DiskHealthReportText {
    param(
        [AllowEmptyString()][string]$Text,
        [int]$Width
    )

    $Width = [Math]::Max(1, $Width)
    if ([string]::IsNullOrEmpty($Text)) { return @('') }
    if ($Text.Length -le $Width) { return @($Text) }

    $leading = [regex]::Match($Text, '^\s*').Value
    if ($leading.Length -ge $Width) { $leading = '' }
    $words = @($Text.Trim() -split '\s+')
    $lines = [System.Collections.Generic.List[string]]::new()
    $line = $leading

    foreach ($originalWord in $words) {
        $word = $originalWord
        while ($word.Length -gt [Math]::Max(1, $Width - $leading.Length)) {
            if ($line.Length -gt $leading.Length) {
                $lines.Add($line)
                $line = $leading
            }
            $chunkWidth = [Math]::Max(1, $Width - $leading.Length)
            $lines.Add($leading + $word.Substring(0, $chunkWidth))
            $word = $word.Substring($chunkWidth)
        }

        $separator = if ($line.Length -gt $leading.Length) { ' ' } else { '' }
        if (($line.Length + $separator.Length + $word.Length) -gt $Width) {
            $lines.Add($line)
            $line = $leading + $word
        }
        else {
            $line += $separator + $word
        }
    }

    if ($line.Length -gt 0) { $lines.Add($line) }
    return @($lines)
}

function ConvertTo-DiskHealthCompactTableLines {
    param(
        [AllowEmptyString()][string]$Text,
        [int]$Width
    )

    $trimmed = $Text.Trim()
    if ($trimmed -match '^\+[+\-]+\+$') { return @() }
    if (-not ($trimmed.StartsWith('|') -and $trimmed.EndsWith('|'))) {
        return @(Split-DiskHealthReportText -Text $Text -Width $Width)
    }

    $cells = @($trimmed.Trim('|').Split('|') | ForEach-Object { $_.Trim() })
    if ($cells.Count -eq 6) {
        if ($cells[0] -eq 'ID') {
            return @(Split-DiskHealthReportText -Text 'SMART attributes (compact view): ID, attribute, score/current, worst, failure floor/threshold and raw/value.' -Width $Width)
        }
        $result = [System.Collections.Generic.List[string]]::new()
        foreach ($line in @(Split-DiskHealthReportText -Text "$($cells[0])  $($cells[1])" -Width $Width)) { $result.Add($line) }
        foreach ($line in @(Split-DiskHealthReportText -Text "  Score/Current $($cells[2]) | Worst $($cells[3]) | Floor/Threshold $($cells[4])" -Width $Width)) { $result.Add($line) }
        foreach ($line in @(Split-DiskHealthReportText -Text "  Raw/Value: $($cells[5])" -Width $Width)) { $result.Add($line) }
        return @($result)
    }
    if ($cells.Count -eq 2) {
        return @(Split-DiskHealthReportText -Text "$($cells[0]): $($cells[1])" -Width $Width)
    }
    return @(Split-DiskHealthReportText -Text ($cells -join ' · ') -Width $Width)
}

function Get-DiskHealthAdaptiveTableWidths {
    param(
        [int]$ColumnCount,
        [int]$Width,
        [int]$IndentLength = 2
    )

    $tableWidth = [Math]::Max(1, $Width - $IndentLength)
    $borderOverhead = (3 * $ColumnCount) + 1
    $contentBudget = $tableWidth - $borderOverhead
    if ($contentBudget -lt $ColumnCount) { return @() }

    if ($ColumnCount -eq 6) {
        # Preserve the familiar SMART columns down to 56 printable columns.
        # Shrink the descriptive fields first, then abbreviate numeric headers;
        # cell contents wrap vertically instead of changing to a card layout.
        if ($contentBudget -lt 35) { return @() }
        $shrinkPlan = @(
            [pscustomobject]@{ Index = 1; Minimum = 16 }
            [pscustomobject]@{ Index = 5; Minimum = 10 }
            [pscustomobject]@{ Index = 4; Minimum = 5 }
            [pscustomobject]@{ Index = 2; Minimum = 4 }
            [pscustomobject]@{ Index = 3; Minimum = 4 }
            [pscustomobject]@{ Index = 1; Minimum = 10 }
            [pscustomobject]@{ Index = 5; Minimum = 8 }
        )
        return @(Get-UiAdaptiveColumnWidths `
                -PreferredWidths ([int[]]@(4, 34, 7, 7, 9, 17)) `
                -ShrinkPlan $shrinkPlan `
                -ContentWidth $contentBudget)
    }

    if ($ColumnCount -eq 2) {
        if ($contentBudget -lt 20) { return @() }
        $leftWidth = [Math]::Min(34, [Math]::Max(12, [int][Math]::Floor($contentBudget * 0.62)))
        $rightWidth = $contentBudget - $leftWidth
        if ($rightWidth -lt 8) {
            $rightWidth = 8
            $leftWidth = $contentBudget - $rightWidth
        }
        return @([int]$leftWidth, [int]$rightWidth)
    }

    if ($ColumnCount -eq 1) {
        return @([Math]::Max(1, $contentBudget))
    }

    $baseWidth = [Math]::Floor($contentBudget / $ColumnCount)
    if ($baseWidth -lt 3) { return @() }
    $widths = [int[]]@(for ($index = 0; $index -lt $ColumnCount; $index++) { $baseWidth })
    $widths[$ColumnCount - 1] += $contentBudget - (($widths | Measure-Object -Sum).Sum)
    return @($widths)
}

function Get-DiskHealthAdaptiveHeaderCells {
    param(
        [Parameter(Mandatory)][string[]]$Cells,
        [Parameter(Mandatory)][int[]]$Widths
    )

    $result = [string[]]@($Cells)
    if ($Cells.Count -ne 6 -or $Cells[0] -ne 'ID') { return @($result) }

    $result[1] = 'Attribute'
    $result[2] = switch ($Cells[2]) {
        'Current' { if ($Widths[2] -ge 7) { 'Current' } else { 'Cur' } }
        'Score'   { if ($Widths[2] -ge 5) { 'Score' } else { 'Scr' } }
        default   { $Cells[2] }
    }
    $result[3] = if ($Widths[3] -ge 5) { 'Worst' } else { 'Wst' }
    $result[4] = if ($Widths[4] -ge 9 -and $Cells[4] -eq 'Threshold') { 'Threshold' } else { 'Fail' }
    $result[5] = if ($Widths[5] -ge 10 -and $Cells[5] -eq 'Vendor Raw') { 'Vendor Raw' } else { $Cells[5] }
    return @($result)
}

function ConvertTo-DiskHealthAdaptiveTableLines {
    param(
        [AllowEmptyString()][string]$Text,
        [int]$Width
    )

    $Width = [Math]::Max(1, $Width)
    if ($Text.Length -le $Width) { return @($Text) }

    $trimmed = $Text.Trim()
    $indent = [regex]::Match($Text, '^\s*').Value
    if ($indent.Length -ge $Width) { $indent = '' }

    if ($trimmed -match '^\+(?:-+\+)+$') {
        $segments = @($trimmed.Substring(1, $trimmed.Length - 2).Split('+'))
        $widths = @(Get-DiskHealthAdaptiveTableWidths -ColumnCount $segments.Count -Width $Width -IndentLength $indent.Length)
        if ($widths.Count -ne $segments.Count) {
            return @(ConvertTo-DiskHealthCompactTableLines -Text $Text -Width $Width)
        }
        return @(New-UiAdaptiveTableBorder -Widths $widths -Indent $indent)
    }

    if (-not ($trimmed.StartsWith('|') -and $trimmed.EndsWith('|'))) {
        return @(Split-DiskHealthReportText -Text $Text -Width $Width)
    }

    [string[]]$cells = @($trimmed.Trim('|').Split('|') | ForEach-Object { $_.Trim() })
    $widths = @(Get-DiskHealthAdaptiveTableWidths -ColumnCount $cells.Count -Width $Width -IndentLength $indent.Length)
    if ($widths.Count -ne $cells.Count) {
        return @(ConvertTo-DiskHealthCompactTableLines -Text $Text -Width $Width)
    }

    $isHeader = $cells.Count -eq 6 -and $cells[0] -eq 'ID'
    if ($isHeader) {
        $cells = @(Get-DiskHealthAdaptiveHeaderCells -Cells $cells -Widths $widths)
    }

    $rightAlignedColumns = if ($isHeader) { @() } else { @(2, 3, 4, 5) }
    return @(ConvertTo-UiAdaptiveTableRowLines `
            -Cells $cells `
            -Widths $widths `
            -RightAlignedColumns $rightAlignedColumns `
            -Indent $indent)
}

function Get-DiskHealthReportAnsiColor {
    param([AllowEmptyString()][string]$Color)

    switch ($Color) {
        'Red'      { return $_C.Fail }
        'Yellow'   { return $_C.Warn }
        'Green'    { return $_C.OK }
        'Cyan'     { return $_C.H1 }
        'White'    { return $_C.White }
        default    { return $_C.Dim }
    }
}

function Get-DiskHealthReportDisplayLines {
    param(
        [Parameter(Mandatory)][object[]]$Rows,
        [int]$Width,
        [int]$HorizontalOffset = 0
    )

    $Width = [Math]::Max(1, $Width)
    $displayLines = [System.Collections.Generic.List[object]]::new()
    foreach ($row in $Rows) {
        $plainText = [string]$row.Text
        $trimmedStart = $plainText.TrimStart()
        $isTableLine = $trimmedStart.StartsWith('+') -or $trimmedStart.StartsWith('|')
        $tableRenderWidth = [Math]::Max(56, $Width)
        $wrapped = if ($isTableLine) {
            @(ConvertTo-DiskHealthAdaptiveTableLines -Text $plainText -Width $tableRenderWidth)
        }
        else {
            @(Split-DiskHealthReportText -Text $plainText -Width $Width)
        }

        $ansiColor = Get-DiskHealthReportAnsiColor -Color ([string]$row.Color)
        foreach ($line in $wrapped) {
            $horizontalMaximum = if ($isTableLine) { [Math]::Max(0, ([string]$line).Length - $Width) } else { 0 }
            $visibleLine = if ($horizontalMaximum -gt 0) {
                Get-UiHorizontalSlice -Text ([string]$line) -Offset $HorizontalOffset -Width $Width
            }
            else {
                [string]$line
            }
            $displayLines.Add([pscustomobject]@{
                    PlainText         = $visibleLine
                    Text              = "$ansiColor$visibleLine$($_C.Reset)$($_C.EraseLn)"
                    HorizontalMaximum = $horizontalMaximum
                })
        }
    }
    return @($displayLines)
}

function New-DiskHealthReportFrame {
    param(
        [Parameter(Mandatory)][object[]]$Rows,
        [int]$Width,
        [int]$WindowHeight,
        [int]$ScrollOffset = 0,
        [int]$HorizontalOffset = 0,
        [AllowEmptyString()][string]$Target = '',
        [AllowEmptyString()][string]$StateMarker = ''
    )

    $Width = [Math]::Max(1, $Width)
    $WindowHeight = [Math]::Max(12, $WindowHeight)
    $contentWidth = [Math]::Max(1, $Width - 2)
    $displayLines = @(Get-DiskHealthReportDisplayLines -Rows $Rows -Width $contentWidth -HorizontalOffset $HorizontalOffset)
    $maximumHorizontalOffset = [int](@($displayLines.HorizontalMaximum | Measure-Object -Maximum).Maximum)
    $HorizontalOffset = [Math]::Max(0, [Math]::Min($HorizontalOffset, $maximumHorizontalOffset))
    $panRowCount = if ($maximumHorizontalOffset -gt 0) { 1 } else { 0 }
    # Leave one physical row unused; writing into the bottom-right cell can force
    # Windows Terminal to scroll even when every individual line fits the width.
    $visibleBudget = [Math]::Max(1, $WindowHeight - 11 - $panRowCount)
    $maximumOffset = [Math]::Max(0, $displayLines.Count - $visibleBudget)
    $ScrollOffset = [Math]::Max(0, [Math]::Min($ScrollOffset, $maximumOffset))
    $visibleEnd = [Math]::Min($displayLines.Count - 1, $ScrollOffset + $visibleBudget - 1)

    $subtitleParts = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($Target)) { $subtitleParts.Add("Target: $Target") }
    $subtitleParts.Add("$($displayLines.Count) report lines")
    if (-not [string]::IsNullOrWhiteSpace($StateMarker)) { $subtitleParts.Add($StateMarker) }

    $frame = New-UiFrame
    Add-UiFrameBanner -Frame $frame -Title 'DiskHealth Diagnostic Report' -Subtitle ($subtitleParts -join ' | ') -Width $Width
    $aboveText = if ($ScrollOffset -gt 0) { "  $(Get-UiGlyph -Name Up) $ScrollOffset more above" } else { '' }
    Add-UiFrameLine -Frame $frame -Text "$($_C.Dim)$aboveText$($_C.Reset)$($_C.EraseLn)"

    if ($displayLines.Count -eq 0) {
        Add-UiFrameLine -Frame $frame -Text "$($_C.Warn)  No diagnostic report rows were generated.$($_C.Reset)$($_C.EraseLn)"
    }
    elseif ($visibleEnd -ge $ScrollOffset) {
        for ($index = $ScrollOffset; $index -le $visibleEnd; $index++) {
            Add-UiFrameLine -Frame $frame -Text $displayLines[$index].Text
        }
    }

    $belowCount = [Math]::Max(0, $displayLines.Count - 1 - $visibleEnd)
    $belowText = if ($belowCount -gt 0) { "  $(Get-UiGlyph -Name Down) $belowCount more below" } else { '' }
    Add-UiFrameLine -Frame $frame -Text "$($_C.Dim)$belowText$($_C.Reset)$($_C.EraseLn)"
    if ($maximumHorizontalOffset -gt 0) {
        $panIndicator = New-UiHorizontalPanIndicator `
            -Offset $HorizontalOffset `
            -MaximumOffset $maximumHorizontalOffset `
            -ViewportWidth $contentWidth `
            -Width $contentWidth
        Add-UiFrameLine -Frame $frame -Text "$($_C.H2)  $panIndicator$($_C.Reset)$($_C.EraseLn)"
    }
    Add-UiFrameLine -Frame $frame
    $shortcutSegments = [System.Collections.Generic.List[object]]::new()
    if ($maximumHorizontalOffset -gt 0) {
        $shortcutSegments.Add((New-UiShortcutSegment -Text 'Left/Right' -Color $_C.White))
        $shortcutSegments.Add((New-UiShortcutSegment -Text ' pan   ' -Color $_C.Dim))
    }
    $shortcutSegments.Add((New-UiShortcutSegment -Text 'Up/Down' -Color $_C.White))
    $shortcutSegments.Add((New-UiShortcutSegment -Text ' scroll   ' -Color $_C.Dim))
    $shortcutSegments.Add((New-UiShortcutSegment -Text 'PgUp/PgDn' -Color $_C.White))
    $shortcutSegments.Add((New-UiShortcutSegment -Text ' page   ' -Color $_C.Dim))
    $shortcutSegments.Add((New-UiShortcutSegment -Text 'Home/End' -Color $_C.White))
    $shortcutSegments.Add((New-UiShortcutSegment -Text ' jump   ' -Color $_C.Dim))
    $shortcutSegments.Add((New-UiShortcutSegment -Text 'Esc' -Color $_C.Fail))
    $shortcutSegments.Add((New-UiShortcutSegment -Text ' back' -Color $_C.Dim))
    Add-UiFrameShortcutSegments -Frame $frame -Segments @($shortcutSegments) -Width $Width

    return [pscustomobject]@{
        Frame         = $frame
        DisplayLines  = $displayLines
        ScrollOffset  = $ScrollOffset
        MaximumOffset = $maximumOffset
        VisibleBudget = $visibleBudget
        HorizontalOffset = $HorizontalOffset
        MaximumHorizontalOffset = $maximumHorizontalOffset
    }
}

function Get-DiskHealthReportFramePayload {
    param(
        [Parameter(Mandatory)][System.Text.StringBuilder]$Frame,
        [switch]$ForceClear
    )

    $escape = [string][char]27
    $prefix = if ($ForceClear) { Get-TuiForceClearSequence } else { "$escape[H" }
    return "$escape[?2026h$prefix$($Frame.ToString())$escape[J$escape[?2026l"
}

function Show-DiskHealthReport {
    param(
        [Parameter(Mandatory)][object[]]$Rows,
        [AllowEmptyString()][string]$Target = ''
    )

    $firstFrameToken = Start-DiskHealthPerformanceStage -Stage 'Report.FirstRenderedFrame' -ParentStage 'Report'
    $scrollOffset = 0
    $horizontalOffset = 0
    Initialize-TuiHost
    try {
        while ($true) {
            Lock-ViewportToWindow
            try {
                $width = Get-UiWidth
                $height = $Host.UI.RawUI.WindowSize.Height
            }
            catch {
                $width = 78
                $height = 30
            }

            $view = New-DiskHealthReportFrame -Rows $Rows -Width $width -WindowHeight $height -ScrollOffset $scrollOffset -HorizontalOffset $horizontalOffset -Target $Target
            $scrollOffset = $view.ScrollOffset
            $horizontalOffset = $view.HorizontalOffset
            [Console]::Write((Get-DiskHealthReportFramePayload -Frame $view.Frame -ForceClear:$script:RequestForceClear))
            $script:RequestForceClear = $false
            if ($null -ne $firstFrameToken) {
                Complete-DiskHealthPerformanceStage -Token $firstFrameToken -Status success -ResultCount $Rows.Count
                Save-DiskHealthPerformanceReport
                $firstFrameToken = $null
            }

            $key = Read-ConsoleKey
            switch ($key.Key) {
                'UpArrow'    { $scrollOffset = [Math]::Max(0, $scrollOffset - 1) }
                'DownArrow'  { $scrollOffset = [Math]::Min($view.MaximumOffset, $scrollOffset + 1) }
                'PageUp'     { $scrollOffset = [Math]::Max(0, $scrollOffset - $view.VisibleBudget) }
                'PageDown'   { $scrollOffset = [Math]::Min($view.MaximumOffset, $scrollOffset + $view.VisibleBudget) }
                'Home'       { $scrollOffset = 0 }
                'End'        { $scrollOffset = $view.MaximumOffset }
                'LeftArrow'  { $horizontalOffset = [Math]::Max(0, $horizontalOffset - 4) }
                'RightArrow' { $horizontalOffset = [Math]::Min($view.MaximumHorizontalOffset, $horizontalOffset + 4) }
                'Escape'     { return }
                'Enter'      { return }
                'ResizeEvent' { continue }
            }
        }
    }
    finally {
        Restore-TuiHost
    }
}

function Write-DiskHealthCapturedOutput {
    param([AllowNull()][object[]]$Records)

    foreach ($record in @($Records)) {
        if ($record -is [System.Management.Automation.InformationRecord] -and $null -ne $record.MessageData) {
            $messageData = $record.MessageData
            $parameters = @{ Object = [string]$messageData.Message; NoNewline = [bool]$messageData.NoNewLine }
            if ($null -ne $messageData.ForegroundColor) { $parameters.ForegroundColor = [ConsoleColor]$messageData.ForegroundColor }
            Microsoft.PowerShell.Utility\Write-Host @parameters
        }
        else {
            Microsoft.PowerShell.Utility\Write-Host ([string]$record)
        }
    }
}

# Επιλογή ATA telemetry profile από model/firmware και, κυρίως, από το πραγματικό
# attribute layout. Το brand μόνο του δεν αρκεί: διαφορετικά Patriot/Intenso SSDs
# χρησιμοποιούν διαφορετικούς controllers και διαφορετική σημασία για τα ίδια IDs.
function Get-AtaTelemetryProfile {
    param(
        [AllowEmptyString()][string]$Model = '',
        [AllowEmptyString()][string]$Firmware = '',
        [AllowNull()][object[]]$Attributes
    )

    if ($Model -match '(?i)SAMSUNG') { return 'Samsung' }
    # Kingston publishes a model-specific SMART contract for the UV400. Its
    # 0xE7 normalized value is remaining life; the raw value is not the same
    # metric. Resolve this before the generic name-based Phison fallback.
    if ($Model -match '(?i)^\s*KINGSTON\s+SUV400S37A?(120|240|480|960)G\s*$') { return 'KingstonUV400' }
    # Do not classify every WDC/WD model as this SSD family: WD HDDs use unrelated
    # attribute layouts. WDS model numbers and explicit SanDisk/WD SSD names are
    # the reliable model hints for the shared WD/SanDisk SATA SSD mapping.
    if ($Model -match '(?i)SanDisk|(?:^|\s)WDC?\s+WDS\d|^WDS\d|WD\s+(?:Green|Blue|Red).*SSD|Western Digital.*SSD') { return 'SanDisk' }

    $ids = @{}
    $names = @{}
    $a9Raw = $null
    $e7Raw = $null
    foreach ($attribute in @($Attributes)) {
        if ($null -eq $attribute) { continue }

        $idProperty = if ($attribute.PSObject.Properties['id']) { $attribute.PSObject.Properties['id'] } elseif ($attribute.PSObject.Properties['ID']) { $attribute.PSObject.Properties['ID'] } else { $null }
        if ($null -eq $idProperty) { continue }

        $id = [int]$idProperty.Value
        $ids[$id] = $true
        $nameProperty = if ($attribute.PSObject.Properties['name']) { $attribute.PSObject.Properties['name'] } elseif ($attribute.PSObject.Properties['Name']) { $attribute.PSObject.Properties['Name'] } else { $null }
        if ($nameProperty) { $names[$id] = [string]$nameProperty.Value }
        if ($id -eq 0xA9) {
            if ($attribute.PSObject.Properties['raw'] -and $null -ne $attribute.raw) {
                if ($attribute.raw.PSObject.Properties['value']) { $a9Raw = [long]$attribute.raw.value }
                else { $a9Raw = [long]$attribute.raw }
            } elseif ($attribute.PSObject.Properties['Raw']) {
                $a9Raw = [long]$attribute.Raw
            } elseif ($attribute.PSObject.Properties['RawVal']) {
                $a9Raw = [long]$attribute.RawVal
            }
        }
        if ($id -eq 0xE7) {
            if ($attribute.PSObject.Properties['raw'] -and $null -ne $attribute.raw) {
                if ($attribute.raw.PSObject.Properties['value']) { $e7Raw = [long]$attribute.raw.value }
                else { $e7Raw = [long]$attribute.raw }
            } elseif ($attribute.PSObject.Properties['Raw']) {
                $e7Raw = [long]$attribute.Raw
            } elseif ($attribute.PSObject.Properties['RawVal']) {
                $e7Raw = [long]$attribute.RawVal
            }
        }
    }

    $hasPlausibleA9Lifetime = ($null -ne $a9Raw -and $a9Raw -ge 0 -and $a9Raw -le 100)
    $hasPlausibleE7Lifetime = ($null -ne $e7Raw -and $e7Raw -ge 0 -and $e7Raw -le 100)
    $smiOemIds = @(0xA0, 0xA1, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7, 0xA8, 0xA9, 0xB1, 0xB2)
    $smiOemMatches = @($smiOemIds | Where-Object { $ids.ContainsKey($_) }).Count
    $patriotBurstIds = @(0xA1, 0xA2, 0xA3, 0xA4, 0xA6, 0xA7, 0xA8, 0xA9, 0xAB, 0xAC, 0xAE, 0xCE, 0xCF)
    $patriotBurstMatches = @($patriotBurstIds | Where-Object { $ids.ContainsKey($_) }).Count

    if ($hasPlausibleE7Lifetime -and $names.ContainsKey(0xE7) -and $names[0xE7] -match '(?i)SSD[_ ]Life[_ ]Left|Life(?:time)?[_ ]Left') {
        return 'Phison'
    }
    if ($hasPlausibleE7Lifetime -and $Model -match '(?i)^Patriot Burst(?:\s|$)' -and $Firmware -match '(?i)^S[AB]FM') {
        return 'Phison'
    }
    if ($hasPlausibleA9Lifetime -and $patriotBurstMatches -ge 10 -and $ids.ContainsKey(0xAB) -and $ids.ContainsKey(0xAC)) {
        return 'PatriotBurst'
    }
    $hasSmiInternalWriteCounters = (
        $ids.ContainsKey(0xF1) -and
        $ids.ContainsKey(0xF2) -and
        $ids.ContainsKey(0xF5)
    )
    if (
        $hasPlausibleA9Lifetime -and
        $smiOemMatches -ge 9 -and
        $ids.ContainsKey(0xA0) -and
        ($ids.ContainsKey(0xB2) -or $hasSmiInternalWriteCounters)
    ) {
        return 'SiliconMotionOEM'
    }

    # Known model hints are accepted only together with a plausible A9 lifetime.
    if ($hasPlausibleA9Lifetime -and $Model -match '(?i)P210|Silicon Motion') {
        return 'SiliconMotionOEM'
    }
    if ($hasPlausibleA9Lifetime -and $Model -match '(?i)Patriot.*Burst') {
        return 'PatriotBurst'
    }

    return 'Generic'
}

function Get-AtaHealthEstimate {
    param(
        [Parameter(Mandatory)][Alias('Profile')][string]$TelemetryProfile,
        [Parameter(Mandatory)][object[]]$Attributes
    )

    $result = [ordered]@{
        Percentage = $null
        Source = 'No trusted vendor wear attribute'
        MetricLabel = 'Health'
        IsTrusted = $false
    }

    if ($TelemetryProfile -eq 'Samsung') {
        $wear = $Attributes | Where-Object { $_.ID -eq 0xB1 } | Select-Object -First 1
        if ($wear -and $null -ne $wear.Current -and [int]$wear.Current -ge 0 -and [int]$wear.Current -le 100) {
            $result.Percentage = [int]$wear.Current
            $result.Source = 'Wear Leveling Count (0xB1 normalized)'
            $result.IsTrusted = $true
        }
    } elseif ($TelemetryProfile -in @('SiliconMotionOEM', 'PatriotBurst')) {
        $wear = $Attributes | Where-Object { $_.ID -eq 0xA9 } | Select-Object -First 1
        if ($wear -and $null -ne $wear.Raw -and [long]$wear.Raw -ge 0 -and [long]$wear.Raw -le 100) {
            $result.Percentage = [int]$wear.Raw
            $result.Source = 'Remaining Lifetime Percentage (0xA9 raw)'
            $result.IsTrusted = $true
        }
    } elseif ($TelemetryProfile -eq 'KingstonUV400') {
        $wear = $Attributes | Where-Object { $_.ID -eq 0xE7 } | Select-Object -First 1
        if ($wear -and $null -ne $wear.Current -and [int]$wear.Current -ge 0 -and [int]$wear.Current -le 100) {
            $result.Percentage = [int]$wear.Current
            $result.Source = 'SSD Life Left (0xE7 normalized)'
            $result.IsTrusted = $true
        }
    } elseif ($TelemetryProfile -eq 'Phison') {
        $wear = $Attributes | Where-Object { $_.ID -eq 0xE7 } | Select-Object -First 1
        if ($wear -and $null -ne $wear.Raw -and [long]$wear.Raw -ge 0 -and [long]$wear.Raw -le 100) {
            $result.Percentage = [int]$wear.Raw
            $result.Source = 'SSD Life Left (0xE7 raw)'
            $result.IsTrusted = $true
        }
    } elseif ($TelemetryProfile -eq 'SanDisk') {
        $cyclesRemaining = $Attributes | Where-Object { $_.ID -eq 0xEE } | Select-Object -First 1
        $mediaWearout = $Attributes | Where-Object { $_.ID -eq 0xE6 } | Select-Object -First 1
        $reserve = $Attributes | Where-Object { $_.ID -eq 0xE8 } | Select-Object -First 1
        if (
            $cyclesRemaining -and
            $mediaWearout -and
            $null -ne $cyclesRemaining.Current -and
            [int]$cyclesRemaining.Current -ge 0 -and
            [int]$cyclesRemaining.Current -le 100
        ) {
            $result.Percentage = [int]$cyclesRemaining.Current
            $result.Source = 'Media Wearout Indicator Cycles Remaining (0xEE normalized)'
            $result.MetricLabel = 'Life'
            $result.IsTrusted = $true
        } elseif ($reserve -and $null -ne $reserve.Raw -and [long]$reserve.Raw -ge 0 -and [long]$reserve.Raw -le 100) {
            $result.Percentage = [int]$reserve.Raw
            $result.Source = 'Available Reserved Space (0xE8 raw)'
            $result.MetricLabel = 'Reserve'
            $result.IsTrusted = $true
        }
    }

    return [PSCustomObject]$result
}

function Get-AtaStandardizedEnduranceEstimate {
    param(
        [AllowNull()]$SmartData
    )

    $result = [ordered]@{
        Percentage     = $null
        UsedPercentage = $null
        Source         = 'ATA Device Statistics endurance unavailable'
        MetricLabel    = 'Life'
        IsTrusted      = $false
    }

    if ($null -eq $SmartData) {
        return [PSCustomObject]$result
    }

    $statisticsProperty = $SmartData.PSObject.Properties['ata_device_statistics']
    if ($null -eq $statisticsProperty -or $null -eq $statisticsProperty.Value) {
        return [PSCustomObject]$result
    }

    $ssdPage = @($statisticsProperty.Value.pages) |
        Where-Object { $null -ne $_.number -and [int]$_.number -eq 7 } |
        Select-Object -First 1
    if ($null -eq $ssdPage) {
        return [PSCustomObject]$result
    }

    # ATA Device Statistics page 7, offset 8 is the standardized Percentage
    # Used Endurance Indicator. Require the validity flag instead of treating
    # missing, malformed, or unsupported telemetry as zero.
    $enduranceEntry = @($ssdPage.table) |
        Where-Object { $null -ne $_.offset -and [int]$_.offset -eq 8 } |
        Select-Object -First 1
    if ($null -eq $enduranceEntry -or $null -eq $enduranceEntry.flags -or $enduranceEntry.flags.valid -ne $true) {
        return [PSCustomObject]$result
    }

    $usedPercentage = 0L
    if (-not [long]::TryParse([string]$enduranceEntry.value, [ref]$usedPercentage)) {
        return [PSCustomObject]$result
    }
    if ($usedPercentage -lt 0 -or $usedPercentage -gt 255) {
        return [PSCustomObject]$result
    }

    $result.Percentage = [int][Math]::Max(0, 100 - $usedPercentage)
    $result.UsedPercentage = [int]$usedPercentage
    $result.Source = 'ATA Device Statistics: Percentage Used Endurance'
    $result.IsTrusted = $true
    return [PSCustomObject]$result
}

function Get-AtaSmartctlDatabaseEnduranceEstimate {
    param(
        [AllowNull()]$SmartData
    )

    $result = [ordered]@{
        Percentage     = $null
        UsedPercentage = $null
        Source         = 'smartmontools drive database endurance unavailable'
        MetricLabel    = 'Life'
        IsTrusted      = $false
    }

    if ($null -eq $SmartData) {
        return [PSCustomObject]$result
    }

    # smartctl 7.5 exposes a protocol-independent endurance_used value. Trust it
    # here only when smartctl confirms a drivedb match; otherwise it may merely
    # repeat unverified device telemetry under a convenient common property.
    $databaseProperty = $SmartData.PSObject.Properties['in_smartctl_database']
    if ($null -eq $databaseProperty -or $databaseProperty.Value -ne $true) {
        return [PSCustomObject]$result
    }

    $enduranceProperty = $SmartData.PSObject.Properties['endurance_used']
    if ($null -eq $enduranceProperty -or $null -eq $enduranceProperty.Value) {
        return [PSCustomObject]$result
    }

    $currentProperty = $enduranceProperty.Value.PSObject.Properties['current_percent']
    if ($null -eq $currentProperty) {
        return [PSCustomObject]$result
    }

    $usedPercentage = 0L
    if (-not [long]::TryParse([string]$currentProperty.Value, [ref]$usedPercentage)) {
        return [PSCustomObject]$result
    }
    if ($usedPercentage -lt 0 -or $usedPercentage -gt 255) {
        return [PSCustomObject]$result
    }

    $result.Percentage = [int][Math]::Max(0, 100 - $usedPercentage)
    $result.UsedPercentage = [int]$usedPercentage
    $result.Source = 'smartmontools drive database: endurance_used'
    $result.IsTrusted = $true
    return [PSCustomObject]$result
}

function Get-WindowsStorageWearEstimate {
    param(
        [AllowNull()]$ReliabilityCounter
    )

    $result = [ordered]@{
        Percentage     = $null
        UsedPercentage = $null
        Source         = 'Windows Storage Reliability Counter wear unavailable'
        MetricLabel    = 'Life'
        IsTrusted      = $false
    }

    if ($null -eq $ReliabilityCounter) {
        return [PSCustomObject]$result
    }

    $wearProperty = $ReliabilityCounter.PSObject.Properties['Wear']
    if ($null -eq $wearProperty -or $null -eq $wearProperty.Value) {
        return [PSCustomObject]$result
    }

    $usedPercentage = 0L
    if (-not [long]::TryParse([string]$wearProperty.Value, [ref]$usedPercentage)) {
        return [PSCustomObject]$result
    }
    # Several Windows SATA drivers expose an unsupported/default Wear value as
    # zero even when ATA telemetry proves measurable wear. Without corroborating
    # evidence, zero cannot distinguish "new drive" from "not implemented".
    if ($usedPercentage -le 0 -or $usedPercentage -gt 100) {
        return [PSCustomObject]$result
    }

    $result.Percentage = [int](100 - $usedPercentage)
    $result.UsedPercentage = [int]$usedPercentage
    $result.Source = 'Windows Storage Reliability Counter: Wear'
    $result.IsTrusted = $true
    return [PSCustomObject]$result
}

function Get-AtaLifeEstimate {
    param(
        [AllowNull()]$SmartData,
        [Parameter(Mandatory)][Alias('Profile')][string]$TelemetryProfile,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Attributes,
        [AllowNull()]$ReliabilityCounter
    )

    $vendor = if (@($Attributes).Count -gt 0) {
        Get-AtaHealthEstimate -Profile $TelemetryProfile -Attributes $Attributes
    } else {
        [PSCustomObject]@{ Percentage = $null; Source = ''; MetricLabel = 'Life'; IsTrusted = $false }
    }

    $standardized = Get-AtaStandardizedEnduranceEstimate -SmartData $SmartData
    if ($standardized.IsTrusted) {
        if ($vendor.IsTrusted -and $vendor.MetricLabel -eq 'Life') {
            $difference = [Math]::Abs([int]$standardized.Percentage - [int]$vendor.Percentage)
            if ($difference -le 5) {
                $selectedPercentage = [Math]::Min([int]$standardized.Percentage, [int]$vendor.Percentage)
                return [PSCustomObject]@{
                    Percentage = $selectedPercentage
                    UsedPercentage = [int]$standardized.UsedPercentage
                    Source = "Conservative agreement: $($standardized.Source)=$($standardized.Percentage)%, $($vendor.Source)=$($vendor.Percentage)%"
                    MetricLabel = 'Life'
                    IsTrusted = $true
                }
            }
            return [PSCustomObject]@{
                Percentage = $null
                UsedPercentage = [int]$standardized.UsedPercentage
                Source = "Conflicting SSD lifetime readings: $($standardized.Source)=$($standardized.Percentage)%, $($vendor.Source)=$($vendor.Percentage)%"
                MetricLabel = 'Life'
                IsTrusted = $false
            }
        }
        $standardized.Source = "$($standardized.Source) ($($standardized.UsedPercentage)% used)"
        return $standardized
    }

    $database = Get-AtaSmartctlDatabaseEnduranceEstimate -SmartData $SmartData
    if ($database.IsTrusted) {
        $database.Source = "$($database.Source) ($($database.UsedPercentage)% used)"
        return $database
    }

    if ($vendor.IsTrusted) {
        return $vendor
    }

    $windows = Get-WindowsStorageWearEstimate -ReliabilityCounter $ReliabilityCounter
    if ($windows.IsTrusted) {
        $windows.Source = "$($windows.Source) ($($windows.UsedPercentage)% used)"
        return $windows
    }

    return [PSCustomObject]@{
        Percentage  = $null
        Source      = 'No trustworthy SSD lifetime reading was available'
        MetricLabel = 'Life'
        IsTrusted   = $false
    }
}

function Get-AtaDataTransferEstimate {
    param(
        [Parameter(Mandatory)][Alias('Profile')][string]$TelemetryProfile,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Attributes,
        [AllowNull()]$SmartData
    )

    $result = [ordered]@{
        HostReadsGiB  = $null
        HostWritesGiB = $null
        NandWritesGiB = $null
        WriteAmplification = $null
        Source = 'No verified counter-unit mapping'
        IsSupported = $false
    }

    if (@($Attributes).Count -eq 0) {
        return [PSCustomObject]$result
    }

    $f1 = $Attributes | Where-Object { $_.ID -eq 0xF1 } | Select-Object -First 1
    $f2 = $Attributes | Where-Object { $_.ID -eq 0xF2 } | Select-Object -First 1
    $f5 = $Attributes | Where-Object { $_.ID -eq 0xF5 } | Select-Object -First 1

    switch ($TelemetryProfile) {
        'SiliconMotionOEM' {
            # Silicon Motion OEM/SM2258 family counters are expressed in 32 MiB
            # units. This is the layout used by the ADATA DM900 and related
            # controller families, rather than an exact-model exception.
            if ($f1) { $result.HostWritesGiB = [Math]::Round(([double]$f1.Raw * 32 / 1024), 2) }
            if ($f2) { $result.HostReadsGiB = [Math]::Round(([double]$f2.Raw * 32 / 1024), 2) }
            if ($f5) { $result.NandWritesGiB = [Math]::Round(([double]$f5.Raw * 32 / 1024), 2) }
            $result.Source = 'Silicon Motion OEM F1/F2/F5 (32 MiB units)'
        }
        'KingstonUV400' {
            if ($f1) { $result.HostWritesGiB = [Math]::Round([double]$f1.Raw, 2) }
            if ($f2) { $result.HostReadsGiB = [Math]::Round([double]$f2.Raw, 2) }
            $result.Source = 'Kingston UV400 F1/F2 (GiB)'
        }
        'Phison' {
            if ($f1) { $result.HostWritesGiB = [Math]::Round([double]$f1.Raw, 2) }
            $result.Source = 'Phison F1 Lifetime_Writes_GiB'
        }
        'SanDisk' {
            $logicalBlockSize = 0L
            $blockSizeProperty = if ($null -ne $SmartData) { $SmartData.PSObject.Properties['logical_block_size'] } else { $null }
            $hasLogicalBlockSize = (
                $null -ne $blockSizeProperty -and
                [long]::TryParse([string]$blockSizeProperty.Value, [ref]$logicalBlockSize) -and
                $logicalBlockSize -ge 512 -and
                $logicalBlockSize -le 4096 -and
                ($logicalBlockSize -band ($logicalBlockSize - 1)) -eq 0
            )
            if ($hasLogicalBlockSize) {
                if ($f1) { $result.HostWritesGiB = [Math]::Round(([decimal]$f1.Raw * $logicalBlockSize / 1GB), 2) }
                if ($f2) { $result.HostReadsGiB = [Math]::Round(([decimal]$f2.Raw * $logicalBlockSize / 1GB), 2) }
            }
            $nandTlc = $Attributes | Where-Object { $_.ID -eq 0xE9 } | Select-Object -First 1
            $nandSlc = $Attributes | Where-Object { $_.ID -eq 0xEA } | Select-Object -First 1
            if ($nandTlc -or $nandSlc) {
                $result.NandWritesGiB = [Math]::Round(
                    $(if ($nandTlc) { [double]$nandTlc.Raw } else { 0 }) +
                    $(if ($nandSlc) { [double]$nandSlc.Raw } else { 0 }),
                    2
                )
            }
            $result.Source = if ($hasLogicalBlockSize) {
                "SanDisk/WD F1/F2 (LBAs x $logicalBlockSize bytes) and E9/EA (GiB)"
            } else {
                'SanDisk/WD E9/EA only; F1/F2 LBA conversion requires logical block size'
            }
        }
        'PatriotBurst' {
            $nandF9 = $Attributes | Where-Object { $_.ID -eq 0xF9 } | Select-Object -First 1
            if ($nandF9) { $result.NandWritesGiB = [Math]::Round([double]$nandF9.Raw, 2) }
            $result.Source = 'Patriot Burst F9 NAND writes (GiB)'
        }
    }

    if ($null -ne $result.HostWritesGiB -and $result.HostWritesGiB -gt 0 -and $null -ne $result.NandWritesGiB) {
        $result.WriteAmplification = [Math]::Round($result.NandWritesGiB / $result.HostWritesGiB, 2)
    }
    $result.IsSupported = [bool](
        $null -ne $result.HostReadsGiB -or
        $null -ne $result.HostWritesGiB -or
        $null -ne $result.NandWritesGiB
    )
    return [PSCustomObject]$result
}

# Λογική επίλυσης ονομάτων attributes ανάλογα με το επιβεβαιωμένο controller profile
function Get-AttributeName {
    param(
        [int]$id,
        [string]$brand
    )
    if ($brand -eq 'KingstonUV400') {
        # Kingston SUV400S37 SMART Attribute Details (MKP-521.3). IDs omitted
        # from that vendor specification remain visible but deliberately opaque.
        switch ($id) {
            0x01 { return "Read Error Rate" }
            0x05 { return "Reallocated Sector Count" }
            0x09 { return "Power On Hours" }
            0x0C { return "Power Cycle Count" }
            0xAA { return "Used Reserved Block Count" }
            0xAB { return "Program Fail Count" }
            0xAC { return "Erase Fail Count" }
            0xAE { return "Unexpected Power Off Count" }
            0xAF { return "Program Fail Count Worst Die" }
            0xB0 { return "Erase Fail Count Worst Die" }
            0xB2 { return "Used Reserved Block Count Worst Die" }
            0xB4 { return "Unused Reserved Block Count (SSD Total)" }
            0xBB { return "Reported Uncorrectable Errors" }
            0xC2 { return "Temperature" }
            0xC3 { return "On-the-Fly ECC Error Event Count" }
            0xC4 { return "Reallocation Event Count" }
            0xC5 { return "Pending Sector Count" }
            0xC7 { return "UDMA CRC Error Count" }
            0xC9 { return "Uncorrectable Read Error Rate" }
            0xCC { return "Soft ECC Correction Rate" }
            0xE7 { return "SSD Life Left" }
            0xF1 { return "GB Written from Interface" }
            0xF2 { return "GB Read from Interface" }
            0xFA { return "Total Number of NAND Read Retries" }
            default { return "Vendor-specific (not in Kingston spec)" }
        }
    }
    elseif ($brand -eq "Samsung") {
        switch ($id) {
            0xAF { return "Program Fail Count (Chip)" }
            0xB0 { return "Erase Fail Count (Chip)" }
            0xB1 { return "Wear Leveling Count" }
            0xB2 { return "Used Reserved Block Count (Chip)" }
            0xB3 { return "Used Reserved Block Count (Total)" }
            0xB4 { return "Available Reserved Blocks (Total)" }
            0xB7 { return "Runtime Bad Block (Total)" }
            0xC3 { return "ECC Error Rate" }
            0xEA { return "Total GB Written to NAND" }
            0xEB { return "POR Recovery Count" }
            0xEC { return "Manufacturer Specific (EC)" }
            0xED { return "Manufacturer Specific (ED)" }
            0xEE { return "Manufacturer Specific (EE)" }
        }
    }
    elseif ($brand -eq 'SiliconMotionOEM') {
        switch ($id) {
            0x94 { return "SLC Total Erase Count" }
            0x95 { return "SLC Maximum Erase Count" }
            0x96 { return "SLC Minimum Erase Count" }
            0x97 { return "SLC Average Erase Count" }
            0xA0 { return "Uncorrectable Error Count" }
            0xA1 { return "Valid Spare Block Count" }
            0xA3 { return "Initial Bad Block Count" }
            0xA4 { return "Total Erase Count" }
            0xA5 { return "Maximum Erase Count" }
            0xA6 { return "Minimum Erase Count" }
            0xA7 { return "Average Erase Count" }
            0xA8 { return "Maximum Erase Count of Spec" }
            0xA9 { return "Remaining Lifetime Percentage" }
            0xAF { return "Program Fail Count (Worst Die)" }
            0xB0 { return "Erase Fail Count (Worst Die)" }
            0xB1 { return "Total Wear Level Count" }
            0xB2 { return "Runtime Invalid Block Count" }
            0xF1 { return "Host Writes (32 MiB)" }
            0xF2 { return "Host Reads (32 MiB)" }
            0xF5 { return "TLC Writes (32 MiB)" }
        }
    }
    elseif ($brand -eq 'PatriotBurst') {
        switch ($id) {
            0xA1 { return "GDN" }
            0xA2 { return "Total Erase Count" }
            0xA3 { return "Max PE Cycle" }
            0xA4 { return "Average Erase Count" }
            0xA6 { return "Total Bad Block Count" }
            0xA7 { return "SSD Protect Mode" }
            0xA8 { return "SATA PHY Error Count" }
            0xA9 { return "Health / Remaining Lifetime" }
            0xAB { return "Program Fail Count" }
            0xAC { return "Erase Fail Count" }
            0xAE { return "Unexpected Power Loss Count" }
            0xAF { return "ECC Fail Count" }
            0xBB { return "Reported Uncorrectable Errors" }
            0xC2 { return "Enclosure Temperature" }
            0xC3 { return "Cumulative Corrected ECC" }
            0xCE { return "Minimum Erase Count" }
            0xCF { return "Maximum Erase Count" }
            0xE8 { return "Available Reserved Space" }
            0xF1 { return "Write Life Time" }
            0xF2 { return "Read Life Time" }
            0xF9 { return "Total GB Written to NAND (TLC)" }
        }
    }
    elseif ($brand -eq 'Phison') {
        switch ($id) {
            0xA8 { return "SATA PHY Error Count" }
            0xAA { return "Bad Block Count (Later/Early)" }
            0xAD { return "Maximum/Average Erase Count" }
            0xC0 { return "Unsafe Shutdown Count" }
            0xDA { return "CRC Error Count" }
            0xE7 { return "SSD Life Left" }
            0xF1 { return "Lifetime Writes (GiB)" }
        }
    }
    elseif ($brand -eq "SanDisk") {
        switch ($id) {
            0xA5 { return "Block Erase Count" }
            0xA6 { return "Minimum P/E Cycles (TLC)" }
            0xA7 { return "Max Bad Blocks per Die" }
            0xA8 { return "Maximum P/E Cycles (TLC)" }
            0xA9 { return "Total Bad Blocks" }
            0xAA { return "Grown Bad Blocks" }
            0xAB { return "Program Fail Count" }
            0xAC { return "Erase Fail Count" }
            0xAD { return "Average P/E Cycles (TLC)" }
            0xAE { return "Unexpected Power Loss Count" }
            0xE6 { return "Media Wearout Indicator" }
            0xE8 { return "Available Reserved Space" }
            0xE9 { return "NAND GB Written (TLC)" }
            0xEA { return "NAND GB Written (SLC)" }
            0xEE { return "Media Wearout Cycles Remaining" }
            0xF1 { return "Host Writes (LBAs)" }
            0xF2 { return "Host Reads (LBAs)" }
            0xF4 { return "Temperature Throttle Status" }
        }
    }
    elseif ($brand -eq "NVMe") {
        switch ($id) {
            0x01 { return "Critical Warning" }
            0x02 { return "Composite Temperature" }
            0x03 { return "Available Spare" }
            0x04 { return "Available Spare Threshold" }
            0x05 { return "Percentage Used" }
            0x06 { return "Data Units Read" }
            0x07 { return "Data Units Written" }
            0x08 { return "Host Read Commands" }
            0x09 { return "Host Write Commands" }
            0x0A { return "Controller Busy Time" }
            0x0B { return "Power Cycles" }
            0x0C { return "Power On Hours" }
            0x0D { return "Unsafe Shutdowns" }
            0x0E { return "Media and Data Integrity Errors" }
            0x0F { return "Number of Error Information Log Entries" }
            0x10 { return "Warning Composite Temperature Time" }
            0x11 { return "Critical Composite Temperature Time" }
            0x12 { return "Temperature Sensor 1" }
            0x13 { return "Temperature Sensor 2" }
        }
    }

    # Generic / Standard fallback
    switch ($id) {
        0x01 { return "Raw Read Error Rate" }
        0x05 { return "Reallocated Sectors Count" }
        0x09 { return "Power-On Hours" }
        0x0C { return "Power Cycle Count" }
        0xB5 { return "Program Fail Count (Total)" }
        0xB6 { return "Erase Fail Count (Total)" }
        0xB8 { return "End-to-End Error / Error Detection" }
        0xBB { return "Uncorrectable Errors" }
        0xBC { return "Command Timeout" }
        0xBE { return "Airflow Temperature" }
        0xC2 { return "Temperature" }
        0xC4 { return "Reallocation Event Count" }
        0xC5 { return "Current Pending Sector Count" }
        0xC6 { return "Offline Uncorrectable Error Count" }
        0xC7 { return "UltraDMA CRC Error Count" }
        0xE9 { return "Normalized Media Wear-out" }
        default { return "Unknown Attribute" }
    }
}

function Test-AtaRawWarningAttribute {
    param(
        [Parameter(Mandatory)][Alias('Profile')][string]$TelemetryProfile,
        [Parameter(Mandatory)][int]$AttributeId
    )

    $commonErrorIds = @(0x05, 0xB8, 0xBB, 0xBC, 0xC4, 0xC5, 0xC6)
    if ($AttributeId -in $commonErrorIds) { return $true }

    switch ($TelemetryProfile) {
        'Samsung'         { return $AttributeId -eq 0xB7 }
        'SiliconMotionOEM'{ return $AttributeId -in @(0xA0, 0xB2) }
        'PatriotBurst'    { return $AttributeId -in @(0xAB, 0xAC) }
        'KingstonUV400'   { return $AttributeId -in @(0xAB, 0xAC) }
        'SanDisk'         { return $AttributeId -in @(0xAA, 0xAB, 0xAC) }
        default           { return $false }
    }
}

Write-Host "`n======================================================================" -ForegroundColor $Cyan
Write-Host "  💾 ΔΙΑΓΝΩΣΤΙΚΟ ΥΓΕΙΑΣ ΔΙΣΚΩΝ (Disk Health Diagnostics)" -ForegroundColor $Cyan
Write-Host "======================================================================" -ForegroundColor $Cyan

# 2. Συλλογή Δεδομένων (WMI/WinRM ή File Import)
$collected = @()

if ($FilePath) {
    Write-Host "  📁 Ανάλυση Αρχείου Report: " -NoNewline -ForegroundColor $White
    Write-Host "$FilePath" -ForegroundColor $Yellow
    Write-Host "----------------------------------------------------------------------" -ForegroundColor $Cyan

    if (-not (Test-Path $FilePath)) {
        Write-Host "❌ Το αρχείο δεν βρέθηκε στο μονοπάτι $FilePath" -ForegroundColor $Red
        return
    }

    $lines = Get-Content -Path $FilePath
    $model = ""
    $firmware = ""
    $sn = ""
    $sizeBytes = 0
    $hours = 0
    $cycles = 0
    $temp = 0
    $healthVal = 100
    $healthText = "GOOD"
    $interface = "SATA"
    $standard = ""
    $transferMode = ""
    $rotationRate = ""
    $smartLines = @()

    $inSmart = $false
    foreach ($line in $lines) {
        if ($line -match "Model\s+:\s+(.+)") { $model = $Matches[1].Trim() }
        elseif ($line -match "Firmware\s+:\s+(.+)") { $firmware = $Matches[1].Trim() }
        elseif ($line -match "Serial Number\s+:\s+(.+)") { $sn = $Matches[1].Trim() }
        elseif ($line -match "Interface\s+:\s+(.+)") { $interface = $Matches[1].Trim() }
        elseif ($line -match "Standard\s+:\s+(.+)") { $standard = $Matches[1].Trim() }
        elseif ($line -match "Transfer Mode\s+:\s+(.+)") { $transferMode = $Matches[1].Trim() }
        elseif ($line -match "Rotation Rate\s+:\s+(.+)") { $rotationRate = $Matches[1].Trim() }
        elseif ($line -match "Disk Size\s+:\s+([0-9,.]+)\s+GB") {
            $cleanSize = $Matches[1] -replace ',', '.'
            $sizeBytes = [double]$cleanSize * 1GB
        }
        elseif ($line -match "Power On Hours\s+:\s+(\d+)") { $hours = [int]$Matches[1] }
        elseif ($line -match "Power On Count\s+:\s+(\d+)") { $cycles = [int]$Matches[1] }
        elseif ($line -match "Temperature\s+:\s+(\d+)\s+C") { $temp = [int]$Matches[1] }
        elseif ($line -match "Health Status\s+:\s+(.+?)\s+\((\d+)\s+%\)") {
            $healthVal = [int]$Matches[2]
            $healthText = $Matches[1].Trim()
        }
        elseif ($line -match "-- S.M.A.R.T. --") {
            $inSmart = $true
            continue
        }
        elseif ($inSmart -and ($line -match "^--+" -or $line -match "^[A-Z_]+$")) {
            $inSmart = $false
        }
        elseif ($inSmart -and ($line -match "^([0-9A-F]{2})\s+([0-9_]+)\s+([0-9_]+)\s+([0-9_]+)\s+([0-9A-F]{12})\s+(.*)")) {
            $smartLines += [PSCustomObject]@{
                IDHex = "0x" + $Matches[1]
                ID = [int]("0x" + $Matches[1])
                Current = [int]($Matches[2] -replace '_', '')
                Worst = [int]($Matches[3] -replace '_', '')
                Threshold = [int]($Matches[4] -replace '_', '')
                RawVal = [System.Convert]::ToUInt64($Matches[5], 16)
                RawHex = "0x" + $Matches[5]
                Name = $Matches[6].Trim()
                IsNVMe = $false
            }
        }
        elseif ($inSmart -and ($line -match "^([0-9A-F]{2})\s+([0-9A-F]{12})\s+(.*)")) {
            $smartLines += [PSCustomObject]@{
                IDHex = "0x" + $Matches[1]
                ID = [int]("0x" + $Matches[1])
                Current = 100
                Worst = 100
                Threshold = 0
                RawVal = [System.Convert]::ToUInt64($Matches[2], 16)
                RawHex = "0x" + $Matches[2]
                Name = $Matches[3].Trim()
                IsNVMe = $true
            }
        }
    }

    $collected += [PSCustomObject]@{
        Index = 0
        Model = $model
        SerialNumber = $sn
        Size = $sizeBytes
        InterfaceType = $interface
        PNPDeviceID = "FILE_IMPORT"
        MediaType = "SSD"
        BusType = if ($interface -like "*NVM*" -or $interface -like "*Express*") { "NVMe" } else { "SATA" }
        Firmware = $firmware
        Letters = @("C:")
        SMARTData = $null
        SMARTThresholds = $null
        IsAdmin = $true
        ParsedAttributes = $smartLines
        ImportedFromFile = $true
        ReliabilityCounter = $null
        SmartctlJSON = $null
        Standard = $standard
        TransferMode = $transferMode
        RotationRate = $rotationRate
    }
} else {
    # Σύνδεση & WMI Query
    $isLocal = ($ComputerName -eq "localhost" -or $ComputerName -eq "127.0.0.1")
    if ($isLocal) {
        Write-Host "  💻 Στόχος: Τοπικός υπολογιστής (localhost)" -ForegroundColor $White
    } else {
        if ($isLocal) {
            Write-Host "  💻 Στόχος: Τοπικός υπολογιστής (localhost)" -ForegroundColor $White
        } else {
            Write-Host "  🌐 Στόχος: $ComputerName (Χρήστης: $Username)" -ForegroundColor $White
        }
    }
    Write-Host "  🔧 Μέθοδος: Native smartctl & WMI/CIM Queries" -ForegroundColor $White
    Write-Host "----------------------------------------------------------------------" -ForegroundColor $Cyan

    $operationWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $connectionAliases = @(
        @($ComputerName, $ConnectionDisplayName) |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique
    )
    if (-not $isLocal) {
        Import-DiskHealthWinRMConnection
        try {
            Import-DiskHealthWinRMDiscovery -StateRoot $DiscoveryStateRoot
            if ([string]::IsNullOrWhiteSpace($ConnectionNetworkId)) {
                $identityToken = Start-DiskHealthPerformanceStage -Stage 'History.NetworkIdentity.Connection' -ParentStage 'Network.Authentication'
                $ConnectionNetworkId = (Get-WinRMNetworkIdentity).NetworkId
                Complete-DiskHealthPerformanceStage -Token $identityToken -Status success -ResultCount 1
            }
            $historyToken = Start-DiskHealthPerformanceStage -Stage 'History.ConnectionLookup' -ParentStage 'Network.Authentication'
            $matchingHistory = Get-WinRMConnectionHistory -NetworkId $ConnectionNetworkId |
                Where-Object {
                    $_.ComputerName -eq $ComputerName -or
                    $_.LastIPAddress -eq $ComputerName -or
                    $_.ComputerName -eq $ConnectionDisplayName
                } |
                Select-Object -First 1
            Complete-DiskHealthPerformanceStage -Token $historyToken -Status success -ResultCount ([int]($null -ne $matchingHistory))
            if ($matchingHistory) {
                $connectionAliases = @(
                    @($connectionAliases) + @(
                        $matchingHistory.ComputerName
                        $matchingHistory.LastIPAddress
                    ) |
                        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                        Select-Object -Unique
                )
                if ($Username -eq 'user' -and -not [string]::IsNullOrWhiteSpace($matchingHistory.UserName) -and $matchingHistory.UserName -ne 'Unknown') {
                    $Username = $matchingHistory.UserName
                }
            }
            if ($null -eq $Credential -and [string]::IsNullOrWhiteSpace($Password)) {
                Show-DiskHealthPerformanceProgress -Stage 'Credential.DPAPILookup' -Message 'Checking the network-scoped encrypted profile.'
                $credentialLookupToken = Start-DiskHealthPerformanceStage -Stage 'Credential.DPAPILookup.Connection' -ParentStage 'Network.Authentication'
                $Credential = Get-DiskHealthStoredCredential -NetworkId $ConnectionNetworkId -ComputerNames $connectionAliases
                Complete-DiskHealthPerformanceStage -Token $credentialLookupToken -Status success -ResultCount ([int]($null -ne $Credential))
                if ($Credential) {
                    $CredentialFromSavedProfile = $true
                    $Username = $Credential.UserName
                    Write-Host "  🔐 Χρήση αποθηκευμένων DPAPI credentials για $Username." -ForegroundColor Green
                }
            }
        } catch {
            $historyCategory = Get-DiskHealthPerformanceErrorCategory $_
            if ($null -ne $historyToken -and $historyToken.Watch.IsRunning) {
                Complete-DiskHealthPerformanceStage -Token $historyToken -Status failure -ErrorCategory $historyCategory
            }
            Write-Host "  ⚠️ Δεν φορτώθηκε το connection history: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    if ($Credential) {
        $cred = $Credential
        $Username = $cred.UserName
    } elseif (-not $isLocal -and [string]::IsNullOrEmpty($Password)) {
        $cred = New-WinRMBlankPasswordCredential -UserName $Username
    } else {
        $secstr = New-Object System.Security.SecureString
        if ($Password) {
            foreach ($char in $Password.ToCharArray()) {
                $secstr.AppendChar($char)
            }
        }
        $cred = New-Object System.Management.Automation.PSCredential($Username, $secstr)
    }

    $scriptBlock = {
        param([bool]$BenchmarkEnabled)

        function Get-SmartctlWindowsDeviceIndex {
            param(
                [AllowNull()]
                [string]$DeviceName
            )

            if ([string]::IsNullOrWhiteSpace($DeviceName)) {
                return $null
            }

            if ($DeviceName -match '^/dev/pd(\d+)$' -or $DeviceName -match '^\\\\\.\\PhysicalDrive(\d+)$') {
                return [int]$Matches[1]
            }

            if ($DeviceName -notmatch '^/dev/sd([a-z]+)$') {
                return $null
            }

            # smartmontools for Windows maps /dev/sda to PhysicalDrive0,
            # /dev/sdz to PhysicalDrive25, /dev/sdaa to PhysicalDrive26, etc.
            $oneBasedIndex = 0
            foreach ($character in $Matches[1].ToCharArray()) {
                $oneBasedIndex = ($oneBasedIndex * 26) + ([int]$character - [int][char]'a' + 1)
            }

            return $oneBasedIndex - 1
        }

        function Test-SmartctlTelemetryPayload {
            param([AllowNull()]$Payload)

            return [bool](
                $Payload -and
                ($Payload.ata_smart_attributes -or $Payload.nvme_smart_health_information_log)
            )
        }

        function Test-SmartctlAtaLifeEvidence {
            param([AllowNull()]$Payload)

            if ($null -eq $Payload) {
                return $false
            }

            $statisticsProperty = $Payload.PSObject.Properties['ata_device_statistics']
            if ($null -ne $statisticsProperty -and $null -ne $statisticsProperty.Value) {
                $ssdPage = @($statisticsProperty.Value.pages) |
                    Where-Object { $null -ne $_.number -and [int]$_.number -eq 7 } |
                    Select-Object -First 1
                if ($null -ne $ssdPage) {
                    $enduranceEntry = @($ssdPage.table) |
                        Where-Object { $null -ne $_.offset -and [int]$_.offset -eq 8 } |
                        Select-Object -First 1
                    if ($null -ne $enduranceEntry -and $null -ne $enduranceEntry.flags -and $enduranceEntry.flags.valid -eq $true) {
                        return $true
                    }
                }
            }

            $databaseProperty = $Payload.PSObject.Properties['in_smartctl_database']
            $enduranceProperty = $Payload.PSObject.Properties['endurance_used']
            return [bool](
                $null -ne $databaseProperty -and
                $databaseProperty.Value -eq $true -and
                $null -ne $enduranceProperty -and
                $null -ne $enduranceProperty.Value -and
                $null -ne $enduranceProperty.Value.PSObject.Properties['current_percent']
            )
        }

        function Get-SmartctlHealthArguments {
            param(
                [Parameter(Mandatory)][string]$Device,
                [AllowEmptyString()][string]$DeviceType = 'auto',
                [switch]$RequestAtaSsdStatistics
            )

            $nativeArguments = @('-a')
            if ($RequestAtaSsdStatistics) {
                # Page 7 is the standardized ATA Solid State Device Statistics
                # page. It adds the endurance indicator without the broader
                # log collection performed by smartctl -x.
                $nativeArguments += @('-l', 'ssd')
            }
            if (-not [string]::IsNullOrWhiteSpace($DeviceType) -and $DeviceType -ne 'auto') {
                $nativeArguments += @('-d', $DeviceType)
            }
            $nativeArguments += @($Device, '--json')
            return $nativeArguments
        }

        function Get-KnownUsbNvmeBridgeType {
            param(
                [AllowNull()]
                [string[]]$InstanceIds
            )

            foreach ($instanceId in @($InstanceIds)) {
                if ($instanceId -notmatch '^USB\\VID_([0-9A-F]{4})&PID_([0-9A-F]{4})(?:\\|$)') {
                    continue
                }

                $usbId = "$($Matches[1]):$($Matches[2])".ToUpperInvariant()
                switch ($usbId) {
                    '152D:0581' {
                        return [PSCustomObject]@{
                            UsbId = $usbId
                            SmartctlType = 'sntjmicron'
                            Description = 'JMicron JMS583-compatible USB-to-NVMe bridge'
                        }
                    }
                }
            }

            return $null
        }

        $collectorStartUtc = [datetime]::UtcNow
        $collectorWatch = [System.Diagnostics.Stopwatch]::StartNew()
        $benchmarkRows = [System.Collections.Generic.List[object]]::new()

        function Add-CollectorBenchmark {
            param(
                [string]$Phase,
                [System.Diagnostics.Stopwatch]$Watch,
                [datetime]$StartUtc = [datetime]::UtcNow,
                [string]$ParentStage = 'Collector.Total',
                [ValidateSet('success', 'failure', 'timeout', 'skipped')][string]$Status = 'success',
                [AllowNull()]$AttemptCount = $null,
                [AllowNull()]$ResultCount = $null,
                [string]$ErrorCategory = '',
                [string]$Details = ''
            )
            if ($BenchmarkEnabled) {
                $endUtc = [datetime]::UtcNow
                $benchmarkRows.Add([PSCustomObject]@{
                    Phase         = $Phase
                    ParentStage   = $ParentStage
                    StartUtc      = $StartUtc
                    EndUtc        = $endUtc
                    Milliseconds  = $Watch.Elapsed.TotalMilliseconds
                    Status        = $Status
                    AttemptCount  = $AttemptCount
                    ResultCount   = $ResultCount
                    ErrorCategory = $ErrorCategory
                    Details       = $Details
                })
            }
        }

        $inventoryStartUtc = [datetime]::UtcNow
        $inventoryWatch = [System.Diagnostics.Stopwatch]::StartNew()
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        $queryStart = [datetime]::UtcNow; $queryWatch = [System.Diagnostics.Stopwatch]::StartNew()
        $disks = Get-CimInstance -ClassName Win32_DiskDrive
        $queryWatch.Stop(); Add-CollectorBenchmark -Phase 'Collector.CIM.Win32DiskDrive' -Watch $queryWatch -StartUtc $queryStart -ResultCount (@($disks).Count)
        $queryStart = [datetime]::UtcNow; $queryWatch = [System.Diagnostics.Stopwatch]::StartNew()
        $physicalDisks = Get-PhysicalDisk -ErrorAction SilentlyContinue
        $queryWatch.Stop(); Add-CollectorBenchmark -Phase 'Collector.Storage.PhysicalDisk' -Watch $queryWatch -StartUtc $queryStart -ResultCount (@($physicalDisks).Count)
        $queryStart = [datetime]::UtcNow; $queryWatch = [System.Diagnostics.Stopwatch]::StartNew()
        $allData = Get-CimInstance -ClassName MSStorageDriver_FailurePredictData -Namespace root\wmi -ErrorAction SilentlyContinue
        $queryWatch.Stop(); Add-CollectorBenchmark -Phase 'Collector.WMI.FailurePredictData' -Watch $queryWatch -StartUtc $queryStart -ResultCount (@($allData).Count)
        $queryStart = [datetime]::UtcNow; $queryWatch = [System.Diagnostics.Stopwatch]::StartNew()
        $allThresholds = Get-CimInstance -ClassName MSStorageDriver_FailurePredictThresholds -Namespace root\wmi -ErrorAction SilentlyContinue
        $queryWatch.Stop(); Add-CollectorBenchmark -Phase 'Collector.WMI.FailurePredictThresholds' -Watch $queryWatch -StartUtc $queryStart -ResultCount (@($allThresholds).Count)
        $queryStart = [datetime]::UtcNow; $queryWatch = [System.Diagnostics.Stopwatch]::StartNew()
        $partitions = Get-CimInstance -ClassName Win32_DiskPartition
        $queryWatch.Stop(); Add-CollectorBenchmark -Phase 'Collector.CIM.Win32DiskPartition' -Watch $queryWatch -StartUtc $queryStart -ResultCount (@($partitions).Count)
        $queryStart = [datetime]::UtcNow; $queryWatch = [System.Diagnostics.Stopwatch]::StartNew()
        $logicalToPart = Get-CimInstance -ClassName Win32_LogicalDiskToPartition
        $queryWatch.Stop(); Add-CollectorBenchmark -Phase 'Collector.CIM.LogicalDiskMapping' -Watch $queryWatch -StartUtc $queryStart -ResultCount (@($logicalToPart).Count)
        $inventoryWatch.Stop()
        if ($BenchmarkEnabled) {
            $benchmarkRows.Add([PSCustomObject]@{
                Phase         = 'Collector.Inventory'
                ParentStage   = 'Collector.Total'
                StartUtc      = $inventoryStartUtc
                EndUtc        = [datetime]::UtcNow
                Milliseconds  = $inventoryWatch.Elapsed.TotalMilliseconds
                Status        = 'success'
                AttemptCount  = 1
                ResultCount   = @($disks).Count
                ErrorCategory = ''
                Details       = "$(@($disks).Count) disks"
            })
        }

        # Reliability counters are queried lazily only when NVMe smartctl data
        # is unavailable. USB bridges may block this call for tens of seconds.
        $reliabilityCounters = @{}

        # smartctl scanning is also lazy and shared across all disks.
        $smartctlScanLoaded = $false
        $smartctlScanData = $null
        $smartctlScanSummary = @()

        # Ανίχνευση του smartctl
        $smartctlPath = $null
        $smartctlCmd = Get-Command smartctl -ErrorAction SilentlyContinue
        if ($smartctlCmd) {
            $smartctlPath = $smartctlCmd.Source
        } else {
            $commonPaths = @(
                "C:\Program Files\smartmontools\bin\smartctl.exe",
                "C:\Program Files (x86)\smartmontools\bin\smartctl.exe",
                "C:\smartmontools\smartctl.exe",
                "C:\smartmontools\bin\smartctl.exe"
            )
            foreach ($path in $commonPaths) {
                if (Test-Path $path) {
                    $smartctlPath = $path
                    break
                }
            }
        }

        $results = @()
        foreach ($disk in $disks) {
            $pnpClean = $disk.PNPDeviceID

            $dataInstance = $allData | Where-Object {
                ($_.InstanceName -replace '_[0-9]+$', '') -eq $pnpClean
            }
            $thresholdInstance = $allThresholds | Where-Object {
                ($_.InstanceName -replace '_[0-9]+$', '') -eq $pnpClean
            }

            $snClean = $disk.SerialNumber -replace '\s+', ''
            $physDisk = $null
            if ($physicalDisks) {
                $physDisk = $physicalDisks | Where-Object {
                    ($_.SerialNumber -replace '\s+', '') -eq $snClean
                }
            }

            $letters = @()
            $diskParts = $partitions | Where-Object { $_.DiskIndex -eq $disk.Index }
            foreach ($part in $diskParts) {
                $lp = $logicalToPart | Where-Object { $_.Antecedent.DeviceID -eq $part.DeviceID }
                if ($lp) {
                    $letters += $lp.Dependent.DeviceID
                }
            }

            $relCounter = $null

            # PCI Link Speed & Width Query natively via PnP Property
            $transferMode = "SATA (Link Speed Unknown)"
            $standard = "SATA (ACS-2)"
            $rotationRate = "---- (SSD)"
            if ($physDisk -and ($physDisk.MediaType -eq "HDD" -or $physDisk.MediaType -eq "Rotational")) {
                $rotationRate = "7200 RPM"
            }

            $isNVMe = ($physDisk -and $physDisk.BusType -eq "NVMe") -or ($disk.InterfaceType -like "*NVM*" -or $disk.InterfaceType -like "*Express*")
            if ($isNVMe) {
                $standard = "NVM Express"
                $pnpTelemetryStartUtc = [datetime]::UtcNow
                $pnpTelemetryWatch = [System.Diagnostics.Stopwatch]::StartNew()
                $pciDev = Get-PnpDevice -Class SCSIAdapter -ErrorAction SilentlyContinue | Where-Object {
                    $_.FriendlyName -like "*NVM*" -or $_.FriendlyName -like "*NVMe*"
                } | Select-Object -First 1

                if ($pciDev) {
                    $curSpeed = Get-PnpDeviceProperty -InstanceId $pciDev.InstanceId -KeyName "DEVPKEY_PciDevice_CurrentLinkSpeed" -ErrorAction SilentlyContinue
                    $curWidth = Get-PnpDeviceProperty -InstanceId $pciDev.InstanceId -KeyName "DEVPKEY_PciDevice_CurrentLinkWidth" -ErrorAction SilentlyContinue
                    $maxSpeed = Get-PnpDeviceProperty -InstanceId $pciDev.InstanceId -KeyName "DEVPKEY_PciDevice_MaxLinkSpeed" -ErrorAction SilentlyContinue
                    $maxWidth = Get-PnpDeviceProperty -InstanceId $pciDev.InstanceId -KeyName "DEVPKEY_PciDevice_MaxLinkWidth" -ErrorAction SilentlyContinue

                    if ($curSpeed -and $curWidth) {
                        $genMap = @{ 1 = "1.0"; 2 = "2.0"; 3 = "3.0"; 4 = "4.0"; 5 = "5.0" }
                        $cSpeed = if ($genMap.ContainsKey($curSpeed.Data)) { $genMap[$curSpeed.Data] } else { $curSpeed.Data }
                        $cWidth = $curWidth.Data
                        $mSpeed = if ($maxSpeed -and $genMap.ContainsKey($maxSpeed.Data)) { $genMap[$maxSpeed.Data] } else { $maxSpeed.Data }
                        $mWidth = if ($maxWidth) { $maxWidth.Data } else { $cWidth }
                        $transferMode = "PCIe $cSpeed x$cWidth | PCIe $mSpeed x$mWidth"
                    }
                }
                $pnpTelemetryWatch.Stop()
                Add-CollectorBenchmark `
                    -Phase "Collector.PnPTelemetry.Disk$($disk.Index)" `
                    -Watch $pnpTelemetryWatch `
                    -StartUtc $pnpTelemetryStartUtc `
                    -ResultCount ([int]($null -ne $pciDev))
            } elseif ($BenchmarkEnabled) {
                $skippedUtc = [datetime]::UtcNow
                $skippedWatch = [System.Diagnostics.Stopwatch]::StartNew(); $skippedWatch.Stop()
                Add-CollectorBenchmark -Phase "Collector.PnPTelemetry.Disk$($disk.Index)" -Watch $skippedWatch -StartUtc $skippedUtc -Status skipped -AttemptCount 0 -ResultCount 0
            }

            # Ανάκτηση δεδομένων από smartctl
            $smartctlData = $null
            $smartctlDevice = "/dev/pd$($disk.Index)"
            $smartctlType = "auto"
            $smartctlIssue = ""
            $resolvedModel = $disk.Model
            $resolvedSerial = $disk.SerialNumber.Trim()
            $resolvedFirmware = if ($physDisk) { $physDisk.FirmwareVersion } else { $disk.FirmwareRevision }
            $requestAtaSsdStatistics = [bool](
                -not $isNVMe -and
                $physDisk -and
                [string]$physDisk.MediaType -eq 'SSD'
            )
            if ($smartctlPath -and $isAdmin) {
                $rawOutput = $null
                $parsedCheck = $null
                $isUsbDisk = $physDisk -and $physDisk.BusType -eq "USB"

                # USB bridges frequently fail auto-detection. Go directly to the
                # cached scan map and avoid a known-failing extra probe.
                if (-not $isUsbDisk) {
                    $autoStartUtc = [datetime]::UtcNow
                    $autoWatch = [System.Diagnostics.Stopwatch]::StartNew()
                    $smartctlArguments = @(Get-SmartctlHealthArguments `
                        -Device $smartctlDevice `
                        -RequestAtaSsdStatistics:$requestAtaSsdStatistics)
                    $rawOutput = & $smartctlPath @smartctlArguments 2>$null
                    $autoExitCode = $LASTEXITCODE
                    $autoWatch.Stop()
                    $parsedCheck = if ($rawOutput) { try { $rawOutput | ConvertFrom-Json } catch { $null } } else { $null }
                    $autoSucceeded = Test-SmartctlTelemetryPayload -Payload $parsedCheck
                    Add-CollectorBenchmark `
                        -Phase "Collector.SmartctlHealth.Disk$($disk.Index).Attempt1" `
                        -Watch $autoWatch `
                        -StartUtc $autoStartUtc `
                        -AttemptCount 1 `
                        -ResultCount ([int]$autoSucceeded) `
                        -Status $(if ($autoSucceeded) { 'success' } else { 'failure' }) `
                        -ErrorCategory $(if ($autoSucceeded) { '' } else { "SmartctlExit$autoExitCode" })
                }

                if (-not (Test-SmartctlTelemetryPayload -Payload $parsedCheck)) {
                    if (-not $smartctlScanLoaded) {
                        $scanStartUtc = [datetime]::UtcNow
                        $scanWatch = [System.Diagnostics.Stopwatch]::StartNew()
                        $scanOutput = & $smartctlPath --scan-open --json 2>$null
                        $scanExitCode = $LASTEXITCODE
                        $scanWatch.Stop()
                        $smartctlScanData = if ($scanOutput) { try { $scanOutput | ConvertFrom-Json } catch { $null } } else { $null }
                        $scanSucceeded = $null -ne $smartctlScanData
                        Add-CollectorBenchmark `
                            -Phase 'Collector.SmartctlScanOpen' `
                            -Watch $scanWatch `
                            -StartUtc $scanStartUtc `
                            -AttemptCount 1 `
                            -ResultCount (@($smartctlScanData.devices).Count) `
                            -Status $(if ($scanSucceeded) { 'success' } else { 'failure' }) `
                            -ErrorCategory $(if ($scanSucceeded) { '' } else { "SmartctlExit$scanExitCode" })
                        $smartctlScanLoaded = $true
                        foreach ($scanCandidate in @($smartctlScanData.devices)) {
                            $scanIndex = Get-SmartctlWindowsDeviceIndex -DeviceName $scanCandidate.name
                            $smartctlScanSummary += "$($scanCandidate.name) (-d $($scanCandidate.type), index=$scanIndex)"
                        }
                    }
                    $scanData = $smartctlScanData

                    $knownUsbBridge = $null
                    if ($isUsbDisk) {
                        $pnpStartUtc = [datetime]::UtcNow
                        $pnpWatch = [System.Diagnostics.Stopwatch]::StartNew()
                        $pnpAncestry = @()
                        $currentInstanceId = $disk.PNPDeviceID
                        for ($depth = 0; $depth -lt 8 -and $currentInstanceId; $depth++) {
                            $pnpAncestry += $currentInstanceId
                            $parentProperty = Get-PnpDeviceProperty `
                                -InstanceId $currentInstanceId `
                                -KeyName 'DEVPKEY_Device_Parent' `
                                -ErrorAction SilentlyContinue
                            $parentInstanceId = [string]$parentProperty.Data
                            if ([string]::IsNullOrWhiteSpace($parentInstanceId) -or $parentInstanceId -eq $currentInstanceId) {
                                break
                            }
                            $currentInstanceId = $parentInstanceId
                        }
                        $knownUsbBridge = Get-KnownUsbNvmeBridgeType -InstanceIds $pnpAncestry
                        $pnpWatch.Stop()
                        Add-CollectorBenchmark `
                            -Phase "Collector.UsbBridge.Disk$($disk.Index)" `
                            -Watch $pnpWatch `
                            -StartUtc $pnpStartUtc `
                            -ResultCount ([int]($null -ne $knownUsbBridge)) `
                            -Details $(if ($knownUsbBridge) { $knownUsbBridge.UsbId } else { 'unknown' })
                    }

                    $indexedDevices = @()
                    $identityDevices = @()
                    foreach ($candidate in @($scanData.devices)) {
                        $candidateIndex = Get-SmartctlWindowsDeviceIndex -DeviceName $candidate.name
                        $candidateRecord = [PSCustomObject]@{
                            Scan          = $candidate
                            Identity      = $null
                            EffectiveType = if (
                                $knownUsbBridge -and
                                $null -ne $candidateIndex -and
                                $candidateIndex -eq [int]$disk.Index
                            ) {
                                $knownUsbBridge.SmartctlType
                            } else {
                                $candidate.type
                            }
                        }
                        if ($null -ne $candidateIndex -and $candidateIndex -eq [int]$disk.Index) {
                            $indexedDevices += $candidateRecord
                        }
                    }

                    # Identity probing is a fallback only. Some SCSI wrappers take
                    # more than six seconds even for -i, while index mapping is exact.
                    if ($indexedDevices.Count -eq 0) {
                        $identityStartUtc = [datetime]::UtcNow
                        $identityWatch = [System.Diagnostics.Stopwatch]::StartNew()
                        $identityAttempt = 0
                        foreach ($candidate in @($scanData.devices)) {
                            $identityAttempt++
                            $singleIdentityStartUtc = [datetime]::UtcNow
                            $singleIdentityWatch = [System.Diagnostics.Stopwatch]::StartNew()
                            $identityOutput = & $smartctlPath -i -d $candidate.type $candidate.name --json 2>$null
                            $identityExitCode = $LASTEXITCODE
                            $singleIdentityWatch.Stop()
                            $identity = if ($identityOutput) { try { $identityOutput | ConvertFrom-Json } catch { $null } } else { $null }
                            Add-CollectorBenchmark `
                                -Phase "Collector.SmartctlIdentity.Disk$($disk.Index).Attempt$identityAttempt" `
                                -Watch $singleIdentityWatch `
                                -StartUtc $singleIdentityStartUtc `
                                -AttemptCount $identityAttempt `
                                -ResultCount ([int]($null -ne $identity)) `
                                -Status $(if ($null -ne $identity) { 'success' } else { 'failure' }) `
                                -ErrorCategory $(if ($null -ne $identity) { '' } else { "SmartctlExit$identityExitCode" })
                            if (-not $identity) { continue }

                            $wmiSerial = $disk.SerialNumber -replace '\s+', ''
                            $smartSerial = $identity.serial_number -replace '\s+', ''
                            $serialMatch = $wmiSerial -and $smartSerial -and $wmiSerial -eq $smartSerial
                            $modelMatch = $identity.model_name -and $disk.Model -and $identity.model_name.Trim() -eq $disk.Model.Trim()
                            if ($serialMatch -or $modelMatch) {
                                $identityDevices += [PSCustomObject]@{
                                    Scan          = $candidate
                                    Identity      = $identity
                                    EffectiveType = $candidate.type
                                }
                            }
                        }
                        $identityWatch.Stop()
                        Add-CollectorBenchmark -Phase "Collector.IdentityFallback.Disk$($disk.Index)" -Watch $identityWatch -StartUtc $identityStartUtc -AttemptCount $identityAttempt -ResultCount $identityDevices.Count
                    }

                    # PhysicalDrive index is the deterministic Windows mapping and
                    # survives USB/UASP wrappers that rewrite model and serial data.
                    # The outer @() is required: assignment from an if expression
                    # otherwise unwraps a single PSCustomObject and .Count is null.
                    $matchingDevices = @(
                        if ($indexedDevices.Count -gt 0) {
                            $indexedDevices
                        } else {
                            $identityDevices
                        }
                    )

                    if ($matchingDevices.Count -eq 1) {
                        $smartctlDevice = $matchingDevices[0].Scan.name
                        $smartctlType = $matchingDevices[0].EffectiveType
                        $resolvedStartUtc = [datetime]::UtcNow
                        $resolvedWatch = [System.Diagnostics.Stopwatch]::StartNew()
                        $smartctlArguments = @(Get-SmartctlHealthArguments `
                            -Device $smartctlDevice `
                            -DeviceType $smartctlType `
                            -RequestAtaSsdStatistics:$requestAtaSsdStatistics)
                        $rawOutput = & $smartctlPath @smartctlArguments 2>$null
                        $resolvedExitCode = $LASTEXITCODE
                        $resolvedWatch.Stop()
                        $parsedCheck = if ($rawOutput) { try { $rawOutput | ConvertFrom-Json } catch { $null } } else { $null }
                        $resolvedSucceeded = Test-SmartctlTelemetryPayload -Payload $parsedCheck
                        Add-CollectorBenchmark `
                            -Phase "Collector.SmartctlHealth.Disk$($disk.Index).BridgeRetry" `
                            -Watch $resolvedWatch `
                            -StartUtc $resolvedStartUtc `
                            -AttemptCount 2 `
                            -ResultCount ([int]$resolvedSucceeded) `
                            -Status $(if ($resolvedSucceeded) { 'success' } else { 'failure' }) `
                            -ErrorCategory $(if ($resolvedSucceeded) { '' } else { "SmartctlExit$resolvedExitCode" })
                    } elseif ($matchingDevices.Count -gt 1) {
                        $smartctlIssue = "Το smartctl επέστρεψε πολλαπλά candidates για PhysicalDrive$($disk.Index). Δεν έγινε αυθαίρετη επιλογή."
                    } else {
                        $scanDetails = if ($smartctlScanSummary.Count -gt 0) {
                            $smartctlScanSummary -join '; '
                        } else {
                            'κανένα parsed candidate'
                        }
                        $smartctlIssue = "Δεν βρέθηκε --scan-open candidate για PhysicalDrive$($disk.Index). Scan: $scanDetails"
                    }
                }
                if (Test-SmartctlTelemetryPayload -Payload $parsedCheck) {
                    $smartctlData = $rawOutput | Out-String
                    $smartctlIssue = ""

                    if ($parsedCheck.model_name) {
                        $resolvedModel = $parsedCheck.model_name
                    }
                    if ($parsedCheck.serial_number) {
                        $resolvedSerial = $parsedCheck.serial_number
                    }
                    if ($parsedCheck.firmware_version) {
                        $resolvedFirmware = $parsedCheck.firmware_version
                    }

                    if ($parsedCheck.nvme_smart_health_information_log -or $parsedCheck.device.protocol -eq "NVMe") {
                        $isNVMe = $true
                        $standard = "NVM Express"
                        if ($physDisk -and $physDisk.BusType -eq "USB") {
                            $transferMode = "USB/UASP bridge -> NVMe (link speed unavailable)"
                        }
                    }
                } elseif (-not $smartctlIssue) {
                    $smartctlIssue = "Το smartctl άνοιξε τη συσκευή αλλά δεν επέστρεψε ATA/NVMe health telemetry."
                }
            } elseif (-not $smartctlPath) {
                $smartctlIssue = "Το smartctl δεν είναι εγκατεστημένο ή δεν βρέθηκε στο PATH/Program Files."
            } elseif (-not $isAdmin) {
                $smartctlIssue = "Η συλλογή smartctl δεν εκτελέστηκε χωρίς Administrator δικαιώματα."
            }

            $needsNvmeReliabilityFallback = [bool]($isNVMe -and -not $smartctlData)
            $needsAtaSsdReliabilityFallback = [bool](
                -not $isNVMe -and
                $physDisk -and
                [string]$physDisk.MediaType -eq 'SSD' -and
                -not (Test-SmartctlAtaLifeEvidence -Payload $parsedCheck)
            )
            if (
                $isAdmin -and
                $physDisk -and
                $physDisk.BusType -ne "USB" -and
                ($needsNvmeReliabilityFallback -or $needsAtaSsdReliabilityFallback)
            ) {
                $reliabilityKey = [string]$physDisk.DeviceId
                if (-not $reliabilityCounters.ContainsKey($reliabilityKey)) {
                    $reliabilityStartUtc = [datetime]::UtcNow
                    $reliabilityWatch = [System.Diagnostics.Stopwatch]::StartNew()
                    $reliabilityCounters[$reliabilityKey] = Get-StorageReliabilityCounter `
                        -PhysicalDisk $physDisk `
                        -ErrorAction SilentlyContinue
                    $reliabilityWatch.Stop()
                    Add-CollectorBenchmark `
                        -Phase "Collector.Reliability.Disk$($disk.Index)" `
                        -Watch $reliabilityWatch `
                        -StartUtc $reliabilityStartUtc `
                        -ResultCount ([int]($null -ne $reliabilityCounters[$reliabilityKey])) `
                        -Details $(if ($needsNvmeReliabilityFallback) { 'NVMe fallback' } else { 'ATA SSD wear fallback' })
                }
                $relCounter = $reliabilityCounters[$reliabilityKey]
            } elseif ($BenchmarkEnabled -and $physDisk -and $physDisk.BusType -eq "USB") {
                $benchmarkRows.Add([PSCustomObject]@{
                    Phase         = "Collector.Reliability.Disk$($disk.Index)"
                    ParentStage   = 'Collector.Total'
                    StartUtc      = [datetime]::UtcNow
                    EndUtc        = [datetime]::UtcNow
                    Milliseconds  = 0
                    Status        = 'skipped'
                    AttemptCount  = 0
                    ResultCount   = 0
                    ErrorCategory = ''
                    Details       = 'Skipped USB timeout path'
                })
            } elseif ($BenchmarkEnabled) {
                $benchmarkRows.Add([PSCustomObject]@{
                    Phase         = "Collector.Reliability.Disk$($disk.Index)"
                    ParentStage   = 'Collector.Total'
                    StartUtc      = [datetime]::UtcNow
                    EndUtc        = [datetime]::UtcNow
                    Milliseconds  = 0
                    Status        = 'skipped'
                    AttemptCount  = 0
                    ResultCount   = 0
                    ErrorCategory = ''
                    Details       = 'Not required because primary telemetry was available'
                })
            }

            $results += [PSCustomObject]@{
                Index = $disk.Index
                Model = $resolvedModel
                SerialNumber = $resolvedSerial
                Size = $disk.Size
                InterfaceType = $disk.InterfaceType
                PNPDeviceID = $disk.PNPDeviceID
                MediaType = if ($physDisk) { $physDisk.MediaType } else { "SSD" }
                BusType = if ($physDisk) { $physDisk.BusType } else { "SATA" }
                Firmware = $resolvedFirmware
                Letters = $letters
                SMARTData = if ($dataInstance) { $dataInstance.VendorSpecific } else { $null }
                SMARTThresholds = if ($thresholdInstance) { $thresholdInstance.VendorSpecific } else { $null }
                IsAdmin = $isAdmin
                ReliabilityCounter = if ($relCounter) {
                    [PSCustomObject]@{
                        Wear = $relCounter.Wear
                        Temperature = $relCounter.Temperature
                        TemperatureMax = $relCounter.TemperatureMax
                        ReadErrorsTotal = $relCounter.ReadErrorsTotal
                        WriteErrorsTotal = $relCounter.WriteErrorsTotal
                        ReadLatencyMax = $relCounter.ReadLatencyMax
                        WriteLatencyMax = $relCounter.WriteLatencyMax
                    }
                } else { $null }
                ImportedFromFile = $false
                SmartctlJSON = $smartctlData
                SmartctlDevice = $smartctlDevice
                SmartctlType = $smartctlType
                SmartctlIssue = $smartctlIssue
                Standard = $standard
                TransferMode = $transferMode
                RotationRate = $rotationRate
            }
        }
        $collectorWatch.Stop()
        if ($BenchmarkEnabled) {
            if (-not $smartctlScanLoaded) {
                $benchmarkRows.Add([PSCustomObject]@{
                    Phase         = 'Collector.SmartctlScanOpen'
                    ParentStage   = 'Collector.Total'
                    StartUtc      = [datetime]::UtcNow
                    EndUtc        = [datetime]::UtcNow
                    Milliseconds  = 0
                    Status        = 'skipped'
                    AttemptCount  = 0
                    ResultCount   = 0
                    ErrorCategory = ''
                    Details       = 'Primary smartctl queries succeeded'
                })
            }
            $benchmarkRows.Add([PSCustomObject]@{
                Phase         = 'Collector.Total'
                ParentStage   = 'Remote.Collection'
                StartUtc      = $collectorStartUtc
                EndUtc        = [datetime]::UtcNow
                Milliseconds  = $collectorWatch.Elapsed.TotalMilliseconds
                Status        = 'success'
                AttemptCount  = 1
                ResultCount   = $results.Count
                ErrorCategory = ''
                Details       = "$($results.Count) disks"
            })
        }

        [PSCustomObject]@{
            ComputerName = $env:COMPUTERNAME
            Disks        = @($results)
            Benchmarks   = @($benchmarkRows)
        }
    }

    $session = $null
    try {
        if ($isLocal) {
            $collectorInvokeStartUtc = [datetime]::UtcNow
            $collectorInvokeWatch = [System.Diagnostics.Stopwatch]::StartNew()
            $collectionPayload = Invoke-Command `
                -ScriptBlock $scriptBlock `
                -ArgumentList ([bool]$Benchmark)
            $collectorInvokeWatch.Stop()
            Add-DiskHealthPerformanceRecord -Stage 'Collector.Invoke.Local' -ParentStage 'Collector.Total' -StartUtc $collectorInvokeStartUtc -EndUtc ([datetime]::UtcNow) -DurationMs $collectorInvokeWatch.Elapsed.TotalMilliseconds -Status success -AttemptCount 1 -ResultCount (@($collectionPayload.Disks).Count)
        } else {
            Import-DiskHealthWinRMWorkshop
            Show-DiskHealthPerformanceProgress -Stage 'TrustedHosts.Preparation' -Message 'Preparing only the exact selected target.'
            $workshopToken = Start-DiskHealthPerformanceStage -Stage 'TrustedHosts.ExactTargetPreparation' -ParentStage 'WinRM.Connect'
            try {
                $workshopPreparation = Add-WinRMWorkshopTrustedHost `
                    -ComputerName $ComputerName `
                    -OnStatus ${function:Write-DiskHealthWinRMWorkshopStatus}
                Complete-DiskHealthPerformanceStage -Token $workshopToken -Status success -AttemptCount 1 -ResultCount ([int]$workshopPreparation.Verified)
            } catch {
                $workshopCategory = Get-DiskHealthPerformanceErrorCategory $_
                Complete-DiskHealthPerformanceStage -Token $workshopToken -Status failure -AttemptCount 1 -ResultCount 0 -ErrorCategory $workshopCategory
                throw
            }
            if (-not $workshopPreparation.Verified) {
                throw "Η exact-target TrustedHosts προετοιμασία απέτυχε για '$ComputerName'."
            }

            $script:DiskHealthConnectionStageTokens = @{}
            Show-DiskHealthPerformanceProgress -Stage 'WinRM.Connect' -Message 'TCP 5985 preflight and bounded authenticated attempts.'
            $connectionToken = Start-DiskHealthPerformanceStage -Stage 'WinRM.NewPSSession' -ParentStage 'WinRM.Connect'
            $sessionWatch = [System.Diagnostics.Stopwatch]::StartNew()
            try {
                $session = Connect-WinRMSession `
                    -ComputerName $ComputerName `
                    -Credential $cred `
                    -OnStatus ${function:Write-DiskHealthWinRMConnectionStatus}
                $sessionWatch.Stop()
                Complete-DiskHealthPerformanceStage -Token $connectionToken -Status success -AttemptCount $session.WinRMConnectionAttemptCount -ResultCount 1
            } catch {
                $sessionWatch.Stop()
                $connectionCategory = Get-WinRMConnectionErrorCategory -ErrorObject $_
                Complete-DiskHealthPerformanceStage -Token $connectionToken -Status $(if ($connectionCategory -eq 'Timeout') { 'timeout' } else { 'failure' }) -AttemptCount $_.Exception.Data['WinRMConnectionAttemptCount'] -ResultCount 0 -ErrorCategory $connectionCategory
                $isAuthError = $connectionCategory -eq 'AuthenticationRejected'
                $isInteractive = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
                if ($isAuthError -and $CredentialFromSavedProfile -and -not [string]::IsNullOrWhiteSpace($ConnectionNetworkId)) {
                    Remove-DiskHealthStoredCredential `
                        -NetworkId $ConnectionNetworkId `
                        -ComputerNames $connectionAliases
                }

                if ($isAuthError -and $isInteractive) {
                    Write-Host "  ❌ WinRM: Άρνηση πρόσβασης (Access Denied) με τα τρέχοντα credentials." -ForegroundColor $Yellow
                    Write-Host "  👤 Παρακαλώ εισάγετε στοιχεία σύνδεσης για το PC '$ComputerName':" -ForegroundColor $Cyan

                    $promptUser = Read-Host "     Username"
                    if (-not [string]::IsNullOrEmpty($promptUser)) {
                        Write-Host "     Password: " -NoNewline -ForegroundColor $White
                        $promptPass = Read-Host -AsSecureString

                        $promptCred = New-Object System.Management.Automation.PSCredential($promptUser, $promptPass)

                        Write-Host "  🔄 Προσπάθεια επανασύνδεσης με τα νέα στοιχεία..." -ForegroundColor $Cyan
                        try {
                            $script:DiskHealthConnectionStageTokens = @{}
                            $retryToken = Start-DiskHealthPerformanceStage -Stage 'WinRM.NewPSSession.Retry' -ParentStage 'WinRM.Connect'
                            $retryWatch = [System.Diagnostics.Stopwatch]::StartNew()
                            $session = Connect-WinRMSession `
                                -ComputerName $ComputerName `
                                -Credential $promptCred `
                                -OnStatus ${function:Write-DiskHealthWinRMConnectionStatus}
                            $retryWatch.Stop()
                            $cred = $promptCred
                            $CredentialFromSavedProfile = $false
                            $Username = $cred.UserName
                            Complete-DiskHealthPerformanceStage -Token $retryToken -Status success -AttemptCount $session.WinRMConnectionAttemptCount -ResultCount 1
                        } catch {
                            $retryCategory = Get-WinRMConnectionErrorCategory -ErrorObject $_
                            Complete-DiskHealthPerformanceStage -Token $retryToken -Status $(if ($retryCategory -eq 'Timeout') { 'timeout' } else { 'failure' }) -AttemptCount $_.Exception.Data['WinRMConnectionAttemptCount'] -ResultCount 0 -ErrorCategory $retryCategory
                            Write-Host "  ❌ Αποτυχία σύνδεσης και με τα νέα στοιχεία." -ForegroundColor $Red
                            throw $_
                        }
                    } else {
                        throw $_
                    }
                } else {
                    throw $_
                }
            }
            if (-not [string]::IsNullOrWhiteSpace($ConnectionNetworkId)) {
                $credentialSaveToken = Start-DiskHealthPerformanceStage -Stage 'Credential.DPAPISave' -ParentStage 'Network.Authentication'
                Save-DiskHealthStoredCredential `
                    -NetworkId $ConnectionNetworkId `
                    -ComputerNames $connectionAliases `
                    -CredentialToStore $cred
                Complete-DiskHealthPerformanceStage -Token $credentialSaveToken -Status success -ResultCount $connectionAliases.Count
                Write-Host "  🔐 Το credential αποθηκεύτηκε με DPAPI για αυτό το PC και δίκτυο." -ForegroundColor $Green
            }

            # Detect the dependency first. Interactive users choose in-app;
            # -InstallSmartctl remains the non-interactive automation override.
            Show-DiskHealthPerformanceProgress -Stage 'Remote.EnvironmentToolDetection' -Message 'Checking remote host identity and smartctl availability.'
            $prerequisiteToken = Start-DiskHealthPerformanceStage -Stage 'WinRM.PrerequisiteProbe' -ParentStage 'Remote.Collection'
            $prerequisiteWatch = [System.Diagnostics.Stopwatch]::StartNew()
            $remoteInfo = Invoke-Command -Session $session -ScriptBlock {
                $paths = @(
                    "smartctl",
                    "C:\Program Files\smartmontools\bin\smartctl.exe",
                    "C:\Program Files\smartmontools\smartctl.exe",
                    "C:\smartmontools\smartctl.exe",
                    "C:\smartmontools\bin\smartctl.exe"
                )
                $found = $false
                foreach ($p in $paths) {
                    if (Get-Command $p -ErrorAction SilentlyContinue) { $found = $true; break }
                }
                [PSCustomObject]@{
                    ComputerName   = $env:COMPUTERNAME
                    SmartctlExists = $found
                }
            }
            $prerequisiteWatch.Stop()
            Complete-DiskHealthPerformanceStage -Token $prerequisiteToken -Status success -ResultCount 1
            $remoteSmartctlExists = [bool]$remoteInfo.SmartctlExists

            $installSmartctlNow = [bool]$InstallSmartctl
            if (-not $remoteSmartctlExists -and -not $installSmartctlNow) {
                $canPromptForInstall = (
                    -not $NoUI -and
                    [Environment]::UserInteractive -and
                    -not [Console]::IsInputRedirected
                )
                if ($canPromptForInstall) {
                    $installChoice = Show-SmartctlInstallMenu
                    if ($installChoice -eq 'Back') {
                        return
                    }
                    $installSmartctlNow = $installChoice -eq 'Install'
                } else {
                    Write-Host "⚠️⚠️⚠️ NEED TOOL: Το remote PC δεν διαθέτει smartctl. Συνεχίζουμε με περιορισμένα WMI/CIM diagnostics." -ForegroundColor $Yellow
                    Write-Host "       Για automation χρησιμοποιήστε -InstallSmartctl ή εγκαταστήστε το από trusted source." -ForegroundColor $Gray
                }
            }

            if (-not $remoteSmartctlExists -and $installSmartctlNow) {
                Write-Host "  ⚠️ Το remote PC δεν διαθέτει smartctl. Εκκίνηση επίσημης εγκατάστασης μέσω winget..." -ForegroundColor $Yellow
                $installResult = Invoke-Command -Session $session -ScriptBlock {
                    function Get-WingetSmartctlInstallArguments {
                        param([AllowEmptyString()][string]$InstallHelp = '')

                        $arguments = @(
                            'install'
                            '--id'
                            'smartmontools.smartmontools'
                            '--exact'
                            '--source'
                            'winget'
                            '--scope'
                            'machine'
                            '--silent'
                        )
                        # winget 1.3 does not support this switch. Detect the
                        # actual CLI capability instead of assuming a version.
                        if ($InstallHelp -match '(?m)^\s*--disable-interactivity(?:\s|$)') {
                            $arguments += '--disable-interactivity'
                        }

                        return $arguments
                    }

                    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
                    if (-not $winget) {
                        return [PSCustomObject]@{
                            Success = $false
                            Message = 'Το winget.exe δεν είναι διαθέσιμο στο remote session.'
                            Version = ''
                        }
                    }

                    $wingetInstallHelp = (& $winget.Source install --help 2>&1 | Out-String)
                    $wingetArguments = Get-WingetSmartctlInstallArguments -InstallHelp $wingetInstallHelp
                    $wingetOutput = & $winget.Source @wingetArguments 2>&1 | Out-String
                    $wingetExitCode = $LASTEXITCODE
                    $installedPath = 'C:\Program Files\smartmontools\bin\smartctl.exe'
                    if ($wingetExitCode -ne 0 -or -not (Test-Path -LiteralPath $installedPath -PathType Leaf)) {
                        return [PSCustomObject]@{
                            Success = $false
                            Message = "winget exit $wingetExitCode. $($wingetOutput.Trim())"
                            Version = ''
                        }
                    }

                    $versionLine = (& $installedPath --version 2>&1 | Select-Object -First 1)
                    [PSCustomObject]@{
                        Success = $true
                        Message = 'Εγκαταστάθηκε στο C:\Program Files\smartmontools.'
                        Version = [string]$versionLine
                    }
                }

                if ($installResult.Success) {
                    Write-Host "  ✅ $($installResult.Message)" -ForegroundColor $Green
                    Write-Host "     $($installResult.Version)" -ForegroundColor $Gray
                } else {
                    Write-Host "⚠️⚠️⚠️ INSTALL FAILED: $($installResult.Message)" -ForegroundColor $Red
                    Write-Host "       Δεν δημιουργήθηκε fallback φάκελος στο C:\." -ForegroundColor $Yellow
                }
            }

            Show-DiskHealthPerformanceProgress -Stage 'Remote.DiskCollection' -Message 'Enumerating disks and collecting read-only telemetry.'
            $collectorInvokeStartUtc = [datetime]::UtcNow
            $collectorInvokeWatch = [System.Diagnostics.Stopwatch]::StartNew()
            $collectionPayload = Invoke-Command `
                -Session $session `
                -ScriptBlock $scriptBlock `
                -ArgumentList ([bool]$Benchmark)
            $collectorInvokeWatch.Stop()
            Add-DiskHealthPerformanceRecord -Stage 'Collector.Invoke.Remote' -ParentStage 'Remote.Collection' -StartUtc $collectorInvokeStartUtc -EndUtc ([datetime]::UtcNow) -DurationMs $collectorInvokeWatch.Elapsed.TotalMilliseconds -Status success -AttemptCount 1 -ResultCount (@($collectionPayload.Disks).Count)

            if (-not [string]::IsNullOrWhiteSpace($ConnectionNetworkId)) {
                $resolvedComputerName = if (
                    -not [string]::IsNullOrWhiteSpace([string]$collectionPayload.ComputerName)
                ) {
                    [string]$collectionPayload.ComputerName
                } else {
                    [string]$remoteInfo.ComputerName
                }
                $resolvedMacAddress = $ConnectionMacAddress
                if ([string]::IsNullOrWhiteSpace($resolvedMacAddress)) {
                    $neighbor = Get-NetNeighbor -IPAddress $ComputerName -ErrorAction SilentlyContinue |
                        Where-Object { $_.LinkLayerAddress -and $_.LinkLayerAddress -ne '00-00-00-00-00-00' } |
                        Select-Object -First 1
                    if ($neighbor) {
                        $resolvedMacAddress = [string]$neighbor.LinkLayerAddress
                    }
                }
                if ([string]::IsNullOrWhiteSpace($resolvedMacAddress)) {
                    $resolvedMacAddress = 'Unknown'
                }

                Add-WinRMConnectionHistoryEntry `
                    -ComputerName $resolvedComputerName `
                    -LastIPAddress $ComputerName `
                    -MACAddress $resolvedMacAddress `
                    -UserName $cred.UserName `
                    -NetworkId $ConnectionNetworkId
                $credentialAliases = @(
                    $connectionAliases
                    $resolvedComputerName
                    $ComputerName
                ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
                Save-DiskHealthStoredCredential `
                    -NetworkId $ConnectionNetworkId `
                    -ComputerNames $credentialAliases `
                    -CredentialToStore $cred
            }
        }

        $collected = @($collectionPayload.Disks)
        foreach ($benchmarkRow in @($collectionPayload.Benchmarks)) {
            $benchmarkEndUtc = if ($benchmarkRow.PSObject.Properties['EndUtc']) { [datetime]$benchmarkRow.EndUtc } else { [datetime]::UtcNow }
            $benchmarkStartUtc = if ($benchmarkRow.PSObject.Properties['StartUtc']) { [datetime]$benchmarkRow.StartUtc } else { $benchmarkEndUtc.AddMilliseconds(-[double]$benchmarkRow.Milliseconds) }
            Add-DiskHealthPerformanceRecord `
                -Stage ([string]$benchmarkRow.Phase) `
                -ParentStage $(if ($benchmarkRow.PSObject.Properties['ParentStage']) { [string]$benchmarkRow.ParentStage } else { 'Collector.Total' }) `
                -StartUtc $benchmarkStartUtc `
                -EndUtc $benchmarkEndUtc `
                -DurationMs ([double]$benchmarkRow.Milliseconds) `
                -Status $(if ($benchmarkRow.PSObject.Properties['Status']) { [string]$benchmarkRow.Status } else { 'success' }) `
                -AttemptCount $(if ($benchmarkRow.PSObject.Properties['AttemptCount']) { $benchmarkRow.AttemptCount } else { $null }) `
                -ResultCount $(if ($benchmarkRow.PSObject.Properties['ResultCount']) { $benchmarkRow.ResultCount } else { $null }) `
                -ErrorCategory $(if ($benchmarkRow.PSObject.Properties['ErrorCategory']) { [string]$benchmarkRow.ErrorCategory } else { '' })
        }
        $operationWatch.Stop()
        Add-DiskHealthPerformanceRecord -Stage 'Operation.Total' -ParentStage 'Run' -StartUtc ([datetime]::UtcNow.AddMilliseconds(-$operationWatch.Elapsed.TotalMilliseconds)) -EndUtc ([datetime]::UtcNow) -DurationMs $operationWatch.Elapsed.TotalMilliseconds -Status success -AttemptCount 1 -ResultCount $collected.Count
        if ($Benchmark -and -not [string]::IsNullOrWhiteSpace($script:DiskHealthBenchmarkLogPath)) {
            Write-Host "  ⏱️ Benchmark log: $script:DiskHealthBenchmarkLogPath" -ForegroundColor DarkGray
        }
    } catch {
        $operationCategory = Get-DiskHealthPerformanceErrorCategory $_
        $failureEndUtc = [datetime]::UtcNow
        Add-DiskHealthPerformanceRecord -Stage 'Operation.Failure' -ParentStage 'Operation.Total' -StartUtc $failureEndUtc -EndUtc $failureEndUtc -DurationMs 0 -Status failure -ErrorCategory $operationCategory
        if ($EmbeddedRemote) {
            Save-DiskHealthPerformanceReport
        } else {
            Save-DiskHealthPerformanceReport -Finalize -ShowSummary
        }
        Write-Host "❌ Σφάλμα κατά τη σύνδεση ή τη συλλογή δεδομένων: $_" -ForegroundColor $Red
        return
    } finally {
        if ($session) {
            Remove-PSSession -Session $session -ErrorAction SilentlyContinue
        }
    }
}

function Show-DriveMenu {
    param (
        [array]$Drives,
        [switch]$AllowBack
    )

    try {
        $selectedIndex = 0

        $options = [System.Collections.Generic.List[object]]::new()
        for ($driveIndex = 0; $driveIndex -lt $Drives.Count; $driveIndex++) {
            $d = $Drives[$driveIndex]
            $lettersStr = if ($d.Letters) { "($($d.Letters -join ', '))" } else { "" }
            $options.Add([PSCustomObject]@{
                Action     = 'Drive'
                DriveIndex = $driveIndex
                Label      = "Disk $($d.Index): $($d.Model) - $([Math]::Round($d.Size / 1GB, 2)) GB $lettersStr"
            })
        }
        if ($Drives.Count -gt 1) {
            $options.Add([PSCustomObject]@{ Action = 'All'; DriveIndex = -1; Label = 'Διάγνωση όλων των δίσκων (All Drives)' })
        }

        $escapeAction = if ($AllowBack) { 'Back' } else { 'Exit' }
        return Show-DiskHealthChoiceMenu `
            -Title 'DiskHealth disks' `
            -Subtitle "Ανιχνεύθηκαν $($Drives.Count) φυσικοί δίσκοι. Επιλέξτε δίσκο για διάγνωση." `
            -Options @($options) `
            -EscapeValue ([pscustomobject]@{ Action = $escapeAction; DriveIndex = -1; Label = '' }) `
            -EscapeMode $(if ($AllowBack) { 'Back' } else { 'Exit' })
    } catch {
        # Fallback αν αποτύχει το console interaction
        if ($Drives.Count -gt 1) {
            return [PSCustomObject]@{ Action = 'All'; DriveIndex = -1; Label = 'All Drives' }
        }
        return [PSCustomObject]@{ Action = 'Drive'; DriveIndex = 0; Label = 'Disk' }
    }
}

if (-not $collected) {
    Write-Host "⚠️ Δεν βρέθηκαν φυσικοί δίσκοι στο σύστημα." -ForegroundColor $Yellow
    return
}

$runLoop = $true
while ($runLoop) {
    $selectedDrives = $collected
    $isInteractive = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected -and $Host.UI.RawUI -and $Host.Name -notlike "*Background*" -and $Host.Name -notlike "*Service*"
    $allowBack = [bool]$EmbeddedRemote
    $menuEnabled = -not $NoUI -and $isInteractive -and ($collected.Count -gt 1 -or $allowBack)

    if ($menuEnabled) {
        Clear-Host
        Write-Host "======================================================================" -ForegroundColor $Cyan
        Write-Host "  💾 ΔΙΑΓΝΩΣΤΙΚΟ ΥΓΕΙΑΣ ΔΙΣΚΩΝ (Disk Health Diagnostics)" -ForegroundColor $Cyan
        Write-Host "======================================================================" -ForegroundColor $Cyan
        Write-Host "  🌐 Στόχος: $ComputerName (Χρήστης: $Username)" -ForegroundColor $White
        Write-Host "  🔧 Μέθοδος: Native smartctl & WMI/CIM Queries" -ForegroundColor $White
        Write-Host "----------------------------------------------------------------------" -ForegroundColor $Cyan

        $menuChoice = Show-DriveMenu -Drives $collected -AllowBack:$allowBack
        if ($menuChoice.Action -eq 'Exit') {
            Clear-Host
            Write-Host "👋 Αντίο! (Exiting...)" -ForegroundColor $Green
            break
        }
        if ($menuChoice.Action -eq 'Back') {
            break
        }
        if ($menuChoice.Action -eq 'Drive') {
            $selectedDrives = @($collected[$menuChoice.DriveIndex])
        }
        Clear-Host
    } else {
        $runLoop = $false
    }

    # 3. Ανάλυση και Παρουσίαση για κάθε δίσκο. Capture Write-Host's structured
    # information records so the same diagnostic logic can feed a resize-safe TUI.
    Show-DiskHealthPerformanceProgress -Stage 'Evaluation.HealthParsing' -Message 'Parsing telemetry and evaluating health evidence.'
    $evaluationToken = Start-DiskHealthPerformanceStage -Stage 'Evaluation.HealthParsing' -ParentStage 'Report'
    $reportRecords = @(
    & {
    foreach ($disk in $selectedDrives) {
    $isDiskNVMe = ($disk.BusType -eq "NVMe" -or $disk.InterfaceType -like "*NVM*" -or $disk.InterfaceType -like "*Express*")

    $brand = "Generic"
    if ($isDiskNVMe) {
        $brand = "NVMe"
    } else {
        $brand = Get-AtaTelemetryProfile -Model $disk.Model -Firmware $disk.Firmware -Attributes @()
    }

    # PARSE SMARTCTL JSON DATA IF AVAILABLE
    $smart = $null
    if ($disk.SmartctlJSON) {
        try {
            $smart = $disk.SmartctlJSON | ConvertFrom-Json
        } catch {}
    }

    if ($smart) {
        if ($smart.nvme_smart_health_information_log -or $smart.device.protocol -eq "NVMe") {
            $isDiskNVMe = $true
            $brand = "NVMe"
        }
        if ($smart.nvme_version.string) {
            $disk.Standard = "NVM Express " + $smart.nvme_version.string
        } elseif ($smart.ata_version.string) {
            $disk.Standard = $smart.ata_version.string
        }

        # Ανάκτηση SATA Link Speed (Transfer Mode)
        $speedObj = if ($smart.interface_speed) { $smart.interface_speed } else { $smart.sata_link_speed }
        if ($speedObj) {
            $curSpeed = $speedObj.current.string
            $maxSpeed = $speedObj.max.string
            if ($curSpeed -and $maxSpeed) {
                $speedMap = @{ "1.5 Gb/s" = "SATA/150"; "3.0 Gb/s" = "SATA/300"; "6.0 Gb/s" = "SATA/600" }
                $cSpeed = if ($speedMap.ContainsKey($curSpeed)) { $speedMap[$curSpeed] } else { $curSpeed }
                $mSpeed = if ($speedMap.ContainsKey($maxSpeed)) { $speedMap[$maxSpeed] } else { $maxSpeed }
                $disk.TransferMode = "$cSpeed | $mSpeed"
            }
        }
    }

    if (-not $isDiskNVMe) {
        $profileAttributes = if ($smart -and $smart.ata_smart_attributes.table) {
            @($smart.ata_smart_attributes.table)
        } elseif ($disk.ImportedFromFile -and $disk.ParsedAttributes) {
            @($disk.ParsedAttributes)
        } else {
            @()
        }
        $brand = Get-AtaTelemetryProfile -Model $disk.Model -Firmware $disk.Firmware -Attributes $profileAttributes
    }

    $isRotationalMedia = (-not $isDiskNVMe) -and (
        $disk.MediaType -match '(?i)HDD|Hard Disk' -or
        $disk.RotationRate -match '^\s*\d+\s*RPM'
    )
    $isSeagateHdd = $isRotationalMedia -and $disk.Model -match '(?i)^(?:ST\d|Seagate)'

    Write-Host "### 🔵 Στοιχεία Δίσκου (Index: $($disk.Index))" -ForegroundColor $Cyan
    Write-Host "  🔸 Μοντέλο: " -NoNewline -ForegroundColor $White
    Write-Host "$($disk.Model)" -ForegroundColor $Cyan
    Write-Host "  🔸 Serial Number: " -NoNewline -ForegroundColor $White
    Write-Host "$($disk.SerialNumber)" -ForegroundColor $Cyan
    Write-Host "  🔸 Χωρητικότητα: " -NoNewline -ForegroundColor $White
    Write-Host "$([Math]::Round($disk.Size / 1GB, 2)) GB" -ForegroundColor $Gray
    Write-Host "  🔸 Τύπος Μέσου: " -NoNewline -ForegroundColor $White
    Write-Host "$($disk.MediaType) ($($disk.BusType))" -ForegroundColor $Gray
    Write-Host "  🔸 Drive Letter(s): " -NoNewline -ForegroundColor $White
    Write-Host "$($disk.Letters -join ', ')" -ForegroundColor $Cyan
    Write-Host "  🔸 Firmware: " -NoNewline -ForegroundColor $White
    Write-Host "$($disk.Firmware)" -ForegroundColor $Gray
    if ($disk.SmartctlJSON) {
        Write-Host "  🔸 SMART Source: " -NoNewline -ForegroundColor $White
        Write-Host "$($disk.SmartctlDevice) (-d $($disk.SmartctlType))" -ForegroundColor $Gray
    }

    if ($disk.Standard) {
        Write-Host "  🔸 Standard: " -NoNewline -ForegroundColor $White
        Write-Host "$($disk.Standard)" -ForegroundColor $Gray
    }
    if ($disk.TransferMode) {
        Write-Host "  🔸 Transfer Mode: " -NoNewline -ForegroundColor $White
        Write-Host "$($disk.TransferMode)" -ForegroundColor $Cyan
    }
    if ($disk.RotationRate) {
        Write-Host "  🔸 Rotation Rate: " -NoNewline -ForegroundColor $White
        Write-Host "$($disk.RotationRate)" -ForegroundColor $Gray
    }
    if (-not $disk.ImportedFromFile) {
        Write-Host "  🔸 Δικαιώματα: " -NoNewline -ForegroundColor $White
        if ($disk.IsAdmin) {
            Write-Host "[Verified with Admin rights]" -ForegroundColor $Green
        } else {
            Write-Host "[User level - SMART access might be limited]" -ForegroundColor $Yellow
        }
    }
    Write-Host ""

    $attributes = @()
    if ($smart) {
        if ($smart.nvme_smart_health_information_log) {
            $brand = "NVMe"
            $log = $smart.nvme_smart_health_information_log

            # Extract Temp Sensors
            $temp1 = if ($log.temperature_sensors -and $log.temperature_sensors.Count -gt 0) { $log.temperature_sensors[0] } else { 0 }
            $temp2 = if ($log.temperature_sensors -and $log.temperature_sensors.Count -gt 1) { $log.temperature_sensors[1] } else { 0 }

            # Extract thermal management values (if any)
            $thm1_trans = if ($log.thm_temp1_trans_count -ne $null) { $log.thm_temp1_trans_count } else { 0 }
            $thm2_trans = if ($log.thm_temp2_trans_count -ne $null) { $log.thm_temp2_trans_count } else { 0 }
            $thm1_time = if ($log.thm_temp1_total_time -ne $null) { $log.thm_temp1_total_time } else { 0 }
            $thm2_time = if ($log.thm_temp2_total_time -ne $null) { $log.thm_temp2_total_time } else { 0 }

            $criticalWarningValue = ConvertTo-NvmeCounter -Value $log.critical_warning
            $errorLogEntryValue = ConvertTo-NvmeCounter -Value $log.num_err_log_entries -StringValue $log.num_err_log_entries_s
            $mediaErrorValue = ConvertTo-NvmeCounter -Value $log.media_errors -StringValue $log.media_errors_s
            $mediaErrorAssessment = Get-NvmeMediaErrorAssessment -MediaErrors $mediaErrorValue -ErrorLogEntries $errorLogEntryValue -CriticalWarning $criticalWarningValue

            $nvmeMapping = @(
                @{ ID = 0x01; Name = "Critical Warning"; Raw = $log.critical_warning }
                @{ ID = 0x02; Name = "Composite Temperature"; Raw = $log.temperature; IsCelsius = $true }
                @{ ID = 0x03; Name = "Available Spare"; Raw = $log.available_spare }
                @{ ID = 0x04; Name = "Available Spare Threshold"; Raw = $log.available_spare_threshold }
                @{ ID = 0x05; Name = "Percentage Used"; Raw = $log.percentage_used }
                @{ ID = 0x06; Name = "Data Units Read"; Raw = $log.data_units_read }
                @{ ID = 0x07; Name = "Data Units Written"; Raw = $log.data_units_written }
                @{ ID = 0x08; Name = "Host Read Commands"; Raw = $log.host_reads }
                @{ ID = 0x09; Name = "Host Write Commands"; Raw = $log.host_writes }
                @{ ID = 0x0A; Name = "Controller Busy Time"; Raw = $log.controller_busy_time }
                @{ ID = 0x0B; Name = "Power Cycles"; Raw = $log.power_cycles }
                @{ ID = 0x0C; Name = "Power On Hours"; Raw = $log.power_on_hours }
                @{ ID = 0x0D; Name = "Unsafe Shutdowns"; Raw = $log.unsafe_shutdowns }
                @{ ID = 0x0E; Name = "Media and Data Integrity Errors"; Raw = $log.media_errors; RawString = $log.media_errors_s }
                @{ ID = 0x0F; Name = "Number of Error Information Log Entries"; Raw = $log.num_err_log_entries; RawString = $log.num_err_log_entries_s }
                @{ ID = 0x10; Name = "Warning Composite Temperature Time"; Raw = $log.warning_temp_time }
                @{ ID = 0x11; Name = "Critical Composite Temperature Time"; Raw = $log.critical_comp_time }
                @{ ID = 0x12; Name = "Temperature Sensor 1"; Raw = $temp1; IsCelsius = $true }
                @{ ID = 0x13; Name = "Temperature Sensor 2"; Raw = $temp2; IsCelsius = $true }
                @{ ID = 0x1A; Name = "Thermal Management Temperature 1 Transition Count"; Raw = $thm1_trans }
                @{ ID = 0x1B; Name = "Thermal Management Temperature 2 Transition Count"; Raw = $thm2_trans }
                @{ ID = 0x1C; Name = "Total Time For Thermal Management Temperature 1"; Raw = $thm1_time }
                @{ ID = 0x1D; Name = "Total Time For Thermal Management Temperature 2"; Raw = $thm2_time }
            )
            foreach ($item in $nvmeMapping) {
                $rawVal = ConvertTo-NvmeCounter -Value $item.Raw -StringValue $item.RawString
                $attributes += [PSCustomObject]@{
                    IDHex     = "0x{0:X2}" -f $item.ID
                    ID        = $item.ID
                    Name      = $item.Name
                    Current   = 100
                    Worst     = 100
                    Threshold = 0
                    Raw       = $rawVal
                    RawHex    = "0x$($rawVal.ToString('X').PadLeft(12, [char]'0'))"
                    IsCelsius = $item.IsCelsius
                    IsTelemetryAnomaly = ($item.ID -eq 0x0E -and $mediaErrorAssessment.IsStructuralAnomaly)
                    Low64 = if ($item.ID -eq 0x0E) { $mediaErrorAssessment.Low64 } else { $null }
                    Upper64 = if ($item.ID -eq 0x0E) { $mediaErrorAssessment.Upper64 } else { $null }
                }
            }
        }
        elseif ($smart.ata_smart_attributes.table) {
            foreach ($attr in $smart.ata_smart_attributes.table) {
                $id = $attr.id
                $attrName = Get-AttributeName $id $brand
                $attributes += [PSCustomObject]@{
                    IDHex     = "0x{0:X2}" -f $id
                    ID        = $id
                    Name      = if ($attrName -ne "Unknown Attribute") { $attrName } else { $attr.name }
                    Current   = $attr.value
                    Worst     = $attr.worst
                    Threshold = $attr.thresh
                    Raw       = [uint64]$attr.raw.value
                    RawHex    = "0x{0:X12}" -f [uint64]$attr.raw.value
                    RawString = [string]$attr.raw.string
                }
            }
        }
    }
    elseif ($disk.ImportedFromFile) {
        foreach ($pAttr in $disk.ParsedAttributes) {
            $attrName = Get-AttributeName $pAttr.ID $brand
            $attributes += [PSCustomObject]@{
                IDHex     = $pAttr.IDHex
                ID        = $pAttr.ID
                Name      = if ($attrName -ne "Unknown Attribute") { $attrName } else { $pAttr.Name }
                Current   = $pAttr.Current
                Worst     = $pAttr.Worst
                Threshold = $pAttr.Threshold
                Raw       = $pAttr.RawVal
                RawHex    = $pAttr.RawHex
            }
        }
    } else {
        # FALLBACK TO WMI BYTES FOR SATA DRIVES
        if ($disk.SMARTData) {
            for ($offset = 2; $offset -lt 500; $offset += 12) {
                $id = $disk.SMARTData[$offset]
                if ($id -eq 0 -or $id -eq 255) { continue }

                $current = $disk.SMARTData[$offset + 3]
                $worst = $disk.SMARTData[$offset + 4]

                $rawBytes = $disk.SMARTData[($offset + 5)..($offset + 10)]
                $rawBytesExtended = $rawBytes + @(0, 0)
                $rawVal = [BitConverter]::ToUInt64($rawBytesExtended, 0)

                $thresholdVal = 0
                if ($disk.SMARTThresholds) {
                    for ($tOffset = 2; $tOffset -lt 500; $tOffset += 12) {
                        $tId = $disk.SMARTThresholds[$tOffset]
                        if ($tId -eq $id) {
                            $thresholdVal = $disk.SMARTThresholds[$tOffset + 1]
                            break
                        }
                    }
                }

                $idInt = [int]$id
                $attrName = Get-AttributeName $idInt $brand

                $attributes += [PSCustomObject]@{
                    IDHex     = "0x{0:X2}" -f $id
                    ID        = $idInt
                    Name      = $attrName
                    Current   = $current
                    Worst     = $worst
                    Threshold = $thresholdVal
                    Raw       = $rawVal
                    RawHex    = "0x{0:X12}" -f $rawVal
                }
            }
        }
    }

    # FALLBACK DIAGNOSTICS FOR NVMe (CIM-only, no file import, no smartctl)
    if (-not $attributes -and $isDiskNVMe -and -not $disk.ImportedFromFile) {
        # Ειδοποίηση 🚨🚨🚨 για εγκατάσταση smartctl
        Write-Host "🚨🚨🚨 ΠΡΟΕΙΔΟΠΟΙΗΣΗ: Για να λάβετε πλήρη S.M.A.R.T. ανάλυση για NVMe δίσκους, προτείνεται η εγκατάσταση του smartctl!" -ForegroundColor $Yellow
        Write-Host "       Μπορείτε να το εγκαταστήσετε τοπικά/remote εκτελώντας: winget install smartmontools`n" -ForegroundColor $Gray

        if ($disk.ReliabilityCounter) {
            $health = 100
            if ($disk.ReliabilityCounter.Wear -ne $null) {
                $health = 100 - $disk.ReliabilityCounter.Wear
            }

            $status = "GOOD"
            $statusColor = $Green
            $statusIcon = "✅"

            $cautionReasons = @()
            if ($disk.ReliabilityCounter.ReadErrorsTotal -gt 0) {
                $status = "CAUTION"
                $statusColor = $Yellow
                $statusIcon = "⚠️"
                $cautionReasons += "Total Read Errors ($($disk.ReliabilityCounter.ReadErrorsTotal))"
            }
            if ($disk.ReliabilityCounter.WriteErrorsTotal -gt 0) {
                $status = "CAUTION"
                $statusColor = $Yellow
                $statusIcon = "⚠️"
                $cautionReasons += "Total Write Errors ($($disk.ReliabilityCounter.WriteErrorsTotal))"
            }

            Write-Host "### 🔵 Κατάσταση Υγείας (Health Status) - NVMe/CIM Log" -ForegroundColor $Cyan
            Write-Host "  $statusIcon Κατάσταση: " -NoNewline -ForegroundColor $White
            Write-Host "$status " -NoNewline -ForegroundColor $statusColor
            Write-Host "(" -NoNewline -ForegroundColor $White
            Write-Host "$health%" -NoNewline -ForegroundColor $(if ($status -eq "GOOD") { $Green } else { $statusColor })
            Write-Host ")" -ForegroundColor $White

            if ($status -eq "GOOD") {
                Write-Host "  🔸 Ο δίσκος εμφανίζει εξαιρετική συμπεριφορά (Wear Leveling: $health% υγεία)." -ForegroundColor $Gray
                Write-Host "  🔸 Δεν καταγράφηκαν σφάλματα ανάγνωσης/εγγραφής (Read/Write Errors)." -ForegroundColor $Gray
            } else {
                Write-Host "  ⚠️ ΠΡΟΣΟΧΗ: Καταγράφηκαν σφάλματα αξιοπιστίας:" -ForegroundColor $Yellow
                foreach ($r in $cautionReasons) {
                    Write-Host "     - $r" -ForegroundColor $Yellow
                }
            }
            Write-Host ""

            Write-Host "### 🔵 Ανάλυση CIM Reliability Τιμών (NVMe Native)" -ForegroundColor $Cyan
            Write-Host "  +------------------------------------+---------------------+" -ForegroundColor $Gray
            Write-Host "  | Attribute Telemetry                | Value               |" -ForegroundColor $Gray
            Write-Host "  +------------------------------------+---------------------+" -ForegroundColor $Gray

            $rows = @(
                [PSCustomObject]@{ Name = "Estimated Health"; Value = "$health%"; Color = if ($health -le 60) { $Yellow } else { $Green } }
                [PSCustomObject]@{ Name = "Composite Temperature"; Value = if ($disk.ReliabilityCounter.Temperature -ne $null) { "$($disk.ReliabilityCounter.Temperature) C" } else { "---" }; Color = $Yellow }
                [PSCustomObject]@{ Name = "Composite Temperature (Max)"; Value = if ($disk.ReliabilityCounter.TemperatureMax -ne $null) { "$($disk.ReliabilityCounter.TemperatureMax) C" } else { "---" }; Color = $Gray }
                [PSCustomObject]@{ Name = "Total Read Errors"; Value = if ($disk.ReliabilityCounter.ReadErrorsTotal -ne $null) { $disk.ReliabilityCounter.ReadErrorsTotal } else { "0" }; Color = if ($disk.ReliabilityCounter.ReadErrorsTotal -gt 0) { $Yellow } else { $Gray } }
                [PSCustomObject]@{ Name = "Total Write Errors"; Value = if ($disk.ReliabilityCounter.WriteErrorsTotal -ne $null) { $disk.ReliabilityCounter.WriteErrorsTotal } else { "0" }; Color = if ($disk.ReliabilityCounter.WriteErrorsTotal -gt 0) { $Yellow } else { $Gray } }
                [PSCustomObject]@{ Name = "Max Read Latency"; Value = if ($disk.ReliabilityCounter.ReadLatencyMax -ne $null) { "$($disk.ReliabilityCounter.ReadLatencyMax) ms" } else { "---" }; Color = $Gray }
                [PSCustomObject]@{ Name = "Max Write Latency"; Value = if ($disk.ReliabilityCounter.WriteLatencyMax -ne $null) { "$($disk.ReliabilityCounter.WriteLatencyMax) ms" } else { "---" }; Color = $Gray }
            )

            foreach ($row in $rows) {
                $namePad = $row.Name.PadRight(34)
                $valPad = "$($row.Value)".PadRight(19)
                Write-Host "  | $namePad | $valPad |" -ForegroundColor ([ConsoleColor]$row.Color)
            }
            Write-Host "  +------------------------------------+---------------------+" -ForegroundColor $Gray

            Write-Host "`n### 🔵 Συμπέρασμα & Ενέργειες" -ForegroundColor $Cyan
            if ($status -eq "GOOD") {
                Write-Host "  ✅ Ο NVMe δίσκος είναι απόλυτα σταθερός και υγιής." -ForegroundColor $Green
            } else {
                Write-Host "  ⚠️ Συνιστάται backup λόγω καταγεγραμμένων σφαλμάτων read/write." -ForegroundColor $Yellow
            }
            Write-Host "`n"
            continue
        } else {
            Write-Host "⚠️ Δεν είναι δυνατή η ανάκτηση των δεδομένων S.M.A.R.T. ή Reliability Counters." -ForegroundColor $Yellow
            continue
        }
    }

    if (-not $attributes) {
        if ($disk.SmartctlIssue) {
            Write-Host "  🔧 smartctl: $($disk.SmartctlIssue)" -ForegroundColor $Gray
        }
        Write-Host "⚠️ Δεν βρέθηκαν S.M.A.R.T. δεδομένα για αυτόν τον δίσκο.`n" -ForegroundColor $Yellow
        continue
    }

    # 5. Υπολογισμός Υγείας (Health Calculation)
    $health = $null
    $healthSource = "No trusted vendor wear attribute"
    $healthMetricLabel = "Health"

    $wearB1 = $attributes | Where-Object { $_.ID -eq 0xB1 }
    $wearE9 = $attributes | Where-Object { $_.ID -eq 0xE9 }
    $wearA9 = $attributes | Where-Object { $_.ID -eq 0xA9 }
    $wear05 = $attributes | Where-Object { $_.ID -eq 0x05 }

    if ($brand -eq "NVMe" -and $wear05) {
        $health = 100 - $wear05.Raw
        $healthSource = "Percentage Used (0x05)"
    } elseif ($brand -ne 'NVMe') {
        $ataLife = Get-AtaLifeEstimate `
            -SmartData $smart `
            -Profile $brand `
            -Attributes $attributes `
            -ReliabilityCounter $disk.ReliabilityCounter
        if ($ataLife.IsTrusted) {
            $health = $ataLife.Percentage
            $healthSource = $ataLife.Source
            $healthMetricLabel = $ataLife.MetricLabel
        }
    }

    # Έλεγχος Κρίσιμων Σφαλμάτων (SATA & NVMe)
    $reallocated = $attributes | Where-Object { $_.ID -eq 0x05 }
    $uncorrectableA0 = $attributes | Where-Object { $_.ID -eq 0xA0 }
    $runtimeB2 = $attributes | Where-Object { $_.ID -eq 0xB2 }
    $runtimeB7 = $attributes | Where-Object { $_.ID -eq 0xB7 }
    $uncorrectableBB = $attributes | Where-Object { $_.ID -eq 0xBB }
    $reallocEventC4 = $attributes | Where-Object { $_.ID -eq 0xC4 }
    $pendingC5 = $attributes | Where-Object { $_.ID -eq 0xC5 }
    $uncorrectableC6 = $attributes | Where-Object { $_.ID -eq 0xC6 }
    $grownBadAA = $attributes | Where-Object { $_.ID -eq 0xAA }
    $programFailAB = $attributes | Where-Object { $_.ID -eq 0xAB }
    $eraseFailAC = $attributes | Where-Object { $_.ID -eq 0xAC }

    $nvmeCriticalWarning = $attributes | Where-Object { $_.ID -eq 0x01 }
    $nvmeMediaErrors = $attributes | Where-Object { $_.ID -eq 0x0E }

    $status = "GOOD"
    $statusColor = $Green
    $statusIcon = "✅"
    $cautionReasons = @()
    $badReasons = @()
    $retiredBlocksOnly = $false
    $hasActiveMediaErrors = $false

    if ($brand -ne "NVMe") {
        if ($brand -eq 'SanDisk' -and (($reallocated -and $reallocated.Raw -gt 0) -or ($grownBadAA -and $grownBadAA.Raw -gt 0))) {
            $status = "CAUTION"
            $statusColor = $Yellow
            $statusIcon = "⚠️"
            $grownCount = [Math]::Max($(if ($reallocated) { [long]$reallocated.Raw } else { 0 }), $(if ($grownBadAA) { [long]$grownBadAA.Raw } else { 0 }))
            $cautionReasons += "Grown/reassigned NAND blocks ($grownCount)"
            $retiredBlocksOnly = $true
        } elseif ($reallocated -and $reallocated.Raw -gt 0) {
            $status = "CAUTION"
            $statusColor = $Yellow
            $statusIcon = "⚠️"
            $cautionReasons += "Reallocated Sectors ($($reallocated.Raw))"
        }
        if ($brand -eq "SiliconMotionOEM" -and $uncorrectableA0 -and $uncorrectableA0.Raw -gt 0) {
            $status = "CAUTION"
            $statusColor = $Yellow
            $statusIcon = "⚠️"
            $cautionReasons += "Uncorrectable Sectors Read/Write ($($uncorrectableA0.Raw))"
            $hasActiveMediaErrors = $true
        }
        if ($runtimeB2 -and $runtimeB2.Raw -gt 0 -and (Test-AtaRawWarningAttribute -Profile $brand -AttributeId 0xB2)) {
            $status = "CAUTION"
            $statusColor = $Yellow
            $statusIcon = "⚠️"
            $cautionReasons += "Runtime Invalid Blocks ($($runtimeB2.Raw))"
        }
        if ($runtimeB7 -and $runtimeB7.Raw -gt 0 -and (Test-AtaRawWarningAttribute -Profile $brand -AttributeId 0xB7)) {
            $status = "CAUTION"
            $statusColor = $Yellow
            $statusIcon = "⚠️"
            $cautionReasons += "Runtime Bad Blocks ($($runtimeB7.Raw))"
        }
        if ($uncorrectableBB -and $uncorrectableBB.Raw -gt 0) {
            $status = "CAUTION"
            $statusColor = $Yellow
            $statusIcon = "⚠️"
            $cautionReasons += "Reported Uncorrectable Errors ($($uncorrectableBB.Raw))"
            $hasActiveMediaErrors = $true
        }
        if ($reallocEventC4 -and $reallocEventC4.Raw -gt 0) {
            $status = "CAUTION"
            $statusColor = $Yellow
            $statusIcon = "⚠️"
            $cautionReasons += "Reallocation Events ($($reallocEventC4.Raw))"
        }
        if ($pendingC5 -and $pendingC5.Raw -gt 0) {
            $status = "CAUTION"
            $statusColor = $Yellow
            $statusIcon = "⚠️"
            $cautionReasons += "Current Pending Sectors ($($pendingC5.Raw))"
            $hasActiveMediaErrors = $true
        }
        if ($uncorrectableC6 -and $uncorrectableC6.Raw -gt 0) {
            $status = "CAUTION"
            $statusColor = $Yellow
            $statusIcon = "⚠️"
            $cautionReasons += "Offline Uncorrectable Errors ($($uncorrectableC6.Raw))"
            $hasActiveMediaErrors = $true
        }
        if ($programFailAB -and $programFailAB.Raw -gt 0 -and (Test-AtaRawWarningAttribute -Profile $brand -AttributeId 0xAB)) {
            $status = "CAUTION"
            $statusColor = $Yellow
            $statusIcon = "⚠️"
            $cautionReasons += "Program Fail Count ($($programFailAB.Raw))"
            $hasActiveMediaErrors = $true
        }
        if ($eraseFailAC -and $eraseFailAC.Raw -gt 0 -and (Test-AtaRawWarningAttribute -Profile $brand -AttributeId 0xAC)) {
            $status = "CAUTION"
            $statusColor = $Yellow
            $statusIcon = "⚠️"
            $cautionReasons += "Erase Fail Count ($($eraseFailAC.Raw))"
            $hasActiveMediaErrors = $true
        }

        # Threshold crossings check
        foreach ($attr in $attributes) {
            if ($attr.Threshold -gt 0 -and $attr.Current -le $attr.Threshold) {
                $status = "BAD"
                $statusColor = $Red
                $statusIcon = "❌"
                $badReasons += "$($attr.Name) (Current $($attr.Current) <= Threshold $($attr.Threshold))"
            }
        }
    }
    else {
        if ($smart.smart_status -and $smart.smart_status.passed -eq $false) {
            $status = "BAD"
            $statusColor = $Red
            $statusIcon = "❌"
            $badReasons += "smartctl overall-health result is FAILED"
        }
        if ($nvmeCriticalWarning -and $nvmeCriticalWarning.Raw -gt 0) {
            $status = "BAD"
            $statusColor = $Red
            $statusIcon = "❌"
            $badReasons += "Critical Warning (Status Code: $($nvmeCriticalWarning.RawHex))"
        }
        if ($nvmeMediaErrors -and $nvmeMediaErrors.Raw -gt 0) {
            if ($nvmeMediaErrors.IsTelemetryAnomaly) {
                if ($status -eq "GOOD") {
                    $status = "REVIEW"
                    $statusColor = $Yellow
                    $statusIcon = "🔎"
                }
                $cautionReasons += "Inconsistent 128-bit NVMe telemetry: full=$($nvmeMediaErrors.Raw), low64=$($nvmeMediaErrors.Low64), error-log entries=0"
            } elseif ($status -ne "BAD") {
                $status = "CAUTION"
                $statusColor = $Yellow
                $statusIcon = "⚠️"
                $cautionReasons += "Media and Data Integrity Errors ($($nvmeMediaErrors.Raw))"
            }
        }
    }

    if ($status -eq 'GOOD' -and -not $isRotationalMedia -and $null -eq $health) {
        $status = 'REVIEW'
        $statusColor = $Yellow
        $statusIcon = '🔎'
        $cautionReasons += 'No trustworthy SSD lifetime reading was available'
    }

    # Health % color code
    $healthPercentColor = $Green
    if ($status -ne "GOOD") {
        $healthPercentColor = $statusColor
    } elseif ($null -ne $health -and $health -le 60) {
        $healthPercentColor = $Yellow
    }

    Write-Host "### 🔵 Κατάσταση Υγείας (Health Status)" -ForegroundColor $Cyan
    Write-Host "  $statusIcon Κατάσταση: " -NoNewline -ForegroundColor $White
    Write-Host "$status " -NoNewline -ForegroundColor $statusColor
    Write-Host "(" -NoNewline -ForegroundColor $White
    $healthDisplay = if ($null -eq $health -and $isRotationalMedia) { 'SMART' } elseif ($null -eq $health) { 'UNSUPPORTED' } elseif ($healthMetricLabel -eq 'Health') { "$health%" } else { "$healthMetricLabel $health%" }
    Write-Host $healthDisplay -NoNewline -ForegroundColor $healthPercentColor
    Write-Host ")" -ForegroundColor $White

    $diagnosticSupported = [bool]($isRotationalMedia -or $null -ne $health)
    Write-Host "  🔸 Υποστήριξη διάγνωσης: " -NoNewline -ForegroundColor $White
    Write-Host $(if ($diagnosticSupported) { 'SUPPORTED' } else { 'UNSUPPORTED' }) `
        -ForegroundColor $(if ($diagnosticSupported) { $Green } else { $Yellow })

    if ($status -eq "GOOD") {
        if ($isRotationalMedia) {
            $reportTextWidth = Get-ConsoleSafeTextWidth
            Write-WrappedConsoleText -Text "Οι μηχανικοί HDD δεν διαθέτουν τυποποιημένο wear/health percentage. Η αξιολόγηση βασίζεται στο SMART overall status, στα thresholds και στους κρίσιμους raw counters." -FirstPrefix "  🔸 " -ContinuationPrefix "     " -MaximumWidth $reportTextWidth -ForegroundColor $Gray
            if ($isSeagateHdd) {
                Write-WrappedConsoleText -Text "Seagate 01/07/C3: τα individual values είναι proprietary. Score πάνω από Fail <= σημαίνει μόνο ότι δεν ενεργοποιήθηκε failure condition· δεν αποδεικνύει από μόνο του φυσιολογική κατάσταση." -FirstPrefix "  🔸 " -ContinuationPrefix "     " -MaximumWidth $reportTextWidth -ForegroundColor $Gray
            }
        } elseif ($null -eq $health) {
            Write-Host "  ⚠️ UNSUPPORTED: Το SMART overall status πέρασε, αλλά δεν βρέθηκε αξιόπιστη ένδειξη υπολειπόμενης ζωής SSD." -ForegroundColor $Yellow
        } else {
            Write-Host "  🔸 Ο δίσκος εμφανίζει φυσιολογική φθορά της NAND flash μνήμης (πηγή: $healthSource)." -ForegroundColor $Gray
        }
        Write-Host "  🔸 Δεν ανιχνεύθηκαν ενεργά SMART failure indicators κατά τη συγκεκριμένη συλλογή." -ForegroundColor $Gray
    } elseif ($status -eq "REVIEW") {
        if (-not $diagnosticSupported) {
            Write-Host "  ⚠️ UNSUPPORTED: Το SMART overall status πέρασε, αλλά δεν βρέθηκε αξιόπιστη ένειξη υπολειπόμενης ζωής SSD." -ForegroundColor $Yellow
            Write-Host "  🔸 Δεν εκδίδεται health percentage ή βέβαιο GOOD συμπέρασμα χωρίς τέτοιο evidence." -ForegroundColor $Gray
        } else {
            Write-Host "  🔎 ΑΠΑΙΤΕΙ ΕΛΕΓΧΟ: Εντοπίστηκε ασυνεπής NVMe telemetry που δεν πρέπει να μετατραπεί ούτε σε 0 ούτε σε αυτόματη αστοχία:" -ForegroundColor $Yellow
            foreach ($r in $cautionReasons) {
                Write-Host "     - $r" -ForegroundColor $Yellow
            }
            Write-Host "  🔸 Η ένδειξη ζωής NAND παραμένει ανεξάρτητη από αυτή την ανωμαλία. Απαιτείται επιβεβαίωση με raw log, firmware/vendor στοιχεία και διαγνωστικό test." -ForegroundColor $Gray
        }
    } elseif ($status -eq "CAUTION") {
        Write-Host "  ⚠️ ΠΡΟΣΟΧΗ: Εντοπίστηκαν προβλήματα στα παρακάτω κρίσιμα attributes:" -ForegroundColor $Yellow
        foreach ($r in $cautionReasons) {
            Write-Host "     - $r" -ForegroundColor $Yellow
        }
        if ($brand -eq 'SanDisk' -and $retiredBlocksOnly -and -not $hasActiveMediaErrors) {
            Write-Host "  🔸 Καταγράφηκε ιστορική απόσυρση NAND blocks, αλλά όχι τρέχον uncorrectable/program/erase error σε αυτό το snapshot." -ForegroundColor $Gray
        }
        Write-Host "  🔸 Συνιστάται άμεσο backup, SMART self-test και αποθήκευση baseline για έλεγχο αν οι μετρητές αυξάνονται." -ForegroundColor $Gray
    } else {
        Write-Host "  🚨 ΚΡΙΣΙΜΟ: Ο δίσκος έχει ξεπεράσει τα όρια ασφαλείας του firmware!" -ForegroundColor $Red
        foreach ($r in $badReasons) {
            Write-Host "     - $r" -ForegroundColor $Red
        }
        Write-Host "  🚨 ALL CAPS: ΣΥΝΙΣΤΑΤΑΙ ΑΜΕΣΗ ΑΝΤΙΚΑΤΑΣΤΑΣΗ ΤΟΥ ΔΙΣΚΟΥ ΚΑΙ ΜΕΤΑΦΟΡΑ ΔΕΔΟΜΕΝΩΝ." -ForegroundColor $Red
    }
    Write-Host ""

    # 6. S.M.A.R.T. Table
    Write-Host "### 🔵 Ανάλυση S.M.A.R.T. Τιμών" -ForegroundColor $Cyan

    if ($brand -ne 'NVMe') {
        $legendRows = Get-SmartTableLegendRows -TextLines @(
            'Score/Worst = vendor-normalized values; not errors or percentages.'
            'Fail <= = firmware failure floor. Vendor Raw = opaque manufacturer telemetry.'
        )
        foreach ($legendRow in $legendRows) {
            Write-Host $legendRow -ForegroundColor $Gray
        }
    }

    Write-Host "  +------+------------------------------------+---------+---------+-----------+-------------------+" -ForegroundColor $Gray
    if ($brand -eq 'NVMe') {
        Write-Host "  | ID   | Attribute Name                     | Current | Worst   | Threshold | Value             |" -ForegroundColor $Gray
    } else {
        Write-Host "  | ID   | Attribute Name                     | Score   | Worst   | Fail <=   | Vendor Raw        |" -ForegroundColor $Gray
    }
    Write-Host "  +------+------------------------------------+---------+---------+-----------+-------------------+" -ForegroundColor $Gray

    $visibleAttributes = $attributes | Sort-Object ID

    foreach ($attr in $visibleAttributes) {
        $nameTrunc = if ($attr.Name.Length -gt 34) { $attr.Name.Substring(0, 31) + "..." } else { $attr.Name.PadRight(34) }
        $idStr = $attr.IDHex.PadRight(4)

        $curStr = if ($brand -eq "NVMe") { "---".PadLeft(7) } else { "$($attr.Current)".PadLeft(7) }
        $worStr = if ($brand -eq "NVMe") { "---".PadLeft(7) } else { "$($attr.Worst)".PadLeft(7) }
        $thrStr = if ($brand -eq "NVMe") { "---".PadLeft(9) } else { "$($attr.Threshold)".PadLeft(9) }

        $rawDisplay = ""
        if ($brand -eq "NVMe" -and $attr.ID -eq 0x0E -and $attr.IsTelemetryAnomaly) {
            $rawDisplay = "ANOMALY (low64=$($attr.Low64))".PadRight(17)
        } elseif (($brand -ne "NVMe" -and $attr.ID -eq 0x09) -or ($brand -eq "NVMe" -and $attr.ID -eq 0x0C)) {
            if ($brand -eq 'NVMe') {
                $rawDisplay = "$($attr.Raw) hrs".PadRight(17)
            } else {
                $decodedHours = Get-AtaPowerOnHoursValue -Attribute $attr -SmartData $smart
                $rawDisplay = if ($null -eq $decodedHours) { "raw=$($attr.Raw)".PadRight(17) } else { "$decodedHours hrs".PadRight(17) }
            }
        } elseif (($brand -ne "NVMe" -and $attr.ID -eq 0x0C) -or ($brand -eq "NVMe" -and $attr.ID -eq 0x0B)) {
            $rawDisplay = "$($attr.Raw) cycles".PadRight(17)
        } elseif ($isRotationalMedia -and $disk.Model -match '(?i)^(?:WDC|Western Digital|WD\s)' -and $attr.ID -eq 0x03) {
            $rawDisplay = (Get-AtaSpinUpTimeDisplay -RawMilliseconds ([long]$attr.Raw)).PadRight(17)
        } elseif ($attr.ID -eq 0xBE -or $attr.ID -eq 0xC2) {
            $temperatureCelsius = Get-AtaTemperatureCelsius -Attribute $attr -SmartData $smart
            $rawDisplay = if ($null -eq $temperatureCelsius) { "raw=$($attr.Raw)".PadRight(17) } else { "$temperatureCelsius C".PadRight(17) }
        } elseif ($brand -eq "NVMe" -and $attr.ID -eq 0x02) {
            $tempVal = if ($attr.IsCelsius) { $attr.Raw } elseif ($attr.Raw -gt 200) { $attr.Raw - 273 } else { $attr.Raw }
            $rawDisplay = "$tempVal C".PadRight(17)
        } elseif ($brand -eq "NVMe" -and ($attr.ID -eq 0x12 -or $attr.ID -eq 0x13)) {
            $tempVal = if ($attr.IsCelsius) { $attr.Raw } elseif ($attr.Raw -gt 200) { $attr.Raw - 273 } else { $attr.Raw }
            $rawDisplay = "$tempVal C".PadRight(17)
        } elseif ($brand -eq "NVMe" -and ($attr.ID -eq 0x06 -or $attr.ID -eq 0x07)) {
            $gbVal = [Math]::Round(([decimal]$attr.Raw * 512000) / 1GB, 2)
            $rawDisplay = "$gbVal GB".PadRight(17)
        } else {
            $rawDisplay = "$($attr.Raw)".PadRight(17)
        }

        # Coloring
        $lineColor = $Gray
        if ($brand -ne "NVMe") {
            $seagateRateState = Get-SeagateNormalizedRateState -AttributeId $attr.ID -Current $attr.Current -Threshold $attr.Threshold -IsSeagateHdd $isSeagateHdd
            if ($seagateRateState -ne 'NotApplicable') {
                # Neutral unless the firmware threshold is actually crossed.
                # Passing one proprietary attribute is not a green health claim.
                if ($seagateRateState -eq 'ThresholdCrossed') { $lineColor = $Red }
                else { $lineColor = $Gray }
            } elseif ($brand -eq 'KingstonUV400') {
                if ($attr.ID -eq 0xE7) {
                    if ($attr.Threshold -gt 0 -and $attr.Current -le $attr.Threshold) { $lineColor = $Red }
                    elseif ($attr.Current -le 10) { $lineColor = $Red }
                    elseif ($attr.Current -le 60) { $lineColor = $Yellow }
                    else { $lineColor = $Green }
                } elseif (Test-AtaRawWarningAttribute -Profile $brand -AttributeId $attr.ID) {
                    $lineColor = if ($attr.Raw -gt 0) { $Yellow } else { $Green }
                }
            } elseif ($brand -eq 'SanDisk') {
                $sanDiskErrorIds = @(0x05, 0xAA, 0xAB, 0xAC, 0xB8, 0xBB, 0xBC, 0xC4, 0xC5, 0xC6)
                if ($attr.ID -in $sanDiskErrorIds) {
                    $lineColor = if ($attr.Raw -gt 0) { $Yellow } else { $Green }
                } elseif ($attr.ID -eq 0xE8) {
                    if ($attr.Raw -le $attr.Threshold -and $attr.Threshold -gt 0) { $lineColor = $Red }
                    elseif ($attr.Raw -lt 100) { $lineColor = $Yellow }
                    else { $lineColor = $Green }
                }
            } else {
                $isCriticalAttr = Test-AtaRawWarningAttribute -Profile $brand -AttributeId $attr.ID
                $isWearAttr = (
                    ($brand -eq 'Samsung' -and $attr.ID -eq 0xB1) -or
                    ($brand -in @('SiliconMotionOEM', 'PatriotBurst') -and $attr.ID -eq 0xA9) -or
                    ($brand -eq 'Phison' -and $attr.ID -eq 0xE7)
                )
                if ($isCriticalAttr -or $isWearAttr) {
                    $isProblematic = $false
                    $isFailed = $false

                    if ($isWearAttr) {
                        $val = if ($attr.ID -in @(0xA9, 0xE7)) { $attr.Raw } else { $attr.Current }
                        if ($val -le 10) { $isFailed = $true }
                        elseif ($val -le 60) { $isProblematic = $true }
                    } else {
                        if ($attr.Raw -gt 0) {
                            if ($attr.Current -le $attr.Threshold -and $attr.Threshold -gt 0) { $isFailed = $true }
                            else { $isProblematic = $true }
                        }
                    }

                    if ($isFailed) { $lineColor = $Red }
                    elseif ($isProblematic) { $lineColor = $Yellow }
                    else { $lineColor = $Green }
                }
            }
            if ($attr.Threshold -gt 0 -and $attr.Current -le $attr.Threshold) {
                $lineColor = $Red
            }
        }
        else {
            $isCriticalAttr = ($attr.ID -eq 0x01 -or $attr.ID -eq 0x03 -or $attr.ID -eq 0x05 -or $attr.ID -eq 0x0E)
            if ($isCriticalAttr) {
                $isProblematic = $false
                $isFailed = $false

                if ($attr.ID -eq 0x01) {
                    if ($attr.Raw -gt 0) { $isFailed = $true }
                } elseif ($attr.ID -eq 0x0E) {
                    if ($attr.Raw -gt 0) { $isProblematic = $true }
                } elseif ($attr.ID -eq 0x03) {
                    if ($attr.Raw -lt 10) { $isFailed = $true }
                    elseif ($attr.Raw -lt 90) { $isProblematic = $true }
                } elseif ($attr.ID -eq 0x05) {
                    if ($attr.Raw -gt 50) { $isFailed = $true }
                    elseif ($attr.Raw -gt 10) { $isProblematic = $true }
                }

                if ($isFailed) { $lineColor = $Red }
                elseif ($isProblematic) { $lineColor = $Yellow }
                else { $lineColor = $Green }
            }
        }

        Write-Host "  | $idStr | $nameTrunc | $curStr | $worStr | $thrStr | $rawDisplay |" -ForegroundColor ([ConsoleColor]$lineColor)
    }
    Write-Host "  +------+------------------------------------+---------+---------+-----------+-------------------+" -ForegroundColor $Gray
    Write-Host ""

    $seagateReadEcc = Get-SeagateReadEccContext -Attributes $attributes -SmartData $smart -IsSeagateHdd $isSeagateHdd
    if ($null -ne $seagateReadEcc) {
        $reportTextWidth = Get-ConsoleSafeTextWidth
        Write-Host "### 🔵 Seagate Read / ECC Context" -ForegroundColor $Cyan
        Write-WrappedConsoleText -Text "Vendor score: Current $($seagateReadEcc.Current), Worst $($seagateReadEcc.Worst), firmware failure floor $($seagateReadEcc.Threshold)." -FirstPrefix "  🔸 " -ContinuationPrefix "     " -MaximumWidth $reportTextWidth -ForegroundColor $Gray
        Write-WrappedConsoleText -Text "Τα παραπάνω είναι proprietary scores — όχι αριθμός errors, error rate ή health percentage." -FirstPrefix "     " -ContinuationPrefix "     " -MaximumWidth $reportTextWidth -ForegroundColor $Gray

        if ($seagateReadEcc.HasMirroredRawTelemetry) {
            Write-WrappedConsoleText -Text "Τα 01 Raw Read Error Rate και C3 Hardware ECC Recovered εκθέτουν το ίδιο Vendor Raw: $($seagateReadEcc.ReadRaw)." -FirstPrefix "  🔸 " -ContinuationPrefix "     " -MaximumWidth $reportTextWidth -ForegroundColor $Gray
            Write-WrappedConsoleText -Text "Η κοινή τιμή δείχνει shared read/ECC telemetry· η Seagate δεν δημοσιεύει αποκωδικοποίηση ή μονάδα μέτρησης." -FirstPrefix "     " -ContinuationPrefix "     " -MaximumWidth $reportTextWidth -ForegroundColor $Gray
        } else {
            Write-WrappedConsoleText -Text "Vendor Raw 01: $($seagateReadEcc.ReadRaw) | Vendor Raw C3: $($seagateReadEcc.EccRaw)." -FirstPrefix "  🔸 " -ContinuationPrefix "     " -MaximumWidth $reportTextWidth -ForegroundColor $Gray
            Write-WrappedConsoleText -Text "Οι τιμές διατηρούνται για baseline/trend comparison και δεν μετατρέπονται σε υποθετικό error count." -FirstPrefix "     " -ContinuationPrefix "     " -MaximumWidth $reportTextWidth -ForegroundColor $Gray
        }

        $errorLogDisplay = if ($null -eq $seagateReadEcc.ErrorLogCount) { 'N/A' } else { "$($seagateReadEcc.ErrorLogCount)" }
        Write-WrappedConsoleText -Text "Unresolved evidence:" -FirstPrefix "  🔸 " -ContinuationPrefix "     " -MaximumWidth $reportTextWidth -ForegroundColor $Gray
        Write-WrappedConsoleText -Text "Reallocated=$($seagateReadEcc.Reallocated) | Reported Uncorrectable=$($seagateReadEcc.ReportedUncorrectable)" -FirstPrefix "     " -ContinuationPrefix "     " -MaximumWidth $reportTextWidth -ForegroundColor $Gray
        Write-WrappedConsoleText -Text "Pending=$($seagateReadEcc.Pending) | Offline Uncorrectable=$($seagateReadEcc.OfflineUncorrectable) | SMART Error Log=$errorLogDisplay" -FirstPrefix "     " -ContinuationPrefix "     " -MaximumWidth $reportTextWidth -ForegroundColor $Gray

        if ($seagateReadEcc.HasUnresolvedIndicators) {
            Write-WrappedConsoleText -Text "Υπάρχει τουλάχιστον ένας καταγεγραμμένος unresolved/media indicator· απαιτείται ξεχωριστή αξιολόγηση και test." -FirstPrefix "  ⚠️ " -ContinuationPrefix "     " -MaximumWidth $reportTextWidth -ForegroundColor $Yellow
        } elseif ($null -ne $seagateReadEcc.ErrorLogCount) {
            Write-WrappedConsoleText -Text "Δεν καταγράφηκε unresolved read/media error στα διαθέσιμα counters και στο SMART Error Log αυτού του snapshot." -FirstPrefix "  ✅ " -ContinuationPrefix "     " -MaximumWidth $reportTextWidth -ForegroundColor $Green
        } else {
            Write-WrappedConsoleText -Text "Δεν καταγράφηκε unresolved read/media error στα διαθέσιμα counters· το SMART Error Log δεν ήταν διαθέσιμο." -FirstPrefix "  🔸 " -ContinuationPrefix "     " -MaximumWidth $reportTextWidth -ForegroundColor $Gray
        }
        Write-Host ""
    }

    # 7. Συμπέρασμα & Ενέργειες (Conclusion)
    Write-Host "### 🔵 Συμπέρασμα & Ενέργειες" -ForegroundColor $Cyan
    if ($status -eq "GOOD") {
        $phAttr = if ($brand -eq "NVMe") { $attributes | Where-Object {$_.ID -eq 0x0C} } else { $attributes | Where-Object {$_.ID -eq 0x09} }
        $phVal = if (-not $phAttr) { $null } elseif ($brand -eq 'NVMe') { [long]$phAttr.Raw } else { Get-AtaPowerOnHoursValue -Attribute $phAttr -SmartData $smart }
        Write-Host "  ✅ Δεν ανιχνεύθηκαν ενεργά SMART failure indicators κατά τη συγκεκριμένη συλλογή." -ForegroundColor $Green
        if ($null -ne $phVal) {
            Write-Host "  💡 Συμβουλή: Με $phVal ώρες λειτουργίας, η τήρηση τακτικού backup παραμένει standard πρακτική." -ForegroundColor $Gray
        } else {
            Write-Host "  💡 Συμβουλή: Η τήρηση τακτικού backup παραμένει standard πρακτική." -ForegroundColor $Gray
        }
    } elseif ($status -eq "REVIEW") {
        if (-not $diagnosticSupported) {
            Write-Host "  ⚠️ SSD health diagnosis: UNSUPPORTED. Διατηρήστε backup και μη βασίζετε απόφαση σε αυτό το snapshot." -ForegroundColor $Yellow
        } else {
            Write-Host "  🔎 Η εκτίμηση ζωής NAND είναι $health%, αλλά υπάρχει ασυνεπής raw NVMe telemetry." -ForegroundColor $Yellow
            Write-Host "  ⚠️ Μην αποφασίσετε αντικατάσταση ή αθώωση του δίσκου μόνο από αυτό το counter. Διατηρήστε backup και εκτελέστε πρόσθετο non-destructive validation." -ForegroundColor $Yellow
        }
    } elseif ($status -eq "CAUTION") {
        if ($brand -eq 'SanDisk' -and $retiredBlocksOnly -and -not $hasActiveMediaErrors) {
            Write-Host "  ⚠️ Έχουν αποσυρθεί NAND blocks, όμως η συγκεκριμένη συλλογή δεν αποδεικνύει ότι η φθορά συνεχίζεται τώρα." -ForegroundColor $Yellow
            Write-Host "  🔸 Κρατήστε backup, εκτελέστε extended SMART self-test και επαναλάβετε τη μέτρηση. Αν τα 05/AA αυξηθούν, εμφανιστούν uncorrectable/program/erase errors ή αποτύχει το self-test, προχωρήστε σε αντικατάσταση." -ForegroundColor $Yellow
        } elseif ($hasActiveMediaErrors) {
            Write-Host "  ⚠️ Εντοπίστηκαν ενεργοί δείκτες media/data errors. Απαιτείται άμεσο backup και επιβεβαίωση με extended SMART self-test." -ForegroundColor $Yellow
            Write-Host "  🔸 Αν το self-test αποτύχει ή οι μετρητές αυξάνονται, αντικαταστήστε τον δίσκο." -ForegroundColor $Yellow
        } else {
            Write-Host "  ⚠️ Εντοπίστηκαν SMART warning indicators. Ένα μόνο snapshot δεν αρκεί για να αποδείξει επιδείνωση." -ForegroundColor $Yellow
            Write-Host "  🔸 Κρατήστε backup, εκτελέστε extended SMART self-test και συγκρίνετε με νέα μέτρηση πριν αποφασίσετε αντικατάσταση." -ForegroundColor $Yellow
        }
    } else {
        Write-Host "  🚨 Ο δίσκος βρίσκεται σε κρίσιμη κατάσταση αστοχίας." -ForegroundColor $Red
        Write-Host "  🚨 ALL CAPS: ΑΝΤΙΚΑΤΑΣΤΗΣΤΕ ΤΟΝ ΔΙΣΚΟ ΑΜΕΣΑ ΓΙΑ ΑΠΟΦΥΓΗ ΑΠΩΛΕΙΑΣ ΔΕΔΟΜΕΝΩΝ." -ForegroundColor $Red
    }

    if ($brand -ne 'NVMe' -and -not $isRotationalMedia) {
        $dataTotals = Get-AtaDataTransferEstimate -Profile $brand -Attributes $attributes -SmartData $smart
        if ($dataTotals.IsSupported) {
            Write-Host "`n  🔵 Lifetime Data Totals:" -ForegroundColor $Cyan
            if ($null -ne $dataTotals.HostReadsGiB) {
                Write-Host "  🔸 Host Reads: " -NoNewline -ForegroundColor $White
                Write-Host (("{0:N2} GiB ({1:N2} TiB)" -f $dataTotals.HostReadsGiB, ($dataTotals.HostReadsGiB / 1024))) -ForegroundColor $Gray
            }
            if ($null -ne $dataTotals.HostWritesGiB) {
                Write-Host "  🔸 Host Writes: " -NoNewline -ForegroundColor $White
                Write-Host (("{0:N2} GiB ({1:N2} TiB)" -f $dataTotals.HostWritesGiB, ($dataTotals.HostWritesGiB / 1024))) -ForegroundColor $Gray
            }
            if ($null -ne $dataTotals.NandWritesGiB) {
                Write-Host "  🔸 NAND Writes: " -NoNewline -ForegroundColor $White
                Write-Host (("{0:N2} GiB ({1:N2} TiB)" -f $dataTotals.NandWritesGiB, ($dataTotals.NandWritesGiB / 1024))) -ForegroundColor $Gray
            }
            if ($null -ne $dataTotals.WriteAmplification) {
                Write-Host "  🔸 Lifetime Write Amplification: " -NoNewline -ForegroundColor $White
                Write-Host "$($dataTotals.WriteAmplification)`x" -ForegroundColor $(if ($dataTotals.WriteAmplification -gt 3) { $Yellow } else { $Gray })
                if ($dataTotals.WriteAmplification -gt 3) {
                    Write-Host "     Υψηλό lifetime WAF: συμβατό με SLC-cache folding, garbage collection σε υψηλή πληρότητα ή/και wear leveling." -ForegroundColor $Yellow
                }
            }
            Write-Host "  🔸 Counter source: $($dataTotals.Source)" -ForegroundColor $Gray
        } else {
            Write-Host "`n  ⚠️ Lifetime Data Totals: UNSUPPORTED (unknown raw counter units)." -ForegroundColor $Yellow
        }
    }

    # Samsung Specific Notes
    if ($brand -eq "Samsung") {
        $wearB1 = $attributes | Where-Object { $_.ID -eq 0xB1 }
        $unusedB4 = $attributes | Where-Object { $_.ID -eq 0xB4 }
        $porRecovery = $attributes | Where-Object { $_.ID -eq 0xEB }

        Write-Host "`n  🔵 Ειδική Παρατήρηση Samsung SSD:" -ForegroundColor $Cyan
        if ($wearB1) {
            Write-Host "  🔸 Το Wear Leveling Count (B1) δείχνει $($wearB1.Raw) κύκλους εγγραφής/διαγραφής (P/E cycles)." -ForegroundColor $Gray
        }
        if ($unusedB4) {
            Write-Host "  🔸 Το Available Reserved Blocks (B4) είναι $($unusedB4.Raw), που σημαίνει ότι τα εργοστασιακά spare blocks είναι εντελώς άθικτα." -ForegroundColor $Gray
        }
        if ($porRecovery -and $porRecovery.Raw -gt 0) {
            Write-Host "  🔸 Το POR Recovery Count (EB) είναι $($porRecovery.Raw). Αυτό δείχνει sudden power loss recoveries (απότομη απώλεια ρεύματος)." -ForegroundColor $Gray
        }
    }

    # Silicon Motion / Patriot controller-specific notes
    if ($brand -in @('SiliconMotionOEM', 'PatriotBurst')) {
        $wearA9 = $attributes | Where-Object { $_.ID -eq 0xA9 }
        $profileLabel = if ($brand -eq 'SiliconMotionOEM') { 'Silicon Motion OEM' } else { 'Patriot Burst' }
        Write-Host "`n  🔵 Ειδική Παρατήρηση $profileLabel profile:" -ForegroundColor $Cyan
        if ($wearA9) {
            Write-Host "  🔸 Η υπολειπόμενη ζωή (Remain Life) είναι " -NoNewline -ForegroundColor $White
            Write-Host "$($wearA9.Raw)%" -ForegroundColor $Yellow
        }
    }

    if ($brand -eq 'Phison') {
        $lifeE7 = $attributes | Where-Object { $_.ID -eq 0xE7 } | Select-Object -First 1
        Write-Host "`n  🔵 Ειδική Παρατήρηση Phison profile:" -ForegroundColor $Cyan
        if ($lifeE7) {
            Write-Host "  🔸 Η υπολειπόμενη ζωή (SSD Life Left) είναι " -NoNewline -ForegroundColor $White
            Write-Host "$($lifeE7.Raw)%" -ForegroundColor $Yellow
        }
    }

    if ($brand -eq 'KingstonUV400') {
        $lifeE7 = $attributes | Where-Object { $_.ID -eq 0xE7 } | Select-Object -First 1
        $undocumentedB7 = $attributes | Where-Object { $_.ID -eq 0xB7 } | Select-Object -First 1

        Write-Host "`n  🔵 Ειδική Παρατήρηση Kingston UV400 profile:" -ForegroundColor $Cyan
        if ($lifeE7) {
            Write-Host "  🔸 Η επίσημη normalized υπολειπόμενη ζωή (0xE7 Current) είναι " -NoNewline -ForegroundColor $White
            Write-Host "$($lifeE7.Current)%" -ForegroundColor $(if ($lifeE7.Current -le 60) { $Yellow } else { $Green })
            Write-Host "  🔸 Το raw 0xE7 = $($lifeE7.Raw) διατηρείται ως ξεχωριστή vendor telemetry και δεν χρησιμοποιείται ως remaining-life percentage." -ForegroundColor $Gray
        }
        if ($undocumentedB7) {
            Write-Host "  🔸 Το 0xB7 raw = $($undocumentedB7.Raw) δεν περιλαμβάνεται στην επίσημη Kingston UV400 SMART specification· παραμένει ορατό χωρίς failure συμπέρασμα." -ForegroundColor $Gray
        }
    }

    # SanDisk/WD Specific Notes
    if ($brand -eq "SanDisk") {
        $badBlocksA9 = $attributes | Where-Object { $_.ID -eq 0xA9 }
        $grownAA = $attributes | Where-Object { $_.ID -eq 0xAA }
        $reallocated05 = $attributes | Where-Object { $_.ID -eq 0x05 }
        $spareE8 = $attributes | Where-Object { $_.ID -eq 0xE8 }

        Write-Host "`n  🔵 Ειδική Παρατήρηση SanDisk/WD SSD:" -ForegroundColor $Cyan
        if ($badBlocksA9) {
            Write-Host "  🔸 Total Bad Blocks (A9): " -NoNewline -ForegroundColor $White
            Write-Host "$($badBlocksA9.Raw)" -ForegroundColor $Gray

            $hasGrownBad = ($grownAA -and $grownAA.Raw -gt 0) -or ($reallocated05 -and $reallocated05.Raw -gt 0)
            if (-not $hasGrownBad) {
                Write-Host "     - Δεν καταγράφονται grown/reassigned blocks (AA/05 = 0). Το A9 μόνο του δεν αποδεικνύει operational degradation." -ForegroundColor $Green
            } else {
                Write-Host "     - ⚠️ Έχουν καταγραφεί grown/reassigned NAND blocks κατά τη χρήση (AA/05 > 0)." -ForegroundColor $Yellow
                Write-Host "     - Αυτό αποδεικνύει ότι έγινε block retirement, όχι ότι ο ρυθμός βλάβης παραμένει ενεργός χωρίς σύγκριση με παλαιότερο baseline." -ForegroundColor $Gray
            }
        }
        if ($spareE8) {
            Write-Host "  🔸 Available Reserved Space (E8): " -NoNewline -ForegroundColor $White
            Write-Host "$($spareE8.Raw)%" -ForegroundColor $(if ($spareE8.Raw -lt 100) { "Yellow" } else { "Gray" })
            Write-Host "     - Είναι vendor reserve/endurance metric και όχι το proprietary συνολικό Health % του Hard Disk Sentinel." -ForegroundColor $Gray
        }
    }

    # NVMe Specific Notes
    if ($brand -eq "NVMe") {
        $wear05 = $attributes | Where-Object { $_.ID -eq 0x05 }
        $readUnits06 = $attributes | Where-Object { $_.ID -eq 0x06 }
        $writeUnits07 = $attributes | Where-Object { $_.ID -eq 0x07 }
        $unsafeShutdowns0D = $attributes | Where-Object { $_.ID -eq 0x0D }

        Write-Host "`n  🔵 Ειδική Παρατήρηση NVMe SSD:" -ForegroundColor $Cyan
        if ($wear05) {
            Write-Host "  🔸 Η συνολική φθορά (Percentage Used) είναι " -NoNewline -ForegroundColor $White
            Write-Host "$($wear05.Raw)%" -ForegroundColor $Yellow
        }
        if ($readUnits06 -and $writeUnits07) {
            $readGB = [Math]::Round(([decimal]$readUnits06.Raw * 512000) / 1GB, 2)
            $writeGB = [Math]::Round(([decimal]$writeUnits07.Raw * 512000) / 1GB, 2)
            Write-Host "  🔸 Host Reads: " -NoNewline -ForegroundColor $White
            Write-Host "$readGB GB" -ForegroundColor $Gray
            Write-Host "  🔸 Host Writes: " -NoNewline -ForegroundColor $White
            Write-Host "$writeGB GB" -ForegroundColor $Gray
        }
        if ($unsafeShutdowns0D -and $unsafeShutdowns0D.Raw -gt 0) {
            Write-Host "  🔸 Απότομες Διακοπές Ρεύματος (Unsafe Shutdowns): " -NoNewline -ForegroundColor $White
            Write-Host "$($unsafeShutdowns0D.Raw)" -ForegroundColor $Yellow
        }
        if ($smart.nvme_self_test_log) {
            $currentTest = $smart.nvme_self_test_log.current_self_test_operation
            if ($currentTest -and $currentTest.value -gt 0) {
                $completion = $smart.nvme_self_test_log.current_self_test_completion_percent
                Write-Host "  🔸 NVMe Self-Test: " -NoNewline -ForegroundColor $White
                Write-Host "$($currentTest.string) ($completion%)" -ForegroundColor $Yellow
            }

            $latestTest = $smart.nvme_self_test_log.table | Select-Object -First 1
            if ($latestTest) {
                Write-Host "  🔸 Latest Completed Self-Test: " -NoNewline -ForegroundColor $White
                Write-Host "$($latestTest.self_test_code.string) — $($latestTest.self_test_result.string)" -ForegroundColor $(if ($latestTest.self_test_result.value -eq 0) { $Green } else { $Yellow })
            }
        }
    }
    }
    } 6>&1
    )
    Complete-DiskHealthPerformanceStage -Token $evaluationToken -Status success -ResultCount $selectedDrives.Count

    if ($menuEnabled -and $runLoop) {
        $constructionToken = Start-DiskHealthPerformanceStage -Stage 'Report.Construction' -ParentStage 'Report'
        $reportRows = @(ConvertTo-DiskHealthReportRows -Records $reportRecords)
        Complete-DiskHealthPerformanceStage -Token $constructionToken -Status success -ResultCount $reportRows.Count
        Show-DiskHealthReport -Rows $reportRows -Target $ComputerName
    }
    else {
        $constructionToken = Start-DiskHealthPerformanceStage -Stage 'Report.Construction' -ParentStage 'Report'
        $renderRecords = @($reportRecords)
        Complete-DiskHealthPerformanceStage -Token $constructionToken -Status success -ResultCount $renderRecords.Count
        $firstFrameToken = Start-DiskHealthPerformanceStage -Stage 'Report.FirstRenderedFrame' -ParentStage 'Report'
        Write-DiskHealthCapturedOutput -Records $renderRecords
        Complete-DiskHealthPerformanceStage -Token $firstFrameToken -Status success -ResultCount $renderRecords.Count
        Save-DiskHealthPerformanceReport
    }
}

if ($null -ne $script:DiskHealthPerformanceContext -and -not $EmbeddedRemote -and -not $script:IsHomeLauncher) {
    Save-DiskHealthPerformanceReport -Finalize -ShowSummary
}
