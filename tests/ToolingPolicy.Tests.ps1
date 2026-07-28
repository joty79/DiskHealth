[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'DiskHealth.ps1'
$source = Get-Content -LiteralPath $scriptPath -Raw

if ($source -notmatch '--id\s+smartmontools\.smartmontools') {
    throw 'The smartmontools install must use the exact official winget package ID.'
}
if ($source -notmatch '--scope\s+machine') {
    throw 'The smartmontools install must use machine scope.'
}
if ($source -notmatch "C:\\Program Files\\smartmontools\\bin\\smartctl\.exe") {
    throw 'The smartmontools install must verify the standard Program Files path.'
}

foreach ($requiredInteractiveMarker in @(
    'function Show-SmartctlInstallMenu'
    "Action = 'Install'"
    "Action = 'Continue'"
    "return 'Back'"
    '$installSmartctlNow = [bool]$InstallSmartctl'
    '$canPromptForInstall'
    '-not $NoUI'
)) {
    if (-not $source.Contains($requiredInteractiveMarker)) {
        throw "Missing interactive smartctl install marker: $requiredInteractiveMarker"
    }
}
if ($source -notmatch '(?s)if\s*\(\$canPromptForInstall\).*?Show-SmartctlInstallMenu') {
    throw 'Missing-smartctl handling does not prompt normal interactive users inside the script.'
}
if ($source -notmatch '(?s)if\s*\(-not\s+\$remoteSmartctlExists\s+-and\s+\$installSmartctlNow\).*?smartmontools\.smartmontools') {
    throw 'Both the interactive decision and -InstallSmartctl must route through the official installer path.'
}

$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $scriptPath,
    [ref]$tokens,
    [ref]$parseErrors
)
if ($parseErrors.Count -gt 0) {
    throw "Production script has parser errors: $($parseErrors -join '; ')"
}
foreach ($functionName in @('Get-MenuDisplayText', 'Show-SmartctlInstallMenu')) {
    $functionAst = $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq $functionName
    }, $true) | Select-Object -First 1
    if (-not $functionAst) {
        throw "Required production function not found: $functionName"
    }
    Invoke-Expression $functionAst.Extent.Text
}

$installKey = [ConsoleKeyInfo]::new('1', [ConsoleKey]::D1, $false, $false, $false)
$continueKey = [ConsoleKeyInfo]::new('2', [ConsoleKey]::D2, $false, $false, $false)
$escapeKey = [ConsoleKeyInfo]::new([char]0, [ConsoleKey]::Escape, $false, $false, $false)
$installDecision = Show-SmartctlInstallMenu -ReadKey { $installKey } 6>$null
if ($installDecision -ne 'Install') {
    throw 'Interactive smartctl option 1 did not return Install.'
}
$continueDecision = Show-SmartctlInstallMenu -ReadKey { $continueKey } 6>$null
if ($continueDecision -ne 'Continue') {
    throw 'Interactive smartctl option 2 did not return Continue.'
}
$backDecision = Show-SmartctlInstallMenu -ReadKey { $escapeKey } 6>$null
if ($backDecision -ne 'Back') {
    throw 'Interactive smartctl ESC did not return Back.'
}

$forbiddenInstallPatterns = @(
    'downloads\.sourceforge\.net',
    'smartmontools-7\.4',
    'New-Item[^\r\n]+C:\\[^\r\n]+smartmontools',
    'Expand-Archive[^\r\n]+C:\\smartmontools',
    'DestinationPath\s+["'']C:\\smartmontools'
)
foreach ($pattern in $forbiddenInstallPatterns) {
    if ($source -match $pattern) {
        throw "Forbidden legacy smartmontools install pattern found: $pattern"
    }
}

Write-Host 'DiskHealth tooling policy tests passed.' -ForegroundColor Green
