#requires -version 5.1
[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingInvokeExpression', '', Justification = 'Loads the pinned TUI blueprint and selected production functions into the isolated regression scope.')]
param(
    [string]$PythonPath = '',
    [switch]$SkipVirtualTerminalReplay
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'DiskHealth.ps1'
$blueprintPath = Join-Path $repoRoot 'PS_UI_Blueprint.psm1'
$receiptPath = Join-Path $repoRoot 'PS_UI_Blueprint.sha256'
$expectedBlueprintHash = (Get-Content -Raw -LiteralPath $receiptPath).Trim()
$actualBlueprintHash = (Get-FileHash -LiteralPath $blueprintPath -Algorithm SHA256).Hash
if ($actualBlueprintHash -ne $expectedBlueprintHash) {
    throw "DiskHealth TUI blueprint drift. Expected=$expectedBlueprintHash Actual=$actualBlueprintHash"
}
Invoke-Expression (Get-Content -Raw -LiteralPath $blueprintPath)

$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw "Production parser errors: $($parseErrors -join '; ')" }
$scriptText = Get-Content -Raw -LiteralPath $scriptPath
if ($scriptText -notmatch '\$visibleBudget\s*=\s*\[Math\]::Max\(1,\s*\$height\s*-\s*11\)') {
    throw 'Choice menu must preserve one unused physical terminal row to prevent resize-triggered scrolling.'
}
foreach ($functionName in @(
        'Get-DiskHealthReportColorPriority'
        'ConvertTo-DiskHealthReportRows'
        'Split-DiskHealthReportText'
        'ConvertTo-DiskHealthCompactTableLines'
        'Get-DiskHealthAdaptiveTableWidths'
        'Get-DiskHealthAdaptiveHeaderCells'
        'ConvertTo-DiskHealthAdaptiveTableLines'
        'Get-DiskHealthReportAnsiColor'
        'Get-DiskHealthReportDisplayLines'
        'New-DiskHealthReportFrame'
        'Get-DiskHealthReportFramePayload'
    )) {
    $functionAst = $ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
        }, $true) | Select-Object -First 1
    if (-not $functionAst) { throw "Missing production TUI function: $functionName" }
    Invoke-Expression $functionAst.Extent.Text
}

function Assert-TuiRegression {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$captured = @(
    & {
        Write-Host '  Status: ' -NoNewline -ForegroundColor White
        Write-Host 'GOOD (SMART)' -ForegroundColor Green
        Write-Host '  This is a deliberately long diagnostic explanation which must reflow without crossing the terminal viewport boundary.' -ForegroundColor DarkGray
    } 6>&1
)
$capturedRows = @(ConvertTo-DiskHealthReportRows -Records $captured)
Assert-TuiRegression ($capturedRows.Count -eq 2) 'Write-Host NoNewline records were not merged into one logical report row.'
Assert-TuiRegression ($capturedRows[0].Text -eq '  Status: GOOD (SMART)') 'Captured mixed-span report text changed.'
Assert-TuiRegression ($capturedRows[0].Color -eq 'Green') 'Captured report row did not retain the diagnostic severity color.'

$reportRows = [System.Collections.Generic.List[object]]::new()
$reportRows.Add([pscustomobject]@{ Text = '### Disk details (Index: 1)'; Color = 'Cyan' })
$reportRows.Add([pscustomobject]@{ Text = '  Model: ST8000DM004-2U9188'; Color = 'Cyan' })
$reportRows.Add([pscustomobject]@{ Text = '  Status: GOOD (SMART)'; Color = 'Green' })
$reportRows.Add([pscustomobject]@{ Text = '  Seagate 01/07/C3 values are proprietary normalized scores and opaque vendor telemetry, not an error count or health percentage.'; Color = 'DarkGray' })
$reportRows.Add([pscustomobject]@{ Text = '  +------+------------------------------------+---------+---------+-----------+-------------------+'; Color = 'DarkGray' })
$reportRows.Add([pscustomobject]@{ Text = '  | ID   | Attribute Name                     | Score   | Worst   | Fail <=   | Vendor Raw        |'; Color = 'DarkGray' })
$reportRows.Add([pscustomobject]@{ Text = '  +------+------------------------------------+---------+---------+-----------+-------------------+'; Color = 'DarkGray' })
$reportRows.Add([pscustomobject]@{ Text = '  | 0x01 | Raw Read Error Rate                |      80 |      64 |         6 | 110953788         |'; Color = 'DarkGray' })
$reportRows.Add([pscustomobject]@{ Text = '  | 0x05 | Reallocated Sectors Count          |     100 |     100 |        10 | 0                 |'; Color = 'Green' })
$reportRows.Add([pscustomobject]@{ Text = '  +------+------------------------------------+---------+---------+-----------+-------------------+'; Color = 'DarkGray' })
for ($index = 0; $index -lt 75; $index++) {
    $reportRows.Add([pscustomobject]@{ Text = "  Evidence row $index confirms that report scrolling and resize redraw preserve only the current frame."; Color = 'DarkGray' })
}

$wideLines = @(Get-DiskHealthReportDisplayLines -Rows @($reportRows) -Width 116)
Assert-TuiRegression ($wideLines.PlainText -contains '  | ID   | Attribute Name                     | Score   | Worst   | Fail <=   | Vendor Raw        |') 'Wide report lost the original SMART table.'
$nearBreakpointLines = @(Get-DiskHealthReportDisplayLines -Rows @($reportRows) -Width 98)
Assert-TuiRegression (-not (@($nearBreakpointLines.PlainText | Where-Object { $_ -like 'SMART attributes (compact view):*' }).Count)) 'The table changed abruptly to stacked mode just below its natural width.'
Assert-TuiRegression (@($nearBreakpointLines.PlainText | Where-Object { $_.TrimStart().StartsWith('| ID') }).Count -eq 1) 'The adaptive table header disappeared just below its natural width.'

$mediumLines = @(Get-DiskHealthReportDisplayLines -Rows @($reportRows) -Width 56)
Assert-TuiRegression (-not (@($mediumLines.PlainText | Where-Object { $_ -like 'SMART attributes (compact view):*' }).Count)) 'A medium-width report changed to stacked mode instead of keeping the table.'
Assert-TuiRegression (@($mediumLines.PlainText | Where-Object { $_.TrimStart().StartsWith('| ID') }).Count -eq 1) 'The medium-width report did not retain a table header.'
Assert-TuiRegression (@($mediumLines.PlainText | Where-Object { $_ -match 'Reallocated|Sectors|Count' }).Count -ge 2) 'A long attribute name did not expand vertically inside the adaptive table row.'
foreach ($line in $mediumLines) {
    Assert-TuiRegression ($line.PlainText.Length -le 56) "Adaptive table line exceeds 56 columns: $($line.PlainText)"
}

$pannedLeftLines = @(Get-DiskHealthReportDisplayLines -Rows @($reportRows) -Width 48 -HorizontalOffset 0)
$pannedRightLines = @(Get-DiskHealthReportDisplayLines -Rows @($reportRows) -Width 48 -HorizontalOffset 8)
Assert-TuiRegression (-not (@($pannedLeftLines.PlainText | Where-Object { $_ -like 'SMART attributes (compact view):*' }).Count)) 'Narrow report unexpectedly switched to the old stacked table view.'
Assert-TuiRegression (@($pannedLeftLines.PlainText | Where-Object { $_.TrimStart().StartsWith('| ID') }).Count -eq 1) 'The left edge of the horizontally panned table lost its header.'
Assert-TuiRegression (@($pannedLeftLines.HorizontalMaximum | Where-Object { $_ -gt 0 }).Count -gt 0) 'Narrow report did not expose a horizontal table range.'
Assert-TuiRegression (($pannedLeftLines.PlainText -join "`n") -ne ($pannedRightLines.PlainText -join "`n")) 'Changing the horizontal offset did not move the table viewport.'
foreach ($line in $pannedLeftLines + $pannedRightLines) {
    Assert-TuiRegression ($line.PlainText.Length -le 48) "Panned report line exceeds 48 columns: $($line.PlainText)"
}

$widthSequence = @(120, 101, 100, 99, 98, 80, 60, 50, 120)
$terminalHeight = 44
$frames = [System.Collections.Generic.List[object]]::new()
for ($index = 0; $index -lt $widthSequence.Count; $index++) {
    $terminalWidth = $widthSequence[$index]
    $state = $index + 1
    $horizontalOffset = if ($terminalWidth -eq 50) { 4 } else { 0 }
    $view = New-DiskHealthReportFrame `
        -Rows @($reportRows) `
        -Width ($terminalWidth - 2) `
        -WindowHeight $terminalHeight `
        -ScrollOffset ($state * 3) `
        -HorizontalOffset $horizontalOffset `
        -Target "state-$state"
    $payload = Get-DiskHealthReportFramePayload -Frame $view.Frame -ForceClear
    $lineCount = [regex]::Matches($view.Frame.ToString(), "`n").Count
    Assert-TuiRegression ($lineCount -le ($terminalHeight - 1)) "Frame $state uses $lineCount rows in a $terminalHeight-row viewport."
    Assert-TuiRegression ($payload.Contains("`r`n")) "Frame $state lost raw CRLF line endings."
    Assert-TuiRegression (-not [regex]::IsMatch($payload, '(?<!\r)\n')) "Frame $state contains a lone LF."
    if ($terminalWidth -eq 50) {
        Assert-TuiRegression ($view.MaximumHorizontalOffset -gt 0) 'The 50-column frame did not expose horizontal table navigation.'
        Assert-TuiRegression ($view.HorizontalOffset -eq 4) 'The 50-column frame did not preserve the requested horizontal offset.'
        Assert-TuiRegression ($view.Frame.ToString().Contains('table pan')) 'The narrow report frame did not render the horizontal pan indicator.'
    }
    $frames.Add([pscustomobject]@{ Width = $terminalWidth; Height = $terminalHeight; State = $state; Data = $payload })
}

function Test-DiskHealthPython {
    param([AllowEmptyString()][string]$Candidate)
    if ([string]::IsNullOrWhiteSpace($Candidate) -or -not (Test-Path -LiteralPath $Candidate -PathType Leaf)) { return $false }
    $oldPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $Candidate -c 'import sys; raise SystemExit(0)' *> $null
        return $LASTEXITCODE -eq 0
    }
    catch { return $false }
    finally { $ErrorActionPreference = $oldPreference }
}

function Get-VerifiedDiskHealthWheel {
    param([string]$Package, [string]$Version, [string]$FileName, [string]$Sha256)

    $downloadRoot = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'DiskHealth\TestTools\downloads'
    $null = New-Item -ItemType Directory -Path $downloadRoot -Force
    $target = Join-Path $downloadRoot $FileName
    if (Test-Path -LiteralPath $target -PathType Leaf) {
        if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -eq $Sha256) { return $target }
        throw "Cached test wheel hash mismatch: $target"
    }

    $metadata = Invoke-RestMethod -Uri "https://pypi.org/pypi/$Package/$Version/json" -TimeoutSec 30
    $artifact = @($metadata.urls | Where-Object { $_.filename -eq $FileName }) | Select-Object -First 1
    if ($null -eq $artifact -or [string]$artifact.digests.sha256 -ne $Sha256.ToLowerInvariant()) {
        throw "Official PyPI metadata did not verify $FileName"
    }
    Invoke-WebRequest -Uri $artifact.url -OutFile $target -UseBasicParsing -TimeoutSec 60
    if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne $Sha256) { throw "Downloaded test wheel hash mismatch: $target" }
    return $target
}

if (-not $SkipVirtualTerminalReplay) {
    $pythonCandidates = @(
        $PythonPath
        $env:DISKHEALTH_TEST_PYTHON
        (Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe')
        (Get-Command python -ErrorAction SilentlyContinue).Source
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
    $PythonPath = @($pythonCandidates | Where-Object { Test-DiskHealthPython -Candidate $_ }) | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($PythonPath)) { throw 'A working Python executable is required for the DiskHealth pyte replay.' }

    $pyteWheel = Get-VerifiedDiskHealthWheel -Package 'pyte' -Version '0.8.2' -FileName 'pyte-0.8.2-py3-none-any.whl' -Sha256 '85DB42A35798A5AAFA96AC4D8DA78B090B2C933248819157FC0E6F78876A0135'
    $wcwidthWheel = Get-VerifiedDiskHealthWheel -Package 'wcwidth' -Version '0.8.2' -FileName 'wcwidth-0.8.2-py3-none-any.whl' -Sha256 'D63947694A0539A1D51E01EDA7CAF800C291020E6CDD7E28AD7B14DD33AD4F85'
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("DiskHealth-TUI-VT-{0}" -f [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $tempRoot
    try {
        $manifest = [System.Collections.Generic.List[object]]::new()
        foreach ($frame in $frames) {
            $framePath = Join-Path $tempRoot ("frame-{0}.txt" -f $frame.State)
            [System.IO.File]::WriteAllText($framePath, $frame.Data, [System.Text.UTF8Encoding]::new($false))
            $manifest.Add([pscustomobject]@{ width = $frame.Width; height = $frame.Height; state = $frame.State; path = $framePath })
        }
        $manifestPath = Join-Path $tempRoot 'manifest.json'
        [System.IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 4), [System.Text.UTF8Encoding]::new($false))
        $pythonCode = @'
import json
import pathlib
import re
import sys
import pyte
from wcwidth import wcswidth

ANSI = re.compile(r"\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1b\\))")

class TrackingScreen(pyte.Screen):
    def __init__(self, columns, lines):
        super().__init__(columns, lines)
        self.scrolls = 0
    def index(self):
        bottom = self.lines - 1 if self.margins is None else self.margins.bottom
        at_bottom = self.cursor.y == bottom
        super().index()
        if at_bottom:
            self.scrolls += 1

manifest = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
first = manifest[0]
screen = TrackingScreen(first["width"], first["height"])
stream = pyte.Stream(screen)
previous_marker = None
for item in manifest:
    screen.resize(lines=item["height"], columns=item["width"])
    with pathlib.Path(item["path"]).open("r", encoding="utf-8", newline="") as handle:
        payload = handle.read()
    if "\r\n" not in payload or re.search(r"(?<!\r)\n", payload):
        raise SystemExit(f"state {item['state']}: raw CRLF payload was not preserved")
    for source_line in ANSI.sub("", payload).splitlines():
        width = wcswidth(source_line)
        if width >= item["width"]:
            raise SystemExit(f"state {item['state']}: line width {width} reached viewport {item['width']}")
    before = screen.scrolls
    stream.feed(payload)
    if screen.scrolls != before:
        raise SystemExit(f"state {item['state']}: viewport scrolled during redraw")
    display = "\n".join(screen.display)
    marker = f"state-{item['state']}"
    if display.count("DiskHealth Diagnostic Report") != 1:
        raise SystemExit(f"state {item['state']}: report banner missing or duplicated")
    if display.count(marker) != 1:
        raise SystemExit(f"state {item['state']}: current frame marker missing or duplicated")
    if previous_marker and previous_marker in display:
        raise SystemExit(f"state {item['state']}: stale prior frame remained")
    previous_marker = marker

print("DiskHealth pyte resize replay passed: 120->101->100->99->98->80->60->50->120, zero wraps, zero scrolls, zero stale frames")
'@
        $pythonScript = Join-Path $tempRoot 'replay.py'
        [System.IO.File]::WriteAllText($pythonScript, $pythonCode, [System.Text.UTF8Encoding]::new($false))
        $previousPythonPath = $env:PYTHONPATH
        $env:PYTHONPATH = "$pyteWheel;$wcwidthWheel"
        try {
            $oldPreference = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'Continue'
                $output = & $PythonPath $pythonScript $manifestPath 2>&1
                $exitCode = $LASTEXITCODE
            }
            finally { $ErrorActionPreference = $oldPreference }
            if ($exitCode -ne 0) { throw ($output -join [Environment]::NewLine) }
            $output | Write-Output
        }
        finally { $env:PYTHONPATH = $previousPythonPath }
    }
    finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Output 'DiskHealth report TUI regression passed.'
