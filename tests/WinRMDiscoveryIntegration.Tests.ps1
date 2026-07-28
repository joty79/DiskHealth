[CmdletBinding()]
param([switch]$Live)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'DiskHealth.ps1'
$compatibilityPath = Join-Path $repoRoot 'Get-DiskHealth.ps1'
$manifest = Join-Path $repoRoot '.assets\WinRMDiscovery\WinRMDiscovery.psd1'

$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) {
    throw ($errors | Format-List | Out-String)
}

$parameterNames = @($ast.ParamBlock.Parameters.Name.VariablePath.UserPath)
foreach ($required in @('ComputerName', 'Discover', 'DiscoveryStateRoot', 'Benchmark', 'NoUI', 'EmbeddedRemote')) {
    if ($parameterNames -notcontains $required) {
        throw "Missing DiskHealth parameter: $required"
    }
}

$computerNameParameter = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'ComputerName' } | Select-Object -First 1
if ($computerNameParameter.DefaultValue.Value -ne 'localhost') {
    throw "Interactive default target must be localhost; got '$($computerNameParameter.DefaultValue.Value)'."
}

foreach ($requiredFunction in @(
    'Get-MenuDisplayText'
    'Get-DiskHealthWinRMComputers'
    'Get-DiskHealthSavedWinRMTargets'
    'Get-DiskHealthStoredCredential'
    'Save-DiskHealthStoredCredential'
    'Remove-DiskHealthStoredCredential'
    'Select-WinRMDiscoveryTarget'
    'Invoke-DiscoveredWinRMTarget'
    'Show-StartupTargetMenu'
    'Show-DriveMenu'
)) {
    $functionAst = $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $requiredFunction
    }, $true) | Select-Object -First 1
    if (-not $functionAst) {
        throw "Missing interactive integration function: $requiredFunction"
    }
}

$source = Get-Content -LiteralPath $scriptPath -Raw
if ($source -notmatch "Action\s*=\s*'Local';\s*Label\s*=\s*'💻 Local computer'") {
    throw 'Startup target menu is missing the Local computer action.'
}
if ($source -notmatch "Action\s*=\s*'Network';\s*Label\s*=\s*'🌐 Network computer \(WinRM\)'") {
    throw 'Startup target menu is missing the Network computer action.'
}
if ($source -notmatch 'if\s*\(\$script:IsHomeLauncher\)') {
    throw 'Normal launch is not routed through the startup target menu.'
}
$localRoutingPattern = 'if\s*\(\$startupChoice\s+-eq\s+''Local''\)[\s\S]{0,500}-ComputerName\s+''localhost''[\s\S]{0,500}-EmbeddedRemote'
if ($source -notmatch $localRoutingPattern) {
    throw 'Local startup choice must run as an embedded target so ESC can return to the main menu.'
}
if ($source -notmatch '\$networkComputers\s*=\s*@\(Get-DiskHealthWinRMComputers' -or $source -notmatch 'Select-WinRMDiscoveryTarget\s+-Computers\s+\$networkComputers') {
    throw 'Network results must be reused when returning from remote disks to the computer selector.'
}

$driveMenuFunction = $ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Show-DriveMenu'
}, $true) | Select-Object -First 1
$driveMenuSource = $driveMenuFunction.Extent.Text
if ($driveMenuSource -match 'AllowDiscovery|ReturnLocal|Αναζήτηση υπολογιστών στο LAN') {
    throw 'The disk menu must not expose network discovery or a local-return pseudo-option.'
}
$backActionPattern = '\$escapeAction\s*=\s*if\s*\(\$AllowBack\)\s*\{\s*''Back''\s*\}\s*else\s*\{\s*''Exit''\s*\}'
if ($driveMenuSource -notmatch '\[switch\]\$AllowBack' -or $driveMenuSource -notmatch $backActionPattern -or $driveMenuSource -notmatch '-EscapeMode\s+\$\(if\s*\(\$AllowBack\)') {
    throw 'The disk menu ESC path must return Back when it was opened from the main menu.'
}

$compatibilityTokens = $null
$compatibilityErrors = $null
$compatibilityAst = [System.Management.Automation.Language.Parser]::ParseFile(
    $compatibilityPath,
    [ref]$compatibilityTokens,
    [ref]$compatibilityErrors
)
if ($compatibilityErrors.Count -gt 0) {
    throw ($compatibilityErrors | Format-List | Out-String)
}
$compatibilitySource = Get-Content -LiteralPath $compatibilityPath -Raw
if ($compatibilitySource -notmatch "ChildPath\s+'DiskHealth\.ps1'" -or $compatibilitySource -notmatch '@PSBoundParameters') {
    throw 'Get-DiskHealth.ps1 must remain a thin compatibility launcher for DiskHealth.ps1.'
}

$menuDisplayFunction = $ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-MenuDisplayText'
}, $true) | Select-Object -First 1
Invoke-Expression $menuDisplayFunction.Extent.Text
$longMenuText = 'X' * 200
$safeMenuText = Get-MenuDisplayText -Text $longMenuText -ReservedColumns 10
$expectedMaximum = [Math]::Max(20, [Math]::Max(30, $Host.UI.RawUI.WindowSize.Width) - 10)
if ($safeMenuText.Length -gt $expectedMaximum -or -not $safeMenuText.EndsWith('...')) {
    throw 'Menu text truncation is not width-safe.'
}

Test-ModuleManifest -Path $manifest -ErrorAction Stop | Out-Null
Import-Module -Name $manifest -Force -ErrorAction Stop
$module = Test-ModuleManifest -Path $manifest -ErrorAction Stop
if ($module.Version -lt [version]'1.1.0') {
    throw "Vendored WinRMDiscovery module must be at least 1.1.0; found $($module.Version)."
}
foreach ($requiredExport in @(
    'Find-WinRMComputer'
    'Get-WinRMConnectionHistory'
    'Add-WinRMConnectionHistoryEntry'
    'Resolve-WinRMHistoryTargetAddress'
)) {
    if (-not (Get-Command $requiredExport -ErrorAction SilentlyContinue)) {
        throw "Vendored WinRMDiscovery module did not export $requiredExport."
    }
}

if ($Live) {
    $rows = @(Find-WinRMComputer)
    $rows | Sort-Object IPAddress | Format-Table ComputerName, IPAddress, Status -AutoSize
}

Write-Host 'DiskHealth WinRMDiscovery integration tests passed.' -ForegroundColor Green
