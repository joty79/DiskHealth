<#
.SYNOPSIS
    Resize-safe, flicker-free PowerShell TUI blueprint for Windows Terminal.

.DESCRIPTION
    Canonical target runtime: Windows Terminal (WT) + PowerShell 7.

    This blueprint captures the architecture that survived real-world debugging
    in WinAppManager after multiple failed approaches:

      1) WT synchronized output mode 2026 for atomic frame rendering
      2) Stateless immediate-mode redraw on every frame
      3) Single-write frame buffers with StringBuilder + [Console]::Write()
      4) Cursor-home redraw for normal frames, gated full clear only when needed
      5) Responsive resize polling via KeyAvailable + Test-WindowResized
      6) Low-latency key polling around 10ms when render time is under 10ms
      7) BufferSize = WindowSize, including width and height, to reduce scrollback tearing
      8) Fullscreen dashboards use the alternate screen buffer by default
      9) Forced clears purge WT scrollback with ESC[3J unless explicitly disabled
     10) UI width helpers must never report more columns than the real viewport
     11) Height budgets may hide lower-priority panes/rows; never write past viewport
     12) Do not batch arrow keys; keep one key -> one selection move -> one frame

    The important lesson is that for complex PowerShell TUIs in WT, "partial
    redraw" is not the canonical answer once resize/stretch correctness matters.
    The stable answer is immediate-mode full redraw wrapped in synchronized output,
    emitted as one text frame. Avoid many Write-Host calls inside fast navigation
    loops; use Write-Host for setup/status outside the hot render path.

    Failure modes this template is meant to prevent:
        - blinking from repeated Clear-Host during normal navigation
        - header/border multiplication from writing past WindowSize.Height
        - visual stretching/wrapping when width math exceeds the real viewport
        - arrow movement skips caused by draining or batching the input queue
        - good copied terminal text but broken rendering due to stale buffer width

    Performance guardrails:
        - when render time is under about 10ms, keep idle polling near 10ms
        - collect benchmark timings in memory and flush logs only on exit
        - use a single [Console]::Write() per frame in the hot render path

.USAGE
    Import this file as a module, then adapt:
        - Initialize-TuiHost / Restore-TuiHost
        - Read-ConsoleKey
        - Lock-ViewportToWindow
        - Show-InteractiveMenu
        - Show-SearchInputBox / Invoke-SearchMode (when modal search is needed)

    If a standalone script intentionally wants these helpers and variables in
    script scope, load it with Invoke-Expression (Get-Content -Raw) instead of
    relying on dot-sourcing a .psm1 file.

    This file is a reusable template/reference, not a finished app.
#>

$_E = [char]27
$_C = @{
    H1      = "$_E[38;2;90;180;240m"
    H2      = "$_E[38;2;140;160;180m"
    OK      = "$_E[38;2;46;204;113m"
    Warn    = "$_E[38;2;241;196;15m"
    Fail    = "$_E[38;2;231;76;60m"
    Info    = "$_E[38;2;52;152;219m"
    Gold    = "$_E[38;2;243;156;18m"
    White   = "$_E[38;2;220;225;230m"
    Dim     = "$_E[38;2;100;110;120m"
    SelBg   = "$_E[48;2;40;80;120m"
    SelFg   = "$_E[38;2;255;255;255m"
    Bold    = "$_E[1m"
    Reset   = "$_E[0m"
    EraseLn = "$_E[K"
}

$script:LastWindowWidth = 0
$script:LastWindowHeight = 0
$script:RequestForceClear = $true
$script:TuiBenchmarkLog = [System.Collections.Generic.List[string]]::new()
$script:TuiAlternateScreenActive = $false

function Test-UiEnvFlag {
    param([Parameter(Mandatory)][string]$Name)

    $value = [Environment]::GetEnvironmentVariable($Name)
    return (-not [string]::IsNullOrWhiteSpace($value) -and $value -notin @('0', 'false', 'False', 'FALSE', 'off', 'Off', 'OFF', 'no', 'No', 'NO'))
}

function Test-TuiKeepScrollback {
    Test-UiEnvFlag -Name 'POWERSHELL_TUI_KEEP_SCROLLBACK'
}

function Test-TuiPrimaryBufferMode {
    $scriptOverride = Get-Variable -Name 'TuiPrimaryBufferModeOverride' -Scope Script -ErrorAction SilentlyContinue
    if ($null -ne $scriptOverride) {
        return [bool]$scriptOverride.Value
    }
    Test-UiEnvFlag -Name 'POWERSHELL_TUI_PRIMARY_BUFFER'
}

function Get-TuiForceClearSequence {
    if (Test-TuiKeepScrollback) {
        return "$_E[2J$_E[H"
    }

    return "$_E[3J$_E[2J$_E[H"
}

function Test-UiAsciiGlyphMode {
    if (Test-UiEnvFlag -Name 'POWERSHELL_TUI_ASCII') { return $true }
    if (Test-UiEnvFlag -Name 'DEVICECHECK_ASCII_UI') { return $true }
    if (Test-UiEnvFlag -Name 'POWERSHELL_TUI_UNICODE') { return $false }

    try {
        return ([Console]::OutputEncoding.CodePage -ne 65001)
    }
    catch {
        return $false
    }
}

$script:UseAsciiUiGlyphs = Test-UiAsciiGlyphMode
$script:UiGlyphs = @{
    Diamond        = @{ Unicode = [string][char]0x25C6; Ascii = '*' }
    Expanded       = @{ Unicode = [string][char]0x25BC; Ascii = 'v' }
    Collapsed      = @{ Unicode = [string][char]0x25B6; Ascii = '>' }
    Up             = @{ Unicode = [string][char]0x2191; Ascii = '^' }
    Down           = @{ Unicode = [string][char]0x2193; Ascii = 'v' }
    Left           = @{ Unicode = [string][char]0x2190; Ascii = '<' }
    Right          = @{ Unicode = [string][char]0x2192; Ascii = '>' }
    SelectionArrow = @{ Unicode = [string][char]0x276F; Ascii = '>' }
    HLine          = @{ Unicode = [string][char]0x2500; Ascii = '-' }
    VLine          = @{ Unicode = [string][char]0x2502; Ascii = '|' }
    BoxH           = @{ Unicode = [string][char]0x2550; Ascii = '=' }
    BoxV           = @{ Unicode = [string][char]0x2551; Ascii = '|' }
    BoxTopLeft     = @{ Unicode = [string][char]0x2554; Ascii = '+' }
    BoxTopRight    = @{ Unicode = [string][char]0x2557; Ascii = '+' }
    BoxBottomLeft  = @{ Unicode = [string][char]0x255A; Ascii = '+' }
    BoxBottomRight = @{ Unicode = [string][char]0x255D; Ascii = '+' }
    Branch         = @{ Unicode = "$([char]0x251C)$([char]0x2500)$([char]0x2500) "; Ascii = '|-- ' }
    BranchLast     = @{ Unicode = "$([char]0x2514)$([char]0x2500)$([char]0x2500) "; Ascii = '`-- ' }
    Ellipsis       = @{ Unicode = [string][char]0x2026; Ascii = '...' }
}

function Get-UiGlyph {
    param([Parameter(Mandatory)][string]$Name)

    if (-not $script:UiGlyphs.ContainsKey($Name)) {
        return ''
    }

    if ($script:UseAsciiUiGlyphs) {
        return [string]$script:UiGlyphs[$Name].Ascii
    }

    return [string]$script:UiGlyphs[$Name].Unicode
}

function Begin-SyncRender {
    [Console]::Write("$_E[?2026h")
}

function End-SyncRender {
    [Console]::Write("$_E[?2026l")
}

function Initialize-TuiHost {
    try {
        $prefix = ''
        $script:TuiAlternateScreenActive = -not (Test-TuiPrimaryBufferMode)
        if ($script:TuiAlternateScreenActive) {
            $prefix = "$_E[?1049h"
        }

        # Disable auto-wrap to reduce horizontal resize tearing.
        [Console]::Write("$prefix$_E[?7l$_E[?25l$(Get-TuiForceClearSequence)")
    }
    catch {
    }
}

function Restore-TuiHost {
    try {
        [Console]::CursorVisible = $true
    }
    catch {
    }

    try {
        $suffix = ''
        if ($script:TuiAlternateScreenActive) {
            $suffix = "$_E[?1049l"
            $script:TuiAlternateScreenActive = $false
        }

        [Console]::Write("$_E[?7h$_E[?25h$suffix")
    }
    catch {
    }
}

function Get-UiWidth {
    try { [Math]::Max(1, $Host.UI.RawUI.WindowSize.Width - 2) }
    catch { 80 }
}

function Lock-ViewportToWindow {
    try {
        $windowSize = $Host.UI.RawUI.WindowSize
        $bufferSize = $Host.UI.RawUI.BufferSize
        if ($bufferSize.Width -ne $windowSize.Width -or $bufferSize.Height -ne $windowSize.Height) {
            $Host.UI.RawUI.BufferSize = $windowSize
        }
    }
    catch {
    }
}

function Test-WindowResized {
    try {
        $width = $Host.UI.RawUI.WindowSize.Width
        $height = $Host.UI.RawUI.WindowSize.Height
    }
    catch {
        return $false
    }

    if ($width -ne $script:LastWindowWidth -or $height -ne $script:LastWindowHeight) {
        $script:LastWindowWidth = $width
        $script:LastWindowHeight = $height
        $script:RequestForceClear = $true
        return $true
    }

    return $false
}

function Test-TuiBenchmarkEnabled {
    $value = [Environment]::GetEnvironmentVariable('POWERSHELL_TUI_BENCHMARK')
    return (-not [string]::IsNullOrWhiteSpace($value) -and $value -notin @('0', 'false', 'False', 'FALSE', 'off', 'Off', 'OFF'))
}

function Add-TuiBenchmarkEntry {
    param(
        [string]$Label,
        [double]$ElapsedMs,
        [string]$Details = ''
    )

    if (-not (Test-TuiBenchmarkEnabled)) { return }

    $detailText = if ([string]::IsNullOrWhiteSpace($Details)) { '' } else { " | $Details" }
    $script:TuiBenchmarkLog.Add("[$(Get-Date -Format 'HH:mm:ss.fff')] ${Label}: $([Math]::Round($ElapsedMs, 1))ms$detailText")
}

function Save-TuiBenchmarkLog {
    param(
        [string]$Path = (Join-Path -Path (Get-Location) -ChildPath 'tui_benchmark.log')
    )

    if (-not (Test-TuiBenchmarkEnabled)) { return }
    if ($script:TuiBenchmarkLog.Count -eq 0) { return }

    $script:TuiBenchmarkLog | Set-Content -LiteralPath $Path -Encoding UTF8
}

function New-UiFrame {
    [System.Text.StringBuilder]::new()
}

function Add-UiFrameLine {
    param(
        [Parameter(Mandatory)][System.Text.StringBuilder]$Frame,
        [AllowEmptyString()][string]$Text = ''
    )

    $null = $Frame.Append($Text)
    $null = $Frame.Append([Environment]::NewLine)
}

function Add-UiFrameBanner {
    param(
        [Parameter(Mandatory)][System.Text.StringBuilder]$Frame,
        [string]$Title,
        [string]$Subtitle = '',
        [int]$Width = (Get-UiWidth)
    )

    $border = (Get-UiGlyph -Name BoxH) * [Math]::Max(0, $Width - 2)
    $maxTextWidth = [Math]::Max(1, $Width - 3)

    $displayTitle = if ($null -eq $Title) { '' } else { $Title }
    if ($displayTitle.Length -gt $maxTextWidth) {
        $ellipsis = Get-UiGlyph -Name Ellipsis
        $displayTitle = $displayTitle.Substring(0, [Math]::Max(1, $maxTextWidth - $ellipsis.Length)) + $ellipsis
    }
    $titlePad = [Math]::Max(0, $maxTextWidth - $displayTitle.Length)

    $displaySubtitle = if ($null -eq $Subtitle) { '' } else { $Subtitle }
    $subtitlePad = 0
    if (-not [string]::IsNullOrWhiteSpace($displaySubtitle)) {
        if ($displaySubtitle.Length -gt $maxTextWidth) {
            $ellipsis = Get-UiGlyph -Name Ellipsis
            $displaySubtitle = $displaySubtitle.Substring(0, [Math]::Max(1, $maxTextWidth - $ellipsis.Length)) + $ellipsis
        }
        $subtitlePad = [Math]::Max(0, $maxTextWidth - $displaySubtitle.Length)
    }

    Add-UiFrameLine -Frame $Frame
    Add-UiFrameLine -Frame $Frame -Text "$($_C.H1)$(Get-UiGlyph -Name BoxTopLeft)$border$(Get-UiGlyph -Name BoxTopRight)$($_C.Reset)$($_C.EraseLn)"
    Add-UiFrameLine -Frame $Frame -Text "$($_C.H1)$(Get-UiGlyph -Name BoxV)$($_C.Bold)$($_C.White) $displayTitle$($_C.Reset)$(' ' * $titlePad)$($_C.H1)$(Get-UiGlyph -Name BoxV)$($_C.Reset)$($_C.EraseLn)"
    if (-not [string]::IsNullOrWhiteSpace($displaySubtitle)) {
        Add-UiFrameLine -Frame $Frame -Text "$($_C.H1)$(Get-UiGlyph -Name BoxV)$($_C.Dim) $displaySubtitle$($_C.Reset)$(' ' * $subtitlePad)$($_C.H1)$(Get-UiGlyph -Name BoxV)$($_C.Reset)$($_C.EraseLn)"
    }
    Add-UiFrameLine -Frame $Frame -Text "$($_C.H1)$(Get-UiGlyph -Name BoxBottomLeft)$border$(Get-UiGlyph -Name BoxBottomRight)$($_C.Reset)$($_C.EraseLn)"
    Add-UiFrameLine -Frame $Frame
}

function Add-UiFrameSection {
    param(
        [Parameter(Mandatory)][System.Text.StringBuilder]$Frame,
        [string]$Title,
        [string]$Icon = (Get-UiGlyph -Name Diamond),
        [int]$Width = (Get-UiWidth)
    )

    $prefix = if ($Icon) { " $Icon $Title " } else { " $Title " }
    $remaining = [Math]::Max(0, $Width - $prefix.Length - 1)
    $line = (Get-UiGlyph -Name HLine) * $remaining

    Add-UiFrameLine -Frame $Frame
    Add-UiFrameLine -Frame $Frame -Text "$($_C.H1)$prefix$($_C.Dim)$line$($_C.Reset)$($_C.EraseLn)"
}

function Add-UiFrameShortcutSegments {
    param(
        [Parameter(Mandatory)][System.Text.StringBuilder]$Frame,
        [Parameter(Mandatory)][object[]]$Segments,
        [int]$Width = (Get-UiWidth)
    )

    $line = [System.Text.StringBuilder]::new()
    $null = $line.Append('  ')
    $remaining = [Math]::Max(1, $Width - 3)
    foreach ($segment in $Segments) {
        if ($remaining -le 0) { break }
        $text = [string]$segment.Text
        if ($text.Length -gt $remaining) {
            $text = if ($remaining -eq 1) { $text.Substring(0, 1) } else { $text.Substring(0, $remaining - 1) + '~' }
        }
        $null = $line.Append("$($segment.Color)$text$($_C.Reset)")
        $remaining -= $text.Length
    }
    Add-UiFrameLine -Frame $Frame -Text "$($line.ToString())$($_C.EraseLn)"
}

function Split-UiWrappedText {
    param(
        [AllowEmptyString()][string]$Text = '',
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
        $contentWidth = [Math]::Max(1, $Width - $leading.Length)
        while ($word.Length -gt $contentWidth) {
            if ($line.Length -gt $leading.Length) {
                $lines.Add($line)
                $line = $leading
            }
            $lines.Add($leading + $word.Substring(0, $contentWidth))
            $word = $word.Substring($contentWidth)
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

function Get-UiAdaptiveColumnWidths {
    <#
    .SYNOPSIS
        Shrinks preferred table widths through an explicit, reusable plan.

    .DESCRIPTION
        The caller owns the table schema and supplies ordered shrink stages such
        as @{ Index = 1; Minimum = 16 }. An empty result means the requested
        content budget cannot preserve the table's declared minimum layout.
    #>
    param(
        [Parameter(Mandatory)][int[]]$PreferredWidths,
        [Parameter(Mandatory)][object[]]$ShrinkPlan,
        [int]$ContentWidth
    )

    if ($PreferredWidths.Count -eq 0 -or $ContentWidth -lt $PreferredWidths.Count) { return @() }

    $widths = [int[]]@($PreferredWidths | ForEach-Object { [Math]::Max(1, [int]$_) })
    $deficit = [Math]::Max(0, [int](($widths | Measure-Object -Sum).Sum) - $ContentWidth)
    foreach ($stage in $ShrinkPlan) {
        if ($deficit -le 0) { break }
        $index = [int]$stage.Index
        if ($index -lt 0 -or $index -ge $widths.Count) { continue }

        $minimum = [Math]::Max(1, [int]$stage.Minimum)
        $available = [Math]::Max(0, $widths[$index] - $minimum)
        $reduction = [Math]::Min($deficit, $available)
        $widths[$index] -= $reduction
        $deficit -= $reduction
    }

    if ($deficit -gt 0) { return @() }
    return @($widths)
}

function Split-UiTableCellText {
    param(
        [AllowEmptyString()][string]$Text = '',
        [int]$Width
    )

    $Width = [Math]::Max(1, $Width)
    if ([string]::IsNullOrEmpty($Text)) { return @('') }
    if ($Text.Length -le $Width) { return @($Text) }

    $lines = [System.Collections.Generic.List[string]]::new()
    $line = ''
    foreach ($originalWord in @($Text.Trim() -split '\s+')) {
        $word = $originalWord
        while ($word.Length -gt $Width) {
            if ($line.Length -gt 0) {
                $lines.Add($line)
                $line = ''
            }
            $lines.Add($word.Substring(0, $Width))
            $word = $word.Substring($Width)
        }

        $separator = if ($line.Length -gt 0) { ' ' } else { '' }
        if (($line.Length + $separator.Length + $word.Length) -gt $Width) {
            if ($line.Length -gt 0) { $lines.Add($line) }
            $line = $word
        }
        else {
            $line += $separator + $word
        }
    }

    if ($line.Length -gt 0) { $lines.Add($line) }
    return @($lines)
}

function New-UiAdaptiveTableBorder {
    param(
        [Parameter(Mandatory)][int[]]$Widths,
        [AllowEmptyString()][string]$Indent = ''
    )

    $border = [System.Text.StringBuilder]::new($Indent + '+')
    foreach ($cellWidth in $Widths) {
        $null = $border.Append(('-' * ([Math]::Max(1, $cellWidth) + 2)) + '+')
    }
    return $border.ToString()
}

function ConvertTo-UiAdaptiveTableRowLines {
    param(
        [Parameter(Mandatory)][string[]]$Cells,
        [Parameter(Mandatory)][int[]]$Widths,
        [int[]]$RightAlignedColumns = @(),
        [AllowEmptyString()][string]$Indent = ''
    )

    if ($Cells.Count -ne $Widths.Count) {
        throw 'Cells and Widths must contain the same number of items.'
    }

    $wrappedCells = [System.Collections.Generic.List[object]]::new()
    $rowHeight = 1
    for ($cellIndex = 0; $cellIndex -lt $Cells.Count; $cellIndex++) {
        $wrapped = @(Split-UiTableCellText -Text $Cells[$cellIndex] -Width $Widths[$cellIndex])
        $wrappedCells.Add($wrapped)
        $rowHeight = [Math]::Max($rowHeight, $wrapped.Count)
    }

    $result = [System.Collections.Generic.List[string]]::new()
    for ($lineIndex = 0; $lineIndex -lt $rowHeight; $lineIndex++) {
        $line = [System.Text.StringBuilder]::new($Indent)
        for ($cellIndex = 0; $cellIndex -lt $Cells.Count; $cellIndex++) {
            $value = if ($lineIndex -lt $wrappedCells[$cellIndex].Count) { [string]$wrappedCells[$cellIndex][$lineIndex] } else { '' }
            $alignRight = $RightAlignedColumns -contains $cellIndex
            $padded = if ($alignRight) { $value.PadLeft($Widths[$cellIndex]) } else { $value.PadRight($Widths[$cellIndex]) }
            $null = $line.Append('| ' + $padded + ' ')
        }
        $null = $line.Append('|')
        $result.Add($line.ToString())
    }
    return @($result)
}

function Get-UiHorizontalSlice {
    param(
        [AllowEmptyString()][string]$Text = '',
        [int]$Offset = 0,
        [int]$Width
    )

    $Width = [Math]::Max(1, $Width)
    $maximumOffset = [Math]::Max(0, $Text.Length - $Width)
    $Offset = [Math]::Max(0, [Math]::Min($Offset, $maximumOffset))
    $length = [Math]::Min($Width, $Text.Length - $Offset)
    if ($length -le 0) { return '' }
    return $Text.Substring($Offset, $length)
}

function New-UiHorizontalPanIndicator {
    param(
        [int]$Offset = 0,
        [int]$MaximumOffset = 0,
        [int]$ViewportWidth,
        [int]$Width = 60,
        [int]$TrackWidth = 12,
        [string]$Label = 'table pan'
    )

    $Width = [Math]::Max(1, $Width)
    $MaximumOffset = [Math]::Max(0, $MaximumOffset)
    if ($MaximumOffset -eq 0) { return '' }
    $Offset = [Math]::Max(0, [Math]::Min($Offset, $MaximumOffset))
    $TrackWidth = [Math]::Max(4, $TrackWidth)

    $logicalWidth = [Math]::Max(1, $ViewportWidth + $MaximumOffset)
    $thumbWidth = [Math]::Max(1, [int][Math]::Round($TrackWidth * ([double]$ViewportWidth / $logicalWidth)))
    $thumbWidth = [Math]::Min($TrackWidth, $thumbWidth)
    $thumbStart = [int][Math]::Round(($TrackWidth - $thumbWidth) * ([double]$Offset / $MaximumOffset))
    $full = if ($script:UseAsciiUiGlyphs) { '#' } else { [string][char]0x2588 }
    $empty = if ($script:UseAsciiUiGlyphs) { '-' } else { [string][char]0x2591 }
    $track = ($empty * $thumbStart) + ($full * $thumbWidth) + ($empty * ($TrackWidth - $thumbStart - $thumbWidth))
    $leftRight = "$(Get-UiGlyph -Name Left)/$(Get-UiGlyph -Name Right)"
    $text = "$leftRight $Label    [$track]  $Offset/$MaximumOffset columns"
    if ($text.Length -le $Width) { return $text }

    $compact = "$leftRight [$track] $Offset/$MaximumOffset"
    if ($compact.Length -le $Width) { return $compact }
    return Get-UiHorizontalSlice -Text $compact -Width $Width
}

function Write-UiFrame {
    param(
        [Parameter(Mandatory)][System.Text.StringBuilder]$Frame,
        [switch]$ForceClear
    )

    $shouldClear = $ForceClear -or $script:RequestForceClear
    $script:RequestForceClear = $false

    $output = [System.Text.StringBuilder]::new()
    $null = $output.Append("$_E[?2026h")
    if ($shouldClear) {
        $null = $output.Append((Get-TuiForceClearSequence))
    }
    else {
        $null = $output.Append("$_E[H")
    }
    $null = $output.Append($Frame.ToString())
    $null = $output.Append("$_E[J")
    $null = $output.Append("$_E[?2026l")

    [Console]::Write($output.ToString())
}

function Move-UiCursorToFrameStart {
    param([switch]$ForceClear)

    $shouldClear = $ForceClear -or $script:RequestForceClear
    $script:RequestForceClear = $false
    if ($shouldClear) {
        [Console]::Write((Get-TuiForceClearSequence))
    }
    else {
        [Console]::Write("$_E[H")
    }
}

function Write-UiBanner {
    param(
        [string]$Title,
        [string]$Subtitle
    )

    $frame = New-UiFrame
    Add-UiFrameBanner -Frame $frame -Title $Title -Subtitle $Subtitle -Width (Get-UiWidth)
    [Console]::Write($frame.ToString())
}

function Write-UiSection {
    param(
        [string]$Title,
        [string]$Icon = (Get-UiGlyph -Name Diamond)
    )

    $width = Get-UiWidth
    $prefix = if ($Icon) { " $Icon $Title " } else { " $Title " }
    $remaining = [Math]::Max(0, $width - $prefix.Length - 1)
    $line = (Get-UiGlyph -Name HLine) * $remaining

    Write-Host ''
    Write-Host "$($_C.H1)$prefix$($_C.Dim)$line$($_C.Reset)"
}

function New-UiShortcutSegment {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Color
    )

    [pscustomobject]@{ Text = $Text; Color = $Color }
}

function Write-UiShortcutSegments {
    param(
        [Parameter(Mandatory)][object[]]$Segments,
        [int]$Width = (Get-UiWidth)
    )

    Write-Host '  ' -NoNewline
    $remaining = [Math]::Max(1, $Width - 3)
    foreach ($segment in $Segments) {
        if ($remaining -le 0) { break }
        $text = [string]$segment.Text
        if ($text.Length -gt $remaining) {
            $text = if ($remaining -eq 1) { $text.Substring(0, 1) } else { $text.Substring(0, $remaining - 1) + '~' }
        }
        Write-Host "$($segment.Color)$text$($_C.Reset)" -NoNewline
        $remaining -= $text.Length
    }
    Write-Host "$($_C.EraseLn)"
}

function Write-UiNavFooter {
    param(
        [ValidateSet('Select','Cancel','Exit','Back')][string]$Mode = 'Select',
        [int]$Width = (Get-UiWidth)
    )

    $segments = @(
        New-UiShortcutSegment -Text "$(Get-UiGlyph -Name Up)$(Get-UiGlyph -Name Down)" -Color $_C.White
        New-UiShortcutSegment -Text ' navigate   ' -Color $_C.Dim
        New-UiShortcutSegment -Text 'Enter' -Color $_C.OK
        New-UiShortcutSegment -Text ' = select   ' -Color $_C.Dim
    )

    if ($Mode -eq 'Cancel') {
        $segments += @(
            New-UiShortcutSegment -Text 'Esc' -Color $_C.Fail
            New-UiShortcutSegment -Text ' = cancel' -Color $_C.Dim
        )
    }
    elseif ($Mode -eq 'Exit') {
        $segments += @(
            New-UiShortcutSegment -Text 'Esc' -Color $_C.Fail
            New-UiShortcutSegment -Text ' = exit' -Color $_C.Dim
        )
    }
    elseif ($Mode -eq 'Back') {
        $segments = @(
            New-UiShortcutSegment -Text 'Enter' -Color $_C.OK
            New-UiShortcutSegment -Text ' / ' -Color $_C.Dim
            New-UiShortcutSegment -Text 'Esc' -Color $_C.Fail
            New-UiShortcutSegment -Text ' = back' -Color $_C.Dim
        )
    }

    Write-UiShortcutSegments -Segments $segments -Width $Width
}

function Add-UiFrameNavFooter {
    param(
        [Parameter(Mandatory)][System.Text.StringBuilder]$Frame,
        [ValidateSet('Select','Cancel','Exit','Back')][string]$Mode = 'Select',
        [int]$Width = (Get-UiWidth)
    )

    $segments = @(
        New-UiShortcutSegment -Text "$(Get-UiGlyph -Name Up)$(Get-UiGlyph -Name Down)" -Color $_C.White
        New-UiShortcutSegment -Text ' navigate   ' -Color $_C.Dim
        New-UiShortcutSegment -Text 'Enter' -Color $_C.OK
        New-UiShortcutSegment -Text ' = select   ' -Color $_C.Dim
    )

    if ($Mode -eq 'Cancel') {
        $segments += @(
            New-UiShortcutSegment -Text 'Esc' -Color $_C.Fail
            New-UiShortcutSegment -Text ' = cancel' -Color $_C.Dim
        )
    }
    elseif ($Mode -eq 'Exit') {
        $segments += @(
            New-UiShortcutSegment -Text 'Esc' -Color $_C.Fail
            New-UiShortcutSegment -Text ' = exit' -Color $_C.Dim
        )
    }
    elseif ($Mode -eq 'Back') {
        $segments = @(
            New-UiShortcutSegment -Text 'Enter' -Color $_C.OK
            New-UiShortcutSegment -Text ' / ' -Color $_C.Dim
            New-UiShortcutSegment -Text 'Esc' -Color $_C.Fail
            New-UiShortcutSegment -Text ' = back' -Color $_C.Dim
        )
    }

    Add-UiFrameShortcutSegments -Frame $Frame -Segments $segments -Width $Width
}

function Show-SearchInputBox {
    param(
        [AllowEmptyString()]
        [string]$Query,
        [int]$MatchCount,
        [int]$MaxWidth = 56
    )

    # Keep the search control anchored and compact; do not let it stretch to full width.
    $boxWidth = [Math]::Min($MaxWidth, [Math]::Max(34, [Math]::Floor((Get-UiWidth) * 0.58)))
    $innerWidth = $boxWidth - 2
    $title = ' Search Mode '
    $titlePad = [Math]::Max(0, $innerWidth - $title.Length)
    $indent = '  '
    $prompt = '> '
    $inputWidth = [Math]::Max(8, $innerWidth - 1)
    $displayQuery = if ($Query.Length -gt $inputWidth) { $Query.Substring($Query.Length - $inputWidth) } else { $Query }
    $inputText = "$prompt$displayQuery"
    $queryPadding = [Math]::Max(0, $inputWidth - $inputText.Length)
    $topBorder = (Get-UiGlyph -Name BoxH) * $titlePad
    $bottomBorder = (Get-UiGlyph -Name BoxH) * $innerWidth

    try {
        $inputRow = $Host.UI.RawUI.CursorPosition.Y + 1
    }
    catch {
        $inputRow = 0
    }

    Write-Host "$indent$($_C.Warn)$(Get-UiGlyph -Name BoxTopLeft)$title$topBorder$(Get-UiGlyph -Name BoxTopRight)$($_C.Reset)$($_C.EraseLn)"
    Write-Host "$indent$($_C.Warn)$(Get-UiGlyph -Name BoxV)$($_C.White)$inputText$(' ' * $queryPadding)$($_C.Warn) $(Get-UiGlyph -Name BoxV)$($_C.Reset)$($_C.EraseLn)"
    Write-Host "$indent$($_C.Warn)$(Get-UiGlyph -Name BoxBottomLeft)$bottomBorder$(Get-UiGlyph -Name BoxBottomRight)$($_C.Reset)$($_C.EraseLn)"
    Write-Host "$($_C.Dim)  Matches: $($_C.OK)$MatchCount$($_C.Reset)$($_C.EraseLn)"

    [pscustomobject]@{
        CursorLeft = $indent.Length + 1 + $prompt.Length + $displayQuery.Length
        CursorTop  = $inputRow
    }
}

function Read-ConsoleKey {
    try { [Console]::CursorVisible = $false } catch {}

    try {
        if (Test-WindowResized) {
            return [pscustomobject]@{
                Key            = 'ResizeEvent'
                KeyChar        = [char]0
                VirtualKeyCode = 0
            }
        }

        while (-not [Console]::KeyAvailable) {
            if (Test-WindowResized) {
                return [pscustomobject]@{
                    Key            = 'ResizeEvent'
                    KeyChar        = [char]0
                    VirtualKeyCode = 0
                }
            }

            Start-Sleep -Milliseconds 10
        }
    }
    catch {
        throw $_
    }

    try {
        $keyInfo = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    }
    catch {
        $keyInfo = [Console]::ReadKey($true)
    }

    $keyName = $null
    $keyChar = [char]0
    $virtualKeyCode = $null

    if ($keyInfo.PSObject.Properties['Key']) {
        $keyName = [string]$keyInfo.Key
    }
    elseif ($keyInfo.PSObject.Properties['VirtualKeyCode']) {
        $virtualKeyCode = [int]$keyInfo.VirtualKeyCode
        try {
            $keyName = [string][System.Enum]::ToObject([System.ConsoleKey], $virtualKeyCode)
        }
        catch {
            $keyName = [string]$virtualKeyCode
        }
    }

    if ($keyInfo.PSObject.Properties['KeyChar']) {
        $keyChar = [char]$keyInfo.KeyChar
    }
    elseif ($keyInfo.PSObject.Properties['Character']) {
        $keyChar = [char]$keyInfo.Character
    }

    [pscustomobject]@{
        Key            = $keyName
        KeyChar        = $keyChar
        VirtualKeyCode = $virtualKeyCode
    }
}

function Invoke-ArrowMenu {
    param(
        [string[]]$Items,
        [string]$Title = 'Select',
        [string]$CurrentItem = '',
        [scriptblock]$HeaderBlock = $null
    )

    if ($Items.Count -eq 0) {
        return $null
    }

    $cursor = [Math]::Max(0, [Array]::IndexOf($Items, $CurrentItem))

    [Console]::CursorVisible = $false
    try {
        while ($true) {
            Lock-ViewportToWindow

            try {
                $maxVisible = [Math]::Max(3, $Host.UI.RawUI.WindowSize.Height - 8)
            }
            catch {
                $maxVisible = 10
            }

            $viewTop = [Math]::Max(0, [Math]::Min($cursor - [int]($maxVisible / 2), [Math]::Max(0, $Items.Count - $maxVisible)))
            $viewBot = [Math]::Min($viewTop + $maxVisible - 1, $Items.Count - 1)

            if ($null -ne $HeaderBlock) {
                Begin-SyncRender
                Move-UiCursorToFrameStart
                & $HeaderBlock
                Write-UiSection -Title $Title -Icon ''
                Write-Host ''

                $aboveMessage = if ($viewTop -gt 0) { "  $($_C.Dim)$(Get-UiGlyph -Name Up) $viewTop more above$($_C.Reset)" } else { '' }
                Write-Host "$aboveMessage$($_C.EraseLn)"

                for ($index = $viewTop; $index -le $viewBot; $index++) {
                    if ($index -eq $cursor) {
                        Write-Host "$($_C.SelBg)$($_C.SelFg)$($_C.Bold)  $(Get-UiGlyph -Name SelectionArrow) $($Items[$index]) $($_C.Reset)$($_C.EraseLn)"
                    }
                    else {
                        Write-Host "    $($_C.Dim)$($Items[$index])$($_C.Reset)$($_C.EraseLn)"
                    }
                }

                $below = $Items.Count - 1 - $viewBot
                $belowMessage = if ($below -gt 0) { "  $($_C.Dim)$(Get-UiGlyph -Name Down) $below more below$($_C.Reset)" } else { '' }
                Write-Host "$belowMessage$($_C.EraseLn)"
                Write-Host "$($_C.EraseLn)"
                Write-UiNavFooter -Mode Cancel
                Write-Host "$($_E)[J" -NoNewline
                End-SyncRender
            }
            else {
                $frame = New-UiFrame
                Add-UiFrameSection -Frame $frame -Title $Title -Icon ''
                Add-UiFrameLine -Frame $frame

                $aboveMessage = if ($viewTop -gt 0) { "  $($_C.Dim)$(Get-UiGlyph -Name Up) $viewTop more above$($_C.Reset)" } else { '' }
                Add-UiFrameLine -Frame $frame -Text "$aboveMessage$($_C.EraseLn)"

                for ($index = $viewTop; $index -le $viewBot; $index++) {
                    if ($index -eq $cursor) {
                        Add-UiFrameLine -Frame $frame -Text "$($_C.SelBg)$($_C.SelFg)$($_C.Bold)  $(Get-UiGlyph -Name SelectionArrow) $($Items[$index]) $($_C.Reset)$($_C.EraseLn)"
                    }
                    else {
                        Add-UiFrameLine -Frame $frame -Text "    $($_C.Dim)$($Items[$index])$($_C.Reset)$($_C.EraseLn)"
                    }
                }

                $below = $Items.Count - 1 - $viewBot
                $belowMessage = if ($below -gt 0) { "  $($_C.Dim)$(Get-UiGlyph -Name Down) $below more below$($_C.Reset)" } else { '' }
                Add-UiFrameLine -Frame $frame -Text "$belowMessage$($_C.EraseLn)"
                Add-UiFrameLine -Frame $frame -Text "$($_C.EraseLn)"
                Add-UiFrameNavFooter -Frame $frame -Mode Cancel
                Write-UiFrame -Frame $frame
            }

            $key = Read-ConsoleKey
            switch ($key.Key) {
                'UpArrow' { if ($cursor -gt 0) { $cursor-- } }
                'DownArrow' { if ($cursor -lt ($Items.Count - 1)) { $cursor++ } }
                'PageUp' { $cursor = [Math]::Max(0, $cursor - $maxVisible) }
                'PageDown' { $cursor = [Math]::Min($Items.Count - 1, $cursor + $maxVisible) }
                'Home' { $cursor = 0 }
                'End' { $cursor = $Items.Count - 1 }
                'Enter' { return $Items[$cursor] }
                'Escape' { return $null }
                'ResizeEvent' { continue }
            }
        }
    }
    finally {
        try { [Console]::CursorVisible = $true } catch {}
    }
}

function Show-InteractiveMenu {
    param(
        [string]$AppTitle = 'My App',
        [string]$AppSubtitle = '',
        [string[]]$Options = @('Option 1', 'Option 2', 'Exit'),
        [hashtable]$Actions = @{}
    )

    $selectedIndex = 0

    [Console]::CursorVisible = $false
    try {
        while ($true) {
            Lock-ViewportToWindow
            $frame = New-UiFrame
            Add-UiFrameBanner -Frame $frame -Title $AppTitle -Subtitle $AppSubtitle -Width (Get-UiWidth)
            Add-UiFrameSection -Frame $frame -Title 'Menu'

            for ($index = 0; $index -lt $Options.Count; $index++) {
                if ($index -eq $selectedIndex) {
                    Add-UiFrameLine -Frame $frame -Text "$($_C.SelBg)$($_C.SelFg)$($_C.Bold)  $(Get-UiGlyph -Name SelectionArrow) $($Options[$index]) $($_C.Reset)$($_C.EraseLn)"
                }
                else {
                    Add-UiFrameLine -Frame $frame -Text "    $($_C.White)$($Options[$index])$($_C.Reset)$($_C.EraseLn)"
                }
            }

            Add-UiFrameLine -Frame $frame
            Add-UiFrameNavFooter -Frame $frame -Mode Exit
            Write-UiFrame -Frame $frame

            $key = Read-ConsoleKey
            switch ($key.Key) {
                'UpArrow' { $selectedIndex = [Math]::Max(0, $selectedIndex - 1) }
                'DownArrow' { $selectedIndex = [Math]::Min($Options.Count - 1, $selectedIndex + 1) }
                'Escape' { return }
                'ResizeEvent' { continue }
                'Enter' {
                    if ($Actions.ContainsKey($selectedIndex)) {
                        & $Actions[$selectedIndex]
                    }
                    elseif ($selectedIndex -eq ($Options.Count - 1)) {
                        return
                    }
                }
            }
        }
    }
    finally {
        try { [Console]::CursorVisible = $true } catch {}
    }
}

function Invoke-SearchMode {
    param(
        [scriptblock]$RenderHeader,
        [scriptblock]$RenderResults,
        [scriptblock]$GetVisibleItems,
        [ref]$Filter,
        [int]$SelectedIndex = 0
    )

    $originalFilter = [string]$Filter.Value
    $currentIndex = [Math]::Max(0, $SelectedIndex)

    while ($true) {
        Lock-ViewportToWindow
        $visibleItems = @(& $GetVisibleItems)
        if ($visibleItems.Count -eq 0) {
            $currentIndex = 0
        }
        else {
            $currentIndex = [Math]::Max(0, [Math]::Min($currentIndex, $visibleItems.Count - 1))
        }

        Begin-SyncRender
        Move-UiCursorToFrameStart
        if ($null -ne $RenderHeader) { & $RenderHeader }
        $searchUi = Show-SearchInputBox -Query $Filter.Value -MatchCount $visibleItems.Count
        if ($null -ne $RenderResults) { & $RenderResults $visibleItems $currentIndex }
        [Console]::Write("$_E[J")
        End-SyncRender

        try { [Console]::SetCursorPosition($searchUi.CursorLeft, $searchUi.CursorTop) } catch {}
        try { [Console]::CursorVisible = $true } catch {}

        $keyInfo = Read-ConsoleKey
        switch ($keyInfo.Key) {
            'Escape' {
                $Filter.Value = $originalFilter
                return 0
            }
            'Enter' {
                $Filter.Value = $Filter.Value.Trim()
                return 0
            }
            'Backspace' {
                if ($Filter.Value.Length -gt 0) {
                    $Filter.Value = $Filter.Value.Substring(0, $Filter.Value.Length - 1)
                }
                $currentIndex = 0
                continue
            }
            'Delete' {
                $Filter.Value = ''
                $currentIndex = 0
                continue
            }
            'Spacebar' {
                $Filter.Value += ' '
                $currentIndex = 0
                continue
            }
            'ResizeEvent' {
                continue
            }
            default {
                if ($keyInfo.KeyChar -ne [char]0 -and -not [char]::IsControl($keyInfo.KeyChar)) {
                    $Filter.Value += [string]$keyInfo.KeyChar
                    $currentIndex = 0
                }
                continue
            }
        }
    }
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  NATIVE WINDOWS FILE/FOLDER PICKERS
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
function Select-FileWithDialog {
    param(
        [string]$Title = 'Select File',
        [string]$Filter = 'All files (*.*)|*.*',
        [string]$InitialDir = ''
    )
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = $Title
    $dlg.Filter = $Filter
    $dlg.CheckFileExists = $true
    if ($InitialDir -and (Test-Path $InitialDir)) { $dlg.InitialDirectory = $InitialDir }
    if ($dlg.ShowDialog() -eq 'OK') { return $dlg.FileName }
    return ''
}
